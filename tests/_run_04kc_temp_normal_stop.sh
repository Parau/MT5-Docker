#!/bin/bash
# TEMP: normal docker stop → container exit 0 (admin stop, not 75).
set -Eeuo pipefail
cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-mt5-docker-mt5-amp:latest}"
NAME="mt5_failpol_stop_$$"
SMOKE="$(mktemp -d /tmp/failpol-stop.XXXXXX)"

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
  -e MT5_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -v "${SMOKE}:/smoke" \
  -v "${SMOKE}/noop.sh:/scripts/wine_bootstrap.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/install_mt5.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/deploy_mql5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/configure_nt5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/bootstrap_python_oneshot.sh:ro" \
  "$IMAGE" >/dev/null

for i in $(seq 1 30); do
  docker exec "$NAME" bash -lc 'test -d /run/service/bridge' 2>/dev/null && break
  sleep 1
done
docker stop -t 15 "$NAME" >/dev/null
code="$(docker inspect -f '{{.State.ExitCode}}' "$NAME")"
echo "stopped exit=${code}"
test "$code" = "0" || { docker logs "$NAME" 2>&1 | tail -40; exit 1; }
docker logs "$NAME" 2>&1 | grep -Eq 'failure_budget=exhausted|rapid_crash_loop' && {
  echo "FAIL stop must not look like crash-loop"
  exit 1
}
echo "TEMP_NORMAL_STOP_0_OK"
exit 0
