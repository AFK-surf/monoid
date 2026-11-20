// Slack on the station (station/src/slack/index.ts): its connects as config.json has them, what the overview shows of
// them, the configuration tokens and the apps made with them, and what keeps a connected connect's app up to date (the
// native stop button, `/sf`). Which connects are connected and their names book are every platform's
// (connects/connects.ts); they are given here as a `ConnectsView`.

///|
/// A connect as config.json has it, as far as its connection goes (config.rs `Connect`, `SlackTokens`).
pub(all) struct SlackConnect {
  id : String
  enabled : Bool
  app_token : String
  bot_token : String
  app_id : String?
  /// Its Slack workspace, as last seen (`id`, `name`).
  team : (String, String)?
  bot_name : String?
  bot_image : String?
  /// Who added or was handed the connect: only their configuration token maintains its app.
  owner : String?
  /// The still.fail workspace it was added in; None: the station's home one.
  workspace : String?
}

///|
pub fn SlackConnect::to_j(self : SlackConnect) -> J {
  jo([
    ("id", js(self.id)),
    ("enabled", jb(self.enabled)),
    ("appToken", js(self.app_token)),
    ("botToken", js(self.bot_token)),
    ("appId", jopt(self.app_id)),
    (
      "team",
      match self.team {
        Some((id, name)) => jo([("id", js(id)), ("name", js(name))])
        None => Null
      },
    ),
    ("botName", jopt(self.bot_name)),
    ("botImage", jopt(self.bot_image)),
    ("owner", jopt(self.owner)),
    ("workspace", jopt(self.workspace)),
  ])
}

///|
/// What a connect is called: its bot's name in its Slack workspace, else its id.
pub fn connect_name(c : SlackConnect) -> String {
  c.bot_name.unwrap_or(c.id)
}

///|
fn non_empty(v : J?) -> String? {
  match v {
    Some(Str(u)) if u.length() > 0 => Some(@jsjson.sanitize_str(u))
    _ => None
  }
}

///|
/// ops/agent-env.ts `maskValue`: a token's start and end, the rest left out.
pub fn mask_value(value : String) -> String {
  if value == "" {
    return ""
  }
  let cs = points(value)
  if cs.length() <= 8 {
    return "••••"
  }
  let head = String::from_array(cs[0:5].to_array())
  let tail = String::from_array(cs[cs.length() - 4:].to_array())
  "\{head}…\{tail}"
}

///|
/// What a Slack connect is known by in the overview (its config.json entry `raw`): its bot's name in its Slack
/// workspace and that workspace, as last seen; its tokens masked.
pub fn slack_shown(raw : J?) -> J {
  let slack = match at(raw, "slack") {
    None | Some(Null) => Some(jo([]))
    s => s
  }
  let fs = []
  match non_empty(at(slack, "botName")) {
    Some(n) => fs.push(("name", js(n)))
    None =>
      match at(raw, "id") {
        Some(id) => fs.push(("name", id))
        None => ()
      }
  }
  let team = at(slack, "team")
  fs.push((
    "team",
    if truthy(at(team, "id")) {
      match at(team, "name") {
        None | Some(Null) => js("")
        n => n.unwrap()
      }
    } else {
      Null
    },
  ))
  fs.push(("botImage", jopt(non_empty(at(slack, "botImage")))))
  let token = (k : String) => match at(slack, k) {
    None | Some(Null) => ""
    v => js_str(v)
  }
  fs.push(("slack", jo([("appToken", js(mask_value(token("appToken")))), ("botToken", js(mask_value(token("botToken"))))])))
  jo(fs)
}

