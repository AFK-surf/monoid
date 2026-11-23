# Working in `pion/station` (for agents)

Standalone Pion station workspace (`pion.toml`) with pinned `AFK-surf/pion` toolchain bootstrap, cross-platform C host/SQLite shims, and real `libstillfail_shell.a` static-link verification.

## Boundaries

- Keep `pion/station/` self-contained: do not depend on `pion/client-core/`, `pion/app/`, or UI packages.
- Do not modify `pion/base/`, `pion/client-core/`, `pion/app/`, `station/mb/`, or `station/src/` from station-toolchain work; propose any upstream `pion/base/` fixes separately.
- Foreign threads in `packages/host_shim/native/station_host.c` never invoke Pion callbacks; they only enqueue native events and signal the single-threaded event loop.
- Direct SQLite FFI in `packages/sqlite_ffi/native/station_sqlite.c` calls the `sqlite3_*` symbols bundled in `libstillfail_shell.a` without JSON serialization.

## Packages and Scripts

- `TOOLCHAIN`: pinned `AFK-surf/pion` commit SHA bootstrapped by `scripts/ensure-pionc.sh`.
- `scripts/ensure-pionc.sh`: verifies or bootstraps `pionc`, `qbe`, and `pion_rt.c` from `TOOLCHAIN` with SHA-256 lock verification.
- `scripts/build.sh`: builds `packages/smoke` (`stillfail-pion`) for `darwin-arm64`, `linux-x64` (glibc 2.28), `linux-arm64` (glibc 2.28), or `win32-x64` (MinGW GNU) linked against real `libstillfail_shell.a`.
- `packages/host_shim`: C11 POSIX + `_WIN32` host bridge (16 MiB stdin backpressure, shell completion queue, stdout framing, args/pid/exit/RSS/fd-count) + Pion wrapper + C ABI test (`packages/host_shim/native/host_shim_test.c`).
- `packages/sqlite_ffi`: direct `sqlite3_*` C11 FFI bridge + Pion wrapper (`open`, `prepare`, `bind_*`, `step`, `column_*`, `finalize`, `exec`, `wal_checkpoint`).
- `packages/smoke`: `stillfail-pion` binary (`--version`, `--smoke-stdio`, `--smoke-sqlite`, `--smoke-shell`, `--smoke-rc-soak`).

## Verification

- `sh pion/station/scripts/ensure-pionc.sh`
- `pionc fmt --check pion/station`
- `pionc check --json pion/station`
- `pionc test --json pion/station`
- `cc -std=c11 -O2 -Wall -Wextra -Werror pion/station/packages/host_shim/native/station_host.c pion/station/packages/host_shim/native/host_shim_test.c -lpthread -o /tmp/host_shim_test && /tmp/host_shim_test`
- `bash pion/station/scripts/build.sh linux-x64 /tmp/stillfail-pion-linux-x64`
