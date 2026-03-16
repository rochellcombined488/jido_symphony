defmodule SymphonyElixir.Tracker.GitHub do
  @moduledoc """
  Tracker adapter that reads from GitHub Issues via the `gh` CLI.

  Uses label-based Kanban conventions since GitHub Issues only has
  open/closed states natively.

  Status: stub — not yet implemented.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:error, :github_tracker_not_implemented}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(_states) do
    {:error, :github_tracker_not_implemented}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(_issue_ids) do
    {:error, :github_tracker_not_implemented}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(_issue_id, _body) do
    {:error, :github_tracker_not_implemented}
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(_issue_id, _state_name) do
    {:error, :github_tracker_not_implemented}
  end

  @spec fetch_all_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_all_issues do
    {:error, :github_tracker_not_implemented}
  end

  @spec create_issue(map()) :: {:ok, Issue.t()} | {:error, term()}
  def create_issue(_attrs) do
    {:error, :github_tracker_not_implemented}
  end
end
