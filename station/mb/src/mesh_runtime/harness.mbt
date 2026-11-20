// The program `stillfail-reader --builder harness-mesh-runtime` (station/test/mb-mesh-runtime.test.ts): this package
// asked line by line, as the test asks the TypeScript it is written from on the same inputs. Each line `{id, op, …}` is
// answered `{id, value}` or `{id, error}` once what it set going is done:
//
// - `call` `{fn, args}`: one of the functions, its answer;
// - `new` `{kind, as, args}` and `do` `{on, method, args}`: one of the things that keep state (a pacer, a sizer, the
//   traces, …) made under a name, and asked;
// - `now` `{ms}`, `stalled` `{ms}`, `hr` `{ns}`: the clocks they read (the view's, the loop's stands, the monotonic one),
//   the test's; `advance` `{ms}`: the clock the traces' batching waits on, moved. The traces' `fail` `{times, error?}`:
//   so many batches refused with these words.

///|
priv struct Harness {
  rt : @effect.Runtime
  front : FrontHarness
  now : Ref[Double]
  stalled : Ref[Double]
  hr : Ref[Int64]
  pacers : Map[String, Pacer]
  sharpeners : Map[String, Sharpener]
  sizers : Map[String, Sizer]
  latencies : Map[String, FrameLatency]
  losses : Map[String, LinkLoss]
  stalls : Map[String, (LoopStall, Ref[(() -> Unit)?], Map[String, () -> Unit])]
  traces : Map[String, (Traces, Array[Json], Array[Json], Ref[Int], Ref[String])]
  spans : Map[String, Span]
  follows : Map[String, (NetworkFollow, Array[Json], Ref[Bool])]
  tells : Map[String, (LockWorld, Array[Json], () -> Unit)]
  told : Map[String, ServedTold]
  queues : Map[String, PieceQueue]
  screens : Map[String, ScreenWorld]
  serveds : Map[String, ServedWorld]
  words : Map[String, String]
}

///|
/// The locks a test's tells read, set as it says.
priv struct LockWorld {
  mut memberships : Array[(String, Bool)]
  heads : Map[String, Json]
  forces : Map[String, String]
  chains : Map[String, Array[Json]]
  cloud : Array[() -> Unit]
  chain : Array[(String) -> Unit]
}

///|
fn arg(args : Json, k : String) -> Json? {
  field(args, k)
}

///|
fn strs(v : Json?) -> Array[String] {
  match v {
    Some(Array(xs)) => xs.filter_map(x => if x is String(s) { Some(s) } else { None })
    _ => []
  }
}

///|
fn arr(v : Json?) -> Array[Json] {
  match v {
    Some(Array(xs)) => xs
    _ => []
  }
}

///|
fn opt_json(v : Double?) -> Json {
  match v {
    Some(n) => jnum(n)
    None => Json::null()
  }
}

///|
fn hex_arg(v : Json?) -> Bytes {
  match v {
    Some(String(h)) => @hex.decode(h[:]) catch { _ => b"" }
    _ => b""
  }
}

///|
fn hexj(b : Bytes) -> Json {
  jstr(@hex.encode(b[:]))
}

///|
fn bounds_arg(v : Json?) -> Bounds {
  {
    max_width: num_of(v.bind(x => field(x, "maxWidth"))).unwrap_or(0.0),
    max_height: num_of(v.bind(x => field(x, "maxHeight"))).unwrap_or(0.0),
  }
}

///|
fn region_json(r : Region?) -> Json {
  match r {
    Some(r) => r.to_json()
    None => Json::null()
  }
}

///|
fn clip_arg(v : Json?) -> Clip {
  match v.bind(x => field(x, "type")) {
    Some(String("png")) => Png(hex_arg(v.bind(x => field(x, "data"))))
    _ => Text(str_of(v.bind(x => field(x, "text"))).unwrap_or(""))
  }
}

///|
fn clip_json(c : Clip) -> Json {
  match c {
    Text(t) => jobj([("type", jstr("text")), ("text", jstr(t))])
    Png(d) => jobj([("type", jstr("png")), ("data", hexj(d))])
  }
}

///|
fn paths_arg(v : Json?) -> Array[WayPath] {
  arr(v).map(WayPath::of_json)
}

///|
fn parent_arg(v : Json?) -> Parent? {
  match v {
    Some(Object(_) as p) =>
      Some({
        trace: str_of(field(p, "trace")).unwrap_or(""),
        span: str_of(field(p, "span")).unwrap_or(""),
        sampled: field(p, "sampled") is Some(True),
      })
    _ => None
  }
}

///|
fn pieces_of(chunks : Array[Bytes]) -> Pieces {
  let at = Ref(0)
  {
    next: async fn() -> Bytes? {
      if at.val >= chunks.length() {
        None
      } else {
        at.val += 1
        Some(chunks[at.val - 1])
      }
    },
    stop: async fn() { at.val = chunks.length() },
  }
}

