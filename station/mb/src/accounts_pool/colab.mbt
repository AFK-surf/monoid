// A Google Colab service profile (station/src/accounts/colab.ts): Google's OAuth2 with PKCE, signed in by a code the
// person pastes (or the station's browser reads off Google's page), kept in `homes/<id>/colab-auth.json` (0600) as
// `google.oauth2.credentials.Credentials.to_json()` writes it, plus `email`; renewed by its refresh token; its Compute
// Units and running VMs read of Colab's `/tun/m/ccu-info`.

///|
pub let colab_auth_file : String = "colab-auth.json"

///|
let colab_client_id : String = "764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com"

///|
let colab_client_secret : String = "d-FL95Q19q7MQmFpd7hHD0Ty"

///|
pub let colab_redirect_uri : String = "https://sdk.cloud.google.com/applicationdefaultauthcode.html"

///|
let colab_scopes : Array[String] = [
  "openid", "https://www.googleapis.com/auth/userinfo.profile", "https://www.googleapis.com/auth/userinfo.email",
  "https://www.googleapis.com/auth/cloud-platform", "https://www.googleapis.com/auth/colaboratory",
  "https://www.googleapis.com/auth/drive.file",
]

///|
let colab_required_scope : String = "https://www.googleapis.com/auth/colaboratory"

///|
let colab_refresh_margin_ms : Double = 60_000.0

///|
let colab_fetch_timeout_ms : Int = 20_000

///|
/// Where Google and Colab are (`ColabUrls`): the context's `colabAuth`, `colabToken`, `colabUserinfo`, `colab` where
/// it names them (a test's), else Google's own.
pub(all) struct ColabUrls {
  auth : String
  token : String
  userinfo : String
  colab : String
}

///|
pub fn colab_urls(ctx : Ctx) -> ColabUrls {
  {
    auth: ctx.url("colabAuth").unwrap_or("https://accounts.google.com/o/oauth2/auth"),
    token: ctx.url("colabToken").unwrap_or("https://oauth2.googleapis.com/token"),
    userinfo: ctx.url("colabUserinfo").unwrap_or("https://www.googleapis.com/oauth2/v2/userinfo"),
    colab: ctx.url("colab").unwrap_or("https://colab.research.google.com"),
  }
}

///|
/// `ColabAuth`.
pub(all) struct ColabAuth {
  token : String
  refresh_token : String
  token_uri : String
  client_id : String
  client_secret : String
  scopes : Array[String]
  expiry : String?
  email : String?
}

///|
pub fn ColabAuth::to_jv(self : ColabAuth) -> JV {
  jobj([
    ("token", js(self.token)),
    ("refresh_token", js(self.refresh_token)),
    ("token_uri", js(self.token_uri)),
    ("client_id", js(self.client_id)),
    ("client_secret", js(self.client_secret)),
    ("scopes", jstrs(self.scopes)),
    ("expiry", jopt(self.expiry)),
    ("email", jopt(self.email)),
  ])
}

///|
/// `readColabAuth`'s reading of the file's text: none where it holds no token at all.
pub fn colab_auth_in(text : String) -> ColabAuth? {
  let raw = try_parse(text)
  guard raw is Some(Obj(_) as o) else { return None }
  let text_at = (k : String) => match o.get(k) {
    Some(Str(s)) => s
    _ => ""
  }
  let token = text_at("token")
  let refresh_token = text_at("refresh_token")
  if token == "" && refresh_token == "" {
    return None
  }
  let scopes = match o.get("scopes") {
    Some(Arr(xs)) =>
      xs.filter_map(x => match x {
        Str(s) if s != "" => Some(s)
        _ => None
      })
    _ => []
  }
  let or_default = (k : String, d : String) => {
    let v = text_at(k)
    if v == "" {
      d
    } else {
      v
    }
  }
  let expiry = text_at("expiry")
  let email = trim_js(text_at("email"))
  Some({
    token,
    refresh_token,
    token_uri: or_default("token_uri", "https://oauth2.googleapis.com/token"),
    client_id: or_default("client_id", colab_client_id),
    client_secret: or_default("client_secret", colab_client_secret),
    scopes,
    expiry: if expiry == "" { None } else { Some(expiry) },
    email: if email == "" { None } else { Some(email) },
  })
}

