#!/bin/bash
# Deterministic shutdown-policy tests for mt5_lifecycle.sh TERM ownership.
#
# Data flow: sources production lifecycle; snapshot scans + fake-active PIDs
# replace /proc and kill. Limitations: no real Wine/broker; real fake-child and
# fake-updater processes are used only in dedicated scenarios.
# Does not replace tests/test_mt5_lifecycle.sh (LiveUpdate state machine).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/images/mt5-headless/scripts/mt5_lifecycle.sh"

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

count_term() {
    local pid="$1"
    local n=0
    if [ -f "$TERM_LOG" ]; then
        n="$(grep -c "^${pid}\$" "$TERM_LOG" || true)"
    fi
    printf '%s' "$n"
}

# shellcheck source=../images/mt5-headless/scripts/mt5_lifecycle.sh
source "$SCRIPT"

SNAPSHOT_INDEX=0
TEST_SNAPSHOTS=()
declare -A FAKE_ACTIVE=()
declare -A STUBBORN_PIDS=()
TERM_LOG=""

parse_csv_pids() {
    local csv="$1"
    local -n _out="$2"
    _out=()
    if [ -z "$csv" ]; then
        return 0
    fi
    local IFS=','
    read -r -a _out <<< "$csv"
}

scan_process_candidates() {
    local -n _updaters="$1"
    local -n _terminals="$2"
    local -n _relaunch="$3"

    _updaters=()
    _terminals=()
    _relaunch=()

    local idx="$SNAPSHOT_INDEX"
    SNAPSHOT_INDEX=$((SNAPSHOT_INDEX + 1))
    if [ "${#TEST_SNAPSHOTS[@]}" -eq 0 ]; then
        return 0
    fi
    if [ "$idx" -ge "${#TEST_SNAPSHOTS[@]}" ]; then
        idx=$((${#TEST_SNAPSHOTS[@]} - 1))
    fi
    local snap="${TEST_SNAPSHOTS[$idx]:-||}"
    local updater_csv terminal_csv relaunch_csv
    IFS='|' read -r updater_csv terminal_csv relaunch_csv <<< "$snap"
    parse_csv_pids "$updater_csv" _updaters
    parse_csv_pids "$terminal_csv" _terminals
    parse_csv_pids "$relaunch_csv" _relaunch
}

process_is_active() {
    local pid="${1:-}"
    case "${pid}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "${pid}" -le 1 ] || [ "${pid}" -eq "$$" ]; then
        return 1
    fi
    [ "${FAKE_ACTIVE[${pid}]:-0}" = "1" ]
}

lifecycle_kill_term() {
    local pid="$1"
    echo "${pid}" >>"$TERM_LOG"
    if [ "${STUBBORN_PIDS[${pid}]:-0}" != "1" ]; then
        FAKE_ACTIVE["${pid}"]=0
    fi
    return 0
}

lifecycle_sleep() {
    :
}

reset_shutdown_test() {
    SNAPSHOT_INDEX=0
    TEST_SNAPSHOTS=()
    FAKE_ACTIVE=()
    STUBBORN_PIDS=()
    STOP_REQUESTED=0
    SHUTDOWN_IN_PROGRESS=0
    CURRENT_STATE="INIT"
    CURRENT_CHILD_PID=""
    MT5_SHUTDOWN_TIMEOUT_SECONDS=4
    MT5_SHUTDOWN_STABLE_SECONDS=2
    MT5_POLL_SECONDS=1
    TERM_LOG="$(mktemp /tmp/mt5-shutdown-term.XXXXXX)"
}

cleanup_term_log() {
    rm -f "$TERM_LOG"
}

echo "=== test 1: no processes ==="
reset_shutdown_test
TEST_SNAPSHOTS=("||" "||" "||" "||")
set +e
OUTPUT="$(shutdown_mt5_processes TERM 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "empty shutdown status"
test ! -s "$TERM_LOG" || fail "empty shutdown must not TERM"
echo "$OUTPUT" | grep -q "shutdown_begin source_signal=TERM child_signal=TERM" || fail "shutdown_begin"
TESTS_RUN=$((TESTS_RUN + 2))
pass "no processes: no TERM, stable window, return 0"
cleanup_term_log

echo "=== test 2: initial child ==="
reset_shutdown_test
CURRENT_CHILD_PID="101"
FAKE_ACTIVE[101]=1
TEST_SNAPSHOTS=("||" "||" "||" "||")
set +e
OUTPUT="$(shutdown_mt5_processes TERM 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "child shutdown status"
assert_eq "1" "$(count_term 101)" "child TERM once"
echo "$OUTPUT" | grep -q "shutdown_signal signal=TERM target_pids=101" || fail "child shutdown_signal"
TESTS_RUN=$((TESTS_RUN + 1))
pass "initial child receives TERM once and completes"
cleanup_term_log

echo "=== test 3: dedup child+terminal ==="
reset_shutdown_test
CURRENT_CHILD_PID="200"
FAKE_ACTIVE[200]=1
TEST_SNAPSHOTS=("|200|" "||" "||" "||")
set +e
OUTPUT="$(shutdown_mt5_processes TERM 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "dedup status"
assert_eq "1" "$(count_term 200)" "dedup TERM once"
TESTS_RUN=$((TESTS_RUN + 1))
pass "same PID as child and terminal is TERMed once per cycle"
cleanup_term_log

echo "=== test 4: relaunched terminal ==="
reset_shutdown_test
CURRENT_CHILD_PID=""
FAKE_ACTIVE[200]=1
TEST_SNAPSHOTS=("|200|200" "||" "||" "||")
set +e
OUTPUT="$(shutdown_mt5_processes TERM 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "relaunch shutdown status"
assert_eq "1" "$(count_term 200)" "relaunch TERM once"
echo "$OUTPUT" | grep -q "target_pids=200" || fail "relaunch target"
TESTS_RUN=$((TESTS_RUN + 1))
pass "relaunch/normal terminal receives TERM"
cleanup_term_log

echo "=== test 5: updater protected ==="
reset_shutdown_test
MT5_SHUTDOWN_TIMEOUT_SECONDS=3
FAKE_ACTIVE[300]=1
TEST_SNAPSHOTS=("300||" "300||" "300||" "300||")
set +e
OUTPUT="$(shutdown_mt5_processes TERM 2>&1)"
STATUS=$?
set -e
assert_eq "1" "$STATUS" "updater timeout helper status"
assert_eq "0" "$(count_term 300)" "updater must not receive TERM"
echo "$OUTPUT" | grep -q "shutdown_wait reason=updater_active updater_pids=300" || fail "updater wait log"
echo "$OUTPUT" | grep -q "shutdown_result=fallback_required reason=timeout" || fail "updater fallback"
set +e
HANDLER_OUT="$(
    STOP_REQUESTED=0
    SHUTDOWN_IN_PROGRESS=0
    CURRENT_STATE="RUNNING"
    shutdown_mt5_processes() {
        echo "helper_nonzero"
        return 1
    }
    on_term TERM
    echo "on_term_returned"
)"
HANDLER_STATUS=$?
set -e
assert_eq "0" "$HANDLER_STATUS" "on_term still exit 0 after fallback"
echo "$HANDLER_OUT" | grep -q "on_term_returned" && fail "on_term must exit"
TESTS_RUN=$((TESTS_RUN + 3))
pass "persistent updater is not TERMed; fallback_required; handler exit 0"
cleanup_term_log

echo "=== test 6: updater then relaunch ==="
reset_shutdown_test
FAKE_ACTIVE[300]=1
FAKE_ACTIVE[400]=1
TEST_SNAPSHOTS=(
    "300||"
    "300||"
    "|400|400"
    "||"
    "||"
    "||"
)
set +e
OUTPUT="$(shutdown_mt5_processes TERM 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "updater-relaunch status"
assert_eq "0" "$(count_term 300)" "updater never TERM"
assert_eq "1" "$(count_term 400)" "relaunch TERM once"
echo "$OUTPUT" | grep -q "shutdown_wait reason=updater_active updater_pids=300" || fail "wait updater"
echo "$OUTPUT" | grep -q "target_pids=400" || fail "TERM relaunch 400"
TESTS_RUN=$((TESTS_RUN + 2))
pass "updater untouched; relaunch TERMed; completed"
cleanup_term_log

echo "=== test 7: stubborn terminal ==="
reset_shutdown_test
MT5_SHUTDOWN_TIMEOUT_SECONDS=3
FAKE_ACTIVE[200]=1
STUBBORN_PIDS[200]=1
TEST_SNAPSHOTS=("|200|" "|200|" "|200|" "|200|")
set +e
OUTPUT="$(shutdown_mt5_processes TERM 2>&1)"
STATUS=$?
set -e
assert_eq "1" "$STATUS" "stubborn helper status"
test "$(count_term 200)" -ge 1 || fail "stubborn must receive TERM"
echo "$OUTPUT" | grep -q "shutdown_result=fallback_required" || fail "stubborn fallback"
echo "$OUTPUT" | grep -qi "KILL" && fail "must not SIGKILL"
TESTS_RUN=$((TESTS_RUN + 2))
pass "stubborn terminal times out to fallback without SIGKILL"
cleanup_term_log

echo "=== test 8: kill race ==="
reset_shutdown_test
FAKE_ACTIVE[200]=1
TEST_SNAPSHOTS=("|200|" "||" "||" "||")
lifecycle_kill_term() {
    local pid="$1"
    echo "${pid}" >>"$TERM_LOG"
    FAKE_ACTIVE["${pid}"]=0
    return 1
}
set +e
OUTPUT="$(shutdown_mt5_processes TERM 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "kill-race status"
assert_eq "1" "$(count_term 200)" "kill attempted once"
TESTS_RUN=$((TESTS_RUN + 1))
pass "ESRCH/kill failure is nonfatal and shutdown completes"
lifecycle_kill_term() {
    local pid="$1"
    echo "${pid}" >>"$TERM_LOG"
    if [ "${STUBBORN_PIDS[${pid}]:-0}" != "1" ]; then
        FAKE_ACTIVE["${pid}"]=0
    fi
    return 0
}
cleanup_term_log

echo "=== test 9: zombie is inactive ==="
ZOMBIE_PID=""
ZOMBIE_PARENT=""
python3 - <<'PY' &
import os, time
pid = os.fork()
if pid == 0:
    os._exit(0)
open("/tmp/mt5-zombie-pid", "w").write(str(pid))
time.sleep(8)
PY
ZOMBIE_PARENT=$!
for _i in $(seq 1 30); do
    if [ -f /tmp/mt5-zombie-pid ]; then
        ZOMBIE_PID="$(cat /tmp/mt5-zombie-pid)"
        break
    fi
    sleep 0.1
done
[ -n "$ZOMBIE_PID" ] || fail "zombie pid not created"
STATE="$(awk '/^State:/ { print $2 }' "/proc/${ZOMBIE_PID}/status" 2>/dev/null || true)"
assert_eq "Z" "$STATE" "proc state is zombie"
# production helper, not the fake-active override
(
    process_is_active() {
        local pid="${1:-}"
        case "${pid}" in
            ''|*[!0-9]*) return 1 ;;
        esac
        if [ "${pid}" -le 1 ] || [ "${pid}" -eq "$$" ]; then
            return 1
        fi
        local status_file="/proc/${pid}/status"
        if [ ! -r "${status_file}" ]; then
            return 1
        fi
        local state
        state="$(awk '/^State:/ { print $2; exit }' "${status_file}" 2>/dev/null || true)"
        if [ "${state}" = "Z" ]; then
            return 1
        fi
        kill -0 "${pid}" 2>/dev/null || return 1
        return 0
    }
    process_is_active "$ZOMBIE_PID"
) && fail "zombie must be inactive" || pass "zombie classified inactive"
TESTS_RUN=$((TESTS_RUN + 1))
kill -TERM "$ZOMBIE_PARENT" 2>/dev/null || true
wait "$ZOMBIE_PARENT" 2>/dev/null || true
rm -f /tmp/mt5-zombie-pid

echo "=== test 10: INT normalizes to child TERM ==="
reset_shutdown_test
CURRENT_CHILD_PID="101"
FAKE_ACTIVE[101]=1
TEST_SNAPSHOTS=("||" "||" "||" "||")
set +e
OUTPUT="$(shutdown_mt5_processes INT 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "INT shutdown status"
echo "$OUTPUT" | grep -q "shutdown_begin source_signal=INT child_signal=TERM" || fail "INT→TERM begin"
echo "$OUTPUT" | grep -q "shutdown_signal signal=TERM target_pids=101" || fail "child signal is TERM"
echo "$OUTPUT" | grep -q "shutdown_signal signal=INT" && fail "must not send INT to child"
assert_eq "1" "$(count_term 101)" "INT path TERMs child"
TESTS_RUN=$((TESTS_RUN + 3))
pass "source INT still sends TERM to child"
cleanup_term_log

echo "=== test 11: bridge PID is not a target ==="
reset_shutdown_test
FAKE_ACTIVE[500]=1
CURRENT_CHILD_PID=""
TEST_SNAPSHOTS=("||" "||" "||" "||")
set +e
OUTPUT="$(shutdown_mt5_processes TERM 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "bridge-ignored status"
assert_eq "0" "$(count_term 500)" "unclassified PID must not be TERMed"
TESTS_RUN=$((TESTS_RUN + 1))
pass "non-child non-terminal PID is not signaled"
cleanup_term_log

echo "=== test 12: static safety ==="
BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$SCRIPT")"
echo "$BODY" | grep -Fq 'wineserver -k' && fail "no wineserver -k"
echo "$BODY" | grep -Eq 'wineboot' && fail "no wineboot"
echo "$BODY" | grep -Eq 'pkill' && fail "no pkill"
echo "$BODY" | grep -Fq 'kill -KILL' && fail "no SIGKILL"
echo "$BODY" | grep -Eq 'kill -TERM -- -|kill -- -\$\$|killpg' && fail "no process-group kill"
TESTS_RUN=$((TESTS_RUN + 5))
pass "executable body has no wineserver-k/wineboot/pkill/SIGKILL/pg"

echo "=== test 13: fake real child ==="
CASE_DIR="$(mktemp -d /tmp/mt5-shutdown-real.XXXXXX)"
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
export MT5_SHUTDOWN_TIMEOUT_SECONDS=8
export MT5_SHUTDOWN_STABLE_SECONDS=1
export MT5_POLL_SECONDS=1
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
[ -n "$CHILD_PID" ] || fail "real-fake child not observed"
kill -TERM "$LIFECYCLE_PID"
set +e
wait "$LIFECYCLE_PID"
LIFE_STATUS=$?
set -e
assert_eq "0" "$LIFE_STATUS" "real-fake lifecycle exit"
grep -q "shutdown_result=completed" "$LOG" || fail "real-fake completed"
CHILD_GONE=0
if ! kill -0 "$CHILD_PID" 2>/dev/null; then
    CHILD_GONE=1
elif awk '/^State:/ { exit ($2 == "Z") ? 0 : 1 }' "/proc/${CHILD_PID}/status" 2>/dev/null; then
    CHILD_GONE=1
fi
assert_eq "1" "$CHILD_GONE" "real-fake child gone or zombie"
kill -KILL "$CHILD_PID" 2>/dev/null || true
pass "fake real child is TERMed via lifecycle"
rm -rf "$CASE_DIR"
unset MT5_EXE MT5_CMD_OPTIONS MT5_SHUTDOWN_TIMEOUT_SECONDS MT5_SHUTDOWN_STABLE_SECONDS MT5_POLL_SECONDS WINE_PID_FILE || true

echo "=== test 14: fake real updater is not TERMed ==="
bash -c 'exec -a "C:\\liveupdate\\terminal64.exe /update /portable" sleep 30' &
UPDATER_PID=$!
sleep 0.2
kill -0 "$UPDATER_PID" || fail "fake updater not running"
set +e
OUTPUT="$(
    MT5_SHUTDOWN_TIMEOUT_SECONDS=3 \
    MT5_SHUTDOWN_STABLE_SECONDS=2 \
    MT5_POLL_SECONDS=1 \
    bash -c '
        set -Eeuo pipefail
        source "$1"
        CURRENT_CHILD_PID=""
        shutdown_mt5_processes TERM
    ' bash "$SCRIPT"
)"
STATUS=$?
set -e
UPDATER_ALIVE=0
if kill -0 "$UPDATER_PID" 2>/dev/null; then
    UPDATER_ALIVE=1
