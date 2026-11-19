// What station/test/mb-feishu.test.ts gives the same inputs as the TypeScript it replaces (reader `--builder
// harness-feishu`): a JSON line a case on stdin, a JSON line its outcome on stdout (`{"ok": …}` or `{"error": …}`).
// Each case is worked out whole on its own: its Feishu a stand-in answering each `METHOD /path` from the case's list
// (the last answer again once they are used up), its disk in memory, its clock a runtime of its own moved only as the
// case says (`advance`), the machine's time (`wall`) moved only by what sleeps on it. What it saw is said back raw
// (each request's address, headers and bytes): the test reads both sides' the same way.

///|
fn bytes_of_hex(hex : String) -> Bytes {
  let n = hex.length() / 2
  let out = FixedArray::make(n, b'\x00')
  for i in 0..<n {
    let hi = @codec.hex_digit(hex.unsafe_charcode_at(2 * i)).unwrap_or(0)
    let lo = @codec.hex_digit(hex.unsafe_charcode_at(2 * i + 1)).unwrap_or(0)
    out[i] = (hi * 16 + lo).to_byte()
  }
  Bytes::from_array(out)
}

///|
/// A decimal integer's low 64 bits (BigInt.asUintN(64), as `encode` writes one), and its bits above them.
fn big_of_decimal(s : String) -> Big {
  let neg = starts(s, "-")
  let digits = if neg { s.unsafe_substring(start=1, end=s.length()) } else { s }
  // (hi, lo) as 128 bits, wrapping
  let mut hi = 0UL
  let mut lo = 0UL
  for i in 0..<digits.length() {
    let d = (digits.unsafe_charcode_at(i) - '0').to_uint64()
    // (hi, lo) * 10 + d
    let lo_hi = lo >> 32
    let lo_lo = lo & 0xffffffffUL
    let p_lo = lo_lo * 10UL
    let p_mid = lo_hi * 10UL + (p_lo >> 32)
    let new_lo = ((p_mid & 0xffffffffUL) << 32) | (p_lo & 0xffffffffUL)
    let carry = p_mid >> 32
    hi = hi * 10UL + carry
    lo = new_lo + d
    if lo < d {
      hi = hi + 1UL
    }
  }
  if neg {
    // two's complement of 128 bits
    let nlo = lo.lnot() + 1UL
    let nhi = hi.lnot() + (if nlo == 0UL { 1UL } else { 0UL })
    { hi: nhi, lo: nlo }
  } else {
    { hi, lo }
  }
}

///|
fn num_of(v : JV?) -> Double {
  match v {
    Some(Num(n)) => n
    _ => 0.0
  }
}

///|
fn opt_text(v : JV?) -> String? {
  match v {
    Some(Str(s)) => Some(s)
    _ => None
  }
}

///|
fn frame_of_jv(f : JV) -> Frame {
  let o = Some(f)
  {
    seq_id: big_of_decimal(js_string(Some(nullish(jget(o, "seqId"), Str("0"))))),
    log_id: big_of_decimal(js_string(Some(nullish(jget(o, "logId"), Str("0"))))),
    service: num_of(jget(o, "service")).to_int64(),
    meth: num_of(jget(o, "method")).to_int64(),
    headers: jitems(jget(o, "headers")).map(h => (text(jat(Some(h), 0)), text(jat(Some(h), 1)))),
    payload_encoding: opt_text(jget(o, "payloadEncoding")),
    payload_type: opt_text(jget(o, "payloadType")),
    payload: opt_text(jget(o, "payload")).map(bytes_of_hex),
    log_id_new: opt_text(jget(o, "logIdNew")),
  }
}

///|
fn frame_to_jv(f : Frame) -> JV {
  jobj([
    ("seqId", Some(js(f.seq_id.to_decimal()))),
    ("logId", Some(js(f.log_id.to_decimal()))),
    ("service", Some(Num(f.service.to_double()))),
    ("method", Some(Num(f.meth.to_double()))),
    ("headers", Some(Arr(f.headers.map(h => Arr([js(h.0), js(h.1)]))))),
    ("payloadEncoding", f.payload_encoding.map(js)),
    ("payloadType", f.payload_type.map(js)),
    ("payload", f.payload.map(p => js(@codec.hex_encode(p)))),
    ("logIdNew", f.log_id_new.map(js)),
  ])
}

///|
/// The words: the catalog the test gave, and the station's language.
priv struct Said {
  mut catalog : @ops_platform.Catalog
  mut lang : String
}

///|
let said : Said = {
  catalog: @ops_platform.Catalog::from_json(Json::null(), Json::null()),
  lang: "zh",
}

///|
fn words() -> Words {
  {
    tr: (lang, key, args) => @ops_platform.tr(said.catalog, lang, key, args),
    station_lang: () => said.lang,
  }
}

///|
fn outcome(f : () -> JV raise) -> JV {
  try {
    jobj([("ok", Some(f()))])
  } catch {
    e => jobj([("error", Some(js(error_words(e))))])
  }
}

///|
fn arg(c : JV, i : Int) -> JV? {
  jat(jget(Some(c), "args"), i)
}

