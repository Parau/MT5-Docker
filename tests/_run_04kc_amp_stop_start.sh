#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
docker compose --profile amp stop mt5-amp
docker compose --profile amp start mt5-amp
for i in $(seq 1 60); do
  st="$(docker inspect -f '{{.State.Health.Status}}' mt5_amp_container 2>/dev/null || echo none)"
  echo "t=${i} health=${st}"
  if [ "$st" = "healthy" ]; then
    docker exec mt5_amp_container bash -lc 'PATH=/command:$PATH /scripts/healthcheck_mt5.sh; echo hc_exit=$?'
    echo AMP_STOP_START_OK
    exit 0
  fi
  sleep 5
done
echo AMP_STOP_START_TIMEOUT
exit 1
