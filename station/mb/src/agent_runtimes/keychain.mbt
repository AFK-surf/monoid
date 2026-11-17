// no-keychain.ts and machine-logins.ts: Claude Code kept off the keychain for a profile's processes (a stand-in
// `security` first on their PATH), a profile's login moved back out of it into its home's file, and how a `machine`
// profile uses this machine's own login (Claude Code's token read where claude reads it, Codex's auth.json shared).

///|
/// no-keychain.ts `STUB`: the stand-in `security`.
pub let keychain_stub : String =
  #|#!/bin/sh
  #|# still.fail: profile logins are kept in files, not the keychain; the rest goes to the real security.
  #|case "$*" in *"Claude Code"*) exit 44 ;; esac
  #|if [ "$1" = "-i" ]; then
  #|  input=$(cat)
  #|  case "$input" in *"Claude Code"*) exit 44 ;; esac
  #|  printf '%s\n' "$input" | /usr/bin/security "$@"
  #|  exit $?
  #|fi
  #|exec /usr/bin/security "$@"
  #|

///|
/// Where the stand-in is (`stubDirSoon`'s directory), for `tmp` (os.tmpdir()) and the user's id.
pub fn stub_dir(tmp : String, uid : Int) -> String {
  join([tmp, "stillfail-no-keychain-\{uid}"])
}

///|
/// `stubDirSoon`: the directory with the stand-in `security`, made (again) when missing or an older one: written aside
/// and moved in (a process may be running the old one), its failures let be.
pub async fn stub_dir_soon(host : @host.Host, tmp : String, uid : Int, aside : String) -> String {
  let dir = stub_dir(tmp, uid)
  let path = join([dir, "security"])
  if read_text(host, path) != Some(keychain_stub) {
    let fresh = join([dir, "security.\{aside}"])
    try {
      make_dir(host, dir)
      write_file(host, fresh, keychain_stub, mode=0o755)
      ask(host, "fs.rename", { "from": Json::string(fresh), "to": Json::string(path) }) |> ignore
    } catch {
      _ => ()
    }
  }
  dir
}

///|
/// `fileCredentialsSoon`'s PATH: the stand-in's directory first (macOS only, `has_keychain`; elsewhere as it was).
/// `process_path` the station's own PATH, for an env that names none.
pub fn credentials_path(env : Fields, has_keychain : Bool, dir : String, process_path : String) -> Unit {
  if !has_keychain {
    return
  }
  let path = str_of(env.get("PATH")).unwrap_or(process_path)
  env.set_str("PATH", "\{dir}:\{path}")
}

///|
/// `keychainItem`: the keychain item Claude Code keeps the login of a config directory in.
pub fn keychain_item(home : String) -> String {
  "Claude Code-credentials-\{sub(sha256_hex(home), 0, to=8)}"
}

///|
/// What `takeBack` moves out of the keychain: the item's text, trimmed, when it is a login (`claudeAiOauth`); none for
/// what security did not find or what is no login.
pub fn login_of_keychain(found_ok : Bool, stdout : String) -> String? {
  if !found_ok {
    return None
  }
  let text = trim(stdout)
  match parse(text) {
    Some(Obj(_) as o) if o.get("claudeAiOauth") is Some(_) => Some(text)
    _ => None
  }
}

///|
/// `takeBackMissing`: a profile's login Claude Code moved into the keychain, moved back into its home's
/// `.credentials.json` (written private) and the item deleted; whether it was.
pub async fn take_back_missing(host : @host.Host, home : String, has_keychain : Bool) -> Bool {
  if !has_keychain {
    return false
  }
  let item = keychain_item(home)
  let found = run_program(host, "/usr/bin/security", ["find-generic-password", "-w", "-s", item])
  let text = match found {
    Some((0, out)) => login_of_keychain(true, out)
    _ => None
  }
  guard text is Some(login) else { return false }
  try {
    write_file(host, join([home, ".credentials.json"]), login, mode=0o600)
  } catch {
    _ => return false
  }
  run_program(host, "/usr/bin/security", ["delete-generic-password", "-s", item]) |> ignore
  true
}

///|
/// `takeBack`: as `takeBackMissing`, nothing where the file is there.
pub async fn take_back(host : @host.Host, home : String, has_keychain : Bool) -> Unit {
  if !has_keychain || exists(host, join([home, ".credentials.json"])) {
    return
  }
  take_back_missing(host, home, has_keychain) |> ignore
}

///|
/// machine-logins.ts `CLAUDE_TOKEN_MARGIN_MS`.
pub let claude_token_margin_ms : Double = 5.0 * 60000.0

///|
/// `platform.home(env)`: HOME, and on Windows USERPROFILE after it.
fn home_dir(env : Fields, windows : Bool) -> String {
  match str_of(env.get("HOME")) {
    Some(h) => h
    None =>
      if windows {
        str_of(env.get("USERPROFILE")).unwrap_or(".")
      } else {
        "."
      }
  }
}

///|
/// `claudeCredentialsFile`.
pub fn claude_credentials_file(env : Fields, windows? : Bool = false) -> String {
  join([home_dir(env, windows), ".claude", ".credentials.json"])
}

