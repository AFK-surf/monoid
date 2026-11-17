// The page's shell's own turning, in Node, with the page's timers in the test's hands: `setTimeout`, `clearTimeout`
// and `queueMicrotask` are the test's while it runs (put back before anything is asserted), so nothing here waits on
// real time, and the runtime's clock is the test's own. What needs iroh, a page's storage or its IndexedDB is not
// reached: that is held by a page in a browser, outside this repository (AGENTS.md).

///|
#external
priv type Hands

///|
/// The page's timers taken: every timer asked from now on is kept, not set, and every microtask kept, not queued.
extern "js" fn hands_take() -> Hands =
  #|() => {
  #|  const hands = { was: [globalThis.setTimeout, globalThis.clearTimeout, globalThis.queueMicrotask], timers: [], soon: [] };
  #|  globalThis.setTimeout = (turn, ms) => hands.timers.push({ turn, ms });
  #|  globalThis.clearTimeout = () => {};
  #|  globalThis.queueMicrotask = (turn) => void hands.soon.push(turn);
  #|  return hands;
  #|}

///|
extern "js" fn hands_back(hands : Hands) -> Unit =
  #|(hands) => {
  #|  [globalThis.setTimeout, globalThis.clearTimeout, globalThis.queueMicrotask] = hands.was;
  #|}

///|
/// The microtasks kept are run, those they queue too: how many.
extern "js" fn hands_soon(hands : Hands) -> Int =
  #|(hands) => {
  #|  let ran = 0;
  #|  for (let turn = hands.soon.shift(); turn !== undefined; turn = hands.soon.shift(), ran++) turn();
  #|  return ran;
  #|}

///|
/// How many timers were asked so far, and the delay the last was asked with.
extern "js" fn hands_timers(hands : Hands) -> Int =
  #|(hands) => hands.timers.length

///|
extern "js" fn hands_delay(hands : Hands) -> Double =
  #|(hands) => hands.timers[hands.timers.length - 1].ms

///|
/// The last timer asked comes due.
extern "js" fn hands_fire(hands : Hands) -> Unit =
  #|(hands) => hands.timers[hands.timers.length - 1].turn()

///|
test "a wake further off than a browser's timer takes is asked as the most it takes, not as none" {
  let hands = hands_take()
  let made = page_start("t", loader_at(""), (_, _, _, _) => ())
  page_wake(made, 1000.0, () => ())
  let near = hands_delay(hands)
  // 2^31 ms: a browser's setTimeout takes it for 0, and what waits for it runs at once, again and again
  page_wake(made, 2147483648.0, () => ())
  let far = hands_delay(hands)
  page_wake(made, 3.0e12, () => ())
  let further = hands_delay(hands)
  page_wake(made, -1.0, () => ())
  let asked = hands_timers(hands)
  hands_back(hands)
  assert_eq(near, 1000.0)
  assert_eq(far, 2147483647.0)
  assert_eq(further, 2147483647.0)
  // (a negative one asks none)
  assert_eq(asked, 3)
}

///|
test "a timer that comes before its time asks again for what is left, by the runtime's clock, and wakes nothing early" {
  let hands = hands_take()
  let clock = Ref(1_000L)
  let rt = @effect.Runtime::live(() => clock.val)
  ignore(Shell::start(rt, "t", iroh=""))
  let woke = Ref(false)
  ignore(
    rt.fork(() => {
      @effect.sleep(5_000)
      woke.val = true
    }),
  )
  // The fork asked a turn; the turn ran the fiber to its sleep and asked the page's timer for it.
  let turns = hands_soon(hands)
  let first = (hands_timers(hands), hands_delay(hands))
  // The timer comes with the clock where it was (as one cut to the most a browser takes does): nothing is due.
  hands_fire(hands)
  ignore(hands_soon(hands))
  let early = (hands_timers(hands), hands_delay(hands), woke.val)
  // And 2 s on, still early: asked for the 3 s left.
  clock.val = 3_000L
  hands_fire(hands)
  ignore(hands_soon(hands))
  let later = (hands_timers(hands), hands_delay(hands), woke.val)
  // At its time the fiber wakes, and no timer is asked after: the runtime has none.
  clock.val = 6_000L
  hands_fire(hands)
  ignore(hands_soon(hands))
  let due = (hands_timers(hands), woke.val)
  hands_back(hands)
  assert_eq(turns, 1)
  assert_eq(first, (1, 5000.0))
  assert_eq(early, (2, 5000.0, false))
  assert_eq(later, (3, 3000.0, false))
  assert_eq(due, (3, true))
}

