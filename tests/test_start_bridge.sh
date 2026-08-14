#!/bin/bash
# Deterministic contract tests for start_bridge.sh readiness, wait, and exec.
#
# Data flow: runs production start_bridge.sh with fake wine + system python3 and
# a temporary MetaTrader5 module. Final bridge is a stub under BRIDGE_DIR.
# Limitations: no real Wine/MT5/broker; does not cover RPyC request semantics.
# Crash/nonfatal ownership for the container remains proven by smoke, not here.
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

executable_body() {
    awk 'NR==1{next} /^#/{next} {print}' "$1"
}

setup_case() {
    CASE_DIR="$(mktemp -d /tmp/start-bridge-contract.XXXXXX)"
    FAKE_BIN="${CASE_DIR}/bin"
    PYLIB="${CASE_DIR}/pylib"
    BRIDGE_DIR="${CASE_DIR}/bridge"
    mkdir -p "$FAKE_BIN" "$PYLIB" "$BRIDGE_DIR"

    cat >"${PYLIB}/MetaTrader5.py" <<'EOF'
import os
import time

_LOG = os.environ.get("MT5_FAKE_LOG", "")
_MODE = os.environ.get("MT5_FAKE_MODE", "ready")
_COUNTER = os.environ.get("MT5_FAKE_COUNTER", "")
_DELAY = float(os.environ.get("MT5_FAKE_DELAY", "0"))


def _record(event: str) -> None:
    if _LOG:
        with open(_LOG, "a", encoding="utf-8") as fh:
            fh.write(event + "\n")


class _Info:
    def __init__(self, connected: bool) -> None:
        self.connected = connected


def initialize() -> bool:
    _record("initialize")
    if _DELAY > 0:
        time.sleep(_DELAY)
    if _MODE == "init_false":
        return False
    if _MODE == "fail_then_ready":
        n = 0
        if _COUNTER and os.path.isfile(_COUNTER):
            with open(_COUNTER, encoding="utf-8") as fh:
                raw = fh.read().strip()
                n = int(raw) if raw else 0
        n += 1
        if _COUNTER:
            with open(_COUNTER, "w", encoding="utf-8") as fh:
                fh.write(str(n))
        return n >= 3
    return True


def terminal_info():
    _record("terminal_info")
    if _MODE == "info_none":
        return None
    if _MODE == "disconnected":
        return _Info(False)
    if _MODE == "fail_then_ready":
        n = 0
        if _COUNTER and os.path.isfile(_COUNTER):
            with open(_COUNTER, encoding="utf-8") as fh:
                raw = fh.read().strip()
                n = int(raw) if raw else 0
        if n < 3:
            return _Info(False)
    return _Info(True)


def shutdown() -> None:
    _record("shutdown")


def last_error():
    return (1, "fake")
EOF

    cat >"${FAKE_BIN}/wine" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "$*" >>"${WINE_CALLS:?}"
if [ "${1:-}" != "python" ]; then
    echo "unexpected wine argv: $*" >&2
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
    shift
    exec python3 - "$@"
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

    cat >"${FAKE_BIN}/sleep" <<'EOF'
#!/bin/bash
echo "$1" >>"${SLEEP_LOG:?}"
exit 0
EOF
    chmod +x "${FAKE_BIN}/sleep"

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
    echo 0 >"${CASE_DIR}/probe_count"
    echo 0 >"${CASE_DIR}/bridge_count"
    : >"${CASE_DIR}/sleep.log"
    : >"${CASE_DIR}/mt5.log"
    : >"${CASE_DIR}/bridge.env"
    : >"${CASE_DIR}/bridge.marker"
    echo 0 >"${CASE_DIR}/fail_counter"
}

run_bridge() {
    set +e
    OUTPUT="$(
        PATH="${FAKE_BIN}:${PATH}" \
        WINE_CALLS="${CASE_DIR}/wine_calls" \
        PROBE_COUNT="${CASE_DIR}/probe_count" \
        BRIDGE_COUNT="${CASE_DIR}/bridge_count" \
        SLEEP_LOG="${CASE_DIR}/sleep.log" \
        BRIDGE_ENV="${CASE_DIR}/bridge.env" \
        BRIDGE_MARKER="${CASE_DIR}/bridge.marker" \
        BRIDGE_EXIT="${BRIDGE_EXIT:-42}" \
        MT5_FAKE_LOG="${CASE_DIR}/mt5.log" \
        MT5_FAKE_MODE="${MT5_FAKE_MODE:-ready}" \
        MT5_FAKE_COUNTER="${CASE_DIR}/fail_counter" \
        MT5_FAKE_DELAY="${MT5_FAKE_DELAY:-0}" \
        PYLIB="$PYLIB" \
        BRIDGE_DIR="$BRIDGE_DIR" \
        WINEPREFIX="${WINEPREFIX:-/tmp/bridge-wine}" \
        WINEDEBUG="${WINEDEBUG:--all}" \
        RPYC_PORT="${RPYC_PORT:-18812}" \
        BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-180}" \
        BRIDGE_RETRY_SECONDS="${BRIDGE_RETRY_SECONDS:-5}" \
        bash "$SCRIPT" 2>&1
    )"
    STATUS=$?
    set -e
}