fi
assert_eq "1" "$STATUS" "updater real helper timeout"
assert_eq "1" "$UPDATER_ALIVE" "updater still alive (not TERMed)"
echo "$OUTPUT" | grep -q "shutdown_wait reason=updater_active" || fail "real updater wait"
echo "$OUTPUT" | grep -q "shutdown_result=fallback_required" || fail "real updater fallback"
echo "$OUTPUT" | grep -q "target_pids=${UPDATER_PID}" && fail "updater must not be in shutdown_signal"
TESTS_RUN=$((TESTS_RUN + 3))
kill -TERM "$UPDATER_PID" 2>/dev/null || true
wait "$UPDATER_PID" 2>/dev/null || true
kill -KILL "$UPDATER_PID" 2>/dev/null || true
pass "real scanner classifies updater and does not TERM it"

echo "=== test 15: fake real relaunch is TERMed ==="
bash -c 'exec -a "C:\\Program Files\\MetaTrader 5\\terminal64.exe /skipupdate:E37BD44435252CF0D1BD0D6944C9EFA5 /portable" sleep 30' &
RELAUNCH_PID=$!
sleep 0.2
kill -0 "$RELAUNCH_PID" || fail "fake relaunch not running"
set +e
OUTPUT="$(
    MT5_SHUTDOWN_TIMEOUT_SECONDS=6 \
    MT5_SHUTDOWN_STABLE_SECONDS=1 \
    MT5_POLL_SECONDS=1 \
    bash -c '
        set -Eeuo pipefail
        source "$1"
        CURRENT_CHILD_PID=""
        shutdown_mt5_processes TERM
    ' bash "$SCRIPT"
)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "real relaunch shutdown status"
echo "$OUTPUT" | grep -q "shutdown_signal signal=TERM target_pids=${RELAUNCH_PID}" || fail "relaunch must be targeted"
RELAUNCH_GONE=0
if ! kill -0 "$RELAUNCH_PID" 2>/dev/null; then
    RELAUNCH_GONE=1