///|
/// config.json's Slack connects (those of no other kind), as their connections read them.
pub fn slack_connects(raw : J?) -> Array[SlackConnect] {
  arr(at(raw, "connects"))
  .filter(c => match at(Some(c), "kind") {
    None | Some(Null) => true
    Some(Str(_) as k) => str_of(Some(k)) == Some("slack")
    _ => false
  })
  .map(c => {
    let cc = Some(c)
    let slack = match at(cc, "slack") {
      None | Some(Null) => Some(jo([]))
      s => s
    }
    let team = at(slack, "team")
    {
      id: match at(cc, "id") {
        None | Some(Null) => ""
        v => js_str(v)
      },
      enabled: !(at(cc, "enabled") is Some(Bool(false))),
      app_token: text(at(slack, "appToken")),
      bot_token: text(at(slack, "botToken")),
      app_id: non_empty(at(slack, "appId")),
      team: match (team, non_empty(at(team, "id"))) {
        (Some(Obj(_) | Arr(_)), Some(id)) => Some((id, text(at(team, "name"))))
        _ => None
      },
      bot_name: non_empty(at(slack, "botName")),
      bot_image: non_empty(at(slack, "botImage")),
      owner: non_empty(at_path(cc, ["createdBy", "id"])),
      workspace: non_empty(at(cc, "workspace")),
    }
  })
}

///|
/// A connect's credentials (what tells its connection changed): its two tokens, None while either is missing.
pub fn slack_credentials(c : SlackConnect) -> String? {
  if c.app_token == "" || c.bot_token == "" {
    None
  } else {
    Some("\{c.app_token}\n\{c.bot_token}")
  }
}

///|
/// What a connected connect is known by now (its Slack workspace and its bot's name there, as Slack says), written into
/// its config.json entry: None when that is what it has.
pub fn slack_seen(c : SlackConnect, i : BotIdentity) -> ((J) -> J)? {
  if i.team_id == "" {
    return None
  }
  match c.team {
    Some((id, name)) if id == i.team_id && name == i.team && c.bot_name == Some(i.bot_name) && c.bot_image == i.bot_image =>
      return None
    _ => ()
  }
  Some(entry => {
    let mut slack = match at(Some(entry), "slack") {
      Some(Obj(_) as s) => s
      _ => jo([])
    }
    slack = put(slack, "team", jo([("id", js(i.team_id)), ("name", js(i.team))]))
    slack = put(slack, "botName", js(i.bot_name))
    slack = match i.bot_image {
      Some(img) => put(slack, "botImage", js(img))
      None => drop(slack, "botImage")
    }
    put(entry, "slack", slack)
  })
}

///|
/// What is not yet anyone's of config.json's Slack parts: its configuration tokens, filtered as config.rs does.
pub fn config_tokens(raw : J?) -> Array[J] {
  arr(at(raw, "slackConfigTokens")).filter(t => {
    let tt = Some(t)
    is_obj(tt) && non_empty(at(tt, "refreshToken")) is Some(_) && non_empty(at(tt, "teamId")) is Some(_) &&
    non_empty(at(tt, "by")) is Some(_)
  })
}

///|
/// The Slack apps the station made with someone's configuration token, waiting for their connect.
pub fn made_apps(raw : J?) -> Array[J] {
  arr(at(raw, "slackApps")).filter(a => {
    let aa = Some(a)
    is_obj(aa) && non_empty(at(aa, "appId")) is Some(_) && non_empty(at(aa, "by")) is Some(_)
  })
}

///|
fn push_some(fs : Array[(String, J)], k : String, v : J?) -> Unit {
  match v {
    Some(x) => fs.push((k, x))
    None => ()
  }
}

///|
fn or_null(v : J?) -> J {
  match v {
    None | Some(Null) => Null
    Some(x) => x
  }
}

