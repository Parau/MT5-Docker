#!/bin/bash
# Deterministic contract tests for mt5_lifecycle.sh liveness, exits, and shutdown.
#
# Data flow: sources production lifecycle (or runs it as $0); fake wine + function
# seams cover main/spawn/signals without real Wine. Limitations: no Docker/broker
# in this suite; TERM child-ownership is demonstrated with a fake sleep child.
# Does not replace tests/test_mt5_lifecycle.sh (handoff classifiers/scenarios).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/images/mt5-headless/scripts/mt5_lifecycle.sh"
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

executable_body() {
    awk 'NR==1{next} /^#/{next} {print}' "$1"
}

echo "=== test 1: defaults ==="
DEFAULTS_OUT="$(
    env -u MT5_EXE -u MT5_CMD_OPTIONS \
        -u MT5_HANDOFF_GRACE_SECONDS -u MT5_UPDATE_TIMEOUT_SECONDS \
        -u MT5_RELAUNCH_STABLE_SECONDS -u MT5_POLL_SECONDS \
        WINEPREFIX=/tmp/contract-wineprefix \
        bash -c '
            set -Eeuo pipefail
            # shellcheck source=../images/mt5-headless/scripts/mt5_lifecycle.sh
            source "$1"
            printf "grace=%s\n" "$MT5_HANDOFF_GRACE_SECONDS"
            printf "update=%s\n" "$MT5_UPDATE_TIMEOUT_SECONDS"
            printf "stable=%s\n" "$MT5_RELAUNCH_STABLE_SECONDS"
            printf "poll=%s\n" "$MT5_POLL_SECONDS"
            printf "opts=%s\n" "$MT5_CMD_OPTIONS"
            printf "exe=%s\n" "$MT5_EXE"
        ' bash "$SCRIPT"
)"
echo "$DEFAULTS_OUT" | grep -qx "grace=8" || fail "default grace"
echo "$DEFAULTS_OUT" | grep -qx "update=180" || fail "default update timeout"
echo "$DEFAULTS_OUT" | grep -qx "stable=5" || fail "default stable"
echo "$DEFAULTS_OUT" | grep -qx "poll=1" || fail "default poll"
echo "$DEFAULTS_OUT" | grep -qx "opts=" || fail "default empty MT5_CMD_OPTIONS"
echo "$DEFAULTS_OUT" | grep -Fq "/tmp/contract-wineprefix/drive_c/Program Files/MetaTrader 5/terminal64.exe" || fail "default MT5_EXE under WINEPREFIX"
TESTS_RUN=$((TESTS_RUN + 6))
pass "defaults frozen"
# shellcheck source=../images/mt5-headless/scripts/mt5_lifecycle.sh
source "$SCRIPT"
RESTORE_handle_handoff="$(declare -f handle_handoff)"
RESTORE_monitor="$(declare -f monitor_running_relaunched)"
RESTORE_scan="$(declare -f scan_process_candidates)"
RESTORE_sleep="$(declare -f lifecycle_sleep)"

restore_lifecycle_functions() {
    eval "$RESTORE_handle_handoff"
    eval "$RESTORE_monitor"
    eval "$RESTORE_scan"
    eval "$RESTORE_sleep"
}

echo "=== test 2: exit constants ==="
assert_eq "70" "$EXIT_UPDATE_TIMEOUT" "EXIT_UPDATE_TIMEOUT"
assert_eq "71" "$EXIT_RELAUNCH_NOT_OBSERVED" "EXIT_RELAUNCH_NOT_OBSERVED"
assert_eq "72" "$EXIT_CLASSIFICATION_INCONSISTENT" "EXIT_CLASSIFICATION_INCONSISTENT"
assert_eq "73" "$EXIT_TERMINAL_DISAPPEARED" "EXIT_TERMINAL_DISAPPEARED"
assert_eq "74" "$EXIT_UNEXPECTED_EXIT" "EXIT_UNEXPECTED_EXIT"
pass "exit constants 70-74 frozen"

echo "=== test 3: source guard ==="
CASE_DIR="$(mktemp -d /tmp/mt5-lifecycle-contract.XXXXXX)"
FAKE_BIN="${CASE_DIR}/bin"
mkdir -p "$FAKE_BIN"
cat >"${FAKE_BIN}/wine" <<'EOF'
#!/bin/bash
echo wine-called >>"${WINE_MARKER:?}"
exit 0
EOF
chmod +x "${FAKE_BIN}/wine"
WINE_MARKER="${CASE_DIR}/wine.marker"
: >"$WINE_MARKER"
PATH="${FAKE_BIN}:${PATH}" WINE_MARKER="$WINE_MARKER" bash -c '
    set -Eeuo pipefail
    source "$1"
