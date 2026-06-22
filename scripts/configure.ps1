# SMAXr Windows installer & configurator
# Usage: irm https://raw.githubusercontent.com/AsmanovLev/SMAXr/main/scripts/configure.ps1 | iex
#
# Does NOT require admin. Installs to $env:LOCALAPPDATA\smaxr.
# Reversible: schtasks /Delete /TN SMAXr-Agent /F + rm -r $env:LOCALAPPDATA\smaxr

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoUrl  = 'https://github.com/AsmanovLev/SMAXr.git'
$RepoDir  = Join-Path $env:LOCALAPPDATA 'smaxr\repo'
$Runtime  = Join-Path $env:LOCALAPPDATA 'smaxr\runtime'
$TaskName = 'SMAXr-Agent'

# Portable Elixir URL (stable, GitHub releases)
$ElixirPortableUrl = 'https://github.com/elixir-lang/elixir/releases/download/v1.16.2/elixir-otp-26.zip'
$ElixirVersion     = '1.16.2 (requires Erlang/OTP 26+)'

function Test-Cmd([string]$name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Read-Choice([string]$prompt, [string[]]$valid) {
  while ($true) {
    $x = (Read-Host $prompt).Trim()
    if ($valid -contains $x) { return $x }
    Write-Host "Invalid. Choose: $($valid -join ' / ')" -ForegroundColor Yellow
  }
}

# Update or append KEY=VALUE in .env
function Set-EnvValue([string]$file, [string]$key, [string]$value) {
  $content = ''
  if (Test-Path $file) { $content = Get-Content $file -Raw -ErrorAction SilentlyContinue }
  $line = "$key=$value"
  if ($content -and ($content -match "(?m)^$key=")) {
    $content = [regex]::Replace($content, "(?m)^$key=.*$", $line)
  } elseif ($content) {
    $content = $content.TrimEnd() + "`r`n" + $line + "`r`n"
  } else {
    $content = $line + "`r`n"
  }
  Set-Content -Path $file -Value $content -NoNewline -Encoding UTF8
}

# ─── Phase 1: pre-flight ────────────────────────────────────────────
Clear-Host
Write-Host "=== SMAXr pre-flight ===" -ForegroundColor Cyan
$hasWinget = Test-Cmd 'winget'
$hasGit    = Test-Cmd 'git'
$hasErl    = Test-Cmd 'erl'
$hasElixir = Test-Cmd 'elixir'

function Ind([bool]$ok) { if ($ok) {'OK         '} else {'MISSING    '} }
Write-Host ("winget       " + (Ind $hasWinget) + $(if ($hasWinget) {'available'} else {'not found'}))
Write-Host ("git          " + (Ind $hasGit)    + $(if ($hasGit)    {'installed'} else {'install: https://git-scm.com/download/win'}))
Write-Host ("Erlang/OTP   " + (Ind $hasErl)    + $(if ($hasErl)    {'installed'} else {'install: https://www.erlang.org/downloads'}))
Write-Host ("Elixir       " + (Ind $hasElixir) + $(if ($hasElixir) {'installed'} else {"portable: $ElixirPortableUrl"}))

# ─── Phase 2: install strategy (only if something missing) ──────────
$needsInstall = -not ($hasGit -and $hasErl -and $hasElixir)
if ($needsInstall) {
  Write-Host ""
  Write-Host "How to install missing prerequisites?" -ForegroundColor Cyan
  Write-Host "  1. winget install" -ForegroundColor $(if ($hasWinget) {'White'} else {'DarkGray'})
  if (-not $hasWinget) { Write-Host "     (winget not available — option disabled)" -ForegroundColor DarkGray }
  Write-Host "  2. portable download (Elixir only, no admin)"
  Write-Host "  3. skip (install manually, exit)"
  $valid = @('1','2','3')
  if (-not $hasWinget) { $valid = @('2','3') }
  $strategy = Read-Choice 'Strategy (1/2/3)' $valid

  switch ($strategy) {
    '1' {
      # winget install
      $pkgs = @()
      if (-not $hasGit)    { $pkgs += 'Git.Git' }
      if (-not $hasErl)    { $pkgs += 'Erlang.Erlang' }
      if (-not $hasElixir) { $pkgs += 'Elixir.Elixir' }
      foreach ($p in $pkgs) {
        Write-Host "  winget install $p ..." -ForegroundColor Cyan
        winget install --id $p --accept-source-agreements --accept-package-agreements | Out-Null
      }
      Write-Host ""
      Write-Host "Installed. Reopen PowerShell for PATH, then re-run this script." -ForegroundColor Yellow
      Write-Host "  irm $PSCommandPath | iex" -ForegroundColor Yellow
      exit 0
    }
    '2' {
      # Elixir portable
      if (-not (Test-Path $Runtime)) { New-Item -ItemType Directory -Force -Path $Runtime | Out-Null }
      $zip = Join-Path $Runtime 'elixir.zip'
      Write-Host "  Downloading Elixir $ElixirVersion ..." -ForegroundColor Cyan
      try {
        Invoke-WebRequest -Uri $ElixirPortableUrl -OutFile $zip -UseBasicParsing
      } catch {
        Write-Host "  Download failed: $_" -ForegroundColor Red
        exit 1
      }
      Expand-Archive $zip -DestinationPath $Runtime -Force
      Remove-Item (Join-Path $Runtime 'elixir-otp-26') -Recurse -Force -ErrorAction SilentlyContinue
      Move-Item (Join-Path $Runtime 'elixir-otp-26') (Join-Path $Runtime 'elixir') -Force
      Remove-Item $zip
      $env:PATH = "$(Join-Path $Runtime 'elixir\bin');$env:PATH"
      Write-Host "  Elixir installed: $Runtime\elixir\bin" -ForegroundColor Green
      Write-Host ""
      Write-Host "  Erlang portable: NOT available (no stable Erlang/OTP Windows zip)" -ForegroundColor Yellow
      Write-Host "  Install Erlang manually:" -ForegroundColor Yellow
      Write-Host "    - Microsoft Store: search 'Erlang OTP'" -ForegroundColor Yellow
      Write-Host "    - Browser:         https://www.erlang.org/downloads" -ForegroundColor Yellow
      Write-Host "  After Erlang is installed, re-run this script." -ForegroundColor Yellow
      exit 0
    }
    '3' {
      Write-Host "Install manually, then re-run this script." -ForegroundColor Yellow
      exit 0
    }
  }
}

# ─── Phase 3: clone + deps ──────────────────────────────────────────
Write-Host ""
Write-Host "=== Clone + deps ===" -ForegroundColor Cyan
if (-not (Test-Path $RepoDir)) {
  if (-not (Test-Path (Split-Path $RepoDir -Parent))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $RepoDir -Parent) | Out-Null
  }
  Write-Host "  git clone $RepoUrl $RepoDir" -ForegroundColor Cyan
  git clone $RepoUrl $RepoDir | Out-Null
  Write-Host "  cloned" -ForegroundColor Green
} else {
  Write-Host "  already cloned at $RepoDir" -ForegroundColor Green
}

