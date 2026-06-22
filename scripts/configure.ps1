# SMAXr Windows installer & configurator
# Usage: irm https://raw.githubusercontent.com/AsmanovLev/SMAXr/main/scripts/configure.ps1 | iex
#
# Supports Windows 7+ (PowerShell 2.0+).
# Does NOT require admin. Installs to $env:LOCALAPPDATA\smaxr.
# Reversible: schtasks /Delete /TN SMAXr-Agent /F + rm -r $env:LOCALAPPDATA\smaxr

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Detect OS + PowerShell version
$PSVer = $PSVersionTable.PSVersion
$isWin7 = ($PSVer.Major -le 2)

if ($isWin7) {
  Write-Host "*** Windows 7 detected. PowerShell 2.0 limited. Install WMF 5.1 if possible." -ForegroundColor Yellow
  Write-Host "    https://www.microsoft.com/en-us/download/details.aspx?id=54616" -ForegroundColor Yellow
  Write-Host ""

  # On Win7 Erlang/OTP 24.3.4.14 (max), Elixir 1.14.5 (max)
  $ElixirPortableUrl = 'https://github.com/elixir-lang/elixir/releases/download/v1.14.5/elixir-otp-24.zip'
  $ElixirVersion     = '1.14.5 (requires Erlang/OTP 24)'
  $ElixirExtractDir  = 'elixir-otp-24'
} else {
  $ElixirPortableUrl = 'https://github.com/elixir-lang/elixir/releases/download/v1.16.2/elixir-otp-26.zip'
  $ElixirVersion     = '1.16.2 (requires Erlang/OTP 26+)'
  $ElixirExtractDir  = 'elixir-otp-26'
}

$RepoUrl  = 'https://github.com/AsmanovLev/SMAXr.git'
$RepoDir  = Join-Path $env:LOCALAPPDATA 'smaxr\repo'
$Runtime  = Join-Path $env:LOCALAPPDATA 'smaxr\runtime'
$TaskName = 'SMAXr-Agent'

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

# Update or append KEY=VALUE in .env (PS2-compatible, no -Raw)
function Set-EnvValue([string]$file, [string]$key, [string]$value) {
  $content = ''
  if (Test-Path $file) {
    $content = [System.IO.File]::ReadAllText($file)
  }
  $line = "$key=$value"
  if ($content -and ($content -match "(?m)^$key=")) {
    $content = [regex]::Replace($content, "(?m)^$key=.*$", $line)
  } elseif ($content) {
    $content = $content.TrimEnd() + "`r`n" + $line + "`r`n"
  } else {
    $content = $line + "`r`n"
  }
  [System.IO.File]::WriteAllText($file, $content)
}

# ─── Phase 1: pre-flight ────────────────────────────────────────────
Clear-Host
Write-Host "=== SMAXr pre-flight ===" -ForegroundColor Cyan
$hasWinget   = Test-Cmd 'winget'
$hasChoco    = (-not $isWin7)  # choco only relevant on modern Windows
if ($isWin7) { $hasWinget = $false; $hasChoco = Test-Cmd 'choco' }
$hasGit    = Test-Cmd 'git'
$hasErl    = Test-Cmd 'erl'
$hasElixir = Test-Cmd 'elixir'

function Ind([bool]$ok) { if ($ok) {'OK         '} else {'MISSING    '} }
Write-Host ("PowerShell  " + (Ind $true) + "$($PSVer.Major).$($PSVer.Minor)")
Write-Host ("winet       " + (Ind $hasWinget) + $(if ($hasWinget) {'available'} else {'not found (Win7, use chocolatey/manual)'}))
if ($isWin7) {
  Write-Host ("chocolatey  " + (Ind $hasChoco) + $(if ($hasChoco) {'available'} else {"install: https://chocolatey.org/install"}))
}
Write-Host ("git          " + (Ind $hasGit)    + $(if ($hasGit)    {'installed'} else {'install: https://git-scm.com/download/win'}))
Write-Host ("Erlang/OTP   " + (Ind $hasErl)    + $(if ($hasErl)    {'installed'} else {"install: $(if ($isWin7) {'OTP 24 (max) from https://www.erlang.org/downloads'} else {'https://www.erlang.org/downloads'})"}))
Write-Host ("Elixir       " + (Ind $hasElixir) + $(if ($hasElixir) {'installed'} else {"portable: $ElixirVersion"}))