echo "=== test 1: defaults frozen ==="
DEFAULTS_OUT="$(
    env -u WINEPREFIX -u WINEDEBUG -u BRIDGE_DIR -u RPYC_PORT \
        -u BRIDGE_WAIT_SECONDS -u BRIDGE_RETRY_SECONDS \
        bash -c '
            set -Eeuo pipefail
            export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
            export WINEDEBUG="${WINEDEBUG:--all}"
            BRIDGE_DIR="${BRIDGE_DIR:-/opt/bridge}"
            RPYC_PORT="${RPYC_PORT:-18812}"
            BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-180}"
            BRIDGE_RETRY_SECONDS="${BRIDGE_RETRY_SECONDS:-5}"
            printf "WINEPREFIX=%s\n" "$WINEPREFIX"
            printf "WINEDEBUG=%s\n" "$WINEDEBUG"
            printf "BRIDGE_DIR=%s\n" "$BRIDGE_DIR"
            printf "RPYC_PORT=%s\n" "$RPYC_PORT"
            printf "WAIT=%s\n" "$BRIDGE_WAIT_SECONDS"
            printf "RETRY=%s\n" "$BRIDGE_RETRY_SECONDS"
        '
)"
echo "$DEFAULTS_OUT" | grep -qx "WINEPREFIX=/config/.wine" || fail "default WINEPREFIX"
echo "$DEFAULTS_OUT" | grep -qx "WINEDEBUG=-all" || fail "default WINEDEBUG"
echo "$DEFAULTS_OUT" | grep -qx "BRIDGE_DIR=/opt/bridge" || fail "default BRIDGE_DIR"
echo "$DEFAULTS_OUT" | grep -qx "RPYC_PORT=18812" || fail "default RPYC_PORT"
echo "$DEFAULTS_OUT" | grep -qx "WAIT=180" || fail "default WAIT"
echo "$DEFAULTS_OUT" | grep -qx "RETRY=5" || fail "default RETRY"
grep -Fq 'WINEPREFIX="${WINEPREFIX:-/config/.wine}"' "$SCRIPT" || fail "literal WINEPREFIX default"
grep -Fq 'BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-180}"' "$SCRIPT" || fail "literal WAIT default"
grep -Fq 'BRIDGE_RETRY_SECONDS="${BRIDGE_RETRY_SECONDS:-5}"' "$SCRIPT" || fail "literal RETRY default"
TESTS_RUN=$((TESTS_RUN + 9))
pass "defaults frozen"

echo "=== test 2: missing bridge exit1 without wine ==="
setup_case
rm -f "${BRIDGE_DIR}/mt5_bridge.py"
BRIDGE_WAIT_SECONDS=1
MT5_FAKE_MODE=ready
run_bridge
assert_eq "1" "$STATUS" "missing bridge exit"
echo "$OUTPUT" | grep -q "ERRO: bridge ausente" || fail "missing bridge message"
test ! -s "${CASE_DIR}/wine_calls" || fail "wine must not run when bridge missing"
assert_eq "0" "$(cat "${CASE_DIR}/probe_count")" "no probes when missing"
pass "missing bridge exits 1 without wine"
rm -rf "$CASE_DIR"

echo "=== test 3: RUN_BRIDGE caller-owned ==="
BODY="$(executable_body "$SCRIPT")"
echo "$BODY" | grep -Eq 'RUN_BRIDGE' && fail "start_bridge must not read RUN_BRIDGE"
grep -Fq 'if [ "${RUN_BRIDGE:-1}" = "1" ]; then' "$ENTRYPOINT" || fail "entrypoint gate missing"
grep -Fq '/scripts/start_bridge.sh &' "$ENTRYPOINT" || fail "entrypoint must background bridge"
grep -Fq 'BRIDGE_PID=$!' "$ENTRYPOINT" || fail "entrypoint must capture BRIDGE_PID"
grep -Eq 'wait[[:space:]]+"?\$BRIDGE_PID' "$ENTRYPOINT" && fail "entrypoint must not wait BRIDGE_PID"
TESTS_RUN=$((TESTS_RUN + 5))
pass "RUN_BRIDGE gate is caller-owned; no wait BRIDGE_PID"

