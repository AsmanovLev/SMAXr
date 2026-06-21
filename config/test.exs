import Config

config :konsolidator, :adapters, []
config :smaxr, data_dir: "priv/smaxr_test"

config :smaxr, Smaxr.LLM.Anthropic,
  base_url: "http://127.0.0.1:65535",
  api_key: "test-key",
  default_model: "test-model"
