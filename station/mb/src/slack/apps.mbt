// Managing a connect's Slack app from still.fail (station/src/slack/apps.ts): its name, description, colour, icon and
// permissions live in the app's manifest, which Slack lets a workspace member change with an app configuration token.
// The token lasts 12 hours; its refresh token (single use) yields the next pair, so the station keeps both and rotates
// as needed. Permission changes still need a person to approve them in Slack; the station hands them the link. Also
// the manifest a new app starts from, and the link that opens Slack's "create app" page with it filled in.

///|
/// A permission group in plain words: the scopes and events it adds to the app.
pub struct SlackGroup {
  id : String
  label : String
  description : String
  scopes : Array[String]
  events : Array[String]
}

///|
pub fn SlackGroup::to_j(self : SlackGroup) -> J {
  jo([
    ("id", js(self.id)),
    ("label", js(self.label)),
    ("description", js(self.description)),
    ("scopes", jsa(self.scopes)),
    ("events", jsa(self.events)),
  ])
}

///|
/// Permissions in plain words. Each group adds its scopes and events to the app; "base" is always on.
pub let slack_groups : Array[SlackGroup] = [
  {
    id: "base",
    label: "读取和回复消息",
    description: "被 @ 或用 /sf 时收到消息，读取所在频道、私信和群聊的消息并回复，干活时在 thread 里显示进度。",
    scopes: [
      "app_mentions:read", "chat:write", "channels:history", "groups:history", "im:history", "mpim:history", "channels:read",
      "groups:read", "im:read", "mpim:read", "users:read", "assistant:write",
      // `/sf` (new_chat_command): Slack takes no slash command without it.
      "commands",
    ],
    events: ["agent_session_stopped", "app_mention", "message.channels", "message.groups", "message.im", "message.mpim"],
  },
  {
    id: "public",
    label: "在没加入的公开频道发言",
    description: "不用先邀请，也能在公开频道回复。",
    scopes: ["chat:write.public", "channels:join"],
    events: [],
  },
  { id: "dm", label: "主动发私信", description: "给人或多人开启私信对话。", scopes: ["im:write", "mpim:write"], events: [] },
  {
    id: "customize",
    label: "用别的名字和头像发消息",
    description: "每条消息可以换显示名和头像。",
    scopes: ["chat:write.customize"],
    events: [],
  },
  {
    id: "files",
    label: "读写文件",
    description: "读取消息里的附件，上传截图、日志等文件。",
    scopes: ["files:read", "files:write", "remote_files:read", "remote_files:write", "remote_files:share"],
    events: ["file_shared"],
  },
  {
    id: "reactions",
    label: "表情回应、置顶和书签",
    description: "用表情标记进度，置顶消息，管理频道书签。",
    scopes: ["reactions:read", "reactions:write", "pins:read", "pins:write", "bookmarks:read", "bookmarks:write"],
    events: ["reaction_added", "reaction_removed"],
  },
  {
    id: "channels",
    label: "创建和管理频道",
    description: "建频道、邀请成员，知道有人加入或新建频道。",
    scopes: ["channels:manage", "groups:write"],
    events: ["member_joined_channel", "channel_created"],
  },
  {
    id: "people",
    label: "查看成员资料",
    description: "读取邮箱、个人资料、用户组、工作区信息和自定义表情。",
    scopes: ["users:read.email", "users.profile:read", "usergroups:read", "team:read", "emoji:read"],
    events: [],
  },
  {
    id: "extras",
    label: "链接预览、提醒和状态",
    description: "展开链接、设置提醒、读取勿扰和通话状态。",
    scopes: ["links:read", "links:write", "reminders:read", "reminders:write", "dnd:read", "calls:read"],
    events: [],
  },
  {
    id: "canvases",
    label: "读写 canvas",
    description: "新建、编辑和读取 canvas 文档，比如把方案、报告写成频道里的 canvas。",
    scopes: ["canvases:read", "canvases:write"],
    events: [],
  },
  {
    id: "lists",
    label: "读写列表",
    description: "新建、编辑和读取 Slack 列表（Lists），比如维护任务清单。",
    scopes: ["lists:read", "lists:write"],
    events: [],
  },
  {
    id: "topics",
    label: "改频道话题和邀请成员",
    description: "设置频道和私信的话题、用途，把人邀请进频道。",
    scopes: [
      "channels:write.invites", "channels:write.topic", "groups:write.invites", "groups:write.topic", "im:write.topic",
      "mpim:write.topic",
    ],
    events: [],
  },
  {
    id: "usergroups",
    label: "管理用户组和发起通话",
    description: "建用户组、改成员，发起和更新 Slack 通话。",
    scopes: ["usergroups:write", "calls:write"],
    events: [],
  },
  // Real-time search: of its kinds only these three take a bot token (private channels and DMs need a person's).
  {
    id: "search",
    label: "搜索消息、文件和成员",
    description: "在公开频道里搜消息和文件、按名字找人，回答问题时自己找上下文。",
    scopes: ["search:read.public", "search:read.files", "search:read.users"],
    events: [],
  },
  {
    id: "connect",
    label: "Slack Connect 跨组织频道",
    description: "查看、发出和接受和别的公司共享频道的邀请。",
    scopes: ["conversations.connect:read", "conversations.connect:write", "conversations.connect:manage"],
    events: [],
  },
  {
    id: "more",
    label: "状态和元数据",
    description: "设置自己的在线状态，读取消息元数据和工作区设置，嵌入视频链接。",
    scopes: ["users:write", "metadata.message:read", "team.preferences:read", "links.embed:write"],
    events: [],
  },
]

