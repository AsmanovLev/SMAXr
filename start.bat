@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

:: SMAXr - start script
:: Loads .env (if present), starts the agent with Telegram adapter
:: via konsolidator.

set "TITLE=SMAXr Agent"
title %TITLE%

:: Find project root (this bat's directory)
set "ROOT=%~dp0"
cd /d "%ROOT%"

:: Load .env into the current process env (skips blank lines and comments)
if exist ".env" (
    echo [%DATE% %TIME%] Loading .env
    for /f "usebackq tokens=1* delims==" %%a in (".env") do (
        set "line=%%a"
        if not "!line:~0,1!"=="#" if not "%%a"=="" set "%%a=%%b"
    )
) else (
    echo [%DATE% %TIME%] WARNING: .env not found — copy .env.example to .env
)

:: Erlang + Elixir must be on PATH
set "PATH=D:\tools\Erlang\bin;D:\tools\Elixir\bin;%PATH%"

:: dev mode for hot-reload (apply_patch)
set "MIX_ENV=dev"

:: Set MIX_ENV to dev (not prod) for hot-reload compatibility
if defined SOCKS_PROXY (
    echo [%DATE% %TIME%] Proxy: %SOCKS_PROXY%
) else (
    echo [%DATE% %TIME%] No SOCKS_PROXY set
)

:: Required env sanity
if not defined TELEGRAM_BOT_TOKEN (
    echo [%DATE% %TIME%] ERROR: TELEGRAM_BOT_TOKEN not set. Add it to .env
    pause
    exit /b 1
)
if not defined OPENCODE_API_KEY (
    echo [%DATE% %TIME%] ERROR: OPENCODE_API_KEY not set. Add it to .env
    pause
    exit /b 1
)

echo [%DATE% %TIME%] Starting SMAXr with model %SMAXR_MODEL%...
echo.

call elixir --sname smaxr_debug -S mix run --no-halt

echo.
echo [%DATE% %TIME%] SMAXr stopped.
pause
