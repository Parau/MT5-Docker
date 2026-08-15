#!/bin/bash
# Evidence gate: shutdown without project-specific global wineserver -k.
#
# Data flow: static checks on the candidate tree/image, then TEMP s6 containers
# with fake lifecycles (and optional test-only stage3 observer). Limitations:
# no broker volumes; oneshots no-oped; observer never baked into production.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-mt5-docker-mt5-amp:latest}"
OBSERVER="${ROOT}/tests/fixtures/stage3_wine_observer.sh"
DOCKERFILE="${ROOT}/images/mt5-headless/Dockerfile"
NAME_PREFIX="mt5_nogk_$$"
SMOKE_DIR="$(mktemp -d /tmp/nogk.XXXXXX)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

cleanup() {
    docker rm -f \
        "${NAME_PREFIX}_stop" \
        "${NAME_PREFIX}_crash" \
        "${NAME_PREFIX}_fatal" \
        "${NAME_PREFIX}_run0" \
        "${NAME_PREFIX}_stray" \
        "${NAME_PREFIX}_obs" \
        "${NAME_PREFIX}_winew" \
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
    mkdir -p "${SMOKE_DIR}/bin" "${SMOKE_DIR}/finish.d"
    cat >"${SMOKE_DIR}/noop.sh" <<'EOF'
#!/bin/bash
echo "SMOKE_NOOP ok"
exit 0
EOF
    cat >"${SMOKE_DIR}/mt_stay.sh" <<'EOF'
#!/bin/bash
echo "FAKE_MT_STAY pid=$$"
echo $$ > /smoke/metatrader.pid
trap 'date +%s%N > /smoke/ts_mt_term; echo FAKE_MT_STAY got TERM; exit 0' TERM
while true; do sleep 1; done
EOF
    cat >"${SMOKE_DIR}/bridge_stay.sh" <<'EOF'
#!/bin/bash
echo "FAKE_BRIDGE_STAY pid=$$"
echo $$ > /smoke/bridge.pid
trap 'date +%s%N > /smoke/ts_bridge_term; echo FAKE_BRIDGE_STAY got TERM; exit 0' TERM
while true; do sleep 1; done
EOF
    cat >"${SMOKE_DIR}/exit42.sh" <<'EOF'
#!/bin/bash
count=0
if [ -f /smoke/bridge_count ]; then count="$(cat /smoke/bridge_count)"; fi
count=$((count + 1))
echo "$count" > /smoke/bridge_count
if [ -f /smoke/prev_pid ]; then
  prev="$(cat /smoke/prev_pid)"
  if kill -0 "$prev" 2>/dev/null; then
    echo 1 > /smoke/overlap_fail
    echo "OVERLAP old=${prev} new_count=${count}"
  fi
fi
echo $$ > /smoke/prev_pid
echo "FAKE_BRIDGE_EXIT42 count=${count} pid=$$"
sleep 0.2
exit 42
EOF
    cat >"${SMOKE_DIR}/mt_exit42.sh" <<'EOF'
#!/bin/bash
echo "FAKE_MT_EXIT42 pid=$$"
exit 42
EOF
    # Stubborn orphan: ignores TERM; stage3 generic KILL must still reclaim.
    cat >"${SMOKE_DIR}/stray_spawn.sh" <<'EOF'
#!/bin/bash
echo "FAKE_MT_WITH_STRAY pid=$$"
(
  trap '' TERM
  echo $$ > /smoke/stray.pid
  echo "STRAY_STARTED pid=$$"
  while true; do sleep 1; done
) &
trap 'echo FAKE_MT_WITH_STRAY got TERM; exit 0' TERM
while true; do sleep 1; done
EOF
    # Minimal wine client for natural wineserver -w observation.
    cat >"${SMOKE_DIR}/wine_minimal.sh" <<'EOF'
#!/bin/bash
set -e
export WINEPREFIX="${WINEPREFIX:-/tmp/wine-min}"
export WINEDEBUG="${WINEDEBUG:--all}"
# Skip Mono/Gecko prompts so a TEMP prefix can finish without network/UI.
export WINEDLLOVERRIDES="mscoree,mshtml="
mkdir -p "$WINEPREFIX"
echo "WINE_MINIMAL start prefix=${WINEPREFIX}"
# Non-interactive client; with persistence default 0, wineserver should exit after.
wine cmd /c exit 0
echo "WINE_MINIMAL client_done"
trap 'echo WINE_MINIMAL got TERM; exit 0' TERM
while true; do sleep 1; done
EOF
    cp "$OBSERVER" "${SMOKE_DIR}/finish.d/10-stage3-wine-observer"
    chmod +x "${SMOKE_DIR}/noop.sh" "${SMOKE_DIR}/mt_stay.sh" "${SMOKE_DIR}/bridge_stay.sh" \
        "${SMOKE_DIR}/exit42.sh" "${SMOKE_DIR}/mt_exit42.sh" "${SMOKE_DIR}/stray_spawn.sh" \
        "${SMOKE_DIR}/wine_minimal.sh" "${SMOKE_DIR}/finish.d/10-stage3-wine-observer"
    echo 0 >"${SMOKE_DIR}/bridge_count"
    echo 0 >"${SMOKE_DIR}/overlap_fail"
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

with_observer_mount() {
    MOUNTS+=(
        -v "${SMOKE_DIR}/finish.d/10-stage3-wine-observer:/etc/cont-finish.d/10-stage3-wine-observer:ro"
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
    local seconds="${3:-90}"
    local i
    for i in $(seq 1 "$seconds"); do
        if docker logs "$name" 2>&1 | grep -q "$pattern"; then
            return 0
        fi
        if ! docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
            docker logs "$name" 2>&1 | grep -q "$pattern" && return 0
            return 1
        fi
        sleep 1
    done
    return 1
}

assert_no_executable_wineserver_k() {
    local root="$1"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        file="${line%%:*}"
        rest="${line#*:}"
        code="$(printf '%s\n' "$rest" | sed 's/#.*//')"
        if printf '%s\n' "$code" | grep -Eq 'wineserver[[:space:]]+-k|pkill[[:space:]].*wine|killall[[:space:]].*wine|wineboot[[:space:]]+-k'; then
            fail "executable global Wine kill in ${file}: ${rest}"
        fi
    done < <(grep -RnE 'wineserver[[:space:]]+-k|pkill|killall|wineboot[[:space:]]+-k' "$root" 2>/dev/null || true)
}

prepare_smoke

echo "=== A: STATIC NO GLOBAL KILL (source tree) ==="
test ! -e "${ROOT}/images/mt5-headless/cont-finish.d/10-wine-cleanup" || fail "finalizer source must be deleted"
grep -Fq 'cont-finish.d' "$DOCKERFILE" && fail "Dockerfile must not COPY cont-finish.d"
assert_no_executable_wineserver_k "${ROOT}/images/mt5-headless"
TESTS_RUN=$((TESTS_RUN + 3))
pass "source has no project-specific wineserver -k"

echo "=== B: IMAGE CONFIG ==="
EP="$(docker image inspect "$IMAGE" --format '{{json .Config.Entrypoint}}')"
CMD="$(docker image inspect "$IMAGE" --format '{{json .Config.Cmd}}')"
echo "Entrypoint=${EP} Cmd=${CMD}"
echo "$EP" | grep -Fq '/init' || fail "Entrypoint /init"
if [ "$CMD" != "null" ] && [ "$CMD" != "[]" ] && [ -n "$CMD" ]; then
    fail "Cmd must be null/empty got ${CMD}"
fi
docker run --rm --entrypoint bash "$IMAGE" -lc '
  test ! -e /entrypoint.sh
  test ! -e /etc/cont-finish.d/10-wine-cleanup
  find /etc/cont-finish.d -maxdepth 1 -type f -print 2>/dev/null | grep -q . && exit 2 || true
  test -d /etc/s6-overlay/s6-rc.d/metatrade
  test -d /etc/s6-overlay/s6-rc.d/bridge
'
TESTS_RUN=$((TESTS_RUN + 3))
pass "image: /init, no CMD, no entrypoint, no wine finalizer"

echo "=== C: SERVICE-ONLY NORMAL STOP (bridge < metatrader) ==="
common_mounts
run_temp "${NAME_PREFIX}_stop" \
    -e RUN_MT5=1 \
    -e RUN_BRIDGE=1 \
    -e MT5_LIFECYCLE_SCRIPT=/smoke/mt_stay.sh \
    -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/bridge_stay.sh
wait_log "${NAME_PREFIX}_stop" "FAKE_MT_STAY" 90 || fail "mt stay"
wait_log "${NAME_PREFIX}_stop" "FAKE_BRIDGE_STAY" 90 || fail "bridge stay"
docker stop -t 20 "${NAME_PREFIX}_stop" >/dev/null
code="$(docker inspect -f '{{.State.ExitCode}}' "${NAME_PREFIX}_stop")"
assert_eq "0" "$code" "normal stop exit0"
docker logs "${NAME_PREFIX}_stop" 2>&1 >"${SMOKE_DIR}/stop.log"
grep -q 'WINE-FINALIZER' "${SMOKE_DIR}/stop.log" && fail "must not run WINE-FINALIZER"
grep -Eq 'wineserver -k' "${SMOKE_DIR}/stop.log" && fail "must not log wineserver -k"
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
print(f"order bridge={bi} mt={mi}")
if bi < 0 or mi < 0:
    sys.exit(1)
if not (bi < mi):
    sys.exit(2)
print("bridge < metatrader OK")
PY
docker rm -f "${NAME_PREFIX}_stop" >/dev/null
TESTS_RUN=$((TESTS_RUN + 2))
pass "normal stop exit0; bridge before metatrader; no finalizer"

echo "=== D: BRIDGE CRASH restart, no global kill ==="
echo 0 >"${SMOKE_DIR}/bridge_count"
echo 0 >"${SMOKE_DIR}/overlap_fail"
run_temp "${NAME_PREFIX}_crash" \
    -e RUN_MT5=1 \
    -e RUN_BRIDGE=1 \
    -e FAKE_NAME=metatrader \
    -e MT5_LIFECYCLE_SCRIPT=/smoke/mt_stay.sh \
    -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/exit42.sh
wait_log "${NAME_PREFIX}_crash" "FAKE_MT_STAY" 90 || fail "mt for crash"
for _i in $(seq 1 40); do
    cnt="$(docker exec "${NAME_PREFIX}_crash" bash -lc 'cat /smoke/bridge_count' 2>/dev/null || echo 0)"
    [ "${cnt:-0}" -ge 2 ] && break
    sleep 1
done
cnt="$(docker exec "${NAME_PREFIX}_crash" bash -lc 'cat /smoke/bridge_count')"
[ "${cnt}" -ge 2 ] || fail "restart count>=2 got ${cnt}"
ov="$(docker exec "${NAME_PREFIX}_crash" bash -lc 'cat /smoke/overlap_fail')"
assert_eq "0" "$ov" "no overlap"
MT1="$(docker exec "${NAME_PREFIX}_crash" bash -lc 'cat /smoke/metatrader.pid')"
sleep 2
MT2="$(docker exec "${NAME_PREFIX}_crash" bash -lc 'cat /smoke/metatrader.pid')"
assert_eq "$MT1" "$MT2" "metatrader PID stable"
RUNNING="$(docker inspect -f '{{.State.Running}}' "${NAME_PREFIX}_crash")"
assert_eq "true" "$RUNNING" "container up"
docker logs "${NAME_PREFIX}_crash" 2>&1 | grep -q 'WINE-FINALIZER' && fail "no finalizer on crash path"
docker rm -f "${NAME_PREFIX}_crash" >/dev/null
TESTS_RUN=$((TESTS_RUN + 2))
pass "bridge crash restarts; no global Wine kill"

echo "=== E: METATRADER FATAL exit42 without finalizer ==="
run_temp "${NAME_PREFIX}_fatal" \
    -e RUN_MT5=1 \
    -e RUN_BRIDGE=0 \
    -e MT5_LIFECYCLE_SCRIPT=/smoke/mt_exit42.sh
for _i in $(seq 1 90); do
    st="$(docker inspect -f '{{.State.Status}}' "${NAME_PREFIX}_fatal" 2>/dev/null || echo gone)"
    [ "$st" = "exited" ] && break
    sleep 1
done
code="$(docker inspect -f '{{.State.ExitCode}}' "${NAME_PREFIX}_fatal")"
assert_eq "42" "$code" "fatal exit42"
docker logs "${NAME_PREFIX}_fatal" 2>&1 | grep -q 'WINE-FINALIZER' && fail "no finalizer on fatal"
docker rm -f "${NAME_PREFIX}_fatal" >/dev/null
pass "metatrader fatal exit42 without finalizer"

echo "=== F: RUN_MT5=0 ==="
echo 0 >"${SMOKE_DIR}/bridge_count"
run_temp "${NAME_PREFIX}_run0" \
    -e RUN_MT5=0 \
    -e RUN_BRIDGE=1 \
    -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/exit42.sh
for _i in $(seq 1 90); do
    st="$(docker inspect -f '{{.State.Status}}' "${NAME_PREFIX}_run0" 2>/dev/null || echo gone)"
    [ "$st" = "exited" ] && break
    sleep 1
done
code="$(docker inspect -f '{{.State.ExitCode}}' "${NAME_PREFIX}_run0")"
assert_eq "0" "$code" "RUN_MT5=0 exit0"
bc="$(cat "${SMOKE_DIR}/bridge_count")"
assert_eq "0" "$bc" "bridge disabled"
docker logs "${NAME_PREFIX}_run0" 2>&1 | grep -q 'WINE-FINALIZER' && fail "no finalizer"
docker rm -f "${NAME_PREFIX}_run0" >/dev/null
pass "RUN_MT5=0 exit0 without finalizer"

echo "=== G: STRAY PROCESS / stage3 safety net ==="
run_temp "${NAME_PREFIX}_stray" \
    -e RUN_MT5=1 \
    -e RUN_BRIDGE=0 \
    -e MT5_LIFECYCLE_SCRIPT=/smoke/stray_spawn.sh
wait_log "${NAME_PREFIX}_stray" "STRAY_STARTED" 90 || fail "stray not started"
sw_start=$(date +%s)
docker stop -t 25 "${NAME_PREFIX}_stray" >/dev/null
sw_end=$(date +%s)
elapsed=$((sw_end - sw_start))
code="$(docker inspect -f '{{.State.ExitCode}}' "${NAME_PREFIX}_stray")"
echo "stray_stop_seconds=${elapsed} exit=${code}"
[ "${elapsed}" -le 30 ] || fail "stray stop exceeded grace (${elapsed}s)"
assert_eq "0" "$code" "stray stop exit0"
docker rm -f "${NAME_PREFIX}_stray" >/dev/null
TESTS_RUN=$((TESTS_RUN + 1))
pass "stage3 generic reclaim stops container within grace"

echo "=== H: OBSERVER + natural wineserver -w (TEMP Wine) ==="
# Mount observer for stage3 visibility; use temp WINEPREFIX (not broker volume).
common_mounts
with_observer_mount
docker rm -f "${NAME_PREFIX}_winew" >/dev/null 2>&1 || true
docker run -d --name "${NAME_PREFIX}_winew" \
    "${MOUNTS[@]}" \
    -e RESET_WINEPREFIX=0 \
    -e INSTALL_MT5=0 \
    -e DEPLOY_MQL5=0 \
    -e CONFIGURE_NT5=0 \
    -e BOOTSTRAP_PYTHON=0 \
    -e ENABLE_VNC=1 \
    -e VNC_PASSWORD=smokepass \
    -e RUN_MT5=1 \
    -e RUN_BRIDGE=0 \
    -e WINEPREFIX=/tmp/wine-min \
    -e MT5_LIFECYCLE_SCRIPT=/smoke/wine_minimal.sh \
    "$IMAGE" >/dev/null
wait_log "${NAME_PREFIX}_winew" "WINE_MINIMAL client_done" 420 || {
    docker logs "${NAME_PREFIX}_winew" 2>&1 | tail -n 80
    fail "wine minimal client did not finish"
}
docker stop -t 20 "${NAME_PREFIX}_winew" >/dev/null
docker logs "${NAME_PREFIX}_winew" 2>&1 >"${SMOKE_DIR}/winew.log"
grep -q 'STAGE3-WINE-OBSERVER' "${SMOKE_DIR}/winew.log" || fail "observer must run"
grep -q 'natural_wait_status=0' "${SMOKE_DIR}/winew.log" || {
    echo "observer log excerpt:"
    grep 'STAGE3-WINE-OBSERVER' "${SMOKE_DIR}/winew.log" || true
    fail "expected wineserver -w status0 (natural end)"
}
grep -q 'wineserver -k' "${SMOKE_DIR}/winew.log" && fail "observer must not -k"
ORDER_LOG="${SMOKE_DIR}/winew.log" python3 - <<'PY' || fail "bridge/mt/observer order"
import os, sys
logs = open(os.environ["ORDER_LOG"], encoding="utf-8", errors="replace").read().splitlines()

def last_idx(pred):
    idx = -1
    for i, line in enumerate(logs):
        if pred(line):
            idx = i
    return idx

mi = last_idx(lambda l: "METATRADER-FINISH" in l or "WINE_MINIMAL got TERM" in l or "FAKE_MT_STAY got TERM" in l)
oi = last_idx(lambda l: "STAGE3-WINE-OBSERVER" in l and "state=START" in l)
print(f"order mt={mi} observer={oi}")
if oi < 0:
    sys.exit(1)
if mi >= 0 and mi >= oi:
    sys.exit(2)
print("service before observer OK")
PY
docker rm -f "${NAME_PREFIX}_winew" >/dev/null
TESTS_RUN=$((TESTS_RUN + 2))
pass "natural wineserver -w status0 via test-only observer"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