///|
/// The tools' deps as a test says them: what the station's state is, and what each op run answers (`result`: `{value}`,
/// `{code, message}` refused, `{throw}` failed).
fn tools_deps(a : Json, said : Array[Json], ran : Array[Json]) -> ToolsDeps {
  let result = arg(a, "result").unwrap_or(Json::null())
  {
    enabled: () => arg(a, "enabled") is Some(True),
    workspace: () => str_of(arg(a, "workspace")),
    removed: () => arg(a, "removed") is Some(True),
    gateway_keys: () => strs(arg(a, "gateways")),
    run: async fn(op, args, context) {
      ran.push(jobj([("op", jstr(op)), ("args", args), ("context", context)]))
      match result {
        { "throw": String(m), .. } => raise Failure(m)
        { "code": String(code), "message": String(message), .. } => Err((code, message))
        { "value": v, .. } => Ok(v)
        _ => Ok(Json::null())
      }
    },
    said: (level, words, with_) => said.push(jobj([("level", jstr(level)), ("words", jstr(words)), ("with", with_)])),
  }
}

///|
/// A connection of one stream in memory, its bytes those given: what was written on it, whether it was finished, and
/// how the connection was closed.
fn one_stream(chunks : Array[Bytes], peer : String) -> (@door.Connection, Array[Bytes], Ref[Bool], Ref[Json]) {
  let written = []
  let finished = Ref(false)
  let closed = Ref(Json::null())
  let at = Ref(0)
  let given = Ref(false)
  let stream : @door.Stream = {
    read: async fn() -> Bytes? {
      if at.val >= chunks.length() {
        None
      } else {
        at.val += 1
        Some(chunks[at.val - 1])
      }
    },
    write: async fn(b) { written.push(b) },
    finish: async fn() { finished.val = true },
    stopped: async fn() -> Int? { None },
    reset: async fn(_) {  },
  }
  let conn : @door.Connection = {
    remote_id: () => peer,
    alpn: () => tools_alpn,
    via: () => None,
    paths: None,
    accept_bi: async fn() -> @door.Stream? {
      if given.val {
        None
      } else {
        given.val = true
        Some(stream)
      }
    },
    open_bi: async fn() -> @door.Stream { raise Failure("no streams opened") },
    answers: None,
    stats: None,
    close: (code, reason) => closed.val = Json::array([jnum(code.to_double()), jstr(reason)]),
    is_closed: () => closed.val is Array(_),
    closed: async fn() -> String { "" },
    close_reason: None,
    handed: None,
  }
  (conn, written, finished, closed)
}