///|
/// `codexHome`: CODEX_HOME where it is set (not empty), else ~/.codex.
pub fn codex_home(env : Fields, windows? : Bool = false) -> String {
  match nonempty(env.get("CODEX_HOME")) {
    Some(h) => h
    None => join([home_dir(env, windows), ".codex"])
  }
}

///|
/// `codexAuthFile`.
pub fn codex_auth_file(env : Fields, windows? : Bool = false) -> String {
  join([codex_home(env, windows~), "auth.json"])
}

///|
/// `MachineToken`.
pub(all) struct MachineToken {
  token : String
  expires_at : Double
  subscription_type : String?
  rate_limit_tier : String?
}

///|
pub fn MachineToken::json(self : MachineToken) -> J {
  let f = Fields::of([("token", js(self.token)), ("expiresAt", num(self.expires_at))])
  if self.subscription_type is Some(s) {
    f.set_str("subscriptionType", s)
  }
  if self.rate_limit_tier is Some(s) {
    f.set_str("rateLimitTier", s)
  }
  f.json()
}

///|
/// `parseClaudeCredentials`.
pub fn parse_claude_credentials(text : String) -> MachineToken? {
  let oauth = get(parse(text), "claudeAiOauth")
  match get(oauth, "accessToken") {
    Some(Str(token)) if token.length() > 0 =>
      Some({
        token: t(token),
        expires_at: num_of(get(oauth, "expiresAt")).unwrap_or(0.0),
        subscription_type: str_of(get(oauth, "subscriptionType")),
        rate_limit_tier: str_of(get(oauth, "rateLimitTier")),
      })
    _ => None
  }
}

///|
/// `KeychainRead`: what `security find-generic-password` said of the machine's login.
pub(all) enum KeychainRead {
  Found(String)
  Missing
  Unreadable
}

///|
/// `readClaudeKeychain`'s reading of security's end: found where it ended well, missing only for errSecItemNotFound
/// (its exit 44), unreadable for anything else (locked, denied, a timeout, no such program).
pub fn keychain_read_of(ended : (Int, String)?) -> KeychainRead {
  match ended {
    Some((0, out)) => Found(out)
    Some((44, _)) => Missing
    _ => Unreadable
  }
}

///|
/// `readClaudeKeychain`.
pub async fn read_claude_keychain(host : @host.Host, env : Map[String, String]) -> KeychainRead {
  keychain_read_of(run_program(host, "security", ["find-generic-password", "-w", "-s", "Claude Code-credentials"], timeout_ms=10000, env~))
}

///|
/// `readClaudeCredentials` once each place is read: the keychain's first on macOS, then the file's.
pub fn claude_credentials_of(has_keychain : Bool, keychain : KeychainRead, file : String?) -> MachineToken? {
  if has_keychain {
    match keychain {
      Found(text) => return parse_claude_credentials(text)
      Unreadable => return None
      Missing => ()
    }
  }
  match file {
    Some(text) => parse_claude_credentials(text)
    None => None
  }
}

///|
/// `machineClaudeToken`'s check at `now`: the token, or why it is not given.
pub fn machine_claude_token_of(found : MachineToken?, now : Double) -> Result[MachineToken, String] {
  match found {
    None => Err("the machine's Claude Code login could not be read")
    Some(token) =>
      if token.expires_at != 0.0 && token.expires_at - now <= claude_token_margin_ms {
        Err("the machine's Claude Code token runs out and is not renewed here")
      } else {
        Ok(token)
      }
  }
}

///|
/// `linkCodexAuthSoon`: a machine profile's Codex home sharing the machine's login, its auth.json a link to the
/// machine's (platform.shareFile on Unix: left as it is where it is that link already, made again otherwise).
pub async fn link_codex_auth_soon(host : @host.Host, home : String, env : Fields) -> Unit raise {
  make_dir(host, home)
  let target = codex_auth_file(env)
  let link = join([home, "auth.json"])
  match ask_or_null(host, "fs.stat", { "path": Json::string(link), "lstat": Json::boolean(true) }) {
    Null => ()
    String("link") if ask_or_null(host, "fs.readlink", { "path": Json::string(link) }) == Json::string(target) => return
    _ => remove(host, link)
  }
  symlink(host, target, link)
}

///|
/// `readClaudeCredentials`: the machine's Claude Code login where claude reads it, the keychain first on macOS.
pub async fn read_claude_credentials(host : @host.Host, env : Fields, has_keychain : Bool) -> MachineToken? {
  let keychain = if has_keychain {
    let vars : Map[String, String] = {}
    for e in env.entries() {
      if e.1 is Str(s) {
        vars[e.0] = t(s)
      }
    }
    read_claude_keychain(host, vars)
  } else {
    Missing
  }
  let file = match keychain {
    Missing => read_text(host, claude_credentials_file(env))
    _ => None
  }
  claude_credentials_of(has_keychain, keychain, file)
}

///|
/// `machineClaudeToken`: the machine's current token, refused where it cannot be read or runs out within the margin.
pub async fn machine_claude_token(host : @host.Host, env : Fields, has_keychain : Bool, now : Double) -> Result[MachineToken, String] {
  machine_claude_token_of(read_claude_credentials(host, env, has_keychain), now)
}
