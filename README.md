# SMAXr

**S**elf-**M**odifying **A**I agent in **Elixir**.

Channel-agnostic backend (Telegram via [konsolidator](https://github.com/AsmanovLev/konsolidator)), hot-reloading modules in the running BEAM via `apply_patch`, eval-based self-modify, multi-step tool use, model registry with ETS cache.

This is the Elixir successor to [SMAGo](https://github.com/AsmanovLev/SMAGo).

## Features

- **Telegram bot** via [konsolidator](https://github.com/AsmanovLev/konsolidator) (long-polling, SOCKS5)
- **Multi-provider LLM** — OpenCode Go, OpenAI, Anthropic — single config switch
- **Tool calling** — terminal, read/write/edit files, web search, vision, eval, MCP
- **Self-modification** — `apply_patch` hot-reloads a `.ex` file in the running BEAM
- **`eval` with `defmodule`** — try a function in BEAM first, then `write_file` + `apply_patch` to persist
- **Async turn** — `/stop` and `/abort` interrupt the LLM loop at the next step boundary
- **Auto-inject** — messages received while the agent is busy are queued and merged into context on the next turn
- **Model registry** — `Smaxr.Models` GenServer with ETS cache, 10-min TTL
- **DCP** — Dynamic Context Pruning (off by default)

## Setup

```bash
git clone https://github.com/AsmanovLev/SMAXr.git
cd SMAXr
cp .env.example .env
# edit .env, fill in TELEGRAM_BOT_TOKEN and OPENCODE_API_KEY
mix deps.get
mix test
start.bat        # or start.sh on Unix
```

### Requirements

- Elixir 1.20+
- Erlang/OTP 27 or 29
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- An OpenCode Go API key (or any OpenAI-compatible endpoint)

### Environment

All secrets live in `.env` (gitignored). See `.env.example` for the template.

```
TELEGRAM_BOT_TOKEN=...   # from @BotFather
OPENCODE_API_KEY=sk-...  # from opencode.ai
SOCKS_PROXY=socks5h://127.0.0.1:10808   # optional, if Telegram is blocked
SMAXR_MODEL=minimax-m3   # any model on the gateway
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
Smaxr.Agent (per user_id, async Task)
    ↓ send
Konsolidator (back to Telegram)
```

LLM turn runs in `Task.Supervisor.start_child` so the agent's main process stays responsive to `/stop` and new messages.

## Commands

| Command   | What it does                                    |
|-----------|-------------------------------------------------|
| `/start`  | Welcome / help                                  |
| `/help`   | Command list                                    |
| `/new`    | Clear session messages                          |
| `/models` | List available models                           |
| `/model`  | Show / set current model                        |
| `/tools`  | List registered tools                           |
| `/version`| Bot version, uptime, BEAM stats                 |
| `/health` | Process tree health                             |
| `/stop`   | Cancel current LLM turn at next step boundary   |
| `/abort`  | Alias for `/stop`                                |
| `/queue`  | Show messages waiting in the auto-inject queue   |
| `/dcp`    | Toggle Dynamic Context Pruning                  |
| `/maxsteps N` | Set max steps per turn                     |

## Self-modify workflow

```
1. eval "defmodule X do def f, do: ... end"      # try in BEAM
2. write_file + apply_patch "path/to/file.ex"     # persist to disk
3. bot uses new code on next turn                 # hot-reload already live
```

## Tests

```bash
mix test                # 80+ tests
mix run --no-halt       # start the agent
```

## License

MIT.
