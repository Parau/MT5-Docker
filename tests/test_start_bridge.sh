#!/bin/bash
# Deterministic contract tests for start_bridge.sh process gate, wait, and spawn/wait.
#
# Data flow: runs production start_bridge.sh with fake wine + system python3 and
# a fake /proc tree (BRIDGE_PROC_ROOT). Final bridge is a stub under BRIDGE_DIR.
# Limitations: no real Wine/MT5/broker; signal ownership is in test_bridge_shutdown.sh.
# Crash/nonfatal ownership for the container remains proven by smoke, not here.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/images/mt5-headless/scripts/start_bridge.sh"
LIFECYCLE="${ROOT}/images/mt5-headless/scripts/mt5_lifecycle.sh"
DOCKERFILE="${ROOT}/images/mt5-headless/Dockerfile"
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

executable_body() {
    awk 'NR==1{next} /^#/{next} {print}' "$1"
}

ensure_proc_bins() {
    mkdir -p "${CASE_DIR}/bins"
    : >"${CASE_DIR}/bins/wine64-preloader"
    : >"${CASE_DIR}/bins/bash"
    : >"${CASE_DIR}/bins/python3"
}

write_proc_stat() {
    local dir="$1"
    local pid="$2"
    local comm="$3"
    local starttime="$4"
    local state="${5:-S}"
    write_linux_proc_stat "${dir}/stat" "$pid" "$comm" "$state" "$starttime"
}

# kind: normal|updater|helper_bash|helper_python|unreadable|zombie|broken_exe
write_mt5_proc() {
    local proc_root="$1"
    local pid="$2"
    local starttime="$3"
    local kind="$4"
    shift 4
    local dir="${proc_root}/${pid}"
    mkdir -p "$dir"
    local arg
    : >"${dir}/cmdline"
    for arg in "$@"; do
        printf '%s\0' "$arg" >>"${dir}/cmdline"
    done
    local comm="main"
    local exe_base="wine64-preloader"
    local state="S"
    case "$kind" in
        helper_bash) comm="bash"; exe_base="bash" ;;
        helper_python) comm="python3"; exe_base="python3" ;;
        zombie) state="Z" ;;
        unreadable) exe_base="" ;;
        broken_exe) exe_base="missing" ;;
    esac
    if [ "$state" = "Z" ]; then
        printf 'State:\tZ\n' >"${dir}/status"
    else
        printf 'State:\tR\n' >"${dir}/status"
    fi
    printf '%s\n' "$comm" >"${dir}/comm"
    write_proc_stat "$dir" "$pid" "$comm" "$starttime" "$state"
    rm -f "${dir}/exe"
    if [ "$kind" = "unreadable" ]; then
        :
    elif [ "$kind" = "broken_exe" ]; then
        ln -sfn "${CASE_DIR}/bins/missing" "${dir}/exe"
    else
        ln -sfn "${CASE_DIR}/bins/${exe_base}" "${dir}/exe"
    fi
}

write_proc_cmdline() {
    local proc_root="$1"
    local pid="$2"
    shift 2
    write_mt5_proc "$proc_root" "$pid" 1000 normal "$@"
}

setup_case() {
    CASE_DIR="$(mktemp -d /tmp/start-bridge-contract.XXXXXX)"
    FAKE_BIN="${CASE_DIR}/bin"
    BRIDGE_DIR="${CASE_DIR}/bridge"
    PROC_ROOT="${CASE_DIR}/proc"
    mkdir -p "$FAKE_BIN" "$BRIDGE_DIR" "$PROC_ROOT"
    ensure_proc_bins

    cat >"${FAKE_BIN}/wine" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "$*" >>"${WINE_CALLS:?}"
if [ "${1:-}" != "python" ]; then
    echo "unexpected wine argv: $*" >&2
    exit 97
fi
shift
if [ "${1:-}" = "-" ]; then
    echo "unexpected wine python - probe" >&2
    echo "PROBE" >>"${WINE_CALLS}"
    exit 97
fi
count=0
if [ -f "${BRIDGE_COUNT:?}" ]; then
    count="$(cat "$BRIDGE_COUNT")"
fi
count=$((count + 1))
echo "$count" >"$BRIDGE_COUNT"
{
    printf 'cwd=%s\n' "$(pwd)"
    printf 'WINEPREFIX=%s\n' "${WINEPREFIX-}"
    printf 'WINEDEBUG=%s\n' "${WINEDEBUG-}"
    printf 'RPYC_PORT=%s\n' "${RPYC_PORT-}"
} >"${BRIDGE_ENV:?}"
exec python3 "$@"
EOF
    chmod +x "${FAKE_BIN}/wine"

    cat >"${BRIDGE_DIR}/mt5_bridge.py" <<'EOF'
import os
import sys

marker = os.environ.get("BRIDGE_MARKER", "")
if marker:
    with open(marker, "a", encoding="utf-8") as fh:
        fh.write("bridge\n")
raise SystemExit(int(os.environ.get("BRIDGE_EXIT", "42")))
EOF

    : >"${CASE_DIR}/wine_calls"
    echo 0 >"${CASE_DIR}/bridge_count"
    : >"${CASE_DIR}/bridge.env"
    : >"${CASE_DIR}/bridge.marker"
}

