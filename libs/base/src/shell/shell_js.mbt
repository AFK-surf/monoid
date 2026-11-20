// The shell of a page: the ops the mesh asks of the Rust shell (shell.mbt lists the two), by the same names
// with the same JSON and bytes, done with what a browser has. iroh is iroh for the browser
// (client/iroh-wasm, a module made by wasm-bindgen with its wasm beside it; its calls are those the TypeScript core
// wraps, client/core-ts/src/iroh-bindings.ts), loaded from where the page serves it the first time an endpoint is
// bound, or given (`Shell::start_with`: the module, or what loads it, where a bundle has it already); what is kept
// is kept in the page's localStorage (none in a worker: `storage.*` fails there, and its program keeps its own);
// the clock is the page's, the random bytes its crypto's, HTTP its `fetch`.
//
//   op                 on a page
//   storage.get/set    localStorage, the key `<dir>:<key>`, the value in hex (a file a key natively); where there is
//                      none (a worker), a failure
//   idb.get/put/delete/scan   keys (strings) and their bytes, past localStorage's few MB: the page's IndexedDB,
//                      the database `<dir>:idb` and its store "kv"; where there is none (Node, a worker made
//                      without it), a map of this page's alone, gone with it. `get {key}` answers `{found}` and,
//                      found, the bytes; `put {key}` with the bytes, `{}`; `delete {key}` or `{prefix}`, every key
//                      it starts, `{}`; `scan {prefix?, after?, limit?}` the keys from `prefix` past `after`, in
//                      the order of their UTF-16 code units, `limit` (200 unless said) at most: `{items: [{key,
//                      hex}], more}`. No other shell has them: the Rust shell keeps what it keeps in `sql.*`
//   fetch              `fetch(url, {method, headers, body})` of `{url, method?, headers?}` (`method` GET unless said,
//                      `headers` pairs `[name, value]`, appended in order) and the bytes as its body where any are
//                      given (none where they are empty on a GET or a HEAD, which a browser refuses one): `{status,
//                      headers}` (pairs, as the page's `Headers` gives them) and the body's bytes, read whole. No
//                      `entry` (a host's address given): a page resolves as its browser does
//   stream.open        as `fetch`, its body left to read: `{status, headers, id}`
//   stream.read        the body's next bytes (never none: a piece that came empty is read past), or `{end: true}`,
//                      the handle let go of then (read again, "not a response", where the Rust shell answers the end)
//   stream.close       the body let go of where it was not read to its end (its reader cancelled); of one let go of
//                      already, nothing
//   fetch.cancel       (answered at once) a `fetch` or `stream.open` under way given up: its request aborted, and it
//                      answered "cancelled" as natively; a body being read after `stream.open` is `stream.close`d
//   iroh.bind          the module's `bind({secretKey, relayUrls})`, with `relayEntries` where any are said (each
//                      `{entry, relay}`): through relays alone whatever is asked (a browser has no UDP: `relayOnly`
//                      is always so), nothing looked up (`lookup` never), and no connection taken (`alpns` is not
//                      read: iroh-wasm binds with none)
//   iroh.setRelayEntries   the endpoint's `setRelayEntries(entries)`, each `{entry, relay}`; of one closed, nothing
//   iroh.accept        none: a page takes no connection. Asked, it fails as every op a page has not, which the
//                      mesh says to whoever asked for one (`Mesh::incoming`)
//   iroh.connect       `endpoint.connect(addr, alpn, [], givenUp)`; `fetch.cancel` of its call resolves `givenUp`,
//                      which drops the handshake, and it is answered "cancelled" as natively
//   iroh.endpointId, iroh.relayStatus, iroh.close      the endpoint's `id`, `relayStatus`, `close`
//   iroh.networkChange the endpoint's `networkChange` (its relay connection looked at anew); of one closed, nothing
//   conn.openBi, conn.close, conn.closed, conn.closeReason, conn.paths, conn.stats
//                      the connection's `openBi`, `close(code, reason)`, `closedInfo`, `closeReason`, `paths` (each
//                      path a relay's: no `ip`), `stats` (`{rxBytes, txBytes}` alone of what the Rust shell says,
//                      and of a connection not ended alone: one that ended is "not its handle", which the mesh
//                      takes as nothing more having come)
//   conn.acceptBi      the connection's `acceptBi`: the next stream its peer opens, a handle as one opened here; of
//                      a connection that ended, or ends meanwhile, `{end: true}`, never a failure
//   istream.read/write/finish/reset                    the stream's own; a read answers its end as `{end: true}`
//   istream.stopped    the stream's `stopped`: `{code}`, what its peer stopped it with, else null: once what was
//                      written is taken, and of a stream reset here. iroh-wasm says null of a failure too, so
//                      where it does and the stream's connection has ended this fails, as the Rust shell does;
//                      a failure with its connection up cannot be told from null
//
// A handle is a number, as the Rust shell's (`{"id": n}`), and a page lives long: each is let go of, none kept for
// the page's life.
//   a stream       once reset, or read to its end and finished; and with its connection, as that ends (its control
//                  stream, which is neither; a reply's left unread): as the Rust shell lets a connection's go;
//   a connection   kept as why it ended once it has (asked after, it answers that), until it is closed with
//                  `forget` (`conn.close {id, forget: true}`: the mesh's, once it was told the end and keeps why
//                  itself, or at once of one an opening gave up, ended or not) or its endpoint closes, as the Rust
//                  shell lets one go;
//   an endpoint    as it is closed, with every connection of it and their streams. Nothing is answered of it after.
// As natively, a wait given up is not a call given up but for a dial: a read let go of goes on (iroh-wasm's `read`
// holds the stream's receiving half), so a stream is not read again after that, but reset.
//
// There is no loop to pump from: every answer is an event of the page's (a promise's), given to its fiber and then
// followed by a turn of the runtime, and so is a timer of the runtime's come due (`Shell::start`).

