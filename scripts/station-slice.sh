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
# Measured again (2026-11-23, Linux x64, the 848 files each alone in its own process, four side by side as CI's
# runners have, LOCK_FORK_WORKERS=4): every file of 5 s or more at its seconds, the rest at 2 (those averaged 2.1). The
# list had stopped at 2026-11-16's 85 files while the files grew to 848: the MoonBit stations' live, e2e and fault
# files came at 2, and check-station (0) and (3) neared their 5 minutes (p90 271 and 254 s, the others 212-222, main's
# 34 runs of 2026-11-22). The list is dealt longest first whatever its order (the awk below sorts it), so a file added
# at its end is dealt in its place; dealt by these, the six slices hold within a few seconds of each other.
# Run in station/.
s=${1:-0/1}
i=${s%/*} n=${s#*/}
# Measured again on CI's own runners (2026-11-25, two runs of all seven slices of 45696584284 and 45698095993, each file
# timed from its start to its end four at a time in its slice's order, as run-files.mjs runs them): every file of 5 s
# or more at the mean of its two seconds, the rest at 2 (those averaged 1.8). Timed so on the runners, each file's
# seconds already hold what its slice's other files cost it, the lock models' four workers too, so no file is set by
# hand. The rules had gone through Pion's Wasm 4.8 times faster (#8402): rules-fork-person-a, -b and -c took 25-54 s
# and rules-fork 41 where they were dealt at 340 and 180, while legacy-agent-build, comma-stats-age-fair,
# projects-jsonl-and-sync and others of 20-45 s came at 2, so check-station (5) and (6) took 238-290 s where (0) and
# (2) took 164-192. Dealt by these, the seven slices of those runs come to 154-168 s, (0) with mb-fault-replica-retire
# alone at its 168.
long="test/mb-fault-replica-retire.test.ts:168 test/memory-sync-random.test.ts:95"
long="$long test/mb-fault-adb-device-connects.test.ts:84 test/mb-fault-move-and-connects.test.ts:74"
long="$long test/replica-heap-bounded.test.ts:72 test/replica-retire.test.ts:71 test/chat-handover-back.test.ts:65"
long="$long test/mb-fault-agents-and-pack.test.ts:64 test/hub-tools.test.ts:62 test/hub.test.ts:62"
long="$long test/move-accounts.test.ts:62 test/mb-fault-runtimes-and-lend.test.ts:59"
long="$long test/mb-reader-usage-page.test.ts:57 test/mb-reader-timeline.test.ts:53 test/lock-roster4.test.ts:49"
long="$long test/mb-live-jobs-ops-parity.test.ts:48 test/rules-fork-person-c.test.ts:48 test/chat-handover.test.ts:46"
long="$long test/projects-jsonl-and-sync.test.ts:45 test/mb-live-p5-1.test.ts:43 test/rules-fork.test.ts:42"
long="$long test/chat-handover-steps.test.ts:39 test/mb-cross-engine-handover.test.ts:39"
long="$long test/chat-handover-moves.test.ts:38 test/store.test.ts:36 test/mb-live-comma-replica-parity.test.ts:33"
long="$long test/comma-surface-scope.test.ts:31 test/mb-legacy.test.ts:31"
long="$long test/mb-live-adb-rig-drivers-parity.test.ts:31 test/rules-fork-person-b.test.ts:28 test/agy.test.ts:27"
long="$long test/mb-live-p5-3.test.ts:25 test/mb-replica.test.ts:25 test/rules-fork-person-a.test.ts:25"
long="$long test/lock-world-3.test.ts:23 test/move-plan-bounded.test.ts:23"
long="$long test/mb-upkeep-state-and-foreign-worktrees.test.ts:22 test/override-replace.test.ts:22"
long="$long test/mb-live-p5-2.test.ts:21 test/lock-moved-model.test.ts:20 test/mb-live-mesh-remote-parity.test.ts:20"
long="$long test/replica-transcript.test.ts:20 test/mb-dirsync.test.ts:19 test/mb-fault-storage-and-peer.test.ts:19"
long="$long test/usage-15m.test.ts:19 test/accounts-routes.test.ts:18 test/mb-usage-counter.test.ts:18"
long="$long test/chat-handover-told.test.ts:17 test/workspace-connects.test.ts:17 test/dirsync.test.ts:16"
long="$long test/mb-fault-lifecycle.test.ts:16 test/json-startup.test.ts:15 test/lock-world-2.test.ts:15"
long="$long test/mb-live-share-group-ops-parity.test.ts:15 test/remote.test.ts:15 test/rules-lock.test.ts:15"
long="$long test/subagent-hook.test.ts:15 test/comma-router-once.test.ts:14 test/legacy-said-write-bounded.test.ts:14"
long="$long test/mb-fault-connects-mesh.test.ts:14 test/mb-live-sessions-parity.test.ts:14"
long="$long test/usage-counter.test.ts:14 test/chat-list-scope-visibility.test.ts:13 test/hub-routes.test.ts:13"
long="$long test/lock-fork-choice.test.ts:13 test/lock-world-1.test.ts:13 test/mb-fault-vault-concurrency.test.ts:13"
long="$long test/mb-upstream-corpora.test.ts:13 test/chat-handover-usage.test.ts:12"
long="$long test/manual-archive-mention.test.ts:12 test/mb-fault-net-and-backpressure.test.ts:12"
long="$long test/mb-live-station.test.ts:12 test/mb-recent-chat.test.ts:12 test/mb-station-e2e.test.ts:12"
long="$long test/replica-stations.test.ts:12 test/thumbs.test.ts:12 test/autoarchive-last-bounded.test.ts:11"
long="$long test/chat-list-home-interleaved.test.ts:11 test/legacy-decision-session-store.test.ts:11"
long="$long test/mb-fault-browser-share-rig.test.ts:11 test/mb-live-vault-proxy-parity.test.ts:11 test/relay.test.ts:11"
long="$long test/usage-compact-source.test.ts:11 test/card-answers-window.test.ts:10 test/codex.test.ts:10"
long="$long test/mb-fault-lock-and-mesh.test.ts:10 test/mb-reader-shared-rows-perf.test.ts:10"
long="$long test/preset-projects.test.ts:10 test/delete-marks-bounded.test.ts:9 test/handover-bounded.test.ts:9"
long="$long test/latest-thread-index.test.ts:9 test/legacy-edits-widget-gate.test.ts:9 test/mb-replica-carry.test.ts:9"
long="$long test/move-sizes.test.ts:9 test/pending-delivery-reader.test.ts:9 test/state-question-reader.test.ts:9"
long="$long test/updates.test.ts:9 test/autoarchive-unread-bounded.test.ts:8 test/cold-hub.test.ts:8"
long="$long test/comma-stats.test.ts:8 test/context.test.ts:8 test/jobs.test.ts:8"
long="$long test/mb-live-accounts-handover.test.ts:8 test/replica-handoff.test.ts:8 test/sending-pack.test.ts:8"
long="$long test/cc-thread-index.test.ts:7 test/chat-list-index-entry-rowid.test.ts:7 test/chat-list-index.test.ts:7"
long="$long test/hermes.test.ts:7 test/hub-e2e.test.ts:7 test/jobs-logs.test.ts:7"
long="$long test/legacy-decision-session-dropped.test.ts:7 test/legacy-said-store.test.ts:7 test/lock-roster.test.ts:7"
long="$long test/mb-live-drive-screens-browser-parity.test.ts:7 test/replica-manifest.test.ts:7"
long="$long test/cc-index-builder.test.ts:6 test/chat-configure.test.ts:6 test/chat-list-home-index.test.ts:6"
long="$long test/chat-list-index-reader.test.ts:6 test/cold-compat.test.ts:6 test/comma-adaptive-page.test.ts:6"
long="$long test/comma-task-page.test.ts:6 test/group-connect.test.ts:6 test/job-chat-latest-prepared-bounded.test.ts:6"
long="$long test/legacy-edits-build.test.ts:6 test/mb-footprint.test.ts:6 test/mb-live-hooks-parity.test.ts:6"
long="$long test/mb-live-p5-4.test.ts:6 test/mb-packed.test.ts:6 test/mb-reclaim-storage.test.ts:6"
long="$long test/mb-runtime-libs-conformance.test.ts:6 test/mb-session-backfill.test.ts:6"
long="$long test/mb-station-shim.test.ts:6 test/move-scheduler.test.ts:6 test/new-account-cap.test.ts:6"
long="$long test/notice-last-bounded.test.ts:6 test/pending-existence.test.ts:6"
long="$long test/platform-edit-legacy-bounded.test.ts:6 test/projects-bounded.test.ts:6 test/reader-line.test.ts:6"
long="$long test/replica-export.test.ts:6 test/replica-s3.test.ts:6 test/search-scope-lifecycle.test.ts:6"
long="$long test/session-chat-index.test.ts:6 test/sidebar-said-rowid.test.ts:6 test/signed.test.ts:6"
long="$long test/state-default-card-reader.test.ts:6 test/transcripts.test.ts:6 test/w5-foundation.test.ts:6"
long="$long test/widget-source-index.test.ts:6 test/agent-start-errors.test.ts:5"
long="$long test/autoarchive-marks-bounded.test.ts:5 test/job-chat-origin-prepared-bounded.test.ts:5"
long="$long test/legacy-login-store.test.ts:5 test/legacy-people-since-store.test.ts:5"
long="$long test/mb-live-devices-rigs-cards.test.ts:5 test/mb-outflow-chats.test.ts:5"
long="$long test/mb-reader-shared-chats.test.ts:5 test/old-turn-count-startup.test.ts:5"
long="$long test/runtime-io-main-thread.test.ts:5 test/warm-evict.test.ts:5"
# The Pion reader's files, run since its program is in every slice's natives (scripts/check.sh station_natives), where
# before they skipped at 2: timed so as above but on pvg-office-2 (Linux x64, 2026-11-26, each file alone, four side by
# side), every one of 5 s or more at its seconds. Measured on CI's runners, they are set again.
long="$long test/builders-replica-pion-switch.test.ts:89 test/builders-core-pion-switch.test.ts:22"
long="$long test/builders-stateful-pion-switch.test.ts:22 test/builders-usage-pion-switch.test.ts:20"
long="$long test/builders-recent-pion-switch.test.ts:16 test/builders-index-pion-switch.test.ts:16"
long="$long test/reader-data-pion-switch.test.ts:13 test/builders-requested-pion-switch.test.ts:12"
long="$long test/builders-legacy-pion-switch.test.ts:11 test/builders-search-pion-switch.test.ts:10"
long="$long test/read-tail.test.ts:9 test/reader-config-select.test.ts:9 test/footprint-pion-switch.test.ts:8"
long="$long test/replica-chat-pion-switch.test.ts:8 test/packed-pion-switch.test.ts:6"
long="$long test/builders-vault-pion-switch.test.ts:6 test/w6-selection-coldstart.test.ts:6"
long="$long test/sessions-foundation.test.ts:5 test/reader-sessions-pion-switch.test.ts:5"
ls test/*.test.ts | awk -v i="$i" -v n="$n" -v long="$long" '
  function put(f, c,   g, b) { b = 0; for (g = 1; g < n; g++) if (load[g] < load[b]) b = g; load[b] += c; if (b == i) print f }
  BEGIN { k = split(long, l, " ") }
  { have[$0] = 1; all[NR] = $0 }
  END {
    for (j = 1; j <= k; j++) { split(l[j], q, ":"); want[q[1]] = 1; if (q[1] in have) { m++; lf[m] = q[1]; lc[m] = q[2] + 0 } }
    # (the longest first, by name among equals, whatever order the list says them in: one added at its end is still
    # dealt in its place)
    for (a = 2; a <= m; a++) {
      f = lf[a]; c = lc[a]
      for (b = a - 1; b >= 1 && (lc[b] < c || (lc[b] == c && lf[b] > f)); b--) { lf[b + 1] = lf[b]; lc[b + 1] = lc[b] }
      lf[b + 1] = f; lc[b + 1] = c
    }
    for (j = 1; j <= m; j++) put(lf[j], lc[j])
    for (r = 1; r <= NR; r++) if (!(all[r] in want)) put(all[r], 2)
  }'