///|
/// What a Slack app the station makes is called when nobody named it.
pub let default_app_name : String = "still.fail"

///|
/// The slash command that opens a new chat with a model picked (surface.mbt `new_chat`): over Socket Mode, so no url.
pub let new_chat_command : String = "/sf"

///|
/// A value as JavaScript's String() writes it, absent as "" (and anything not a string as JSON).
fn app_text(v : J?) -> String {
  match v {
    None | Some(Null) => ""
    Some(Str(u)) => @jsjson.sanitize_str(u)
    Some(x) => stringify(x)
  }
}

///|
fn known_scopes() -> Array[String] {
  slack_groups.map(g => g.scopes).flatten()
}

///|
fn known_events() -> Array[String] {
  slack_groups.map(g => g.events).flatten()
}

///|
/// The first `n` UTF-16 units of `s` (`s.slice(0, n)`).
fn slice_units(s : String, n : Int) -> String {
  if s.length() <= n {
    s
  } else {
    s.unsafe_substring(start=0, end=n)
  }
}

///|
/// The form's view of a manifest. A group counts as on when all its scopes are there.
pub fn settings_of(manifest : J?) -> J {
  let scopes = strings(at_path(manifest, ["oauth_config", "scopes", "bot"]))
  let groups = jo(slack_groups.map(g => (g.id, jb(g.scopes.iter().all(s => scopes.contains(s))))))
  jo([
    ("name", js(app_text(at_path(manifest, ["display_information", "name"])))),
    ("displayName", js(app_text(at_path(manifest, ["features", "bot_user", "display_name"])))),
    ("description", js(app_text(at_path(manifest, ["display_information", "description"])))),
    ("longDescription", js(app_text(at_path(manifest, ["display_information", "long_description"])))),
    ("backgroundColor", js(app_text(at_path(manifest, ["display_information", "background_color"])))),
    ("groups", groups),
  ])
}

///|
fn set_or_delete(target : J, key : String, value : String) -> J {
  if value == "" {
    drop(target, key)
  } else {
    put(target, key, js(value))
  }
}

