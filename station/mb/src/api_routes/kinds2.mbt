// Feishu's connects (routes/feishu.ts), Comma's (routes/comma.ts) and the group's (routes/group.ts).

///|
/// A Feishu connect's part of its config entry (`feishu`).
pub fn feishu_entry(given : JV, had : JV) -> JV {
  if !(given is Obj(_)) && had is Null {
    return Null
  }
  let mut f = spread_of(Some(had))
  for
    key in [
      "appId", "appSecret", "botName", "botImage", "botOpenId", "registration",
    ] {
    match connect_field(Some(given), key).1 {
      Some(v) => f = jset(f, key, js(v))
      None => ()
    }
  }
  match field_of(Some(given), "domain") {
    Some(Str("feishu" | "lark") as d) => f = jset(f, "domain", d)
    _ => ()
  }
  match field_of(Some(given), "threads") {
    Some(Bool(_) as t) => f = jset(f, "threads", t)
    _ => ()
  }
  match field_of(Some(given), "tenant") {
    Some(Obj(_) as t) =>
      match t.get("key") {
        Some(Str(_) as k) =>
          f = jset(
            f,
            "tenant",
            jobj([
              ("key", k),
              (
                "name",
                match t.get("name") {
                  Some(Str(_) as n) => n
                  _ => js("")
                },
              ),
            ]),
          )
        _ => ()
      }
    _ => ()
  }
  f
}

///|
/// A Comma connect's part of its config entry (`comma`).
pub fn comma_entry(given : JV, had : JV) -> JV {
  if !(given is Obj(_)) && had is Null {
    return Null
  }
  let mut c = spread_of(Some(had))
  for key in ["server", "token"] {
    match connect_field(Some(given), key).1 {
      Some(v) => c = jset(c, key, js(v))
      None => ()
    }
  }
  c
}

///|
async fn Admin::feishu_verify_app(
  self : Admin,
  app_id : JV,
  secret : JV,
  domain : JV,
  lang : String,
) -> (JV, Array[JV]) {
  let pair = jitems(
    Some(
      self.backend.ask("feishu/surface.verifyFeishuApp", [
        app_id,
        secret,
        domain,
        js(lang),
      ]),
    ),
  )
  (pair.get(0).unwrap_or(Null), jitems(pair.get(1)))
}

///|
async fn Admin::domain_of(self : Admin, v : JV?) -> JV {
  self.backend.ask("feishu/web.domainOf", [v.unwrap_or(jundef)])
}

///|
fn Admin::feishu_edits(self : Admin) -> ConnectEdits {
  self.connect_edits(async fn(kind) {
    if kind == "feishu" {
      Some({ edit: async fn(given, had) { feishu_entry(given, had) }, })
    } else {
      None
    }
  })
}

