defmodule SymphonyElixir.AgentAdapters.Claude do
  @moduledoc """
  Agent adapter for Claude Code via jido_claude.

  Status: stub — not yet implemented.
  """

  @behaviour SymphonyElixir.AgentAdapter

  @impl true
  def start_session(_workspace, _opts \\ []) do
    {:error, :claude_adapter_not_implemented}
  end

  @impl true
  def run_turn(_session, _prompt, _issue, _opts \\ []) do
    {:error, :claude_adapter_not_implemented}
  end

  @impl true
  def stop_session(_session), do: :ok

  @impl true
  def tool_specs, do: []
end
