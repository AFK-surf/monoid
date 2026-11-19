// agy.ts: Antigravity CLI, one `agy acp` per session spoken to in ACP (acp.mbt): its files in the profile's own
// `--gemini-dir` (its sign-in kept in that file alone, moved back from the keychain where it went before), the
// station's instructions appended to its system prompt, no approvals, no telemetry, no updating itself; a message for
// the running turn takes it over, its model and thinking level set by session/set_model; the transcript kept by the
// station with each turn's usage; a borrowed sign-in lent again before it runs out; a process that could not load its
// models opened again after a wait; a conversation brought in from another home of the station.

///|
let agy_scrubbed : Array[String] = [
  "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT",
  "GOOGLE_CLOUD_LOCATION", "AGY_ADC_AUTH", "AGY_ACCOUNT", "STILLFAIL_REPO_RULES",
]

///|
/// The thinking levels Antigravity's models append to a family's name (`AGY_LEVELS`).
let agy_levels : Array[String] = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

///|
/// The waits before a process that offered no models is opened again (`AGY_CATALOG_RETRY_MS`).
let agy_catalog_retry_ms : Array[Double] = [1000.0, 2000.0, 4000.0]

///|
/// A borrowed sign-in is asked of its host again once it has less than this left (`AGY_LENT_RENEW_MS`).
let agy_lent_renew_ms = 2400000.0

///|
/// What `agy` needs left of a sign-in to start on it (`AGY_LENT_LEAST_MS`).
let agy_lent_least_ms = 600000.0

///|
/// Margin before a borrowed sign-in's expiry within which an auth failure is taken as it running out (`AGY_LENT_EXPIRE_MARGIN_MS`).
let agy_lent_expire_margin_ms = 300000.0

///|
/// Minimum time a process must have been open on its borrowed sign-in before another mid-turn expiry reopens it (`AGY_LENT_MIN_RUN_MS`).
let agy_lent_min_run_ms = 300000.0

///|
/// Where the station keeps its sessions' transcripts (`SESSIONS`).
let agy_sessions = "sessions"

///|
let agy_hook_seconds = 10

///|
/// The tools of Antigravity CLI that touch files or directories in a repository (`AGY_REPO_RULES_TOOLS`).
let agy_repo_rules_tools = "run_command|read_file|write_file|edit_file|view_file|grep_search|find_by_name|list_dir"

///|
/// The conversation ids it gives (`SESSION_ID`): /^[a-zA-Z0-9_-]+$/.
pub fn agy_session_id(id : String) -> Bool {
  id.length() > 0 && @jsjson.units(id).iter().all(c => ascii_word(c) || c == 0x2d)
}

///|
pub fn agy_home(m : Machine, home : String) -> String {
  m.join([home, "agy"])
}

///|
pub fn gemini_dir(m : Machine, home : String) -> String {
  m.join([agy_home(m, home), ".gemini"])
}

///|
pub fn agy_token_in(m : Machine, gemini : String) -> String {
  m.join([gemini, "antigravity-cli", "antigravity-oauth-token"])
}

///|
pub fn agy_token(m : Machine, home : String) -> String {
  agy_token_in(m, gemini_dir(m, home))
}

///|
pub fn agy_account_file(m : Machine, home : String) -> String {
  m.join([agy_home(m, home), "account.json"])
}

///|
pub fn agy_conversations(m : Machine, home : String) -> String {
  m.join([gemini_dir(m, home), "antigravity-cli", "conversations"])
}

///|
pub fn agy_hooks_file(m : Machine, home : String) -> String {
  m.join([gemini_dir(m, home), "config", "hooks.json"])
}

///|
/// The process's arguments (`agyArgs`).
pub fn agy_args(m : Machine, home : String) -> Array[String] {
  ["acp", "--gemini-dir", gemini_dir(m, home), "--dangerously-skip-permissions", "--disable-telemetry"]
}

///|
/// What session/new and session/load are given besides (`agyOpening`).
pub fn agy_opening(instructions : String) -> JValue {
  if instructions == "" {
    obj([])
  } else {
    obj([
      (
        "_meta",
        obj([("antigravity", obj([("systemPrompt", obj([("append", s(instructions))]))]))]),
      ),
    ])
  }
}

///|
/// The email of a sign-in's file (`agyEmailIn`).
pub fn agy_email_in(text : String) -> String? {
  match parse_json(text) {
    Some(j) =>
      match str_at(Some(j), "id_token_email") {
        Some(e) if e != "" => Some(e)
        _ => None
      }
    None => None
  }
}

///|
/// go-keyring's stored value as `agy` wrote it (`goKeyringValue`).
pub fn go_keyring_value(stored : String) -> String {
  let b64 = "go-keyring-base64:"
  let hex = "go-keyring-encoded:"
  if stored.has_prefix(b64) {
    return utf8_text(@base64.decode_lossy(stored.substring(start=b64.length()), ignore_whitespace=true))
  }
  if stored.has_prefix(hex) {
    let digits = stored.substring(start=hex.length())
    let out = @buffer.Buffer()
    let value = (c : Int) => if c >= 0x30 && c <= 0x39 {
      Some(c - 0x30)
    } else if c >= 0x61 && c <= 0x66 {
      Some(c - 0x61 + 10)
    } else if c >= 0x41 && c <= 0x46 {
      Some(c - 0x41 + 10)
    } else {
      None
    }
    let mut i = 0
    while i + 1 < digits.length() {
      match (value(digits.unsafe_charcode_at(i)), value(digits.unsafe_charcode_at(i + 1))) {
        (Some(hi), Some(lo)) => out.write_byte((hi * 16 + lo).to_byte())
        _ => break
      }
      i += 2
    }
    return utf8_text(out.to_bytes())
  }
  stored
}

///|
/// A way of signing in that is a company's (`companyMethod`).
pub fn company_method(meth : JValue?) -> Bool {
  match str_of(meth) {
    Some(m) => m != "" && m != "consumer" && m != "oauth"
    None => false
  }
}

///|
/// Whether a sign-in's file is one `agy` runs on (`agyTokenReady`).
pub fn agy_token_ready(text : String, enterprise : Bool) -> Bool {
  guard parse_json(text) is Some(parsed) else { return false }
  let filled = (v : JValue?) => match str_of(v) {
    Some(x) => x != ""
    None => false
  }
  if !filled(get(get(Some(parsed), "token"), "access_token")) {
    return false
  }
  let company = enterprise || company_method(get(Some(parsed), "auth_method"))
  !company || filled(get(Some(parsed), "user_tier")) || filled(get(Some(parsed), "project_id"))
}

///|
/// Whether a sign-in's file is a company's Google account's (`agyCompany`).
pub fn agy_company(text : String) -> Bool {
  match parse_json(text) {
    Some(j) => company_method(get(Some(j), "auth_method"))
    None => false
  }
}

///|
/// The plan a Google account is on, from its tier (`agyPlan`).
pub fn agy_plan(tier : String?, company? : Bool = false) -> String? {
  let id = match tier {
    Some(t) => @jscase.lower(@jscase.trim(t))
    None => ""
  }
  let known = [
    ("g1-ultra-tier", "Ultra"),
    ("g1-pro-tier", "Pro"),
    ("free-tier", "Free"),
    ("gcp-ge-ultra-tier", "Enterprise Ultra"),
    ("gcp-ge-plus-tier", "Enterprise Plus"),
    ("gcp-ge-standard-tier", "Enterprise"),
    ("gcp-standard-tier", "Enterprise"),
  ]
  for k in known {
    if k.0 == id {
      return Some(k.1)
    }
  }
  if id.has_prefix("gcp-") || company {
    Some("Enterprise")
  } else {
    None
  }
}

