defmodule Smaxr.LLM.AnthropicParseTest do
  use ExUnit.Case, async: true

  alias Smaxr.LLM.Anthropic

  describe "parse_result/1 — thinking-only block" do
    test "returns empty text when only thinking is present (no text, no tool_use)" do
      body = %{
        "content" => [
          %{
            "type" => "thinking",
            "thinking" => "Let me think about this…",
            "signature" => "abc123"
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      assert {:ok, msg, _usage} = Anthropic.parse_result(body)
      assert msg.content == ""
      assert msg.tool_calls == nil
      assert msg.thinking == "Let me think about this…"
      assert msg.signature == "abc123"
    end

    test "returns real text when text block is present alongside thinking" do
      body = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "hmm", "signature" => "sig"},
          %{"type" => "text", "text" => "Here is my answer."}
        ],
        "usage" => %{}
      }

      assert {:ok, msg, _} = Anthropic.parse_result(body)
      assert msg.content == "Here is my answer."
    end

    test "returns empty text when tool_use is present but no text block" do
      body = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "calling tool", "signature" => "s"},
          %{"type" => "tool_use", "id" => "tool_1", "name" => "list_dir", "input" => %{}}
        ],
        "usage" => %{}
      }

      assert {:ok, msg, _} = Anthropic.parse_result(body)
      assert msg.content == ""
      assert is_list(msg.tool_calls)
      assert length(msg.tool_calls) == 1
    end
  end
end