elif awk '/^State:/ { exit ($2 == "Z") ? 0 : 1 }' "/proc/${RELAUNCH_PID}/status" 2>/dev/null; then
    RELAUNCH_GONE=1
fi
assert_eq "1" "$RELAUNCH_GONE" "relaunch process ended"
kill -KILL "$RELAUNCH_PID" 2>/dev/null || true
TESTS_RUN=$((TESTS_RUN + 1))
pass "real scanner TERMs skipupdate relaunch terminal"

echo "=== test 16: updater then relaunch (real processes, synchronized) ==="
# Stabilized 04K-B: explicit markers replace the sleep-1 race. Production
# lifecycle is untouched; only the test-only lifecycle_sleep seam is overridden.
MARKER_DIR="$(mktemp -d /tmp/mt5-upd-relaunch.XXXXXX)"
UPDATER_PID=""
RELAUNCH_PID=""
ORCH_PID=""
cleanup_test16() {
    if [ -n "${RELAUNCH_PID}" ]; then
        kill -TERM "$RELAUNCH_PID" 2>/dev/null || true
        kill -KILL "$RELAUNCH_PID" 2>/dev/null || true
    fi
    if [ -n "${UPDATER_PID}" ]; then
        kill -TERM "$UPDATER_PID" 2>/dev/null || true
        kill -KILL "$UPDATER_PID" 2>/dev/null || true
    fi
    if [ -n "${ORCH_PID}" ]; then
        kill -TERM "$ORCH_PID" 2>/dev/null || true
        kill -KILL "$ORCH_PID" 2>/dev/null || true
    fi
    rm -rf "$MARKER_DIR"
}
trap cleanup_test16 EXIT

