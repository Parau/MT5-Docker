#!/bin/bash
# Deterministic tests for configure_nt5.sh / configure_nt5_service.py contract.
#
# Data flow: temp WINEPREFIX + UTF-16 fixtures; shell tests use fake python3
# on PATH; Python tests invoke configure_nt5_service.py directly.
# Limitations: no Wine/MT5/Docker/network; does not exercise the entrypoint
# nonfatal wrapper. Legacy: services.ini without NT5 is replaced, not appended.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_SCRIPT="${ROOT}/images/mt5-headless/scripts/configure_nt5.sh"
PY_SCRIPT="${ROOT}/images/mt5-headless/scripts/configure_nt5_service.py"

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

setup_case() {
    CASE_DIR="$(mktemp -d /tmp/configure-nt5-test.XXXXXX)"
    WINEPREFIX="${CASE_DIR}/wineprefix"
    MT5_CONFIG="${WINEPREFIX}/drive_c/Program Files/MetaTrader 5/Config"
    COMMON_INI="${MT5_CONFIG}/common.ini"
    SERVICES_INI="${MT5_CONFIG}/services.ini"
    FAKE_BIN="${CASE_DIR}/fake-bin"
    mkdir -p "$FAKE_BIN" "$WINEPREFIX"

    export WINEPREFIX
    unset NT5_WS_URL || true
    unset NT5_WS_SYMBOLS || true
    unset NT5_SERVICE_ENABLED || true
    unset CONFIGURE_NT5 || true
}

make_config_dir() {
    mkdir -p "$MT5_CONFIG"
}

write_utf16() {
    local dest="$1"
    local content="$2"
    printf '%s' "$content" | python3 -c '
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(sys.stdin.read(), encoding="utf-16")
' "$dest"
}

read_utf16() {
    python3 -c '
from pathlib import Path
import sys
sys.stdout.write(Path(sys.argv[1]).read_text(encoding="utf-16"))
' "$1"
}

file_sha256() {
    python3 -c '
from pathlib import Path
import hashlib
import sys
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
' "$1"
}

run_shell() {
    set +e
    OUTPUT="$(bash "$SHELL_SCRIPT" 2>&1)"
    STATUS=$?
    set -e
}

run_python() {
    set +e
    OUTPUT="$(python3 "$PY_SCRIPT" 2>&1)"
    STATUS=$?
    set -e
}

cleanup_case() {
    rm -rf "$CASE_DIR"
}

echo "=== test 1: CONFIGURE_NT5=0 skip ==="
setup_case
cat >"${FAKE_BIN}/python3" <<'EOF'
#!/bin/bash
echo "python3 called $*" >>"${CONFIGURE_NT5_TEST_LOG:?}"
exit 42
EOF
chmod +x "${FAKE_BIN}/python3"
export CONFIGURE_NT5_TEST_LOG="${CASE_DIR}/python.log"
: >"$CONFIGURE_NT5_TEST_LOG"
export PATH="${FAKE_BIN}:${PATH}"
export CONFIGURE_NT5=0
run_shell
assert_eq "0" "$STATUS" "configure=0 exit"
echo "$OUTPUT" | grep -q "Configuração NT5 ignorada" || fail "skip log missing"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -s "$CONFIGURE_NT5_TEST_LOG" ]; then
    fail "python3 must not be called when CONFIGURE_NT5=0"
fi
assert_dir_missing "$MT5_CONFIG" "no Config created on skip"
pass "CONFIGURE_NT5=0 skips without python"
cleanup_case

echo "=== test 2: python3 absent ==="
setup_case
EMPTY_BIN="${CASE_DIR}/empty-bin"
mkdir -p "$EMPTY_BIN"
export CONFIGURE_NT5=1
set +e
OUTPUT="$(env PATH="$EMPTY_BIN" /bin/bash "$SHELL_SCRIPT" 2>&1)"
STATUS=$?
set -e
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$STATUS" -eq 0 ]; then
    fail "python3 absent should be nonzero"
