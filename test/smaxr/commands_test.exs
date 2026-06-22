defmodule Smaxr.CommandsTest do
  use ExUnit.Case, async: true

  alias Smaxr.Commands

  def agent_state(opts \\ []) do
    %{
      user_id: 1,
      messages: [],
      message_count: 0,
      last_ref: nil,
      model: opts[:model] || "deepseek-v4-flash",
      provider: opts[:provider] || "openai",
      max_steps: 200
    }
  end

  describe "parse/1" do
    test "parses /start" do
      assert {:command, "start", ""} = Commands.parse("/start")
    end

    test "parses /help" do
      assert {:command, "help", ""} = Commands.parse("/help")
    end

    test "parses /model with args" do
      assert {:command, "model", "kimi-k2.6"} = Commands.parse("/model kimi-k2.6")
    end

    test "parses /maxsteps with number" do
      assert {:command, "maxsteps", "50"} = Commands.parse("/maxsteps 50")
    end

    test "returns nil for unknown command" do
      assert is_nil(Commands.parse("/unknown"))
    end

    test "returns nil for plain text" do
      assert is_nil(Commands.parse("hello world"))
    end
  end

  describe "execute/4" do
    test "/start returns welcome" do
      {:handled, reply, _state} = Commands.execute("start", "", :telegram, agent_state())
      assert reply =~ "SMAXr"
    end

    test "/help returns command list" do
      {:handled, reply, _state} = Commands.execute("help", "", :telegram, agent_state())
      assert reply =~ "/start"
    end

    test "/new clears messages" do
      state = agent_state() |> Map.put(:messages, [%{}])
      {:handled, _reply, new_state} = Commands.execute("new", "", :telegram, state)
      assert new_state.messages == []
      assert new_state.message_count == 0
    end

    test "/model shows current model" do
      {:handled, reply, _state} = Commands.execute("model", "", :telegram, agent_state(model: "test-model"))
      assert reply =~ "test-model"
    end

    test "/model sets new model" do
      # use a real alias from the registry so validation passes
      alias_name = Smaxr.Models.list() |> hd() |> Map.get(:id)
      {:handled, reply, new_state} = Commands.execute("model", alias_name, :telegram, agent_state())
      assert new_state.model == alias_name
      assert reply =~ alias_name
    end

    test "/model rejects unknown model" do
      base = agent_state()
      base = %{base | model: nil}
      {:handled, reply, new_state} = Commands.execute("model", "definitely-not-a-model-xyz", :telegram, base)
      assert reply =~ "unknown model"
      # state unchanged
      assert new_state.model == nil
    end

    test "/version returns formatted string" do
      {:handled, reply, _state} = Commands.execute("version", "", :telegram, agent_state())
      assert reply =~ "SMAXr"
    end

    test "/tools lists available tools" do
      {:handled, reply, _state} = Commands.execute("tools", "", :telegram, agent_state())
      assert reply =~ "terminal"
      assert reply =~ "read_file"
    end

    test "/maxsteps shows current value" do
      {:handled, reply, _state} = Commands.execute("maxsteps", "", :telegram, agent_state())
      assert reply =~ "200"
    end

    test "/maxsteps sets new value" do
      {:handled, _reply, state} = Commands.execute("maxsteps", "50", :telegram, agent_state())
      assert state.max_steps == 50
    end

    test "/sessions shows info" do
      {:handled, reply, _state} = Commands.execute("sessions", "", :telegram, agent_state())
      assert reply =~ "Active session"
    end

    test "/compress returns stub" do
      {:handled, reply, _state} = Commands.execute("compress", "", :telegram, agent_state())
      assert reply =~ "compress"
    end

    test "/dcp returns stub" do
      {:handled, reply, _state} = Commands.execute("dcp", "", :telegram, agent_state())
      assert reply =~ "DCP"
    end
  end
end
