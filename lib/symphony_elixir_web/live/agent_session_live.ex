defmodule SymphonyElixirWeb.AgentSessionLive do
  @moduledoc """
  Real-time view of a single agent's activity.

  Coalesces raw events into renderable blocks:
  - Agent text chunks → merged message blocks
  - tool_call + tool_call_completed → combined tool entries
  - Consecutive tools → collapsible groups
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias Jido.ToolRenderers.Adapters.Symphony, as: EventAdapter
  alias Jido.ToolRenderers.SessionViewer.Terminal
  alias SymphonyElixir.{AgentEventStore, Orchestrator}

  @tick_ms 2_000

  @impl true
  def mount(%{"issue_id" => issue_id}, _session, socket) do
    raw_events = AgentEventStore.events(issue_id)
    agent_info = find_running_agent(issue_id)
    blocks = coalesce_events(raw_events)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "agent:#{issue_id}")
      schedule_tick()
    end

    socket =
      socket
      |> assign(:issue_id, issue_id)
      |> assign(:agent_info, agent_info)
      |> assign(:raw_count, length(raw_events))
      |> assign(:text_acc, "")
      |> assign(:text_block_id, nil)
      |> assign(:thought_acc, "")
      |> assign(:thought_block_id, nil)
      |> assign(:pending_tools, %{})
      |> assign(:view_mode, :rich)
      |> assign(:terminal_blocks, blocks)
      |> stream(:blocks, blocks)

    {:ok, socket}
  end

  @impl true
  def handle_event("set_view_mode", %{"mode" => mode}, socket) do
    view_mode = if mode == "terminal", do: :terminal, else: :rich
    {:noreply, assign(socket, :view_mode, view_mode)}
  end

  @impl true
  def handle_info({:agent_event, _issue_id, event}, socket) do
    socket = ingest_live_event(socket, event)

    # Track for terminal view and push xterm data if in terminal mode
    socket = track_terminal_event(socket, event)

    {:noreply, assign(socket, :raw_count, socket.assigns.raw_count + 1)}
  end

  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, assign(socket, :agent_info, find_running_agent(socket.assigns.issue_id))}
  end

  # -- Live event ingestion (one event at a time) --

  defp ingest_live_event(socket, event) do
    case event[:event] do
      :agent_text ->
        text = event[:text] || ""
        acc = socket.assigns.text_acc <> text
        block_id = socket.assigns.text_block_id || "msg-#{uid()}"

        block = %{id: block_id, kind: :message, text: acc, timestamp: event[:timestamp]}

        socket
        |> assign(:text_acc, acc)
        |> assign(:text_block_id, block_id)
        |> stream_insert(:blocks, block)

      :agent_thought ->
        text = event[:text] || ""
        acc = socket.assigns.thought_acc <> text
        block_id = socket.assigns.thought_block_id || "thought-#{uid()}"
        block = %{id: block_id, kind: :thought, text: acc, timestamp: event[:timestamp]}

        socket
        |> assign(:thought_acc, acc)
        |> assign(:thought_block_id, block_id)
        |> stream_insert(:blocks, block)

      :tool_call ->
        tool_id = event[:tool_call_id] || "t-#{uid()}"
        name = event[:tool_name]
        args = event[:args] || ""
        title = event[:title] || ""

        block = %{
          id: "tool-#{tool_id}",
          kind: :tool,
          tool_name: name,
          title: title,
          tool_call_id: tool_id,
          args: args,
          completed: false,
          result: nil,
          timestamp: event[:timestamp]
        }

        socket
        |> flush_text()
        |> flush_thought()
        |> assign(:pending_tools, Map.put(socket.assigns.pending_tools, tool_id, %{tool_name: name, args: args, title: title}))
        |> stream_insert(:blocks, block, at: -1)

      :tool_call_completed ->
        tool_id = event[:tool_call_id]
        result = event[:result] || ""

        if tool_id && Map.has_key?(socket.assigns.pending_tools, tool_id) do
          pending = socket.assigns.pending_tools[tool_id]

          block = %{
            id: "tool-#{tool_id}",
            kind: :tool,
            tool_name: pending.tool_name,
            title: pending[:title] || "",
            tool_call_id: tool_id,
            args: pending.args,
            completed: true,
            result: result,
            timestamp: event[:timestamp]
          }

          socket
          |> assign(:pending_tools, Map.delete(socket.assigns.pending_tools, tool_id))
          |> stream_insert(:blocks, block)
        else
          # Orphan completion — show standalone
          block = %{id: "tooldone-#{uid()}", kind: :tool_done, result: result, timestamp: event[:timestamp]}
          stream_insert(socket, :blocks, block, at: -1)
        end

      :session_started ->
        block = %{id: "session-#{uid()}", kind: :session_started, session_id: event[:session_id], timestamp: event[:timestamp]}
        stream_insert(socket, :blocks, block, at: -1)

      :approval_auto_approved ->
        block = %{id: "approve-#{uid()}", kind: :approved, decision: event[:decision], timestamp: event[:timestamp]}
        stream_insert(socket, :blocks, block, at: -1)

      :turn_completed ->
        block = %{id: "turn-#{uid()}", kind: :turn_completed, timestamp: event[:timestamp]}
        flush_text(socket) |> stream_insert(:blocks, block, at: -1)

      :turn_ended_with_error ->
        block = %{id: "err-#{uid()}", kind: :error, reason: inspect(event[:reason], limit: 200), timestamp: event[:timestamp]}
        flush_text(socket) |> stream_insert(:blocks, block, at: -1)

      :plan ->
        block = %{id: "plan-#{uid()}", kind: :plan, entries: event[:entries] || [], timestamp: event[:timestamp]}
        stream_insert(socket, :blocks, block, at: -1)

      _ ->
        # Legacy :notification with text
        if event[:text] && String.trim(event[:text]) != "" do
          acc = socket.assigns.text_acc <> (event[:text] || "")
          block_id = socket.assigns.text_block_id || "msg-#{uid()}"
          block = %{id: block_id, kind: :message, text: acc, timestamp: event[:timestamp]}

          socket
          |> assign(:text_acc, acc)
          |> assign(:text_block_id, block_id)
          |> stream_insert(:blocks, block)
        else
          socket
        end
    end
  end

  defp flush_text(socket) do
    if socket.assigns.text_acc != "" do
      socket
      |> assign(:text_acc, "")
      |> assign(:text_block_id, nil)
    else
      socket
    end
  end

  defp flush_thought(socket) do
    if socket.assigns.thought_acc != "" do
      socket
      |> assign(:thought_acc, "")
      |> assign(:thought_block_id, nil)
    else
      socket
    end
  end

  # -- Coalesce historical events into blocks on mount --

  defp coalesce_events(events) do
    {blocks, text_acc, thought_acc, _pending} =
      Enum.reduce(events, {[], "", "", %{}}, fn event, {blocks, text, thought, pending} ->
        case event[:event] do
          :agent_text ->
            {blocks, text <> (event[:text] || ""), thought, pending}

          :agent_thought ->
            {blocks, text, thought <> (event[:text] || ""), pending}

          :tool_call ->
            blocks = blocks |> flush_text_block(text, event[:timestamp]) |> flush_thought_block(thought, event[:timestamp])
            tool_id = event[:tool_call_id] || "t-#{uid()}"

            tool_block = %{
              id: "tool-#{tool_id}",
              kind: :tool,
              tool_name: event[:tool_name],
              title: event[:title] || "",
              tool_call_id: tool_id,
              args: event[:args] || "",
              completed: false,
              result: nil,
              timestamp: event[:timestamp]
            }

            {blocks ++ [tool_block], "", "", Map.put(pending, tool_id, length(blocks))}

          :tool_call_completed ->
            tool_id = event[:tool_call_id]
            result = event[:result] || ""

            if tool_id && Map.has_key?(pending, tool_id) do
              idx = pending[tool_id]

              if idx < length(blocks) do
                existing = Enum.at(blocks, idx)
                updated = %{existing | completed: true, result: result}
                {List.replace_at(blocks, idx, updated), text, thought, Map.delete(pending, tool_id)}
              else
                done = %{id: "tooldone-#{uid()}", kind: :tool_done, result: result, timestamp: event[:timestamp]}
                {blocks ++ [done], text, thought, Map.delete(pending, tool_id)}
              end
            else
              done = %{id: "tooldone-#{uid()}", kind: :tool_done, result: result, timestamp: event[:timestamp]}
              {blocks ++ [done], text, thought, pending}
            end

          :session_started ->
            block = %{id: "session-#{uid()}", kind: :session_started, session_id: event[:session_id], timestamp: event[:timestamp]}
            {blocks ++ [block], text, thought, pending}

          :turn_completed ->
            blocks = blocks |> flush_text_block(text, event[:timestamp]) |> flush_thought_block(thought, event[:timestamp])
            block = %{id: "turn-#{uid()}", kind: :turn_completed, timestamp: event[:timestamp]}
            {blocks ++ [block], "", "", pending}

          :turn_ended_with_error ->
            blocks = blocks |> flush_text_block(text, event[:timestamp]) |> flush_thought_block(thought, event[:timestamp])
            block = %{id: "err-#{uid()}", kind: :error, reason: inspect(event[:reason], limit: 200), timestamp: event[:timestamp]}
            {blocks ++ [block], "", "", pending}

          :approval_auto_approved ->
            block = %{id: "approve-#{uid()}", kind: :approved, decision: event[:decision], timestamp: event[:timestamp]}
            {blocks ++ [block], text, thought, pending}

          :usage ->
            # Skip usage events in the block stream for now
            {blocks, text, thought, pending}

          :plan ->
            block = %{id: "plan-#{uid()}", kind: :plan, entries: event[:entries] || [], timestamp: event[:timestamp]}
            {blocks ++ [block], text, thought, pending}

          _ ->
            # Legacy :notification with text field
            if event[:text] && String.trim(event[:text]) != "" do
              {blocks, text <> (event[:text] || ""), thought, pending}
            else
              {blocks, text, thought, pending}
            end
        end
      end)

    blocks
    |> flush_text_block(text_acc, nil)
    |> flush_thought_block(thought_acc, nil)
  end

  defp flush_text_block(blocks, text, ts) do
    if String.trim(text) != "" do
      blocks ++ [%{id: "msg-#{uid()}", kind: :message, text: text, timestamp: ts}]
    else
      blocks
    end
  end

  defp flush_thought_block(blocks, thought, ts) do
    if String.trim(thought) != "" do
      blocks ++ [%{id: "thought-#{uid()}", kind: :thought, text: thought, timestamp: ts}]
    else
      blocks
    end
  end

  # -- Render --

  @impl true
  def render(assigns) do
    terminal_events = Enum.map(assigns.terminal_blocks, &EventAdapter.convert_block/1)
    assigns = assign(assigns, :terminal_events, terminal_events)

    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card" style="padding: 1.25rem 1.5rem;">
        <div style="display: flex; justify-content: space-between; align-items: center;">
          <div>
            <h1 style="margin: 0.25rem 0 0; font-size: 1.4rem; font-weight: 700;">
              <span style="color: #60a5fa; font-family: monospace;"><%= @issue_id %></span>
              <%= if @agent_info do %>
                <span style="font-weight: 400; color: #94a3b8;"> — <%= @agent_info.title %></span>
              <% end %>
            </h1>
          </div>
          <div style="display: flex; align-items: center; gap: 0.75rem;">
            <div style="display: flex; gap: 2px;">
              <button
                phx-click="set_view_mode"
                phx-value-mode="rich"
                style={"padding: 0.25rem 0.75rem; border-radius: 4px 0 0 4px; font-size: 0.75rem; cursor: pointer; border: 1px solid #334155; #{if @view_mode == :rich, do: "background: #60a5fa; color: #0f172a; font-weight: 600;", else: "background: #1e293b; color: #94a3b8;"}"}
              >
                Rich
              </button>
              <button
                phx-click="set_view_mode"
                phx-value-mode="terminal"
                style={"padding: 0.25rem 0.75rem; border-radius: 0 4px 4px 0; font-size: 0.75rem; cursor: pointer; border: 1px solid #334155; #{if @view_mode == :terminal, do: "background: #60a5fa; color: #0f172a; font-weight: 600;", else: "background: #1e293b; color: #94a3b8;"}"}
              >
                Terminal
              </button>
            </div>
            <div style="text-align: right;">
              <%= if @agent_info do %>
                <span class={"state-badge #{status_class(@agent_info.last_event)}"} style="display:inline-block;">
                  <%= @agent_info.last_event || "waiting" %>
                </span>
                <div style="color: #94a3b8; font-size: 0.8rem; margin-top: 0.25rem;">
                  Turn <%= @agent_info.turn_count %> · <%= @raw_count %> raw events
                </div>
              <% else %>
                <span class="state-badge">completed</span>
                <div style="color: #94a3b8; font-size: 0.8rem;"><%= @raw_count %> raw events</div>
              <% end %>
            </div>
          </div>
        </div>
      </header>

      <section class="section-card" style="max-height: 80vh; overflow-y: auto;" id="event-stream" phx-hook="AutoScroll">
        <%= if @view_mode == :rich do %>
          <div id="blocks" phx-update="stream">
            <div :for={{dom_id, block} <- @streams.blocks} id={dom_id}>
              <.render_block block={block} />
            </div>
          </div>
        <% else %>
          <Terminal.terminal_view
            id="session-terminal"
            events={@terminal_events}
            class="h-full min-h-[60vh]"
          />
        <% end %>

        <%= if @raw_count == 0 do %>
          <p class="empty-state">Waiting for agent events…</p>
        <% end %>
      </section>
    </section>
    """
  end

  # -- Block renderers --

  defp render_block(%{block: %{kind: :message}} = assigns) do
    ~H"""
    <div style="margin: 0.75rem 0; padding: 0.75rem 1rem; background: #1e293b; border-radius: 8px; border-left: 3px solid #60a5fa;">
      <div style="font-size: 0.75rem; color: #60a5fa; font-weight: 600; margin-bottom: 0.25rem;">💬 Agent</div>
      <div style="color: #e2e8f0; font-size: 0.875rem; line-height: 1.6; white-space: pre-wrap; word-break: break-word;"><%= @block.text %></div>
    </div>
    """
  end

  # -- Tool block renderer (dispatches to specialized renderers) --

  defp render_block(%{block: %{kind: :tool}} = assigns) do
    tool_name = assigns.block.tool_name || ""
    completed = assigns.block[:completed] || false
    args = parse_args(assigns.block[:args])
    content = clean_tool_result(assigns.block[:result])
    error_msg = if assigns.block[:error], do: inspect(assigns.block[:error]), else: ""

    renderer = Jido.ToolRenderers.renderer_for(tool_name)

    assigns =
      assigns
      |> assign(:tool, tool_name)
      |> assign(:args, args)
      |> assign(:completed, completed)
      |> assign(:content, content)
      |> assign(:error_msg, error_msg)
      |> assign(:tool_call_id, assigns.block[:tool_call_id])
      |> assign(:renderer, renderer)

    ~H"""
    <div style="margin: 0.35rem 0.5rem; padding: 0.5rem 0.75rem; background: #0f172a; border-radius: 6px; border: 1px solid #1e293b;">
      {@renderer.render(assigns)}
    </div>
    """
  end

  defp render_block(%{block: %{kind: :tool_done}} = assigns) do
    ~H"""
    <div style="margin: 0.25rem 0.5rem; padding: 0.35rem 0.75rem; color: #64748b; font-size: 0.75rem;">
      ✔ tool completed
      <%= if @block.result && to_string(@block.result) != "" do %>
        <details style="display: inline;">
          <summary style="cursor: pointer; color: #475569;">output</summary>
          <pre style="padding: 0.5rem; background: #020617; border-radius: 4px; font-size: 0.7rem; color: #94a3b8; max-height: 8rem; overflow-y: auto; white-space: pre-wrap;"><%= String.slice(to_string(@block.result), 0, 2000) %></pre>
        </details>
      <% end %>
    </div>
    """
  end

  defp render_block(%{block: %{kind: :thought}} = assigns) do
    ~H"""
    <div style="margin: 0.25rem 0.5rem; padding: 0.35rem 0.75rem; border-left: 2px solid #7c3aed; color: #a78bfa; font-size: 0.8rem; font-style: italic;">
      💭 <%= @block.text %>
    </div>
    """
  end

  defp render_block(%{block: %{kind: :session_started}} = assigns) do
    ~H"""
    <div style="margin: 0.5rem 0; padding: 0.5rem 1rem; background: #052e16; border-radius: 6px; color: #34d399; font-size: 0.85rem;">
      🚀 Session started · <span style="font-family: monospace; font-size: 0.75rem;"><%= @block.session_id %></span>
    </div>
    """
  end

  defp render_block(%{block: %{kind: :turn_completed}} = assigns) do
    ~H"""
    <div style="margin: 0.5rem 0; padding: 0.5rem 1rem; background: #052e16; border-radius: 6px; color: #34d399; font-size: 0.85rem;">
      ✅ Turn completed
    </div>
    """
  end

  defp render_block(%{block: %{kind: :error}} = assigns) do
    ~H"""
    <div style="margin: 0.5rem 0; padding: 0.5rem 1rem; background: #450a0a; border-radius: 6px; color: #f87171; font-size: 0.85rem;">
      ❌ Error: <%= @block.reason %>
    </div>
    """
  end

  defp render_block(%{block: %{kind: :approved}} = assigns) do
    ~H"""
    <div style="margin: 0.15rem 0.5rem; padding: 0.2rem 0.75rem; color: #64748b; font-size: 0.7rem;">
      🔓 auto-approved: <%= @block.decision %>
    </div>
    """
  end

  defp render_block(%{block: %{kind: :plan}} = assigns) do
    ~H"""
    <div style="margin: 0.25rem 0.5rem; padding: 0.35rem 0.75rem; color: #94a3b8; font-size: 0.8rem;">
      📋 Plan updated (<%= length(@block.entries) %> entries)
    </div>
    """
  end

  defp render_block(assigns) do
    ~H"""
    <div style="margin: 0.15rem 0.5rem; padding: 0.2rem 0.75rem; color: #475569; font-size: 0.7rem;">
      · event
    </div>
    """
  end

  # -- Helpers --

  defp track_terminal_event(socket, event) do
    session_event = EventAdapter.convert_event(Map.put(event, :type, event[:event]))

    terminal_blocks = socket.assigns.terminal_blocks ++ [%{id: "term-#{uid()}", kind: event_to_kind(event[:event]), text: event[:text] || "", timestamp: event[:timestamp]}]
    socket = assign(socket, :terminal_blocks, terminal_blocks)

    if socket.assigns.view_mode == :terminal do
      ansi = Terminal.format_event(session_event)
      push_event(socket, "xterm:write", %{data: ansi, target: "session-terminal"})
    else
      socket
    end
  end

  defp event_to_kind(:agent_text), do: :message
  defp event_to_kind(:agent_thought), do: :thought
  defp event_to_kind(:tool_call), do: :tool
  defp event_to_kind(:tool_call_completed), do: :tool_done
  defp event_to_kind(:session_started), do: :session_started
  defp event_to_kind(:turn_completed), do: :turn_completed
  defp event_to_kind(:turn_ended_with_error), do: :error
  defp event_to_kind(:plan), do: :plan
  defp event_to_kind(:approval_auto_approved), do: :approved
  defp event_to_kind(_), do: :message

  defp find_running_agent(issue_id) do
    case Orchestrator.snapshot() do
      %{running: running} ->
        case Enum.find(running, &(&1.issue_id == issue_id)) do
          nil ->
            nil

          entry ->
            %{
              title: Map.get(entry, :identifier, issue_id),
              last_event: entry.last_codex_event,
              turn_count: entry.turn_count,
              started_at: entry.started_at,
              session_id: entry.session_id
            }
        end

      _ ->
        nil
    end
  end

  defp parse_args(nil), do: %{}
  defp parse_args(""), do: %{}

  defp parse_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{"raw" => args}
    end
  end

  defp parse_args(args) when is_map(args), do: args
  defp parse_args(_), do: %{}

  defp status_class(:tool_call_completed), do: "state-badge-active"
  defp status_class(:tool_call), do: "state-badge-active"
  defp status_class(:agent_text), do: "state-badge-active"
  defp status_class(:notification), do: "state-badge-active"
  defp status_class(:session_started), do: "state-badge-active"
  defp status_class(:turn_completed), do: ""
  defp status_class(_), do: "state-badge-warning"

  defp uid, do: System.unique_integer([:positive])
  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  # Extract text from tool result, handling the JSON envelope from Server protocol
  defp clean_tool_result(nil), do: ""
  defp clean_tool_result(""), do: ""

  defp clean_tool_result(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"content" => content}} when is_binary(content) -> content
      {:ok, %{"detailedContent" => content}} when is_binary(content) -> content
      _ -> result
    end
  end

  defp clean_tool_result(result) when is_map(result) do
    Map.get(result, "content") || Map.get(result, "detailedContent") || inspect(result)
  end

  defp clean_tool_result(result), do: to_string(result)
end
