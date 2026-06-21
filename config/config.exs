import Config

# SOCKS proxy is required on networks where Telegram API is blocked.
config :smaxr, :proxy, System.get_env("SOCKS_PROXY", "socks5h://127.0.0.1:10808")

# Telegram adapter is enabled per environment — see dev.exs, test.exs.
config :konsolidator, :adapters, []

config :konsolidator, Konsolidator.Adapters.Telegram,
  token: System.get_env("TELEGRAM_BOT_TOKEN", ""),
  long_poll_timeout: 30,
  allowed_updates: ["message", "callback_query"]

config :konsolidator, :proxy, "socks5h://127.0.0.1:10808"

config :smaxr,
  llm_provider: "openai",
  default_model: "minimax-m3",
  data_dir: "priv/smaxr",
  mcp_servers: []

# Import last so env overrides take precedence.
import_config "#{config_env()}.exs"
