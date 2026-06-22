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
  default_model: "deepseek-v4-flash",
  data_dir: "priv/smaxr",
  mcp_servers: []

# --- LLM Providers ---
# Each provider has a unique id, a human-readable label, and the module
# that implements the `Smaxr.LLM` behaviour (call/3).
config :smaxr, Smaxr.Providers,
  providers: [
    %{
      id: "openai",
      label: "OpenAI / OpenCode",
      module: Smaxr.LLM.OpenAI
    },
    %{
      id: "anthropic",
      label: "Anthropic / OpenModel",
      module: Smaxr.LLM.Anthropic
    }
  ]

# Import last so env overrides take precedence.
import_config "#{config_env()}.exs"
