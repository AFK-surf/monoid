// Feishu on the station (station/src/feishu/index.ts and module.ts): its connects as config.json says them (each
// kept connected as every platform's are, connects/connects.ts: the connects' own), where its chats' words go
// (<data>/feishu-threads.json), the apps being made by a scan (<data>/feishu-registrations.json), what the overview
// shows of them, and feishu_api for the agents.

///|
/// A Feishu connect as config.json has it, as far as its connection goes.
#derive(Eq, Debug)
pub(all) struct FeishuConnect {
  id : String
  enabled : Bool
  app_id : String
  app_secret : String
  domain : String
  /// Thread mode: each thread of a group its own conversation (only where each conversation has its own session).
  threads : Bool
  bot_name : String?
  bot_image : String?
  bot_open_id : String?
  tenant : (String, String)?
  workspace : String?
}

///|
pub fn FeishuConnect::to_jv(self : FeishuConnect) -> JV {
  jobj([
    ("id", Some(js(self.id))),
    ("enabled", Some(Bool(self.enabled))),
    ("appId", Some(js(self.app_id))),
    ("appSecret", Some(js(self.app_secret))),
    ("domain", Some(js(self.domain))),
    ("threads", Some(Bool(self.threads))),
    ("botName", Some(jopt(self.bot_name))),
    ("botImage", Some(jopt(self.bot_image))),
    ("botOpenId", Some(jopt(self.bot_open_id))),
    (
      "tenant",
      Some(
        match self.tenant {
          Some((key, name)) =>
            jobj([("key", Some(js(key))), ("name", Some(js(name)))])
          None => Null
        },
      ),
    ),
    ("workspace", Some(jopt(self.workspace))),
  ])
}

///|
fn non_empty(v : JV?) -> String? {
  match v {
    Some(Str(s)) if s != "" => Some(s)
    _ => None
  }
}

///|
/// The Feishu connects of config.json.
pub fn feishu_connects(raw : JV) -> Array[FeishuConnect] {
  jitems(jget(Some(raw), "connects"))
  .filter(c => jget(Some(c), "kind") == Some(Str("feishu")))
  .map(c => {
    let f = nullish(jget(Some(c), "feishu"), Obj([]))
    let tenant = jget(Some(f), "tenant")
    {
      id: js_string(Some(nullish(jget(Some(c), "id"), Str("")))),
      enabled: jget(Some(c), "enabled") != Some(Bool(false)),
      app_id: text(jget(Some(f), "appId")),
      app_secret: text(jget(Some(f), "appSecret")),
      domain: domain_of(jget(Some(f), "domain")),
      threads: jget(Some(f), "threads") == Some(Bool(true)) &&
      jget(Some(c), "mode") != Some(Str("single-session")),
      bot_name: non_empty(jget(Some(f), "botName")),
      bot_image: non_empty(jget(Some(f), "botImage")),
      bot_open_id: non_empty(jget(Some(f), "botOpenId")),
      tenant: match non_empty(jget(tenant, "key")) {
        Some(key) => Some((key, text(jget(tenant, "name"))))
        None => None
      },
      workspace: non_empty(jget(Some(c), "workspace")),
    }
  })
}

///|
/// An app's secret as the pages are shown it.
pub fn mask_secret(s : String) -> String {
  if s.length() <= 4 {
    if s == "" {
      ""
    } else {
      "••••"
    }
  } else {
    "••••" + slice_js(s, -4)
  }
}

///|
/// What tells one connect's connection from another's: none for a connect without an app (its connection is not made).
pub fn credentials(c : FeishuConnect) -> String? {
  if c.app_id == "" || c.app_secret == "" {
    None
  } else {
    Some("\{c.domain}\n\{c.app_id}\n\{c.app_secret}\n\{c.threads}")
  }
}

///|
/// What config.json's entry of `c` is to be changed by, as its bot is seen (`i`): its bot's name and picture, its
/// company; None where it says so already.
pub fn seen_patch(c : FeishuConnect, i : BotIdentity) -> ((JV) -> Unit)? {
  let tenant = if i.team_id != "" { Some((i.team_id, i.team)) } else { c.tenant }
  let tenant_jv = (t : (String, String)?) => match t {
    Some((key, name)) => jobj([("key", Some(js(key))), ("name", Some(js(name)))])
    None => Null
  }
  if c.bot_name == Some(i.bot_name) &&
    c.bot_image == i.bot_image &&
    c.bot_open_id == Some(i.bot_user_id) &&
    stringify(tenant_jv(c.tenant)) == stringify(tenant_jv(tenant)) {
    return None
  }
  Some(entry => {
    let f = match entry.get("feishu") {
      Some(Obj(_) as f) => f
      // (an array is an object to JavaScript: what is set on it is kept by nothing written)
      Some(Arr(_)) => Obj([])
      _ => {
        let f = JV::Obj([])
        jput(entry, "feishu", f)
        f
      }
    }
    jput(f, "botName", js(i.bot_name))
    jput(f, "botOpenId", js(i.bot_user_id))
    match i.bot_image {
      Some(img) => jput(f, "botImage", js(img))
      None => jdelete(f, "botImage")
    }
    match tenant {
      Some(_) => jput(f, "tenant", tenant_jv(tenant))
      None => ()
    }
  })
}