///|
pub async fn read_colab_auth(io : Io, home : String) -> ColabAuth? {
  match io.read_file_or_none(join_path([home, colab_auth_file])) {
    Some(text) => colab_auth_in(text)
    None => None
  }
}

///|
pub async fn write_colab_auth(io : Io, home : String, auth : ColabAuth) -> Unit {
  io.write_private(join_path([home, colab_auth_file]), stringify_pretty(auth.to_jv()) + "\n")
}

///|
/// A sign-in's PKCE: its `state`, its code's verifier and the verifier's challenge (S256), of `random`'s bytes.
pub(all) struct ColabPkce {
  state : String
  verifier : String
  challenge : String
}

///|
pub fn colab_pkce(random : (Int) -> Bytes) -> ColabPkce {
  let state = base64url(random(24))
  let verifier = base64url(random(32))
  let challenge = base64url(@hash.sha256(@utf8.encode(verifier)))
  { state, verifier, challenge }
}

///|
/// `colabAuthorizeUrl`: Google's page that asks the person to approve, its code shown on `colab_redirect_uri`.
pub fn colab_authorize_url(urls : ColabUrls, pkce : ColabPkce, email : String?) -> String {
  let params = [
    ("response_type", "code"),
    ("redirect_uri", colab_redirect_uri),
    ("client_id", colab_client_id),
    ("scope", colab_scopes.join(" ")),
    ("access_type", "offline"),
    ("prompt", "consent"),
    ("token_usage", "remote"),
    ("state", pkce.state),
    ("code_challenge", pkce.challenge),
    ("code_challenge_method", "S256"),
  ]
  match email {
    Some(e) if trim_js(e) != "" => params.push(("login_hint", trim_js(e)))
    _ => ()
  }
  let query = params.map(p => form_encode(p.0) + "=" + form_encode(p.1)).join("&")
  let sep = if urls.auth.contains("?") { "&" } else { "?" }
  urls.auth + sep + query
}

///|
/// An address cut at its query and fragment: what comes before, and its query's parameters (form-decoded).
fn colab_url_parts(url : String) -> (String, Array[(String, String)]) {
  let no_hash = match url.find("#") {
    Some(i) => slice(url, 0, b=i)
    None => url
  }
  guard no_hash.find("?") is Some(q) else { return (no_hash, []) }
  let base = slice(no_hash, 0, b=q)
  let query = slice(no_hash, q + 1)
  let params = []
  for part in query.split("&") {
    let part = part.to_owned()
    if part == "" {
      continue
    }
    let (k, v) = match part.find("=") {
      Some(i) => (slice(part, 0, b=i), slice(part, i + 1))
      None => (part, "")
    }
    params.push((@url.percent_decode_lossy(k, plus_space=true), @url.percent_decode_lossy(v, plus_space=true)))
  }
  (base, params)
}

///|
fn colab_param(params : Array[(String, String)], name : String) -> String {
  match params.search_by(p => p.0 == name) {
    Some(i) => trim_js(params[i].1)
    None => ""
  }
}

///|
fn colab_web_address(s : String) -> Bool {
  let l = s.to_lower()
  l.has_prefix("http://") || l.has_prefix("https://")
}

///|
/// `colabCodeOf`: the code in what the person pasted, the code itself or Google's whole address with it; else the
/// words of why not (`Err`).
pub fn colab_code_of(words : Words, raw : String, expected_state : String, lang : String) -> Result[String, String] {
  let trimmed = trim_js(raw)
  if trimmed == "" {
    return Err(words.tr(lang, "station.login.emptyCode"))
  }
  if !colab_web_address(trimmed) {
    return Ok(trimmed)
  }
  let (_, params) = colab_url_parts(trimmed)
  let error = colab_param(params, "error")
  if error != "" {
    return Err(words.tr(lang, "station.colab.oauthError", args=[("error", error)]))
  }
  let code = colab_param(params, "code")
  let state = colab_param(params, "state")
  if code == "" {
    return Err(words.tr(lang, "station.colab.invalidCode"))
  }
  if state != "" && expected_state != "" && state != expected_state {
    return Err(words.tr(lang, "station.colab.wrongState"))
  }
  Ok(code)
}

///|
fn colab_no_trailing_slashes(s : String) -> String {
  let mut end = s.length()
  while end > 0 && s.unsafe_charcode_at(end - 1) == '/' {
    end -= 1
  }
  slice(s, 0, b=end)
}