fi
echo "$OUTPUT" | grep -q "python3 ausente" || fail "python3 absent log missing"
assert_dir_missing "$MT5_CONFIG" "no Config created without python3"
pass "python3 absent is raw nonzero"
cleanup_case

echo "=== test 3: raw python failure propagates ==="
setup_case
cat >"${FAKE_BIN}/python3" <<'EOF'
#!/bin/bash
echo "python3 called $*" >>"${CONFIGURE_NT5_TEST_LOG:?}"
exit 42
EOF
chmod +x "${FAKE_BIN}/python3"
export CONFIGURE_NT5_TEST_LOG="${CASE_DIR}/python.log"
: >"$CONFIGURE_NT5_TEST_LOG"
export PATH="${FAKE_BIN}:${PATH}"
export CONFIGURE_NT5=1
run_shell
assert_eq "42" "$STATUS" "python failure status"
TESTS_RUN=$((TESTS_RUN + 1))
if [ ! -s "$CONFIGURE_NT5_TEST_LOG" ]; then
    fail "fake python3 should have been called"
fi
pass "shell does not mask python failure"
cleanup_case

echo "=== test 4: Config dir absent ==="
setup_case
export CONFIGURE_NT5=1
run_python
assert_eq "0" "$STATUS" "config absent exit"
echo "$OUTPUT" | grep -q "MT5 config dir ausente — ignorando" || fail "config absent log missing"
assert_dir_missing "$MT5_CONFIG" "Config must stay absent"
pass "missing Config dir is skip 0"
cleanup_case

echo "=== test 5: services absent / common absent ==="
setup_case
make_config_dir
export NT5_WS_URL="ws://example.test:9999/mt5-feed"
export NT5_WS_SYMBOLS="FOO,BAR"
export NT5_SERVICE_ENABLED="1"
run_python
assert_eq "0" "$STATUS" "create services exit"
assert_file_missing "$COMMON_INI" "common.ini not created"
assert_file_exists "$SERVICES_INI" "services.ini created"
TEXT="$(read_utf16 "$SERVICES_INI")"
echo "$TEXT" | grep -q "name=NT5TickFeedService" || fail "name missing"
echo "$TEXT" | grep -q 'path=Services\\NT5TickFeedService.ex5' || fail "path missing"
echo "$TEXT" | grep -q "enabled=1" || fail "enabled=1 missing"
echo "$TEXT" | grep -q "InpWsUrl=ws://example.test:9999/mt5-feed" || fail "url missing"
echo "$TEXT" | grep -q "InpSymbols=FOO,BAR" || fail "symbols missing"
echo "$TEXT" | grep -q "InpSleepMs=10" || fail "sleep missing"
echo "$TEXT" | grep -q "InpBatchSize=100" || fail "batch missing"
echo "$TEXT" | grep -q "InpBarSpecs=" || fail "barspecs missing"
echo "$TEXT" | grep -q "InpBarPollMs=300" || fail "barpoll missing"
echo "$TEXT" | grep -q "InpHeartbeatSec=30" || fail "heartbeat missing"
echo "$TEXT" | grep -q "InpDebug=true" || fail "debug missing"
echo "$OUTPUT" | grep -q "whitelist manual" || fail "whitelist hint missing"
echo "$OUTPUT" | grep -q "example.test" || fail "whitelist host missing"
TESTS_RUN=$((TESTS_RUN + 12))
pass "creates UTF-16 services.ini; does not create common.ini"
cleanup_case

echo "=== test 6: common.ini Experts flags ==="
setup_case
make_config_dir
write_utf16 "$COMMON_INI" $'[Common]\r\nFoo=Bar\r\n\r\n[Experts]\r\nEnabled=0\r\nWebRequest=0\r\nKeepMe=123\r\n\r\n[Other]\r\nEnabled=9\r\n'
export NT5_SERVICE_ENABLED=1
run_python
assert_eq "0" "$STATUS" "common flags exit"
TEXT="$(read_utf16 "$COMMON_INI")"
echo "$TEXT" | grep -Fq "[Experts]" || fail "Experts section missing"
echo "$TEXT" | grep -q "KeepMe=123" || fail "KeepMe lost"
echo "$TEXT" | grep -Fq "[Other]" || fail "Other section missing"
python3 -c '
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding="utf-16")
parts = text.split("[Experts]")
if len(parts) < 2:
    raise SystemExit("no Experts")
