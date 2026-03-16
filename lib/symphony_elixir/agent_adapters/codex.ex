defmodule SymphonyElixir.AgentAdapters.Codex do
  @moduledoc """
  Agent adapter wrapping the existing Codex app-server integration.

  Delegates to `SymphonyElixir.Codex.AppServer` — no new Codex logic,
  just conforming the existing implementation to the `AgentAdapter` behaviour.
  """

  @behaviour SymphonyElixir.AgentAdapter

  alias SymphonyElixir.Codex.{AppServer, DynamicTool}

  @impl true
  def start_session(workspace, _opts \\ []) do
    AppServer.start_session(workspace)
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    AppServer.run_turn(session, prompt, issue, opts)
  end

  @impl true
  def stop_session(session) do
    AppServer.stop_session(session)
  end

  @impl true
  def tool_specs do
    DynamicTool.tool_specs()
  end
end