///|
/// Save an app, or find the result of an earlier save whose response or registration journal write failed.
async fn Admin::feishu_save(
  self : Admin,
  edits : ConnectEdits,
  r : Request,
  i : JV,
  made : JV?,
) -> JV {
  let f = i.get("feishu")
  let mut app_id = js(trim_js(jstr(field_of(f, "appId")).unwrap_or("")))
  let mut secret = js(trim_js(jstr(field_of(f, "appSecret")).unwrap_or("")))
  let mut domain = self.domain_of(field_of(f, "domain"))
  let registration = match made {
    Some(m) => m.get("id")
    None => None
  }
  let saved = async fn() -> JV? {
    match registration {
      None => None
      Some(reg) => {
        for c in connects_of(with_connects(edits.raw())) {
          if field_of(Some(c), "kind") == Some(js("feishu")) &&
            field_of(field_of(Some(c), "feishu"), "registration") == Some(reg) &&
            edits.of_viewer(r, Some(c)) {
            return Some(c)
          }
        }
        None
      }
    }
  }
  match saved() {
    Some(existing) =>
      return jobj([
        ("id", existing.get("id").unwrap_or(jundef)),
        ("overview", Null),
      ]).filter_undef()
    None => ()
  }
  match made {
    Some(m) => {
      let app = m.get("app").unwrap_or(jundef)
      if app is Null {
        raise Refused(400, self.tr(r.lang, "station.feishu.notRegistered"))
      }
      app_id = field_of(Some(app), "appId").unwrap_or(jundef)
      secret = field_of(Some(app), "appSecret").unwrap_or(jundef)
      domain = m.get("domain").unwrap_or(jundef)
    }
    None => ()
  }
  let (identity, errors) = self.feishu_verify_app(
    app_id,
    secret,
    domain,
    r.lang,
  )
  // An app just made may take a moment to have its bot: kept all the same, it connects once it does.
  if registration is None && (identity is Null || errors.length() > 0) {
    raise Refused(
      400,
      errors
      .map(e => js_string(Some(e)))
      .join(self.tr(r.lang, "station.list.semicolon")),
    )
  }
  let bot = field_of(Some(identity), "botName")
  let name = if is_truthy(bot) {
    js_string(bot)
  } else {
    js_string(Some(app_id))
  }
  let id = first_free(edits.taken(), connect_slug(name, fallback="feishu"))
  let mut fields = jobj(
    [("appId", app_id), ("appSecret", secret), ("domain", domain)] +
    (match registration {
      Some(reg) => [("registration", reg)]
      None => []
    }) +
    (if field_of(f, "threads") is Some(Bool(true)) {
      [("threads", jbool(true))]
    } else {
      []
    }),
  ).filter_undef()
  if !(identity is Null) {
    fields = jset(fields, "botName", identity.get("botName").unwrap_or(jundef))
    fields = jset(
      fields,
      "botOpenId",
      identity.get("botUserId").unwrap_or(jundef),
    )
    match identity.get("botImage") {
      Some(b) if !(b is Null) => fields = jset(fields, "botImage", b)
      _ => ()
    }
    if identity.get("teamId") != Some(js("")) {
      fields = jset(
        fields,
        "tenant",
        jobj([
          ("key", identity.get("teamId").unwrap_or(jundef)),
          ("name", identity.get("team").unwrap_or(jundef)),
        ]).filter_undef(),
      )
    }
    fields = fields.filter_undef()
  }
  try {
    let overview = edits.put_connect(
      r,
      id,
      jset(jset(i, "kind", js("feishu")), "feishu", fields),
    )
    jobj([("id", js(id)), ("overview", overview)])
  } catch {
    e =>
      // putConnect writes before producing the overview: a failure in the latter must not make a second connect.
      match saved() {
        Some(committed) =>
          jobj([
            ("id", committed.get("id").unwrap_or(jundef)),
            ("overview", Null),
          ]).filter_undef()
        None => raise e
      }
  }
}

///|
/// What the station does as it starts, of the routes' parts: the Feishu registrations' worker given its save.
pub async fn Admin::start(self : Admin) -> Unit {
  if !self.setup.has("feishu") {
    return
  }
  let edits = self.feishu_edits()
  let save = self.callback_answering(async fn(args) {
    let made = args.get(0).unwrap_or(Null)
    let context = made.get("context").unwrap_or(Null)
    let r : Request = {
      verb: "POST",
      path: "/feishu/connects",
      query: [],
      search: None,
      headers: [],
      body: b"",
      viewer: context.get("viewer").unwrap_or(Obj([])),
      lang: jstr(context.get("lang")).unwrap_or("zh"),
      background: false,
      signal: None,
    }
    self
    .feishu_save(edits, r, context.get("input").unwrap_or(Obj([])), Some(made))
    .get("id")
    .unwrap_or(jundef)
  })
  self.backend.tell("feishu.registrations.start", [save])
}

