// How much of a profile's allowance is used, where the provider says (station/src/accounts/quota.ts):
// - OpenCode Go: GET /zen/go/v1/usage (rolling, weekly and monthly windows);
// - Kimi Code (its key, or a Kimi sign-in's current token): GET /coding/v1/usages, as kimi-cli's /usage reads it;
// - ChatGPT subscription (Codex): the app-server's account/rateLimits/read, its details read of ChatGPT's backend;
// - Claude subscription: Claude Code's OAuth usage endpoint, with the token Claude Code keeps in the profile's home
//   (renewed by station/src/accounts/oauth.ts, asked of it), a model's own week apart in `scoped`, the limit resets;
// - Antigravity CLI: agy_quota.mbt; Grok Build: its `x.ai/billing`, asked of a `grok agent stdio` started for it;
// - MiniMax Token Plan and GLM Coding Plan (China): their usage endpoints, asked with the profile's key;
// - Anthropic API keys and other providers bill per use and have no allowance to show.

///|
let quota_timeout_ms : Int = 15_000

///|
let day_minutes : Double = 1440.0

///|
let week_minutes : Double = 10080.0

///|
/// What the accounts' IO and words are: the parts, the words, where the providers are, the station's language, and
/// the offset of the machine's local time at a moment (what Date.parse reads a time with no zone by).
pub(all) struct Ctx {
  io : Io
  words : Words
  urls : JV
  station_lang : String
  tz_offset_ms : (Double) -> Double
}

///|
pub fn Ctx::tr(
  self : Ctx,
  lang : String,
  key : String,
  args? : Array[(String, String)] = [],
) -> String {
  self.words.tr(lang, key, args~)
}

///|
pub fn Ctx::url(self : Ctx, k : String) -> String? {
  jstr(self.urls.get(k))
}

///|
/// `quota(state, windows, detail)`: `checkedAt` stamped by whoever keeps it.
pub fn quota(state : String, windows : Array[JV], detail : String?) -> JV {
  jobj([
    ("state", js(state)),
    ("windows", jarr(windows)),
    ("detail", jopt(detail)),
    ("checkedAt", jint(0)),
  ])
}

///|
/// `okOrUnavailable`.
pub fn ok_or_unavailable(windows : Array[JV], empty : String) -> JV {
  if windows.length() == 0 {
    quota("unavailable", [], Some(empty))
  } else {
    quota("ok", windows, None)
  }
}

///|
fn digits_at(s : String, i : Int, n : Int) -> Int? {
  if i + n > s.length() {
    return None
  }
  let mut v = 0
  for k in i..<(i + n) {
    let c = s.unsafe_charcode_at(k)
    if c < '0'.to_int() || c > '9'.to_int() {
      return None
    }
    v = v * 10 + (c - '0'.to_int())
  }
  Some(v)
}

///|
/// `Date.parse` of a date and time as ISO 8601 writes it (V8's: a fraction of any length cut to milliseconds, `Z`,
/// `z`, `±HH:MM` or `±HHMM`, `24:00:00` the next day, a day up to 31 whatever the month; no zone: local time, by
/// `tz_offset_ms`). None for anything else.
pub fn date_parse(text : String, tz_offset_ms : (Double) -> Double) -> Double? {
  guard text.length() >= 16 &&
    text.unsafe_get(4).to_int() == '-' &&
    text.unsafe_get(7).to_int() == '-' &&
    text.unsafe_get(10).to_int() == 'T' &&
    text.unsafe_get(13).to_int() == ':' else {
    return None
  }
  @jsjson.js_parse_iso(text, tz_offset_ms~)
}

///|
/// `parseIso` (transcript.rs parse_iso): an RFC 3339 time, as epoch ms.
fn parse_iso(ctx : Ctx, text : String) -> Double? {
  // `/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/` first
  if text.length() < 19 ||
    digits_at(text, 17, 2) is None ||
    text.unsafe_charcode_at(16) != ':'.to_int() {
    return None
  }
  date_parse(text, ctx.tz_offset_ms)
}

///|
/// `at`: a time as a provider gives it: epoch seconds or ms, or an ISO string.
pub fn at(ctx : Ctx, value : JV?) -> Double? {
  match value {
    Some(Num(n)) => if n > 1.0e12 { Some(trunc(n)) } else { Some(trunc(n * 1000.0)) }
    Some(Str(s)) if s != "" => parse_iso(ctx, s)
    _ => None
  }
}

///|
/// `Math.trunc`.
pub fn trunc(n : Double) -> Double {
  if n.is_nan() || n.is_inf() {
    n
  } else if n < 0.0 {
    -(-n).floor()
  } else {
    n.floor()
  }
}

///|
fn sign(n : Double) -> Double {
  if n > 0.0 {
    1.0
  } else if n < 0.0 {
    -1.0
  } else {
    n
  }
}

///|
/// Rust's round: halves away from zero.
fn round_half_away(n : Double) -> Double {
  sign(n) * js_round(n.abs())
}

///|
/// `percent`: a provider's percentage, rounded, 0–100.
pub fn percent(value : JV?) -> Double {
  let mut n = 0.0
  match value {
    Some(Num(x)) => n = x
    Some(Str(s)) => {
      let t = trim_js(s)
      let parsed = js_number(t)
      n = if t != "" && !parsed.is_nan() && !parsed.is_inf() {
        parsed
      } else {
        0.0
      }
    }
    _ => ()
  }
  let rounded = round_half_away(n)
  js_min(100.0, js_max(0.0, rounded))
}

///|
/// `windowLabel`: a window's label (not translated: cores read them).
pub fn window_label(minutes : Double?, fallback : String) -> String {
  guard minutes is Some(m) && m > 0.0 else { return fallback }
  if m <= 360.0 {
    return "\{num_text(round_half_away(m / 60.0))} 小时"
  }
  if m >= 60.0 * 24.0 * 6.0 && m <= 60.0 * 24.0 * 8.0 {
    return "每周"
  }
  if m >= 60.0 * 24.0 * 27.0 {
    return "每月"
  }
  "\{num_text(round_half_away(m / 60.0 / 24.0))} 天"
}

