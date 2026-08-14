#!/bin/bash
# Deterministic startup/exit contract tests for vendor/bridge/mt5_bridge.py.
#
# Data flow: runs production mt5_bridge.py under system Python with temporary
# fake MetaTrader5 + rpyc + history_args modules. Limitations: no Wine, no real
# RPyC, no broker; does not cover exposed_* trading API semantics.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_PY="${ROOT}/vendor/bridge/mt5_bridge.py"

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

setup_fakes() {
    CASE_DIR="$(mktemp -d /tmp/mt5-bridge-startup.XXXXXX)"
    mkdir -p "${CASE_DIR}/rpyc/utils"

    cat >"${CASE_DIR}/history_args.py" <<'EOF'
def coerce_tick_time(*args, **kwargs):
    return None


def normalize_history_interval_args(*args, **kwargs):
    return args, kwargs
EOF

    cat >"${CASE_DIR}/MetaTrader5.py" <<'EOF'
import os

_LOG = os.environ.get("MT5_FAKE_LOG", "")
_INIT = os.environ.get("MT5_FAKE_INIT", "1") == "1"


def _record(event: str) -> None:
    if _LOG:
        with open(_LOG, "a", encoding="utf-8") as fh:
            fh.write(event + "\n")


def initialize(*args, **kwargs) -> bool:
    _record("initialize")
    return _INIT


def shutdown() -> None:
    _record("shutdown")


def last_error():
    return (1, "fake-init-failed")


def terminal_info():
    return None
EOF

    cat >"${CASE_DIR}/rpyc/__init__.py" <<'EOF'
class Service:
    pass
EOF

    cat >"${CASE_DIR}/rpyc/utils/__init__.py" <<'EOF'
EOF

    cat >"${CASE_DIR}/rpyc/utils/server.py" <<'EOF'
import os


class ThreadedServer:
    def __init__(self, service, port=None, protocol_config=None, **kwargs):
        log = os.environ.get("RPYC_FAKE_LOG", "")
        mode = os.environ.get("RPYC_FAKE_MODE", "ok")
        if mode == "ctor_raise":
            if log:
                with open(log, "a", encoding="utf-8") as fh:
                    fh.write("ctor\n")
            raise RuntimeError("ctor failed")
        self.service = service
        self.port = port
        self.protocol_config = protocol_config or {}
        if log:
            with open(log, "a", encoding="utf-8") as fh:
                fh.write(f"ctor port={port}\n")
                fh.write(
                    "config allow_public_attrs="
                    f"{self.protocol_config.get('allow_public_attrs')}\n"
                )
                fh.write(
                    "config allow_all_attrs="
                    f"{self.protocol_config.get('allow_all_attrs')}\n"
                )

    def start(self):
        log = os.environ.get("RPYC_FAKE_LOG", "")
        mode = os.environ.get("RPYC_FAKE_MODE", "ok")
        if log:
            with open(log, "a", encoding="utf-8") as fh:
                fh.write("start\n")
        if mode == "start_raise":
            raise RuntimeError("start failed")
        return None
EOF

    : >"${CASE_DIR}/mt5.log"
    : >"${CASE_DIR}/rpyc.log"
}

run_bridge_main() {
    set +e
    if [ "${RPYC_PORT_SET:-0}" = "1" ]; then
        OUTPUT="$(
            PYTHONPATH="${CASE_DIR}${PYTHONPATH:+:${PYTHONPATH}}" \
            MT5_FAKE_LOG="${CASE_DIR}/mt5.log" \
            MT5_FAKE_INIT="${MT5_FAKE_INIT:-1}" \
            RPYC_FAKE_LOG="${CASE_DIR}/rpyc.log" \
            RPYC_FAKE_MODE="${RPYC_FAKE_MODE:-ok}" \
            RPYC_PORT="${RPYC_PORT}" \
            python3 "$BRIDGE_PY" 2>&1
        )"
    else
        OUTPUT="$(
            env -u RPYC_PORT \
            PYTHONPATH="${CASE_DIR}${PYTHONPATH:+:${PYTHONPATH}}" \
            MT5_FAKE_LOG="${CASE_DIR}/mt5.log" \
            MT5_FAKE_INIT="${MT5_FAKE_INIT:-1}" \
            RPYC_FAKE_LOG="${CASE_DIR}/rpyc.log" \
            RPYC_FAKE_MODE="${RPYC_FAKE_MODE:-ok}" \
            python3 "$BRIDGE_PY" 2>&1
        )"
    fi
    STATUS=$?
    set -e
}

