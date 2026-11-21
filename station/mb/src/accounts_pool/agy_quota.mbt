// An Antigravity CLI subscription's allowance (station/src/accounts/agy-quota.ts): what `agy -p /usage
// --output-format json` reports (Gemini Models and Claude and GPT models, 5-hour and weekly windows), asked of `agy`
// in the profile's own files (ANTIGRAVITY_GEMINI_DIR=<home>/agy/.gemini, HOME=<home>/agy). The process is the
// station's to start (`agy.run`); what it is started in and what is made of what it said are here.

///|
let scrubbed : Array[String] = [
  "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_APPLICATION_CREDENTIALS",
  "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION", "AGY_ADC_AUTH", "AGY_ACCOUNT", "SSH_CONNECTION",
]

///|
fn is_ascii_digit(c : Int) -> Bool {
  c >= '0'.to_int() && c <= '9'.to_int()
}

///|
fn is_ascii_letter(c : Int) -> Bool {
  (c >= 'a'.to_int() && c <= 'z'.to_int()) || (c >= 'A'.to_int() && c <= 'Z'.to_int())
}

///|
/// `\d+(?:\.\d+)?` from `i`: where it ends, None where there is none.
fn number_end(s : String, i : Int) -> Int? {
  let mut j = i
  while j < s.length() && is_ascii_digit(s.unsafe_charcode_at(j)) {
    j += 1
  }
  if j == i {
    return None
  }
  if j + 1 < s.length() &&
    s.unsafe_charcode_at(j) == '.'.to_int() &&
    is_ascii_digit(s.unsafe_charcode_at(j + 1)) {
    j += 1
    while j < s.length() && is_ascii_digit(s.unsafe_charcode_at(j)) {
      j += 1
    }
  }
  Some(j)
}

///|
/// `\s+` from `i`: where it ends, None where there is none.
fn spaces_end(s : String, i : Int) -> Int? {
  let mut j = i
  while j < s.length() && js_space(s.unsafe_charcode_at(j)) {
    j += 1
  }
  if j == i {
    None
  } else {
    Some(j)
  }
}

///|
fn no_line_break(s : String) -> Bool {
  for i in 0..<s.length() {
    if is_line_break(s.unsafe_charcode_at(i)) {
      return false
    }
  }
  true
}

///|
/// `/^gemini\s+(?:\d+(?:\.\d+)?\s+)?(.+)$/i`: its group.
fn gemini_tier(g : String) -> String? {
  if g.length() < 6 || lower(slice(g, 0, b=6)) != "gemini" {
    return None
  }
  guard spaces_end(g, 6) is Some(after) else { return None }
  // `\s+` gives back what `.+` needs where nothing else is left
  let rest_from = (from : Int) => {
    let rest = slice(g, from)
    if rest != "" && no_line_break(rest) {
      Some(rest)
    } else {
      None
    }
  }
  match number_end(g, after) {
    Some(n) =>
      match spaces_end(g, n) {
        Some(m) =>
          match rest_from(m) {
            Some(r) => return Some(r)
            None => ()
          }
        None => ()
      }
    None => ()
  }
  match rest_from(after) {
    Some(r) => Some(r)
    None =>
      // all of it spaces: the last one is `.+`'s
      if after - 1 > 6 && no_line_break(slice(g, after - 1)) {
        Some(slice(g, after - 1))
      } else {
        None
      }
  }
}

///|
/// `/^claude\s+([A-Za-z]+)(?:\s+\d+(?:\.\d+)?)?$/i`: its group.
fn claude_tier(g : String) -> String? {
  if g.length() < 6 || lower(slice(g, 0, b=6)) != "claude" {
    return None
  }
  guard spaces_end(g, 6) is Some(after) else { return None }
  let mut j = after
  while j < g.length() && is_ascii_letter(g.unsafe_charcode_at(j)) {
    j += 1
  }
  if j == after {
    return None
  }
  let word = slice(g, after, b=j)
  if j == g.length() {
    return Some(word)
  }
  match spaces_end(g, j) {
    Some(k) =>
      match number_end(g, k) {
        Some(e) if e == g.length() => Some(word)
        _ => None
      }
    None => None
  }
}

