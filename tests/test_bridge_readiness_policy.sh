#!/bin/bash
# Freeze 04K-B readiness policy: process-up ≠ s6 ready ≠ Docker operational health.
#
# Data flow: static scans of production tree; s6-supervise fixtures (test-only)
# for notification-fd true/false; optional TEMP container for live bridge
# up,ready. Limitations: does not alter production topology; stage2 timeout
# proof is documentary if a full s6-rc pack is too fragile.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-mt5-docker-mt5-amp:latest}"
BRIDGE_DIR="${ROOT}/images/mt5-headless/s6-rc.d/bridge"
DOCKERFILE="${ROOT}/images/mt5-headless/Dockerfile"
HC_SCRIPT="${ROOT}/images/mt5-headless/scripts/healthcheck_mt5.sh"
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

echo "=== static: no native readiness in production bridge ==="
test ! -e "${BRIDGE_DIR}/notification-fd" || fail "bridge/notification-fd must not exist"
test ! -e "${BRIDGE_DIR}/timeout-up" || fail "bridge/timeout-up must not exist"
test ! -e "${BRIDGE_DIR}/data/check" || fail "bridge/data/check must not exist"
test ! -d "${ROOT}/images/mt5-headless/s6-rc.d/mt5-ready" || fail "mt5-ready must not exist"
# Executable bodies only (comments may mention the banned tokens).
RUN_BODY="$(awk 'NR==1{next} /^#/{next} {print}' "${BRIDGE_DIR}/run")"
FINISH_BODY="$(awk 'NR==1{next} /^#/{next} {print}' "${BRIDGE_DIR}/finish")"
echo "$RUN_BODY" | grep -Fq 's6-notifyoncheck' && fail "s6-notifyoncheck in bridge/run body"
echo "$FINISH_BODY" | grep -Fq 's6-notifyoncheck' && fail "s6-notifyoncheck in bridge/finish body"
TESTS_RUN=$((TESTS_RUN + 6))
pass "production bridge has no notification-fd/timeout-up/data/check/mt5-ready/notifyoncheck"

echo "=== static: Docker HEALTHCHECK remains operational path ==="
grep -q '^HEALTHCHECK' "$DOCKERFILE" || fail "Dockerfile must declare HEALTHCHECK"
grep -Fq 'healthcheck_mt5.sh' "$DOCKERFILE" || fail "HEALTHCHECK must invoke healthcheck_mt5.sh"
grep -Fq 'root.health()' "$HC_SCRIPT" || fail "healthcheck must call root.health()"
grep -Eq 'def exposed_health' "$BRIDGE_PY" || fail "exposed_health must exist"
HC_BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$HC_SCRIPT")"
echo "$HC_BODY" | grep -Eq 's6-svstat[[:space:]]+-r|s6-svstat[[:space:]].*ready' && fail "health must not use s6 ready"
echo "$HC_BODY" | grep -Fq 's6-svstat' || fail "health must gate on s6-svstat up"
TESTS_RUN=$((TESTS_RUN + 5))
pass "HEALTHCHECK + RPyC health; no s6 ready gate"

echo "=== static: Dockerfile PATH uses \$PATH not \$\$PATH ==="
HC_LINE="$(grep -E 'CMD PATH=/command' "$DOCKERFILE" || true)"
echo "dockerfile_health_cmd=${HC_LINE}"
echo "$HC_LINE" | grep -Fq 'PATH=/command:$PATH' || fail "Dockerfile must use PATH=/command:\$PATH"
echo "$HC_LINE" | grep -Fq '$$PATH' && fail "Dockerfile must not use \$\$PATH"
TESTS_RUN=$((TESTS_RUN + 2))
pass "Dockerfile HEALTHCHECK PATH uses \$PATH"