run_bridge() {
    set +e
    OUTPUT="$(
        PATH="${FAKE_BIN}:${PATH}" \
        WINE_CALLS="${CASE_DIR}/wine_calls" \
        BRIDGE_COUNT="${CASE_DIR}/bridge_count" \
        BRIDGE_ENV="${CASE_DIR}/bridge.env" \
        BRIDGE_MARKER="${CASE_DIR}/bridge.marker" \
        BRIDGE_EXIT="${BRIDGE_EXIT:-42}" \
        BRIDGE_DIR="$BRIDGE_DIR" \
        BRIDGE_PROC_ROOT="${PROC_ROOT}" \
        WINEPREFIX="${WINEPREFIX:-/tmp/bridge-wine}" \
        WINEDEBUG="${WINEDEBUG:--all}" \
        RPYC_PORT="${RPYC_PORT:-18812}" \
        BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-180}" \
        BRIDGE_PROCESS_POLL_SECONDS="${BRIDGE_PROCESS_POLL_SECONDS:-1}" \
        BRIDGE_MT5_PROCESS_STABLE_SECONDS="${BRIDGE_MT5_PROCESS_STABLE_SECONDS:-1}" \
        BRIDGE_SHUTDOWN_TIMEOUT_SECONDS="${BRIDGE_SHUTDOWN_TIMEOUT_SECONDS:-8}" \
        BRIDGE_SHUTDOWN_POLL_SECONDS="${BRIDGE_SHUTDOWN_POLL_SECONDS:-1}" \
        bash "$SCRIPT" 2>&1
    )"
    STATUS=$?
    set -e
}

run_bridge_bg() {
    PATH="${FAKE_BIN}:${PATH}" \
    WINE_CALLS="${CASE_DIR}/wine_calls" \
    BRIDGE_COUNT="${CASE_DIR}/bridge_count" \
    BRIDGE_ENV="${CASE_DIR}/bridge.env" \
    BRIDGE_MARKER="${CASE_DIR}/bridge.marker" \
    BRIDGE_EXIT="${BRIDGE_EXIT:-42}" \
    BRIDGE_DIR="$BRIDGE_DIR" \
    BRIDGE_PROC_ROOT="${PROC_ROOT}" \
    WINEPREFIX="${WINEPREFIX:-/tmp/bridge-wine}" \
    WINEDEBUG="${WINEDEBUG:--all}" \
    RPYC_PORT="${RPYC_PORT:-18812}" \
    BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-180}" \
    BRIDGE_PROCESS_POLL_SECONDS="${BRIDGE_PROCESS_POLL_SECONDS:-1}" \
    BRIDGE_MT5_PROCESS_STABLE_SECONDS="${BRIDGE_MT5_PROCESS_STABLE_SECONDS:-1}" \
    BRIDGE_SHUTDOWN_TIMEOUT_SECONDS="${BRIDGE_SHUTDOWN_TIMEOUT_SECONDS:-8}" \
    BRIDGE_SHUTDOWN_POLL_SECONDS="${BRIDGE_SHUTDOWN_POLL_SECONDS:-1}" \
    bash "$SCRIPT" >"${CASE_DIR}/wrapper.log" 2>&1 &
    WRAPPER_PID=$!
}