experts, rest = parts[1].split("[Other]", 1)
if "Enabled=1" not in experts:
    raise SystemExit("Experts Enabled not 1")
if "WebRequest=1" not in experts:
    raise SystemExit("Experts WebRequest not 1")
if "Enabled=0" in experts or "WebRequest=0" in experts:
    raise SystemExit("old Experts flags remain")
if "Enabled=9" not in rest:
    raise SystemExit("Other Enabled mutated")
' "$COMMON_INI" || fail "Experts/Other flag contract"
TESTS_RUN=$((TESTS_RUN + 5))
pass "Experts flags patched; other sections preserved"
cleanup_case

echo "=== test 7: common.ini without Enabled/WebRequest ==="
setup_case
make_config_dir
write_utf16 "$COMMON_INI" $'[Experts]\r\nKeepMe=123\r\n'
run_python
assert_eq "0" "$STATUS" "no keys exit"
TEXT="$(read_utf16 "$COMMON_INI")"
echo "$TEXT" | grep -q "KeepMe=123" || fail "KeepMe lost"
echo "$TEXT" | grep -q "Enabled=1" && fail "must not insert Enabled=1"
echo "$TEXT" | grep -q "WebRequest=1" && fail "must not insert WebRequest=1"
TESTS_RUN=$((TESTS_RUN + 3))
pass "missing Experts keys are not inserted"
cleanup_case

echo "=== test 8: existing NT5 services.ini patched ==="
setup_case
make_config_dir
write_utf16 "$SERVICES_INI" $'\r\n<service>\r\nname=NT5TickFeedService\r\nenabled=0\r\n<inputs>\r\nInpWsUrl=ws://old:1111/old\r\nInpSymbols=OLD\r\nKeepMe=abc\r\n</inputs>\r\n</service>\r\n'
export NT5_WS_URL="ws://new.test:2222/mt5-feed"
export NT5_WS_SYMBOLS="NEW"
export NT5_SERVICE_ENABLED="1"
run_python
assert_eq "0" "$STATUS" "patch existing NT5 exit"
TEXT="$(read_utf16 "$SERVICES_INI")"
echo "$TEXT" | grep -q "InpWsUrl=ws://new.test:2222/mt5-feed" || fail "url not updated"
echo "$TEXT" | grep -q "InpSymbols=NEW" || fail "symbols not updated"
echo "$TEXT" | grep -q "enabled=1" || fail "enabled not updated"
echo "$TEXT" | grep -q "KeepMe=abc" || fail "KeepMe lost"
echo "$TEXT" | grep -q "ws://old:1111/old" && fail "old url remains"
TESTS_RUN=$((TESTS_RUN + 5))
pass "existing NT5 block is patched in place"
cleanup_case

echo "=== test 9: idempotence ==="
setup_case
make_config_dir
write_utf16 "$COMMON_INI" $'[Experts]\r\nEnabled=0\r\nWebRequest=0\r\n'
export NT5_WS_URL="ws://idem.test:1/mt5-feed"
export NT5_WS_SYMBOLS="IDEM"
export NT5_SERVICE_ENABLED="1"
run_python
assert_eq "0" "$STATUS" "first run exit"
COMMON_HASH1="$(file_sha256 "$COMMON_INI")"
SERVICES_HASH1="$(file_sha256 "$SERVICES_INI")"
cp "$SERVICES_INI" "${CASE_DIR}/services.first.ini"
run_python
assert_eq "0" "$STATUS" "second run exit"
COMMON_HASH2="$(file_sha256 "$COMMON_INI")"
SERVICES_HASH2="$(file_sha256 "$SERVICES_INI")"
assert_eq "$COMMON_HASH1" "$COMMON_HASH2" "common.ini bytes stable"
if [ "$SERVICES_HASH1" = "$SERVICES_HASH2" ]; then
    echo "services.ini bytes identical across runs"
