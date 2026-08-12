#!/bin/bash
# Deterministic tests for install_mt5.sh using fake curl/wine on PATH.
#
# Data flow: creates temp WINEPREFIX and fake-bin; invokes install_mt5.sh with bash.
# Limitations: no network, no real Wine, no broker volumes.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/images/mt5-headless/scripts/install_mt5.sh"

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
    CASE_DIR="$(mktemp -d /tmp/install-mt5-test.XXXXXX)"
    FAKE_BIN="${CASE_DIR}/fake-bin"
    PREFIX="${CASE_DIR}/wineprefix"
    LOG_DIR="${CASE_DIR}/logs"
    mkdir -p "$FAKE_BIN" "$PREFIX/drive_c" "$LOG_DIR"
    : >"${LOG_DIR}/curl.log"
    : >"${LOG_DIR}/wine.log"

    cat >"${FAKE_BIN}/curl" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
LOG_DIR="${INSTALL_MT5_TEST_LOG_DIR:?}"
echo "curl $*" >>"${LOG_DIR}/curl.log"
out=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "--output" ]; then
        out="$arg"
    fi
    prev="$arg"
done
if [ -z "$out" ]; then
    echo "fake curl: missing --output" >&2
    exit 1
fi
mkdir -p "$(dirname "$out")"
printf 'fake-installer\n' >"$out"
exit 0
EOF
    chmod +x "${FAKE_BIN}/curl"

    cat >"${FAKE_BIN}/wine" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
LOG_DIR="${INSTALL_MT5_TEST_LOG_DIR:?}"
MODE="${INSTALL_MT5_FAKE_WINE_MODE:-success}"
echo "wine $*" >>"${LOG_DIR}/wine.log"

installer=""
has_auto=0
is_webview=0
for arg in "$@"; do
    case "$arg" in
        */webview2.exe|*/webview2.exe*)
            is_webview=1
            installer="$arg"
            ;;
        */mt5setup.exe|*/mt5setup.exe*)
            installer="$arg"
            ;;
        /auto|"/auto")
            has_auto=1
            ;;
    esac
done

if [ "$is_webview" -eq 1 ]; then
    if [ "$MODE" = "webview_fail" ]; then
        exit 42
    fi
    exit 0
fi

case "$MODE" in
    success|webview_fail|mt5_nonzero_but_creates|manual_success|auto_success)
        if [ -n "${INSTALL_MT5_FAKE_CREATE_EXE:-}" ]; then
            mkdir -p "$(dirname "$INSTALL_MT5_FAKE_CREATE_EXE")"
            printf 'fake-terminal\n' >"$INSTALL_MT5_FAKE_CREATE_EXE"
        fi
        if [ "$MODE" = "mt5_nonzero_but_creates" ]; then
            exit 17
        fi
        exit 0
        ;;
    no_create)
        exit 0
        ;;
    *)
        echo "fake wine: unknown mode $MODE" >&2
        exit 99
        ;;
esac
EOF
    chmod +x "${FAKE_BIN}/wine"

    export PATH="${FAKE_BIN}:${PATH}"
    export INSTALL_MT5_TEST_LOG_DIR="$LOG_DIR"
    export WINEPREFIX="$PREFIX"
    export WINEARCH=win64
    export DISPLAY=:99
    export WINEDEBUG=-all
    export XDG_RUNTIME_DIR="${CASE_DIR}/runtime"
    mkdir -p "$XDG_RUNTIME_DIR"

    # Default: skip VNC barrier so install semantics stay the focus.
    export ENABLE_VNC=0
    export DISPLAY_BACKEND=xvnc
    export VNC_PORT=5900
    export INSTALL_MT5_VNC_TIMEOUT_SECONDS=1
    unset INSTALL_MT5_FAKE_CREATE_EXE || true
    unset INSTALL_MT5_FAKE_WINE_MODE || true
    unset MT5_EXE || true
    unset MT5_INSTALL_MODE || true
}

run_install() {
    set +e
    OUTPUT="$(bash "$SCRIPT" 2>&1)"
    STATUS=$?
    set -e
}