///|
/// The plan of a profile's sign-in as its file says it (`agyPlanIn`).
pub fn agy_plan_in(text : String, enterprise? : Bool = false) -> String? {
  match parse_json(text) {
    Some(j) => agy_plan(str_at(Some(j), "user_tier"), company=enterprise || agy_company(text))
    None => if enterprise { Some("Enterprise") } else { None }
  }
}

///|
/// `Date.parse` of an ISO time (a date, a time to the second with its fraction, `Z` or an offset), none otherwise; a
/// time with no zone read as UTC.
pub fn date_parse(text : String) -> Double? {
  let u = @jsjson.units(text)
  let at = Ref(0)
  let digits = (count : Int) => {
    if at.val + count > u.length() {
      return None
    }
    let mut v = 0
    for k in 0..<count {
      let c = u[at.val + k]
      if c < 0x30 || c > 0x39 {
        return None
      }
      v = v * 10 + (c - 0x30)
    }
    at.val += count
    Some(v)
  }
  let sign = if at.val < u.length() && (u[0] == 0x2b || u[0] == 0x2d) {
    let s = if u[0] == 0x2d { -1 } else { 1 }
    at.val = 1
    Some(s)
  } else {
    None
  }
  let year = match sign {
    Some(sg) => digits(6).map(y => y * sg)
    None => digits(4)
  }
  guard year is Some(year) else { return None }
  let peek = (c : Int) => at.val < u.length() && u[at.val] == c
  let mut month = 1
  let mut day = 1
  if peek(0x2d) {
    at.val += 1
    guard digits(2) is Some(mo) else { return None }
    month = mo
    if peek(0x2d) {
      at.val += 1
      guard digits(2) is Some(dd) else { return None }
      day = dd
    }
  }
  let mut hour = 0
  let mut minute = 0
  let mut second = 0
  let mut millis = 0.0
  let mut offset = 0
  if peek(0x54) || peek(0x74) {
    at.val += 1
    guard digits(2) is Some(h) else { return None }
    guard peek(0x3a) else { return None }
    at.val += 1
    guard digits(2) is Some(mi) else { return None }
    hour = h
    minute = mi
    if peek(0x3a) {
      at.val += 1
      guard digits(2) is Some(se) else { return None }
      second = se
      if peek(0x2e) || peek(0x2c) {
        at.val += 1
        let start = at.val
        let mut frac = 0.0
        let mut scale = 100.0
        while at.val < u.length() && u[at.val] >= 0x30 && u[at.val] <= 0x39 {
          if scale >= 1.0 {
            frac += (u[at.val] - 0x30).to_double() * scale
          }
          scale /= 10.0
          at.val += 1
        }
        if at.val == start {
          return None
        }
        millis = frac.floor()
      }
    }
    if peek(0x5a) || peek(0x7a) {
      at.val += 1
    } else if peek(0x2b) || peek(0x2d) {
      let sg = if u[at.val] == 0x2d { -1 } else { 1 }
      at.val += 1
      guard digits(2) is Some(oh) else { return None }
      if peek(0x3a) {
        at.val += 1
      }
      guard digits(2) is Some(om) else { return None }
      offset = sg * (oh * 60 + om)
    }
  } else if peek(0x5a) {
    at.val += 1
  }
  if at.val != u.length() {
    return None
  }
  if month < 1 || month > 12 || day < 1 || day > 31 || hour > 24 || minute > 59 || second > 59 {
    return None
  }
  if hour == 24 && (minute != 0 || second != 0 || millis != 0.0) {
    return None
  }
  let days = days_from_civil(year, month, day)
  Some(
    days.to_double() * 86400000.0 +
    ((hour * 60 + minute - offset) * 60 + second).to_double() * 1000.0 +
    millis,
  )
}

///|
/// Days since 1970-01-01 of a date of the proleptic Gregorian calendar.
pub fn days_from_civil(y0 : Int, m : Int, d : Int) -> Int {
  @time.days_from_civil(y0, m, d).to_int()
}

///|
/// When the access token of a sign-in runs out (`agyExpiryIn`), 0 when none is readable.
pub fn agy_expiry_in(text : String) -> Double {
  match parse_json(text) {
    Some(j) =>
      match str_at(get(Some(j), "token"), "expiry") {
        Some(e) => date_parse(e).unwrap_or(0.0)
        None => 0.0
      }
    None => 0.0
  }
}

///|
/// A sign-in as a borrower keeps it (`agyLentFile`).
pub fn agy_lent_file(lent : JValue) -> String {
  let token = match get(Some(lent), "token") {
    Some(Obj(_) as t) => del(t, "refresh_token")
    _ => obj([])
  }
  let stored = match get(Some(lent), "stored") {
    Some(Obj(_) as st) => st
    _ => obj([])
  }
  let meth = match get(Some(lent), "auth_method") {
    Some(Null) | None =>
      match get(Some(stored), "auth_method") {
        Some(Null) | None => s("consumer")
        Some(m) => m
      }
    Some(m) => m
  }
  let parts = [stored, obj([("token", token), ("auth_method", meth)])]
  match get(Some(lent), "email") {
    Some(Str(u)) if u.length() > 0 => parts.push(obj([("id_token_email", Str(u))]))
    _ => ()
  }
  json_text(spread(parts))
}

///|
/// What failed a turn, from what it said of it (`classifyFailure`).
pub fn agy_classify_failure(text : String) -> String {
  failure_of(
    text,
    auth=[
      "authentication required", "not logged into antigravity", "authentication expired", "couldn't sign in", "invalid_grant",
      "unauthenticated", "token expired",
    ],
    limit=["resource_exhausted", "quota"],
  )
}

///|
/// A failure Antigravity CLI tells only in words (`noticeFailure`): the reading's (mb/src/acp `notice_failure`).
pub fn agy_notice_failure(said : String) -> String? {
  @acp.notice_failure(said)
}

///|
/// A raw ACP `modelId` split into its base model and thinking level (`agyBaseModel`).
pub fn agy_base_model(id : String) -> (String, String?) {
  let trimmed = @jscase.trim(id)
  for l in agy_levels {
    if trimmed.has_suffix("-\{l}") && trimmed.length() > l.length() + 1 {
      return (trimmed.substring(end=trimmed.length() - l.length() - 1), Some(l))
    }
  }
  (trimmed, None)
}

///|
/// The tier session/new or session/load said the account is on (`agyTierIn`).
pub fn agy_tier_in(result : JValue?) -> String? {
  match str_at(get(get(get(result, "_meta"), "antigravity"), "tier"), "id") {
    Some(id) if id != "" => Some(id)
    _ => None
  }
}

