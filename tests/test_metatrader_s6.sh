#!/bin/bash
# Deterministic tests for the metatrader s6 longrun run/finish anti-restart contract.
#
# Data flow: invokes production run/finish with MT5_LIFECYCLE_SCRIPT, halt, and
# exitcode seams. Limitations: no s6-supervise, no Wine, no broker volumes.
# LiveUpdate/shutdown contracts remain in the dedicated lifecycle suites.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="${ROOT}/images/mt5-headless/s6-rc.d/metatrader/run"
FINISH="${ROOT}/images/mt5-headless/s6-rc.d/metatrader/finish"
DOCKERFILE="${ROOT}/images/mt5-headless/Dockerfile"
FINALIZER="${ROOT}/images/mt5-headless/cont-finish.d/10-wine-cleanup"
TYPE_FILE="${ROOT}/images/mt5-headless/s6-rc.d/metatrader/type"
DEP_FILE="${ROOT}/images/mt5-headless/s6-rc.d/metatrader/dependencies.d/python-bootstrap"
BUNDLE_FILE="${ROOT}/images/mt5-headless/user-bundles.d/user/contents.d/metatrader"
SERVICE_DIR="${ROOT}/images/mt5-headless/s6-rc.d/metatrader"

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

echo "=== test 1: type is longrun ==="
TYPE_VAL="$(tr -d '\r\n' < "$TYPE_FILE")"
assert_eq "longrun" "$TYPE_VAL" "metatrader type"
pass "type=longrun"

echo "=== test 2: dependency python-bootstrap ==="
test -e "$DEP_FILE" || fail "missing dependencies.d/python-bootstrap"
TESTS_RUN=$((TESTS_RUN + 1))
pass "direct dependency is python-bootstrap"

echo "=== test 3: user bundle marker ==="
test -e "$BUNDLE_FILE" || fail "missing user-bundles marker"
TESTS_RUN=$((TESTS_RUN + 1))
pass "user bundle contains metatrader"

echo "=== test 4: no notification-fd/down/timeout-kill/down-signal ==="
for banned in notification-fd down timeout-kill flag-timeout-killpg down-signal; do
    if [ -e "${SERVICE_DIR}/${banned}" ]; then
        fail "unexpected ${banned}"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
done
pass "no notification-fd/down/timeout-kill/down-signal"

echo "=== test 5: RUN_MT5=0 skips without fake lifecycle ==="
CASE_DIR="$(mktemp -d /tmp/metatrader-s6.XXXXXX)"
cat >"${CASE_DIR}/fake-lifecycle.sh" <<'EOF'
#!/bin/bash
echo called >>"${FAKE_MARKER:?}"
exit 42
EOF
chmod +x "${CASE_DIR}/fake-lifecycle.sh"
: >"${CASE_DIR}/marker"
set +e
OUTPUT="$(
    RUN_MT5=0 \
    MT5_LIFECYCLE_SCRIPT="${CASE_DIR}/fake-lifecycle.sh" \
    FAKE_MARKER="${CASE_DIR}/marker" \
    bash "$RUN" 2>&1
)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "RUN_MT5=0 exit"
echo "$OUTPUT" | grep -q "state=SKIPPED reason=run_mt5_disabled" || fail "skip log"
test ! -s "${CASE_DIR}/marker" || fail "fake lifecycle must not run"
TESTS_RUN=$((TESTS_RUN + 1))
pass "RUN_MT5=0 skips without invoking lifecycle"
rm -rf "$CASE_DIR"

echo "=== test 6: RUN_MT5=1 execs fake lifecycle once and propagates 42 ==="
CASE_DIR="$(mktemp -d /tmp/metatrader-s6.XXXXXX)"
cat >"${CASE_DIR}/fake-lifecycle.sh" <<'EOF'
#!/bin/bash
count=0
if [ -f "${FAKE_COUNT:?}" ]; then
    count="$(cat "$FAKE_COUNT")"