///|
/// `blocked`: whether a provider's words refuse an account itself.
pub fn blocked(text : String) -> Bool {
  let l = lower(text)
  [
    "on hold", "restricted", "suspend", "disabled", "deactivat", "banned", "terminated",
    "violat",
  ].iter().any(w => l.contains(w))
}

///|
/// `message`: a provider's error body, in a line when it has one.
fn provider_message(text : String) -> String? {
  guard try_parse(text) is Some(body) else { return None }
  let error = body.get("error")
  let mut said : JV? = match error {
    Some(Str(_)) => error
    None | Some(Null) => None
    Some(e) => e.get("message")
  }
  if !(said is Some(Str(_))) {
    said = match body.get("detail") {
      Some(Str(_)) as d => d
      _ =>
        match body.get("message") {
          Some(Str(_)) as m => m
          _ => None
        }
    }
  }
  match said {
    Some(Str(s)) => Some(chars(s, 200))
    _ => None
  }
}

///|
/// A status that is the provider's own trouble or its asking to be asked later.
fn troubled(status : Int) -> Bool {
  status == 429 || status >= 500
}

///|
/// `refused`: a provider's refusal as a quota: the account refused (blocked), or its sign-in no longer good.
pub fn refused(
  ctx : Ctx,
  provider : String,
  response : Response,
  lang : String,
) -> JV {
  let status = response.status
  let text = chars(response.text, 500)
  if blocked(text) || status == 403 {
    let detail = match provider_message(text) {
      Some(said) =>
        ctx.tr(lang, "station.quota.refusedSaying", args=[
          ("provider", provider),
          ("status", status.to_string()),
          ("said", said),
        ])
      None =>
        ctx.tr(lang, "station.quota.refused", args=[
          ("provider", provider),
          ("status", status.to_string()),
        ])
    }
    return quota("blocked", [], Some(detail))
  }
  if status == 401 {
    return quota("unavailable", [], Some(ctx.tr(lang, "station.quota.signInExpired")))
  }
  let q = quota(
    "unavailable",
    [],
    Some(
      ctx.tr(lang, "station.quota.providerStatus", args=[
        ("provider", provider),
        ("status", status.to_string()),
      ]),
    ),
  )
  if troubled(status) {
    jset(q, "unanswered", jbool(true))
  } else {
    q
  }
}

///|
/// What a question that got no answer leaves.
fn unanswered_quota(detail : String) -> JV {
  jset(quota("unavailable", [], Some(detail)), "unanswered", jbool(true))
}

///|
fn quota_window(
  label : String,
  used : Double,
  resets_at : Double?,
  minutes : Double?,
  scope? : String,
) -> JV {
  let fields = [
    ("label", js(label)),
    ("usedPercent", jnum(used)),
    (
      "resetsAt",
      match resets_at {
        Some(r) => jnum(r)
        None => Null
      },
    ),
    (
      "minutes",
      match minutes {
        Some(m) => jnum(m)
        None => Null
      },
    ),
  ]
  if scope is Some(s) {
    fields.push(("scope", js(s)))
  }
  jobj(fields)
}

///|
async fn opencode(ctx : Ctx, key : String, lang : String) -> JV {
  let response = ctx.io.get(
    "\{ctx.url("opencode").unwrap_or("")}/v1/usage",
    [("authorization", "Bearer \{key}")],
    quota_timeout_ms,
  )
  if !response.ok() {
    raise plain_error(
      ctx.tr(lang, "station.quota.providerStatus", args=[
        ("provider", "OpenCode Go "),
        ("status", response.status.to_string()),
      ]),
    )
  }
  let body = response.json()
  let usage = body.get("usage")
  let windows = match usage {
    Some(Obj(fields)) =>
      fields.map(f => {
        let (label, length) = match f.0 {
          "rolling" => ("5 小时", Some(300.0))
          "weekly" => ("每周", Some(week_minutes))
          "monthly" => ("每月", Some(30.0 * day_minutes))
          k => (k, None)
        }
        quota_window(
          label,
          percent(f.1.get("percent")),
          at(ctx, f.1.get("resetsAt")),
          length,
        )
      })
    _ => []
  }
  quota("ok", windows, None)
}

///|
/// `claudeWithRefresh`: a Claude subscription's allowance with its token; asked again once with a renewed token when
/// the provider says the token is not good. `home`: the profile's (None: the machine's own login).
pub async fn claude_with_refresh(
  ctx : Ctx,
  home : String?,
  lang : String,
  version : String?,
) -> JV {
  let token_url = ctx.url("claudeToken").unwrap_or("")
  let token = claude_oauth_token(ctx, home, None, token_url, lang, claude_version?=version)
  let (first, unauthorized) = claude_usage_response(
    ctx,
    ctx.url("anthropic").unwrap_or(""),
    token.0,
    lang,
    version,
  )
  if !unauthorized {
    return first
  }
  let renewed = claude_oauth_token(ctx, home, Some(token.0), token_url, lang, claude_version?=version)
  let (second, still_unauthorized) = claude_usage_response(
    ctx,
    ctx.url("anthropic").unwrap_or(""),
    renewed.0,
    lang,
    version,
  )
  if still_unauthorized {
    jset(second, "signedOut", jbool(true))
  } else {
    second
  }
}

///|
/// oauth.ts `claudeOAuthToken`, asked of it: the token and when it runs out.
pub async fn claude_oauth_token(
  ctx : Ctx,
  home : String?,
  rejected : String?,
  token_url : String,
  lang : String,
  margin? : Double,
  lent? : Bool = false,
  claude_version? : String,
) -> (String, Double) {
  let args = [jopt(home), jopt(rejected), js(token_url), js(lang)]
  match margin {
    Some(m) => args.push(jnum(m))
    None => args.push(jundef)
  }
  args.push(jbool(lent))
  args.push(jopt(claude_version))
  let a = ctx.io.b.ask("oauth.claudeOAuthToken", args)
  let items = jitems(Some(a))
  (
    js_string(items.get(0)),
    jnumber(items.get(1)).unwrap_or(0.0),
  )
}