///|
/// Applies form edits to a manifest (`edit`: what is given changes, the rest stays: name, displayName, description,
/// longDescription, backgroundColor, groups). Turning a group off removes only what no group that stays on needs;
/// scopes the station does not know about are kept.
pub fn apply_settings(manifest : J?, edit : J?) -> J {
  let mut next = match manifest {
    Some(Obj(_) as m) => m
    _ => jo([])
  }
  let edited = (k : String) => str_of(at(edit, k))
  next = put(next, "display_information", obj_at(next, "display_information"))
  let mut features = obj_at(next, "features")
  next = put(next, "features", features)
  if nullish(at(Some(features), "bot_user")) {
    let shown = match edited("displayName") {
      Some(d) => d
      None => edited("name").unwrap_or(default_app_name)
    }
    features = put(features, "bot_user", jo([("display_name", js(shown)), ("always_online", jb(true))]))
  }
  // People can always message the bot directly (an app made before this is fixed by any change to it).
  let home = obj_at(features, "app_home")
    |> put("messages_tab_enabled", jb(true))
    |> put("messages_tab_read_only_enabled", jb(false))
  features = put(features, "app_home", home)
  let mut info = obj_at(next, "display_information")
  match edited("name") {
    Some(n) => info = put(info, "name", js(trim(n)))
    None => ()
  }
  match edited("displayName") {
    Some(d) => features = put(features, "bot_user", put(obj_at(features, "bot_user"), "display_name", js(trim(d))))
    None => ()
  }
  next = put(next, "features", features)
  match edited("description") {
    Some(d) => info = set_or_delete(info, "description", trim(d))
    None => ()
  }
  match edited("longDescription") {
    Some(d) => info = set_or_delete(info, "long_description", trim(d))
    None => ()
  }
  match edited("backgroundColor") {
    Some(d) => info = set_or_delete(info, "background_color", trim(d))
    None => ()
  }
  next = put(next, "display_information", info)
  // Every save puts in what "base" has now (an app made before a scope joined it gets it), and the groups as edited.
  let now = settings_of(manifest)
  let given = at(edit, "groups")
  let on = slack_groups.filter(g => {
    g.id == "base" ||
    (match at(given, g.id) {
      None | Some(Null) => truthy(at_path(Some(now), ["groups", g.id]))
      x => truthy(x)
    })
  })
  let keep_scopes = unique(on.map(g => g.scopes).flatten())
  let keep_events = unique(on.map(g => g.events).flatten())
  let known = known_scopes()
  let events_known = known_events()
  let scopes = unique(
    strings(at_path(Some(next), ["oauth_config", "scopes", "bot"])).filter(s => !known.contains(s) ||
      keep_scopes.contains(s)) +
    keep_scopes,
  )
  let events = unique(
    strings(at_path(Some(next), ["settings", "event_subscriptions", "bot_events"])).filter(e => !events_known.contains(
        e,
      ) ||
      keep_events.contains(e)) +
    keep_events,
  )
  next = with_obj(next, "oauth_config", o => with_obj(o, "scopes", s => put(s, "bot", jsa(scopes))))
  next = with_obj(next, "settings", s => with_obj(s, "event_subscriptions", e => put(e, "bot_events", jsa(events))))
  // Cards' buttons come over Socket Mode (an app made before them gets them on its next save).
  if is_true(at_path(Some(next), ["settings", "socket_mode_enabled"])) {
    next = with_obj(next, "settings", s => with_obj(s, "interactivity", i => put(i, "is_enabled", jb(true))))
  }
  with_command(next)
}

///|
/// The events of the groups on (base always).
fn events_on(groups : J?) -> Array[String] {
  slack_groups.filter(g => g.id == "base" || is_true(at(groups, g.id))).map(g => g.events).flatten()
}

///|
fn agent_description(manifest : J?) -> String {
  let d = trim(app_text(at_path(manifest, ["display_information", "description"])))
  slice_units(if d == "" { "A coding agent in your threads (still.fail)" } else { d }, 300)
}

///|
/// Enable the agent and its native stop event on an existing Socket Mode app. Keep an existing assistant view: moving
/// one to the new agent view is irreversible. None means there is nothing to change.
pub fn with_stop_event(manifest : J?) -> J? {
  if !is_true(at_path(manifest, ["settings", "socket_mode_enabled"])) {
    return None
  }
  let events = strings(at_path(manifest, ["settings", "event_subscriptions", "bot_events"]))
  let has_view = is_obj(at_path(manifest, ["features", "agent_view"])) ||
    is_obj(at_path(manifest, ["features", "assistant_view"]))
  let stops = events.contains("agent_session_stopped")
  if stops && has_view {
    return None
  }
  let mut next = manifest.unwrap_or(Null)
  if !stops {
    next = with_obj(next, "settings", s => with_obj(s, "event_subscriptions", e => {
      put(e, "bot_events", jsa(events + ["agent_session_stopped"]))
    }))
  }
  if !has_view {
    let d = agent_description(Some(next))
    next = with_obj(next, "features", f => put(f, "agent_view", jo([("agent_description", js(d))])))
  }
  Some(next)
}

