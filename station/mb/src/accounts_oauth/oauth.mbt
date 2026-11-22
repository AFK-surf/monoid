// station/src/accounts/oauth.ts: renewing a Claude login without sending a prompt: under Claude Code's own locks (its
// current one in the config directory and its legacy one beside it), read again once locked, and saved back where it
// was (the keychain for the machine's login on macOS, else the file), never as a copy. Used for the machine profile's
// and a local subscription profile's token, for checking a profile and for reading a subscription's allowance. A login
// that can no longer be renewed (none to renew it with, or its refresh token refused) is over: RenewRefused.

///|
let claude_client_id : String = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

///|
let keychain_item : String = "Claude Code-credentials"

///|
let margin_ms : Int64 = 300_000L

///|
let lock_wait_ms : Int64 = 40_000L

///|
let lock_stale_ms : Int64 = 60_000L

///|
let heartbeat_ms : Int64 = 5_000L

///|
/// How long a lend to another station waits for its login's renewal before the token it has is lent (still lasting the
/// usual margin), its renewal going on behind.
pub let lend_bound_ms : Int64 = 10_000L

///|
/// What the keychain says of the machine's Claude login (machine-logins.ts `readClaudeKeychain`).
pub(all) enum KeychainRead {
  KeychainFound(String)
  KeychainMissing
  KeychainUnreadable
}

///|
/// How `security -i` ended: its code (none: a signal), not started, or killed at its deadline.
pub(all) enum SecurityEnd {
  SecurityExited(Int?)
  SecurityUnstarted
  SecurityTimedOut
}

///|
/// The machine's logins and the platform, as Claude's renewal asks them.
pub(all) struct ClaudeStore {
  /// macOS: the machine's login is in the keychain first.
  has_keychain : Bool
  read_keychain : async (Env) -> KeychainRead
  /// no-keychain.ts `takeBackMissing`: a profile's login the keychain took, put back in its file.
  take_back_missing : async (String) -> Bool
  /// platform `home`.
  home_of : (Env) -> String?
  /// `/usr/bin/id -un` in the station's environment: whether it ended well and what it said; none where it could not
  /// be run.
  user_name : async () -> (Bool, String)?
  /// `security -i` in `env`, given its commands on stdin, given `ms`.
  security : async (Env, String, Int) -> SecurityEnd
}

///|
/// A login's credentials as read, and where from.
priv struct Credentials {
  data : Json
  keychain : Bool
}

///|
/// The OAuth access token Claude Code keeps in this config directory's file.
pub async fn claude_token(io : Io, home : String) -> String? {
  let text = (io.read)(join([home, ".credentials.json"])) catch { _ => return None }
  let j = parse_or_none(text)
  text_of(get(get(j, "claudeAiOauth"), "accessToken"))
}

///|
fn access_of(words : Words, c : Credentials, lang : String) -> (String, Int64) raise Said {
  let oauth = get(Some(c.data), "claudeAiOauth")
  guard text_of(get(oauth, "accessToken")) is Some(token) else {
    raise Said(tr(words, lang, "station.claudeAuth.noCredentials", []))
  }
  let expires = get(oauth, "expiresAt")
  (token, if is_integer(expires) { num_of(expires).unwrap().to_int64() } else { 0L })
}

///|
fn usable(io : Io, words : Words, c : Credentials, rejected : String?, lang : String, margin : Int64) -> Bool {
  let (token, expires) = access_of(words, c, lang) catch { _ => return false }
  rejected != Some(token) && (expires == 0L || expires - (io.wall)() > margin)
}

///|
/// Claude's renewals: the logins being renewed for a lend, one a login (what is asked meanwhile waits on the same).
pub struct ClaudeAuth {
  priv io : Io
  priv store : ClaudeStore
  priv words : Words
  priv renewing : Map[String, @effect.Deferred[(String, Int64)?]]
}

///|
pub fn ClaudeAuth::new(io : Io, store : ClaudeStore, words : Words) -> ClaudeAuth {
  { io, store, words, renewing: {} }
}

