// station/src/accounts/profiles.ts: whether a profile works, and what models it offers (the checks, and which access
// kinds a runtime takes). How an access kind reaches its models is agents/profiles.ts's, the providers' list
// agents/providers.ts's: given here (`ProfileDeps`), as what the runtimes' own parts read of a home. The providers'
// addresses can be pointed elsewhere (`Urls`): tests give fake servers.

///|
/// Where the providers are: the real ones unless a test says otherwise.
pub(all) struct Urls {
  opencode : String
  anthropic : String
  chatgpt : String
  claude_token : String
  console : String
}

///|
pub let urls : Urls = {
  opencode: "https://opencode.ai/zen/go",
  anthropic: "https://api.anthropic.com",
  chatgpt: "https://chatgpt.com",
  claude_token: "https://platform.claude.com/v1/oauth/token",
  console: console_url,
}

///|
/// The access kinds each runtime can use, keyed kinds, and runtimes per access kind.
pub using @agent_runtimes {access_kinds, keyed, runtimes_of_kind as runtimes_of}

///|
/// What these checks ask of the station's other parts.
pub(all) struct ProfileDeps {
  commands : Commands
  /// providers.ts `find`: a provider by its id (`name`, `keyOptional`, `sessionHeader` and its addresses).
  find : (String) -> Json?
  /// providers.ts `endpoints`: a provider's addresses (`chat`, `responses`, `anthropic`, `decision`), for one at the
  /// person's own address derived from it and its protocol; none where it is needed and not usable.
  endpoints : (Json, String?, String?) -> Json?
  /// agents/profiles.ts `profileRuntimes`.
  profile_runtimes : (Json, Json?) -> Array[String]
  /// no-keychain.ts `takeBack` and `fileCredentialsSoon`.
  take_back : async (String) -> Unit
  file_credentials : async (Env) -> Unit
  /// machine-logins.ts `linkCodexAuthSoon`.
  link_codex_auth : async (String, Env) -> Unit
  /// machine-logins.ts `parseClaudeCredentials` (its `subscriptionType`, `rateLimitTier`).
  parse_claude_credentials : (String) -> Json?
  /// cursor.ts: the sign-in's key in a home (`apiKey`, `email`), whose it is (`email`), its models.
  read_cursor : async (String) -> Json?
  cursor_me : async (String) -> Json?
  cursor_models : async (String) -> Json
  /// devin.ts `devinCatalog` (`models`, `efforts`, `fusion`).
  devin_catalog : (Json) -> Json raise
  /// agy.ts: the sign-in taken back from the keychain, the email noted, whether it is whole, its plan.
  agy_take_back : async (String) -> Bool
  note_agy_email : async (String, String) -> String?
  agy_token_ready : (String, Bool) -> Bool
  agy_plan_in : (String) -> String?
  /// A new random UUID (`randomUUID`).
  uuid : () -> String
}

///|
/// Whether a profile on this access must have a key: every keyed one but a provider that works without.
pub fn needs_key(deps : ProfileDeps, kind : String, provider : String?) -> Bool {
  keyed(kind) &&
  !(
    kind == "api-provider" &&
    (match provider {
      Some(p) => get((deps.find)(p), "keyOptional") is Some(True)
      None => false
    })
  )
}

///|
/// The runtimes of an access as config.json has it (with its provider and address).
pub fn runtimes_for(deps : ProfileDeps, access : Json, runtime : Json?) -> Array[String] {
  (deps.profile_runtimes)(access, runtime)
}

///|
/// agents/devin.ts `devinData`; agents/agy.ts `agyHome`, `agyToken`, `agyTokenIn`.
pub using @agent_runtimes {devin_data}

///|
pub fn agy_home(home : String) -> String {
  join([home, "agy"])
}

///|
pub fn agy_token_in(gemini : String) -> String {
  join([gemini, "antigravity-cli", "antigravity-oauth-token"])
}

///|
pub fn agy_token(home : String) -> String {
  agy_token_in(join([agy_home(home), ".gemini"]))
}

