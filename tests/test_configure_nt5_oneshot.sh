#!/bin/bash
# Deterministic tests for configure_nt5_oneshot.sh legacy nonfatal wrapper.
#
# Data flow: temp MT5 trees; invokes oneshot wrapper with CONFIGURE_NT5_SCRIPT
# override pointing at fake raw scripts (success/failure/missing).
# Limitations: no Wine/Docker/network; does not exercise s6-rc itself.
# Raw configure/Python contract remains in tests/test_configure_nt5.sh.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${ROOT}/images/mt5-headless/scripts/configure_nt5_oneshot.sh"

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

assert_file_exists() {
    local path="$1"
    local label="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ ! -f "$path" ]; then
        fail "${label}: missing file '${path}'"
    fi
}

assert_file_missing() {
    local path="$1"
    local label="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -f "$path" ]; then
        fail "${label}: unexpected file '${path}'"
    fi
}

setup_case() {
    CASE_DIR="$(mktemp -d /tmp/configure-nt5-oneshot-test.XXXXXX)"
    WINEPREFIX="${CASE_DIR}/wineprefix"
    MT5_INSTALL_DIR="${WINEPREFIX}/drive_c/Program Files/MetaTrader 5"
    MT5_EXE="${MT5_INSTALL_DIR}/terminal64.exe"
    MARKER="${CASE_DIR}/raw-called.marker"

    export WINEPREFIX
    export MT5_EXE
    export RUN_MT5=1
    export CONFIGURE_NT5=1
    export CONFIGURE_NT5_SCRIPT=/path/does-not-exist-raw.sh
}

make_mt5_install_with_exe() {
    mkdir -p "$MT5_INSTALL_DIR"
    printf 'fake-terminal\n' >"$MT5_EXE"
}

make_fake_raw_success() {
    cat >"${CASE_DIR}/fake-raw.sh" <<'EOF'
#!/bin/bash
echo "raw-called" >>"${CONFIGURE_NT5_ONESHOT_MARKER:?}"
exit 0
EOF
    chmod +x "${CASE_DIR}/fake-raw.sh"
    export CONFIGURE_NT5_SCRIPT="${CASE_DIR}/fake-raw.sh"
    export CONFIGURE_NT5_ONESHOT_MARKER="$MARKER"
    : >"$MARKER"
}

make_fake_raw_failure() {
    cat >"${CASE_DIR}/fake-raw.sh" <<'EOF'
#!/bin/bash
echo "raw-called" >>"${CONFIGURE_NT5_ONESHOT_MARKER:?}"
exit 42
EOF
    chmod +x "${CASE_DIR}/fake-raw.sh"
    export CONFIGURE_NT5_SCRIPT="${CASE_DIR}/fake-raw.sh"
    export CONFIGURE_NT5_ONESHOT_MARKER="$MARKER"
    : >"$MARKER"
}

run_wrapper() {
    set +e
    OUTPUT="$(bash "$WRAPPER" 2>&1)"
    STATUS=$?
    set -e
}

cleanup_case() {
    rm -rf "$CASE_DIR"
}

echo "=== wrapper 1: RUN_MT5=0 skips before raw ==="
setup_case
make_mt5_install_with_exe
export RUN_MT5=0
export CONFIGURE_NT5_SCRIPT=/path/does-not-exist-raw.sh
run_wrapper
assert_eq "0" "$STATUS" "run_mt5=0 exit"
echo "$OUTPUT" | grep -q "state=SKIPPED reason=run_mt5_disabled" || fail "run_mt5 skip log"
assert_file_missing "$MARKER" "no marker when RUN_MT5=0"
pass "RUN_MT5=0 skips without invoking raw"
cleanup_case

echo "=== wrapper 2: MT5_EXE missing skips ==="
setup_case
mkdir -p "$MT5_INSTALL_DIR"
export MT5_EXE="${MT5_INSTALL_DIR}/missing-terminal64.exe"
export CONFIGURE_NT5_SCRIPT=/path/does-not-exist-raw.sh
run_wrapper
assert_eq "0" "$STATUS" "missing exe exit"
echo "$OUTPUT" | grep -q "state=SKIPPED reason=mt5_exe_missing_before_cmd_validation" || fail "missing exe skip log"
pass "MT5_EXE missing skips without raw"
cleanup_case

echo "=== wrapper 3: CONFIGURE_NT5=0 skips ==="
setup_case
make_mt5_install_with_exe
export CONFIGURE_NT5=0
export CONFIGURE_NT5_SCRIPT=/path/does-not-exist-raw.sh
run_wrapper
assert_eq "0" "$STATUS" "configure=0 exit"
echo "$OUTPUT" | grep -q "state=SKIPPED reason=configure_disabled" || fail "configure_disabled log"
pass "CONFIGURE_NT5=0 skips without raw"
cleanup_case

echo "=== wrapper 4: success path ==="
setup_case
make_mt5_install_with_exe
make_fake_raw_success
run_wrapper
assert_eq "0" "$STATUS" "success exit"
echo "$OUTPUT" | grep -q "state=COMPLETED raw_status=0" || fail "completed log"
assert_file_exists "$MARKER" "raw marker after success"
grep -q "raw-called" "$MARKER" || fail "raw not called on success"
pass "success invokes raw and completes"
cleanup_case

echo "=== wrapper 5: raw failure is nonfatal ==="
setup_case
make_mt5_install_with_exe
make_fake_raw_failure
run_wrapper
assert_eq "0" "$STATUS" "raw failure wrapper exit"
echo "$OUTPUT" | grep -Fq "AVISO: configure NT5 falhou (continuando)." || fail "legacy warning missing"
echo "$OUTPUT" | grep -q "state=WARNING" || fail "warning state missing"
echo "$OUTPUT" | grep -q "policy=legacy_nonfatal" || fail "policy tag missing"
echo "$OUTPUT" | grep -q "raw_status=42" || fail "raw_status=42 missing"
assert_file_exists "$MARKER" "raw marker after failure"
pass "raw failure becomes legacy nonfatal warning"
cleanup_case

echo "=== wrapper 6: nonexistent raw script treated as nonfatal ==="
setup_case
make_mt5_install_with_exe
export CONFIGURE_NT5_SCRIPT=/path/does-not-exist-raw.sh
run_wrapper
assert_eq "0" "$STATUS" "missing raw script exit"
echo "$OUTPUT" | grep -Fq "AVISO: configure NT5 falhou (continuando)." || fail "legacy warning for missing raw"
echo "$OUTPUT" | grep -q "state=WARNING" || fail "warning for missing raw"
echo "$OUTPUT" | grep -q "policy=legacy_nonfatal" || fail "policy for missing raw"
echo "$OUTPUT" | grep -Eq "raw_status=[1-9]" || fail "raw_status missing for missing raw"
pass "missing raw script is nonfatal via wrapper"
cleanup_case

echo "=== summary ==="
echo "tests_run=${TESTS_RUN} passed=${TESTS_PASSED} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
