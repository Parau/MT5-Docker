#!/bin/bash
# Deterministic tests for bootstrap_python.sh contract (no real Wine/network/MT5).
#
# Data flow: stateful fake wine/curl/wineserver on PATH; command log asserts
# install vs fast-path vs failure branches. Limitations: does not exercise the
# entrypoint nonfatal wrapper or real Wine Python.
# Temporal finding: wineserver -w is only on the install path; concurrency with
# long-lived Wine clients is validated empirically outside this suite.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/images/mt5-headless/scripts/bootstrap_python.sh"

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
        fail "${label}: missing '${path}'"
    fi
}

assert_file_missing() {
    local path="$1"
    local label="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -f "$path" ]; then
        fail "${label}: unexpected '${path}'"
    fi
}

setup_case() {
    CASE_DIR="$(mktemp -d /tmp/bootstrap-python-test.XXXXXX)"
    FAKE_BIN="${CASE_DIR}/bin"
    STATE_DIR="${CASE_DIR}/state"
    CMD_LOG="${CASE_DIR}/cmd.log"
    mkdir -p "$FAKE_BIN" "$STATE_DIR"
    : >"$CMD_LOG"

    export WINEPREFIX="${CASE_DIR}/wineprefix"
    mkdir -p "$WINEPREFIX"
    unset PYTHON_VERSION || true
    unset PYTHON_INSTALLER_URL || true

    # Defaults match production unless a test overrides.
    echo 0 >"${STATE_DIR}/python_installed"
    echo 0 >"${STATE_DIR}/packages_installed"
    echo 1 >"${STATE_DIR}/numpy_major"
    echo 0 >"${STATE_DIR}/curl_status"
    echo 0 >"${STATE_DIR}/installer_status"
    echo 0 >"${STATE_DIR}/wineserver_status"
    echo 0 >"${STATE_DIR}/pip_upgrade_status"
    echo 0 >"${STATE_DIR}/pip_packages_status"
    echo 0 >"${STATE_DIR}/final_ok_broken"
    echo 0 >"${STATE_DIR}/installer_does_not_enable_python"

    cat >"${FAKE_BIN}/wine" <<'EOF'
#!/bin/bash
set -e
STATE_DIR="${BOOTSTRAP_FAKE_STATE:?}"
CMD_LOG="${BOOTSTRAP_FAKE_LOG:?}"
echo "wine $*" >>"$CMD_LOG"

python_installed="$(cat "${STATE_DIR}/python_installed")"
packages_installed="$(cat "${STATE_DIR}/packages_installed")"
numpy_major="$(cat "${STATE_DIR}/numpy_major")"

# wine python -c "..."
if [ "${1:-}" = "python" ] && [ "${2:-}" = "-c" ]; then
    if [ "$python_installed" != "1" ] || [ "$packages_installed" != "1" ]; then
        exit 1
    fi
    if [ "$numpy_major" != "1" ]; then
        exit 1
    fi
    if [ "$(cat "${STATE_DIR}/final_ok_broken")" = "1" ] && grep -q "final_ok_broken_armed" "${STATE_DIR}/flags" 2>/dev/null; then
        exit 1
    fi
    exit 0
fi

# wine python --version
if [ "${1:-}" = "python" ] && [ "${2:-}" = "--version" ]; then
    if [ "$python_installed" = "1" ]; then
        echo "Python 3.11.9"
        exit 0
    fi
    exit 1
fi

# wine python -m pip ...
if [ "${1:-}" = "python" ] && [ "${2:-}" = "-m" ] && [ "${3:-}" = "pip" ]; then
    shift 3
    if [ "${1:-}" = "install" ] && [ "${2:-}" = "--upgrade" ] && [ "${3:-}" = "pip" ]; then
        st="$(cat "${STATE_DIR}/pip_upgrade_status")"
        if [ "$st" != "0" ]; then
            exit "$st"
        fi
        # Arm final-ok breakage after successful pip path starts, if requested.
        if [ "$(cat "${STATE_DIR}/final_ok_broken")" = "1" ]; then
            echo final_ok_broken_armed >"${STATE_DIR}/flags"
        fi
        exit 0
    fi
    if [ "${1:-}" = "install" ]; then
        st="$(cat "${STATE_DIR}/pip_packages_status")"
        if [ "$st" != "0" ]; then
            exit "$st"
        fi
        echo 1 >"${STATE_DIR}/packages_installed"
        echo 1 >"${STATE_DIR}/numpy_major"
        if [ "$(cat "${STATE_DIR}/final_ok_broken")" = "1" ]; then
            echo final_ok_broken_armed >"${STATE_DIR}/flags"
            # Keep packages_installed=1 but force wine_python_ok to fail via flag.
        fi
        exit 0
    fi
    if [ "${1:-}" = "show" ]; then
        cat <<'SHOW'
Name: MetaTrader5
Version: 5.0.0
---
Name: rpyc
Version: 5.0.0
---
Name: numpy
Version: 1.26.4
SHOW
        exit 0
    fi
    exit 1
fi

# wine <installer.exe> ...
case "${1:-}" in
    *.exe)
        st="$(cat "${STATE_DIR}/installer_status")"
        if [ "$st" != "0" ]; then
            exit "$st"
        fi
        if [ "$(cat "${STATE_DIR}/installer_does_not_enable_python")" = "1" ]; then
            exit 0
        fi
        echo 1 >"${STATE_DIR}/python_installed"
        exit 0
        ;;