///|
/// The command to sign a subscription profile in, run on the station's machine.
pub fn login_command(runtime : String, home : String, machine? : Bool = false) -> String {
  if machine {
    return match runtime {
      "claude" => "claude auth login"
      "codex" => "codex login"
      _ => ""
    }
  }
  match runtime {
    "claude" => "CLAUDE_CONFIG_DIR=\{home} claude auth login"
    "codex" => "CODEX_HOME=\{home} codex login"
    "grok" => "GROK_HOME=\{join([home, "grok"])} grok login --device-auth"
    "devin" => "XDG_DATA_HOME=\{devin_data(home)} devin auth login --force-manual-token-flow"
    "agy" => "HOME=\{agy_home(home)} agy"
    _ => ""
  }
}

///|
/// What a check is given: the account and where it lives.
pub(all) struct CheckOptions {
  runtime : String
  kind : String
  key : String
  /// Of an API-provider profile: which provider and where.
  provider : String?
  endpoint : String?
  protocol : String?
  home : String
  /// The station's environment.
  env : Env
  /// On the machine's own login.
  machine : Bool
  /// Its key is a sign-in's token (OpenCode's Console, Kimi).
  login : Bool
  /// The machine login's current token, renewed when about to run out.
  machine_token : (async (Env) -> String)?
  urls : Urls?
  lang : String
  /// Asked again because a runtime on it was refused (Accounts `recheck_profile`): a Claude subscription's login is
  /// renewed even when not due, so a refresh token revoked with its access token still listing models is found over.
  recheck : Bool
}

///|
/// Whether Anthropic's answer refuses a Claude subscription's OAuth token: a revoked one is answered 401 or 403.
pub fn claude_auth_status(status : Int?) -> Bool {
  status == Some(401) || status == Some(403)
}

///|
/// Whether a profile works, and what models it offers (the same JSON). `checkedAt`: stamped by whoever keeps it.
fn check(state : String, detail : String, models : Array[String]?) -> Map[String, Json] {
  {
    "state": Json::string(state),
    "detail": Json::string(detail),
    "models": match models {
      Some(m) => jstrings(m)
      None => Json::null()
    },
    "checkedAt": Json::number(0.0),
  }
}

///|
async fn profile_get(io : Io, url : String, headers : Array[(String, String)]) -> Response {
  (io.fetch)({ url, method_: "GET", headers, body: None, timeout_ms: 15_000, manual: false })
}

///|
/// The ids of a `/v1/models` answer.
fn model_ids(response : Response) -> Array[String] raise JsonError {
  let body = parse_json(response.body)
  match get(Some(body), "data") {
    Some(Array(a)) => a.filter_map(m => str_of(get(Some(m), "id")))
    _ => []
  }
}

///|
/// Runs a runtime's own status command, in `env` only; what it said and how it ended.
async fn status_of(deps : ProfileDeps, command : String, args : Array[String], env : Env) -> (Int?, String, String) {
  match (deps.commands.run)(command, args, env, 20_000) {
    NotFound(m) => raise Failed("\{command}: \{m}")
    TimedOut => raise Failed("\{command} \{args.join(" ")} timed out")
    Ended(code, out, err) => (code, out, err)
  }
}

///|
/// Asks the provider or runtime whether this profile works, and what models it offers. Never fails: what went wrong
/// is a failed check.
pub async fn check_profile(io : Io, deps : ProfileDeps, auth : ClaudeAuth, words : Words, o : CheckOptions) -> Json {
  let lang = o.lang
  let got = check_inner(io, deps, auth, words, o, lang) catch {
    // A login that can no longer be renewed is over: signed in again.
    RenewRefused(_, m) => check("login", m, None)
    e => check("failed", tr(words, lang, "station.profile.checkError", [("error", message_of(e))]), None)
  }
  Json::object(got)
}

///|
fn joined(words : Words, lang : String, parts : Array[String]) -> String {
  parts.filter(s => s != "").join(tr(words, lang, "station.list.comma", []))
}

