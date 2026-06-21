# Smoke: SMAXr with real LLM + Telegram
#
# Injects a message via Router, agent calls LLM, reply goes to Telegram.
# Run with: mix run scripts/smoke_llm.exs

alias Smaxr.LLM.Message

# 1. Quick LLM test via curl (no dependency on app startup)
IO.puts("=== LLM ping ===")
api_key = "sk-PmxhYS11pNQJNTasj83ysHVrNF5pMM9a5FTSmLtHyC7RuQcI3HW3fD5nnAF3rDva"
proxy = "socks5h://127.0.0.1:10808"
url = "https://opencode.ai/zen/go/v1/chat/completions"

{body, 0} = System.cmd("curl", [
  "--proxy", proxy, "-s", "-m", "30",
  "-H", "Authorization: Bearer #{api_key}",
  "-H", "Content-Type: application/json",
  "-d", ~S({"model":"kimi-k2.6","messages":[{"role":"user","content":"say hi"}],"max_tokens":10}),
  url
], stderr_to_stdout: true)

{:ok, resp} = Jason.decode(body)
reply = get_in(resp, ["choices", Access.at(0), "message", "content"])
IO.puts("LLM says: #{reply}")

# 2. Start SMAXr with dev config (real LLM + Telegram)
IO.puts("\n=== Starting SMAXr ===")
{:ok, _} = Application.ensure_all_started(:smaxr)
Process.sleep(500)
IO.puts("Supervisor started.")

# 3. Inject an incoming message as if from Telegram
IO.puts("\n=== Injecting message via Konsolidator.Router ===")
test_user_id = 10_551_980_77

Konsolidator.Router.publish_incoming(%{
  source: :telegram,
  user_id: test_user_id,
  text: "hi, what model are you?",
  ref: 999_999,
  raw: nil
})

# 4. Wait for LLM to respond
IO.puts("Waiting for LLM response...")
Process.sleep(15_000)

# 5. Check agent state
agent_pid = Smaxr.Agent.whereis(test_user_id)
if agent_pid do
  state = :sys.get_state(agent_pid)
  IO.puts("\n=== Agent state ===")
  IO.puts("message_count: #{state.message_count}")
  IO.puts("messages in history: #{length(state.messages)}")
  last = List.last(state.messages)
  if last, do: IO.puts("last message role: #{last.role}, len=#{byte_size(last.content || "")}")
  IO.puts("last_ref (Telegram msg_id): #{inspect(state.last_ref)}")
  IO.puts("model: #{state.model}")
else
  IO.puts("WARN: Agent not started")
end

IO.puts("\nDone. Check Telegram for the bot's reply.")
