# Working on the station (for agents)

Narrower rules:

- `station/src/agents/AGENTS.md`: runtime drivers, output parsers, MCP tools, silent subagents, bug-report replies, sandboxes
- `station/src/sessions/AGENTS.md`: actors, `--sessions` `#jobs`/`#remote`/`#live`, turn states, cards, usage, cold storage, footprint
- `station/src/cloud/AGENTS.md`: lock pinning, fork choice, moved workspaces, lock tests, cloud TCP entries
- `station/src/mesh/AGENTS.md`: mesh base, ways and relays, station name and icon
- `station/src/rig/AGENTS.md`: task-only stations, ownership, signed grants, mode switch, devices
- `station/src/share/AGENTS.md`: shared agent memory, team skills, presets, starred models
- `station/src/ops/AGENTS.md`: storage manifest, logs, background yielding, bounded walks, self-memory, stdin backpressure
- `station/src/move/AGENTS.md`, `station/src/replica/AGENTS.md`: migration, chat handovers, backups, retirement (off)
- `station/mb/src/station_main/AGENTS.md`, `station/docker/AGENTS.md`: MoonBit station, Docker
- `station/src/screens/AGENTS.md`: clipboard privacy marks, pointer lock, gamepads

## Its shape

- A release holds the TypeScript station on its own Node (`main.js`, `pnpm run build:node`, `NODE_VERSION` from `cloud/src/install.ts`), the MoonBit reader/builder (`stillfail-reader`), launcher, runner, Helper (`scripts/station-bundle.sh`).
- The MoonBit program runs the whole station (`station/mb/src/station_main`, `station/test/mb-live-*.test.ts`) when a release omits `main.js` (`station/native/launcher/src/main.rs` `station`) or `config.json` sets `"engine": "moonbit"` (`station_of`). 0.1.9984-0.1.9996 shipped it alone and reverted (chat events, files, peers, accounts fell short): not alone again until those live tests match TypeScript.
- Processes:
  - Launcher (`station/native/launcher`, Rust) owns the pid, data-dir lock, ports; it starts the next station, then stops the old.
  - Runner (`station/native/runner`) hosts each agent so turns survive restarts (`station/src/agents/runner.ts`, `station/src/agents/mb-agents.ts` `HostedProcess.adopt`); unowned runners end (`ownedRunners`, `station/src/sessions/hub.ts` `takeUp`, `endOrphan`).
  - The MoonBit front (`station/mb/src/front/mesh.mbt`) keeps iroh's endpoint over Node handovers (`station/native/launcher/src/front.rs`, `station/src/mesh/front.ts`); without one (Windows, some checkouts) Node binds iroh via `station/native/mesh` (also image codecs).
  - `station/native/launcher/src/lifecycle.rs` restarts a Node silent on `--launcher-heartbeat` or a dead front, and retries a given-up front later. It runs the updater when Node cannot (`--launcher-installer`, `run.rs` `run_installer`; Windows: a scheduled task). `stillfail status` reads Node's `<data>/run/health.json` (`station/src/ops/health.ts`).
  - The front routes device requests (`station/src/mesh/served.ts`) to MoonBit `reader --serve` (Node gives member identity, core floor, idempotency `claim`, handles `changes`/`said`), streams compressed `GET /events` via `relay`. Background `POST /batch` reads stay on Node behind interactive ones (`station/src/read/pool.ts`).
  - Native parts are prebuilt (`scripts/native.ts`): any edit, a comment too, rebuilds them everywhere, so change them only for function.
- Helper UI (`station/native/helper`) uses still.fail's design (`web/ui/src/palette.ts`, corners, capsule buttons, `s.` mark), not system controls.
- `station/src/main.ts` is the composition root: each part an Effect 4 `Layer` (`station/src/services.ts`), no self-registration or globals; scoped fibers, `Schedule` backoff, streams for pushes, plain functions.
- Mesh wire and door (`station/src/mesh/AGENTS.md`) stay independent of still.fail admission and routes (`scripts/mesh-base.ts`).
- The main thread waits on nothing: no synchronous `node:fs`, `child_process`, or `zlib` in `station/src/` unless marked `sync:` with a reason (startup or atomic step), except `*worker.ts`, off-main-thread `station/src/read/`, `station/src/cli.ts`, `station/src/updates/command.ts` / `delta.ts` (`scripts/check.sh`; `station/test/main-thread-waits.test.ts` counts only fall; `station/test/src-sync-calls.test.ts`, config writes via `updateSoon`, its list only shrinks).
- Effect `Clock` (`TestClock` in tests). `Date.now`, `new Date()`, `setTimeout`, `setInterval` only in `station/src/ops/fibers.ts` (`wall`: external mtimes, expiries, deadlines); `scripts/check.sh` rejects them elsewhere.

## Its data

