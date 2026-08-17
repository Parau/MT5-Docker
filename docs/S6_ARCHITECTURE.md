# S6 architecture (MT5-Docker)

Canonical reference for the MetaTrader 5 headless container after the s6-overlay
refactor (Issue #3 / tasks 04A–04K). Runtime policies here are **frozen**; change
them only with an explicit architectural decision.

## A. Scope

- **One image** (`images/mt5-headless`), three **independent** compose services /
  containers (Tickmill, XP, AMP).
- **Fault isolation:** bridge crash does not equal MT fatal; Docker unhealthy does
  not restart or halt anything.
- No legacy PID1 (`entrypoint.sh`, supervisord).

## B. Container topology

```text
Docker
  ENTRYPOINT ["/init"]     # s6-overlay
  CMD = null
  PID1 ≈ s6-svscan

/init
  ├── display                  longrun
  ├── window-manager           longrun
  ├── wine-bootstrap           oneshot
  ├── vnc-access               longrun
  ├── install-mt5              oneshot
  ├── deploy-mql5              oneshot
  ├── configure-nt5            oneshot
  ├── python-bootstrap         oneshot
  ├── metatrader               longrun / fatal authority
  │     └── mt5_lifecycle.sh
  └── bridge                   longrun / isolated restart
        └── start_bridge.sh
              └── Wine Python mt5_bridge.py

Docker HEALTHCHECK  →  metatrader up + bridge up + RPyC root.health()
                       (observational; not s6 ready)
```

## C. s6 services

| Service | Type | Role | Dependencies | Fatal / restart |
|---------|------|------|--------------|-----------------|
| `display` | longrun | Display backend owner: Xvnc/Xtigervnc by default when VNC is enabled; Xvfb for alternate/non-VNC operation | `base` (s6-overlay) | supervised restart |
| `window-manager` | longrun | openbox | `display` | supervised restart |
| `wine-bootstrap` | oneshot | Wine prefix bootstrap | `window-manager` | oneshot |
| `vnc-access` | longrun | VNC access policy: delegates to display-owned Xvnc (sentinel), owns x11vnc fallback, or stays as sentinel when disabled | `wine-bootstrap` | supervised restart |
| `install-mt5` | oneshot | MT5 install gate | `vnc-access` | oneshot |
| `deploy-mql5` | oneshot | Vendor MQL5 sync | `install-mt5` | oneshot |
| `configure-nt5` | oneshot | `services.ini` / Experts flags | `deploy-mql5` | oneshot |
| `python-bootstrap` | oneshot | Wine Python + packages | `configure-nt5` | oneshot |
| `metatrader` | longrun | Terminal lifecycle | `python-bootstrap` | **fatal** → exitcode + halt |
| `bridge` | longrun | RPyC bridge | `metatrader` | isolated restart; crash-loop → **75** |

Source of truth: `images/mt5-headless/s6-rc.d/*/type` and `dependencies.d/`.

Display/VNC (defaults `DISPLAY_BACKEND=xvnc`, `ENABLE_VNC=1`): `display` execs Xvnc or
Xtigervnc when those defaults hold, otherwise Xvfb. `vnc-access` then either
delegates to that display-owned Xvnc (sentinel), stays as sentinel when VNC is
disabled, or waits for display/window-manager and execs x11vnc as fallback.

User bundle: `images/mt5-headless/user-bundles.d/user/contents.d/` lists the same
ten services. No `mt5-ready` / watchdog services.

## D. Startup flow

1. Stage2 hook `S6_STAGE2_HOOK=/scripts/s6_stage2_bridge_gate.sh` enables or
   disables the bridge service marker from `RUN_MT5` / `RUN_BRIDGE`.
2. Oneshots run in dependency order through Python bootstrap.
3. `metatrader` execs `mt5_lifecycle.sh` (or skip when `RUN_MT5=0`).
4. `bridge` execs `start_bridge.sh` after metatrader is up (process-up only).

## E. Service-only runtime

- `ENTRYPOINT ["/init"]`, no project `CMD`, no idle barrier.
- `ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2`.
- Overlay version pinned: `ARG S6_OVERLAY_VERSION=3.2.3.2`.
- No project `cont-finish.d` Wine killer; last containment is generic s6 stage3.

## F. MT5 lifecycle

- Owned by `metatrader` + `scripts/mt5_lifecycle.sh`.
- Preserves LiveUpdate handoff semantics (exits **70–74** as documented in
  lifecycle tests/contracts).
- Fatal path: lifecycle exit → `metatrader/finish` writes exitcode → `halt` →
  finish **125** → container exits with that code.
- `metatrader/finish` **preserves a prior non-zero** exitcode (so bridge **75**
  is not wiped by TERM→0 during halt cascade).

## G. Bridge lifecycle

- Owned by `bridge` + `scripts/start_bridge.sh`.
- Startup uses a **passive local terminal-process gate** (`/proc` cmdline scan
  for a stable normal `terminal64.exe`). Updater/LiveUpdate does not admit the
  server. The real `mt5_bridge.py` process performs the only startup
  `initialize()`.
- `BRIDGE_WAIT_SECONDS` is a warning/observability interval during that wait;
  the wrapper keeps waiting and does not launch without a normal terminal.
- On death: `bridge/finish` captures `wantedup`, quiesces old PGID, then
  `s6-permafailon` against the s6 death tally.
- Defaults: **60s** window, **5** deaths; events = exits `1–255` + abnormal
  signals; **excludes** exit0 / SIGTERM / SIGINT.
- Within budget → finish **0** (supervise restarts bridge only).
- Exhausted / unsafe cleanup while wanted-up → exitcode **75**, halt, finish **125**.
- Admin down (`wantedup=false`) skips budget (no spurious **75**).

## H. Readiness / health

| Signal | Meaning |
|--------|---------|
| s6 `up` | process-up only |
| s6 `ready` (bridge) | **false by design** — no `notification-fd` |
| Docker HEALTHCHECK | continuous operational health |

Deliberately **not** adopted: `notification-fd`, `timeout-up`, `data/check`,
`s6-notifyoncheck`, `mt5-ready`.

Healthcheck calls RPyC `root.health()` (no `MetaTrader5.initialize`). Unhealthy
never runs `s6-svc` / halt / restart.

## I. Shutdown

- Dependency reverse order: **bridge before metatrader**.
- Normal stop → container exit **0**.
- No project `wineserver -k` fallback.

## J. Exit code registry

| Code | Meaning |
|------|---------|
| 0 | Normal stop / success |
| 70 | Update timeout |
| 71 | Relaunch missing |
| 72 | Inconsistent lifecycle |
| 73 | Reserved |
| 74 | Unexpected / no MT process after handoff |
| 75 | Bridge unrecoverable (crash-loop / unsafe while up) |
| 128+N | Uncaught signal N (when mapped via finish) |

## K. Configuration matrix

| `RUN_MT5` | `RUN_BRIDGE` | Effect |
|-----------|--------------|--------|
| 0 | * | Metatrader skipped; bridge gate disabled |
| 1 | 0 | MT only; no bridge longrun |
| 1 | 1 | Full stack (default) |

Compose always sets `restart: "no"` and `stop_grace_period: 30s`.

## L. Broker matrix

| Broker | Profile | Service | VNC | RPyC | WS | Volume |
|--------|---------|---------|-----|------|----|--------|
| Tickmill | `tickmill` | `mt5-tickmill` | 5901 | 18812 | 8765 | `mt5_tickmill_data` |
| XP | `xp` | `mt5-xp` | 5902 | 18813 | 8766 | `mt5_xp_data` |
| AMP | `amp` | `mt5-amp` | 5903 | 18814 | 8767 | `mt5_amp_data` |

Host binds for VNC and RPyC are `127.0.0.1`.

## M. Security

- Secrets only in local `.env` (gitignored; also in `.dockerignore`).
- No tracked credentials; do not `printenv` / dump `/proc/*/environ` in ops docs.
- RPyC and VNC published on loopback only.

## N. Known deliberate limitations

1. `start_bridge.sh` uses a passive local terminal-process gate; the real
   bridge process performs the only startup `initialize()`.
2. MetaQuotes documents that `initialize()` may launch a terminal if required;
   the gate reduces ownership ambiguity but does not provide a guarantee beyond
   the official API.
3. `BRIDGE_WAIT_SECONDS` is a warning interval during passive wait, not a
   launch timeout.
4. Bridge process-up ≠ operational health. Waiting for a terminal is s6 `up`
   with RPyC absent and Docker unhealthy — by design.
5. Broker disconnected → Docker unhealthy, no auto-restart.
6. Bridge alive-but-wedged → unhealthy, no watchdog restart.
7. Compose `restart: "no"`.
8. Spontaneous bridge `exit 0` deaths are not counted by the budget.
9. NT5 WebSocket service still needs whitelist + manual start (see MANUAL_STEPS).
10. Native s6 readiness for the bridge was deliberately rejected.

## Related tests

- `tests/test_start_bridge.sh` — local process gate
- `tests/test_bridge_process_gate.sh` — classifier/TEMP process gate
- `tests/test_s6_final_architecture.sh` — high-level invariants
- `tests/test_bridge_failure_policy.sh` / `_runtime.sh` — failure budget
- `tests/test_bridge_readiness_policy.sh` — frozen readiness
- `tests/test_healthcheck_mt5.sh` — observational health
- `tests/test_service_only_runtime.sh` — no CMD / no Wine finalizer