///|
fn Admin::feishu_routes(self : Admin) -> Array[Route] {
  if !self.setup.has("feishu") {
    return []
  }
  let edits = self.feishu_edits()
  let answer = (f : async (Request, Array[String?]) -> Answer) => {
    async fn(r : Request, m : Array[String?]) -> Answer {
      self.connect_answer(r, async fn() { f(r, m) })
    }
  }
  [
    // An app's id and secret as given, checked against Feishu.
    route(
      "POST",
      "^\\/feishu\\/verify$",
      answer(async fn(r, _) {
        let i = input(r)
        let app_id = trim_js(jstr(i.get("appId")).unwrap_or(""))
        let secret = trim_js(jstr(i.get("appSecret")).unwrap_or(""))
        let domain = self.domain_of(i.get("domain"))
        let (identity, errors) = self.feishu_verify_app(
          js(app_id),
          js(secret),
          domain,
          r.lang,
        )
        let shown = if identity is Null {
          JV::Null
        } else {
          jobj([
            ("botName", identity.get("botName").unwrap_or(jundef)),
            ("botImage", identity.get("botImage").unwrap_or(jundef)),
            ("botOpenId", identity.get("botUserId").unwrap_or(jundef)),
            (
              "tenant",
              if identity.get("teamId") != Some(js("")) {
                jobj([
                  ("key", identity.get("teamId").unwrap_or(jundef)),
                  ("name", identity.get("team").unwrap_or(jundef)),
                ]).filter_undef()
              } else {
                Null
              },
            ),
          ]).filter_undef()
        }
        ok(jobj([("identity", shown), ("errors", jarr(errors))]))
      }),
    ),
    // An app given by its id and secret, or a finished scan.
    route(
      "POST",
      "^\\/feishu\\/connects$",
      answer(async fn(r, _) {
        let i = input(r)
        match jstr(field_of(i.get("feishu"), "registration")) {
          None => ok(self.feishu_save(edits, r, i, None))
          Some(registration) => {
            let save = self.callback_answering(async fn(args) {
              self
              .feishu_save(edits, r, i, Some(args.get(0).unwrap_or(Null)))
              .get("id")
              .unwrap_or(jundef)
            })
            let id = self.backend.ask("feishu.registrations.complete", [
              js(registration),
              js(r.email()),
              r.who("workspace").unwrap_or(jundef),
              save,
            ])
            if id is Null {
              raise Refused(
                400,
                self.tr(r.lang, "station.feishu.notRegistered"),
              )
            }
            ok(jobj([("id", id), ("overview", self.overview_of(r))]))
          }
        }
      }),
    ),
    route(
      "POST",
      "^\\/feishu\\/registrations$",
      answer(async fn(r, _) {
        let i = input(r)
        let name = match i.get("name") {
          Some(Str(n)) => js(trim_js(n))
          _ => Null
        }
        let made = try {
          let w = (k : String) => (k, r.who(k).unwrap_or(jundef))
          let viewer = jobj(
            [
              w("sub"),
              w("email"),
              w("name"),
              w("role"),
              w("workspace"),
              w("device"),
            ] +
            (match r.who("home") {
              None => []
              Some(h) => [("home", h)]
            }),
          ).filter_undef()
          let context = match i.get("bind") {
            Some(Obj(_) as bind) =>
              jobj([
                ("viewer", viewer),
                ("lang", js(r.lang)),
                (
                  "input",
                  jobj([
                    ("bind", bind),
                    ("mode", i.get("mode").unwrap_or(jundef)),
                    (
                      "requireMention",
                      i.get("requireMention").unwrap_or(jundef),
                    ),
                    (
                      "feishu",
                      jobj([
                        ("threads", jbool(i.get("threads") is Some(Bool(true)))),
                      ]),
                    ),
                  ]).filter_undef(),
                ),
              ])
            _ => Null
          }
          let domain = self.domain_of(i.get("domain"))
          self.backend.ask("feishu.registrations.begin", [
            js(r.email()),
            domain,
            name,
            context,
            r.who("workspace").unwrap_or(jundef),
          ])
        } catch {
          e =>
            raise Refused(
              502,
              self.tr(r.lang, "station.feishu.registerFailed", args=[
                ("error", message_of(e)),
              ]),
            )
        }
        ok(
          jobj([
            ("id", made.get("id").unwrap_or(jundef)),
            ("url", made.get("url").unwrap_or(jundef)),
            ("expiresAt", made.get("expiresAt").unwrap_or(jundef)),
            ("overview", self.overview_of(r)),
          ]).filter_undef(),
        )
      }),
    ),
    route(
      "DELETE",
      "^\\/*feishu\\/+registrations\\/+([^/]+)\\/*$",
      answer(async fn(r, m) {
        let cancelled = self.backend.ask("feishu.registrations.cancel", [
          js(percent_decode(m[0].unwrap())),
          js(r.email()),
          r.who("workspace").unwrap_or(jundef),
        ])
        if !is_truthy(Some(cancelled)) {
          raise Refused(404, self.tr(r.lang, "station.feishu.notRegistered"))
        }
        ok(self.overview_of(r))
      }),
    ),
    // An app's secret replaced.
    route(
      "PUT",
      "^\\/*feishu\\/+connects\\/+([^/]+)\\/+secret\\/*$",
      answer(async fn(r, m) {
        let id = edits.mine(r, percent_decode(m[0].unwrap()))
        let i = input(r)
        let secret = trim_js(jstr(i.get("appSecret")).unwrap_or(""))
        let existing = connects_of(with_connects(self.config_raw()))
          .iter()
          .find_first(c => id_is(c, id))
        guard existing is Some(existing) &&
          existing.get("kind") == Some(js("feishu")) else {
          raise Refused(404, "unknown connect \{id}")
        }
        let f = match existing.get("feishu") {
          Some(Obj(_) as o) => o
          _ => Obj([])
        }
        let app_id = match f.get("appId") {
          None | Some(Null) => ""
          v => js_string(v)
        }
        let domain = self.domain_of(f.get("domain"))
        let (_, errors) = self.feishu_verify_app(
          js(app_id),
          js(secret),
          domain,
          r.lang,
        )
        if errors.length() > 0 {
          raise Refused(
            400,
            errors
            .map(e => js_string(Some(e)))
            .join(self.tr(r.lang, "station.list.semicolon")),
          )
        }
        ok(
          edits.save(r, "feishu secret of \{id}", async fn(raw) {
            let raw = with_connects(raw)
            jset(
              raw,
              "connects",
              jarr(
                connects_of(raw).map(c => {
                  if id_is(c, id) {
                    jset(
                      c,
                      "feishu",
                      jset(
                        match field_of(Some(c), "feishu") {
                          Some(Obj(_) as o) => o
                          _ => Obj([])
                        },
                        "appSecret",
                        js(secret),
                      ),
                    )
                  } else {
                    c
                  }
                }),
              ),
            )
          }),
        )
      }),
    ),
  ]
}

