# `station_ops`

Pure-Pion core ops, lifecycle, and platform helpers for `stillfail-station-pion`, aligned 1:1 with `station/src/ops/` and `station/src/platform/`.

## Scope & Wiring Boundaries

This package is designed to have zero `station_http` / Effect-runtime dependencies so it can be unit-tested deterministically and composed into the main station event loop during Wave 10 integration:

- **`OpsFs` (`fs_port.pion`)**:
  - Production `shell_ops_fs()` wires `fs.bytes`, `fs.write` (with `mode`), `fs.lstat` (with `follow: true` for `stat`), `fs.readlink`, `fs.realpath`, `fs.mkdir`, `fs.rename`, `fs.remove`, `fs.readdir`, and `fs.rotate` (via `shell_rotate_blocking` for standalone/CLI callers, or `shell_rotate_request` + `parse_rotate_reply` for async event-loop callers). `client/shell` has no `fs.truncate`; `rotate_in_place` always delegates to `fs.rotate`.
  - Unit tests use deterministic in-memory `MemFs` (inode tracking, mode bits, symlink resolution, transient rename fault injection, and inode-preserving `rotate_in_place_native`).
- **`ConfigFile` (`config.pion`)**:
  - Implements synchronous `update()` + non-recursive `station_sys::fs_watch_open` hot reload (`watch`, `unwatch`, `on_fs_event`) with self-write tracking (`last_written_text`) and post-write stamp invalidation (preventing concurrent external edits from being skipped).
  - Async serialized off-thread `updateSoon` / `written` queuing is left to the station's async Effect/event-loop composition layer.
- **`LogExporter` (`log_export.pion`)**:
  - Implements full PII/secret scrubbing (`scrub_secrets` incl. PEM private keys & `Cookie:`/`Set-Cookie:` headers, `scrub_emails`, `scrub_email_slugs`, `scrub_message`, scrub-before-truncate on UTF-8 character boundaries), bounded queue trimming (dropping oldest `INFO` lines first), and OTLP JSON batch construction (`otlp_record`, `build_body`, `log_export_refused`).
  - Periodic 5s flush scheduling and signed HTTP transport to `/v1/telemetry/logs` are wired in the control-plane/HTTP layer.
- **`restart` (`restart.pion`)**:
  - Implements pure-data handover/restart decision logic (`RestartMode`, `pick_restart_mode`, `should_handover_for_memory`) without invoking `station_http` or process exit directly; the main station composition root dispatches the chosen action (`LauncherChannel`, `station_sys::proc_kill`, or platform restarter).
- **`ShellPathProbe` (`shell_path.pion`)**:
  - Implements credential-stripped interactive/login shell PATH probing over `station_sys::proc_spawn` (`ChildProcess`) with 8s timeout, 256 KiB output cap, exit code 0 check, and process-group `SIGKILL` cleanup, plus both event-driven (`ShellPathProbe`) and standalone blocking (`read_shell_path_blocking`) drivers.