# ─── Phase 2: install strategy (only if something missing) ──────────
$needsInstall = -not ($hasGit -and $hasErl -and $hasElixir)
if ($needsInstall) {
  Write-Host ""
  Write-Host "How to install missing prerequisites?" -ForegroundColor Cyan
  $valid = @()
  if ($hasWinget) {
    Write-Host "  1. winget install (recommended)"
    $valid += '1'
  } elseif ($isWin7) {
    Write-Host "  1. (winget unavailable on Win7)" -ForegroundColor DarkGray
  }
  Write-Host "  2. portable download (Elixir only, no admin)"
  $valid += '2'
  if ($isWin7) {
    Write-Host "  3. chocolatey (if installed)"
    if ($hasChoco) { $valid += '3' }
  } else {
    Write-Host "  3. skip (install manually, exit)"
    $valid += '3'
  }
  $strategy = Read-Choice "Strategy ($($valid -join '/'))" $valid

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
      Write-Host "  irm https://raw.githubusercontent.com/AsmanovLev/SMAXr/win7-support/scripts/configure.ps1 | iex" -ForegroundColor Yellow
      exit 0
    }
    '2' {
      # Elixir portable (PS2-compatible download)
      if (-not (Test-Path $Runtime)) { New-Item -ItemType Directory -Force -Path $Runtime | Out-Null }
      $zip = Join-Path $Runtime 'elixir.zip'
      Write-Host "  Downloading Elixir $ElixirVersion ..." -ForegroundColor Cyan
      try {
        $wc = New-Object System.Net.WebClient
        Write-Output "  (this may take a moment, ~10-15 MB)"
        $wc.DownloadFile($ElixirPortableUrl, $zip)
        Write-Output ""
      } catch {
        Write-Host "  Download failed: $_" -ForegroundColor Red
        exit 1
      }
      # Extract (PS2-compatible via Shell.Application or ZipFile)
      try {
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $Runtime)
      } catch {
        # Fallback: Shell.Application COM (PS2)
        $shell = New-Object -ComObject Shell.Application
        $zipObj = $shell.NameSpace($zip)
        $dest = $shell.NameSpace($Runtime)
        $dest.CopyHere($zipObj.Items(), 16)
      }
      # Rename extracted dir
      $extracted = Join-Path $Runtime $ElixirExtractDir
      $elixirDir = Join-Path $Runtime 'elixir'
      if (Test-Path $extracted) {
        Remove-Item $elixirDir -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item $extracted $elixirDir -Force
      }
      Remove-Item $zip
      $env:PATH = "$(Join-Path $elixirDir 'bin');$env:PATH"
      Write-Host "  Elixir installed: $elixirDir\bin" -ForegroundColor Green
      Write-Host ""

      if ($isWin7) {
        Write-Host "  Note: Erlang/OTP 24.3.4.14 is the last Win7-compatible version." -ForegroundColor Yellow
        Write-Host "  Install Erlang:" -ForegroundColor Yellow
        Write-Host "    - Browser: https://www.erlang.org/downloads (choose OTP 24.x)" -ForegroundColor Yellow
        Write-Host "    - Chocolatey: choco install erlang --version 24.3.4.14" -ForegroundColor Yellow
      } else {
        Write-Host "  Install Erlang:" -ForegroundColor Yellow
        Write-Host "    - winget: winget install Erlang.Erlang" -ForegroundColor Yellow
        Write-Host "    - Browser: https://www.erlang.org/downloads" -ForegroundColor Yellow
        Write-Host "    - Microsoft Store: 'Erlang OTP'" -ForegroundColor Yellow
      }
      Write-Host "  After Erlang is installed, re-run this script." -ForegroundColor Yellow
      exit 0
    }
    '3' {
      if ($isWin7 -and $hasChoco) {
        # chocolatey install
        Write-Host "  Installing via chocolatey..." -ForegroundColor Cyan
        if (-not $hasGit)    { choco install git -y }
        if (-not $hasErl)    { choco install erlang --version 24.3.4.14 -y }
        if (-not $hasElixir) { choco install elixir -y }
        Write-Host "  Installed. Reopen PowerShell, re-run this script." -ForegroundColor Yellow
      } else {
        Write-Host "Install manually, then re-run this script." -ForegroundColor Yellow
      }
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
  $content = [System.IO.File]::ReadAllText($EnvFile)
  foreach ($_ in ($content -split "`n")) {
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
  $x = schtasks /Create /TN $TaskName /XML $xmlPath /F 2>&1
  Remove-Item $xmlPath
  if ($LASTEXITCODE -eq 0) {
    Write-Host "  Registered: $TaskName" -ForegroundColor Green
  } elseif ($LASTEXITCODE -eq 1) {
    Write-Host "  Task Scheduler registration failed (run as admin?): $x" -ForegroundColor Yellow
    Write-Host "  Add manually: $startBat → Windows Startup folder" -ForegroundColor Yellow
  } else {
    Write-Host "  Registered (exit code: $LASTEXITCODE)" -ForegroundColor Green
  }
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
