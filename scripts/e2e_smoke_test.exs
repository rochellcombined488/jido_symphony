#!/usr/bin/env elixir

# E2E smoke test: Beads tracker + Echo adapter against symphony_demo
#
# Set workflow file path BEFORE the app starts (Application.start)
# since WorkflowStore reads it on init.

beads_root = System.get_env("BEADS_ROOT", "/home/chgeuer/github/chgeuer/symphony_demo")
workflow_path = System.get_env("WORKFLOW_PATH", "/tmp/symphony_e2e_workflow.md")

# These must be set before the app's supervision tree starts
Application.put_env(:symphony_elixir, :beads_root, beads_root)
Application.put_env(:symphony_elixir, :workflow_file_path, workflow_path)

IO.puts("=== Symphony E2E Smoke Test ===")
IO.puts("  Beads root:    #{beads_root}")
IO.puts("  Workflow path: #{workflow_path}")
IO.puts("")

# Config is now loaded from the workflow file
IO.puts("✓ Config loaded")
IO.puts("  tracker.kind: #{SymphonyElixir.Config.tracker_kind()}")
IO.puts("  agent.kind:   #{SymphonyElixir.Config.agent_kind()}")
IO.puts("")

# Fetch issues from beads tracker
IO.puts("--- Fetching candidate issues from #{beads_root}/.beads ---")
{:ok, issues} = SymphonyElixir.Tracker.Beads.fetch_candidate_issues()
IO.puts("✓ Found #{length(issues)} candidate issues\n")

for issue <- Enum.take(issues, 8) do
  IO.puts("  #{String.pad_trailing(issue.identifier || issue.id, 10)} [#{String.pad_trailing(issue.state, 12)}] #{issue.title}")
end

IO.puts("")

# Resolve adapter
{:ok, adapter} = SymphonyElixir.AgentAdapter.adapter_for_kind(SymphonyElixir.Config.agent_kind())
IO.puts("✓ Adapter resolved: #{inspect(adapter)}\n")

# Run first issue through the adapter
first_issue = hd(issues)
IO.puts("--- Running adapter for: #{first_issue.identifier || first_issue.id} ---")
IO.puts("  Title: #{first_issue.title}")

workspace_key =
  (first_issue.identifier || first_issue.id)
  |> String.replace(~r/[^A-Za-z0-9._-]/, "_")

workspace = Path.join(SymphonyElixir.Config.workspace_root(), workspace_key)
File.mkdir_p!(workspace)

# Start session
{:ok, session} = adapter.start_session(workspace)
IO.puts("  ✓ Session started: #{session.session_id}")

# Build prompt
prompt = SymphonyElixir.PromptBuilder.build_prompt(first_issue)
IO.puts("  ✓ Prompt built (#{String.length(prompt)} chars)")

# Run turn
{:ok, result} =
  adapter.run_turn(session, prompt, first_issue,
    on_message: fn msg ->
      IO.puts("    → event: #{msg.event}")
    end
  )

IO.puts("  ✓ Turn completed: #{inspect(result.result)}")

# Stop session
adapter.stop_session(session)
IO.puts("  ✓ Session stopped")

IO.puts("\n=== E2E PASS: Beads → #{inspect(adapter)} pipeline works! ===")
IO.puts("  Issues polled: #{length(issues)}")
IO.puts("  Issue processed: #{first_issue.identifier || first_issue.id}")
IO.puts("  Workspace: #{workspace}")