///|
fn model_scope_name(group_name : String, bucket_id : String) -> String {
  let g = trim_js(group_name)
  match gemini_tier(g) {
    Some(t) if lower(trim_js(t)) != "models" => return trim_js(t)
    _ => ()
  }
  match claude_tier(g) {
    Some(t) => return t
    None => ()
  }
  if g != "" {
    return g
  }
  // `/^(?:gemini|3p)-([a-z0-9]+)-/i`
  let id = trim_js(bucket_id)
  let l = lower(id)
  let from = if l.has_prefix("gemini-") {
    7
  } else if l.has_prefix("3p-") {
    3
  } else {
    -1
  }
  if from < 0 {
    return ""
  }
  let mut j = from
  while j < id.length() &&
        (is_ascii_letter(id.unsafe_charcode_at(j)) || is_ascii_digit(id.unsafe_charcode_at(j))) {
    j += 1
  }
  if j == from || j >= id.length() || id.unsafe_charcode_at(j) != '-'.to_int() {
    return ""
  }
  let s = slice(id, from, b=j)
  slice(s, 0, b=1).to_upper() + lower(slice(s, 1))
}

///|
/// `-(\d+h|weekly|daily|monthly)$` after `prefix`, the whole of it.
fn window_id(id : String, prefix : String) -> Bool {
  if !id.has_prefix(prefix) {
    return false
  }
  let rest = slice(id, prefix.length())
  if rest == "weekly" || rest == "daily" || rest == "monthly" {
    return true
  }
  rest.length() >= 2 && rest.has_suffix("h") && is_digits(slice(rest, 0, b=rest.length() - 1))
}

///|
/// `groupMeta`: the suffix a group's windows are labelled with, their scope, and whether it is one model's own.
fn group_meta(group_name : String, bucket_id : String) -> (String, String?, Bool) {
  let id = lower(trim_js(bucket_id))
  let g = lower(trim_js(group_name))
  if window_id(id, "gemini-") || g == "gemini models" || g == "gemini" {
    return ("Gemini", Some("gemini"), false)
  }
  if window_id(id, "3p-") || (g.contains("claude") && g.contains("gpt")) || g == "claude / gpt" {
    return ("Claude / GPT", Some("3p"), false)
  }
  let own = model_scope_name(group_name, bucket_id)
  if own != "" {
    (own, Some(own), true)
  } else {
    (trim_js(group_name), None, false)
  }
}

///|
/// `windowDuration`: a window's length and label.
fn window_duration(raw_window : String, bucket_id : String) -> (Double?, String) {
  let w = lower(trim_js(raw_window))
  let id = lower(trim_js(bucket_id))
  // `/^(\d+)\s*h$/` of the window, else `/-(\d+)h$/` of the id
  let hours = {
    let mut found : String? = None
    if w.has_suffix("h") {
      let body = slice(w, 0, b=w.length() - 1)
      let mut e = body.length()
      while e > 0 && js_space(body.unsafe_charcode_at(e - 1)) {
        e -= 1
      }
      let digits = slice(body, 0, b=e)
      if is_digits(digits) {
        found = Some(digits)
      }
    }
    if found is None && id.has_suffix("h") {
      let body = slice(id, 0, b=id.length() - 1)
      let mut s = body.length()
      while s > 0 && is_ascii_digit(body.unsafe_charcode_at(s - 1)) {
        s -= 1
      }
      if s < body.length() && s > 0 && body.unsafe_charcode_at(s - 1) == '-'.to_int() {
        found = Some(slice(body, s))
      }
    }
    found
  }
  match hours {
    Some(h) => {
      let mins = js_number(h) * 60.0
      return (Some(mins), window_label(Some(mins), "\{h} 小时"))
    }
    None => ()
  }
  if w == "weekly" || id.has_suffix("-weekly") {
    return (Some(week_minutes), "每周")
  }
  if w == "monthly" || id.has_suffix("-monthly") {
    return (Some(30.0 * day_minutes), "每月")
  }
  if w == "daily" || id.has_suffix("-daily") {
    return (Some(day_minutes), "1 天")
  }
  (
    None,
    if trim_js(raw_window) == "" {
      "限额"
    } else {
      trim_js(raw_window)
    },
  )
}

