#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
chmod +x tests/_run_04kc_temp_*.sh 2>/dev/null || true
bash tests/_run_04kc_temp_normal_stop.sh
tests=(
  test_bridge_failure_policy.sh
  test_bridge_finish_pgid.sh
  test_bridge_s6.sh
  test_bridge_shutdown.sh
  test_start_bridge.sh
  test_s6_stage2_bridge_gate.sh
  test_bridge_readiness_policy.sh
  test_healthcheck_mt5.sh
  test_mt5_bridge_startup.sh
  test_service_only_runtime.sh
  test_wine_shutdown_without_global_kill.sh
  test_metatrader_s6.sh
)
for t in "${tests[@]}"; do
  echo "===== $t ====="
  bash "tests/$t"
done
echo ALL_CORE_OK