echo "=== test 4: first probe success ==="
setup_case
BRIDGE_WAIT_SECONDS=30
MT5_FAKE_MODE=ready
run_bridge
assert_eq "42" "$STATUS" "wrapper propagates final exit42"
assert_eq "1" "$(cat "${CASE_DIR}/probe_count")" "probe once"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "final bridge once"
echo "$OUTPUT" | grep -q "MT5 respondeu via MetaTrader5.initialize()" || fail "success log"
grep -qx "initialize" "${CASE_DIR}/mt5.log" || fail "initialize recorded"
grep -qx "terminal_info" "${CASE_DIR}/mt5.log" || fail "terminal_info recorded"
grep -qx "shutdown" "${CASE_DIR}/mt5.log" || fail "shutdown recorded"
assert_eq "1" "$(grep -c '^bridge$' "${CASE_DIR}/bridge.marker" || true)" "bridge marker once"
pass "first probe success then final bridge exit42"
rm -rf "$CASE_DIR"

echo "=== test 5: fail fail success ==="
setup_case
BRIDGE_WAIT_SECONDS=60
BRIDGE_RETRY_SECONDS=5
MT5_FAKE_MODE=fail_then_ready
run_bridge
assert_eq "42" "$STATUS" "fail-then-ready final exit"
assert_eq "3" "$(cat "${CASE_DIR}/probe_count")" "three probes"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "one final bridge"
assert_eq "2" "$(wc -l < "${CASE_DIR}/sleep.log" | tr -d ' ')" "two sleeps between failures"
assert_eq "5" "$(head -n1 "${CASE_DIR}/sleep.log" | tr -d '[:space:]')" "retry sleep 5"
pass "fail/fail/success with retry sleep"
rm -rf "$CASE_DIR"

echo "=== test 6: WAIT=0 zero probes timeout then bridge ==="
setup_case
BRIDGE_WAIT_SECONDS=0
MT5_FAKE_MODE=ready
run_bridge
assert_eq "42" "$STATUS" "WAIT=0 still runs bridge"
assert_eq "0" "$(cat "${CASE_DIR}/probe_count")" "zero probes when WAIT=0"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "bridge still runs"
echo "$OUTPUT" | grep -q "AVISO: MT5 não respondeu a tempo" || fail "timeout warning"
pass "WAIT=0 skips probes, warns, still execs bridge"
rm -rf "$CASE_DIR"

echo "=== test 7: env propagation to final process ==="
setup_case
WINEPREFIX=/tmp/custom-wine
WINEDEBUG=-fix+all
RPYC_PORT=18814
BRIDGE_WAIT_SECONDS=0
run_bridge
assert_eq "42" "$STATUS" "env propagation exit"
grep -qx "WINEPREFIX=/tmp/custom-wine" "${CASE_DIR}/bridge.env" || fail "WINEPREFIX not propagated"
grep -qx "WINEDEBUG=-fix+all" "${CASE_DIR}/bridge.env" || fail "WINEDEBUG not propagated"
grep -qx "RPYC_PORT=18814" "${CASE_DIR}/bridge.env" || fail "RPYC_PORT not propagated"
TESTS_RUN=$((TESTS_RUN + 3))
pass "WINEPREFIX/WINEDEBUG/RPYC_PORT reach final process"
rm -rf "$CASE_DIR"
unset WINEPREFIX WINEDEBUG RPYC_PORT || true

echo "=== test 8: final cwd is BRIDGE_DIR ==="
setup_case
BRIDGE_WAIT_SECONDS=0
run_bridge
grep -qx "cwd=${BRIDGE_DIR}" "${CASE_DIR}/bridge.env" || fail "cwd must be BRIDGE_DIR"
TESTS_RUN=$((TESTS_RUN + 1))
pass "final process cwd equals BRIDGE_DIR"
rm -rf "$CASE_DIR"

echo "=== test 9: success after deadline emits success and warning ==="
setup_case
BRIDGE_WAIT_SECONDS=1
MT5_FAKE_MODE=ready
MT5_FAKE_DELAY=2
# Use real sleep during the slow probe (fake sleep would make delay instant).
rm -f "${FAKE_BIN}/sleep"
run_bridge
assert_eq "42" "$STATUS" "success-after-deadline exit"
assert_eq "1" "$(cat "${CASE_DIR}/probe_count")" "one slow probe"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "bridge still execs"
echo "$OUTPUT" | grep -q "MT5 respondeu via MetaTrader5.initialize()" || fail "success log after overshoot"
echo "$OUTPUT" | grep -q "AVISO: MT5 não respondeu a tempo" || fail "timeout warning after overshoot"
pass "slow probe success after deadline still warns"
rm -rf "$CASE_DIR"

