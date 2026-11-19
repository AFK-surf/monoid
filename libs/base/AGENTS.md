# Working in the base (for agents)

The first of the base in MoonBit: what a client's core stands on where the core is MoonBit, written once and shared
(the user, 2026-11-14: still.fail's own core is to move to MoonBit, 「以后 still fail 也会切 mb」, and a module is
written once for both sides, 「这样两边共用」). A moon module of its own, `base`, which takes mbui's `effect` as a member
of its workspace (`moon.work`); `effect` stays in mbui.

## Its parts

- `src/shell`: the binding of the Rust shell (`client/shell`, through its C interface) for a program on `@effect`:
  `shell.mbt` is the surface, shared across `shell_native.mbt` (with `shell.c`), `shell_js.mbt` (with `client/iroh-wasm`
  and browser APIs), and `Shell::stood_in` for deterministic tests. Natively a process whose host started the Rust
  shell already shares it (`bsh_attach`, `Shell::attached`): this side's call ids start past 2^40, and the host hands
  each answer of such an id to `bsh_deliver`. A program whose own loop runs its thread (a window's) never calls `run`,
  which waits: it gives `bsh_on_wake` what brings that loop round as an answer is queued (called on the shell's
  thread, and at once where answers wait already), and at each round calls `Shell::turn`, which takes what is in and
  runs the runtime until nothing is ready, never waiting, and says when its next timer is due. On js iroh is loaded from an address (`Shell::start`) or given, the
  module or what loads it (`Shell::start_with`, `IrohJs`); a worker has no localStorage, so `storage.*` fails there.
  A page keeps keys and their bytes past localStorage's few MB in IndexedDB (`idb.*`, `shell_js.mbt`'s head), in a map
  of its own where there is none (Node): no other shell has those ops. A page's HTTP (`fetch`, `stream.open`,
  `stream.read`, `stream.close`, given up by `fetch.cancel`) is its `fetch`, with the Rust shell's JSON and bytes; no
  `entry` there, and a body read to its end lets go of its handle. A program whose core must run in one tab of
  a browser at a time asks for a tab's claim (`claim_tab`, `tab.mbt`): on a page a Web Lock of its name, taken over
  on a BroadcastChannel of the same (`TabClaim::take_over`: the tab holding it is told `Yielded` before it lets go);
  natively, and on a page without either, `Held` at once. What a tab does as it yields is its program's.
- `src/sql`: a database in the shell (SQLite), asked synchronously (`sql.*`, `Shell::ask`): `Sql` (open, attach, exec,
  run, all, close), `Burst` (one writer's transaction, `BEGIN IMMEDIATE` at its first write and committed once; none
  run where nothing was written; `in_tx` rolls back what raised), `query_in_chunks` (many keys in one statement per
  `chunk_most`, each asked once, none for none) and the column readers (`col_*`). The schema is its program's.
- `src/scheduler`: one lane of requests to a peer, the most urgent first (the device base in TypeScript's
  `client/core-ts/src/sync/scheduler.ts`, one `Scheduler` a lane): the urgent in `width` and `urgent_room` more, the
  shown in `width`, the background one at a time behind them and any request in sight (`foreground_begin`), the idle
  alone and told to give way (`Preempt`, while it is idle as raised) as a request in sight or anything above the
  background is asked; the background waits for an idle step to end. A task runs in the fiber that asks
  (`Scheduler::run`); interrupted waiting or running, a `defer` lets its place or slot go.
