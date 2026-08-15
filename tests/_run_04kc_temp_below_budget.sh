#!/bin/bash
# TEMP: below-budget bridge crashes restart; container stays running.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-mt5-docker-mt5-amp:latest}"
NAME="mt5_failpol_below_$$"
SMOKE="$(mktemp -d /tmp/failpol-below.XXXXXX)"

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
# Crash once then stay up (write marker after first death via counter file).
cat >"${SMOKE}/crash_once.sh" <<'EOF'
#!/bin/bash
MARKER=/smoke/deaths
n=0
if [ -f "$MARKER" ]; then n=$(cat "$MARKER"); fi
n=$((n + 1))
echo "$n" >"$MARKER"
if [ "$n" -lt 2 ]; then
  echo "FAKE_BRIDGE_CRASH_ONCE n=$n"
  exit 42
fi
echo "FAKE_BRIDGE_STABLE n=$n"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "${SMOKE}/noop.sh" "${SMOKE}/stay.sh" "${SMOKE}/crash_once.sh"

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" \
  -e RUN_MT5=1 -e RUN_BRIDGE=1 -e ENABLE_VNC=0 \
  -e RESET_WINEPREFIX=0 -e INSTALL_MT5=0 \
  -e BOOTSTRAP_PYTHON=0 -e DEPLOY_MQL5=0 -e CONFIGURE_NT5=0 \
  -e VNC_PASSWORD=testpass \
  -e MT5_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/crash_once.sh \
  -e BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS=60 \
  -e BRIDGE_FAILURE_BUDGET_DEATHS=5 \
  -v "${SMOKE}:/smoke" \
  -v "${SMOKE}/noop.sh:/scripts/wine_bootstrap.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/install_mt5.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/deploy_mql5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/configure_nt5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/bootstrap_python_oneshot.sh:ro" \
  "$IMAGE" >/dev/null

echo "waiting for within-budget restart then stable..."
for i in $(seq 1 90); do
  running="$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)"
  if [ "$running" != "true" ]; then
    code="$(docker inspect -f '{{.State.ExitCode}}' "$NAME")"
    echo "UNEXPECTED stop exit=${code}"
    docker logs "$NAME" 2>&1 | tail -40
    exit 1
  fi
  if [ -f "${SMOKE}/deaths" ] && [ "$(cat "${SMOKE}/deaths")" -ge 2 ]; then
    docker logs "$NAME" 2>&1 | grep -q 'failure_budget=within_budget' || \
      docker logs "$NAME" 2>&1 | grep -q 'restart_allowed=1' || true
    # Still running after restart; no halt/75.
    docker logs "$NAME" 2>&1 | grep -q 'failure_budget=exhausted' && {
      echo "FAIL: exhausted while below budget"; exit 1
    }
    sleep 3
    running="$(docker inspect -f '{{.State.Running}}' "$NAME")"
    test "$running" = "true" || { echo "FAIL: not running after restart"; exit 1; }
    echo "TEMP_BELOW_BUDGET_OK deaths=$(cat "${SMOKE}/deaths")"
    exit 0
  fi
  sleep 1
done
echo "TIMEOUT"
docker logs "$NAME" 2>&1 | tail -60
exit 1