Push-Location $RepoDir
try {
  Write-Host "  mix deps.get ..." -ForegroundColor Cyan
  mix deps.get | Out-Null
  Write-Host "  deps installed" -ForegroundColor Green
} catch {
  Write-Host "  mix deps.get FAILED: $_" -ForegroundColor Red
  Pop-Location
  exit 1
}
Pop-Location

# ─── Phase 4: configurator (.env) ──────────────────────────────────
$EnvFile = Join-Path $RepoDir '.env'
$EnvExample = Join-Path $RepoDir '.env.example'
if (-not (Test-Path $EnvFile) -and (Test-Path $EnvExample)) {
  Copy-Item $EnvExample $EnvFile
}

Write-Host ""
Write-Host "=== Configuration ===" -ForegroundColor Cyan
$existing = @{}
if (Test-Path $EnvFile) {
  Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.*)$') { $existing[$Matches[1]] = $Matches[2] }
  }
}
if ($existing.Count -gt 0) {
  $reconf = Read-Host "Existing .env found with $($existing.Count) keys. Reconfigure? [y/N]"
  if ($reconf -notmatch '^[Yy]') {
    Write-Host "  keeping existing .env" -ForegroundColor Green
  } else {
    $existing = @{}
  }
}

if ($existing.Count -eq 0) {
  $tg = Read-Host "  1) Telegram bot token (from @BotFather, Enter to skip)"
  if ($tg) { Set-EnvValue $EnvFile 'TELEGRAM_BOT_TOKEN' $tg }
  $prov = Read-Host "  2) LLM provider (openai/anthropic, Enter = openai)"
  if (-not $prov) { $prov = 'openai' }
  Set-EnvValue $EnvFile 'SMAXR_LLM_PROVIDER' $prov
  $model = Read-Host "  3) LLM model (Enter = deepseek-v4-flash)"
  if (-not $model) { $model = 'deepseek-v4-flash' }
  Set-EnvValue $EnvFile 'SMAXR_MODEL' $model
  $proxy = Read-Host "  4) SOCKS proxy (Enter = none)"
  if ($proxy) { Set-EnvValue $EnvFile 'SOCKS_PROXY' $proxy }
  $wd = Read-Host "  5) Workdir for file tools (Enter = $RepoDir)"
  if (-not $wd) { $wd = $RepoDir }
  Set-EnvValue $EnvFile 'SMAXR_WORKDIR' $wd

  if ($prov -eq 'openai') {
    $key = Read-Host "  6) OPENCODE_API_KEY (Enter to skip)"
    if ($key) { Set-EnvValue $EnvFile 'OPENCODE_API_KEY' $key }
  } elseif ($prov -eq 'anthropic') {
    $key = Read-Host "  6) ANTHROPIC_API_KEY (Enter to skip)"
    if ($key) { Set-EnvValue $EnvFile 'ANTHROPIC_API_KEY' $key }
  }
  Write-Host "  .env saved" -ForegroundColor Green
}