echo "=== image inspect: Healthcheck PATH contract ==="
HC_JSON="$(docker image inspect "$IMAGE" --format '{{json .Config.Healthcheck}}')"
echo "Healthcheck=${HC_JSON}"
echo "$HC_JSON" | grep -Fq '/scripts/healthcheck_mt5.sh' || fail "inspect missing script"
echo "$HC_JSON" | grep -Fq 'PATH=/command' || fail "inspect missing /command prefix"
echo "$HC_JSON" | grep -Fq '$$PATH' && fail "inspect must not contain \$\$PATH"
# Docker may leave $PATH for CMD-SHELL runtime expansion; Wine is verified below.
echo "$HC_JSON" | grep -E 'PATH=/command:(\$PATH|/opt/wine-stable/bin)' >/dev/null \
  || fail "inspect must keep \$PATH or baked Wine path"
TESTS_RUN=$((TESTS_RUN + 4))
pass "image Healthcheck has /command + \$PATH (no \$\$PATH)"

echo "=== runtime PATH seen by probe (sanitized) ==="
PATH_PROBE="$(docker run --rm --entrypoint /bin/bash "$IMAGE" -c '
set -Eeuo pipefail
# Non-login shell preserves image ENV PATH (login shells reset via /etc/profile).
export PATH="/command:${PATH}"
case ":${PATH}:" in
  *:/command:*) echo HAS_COMMAND=1 ;;
  *) echo HAS_COMMAND=0 ;;
esac
case ":${PATH}:" in
  *:/opt/wine-stable/bin:*) echo HAS_WINE=1 ;;
  *) echo HAS_WINE=0 ;;
esac
')"
echo "$PATH_PROBE"
echo "$PATH_PROBE" | grep -qx 'HAS_COMMAND=1' || fail "probe PATH missing /command"
echo "$PATH_PROBE" | grep -qx 'HAS_WINE=1' || fail "probe PATH missing Wine"
# Invoke via bash so shebang with-contenv is not required outside /init.
OUT="$(docker run --rm --entrypoint /bin/bash "$IMAGE" -c \
  'PATH=/command:$PATH RUN_MT5=0 bash /scripts/healthcheck_mt5.sh' 2>&1)" || true
echo "$OUT" | grep -q 'state=DISABLED reason=RUN_MT5' || fail "disabled probe failed: ${OUT}"
TESTS_RUN=$((TESTS_RUN + 3))
pass "runtime PATH keeps /command and Wine; disabled probe works"

echo "=== fixture A: notification-fd without notify → up=true ready=false ==="
docker run --rm --entrypoint bash "$IMAGE" -lc '
set -Eeuo pipefail
FIX=$(mktemp -d /tmp/ready-a.XXXXXX)
mkdir -p "$FIX/svc"
printf "3\n" > "$FIX/svc/notification-fd"
cat > "$FIX/svc/run" <<'"'"'EOF'"'"'
#!/bin/bash
exec sleep 300
EOF
chmod +x "$FIX/svc/run"
/command/s6-supervise "$FIX/svc" &
SUP=$!
for i in $(seq 1 50); do
  st=$(/command/s6-svstat -o up,ready "$FIX/svc" 2>/dev/null || true)
  if [ "$st" = "true false" ]; then
    echo "FIXTURE_A=$st"
    kill -TERM "$SUP" 2>/dev/null || true
    wait "$SUP" 2>/dev/null || true
    rm -rf "$FIX"
    exit 0
  fi
  sleep 0.1
done
kill -TERM "$SUP" 2>/dev/null || true
wait "$SUP" 2>/dev/null || true
echo "FIXTURE_A_FAIL last=$(/command/s6-svstat -o up,ready "$FIX/svc" 2>/dev/null || true)"
rm -rf "$FIX"
exit 1
' || fail "fixture A up/ready"
TESTS_RUN=$((TESTS_RUN + 1))
pass "fixture A: up=true ready=false without notify"

