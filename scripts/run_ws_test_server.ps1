# Start NT5 WS feed test server on the Docker host.
# Tickmill: default port 8765. XP: $env:WS_PORT=8766
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$NtMt5 = if ($env:NT_MT5_ROOT) { $env:NT_MT5_ROOT } else { Join-Path (Split-Path $Root -Parent) "nt_mt5" }
$Script = Join-Path $NtMt5 "MQL5\refactoring\tools\ws_feed_test_server.py"
$Port = if ($env:WS_PORT) { $env:WS_PORT } else { "8765" }

if (-not (Test-Path $Script)) {
    Write-Error "Não encontrado: $Script. Defina NT_MT5_ROOT ou clone nt_mt5."
}

$Python = if ($env:PYTHON) { $env:PYTHON } else { "python" }
& $Python $Script --host 0.0.0.0 --port $Port -v @args
