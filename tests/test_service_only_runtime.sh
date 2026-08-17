#!/bin/bash
# Service-only runtime tests: no CMD/entrypoint; s6 PID1 + longruns keep the box up.
#
# Data flow: inspects the built image, then runs TEMP containers with noop oneshots
# and fake metatrader/bridge lifecycles. Limitations: no broker volumes; display/VNC
# still start; wine-bootstrap/install/deploy/configure/python are no-oped via mounts.
# After 04J-B there is no project wineserver -k finalizer.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-mt5-docker-mt5-amp:latest}"
NAME_PREFIX="mt5_svc_only_$$"
SMOKE_DIR="$(mktemp -d /tmp/svc-only.XXXXXX)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

cleanup() {
    docker rm -f \
        "${NAME_PREFIX}_up" \
        "${NAME_PREFIX}_bridge" \
        "${NAME_PREFIX}_crash" \
        "${NAME_PREFIX}_fatal" \
        "${NAME_PREFIX}_run0" \
        "${NAME_PREFIX}_stop" \
        2>/dev/null || true
    rm -rf "$SMOKE_DIR"
}
trap cleanup EXIT

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

prepare_smoke() {
    mkdir -p "${SMOKE_DIR}/bin"
    cat >"${SMOKE_DIR}/noop.sh" <<'EOF'
#!/bin/bash
echo "SMOKE_NOOP ok"
exit 0
EOF
    cat >"${SMOKE_DIR}/stay.sh" <<'EOF'
#!/bin/bash
echo "FAKE_STAY name=${FAKE_NAME:-unknown} pid=$$"
echo $$ > "/smoke/${FAKE_NAME:-stay}.pid"
trap 'echo "FAKE_STAY name=${FAKE_NAME:-unknown} got TERM"; exit 0' TERM
while true; do sleep 1; done
EOF
    cat >"${SMOKE_DIR}/bridge_stay.sh" <<'EOF'
#!/bin/bash
echo "FAKE_BRIDGE_STAY pid=$$"
echo $$ > /smoke/bridge.pid
trap 'echo FAKE_BRIDGE_STAY got TERM; exit 0' TERM
while true; do sleep 1; done
EOF
    cat >"${SMOKE_DIR}/mt_stay.sh" <<'EOF'
#!/bin/bash
echo "FAKE_MT_STAY pid=$$"
echo $$ > /smoke/metatrader.pid
trap 'echo FAKE_MT_STAY got TERM; exit 0' TERM
while true; do sleep 1; done
EOF
    cat >"${SMOKE_DIR}/exit42.sh" <<'EOF'
#!/bin/bash
count=0
if [ -f /smoke/bridge_count ]; then count="$(cat /smoke/bridge_count)"; fi
count=$((count + 1))
echo "$count" > /smoke/bridge_count
echo "FAKE_BRIDGE_EXIT42 count=${count} pid=$$"
sleep 0.2
exit 42
EOF
    cat >"${SMOKE_DIR}/mt_exit42.sh" <<'EOF'
#!/bin/bash
echo "FAKE_MT_EXIT42 pid=$$"
exit 42
EOF
    chmod +x "${SMOKE_DIR}/noop.sh" "${SMOKE_DIR}/stay.sh" "${SMOKE_DIR}/bridge_stay.sh" \
        "${SMOKE_DIR}/mt_stay.sh" "${SMOKE_DIR}/exit42.sh" "${SMOKE_DIR}/mt_exit42.sh"
    echo 0 >"${SMOKE_DIR}/bridge_count"
}

common_mounts() {
    MOUNTS=(
        -v "${SMOKE_DIR}:/smoke"
        -v "${SMOKE_DIR}/noop.sh:/scripts/wine_bootstrap.sh:ro"
        -v "${SMOKE_DIR}/noop.sh:/scripts/install_mt5.sh:ro"
        -v "${SMOKE_DIR}/noop.sh:/scripts/deploy_mql5_oneshot.sh:ro"
        -v "${SMOKE_DIR}/noop.sh:/scripts/configure_nt5_oneshot.sh:ro"
        -v "${SMOKE_DIR}/noop.sh:/scripts/bootstrap_python_oneshot.sh:ro"
    )
}