///|
fn end_of(v : JV?) -> CardEnd {
  match text(jget(v, "why")) {
    "message" => ByMessage(text(jget(v, "by")), text(jget(v, "byTs")))
    "replaced" => Replaced
    "withdrawn" => Withdrawn
    _ => Closed
  }
}

///|
fn identity_of_jv(v : JV?) -> BotIdentity {
  {
    team: text(jget(v, "team")),
    team_id: text(jget(v, "teamId")),
    url: text(jget(v, "url")),
    bot_user_id: text(jget(v, "botUserId")),
    bot_name: text(jget(v, "botName")),
    bot_image: opt_text(jget(v, "botImage")),
    bot_id: text(jget(v, "botId")),
  }
}

///|
/// The pure functions, each by its TypeScript name.
fn pure_case(c : JV) -> JV raise {
  let a0 = arg(c, 0)
  let s0 = text(a0)
  match text(jget(Some(c), "fn")) {
    // frame.ts
    "encode" => js(@codec.hex_encode(encode(frame_of_jv(or_null(a0)))))
    "decode" => frame_to_jv(decode(bytes_of_hex(s0)))
    // parse.ts
    "messageOf" =>
      match message_of(a0, text(arg(c, 1))) {
        Some(m) => m.to_jv()
        None => Null
      }
    "listedAsEvent" => listed_as_event(a0)
    "cardAnswerOf" =>
      match card_answer_of(a0, text(arg(c, 1))) {
        Some(a) => a.to_jv()
        None => Null
      }
    "resourceUrl" => js(resource_url(s0, text(arg(c, 1)), text(arg(c, 2))))
    "resourceOf" =>
      match resource_of(s0) {
        Some((kind, message, key)) =>
          jobj([
            ("type", Some(js(kind))),
            ("message", Some(js(message))),
            ("key", Some(js(key))),
          ])
        None => Null
      }
    // cards.ts
    "textPosts" => Arr(text_posts(s0).map(js))
    "questionCard" =>
      question_card(words(), s0, arg(c, 1), text(arg(c, 2)), text(arg(c, 3)))
    "answeredCard" =>
      answered_card(words(), s0, text(arg(c, 1)), text(arg(c, 2)), text(arg(c, 3)))
    "endedCard" => ended_card(s0, text(arg(c, 1)))
    "took" => js(took(words(), num_of(a0), text(arg(c, 1))))
    "workingCard" => working_card(s0)
    "doneCard" => done_card(words(), num_of(a0), opt_text(arg(c, 1)), text(arg(c, 2)))
    "inline" => js(inline(or_null(a0)))
    "entity" => js(entity(s0))
    "endedWords" =>
      js(ended_words(words(), arg(c, 0), end_of(arg(c, 1)), opt_text(arg(c, 2)), text(arg(c, 3))))
    // index.ts
    "feishuConnects" => Arr(feishu_connects(or_null(a0)).map(x => x.to_jv()))
    "maskSecret" => js(mask_secret(s0))
    "credentials" =>
      match feishu_connects(or_null(a0)) {
        [first, ..] => jopt(credentials(first))
        [] => Null
      }
    "seen" =>
      match feishu_connects(or_null(a0)) {
        [first, ..] =>
          match seen_patch(first, identity_of_jv(arg(c, 1))) {
            Some(patch) => {
              let entry = parse(stringify(or_null(arg(c, 2))))
              patch(entry)
              entry
            }
            None => Null
          }
        [] => Null
      }
    "shown" => {
      let live = match arg(c, 1) {
        Some(Obj(_) as l) => Some(identity_of_jv(Some(l)))
        _ => None
      }
      shown(or_null(a0), live)
    }
    "domainOf" => js(domain_of(a0))
    // web.ts, surface.ts, tool.ts, register.ts
    "isJson" => Bool(is_json_type(s0))
    "urlWith" =>
      js(url_with(s0, jitems(arg(c, 1)).map(p => (text(jat(Some(p), 0)), text(jat(Some(p), 1))))))
    "extname" => js(extname(s0))
    "fileType" => js(file_type(s0))
    "isImage" => Bool(is_image_name(s0))
    "fileName" => js(file_name(s0, text(arg(c, 1))))
    "apiMethod" =>
      match api_method(trim_js(s0)) {
        Some((v, p)) => Arr([js(v), js(p)])
        None => Null
      }
    "serviceOf" => Num(service_of(s0))
    "encodeAddons" => js(encode_addons(addons()))
    "shownRegistration" => shown_registration(or_null(a0))
    "toolDeclaration" => feishu_api_tool()
    "gzip" => js(@codec.hex_encode(gzip(utf8(s0))))
    f => raise FeishuError("no such function: \{f}")
  }
}

///|
/// `Parts` through a list of steps: each `{add: frame, now}` the whole or None (or its error), each `{drop}` nothing.
fn parts_case(c : JV) -> JV {
  let parts = Parts::new()
  let out = []
  for step in jitems(jget(Some(c), "steps")) {
    match jget(Some(step), "add") {
      Some(f) =>
        out.push(
          outcome(() => match
            parts.add(frame_of_jv(f), num_of(jget(Some(step), "now")).to_int64()) {
            Some(b) => js(@codec.hex_encode(b))
            None => Null
          }),
        )
      None => {
        parts.drop(num_of(jget(Some(step), "drop")).to_int64())
        out.push(Null)
      }
    }
  }
  jobj([("steps", Some(Arr(out))), ("open", Some(jint(parts.open_count())))])
}

