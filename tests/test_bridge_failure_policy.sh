#!/bin/bash
# Failure/recovery policy for bridge/finish: crash-loop budget + exit 75.
#
# Data flow: invokes production bridge/finish with fake s6-svstat,
# s6-permafailon, and halt seams. Limitations: no real s6 death tally unless
# explicitly noted; no Wine/broker; Docker unhealthy is side-effect-free.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FINISH="${ROOT}/images/mt5-headless/s6-rc.d/bridge/finish"
IMAGE="${IMAGE:-mt5-docker-mt5-amp:latest}"

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

setup_case() {
    CASE_DIR="$(mktemp -d /tmp/bridge-failpol.XXXXXX)"
    mkdir -p "${CASE_DIR}/bin" "${CASE_DIR}/svc"
    : >"${CASE_DIR}/halt.log"
    : >"${CASE_DIR}/perma.log"
    : >"${CASE_DIR}/svstat.log"
    echo 0 >"${CASE_DIR}/halt_count"
    echo 0 >"${CASE_DIR}/perma_count"
    echo true >"${CASE_DIR}/wantedup"
    echo 0 >"${CASE_DIR}/perma_status"

    cat >"${CASE_DIR}/bin/fake-svstat" <<EOF
#!/bin/bash
echo "svstat \$*" >> "${CASE_DIR}/svstat.log"
# Usage: fake-svstat -o wantedup <servicedir>
if [ "\${1:-}" = "-o" ] && [ "\${2:-}" = "wantedup" ]; then
  cat "${CASE_DIR}/wantedup"
  exit 0
fi
exit 1
EOF
    chmod +x "${CASE_DIR}/bin/fake-svstat"

    cat >"${CASE_DIR}/bin/fake-svstat-fail" <<EOF
#!/bin/bash
echo "svstat_fail \$*" >> "${CASE_DIR}/svstat.log"
exit 1
EOF
    chmod +x "${CASE_DIR}/bin/fake-svstat-fail"

    cat >"${CASE_DIR}/bin/fake-perma" <<EOF
#!/bin/bash
# Reject non-numeric / out-of-range budget args so contaminated command
# substitution cannot silently pass as "within budget".
echo "perma \$*" >> "${CASE_DIR}/perma.log"
printf '%s\n' "\$1" > "${CASE_DIR}/perma_arg1"
printf '%s\n' "\$2" > "${CASE_DIR}/perma_arg2"
case "\${1:-}" in
  ''|*[!0-9]*) exit 64 ;;
esac
case "\${2:-}" in
  ''|*[!0-9]*) exit 64 ;;
esac
if [ "\$1" -lt 1 ] || [ "\$2" -lt 2 ]; then
  exit 64
fi
count=\$(cat "${CASE_DIR}/perma_count")
echo \$((count + 1)) > "${CASE_DIR}/perma_count"
st=\$(cat "${CASE_DIR}/perma_status")
exit "\$st"
EOF
    chmod +x "${CASE_DIR}/bin/fake-perma"

    cat >"${CASE_DIR}/bin/fake-halt" <<EOF
#!/bin/bash
echo "halt \$*" >> "${CASE_DIR}/halt.log"
count=\$(cat "${CASE_DIR}/halt_count")
echo \$((count + 1)) > "${CASE_DIR}/halt_count"
exit 0
EOF
    chmod +x "${CASE_DIR}/bin/fake-halt"

    EXITCODE_FILE="${CASE_DIR}/exitcode"
}

spawn_group() {
    setsid bash -c 'sleep 300' >/dev/null 2>&1 &
    CHILD=$!
    for _i in $(seq 1 50); do
        kill -0 "$CHILD" 2>/dev/null && break
        sleep 0.05
    done
    PGID="$(read_pgid "$CHILD")" || fail "could not read child pgid"
}

run_finish() {
    set +e
    OUTPUT="$(
        BRIDGE_S6_SVSTAT_BIN="${BRIDGE_S6_SVSTAT_BIN:-${CASE_DIR}/bin/fake-svstat}" \
        BRIDGE_S6_PERMAFAILON_BIN="${CASE_DIR}/bin/fake-perma" \
        BRIDGE_HALT_BIN="${CASE_DIR}/bin/fake-halt" \
        BRIDGE_CONTAINER_EXITCODE_FILE="${EXITCODE_FILE}" \
        BRIDGE_FINISH_QUIESCE_TIMEOUT_SECONDS=2 \
        BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS="${BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS:-}" \
        BRIDGE_FAILURE_BUDGET_DEATHS="${BRIDGE_FAILURE_BUDGET_DEATHS:-}" \
        bash "$FINISH" "${1:-42}" "${2:-0}" "${CASE_DIR}/svc" "${3:-$PGID}" 2>&1
    )"
    STATUS=$?
    set -e
}