- `src/wire`: pure stream framing and event-stream parsing (`lines`, request/reply heads, SSE text) with no transport.
- `src/mesh`: the device side of the mesh on top of `shell` and `wire` (endpoints, scoped peer links,
  hello/pings/renewal, requests/streams/duplex, health racing in `health.mbt`, wake/rebind in `wake.mbt`, what the
  endpoint is bound with, relays told again and connections peers dial to it or it dials itself in `bind.mbt`, where
  peers are dialled straight in `addrs.mbt`, a connection dialled once on a protocol of its program's in
  `dial_once.mbt`, the ways to a place and the choice among them in `ways.mbt`, with `sha256.mbt` (a program's to call
  too) for the keys of relays' own endpoints, ways' speeds and the day's tally in `speed.mbt`, what it tells of itself
  in `trace.mbt`, and a program's other asks in `hooks.mbt`, with Ed25519 and SHA-512 in `sign.mbt`).

## It knows no program

- Not still.fail's app, station or cloud, and not any specific application. Everything program-specific is passed in via
  `Options` (`Binding`: lookup, protocols taken, relay entries the program worked out), `Mesh::link` (`scope`),
  `Mesh::drop_link` (`reason`), and `Shell::start`.
- `scripts/mb-base.ts` (`scripts/check.sh`) enforces that packages import only their own packages, `mbui/effect`, and
  MoonBit's core, and that no line under `src/` names `still.fail` or application-specific vocabulary (`member`,
  `conversation`, `im`). Legacy exceptions in `NAMED` (`sf_shell_start`, etc.) may only shrink; never add a name chosen
  by this library, and ask the owner before adding any external symbol. The script counts what is there, not what
  was, so that the table only falls is this file's rule: a count is raised or an entry added only in the change that
  needs it, its entry saying what takes it away.
- The station's MoonBit programs keep their own host binding (`station/mb/src/host`) until moved onto this base whole.

## What is checked here, and what is not

- On commit/push and in CI (`check-linux`): `scripts/mb-base.ts`, `scripts/mb-base-words.ts --check` (verifying
  `src/mesh/words_made.mbt` against `client/core-ts/src/lang.{zh,en}.json` `core-logic.mesh.*`), and
  `scripts/mb-base-sse.ts --check` (verifying `src/wire/sse_made_test.mbt` matches `client/core-ts/src/sse.ts` byte for
  byte). Edit the source files and run the generator scripts; never hand-edit `words_made.mbt` or `sse_made_test.mbt`.
- In CI and full checks: every package under `src/` is type-checked and tested on both `native` and `js` targets using
  `Shell::stood_in` (`src/mesh/stood_wbtest.mbt`, whose head says how a test scripts its peer) on the test's
  deterministic clock. A native test that reaches the shell's C (`Shell::start`, the package's `random` and `now`)
  fails to link, naming `sf_shell_start`: it is not skipped. What depends on which of two fibers comes first in one
  turn is set up without running and then run at once (its `start`, `answered`, `run`): a test that runs to rest
  after every step never sees a fiber cut before its first. `src/mesh/sim_wbtest.mbt` runs two meshes end to end, a
  peer's taking connections and serving them, over a network of the test's (relays and addresses, each with its
  delay, speed and outages), whose head says what it models.
