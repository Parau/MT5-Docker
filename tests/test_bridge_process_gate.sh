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
# shellcheck source=lib/proc_stat_fixture.sh
source "${ROOT}/tests/lib/proc_stat_fixture.sh"

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
    mkdir -p "${SMOKE}/proc" "${SMOKE}/bins"
    : >"${SMOKE}/bins/wine64-preloader"
    : >"${SMOKE}/bins/bash"
    chmod +x "${SMOKE}/noop.sh" "${SMOKE}/stay.sh" "${SMOKE}/hold.sh" "${SMOKE}/bin/wine"
}

write_smoke_mt5() {
    local pid="$1"
    local starttime="$2"
    local kind="$3"
    shift 3
    local dir="${SMOKE}/proc/${pid}"
    mkdir -p "$dir"
    local arg comm="main" exe_base="wine64-preloader"
    : >"${dir}/cmdline"
    for arg in "$@"; do
        printf '%s\0' "$arg" >>"${dir}/cmdline"
    done
    case "$kind" in
        helper_bash) comm="bash"; exe_base="bash" ;;
        updater) comm="main"; exe_base="wine64-preloader" ;;
    esac
    printf 'State:\tR\n' >"${dir}/status"
    printf '%s\n' "$comm" >"${dir}/comm"
    write_linux_proc_stat "${dir}/stat" "$pid" "$comm" S "$starttime"
    ln -sfn "/smoke/bins/${exe_base}" "${dir}/exe"
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
      -e BRIDGE_MT5_PROCESS_STABLE_SECONDS="${BRIDGE_MT5_PROCESS_STABLE_SECONDS:-1}" \
      -e BRIDGE_PROC_ROOT=/smoke/proc \
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

wait_for_container_log() {
    local pattern="$1"
    local i
    for i in $(seq 1 40); do
        if docker logs "$NAME" 2>&1 | grep -q "$pattern"; then
            return 0
        fi
        sleep 0.25
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
write_smoke_mt5 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
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

echo "=== TEMP identity change before window completes ==="
prepare_smoke
BRIDGE_MT5_PROCESS_STABLE_SECONDS=3
BRIDGE_WAIT_SECONDS=30
start_temp_container
READY_LINE="$(wait_bridge_up)" || fail "bridge up before identity change"
write_smoke_mt5 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
wait_for_container_log "candidate_pid=100" || fail "selected PID100"
sleep 0.8
rm -rf "${SMOKE}/proc/100"
write_smoke_mt5 200 2000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
wait_for_container_log "candidate_pid=200" || fail "identity reset to PID200"
sleep 1.2
if docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' 2>/dev/null; then
    fail "server must not start on inherited stability"
fi
for i in $(seq 1 20); do
    if docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' 2>/dev/null; then
        break
    fi
    sleep 0.5
done
docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' || fail "server after PID200 window"
docker logs "$NAME" 2>&1 | grep -q "candidate_identity_changed=1" || fail "identity change logged"
pass "TEMP identity change: reset; server only after new window"
docker rm -f "$NAME" >/dev/null
rm -rf "$SMOKE"
unset BRIDGE_MT5_PROCESS_STABLE_SECONDS BRIDGE_WAIT_SECONDS

echo "=== TEMP verified normal + updater then relaunch ==="
prepare_smoke
BRIDGE_MT5_PROCESS_STABLE_SECONDS=2
BRIDGE_WAIT_SECONDS=30
start_temp_container
READY_LINE="$(wait_bridge_up)" || fail "bridge up before updater"
write_smoke_mt5 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
write_smoke_mt5 200 1000 updater "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/update"
wait_for_container_log "reason=updater_active" || fail "updater blocks"
sleep 2.2
if docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' 2>/dev/null; then
    fail "normal+updater must not start server"
fi
rm -rf "${SMOKE}/proc/200"
sleep 1.0
if docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' 2>/dev/null; then
    fail "must not reuse time from before updater removal"
fi
for i in $(seq 1 20); do
    if docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' 2>/dev/null; then
        break
    fi
    sleep 0.5
done
docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' || fail "server after fresh window"
pass "TEMP updater coexistence blocked; fresh window after removal"
docker rm -f "$NAME" >/dev/null
rm -rf "$SMOKE"
unset BRIDGE_MT5_PROCESS_STABLE_SECONDS BRIDGE_WAIT_SECONDS

echo "=== TEMP false bash helper then verified normal ==="
prepare_smoke
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
BRIDGE_WAIT_SECONDS=30
start_temp_container
READY_LINE="$(wait_bridge_up)" || fail "bridge up before helper"
write_smoke_mt5 300 1000 helper_bash "bash" "-c" "terminal64.exe /portable"
sleep 2.2
if docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' 2>/dev/null; then
    fail "bash helper must not start server"
fi
write_smoke_mt5 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
for i in $(seq 1 20); do
    if docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' 2>/dev/null; then
        break
    fi
    sleep 0.5
done
docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' || fail "verified normal must start server"
pass "TEMP false helper rejected; verified normal admits after window"
docker rm -f "$NAME" >/dev/null
rm -rf "$SMOKE"

echo "=== TEMP same PID new starttime resets identity ==="
prepare_smoke
BRIDGE_MT5_PROCESS_STABLE_SECONDS=4
BRIDGE_WAIT_SECONDS=30
start_temp_container
READY_LINE="$(wait_bridge_up)" || fail "bridge up before starttime rewrite"
write_smoke_mt5 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
assert_eq "1000" "$(independent_stat_field "${SMOKE}/proc/100/stat" 22)" "TEMP field22=1000"
wait_for_container_log "candidate_pid=100" || fail "selected PID100"
t0="$(date +%s)"
sleep 2
write_smoke_mt5 100 2000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
assert_eq "2000" "$(independent_stat_field "${SMOKE}/proc/100/stat" 22)" "TEMP rewritten field22=2000"
for i in $(seq 1 40); do
    n="$(docker logs "$NAME" 2>&1 | grep -c "candidate_identity_changed=1" || true)"
    if [ "${n:-0}" -ge 2 ]; then
        break
    fi
    sleep 0.25
done
n="$(docker logs "$NAME" 2>&1 | grep -c "candidate_identity_changed=1" || true)"
[ "${n:-0}" -ge 2 ] || fail "TEMP expected second identity change, got ${n:-0}"
now="$(date +%s)"
remain=$((t0 + 5 - now))
if [ "$remain" -gt 0 ]; then
    sleep "$remain"
fi
if docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' 2>/dev/null; then
    fail "server must not start at old inherited deadline"
fi
for i in $(seq 1 40); do
    if docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' 2>/dev/null; then
        break
    fi
    sleep 0.5
done
docker exec "$NAME" bash -lc 'test -s /smoke/server.pid' || fail "server after new starttime window"
pass "TEMP same PID new starttime: no launch at old deadline; server after new window"
docker rm -f "$NAME" >/dev/null
rm -rf "$SMOKE"
unset BRIDGE_MT5_PROCESS_STABLE_SECONDS BRIDGE_WAIT_SECONDS

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
