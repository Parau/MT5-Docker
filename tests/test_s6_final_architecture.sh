#!/bin/bash
# Final architectural contract for the s6-overlay MT5-Docker baseline (04L).
#
# Data flow: static asserts over Dockerfile, s6-rc.d, compose, docs, and key
# scripts. Consumed by release-baseline gates. Limitations: no broker volumes;
# runtime proofs live in dedicated suites (failure_policy_runtime, service_only).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${ROOT}/images/mt5-headless/Dockerfile"
S6_ROOT="${ROOT}/images/mt5-headless/s6-rc.d"
BUNDLE="${ROOT}/images/mt5-headless/user-bundles.d/user/contents.d"
COMPOSE="${ROOT}/docker-compose.yml"
ENV_EXAMPLE="${ROOT}/.env.example"
README="${ROOT}/README.md"
ARCH_DOC="${ROOT}/docs/S6_ARCHITECTURE.md"
FINISH_BRIDGE="${S6_ROOT}/bridge/finish"
FINISH_MT="${S6_ROOT}/metatrader/finish"
HEALTH="${ROOT}/images/mt5-headless/scripts/healthcheck_mt5.sh"

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

expect_services=(
    bridge
    configure-nt5
    deploy-mql5
    display
    install-mt5
    metatrader
    python-bootstrap
    vnc-access
    window-manager
    wine-bootstrap
)

echo "=== Dockerfile /init contract ==="
grep -Fq 'ARG S6_OVERLAY_VERSION=3.2.3.2' "$DOCKERFILE" || fail "S6 overlay version"
grep -Fq 'ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2' "$DOCKERFILE" || fail "stage2 fail behaviour"
grep -Fq 'ENV S6_STAGE2_HOOK="/scripts/s6_stage2_bridge_gate.sh"' "$DOCKERFILE" || fail "stage2 hook"
grep -Fq 'ENTRYPOINT ["/init"]' "$DOCKERFILE" || fail "ENTRYPOINT /init"
grep -Eq '^CMD ' "$DOCKERFILE" && fail "Dockerfile must not declare CMD"
grep -Fq -- '--interval=30s' "$DOCKERFILE" || fail "health interval"
grep -Fq -- '--timeout=8s' "$DOCKERFILE" || fail "health timeout"
grep -Fq -- '--start-period=420s' "$DOCKERFILE" || fail "health start-period"
grep -Fq -- '--retries=3' "$DOCKERFILE" || fail "health retries"
grep -Fq '/scripts/healthcheck_mt5.sh' "$DOCKERFILE" || fail "health script"
grep -Eiq 'supervisor|supervisord' "$DOCKERFILE" && fail "Dockerfile must not install supervisor"
TESTS_RUN=$((TESTS_RUN + 11))
pass "Dockerfile s6 + HEALTHCHECK contract"

echo "=== service-only / no legacy supervisor ==="
test ! -e "${ROOT}/images/mt5-headless/entrypoint.sh" || fail "entrypoint.sh must not exist"
test ! -e "${ROOT}/images/mt5-headless/supervisord.conf" || fail "supervisord.conf must not exist"
test ! -d "${ROOT}/images/mt5-headless/cont-finish.d" || fail "project cont-finish.d must not exist"
TESTS_RUN=$((TESTS_RUN + 3))
pass "no entrypoint / supervisord / project Wine finalizer dir"

