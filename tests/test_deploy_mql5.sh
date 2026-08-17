#!/bin/bash
# Deterministic tests for deploy_mql5.sh contract (no Wine/MT5/Docker/network).
#
# Data flow: builds temp vendor + fake MT5 install trees; invokes deploy_mql5.sh
# with bash and asserts copy/skip/error semantics.
# Limitations: does not exercise entrypoint nonfatal wrapper; WebSocket broken
# symlink tolerance depends on local cp behavior.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/images/mt5-headless/scripts/deploy_mql5.sh"

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

assert_dir_missing() {
    local path="$1"
    local label="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -d "$path" ]; then
        fail "${label}: unexpected dir '${path}'"
    fi
}

assert_dir_exists() {
    local path="$1"
    local label="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ ! -d "$path" ]; then
        fail "${label}: missing dir '${path}'"
    fi
}

assert_file_same() {
    local src="$1"
    local dest="$2"
    local label="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! cmp -s "$src" "$dest"; then
        fail "${label}: '${src}' != '${dest}'"
    fi
}

assert_file_content() {
    local path="$1"
    local expected="$2"
    local label="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    local actual
    actual="$(cat "$path")"
    if [ "$actual" != "$expected" ]; then
        fail "${label}: expected '${expected}', got '${actual}'"
    fi
}

setup_case() {
    CASE_DIR="$(mktemp -d /tmp/deploy-mql5-test.XXXXXX)"
    WINEPREFIX="${CASE_DIR}/wineprefix"
    VENDOR_MQL5_ROOT="${CASE_DIR}/vendor"
    MT5_MQL5_ROOT="${CASE_DIR}/target-mql5"
    MT5_INSTALL_DIR="${WINEPREFIX}/drive_c/Program Files/MetaTrader 5"

    export WINEPREFIX
    export VENDOR_MQL5_ROOT
    export MT5_MQL5_ROOT
    export DEPLOY_MQL5=1
}

make_mt5_install() {
    mkdir -p "$MT5_INSTALL_DIR"
}

make_full_vendor() {
    mkdir -p "${VENDOR_MQL5_ROOT}/Include/WebSocket" "${VENDOR_MQL5_ROOT}/Services"
    mkdir -p "${VENDOR_MQL5_ROOT}/Experts/FluxoReal" "${VENDOR_MQL5_ROOT}/Experts/OutroVendor/Subdir"
    printf 'wire-content\n' >"${VENDOR_MQL5_ROOT}/Include/NT5FeedWire.mqh"
    printf 'ws-a\n' >"${VENDOR_MQL5_ROOT}/Include/WebSocket/A.mqh"
    printf 'ws-b\n' >"${VENDOR_MQL5_ROOT}/Include/WebSocket/B.mqh"
    printf 'service-mq5\n' >"${VENDOR_MQL5_ROOT}/Services/NT5TickFeedService.mq5"
    printf 'service-ex5\n' >"${VENDOR_MQL5_ROOT}/Services/NT5TickFeedService.ex5"
    printf 'boleta-a-binary-fixture\n' >"${VENDOR_MQL5_ROOT}/Experts/FluxoReal/BoletaA.ex5"
    printf 'boleta-b-binary-fixture\n' >"${VENDOR_MQL5_ROOT}/Experts/FluxoReal/BoletaB.ex5"
    printf 'other-vendor-ea\n' >"${VENDOR_MQL5_ROOT}/Experts/OutroVendor/Subdir/EA.ex5"
}

run_deploy() {
    set +e
    OUTPUT="$(bash "$SCRIPT" 2>&1)"
    STATUS=$?
    set -e
}

cleanup_case() {
    rm -rf "$CASE_DIR"
}

