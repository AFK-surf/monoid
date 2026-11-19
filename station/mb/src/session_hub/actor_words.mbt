// What a session's actor is told in the station's words, the part of station/src/sessions/actor.ts that is not the
// program's yet (what the actors in reader/actor_*.mbt ask Node as `node.words`, mb-actor.ts `#words`): a failed turn's
// notice, a limit its allowance showed, a compaction that failed, an agent that could not start, what a runtime too old
// said; when a turn is delivered; which failed turns a notice's 重试 takes up again; who wrote a message.

///|
/// actor.ts `timed`: the time said with every turn and every steer.
pub fn timed(text : String, now : Double) -> String {
  "[Delivered at \{iso(now)} (UTC)]\n\{text}"
}

///|
let again_reasons : Array[String] = ["network", "model", "other", "exited"]

///|
/// actor.ts `retryable`: a turn its notice's 重试 takes up again (`{outcome, declared, detail}`): one failed for the
/// provider's or the connection's reasons waiting on nothing, or one that completed in no state.
pub fn retryable(turn : Json) -> Bool {
  let outcome = str_of(turn, "outcome")
  let declared_null = match field(turn, "declared") {
    None | Some(Null) => true
    _ => false
  }
  let detail = str_of(turn, "detail").unwrap_or("")
  let failed_again = outcome == Some("failed") && declared_null && again_reasons.iter().any(r => detail.has_prefix("\{r}:"))
  let given_up = outcome == Some("completed") && declared_null
  failed_again || given_up
}

///|
/// actor.ts `SPENT_BEFORE`.
pub let spent_before : Array[String] = ["⚠️ 已达到额度或速率限制", "⚠️ Hit a usage or rate limit"]

///|
/// actor.ts `FALLBACK_MOST`: the most of the agent's last words shown in its place.
pub let fallback_most : Int = 4000

///|
/// actor.ts `codexTooOld`: Codex relays the provider's refusal of a version too old.
pub fn codex_too_old(message : String) -> Bool {
  let l = @jscase.lower(message)
  let a = index_of(l, "model requires a newer version of codex.")
  if a < 0 {
    return false
  }
  // \b before "model": not a word character before it
  if a > 0 && word_unit(u(l, a - 1)) {
    return false
  }
  let rest = slice(l, a + "model requires a newer version of codex.".length())
  let mut i = 0
  while i < rest.length() && @jscase.is_space(u(rest, i)) {
    i += 1
  }
  slice(rest, i).has_prefix("please upgrade to the latest app or cli and try again.")
}

