// What this station shares with the other stations of its workspaces, and what it uses of theirs (station/src/share/
// index.ts `Sharing`, line for line). It is between the stations only (the station transport, `share.*`); still.fail
// cloud says nothing of it beyond which stations are in each workspace. index.ts's head says the whole of it: who a
// share is for, what its host keeps (state.json `hosted`), what a station that uses one keeps (`borrowed`), a key
// profile and a skill copied, a subscription's login lent for each process, a skill's edits sent to its host (one on an
// older copy kept beside it as SKILL.conflict-<station>.md), a profile moved to another station (`moveProfile`,
// `lendTo`, `shareFirst`, `unshareMoved`). Its state.json and the config it writes are the TypeScript's, byte for byte.

///|
/// What a skill may hold to be shared (sent whole in one request of the station transport, which takes 1 MB).
let max_skill_bytes : Double = 524288.0

///|
let max_skill_files : Int = 200

///|
/// A host lends a Codex token it has for at least this long; one closer to its end is renewed first (when it can be).
let codex_lend_ms : Double = 86400000.0

///|
let codex_min_ms : Double = 3600000.0

///|
/// An Antigravity CLI sign-in lent lasts at least this long, one closer to its end renewed first; one with less than
/// AGY_MIN_MS waits for its renewal (index.ts says why).
let agy_lend_ms : Double = 3000000.0

///|
let agy_min_ms : Double = 2520000.0

///|
/// A login lent before is used again while its host does not answer, if it still has this long.
let keep_lent_ms : Double = 3600000.0

///|
/// A borrower goes on with the Antigravity CLI sign-in lent before while its host is away, if it lasts this long still.
let keep_agy_ms : Double = 600000.0

///|
/// How long a login wanted waits for the cloud to say the workspace's stations.
let roster_wait_ms : Double = 10000.0

///|
/// Edits to a skill are taken once they have settled this long.
let settle_ms : Double = 2000.0

///|
/// The most directories of a skill shared from here watched.
let skill_dirs_most : Int = 200

///|
/// What could not be done because another station did not answer is tried again after this, then twice as long each
/// time up to RETRY_MAX_MS.
let retry_ms : Double = 60000.0

///|
let retry_max_ms : Double = 1800000.0

///|
/// How long a lend waits for a renewal going on (accounts/oauth.ts `LEND_BOUND_MS`).
let lend_bound_ms : Double = 10000.0

///|
let codex_client_id : String = "app_EMoamEEZ73f0CkXaXp7hrann"

///|
pub let codex_token_url : String = "https://auth.openai.com/oauth/token"

///|
let too_large : String = "the skill is too large to share (512 KB, 200 files at most)"

///|
/// What is never part of a skill as shared: what a program makes beside its files (memory.ts `SKIPPED`).
pub let skipped : Array[String] = ["__pycache__", "node_modules", ".venv", ".git", ".DS_Store"]

///|
/// A directory's watch (ops/follow.ts `FollowedTree`, or a file's directory as `fs.watch` follows it): looked at again
/// (`scan`: why it could not be followed, None when it is), and let go.
pub(all) struct Watcher {
  close : () -> Unit
  scan : async () -> String?
}

///|
/// How the station follows directories (the machine's own): a tree from `root` (each directory `into` says, `most` at
/// most; `changed` told what changed, `failed` a watch the system took back), and one directory for one file's name in
/// it (`changed` told the name that changed, None: something did; None given back where it cannot be watched now).
pub(all) struct Watching {
  tree : (String, (String) -> Bool, Int, (String) -> Unit, (String) -> Unit) -> Watcher
  dir : (String, (String?) -> Unit, () -> Unit) -> Watcher?
}

///|
/// Nothing followed (a station that watches nothing, a test's).
pub fn Watching::none() -> Watching {
  {
    tree: (_, _, _, _, _) => { close: () => (), scan: async fn() { None } },
    dir: (_, _, _) => None,
  }
}