// ── a case's world ──

///|
/// A stand-in for Feishu (its OpenAPI and its accounts' device flow): each `METHOD /path` answered from the case's
/// list in order, the last again once they are used up; what was asked kept as it came.
priv struct World {
  routes : JV
  used : Map[String, Int]
  seen : Array[JV]
  sleeps : Array[JV]
  logs : Array[JV]
  mut wall : Int64
  files : Map[String, Bytes]
  writes : Array[JV]
}

///|
fn World::new(c : JV) -> World {
  let files : Map[String, Bytes] = Map([])
  match jget(Some(c), "files") {
    Some(Obj(fields)) => for f in fields { files[f.0] = bytes_of_hex(text(Some(f.1))) }
    _ => ()
  }
  {
    routes: nullish(jget(Some(c), "routes"), Obj([])),
    used: Map([]),
    seen: [],
    sleeps: [],
    logs: [],
    wall: num_of(jget(Some(c), "wall")).to_int64(),
    files,
    writes: [],
  }
}

///|
/// The path of an address (what is between its host and its query).
fn path_of(url : String) -> String {
  match @cloud_net.parse_url(url) {
    Some(u) => u.path
    None => url
  }
}

///|
fn World::answer(self : World, req : HttpRequest) -> HttpResponse raise FeishuError {
  self.seen.push(
    jobj([
      ("method", Some(js(req.verb))),
      ("url", Some(js(req.url))),
      ("headers", Some(Arr(req.headers.map(h => Arr([js(h.0), js(h.1)]))))),
      ("body", Some(match req.body { Some(b) => js(@codec.hex_encode(b)); None => Null })),
    ]),
  )
  let route = "\{req.verb} \{path_of(req.url)}"
  let list = jitems(self.routes.get(route))
  let spec = if list.is_empty() {
    if route == "POST /open-apis/auth/v3/tenant_access_token/internal" {
      jobj([
        (
          "json",
          Some(
            jobj([
              ("code", Some(jint(0))),
              ("tenant_access_token", Some(js("t-1"))),
              ("expire", Some(jint(7200))),
            ]),
          ),
        ),
      ])
    } else {
      jobj([
        (
          "json",
          Some(jobj([("code", Some(jint(0))), ("data", Some(Obj([])))])),
        ),
      ])
    }
  } else {
    let n = self.used.get(route).unwrap_or(0)
    self.used[route] = n + 1
    list[@cmp.minimum(n, list.length() - 1)]
  }
  match jget(Some(spec), "fail") {
    Some(Str(words)) => raise FeishuError(words)
    _ => ()
  }
  let headers : Array[(String, String)] = match jget(Some(spec), "headers") {
    Some(Obj(_) as h) => jkeys(h).map(k => (@jscase.lower(k), text(h.get(k))))
    _ => []
  }
  let body = match jget(Some(spec), "json") {
    Some(j) => {
      if !headers.iter().any(h => h.0 == "content-type") {
        headers.push(("content-type", "application/json"))
      }
      utf8(stringify(j))
    }
    None =>
      match jget(Some(spec), "hex") {
        Some(Str(h)) => bytes_of_hex(h)
        _ => {
          if !headers.iter().any(h => h.0 == "content-type") &&
            jget(Some(spec), "text") is Some(_) {
            headers.push(("content-type", "text/plain;charset=UTF-8"))
          }
          utf8(text(jget(Some(spec), "text")))
        }
      }
  }
  let status = match jget(Some(spec), "status") {
    Some(Num(n)) => n.to_int()
    _ => 200
  }
  { status, headers, body }
}

///|
/// (`stand_in`: STILLFAIL_FEISHU_API, where the case's TypeScript sets it)
fn World::net(self : World, stand_in? : String) -> Net {
  {
    fetch: async fn(req) { self.answer(req) },
    now: () => self.wall,
    sleep: async fn(ms) {
      self.sleeps.push(jint(ms))
      self.wall = self.wall + ms.to_int64()
    },
    stand_in,
  }
}

///|
fn World::log(self : World) -> Log {
  {
    say: (level, area, words, _fields) =>
      self.logs.push(Arr([js(level), js(area), js(words)])),
  }
}

///|
fn World::disk(self : World) -> Disk {
  {
    read: async fn(path) { self.files.get(path) },
    write_private: async fn(path, bytes) {
      self.files[path] = bytes
      self.writes.push(Arr([js("private"), js(path)]))
    },
    mkdir: async fn(path) { self.writes.push(Arr([js("mkdir"), js(path)])) },
    put_new: async fn(path, bytes) {
      if self.files.contains(path) {
        raise FeishuError("EEXIST: file already exists, open '\{path}'")
      }
      self.files[path] = bytes
      self.writes.push(Arr([js("new"), js(path)]))
    },
  }
}

///|
/// What sits on the case's runtime is let go of as far as it goes now (what waits on its clock waits).
fn settle(rt : @effect.Runtime) -> Unit {
  rt.advance(0)
}