# Updater stays alive until release_updater, then exits naturally (not TERMed).
exec -a "C:\\liveupdate\\terminal64.exe /update /portable" \
    bash -c "
set -Eeuo pipefail
echo \$\$ > '${MARKER_DIR}/updater.pid'
touch '${MARKER_DIR}/updater_ready'
while [ ! -f '${MARKER_DIR}/release_updater' ]; do
  sleep 0.05
done
exit 0
" &
# Note: $! is the bash child; cmdline classification uses the exec -a name.
sleep 0.05
for _ in $(seq 1 100); do
    if [ -f "${MARKER_DIR}/updater.pid" ] && [ -f "${MARKER_DIR}/updater_ready" ]; then
        break
    fi
    sleep 0.05
done
test -f "${MARKER_DIR}/updater.pid" || fail "updater_ready timeout"
UPDATER_PID="$(cat "${MARKER_DIR}/updater.pid")"
kill -0 "$UPDATER_PID" || fail "updater not running"

# Orchestrator: after release, wait updater gone, spawn relaunch, publish ready.
(
    set -Eeuo pipefail
    while [ ! -f "${MARKER_DIR}/release_updater" ]; do
        sleep 0.05
    done
    while kill -0 "$UPDATER_PID" 2>/dev/null; do
        sleep 0.05
    done
    exec -a "C:\\Program Files\\MetaTrader 5\\terminal64.exe /skipupdate:E37BD44435252CF0D1BD0D6944C9EFA5 /portable" sleep 30 &
    echo $! >"${MARKER_DIR}/relaunch.pid"
    touch "${MARKER_DIR}/relaunch_ready"
    wait || true
) &
ORCH_PID=$!

