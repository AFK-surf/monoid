// sandbox.ts and sandbox-name.ts: sandboxes as targets of station_task (config.json's `sandboxes`, each an l4es front
// door or a Google Colab VM of kind "colab"), what station_list says of one, and what the shell runs in place of a
// job's command there (the bridge, carried over ssh, or colab-sandbox.mjs).

///|
/// `SANDBOX`: how a sandbox is named as a station of station_task's.
pub let sandbox_prefix : String = "sandbox:"

///|
/// `COLAB_GPUS`: GPUs a Colab sandbox may name.
pub let colab_gpus : Array[String] = ["T4", "L4", "G4", "A100", "H100"]

///|
/// `COLAB_REAP_MS`: how often idle Colab VMs are reaped.
pub let colab_reap_ms : Int = 60000

///|
/// `colabPool`: where the station keeps its bounded-ephemeral Colab CLI venv, synced CLI homes and VM records.
pub fn colab_pool(data : String) -> String {
  join([data, "colab"])
}

///|
/// `CONNECTION_LOST`, `LOST_EXIT`.
pub let connection_lost : String = "sandbox: the connection to the sandbox was lost"

///|
pub let lost_exit : Int = 75

///|
/// `Sandbox`: an l4es front door (`kind == ""` or `"l4es"`) or a Colab VM (`kind == "colab"`, `gpu`).
pub(all) struct Sandbox {
  name : String
  kind : String
  target : String
  size : String?
  identity : String?
  gpu : String?
}

///|
pub fn is_colab(d : Sandbox) -> Bool {
  d.kind == "colab"
}

///|
pub fn default_colab_sandboxes() -> Array[Sandbox] {
  [
    { name: "colab-g4", kind: "colab", target: "", size: None, identity: None, gpu: Some("G4") },
    { name: "colab-l4", kind: "colab", target: "", size: None, identity: None, gpu: Some("L4") },
    { name: "colab-t4", kind: "colab", target: "", size: None, identity: None, gpu: Some("T4") },
  ]
}

///|
pub fn Sandbox::json(self : Sandbox) -> J {
  if is_colab(self) {
    let f = Fields::of([("name", js(self.name)), ("kind", js("colab"))])
    if self.gpu is Some(g) {
      f.set_str("gpu", g)
    }
    return f.json()
  }
  let f = Fields::of([("name", js(self.name)), ("target", js(self.target))])
  if self.kind == "l4es" {
    f.set_str("kind", "l4es")
  }
  if self.size is Some(s) {
    f.set_str("size", s)
  }
  if self.identity is Some(i) {
    f.set_str("identity", i)
  }
  f.json()
}

///|
pub fn sandbox_name_ok(s : String) -> Bool {
  let ok = (c : Int) => is_alnum(c) || c == '.'.to_int() || c == '_'.to_int() || c == '-'.to_int()
  s.length() >= 1 && s.length() <= 63 && is_alnum(s.unsafe_charcode_at(0)) && all_units(sub(s, 1), ok)
}

///|
/// Parses a cross-station sandbox target `sandbox:<hostId>:<name>`; None for local `sandbox:<name>` or non-sandbox ids.
pub fn parse_remote_sandbox(station : String) -> (String, String)? {
  if !station.has_prefix(sandbox_prefix) {
    return None
  }
  let rest = sub(station, sandbox_prefix.length())
  let colon = index_of(rest, ":")
  if colon <= 0 || colon == rest.length() - 1 {
    return None
  }
  let host_id = sub(rest, 0, to=colon)
  let name = sub(rest, colon + 1)
  if index_of(name, ":") >= 0 || !sandbox_name_ok(name) {
    return None
  }
  Some((host_id, name))
}

///|
/// `/^[^\s@]*\{name\}[^\s@]*@[^\s@]+$/`.
fn front_door_ok(s : String) -> Bool {
  let at = index_of(s, "@")
  if at < 0 || has_space(s) || index_of(s, "@", from=at + 1) >= 0 {
    return false
  }
  sub(s, at + 1) != "" && sub(s, 0, to=at).contains("{name}")
}

///|
/// `/^[a-z][a-z0-9-]{0,30}$/`.
fn size_ok(s : String) -> Bool {
  s.length() >= 1 &&
  s.length() <= 31 &&
  is_lower(s.unsafe_charcode_at(0)) &&
  all_units(sub(s, 1), c => is_lower(c) || is_digit(c) || c == '-'.to_int())
}

