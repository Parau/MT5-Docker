# Sync vendor/ from nt_mt5 (run from MT5-Docker repo root).
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$NtMt5 = Join-Path (Split-Path -Parent $Root) "nt_mt5"

if (-not (Test-Path $NtMt5)) {
    Write-Error "nt_mt5 not found at $NtMt5 — adjust path or clone alongside MT5-Docker."
}

$BridgeSrc = Join-Path $NtMt5 "MQL5\refactoring\bridge"
$Mql5Src = Join-Path $NtMt5 "MQL5\refactoring"

New-Item -ItemType Directory -Force -Path "$Root\vendor\bridge","$Root\vendor\mql5\Include\WebSocket","$Root\vendor\mql5\Services" | Out-Null

Copy-Item "$BridgeSrc\mt5_bridge.py","$BridgeSrc\history_args.py" -Destination "$Root\vendor\bridge\" -Force
Copy-Item "$Mql5Src\Include\NT5FeedWire.mqh" -Destination "$Root\vendor\mql5\Include\" -Force
Copy-Item "$Mql5Src\Include\WebSocket\*.mqh" -Destination "$Root\vendor\mql5\Include\WebSocket\" -Force
Copy-Item "$Mql5Src\Services\NT5TickFeedService.mq5","$Mql5Src\Services\NT5TickFeedService.ex5" -Destination "$Root\vendor\mql5\Services\" -Force

Write-Host "vendor/ synced from $NtMt5"
