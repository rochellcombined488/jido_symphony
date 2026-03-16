# Jido Symphony

Jido Symphony is a multi-agent orchestration harness that turns project
descriptions into working software. It dispatches AI coding agents to work on
issues from a Kanban board, merges their feature branches, and keeps going until
every issue is closed.

> [!WARNING]
> Jido Symphony is prototype software built on top of
> [OpenAI's Symphony](https://github.com/openai/symphony) reference
> implementation. It extends the original with multi-agent support, automatic
> merge with LLM conflict resolution, and a project bootstrapping flow.

## What it does

```
You: "Build me a Linear clone with Elixir + Phoenix + LiveView"
  ↓
Symphony creates a git repo, initializes the issue tracker,
asks the LLM to plan a backlog of 10-15 issues, then dispatches
up to 5 agents in parallel to build the whole thing.
  ↓
Each agent works in an isolated workspace on its own feature branch,
pushes changes, and the orchestrator merges them into trunk automatically.
```

### The loop

1. **Poll** the issue tracker (Beads, Linear, or GitHub Issues) for open work
2. **Dispatch** an agent per issue into an isolated workspace clone
3. **Agent works** — reads the issue, writes code, runs tests
4. **After-run hook** commits to a feature branch and pushes
5. **Merge pipeline** pulls trunk into the branch, resolves conflicts (using the
   LLM if needed), fast-forward merges to trunk, pushes
6. **Close** the issue in the tracker
7. **Repeat** — orchestrator picks up the next open issue

### Architecture

```
┌──────────────────────────────────────────────────┐
│  LiveView Dashboard (localhost:4009)              │
│  ┌────────┐  ┌────────┐  ┌───────────────────┐   │
│  │Overview│  │Issues  │  │+ New Project      │   │
│  │  /     │  │/issues │  │  /projects/new    │   │
│  └────────┘  └────────┘  └───────────────────┘   │
└───────────────────┬──────────────────────────────┘
                    │ PubSub
┌───────────────────▼──────────────────────────────┐
│  Orchestrator (GenServer)                         │
│  - Polls tracker every 5s                        │
│  - Dispatches up to N agents in parallel         │
│  - Manages retry backoff                         │
│  - Triggers merge pipeline after each agent run  │
└───┬───────────┬───────────┬──────────────────────┘
    │           │           │
┌───▼───┐  ┌───▼───┐  ┌───▼───┐
│Agent 1│  │Agent 2│  │Agent 3│  ... up to max_concurrent_agents
│bd-abc │  │bd-def │  │bd-ghi │
│       │  │       │  │       │
│GHCopil│  │Codex  │  │Echo   │  ← pluggable adapters
└───┬───┘  └───┬───┘  └───┬───┘
    │          │          │
┌───▼──────────▼──────────▼────┐
│  Workspace Manager            │
│  - Isolated clone per issue  │
│  - Hooks: after_create,      │
│    before_run, after_run     │
│  - Feature branch workflow   │
└──────────────────────────────┘
```

## Quick start: build something from scratch

### Prerequisites

- [Elixir](https://elixir-lang.org/install.html) 1.17+ / Erlang/OTP 27+
  (we recommend [mise](https://mise.jdx.dev/) for version management)
- [Beads](https://github.com/cosmicbuffalo/beads) (`br` CLI) for local issue
  tracking
- [GitHub Copilot CLI](https://docs.github.com/en/copilot) for the LLM agent
- Git

### 1. Start the orchestrator

```bash
cd elixir
mix deps.get
mix compile

# Start with the web dashboard
PORT=4009 mix phx.server
```

### 2. Create a new project

Open `http://localhost:4009/projects/new` and fill in:

| Field | Example |
|-------|---------|
| **Project name** | `ex_linear_clone` |
| **Path** | `~/github/chgeuer/ex_linear_clone` |
| **Description** | "Create a clone of Linear.app — a project management tool with boards, issues, drag-and-drop, and real-time updates" |
| **Tech stack** | "Elixir + Phoenix + LiveView. Ecto with SQLite. Tailwind CSS. Use Req for HTTP. Write ExUnit tests." |
| **Model** | Claude Sonnet 4 |
| **Max agents** | 3 |

Click **Create Project & Start Building**. Symphony will:

1. Create the git repo at the specified path
2. Initialize the beads issue tracker (`br init`)
3. Generate `WORKFLOW.md` with your config
4. Ask the LLM to decompose your description into 10-15 small, focused issues
5. Activate the orchestrator — agents start picking up issues immediately

### 3. Watch it work

- **Dashboard** (`/`) — running agents, token usage, retry queue
- **Issues** (`/issues`) — full issue list with state filters, create new issues
- **Agent detail** (`/agent/:id`) — real-time tool calls, agent messages, thinking

## Using an existing project

If you already have a repo with a `WORKFLOW.md` and issues (e.g. via Beads or
Linear), point Symphony at it:

```bash
export WORKFLOW_PATH=/path/to/your/repo/WORKFLOW.md
export BEADS_ROOT=/path/to/your/repo
PORT=4009 mix phx.server
```

You'll need to write `WORKFLOW.md` yourself for this path — see the
[WORKFLOW.md](#workflowmd) section below for the format and
`elixir/WORKFLOW.md` as a starting point.

Or use the `run_tee` script which logs output:

```bash
WORKFLOW_PATH=~/myproject/WORKFLOW.md BEADS_ROOT=~/myproject ./run_tee
```

## WORKFLOW.md

`WORKFLOW.md` is the per-project config file that tells Symphony what tracker to
use, how to set up workspaces, which LLM agent to run, and what prompt to give
it. It lives **in the target project's repo**, not in jido_symphony itself.

There are two ways it gets created:

1. **Automatic** (recommended) — use `/projects/new` in the web dashboard.
   The `ProjectBootstrapper` generates `WORKFLOW.md` from your inputs (tech
   stack, model, concurrency) and commits it to the new repo. You never touch
   it.

2. **Manual** — for existing projects, write `WORKFLOW.md` by hand in your repo
   root and point Symphony at it with `WORKFLOW_PATH`. See the example below
   and `elixir/WORKFLOW.md` in this repo as a reference.

The file uses YAML front matter for config and a Markdown/Liquid body as the
per-issue prompt template.

```markdown
---
tracker:
  kind: beads                          # beads | linear | github | memory
workspace:
  root: ~/code/my-project-workspaces
hooks:
  after_create: |
    git clone /path/to/my-project .    # clone into workspace
  after_run: |
    set -e
    BRANCH="symphony/${SYMPHONY_ISSUE_ID}"
    git checkout -B "$BRANCH"
    git add -A
    git commit -m "feat: ${SYMPHONY_ISSUE_TITLE}" --allow-empty || true
    git fetch origin master
    git rebase origin/master || git rebase --abort
    git push origin "$BRANCH" --force-with-lease
agent:
  kind: ghcopilot                      # ghcopilot | codex | echo
  max_concurrent_agents: 5
  max_turns: 20
ghcopilot:
  model: claude-sonnet-4
  allow_all_tools: true
polling:
  interval_ms: 5000
---

You are working on issue `{{ issue.identifier }}`.

Title: {{ issue.title }}
Description: {{ issue.description }}

Instructions:
1. This is unattended. Never ask a human for follow-up.
2. Work only in this repository copy.
3. Create a feature branch: `git checkout -b symphony/{{ issue.identifier }}`
4. Do NOT run `git push` — the after_run hook handles that.
```

### Key config fields

| Field | Description | Default |
|-------|-------------|---------|
| `tracker.kind` | Issue tracker adapter | `linear` |
| `workspace.root` | Directory for agent workspaces | `/tmp/symphony_workspaces` |
| `agent.kind` | Agent adapter to use | `codex` |
| `agent.max_concurrent_agents` | Parallel agent limit | `10` |
| `agent.max_turns` | Max LLM turns per issue | `20` |
| `ghcopilot.model` | LLM model for GH Copilot | — |
| `polling.interval_ms` | Tracker poll interval | `30000` |
| `hooks.after_create` | Shell script run after workspace creation | — |
| `hooks.after_run` | Shell script run after each agent turn | — |

Hooks receive `SYMPHONY_ISSUE_ID` and `SYMPHONY_ISSUE_TITLE` as environment
variables.

## Agent adapters

| Adapter | Backend | Config |
|---------|---------|--------|
| `ghcopilot` | GitHub Copilot CLI (Server protocol, JSON-RPC over stdio) | `ghcopilot.model`, `ghcopilot.allow_all_tools` |
| `codex` | OpenAI Codex App Server | `codex.command`, `codex.approval_policy` |
| `echo` | No-op test adapter | — |

The adapter is selected by `agent.kind` in WORKFLOW.md.

## Tracker adapters

| Adapter | Backend | Notes |
|---------|---------|-------|
| `beads` | Local `br` CLI | Fully local, no external service needed |
| `linear` | Linear.app GraphQL API | Needs `LINEAR_API_KEY` |
| `github` | GitHub Issues via `gh` CLI | Stub — not yet implemented |
| `memory` | In-memory (tests) | Configured via application env |

## Merge pipeline

After an agent finishes, the orchestrator runs:

1. **Pull trunk into feature branch** — `git merge origin/master` into the
   agent's branch
2. **If conflicts** — spawn a new LLM turn with the conflict markers visible,
   asking the agent to resolve them
3. **Finalize** — `git add -A && git commit` the resolution
4. **Fast-forward merge to trunk** — `git merge --ff-only` the feature branch
   into master, then push
5. **Close issue** — mark as "Done" in the tracker
6. **Auto-commit dirty tracker state** — if the trunk repo has unstaged beads
   changes, commit them before pushing to avoid
   `receive.denyCurrentBranch` rejection

## Web dashboard

The LiveView dashboard runs on a minimal Phoenix stack (Bandit, no Webpack/esbuild):

| Route | Page |
|-------|------|
| `/` | Operations dashboard — running agents, tokens, retry queue |
| `/issues` | Issue tracker viewer — list, filter, create issues |
| `/projects/new` | Project factory — describe what to build, start building |
| `/agent/:id` | Agent session detail — real-time tool calls and messages |
| `/api/v1/state` | JSON API — orchestrator snapshot |

## Project layout

```
elixir/
├── lib/
│   ├── symphony_elixir/
│   │   ├── orchestrator.ex          # Main polling/dispatch loop
│   │   ├── agent_runner.ex          # Runs agent turns, merge pipeline
│   │   ├── workspace.ex             # Workspace lifecycle + merge ops
│   │   ├── project_bootstrapper.ex  # git init + br init + WORKFLOW.md
│   │   ├── backlog_planner.ex       # LLM-powered issue generation
│   │   ├── workflow_template.ex     # WORKFLOW.md generator
│   │   ├── workflow.ex              # Parse WORKFLOW.md
│   │   ├── workflow_store.ex        # Hot-reload WORKFLOW.md on change
│   │   ├── config.ex                # Runtime config from workflow
│   │   ├── tracker.ex               # Tracker behaviour
│   │   ├── tracker/beads.ex         # Beads adapter (br CLI)
│   │   ├── tracker/github.ex        # GitHub Issues adapter (stub)
│   │   ├── agent_adapter.ex         # Agent adapter behaviour
│   │   └── agent_adapters/
│   │       ├── ghcopilot.ex         # GitHub Copilot (Server protocol)
│   │       ├── codex.ex             # OpenAI Codex (App Server)
│   │       └── echo.ex              # No-op test adapter
│   └── symphony_elixir_web/
│       ├── live/
│       │   ├── dashboard_live.ex    # Operations overview
│       │   ├── issues_live.ex       # Issue tracker viewer
│       │   ├── new_project_live.ex  # Project factory form
│       │   └── agent_session_live.ex # Per-agent detail
│       └── router.ex
├── scripts/
│   ├── monitor.sh                   # BEAM introspection: orchestrator status
│   └── peek_agent.sh               # BEAM introspection: agent events
├── test/                            # 216+ ExUnit tests
└── WORKFLOW.md                      # Default workflow config
```

## Testing

```bash
cd elixir
mix deps.get
mix test
```

## FAQ

### Why Elixir?

Elixir runs on Erlang/OTP's BEAM VM, which excels at supervising many
long-running concurrent processes. Each agent runs as a supervised task. The
orchestrator is a GenServer with a polling loop. Hot code reloading lets you
update the orchestrator without killing running agents.

### Can I use models other than OpenAI?

Yes. Set `agent.kind: ghcopilot` and `ghcopilot.model` to any model supported by
GitHub Copilot CLI: `claude-sonnet-4`, `claude-sonnet-4.5`, `gpt-5.3-codex`,
`gemini-2.5-pro`, etc. The GHCopilot adapter communicates via the Server
protocol (JSON-RPC over stdio), so any model available through Copilot works.

### How do agents avoid stepping on each other?

Each agent gets its own workspace (a fresh `git clone`). Each works on a
dedicated feature branch (`symphony/<issue-id>`). The merge pipeline handles
integration one branch at a time, resolving conflicts with the LLM if needed.

### How does an agent signal it's stuck?

If an agent hits a true blocker (missing secrets, permissions), it stops early.
The orchestrator sees the issue is still open and retries with exponential
backoff. The retry prompt includes `attempt #N` context so the agent doesn't
redo completed work.

### Can I create issues manually?

Yes — use the `/issues` page to create issues directly, or use the `br` CLI:

```bash
cd /path/to/project
br create "Add dark mode support" --type feature --priority 2
```

The orchestrator picks up new issues on the next poll cycle.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).

