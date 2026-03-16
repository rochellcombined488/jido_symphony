---
tracker:
  kind: beads
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed
workspace:
  root: /tmp/symphony_e2e_workspaces
hooks:
  after_create: |
    echo "workspace created" > .workspace_created
agent:
  kind: echo
  max_concurrent_agents: 2
  max_turns: 3
polling:
  interval_ms: 2000
codex:
  command: "echo noop"
---

You are working on issue `{{ issue.identifier }}`.

Title: {{ issue.title }}

{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

This is an echo test session. Report success.
