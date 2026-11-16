#!/bin/bash
# A command run for so long at most, to the second, on Linux and macOS alike (macOS has no `timeout`): CI's steps that
# must end before their job does, so that what comes after them (stopping what they left, keying and saving the
# caches) still has its time. A step's own `timeout-minutes` is no use for it: GitHub's runner takes it in whole
# minutes, 3.8, 3.5, 3.4 and 3.2 all cut at 3 (`has timed out after 3 minutes`, preview's ios 43924444930 and
# 43925936518 at 192 s, mbc's link done and the .ipa some 5 s off, 50 s of the job left), so the steps say none.
#   bash scripts/with-timeout.sh LIMIT COMMAND [ARG...]
# LIMIT is seconds, or @T: until T (seconds since the epoch). A job's first step writes when the job is cut
# (JOB_END, in $GITHUB_ENV) and its long step runs `with-timeout.sh @$((JOB_END - 35)) …`: what the job leaves it less
# what comes after it. The command's own exit status is this one's; out of time, the command and all its processes are
# stopped (TERM, then KILL 5 s on) and this exits 124, as GNU timeout does, so that `if: always()` steps after it take
# the failed way. What a stopped process left behind, reparented, is the step after's to stop (by MBUI_BUILD_TREE).
set -u
limit=${1:?usage: with-timeout.sh SECONDS|@EPOCH COMMAND [ARG...]}
shift
[ $# -gt 0 ] || { echo "with-timeout.sh: no command" >&2; exit 2; }
case $limit in
  @*) left=$(( ${limit#@} - $(date +%s) )) ;;
  *) left=$limit ;;
esac
case $left in -*|0) echo "with-timeout.sh: no time left ($limit) for $1" >&2; exit 124 ;; esac

# (the command and what it started, each process's children found again at each stop: no process group asked of the
# shell, which a shell without a terminal may not give)
tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done; echo "$1"; }

"$@" &
pid=$!
mark=$(mktemp "${TMPDIR:-/tmp}/with-timeout.XXXXXX")
rm -f "$mark"
(
  # (its sleep stopped with it, when the command ends first: nothing of this left running past the step)
  trap 'kill ${s:-} 2>/dev/null; exit 0' TERM
  sleep "$left" < /dev/null > /dev/null 2>&1 &
  s=$!
  wait $s
  : > "$mark"
  echo "with-timeout.sh: $1 still running after ${left} s: stopped" >&2
  pids=$(tree $pid)
  # shellcheck disable=SC2086 # pids, one word each
  kill -TERM $pids 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
  pids="$pids $(tree $pid 2>/dev/null)"
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
) < /dev/null &
watch=$!
wait $pid
code=$?
if [ -e "$mark" ]; then
  wait $watch 2>/dev/null
  rm -f "$mark"
  exit 124
fi
kill -TERM $watch 2>/dev/null
wait $watch 2>/dev/null
exit $code
