# Working in `pion/client-core` (for agents)

Pure-Pion client core workspace (`pion.toml`) on top of `pion/base` and official `AFK-surf/pion-packages` Git tags (`base64-v0.1.0`, `effect-v0.1.0`, `crypto-v0.2.0`, `flate-v0.1.0`, `url-v0.1.0`, `time-v0.1.0`, `http1-v0.1.0`, `json5-v0.1.0`), designed for two goals at once:

1. Strongly typed, immutable internal domain structures, zero-write cold chat open, and zero-serialization `FrameOutbox[T]` ready to feed the Invar render thread directly.
2. A removable thin JSON protocol adapter (`packages/protocol`) and C ABI bridge (`packages/core_abi/native/core_pion.c`) implementing all 6 functions of `apps/mbui/src/host/core_api.h` so `apps/mbui` can mount it during transition without changing a line.

## Packages

- `packages/outbox`: `FrameOutbox[T]` — typed, zero-serialization core-to-frame batching queue (`tell`, `take(most=...)`, coalesced single `wake`, `waiting`/`wakes`/`takes`).
- `packages/store`:
  - `schema.pion`: 100% SQLite schema parity with `client/core-ts/src/db/schema.ts` (`VERSION`, `MIGRATIONS`, `ensure_said`, `ensure_md_kept`, `ensure_kept`, `open_account_db` with forward-version read-only protection).
  - `md.pion`: `MdStore` (`md_key` UTF-16 FNV-1a parity with TypeScript/MoonBit, `older_md_keys`, single-statement `preload`, `get`/`put_prepared`/`note_opened`/`last_opened`, single-transaction `Burst` `flush_turn`).
  - `window.pion` & `open.pion`: `Entry`, `entry_min_rows`, `first_shown_window`, `open_chat` (zero writes before first view, constant statements at 5× chat count).
  - `chat_list.pion` & `ops.pion`: indexed `chat` reads (`chat_recent` window, PK/thread/session lookup, local `outbox`/`pending`/`draft` overlays, `account_doc`), draft & `workspace_pref` persistence, thread read cursor updates, bounded indexed `search_chats`, and `said`-backed `search_messages` — never full-table scans `chat`.
- `packages/protocol`: typed `CoreRequest` / `CoreEvent` / `Topic`, removable JSON wire codec matching `client/core-ts/src/protocol.ts`, keyed delta engine (`delta.pion`: `diff_keyed`/`apply_keyed`/`value_token`), and local router (`chat.open`, `chats.window`, `account.doc`, `accounts`, `account.switch`, `vault.status`, `vault.secrets`, `search.chats`, `search.messages`, `settings.get`, `settings.set`, `chat.draft`, topic subscriptions with `keyed` delta + `have`/`keep` token negotiation).
- `packages/core_abi`: Pion-side bridge types plus `packages/core_abi/native/core_pion.c` implementing `apps/mbui/src/host/core_api.h` (`mb_core_start`, `mb_core_send`, `mb_core_stop`, `mb_core_screen_ack`, `mb_core_screen_input`, `mb_core_route_media`) and standalone C test `packages/core_abi/native/core_abi_test.c`.
- `packages/sync`: Slice 2 pure-Pion sync engine, optimistic outbox, native `pion/rules` bridge, and dual-channel `ClientCore` facade:
  - `station_events.pion`: `StationEvents` (`mesh::Link` + `wire::Sse` `/events` consumer, zero polling, exponential virtual-clock reconnect backoff, single-transaction `sql::Burst` ingestion, typed `CoreEvent` pushed to `FrameOutbox[CoreEvent]`).
  - `sync_scheduler.pion`: `SyncScheduler` over `pion-packages/effect` (`effect::Scheduler`, `urgent_room`, `prioritize`, `Preempt`, Rule 4).
  - `local_outbox.pion`: `LocalOutbox` optimistic writes (`outbox`/`pending`/`changing`), `message.send`/`message.edit`/`message.delete`/`card.answer`/`chat.read`, exact `client_key` reconciliation, offline auto-flush on reconnect, and atomic rollback with recovery hint on station refusal (Rule 5).
  - `lock_bridge.pion`: zero-JSON native `pion/rules` (`lock`, `vault`) crypto & verification bridge backed by `mesh::ed25519_verify` / `ed25519_sign`, `crypto::p256_verify_der` (WebAuthn/Passkey) / `crypto::p256_verify_es256`, and `crypto::sha256_hex` / `crypto::sha256`.
  - `client_core.pion`: unified `ClientCore` exposing both direct typed `FrameOutbox[CoreEvent]` commands for Invar UI and thin JSON `core_api.h` wire protocol via `packages/protocol`.
  - `sim_station_test.pion`: deterministic `SimStation` + `SimAccountDb` E2E tests on `effect::Runtime` virtual clock.
- `packages/core_runtime` (standalone, excluded from default workspace tests): real `core_api.h` engine exporting `pub extern "C" fn` driver hooks wired to `packages/core_abi/native/core_pion.c`, `ClientCore`, and `shell_native::open` (`libstillfail_shell.so`), with C host E2E test `packages/core_runtime/native/core_runtime_e2e.c` and runner `packages/core_runtime/run_e2e.sh`.
- `packages/live_shell_smoke` (standalone, excluded from default workspace tests): end-to-end native executable linking `shell_native` + `shell_pion.c` + real Rust `libstillfail_shell` (`rusqlite` WAL + Tokio async IO).

## Rules

- Opening a chat writes nothing before its first view is built (`open_chat` performs 0 SQL writes, preloads `md_kept` in 1 statement, and keeps statement count constant as account chat count scales 5×). Pending `log_use` / `md_kept` writes flush afterward in one `Burst` transaction via `MdStore::flush_turn`.
- Never scan `chat` whole; keep all list reads bounded by indexes (`chat_recent`, `chat_thread`, `chat_session`, PK).
- Keep `md_key`, `entry_min_rows`, and SQLite schema byte-compatible with `client/core-ts` and `libs/client-core`.
- Use qualified `crypto::sha256_hex` / `crypto::sha256` (avoid unqualified `sha256_hex` shadowing in `pionc 0.1.0`).
- Verify with:
  - `pionc fmt --check pion/client-core`
  - `pionc check --json pion/client-core`
  - `pionc test --json pion/client-core`
  - `cc -Wall -Wextra -Werror -Iapps/mbui/src/host -I"$HOME/.pion/share/pion/runtime" pion/client-core/packages/core_abi/native/core_pion.c pion/client-core/packages/core_abi/native/core_abi_test.c -lpthread -o /tmp/core_abi_test && /tmp/core_abi_test`
  - `pionc build --target wasm32 pion/client-core/packages/sync`
