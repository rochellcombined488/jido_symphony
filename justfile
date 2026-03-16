# Start the server (visible output, logs to run.log)
start:
    #!/usr/bin/env bash
    SNAME="$(basename "$(pwd)")"
    export PORT="${PORT:-$(phx-port)}"
    export WORKFLOW_PATH="${WORKFLOW_PATH:-$HOME/github/chgeuer/symphony_demo/WORKFLOW.md}"
    export BEADS_ROOT="${BEADS_ROOT:-$HOME/github/chgeuer/symphony_demo}"
    exec elixir --sname "$SNAME" --cookie devcookie -S mix phx.server 2>&1 | tee run.log

# Start the server in background (logs to run.log only)
start-bg:
    #!/usr/bin/env bash
    SNAME="$(basename "$(pwd)")"
    export PORT="${PORT:-$(phx-port)}"
    export WORKFLOW_PATH="${WORKFLOW_PATH:-$HOME/github/chgeuer/symphony_demo/WORKFLOW.md}"
    export BEADS_ROOT="${BEADS_ROOT:-$HOME/github/chgeuer/symphony_demo}"
    elixir --sname "$SNAME" --cookie devcookie -S mix phx.server > run.log 2>&1 &
    echo "Started in background on port $PORT (PID $!). Logs in run.log"

# Open the app in a browser (starts the server if not running)
open:
    #!/usr/bin/env bash
    SNAME="$(basename "$(pwd)")"
    if ! scripts/dev_node.sh status 2>&1 | grep -q "running"; then
        echo "Node $SNAME not running, starting in background..."
        export PORT="${PORT:-$(phx-port)}"
        export WORKFLOW_PATH="${WORKFLOW_PATH:-$HOME/github/chgeuer/symphony_demo/WORKFLOW.md}"
        export BEADS_ROOT="${BEADS_ROOT:-$HOME/github/chgeuer/symphony_demo}"
        elixir --sname "$SNAME" --cookie devcookie -S mix phx.server > run.log 2>&1 &
        for i in $(seq 1 30); do
            if scripts/dev_node.sh status 2>&1 | grep -q "running"; then
                break
            fi
            sleep 1
        done
    fi
    phx-port open

# Stop the running BEAM node gracefully
stop:
    scripts/dev_node.sh rpc "System.halt()"

# Check if the BEAM node is running
status:
    scripts/dev_node.sh status

# Execute an expression on the running BEAM node
rpc EXPR:
    scripts/dev_node.sh rpc "{{EXPR}}"

# Show the assigned port
port:
    @phx-port | cat