esac

exit 1
EOF
    chmod +x "${FAKE_BIN}/wine"

    cat >"${FAKE_BIN}/curl" <<'EOF'
#!/bin/bash
set -e
STATE_DIR="${BOOTSTRAP_FAKE_STATE:?}"
CMD_LOG="${BOOTSTRAP_FAKE_LOG:?}"
echo "curl $*" >>"$CMD_LOG"
st="$(cat "${STATE_DIR}/curl_status")"
out=""
url=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-o" ]; then
        out="$arg"
    fi
    prev="$arg"
done
url="${@: -1}"
echo "curl_url=${url}" >>"$CMD_LOG"
echo "curl_out=${out}" >>"$CMD_LOG"
if [ "$st" != "0" ]; then
    exit "$st"
fi
if [ -z "$out" ]; then
    exit 2
fi
printf 'fake-installer\n' >"$out"
exit 0
EOF
    chmod +x "${FAKE_BIN}/curl"

    cat >"${FAKE_BIN}/wineserver" <<'EOF'
#!/bin/bash
set -e
STATE_DIR="${BOOTSTRAP_FAKE_STATE:?}"
CMD_LOG="${BOOTSTRAP_FAKE_LOG:?}"
echo "wineserver $*" >>"$CMD_LOG"
st="$(cat "${STATE_DIR}/wineserver_status")"
exit "$st"
EOF
    chmod +x "${FAKE_BIN}/wineserver"

    export BOOTSTRAP_FAKE_STATE="$STATE_DIR"
    export BOOTSTRAP_FAKE_LOG="$CMD_LOG"
    export PATH="${FAKE_BIN}:${PATH}"
}

set_state() {
    local key="$1"
    local val="$2"
    printf '%s\n' "$val" >"${STATE_DIR}/${key}"
}

run_script() {
    set +e
    OUTPUT="$(bash "$SCRIPT" 2>&1)"
    STATUS=$?
    set -e
}

cmd_log_has() {
    grep -Fq "$1" "$CMD_LOG"
}

cmd_log_missing() {
    ! grep -Fq "$1" "$CMD_LOG"
}

cleanup_case() {
    rm -rf "$CASE_DIR"
}

echo "=== test 1: fast path complete ==="
setup_case
set_state python_installed 1
set_state packages_installed 1
set_state numpy_major 1
run_script
assert_eq "0" "$STATUS" "fast path exit"
echo "$OUTPUT" | grep -q "já presentes" || fail "fast path log missing"
cmd_log_has "wine python -c" || fail "ok probe missing"
cmd_log_has "wine python --version" || fail "version on fast path missing"
cmd_log_missing "curl " || fail "curl must not run on fast path"
cmd_log_missing "wineserver" || fail "wineserver must not run on fast path"
cmd_log_missing "pip install" || fail "pip must not run on fast path"
TESTS_RUN=$((TESTS_RUN + 5))
pass "fast path skips install/pip"
cleanup_case

echo "=== test 2: python absent / full install ==="
setup_case
set_state python_installed 0
set_state packages_installed 0
run_script
assert_eq "0" "$STATUS" "full install exit"
echo "$OUTPUT" | grep -q "BOOTSTRAP_PYTHON: OK" || fail "OK log missing"
cmd_log_has "curl -fL --retry 3 -o /tmp/python-3.11.9-amd64.exe" || fail "curl flags/path"
cmd_log_has "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe" || fail "default URL"
cmd_log_has "wine /tmp/python-3.11.9-amd64.exe /quiet InstallAllUsers=0 PrependPath=1 Include_pip=1" || fail "installer args"
cmd_log_has "wineserver -w" || fail "wineserver -w missing"
cmd_log_has "wine python -m pip install --upgrade pip" || fail "pip upgrade missing"
cmd_log_has 'wine python -m pip install numpy<2 MetaTrader5 rpyc' || fail "pip packages missing"
assert_file_missing "/tmp/python-3.11.9-amd64.exe" "installer cleaned"
# Order: curl before installer before wineserver before pip
python3 - <<PY || fail "command order"
from pathlib import Path
log = Path("${CMD_LOG}").read_text().splitlines()
def idx(prefix):
    for i, line in enumerate(log):
        if line.startswith(prefix) or prefix in line:
            return i
    raise SystemExit(f"missing {prefix}")
