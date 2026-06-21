# Direct LLM test from within the Mix project
# Run with: mix run scripts/debug_llm.exs

IO.puts("=== LLM config ===")
config = Application.get_env(:smaxr, Smaxr.LLM.OpenAI, [])
IO.inspect(config)

IO.puts("\n=== Direct curl test ===")
model = Keyword.get(config, :default_model, "unknown")
url = Keyword.get(config, :base_url, "no-url") <> "/chat/completions"
body = Jason.encode!(%{model: model, messages: [%{role: "user", content: "hi"}], stream: false})

IO.puts("URL: #{url}")
IO.puts("Model: #{model}")
args = ["-s", "-m", "15", "-d", body, "-H", "Content-Type: application/json", url]

case System.cmd("curl", args, stderr_to_stdout: true) do
  {out, 0} -> IO.puts("CURL OK: #{String.slice(out, 0, 200)}")
  {out, code} -> IO.puts("CURL FAIL #{code}: #{String.slice(out, 0, 200)}")
end

IO.puts("\n=== Via OpenAI.call ===")
case Smaxr.LLM.OpenAI.call(model, [%{role: :user, content: "hi"}]) do
  {:ok, %{content: content}} -> IO.puts("LLM OK: #{String.slice(content || "", 0, 100)}")
  {:error, reason} -> IO.puts("LLM FAIL: #{inspect(reason)}")
end
