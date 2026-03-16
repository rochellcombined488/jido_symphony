defmodule SymphonyElixir.AgentAdapter do
  @moduledoc """
  Behaviour defining the contract for coding agent backends.

  Each adapter wraps one agent's protocol (Codex app-server, GitHub Copilot ACP,
  Claude CLI, etc.) behind a uniform session/turn lifecycle that the orchestrator
  and agent runner consume.
  """

  alias SymphonyElixir.Issue

  @type session :: map()
  @type turn_result :: map()
  @type on_message :: (map() -> :ok)

  @doc """
  Start a new agent session in the given workspace directory.

  Returns an opaque session map that will be passed to `run_turn/4` and
  `stop_session/1`.
  """
  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @doc """
  Execute a single turn inside an existing session.

  Options:
    - `:on_message` — callback receiving normalized agent events
    - `:tool_executor` — function handling client-side tool calls
  """
  @callback run_turn(session(), prompt :: String.t(), issue :: Issue.t(), opts :: keyword()) ::
              {:ok, turn_result()} | {:error, term()}

  @doc """
  Terminate the agent session and release its resources.
  """
  @callback stop_session(session()) :: :ok

  @doc """
  Return tool specifications that this adapter's agent understands.

  The orchestrator registers these tools with the agent at session start.
  """
  @callback tool_specs() :: [map()]

  @doc """
  Resolve the adapter module for a given `agent.kind` string.
  """
  @spec adapter_for_kind(String.t()) :: {:ok, module()} | {:error, {:unsupported_agent_kind, String.t()}}
  def adapter_for_kind(kind) when is_binary(kind) do
    case String.trim(kind) |> String.downcase() do
      "codex" -> {:ok, SymphonyElixir.AgentAdapters.Codex}
      "ghcopilot" -> {:ok, SymphonyElixir.AgentAdapters.GHCopilot}
      "claude" -> {:ok, SymphonyElixir.AgentAdapters.Claude}
      "gemini" -> {:ok, SymphonyElixir.AgentAdapters.Gemini}
      "echo" -> {:ok, SymphonyElixir.AgentAdapters.Echo}
      other -> {:error, {:unsupported_agent_kind, other}}
    end
  end
end
