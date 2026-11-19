// A Claude subscription's limit resets (what Claude Code's /limit-reset uses), read and used as the installed Claude
// Code does (station/src/accounts/claude-reset.ts). Its OAuth usage endpoint says them only to Claude Code's own CLI,
// of a version that has them, in two programs: `juniper_tide` (the 5-hour limit reset now, once a week, available
// only at the limit) and `cedar_ember` (resets granted to the account, each grant some resets until a date, usable now
// or once at a limit), both used at POST /api/organizations/<organization>/reset_rate_limits.

///|
let reset_timeout_ms : Int = 25_000

///|
/// The usage read that says the resets as well.
pub let usage_path : String = "/api/oauth/usage?at_wall=1&skip_spend=1"

///|
/// `claudeHeaders`: Claude Code's own headers for its OAuth endpoints.
pub fn claude_headers(token : String, version : String?) -> Array[(String, String)] {
  let h = [
    ("authorization", "Bearer \{token}"),
    ("anthropic-beta", "oauth-2025-04-20"),
  ]
  match version {
    Some(v) => h.push(("user-agent", "claude-cli/\{v} (external, cli)"))
    None => ()
  }
  h
}

///|
fn reset_count_of(v : JV?) -> Double {
  match v {
    Some(Num(n)) if is_integer(n) && n > 0.0 => n
    _ => 0.0
  }
}

///|
fn reset_time(ctx : Ctx, v : JV?) -> Double? {
  match v {
    Some(Str(s)) if s.length() >= 11 &&
      digits_at(s, 0, 4) is Some(_) &&
      s.unsafe_charcode_at(4) == '-'.to_int() &&
      digits_at(s, 5, 2) is Some(_) &&
      s.unsafe_charcode_at(7) == '-'.to_int() &&
      digits_at(s, 8, 2) is Some(_) &&
      s.unsafe_charcode_at(10) == 'T'.to_int() => date_parse(s, ctx.tz_offset_ms)
    _ => None
  }
}

///|
/// The weekly 5-hour reset there to use.
fn tide_ready(tide : JV?) -> Bool {
  match tide {
    Some(Obj(_) as t) =>
      t.get("eligible") == Some(Bool(true)) &&
      t.get("arm") == Some(Str("reset")) &&
      t.get("available") == Some(Bool(true))
    _ => false
  }
}

///|
/// A grant still holding resets.
fn live_grant(g : JV) -> Bool {
  match g {
    Obj(_) =>
      (g.get("id") is Some(Str(_))) &&
      reset_count_of(g.get("resets_left")) > 0.0 &&
      g.get("paused") != Some(Bool(true))
    _ => false
  }
}

///|
/// `grantKind`: a grant's kind, as Claude Code names it.
pub fn grant_kind(g : JV?) -> String {
  if jget(g, "gives_back_weekly") == Some(Bool(true)) ||
    jget(g, "type") == Some(Str("fable")) {
    return "model"
  }
  match jget(g, "type") {
    Some(Str("session" | "weekly" | "full" as t)) => return t
    _ => ()
  }
  let clears = jitems(jget(g, "clears"))
  let session = clears.contains(Str("five_hour"))
  let other = clears.iter().any(c => c != Str("five_hour"))
  if session && !other {
    "session"
  } else if other && !session {
    "weekly"
  } else {
    "full"
  }
}

///|
let reset_order : Array[String] = ["session", "weekly", "model", "full", "credit"]

///|
/// `claudeResets`: the resets a usage answer says the account holds, one entry a kind, in Claude Code's order.
pub fn claude_resets(ctx : Ctx, body : JV?, model : String?) -> Array[JV] {
  let tide = jget(body, "juniper_tide")
  let ember = jget(body, "cedar_ember")
  let kinds : Map[String, JV] = Map::new()
  let add = (kind : String, left : Double, usable : Bool, ends : Double?) => {
    let base = match kinds.get(kind) {
      Some(r) => r
      None => {
        let fields = [("id", js(kind)), ("kind", js(kind))]
        if kind == "model" {
          fields.push(("model", js(model.unwrap_or("Fable"))))
        }
        fields.push(("left", jint(0)))
        fields.push(("usable", jbool(false)))
        jobj(fields)
      }
    }
    let mut r = jset(base, "left", jnum(to_number(base.get("left")) + left))
    r = jset(r, "usable", jbool(base.get("usable") == Some(Bool(true)) || usable))
    match ends {
      Some(e) => {
        let list = jitems(r.get("expiries")).map(x => to_number(Some(x)))
        for _ in 0..<left.to_int() {
          list.push(e)
        }
        stable_sort(list, (a, b) => a - b)
        r = jset(r, "expiries", jarr(list.map(jnum)))
      }
      None => ()
    }
    kinds[kind] = r
  }
  if tide_ready(tide) {
    add("session", 1.0, true, None)
  }
  let grants = match ember {
    Some(Obj(_) as e) if e.get("eligible") == Some(Bool(true)) => jitems(e.get("grants"))
    _ => []
  }
  for g in grants {
    if live_grant(g) {
      add(
        grant_kind(Some(g)),
        reset_count_of(g.get("resets_left")),
        g.get("usable_now") == Some(Bool(true)),
        reset_time(ctx, g.get("ends_at")),
      )
    }
  }
  reset_order.filter_map(k => kinds.get(k))
}