///|
fn Admin::comma_routes(self : Admin) -> Array[Route] {
  if !self.setup.has("comma") {
    return []
  }
  let edits = self.connect_edits(async fn(kind) {
    if kind == "comma" {
      Some({ edit: async fn(given, had) { comma_entry(given, had) }, })
    } else {
      None
    }
  })
  [
    route("POST", "^\\/comma\\/connects$", async fn(r, _) {
      self.connect_answer(r, async fn() {
        let i = input(r)
        let line = self.backend.ask("comma/index.commaLine", [
          js(jstr(i.get("line")).unwrap_or("")),
        ])
        if line is Null {
          raise Refused(400, self.tr(r.lang, "station.comma.badLine"))
        }
        let taken = edits.taken()
        let mut id = "comma"
        let mut n = 2
        while taken.contains(js(id)) {
          id = "comma-\{n}"
          n += 1
        }
        let given = jobj([
          ("bind", i.get("bind").unwrap_or(jundef)),
          ("kind", js("comma")),
          ("mode", js("multi-session")),
          ("comma", line),
        ]).filter_undef()
        ok(
          jobj([("id", js(id)), ("overview", edits.put_connect(r, id, given))]),
        )
      })
    }),
  ]
}

///|
let group_server : Re = re("^[0-9a-f]{64}$")