///|
/// `colabCallbackCode`: the code of the station's browser's tab where it landed on Google's page for it, of this
/// sign-in (its `state`).
pub fn colab_callback_code(tab_url : String?, expected_state : String) -> String? {
  guard tab_url is Some(url) && colab_web_address(url) else { return None }
  let (base, params) = colab_url_parts(url)
  if colab_no_trailing_slashes(base).to_lower() != colab_no_trailing_slashes(colab_redirect_uri) {
    return None
  }
  let code = colab_param(params, "code")
  if code == "" {
    return None
  }
  if expected_state != "" && colab_param(params, "state") != expected_state {
    return None
  }
  Some(code)
}

///|
/// `oauthErrorText`.
fn colab_oauth_error_text(status : Int, body : JV) -> String {
  let said = (k : String) => match body.get(k) {
    Some(Str(s)) if trim_js(s) != "" => Some(trim_js(s))
    _ => None
  }
  match (said("error"), said("error_description")) {
    (Some(e), Some(d)) => "\{e}: \{d}"
    (None, Some(d)) => d
    (Some(e), None) => e
    (None, None) => "HTTP \{status}"
  }
}

///|
fn colab_scopes_of(raw : JV?) -> Array[String] {
  match raw {
    Some(Str(s)) => s.split(" ").map(x => trim_js(x.to_owned())).filter(x => x != "").collect()
    Some(Arr(xs)) =>
      xs.filter_map(x => match x {
        Str(s) if s != "" => Some(s)
        _ => None
      })
    _ => []
  }
}

///|
fn colab_expiry(expires_in : JV?, now : Double) -> String? {
  match expires_in {
    Some(Num(s)) if !s.is_nan() && !s.is_inf() && s > 0.0 => @jsjson.js_iso_checked(now + s * 1000.0)
    _ => None
  }
}

///|
fn colab_text(body : JV, k : String) -> String {
  match body.get(k) {
    Some(Str(s)) => trim_js(s)
    _ => ""
  }
}

///|
/// `exchangeColabCode`: the code exchanged for tokens, who signed in asked of Google (left out where it does not
/// answer); raises the words of why not.
pub async fn exchange_colab_code(
  ctx : Ctx,
  code : String,
  verifier : String,
  lang : String,
  now : Double,
) -> ColabAuth {
  let urls = colab_urls(ctx)
  let (status, body) = ctx.io.post_form(
    urls.token,
    [
      ("code", code),
      ("client_id", colab_client_id),
      ("client_secret", colab_client_secret),
      ("redirect_uri", colab_redirect_uri),
      ("grant_type", "authorization_code"),
      ("code_verifier", verifier),
    ],
    [],
  )
  guard status >= 200 && status < 300 && body is Obj(_) else {
    raise plain_error(
      ctx.tr(lang, "station.colab.oauthError", args=[("error", colab_oauth_error_text(status, body))]),
    )
  }
  let access = colab_text(body, "access_token")
  let refresh = colab_text(body, "refresh_token")
  let scopes = colab_scopes_of(body.get("scope"))
  if access == "" || refresh == "" {
    raise plain_error(ctx.tr(lang, "station.colab.missingTokens"))
  }
  if !scopes.contains(colab_required_scope) {
    raise plain_error(ctx.tr(lang, "station.colab.missingScope"))
  }
  // Who it is only names the profile: a sign-in still works where Google does not say.
  let email = try {
    let info = ctx.io.get(
      urls.userinfo,
      [("authorization", "Bearer \{access}"), ("accept", "application/json")],
      colab_fetch_timeout_ms,
    )
    if info.ok() {
      let e = colab_text(info.json(), "email")
      if e == "" {
        None
      } else {
        Some(e)
      }
    } else {
      None
    }
  } catch {
    _ => None
  }
  {
    token: access,
    refresh_token: refresh,
    token_uri: urls.token,
    client_id: colab_client_id,
    client_secret: colab_client_secret,
    scopes,
    expiry: colab_expiry(body.get("expires_in"), now),
    email,
  }
}

///|
/// `TokenResult`.
priv enum ColabToken {
  Token(String, ColabAuth)
  /// Whether it is signed out (to sign in again), and why.
  NoToken(Bool, String)
}