///|
/// `agyAllowance`: the account's windows, and those of one model's own.
pub fn agy_allowance(ctx : Ctx, body : JV?) -> (Array[JV], Array[JV]) {
  let groups = match jget(jget(jget(body, "command"), "data"), "groups") {
    Some(Arr(g)) => g
    _ =>
      match jget(jget(body, "quotaSummary"), "groups") {
        Some(Arr(g)) => g
        _ =>
          match jget(body, "groups") {
            Some(Arr(g)) => g
            _ => []
          }
      }
  }
  let multi = groups.length() > 1
  let windows = []
  let scoped = []
  for group in groups {
    let group_name = match group.get("displayName") {
      Some(Str(n)) => n
      _ =>
        match group.get("name") {
          Some(Str(n)) => n
          _ => ""
        }
    }
    for b in jitems(group.get("buckets")) {
      guard b is Obj(_) else { continue }
      let frac = match b.get("remainingFraction") {
        Some(Num(f)) => Some(f)
        _ =>
          match b.get("remaining_fraction") {
            Some(Num(f)) => Some(f)
            _ => None
          }
      }
      let disabled = b.get("disabled") == Some(Bool(true))
      if frac is None && !disabled {
        continue
      }
      let used = if disabled {
        100.0
      } else {
        percent(Some(Num((1.0 - frac.unwrap_or(0.0)) * 100.0)))
      }
      let bucket_id = match b.get("bucketId") {
        Some(Str(s)) => s
        _ =>
          match b.get("id") {
            Some(Str(s)) => s
            _ => ""
          }
      }
      let raw_win = match b.get("refreshWindowLabel") {
        Some(Str(s)) => s
        _ =>
          match b.get("window") {
            Some(Str(s)) => s
            _ => ""
          }
      }
      let (minutes, base) = window_duration(raw_win, bucket_id)
      let (suffix, scope, model_scoped) = group_meta(group_name, bucket_id)
      let label = if (multi || scope is Some(_)) && suffix != "" {
        "\{base} · \{suffix}"
      } else {
        base
      }
      let resets_at = at(ctx, coalesce(b.get("resetTime"), () => b.get("reset_time")))
      let win = match scope {
        Some(s) => quota_window(label, used, resets_at, minutes, scope=s)
        None => quota_window(label, used, resets_at, minutes)
      }
      if model_scoped {
        scoped.push(win)
      } else {
        windows.push(win)
      }
    }
  }
  (windows, scoped)
}

///|
/// `agyWindows`.
pub fn agy_windows(ctx : Ctx, body : JV?) -> Array[JV] {
  agy_allowance(ctx, body).0
}

///|
/// `agyScopeForModel`: which of an Antigravity account's groups a model counts against.
pub fn agy_scope_for_model(model : String?) -> String {
  guard model is Some(m) && trim_js(m) != "" else { return "gemini" }
  let first = split_on(lower(trim_js(m)), "[")[0]
  let slashes = split_on(first, "/")
  let bare = split_on(slashes[slashes.length() - 1], "@")[0]
  // `/^(?:[a-z]+\.)+/` off
  let mut s = bare
  while true {
    let mut j = 0
    while j < s.length() &&
          s.unsafe_charcode_at(j) >= 'a'.to_int() &&
          s.unsafe_charcode_at(j) <= 'z'.to_int() {
      j += 1
    }
    if j > 0 && j < s.length() && s.unsafe_charcode_at(j) == '.'.to_int() {
      s = slice(s, j + 1)
    } else {
      break
    }
  }
  if s.has_prefix("gemini") || s.has_prefix("gemma") {
    "gemini"
  } else {
    "3p"
  }
}

