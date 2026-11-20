// The group connects on the station (group/index.ts; an IM community of AFK-surf/group, `im/2`, joined as a member): kept as
// every platform's are (connects.mbt: connected as config.json and the station's workspace say, what the server calls
// people and conversations in <data>/group-names.json), with what each heard of its server in
// <data>/group-threads.json.
//
// A connect's part of config.json (`group`): the server's endpoint id and relays; its key (32 bytes, hex: the device
// it is on the server, made as it is added, carried with its entry wherever the connect goes, as Slack's token is);
// the code it joins by until it has (taken out once the server let it in, its hash kept as `bound`, so that the link
// is not made again for it); the name it asks to be known by; and, as the server last said, who it is there
// (`memberId`, `name`).

///|
fn non_empty(v : J?) -> J {
  match v {
    Some(Str(u)) =>
      match @session_chats.trim(@jsjson.sanitize_str(u)) {
        "" => Null
        t => js(t)
      }
    _ => Null
  }
}

///|
/// A text in capitals as JavaScript's `toUpperCase` says it (upper_table.mbt).
pub fn js_upper(s : String) -> String {
  let out = StringBuilder()
  for c in s {
    let n = c.to_int()
    let mut done = false
    let mut i = 0
    while i < upper_multi.length() {
      let k = upper_multi[i + 1]
      if upper_multi[i] == n {
        for j in 0..<k {
          out.write_char(Int::unsafe_to_char(upper_multi[i + 2 + j]))
        }
        done = true
        break
      }
      i += 2 + k
    }
    if done {
      continue
    }
    let mut mapped = n
    let mut r = 0
    while r < upper_runs.length() {
      let start = upper_runs[r]
      let count = upper_runs[r + 1]
      let stride = upper_runs[r + 2]
      if n >= start && n <= start + (count - 1) * stride && (n - start) % stride == 0 {
        mapped = n + upper_runs[r + 3]
        break
      }
      if start > n {
        break
      }
      r += 4
    }
    out.write_char(Int::unsafe_to_char(mapped))
  }
  out.to_string()
}

///|
/// A code as it is compared: its letters, without hyphens or spaces, in capitals (the server's `hashOf`).
pub fn code_hash(code : String) -> String {
  let kept = StringBuilder()
  for c in js_upper(code) {
    if c == '-' || @jscase.is_space(c.to_int()) {
      continue
    }
    kept.write_char(c)
  }
  @cloud_net.sha256_hex(kept.to_string())
}

///|
/// config.json's group connects, each as the connects read it (`GroupConnect`: `{id, enabled, server, relays, key,
/// code, bound, botName, memberId, name, workspace}`).
pub fn group_connects(raw : J) -> Array[J] {
  arr_of(at(Some(raw), "connects"))
  .unwrap_or([])
  .filter(c => str_of(at(Some(c), "kind")) == Some("group"))
  .map(c => {
    let g = match at(Some(c), "group") {
      Some(Null) | None => Some(jo([]))
      v => v
    }
    let id = match at(Some(c), "id") {
      Some(Null) | None => ""
      v => js_text(v)
    }
    let relays : Array[J] = []
    for r in arr_of(at(g, "relays")).unwrap_or([]) {
      match r {
        Str(u) =>
          match @session_chats.trim(@jsjson.sanitize_str(u)) {
            "" => ()
            t => relays.push(js(t))
          }
        _ => ()
      }
    }
    jo([
      ("id", js(id)),
      ("enabled", jb(!(at(Some(c), "enabled") is Some(Bool(false))))),
      ("server", js(match at(g, "server") { Some(Str(u)) => @session_chats.lower(@session_chats.trim(@jsjson.sanitize_str(u))); _ => "" })),
      ("relays", ja(relays)),
      ("key", js(str_of(at(g, "key")).unwrap_or(""))),
      ("code", non_empty(at(g, "code"))),
      ("bound", non_empty(at(g, "bound"))),
      ("botName", non_empty(at(g, "botName"))),
      ("memberId", non_empty(at(g, "memberId"))),
      ("name", non_empty(at(g, "name"))),
      ("workspace", non_empty(at(Some(c), "workspace"))),
    ])
  })
}

///|
/// What a group connect connects with (its server, relays, key and the code it joins by or the hash of the one it
/// joined by): None where it has nothing to connect with. A code taken out once it was used (its hash kept as
/// `bound`) connects nothing again; a new one does.
pub fn group_credentials(c : J) -> String? {
  let s = (k : String) => str_of(at(Some(c), k))
  let server = s("server").unwrap_or("")
  let key = s("key").unwrap_or("")
  let relays = arr_of(at(Some(c), "relays")).unwrap_or([]).map(r => js_text(Some(r)))
  let code = s("code")
  let bound = s("bound")
  if server == "" || key == "" || relays.length() == 0 || (code is None && bound is None && s("memberId") is None) {
    return None
  }
  let last = match code {
    Some(k) => code_hash(k)
    None => bound.unwrap_or("")
  }
  Some("\{server}\n\{relays.join(" ")}\n\{key}\n\{last}")
}

