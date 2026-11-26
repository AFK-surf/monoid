# Working in `pion/station-main` (for agents)

Standalone sibling Pion workspace (`pion.toml`) for the full Pion station binary (`stillfail-station-pion`), isolated from `pion/station/` (`stillfail-pion` reader/worker) so changes here never invalidate the `pion-reader` native cache key.

## Boundaries

- Reuse `pion/station/TOOLCHAIN` and `pion/station/scripts/ensure-pionc.sh`; never add a second toolchain pin.
- Keep `pion/station-main/` self-contained on shared packages from `pion/station/packages/`, `pion/rules/packages/`, and `pion/base/packages/base_codec`; do not depend on `pion/client-core/`, `pion/app/`, or UI packages.
- Do not advertise any role or CLI command in `stillfail-station-pion --version` (`roles:` / `commands:`) until its implementation and verification gates have landed.
- `--version` output must be a single line with exactly 4 whitespace-separated tokens: `stillfail-station-pion <version> roles:a,b commands:c,d` (no spaces after colons; empty lists are `roles:` and `commands:`).
- Static invariants enforced by `scripts/check.sh` and `scripts/mesh-base.ts`:
  - No polling timers without an explicit `timer:` reason on the line or preceding line.
  - Business code spawns child processes via the dedicated `station_sys` process-spawning primitive (added in W10-A) and never invokes `"proc.run"` directly; mark any required blocking `shell_sync*`/`shell_call_wait` call with `sync:` and a reason.
  - No raw SQLite transaction SQL (`BEGIN`/`COMMIT`/`ROLLBACK`/`SAVEPOINT`/`RELEASE`) outside `pion/station/packages/sql_db/`.
  - All listeners stay local (`"127.0.0.1"`, `"::1"`, `"localhost"`, `unix_listen`, `tcp_listen_fd`, or `{ "fd": ... }`) and no tunnel names appear in station code.
  - Mesh base packages (`mesh_wire`, `mesh_door`, `mesh_accept`, when present) import no station-domain packages and do not mention `still.fail` in code.

## Packages and Scripts

- `packages/station_sys`: cross-platform C11 system primitives (`packages/station_sys/native/station_sys.h`, `packages/station_sys/native/station_sys.c`, `packages/station_sys/native/station_sys_test.c`) + Pion wrapper (`packages/station_sys/src/station_sys.pion`) over `host_shim`'s event queue:
  - Non-recursive / single-file `fs.watch` (`FsChangeKind::Rename`, `Change`, `Overflow`, `Error`; note macOS uses path-based CoreServices `FSEvents`, while Linux uses inode-based `inotify` and Windows uses `ReadDirectoryChangesW`),
  - Async child process manager (`PROC_EXPLICIT_ENV`, `ChildProcess::kill` handle-bound signaling without PID-reuse window),
  - Launcher control fd (> 4) / named pipe, signals, `flock`/`LockFileEx` + `unlink`, `peer_process`, `process_usage`, PTY/ConPTY, UDP `dgram` (`udp_bind`, `udp_send_to`, `udp_send_once`, `ERR_HOSTUNREACH` = `-113`, `ERR_NETUNREACH` = `-101`), machine/OS/PSI/network interfaces.
  - Bounded-queue close contract: `sts_proc_close` / `sts_pty_close` / `sts_udp_close` detach teardown and return immediately even when `sth_push_sys_bounded` is full; each independent reader thread parked in `sth_push_sys_bounded` may surface at most one in-flight data frame for that closed `event_id` (plus pre-close queued frames — callers must discard frames for closed `event_id`s); shutdown completion is draining `sth_wait` until `sts_active_workers() == 0` and `sth_wait(0) == NULL`. Children meant to exit with the station should be terminated via `sts_proc_kill_handle` before `close`; background children left alive after `close` keep only a silent reaper (`closing == 1` emits no events) excluded from `sts_active_workers()`.
- `packages/station_http`: asynchronous HTTP/1.1 + chunked SSE + RFC 6455 WebSocket server (`HttpServer`, `SseStream`, `WsConn`, `Router`, `Middleware`) and async client wrappers (`HttpClient`, `WsClient`) over `builders_core::ShellMux` / `SerialOutbox` and pinned `pion-packages/{http1,websocket,url,mime,sse}` (zero RC cycles, strictly local listeners: loopback `127.0.0.1`, launcher inherited fd, Unix domain socket).
- `packages/station_ops`: station configuration (`config.json` reload & `handoff-error`), files/paths/places, held lock, build-time generated `i18n` catalog (`scripts/gen-i18n.mjs`), version/log/log-export scrubbing, launcher control channel state machine, health/forewarn/pressure/awake/own/previous/restart, platform helpers, loopback `/healthz` + `/admin` redirect, and native `shell-path` / `places`.
- `packages/station_store`: forward-only SQLite primary writer and idempotent schema migration core over `sql_db` / `station_conv` (`schema`, `store`, `conversations`, `archive`, `card_outbox` with `rig` CHECK widening + `AFTER DELETE` done trigger, `jobs_store`, `handover`, `timed`, and native SQLite `selftest`).
- `packages/station_rules_bridge`: native `libcrux` `lock::Crypto` & `vault::Crypto` adapters (Ed25519 + WebAuthn DER P-256 + `rig-form`), plus lossless WTF-8↔UTF-16 `form::Json`↔`js_json::JValue` bridge over `pion/rules/packages/*`.
- `packages/station_cloud`: cloud control plane client (`key`, `state`, `provider`, `transport` using `race: true`, `presence` bounded WS, `log_keep`, `lock_bodies`, `notify`, `signed`, `vault_lock`, `joinWorkspace`).
- `packages/station_main`: `stillfail-station-pion` entrypoint (`--version` prints `stillfail-station-pion 0.1.0 roles: commands:`; `--smoke-sys` verifies live `station_sys` FFI linking; `--smoke-http` verifies live `station_http` HTTP/1.1 + prefix + HEAD/204 + chunked SSE + WebSocket roundtrip over `libstillfail_shell.a`).
- `scripts/gen-i18n.mjs`: generates `packages/station_ops/src/i18n_catalog.pion` from `client/i18n/catalog/{zh,en}/station.json` and `client/i18n/brand.ts` (`--check` verifies zero drift in CI).
- `scripts/build.sh`: builds `stillfail-station-pion` for `darwin-arm64`, `linux-x64`, `linux-arm64`, or `win32-x64`, linking `host_shim`'s `station_host.o`, `sqlite_ffi`'s `station_sqlite.o`, `station_sys`'s `station_sys.o`, and `libstillfail_shell.a`.

## Verification

- `sh pion/station/scripts/ensure-pionc.sh`
- `node pion/station-main/scripts/gen-i18n.mjs --check`
- `pionc fmt --check pion/station-main`
- `pionc check --json pion/station-main`
- `pionc test --json pion/station-main`
- `bash pion/station-main/scripts/build.sh linux-x64 /tmp/stillfail-station-pion-linux-x64`
