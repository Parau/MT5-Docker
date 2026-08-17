#!/bin/bash
# Deterministic state-machine tests for mt5_lifecycle.sh handoff detection.
#
# Data flow: sources production lifecycle script, replaces scan/sleep seams with
# synthetic snapshots. Limitations: no Wine, no broker volumes, no LiveUpdate forcing.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../images/mt5-headless/scripts/mt5_lifecycle.sh
source "${ROOT}/images/mt5-headless/scripts/mt5_lifecycle.sh"

MT5_HANDOFF_GRACE_SECONDS=8
MT5_UPDATE_TIMEOUT_SECONDS=10
MT5_RELAUNCH_STABLE_SECONDS=3
MT5_POLL_SECONDS=1

SNAPSHOT_INDEX=0
TEST_SNAPSHOTS=()

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

assert_ne() {
    local unexpected="$1"
    local actual="$2"
    local label="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$unexpected" = "$actual" ]; then
        fail "${label}: did not expect '${actual}'"
    fi
}

reset_test_state() {
    SNAPSHOT_INDEX=0
    TEST_SNAPSHOTS=()
    STOP_REQUESTED=0
    CURRENT_STATE="INIT"
}

parse_csv_pids() {
    local csv="$1"
    local -n _out="$2"
    _out=()
    if [ -z "$csv" ]; then
        return 0
    fi
    local IFS=','
    read -r -a _out <<< "$csv"
}