echo "=== test 1: default port 18812 ==="
setup_fakes
RPYC_PORT_SET=0
MT5_FAKE_INIT=1
RPYC_FAKE_MODE=ok
run_bridge_main
assert_eq "0" "$STATUS" "default port exit"
grep -qx "initialize" "${CASE_DIR}/mt5.log" || fail "initialize called"
grep -q "ctor port=18812" "${CASE_DIR}/rpyc.log" || fail "default port 18812"
grep -qx "start" "${CASE_DIR}/rpyc.log" || fail "server start"
grep -qx "shutdown" "${CASE_DIR}/mt5.log" || fail "shutdown after start returns"
echo "$OUTPUT" | grep -q "MT5 initialized successfully" || fail "success log"
TESTS_RUN=$((TESTS_RUN + 4))
pass "default port 18812 start+shutdown exit0"
rm -rf "$CASE_DIR"

echo "=== test 2: custom RPYC_PORT=18814 ==="
setup_fakes
RPYC_PORT_SET=1
RPYC_PORT=18814
MT5_FAKE_INIT=1
RPYC_FAKE_MODE=ok
run_bridge_main
assert_eq "0" "$STATUS" "custom port exit"
grep -q "ctor port=18814" "${CASE_DIR}/rpyc.log" || fail "custom port 18814"
TESTS_RUN=$((TESTS_RUN + 1))
pass "custom RPYC_PORT reaches ThreadedServer"
rm -rf "$CASE_DIR"

echo "=== test 3: invalid RPYC_PORT ==="
setup_fakes
RPYC_PORT_SET=1
RPYC_PORT=not-a-number
MT5_FAKE_INIT=1
RPYC_FAKE_MODE=ok
run_bridge_main
test "$STATUS" -ne 0 || fail "invalid port must be nonzero"
test ! -s "${CASE_DIR}/mt5.log" || fail "initialize must not run on invalid port"
test ! -s "${CASE_DIR}/rpyc.log" || fail "server must not be constructed on invalid port"
TESTS_RUN=$((TESTS_RUN + 3))
pass "invalid RPYC_PORT fails before initialize/server"
rm -rf "$CASE_DIR"

echo "=== test 4: initialize failure exits 1 ==="
setup_fakes
RPYC_PORT_SET=0
MT5_FAKE_INIT=0
RPYC_FAKE_MODE=ok
run_bridge_main
assert_eq "1" "$STATUS" "init failure exit1"
echo "$OUTPUT" | grep -q "initialize() failed" || fail "failure log"
grep -qx "initialize" "${CASE_DIR}/mt5.log" || fail "initialize called"
grep -q "shutdown" "${CASE_DIR}/mt5.log" && fail "shutdown must not run on init failure"
test ! -s "${CASE_DIR}/rpyc.log" || fail "server must not be constructed"
TESTS_RUN=$((TESTS_RUN + 3))
pass "initialize False → log + exit1 + no server/shutdown"
rm -rf "$CASE_DIR"

echo "=== test 5: start returns → shutdown exit0 ==="
setup_fakes
RPYC_PORT_SET=0
MT5_FAKE_INIT=1
RPYC_FAKE_MODE=ok
run_bridge_main
assert_eq "0" "$STATUS" "start returns exit0"
grep -qx "start" "${CASE_DIR}/rpyc.log" || fail "start"
grep -qx "shutdown" "${CASE_DIR}/mt5.log" || fail "finally shutdown"
pass "server.start returns → finally shutdown → exit0"
rm -rf "$CASE_DIR"