///|
/// A manifest with `/sf` when its bot may take slash commands (the `commands` scope: Slack refuses a command without
/// it), without it otherwise. Other commands stay as they are.
pub fn with_command(manifest : J) -> J {
  let next = manifest
  let features = obj_at(next, "features")
  let others = arr(at(Some(features), "slash_commands")).filter(c => {
    str_of(at(Some(c), "command")) != Some(new_chat_command)
  })
  let on = is_true(at_path(Some(next), ["settings", "socket_mode_enabled"])) &&
    strings(at_path(Some(next), ["oauth_config", "scopes", "bot"])).contains("commands")
  let commands = if on {
    others +
    [
      jo([
        ("command", js(new_chat_command)),
        ("description", js("Start a chat with a model you pick")),
        ("usage_hint", js("[what to say]")),
        ("should_escape", jb(false)),
      ]),
    ]
  } else {
    others
  }
  let features = if commands.length() > 0 {
    put(features, "slash_commands", ja(commands))
  } else {
    drop(features, "slash_commands")
  }
  put(next, "features", features)
}

///|
/// An existing app brought up to date as the station maintains it (index.mbt): the native stop event and agent view
/// (`with_stop_event`), and `/sf` (`with_command`). None: nothing to change.
pub fn upgraded(manifest : J) -> J? {
  let stopped = with_stop_event(Some(manifest)).unwrap_or(manifest)
  let next = with_command(stopped)
  if stringify(next) == stringify(manifest) {
    None
  } else {
    Some(next)
  }
}

///|
/// A manifest with Socket Mode off or on. Off, it has no events or interactivity either (Slack asks those of an app
/// without Socket Mode to go to a URL). On, its events are those of the groups it has on, and its cards' buttons come
/// over the socket.
pub fn with_socket_mode(manifest : J?, on : Bool) -> J {
  let next = match manifest {
    Some(Obj(_) as m) => m
    _ => jo([])
  }
  let mut settings = obj_at(next, "settings") |> put("socket_mode_enabled", jb(on))
  if !on {
    settings = drop(settings, "event_subscriptions") |> put("interactivity", jo([("is_enabled", jb(false))]))
    return with_command(put(next, "settings", settings))
  }
  settings = with_obj(settings, "interactivity", i => put(i, "is_enabled", jb(true)))
  let events = events_on(at(Some(settings_of(manifest)), "groups"))
  let known = known_events()
  let others = strings(at_path(Some(settings), ["event_subscriptions", "bot_events"])).filter(e => !known.contains(e))
  settings = with_obj(settings, "event_subscriptions", e => put(e, "bot_events", jsa(unique(others + events))))
  with_command(put(next, "settings", settings))
}

///|
/// Every bot scope of every permission group.
pub fn bot_scopes() -> Array[String] {
  unique(known_scopes())
}

///|
/// The Slack app manifest for a still.fail connect. Every permission group is on. `redirect_url`: where Slack sends a
/// person who installed it (still.fail cloud's page that hands the code to the station).
pub fn slack_manifest(name : String, description? : String? = None, redirect_url? : String? = None) -> J {
  let oauth = [("scopes", jo([("bot", jsa(bot_scopes()))]))]
  match redirect_url {
    Some(u) => oauth.push(("redirect_urls", jsa([u])))
    None => ()
  }
  let shown = match description {
    Some(d) if trim(d) != "" => trim(d)
    _ => "A coding agent in your threads (still.fail)"
  }
  with_command(
    jo([
      (
        "display_information",
        jo([
          ("name", js(name)),
          ("description", js(description.unwrap_or("Coding agent in your threads (still.fail)"))),
          ("background_color", js("#7a2e0e")),
        ]),
      ),
      // The Messages tab lets people message the bot directly; without it Slack says messaging the app is turned off.
      (
        "features",
        jo([
          ("bot_user", jo([("display_name", js(name)), ("always_online", jb(true))])),
          (
            "app_home",
            jo([
              ("home_tab_enabled", jb(false)),
              ("messages_tab_enabled", jb(true)),
              ("messages_tab_read_only_enabled", jb(false)),
            ]),
          ),
          ("agent_view", jo([("agent_description", js(slice_units(shown, 300)))])),
        ]),
      ),
      ("oauth_config", jo(oauth)),
      (
        "settings",
        jo([
          ("event_subscriptions", jo([("bot_events", jsa(unique(known_events())))])),
          ("interactivity", jo([("is_enabled", jb(true))])),
          ("org_deploy_enabled", jb(false)),
          ("socket_mode_enabled", jb(true)),
          ("token_rotation_enabled", jb(false)),
        ]),
      ),
    ]),
  )
}