///|
/// The page's side, made once (`page_start`): the handles, iroh's module once loaded, the one timer.
#external
priv type Page

///|
/// iroh for the browser as its program gives it (`Shell::start_with`): the module itself, initialized (what has
/// `bind`), or a function that gives it or a promise of it (`() => init().then(() => iroh)`), called the first time
/// an endpoint is bound, and again at the next where what it gave failed.
#external
pub type IrohJs

///|
/// How the page's shell gets iroh's module: a function giving a promise of it, called as an endpoint is bound
/// until one it gave came.
#external
priv type Loader

///|
/// The module at `at` (iroh-wasm's JavaScript, its wasm beside it), loaded and initialized.
extern "js" fn loader_at(at : String) -> Loader =
  #|(at) => () => import(at).then((module) => module.default().then(() => module))

///|
/// The module given, or what the function given gives (asked once a promise of it is wanted, not before).
extern "js" fn loader_of(iroh : IrohJs) -> Loader =
  #|(given) => typeof given === "function" ? () => Promise.resolve().then(() => given()) : () => Promise.resolve(given)

///|
/// `answered(id, kind, text, bytes)` is called as a call is answered (`Shell::settle`'s kinds), never while it is
/// asked.
extern "js" fn page_start(prefix : String, loader : Loader, answered : (Int, Int, String, Bytes) -> Unit) -> Page =
  #|(prefix, loader, answered) => {
  #|  const none = new Uint8Array(0);
  #|  // by handle: {endpoint}; {conn, of: its endpoint, closed: why it ended, once it has} or, ended, {gone: why, of};
  #|  // {stream, on: its connection, finished, ended}
  #|  const handles = new Map();
  #|  let last = 0;
  #|  const keep = (handle) => (handles.set(++last, handle), last);
  #|  // a connection's streams let go of (as it ends, or is let go of itself)
  #|  const streamsGo = (conn) => {
  #|    for (const [id, h] of handles) if (h.on === conn) handles.delete(id);
  #|  };
  #|  // by the call of a dial or a request under way: what gives it up
  #|  const dials = new Map();
  #|  let iroh = null;
  #|  const load = () => (iroh ??= loader().catch((e) => { iroh = null; throw e; }));
  #|  const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  #|  const unhex = (text) => Uint8Array.from(text.match(/../g) ?? [], (b) => Number.parseInt(b, 16));
  #|  const connection = (h) => {
  #|    if (h?.gone !== undefined) throw new Error("connection closed: " + (h.gone.reason ?? ""));
  #|    if (h?.conn === undefined) throw new Error("not a connection");
  #|    return h.conn;
  #|  };
  #|  // (a worker has no localStorage: its program keeps what it keeps itself)
  #|  const storage = () => {
  #|    if (typeof localStorage === "undefined") throw new Error("no localStorage here");
  #|    return localStorage;
  #|  };
  #|  // the page's IndexedDB, opened as first asked (again after a failure); none: a map of the page's alone
  #|  let db = null;
  #|  const memory = typeof indexedDB === "undefined" ? new Map() : null;
  #|  const done = (r) => new Promise((ok, fail) => { r.onsuccess = () => ok(r.result); r.onerror = () => fail(r.error); });
  #|  const store = (mode) => (db ??= new Promise((ok, fail) => {
  #|    const r = indexedDB.open(prefix + ":idb", 1);
  #|    r.onupgradeneeded = () => r.result.createObjectStore("kv");
  #|    r.onsuccess = () => ok(r.result);
  #|    r.onerror = () => fail(r.error);
  #|  }).catch((e) => { db = null; throw e; })).then((d) => d.transaction("kv", mode).objectStore("kv"));
  #|  const committed = (s) => new Promise((ok, fail) => {
  #|    s.transaction.oncomplete = () => ok();
  #|    s.transaction.onerror = s.transaction.onabort = () => fail(s.transaction.error ?? new Error("aborted"));
  #|  });
  #|  const key = (a) => {
  #|    if (typeof a.key !== "string") throw new Error("no key");
  #|    return a.key;
  #|  };
  #|  // the keys from `from` on (past it where `past`), in order, each with its value, while `f` takes them
  #|  const walk = async (from, past, f) => {
  #|    if (memory !== null) {
  #|      for (const k of [...memory.keys()].sort()) {
  #|        if (k < from || (past && k === from)) continue;
  #|        if (!f(k, memory.get(k))) break;
  #|      }
  #|      return;
  #|    }
  #|    const s = await store("readonly");
  #|    await new Promise((ok, fail) => {
  #|      const r = s.openCursor(IDBKeyRange.lowerBound(from, past));
  #|      r.onerror = () => fail(r.error);
  #|      r.onsuccess = () => {
  #|        const c = r.result;
  #|        if (c === null || typeof c.key !== "string" || !f(c.key, c.value)) ok();
  #|        else c.continue();
  #|      };
  #|    });
  #|  };
  #|  const idb = async (op, a, bytes) => {
  #|    switch (op) {
  #|      case "idb.get": {
  #|        const k = key(a);
  #|        const v = memory !== null ? memory.get(k) : await done((await store("readonly")).get(k));
  #|        return v === undefined ? [{ found: false }] : [{ found: true }, v];
  #|      }
  #|      case "idb.put": {
  #|        const k = key(a);
  #|        const v = Uint8Array.from(bytes ?? none);
  #|        if (memory !== null) memory.set(k, v);
  #|        else {
  #|          const s = await store("readwrite");
  #|          s.put(v, k);
  #|          await committed(s);
  #|        }
  #|        return [{}];
  #|      }
  #|      case "idb.delete": {
  #|        const gone = [];
  #|        if (typeof a.prefix === "string") await walk(a.prefix, false, (k) => k.startsWith(a.prefix) && gone.push(k) > 0);
  #|        else gone.push(key(a));
  #|        if (memory !== null) for (const k of gone) memory.delete(k);
  #|        else if (gone.length > 0) {
  #|          const s = await store("readwrite");
  #|          for (const k of gone) s.delete(k);
  #|          await committed(s);
  #|        }
  #|        return [{}];
  #|      }
  #|      default: {
  #|        // idb.scan
  #|        const p = typeof a.prefix === "string" ? a.prefix : "";
  #|        const after = typeof a.after === "string" ? a.after : null;
  #|        const limit = Number.isInteger(a.limit) && a.limit > 0 ? a.limit : 200;
  #|        const past = after !== null && after >= p;
  #|        const items = [];
  #|        let more = false;
  #|        await walk(past ? after : p, past, (k, v) => {
  #|          if (!k.startsWith(p)) return false;
  #|          if (items.length === limit) return !(more = true);
  #|          items.push({ key: k, hex: hex(v) });
  #|          return true;
  #|        });
  #|        return [{ items, more }];
  #|      }
  #|    }
  #|  };
  #|  const stream = (h) => {
  #|    if (h?.stream === undefined) throw new Error("not a stream");
  #|    return h.stream;
  #|  };
  #|  // `a` asked of the page's fetch as call `id`, given up by `fetch.cancel` until `then` is done with its response
  #|  const request = async (id, a, bytes, then) => {
  #|    if (typeof a.url !== "string") throw new Error("no url");
  #|    if (typeof fetch !== "function") throw new Error("no fetch here");
  #|    const method = typeof a.method === "string" ? a.method : "GET";
  #|    const headers = new Headers();
  #|    for (const pair of Array.isArray(a.headers) ? a.headers : []) {
  #|      if (typeof pair?.[0] === "string" && typeof pair?.[1] === "string") headers.append(pair[0], pair[1]);
  #|    }
  #|    const body = bytes !== null && (bytes.length > 0 || (method !== "GET" && method !== "HEAD")) ? bytes : undefined;
  #|    const abort = new AbortController();
  #|    let gave = false;
  #|    dials.set(id, () => { gave = true; abort.abort(); });
  #|    try {
  #|      const response = await fetch(a.url, { method, headers, body, signal: abort.signal });
  #|      return await then(response, { status: response.status, headers: [...response.headers.entries()] });
  #|    } catch (e) {
  #|      throw gave ? new Error("cancelled") : e;
  #|    } finally {
  #|      dials.delete(id);
  #|    }
  #|  };
  #|  // what a call is answered later: [its JSON] or [its JSON, its bytes]
  #|  const run = async (id, op, a, bytes) => {
  #|    const h = handles.get(a.id);
  #|    switch (op) {
  #|      case "storage.get": {
  #|        const kept = storage().getItem(prefix + ":" + a.key);
  #|        return kept === null ? [{ none: true }] : [{}, unhex(kept)];
  #|      }
  #|      case "storage.set":
  #|        storage().setItem(prefix + ":" + a.key, hex(bytes ?? none));
  #|        return [{}];
  #|      case "idb.get":
  #|      case "idb.put":
  #|      case "idb.delete":
  #|      case "idb.scan":
  #|        return idb(op, a, bytes);
  #|      case "iroh.bind": {
  #|        const module = await load();
  #|        return [{ id: keep({ endpoint: await module.bind({ secretKey: bytes ?? none, relayUrls: a.relayUrls ?? [], ...(a.relayEntries ? { relayEntries: a.relayEntries } : {}) }) }) }];
  #|      }
  #|      case "iroh.connect": {
  #|        if (h?.endpoint === undefined) throw new Error("not an endpoint");
  #|        let giveUp = () => {};
  #|        let gave = false;
  #|        const given = new Promise((resolve) => (giveUp = resolve));
  #|        dials.set(id, () => { gave = true; giveUp(); });
  #|        try {
  #|          const conn = await h.endpoint.connect(a.addr, bytes ?? none, [], given);
  #|          // (its endpoint closed meanwhile: nothing would let go of a connection kept now)
  #|          if (handles.get(a.id) !== h) {
  #|            conn.close(0, "closed");
  #|            throw new Error("the endpoint is closed");
  #|          }
  #|          const entry = { conn, of: a.id, closed: conn.closedInfo().catch((e) => ({ kind: "other", reason: said(e) })) };
  #|          const kept = keep(entry);
  #|          // Ended, however it did: its streams go, and what is kept of it is why (unless it was let go of first).
  #|          entry.closed.then((why) => {
  #|            if (handles.get(kept) !== entry) return;
  #|            handles.set(kept, { gone: why, of: a.id });
  #|            streamsGo(kept);
  #|          });
  #|          return [{ id: kept }];
  #|        } catch (e) {
  #|          throw gave ? new Error("cancelled") : e;
  #|        } finally {
  #|          dials.delete(id);
  #|        }
  #|      }
  #|      case "iroh.setRelayEntries":
  #|        if (h?.endpoint !== undefined) await h.endpoint.setRelayEntries(a.entries ?? []);
  #|        return [{}];
  #|      case "iroh.networkChange":
  #|        if (h?.endpoint !== undefined) await h.endpoint.networkChange();
  #|        return [{}];
  #|      case "iroh.close":
  #|        if (h?.endpoint !== undefined) {
  #|          // let go of with all that was its: its connections, ended or not, and their streams
  #|          handles.delete(a.id);
  #|          for (const [id, one] of handles) {
  #|            if (one.of !== a.id) continue;
  #|            handles.delete(id);
  #|            streamsGo(id);
  #|          }
  #|          await h.endpoint.close();
  #|        }
  #|        return [{}];
  #|      case "conn.openBi": {
  #|        const opened = await connection(h).openBi();
  #|        // (ended, or let go of, meanwhile: its streams went then, and this one would stay)
  #|        if (handles.get(a.id) !== h) throw new Error("connection closed");
  #|        return [{ id: keep({ stream: opened, on: a.id, finished: false, ended: false }) }];
  #|      }
  #|      case "conn.acceptBi": {
  #|        if (h?.gone !== undefined) return [{ end: true }];
  #|        const accepted = await connection(h).acceptBi();
  #|        // (ended, or let go of, meanwhile: its streams went then, and this one would stay)
  #|        if (accepted === null || accepted === undefined || handles.get(a.id) !== h) return [{ end: true }];
  #|        return [{ id: keep({ stream: accepted, on: a.id, finished: false, ended: false }) }];
  #|      }
  #|      case "conn.closed":
  #|        if (h?.gone !== undefined) return [h.gone];
  #|        connection(h);
  #|        return [await h.closed];
  #|      case "conn.close":
  #|        if (h?.gone === undefined) connection(h).close(a.code ?? 0, a.reason ?? "");
  #|        // `forget`: nothing is asked of it after (the mesh was told its end, or gave it up with its opening, where
  #|        // it is closed just above): let go of, its streams with it
  #|        if (a.forget === true) {
  #|          handles.delete(a.id);
  #|          streamsGo(a.id);
  #|        }
  #|        return [{}];
  #|      case "istream.read": {
  #|        const came = await stream(h).read();
  #|        if (came !== null && came !== undefined) return [{}, came];
  #|        h.ended = true;
  #|        if (h.finished) handles.delete(a.id);
  #|        return [{ end: true }];
  #|      }
  #|      case "istream.write":
  #|        await stream(h).write(bytes ?? none);
  #|        return [{}];
  #|      case "istream.finish":
  #|        await stream(h).finish();
  #|        h.finished = true;
  #|        if (h.ended) handles.delete(a.id);
  #|        return [{}];
  #|      case "istream.stopped": {
  #|        const code = (await stream(h).stopped()) ?? null;
  #|        if (code === null) {
  #|          // (null is a failure's answer too: its connection ended, or let go of, that is what it was)
  #|          const on = handles.get(h.on);
  #|          if (on?.conn === undefined || (on.conn.closeReason() ?? null) !== null) throw new Error("connection closed");
  #|        }
  #|        return [{ code }];
  #|      }
  #|      case "fetch":
  #|        return request(id, a, bytes, async (response, head) => [head, new Uint8Array(await response.arrayBuffer())]);
  #|      case "stream.open":
  #|        return request(id, a, bytes, async (response, head) => {
  #|          const reader = response.body ? response.body.getReader() : null;
  #|          return [{ ...head, id: keep({ responseReader: reader, done: reader === null }) }];
  #|        });
  #|      case "stream.read": {
  #|        if (h?.responseReader === undefined) throw new Error("not a response");
  #|        for (;;) {
  #|          const came = h.done ? { done: true } : await h.responseReader.read();
  #|          if (came.done) {
  #|            h.done = true;
  #|            handles.delete(a.id);
  #|            return [{ end: true }];
  #|          }
  #|          if (came.value.length > 0) return [{}, came.value];
  #|        }
  #|      }
  #|      case "stream.close":
  #|        if (h?.responseReader !== undefined) {
  #|          handles.delete(a.id);
  #|          if (!h.done) await h.responseReader.cancel().catch(() => {});
  #|          h.done = true;
  #|        }
  #|        return [{}];
  #|      case "istream.reset":
  #|        if (h?.stream !== undefined) {
  #|          handles.delete(a.id);
  #|          await h.stream.reset(a.code ?? 0);
  #|        }
  #|        return [{}];
  #|      default:
  #|        throw new Error("a page's shell has no " + op);
  #|    }
  #|  };
  #|  // what a call is answered at once
  #|  const now = (op, a) => {
  #|    if (op === "fetch.cancel") {
  #|      const give = dials.get(a.id);
  #|      if (give === undefined) return false;
  #|      give();
  #|      return true;
  #|    }
  #|    const h = handles.get(a.id);
  #|    switch (op) {
  #|      case "iroh.endpointId":
  #|        if (h?.endpoint !== undefined) return h.endpoint.id();
  #|        break;
  #|      case "iroh.relayStatus":
  #|        if (h?.endpoint !== undefined) return h.endpoint.relayStatus();
  #|        break;
  #|      case "iroh.addAddr":
  #|        // (where a peer is, without looking it up: iroh-wasm's `addAddr`, answered at once)
  #|        if (h?.endpoint !== undefined) {
  #|          h.endpoint.addAddr(a.addr);
  #|          return null;
  #|        }
  #|        break;
  #|      case "conn.closeReason":
  #|        if (h?.conn !== undefined) return h.conn.closeReason() ?? null;
  #|        if (h?.gone !== undefined) return h.gone;
  #|        break;
  #|      case "conn.paths":
  #|        if (h?.conn !== undefined) return h.conn.paths();
  #|        if (h?.gone !== undefined) return [];
  #|        break;
  #|      case "conn.stats":
  #|        // ({rxBytes, txBytes}: of one that ended a page keeps none, and the mesh asks it of none)
  #|        if (h?.conn !== undefined) return h.conn.stats();
  #|        break;
  #|      default:
  #|        throw new Error("a page's shell has no " + op);
  #|    }
  #|    throw new Error(op + ": not its handle");
  #|  };
  #|  const said = (e) => String(e?.message ?? e);
  #|  let timer = 0;
  #|  return {
  #|    call: (id, op, json, bytes, has) => {
  #|      run(id, op, JSON.parse(json), has ? bytes : null).then(
  #|        (answer) => answered(id, answer.length > 1 ? 1 : 0, JSON.stringify(answer[0]), answer.length > 1 ? answer[1] : none),
  #|        (e) => answered(id, 2, said(e), none),
  #|      );
  #|    },
  #|    ask: (op, json) => {
  #|      try {
  #|        return JSON.stringify({ value: now(op, JSON.parse(json)) ?? null });
  #|      } catch (e) {
  #|        return JSON.stringify({ error: said(e) });
  #|      }
  #|    },
  #|    soon: (turn) => queueMicrotask(turn),
  #|    // (a delay past 2^31-1 ms a browser takes for none and fires at once: the most it takes is asked instead, and
  #|    // the turn that comes of it, finding nothing due, asks again for what is left)
  #|    wake: (ms, turn) => {
  #|      clearTimeout(timer);
  #|      timer = ms < 0 ? 0 : setTimeout(turn, Math.min(ms, 2147483647));
  #|    },
  #|  };
  #|}