- State is one SQLite file, `stillfail.db` (`station/src/store/store.ts`, `station/src/store/schema.ts`), one writer on the main thread. Reads, card pages, checkpoints, backfills, replica export/restore run in MoonBit readers and builders (`station/mb/`, `station/src/read/pool.ts`, `station/src/read/mb-reader.ts`, `station/src/replica/`): no JS workers, no TypeScript fallback. Schema repairs (`Readers.repairEdits`) run on the writer, retrying on busy without blocking. Parity references: `station/test/reference/`, `station/test/workers/`.
- Two processes open `stillfail.db` during a handover: each connection sets a busy timeout, each writing transaction starts `BEGIN IMMEDIATE` (`scripts/check.sh`).
- Station reads carry no UI words (the core's: `client/core-ts/src/chat-row.ts` `worded`, `entries.ts` `authorNameOf`, local pages, `station.files.*` refusals, `inScript`); only station notices and Comma messages do (`station/src/read/pool.ts` `SAID`).
- Every read uses an index and a limit; a new read gets a bounded test (`station/test/*-bounded.test.ts`). New indexes come from background backfills sharing one permit (`station/src/read/*-builder.ts`, `station/src/store/backfill.ts`); bound reads another way until then.
- Threads are append-only logs (edits append, Slack deletes ignored, readers merge); migrations go forward only; every change is pushed on `GET /events` (`station/src/api/events.ts`).
- No per-person or per-chat permission inside a workspace: every member and agent reads every chat (private too); agents share one OS user and database. Only workspaces are isolated. Never propose or build per-chat visibility: it is by design unless the owner changes it.

## Core invariants

- Subagents never speak in a chat; agent plain text is never forwarded; turns end with a state; bug-report replies never reach agents by themselves (`station/src/agents/AGENTS.md`, `station/src/sessions/AGENTS.md`).
- Workspace `MEMORY.md` and team skills sync to all stations by MoonBit 3-way merges; each person's devices carry presets and starred models (`station/src/share/AGENTS.md`).
- Relays: kept on stations, added by agents without approval after a probe; disabled ones apply to stations too (`station/src/mesh/AGENTS.md`).
- Rigs run tasks only under owner-signed grants; only its adding owner changes a station's mode (`station/src/rig/AGENTS.md`).
- Pinned locks are released only by `disable` or the local CLI, follow fork choice, enforce moved-workspace build floors (`station/src/cloud/AGENTS.md`).
- Heavy work goes to l4es `sandboxes` via `station_task`; no station or agent runs in one (`station/src/agents/AGENTS.md`).

## Screens

- One view drives a screen; any number watch (`station/src/screens/hub.ts` `drive`). Taking control (控制 / 接管, `taken`) makes every other driver (the person's other devices too) watch, told who took it; reconnects and resizes never take it.
- Agent input waits while a person drives (`station/src/tools/computer.ts`); both sides are told.

## Terminals

- Member terminals (`station/src/terminals/`) run under `native/runner --pty` (`term-…`, metadata in `<data>/run/terminals/`), adopted across restarts apart from agent runners (`isTerminalRunner`).
- Members not read-only type (exclusive with 接管); read-only ones watch; each workspace sees its own. A new viewer gets the libghostty-vt screen (`native/runner` `screen`), then live output.
- Terminals are `beta` (`station/src/features.ts`): new ones only on test-channel stations (overview `features`); old ones stay viewable and stoppable; none on rigs yet.

## Devices (设备)

- Devices: USB, network, or serial devices on a station (`station/src/devices/`, `connect.ts`), or a member's phone lent by its app (`station/src/adb/`). One list (`device_list`), one request flow (`device_use`). A chat gets a `127.0.0.1` port for its processes alone (`station/src/adb/door.ts`), tunneled over the mesh (`station/src/mesh/peer-http.ts`).
- A whole station's devices need no grant (all workspace chats share it); ones needing owner approval attach to a rig (`station/src/rig/AGENTS.md`).

## Tests

- Typecheck `pnpm exec tsgo --noEmit`; one file: `node ../scripts/native.ts run mesh runner archive-rs reader reader-harness launcher -- node --import ./test/setup-env.mjs --test test/<file>.test.ts` (all: `pnpm test`). A package's harness (`--builder harness-*`, its `harness*.mbt`) lives in the tests' `stillfail-reader-harness` (`station/mb/src/reader_harness`, `station/test/mb-harness.ts`), never the shipped reader. Fake agents on `TestClock`; real processes, signals, sockets in `station/side/`.
- CI runs `station/test/` on Linux, sliced (`scripts/check.sh`, `station-tests`). Tests pass on Linux and macOS or skip naming what is missing. File-backed vault tests use `station/test/vault-no-reader.ts` unless testing the reader process.
- Wait on off-main-thread work with `settle()` (`station/test/hub-fakes.ts`), not turn counts. Guard events that may never come with `given()` to fail at once.
