#!/bin/bash
# TEMP: real s6-permafailon crash-loop budget exhausts to container exit 75.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-mt5-docker-mt5-amp:latest}"
NAME="mt5_failpol_tmp_$$"
SMOKE="$(mktemp -d /tmp/failpol.XXXXXX)"

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
cat >"${SMOKE}/crash.sh" <<'EOF'
#!/bin/bash
echo "FAKE_BRIDGE_CRASH"
exit 42
EOF
chmod +x "${SMOKE}/noop.sh" "${SMOKE}/stay.sh" "${SMOKE}/crash.sh"

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" \
  -e RUN_MT5=1 -e RUN_BRIDGE=1 -e ENABLE_VNC=0 \
  -e RESET_WINEPREFIX=0 -e INSTALL_MT5=0 \
  -e BOOTSTRAP_PYTHON=0 -e DEPLOY_MQL5=0 -e CONFIGURE_NT5=0 \
  -e VNC_PASSWORD=testpass \
  -e MT5_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/crash.sh \
  -e BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS=60 \
  -e BRIDGE_FAILURE_BUDGET_DEATHS=3 \
  -v "${SMOKE}:/smoke" \
  -v "${SMOKE}/noop.sh:/scripts/wine_bootstrap.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/install_mt5.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/deploy_mql5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/configure_nt5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/bootstrap_python_oneshot.sh:ro" \
  "$IMAGE" >/dev/null

echo "waiting for crash-loop escalate to exit 75..."
for i in $(seq 1 120); do
  running="$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)"
  if [ "$running" != "true" ]; then
    code="$(docker inspect -f '{{.State.ExitCode}}' "$NAME")"
    echo "stopped exit=${code} after ${i}s"
    test "$code" = "75" || { docker logs "$NAME" 2>&1 | tail -40; exit 1; }
    docker logs "$NAME" 2>&1 | grep -q 'failure_budget=exhausted' || \
      docker logs "$NAME" 2>&1 | grep -q 'rapid_crash_loop' || \
      echo "NOTE: exhausted log may be in finish output; exit75 confirmed"
    echo "TEMP_CRASH_LOOP_75_OK"
    exit 0
  fi
  sleep 1
done
echo "TIMEOUT still running"
docker logs "$NAME" 2>&1 | tail -60
exit 1