echo "=== test 6: start raises → shutdown nonzero ==="
setup_fakes
RPYC_PORT_SET=0
MT5_FAKE_INIT=1
RPYC_FAKE_MODE=start_raise
run_bridge_main
test "$STATUS" -ne 0 || fail "start raise must be nonzero"
grep -qx "start" "${CASE_DIR}/rpyc.log" || fail "start attempted"
grep -qx "shutdown" "${CASE_DIR}/mt5.log" || fail "finally shutdown on start raise"
TESTS_RUN=$((TESTS_RUN + 2))
pass "server.start raises → finally shutdown → nonzero"
rm -rf "$CASE_DIR"

echo "=== test 7: constructor raises → finally shutdown ==="
setup_fakes
RPYC_PORT_SET=0
MT5_FAKE_INIT=1
RPYC_FAKE_MODE=ctor_raise
run_bridge_main
test "$STATUS" -ne 0 || fail "ctor raise must be nonzero"
grep -qx "initialize" "${CASE_DIR}/mt5.log" || fail "initialize before ctor"
grep -qx "shutdown" "${CASE_DIR}/mt5.log" || fail "finally shutdown must run when ctor raises"
TESTS_RUN=$((TESTS_RUN + 2))
pass "ThreadedServer ctor raises → nonzero, finally shutdown"
rm -rf "$CASE_DIR"

echo "=== test 8: protocol_config flags ==="
setup_fakes
RPYC_PORT_SET=0
MT5_FAKE_INIT=1
RPYC_FAKE_MODE=ok
run_bridge_main
grep -qx "config allow_public_attrs=True" "${CASE_DIR}/rpyc.log" || fail "allow_public_attrs"
grep -qx "config allow_all_attrs=True" "${CASE_DIR}/rpyc.log" || fail "allow_all_attrs"
TESTS_RUN=$((TESTS_RUN + 2))
pass "protocol_config allow_public_attrs/allow_all_attrs True"
rm -rf "$CASE_DIR"

echo "=== test 9: exposed_shutdown is no-op ==="
setup_fakes
OUTPUT="$(
    PYTHONPATH="${CASE_DIR}${PYTHONPATH:+:${PYTHONPATH}}" \
    MT5_FAKE_LOG="${CASE_DIR}/mt5.log" \
    python3 - <<PY
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "mt5_bridge",
    Path(r"${BRIDGE_PY}"),
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
svc = mod.MT5Service()
result = svc.exposed_shutdown()
print(f"result={result!r}")
PY
)"
echo "$OUTPUT" | grep -qx "result=True" || fail "exposed_shutdown must return True"
grep -q "shutdown" "${CASE_DIR}/mt5.log" && fail "exposed_shutdown must not call mt5.shutdown"
TESTS_RUN=$((TESTS_RUN + 2))
pass "exposed_shutdown returns True without mt5.shutdown"
rm -rf "$CASE_DIR"

echo "=== test 10: no explicit signal handler ==="
grep -En 'signal\.signal|SIGTERM|SIGINT' "$BRIDGE_PY" && fail "unexpected signal handler references" || true
# Allow comments mentioning shutdown but forbid signal.signal installs.
if grep -E 'signal\.signal\s*\(' "$BRIDGE_PY"; then
    fail "signal.signal install present"
fi
if grep -E 'import[[:space:]]+signal|from[[:space:]]+signal[[:space:]]+import' "$BRIDGE_PY"; then
    fail "signal module imported"
fi
if grep -E 'quit\s*\(' "$BRIDGE_PY"; then
    fail "quit() must not remain on startup failure"
fi
TESTS_RUN=$((TESTS_RUN + 3))
pass "no explicit signal.signal / signal import; quit() removed"
rm -rf "${CASE_DIR:-}"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
