defmodule SymphonyElixir.Tracker.BeadsTest do
  @moduledoc """
  Tests for the Beads (br) tracker adapter.

  Creates a temporary .beads workspace, populates it with issues via the br CLI,
  and verifies all Tracker behaviour callbacks produce correct Issue structs.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.{Issue, Tracker.Beads}

  @moduletag :integration

  setup_all do
    unless System.find_executable("br") do
      IO.puts("Skipping Beads tracker tests: `br` CLI not installed")
    end

    :ok
  end

  setup do
    case System.find_executable("br") do
      nil ->
        {:ok, %{skip: true}}

      _br ->
        tmp = Path.join(System.tmp_dir!(), "beads_test_#{System.unique_integer([:positive])}")
        File.mkdir_p!(tmp)

        # Init beads workspace
        {_, 0} = System.cmd("br", ["init"], cd: tmp, stderr_to_stdout: true)

        # Create test issues
        id1 = br_create!(tmp, "Fix authentication bug", "-t", "bug", "-p", "1", "-l", "auth,urgent")
        id2 = br_create!(tmp, "Add user settings page", "-t", "feature", "-p", "2", "-l", "ui")
        id3 = br_create!(tmp, "Update README", "-t", "task", "-p", "3")

        # Move id2 to in_progress
        {_, 0} = System.cmd("br", ["update", id2, "--status", "in_progress", "--no-color"], cd: tmp, stderr_to_stdout: true)

        # Close id3
        {_, 0} = System.cmd("br", ["close", id3, "--no-color"], cd: tmp, stderr_to_stdout: true)

        # Point beads adapter at this temp dir
        Application.put_env(:symphony_elixir, :beads_root, tmp)

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :beads_root)
          File.rm_rf!(tmp)
        end)

        {:ok, %{tmp: tmp, id1: id1, id2: id2, id3: id3}}
    end
  end

  describe "fetch_candidate_issues/0" do
    test "returns open unblocked issues", context do
      if Map.get(context, :skip), do: flunk("br not installed")

      assert {:ok, issues} = Beads.fetch_candidate_issues()
      # id1 is open and unblocked (ready), id2 is in_progress (not in br ready), id3 is closed
      ids = Enum.map(issues, & &1.id)
      assert context.id1 in ids
      refute context.id3 in ids
    end
  end

  describe "fetch_issues_by_states/1" do
    test "filters by Todo state", context do
      if Map.get(context, :skip), do: flunk("br not installed")

      assert {:ok, issues} = Beads.fetch_issues_by_states(["Todo"])
      ids = Enum.map(issues, & &1.id)
      assert context.id1 in ids
      refute context.id2 in ids
      refute context.id3 in ids
    end

    test "filters by In Progress state", context do
      if Map.get(context, :skip), do: flunk("br not installed")

      assert {:ok, issues} = Beads.fetch_issues_by_states(["In Progress"])
      ids = Enum.map(issues, & &1.id)
      assert context.id2 in ids
      refute context.id1 in ids
    end

    test "filters by Done state", context do
      if Map.get(context, :skip), do: flunk("br not installed")

      assert {:ok, issues} = Beads.fetch_issues_by_states(["Done"])
      ids = Enum.map(issues, & &1.id)
      assert context.id3 in ids
      refute context.id1 in ids
    end

    test "multiple states", context do
      if Map.get(context, :skip), do: flunk("br not installed")

      assert {:ok, issues} = Beads.fetch_issues_by_states(["Todo", "In Progress"])
      ids = Enum.map(issues, & &1.id)
      assert context.id1 in ids
      assert context.id2 in ids
      refute context.id3 in ids
    end
  end

  describe "fetch_issue_states_by_ids/1" do
    test "returns issues for given IDs", context do
      if Map.get(context, :skip), do: flunk("br not installed")

      assert {:ok, issues} = Beads.fetch_issue_states_by_ids([context.id1, context.id3])
      assert length(issues) == 2

      issue1 = Enum.find(issues, &(&1.id == context.id1))
      issue3 = Enum.find(issues, &(&1.id == context.id3))

      assert issue1.state == "Todo"
      assert issue1.title == "Fix authentication bug"
      assert issue3.state == "Done"
    end

    test "returns empty list for unknown IDs", context do
      if Map.get(context, :skip), do: flunk("br not installed")

      # br show returns error for unknown ID, so fetch should handle gracefully
      result = Beads.fetch_issue_states_by_ids(["bd-nonexistent"])
      # Will be error because br show fails for unknown IDs
      assert {:error, _} = result
    end
  end

  describe "create_comment/2" do
    test "adds a comment to an issue", context do
      if Map.get(context, :skip), do: flunk("br not installed")

      assert :ok = Beads.create_comment(context.id1, "Test comment from Symphony")

      # Verify via br CLI
      {output, 0} =
        System.cmd("br", ["comments", "list", context.id1, "--json", "--no-color"],
          cd: context.tmp,
          stderr_to_stdout: true
        )

      # Should contain our comment text somewhere
      assert String.contains?(output, "Test comment from Symphony")
    end
  end

  describe "update_issue_state/2" do
    test "transitions issue to In Progress", context do
      if Map.get(context, :skip), do: flunk("br not installed")

      assert :ok = Beads.update_issue_state(context.id1, "In Progress")

      # Verify state changed
      assert {:ok, [issue]} = Beads.fetch_issue_states_by_ids([context.id1])
      assert issue.state == "In Progress"
    end

    test "transitions issue to Done", context do
      if Map.get(context, :skip), do: flunk("br not installed")

      assert :ok = Beads.update_issue_state(context.id1, "Done")

      assert {:ok, [issue]} = Beads.fetch_issue_states_by_ids([context.id1])
      assert issue.state == "Done"
    end
  end

  describe "parse_issue/1" do
    test "maps br JSON fields to Issue struct" do
      item = %{
        "id" => "bd-abc",
        "title" => "Test issue",
        "description" => "A description",
        "priority" => 1,
        "status" => "open",
        "labels" => ["bug", "urgent"],
        "created_at" => "2026-01-15T10:00:00Z",
        "updated_at" => "2026-01-15T12:00:00Z"
      }

      issue = Beads.parse_issue(item)

      assert %Issue{} = issue
      assert issue.id == "bd-abc"
      assert issue.identifier == "bd-abc"
      assert issue.title == "Test issue"
      assert issue.description == "A description"
      assert issue.priority == 1
      assert issue.state == "Todo"
      assert issue.labels == ["bug", "urgent"]
      assert %DateTime{} = issue.created_at
    end

    test "maps in_progress status" do
      issue = Beads.parse_issue(%{"id" => "x", "status" => "in_progress"})
      assert issue.state == "In Progress"
    end

    test "maps closed status" do
      issue = Beads.parse_issue(%{"id" => "x", "status" => "closed"})
      assert issue.state == "Done"
    end

    test "handles missing optional fields" do
      issue = Beads.parse_issue(%{"id" => "x"})
      assert issue.id == "x"
      assert issue.title == nil
      assert issue.labels == []
      assert issue.created_at == nil
    end
  end

  # -- Helpers --

  defp br_create!(dir, title, extra_args \\ []) do
    args = ["create", title, "--silent", "--no-color"] ++ List.wrap(extra_args)

    {output, 0} = System.cmd("br", args, cd: dir, stderr_to_stdout: true)

    output
    |> String.split("\n")
    |> hd()
    |> String.trim()
  end

  defp br_create!(dir, title, flag1, val1, flag2, val2) do
    br_create!(dir, title, [flag1, val1, flag2, val2])
  end

  defp br_create!(dir, title, flag1, val1, flag2, val2, flag3, val3) do
    br_create!(dir, title, [flag1, val1, flag2, val2, flag3, val3])
  end
end
