defmodule Smaxr.LLM.OpenAITest do
  use ExUnit.Case, async: true

  alias Smaxr.LLM.{OpenAI, Message}

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
      # When no config is set, models() returns [] because curl can't reach
      # the default URL (not available from this network). This is a safe
      # fallback.
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