///|
fn word_unit(c : Int) -> Bool {
  (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
  (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
  (c >= '0'.to_int() && c <= '9'.to_int()) ||
  c == '_'.to_int()
}

///|
/// runtime.ts `modelLimitOf`: the model whose own limit a refusal names (/\b(?:reached|hit) your ([\w.\- ]+?) limit\b/i),
/// none for the account's.
pub fn model_limit_of(text : String) -> String? {
  let l = @jscase.lower(text)
  let n = text.length()
  for start in 0..<n {
    if start > 0 && word_unit(u(text, start - 1)) {
      continue
    }
    let after = if slice(l, start).has_prefix("reached your ") {
      start + "reached your ".length()
    } else if slice(l, start).has_prefix("hit your ") {
      start + "hit your ".length()
    } else {
      continue
    }
    // the shortest run of [\w.\- ] followed by " limit\b"
    let mut i = after
    while i < n {
      let c = u(text, i)
      if !(word_unit(c) || c == '.'.to_int() || c == '-'.to_int() || c == ' '.to_int()) {
        break
      }
      if i > after && slice(l, i).has_prefix(" limit") {
        let end = i + " limit".length()
        if end >= n || !word_unit(u(text, end)) {
          let name = trim(slice(text, after, to=i))
          if name == "" {
            return None
          }
          return if account_limit(name) { None } else { Some(name) }
        }
      }
      i += 1
    }
  }
  None
}

///|
/// runtime.ts `ACCOUNT_LIMIT`: /\b(?:usage|session|weekly|daily|monthly|spend|rate|\d+[- ]hour)\b/i.
fn account_limit(name : String) -> Bool {
  let l = @jscase.lower(name)
  let words = ["usage", "session", "weekly", "daily", "monthly", "spend", "rate"]
  let n = l.length()
  for start in 0..<n {
    if start > 0 && word_unit(u(l, start - 1)) {
      continue
    }
    for w in words {
      let end = start + w.length()
      if slice(l, start).has_prefix(w) && (end >= n || !word_unit(u(l, end))) {
        return true
      }
    }
    // \d+[- ]hour\b
    let mut i = start
    while i < n && is_digit_unit(u(l, i)) {
      i += 1
    }
    if i > start && i < n && (u(l, i) == '-'.to_int() || u(l, i) == ' '.to_int()) && slice(l, i + 1).has_prefix("hour") {
      let end = i + 5
      if end >= n || !word_unit(u(l, end)) {
        return true
      }
    }
  }
  false
}

///|
/// actor.ts `withSaid`: `words`, and under them what failed said itself, as a code block.
pub fn with_said(words : String, said : String) -> String {
  let raw = replace_all(trim(said), "```", "ʼʼʼ")
  if raw == "" {
    words
  } else {
    "\{words}\n\n```\n\{raw}\n```"
  }
}

///|
let first_line_most : Int = 200

///|
/// actor.ts `firstLine` (of what failed said, short enough for a notice's line and a push; by UTF-16 units).
fn failure_first_line(said : String) -> String {
  let line = trim(split(trim(said), "\n")[0])
  if line.length() > first_line_most {
    trim_end(slice(line, 0, to=first_line_most - 1)) + "…"
  } else {
    line
  }
}

///|
/// actor.ts `failureNotice`: a failed turn (`{kind, reason, message}`) as its chat is told it.
pub fn failure_notice(words : Words, outcome : Json) -> String {
  if str_of(outcome, "kind") != Some("failed") {
    return ""
  }
  let reason = str_of(outcome, "reason").unwrap_or("")
  let message = str_of(outcome, "message").unwrap_or("")
  let model = if reason == "rate_limit" { model_limit_of(message) } else { None }
  match model {
    Some(m) => return "⚠️ \{with_said(words.tr("station.notice.modelLimit", args=[("model", Json::string(m))]), message)}"
    None => ()
  }
  let key = if reason == "rate_limit" {
    "rateLimit"
  } else if reason == "other" {
    "failed"
  } else {
    reason
  }
  let why = if reason == "model" || reason == "other" { failure_first_line(message) } else { "" }
  let said = if why == "" {
    words.tr("station.notice.\{key}")
  } else {
    words.tr("station.notice.\{key}Why", args=[("why", Json::string(why))])
  }
  "⚠️ \{with_said(said, message)}"
}

///|
/// actor.ts `LIMIT_SHOWN`.
pub let limit_shown : String = "limit:"

///|
/// actor.ts `shownLimitOf`: what a turn's detail says its allowance showed: the model's limit by its name (Some(Some)),
/// the account's (Some(None)), none (None).
pub fn shown_limit_of(detail : String?) -> String?? {
  match detail {
    Some(d) if d.has_prefix(limit_shown) => {
      let end = index_of(d, ": ", from=limit_shown.length())
      let name = if end < 0 { slice(d, limit_shown.length()) } else { slice(d, limit_shown.length(), to=end) }
      Some(if name == "" { None } else { Some(name) })
    }
    _ => None
  }
}

///|
/// actor.ts `limitShownNotice`.
pub fn limit_shown_notice(words : Words, model : String?, said : String) -> String {
  let w = match model {
    None => words.tr("station.notice.limitShownAccount")
    Some(m) => words.tr("station.notice.limitShown", args=[("model", Json::string(m))])
  }
  "⚠️ \{with_said(w, said)}"
}

///|
fn failure_words(words : Words, reason : String) -> String {
  words.tr("station.failure.\{if reason == "rate_limit" { "rateLimit" } else { reason }}")
}

///|
/// actor.ts `compactFailedNotice`: that its compaction failed.
pub fn compact_failed_notice(words : Words, outcome : Json) -> String {
  let message = str_of(outcome, "message").unwrap_or("")
  let why = if @jscase.lower(message).contains("not enough messages") {
    words.tr("station.context.tooShort")
  } else {
    failure_words(words, str_of(outcome, "reason").unwrap_or(""))
  }
  "⚠️ \{with_said(words.tr("station.notice.compactFailed", args=[("why", Json::string(why))]), message)}"
}

///|
/// What failed as the runtime said it (runtime.ts `failureOf`, the claude package's).
pub fn failure_reason(message : String) -> String {
  @claude.failure_of(message)
}

///|
/// actor.ts `cannotStartWords`: why its agent could not start. `said`: the station's own words (`Said`).
pub fn cannot_start_words(words : Words, message : String, said : Bool) -> String {
  if said {
    return words.tr("station.notice.cannotStartWhy", args=[("why", Json::string(message))])
  }
  let reason = failure_reason(message)
  let w = if ["auth", "refused", "blocked", "network"].contains(reason) {
    words.tr("station.notice.cannotStartWhy", args=[("why", Json::string(failure_words(words, reason)))])
  } else {
    words.tr("station.notice.cannotStart")
  }
  with_said(w, message)
}

///|
/// actor.ts `compactFailed`: compaction that could not begin, in words.
pub fn compact_failed(words : Words, message : String, said : Bool) -> String {
  if said {
    return words.tr("station.notice.compactFailed", args=[("why", Json::string(message))])
  }
  words.tr("station.notice.compactFailed", args=[("why", Json::string(failure_words(words, failure_reason(message))))])
}

///|
/// What a message is quoted as in the agent's words (mb-actor.ts `quoted`): at most `fallback_most` characters, each line
/// marked.
pub fn quoted(text : String) -> String {
  let cut = if text.length() <= fallback_most { text } else { take(text, fallback_most) }
  split(cut, "\n").map(line => "> \{line}").join("\n")
}

///|
/// actor.ts `personRef`: who wrote a message, as a creator reference.
pub fn person_ref(m : Json) -> String {
  let message = field(m, "message").unwrap_or(Json::null())
  let author = str_of(message, "author").unwrap_or("")
  if str_of(m, "surface") == Some(stillfail_surface) {
    author
  } else {
    "slack:\{str_of(m, "connect").unwrap_or("")}:\{author}"
  }
}

///|
/// What the actors ask of the station's words (`node.words`), by name: answered here where it is this package's.
pub fn words_answer(words : Words, name : String, args : Array[Json]) -> Json raise Refused {
  let s = (i : Int) => match args.get(i) {
    Some(String(t)) => t
    _ => ""
  }
  match name {
    "shownLimitOf" =>
      match shown_limit_of(match args.get(0) { Some(String(d)) => Some(d); _ => None }) {
        None => Json::null()
        Some(m) => { "model": opt_str(m) }
      }
    "runtimeLabel" => Json::string(runtime_label(s(0)))
    "compactFailed" | "cannotStartWords" => {
      let e = args.get(0).unwrap_or(Json::null())
      let message = match field(e, "message") {
        Some(String(m)) => m
        _ => js_string(e)
      }
      let said = is_true(e, "said")
      Json::string(if name == "compactFailed" { compact_failed(words, message, said) } else { cannot_start_words(words, message, said) })
    }
    "compactFailedNotice" => Json::string(compact_failed_notice(words, args.get(0).unwrap_or(Json::null())))
    "failureNotice" => Json::string(failure_notice(words, args.get(0).unwrap_or(Json::null())))
    "limitShownNotice" =>
      Json::string(limit_shown_notice(words, match args.get(0) { Some(String(m)) => Some(m); _ => None }, s(1)))
    "codexStillOld" => Json::string("⚠️ \{with_said(words.tr("station.notice.codexStillOld"), s(0))}")
    "codexTooOld" => Json::boolean(codex_too_old(s(0)))
    "modelLimitOf" => opt_str(model_limit_of(s(0)))
    "spentBefore" => Json::array(spent_before.map(Json::string))
    "quoted" => Json::string(quoted(s(0)))
    _ => raise Refused("no words named \{name}")
  }
}
