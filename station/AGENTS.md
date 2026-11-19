# Working on the station (for agents)

Subsystem rules live in narrower `AGENTS.md` files loaded when touching those directories:

- `station/src/agents/AGENTS.md`: runtime drivers, MoonBit output parsers, MCP tools, subagent silence, bug-report replies, sandboxes
- `station/src/sessions/AGENTS.md`: actors, MoonBit `--sessions`/`#jobs`/`#remote`/`#live`, turn states, card waits, usage 15m stats, cold storage, footprint, thread bounds
- `station/src/cloud/AGENTS.md`: lock pinning, fork choice, moved workspaces, device build floors, lock tests, cloud TCP entries
- `station/src/mesh/AGENTS.md`: mesh base isolation, workspace ways and relays, station name and icon
- `station/src/rig/AGENTS.md`: task-only stations (`rig` / `rigs`), ownership, signed grants, mode switch, rig devices
- `station/src/share/AGENTS.md`: shared agent memory, team skills, presets, starred models
- `station/src/ops/AGENTS.md`: storage manifest, log rotation, background yielding, bounded walks, self-memory, stdin backpressure
- `station/src/move/AGENTS.md` and `station/src/replica/AGENTS.md`: item migration, chat handovers, backups, retirement
- `station/mb/src/station_main/AGENTS.md` and `station/docker/AGENTS.md`: MoonBit whole-station engine and Docker image

## Its shape

- A release ships the TypeScript station on its own Node (`main.js`, `pnpm run build:node`, `NODE_VERSION` fetched by `cloud/src/install.ts`) alongside the MoonBit reader/builder program (`stillfail-reader`), launcher, runner, Helper, and bundle layout (`scripts/station-bundle.sh`).
- The MoonBit program can also run as the whole station (`station/mb/src/station_main`, `station/test/mb-live-*.test.ts`) when a release omits `main.js` (`station/native/launcher/src/main.rs` `station`) or `config.json` sets `"engine": "moonbit"` (`station_of`). Releases 0.1.9984-0.1.9996 ran it alone and reverted because chat events, files, peers, and accounts fell short. Do not ship it alone again until those live parity tests match TypeScript.
- Process architecture:
  - Launcher (`station/native/launcher`, Rust) owns the pid, data-dir lock, and ports, and starts the next station before stopping the old one on update.
  - Runner (`station/native/runner`) hosts each agent process so turns survive station restarts (`station/src/agents/runner.ts`, `HostedProcess.adopt` in `station/src/agents/mb-agents.ts`). End unowned runners (`ownedRunners`, `station/src/sessions/hub.ts` `takeUp`, `endOrphan`).
  - MoonBit front (`station/mb/src/front/mesh.mbt`) keeps the iroh endpoint across Node handovers (`station/native/launcher/src/front.rs`, `station/src/mesh/front.ts`). Where no front runs (Windows, checkouts without it), Node binds iroh through `station/native/mesh`, which also holds image codecs.
  - Launcher lifecycle (`station/native/launcher/src/lifecycle.rs`) restarts a Node silent on `--launcher-heartbeat`, restarts an unresponsive front, and later retries a given-up front. If Node cannot start the updater, the launcher runs it (`--launcher-installer`, `run.rs` `run_installer`, while Windows uses a scheduled task). Node writes `<data>/run/health.json` (`station/src/ops/health.ts`) for `stillfail status`.
  - The front routes device requests in `station/src/mesh/served.ts` directly to MoonBit `reader --serve` (Node supplies member identity, minimum core floor, idempotency `claim`, and handles `changes`/`said`) and streams compressed `GET /events` via `relay`. Background `POST /batch` reads stay on Node behind interactive reads (`station/src/read/pool.ts`).
  - Native parts are prebuilt from source (`scripts/native.ts`): even a comment edit forces rebuilds across CI and machines, so touch them only for functional changes.
- Non-app UI (`station/native/helper`) uses still.fail's design system (`web/ui/src/palette.ts`, corners, capsule buttons, `s.` mark), never system default controls.
- `station/src/main.ts` is the composition root: build every part as an Effect 4 `Layer` (`station/src/services.ts`) with no self-registration or global state. Use scoped fibers, `Schedule` for backoff, streams for pushes, and plain functions for pure logic.
- Mesh wire and door (`station/src/mesh/AGENTS.md`) stay independent of still.fail admission and routes (`scripts/mesh-base.ts`).
- The main thread waits on nothing. Never add synchronous `node:fs`, `child_process`, or `zlib` calls in `station/src/` unless marked `sync:` with a reason (startup-only or atomic step), outside `*worker.ts`, non-main-thread `station/src/read/`, `station/src/cli.ts`, and `station/src/updates/command.ts` / `delta.ts`. Enforced by `scripts/check.sh`, `station/test/main-thread-waits.test.ts` (counts only fall), and `station/test/src-sync-calls.test.ts` (config writes via `updateSoon`, allowed list only shrinks).
- Use Effect `Clock` (`TestClock` in tests). `Date.now`, `new Date()`, `setTimeout`, and `setInterval` are allowed only in `station/src/ops/fibers.ts` (`wall` for external mtimes/expiries/deadlines). `scripts/check.sh` rejects them elsewhere.
- Background work yields to foreground, directory walks stay bounded, and self-memory trims idle resources before launcher handover (`station/src/ops/AGENTS.md`).

## Its data

