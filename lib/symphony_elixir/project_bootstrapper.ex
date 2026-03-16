defmodule SymphonyElixir.ProjectBootstrapper do
  @moduledoc """
  Creates a new project: git repo, beads tracker, WORKFLOW.md.

  Handles the full lifecycle from empty directory to a ready-to-orchestrate project.
  """

  require Logger

  alias SymphonyElixir.WorkflowTemplate

  @type project_opts :: %{
          name: String.t(),
          path: String.t(),
          description: String.t(),
          tech_stack: String.t(),
          agent_model: String.t(),
          max_agents: pos_integer(),
          max_turns: pos_integer()
        }

  @type project_result :: %{
          repo_path: String.t(),
          workflow_path: String.t(),
          workspace_root: String.t()
        }

  @doc """
  Bootstrap a new project from scratch.

  Creates the directory, initializes git + beads, writes WORKFLOW.md,
  and returns paths needed to start orchestration.
  """
  @spec bootstrap(project_opts()) :: {:ok, project_result()} | {:error, term()}
  def bootstrap(opts) do
    repo_path = Path.expand(opts.path)
    workspace_root = Path.join(Path.dirname(repo_path), "#{opts.name}-workspaces")

    with :ok <- create_directory(repo_path),
         :ok <- git_init(repo_path),
         :ok <- create_starter_files(repo_path, opts),
         :ok <- git_initial_commit(repo_path),
         :ok <- beads_init(repo_path),
         :ok <- git_commit(repo_path, "Initialize beads issue tracker"),
         :ok <- configure_receive_policy(repo_path),
         workflow_path <- Path.join(repo_path, "WORKFLOW.md"),
         :ok <- write_workflow(workflow_path, repo_path, workspace_root, opts),
         :ok <- git_commit(repo_path, "Add WORKFLOW.md orchestration config"),
         :ok <- create_directory(workspace_root) do
      Logger.info("Project bootstrapped: #{repo_path}")

      {:ok,
       %{
         repo_path: repo_path,
         workflow_path: workflow_path,
         workspace_root: workspace_root
       }}
    end
  end

  @doc """
  Activate a bootstrapped project: set WORKFLOW_PATH, BEADS_ROOT, and reload.
  """
  @spec activate(project_result()) :: :ok
  def activate(%{repo_path: repo_path, workflow_path: workflow_path}) do
    Application.put_env(:symphony_elixir, :beads_root, repo_path)
    SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)
    Logger.info("Project activated: workflow=#{workflow_path} beads=#{repo_path}")
    :ok
  end

  # -- Steps --

  defp create_directory(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  defp git_init(path) do
    case System.cmd("git", ["init"], cd: path, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:git_init_failed, code, output}}
    end
  end

  defp create_starter_files(path, opts) do
    readme = """
    # #{opts.name}

    #{opts.description}

    ## Development

    This project is orchestrated by [Jido Symphony](https://github.com/agentjido/jido_symphony).
    Issues are tracked with Beads (`br list`).
    """

    gitignore = """
    # Dependencies
    /deps
    /_build
    /node_modules

    # Generated
    *.beam
    *.pyc
    __pycache__/
    /cover
    /doc

    # IDE
    .elixir_ls/
    .vscode/
    .idea/

    # OS
    .DS_Store
    Thumbs.db
    """

    with :ok <- File.write(Path.join(path, "README.md"), readme),
         :ok <- File.write(Path.join(path, ".gitignore"), gitignore) do
      :ok
    else
      {:error, reason} -> {:error, {:write_starter_files_failed, reason}}
    end
  end

  defp git_initial_commit(path) do
    with {_, 0} <- System.cmd("git", ["add", "-A"], cd: path, stderr_to_stdout: true),
         {_, 0} <-
           System.cmd("git", ["commit", "-m", "Initial commit"], cd: path, stderr_to_stdout: true) do
      :ok
    else
      {output, code} -> {:error, {:git_commit_failed, code, output}}
    end
  end

  defp beads_init(path) do
    br_path = System.find_executable("br")

    if is_nil(br_path) do
      {:error, :br_not_installed}
    else
      case System.cmd(br_path, ["init"], cd: path, stderr_to_stdout: true) do
        {_, 0} ->
          # Stage the .beads directory
          {_, 0} = System.cmd("git", ["add", "-A"], cd: path, stderr_to_stdout: true)
          :ok

        {output, code} ->
          {:error, {:beads_init_failed, code, output}}
      end
    end
  end

  defp configure_receive_policy(path) do
    case System.cmd("git", ["config", "receive.denyCurrentBranch", "updateInstead"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:git_config_failed, code, output}}
    end
  end

  defp write_workflow(workflow_path, repo_path, workspace_root, opts) do
    content =
      WorkflowTemplate.render(
        repo_path: repo_path,
        workspace_root: workspace_root,
        project_description: opts.description,
        tech_stack: Map.get(opts, :tech_stack, ""),
        agent_model: Map.get(opts, :agent_model, "claude-sonnet-4"),
        max_agents: Map.get(opts, :max_agents, 3),
        max_turns: Map.get(opts, :max_turns, 15)
      )

    case File.write(workflow_path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_workflow_failed, reason}}
    end
  end

  defp git_commit(path, message) do
    with {_, 0} <- System.cmd("git", ["add", "-A"], cd: path, stderr_to_stdout: true),
         {_, 0} <-
           System.cmd("git", ["commit", "-m", message, "--allow-empty"],
             cd: path,
             stderr_to_stdout: true
           ) do
      :ok
    else
      {output, code} -> {:error, {:git_commit_failed, code, output}}
    end
  end
end