echo "=== test 1: DEPLOY_MQL5=0 skip ==="
setup_case
make_mt5_install
make_full_vendor
export DEPLOY_MQL5=0
run_deploy
assert_eq "0" "$STATUS" "deploy=0 exit"
echo "$OUTPUT" | grep -q "DEPLOY_MQL5=0" || fail "skip log missing"
assert_dir_missing "$MT5_MQL5_ROOT" "target not created on skip"
pass "DEPLOY_MQL5=0 is no-op"
cleanup_case

echo "=== test 2: vendor absent ==="
setup_case
make_mt5_install
# no vendor dir
run_deploy
assert_eq "0" "$STATUS" "vendor absent exit"
echo "$OUTPUT" | grep -qi "ignorando" || fail "vendor absent log missing"
assert_dir_missing "$MT5_MQL5_ROOT" "target not created without vendor"
pass "vendor absent skips"
cleanup_case

echo "=== test 3: MT5 absent ==="
setup_case
make_full_vendor
# no MT5 install dir
run_deploy
assert_eq "0" "$STATUS" "mt5 absent exit"
echo "$OUTPUT" | grep -qi "não instalado\|nao instalado" || fail "mt5 absent log missing"
assert_dir_missing "$MT5_MQL5_ROOT" "target not created without MT5"
pass "MT5 absent skips"
cleanup_case

echo "=== test 4: full deploy ==="
setup_case
make_mt5_install
make_full_vendor
run_deploy
assert_eq "0" "$STATUS" "full deploy exit"
assert_file_exists "${MT5_MQL5_ROOT}/Include/NT5FeedWire.mqh" "wire copied"
assert_file_exists "${MT5_MQL5_ROOT}/Include/WebSocket/A.mqh" "ws A copied"
assert_file_exists "${MT5_MQL5_ROOT}/Include/WebSocket/B.mqh" "ws B copied"
assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.mq5" "mq5 copied"
assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.ex5" "ex5 copied"
cmp -s "${VENDOR_MQL5_ROOT}/Include/NT5FeedWire.mqh" "${MT5_MQL5_ROOT}/Include/NT5FeedWire.mqh" || fail "wire cmp"
cmp -s "${VENDOR_MQL5_ROOT}/Services/NT5TickFeedService.mq5" "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.mq5" || fail "mq5 cmp"
cmp -s "${VENDOR_MQL5_ROOT}/Services/NT5TickFeedService.ex5" "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.ex5" || fail "ex5 cmp"
echo "$OUTPUT" | grep -q "NT5TickFeedService.mq5" || fail "mq5 log missing"
echo "$OUTPUT" | grep -q "compilado vendored" || fail "ex5 log missing"
echo "$OUTPUT" | grep -q "Experts vendorizados sincronizados" || fail "experts log missing"
echo "$OUTPUT" | grep -q "concluído\|concluido" || fail "done log missing"
assert_file_exists "${MT5_MQL5_ROOT}/Experts/FluxoReal/BoletaA.ex5" "FluxoReal A copied"
assert_file_exists "${MT5_MQL5_ROOT}/Experts/FluxoReal/BoletaB.ex5" "FluxoReal B copied"
assert_file_exists "${MT5_MQL5_ROOT}/Experts/OutroVendor/Subdir/EA.ex5" "nested EA copied"
assert_dir_missing "${MT5_MQL5_ROOT}/Experts/Experts" "must not nest Experts/Experts"
assert_file_same "${VENDOR_MQL5_ROOT}/Experts/FluxoReal/BoletaA.ex5" \
    "${MT5_MQL5_ROOT}/Experts/FluxoReal/BoletaA.ex5" "BoletaA cmp"
assert_file_same "${VENDOR_MQL5_ROOT}/Experts/FluxoReal/BoletaB.ex5" \
    "${MT5_MQL5_ROOT}/Experts/FluxoReal/BoletaB.ex5" "BoletaB cmp"
assert_file_same "${VENDOR_MQL5_ROOT}/Experts/OutroVendor/Subdir/EA.ex5" \
    "${MT5_MQL5_ROOT}/Experts/OutroVendor/Subdir/EA.ex5" "nested EA cmp"