///|
extern "js" fn page_call(page : Page, id : Int, op : String, json : String, bytes : Bytes, has : Bool) -> Unit =
  #|(page, id, op, json, bytes, has) => page.call(id, op, json, bytes, has)

///|
extern "js" fn page_ask(page : Page, op : String, json : String) -> String =
  #|(page, op, json) => page.ask(op, json)

///|
/// `turn` run once what runs now is over (a microtask).
extern "js" fn page_soon(page : Page, turn : () -> Unit) -> Unit =
  #|(page, turn) => page.soon(turn)

///|
/// `turn` run `ms` from now, in the place of the one asked before (the page's one timer); negative: none. It may
/// come early (after 2^31-1 ms where `ms` is more): whoever asks looks at the clock when it does.
extern "js" fn page_wake(page : Page, ms : Double, turn : () -> Unit) -> Unit =
  #|(page, ms, turn) => page.wake(ms, turn)

///|
extern "js" fn page_now() -> Double =
  #|() => performance.now()

///|
extern "js" fn page_random(n : Int) -> Bytes =
  #|(n) => crypto.getRandomValues(new Uint8Array(n))

///|
/// The page's side, once the shell is started.
let page : Ref[Page?] = Ref(None)

///|
/// Starts the shell of this page for the fibers of `rt`: what it keeps (`storage.*`) is in the page's localStorage
/// under `dir` (the key `<dir>:<key>`, in hex), and iroh is the module at `iroh` (an address of the page's server:
/// iroh-wasm's JavaScript, its wasm beside it), loaded as the first endpoint is bound. From now on `rt` is turned by
/// the page's events: once what woke a fiber is over (an answer of the shell's, a fork from the page's own code), and
/// as its next timer comes due, by `rt`'s own clock. So `rt` is a runtime on a clock of the page's
/// (`Runtime::live(now)`), and nothing else ticks it.
pub fn Shell::start(rt : @effect.Runtime, dir : String, iroh~ : String) -> Shell {
  Shell::started(rt, dir, loader_at(iroh))
}

