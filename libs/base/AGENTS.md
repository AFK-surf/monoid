# Working in the base (for agents)

The first of the base in MoonBit: what a client's core stands on where the core is MoonBit, written once and shared (the user, 2026-11-14: still.fail's own core moves to MoonBit, 「以后 still fail 也会切 mb」, a module written once for both sides, 「这样两边共用」). A moon module of its own, `base`, taking mbui's `effect` as a member of its workspace (`moon.work`); `effect` stays in mbui.

Narrower rules: `src/shell/AGENTS.md` (the shell's binding), `src/mesh/AGENTS.md` (what the mesh gives a program, what is left to the shells, fibers and shell lifetimes).

## Its parts

- `src/shell`: the Rust shell's binding (`client/shell`, via its C interface) for a program on `@effect`, natively and on js, with `Shell::stood_in` for tests (`src/shell/AGENTS.md`).
- `src/sql`: SQLite in the shell, asked synchronously (`sql.*`, `Shell::ask`): `Sql` (open, attach, exec, run, all, close), `Burst` (one writer's transaction: `BEGIN IMMEDIATE` at its first write, committed once, none if nothing written, `in_tx` rolls back what raised), `query_in_chunks` (one statement per `chunk_most` keys, each key once, none for none), the `col_*` readers. The schema is its program's.
- `src/scheduler`: one lane of requests to a peer, most urgent first (as `client/core-ts/src/sync/scheduler.ts`): urgent in `width` plus `urgent_room`, shown in `width`, background one at a time behind them and any request in sight (`foreground_begin`), idle alone and told to give way (`Preempt`) when anything above background is asked; background waits for an idle step to end. A task runs in the asking fiber (`Scheduler::run`); interrupted, a `defer` frees its place or slot.
- `src/wire`: pure framing and event-stream parsing (`lines`, request/reply heads, SSE text), no transport.
- `src/hash`: SHA-256, SHA-1 (`Sha256`, `Sha1` piecewise, `sha256`, `sha1`, `_hex`, `_utf8_hex`: a lone surrogate as U+FFFD, as node:crypto, where `@utf8.encode` aborts natively), HMAC-SHA-256, hex, no dependency: programs on the base hash with it, never a copy. SHA-1 only where a format names it (WebSocket accept, Git names), never for new trust.
- `src/url`: percent-encoding as ECMA-262 `encodeURIComponent`, `encodeURI`, `decodeURIComponent` (lone surrogate U+FFFD, or `None` in `encode_uri_component_strict` and the decoder where they throw), `percent_encode` keeping what the caller says (a form's `+`).
- `src/flate`: raw deflate both ways (`inflate`, `inflate_at` saying where it ended; `deflate`, `Deflater` piecewise over a kept 32 KiB window, fixed Huffman or stored), zlib and gzip wrappings with checks (`zlib_compress`/`zlib_decompress`, `gzip`/`gunzip`, Adler-32 here, CRC-32 `src/codec`'s). Not zlib byte for byte (no dynamic codes): only what inflates is the same.
- `src/net`: a connection's halves and a listener loop over a program's transport (`Socket`, `Listener`, `pipe_duplex`; net.mbt's head): a handle closed exactly once however it ends, a passing accept failure retried, nothing a defect.
- `src/mesh`: the mesh's device side on `shell` and `wire`: endpoints, scoped peer links, hello/pings/renewal, requests/streams/duplex; `health.mbt` health racing, `wake.mbt` wake/rebind, `bind.mbt` binding, relays and incoming/outgoing connections, `addrs.mbt` direct dials, `dial_once.mbt` one-off dials on a program's protocol, `ways.mbt` ways to a place and the choice, `sha256.mbt` keys of relay endpoints, `speed.mbt` speeds and the day's tally, `trace.mbt` what it tells of itself, `hooks.mbt` a program's other asks, `sign.mbt` Ed25519 and SHA-512.

## It knows no program

- Not still.fail's app, station or cloud, nor any application. Everything program-specific comes in through `Options` (`Binding`: lookup, protocols taken, relay entries), `Mesh::link` (`scope`), `Mesh::drop_link` (`reason`) and `Shell::start`.
- `scripts/mb-base.ts` (`scripts/check.sh`) allows imports only of its own packages, `mbui/effect` and MoonBit's core, and no line under `src/` naming `still.fail` or application words (`member`, `conversation`, `im`). Legacy exceptions in `NAMED` (`sf_shell_start`, …) only shrink: never add a name chosen here; ask the owner before adding an external symbol. The script counts what is there, so that the table only falls is this file's rule: a count is raised or entry added only by the change that needs it, saying what removes it.
- The station's MoonBit programs keep their own host binding (`station/mb/src/host`) until moved whole: they take the shell-free packages (`src/hash`, `src/net`), never `src/shell`, whose `shell.c` binds C symbols that `station/mb/src/host/host.c` binds too.
- Every suberror here shows as words for people (`impl Show`, own or derived), never package path and constructor: `scripts/mb-base.ts` refuses one that does not.

## What is checked here, and what is not

- On commit/push and in CI (`check-linux`): `scripts/mb-base.ts`, `scripts/mb-base-words.ts --check` (`src/mesh/words_made.mbt` against `client/core-ts/src/lang.{zh,en}.json` `core-logic.mesh.*`) and `scripts/mb-base-sse.ts --check` (`src/wire/sse_made_test.mbt` byte for byte against `client/core-ts/src/sse.ts`). Edit sources and run the generators; never hand-edit `words_made.mbt` or `sse_made_test.mbt`.
- In CI and full checks every package under `src/` is checked and tested on `native` and `js` with `Shell::stood_in` (`src/mesh/stood_wbtest.mbt`, whose head says how a test scripts its peer) on the test's clock. A native test reaching the shell's C (`Shell::start`, `random`, `now`) fails to link naming `sf_shell_start`; it is not skipped. What depends on which of two fibers goes first in one turn is set up without running, then run at once (`start`, `answered`, `run`): a test that rests after every step never sees a fiber cut before its first. `src/mesh/sim_wbtest.mbt` runs two meshes end to end, a peer taking and serving connections, over a test network (relays, addresses, delays, speeds, outages; its head says what it models).
- No Rust shell or real network in unit tests: `shell.c` builds as a stub; the `extern "js"` iroh glue in `shell_js.mbt` runs in Node against a fake module (`shell_js_wbtest.mbt`: async tests run at once in one process and a page has one shell, so they are one test; the tab claim is tested beside it against a test's Web Locks and BroadcastChannel). Changing `src/shell`, or what `src/mesh` asks of a shell, say which outside suite or environment verified it.

## Working here

- Never run `moon check` or `moon info` on the whole workspace (it rewrites `mbui`'s `.mbti` files). Check and test by package: `moon check --target native src/mesh` (and `--target js`), `moon test --target native src/wire`. Committed `pkg.generated.mbti` files are from `native`.
- A compiler warning is an error or off (`moon.mod`'s `warnings`, as `libs/ui`).