pass "full deploy copies all artifacts"
cleanup_case

echo "=== test 5: ex5 absent warning ==="
setup_case
make_mt5_install
make_full_vendor
rm -f "${VENDOR_MQL5_ROOT}/Services/NT5TickFeedService.ex5"
run_deploy
assert_eq "0" "$STATUS" "ex5 absent exit"
assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.mq5" "mq5 still copied"
assert_file_missing "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.ex5" "ex5 not invented"
echo "$OUTPUT" | grep -q "AVISO" || fail "ex5 aviso missing"
echo "$OUTPUT" | grep -q "ex5 ausente" || fail "ex5 absent text missing"
pass "missing ex5 warns and succeeds"
cleanup_case

echo "=== test 6: NT5FeedWire absent ==="
setup_case
make_mt5_install
make_full_vendor
rm -f "${VENDOR_MQL5_ROOT}/Include/NT5FeedWire.mqh"
run_deploy
assert_eq "0" "$STATUS" "wire absent exit"
assert_file_missing "${MT5_MQL5_ROOT}/Include/NT5FeedWire.mqh" "wire not copied"
assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.mq5" "mq5 still copied"
assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.ex5" "ex5 still copied"
pass "missing wire is nonfatal"
cleanup_case

echo "=== test 7a: WebSocket directory absent ==="
setup_case
make_mt5_install
make_full_vendor
rm -rf "${VENDOR_MQL5_ROOT}/Include/WebSocket"
run_deploy
assert_eq "0" "$STATUS" "ws dir absent exit"
assert_file_exists "${MT5_MQL5_ROOT}/Include/NT5FeedWire.mqh" "wire copied without ws"
assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.mq5" "mq5 copied without ws"
pass "WebSocket dir absent tolerated"
cleanup_case

echo "=== test 7b: WebSocket directory empty ==="
setup_case
make_mt5_install
make_full_vendor
rm -f "${VENDOR_MQL5_ROOT}/Include/WebSocket/"*.mqh
run_deploy
assert_eq "0" "$STATUS" "ws empty exit"
assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.ex5" "ex5 copied with empty ws"
pass "WebSocket empty tolerated"
cleanup_case

echo "=== test 8: mq5 absent, ex5 present ==="
setup_case
make_mt5_install
make_full_vendor
rm -f "${VENDOR_MQL5_ROOT}/Services/NT5TickFeedService.mq5"
run_deploy
assert_eq "0" "$STATUS" "mq5 absent exit"
assert_file_missing "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.mq5" "mq5 not copied"
assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.ex5" "ex5 copied"
pass "mq5 optional when ex5 present"
cleanup_case

echo "=== test 9: paths with spaces ==="
setup_case
make_mt5_install
export VENDOR_MQL5_ROOT="${CASE_DIR}/vendor custom"
export MT5_MQL5_ROOT="${CASE_DIR}/target custom/MQL5"
mkdir -p "${VENDOR_MQL5_ROOT}/Include/WebSocket" "${VENDOR_MQL5_ROOT}/Services"
printf 'wire-space\n' >"${VENDOR_MQL5_ROOT}/Include/NT5FeedWire.mqh"
printf 'ws-space\n' >"${VENDOR_MQL5_ROOT}/Include/WebSocket/A.mqh"
printf 'mq5-space\n' >"${VENDOR_MQL5_ROOT}/Services/NT5TickFeedService.mq5"
printf 'ex5-space\n' >"${VENDOR_MQL5_ROOT}/Services/NT5TickFeedService.ex5"
mkdir -p "${VENDOR_MQL5_ROOT}/Experts/Fluxo Real"
printf 'boleta-space-fixture\n' >"${VENDOR_MQL5_ROOT}/Experts/Fluxo Real/Boleta Teste.ex5"
run_deploy
assert_eq "0" "$STATUS" "spaces path exit"
assert_file_exists "${MT5_MQL5_ROOT}/Include/NT5FeedWire.mqh" "wire with spaces"
assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.ex5" "ex5 with spaces"
assert_file_exists "${MT5_MQL5_ROOT}/Experts/Fluxo Real/Boleta Teste.ex5" "expert with spaces"
assert_file_same "${VENDOR_MQL5_ROOT}/Experts/Fluxo Real/Boleta Teste.ex5" \
    "${MT5_MQL5_ROOT}/Experts/Fluxo Real/Boleta Teste.ex5" "expert spaces cmp"
