#!/bin/bash
# TEMP: s6-svc -t (TERM) on bridge must not count toward crash-loop budget.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-mt5-docker-mt5-amp:latest}"
NAME="mt5_failpol_term_$$"
SMOKE="$(mktemp -d /tmp/failpol-term.XXXXXX)"

cleanup() {
  docker rm -f "$NAME" 2>/dev/null || true
  rm -rf "$SMOKE"
}
trap cleanup EXIT

cat >"${SMOKE}/noop.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"${SMOKE}/stay.sh" <<'EOF'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "${SMOKE}/noop.sh" "${SMOKE}/stay.sh"

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" \
  -e RUN_MT5=1 -e RUN_BRIDGE=1 -e ENABLE_VNC=0 \
  -e RESET_WINEPREFIX=0 -e INSTALL_MT5=0 \
  -e BOOTSTRAP_PYTHON=0 -e DEPLOY_MQL5=0 -e CONFIGURE_NT5=0 \
  -e VNC_PASSWORD=testpass \
  -e BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS=60 \
  -e BRIDGE_FAILURE_BUDGET_DEATHS=3 \
  -e MT5_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -v "${SMOKE}:/smoke" \
  -v "${SMOKE}/noop.sh:/scripts/wine_bootstrap.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/install_mt5.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/deploy_mql5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/configure_nt5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/bootstrap_python_oneshot.sh:ro" \
  "$IMAGE" >/dev/null

for i in $(seq 1 40); do
  docker exec "$NAME" bash -lc 'test -d /run/service/bridge/supervise' 2>/dev/null && break
  sleep 1
done

# Admin TERM restart x5 — must stay within budget (events exclude SIGTERM).
for n in 1 2 3 4 5; do
  docker exec "$NAME" bash -lc '/command/s6-svc -t /run/service/bridge'
  sleep 2
  running="$(docker inspect -f '{{.State.Running}}' "$NAME")"
  test "$running" = "true" || { echo "FAIL stopped after TERM #$n"; docker logs "$NAME" 2>&1 | tail -40; exit 1; }
done

docker logs "$NAME" 2>&1 | grep -Eq 'failure_budget=exhausted|rapid_crash_loop|container_exit=75' && {
  echo "FAIL TERM restart burned budget / escalated"
  docker logs "$NAME" 2>&1 | grep -E 'BRIDGE-FINISH|failure_budget' | tail -20
  exit 1
}
# Finish may log wantedup_false or within_budget skip for TERM deaths.
echo "TEMP_TERM_NO_BUDGET_BURN_OK"
exit 0
