@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

:: SMAXr with iex shell (so we can poke at it)

set "TITLE=SMAXr Shell"
title %TITLE%

set "SMAGO_DIR=%~dp0"
cd /d "%SMAGO_DIR%"

set "PATH=D:\tools\Erlang\bin;D:\tools\Elixir\bin;%PATH%"
set "PROXY=socks5h://127.0.0.1:10808"
set "MIX_ENV=dev"
set "ERL_AFLAGS=-kernel shell_history enabled"

echo [%DATE% %TIME%] Starting SMAXr with iex shell...
echo [%DATE% %TIME%] Proxy: %PROXY%
echo.

call iex --sname smaxr_debug -S mix
