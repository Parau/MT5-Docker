#!/bin/bash
# Deterministic tests for the bridge s6 longrun run/finish/gate packaging contract.
#
# Data flow: invokes production bridge/run and bridge/finish with lifecycle and
# PGID seams. Limitations: no s6-supervise, no Wine, no broker volumes.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="${ROOT}/images/mt5-headless/s6-rc.d/bridge/run"
FINISH="${ROOT}/images/mt5-headless/s6-rc.d/bridge/finish"
ENTRYPOINT="${ROOT}/images/mt5-headless/entrypoint.sh"
TYPE_FILE="${ROOT}/images/mt5-headless/s6-rc.d/bridge/type"
DEP_FILE="${ROOT}/images/mt5-headless/s6-rc.d/bridge/dependencies.d/metatrader"
BUNDLE_FILE="${ROOT}/images/mt5-headless/user-bundles.d/user/contents.d/bridge"
SERVICE_DIR="${ROOT}/images/mt5-headless/s6-rc.d/bridge"

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
assert_eq "longrun" "$TYPE_VAL" "bridge type"
pass "type=longrun"

echo "=== test 2: dependency metatrader ==="
test -e "$DEP_FILE" || fail "missing dependencies.d/metatrader"
TESTS_RUN=$((TESTS_RUN + 1))
pass "direct dependency is metatrader"

echo "=== test 3: user bundle marker ==="
test -e "$BUNDLE_FILE" || fail "missing user-bundles marker"
TESTS_RUN=$((TESTS_RUN + 1))
pass "user bundle contains bridge"

echo "=== test 4: run uses with-contenv ==="
head -n 1 "$RUN" | tr -d '\r' | grep -Fq '#!/command/with-contenv bash' || fail "run shebang"
TESTS_RUN=$((TESTS_RUN + 1))
pass "run uses with-contenv"

echo "=== test 5: run execs lifecycle once ==="
CASE_DIR="$(mktemp -d /tmp/bridge-s6.XXXXXX)"
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
    BRIDGE_LIFECYCLE_SCRIPT="${CASE_DIR}/fake-lifecycle.sh" \
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
pass "run execs lifecycle and propagates status"
rm -rf "$CASE_DIR"

echo "=== test 6: no RUN_BRIDGE gate in run ==="
BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$RUN")"
echo "$BODY" | grep -Eq 'RUN_BRIDGE' && fail "run must not gate RUN_BRIDGE"
TESTS_RUN=$((TESTS_RUN + 1))
pass "RUN_BRIDGE gate is not in bridge/run"

echo "=== test 7: no notification-fd ==="
for banned in notification-fd down timeout-kill flag-timeout-killpg down-signal; do
    if [ -e "${SERVICE_DIR}/${banned}" ]; then
        fail "unexpected ${banned}"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
done
pass "no notification-fd/down/timeout-kill/down-signal"

echo "=== test 8: finish valid PGID cleanup ==="
CASE_DIR="$(mktemp -d /tmp/bridge-s6.XXXXXX)"
setsid bash -c 'sleep 300' >/dev/null 2>&1 &
CHILD=$!
# Wait until child exists, then read its PGID (session leader == pgid).
for _i in $(seq 1 50); do
    if kill -0 "$CHILD" 2>/dev/null; then
        break
    fi
    sleep 0.05
done
PGID="$(awk '{ print $5; exit }' "/proc/${CHILD}/stat")"
test -n "$PGID" || fail "could not read child pgid"
set +e
OUTPUT="$(BRIDGE_FINISH_QUIESCE_TIMEOUT_SECONDS=2 bash "$FINISH" 42 0 /tmp/bridge-svc "$PGID" 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "finish quiescent exit"
echo "$OUTPUT" | grep -q "cleanup_result=quiescent" || fail "quiescent log: ${OUTPUT}"
echo "$OUTPUT" | grep -q "restart_allowed=1" || fail "restart allowed log"
if kill -0 "$CHILD" 2>/dev/null; then
    kill -KILL -- "-${PGID}" 2>/dev/null || true
    fail "old child must be gone"
fi
TESTS_RUN=$((TESTS_RUN + 2))
pass "finish kills isolated PGID and exits 0"
rm -rf "$CASE_DIR"

echo "=== test 9: finish signalled run cleanup ==="
CASE_DIR="$(mktemp -d /tmp/bridge-s6.XXXXXX)"
setsid bash -c 'sleep 300' >/dev/null 2>&1 &
CHILD=$!
for _i in $(seq 1 50); do
    kill -0 "$CHILD" 2>/dev/null && break
    sleep 0.05