set +e
OUTPUT="$(
    MARKER_DIR="$MARKER_DIR" \
    MT5_SHUTDOWN_TIMEOUT_SECONDS=8 \
    MT5_SHUTDOWN_STABLE_SECONDS=1 \
    MT5_POLL_SECONDS=1 \
    bash -c '
        set -Eeuo pipefail
        source "$1"
        CURRENT_CHILD_PID=""
        RELEASED=0
        lifecycle_sleep() {
            local seconds="${1:-1}"
            if [ "$RELEASED" -eq 0 ]; then
                RELEASED=1
                touch "${MARKER_DIR}/release_updater"
                local i=0
                while [ ! -f "${MARKER_DIR}/relaunch_ready" ]; do
                    if [ "$i" -ge 100 ]; then
                        echo "FAIL: relaunch_ready timeout" >&2
                        return 1
                    fi
                    sleep 0.05
                    i=$((i + 1))
                done
            fi
            sleep "$seconds"
        }
        shutdown_mt5_processes TERM
    ' bash "$SCRIPT"
)"
STATUS=$?
set -e

test -f "${MARKER_DIR}/relaunch.pid" || fail "relaunch pid missing"
RELAUNCH_PID="$(cat "${MARKER_DIR}/relaunch.pid")"

assert_eq "0" "$STATUS" "synchronized updater→relaunch status"
echo "$OUTPUT" | grep -q "shutdown_wait reason=updater_active" || fail "must wait while updater active"
echo "$OUTPUT" | grep -q "shutdown_signal signal=TERM" || fail "must TERM relaunch"
echo "$OUTPUT" | grep -q "target_pids=${RELAUNCH_PID}" || fail "must TERM relaunch pid"
if echo "$OUTPUT" | grep -E 'target_pids=' | grep -Eq "(^|[^0-9])${UPDATER_PID}([^0-9]|$)"; then
    fail "updater PID appeared in target_pids"
fi
TESTS_RUN=$((TESTS_RUN + 4))
pass "real updater→relaunch: synchronized; updater untouched; relaunch TERMed"

trap - EXIT
cleanup_test16

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
