# MT5-Docker

Headless MetaTrader 5 (Debian + Wine) with VNC, automated MQL5 deploy, Wine Python
RPyC bridge, and NT5TickFeedService wiring for a WebSocket tick feed.

**Security:** credentials live only in your local `.env` (gitignored). Do not commit
`.env`, VNC passwords, or MT5 login details.

Canonical architecture reference: **[docs/S6_ARCHITECTURE.md](docs/S6_ARCHITECTURE.md)**.

## Architecture (s6-overlay)

One image, three independent broker containers. PID1 is s6-overlay (`ENTRYPOINT ["/init"]`; no runtime `CMD`).

```text
Docker /init (s6-svscan)
  ├── display                 longrun
  ├── window-manager          longrun
  ├── wine-bootstrap          oneshot
  ├── vnc-access              longrun
  ├── install-mt5             oneshot
  ├── deploy-mql5             oneshot
  ├── configure-nt5           oneshot
  ├── python-bootstrap        oneshot
  ├── metatrader              longrun  (fatal authority → container exit)
  └── bridge                  longrun  (isolated restart + crash-loop budget)
```

Startup order comes from `images/mt5-headless/s6-rc.d/*/dependencies.d/` (see
[docs/S6_ARCHITECTURE.md](docs/S6_ARCHITECTURE.md)). There is no legacy `entrypoint.sh`
or supervisord runtime.

### Automated on each start (`RUN_MT5=1`)

| Phase | Owner | Role |
|-------|-------|------|
| Display / WM / Wine / VNC | s6 longruns + `wine-bootstrap` | Headless desktop stack |
| Install / deploy / configure / Python | s6 oneshots | Volume bootstrap (gated by env) |
| MetaTrader | `metatrader` → `mt5_lifecycle.sh` | Terminal lifecycle / LiveUpdate |
| Bridge | `bridge` → `start_bridge.sh` | RPyC after local MT process gate |

`extra_hosts: host.docker.internal:host-gateway` lets Wine reach host WebSocket / adapter services.

## What remains manual

See **[docs/MANUAL_STEPS.md](docs/MANUAL_STEPS.md)**. Summary:

| Step | When | Why |
|------|------|-----|
| Create `.env` with `VNC_PASSWORD` | First setup | Secret — local only |
| MT5 installer + broker login | First volume | Interactive UI |
| WebRequest URL whitelist | Once per volume | Encrypted in MT5 `common.ini` |
| Start NT5TickFeedService | Each session (or after whitelist) | No headless Services API start |
| WS test server on host | Tick validation | Host tooling |

## Brokers (Tickmill / XP / AMP)

| Service | Profile | Container | VNC | RPyC | WS (host) | Volume |
|---------|---------|-----------|-----|------|-----------|--------|
| `mt5-tickmill` | `tickmill` | `mt5_tickmill_container` | `127.0.0.1:5901` | `127.0.0.1:18812` | `:8765` | `mt5_tickmill_data` |
| `mt5-xp` | `xp` | `mt5_xp_container` | `127.0.0.1:5902` | `127.0.0.1:18813` | `:8766` | `mt5_xp_data` |
| `mt5-amp` | `amp` | `mt5_amp_container` | `127.0.0.1:5903` | `127.0.0.1:18814` | `:8767` | `mt5_amp_data` |

## Quick start

```bash
cp .env.example .env
# Edit .env — set VNC_PASSWORD (quote if special chars: VNC_PASSWORD="...")
```

Sync vendored assets from `nt_mt5` before build when needed:

```bash
./scripts/sync_vendor_from_nt_mt5.sh
```

```powershell
.\scripts\sync_vendor_from_nt_mt5.ps1
```

### First install (example: Tickmill)

```bash
RESET_WINEPREFIX=1 INSTALL_MT5=1 RUN_MT5=0 MT5_INSTALL_MODE=manual \
  docker compose --profile tickmill up mt5-tickmill
```

Complete installer + login over VNC (`127.0.0.1:5901`) using **your** `.env` password.

