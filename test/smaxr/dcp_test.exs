defmodule Smaxr.DCPTest do
  use ExUnit.Case

  alias Smaxr.DCP
  alias Smaxr.LLM.Message

  defp msgs(count, role \\ :user) do
    Enum.map(1..count, fn i -> struct(Message, role: role, content: "message #{i}") end)
  end

  setup do
    # These tests exercise the active prune strategies, so enable DCP
    # for the duration of the test and restore the default (off) after.
    original = Application.get_env(:smaxr, :dcp_enabled, false)
    Application.put_env(:smaxr, :dcp_enabled, true)
    on_exit(fn -> Application.put_env(:smaxr, :dcp_enabled, original) end)
    :ok
  end

  describe "apply_strategies/2 (DCP enabled)" do
    test "does not compress small histories" do
      history = msgs(5)
      {result, nudge} = DCP.apply_strategies(history)
      assert length(result) == 5
      assert nudge == ""
    end

    test "compresses old messages when over threshold" do
      history = msgs(55)
      {result, _nudge} = DCP.apply_strategies(history, compress_threshold: 20)
      assert length(result) < length(history)
      assert length(result) <= 21
    end

    test "nudge triggers for very long conversations" do
      history = msgs(60)
      {_result, nudge} = DCP.apply_strategies(history, compress_threshold: 55)
      assert nudge != ""
    end

    test "compresses 30 messages into summary + 15 recent" do
      history = msgs(30)
      {result, _nudge} = DCP.apply_strategies(history, compress_threshold: 15)
      assert length(result) <= 16
      # First message should be a system message (the compressed summary)
      assert hd(result).role == :system
      assert hd(result).content =~ "compressed"
    end

    test "dedup removes excessive tool call cycles" do
      tool_msgs = [
        Message.assistant("", [%{function: %{name: "test"}}]),
        Message.tool("result", "1", "test"),
        Message.assistant(""),
        Message.assistant("", [%{function: %{name: "test2"}}]),
        Message.tool("result2", "2", "test2"),
        Message.assistant("final")
      ]

      {result, _} = DCP.apply_strategies(tool_msgs)
      # Should not crash or lose the final message
      assert Enum.any?(result, fn m -> m.role == :assistant and m.tool_calls == nil end)
    end

    test "purges error messages" do
      messages = [
        Message.user("do something"),
        Message.assistant("", [%{function: %{name: "test"}}]),
        Message.tool("error: connection failed", "1", "test"),
        Message.tool("error: timeout", "2", "test"),
        Message.user("continue")
      ]

      {result, _} = DCP.apply_strategies(messages)
      remaining_errors = Enum.filter(result, &is_error_message?(&1))
      assert remaining_errors == []
    end
  end

  describe "should_compress?/2" do
    test "returns true when over threshold" do
      assert DCP.should_compress?(msgs(21), 20) == true
    end

    test "returns false when under threshold" do
      assert DCP.should_compress?(msgs(10), 20) == false
    end
  end

  describe "split_at_newest safe boundary" do
    test "does not split mid tool-cycle (kept slice starts with user)" do
      # 25 messages, threshold 20, naive split would cut at 5 = mid tool-cycle
      # `[user, asst_3tcu, tool_3results, asst_3tcu, tool_3results | keep...]`
      # The kept slice would start with `tool_3results` (orphan). Safe split
      # should advance to the next `:user` message.
      history =
        [
          Message.user("u0"),
          Message.assistant_with_thinking("a0", [%{"id" => "c0", "function" => %{"name" => "t"}}], nil, nil),
          Message.tool_results([{"r0", "c0", "t"}]),
          Message.assistant_with_thinking("a1", [%{"id" => "c1", "function" => %{"name" => "t"}}], nil, nil),
          Message.tool_results([{"r1", "c1", "t"}]),
          Message.user("u1"),
          Message.assistant_with_thinking("a2", [%{"id" => "c2", "function" => %{"name" => "t"}}], nil, nil),
          Message.tool_results([{"r2", "c2", "t"}])
        ] ++ msgs(17, :user)

      {result, _} = DCP.apply_strategies(history, compress_threshold: 20)
      # First message should be the compressed system summary
      assert hd(result).role == :system
      # Second message (start of kept slice) should be a :user, not :tool
      assert result |> Enum.at(1) |> Map.get(:role) == :user
    end
  end

  defp is_error_message?(%{role: :tool, content: c}) when is_binary(c) do
    String.contains?(c, ["error:", "failed:", "timeout"])
  end

  defp is_error_message?(_), do: false
end
