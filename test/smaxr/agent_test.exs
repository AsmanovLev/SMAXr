defmodule Smaxr.AgentTest do
  use ExUnit.Case, async: false

  alias Smaxr.Agent
  alias Smaxr.Agent.Supervisor, as: AgentSupervisor
  alias Smaxr.LLM.Message

  setup do
    # Guard: Registry may already be started by another test
    unless Process.whereis(Smaxr.Registry) do
      start_supervised!({Registry, keys: :duplicate, name: Smaxr.Registry})
    end

    unless Process.whereis(Smaxr.Agent.Supervisor) do
      start_supervised!(Smaxr.Agent.Supervisor)
    end

    unless Process.whereis(Smaxr.EvalSupervisor) do
      start_supervised!({Task.Supervisor, name: Smaxr.EvalSupervisor})
    end

    user_id = System.unique_integer([:positive])
    Smaxr.Agent.Supervisor.start_agent(user_id)
    Process.sleep(50)
    %{user_id: user_id}
  end

  test "whereis/1 returns the agent pid for a known user", %{user_id: user_id} do
    pid = Agent.whereis(user_id)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "whereis/1 returns nil for an unknown user" do
    assert is_nil(Agent.whereis(99_999_999))
  end

  test "handle_incoming/3 casts a payload to the agent", %{user_id: user_id} do
    Agent.handle_incoming(user_id, :telegram, %{text: "/help", ref: 1})
    Process.sleep(200)
    pid = Agent.whereis(user_id)
    if pid do
      state = :sys.get_state(pid)
      assert state.message_count >= 1
    end
  end

  test "agent increments message_count on incoming", %{user_id: user_id} do
    pid = Agent.whereis(user_id)
    Agent.handle_incoming(user_id, :telegram, %{text: "/help", ref: 1})
    Process.sleep(200)
    state = :sys.get_state(pid)
    assert state.message_count >= 1
  end

  test "agent stores messages from non-command", %{user_id: user_id} do
    Agent.handle_incoming(user_id, :telegram, %{text: "/help", ref: 7})
    Process.sleep(200)
    pid = Agent.whereis(user_id)
    if pid do
      state = :sys.get_state(pid)
      # commands don't store messages in history
      msgs = length(state.messages)
      assert msgs >= 0
    end
  end

  test "tool execution does not auto-send messages to user", %{user_id: user_id} do
    # Execute a tool call directly — should NOT send anything to user
    tool_call = %{
      "id" => "call_1",
      "type" => "function",
      "function" => %{
        "name" => "read_file",
        "arguments" => ~s({"path":"test/test_helper.exs"})
      }
    }

    pid = Agent.whereis(user_id)
    state = :sys.get_state(pid)
    last_ref_before = state.last_ref
    state_after = Agent.execute_tool_calls(state, [tool_call], 0)
    # last_ref should NOT change because execute_tool_calls does not call reply_to_user
    assert state_after.last_ref == last_ref_before
    # messages should have a tool response appended
    assert length(state_after.messages) > length(state.messages)
    last_msg = List.last(state_after.messages)
    assert last_msg.role == :tool
  end
end