///|
/// The functions held to their TypeScript by name.
async fn Harness::call(self : Harness, name : String, a : Json) -> Json {
  match name {
    "congestionOf" => jstr(congestion_of(arg(a, "raw")))
    "checkNetwork" =>
      match check_network(arg(a, "raw")) {
        Some(e) => jobj([("error", jstr(e))])
        None => jobj([("ok", Json::boolean(true))])
      }
    "networkView" => network_view(arg(a, "raw"))
    "bindStation" =>
      bind_station(arg(a, "options").unwrap_or(Json::object(Map([]))), str_of(arg(a, "bindAddr")), str_of(arg(a, "dscp")))
    "privateV4" => Json::boolean(private_v4(str_of(arg(a, "ip")).unwrap_or("")))
    "tailnetV4" => Json::boolean(tailnet_v4(str_of(arg(a, "ip")).unwrap_or("")))
    "lanAddrs" =>
      Json::array(lan_addrs(strs(arg(a, "sockets")), interfaces_of_json(arg(a, "interfaces").unwrap_or(Json::null()))).map(jstr))
    "tailnetAddrs" =>
      Json::array(tailnet_addrs(strs(arg(a, "sockets")), interfaces_of_json(arg(a, "interfaces").unwrap_or(Json::null()))).map(jstr))
    "lanNeighbours" => Json::array(lan_neighbours(interfaces_of_json(arg(a, "interfaces").unwrap_or(Json::null()))).map(jstr))
    "lanReach" => {
      let codes = arg(a, "codes").unwrap_or(Json::null())
      let reach = lan_reach(strs(arg(a, "neighbours")), async fn(ip) { str_of(field(codes, ip)) })
      match reach {
        Some(r) => jstr(r)
        None => Json::null()
      }
    }
    "jsNumber" => {
      let n = js_number(str_of(arg(a, "s")).unwrap_or(""))
      if n.is_nan() {
        jstr("NaN")
      } else {
        jnum(n)
      }
    }
    "parseParent" =>
      match parse_parent(str_of(arg(a, "header"))) {
        Some(p) => p.to_json()
        None => Json::null()
      }
    "route" => jstr(route(str_of(arg(a, "path")).unwrap_or("")))
    "attribute" => attribute(str_of(arg(a, "key")).unwrap_or(""), arg(a, "value").unwrap_or(Json::null()))
    "otlpBody" =>
      jstr(
        otlp_body(
          str_of(arg(a, "station")).unwrap_or(""),
          arr(arg(a, "spans")),
          resource=arr(arg(a, "resource")).map(kv => match kv {
            Array([String(k), String(v)]) => (k, v)
            _ => ("", "")
          }),
        ),
      )
    "ownRate" => jnum(own_rate(num_of(arg(a, "width")).unwrap_or(0.0), num_of(arg(a, "height")).unwrap_or(0.0)))
    "rateCeiling" =>
      jnum(
        rate_ceiling(num_of(arg(a, "width")).unwrap_or(0.0), num_of(arg(a, "height")).unwrap_or(0.0), str_of(arg(a, "quality"))),
      )
    "isFps" => Json::boolean(is_fps(arg(a, "v")))
    "queueMs" => jnum(queue_ms(num_of(arg(a, "rtt")).unwrap_or(0.0)))
    "startRate" => jnum(start_rate_for(arg(a, "paths")))
    "cursorPayload" => hexj(cursor_payload(arg(a, "cursor").unwrap_or(Json::null())))
    "frame" => hexj(frame(num_of(arg(a, "kind")).unwrap_or(0.0).to_int(), hex_arg(arg(a, "payload"))))
    "configPayload" => {
      let c = arg(a, "config").unwrap_or(Json::null())
      let description = match field(c, "description") {
        Some(String(_)) as d => Some(hex_arg(d))
        _ => None
      }
      hexj(
        config_payload(
          str_of(field(c, "codec")).unwrap_or(""),
          num_of(field(c, "width")).unwrap_or(0.0),
          num_of(field(c, "height")).unwrap_or(0.0),
          description,
          match field(c, "region") {
            Some(Object(_) as r) =>
              Some({
                x: num_of(field(r, "x")).unwrap_or(0.0),
                y: num_of(field(r, "y")).unwrap_or(0.0),
                w: num_of(field(r, "w")).unwrap_or(0.0),
                h: num_of(field(r, "h")).unwrap_or(0.0),
              })
            _ => None
          },
        ),
      )
    }
    "videoPayload" => {
      let f = arg(a, "frame").unwrap_or(Json::null())
      hexj(video_payload(field(f, "key") is Some(True), num_of(field(f, "ts")).unwrap_or(0.0), hex_arg(field(f, "data"))))
    }
    "privateClipPayload" =>
      hexj(private_clip_payload(clip_arg(arg(a, "clip")), num_of(arg(a, "privacy")).unwrap_or(0.0).to_int()))
    "clipPayload" => hexj(clip_payload(clip_arg(arg(a, "clip")), flags=num_of(arg(a, "flags")).map(n => n.to_int())))
    "parseClip" =>
      match parse_clip(hex_arg(arg(a, "payload"))) {
        Some((clip, paste)) => {
          let shown = match (clip_json(clip), privacy_name(parse_clip_privacy(hex_arg(arg(a, "payload"))))) {
            (Object(m), Some(p)) => {
              m["privacy"] = jstr(p)
              Json::object(m)
            }
            (j, _) => j
          }
          jobj([("clip", shown), ("paste", Json::boolean(paste))])
        }
        None => Json::null()
      }
    "regionOf" => region_json(region_of(arg(a, "v")))
    "parseScale" => opt_json(parse_scale(arg(a, "v").unwrap_or(Json::null())))
    "parseResolution" =>
      match parse_resolution(arg(a, "v").unwrap_or(Json::null())) {
        Some((w, h)) => jobj([("width", jnum(w)), ("height", jnum(h))])
        None => Json::null()
      }
    "parseReveal" =>
      match parse_reveal(arg(a, "v").unwrap_or(Json::null())) {
        Some(p) => jstr(p)
        None => Json::null()
      }
    "parseFill" => parse_fill(arg(a, "v").unwrap_or(Json::null())).unwrap_or(Json::null())
    "parsePasskey" => parse_passkey(arg(a, "v").unwrap_or(Json::null())).unwrap_or(Json::null())
    "parseLook" =>
      match parse_look(hex_arg(arg(a, "payload")), bounds_arg(arg(a, "own"))) {
        Some((region, b)) =>
          jobj([("region", region_json(region)), ("maxWidth", jnum(b.max_width)), ("maxHeight", jnum(b.max_height))])
        None => Json::null()
      }
    "parseWindowPick" =>
      match parse_window_pick(arg(a, "v").unwrap_or(Json::null())) {
        NotOne => jstr("undefined")
        Whole => Json::null()
        Window(n) => jnum(n)
      }
    "parseInput" => parse_input(arg(a, "v").unwrap_or(Json::null())).unwrap_or(Json::null())
    "asked" => asked(arg(a, "screen").unwrap_or(Json::object(Map([]))))
    "limitIn" => jnum(limit_in(num_of(arg(a, "kind")).unwrap_or(0.0).to_int()).to_double())
    "frameIn" => {
      let chunks = arr(arg(a, "chunks")).map(c => hex_arg(Some(c)))
      let at = Ref(0)
      let read = async fn() -> Bytes? {
        if at.val >= chunks.length() {
          None
        } else {
          at.val += 1
          Some(chunks[at.val - 1])
        }
      }
      let limit = match num_of(arg(a, "limit")) {
        Some(n) => (_ : Int) => n.to_int()
        None => limit_in
      }
      let frames = FrameIn::new(read, carry=hex_arg(arg(a, "carry")), limit~)
      let out = []
      while true {
        let got : Result[(Int, Bytes)?, Error] = try { Ok(frames.next()) } catch { e => Err(e) }
        match got {
          Ok(Some((kind, payload))) => out.push(jobj([("kind", jnum(kind.to_double())), ("payload", hexj(payload))]))
          Ok(None) => break
          Err(e) => {
            out.push(jobj([("error", jstr(message_of(e)))]))
            break
          }
        }
      }
      Json::array(out)
    }
    "subOf" =>
      match sub_of(arr(arg(a, "chain"))) {
        Some(s) => jstr(s)
        None => Json::null()
      }
    "pathsOf" => jstr(paths_of(paths_arg(arg(a, "paths"))))
    "sentOn" => Json::array(sent_on(paths_arg(arg(a, "paths"))).map(kv => Json::array([jstr(kv.0), jnum(kv.1)])))
    "slowLine" =>
      slow_line(
        sent_on(paths_arg(arg(a, "before"))),
        num_of(arg(a, "code")).map(n => n.to_int()),
        num_of(arg(a, "ms")).unwrap_or(0.0),
        paths_arg(arg(a, "paths")),
        () => str_of(arg(a, "route")).unwrap_or(""),
        num_of(arg(a, "bytes")).unwrap_or(0.0),
        num_of(arg(a, "made")).unwrap_or(0.0),
        str_of(arg(a, "device")).unwrap_or(""),
      ).unwrap_or(Json::null())
    "tools" => {
      let said = []
      let ran = []
      let d = tools_deps(a, said, ran)
      let reply = match str_of(arg(a, "over")) {
        Some("presence") => presence_tools(d, arg(a, "head"))
        _ => {
          let peer = str_of(arg(a, "peer")).unwrap_or("")
          tools_answer(d, arg(a, "head"), () => tools_refusal(d, peer))
        }
      }
      let refusal = match tools_refusal(d, str_of(arg(a, "peer")).unwrap_or("")) {
        Some(r) => jstr(r)
        None => Json::null()
      }
      jobj([("reply", reply), ("said", Json::array(said)), ("ran", Json::array(ran)), ("refusal", refusal)])
    }
    "toolsStatus" => tools_status(arr(arg(a, "turns")))
    "toolsThreadStatus" => {
      // (`threads`: each thread's id and its sessions' last turns, null for none; no `threads`: no store)
      let threads = arg(a, "threads")
      let store : ToolsStore? = match threads {
        Some(Object(m)) =>
          Some({
            has_thread: id => m.contains(js_num(id)),
            thread_sessions: id => match m.get(js_num(id)) {
              Some(Array(turns)) => turns.mapi((i, _) => "\{js_num(id)}/\{i}")
              _ => []
            },
            last_turn: k => {
              let parts = k.split("/").map(p => p.to_owned()).to_array()
              match m.get(parts[0]) {
                Some(Array(turns)) =>
                  match turns.get(@string.parse_int(parts[1]) catch { _ => -1 }) {
                    Some(Null) | None => None
                    t => t
                  }
                _ => None
              }
            },
          })
        _ => None
      }
      tools_thread_status(store, str_of(arg(a, "thread")).unwrap_or("")).unwrap_or(Json::null())
    }
    "adminAnswered" =>
      match admin_answered(num_of(arg(a, "status")).unwrap_or(0.0).to_int(), str_of(arg(a, "text")).unwrap_or("")) {
        Ok(v) => jobj([("value", v)])
        Err((message, code)) => jobj([("error", jstr(message)), ("code", jstr(code))])
      }
    "encodeURIComponent" => jstr(encode_uri_component(str_of(arg(a, "s")).unwrap_or("")))
    "toolsChat" => {
      // (`ask` answers each request with the next of `answers`, as the admin API answered: status and text)
      let answers = arr(arg(a, "answers"))
      let asked = []
      let next = Ref(0)
      let ask : Ask = async fn(requester, verb, path, body) {
        asked.push(jobj([("as", jstr(requester)), ("method", jstr(verb)), ("path", jstr(path)), ("body", body)]))
        let answer = if next.val < answers.length() { answers[next.val] } else { Json::null() }
        next.val += 1
        match
          admin_answered(num_of(field(answer, "status")).unwrap_or(200.0).to_int(), str_of(field(answer, "text")).unwrap_or("")) {
          Ok(v) => v
          Err((message, code)) => raise AdminRefused(message, code)
        }
      }
      let result = try {
        match str_of(arg(a, "say")) {
        Some(thread) => {
          tools_say(ask, thread, str_of(arg(a, "text")).unwrap_or(""), str_of(arg(a, "requester")).unwrap_or(""))
          Json::null()
        }
        None => {
          let (session, thread) = tools_start(
            ask,
            strs(arg(a, "runtimes")),
            strs(arg(a, "kinds")),
            str_of(arg(a, "prompt")).unwrap_or(""),
            match arg(a, "title") { Some(String(t)) => Some(t); _ => None },
            str_of(arg(a, "runtime")),
            str_of(arg(a, "requester")).unwrap_or(""),
          )
          jobj([("session", jstr(session)), ("thread", jstr(thread))])
        }
        }
      } catch {
        AdminRefused(message, code) => jobj([("error", jstr(message)), ("code", jstr(code))])
        e => jobj([("error", jstr(message_of(e)))])
      }
      jobj([("result", result), ("asked", Json::array(asked))])
    }
    "words" => {
      if arg(a, "words") is Some(Object(m)) {
        for k, v in m {
          self.words[k] = str_of(Some(v)).unwrap_or("")
        }
      }
      Json::null()
    }
    "accessShown" => {
      let words = self.words
      access_shown(arg(a, "access"), str_of(arg(a, "lang")).unwrap_or("zh"), (lang, key, args) => words_tr(words, lang, key, args)).unwrap_or(
        Json::null(),
      )
    }
    "decodeURIComponent" =>
      match decode_uri_component(str_of(arg(a, "s")).unwrap_or("")) {
        Some(d) => jstr(d)
        None => jobj([("error", Json::boolean(true))])
      }
    "langOfCore" => {
      let headers = match arg(a, "headers") {
        Some(Object(m)) => m.to_array().filter_map(kv => match kv.1 { String(v) => Some((kv.0, v)); _ => None })
        _ => []
      }
      jstr(lang_of_core(headers))
    }
    "incoming" => incoming_steps(arr(arg(a, "steps")))
    "bare" => jstr(bare(str_of(arg(a, "url")).unwrap_or("")))
    "servedAgainAfter" => jnum(served_again_after(num_of(arg(a, "ran")).unwrap_or(0.0)))
    "servedRoutes" => Json::array(served_routes.map(jstr))
    "fileBytes" => {
      let content = hex_arg(arg(a, "content"))
      let opened = Ref(0)
      let closed = Ref(0)
      let open = async fn() -> FileReading {
        opened.val += 1
        {
          read_at: async fn(at : Int64, length : Int) -> Bytes {
            let from = if at.to_int() > content.length() { content.length() } else { at.to_int() }
            let to = if from + length > content.length() { content.length() } else { from + length }
            @door.own(content[from:to])
          },
          close: async fn() { closed.val += 1 },
        }
      }
      let pieces = file_bytes(
        open,
        num_of(arg(a, "offset")).unwrap_or(0.0).to_int64(),
        num_of(arg(a, "end")).unwrap_or(0.0).to_int64(),
      )
      let take = num_of(arg(a, "take")).map(n => n.to_int())
      let out = []
      let error = Ref(Json::null())
      let mut n = 0
      while take.map(t => n < t).unwrap_or(true) {
        let got : Result[Bytes?, Error] = try { Ok((pieces.next)()) } catch { e => Err(e) }
        match got {
          Ok(Some(p)) => out.push(jnum(p.length().to_double()))
          Ok(None) => break
          Err(e) => {
            error.val = jstr(message_of(e))
            break
          }
        }
        n += 1
      }
      if take is Some(_) {
        stop_bytes(pieces)
      }
      // (opened once at most, and closed as often)
      if opened.val > 1 || opened.val != closed.val {
        raise Failure("opened \{opened.val} times, closed \{closed.val}")
      }
      jobj([("pieces", Json::array(out)), ("error", error.val)])
    }
    "readBytes" => {
      let chunks = arr(arg(a, "chunks")).map(c => hex_arg(Some(c)))
      let bytes = read_bytes(pieces_of(chunks), num_of(arg(a, "limit")).unwrap_or(0.0).to_int()) catch {
        e => return jobj([("error", jstr(message_of(e)))])
      }
      jobj([("bytes", hexj(bytes))])
    }
    "writeBytes" => {
      let chunks = arr(arg(a, "chunks")).map(c => hex_arg(Some(c)))
      let writes = []
      let n = write_bytes(
        async fn(p, at) { writes.push(Json::array([jnum(at.to_double()), hexj(p)])) },
        pieces_of(chunks),
        num_of(arg(a, "offset")).unwrap_or(0.0).to_int64(),
        num_of(arg(a, "limit")).unwrap_or(0.0).to_int64(),
      ) catch {
        e => return jobj([("error", jstr(message_of(e))), ("writes", Json::array(writes))])
      }
      jobj([("n", jnum(n.to_double())), ("writes", Json::array(writes))])
    }
    "serveTools" => {
      let said = []
      let ran = []
      let d = tools_deps(a, said, ran)
      let chunks = arr(arg(a, "chunks")).map(c => hex_arg(Some(c)))
      let (conn, written, finished, closed) = one_stream(chunks, str_of(arg(a, "peer")).unwrap_or(""))
      let error = serve_tools(d, conn, self.rt) catch { e => Some(message_of(e)) } noraise { _ => None }
      ignore(self.rt.run_ready())
      jobj([
        ("written", jstr(@utf8.decode_lossy(@door.concat(written)[:]))),
        ("finished", Json::boolean(finished.val)),
        ("closed", closed.val),
        ("error", match error { Some(e) => jstr(e); None => Json::null() }),
        ("said", Json::array(said)),
        ("ran", Json::array(ran)),
      ])
    }
    "oneBytes" => {
      let pieces = one_bytes(hex_arg(arg(a, "bytes")))
      let out = []
      while (pieces.next)() is Some(p) {
        out.push(hexj(p))
      }
      Json::array(out)
    }
    _ => raise Failure("no function \{name}")
  }
}