///|
pub fn create_app_url(name : String) -> String {
  "https://api.slack.com/apps?new_app=1&manifest_json=\{@session_chats.encode_uri_component(stringify(slack_manifest(name)))}"
}

///|
/// An error said in words from the catalog (`key`), in the station's language as its message.
pub fn slack_words(words : Words, lang : String, key : String) -> SlackWords {
  SlackWords(key, words.tr(lang, key))
}

///|
/// Slack's error codes in words people can act on; other errors as they are.
pub fn slack_error(words : Words, e : Error, lang : String) -> String {
  match e {
    SlackWords(key, _) => words.tr(lang, key)
    SlackApiError(_, code, details) => {
      let key = match code {
        "invalid_auth" => Some("station.slackApi.invalidAuth")
        "token_expired" => Some("station.slackApi.tokenExpired")
        "invalid_refresh_token" => Some("station.slackApi.invalidRefreshToken")
        "not_allowed_token_type" => Some("station.slackApi.notConfigToken")
        "app_not_found" => Some("station.slackApi.appNotFound")
        "invalid_manifest" => Some("station.slackApi.invalidManifest")
        _ => None
      }
      let known = match key {
        Some(k) => words.tr(lang, k)
        None => code
      }
      let said = match details {
        Some(Arr(ds)) =>
          ds
          .map(d => trim("\{app_text(at(Some(d), "pointer"))} \{app_text(at(Some(d), "message"))}"))
          .join(words.tr(lang, "station.list.semicolon"))
        _ => ""
      }
      if said == "" {
        known
      } else if known == "" {
        said
      } else {
        words.tr(lang, "station.slackApi.withDetails", args=[("error", known), ("details", said)])
      }
    }
    e => message_of(e)
  }
}

///|
/// An installation's code (from Slack's redirect) exchanged for its bot token, with the workspace it went into.
pub async fn exchange_install_code(
  client : SlackClient,
  client_id : String,
  client_secret : String,
  code : String,
  redirect_uri : String,
) -> (String, String?) {
  let data = client.app("oauth.v2.access", None, [
    ("client_id", client_id),
    ("client_secret", client_secret),
    ("code", code),
    ("redirect_uri", redirect_uri),
  ])
  let team = match at_path(Some(data), ["team", "name"]) {
    Some(Str(u)) if u.length() > 0 => Some(@jsjson.sanitize_str(u))
    _ => None
  }
  (app_text(at(Some(data), "access_token")), team)
}

///|
/// Exchanges a refresh token for a fresh pair (`{accessToken, refreshToken, expiresAt, teamId}`). The old refresh
/// token stops working.
pub async fn rotate_config_token(client : SlackClient, refresh_token : String) -> J {
  let data = client.app("tooling.tokens.rotate", None, [("refresh_token", trim(refresh_token))])
  let exp = match at(Some(data), "exp") {
    Some(Num(d)) if d == d.floor() && d.abs() <= 9007199254740991.0 => d
    _ => 0.0
  }
  jo([
    ("accessToken", js(app_text(at(Some(data), "token")))),
    ("refreshToken", js(app_text(at(Some(data), "refresh_token")))),
    ("expiresAt", jn(exp * 1000.0)),
    ("teamId", js(app_text(at(Some(data), "team_id")))),
  ])
}

///|
/// Which app a bot token belongs to.
pub async fn app_id_of(client : SlackClient, bot_token : String) -> String {
  let auth = client.app("auth.test", Some(bot_token), [])
  let bot = client.app("bots.info", Some(bot_token), [("bot", app_text(at(Some(auth), "bot_id")))])
  app_text(at_path(Some(bot), ["bot", "app_id"]))
}

