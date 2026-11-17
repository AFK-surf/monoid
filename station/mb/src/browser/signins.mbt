// Sign-ins in a chat's browser (src/browser/signins.ts, 登录态): a site's sign-in is its cookies (and its passkeys:
// passkeys.mbt), kept in the vault as an item of kind browser and put into a chat's browser while a grant for it
// lasts. Here: which cookies are a site's, the cookies of a browser as they are set again (DevTools'
// Storage.getCookies gives more than Storage.setCookies takes). A cookie is kept as the JSON DevTools takes
// (Network.CookieParam), its fields in the TypeScript's order.

///|
/// Whether a cookie of `domain` is one of `sites`' (each with its subdomains: github.com takes .github.com and
/// api.github.com, not notgithub.com).
pub fn of_sites(domain : String, sites : Array[String]) -> Bool {
  let l = lower(domain)
  let d = if l.has_prefix(".") { slice(l, 1) } else { l }
  sites.iter().any(s => d == s || d.has_suffix("." + s))
}

///|
/// The cookies among those DevTools read, as they are set again: a session cookie without its expiry.
fn cookies_in(read : J?, keep : ((String) -> Bool)?) -> Array[J] {
  let out = []
  for c in arr(read) {
    let cv = Some(c)
    guard c is Obj(_) else { continue }
    guard at(cv, "name") is Some(Str(_)) &&
      at(cv, "value") is Some(Str(_)) &&
      at(cv, "domain") is Some(Str(_)) else {
      continue
    }
    let domain = text(at(cv, "domain"))
    match keep {
      Some(k) => if !k(domain) { continue }
      None => ()
    }
    let fs : Array[(String, J)] = [
      ("name", at(cv, "name").unwrap()),
      ("value", at(cv, "value").unwrap()),
      ("domain", at(cv, "domain").unwrap()),
      (
        "path",
        match at(cv, "path") {
          Some(Str(_) as p) => p
          _ => js("/")
        },
      ),
    ]
    if at(cv, "secure") is Some(Bool(_) as b) {
      fs.push(("secure", b))
    }
    if at(cv, "httpOnly") is Some(Bool(_) as b) {
      fs.push(("httpOnly", b))
    }
    if at(cv, "sameSite") is Some(Str(_) as s) {
      fs.push(("sameSite", s))
    }
    match at(cv, "expires") {
      Some(Num(e) as x) if !is_true(at(cv, "session")) && e > 0.0 => fs.push(("expires", x))
      _ => ()
    }
    if at(cv, "priority") is Some(Str(_) as s) {
      fs.push(("priority", s))
    }
    if at(cv, "sourceScheme") is Some(Str(_) as s) {
      fs.push(("sourceScheme", s))
    }
    if at(cv, "sourcePort") is Some(Num(_) as n) {
      fs.push(("sourcePort", n))
    }
    match at(cv, "partitionKey") {
      Some(k) => fs.push(("partitionKey", k))
      None => ()
    }
    out.push(jo(fs))
  }
  out
}

///|
/// All cookies among those DevTools read, as they are set again (a profile sign-in's isolated context: browser.mbt).
pub fn all_cookies(read : J?) -> Array[J] {
  cookies_in(read, None)
}

///|
/// The cookies of `sites` among those DevTools read, as they are set again: a session cookie without its expiry.
pub fn site_cookies(read : J?, sites : Array[String]) -> Array[J] {
  cookies_in(read, Some(domain => of_sites(domain, sites)))
}

///|
/// A sign-in as the vault keeps it (the item's `cookies` field): its cookies, as JSON; with its sites' passkeys too
/// (passkeys.mbt), an object of both. One without passkeys stays the cookies alone, as every sign-in was before.
pub(all) struct SignInState {
  cookies : Array[J]
  passkeys : Array[Passkey]
}

///|
/// A sign-in's state read from what the vault keeps: the cookies alone (a list), or both.
pub fn state_of(kept : String) -> SignInState {
  let v : Result[J, Error] = try Ok(parse(kept)) catch { e => Err(e) }
  match v {
    Ok(Arr(xs)) => { cookies: xs, passkeys: [] }
    Ok(o) => {
      let passkeys = arr(at(Some(o), "passkeys")).filter_map(p => passkey_of(Some(p)))
      { cookies: arr(at(Some(o), "cookies")), passkeys }
    }
    Err(_) => { cookies: [], passkeys: [] }
  }
}

///|
pub fn SignInState::to_j(self : SignInState) -> J {
  jo([("cookies", ja(self.cookies)), ("passkeys", ja(self.passkeys.map(p => p.to_j())))])
}

///|
/// What the vault keeps of a sign-in's state: the cookies alone where it has no passkeys.
pub fn kept_of(s : SignInState) -> String {
  if s.passkeys.length() == 0 {
    stringify(ja(s.cookies))
  } else {
    stringify(s.to_j())
  }
}

///|
/// The same cookies set to have expired: setting them so takes them out of the browser.
pub fn expired(cookies : Array[J]) -> Array[J] {
  cookies.map(c => spread(c, jo([("value", js("")), ("expires", ji(1))])))
}

///|
/// A sign-in put into a chat's browser: its request and workspace, sites, and end (unix seconds). Older kept contexts
/// do not have the workspace. `raw`: the record as it was made or read (written back as it is, its end as it is now).
pub(all) struct SignedIn {
  raw : J
  request : String
  workspace : String?
  sites : Array[String]
  mut until : Double
}

///|
pub fn SignedIn::new(request : String, workspace : String?, sites : Array[String], until : Double) -> SignedIn {
  let fs : Array[(String, J)] = [("request", js(request))]
  match workspace {
    Some(w) => fs.push(("workspace", js(w)))
    None => ()
  }
  fs.push(("sites", jsa(sites)))
  fs.push(("until", jn(until)))
  { raw: jo(fs), request, workspace, sites, until }
}

///|
pub fn SignedIn::to_j(self : SignedIn) -> J {
  match at(Some(self.raw), "until") {
    Some(Num(u)) if u == self.until => self.raw
    _ => put(self.raw, "until", jn(self.until))
  }
}

///|
/// A kept sign-in as contexts.json says it.
fn SignedIn::of_j(v : J) -> SignedIn {
  {
    raw: v,
    request: text(at(Some(v), "request")),
    workspace: str_of(at(Some(v), "workspace")),
    sites: arr(at(Some(v), "sites")).map(s => js_str(Some(s))),
    until: js_num(at(Some(v), "until")),
  }
}