///|
/// The endpoint id of a key (hex): its Ed25519 public half, as iroh says it (`public_key`: of a seed, hex, the
/// shell's).
pub fn device_of(key : String, public_key : (String) -> String?) -> String? {
  if !lower_hex_of(key, 64) {
    return None
  }
  public_key(key)
}

///|
pub(all) struct GroupOptions {
  connects : ConnectsOptions
  /// What binds the connects' endpoints (the station's mesh; a test's).
  endpoints : () -> Endpoints
  /// How a connect's connection is made (tests); default a group surface.
  create : (async (J, NameBook, GroupThreads) -> Connection)?
  public_key : (String) -> String?
  speech : Speech
  uuid : () -> String
  signer : Signer
}

///|
pub struct GroupParts {
  connects : Connects
  threads : GroupThreads
  priv public_key : (String) -> String?
}

///|
pub async fn make_group(options : GroupOptions) -> GroupParts {
  let o = options.connects
  let threads = GroupThreads::open(o.fs.join([o.data, "group-threads.json"]), o.fs, o.log)
  let create = match options.create {
    Some(f) => f
    None =>
      async fn(c : J, book : NameBook, t : GroupThreads) -> Connection {
        let s = (k : String) => str_of(at(Some(c), k))
        let surface = GroupSurface::new({
          connect: s("id").unwrap_or(""),
          server: s("server").unwrap_or(""),
          relays: arr_of(at(Some(c), "relays")).unwrap_or([]).map(r => js_text(Some(r))),
          ips: [],
          key: s("key").unwrap_or(""),
          code: s("code"),
          bot_name: s("botName"),
          threads: t,
          book: Some(book),
          endpoints: (options.endpoints)(),
          clock: o.clock,
          ping_ms: None,
          stale_ms: None,
          backoff_ms: None,
          on_heard: () => (),
          log: o.log,
          fs: o.fs,
          speech: options.speech,
          uuid: options.uuid,
          signer: options.signer,
        })
        surface.connection()
      }
  }
  let connects = make_connects(o, {
    kind: "group",
    names: names_file("group").unwrap(),
    connects: group_connects,
    credentials: group_credentials,
    create: async fn(c, book) { create(c, book, threads) },
    // Who it is on the server, and its code gone once it was let in.
    seen: (c, i) => {
      let member_id = at(Some(i), "botUserId").unwrap_or(Null)
      let name = at(Some(i), "botName").unwrap_or(Null)
      let had = at(Some(c), "memberId").unwrap_or(Null)
      if @session_chats.jeq(had, member_id) && @session_chats.jeq(at(Some(c), "name").unwrap_or(Null), name) && at(Some(c), "code") is Some(Null) {
        return None
      }
      // (let in as another member than before: what it heard of the conversations was the other's)
      if !(had is Null) && !@session_chats.jeq(had, member_id) {
        threads.drop(js_text(at(Some(c), "id")))
      }
      Some(entry => {
        let mut group = match at(Some(entry), "group") {
          Some(Obj(_) | Arr(_) as g) => g
          _ => jo([])
        }
        group = set_field(group, "memberId", member_id)
        group = set_field(group, "name", name)
        match at(Some(group), "code") {
          Some(Str(u)) if u.length() > 0 => {
            group = set_field(group, "bound", js(code_hash(@jsjson.sanitize_str(u))))
            group = without(group, ["code"])
          }
          _ => ()
        }
        set_field(entry, "group", group)
      })
    },
  })
  { connects, threads, public_key: options.public_key }
}

///|
/// Stops as every platform's connects do, what they heard on the disk once it is.
pub async fn GroupParts::close(self : GroupParts) -> Unit {
  self.connects.close()
  self.threads.flushed()
}

///|
/// What the overview says of a group connect besides what all connects say (its key never).
pub fn GroupParts::shown(self : GroupParts, raw : J) -> J {
  let c = group_connects(jo([("connects", ja([raw]))])).get(0)
  let id = match at(Some(raw), "id") {
    Some(Null) | None => ""
    v => js_text(v)
  }
  let live = match self.connects.chat(id) {
    Some(conn) => (conn.identity)()
    None => Null
  }
  let pick = fn(vs : Array[J?]) -> J {
    for v in vs {
      match v {
        Some(Null) | None => continue
        Some(x) => if is_undefined(x) { continue } else { return x }
      }
    }
    undefined()
  }
  let name = pick([at(c, "name"), at(Some(live), "botName"), at(c, "botName"), at(Some(raw), "id")])
  let device = match c {
    None => J::Null
    Some(c) => jopt(device_of(js_text(at(Some(c), "key")), self.public_key))
  }
  jo([
    ("name", name),
    ("team", Null),
    ("botImage", Null),
    (
      "group",
      jo([
        ("server", at(c, "server").unwrap_or(js(""))),
        ("relays", at(c, "relays").unwrap_or(ja([]))),
        ("botName", nullish_or_null(at(c, "botName"))),
        ("memberId", nullish_or_null(at(c, "memberId"))),
        ("device", device),
        // Whether it waits to join by a code (one given and not used yet).
        ("joining", jb(match at(c, "code") { Some(Null) | None => false; _ => true })),
      ]),
    ),
  ])
  |> drop_undefined
}
