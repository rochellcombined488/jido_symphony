#!/usr/bin/env bash
set -euo pipefail
#
# Introspect running Symphony BEAM node — shows what each Copilot agent
# is actually doing: workspace contents, port I/O, process state.
#
# Usage: scripts/introspect.sh [command]
#   status   - Overview of orchestrator state
#   agents   - Deep view of each running agent worker
#   prompts  - Show what prompt was sent to each agent
#   workspaces - List workspace contents
#   all      - Everything

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="${DEV_NODE_NAME:-jido_symphony}"
COOKIE="${DEV_NODE_COOKIE:-devcookie}"
HOSTNAME="$(hostname -s)"
FQDN="${APP_NAME}@${HOSTNAME}"

rpc_eval() {
  local file="$1"
  cd "$PROJECT_DIR"
  mise exec -- elixir --sname "introspect_$$" --cookie "$COOKIE" --hidden --no-halt -e "
    target = :\"${FQDN}\"
    true = Node.connect(target)
    code = File.read!(\"${file}\")
    {result, _binding} = :rpc.call(target, Code, :eval_string, [code])
    System.halt(0)
  " 2>/dev/null
}

case "${1:-status}" in
  status)
    cat > /tmp/_introspect.exs << 'ELIXIR'
state = :sys.get_state(SymphonyElixir.Orchestrator)

IO.puts("╔══════════════════════════════════════════════════════╗")
IO.puts("║           SYMPHONY ORCHESTRATOR STATUS               ║")
IO.puts("╚══════════════════════════════════════════════════════╝")
IO.puts("")
IO.puts("  Running agents:  #{map_size(state.running)}/#{state.max_concurrent_agents}")
IO.puts("  Completed:       #{MapSet.size(state.completed)}")
IO.puts("  Retry queue:     #{map_size(state.retry_attempts)}")
IO.puts("  Poll interval:   #{state.poll_interval_ms}ms")
IO.puts("")

if map_size(state.running) > 0 do
  IO.puts("  ┌─────────┬──────────────────────────────────────────┬────────┬──────────────────────┐")
  IO.puts("  │ ID      │ Title                                    │ Turn   │ Last Event           │")
  IO.puts("  ├─────────┼──────────────────────────────────────────┼────────┼──────────────────────┤")

  for {id, entry} <- state.running do
    elapsed = DateTime.diff(DateTime.utc_now(), entry.started_at, :second)
    title = String.slice(entry.issue.title, 0, 38) |> String.pad_trailing(38)
    turn_info = "#{entry.turn_count} (#{elapsed}s)" |> String.pad_trailing(6)
    event = to_string(entry.last_codex_event) |> String.slice(0, 20) |> String.pad_trailing(20)
    IO.puts("  │ #{String.pad_trailing(id, 7)} │ #{title} │ #{turn_info} │ #{event} │")
  end

  IO.puts("  └─────────┴──────────────────────────────────────────┴────────┴──────────────────────┘")
end

if MapSet.size(state.completed) > 0 do
  IO.puts("\n  Completed: #{MapSet.to_list(state.completed) |> Enum.join(", ")}")
end

if map_size(state.retry_attempts) > 0 do
  IO.puts("\n  Retries:")
  for {id, entry} <- state.retry_attempts do
    IO.puts("    #{id}: attempt #{entry.attempt}, error: #{inspect(entry.error, limit: 80)}")
  end
end

:ok
ELIXIR
    rpc_eval /tmp/_introspect.exs
    ;;

  agents)
    cat > /tmp/_introspect.exs << 'ELIXIR'
children = Task.Supervisor.children(SymphonyElixir.TaskSupervisor)
state = :sys.get_state(SymphonyElixir.Orchestrator)

IO.puts("\n=== AGENT WORKER DETAILS (#{length(children)} workers) ===\n")

for pid <- children do
  info = Process.info(pid, [:current_function, :message_queue_len, :links, :current_stacktrace])
  links = Keyword.get(info, :links, [])
  stack = Keyword.get(info, :current_stacktrace, [])
  func = Keyword.get(info, :current_function)

  # Find which issue this worker is handling
  issue_entry = Enum.find_value(state.running, fn {_id, e} -> if e.pid == pid, do: e end)

  ports = Enum.flat_map(links, fn
    p when is_port(p) ->
      pi = Port.info(p) || []
      os_pid = Keyword.get(pi, :os_pid)
      input = Keyword.get(pi, :input, 0)
      output = Keyword.get(pi, :output, 0)
      [{os_pid, input, output}]
    _ -> []
  end)

  IO.puts("── Worker #{inspect(pid)} ──")

  if issue_entry do
    IO.puts("  Issue:     #{issue_entry.identifier} — #{issue_entry.issue.title}")
    IO.puts("  Session:   #{issue_entry.session_id}")
    IO.puts("  Turn:      #{issue_entry.turn_count}")
    IO.puts("  Last evt:  #{issue_entry.last_codex_event} @ #{issue_entry.last_codex_timestamp}")
  end

  IO.puts("  Function:  #{inspect(func)}")
  IO.puts("  Msg queue: #{Keyword.get(info, :message_queue_len)}")

  for {os_pid, input_bytes, output_bytes} <- ports do
    IO.puts("  Port:      OS pid #{os_pid}, sent #{input_bytes} bytes → copilot, received #{output_bytes} bytes ← copilot")

    # Check if the copilot process is still alive
    case System.cmd("ps", ["-p", to_string(os_pid), "-o", "etime,stat", "--no-headers"], stderr_to_stdout: true) do
      {ps, 0} -> IO.puts("  OS proc:   #{String.trim(ps)}")
      _ -> IO.puts("  OS proc:   DEAD")
    end
  end

  IO.puts("  Stack:")
  for frame <- Enum.take(stack, 3) do
    IO.puts("    #{inspect(frame)}")
  end

  IO.puts("")
end

:ok
ELIXIR
    rpc_eval /tmp/_introspect.exs
    ;;

  workspaces)
    echo "=== WORKSPACE CONTENTS ==="
    echo ""
    for ws in /tmp/symphony_e2e_workspaces/*/; do
      id=$(basename "$ws")
      echo "── $id ──"
      if [ -f "$ws/.git/HEAD" ]; then
        echo "  git: $(cat "$ws/.git/HEAD")"
      else
        echo "  git: NOT A GIT REPO"
      fi
      echo "  files: $(find "$ws" -maxdepth 1 -not -name '.*' -not -path "$ws" | wc -l) top-level"
      ls -1 "$ws" 2>/dev/null | head -10 | sed 's/^/    /'
      echo ""
    done
    ;;

  prompts)
    cat > /tmp/_introspect.exs << 'ELIXIR'
state = :sys.get_state(SymphonyElixir.Orchestrator)

IO.puts("\n=== PROMPTS SENT TO AGENTS ===\n")

for {id, entry} <- state.running do
  IO.puts("── #{id}: #{entry.issue.title} ──")
  prompt = SymphonyElixir.PromptBuilder.build_prompt(entry.issue)
  IO.puts(prompt)
  IO.puts("\n" <> String.duplicate("─", 60) <> "\n")
end

:ok
ELIXIR
    rpc_eval /tmp/_introspect.exs
    ;;

  all)
    "$0" status
    echo ""
    "$0" agents
    echo ""
    "$0" workspaces
    ;;

  *)
    echo "Usage: scripts/introspect.sh {status|agents|workspaces|prompts|all}"
    ;;
esac