// iroh given (`Shell::start_with`): a module of the test's, in Node, every promise of it a microtask's, so all a
// call sets going is over by the next of Node's turns (`settled`), the runtime's clock the test's and no timer set.

///|
#external
priv type Fake

///|
/// A module of iroh's that answers at once: an endpoint `ep`, a dial to `"nowhere"` that waits till given up, a
/// connection whose streams echo what is written, all that is done to them told in `fake.log`.
extern "js" fn fake_make() -> Fake =
  #|() => {
  #|  const fake = { log: [], loads: 0 };
  #|  const stream = () => {
  #|    const came = [];
  #|    let finished = false;
  #|    return {
  #|      write: async (b) => { came.push(Uint8Array.from(b)); },
  #|      finish: async () => { finished = true; },
  #|      read: async () => came.length > 0 ? came.shift() : finished ? null : new Promise(() => {}),
  #|      reset: async (code) => { fake.log.push("reset " + code); },
  #|      stopped: async () => null,
  #|    };
  #|  };
  #|  const conn = {
  #|    openBi: async () => stream(),
  #|    acceptBi: () => new Promise(() => {}),
  #|    closedInfo: () => new Promise(() => {}),
  #|    close: (code, reason) => { fake.log.push("conn.close " + code + " " + reason); },
  #|    closeReason: () => null,
  #|    paths: () => [{ relay: "r1", rtt: 20 }],
  #|    stats: () => ({ rxBytes: 1, txBytes: 2 }),
  #|  };
  #|  const endpoint = {
  #|    id: () => "ep",
  #|    relayStatus: () => "connected",
  #|    addAddr: (addr) => { fake.log.push("addAddr " + JSON.stringify(addr)); },
  #|    connect: (addr, alpn, _, givenUp) => addr === "nowhere"
  #|      ? new Promise((_, fail) => givenUp.then(() => { fake.log.push("dropped"); fail(new Error("dropped")); }))
  #|      : Promise.resolve(conn),
  #|    setRelayEntries: async () => {},
  #|    networkChange: async () => {},
  #|    close: async () => { fake.log.push("iroh.close"); },
  #|  };
  #|  fake.module = { bind: async ({ secretKey, relayUrls }) => { fake.log.push("bind " + secretKey.length + " " + relayUrls.join(",")); return endpoint; } };
  #|  return fake;
  #|}

///|
/// The fake module as given itself.
extern "js" fn fake_module(fake : Fake) -> IrohJs =
  #|(fake) => fake.module

///|
/// What loads the fake module: its first load fails, each after gives it.
extern "js" fn fake_loader(fake : Fake) -> IrohJs =
  #|(fake) => () => (++fake.loads === 1 ? Promise.reject(new Error("the wasm did not load")) : Promise.resolve(fake.module))

///|
extern "js" fn fake_loads(fake : Fake) -> Int =
  #|(fake) => fake.loads

///|
extern "js" fn fake_log(fake : Fake) -> FixedArray[String] =
  #|(fake) => fake.log.slice()

///|
/// Takes away the page's localStorage (as in a worker) where Node has one, giving back what puts it back.
extern "js" fn no_local_storage() -> () -> Unit =
  #|() => {
  #|  const was = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  #|  if (was !== undefined) Object.defineProperty(globalThis, "localStorage", { value: undefined, configurable: true, writable: true });
  #|  return () => { if (was !== undefined) Object.defineProperty(globalThis, "localStorage", was); };
  #|}