wait_for_log() {
    local file="$1"
    local pattern="$2"
    local i
    for i in $(seq 1 50); do
        if grep -q "$pattern" "$file" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

wait_for_log_count() {
    local file="$1"
    local pattern="$2"
    local need="$3"
    local i n
    for i in $(seq 1 80); do
        n="$(grep -c "$pattern" "$file" 2>/dev/null || true)"
        if [ "${n:-0}" -ge "$need" ]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

call_bridge_starttime() {
    local pid="$1"
    BRIDGE_PROC_ROOT="$PROC_ROOT" bash -c '
set -Eeuo pipefail
source "$1"
bridge_proc_starttime "$2"
' _ "$SCRIPT" "$pid"
}

call_bridge_identity() {
    local pid="$1"
    BRIDGE_PROC_ROOT="$PROC_ROOT" bash -c '
set -Eeuo pipefail
source "$1"
bridge_process_identity "$2"
' _ "$SCRIPT" "$pid"
}

wine_probe_forbidden() {
    if grep -Eq '(^|[[:space:]])python[[:space:]]+-' "${CASE_DIR}/wine_calls" 2>/dev/null; then
        fail "wine python - probe must not run"
    fi
    if grep -qx "PROBE" "${CASE_DIR}/wine_calls" 2>/dev/null; then
        fail "probe marker written"
    fi
}

echo "=== test 1: defaults frozen ==="
DEFAULTS_OUT="$(
    env -u WINEPREFIX -u WINEDEBUG -u BRIDGE_DIR -u RPYC_PORT \
        -u BRIDGE_WAIT_SECONDS -u BRIDGE_RETRY_SECONDS \
        -u BRIDGE_PROCESS_POLL_SECONDS -u BRIDGE_MT5_PROCESS_STABLE_SECONDS \
        -u BRIDGE_SHUTDOWN_TIMEOUT_SECONDS -u BRIDGE_SHUTDOWN_POLL_SECONDS \
        bash -c '
            set -Eeuo pipefail
            export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
            export WINEDEBUG="${WINEDEBUG:--all}"
            BRIDGE_DIR="${BRIDGE_DIR:-/opt/bridge}"
            RPYC_PORT="${RPYC_PORT:-18812}"
            BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-180}"
            BRIDGE_PROCESS_POLL_SECONDS="${BRIDGE_PROCESS_POLL_SECONDS:-${BRIDGE_RETRY_SECONDS:-1}}"
            BRIDGE_MT5_PROCESS_STABLE_SECONDS="${BRIDGE_MT5_PROCESS_STABLE_SECONDS:-5}"
            BRIDGE_SHUTDOWN_TIMEOUT_SECONDS="${BRIDGE_SHUTDOWN_TIMEOUT_SECONDS:-8}"
            BRIDGE_SHUTDOWN_POLL_SECONDS="${BRIDGE_SHUTDOWN_POLL_SECONDS:-1}"
            printf "WINEPREFIX=%s\n" "$WINEPREFIX"
            printf "WINEDEBUG=%s\n" "$WINEDEBUG"
            printf "BRIDGE_DIR=%s\n" "$BRIDGE_DIR"
            printf "RPYC_PORT=%s\n" "$RPYC_PORT"
            printf "WAIT=%s\n" "$BRIDGE_WAIT_SECONDS"
            printf "POLL=%s\n" "$BRIDGE_PROCESS_POLL_SECONDS"
            printf "STABLE=%s\n" "$BRIDGE_MT5_PROCESS_STABLE_SECONDS"
            printf "SHUTDOWN_TIMEOUT=%s\n" "$BRIDGE_SHUTDOWN_TIMEOUT_SECONDS"
            printf "SHUTDOWN_POLL=%s\n" "$BRIDGE_SHUTDOWN_POLL_SECONDS"
        '
)"
echo "$DEFAULTS_OUT" | grep -qx "WINEPREFIX=/config/.wine" || fail "default WINEPREFIX"
echo "$DEFAULTS_OUT" | grep -qx "WINEDEBUG=-all" || fail "default WINEDEBUG"
echo "$DEFAULTS_OUT" | grep -qx "BRIDGE_DIR=/opt/bridge" || fail "default BRIDGE_DIR"
echo "$DEFAULTS_OUT" | grep -qx "RPYC_PORT=18812" || fail "default RPYC_PORT"
echo "$DEFAULTS_OUT" | grep -qx "WAIT=180" || fail "default WAIT"
echo "$DEFAULTS_OUT" | grep -qx "POLL=1" || fail "default POLL"
echo "$DEFAULTS_OUT" | grep -qx "STABLE=5" || fail "default STABLE"
echo "$DEFAULTS_OUT" | grep -qx "SHUTDOWN_TIMEOUT=8" || fail "default shutdown timeout"
echo "$DEFAULTS_OUT" | grep -qx "SHUTDOWN_POLL=1" || fail "default shutdown poll"
grep -Fq 'WINEPREFIX="${WINEPREFIX:-/config/.wine}"' "$SCRIPT" || fail "literal WINEPREFIX default"
grep -Fq 'BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-180}"' "$SCRIPT" || fail "literal WAIT default"
grep -Fq 'BRIDGE_PROCESS_POLL_SECONDS="${BRIDGE_PROCESS_POLL_SECONDS:-${BRIDGE_RETRY_SECONDS:-1}}"' "$SCRIPT" || fail "literal POLL default"
grep -Fq 'BRIDGE_MT5_PROCESS_STABLE_SECONDS="${BRIDGE_MT5_PROCESS_STABLE_SECONDS:-5}"' "$SCRIPT" || fail "literal STABLE default"
grep -Fq 'BRIDGE_SHUTDOWN_TIMEOUT_SECONDS="${BRIDGE_SHUTDOWN_TIMEOUT_SECONDS:-8}"' "$SCRIPT" || fail "literal shutdown timeout"
TESTS_RUN=$((TESTS_RUN + 14))
pass "defaults frozen"

echo "=== test 2: missing bridge exit1 without wine ==="
setup_case
rm -f "${BRIDGE_DIR}/mt5_bridge.py"
BRIDGE_WAIT_SECONDS=1
run_bridge
assert_eq "1" "$STATUS" "missing bridge exit"
echo "$OUTPUT" | grep -q "ERRO: bridge ausente" || fail "missing bridge message"
test ! -s "${CASE_DIR}/wine_calls" || fail "wine must not run when bridge missing"
pass "missing bridge exits 1 without wine"
rm -rf "$CASE_DIR"

echo "=== test 3: RUN_BRIDGE not owned by start_bridge or CMD ==="
BODY="$(executable_body "$SCRIPT")"
echo "$BODY" | grep -Eq 'RUN_BRIDGE' && fail "start_bridge must not read RUN_BRIDGE"
test ! -e "${ROOT}/images/mt5-headless/entrypoint.sh" || fail "entrypoint.sh must be deleted"
grep -Eq '^CMD ' "$DOCKERFILE" && fail "Dockerfile must not declare CMD"
GATE="${ROOT}/images/mt5-headless/scripts/s6_stage2_bridge_gate.sh"
test -f "$GATE" || fail "stage2 gate script missing"
grep -Fq 'RUN_BRIDGE' "$GATE" || fail "stage2 gate must read RUN_BRIDGE"
test -e "${ROOT}/images/mt5-headless/s6-rc.d/bridge/type" || fail "bridge longrun missing"
TESTS_RUN=$((TESTS_RUN + 5))
pass "RUN_BRIDGE is stage2-gate owned; no CMD spawn"