cleanup_child() {
    if [ -n "${PGID:-}" ]; then
        kill -KILL -- "-${PGID}" 2>/dev/null || true
    fi
    if [ -n "${CHILD:-}" ]; then
        kill -KILL "$CHILD" 2>/dev/null || true
    fi
}

echo "=== A: config defaults frozen ==="
grep -Fq 'BRIDGE_FAILURE_BUDGET_WINDOW_DEFAULT=60' "$FINISH" || fail "window default 60"
grep -Fq 'BRIDGE_FAILURE_BUDGET_DEATHS_DEFAULT=5' "$FINISH" || fail "deaths default 5"
grep -Fq '1-255,SIGABRT' "$FINISH" || fail "events must include 1-255 + abnormal signals"
BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$FINISH")"
echo "$BODY" | grep -Fq 'SIGTERM' && fail "events body must not include SIGTERM"
echo "$BODY" | grep -Fq 'SIGINT' && fail "events body must not include SIGINT"
# Comments may mention SIGTERM exclusion — check the events string line only.
EVENTS_LINE="$(grep -E 'BRIDGE_FAILURE_BUDGET_EVENTS=' "$FINISH" | head -1)"
echo "$EVENTS_LINE" | grep -Fq 'SIGTERM' && fail "events string must exclude SIGTERM"
echo "$EVENTS_LINE" | grep -Fq 'SIGINT' && fail "events string must exclude SIGINT"
grep -Fq 'BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS' "${ROOT}/docker-compose.yml" || fail "compose window env"
grep -Fq 'BRIDGE_FAILURE_BUDGET_DEATHS' "${ROOT}/docker-compose.yml" || fail "compose deaths env"
TESTS_RUN=$((TESTS_RUN + 8))
pass "defaults, events exclusions, compose env"

echo "=== B: invalid config falls back to defaults (numeric args) ==="
setup_case
spawn_group
echo true >"${CASE_DIR}/wantedup"
echo 0 >"${CASE_DIR}/perma_status"
BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS=0 BRIDGE_FAILURE_BUDGET_DEATHS=1 \
  run_finish 42 0 "$PGID"
assert_eq "0" "$STATUS" "invalid config still within-budget path"
echo "$OUTPUT" | grep -q 'failure_budget_config_invalid key=BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS' || fail "window invalid log"
echo "$OUTPUT" | grep -q 'failure_budget_config_invalid key=BRIDGE_FAILURE_BUDGET_DEATHS' || fail "deaths invalid log"
echo "$OUTPUT" | grep -q 'failure_budget=within_budget' || fail "within budget after fallback"
assert_eq "0" "$(cat "${CASE_DIR}/halt_count")" "no halt"
assert_eq "1" "$(cat "${CASE_DIR}/perma_count")" "perma called once after fallback"
assert_eq "60" "$(tr -d '[:space:]' <"${CASE_DIR}/perma_arg1")" "perma window arg exactly 60"
assert_eq "5" "$(tr -d '[:space:]' <"${CASE_DIR}/perma_arg2")" "perma deaths arg exactly 5"
# Contaminated multi-line window must never reach perma (would exit 64 → check_error).
echo "$OUTPUT" | grep -q 'failure_budget=check_error' && fail "invalid config must not become check_error"
cleanup_child
rm -rf "$CASE_DIR"
pass "invalid budget config falls back with clean 60/5 args"

echo "=== B2: non-numeric invalid config also falls back to 60/5 ==="
setup_case
spawn_group
echo true >"${CASE_DIR}/wantedup"
echo 0 >"${CASE_DIR}/perma_status"
BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS=abc BRIDGE_FAILURE_BUDGET_DEATHS=abc \
  run_finish 42 0 "$PGID"