///|
/// The base models, their thinking levels and default levels (`agyCatalog`).
pub fn agy_catalog(available : Array[String], current : String?) -> JValue {
  let models = []
  let levels : Array[(String, Array[String])] = []
  for raw in available {
    let (model, effort) = agy_base_model(raw)
    if model == "" {
      continue
    }
    if !models.contains(model) {
      models.push(model)
    }
    match effort {
      Some(e) =>
        match levels.search_by(l => l.0 == model) {
          Some(i) => if !levels[i].1.contains(e) { levels[i].1.push(e) }
          None => levels.push((model, [e]))
        }
      None => ()
    }
  }
  let cur = match current {
    Some(c) if @jscase.trim(c) != "" => Some(agy_base_model(c))
    _ => None
  }
  let efforts = []
  let defaults = []
  for model in models {
    let have = match levels.search_by(l => l.0 == model) {
      Some(i) => levels[i].1
      None => []
    }
    let sorted = agy_levels.filter(l => have.contains(l))
    efforts.push((model, strs(if sorted.length() >= 2 { sorted } else { [] })))
    if sorted.length() >= 2 {
      let level = match cur {
        Some((cm, Some(ce))) if cm == model && sorted.contains(ce) => ce
        _ =>
          if sorted.contains("medium") {
            "medium"
          } else if sorted.contains("high") {
            "high"
          } else {
            sorted[sorted.length() - 1]
          }
      }
      defaults.push((model, s(level)))
    }
  }
  obj([("models", strs(models)), ("efforts", obj(efforts)), ("defaults", obj(defaults))])
}

///|
/// The ACP `modelId` for a model and effort among those offered (`agyVariant`), none where none of it is.
pub fn agy_variant(model : String, effort : String?, available : Array[String], default_id : String?) -> String? {
  let (base, inline) = agy_base_model(model)
  let wanted = match effort {
    Some(e) if agy_levels.contains(e) => Some(e)
    _ => inline
  }
  match (wanted, default_id) {
    (None, Some(def)) if def != "" && agy_base_model(def).0 == base =>
      if available.length() == 0 || available.contains(def) {
        return Some(def)
      }
    _ => ()
  }
  if available.length() == 0 {
    return match (wanted, inline) {
      (Some(w), None) => Some("\{base}-\{w}")
      _ => Some(model)
    }
  }
  match wanted {
    Some(w) if available.contains("\{base}-\{w}") => return Some("\{base}-\{w}")
    _ => ()
  }
  if effort is None && available.contains(model) {
    return Some(model)
  }
  if available.contains(base) {
    return Some(base)
  }
  let variants = available.filter(m => agy_base_model(m).0 == base)
  if variants.length() == 0 {
    return None
  }
  if variants.contains("\{base}-medium") {
    Some("\{base}-medium")
  } else if variants.contains("\{base}-high") {
    Some("\{base}-high")
  } else {
    Some(variants[0])
  }
}

///|
/// The models session/new or session/load lists, the current first (`agyModels`).
pub fn agy_models(result : JValue?) -> Array[String] {
  let valid = (v : JValue?) => match str_of(v) {
    Some(t) => @jscase.trim(t) != ""
    None => false
  }
  let out = []
  let models = get(result, "models")
  if valid(get(models, "currentModelId")) {
    out.push(str_at(models, "currentModelId").unwrap())
  }
  for m in arr_at(models, "availableModels").unwrap_or([]) {
    if valid(get(Some(m), "modelId")) {
      let id = str_at(Some(m), "modelId").unwrap()
      if !out.contains(id) {
        out.push(id)
      }
    }
  }
  out
}

///|
/// A turn's counts as the prompt's answer says them (`turnUsage`). agy says them apart, as its `totalTokens` adds them
/// up (`inputTokens + outputTokens + cachedReadTokens`): what was read from the cache is not in `inputTokens`, and
/// `thoughtTokens` is already in `outputTokens`.
pub fn turn_usage(answer : JValue?) -> JValue? {
  guard get(get(answer, "result"), "usage") is Some(Obj(_) as u) else { return None }
  let num = (k : String) => match get(Some(u), k) {
    Some(Num(x)) if x - x == 0.0 && x > 0.0 => x
    _ => 0.0
  }
  Some(
    obj([
      ("inputTokens", d(num("inputTokens"))),
      ("cacheReadTokens", d(num("cachedReadTokens"))),
      ("cacheWriteTokens", d(num("cachedWriteTokens"))),
      ("outputTokens", d(num("outputTokens"))),
    ]),
  )
}

///|
/// What the Antigravity driver is given beside the machine.
pub(all) struct AgyWorld {
  raw_env : Env
  has_keychain : Bool
  /// the keychain item `agy` kept a sign-in in before (`agyKeychain.read`)
  keychain_read : () -> Later[String?]
  lent_borrowed : ((JValue) -> Bool)?
  lent_write : ((JValue) -> Later[Double])?
  /// a command run to its end (`execFile`): command, arguments, environment, where, how long at most
  run : (String, Array[String], Env, String, Double) -> Later[Unit]
  /// a wait on the driver's clock (`AgyDriverOptions.clock`)
  sleep : (Double) -> Later[Unit]
}

///|
/// The Antigravity CLI driver (`AgyDriver`).
pub struct AgyDriver {
  own : OwnDriver
  command : String
  world : AgyWorld
  profiles : ProfileSays
  words : Words
  ids : Ids
  lost : Array[String]
  sessions : Array[AgySession]
}

///|
/// An Antigravity CLI session (`AgySession`).
pub struct AgySession {
  acp : AcpSession
  driver : AgyDriver
  mut available_models : Array[String]
  mut current_model_id : String?
  mut default_model_id : String?
  mut tier : String?
  mut context_used : Double
  mut context_size : Double
  mut sign_in_until : Double?
  mut sign_in_opened_at : Double?
}

///|
pub fn AgyDriver::new(
  m : Machine,
  data : String,
  procs : Procs,
  command? : String = "agy",
  world : AgyWorld,
  profiles : ProfileSays,
  words : Words,
  ids : Ids,
) -> AgyDriver {
  {
    own: OwnDriver::new(m, data, procs, "agy"),
    command,
    world,
    profiles,
    words,
    ids,
    lost: [],
    sessions: [],
  }
}

///|
pub fn AgyDriver::m(self : AgyDriver) -> Machine {
  self.own.m
}

///|
pub fn AgyDriver::lp(self : AgyDriver) -> Loop {
  self.own.m.lp
}

///|
/// The environment of an Antigravity CLI process (`agyEnv`).
pub fn AgyDriver::env_for(self : AgyDriver, options : JValue) -> Env {
  let o = Some(options)
  let profile = get(o, "profile").unwrap_or(Null)
  let env = start_env(self.world.raw_env, agy_scrubbed)
  env.merge(expand_route((self.profiles.env)(profile, "agy"), str_at(o, "route").unwrap_or("")))
  // The profile's own proxy too leaves this machine out (`keepLocal`).
  let env = keep_local(env)
  env.set("ANTIGRAVITY_GEMINI_DIR", gemini_dir(self.m(), profile_home(profile)))
  if self.world.has_keychain {
    env.set("SSH_CLIENT", "127.0.0.1 0 0")
  }
  env.set("AGY_CLI_DISABLE_AUTO_UPDATE", "1")
  env.set("STILLFAIL_PEER_HTTP", peer_http_base(str_at(o, "mcpUrl").unwrap_or("")))
  if str_at(o, "instructions").unwrap_or("") == "" {
    env.set("STILLFAIL_REPO_RULES", "0")
  }
  env
}

