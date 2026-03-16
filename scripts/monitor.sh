#!/usr/bin/env bash
# Monitor running Symphony agents via BEAM introspection + workspace git state.
# Usage: scripts/monitor.sh [--loop]
set -euo pipefail

SNAME="${DEV_NODE_NAME:-elixir}"
COOKIE="${DEV_NODE_COOKIE:-devcookie}"
HOSTNAME="$(hostname -s)"
TARGET="${SNAME}@${HOSTNAME}"

rpc() {
  elixir --sname "mon_$$" --cookie "$COOKIE" -e "
    target = :\"${TARGET}\"
    case Node.connect(target) do
      true -> :ok
      _ ->
        IO.puts(\"ERROR: Cannot connect to #{target}\")
        System.halt(1)
    end
    $1
    System.halt(0)
  " 2>&1
}

print_orchestrator() {
  rpc '
    state = :rpc.call(target, GenServer, :call, [SymphonyElixir.Orchestrator, :snapshot, 15_000])
    running = Map.get(state, :running, [])
    retrying = Map.get(state, :retrying, [])
    totals = Map.get(state, :codex_totals, %{})

    IO.puts("╭─ ORCHESTRATOR")
    IO.puts("│ Running: #{length(running)}  Retrying: #{length(retrying)}")
    IO.puts("│ Tokens: in #{totals[:input_tokens] || 0} | out #{totals[:output_tokens] || 0} | total #{totals[:total_tokens] || 0}")
    IO.puts("├─ Running agents")

    for r <- Enum.sort_by(running, & &1.issue_id) do
      elapsed = trunc(r.runtime_seconds)
      mins = div(elapsed, 60)
      secs = rem(elapsed, 60)
      title = String.slice(r[:title] || "?", 0, 40)
      IO.puts("│  #{r.issue_id} │ #{title} │ turns=#{r.turn_count} │ #{mins}m#{secs}s │ event=#{r.last_codex_event || "none"}")

      events = :rpc.call(target, SymphonyElixir.AgentEventStore, :events, [r.issue_id])
      tool_calls = Enum.count(events, fn e -> e[:event] == :tool_call end)
      completed = Enum.count(events, fn e -> e[:event] == :tool_call_completed end)
      pending = tool_calls - completed
      text_chars = Enum.reduce(events, 0, fn e, acc ->
        if e[:event] == :agent_text, do: acc + String.length(e[:text] || ""), else: acc
      end)
      IO.puts("│           #{length(events)} events │ #{tool_calls} tools (#{pending} pending) │ #{text_chars} chars text")
    end

    if length(retrying) > 0 do
      IO.puts("├─ Retrying")
      for r <- Enum.sort_by(retrying, & &1.issue_id) do
        IO.puts("│  #{r.issue_id} │ attempt=#{r.attempt} │ due=#{trunc(r.due_in_ms / 1000)}s │ #{r.error}")
      end
    end

    IO.puts("╰─")
  '
}

print_workspaces() {
  WORKSPACE_ROOT="${SYMPHONY_WORKSPACE_ROOT:-$HOME/code/symphony-demo-workspaces}"
  echo "╭─ WORKSPACES ($WORKSPACE_ROOT)"

  for d in "$WORKSPACE_ROOT"/bd-*/; do
    [ -d "$d" ] || continue
    id=$(basename "$d")
    if [ -d "$d/.git" ]; then
      branch=$(cd "$d" && git branch --show-current 2>/dev/null || echo "detached")
      ahead=$(cd "$d" && git rev-list --count master..HEAD 2>/dev/null || echo "?")
      last_msg=$(cd "$d" && git --no-pager log --format="%s" -1 2>/dev/null || echo "?")
      last_msg="${last_msg:0:60}"
      dirty=$(cd "$d" && git status --porcelain 2>/dev/null | wc -l)
      echo "│  $id │ $branch │ +${ahead} commits │ ${dirty} dirty │ $last_msg"
    else
      echo "│  $id │ (no git repo)"
    fi
  done

  echo "╰─"
}

print_main_repo() {
  DEMO_REPO="${SYMPHONY_DEMO_REPO:-$HOME/github/chgeuer/symphony_demo}"
  echo "╭─ MAIN REPO ($DEMO_REPO)"
  echo "│ Branch: $(cd "$DEMO_REPO" && git branch --show-current)"
  echo "│ HEAD: $(cd "$DEMO_REPO" && git --no-pager log --oneline -1)"
  echo "│ Dirty: $(cd "$DEMO_REPO" && git status --porcelain | wc -l) files"

  branches=$(cd "$DEMO_REPO" && git branch --list "symphony/*" 2>/dev/null)
  if [ -n "$branches" ]; then
    echo "├─ Feature branches"
    while IFS= read -r b; do
      b=$(echo "$b" | xargs)
      ahead=$(cd "$DEMO_REPO" && git rev-list --count "master..$b" 2>/dev/null || echo "?")
      echo "│  $b (+${ahead})"
    done <<< "$branches"
  fi

  echo "╰─"
}

run_once() {
  echo ""
  echo "═══ Symphony Monitor $(date '+%H:%M:%S') ═══"
  echo ""
  print_orchestrator
  echo ""
  print_workspaces
  echo ""
  print_main_repo
  echo ""
}

if [ "${1:-}" = "--loop" ]; then
  while true; do
    clear
    run_once
    sleep "${2:-15}"
  done
else
  run_once
fi
