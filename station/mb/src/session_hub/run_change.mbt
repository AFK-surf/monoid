// A session's run changed (station/src/sessions/run-change.ts; lifecycle `configure`): how it ran and how it runs now,
// as its chat's notice keeps them (rows.ts RunChange), and the notice's words where a chat shows no more than them.
// What the most context a session runs with may be (context-cap.ts) is here too.

///|
/// `runShown`: how session `row` (a SessionRow as JSON) runs, its account named by `named` (None: a profile the
/// station no longer has).
pub fn run_shown(row : Json, named : (String) -> String?) -> Json {
  let profile = str_of(row, "profile").unwrap_or("")
  let out : Map[String, Json] = {
    "runtime": field(row, "runtime").unwrap_or(Json::null()),
    "model": field(row, "model").unwrap_or(Json::null()),
    "effort": field(row, "effort").unwrap_or(Json::null()),
    "fast": field(row, "fast").unwrap_or(Json::null()),
  }
  if field(row, "tui") == Some(Json::boolean(true)) { out["tui"] = Json::boolean(true) }
  match field(row, "speed") {
    Some(String(s)) if s != "" => out["speed"] = Json::string(s)
    _ => ()
  }
  out["profile"] = field(row, "profile").unwrap_or(Json::null())
  out["account"] = opt_str(named(profile))
  out["pinned"] = field(row, "profilePinned").unwrap_or(Json::null())
  out["context"] = field(row, "context").unwrap_or(Json::null())
  Json::object(out)
}

///|
let run_parts : Array[String] = ["runtime", "model", "effort", "fast", "tui"]

///|
fn part_differs(change : Json, k : String) -> Bool {
  let was = field(change, "was").unwrap_or(Json::null())
  let now = field(change, "now").unwrap_or(Json::null())
  if k == "fast" {
    chosen_speed(was) != chosen_speed(now)
  } else {
    !same(field(was, k), field(now, k))
  }
}

///|
/// `runChanged`: what a change by hand posts a notice for: another runtime, model, effort or speed.
pub fn run_changed(change : Json) -> Bool {
  run_parts.iter().any(k => part_differs(change, k))
}

///|
/// `runChangeWords`: the notice's words: what changed, before and after, or another account alone.
pub fn run_change_words(words : Words, change : Json, lang : String) -> String {
  let part = (r : Json, k : String) => match k {
    "runtime" => {
      let rt = match str_of(r, "runtime") {
        Some(s) => runtime_named(s).unwrap_or("claude")
        None => "claude"
      }
      runtime_label(rt)
    }
    "model" =>
      match str_of(r, "model") {
        None => words.tr("station.notice.runDefaultModel", lang~)
        Some(m) => model_name(m)
      }
    "effort" =>
      match str_of(r, "effort") {
        Some(e) => e
        None => words.tr("station.notice.runDefaultEffort", lang~)
      }
    "tui" => if field(r, "tui") == Some(Json::boolean(true)) { "TUI" } else { "Print" }
    "fast" =>
      match chosen_speed(r) {
        Some("ultrafast") => "Ultrafast"
        Some("fast") => "Fast"
        _ => words.tr("station.notice.runStandard", lang~)
      }
    _ =>
      match str_of(r, "account") {
        Some(a) => a
        None => str_of(r, "profile").unwrap_or("")
      }
  }
  let differs = (run_parts + ["profile"]).filter(k => part_differs(change, k))
  let changed = if differs.length() > 1 {
    differs.filter(k => k != "profile")
  } else {
    differs
  }
  let side = (r : Json) => changed.map(k => part(r, k)).join(" · ")
  let key = if changed.length() == 1 && changed[0] == "profile" {
    "station.notice.runAccountChanged"
  } else {
    "station.notice.runChanged"
  }
  let was = field(change, "was").unwrap_or(Json::null())
  let now = field(change, "now").unwrap_or(Json::null())
  words.tr(key, args=[("was", Json::string(side(was))), ("now", Json::string(side(now)))], lang~)
}

// ── context-cap.ts ──

///|
/// The runtimes that take a cap.
pub let context_runtimes : Array[String] = ["claude", "codex"]

///|
/// The least a cap can be: Claude Code's autoCompactWindow takes 100,000 tokens and up.
pub let context_least : Double = 100_000.0

///|
let context_most : Double = 10_000_000.0

///|
/// `contextAsked`: a cap as asked: None when not asked (undefined), Some(None) for the model's whole window (null).
pub fn context_asked(words : Words, v : Json?, lang : String) -> Double?? raise Refused {
  match v {
    None => None
    Some(Null) => Some(None)
    Some(Number(n, ..)) if n == n.floor() && n >= context_least && n <= context_most =>
      Some(Some(n))
    Some(_) =>
      raise Refused(
        words.tr("station.session.badContext", args=[("least", num(context_least))], lang~),
      )
  }
}

///|
/// `checkContext`: refuses, in `lang`, a cap asked of a runtime that does not take one.
pub fn check_context(words : Words, runtime : String, context : Double?, lang : String) -> Unit raise Refused {
  if context is Some(_) && !context_runtimes.contains(runtime) {
    raise Refused(words.tr("station.session.contextRuntimes", lang~))
  }
}
