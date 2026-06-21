defmodule Smaxr.DCPTest do
  use ExUnit.Case, async: false

  alias Smaxr.DCP
  alias Smaxr.LLM.Message

  defp msgs(count, role \\ :user, content \\ nil) do
    Enum.map(1..count, fn i ->
      c = content || "message #{i}"
      struct(Message, role: role, content: c)
    end)
  end

  setup do
    # Active prune strategies are off by default; tests exercise the
    # enabled code path. Restore the default (off) on exit.
    original = Application.get_env(:smaxr, :dcp_enabled, false)
    Application.put_env(:smaxr, :dcp_enabled, true)
    on_exit(fn -> Application.put_env(:smaxr, :dcp_enabled, original) end)
    :ok
  end

  describe "estimate_tokens/1" do
    test "rough 4-chars-per-token heuristic" do
      m = struct(Message, role: :user, content: String.duplicate("a", 400))
      assert DCP.estimate_tokens([m]) == 100
    end
  end

  describe "apply_strategies/2 (DCP enabled, under budget)" do
    test "small history passes through unchanged" do
      history = msgs(5)
      {result, nudge} = DCP.apply_strategies(history, token_budget: 100_000)
      assert length(result) == 5
      assert nudge == ""
    end
  end

  describe "apply_strategies/2 (DCP enabled, over budget)" do
    test "compresses oldest turns into a digest" do
      history = build_long_history(turn_count: 30, msgs_per_turn: 2, content: String.duplicate("alpha ", 20))
      {result, _nudge} = DCP.apply_strategies(history, token_budget: 500)

      # 1 digest + keep_turns=10 turns × 2 msgs/turn = 1 + 20 = 21
      assert length(result) == 1 + 10 * 2
      # First message is the digest
      assert hd(result).role == :system
      digest_text = hd(result).content
      assert digest_text =~ "Conversation summary"
      assert digest_text =~ "alpha"
    end

    test "digest mentions tool names that were called" do
      tool_msgs =
        [
          Message.user(String.duplicate("find the file ", 30)),
          Message.assistant_with_thinking("", [%{"id" => "c1", "function" => %{"name" => "find_files"}}], nil, nil),
          Message.tool_results([{String.duplicate("found 3 ", 30), "c1", "find_files"}]),
          Message.user("goodbye")
        ] ++ Enum.map(1..20, fn i -> Message.user(String.duplicate("hi ", 30) <> "#{i}") end)

      {result, _} = DCP.apply_strategies(tool_msgs, token_budget: 100)
      digest = hd(result)
      assert digest.role == :system
      assert digest.content =~ "find_files"
    end

    test "never breaks tool_use / tool_result pairs (no orphan tool_results)" do
      # 12 turns of [user, asst_with_tool, tool_results]. DCP must keep
      # the last N turns intact, so any remaining tool_result must have
      # a matching tool_use in the same kept slice.
      history =
        for n <- 1..20 do
          [
            Message.user("u#{n}"),
            Message.assistant_with_thinking(
              "",
              [%{"id" => "c#{n}", "function" => %{"name" => "t"}}],
              nil,
              nil
            ),
            Message.tool_results([{"r#{n}", "c#{n}", "t"}])
          ]
        end
        |> List.flatten()

      {result, _} = DCP.apply_strategies(history, token_budget: 200)

      # Find the first non-system message; if it's a tool, we've broken
      # a cycle.
      first_kept = result |> Enum.drop_while(&(&1.role == :system)) |> List.first()

      case first_kept do
        nil ->
          :ok

        %Message{role: :tool} ->
          flunk("DCP broke a tool cycle: first kept message is a tool result")

        _ ->
          :ok
      end
    end
  end

  describe "truncate_long_tool_results" do
    test "long tool results are truncated but cycle preserved" do
      long = String.duplicate("x", 5000)
      history = [
        Message.user("read big file"),
        Message.assistant_with_thinking("", [%{"id" => "c1", "function" => %{"name" => "read_file"}}], nil, nil),
        Message.tool_results([{long, "c1", "read_file"}])
      ] ++ msgs(2)

      {result, _} = DCP.apply_strategies(history, token_budget: 10, tool_result_max_chars: 500)

      # Find the tool message and verify truncation
      tool_msg = Enum.find(result, &match?(%Message{role: :tool}, &1))
      assert tool_msg
      truncated = Enum.at(tool_msg.tool_results, 0) |> elem(0)
      assert String.length(truncated) < 1000
      assert truncated =~ "truncated by DCP"
    end
  end

  describe "tombstone_retry_loops" do
    test "3+ consecutive failures of the same tool get tombstoned" do
      fail = "error: file not found"
      history = [
        Message.user("read foo.txt"),
        Message.assistant_with_thinking("", [%{"id" => "c1", "function" => %{"name" => "read_file"}}], nil, nil),
        Message.tool_results([{fail, "c1", "read_file"}]),
        Message.assistant_with_thinking("", [%{"id" => "c2", "function" => %{"name" => "read_file"}}], nil, nil),
        Message.tool_results([{fail, "c2", "read_file"}]),
        Message.assistant_with_thinking("", [%{"id" => "c3", "function" => %{"name" => "read_file"}}], nil, nil),
        Message.tool_results([{fail, "c3", "read_file"}])
      ]

      {result, _} = DCP.apply_strategies(history, token_budget: 10, retry_threshold: 3)

      # All three tool_results should be tombstoned
      tool_results =
        result
        |> Enum.flat_map(fn
          %Message{role: :tool, tool_results: trs} -> trs || []
          _ -> []
        end)
        |> Enum.map(&elem(&1, 0))

      assert Enum.all?(tool_results, &String.contains?(&1, "tombstoned"))
    end

    test "only 2 failures (under threshold) are kept verbatim" do
      fail = "error: file not found"
      history = [
        Message.user("read foo"),
        Message.assistant_with_thinking("", [%{"id" => "c1", "function" => %{"name" => "read_file"}}], nil, nil),
        Message.tool_results([{fail, "c1", "read_file"}]),
        Message.assistant_with_thinking("", [%{"id" => "c2", "function" => %{"name" => "read_file"}}], nil, nil),
        Message.tool_results([{fail, "c2", "read_file"}])
      ]

      {result, _} = DCP.apply_strategies(history, token_budget: 10, retry_threshold: 3)

      tool_results =
        result
        |> Enum.flat_map(fn
          %Message{role: :tool, tool_results: trs} -> trs || []
          _ -> []
        end)
        |> Enum.map(&elem(&1, 0))

      # Only 2 failures — none should be tombstoned (under threshold)
      refute Enum.any?(tool_results, &String.contains?(&1, "tombstoned"))
    end
  end

  describe "nudge_for" do
    test "nudge appears at >=50% budget" do
      history = msgs(50, :user, String.duplicate("x", 4000))
      {_, nudge} = DCP.apply_strategies(history, token_budget: 1000)
      assert nudge =~ "Context:"
    end
  end

  # Build a long history with the given number of user turns, each
  # containing `msgs_per_turn` messages (one user, one assistant, etc).
  defp build_long_history(opts \\ []) do
    turn_count = Keyword.get(opts, :turn_count, 25)
    msgs_per_turn = Keyword.get(opts, :msgs_per_turn, 3)
    content = Keyword.get(opts, :content, "x")

    Enum.flat_map(1..turn_count, fn t ->
      [
        Message.user("#{content} #{t}"),
        Message.assistant("ok #{t}"),
        Message.user("thanks")
      ]
      |> Enum.take(msgs_per_turn)
    end)
  end
end