///|
/// Pages in Slack's app settings a person may need (`{settings, install, appToken, oauth}`).
pub fn slack_app_links(app_id : String, team_id : String?) -> J {
  match team_id {
    None => {
      let apps = "https://api.slack.com/apps"
      jo([("settings", js(apps)), ("install", js(apps)), ("appToken", js(apps)), ("oauth", js(apps))])
    }
    Some(team) => {
      let base = "https://app.slack.com/app-settings/\{team}/\{app_id}"
      // An app-level token is made from the Socket Mode page: there Slack has its scope (connections:write) picked.
      jo([
        ("settings", js(base)),
        ("install", js("\{base}/install-on-team")),
        ("appToken", js("\{base}/socket-mode")),
        ("oauth", js("\{base}/oauth")),
      ])
    }
  }
}

///|
/// Who a configuration token belongs to and in which workspace, as Slack shows them; None if Slack will not say.
pub async fn owner_of_config_token(client : SlackClient, access_token : String) -> J? {
  let auth = client.app("auth.test", Some(access_token), []) catch {
    _ => return None
  }
  let asked = @effect.all([
    async fn() {
      let d = client.app("users.info", Some(access_token), [("user", app_text(at(Some(auth), "user_id")))]) catch {
        _ => return J::Null
      }
      at(Some(d), "user").unwrap_or(Null)
    },
    async fn() {
      let d = client.app("team.info", Some(access_token), []) catch { _ => return J::Null }
      at(Some(d), "team").unwrap_or(Null)
    },
  ])
  let user = Some(asked[0])
  let team = Some(asked[1])
  let some = (v : J?) => match v {
    Some(Str(u)) if u.length() > 0 => Some(@jsjson.sanitize_str(u))
    _ => None
  }
  let user_name = match some(at_path(user, ["profile", "display_name"])) {
    Some(n) => n
    None =>
      match some(at(user, "real_name")) {
        Some(n) => n
        None => app_text(at(Some(auth), "user"))
      }
  }
  Some(
    jo([
      (
        "team",
        js(
          match some(at(team, "name")) {
            Some(n) => n
            None => app_text(at(Some(auth), "team"))
          },
        ),
      ),
      ("teamDomain", jopt(some(at(team, "domain")))),
      ("teamIcon", jopt(some(at_path(team, ["icon", "image_68"])))),
      ("user", js(user_name)),
      ("email", jopt(some(at_path(user, ["profile", "email"])))),
      ("image", jopt(some(at_path(user, ["profile", "image_48"])))),
    ]),
  )
}

///|
/// The tokens with this one in, in place of its person's old one for the workspace (an owner it lacks kept).
pub fn upsert_token(tokens : Array[J], token : J) -> Array[J] {
  let out = tokens.copy()
  let same = (t : J) => jeq(at(Some(t), "by"), at(Some(token), "by")) &&
    jeq(at(Some(t), "teamId"), at(Some(token), "teamId"))
  match out.search_by(same) {
    None => out.push(token)
    Some(i) => {
      let owner = match at(Some(token), "owner") {
        None => at(Some(out[i]), "owner")
        o => o
      }
      out[i] = match owner {
        Some(o) => put(token, "owner", o)
        None => drop(token, "owner")
      }
    }
  }
  out
}

///|
/// `a === b` of two values JSON gives (undefined only as itself).
fn jeq(a : J?, b : J?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(Str(x)), Some(Str(y))) => x == y
    (Some(Num(x)), Some(Num(y))) => x == y
    (Some(Bool(x)), Some(Bool(y))) => x == y
    (Some(Null), Some(Null)) => true
    _ => false
  }
}

///|
/// A JSON value's shape, for the log: its keys, and of each string only its kind (an xapp-/xoxb-/… token, or text).
pub fn shape_of(v : J) -> J {
  match v {
    Arr(xs) => Arr(xs.map(shape_of))
    Null => js("object")
    Obj(fs) => Obj(fs.map(f => (f.0, shape_of(f.1))))
    Str(u) => {
      let s = @jsjson.sanitize_str(u)
      let token = s.length() >= 5 &&
        s.unsafe_charcode_at(0) == 'x'.to_int() &&
        s.unsafe_charcode_at(4) == '-'.to_int() &&
        (1).until(4).all(i => {
          let c = s.unsafe_charcode_at(i)
          c >= 'a'.to_int() && c <= 'z'.to_int()
        })
      if token {
        js("\{s.unsafe_substring(start=0, end=5)}…")
      } else {
        js("string")
      }
    }
    Num(_) => js("number")
    Bool(_) => js("boolean")
  }
}

