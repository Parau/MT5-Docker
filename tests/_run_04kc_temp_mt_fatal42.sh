#!/bin/bash
# TEMP: metatrader fake exit 42 must win final container exitcode (not 75).
set -Eeuo pipefail
cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-mt5-docker-mt5-amp:latest}"
NAME="mt5_failpol_mt42_$$"
SMOKE="$(mktemp -d /tmp/failpol-mt42.XXXXXX)"

cleanup() {
  docker rm -f "$NAME" 2>/dev/null || true
  rm -rf "$SMOKE"
}
trap cleanup EXIT

cat >"${SMOKE}/noop.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"${SMOKE}/mt_die.sh" <<'EOF'
#!/bin/bash
echo "FAKE_MT_FATAL"
exit 42
EOF
cat >"${SMOKE}/bridge_stay.sh" <<'EOF'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "${SMOKE}/noop.sh" "${SMOKE}/mt_die.sh" "${SMOKE}/bridge_stay.sh"

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" \
  -e RUN_MT5=1 -e RUN_BRIDGE=1 -e ENABLE_VNC=0 \
  -e RESET_WINEPREFIX=0 -e INSTALL_MT5=0 \
  -e BOOTSTRAP_PYTHON=0 -e DEPLOY_MQL5=0 -e CONFIGURE_NT5=0 \
  -e VNC_PASSWORD=testpass \
  -e MT5_LIFECYCLE_SCRIPT=/smoke/mt_die.sh \
  -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/bridge_stay.sh \
  -v "${SMOKE}:/smoke" \
  -v "${SMOKE}/noop.sh:/scripts/wine_bootstrap.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/install_mt5.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/deploy_mql5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/configure_nt5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/bootstrap_python_oneshot.sh:ro" \
  "$IMAGE" >/dev/null

echo "waiting for metatrader fatal exit 42..."
for i in $(seq 1 60); do
  running="$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)"
  if [ "$running" != "true" ]; then
    code="$(docker inspect -f '{{.State.ExitCode}}' "$NAME")"
    echo "stopped exit=${code} after ${i}s"
    test "$code" = "42" || { docker logs "$NAME" 2>&1 | tail -40; exit 1; }
    echo "TEMP_MT_FATAL_42_OK"
    exit 0
  fi
  sleep 1
done
echo "TIMEOUT"
docker logs "$NAME" 2>&1 | tail -40
exit 1
