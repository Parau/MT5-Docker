#!/bin/bash
# Deterministic tests for stage3 Wine finalizer cont-finish.d/10-wine-cleanup.
#
# Data flow: runs production finalizer with a fake wineserver on PATH and optional
# WINEPREFIX overrides. Limitations: no s6 stage3, no real Wine, no broker volumes.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FINALIZER="${ROOT}/images/mt5-headless/cont-finish.d/10-wine-cleanup"

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

setup_fake_wineserver() {
    local case_dir="$1"
    local exit_code="$2"
    mkdir -p "${case_dir}/bin"
    cat >"${case_dir}/bin/wineserver" <<EOF
#!/bin/bash
echo "WINEPREFIX=\${WINEPREFIX-}" >> "${case_dir}/wine_env"
printf '%s\\n' "\$@" >> "${case_dir}/wine_args"
count=0
if [ -f "${case_dir}/count" ]; then
    count="\$(cat "${case_dir}/count")"
fi
count=\$((count + 1))
echo "\$count" > "${case_dir}/count"
exit ${exit_code}
EOF
    chmod +x "${case_dir}/bin/wineserver"
    echo 0 >"${case_dir}/count"
    : >"${case_dir}/wine_env"
    : >"${case_dir}/wine_args"
}

run_finalizer() {
    local case_dir="$1"
    shift
    set +e
    OUTPUT="$(
        PATH="${case_dir}/bin:${PATH}" \
        "$@" \
        bash "$FINALIZER" 2>&1
    )"
    STATUS=$?
    set -e
}

echo "=== test A: default WINEPREFIX=/config/.wine ==="
CASE_DIR="$(mktemp -d /tmp/wine-finalizer.XXXXXX)"
setup_fake_wineserver "$CASE_DIR" 0
run_finalizer "$CASE_DIR" env -u WINEPREFIX
assert_eq "0" "$STATUS" "finalizer exit"
assert_eq "1" "$(cat "${CASE_DIR}/count")" "wineserver once"
grep -Fq 'WINEPREFIX=/config/.wine' "${CASE_DIR}/wine_env" || fail "default prefix: $(cat "${CASE_DIR}/wine_env")"
echo "$OUTPUT" | grep -q 'state=START action=wineserver-k' || fail "START log"
echo "$OUTPUT" | grep -q 'state=COMPLETED status=0' || fail "COMPLETED 0"
TESTS_RUN=$((TESTS_RUN + 3))
pass "default prefix /config/.wine"
rm -rf "$CASE_DIR"

echo "=== test B: custom WINEPREFIX observed ==="
CASE_DIR="$(mktemp -d /tmp/wine-finalizer.XXXXXX)"
setup_fake_wineserver "$CASE_DIR" 0
run_finalizer "$CASE_DIR" env WINEPREFIX=/tmp/custom
assert_eq "0" "$STATUS" "custom finalizer exit"
grep -Fq 'WINEPREFIX=/tmp/custom' "${CASE_DIR}/wine_env" || fail "custom prefix not observed"
TESTS_RUN=$((TESTS_RUN + 1))
pass "custom WINEPREFIX=/tmp/custom"
rm -rf "$CASE_DIR"

echo "=== test C: wineserver success → finalizer 0 ==="
CASE_DIR="$(mktemp -d /tmp/wine-finalizer.XXXXXX)"
setup_fake_wineserver "$CASE_DIR" 0
run_finalizer "$CASE_DIR" env WINEPREFIX=/config/.wine
assert_eq "0" "$STATUS" "success path exit"
assert_eq "1" "$(cat "${CASE_DIR}/count")" "success count"
echo "$OUTPUT" | grep -q 'state=COMPLETED status=0' || fail "success log"
pass "success path"
rm -rf "$CASE_DIR"

echo "=== test D: wineserver failure → finalizer still 0 ==="
CASE_DIR="$(mktemp -d /tmp/wine-finalizer.XXXXXX)"
setup_fake_wineserver "$CASE_DIR" 42
run_finalizer "$CASE_DIR" env WINEPREFIX=/config/.wine
assert_eq "0" "$STATUS" "failure path must exit 0"
assert_eq "1" "$(cat "${CASE_DIR}/count")" "failure count"
echo "$OUTPUT" | grep -q 'state=COMPLETED status=42' || fail "status 42 log"
echo "$OUTPUT" | grep -q 'result=best_effort_failure' || fail "best_effort_failure"
pass "failure is best-effort; finalizer exits 0"
rm -rf "$CASE_DIR"

echo "=== test E: arguments exactly -k ==="
CASE_DIR="$(mktemp -d /tmp/wine-finalizer.XXXXXX)"
setup_fake_wineserver "$CASE_DIR" 0
run_finalizer "$CASE_DIR" env WINEPREFIX=/config/.wine
assert_eq "-k" "$(tr -d '\r' < "${CASE_DIR}/wine_args" | head -n 1)" "args"
line_count="$(grep -c . "${CASE_DIR}/wine_args" || true)"
assert_eq "1" "$line_count" "single argv line"
pass "wineserver invoked with exactly -k"
rm -rf "$CASE_DIR"

echo "=== test F: static safety ==="
BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$FINALIZER")"
echo "$BODY" | grep -Eq 'pkill|killall|wineboot' && fail "banned tools"
echo "$BODY" | grep -Fq 'terminal64' && fail "must not target terminal64"
echo "$BODY" | grep -Fq 'rm -rf' && fail "must not rm prefix"
echo "$BODY" | grep -Fq 'wineserver -w' && fail "must not wineserver -w"
echo "$BODY" | grep -Fq 'wineserver -k' || fail "must call wineserver -k"
head -n 1 "$FINALIZER" | tr -d '\r' | grep -Fq '#!/command/with-contenv bash' || fail "with-contenv shebang"
TESTS_RUN=$((TESTS_RUN + 6))
pass "static safety + with-contenv"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
