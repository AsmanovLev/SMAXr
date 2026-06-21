#!/usr/bin/env elixir
#
# Integration smoke test for the full SMAXr + konsolidator flow.
#
# Starts the apps, registers a fake "Telegram" GenServer that captures
# outgoing messages, publishes a fake incoming event, and asserts that
# SMAXr's agent receives the message and tries to reply.
#
# Run with:
#   mix run scripts/smoke_integration.exs
#
# Exits with status 0 on success, 1 on failure.

defmodule SmokeTest.FakeTelegram do
  @moduledoc "Stand-in for the real Telegram adapter. Captures sent messages."

  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def get_sent, do: GenServer.call(__MODULE__, :get)
  def reset, do: GenServer.call(__MODULE__, :reset)

  def send(_adapter, user_id, content) do
    GenServer.call(__MODULE__, {:send, user_id, content})
  end

  def edit(_, _, _, _), do: :ok
  def delete(_, _, _), do: :ok
  def typing(_, _, _), do: :ok
  def answer_callback(_, _, _), do: :ok

  def name, do: :fake_telegram
  def capabilities, do: [:send_text, :edit_text, :delete_message, :send_file, :send_photo, :inline_buttons, :edit_buttons, :url_buttons, :typing_indicator, :reply_to]

  @impl true
  def init(_), do: {:ok, []}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, Enum.reverse(state), state}
  def handle_call(:reset, _from, _), do: {:reply, :ok, []}
  def handle_call({:send, _user_id, content}, _from, state) do
    {:reply, {:ok, length(state) + 1}, [content | state]}
  end
end

# Override the Telegram alias by replacing the registered name in the
# Smaxr.Agent module. Easiest: we use a wrapper. The agent calls
# Konsolidator.Adapters.Telegram directly, so we patch the name registry.

ExUnit.start(autorun: false)

{:ok, _} = Application.ensure_all_started(:smaxr)
Process.sleep(100)

# Stop the real Telegram adapter if it was started by Konsolidator.Supervisor.
# (In test/dev config, no adapter is started, but be defensive.)
old_tg = Process.whereis(Konsolidator.Adapters.Telegram)
if old_tg do
  Process.unregister(Konsolidator.Adapters.Telegram)
  GenServer.stop(old_tg, :normal, 100)
end

# Start the fake GenServer under BOTH names.
{:ok, fake_pid} = GenServer.start_link(SmokeTest.FakeTelegram, [], name: __MODULE__)
true = Process.register(fake_pid, Konsolidator.Adapters.Telegram)

# Reset the fake's state. Use the pid (since the original name is unregistered
# after we re-registered under the Telegram name).
GenServer.call(fake_pid, :reset)

# Make sure the agent supervisor is running.
unless Process.whereis(Smaxr.Agent.Supervisor) do
  IO.puts("FAIL: Smaxr.Agent.Supervisor not started")
  System.halt(1)
end

# Inject a fake incoming message as if it came from Telegram.
test_user_id = 12_345

Konsolidator.Router.publish_incoming(%{
  source: :telegram,
  user_id: test_user_id,
  text: "smoke test hello",
  ref: 99,
  raw: nil
})

# Wait for the agent to process and reply.
Process.sleep(500)

# Verify the agent was started.
agent_pid = Smaxr.Agent.whereis(test_user_id)
unless agent_pid do
  IO.puts("FAIL: Agent for user_id=#{test_user_id} was not started")
  System.halt(1)
end

# Verify the agent received the message.
state = :sys.get_state(agent_pid)
unless state.message_count == 1 do
  IO.puts("FAIL: message_count expected 1, got #{state.message_count}")
  System.halt(1)
end

# Verify the fake Telegram received a send from the agent.
sent = GenServer.call(fake_pid, :get)
unless length(sent) == 1 do
  IO.puts("FAIL: expected 1 message sent, got #{length(sent)}")
  IO.inspect(sent, label: "sent")
  System.halt(1)
end

[content] = sent
unless content.text =~ "received: smoke test hello" do
  IO.puts("FAIL: message text does not match")
  IO.inspect(content, label: "content")
  System.halt(1)
end

unless length(content.buttons) == 1 and length(hd(content.buttons)) == 2 do
  IO.puts("FAIL: buttons not set correctly")
  IO.inspect(content.buttons, label: "buttons")
  System.halt(1)
end

IO.puts("OK: SMAXr + konsolidator integration smoke test passed.")
IO.puts("  - User message: \"smoke test hello\"")
IO.puts("  - Agent state: message_count=#{state.message_count}, last_ref=#{inspect(state.last_ref)}")
IO.puts("  - Telegram fake received: #{length(sent)} message(s)")
IO.puts("  - Reply text: #{content.text}")
IO.puts("  - Reply buttons: #{inspect(content.buttons)}")

System.halt(0)