///|
/// As `Shell::start`, with iroh given rather than loaded from an address (`IrohJs`: the module a bundle imported, or
/// what initializes it), for a page or a worker. `dir`: what `storage.*` keys are kept under, where there is a
/// localStorage (a worker has none, and its program keeps its own).
pub fn Shell::start_with(rt : @effect.Runtime, iroh : IrohJs, dir? : String = "") -> Shell {
  Shell::started(rt, dir, loader_of(iroh))
}

///|
/// The page's shell started, iroh got by `loader`, and `rt` turned by the page's events from now on.
fn Shell::started(rt : @effect.Runtime, dir : String, loader : Loader) -> Shell {
  let shell = Shell::of_target(rt)
  let made = page_start(dir, loader, (id, kind, text, bytes) => shell.settle(id.to_int64(), kind, text, bytes))
  page.val = Some(made)
  turn_on(rt, made)
  shell
}

///|
/// `rt` turned by the page `made`'s events: once what woke a fiber is over, and as its next timer comes due.
fn turn_on(rt : @effect.Runtime, made : Page) -> Unit {
  // (one turn for all that woke since the last: asked once, run as a microtask; then the page's timer set for the
  // runtime's next, which asks a turn as it comes due)
  let asked = Ref(false)
  let wake : Ref[() -> Unit] = Ref(() => ())
  let turn = () => {
    asked.val = false
    rt.tick()
    match rt.next_timer() {
      Some(at) => {
        let left = at - rt.now()
        page_wake(made, if left < 0L { 0.0 } else { left.to_double() }, () => (wake.val)())
      }
      None => page_wake(made, -1.0, () => ())
    }
  }
  wake.val = () => {
    if !asked.val {
      asked.val = true
      page_soon(made, turn)
    }
  }
  rt.on_wake(() => (wake.val)())
  rt.on_timer(_ => (wake.val)())
}

