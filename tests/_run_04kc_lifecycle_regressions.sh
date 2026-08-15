#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
tests=(
  test_mt5_lifecycle.sh
  test_mt5_lifecycle_contract.sh
  test_mt5_lifecycle_shutdown.sh
  test_bootstrap_python.sh
  test_bootstrap_python_oneshot.sh
  test_configure_nt5.sh
  test_configure_nt5_oneshot.sh
  test_deploy_mql5.sh
  test_deploy_mql5_oneshot.sh
  test_install_mt5.sh
)
for t in "${tests[@]}"; do
  echo "===== $t ====="
  bash "tests/$t"
done
echo ALL_LIFECYCLE_OK
