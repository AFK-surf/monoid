# The station as the MoonBit program runs it (for agents)

- `stillfail-reader` is the station itself when its arguments ask for it (`entry.mbt` `is_station`: a hook's file,
  a sandbox's bridge or a Claude TUI's (`<…>/claude-tui.mjs` and its `hook` and `mcp`: claude_tui.mbt, line for line
  as src/agents/claude-tui.mjs, which a session a station from before started still runs under Node), one of `run`,
  `enroll`, `status`, `id`, `lock`, `channel`, `update`, `heap`, or `run`'s flags with no command);
  every reader and builder mode (`--data`, `--serve`, `--sessions`, `--builder …`) stays reader/main.mbt's as it was.
- What the shell (client/shell) does not do is `sys.c`'s, POSIX and `_WIN32` both, built into the reader for every
  target (station/mb/build.sh takes `src/*/*.c`): what comes later (a child's output and end, a lock taken, a control
  line, a signal) is an event on the host's queue (host.c `sfh_push_sys`, `Host::sys_listen`), never a call into
  MoonBit from another thread. So is `live_p5_4_io.c`: a TCP connection to any address, a serial port, and one ask of
  still.fail Helper's socket at once (the drive's protected folders).
- The vault's keys, signatures and its proxy's TLS 1.3 are this package's (`live_p5_4_crypto.mbt`,
  `live_p5_4_tls.mbt`) over the shell's primitives (SHA-256, HMAC, X25519, ChaCha20-Poly1305, Ed25519, ECDSA's check):
  each P-256 and RSA signature made here is checked before it is given. Their BigInt arithmetic is not constant time
  (known and taken, the lead 2026-11-17); the proxy speaks no HelloRetryRequest, resumption or early data.