///|
/// One step, run on `rt` till it waits on the clock: its outcome, or `{pending: true}` where it still waits.
fn step_outcome(rt : @effect.Runtime, f : async () -> JV) -> JV {
  let fiber = rt.fork(f)
  settle(rt)
  match fiber.poll() {
    Some(Succeeded(v)) => jobj([("ok", Some(v))])
    Some(Failed(e)) => jobj([("error", Some(js(error_words(e))))])
    Some(Interrupted) => jobj([("error", Some(js("interrupted")))])
    None => jobj([("pending", Some(Bool(true)))])
  }
}

///|
fn answered_jv(a : Answered) -> JV {
  match a {
    Data(d) => jobj([("data", Some(d))])
    File(bytes, ct, disposition) =>
      jobj([
        (
          "file",
          Some(
            jobj([
              ("hex", Some(js(@codec.hex_encode(bytes)))),
              ("contentType", Some(js(ct))),
              ("disposition", Some(js(disposition))),
            ]),
          ),
        ),
      ])
  }
}

///|
fn query_of(v : JV?) -> Array[(String, String)] {
  match v {
    Some(Obj(_) as o) => jkeys(o).map(k => (k, js_string(o.get(k))))
    _ => []
  }
}

///|
fn files_of(v : JV?) -> Array[FilePart] {
  jitems(v).map(f => {
    field: text(jget(Some(f), "field")),
    bytes: bytes_of_hex(text(jget(Some(f), "hex"))),
    name: text(jget(Some(f), "name")),
    mime: text(jget(Some(f), "mime")),
  })
}

///|
/// A FeishuClient through a case's steps.
fn client_case(c : JV) -> JV {
  let world = World::new(c)
  let rt = @effect.Runtime::new()
  let client = FeishuClient::new(
    world.net(),
    text(jget(Some(c), "appId")),
    text(jget(Some(c), "appSecret")),
    domain=text(jget(Some(c), "domain")),
    base=text(jget(Some(c), "base")),
  )
  let results = []
  for step in jitems(jget(Some(c), "steps")) {
    let s = Some(step)
    let r = match text(jget(s, "call")) {
      "pass" => {
        world.wall = world.wall + num_of(jget(s, "ms")).to_int64()
        JV::Null
      }
      "tenantToken" => step_outcome(rt, async fn() { js(client.tenant_token()) })
      "api" =>
        step_outcome(rt, async fn() {
          answered_jv(
            client.api(
              text(jget(s, "method")),
              text(jget(s, "path")),
              body=match jget(s, "body") {
                None | Some(Null) => None
                b => b
              },
              query=query_of(jget(s, "query")),
              files=files_of(jget(s, "files")),
              take_file=jget(s, "takeFile") == Some(Bool(true)),
            ),
          )
        })
      "resource" =>
        step_outcome(rt, async fn() {
          js(
            @codec.hex_encode(
              client.resource(
                text(jget(s, "message")),
                text(jget(s, "key")),
                text(jget(s, "type")),
              ),
            ),
          )
        })
      "endpoint" =>
        step_outcome(rt, async fn() {
          let (url, ping) = client.endpoint()
          jobj([("url", Some(js(url))), ("pingMs", Some(Num(ping)))])
        })
      "post" =>
        step_outcome(rt, async fn() {
          registration_post(
            world.net(),
            text(jget(s, "domain")),
            query_of(jget(s, "form")),
          )
        })
      other => jobj([("error", Some(js("no such call: \{other}")))])
    }
    results.push(r)
  }
  jobj([
    ("results", Some(Arr(results))),
    ("requests", Some(Arr(world.seen))),
    ("sleeps", Some(Arr(world.sleeps))),
  ])
}

///|
fn thread_of(v : JV?) -> ThreadRef {
  { channel: text(jget(v, "channel")), thread_ts: text(jget(v, "threadTs")) }
}

///|
fn person_jv(p : Person?) -> JV {
  match p {
    Some(p) => p.to_jv()
    None => Null
  }
}

///|
/// A NameBook in memory (connects/names.ts as far as the surface asks it): what it knows of each key, the age it says
/// each is, and a key it does not know (or knows stale) read by its fetch in the background.
fn book_of(world : World, rt : @effect.Runtime, c : JV) -> NameBook {
  let people : Map[String, Person] = Map([])
  match jget(Some(c), "people") {
    Some(Obj(fields)) =>
      for f in fields {
        people[f.0] = {
          name: text(jget(Some(f.1), "name")),
          email: text(jget(Some(f.1), "email")),
        }
      }
    _ => ()
  }
  let channels : Map[String, String?] = Map([])
  let age = num_of(jget(Some(c), "bookAge"))
  {
    person: (key, fetch, stale) => {
      let known = people.get(key)
      match known {
        Some(k) if !stale(k, age) => known
        _ => {
          ignore(
            rt.fork(async fn() {
              match (try fetch() catch { _ => None }) {
                Some(p) => people[key] = p
                None => ()
              }
              world.logs.push(Arr([js("book"), js("person"), js(key)]))
            }),
          )
          known
        }
      }
    },
    channel: (key, fetch) => {
      match channels.get(key) {
        Some(n) => n
        None => {
          ignore(
            rt.fork(async fn() {
              let n = try fetch() catch { _ => None }
              channels[key] = n
              world.logs.push(Arr([js("book"), js("channel"), js(key)]))
            }),
          )
          None
        }
      }
    },
  }
}

