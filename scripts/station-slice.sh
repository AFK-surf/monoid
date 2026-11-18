#!/bin/sh
# The station's test files of one slice, I/N (scripts/check.sh's station-tests, CI's check-station), dealt by what
# each costs a runner's cores: the long files at their seconds below, the longest first, then every other file at two
# (a slice of some 108 of them took 200 core-seconds on Studio), each onto the slice with the least so far (the lowest
# among equals). Dealt one long file to a slice by place, rules-fork (125 core-seconds, its model's draws on four
# workers) took 2 in its slice beside its share of the rest, check-station (2) 148-218 s where the others were 73-171,
# eight runs of 2026-11-14. Seconds are user and system time alone on Studio with four workers (LOCK_FORK_WORKERS=4,
# as CI's runners have), 2026-11-14. On CI those two model runners cost more than that beside a slice's other files:
# dealt at 125 and 46, check-station (0) with rules-fork was 145-187 s and (1) with lock-roster4 127-152, the others
# 79-137 (fork-pr-6238 43593595033, ci/film-macos-oldest 43593584773, feat/mbui-viz 43593193529), so they count 230
# and 90, what those runs make of them. A file named here and gone is skipped; one grown long is added.
# Measured again file by file (each alone, four side by side, Studio, 2026-11-14): every file of 5 s or more at
# its seconds, rules-fork and lock-roster4 kept at what CI makes of their models' workers. Dealt with the old list's
# nine long files and 2 for the rest, slice 3 held 322 measured seconds where the others held 215-288, and was
# check-station (3) 184-204 s on every push for hours (comma-stats 27 s, replica-retire 20, mb-reader-timeline 18,
# mb-replica 16, autoarchive-last-bounded 14, accounts-routes 12, counted 2 each); dealt by these, 241-259 and
# rules-fork's slice 297. A file grown long is added, one named here and gone skipped.
# Measured again (every file, six side by side, Studio, 2026-11-16), after the lock models kept the signatures they had
# checked (lock-world-sim.ts) and the Comma statistics' tests stopped waiting 5 s a try on a database they hold
# (stats.ts `BUSY_MS`): each file at the larger of its core-seconds and its seconds, as its slot is held that long;
# rules-fork and lock-roster4 at what CI made of them before (230 and 90) times what their own time came to (129 core-s
# of 177, 27 of 63); cold-routes at its core-seconds (its 31 s are a Mac's qlmanage over a video that is none).
# Check-station (0) with rules-fork had been 119-187 s and (1) 127-190 where the others were 93-169 (2026-11-16).
# Run in station/.
s=${1:-0/1}
i=${s%/*} n=${s#*/}
long="test/rules-fork.test.ts:168 test/memory-sync-random.test.ts:69 test/replica-heap-bounded.test.ts:57"
long="$long test/move-accounts.test.ts:53 test/replica-retire.test.ts:44 test/lock-moved-model.test.ts:40"
long="$long test/lock-roster4.test.ts:39 test/updates.test.ts:36 test/chat-handover-steps.test.ts:28"
long="$long test/mb-reader-timeline.test.ts:22 test/chat-handover.test.ts:21 test/lock-world-1.test.ts:21"
# (mb-twin-station: two stations under the launcher, then a chain of three handovers, 12-15 s on Studio, 2026-11-18)
long="$long test/mb-twin-station.test.ts:15"
long="$long test/chat-handover-back.test.ts:20 test/mb-replica.test.ts:20 test/chat-handover-moves.test.ts:19"
long="$long test/lock-world-2.test.ts:19 test/lock-world-3.test.ts:19 test/hub.test.ts:18"
long="$long test/move-plan-bounded.test.ts:15 test/replica-stations.test.ts:13 test/lock-forks.test.ts:12"
long="$long test/mb-reader-usage-page.test.ts:12 test/store.test.ts:12 test/comma-router-once.test.ts:11"
long="$long test/agy.test.ts:10 test/chat-handover-told.test.ts:10 test/hub-tools.test.ts:10"
long="$long test/lock-fork-choice.test.ts:10 test/lock-root-gone-ways.test.ts:10 test/mb-legacy.test.ts:10"
long="$long test/codex.test.ts:9 test/cold-hub.test.ts:9 test/comma-adaptive-page.test.ts:9 test/dirsync.test.ts:9"
long="$long test/logins.test.ts:9 test/mb-footprint.test.ts:9 test/remote.test.ts:9"
long="$long test/legacy-decision-session-store.test.ts:8 test/mb-dirsync.test.ts:8 test/mb-replica-carry.test.ts:8"
long="$long test/updates-routes.test.ts:8 test/usage-compact-source.test.ts:8 test/hub-routes.test.ts:7"
long="$long test/legacy-said-write-bounded.test.ts:7 test/lock-root-out.test.ts:7 test/long-chat.test.ts:7"
long="$long test/move-sizes.test.ts:7 test/rules-lock.test.ts:7 test/autoarchive-last-bounded.test.ts:6"
long="$long test/chat-list-home-interleaved.test.ts:6 test/jobs-logs.test.ts:6 test/json-startup.test.ts:6"
long="$long test/main-thread-waits.test.ts:6 test/mb-usage-counter.test.ts:6 test/relay.test.ts:6"
long="$long test/subagent-hook.test.ts:6 test/accounts-routes.test.ts:5 test/card-answers-window.test.ts:5"
long="$long test/chat-list-scope-visibility.test.ts:5 test/comma-stats.test.ts:5 test/handover-bounded.test.ts:5"
long="$long test/hermes.test.ts:5 test/lock-moved-pin.test.ts:5 test/lock-roster.test.ts:5 test/lock.test.ts:5"
long="$long test/mb-packed.test.ts:5 test/mb-recent-chat.test.ts:5 test/mb-session-up-jobs.test.ts:5"
long="$long test/restate-card-concurrent-write.test.ts:5 test/screens.test.ts:5 test/usage-counter.test.ts:5"
long="$long test/usage-retire.test.ts:5"
ls test/*.test.ts | awk -v i="$i" -v n="$n" -v long="$long" '
  function put(f, c,   g, b) { b = 0; for (g = 1; g < n; g++) if (load[g] < load[b]) b = g; load[b] += c; if (b == i) print f }
  BEGIN { k = split(long, l, " ") }
  { have[$0] = 1; all[NR] = $0 }
  END {
    for (j = 1; j <= k; j++) { split(l[j], q, ":"); want[q[1]] = 1; if (q[1] in have) put(q[1], q[2]) }
    for (r = 1; r <= NR; r++) if (!(all[r] in want)) put(all[r], 2)
  }'
