#!/bin/bash
# Regressions for bridge/finish PGID parsing with pathological /proc/PID/stat comm.
#
# Data flow: spawns isolated sessions with renamed comm (spaces / ')'), proves the
# historical awk '$5' parser misreads PGID, then invokes production finish and
# asserts quiescence. Also covers PGID isolation vs a sibling group.
# Limitations: no s6-supervise, no Wine, no broker volumes; requires procps `ps`.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FINISH="${ROOT}/images/mt5-headless/s6-rc.d/bridge/finish"

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

# Historical anti-pattern from 04I-C finish (whitespace tokenize).
fragile_awk_pgid() {
    local pid="$1"
    awk '{ print $5; exit }' "/proc/${pid}/stat" 2>/dev/null || true
}

# Parser that stops at the FIRST ')' — wrong when comm itself contains ')'.
fragile_first_paren_pgid() {
    local pid="$1"
    local rest
    rest="$(sed 's/[^)]*)//' "/proc/${pid}/stat" 2>/dev/null || true)"
    awk '{ print $3; exit }' <<<"${rest}" 2>/dev/null || true
}

# Keep bash as the process and rename its comm so /proc/PID/stat field 2 is special.
spawn_named_session() {
    local name="$1"
    local ready="$2"
    setsid bash -c "
        printf '%s' '${name}' > /proc/self/comm
        : > '${ready}'
        sleep 300
    " >/dev/null 2>&1 &
    echo $!
}

wait_ready() {
    local ready="$1"
    local pid="$2"
    local i
    for i in $(seq 1 100); do
        if [ -f "$ready" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

run_special_comm_case() {
    local label="$1"
    local name="$2"
    # require: awk5 | firstparen | either
    local require_break="${3:-either}"
    local case_dir child ready pgid wrong_awk wrong_first output status broke

    case_dir="$(mktemp -d /tmp/bridge-finish-pgid.XXXXXX)"
    ready="${case_dir}/ready"
    child="$(spawn_named_session "$name" "$ready")"
    wait_ready "$ready" "$child" || {
        kill -KILL "$child" 2>/dev/null || true
        fail "${label}: child did not become ready"
    }

    # Confirm kernel accepted the renamed comm (may truncate to TASK_COMM_LEN-1).
    COMM_NOW="$(tr -d '\0' < "/proc/${child}/comm" 2>/dev/null || true)"
    echo "${label}: pid=${child} comm='${COMM_NOW}' stat=$(tr -d '\0' < "/proc/${child}/stat" | head -c 120)"

    pgid="$(read_pgid "$child")" || fail "${label}: could not read robust pgid"
    wrong_awk="$(fragile_awk_pgid "$child")"
    wrong_first="$(fragile_first_paren_pgid "$child")"
    echo "${label}: fragile_awk=${wrong_awk} fragile_first_paren=${wrong_first} robust_ps=${pgid}"

    broke=0
    if [ "$wrong_awk" != "$pgid" ]; then
        broke=1
    fi
    if [ "$wrong_first" != "$pgid" ]; then
        broke=1
    fi
    case "$require_break" in
        awk5)
            [ "$wrong_awk" != "$pgid" ] || {
                kill -KILL -- "-${pgid}" 2>/dev/null || true
                rm -rf "$case_dir"
                fail "${label}: fixture must break awk '\$5' (awk=${wrong_awk} pgid=${pgid})"
            }
            ;;
        firstparen)
            [ "$wrong_first" != "$pgid" ] || {
                kill -KILL -- "-${pgid}" 2>/dev/null || true
                rm -rf "$case_dir"
                fail "${label}: fixture must break first-')' parser (first=${wrong_first} pgid=${pgid})"
            }
            ;;
        either)
            [ "$broke" -eq 1 ] || {
                kill -KILL -- "-${pgid}" 2>/dev/null || true
                rm -rf "$case_dir"
                fail "${label}: fixture must break at least one fragile parser"
            }
            ;;
        *)
            fail "${label}: unknown require_break=${require_break}"
            ;;
    esac
    TESTS_RUN=$((TESTS_RUN + 1))

    set +e
    output="$(BRIDGE_FINISH_QUIESCE_TIMEOUT_SECONDS=2 bash "$FINISH" 42 0 /tmp/bridge-svc "$pgid" 2>&1)"
    status=$?
    set -e
    assert_eq "0" "$status" "${label}: finish exit"
    echo "$output" | grep -q "cleanup_result=quiescent" || fail "${label}: quiescent log: ${output}"
    if kill -0 "$child" 2>/dev/null; then
        kill -KILL -- "-${pgid}" 2>/dev/null || true
        fail "${label}: old child must be gone after finish"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
    pass "${label}: finish quiescent with pathological comm"
    rm -rf "$case_dir"
}

echo "=== special-comm: space ==="
run_special_comm_case "comm_space" "a b" "awk5"

echo "=== special-comm: closing paren ==="
run_special_comm_case "comm_paren" "a)b" "firstparen"

echo "=== special-comm: paren + space ==="
run_special_comm_case "comm_paren_space" "a)b c" "awk5"

echo "=== isolation: finish bridge PGID must not kill sibling metatrader PGID ==="
CASE_DIR="$(mktemp -d /tmp/bridge-finish-pgid.XXXXXX)"
setsid bash -c 'sleep 300' >/dev/null 2>&1 &
BRIDGE_CHILD=$!
setsid bash -c 'sleep 300' >/dev/null 2>&1 &
MT_CHILD=$!
for _i in $(seq 1 50); do
    kill -0 "$BRIDGE_CHILD" 2>/dev/null && kill -0 "$MT_CHILD" 2>/dev/null && break
    sleep 0.05
done
BRIDGE_PGID="$(read_pgid "$BRIDGE_CHILD")" || fail "bridge pgid"
MT_PGID="$(read_pgid "$MT_CHILD")" || fail "metatrader pgid"
if [ "$BRIDGE_PGID" = "$MT_PGID" ]; then
    kill -KILL -- "-${BRIDGE_PGID}" 2>/dev/null || true
    fail "fixture requires distinct PGIDs"
fi
MT_BEFORE_PID="$MT_CHILD"
MT_BEFORE_PGID="$MT_PGID"
set +e
OUTPUT="$(bash "$FINISH" 42 0 /tmp/bridge-svc "$BRIDGE_PGID" 2>&1)"
STATUS=$?
set -e
assert_eq "0" "$STATUS" "isolation finish exit"
echo "$OUTPUT" | grep -q "cleanup_result=quiescent" || fail "isolation quiescent"
if kill -0 "$BRIDGE_CHILD" 2>/dev/null; then
    fail "bridge child must die"
fi
kill -0 "$MT_BEFORE_PID" 2>/dev/null || fail "metatrader fake must survive"
MT_AFTER_PGID="$(read_pgid "$MT_BEFORE_PID")" || fail "metatrader pgid after"
assert_eq "$MT_BEFORE_PGID" "$MT_AFTER_PGID" "metatrader pgid unchanged"
kill -KILL -- "-${MT_BEFORE_PGID}" 2>/dev/null || true
TESTS_RUN=$((TESTS_RUN + 2))
pass "finish isolates bridge PGID from sibling group"
rm -rf "$CASE_DIR"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
