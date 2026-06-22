defmodule Smaxr.DCPDisabledTest do
  use ExUnit.Case, async: true

  alias Smaxr.DCP
  alias Smaxr.LLM.Message

  defp msgs(count, role \\ :user) do
    Enum.map(1..count, fn i -> struct(Message, role: role, content: "message #{i}") end)
  end

  setup do
    # DCP is off by default — but be explicit to avoid flakiness if a
    # sibling test set the env.
    original = Application.get_env(:smaxr, :dcp_enabled, false)
    Application.put_env(:smaxr, :dcp_enabled, false)
    on_exit(fn -> Application.put_env(:smaxr, :dcp_enabled, original) end)
    :ok
  end

  describe "apply_strategies/2 (DCP disabled — default)" do
    test "passes messages through unchanged" do
      history = msgs(50, :user) ++ [Message.assistant("final")]
      {result, nudge, _state} = DCP.apply_strategies(history)
      assert result == history
      assert nudge == ""
    end

    test "does not compress or dedup or nudge, even with 100 messages" do
      history = msgs(100)
      {result, nudge, _state} = DCP.apply_strategies(history, compress_threshold: 20)
      assert length(result) == 100
      assert nudge == ""
    end
  end
end
