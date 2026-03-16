defmodule SymphonyElixir.AgentAdapters.Echo do
  @moduledoc """
  Minimal agent adapter for testing the orchestration loop.

  Logs the prompt and returns success after a brief delay, without
  spawning any external process. Useful for validating the Beads tracker
  integration and multi-turn loop without requiring a real coding agent.
  """

  @behaviour SymphonyElixir.AgentAdapter

  require Logger

  @impl true
  def start_session(workspace, _opts \\ []) do
    session_id = "echo-#{System.unique_integer([:positive])}"
    Logger.info("Echo adapter: started session #{session_id} in #{workspace}")
    {:ok, %{session_id: session_id, workspace: workspace}}
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    %{session_id: session_id} = session

    on_message.(%{
      event: :session_started,
      session_id: session_id,
      thread_id: session_id,
      turn_id: "turn-1",
      timestamp: DateTime.utc_now()
    })

    identifier = Map.get(issue, :identifier) || Map.get(issue, :id, "unknown")
    Logger.info("Echo adapter: running turn for #{identifier}")
    Logger.info("Echo adapter: prompt length=#{String.length(prompt)} chars")

    # Simulate brief processing
    Process.sleep(100)

    on_message.(%{
      event: :turn_completed,
      session_id: session_id,
      timestamp: DateTime.utc_now()
    })

    {:ok,
     %{
       result: :turn_completed,
       session_id: session_id,
       thread_id: session_id,
       turn_id: "turn-1"
     }}
  end

  @impl true
  def stop_session(%{session_id: session_id}) do
    Logger.info("Echo adapter: stopped session #{session_id}")
    :ok
  end

  def stop_session(_), do: :ok

  @impl true
  def tool_specs, do: []
end