' bash "$SCRIPT"
if [ -s "$WINE_MARKER" ]; then
    fail "source must not invoke wine/main"
fi
TESTS_RUN=$((TESTS_RUN + 1))
pass "source does not execute main"
rm -rf "$CASE_DIR"

echo "=== test 4: MT5_EXE missing ==="
CASE_DIR="$(mktemp -d /tmp/mt5-lifecycle-contract.XXXXXX)"
FAKE_BIN="${CASE_DIR}/bin"
mkdir -p "$FAKE_BIN"
cat >"${FAKE_BIN}/wine" <<'EOF'
#!/bin/bash
echo wine-called >>"${WINE_MARKER:?}"
exit 0
EOF
chmod +x "${FAKE_BIN}/wine"
export WINE_MARKER="${CASE_DIR}/wine.marker"
: >"$WINE_MARKER"
export PATH="${FAKE_BIN}:${PATH}"
export MT5_EXE="${CASE_DIR}/missing-terminal64.exe"
set +e
OUTPUT="$(main 2>&1)"
STATUS=$?
set -e
assert_eq "1" "$STATUS" "missing exe exit"
echo "$OUTPUT" | grep -q "state=FAILED reason=mt5_exe_missing" || fail "missing exe log"
if [ -s "$WINE_MARKER" ]; then
    fail "wine must not run when MT5_EXE missing"
fi
TESTS_RUN=$((TESTS_RUN + 1))
pass "MT5_EXE missing is exit 1 without wine"
rm -rf "$CASE_DIR"
unset WINE_MARKER || true

echo "=== test 5: spawn + state order ==="
CASE_DIR="$(mktemp -d /tmp/mt5-lifecycle-contract.XXXXXX)"
FAKE_BIN="${CASE_DIR}/bin"
mkdir -p "$FAKE_BIN" "${CASE_DIR}/mt5"
printf 'fake-exe\n' >"${CASE_DIR}/mt5/terminal64.exe"
cat >"${FAKE_BIN}/wine" <<'EOF'
#!/bin/bash
echo "wine $*" >>"${WINE_LOG:?}"
exit 0
EOF
chmod +x "${FAKE_BIN}/wine"
export PATH="${FAKE_BIN}:${PATH}"
export WINE_LOG="${CASE_DIR}/wine.log"
: >"$WINE_LOG"
export MT5_EXE="${CASE_DIR}/mt5/terminal64.exe"
export MT5_CMD_OPTIONS=""
handle_handoff() {
    echo "handoff child_status=${1:-} reason=${2:-}" >>"${HANDOFF_LOG:?}"
    return 74
}
export HANDOFF_LOG="${CASE_DIR}/handoff.log"
: >"$HANDOFF_LOG"
MT5_HANDOFF_GRACE_SECONDS=0
set +e
OUTPUT="$(main 2>&1)"
STATUS=$?
set -e
assert_eq "74" "$STATUS" "spawn path final exit"
python3 - <<PY || fail "state order"
from pathlib import Path
text = """${OUTPUT}"""
i_start = text.find("state=STARTING")
i_run = text.find("state=RUNNING")
i_child = text.find("child_exit code=0")
if not (0 <= i_start < i_run < i_child):
    raise SystemExit(f"bad order start={i_start} run={i_run} child={i_child}")
PY
grep -q "handoff child_status=0 reason=child_exit" "$HANDOFF_LOG" || fail "handoff args"
TESTS_RUN=$((TESTS_RUN + 2))
pass "STARTING then RUNNING then child_exit; handoff gets child_exit 0"
restore_lifecycle_functions
rm -rf "$CASE_DIR"

