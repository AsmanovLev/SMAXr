defmodule Smaxr.LLM.MessageTest do
  use ExUnit.Case, async: true
  alias Smaxr.LLM.Message

  test "system/1 creates a system message" do
    msg = Message.system("You are helpful.")
    assert msg.role == :system
    assert msg.content == "You are helpful."
  end

  test "user/1 creates a user message" do
    msg = Message.user("Hello!")
    assert msg.role == :user
    assert msg.content == "Hello!"
  end

  test "assistant/2 creates an assistant message with optional tool_calls" do
    msg = Message.assistant("Sure", [%{"id" => "1", "function" => %{"name" => "test"}}])
    assert msg.role == :assistant
    assert msg.content == "Sure"
    assert length(msg.tool_calls) == 1
  end

  test "tool/3 creates a tool response" do
    msg = Message.tool("42", "call-1", "calculator")
    assert msg.role == :tool
    assert msg.content == "42"
    assert msg.tool_call_id == "call-1"
    assert msg.name == "calculator"
  end

  test "to_map/1 converts to wire format" do
    msg = Message.user("hi")
    assert Message.to_map(msg) == %{"role" => "user", "content" => "hi"}
  end

  test "to_map/1 includes tool_calls when present" do
    tc = [%{"id" => "1", "type" => "function", "function" => %{"name" => "f", "arguments" => "{}"}}]
    msg = Message.assistant("ok", tc)
    map = Message.to_map(msg)
    assert map["tool_calls"] == tc
  end

  test "to_map/1 includes tool_call_id for tool messages" do
    msg = Message.tool("result", "c-1", "fn")
    map = Message.to_map(msg)
    assert map["tool_call_id"] == "c-1"
    assert map["name"] == "fn"
  end
end