run_temp() {
    local name="$1"
    shift
    docker rm -f "$name" >/dev/null 2>&1 || true
    common_mounts
    docker run -d --name "$name" \
        "${MOUNTS[@]}" \
        -e RESET_WINEPREFIX=0 \
        -e INSTALL_MT5=0 \
        -e DEPLOY_MQL5=0 \
        -e CONFIGURE_NT5=0 \
        -e BOOTSTRAP_PYTHON=0 \
        -e ENABLE_VNC=1 \
        -e VNC_PASSWORD=smokepass \
        "$@" \
        "$IMAGE" >/dev/null
}

wait_log() {
    local name="$1"
    local pattern="$2"
    local seconds="${3:-60}"
    local i
    for i in $(seq 1 "$seconds"); do
        if docker logs "$name" 2>&1 | grep -q "$pattern"; then
            return 0
        fi
        if ! docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
            if docker logs "$name" 2>&1 | grep -q "$pattern"; then
                return 0
            fi
            return 1
        fi
        sleep 1
    done
    return 1
}

prepare_smoke

echo "=== A: IMAGE CONFIG ==="
EP="$(docker image inspect "$IMAGE" --format '{{json .Config.Entrypoint}}')"
CMD="$(docker image inspect "$IMAGE" --format '{{json .Config.Cmd}}')"
echo "Entrypoint=${EP} Cmd=${CMD}"
echo "$EP" | grep -Fq '/init' || fail "Entrypoint must be /init"
if [ "$CMD" != "null" ] && [ "$CMD" != "[]" ] && [ -n "$CMD" ] && [ "$CMD" != "<no value>" ]; then
    fail "Cmd must be absent/null/empty, got ${CMD}"
fi
docker run --rm --entrypoint bash "$IMAGE" -lc '
set -Eeuo pipefail
test ! -e /entrypoint.sh
test ! -e /etc/cont-finish.d/10-wine-cleanup
test -d /etc/s6-overlay/s6-rc.d/metatrader
test -d /etc/s6-overlay/s6-rc.d/bridge
test -x /scripts/healthcheck_mt5.sh
head -1 /scripts/healthcheck_mt5.sh | grep -Fq with-contenv
'
HC="$(docker image inspect "$IMAGE" --format '{{json .Config.Healthcheck}}')"
echo "Healthcheck=${HC}"
echo "$HC" | grep -Fq '/scripts/healthcheck_mt5.sh' || fail "HEALTHCHECK missing script"
echo "$HC" | grep -Fq 'PATH=/command' || fail "HEALTHCHECK must prefix /command for with-contenv"
echo "$HC" | grep -Fq '$$PATH' && fail "HEALTHCHECK must not contain \$\$PATH"
echo "$HC" | grep -E 'PATH=/command:(\$PATH|/opt/wine-stable/bin)' >/dev/null \
  || fail "HEALTHCHECK must keep \$PATH or baked Wine path"
TESTS_RUN=$((TESTS_RUN + 6))
pass "image Entrypoint=/init, Cmd empty, no entrypoint, no wine finalizer, HEALTHCHECK PATH"

echo "=== B: SERVICE-ONLY UP (RUN_BRIDGE=0) ==="
run_temp "${NAME_PREFIX}_up" \
    -e RUN_MT5=1 \
    -e RUN_BRIDGE=0 \
    -e FAKE_NAME=metatrader \
    -e MT5_LIFECYCLE_SCRIPT=/smoke/stay.sh
