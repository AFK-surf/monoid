// The connects of each kind through the pages: Slack's (routes/slack.ts: apps made and edited with a person's
// configuration token, their installs, new connects from tokens, the token check, the people of the connected Slack
// workspaces, a viewer saying a Slack user is them), Feishu's (routes/feishu.ts), Comma's (routes/comma.ts) and the
// group's (routes/group.ts); and each kind's part of a connect's config entry.

///|
let slack_groups : Array[String] = [
  "base", "public", "dm", "customize", "files", "reactions", "channels", "people",
  "extras", "canvases", "lists", "topics", "usergroups", "search", "connect", "more",
]

///|
const DEFAULT_APP_NAME : String = "still.fail"

///|
/// A Slack connect's part of its config entry (`slack`): its tokens as given (blank ones stay as they were), its app,
/// and who it is in Slack.
pub fn slack_entry(given : JV, had : JV) -> JV {
  let old = if had is Null { JV::Obj([]) } else { had }
  let token = (key : String) => {
    match connect_field(Some(given), key).1 {
      Some(t) => Some(t)
      None => jstr(old.get(key))
    }
  }
  let app_token = token("appToken")
  let bot_token = token("botToken")
  let given_team = field_of(Some(given), "team")
  let team_ok = match given_team {
    Some(Obj(_) as t) =>
      (match t.get("id") {
        None | Some(Str(_)) => true
        _ => false
      }) &&
      (match t.get("name") {
        None | Some(Null) | Some(Str(_)) => true
        _ => false
      })
    _ => false
  }
  let mut team = JV::Null
  let mut bot_name : String? = None
  let mut bot_image : String? = None
  if team_ok {
    let t = given_team.unwrap()
    team = jobj(
      [("id", t.get("id").unwrap_or(js("")))] +
      (match t.get("name") {
        Some(Str(n)) => [("name", js(n))]
        _ => []
      }),
    )
    bot_name = jstr(field_of(Some(given), "botName"))
    bot_image = match jstr(field_of(Some(given), "botImage")) {
      Some(i) if i != "" => Some(i)
      _ => None
    }
  } else if !nullish(old.get("team").unwrap_or(jundef)) {
    team = old.get("team").unwrap()
    bot_name = jstr(old.get("botName"))
    bot_image = jstr(old.get("botImage"))
  }
  let app_id = jstr(old.get("appId"))
  if app_token is None && bot_token is None && app_id is None && team is Null {
    return Null
  }
  let mut s = JV::Obj([])
  match app_token {
    Some(t) => s = jset(s, "appToken", js(t))
    None => ()
  }
  match bot_token {
    Some(t) => s = jset(s, "botToken", js(t))
    None => ()
  }
  match app_id {
    Some(a) => s = jset(s, "appId", js(a))
    None => ()
  }
  if !(team is Null) {
    s = jset(s, "team", team)
  }
  match bot_name {
    Some(n) => s = jset(s, "botName", js(n))
    None => ()
  }
  match bot_image {
    Some(i) => s = jset(s, "botImage", js(i))
    None => ()
  }
  s
}

///|
/// admin/slack.rs `url_encode`: everything but A-Z a-z 0-9 - _ . ~ as %XX.
fn url_encode(s : String) -> String {
  let out = StringBuilder::new()
  let hex = "0123456789ABCDEF"
  for b in utf8(s) {
    let c = b.to_int()
    if (c >= 'A' && c <= 'Z') ||
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '.' ||
      c == '~' {
      out.write_char(c.unsafe_to_char())
    } else {
      out.write_char('%')
      out.write_char(hex.unsafe_charcode_at(c >> 4).unsafe_to_char())
      out.write_char(hex.unsafe_charcode_at(c & 15).unsafe_to_char())
    }
  }
  out.to_string()
}

///|
fn color_ok(color : String) -> Bool {
  re("^#[0-9a-fA-F]{6}$").matches(trim_js(color))
}

///|
/// Groups on and off as serde reads a `BTreeMap<String, bool>`; None when it is not one.
fn groups_of(v : JV?) -> JV? {
  guard v is Some(Obj(fields)) else { return None }
  if fields.all(f => f.1 is Bool(_)) {
    Some(Obj(fields))
  } else {
    None
  }
}

///|
/// A form's edits as serde reads them (`SlackAppEdit`): None when a field has the wrong kind.
fn edit_of(v : JV?) -> JV? {
  guard v is Some(Obj(_) as o) else { return None }
  let mut edit = JV::Obj([])
  for
    key in [
      "name", "displayName", "description", "longDescription", "backgroundColor",
    ] {
    match o.get(key) {
      None | Some(Null) => continue
      Some(Str(_) as s) => edit = jset(edit, key, s)
      Some(_) => return None
    }
  }
  match o.get("groups") {
    None | Some(Null) => ()
    g =>
      match groups_of(g) {
        Some(groups) => edit = jset(edit, "groups", groups)
        None => return None
      }
  }
  Some(edit)
}