///|
fn network_failure(text : String) -> Bool {
  let l = lower(text)
  if has_word(l, "eof") {
    return true
  }
  [
    "connection refused", "connection reset", "no such host", "i/o timeout", "context deadline exceeded",
    "tls handshake timeout", "network is unreachable", "no route to host", "temporary failure in name resolution",
  ].iter().any(w => l.contains(w))
}

///|
let agy_cloud_code_url : String = "https://daily-cloudcode-pa.googleapis.com"

///|
let agy_user_agent : String = "antigravity/1.5.12"

///|
let agy_timeout_ms : Int = 30_000

///|
/// `agyVerify`: Google holding an account until a person verifies it ("Eligibility check failed: Your current account
/// is not eligible for Antigravity. Verify your account to continue." and the page to do it on; its backend
/// `VALIDATION_REQUIRED`): that page, "" when it gives none, None when it is not that.
pub fn agy_verify(text : String) -> String? {
  let l = lower(text)
  if !["verify your account", "validation_required"].iter().any(w => l.contains(w)) {
    return None
  }
  let at = index_of(text, "https://accounts.google.com/")
  if at < 0 {
    return Some("")
  }
  let mut end = at
  while end < text.length() && !js_space(text.unsafe_charcode_at(end)) {
    end += 1
  }
  Some(slice(text, at, b=end))
}

///|
fn agy_location_ineligible(text : String) -> Bool {
  let l = lower(text)
  l.contains("not currently available in your location") ||
  l.contains("unsupported_location") ||
  l.contains("not eligible for antigravity")
}

///|
/// `agyModelWindows`: 5-hour quota windows derived from `v1internal:fetchAvailableModels` (`models[*].quotaInfo`),
/// one per pool (`gemini` and `3p`), taking the lowest remaining fraction in each pool.
fn agy_model_windows(ctx : Ctx, body : JV?) -> Array[JV] {
  guard jget(body, "models") is Some(Obj(_)) else { return [] }
  let models = jget(body, "models")
  let mut gemini_frac : Double? = None
  let mut gemini_reset : Double? = None
  let mut p3_frac : Double? = None
  let mut p3_reset : Double? = None
  for f in jfields(models) {
    let model_id = f.0
    if lower(model_id).has_prefix("tab_") {
      continue
    }
    guard f.1 is Obj(_) else { continue }
    guard f.1.get("quotaInfo") is Some(Obj(_) as qi) else { continue }
    let frac = match qi.get("remainingFraction") {
      Some(Num(v)) => Some(v)
      _ =>
        match qi.get("remaining_fraction") {
          Some(Num(v)) => Some(v)
          _ => None
        }
    }
    guard frac is Some(v) else { continue }
    let resets_at = at(ctx, coalesce(qi.get("resetTime"), () => qi.get("reset_time")))
    if agy_scope_for_model(Some(model_id)) == "gemini" {
      match gemini_frac {
        None => {
          gemini_frac = Some(v)
          gemini_reset = resets_at
        }
        Some(prev) => {
          if v < prev {
            gemini_frac = Some(v)
          }
          if gemini_reset is None && resets_at is Some(_) {
            gemini_reset = resets_at
          }
        }
      }
    } else {
      match p3_frac {
        None => {
          p3_frac = Some(v)
          p3_reset = resets_at
        }
        Some(prev) => {
          if v < prev {
            p3_frac = Some(v)
          }
          if p3_reset is None && resets_at is Some(_) {
            p3_reset = resets_at
          }
        }
      }
    }
  }
  let out = []
  let base_label = window_label(Some(300.0), "5 小时")
  match gemini_frac {
    Some(v) =>
      out.push(
        quota_window(
          "\{base_label} · Gemini",
          percent(Some(Num((1.0 - v) * 100.0))),
          gemini_reset,
          Some(300.0),
          scope="gemini",
        ),
      )
    None => ()
  }
  match p3_frac {
    Some(v) =>
      out.push(
        quota_window(
          "\{base_label} · Claude / GPT",
          percent(Some(Num((1.0 - v) * 100.0))),
          p3_reset,
          Some(300.0),
          scope="3p",
        ),
      )
    None => ()
  }
  out
}