# ─── Phase 5: Task Scheduler (opt-in) ──────────────────────────────
Write-Host ""
$auto = Read-Host "Register SMAXr in Task Scheduler (boot + logon autostart)? [y/N]"
if ($auto -match '^[Yy]') {
  $startBat = Join-Path $RepoDir 'start.bat'
  $startBat = $startBat -replace '\\', '\\'
  $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>SMAXr self-modifying agent</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
  </Settings>
  <Actions>
    <Exec>
      <Command>$startBat</Command>
    </Exec>
  </Actions>
</Task>
"@
  $xmlPath = Join-Path $env:TEMP 'smaxr_task.xml'
  $xml | Out-File $xmlPath -Encoding Unicode
  schtasks /Create /TN $TaskName /XML $xmlPath /F | Out-Null
  Remove-Item $xmlPath
  Write-Host "  Registered: $TaskName" -ForegroundColor Green
} else {
  Write-Host "  Autostart: not registered" -ForegroundColor DarkGray
}

# ─── Phase 6: итог ──────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "  Install path:    $RepoDir"
Write-Host "  Config:          $EnvFile"
Write-Host ""
Write-Host "To start now:"
Write-Host "  cd `"$RepoDir`"" -ForegroundColor White
Write-Host "  .\start.bat" -ForegroundColor White
Write-Host ""
Write-Host "To remove autostart:"
Write-Host "  schtasks /Delete /TN $TaskName /F" -ForegroundColor DarkGray
Write-Host ""
Write-Host "To uninstall:"
Write-Host "  schtasks /Delete /TN $TaskName /F" -ForegroundColor DarkGray
Write-Host "  Remove-Item -Recurse `$env:LOCALAPPDATA\smaxr" -ForegroundColor DarkGray