///|
/// `claudeUsage`: a Claude subscription's allowance, by its access token.
pub async fn claude_usage(
  ctx : Ctx,
  base : String,
  token : String,
  lang : String,
  version : String?,
) -> JV {
  claude_usage_response(ctx, base, token, lang, version).0
}

///|
async fn claude_usage_response(
  ctx : Ctx,
  base : String,
  token : String,
  lang : String,
  version : String?,
) -> (JV, Bool) {
  let path = match version {
    Some(_) => usage_path
    None => "/api/oauth/usage"
  }
  let response = ctx.io.get(
    "\{base}\{path}",
    claude_headers(token, version),
    quota_timeout_ms,
  )
  if !response.ok() {
    // An account the provider refuses stays blocked; otherwise a 401 or a 403 is the OAuth token refused (one revoked
    // is answered 403, FB-44): renewed and asked again, then the login is over.
    if !blocked(chars(response.text, 500)) && (response.status == 401 || response.status == 403) {
      return (quota("unavailable", [], Some(ctx.tr(lang, "station.quota.signInExpired"))), true)
    }
    return (refused(ctx, "Anthropic ", response, lang), false)
  }
  let body = response.json()
  let windows = match body {
    Obj(fields) =>
      fields.filter_map(f => {
        let label = match f.0 {
          "five_hour" => Some("5 小时")
          "seven_day" => Some("每周")
          "seven_day_opus" => Some("每周 · Opus")
          "seven_day_sonnet" => Some("每周 · Sonnet")
          _ => None
        }
        match (label, f.1) {
          (Some(l), Obj(_) as w) =>
            Some(
              quota_window(
                l,
                percent(w.get("utilization")),
                at(ctx, w.get("resets_at")),
                Some(if f.0 == "five_hour" { 300.0 } else { week_minutes }),
              ),
            )
          _ => None
        }
      })
    _ => []
  }
  let mut q = quota("ok", windows, None)
  let labelled = (s : JV) => windows.iter().any(w => w.get("label") == s.get("label"))
  let scoped = claude_scoped(ctx, body.get("limits")).filter(s => !labelled(s))
  if scoped.length() > 0 {
    q = jset(q, "scoped", jarr(scoped))
  }
  match jget(body.get("extra_usage"), "is_enabled") {
    Some(Bool(b)) => q = jset(q, "extraUsage", jbool(b))
    _ => ()
  }
  let resets = match version {
    Some(_) =>
      claude_resets(
        ctx,
        Some(body),
        if scoped.length() == 1 {
          jstr(scoped[0].get("scope"))
        } else {
          None
        },
      )
    None => []
  }
  if resets.length() > 0 {
    q = with_resets(q, resets)
  }
  (q, false)
}

///|
/// `withResets`: the resets of each kind, and their count and expiries all together.
fn with_resets(q : JV, resets : Array[JV]) -> JV {
  let mut o = jset(q, "resets", jarr(resets))
  let mut count = 0.0
  let expiries : Array[Double] = []
  for r in resets {
    count = count + to_number(r.get("left"))
    for e in jitems(r.get("expiries")) {
      expiries.push(to_number(Some(e)))
    }
  }
  o = jset(o, "resetCount", jnum(count))
  if expiries.length() > 0 {
    stable_sort(expiries, (a, b) => a - b)
    o = jset(o, "resetExpiries", jarr(expiries.map(jnum)))
  }
  o
}

///|
/// `claudeScoped`: the weeks one model has to itself under the account's.
fn claude_scoped(ctx : Ctx, limits : JV?) -> Array[JV] {
  guard limits is Some(Arr(items)) else { return [] }
  items.filter_map(l => {
    let name = jget(jget(jget(Some(l), "scope"), "model"), "display_name")
    match name {
      Some(Str(n)) if l.get("group") == Some(Str("weekly")) && trim_js(n) != "" =>
        Some(
          quota_window(
            "每周 · \{trim_js(n)}",
            percent(l.get("percent")),
            at(ctx, l.get("resets_at")),
            Some(week_minutes),
            scope=trim_js(n),
          ),
        )
      _ => None
    }
  })
}

///|
/// `codexWindows`: the windows of the app-server's account/rateLimits/read.
pub fn codex_windows(ctx : Ctx, result : JV?) -> Array[JV] {
  let limits = match jget(result, "rateLimits") {
    Some(Obj(_)) as l => l
    _ => result
  }
  [("primary", "5 小时"), ("secondary", "每周")].filter_map(p => {
    match jget(limits, p.0) {
      Some(Obj(_) as w) => {
        let minutes = match w.get("windowDurationMins") {
          Some(Num(m)) if m > 0.0 => m
          _ => if p.0 == "primary" { 300.0 } else { week_minutes }
        }
        Some(
          quota_window(
            window_label(Some(minutes), p.1),
            percent(w.get("usedPercent")),
            at(ctx, w.get("resetsAt")),
            Some(minutes),
          ),
        )
      }
      _ => None
    }
  })
}

