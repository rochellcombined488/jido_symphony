defmodule SymphonyElixir.WorkflowTemplate do
  @moduledoc """
  Generates a WORKFLOW.md file from project parameters.

  The template is tech-stack-agnostic in its orchestration config
  (YAML front matter) but includes user-provided tech-stack instructions
  in the agent prompt section.
  """

  @doc """
  Render a complete WORKFLOW.md string from the given options.

  ## Options

    * `:repo_path` — absolute path to the local git repository (required)
    * `:workspace_root` — where agent workspaces are created (default: `<repo_path>/../<name>-workspaces`)
    * `:tech_stack` — tech-stack instructions for the agent prompt (e.g., "Elixir + Phoenix + LiveView")
    * `:project_description` — one-line project description for prompt context
    * `:agent_model` — LLM model (default: "claude-sonnet-4")
    * `:max_agents` — max concurrent agents (default: 3)
    * `:max_turns` — max turns per issue (default: 15)

  """
  @spec render(keyword()) :: String.t()
  def render(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path) |> Path.expand()
    name = Path.basename(repo_path)

    workspace_root =
      Keyword.get_lazy(opts, :workspace_root, fn ->
        Path.join(Path.dirname(repo_path), "#{name}-workspaces")
      end)

    tech_stack = Keyword.get(opts, :tech_stack, "")
    project_description = Keyword.get(opts, :project_description, "")
    agent_model = Keyword.get(opts, :agent_model, "claude-sonnet-4")
    max_agents = Keyword.get(opts, :max_agents, 3)
    max_turns = Keyword.get(opts, :max_turns, 15)

    yaml_section(repo_path, workspace_root, agent_model, max_agents, max_turns) <>
      prompt_section(project_description, tech_stack)
  end

  defp yaml_section(repo_path, workspace_root, agent_model, max_agents, max_turns) do
    """
    ---
    tracker:
      kind: beads
    workspace:
      root: #{workspace_root}
    hooks:
      after_create: |
        git clone #{repo_path} .
      after_run: |
        set -e
        BRANCH="symphony/${SYMPHONY_ISSUE_ID:-unknown}"
        git checkout -B "$BRANCH"
        if ! git diff --quiet HEAD || ! git diff --cached --quiet; then
          git add -A
          git commit -m "feat: ${SYMPHONY_ISSUE_TITLE:-work for $BRANCH}" --allow-empty || true
        fi
        git fetch origin master 2>/dev/null || git fetch origin main 2>/dev/null || true
        DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "master")
        git rebase "origin/$DEFAULT_BRANCH" || git rebase --abort
        git push origin "$BRANCH" --force-with-lease
    agent:
      kind: ghcopilot
      max_concurrent_agents: #{max_agents}
      max_turns: #{max_turns}
    ghcopilot:
      mode: acp
      model: #{agent_model}
      allow_all_tools: true
    polling:
      interval_ms: 5000
    ---
    """
  end

  # Use ~S sigil to avoid Elixir interpolation of Liquid {{ }} template syntax
  @prompt_template ~S"""

  You are working on issue `{{ issue.identifier }}`.

  {% if attempt %}
  Continuation context:

  - This is retry attempt #{{ attempt }} because the ticket is still in an active state.
  - Resume from the current workspace state instead of restarting from scratch.
  {% endif %}

  Issue context:
  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}
  Current status: {{ issue.state }}
  Labels: {{ issue.labels }}

  Description:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @instructions_template ~S"""
  Instructions:

  1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
  2. Only stop early for a true blocker (missing required auth/permissions/secrets).
  3. Work only in the provided repository copy. Do not touch any other path.
  4. Follow the conventions already established in the codebase.
  5. Write tests for all new modules.
  6. Run the project's existing test command before considering work complete.
  7. Format code according to the project's conventions before committing.

  ## Git workflow

  - At the start, create and switch to a feature branch: `git checkout -b symphony/{{ issue.identifier }}`
  - Commit your work to this feature branch with descriptive messages.
  - Do NOT push or merge to master/main directly. The orchestrator handles merging.
  - Do NOT run `git push`. The after_run hook handles pushing.

  ## Status flow

  - `open` → pick up and start working
  - `in_progress` → actively implementing
  - `closed` → done, no further action
  """

  defp prompt_section(project_description, tech_stack) do
    @prompt_template <>
      project_context_section(project_description) <>
      tech_stack_section(tech_stack) <>
      @instructions_template
  end

  defp project_context_section(""), do: ""

  defp project_context_section(description) do
    """

    Project context:
    #{description}
    """
  end

  defp tech_stack_section(""), do: ""

  defp tech_stack_section(tech_stack) do
    """

    ## Tech stack

    #{tech_stack}
    """
  end
end
