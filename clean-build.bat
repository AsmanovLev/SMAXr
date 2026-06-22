@echo off
chcp 65001 >nul
echo === SMAXr build cleanup ===
echo Cleaning Hex cache...
rmdir /s /q "%USERPROFILE%\.mix\archives" 2>nul
rmdir /s /q "%USERPROFILE%\.mix\hex" 2>nul

echo Reinstalling Hex...
call mix local.hex --force

echo Cleaning all deps...
call mix deps.clean --all

echo Fetching fresh deps...
call mix deps.get

echo Compiling...
call mix compile

echo.
echo === Done. Run start.bat to launch ===
pause
