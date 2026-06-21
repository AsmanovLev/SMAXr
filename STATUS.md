# SMAXr

`SMAXr` is the Elixir rewrite of SMAGo. Self-modifying AI agent, channel-agnostic backend, multi-messenger UI via [konsolidator](../konsolidator).

## Status (v0.1)

- ✅ Mix project, supervisor tree
- ✅ Konsolidator dependency (path: `../konsolidator`)
- ✅ Per-user `Smaxr.Agent` GenServer
- ✅ Incoming-event router subscribes to Konsolidator
- ✅ Telegram adapter wired through Konsolidator (no direct Telegram dep in SMAXr)
- 🚧 Real LLM loop (next)
- 🚧 DCP, MCP, DC (next)
- 🚧 Web frontend (later)

## Test status

```
$ mix test
Result: 7 passed
```

## Running

```bash
# Set env vars for Telegram (and SOCKS proxy if needed)
export TELEGRAM_BOT_TOKEN="..."
export SOCKS_PROXY="socks5h://127.0.0.1:10808"

# In config/dev.exs, enable the adapter:
#   config :konsolidator, :adapters, [Konsolidator.Adapters.Telegram]

mix deps.get
mix compile
mix test
mix run --no-halt
```

## Architecture

```
Telegram user
    ↓
Konsolidator.Adapters.Telegram (long-poll)
    ↓ publish_incoming
Konsolidator.Router (PubSub)
    ↓
Smaxr.Router (subscribed)
    ↓ cast
Smaxr.Agent (per user_id)
    ↓ send
Konsolidator (back to Telegram)
```

## File map

```
lib/
├── smaxr.ex                    # facade
└── smaxr/
    ├── application.ex          # supervisor tree
    ├── router.ex               # subscribes to incoming
    ├── agent.ex                # per-user GenServer
    └── agent/supervisor.ex     # DynamicSupervisor

test/
├── smaxr_test.exs              # smoke test
└── smaxr/agent_test.exs        # agent unit tests
```