///|
fn chat_message_jv(m : ChatMessage?) -> JV {
  match m {
    Some(m) => m.to_jv()
    None => Null
  }
}

///|
/// A FeishuSurface through a case's steps: what it answered, what it gave the station (`events`), what it asked of
/// Feishu, what it sent on its socket, what it logged, and its threads' file at the end.
async fn surface_case(c : JV) -> JV {
  let world = World::new(c)
  let rt = @effect.Runtime::new()
  let threads_path = path_or(c, "/data/feishu-threads.json")
  match jget(Some(c), "threadsFile") {
    Some(Str(t)) => world.files[threads_path] = utf8(t)
    _ => ()
  }
  let threads = FeishuThreads::open(world.disk(), world.log(), threads_path)
  let net = world.net()
  let book = if jget(Some(c), "book") == Some(Bool(true)) {
    Some(book_of(world, rt, c))
  } else {
    None
  }
  let surface = FeishuSurface::new({
    connect: text(jget(Some(c), "connect")),
    app_id: text(jget(Some(c), "appId")),
    app_secret: text(jget(Some(c), "appSecret")),
    domain: text(jget(Some(c), "domain")),
    threads,
    thread_mode: jget(Some(c), "threadMode") == Some(Bool(true)),
    direct_threads: jget(Some(c), "directThreads") == Some(Bool(true)),
    book,
    client: Some(
      FeishuClient::new(
        net,
        text(jget(Some(c), "appId")),
        text(jget(Some(c), "appSecret")),
        domain=text(jget(Some(c), "domain")),
        base="https://fake.test",
      ),
    ),
    net,
    words: words(),
    log: world.log(),
    disk: world.disk(),
    rt,
  })
  match jget(Some(c), "me") {
    Some(Obj(_) as me) => surface.me = Some(identity_of_jv(Some(me)))
    _ => ()
  }
  let events = []
  let fails = jitems(jget(Some(c), "handlerFails"))
  let handler = async fn(event : JV) {
    events.push(event)
    let ts = text(jget(jget(Some(event), "message"), "ts"))
    if fails.contains(js(ts)) {
      raise FeishuError("the store refused it")
    }
  }
  let sent = []
  let results = []
  for step in jitems(jget(Some(c), "steps")) {
    let s = Some(step)
    let r = match text(jget(s, "call")) {
      "advance" => {
        rt.advance(num_of(jget(s, "ms")).to_int())
        JV::Null
      }
      "take" =>
        step_outcome(rt, async fn() {
          or_null(surface.take(or_null(jget(s, "envelope")), handler))
        })
      "post" =>
        step_outcome(rt, async fn() {
          js(
            surface.post(
              thread_of(jget(s, "thread")),
              text(jget(s, "message")),
              jitems(jget(s, "files")).map(f => {
                path: text(jget(Some(f), "path")),
                name: text(jget(Some(f), "name")),
              }),
              card=match jget(s, "card") {
                None | Some(Null) => None
                x => x
              },
            ),
          )
        })
      "places" =>
        step_outcome(rt, async fn() {
          Arr(
            surface
            .places()
            .map(p => jobj([
              ("id", Some(js(p.id))),
              ("name", Some(js(p.name))),
              ("kind", Some(js(p.kind))),
            ])),
          )
        })
      "peopleIn" =>
        step_outcome(rt, async fn() {
          Arr(
            surface
            .people_in(text(jget(s, "chat")))
            .map(m => jobj([("id", Some(js(m.id))), ("name", Some(js(m.name)))])),
          )
        })
      "permalink" =>
        step_outcome(rt, async fn() {
          js(surface.permalink(thread_of(jget(s, "thread"))))
        })
      "begin" =>
        step_outcome(rt, async fn() {
          let (t, ts) = surface.begin(text(jget(s, "chat")), text(jget(s, "message")))
          jobj([
            (
              "thread",
              Some(
                jobj([
                  ("channel", Some(js(t.channel))),
                  ("threadTs", Some(js(t.thread_ts))),
                ]),
              ),
            ),
            ("ts", Some(js(ts))),
          ])
        })
      "cardEnded" =>
        step_outcome(rt, async fn() {
          surface.card_ended(
            thread_of(jget(s, "thread")),
            text(jget(s, "ts")),
            text(jget(s, "said")),
            jget(s, "card"),
            end_of(jget(s, "end")),
          )
          Null
        })
      "edit" =>
        step_outcome(rt, async fn() {
          Bool(
            surface.edit(
              thread_of(jget(s, "thread")),
              text(jget(s, "ts")),
              text(jget(s, "message")),
            ),
          )
        })
      "download" =>
        step_outcome(rt, async fn() {
          let f = jget(s, "file")
          js(
            @codec.hex_encode(
              surface.download({
                id: text(jget(f, "id")),
                name: text(jget(f, "name")),
                size: 0,
                url: opt_text(jget(f, "url")),
              }),
            ),
          )
        })
      "userName" =>
        step_outcome(rt, async fn() { jopt(surface.user_name(text(jget(s, "user")))) })
      "userEmail" =>
        step_outcome(rt, async fn() { jopt(surface.user_email(text(jget(s, "user")))) })
      "userOf" =>
        step_outcome(rt, async fn() { jopt(surface.user_of(text(jget(s, "email")))) })
      "knownPerson" =>
        step_outcome(rt, async fn() {
          person_jv(surface.known_person(text(jget(s, "user"))))
        })
      "knownChannel" =>
        step_outcome(rt, async fn() {
          jopt(surface.known_channel(text(jget(s, "channel"))))
        })
      "channelName" =>
        step_outcome(rt, async fn() {
          jopt(surface.channel_name(text(jget(s, "channel"))))
        })
      "history" =>
        step_outcome(rt, async fn() {
          Arr(
            surface
            .history(
              thread_of(jget(s, "thread")),
              text(jget(s, "before")),
              num_of(jget(s, "limit")).to_int(),
            )
            .map(m => m.to_jv()),
          )
        })
      "quoted" =>
        step_outcome(rt, async fn() {
          chat_message_jv(
            surface.quoted(thread_of(jget(s, "thread")), text(jget(s, "ts"))),
          )
        })
      "api" =>
        step_outcome(rt, async fn() {
          answered_jv(
            surface.api(text(jget(s, "method")), nullish(jget(s, "params"), Obj([]))),
          )
        })
      "catchUp" =>
        step_outcome(rt, async fn() {
          surface.catch_up(handler)
          Null
        })
      "identify" =>
        step_outcome(rt, async fn() {
          let i = surface.identify()
          surface.usable(i)
          i.to_jv()
        })
      "address" => step_outcome(rt, async fn() { js(surface.address()) })
      "verify" =>
        step_outcome(rt, async fn() {
          let (i, errors) = verify_feishu_app(
            net,
            words(),
            text(jget(s, "appId")),
            text(jget(s, "appSecret")),
            text(jget(s, "domain")),
            lang=text(jget(s, "lang")),
          )
          Arr([
            match i {
              Some(i) => i.to_jv()
              None => Null
            },
            Arr(errors.map(js)),
          ])
        })
      "mention" => jobj([("ok", Some(js(surface.mention(text(jget(s, "user"))))))])
      "platform" => jobj([("ok", Some(js(surface.platform())))])
      "socket" =>
        step_outcome(rt, async fn() {
          let open = Ref(true)
          let socket : Socket = {
            send: b => sent.push(js(@codec.hex_encode(b))),
            is_open: () => open.val,
          }
          let hooks = surface.socket_hooks(text(jget(s, "url")), handler)
          if jget(s, "open") != Some(Bool(false)) {
            (hooks.opened)(socket)
          }
          for f in jitems(jget(s, "frames")) {
            let bytes = match jget(Some(f), "hex") {
              Some(Str(h)) => bytes_of_hex(h)
              _ => encode(frame_of_jv(or_null(jget(Some(f), "frame"))))
            }
            (hooks.message)(socket, bytes, num_of(jget(Some(f), "now")).to_int64())
            if jget(Some(f), "close") == Some(Bool(true)) {
              open.val = false
            }
          }
          if jget(s, "ping") == Some(Bool(true)) {
            (hooks.ping)(socket)
          }
          Null
        })
      "working" => {
        surface.working(
          thread_of(jget(s, "thread")),
          opt_text(jget(s, "ts")),
          text(jget(s, "status")),
          page=opt_text(jget(s, "page")),
        )
        settle(rt)
        Null
      }
      "me" =>
        jobj([
          (
            "ok",
            Some(
              match surface.me {
                Some(m) => m.to_jv()
                None => Null
              },
            ),
          ),
        ])
      other => jobj([("error", Some(js("no such call: \{other}")))])
    }
    results.push(r)
    settle(rt)
  }
  // (what its threads asked written, written)
  let done = rt.fork(async fn() { threads.written() })
  settle(rt)
  ignore(done)
  jobj([
    ("results", Some(Arr(results))),
    ("events", Some(Arr(events))),
    ("requests", Some(Arr(world.seen))),
    ("sleeps", Some(Arr(world.sleeps))),
    ("sent", Some(Arr(sent))),
    ("logs", Some(Arr(world.logs))),
    (
      "threadsFile",
      Some(
        match world.files.get(threads_path) {
          Some(b) => js(utf8_text(b))
          None => Null
        },
      ),
    ),
  ])
}