///|
async fn check_inner(
  io : Io,
  deps : ProfileDeps,
  auth : ClaudeAuth,
  words : Words,
  o : CheckOptions,
  lang : String,
) -> Map[String, Json] {
  let at = o.urls.unwrap_or(urls)
  let t = (key : String, args : Array[(String, String)]) => tr(words, lang, key, args)
  if o.kind == "opencode-go" {
    // The model list answers any key; the usage is the key's own, so it is what tells a key that works.
    let usage = profile_get(io, "\{at.opencode}/v1/usage", [("authorization", "Bearer \{o.key}")])
    // A sign-in refused is one to sign in again (the account's own key would not be).
    if o.login && (usage.status == 401 || usage.status == 403) {
      return check("login", t("station.profile.consoleSignedOut", []), None)
    }
    if !usage.ok() {
      return check("failed", t("station.profile.keyRefused", [("provider", "OpenCode Go"), ("status", usage.status.to_string())]), None)
    }
    let response = profile_get(io, "\{at.opencode}/v1/models", [("authorization", "Bearer \{o.key}")])
    if !response.ok() {
      return check("failed", t("station.profile.modelsUnreadable", [("provider", "OpenCode Go"), ("status", response.status.to_string())]), None)
    }
    let models = sort_units(model_ids(response))
    return check("ok", t("station.profile.works", [("n", models.length().to_string())]), Some(models))
  }
  if o.kind == "anthropic-api" {
    let response = profile_get(io, "\{at.anthropic}/v1/models?limit=100", [
      ("x-api-key", o.key),
      ("anthropic-version", "2023-06-01"),
    ])
    if !response.ok() {
      return check("failed", t("station.profile.keyRefused", [("provider", "Anthropic"), ("status", response.status.to_string())]), None)
    }
    let models = model_ids(response)
    return check("ok", t("station.profile.works", [("n", models.length().to_string())]), Some(models))
  }
  if o.kind == "api-provider" {
    let source = match o.provider {
      Some(p) => (deps.find)(p)
      None => None
    }
    guard source is Some(src) else { return check("failed", t("station.profile.unknownProvider", []), None) }
    guard (deps.endpoints)(src, o.endpoint, o.protocol) is Some(ends) else {
      return check("failed", t("station.profile.addressNeeded", []), None)
    }
    // Signed in to Kimi: a sign-in no longer renewed, or a token refused, is one to sign in again.
    if o.login && o.key == "" {
      return check("login", t("station.profile.kimiSignedOut", []), None)
    }
    let done = check_api(io, deps, words, src, ends, o.key, lang)
    if o.login && done.get("state") is Some(String("failed")) {
      return check("login", t("station.profile.kimiSignedOut", []), None)
    }
    return done
  }
  if o.kind == "subscription" && o.runtime == "claude" {
    let env = o.env.copy()
    env["CLAUDE_CONFIG_DIR"] = o.home
    let mut machine_token : String? = None
    if o.machine {
      guard o.machine_token is Some(give) else {
        raise Failed("the machine's Claude Code login could not be read")
      }
      let token = give(o.env)
      machine_token = Some(token)
      env["CLAUDE_CODE_OAUTH_TOKEN"] = token
    } else {
      (deps.take_back)(o.home)
      (deps.file_credentials)(env)
    }
    let (code, stdout, stderr) = status_of(deps, "claude", ["auth", "status"], env)
    // Signed out, it says so and exits 1: its answer is still the JSON on stdout.
    if code != Some(0) && !(code == Some(1) && trim_start(stdout).has_prefix("{")) {
      raise Failed("Command failed: claude auth status\n\{stderr}")
    }
    let status = parse_json(stdout)
    if !(get(Some(status), "loggedIn") is Some(True)) {
      return check("login", t("station.profile.signedOut", []), None)
    }
    // What the subscription runs, as Anthropic lists it for the account's own token.
    let (token, renew_error) = match machine_token {
      Some(tk) => (Some(tk), None)
      None => profile_token(io, auth, o, at, lang)
    }
    let (first_models, models_status) = match token {
      None => (None, None)
      Some(tk) => claude_models(io, at, tk)
    }
    let mut models = first_models
    // (its login renewed against the token just refused: a refresh token refused too is a login over)
    let renew = async fn(tk : String) -> String raise {
      auth.token(o.env, if o.machine { None } else { Some(o.home) }, Some(tk), at.claude_token, lang).0
    }
    let mut renewed_here = false
    match renew_error {
      Some(err) =>
        if models is None {
          return check("failed", err, None)
        }
      None =>
        if claude_auth_status(models_status) {
          if token is Some(tk) {
            let renewed = renew(tk) catch {
              RenewRefused(_, _) as e => raise e
              e => return check("failed", message_of(e), None)
            }
            renewed_here = true
            let (retry_models, retry_status) = claude_models(io, at, renewed)
            if claude_auth_status(retry_status) {
              return check("login", t("station.quota.signInExpired", []), None)
            }
            models = retry_models
          }
        }
    }
    // Asked again after a runtime on it was refused: Anthropic can go on listing models for an access token whose login
    // was revoked (FB-44), so its refresh token is what is asked. One refused is over; one not reached now leaves a
    // listing that worked standing, and one that did not a failed check.
    if o.recheck && !renewed_here && renew_error is None && token is Some(tk) {
      let renewed : String? = try {
        Some(renew(tk))
      } catch {
        RenewRefused(status, _) =>
          // (none to renew with: a token that still lists models is not taken for one revoked)
          if !(status is None && models_status == Some(200)) {
            return check("login", t("station.quota.signInExpired", []), None)
          } else {
            None
          }
        e =>
          if models_status != Some(200) {
            return check("failed", message_of(e), None)
          } else {
            None
          }
      }
      if renewed is Some(r) && models is None {
        let (retry_models, retry_status) = claude_models(io, at, r)
        if claude_auth_status(retry_status) {
          return check("login", t("station.quota.signInExpired", []), None)
        }
        models = retry_models
      }
    }
    // For a profile in its own home Claude keeps the more specific tier beside its token.
    let credentials = if o.machine {
      None
    } else {
      let text = (io.read)(join([o.home, ".credentials.json"])) catch { _ => "" }
      if text == "" {
        None
      } else {
        (deps.parse_claude_credentials)(text)
      }
    }
    let plan = claude_plan(
      either(get(Some(status), "subscriptionType"), get(credentials, "subscriptionType")),
      either(get(Some(status), "rateLimitTier"), get(credentials, "rateLimitTier")),
    )
    let detail = joined(words, lang, [
      t("station.profile.signedIn", []),
      str_of(get(Some(status), "email")).unwrap_or(""),
      plan.unwrap_or(""),
    ])
    let result = check("ok", detail, models)
    if plan is Some(p) {
      result["plan"] = Json::string(p)
    }
    return result
  }
  if o.kind == "subscription" && o.runtime == "codex" {
    if o.machine {
      (deps.link_codex_auth)(o.home, o.env)
    }
    let env = o.env.copy()
    env["CODEX_HOME"] = o.home
    let (code, stdout, stderr) = status_of(deps, "codex", ["login", "status"], env)
    let text = trim(stdout + stderr)
    if includes(lower(text), "not logged in") {
      return check("login", t("station.profile.signedOut", []), None)
    }
    if code != Some(0) {
      raise Failed("Command failed: codex login status\n\{text}")
    }
    let first = split(text, "\n")[0]
    let result = check("ok", if first != "" { first } else { t("station.profile.signedIn", []) }, None)
    let plan = get(get(codex_claims_soon(io, o.home), "https://api.openai.com/auth"), "chatgpt_plan_type")
    if str_of(plan) is Some(p) && trim(p) != "" {
      result["plan"] = Json::string(trim(p))
    }
    return result
  }
  if o.kind == "subscription" && o.runtime == "grok" {
    // `grok models` says whether it is signed in, and the account's models (* the default, - the rest).
    let env = o.env.copy()
    env["GROK_HOME"] = join([o.home, "grok"])
    env["GROK_DISABLE_AUTOUPDATER"] = "1"
    let (code, stdout, stderr) = status_of(deps, "grok", ["models"], env)
    let text = stdout + stderr
    let low = lower(text)
    if includes(low, "not authenticated") || includes(low, "not logged in") || includes(low, "sign in") {
      return check("login", t("station.profile.signedOut", []), None)
    }
    if code != Some(0) {
      raise Failed("Command failed: grok models\n\{trim(text)}")
    }
    let models = grok_models(text)
    let email = grok_email(io, o.home)
    return check(
      "ok",
      joined(words, lang, [t("station.profile.signedIn", []), email.unwrap_or("")]),
      if models.length() > 0 { Some(models) } else { None },
    )
  }
  if o.kind == "subscription" && o.runtime == "cursor" {
    // The key the sign-in minted, asked of Cursor's API: whose it is, and the models it may run.
    guard (deps.read_cursor)(o.home) is Some(login) else {
      return check("login", t("station.profile.signedOut", []), None)
    }
    let key = str_of(get(Some(login), "apiKey")).unwrap_or("")
    guard (deps.cursor_me)(key) is Some(me) else {
      return check("login", t("station.profile.cursorKeyRevoked", []), None)
    }
    let models = (deps.cursor_models)(key)
    let email = match str_of(get(Some(me), "email")) {
      Some(e) => e
      None => str_of(get(Some(login), "email")).unwrap_or("")
    }
    let result = check("ok", joined(words, lang, [t("station.profile.signedIn", []), email]), None)
    result["models"] = models
    return result
  }
  if o.kind == "subscription" && o.runtime == "devin" {
    // `devin auth status` in the profile's data directory says whether it is signed in, and as whom; `devin models
    // list` the account's models, a family at its thinking levels each.
    let env = o.env.copy()
    env["XDG_DATA_HOME"] = devin_data(o.home)
    let (code, stdout, stderr) = status_of(deps, "devin", ["auth", "status"], env)
    let text = stdout + stderr
    if includes(lower(text), "not logged in") {
      return check("login", t("station.profile.signedOut", []), None)
    }
    if code != Some(0) {
      raise Failed("Command failed: devin auth status\n\{trim(text)}")
    }
    let (_, listed, _) = status_of(deps, "devin", ["models", "list", "--format", "json"], env)
    let catalog = try Some((deps.devin_catalog)(parse_json(listed))) catch { _ => None }
    let email = devin_email_in(text)
    // Noted for what names the account without asking Devin (devinEmail).
    if email is Some(e) {
      try {
        (io.mkdir)(join([o.home, "devin"]), true)
        (io.write)(devin_account_file(o.home), stringify({ "email": Json::string(e) }) + "\n")
      } catch {
        _ => ()
      }
    }
    let listed_models = match get(catalog, "models") {
      Some(Array(a)) if a.length() > 0 => Some(strings_of(Some(Json::array(a))))
      _ => None
    }
    let done = check("ok", joined(words, lang, [t("station.profile.signedIn", []), email.unwrap_or("")]), listed_models)
    if catalog is Some(c) {
      done["modelEfforts"] = { "devin": get(Some(c), "efforts").unwrap_or(Json::null()) }
      match get(Some(c), "fusion") {
        None | Some(Null) => ()
        Some(f) => done["fusion"] = f
      }
    }
    return done
  }
  if o.kind == "subscription" && o.runtime == "agy" {
    // Signed in when its sign-in's file is in the profile's, taken back from the macOS keychain where `agy` had moved
    // it; whether it works, and its models, a session opened only to ask says.
    if !(deps.agy_take_back)(o.home) {
      return check("login", t("station.profile.signedOut", []), None)
    }
    let (text, email) = try {
      let text = (io.read)(agy_token(o.home))
      (text, (deps.note_agy_email)(o.home, text))
    } catch {
      _ => return check("login", t("station.profile.signedOut", []), None)
    }
    // A company's account whose licence or project was never given is signed out to `agy`.
    if !(deps.agy_token_ready)(text, false) {
      return check("login", t("station.profile.signedOut", []), None)
    }
    let plan = (deps.agy_plan_in)(text)
    let result = check("ok", joined(words, lang, [t("station.profile.signedIn", []), email.unwrap_or("")]), None)
    if plan is Some(p) {
      result["plan"] = Json::string(p)
    }
    return result
  }
  check("unknown", t("station.profile.envUnchecked", []), None)
}