///|
fn Harness::new_(self : Harness, kind : String, name : String, a : Json) -> Json raise {
  let now = self.now
  let clock = () => now.val
  match kind {
    "Pacer" => {
      let stalled = self.stalled
      self.pacers[name] = Pacer::new(clock, start=num_of(arg(a, "start")), fps=num_of(arg(a, "fps")), stalled=() => stalled.val)
    }
    "Sharpener" => self.sharpeners[name] = Sharpener::new()
    "Sizer" => self.sizers[name] = Sizer::new(clock, bounds_arg(arg(a, "asked")), quality=str_of(arg(a, "quality")))
    "FrameLatency" => self.latencies[name] = FrameLatency::new(clock)
    "LinkLoss" => self.losses[name] = LinkLoss::new(clock)
    "LoopStall" => {
      let tick : Ref[(() -> Unit)?] = Ref(None)
      let stall = LoopStall::new(clock, (_, f) => {
        tick.val = Some(f)
        () => tick.val = None
      })
      self.stalls[name] = (stall, tick, Map([]))
    }
    "Traces" => {
      let sent = []
      let said = []
      let failing = Ref(0)
      let error = Ref("the plane is down")
      let hr = self.hr
      let t = Traces::new(
        arg(a, "enabled") is Some(True),
        self.rt,
        () => hr.val,
        (level, words, with_) => said.push(jobj([("level", jstr(level)), ("words", jstr(words)), ("with", with_)])),
        tail_only=arg(a, "tailOnly") is Some(True),
        slow_ms=match arg(a, "slowMs") {
          Some(Number(n, ..)) => n.to_int()
          _ => 1_000
        },
      )
      self.traces[name] = (t, sent, said, failing, error)
    }
    "NetworkFollow" => {
      let calls = []
      let fails = Ref(false)
      let f = NetworkFollow::new(
        arg(a, "raw"),
        c => {
          calls.push(jobj([("set", jstr(c))]))
          if fails.val {
            raise Failure("not now")
          }
        },
        (level, words, with_) => calls.push(jobj([("level", jstr(level)), ("words", jstr(words)), ("with", with_)])),
      )
      self.follows[name] = (f, calls, fails)
    }
    "LockTells" => {
      let world : LockWorld = { memberships: [], heads: Map([]), forces: Map([]), chains: Map([]), cloud: [], chain: [] }
      lock_world_set(world, a)
      let told = []
      let source : LockSource = {
        memberships: () => world.memberships,
        head: ws => world.heads.get(ws.unwrap_or("")),
        force_word: ws => world.forces.get(ws.unwrap_or("")).unwrap_or(""),
        listen_cloud: f => {
          world.cloud.push(f)
          () => world.cloud.clear()
        },
        listen_chains: f => {
          world.chain.push(f)
          () => world.chain.clear()
        },
        kept: g => world.chains.get(g),
      }
      let stop = tell_locks(source, (event, data, of, to) => told.push(
        jobj([("event", jstr(event)), ("data", data), ("of", jstr(of)), ("to", to)]),
      ))
      self.tells[name] = (world, told, stop)
    }
    "ServedTold" => self.told[name] = ServedTold::new()
    "Screen" => self.screens[name] = screen_open(a, self.words)
    "Served" => self.serveds[name] = served_world(a)
    "PieceQueue" => self.queues[name] = PieceQueue::new()
    _ => raise Failure("no kind \{kind}")
  }
  Json::null()
}