///|
/// `sandboxRefusal`: why `s` is no sandbox, or none.
fn sandbox_refusal(s : J) -> String? {
  guard s is Obj(_) else { return Some("each is {name, target, size?, identity?} or {name, kind: \"colab\", gpu}") }
  let x = Some(s)
  let name = str_of(get(x, "name"))
  guard name is Some(n) && sandbox_name_ok(n) else { return Some("a name of letters, digits, ., _ and -") }
  match str_of(get(x, "kind")) {
    Some("colab") =>
      return match str_of(get(x, "gpu")) {
        Some(g) if colab_gpus.contains(g) => None
        _ => Some("\{n}'s gpu is one of Colab's: T4, L4, G4, A100, H100")
      }
    Some("l4es") | None => ()
    Some(_) => return Some("\{n}'s kind is \"colab\", \"l4es\", or none")
  }
  match str_of(get(x, "target")) {
    Some(target) if front_door_ok(target) => ()
    _ => return Some("\{n}'s target is its front door, like {name}.WORKSPACE@HOST")
  }
  match get(x, "size") {
    None => ()
    Some(Str(size)) if size_ok(t(size)) => ()
    Some(_) => return Some("\{n}'s size is the name of one of its operator's sizes")
  }
  match get(x, "identity") {
    None => ()
    Some(Str(id)) if t(id).has_prefix("/") => ()
    Some(_) => return Some("\{n}'s identity is a key's absolute path")
  }
  None
}

///|
/// `sandboxesOf`: config.json's `sandboxes` as the station takes them, those not well formed left out.
pub fn sandboxes_of(raw : J?) -> Array[Sandbox] {
  arr(get(raw, "sandboxes"))
  .filter(s => sandbox_refusal(s) is None)
  .map(s => {
    let x = Some(s)
    let name = str_of(get(x, "name")).unwrap()
    match str_of(get(x, "kind")) {
      Some("colab") =>
        { name, kind: "colab", target: "", size: None, identity: None, gpu: str_of(get(x, "gpu")) }
      other =>
        {
          name,
          kind: other.unwrap_or(""),
          target: str_of(get(x, "target")).unwrap(),
          size: str_of(get(x, "size")),
          identity: str_of(get(x, "identity")),
          gpu: None,
        }
    }
  })
}

///|
/// `effectiveSandboxes`: config.json's `sandboxes`, plus `default_colab_sandboxes()` when `colab_account_count > 0`
/// and config.json has no explicit `kind: "colab"` entry (skipping names taken by l4es, case-insensitively).
pub fn effective_sandboxes(raw : J?, colab_account_count : Int) -> Array[Sandbox] {
  let configured = sandboxes_of(raw)
  if colab_account_count <= 0 || configured.iter().any(is_colab) {
    return configured
  }
  let taken = configured.map(s => lower(s.name))
  let out = configured.copy()
  for d in default_colab_sandboxes() {
    if !taken.contains(lower(d.name)) {
      out.push(d)
    }
  }
  out
}

///|
/// `checkSandboxes`: what is wrong with config.json's `sandboxes` (none: nothing).
pub fn check_sandboxes(raw : J?) -> String? {
  let list = get(raw, "sandboxes")
  match list {
    None | Some(Null) => None
    Some(Arr(items)) => {
      let names : Array[String] = []
      for s in items {
        if sandbox_refusal(s) is Some(why) {
          return Some("sandboxes: \{why}")
        }
        let name = str_of(get(Some(s), "name")).unwrap()
        let key = lower(name)
        if names.contains(key) {
          return Some("sandboxes: \{name} is named twice")
        }
        names.push(key)
      }
      None
    }
    Some(_) => Some("sandboxes must be a list")
  }
}

///|
/// `sandboxDescribed`: what station_list says of a sandbox.
pub fn sandbox_described(d : Sandbox, accounts? : Int = 0, host? : String? = None) -> J {
  if is_colab(d) {
    let gpu = d.gpu.unwrap_or("T4")
    let where_ = match host {
      Some(h) if h != "" => "station \{h}'s"
      _ => "this station's"
    }
    let plural = if accounts == 1 { "" } else { "s" }
    let f = Fields::of([
      ("kind", js("sandbox")),
      ("sandboxKind", js("colab")),
      ("gpu", js(gpu)),
      ("accounts", int(accounts)),
    ])
    if host is Some(h) && h != "" {
      f.set_str("host", h)
    }
    f.spread([
      ("tasks", Bool(true)),
      ("files", Bool(true)),
      ("sync", int(1)),
      ("sessions", Bool(false)),
      ("messages", Bool(false)),
      ("reads", Bool(false)),
      ("chats", Bool(false)),
      (
        "note",
        js(
          "A Google Colab VM with a \{gpu} GPU (Linux, root, x86-64), from \{where_} Google Colab profile pool (\{accounts} account\{plural}): started for this chat's first task (about 10 s; tasks wait in turn while every account holds its 3 of this GPU), kept 3 minutes after a task for the next, then stopped. Run GPU work there with station_task (dir to sync, back to bring results here); no screen. Manage Colab accounts in Settings → Profiles → Add Account → Google → Google Colab.",
        ),
      ),
    ])
    return f.json()
  }
  let f = Fields::of([("kind", js("sandbox")), ("target", js(d.target))])
  if d.size is Some(s) {
    f.set_str("size", s)
  }
  f.spread([
    ("tasks", Bool(true)),
    ("files", Bool(true)),
    ("sync", int(1)),
    ("sessions", Bool(false)),
    ("messages", Bool(false)),
    ("reads", Bool(false)),
    ("chats", Bool(false)),
    (
      "note",
      js(
        "A sandbox: a Linux sandbox of this chat's, made for its first task and deleted once idle. Run builds and tests there with station_task (dir to sync, back to bring results here); no screen. The first time, its front door may ask for this station's key to be linked: the task's log gives the link a person opens.",
      ),
    ),
  ])
  f.json()
}