done
PGID="$(awk '{ print $5; exit }' "/proc/${CHILD}/stat")"
set +e
OUTPUT="$(bash "$FINISH" 256 15 /tmp/bridge-svc "$PGID" 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "signalled finish exit"
echo "$OUTPUT" | grep -q "cleanup_result=quiescent" || fail "signalled quiescent"
TESTS_RUN=$((TESTS_RUN + 1))
pass "finish cleans up after signalled run"
rm -rf "$CASE_DIR"

echo "=== test 10: finish invalid PGID → 125 ==="
for bad in '' abc 0 1; do
    set +e
    OUTPUT="$(bash "$FINISH" 42 0 /tmp/bridge-svc "$bad" 2>&1)"
    STATUS=$?
    set -e
    assert_eq "125" "$STATUS" "invalid pgid '${bad}'"
    echo "$OUTPUT" | grep -q "cleanup_result=unsafe_no_restart" || fail "unsafe log for '${bad}'"
done
pass "invalid PGID refuses cleanup with exit 125"

echo "=== test 11: finish refuses caller/self PGID ==="
# Run finish inside an isolated session and ask it to clean that same PGID.
set +e
OUTPUT="$(
    setsid bash -c '
        pgid="$(awk "{ print \$5; exit }" /proc/self/stat)"
        exec bash "'"$FINISH"'" 42 0 /tmp/bridge-svc "$pgid"
    ' 2>&1
)"
STATUS=$?
set -e
assert_eq "125" "$STATUS" "self pgid refused"
echo "$OUTPUT" | grep -q "reason=pgid_matches_finish" || fail "self-pgid reason: ${OUTPUT}"
kill -0 "$$" 2>/dev/null || fail "test runner must survive"
TESTS_RUN=$((TESTS_RUN + 2))
pass "finish does not kill caller process group"

echo "=== test 12: finish never halts container ==="
BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$FINISH")"
echo "$BODY" | grep -Eq '\bhalt\b|/run/s6/basedir/bin/halt' && fail "finish must not halt"
TESTS_RUN=$((TESTS_RUN + 1))
pass "finish does not halt container"

echo "=== test 13: finish no wineserver-k / pkill / MT5 kill ==="
echo "$BODY" | grep -Fq 'wineserver' && fail "finish wineserver"
echo "$BODY" | grep -Eq 'pkill|wineboot' && fail "finish pkill/wineboot"
echo "$BODY" | grep -Fq 'terminal64' && fail "finish must not target MT5"
TESTS_RUN=$((TESTS_RUN + 3))
pass "finish only targets old bridge PGID"

echo "=== test 14: entrypoint has no bridge ownership ==="
grep -Fq '/scripts/start_bridge.sh &' "$ENTRYPOINT" && fail "CMD must not background bridge"
grep -Fq 'BRIDGE_PID' "$ENTRYPOINT" && fail "CMD must not use BRIDGE_PID"
grep -Fq 'cmd_wait_bridge_wrapper' "$ENTRYPOINT" && fail "CMD must not wait bridge wrapper"
grep -Fq 'targeting bridge lifecycle wrapper' "$ENTRYPOINT" && fail "CMD must not target wrapper"
grep -Fq "Bridge RPyC é gerenciada pelo longrun s6 'bridge'" "$ENTRYPOINT" || fail "s6 bridge ownership message"
TESTS_RUN=$((TESTS_RUN + 5))
pass "entrypoint no longer owns the bridge"

echo "=== test 15: CMD barrier and wineserver-k remain ==="
grep -Fq 'cmd_liveness_barrier' "$ENTRYPOINT" || fail "barrier missing"
grep -Fq 'wineserver -k || true' "$ENTRYPOINT" || fail "global wineserver-k missing"
grep -Fq 'trap cleanup EXIT' "$ENTRYPOINT" || fail "cleanup trap missing"
TESTS_RUN=$((TESTS_RUN + 3))
pass "CMD barrier and global wineserver-k preserved"

echo "=== test 16: production defaults ==="
grep -Fq 'BRIDGE_LIFECYCLE_SCRIPT:-/scripts/start_bridge.sh' "$RUN" || fail "lifecycle default"
grep -Fq 'BRIDGE_FINISH_QUIESCE_TIMEOUT_SECONDS:-2' "$FINISH" || fail "quiesce default"
TESTS_RUN=$((TESTS_RUN + 2))
pass "production defaults frozen"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