echo "=== production service set ==="
mapfile -t found < <(find "$S6_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
expected_sorted="$(printf '%s\n' "${expect_services[@]}" | sort | tr '\n' ' ')"
found_sorted="$(printf '%s\n' "${found[@]}" | sort | tr '\n' ' ')"
assert_eq "$expected_sorted" "$found_sorted" "s6-rc.d service set"

echo "=== service types ==="
for svc in display window-manager vnc-access metatrader bridge; do
    assert_eq "longrun" "$(tr -d '\r\n' <"${S6_ROOT}/${svc}/type")" "${svc} type"
done
for svc in wine-bootstrap install-mt5 deploy-mql5 configure-nt5 python-bootstrap; do
    assert_eq "oneshot" "$(tr -d '\r\n' <"${S6_ROOT}/${svc}/type")" "${svc} type"
done
pass "longrun/oneshot types frozen"

echo "=== dependency graph ==="
declare -A DEPS=()
while IFS= read -r depfile; do
    svc="$(basename "$(dirname "$(dirname "$depfile")")")"
    dep="$(basename "$depfile")"
    DEPS["${svc}"]="${DEPS[${svc}]:-} ${dep}"
    if [ "$dep" = "$svc" ]; then
        fail "self dependency: ${svc}"
    fi
    if [ "$dep" != "base" ] && [ ! -d "${S6_ROOT}/${dep}" ]; then
        fail "missing dependency service '${dep}' for '${svc}'"
    fi
done < <(find "$S6_ROOT" -path '*/dependencies.d/*' -type f | sort)

echo "${DEPS[bridge]:-}" | grep -qw metatrader || fail "bridge must depend on metatrader"

# Kahn-style cycle detection over project services (ignore external `base`).
declare -A indeg=()
for svc in "${expect_services[@]}"; do
    indeg["$svc"]=0
done
for svc in "${expect_services[@]}"; do
    for d in ${DEPS[$svc]:-}; do
        [ "$d" = "base" ] && continue
        [ -d "${S6_ROOT}/${d}" ] || continue
        indeg["$svc"]=$((${indeg[$svc]} + 1))
    done
done
queue=()
for svc in "${expect_services[@]}"; do
    if [ "${indeg[$svc]}" -eq 0 ]; then
        queue+=("$svc")
    fi
done
seen=0
while [ "${#queue[@]}" -gt 0 ]; do
    n="${queue[0]}"
    queue=("${queue[@]:1}")
    seen=$((seen + 1))
    for svc in "${expect_services[@]}"; do
        for d in ${DEPS[$svc]:-}; do
            if [ "$d" = "$n" ]; then
                indeg["$svc"]=$((${indeg[$svc]} - 1))
                if [ "${indeg[$svc]}" -eq 0 ]; then
                    queue+=("$svc")
                fi
            fi
        done
    done
done
[ "$seen" -eq "${#expect_services[@]}" ] || fail "dependency cycle detected (seen=${seen})"
TESTS_RUN=$((TESTS_RUN + 3))
pass "dependency graph: bridge→metatrader, no missing/self/cycle"

echo "=== user bundle ==="
mapfile -t bundle < <(find "$BUNDLE" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
bundle_sorted="$(printf '%s\n' "${bundle[@]}" | sort | tr '\n' ' ')"
assert_eq "$expected_sorted" "$bundle_sorted" "user bundle contents"
echo "${bundle[*]}" | grep -Eq 'mt5-ready|watchdog' && fail "forbidden bundle markers"
TESTS_RUN=$((TESTS_RUN + 1))
pass "user bundle matches production services"

echo "=== readiness policy frozen ==="
if find "$S6_ROOT" \( -name notification-fd -o -name timeout-up -o -path '*/data/check' \) | grep -q .; then
    fail "readiness artifacts present under s6-rc.d"
fi
# Comments may mention rejected readiness; scan executable bodies only.
while IFS= read -r file; do
    body="$(awk 'NR==1{next} /^#/{next} {print}' "$file")"
    echo "$body" | grep -Eq 's6-notifyoncheck|mt5-ready' && \
      fail "readiness call in executable body: ${file}"
done < <(find "$S6_ROOT" -type f \( -name run -o -name finish -o -name up \) | sort)
TESTS_RUN=$((TESTS_RUN + 2))
pass "no native bridge readiness"

echo "=== bridge failure policy high-level ==="
grep -Fq 's6-permafailon' "$FINISH_BRIDGE" || fail "permafailon"
grep -Fq 'wantedup' "$FINISH_BRIDGE" || fail "wantedup"
grep -Fq 'BRIDGE_FAILURE_BUDGET_WINDOW_DEFAULT=60' "$FINISH_BRIDGE" || fail "window 60"
grep -Fq 'BRIDGE_FAILURE_BUDGET_DEATHS_DEFAULT=5' "$FINISH_BRIDGE" || fail "deaths 5"
grep -Fq '75' "$FINISH_BRIDGE" || fail "exit 75"
grep -Fq 'BRIDGE_HALT_BIN' "$FINISH_BRIDGE" || fail "halt seam"
TESTS_RUN=$((TESTS_RUN + 6))
pass "bridge failure budget primitives"

echo "=== metatrader fatal finish ==="
grep -Fq 'METATRADER_HALT_BIN' "$FINISH_MT" || fail "mt halt"
grep -Fq 'exit 125' "$FINISH_MT" || fail "mt finish 125"
grep -Fq 'fatal_exit_preserved' "$FINISH_MT" || fail "preserve prior non-zero"
TESTS_RUN=$((TESTS_RUN + 3))
pass "metatrader finish halt + preserve"

echo "=== health side-effect free ==="
HC_BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$HEALTH")"
echo "$HC_BODY" | grep -Eq '\bs6-svc\b' && fail "health s6-svc"
echo "$HC_BODY" | grep -Eq '\bs6-rc\b' && fail "health s6-rc"
echo "$HC_BODY" | grep -Fq 'halt' && fail "health halt"
echo "$HC_BODY" | grep -Eq '\b(kill|pkill|wineboot|docker)\b' && fail "health recovery verbs"
echo "$HC_BODY" | grep -Fq 'root.health()' || fail "must call root.health()"
TESTS_RUN=$((TESTS_RUN + 5))
pass "healthcheck observational only"

echo "=== no global Wine kill in production executable bodies ==="
while IFS= read -r file; do
    [ -f "$file" ] || continue
    body="$(awk 'NR==1{next} /^#/{next} {print}' "$file")"
    echo "$body" | grep -Fq 'wineserver -k' && fail "wineserver -k in ${file}"
    echo "$body" | grep -Eq 'pkill[[:space:]]+terminal64|killall[[:space:]]+terminal64|wineboot[[:space:]]+-k' && \
      fail "terminal kill in ${file}"
done < <(find "${ROOT}/images/mt5-headless/scripts" "${ROOT}/images/mt5-headless/s6-rc.d" \
    -type f \( -name '*.sh' -o -name 'run' -o -name 'finish' -o -name 'up' \) | sort)
TESTS_RUN=$((TESTS_RUN + 1))
pass "no project global Wine/terminal kill"

echo "=== compose contract ==="
if command -v docker >/dev/null 2>&1; then
    CFG="$(docker compose -f "$COMPOSE" --profile tickmill --profile xp --profile amp config 2>/dev/null || true)"
    if [ -n "$CFG" ]; then
        echo "$CFG" | grep -q 'mt5-tickmill' || fail "compose tickmill"
        echo "$CFG" | grep -q 'mt5-xp' || fail "compose xp"
        echo "$CFG" | grep -q 'mt5-amp' || fail "compose amp"
        echo "$CFG" | grep -Eq "restart:[[:space:]]*['\"]?no['\"]?" || fail "restart no"
        echo "$CFG" | grep -Eq 'stop_grace_period:[[:space:]]*30s?' || fail "stop_grace 30s"
        echo "$CFG" | grep -q 'mt5_tickmill_data' || fail "tickmill volume"
        echo "$CFG" | grep -q 'mt5_xp_data' || fail "xp volume"
        echo "$CFG" | grep -q 'mt5_amp_data' || fail "amp volume"
        echo "$CFG" | grep -Eq 'published:[[:space:]]*"?5901"?' || fail "VNC 5901"
        echo "$CFG" | grep -Eq 'published:[[:space:]]*"?5902"?' || fail "VNC 5902"
        echo "$CFG" | grep -Eq 'published:[[:space:]]*"?5903"?' || fail "VNC 5903"
        echo "$CFG" | grep -Eq 'published:[[:space:]]*"?18812"?' || fail "RPyC 18812"
        echo "$CFG" | grep -Eq 'published:[[:space:]]*"?18813"?' || fail "RPyC 18813"
        echo "$CFG" | grep -Eq 'published:[[:space:]]*"?18814"?' || fail "RPyC 18814"
        echo "$CFG" | grep -Fq 'host_ip: 127.0.0.1' || fail "loopback host_ip"
        echo "$CFG" | grep -Fq 'BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS' || fail "budget window env"
        echo "$CFG" | grep -Fq 'BRIDGE_FAILURE_BUDGET_DEATHS' || fail "budget deaths env"
        echo "$CFG" | grep -Fq 'BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS: "60"' || \
          echo "$CFG" | grep -Fq "BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS: '60'" || \
          echo "$CFG" | grep -Eq 'BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS:[[:space:]]*"?60"?' || \
          fail "budget window default 60"
        echo "$CFG" | grep -Eq 'BRIDGE_FAILURE_BUDGET_DEATHS:[[:space:]]*"?5"?' || fail "budget deaths default 5"
        echo "$CFG" | grep -Fq '/var/run/docker.sock' && fail "docker.sock must not be mounted"
        TESTS_RUN=$((TESTS_RUN + 18))
        pass "compose config matrix + loopback + no docker.sock"
    else
        echo "NOTE: docker compose config unavailable; falling back to file asserts"
        grep -Fq 'restart: "no"' "$COMPOSE" || fail "restart no file"
        grep -Fq 'stop_grace_period: 30s' "$COMPOSE" || fail "grace file"
        grep -Fq '127.0.0.1:5901' "$COMPOSE" || fail "vnc1 file"
        grep -Fq 'mt5-amp' "$COMPOSE" || fail "amp service file"
        TESTS_RUN=$((TESTS_RUN + 4))
        pass "compose file asserts (config fallback)"
    fi
else
    fail "docker CLI required for compose contract"
fi

echo "=== .env.example brokers + budget ==="
grep -Fq 'Tickmill' "$ENV_EXAMPLE" || grep -Fq 'tickmill' "$ENV_EXAMPLE" || fail "env tickmill"
grep -Fq 'XP' "$ENV_EXAMPLE" || fail "env xp"
grep -Fq 'AMP' "$ENV_EXAMPLE" || fail "env amp"
grep -Fq 'BRIDGE_FAILURE_BUDGET_WINDOW_SECONDS' "$ENV_EXAMPLE" || fail "env window"
grep -Fq 'BRIDGE_FAILURE_BUDGET_DEATHS' "$ENV_EXAMPLE" || fail "env deaths"
grep -Fiq 'process deaths' "$ENV_EXAMPLE" || grep -Fiq 'death tally' "$ENV_EXAMPLE" || \
  fail "env must note budget vs health"
TESTS_RUN=$((TESTS_RUN + 6))
pass ".env.example documents three brokers + budget semantics"

echo "=== repository hygiene ==="
tracked_bad="$(git -C "$ROOT" ls-files | grep -E '(^|/)__pycache__/|\.py[co]$|^tests/_run_04kc_' || true)"
[ -z "$tracked_bad" ] || fail "tracked forbidden artifacts: ${tracked_bad}"
grep -Fq '__pycache__/' "${ROOT}/.gitignore" || fail "gitignore pycache"
grep -Fq '*.py[cod]' "${ROOT}/.gitignore" || fail "gitignore pyc"
grep -Fq '.env' "${ROOT}/.dockerignore" || fail "dockerignore must ignore .env"
TESTS_RUN=$((TESTS_RUN + 4))
pass "no tracked bytecode/TEMP; ignore files cover secrets/bytecode"

echo "=== documentation staleness ==="
test -f "$ARCH_DOC" || fail "missing docs/S6_ARCHITECTURE.md"
# Reject instructional references to the deleted entrypoint path.
if grep -E '(sed .*)?images/mt5-headless/entrypoint\.sh|^[^#]*entrypoint\.sh' "$README" \
  | grep -Ev 'no legacy|must not|deleted|absent|não existe|does not exist' \
  | grep -q .; then
    fail "README must not recommend entrypoint.sh"
fi
grep -Fq 'Two brokers' "$README" && fail "README must not say Two brokers"
grep -Fq 'mt5-amp' "$README" || fail "README must document AMP"
grep -Fq 'S6_ARCHITECTURE.md' "$README" || fail "README must link architecture doc"
grep -Fq '/var/run/docker.sock' "$COMPOSE" && fail "docker.sock in compose"
grep -Fq '/var/run/docker.sock' "$DOCKERFILE" && fail "docker.sock in Dockerfile"
# production scripts: no destructive volume automation
PROD_SCRIPTS="${ROOT}/images/mt5-headless/scripts"
grep -REq 'docker[[:space:]]+volume[[:space:]]+rm|compose[[:space:]]+down[[:space:]]+-v|prune[[:space:]]+--volumes' \
  "$PROD_SCRIPTS" && fail "destructive volume automation in production scripts"
TESTS_RUN=$((TESTS_RUN + 7))
pass "docs + security static gates"

echo "=== production comments must not describe legacy entrypoint/CMD as current ==="
# Block only stale runtime descriptions. Allow factual phrases such as
# "no legacy entrypoint", "entrypoint removed", "CMD no longer starts...".
stale_hits="$(
    grep -R -n -i -E \
        'remain(s)? in entrypoint CMD|remain(s)? in the CMD entrypoint|entrypoint (only )?waits|started by s6 before CMD' \
        "${S6_ROOT}"/*/run "${S6_ROOT}"/*/finish "${ROOT}/images/mt5-headless/scripts"/*.sh \
        2>/dev/null || true
)"
[ -z "$stale_hits" ] || fail "stale entrypoint/CMD comments: ${stale_hits}"
TESTS_RUN=$((TESTS_RUN + 1))
pass "production comments do not describe entrypoint/CMD as current runtime"

echo "=== canonical display/VNC documentation ==="
grep -Fq 'Xvnc' "$ARCH_DOC" || fail "architecture doc must mention Xvnc"
grep -Fq 'Xvfb' "$ARCH_DOC" || fail "architecture doc must mention Xvfb"
grep -Fq 'x11vnc' "$ARCH_DOC" || fail "architecture doc must mention x11vnc"
grep -Eiq 'delegat' "$ARCH_DOC" || fail "architecture doc must mention VNC delegation"
TESTS_RUN=$((TESTS_RUN + 4))
pass "canonical doc covers Xvnc/Xvfb/x11vnc/delegation"

echo "=== start_bridge process gate (no API preflight) ==="
START_BRIDGE="${ROOT}/images/mt5-headless/scripts/start_bridge.sh"
test -f "$START_BRIDGE" || fail "start_bridge.sh missing"
SB_BODY="$(awk 'NR==1{next} /^#/{next} {print}' "$START_BRIDGE")"
echo "$SB_BODY" | grep -Eq 'MetaTrader5|mt5\.initialize|terminal_info|mt5\.shutdown' && \
  fail "start_bridge must not call MT5 Python API"
grep -Eq 'MetaTrader5|mt5\.initialize|terminal_info|mt5\.shutdown' "$START_BRIDGE" && \
  fail "start_bridge file must not mention MT5 Python API"
echo "$SB_BODY" | grep -Fq 'wine python -' && fail "start_bridge must not probe with wine python -"
echo "$SB_BODY" | grep -Fq 'scan_normal_mt5_processes' || fail "passive process scan missing"
echo "$SB_BODY" | grep -Fq 'WAITING_FOR_MT5_PROCESS' || fail "waiting state missing"
echo "$SB_BODY" | grep -Fq 'continue_waiting' || fail "warning continue_waiting missing"
echo "$SB_BODY" | grep -Fq 'wine python mt5_bridge.py' || fail "server spawn missing"
grep -Fq 'passive local terminal-process gate' "$ARCH_DOC" || fail "arch doc process gate"
grep -Fq 'does not provide a guarantee beyond' "$ARCH_DOC" || fail "arch doc residual initialize limitation"
grep -Fq 'root.health()' "$HEALTH" || fail "health remains root.health()"
if find "$S6_ROOT" \( -name notification-fd -o -name timeout-up -o -path '*/data/check' \) | grep -q .; then
    fail "native readiness artifacts present"
fi
TESTS_RUN=$((TESTS_RUN + 11))
pass "start_bridge process gate; docs updated; health/readiness frozen"

echo "=== summary ==="
echo "scenarios_passed=${TESTS_PASSED} assertions_run=${TESTS_RUN} failed=${TESTS_FAILED}"
[ "$TESTS_FAILED" -eq 0 ]