echo "=== test 4: classifier parity with mt5_lifecycle.sh ==="
classify_line() {
    local script="$1"
    local cmd="$2"
    local prefix="$3"
    bash -c '
        set -Eeuo pipefail
        script="$1"
        cmd="$2"
        prefix="$3"
        # shellcheck source=/dev/null
        source "$script"
        lower="${cmd,,}"
        t=0; u=0; n=0
        if [ "$prefix" = "lifecycle" ]; then
            is_terminal64_cmdline "$lower" && t=1 || true
            is_updater_cmdline "$lower" && u=1 || true
            is_normal_terminal_cmdline "$lower" && n=1 || true
        else
            bridge_is_terminal64_cmdline "$lower" && t=1 || true
            bridge_is_updater_cmdline "$lower" && u=1 || true
            bridge_is_normal_terminal_cmdline "$lower" && n=1 || true
        fi
        printf "t=%s u=%s n=%s\n" "$t" "$u" "$n"
    ' _ "$script" "$cmd" "$prefix"
}
parity_cases=(
    "C:\\Program Files\\MetaTrader 5\\terminal64.exe /portable|normal"
    "C:\\Program Files\\MetaTrader 5\\terminal64.exe /skipupdate:E37BD44435252CF0D1BD0D6944C9EFA5 /portable|normal"
    "C:\\users\\root\\AppData\\Roaming\\MetaQuotes\\Terminal\\D0E8209F77C8CF37AD8BF550E51FF075\\liveupdate\\terminal64.exe /update /portable|updater"
    "Z:\\mt5\\terminal64.exe liveupdate|updater"
    "C:\\windows\\system32\\updater.exe /update|other"
    "C:\\python\\python.exe|other"
    "|empty"
)
for spec in "${parity_cases[@]}"; do
    cmd="${spec%%|*}"
    kind="${spec##*|}"
    lc="$(classify_line "$LIFECYCLE" "$cmd" lifecycle)"
    br="$(classify_line "$SCRIPT" "$cmd" bridge)"
    assert_eq "$lc" "$br" "parity line (${kind})"
    case "$kind" in
        normal)
            echo "$br" | grep -qx "t=1 u=0 n=1" || fail "expected normal: $cmd ($br)"
            ;;
        updater)
            echo "$br" | grep -qx "t=1 u=1 n=0" || fail "expected updater: $cmd ($br)"
            ;;
        other|empty)
            echo "$br" | grep -qx "t=0 u=0 n=0" || fail "expected non-terminal: $cmd ($br)"
            ;;
    esac
done
pass "classifier parity A–G"

echo "=== test 5: no terminal waits; TERM exits 0 without wine ==="
setup_case
BRIDGE_WAIT_SECONDS=30
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "state=WAITING_FOR_MT5_PROCESS" || fail "waiting log"
sleep 0.4
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "no server while waiting"
test ! -s "${CASE_DIR}/wine_calls" || fail "wine must not run without terminal"
kill -TERM "$WRAPPER_PID"
set +e
wait "$WRAPPER_PID"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "TERM during wait exit0"
wine_probe_forbidden
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "TERM wait must not start server"
pass "A: no terminal waits; TERM→exit0; no wine"
rm -rf "$CASE_DIR"

echo "=== test 6: updater-only does not start server ==="
setup_case
write_proc_cmdline "$PROC_ROOT" 100 "Z:\\mt5\\terminal64.exe" "/update"
BRIDGE_WAIT_SECONDS=30
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "state=WAITING_FOR_MT5_PROCESS" || fail "updater waiting log"
sleep 1.2
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "updater must not launch server"
grep -q "candidate_count=0" "${CASE_DIR}/wrapper.log" || fail "updater candidate_count=0"
kill -TERM "$WRAPPER_PID"
wait "$WRAPPER_PID" 2>/dev/null || true
wine_probe_forbidden
pass "B: updater-only rejected"
rm -rf "$CASE_DIR"

echo "=== test 7: normal terminal stable then wine python mt5_bridge.py ==="
setup_case
write_proc_cmdline "$PROC_ROOT" 200 "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
BRIDGE_WAIT_SECONDS=30
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
BRIDGE_PROCESS_POLL_SECONDS=1
run_bridge
assert_eq "42" "$STATUS" "wrapper propagates final exit42"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "final bridge once"
echo "$OUTPUT" | grep -q "state=MT5_PROCESS_READY" || fail "process ready log"
echo "$OUTPUT" | grep -q "state=BRIDGE_EXIT code=42" || fail "BRIDGE_EXIT 42"
grep -Eq 'python mt5_bridge.py' "${CASE_DIR}/wine_calls" || fail "must invoke wine python mt5_bridge.py"
wine_probe_forbidden
assert_eq "1" "$(grep -c '^bridge$' "${CASE_DIR}/bridge.marker" || true)" "bridge marker once"
pass "C: normal terminal → exactly wine python mt5_bridge.py"
rm -rf "$CASE_DIR"

echo "=== test 8: skipupdate is accepted as normal ==="
setup_case
write_proc_cmdline "$PROC_ROOT" 201 "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/skipupdate:E37BD44435252CF0D1BD0D6944C9EFA5" "/portable"
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
run_bridge
assert_eq "42" "$STATUS" "skipupdate exit"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "skipupdate starts server"
echo "$OUTPUT" | grep -q "state=MT5_PROCESS_READY" || fail "skipupdate ready"
wine_probe_forbidden
pass "D: skipupdate accepted"
rm -rf "$CASE_DIR"

echo "=== test 9: unstable appear/disappear resets and does not launch ==="
setup_case
write_proc_cmdline "$PROC_ROOT" 202 "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
BRIDGE_WAIT_SECONDS=30
BRIDGE_MT5_PROCESS_STABLE_SECONDS=2
BRIDGE_PROCESS_POLL_SECONDS=1
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "candidate_count=1" || fail "saw candidate"
sleep 0.3
rm -rf "${PROC_ROOT}/202"
wait_for_log "${CASE_DIR}/wrapper.log" "candidate_count=0" || fail "reset after disappear"
sleep 1.2
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "unstable must not launch"
kill -TERM "$WRAPPER_PID"
wait "$WRAPPER_PID" 2>/dev/null || true
wine_probe_forbidden
pass "E: unstable appear/disappear resets; no server"
rm -rf "$CASE_DIR"