scan_process_candidates() {
    local -n _updaters="$1"
    local -n _terminals="$2"
    local -n _relaunch="$3"

    _updaters=()
    _terminals=()
    _relaunch=()

    local idx="$SNAPSHOT_INDEX"
    SNAPSHOT_INDEX=$((SNAPSHOT_INDEX + 1))
    if [ "$idx" -ge "${#TEST_SNAPSHOTS[@]}" ]; then
        idx=$((${#TEST_SNAPSHOTS[@]} - 1))
    fi

    local snap="${TEST_SNAPSHOTS[$idx]:-||}"

    local updater_csv terminal_csv relaunch_csv
    IFS='|' read -r updater_csv terminal_csv relaunch_csv <<< "$snap"
    parse_csv_pids "$updater_csv" _updaters
    parse_csv_pids "$terminal_csv" _terminals
    parse_csv_pids "$relaunch_csv" _relaunch
}

lifecycle_sleep() {
    :
}

run_handoff_expect() {
    local expected_status="$1"
    local child_status="${2:-0}"
    local reason="${3:-test}"
    local actual_status=0
    handle_handoff "$child_status" "$reason" || actual_status=$?
    assert_eq "$expected_status" "$actual_status" "handoff exit (${reason})"
}

test_classifiers() {
    echo "=== classifier tests ==="
    local updater_cmd='C:\users\root\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\liveupdate\terminal64.exe /update /path:C:\Program Files\MetaTrader 5 /portable'
    local relaunch_cmd='C:\Program Files\MetaTrader 5\terminal64.exe /skipupdate:E37BD44435252CF0D1BD0D6944C9EFA5 /portable'
    local normal_cmd='C:\Program Files\MetaTrader 5\terminal64.exe /portable'
    local other_cmd='C:\windows\system32\something.exe'

    local lower="${updater_cmd,,}"
    is_updater_cmdline "$lower" && pass "updater cmd classified as updater" || fail "updater cmd"
    is_normal_terminal_cmdline "$lower" && fail "updater cmd must not be normal terminal" || pass "updater cmd not normal"

    lower="${relaunch_cmd,,}"
    is_updater_cmdline "$lower" && fail "relaunch cmd must not be updater" || pass "relaunch cmd not updater"
    is_normal_terminal_cmdline "$lower" && pass "relaunch cmd is normal terminal" || fail "relaunch cmd normal"
    is_relaunch_marker_cmdline "$lower" && pass "relaunch cmd has skipupdate marker" || fail "relaunch marker"

    lower="${normal_cmd,,}"
    is_updater_cmdline "$lower" && fail "normal cmd must not be updater" || pass "normal cmd not updater"
    is_normal_terminal_cmdline "$lower" && pass "normal cmd is normal terminal" || fail "normal cmd normal"
    is_relaunch_marker_cmdline "$lower" && fail "normal cmd must not have skipupdate" || pass "normal cmd no marker"

    lower="${other_cmd,,}"
    is_terminal64_cmdline "$lower" && fail "irrelevant cmd must not match terminal64" || pass "irrelevant cmd ignored"
}

test_scenario_1_updater_long() {
    echo "=== scenario 1: updater long ==="
    reset_test_state
    TEST_SNAPSHOTS=(
        "||"
        "100||"
        "100||"
        "100||"
        "|200|200"
        "|200|200"
        "|200|200"
        "|200|200"
        "|200|200"
    )
    run_handoff_expect 0 0 "updater_long"
    assert_eq "RUNNING_RELAUNCHED" "$CURRENT_STATE" "scenario 1 final state"
}

test_scenario_2_race_02a() {
    echo "=== scenario 2: race from TAREFA 02A ==="
    reset_test_state
    TEST_SNAPSHOTS=(
        "||"
        "100||"
        "100||"
        "|200|200"
        "|200|200"
        "|200|200"
        "|200|200"
        "|200|200"
    )
    run_handoff_expect 0 0 "race_02a"
    assert_eq "RUNNING_RELAUNCHED" "$CURRENT_STATE" "scenario 2 final state"
}

test_scenario_3_skipupdate_fallback() {
    echo "=== scenario 3: skipupdate fallback ==="
    reset_test_state
    TEST_SNAPSHOTS=(
        "||"
        "|200|200"
        "|200|200"
        "|200|200"
        "|200|200"
        "|200|200"
    )
    run_handoff_expect 0 0 "skipupdate_fallback"
    assert_eq "RUNNING_RELAUNCHED" "$CURRENT_STATE" "scenario 3 final state"
}

test_scenario_4_generic_terminal_rejected() {
    echo "=== scenario 4: generic terminal without update evidence ==="
    reset_test_state
    TEST_SNAPSHOTS=(
        "||"
        "|200|"
        "|200|"
        "|200|"
        "|200|"
        "|200|"
        "|200|"
        "|200|"
        "|200|"
        "|200|"
    )
    run_handoff_expect "$EXIT_CLASSIFICATION_INCONSISTENT" 0 "generic_terminal"
}

test_scenario_5_no_processes() {
    echo "=== scenario 5: no processes after child exit 0 ==="
    reset_test_state
    TEST_SNAPSHOTS=(
        "||"
        "||"
        "||"
        "||"
        "||"
        "||"
        "||"
        "||"
        "||"
    )
    run_handoff_expect "$EXIT_UNEXPECTED_EXIT" 0 "no_processes"
}

test_scenario_6_update_timeout() {
    echo "=== scenario 6: updater never finishes ==="
    reset_test_state
    TEST_SNAPSHOTS=(
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
        "100||"
    )
    run_handoff_expect "$EXIT_UPDATE_TIMEOUT" 0 "update_timeout"
}

test_scenario_7_relaunch_not_observed() {
    echo "=== scenario 7: updater clears but terminal never returns ==="
    reset_test_state
    TEST_SNAPSHOTS=(
        "100||"
        "100||"
        "||"
        "||"
        "||"
        "||"
        "||"
        "||"
        "||"
        "||"
        "||"
        "||"
        "||"
    )
    run_handoff_expect "$EXIT_RELAUNCH_NOT_OBSERVED" 0 "relaunch_not_observed"
}

test_scenario_8_second_handoff_via_monitor() {
    echo "=== scenario 8: second handoff reuses handle_handoff ==="
    reset_test_state
    TEST_SNAPSHOTS=(
        "||"
        "100||"
        "100||"
        "|400|400"
        "|400|400"
        "|400|400"
        "|400|400"
        "|400|400"
    )

    local handoff_status=0
    handle_handoff 0 "terminal_disappeared" || handoff_status=$?
    assert_eq 0 "$handoff_status" "scenario 8 second handoff"
    assert_eq "RUNNING_RELAUNCHED" "$CURRENT_STATE" "scenario 8 final state"

    if grep -q 'handle_handoff 0 "terminal_disappeared"' "${ROOT}/images/mt5-headless/scripts/mt5_lifecycle.sh"; then
        pass "monitor_running_relaunched delegates to handle_handoff"
    else
        fail "monitor_running_relaunched must call handle_handoff"
    fi
}

test_old_logic_would_miss_updater_in_race() {
    echo "=== red/green note: old sleep+scan race ==="
    reset_test_state
    TEST_SNAPSHOTS=(
        "||"
        "100||"
        "100||"
        "|200|200"
    )

    local updater_seen_during_grace=0
    local poll=0
    while [ "$poll" -lt 3 ]; do
        local updater_pids=() terminal_pids=() relaunch_pids=()
        scan_process_candidates updater_pids terminal_pids relaunch_pids
        if [ "${#updater_pids[@]}" -gt 0 ]; then
            updater_seen_during_grace=1
        fi
        poll=$((poll + 1))
    done

    SNAPSHOT_INDEX=3
    local final_updater=() final_terminal=() final_relaunch=()
    scan_process_candidates final_updater final_terminal final_relaunch

    assert_eq 1 "$updater_seen_during_grace" "continuous polling observes updater during grace"
    assert_eq 0 "${#final_updater[@]}" "final single-scan moment has no updater"
    assert_ne 0 "${#final_terminal[@]}" "final single-scan moment already has relaunch terminal"
    pass "old single-scan would miss UPDATING state while new polling captures updater_seen"
}

main() {
    test_classifiers
    test_scenario_1_updater_long
    test_scenario_2_race_02a
    test_scenario_3_skipupdate_fallback
    test_scenario_4_generic_terminal_rejected
    test_scenario_5_no_processes
    test_scenario_6_update_timeout
    test_scenario_7_relaunch_not_observed
    test_scenario_8_second_handoff_via_monitor
    test_old_logic_would_miss_updater_in_race

    echo "=== summary ==="
    echo "tests_run=${TESTS_RUN} passed=${TESTS_PASSED} failed=${TESTS_FAILED}"
    if [ "$TESTS_FAILED" -ne 0 ]; then
        exit 1
    fi
}

main "$@"