///|
fn strip_trailing_slashes(s : String) -> String {
  let mut end = s.length()
  while end > 0 && s.unsafe_charcode_at(end - 1) == '/'.to_int() {
    end -= 1
  }
  slice(s, 0, b=end)
}

///|
async fn agy_post(
  ctx : Ctx,
  base : String,
  path : String,
  token : String,
  body : JV,
) -> JV? {
  let response = Some(
    ctx.io.fetch({
      url: "\{base}\{path}",
      verb: Some("POST"),
      headers: [
        ("authorization", "Bearer \{token}"),
        ("content-type", "application/json"),
        ("accept", "application/json"),
        ("user-agent", agy_user_agent),
      ],
      body: Some(stringify(body)),
      timeout_ms: agy_timeout_ms,
    }),
  ) catch {
    _ => None
  }
  guard response is Some(res) && res.ok() else { return None }
  try_parse(res.text)
}

///|
async fn agy_direct_quota(ctx : Ctx, home : String, lang : String) -> JV? {
  let token_text = ctx.io.read_file_or_none(
    join_path([home, "agy", ".gemini", "antigravity-cli", "antigravity-oauth-token"]),
  ).unwrap_or("")
  let token = match jget(jget(try_parse(token_text), "token"), "access_token") {
    Some(Str(t)) if t != "" => t
    _ => return None
  }
  let raw_base = match ctx.url("agyQuota") {
    Some(u) if trim_js(u) != "" => u
    _ => agy_cloud_code_url
  }
  let base = strip_trailing_slashes(raw_base)
  let loaded = agy_post(
    ctx,
    base,
    "/v1internal:loadCodeAssist",
    token,
    jobj([("metadata", jobj([("ideType", js("ANTIGRAVITY"))]))]),
  )
  let has_tier = match jget(loaded, "paidTier") {
    Some(Obj(_)) => true
    _ =>
      match jget(loaded, "currentTier") {
        Some(Obj(_)) => true
        _ => false
      }
  }
  if !has_tier {
    return None
  }
  let payload = match jget(loaded, "cloudaicompanionProject") {
    Some(Str(p)) if p != "" => jobj([("project", js(p))])
    _ => jobj([])
  }
  let summary = agy_post(ctx, base, "/v1internal:retrieveUserQuotaSummary", token, payload)
  let models = agy_post(ctx, base, "/v1internal:fetchAvailableModels", token, payload)
  let (windows, scoped) = match summary {
    Some(_) => agy_allowance(ctx, summary)
    None => ([], [])
  }
  let has_scope = (s : String) => windows.iter().any(w => w.get("scope") == Some(Str(s)))
  let extra = match models {
    Some(_) =>
      agy_model_windows(ctx, models).filter(w => match w.get("scope") {
        Some(Str(s)) => !has_scope(s)
        _ => false
      })
    None => []
  }
  let merged = []
  for w in extra {
    if w.get("scope") == Some(Str("gemini")) {
      merged.push(w)
    }
  }
  for w in windows {
    merged.push(w)
  }
  for w in extra {
    if w.get("scope") != Some(Str("gemini")) {
      merged.push(w)
    }
  }
  if merged.length() == 0 && scoped.length() == 0 {
    return None
  }
  let mut q = ok_or_unavailable(
    if merged.length() > 0 {
      merged
    } else {
      scoped
    },
    ctx.tr(lang, "station.quota.agyNoWindows"),
  )
  if q.get("state") == Some(Str("ok")) && merged.length() > 0 && scoped.length() > 0 {
    q = jset(q, "scoped", jarr(scoped))
  }
  Some(q)
}

