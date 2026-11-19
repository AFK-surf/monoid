// A Cursor profile signed in with the person's Cursor account (station/src/accounts/cursor.ts): the browser login
// Cursor's CLI and SDK use (a page at cursor.com/loginDeepControl given a one-time challenge, the station asking
// Cursor's backend until the page is confirmed), then, once, the login's session token mints a user API key and is
// dropped. The key is what the SDK runs on, kept in the profile's home (cursor/auth.json).

///|
/// Where Cursor is: its site, its backend and its API (`CursorUrls`; tests give fake ones).
pub(all) struct CursorUrls {
  website : String
  backend : String
  api : String
}

///|
pub let cursor_urls : CursorUrls = {
  website: "https://cursor.com",
  backend: "https://api2.cursor.sh",
  api: "https://api.cursor.com",
}

///|
pub fn CursorUrls::of_jv(v : JV?) -> CursorUrls {
  match v {
    Some(Obj(_) as u) =>
      {
        website: jstr(u.get("website")).unwrap_or(cursor_urls.website),
        backend: jstr(u.get("backend")).unwrap_or(cursor_urls.backend),
        api: jstr(u.get("api")).unwrap_or(cursor_urls.api),
      }
    _ => cursor_urls
  }
}

///|
/// What a sign-in leaves in the profile's home (`CursorLogin`).
pub(all) struct CursorLogin {
  api_key : String
  email : String?
  key_name : String
  created_at : Double
} derive(Eq, Show)

///|
pub fn CursorLogin::to_jv(self : CursorLogin) -> JV {
  jobj([
    ("apiKey", js(self.api_key)),
    ("email", jopt(self.email)),
    ("keyName", js(self.key_name)),
    ("createdAt", jnum(self.created_at)),
  ])
}

///|
/// `authFile`: where a sign-in is kept.
pub fn cursor_auth_file(home : String) -> String {
  join_path([home, "cursor", "auth.json"])
}

///|
/// `cursorIn`: what a sign-in's file says (JSON.parse's failure thrown, as there).
pub fn cursor_in(text : String) -> CursorLogin? raise Thrown {
  let j = json_parse(text)
  match j.get("apiKey") {
    Some(Str(k)) if k != "" =>
      Some({
        api_key: k,
        email: match j.get("email") {
          Some(Str(e)) if e != "" => Some(e)
          _ => None
        },
        key_name: match j.get("keyName") {
          Some(Str(n)) => n
          _ => ""
        },
        created_at: match j.get("createdAt") {
          Some(Num(n)) => n
          _ => 0.0
        },
      })
    _ => None
  }
}

///|
/// `readCursor`.
pub async fn read_cursor(io : Io, home : String) -> CursorLogin? {
  let run = async fn() -> CursorLogin? {
    cursor_in(io.read_file(cursor_auth_file(home)))
  }
  run() catch {
    _ => None
  }
}

///|
/// `writeCursor`.
pub async fn write_cursor(io : Io, home : String, login : CursorLogin) -> Unit {
  io.write_private(cursor_auth_file(home), stringify_pretty(login.to_jv()) + "\n")
}

///|
/// `cursorHandshake`: a sign-in to make: the page to confirm it on, and what only this station holds to redeem it.
pub async fn cursor_handshake(io : Io, urls : CursorUrls) -> JV {
  let verifier = base64url(hex_bytes(io.random_hex(32)))
  let challenge = base64url(hex_bytes(@hash.sha256_utf8_hex(verifier)))
  let uuid = io.uuid()
  jobj([
    ("uuid", js(uuid)),
    ("verifier", js(verifier)),
    (
      "url",
      js(
        "\{urls.website}/loginDeepControl?challenge=\{challenge}&uuid=\{uuid}&mode=login&redirectTarget=cli",
      ),
    ),
  ])
}

///|
/// `pollCursor`: the login's tokens (`{accessToken}`), or still waiting (`{pending: true}`).
pub async fn poll_cursor(io : Io, urls : CursorUrls, handshake : JV) -> JV {
  let response = io.fetch({
    url: "\{urls.backend}/auth/poll",
    verb: Some("POST"),
    headers: [("accept", "application/json"), ("content-type", "application/json")],
    body: Some(
      stringify(
        jobj([
          ("uuid", handshake.get("uuid").unwrap_or(jundef)),
          ("verifier", handshake.get("verifier").unwrap_or(jundef)),
        ]),
      ),
    ),
    timeout_ms: 20_000,
  })
  if response.status == 404 {
    return jobj([("pending", jbool(true))])
  }
  if !response.ok() {
    raise plain_error("HTTP \{response.status}")
  }
  match response.json().get("accessToken") {
    Some(Str(t)) => jobj([("accessToken", js(t))])
    _ => raise plain_error("Cursor gave no login")
  }
}

