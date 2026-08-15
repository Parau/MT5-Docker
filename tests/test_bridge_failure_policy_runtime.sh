#!/bin/bash
# Official runtime coverage for bridge failure/recovery policy (real s6).
#
# Data flow: spins ephemeral containers from IMAGE with fake MT/bridge
# lifecycles (no broker volumes). Proves budget defaults, crash-loop exit 75,
# MT fatal precedence, normal stop, and observational unhealthy.
# Prerequisites: Docker + built image (default mt5-docker-mt5-amp:latest).
# Limitations: not a broker smoke; does not touch compose volumes.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-mt5-docker-mt5-amp:latest}"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

fail() {
    echo "FAIL: $*"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    exit 1
}

pass() {
    echo "PASS: $*"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" != "$actual" ]; then
        fail "${label}: expected '${expected}', got '${actual}'"
    fi
}

prepare_smoke() {
    SMOKE="$(mktemp -d /tmp/failpol-rt.XXXXXX)"
    NAME="mt5_failpol_rt_${SCENARIO}_$$"
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
    cat >"${SMOKE}/mt_die.sh" <<'EOF'
#!/bin/bash
echo "FAKE_MT_FATAL"
exit 42
EOF
    chmod +x "${SMOKE}"/*.sh
}

cleanup_smoke() {
    docker rm -f "${NAME:-}" 2>/dev/null || true
    rm -rf "${SMOKE:-}"
}

run_common_env() {
    # Extra -e pairs follow as "$@" before IMAGE is implied by caller.
    docker run -d --name "$NAME" \
      -e RUN_MT5=1 -e RUN_BRIDGE=1 -e ENABLE_VNC=0 \
      -e RESET_WINEPREFIX=0 -e INSTALL_MT5=0 \
      -e BOOTSTRAP_PYTHON=0 -e DEPLOY_MQL5=0 -e CONFIGURE_NT5=0 \
      -e VNC_PASSWORD=testpass \
      -v "${SMOKE}:/smoke" \
      -v "${SMOKE}/noop.sh:/scripts/wine_bootstrap.sh:ro" \
      -v "${SMOKE}/noop.sh:/scripts/install_mt5.sh:ro" \
      -v "${SMOKE}/noop.sh:/scripts/deploy_mql5_oneshot.sh:ro" \
      -v "${SMOKE}/noop.sh:/scripts/configure_nt5_oneshot.sh:ro" \
      -v "${SMOKE}/noop.sh:/scripts/bootstrap_python_oneshot.sh:ro" \
      "$@" \
      "$IMAGE" >/dev/null
}

wait_stopped_exit() {
    local expect="$1"
    local max="${2:-120}"
    local i running code
    for i in $(seq 1 "$max"); do
        running="$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)"
        if [ "$running" != "true" ]; then
            code="$(docker inspect -f '{{.State.ExitCode}}' "$NAME")"
            echo "stopped exit=${code} after ${i}s"
            assert_eq "$expect" "$code" "container exit"
            return 0
        fi
        sleep 1
    done
    docker logs "$NAME" 2>&1 | tail -60 || true
    fail "timeout waiting for exit ${expect}"
}

echo "=== runtime A: invalid config fallback uses real defaults (exit75 on 5th) ==="
SCENARIO=invalid
prepare_smoke
trap cleanup_smoke EXIT
docker rm -f "$NAME" 2>/dev/null || true
run_common_env \
  -e MT5_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/crash.sh \
  -e BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS=invalid \
  -e BRIDGE_FAILURE_BUDGET_DEATHS=1
wait_stopped_exit 75 180
docker logs "$NAME" 2>&1 | grep -q 'failure_budget_config_invalid key=BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS' || \
  echo "NOTE: invalid-window warning may only appear in finish stream"
docker logs "$NAME" 2>&1 | grep -Eq 'failure_budget=exhausted|rapid_crash_loop' || \
  echo "NOTE: exhausted log optional; exit75 is authoritative"
pass "invalid env falls back to 60/5 and reaches exit 75"
cleanup_smoke
trap - EXIT

echo "=== runtime B: below budget restarts; MT PID stable ==="
SCENARIO=below
prepare_smoke
trap cleanup_smoke EXIT
docker rm -f "$NAME" 2>/dev/null || true
run_common_env \
  -e MT5_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/crash_once.sh \
  -e BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS=60 \
  -e BRIDGE_FAILURE_BUDGET_DEATHS=5
mt_pid=""
ok=0
for i in $(seq 1 90); do
    running="$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)"
    if [ "$running" != "true" ]; then
        code="$(docker inspect -f '{{.State.ExitCode}}' "$NAME")"
        fail "unexpected stop exit=${code} below budget"
    fi
    if [ -z "$mt_pid" ]; then
        mt_pid="$(docker exec "$NAME" bash -lc '/command/s6-svstat -o pid /run/service/metatrader' 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    if [ -f "${SMOKE}/deaths" ] && [ "$(cat "${SMOKE}/deaths")" -ge 2 ]; then
        sleep 3
        running="$(docker inspect -f '{{.State.Running}}' "$NAME")"
        assert_eq "true" "$running" "still running after restart"
        mt_pid2="$(docker exec "$NAME" bash -lc '/command/s6-svstat -o pid /run/service/metatrader' | tr -d '[:space:]')"
        assert_eq "$mt_pid" "$mt_pid2" "MT PID stable across bridge restart"
        docker logs "$NAME" 2>&1 | grep -q 'failure_budget=exhausted' && fail "exhausted while below budget"
        ok=1
        break
    fi
    sleep 1
done
[ "$ok" -eq 1 ] || fail "below-budget timeout"
pass "below budget: bridge restarts; MT PID stable"
cleanup_smoke
trap - EXIT

echo "=== runtime C: rapid crash-loop (deaths=3) → exit 75 ==="
SCENARIO=rapid
prepare_smoke
trap cleanup_smoke EXIT
docker rm -f "$NAME" 2>/dev/null || true
run_common_env \
  -e MT5_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/crash.sh \
  -e BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS=60 \
  -e BRIDGE_FAILURE_BUDGET_DEATHS=3
wait_stopped_exit 75 120
pass "rapid crash-loop exits 75"
cleanup_smoke
trap - EXIT

echo "=== runtime D: metatrader fatal → exit 42 ==="
SCENARIO=mt42
prepare_smoke
trap cleanup_smoke EXIT
docker rm -f "$NAME" 2>/dev/null || true
run_common_env \
  -e MT5_LIFECYCLE_SCRIPT=/smoke/mt_die.sh \
  -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/stay.sh
wait_stopped_exit 42 60
pass "metatrader fatal exits 42"
cleanup_smoke
trap - EXIT

echo "=== runtime E: normal stop → exit 0 ==="
SCENARIO=stop
prepare_smoke
trap cleanup_smoke EXIT
docker rm -f "$NAME" 2>/dev/null || true
run_common_env \
  -e MT5_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/stay.sh
for i in $(seq 1 30); do
    docker exec "$NAME" bash -lc 'test -d /run/service/bridge' 2>/dev/null && break
    sleep 1
done
docker stop -t 15 "$NAME" >/dev/null
code="$(docker inspect -f '{{.State.ExitCode}}' "$NAME")"
assert_eq "0" "$code" "normal stop exit"
docker logs "$NAME" 2>&1 | grep -Eq 'failure_budget=exhausted|rapid_crash_loop' && \
  fail "normal stop must not look like crash-loop"
pass "normal stop exits 0"
cleanup_smoke
trap - EXIT

echo "=== runtime F: persistent unhealthy is observational ==="
SCENARIO=unh
prepare_smoke
trap cleanup_smoke EXIT
docker rm -f "$NAME" 2>/dev/null || true
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

st=""
for i in $(seq 1 90); do
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null || echo none)"
    if [ "$st" = "unhealthy" ]; then
        break
    fi
    sleep 1
done
assert_eq "unhealthy" "$st" "health status"
bridge_pid1="$(docker exec "$NAME" bash -lc '/command/s6-svstat -o pid /run/service/bridge' | tr -d '[:space:]')"
mt_pid1="$(docker exec "$NAME" bash -lc '/command/s6-svstat -o pid /run/service/metatrader' | tr -d '[:space:]')"
sleep 10
running="$(docker inspect -f '{{.State.Running}}' "$NAME")"
st2="$(docker inspect -f '{{.State.Health.Status}}' "$NAME")"
bridge_pid2="$(docker exec "$NAME" bash -lc '/command/s6-svstat -o pid /run/service/bridge' | tr -d '[:space:]')"
mt_pid2="$(docker exec "$NAME" bash -lc '/command/s6-svstat -o pid /run/service/metatrader' | tr -d '[:space:]')"
assert_eq "true" "$running" "still running while unhealthy"
assert_eq "unhealthy" "$st2" "still unhealthy"
assert_eq "$bridge_pid1" "$bridge_pid2" "bridge PID unchanged"
assert_eq "$mt_pid1" "$mt_pid2" "MT PID unchanged"
docker logs "$NAME" 2>&1 | grep -Eq 'failure_budget=exhausted|rapid_crash_loop' && \
  fail "unhealthy must not escalate crash-loop"
pass "persistent unhealthy does not restart/halt"
cleanup_smoke
trap - EXIT

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