///|
/// `withCodexCredits`.
fn with_codex_credits(ctx : Ctx, q : JV, limits : JV?, resets : JV?) -> JV {
  let mut o = q
  match jget(limits, "credits") {
    Some(Obj(_) as c) => {
      let has = match c.get("hasCredits") {
        Some(Bool(b)) => b
        _ =>
          match c.get("has_credits") {
            Some(Bool(b)) => b
            _ => false
          }
      }
      let balance = match c.get("balance") {
        Some(Str(s)) => js(s)
        Some(Num(n)) => js(num_text(n))
        _ => Null
      }
      o = jset(
        o,
        "credits",
        jobj([
          ("hasCredits", jbool(has)),
          ("unlimited", jbool(c.get("unlimited") == Some(Bool(true)))),
          ("balance", balance),
        ]),
      )
    }
    _ => ()
  }
  let count = match jget(resets, "availableCount") {
    None | Some(Null) => jget(resets, "available_count")
    x => x
  }
  match count {
    Some(Num(n)) if is_integer(n) && n >= 0.0 => o = jset(o, "resetCount", jnum(n))
    _ => ()
  }
  let reset_count = jnumber(o.get("resetCount")).unwrap_or(0.0)
  match jget(resets, "credits") {
    Some(Arr(credits)) if reset_count != 0.0 && !reset_count.is_nan() => {
      let expiries : Array[Double] = []
      for credit in credits {
        if credit.get("status") != Some(Str("available")) {
          continue
        }
        let raw = match credit.get("expiresAt") {
          None | Some(Null) => credit.get("expires_at")
          x => x
        }
        match at(ctx, raw) {
          Some(e) if is_safe_integer(e) && e > 0.0 => expiries.push(e)
          _ => ()
        }
      }
      if expiries.length() > 0 {
        stable_sort(expiries, (a, b) => a - b)
        let n = reset_count.to_int()
        let kept = if expiries.length() > n {
          expiries[0:n].to_array()
        } else {
          expiries
        }
        o = jset(o, "resetExpiries", jarr(kept.map(jnum)))
      }
    }
    _ => ()
  }
  if o.get("credits") is Some(_) || o.get("resetCount") is Some(_) {
    o = jset(o, "state", js("ok"))
    o = jset(o, "detail", Null)
  }
  o
}

///|
/// `codexQuota`: a ChatGPT subscription's allowance as the app-server reports it.
pub fn codex_quota(ctx : Ctx, result : JV?, lang : String) -> JV {
  let limits = match jget(result, "rateLimits") {
    Some(Obj(_)) as l => l
    _ => result
  }
  let mut q = with_codex_credits(
    ctx,
    ok_or_unavailable(
      codex_windows(ctx, result),
      ctx.tr(lang, "station.quota.chatgptNoWindows"),
    ),
    limits,
    jget(result, "rateLimitResetCredits"),
  )
  match jget(limits, "planType") {
    Some(Str(p)) if trim_js(p) != "" => q = jset(q, "plan", js(trim_js(p)))
    _ => ()
  }
  q
}

///|
/// `failed`: what went wrong, as an unavailable (or blocked) allowance.
pub fn failed(ctx : Ctx, e : Error, lang : String) -> JV {
  if unanswered(e) {
    return unanswered_quota(ctx.tr(lang, "station.quota.unreachable"))
  }
  let detail = message_of(e)
  if kind_of(e) == "RenewRefused" {
    return jset(quota("unavailable", [], Some(detail)), "signedOut", jbool(true))
  }
  quota(
    if blocked(detail) {
      "blocked"
    } else {
      "unavailable"
    },
    [],
    Some(detail),
  )
}

///|
/// codex-quota.ts `codexQuotaFailure`: what Codex's wrapped usage response says.
pub fn codex_quota_failure(detail : String) -> (String, Double?) {
  let mut said = detail
  if detail.has_prefix("codex {") {
    match try_parse(slice(detail, "codex ".length())) {
      Some(rpc) =>
        match rpc.get("message") {
          Some(Str(m)) => said = m
          _ => ()
        }
      None => ()
    }
  }
  let l = lower(said)
  let usage = l.contains("failed to fetch codex rate limits")
  let status = if usage { failed_status(l) } else { None }
  if usage &&
    (status == Some(401.0) || has_word(l, "token_revoked") || l.contains("invalidated oauth token")) {
    return ("login", None)
  }
  if usage && account_blocked(l) {
    return ("blocked", None)
  }
  match status {
    Some(s) => return ("status", Some(s))
    None => ()
  }
  if l.contains("timed out") ||
    l.contains("time out") ||
    l.contains("timeout") ||
    l.contains("error sending request") ||
    l.contains("dns error") ||
    l.contains("connection refused") ||
    l.contains("connection reset") ||
    l.contains("network unreachable") ||
    l.contains("network is unreachable") {
    return ("network", None)
  }
  ("other", None)
}

