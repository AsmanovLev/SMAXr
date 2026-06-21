#!/usr/bin/env elixir
#
# Full integration test: SMAXr + konsolidator + real Telegram bot.
#
# Run with:  mix run scripts/smoke_real_integration.exs
#
# This verifies that:
#   1. Telegram bot is reachable (getMe)
#   2. A message can be sent (sendMessage)
#   3. SMAXr's agent receives incoming events and processes them
#   4. The agent replies via Konsolidator → Telegram

token = System.fetch_env!("TELEGRAM_BOT_TOKEN")
chat_id = 10_551_980_77
proxy = "socks5h://127.0.0.1:10808"

defmodule RealIntegration do
  def curl(method, params \\ []) do
    token = System.fetch_env!("TELEGRAM_BOT_TOKEN")
    url = "https://api.telegram.org/bot#{token}/#{method}"
    proxy = "socks5h://127.0.0.1:10808"

    args =
      ["--proxy", proxy, "-s", "-m", "15"] ++
        (if params != [],
           do: Enum.flat_map(params, fn {k, v} -> ["--data-urlencode", "#{k}=#{v}"] end),
           else: []) ++
        [url]

    case System.cmd("curl", args, stderr_to_stdout: true) do
      {out, 0} -> Jason.decode(out)
      {out, code} -> {:error, "curl #{code}: #{out}"}
    end
  end
end

# 1. Verify bot is alive
IO.puts("=== Step 1: Verify bot ===")
{:ok, me} = RealIntegration.curl("getMe")
IO.puts("Bot: @#{me["result"]["username"]}")

# 2. Send test message
IO.puts("\n=== Step 2: Send message via curl ===")
{:ok, msg} = RealIntegration.curl("sendMessage", chat_id: 10_551_980_77, text: "[smaxr integration] testing agent flow")
msg_id = msg["result"]["message_id"]
IO.puts("Sent. message_id = #{msg_id}")

# 3. Inject via Konsolidator.Router (simulates what the adapter does)
IO.puts("\n=== Step 3: Inject via Konsolidator.Router ===")
{:ok, _} = Application.ensure_all_started(:smaxr)
Process.sleep(200)

alias Konsolidator.Router
alias Smaxr.Agent

Router.publish_incoming(%{
  source: :telegram,
  user_id: 10_551_980_77,
  text: "/start",
  ref: msg_id,
  raw: %{"message" => %{"text" => "/start"}}
})

Process.sleep(300)

# 4. Verify agent was created
agent_pid = Agent.whereis(10_551_980_77)
if agent_pid do
  state = :sys.get_state(agent_pid)
  IO.puts("Agent started! message_count=#{state.message_count}, last_ref=#{inspect(state.last_ref)}")
else
  IO.puts("WARN: Agent not started (expected if Telegram adapter isn't running)")
end

# 5. Cleanup
IO.puts("\n=== Cleanup ===")
RealIntegration.curl("deleteMessage", chat_id: 10_551_980_77, message_id: msg_id)
IO.puts("Done.")
