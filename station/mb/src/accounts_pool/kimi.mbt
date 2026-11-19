// A Kimi Code profile signed in with the person's Kimi account instead of a key (station/src/accounts/kimi.ts): Kimi
// Code's device authorization grant (RFC 8628), as kimi-cli `kimi login` signs in. Its access token lasts minutes and
// is renewed with a refresh token that is spent when used, so the token is never the profile's key: the tokens are in
// the profile's home (`kimi-code.json`), the current access token alone in `kimi-code.token` (what Claude Code reads),
// renewed while it has less than half its life left; every request carries the device it was made on.

///|
pub let kimi_auth : String = "https://auth.kimi.com"

///|
pub let kimi_file : String = "kimi-code.json"

///|
pub let kimi_token_file : String = "kimi-code.token"

///|
let kimi_client_id : String = "17e5f671-d194-4dfb-9706-5516cb48c098"

///|
let kimi_platform : String = "still.fail"

///|
/// What a sign-in leaves in the profile's home (`KimiLogin`).
pub(all) struct KimiLogin {
  access : String
  refresh : String
  expires_at : Double
  life_ms : Double
  device_id : String
} derive(Eq, Show)

///|
pub fn KimiLogin::to_jv(self : KimiLogin) -> JV {
  jobj([
    ("access", js(self.access)),
    ("refresh", js(self.refresh)),
    ("expiresAt", jnum(self.expires_at)),
    ("lifeMs", jnum(self.life_ms)),
    ("deviceId", js(self.device_id)),
  ])
}

///|
/// A token as Kimi gives it (`KimiToken`).
pub(all) struct KimiToken {
  access : String
  refresh : String
  expires_in_ms : Double
}

///|
/// `newDeviceId`.
pub async fn new_device_id(io : Io) -> String {
  io.uuid().replace_all(old="-", new="")
}

///|
fn ascii_header(v : String) -> String {
  let out = StringBuilder::new()
  for i in 0..<v.length() {
    let c = v.unsafe_charcode_at(i)
    if c >= 0x20 && c <= 0x7e {
      out.write_char(c.unsafe_to_char())
    }
  }
  let t = trim_js(out.to_string())
  if t == "" {
    "unknown"
  } else {
    t
  }
}

///|
/// `kimiHeaders`: which device a request of a sign-in is, as kimi-cli says.
pub async fn kimi_headers(io : Io, device_id : String) -> Array[(String, String)] {
  let os = io.os()
  [
    ("X-Msh-Platform", kimi_platform),
    ("X-Msh-Version", "1"),
    ("X-Msh-Device-Name", ascii_header(js_string(os.get("hostname")))),
    (
      "X-Msh-Device-Model",
      ascii_header("\{js_string(os.get("type"))} \{js_string(os.get("arch"))}"),
    ),
    ("X-Msh-Os-Version", ascii_header(js_string(os.get("release")))),
    ("X-Msh-Device-Id", device_id),
  ]
}

///|
/// What a sign-in's file says, None where it says no sign-in.
pub fn kimi_in(text : String) -> KimiLogin? {
  guard try_parse(text) is Some(j) else { return None }
  match (j.get("access"), j.get("refresh"), j.get("expiresAt"), j.get("deviceId")) {
    (Some(Str(a)), Some(Str(r)), Some(Num(e)), Some(Str(d))) =>
      Some({
        access: a,
        refresh: r,
        expires_at: e,
        life_ms: match j.get("lifeMs") {
          Some(Num(l)) => l
          _ => 0.0
        },
        device_id: d,
      })
    _ => None
  }
}

///|
/// `readKimi`.
pub async fn read_kimi(io : Io, home : String) -> KimiLogin? {
  match io.read_file_or_none(join_path([home, kimi_file])) {
    Some(text) => kimi_in(text)
    None => None
  }
}

///|
/// JSON.stringify(v, null, 2).
pub fn stringify_pretty(v : JV) -> String {
  @jsjson.stringify_indent(JV::to_js(v), 2)
}

///|
/// `writeKimi`: the sign-in written, then its access token for Claude Code.
pub async fn write_kimi(io : Io, home : String, login : KimiLogin) -> Unit {
  io.write_private(join_path([home, kimi_file]), stringify_pretty(login.to_jv()) + "\n")
  io.write_private(join_path([home, kimi_token_file]), login.access)
}

///|
/// `kimiDue`: less than half its life left (at least 5 minutes).
pub fn kimi_due(login : KimiLogin, now : Double) -> Bool {
  login.expires_at - now < js_max(5.0 * 60000.0, login.life_ms / 2.0)
}