- What can be tested without the shell is in `media/` (the images' codecs, local links): `moon test` links no shell
  (scripts/check.sh's station MoonBit step), and this package, which imports the host package (station/mb/src/host), links only into the
  reader. The rest is held by station/test/mb-station-e2e.test.ts through the program (`--builder
  harness-station-main`, the commands, `run` under a launcher of the test's), each part to the TypeScript, the
  .mjs hooks or the mesh addon it replaces.
- `words_catalog.mbt` is client/i18n/catalog's station.json, zh and en, as the program carries them: a change to the
  catalog writes it again (the e2e test fails until it is: `STILLFAIL_WRITE_WORDS=1` on that test writes it).
- `run` (run.mbt) is the composition root: the data directory held, its files read before ready, the launcher's
  channel (ops/launcher.ts's lines), its key and store, the loopback port, the status socket, the agents' door (`/mcp`:
  its tools and door places the parts', parts.mbt), health.json and the heartbeat, `heap`, a handover (what the parts
  carry) and its taking up. It makes the composition bus once the store opens (`live_bus.mbt`: what services.ts's
  layers give each other) and starts the live slices on it, a file family each (`live_p5_<N>_*.mbt`, each its
  `start_live_p5_<N>`): P5-1 first, then on a whole station P5-2, P5-3, P5-4 and P5-5 in that order (P5-3 finds the
  hub's sessions' program there and mounts `#jobs` and `#remote` on it); a station that only runs tasks (`--rig`, or
  cloud.json's `rig`) starts P5-3 and the devices of P5-4 alone. What one slice asks of another goes by name on the bus
  (`hub_ask`, `jobs_ask`, `ui_ask`, `coord_ask`, `cloud_call`, the peers' `$…` handlers), never an import of its file;
  what several slices follow is a list on the bus each adds to (`on_release`, `on_peer_heard`, `on_trim`,
  `register_pids`). station/test/mb-station-contracts.test.ts holds every `Ref` of the bus given by a slice, and every
  `parts.carry`, `plane.told` and `events.follow` hook of the TypeScript's given here; station/test/mb-live-hooks-parity.test.ts
  holds them live.
  A release runs this program alone (station/AGENTS.md); held by station/test/mb-live-station.test.ts whole, under the
  real launcher, and each slice by its own test:
  - P5-1 (`live_p5_1_*.mbt`), the platform: config.json, the log and error reports, the machine kept awake, a lost
    station's chats taken back before the store opens, the control plane and its presence, the readers and their
    builders, the machine and the event streams, the admin API (the platform's calls answered there, another slice's
    asked through the bus), the mesh (the front's endpoint or one bound through the shell, members, peers, the agents'
    `/peer/` door, the device tools), the workspaces' mesh directory, the relays' enrollment door and a device's leaf
    in its workspace's scope (live_p5_1_scopes.mbt over src/mesh_scopes: mesh/scope-sync.ts, enrollment-door.ts and
    leaf.ts as the TypeScript has them, where the endpoint is the front's), the forwards of other stations' ports and
    devices (`$forwards`) and the rigs.
    With `STILLFAIL_LOCAL_ADMIN=1` (a test with no mesh) the admin API is on the agents' door under `/admin-api/`, as
    the station's owner: station/test/mb-live-p5-1.test.ts.
  - P5-2 (`live_p5_2_*.mbt`), the agents' side: the hub, its actors and their drivers in the sessions' program
    (`stillfail-reader --sessions`, with `#live` mounted: live_p5_2_main `mount_live`), the conversations and their
    storage's world (live_p5_2_world.mbt: the live view's locator, the machine's sessions, the peers), the tools of
    `/mcp`, and what the admin API's routes ask by a module's name (live_p5_2_hubops.mbt `hub_bridge`); the usage
    counter, its drain and the old statistics' retirement (live_p5_2_usage.mbt), the bug reports' part:
    station/test/mb-live-p5-2.test.ts.
  - P5-3 (`live_p5_3*.mbt`), the jobs and their services, other stations' tasks (`task.*`, `sync.*`, `file.*`,
    `session.*` on the peers' bus), resources (the network's counters: live_p5_3_netstat.c) and the station's own
    memory, search, upkeep, a workspace's size, the accounts (what they ask of the machine: live_p5_3_accounts_io.mbt)
    and the model catalog, the shared profiles, the memory and the chats shared across workspaces. The jobs and the
    remote tasks run as `#jobs` and `#remote` of the sessions' program (the hub's where `hub_ask("program.has")` says
    so, one of its own only where there is no hub, a rig's or a test's: never two on one data directory); a sandbox's
    task runs through this program as its bridge's host side (`stillfail-reader <…>/sandbox-bridge.mjs host
    '<json>'`: live_p5_3_sandbox.mbt). With `STILLFAIL_PARTS_DOOR=1` the agents' door answers the parts' routes,
    `jobs_ask`, `hub_ask`, overview fields and peers' requests under `/parts/`: station/test/mb-live-p5-3.test.ts.
  - P5-4 (`live_p5_4_*.mbt`), the vault, the drive and its transfers, the screens with the Helper and its grants, the
    browser, the phones and devices, the terminals and the logins, answered by name on `ui_ask`:
    station/test/mb-live-p5-4.test.ts.
  - P5-5 (`live_p5_5_*.mbt`), the connects of Slack, Feishu, Comma and the group, and the workspace's connects (their
    chat surfaces told the agents' side, `surfaces`, and called by name, `chat.*`); the copies, their export a
    backgrounded process of its own, and a retirement; the moves; the updates and the `beta` features, on
    `coord_ask`: station/test/mb-live-p5-5.test.ts.
- `@host.now()` (and the runtime's `now`) is a monotonic clock counting from the machine's start: it times waits and
  durations only. A time a part keeps or compares as the world's (a record's `at`, an expiry, a process's start) is
  `p5_epoch_ms` (sys.mbt), given to each package's clock where it is made; a process's start is `start_time_of`
  (the system's, ms since the epoch), never `ps`'s words, which are in the machine's own time zone.
- The shell keeps no watch of a file or a folder: what the TypeScript watched (a transcript, a job's log, a drive's
  folder, run/'s files) is looked at by its size and time every few hundred ms while it is followed, its line saying
  `timer:` why. A command named bare is found on the PATH it is given, then in the system's own directories
  (sys.mbt `resolved_program`, the shell's `proc.run`), so a station whose PATH names none of them still runs `ps`,
  `lsof` or `git`.