///|
let group_code : Re = re("^[2-9A-HJ-NP-Z]{16}$")

///|
const NAME_MOST : Int32 = 40

///|
/// Relays as given: a list, or words of a text (lines, commas, spaces).
fn relays_of(v : JV?) -> Array[String]? {
  let list = match v {
    Some(Arr(items)) => items
    Some(Str(s)) =>
      re("[\\s,]+")
      .replace_all(s, _ => "\u{0}")
      .split("\u{0}")
      .map(x => js(x.to_string()))
      .collect()
    _ => return None
  }
  let out = []
  for x in list {
    match x {
      Str(s) => {
        let t = trim_js(s)
        if t != "" && !out.contains(t) {
          out.push(t)
        }
      }
      _ => ()
    }
  }
  Some(out)
}

///|
/// Whether `r` is an http(s) URL with a host, as the URL constructor reads it.
fn is_relay(given : String) -> Bool {
  // (leading and trailing C0 controls and spaces are no part of it, tabs and newlines inside neither)
  let mut s = given
  let mut a = 0
  let mut b = s.length()
  while a < b && s.unsafe_charcode_at(a) <= 0x20 {
    a += 1
  }
  while b > a && s.unsafe_charcode_at(b - 1) <= 0x20 {
    b -= 1
  }
  s = s
    .unsafe_substring(start=a, end=b)
    .replace_all(old="\t", new="")
    .replace_all(old="\n", new="")
    .replace_all(old="\r", new="")
  guard s.find(":") is Some(colon) else { return false }
  let scheme = s.unsafe_substring(start=0, end=colon).to_lower()
  if scheme != "http" && scheme != "https" {
    return false
  }
  let mut i = colon + 1
  while i < s.length() &&
        (s.unsafe_charcode_at(i) == '/' || s.unsafe_charcode_at(i) == '\\') {
    i += 1
  }
  let mut j = i
  while j < s.length() &&
        !"/\\?#".contains_char(s.unsafe_charcode_at(j).unsafe_to_char()) {
    j += 1
  }
  let mut authority = s.unsafe_substring(start=i, end=j)
  match authority.rev_find("@") {
    Some(at) =>
      authority = authority.unsafe_substring(
        start=at + 1,
        end=authority.length(),
      )
    None => ()
  }
  let host = if authority.has_prefix("[") {
    match authority.find("]") {
      Some(end) => authority.unsafe_substring(start=0, end=end + 1)
      None => return false
    }
  } else {
    match authority.rev_find(":") {
      Some(at) => {
        let port = authority.unsafe_substring(
          start=at + 1,
          end=authority.length(),
        )
        if port != "" && !re("^[0-9]+$").matches(port) {
          return false
        }
        if port != "" && js_number(port) > 65535.0 {
          return false
        }
        authority.unsafe_substring(start=0, end=at)
      }
      None => authority
    }
  }
  if host == "" {
    return false
  }
  for k in 0..<host.length() {
    let c = host.unsafe_charcode_at(k)
    if c <= 0x20 || "<>^|%\"`{}".contains_char(c.unsafe_to_char()) {
      return false
    }
  }
  true
}

///|
/// A code as it is kept: its letters in capitals, in fours. None: not one.
fn code_of(v : JV?) -> String? {
  guard v is Some(Str(s)) else { return None }
  let letters = re("[\\s-]").replace_all(s.to_upper(), _ => "")
  if !group_code.matches(letters) {
    return None
  }
  Some(
    [0, 4, 8, 12]
    .map(i => letters.unsafe_substring(start=i, end=i + 4))
    .join("-"),
  )
}