wait_log "${NAME_PREFIX}_up" "FAKE_STAY name=metatrader" 90 || fail "metatrader fake did not start"
sleep 5
RUNNING="$(docker inspect -f '{{.State.Running}}' "${NAME_PREFIX}_up")"
assert_eq "true" "$RUNNING" "container up >=5s"
PID1="$(docker exec "${NAME_PREFIX}_up" bash -lc 'tr -d "\0" < /proc/1/comm')"
echo "PID1_comm=${PID1}"
echo "$PID1" | grep -Eq 's6-svscan|s6-linux-init' || fail "PID1 must be s6"
docker exec "${NAME_PREFIX}_up" bash -lc 'test ! -e /entrypoint.sh'
docker logs "${NAME_PREFIX}_up" 2>&1 | grep -Eq 'cmd_liveness_barrier|sleep 3600|WINE-FINALIZER' && fail "barrier/finalizer residue"
docker rm -f "${NAME_PREFIX}_up" >/dev/null
TESTS_RUN=$((TESTS_RUN + 2))
pass "service-only UP without CMD/barrier/finalizer"

echo "=== C: BRIDGE ENABLED ==="
run_temp "${NAME_PREFIX}_bridge" \
    -e RUN_MT5=1 \
    -e RUN_BRIDGE=1 \
    -e MT5_LIFECYCLE_SCRIPT=/smoke/mt_stay.sh \
    -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/bridge_stay.sh
wait_log "${NAME_PREFIX}_bridge" "FAKE_MT_STAY" 90 || fail "mt stay"
wait_log "${NAME_PREFIX}_bridge" "FAKE_BRIDGE_STAY" 90 || fail "bridge stay"
RUNNING="$(docker inspect -f '{{.State.Running}}' "${NAME_PREFIX}_bridge")"
assert_eq "true" "$RUNNING" "both services up"
docker rm -f "${NAME_PREFIX}_bridge" >/dev/null
pass "bridge+metatrader up without CMD"

echo "=== D: BRIDGE CRASH restart, metatrader stable ==="
echo 0 >"${SMOKE_DIR}/bridge_count"
run_temp "${NAME_PREFIX}_crash" \
    -e RUN_MT5=1 \
    -e RUN_BRIDGE=1 \
    -e MT5_LIFECYCLE_SCRIPT=/smoke/mt_stay.sh \
    -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/exit42.sh
wait_log "${NAME_PREFIX}_crash" "FAKE_MT_STAY" 90 || fail "mt for crash case"
for _i in $(seq 1 40); do
    cnt="$(docker exec "${NAME_PREFIX}_crash" bash -lc 'cat /smoke/bridge_count' 2>/dev/null || echo 0)"
    if [ "${cnt:-0}" -ge 2 ]; then
        break
    fi
    sleep 1
done
cnt="$(docker exec "${NAME_PREFIX}_crash" bash -lc 'cat /smoke/bridge_count')"
[ "${cnt}" -ge 2 ] || fail "bridge restart count>=2 got ${cnt}"
MT_PID1="$(docker exec "${NAME_PREFIX}_crash" bash -lc 'cat /smoke/metatrader.pid')"
sleep 2
MT_PID2="$(docker exec "${NAME_PREFIX}_crash" bash -lc 'cat /smoke/metatrader.pid')"
assert_eq "$MT_PID1" "$MT_PID2" "metatrader PID stable"
RUNNING="$(docker inspect -f '{{.State.Running}}' "${NAME_PREFIX}_crash")"
assert_eq "true" "$RUNNING" "container stays up on bridge crash"
docker logs "${NAME_PREFIX}_crash" 2>&1 | grep -q 'cleanup_result=quiescent' || fail "finish quiescent"
docker rm -f "${NAME_PREFIX}_crash" >/dev/null
TESTS_RUN=$((TESTS_RUN + 2))
pass "bridge crash restarts without CMD; container stays up"

echo "=== E: METATRADER FATAL exit42 (no finalizer) ==="
run_temp "${NAME_PREFIX}_fatal" \
    -e RUN_MT5=1 \
    -e RUN_BRIDGE=0 \
    -e MT5_LIFECYCLE_SCRIPT=/smoke/mt_exit42.sh
for _i in $(seq 1 90); do
    st="$(docker inspect -f '{{.State.Status}}' "${NAME_PREFIX}_fatal" 2>/dev/null || echo gone)"
    if [ "$st" = "exited" ]; then
        break
    fi
    sleep 1