///|
/// The account `devin auth status` says it is signed in as (its `Email:` line: /^\s*Email:\s*(\S+@\S+)\s*$/m).
pub fn devin_email_in(text : String) -> String? {
  let n = text.length()
  let line_end = (c : Int) => c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029
  for p in 0..=n {
    if p > 0 && !line_end(text.unsafe_charcode_at(p - 1)) {
      continue
    }
    let mut i = p
    while i < n && is_space(text.unsafe_charcode_at(i)) {
      i += 1
    }
    if !(i + 6 <= n && sub(text, i, i + 6) == "Email:") {
      continue
    }
    i += 6
    while i < n && is_space(text.unsafe_charcode_at(i)) {
      i += 1
    }
    let start = i
    while i < n && !is_space(text.unsafe_charcode_at(i)) {
      i += 1
    }
    let token = sub(text, start, i)
    let mut has_at = false
    for k in 1..<(token.length() - 1) {
      if token.unsafe_charcode_at(k) == '@' {
        has_at = true
      }
    }
    if !has_at {
      continue
    }
    let mut j = i
    let mut ends = j >= n
    while j < n && is_space(text.unsafe_charcode_at(j)) {
      if line_end(text.unsafe_charcode_at(j)) {
        ends = true
        break
      }
      j += 1
    }
    if j >= n {
      ends = true
    }
    if ends {
      return Some(token)
    }
  }
  None
}