i_curl = idx("curl ")
i_inst = idx("wine /tmp/python-3.11.9-amd64.exe")
i_ws = idx("wineserver -w")
i_pipu = idx("wine python -m pip install --upgrade pip")
i_pipp = idx("wine python -m pip install numpy<2")
if not (i_curl < i_inst < i_ws < i_pipu < i_pipp):
    raise SystemExit(f"bad order {[i_curl,i_inst,i_ws,i_pipu,i_pipp]}")
print("order ok")
PY
TESTS_RUN=$((TESTS_RUN + 8))
pass "full install path ordered and complete"
cleanup_case

echo "=== test 3: python present / packages absent ==="
setup_case
set_state python_installed 1
set_state packages_installed 0
run_script
assert_eq "0" "$STATUS" "packages path exit"
cmd_log_missing "curl " || fail "no curl when python present"
cmd_log_missing "wineserver" || fail "no wineserver when python present"
cmd_log_has "wine python -m pip install --upgrade pip" || fail "pip upgrade required"
cmd_log_has 'wine python -m pip install numpy<2 MetaTrader5 rpyc' || fail "pip packages required"
echo "$OUTPUT" | grep -q "BOOTSTRAP_PYTHON: OK" || fail "OK missing"
TESTS_RUN=$((TESTS_RUN + 4))
pass "packages-only path skips installer"
cleanup_case

echo "=== test 4: numpy 2.x is repaired ==="
setup_case
set_state python_installed 1
set_state packages_installed 1
set_state numpy_major 2
run_script
assert_eq "0" "$STATUS" "numpy2 repair exit"
cmd_log_missing "curl " || fail "no reinstall for numpy2"
cmd_log_missing "wineserver" || fail "no wineserver for numpy2"
cmd_log_has "wine python -m pip install --upgrade pip" || fail "pip upgrade for numpy2"
cmd_log_has 'wine python -m pip install numpy<2 MetaTrader5 rpyc' || fail "pip repair for numpy2"
assert_eq "1" "$(cat "${STATE_DIR}/numpy_major")" "numpy major repaired"
TESTS_RUN=$((TESTS_RUN + 4))
pass "numpy 2.x triggers package repair"
cleanup_case

echo "=== test 5: curl failure ==="
setup_case
set_state python_installed 0
set_state curl_status 22
run_script
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$STATUS" -eq 0 ]; then
    fail "curl failure should be nonzero"
fi
cmd_log_has "curl " || fail "curl attempted"
cmd_log_missing "wine /tmp/python-" || fail "installer must not run after curl fail"
cmd_log_missing "wineserver" || fail "wineserver must not run after curl fail"
cmd_log_missing "pip install" || fail "pip must not run after curl fail"
TESTS_RUN=$((TESTS_RUN + 3))
pass "curl failure is raw nonzero"
cleanup_case

echo "=== test 6: installer failure (legacy cleanup) ==="
setup_case
set_state python_installed 0
set_state installer_status 42
run_script
assert_eq "42" "$STATUS" "installer failure status"
cmd_log_has "curl " || fail "curl before installer"
cmd_log_has "wine /tmp/python-3.11.9-amd64.exe" || fail "installer attempted"
# Legacy: rm -f after installer may not run under set -e; installer may remain.
assert_file_exists "/tmp/python-3.11.9-amd64.exe" "legacy leftover installer on failure"
cmd_log_missing "wineserver" || fail "wineserver must not run after installer fail"
cmd_log_missing "pip install" || fail "pip must not run after installer fail"
echo "NOTE: legacy cleanup behavior on installer failure — rm -f may not run"
TESTS_RUN=$((TESTS_RUN + 4))
rm -f /tmp/python-3.11.9-amd64.exe
pass "installer failure propagates; leftover installer is legacy"
cleanup_case

echo "=== test 7: wineserver -w failure tolerated ==="
setup_case
set_state python_installed 0
set_state wineserver_status 77
run_script
assert_eq "0" "$STATUS" "wineserver fail tolerated exit"
cmd_log_has "wineserver -w" || fail "wineserver called"
cmd_log_has "wine python -m pip install --upgrade pip" || fail "pip continues after wineserver fail"
echo "$OUTPUT" | grep -q "BOOTSTRAP_PYTHON: OK" || fail "OK after wineserver fail"
TESTS_RUN=$((TESTS_RUN + 2))
pass "wineserver -w || true allows continue"
cleanup_case