///|
/// What the station logs, by level ("info", "warn", "error"), part, words and their details.
pub type Log = (String, String, String, J) -> Unit

///|
/// One at a time per key, in order (a chain of promises in the TypeScript: each waits for the one before, failed or
/// not).
priv struct Chains {
  tails : Map[String, @effect.Deferred[Unit]]
}

///|
async fn[X] Chains::run(self : Chains, key : String, f : async () -> X) -> X {
  let before = self.tails.get(key)
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.tails[key] = mine
  match before {
    Some(b) => b.wait() catch { _ => () }
    None => ()
  }
  let done = () => {
    ignore(mine.succeed(()))
    match self.tails.get(key) {
      Some(t) if physical_equal(t, mine) => self.tails.remove(key)
      _ => ()
    }
  }
  let out = f() catch {
    e => {
      done()
      raise e
    }
  }
  done()
  out
}

///|
/// The Slack app API with the configuration tokens (apps.ts `SlackApps`): a person's own (`by`), one per Slack
/// workspace; nobody uses another's. `load` and `save` keep them in the station's config, so a rotation survives
/// restarts.
pub struct SlackApps {
  client : SlackClient
  load : () -> Array[J]
  save : async (J) -> Unit
  words : Words
  lang : Ref[String]
  log : Log
  /// One rotation at a time per person and workspace: the refresh token works once.
  priv rotating : Chains
  /// Which workspace's token owns an app, once known.
  owner : Map[String, String]
  priv edits : Chains
}

///|
pub fn SlackApps::new(
  client : SlackClient,
  load : () -> Array[J],
  save : async (J) -> Unit,
  words : Words,
  lang : Ref[String],
  log : Log,
) -> SlackApps {
  { client, load, save, words, lang, log, rotating: { tails: {} }, owner: {}, edits: { tails: {} } }
}

///|
/// Whether this person has a token of their own.
pub fn SlackApps::configured(self : SlackApps, by : String) -> Bool {
  (self.load)().iter().any(t => str_of(at(Some(t), "by")) == Some(by))
}

///|
pub async fn SlackApps::export_manifest(self : SlackApps, by : String, app_id : String) -> J {
  let data = self.for_app(by, app_id, "apps.manifest.export", [("app_id", app_id)])
  match at(Some(data), "manifest") {
    None | Some(Null) => Null
    Some(m) => m
  }
}

///|
/// Validates, then updates. Whether Slack wants the permissions approved again.
pub async fn SlackApps::update_manifest(self : SlackApps, by : String, app_id : String, manifest : J) -> Bool {
  let params = [("app_id", app_id), ("manifest", stringify(manifest))]
  ignore(self.for_app(by, app_id, "apps.manifest.validate", params))
  let data = self.for_app(by, app_id, "apps.manifest.update", params)
  is_true(at(Some(data), "permissions_updated"))
}

///|
/// Read and change one manifest in order with the station's other edits; None from `edit` leaves it alone.
pub async fn SlackApps::edit_manifest(
  self : SlackApps,
  by : String,
  app_id : String,
  edit : async (J) -> J?,
) -> Bool {
  self.edits.run(app_id, async fn() {
    match edit(self.export_manifest(by, app_id)) {
      None => false
      Some(m) => self.update_manifest(by, app_id, m)
    }
  })
}

///|
/// Makes the app in one of this person's workspaces (`team`); its OAuth credentials come only now, once
/// (`{appId, clientId, clientSecret}`).
pub async fn SlackApps::create_app(self : SlackApps, by : String, team : String, manifest : J) -> J {
  let token = self.token(by, team)
  let data = self.client.app("apps.manifest.create", Some(token), [("manifest", stringify(manifest))])
  // What Slack answers beyond what is read here, by shape only (never a value).
  (self.log)("info", "slack", "slack app made", jo([("shape", shape_of(data))]))
  let app_id = app_text(at(Some(data), "app_id"))
  self.owner["\{by}|\{app_id}"] = team
  jo([
    ("appId", js(app_id)),
    ("clientId", js(app_text(at_path(Some(data), ["credentials", "client_id"])))),
    ("clientSecret", js(app_text(at_path(Some(data), ["credentials", "client_secret"])))),
  ])
}