///|
/// Whose Devin account a profile signed in to: the email the station noted when it was last checked.
pub async fn devin_email(io : Io, home : String) -> String? {
  let text = (io.read)(devin_account_file(home)) catch { _ => return None }
  devin_noted_in(text) catch { _ => None }
}

///|
pub fn devin_account_file(home : String) -> String {
  join([home, "devin", "account.json"])
}

///|
pub fn devin_noted_in(text : String) -> String? raise JsonError {
  text_of(get(Some(parse_json(text)), "email"))
}

///|
/// The models `grok models` lists: a line each, `* id (default)` or `- id`.
pub fn grok_models(text : String) -> Array[String] {
  let out = []
  for line in split(text, "\n") {
    let n = line.length()
    let mut i = 0
    while i < n && is_space(line.unsafe_charcode_at(i)) {
      i += 1
    }
    if i >= n {
      continue
    }
    let c = line.unsafe_charcode_at(i)
    if c != '*' && c != '-' {
      continue
    }
    i += 1
    let gap = i
    while i < n && is_space(line.unsafe_charcode_at(i)) {
      i += 1
    }
    if i == gap {
      continue
    }
    let start = i
    while i < n && !is_space(line.unsafe_charcode_at(i)) {
      i += 1
    }
    if i > start {
      out.push(sub(line, start, i))
    }
  }
  out
}