assert_eq "0" "$STATUS" "abc config within-budget path"
echo "$OUTPUT" | grep -q 'failure_budget_config_invalid key=BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS' || fail "abc window log"
echo "$OUTPUT" | grep -q 'failure_budget_config_invalid key=BRIDGE_FAILURE_BUDGET_DEATHS' || fail "abc deaths log"
assert_eq "60" "$(tr -d '[:space:]' <"${CASE_DIR}/perma_arg1")" "abc window → 60"
assert_eq "5" "$(tr -d '[:space:]' <"${CASE_DIR}/perma_arg2")" "abc deaths → 5"
cleanup_child
rm -rf "$CASE_DIR"
pass "non-numeric invalid config falls back with clean 60/5 args"

echo "=== C: wantedup=false skips budget ==="
setup_case
spawn_group
echo false >"${CASE_DIR}/wantedup"
echo 125 >"${CASE_DIR}/perma_status"
run_finish 42 0 "$PGID"
assert_eq "0" "$STATUS" "wantedup false exit0"
assert_eq "0" "$(cat "${CASE_DIR}/perma_count")" "permafailon not called"
assert_eq "0" "$(cat "${CASE_DIR}/halt_count")" "no halt"
test ! -f "$EXITCODE_FILE" || fail "no exitcode on admin down"
echo "$OUTPUT" | grep -q 'failure_budget=skipped reason=wantedup_false' || fail "skip log"
cleanup_child
rm -rf "$CASE_DIR"
pass "wantedup false skips budget"

echo "=== D: wantedup unknown skips budget ==="
setup_case
spawn_group
BRIDGE_S6_SVSTAT_BIN="${CASE_DIR}/bin/fake-svstat-fail" \
  run_finish 42 0 "$PGID"
assert_eq "0" "$STATUS" "unknown wantedup exit0"
assert_eq "0" "$(cat "${CASE_DIR}/perma_count")" "perma not called"
assert_eq "0" "$(cat "${CASE_DIR}/halt_count")" "no halt"
echo "$OUTPUT" | grep -q 'failure_budget=skipped reason=wantedup_unreadable' || fail "unknown skip log"
cleanup_child
rm -rf "$CASE_DIR"
pass "wantedup unknown skips budget"

echo "=== E: within budget → restart ==="
setup_case
spawn_group
echo true >"${CASE_DIR}/wantedup"
echo 0 >"${CASE_DIR}/perma_status"
run_finish 42 0 "$PGID"
assert_eq "0" "$STATUS" "within budget exit0"
assert_eq "1" "$(cat "${CASE_DIR}/perma_count")" "perma once"
assert_eq "0" "$(cat "${CASE_DIR}/halt_count")" "no halt"
test ! -f "$EXITCODE_FILE" || fail "no exitcode within budget"
echo "$OUTPUT" | grep -q 'failure_budget=within_budget' || fail "within log"
echo "$OUTPUT" | grep -q 'restart_allowed=1' || fail "restart allowed"
# Prove events string passed to permafailon.
grep -q '1-255,SIGABRT' "${CASE_DIR}/perma.log" || fail "events not passed: $(cat "${CASE_DIR}/perma.log")"
grep -q 'SIGTERM' "${CASE_DIR}/perma.log" && fail "SIGTERM must not be in events arg"
cleanup_child
rm -rf "$CASE_DIR"
pass "within budget allows restart"

echo "=== F: budget exhausted → halt 75 ==="
setup_case
spawn_group
echo true >"${CASE_DIR}/wantedup"
echo 125 >"${CASE_DIR}/perma_status"
run_finish 42 0 "$PGID"
assert_eq "125" "$STATUS" "exhausted finish 125"
assert_eq "1" "$(cat "${CASE_DIR}/halt_count")" "halt once"
assert_eq "75" "$(tr -d '[:space:]' <"$EXITCODE_FILE")" "exitcode 75"
echo "$OUTPUT" | grep -q 'failure_budget=exhausted' || fail "exhausted log"
echo "$OUTPUT" | grep -q 'reason=rapid_crash_loop' || fail "rapid_crash_loop reason"
cleanup_child
rm -rf "$CASE_DIR"
pass "exhausted budget writes 75 and halts"

echo "=== G: existing fatal exit preserved ==="
setup_case
spawn_group
echo true >"${CASE_DIR}/wantedup"
echo 125 >"${CASE_DIR}/perma_status"
printf '42\n' >"$EXITCODE_FILE"
run_finish 42 0 "$PGID"
assert_eq "125" "$STATUS" "preserved finish 125"
assert_eq "1" "$(cat "${CASE_DIR}/halt_count")" "halt once"
assert_eq "42" "$(tr -d '[:space:]' <"$EXITCODE_FILE")" "exitcode stays 42"
echo "$OUTPUT" | grep -q 'fatal_exit_preserved=42' || fail "preserved log"
cleanup_child
rm -rf "$CASE_DIR"
pass "existing fatal exitcode preserved"

