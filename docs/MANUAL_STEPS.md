# Manual steps (cannot be fully automated)

MT5 stores WebRequest allowed URLs in an encrypted field inside `common.ini`.
There is no supported way to inject the whitelist from Docker without the MT5 UI.
This document lists everything you must still do by hand.

## Secrets (local only)

1. Copy `.env.example` → `.env`.
2. Set `VNC_PASSWORD` in `.env`. **Never commit `.env`.**
3. If the password contains `#`, `!`, or spaces, wrap it in double quotes:

   ```
   VNC_PASSWORD="your-password-here"
   ```

4. `MT5_LOGIN` / `MT5_PASSWORD` in `.env` are optional placeholders today;
   broker login is done interactively via VNC.

## One-time per volume

### 1. Install MetaTrader 5

```bash
RESET_WINEPREFIX=1 INSTALL_MT5=1 RUN_MT5=0 MT5_INSTALL_MODE=manual \
  docker compose --profile tickmill up mt5-tickmill
```

Via VNC (`127.0.0.1:5901`):

- Run the MT5 installer.
- Log in to your broker account (e.g. Tickmill-Demo).
- Close the installer wizard.

### 2. WebRequest whitelist (required for WS tick feed)

**Tools → Options → Expert Advisors** (use keyboard if the dialog is sluggish):

- [x] Allow algorithmic trading
- [x] Allow WebRequest for listed URL

Add **both** lines (Docker Desktop + WSL2):

```
host.docker.internal
http://host.docker.internal:8765
```

Click **OK** and confirm the dialog closes.

> **Do not use `172.20.0.1` alone** for the service URL on Docker Desktop — from
> Wine inside the container, `host.docker.internal` is the host that works for
> port 8765. You may keep `172.20.0.1` entries in the list; they do not replace
> `host.docker.internal`.

This step is **once per volume**. After `docker compose down` (without `-v`),
the whitelist is preserved.

**XP instance** uses port **8766** instead of 8765:

```
host.docker.internal
http://host.docker.internal:8766
```

See [XP_SETUP.md](XP_SETUP.md).

## Each session (or after container restart)

### 3. Start the WebSocket test server (host)

From the `MT5-Docker` repo:

```bash
./scripts/run_ws_test_server.sh
```

```powershell
.\scripts\run_ws_test_server.ps1
```

Requires a sibling `nt_mt5` checkout and Python with `websockets` installed.

### 4. Start NT5TickFeedService

Via VNC — **do not open Properties** unless you need to change symbols (inputs
are applied automatically by `configure_nt5.sh` on container start):

1. **Navigator → Services → NT5TickFeedService**
2. Right-click → **Start**

If you previously had error **5270** (too many sockets), **Remove** the service,
wait 30 seconds, then **Start** again.

### 5. Verify

**Experts tab** (MT5):

```
 > Connected ws://host.docker.internal:8765/mt5-feed
```

**WS test server** (host):

```
HELLO session=... symbols=['BTCUSD']
TICKS symbol=BTCUSD ...
```

## Optional manual edits

| Task | How |
|------|-----|
| Change symbol / WS URL without UI | Tickmill: `docker exec mt5_tickmill_container /scripts/configure_nt5.sh` — XP: `docker exec mt5_xp_container /scripts/configure_nt5.sh` (set `NT5_WS_URL` / `NT5_WS_SYMBOLS` via `-e`) then restart service |
| Change symbol via UI | Service → Properties → `InpSymbols` (keyboard only) |
| Auto-start service after whitelist | Set `NT5_SERVICE_ENABLED=1` in `.env` and recreate container |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| VNC `Authentication failure` | Wrong password — check `.env`; recreate container after changing `VNC_PASSWORD` |
| Error **4014** | Whitelist missing `host.docker.internal` — complete step 2 |
| Error **5270** | Stop service, wait 30s, start again |
| URL shows `172.20.0.1` in Experts | Restart container so `configure_nt5.sh` runs; or fix in Properties |
| UI frozen | Keyboard: `Esc` / `Enter`; or `docker compose --profile tickmill restart mt5-tickmill` |
| Container exits when MT5 dies | Expected — `docker compose --profile tickmill up -d mt5-tickmill` |
| XP: bootstrap never finishes / no RPyC on 18813 | See [XP_SETUP.md](XP_SETUP.md) — manual pip + `start_bridge.sh` |
| XP: service connects to 8765 not 8766 | Re-run `configure_nt5.sh` on `mt5_xp_container` with `NT5_WS_URL=...8766`; WS server on host port **8766** |