///|
/// The hooks file kept telling a repository's rules (`agyHooks`).
pub fn AgyDriver::hooks(self : AgyDriver, home : String) -> Later[Unit] {
  let m = self.m()
  let file = agy_hooks_file(m, home)
  m
  .read_file(file)
  .map(raw => Some(raw))
  .recover(_ => Later::ok(m.lp, None))
  .bind(raw_now => {
    let current = match raw_now {
      Some(raw) =>
        match parse_json(raw) {
          Some(Obj(_) as o) => o
          _ => obj([])
        }
      None => obj([])
    }
    let command = (with_matcher : Bool) => {
      let hook = obj([
        ("type", s("command")),
        ("command", s(self.words.agy_repo_rules_command)),
        ("timeout", n(agy_hook_seconds)),
      ])
      if with_matcher {
        obj([("matcher", s(agy_repo_rules_tools)), ("hooks", arr([hook]))])
      } else {
        hook
      }
    }
    let next = set(
      current,
      "stillfail",
      obj([("PostToolUse", arr([command(true)])), ("PostInvocation", arr([command(false)]))]),
    )
    let text = @jsjson.stringify_indent(next, 2) + "\n"
    if raw_now == Some(text) {
      return done(m.lp)
    }
    m.make_dir(m.join([gemini_dir(m, home), "config"])).bind(_ => m.write_file(file, text))
  })
}

///|
/// Each workspace skill made a directory of its own in the workspace (`agySkills`).
pub fn agy_skills(m : Machine, cwd : String, skills_dir : String?) -> Later[Unit] {
  let lp = m.lp
  let not_skill = [".git", "node_modules", ".venv"]
  let list = (dir : String) => m.read_dir(dir).recover(_ => Later::ok(lp, []))
  let sources : Array[(String, String)] = []
  let dot_agents = m.join([cwd, ".agents", "skills"])
  list(dot_agents)
  .bind(names => {
    for name in names {
      if !name.has_prefix(".") {
        put_pair(sources, name, m.join([dot_agents, name]))
      }
    }
    match skills_dir {
      Some(dir) =>
        list(dir).map(more => for name in more {
          if !name.has_prefix(".") && !sources.iter().any(x => x.0 == name) {
            sources.push((name, m.join([dir, name])))
          }
        })
      None => done(lp)
    }
  })
  .bind(_ => {
    let root = m.join([cwd, ".agent", "skills"])
    let valid : Array[(String, String, String, FileStat)] = []
    each_in_turn(lp, sources.length(), i => {
      let (name, src) = sources[i]
      m
      .realpath(src)
      .bind(dir => match dir {
        None => done(lp)
        Some(dir) =>
          m
          .realpath(m.join([dir, "SKILL.md"]))
          .bind(md => match md {
            None => done(lp)
            Some(md) =>
              m
              .stat(md)
              .map(st => match st {
                Some(st) if st.file => valid.push((name, dir, md, st))
                _ => ()
              })
          })
      })
      .recover(_ => done(lp))
    })
    .bind(_ => list(root))
    .bind(olds => each_in_turn(lp, olds.length(), i => if !valid.iter().any(v => v.0 == olds[i]) {
      m.remove_tree(m.join([root, olds[i]]))
    } else {
      done(lp)
    }))
    .bind(_ => {
      if valid.length() == 0 {
        return done(lp)
      }
      m
      .make_dir(root)
      .bind(_ => each_in_turn(lp, valid.length(), i => {
        let (name, dir, md, src) = valid[i]
        let target = m.join([root, name])
        m
        .stat(target, follow=false)
        .bind(meta => match meta {
          Some(t) if !t.directory => m.remove_tree(target)
          _ => done(lp)
        })
        .bind(_ => m.make_dir(target))
        .bind(_ => {
          let dst = m.join([target, "SKILL.md"])
          m
          .stat(dst, follow=false)
          .bind(dm => {
            let same_inode = match dm {
              Some(x) => !x.symlink && x.dev == src.dev && x.ino == src.ino
              None => false
            }
            let same_copy = match dm {
              Some(x) =>
                !x.symlink && x.dev != src.dev && x.size == src.size && (x.mtime - src.mtime).abs() < 1.0
              None => false
            }
            if same_inode || same_copy {
              done(lp)
            } else {
              m
              .remove(dst)
              .recover(_ => done(lp))
              .bind(_ => m.hard_link(md, dst).recover(_ => m.copy_file(md, dst)))
            }
          })
        })
        .bind(_ => list(dir))
        .bind(entries => {
          let siblings = entries.filter(e => e != "SKILL.md" && !not_skill.contains(e))
          let keep = ["SKILL.md"] + siblings
          list(target)
          .bind(existing => each_in_turn(lp, existing.length(), k => if !keep.contains(existing[k]) {
            m.remove_tree(m.join([target, existing[k]]))
          } else {
            done(lp)
          }))
          .bind(_ => each_in_turn(lp, siblings.length(), k => {
            let at = m.join([target, siblings[k]])
            m
            .stat(at, follow=false)
            .bind(st => if st is None {
              m.link_path(m.join([dir, siblings[k]]), at).recover(_ => done(lp))
            } else {
              done(lp)
            })
          }))
        })
      }))
    })
  })
}

///|
/// When the conversation's database (or its `-wal`) was last written in a CLI's store (`lastWritten`).
pub fn last_written(m : Machine, cli : String, id : String) -> Later[Double?] {
  m
  .stat(m.join([cli, "conversations", "\{id}.db"]))
  .bind(db => match db {
    None => Later::ok(m.lp, None)
    Some(db) =>
      m
      .stat(m.join([cli, "conversations", "\{id}.db-wal"]))
      .map(wal => {
        let w = match wal {
          Some(x) => x.mtime
          None => 0.0
        }
        Some(if db.mtime > w { db.mtime } else { w })
      })
  })
}

///|
/// How many conversations this process brought in (`agy_bring_in`): the names it copies beside under.
let agy_bring_seq : Ref[Int] = { val: 0 }