///|
/// A call out: `op` with its JSON and, where it carries any, its bytes, answered later as `id`.
fn send(id : Int64, op : String, json : String, bytes : Bytes?) -> Unit {
  guard page.val is Some(page) else { return }
  match bytes {
    Some(b) => page_call(page, id.to_int(), op, json, b, true)
    None => page_call(page, id.to_int(), op, json, b"", false)
  }
}

///|
/// What the shell answers `op` at once: `{"value": …}` or `{"error": …}`.
fn asked(op : String, json : String) -> String {
  match page.val {
    Some(page) => page_ask(page, op, json)
    None => "{\"error\":\"the shell is not started\"}"
  }
}

///|
/// A clock that never goes back, in ms: what a runtime of the shell's programs goes by.
pub fn now() -> Int64 {
  page_now().to_int64()
}

///|
/// `n` bytes of the system's randomness (a key).
pub fn random(n : Int) -> Bytes {
  page_random(n)
}

///|
/// A tab's claim on a page (tab.mbt), as `tab_start` made it.
#external
priv type TabJs

///|
/// A tab's claim under `name`: the Web Lock `base:tab:<name>`, held by a request whose promise is resolved as it is let
/// go of, and the BroadcastChannel of the same name, on which a tab asks the one that holds it to let it go
/// (`{kind: "take", by}`) and a tab that has it after such an ask says so (`{kind: "held", by}`). `told` is given
/// each change: 0 held, 1 busy, 2 yielded. Without Web Locks or a BroadcastChannel (where nothing could hold it
/// against another tab) it is held at once, and stays so.
///
/// A tab told `take` while it holds it is told yielded first and then lets it go, so its program stops before the
/// next tab starts; a second `take` finds nothing to let go of. A tab that asked waits in the lock's own queue,
/// asked before it says so, so it has it as the one before lets it go. Two tabs asking at once: the first in the
/// queue has it and says so, and the other, still waiting, asks again, so the last to ask has it and none waits
/// behind a tab that never heard it.
extern "js" fn tab_start(name : String, told : (Int) -> Unit) -> TabJs =
  #|(name, told) => {
  #|  const locks = globalThis.navigator?.locks;
  #|  const Channel = globalThis.BroadcastChannel;
  #|  let closed = false;
  #|  if (typeof locks?.request !== "function" || typeof Channel !== "function") {
  #|    told(0);
  #|    return { take: () => {}, release: () => { closed = true; } };
  #|  }
  #|  const key = "base:tab:" + name;
  #|  const me = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");
  #|  const channel = new Channel(key);
  #|  // what was told last; what lets go of the lock while it is held here; what gives up an ask while it waits;
  #|  // whether the first answer is still to come, and whether a take over was asked meanwhile
  #|  let state = -1;
  #|  let letGo = null;
  #|  let asked = null;
  #|  let first = true;
  #|  let wanted = false;
  #|  const tell = (s) => {
  #|    if (closed || state === s) return;
  #|    state = s;
  #|    told(s);
  #|  };
  #|  // the lock granted: held until let go of (yielded or released); released before it came, let go of at once
  #|  const hold = () => {
  #|    if (closed) return undefined;
  #|    const held = new Promise((resolve) => { letGo = resolve; });
  #|    tell(0);
  #|    channel.postMessage({ kind: "held", by: me });
  #|    return held;
  #|  };
  #|  const take = () => {
  #|    if (closed || letGo !== null || asked !== null) return;
  #|    if (first) {
  #|      wanted = true;
  #|      return;
  #|    }
  #|    const ask = new AbortController();
  #|    asked = ask;
  #|    new Promise((ok) => ok(locks.request(key, { signal: ask.signal }, () => {
  #|      if (asked === ask) asked = null;
  #|      return hold();
  #|    }))).catch(() => { if (asked === ask) asked = null; });
  #|    channel.postMessage({ kind: "take", by: me });
  #|  };
  #|  channel.onmessage = (event) => {
  #|    const m = event?.data;
  #|    if (closed || m?.by === me) return;
  #|    if (m?.kind === "held") {
  #|      // (had by another while this one still waits: it asks again)
  #|      if (asked !== null) channel.postMessage({ kind: "take", by: me });
  #|      return;
  #|    }
  #|    if (m?.kind !== "take" || letGo === null) return;
  #|    const go = letGo;
  #|    letGo = null;
  #|    tell(2);
  #|    go();
  #|  };
  #|  new Promise((ok) => ok(locks.request(key, { ifAvailable: true }, (lock) => {
  #|    first = false;
  #|    if (lock !== null && lock !== undefined) return hold();
  #|    tell(1);
  #|    if (wanted) take();
  #|    return undefined;
  #|  }))).catch(() => {
  #|    // (the browser refused to ask at all: as where there are no locks, held, so the program is not stuck)
  #|    first = false;
  #|    tell(0);
  #|  });
  #|  return {
  #|    take,
  #|    release: () => {
  #|      if (closed) return;
  #|      closed = true;
  #|      asked?.abort();
  #|      asked = null;
  #|      const go = letGo;
  #|      letGo = null;
  #|      go?.();
  #|      channel.close();
  #|    },
  #|  };
  #|}

///|
extern "js" fn tab_take(tab : TabJs) -> Unit =
  #|(tab) => tab.take()

///|
extern "js" fn tab_release(tab : TabJs) -> Unit =
  #|(tab) => tab.release()

///|
/// A claim on a page (tab.mbt), as `tab_start` keeps it.
fn tab_claim(name : String, on_state : (TabState) -> Unit) -> TabClaim {
  let tab = tab_start(name, told => on_state(
    match told {
      0 => Held
      1 => Busy
      _ => Yielded
    },
  ))
  { take: () => tab_take(tab), let_go: () => tab_release(tab) }
}
