# The station as the MoonBit program runs it (for agents)

- `stillfail-reader` is the station itself when its arguments ask for it (`entry.mbt` `is_station`: a hook's file,
  one of `run`, `enroll`, `status`, `id`, `lock`, `channel`, `update`, `heap`, or `run`'s flags with no command);
  every reader and builder mode (`--data`, `--serve`, `--sessions`, `--builder …`) stays reader/main.mbt's as it was.
- What the shell (client/shell) does not do is `sys.c`'s, POSIX and `_WIN32` both, built into the reader for every
  target (station/mb/build.sh takes `src/*/*.c`): what comes later (a child's output and end, a lock taken, a control
  line, a signal) is an event on the host's queue (host.c `sfh_push_sys`, `Host::sys_listen`), never a call into
  MoonBit from another thread.
- What can be tested without the shell is in `media/` (the images' codecs, local links): `moon test` links no shell
  (scripts/check.sh's station MoonBit step), and this package, which imports the host package (station/mb/src/host), links only into the
  reader. The rest is held by station/test/mb-station-e2e.test.ts through the program (`--builder
  harness-station-main`, the commands, `run` under a launcher of the test's), each part to the TypeScript, the
  .mjs hooks or the mesh addon it replaces.
- `words_catalog.mbt` is client/i18n/catalog's station.json, zh and en, as the program carries them: a change to the
  catalog writes it again (the e2e test fails until it is: `STILLFAIL_WRITE_WORDS=1` on that test writes it).
- `run` (run.mbt) is the composition root so far of: the data directory held, its files read before ready, the
  launcher's channel (ops/launcher.ts's lines), its key and store, the loopback port, the status socket, the agents'
  door (`/mcp`: its tools and door places the parts', parts.mbt), health.json and the heartbeat, `heap`, a handover
  (what the parts carry) and its taking up. The hub and its actors, the mesh, the control plane's presence, the connects, jobs, vault, drive, browser,
  devices, copies and moves are their packages' (each held to its TypeScript by its harness), not put together here
  yet: until they are, the TypeScript station is what a release runs.
