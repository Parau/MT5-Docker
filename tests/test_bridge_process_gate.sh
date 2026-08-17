#!/bin/bash
# TEMP/runtime coverage for the start_bridge.sh local MT5 process gate.
#
# Data flow: ephemeral containers from IMAGE with fake metatrader + fake wine,
# overlaying production start_bridge.sh. No broker volumes. Limitations: not a
# broker smoke; server child is a stay stub (no real RPyC/initialize).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-mt5-docker-mt5-amp:latest}"
SCRIPT="${ROOT}/images/mt5-headless/scripts/start_bridge.sh"

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
    SMOKE="$(mktemp -d /tmp/procgate.XXXXXX)"
    cat >"${SMOKE}/noop.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
    cat >"${SMOKE}/stay.sh" <<'EOF'
#!/bin/bash
echo "FAKE_STAY name=${FAKE_NAME:-unknown}"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
    cat >"${SMOKE}/hold.sh" <<'EOF'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
    mkdir -p "${SMOKE}/bin"
    cat >"${SMOKE}/bin/wine" <<'EOF'
#!/bin/bash
echo "$*" >>/smoke/wine_calls
if [ "${1:-}" = "python" ] && [ "${2:-}" = "-" ]; then
    echo "PROBE_FORBIDDEN" >>/smoke/wine_calls
    exit 97
fi
if [ "${1:-}" = "python" ] && [ "${2:-}" = "mt5_bridge.py" ]; then
    echo $$ >/smoke/server.pid
    exec /smoke/stay.sh
fi
exit 97
EOF
    : >"${SMOKE}/wine_calls"
    chmod +x "${SMOKE}/noop.sh" "${SMOKE}/stay.sh" "${SMOKE}/hold.sh" "${SMOKE}/bin/wine"
}

start_temp_container() {
    NAME="mt5_procgate_$$"
    docker rm -f "$NAME" 2>/dev/null || true
    docker run -d --name "$NAME" \
      -e RUN_MT5=1 -e RUN_BRIDGE=1 -e ENABLE_VNC=0 \
      -e RESET_WINEPREFIX=0 -e INSTALL_MT5=0 \
      -e BOOTSTRAP_PYTHON=0 -e DEPLOY_MQL5=0 -e CONFIGURE_NT5=0 \
      -e VNC_PASSWORD=testpass \
      -e MT5_LIFECYCLE_SCRIPT=/smoke/stay.sh \
      -e BRIDGE_LIFECYCLE_SCRIPT=/scripts/start_bridge.sh \
      -e BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-2}" \
      -e BRIDGE_PROCESS_POLL_SECONDS=1 \
      -e BRIDGE_MT5_PROCESS_STABLE_SECONDS=1 \
      -e PATH="/smoke/bin:/command:/opt/wine-stable/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      -e FAKE_NAME=metatrader \
      -v "${SMOKE}:/smoke" \
      -v "${SCRIPT}:/scripts/start_bridge.sh:ro" \
      -v "${SMOKE}/noop.sh:/scripts/wine_bootstrap.sh:ro" \
      -v "${SMOKE}/noop.sh:/scripts/install_mt5.sh:ro" \
      -v "${SMOKE}/noop.sh:/scripts/deploy_mql5_oneshot.sh:ro" \
      -v "${SMOKE}/noop.sh:/scripts/configure_nt5_oneshot.sh:ro" \
      -v "${SMOKE}/noop.sh:/scripts/bootstrap_python_oneshot.sh:ro" \
      -v "${SMOKE}/stay.sh:/smoke/stay.sh:ro" \
      "$IMAGE" >/dev/null
}

start_named_terminal() {
    local kind="${1:-normal}"
    local bin
    if [ "$kind" = updater ]; then
        docker exec "$NAME" bash -c 'mkdir -p /tmp/liveupdate; cp /bin/sleep /tmp/liveupdate/terminal64.exe'
        bin=/tmp/liveupdate/terminal64.exe
    else
        docker exec "$NAME" bash -c 'cp /bin/sleep /tmp/terminal64.exe'
        bin=/tmp/terminal64.exe
    fi
    docker exec -d "$NAME" "$bin" 3600
    local pid="" i
    for i in $(seq 1 20); do
        pid="$(docker exec "$NAME" bash -c "pgrep -f '^${bin}' | head -n1" || true)"
        if [ -n "$pid" ]; then
            echo "$pid"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

wait_bridge_up() {
    local i line
    for i in $(seq 1 90); do
        if docker exec "$NAME" bash -lc 'test -d /run/service/bridge' 2>/dev/null; then
            line="$(docker exec "$NAME" /command/s6-svstat -o up,ready /run/service/bridge 2>/dev/null || true)"
            if [ "$line" = "true false" ]; then
                echo "$line"
                return 0
            fi
        fi
        sleep 1
    done
    echo "$line"
    return 1
}

bridge_pid() {
    docker exec "$NAME" /command/s6-svstat -o pid /run/service/bridge 2>/dev/null || true
}

cleanup_temp() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "${SMOKE:-}"
}

docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image missing: ${IMAGE}"

echo "=== TEMP waiting: no terminal, wrapper stays, no wine child ==="
prepare_smoke
trap cleanup_temp EXIT
start_temp_container
READY_LINE="$(wait_bridge_up)" || fail "bridge did not come up: ${READY_LINE:-none}"
assert_eq "true false" "$READY_LINE" "bridge up,ready while waiting"
PID1="$(bridge_pid)"
[ -n "$PID1" ] && [ "$PID1" != "0" ] || fail "bridge pid missing"
sleep 3
PID2="$(bridge_pid)"
assert_eq "$PID1" "$PID2" "wrapper pid stable while waiting"
RUNNING="$(docker inspect -f '{{.State.Running}}' "$NAME")"
assert_eq "true" "$RUNNING" "container running"
EXITCODE="$(docker inspect -f '{{.State.ExitCode}}' "$NAME")"
assert_eq "0" "$EXITCODE" "no container exit while waiting"
DH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME")"
echo "docker_health=${DH}"
[ "$DH" = "healthy" ] && fail "waiting wrapper must not be Docker healthy"
if docker exec "$NAME" bash -lc 'grep -q "mt5_bridge.py" /smoke/wine_calls 2>/dev/null'; then
    fail "server must not start without a terminal"
fi
if docker exec "$NAME" bash -lc 'test -s /smoke/server.pid'; then
    fail "server pid must not exist while waiting"
fi
pass "TEMP waiting: up=true ready=false; no wine; pid stable; not healthy"
docker rm -f "$NAME" >/dev/null
rm -rf "$SMOKE"

echo "=== TEMP terminal appears: same wrapper starts fake server ==="
prepare_smoke
start_temp_container
READY_LINE="$(wait_bridge_up)" || fail "bridge up before appear"
PID_BEFORE="$(bridge_pid)"
sleep 1
if docker exec "$NAME" bash -lc 'grep -q "mt5_bridge.py" /smoke/wine_calls 2>/dev/null'; then
    fail "wine before terminal appear"
fi
NAMED_PID="$(start_named_terminal)"
[ -n "$NAMED_PID" ] || fail "named terminal pid missing"
docker exec "$NAME" bash -c "kill -0 ${NAMED_PID}" || fail "named terminal not alive"
CMDLINE="$(docker exec "$NAME" bash -c "tr '\\0' ' ' < /proc/${NAMED_PID}/cmdline")"
echo "$CMDLINE" | grep -qi 'terminal64.exe' || fail "named cmdline missing terminal64.exe: ${CMDLINE}"
# Fake normal terminal is now visible in /proc; give the gate time to stabilize.
for i in $(seq 1 20); do
    if docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' 2>/dev/null; then
        break
    fi
    sleep 0.5
done
docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' || fail "server did not start after terminal appear"
PID_AFTER="$(bridge_pid)"
assert_eq "$PID_BEFORE" "$PID_AFTER" "wrapper pid unchanged after appear"
WINE_CALLS="$(docker exec "$NAME" bash -c 'cat /smoke/wine_calls' 2>/dev/null || true)"
echo "$WINE_CALLS" | grep -Fq 'python mt5_bridge.py' || fail "expected wine python mt5_bridge.py"
pass "TEMP terminal appears: stable then server; same wrapper; no probe"
docker rm -f "$NAME" >/dev/null
rm -rf "$SMOKE"

echo "=== TEMP updater then normal relaunch ==="
prepare_smoke
start_temp_container
READY_LINE="$(wait_bridge_up)" || fail "bridge up before updater"
UPDATER_PID="$(start_named_terminal updater)"
[ -n "$UPDATER_PID" ] || fail "updater pid missing"
docker exec "$NAME" bash -c "kill -0 ${UPDATER_PID}" || fail "updater not alive"
UCMD="$(docker exec "$NAME" bash -c "tr '\\0' ' ' < /proc/${UPDATER_PID}/cmdline")"
echo "$UCMD" | grep -qi 'terminal64.exe' || fail "updater cmdline missing terminal64.exe: ${UCMD}"
echo "$UCMD" | grep -qi 'liveupdate' || fail "updater cmdline missing liveupdate: ${UCMD}"
sleep 2
if docker exec "$NAME" bash -c 'grep -q "mt5_bridge.py" /smoke/wine_calls 2>/dev/null'; then
    fail "updater-only must not start server"
fi
docker exec "$NAME" bash -lc "kill -TERM ${UPDATER_PID} 2>/dev/null || true"
start_named_terminal >/dev/null
for i in $(seq 1 20); do
    if docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' 2>/dev/null; then
        break
    fi
    sleep 0.5
done
docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' || fail "server did not start after normal relaunch"
WINE_CALLS="$(docker exec "$NAME" bash -c 'cat /smoke/wine_calls' 2>/dev/null || true)"
echo "$WINE_CALLS" | grep -Fq 'python mt5_bridge.py' || fail "relaunch must start server"
pass "TEMP updater rejected then normal relaunch starts server"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