///|
async fn kimi_post(
  io : Io,
  base : String,
  path : String,
  form : Array[(String, String)],
  device_id : String,
) -> (Int, JV) {
  let all = [("client_id", kimi_client_id)]
  for f in form {
    let mut put = false
    for i, a in all {
      if a.0 == f.0 {
        all[i] = f
        put = true
      }
    }
    if !put {
      all.push(f)
    }
  }
  io.post_form("\{base}\{path}", all, kimi_headers(io, device_id))
}

///|
fn kimi_token_of(body : JV) -> KimiToken? {
  match (body.get("access_token"), body.get("refresh_token")) {
    (Some(Str(a)), Some(Str(r))) =>
      Some({
        access: a,
        refresh: r,
        expires_in_ms: (match body.get("expires_in") {
          Some(Num(n)) if n > 0.0 => n
          _ => 900.0
        }) *
        1000.0,
      })
    _ => None
  }
}

///|
fn kimi_error_of(status : Int, body : JV) -> String {
  match body.get("error") {
    Some(Str(e)) => e
    _ =>
      match body.get("message") {
        Some(Str(m)) => m
        _ => "HTTP \{status}"
      }
  }
}

///|
/// `startKimiDevice`: a code to sign in with, for the device `device_id`.
pub async fn start_kimi_device(io : Io, base : String, device_id : String) -> JV {
  let (status, body) = kimi_post(io, base, "/api/oauth/device_authorization", [], device_id)
  match (body.get("device_code"), body.get("user_code")) {
    (Some(Str(device_code)), Some(Str(user_code))) if status == 200 => {
      let url = match body.get("verification_uri_complete") {
        Some(Str(u)) => u
        _ =>
          match body.get("verification_uri") {
            None | Some(Null) => ""
            v => js_string(v)
          }
      }
      let seconds = (v : JV?, fallback : Double) => match v {
        Some(Num(n)) if n >= 0.0 => n
        _ => fallback
      }
      jobj([
        ("deviceCode", js(device_code)),
        ("userCode", js(user_code)),
        ("url", js(url)),
        ("expiresInMs", jnum(seconds(body.get("expires_in"), 600.0) * 1000.0)),
        ("intervalMs", jnum(seconds(body.get("interval"), 5.0) * 1000.0)),
      ])
    }
    _ => raise plain_error(kimi_error_of(status, body))
  }
}

///|
/// console.ts `pollAnswer`: signed in, still waiting (`slow_down`: asked too often), or refused.
pub fn poll_answer(token : JV?, error : () -> String) -> JV {
  match token {
    Some(t) => jobj([("token", t)])
    None => {
      let e = error()
      if e == "authorization_pending" || e == "slow_down" {
        jobj([("pending", jbool(true)), ("slowDown", jbool(e == "slow_down"))])
      } else {
        jobj([("error", js(e))])
      }
    }
  }
}

///|
/// `kimiDeviceToken`: whether the code was approved.
pub async fn kimi_device_token(
  io : Io,
  base : String,
  device_code : String,
  device_id : String,
) -> JV {
  let (status, body) = kimi_post(
    io,
    base,
    "/api/oauth/token",
    [
      ("device_code", device_code),
      ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
    ],
    device_id,
  )
  let token = if status == 200 { kimi_token_of(body) } else { None }
  poll_answer(
    token.map(t => jobj([
      ("access", js(t.access)),
      ("refresh", js(t.refresh)),
      ("expiresInMs", jnum(t.expires_in_ms)),
      ("org", Null),
    ])),
    () => kimi_error_of(status, body),
  )
}

///|
/// console.ts `renewAnswer`: the new token, else refused for good (a 400, 401 or 403: RenewRefused) or for now.
pub fn renew_refused(status : Int, message : String) -> Thrown {
  if status == 400 || status == 401 || status == 403 {
    Thrown("RenewRefused", jobj([("status", jint(status)), ("message", js(message))]))
  } else {
    plain_error(message)
  }
}

///|
/// `renewKimiToken`: a new access token for a refresh token (which is spent: the one returned replaces it).
pub async fn renew_kimi_token(
  io : Io,
  base : String,
  refresh : String,
  device_id : String,
) -> KimiToken {
  let (status, body) = kimi_post(
    io,
    base,
    "/api/oauth/token",
    [("grant_type", "refresh_token"), ("refresh_token", refresh)],
    device_id,
  )
  match (if status == 200 { kimi_token_of(body) } else { None }) {
    Some(t) => t
    None => raise renew_refused(status, kimi_error_of(status, body))
  }
}