///|
/// `identityOf`: the station's own ssh key for its sandboxes.
pub fn identity_of(data : String) -> String {
  join([data, "run", "sandbox", "id_ed25519"])
}

///|
fn known_hosts_of(data : String) -> String {
  join([data, "run", "sandbox", "known_hosts"])
}

///|
/// `ensureIdentity`: the station's key made where it has none (`ssh-keygen`).
pub async fn ensure_identity(host : @host.Host, data : String) -> Unit raise {
  let file = identity_of(data)
  if exists(host, file) {
    return
  }
  make_dir(host, join([data, "run", "sandbox"]))
  match run_program(host, "ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "stillfail-station", "-f", file], timeout_ms=60000) {
    Some((0, _)) => ()
    _ => raise FsError("ssh-keygen did not make the station's key")
  }
}

///|
/// `sshTo`: ssh's command line to `destination` with `identity` (none: the station's key).
pub fn ssh_to(data : String, destination : String, identity? : String? = None) -> Array[String] {
  [
    "ssh", "-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "StrictHostKeyChecking=accept-new",
    "-i", identity.unwrap_or(identity_of(data)), "-o", "IdentitiesOnly=yes", "-o", "UserKnownHostsFile=\{known_hosts_of(data)}", destination,
  ]
}

///|
/// `sandboxName` (the session backfill's, station/mb src/activity).
pub fn sandbox_name(key : String) -> String {
  @activity.sandbox_name(key)
}

///|
/// `keyPart`.
pub fn key_part(key : String) -> String {
  @activity.key_part(key)
}

///|
/// `sandboxOf`: the sandbox of chat `session` at `d`, by its name at the front door.
pub fn sandbox_of(d : Sandbox, session : String) -> String {
  sandbox_name("\{d.name}|\{session}")
}

///|
/// `SandboxPlace`: where a job runs in a sandbox.
pub(all) struct SandboxPlace {
  sandbox : String
  session : String
  back : Array[String]
  workspace : String?
}

///|
/// `sandboxCommand`: what the shell runs in place of a job's command in a sandbox. `bridge` the bridge's file
/// (`BRIDGE`), `node` the Node (or reader) it runs on.
pub fn sandbox_command(
  data : String,
  d : Sandbox,
  place : SandboxPlace,
  command : String,
  cwd : String,
  ports : Array[Double],
  lost_file : String,
  node : String,
  bridge : String,
  colab_script? : String = "",
  accounts? : Array[(String, String)] = [],
) -> String {
  if is_colab(d) {
    let spec = Fields::of([
      ("pool", js(colab_pool(data))),
      ("data", js(data)),
      ("gpu", js(d.gpu.unwrap_or("T4"))),
      ("chat", js(place.session)),
      ("command", js(command)),
      ("cwd", js(cwd)),
      ("ports", Arr(ports.map(Num(_)))),
      ("lostFile", js(lost_file)),
      ("back", arr_of(place.back)),
      ("bridge", js(bridge)),
      ("accounts", Arr(accounts.map(a => obj([("id", js(a.0)), ("authFile", js(a.1))])))),
    ])
    return [node, colab_script, "run", stringify(spec.json())].map(sh_quoted).join(" ")
  }
  let name = sandbox_of(d, place.session)
  let base = Fields::new()
  base.set("ssh", arr_of(ssh_to(data, replace_first(d.target, "{name}", name), identity=d.identity)))
  if d.size is Some(size) {
    let create = ssh_to(data, replace_first(d.target, "{name}", "_"), identity=d.identity)
    create.push_iter(["create", name, "--size", size].iter())
    base.set("create", arr_of(create))
  }
  base.set("root", obj([("path", js(data))]))
  base.set("dirs", arr_of([cwd]))
  let run = Fields::of(base.entries())
  run.set("ports", Arr(ports.map(Num(_))))
  run.set("sync", Arr([obj([("path", js(cwd)), ("mode", js("whole")), ("back", Bool(false)), ("dir", Bool(true))])]))
  run.set_str("program", "/bin/sh")
  run.set("args", arr_of(["-c", command]))
  run.set_str("cwd", cwd)
  run.set_str("lostFile", lost_file)
  let back = Fields::of(base.entries())
  back.set(
    "sync",
    Arr(
      place.back.map(b => obj([("path", js(join([cwd, b]))), ("mode", js("whole")), ("push", Bool(false)), ("dir", Bool(false))])),
    ),
  )
  let bridged = (spec : Fields) => [node, bridge, "host", stringify(spec.json())].map(sh_quoted).join(" ")
  if place.back.is_empty() {
    bridged(run)
  } else {
    "\{bridged(run)}; code=$?; \{bridged(back)}; exit $code"
  }
}
