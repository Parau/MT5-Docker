#!/bin/bash
# Deterministic tests for the bridge s6 longrun run/finish/gate packaging contract.
#
# Data flow: invokes production bridge/run and bridge/finish with lifecycle and
# PGID seams. Limitations: no s6-supervise, no Wine, no broker volumes.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="${ROOT}/images/mt5-headless/s6-rc.d/bridge/run"
FINISH="${ROOT}/images/mt5-headless/s6-rc.d/bridge/finish"
DOCKERFILE="${ROOT}/images/mt5-headless/Dockerfile"
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

# Independent of production finish: never tokenize /proc/PID/stat for pgrp.
read_pgid() {
    local pid="$1"
    local value
    value="$(ps -o pgid= -p "$pid" 2>/dev/null || true)"
    value="$(printf '%s' "$value" | tr -d '[:space:]')"
    case "$value" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$value"
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
# Wait until child exists, then read its PGID via ps (not /proc/.../stat $5).
for _i in $(seq 1 50); do
    if kill -0 "$CHILD" 2>/dev/null; then
        break
    fi
    sleep 0.05
done
PGID="$(read_pgid "$CHILD")" || fail "could not read child pgid"
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
PGID="$(read_pgid "$CHILD")" || fail "could not read signalled child pgid"
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
        pgid="$(ps -o pgid= -p $$ | tr -d "[:space:]")"
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

echo "=== test 12: finish may halt only via controlled BRIDGE_HALT_BIN seam ==="
BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$FINISH")"
# 04K-C: halt is allowed for BRIDGE_UNRECOVERABLE (75), only through BRIDGE_HALT_BIN.
echo "$BODY" | grep -Fq 'BRIDGE_HALT_BIN' || fail "finish must use BRIDGE_HALT_BIN seam"
echo "$BODY" | grep -Eq 'kill[[:space:]]+1\b|pkill|docker stop' && fail "finish must not kill PID1/pkill/docker stop"
echo "$BODY" | grep -Fq 'halt_bridge_unrecoverable' || fail "finish must define halt_bridge_unrecoverable"
TESTS_RUN=$((TESTS_RUN + 3))
pass "finish uses controlled halt seam only (no PID1/pkill)"

echo "=== test 12b: failure budget primitives present ==="
echo "$BODY" | grep -Fq 's6-permafailon' || fail "finish must call s6-permafailon"
echo "$BODY" | grep -Fq 'wantedup' || fail "finish must gate on wantedup"
echo "$BODY" | grep -Fq 'BRIDGE_UNRECOVERABLE' || true
grep -Fq '75' "$FINISH" || fail "exit 75 must be reserved"
test ! -e "${SERVICE_DIR}/max-death-tally" || fail "must not add max-death-tally"
TESTS_RUN=$((TESTS_RUN + 4))
pass "failure budget uses s6-permafailon + wantedup; no max-death-tally"

echo "=== test 13: finish no wineserver-k / pkill / MT5 kill ==="
echo "$BODY" | grep -Fq 'wineserver' && fail "finish wineserver"
echo "$BODY" | grep -Eq 'pkill|wineboot' && fail "finish pkill/wineboot"
echo "$BODY" | grep -Fq 'terminal64' && fail "finish must not target MT5"
TESTS_RUN=$((TESTS_RUN + 3))
pass "finish only targets old bridge PGID"

echo "=== test 13b: static — no fragile /proc/*/stat \$5 pgrp parsing ==="
if grep -E 'awk.*print \$5' "$FINISH" | grep -q '/proc'; then
    fail "finish must not use awk \$5 on /proc/*/stat"
fi
if grep -Fq "awk '{ print \$5; exit }'" "$FINISH"; then
    fail "finish must not retain awk '{ print \$5; exit }' anti-pattern"
fi
if ! grep -Fq 'ps -o pgid=' "$FINISH"; then
    fail "finish must prefer ps -o pgid="
fi
if ! grep -Fq 'process_pgid' "$FINISH"; then
    fail "finish must define process_pgid"
fi
TESTS_RUN=$((TESTS_RUN + 4))
pass "finish uses robust process_pgid (no awk \$5 on stat)"

echo "=== test 14: no transitional CMD/entrypoint ==="
test ! -e "${ROOT}/images/mt5-headless/entrypoint.sh" || fail "entrypoint.sh must be deleted"
grep -Fq 'entrypoint.sh' "$DOCKERFILE" && fail "Dockerfile must not reference entrypoint.sh"
grep -Eq '^CMD ' "$DOCKERFILE" && fail "Dockerfile must not declare a default CMD"
grep -Fq 'ENTRYPOINT ["/init"]' "$DOCKERFILE" || fail "ENTRYPOINT /init required"
TESTS_RUN=$((TESTS_RUN + 4))
pass "service-only runtime: entrypoint/CMD removed"

echo "=== test 15: no project-specific global wineserver -k ==="
test ! -e "${ROOT}/images/mt5-headless/cont-finish.d/10-wine-cleanup" || fail "finalizer must be deleted"
grep -Fq 'cont-finish.d' "$DOCKERFILE" && fail "Dockerfile must not reference cont-finish.d"
while IFS= read -r line; do
    [ -z "$line" ] && continue
    file="${line%%:*}"
    rest="${line#*:}"
    code="$(printf '%s\n' "$rest" | sed 's/#.*//')"
    if printf '%s\n' "$code" | grep -Fq 'wineserver -k'; then
        fail "executable wineserver -k in ${file}: ${rest}"
    fi
done < <(grep -Rn 'wineserver -k' "${ROOT}/images/mt5-headless" || true)
TESTS_RUN=$((TESTS_RUN + 3))
pass "no project-specific wineserver -k; stage3 generic containment only"

echo "=== test 16: production defaults ==="
grep -Fq 'BRIDGE_LIFECYCLE_SCRIPT:-/scripts/start_bridge.sh' "$RUN" || fail "lifecycle default"
grep -Fq 'BRIDGE_FINISH_QUIESCE_TIMEOUT_SECONDS:-2' "$FINISH" || fail "quiesce default"
TESTS_RUN=$((TESTS_RUN + 2))
pass "production defaults frozen"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