///|
/// A conversation brought into a profile's CLI from another home of the station that kept it last (`agyBringIn`): the
/// name of that home, none where nothing was brought.
pub fn agy_bring_in(m : Machine, home : String, id : String) -> Later[String?] {
  let lp = m.lp
  if !agy_session_id(id) {
    return Later::ok(lp, None)
  }
  let cli_of = (h : String) => m.join([gemini_dir(m, h), "antigravity-cli"])
  let here = cli_of(home)
  let homes = dirname_of(m, home)
  last_written(m, here, id).bind(mine => m
    .read_dir(homes)
    .recover(_ => Later::ok(lp, []))
    .bind(names => {
      let sorted = names.copy()
      sorted.sort_by(js_compare)
      let best : Ref[(String, String, Double)?] = Ref(None)
      each_in_turn(lp, sorted.length(), i => {
        let other = m.join([homes, sorted[i]])
        if other == home {
          return done(lp)
        }
        last_written(m, cli_of(other), id).map(at => match at {
          Some(t) => {
            let newer = match mine {
              Some(x) => t > x
              None => true
            }
            let best_ok = match best.val {
              Some((_, _, bt)) => t > bt
              None => true
            }
            if newer && best_ok {
              best.val = Some((sorted[i], cli_of(other), t))
            }
          }
          None => ()
        })
      })
      .bind(_ => {
        guard best.val is Some((name, cli, _)) else { return Later::ok(lp, None) }
        let conv = m.join([here, "conversations"])
        let db = m.join([conv, "\{id}.db"])
        let from_wal = m.join([cli, "conversations", "\{id}.db-wal"])
        // (names of its own beside, so that two bringing it at once, or one left by a failed one, are not each other's)
        agy_bring_seq.val += 1
        let db_bringing = "\{db}.\{agy_bring_seq.val}.bringing"
        let wal_bringing = "\{db}-wal.\{agy_bring_seq.val}.bringing"
        m
        .make_dir(conv)
        .bind(_ => m.there(from_wal))
        .bind(has_wal => m
          .copy(m.join([cli, "conversations", "\{id}.db"]), db_bringing)
          .bind(_ => if has_wal { m.copy(from_wal, wal_bringing) } else { done(lp) })
          .bind(_ => {
            let parts = [("annotations", "\{id}.pbtxt"), ("brain", id)]
            each_in_turn(lp, parts.length(), k => {
              let (dir, entry) = parts[k]
              m
              .remove_tree(m.join([here, dir, entry]))
              .bind(_ => m.there(m.join([cli, dir, entry])))
              .bind(there => if !there {
                done(lp)
              } else {
                m
                .make_dir(m.join([here, dir]))
                .bind(_ => m.copy(m.join([cli, dir, entry]), m.join([here, dir, entry])))
              })
            })
          })
          .bind(_ => m.remove_tree("\{db}-wal"))
          .bind(_ => m.remove_tree("\{db}-shm"))
          .bind(_ => m.rename(db_bringing, db))
          .bind(_ => if has_wal { m.rename(wal_bringing, "\{db}-wal") } else { done(lp) })
          .map(_ => {
            m.log(
              "info",
              "agy",
              "a conversation brought into the profile's CLI from another home of the station",
              obj([("id", s(id)), ("from", s(name)), ("to", s(home))]),
            )
            Some(name)
          }))
      })
    }))
}

///|
/// `path.dirname`.
pub fn dirname_of(m : Machine, path : String) -> String {
  match path.rev_find(m.sep) {
    Some(0) => m.sep
    Some(i) => path.substring(end=i)
    None => "."
  }
}

///|
/// The email noted of a profile's sign-in (`agyNotedEmail`).
pub fn agy_noted_email(m : Machine, home : String) -> Later[String?] {
  m
  .read_file(agy_account_file(m, home))
  .map(text => match parse_json(text) {
    Some(j) =>
      match str_at(Some(j), "email") {
        Some(e) if e != "" => Some(e)
        _ => None
      }
    None => None
  })
  .recover(_ => Later::ok(m.lp, None))
}

///|
/// The email of a sign-in noted beside it (`noteAgyEmail`).
pub fn note_agy_email(m : Machine, home : String, text : String) -> Later[String?] {
  match parse_json(text) {
    Some(Obj(_) as parsed) => {
      let email = match str_at(Some(parsed), "id_token_email") {
        Some(e) if e != "" => Some(e)
        _ => None
      }
      let body = match email {
        Some(e) => obj([("email", s(e))])
        None => obj([])
      }
      m
      .write_file(agy_account_file(m, home), json_text(body) + "\n")
      .recover(_ => done(m.lp))
      .map(_ => email)
    }
    _ => m.remove_tree(agy_account_file(m, home)).recover(_ => done(m.lp)).map(_ => None)
  }
}

///|
/// Whether the profile has its sign-in in its file, moved back from the keychain where it is its account's (`agyTakeBack`).
pub fn AgyDriver::take_back(self : AgyDriver, home : String) -> Later[Bool] {
  let m = self.m()
  let lp = m.lp
  m
  .stat(agy_token(m, home), follow=false)
  .bind(st => {
    if st is Some(_) {
      return Later::ok(lp, true)
    }
    if !self.world.has_keychain {
      return Later::ok(lp, false)
    }
    agy_noted_email(m, home).bind(noted => {
      guard noted is Some(noted) else { return Later::ok(lp, false) }
      (self.world.keychain_read)().bind(stored => {
        guard stored is Some(stored) else { return Later::ok(lp, false) }
        let text = go_keyring_value(stored)
        if agy_email_in(text) != Some(noted) {
          return Later::ok(lp, false)
        }
        m
        .write_file(agy_token(m, home), text, private=true)
        .map(_ => {
          m.log(
            "info",
            "agents::agy",
            "a profile's sign-in moved back from the keychain to its file",
            obj([("home", s(home))]),
          )
          true
        })
        .recover(e => {
          m.log(
            "warn",
            "agents::agy",
            "could not move a profile's sign-in out of the keychain",
            obj([("home", s(home)), ("error", s(words_of(e)))]),
          )
          Later::ok(lp, false)
        })
      })
    })
  })
}

///|
/// When the profile's sign-in runs out (`agyExpiry`).
pub fn agy_expiry(m : Machine, home : String) -> Later[Double] {
  m
  .read_file(agy_token(m, home))
  .map(t => agy_expiry_in(t))
  .recover(_ => Later::ok(m.lp, 0.0))
}

///|
/// The profile's sign-in renewed by `agy` itself (`agyRenew`).
pub fn AgyDriver::renew(self : AgyDriver, home : String) -> Later[Unit] {
  let m = self.m()
  m
  .read_file(agy_token(m, home))
  .bind(had => {
    guard parse_json(had) is Some(parsed) else { raise Failed("not JSON") }
    match str_at(get(Some(parsed), "token"), "refresh_token") {
      Some(r) if r != "" => ()
      _ => raise Failed("no refresh token")
    }
    let dir = m.join([agy_home(m, home), "renewing"])
    let gemini = m.join([dir, ".gemini"])
    let marked = agy_token_in(m, gemini)
    m
    .remove_tree(dir)
    .bind(_ => {
      let work = m
        .make_dir(m.join([gemini, "antigravity-cli"]))
        .bind(_ => {
          let token = set(get(Some(parsed), "token").unwrap(), "expiry", s("1970-01-01T00:00:00Z"))
          m.write_file(marked, json_text(set(parsed, "token", token)), private=true)
        })
        .bind(_ => {
          let env = start_env(self.world.raw_env, agy_scrubbed)
          env.merge([
            ("HOME", dir),
            ("ANTIGRAVITY_GEMINI_DIR", gemini),
            ("AGY_CLI_DISABLE_AUTO_UPDATE", "1"),
            ("SSH_CLIENT", "127.0.0.1 0 0"),
          ])
          (self.world.run)(self.command, ["models"], env, dir, 30000.0)
        })
        .bind(_ => m.read_file(marked))
        .bind(renewed => {
          if agy_expiry_in(renewed) <= m.now() {
            raise Failed("agy did not renew the sign-in")
          }
          guard parse_json(renewed) is Some(fresh) else { raise Failed("not JSON") }
          let merged = set(spread([parsed, fresh]), "token", get(Some(fresh), "token").unwrap_or(Null))
          m.write_file(agy_token(m, home), json_text(merged), private=true)
        })
      work.always(() => m.remove_tree(dir).on(_ => ()))
    })
  })
}

///|
/// Marks a conversation as missing its trajectory in the CLI (`noteLost`).
pub fn AgyDriver::note_lost(self : AgyDriver, id : String) -> Unit {
  if agy_session_id(id) && !self.lost.contains(id) {
    self.lost.push(id)
  }
}