fi
count=$((count + 1))
echo "$count" >"$FAKE_COUNT"
exit 42
EOF
chmod +x "${CASE_DIR}/fake-lifecycle.sh"
echo 0 >"${CASE_DIR}/count"
set +e
OUTPUT="$(
    RUN_MT5=1 \
    MT5_LIFECYCLE_SCRIPT="${CASE_DIR}/fake-lifecycle.sh" \
    FAKE_COUNT="${CASE_DIR}/count" \
    bash "$RUN" 2>&1
)"
STATUS=$?
set -e
assert_eq "42" "$STATUS" "run propagates lifecycle 42"
assert_eq "1" "$(cat "${CASE_DIR}/count")" "lifecycle invoked once"
echo "$OUTPUT" | grep -q "state=EXEC lifecycle=${CASE_DIR}/fake-lifecycle.sh" || fail "exec log"
grep -q '^exec ' "$RUN" || fail "run must exec"
echo "$OUTPUT" | grep -q 'lifecycle &' && fail "run must not background"
TESTS_RUN=$((TESTS_RUN + 2))
pass "RUN_MT5=1 execs lifecycle exactly once; status 42 propagates"
rm -rf "$CASE_DIR"

run_finish() {
    local run_exit="$1"
    local signal="${2:-}"
    CASE_DIR="$(mktemp -d /tmp/metatrader-finish.XXXXXX)"
    EXITCODE_FILE="${CASE_DIR}/exitcode"
    HALT_LOG="${CASE_DIR}/halt.log"
    cat >"${CASE_DIR}/halt.sh" <<'EOF'
#!/bin/bash
echo halt >>"${HALT_LOG:?}"
exit "${HALT_EXIT:-0}"
EOF
    chmod +x "${CASE_DIR}/halt.sh"
    set +e
    if [ -n "$signal" ]; then
        OUTPUT="$(
            METATRADER_EXITCODE_FILE="$EXITCODE_FILE" \
            METATRADER_HALT_BIN="${CASE_DIR}/halt.sh" \
            HALT_LOG="$HALT_LOG" \
            HALT_EXIT="${HALT_EXIT:-0}" \
            bash "$FINISH" "$run_exit" "$signal" 2>&1
        )"
    else
        OUTPUT="$(
            METATRADER_EXITCODE_FILE="$EXITCODE_FILE" \
            METATRADER_HALT_BIN="${CASE_DIR}/halt.sh" \
            HALT_LOG="$HALT_LOG" \
            HALT_EXIT="${HALT_EXIT:-0}" \
            bash "$FINISH" "$run_exit" 2>&1
        )"
    fi
    STATUS=$?
    set -e
}

echo "=== test 7: finish exit0 → exitcode0 halt once finish125 ==="
run_finish 0
assert_eq "125" "$STATUS" "finish 0 → 125"
assert_eq "0" "$(cat "$EXITCODE_FILE")" "exitcode 0"
assert_eq "1" "$(grep -c halt "$HALT_LOG")" "halt once"
echo "$OUTPUT" | grep -q "run_exit=0 signal=0 container_exit=0 action=halt no_restart=1" || fail "finish0 log"
TESTS_RUN=$((TESTS_RUN + 1))
pass "finish maps 0, halt once, exit 125"
rm -rf "$CASE_DIR"

echo "=== test 8: finish exit42 → exitcode42 ==="
run_finish 42
assert_eq "125" "$STATUS" "finish 42 → 125"
assert_eq "42" "$(cat "$EXITCODE_FILE")" "exitcode 42"
assert_eq "1" "$(grep -c halt "$HALT_LOG")" "halt once"
echo "$OUTPUT" | grep -q "run_exit=42 signal=0 container_exit=42 action=halt no_restart=1" || fail "finish42 log"
TESTS_RUN=$((TESTS_RUN + 1))
pass "finish maps 42, halt once, exit 125"
rm -rf "$CASE_DIR"

echo "=== test 9: finish exit70 passthrough without interpretation ==="
run_finish 70
assert_eq "125" "$STATUS" "finish 70 → 125"
assert_eq "70" "$(cat "$EXITCODE_FILE")" "exitcode 70 numeric passthrough"
echo "$OUTPUT" | grep -qi 'update_timeout' && fail "finish must not interpret 70"
TESTS_RUN=$((TESTS_RUN + 1))
pass "finish 70 is numeric passthrough"
rm -rf "$CASE_DIR"