///|
fn word_char_at(s : String, i : Int) -> Bool {
  if i < 0 || i >= s.length() {
    return false
  }
  let c = s.unsafe_charcode_at(i)
  (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
  (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
  (c >= '0'.to_int() && c <= '9'.to_int()) ||
  c == '_'.to_int()
}

///|
/// `/\bword\b/` in `s`.
fn has_word(s : String, word : String) -> Bool {
  let mut from = 0
  while true {
    let i = index_of(s, word, from~)
    if i < 0 {
      return false
    }
    if !word_char_at(s, i - 1) && !word_char_at(s, i + word.length()) {
      return true
    }
    from = i + 1
  }
  false
}

///|
/// `/\bfailed:\s*([45]\d\d)\b/i` of a lower-cased text: the status.
fn failed_status(l : String) -> Double? {
  let mut from = 0
  while true {
    let i = index_of(l, "failed:", from~)
    if i < 0 {
      return None
    }
    from = i + 1
    if word_char_at(l, i - 1) {
      continue
    }
    let mut j = i + 7
    while j < l.length() && js_space(l.unsafe_charcode_at(j)) {
      j += 1
    }
    match digits_at(l, j, 3) {
      Some(n) if n >= 400 && n < 600 && !word_char_at(l, j + 3) =>
        return Some(n.to_double())
      _ => ()
    }
  }
  None
}

///|
/// `/\b(account|organi[sz]ation)\b.{0,80}\b(suspended|disabled|deactivated|banned|terminated)\b/i`.
fn account_blocked(l : String) -> Bool {
  let subjects = ["account", "organisation", "organization"]
  let states = ["suspended", "disabled", "deactivated", "banned", "terminated"]
  for subject in subjects {
    let mut from = 0
    while true {
      let i = index_of(l, subject, from~)
      if i < 0 {
        break
      }
      from = i + 1
      if word_char_at(l, i - 1) || word_char_at(l, i + subject.length()) {
        continue
      }
      let after = i + subject.length()
      for state in states {
        let mut k = after
        while k <= after + 80 && k + state.length() <= l.length() {
          // `.` takes no line break
          if k > after && is_line_break(l.unsafe_charcode_at(k - 1)) {
            break
          }
          if l.unsafe_substring(start=k, end=k + state.length()) == state &&
            !word_char_at(l, k - 1) &&
            !word_char_at(l, k + state.length()) {
            return true
          }
          k += 1
        }
      }
    }
  }
  false
}

///|
fn is_line_break(c : Int) -> Bool {
  c == 0x0a || c == 0x0d || c == 0x2028 || c == 0x2029
}

///|
/// `codexFailed`: Codex's app-server wraps the provider response in RPC JSON; that response is not the reason shown.
fn codex_failed(ctx : Ctx, e : Error, lang : String) -> JV {
  if unanswered(e) {
    return unanswered_quota(ctx.tr(lang, "station.quota.unreachable"))
  }
  let (kind, status) = codex_quota_failure(message_of(e))
  match kind {
    "login" =>
      jset(
        quota("unavailable", [], Some(ctx.tr(lang, "station.quota.codexLogin"))),
        "signedOut",
        jbool(true),
      )
    "network" => unanswered_quota(ctx.tr(lang, "station.quota.unreachable"))
    "blocked" =>
      quota("blocked", [], Some(ctx.tr(lang, "station.quota.codexBlocked")))
    "status" => {
      let s = status.unwrap_or(0.0)
      let q = quota(
        "unavailable",
        [],
        Some(
          ctx.tr(lang, "station.quota.codexStatus", args=[("status", num_text(s))]),
        ),
      )
      if troubled(s.to_int()) {
        jset(q, "unanswered", jbool(true))
      } else {
        q
      }
    }
    _ => quota("unavailable", [], Some(ctx.tr(lang, "station.quota.codexFailed")))
  }
}

///|
/// `checkQuota`: asks the provider. Never throws: what went wrong is an unavailable (or blocked) allowance.
/// `codex`: whether a codex app-server is there to ask (`codex.rateLimits`).
pub async fn check_quota(
  ctx : Ctx,
  profile : Profile,
  codex : Bool,
  lang : String,
  claude_version : String?,
) -> JV {
  check_quota_inner(ctx, profile, codex, lang, claude_version) catch {
    e => failed(ctx, e, lang)
  }
}

///|
async fn check_quota_inner(
  ctx : Ctx,
  profile : Profile,
  codex : Bool,
  lang : String,
  claude_version : String?,
) -> JV {
  let p = profile.raw
  let kind = access_kind(p)
  let key_of = () => trim_js(
    match jget(p.get("access"), "key") {
      None | Some(Null) => ""
      v => js_string(v)
    },
  )
  if kind == "service" {
    return match jget(p.get("access"), "service") {
      Some(Str("colab")) => colab_quota(ctx, profile.home, lang, @host.epoch_ms().to_double())
      _ => quota("unsupported", [], None)
    }
  }
  if kind == "opencode-go" {
    return opencode(ctx, key_of(), lang)
  }
  if kind == "api-provider" &&
    jget(p.get("access"), "provider") == Some(Str(kimi_code)) {
    let key = if kimi_signed_in(p) {
      match read_kimi(ctx.io, profile.home) {
        Some(l) => l.access
        None => ""
      }
    } else {
      key_of()
    }
    return kimi_quota(ctx, key, lang)
  }
  if kind == "api-provider" {
    let provider = jget(p.get("access"), "provider")
    let key = key_of()
    if provider == Some(Str("minimax-cn")) && key.has_prefix("sk-cp") {
      return plan_quota(
        ctx,
        ctx.url("minimaxCnQuota").unwrap_or(minimax_cn_quota),
        key,
        body => minimax_windows(body, v => at(ctx, v)),
        lang,
      )
    }
    if provider == Some(Str("zai-coding-cn")) {
      return plan_quota(
        ctx,
        ctx.url("glmCodingCnQuota").unwrap_or(glm_coding_cn_quota),
        key,
        body => glm_coding_windows(body, v => at(ctx, v)),
        lang,
      )
    }
  }
  if kind == "anthropic-api" || kind == "api-provider" {
    return quota("unsupported", [], Some(ctx.tr(lang, "station.quota.payAsYouGo")))
  }
  if kind == "service" {
    return quota("unsupported", [], None)
  }
  if kind == "env" {
    return quota("unsupported", [], Some(ctx.tr(lang, "station.quota.envUnsupported")))
  }
  if kind == "subscription" && profile.runtime == Some("grok") {
    return grok_quota(ctx, profile, lang)
  }
  if kind == "subscription" && profile.runtime == Some("cursor") {
    return quota("unsupported", [], Some(ctx.tr(lang, "station.quota.cursorUnsupported")))
  }
  if kind == "subscription" && profile.runtime == Some("devin") {
    return quota("unsupported", [], Some(ctx.tr(lang, "station.quota.devinUnsupported")))
  }
  if kind == "subscription" && profile.runtime == Some("agy") {
    let env = station_env(ctx)
    let source = match p.get("env") {
      Some(Obj(_) as e) => jspread(env, e)
      _ => env
    }
    return agy_quota(
      ctx,
      profile.home,
      source,
      lang,
      direct=p.get("directQuota") != Some(Bool(false)),
    )
  }
  if kind == "subscription" && profile.runtime == Some("claude") {
    return claude_with_refresh(
      ctx,
      if profile.machine {
        None
      } else {
        Some(profile.home)
      },
      lang,
      claude_version,
    ) catch {
      e => {
        let q = failed(ctx, e, lang)
        if q.get("unanswered") != Some(Bool(true)) &&
          q.get("signedOut") != Some(Bool(true)) {
          jset(q, "recheck", jbool(true))
        } else {
          q
        }
      }
    }
  }
  if kind == "subscription" && profile.runtime == Some("codex") {
    return codex_quota_of(ctx, profile, codex, lang) catch {
      e => codex_failed(ctx, e, lang)
    }
  }
  quota("unsupported", [], None)
}

///|
async fn codex_quota_of(
  ctx : Ctx,
  profile : Profile,
  codex : Bool,
  lang : String,
) -> JV {
  if !codex {
    raise plain_error("no codex app-server to ask")
  }
  let result = ctx.io.b.ask("codex.rateLimits", [profile.raw])
  let q = codex_quota(ctx, defined(result), lang)
  let count = jnumber(q.get("resetCount")).unwrap_or(0.0)
  let have = jitems(q.get("resetExpiries")).length().to_double()
  if count != 0.0 && !count.is_nan() && have < count {
    let auth_file = if profile.machine {
      codex_auth_file(ctx)
    } else {
      join_path([profile.home, "auth.json"])
    }
    let direct = codex_usage(ctx, auth_file, lang) catch { _ => None }
    match direct {
      Some(d) if d.get("state") == Some(Str("ok")) && d.get("resetCount") is Some(dc) => {
        let dcount = to_number(Some(dc))
        let dhave = jitems(d.get("resetExpiries")).length().to_double()
        if dcount != count || dhave > have {
          return d
        }
      }
      _ => ()
    }
  }
  q
}

///|
/// machine-logins.ts `codexAuthFile`: the machine's own Codex login file, asked of it.
pub async fn codex_auth_file(ctx : Ctx) -> String {
  js_string(Some(ctx.io.b.ask("machine.codexAuthFile", [])))
}

///|
/// The station's environment (what the agents' CLIs are started in: ops/agent-env.ts `startEnv`), asked of it.
pub async fn station_env(ctx : Ctx) -> JV {
  ctx.io.b.ask("station.env", [])
}

///|
let minimax_cn_quota : String = "https://www.minimaxi.com/v1/token_plan/remains"

///|
let glm_coding_cn_quota : String = "https://open.bigmodel.cn/api/monitor/usage/quota/limit"

///|
/// `planQuota`: a plan's windows as its provider's usage endpoint gives them (both answer 200 with their error in the
/// body, so an answer with no window in it is unavailable).
async fn plan_quota(
  ctx : Ctx,
  url : String,
  key : String,
  windows_of : (JV?) -> Array[JV],
  lang : String,
) -> JV {
  let response = ctx.io.get(
    url,
    [("authorization", "Bearer \{key}"), ("accept", "application/json")],
    quota_timeout_ms,
  )
  let body = if response.ok() { try_parse(response.text) } else { None }
  ok_or_unavailable(windows_of(body), ctx.tr(lang, "station.quota.planUnavailable"))
}

///|
fn plan_percentage(v : JV?) -> Double? {
  match v {
    Some(Num(n)) if n >= 0.0 && n <= 100.0 => Some(n)
    _ => None
  }
}

///|
/// `miniMaxWindows`: the shared text allowance (its `general` model) of a Token Plan, its 5 hours and its week.
fn minimax_windows(body : JV?, when : (JV?) -> Double?) -> Array[JV] {
  let out = []
  guard body is Some(Obj(_)) &&
    jget(jget(body, "base_resp"), "status_code") == Some(Num(0.0)) &&
    jget(body, "model_remains") is Some(Arr(remains)) else {
    return out
  }
  let mut g : JV? = None
  for entry in remains {
    if entry is Obj(_) && entry.get("model_name") == Some(Str("general")) {
      g = Some(entry)
      break
    }
  }
  guard g is Some(_) else { return out }
  for window in [
    ("current_interval_remaining_percent", "start_time", "end_time"),
    ("current_weekly_remaining_percent", "weekly_start_time", "weekly_end_time"),
  ] {
    let (remaining, start, end) = window
    guard plan_percentage(jget(g, remaining)) is Some(remaining) &&
      when(jget(g, start)) is Some(start) &&
      when(jget(g, end)) is Some(end) &&
      end > start else {
      continue
    }
    let minutes = (end - start) / 60_000.0
    out.push(
      quota_window(
        window_label(Some(minutes), "限额"),
        percent(Some(Num(100.0 - remaining))),
        Some(end),
        Some(minutes),
      ),
    )
  }
  out
}

///|
/// `glmCodingWindows`: a Coding Plan's token limits (unit 3 hours of `number`, unit 6 weeks), shortest first.
fn glm_coding_windows(body : JV?, when : (JV?) -> Double?) -> Array[JV] {
  guard body is Some(Obj(_)) && jget(body, "code") == Some(Num(200.0)) &&
    jget(jget(body, "data"), "limits") is Some(Arr(limits)) else {
    return []
  }
  let found : Array[(Double, JV)] = []
  for entry in limits {
    guard entry is Obj(_) && entry.get("type") == Some(Str("TOKENS_LIMIT")) else {
      continue
    }
    let e = Some(entry)
    guard plan_percentage(jget(e, "percentage")) is Some(used) &&
      jget(e, "number") is Some(Num(number)) &&
      !number.is_nan() &&
      !number.is_inf() &&
      number > 0.0 else {
      continue
    }
    let unit_minutes = match jget(e, "unit") {
      Some(Num(3.0)) => 60.0
      Some(Num(6.0)) => week_minutes
      _ => continue
    }
    let minutes = number * unit_minutes
    found.push(
      (
        minutes,
        quota_window(
          window_label(Some(minutes), "限额"),
          percent(Some(Num(used))),
          when(jget(e, "nextResetTime")),
          Some(minutes),
        ),
      ),
    )
  }
  // Shortest first, those as long kept in the order given (Array.prototype.sort is stable).
  let out : Array[JV] = []
  let kept : Array[Double] = []
  for f in found {
    let mut i = kept.length()
    while i > 0 && kept[i - 1] > f.0 {
      i -= 1
    }
    kept.insert(i, f.0)
    out.insert(i, f.1)
  }
  out
}

///|
let kimi_api : String = "https://api.kimi.com/coding/v1"

///|
/// `kimiQuota`: Kimi Code's allowance.
async fn kimi_quota(ctx : Ctx, key : String, lang : String) -> JV {
  let response = ctx.io.get(
    "\{ctx.url("kimiApi").unwrap_or(kimi_api)}/usages",
    [("authorization", "Bearer \{key}"), ("accept", "application/json")],
    quota_timeout_ms,
  )
  if !response.ok() {
    return refused(ctx, "Kimi Code ", response, lang)
  }
  guard try_parse(response.text) is Some(body) else {
    return quota("unavailable", [], Some(ctx.tr(lang, "station.quota.kimiNoWindows")))
  }
  match body {
    Obj(_) => {
      let usage_none = match body.get("usage") {
        None | Some(Null) => true
        _ => false
      }
      let limits_some = match body.get("limits") {
        Some(Arr(a)) => a.length() > 0
        _ => false
      }
      if usage_none && !limits_some {
        return quota("unsupported", [], Some(ctx.tr(lang, "station.quota.kimiNone")))
      }
    }
    _ => ()
  }
  ok_or_unavailable(
    kimi_windows(ctx, Some(body)),
    ctx.tr(lang, "station.quota.kimiNoWindows"),
  )
}

///|
fn kimi_num(v : JV?) -> Double? {
  match v {
    Some(Num(n)) => Some(n)
    Some(Str(s)) if trim_js(s) != "" => {
      let n = js_number(s)
      if n.is_nan() || n.is_inf() {
        None
      } else {
        Some(n)
      }
    }
    _ => None
  }
}

///|
/// `a ?? b` of two fields.
fn coalesce(a : JV?, b : () -> JV?) -> JV? {
  match a {
    None | Some(Null) => b()
    _ => a
  }
}

///|
/// `kimiWindows`: the windows of a Kimi Code usage answer.
pub fn kimi_windows(ctx : Ctx, body : JV?) -> Array[JV] {
  let one = (d : JV?, minutes : Double?, fallback : String) => {
    let limit = kimi_num(jget(d, "limit"))
    guard limit is Some(limit) && limit > 0.0 else { return None }
    let used = match kimi_num(jget(d, "used")) {
      Some(u) => Some(u)
      None =>
        match kimi_num(jget(d, "remaining")) {
          Some(r) => Some(limit - r)
          None => None
        }
    }
    guard used is Some(used) else { return None }
    let raw = coalesce(jget(d, "resetTime"), () => coalesce(jget(d, "reset_time"), () => coalesce(
          jget(d, "resetAt"),
          () => jget(d, "reset_at"),
        )))
    Some(
      quota_window(
        window_label(minutes, fallback),
        percent(Some(Num(used / limit * 100.0))),
        at(ctx, raw),
        minutes,
      ),
    )
  }
  let out = []
  for item in jitems(jget(body, "limits")) {
    let window = match item.get("window") {
      Some(Obj(_)) as w => w
      _ => Some(item)
    }
    let duration = kimi_num(jget(window, "duration"))
    let unit = match jget(window, "timeUnit") {
      None | Some(Null) => ""
      x => js_string(x)
    }
    let minutes = match duration {
      None => None
      Some(d) =>
        Some(
          if unit.contains("MINUTE") {
            d
          } else if unit.contains("HOUR") {
            d * 60.0
          } else if unit.contains("DAY") {
            d * day_minutes
          } else {
            d / 60.0
          },
        )
    }
    let detail = match item.get("detail") {
      Some(Obj(_)) as d => d
      _ => Some(item)
    }
    match one(detail, minutes, "限额") {
      Some(w) => out.push(w)
      None => ()
    }
  }
  match one(jget(body, "usage"), Some(week_minutes), "每周") {
    Some(w) => out.push(w)
    None => ()
  }
  out
}

///|
/// `grokQuota`: a SuperGrok subscription's allowance, asked of a `grok agent stdio` started for it.
async fn grok_quota(ctx : Ctx, profile : Profile, lang : String) -> JV {
  let env = jspread(
    station_env(ctx),
    jobj([
      ("GROK_HOME", js(join_path([profile.home, "grok"]))),
      ("GROK_DISABLE_AUTOUPDATER", js("1")),
      ("GROK_TELEMETRY_ENABLED", js("0")),
    ]),
  )
  let said = ctx.io.b.ask("grok.billing", [env])
  grok_quota_of(ctx, defined(said), lang)
}

///|
/// `grokQuotaOf`: the allowance in Grok Build's billing answer.
pub fn grok_quota_of(ctx : Ctx, said : JV?, lang : String) -> JV {
  let config = jget(said, "config")
  let period = jget(config, "currentPeriod")
  let tier = jget(said, "subscription_tier")
  let plan = match tier {
    Some(Str(t)) => trim_js(t)
    _ => ""
  }
  let used = match jget(config, "creditUsagePercent") {
    Some(Num(n)) => Some(n)
    _ => if period is Some(Obj(_)) { Some(0.0) } else { None }
  }
  guard used is Some(used) else {
    let q = quota("unavailable", [], Some(ctx.tr(lang, "station.quota.grokNoWindows")))
    return if plan != "" { jset(q, "plan", js(plan)) } else { q }
  }
  let start = at(ctx, coalesce(jget(period, "start"), () => jget(config, "billingPeriodStart")))
  let end = at(ctx, coalesce(jget(period, "end"), () => jget(config, "billingPeriodEnd")))
  let type_ = match jget(period, "type") {
    None | Some(Null) => ""
    x => js_string(x)
  }
  let minutes = match (start, end) {
    (Some(s), Some(e)) if e > s => Some((e - s) / 60000.0)
    _ =>
      if type_.contains("WEEKLY") {
        Some(week_minutes)
      } else if type_.contains("MONTHLY") {
        Some(30.0 * day_minutes)
      } else {
        None
      }
  }
  let window = quota_window(
    window_label(
      minutes,
      if type_.contains("WEEKLY") {
        "每周"
      } else {
        "每月"
      },
    ),
    percent(Some(Num(used))),
    end,
    minutes,
  )
  let q = quota(
    "ok",
    [window],
    match tier {
      Some(Str(t)) => Some(t)
      _ => None
    },
  )
  if plan != "" {
    jset(q, "plan", js(plan))
  } else {
    q
  }
}

///|
/// `codexHeaders`: the account named by a Codex login file; the credentials never leave the request headers.
async fn codex_headers(ctx : Ctx, auth_file : String) -> Array[(String, String)]? {
  let tokens = match ctx.io.read_file_or_none(auth_file) {
    None => return None
    Some(text) =>
      match try_parse(text) {
        None => return None
        Some(j) => j.get("tokens")
      }
  }
  let access = match jget(tokens, "access_token") {
    Some(Str(a)) if a != "" => a
    _ => return None
  }
  let headers = [
    ("authorization", "Bearer \{access}"),
    ("user-agent", "codex_cli_rs"),
  ]
  match jget(tokens, "account_id") {
    Some(Str(id)) => headers.push(("chatgpt-account-id", id))
    _ => ()
  }
  Some(headers)
}

///|
/// `addCodexResetDetails`: the details read when a summary has fewer expiry dates than available cards.
async fn add_codex_reset_details(
  ctx : Ctx,
  q : JV,
  headers : Array[(String, String)],
) -> JV {
  let count0 = jnumber(q.get("resetCount")).unwrap_or(0.0)
  let have = jitems(q.get("resetExpiries")).length().to_double()
  if count0 == 0.0 || count0.is_nan() || have >= count0 {
    return q
  }
  let attempt = async fn() -> JV {
    let detail = ctx.io.get(
      "\{ctx.url("chatgpt").unwrap_or("")}/backend-api/wham/rate-limit-reset-credits",
      headers,
      quota_timeout_ms,
    )
    if !detail.ok() {
      return q
    }
    let resets = detail.json()
    guard resets.get("credits") is Some(Arr(_) as credits) else { return q }
    let said = coalesce(resets.get("available_count"), () => resets.get("availableCount"))
    let count = match said {
      Some(Num(n)) if is_integer(n) && n >= 0.0 => n
      _ => count0
    }
    let before = q.get("resetExpiries")
    let same_count = count == count0
    let mut o = if same_count { q } else { jdel(q, "resetExpiries") }
    o = with_codex_credits(
      ctx,
      o,
      None,
      Some(jobj([("available_count", jnum(count)), ("credits", credits)])),
    )
    match before {
      Some(Arr(b)) if same_count && jitems(o.get("resetExpiries")).length() < b.length() =>
        o = jset(o, "resetExpiries", Arr(b))
      _ => ()
    }
    o
  }
  attempt() catch {
    _ => q
  }
}

///|
/// `codexUsage`: a ChatGPT subscription's allowance read with the tokens of a Codex auth.json. None when there is no
/// such file or token.
pub async fn codex_usage(ctx : Ctx, auth_file : String, lang : String) -> JV? {
  guard codex_headers(ctx, auth_file) is Some(headers) else { return None }
  let response = ctx.io.get(
    "\{ctx.url("chatgpt").unwrap_or("")}/backend-api/wham/usage",
    headers,
    quota_timeout_ms,
  )
  if !response.ok() {
    let result = refused(ctx, "ChatGPT ", response, lang)
    return Some(
      if response.status == 401 {
        jset(result, "signedOut", jbool(true))
      } else {
        result
      },
    )
  }
  let body = response.json()
  let windows = [("primary_window", "5 小时"), ("secondary_window", "每周")].filter_map(p => {
    match jget(body.get("rate_limit"), p.0) {
      Some(Obj(_) as w) => {
        let seconds = match w.get("limit_window_seconds") {
          Some(Num(s)) if s > 0.0 => Some(s)
          _ => None
        }
        let minutes = match seconds {
          Some(s) => s / 60.0
          None => if p.0 == "primary_window" { 300.0 } else { week_minutes }
        }
        Some(
          quota_window(
            window_label(Some(minutes), p.1),
            percent(w.get("used_percent")),
            at(ctx, w.get("reset_at")),
            Some(minutes),
          ),
        )
      }
      _ => None
    }
  })
  let mut q = with_codex_credits(
    ctx,
    ok_or_unavailable(windows, ctx.tr(lang, "station.quota.chatgptNoWindows")),
    Some(body),
    body.get("rate_limit_reset_credits"),
  )
  q = add_codex_reset_details(ctx, q, headers)
  match body.get("plan_type") {
    Some(Str(p)) if trim_js(p) != "" => q = jset(q, "plan", js(trim_js(p)))
    _ => ()
  }
  Some(q)
}

///|
/// `lentCodexUsage`: a borrowed Codex subscription's allowance, read with the login its host lent while that has not
/// run out. None when there is no such login.
pub async fn lent_codex_usage(
  ctx : Ctx,
  home : String,
  now : Double,
  lang : String,
) -> JV? {
  let file = join_path([home, "auth.json"])
  let text = match ctx.io.read_file_or_none(file) {
    Some(t) => t
    None => return None
  }
  guard try_parse(text) is Some(j) else { return None }
  let token = js_string(jget(jget(Some(j), "tokens"), "access_token"))
  let parts = split_on(token, ".")
  let payload = if parts.length() > 1 { parts[1] } else { "" }
  guard try_parse(base64url_text(payload)) is Some(claims) else { return None }
  let expires = match claims.get("exp") {
    Some(Num(e)) => e * 1000.0
    _ => 0.0
  }
  if expires > now {
    codex_usage(ctx, file, lang)
  } else {
    None
  }
}

///|
/// `machineUsage`: the allowance of the machine's own login of a runtime, the account's own windows alone.
pub async fn machine_usage(
  ctx : Ctx,
  runtime : String,
  lang : String,
  claude_version? : String,
) -> JV? {
  let run = async fn() -> JV? {
    if runtime == "codex" {
      return codex_usage(ctx, codex_auth_file(ctx), lang)
    }
    let own = claude_with_refresh(ctx, None, lang, claude_version)
    Some(jdel(own, "scoped"))
  }
  run() catch {
    e => Some(failed(ctx, e, lang))
  }
}