///|
/// A conversation resumed or taken up is one its CLI keeps (`ensureConversation`).
pub fn AgyDriver::ensure_conversation(self : AgyDriver, home : String, id : String) -> Later[Unit] {
  let m = self.m()
  if !agy_session_id(id) {
    return done(m.lp)
  }
  if self.lost.contains(id) {
    return Later::fail(m.lp, Failed("Antigravity conversation \{id} lost its trajectory in its CLI's store"))
  }
  agy_bring_in(m, home, id)
  .bind(_ => m.there(m.join([agy_conversations(m, home), "\{id}.db"])))
  .map(there => if !there {
    raise Failed("no Antigravity conversation \{id} in its CLI's store")
  })
}

///|
/// A borrowed sign-in with little left lent again before a process opens on it (`renewLent`).
pub fn AgyDriver::renew_lent(self : AgyDriver, profile : JValue) -> Later[Unit] {
  let m = self.m()
  agy_expiry(m, profile_home(profile)).bind(until => {
    if until - m.now() >= agy_lent_renew_ms {
      return done(m.lp)
    }
    (self.world.lent_write.unwrap())(profile)
    .map(_ => ())
    .recover(e => {
      if until - m.now() < agy_lent_least_ms {
        return Later::fail(m.lp, e)
      }
      m.log(
        "warn",
        "agents::agy",
        "its borrowed sign-in runs out soon and no new one was lent; it goes on with the one it has",
        obj([("profile", s(profile_id(profile))), ("error", s(words_of(e)))]),
      )
      done(m.lp)
    })
  })
}

///|
pub fn AgyDriver::borrowed(self : AgyDriver, profile : JValue) -> Bool {
  match self.world.lent_borrowed {
    Some(f) => f(profile)
    None => false
  }
}

///|
/// A session of it, not open yet (`session`).
pub fn AgyDriver::session(self : AgyDriver, options : JValue, events : (JValue) -> Unit) -> AgySession {
  let m = self.m()
  let profile = get(Some(options), "profile").unwrap_or(Null)
  let transcript = KeptTranscript::new(m, "agy", m.join([agy_home(m, profile_home(profile)), agy_sessions]))
  let acp = AcpSession::new(m.lp, "agy", self.ids, events, Some(transcript))
  let session = {
    acp,
    driver: self,
    available_models: [],
    current_model_id: None,
    default_model_id: None,
    tier: None,
    context_used: 0.0,
    context_size: 0.0,
    sign_in_until: None,
    sign_in_opened_at: None,
  }
  acp.acp = {
    updated: (update, _) => session.updated(update),
    ending: (id, answer) => session.ending(id, answer),
    ignored: (id, answer) => session.ending(id, answer),
    prompt_text: t => t,
    kept: () => session.kept(),
    taken: snapshot => session.taken(snapshot),
    opened: result => session.opened(result),
    named: id => if !agy_session_id(id) { raise Failed("invalid Antigravity conversation id") },
  }
  session
}

///|
pub fn AgySession::opened(self : AgySession, result : JValue?) -> Unit {
  self.available_models = agy_models(result)
  self.tier = match agy_tier_in(result) {
    Some(t) => Some(t)
    None => self.tier
  }
  match str_at(get(result, "models"), "currentModelId") {
    Some(current) if current != "" => {
      self.current_model_id = Some(current)
      self.default_model_id = Some(current)
      self.acp.model = Some(agy_base_model(current).0)
    }
    _ => ()
  }
}

///|
pub fn AgySession::kept(self : AgySession) -> Array[(String, JValue)] {
  [
    ("availableModels", strs(self.available_models)),
    ("currentModelId", opt_s(self.current_model_id)),
    ("defaultModelId", opt_s(self.default_model_id)),
    ("context", obj([("used", d(self.context_used)), ("size", d(self.context_size))])),
    (
      "signInUntil",
      match self.sign_in_until {
        Some(x) => d(x)
        None => Null
      },
    ),
    (
      "signInOpenedAt",
      match self.sign_in_opened_at {
        Some(x) => d(x)
        None => Null
      },
    ),
  ]
}

///|
pub fn AgySession::taken(self : AgySession, snapshot : JValue) -> Unit {
  let sn = Some(snapshot)
  self.available_models = strings_in(get(sn, "availableModels"))
  self.current_model_id = match str_at(sn, "currentModelId") {
    Some(c) => Some(c)
    None => self.acp.model
  }
  self.default_model_id = str_at(sn, "defaultModelId")
  match get(sn, "context") {
    Some(Obj(_) as c) => {
      self.context_used = num_at(Some(c), "used").unwrap_or(0.0)
      self.context_size = num_at(Some(c), "size").unwrap_or(0.0)
    }
    _ => ()
  }
  self.sign_in_until = num_at(sn, "signInUntil")
  self.sign_in_opened_at = num_at(sn, "signInOpenedAt")
}

///|
/// Its borrowed sign-in has too little left to take a turn on (`outlived`).
pub fn AgySession::outlived(self : AgySession) -> Bool {
  match self.sign_in_until {
    Some(until) => until - self.driver.m().now() < agy_lent_renew_ms
    None => false
  }
}

///|
/// Its borrowed sign-in has run out under the turn (`signInExpired`).
pub fn AgySession::sign_in_expired(self : AgySession) -> Bool {
  match self.sign_in_until {
    Some(until) => until - self.driver.m().now() <= agy_lent_expire_margin_ms
    None => false
  }
}

///|
/// Its known borrowed sign-in ran at least AGY_LENT_MIN_RUN_MS and reached expiry (`lentExpired`).
pub fn AgySession::lent_expired(self : AgySession) -> Bool {
  match (self.sign_in_until, self.sign_in_opened_at) {
    (Some(until), Some(opened_at)) if until > 0.0 => {
      let now = self.driver.m().now()
      until - now <= agy_lent_expire_margin_ms && now - opened_at >= agy_lent_min_run_ms
    }
    _ => false
  }
}

///|
pub fn AgySession::updated(self : AgySession, update : JValue) -> Unit {
  if str_at(Some(update), "sessionUpdate") != Some("usage_update") {
    return
  }
  let num = (k : String) => match get(Some(update), k) {
    Some(Num(x)) if x - x == 0.0 && x > 0.0 => x
    _ => 0.0
  }
  if num("used") > 0.0 {
    self.context_used = num("used")
  }
  if num("size") > 0.0 {
    self.context_size = num("size")
  }
}

///|
/// The turn's usage into the transcript before its end (`ending`).
pub fn AgySession::ending(self : AgySession, id : String, answer : JValue) -> Unit {
  match get(Some(answer), "error") {
    Some(e) =>
      if has_word_ci(error_text(Some(e)), "trajectory not found") {
        self.driver.note_lost(self.acp.own.session_id)
      }
    None => ()
  }
  match turn_usage(Some(answer)) {
    Some(usage) =>
      match self.acp.transcript {
        Some(t) => {
          let run = match id.find(":") {
            Some(i) => id.substring(start=i + 1)
            None => id
          }
          t.keep(
            self.acp.own.session_id,
            obj([
              ("type", s("usage")),
              ("run", s(run)),
              ("model", opt_s(self.acp.model)),
              ("usage", usage),
              ("calls", n(1)),
              ("context", d(self.context_used)),
              ("window", d(self.context_size)),
            ]),
          )
        }
        None => ()
      }
    None => ()
  }
}