curl_called() {
    [ -s "${LOG_DIR}/curl.log" ]
}

wine_called() {
    [ -s "${LOG_DIR}/wine.log" ]
}

cleanup_case() {
    rm -rf "$CASE_DIR"
}

echo "=== test 1: INSTALL_MT5=0 skip ==="
setup_case
export INSTALL_MT5=0
run_install
assert_eq "0" "$STATUS" "skip exit"
echo "$OUTPUT" | grep -q "INSTALL_MT5=0" || fail "skip log missing"
curl_called && fail "curl should not run on skip"
wine_called && fail "wine should not run on skip"
pass "INSTALL_MT5=0 skips downloads"
cleanup_case

echo "=== test 2: MT5 already installed ==="
setup_case
export INSTALL_MT5=1
export MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
mkdir -p "$(dirname "$MT5_EXE")"
printf 'existing\n' >"$MT5_EXE"
run_install
assert_eq "0" "$STATUS" "already installed exit"
echo "$OUTPUT" | grep -q "já instalado" || fail "already installed log missing"
curl_called && fail "curl should not run when MT5 exists"
wine_called && fail "wine should not run when MT5 exists"
assert_file_exists "$MT5_EXE" "existing exe preserved"
pass "already installed is idempotent"
cleanup_case

echo "=== test 3: auto success ==="
setup_case
export INSTALL_MT5=1
export MT5_INSTALL_MODE=auto
export MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
export INSTALL_MT5_FAKE_WINE_MODE=auto_success
export INSTALL_MT5_FAKE_CREATE_EXE="$MT5_EXE"
run_install
assert_eq "0" "$STATUS" "auto exit"
curl_called || fail "curl should run in auto install"
grep -q "/auto" "${LOG_DIR}/wine.log" || fail "auto mode missing /auto"
assert_file_exists "$MT5_EXE" "auto created exe"
assert_file_missing "${PREFIX}/drive_c/mt5setup.exe" "mt5 installer cleaned"
assert_file_missing "${PREFIX}/drive_c/webview2.exe" "webview installer cleaned"
pass "auto install success"
cleanup_case

echo "=== test 4: manual success ==="
setup_case
export INSTALL_MT5=1
export MT5_INSTALL_MODE=manual
export MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
export INSTALL_MT5_FAKE_WINE_MODE=manual_success
export INSTALL_MT5_FAKE_CREATE_EXE="$MT5_EXE"
run_install
assert_eq "0" "$STATUS" "manual exit"
grep -q "mt5setup.exe" "${LOG_DIR}/wine.log" || fail "manual wine missing mt5setup"
grep -q "/auto" "${LOG_DIR}/wine.log" && fail "manual mode must not pass /auto"
assert_file_exists "$MT5_EXE" "manual created exe"
pass "manual install success"
cleanup_case

echo "=== test 5: webview nonzero continues ==="
setup_case
export INSTALL_MT5=1
export MT5_INSTALL_MODE=auto
export MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
export INSTALL_MT5_FAKE_WINE_MODE=webview_fail
export INSTALL_MT5_FAKE_CREATE_EXE="$MT5_EXE"
run_install
assert_eq "0" "$STATUS" "webview fail still succeeds if MT5 exists"
echo "$OUTPUT" | grep -q "WebView2 retornou código: 42" || fail "webview status not logged"
assert_file_exists "$MT5_EXE" "mt5 created despite webview fail"
pass "webview nonzero is nonfatal"
cleanup_case

echo "=== test 6: mt5 installer nonzero but exe exists ==="
setup_case
export INSTALL_MT5=1
export MT5_INSTALL_MODE=auto
export MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
export INSTALL_MT5_FAKE_WINE_MODE=mt5_nonzero_but_creates
export INSTALL_MT5_FAKE_CREATE_EXE="$MT5_EXE"
run_install
assert_eq "0" "$STATUS" "nonzero installer ok when exe exists"
echo "$OUTPUT" | grep -q "Instalador MT5 retornou código: 17" || fail "installer status not logged"
assert_file_exists "$MT5_EXE" "exe exists after nonzero installer"
pass "installer nonzero accepted when exe present"
cleanup_case