echo "=== test 10: terminal appears later in the same wrapper ==="
setup_case
BRIDGE_WAIT_SECONDS=30
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
BRIDGE_PROCESS_POLL_SECONDS=1
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "state=WAITING_FOR_MT5_PROCESS" || fail "waiting before appear"
sleep 0.4
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "still waiting"
write_proc_cmdline "$PROC_ROOT" 203 "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
set +e
wait "$WRAPPER_PID"
STATUS=$?
set -e
assert_eq "42" "$STATUS" "same wrapper starts server after appear"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "one server after late appear"
grep -q "state=MT5_PROCESS_READY" "${CASE_DIR}/wrapper.log" || fail "ready after late appear"
wine_probe_forbidden
pass "F: terminal appears later; same wrapper starts server"
rm -rf "$CASE_DIR"

echo "=== test 11: warning interval continues waiting; no launch ==="
setup_case
BRIDGE_WAIT_SECONDS=1
BRIDGE_PROCESS_POLL_SECONDS=1
BRIDGE_MT5_PROCESS_STABLE_SECONDS=5
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "action=continue_waiting" || fail "warning interval log"
sleep 0.3
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "warning must not launch"
grep -q "launch_allowed=0" "${CASE_DIR}/wrapper.log" || fail "launch_allowed=0"
if ! kill -0 "$WRAPPER_PID" 2>/dev/null; then
    fail "wrapper must stay alive after warning"
fi
kill -TERM "$WRAPPER_PID"
set +e
wait "$WRAPPER_PID"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "warning path TERM exit0"
wine_probe_forbidden
pass "G: warning interval; continue wait; no server; no exit"
rm -rf "$CASE_DIR"

echo "=== test 12: env propagation to final process ==="
setup_case
write_proc_cmdline "$PROC_ROOT" 204 "C:\\Program Files\\MetaTrader 5\\terminal64.exe"
WINEPREFIX=/tmp/custom-wine
WINEDEBUG=-fix+all
RPYC_PORT=18814
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
run_bridge
assert_eq "42" "$STATUS" "env propagation exit"
grep -qx "WINEPREFIX=/tmp/custom-wine" "${CASE_DIR}/bridge.env" || fail "WINEPREFIX not propagated"
grep -qx "WINEDEBUG=-fix+all" "${CASE_DIR}/bridge.env" || fail "WINEDEBUG not propagated"
grep -qx "RPYC_PORT=18814" "${CASE_DIR}/bridge.env" || fail "RPYC_PORT not propagated"
TESTS_RUN=$((TESTS_RUN + 3))
pass "WINEPREFIX/WINEDEBUG/RPYC_PORT reach final process"
rm -rf "$CASE_DIR"
unset WINEPREFIX WINEDEBUG RPYC_PORT || true

echo "=== test 13: final cwd is BRIDGE_DIR ==="
setup_case
write_proc_cmdline "$PROC_ROOT" 205 "C:\\Program Files\\MetaTrader 5\\terminal64.exe"
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
run_bridge
grep -qx "cwd=${BRIDGE_DIR}" "${CASE_DIR}/bridge.env" || fail "cwd must be BRIDGE_DIR"
TESTS_RUN=$((TESTS_RUN + 1))
pass "final process cwd equals BRIDGE_DIR"
rm -rf "$CASE_DIR"

echo "=== test 14: server exit42 propagated; no internal restart ==="
setup_case
write_proc_cmdline "$PROC_ROOT" 206 "C:\\Program Files\\MetaTrader 5\\terminal64.exe"
BRIDGE_EXIT=42
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
run_bridge
assert_eq "42" "$STATUS" "H: crash passthrough"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "final invoked once"
sleep 0.2
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "still once after delay"
echo "$OUTPUT" | grep -q "state=BRIDGE_EXIT code=42" || fail "BRIDGE_EXIT 42"
pass "H: server exit42 count1 no restart"
rm -rf "$CASE_DIR"

echo "=== test 15: invalid WAIT falls back to 180 without abort ==="
setup_case
write_proc_cmdline "$PROC_ROOT" 207 "C:\\Program Files\\MetaTrader 5\\terminal64.exe"
BRIDGE_WAIT_SECONDS=0
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
run_bridge
assert_eq "42" "$STATUS" "invalid wait still launches after gate"
echo "$OUTPUT" | grep -q "invalid BRIDGE_WAIT_SECONDS=0" || fail "invalid wait warning"
echo "$OUTPUT" | grep -q "wait_seconds=180" || fail "fallback wait_seconds=180"
pass "invalid BRIDGE_WAIT_SECONDS warns and falls back to 180"
rm -rf "$CASE_DIR"

echo "=== test 15b: field 22 starttime and identity are discriminant ==="
setup_case
write_mt5_proc "$PROC_ROOT" 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
assert_eq "1000" "$(independent_stat_field "${PROC_ROOT}/100/stat" 22)" "independent field22=1000"
assert_eq "1000" "$(call_bridge_starttime 100)" "bridge_proc_starttime(100)=1000"
assert_eq "100:1000" "$(call_bridge_identity 100)" "identity=100:1000"
id1="$(call_bridge_identity 100)"
write_mt5_proc "$PROC_ROOT" 100 2000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
assert_eq "2000" "$(independent_stat_field "${PROC_ROOT}/100/stat" 22)" "independent field22=2000"
assert_eq "2000" "$(call_bridge_starttime 100)" "bridge_proc_starttime(100)=2000"
assert_eq "100:2000" "$(call_bridge_identity 100)" "identity=100:2000"
id2="$(call_bridge_identity 100)"
[ "$id1" != "$id2" ] || fail "identities must differ after starttime rewrite"
assert_eq "100:1000" "$id1" "id1 frozen"
assert_eq "100:2000" "$id2" "id2 rewritten"
pass "field22 1000→2000; identities 100:1000 != 100:2000"
rm -rf "$CASE_DIR"