echo "=== test 8: python still absent after installer ==="
setup_case
set_state python_installed 0
set_state installer_does_not_enable_python 1
run_script
assert_eq "1" "$STATUS" "missing python after install exit"
echo "$OUTPUT" | grep -q "Wine Python não encontrado após instalação" || fail "missing-after-install log"
cmd_log_has "wineserver -w" || fail "wineserver still called after installer"
cmd_log_missing "pip install" || fail "pip must not run when python missing"
TESTS_RUN=$((TESTS_RUN + 2))
pass "python missing after installer is fatal before pip"
cleanup_case

echo "=== test 9: pip upgrade failure ==="
setup_case
set_state python_installed 1
set_state packages_installed 0
set_state pip_upgrade_status 17
run_script
assert_eq "17" "$STATUS" "pip upgrade failure status"
cmd_log_has "wine python -m pip install --upgrade pip" || fail "pip upgrade attempted"
cmd_log_missing 'wine python -m pip install numpy<2' || fail "package install must not run"
TESTS_RUN=$((TESTS_RUN + 2))
pass "pip upgrade failure is raw nonzero"
cleanup_case

echo "=== test 10: package install failure ==="
setup_case
set_state python_installed 1
set_state packages_installed 0
set_state pip_packages_status 23
run_script
assert_eq "23" "$STATUS" "package install failure status"
cmd_log_has "wine python -m pip install --upgrade pip" || fail "upgrade before packages"
cmd_log_has 'wine python -m pip install numpy<2 MetaTrader5 rpyc' || fail "packages attempted"
echo "$OUTPUT" | grep -q "BOOTSTRAP_PYTHON: OK" && fail "OK must be absent"
TESTS_RUN=$((TESTS_RUN + 2))
pass "package install failure is raw nonzero"
cleanup_case

echo "=== test 11: final validation failure ==="
setup_case
set_state python_installed 1
set_state packages_installed 0
set_state final_ok_broken 1
run_script
assert_eq "1" "$STATUS" "final validation exit"
echo "$OUTPUT" | grep -q "ERRO: bootstrap Python incompleto" || fail "incomplete log missing"
TESTS_RUN=$((TESTS_RUN + 1))
pass "final wine_python_ok failure is fatal"
cleanup_case

echo "=== test 12: PYTHON_VERSION override ==="
setup_case
set_state python_installed 0
export PYTHON_VERSION="3.11.X_TEST"
run_script
assert_eq "0" "$STATUS" "version override exit"
cmd_log_has "curl_out=/tmp/python-3.11.X_TEST-amd64.exe" || fail "installer path override"
cmd_log_has "https://www.python.org/ftp/python/3.11.X_TEST/python-3.11.X_TEST-amd64.exe" || fail "URL override from version"
TESTS_RUN=$((TESTS_RUN + 2))
pass "PYTHON_VERSION overrides URL and installer path"
cleanup_case

echo "=== test 13: PYTHON_INSTALLER_URL override ==="
setup_case
set_state python_installed 0
export PYTHON_INSTALLER_URL="https://example.test/custom-python.exe"
run_script
assert_eq "0" "$STATUS" "url override exit"
cmd_log_has "curl_url=https://example.test/custom-python.exe" || fail "custom URL not used"
TESTS_RUN=$((TESTS_RUN + 1))
pass "PYTHON_INSTALLER_URL override honored"
cleanup_case

echo "=== test 14: raw has no BOOTSTRAP_PYTHON gate ==="
TESTS_RUN=$((TESTS_RUN + 1))
# Gate ownership = caller/entrypoint. Comments may mention the name; executable body must not.
BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$SCRIPT")"
if echo "$BODY" | grep -Eq '\$\{BOOTSTRAP_PYTHON|BOOTSTRAP_PYTHON:-|\[\s*"\$\{BOOTSTRAP_PYTHON'; then
    fail "raw must not gate on BOOTSTRAP_PYTHON (gate ownership = caller/entrypoint)"
fi
# Log strings "BOOTSTRAP_PYTHON: ..." are allowed.
pass "raw has no BOOTSTRAP_PYTHON gate (caller-owned)"

echo "=== test 15: raw has no MT5 readiness dependency ==="
TESTS_RUN=$((TESTS_RUN + 1))
# Executable lines only: ignore comment block.
BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$SCRIPT")"
echo "$BODY" | grep -Eq 'terminal64\.exe|MetaTrader5\.initialize|terminal_info|RPYC_PORT|8765|8767|websocket' && fail "MT5 readiness dependency found in executable body"
echo "$BODY" | grep -Eq '\$\{RUN_MT5|RUN_MT5=' && fail "RUN_MT5 gate found in raw"
pass "raw has no MT5 readiness / RUN_MT5 dependency"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