done
code="$(docker inspect -f '{{.State.ExitCode}}' "${NAME_PREFIX}_fatal")"
assert_eq "42" "$code" "fatal container exit"
docker logs "${NAME_PREFIX}_fatal" 2>&1 | grep -q 'WINE-FINALIZER' && fail "must not run finalizer"
docker rm -f "${NAME_PREFIX}_fatal" >/dev/null
pass "metatrader fatal exit42 without CMD/finalizer"

echo "=== F: RUN_MT5=0 → exit0, bridge count0 ==="
echo 0 >"${SMOKE_DIR}/bridge_count"
run_temp "${NAME_PREFIX}_run0" \
    -e RUN_MT5=0 \
    -e RUN_BRIDGE=1 \
    -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/exit42.sh
for _i in $(seq 1 90); do
    st="$(docker inspect -f '{{.State.Status}}' "${NAME_PREFIX}_run0" 2>/dev/null || echo gone)"
    if [ "$st" = "exited" ]; then
        break
    fi
    sleep 1
done
code="$(docker inspect -f '{{.State.ExitCode}}' "${NAME_PREFIX}_run0")"
assert_eq "0" "$code" "RUN_MT5=0 exit0"
bc="$(cat "${SMOKE_DIR}/bridge_count")"
assert_eq "0" "$bc" "bridge not started"
docker logs "${NAME_PREFIX}_run0" 2>&1 | grep -q 'WINE-FINALIZER' && fail "no finalizer"
docker rm -f "${NAME_PREFIX}_run0" >/dev/null
pass "RUN_MT5=0 exits 0; bridge disabled; no finalizer"

echo "=== G: NORMAL STOP order bridge < metatrader ==="
run_temp "${NAME_PREFIX}_stop" \
    -e RUN_MT5=1 \
    -e RUN_BRIDGE=1 \
    -e MT5_LIFECYCLE_SCRIPT=/smoke/mt_stay.sh \
    -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/bridge_stay.sh
wait_log "${NAME_PREFIX}_stop" "FAKE_MT_STAY" 90 || fail "mt stay for stop"
wait_log "${NAME_PREFIX}_stop" "FAKE_BRIDGE_STAY" 90 || fail "bridge stay for stop"
docker stop -t 20 "${NAME_PREFIX}_stop" >/dev/null
code="$(docker inspect -f '{{.State.ExitCode}}' "${NAME_PREFIX}_stop")"
assert_eq "0" "$code" "normal stop exit0"
docker logs "${NAME_PREFIX}_stop" 2>&1 >"${SMOKE_DIR}/stop.log"
grep -q 'BRIDGE-FINISH' "${SMOKE_DIR}/stop.log" || fail "bridge finish on stop"
grep -q 'WINE-FINALIZER' "${SMOKE_DIR}/stop.log" && fail "must not run WINE-FINALIZER"
ORDER_LOG="${SMOKE_DIR}/stop.log" python3 - <<'PY' || fail "bridge < metatrader order"
import os, sys
logs = open(os.environ["ORDER_LOG"], encoding="utf-8", errors="replace").read().splitlines()

def last_idx(pred):
    idx = -1
    for i, line in enumerate(logs):
        if pred(line):
            idx = i
    return idx

bi = last_idx(lambda l: "BRIDGE-FINISH" in l or "FAKE_BRIDGE_STAY got TERM" in l)
mi = last_idx(lambda l: "METATRADER-FINISH" in l or "FAKE_MT_STAY got TERM" in l)
print(f"order indices bridge={bi} mt={mi}")
if bi < 0 or mi < 0:
    sys.exit(1)
if not (bi < mi):
    sys.exit(2)
print("bridge < metatrader OK")
PY
docker rm -f "${NAME_PREFIX}_stop" >/dev/null
TESTS_RUN=$((TESTS_RUN + 2))
pass "stop order: bridge before metatrader; no Wine finalizer"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
