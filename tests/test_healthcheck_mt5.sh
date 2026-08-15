#!/bin/bash
# Deterministic unit tests for images/mt5-headless/scripts/healthcheck_mt5.sh.
#
# Data flow: runs production healthcheck with fake s6-svstat and wine on PATH
# seams. Limitations: no Docker HEALTHCHECK daemon, no real Wine/RPyC/broker.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/images/mt5-headless/scripts/healthcheck_mt5.sh"

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

setup_case() {
    CASE_DIR="$(mktemp -d /tmp/healthcheck.XXXXXX)"
    mkdir -p "${CASE_DIR}/bin" "${CASE_DIR}/service/metatrader" "${CASE_DIR}/service/bridge"
    echo 0 >"${CASE_DIR}/svstat_calls"
    echo 0 >"${CASE_DIR}/wine_calls"
    : >"${CASE_DIR}/svstat_log"
    : >"${CASE_DIR}/wine_log"

    cat >"${CASE_DIR}/bin/fake-svstat" <<EOF
#!/bin/bash
echo "svstat \$*" >> "${CASE_DIR}/svstat_log"
count=\$(cat "${CASE_DIR}/svstat_calls")
echo \$((count + 1)) > "${CASE_DIR}/svstat_calls"
# Usage: fake-svstat -u /path/service
svc="\${2:-}"
base="\$(basename "\$svc")"
case "\$base" in
  metatrader) cat "${CASE_DIR}/mt_state" ;;
  bridge) cat "${CASE_DIR}/br_state" ;;
  *) echo false ;;
esac
EOF
    chmod +x "${CASE_DIR}/bin/fake-svstat"

    cat >"${CASE_DIR}/bin/fake-wine" <<EOF
#!/bin/bash
echo "wine \$*" >> "${CASE_DIR}/wine_log"
count=\$(cat "${CASE_DIR}/wine_calls")
echo \$((count + 1)) > "${CASE_DIR}/wine_calls"
mode="\$(cat "${CASE_DIR}/wine_mode")"
case "\$mode" in
  ok) exit 0 ;;
  fail) exit 1 ;;
  block) sleep 30; exit 1 ;;
  *) exit 1 ;;
esac
EOF
    chmod +x "${CASE_DIR}/bin/fake-wine"

    # Real timeout from the host/container PATH is fine; pin via env.
    echo true >"${CASE_DIR}/mt_state"
    echo true >"${CASE_DIR}/br_state"
    echo ok >"${CASE_DIR}/wine_mode"
}

run_hc() {
    set +e
    OUTPUT="$(
        S6_SVSTAT_BIN="${CASE_DIR}/bin/fake-svstat" \
        S6_SERVICE_ROOT="${CASE_DIR}/service" \
        HEALTHCHECK_WINE_BIN="${CASE_DIR}/bin/fake-wine" \
        HEALTHCHECK_TIMEOUT_BIN="$(command -v timeout)" \
        HEALTHCHECK_RPC_TIMEOUT_SECONDS="${HEALTHCHECK_RPC_TIMEOUT_SECONDS:-5}" \
        "$@" \
        bash "$SCRIPT" 2>&1
    )"
    STATUS=$?
    set -e
}

echo "=== unit 1: RUN_MT5=0 disabled ==="
setup_case
run_hc env RUN_MT5=0 RUN_BRIDGE=1
assert_eq "0" "$STATUS" "disabled exit"
echo "$OUTPUT" | grep -q 'state=DISABLED reason=RUN_MT5' || fail "disabled log: ${OUTPUT}"
assert_eq "0" "$(cat "${CASE_DIR}/svstat_calls")" "no svstat"
assert_eq "0" "$(cat "${CASE_DIR}/wine_calls")" "no wine"
pass "RUN_MT5=0 disabled"
rm -rf "$CASE_DIR"

echo "=== unit 2: mt5-only healthy ==="
setup_case
echo true >"${CASE_DIR}/mt_state"
run_hc env RUN_MT5=1 RUN_BRIDGE=0
assert_eq "0" "$STATUS" "mt5-only exit"
echo "$OUTPUT" | grep -q 'mode=mt5-only evidence=metatrader-up' || fail "mt5-only log"
assert_eq "0" "$(cat "${CASE_DIR}/wine_calls")" "no wine in mt5-only"
pass "mt5-only healthy"
rm -rf "$CASE_DIR"

echo "=== unit 3: mt5-only down ==="
setup_case
echo false >"${CASE_DIR}/mt_state"
run_hc env RUN_MT5=1 RUN_BRIDGE=0
assert_eq "1" "$STATUS" "mt5-only down exit"
echo "$OUTPUT" | grep -q 'reason=metatrader-down' || fail "down log"
assert_eq "0" "$(cat "${CASE_DIR}/wine_calls")" "no wine"
pass "mt5-only down"
rm -rf "$CASE_DIR"

echo "=== unit 4: bridge mode metatrader down ==="
setup_case
echo false >"${CASE_DIR}/mt_state"
echo true >"${CASE_DIR}/br_state"
run_hc env RUN_MT5=1 RUN_BRIDGE=1
assert_eq "1" "$STATUS" "mt down exit"
echo "$OUTPUT" | grep -q 'reason=metatrader-down' || fail "mt down log"
assert_eq "0" "$(cat "${CASE_DIR}/wine_calls")" "no wine"
# Bridge must not be consulted once MT is down (only metatrader queried).
grep -q 'bridge' "${CASE_DIR}/svstat_log" && fail "bridge must not be queried"
pass "bridge mode stops at metatrader-down"
rm -rf "$CASE_DIR"

