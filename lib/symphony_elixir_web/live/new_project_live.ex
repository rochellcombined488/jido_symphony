defmodule SymphonyElixirWeb.NewProjectLive do
  @moduledoc """
  LiveView for bootstrapping a new project.

  Collects project description, tech stack, and config, then:
  1. Creates a local git repo + beads tracker
  2. Runs the BacklogPlanner (LLM) to generate issues
  3. Activates the project for orchestration
  4. Redirects to /issues
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{ProjectBootstrapper, BacklogPlanner}

  @impl true
  def mount(_params, _session, socket) do
    models = Jido.GHCopilot.Models.all()

    socket =
      socket
      |> assign(:form, default_form())
      |> assign(:models, models)
      |> assign(:phase, :form)
      |> assign(:log, [])
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("start_project", params, socket) do
    socket =
      socket
      |> assign(:phase, :bootstrapping)
      |> assign(:log, ["Starting project bootstrap..."])
      |> assign(:error, nil)

    # Run async so LiveView stays responsive
    lv = self()

    Task.start(fn ->
      run_bootstrap(params, lv)
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:log, message}, socket) do
    {:noreply, assign(socket, :log, socket.assigns.log ++ [message])}
  end

  @impl true
  def handle_info({:phase, phase}, socket) do
    {:noreply, assign(socket, :phase, phase)}
  end

  @impl true
  def handle_info({:error, message}, socket) do
    {:noreply, socket |> assign(:phase, :error) |> assign(:error, message)}
  end

  @impl true
  def handle_info(:done, socket) do
    {:noreply, push_navigate(socket, to: "/issues")}
  end

  # -- Bootstrap pipeline (runs in Task) --

  defp run_bootstrap(params, lv) do
    opts = %{
      name: String.trim(params["name"] || ""),
      path: Path.expand(String.trim(params["path"] || "")),
      description: String.trim(params["description"] || ""),
      tech_stack: String.trim(params["tech_stack"] || ""),
      agent_model: params["agent_model"] || "claude-sonnet-4",
      max_agents: parse_int(params["max_agents"], 3),
      max_turns: parse_int(params["max_turns"], 15)
    }

    # Phase 1: Bootstrap
    send(lv, {:log, "📁 Creating directory: #{opts.path}"})

    case ProjectBootstrapper.bootstrap(opts) do
      {:ok, project} ->
        send(lv, {:log, "✓ Git repo initialized"})
        send(lv, {:log, "✓ Beads tracker initialized"})
        send(lv, {:log, "✓ WORKFLOW.md generated"})
        send(lv, {:phase, :planning})
        send(lv, {:log, "🤖 Running BacklogPlanner (LLM generating issues)..."})

        # Phase 2: Plan backlog
        case BacklogPlanner.plan(
               repo_path: project.repo_path,
               description: opts.description,
               tech_stack: opts.tech_stack
             ) do
          {:ok, issues} ->
            send(lv, {:log, "✓ Created #{length(issues)} issues in backlog"})

            for issue <- issues do
              send(lv, {:log, "  • #{issue.title || issue.id}"})
            end

            # Phase 3: Activate
            send(lv, {:phase, :activating})
            send(lv, {:log, "⚡ Activating project for orchestration..."})
            ProjectBootstrapper.activate(project)
            send(lv, {:log, "✓ Orchestrator will pick up issues on next poll cycle"})

            Process.sleep(1500)
            send(lv, :done)

          {:error, reason} ->
            send(lv, {:error, "BacklogPlanner failed: #{inspect(reason)}"})
        end

      {:error, reason} ->
        send(lv, {:error, "Bootstrap failed: #{inspect(reason)}"})
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(n, _default) when is_integer(n), do: n

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Project Factory</p>
            <h1 class="hero-title">New Project</h1>
            <p class="hero-copy">
              Describe what to build. Symphony creates the repo, plans the backlog, and starts building.
            </p>
          </div>
          <div class="status-stack">
          </div>
        </div>
      </header>

      <%= if @phase == :form do %>
        <.project_form form={@form} models={@models} />
      <% else %>
        <.progress_panel phase={@phase} log={@log} error={@error} />
      <% end %>
    </section>
    """
  end

  defp project_form(assigns) do
    ~H"""
    <section class="section-card">
      <div class="section-header">
        <div>
          <h2 class="section-title">Project details</h2>
          <p class="section-copy">Describe what you want to build and the orchestrator will take it from here.</p>
        </div>
      </div>

      <form phx-submit="start_project" style="padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem;">
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
          <div style="display: flex; flex-direction: column; gap: 0.35rem;">
            <label style="color: #94a3b8; font-size: 0.8rem; font-weight: 600;">Project name</label>
            <input
              type="text"
              name="name"
              value={@form["name"]}
              placeholder="my_awesome_app"
              required
              style="padding: 0.5rem 0.75rem; border-radius: 0.375rem; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 0.9rem;"
            />
          </div>
          <div style="display: flex; flex-direction: column; gap: 0.35rem;">
            <label style="color: #94a3b8; font-size: 0.8rem; font-weight: 600;">Path</label>
            <input
              type="text"
              name="path"
              value={@form["path"]}
              placeholder="~/github/chgeuer/my_awesome_app"
              required
              style="padding: 0.5rem 0.75rem; border-radius: 0.375rem; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 0.9rem;"
            />
          </div>
        </div>

        <div style="display: flex; flex-direction: column; gap: 0.35rem;">
          <label style="color: #94a3b8; font-size: 0.8rem; font-weight: 600;">What do you want to build?</label>
          <textarea
            name="description"
            placeholder="Create a clone of Linear.app — a project management tool with boards, issues, drag-and-drop, real-time updates..."
            rows="5"
            required
            style="padding: 0.5rem 0.75rem; border-radius: 0.375rem; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 0.9rem; resize: vertical;"
          ><%= @form["description"] %></textarea>
        </div>

        <div style="display: flex; flex-direction: column; gap: 0.35rem;">
          <label style="color: #94a3b8; font-size: 0.8rem; font-weight: 600;">Tech stack instructions</label>
          <textarea
            name="tech_stack"
            placeholder="Elixir + Phoenix Framework + LiveView. Use Ecto with SQLite. Tailwind CSS for styling. Use Req for HTTP client. Write ExUnit tests."
            rows="3"
            style="padding: 0.5rem 0.75rem; border-radius: 0.375rem; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 0.9rem; resize: vertical;"
          ><%= @form["tech_stack"] %></textarea>
        </div>

        <div style="display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 1rem;">
          <div style="display: flex; flex-direction: column; gap: 0.35rem;">
            <label style="color: #94a3b8; font-size: 0.8rem; font-weight: 600;">Agent model</label>
            <select
              name="agent_model"
              style="padding: 0.5rem 0.5rem; border-radius: 0.375rem; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 0.85rem;"
            >
              <option
                :for={{name, id, _mult} <- @models}
                value={id}
                selected={id == "claude-sonnet-4"}
              ><%= name %></option>
            </select>
          </div>
          <div style="display: flex; flex-direction: column; gap: 0.35rem;">
            <label style="color: #94a3b8; font-size: 0.8rem; font-weight: 600;">Max concurrent agents</label>
            <select
              name="max_agents"
              style="padding: 0.5rem 0.5rem; border-radius: 0.375rem; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 0.85rem;"
            >
              <option value="1">1</option>
              <option value="2">2</option>
              <option value="3" selected>3</option>
              <option value="5">5</option>
            </select>
          </div>
          <div style="display: flex; flex-direction: column; gap: 0.35rem;">
            <label style="color: #94a3b8; font-size: 0.8rem; font-weight: 600;">Max turns per issue</label>
            <select
              name="max_turns"
              style="padding: 0.5rem 0.5rem; border-radius: 0.375rem; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 0.85rem;"
            >
              <option value="5">5</option>
              <option value="10">10</option>
              <option value="15" selected>15</option>
              <option value="20">20</option>
              <option value="30">30</option>
            </select>
          </div>
        </div>

        <div style="padding-top: 0.5rem;">
          <button
            type="submit"
            style="padding: 0.65rem 2rem; border-radius: 0.5rem; border: none; background: #60a5fa; color: #0f172a; cursor: pointer; font-weight: 700; font-size: 1rem;"
          >
            🚀 Create Project & Start Building
          </button>
        </div>
      </form>
    </section>
    """
  end

  defp progress_panel(assigns) do
    ~H"""
    <section class="section-card">
      <div class="section-header">
        <div>
          <h2 class="section-title">
            <%= case @phase do %>
              <% :bootstrapping -> %>📁 Bootstrapping project...
              <% :planning -> %>🤖 Planning backlog...
              <% :activating -> %>⚡ Activating orchestrator...
              <% :error -> %>❌ Error
              <% _ -> %>Working...
            <% end %>
          </h2>
          <p class="section-copy">
            <%= case @phase do %>
              <% :bootstrapping -> %>Creating git repo and initializing tracker
              <% :planning -> %>LLM is generating issues for the backlog (this may take a minute)
              <% :activating -> %>Pointing orchestrator at the new project
              <% :error -> %>Something went wrong
              <% _ -> %>Please wait...
            <% end %>
          </p>
        </div>
        <%= unless @phase == :error do %>
          <div style="display: flex; align-items: center; gap: 0.5rem;">
            <div style="width: 0.75rem; height: 0.75rem; border-radius: 50%; background: #60a5fa; animation: pulse 1.5s infinite;"></div>
            <span style="color: #94a3b8; font-size: 0.85rem;">Working</span>
          </div>
        <% end %>
      </div>

      <div style="padding: 1rem 1.5rem; font-family: monospace; font-size: 0.85rem; line-height: 1.8;">
        <%= for line <- @log do %>
          <div style={"color: #{log_color(line)}"}><%= line %></div>
        <% end %>

        <%= if @error do %>
          <div style="color: #fca5a5; margin-top: 0.75rem; padding: 0.75rem; border-radius: 0.375rem; background: #7f1d1d;">
            <%= @error %>
          </div>
          <div style="margin-top: 1rem;">
            <a href="/projects/new" style="color: #60a5fa; text-decoration: none;">← Try again</a>
          </div>
        <% end %>
      </div>
    </section>

    <style>
      @keyframes pulse {
        0%, 100% { opacity: 1; }
        50% { opacity: 0.3; }
      }
    </style>
    """
  end

  defp log_color(line) do
    cond do
      String.starts_with?(line, "✓") -> "#6ee7b7"
      String.starts_with?(line, "•") or String.starts_with?(line, "  •") -> "#94a3b8"
      String.starts_with?(line, "❌") -> "#fca5a5"
      true -> "#e2e8f0"
    end
  end

  defp default_form do
    home = System.get_env("HOME", "~")

    %{
      "name" => "",
      "path" => "#{home}/github/chgeuer/",
      "description" => "",
      "tech_stack" => "Elixir + Phoenix Framework + LiveView\nEcto with SQLite for database\nTailwind CSS for styling\nUse Req for HTTP client\nWrite ExUnit tests for all modules",
      "agent_model" => "claude-sonnet-4",
      "max_agents" => "3",
      "max_turns" => "15"
    }
  end
end