///|
/// An error as it is given a part (`{"$error": {message, ...}}`).
fn error_json(e : Error) -> JV {
  match e {
    Thrown(_, said) => jobj([("$error", jdel(said, "kind"))])
    _ => jobj([("$error", jobj([("message", js(message_of(e)))]))])
  }
}

///|
/// Sorted keeping the order of equals (Array.prototype.sort).
fn stable_sort(items : Array[JV], cmp : (JV, JV) -> Int32) -> Array[JV] {
  if items.length() <= 1 {
    return items.copy()
  }
  let mid = items.length() / 2
  let a = stable_sort(items[0:mid].to_array(), cmp)
  let b = stable_sort(items[mid:].to_array(), cmp)
  let out = []
  let mut i = 0
  let mut j = 0
  while i < a.length() && j < b.length() {
    if cmp(b[j], a[i]) < 0 {
      out.push(b[j])
      j += 1
    } else {
      out.push(a[i])
      i += 1
    }
  }
  while i < a.length() {
    out.push(a[i])
    i += 1
  }
  while j < b.length() {
    out.push(b[j])
    j += 1
  }
  out
}

///|
fn first_free(taken : Array[JV], base : String) -> String {
  let mut id = base
  let mut n = 2
  while taken.contains(js(id)) {
    id = "\{base}-\{n}"
    n += 1
  }
  id
}

///|
async fn ConnectEdits::taken(self : ConnectEdits) -> Array[JV] {
  connects_of(with_connects(self.raw())).map(c => {
    field_of(Some(c), "id").unwrap_or(jundef)
  })
}

