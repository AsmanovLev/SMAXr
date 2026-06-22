# SMAXr — status

`SMAXr` is the Elixir rewrite of SMAGo. Self-modifying AI agent, channel-agnostic backend, multi-messenger UI via [konsolidator](../konsolidator).

## Status (v0.1)

- ✅ Mix project, supervisor tree
- ✅ Konsolidator dependency (path: `../konsolidator`)
- ✅ Per-user `Smaxr.Agent` GenServer (async turn in `Task.Supervisor`)
- ✅ Incoming-event router subscribes to Konsolidator
- ✅ Telegram adapter wired through Konsolidator (no direct Telegram dep in SMAXr)
- ✅ Real LLM loop (multi-step tool calls, max 3 tools/turn, OpenAI-compatible API)
- ✅ OpenCode Go provider + OpenAI provider; model registry (`Smaxr.Models`) with ETS cache
- ✅ Self-modification: `apply_patch` hot-reloads a `.ex` file in the running BEAM
- ✅ `eval` with `defmodule` support — try a function in BEAM first, then `write_file` + `apply_patch` to persist
- ✅ `/stop` and `/abort` interrupt the LLM loop at the next step boundary
- ✅ Auto-inject — messages received while the agent is busy are queued and merged into context on the next turn
- ✅ DCP (Dynamic Context Pruning) — model-driven `compress` tool with `mN` message ids + system-prompt education. Architecture taken from [opencode-dcp](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning).
- 🚧 MCP — basic manager exists; not yet integrated with the LLM loop's tool registry
- 🚧 Web frontend (later)

## Test status

```
$ mix test
Result: 88 passed
```

## DCP usage

DCP is **off by default**. To enable model-driven context compression:

```elixir
# config/dev.exs
config :smaxr, :dcp_enabled, true
```

The model gets a `compress` tool that takes:

```json
{
  "topic": "Auth System Exploration",
  "content": [
    {
      "start_id": "m3",
      "end_id": "m12",
      "summary": "Complete technical summary of the range..."
    }
  ]
}
```

Each message is referenced by an `mN` id (injected into the request as `<dcp-message-id>mN</dcp-message-id>`). The model writes the summary itself; the tool splices the range out of `state.messages` and inserts a single system message with the LLM-produced summary.

## Running

```bash
# Set env vars (or fill in .env)
export TELEGRAM_BOT_TOKEN="..."
export OPENCODE_API_KEY="sk-..."
export SOCKS_PROXY="socks5h://127.0.0.1:10808"   # optional
export SMAXR_MODEL="minimax-m3"                    # or deepseek-v4-flash

mix deps.get
mix test
start.bat        # or start.sh on Unix
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
Smaxr.Agent (per user_id, async turn in Task)
    ↓ send
Konsolidator (back to Telegram)
```

LLM turn runs in `Task.Supervisor.start_child` so the agent's main process stays responsive to `/stop` and new messages (which are queued and auto-injected on the next turn).

## File map

```
lib/
├── smaxr.ex                      # facade
└── smaxr/
    ├── application.ex            # supervisor tree
    ├── router.ex                 # subscribes to incoming
    ├── agent.ex                  # per-user GenServer + DCP splice
    ├── commands.ex               # /start /help /model /stop /queue /dcp
    ├── dcp.ex                    # server-side helpers (digest heuristics)
    ├── tools.ex                  # tool registry
    ├── tools/
    │   ├── terminal.ex
    │   ├── read_file.ex
    │   ├── write_file.ex
    │   ├── edit_file.ex
    │   ├── list_dir.ex
    │   ├── delete_file.ex
    │   ├── find_files.ex
    │   ├── file_info.ex
    │   ├── move_file.ex
    │   ├── diff.ex
    │   ├── grep.ex
    │   ├── web_search.ex
    │   ├── vision.ex
    │   ├── send_file.ex
    │   ├── eval.ex
    │   ├── apply_patch.ex        # hot-reload .ex in BEAM
    │   ├── compress.ex           # model-driven DCP
    │   ├── commit.ex
    │   ├── mcp_control.ex
    │   └── mcp_call.ex
    ├── models.ex                 # LLM model registry (ETS cache)
    ├── providers.ex              # LLM provider registry
    ├── func_lib.ex
    ├── inspect_helpers.ex
    └── llm/
        ├── message.ex
        ├── openai.ex
        └── anthropic.ex
```
