#!/bin/bash
# TEMP: persistent Docker unhealthy must not restart bridge/MT or halt.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-mt5-docker-mt5-amp:latest}"
NAME="mt5_failpol_unh_$$"
SMOKE="$(mktemp -d /tmp/failpol-unh.XXXXXX)"

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
# Override image HEALTHCHECK entirely (including 420s start-period).
docker run -d --name "$NAME" \
  --health-cmd='PATH=/command:$PATH /scripts/healthcheck_mt5.sh' \
  --health-interval=2s \
  --health-timeout=8s \
  --health-retries=1 \
  --health-start-period=1s \
  -e RUN_MT5=1 -e RUN_BRIDGE=1 -e ENABLE_VNC=0 \
  -e RESET_WINEPREFIX=0 -e INSTALL_MT5=0 \
  -e BOOTSTRAP_PYTHON=0 -e DEPLOY_MQL5=0 -e CONFIGURE_NT5=0 \
  -e VNC_PASSWORD=testpass \
  -e RPYC_PORT=18814 \
  -e HEALTHCHECK_RPC_TIMEOUT_SECONDS=2 \
  -e MT5_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -v "${SMOKE}:/smoke" \
  -v "${SMOKE}/noop.sh:/scripts/wine_bootstrap.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/install_mt5.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/deploy_mql5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/configure_nt5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/bootstrap_python_oneshot.sh:ro" \
  "$IMAGE" >/dev/null

echo "waiting for unhealthy (no RPyC server)..."
for i in $(seq 1 90); do
  st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null || echo none)"
  failing="$(docker inspect -f '{{if .State.Health}}{{.State.Health.FailingStreak}}{{else}}0{{end}}' "$NAME" 2>/dev/null || echo 0)"
  if [ "$st" = "unhealthy" ]; then
    echo "unhealthy after ${i}s failing_streak=${failing}"
    break
  fi
  if [ "$i" -eq 15 ] || [ "$i" -eq 45 ]; then
    echo "t=${i}s health=${st} streak=${failing}"
    docker inspect -f '{{json .State.Health}}' "$NAME" 2>/dev/null | head -c 800 || true
    echo
  fi
  sleep 1
done
st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME")"
if [ "$st" != "unhealthy" ]; then
  echo "FAIL health=$st"
  docker inspect -f '{{json .State.Health}}' "$NAME" || true
  docker exec "$NAME" bash -lc 'PATH=/command:$PATH /scripts/healthcheck_mt5.sh; echo hc_exit=$?' || true
  docker logs "$NAME" 2>&1 | tail -40
  exit 1
fi

bridge_pid1="$(docker exec "$NAME" bash -lc '/command/s6-svstat -o pid /run/service/bridge' | tr -d '[:space:]')"
mt_pid1="$(docker exec "$NAME" bash -lc '/command/s6-svstat -o pid /run/service/metatrader' | tr -d '[:space:]')"
echo "pids bridge=${bridge_pid1} mt=${mt_pid1}"

# Persist across >=3 health intervals (2s); wait well past that.
sleep 10
running="$(docker inspect -f '{{.State.Running}}' "$NAME")"
st2="$(docker inspect -f '{{.State.Health.Status}}' "$NAME")"
bridge_pid2="$(docker exec "$NAME" bash -lc '/command/s6-svstat -o pid /run/service/bridge' | tr -d '[:space:]')"
mt_pid2="$(docker exec "$NAME" bash -lc '/command/s6-svstat -o pid /run/service/metatrader' | tr -d '[:space:]')"

test "$running" = "true" || { echo "FAIL not running"; exit 1; }
test "$st2" = "unhealthy" || { echo "FAIL health drifted to $st2"; exit 1; }
test -n "$bridge_pid1" && test "$bridge_pid1" = "$bridge_pid2" || {
  echo "FAIL bridge PID changed '${bridge_pid1}' -> '${bridge_pid2}'"
  exit 1
}
test -n "$mt_pid1" && test "$mt_pid1" = "$mt_pid2" || {
  echo "FAIL mt PID changed '${mt_pid1}' -> '${mt_pid2}'"
  exit 1
}
docker logs "$NAME" 2>&1 | grep -Eq 'failure_budget=exhausted|reason=rapid_crash_loop|action=halt reason=' && {
  echo "FAIL unexpected fatal escalation during unhealthy"
  docker logs "$NAME" 2>&1 | tail -30
  exit 1
}
echo "TEMP_UNHEALTHY_NO_RESTART_OK bridge=${bridge_pid1} mt=${mt_pid1}"
exit 0
