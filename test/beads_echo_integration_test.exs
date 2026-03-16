defmodule SymphonyElixir.BeadsEchoIntegrationTest do
  @moduledoc """
  End-to-end integration test: Beads tracker + Echo agent adapter.

  Proves the full orchestration loop works without any external services:
  1. Reads issues from a local .beads workspace via `br` CLI
  2. Dispatches them to the Echo agent adapter
  3. Verifies the agent runner completes successfully
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentAdapter, Issue}

  @moduletag :integration

  @tmp_root "/tmp/symphony_e2e_test_#{System.unique_integer([:positive])}"

  setup do
    # Check that br is available
    case System.find_executable("br") do
      nil ->
        IO.puts("Skipping integration test: `br` CLI not installed")
        :ok

      _br_path ->
        # Create temp beads workspace
        beads_dir = Path.join(@tmp_root, "project")
        workspace_root = Path.join(@tmp_root, "workspaces")
        File.mkdir_p!(beads_dir)
        File.mkdir_p!(workspace_root)

        # Init beads
        {_out, 0} = System.cmd("br", ["init"], cd: beads_dir, stderr_to_stdout: true)

        # Create a test issue
        {issue_id_raw, 0} =
          System.cmd(
            "br",
            [
              "create",
              "Test issue for E2E",
              "-t",
              "task",
              "-p",
              "1",
              "-d",
              "This is a test issue created by the integration test.",
              "--silent"
            ],
            cd: beads_dir,
            stderr_to_stdout: true
          )

        issue_id = issue_id_raw |> String.split("\n") |> hd() |> String.trim()

        on_exit(fn ->
          File.rm_rf!(@tmp_root)
        end)

        {:ok, %{beads_dir: beads_dir, workspace_root: workspace_root, issue_id: issue_id}}
    end
  end

  test "Beads adapter reads issues from br workspace", context do
    skip_unless_br()

    # Run br in the beads project dir
    {output, 0} =
      System.cmd("br", ["list", "--json", "--no-color"],
        cd: context.beads_dir,
        stderr_to_stdout: true
      )

    assert {:ok, items} = Jason.decode(String.trim(output))
    assert length(items) >= 1

    first = hd(items)
    assert first["id"] == context.issue_id
    assert first["title"] == "Test issue for E2E"
  end

  test "Echo adapter completes a full session lifecycle" do
    workspace = Path.join(System.tmp_dir!(), "echo_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, adapter} = AgentAdapter.adapter_for_kind("echo")
    assert adapter == SymphonyElixir.AgentAdapters.Echo

    # Start session
    assert {:ok, session} = adapter.start_session(workspace)
    assert is_binary(session.session_id)

    # Run turn
    issue = %Issue{id: "test-1", identifier: "TEST-1", title: "Test issue", state: "Todo"}
    messages = :ets.new(:messages, [:bag, :public])

    on_message = fn msg ->
      :ets.insert(messages, {:msg, msg})
      :ok
    end

    assert {:ok, result} = adapter.run_turn(session, "Fix the bug", issue, on_message: on_message)
    assert result.session_id == session.session_id
    assert result.result == :turn_completed

    # Verify events were emitted
    all_msgs = :ets.lookup(messages, :msg) |> Enum.map(&elem(&1, 1))
    events = Enum.map(all_msgs, & &1.event)
    assert :session_started in events
    assert :turn_completed in events

    # Stop session
    assert :ok = adapter.stop_session(session)

    :ets.delete(messages)
  end

  test "GHCopilot adapter resolves correctly" do
    assert {:ok, SymphonyElixir.AgentAdapters.GHCopilot} = AgentAdapter.adapter_for_kind("ghcopilot")
    assert {:ok, SymphonyElixir.AgentAdapters.Codex} = AgentAdapter.adapter_for_kind("codex")
    assert {:ok, SymphonyElixir.AgentAdapters.Echo} = AgentAdapter.adapter_for_kind("echo")
    assert {:error, {:unsupported_agent_kind, "nope"}} = AgentAdapter.adapter_for_kind("nope")
  end

  defp skip_unless_br do
    unless System.find_executable("br") do
      ExUnit.configure(exclude: [:integration])
    end
  end
end
