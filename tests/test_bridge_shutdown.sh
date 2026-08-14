#!/bin/bash
# Deterministic shutdown-ownership tests for start_bridge.sh (s6 longrun-owned).
#
# Data flow: sources production start_bridge.sh; fake wine plus real sleep
# children cover probe/server TERM and spawn-registration race. Limitations:
# no Wine/broker; no s6-supervise (bridge finish coverage is in test_bridge_s6).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/images/mt5-headless/scripts/start_bridge.sh"
ENTRYPOINT="${ROOT}/images/mt5-headless/entrypoint.sh"

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

# shellcheck source=../images/mt5-headless/scripts/start_bridge.sh
source "$SCRIPT"

setup_runtime() {
    CASE_DIR="$(mktemp -d /tmp/bridge-shutdown.XXXXXX)"
    FAKE_BIN="${CASE_DIR}/bin"
    PYLIB="${CASE_DIR}/pylib"
    BRIDGE_DIR="${CASE_DIR}/bridge"
    mkdir -p "$FAKE_BIN" "$PYLIB" "$BRIDGE_DIR"

    cat >"${PYLIB}/MetaTrader5.py" <<'EOF'
import os
import time

_DELAY = float(os.environ.get("MT5_FAKE_DELAY", "0"))
_MODE = os.environ.get("MT5_FAKE_MODE", "ready")


class _Info:
    def __init__(self, connected: bool) -> None:
        self.connected = connected


def initialize() -> bool:
    if _DELAY > 0:
        time.sleep(_DELAY)
    return _MODE != "init_false"


def terminal_info():
    if _MODE == "init_false":
        raise AssertionError("terminal_info must not run")
    return _Info(True)


def shutdown() -> None:
    return None
EOF

    cat >"${FAKE_BIN}/wine" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" != "python" ]; then
    exit 97
fi
shift
export PYTHONPATH="${PYLIB:?}${PYTHONPATH:+:${PYTHONPATH}}"
if [ "${1:-}" = "-" ]; then
    count=0
    if [ -f "${PROBE_COUNT:?}" ]; then
        count="$(cat "$PROBE_COUNT")"
    fi
    count=$((count + 1))
    echo "$count" >"$PROBE_COUNT"
    if [ "${STAY_PROBE:-0}" = "1" ]; then
        echo $$ >"${PROBE_PID_FILE:?}"
        exec sleep 300
    fi
    shift
    exec python3 - "$@"
fi
count=0
if [ -f "${BRIDGE_COUNT:?}" ]; then
    count="$(cat "$BRIDGE_COUNT")"
fi
count=$((count + 1))
echo "$count" >"$BRIDGE_COUNT"
echo $$ >"${SERVER_PID_FILE:?}"
exec python3 "$@"
EOF
    chmod +x "${FAKE_BIN}/wine"

    cat >"${BRIDGE_DIR}/mt5_bridge.py" <<'EOF'
import os
import signal
import sys
import time

mode = os.environ.get("BRIDGE_CHILD_MODE", "exit42")
if mode == "stay":
    def _on_term(_signum, _frame):
        sys.exit(0)
    signal.signal(signal.SIGTERM, _on_term)
    while True:
        time.sleep(1)
if mode == "stubborn":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    time.sleep(30)
    sys.exit(99)
raise SystemExit(int(os.environ.get("BRIDGE_EXIT", "42")))
EOF

    echo 0 >"${CASE_DIR}/probe_count"
    echo 0 >"${CASE_DIR}/bridge_count"
    : >"${CASE_DIR}/probe.pid"
    : >"${CASE_DIR}/server.pid"
}

run_wrapper_bg() {
    PATH="${FAKE_BIN}:${PATH}" \
    PYLIB="$PYLIB" \
    BRIDGE_DIR="$BRIDGE_DIR" \
    PROBE_COUNT="${CASE_DIR}/probe_count" \
    BRIDGE_COUNT="${CASE_DIR}/bridge_count" \
    PROBE_PID_FILE="${CASE_DIR}/probe.pid" \
    SERVER_PID_FILE="${CASE_DIR}/server.pid" \
    STAY_PROBE="${STAY_PROBE:-0}" \
    BRIDGE_CHILD_MODE="${BRIDGE_CHILD_MODE:-stay}" \
    BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-30}" \
    BRIDGE_RETRY_SECONDS="${BRIDGE_RETRY_SECONDS:-5}" \
    BRIDGE_SHUTDOWN_TIMEOUT_SECONDS="${BRIDGE_SHUTDOWN_TIMEOUT_SECONDS:-8}" \
    BRIDGE_SHUTDOWN_POLL_SECONDS="${BRIDGE_SHUTDOWN_POLL_SECONDS:-1}" \
    MT5_FAKE_MODE="${MT5_FAKE_MODE:-ready}" \
    WINEPREFIX=/tmp/bridge-wine \
    WINEDEBUG=-all \
    RPYC_PORT=18812 \
    bash "$SCRIPT" >"${CASE_DIR}/wrapper.log" 2>&1 &
    WRAPPER_PID=$!
}