echo "=== fixture B: notification-fd + newline → up=true ready=true ==="
docker run --rm --entrypoint bash "$IMAGE" -lc '
set -Eeuo pipefail
FIX=$(mktemp -d /tmp/ready-b.XXXXXX)
mkdir -p "$FIX/svc"
printf "3\n" > "$FIX/svc/notification-fd"
cat > "$FIX/svc/run" <<'"'"'EOF'"'"'
#!/bin/bash
# Notify readiness on fd 3 then stay up.
printf "\n" >&3
exec sleep 300
EOF
chmod +x "$FIX/svc/run"
/command/s6-supervise "$FIX/svc" &
SUP=$!
for i in $(seq 1 50); do
  st=$(/command/s6-svstat -o up,ready "$FIX/svc" 2>/dev/null || true)
  if [ "$st" = "true true" ]; then
    echo "FIXTURE_B=$st"
    kill -TERM "$SUP" 2>/dev/null || true
    wait "$SUP" 2>/dev/null || true
    rm -rf "$FIX"
    exit 0
  fi
  sleep 0.1
done
kill -TERM "$SUP" 2>/dev/null || true
wait "$SUP" 2>/dev/null || true
echo "FIXTURE_B_FAIL last=$(/command/s6-svstat -o up,ready "$FIX/svc" 2>/dev/null || true)"
rm -rf "$FIX"
exit 1
' || fail "fixture B up/ready"
TESTS_RUN=$((TESTS_RUN + 1))
pass "fixture B: up=true ready=true after notify"

echo "=== TEMP: production bridge longrun up=true ready=false ==="
NAME="mt5_ready_pol_$$"
SMOKE="$(mktemp -d /tmp/ready-pol.XXXXXX)"
cleanup_temp() {
    docker rm -f "$NAME" 2>/dev/null || true
    rm -rf "$SMOKE"
}
trap cleanup_temp EXIT
cat >"${SMOKE}/noop.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"${SMOKE}/stay.sh" <<'EOF'
#!/bin/bash
echo "FAKE_STAY name=${FAKE_NAME:-unknown}"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "${SMOKE}/noop.sh" "${SMOKE}/stay.sh"
docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" \
  -e RUN_MT5=1 -e RUN_BRIDGE=1 -e ENABLE_VNC=0 \
  -e RESET_WINEPREFIX=0 -e INSTALL_MT5=0 \
  -e BOOTSTRAP_PYTHON=0 -e DEPLOY_MQL5=0 -e CONFIGURE_NT5=0 \
  -e VNC_PASSWORD=testpass \
  -e MT5_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -e BRIDGE_LIFECYCLE_SCRIPT=/smoke/stay.sh \
  -e FAKE_NAME=metatrader \
  -v "${SMOKE}:/smoke" \
  -v "${SMOKE}/noop.sh:/scripts/wine_bootstrap.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/install_mt5.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/deploy_mql5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/configure_nt5_oneshot.sh:ro" \
  -v "${SMOKE}/noop.sh:/scripts/bootstrap_python_oneshot.sh:ro" \
  -v "${SMOKE}/stay.sh:/smoke/stay.sh:ro" \
  "$IMAGE" >/dev/null
READY_LINE=""
for i in $(seq 1 90); do
    if docker exec "$NAME" bash -lc 'test -d /run/service/bridge' 2>/dev/null; then
        READY_LINE="$(docker exec "$NAME" /command/s6-svstat -o up,ready /run/service/bridge 2>/dev/null || true)"
        if [ "$READY_LINE" = "true false" ]; then
            break
        fi
    fi
    sleep 1
done
assert_eq "true false" "$READY_LINE" "bridge up,ready"
DH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME")"
RUNNING="$(docker inspect -f '{{.State.Running}}' "$NAME")"
assert_eq "true" "$RUNNING" "TEMP container running"
echo "docker_health=${DH} (ready=false does not imply Docker healthy)"
TESTS_RUN=$((TESTS_RUN + 1))
pass "TEMP bridge: s6 up=true ready=false; Docker health is a separate signal"

echo "=== note: stage2 + unreadiness (docs) ==="
echo "Official s6-rc: longrun WITH readiness support completes up only when up AND ready;"
echo "timeout-up failure with S6_BEHAVIOUR_IF_STAGE2_FAILS=2 can stop the container."
echo "Therefore native bridge readiness is NOT adopted (would change failure policy)."
pass "documented stage2 consequence without production change"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
