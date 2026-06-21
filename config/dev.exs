import Config

# In dev, enable the Telegram adapter with the real bot token and SOCKS proxy.
config :konsolidator, :adapters, [Konsolidator.Adapters.Telegram]

config :konsolidator, Konsolidator.Adapters.Telegram,
  token: System.get_env("TELEGRAM_BOT_TOKEN", ""),
  long_poll_timeout: 30,
  allowed_updates: ["message", "callback_query"]

config :konsolidator, :proxy, "socks5h://127.0.0.1:10808"

config :smaxr,
  data_dir: "priv/smaxr"

config :smaxr, Smaxr.LLM.OpenAI,
  base_url: "https://opencode.ai/zen/go/v1",
  api_key: System.get_env("OPENCODE_API_KEY", ""),
  default_model: System.get_env("SMAXR_MODEL", "minimax-m3")