///|
fn auth_failure(text : String) -> Bool {
  let l = lower(text)
  [
    "authentication required", "not logged into antigravity", "authentication expired", "couldn't sign in",
    "invalid_grant", "unauthenticated",
  ].iter().any(w => l.contains(w))
}

///|
/// `parseJsonLine`: the last line of what it said that is JSON.
fn parse_json_line(stdout : String) -> JV? {
  let lines = split_on(trim_js(stdout), "\n").map(l => if l.has_suffix("\r") {
    slice(l, 0, b=l.length() - 1)
  } else {
    l
  })
  lines.rev_in_place()
  for line in lines {
    let t = trim_js(line)
    if !t.has_prefix("{") {
      continue
    }
    match try_parse(t) {
      Some(v) => return Some(v)
      None => ()
    }
  }
  None
}

///|
/// `/\bHTTP\s+(429|5\d\d)\b|\bstatus(?:\s+code)?[:=\s]+(429|5\d\d)\b/i`: the status.
fn agy_status(detail : String) -> Double? {
  let l = lower(detail)
  let status_at = (j : Int) => match digits_at(l, j, 3) {
    Some(n) if (n == 429 || (n >= 500 && n <= 599)) && !word_char_at(l, j + 3) =>
      Some(n.to_double())
    _ => None
  }
  // the leftmost match of either
  let mut i = 0
  while i < l.length() {
    if !word_char_at(l, i - 1) {
      if l.unsafe_substring(start=i, end=@cmp.minimum(i + 4, l.length())) == "http" &&
        !word_char_at(l, i + 4) {
        match spaces_end(l, i + 4) {
          Some(j) =>
            match status_at(j) {
              Some(s) => return Some(s)
              None => ()
            }
          None => ()
        }
      }
      if l.unsafe_substring(start=i, end=@cmp.minimum(i + 6, l.length())) == "status" {
        let mut tries = [i + 6]
        match spaces_end(l, i + 6) {
          Some(j) if l.unsafe_substring(start=j, end=@cmp.minimum(j + 4, l.length())) == "code" =>
            tries.push(j + 4)
          _ => ()
        }
        for t in tries {
          let mut j = t
          while j < l.length() &&
                (
                  l.unsafe_charcode_at(j) == ':'.to_int() ||
                  l.unsafe_charcode_at(j) == '='.to_int() ||
                  js_space(l.unsafe_charcode_at(j))
                ) {
            j += 1
          }
          if j > t {
            // `[:=\s]+` gives back nothing a status could use: the status follows the run
            match status_at(j) {
              Some(s) => return Some(s)
              None => ()
            }
          }
        }
        tries = []
      }
    }
    i += 1
  }
  None
}