echo "=== test 10: finish 256/15 → exitcode 143 ==="
run_finish 256 15
assert_eq "125" "$STATUS" "finish signal → 125"
assert_eq "143" "$(cat "$EXITCODE_FILE")" "256+SIGTERM → 143"
echo "$OUTPUT" | grep -q "run_exit=256 signal=15 container_exit=143 action=halt no_restart=1" || fail "signal log"
TESTS_RUN=$((TESTS_RUN + 1))
pass "finish maps uncaught SIGTERM to 143"
rm -rf "$CASE_DIR"

echo "=== test 11: halt failure still finish 125 ==="
HALT_EXIT=1
run_finish 42
assert_eq "125" "$STATUS" "halt failure still 125"
assert_eq "42" "$(cat "$EXITCODE_FILE")" "exitcode still written"
echo "$OUTPUT" | grep -q "no_restart=1" || fail "no_restart log"
TESTS_RUN=$((TESTS_RUN + 1))
pass "halt failure does not allow restart (still 125)"
rm -rf "$CASE_DIR"
unset HALT_EXIT || true

echo "=== test 12: no transitional CMD owns lifecycle ==="
test ! -e "${ROOT}/images/mt5-headless/entrypoint.sh" || fail "entrypoint.sh must be deleted"
grep -Fq 'entrypoint.sh' "$DOCKERFILE" && fail "Dockerfile must not copy entrypoint"
grep -Eq '^CMD ' "$DOCKERFILE" && fail "Dockerfile must not declare CMD"
TESTS_RUN=$((TESTS_RUN + 3))
pass "no CMD/entrypoint owns lifecycle"

echo "=== test 13: bridge is s6-owned, not CMD-owned ==="
test -e "${ROOT}/images/mt5-headless/s6-rc.d/bridge/type" || fail "bridge longrun missing"
test -e "${ROOT}/images/mt5-headless/s6-rc.d/bridge/dependencies.d/metatrader" || fail "bridge depends on metatrader"
grep -Fq 'BRIDGE_PID' "$DOCKERFILE" && fail "Dockerfile must not mention BRIDGE_PID"
TESTS_RUN=$((TESTS_RUN + 3))
pass "bridge ownership is s6 longrun"

echo "=== test 14: no CMD liveness barrier; stage3 finalizer present ==="
test ! -e "${ROOT}/images/mt5-headless/entrypoint.sh" || fail "entrypoint absent"
grep -RFq 'cmd_liveness_barrier' "${ROOT}/images/mt5-headless" && fail "cmd_liveness_barrier residue"
test -f "$FINALIZER" || fail "finalizer missing"
grep -Fq 'wineserver -k' "$FINALIZER" || fail "finalizer wineserver-k"
TESTS_RUN=$((TESTS_RUN + 4))
pass "service-only liveness; wineserver-k in stage3 finalizer"

echo "=== test 15: no readiness / notification-fd ==="
BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$RUN"; awk 'NR==1{next} /^#/{next} {print}' "$FINISH")"
echo "$BODY" | grep -Eq 'notification-fd|s6-notify|MetaTrader5\.initialize|terminal_info' && fail "readiness in run/finish"
grep -Fq 'notification-fd' "$FINALIZER" && fail "notification-fd in finalizer"
TESTS_RUN=$((TESTS_RUN + 2))
pass "no readiness/notification-fd in metatrader run/finish/finalizer"

echo "=== test 16: production defaults ==="
grep -Fq 'MT5_LIFECYCLE_SCRIPT:-/scripts/mt5_lifecycle.sh' "$RUN" || fail "lifecycle default"
grep -Fq 'METATRADER_EXITCODE_FILE:-/run/s6-linux-init-container-results/exitcode' "$FINISH" || fail "exitcode default"
grep -Fq 'METATRADER_HALT_BIN:-/run/s6/basedir/bin/halt' "$FINISH" || fail "halt default"
TESTS_RUN=$((TESTS_RUN + 3))
pass "production defaults are official s6 paths"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
