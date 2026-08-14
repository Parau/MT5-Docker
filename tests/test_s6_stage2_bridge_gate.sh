#!/bin/bash
# Deterministic tests for the S6_STAGE2_HOOK bridge gate script.
#
# Data flow: runs production s6_stage2_bridge_gate.sh against temp bundle/service
# trees. Limitations: no /init, no s6-rc-compile; packaging seams only.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${ROOT}/images/mt5-headless/scripts/s6_stage2_bridge_gate.sh"

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

setup_packaging() {
    CASE_DIR="$(mktemp -d /tmp/bridge-gate.XXXXXX)"
    BUNDLE_DIR="${CASE_DIR}/contents.d"
    SERVICE_DIR="${CASE_DIR}/bridge"
    mkdir -p "$BUNDLE_DIR" "$SERVICE_DIR"
    echo longrun >"${SERVICE_DIR}/type"
    cat >"${SERVICE_DIR}/run" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "${SERVICE_DIR}/run"
    : >"${BUNDLE_DIR}/bridge"
}

run_gate() {
    local run_mt5="$1"
    local run_bridge="$2"
    RUN_MT5="$run_mt5" \
    RUN_BRIDGE="$run_bridge" \
    BRIDGE_GATE_BUNDLE_DIR="$BUNDLE_DIR" \
    BRIDGE_GATE_MARKER="${BUNDLE_DIR}/bridge" \
    BRIDGE_GATE_SERVICE_DIR="$SERVICE_DIR" \
    bash "$GATE"
}

echo "=== test 1: 1/1 enabled ==="
setup_packaging
set +e
OUTPUT="$(run_gate 1 1 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "1/1 exit"
test -e "${BUNDLE_DIR}/bridge" || fail "marker missing when enabled"
echo "$OUTPUT" | grep -q "state=ENABLED run_mt5=1 run_bridge=1" || fail "enabled log"
pass "1/1 enables bridge marker"
rm -rf "$CASE_DIR"

echo "=== test 2: 1/0 disabled ==="
setup_packaging
set +e
OUTPUT="$(run_gate 1 0 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "1/0 exit"
test ! -e "${BUNDLE_DIR}/bridge" || fail "marker must be removed"
echo "$OUTPUT" | grep -q "state=DISABLED" || fail "disabled log"
echo "$OUTPUT" | grep -q "reason=run_bridge_disabled" || fail "reason"
pass "1/0 disables bridge marker"
rm -rf "$CASE_DIR"

echo "=== test 3: 0/1 disabled ==="
setup_packaging
set +e
OUTPUT="$(run_gate 0 1 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "0/1 exit"
test ! -e "${BUNDLE_DIR}/bridge" || fail "marker must be removed"
echo "$OUTPUT" | grep -q "reason=run_mt5_disabled" || fail "mt5 reason"
pass "0/1 disables bridge marker"
rm -rf "$CASE_DIR"

echo "=== test 4: 0/0 disabled ==="
setup_packaging
set +e
OUTPUT="$(run_gate 0 0 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "0/0 exit"
test ! -e "${BUNDLE_DIR}/bridge" || fail "marker must be removed"
echo "$OUTPUT" | grep -q "reason=run_mt5_and_run_bridge_disabled" || fail "both reason"
pass "0/0 disables bridge marker"
rm -rf "$CASE_DIR"

echo "=== test 5: enabled idempotent ==="
setup_packaging
run_gate 1 1 >/dev/null
set +e
OUTPUT="$(run_gate 1 1 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "enabled twice"
test -e "${BUNDLE_DIR}/bridge" || fail "marker must remain"
pass "enabled is idempotent"
rm -rf "$CASE_DIR"

echo "=== test 6: disabled idempotent ==="
setup_packaging
run_gate 1 0 >/dev/null
set +e
OUTPUT="$(run_gate 1 0 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "disabled twice"
test ! -e "${BUNDLE_DIR}/bridge" || fail "marker must stay absent"
pass "disabled is idempotent"
rm -rf "$CASE_DIR"

echo "=== test 7: packaging service missing → nonzero ==="
setup_packaging
rm -rf "$SERVICE_DIR"
set +e
OUTPUT="$(run_gate 1 1 2>&1)"
STATUS=$?
set -e
assert_eq "1" "$STATUS" "missing service dir"
echo "$OUTPUT" | grep -q "state=FAILED" || fail "failed log"
echo "$OUTPUT" | grep -q "bridge_service_dir_missing" || fail "missing reason"
pass "missing service definition fails enabled gate"
rm -rf "$CASE_DIR"

echo "=== test 8: packaging bundle dir missing → nonzero ==="
setup_packaging
rm -rf "$BUNDLE_DIR"
set +e
OUTPUT="$(run_gate 1 1 2>&1)"
STATUS=$?
set -e
assert_eq "1" "$STATUS" "missing bundle dir"
echo "$OUTPUT" | grep -q "bundle_dir_missing" || fail "bundle reason"
pass "missing bundle dir fails enabled gate"
rm -rf "$CASE_DIR"

echo "=== test 9: incomplete run (not executable) → nonzero ==="
setup_packaging
chmod a-x "${SERVICE_DIR}/run"
set +e
OUTPUT="$(run_gate 1 1 2>&1)"
STATUS=$?
set -e
assert_eq "1" "$STATUS" "non-exec run"
echo "$OUTPUT" | grep -q "bridge_service_definition_incomplete" || fail "incomplete reason"
pass "non-executable run fails enabled gate"
rm -rf "$CASE_DIR"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