pass "paths with spaces work"
cleanup_case

echo "=== test 10: target mkdir error => nonzero ==="
setup_case
make_mt5_install
make_full_vendor
printf 'not-a-dir\n' >"${CASE_DIR}/not-a-directory"
export MT5_MQL5_ROOT="${CASE_DIR}/not-a-directory/MQL5"
run_deploy
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$STATUS" -eq 0 ]; then
    fail "mkdir failure should be nonzero"
fi
echo "$OUTPUT" | grep -q "concluído\|concluido" && fail "done log must be absent on failure"
pass "target error returns nonzero"
cleanup_case

echo "=== test 11: WebSocket broken symlink tolerated ==="
setup_case
make_mt5_install
make_full_vendor
ln -s "${VENDOR_MQL5_ROOT}/Include/WebSocket/missing-target.mqh" \
    "${VENDOR_MQL5_ROOT}/Include/WebSocket/broken.mqh" || true
if [ ! -L "${VENDOR_MQL5_ROOT}/Include/WebSocket/broken.mqh" ]; then
    echo "SKIP note: could not create broken symlink; documenting || true remains in production"
    pass "WebSocket tolerance documented (symlink unavailable)"
else
    run_deploy
    assert_eq "0" "$STATUS" "broken ws symlink exit"
    assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.mq5" "mq5 after ws tolerance"
    assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.ex5" "ex5 after ws tolerance"
    echo "$OUTPUT" | grep -q "concluído\|concluido" || fail "done log missing after ws tolerance"
    pass "WebSocket broken symlink tolerated via || true"
fi
cleanup_case

echo "=== test 12: vendor Experts absent is nonfatal ==="
setup_case
make_mt5_install
make_full_vendor
rm -rf "${VENDOR_MQL5_ROOT}/Experts"
run_deploy
assert_eq "0" "$STATUS" "experts absent exit"
assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.mq5" "mq5 without experts"
assert_file_exists "${MT5_MQL5_ROOT}/Include/NT5FeedWire.mqh" "wire without experts"
assert_dir_missing "${MT5_MQL5_ROOT}/Experts" "must not invent Experts tree"
echo "$OUTPUT" | grep -q "Experts vendorizados sincronizados" && fail "experts log must be absent"
echo "$OUTPUT" | grep -q "concluído\|concluido" || fail "done log missing without experts"
pass "vendor Experts absent is nonfatal"
cleanup_case

echo "=== test 13: vendor Experts empty is nonfatal ==="
setup_case
make_mt5_install
make_full_vendor
rm -rf "${VENDOR_MQL5_ROOT}/Experts"
mkdir -p "${VENDOR_MQL5_ROOT}/Experts"
run_deploy
assert_eq "0" "$STATUS" "experts empty exit"
assert_file_exists "${MT5_MQL5_ROOT}/Services/NT5TickFeedService.ex5" "ex5 with empty experts"
assert_file_exists "${MT5_MQL5_ROOT}/Include/NT5FeedWire.mqh" "wire with empty experts"
echo "$OUTPUT" | grep -q "concluído\|concluido" || fail "done log missing with empty experts"
pass "vendor Experts empty is nonfatal"
cleanup_case