- Durable state lives in one SQLite file, `stillfail.db` (`station/src/store/store.ts`, `station/src/store/schema.ts`), with one write connection on the main thread. All reads, queued card pages, checkpoints, backfills, and replica exports/restores run in MoonBit readers and builders (`station/mb/`, `station/src/read/pool.ts`, `station/src/read/mb-reader.ts`, `station/src/replica/`) with no JS worker threads and no TypeScript fallback. Schema repairs (`Readers.repairEdits`) run on the writer and retry on busy without blocking. Parity tests compare against reference code in `station/test/reference/` and `station/test/workers/` (`station/src/read/` holds only production code).
- During handovers two processes access `stillfail.db` concurrently: every connection sets a busy timeout and every writing transaction starts with `BEGIN IMMEDIATE` (`scripts/check.sh` enforces both).
- Station reads return no localized UI text (`client/core-ts/src/chat-row.ts` `worded`, `entries.ts` `authorNameOf` localize unnamed chats/DMs, local pages, `station.files.*` refusals, and `inScript` results). Only station-authored notices and Comma messages carry words (`station/src/read/pool.ts` `SAID`).
- Every read uses an index and a limit (`station/test/*-bounded.test.ts`). Add a bounded test for every new read. Build new indexes via background backfills sharing one permit (`station/src/read/*-builder.ts`, `station/src/store/backfill.ts`), and bound reads another way until backfilled.
- Threads are append-only logs (edits append new entries, Slack deletes are ignored, readers merge). Schema migrations are forward-only. Push all changes through `GET /events` (`station/src/api/events.ts`), never polling.
- No per-person or per-chat permission system exists inside a workspace. Every member and every workspace agent can read every chat (including private ones) because agents share one OS user and database. Keep only workspaces isolated. Do not propose or build per-chat visibility. Answer reports that visibility is by design unless the owner changes policy.
- See `station/src/sessions/AGENTS.md` (usage 15m stats, cold storage, footprint, many-thread bounds), `station/src/ops/AGENTS.md` (storage manifest), `station/src/replica/AGENTS.md` (off-main-thread backups), and `station/src/move/AGENTS.md` (live item migration).

## Core invariants for agents, memory, mesh, rigs, and locks

- Subagents never speak in a chat, agent plain text is never forwarded, turns end with an explicit state, and bug-report replies never auto-reach agents (`station/src/agents/AGENTS.md`, `station/src/sessions/AGENTS.md`).
- Workspace `MEMORY.md` and team skills sync across all stations via MoonBit 3-way merges. Presets and starred models are carried by each person's devices (`station/src/share/AGENTS.md`).
- Workspace relays live on stations, agents add relays without approval after probing, and disabled relays apply to stations too (`station/src/mesh/AGENTS.md`).
- Rigs run tasks only under owner-signed grants, and only the adding owner changes a station's mode (`station/src/rig/AGENTS.md`).
- Pinned locks are released only by `disable` or local CLI, follow fork choice, and enforce moved-workspace build floors (`station/src/cloud/AGENTS.md`).
- Heavy work uses configured l4es `sandboxes` via `station_task`. Never install a station or run agents inside a sandbox (`station/src/agents/AGENTS.md`).

## Screens

- One person's view drives a screen at a time, while any number may watch (`station/src/screens/hub.ts` `drive`). Requesting control (控制 / 接管, `taken`) demotes every other driving view (including the same person's other devices) to watch-only and notifies them who took control. Automatic reconnects and resizes never take control.
- Agent input waits while a person drives (`station/src/tools/computer.ts`). Notify both sides when control is exclusive.

## Terminals

- Member terminals (`station/src/terminals/`) run under `native/runner --pty` (`term-…`, metadata in `<data>/run/terminals/`) and are adopted across station restarts separately from agent runners (`isTerminalRunner`).
- Every non-read-only member can open and type (exclusive control with 接管 like screens). Read-only members watch only. Workspaces see only their own terminals. New viewers receive the current libghostty-vt screen (`native/runner` `screen`) followed by live output.
- Terminals are a `beta` feature (`station/src/features.ts`): open new terminals only on test-channel stations (advertised in overview `features`), while existing ones remain viewable and stoppable. Rigs do not support terminals yet.

## Devices (设备)

- Devices are non-station peripherals used by agents: USB, network, or serial devices attached to a station (`station/src/devices/`, `connect.ts`), or a member's phone shared by its app (`station/src/adb/`). All share one list (`device_list`) and one request flow (`device_use`). Each chat gets a `127.0.0.1` port gated to its own processes (`station/src/adb/door.ts`), tunneled over the mesh (`station/src/mesh/peer-http.ts`).
- Devices on a whole station require no grant because the station is already shared across all workspace chats. Devices needing owner approval attach to a rig (`station/src/rig/AGENTS.md`).

## Tests

- Typecheck: `pnpm exec tsgo --noEmit`. Single test file: `node ../scripts/native.ts run mesh runner archive-rs reader reader-harness launcher -- node --import ./test/setup-env.mjs --test test/<file>.test.ts` (`pnpm test` runs all). A package's harness (`--builder harness-*`, its package's `harness*.mbt`) is the tests' program `stillfail-reader-harness` (`station/mb/src/reader_harness`, `station/test/mb-harness.ts`), never the shipped reader: add a new one there. Use fake agents on `TestClock`. Put real processes, signals, and sockets in `station/side/`.
- CI runs `station/test/` on Linux in slices (`scripts/check.sh`, `station-tests`). Tests must pass on Linux and macOS, or skip explicitly naming what is missing. File-backed vault tests use `station/test/vault-no-reader.ts` unless testing the separate reader process directly.
- Wait on off-main-thread work with `settle()` (`station/test/hub-fakes.ts`), never fixed turn counts. Guard events that might never arrive with `given()` so failures report immediately instead of timing out.
- Lock world and fork-choice tests are documented in `station/src/cloud/AGENTS.md`.