///|
async fn ClaudeAuth::read(self : ClaudeAuth, env : Env, home : String, machine : Bool, lang : String) -> Credentials {
  let t = (key : String) => tr(self.words, lang, key, [])
  if machine && self.store.has_keychain {
    match (self.store.read_keychain)(env) {
      KeychainUnreadable => raise Said(t("station.claudeAuth.keychainUnreadable"))
      // An unreadable keychain entry must not be replaced with a stale file's login.
      KeychainFound(text) =>
        return { data: parse_json(text) catch { _ => raise Said(t("station.claudeAuth.keychainUnreadable")) }, keychain: true }
      KeychainMissing => ()
    }
  }
  let file = join([home, ".credentials.json"])
  let text = (self.io.read)(file) catch {
    e =>
      if !machine && code_of(e) == "ENOENT" && (self.store.take_back_missing)(home) {
        (self.io.read)(file) catch { _ => raise Said(t("station.claudeAuth.noCredentials")) }
      } else {
        raise Said(t("station.claudeAuth.noCredentials"))
      }
  }
  { data: parse_json(text) catch { _ => raise Said(t("station.claudeAuth.credentialsUnreadable")) }, keychain: false }
}

///|
async fn ClaudeAuth::save(self : ClaudeAuth, env : Env, home : String, c : Credentials, lang : String) -> Unit {
  let t = (key : String) => tr(self.words, lang, key, [])
  if !c.keychain {
    (self.io.write_private)(join([home, ".credentials.json"]), stringify(c.data)) catch {
      _ => raise Said(t("station.claudeAuth.saveFailed"))
    }
    return
  }
  // Secrets kept off argv, as Claude Code does: `security -i` reads its commands from stdin.
  let who = (self.store.user_name)()
  let account = match who {
    Some((_, out)) => trim(out)
    None => ""
  }
  let bad = includes(account, "\"") || includes(account, "\\") || includes(account, "\n") || includes(account, "\r")
  if !(who is Some((true, _))) || account == "" || bad {
    raise Said(t("station.claudeAuth.keychainAccount"))
  }
  let input = "add-generic-password -U -a \"\{account}\" -s \"\{keychain_item}\" -X \"\{hex_utf8(stringify(c.data))}\"\n"
  match (self.store.security)(env, input, 10_000) {
    SecurityExited(Some(0)) => ()
    SecurityExited(_) => raise Said(t("station.claudeAuth.keychainSaveFailed"))
    SecurityUnstarted => raise Said(t("station.claudeAuth.keychainWrite"))
    SecurityTimedOut => raise Said(t("station.claudeAuth.keychainTimeout"))
  }
}

///|
/// How long a lend waits for its login's renewal, on whose clock (`after`: `f` once `ms` from now, called off by what
/// it gives).
pub(all) struct Bound {
  ms : Int64
  after : (Int64, () -> Unit) -> () -> Unit
}

