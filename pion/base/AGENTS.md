# Working in `pion/base` (for agents)

Program-agnostic pure-Pion client base workspace (`pion.toml`), mirroring the non-mesh and mesh foundation of `libs/base` on top of official `AFK-surf/pion-packages` ecosystem dependencies and the flat C ABI shell bridge.

## Ecosystem Dependencies (`AFK-surf/pion-packages`)

Declared in `[workspace.dependencies]` in `pion.toml` via official Git tags:

- `base64` (`base64-v0.1.0`): RFC 4648 Base64 / Base64URL and hex codecs.
- `effect` (`effect-v0.1.0`): single-threaded cooperative fiber runtime (`Runtime`, `Fiber`, `Deferred`, `EffectScope`, `Queue`, `Semaphore`, `Rng`, deterministic `TestClock`, interruption) plus built-in priority lane `Scheduler` / `Preempt` / `priority_*`.
- `crypto` (`crypto-v0.2.0`): SHA-256, SHA-512, SHA-1, HMAC-SHA-256, strict RFC 8032 Ed25519 signing/verification, and P-256 ECDSA DER verification (`p256_verify_der`).
- `flate` (`flate-v0.1.0`): RFC 1951/1950/1952 deflate/zlib/gzip and IEEE CRC-32 / Adler-32 checksums.
- `url` (`url-v0.1.0`): WHATWG URL parsing and percent-encoding.
- `time` (`time-v0.1.0`): Gregorian calendar and ISO 8601 / RFC 3339 formatting/parsing.
- `http1` (`http1-v0.1.0`): HTTP/1.1 parser/encoder and WHATWG `SseDecoder`.
- `json5` (`json5-v0.1.0`): JSON5 / JSONC / strict JSON parser, serializer, Pointer, and Patch.

## Local Packages

- `packages/base_codec`: thin Base64 / Base64URL / hex / IEEE CRC-32 adapters over `pion-packages/base64` & `flate`, plus insertion-ordered `Json` parser/stringifier preserving raw `Int64` numeric `repr` beyond 2^53-1.
- `packages/wire`: stream line framing (`Carry`, `hello_line`, `head_line`, `reply_head`) and Monoid JS-compatible byte-exact SSE parser (`Sse`, `Event`, `TooLong`).
- `packages/net`: `Socket`, `Listener`, and `pipe_duplex_k` with exactly-once close guarantees.
- `packages/shell`: `Shell` interface (`Shell::stood_in` test stand-in, `call_k`, `tell`, `ask`, `give_up`, `random`, `pump`, `turn`), pure async network/WebSocket/peer-mesh op wrappers (`net_ops.pion`: `fetch_k`, `stream_open_k`/`stream_read_k`/`stream_close`, `ws_open_k`/`ws_next_k`/`ws_send_*`/`ws_close`, `iroh_*`/`conn_*`/`istream_*`), and native C bridge `packages/shell/native/shell_pion.c` targeting `sf_shell_*` (zero `extern "C"` in `packages/shell` so `wasm32` builds stay pure).
- `packages/shell_native`: native `extern "C" fn` binding (`open`, `now_ms`, `is_attached`, `random_bytes`, `drain_until`, `decode_ask_envelope`) linking `packages/shell/native/shell_pion.c` and Rust `libstillfail_shell`.
- `packages/sql`: `Sql` (including `in_transaction`), `Burst`, `query_in_chunks`, and `col_*` readers over `Shell::ask("sql.*", ...)`.
- `packages/mesh`: program-agnostic device-side mesh protocol stack (`Mesh`, `Link`, `Reply`, `Out`, `Inbound`, `Incoming`, `Outgoing`, Ed25519/SHA-512/SHA-256 delegated to `pion-packages/crypto`, multi-way scoring/promotion/pruning, health racing, wake/rebind, speed/daily tallies, tracing/recorder, and dual-Mesh simulated network tests).

## Rules

- Keep every package strictly program-agnostic: no product or domain words in `packages/`. Only the existing C ABI symbols (`sf_shell_start`, `sf_shell_call`, `sf_shell_call_sync`, `sf_free`) are referenced in `packages/shell/native/shell_pion.c`.
- Qualify hash calls as `crypto::sha256` / `crypto::sha256_hex` (avoid unqualified `sha256_hex` shadowing in `pionc 0.1.0`).
- Verify with `pionc fmt --check pion/base`, `pionc check --json pion/base`, `pionc test --json pion/base`, `cc -Wall -Wextra -Werror -fsyntax-only -I"$HOME/.pion/share/pion/runtime" pion/base/packages/shell/native/shell_pion.c`, and `pionc build --target wasm32 pion/base/packages/mesh`.