### Normal start / stop (prefer target-specific)

```bash
docker compose --profile amp up -d mt5-amp
docker compose --profile amp stop mt5-amp
docker compose --profile amp start mt5-amp
```

All three:

```bash
docker compose --profile tickmill --profile xp --profile amp up -d
```

Never use `down -v` for daily ops (destroys named volumes / login / whitelist).

`docker compose ... down` (without `-v`) removes containers but keeps volumes.
`stop` keeps the container definition and is preferred for pause/resume.

### Health

`docker ps` may show `Up ... (healthy)` or `unhealthy`.

- **Running ≠ healthy.** Process-up is s6; Docker HEALTHCHECK is continuous operational health (RPyC `root.health()` when bridge mode is on).
- Unhealthy is **observational only** — it does not restart bridge/MT or halt the container.
- Compose `restart: "no"`.

Manual probe:

```bash
docker exec mt5_amp_container /scripts/healthcheck_mt5.sh
```

Host RPyC (prefer health):

```bash
python -c "import rpyc; c=rpyc.connect('127.0.0.1',18814); print(c.root.health())"
```

### Failure / recovery (summary)

| Event | Policy |
|-------|--------|
| Bridge isolated crash | s6 restarts **bridge only** (within budget) |
| Bridge rapid crash-loop | default **5 deaths / 60s** → container **exit 75** |
| MT5 lifecycle fatal | container exits with lifecycle code (e.g. 42, 70–74) |
| Broker disconnected / health false | Docker **unhealthy** only |
| Normal `docker stop` | exit **0**; bridge stops before metatrader |

Crash-loop budget counts **process deaths**, not Docker health failures. After exit 75, recovery is an explicit `compose up`/`start` (new `/run` death tally).

### WS tick feed validation

1. Host test server: `./scripts/run_ws_test_server.sh` (or `.ps1`; set `WS_PORT` for XP/AMP).
2. Whitelist + start NT5 service per [docs/MANUAL_STEPS.md](docs/MANUAL_STEPS.md).
3. Expect `HELLO` then `TICKS` in the test server log.

## Environment variables (common)

| Variable | Default | Purpose |
|----------|---------|---------|
| `VNC_PASSWORD` | *(required in .env)* | TigerVNC password |
| `RUN_MT5` / `RUN_BRIDGE` | `1` / `1` | Stage2 gate for longruns |
| `BRIDGE_WAIT_SECONDS` | `180` | Warning interval while waiting for the same verified MT5 identity |
| `BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS` | `60` | Crash-loop window |
| `BRIDGE_FAILURE_BUDGET_DEATHS` | `5` | Crash-loop death threshold |
| `NT5_SERVICE_ENABLED` | `0` | Keep `0` until whitelist is done |

Per-broker login / RPyC / WS placeholders: see `.env.example`.

## Rebuild after code changes

```bash
./scripts/sync_vendor_from_nt_mt5.sh   # if nt_mt5 changed
docker compose --profile tickmill --profile xp --profile amp build
docker compose --profile amp up -d mt5-amp
```

After editing shell scripts on Windows, strip CRLF before build (Dockerfile also
normalizes copied scripts at build time):

```bash
sed -i 's/\r$//' images/mt5-headless/scripts/*.sh
```

## Wine + VNC tips

- Prefer **keyboard** over mouse in modal dialogs.
- If the UI freezes: `Esc`, `Alt+F4`, or `docker compose --profile amp restart mt5-amp`.
- Service inputs without UI:

  ```bash
  docker exec -e NT5_WS_SYMBOLS=EURUSD mt5_tickmill_container /scripts/configure_nt5.sh
  ```

## Related

- Adapter: `nt_mt5`
- Manual checklist: [docs/MANUAL_STEPS.md](docs/MANUAL_STEPS.md)
- XP install notes: [docs/XP_SETUP.md](docs/XP_SETUP.md)
- Architecture: [docs/S6_ARCHITECTURE.md](docs/S6_ARCHITECTURE.md)
- Local WSL cheatsheet: `_como rodar.txt`