else
    python3 -c '
from pathlib import Path
import sys
first = Path(sys.argv[1]).read_bytes()
second = Path(sys.argv[2]).read_bytes()
t1 = first.decode("utf-16").replace("\r\n", "\n").replace("\r", "\n")
t2 = second.decode("utf-16").replace("\r\n", "\n").replace("\r", "\n")
if t1 != t2:
    raise SystemExit("textual mismatch after newline normalize")
print("NOTE: services.ini bytes change on second write.")
print("Cause: Path.read_text uses universal newlines, so the first-run CRLF")
print("payload is read back as LF; _write_utf16 only restores a trailing CRLF.")
print("Textual content is equivalent after newline normalize.")
' "${CASE_DIR}/services.first.ini" "$SERVICES_INI" || fail "services.ini textual equivalence"
fi
TESTS_RUN=$((TESTS_RUN + 1))
pass "second run is text-equivalent (common.ini bytes stable)"
cleanup_case

echo "=== test 10: services.ini without NT5 is replaced ==="
setup_case
make_config_dir
write_utf16 "$SERVICES_INI" $'\r\n<service>\r\nname=OtherService\r\nenabled=1\r\n<inputs>\r\nFoo=Bar\r\n</inputs>\r\n</service>\r\n'
export NT5_WS_URL="ws://replace.test:3/mt5-feed"
export NT5_WS_SYMBOLS="REPL"
export NT5_SERVICE_ENABLED="1"
run_python
assert_eq "0" "$STATUS" "replace exit"
TEXT="$(read_utf16 "$SERVICES_INI")"
echo "$TEXT" | grep -q "NT5TickFeedService" || fail "NT5 not written"
echo "$TEXT" | grep -q "OtherService" && fail "OtherService must be replaced"
echo "$TEXT" | grep -q "Foo=Bar" && fail "Foo=Bar must be replaced"
TESTS_RUN=$((TESTS_RUN + 3))
pass "legacy: services.ini without NT5 is replaced not appended"
cleanup_case

echo "=== test 11: NT5_SERVICE_ENABLED=0 ==="
setup_case
make_config_dir
export NT5_SERVICE_ENABLED=0
run_python
assert_eq "0" "$STATUS" "enabled=0 exit"
TEXT="$(read_utf16 "$SERVICES_INI")"
echo "$TEXT" | grep -q "enabled=0" || fail "enabled=0 missing"
echo "$TEXT" | grep -q "enabled=1" && fail "enabled unexpectedly 1"
TESTS_RUN=$((TESTS_RUN + 2))
pass "NT5_SERVICE_ENABLED=0 writes enabled=0"
cleanup_case

echo "=== test 12: invalid UTF-16 is raw failure ==="
setup_case
make_config_dir
printf 'not-utf16\xff\xfe\x00' >"$SERVICES_INI"
run_python
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$STATUS" -eq 0 ]; then
    fail "invalid UTF-16 should be nonzero"
fi
pass "invalid UTF-16 propagates as raw failure"
cleanup_case

echo "=== test 13: Python defaults ==="
setup_case
make_config_dir
run_python
assert_eq "0" "$STATUS" "defaults exit"
TEXT="$(read_utf16 "$SERVICES_INI")"
echo "$TEXT" | grep -q "InpWsUrl=ws://host.docker.internal:8765/mt5-feed" || fail "default url"
echo "$TEXT" | grep -q "InpSymbols=BTCUSD" || fail "default symbols"
echo "$TEXT" | grep -q "enabled=0" || fail "default enabled"
TESTS_RUN=$((TESTS_RUN + 3))
pass "defaults are 8765/BTCUSD/enabled=0"
cleanup_case

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