///|
/// A current access token and when it runs out: the one kept, unless it is about to run out or is `rejected` (a 401
/// said so); then renewed. `home`: a profile's config directory; none: the machine's own login (~/.claude, and on macOS
/// the keychain first). `margin`: how long the token given must still last. `bound` (a token lent to another station):
/// the renewal of one that still lasts the usual margin is waited for `bound.ms` at most, then the token it has is
/// given and the renewal goes on behind.
pub async fn ClaudeAuth::token(
  self : ClaudeAuth,
  env : Env,
  home : String?,
  rejected : String?,
  endpoint : String,
  lang : String,
  margin? : Int64 = margin_ms,
  bound? : Bound,
  claude_version? : String,
) -> (String, Int64) {
  let machine = home is None
  let dir = match home {
    Some(h) => h
    None => join([(self.store.home_of)(env).unwrap_or("."), ".claude"])
  }
  let initial = self.read(env, dir, machine, lang)
  if usable(self.io, self.words, initial, rejected, lang, margin) {
    return access_of(self.words, initial, lang)
  }
  if bound is Some(b) && margin > margin_ms && usable(self.io, self.words, initial, rejected, lang, margin_ms) {
    let given = access_of(self.words, initial, lang)
    let renewed = self.renewal(dir, given, async fn() {
      self.renew_locked(env, dir, machine, rejected, endpoint, lang, margin, claude_version?)
    })
    let out : @effect.Deferred[(String, Int64)] = @effect.Deferred::new()
    let began = (self.io.wall)()
    let over = Ref(false)
    let stop = (b.after)(b.ms, () => {
      over.val = true
      (self.io.log)(
        "warn",
        "accounts",
        "a Claude login's renewal outlasted the lend's bound; the token it has was lent, the renewal goes on",
        { "login": Json::string(dir), "ms": jnum((self.io.wall)() - began), "lastsMin": lasts_min(self.io, given.1) },
      )
      ignore(out.succeed(given))
    })
    (self.io.spawn)(async fn() {
      let got = renewed.wait() catch { _ => None }
      if over.val {
        return
      }
      stop()
      ignore(out.succeed(got.unwrap_or(given)))
    })
    return out.wait()
  }
  let began = (self.io.wall)()
  let got = self.renew_locked(env, dir, machine, rejected, endpoint, lang, margin, claude_version?) catch {
    error => {
      // Renewed early and it could not be: the token is still given while it lasts the usual margin.
      if margin > margin_ms {
        let latest = self.read(env, dir, machine, lang)
        if usable(self.io, self.words, latest, rejected, lang, margin_ms) {
          let given = access_of(self.words, latest, lang)
          self.not_renewed(dir, began, given.1, message_of(error))
          return given
        }
      }
      raise error
    }
  }
  // (its provider refused it for now, the token it has given while it lasts the usual margin: renew's own way)
  if margin > margin_ms && !usable_for(self.io, got, margin) {
    self.not_renewed(dir, began, got.1, "its provider did not renew it")
  }
  got
}

///|
/// The renewal of a lent login, one a login: what it renewed, or none where it did not (said: `not_renewed`).
fn ClaudeAuth::renewal(
  self : ClaudeAuth,
  dir : String,
  given : (String, Int64),
  renew : async () -> (String, Int64),
) -> @effect.Deferred[(String, Int64)?] {
  if self.renewing.get(dir) is Some(going) {
    return going
  }
  let began = (self.io.wall)()
  let done : @effect.Deferred[(String, Int64)?] = @effect.Deferred::new()
  self.renewing[dir] = done
  (self.io.spawn)(async fn() {
    let result = try {
      let got = renew()
      if got.0 != given.0 {
        Some(got)
      } else {
        self.not_renewed(dir, began, given.1, "its provider did not renew it")
        None
      }
    } catch {
      error => {
        self.not_renewed(dir, began, given.1, message_of(error))
        None
      }
    }
    self.renewing.remove(dir)
    ignore(done.succeed(result))
  })
  done
}

///|
/// Once the renewal of a lent login at `dir` going on, if any, is over (tests).
pub async fn ClaudeAuth::renewed_behind(self : ClaudeAuth, dir : String) -> Unit {
  if self.renewing.get(dir) is Some(d) {
    ignore(d.wait())
  }
}

///|
/// Whether a token given lasts `margin` more (one that says no end does).
fn usable_for(io : Io, got : (String, Int64), margin : Int64) -> Bool {
  got.1 == 0L || got.1 - (io.wall)() > margin
}

///|
fn lasts_min(io : Io, expires_at : Int64) -> Json {
  if expires_at == 0L {
    Json::null()
  } else {
    Json::number(js_round((expires_at - (io.wall)()).to_double() / 60_000.0))
  }
}

///|
/// Said, as nothing else says it: which login, how long its renewal took, how long the token given instead still lasts.
fn ClaudeAuth::not_renewed(self : ClaudeAuth, dir : String, began : Int64, expires_at : Int64, error : String) -> Unit {
  (self.io.log)("warn", "accounts", "a Claude login was not renewed early; the token it has was given meanwhile", {
    "login": Json::string(dir),
    "ms": jnum((self.io.wall)() - began),
    "lastsMin": lasts_min(self.io, expires_at),
    "error": Json::string(error),
  })
}