echo "=== test 6: MT5_CMD_OPTIONS passed to wine ==="
CASE_DIR="$(mktemp -d /tmp/mt5-lifecycle-contract.XXXXXX)"
FAKE_BIN="${CASE_DIR}/bin"
mkdir -p "$FAKE_BIN" "${CASE_DIR}/mt5"
printf 'fake-exe\n' >"${CASE_DIR}/mt5/terminal64.exe"
cat >"${FAKE_BIN}/wine" <<'EOF'
#!/bin/bash
echo "wine $*" >>"${WINE_LOG:?}"
exit 0
EOF
chmod +x "${FAKE_BIN}/wine"
export PATH="${FAKE_BIN}:${PATH}"
export WINE_LOG="${CASE_DIR}/wine.log"
: >"$WINE_LOG"
export MT5_EXE="${CASE_DIR}/mt5/terminal64.exe"
export MT5_CMD_OPTIONS="/portable /test-option"
handle_handoff() { return 74; }
set +e
(main) >/dev/null 2>&1
set -e
grep -Fq "wine ${MT5_EXE} /portable /test-option" "$WINE_LOG" || fail "options not passed as currently expanded"
TESTS_RUN=$((TESTS_RUN + 1))
pass "MT5_CMD_OPTIONS forwarded to wine (current expansion)"
restore_lifecycle_functions
unset MT5_CMD_OPTIONS || true
rm -rf "$CASE_DIR"

echo "=== test 7: child 0 without update → 74 ==="
scan_process_candidates() {
    local -n _updaters="$1"
    local -n _terminals="$2"
    local -n _relaunch="$3"
    _updaters=()
    _terminals=()
    _relaunch=()
}
lifecycle_sleep() { :; }
MT5_HANDOFF_GRACE_SECONDS=0
STOP_REQUESTED=0
CURRENT_STATE="INIT"
set +e
OUTPUT="$(handle_handoff 0 "contract_test" 2>&1)"
STATUS=$?
set -e
assert_eq "74" "$STATUS" "child0 no-update exit"
echo "$OUTPUT" | grep -q "reason=no_updater_or_terminal_after_handoff" || fail "unexpected_exit reason"
TESTS_RUN=$((TESTS_RUN + 1))
pass "child 0 without update is 74"

echo "=== test 8: child nonzero passthrough ==="
STOP_REQUESTED=0
CURRENT_STATE="INIT"
set +e
OUTPUT="$(handle_handoff 42 "contract_test" 2>&1)"
STATUS=$?
set -e
assert_eq "42" "$STATUS" "child 42 passthrough"
echo "$OUTPUT" | grep -q "reason=child_nonzero_exit code=42" || fail "child_nonzero_exit log"
TESTS_RUN=$((TESTS_RUN + 1))
pass "child nonzero status is propagated"

echo "=== test 9: no crash autorestart ==="
CASE_DIR="$(mktemp -d /tmp/mt5-lifecycle-contract.XXXXXX)"
FAKE_BIN="${CASE_DIR}/bin"
mkdir -p "$FAKE_BIN" "${CASE_DIR}/mt5"
printf 'fake-exe\n' >"${CASE_DIR}/mt5/terminal64.exe"
cat >"${FAKE_BIN}/wine" <<'EOF'
#!/bin/bash
count=0
if [ -f "${WINE_COUNT:?}" ]; then
    count="$(cat "$WINE_COUNT")"
fi
count=$((count + 1))
echo "$count" >"$WINE_COUNT"
exit 42
EOF
chmod +x "${FAKE_BIN}/wine"
export PATH="${FAKE_BIN}:${PATH}"
export WINE_COUNT="${CASE_DIR}/wine.count"
echo 0 >"$WINE_COUNT"
export MT5_EXE="${CASE_DIR}/mt5/terminal64.exe"
export MT5_CMD_OPTIONS=""
MT5_HANDOFF_GRACE_SECONDS=0
set +e
(main) >/dev/null 2>&1
STATUS=$?
set -e
assert_eq "42" "$STATUS" "crash path exit"
assert_eq "1" "$(cat "$WINE_COUNT")" "wine spawn count"
pass "crash does not autorestart (one spawn)"
rm -rf "$CASE_DIR"
unset WINE_COUNT || true

echo "=== test 10: successful handoff calls monitor ==="
CASE_DIR="$(mktemp -d /tmp/mt5-lifecycle-contract.XXXXXX)"
FAKE_BIN="${CASE_DIR}/bin"
mkdir -p "$FAKE_BIN" "${CASE_DIR}/mt5"
printf 'fake-exe\n' >"${CASE_DIR}/mt5/terminal64.exe"
cat >"${FAKE_BIN}/wine" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "${FAKE_BIN}/wine"
export PATH="${FAKE_BIN}:${PATH}"
export MT5_EXE="${CASE_DIR}/mt5/terminal64.exe"
export MONITOR_MARKER="${CASE_DIR}/monitor.marker"
handle_handoff() { return 0; }
monitor_running_relaunched() {
    echo monitor-called >"${MONITOR_MARKER:?}"
    return 74
}
set +e
(main) >/dev/null 2>&1
STATUS=$?
set -e
assert_eq "74" "$STATUS" "monitor status propagated"
test -f "$MONITOR_MARKER" || fail "monitor not called after successful handoff"
TESTS_RUN=$((TESTS_RUN + 1))
pass "successful handoff enters monitor phase"
restore_lifecycle_functions
rm -rf "$CASE_DIR"
unset MONITOR_MARKER || true