echo "=== test 15c: comm with spaces still yields field 22 ==="
setup_case
mkdir -p "${PROC_ROOT}/101"
write_linux_proc_stat "${PROC_ROOT}/101/stat" 101 "Meta Trader" S 3000
assert_eq "3000" "$(independent_stat_field "${PROC_ROOT}/101/stat" 22)" "independent field22 with spaces"
assert_eq "Meta Trader" "$(independent_stat_field "${PROC_ROOT}/101/stat" 2)" "comm preserves spaces"
assert_eq "3000" "$(call_bridge_starttime 101)" "bridge_proc_starttime with spaced comm"
assert_eq "101:3000" "$(call_bridge_identity 101)" "identity with spaced comm"
pass "comm with spaces: starttime=3000"
rm -rf "$CASE_DIR"

echo "=== test 15d: comm containing ) uses last parenthesis ==="
setup_case
mkdir -p "${PROC_ROOT}/102"
write_linux_proc_stat "${PROC_ROOT}/102/stat" 102 "Meta)Trader" S 4000
assert_eq "4000" "$(independent_stat_field "${PROC_ROOT}/102/stat" 22)" "independent field22 with ) in comm"
assert_eq "Meta)Trader" "$(independent_stat_field "${PROC_ROOT}/102/stat" 2)" "comm keeps inner )"
assert_eq "4000" "$(call_bridge_starttime 102)" "production last-) parse"
assert_eq "102:4000" "$(call_bridge_identity 102)" "identity with ) in comm"
pass "comm with ) : starttime=4000 via last parenthesis"
rm -rf "$CASE_DIR"

echo "=== test 15e: fake field22 matches Linux /proc/self/stat layout ==="
setup_case
write_mt5_proc "$PROC_ROOT" 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
real_start="$(independent_stat_field /proc/self/stat 22)"
case "${real_start}" in
    ''|*[!0-9]*) fail "real /proc/self/stat field22 must be numeric, got '${real_start}'" ;;
esac
real_state="$(independent_stat_field /proc/self/stat 3)"
[ -n "$real_state" ] || fail "real /proc/self/stat field3 (state) missing"
fake_start="$(independent_stat_field "${PROC_ROOT}/100/stat" 22)"
assert_eq "1000" "$fake_start" "fake field22 is the supplied starttime"
fake_pid="$(independent_stat_field "${PROC_ROOT}/100/stat" 1)"
assert_eq "100" "$fake_pid" "fake field1 is pid"
pass "Linux self field22 numeric; fake field22=1000 at same slot"
rm -rf "$CASE_DIR"

echo "=== test 16: PID replacement does not inherit stability ==="
setup_case
write_mt5_proc "$PROC_ROOT" 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
BRIDGE_WAIT_SECONDS=30
BRIDGE_MT5_PROCESS_STABLE_SECONDS=3
BRIDGE_PROCESS_POLL_SECONDS=1
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "candidate_pid=100" || fail "chose PID100"
sleep 1.2
rm -rf "${PROC_ROOT}/100"
write_mt5_proc "$PROC_ROOT" 200 2000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
wait_for_log "${CASE_DIR}/wrapper.log" "candidate_pid=200" || fail "switched to PID200"
sleep 1.2
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "PID200 must not inherit PID100 stable_for"
grep -q "candidate_identity_changed=1" "${CASE_DIR}/wrapper.log" || fail "identity change logged"
set +e
wait "$WRAPPER_PID"
STATUS=$?
set -e
assert_eq "42" "$STATUS" "PID200 eventually starts after own window"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "one server after PID200 window"
wine_probe_forbidden
pass "B: PID replacement resets stability"
rm -rf "$CASE_DIR"

echo "=== test 17: same PID new starttime resets identity (discriminant) ==="
setup_case
write_mt5_proc "$PROC_ROOT" 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
assert_eq "1000" "$(independent_stat_field "${PROC_ROOT}/100/stat" 22)" "preflight field22=1000"
assert_eq "100:1000" "$(call_bridge_identity 100)" "preflight identity 100:1000"
BRIDGE_WAIT_SECONDS=30
BRIDGE_MT5_PROCESS_STABLE_SECONDS=4
BRIDGE_PROCESS_POLL_SECONDS=1
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "candidate_pid=100" || fail "initial identity"
t0="$(date +%s)"
changed1="$(grep -c 'candidate_identity_changed=1' "${CASE_DIR}/wrapper.log" || true)"
[ "${changed1:-0}" -ge 1 ] || fail "first candidate_identity_changed missing"
sleep 2
write_mt5_proc "$PROC_ROOT" 100 2000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
assert_eq "2000" "$(independent_stat_field "${PROC_ROOT}/100/stat" 22)" "rewritten field22=2000"
assert_eq "100:2000" "$(call_bridge_identity 100)" "rewritten identity 100:2000"
wait_for_log_count "${CASE_DIR}/wrapper.log" "candidate_identity_changed=1" 2 || \
    fail "second candidate_identity_changed missing after starttime rewrite"
wait_for_log_count "${CASE_DIR}/wrapper.log" "candidate_pid=100" 2 || \
    fail "PID100 must be re-selected as a new identity"
now="$(date +%s)"
remain=$((t0 + 5 - now))
if [ "$remain" -gt 0 ]; then
    sleep "$remain"