///|
async fn ClaudeAuth::renew_locked(
  self : ClaudeAuth,
  env : Env,
  dir : String,
  machine : Bool,
  rejected : String?,
  endpoint : String,
  lang : String,
  margin : Int64,
  claude_version? : String,
) -> (String, Int64) {
  (self.io.mkdir)(dir, true)
  let current = RefreshLock::acquire(self.io, self.words, join([dir, ".oauth_refresh.lock"]), lang)
  let result = try {
    let legacy = RefreshLock::acquire(self.io, self.words, (self.io.realpath)(dir) + ".lock", lang)
    let got = try {
      self.renew(env, dir, machine, rejected, endpoint, lang, margin, claude_version?)
    } catch {
      e => {
        legacy.release()
        raise e
      }
    }
    legacy.release()
    got
  } catch {
    e => {
      current.release()
      raise e
    }
  }
  current.release()
  result
}

///|
async fn ClaudeAuth::renew(
  self : ClaudeAuth,
  env : Env,
  home : String,
  machine : Bool,
  rejected : String?,
  endpoint : String,
  lang : String,
  margin : Int64,
  claude_version? : String,
) -> (String, Int64) {
  let t = (key : String, args : Array[(String, String)]) => tr(self.words, lang, key, args)
  let credentials = self.read(env, home, machine, lang)
  if usable(self.io, self.words, credentials, rejected, lang, margin) {
    return access_of(self.words, credentials, lang)
  }
  let oauth = match get(Some(credentials.data), "claudeAiOauth") {
    None | Some(Null) => Json::object({})
    Some(o) => o
  }
  guard text_of(get(Some(oauth), "refreshToken")) is Some(refresh) else {
    raise RenewRefused(None, t("station.claudeAuth.expiredNoRefresh", []))
  }
  let body : Map[String, Json] = {
    "grant_type": "refresh_token",
    "refresh_token": Json::string(refresh),
    "client_id": Json::string(text_of(get(Some(oauth), "clientId")).unwrap_or(claude_client_id)),
  }
  if get(Some(oauth), "scopes") is Some(Array(_)) {
    let scopes = strings_of(get(Some(oauth), "scopes"))
    if scopes.length() > 0 {
      body["scope"] = Json::string(scopes.join(" "))
    }
  }
  let headers : Array[(String, String)] = [("content-type", "application/json")]
  match claude_version {
    Some(v) if v != "" => headers.push(("user-agent", "claude-cli/\{v} (external, cli)"))
    _ => ()
  }
  let response = (self.io.fetch)({
    url: endpoint,
    method_: "POST",
    headers,
    body: Some(stringify(Json::object(body))),
    timeout_ms: 30_000,
    manual: true,
  }) catch {
    _ => raise Said(t("station.claudeAuth.refreshFailed", []))
  }
  if !response.ok() {
    // A CLI version using different locks may have won: its credentials are never erased or rolled back.
    let latest = self.read(env, home, machine, lang)
    if usable(self.io, self.words, latest, rejected, lang, margin_ms) {
      return access_of(self.words, latest, lang)
    }
    let status = response.status
    if status == 400 || status == 401 {
      raise RenewRefused(Some(status), t("station.claudeAuth.refreshRefused", [("status", status.to_string())]))
    }
    raise Said(t("station.claudeAuth.refreshUnavailable", [("status", status.to_string())]))
  }
  let answer = parse_json(response.body) catch { _ => raise Said(t("station.claudeAuth.badResponse", [])) }
  guard text_of(get(Some(answer), "access_token")) is Some(token) else {
    raise Said(t("station.claudeAuth.noAccessToken", []))
  }
  let sane = (s : Json?) => is_integer(s) &&
    num_of(s).unwrap() > 0.0 &&
    num_of(s).unwrap() < 9007199254740991.0 / 2000.0
  let seconds = get(Some(answer), "expires_in")
  if !sane(seconds) {
    raise Said(t("station.claudeAuth.noExpiry", []))
  }
  let latest = self.read(env, home, machine, lang)
  if latest.keychain != credentials.keychain ||
    !same_json(get(get(Some(latest.data), "claudeAiOauth"), "refreshToken"), get(Some(oauth), "refreshToken")) {
    // A simultaneous login wins over this refresh, even of another account.
    if usable(self.io, self.words, latest, None, lang, margin_ms) {
      return access_of(self.words, latest, lang)
    }
    raise Said(t("station.claudeAuth.changedDuringRefresh", []))
  }
  guard get(Some(latest.data), "claudeAiOauth") is Some(Object(updated)) else {
    raise Said(t("station.claudeAuth.changedDuringRefresh", []))
  }
  let now = (self.io.wall)()
  updated["accessToken"] = Json::string(token)
  updated["expiresAt"] = Json::number(now.to_double() + num_of(seconds).unwrap() * 1000.0)
  if text_of(get(Some(answer), "refresh_token")) is Some(r) {
    updated["refreshToken"] = Json::string(r)
  }
  if str_of(get(Some(answer), "scope")) is Some(scope) {
    updated["scopes"] = jstrings(split_space(scope).filter(s => s != ""))
  }
  let refresh_expires = get(Some(answer), "refresh_token_expires_in")
  if sane(refresh_expires) {
    updated["refreshTokenExpiresAt"] = Json::number(now.to_double() + num_of(refresh_expires).unwrap() * 1000.0)
  }
  let mut error : Error? = None
  for attempt in 0..<3 {
    if attempt > 0 {
      (self.io.sleep)(100)
    }
    let failed = self.save(env, home, latest, lang) catch { e => Some(e) } noraise { _ => None }
    error = failed
    if failed is None {
      break
    }
  }
  if error is Some(e) {
    raise e
  }
  access_of(self.words, latest, lang)
}