///|
/// One of Cursor's dashboard calls (Connect, its JSON form) with the login's session token.
async fn cursor_dashboard(
  io : Io,
  urls : CursorUrls,
  verb : String,
  access_token : String,
  body : JV,
) -> JV {
  let response = io.fetch({
    url: "\{urls.backend}/aiserver.v1.DashboardService/\{verb}",
    verb: Some("POST"),
    headers: [
      ("authorization", "Bearer \{access_token}"),
      ("content-type", "application/json"),
      ("connect-protocol-version", "1"),
    ],
    body: Some(stringify(body)),
    timeout_ms: 20_000,
  })
  let text = response.text
  if !response.ok() {
    let mut said = js(text)
    match try_parse(text) {
      Some(j) =>
        said = match j.get("message") {
          None | Some(Null) => js(text)
          Some(m) => m
        }
      None => ()
    }
    let said_text = js_string(Some(said))
    let tail = if is_truthy(Some(said)) {
      ": " + slice(said_text, 0, b=300)
    } else {
      ""
    }
    raise plain_error("\{verb}: HTTP \{response.status}\{tail}")
  }
  json_parse(text)
}

///|
/// `mintCursorKey`: the key the login mints (no end set), and whose account it is.
pub async fn mint_cursor_key(
  io : Io,
  urls : CursorUrls,
  access_token : String,
  name : String,
) -> JV {
  let made = cursor_dashboard(
    io,
    urls,
    "CreateUserApiKey",
    access_token,
    jobj([("name", js(name))]),
  )
  let api_key = match made.get("apiKey") {
    Some(Str(k)) if k != "" => k
    _ => raise plain_error("Cursor minted no key")
  }
  let me = cursor_dashboard(io, urls, "GetMe", access_token, Obj([])) catch {
    _ => Null
  }
  let email = match me.get("email") {
    Some(Str(e)) if e != "" => js(e)
    _ => Null
  }
  jobj([("apiKey", js(api_key)), ("email", email)])
}

///|
fn basic(api_key : String) -> String {
  "Basic " + @base64.encode(utf8("\{api_key}:"))
}

///|
/// `cursorMe`: whose a key is (None: it refused the key; an error: it could not be asked).
pub async fn cursor_me(io : Io, urls : CursorUrls, api_key : String) -> JV {
  let response = io.get(
    "\{urls.api}/v1/me",
    [("authorization", basic(api_key)), ("accept", "application/json")],
    15_000,
  )
  if response.status == 401 || response.status == 403 {
    return Null
  }
  if !response.ok() {
    raise plain_error("HTTP \{response.status}")
  }
  let body = response.json()
  jobj([
    (
      "email",
      match body.get("userEmail") {
        Some(Str(e)) if e != "" => js(e)
        _ => Null
      },
    ),
    (
      "keyName",
      match body.get("apiKeyName") {
        Some(Str(n)) => js(n)
        _ => js("")
      },
    ),
  ])
}

///|
/// `cursorModels`: the models a key may run, as Cursor's API lists them (None where it does not say).
pub async fn cursor_models(
  io : Io,
  urls : CursorUrls,
  api_key : String,
) -> Array[String]? {
  let run = async fn() -> Array[String]? {
    let response = io.get(
      "\{urls.api}/v1/models",
      [("authorization", basic(api_key)), ("accept", "application/json")],
      20_000,
    )
    if !response.ok() {
      return None
    }
    let body = response.json()
    let list = match body {
      Arr(a) => a
      _ =>
        match body.get("models") {
          Some(Arr(a)) => a
          _ =>
            match body.get("items") {
              Some(Arr(a)) => a
              _ => []
            }
        }
    }
    let ids = list.filter_map(m => {
      let id = match m {
        Str(_) => Some(m)
        _ => m.get("id")
      }
      match id {
        Some(Str(s)) if s != "" => Some(s)
        _ => None
      }
    })
    if ids.length() > 0 {
      Some(ids)
    } else {
      None
    }
  }
  run() catch {
    _ => None
  }
}

///|
/// The SHA-256 of `text`'s UTF-8, hex: `@hash.sha256_utf8_hex`'s, kept here for what calls it by this package.
pub fn sha256_hex(text : String) -> String {
  @hash.sha256_utf8_hex(text)
}