///|
/// The overview's Slack parts for a viewer (`{slackApps, slackTeams}`).
pub fn slack_overview(raw : J?, by : String) -> J {
  let tokens = config_tokens(raw)
  let apps = made_apps(raw)
    .filter(a => str_of(at(Some(a), "by")) == Some(by))
    .map(a => {
      let aa = Some(a)
      let team_id = at(aa, "teamId")
      let links = slack_app_links(js_str(at(aa, "appId")), match team_id {
        Some(Null) => None
        t => Some(js_str(t))
      })
      let team = match tokens.search_by(t => jeq(at(Some(t), "teamId"), team_id)) {
        Some(i) => or_null(at_path(Some(tokens[i]), ["owner", "team"]))
        None => Null
      }
      let fs = []
      push_some(fs, "appId", at(aa, "appId"))
      push_some(fs, "name", at(aa, "name"))
      push_some(fs, "teamId", team_id)
      fs.push(("team", team))
      push_some(fs, "created", at(aa, "created"))
      fs.push(("links", links))
      fs.push(("install", or_null(at_path(aa, ["oauth", "install"]))))
      fs.push(("state", or_null(at_path(aa, ["oauth", "state"]))))
      fs.push(("installed", jb(str_of(at_path(aa, ["oauth", "botToken"])) is Some(_))))
      fs.push(("installedTeam", or_null(at_path(aa, ["oauth", "installedTeam"]))))
      jo(fs)
    })
  let teams = tokens
    .filter(t => str_of(at(Some(t), "by")) == Some(by))
    .map(t => {
      let tt = Some(t)
      let name = match at_path(tt, ["owner", "team"]) {
        n if truthy(n) => n.unwrap()
        _ => or_null(at(tt, "teamId"))
      }
      jo([("teamId", or_null(at(tt, "teamId"))), ("name", name), ("owner", or_null(at(tt, "owner")))])
    })
  jo([("slackApps", ja(apps)), ("slackTeams", ja(teams))])
}

///|
/// What a platform's connects give of each connect (connects/connects.ts), as the upgrade of its app reads them: the
/// connects, each one's state ("connected", …), its connection's workspace and bot user (None: no connection), whether
/// the station is in its workspace, and config.json as it is now.
pub struct ConnectsView {
  connects : () -> Array[SlackConnect]
  state : (String) -> String?
  /// A connection's (workspace, bot user id).
  chat : (String) -> (String?, String)?
  bound : () -> Bool
  in_workspace : (String?) -> Bool
  raw : () -> J
}

///|
/// What keeps connected apps up to date as well as new ones (index.ts `makeConnections`' upgrade): a configuration
/// token lets the station maintain that app; Slack still decides whether its owner may edit it. Tried once per
/// configuration, and again when a token or connection changes, or a real turn begins (`on_working`).
pub struct Upgrades {
  view : ConnectsView
  apps : SlackApps
  client : SlackClient
  log : Log
  run : (async () -> Unit) -> Unit
  attempted : Map[String, String]
  completed : Map[String, String]
  upgrading : Map[String, @effect.Deferred[Unit]]
  mut closed : Bool
}

///|
pub fn Upgrades::new(
  view : ConnectsView,
  apps : SlackApps,
  log : Log,
  run : (async () -> Unit) -> Unit,
) -> Upgrades {
  { view, apps, client: apps.client, log, run, attempted: {}, completed: {}, upgrading: {}, closed: false }
}