///|
/// What the sharing is given (index.ts `SharingDeps`).
pub(all) struct SharingDeps {
  data : String
  config : Config
  cloud : Cloud
  /// A request to another station of one of the station's workspaces, in `workspace` (None: the first both are in).
  ask : async (String, String?, Json) -> Json
  /// The agents' home (its skills/ directory is where shared skills are linked).
  agent_home : () -> String
  /// Where the machine's own Codex login is (machine-logins.ts `codexAuthFile(env)`).
  codex_auth_file : () -> String
  /// The account of a profile on the machine's login, as read by Accounts.
  machine_email : ((String) -> String?)?
  /// A Claude profile's current access token, renewed when about to run out: its token and when it runs out.
  claude_token : async (Json, String?) -> (String, Double)
  /// Has the Codex app-server running on a profile here renew its login; false: none runs on it.
  codex_renew_running : async (String) -> Bool
  /// Has `agy` renew an Antigravity CLI profile's sign-in here.
  agy_renew : (async (String) -> Unit)?
  /// A profile's check and allowance as this station has them (`{check, quota}`).
  status : async (String) -> Json
  /// Something the overview shows changed.
  changed : () -> Unit
  /// A host that had not answered answers again.
  recheck : (() -> Unit)?
  /// A copied profile changed on its host.
  profile_changed : (async (String, Bool) -> Unit)?
  /// A borrower redeemed a reset.
  quota_reset : (async (String) -> Unit)?
  /// A profile of this station's moved to another and gone from here.
  profile_gone : (async (String) -> Unit)?
  /// Whether a request naming `station` comes back to this station (a station retired into this one).
  itself : ((String) -> Bool)?
  /// Codex's token endpoint.
  codex_token_url : String
  /// An HTTP request (the agents' proxy's, ops/agent-env.ts `profileFetch`): url, JSON body → status and body.
  fetch : async (String, String) -> (Int, String)
  /// The account a grok or cursor home is signed in to (accounts/index.ts `accountEmailSoon`).
  account_email : async (String, String) -> String?
  /// The station's language (ops/i18n.ts `stationLang`).
  lang : () -> String
  /// `n` random bytes, hex.
  random_hex : async (Int) -> String
  watching : Watching
  clock : Clock
  log : Log
  files : Files
}

// ── profiles and what of them goes to another station ──

///|
fn keyed(kind : Json?) -> Bool {
  kind is Some(String("opencode-go" | "anthropic-api" | "api-provider"))
}

///|
/// Kimi Code signed in (agents/profiles.ts `kimiSignedIn`).
fn kimi_signed_in(p : Json) -> Bool {
  let access = match get(Some(p), "access") {
    Some(Object(_) as a) | Some(Array(_) as a) => Some(a)
    _ => None
  }
  let kind = match get(access, "kind") {
    None | Some(Null) => Some(jstr("env"))
    k => k
  }
  kind is Some(String("api-provider")) && get(access, "provider") is Some(String("kimi-code")) && true_at(access, "login")
}

///|
/// The files a profile's login is in, under its home, by its runtime and how it signs in (index.ts `signInFiles`).
pub fn sign_in_files(p : Json, sep : String) -> Array[String] {
  let j = (parts : Array[String]) => @nodepath.join(sep, parts)
  let access = get(Some(p), "access")
  let kind = if access is Some(Object(_)) { get(access, "kind") } else { None }
  let out = []
  if kind is Some(String("service")) {
    return out
  }
  if kind is Some(String("subscription")) {
    let r = match get(Some(p), "runtime") {
      None | Some(Null) => ""
      v => js_string(v)
    }
    match r {
      "claude" => {
        out.push(".credentials.json")
        out.push(".claude.json")
      }
      "codex" => out.push("auth.json")
      "grok" => out.push(j(["", "grok", "auth.json"]))
      "cursor" => out.push(j([j(["", "cursor"]), "auth.json"]))
      "devin" => {
        out.push(j([j([j(["", "devin"]), "data"]), "devin", "credentials.toml"]))
        out.push(j(["", "devin", "account.json"]))
      }
      "agy" => {
        out.push(j([j([j(["", "agy"]), ".gemini"]), "antigravity-cli", "antigravity-oauth-token"]))
        out.push(j([j(["", "agy"]), "account.json"]))
      }
      _ => ()
    }
  }
  if kind is Some(String("opencode-go")) && true_at(access, "login") {
    out.push("opencode-console.json")
  }
  if kimi_signed_in(p) {
    out.push("kimi-code.json")
    out.push("kimi-code.token")
  }
  out
}

///|
/// A profile as another station gets it: what it is, its key when it has one, never where its files are or a login.
pub fn portable(p : Json) -> Json {
  let out : Map[String, Json] = Map([])
  for k in ["name", "runtime", "access", "env", "model", "models", "backgroundOnMessage", "fast", "enabled"] {
    if get(Some(p), k) is Some(v) {
      out[k] = clone(v)
    }
  }
  if out.get("access") is Some(Object(a)) && !keyed(a.get("kind")) {
    a.remove("key")
  }
  // A proxy is this machine's, not the profile's: the other station has its own way out, or none.
  if out.get("env") is Some(Object(e)) {
    for k in e.keys().collect() {
      if machine_proxy(k) {
        e.remove(k)
      }
    }
  }
  Json::object(out)
}

///|
/// `/^(https?|all|no)_proxy$/i.test(name)` (profiles.ts `machineProxy`).
fn machine_proxy(name : String) -> Bool {
  let folded = StringBuilder::new()
  for c in name {
    folded.write_char(if c >= 'A' && c <= 'Z' { (c.to_int() + 32).unsafe_to_char() } else { c })
  }
  ["http_proxy", "https_proxy", "all_proxy", "no_proxy"].contains(folded.to_string())
}