///|
/// proper-lockfile-compatible mkdir locks, as Claude Code takes them: a 5 s heartbeat and a 60 s stale threshold. The
/// directory is held open, so an owner from before cannot touch or remove a lock that replaced its own.
pub struct RefreshLock {
  priv io : Io
  priv path : String
  priv held : Held
  priv heartbeat : () -> Unit
}

///|
pub async fn RefreshLock::acquire(io : Io, words : Words, path : String, lang : String) -> RefreshLock {
  let deadline = (io.wall)() + lock_wait_ms
  while true {
    let made = (io.mkdir)(path, false) catch { e => Some(e) } noraise { _ => None }
    match made {
      None => break
      Some(e) => {
        if code_of(e) != "EEXIST" {
          raise Said(tr(words, lang, "station.claudeAuth.lockFailed", []))
        }
        let st = (io.stat)(path) catch { _ => continue }
        let age = (io.wall)().to_double() - st.mtime_ms
        if age > lock_stale_ms.to_double() {
          let gone = (io.rmdir)(path) catch { e => Some(e) } noraise { _ => None }
          match gone {
            None => continue
            Some(e) if code_of(e) == "ENOENT" => continue
            Some(_) => ()
          }
        }
        if (io.wall)() >= deadline {
          raise Said(tr(words, lang, "station.claudeAuth.refreshLocked", []))
        }
        (io.sleep)(100)
      }
    }
  }
  let held = (io.hold)(path)
  let stopped = Ref(false)
  let stop_ref : Ref[() -> Unit] = Ref(() => ())
  // timer: a heartbeat that keeps the lock
  stop_ref.val = (io.every)(heartbeat_ms, () => {
    if stopped.val {
      return
    }
    (io.spawn)(async fn() {
      (held.utimes)((io.wall)()) catch {
        _ => {
          stopped.val = true
          (stop_ref.val)()
        }
      }
    })
  })
  let heartbeat = () => {
    stopped.val = true
    (stop_ref.val)()
  }
  { io, path, held, heartbeat }
}

///|
pub async fn RefreshLock::release(self : RefreshLock) -> Unit {
  (self.heartbeat)()
  try {
    let held = (self.held.stat)()
    let current = (self.io.stat)(self.path)
    if held.dev == current.dev && held.ino == current.ino {
      (self.io.rmdir)(self.path)
    }
  } catch {
    _ => ()
  }
  (self.held.close)() catch {
    _ => ()
  }
}