///|
/// What is wrong with a connect's part as it would be (said in `lang`).
fn Admin::group_faults(self : Admin, g : JV, lang : String) -> Array[String] {
  let out = []
  match g.get("server") {
    Some(Str(s)) if group_server.matches(s) => ()
    _ => out.push(self.tr(lang, "station.group.badServer"))
  }
  let relays = jitems(g.get("relays"))
  if relays.length() == 0 {
    out.push(self.tr(lang, "station.group.noRelay"))
  } else if relays.iter().any(r => !(r is Str(s) && is_relay(s))) {
    out.push(self.tr(lang, "station.group.badRelay"))
  }
  if g.get("code") is None &&
    !(g.get("memberId") is Some(Str(_))) &&
    !(g.get("bound") is Some(Str(_))) {
    out.push(self.tr(lang, "station.group.noCode"))
  }
  match g.get("botName") {
    Some(Str(n)) if code_points(n) > NAME_MOST =>
      out.push(
        self.tr(lang, "station.group.longName", args=[
          ("most", NAME_MOST.to_string()),
        ]),
      )
    _ => ()
  }
  out
}

///|
/// A group connect's part of its config entry (`group`), from what was given and what it had.
async fn Admin::group_entry(
  self : Admin,
  lang : String,
  given : JV,
  had : JV,
) -> JV {
  if !(given is Obj(_)) && had is Null {
    return Null
  }
  let mut g = spread_of(Some(had))
  match jstr(field_of(Some(given), "server")) {
    Some(server) => {
      let s = @jscase.lower(trim_js(server))
      if Some(js(s)) != g.get("server") {
        g = jset(g, "server", js(s))
        for key in ["memberId", "name", "bound"] {
          g = jdel(g, key)
        }
      }
    }
    None => ()
  }
  match relays_of(field_of(Some(given), "relays")) {
    Some(relays) => g = jset(g, "relays", jstrs(relays))
    None => ()
  }
  match field_of(Some(given), "code") {
    Some(Str(code)) if trim_js(code) != "" =>
      match code_of(Some(js(code))) {
        Some(kept) => g = jset(g, "code", js(kept))
        None => raise Refused(400, self.tr(lang, "station.group.badCode"))
      }
    _ => ()
  }
  match field_of(Some(given), "botName") {
    Some(Str(n)) =>
      g = if trim_js(n) == "" {
        jdel(g, "botName")
      } else {
        jset(g, "botName", js(trim_js(n)))
      }
    Some(Null) => g = jdel(g, "botName")
    _ => ()
  }
  match g.get("key") {
    Some(Str(k)) if group_server.matches(k) => ()
    _ => {
      let key = hex_of(
        bytes_of(self.backend.ask("crypto.randomBytes", [jint(32)])).unwrap_or(
          b"",
        ),
      )
      g = jset(g, "key", js(key))
    }
  }
  let wrong = self.group_faults(g, lang)
  if wrong.length() > 0 {
    raise Refused(400, wrong.join(self.tr(lang, "station.list.semicolon")))
  }
  g
}

///|
fn Admin::group_routes(self : Admin) -> Array[Route] {
  if !self.setup.has("group") {
    return []
  }
  let edits = self.connect_edits(async fn(kind) {
    if kind == "group" {
      Some({
        edit: async fn(given, had) {
          self.group_entry(self.setup.station_lang, given, had)
        },
      })
    } else {
      None
    }
  })
  [
    route("POST", "^\\/group\\/connects$", async fn(r, _) {
      self.connect_answer(r, async fn() {
        let i = input(r)
        guard i.get("group") is Some(Obj(_) as given) else {
          raise Refused(400, self.tr(r.lang, "station.group.badServer"))
        }
        // (checked in the asker's words before it is saved)
        ignore(self.group_entry(r.lang, given, Null))
        if code_of(given.get("code")) is None {
          raise Refused(400, self.tr(r.lang, "station.group.noCode"))
        }
        let name = match given.get("botName") {
          Some(Str(n)) if trim_js(n) != "" => n
          _ => "group"
        }
        let id = first_free(edits.taken(), connect_slug(name, fallback="group"))
        let overview = edits.put_connect(
          r,
          id,
          jset(jset(i, "kind", js("group")), "group", given),
        )
        ok(jobj([("id", js(id)), ("overview", overview)]))
      })
    }),
  ]
}