echo "=== test 7: terminal missing after install ==="
setup_case
export INSTALL_MT5=1
export MT5_INSTALL_MODE=auto
export MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
export INSTALL_MT5_FAKE_WINE_MODE=no_create
unset INSTALL_MT5_FAKE_CREATE_EXE || true
run_install
assert_eq "1" "$STATUS" "missing terminal exits 1"
echo "$OUTPUT" | grep -q "terminal64.exe não encontrado" || fail "missing terminal log absent"
pass "missing terminal fails"
cleanup_case

echo "=== test 8: path with spaces ==="
setup_case
export INSTALL_MT5=1
export MT5_INSTALL_MODE=auto
export MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
export INSTALL_MT5_FAKE_WINE_MODE=auto_success
export INSTALL_MT5_FAKE_CREATE_EXE="$MT5_EXE"
run_install
assert_eq "0" "$STATUS" "spaces path exit"
assert_file_exists "$MT5_EXE" "spaces path exe"
pass "Program Files path works"
cleanup_case

echo "=== test 9: custom MT5_EXE ==="
setup_case
export INSTALL_MT5=1
export MT5_INSTALL_MODE=auto
export MT5_EXE="${PREFIX}/custom/dir/my-terminal64.exe"
export INSTALL_MT5_FAKE_WINE_MODE=auto_success
export INSTALL_MT5_FAKE_CREATE_EXE="$MT5_EXE"
run_install
assert_eq "0" "$STATUS" "custom exe exit"
assert_file_exists "$MT5_EXE" "custom exe created"
pass "custom MT5_EXE honored"
cleanup_case

echo "=== test 10: VNC unavailable fails before download ==="
setup_case
export INSTALL_MT5=1
export MT5_INSTALL_MODE=auto
export MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
export ENABLE_VNC=1
export DISPLAY_BACKEND=xvnc
export VNC_PORT=1
export INSTALL_MT5_VNC_TIMEOUT_SECONDS=1
unset INSTALL_MT5_FAKE_CREATE_EXE || true
run_install
assert_eq "1" "$STATUS" "vnc timeout exit"
echo "$OUTPUT" | grep -q "state=FAILED reason=vnc_not_ready" || fail "vnc_not_ready log missing"
curl_called && fail "curl must not run when VNC not ready"
wine_called && fail "wine must not run when VNC not ready"
assert_file_missing "$MT5_EXE" "exe absent after VNC failure"
pass "VNC unavailable blocks downloads"
cleanup_case

echo "=== test 11: VNC ready allows install ==="
setup_case
export INSTALL_MT5=1
export MT5_INSTALL_MODE=auto
export MT5_EXE="${PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
export ENABLE_VNC=1
export DISPLAY_BACKEND=xvnc
export INSTALL_MT5_VNC_TIMEOUT_SECONDS=5
export INSTALL_MT5_FAKE_WINE_MODE=auto_success
export INSTALL_MT5_FAKE_CREATE_EXE="$MT5_EXE"

VNC_LISTENER_PORT="$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
export VNC_PORT="$VNC_LISTENER_PORT"

python3 - <<'PY' &
import socket
import time
import os

port = int(os.environ["VNC_PORT"])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
srv.settimeout(10.0)
deadline = time.time() + 10.0
while time.time() < deadline:
    try:
        conn, _addr = srv.accept()
        conn.close()
        break
    except socket.timeout:
        continue
srv.close()
PY
VNC_LISTENER_PID=$!
sleep 0.2

run_install
assert_eq "0" "$STATUS" "vnc ready install exit"
echo "$OUTPUT" | grep -q "state=VNC_READY provider=xvnc" || fail "VNC_READY log missing"
curl_called || fail "curl should run after VNC ready"
assert_file_exists "$MT5_EXE" "exe created after VNC ready"
pass "VNC ready allows install"
kill "$VNC_LISTENER_PID" 2>/dev/null || true
wait "$VNC_LISTENER_PID" 2>/dev/null || true
cleanup_case

echo "=== summary ==="
echo "tests_run=${TESTS_RUN} passed=${TESTS_PASSED} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