///|
/// Why profile `p`'s login cannot be shared with other stations (None: it can).
pub fn share_refusal(p : Json) -> String? {
  let pj = Some(p)
  if is_obj(get(pj, "share")) && true_at(get(pj, "share"), "borrowed") {
    return Some("this profile is another station's")
  }
  if gets(pj, ["access", "kind"]) is Some(String("service")) {
    return Some("a service profile cannot be shared with other stations yet")
  }
  let sub = gets(pj, ["access", "kind"]) is Some(String("subscription"))
  let runtime = get(pj, "runtime")
  if sub && runtime is Some(String("grok")) {
    return Some("a SuperGrok subscription cannot be shared with other stations yet")
  }
  if sub && runtime is Some(String("cursor")) {
    return Some("a Cursor account cannot be shared with other stations yet")
  }
  if sub && runtime is Some(String("devin")) {
    return Some("a Devin account cannot be shared with other stations yet")
  }
  if gets(pj, ["access", "provider"]) is Some(String("kimi-code")) && gets(pj, ["access", "login"]) is Some(True) {
    return Some("a Kimi Code sign-in cannot be shared with other stations yet")
  }
  None
}

///|
/// Whether a profile serves workspace `ws` (sessions/config.ts `allowedIn`).
pub fn allowed_in(profile : Json, ws : String?, home : String?) -> Bool {
  let share = get(Some(profile), "share")
  let only = if true_at(share, "borrowed") { arr_at(share, "workspaces") } else { None }
  let at = match ws {
    Some(_) => ws
    None => home
  }
  if only is Some(o) && at is Some(a) && !o.contains(jstr(a)) {
    return false
  }
  match (ws, home) {
    (None, _) | (_, None) => true
    (Some(w), Some(h)) =>
      w == h ||
      (match get(Some(profile), "withheld") {
        Some(Array(list)) => !list.contains(jstr(w))
        _ => true
      })
  }
}

///|
/// Path::join as Rust has it (platform `paths.join`): an absolute `given` replaces `base`; nothing normalised.
fn join_path(sep : String, base : String, given : String) -> String {
  let absolute = if sep == "\\" {
    @nodepath.is_absolute(sep, given)
  } else {
    given.has_prefix("/")
  }
  if absolute || base == "" {
    given
  } else if base.has_suffix(sep) || (sep == "\\" && base.has_suffix("/")) {
    base + given
  } else {
    base + sep + given
  }
}

