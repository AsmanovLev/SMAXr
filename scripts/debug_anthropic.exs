IO.puts("=== Debug Anthropic multi-turn ===")

alias Smaxr.LLM.Message
alias Smaxr.LLM.Anthropic

model = "deepseek-v4-flash"

# Turn 1
sys = Message.system("You are SMAXr, a helpful Elixir agent.")
user1 = Message.user("say hi")
IO.puts("Turn 1...")
case Anthropic.call(model, [sys, user1]) do
  {:ok, resp1, usage1} ->
    IO.puts("Turn 1 OK: #{String.slice(resp1.content, 0, 100)}")
    IO.puts("tokens: #{usage1["input_tokens"]} in / #{usage1["output_tokens"]} out")

    # Turn 2 - include the assistant response
    user2 = Message.user("say bye")
    IO.puts("Turn 2...")
    case Anthropic.call(model, [sys, user1, resp1, user2]) do
      {:ok, resp2, usage2} ->
        IO.puts("Turn 2 OK: #{String.slice(resp2.content, 0, 100)}")
        IO.puts("tokens: #{usage2["input_tokens"]} in / #{usage2["output_tokens"]} out")

      {:error, reason} ->
        IO.puts("Turn 2 FAILED: #{inspect(reason)}")
        # Debug: show the messages
        IO.puts("--- Messages sent to API ---")
        for m <- [sys, user1, resp1, user2] do
          IO.inspect(m, label: "#{m.role}")
        end
    end

  {:error, reason} ->
    IO.puts("Turn 1 FAILED: #{inspect(reason)}")
end

IO.puts("=== Done ===")
