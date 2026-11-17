// station/src/accounts/console.ts: an OpenCode Go profile signed in with the person's OpenCode Console account instead
// of a key: the Console's device authorization grant (RFC 8628). Its access token is the profile's key in config.json;
// the refresh token, when the access token runs out and whose account it is are in the profile's home (`console_file`);
// only the station the profile is on renews it.

///|
pub let console_url : String = "https://opencode.ai/console"

///|
/// The file in a signed-in profile's home.
pub let console_file : String = "opencode-console.json"

///|
/// The client the Console is told signs in (any id will do: it is shown on the page that approves it).
let console_client : String = "still.fail"

///|
let console_agent : String = "still.fail"

///|
/// What a sign-in leaves in the profile's home. `expires_at`: when `access` runs out (ms since the epoch).
pub(all) struct ConsoleLogin {
  access : String
  refresh : String
  expires_at : Double
  org : String?
  email : String?
  workspace : String?
}

///|
pub fn ConsoleLogin::to_json(self : ConsoleLogin) -> Json {
  {
    "access": Json::string(self.access),
    "refresh": Json::string(self.refresh),
    "expiresAt": Json::number(self.expires_at),
    "org": opt(self.org),
    "email": opt(self.email),
    "workspace": opt(self.workspace),
  }
}

///|
/// Where to sign in: the page with the code filled in, the code, how long it lasts and how often to ask.
pub(all) struct Device {
  device_code : String
  user_code : String
  url : String
  expires_in_ms : Double
  interval_ms : Double
}

///|
pub fn Device::to_json(self : Device) -> Json {
  {
    "deviceCode": Json::string(self.device_code),
    "userCode": Json::string(self.user_code),
    "url": Json::string(self.url),
    "expiresInMs": Json::number(self.expires_in_ms),
    "intervalMs": Json::number(self.interval_ms),
  }
}

///|
pub(all) struct Token {
  access : String
  refresh : String
  expires_in_ms : Double
  org : String?
}

///|
pub fn Token::to_json(self : Token) -> Json {
  {
    "access": Json::string(self.access),
    "refresh": Json::string(self.refresh),
    "expiresInMs": Json::number(self.expires_in_ms),
    "org": opt(self.org),
  }
}

///|
/// The Console's answer for a device: still waiting (`slow_down`: asked too often), signed in, or refused.
pub(all) enum DeviceAnswer {
  Pending(Bool)
  Signed(Token)
  Refused(String)
}

///|
pub fn DeviceAnswer::to_json(self : DeviceAnswer) -> Json {
  match self {
    Pending(slow) => { "pending": true, "slowDown": Json::boolean(slow) }
    Signed(t) => { "token": t.to_json() }
    Refused(e) => { "error": Json::string(e) }
  }
}

///|
/// What a sign-in's file says (`consoleIn`).
pub fn console_in(file : String) -> ConsoleLogin? {
  let j = parse_or_none(file)
  guard str_of(get(j, "access")) is Some(access) &&
    str_of(get(j, "refresh")) is Some(refresh) &&
    num_of(get(j, "expiresAt")) is Some(expires_at) else {
    return None
  }
  Some({
    access,
    refresh,
    expires_at,
    org: text_of(get(j, "org")),
    email: text_of(get(j, "email")),
    workspace: text_of(get(j, "workspace")),
  })
}

///|
pub async fn read_console(io : Io, home : String) -> ConsoleLogin? {
  let text = (io.read)(join([home, console_file])) catch { _ => return None }
  console_in(text)
}

///|
pub async fn write_console(io : Io, home : String, login : ConsoleLogin) -> Unit {
  (io.write_private)(join([home, console_file]), stringify_pretty(login.to_json()) + "\n")
}

///|
/// An OAuth form posted (a device's code asked for, a token asked for or renewed): its status and its JSON (null for
/// none). Kimi's sign-in posts its own the same way, with its own headers.
pub async fn post_form(
  io : Io,
  url : String,
  form : Array[(String, String)],
  headers : Array[(String, String)],
) -> (Int, Json) {
  let all = [("content-type", "application/x-www-form-urlencoded"), ("accept", "application/json")]
  for h in headers {
    match all.search_by(p => p.0 == h.0) {
      Some(i) => all[i] = h
      None => all.push(h)
    }
  }
  let response = (io.fetch)({
    url,
    method_: "POST",
    headers: all,
    body: Some(form_encoded(form)),
    timeout_ms: 20_000,
    manual: false,
  })
  (response.status, parse_or_none(response.body).unwrap_or(Json::null()))
}

///|
async fn console_post(io : Io, base : String, path : String, form : Array[(String, String)]) -> (Int, Json) {
  post_form(io, "\{base}\{path}", form, [("user-agent", console_agent)])
}

///|
/// A device's poll answered (RFC 8628): signed in, still waiting (`slow_down`: asked too often), or refused.
pub fn poll_answer(token : Token?, error : () -> String) -> DeviceAnswer {
  match token {
    Some(t) => Signed(t)
    None => {
      let e = error()
      if e == "authorization_pending" || e == "slow_down" {
        Pending(e == "slow_down")
      } else {
        Refused(e)
      }
    }
  }
}