- No Rust shell or real network is linked in unit tests (`shell.c` is compiled as a stub only, and the `extern "js"`
  iroh glue in `shell_js.mbt` runs in Node against a fake module alone, `shell_js_wbtest.mbt`: its async tests run at
  once in one process, and a page has one shell, so they are one test; a tab's claim, which reaches no shell, is
  tested beside it against Web Locks and a BroadcastChannel of the test's). When changing `src/shell` or what `src/mesh`
  asks of a shell, state what external suite or environment verified it.

## What a program on it gets with it

- A peer's bytes are kept up to a bound, the caller's to say: a reply read whole (`Reply::rest`, `max_body`) and one
  block of an event stream (`Sse::new`, `max_event`), 16 MiB each unless said, past which each fails (`too_long`,
  `TooLong`). What is longer is read as it comes (`Reply::take`, a duplex's reply, `Inbound::take`), keeping none: a
  reader that stops asking holds its peer back by the transport's own window, and a body told of (`Link::request`'s
  `wrote`) has one step of 64 KiB waiting at most. A reply not yet read is handed to the shell to read itself
  (`Reply::tap`, `istream.tap`) with what was read past its head; where the shell does not take it, that is kept
  and the reply read as ever.
- A connection a peer dials to the endpoint (`Mesh::incoming`, only where `Binding.takes` names a protocol) is never a
  link: no credential, ping or `links` entry knows it. The mesh keeps one the shell brought that no asker took yet;
  its first line is held to `first_ms` (30 s) and 64 KiB (`Incoming::first`). The streams after it, its peer's
  (`Incoming::accept`) and its program's (`Incoming::open`), are waited for in the mesh's fibers as a link's are,
  and are its program's to bound, as are how long a taken one stays and how many at once; while one is open the
  endpoint is not bound anew.
- A connection dialled to a peer on a protocol of its program's (`Mesh::dial_once`, its other way) is no link
  either, and is on an endpoint bound for it alone with a key drawn for it: never the device's (on the relay the
  device's endpoint is on, the same endpoint id puts that one off it), so it proves nothing of the device; that is
  its program's to send on it (`Mesh::sign`). Its connection and that endpoint are closed to be forgotten as it is
  closed, ends, fails to open, is given up or the mesh closes.
- `Mesh::connect` dials on the endpoint itself instead, so the peer's transport proves the device (no relay put off),
  and hands out an `Incoming` kept as one a peer dialled; its dial counts as on the endpoint while it lasts.
- What a peer's hello answer says of its `lan` / `tailnet` addresses (IPv4 `a.b.c.d:port`, 8 of each, as the
  TypeScript mesh's check) is kept by place in the program's `Store` (`Mesh::make`'s `addresses`), unreadable kept
  values taken for none. A dial given them does not wait to be on a relay (`onto_max_ms`), as in that mesh.
  `iroh.addAddr` is an op answered at once (`Shell::ask`): the Rust shell has it only there, never as a call.
- The mesh passes `forget: true` on every last `conn.close` and `iroh.close`: both shells then let go of the
  connection or endpoint whole, its streams with it, so nothing is kept of one the mesh is done with.
- Ways (`ways.mbt`'s head): a place is dialled on the endpoint alone, as before, unless its endpoint's ways are off
  (`off`), direct is held for flakiness, its last dial there went unanswered given the same addresses, or its link
  there died of missed pings; then every way is raced. The numbers are the TypeScript mesh's: change both together.
  A relay endpoint's key is SHA-256 of `pinned_prefix`, the device key and the relay, so the TypeScript prefix gives
  its keys. On purpose unlike it: the endpoint's way, missing where it is on again, is redialled every
  `redial_main_ms` (dead code at `mesh.ts` `#steer`); `relay_only` does not turn the endpoint's ways off; LAN and
  tailnet endpoints get a drawn key. Only the endpoint's own dial says whether it is stuck or its addresses
  unanswered, raced or not (`Mesh::dial_main_raced`); a race and a wake's second dial go by `Mesh::dial_all`.
- Speeds and days (`speed.mbt`) go by the program's wall clock (`Mesh::make`'s `clock`, the runtime's at UTC unless
  given) and are kept under their keys in its `Store`; a speed is noted only from replies its program times
  (`Mesh::timed`) and weighs in a way's `Score.cost`. The day's tally runs only while a link is open.
- Spans and record lines (`trace.mbt`) are the TypeScript mesh's by name and attribute, but the peer's attribute is
  named by `Trace.peer_key` (`"peer"` unless given): this library never says another program's word for it. A record
  line is worked out only while `Recorder.on`; a place is observed (paths, `conn ways`, `dht`) once a tick, by the
  ways' fiber while they are steered, by its link's otherwise.
- `Mesh::sign` asks the shell (`ed25519.sign`, the Rust shell's) and signs in `sign.mbt` only where it cannot (a
  page): that code is TweetNaCl's, not constant-time beyond what it was, and signs nothing it is not given. Its
  check (`double_scalarmult`) is not constant-time at all, being of public bytes alone: never sign with it.
  `Mesh::verify` asks the shell (`crypto.verify`) and checks in `sign.mbt` (`ed25519_verify`) where it cannot, which
  refuses what the Rust shell's libcrux refuses (`S` past the order, a point not written once only): change both
  together.
  `Mesh::migrate` binds the endpoint anew on the key given and lets go of everything on the one before at once.
- The device's key file is its user's alone whatever the umask, by the Rust shell's doing alone
  (`client/shell/src/lib.rs` `create_private`): a program linked to a shell from before keeps its key as its umask has
  it. `shell.c` has been run on macOS on arm64 alone (compiled for Linux, glibc 2.28, too).

## Known, and left

What was known as the library was moved here (2026-11-14) is mended, each with a test that failed before; what is
left is another part's:

- Natively the Rust shell takes every connection dialled to an endpoint that takes a protocol once `iroh.accept` is
  first asked, queueing those nobody asked for with no bound (`client/shell/src/lib.rs`, `Accepted`); the mesh asks
  one at a time. That shell's to bound. A page's shell has no `iroh.accept` (`Mesh::incoming` fails there).
- A write given up lets go of its stream: that is the mesh's intent (`Out::write` resets it), and both shells' only
  once that write moves. `istream.write` holds the sending half while it writes, and `istream.reset` waits for it
  (`client/shell/src/lib.rs`, `client/iroh-wasm/src/lib.rs`): given up because the peer is not reading, the write
  stays, and the reset behind it, until the peer reads, stops the stream or the connection ends. The Rust shell's
  and iroh-wasm's to mend, for the device base in TypeScript too.
- A read that waits as its connection ends can be answered the stream's end by the Rust shell, not a failure (it
  wakes the read as it lets go of the connection's streams). The mesh is told an end and has no length of its own
  to hold a body to, so a reply cut so passes for whole (`requests_wbtest.mbt` scripts it): what a reply's head
  says of its length is its program's to hold it to, until that shell answers a failure there. As in the device
  base in TypeScript.
- On js under Hermes, MoonBit's own `Array` costs the square of its length as it grows: a full one is copied into a
  `new Array(n)` from its last place down, which that engine takes badly (40,000 pushes 0.6 s, 80,000 2.7 s, where
  the engine's own `push` takes 3 and 6 ms; the hermes of React Native 0.81.4, 2026-11-14), and its `StringBuilder`
  and `join` make their string again at each piece. The reader of an event stream keeps one event's lines out of
  both (`sse_js.mbt`); what `Sse::feed` gives is still an `Array`, so a chunk that ends tens of thousands of events
  at once pays it there, as does anything else here that grows one. MoonBit's core's to mend; no program runs
  this library under Hermes.

## Working here

- Never run `moon check` or `moon info` on the whole workspace (which would rewrite `mbui`'s `.mbti` files). Check and
  test by package:
  - `moon check --target native src/mesh` (and `--target js`)
  - `moon test --target native src/wire`
  The committed `pkg.generated.mbti` files are from the `native` target.
- A compiler warning is an error or off (`moon.mod`'s `warnings`, matching `libs/mbui`).
- Fiber interruption and shell lifetimes:
  - `catch` does not catch fiber interruption; cleanup on interruption belongs in `defer`, and `Mesh::close` explicitly
    notifies all pending openings, live links, and waiting dialers before cutting fibers so nothing hangs if cut before
    its first step.
  - Only a dial can be cancelled in the shell (`Shell::give_up`). An interrupted stream read or write leaves the shell
    stream unusable, so interrupted streams must be reset (`Reply::cancel`, `Out::write`), and control-stream exchanges
    (`Mesh::ping`, `Mesh::race`) or stream opens/accepts (`open_on`, `accept_on`: a link's and a taken connection's)
    run in the mesh's own fibers.
  - `Mesh::rebind` only rebinds the endpoint when `Mesh::idle` reports nothing active on it; callers never cache the
    endpoint handle across waits.
  - `Mesh::retune` onto other relays lets go of every link first, as `drop_link` does (peers told the caller's
    reason), then binds once their ends are told; it never closes the endpoint under live links. A failed bind
    leaves the links gone and the old relays kept until a dial finds the endpoint idle. Entries alone
    (`iroh.setRelayEntries`) are told one telling at a time, never rebinding.
  - The wait for `iroh.accept` outlives an endpoint: it is let go of in the step the endpoint changes
    (`Mesh::forget_coming`), and its fiber and asker both check it is still the one kept before taking its answer.
  - After every wait in `ways.mbt` the mesh, the place in `links` and the entry in `pinned` are looked at anew; what a
    dial brings is a way or closed in the step it comes (`Mesh::adopt_way`); `release_pinned` closes nothing while
    `dialing`. A ping not late yet is not counted again (`Mesh::remeasure` pings links their ticks ping too).
  - Native device keys written by the Rust shell are `0600` (`create_private`), and `shell.c` requires POSIX (`pthread`)
    and the system's randomness: `getrandom` on Linux (glibc >= 2.25, so a build for glibc 2.28 links), `arc4random_buf`
    on Apple's systems and the BSDs.
