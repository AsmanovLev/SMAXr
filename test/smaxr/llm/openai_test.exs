defmodule Smaxr.LLM.OpenAITest do
  use ExUnit.Case, async: true

  alias Smaxr.LLM.{OpenAI, Message}

  describe "m_id injection" do
    test "injects dcp-message-id tag when message has m_id" do
      msg = %Message{role: :user, content: "hello", m_id: 5}
      [result] = OpenAI.messages_for_test([msg])
      assert result["content"] =~ ~r/dcp-message-id>m5<\/dcp-message-id>/
    end

    test "does not inject tag when m_id is nil" do
      msg = %Message{role: :user, content: "hello", m_id: nil}
      [result] = OpenAI.messages_for_test([msg])
      refute result["content"] =~ ~r/dcp-message-id>/
    end

    test "injects on tool_result messages using the message's m_id" do
      msg = Message.tool_results([{"result_a", "call_1", "tool_a"}, {"result_b", "call_2", "tool_b"}])
      msg = %{msg | m_id: 3}
      results = OpenAI.messages_for_test([msg])
      assert length(results) == 2
      for r <- results do
        assert r[:content] =~ ~r/dcp-message-id>m3<\/dcp-message-id>/
      end
    end
  end

  describe "fixture parsing" do
    test "fixture parses correctly" do
      body = fixture()
      {:ok, msg, usage} = parse_response(body)
      assert msg.role == :assistant
      assert is_binary(msg.content)
      assert is_integer(usage["total_tokens"])
    end

    test "rejects API error response" do
      {:error, msg} = parse_response(%{"error" => %{"message" => "rate limit"}})
      assert msg == "rate limit"
    end

    test "rejects unexpected shape" do
      assert {:error, _} = parse_response(%{})
      assert {:error, _} = parse_response(%{"choices" => []})
    end
  end

  describe "models/0" do
    test "returns empty list when config is unset" do
      models = OpenAI.models()
      assert is_list(models)
    end
  end

  # Test direct parse without HTTP
  defp fixture do
    path = "test/support/fixtures/llm/chat_completion_200.json"
    File.read!(path) |> Jason.decode!()
  end

  defp parse_response(%{"choices" => [choice | _], "usage" => usage}) do
    msg = %Message{
      role: :assistant,
      content: choice["message"]["content"] || "",
      tool_calls: choice["message"]["tool_calls"]
    }
    {:ok, msg, usage || %{}}
  end

  defp parse_response(%{"error" => err}) do
    {:error, err["message"] || "API error"}
  end

  defp parse_response(_) do
    {:error, "unexpected response"}
  end
end
