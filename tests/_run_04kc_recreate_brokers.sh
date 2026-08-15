#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# Recreate brokers on newly built images without touching volumes (-v forbidden).
for profile_svc in "tickmill mt5-tickmill" "xp mt5-xp"; do
  set -- $profile_svc
  profile="$1"
  svc="$2"
  echo "=== recreate $svc ($profile) ==="
  docker compose --profile "$profile" stop "$svc"
  docker compose --profile "$profile" rm -f "$svc"
  docker compose --profile "$profile" up -d "$svc"
done

wait_healthy() {
  local name="$1"
  local i st
  for i in $(seq 1 90); do
    st="$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo none)"
    echo "t=${i} ${name} health=${st}"
    if [ "$st" = "healthy" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

wait_healthy mt5_tickmill_container
wait_healthy mt5_xp_container
# AMP already on new image from prior smoke.
docker inspect -f '{{.Name}} {{.State.Health.Status}}' mt5_tickmill_container mt5_xp_container mt5_amp_container
echo ALL_BROKERS_HEALTHY