///|
/// Whose account Grok Build is signed in with, as its auth.json says.
pub async fn grok_email(io : Io, home : String) -> String? {
  let text = (io.read)(grok_auth_file(home)) catch { _ => return None }
  grok_email_in(text) catch { _ => None }
}

///|
pub fn grok_auth_file(home : String) -> String {
  join([home, "grok", "auth.json"])
}

///|
pub fn grok_email_in(text : String) -> String? raise JsonError {
  let auth = parse_json(text)
  let values : Array[Json] = match auth {
    Object(m) => m.values().collect()
    Array(a) => a
    String(s) => points(s).map(Json::string)
    _ => []
  }
  for entry in values {
    if text_of(get(Some(entry), "email")) is Some(e) {
      return Some(e)
    }
  }
  None
}

///|
/// A Claude profile's token as it signs in now, renewed first when due: a login that can no longer be renewed fails
/// (to sign in again); one not renewed now for another reason is the one kept.
async fn profile_token(io : Io, auth : ClaudeAuth, o : CheckOptions, at : Urls, lang : String) -> (String?, String?) {
  let got = auth.token(o.env, Some(o.home), None, at.claude_token, lang) catch {
    RenewRefused(_, _) as e => raise e
    e => return (claude_token(io, o.home), Some(message_of(e)))
  }
  (Some(got.0), None)
}

