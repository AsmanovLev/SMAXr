defmodule Smaxr.AgentDCPTest do
  @moduledoc """
  Tests for the model-driven DCP pieces that live in the agent:
  - m_id auto-assignment in push/2
  - apply_pending_compress/1 (the splice + renumber + system block)
  - reasoning_content round-trip (parse captures, to_map echoes)

  These complement compress_test.exs (input validation) and
  dcp_test.exs (old server-side heuristics). Together they cover
  the full DCP pipeline.
  """
  use ExUnit.Case, async: false

  alias Smaxr.Agent
  alias Smaxr.LLM.Message

  defp base_state do
    %{
      user_id: 42,
      messages: [],
      message_count: 0,
      last_ref: nil,
      model: "test-model",
      max_steps: 50,
      busy: false,
      cancel: false,
      pending: []
    }
  end

  describe "m_id auto-assignment" do
    test "each push increments m_id from previous length" do
      state = base_state()
      state = Agent.push_for_test(state, Message.user("first"))
      assert List.last(state.messages).m_id == 1
      state = Agent.push_for_test(state, Message.user("second"))
      assert List.last(state.messages).m_id == 2
      state = Agent.push_for_test(state, Message.assistant("third"))
      assert List.last(state.messages).m_id == 3
    end
  end

  describe "apply_pending_compress/1 (no pending)" do
    test "returns state unchanged when no compress tool was called" do
      state = base_state() |> Agent.push_for_test(Message.user("hello"))
      Process.delete(:smaxr_compress)
      result = Agent.apply_pending_compress_for_test(state)
      assert result.messages == state.messages
    end
  end

  describe "apply_pending_compress/1 (single range)" do
    setup do
      Process.delete(:smaxr_compress)
      on_exit(fn -> Process.delete(:smaxr_compress) end)
      :ok
    end

    test "splices a range and inserts a system block with the topic and summary" do
      state =
        base_state()
        |> Agent.push_for_test(Message.user("m1 user"))
        |> Agent.push_for_test(Message.assistant("m2 reply"))
        |> Agent.push_for_test(Message.user("m3 user"))
        |> Agent.push_for_test(Message.assistant("m4 reply"))
        |> Agent.push_for_test(Message.user("m5 user"))

      Process.put(:smaxr_compress, {"auth flow", [{1, 3, "User asked about auth; agent explained setup"}]})

      result = Agent.apply_pending_compress_for_test(state)

      # m1..m3 are gone; only m4, m5, plus the system block remain
      assert length(result.messages) == 3

      last = List.last(result.messages)
      assert last.role == :system
      assert last.content =~ "auth flow"
      assert last.content =~ "User asked about auth"

      # m_ids are renumbered 1..N
      m_ids = Enum.map(result.messages, & &1.m_id)
      assert m_ids == [1, 2, 3]
    end

    test "renumbering preserves the system block as the last message" do
      state = base_state() |> Agent.push_for_test(Message.user("only"))
      Process.put(:smaxr_compress, {"topic", [{1, 1, "summary"}]})

      result = Agent.apply_pending_compress_for_test(state)
      assert length(result.messages) == 1
      assert List.last(result.messages).role == :system
      assert List.last(result.messages).m_id == 1
    end
  end

  describe "apply_pending_compress/1 (multiple ranges, high to low)" do
    setup do
      Process.delete(:smaxr_compress)
      on_exit(fn -> Process.delete(:smaxr_compress) end)
      :ok
    end

    test "splices both ranges from the highest to the lowest" do
      state =
        base_state()
        |> Agent.push_for_test(Message.user("m1"))
        |> Agent.push_for_test(Message.assistant("m2"))
        |> Agent.push_for_test(Message.user("m3"))
        |> Agent.push_for_test(Message.assistant("m4"))
        |> Agent.push_for_test(Message.user("m5"))
        |> Agent.push_for_test(Message.assistant("m6"))
        |> Agent.push_for_test(Message.user("m7"))

      Process.put(:smaxr_compress, {
        "two topics",
        [
          {5, 6, "second half summary"},
          {1, 2, "first half summary"}
        ]
      })

      result = Agent.apply_pending_compress_for_test(state)
      # m1, m2, m5, m6 removed; m3, m4, m7 + system block remain
      assert length(result.messages) == 4
      assert List.last(result.messages).role == :system
      assert List.last(result.messages).content =~ "two topics"
    end
  end

  describe "apply_pending_compress/1 — clears Process dict" do
    setup do
      Process.delete(:smaxr_compress)
      on_exit(fn -> Process.delete(:smaxr_compress) end)
      :ok
    end

    test "removes :smaxr_compress from Process dict after applying" do
      state = base_state() |> Agent.push_for_test(Message.user("a"))
      Process.put(:smaxr_compress, {"x", [{1, 1, "y"}]})

      Agent.apply_pending_compress_for_test(state)
      assert Process.get(:smaxr_compress) == nil
    end
  end

  describe "reasoning_content round-trip" do
    test "parse stores reasoning_content, to_map echoes it back" do
      # Simulate the API response shape
      body = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "Hello user",
              "reasoning_content" => "thinking about it"
            }
          }
        ],
        "usage" => %{}
      }

      {:ok, msg, _usage} = Smaxr.LLM.OpenAI.parse_result_for_test(body)
      assert msg.content == "Hello user"
      assert msg.thinking == "thinking about it"

      # Echo back to the API
      out = Message.to_map(msg)
      assert out["reasoning_content"] == "thinking about it"
    end

    test "to_map omits reasoning_content when message has no thinking" do
      msg = %Message{role: :assistant, content: "no thought"}
      out = Message.to_map(msg)
      refute Map.has_key?(out, "reasoning_content")
    end
  end
end
