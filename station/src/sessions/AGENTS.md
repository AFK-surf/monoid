# Station sessions, actors, jobs, usage, and archives (for agents)

## Actors and MoonBit `--sessions` program

- Every session has one serial actor queue handling state changes, runtime events, deliveries, and tool calls. Input starts a prompt when idle, steers during a turn, or queues otherwise.
- Actors run in the MoonBit `--sessions` program (`station/mb/src/reader/actors.mbt`, `station/mb/src/reader/actor_run.mbt`, `station/src/agents/mb-program.ts`) with no TypeScript fallback. The hub holds shells (`station/src/sessions/mb-actor.ts`, shared with `station/src/sessions/actor.ts`) that answer station callbacks and read latest state.
- Hot store operations (turns, running flags, session rows) run directly on SQLite inside `station/mb/src/reader/actor_store.mbt` and notify Node of changes. In-memory stores route through Node, so hub tests use a file-backed database (`station/test/hub-fakes.ts`). `settle()` waits on `actorsBusy` too.
- Three pseudo-actors run in the same program:
  - `#jobs` (`station/src/jobs/jobs.ts`, `station/mb/src/reader/jobs.mbt`, `station/mb/src/admit`): owns start checks, remote-task and screen queues, exit notifications, service restarts, stops, and restart adoption. Node owns OS process groups, signals, logs, memory pressure, and store writes.
  - `#remote` (`station/mb/src/reader/remote*.mbt`, `station/mb/src/reader/dirsync_source.mbt`, `station/mb/src/reader/dirsync.mbt`): owns cross-station `station_task` tracking, mirror sweeps, and two-way directory sync (`fs.scan`, `zstd.pack`). Node (`station/src/jobs/remote.ts`, `station/src/jobs/dirsync.ts`) owns the mesh bus, file bytes, bulk queue, returned patches, protected folders, and load. No TypeScript sync fallback exists (`station/test/dirsync-reference.ts`, verified by `station/test/mb-dirsync.test.ts`).
  - `#live` (`station/mb/src/reader/live.mbt`, `station/src/sessions/live.ts`): tracks running turns, rates, background tasks, checklists, and live transcript entries. Node handles transcript locations, pages via separate reader processes (so long reads never stall actors), file watches, usage counter, and stream listeners (`station/src/api/events.ts` `heldWaits`).

## Turn states, cards, and deciders

- Never forward an agent's plain text answer. Agents post with `chat_post` and end every turn with `all_done`, `need_human`, or `waiting`.
- Re-prompt turns that end without a state, or post without a state after `all_done` or `need_human` (`goesOn`). Keep the session running during re-prompt so it never flashes stopped. After one re-prompt, a turn that posted ends `all_done`, or `need_human` if a pending card remains (`station/mb/src/reader/actor_run.mbt` `on_turn_ended`).
- Pending cards have two kinds (`station/src/store/card-kinds.ts`), shared by the store, `station/mb/`, and `station/test/reference/`:
  - System cards (login, vault secret, phone, rig, sign-in) wait until decided or withdrawn, regardless of chat messages.
  - Conversational cards (options, text) close when a person's message reaches the agent (in platform threads, only a message routed to the session).
- One person is the decider for both pushes and the app (`client/core-ts/src/decisions.ts` `decider`, `station/mb/src/readops/notices.mbt` `asked_of`, `starter_of`, `station/src/store/card-kinds.ts` `ASKER_BEFORE`): the card's assignee, else the person whose message the agent answered, else the chat starter. Send the ask notice to them alone, and failure notices to the chat starter.

## Usage counter and 15-minute statistics

- Spend has one statistic (`station/src/store/usage-15m.ts` `usage_15m`), updated in the same SQLite write as each call (by quarter hour, workspace, session, chat, person, account, model, plus quarter and workspace totals).
- Reads never return 503 or wait on background workers. They read raw calls only for partial quarters or local day edges. Deleted sessions keep their workspace spend. Legacy databases backfill via `station/mb/src/usagefill` and drop old tables via `station/src/store/usage-retire.ts`. `station/test/usage-15m.test.ts` checks parity across all write paths.
- Usage transcript reading runs in MoonBit `--builder usage-counter` (`station/src/usage/counter-mb.ts`, `station/mb/src/usagecount`) with no TypeScript fallback (`station/test/mb-usage-counter.test.ts`).
- Generation speed (`usage.gen_ms`, `gen_output`) is read from transcripts (`station/mb/src/usagecount/speed.mbt`, cursor in `usage_files.speed`) for `GET /profiles/pace` (`speedHours`, `speedQuarters`). Prior calls are timed once over `TIMED_BACK_MS` on startup (`station/src/usage/counter.ts`).

## Cold storage, footprint, and many-thread bounds

- Cold storage (`station/src/sessions/archive.ts`, `station/src/sessions/packed-mb.ts`) runs in MoonBit `--builder packed` (`station/mb/src/packed`) for segmented `<file>.jsonl.zst` transcripts and GNU `workspace.tar.zst` archives (`zstd.segments`, `zstd.check`, `tar.pack`, `tar.unpack`, `tar.file`). Node holds locks, worktree locks, and renames only, with no TypeScript fallback. Verified against `station/test/reference/packed.ts` and `station/test/reference/workspace-archive.ts` (`station/test/mb-packed.test.ts`) and Rust archives (`station/test/cold-compat.test.ts`).
- Workspace disk footprint (`station/src/sessions/footprint.ts`) runs in MoonBit `--builder footprint` (`station/mb/src/footprint`), one process per measure, killed on cancel, bounded like `walkBounded`. No TypeScript fallback (`station/test/footprint-reference.ts`, `station/test/mb-footprint.test.ts`).
- Sessions can span thousands of threads. Prompts, turns, tools, and archive use `recentSessionThreads` and `recentThreadRows`. Reserve `sessionThreads` for operations that must scan every thread (shares, archive transitions). Enforced by `station/test/many-threads-bounded.test.ts`.