///|
/// Node's next turn: every microtask queued till then has run.
async fn settled() -> Unit {
  @async.sleep(0)
}

///|
/// What `f` gives or fails with, run as a fiber of `rt` and settled.
async fn on_page(rt : @effect.Runtime, f : async () -> String) -> String {
  let got = Ref("(not done)")
  ignore(
    rt.fork(() => {
      got.val = f() catch {
        ShellError(e) => "failed: " + e
        e => "failed: \{e}"
      }
    }),
  )
  settled()
  settled()
  got.val
}

///|
fn handle(answer : Answer) -> Int64 {
  guard answer.json is { "id": Number(n, ..), .. } else { abort("no handle: \{answer.json.stringify()}") }
  n.to_int64()
}

///|
/// What is asked at once, or what it failed with.
fn asked_or(f : () -> Json raise ShellError) -> Result[Json, String] {
  Ok(f()) catch {
    ShellError(e) => Err(e)
  }
}

///|
fn id_of(n : Int64) -> Json {
  Json::number(n.to_double())
}

///|
/// iroh given as what loads it: loaded as the first endpoint is bound, again after a load that failed, and its
/// handles let go of.
async fn given_a_loader() -> Unit raise {
  let fake = fake_make()
  let rt = @effect.Runtime::live(() => 1_000L)
  let shell = Shell::start_with(rt, fake_loader(fake))
  // Nothing is loaded before an endpoint is asked for.
  let before = fake_loads(fake)
  let first = on_page(rt, () => {
    ignore(shell.call("iroh.bind", { "relayUrls": ["https://r1"] }, bytes=b"0123"))
    "bound"
  })
  let ep = Ref(0L)
  let second = on_page(rt, () => {
    ep.val = handle(shell.call("iroh.bind", { "relayUrls": ["https://r1"] }, bytes=b"0123"))
    "bound"
  })
  let third = on_page(rt, () => {
    ignore(shell.call("iroh.bind", { "relayUrls": [] }, bytes=b"0123"))
    "bound"
  })
  let loads = fake_loads(fake)
  let id = shell.ask("iroh.endpointId", { "id": id_of(ep.val) })
  let status = shell.ask("iroh.relayStatus", { "id": id_of(ep.val) })
  ignore(shell.ask("iroh.addAddr", { "id": id_of(ep.val), "addr": { "id": "peer" } }))
  // A dial under way given up is answered "cancelled", what it had begun dropped.
  let dial = Ref(0L)
  let cancelled = Ref("(not done)")
  ignore(
    rt.fork(() => {
      cancelled.val = {
        ignore(shell.call("iroh.connect", { "id": id_of(ep.val), "addr": "nowhere" }, bytes=b"alpn", called=id => dial.val = id))
        "connected"
      } catch {
        ShellError(e) => e
        e => "\{e}"
      }
    }),
  )
  settled()
  shell.give_up(dial.val)
  settled()
  settled()
  // A connection, a stream on it written, finished and read to its end: let go of then.
  let conn = Ref(0L)
  let s = Ref(0L)
  let echoed = on_page(rt, () => {
    conn.val = handle(shell.call("iroh.connect", { "id": id_of(ep.val), "addr": "peer" }, bytes=b"alpn"))
    s.val = handle(shell.call("conn.openBi", { "id": id_of(conn.val) }))
    ignore(shell.call("istream.write", { "id": id_of(s.val) }, bytes=b"hi"))
    ignore(shell.call("istream.finish", { "id": id_of(s.val) }))
    let came = shell.call("istream.read", { "id": id_of(s.val) })
    let end = shell.call("istream.read", { "id": id_of(s.val) })
    "\{came.bytes.unwrap_or(b"").length()} \{end.json.stringify()}"
  })
  let read_after_end = on_page(rt, () => {
    ignore(shell.call("istream.read", { "id": id_of(s.val) }))
    "read"
  })
  let paths = shell.ask("conn.paths", { "id": id_of(conn.val) })
  let stats = shell.ask("conn.stats", { "id": id_of(conn.val) })
  // A stream left open, then its connection closed with `forget`: both let go of.
  let open = Ref(0L)
  let forgot = on_page(rt, () => {
    open.val = handle(shell.call("conn.openBi", { "id": id_of(conn.val) }))
    ignore(shell.call("conn.close", { "id": id_of(conn.val), "code": 0, "reason": "done", "forget": true }))
    "closed"
  })
  let conn_after = asked_or(() => shell.ask("conn.paths", { "id": id_of(conn.val) }))
  let stream_after = on_page(rt, () => {
    ignore(shell.call("istream.write", { "id": id_of(open.val) }, bytes=b"x"))
    "written"
  })
  // An endpoint closed lets go of its connections and their streams with it.
  let conn2 = Ref(0L)
  let closed = on_page(rt, () => {
    conn2.val = handle(shell.call("iroh.connect", { "id": id_of(ep.val), "addr": "peer" }, bytes=b"alpn"))
    ignore(shell.call("iroh.close", { "id": id_of(ep.val), "forget": true }))
    "closed"
  })
  let ep_after = asked_or(() => shell.ask("iroh.endpointId", { "id": id_of(ep.val) }))
  let conn2_after = asked_or(() => shell.ask("conn.stats", { "id": id_of(conn2.val) }))
  assert_eq(before, 0)
  assert_eq(first, "failed: the wasm did not load")
  assert_eq(second, "bound")
  assert_eq(third, "bound")
  assert_eq(loads, 2)
  assert_eq(id, Json::string("ep"))
  assert_eq(status, Json::string("connected"))
  assert_eq(cancelled.val, "cancelled")
  assert_eq(echoed, "2 {\"end\":true}")
  assert_eq(read_after_end, "failed: not a stream")
  assert_eq(paths, [{ "relay": "r1", "rtt": 20 }])
  assert_eq(stats, { "rxBytes": 1, "txBytes": 2 })
  assert_eq(forgot, "closed")
  assert_eq(conn_after, Err("conn.paths: not its handle"))
  assert_eq(stream_after, "failed: not a stream")
  assert_eq(closed, "closed")
  assert_eq(ep_after, Err("iroh.endpointId: not its handle"))
  assert_eq(conn2_after, Err("conn.stats: not its handle"))
  assert_eq(Array::from_fixed_array(fake_log(fake)), [
    "bind 4 https://r1", "bind 4 ", "addAddr {\"id\":\"peer\"}", "dropped", "conn.close 0 done",
    "iroh.close",
  ])
}