///|
/// `agyQuota`. `source`: the environment `agy` is started from (the station's, the profile's own over it).
pub async fn agy_quota(
  ctx : Ctx,
  home : String,
  source : JV,
  lang : String,
  command? : String = "agy",
) -> JV {
  if ctx.io.b.ask("agy.takeBack", [js(home)]) != Bool(true) {
    raise Thrown(
      "Said",
      jobj([("message", js(ctx.tr(lang, "station.quota.signInExpired")))]),
    )
  }
  let mut base = JV::Obj([])
  for f in jfields(Some(source)) {
    if !is_undef(f.1) && !scrubbed.contains(f.0) {
      base = jset(base, f.0, f.1)
    }
  }
  base = jset(base, "HOME", js(join_path([home, "agy"])))
  if ctx.io.b.ask("platform.hasKeychain", []) == Bool(true) {
    base = jset(base, "SSH_CLIENT", js("127.0.0.1 0 0"))
  }
  base = jset(base, "ANTIGRAVITY_GEMINI_DIR", js(join_path([home, "agy", ".gemini"])))
  base = jset(base, "AGY_CLI_DISABLE_AUTO_UPDATE", js("1"))
  match ctx.url("agyQuota") {
    Some(u) if u != "" => base = jset(base, "CLOUD_CODE_URL", js(u))
    _ => ()
  }
  let run_env = ctx.io.b.ask("shell.withShellCommand", [js(command), base, source])
  ctx.io.mkdir(home)
  let ran = ctx.io.b.ask("agy.run", [js(command), run_env, js(home)])
  let code = ran.get("code").unwrap_or(Null)
  let stdout = js_string(ran.get("stdout"))
  let stderr = js_string(ran.get("stderr"))
  if ran.get("authPrompted") == Some(Bool(true)) {
    raise Thrown(
      "RenewRefused",
      jobj([
        ("status", jint(401)),
        ("message", js(ctx.tr(lang, "station.quota.signInExpired"))),
      ]),
    )
  }
  let parsed = parse_json_line(stdout)
  if jget(parsed, "status") == Some(Str("SUCCESS")) {
    let (windows, scoped) = agy_allowance(ctx, parsed)
    if windows.length() == 0 && scoped.length() == 0 {
      let token = ctx.io.read_file_or_none(
        join_path([home, "agy", ".gemini", "antigravity-cli", "antigravity-oauth-token"]),
      ).unwrap_or("")
      if ctx.io.b.ask("agy.company", [js(token)]) == Bool(true) {
        return jobj([
          ("state", js("unsupported")),
          ("windows", jarr([])),
          ("detail", js(ctx.tr(lang, "station.quota.agyPayAsYouGo"))),
          ("checkedAt", jint(0)),
        ])
      }
    }
    let mut q = ok_or_unavailable(
      if windows.length() > 0 {
        windows
      } else {
        scoped
      },
      ctx.tr(lang, "station.quota.agyNoWindows"),
    )
    if q.get("state") == Some(Str("ok")) &&
      windows.length() > 0 &&
      scoped.length() > 0 {
      q = jset(q, "scoped", jarr(scoped))
    }
    return q
  }
  let said = match jget(parsed, "error") {
    Some(Str(e)) if trim_js(e) != "" => trim_js(e)
    _ => if trim_js(stderr) != "" { trim_js(stderr) } else { trim_js(stdout) }
  }
  // Google refusing the account until a person verifies it: blocked, saying where to verify it. Its page comes after
  // the first 300 characters.
  match agy_verify(said) {
    Some(url) => {
      let detail = if url != "" {
        ctx.tr(lang, "station.quota.agyVerifyAt", args=[("url", url)])
      } else {
        ctx.tr(lang, "station.quota.agyVerify")
      }
      return jobj([
        ("state", js("blocked")),
        ("windows", jarr([])),
        ("detail", js(detail)),
        ("checkedAt", jint(0)),
      ])
    }
    None => ()
  }
  if agy_location_ineligible(said) {
    match agy_direct_quota(ctx, home, lang) {
      Some(q) => return q
      None => ()
    }
  }
  let detail = slice(said, 0, b=300)
  if auth_failure(detail) {
    raise Thrown(
      "RenewRefused",
      jobj([
        ("status", jint(401)),
        ("message", js(ctx.tr(lang, "station.quota.signInExpired"))),
      ]),
    )
  }
  if network_failure(detail) {
    raise Thrown(
      "Error",
      jobj([
        (
          "message",
          js(if detail != "" { detail } else { "agy /usage network error" }),
        ),
        ("code", js("ECONNREFUSED")),
      ]),
    )
  }
  match agy_status(detail) {
    Some(status) =>
      return jobj([
        ("state", js("unavailable")),
        ("windows", jarr([])),
        (
          "detail",
          js(
            ctx.tr(lang, "station.quota.providerStatus", args=[
              ("provider", "Antigravity "),
              ("status", num_text(status)),
            ]),
          ),
        ),
        ("checkedAt", jint(0)),
        ("unanswered", jbool(true)),
      ])
    None => ()
  }
  raise plain_error(
    if detail != "" {
      detail
    } else {
      "agy exited (\{js_string(Some(code))})"
    },
  )
}
