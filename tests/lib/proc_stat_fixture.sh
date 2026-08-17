#!/bin/bash
# Canonical fake /proc/<pid>/stat for tests. Field numbers follow Linux
# proc(5): field 22 is starttime. comm is parenthesized and may contain
# spaces or ')'; callers pass the raw comm without parentheses.
#
# Data flow: sourced by test_start_bridge.sh and test_bridge_process_gate.sh.
# Independent of images/mt5-headless/scripts/start_bridge.sh.
# Premises: synthetic fields 4-21/23-24 are dummy integers; only pid, comm,
# state, and starttime are meaningful to the gate tests.

write_linux_proc_stat() {
    local dest="$1"
    local pid="$2"
    local comm="$3"
    local state="$4"
    local starttime="$5"
    {
        printf '%s (%s) %s ' "$pid" "$comm" "$state" # 1 pid, 2 comm, 3 state
        printf '%s ' 1                               # 4 ppid
        printf '%s ' 1                               # 5 pgrp
        printf '%s ' 1                               # 6 session
        printf '%s ' 0                               # 7 tty_nr
        printf '%s ' -1                              # 8 tpgid
        printf '%s ' 0                               # 9 flags
        printf '%s ' 0                               # 10 minflt
        printf '%s ' 0                               # 11 cminflt
        printf '%s ' 0                               # 12 majflt
        printf '%s ' 0                               # 13 cmajflt
        printf '%s ' 0                               # 14 utime
        printf '%s ' 0                               # 15 stime
        printf '%s ' 0                               # 16 cutime
        printf '%s ' 0                               # 17 cstime
        printf '%s ' 0                               # 18 priority
        printf '%s ' 0                               # 19 nice
        printf '%s ' 1                               # 20 num_threads
        printf '%s ' 0                               # 21 itrealvalue
        printf '%s ' "$starttime"                    # 22 starttime
        printf '%s ' 0                               # 23 vsize
        printf '%s\n' 0                              # 24 rss
    } >"$dest"
}

# Independent of start_bridge.sh: map Linux field numbers from pid, the
# substring between the first '(' and the last ')', then tokens from field 3.
independent_stat_field() {
    local stat_file="$1"
    local field="$2"
    python3 - "$stat_file" "$field" <<'PY'
import sys

path, field_s = sys.argv[1], sys.argv[2]
field = int(field_s)
line = open(path, "r", encoding="utf-8", errors="replace").read().splitlines()[0]
open_paren = line.find("(")
close = line.rfind(")")
if open_paren < 0 or close < open_paren:
    raise SystemExit(1)
pid = line[:open_paren].strip()
comm = line[open_paren + 1 : close]
rest = line[close + 1 :].split()
fields = {1: pid, 2: comm}
for i, tok in enumerate(rest, start=3):
    fields[i] = tok
if field not in fields:
    raise SystemExit(1)
sys.stdout.write(fields[field])
PY
}
