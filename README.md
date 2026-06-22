# SMAXr

**S**elf-**M**odifying **A**I agent in **Elixir**.

Channel-agnostic backend (Telegram via [konsolidator](https://github.com/AsmanovLev/konsolidator)), hot-reloading modules in the running BEAM via `apply_patch`, eval-based self-modify, multi-step tool use, multi-session persistence, model registry with ETS cache.

This is the Elixir successor to [SMAGo](https://github.com/AsmanovLev/SMAGo).

## Quick install (Windows 10/11)

```powershell
irm https://raw.githubusercontent.com/AsmanovLev/SMAXr/main/scripts/configure.ps1 | iex
```

This one-liner:
- Checks prerequisites (git, Erlang/OTP, Elixir)
- Installs missing via winget or portable download
- Clones the repo, installs deps, configures `.env` via numeric menu
- Optionally registers autostart in Task Scheduler (boot + logon)

For **Windows 7** (Erlang/OTP 24 max): same command, automatically detects Win7 and adjusts.

After install: `cd %LOCALAPPDATA%\smaxr\repo && .\start.bat`

## Setup (manual)

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

- **main branch**: Elixir 1.20+, Erlang/OTP 27+
- **win7-support branch**: Elixir 1.14.5, Erlang/OTP 24 (max versions for Windows 7)
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- An OpenCode Go API key (or any OpenAI-compatible endpoint)

### Environment

All secrets live in `.env` (gitignored). See `.env.example` for the template.

```
TELEGRAM_BOT_TOKEN=...   # from @BotFather
OPENCODE_API_KEY=sk-...  # from opencode.ai
SOCKS_PROXY=socks5h://127.0.0.1:10808   # optional, if Telegram is blocked
SMAXR_MODEL=deepseek-v4-flash   # any model on the gateway
SMAXR_WORKDIR=               # optional, working directory for file tools
```

## Features

- **Telegram bot** via [konsolidator](https://github.com/AsmanovLev/konsolidator) (long-polling, SOCKS5)
- **Multi-session** — DETS-backed persistent sessions per chat, switch/rename/delete via commands
- **Multi-provider LLM** — OpenCode Go, OpenAI, Anthropic — single config switch
- **Tool calling** — terminal, read/write/edit files, web search, vision, eval, MCP, git
- **Self-modification** — `apply_patch` hot-reloads a `.ex` file in the running BEAM
- **`eval` with `defmodule`** — try a function in BEAM first, then `write_file` + `apply_patch` to persist
- **Workdir isolation** — each session has its own working directory; file tools enforce path guard
- **Git integration** — LLM can commit, push, diff, log, status; user commands: `/gitsha`, `/gitlog`, `/gitdiff`, `/status`
- **Async turn** — `/stop` and `/abort` interrupt the LLM loop at the next step boundary
- **Command whitelist** — read-only commands (help, sessions, version, git, etc.) work mid-turn
- **Auto-inject** — messages received while the agent is busy are queued and merged into context on the next turn
- **Model registry** — `Smaxr.Models` GenServer with ETS cache, 10-min TTL
- **LLM retry** — exponential backoff on 429/502/503/504
- **DCP** — model-driven context compression via `compress` tool with `mN` message ids. Architecture from [opencode-dcp](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning). Off by default; enable with `config :smaxr, :dcp_enabled, true`.

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

| Command         | What it does                                    |
|-----------------|-------------------------------------------------|
| `/start`        | Welcome / help                                  |
| `/help`         | Command list                                    |
| `/new`          | Create new session                              |
| `/switch <name>`| Switch to existing session                      |
| `/rename <name>`| Rename current session                          |
| `/delete [name]`| Delete a session                                |
| `/sessions`     | List sessions                                   |
| `/clear`        | Clear current session history                   |
| `/workdir [path]`| Show or set working directory                  |
| `/model [name]` | Show/set model (e.g. `/model kimi`)             |
| `/models [filter\|refresh]` | List available models                   |
| `/provider [name]`| Show/set provider                             |
| `/providers`    | List available providers                        |
| `/system`       | Show system prompt                              |
| `/maxsteps [n]` | Show/set max steps per turn                     |
| `/tools`        | List registered tools                           |
| `/trace`        | Toggle trace mode                               |
| `/version`      | Bot version, git SHA, uptime                    |
| `/dcp`          | Toggle Dynamic Context Pruning                  |
| `/compress`     | Context compression status                      |
| `/gitsha`       | Show current git SHA                            |
| `/gitlog [N]`   | Show last N commits                             |
| `/gitdiff [path]`| Show working-tree diff                         |
| `/status`       | Show working tree status (git)                  |
| `/stop`         | Cancel current LLM turn                         |
| `/abort`        | Alias for `/stop`                               |
| `/queue`        | Show messages waiting in the auto-inject queue   |

## Self-modify workflow

```
1. eval "defmodule X do def f, do: ... end"      # try in BEAM
2. write_file + apply_patch "path/to/file.ex"     # persist to disk
3. bot uses new code on next turn                 # hot-reload already live
```

## Tests

```bash
mix test                # 99 tests
mix run --no-halt       # start the agent
```

## License

MIT.