fi
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "no launch at old inherited deadline (~4s)"
set +e
wait "$WRAPPER_PID"
STATUS=$?
set -e
assert_eq "42" "$STATUS" "reused PID starts after new window"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "one server after starttime reset"
changed2="$(grep -c 'candidate_identity_changed=1' "${CASE_DIR}/wrapper.log" || true)"
[ "${changed2:-0}" -ge 2 ] || fail "expected >=2 identity changes, got ${changed2:-0}"
pass "C: same PID new starttime resets; no launch at old deadline"
rm -rf "$CASE_DIR"

echo "=== test 18: verified normal + updater blocks; fresh window after updater gone ==="
setup_case
write_mt5_proc "$PROC_ROOT" 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
write_mt5_proc "$PROC_ROOT" 200 1000 updater "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/update"
BRIDGE_WAIT_SECONDS=30
BRIDGE_MT5_PROCESS_STABLE_SECONDS=2
BRIDGE_PROCESS_POLL_SECONDS=1
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "reason=updater_active" || fail "updater blocks"
sleep 2.2
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "coexistence must not launch"
rm -rf "${PROC_ROOT}/200"
sleep 1.2
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "must not reuse pre-updater time"
set +e
wait "$WRAPPER_PID"
STATUS=$?
set -e
assert_eq "42" "$STATUS" "fresh window after updater removed"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "server after new window"
grep -q "updater_count=1" "${CASE_DIR}/wrapper.log" || fail "updater_count logged"
pass "D/E: updater coexistence blocks; removal starts new window"
rm -rf "$CASE_DIR"

echo "=== test 19: bash helper mentioning terminal64.exe is rejected ==="
setup_case
write_mt5_proc "$PROC_ROOT" 300 1000 helper_bash "bash" "-c" "terminal64.exe /portable"
BRIDGE_WAIT_SECONDS=30
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "state=WAITING_FOR_MT5_PROCESS" || fail "waiting"
sleep 2.2
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "bash helper must not admit"
kill -TERM "$WRAPPER_PID"
wait "$WRAPPER_PID" 2>/dev/null || true
wine_probe_forbidden
pass "F: bash false candidate rejected"
rm -rf "$CASE_DIR"

echo "=== test 20: python helper mentioning terminal64.exe is rejected ==="
setup_case
write_mt5_proc "$PROC_ROOT" 301 1000 helper_python "python3" "-c" "terminal64.exe /portable"
BRIDGE_WAIT_SECONDS=30
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "state=WAITING_FOR_MT5_PROCESS" || fail "waiting"
sleep 2.2
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "python helper must not admit"
kill -TERM "$WRAPPER_PID"
wait "$WRAPPER_PID" 2>/dev/null || true
wine_probe_forbidden
pass "G: python false candidate rejected"
rm -rf "$CASE_DIR"

echo "=== test 21: multiple normals keep smallest PID; disappearance switches ==="
setup_case
write_mt5_proc "$PROC_ROOT" 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
write_mt5_proc "$PROC_ROOT" 200 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
BRIDGE_WAIT_SECONDS=30
BRIDGE_MT5_PROCESS_STABLE_SECONDS=2
BRIDGE_PROCESS_POLL_SECONDS=1
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "candidate_pid=100" || fail "deterministic smallest PID"
sleep 0.4
rm -rf "${PROC_ROOT}/200"
sleep 0.8
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "removing extra candidate must not reset PID100"
# Let PID100 finish its original window.
set +e
wait "$WRAPPER_PID"
STATUS=$?
set -e
assert_eq "42" "$STATUS" "PID100 completes original window"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "one server"
echo "$(grep candidate_pid= "${CASE_DIR}/wrapper.log" || true)" | grep -q "candidate_pid=200" && \
  fail "must not switch to PID200 while PID100 remains"
pass "H: multiple normals stay on smallest PID"
rm -rf "$CASE_DIR"

echo "=== test 22: chosen normal disappearance starts new window on remaining ==="
setup_case
write_mt5_proc "$PROC_ROOT" 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
write_mt5_proc "$PROC_ROOT" 200 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
BRIDGE_WAIT_SECONDS=30
BRIDGE_MT5_PROCESS_STABLE_SECONDS=2
BRIDGE_PROCESS_POLL_SECONDS=1
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "candidate_pid=100" || fail "chose 100"
sleep 0.4
rm -rf "${PROC_ROOT}/100"
wait_for_log "${CASE_DIR}/wrapper.log" "candidate_pid=200" || fail "switched to 200"
sleep 0.8
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "PID200 needs a full new window"
set +e
wait "$WRAPPER_PID"
STATUS=$?
set -e
assert_eq "42" "$STATUS" "PID200 after new window"
pass "I: chosen process disappearance resets to remaining identity"
rm -rf "$CASE_DIR"

echo "=== test 23: zombie looking like terminal is ignored ==="
setup_case
write_mt5_proc "$PROC_ROOT" 400 1000 zombie "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
BRIDGE_WAIT_SECONDS=30
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "state=WAITING_FOR_MT5_PROCESS" || fail "waiting"
sleep 2.2
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "zombie must not admit"
kill -TERM "$WRAPPER_PID"
wait "$WRAPPER_PID" 2>/dev/null || true
wine_probe_forbidden
pass "J: zombie rejected"
rm -rf "$CASE_DIR"