///|
/// The models a Claude subscription's OAuth token may use; none when Anthropic does not say.
async fn claude_models(io : Io, at : Urls, token : String) -> (Array[String]?, Int?) {
  try {
    let response = profile_get(io, "\{at.anthropic}/v1/models?limit=100", [
      ("authorization", "Bearer \{token}"),
      ("anthropic-version", "2023-06-01"),
      ("anthropic-beta", "oauth-2025-04-20"),
    ])
    if response.ok() {
      (Some(model_ids(response)), Some(response.status))
    } else {
      (None, Some(response.status))
    }
  } catch {
    _ => (None, None)
  }
}

///|
/// The header OpenCode's gateways ask of every request: any id will do.
pub fn opencode_session(deps : ProfileDeps) -> (String, String) {
  ("x-opencode-session", (deps.uuid)())
}

///|
/// A provider's key, asked by its model list: a refusal (401/403) is a key that does not work; a provider with no list
/// is not held against it, its key is only unchecked.
async fn check_api(
  io : Io,
  deps : ProfileDeps,
  words : Words,
  source : Json,
  ends : Json,
  key : String,
  lang : String,
) -> Map[String, Json] {
  let t = (k : String, args : Array[(String, String)]) => tr(words, lang, k, args)
  let name = js_string(get(Some(source), "name"))
  let e = (k : String) => match get(Some(ends), k) {
    Some(String(s)) => Some(s)
    _ => None
  }
  // A decision-only provider has no model list and nothing to name: its key is tried by the decision probe.
  if e("decision") is Some(_) && e("chat") is None && e("responses") is None && e("anthropic") is None {
    return check("ok", t("station.profile.decisionOnly", [("provider", name)]), None)
  }
  let base = match (e("chat"), e("responses"), e("anthropic")) {
    (Some(c), _, _) => Some(c)
    (None, Some(r), _) => Some(r)
    (None, None, Some(a)) => Some("\{a}/v1")
    _ => None
  }
  guard base is Some(b) else { return check("failed", t("station.profile.addressNeeded", []), None) }
  let anthropic_only = e("chat") is None && e("responses") is None
  let headers : Array[(String, String)] = []
  if key != "" {
    headers.push(("authorization", "Bearer \{key}"))
  }
  if anthropic_only {
    headers.push(("x-api-key", key))
    headers.push(("anthropic-version", "2023-06-01"))
  }
  match get(Some(source), "sessionHeader") {
    None | Some(Null) | Some(False) => ()
    Some(String("")) => ()
    _ => headers.push(opencode_session(deps))
  }
  let response = profile_get(io, "\{b}/models", headers)
  if response.status == 401 || response.status == 403 {
    return check("failed", t("station.profile.keyRefused", [("provider", name), ("status", response.status.to_string())]), None)
  }
  if !response.ok() {
    return check("unknown", t("station.profile.noModelList", [("provider", name)]), None)
  }
  // A `:batch` entry (OpenRouter's) is served by the provider's Batch API alone.
  let models = sort_units(model_ids(response).filter(id => !id.has_suffix(":batch")))
  check("ok", t("station.profile.works", [("n", models.length().to_string())]), Some(models))
}