///|
/// iroh given as the module itself, in a worker: bound with no load, and storage failing as the shell's words.
async fn given_the_module() -> Unit raise {
  let fake = fake_make()
  let put_back = no_local_storage()
  let rt = @effect.Runtime::live(() => 1_000L)
  let shell = Shell::start_with(rt, fake_module(fake))
  let bound = on_page(rt, () => {
    let ep = handle(shell.call("iroh.bind", { "relayUrls": ["https://r2"] }, bytes=b"k"))
    shell.ask("iroh.endpointId", { "id": id_of(ep) }).stringify()
  })
  let got = on_page(rt, () => {
    ignore(shell.call("storage.get", { "key": "device" }))
    "got"
  })
  let set = on_page(rt, () => {
    ignore(shell.call("storage.set", { "key": "device" }, bytes=b"k"))
    "set"
  })
  put_back()
  assert_eq(bound, "\"ep\"")
  assert_eq(fake_loads(fake), 0)
  assert_eq(got, "failed: no localStorage here")
  assert_eq(set, "failed: no localStorage here")
  assert_eq(Array::from_fixed_array(fake_log(fake)), ["bind 1 https://r2"])
}

///|
/// What `op` is answered on the page: its JSON, and its bytes as text where it carries any; or what it failed with.
async fn page_said(rt : @effect.Runtime, shell : Shell, op : String, args : Json, bytes? : Bytes) -> String {
  on_page(rt, () => {
    let answer = shell.call(op, args, bytes?)
    match answer.bytes {
      Some(b) => "\{answer.json.stringify()} \{@utf8.decode(b)}"
      None => answer.json.stringify()
    }
  })
}