echo "=== test 24: unreadable/broken exe is not verified ==="
setup_case
write_mt5_proc "$PROC_ROOT" 401 1000 unreadable "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
write_mt5_proc "$PROC_ROOT" 402 1000 broken_exe "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
BRIDGE_WAIT_SECONDS=30
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
run_bridge_bg
wait_for_log "${CASE_DIR}/wrapper.log" "state=WAITING_FOR_MT5_PROCESS" || fail "waiting"
sleep 2.2
assert_eq "0" "$(cat "${CASE_DIR}/bridge_count")" "unreadable exe must not admit"
kill -TERM "$WRAPPER_PID"
wait "$WRAPPER_PID" 2>/dev/null || true
wine_probe_forbidden
pass "K: unreadable/broken exe rejected"
rm -rf "$CASE_DIR"

echo "=== test 25: nullglob restored; empty proc does not abort ==="
setup_case
# shellcheck source=/dev/null
BRIDGE_PROC_ROOT="$PROC_ROOT" bash -c '
set -Eeuo pipefail
source "$1"
if shopt -q nullglob; then echo BEFORE=on; else echo BEFORE=off; fi
scan_mt5_processes
if shopt -q nullglob; then echo AFTER=on; else echo AFTER=off; fi
echo UPDATERS=${SCAN_UPDATER_COUNT}
echo NORMALS=${SCAN_NORMAL_COUNT}
' _ "$SCRIPT" >"${CASE_DIR}/nullglob.off"
grep -qx "BEFORE=off" "${CASE_DIR}/nullglob.off" || fail "nullglob starts off"
grep -qx "AFTER=off" "${CASE_DIR}/nullglob.off" || fail "nullglob restored off"
grep -qx "UPDATERS=0" "${CASE_DIR}/nullglob.off" || fail "empty scan updater 0"
grep -qx "NORMALS=0" "${CASE_DIR}/nullglob.off" || fail "empty scan normal 0"
BRIDGE_PROC_ROOT="$PROC_ROOT" bash -c '
set -Eeuo pipefail
source "$1"
shopt -s nullglob
if shopt -q nullglob; then echo BEFORE=on; else echo BEFORE=off; fi
scan_mt5_processes
if shopt -q nullglob; then echo AFTER=on; else echo AFTER=off; fi
' _ "$SCRIPT" >"${CASE_DIR}/nullglob.on"
grep -qx "BEFORE=on" "${CASE_DIR}/nullglob.on" || fail "nullglob starts on"
grep -qx "AFTER=on" "${CASE_DIR}/nullglob.on" || fail "nullglob restored on"
BODY="$(executable_body "$SCRIPT")"
echo "$BODY" | grep -Fq 'eval ' && fail "must not eval nullglob restore"
echo "$BODY" | grep -Fq 'shopt -p nullglob' && fail "must not use shopt -p"
pass "nullglob restore explicit; empty proc scan nonfatal"
rm -rf "$CASE_DIR"

echo "=== test 26: bash helper with /update does not DoS as updater ==="
setup_case
write_mt5_proc "$PROC_ROOT" 100 1000 normal "C:\\Program Files\\MetaTrader 5\\terminal64.exe" "/portable"
write_mt5_proc "$PROC_ROOT" 300 1000 helper_bash "bash" "terminal64.exe" "/update"
BRIDGE_MT5_PROCESS_STABLE_SECONDS=1
run_bridge
assert_eq "42" "$STATUS" "helper updater substring must not block verified normal"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "server starts despite helper /update"
pass "helper /update substring is not a verified updater"
rm -rf "$CASE_DIR"

echo "=== test 27: static safety ==="
BODY="$(executable_body "$SCRIPT")"
echo "$BODY" | grep -Eq 's6-svc|s6-rc' && fail "no s6-svc/s6-rc"
echo "$BODY" | grep -Fq 'notification-fd' && fail "no notification-fd"
echo "$BODY" | grep -Fq 'wineserver -k' && fail "no wineserver-k"
echo "$BODY" | grep -Eq 'wineboot|pkill' && fail "no wineboot/pkill"
echo "$BODY" | grep -Fq 'kill -KILL' && fail "no SIGKILL"
echo "$BODY" | grep -Eq 'kill -TERM -- -|kill -- -' && fail "no process-group kill"
echo "$BODY" | grep -Fq 'exec wine python mt5_bridge.py' && fail "must not final-exec bridge"
grep -Fq 'wine python mt5_bridge.py &' "$SCRIPT" || fail "must spawn server child"
grep -Fq 'wait "${CURRENT_BRIDGE_CHILD_PID}"' "$SCRIPT" || fail "must wait owned child"
echo "$BODY" | grep -Eq 'MetaTrader5|mt5\.initialize|terminal_info|mt5\.shutdown' && \
  fail "start_bridge body must not call MT5 Python API"
grep -Eq 'MetaTrader5|mt5\.initialize|terminal_info|mt5\.shutdown' "$SCRIPT" && \
  fail "start_bridge file must not mention MT5 Python API"
echo "$BODY" | grep -Fq 'wine python -' && fail "must not spawn wine python -"
echo "$BODY" | grep -Fq 'run_readiness_probe' && fail "readiness probe helper must be gone"
echo "$BODY" | grep -Fq 'scan_mt5_processes' || fail "scan_mt5_processes missing"
echo "$BODY" | grep -Fq 'bridge_process_identity' || fail "identity helper missing"
echo "$BODY" | grep -Fq 'bridge_is_verified_mt5_process' || fail "verified predicate missing"
echo "$BODY" | grep -Fq 'reason=updater_active' || fail "updater block missing"
echo "$BODY" | grep -Fq 'eval ' && fail "no eval restore"
TESTS_RUN=$((TESTS_RUN + 17))
pass "static safety: process gate, spawn/wait, no API preflight"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