///|
/// Where a case keeps its file: where the test's TypeScript keeps it (what a refusal says names it).
fn path_or(c : JV, fallback : String) -> String {
  match jget(Some(c), "path") {
    Some(Str(p)) => p
    _ => fallback
  }
}

///|
/// FeishuThreads through a case's steps.
async fn threads_case(c : JV) -> JV {
  let world = World::new(c)
  let rt = @effect.Runtime::new()
  let path = path_or(c, "/data/feishu-threads.json")
  match jget(Some(c), "file") {
    Some(Str(t)) => world.files[path] = utf8(t)
    _ => ()
  }
  let threads = FeishuThreads::open(world.disk(), world.log(), path)
  let results = []
  for step in jitems(jget(Some(c), "steps")) {
    let s = Some(step)
    let connect = text(jget(s, "connect"))
    let r = step_outcome(rt, async fn() {
      match text(jget(s, "call")) {
        "current" => threads.current(connect, text(jget(s, "chat"))).unwrap_or(Null)
        "begin" => {
          threads.begin(connect, text(jget(s, "chat")), text(jget(s, "message")))
          Null
        }
        "conversations" =>
          Arr(
            threads
            .conversations(connect)
            .map(e => Arr([js(e.0), e.1])),
          )
        "heard" => {
          threads.heard(connect, text(jget(s, "chat")), num_of(jget(s, "when")))
          Null
        }
        "topicRoot" => jopt(threads.topic_root(connect, text(jget(s, "topic"))))
        "heardTopic" => {
          threads.heard_topic(connect, text(jget(s, "topic")), text(jget(s, "root")))
          Null
        }
        other => raise FeishuError("no such call: \{other}")
      }
    })
    results.push(r)
  }
  ignore(rt.fork(async fn() { threads.written() }))
  settle(rt)
  jobj([
    ("results", Some(Arr(results))),
    ("logs", Some(Arr(world.logs))),
    (
      "file",
      Some(
        match world.files.get(path) {
          Some(b) => js(utf8_text(b))
          None => Null
        },
      ),
    ),
  ])
}