///|
/// `/\b<phrase>\b/i`.
pub fn has_word_ci(text : String, phrase : String) -> Bool {
  let u = @jsjson.units(text)
  for i in 0..<u.length() {
    if boundary(u, i) && at_word(u, i, phrase) && boundary(u, i + phrase.length()) {
      return true
    }
  }
  false
}

///|
/// Into the running turn: it takes the turn over (`steer`).
pub fn AgySession::steer(self : AgySession, text : String) -> Later[Bool] {
  Later::ok(self.driver.lp(), self.acp.prompt_takeover(text))
}

///|
/// Between turns, another model or thinking level set in the running process (`retune`).
pub fn AgySession::retune(self : AgySession, options : JValue) -> Bool {
  let own = self.acp.own
  if own.closed() || own.busy() || own.session_id == "" || self.outlived() {
    return false
  }
  match str_at(Some(options), "skills") {
    Some(dir) =>
      agy_skills(self.driver.m(), str_at(Some(options), "cwd").unwrap_or(""), Some(dir)).on(_ => ())
    None => ()
  }
  let profile = get(Some(options), "profile").unwrap_or(Null)
  let model = match str_at(Some(options), "model") {
    Some(m) => Some(m)
    None => profile_model(profile)
  }
  guard model is Some(model) else { return false }
  guard agy_variant(model, str_at(Some(options), "effort"), self.available_models, self.default_model_id)
    is Some(target) else {
    return false
  }
  if Some(target) != self.current_model_id {
    self.acp.send("session/set_model", obj([("sessionId", s(own.session_id)), ("modelId", s(target))]))
  }
  self.current_model_id = Some(target)
  self.acp.model = Some(agy_base_model(model).0)
  true
}

///|
/// How its process is started for a session (`starting`).
pub fn AgyDriver::starting(self : AgyDriver, options : JValue) -> Later[AcpStart] {
  let m = self.m()
  let o = Some(options)
  let home = profile_home(get(o, "profile").unwrap_or(Null))
  let resumed = str_at(o, "resume")
  match resumed {
    Some(r) if !agy_session_id(r) => return Later::fail(m.lp, Failed("invalid Antigravity conversation id"))
    _ => ()
  }
  let sessions = m.join([agy_home(m, home), agy_sessions])
  m
  .make_dir(sessions)
  .bind(_ => m.make_dir(gemini_dir(m, home)))
  .bind(_ => match resumed {
    Some(r) =>
      m
      .there(m.join([sessions, "\{r}.jsonl"]))
      .map(there => if !there { raise Failed("no Antigravity conversation \{r}") })
    None => done(m.lp)
  })
  .map(_ => {
    command: self.command,
    args: agy_args(m, home),
    env: self.env_for(options),
    meta: None,
    opening: Some(agy_opening(str_at(o, "instructions").unwrap_or(""))),
    initialize_timeout_ms: None,
  })
}

///|
/// One opening, opened again after a wait while its process offers no models (`begin`).
pub fn AgyDriver::begin(
  self : AgyDriver,
  options : JValue,
  events : (JValue) -> Unit,
  probe : Bool,
) -> Later[AgySession] {
  let m = self.m()
  fn attempt(i : Int) -> Later[AgySession] {
    self
    .begin_once(options, events, probe)
    .recover(e => {
      guard e is Failed(msg) &&
        msg == "Antigravity CLI could not load its model catalog: connection failed" &&
        i < agy_catalog_retry_ms.length() else {
        return Later::fail(m.lp, e)
      }
      let wait = agy_catalog_retry_ms[i]
      m.log(
        "warn",
        "agents::agy",
        "its process offered no models (its network not up?); opened again after a wait",
        obj([("key", get(Some(options), "key").unwrap_or(Null)), ("attempt", n(i + 1)), ("waitMs", d(wait))]),
      )
      (self.world.sleep)(wait).bind(_ => attempt(i + 1))
    })
  }

  attempt(0)
}

///|
pub fn AgyDriver::begin_once(
  self : AgyDriver,
  options : JValue,
  events : (JValue) -> Unit,
  probe : Bool,
) -> Later[AgySession] {
  let m = self.m()
  let lp = m.lp
  let o = Some(options)
  let profile = get(o, "profile").unwrap_or(Null)
  let home = profile_home(profile)
  let borrowed = self.borrowed(profile)
  let first = if borrowed {
    self.renew_lent(profile)
  } else if access_kind(profile) == "subscription" {
    self.take_back(home).map(_ => ())
  } else {
    done(lp)
  }
  first
  .bind(_ => if borrowed { agy_expiry(m, home).map(x => Some(x)) } else { Later::ok(lp, None) })
  .bind(until => match str_at(o, "resume") {
    Some(r) => self.ensure_conversation(home, r).map(_ => until)
    None => Later::ok(lp, until)
  })
  .bind(until => {
    let prepared = if !probe {
      self
      .hooks(home)
      .bind(_ => match str_at(o, "skills") {
        Some(dir) => agy_skills(m, str_at(o, "cwd").unwrap_or(""), Some(dir))
        None => done(lp)
      })
    } else {
      done(lp)
    }
    prepared.bind(_ => self.acp_begin(options, events, probe)).map(session => {
      session.sign_in_until = until
      session.sign_in_opened_at = if borrowed { Some(m.now()) } else { None }
      session
    })
  })
}

///|
/// `AcpDriver.begin`: started, initialized, the session opened and ready, or ended.
pub fn AgyDriver::acp_begin(
  self : AgyDriver,
  options : JValue,
  events : (JValue) -> Unit,
  probe : Bool,
) -> Later[AgySession] {
  let m = self.m()
  let lp = m.lp
  let o = Some(options)
  self
  .starting(options)
  .bind(start => {
    let session = self.session(options, events)
    let own = session.acp.own
    own.tools_url = str_at(o, "mcpUrl")
    let key = str_at(o, "key").unwrap_or("")
    self.own
    .start(
      own,
      key,
      str_at(o, "cwd").unwrap_or(""),
      start.command,
      start.args,
      start.env,
      own.hosted_options("agy \{key}", "acp", flavor="agy", kept=true),
    )
    .bind(_ => {
      let meta = match start.meta {
        Some(mt) => obj([("_meta", mt)])
        None => obj([])
      }
      let work = session.acp
        .request(
          acp_init,
          "initialize",
          spread([
            obj([
              ("protocolVersion", n(1)),
              ("clientCapabilities", obj([])),
              ("clientInfo", obj([("name", s("still.fail")), ("version", s("1"))])),
            ]),
            meta,
          ]),
          timeout_ms?=start.initialize_timeout_ms,
        )
        .bind(answer => self.initialized(session, answer, options))
        .bind(_ => {
          let opening = spread([
            obj([
              ("cwd", get(o, "cwd").unwrap_or(Null)),
              (
                "mcpServers",
                if probe {
                  arr([])
                } else {
                  mcp_servers(str_at(o, "mcpUrl").unwrap_or(""), str_at(o, "mcpToken").unwrap_or(""))
                },
              ),
            ]),
            start.opening.unwrap_or(obj([])),
            meta,
          ])
          match str_at(o, "resume") {
            Some(r) => {
              session.acp.named(r)
              session.acp.request(acp_open, "session/load", spread([obj([("sessionId", s(r))]), opening]))
            }
            None =>
              session.acp
              .request(acp_open, "session/new", opening)
              .map(opened => {
                match str_at(get(Some(opened), "result"), "sessionId") {
                  Some(id) if id != "" => {
                    session.acp.named(id)
                    if !probe {
                      session.acp.began(str_at(o, "cwd").unwrap_or(""))
                    }
                  }
                  _ => raise Failed("\{runtime_label("agy")} named no session")
                }
                opened
              })
          }
        })
        .bind(opened => {
          session.acp.opened(get(Some(opened), "result"))
          self.ready(session, options, probe)
        })
        .bind(_ => match own.settled() {
          Some(w) => w
          None => done(lp)
        })
      work
      .map(_ => {
        self.sessions.push(session)
        session
      })
      .recover(e => own.dispose().bind(_ => Later::fail(lp, e)))
    })
  })
}