///|
fn colab_token_expired(ctx : Ctx, expiry : String?, now : Double) -> Bool {
  match expiry {
    None => false
    Some(e) =>
      match date_parse(e, ctx.tz_offset_ms) {
        Some(ms) => ms - now <= colab_refresh_margin_ms
        None => true
      }
  }
}

///|
/// `ensureColabToken`: the access token, renewed (and written) where it runs out within a minute or `force`.
async fn ensure_colab_token(ctx : Ctx, home : String, now : Double, force : Bool) -> ColabToken {
  guard read_colab_auth(ctx.io, home) is Some(auth) else { return NoToken(true, "no credentials") }
  if !force && auth.token != "" && !colab_token_expired(ctx, auth.expiry, now) {
    return Token(auth.token, auth)
  }
  if auth.refresh_token == "" {
    return NoToken(true, "missing refresh token")
  }
  let (status, body) = ctx.io.post_form(
    colab_urls(ctx).token,
    [
      ("client_id", auth.client_id),
      ("client_secret", auth.client_secret),
      ("refresh_token", auth.refresh_token),
      ("grant_type", "refresh_token"),
    ],
    [],
  ) catch {
    e => return NoToken(false, message_of(e))
  }
  if status == 401 || colab_text(body, "error") == "invalid_grant" {
    return NoToken(true, colab_oauth_error_text(status, body))
  }
  let access = colab_text(body, "access_token")
  if status < 200 || status >= 300 || access == "" {
    return NoToken(false, colab_oauth_error_text(status, body))
  }
  let granted = colab_scopes_of(body.get("scope"))
  let refresh = colab_text(body, "refresh_token")
  let next = {
    ..auth,
    token: access,
    refresh_token: if refresh == "" { auth.refresh_token } else { refresh },
    scopes: if granted.length() > 0 { granted } else { auth.scopes },
    expiry: match colab_expiry(body.get("expires_in"), now) {
      Some(_) as e => e
      None => auth.expiry
    },
  }
  write_colab_auth(ctx.io, home, next)
  Token(next.token, next)
}

///|
/// `CcuInfo`.
priv struct ColabCcu {
  balance : Double
  rate : Double
  assignments : Int
}

///|
/// `CcuResult`.
priv enum ColabCcuAnswer {
  Ccu(ColabCcu)
  /// Its status (none where it did not answer), whether it is signed out, why.
  NoCcu(Int?, Bool, String)
}

///|
fn colab_strip_xssi(raw : String) -> String {
  if raw.has_prefix(")]}'\n") {
    slice(raw, 5)
  } else if raw.has_prefix(")]}'\r\n") {
    slice(raw, 6)
  } else if raw.has_prefix(")]}'") {
    slice(raw, 4).trim_start(chars=" \t\r\n").to_owned()
  } else {
    raw
  }
}

///|
/// `fetchCcuInfo`.
async fn fetch_colab_ccu(ctx : Ctx, token : String) -> ColabCcuAnswer {
  let base = colab_no_trailing_slashes(colab_urls(ctx).colab)
  let response = ctx.io.get(
    "\{base}/tun/m/ccu-info?authuser=0",
    [("authorization", "Bearer \{token}"), ("accept", "application/json"), ("x-colab-client-agent", "colab-cli")],
    colab_fetch_timeout_ms,
  ) catch {
    e => return NoCcu(None, false, message_of(e))
  }
  if response.status == 401 || response.status == 403 {
    return NoCcu(Some(response.status), true, "HTTP \{response.status}")
  }
  if !response.ok() {
    return NoCcu(Some(response.status), false, "HTTP \{response.status}")
  }
  let parsed = json_parse(colab_strip_xssi(response.text)) catch {
    e => return NoCcu(Some(response.status), false, message_of(e))
  }
  let num = (k : String) => match parsed.get(k) {
    Some(Num(n)) if !n.is_nan() && !n.is_inf() => n
    _ => 0.0
  }
  let assignments = match parsed.get("assignmentsCount") {
    Some(Num(n)) if !n.is_nan() && !n.is_inf() => if n > 0.0 { n.to_int() } else { 0 }
    _ =>
      match parsed.get("assignments") {
        Some(Arr(xs)) => xs.length()
        _ => 0
      }
  }
  Ccu({ balance: num("currentBalance"), rate: num("consumptionRateHourly"), assignments })
}