wait_for_log() {
    local pattern="$1"
    local i
    for i in $(seq 1 50); do
        if grep -q "$pattern" "${CASE_DIR}/wrapper.log" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

echo "=== test 1: TERM during readiness probe ==="
setup_runtime
STAY_PROBE=1
BRIDGE_WAIT_SECONDS=60
run_wrapper_bg
wait_for_log "state=WAITING_FOR_MT5" || fail "waiting log"
for _i in $(seq 1 50); do
    if [ -s "${CASE_DIR}/probe.pid" ] && kill -0 "$(cat "${CASE_DIR}/probe.pid")" 2>/dev/null; then
        break
    fi
    sleep 0.1
done
PROBE_PID="$(cat "${CASE_DIR}/probe.pid")"
[ -n "$PROBE_PID" ] || fail "probe pid missing"
kill -TERM "$WRAPPER_PID"
set +e
wait "$WRAPPER_PID"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "wrapper TERM during probe exit0"
grep -q "child_kind=probe" "${CASE_DIR}/wrapper.log" || fail "child_kind=probe"
grep -q "shutdown_result=completed" "${CASE_DIR}/wrapper.log" || fail "probe completed"
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "final bridge must not start"
if kill -0 "$PROBE_PID" 2>/dev/null; then
    kill -KILL "$PROBE_PID" 2>/dev/null || true
    fail "probe child must receive TERM"
fi
pass "TERM during probe stops child and skips server"
rm -rf "$CASE_DIR"

echo "=== test 2: TERM during final server ==="
setup_runtime
STAY_PROBE=0
BRIDGE_CHILD_MODE=stay
run_wrapper_bg
wait_for_log "state=RUNNING child_pid=" || fail "running log"
SERVER_PID="$(cat "${CASE_DIR}/server.pid")"
[ -n "$SERVER_PID" ] || fail "server pid missing"
kill -0 "$SERVER_PID" || fail "server not alive"
kill -TERM "$WRAPPER_PID"
set +e
wait "$WRAPPER_PID"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "wrapper TERM during server exit0"
grep -q "child_kind=server" "${CASE_DIR}/wrapper.log" || fail "child_kind=server"
grep -q "shutdown_result=completed" "${CASE_DIR}/wrapper.log" || fail "server completed"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "server invoked once"
if kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -KILL "$SERVER_PID" 2>/dev/null || true
    fail "server child must receive TERM"
fi
pass "TERM during server TERMs child once and wrapper exits 0"
rm -rf "$CASE_DIR"

echo "=== test 3: INT normalizes to child TERM ==="
# Background bash ignores SIGINT; invoke the production handler directly.
sleep 300 &
INT_CHILD=$!
CURRENT_BRIDGE_CHILD_PID="$INT_CHILD"
CURRENT_BRIDGE_CHILD_KIND="server"
SHUTDOWN_IN_PROGRESS=0
STOP_REQUESTED=0
BRIDGE_SHUTDOWN_TIMEOUT_SECONDS=8
BRIDGE_SHUTDOWN_POLL_SECONDS=1
set +e
OUTPUT="$(on_term INT 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "INT handler exit0"
echo "$OUTPUT" | grep -q "source_signal=INT child_signal=TERM" || fail "INT→TERM"
echo "$OUTPUT" | grep -q "child_signal=INT" && fail "must not send INT to child"
echo "$OUTPUT" | grep -q "shutdown_result=completed" || fail "INT completed"
if kill -0 "$INT_CHILD" 2>/dev/null; then
    kill -KILL "$INT_CHILD" 2>/dev/null || true
    fail "INT path must TERM the child"
fi
CURRENT_BRIDGE_CHILD_PID=""
CURRENT_BRIDGE_CHILD_KIND=""
SHUTDOWN_IN_PROGRESS=0
pass "INT source still TERMs child"
rm -rf "${CASE_DIR:-}"

echo "=== test 4: stubborn child fallback without SIGKILL ==="
setup_runtime
BRIDGE_CHILD_MODE=stubborn
BRIDGE_SHUTDOWN_TIMEOUT_SECONDS=2
BRIDGE_SHUTDOWN_POLL_SECONDS=1
run_wrapper_bg
wait_for_log "state=RUNNING child_pid=" || fail "running stubborn"
SERVER_PID="$(cat "${CASE_DIR}/server.pid")"
kill -TERM "$WRAPPER_PID"
set +e
wait "$WRAPPER_PID"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "stubborn wrapper still exit0"
grep -q "shutdown_result=fallback_required reason=timeout" "${CASE_DIR}/wrapper.log" || fail "fallback_required"
BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$SCRIPT")"
echo "$BODY" | grep -Fq 'kill -KILL' && fail "wrapper must not SIGKILL"
kill -KILL "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
pass "stubborn child yields fallback_required without SIGKILL"
rm -rf "$CASE_DIR"

echo "=== test 5: child already dead is nonfatal ==="
DEAD_PID=""
sleep 0.01 &
DEAD_PID=$!
wait "$DEAD_PID" || true
CURRENT_BRIDGE_CHILD_PID="$DEAD_PID"
CURRENT_BRIDGE_CHILD_KIND="server"
SHUTDOWN_IN_PROGRESS=0
STOP_REQUESTED=0
set +e
OUTPUT="$(on_term TERM 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "dead child handler exit0"
echo "$OUTPUT" | grep -q "shutdown_result=completed" || fail "dead child completed"
pass "already-dead child does not fatal the handler"
CURRENT_BRIDGE_CHILD_PID=""
CURRENT_BRIDGE_CHILD_KIND=""
SHUTDOWN_IN_PROGRESS=0

echo "=== test 6: zombie is inactive ==="
python3 - <<'PY' &
import os, time
pid = os.fork()
if pid == 0:
    os._exit(0)
open("/tmp/mt5-bridge-zombie-pid", "w").write(str(pid))
time.sleep(8)
PY
ZOMBIE_PARENT=$!
ZOMBIE_PID=""
for _i in $(seq 1 30); do
    if [ -f /tmp/mt5-bridge-zombie-pid ]; then
        ZOMBIE_PID="$(cat /tmp/mt5-bridge-zombie-pid)"
        break
    fi
    sleep 0.1
done
[ -n "$ZOMBIE_PID" ] || fail "zombie pid not created"
STATE="$(awk '/^State:/ { print $2 }' "/proc/${ZOMBIE_PID}/status" 2>/dev/null || true)"
assert_eq "Z" "$STATE" "proc state is zombie"
process_is_active "$ZOMBIE_PID" && fail "zombie must be inactive" || pass "zombie classified inactive"
TESTS_RUN=$((TESTS_RUN + 1))
kill -TERM "$ZOMBIE_PARENT" 2>/dev/null || true
wait "$ZOMBIE_PARENT" 2>/dev/null || true
rm -f /tmp/mt5-bridge-zombie-pid

echo "=== test 7: crash exit42 count1 no restart ==="
setup_runtime
BRIDGE_CHILD_MODE=exit42
BRIDGE_WAIT_SECONDS=0
set +e
PATH="${FAKE_BIN}:${PATH}" \
PYLIB="$PYLIB" \
BRIDGE_DIR="$BRIDGE_DIR" \
PROBE_COUNT="${CASE_DIR}/probe_count" \
BRIDGE_COUNT="${CASE_DIR}/bridge_count" \
PROBE_PID_FILE="${CASE_DIR}/probe.pid" \
SERVER_PID_FILE="${CASE_DIR}/server.pid" \
STAY_PROBE=0 \
BRIDGE_WAIT_SECONDS=0 \
WINEPREFIX=/tmp/bridge-wine \
bash "$SCRIPT" >"${CASE_DIR}/wrapper.log" 2>&1
STATUS=$?
set -e
assert_eq "42" "$STATUS" "crash passthrough"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "one server"
sleep 0.2
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "still one after delay"
grep -q "state=BRIDGE_EXIT code=42" "${CASE_DIR}/wrapper.log" || fail "BRIDGE_EXIT 42"
pass "final crash remains one-shot exit42"
rm -rf "$CASE_DIR"

echo "=== test 8: CMD no longer owns bridge shutdown ==="
grep -Fq 'BRIDGE_PID' "$ENTRYPOINT" && fail "BRIDGE_PID must be gone"
grep -Fq 'cmd_wait_bridge_wrapper' "$ENTRYPOINT" && fail "cmd_wait_bridge_wrapper must be gone"
grep -Fq 'targeting bridge lifecycle wrapper' "$ENTRYPOINT" && fail "CMD must not target wrapper"
grep -Fq '/scripts/start_bridge.sh &' "$ENTRYPOINT" && fail "CMD must not spawn bridge"
# shellcheck source=../images/mt5-headless/entrypoint.sh
source "$ENTRYPOINT"
set +e
OUTPUT="$(cmd_on_term 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "simple CMD TERM"
echo "$OUTPUT" | grep -q "CMD: shutdown signal received." || fail "CMD TERM log"
echo "$OUTPUT" | grep -q "targeting bridge" && fail "must not target bridge"
TESTS_RUN=$((TESTS_RUN + 4))
pass "CMD TERM is bridge-agnostic"

echo "=== test 9: static no SIGKILL/pg/wineserver-k in wrapper ==="
BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$SCRIPT")"
echo "$BODY" | grep -Fq 'wineserver -k' && fail "wrapper wineserver-k"
echo "$BODY" | grep -Fq 'kill -KILL' && fail "wrapper SIGKILL"
echo "$BODY" | grep -Eq 'pkill|wineboot' && fail "wrapper pkill/wineboot"
echo "$BODY" | grep -Eq 'kill -TERM -- -|kill -- -' && fail "wrapper process-group"
grep -Fq 'wineserver -k || true' "$ENTRYPOINT" || fail "global fallback preserved"
TESTS_RUN=$((TESTS_RUN + 5))
pass "wrapper has no SIGKILL/pg/wineserver-k; CMD fallback remains"

echo "=== test 10: deterministic spawn→PID registration race ==="
setup_runtime
BRIDGE_WAIT_SECONDS=0
BRIDGE_CHILD_MODE=stay
cat >"${CASE_DIR}/race_hook.sh" <<EOF
bridge_after_spawn_before_register() {
    local pid="\$1"
    local kind="\$2"
    echo "\${pid}" >"${CASE_DIR}/spawned.pid"
    echo "\${kind}" >"${CASE_DIR}/spawned.kind"
    echo "\${SPAWN_IN_PROGRESS}" >"${CASE_DIR}/spawn_flag"
    local i
    for i in \$(seq 1 100); do
        if grep -q "state=STOP_DEFERRED" "${CASE_DIR}/wrapper.log" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
}
EOF
# shellcheck disable=SC1090
source "${CASE_DIR}/race_hook.sh"
PATH="${FAKE_BIN}:${PATH}" \
PYLIB="$PYLIB" \
BRIDGE_DIR="$BRIDGE_DIR" \
PROBE_COUNT="${CASE_DIR}/probe_count" \
BRIDGE_COUNT="${CASE_DIR}/bridge_count" \
PROBE_PID_FILE="${CASE_DIR}/probe.pid" \
SERVER_PID_FILE="${CASE_DIR}/server.pid" \
STAY_PROBE=0 \
BRIDGE_CHILD_MODE=stay \
BRIDGE_WAIT_SECONDS=0 \
BRIDGE_SHUTDOWN_TIMEOUT_SECONDS=8 \
WINEPREFIX=/tmp/bridge-wine \
WINEDEBUG=-all \
RPYC_PORT=18812 \
stdbuf -oL -eL bash -c '
set -Eeuo pipefail
# shellcheck source=/dev/null
source "'"$SCRIPT"'"
# shellcheck source=/dev/null
source "'"${CASE_DIR}/race_hook.sh"'"
main
' >"${CASE_DIR}/wrapper.log" 2>&1 &
WRAPPER_PID=$!
for _i in $(seq 1 100); do
    if [ -s "${CASE_DIR}/spawned.pid" ]; then
        break
    fi
    sleep 0.05
done
test -s "${CASE_DIR}/spawned.pid" || fail "child must be spawned before register"
assert_eq "1" "$(cat "${CASE_DIR}/spawn_flag")" "SPAWN_IN_PROGRESS still set"
CHILD_PID="$(cat "${CASE_DIR}/spawned.pid")"
# Give the hook a moment to enter its STOP_DEFERRED wait loop.
sleep 0.1
kill -TERM "$WRAPPER_PID"
for _i in $(seq 1 100); do
    if grep -q "state=STOP_DEFERRED" "${CASE_DIR}/wrapper.log" 2>/dev/null; then
        break
    fi
    sleep 0.05
done
grep -q "state=STOP_DEFERRED reason=spawn_in_progress" "${CASE_DIR}/wrapper.log" || fail "STOP_DEFERRED missing"
wait "$WRAPPER_PID" 2>/dev/null || true
grep -q "state=STOPPING" "${CASE_DIR}/wrapper.log" || fail "STOPPING after register missing"
grep -q "shutdown_result=completed" "${CASE_DIR}/wrapper.log" || fail "shutdown completed missing"
if kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -KILL "$CHILD_PID" 2>/dev/null || true
    fail "child must not remain orphan"
fi
TESTS_RUN=$((TESTS_RUN + 3))
pass "TERM during spawn defers, registers PID, TERMs child, no orphan"
rm -rf "$CASE_DIR"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