///|
/// Tried for every connect that may be (a change of the connects or of config.json, a reconcile).
pub fn Upgrades::upgrade_apps(self : Upgrades) -> Unit {
  if self.closed {
    return
  }
  if !(self.view.bound)() {
    self.attempted.clear()
    return
  }
  let tokens = config_tokens(Some((self.view.raw)()))
  for c in (self.view.connects)() {
    if !c.enabled || !(self.view.in_workspace)(c.workspace) || (self.view.state)(c.id) != Some("connected") {
      self.attempted.remove(c.id)
      continue
    }
    let connection = (self.view.chat)(c.id)
    let team = match connection {
      Some((Some(w), _)) => Some(w)
      _ =>
        match c.team {
          Some((id, _)) => Some(id)
          None => None
        }
    }
    let owner = match c.owner {
      Some(o) => o
      None => continue
    }
    let own = tokens.filter(t => str_of(at(Some(t), "by")) == Some(owner))
    if own.length() == 0 {
      continue
    }
    let version_of = (all : Array[J]) => stringify(
      ja([
        jopt(c.app_id),
        jopt(team),
        match connection {
          Some((_, bot)) => js(bot)
          None => Null
        },
        js(owner),
        ja(
          all
          .filter(t => str_of(at(Some(t), "by")) == Some(owner))
          .map(t => ja([or_undefined(at(Some(t), "teamId")), or_undefined(at(Some(t), "expiresAt"))])),
        ),
      ]),
    )
    let version = version_of(tokens)
    if self.upgrading.contains(c.id) ||
      self.completed.get(c.id) == Some(version) ||
      self.attempted.get(c.id) == Some(version) {
      continue
    }
    self.attempted[c.id] = version
    let done : @effect.Deferred[Unit] = @effect.Deferred::new()
    self.upgrading[c.id] = done
    (self.run)(async fn() {
      let worked = try Ok({
        let app = match c.app_id {
          Some(a) => a
          None => app_id_of(self.client, c.bot_token)
        }
        if app == "" {
          raise fail_("the Slack app id is unavailable")
        }
        let applicable = Ref(false)
        ignore(
          self.apps.edit_manifest(owner, app, async fn(manifest) {
            let current = (self.view.connects)().search_by(e => e.id == c.id)
            let current = match current {
              Some(i) => Some((self.view.connects)()[i])
              None => None
            }
            let still = match current {
              Some(cur) =>
                !self.closed &&
                (self.view.bound)() &&
                (self.view.in_workspace)(c.workspace) &&
                cur.enabled &&
                cur.owner == c.owner &&
                cur.app_id == c.app_id &&
                cur.bot_token == c.bot_token &&
                (self.view.state)(c.id) == Some("connected")
              None => false
            }
            if !still {
              return None
            }
            match manifest {
              Obj(_) | Arr(_) => ()
              _ => raise fail_("Slack returned no app manifest")
            }
            applicable.val = true
            upgraded(manifest)
          }),
        )
        if applicable.val {
          self.completed[c.id] = version_of(config_tokens(Some((self.view.raw)())))
        }
      }) catch { e => Err(e) }
      match worked {
        Ok(_) => ()
        Err(e) =>
          (self.log)(
            "warn",
            "slack",
            "could not bring the app up to date (native stop button, /sf)",
            jo([("connect", js(c.id)), ("error", js(message_of(e)))]),
          )
      }
      self.upgrading.remove(c.id)
      ignore(done.succeed(()))
      self.upgrade_apps()
    })
  }
}

///|
/// A value of a list as JSON.stringify writes it (undefined there as null).
fn or_undefined(v : J?) -> J {
  match v {
    None => Null
    Some(x) => x
  }
}

///|
/// A real turn began in a connect's thread: the opportunity to retry its app's setup if it failed (there is no timer
/// polling Slack). Whether its app is up to date.
pub async fn Upgrades::on_working(self : Upgrades, id : String) -> Bool {
  match self.upgrading.get(id) {
    Some(d) => d.wait() catch { _ => () }
    None => ()
  }
  self.attempted.remove(id)
  self.upgrade_apps()
  match self.upgrading.get(id) {
    Some(d) => d.wait() catch { _ => () }
    None => ()
  }
  self.completed.contains(id)
}

///|
/// Ends it: nothing is tried again; what is under way is waited for.
pub async fn Upgrades::close(self : Upgrades) -> Unit {
  self.closed = true
  for d in self.upgrading.values().collect() {
    d.wait() catch {
      _ => ()
    }
  }
}

///|
/// The configuration tokens kept in config.json, a rotated one written into its list (index.ts's `save`).
pub fn kept_config_token(raw : J, token : J) -> J {
  let tokens = arr(at(Some(raw), "slackConfigTokens"))
  put(raw, "slackConfigTokens", ja(upsert_token(tokens, token)))
}