///|
/// Registrations through a case's steps: each step's outcome and the file after it.
async fn registrations_case(c : JV) -> JV {
  let world = World::new(c)
  let rt = @effect.Runtime::new()
  let path = path_or(c, "/data/feishu-registrations.json")
  match jget(Some(c), "file") {
    Some(Str(t)) => world.files[path] = utf8(t)
    _ => ()
  }
  let ids = jitems(jget(Some(c), "ids"))
  let next_id = Ref(0)
  let net = world.net(stand_in="https://fake.test")
  let changes = Ref(0)
  let reg = Registrations::new(rt, {
    post: async fn(domain, form) { registration_post(net, domain, form) },
    file: if jget(Some(c), "noFile") == Some(Bool(true)) { None } else { Some(path) },
    disk: world.disk(),
    log: world.log(),
    words: words(),
    random_hex: _ => {
      let id = text(jat(Some(Arr(ids)), next_id.val))
      next_id.val += 1
      id
    },
    exec_path: text(jget(Some(c), "execPath")),
  })
  ignore(reg.on_change(() => changes.val += 1))
  // what a save or a create answers, in order
  let saves = jitems(jget(Some(c), "saves"))
  let next_save = Ref(0)
  let save = async fn(r : Reg) -> String {
    let n = next_save.val
    next_save.val += 1
    world.logs.push(Arr([js("save"), js(js_string(r.field("id")))]))
    match jat(Some(Arr(saves)), n) {
      Some(Obj(_) as x) =>
        match x.get("fail") {
          Some(Str(w)) => raise FeishuError(w)
          _ => text(x.get("ok"))
        }
      _ => "connect-\{n}"
    }
  }
  let results = []
  let files = []
  for step in jitems(jget(Some(c), "steps")) {
    let s = Some(step)
    let r = match text(jget(s, "call")) {
      "advance" => {
        rt.advance(num_of(jget(s, "ms")).to_int())
        JV::Null
      }
      "begin" =>
        step_outcome(rt, async fn() {
          let r = reg.begin(
            text(jget(s, "by")),
            text(jget(s, "domain")),
            opt_text(jget(s, "name")),
            context=or_null(jget(s, "context")),
            workspace=opt_text(jget(s, "workspace")),
          )
          shown_registration(r.jv())
        })
      "cancel" =>
        step_outcome(rt, async fn() {
          Bool(
            reg.cancel(
              text(jget(s, "id")),
              text(jget(s, "by")),
              workspace?=opt_text(jget(s, "workspace")),
            ),
          )
        })
      "complete" =>
        step_outcome(rt, async fn() {
          jopt(
            reg.complete(
              text(jget(s, "id")),
              text(jget(s, "by")),
              text(jget(s, "workspace")),
              save,
            ),
          )
        })
      "start" => {
        reg.start(save)
        settle(rt)
        Null
      }
      "of" =>
        jobj([
          (
            "ok",
            Some(
              Arr(
                reg
                .of(text(jget(s, "by")), workspace?=opt_text(jget(s, "workspace")))
                .map(shown_registration),
              ),
            ),
          ),
        ])
      "get" =>
        jobj([
          (
            "ok",
            Some(
              match reg.get(text(jget(s, "id"))) {
                // (as it is now: the record itself changes on)
                Some(r) => try_parse(stringify(r.jv())).unwrap_or(Null)
                None => Null
              },
            ),
          ),
        ])
      "ready" =>
        step_outcome(rt, async fn() {
          reg.ready()
          Null
        })
      "written" =>
        step_outcome(rt, async fn() {
          reg.written()
          Null
        })
      "close" =>
        step_outcome(rt, async fn() {
          reg.close()
          Null
        })
      other => jobj([("error", Some(js("no such call: \{other}")))])
    }
    results.push(r)
    settle(rt)
    files.push(
      match world.files.get(path) {
        Some(b) => js(utf8_text(b))
        None => Null
      },
    )
  }
  jobj([
    ("results", Some(Arr(results))),
    ("files", Some(Arr(files))),
    ("changes", Some(jint(changes.val))),
    ("requests", Some(Arr(world.seen))),
    ("logs", Some(Arr(world.logs))),
  ])
}