///|
priv enum ColabQuery {
  Answered(ColabCcu, ColabAuth)
  MissingScope
  /// Whether it is signed out, why.
  Unanswered(Bool, String)
}

///|
fn colab_lacks_scope(auth : ColabAuth) -> Bool {
  auth.scopes.length() > 0 && !auth.scopes.contains(colab_required_scope)
}

///|
/// `queryCcuWithRefresh`: asked with the token it has, asked again once renewed where Colab said 401.
async fn colab_query(ctx : Ctx, home : String, now : Double) -> ColabQuery {
  let (token, auth) = match ensure_colab_token(ctx, home, now, false) {
    Token(t, a) => (t, a)
    NoToken(out, why) => return Unanswered(out, why)
  }
  if colab_lacks_scope(auth) {
    return MissingScope
  }
  match fetch_colab_ccu(ctx, token) {
    Ccu(info) => Answered(info, auth)
    NoCcu(Some(401), _, _) => {
      let (token, auth) = match ensure_colab_token(ctx, home, now, true) {
        Token(t, a) => (t, a)
        NoToken(out, why) => return Unanswered(out, why)
      }
      if colab_lacks_scope(auth) {
        return MissingScope
      }
      match fetch_colab_ccu(ctx, token) {
        Ccu(info) => Answered(info, auth)
        NoCcu(_, out, why) => Unanswered(out, why)
      }
    }
    NoCcu(_, out, why) => Unanswered(out, why)
  }
}

///|
fn colab_check_of(state : String, detail : String) -> JV {
  jobj([("state", js(state)), ("detail", js(detail)), ("models", Null), ("checkedAt", jint(0))])
}

///|
/// The Colab adapter's `check`: signed in (and as whom) where Colab answers with its token.
pub async fn colab_check(ctx : Ctx, home : String, lang : String, now : Double) -> JV {
  guard read_colab_auth(ctx.io, home) is Some(auth) else {
    return colab_check_of("login", ctx.tr(lang, "station.profile.signedOut"))
  }
  if colab_lacks_scope(auth) {
    return colab_check_of("login", ctx.tr(lang, "station.colab.missingScope"))
  }
  match colab_query(ctx, home, now) {
    MissingScope => colab_check_of("login", ctx.tr(lang, "station.colab.missingScope"))
    Unanswered(true, _) => colab_check_of("login", ctx.tr(lang, "station.profile.signedOut"))
    Unanswered(false, why) => colab_check_of("failed", why)
    Answered(_, auth) => {
      let parts = [ctx.tr(lang, "station.profile.signedIn"), auth.email.unwrap_or("")].filter(s => s != "")
      colab_check_of("ok", parts.join(ctx.tr(lang, "station.list.comma")))
    }
  }
}

///|
/// `x.toFixed(2)` of an amount (CU, CU an hour).
fn colab_fixed2(x : Double) -> String {
  let cents = (x.abs() * 100.0).round().to_int64()
  let frac = cents % 100L
  let sign = if x < 0.0 && cents != 0L { "-" } else { "" }
  "\{sign}\{cents / 100L}.\{if frac < 10L { "0" } else { "" }}\{frac}"
}

///|
/// The Colab adapter's `quota`: its Compute Units left, and what its running VMs use an hour.
pub async fn colab_quota(ctx : Ctx, home : String, lang : String, now : Double) -> JV {
  match colab_query(ctx, home, now) {
    MissingScope =>
      jset(quota("unavailable", [], Some(ctx.tr(lang, "station.colab.missingScope"))), "signedOut", jbool(true))
    Unanswered(true, _) =>
      jset(quota("unavailable", [], Some(ctx.tr(lang, "station.quota.signInExpired"))), "signedOut", jbool(true))
    Unanswered(false, why) => unanswered_quota(why)
    Answered(info, _) => {
      let detail = if info.assignments > 0 || info.rate > 0.0 {
        Some(
          ctx.tr(lang, "station.colab.activeVms", args=[
            ("n", info.assignments.to_string()),
            ("rate", colab_fixed2(info.rate)),
          ]),
        )
      } else {
        None
      }
      jset(
        quota("ok", [], detail),
        "credits",
        jobj([
          ("hasCredits", jbool(info.balance > 0.0)),
          ("unlimited", jbool(false)),
          ("balance", js("\{colab_fixed2(info.balance)} CU")),
        ]),
      )
    }
  }
}