///|
fn lock_world_set(world : LockWorld, a : Json) -> Unit {
  if arg(a, "memberships") is Some(Array(ms)) {
    world.memberships = ms.map(m => (str_of(field(m, "workspace")).unwrap_or(""), field(m, "home") is Some(True)))
  }
  if arg(a, "heads") is Some(Object(h)) {
    for k, v in h {
      match v {
        Null => world.heads.remove(k)
        _ => world.heads[k] = v
      }
    }
  }
  if arg(a, "forces") is Some(Object(f)) {
    for k, v in f {
      world.forces[k] = str_of(Some(v)).unwrap_or("")
    }
  }
  if arg(a, "chains") is Some(Object(c)) {
    for k, v in c {
      match v {
        Array(xs) => world.chains[k] = xs
        _ => world.chains.remove(k)
      }
    }
  }
}

///|
async fn Harness::do_(self : Harness, on : String, verb : String, a : Json) -> Json {
  let n = (k : String) => num_of(arg(a, k)).unwrap_or(0.0)
  if self.pacers.get(on) is Some(p) {
    return match verb {
      "sent" => { p.sent(n("ts"), n("bytes")); Json::null() }
      "acked" => {
        let wait = num_of(arg(a, "wait")).unwrap_or(0.0)
        p.acked(n("ts"), viewer_wait_ms=wait)
        Json::null()
      }
      "viewerWait" => jnum(p.viewer_wait())
      "may" => Json::boolean(p.may())
      "backlogged" => Json::boolean(p.backlogged())
      "rate" => opt_json(p.asked_rate())
      "through" => jnum(p.through_rate())
      "rtt" => opt_json(p.rtt())
      "wait" => jnum(p.wait())
      "unacked" => jnum(p.unacked().to_double())
      "ceiling" => { p.set_ceiling(n("rate")); Json::null() }
      _ => raise Failure("no method \{verb}")
    }
  }
  if self.losses.get(on) is Some(l) {
    let paths = arr(arg(a, "paths")).map(LinkPath::of_json)
    return match verb {
      "step" => opt_json(l.step(paths))
      "sample" => opt_json(l.sample(paths))
      _ => raise Failure("no method \{verb}")
    }
  }
  if self.sharpeners.get(on) is Some(s) {
    return match verb {
      "sent" => { s.sent(n("now"), num_of(arg(a, "rate")), key=arg(a, "key") is Some(True)); Json::null() }
      "left" => jnum(s.left(n("now")))
      "due" => Json::boolean(s.due(n("now"), num_of(arg(a, "rate"))))
      "dueMoving" => Json::boolean(s.due_moving(n("now"), num_of(arg(a, "rate"))))
      _ => raise Failure("no method \{verb}")
    }
  }
  if self.sizers.get(on) is Some(s) {
    return match verb {
      "ask" => s.ask(bounds_arg(arg(a, "asked"))).to_json()
      "step" =>
        match s.step(n("rate"), n("through"), n("width"), n("height")) {
          Some(b) => b.to_json()
          None => Json::null()
        }
      "bounds" => s.bounds().to_json()
      "asked" => s.asked_bounds().to_json()
      "low" => Json::boolean(s.is_low())
      _ => raise Failure("no method \{verb}")
    }
  }
  if self.latencies.get(on) is Some(l) {
    return match verb {
      "sent" => { l.sent(n("ts")); Json::null() }
      "acked" => { l.acked(n("ts"), n("rtt")); Json::null() }
      "take" =>
        match l.take() {
          Some((frame, before)) => jobj([("frame", jnum(frame)), ("before", jnum(before))])
          None => Json::null()
        }
      _ => raise Failure("no method \{verb}")
    }
  }
  if self.stalls.get(on) is Some((stall, tick, uses)) {
    return match verb {
      "use" => {
        uses[str_of(arg(a, "as")).unwrap_or("")] = stall.use_()
        Json::null()
      }
      "done" => {
        if uses.get(str_of(arg(a, "as")).unwrap_or("")) is Some(done) {
          done()
        }
        Json::null()
      }
      "tick" => {
        if tick.val is Some(f) {
          f()
        }
        Json::boolean(tick.val is Some(_))
      }
      "stalled" => jnum(stall.stalled())
      "ticking" => Json::boolean(tick.val is Some(_))
      _ => raise Failure("no method \{verb}")
    }
  }
  if self.traces.get(on) is Some((t, sent, said, failing, error)) {
    return match verb {
      "start" => {
        let span = t.start(
          parent_arg(arg(a, "parent")),
          str_of(arg(a, "spanId")).unwrap_or(""),
          n("wallMs").to_int64(),
        )
        match span {
          Some(s) => {
            self.spans[str_of(arg(a, "as")).unwrap_or("")] = s
            jstr(traceparent(s))
          }
          None => Json::null()
        }
      }
      "end" => {
        guard self.spans.get(str_of(arg(a, "span")).unwrap_or("")) is Some(span) else { return Json::null() }
        let attrs = arr(arg(a, "attributes")).map(kv => match kv {
          Array([String(k), v]) => (k, v)
          _ => ("", Json::null())
        })
        t.end(span, str_of(arg(a, "name")).unwrap_or(""), attrs, arg(a, "failed") is Some(True))
        Json::null()
      }
      "export" => {
        t.export_to(async fn(batch) {
          if failing.val > 0 {
            failing.val -= 1
            raise Failure(error.val)
          }
          sent.push(Json::array(batch))
        })
        Json::null()
      }
      "fail" => {
        failing.val = n("times").to_int()
        error.val = str_of(arg(a, "error")).unwrap_or("the plane is down")
        Json::null()
      }
      "spans" => Json::array(t.spans)
      "sent" => Json::array(sent)
      "said" => {
        // (what was said since asked last)
        let out = said.copy()
        said.clear()
        Json::array(out)
      }
      "close" => { t.close(); Json::null() }
      _ => raise Failure("no method \{verb}")
    }
  }
  if self.follows.get(on) is Some((f, calls, fails)) {
    return match verb {
      "told" => { f.told(arg(a, "raw")); Json::null() }
      "fails" => { fails.val = arg(a, "fails") is Some(True); Json::null() }
      "calls" => Json::array(calls)
      _ => raise Failure("no method \{verb}")
    }
  }
  if self.tells.get(on) is Some((world, told, stop)) {
    return match verb {
      "set" => { lock_world_set(world, a); Json::null() }
      "cloud" => { for f in world.cloud.copy() { f() }; Json::null() }
      "chain" => {
        let g = str_of(arg(a, "genesis")).unwrap_or("")
        for f in world.chain.copy() {
          f(g)
        }
        Json::null()
      }
      "told" => Json::array(told)
      "stop" => { stop(); Json::null() }
      _ => raise Failure("no method \{verb}")
    }
  }
  if self.told.get(on) is Some(t) {
    return match verb {
      "viewer" =>
        Json::array(
          t.viewer(
            n("conn").to_int(),
            match arg(a, "viewer") { None | Some(Null) => None; v => v },
            arg(a, "moved") is Some(True),
            num_of(arg(a, "floor")),
          ),
        )
      "viewerOf" => t.viewer_of(n("conn").to_int()).unwrap_or(Json::null())
      "again" => Json::array(t.again())
      _ => raise Failure("no method \{verb}")
    }
  }
  if self.screens.get(on) is Some(w) {
    return match verb {
      "step" => {
        w.step(a)
        w.told()
      }
      "told" => w.told()
      _ => raise Failure("no method \{verb}")
    }
  }
  if self.serveds.get(on) is Some(w) {
    return match verb {
      "step" => {
        w.step(a)
        w.told()
      }
      _ => raise Failure("no method \{verb}")
    }
  }
  if self.queues.get(on) is Some(q) {
    return match verb {
      "piece" => { q.piece(n("n").to_int(), str_of(arg(a, "text"))); Json::null() }
      "drain" => Json::array(q.drain())
      _ => raise Failure("no method \{verb}")
    }
  }
  raise Failure("nothing called \{on}")
}