echo "=== unit 5: bridge down ==="
setup_case
echo true >"${CASE_DIR}/mt_state"
echo false >"${CASE_DIR}/br_state"
run_hc env RUN_MT5=1 RUN_BRIDGE=1
assert_eq "1" "$STATUS" "bridge down exit"
echo "$OUTPUT" | grep -q 'reason=bridge-down' || fail "bridge-down log"
assert_eq "0" "$(cat "${CASE_DIR}/wine_calls")" "no wine"
pass "bridge down"
rm -rf "$CASE_DIR"

echo "=== unit 6: rpyc health true ==="
setup_case
echo true >"${CASE_DIR}/mt_state"
echo true >"${CASE_DIR}/br_state"
echo ok >"${CASE_DIR}/wine_mode"
run_hc env RUN_MT5=1 RUN_BRIDGE=1 RPYC_PORT=18814
assert_eq "0" "$STATUS" "healthy exit"
echo "$OUTPUT" | grep -q 'state=HEALTHY mode=bridge evidence=rpyc+mt5-connected' || fail "healthy log"
assert_eq "1" "$(cat "${CASE_DIR}/wine_calls")" "wine once"
pass "rpyc health true"
rm -rf "$CASE_DIR"

echo "=== unit 7: rpyc health false ==="
setup_case
echo fail >"${CASE_DIR}/wine_mode"
run_hc env RUN_MT5=1 RUN_BRIDGE=1 RPYC_PORT=18814
assert_eq "1" "$STATUS" "unhealthy exit"
echo "$OUTPUT" | grep -q 'state=UNHEALTHY reason=rpyc-or-mt5-not-ready' || fail "unhealthy log"
pass "rpyc health false"
rm -rf "$CASE_DIR"

echo "=== unit 8: client timeout ==="
setup_case
echo block >"${CASE_DIR}/wine_mode"
run_hc env RUN_MT5=1 RUN_BRIDGE=1 RPYC_PORT=18814 HEALTHCHECK_RPC_TIMEOUT_SECONDS=1
assert_eq "1" "$STATUS" "timeout exit"
echo "$OUTPUT" | grep -q 'reason=timeout' || fail "timeout log: ${OUTPUT}"
# No leftover sleep from fake-wine (timeout should kill the process group member).
pgrep -f "${CASE_DIR}/bin/fake-wine" >/dev/null 2>&1 && fail "fake-wine residual"
pass "client timeout bounded"
rm -rf "$CASE_DIR"

echo "=== unit 9: invalid RPyC port ==="
setup_case
# Empty RPYC_PORT uses script default 18812 (${RPYC_PORT:-18812}); reject only explicit garbage.
for bad in abc 0 65536 -1; do
    run_hc env RUN_MT5=1 RUN_BRIDGE=1 RPYC_PORT="$bad"
    assert_eq "1" "$STATUS" "invalid port '${bad}'"
    echo "$OUTPUT" | grep -q 'reason=invalid_rpyc_port' || fail "invalid port log for '${bad}'"
    assert_eq "0" "$(cat "${CASE_DIR}/wine_calls")" "no wine for '${bad}'"
    echo 0 >"${CASE_DIR}/wine_calls"
done
pass "invalid ports rejected"
rm -rf "$CASE_DIR"

echo "=== unit 9b: empty RPYC_PORT defaults ==="
setup_case
run_hc env RUN_MT5=1 RUN_BRIDGE=1 RPYC_PORT=
assert_eq "0" "$STATUS" "empty port defaults to 18812"
assert_eq "1" "$(cat "${CASE_DIR}/wine_calls")" "wine after default port"
pass "empty RPYC_PORT uses default"
rm -rf "$CASE_DIR"

echo "=== unit 10: no initialize / MetaTrader5 in client ==="
BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$SCRIPT")"
echo "$BODY" | grep -Fq 'MetaTrader5' && fail "must not import MetaTrader5"
echo "$BODY" | grep -Fq 'mt5.initialize' && fail "must not call mt5.initialize"
echo "$BODY" | grep -Fq 'initialize(' && fail "must not call initialize("
echo "$BODY" | grep -Fq 'root.health()' || fail "must call root.health()"
TESTS_RUN=$((TESTS_RUN + 4))
pass "client uses RPyC health only"

echo "=== unit 11: no secrets in script/output paths ==="
echo "$BODY" | grep -Eq 'MT5_PASSWORD|VNC_PASSWORD|printenv|/proc/.*/environ' && fail "secrets residue"
setup_case
run_hc env RUN_MT5=1 RUN_BRIDGE=1 RPYC_PORT=18814 MT5_PASSWORD=secret VNC_PASSWORD=secret MT5_LOGIN=999
echo "$OUTPUT" | grep -Eq 'MT5_PASSWORD|VNC_PASSWORD|MT5_LOGIN|secret' && fail "secrets leaked: ${OUTPUT}"
TESTS_RUN=$((TESTS_RUN + 2))
pass "no secrets in healthcheck"
rm -rf "$CASE_DIR"

echo "=== unit 12: image inspect path typo regression helper ==="
# Prove strict mode would fail on missing path (masks the old metatrade typo).
set +e
OUT="$(bash -Eeuo pipefail -lc 'test -d /etc/s6-overlay/s6-rc.d/metatrade_does_not_exist' 2>&1)"
ST=$?
set -e
assert_eq "1" "$ST" "missing path must fail under -e"
pass "strict test -d fails on missing path"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
