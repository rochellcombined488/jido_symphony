defmodule SymphonyElixir.BacklogPlanner do
  @moduledoc """
  Uses an LLM (via GHCopilot Connection) to generate a project backlog
  from a natural-language description.

  Sends a structured prompt, parses the JSON response, and creates
  issues in the tracker via `br create`.
  """

  require Logger

  alias Jido.GHCopilot.Server.Connection
  alias SymphonyElixir.Tracker

  @prompt_timeout_ms 300_000
  @event_timeout_ms 300_000

  @doc """
  Generate a backlog of issues from a project description.

  Starts a one-shot GHCopilot session, sends the planning prompt,
  parses the JSON issue list, and creates each issue via the tracker.

  ## Options

    * `:repo_path` — path to the project repo (used as cwd for the LLM)
    * `:description` — what to build
    * `:tech_stack` — tech-stack context (e.g., "Elixir + Phoenix + LiveView")
    * `:max_issues` — cap on number of issues to create (default: 15)

  Returns `{:ok, issues_created}` or `{:error, reason}`.
  """
  @spec plan(keyword()) :: {:ok, [map()]} | {:error, term()}
  def plan(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path) |> Path.expand()
    description = Keyword.fetch!(opts, :description)
    tech_stack = Keyword.get(opts, :tech_stack, "")
    max_issues = Keyword.get(opts, :max_issues, 15)

    prompt = build_planner_prompt(description, tech_stack, max_issues)

    Logger.info("BacklogPlanner: starting LLM session for #{repo_path}")

    with {:ok, session} <- start_session(repo_path),
         {:ok, text} <- run_prompt(session, prompt),
         :ok <- stop_session(session),
         {:ok, issues} <- parse_issues(text, max_issues) do
      create_issues(issues)
    else
      {:error, reason} ->
        Logger.error("BacklogPlanner failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # -- LLM Session --

  defp start_session(cwd) do
    cli_args = ["--allow-all-tools", "--allow-all-paths", "--allow-all-urls"]

    case Connection.start_link(cli_args: cli_args, cwd: cwd) do
      {:ok, conn} ->
        case Connection.create_session(conn) do
          {:ok, session_id} ->
            :ok = Connection.subscribe(conn, session_id)
            {:ok, %{conn: conn, session_id: session_id}}

          {:error, reason} ->
            Connection.stop(conn)
            {:error, {:session_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  defp run_prompt(%{conn: conn, session_id: sid}, prompt) do
    case Connection.send_prompt(conn, sid, prompt, %{}, @prompt_timeout_ms) do
      {:ok, _msg_id} ->
        collect_response()

      {:error, reason} ->
        {:error, {:prompt_send_failed, reason}}
    end
  end

  defp stop_session(%{conn: conn, session_id: sid}) do
    Connection.unsubscribe(conn, sid)
    Connection.destroy_session(conn, sid)
    Connection.stop(conn)
    :ok
  rescue
    _ -> :ok
  end

  # Collect all assistant.message chunks until session.idle
  defp collect_response(acc \\ "") do
    receive do
      {:server_event, %{type: "session.idle"}} ->
        {:ok, acc}

      {:server_event, %{type: "assistant.message", data: data}} ->
        text = data["content"] || data["chunkContent"] || ""
        collect_response(acc <> text)

      {:server_event, %{type: "session.error", data: data}} ->
        {:error, {:session_error, data["message"] || inspect(data)}}

      {:server_event, %{type: _other}} ->
        # Ignore tool calls, intents, usage etc.
        collect_response(acc)
    after
      @event_timeout_ms -> {:error, :response_timeout}
    end
  end

  # -- Prompt --

  defp build_planner_prompt(description, tech_stack, max_issues) do
    tech_section =
      if tech_stack != "" do
        "\nTech stack: #{tech_stack}\n"
      else
        ""
      end

    """
    You are a software project planner. Given the project description below,
    create a backlog of #{max_issues} or fewer small, focused issues.

    Project description:
    #{description}
    #{tech_section}
    Requirements for issues:
    - Each issue should be independently implementable
    - Order issues by dependency (foundational issues first, like project setup)
    - The first issue should always be project initialization/scaffolding
    - Keep scope small: each issue = 1 feature or 1 component
    - Include descriptive titles and detailed descriptions
    - Descriptions should include acceptance criteria
    - Use types: task, feature, or bug

    Return ONLY a JSON array with no other text. Each element:
    ```json
    [
      {
        "title": "Set up Phoenix project with LiveView",
        "description": "Initialize a new Phoenix project with LiveView support. Include...",
        "type": "task",
        "priority": 1
      }
    ]
    ```

    Priority scale: 0 = urgent, 1 = high, 2 = medium, 3 = low.
    Return ONLY the JSON array, no markdown fences, no explanation.
    """
  end

  # -- Parse --

  defp parse_issues(text, max_issues) do
    # Strip markdown code fences if present
    cleaned =
      text
      |> String.replace(~r/```json\s*\n?/, "")
      |> String.replace(~r/```\s*\n?/, "")
      |> String.trim()

    # Find the JSON array
    case extract_json_array(cleaned) do
      {:ok, items} when is_list(items) ->
        issues =
          items
          |> Enum.take(max_issues)
          |> Enum.map(fn item ->
            %{
              title: item["title"] || "Untitled",
              description: item["description"],
              type: item["type"] || "task",
              priority: item["priority"]
            }
          end)

        {:ok, issues}

      {:ok, _} ->
        {:error, :expected_json_array}

      {:error, reason} ->
        Logger.error("BacklogPlanner: failed to parse JSON: #{inspect(reason)}\nRaw: #{String.slice(text, 0, 500)}")
        {:error, {:json_parse_failed, reason}}
    end
  end

  defp extract_json_array(text) do
    # Find first '[' and try to parse from there
    case :binary.match(text, "[") do
      {pos, _} ->
        candidate = binary_part(text, pos, byte_size(text) - pos)
        Jason.decode(candidate)

      :nomatch ->
        {:error, :no_json_array_found}
    end
  end

  # -- Create issues in tracker --

  defp create_issues(issues) do
    results =
      Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
        case Tracker.create_issue(issue) do
          {:ok, created} ->
            Logger.info("BacklogPlanner: created issue #{created.id}: #{issue.title}")
            {:cont, {:ok, [created | acc]}}

          {:error, reason} ->
            Logger.error("BacklogPlanner: failed to create issue '#{issue.title}': #{inspect(reason)}")
            # Continue creating remaining issues even if one fails
            {:cont, {:ok, acc}}
        end
      end)

    case results do
      {:ok, created} ->
        created = Enum.reverse(created)
        Logger.info("BacklogPlanner: created #{length(created)} issues")
        {:ok, created}
    end
  end
end