///|
/// feishu_api through a case's steps: a hub of the case's sessions, threads and connects, each connect's API
/// answering from its list.
async fn tool_case(c : JV) -> JV {
  let world = World::new(c)
  let o = Some(c)
  let feishu = jitems(jget(o, "feishu"))
  let is_feishu = (connect : String) => feishu.contains(js(connect))
  let used : Map[String, Int] = Map([])
  let asked = []
  let uuids = jitems(jget(o, "uuids"))
  let next_uuid = Ref(0)
  let tool_world : ToolWorld = {
    session: key => match jget(jget(o, "sessions"), key) {
      Some(Obj(_) as s) =>
        Some((opt_text(s.get("connect")), text(s.get("workspace"))))
      _ => None
    },
    recent_connects: key => jitems(jget(jget(o, "recent"), key)).map(x => text(Some(x))),
    target: (key, to) => {
      if jget(jget(o, "sessions"), key) is None {
        raise FeishuError("unknown session")
      }
      for t in jitems(jget(o, "threads")) {
        if jget(Some(t), "key") == Some(js(key)) && jget(Some(t), "to") == Some(to) {
          return text(jget(Some(t), "connect"))
        }
      }
      raise FeishuError("\{js_string(Some(to))} is not a conversation of this session")
    },
    chat_api: connect => match jget(jget(o, "connected"), connect) {
      Some(Arr(list)) =>
        Some(async fn(meth, params) {
          asked.push(JV::Arr([js(connect), js(meth), params]))
          let n = used.get(connect).unwrap_or(0)
          used[connect] = n + 1
          let spec = list[@cmp.minimum(n, list.length() - 1)]
          match jget(Some(spec), "fail") {
            Some(Str(w)) => raise FeishuError(w)
            _ => ()
          }
          match jget(Some(spec), "file") {
            Some(f) =>
              File(
                bytes_of_hex(text(jget(Some(f), "hex"))),
                text(jget(Some(f), "contentType")),
                text(jget(Some(f), "disposition")),
              )
            None => Data(or_null(jget(Some(spec), "data")))
          }
        })
      _ => None
    },
    now: () => num_of(jget(o, "now")).to_int64(),
    uuid: () => {
      // (the last one again once the others are used, as the test's)
      let u = text(jat(Some(Arr(uuids)), next_uuid.val))
      if next_uuid.val < uuids.length() - 1 {
        next_uuid.val += 1
      }
      u
    },
    disk: world.disk(),
    sep: "/",
  }
  let rt = @effect.Runtime::new()
  let results = []
  for step in jitems(jget(o, "steps")) {
    let s = Some(step)
    results.push(
      step_outcome(rt, async fn() {
        let w = if jget(o, "starting") == Some(Bool(true)) {
          None
        } else {
          Some(tool_world)
        }
        js(
          feishu_api_run(
            w,
            is_feishu,
            text(jget(s, "key")),
            nullish(jget(s, "args"), Obj([])),
          ),
        )
      }),
    )
  }
  let written = JV::Obj([])
  for p, b in world.files {
    jput(written, p, js(@codec.hex_encode(b)))
  }
  jobj([
    ("results", Some(Arr(results))),
    ("asked", Some(Arr(asked))),
    ("files", Some(written)),
    ("writes", Some(Arr(world.writes))),
  ])
}

///|
/// One case by its `op`.
pub async fn harness_case(c : JV) -> JV {
  let o = Some(c)
  match text(jget(o, "op")) {
    "catalog" => {
      said.catalog = @ops_platform.Catalog::from_json(
        or_null(jget(o, "zh")).to_json(),
        or_null(jget(o, "en")).to_json(),
      )
      said.lang = text(jget(o, "lang"))
      jobj([("ok", Some(Null))])
    }
    "pure" => outcome(() => pure_case(c))
    "parts" => jobj([("ok", Some(parts_case(c)))])
    "client" => jobj([("ok", Some(client_case(c)))])
    "surface" => jobj([("ok", Some(surface_case(c)))])
    "threads" => jobj([("ok", Some(threads_case(c)))])
    "registrations" => jobj([("ok", Some(registrations_case(c)))])
    "tool" => jobj([("ok", Some(tool_case(c)))])
    op => jobj([("error", Some(js("no such case: \{op}")))])
  }
}

///|
/// The program's harness: a case a line, answered a line each, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  while true {
    guard host.line() is Some(line) else { break }
    let answer = match try_parse(line) {
      Some(c) =>
        harness_case(c) catch {
          e => jobj([("error", Some(js(error_words(e))))])
        }
      None => jobj([("error", Some(js("not JSON")))])
    }
    host.say(stringify(answer))
  }
}
