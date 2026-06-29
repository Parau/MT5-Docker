# Vendored assets from nt_mt5 (sync before build)

Copied from `nt_mt5/MQL5/refactoring/` for self-contained Docker builds.

| Asset | Source | Deploy target (container start) |
|-------|--------|----------------------------------|
| `mql5/Services/NT5TickFeedService.mq5` | `Services/` | `MQL5/Services/` |
| `mql5/Services/NT5TickFeedService.ex5` | `Services/` (compile F7 in MetaEditor) | `MQL5/Services/` |
| `mql5/Include/*` | `Include/` | `MQL5/Include/` |
| `bridge/*.py` | `bridge/` | `/opt/bridge/` (image build) |

After changing the Service source, **recompile in MetaEditor** and commit or sync the
`.ex5` alongside the `.mq5` in `nt_mt5` before running sync — Docker deploys both so
VNC compile is optional on rebuild.

Refresh after bridge or Service changes:

```powershell
# from MT5-Docker repo root
.\scripts\sync_vendor_from_nt_mt5.ps1
```

Or WSL:

```bash
./scripts/sync_vendor_from_nt_mt5.sh
```

Then rebuild the image:

```bash
docker compose --profile tickmill build mt5-tickmill
docker compose --profile tickmill up -d mt5-tickmill
```
