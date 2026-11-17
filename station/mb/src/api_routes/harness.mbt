// The routes run against the station as a test says it (`harness-api-routes`, station/test/mb-api-routes.test.ts):
// every call of a part goes to the test on stdout, `{"call": n, "name", "args"}`, answered on stdin `{"ret": n,
// "value"}` or `{"ret": n, "throw": {kind, ...}}`; a request comes as `{"req": {id, method, path, query, search,
// headers, body (base64), viewer, lang}}` and is answered `{"ans": id, status, headers, body (base64)}`. The first
// line is `{"setup": {zh, en, product, build, runtimes, dev, data, absent}}`.

///|
priv struct Harness {
  host : @host.Host
  waiting : Map[Int32, @effect.Deferred[Result[JV, Error]]]
  mut next : Int32
  claims : Map[Int32, async (Kept?) -> Unit]
}

///|
fn Harness::say(self : Harness, v : JV) -> Unit {
  self.host.say(stringify(v))
}

///|
async fn Harness::call(self : Harness, name : String, args : Array[JV]) -> JV {
  self.next += 1
  let n = self.next
  let done = @effect.Deferred::new()
  self.waiting[n] = done
  self.say(jobj([("call", jint(n)), ("name", js(name)), ("args", jarr(args))]))
  match done.wait() {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
fn pairs_of(v : JV?) -> Array[(String, String)] {
  jitems(v).map(p => {
    let items = jitems(Some(p))
    (jstr(items.get(0)).unwrap_or(""), jstr(items.get(1)).unwrap_or(""))
  })
}

///|
fn request_of(q : JV) -> Request {
  {
    verb: jstr(q.get("method")).unwrap_or("GET"),
    path: jstr(q.get("path")).unwrap_or("/"),
    query: pairs_of(q.get("query")),
    search: jstr(q.get("search")),
    headers: match q.get("headers") {
      Some(Obj(fields)) => fields.map(f => (f.0, js_string(Some(f.1))))
      other => pairs_of(other)
    },
    body: @base64.decode(jstr(q.get("body")).unwrap_or("")) catch {
      _ => b""
    },
    viewer: q.get("viewer").unwrap_or(Obj([])),
    lang: jstr(q.get("lang")).unwrap_or("zh"),
    background: q.get("background") is Some(Bool(true)),
    signal: if q.get("signal") is Some(Bool(false)) {
      None
    } else {
      Some(Signal::new())
    },
  }
}

///|
fn kept_json(k : Kept) -> JV {
  jobj([
    ("status", jint(k.status)),
    ("headers", jobj(k.headers.to_array().map(h => (h.0, js(h.1))))),
    ("body", js(@base64.encode(k.body))),
  ])
}

///|
fn kept_from(v : JV) -> Kept {
  let headers = {}
  for f in jfields(v.get("headers")) {
    headers[f.0] = jstr(Some(f.1)).unwrap_or("")
  }
  {
    status: jnumber(v.get("status")).unwrap_or(0.0).to_int(),
    headers,
    body: @base64.decode(jstr(v.get("body")).unwrap_or("")) catch {
      _ => b""
    },
  }
}

///|
pub async fn harness(host : @host.Host) -> Unit {
  let h : Harness = { host, waiting: {}, next: 0, claims: {}, }
  guard host.line() is Some(first) else { return }
  let setup = parse(first).get("setup").unwrap_or(Obj([]))
  let admin = Admin::new(Backend::new((name, args) => h.call(name, args)), {
    words: Words::new(
      setup.get("zh").unwrap_or(Obj([])),
      setup.get("en").unwrap_or(Obj([])),
      product=jstr(setup.get("product")).unwrap_or("still.fail"),
    ),
    build: jstr(setup.get("build")).unwrap_or(""),
    runtime_kinds: jitems(setup.get("runtimes")).filter_map(v => jstr(Some(v))),
    dev: setup.get("dev") is Some(Bool(true)),
    data: jstr(setup.get("data")),
    station_lang: jstr(setup.get("stationLang")).unwrap_or("zh"),
    grant_key: @base64.decode(jstr(setup.get("grantKey")).unwrap_or("")) catch {
      _ => b""
    },
    absent: jitems(setup.get("absent")).filter_map(v => jstr(Some(v))),
  })
  h.say(jobj([("ready", jbool(true))]))

  while host.line() is Some(line) {
    let said = parse(line) catch { _ => continue }
    match said {
      { "ret": Num(n), .. } =>
        match h.waiting.get(n.to_int()) {
          Some(done) => {
            h.waiting.remove(n.to_int())
            match said.get("throw") {
              Some(t) =>
                ignore(
                  done.succeed(
                    Err(Thrown(jstr(t.get("kind")).unwrap_or("Error"), t)),
                  ),
                )
              None =>
                ignore(done.succeed(Ok(said.get("value").unwrap_or(jundef))))
            }
          }
          None => ()
        }
      { "req": q, .. } => {
        let id = q.get("id").unwrap_or(Null)
        ignore(
          host.rt.fork(name="harness request", async fn() {
            let r = request_of(q)
            let out = try {
              let a = admin.handle(r)
              let body = a.bytes()
              jobj([
                ("ans", id),
                ("status", jint(a.status)),
                ("headers", jobj(a.headers.to_array().map(x => (x.0, js(x.1))))),
                ("body", js(@base64.encode(body))),
              ])
            } catch {
              e =>
                match refused_of(e) {
                  Some((status, message)) =>
                    jobj([
                      ("ans", id),
                      (
                        "refused",
                        jobj([
                          ("status", jint(status)),
                          ("message", js(message)),
                        ]),
                      ),
                    ])
                  None => jobj([("ans", id), ("failed", js(e.to_string()))])
                }
            }
            h.say(out)
          }),
        )
      }
      { "keptSends": t, .. } => {
        let threads = {}
        for p in jitems(t.get("threads")) {
          let items = jitems(Some(p))
          threads[jnumber(items.get(0)).unwrap_or(0.0)] = jnumber(items.get(1)).unwrap_or(
            0.0,
          )
        }
        let sends = admin.kept_sends(threads)
        h.say(
          jobj([
            (
              "keptSends",
              jarr(
                sends.map(s => {
                  jobj([
                    ("viewer", js(s.viewer)),
                    ("thread", jnum(s.thread)),
                    ("key", js(s.key)),
                    ("at", jnum(s.at)),
                    ("status", jint(s.status)),
                    (
                      "headers",
                      jobj(s.headers.to_array().map(x => (x.0, js(x.1)))),
                    ),
                    ("body", js(s.body)),
                  ])
                }),
              ),
            ),
          ]),
        )
      }
      { "keepSends": Arr(sends), .. } => {
        admin.keep_sends(
          sends.map(s => {
            let k = kept_from(s)
            {
              viewer: jstr(s.get("viewer")).unwrap_or(""),
              thread: jnumber(s.get("thread")).unwrap_or(0.0),
              key: jstr(s.get("key")).unwrap_or(""),
              at: jnumber(s.get("at")).unwrap_or(0.0),
              status: k.status,
              headers: k.headers,
              body: jstr(s.get("body")).unwrap_or(""),
            }
          }),
        )
        h.say(jobj([("keptSendsKept", jbool(true))]))
      }
      { "claimSay": c, .. } => {
        let id = jnumber(c.get("id")).unwrap_or(0.0).to_int()
        ignore(
          host.rt.fork(name="harness claim", async fn() {
            let claim = admin.claim_say(
              c.get("viewer").unwrap_or(Obj([])),
              jstr(c.get("path")).unwrap_or(""),
              jstr(c.get("key")),
              jstr(c.get("lang")).unwrap_or("zh"),
            )
            let out = match claim {
              KeptAnswer(k) =>
                jobj([("claimed", jint(id)), ("kept", kept_json(k))])
              RefusedAnswer(k) =>
                jobj([("claimed", jint(id)), ("refused", kept_json(k))])
              Write(ts, settle) => {
                h.claims[id] = settle
                jobj([("claimed", jint(id)), ("ts", js(ts))])
              }
            }
            h.say(out)
          }),
        )
      }
      { "settle": c, .. } => {
        let id = jnumber(c.get("id")).unwrap_or(0.0).to_int()
        match h.claims.get(id) {
          Some(settle) => {
            h.claims.remove(id)
            let answer = match c.get("answer") {
              Some(Obj(_) as a) => Some(kept_from(a))
              _ => None
            }
            ignore(
              host.rt.fork(name="harness settle", async fn() {
                settle(answer)
                h.say(jobj([("settled", jint(id))]))
              }),
            )
          }
          None => ()
        }
      }
      { "callback": Num(n), .. } => {
        let args = jitems(said.get("args"))
        ignore(
          host.rt.fork(name="harness callback", async fn() {
            let v = admin.called(n.to_int(), args)
            h.say(jobj([("calledBack", jnum(n)), ("value", v)]))
          }),
        )
      }
      { "start": _, .. } =>
        ignore(
          host.rt.fork(name="harness start", async fn() {
            admin.start()
            h.say(jobj([("started", jbool(true))]))
          }),
        )
      { "drain": _, .. } =>
        ignore(
          host.rt.fork(name="harness drain", async fn() {
            admin.drained()
            h.say(jobj([("drained", jbool(true))]))
          }),
        )
      { "saidElsewhere": c, .. } =>
        ignore(
          host.rt.fork(name="harness said", async fn() {
            admin.said_elsewhere(
              jnumber(c.get("thread")).unwrap_or(0.0),
              jnumber(c.get("n")).unwrap_or(0.0),
              jstr(c.get("text")).unwrap_or(""),
              c.get("row").unwrap_or(Obj([])),
            )
            h.say(jobj([("saidElsewhereDone", jbool(true))]))
          }),
        )
      _ => ()
    }
  }
}