///|
/// Once initialize is answered: a Gemini key signed in with (`initialized`).
pub fn AgyDriver::initialized(self : AgyDriver, session : AgySession, answer : JValue, options : JValue) -> Later[Unit] {
  let profile = get(Some(options), "profile").unwrap_or(Null)
  let methods = arr_at(get(Some(answer), "result"), "authMethods")
  match methods {
    Some(ms) if access_kind(profile) == "api-provider" &&
      ms.iter().any(x => str_at(Some(x), "id") == Some("gemini-api-key")) =>
      session.acp
      .request("auth:\{(self.ids.next)()}", "authenticate", obj([("methodId", s("gemini-api-key"))]))
      .map(_ => ())
    _ => done(self.lp())
  }
}

///|
/// Once open: its model and thinking level set (`ready`).
pub fn AgyDriver::ready(self : AgyDriver, session : AgySession, options : JValue, probe : Bool) -> Later[Unit] {
  let lp = self.lp()
  if session.available_models.length() == 0 {
    return Later::fail(lp, Failed("Antigravity CLI could not load its model catalog: connection failed"))
  }
  let profile = get(Some(options), "profile").unwrap_or(Null)
  let model = if probe {
    None
  } else {
    match str_at(Some(options), "model") {
      Some(m) => Some(m)
      None => profile_model(profile)
    }
  }
  guard model is Some(model) else { return done(lp) }
  let target = match
    agy_variant(model, str_at(Some(options), "effort"), session.available_models, session.default_model_id) {
    Some(t) => t
    None => model
  }
  let set_ = if Some(target) != session.current_model_id {
    session.acp
    .request(
      "model:\{(self.ids.next)()}",
      "session/set_model",
      obj([("sessionId", s(session.acp.own.session_id)), ("modelId", s(target))]),
    )
    .map(_ => ())
  } else {
    done(lp)
  }
  set_.map(_ => {
    session.current_model_id = Some(target)
    session.acp.model = Some(agy_base_model(model).0)
  })
}

///|
/// Opens a session (`open`).
pub fn AgyDriver::open(self : AgyDriver, options : JValue, events : (JValue) -> Unit) -> Later[AgySession] {
  self.begin(options, events, false)
}

///|
/// The models a profile's CLI offers: a session opened only to ask (`catalog`).
pub fn AgyDriver::catalog(self : AgyDriver, profile : JValue) -> Later[JValue] {
  let m = self.m()
  let options = obj([
    ("key", s("models-\{profile_id(profile)}-\{(self.ids.next)()}")),
    ("profile", profile),
    ("cwd", s(agy_home(m, profile_home(profile)))),
    ("instructions", s("")),
    ("mcpToken", s("")),
    ("mcpUrl", s("")),
    ("route", s("model-discovery")),
  ])
  self
  .begin(options, _ => (), true)
  .bind(session => {
    let catalog = agy_catalog(session.available_models, session.current_model_id)
    let out = match session.tier {
      Some(t) => set(catalog, "tier", s(t))
      None => catalog
    }
    session.acp.own.dispose().map(_ => out)
  })
}

///|
/// Takes up a session whose process a runner kept (`adopt`).
pub fn AgyDriver::adopt(
  self : AgyDriver,
  options : JValue,
  snapshot : JValue?,
  events : (JValue) -> Unit,
) -> Later[AgySession] {
  let m = self.m()
  let lp = m.lp
  let o = Some(options)
  let profile = get(o, "profile").unwrap_or(Null)
  let home = profile_home(profile)
  // (a snapshot's id of "" is one a station before took up without its session: the row's is taken then)
  let id = match str_at(snapshot, "id") {
    Some(i) if i != "" => Some(i)
    _ => str_at(o, "resume")
  }
  let first = match id {
    Some(i) => self.ensure_conversation(home, i)
    None => done(lp)
  }
  let made : Ref[AgySession?] = Ref(None)
  let replaying = match str_at(o, "resume") {
    Some(r) => obj([("resume", s(r))])
    None => obj([])
  }
  let how = {
    handed_over: (h, _) => {
      let x = self.session(options, events)
      x.acp.handed(h)
      if x.acp.own.session_id == "" {
        x.acp.own.session_id = id.unwrap_or("")
      }
      made.val = Some(x)
      x.acp.own
    },
    crashed: (r, _) => {
      let x = self.session(options, events)
      x.acp.model = match str_at(o, "model") {
        Some(mm) => Some(mm)
        None =>
          match profile_model(profile) {
            Some(pm) => Some(pm)
            None => x.acp.model
          }
      }
      x.acp.replayed(r, str_at(o, "resume"))
      x.acp.own.tools_url = crashed_tools_url(o)
      made.val = Some(x)
      Later::ok(lp, x.acp.own)
    },
    hosting_kind: "acp",
    flavor: Some("agy"),
    kept: true,
    replaying,
    label: _ => "agy \{str_at(o, "key").unwrap_or("")}",
    options_of: (x, label) => x.hosted_options(label, "acp", flavor="agy", kept=true),
    adopted: x => match x.settled() {
      Some(w) => w
      None => done(lp)
    },
  }
  first
  .bind(_ => self.own.adopt(str_at(o, "key").unwrap_or(""), snapshot, events, how))
  .bind(_ => {
    let session = made.val.unwrap()
    if !self.borrowed(profile) {
      session.sign_in_until = None
      session.sign_in_opened_at = None
    } else if session.sign_in_until is None {
      session.sign_in_until = Some(0.0)
      session.sign_in_opened_at = None
    } else if session.sign_in_opened_at is None && session.sign_in_until is Some(u) && u > 0.0 {
      session.sign_in_opened_at = Some(u - 3600000.0)
    }
    let checked = if Some(session.acp.own.session_id) != id {
      self
      .ensure_conversation(home, session.acp.own.session_id)
      .recover(e => session.acp.own.dispose().bind(_ => Later::fail(lp, e)))
    } else {
      done(lp)
    }
    checked
    .bind(_ => self.hooks(home))
    .bind(_ => match str_at(o, "skills") {
      Some(dir) => agy_skills(m, str_at(o, "cwd").unwrap_or(""), Some(dir))
      None => done(lp)
    })
    .map(_ => {
      self.sessions.push(session)
      session
    })
  })
}