echo "=== test 11: TERM handler ==="
set +e
OUTPUT="$(
    STOP_REQUESTED=0
    CURRENT_STATE="RUNNING"
    on_term TERM
    echo "on_term_returned"
)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "TERM handler exit"
echo "$OUTPUT" | grep -q "state=STOPPING signal=TERM" || fail "TERM STOPPING log"
echo "$OUTPUT" | grep -q "on_term_returned" && fail "on_term must exit"
TESTS_RUN=$((TESTS_RUN + 1))
pass "TERM stops wrapper with exit 0"

echo "=== test 12: INT handler ==="
set +e
OUTPUT="$(
    STOP_REQUESTED=0
    CURRENT_STATE="RUNNING"
    on_term INT
    echo "on_term_returned"
)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "INT handler exit"
echo "$OUTPUT" | grep -q "state=STOPPING signal=INT" || fail "INT STOPPING log"
echo "$OUTPUT" | grep -q "on_term_returned" && fail "on_term INT must exit"
TESTS_RUN=$((TESTS_RUN + 1))
pass "INT stops wrapper with exit 0"

echo "=== test 13: TERM does not forward to child ==="
CASE_DIR="$(mktemp -d /tmp/mt5-lifecycle-contract.XXXXXX)"
FAKE_BIN="${CASE_DIR}/bin"
mkdir -p "$FAKE_BIN" "${CASE_DIR}/mt5"
printf 'fake-exe\n' >"${CASE_DIR}/mt5/terminal64.exe"
cat >"${FAKE_BIN}/wine" <<'EOF'
#!/bin/bash
echo $$ >"${WINE_PID_FILE:?}"
exec sleep 300
EOF
chmod +x "${FAKE_BIN}/wine"
export WINE_PID_FILE="${CASE_DIR}/wine.pid"
export MT5_EXE="${CASE_DIR}/mt5/terminal64.exe"
export MT5_CMD_OPTIONS=""
LOG="${CASE_DIR}/lifecycle.log"
PATH="${FAKE_BIN}:${PATH}" bash "$SCRIPT" >"$LOG" 2>&1 &
LIFECYCLE_PID=$!
CHILD_PID=""
for _i in $(seq 1 50); do
    if grep -q "state=RUNNING" "$LOG" 2>/dev/null && [ -f "$WINE_PID_FILE" ]; then
        CHILD_PID="$(cat "$WINE_PID_FILE")"
        break
    fi
    sleep 0.1
done
[ -n "$CHILD_PID" ] || fail "did not observe RUNNING/child pid"
kill -0 "$CHILD_PID" 2>/dev/null || fail "fake child not alive before TERM"
# Signal only the lifecycle PID, not the process group.
kill -TERM "$LIFECYCLE_PID"
set +e
wait "$LIFECYCLE_PID"
LIFE_STATUS=$?
set -e
assert_eq "0" "$LIFE_STATUS" "lifecycle TERM exit"
grep -q "state=STOPPING signal=TERM" "$LOG" || fail "STOPPING log missing"
CHILD_ALIVE=0
if kill -0 "$CHILD_PID" 2>/dev/null; then
    CHILD_ALIVE=1
fi
if [ "$CHILD_ALIVE" -ne 1 ]; then
    echo "NOTE: fake child died after lifecycle TERM; investigating process group"
    echo "lifecycle_pid=${LIFECYCLE_PID} child_pid=${CHILD_PID}"
    fail "current contract: child must survive TERM sent only to lifecycle"
fi
TESTS_RUN=$((TESTS_RUN + 2))
echo "lifecycle_pid=${LIFECYCLE_PID} fake_child_pid=${CHILD_PID} child_survived=1"
kill -TERM "$CHILD_PID" 2>/dev/null || true
wait "$CHILD_PID" 2>/dev/null || true
kill -KILL "$CHILD_PID" 2>/dev/null || true
pass "TERM to lifecycle leaves fake Wine child alive (ownership gap frozen)"
rm -rf "$CASE_DIR"