///|
/// Runs the harness till stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  let rt = @effect.Runtime::new()
  rt.on_defect(e => host.say(jobj([("defect", jstr(message_of(e)))]).stringify()))
  let h : Harness = {
    rt,
    front: FrontHarness::new(host),
    now: Ref(0.0),
    stalled: Ref(0.0),
    hr: Ref(0L),
    pacers: Map([]),
    sharpeners: Map([]),
    sizers: Map([]),
    latencies: Map([]),
    losses: Map([]),
    stalls: Map([]),
    traces: Map([]),
    spans: Map([]),
    follows: Map([]),
    tells: Map([]),
    told: Map([]),
    queues: Map([]),
    screens: Map([]),
    serveds: Map([]),
    words: Map([]),
  }
  host.say(jobj([("ready", Json::boolean(true))]).stringify())
  while host.line() is Some(text) {
    let line = @json.parse(text) catch { _ => continue }
    let id = field(line, "id").unwrap_or(Json::null())
    let a = field(line, "args").unwrap_or(Json::object(Map([])))
    let answer = (fn(r : Result[Json, Error]) {
      let out = match r {
        Ok(v) => jobj([("id", id), ("value", v)])
        Err(e) => jobj([("id", id), ("error", jstr(message_of(e)))])
      }
      host.say(out.stringify())
    })
    match str_of(field(line, "op")) {
      Some("now") => { h.now.val = num_of(field(line, "ms")).unwrap_or(0.0); answer(Ok(Json::null())) }
      Some("stalled") => { h.stalled.val = num_of(field(line, "ms")).unwrap_or(0.0); answer(Ok(Json::null())) }
      Some("hr") => { h.hr.val = num_of(field(line, "ns")).unwrap_or(0.0).to_int64(); answer(Ok(Json::null())) }
      Some("advance") => {
        rt.advance(num_of(field(line, "ms")).unwrap_or(0.0).to_int())
        ignore(rt.run_ready())
        answer(Ok(Json::null()))
      }
      Some("call") => {
        let name = str_of(field(line, "fn")).unwrap_or("")
        answer(Ok(h.call(name, a)) catch { e => Err(e) })
      }
      Some("new") =>
        answer(
          Ok(h.new_(str_of(field(line, "kind")).unwrap_or(""), str_of(field(line, "as")).unwrap_or(""), a)) catch {
            e => Err(e)
          },
        )
      Some("do") => {
        answer(
          Ok(h.do_(str_of(field(line, "on")).unwrap_or(""), str_of(field(line, "method")).unwrap_or(""), a)) catch {
            e => Err(e)
          },
        )
        ignore(rt.run_ready())
      }
      Some("front") => {
        // (answered once done, the next lines read meanwhile: an accept waits for a connection)
        let name = str_of(field(line, "name")).unwrap_or("")
        let verb = str_of(field(line, "verb")).unwrap_or("")
        ignore(host.rt.fork(name="harness front", () => answer(Ok(h.front.ask(name, verb, a)) catch { e => Err(e) })))
      }
      _ => answer(Err(Failure("no op")))
    }
  }
  // (stdin over: what still waits on the machine's sockets, a front's link and its streams, ends with the program)
  @host.exit(0)
}