///|
/// Whether `ws` can name a workspace's directory (`/^[0-9A-Za-z_-]{1,128}$/`).
fn is_ws_id(ws : String) -> Bool {
  ws.length() >= 1 &&
  ws.length() <= 128 &&
  ws.iter().all(c => (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '-')
}

///|
/// Where the agent home of workspace `ws` is (sessions/agent-home.ts `workspaceAgentHomePath`).
pub fn workspace_agent_home_path(sep : String, agent_home : String, ws : String?, home : String?) -> String raise {
  match (ws, home) {
    (Some(w), Some(h)) if w != h => {
      if !is_ws_id(w) {
        raise Failed("not a workspace id: \{js_stringify(jstr(w))}")
      }
      @nodepath.join(sep, [agent_home, "workspaces", w])
    }
    _ => agent_home
  }
}

///|
/// A share id as the stations make them (`/^sh-[0-9a-z]{10,40}$/`).
fn share_id_ok(id : String) -> Bool {
  guard id.has_prefix("sh-") else { return false }
  let rest = id.view(start_offset=3)
  rest.length() >= 10 && rest.length() <= 40 && rest.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z'))
}

///|
/// A profile's id handed over (`/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/`).
fn profile_id_ok(id : String) -> Bool {
  let alnum = (c : Char) => (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
  id.length() >= 1 &&
  id.length() <= 64 &&
  alnum(id.unsafe_get(0).unsafe_to_char()) &&
  id.iter().all(c => alnum(c) || c == '.' || c == '_' || c == '-')
}

///|
/// Keeps why a station that may use a share does not (None: it does, or may not): `hosted.missing`.
fn miss(hosted : Map[String, Json], peer : String, why : String?) -> Unit {
  match why {
    Some(w) => {
      let m = match hosted.get("missing") {
        Some(Object(m)) => m
        _ => {
          let m : Map[String, Json] = Map([])
          hosted["missing"] = Json::object(m)
          m
        }
      }
      m[peer] = jstr(w)
    }
    None =>
      if hosted.get("missing") is Some(Object(m)) {
        m.remove(peer)
        if m.is_empty() {
          hosted.remove("missing")
        }
      } else if hosted.get("missing") is Some(_) {
        // (`delete hosted.missing[peer]` of what is not an object: nothing; `Object.keys` of it has none)
        hosted.remove("missing")
      }
  }
}

///|
/// What is at a path itself (a link not followed).
priv enum Entry {
  Nothing
  Other
  Link(String)
}

///|
async fn entry_at(files : Files, path : String) -> Entry {
  guard files.lstat(path) is Some(st) else { return Nothing }
  if st.kind != "link" {
    return Other
  }
  match files.readlink(path) {
    Some(l) => Link(l)
    None => Nothing
  }
}

///|
/// What the memory's program says of a skill's files: its hash, whether it has its SKILL.md, and (asked) its files.
priv struct SkillRead {
  hash : String
  has_skill_md : Bool
  files : Json?
}

///|
/// A share of this station's as configured (`Shared`), with its content's hash where it was read (`Own`).
priv struct Own {
  kind : String
  name : String
  allow : Json
  profile : Json?
  skill : String?
  mut hash : String?
  mut unread : String?
}

///|
pub struct Sharing {
  deps : SharingDeps
  priv tasks : Tasks
  priv files : Files
  priv watchers : Map[String, Watcher]
  priv login_dirs : Map[String, String]
  priv settle : Map[String, () -> Unit]
  priv mut retry : (() -> Unit)?
  priv mut retry_wait : Double
  priv stops : Array[() -> Unit]
  priv silent_hosts : Map[String, Double]
  priv moving : Set[String]
  priv unannounced : Set[String]
  priv move_done : Map[String, @effect.Deferred[Unit]]
  priv lent_claude : Map[String, (String, Double)]
  priv mut reconciling : @effect.Deferred[Unit]?
  priv mut again : Bool
  priv checked : Set[String]
  priv program : MemoryProgram
  priv hosted_turn : Turn
  priv link_turn : Turn
  priv renewing : Map[String, @effect.Deferred[Unit]]
  priv mut closed : Bool
  /// The one copy of state.json in memory (index.ts `state`).
  priv mut state : Map[String, Json]?
  priv mut state_file : PrivateFile?
  /// Told as a shared profile is handed over to this station to host (share `id`, from `peer`).
  priv mut on_hosted : ((String, String) -> Unit)?
}

///|
pub fn Sharing::new(deps : SharingDeps, rt : @effect.Runtime) -> Sharing {
  let s : Sharing = {
    deps,
    tasks: Tasks::new(rt, deps.log, "share"),
    files: deps.files,
    watchers: Map([]),
    login_dirs: Map([]),
    settle: Map([]),
    retry: None,
    retry_wait: retry_ms,
    stops: [],
    silent_hosts: Map([]),
    moving: Set::new(),
    unannounced: Set::new(),
    move_done: Map([]),
    lent_claude: Map([]),
    reconciling: None,
    again: false,
    checked: Set::new(),
    program: MemoryProgram::new(deps.files.host, deps.files.sep),
    hosted_turn: Turn::new(),
    link_turn: Turn::new(),
    renewing: Map([]),
    closed: false,
    state: None,
    state_file: None,
    on_hosted: None,
  }
  s
}

///|
/// What is still going of what it set going (tests: settled once none is).
pub fn Sharing::busy(self : Sharing) -> Int {
  self.tasks.busy
}

///|
/// The skills' program let go at once if nothing is asked of it: 1, else 0.
pub fn Sharing::trim_idle(self : Sharing) -> Int {
  self.program.trim_idle()
}

///|
fn Sharing::root(self : Sharing) -> String {
  self.files.join([self.deps.data, "share"])
}

///|
fn Sharing::me(self : Sharing) -> String? {
  (self.deps.cloud.station)()
}

///|
fn Sharing::home_ws(self : Sharing) -> String? {
  (self.deps.cloud.home)()
}

///|
/// A skill's files as the program reads them; TooLarge past what may be shared.
async fn Sharing::read_skill(self : Sharing, dir : String, bytes? : Bool = false) -> SkillRead {
  let r = self.program.ask("skillRead", [
    ("dir", jstr(dir)),
    ("maxBytes", jnum(max_skill_bytes)),
    ("maxFiles", jnum(max_skill_files.to_double())),
    ("bytes", jbool(bytes)),
  ])
  if get(Some(r), "tooLarge") is Some(True) {
    raise TooLarge(too_large)
  }
  { hash: js_string(get(Some(r), "hash")), has_skill_md: get(Some(r), "hasSkillMd") is Some(True), files: if bytes { get(Some(r), "files") } else { None } }
}

///|
/// The other stations of the station's workspaces, as the cloud said last, each with the workspaces it is in too, the
/// home one first (None: not known now).
fn Sharing::rosters(self : Sharing) -> Map[String, Array[String]]? {
  let cloud = self.deps.cloud
  if !(cloud.peers_current)() || !(cloud.has_state)() {
    return None
  }
  let me = self.me()
  let out : Map[String, Array[String]] = Map([])
  for m in (cloud.memberships)() {
    for p in m.peers {
      if get(Some(p), "id") is Some(String(id)) && Some(id) != me {
        match out.get(id) {
          Some(a) => a.push(m.workspace)
          None => out[id] = [m.workspace]
        }
      }
    }
  }
  Some(out)
}

///|
/// Whether a share is for the stations of workspace `ws`: a profile for those of each workspace it serves, a skill for
/// the home one's.
fn Sharing::serves_in(self : Sharing, kind : String, profile : Json?, ws : String) -> Bool {
  let home = self.home_ws()
  if kind == "profile" {
    allowed_in(profile.unwrap_or(Json::null()), Some(ws), home)
  } else {
    Some(ws) == home
  }
}

///|
/// The workspaces of this station's a profile is shared in.
fn Sharing::shared_in(self : Sharing, profile : Json) -> Array[String] {
  (self.deps.cloud.memberships)().filter_map(m => if self.serves_in("profile", Some(profile), m.workspace) {
    Some(m.workspace)
  } else {
    None
  })
}

///|
fn Sharing::codex_file(self : Sharing, p : Json) -> String {
  if get(Some(p), "machine") is Some(True) {
    (self.deps.codex_auth_file)()
  } else {
    self.files.join([self.home(p), "auth.json"])
  }
}

///|
/// What a shared profile is, hashed: where it is shared too.
async fn Sharing::profile_hash(self : Sharing, p : Json) -> String {
  let pj = Some(p)
  let mut login : String? = None
  if get(pj, "runtime") is Some(String("codex")) && gets(pj, ["access", "kind"]) is Some(String("subscription")) {
    match self.files.read_text(self.codex_file(p)) {
      Some(t) => login = Some(hash_of(jstr(t)))
      None => ()
    }
  }
  let out = match portable(p) {
    Object(m) => m
    _ => Map([])
  }
  out["workspaces"] = jstrs(self.shared_in(p))
  if get(pj, "machine") is Some(True) && gets(pj, ["access", "kind"]) is Some(String("subscription")) {
    out["email"] = match self.email_of(p) {
      Some(e) => jstr(e)
      None => jnull()
    }
  }
  if login is Some(l) {
    out["login"] = jstr(l)
  }
  hash_of(Json::object(out))
}

///|
/// The workspace a share reaches `station` in: the first both are in that it is for; None when there is none.
fn Sharing::reach(
  self : Sharing,
  kind : String,
  profile : Json?,
  station : String,
  rosters : Map[String, Array[String]]?,
) -> String? {
  match rosters {
    Some(r) =>
      match r.get(station) {
        Some(wss) => {
          for ws in wss {
            if self.serves_in(kind, profile, ws) {
              return Some(ws)
            }
          }
          None
        }
        None => None
      }
    None => None
  }
}

///|
/// Where a copy's host is asked: a skill's in the workspace it was had in; a profile's in any both are in.
fn Sharing::ask_in(self : Sharing, had : Map[String, Json]) -> String? {
  if had.get("kind") is Some(String("skill")) {
    match had.get("workspace") {
      None | Some(Null) => self.home_ws()
      Some(String(w)) => Some(w)
      Some(other) => Some(js_string(Some(other)))
    }
  } else {
    None
  }
}

///|
fn Sharing::host_there(self : Sharing, had : Map[String, Json], rosters : Map[String, Array[String]]) -> Bool {
  let where_ = self.ask_in(had)
  match rosters.get(js_string(had.get("host"))) {
    Some(of) =>
      match where_ {
        None => true
        Some(w) => of.contains(w)
      }
    None => false
  }
}

///|
fn may_use(allow : Json, station : String) -> Bool {
  match allow {
    Array(a) => a.contains(jstr(station))
    _ => true
  }
}

///|
/// What a host answers a station a share's `allow` leaves out (index.ts NOT_FOR_IT), one in none of the workspaces it
/// is shared in as the cloud's list has it (NOT_THERE), any while that list is not known (STATIONS_UNKNOWN), and one
/// asking of a share it does not have (NOT_SHARED: no longer shared, or moved and forgotten).
let not_for_it : String = "that share is not for this station"

///|
let not_there : String = "that share is not for this station's workspaces"

///|
let stations_unknown : String = "this station does not know its workspaces' stations yet"

///|
let not_shared : String = "this station does not share that"

///|
/// Whether a host answered that its `allow` leaves this station out (index.ts `notOurs`): the copy it has is not its to
/// keep, as the `gone` its host tells (share.changed) would have said had it got here. Only that, the host's own word:
/// what the cloud's list says (NOT_THERE, STATIONS_UNKNOWN) it can hold back or lose a station of a while, and a host
/// that forgot a move answers NOT_SHARED till the new one says it.
fn not_ours(e : Error) -> Bool {
  error_words(e) == not_for_it
}

///|
/// Whether two of a share's `allow` let the same stations use it (anything but an array: every one), in whatever order
/// (index.ts `sameStations`).
fn same_stations(a : Json?, b : Json?) -> Bool {
  match (a, b) {
    (Some(Array(x)), Some(Array(y))) => {
      let names = (xs : Array[Json]) => xs.map(v => js_string(Some(v)))
      let mine : Set[String] = Set::from_array(names(x))
      let both : Set[String] = Set::from_array(names(x) + names(y))
      x.length() == y.length() && both.length() == mine.length()
    }
    (Some(Array(_)), _) | (_, Some(Array(_))) => false
    _ => true
  }
}

///|
/// Why a host refuses `peer` a share it has (index.ts `handle`), each said apart: its `allow` leaving it out (its own
/// word, a copy taken away on it), the cloud's list not known, or leaving it out (a copy kept on those).
fn refusal_of(
  allow : Json,
  peer : String,
  rosters : Map[String, Array[String]]?,
  reach : (Map[String, Array[String]]) -> String?,
) -> String? {
  if !may_use(allow, peer) {
    return Some(not_for_it)
  }
  guard rosters is Some(r) else { return Some(stations_unknown) }
  if reach(r) is None {
    return Some(not_there)
  }
  None
}

///|
/// The stations to be told a share is no longer for them (`told` -1) as who may use it changes from `before` to `now`
/// (index.ts `syncHosted`): every one of the workspaces' its `allow` leaves out, not only those down as told of it (one
/// the cloud's list left out a while is forgotten as told, and would keep its copy, told nothing till it asked again).
fn left_out(
  told : Map[String, Json],
  before : Json?,
  now : Json,
  rosters : Map[String, Array[String]],
  itself : (String) -> Bool,
) -> Array[String] {
  if same_stations(before, Some(now)) {
    return []
  }
  rosters.keys().filter(peer => !told.contains(peer) && !may_use(now, peer) && !itself(peer)).collect()
}

///|
fn allow_of(v : Json?) -> Json {
  match v {
    Some(Array(_) as a) => a
    _ => jnull()
  }
}

// ── state ──

///|
/// The one copy of state.json in memory, read as the station starts (it is the same one every change is made to).
pub async fn Sharing::load(self : Sharing) -> Unit {
  ignore(self.read_state_from_disk())
}

///|
async fn Sharing::read_state_from_disk(self : Sharing) -> Map[String, Json] {
  if self.state is Some(s) {
    return s
  }
  let path = self.files.join([self.root(), "state.json"])
  let parsed : Json? = match self.files.read_text(path) {
    Some(t) => try Some(js_parse(t)) catch { _ => None }
    None => None
  }
  let st : Map[String, Json] = Map([])
  match parsed {
    Some(s) if s is Object(_) || s is Array(_) || s is Null => {
      // (`{hosted, borrowed, moved, taken}` of what it holds, each `{}` where it is no object)
      let field = (k : String) => match get(Some(s), k) {
        Some(Object(_) as o) => o
        _ => Json::object(Map([]))
      }
      guard s is Object(_) else {
        st["hosted"] = Json::object(Map([]))
        st["borrowed"] = Json::object(Map([]))
        st["moved"] = Json::object(Map([]))
        self.state = Some(st)
        return st
      }
      st["hosted"] = field("hosted")
      st["borrowed"] = field("borrowed")
      st["moved"] = field("moved")
      st["taken"] = field("taken")
    }
    Some(_) => {
      st["hosted"] = Json::object(Map([]))
      st["borrowed"] = Json::object(Map([]))
      st["moved"] = Json::object(Map([]))
      st["taken"] = Json::object(Map([]))
    }
    None => {
      st["hosted"] = Json::object(Map([]))
      st["borrowed"] = Json::object(Map([]))
      st["moved"] = Json::object(Map([]))
    }
  }
  self.state = Some(st)
  st
}

///|
fn Sharing::st(self : Sharing) -> Map[String, Json] {
  match self.state {
    Some(s) => s
    None => {
      // (read before it serves: `load`; one made before that starts from nothing)
      let st : Map[String, Json] = Map([])
      st["hosted"] = Json::object(Map([]))
      st["borrowed"] = Json::object(Map([]))
      st["moved"] = Json::object(Map([]))
      self.state = Some(st)
      st
    }
  }
}

///|
fn section(st : Map[String, Json], k : String) -> Map[String, Json] {
  match st.get(k) {
    Some(Object(m)) => m
    _ => {
      let m : Map[String, Json] = Map([])
      st[k] = Json::object(m)
      m
    }
  }
}

///|
fn Sharing::hosted(self : Sharing) -> Map[String, Json] {
  section(self.st(), "hosted")
}

///|
fn Sharing::borrowed(self : Sharing) -> Map[String, Json] {
  section(self.st(), "borrowed")
}

///|
fn Sharing::moved(self : Sharing) -> Map[String, Json] {
  section(self.st(), "moved")
}

///|
fn entry_of(m : Map[String, Json], k : String) -> Map[String, Json]? {
  match m.get(k) {
    Some(Object(o)) => Some(o)
    _ => None
  }
}

///|
/// The state as state.json holds it (tests).
pub fn Sharing::state_json(self : Sharing) -> Json {
  Json::object(self.st())
}

///|
/// Once the state asked to be written is.
pub async fn Sharing::state_written(self : Sharing) -> Unit {
  if self.state_file is Some(f) {
    f.written()
  }
}

///|
fn Sharing::write_state(self : Sharing) -> Unit {
  let file = match self.state_file {
    Some(f) => f
    None => {
      let f = PrivateFile::new(self.files, self.files.join([self.root(), "state.json"]), self.tasks)
      self.state_file = Some(f)
      f
    }
  }
  file.write(js_stringify2(Json::object(self.st())))
}

///|
fn Sharing::profiles(self : Sharing) -> Array[Json] {
  match get(Some((self.deps.config.raw)()), "profiles") {
    Some(Array(a)) => a
    _ => []
  }
}

///|
fn Sharing::home(self : Sharing, p : Json) -> String {
  let home = match get(Some(p), "home") {
    None | Some(Null) => "homes/\{js_string(get(Some(p), "id"))}"
    h => js_string(h)
  }
  join_path(self.files.sep, self.deps.data, home)
}

///|
/// The agents' skills of workspace `ws` (None: the home one's).
fn Sharing::skills_dir(self : Sharing, ws? : String? = None) -> String raise {
  self.files.join([
    workspace_agent_home_path(self.files.sep, (self.deps.agent_home)(), ws, self.home_ws()),
    "skills",
  ])
}

///|
/// The skills this station shares: name → id and who may use it.
fn Sharing::shared_skills(self : Sharing) -> Array[(String, String, Json)] {
  guard get(Some((self.deps.config.raw)()), "sharedSkills") is Some(Object(s)) else { return [] }
  let out : Array[(String, String, Json)] = []
  let seen : Map[String, Int] = Map([])
  for name in js_keys(s) {
    let v = s[name]
    let item = match v {
      String(id) => Some((name, id, jnull()))
      Object(o) =>
        match o.get("id") {
          Some(String(id)) => Some((name, id, allow_of(o.get("allow"))))
          _ => None
        }
      _ => None
    }
    if item is Some(i) {
      match seen.get(name) {
        Some(at) => out[at] = i
        None => {
          seen[name] = out.length()
          out.push(i)
        }
      }
    }
  }
  out
}

///|
fn Sharing::shared_skill(self : Sharing, name : String) -> (String, Json)? {
  for s in self.shared_skills() {
    if s.0 == name {
      return Some((s.1, s.2))
    }
  }
  None
}

///|
/// Shared skills whose directory is gone: shared under the name it was renamed to, or no longer once it is deleted.
async fn Sharing::follow_skills(self : Sharing) -> Unit {
  let skills = self.skills_dir()
  guard self.files.readdir(skills) is Some(names) else { return }
  let shared = self.shared_skills()
  let gone : Array[(String, String)] = []
  for e in shared {
    if !self.files.exists(self.files.join([skills, e.0])) {
      gone.push((e.0, e.1))
    }
  }
  if gone.is_empty() {
    return
  }
  let free : Map[String, String] = Map([])
  for name in names {
    let key = if shared.iter().any(e => e.0 == name) {
      None
    } else {
      self.files.dir_key(self.files.join([skills, name]))
    }
    if key is Some(k) {
      free[k] = name
    }
  }
  let hosted = self.hosted()
  ignore(
    (self.deps.config.update_soon)(raw => {
      guard raw is Object(r) else { return }
      let to = match r.get("sharedSkills") {
        Some(Object(m)) => m
        _ => Map([])
      }
      for g in gone {
        let (name, id) = g
        let key = match entry_of(hosted, id) {
          Some(h) => h.get("dir")
          None => None
        }
        let now = match key {
          Some(String(k)) => free.get(k)
          Some(other) => free.get(js_string(Some(other)))
          None => None
        }
        match now {
          Some(n) if @memory.portable_name(n) => {
            to[n] = to.get(name).unwrap_or(Json::null())
            if to.get(name) is None {
              // (`to[now] = to[name]` of a name not there: undefined, which JSON leaves out)
              to.remove(n)
            }
            self.deps.log.info("share", "a shared skill renamed is shared under its new name", jobj([("id", jstr(id)), ("from", jstr(name)), ("to", jstr(n))]))
          }
          _ =>
            self.deps.log.info("share", "a shared skill deleted is no longer shared", jobj([("id", jstr(id)), ("name", jstr(name))]))
        }
        to.remove(name)
        self.stop_watch("hosted:\{name}")
      }
      r["sharedSkills"] = Json::object(to)
    }),
  )
}

///|
/// What this station shares now, by id, as configured (nothing of it read).
fn Sharing::shares(self : Sharing) -> Map[String, Own] {
  let out : Map[String, Own] = Map([])
  for p in self.profiles() {
    let share = get(Some(p), "share")
    guard share is Some(Object(sh)) && !(sh.get("borrowed") is Some(True)) && sh.get("id") is Some(String(id)) else {
      continue
    }
    let name = match get(Some(p), "name") {
      None | Some(Null) => js_string(get(Some(p), "id"))
      n => js_string(n)
    }
    out[id] = { kind: "profile", name, allow: allow_of(sh.get("allow")), profile: Some(p), skill: None, hash: None, unread: None }
  }
  for s in self.shared_skills() {
    let (name, id, allow) = s
    out[id] = { kind: "skill", name, allow, profile: None, skill: Some(name), hash: None, unread: None }
  }
  out
}

///|
/// What this station shares now, by id, with its content's hash (None: unreadable now), a skill's read by the program.
async fn Sharing::own_shares(self : Sharing) -> Map[String, Own] {
  let out = self.shares()
  for id, share in out {
    if share.kind == "profile" {
      share.hash = Some(self.profile_hash(share.profile.unwrap_or(Json::null())))
      continue
    }
    let skill = share.skill.unwrap_or("")
    try {
      share.hash = Some(self.read_skill(self.files.join([self.skills_dir(), skill])).hash)
    } catch {
      Stopped(_) as e => raise e
      e => {
        share.unread = Some(if e is TooLarge(_) { "too-large" } else { "unreadable" })
        self.deps.log.warn("share", "a shared skill could not be read", jobj([("name", jstr(skill)), ("error", jstr(error_words(e)))]))
      }
    }
    ignore(id)
  }
  out
}

///|
/// Updates `state.hosted` and the watches for what this station shares now, one at a time with what else changes it.
async fn Sharing::sync_hosted(self : Sharing) -> Map[String, Own] {
  self.hosted_turn.run(async fn() { self.sync_hosted_now() })
}

///|
async fn Sharing::sync_hosted_now(self : Sharing) -> Map[String, Own] {
  let own = self.own_shares()
  let hosted_all = self.hosted()
  let mut dirty = false
  for id in self.login_dirs.keys().collect() {
    if !own.contains(id) {
      self.stop_watch("login:\{id}")
      self.login_dirs.remove(id)
    }
  }
  // (a skill no longer shared: its watch, made again by a pass that read it before it stopped, stops)
  let skills : Set[String] = Set::new()
  for _, now in own {
    if now.kind == "skill" {
      skills.add("hosted:\{now.skill.unwrap_or("")}")
    }
  }
  for key in self.watchers.keys().collect() {
    if key.has_prefix("hosted:") && !skills.contains(key) {
      self.stop_watch(key)
    }
  }
  for id, now in own {
    if self.unannounced.contains(id) {
      continue
    }
    if now.kind == "skill" {
      let skill = now.skill.unwrap_or("")
      self.watch_hosted(skill, self.files.join([self.skills_dir(), skill]))
    }
    let p = now.profile.unwrap_or(Json::null())
    if now.kind == "profile" &&
      get(Some(p), "runtime") is Some(String("codex")) &&
      gets(Some(p), ["access", "kind"]) is Some(String("subscription")) {
      self.watch_login(id, self.codex_file(p))
    } else if self.login_dirs.contains(id) {
      self.stop_watch("login:\{id}")
      self.login_dirs.remove(id)
    }
    let hosted = match entry_of(hosted_all, id) {
      Some(h) => h
      None => {
        dirty = true
        let h : Map[String, Json] = Map([])
        h["version"] = jnum(0.0)
        h["hash"] = jstr("")
        h["kind"] = jstr(now.kind)
        h["name"] = jstr(now.name)
        h["allow"] = now.allow
        h["told"] = Json::object(Map([]))
        h
      }
    }
    match now.hash {
      None => {
        let unread = match now.unread {
          Some(u) => Some(jstr(u))
          None => None
        }
        if hosted.get("unread") != unread {
          match unread {
            Some(u) => hosted["unread"] = u
            None => hosted.remove("unread")
          }
          dirty = true
        }
        hosted_all[id] = Json::object(hosted)
        continue
      }
      Some(hash) => {
        if hosted.contains("unread") {
          hosted.remove("unread")
          dirty = true
        }
        // Its name is part of what it is: a skill renamed is linked under its new name where it is copied.
        if hosted.get("hash") != Some(jstr(hash)) || hosted.get("name") != Some(jstr(now.name)) {
          hosted["version"] = jnum_js(js_num(hosted.get("version")) + 1.0)
          hosted["hash"] = jstr(hash)
          dirty = true
        }
        if now.kind == "skill" {
          let next = match self.files.dir_key(self.files.join([self.skills_dir(), now.skill.unwrap_or("")])) {
            Some(k) => Some(jstr(k))
            None => hosted.get("dir")
          }
          if hosted.get("dir") != next {
            match next {
              Some(n) => hosted["dir"] = n
              None => hosted.remove("dir")
            }
            dirty = true
          }
        }
        // Who may use it changed: every station it leaves out now is to be told so (-1, `left_out`). Kept as it was
        // till the stations are known, so that they are told then.
        if self.rosters() is Some(ros) &&
          (
            js_stringify(hosted.get("allow").unwrap_or(Json::null())) != js_stringify(now.allow) ||
            hosted.get("allow") is None
          ) {
          let told = obj_field(hosted, "told")
          for peer in left_out(told, hosted.get("allow"), now.allow, ros, p => self.itself(p)) {
            told[peer] = jnum(-1.0)
          }
          hosted["allow"] = now.allow
          dirty = true
        }
        if hosted.get("name") != Some(jstr(now.name)) {
          hosted["name"] = jstr(now.name)
          dirty = true
        }
        hosted_all[id] = Json::object(hosted)
      }
    }
  }
  // Written before anyone is told, so what they ask for is that version.
  if dirty {
    self.write_state()
  }
  own
}

///|
/// A request to another station (the station transport).
async fn Sharing::ask(self : Sharing, station : String, ws : String?, request : Json) -> Json {
  (self.deps.ask)(station, ws, request)
}
