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
  - `chat_list.pion`, `moved.pion` & `ops.pion`: indexed `chat` reads (`chat_recent` window, PK/thread/session lookup, local `outbox`/`pending`/`changing`/`draft` overlays, `thread`, `account_doc`), `moved` table & multi-hop `resolve_chat_now` (with cycle detection and origin-row cleanup), draft & `workspace_pref` persistence, thread read cursor updates, bounded indexed `search_chats`, and `said`-backed `search_messages` — never full-table scans `chat`.
- `packages/views`: pure-Pion view projections and unified safe-mode lock state machine:
  - `chats_view.pion`: `RowsMemo` incremental row memoization (constant reads at 3× scale, zero full-table scan), `project_chats` (`days` bucketing + pinned `daysAgo: -1`, `pending`, `changing` rename/pin/archive, `draft`, viewer-only `unread`/`mine`/`quoted` marks, `moved` deduplication, ≤ 4 KB keyed delta via `protocol::diff_keyed`).
  - `chat_view.pion`: `project_chat` with 0 SQL writes on cold open, `tool_call`/`tool_result` folding, interactive `card` (`options`/`text`/`login`, recommended last, `answeredBy`), attachment tokens stripping inline bytes, exact `clientKey` outbox dedup, `changing` edit/delete/card_answer overlays, `unreadLine`/`hasMore`/`oldest`.
  - `workspace_view.pion`: conformed `project_workspaces`, `project_workspace`, `project_stations`, `project_accounts`, `project_vaults` stripping internal/detail/secret fields.
  - `lock_view.pion`: native `pion/rules` (`lock`, `fork`, `form`, `role`, `vault`) active chain + fork choice (`ASIDE_MOST = 256`, `prev == head`, `again_of` `AGAIN_MOST = 3`), moved workspace `lock::state4_moved` & `lock_moved` refusal, strict `ownLockFor` (`vouchers_in`/`approved_in`), `LockPendingQueue` (station delivery only, `PENDING_MOST = 8`), and unified `SafeModeView` (Laws A/B/C, zero 「个人锁」 leakage).
- `packages/protocol`: typed `CoreRequest` / `CoreEvent` / `Topic`, removable JSON wire codec matching `client/core-ts/src/protocol.ts`, keyed delta engine (`delta.pion`: `diff_keyed`/`apply_keyed`/`value_token`), and local router (`chat.open`, `chats.window`, `account.doc`, `accounts`, `account.switch`, `vault.status`, `vault.secrets`, `search.chats`, `search.messages`, `settings.get`, `settings.set`, `chat.draft`, topic subscriptions with `keyed` delta + `have`/`keep` token negotiation).
- `packages/core_abi`: Pion-side bridge types plus `packages/core_abi/native/core_pion.c` implementing `apps/mbui/src/host/core_api.h` (`mb_core_start`, `mb_core_send`, `mb_core_stop`, `mb_core_screen_ack`, `mb_core_screen_input`, `mb_core_route_media`) and standalone C test `packages/core_abi/native/core_abi_test.c`.
- `packages/sync`: Slice 2 pure-Pion sync engine, optimistic outbox, native `pion/rules` bridge, and dual-channel `ClientCore` facade:
  - `station_events.pion`: `StationEvents` (`mesh::Link` + `wire::Sse` `/events` consumer, zero polling, exponential virtual-clock reconnect backoff, single-transaction `sql::Burst` ingestion, typed `CoreEvent` pushed to `FrameOutbox[CoreEvent]`).
  - `sync_scheduler.pion`: `SyncScheduler` over `pion-packages/effect` (`effect::Scheduler`, `urgent_room`, `prioritize`, `Preempt`, Rule 4).
  - `local_outbox.pion`: `LocalOutbox` optimistic writes (`outbox`/`pending`/`changing`), `message.send`/`message.edit`/`message.delete`/`card.answer`/`chat.read`, exact `client_key` reconciliation, offline auto-flush on reconnect, and atomic rollback with recovery hint on station refusal (Rule 5).
  - `lock_bridge.pion`: zero-JSON native `pion/rules` (`lock`, `vault`) crypto & verification bridge backed by `mesh::ed25519_verify` / `ed25519_sign`, `crypto::p256_verify_der` (WebAuthn/Passkey) / `crypto::p256_verify_es256`, and `crypto::sha256_hex` / `crypto::sha256`.
  - `client_core.pion`: unified `ClientCore` exposing both direct typed `FrameOutbox[CoreEvent]` commands for Invar UI and thin JSON `core_api.h` wire protocol via `packages/protocol`, wired directly to `packages/views` (`RowsMemo`, `ViewerMarks`, `LockPendingQueue`, `project_chats`, `project_chat`, `project_workspaces`, `project_workspace`, `project_stations`, `project_accounts`, `project_vaults`, `project_safe_mode`).
  - `shell_transport.pion`: live HTTP/SSE `StationTransport` (`shell_http_transport`) and iroh Mesh bidirectional QUIC `StationTransport` (`shell_iroh_transport` over `iroh.bind`/`iroh.setRelayEntries`/`iroh.connect`/`conn.openBi`/`istream.*` + `wire::head_line`/`wire::reply_head`, zero polling).
  - `cloud_sync.pion`: `CloudSync` (`fetch_me_k`, `fetch_workspace_k`, `fetch_member_credential_k` with expiry cache, and `/v1/events` WebSocket consumer with `1000ms..60000ms` exponential backoff) persisting `/v1/me` (`account_doc`) and `/v1/workspaces/<ws>` (`workspace` + `station` overview) to SQLite.
  - `sim_station_test.pion` & `cloud_sync_test.pion`: deterministic `SimStation`, `SimAccountDb`, `CloudSync`, `shell_http_transport`, `shell_iroh_transport`, and `packages/views` subscription/delta tests on `effect::Runtime` virtual clock.
- `packages/core_runtime` (standalone, excluded from default workspace tests): real `core_api.h` engine exporting `pub extern "C" fn` driver hooks wired to `packages/core_abi/native/core_pion.c`, `ClientCore`, `CloudSync`, `shell_http_transport`, `packages/views` live SSE keyed delta push, and `shell_native::open` (`libstillfail_shell.so`), with C host E2E tests `packages/core_runtime/native/core_runtime_e2e.c` + `packages/core_runtime/native/core_runtime_live_net_e2e.c` and runner `packages/core_runtime/run_e2e.sh`.
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
  - `pionc build --target wasm32 pion/client-core/packages/views`