echo "=== test 14: Experts deploy is additive ==="
setup_case
make_mt5_install
make_full_vendor
mkdir -p "${MT5_MQL5_ROOT}/Experts/Manual"
printf 'manual-existing-content\n' >"${MT5_MQL5_ROOT}/Experts/Manual/MeuEA.ex5"
run_deploy
assert_eq "0" "$STATUS" "additive deploy exit"
assert_file_exists "${MT5_MQL5_ROOT}/Experts/Manual/MeuEA.ex5" "manual EA kept"
assert_file_content "${MT5_MQL5_ROOT}/Experts/Manual/MeuEA.ex5" "manual-existing-content" "manual content unchanged"
assert_file_exists "${MT5_MQL5_ROOT}/Experts/FluxoReal/BoletaA.ex5" "vendored EA added"
assert_dir_missing "${MT5_MQL5_ROOT}/Experts/Experts" "no nested Experts after additive"
pass "manual EA preserved; vendored Experts added"
cleanup_case

echo "=== test 15: vendored Expert same path is updated ==="
setup_case
make_mt5_install
make_full_vendor
mkdir -p "${MT5_MQL5_ROOT}/Experts/FluxoReal"
printf 'old-version\n' >"${MT5_MQL5_ROOT}/Experts/FluxoReal/BoletaA.ex5"
run_deploy
assert_eq "0" "$STATUS" "update deploy exit"
assert_file_content "${MT5_MQL5_ROOT}/Experts/FluxoReal/BoletaA.ex5" "boleta-a-binary-fixture" "vendored file updated"
assert_file_same "${VENDOR_MQL5_ROOT}/Experts/FluxoReal/BoletaA.ex5" \
    "${MT5_MQL5_ROOT}/Experts/FluxoReal/BoletaA.ex5" "updated file matches vendor"
pass "same-path vendored Expert is overwritten"
cleanup_case

echo "=== test 16: Experts mkdir/copy error is nonzero ==="
setup_case
make_mt5_install
make_full_vendor
mkdir -p "$MT5_MQL5_ROOT"
printf 'not-a-dir\n' >"${MT5_MQL5_ROOT}/Experts"
run_deploy
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$STATUS" -eq 0 ]; then
    fail "Experts mkdir/copy failure should be nonzero"
fi
echo "$OUTPUT" | grep -q "concluído\|concluido" && fail "done log must be absent on Experts failure"
echo "$OUTPUT" | grep -q "Experts vendorizados sincronizados" && fail "experts success log must be absent on failure"
pass "Experts copy/mkdir error returns nonzero"
cleanup_case

echo "=== test 17: Experts deploy is idempotent ==="
setup_case
make_mt5_install
make_full_vendor
mkdir -p "${MT5_MQL5_ROOT}/Experts/Manual"
printf 'manual-existing-content\n' >"${MT5_MQL5_ROOT}/Experts/Manual/MeuEA.ex5"
run_deploy
assert_eq "0" "$STATUS" "first idempotent deploy"
run_deploy
assert_eq "0" "$STATUS" "second idempotent deploy"
assert_file_exists "${MT5_MQL5_ROOT}/Experts/FluxoReal/BoletaA.ex5" "vendored still present"
assert_file_same "${VENDOR_MQL5_ROOT}/Experts/FluxoReal/BoletaA.ex5" \
    "${MT5_MQL5_ROOT}/Experts/FluxoReal/BoletaA.ex5" "idempotent cmp"
assert_file_content "${MT5_MQL5_ROOT}/Experts/Manual/MeuEA.ex5" "manual-existing-content" "manual kept after rerun"
assert_dir_missing "${MT5_MQL5_ROOT}/Experts/Experts" "no nested Experts after rerun"
assert_file_missing "${MT5_MQL5_ROOT}/Experts/FluxoReal/FluxoReal/BoletaA.ex5" "no duplicated subtree"
pass "repeat deploy is idempotent and additive"
cleanup_case

echo "=== summary ==="
echo "tests_run=${TESTS_RUN} passed=${TESTS_PASSED} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
