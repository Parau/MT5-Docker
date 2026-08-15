#!/command/with-contenv bash
# TEST-ONLY stage3 observer. Never install into the production image.
#
# Data flow: mounted into /etc/cont-finish.d during TEMP evidence tests afte
# user s6 services are already down. Observes whether the Wine session has
# already ended via bounded `wineserver -w`. Always exits 0.
# Limitations: no kills; no environ/cmdline; bounded to 5s wait.
readonly LOG_PREFIX="[STAGE3-WINE-OBSERVER]"

echo "${LOG_PREFIX} state=START ts=$(date +%s%N 2>/dev/null || date +%s)"

# Sanitized snapshot: pid/ppid/stat/comm only (no cmdline/env).
echo "${LOG_PREFIX} snapshot_begin"
ps -eo pid=,ppid=,stat=,comm= 2>/dev/null | head -n 80 || true
echo "${LOG_PREFIX} snapshot_end"

set +e
timeout 5s wineserver -w
wait_status=$?
set -e

echo "${LOG_PREFIX} state=COMPLETED natural_wait_status=${wait_status}"
exit 0