echo "=== test 14: readiness absent from executable body ==="
BODY="$(executable_body "$SCRIPT")"
echo "$BODY" | grep -Eq 'MetaTrader5\.initialize|mt5\.initialize|terminal_info' && fail "readiness API in lifecycle body"
echo "$BODY" | grep -Eq 'RPYC_PORT|notification-fd|s6-notify' && fail "RPyC/notify in lifecycle body"
# NT5/websocket would be false positives in comments only; body already stripped of # lines.
echo "$BODY" | grep -Eq 'websocket' && fail "websocket in lifecycle body"
grep -n 'set_state "RUNNING" "child_pid=' "$SCRIPT" | grep -q 'child_pid=${child_pid}' || fail "RUNNING is set from child PID after spawn"
TESTS_RUN=$((TESTS_RUN + 2))
pass "RUNNING is process/lifecycle state only; no MT5 readiness"

echo "=== test 15: entrypoint liveness contract ==="
grep -Fq '/scripts/mt5_lifecycle.sh &' "$ENTRYPOINT" || fail "lifecycle background"
grep -Fq 'MT5_LIFECYCLE_PID=$!' "$ENTRYPOINT" || fail "lifecycle pid capture"
grep -Fq 'wait "$MT5_LIFECYCLE_PID"' "$ENTRYPOINT" || fail "wait lifecycle"
grep -Fq '/scripts/start_bridge.sh &' "$ENTRYPOINT" || fail "bridge background"
if grep -Fq 'wait "$BRIDGE_PID"' "$ENTRYPOINT"; then
    fail "entrypoint must not wait on BRIDGE_PID"
fi
grep -Fq 'exit "$MT5_LIFECYCLE_STATUS"' "$ENTRYPOINT" || fail "propagate lifecycle status"
grep -Fq 'wineserver -k || true' "$ENTRYPOINT" || fail "cleanup wineserver -k"
grep -Fq 'trap cleanup EXIT' "$ENTRYPOINT" || fail "trap cleanup EXIT"
ENTRYPOINT_PATH="$ENTRYPOINT" python3 - <<'PY' || fail "entrypoint wait order"
from pathlib import Path
import os
text = Path(os.environ["ENTRYPOINT_PATH"]).read_text()
assert text.index("/scripts/mt5_lifecycle.sh &") < text.index("/scripts/start_bridge.sh")
assert text.index("/scripts/start_bridge.sh") < text.index('wait "$MT5_LIFECYCLE_PID"')
print("liveness order OK")
PY
TESTS_RUN=$((TESTS_RUN + 8))
pass "CMD liveness is wait(lifecycle); bridge is not owner; cleanup is entrypoint"

echo "=== test 16: exit-code collision child 70 vs update_timeout ==="
scan_process_candidates() {
    local -n _updaters="$1"
    local -n _terminals="$2"
    local -n _relaunch="$3"
    _updaters=()
    _terminals=()
    _relaunch=()
}
lifecycle_sleep() { :; }
STOP_REQUESTED=0
CURRENT_STATE="INIT"
MT5_HANDOFF_GRACE_SECONDS=0
set +e
OUTPUT="$(handle_handoff 70 "child_collision" 2>&1)"
STATUS=$?
set -e
assert_eq "70" "$STATUS" "collision numeric code"
echo "$OUTPUT" | grep -q "reason=child_nonzero_exit code=70" || fail "semantic is child_nonzero_exit not update_timeout"
echo "$OUTPUT" | grep -q "reason=update_timeout" && fail "must not log update_timeout for child 70"
TESTS_RUN=$((TESTS_RUN + 2))
echo "NOTE: numeric code 70 alone does not prove update_timeout (exit-code namespace collision)."
pass "child 70 collides numerically with EXIT_UPDATE_TIMEOUT"

echo "=== test 17: exit 73 reserved/unused ==="
grep -Fq 'EXIT_TERMINAL_DISAPPEARED=73' "$SCRIPT" || fail "constant 73 missing"
if grep -E 'return "\$EXIT_TERMINAL_DISAPPEARED"|exit "\$EXIT_TERMINAL_DISAPPEARED"' "$SCRIPT"; then
    fail "73 must remain unused in production paths"
fi
TESTS_RUN=$((TESTS_RUN + 2))
pass "EXIT_TERMINAL_DISAPPEARED=73 is reserved/currently unused"

echo "=== test 18: lifecycle does not call wineserver -k ==="
BODY="$(executable_body "$SCRIPT")"
echo "$BODY" | grep -Fq 'wineserver -k' && fail "lifecycle executable body must not wineserver -k"
TESTS_RUN=$((TESTS_RUN + 1))
pass "wineserver -k cleanup stays outside lifecycle"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
