defmodule SymphonyElixir.AgentEventStore do
  @moduledoc """
  ETS-backed store for agent session events.

  Stores normalized events per issue_id so LiveViews can replay
  the event history when mounting, and receive new events via PubSub.
  """

  @table __MODULE__
  @pubsub SymphonyElixir.PubSub

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :bag, :public, read_concurrency: true])
    end

    :ok
  end

  @doc "Record a normalized event for an issue."
  def record(issue_id, event) when is_binary(issue_id) and is_map(event) do
    stamped = Map.put_new(event, :timestamp, DateTime.utc_now())
    :ets.insert(@table, {issue_id, stamped})
    Phoenix.PubSub.broadcast(@pubsub, "agent:#{issue_id}", {:agent_event, issue_id, stamped})
    :ok
  end

  @doc "Get all events for an issue, ordered by timestamp."
  def events(issue_id) when is_binary(issue_id) do
    @table
    |> :ets.lookup(issue_id)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1[:timestamp], DateTime)
  end

  @doc "Clear events for an issue (on workspace cleanup)."
  def clear(issue_id) when is_binary(issue_id) do
    :ets.delete(@table, issue_id)
    :ok
  end

  @doc "List issue IDs that have recorded events."
  def active_issue_ids do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
  end
end
