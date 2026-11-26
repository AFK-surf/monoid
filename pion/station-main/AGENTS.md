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

- `packages/station_main`: `stillfail-station-pion` entrypoint (`--version` prints `stillfail-station-pion 0.1.0 roles: commands:`).
- `scripts/build.sh`: builds `stillfail-station-pion` for `darwin-arm64`, `linux-x64`, `linux-arm64`, or `win32-x64`, linking `host_shim`'s `station_host.o` and `libstillfail_shell.a`.

## Verification

- `sh pion/station/scripts/ensure-pionc.sh`
- `pionc fmt --check pion/station-main`
- `pionc check --json pion/station-main`
- `pionc test --json pion/station-main`
- `bash pion/station-main/scripts/build.sh linux-x64 /tmp/stillfail-station-pion-linux-x64`