///|
/// Keys and their bytes (`idb.*`) where there is no IndexedDB (Node): kept in the page's own map, read back, deleted
/// one by one and by a prefix, and scanned in order, from a prefix, past a key, a page at a time.
async fn keys_in_memory() -> Unit raise {
  let rt = @effect.Runtime::live(() => 1_000L)
  let shell = Shell::start_with(rt, fake_module(fake_make()))
  let missing = page_said(rt, shell, "idb.get", { "key": "a/1" })
  let puts = []
  for k in ["b/2", "a/2", "a/10", "a/1", "ab", "a"] {
    puts.push(page_said(rt, shell, "idb.put", { "key": Json::string(k) }, bytes=@utf8.encode("v" + k)))
  }
  let got = page_said(rt, shell, "idb.get", { "key": "a/10" })
  let again = page_said(rt, shell, "idb.put", { "key": "a/10" }, bytes=b"w")
  let got_again = page_said(rt, shell, "idb.get", { "key": "a/10" })
  let all = page_said(rt, shell, "idb.scan", {})
  let under = page_said(rt, shell, "idb.scan", { "prefix": "a/" })
  let first_page = page_said(rt, shell, "idb.scan", { "prefix": "a/", "limit": 2 })
  let next_page = page_said(rt, shell, "idb.scan", { "prefix": "a/", "after": "a/10", "limit": 2 })
  let before_prefix = page_said(rt, shell, "idb.scan", { "prefix": "a/", "after": "", "limit": 1 })
  let one_gone = page_said(rt, shell, "idb.delete", { "key": "ab" })
  let prefix_gone = page_said(rt, shell, "idb.delete", { "prefix": "a/" })
  let left = page_said(rt, shell, "idb.scan", {})
  let no_key = page_said(rt, shell, "idb.get", {})
  let item = (k : String, v : String) => "{\"key\":\"\{k}\",\"hex\":\"\{v}\"}"
  assert_eq(missing, "{\"found\":false}")
  assert_eq(puts, ["{}", "{}", "{}", "{}", "{}", "{}"])
  assert_eq(got, "{\"found\":true} va/10")
  assert_eq((again, got_again), ("{}", "{\"found\":true} w"))
  assert_eq(
    all,
    "{\"items\":[\{item("a", "7661")},\{item("a/1", "76612f31")},\{item("a/10", "77")},\{item("a/2", "76612f32")},\{item("ab", "766162")},\{item("b/2", "76622f32")}],\"more\":false}",
  )
  assert_eq(under, "{\"items\":[\{item("a/1", "76612f31")},\{item("a/10", "77")},\{item("a/2", "76612f32")}],\"more\":false}")
  assert_eq(first_page, "{\"items\":[\{item("a/1", "76612f31")},\{item("a/10", "77")}],\"more\":true}")
  assert_eq(next_page, "{\"items\":[\{item("a/2", "76612f32")}],\"more\":false}")
  assert_eq(before_prefix, "{\"items\":[\{item("a/1", "76612f31")}],\"more\":true}")
  assert_eq((one_gone, prefix_gone), ("{}", "{}"))
  assert_eq(left, "{\"items\":[\{item("a", "7661")},\{item("b/2", "76622f32")}],\"more\":false}")
  assert_eq(no_key, "failed: no key")
}

///|
/// (one test, these one after the other: a page has one shell, and Node runs async tests at once)
async test "iroh given: as what loads it, then as the module itself in a worker; keys kept where there is no IndexedDB" {
  given_a_loader()
  given_the_module()
  keys_in_memory()
}