///|
/// What the overview says of a Feishu connect besides what all connects say (`live`: who its bot is, where it is
/// connected).
pub fn shown(raw : JV, live : BotIdentity?) -> JV {
  let f = nullish(jget(Some(raw), "feishu"), Obj([]))
  let name = match non_empty(jget(Some(f), "botName")) {
    Some(n) => Some(js(n))
    None =>
      match live {
        Some(l) => Some(js(l.bot_name))
        None =>
          match jget(Some(raw), "id") {
            None => None
            Some(id) => Some(id)
          }
      }
  }
  let team = match non_empty(jget(jget(Some(f), "tenant"), "name")) {
    Some(t) => js(t)
    None =>
      match live {
        Some(l) if l.team != "" => js(l.team)
        _ => Null
      }
  }
  jobj([
    ("name", name),
    ("team", Some(team)),
    ("botImage", Some(jopt(non_empty(jget(Some(f), "botImage"))))),
    (
      "feishu",
      Some(
        jobj([
          ("appId", Some(js(text(jget(Some(f), "appId"))))),
          ("appSecret", Some(js(mask_secret(text(jget(Some(f), "appSecret")))))),
          ("domain", Some(js(domain_of(jget(Some(f), "domain"))))),
          ("threads", Some(Bool(jget(Some(f), "threads") == Some(Bool(true))))),
        ]),
      ),
    ),
  ])
}

///|
/// What the Feishu connects are made of, besides the connects' own: where its chats' words go, the apps being made by
/// a scan, and how a connect's surface is made.
pub struct Feishu {
  threads : FeishuThreads
  registrations : Registrations
  priv net : Net
  priv words : Words
  priv log : Log
  priv disk : Disk
  priv rt : @effect.Runtime
}

///|
/// `makeFeishu`: its threads read from <data>/feishu-threads.json and its registrations from
/// <data>/feishu-registrations.json, on `rt`.
pub async fn make_feishu(
  rt : @effect.Runtime,
  data : String,
  sep : String,
  net : Net,
  words : Words,
  log : Log,
  disk : Disk,
  random_hex : (Int) -> String,
  exec_path : String,
) -> Feishu {
  let threads = FeishuThreads::open(
    disk,
    log,
    @nodepath.join(sep, [data, "feishu-threads.json"]),
  )
  let registrations = Registrations::new(rt, {
    post: async fn(domain, form) { registration_post(net, domain, form) },
    file: Some(@nodepath.join(sep, [data, "feishu-registrations.json"])),
    disk,
    log,
    words,
    random_hex,
    exec_path,
  })
  { threads, registrations, net, words, log, disk, rt }
}

///|
/// A connect's surface (`create`'s default).
pub fn Feishu::create(
  self : Feishu,
  c : FeishuConnect,
  book : NameBook?,
) -> FeishuSurface raise FeishuError {
  FeishuSurface::new({
    connect: c.id,
    app_id: c.app_id,
    app_secret: c.app_secret,
    domain: c.domain,
    threads: self.threads,
    thread_mode: c.threads,
    book,
    client: None,
    net: self.net,
    words: self.words,
    log: self.log,
    disk: self.disk,
    rt: self.rt,
  })
}

///|
/// What the overview lists of the apps a viewer is making by a scan (module.ts `feishuRegistrations`).
pub fn Feishu::overview(
  self : Feishu,
  email : String,
  workspace : String?,
) -> JV {
  Arr(self.registrations.of(email, workspace?).map(shown_registration))
}

///|
/// Its registrations closed, then what its threads changed written.
pub async fn Feishu::close(self : Feishu) -> Unit {
  self.registrations.close()
  self.threads.written()
}

///|
/// feishu_api for the agents (module.ts `feishuTools`): its declaration and its call.
pub fn Feishu::tool(
  _self : Feishu,
  world : () -> ToolWorld?,
  is_feishu : (String) -> Bool,
) -> (JV, async (String, JV) -> String) {
  (feishu_api_tool(), async fn(key, args) {
    feishu_api_run(world(), is_feishu, key, args)
  })
}