///|
/// `mime`: the picture's (image/png or image/jpeg).
pub async fn SlackApps::set_icon(self : SlackApps, by : String, app_id : String, picture : Bytes, mime : String) -> Unit {
  let file : FilePart = if mime == "image/jpeg" {
    { bytes: picture, name: "icon.jpg", mime: "image/jpeg" }
  } else {
    { bytes: picture, name: "icon.png", mime: "image/png" }
  }
  ignore(self.for_app(by, app_id, "apps.icon.set", [("app_id", app_id)], file~))
}

///|
pub async fn SlackApps::exchange_install_code(
  self : SlackApps,
  client_id : String,
  client_secret : String,
  code : String,
  redirect_uri : String,
) -> (String, String?) {
  exchange_install_code(self.client, client_id, client_secret, code, redirect_uri)
}

///|
pub async fn SlackApps::verify_tokens(
  self : SlackApps,
  app_token : String,
  bot_token : String,
  lang : String,
) -> (J?, Array[String]) {
  verify_slack_tokens(self.words, self.client, app_token, bot_token, lang)
}

///|
/// A call about an app, with the person's token that owns it: the one known, else each in turn until one is not
/// refused.
async fn SlackApps::for_app(
  self : SlackApps,
  by : String,
  app_id : String,
  meth : String,
  params : Params,
  file? : FilePart,
) -> J {
  let key = "\{by}|\{app_id}"
  let call = async fn(token : String) -> J {
    match file {
      Some(f) => self.client.app(meth, Some(token), params, file=f)
      None => self.client.app(meth, Some(token), params)
    }
  }
  match self.owner.get(key) {
    Some(known) => return call(self.token(by, known))
    None => ()
  }
  let tokens = (self.load)().filter(t => str_of(at(Some(t), "by")) == Some(by))
  if tokens.length() == 0 {
    raise slack_words(self.words, self.lang.val, "station.slackApi.noConfigToken")
  }
  let mut last : Error? = None
  for t in tokens {
    let team = js_str(at(Some(t), "teamId"))
    let data = (try Ok(call(self.token(by, team))) catch { e => Err(e) })
    match data {
      Ok(d) => {
        self.owner[key] = team
        return d
      }
      Err(e) => last = Some(e)
    }
  }
  match last {
    Some(e) => raise e
    None => raise fail_("unreachable")
  }
}

///|
/// A working access token of a person's workspace, rotating first when the current one is about to expire.
async fn SlackApps::token(self : SlackApps, by : String, team : String) -> String {
  let current = () => {
    let all = (self.load)()
    match
      all.search_by(t => str_of(at(Some(t), "by")) == Some(by) && str_of(at(Some(t), "teamId")) == Some(team)) {
      Some(i) => Some(all[i])
      None => None
    }
  }
  let fresh = (t : J) => js_num(at(Some(t), "expiresAt")) - (self.client.net.now)() > 300000.0
  let token = match current() {
    Some(t) => t
    None => raise slack_words(self.words, self.lang.val, "station.slackApi.noTokenForTeam")
  }
  if fresh(token) {
    return js_str(at(Some(token), "accessToken"))
  }
  self.rotating.run("\{by}|\{team}", async fn() {
    // Another call may have rotated it meanwhile: its refresh token is spent, the pair it made is the one to use.
    let now = match current() {
      Some(t) => t
      None => raise slack_words(self.words, self.lang.val, "station.slackApi.noTokenForTeam")
    }
    if fresh(now) {
      return js_str(at(Some(now), "accessToken"))
    }
    let next = rotate_config_token(self.client, js_str(at(Some(now), "refreshToken")))
    (self.log)("info", "slack", "slack configuration token rotated", jo([("team", at(Some(next), "teamId").unwrap_or(Null))]))
    let mut kept = jo([
      ("accessToken", at(Some(next), "accessToken").unwrap_or(Null)),
      ("refreshToken", at(Some(next), "refreshToken").unwrap_or(Null)),
      ("expiresAt", at(Some(next), "expiresAt").unwrap_or(Null)),
      ("teamId", at(Some(next), "teamId").unwrap_or(Null)),
      ("by", js(by)),
    ])
    match at(Some(now), "owner") {
      Some(o) => kept = put(kept, "owner", o)
      None => ()
    }
    (self.save)(kept)
    js_str(at(Some(next), "accessToken"))
  })
}