///|
fn Admin::slack_routes(self : Admin) -> Array[Route] {
  let edits = self.connect_edits(async fn(kind) {
    if kind == "slack" {
      Some({ edit: async fn(given, had) { slack_entry(given, had) }, })
    } else {
      None
    }
  })
  let answer = (f : async (Request, Array[String?]) -> Answer) => {
    async fn(r : Request, m : Array[String?]) -> Answer {
      self.connect_answer(r, async fn() { f(r, m) })
    }
  }
  let apps = async fn(call : String, args : Array[JV]) -> JV {
    self.backend.ask("slack.apps." + call, args)
  }
  let slack_fn = async fn(name : String, args : Array[JV]) -> JV {
    self.backend.ask("slack/index." + name, args)
  }
  let made_app = async fn(key : String) -> JV? {
    jitems(Some(slack_fn("madeApps", [edits.raw()])))
    .iter()
    .find_first(a => {
      a.get("appId") == Some(js(key)) ||
      field_of(field_of(Some(a), "oauth"), "state") == Some(js(key))
    })
  }
  let team_for = async fn(i : JV, r : Request) -> String {
    let teams = jitems(Some(slack_fn("configTokens", [edits.raw()]))).filter(t => {
      t.get("by") == Some(js(r.email()))
    })
    if teams.length() == 0 {
      raise Refused(400, self.tr(r.lang, "station.slackApp.noConfigToken"))
    }
    let team = match i.get("team") {
      Some(Str(t)) => Some(js(t))
      _ =>
        if teams.length() == 1 {
          Some(teams[0].get("teamId").unwrap_or(jundef))
        } else {
          None
        }
    }
    match team {
      Some(t) if !is_undef(t) &&
        teams.iter().any(x => x.get("teamId") == Some(t)) => js_string(Some(t))
      _ => raise Refused(400, self.tr(r.lang, "station.slackApp.chooseTeam"))
    }
  }
  let connects = async fn() {
    jitems(Some(self.backend.ask("slack.connects", [])))
  }
  let team_of = async fn(id : String) -> JV {
    match connects().iter().find_first(c => id_is(c, id)) {
      Some(c) =>
        match field_of(field_of(Some(c), "team"), "id") {
          Some(v) if !nullish(v) => v
          _ => Null
        }
      None => Null
    }
  }
  let app_id = async fn(id : String) -> JV {
    guard connects().iter().find_first(c => id_is(c, id)) is Some(connect) else {
      raise Refused(404, "unknown connect \{id}")
    }
    let has = connect.get("appId").unwrap_or(jundef)
    if !(has is Null) {
      return has
    }
    match self.state.app_ids.get(id) {
      Some(known) => return js(known)
      None => ()
    }
    if connect.get("botToken") == Some(js("")) {
      return Null
    }
    let app = slack_fn("appIdOf", [
      jref("slack.client"),
      connect.get("botToken").unwrap_or(jundef),
    ])
    self.state.app_ids[id] = js_string(Some(app))
    app
  }
  let slack_error = async fn(e : Error, lang : String) -> JV {
    slack_fn("slackError", [error_json(e), js(lang)])
  }
  // Sets an app's icon (an image's data URL); what went wrong, in words, or null.
  let set_icon = async fn(
    by : String,
    app : JV,
    icon : String,
    lang : String,
  ) -> JV {
    let (head, data) = match icon.find(";base64,") {
      Some(at) =>
        (
          icon.unsafe_substring(start=0, end=at),
          icon.unsafe_substring(start=at + 8, end=icon.length()),
        )
      None => ("data:image/png", "")
    }
    let mime = if head.has_prefix("data:") &&
      head.unsafe_substring(start=5, end=head.length()).has_prefix("image/") {
      head.unsafe_substring(start=5, end=head.length())
    } else {
      "image/png"
    }
    let bytes = if re("^[A-Za-z0-9+/]*={0,2}$").matches(data) &&
      data.length() % 4 == 0 {
      @base64.decode(data) catch {
        _ => b""
      }
    } else {
      b""
    }
    try {
      ignore(apps("setIcon", [js(by), app, jbytes(bytes), js(mime)]))
      Null
    } catch {
      e =>
        match thrown_as(e, "SlackApiError") {
          Some(said) if said.get("code") ==
            Some(js("app_not_owned_by_manager_app")) =>
            js(self.tr(lang, "station.slackApp.iconNotOwned"))
          _ => slack_error(e, lang)
        }
    }
  }
  let new_connect = async fn(r : Request, i : JV) -> Answer {
    let lang = r.lang
    let slack_in = i.get("slack")
    let t = (k : String) => trim_js(jstr(field_of(slack_in, k)).unwrap_or(""))
    let app_token = t("appToken")
    // Installed through Slack's OAuth: its bot token is here already.
    let install = jstr(field_of(slack_in, "install"))
    let installed = match install {
      Some(k) => field_of(made_app(k), "oauth")
      None => None
    }
    let installed_bot = field_of(installed, "botToken")
    if install is Some(_) && installed_bot is None {
      raise Refused(400, self.tr(lang, "station.slackApp.notInstalled"))
    }
    let bot_token = match installed_bot {
      Some(b) => b
      None => js(t("botToken"))
    }
    let pair = jitems(
      Some(apps("verifyTokens", [js(app_token), bot_token, js(lang)])),
    )
    let identity = pair.get(0).unwrap_or(Null)
    let errors = jitems(pair.get(1))
    if identity is Null || errors.length() > 0 {
      raise Refused(
        400,
        if errors.length() == 0 {
          self.tr(lang, "station.slackApp.badToken")
        } else {
          errors
          .map(x => js_string(Some(x)))
          .join(self.tr(lang, "station.list.semicolon"))
        },
      )
    }
    let app_given = match jstr(field_of(slack_in, "appId")) {
      Some(a) if a != "" => Some(a)
      _ => None
    }
    let made = match (install, app_given) {
      (Some(k), _) => made_app(k)
      (None, Some(a)) => made_app(a)
      _ => None
    }
    // An app made here, being connected: Socket Mode and its events on in its manifest.
    match made {
      Some(m) =>
        try {
          let cb = self.callback_answering(async fn(args) {
            slack_fn("withSocketMode", [
              args.get(0).unwrap_or(jundef),
              jbool(true),
            ])
          })
          ignore(
            apps("editManifest", [
              m.get("by").unwrap_or(jundef),
              m.get("appId").unwrap_or(jundef),
              cb,
            ]),
          )
        } catch {
          e =>
            raise Refused(
              400,
              self.tr(lang, "station.slackApp.socketModeFailed", args=[
                ("error", js_string(Some(slack_error(e, lang)))),
              ]),
            )
        }
      None => ()
    }
    let bot_name = js_string(identity.get("botName"))
    let name = if identity.get("botName") == Some(js("")) {
      DEFAULT_APP_NAME
    } else {
      bot_name
    }
    let id = first_free(edits.taken(), connect_slug(name))
    let app = match made {
      Some(m) =>
        match m.get("appId") {
          Some(a) if !nullish(a) => Some(a)
          _ => app_given.map(js)
        }
      None => app_given.map(js)
    }
    let mut fields = jobj([
      ("appToken", js(app_token)),
      ("botToken", bot_token),
      (
        "team",
        jobj([
          ("id", identity.get("teamId").unwrap_or(jundef)),
          ("name", identity.get("team").unwrap_or(jundef)),
        ]).filter_undef(),
      ),
      ("botName", identity.get("botName").unwrap_or(jundef)),
    ]).filter_undef()
    match identity.get("botImage") {
      Some(b) if !(b is Null) => fields = jset(fields, "botImage", b)
      _ => ()
    }
    let given = jset(jset(i, "kind", js("slack")), "slack", fields)
    let mut shown = edits.put_connect(r, id, given)
    // Its app is connected now: no longer one waiting.
    match made {
      Some(m) =>
        self.config_update(raw => {
          let kept = jitems(raw.get("slackApps")).filter(a => {
            field_of(Some(a), "appId") != m.get("appId")
          })
          jset(raw, "slackApps", jarr(kept))
        })
      None => ()
    }
    guard app is Some(app) else {
      return ok(jobj([("id", js(id)), ("overview", shown)]))
    }
    shown = edits.save(r, "slack app of \{id}", async fn(raw) {
      let raw = with_connects(raw)
      jset(
        raw,
        "connects",
        jarr(
          connects_of(raw).map(c => {
            if id_is(c, id) {
              jset(
                c,
                "slack",
                jset(
                  match field_of(Some(c), "slack") {
                    Some(Obj(_) as s) => s
                    _ => Obj([])
                  },
                  "appId",
                  app,
                ),
              )
            } else {
              c
            }
          }),
        ),
      )
    })
    ok(jobj([("id", js(id)), ("overview", shown)]))
  }
  let make_app = async fn(r : Request, i : JV) -> Answer {
    let lang = r.lang
    let by = r.email()
    let team = team_for(i, r)
    let mut edit = edit_of(i.get("settings")).unwrap_or(Obj([]))
    let trimmed = match edit.get("name") {
      Some(Str(n)) => Some(trim_js(n))
      _ => None
    }
    let name = match trimmed {
      Some(t) if t != "" => t
      _ => DEFAULT_APP_NAME
    }
    match edit.get("backgroundColor") {
      Some(Str(c)) if c != "" && !color_ok(c) =>
        raise Refused(400, self.tr(lang, "station.slackApp.badColor"))
      _ => ()
    }
    edit = jset(edit, "name", js(name))
    let place = self.backend.ask("agents.place", [])
    let place = if nullish(place) { JV::Null } else { place }
    let redirect = if place is Null {
      JV::Null
    } else {
      js("\{js_string(place.get("origin"))}/slack/installed")
    }
    let manifest = slack_fn("applySettings", [
      slack_fn("slackManifest", [js(name), Null, redirect]),
      edit,
    ])
    let app = apps("createApp", [
      js(by),
      js(team),
      slack_fn("withSocketMode", [manifest, jbool(false)]),
    ]) catch {
      e =>
        raise Refused(
          400,
          self.tr(lang, "station.slackApp.createFailed", args=[
            ("error", js_string(Some(slack_error(e, lang)))),
          ]),
        )
    }
    let app_id = app.get("appId").unwrap_or(jundef)
    let icon_error = match i.get("icon") {
      Some(Str(icon)) if icon != "" => set_icon(by, app_id, icon, lang)
      _ => Null
    }
    // Kept here until a connect takes it.
    let shown_name = match
      field_of(field_of(Some(manifest), "display_information"), "name") {
      Some(Str(n)) => n
      _ => name
    }
    let mut made = jobj([
      ("appId", app_id),
      ("name", js(shown_name)),
      ("teamId", js(team)),
      ("by", js(by)),
      ("created", self.backend.ask("ops/fibers.wall.now", [])),
    ]).filter_undef()
    let client_id = app.get("clientId").unwrap_or(jundef)
    let client_secret = app.get("clientSecret").unwrap_or(jundef)
    if !(redirect is Null) &&
      !(place is Null) &&
      client_id != js("") &&
      client_secret != js("") {
      // Which station it is for goes with it, so still.fail cloud's page knows where to hand the code.
      let random = hex_of(
        bytes_of(self.backend.ask("crypto.randomBytes", [jint(16)])).unwrap_or(
          b"",
        ),
      )
      let state = "\{js_string(place.get("workspace"))}/\{js_string(place.get("station"))}~\{random}"
      let scopes = jitems(
        field_of(
          field_of(field_of(Some(manifest), "oauth_config"), "scopes"),
          "bot",
        ),
      ).filter_map(s => jstr(Some(s)))
      let install = "https://slack.com/oauth/v2/authorize?client_id=\{url_encode(js_string(Some(client_id)))}&scope=\{url_encode(scopes.join(","))}&redirect_uri=\{url_encode(js_string(Some(redirect)))}&state=\{url_encode(state)}"
      made = jset(
        made,
        "oauth",
        jobj([
          ("state", js(state)),
          ("clientId", client_id),
          ("clientSecret", client_secret),
          ("redirectUri", redirect),
          ("install", js(install)),
        ]),
      )
    }
    let kept = made
    edits.change(r, "slack app \{js_string(Some(app_id))}", async fn(raw) {
      jset(raw, "slackApps", jarr(jitems(raw.get("slackApps")) + [kept]))
    })
    ok(jobj([("appId", app_id), ("iconError", icon_error)]).filter_undef())
  }
  let slack_app = async fn(r : Request, id : String) -> Answer {
    let groups = jstrs(slack_groups)
    let app = app_id(id) catch {
      e =>
        match refused_of(e) {
          Some(_) => raise e
          None =>
            // The bot token no longer works, so the app cannot be looked up; the Slack section says why.
            return ok(
              jobj([
                ("state", js("no_app")),
                ("appId", Null),
                ("links", Null),
                ("settings", Null),
                ("groups", groups),
                ("error", slack_error(e, r.lang)),
              ]),
            )
        }
    }
    if app is Null {
      return ok(
        jobj([
          ("state", js("no_app")),
          ("appId", Null),
          ("links", Null),
          ("settings", Null),
          ("groups", groups),
        ]),
      )
    }
    let links = slack_fn("slackAppLinks", [app, team_of(id)])
    let by = r.email()
    if !is_truthy(Some(apps("configured", [js(by)]))) {
      return ok(
        jobj([
          ("state", js("no_config_token")),
          ("appId", app),
          ("links", links),
          ("settings", Null),
          ("groups", groups),
        ]),
      )
    }
    try {
      let manifest = apps("exportManifest", [js(by), app])
      ok(
        jobj([
          ("state", js("ok")),
          ("appId", app),
          ("links", links),
          ("settings", slack_fn("settingsOf", [manifest])),
          ("groups", groups),
        ]),
      )
    } catch {
      e =>
        ok(
          jobj([
            ("state", js("error")),
            ("appId", app),
            ("links", links),
            ("settings", Null),
            ("groups", groups),
            ("error", slack_error(e, r.lang)),
          ]),
        )
    }
  }
  let put_app = async fn(r : Request, id : String, i : JV) -> Answer {
    let lang = r.lang
    let app = app_id(id)
    if app is Null {
      raise Refused(400, self.tr(lang, "station.slackApp.none"))
    }
    let mut edit = JV::Obj([])
    for
      key in [
        "name", "displayName", "description", "longDescription", "backgroundColor",
      ] {
      match i.get(key) {
        Some(Str(_) as v) => edit = jset(edit, key, v)
        _ => ()
      }
    }
    match groups_of(i.get("groups")) {
      Some(g) => edit = jset(edit, "groups", g)
      None => ()
    }
    match edit.get("name") {
      Some(Str(n)) if trim_js(n) == "" =>
        raise Refused(400, self.tr(lang, "station.slackApp.nameEmpty"))
      _ => ()
    }
    match edit.get("backgroundColor") {
      Some(Str(c)) if c != "" && !color_ok(c) =>
        raise Refused(400, self.tr(lang, "station.slackApp.badColor"))
      _ => ()
    }
    let by = r.email()
    let given = edit
    let permissions_updated = try {
      let cb = self.callback_answering(async fn(args) {
        slack_fn("applySettings", [args.get(0).unwrap_or(jundef), given])
      })
      apps("editManifest", [js(by), app, cb])
    } catch {
      e =>
        raise Refused(
          400,
          self.tr(lang, "station.slackApp.updateRefused", args=[
            ("error", js_string(Some(slack_error(e, lang)))),
          ]),
        )
    }
    let icon_error = match i.get("icon") {
      Some(Str(icon)) if icon != "" => set_icon(by, app, icon, lang)
      _ => Null
    }
    // Its name here is its bot's in Slack: read again now, and once more when Slack has surely taken the change.
    if edit.get("name") is Some(_) || edit.get("displayName") is Some(_) {
      let refresh = async fn() {
        self.backend.tell("slack.refreshIdentity", [js(id)]) catch {
          e =>
            self.log(
              "warn",
              "slack",
              "slack identity refresh failed",
              jobj([("connect", js(id)), ("error", js(message_of(e)))]),
            )
        }
      }
      self.later(refresh)
      let again = self.callback(async fn(_) { refresh() })
      self.backend.tell("ops/fibers.wall.after", [jint(8000), again])
    }
    self.log(
      "info",
      "slack",
      "slack app updated from the admin page",
      jobj([
        ("connect", js(id)),
        ("app", app),
        ("permissionsUpdated", permissions_updated),
        ("by", js(by)),
      ]).filter_undef(),
    )
    ok(
      jobj([
        ("permissionsUpdated", permissions_updated),
        ("iconError", icon_error),
        ("links", slack_fn("slackAppLinks", [app, team_of(id)])),
      ]).filter_undef(),
    )
  }
  let create_app = async fn(r : Request, id : String, i : JV) -> Answer {
    let lang = r.lang
    guard connects().iter().find_first(c => id_is(c, id)) is Some(connect) else {
      raise Refused(404, "unknown connect \{id}")
    }
    if !(app_id(id) is Null) {
      raise Refused(400, self.tr(lang, "station.slackApp.already"))
    }
    let name = match i.get("name") {
      Some(Str(n)) if trim_js(n) != "" => js(trim_js(n))
      _ => slack_fn("connectName", [connect])
    }
    let team = team_for(i, r)
    let app = apps("createApp", [
      js(r.email()),
      js(team),
      slack_fn("slackManifest", [name]),
    ]) catch {
      e =>
        raise Refused(
          400,
          self.tr(lang, "station.slackApp.createFailed", args=[
            ("error", js_string(Some(slack_error(e, lang)))),
          ]),
        )
    }
    let app_id = app.get("appId").unwrap_or(jundef)
    edits.change(r, "create slack app for \{id}", async fn(raw) {
      let raw = with_connects(raw)
      jset(
        raw,
        "connects",
        jarr(
          connects_of(raw).map(c => {
            if id_is(c, id) {
              jset(
                c,
                "slack",
                jset(
                  match field_of(Some(c), "slack") {
                    Some(Obj(_) as s) => s
                    _ => Obj([])
                  },
                  "appId",
                  app_id,
                ),
              )
            } else {
              c
            }
          }),
        ),
      )
    })
    ok(
      jobj([
        ("appId", app_id),
        ("links", slack_fn("slackAppLinks", [app_id, js(team)])),
      ]).filter_undef(),
    )
  }
  let add_config_token = async fn(r : Request, i : JV) -> Answer {
    let lang = r.lang
    let refresh = trim_js(text_of(i.get("refreshToken")))
    if !refresh.has_prefix("xoxe-") {
      raise Refused(400, self.tr(lang, "station.slackApp.badRefreshToken"))
    }
    let token = slack_fn("rotateConfigToken", [
      jref("slack.client"),
      js(refresh),
    ]) catch {
      e =>
        raise Refused(
          400,
          self.tr(lang, "station.slackApp.tokenRefused", args=[
            ("error", message_of(e)),
          ]),
        )
    }
    let owner = slack_fn("ownerOfConfigToken", [
      jref("slack.client"),
      token.get("accessToken").unwrap_or(jundef),
    ])
    let by = r.email()
    let made = jobj(
      [
        ("accessToken", token.get("accessToken").unwrap_or(jundef)),
        ("refreshToken", token.get("refreshToken").unwrap_or(jundef)),
        ("expiresAt", token.get("expiresAt").unwrap_or(jundef)),
        ("teamId", token.get("teamId").unwrap_or(jundef)),
        ("by", js(by)),
      ] +
      (if owner is Null { [] } else { [("owner", owner)] }),
    ).filter_undef()
    let raw = self.config_raw()
    let next = jset(
      raw,
      "slackConfigTokens",
      slack_fn("upsertToken", [jarr(jitems(raw.get("slackConfigTokens"))), made]),
    )
    self.backend.tell("config.updateSoon", [next])
    self.log(
      "info",
      "slack",
      "slack configuration token added",
      jobj([("team", token.get("teamId").unwrap_or(jundef)), ("by", js(by))]).filter_undef(),
    )
    ok(
      jobj([
        ("teamId", token.get("teamId").unwrap_or(jundef)),
        ("overview", self.overview_of(r)),
      ]).filter_undef(),
    )
  }
  let installed = async fn(r : Request, i : JV) -> Answer {
    let lang = r.lang
    let state = text_of(i.get("state"))
    let oauth = field_of(made_app(state), "oauth")
    if state == "" ||
      oauth is None ||
      field_of(oauth, "state") != Some(js(state)) {
      raise Refused(400, self.tr(lang, "station.slackApp.installNotOurs"))
    }
    let o = oauth.unwrap()
    let pair = jitems(
      Some(
        apps("exchangeInstallCode", [
          o.get("clientId").unwrap_or(jundef),
          o.get("clientSecret").unwrap_or(jundef),
          js(text_of(i.get("code"))),
          o.get("redirectUri").unwrap_or(jundef),
        ]),
      ),
    ) catch {
      e =>
        raise Refused(
          400,
          self.tr(lang, "station.slackApp.installFailed", args=[
            ("error", js_string(Some(slack_error(e, lang)))),
          ]),
        )
    }
    let bot_token = pair.get(0).unwrap_or(jundef)
    let team = pair.get(1).unwrap_or(Null)
    self.config_update(raw => {
      match raw.get("slackApps") {
        Some(Arr(list)) =>
          jset(
            raw,
            "slackApps",
            jarr(
              list.map(app => {
                match field_of(Some(app), "oauth") {
                  Some(Obj(_) as oa) if oa.get("state") == Some(js(state)) => {
                    let mut oa = jset(oa, "botToken", bot_token)
                    oa = if team is Null {
                      jdel(oa, "installedTeam")
                    } else {
                      jset(oa, "installedTeam", team)
                    }
                    jset(app, "oauth", oa)
                  }
                  _ => app
                }
              }),
            ),
          )
        _ => raw
      }
    })
    self.log(
      "info",
      "slack",
      "slack app installed",
      jobj([("state", js(state)), ("team", team)]),
    )
    self.overview_changed()
    ok(jobj([("team", team)]))
  }
  let verify = async fn(r : Request, i : JV) -> Answer {
    let stored = match i.get("connect") {
      Some(Str(cid)) => {
        let mut found = None
        for c in connects() {
          if c.get("id") == Some(js(edits.mine(r, cid))) {
            found = Some(c)
            break
          }
        }
        found
      }
      _ => None
    }
    let pick = (key : String, kept : JV?) => {
      match i.get(key) {
        Some(Str(g)) if trim_js(g) != "" => js(trim_js(g))
        _ =>
          match kept {
            Some(k) if !nullish(k) => k
            _ => js("")
          }
      }
    }
    let app_token = pick("appToken", field_of(stored, "appToken"))
    let from_install = match i.get("install") {
      Some(Str(k)) => field_of(field_of(made_app(k), "oauth"), "botToken")
      _ => None
    }
    let bot_token = match from_install {
      Some(b) if !is_undef(b) => b
      _ => pick("botToken", field_of(stored, "botToken"))
    }
    let pair = jitems(
      Some(apps("verifyTokens", [app_token, bot_token, js(r.lang)])),
    )
    let identity = pair.get(0).unwrap_or(Null)
    ok(
      jobj([
        (
          "identity",
          if identity is Null {
            Null
          } else {
            slack_fn("shownIdentity", [identity])
          },
        ),
        ("errors", pair.get(1).unwrap_or(jundef)),
      ]).filter_undef(),
    )
  }
  let people = async fn(r : Request) -> Answer {
    let found : Array[JV] = []
    let seen : Array[String] = []
    let errors = []
    for connect in connects() {
      let entry = edits
        .listed()
        .iter()
        .find_first(c => field_of(Some(c), "id") == connect.get("id"))
      if !edits.of_viewer(r, entry) {
        continue
      }
      guard ref_of(
          self.backend.ask("slack.chat", [connect.get("id").unwrap_or(jundef)]),
        )
        is Some(chat) else {
        continue
      }
      let mut cursor = ""
      while true {
        let params = jobj(
          [("limit", jint(200))] +
          (if cursor != "" { [("cursor", js(cursor))] } else { [] }),
        )
        let page = self.backend.ask(chat + ".api", [js("users.list"), params]) catch {
          e => {
            let name = js_string(Some(slack_fn("connectName", [connect])))
            errors.push(
              js(
                self.tr(r.lang, "station.list.labeled", args=[
                  ("name", name),
                  ("note", message_of(e)),
                ]),
              ),
            )
            break
          }
        }
        for m in jitems(field_of(Some(page), "members")) {
          let profile = field_of(Some(m), "profile")
          let email = @jscase.lower(
            jstr(field_of(profile, "email")).unwrap_or(""),
          )
          let skip = field_of(Some(m), "is_bot") is Some(Bool(true)) ||
            field_of(Some(m), "deleted") is Some(Bool(true)) ||
            field_of(Some(m), "id") == Some(js("USLACKBOT")) ||
            email == ""
          if skip || seen.contains(email) {
            continue
          }
          seen.push(email)
          let name = [
              field_of(profile, "real_name"),
              field_of(Some(m), "real_name"),
              field_of(Some(m), "name"),
            ]
            .iter()
            .find_first(n => n is Some(Str(s)) && s != "")
          let name = match name {
            Some(Some(n)) => n
            _ => js(email)
          }
          found.push(
            jobj([
              ("email", js(email)),
              ("name", name),
              (
                "image",
                match field_of(profile, "image_72") {
                  Some(Str(_) as i) => i
                  _ => Null
                },
              ),
              (
                "guest",
                jbool(
                  field_of(Some(m), "is_restricted") is Some(Bool(true)) ||
                  field_of(Some(m), "is_ultra_restricted") is Some(Bool(true)),
                ),
              ),
              (
                "team",
                match field_of(field_of(Some(connect), "team"), "name") {
                  Some(n) if !nullish(n) => n
                  _ => Null
                },
              ),
            ]),
          )
        }
        cursor = match
          field_of(field_of(Some(page), "response_metadata"), "next_cursor") {
          Some(Str(n)) => n
          _ => ""
        }
        if cursor == "" {
          break
        }
      }
    }
    let sorted = stable_sort(found, (a, b) => {
      let g = (if a.get("guest") is Some(Bool(true)) { 1 } else { 0 }) -
        (if b.get("guest") is Some(Bool(true)) { 1 } else { 0 })
      if g != 0 {
        return g
      }
      let c = js_compare(js_string(a.get("name")), js_string(b.get("name")))
      if c < 0 {
        -1
      } else if c > 0 {
        1
      } else {
        0
      }
    })
    ok(jobj([("people", jarr(sorted)), ("errors", jarr(errors))]))
  }
  [
    route(
      "POST",
      "^\\/connects$",
      answer(async fn(r, _) { new_connect(r, input(r)) }),
    ),
    route(
      "POST",
      "^\\/slack\\/apps$",
      answer(async fn(r, _) { make_app(r, input(r)) }),
    ),
    route(
      "POST",
      "^\\/slack\\/installs$",
      answer(async fn(r, _) { installed(r, input(r)) }),
    ),
    route(
      "POST",
      "^\\/slack\\/verify$",
      answer(async fn(r, _) { verify(r, input(r)) }),
    ),
    route(
      "POST",
      "^\\/slack\\/config-tokens$",
      answer(async fn(r, _) { add_config_token(r, input(r)) }),
    ),
    route("GET", "^\\/slack\\/people$", answer(async fn(r, _) { people(r) })),
    route(
      "GET",
      "^\\/slack\\/create-app-url$",
      answer(async fn(r, _) {
        let name = match r.param("name") {
          Some(n) => trim_js(n)
          None => ""
        }
        if name == "" {
          raise Refused(400, "name is required")
        }
        ok(jobj([("url", slack_fn("createAppUrl", [js(name)]))]))
      }),
    ),
  ] +
  ["PUT", "DELETE"].map(verb => {
    route(
      verb,
      "^\\/*me\\/+slack\\/+([^/]+)\\/*$",
      answer(async fn(r, m) {
        self.backend.tell("store.setSlackIdentity", [
          js(r.email()),
          js(segment(m[0].unwrap())),
          jbool(verb == "PUT"),
        ])
        ok(self.overview_of(r))
      }),
    )
  }) +
  [
    // A made app dropped from the waiting ones (it stays in Slack); only its maker's to drop.
    route(
      "DELETE",
      "^\\/*slack\\/+apps\\/+([^/]+)(?:\\/.*)?$",
      answer(async fn(r, m) {
        let app = segment(m[0].unwrap())
        let by = r.email()
        let mine = jitems(Some(slack_fn("madeApps", [edits.raw()])))
          .iter()
          .any(x => {
            x.get("appId") == Some(js(app)) && x.get("by") == Some(js(by))
          })
        if !mine {
          raise Refused(404, self.tr(r.lang, "station.slackApp.notFound"))
        }
        ok(
          edits.save(r, "slack app \{app} dropped", async fn(raw) {
            jset(
              raw,
              "slackApps",
              jarr(
                jitems(raw.get("slackApps")).filter(x => {
                  field_of(Some(x), "appId") != Some(js(app))
                }),
              ),
            )
          }),
        )
      }),
    ),
    route(
      "DELETE",
      "^\\/*slack\\/+config-tokens\\/+([^/]+)(?:\\/.*)?$",
      answer(async fn(r, m) {
        let team = segment(m[0].unwrap())
        let by = r.email()
        ok(
          edits.save(r, "slack configuration token removed", async fn(raw) {
            jset(
              raw,
              "slackConfigTokens",
              jarr(
                jitems(raw.get("slackConfigTokens")).filter(x => {
                  field_of(Some(x), "by") != Some(js(by)) ||
                  field_of(Some(x), "teamId") != Some(js(team))
                }),
              ),
            )
          }),
        )
      }),
    ),
    route(
      "GET",
      "^\\/*connects\\/+([^/]+)\\/+slack-app(?:\\/.*)?$",
      answer(async fn(r, m) {
        slack_app(r, edits.mine(r, segment(m[0].unwrap())))
      }),
    ),
    route(
      "PUT",
      "^\\/*connects\\/+([^/]+)\\/+slack-app(?:\\/.*)?$",
      answer(async fn(r, m) {
        let id = edits.mine(r, segment(m[0].unwrap()))
        put_app(r, id, input(r))
      }),
    ),
    route(
      "POST",
      "^\\/*connects\\/+([^/]+)\\/+slack-app(?:\\/.*)?$",
      answer(async fn(r, m) {
        let id = edits.mine(r, segment(m[0].unwrap()))
        create_app(r, id, input(r))
      }),
    ),
  ]
}
