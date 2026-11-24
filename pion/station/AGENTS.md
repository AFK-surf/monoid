# Working in `pion/station` (for agents)

Standalone Pion station workspace (`pion.toml`) with pinned `AFK-surf/pion` toolchain bootstrap, cross-platform C host/SQLite shims, and real `libstillfail_shell.a` static-link verification.

## Boundaries

- Keep `pion/station/` self-contained: do not depend on `pion/client-core/`, `pion/app/`, or UI packages.
- Do not modify `pion/base/`, `pion/client-core/`, or `pion/app/` from station-migration work (propose upstream `pion/base/` fixes separately). Slice-wiring PRs may update the corresponding `station/src/` switch entrypoints and `station/mb/` parity fixes alongside `pion/station/`.
- Foreign threads in `packages/host_shim/native/station_host.c` never invoke Pion callbacks; they only enqueue native events and signal the single-threaded event loop. `sth_stop` drops only `STH_EV_SHELL_DONE` events and preserves queued stdin data and EOF.
- Direct SQLite FFI in `packages/sqlite_ffi/native/station_sqlite.c` calls the `sqlite3_*` symbols bundled in `libstillfail_shell.a` without JSON serialization, behind generation-checked handle tables to prevent UAF on double-close or double-finalize.
- `--smoke-rc-soak` verifies deterministic RC reclamation and bounded RSS plateau for **acyclic object graphs** only; Pion RC does not auto-collect strong reference cycles, so long-lived station workers must break cycles via owner IDs or explicit `close()`.

## Packages and Scripts

- `TOOLCHAIN`: pinned `AFK-surf/pion` commit SHA bootstrapped by `scripts/ensure-pionc.sh`.
- `scripts/ensure-pionc.sh`: pinned upstream SHA bootstrap + local cache SHA-256 integrity verification across `pionc`, `qbe`, `libpionrt.a`, and runtime sources/headers (serialized with a lock directory).
- `scripts/build.sh`: builds `packages/smoke` (`stillfail-pion`) for `darwin-arm64`, `linux-x64` (glibc 2.28), `linux-arm64` (glibc 2.28), or `win32-x64` (MinGW GNU) linked against real `libstillfail_shell.a`.
- `packages/host_shim`: C11 POSIX + `_WIN32` host bridge (strict <= 16 MiB stdin backpressure, shell completion queue, stdout framing, args/pid/exit/RSS/fd-count) + Pion wrapper + C concurrency test (`packages/host_shim/native/host_shim_test.c`).
- `packages/sqlite_ffi`: direct `sqlite3_*` C11 FFI bridge + Pion wrapper (`open`, `prepare`, `bind_*`, `step`, `column_*`, `reset`, `clear_bindings`, `finalize`, `exec`, `wal_checkpoint`, `wal_checkpoint_hard`).
- `packages/footprint`: production disk footprint worker (`--builder footprint`) with thin cross-platform C11 FFI (`packages/footprint/native/footprint_fs.c`: `lstat`, sorted `readdir`, `exists`, `is_dir`, non-blocking regular-file-only `head`, monotonic clock) + pure Pion traversal/rebuildable/budget engine + C unit test (`packages/footprint/native/footprint_fs_test.c`).
- `packages/memory`: production agent memory & shared skills worker (`--builder memory [--shell-dir <dir>] [--sep <sep>]`) in pure Pion over `host_shim` (`libstillfail_shell.a` `fs.*`), `base_codec`, and `crypto` (all 16 JSON-RPC ops, JS UTF-16 ordering/tags, 3-way line merge, union lines, blob storage, path-safe atomic skill writes, streaming pipelined stdin loop).
- `packages/packed`: production cold-storage worker (`--builder packed [--shell-dir <dir>]`) in pure Pion over `host_shim` (`libstillfail_shell.a`: `fs.meta`, `fs.bytes`, `fs.put`, `zstd.segments`, `zstd.check`, `tar.pack`, `tar.unpack`, `tar.file`), matching `station/mb/src/packed` seek-table and streaming line-JSON RPC contracts.
- `packages/smoke`: `stillfail-pion` binary (`--version`, `--smoke-stdio`, `--smoke-sqlite`, `--smoke-shell`, `--smoke-rc-soak`, `--builder footprint [--sep <sep>]`, `--builder memory [--shell-dir <dir>] [--sep <sep>]`, `--builder packed [--shell-dir <dir>]`).

## Verification

- `sh pion/station/scripts/ensure-pionc.sh`
- `pionc fmt --check pion/station`
- `pionc check --json pion/station`
- `pionc test --json pion/station`
- `cc -std=c11 -O2 -Wall -Wextra -Werror pion/station/packages/host_shim/native/station_host.c pion/station/packages/host_shim/native/host_shim_test.c -lpthread -o /tmp/host_shim_test && /tmp/host_shim_test`
- `bash pion/station/scripts/build.sh linux-x64 /tmp/stillfail-pion-linux-x64`
