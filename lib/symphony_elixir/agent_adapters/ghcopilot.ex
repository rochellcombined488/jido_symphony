defmodule SymphonyElixir.AgentAdapters.GHCopilot do
  @moduledoc """
  Agent adapter for GitHub Copilot CLI via the Server protocol.

  Uses `Jido.GHCopilot.Server.Connection` which handles LSP-framed
  JSON-RPC 2.0, permission auto-approval, and structured event streaming.
  Gives richer data than ACP: tool names/args/results, token usage, cost.
  """

  @behaviour SymphonyElixir.AgentAdapter

  require Logger
  alias Jido.GHCopilot.Server.Connection
  alias SymphonyElixir.Codex.DynamicTool

  @prompt_timeout_ms 3_600_000

  @impl true
  def start_session(workspace, _opts \\ []) do
    expanded = Path.expand(workspace)
    cli_args = ["--allow-all-tools", "--allow-all-paths", "--allow-all-urls"]

    case Connection.start_link(cli_args: cli_args, cwd: expanded) do
      {:ok, conn} ->
        case Connection.create_session(conn) do
          {:ok, session_id} ->
            :ok = Connection.subscribe(conn, session_id)
            Logger.info("GHCopilot server session #{session_id} in #{expanded}")
            {:ok, %{conn: conn, session_id: session_id, workspace: expanded}}

          {:error, reason} ->
            Connection.stop(conn)
            {:error, {:session_create_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    %{conn: conn, session_id: session_id} = session
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)

    emit(on_message, :session_started, %{session_id: session_id})

    case Connection.send_prompt(conn, session_id, prompt, %{}, @prompt_timeout_ms) do
      {:ok, _message_id} ->
        case event_loop(session_id, on_message) do
          {:ok, result} ->
            Logger.info("Copilot completed for #{issue_label(issue)}")
            {:ok, %{result: result, session_id: session_id, thread_id: session_id, turn_id: "turn-1"}}

          {:error, reason} ->
            emit(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason})
            {:error, reason}
        end

      {:error, reason} ->
        emit(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason})
        {:error, reason}
    end
  end

  @impl true
  def stop_session(%{conn: conn, session_id: sid}) do
    Connection.unsubscribe(conn, sid)
    Connection.destroy_session(conn, sid)
    Connection.stop(conn)
    :ok
  rescue
    _ -> :ok
  end

  def stop_session(_), do: :ok

  @impl true
  def tool_specs, do: DynamicTool.tool_specs()

  # -- Event loop --

  defp event_loop(session_id, on_message) do
    receive do
      {:server_event, %{type: "session.idle"}} ->
        {:ok, :turn_completed}

      {:server_event, %{type: type, data: data}} ->
        handle_event(type, data, on_message)
        event_loop(session_id, on_message)

      {:server_tool_call, %{tool_name: tool_name, arguments: arguments, request_id: _req_id}} ->
        Logger.info("GHCopilot external tool call: #{tool_name}")
        result = DynamicTool.execute(tool_name, arguments)
        # Connection auto-handles the response for permission requests;
        # for custom tools we'd call Connection.respond_to_tool_call
        emit(on_message, :tool_call_completed, %{
          tool_call_id: "dynamic-#{tool_name}",
          tool_name: tool_name,
          result: inspect(result, limit: 200)
        })

        event_loop(session_id, on_message)
    after
      @prompt_timeout_ms -> {:error, :prompt_timeout}
    end
  end

  defp handle_event("assistant.message", data, on_message) do
    text = data["content"] || data["chunkContent"] || ""
    if text != "", do: emit(on_message, :agent_text, %{text: text})
  end

  defp handle_event("assistant.intent", data, on_message) do
    text = data["content"] || data["text"] || ""
    if text != "", do: emit(on_message, :agent_thought, %{text: text})
  end

  defp handle_event("tool.execution_start", data, on_message) do
    tool_name = data["toolName"] || data["name"] || ""
    tool_call_id = data["toolCallId"] || ""
    title = data["title"] || ""
    args = data["arguments"] || data["input"] || ""

    args_str =
      cond do
        is_binary(args) -> args
        is_map(args) -> Jason.encode!(args) |> String.slice(0, 2000)
        true -> inspect(args)
      end

    emit(on_message, :tool_call, %{
      tool_name: tool_name,
      tool_call_id: tool_call_id,
      title: title,
      args: args_str
    })
  end

  defp handle_event("tool.execution_complete", data, on_message) do
    tool_call_id = data["toolCallId"] || ""
    raw_result = data["result"] || data["output"] || ""

    result_str = extract_tool_result(raw_result)

    emit(on_message, :tool_call_completed, %{
      tool_call_id: tool_call_id,
      result: result_str,
      success: data["success"],
      error: data["error"]
    })
  end

  defp handle_event("assistant.usage", data, on_message) do
    emit(on_message, :usage, %{
      model: data["model"],
      input_tokens: data["inputTokens"],
      output_tokens: data["outputTokens"],
      cost: data["cost"]
    })
  end

  defp handle_event("session.error", data, on_message) do
    emit(on_message, :turn_ended_with_error, %{reason: data["message"] || inspect(data)})
  end

  defp handle_event(_type, _data, _on_message), do: :ok

  # -- Helpers --

  defp emit(on_message, event, details) when is_function(on_message) do
    on_message.(Map.merge(details, %{event: event, timestamp: DateTime.utc_now()}))
  end

  defp emit(_, _, _), do: :ok

  defp issue_label(%{identifier: id}) when is_binary(id), do: id
  defp issue_label(%{id: id}), do: "issue=#{id}"

  # Server protocol wraps tool results in {"content": "...", "detailedContent": "..."}
  defp extract_tool_result(result) when is_map(result) do
    (result["content"] || result["detailedContent"] || "") |> to_string() |> String.slice(0, 4000)
  end

  defp extract_tool_result(result) when is_binary(result) do
    # May be a JSON string with the envelope
    case Jason.decode(result) do
      {:ok, %{"content" => content}} -> to_string(content) |> String.slice(0, 4000)
      _ -> String.slice(result, 0, 4000)
    end
  end

  defp extract_tool_result(result), do: inspect(result, limit: 200)
end
