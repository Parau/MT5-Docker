# XP container (profile `xp`)

Second MetaTrader 5 instance for **XP / B3**, isolated from Tickmill (separate
volume, ports, and broker login). Same image and automation as `mt5-tickmill`.

## Port map

| Instance | Profile | VNC | RPyC | WS test server (host) |
|----------|---------|-----|------|------------------------|
| Tickmill | `tickmill` | `127.0.0.1:5901` | `18812` | `8765` |
| XP | `xp` | `127.0.0.1:5902` | `18813` | `8766` |

Both containers can run **at the same time**.

## First install (XP volume)

```bash
RESET_WINEPREFIX=1 INSTALL_MT5=1 RUN_MT5=0 MT5_INSTALL_MODE=manual \
  docker compose --profile xp up mt5-xp
```

Via VNC (`127.0.0.1:5902`, password from your local `.env`):

1. Complete MT5 installer (if fresh volume).
2. Log in to **XPMT5-DEMO** (or your XP server) — **not** Tickmill.
3. **Tools → Options → Expert Advisors** — whitelist (keyboard if UI is slow):

   ```
   host.docker.internal
   http://host.docker.internal:8766
   ```

4. Stop the foreground container (`Ctrl+C`) and start normally:

   ```bash
   docker compose --profile xp up -d mt5-xp
   ```

## Normal use

```bash
docker compose --profile xp up -d mt5-xp
docker compose --profile xp logs -f mt5-xp
```

WS test server on host (port **8766**):

```powershell
$env:WS_PORT=8766; .\scripts\run_ws_test_server.ps1
```

```bash
WS_PORT=8766 ./scripts/run_ws_test_server.sh
```

Start **NT5TickFeedService** in VNC (Navigator → Services → Start).

Expected service URL (auto-configured):

```
ws://host.docker.internal:8766/mt5-feed
```

Default symbol: `WDOQ26` (override via `NT5_WS_SYMBOLS_XP` in `.env`). `WDON26` (série N) expired — use current WDO nominal.

## Verify RPyC

```bash
python -c "import rpyc; c=rpyc.connect('127.0.0.1',18813); i=c.root.account_info(); print(i.login, i.server)"
```

Must show XP account/server — **not** Tickmill.

## Homologation (nt_mt5)

```cmd
cd /d E:\dev\nt_mt5
set MT5_HOST=127.0.0.1
set MT5_PORT=18813
set MT5_VENUE_PROFILE=xp_b3
set MT5_ACCOUNT_NUMBER=<your-xp-login>
set MT5_SYMBOL=WDOQ26
set MT5_BROKER=XPMT5-DEMO
set HOMOLOG_REPORT_JSON=homologation/last_xp_closed_market_report.json
E:\miniconda\envs\trading\python.exe homologation\run_xp_closed_market.py
```

**Validated (2026-06-28):** 17/17 PASS on `XPMT5-DEMO` / `56822578` with bridge
`18813` and closed-market suite (`homologation/last_xp_closed_market_report.json`).

## Troubleshooting

### `bootstrap_python` appears stuck (15+ minutes)

On first boot the script can hang at `wineserver -w` after the Windows Python
installer while MT5 + Edge WebView are busy. Symptoms:

- Logs stop at `BOOTSTRAP_PYTHON: instalando Python 3.11.9...`
- `wine python --version` works, but `import MetaTrader5` fails
- RPyC bridge never starts (entrypoint runs bridge only after bootstrap)

**Check:**

```bash
docker exec mt5_xp_container wine python -c "import MetaTrader5, rpyc, numpy; print('OK')"
docker compose --profile xp logs mt5-xp --tail 20
```

**Fix (manual pip + bridge):**

```bash
docker exec mt5_xp_container bash -c \
  "wine python -m pip install 'numpy<2' MetaTrader5 rpyc"

docker exec -d mt5_xp_container bash -c \
  "export WINEPREFIX=/config/.wine RPYC_PORT=18813; \
   /scripts/start_bridge.sh >> /tmp/start_bridge.log 2>&1"

docker exec mt5_xp_container tail -5 /tmp/start_bridge.log
```

RPyC must listen on **18813** inside the container (see bridge port note below).

### WS connects to wrong port (8765 instead of 8766)

MT5 may overwrite `Config/services.ini` when the service starts (URL reverts to
`8765`, `InpSymbols` may clear). Re-apply and restart the service:

```bash
docker exec -e NT5_WS_URL=ws://host.docker.internal:8766/mt5-feed \
  -e NT5_WS_SYMBOLS=WDOQ26 mt5_xp_container /scripts/configure_nt5.sh
```

Then in VNC: stop → start **NT5TickFeedService**. Confirm the host WS server is
on **8766**, not 8765.

### Bridge port (`RPYC_PORT`)

`vendor/bridge/mt5_bridge.py` reads `RPYC_PORT` from the environment (default
`18812`). The XP compose service sets `RPYC_PORT=18813`. **Rebuild the image**
after pulling this change so new containers pick it up without manual `docker cp`.

### VNC UI freezes on Properties / Options

Use keyboard navigation only, or patch config via `configure_nt5.sh` as above.
See [MANUAL_STEPS.md](MANUAL_STEPS.md).

## Wipe XP volume only

```bash
docker compose --profile xp down -v
```

This does **not** affect Tickmill data (`mt5_tickmill_data`).