///|
/// What a claim comes to: the claim's JSON, or none to use now ("none"), or none held ("noCredit").
pub(all) enum Claim {
  Use(JV)
  NoneNow
  NoCredit
}

///|
/// `claudeClaim`: the claim a usage answer allows now for a reset of `kind` (None: any).
pub fn claude_claim(ctx : Ctx, body : JV?, key : String, kind : String?) -> Claim {
  let tide = jget(body, "juniper_tide")
  let any_or_session = kind is None || kind == Some("session")
  if any_or_session && tide_ready(tide) {
    return Use(jobj([("program", js("juniper_tide"))]))
  }
  let ember = jget(body, "cedar_ember")
  let grants = (match ember {
    Some(Obj(_) as e) if e.get("eligible") == Some(Bool(true)) =>
      jitems(e.get("grants")).filter(live_grant)
    _ => []
  }).filter(g => match kind {
    None => true
    Some(k) => grant_kind(Some(g)) == k
  })
  let usable = grants.filter(g => g.get("usable_now") == Some(Bool(true)))
  stable_sort(usable, (a, b) => reset_time(ctx, a.get("ends_at")).unwrap_or(@double.infinity) -
    reset_time(ctx, b.get("ends_at")).unwrap_or(@double.infinity))
  let next = jget(ember, "next_grant_id")
  let grant = match usable.iter().find_first(g => g.get("id") == next && next is Some(_)) {
    Some(g) => Some(g)
    None => usable.get(0)
  }
  match grant {
    Some(g) =>
      Use(
        jobj([
          ("program", js("cedar_ember")),
          ("grant_id", g.get("id").unwrap_or(Null)),
          ("request_id", js(@hash.sha256_utf8_hex(key))),
        ]),
      )
    None =>
      if grants.length() > 0 ||
        (
          any_or_session &&
          (match tide {
            Some(Obj(_) as t) => t.get("eligible") == Some(Bool(true))
            _ => false
          })
        ) {
        NoneNow
      } else {
        NoCredit
      }
  }
}

///|
/// `claimOutcome`: what a claim's answer means to the station.
pub fn claim_outcome(result : JV?) -> String {
  match result {
    Some(Str("reset")) => "reset"
    Some(Str("already_used")) => "alreadyRedeemed"
    Some(Str("not_limited")) => "nothingToReset"
    Some(Str("cooldown" | "ineligible")) => "unavailable"
    _ => "unconfirmed"
  }
}

///|
fn org_ok(s : String) -> Bool {
  s.length() >= 1 &&
  s.length() <= 64 &&
  s
  .iter()
  .all(c => (c >= 'A' && c <= 'Z') ||
    (c >= 'a' && c <= 'z') ||
    (c >= '0' && c <= '9') ||
    c == '-')
}

///|
/// `claudeResetWith`: uses one of the account's resets with `token`. `{outcome}`, or `{unauthorized: true}` when the
/// provider said the token is not good.
pub async fn claude_reset_with(
  ctx : Ctx,
  base : String,
  token : String,
  version : String,
  key : String,
  kind : String?,
) -> JV {
  let headers = claude_headers(token, Some(version))
  let ask = async fn(path : String, body : JV?) -> Response {
    match body {
      Some(b) => {
        let h = headers.copy()
        h.push(("content-type", "application/json"))
        ctx.io.fetch({
          url: "\{base}\{path}",
          verb: Some("POST"),
          headers: h,
          body: Some(stringify(b)),
          timeout_ms: reset_timeout_ms,
        })
      }
      None =>
        ctx.io.fetch({
          url: "\{base}\{path}",
          verb: None,
          headers,
          body: None,
          timeout_ms: reset_timeout_ms,
        })
    }
  }
  let unauthorized = jobj([("unauthorized", jbool(true))])
  let usage = ask(usage_path, None)
  if usage.status == 401 {
    return unauthorized
  }
  if !usage.ok() {
    raise plain_error("Anthropic \{usage.status}")
  }
  let claim = match claude_claim(ctx, try_parse(usage.text), key, kind) {
    NoneNow => return jobj([("outcome", js("nothingToReset"))])
    NoCredit => return jobj([("outcome", js("noCredit"))])
    Use(c) => c
  }
  let profile = ask("/api/oauth/profile", None)
  if profile.status == 401 {
    return unauthorized
  }
  let organization = jget(jget(try_parse(profile.text), "organization"), "uuid")
  let org = match organization {
    Some(Str(o)) if profile.ok() && org_ok(o) => o
    _ =>
      raise plain_error(
        "Anthropic did not say the account's organization (\{profile.status})",
      )
  }
  let answer = ask("/api/organizations/\{org}/reset_rate_limits", Some(claim))
  if answer.status == 401 {
    return unauthorized
  }
  if answer.status == 429 {
    return jobj([("outcome", js("unavailable"))])
  }
  if !answer.ok() {
    raise plain_error("Anthropic \{answer.status}")
  }
  jobj([
    ("outcome", js(claim_outcome(jget(try_parse(answer.text), "result")))),
  ])
}
