#!/bin/bash
# Deterministic tests for deploy_mql5_oneshot.sh legacy nonfatal wrapper.
#
# Data flow: temp vendor/MT5 trees; invokes oneshot wrapper with
# DEPLOY_MQL5_SCRIPT override pointing at repo deploy_mql5.sh.
# Limitations: no Wine/Docker/network; does not exercise s6-rc itself.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${ROOT}/images/mt5-headless/scripts/deploy_mql5_oneshot.sh"
RAW_SCRIPT="${ROOT}/images/mt5-headless/scripts/deploy_mql5.sh"

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

assert_dir_missing() {
    local path="$1"
    local label="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -d "$path" ]; then
        fail "${label}: unexpected dir '${path}'"
    fi
}

setup_case() {
    CASE_DIR="$(mktemp -d /tmp/deploy-mql5-oneshot-test.XXXXXX)"
    WINEPREFIX="${CASE_DIR}/wineprefix"
    VENDOR_MQL5_ROOT="${CASE_DIR}/vendor"
    MT5_MQL5_ROOT="${CASE_DIR}/target-mql5"
    MT5_INSTALL_DIR="${WINEPREFIX}/drive_c/Program Files/MetaTrader 5"
    MT5_EXE="${MT5_INSTALL_DIR}/terminal64.exe"

    export WINEPREFIX
    export VENDOR_MQL5_ROOT
    export MT5_MQL5_ROOT
    export MT5_EXE
    export RUN_MT5=1
    export DEPLOY_MQL5=1
    export DEPLOY_MQL5_SCRIPT="$RAW_SCRIPT"
}

make_mt5_install_with_exe() {
    mkdir -p "$MT5_INSTALL_DIR"
    printf 'fake-terminal\n' >"$MT5_EXE"
}

make_full_vendor() {
    mkdir -p "${VENDOR_MQL5_ROOT}/Include/WebSocket" "${VENDOR_MQL5_ROOT}/Services"
    printf 'wire\n' >"${VENDOR_MQL5_ROOT}/Include/NT5FeedWire.mqh"
    printf 'ws-a\n' >"${VENDOR_MQL5_ROOT}/Include/WebSocket/A.mqh"
    printf 'mq5\n' >"${VENDOR_MQL5_ROOT}/Services/NT5TickFeedService.mq5"
    printf 'ex5\n' >"${VENDOR_MQL5_ROOT}/Services/NT5TickFeedService.ex5"
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
make_full_vendor
export RUN_MT5=0
export DEPLOY_MQL5_SCRIPT=/path/does-not-exist-raw.sh
run_wrapper
assert_eq "0" "$STATUS" "run_mt5=0 exit"
echo "$OUTPUT" | grep -q "state=SKIPPED reason=run_mt5_disabled" || fail "run_mt5 skip log"
assert_dir_missing "$MT5_MQL5_ROOT" "no target when RUN_MT5=0"
pass "RUN_MT5=0 skips without invoking raw"
cleanup_case

echo "=== wrapper 2: MT5_EXE missing skips ==="
setup_case
make_full_vendor
mkdir -p "$MT5_INSTALL_DIR"
export MT5_EXE="${MT5_INSTALL_DIR}/missing-terminal64.exe"
export DEPLOY_MQL5_SCRIPT=/path/does-not-exist-raw.sh
run_wrapper
assert_eq "0" "$STATUS" "missing exe exit"
echo "$OUTPUT" | grep -q "state=SKIPPED reason=mt5_exe_missing_before_cmd_validation" || fail "missing exe skip log"
assert_dir_missing "$MT5_MQL5_ROOT" "no target when MT5_EXE missing"
pass "MT5_EXE missing skips without raw"
cleanup_case

echo "=== wrapper 3: DEPLOY_MQL5=0 skips ==="
setup_case
make_mt5_install_with_exe
make_full_vendor
export DEPLOY_MQL5=0
export DEPLOY_MQL5_SCRIPT=/path/does-not-exist-raw.sh
run_wrapper
assert_eq "0" "$STATUS" "deploy=0 exit"
echo "$OUTPUT" | grep -q "state=SKIPPED reason=deploy_disabled" || fail "deploy_disabled log"
assert_dir_missing "$MT5_MQL5_ROOT" "no target when DEPLOY_MQL5=0"
pass "DEPLOY_MQL5=0 skips without raw"
cleanup_case

echo "=== wrapper 4: success path ==="
setup_case
make_mt5_install_with_exe
make_full_vendor
run_wrapper
assert_eq "0" "$STATUS" "success exit"
echo "$OUTPUT" | grep -q "state=COMPLETED raw_status=0" || fail "completed log"
echo "$OUTPUT" | grep -q "concluído\|concluido" || fail "raw done log"
assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.ex5" "ex5 deployed"
assert_file_exists "${MT5_MQL5_ROOT}/Include/NT5FeedWire.mqh" "wire deployed"
pass "success invokes raw and completes"
cleanup_case

echo "=== wrapper 5: raw failure is nonfatal ==="
setup_case
make_mt5_install_with_exe
make_full_vendor
printf 'not-a-dir\n' >"${CASE_DIR}/not-a-directory"
export MT5_MQL5_ROOT="${CASE_DIR}/not-a-directory/MQL5"
run_wrapper
assert_eq "0" "$STATUS" "raw failure wrapper exit"
echo "$OUTPUT" | grep -Fq "AVISO: deploy MQL5 falhou (continuando)." || fail "legacy warning missing"
echo "$OUTPUT" | grep -q "state=WARNING" || fail "warning state missing"
echo "$OUTPUT" | grep -q "policy=legacy_nonfatal" || fail "policy tag missing"
echo "$OUTPUT" | grep -Eq "raw_status=[1-9]" || fail "raw_status missing"
echo "$OUTPUT" | grep -q "concluído\|concluido" && fail "raw done must be absent"
pass "raw failure becomes legacy nonfatal warning"
cleanup_case

echo "=== wrapper 6: nonexistent raw script treated as nonfatal ==="
setup_case
make_mt5_install_with_exe
make_full_vendor
export DEPLOY_MQL5_SCRIPT=/path/does-not-exist-raw.sh
run_wrapper
assert_eq "0" "$STATUS" "missing raw script exit"
echo "$OUTPUT" | grep -Fq "AVISO: deploy MQL5 falhou (continuando)." || fail "legacy warning for missing raw"
echo "$OUTPUT" | grep -q "state=WARNING" || fail "warning for missing raw"
echo "$OUTPUT" | grep -q "policy=legacy_nonfatal" || fail "policy for missing raw"
pass "missing raw script is nonfatal via wrapper"
cleanup_case

echo "=== summary ==="
echo "tests_run=${TESTS_RUN} passed=${TESTS_PASSED} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
