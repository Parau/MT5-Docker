# MT5-Docker

Headless MetaTrader 5 (Debian + Wine) with VNC, automated MQL5 deploy, Wine Python
bridge (RPyC), and NT5TickFeedService input wiring for WebSocket tick feed.

**Security:** credentials live only in your local `.env` (gitignored). Do not commit
`.env`, VNC passwords, or MT5 login details to this public repository.

## What is automated on each start

When `RUN_MT5=1` (default), the container automatically:

| Step | Script | Description |
|------|--------|-------------|
| 1 | entrypoint | Wine prefix, Xvnc, openbox |
| 2 | entrypoint | Start `terminal64.exe` |
| 3 | `deploy_mql5.sh` | Sync `NT5TickFeedService` (`.mq5` + vendored `.ex5`) + `Include/` into MT5 `MQL5/` |
| 4 | `configure_nt5.sh` | Set `services.ini` inputs (`NT5_WS_URL`, symbols) + algo-trading flags in `common.ini` |
| 5 | `bootstrap_python.sh` | Wine Python + `numpy<2` + `MetaTrader5` + `rpyc` (once per volume) |
| 6 | `start_bridge.sh` | RPyC bridge on port **18812** after MT5 responds |

`extra_hosts: host.docker.internal:host-gateway` is set so Wine can reach services on
the Docker host (WebSocket test server, adapter).

## What remains manual (one-time or per session)

See **[docs/MANUAL_STEPS.md](docs/MANUAL_STEPS.md)** for the full checklist. Summary:

| Step | When | Why not automated |
|------|------|-------------------|
| Create `.env` with `VNC_PASSWORD` | First setup | Secret — local only |
| MT5 installer + broker login | First volume / reprovision | Interactive UI |
| **WebRequest URL whitelist** | Once per volume | MT5 stores allowed URLs encrypted in `common.ini` |
| **Start NT5TickFeedService** | Each session (or after whitelist) | MT5 Services API has no headless start; avoid auto-start before whitelist (4014 loop) |
| WS test server on host | While testing ticks | Adapter/test tooling runs on host |

## Quick start

```bash
cp .env.example .env
# Edit .env — set VNC_PASSWORD (quote if special chars: VNC_PASSWORD="...")
```

Sync vendored assets from `nt_mt5` before build (includes compiled `NT5TickFeedService.ex5` when present in `nt_mt5/MQL5/refactoring/Services/`):

```powershell
.\scripts\sync_vendor_from_nt_mt5.ps1
```

```bash
./scripts/sync_vendor_from_nt_mt5.sh
```

### First install (Tickmill)

```bash
RESET_WINEPREFIX=1 INSTALL_MT5=1 RUN_MT5=0 MT5_INSTALL_MODE=manual \
  docker compose --profile tickmill up mt5-tickmill
```

- VNC: `127.0.0.1:5901` — complete MT5 installer and log in to the broker.
- Use the password from **your** `.env` only.

### Normal use

```bash
docker compose --profile tickmill up -d mt5-tickmill
docker compose --profile tickmill logs -f mt5-tickmill
```

Verify RPyC from the host (no `ping` on the bridge — use `terminal_info`):

```bash
python -c "import rpyc; c=rpyc.connect('127.0.0.1',18812); i=c.root.terminal_info(); print(i.connected, i.name)"
```

### WS tick feed validation

1. On the host, start the test server (requires `nt_mt5` checkout + `websockets`):

   ```bash
   ./scripts/run_ws_test_server.sh
   ```

   ```powershell
   .\scripts\run_ws_test_server.ps1
   ```

2. Complete the **whitelist** and **service start** steps in [docs/MANUAL_STEPS.md](docs/MANUAL_STEPS.md).

3. Expect `HELLO` then `TICKS` in the test server log.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `VNC_PASSWORD` | *(required in .env)* | TigerVNC password |
| `NT5_WS_URL` | `ws://host.docker.internal:8765/mt5-feed` | Service WebSocket URL |
| `NT5_WS_SYMBOLS` | `BTCUSD` | `InpSymbols` |
| `NT5_SERVICE_ENABLED` | `0` | `enabled=` in `services.ini` — set `1` only after whitelist |
| `CONFIGURE_NT5` | `1` | Patch `services.ini` / `common.ini` on start |
| `DEPLOY_MQL5` | `1` | Deploy MQL5 tree |
| `RUN_BRIDGE` | `1` | Start RPyC bridge |
| `RPYC_PORT` | `18812` | Bridge port |

Disable all automation (debug):

```bash
CONFIGURE_NT5=0 RUN_BRIDGE=0 BOOTSTRAP_PYTHON=0 DEPLOY_MQL5=0 \
  docker compose --profile tickmill up mt5-tickmill
```

## Rebuild after code changes

```bash
./scripts/sync_vendor_from_nt_mt5.sh   # if nt_mt5 changed
docker compose --profile tickmill build mt5-tickmill
docker compose --profile tickmill up -d mt5-tickmill
```

After editing shell scripts on Windows, strip CRLF before build:

```bash
sed -i 's/\r$//' images/mt5-headless/entrypoint.sh images/mt5-headless/scripts/*.sh
```

## Wine + VNC tips

- Prefer **keyboard** over mouse in modal dialogs (Properties, Options).
- If the UI freezes: `Esc`, `Alt+F4`, or `docker compose --profile tickmill restart mt5-tickmill`.
- Service inputs can be changed without the UI: re-run configure inside the container:

  ```bash
  docker exec -e NT5_WS_SYMBOLS=EURUSD mt5_tickmill_container /scripts/configure_nt5.sh
  ```

## Related

- Adapter repo: `nt_mt5` (Nautilus MT5 adapter)
- Manual checklist: [docs/MANUAL_STEPS.md](docs/MANUAL_STEPS.md)
- **XP second instance:** [docs/XP_SETUP.md](docs/XP_SETUP.md)
- Local notes: `_como rodar.txt` (WSL commands)

## Two brokers (Tickmill + XP)

| Service | Profile | VNC | RPyC | WS (host) |
|---------|---------|-----|------|-----------|
| `mt5-tickmill` | `tickmill` | `:5901` | `:18812` | `:8765` |
| `mt5-xp` | `xp` | `:5902` | `:18813` | `:8766` |

Run both:

```bash
docker compose --profile tickmill --profile xp up -d
```

See [docs/XP_SETUP.md](docs/XP_SETUP.md) for XP first install.
