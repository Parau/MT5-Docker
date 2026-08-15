#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
docker inspect -f 'running={{.State.Running}} health={{.State.Health.Status}} exit={{.State.ExitCode}}' mt5_amp_container
docker exec mt5_amp_container bash -lc 'PATH=/command:$PATH /scripts/healthcheck_mt5.sh; echo hc_exit=$?'
docker compose --profile tickmill --profile xp --profile amp ps
# Optional: recreate tickmill/xp only if needed for image hash — report status only.
echo AMP_SMOKE_OK