///|
/// A renewal answered: the new token, else refused for good (a 400, 401 or 403: RenewRefused) or for now.
pub fn renew_answer(status : Int, token : Token?, error : () -> String) -> Token raise {
  match token {
    Some(t) => t
    None => {
      let e = error()
      if status == 400 || status == 401 || status == 403 {
        raise RenewRefused(Some(status), e)
      }
      raise Failed(e)
    }
  }
}

///|
fn token_of(body : Json) -> Token? {
  let b = Some(body)
  guard str_of(get(b, "access_token")) is Some(access) &&
    str_of(get(b, "refresh_token")) is Some(refresh) &&
    num_of(get(b, "expires_in")) is Some(expires_in) else {
    return None
  }
  Some({ access, refresh, expires_in_ms: expires_in * 1000.0, org: str_of(get(b, "org_id")) })
}

///|
/// What the Console says went wrong: its OAuth error, its tag, or the status.
fn error_of(status : Int, body : Json) -> String {
  match (str_of(get(Some(body), "error")), str_of(get(Some(body), "_tag"))) {
    (Some(e), _) => e
    (None, Some(t)) => t
    _ => "HTTP \{status}"
  }
}

///|
/// `new URL(raw)`, failing as Node's does.
fn url_of(raw : String) -> @cloud_net.Url raise {
  match @cloud_net.parse_url(raw) {
    Some(u) => u
    None => raise Failed("Invalid URL")
  }
}

///|
/// `new URL(relative, origin).toString()`, for a base that is an origin (its path `/`).
fn resolve_at_origin(relative : String, origin : String) -> String raise {
  if @cloud_net.parse_url(relative) is Some(u) {
    return u.href()
  }
  let scheme = sub(origin, 0, index_of(origin, ":") + 1)
  let joined = if relative.has_prefix("//") {
    scheme + relative
  } else if relative.has_prefix("/") || relative.has_prefix("\\") {
    origin + relative
  } else if relative == "" {
    origin + "/"
  } else {
    origin + "/" + relative
  }
  url_of(joined).href()
}

///|
/// A code to sign in with, for one workspace (chosen on the Console's page).
pub async fn start_device(io : Io, base : String) -> Device {
  let (status, body) = console_post(io, base, "/auth/device/code", [
    ("client_id", console_client),
    ("supports_org_scope", "true"),
  ])
  let b = Some(body)
  guard status == 200 &&
    str_of(get(b, "device_code")) is Some(device_code) &&
    str_of(get(b, "user_code")) is Some(user_code) &&
    str_of(get(b, "verification_uri_complete")) is Some(page) else {
    raise Failed(error_of(status, body))
  }
  // The page is given relative to the Console's site.
  let url = resolve_at_origin(page, url_of(base).origin())
  let seconds = (v : Json?, fallback : Double) => match v {
    Some(Number(n, ..)) if n >= 0.0 => n
    _ => fallback
  }
  {
    device_code,
    user_code,
    url,
    expires_in_ms: seconds(get(b, "expires_in"), 600.0) * 1000.0,
    interval_ms: seconds(get(b, "interval"), 5.0) * 1000.0,
  }
}

///|
/// Asks whether the code was approved.
pub async fn device_token(io : Io, base : String, device_code : String) -> DeviceAnswer {
  let (status, body) = console_post(io, base, "/auth/device/token", [
    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
    ("device_code", device_code),
    ("client_id", console_client),
  ])
  poll_answer(if status == 200 { token_of(body) } else { None }, () => error_of(status, body))
}

///|
/// A new access token for a refresh token (which is spent: the one returned replaces it).
pub async fn renew_token(io : Io, base : String, refresh : String) -> Token {
  let (status, body) = console_post(io, base, "/auth/device/token", [
    ("grant_type", "refresh_token"),
    ("refresh_token", refresh),
    ("client_id", console_client),
  ])
  renew_answer(status, if status == 200 { token_of(body) } else { None }, () => error_of(status, body))
}

///|
/// Whose account a token is and which workspace it is for, where the Console says (none where it does not).
pub async fn who_is(io : Io, base : String, access : String, org : String?) -> (String?, String?) {
  let ask = async fn(path : String) -> Json {
    let response = (io.fetch)({
      url: "\{base}\{path}",
      method_: "GET",
      headers: [
        ("authorization", "Bearer \{access}"),
        ("accept", "application/json"),
        ("user-agent", console_agent),
      ],
      body: None,
      timeout_ms: 15_000,
      manual: false,
    }) catch {
      _ => return Json::null()
    }
    if !response.ok() {
      return Json::null()
    }
    parse_or_none(response.body).unwrap_or(Json::null())
  }
  let user = ask("/api/user")
  let orgs = ask("/api/orgs")
  let found = match (orgs, org) {
    (Array(list), Some(o)) =>
      match list.search_by(x => get(Some(x), "id") is Some(String(id)) && id == o) {
        Some(i) => Some(list[i])
        None => None
      }
    _ => None
  }
  (str_of(get(Some(user), "email")), str_of(get(found, "name")))
}