echo "=== G2: exitcode 0 is not preserved (bridge may write 75) ==="
setup_case
spawn_group
echo true >"${CASE_DIR}/wantedup"
echo 125 >"${CASE_DIR}/perma_status"
printf '0\n' >"$EXITCODE_FILE"
run_finish 42 0 "$PGID"
assert_eq "125" "$STATUS" "zero prior finish 125"
assert_eq "75" "$(tr -d '[:space:]' <"$EXITCODE_FILE")" "zero prior overwritten with 75"
echo "$OUTPUT" | grep -q 'fatal_exit_preserved' && fail "must not preserve 0"
cleanup_child
rm -rf "$CASE_DIR"
pass "exitcode 0 does not block bridge 75"

echo "=== H: unsafe cleanup + wantedup true → halt 75 ==="
setup_case
echo true >"${CASE_DIR}/wantedup"
run_finish 42 0 "abc"
assert_eq "125" "$STATUS" "unsafe finish 125"
assert_eq "1" "$(cat "${CASE_DIR}/halt_count")" "halt on unsafe+up"
assert_eq "75" "$(tr -d '[:space:]' <"$EXITCODE_FILE")" "unsafe exit 75"
echo "$OUTPUT" | grep -q 'cleanup_result=unsafe_no_restart' || fail "unsafe log"
echo "$OUTPUT" | grep -q 'reason=unsafe_cleanup' || fail "unsafe halt reason"
assert_eq "0" "$(cat "${CASE_DIR}/perma_count")" "perma not called before quiescence"
rm -rf "$CASE_DIR"
pass "unsafe while wanted-up escalates to 75"

echo "=== I: unsafe cleanup + wantedup false → no halt 75 ==="
setup_case
echo false >"${CASE_DIR}/wantedup"
run_finish 42 0 "abc"
assert_eq "125" "$STATUS" "unsafe+down finish 125"
assert_eq "0" "$(cat "${CASE_DIR}/halt_count")" "no halt on admin down unsafe"
test ! -f "$EXITCODE_FILE" || fail "no exit75 on admin down unsafe"
rm -rf "$CASE_DIR"
pass "unsafe while wanted-down does not write 75"

echo "=== I2: unsafe + wantedup unknown → no halt 75 ==="
setup_case
BRIDGE_S6_SVSTAT_BIN="${CASE_DIR}/bin/fake-svstat-fail" \
  run_finish 42 0 "0"
assert_eq "125" "$STATUS" "unsafe+unknown 125"
assert_eq "0" "$(cat "${CASE_DIR}/halt_count")" "no halt unknown"
test ! -f "$EXITCODE_FILE" || fail "no exit75 unknown unsafe"
rm -rf "$CASE_DIR"
pass "unsafe while wantedup unknown keeps old safety exit125"

echo "=== check_error → restart allowed ==="
setup_case
spawn_group
echo true >"${CASE_DIR}/wantedup"
echo 111 >"${CASE_DIR}/perma_status"
run_finish 42 0 "$PGID"
assert_eq "0" "$STATUS" "check_error exit0"
assert_eq "0" "$(cat "${CASE_DIR}/halt_count")" "no halt on check_error"
echo "$OUTPUT" | grep -q 'failure_budget=check_error' || fail "check_error log"
cleanup_child
rm -rf "$CASE_DIR"
pass "permafailon check_error does not escalate"

echo "=== J: image has s6-permafailon; health has no halt/restart ==="
docker run --rm --entrypoint bash "$IMAGE" -lc 'test -x /command/s6-permafailon' || fail "s6-permafailon missing in image"
HC="${ROOT}/images/mt5-headless/scripts/healthcheck_mt5.sh"
HC_BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$HC")"
echo "$HC_BODY" | grep -Eq '\bhalt\b|s6-svc|docker restart' && fail "health must not recover"
TESTS_RUN=$((TESTS_RUN + 2))
pass "s6-permafailon present; health side-effect-free"

echo "=== policy matrix comment present ==="
head -20 "$FINISH" | grep -q 'BRIDGE_UNRECOVERABLE\|crash-loop\|observability' || fail "policy matrix comment"
TESTS_RUN=$((TESTS_RUN + 1))
pass "finish documents failure policy"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
