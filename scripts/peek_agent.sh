#!/usr/bin/env bash
# Peek at a specific agent's recent activity via BEAM introspection.
# Usage: scripts/peek_agent.sh <issue-id> [num-events]
set -euo pipefail

ISSUE_ID="${1:?Usage: peek_agent.sh <issue-id> [num-events]}"
NUM="${2:-20}"
SNAME="${DEV_NODE_NAME:-elixir}"
COOKIE="${DEV_NODE_COOKIE:-devcookie}"
HOSTNAME="$(hostname -s)"
TARGET="${SNAME}@${HOSTNAME}"

elixir --sname "peek_$$" --cookie "$COOKIE" -e "
  target = :\"${TARGET}\"
  true = Node.connect(target)

  issue_id = \"${ISSUE_ID}\"
  num = ${NUM}

  events = :rpc.call(target, SymphonyElixir.AgentEventStore, :events, [issue_id])
  total = length(events)
  recent = Enum.take(events, -num)

  IO.puts(\"=== #{issue_id}: #{total} total events, showing last #{num} ===\")
  IO.puts(\"\")

  for e <- recent do
    ts = case e[:timestamp] do
      %DateTime{} = dt -> Calendar.strftime(dt, \"%H:%M:%S\")
      _ -> \"??:??:??\"
    end

    case e[:event] do
      :agent_text ->
        text = String.slice(e[:text] || \"\", 0, 120) |> String.replace(~r/[\\n\\r]+/, \" \")
        IO.puts(\"  #{ts} 💬 #{text}\")

      :agent_thought ->
        text = String.slice(e[:text] || \"\", 0, 120) |> String.replace(~r/[\\n\\r]+/, \" \")
        IO.puts(\"  #{ts} 💭 #{text}\")

      :tool_call ->
        name = e[:tool_name] || \"?\"
        args = String.slice(inspect(e[:args] || \"\"), 0, 80)
        IO.puts(\"  #{ts} 🔧 #{name} #{args}\")

      :tool_call_completed ->
        result = String.slice(to_string(e[:result] || \"\"), 0, 80)
        IO.puts(\"  #{ts} ✅ tool done: #{result}\")

      :session_started ->
        IO.puts(\"  #{ts} 🚀 session #{e[:session_id]}\")

      :turn_completed ->
        IO.puts(\"  #{ts} ✅ turn completed\")

      :turn_ended_with_error ->
        IO.puts(\"  #{ts} ❌ error: #{inspect(e[:reason], limit: 100)}\")

      :usage ->
        IO.puts(\"  #{ts} 📊 model=#{e[:model]} in=#{e[:input_tokens]} out=#{e[:output_tokens]}\")

      other ->
        IO.puts(\"  #{ts} · #{other}\")
    end
  end

  System.halt(0)
" 2>&1