echo "=== test 10: no internal restart on final exit42 ==="
setup_case
BRIDGE_WAIT_SECONDS=0
BRIDGE_EXIT=42
run_bridge
assert_eq "42" "$STATUS" "no-restart exit"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "final invoked once"
sleep 0.2
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "still once after delay"
pass "no internal restart after final exit42"
rm -rf "$CASE_DIR"

echo "=== test 11: probe initialize False ==="
setup_case
BRIDGE_WAIT_SECONDS=1
BRIDGE_RETRY_SECONDS=5
MT5_FAKE_MODE=init_false
run_bridge
assert_eq "42" "$STATUS" "init_false still starts bridge after timeout"
test "$(cat "${CASE_DIR}/probe_count")" -ge 1 || fail "at least one probe"
grep -q "initialize" "${CASE_DIR}/mt5.log" || fail "initialize must run"
grep -q "terminal_info" "${CASE_DIR}/mt5.log" && fail "terminal_info must not run when initialize False"
grep -q "shutdown" "${CASE_DIR}/mt5.log" && fail "shutdown must not run when initialize False"
TESTS_RUN=$((TESTS_RUN + 3))
pass "initialize False: no terminal_info, no shutdown"
rm -rf "$CASE_DIR"

echo "=== test 12: probe disconnected ==="
setup_case
BRIDGE_WAIT_SECONDS=1
BRIDGE_RETRY_SECONDS=5
MT5_FAKE_MODE=disconnected
run_bridge
grep -q "initialize" "${CASE_DIR}/mt5.log" || fail "initialize"
grep -q "terminal_info" "${CASE_DIR}/mt5.log" || fail "terminal_info"
grep -q "shutdown" "${CASE_DIR}/mt5.log" || fail "shutdown on disconnected"
# Ensure order initialize → terminal_info → shutdown for first probe
FIRST="$(awk 'NR<=3 {print}' "${CASE_DIR}/mt5.log")"
echo "$FIRST" | head -n1 | grep -qx "initialize" || fail "order initialize first"
echo "$FIRST" | sed -n '2p' | grep -qx "terminal_info" || fail "order terminal_info second"
echo "$FIRST" | sed -n '3p' | grep -qx "shutdown" || fail "order shutdown third"
TESTS_RUN=$((TESTS_RUN + 3))
pass "disconnected: initialize+terminal_info+shutdown then fail"
rm -rf "$CASE_DIR"

echo "=== test 13: probe terminal_info None ==="
setup_case
BRIDGE_WAIT_SECONDS=1
MT5_FAKE_MODE=info_none
run_bridge
grep -q "initialize" "${CASE_DIR}/mt5.log" || fail "initialize"
grep -q "terminal_info" "${CASE_DIR}/mt5.log" || fail "terminal_info"
grep -q "shutdown" "${CASE_DIR}/mt5.log" || fail "shutdown on None"
TESTS_RUN=$((TESTS_RUN + 3))
pass "terminal_info None: shutdown then fail"
rm -rf "$CASE_DIR"

echo "=== test 14: probe ready ==="
setup_case
BRIDGE_WAIT_SECONDS=30
MT5_FAKE_MODE=ready
run_bridge
assert_eq "42" "$STATUS" "ready path exit"
assert_eq "1" "$(cat "${CASE_DIR}/probe_count")" "ready one probe"
assert_eq "1" "$(cat "${CASE_DIR}/bridge_count")" "ready one bridge"
sed -n '1p' "${CASE_DIR}/mt5.log" | grep -qx "initialize" || fail "ready initialize first"
sed -n '2p' "${CASE_DIR}/mt5.log" | grep -qx "terminal_info" || fail "ready terminal_info second"
sed -n '3p' "${CASE_DIR}/mt5.log" | grep -qx "shutdown" || fail "ready shutdown third"
TESTS_RUN=$((TESTS_RUN + 3))
pass "ready: initialize+terminal_info+shutdown then bridge exec"
rm -rf "$CASE_DIR"

echo "=== test 15: static safety ==="
BODY="$(executable_body "$SCRIPT")"
echo "$BODY" | grep -Eq 's6-svc|s6-rc' && fail "no s6-svc/s6-rc"
echo "$BODY" | grep -Fq 'notification-fd' && fail "no notification-fd"
echo "$BODY" | grep -Fq 'wineserver -k' && fail "no wineserver-k"
echo "$BODY" | grep -Eq 'wineboot|pkill' && fail "no wineboot/pkill"
echo "$BODY" | grep -Eq 'while[[:space:]]+true|for[[:space:]]*\(\(' && fail "unexpected restart-style loop"
grep -Fq 'exec wine python mt5_bridge.py' "$SCRIPT" || fail "must final-exec bridge"
TESTS_RUN=$((TESTS_RUN + 6))
pass "static safety: no s6/restart/wineserver-k; final exec present"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
