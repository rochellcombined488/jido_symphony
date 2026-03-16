defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Backward-compatible alias for `SymphonyElixir.Issue`.

  Kept so that existing Linear-specific code (client.ex, adapter.ex)
  continues to compile without changes.
  """

  defstruct Map.keys(%SymphonyElixir.Issue{}) -- [:__struct__]

  @type t :: SymphonyElixir.Issue.t()

  defdelegate label_names(issue), to: SymphonyElixir.Issue
end
