// When a session goes on in a new runtime session instead of taking up its own (station/src/sessions/afresh.ts): its
// next turn runs on another account than the one its conversation last ran on, or its prompt cache is over and it is
// worth reading back rather than sending whole again. What the agent is told then (agents/instructions.ts `afresh`,
// `cleared`, `longChat`, `resumeLost`), and a session's usage now (read/usage.ts `usageNow`), which it is decided by.

///|
/// read/usage.ts `price`: (input, output, cache read) dollars a million tokens, delegated to `@ops_platform`.
pub using @ops_platform {model_price as price}

///|
let cache_calls : Int = 5

///|
/// read/usage.ts `usageNow`: a session's usage now, from what is recorded of its calls (None before one is).
pub fn Hub::usage_now(self : Hub, key : String) -> Json? raise {
  let groups = self.store.usage_of_session(key)
  let all = self.store.last_contexts(key, cache_calls)
  let since = match self.store.conversation_since(key) {
    Number(s, ..) => Some(s)
    _ => None
  }
  let saved = match self.store.saved_compact_context(key) {
    Object(_) as s => Some(s)
    _ => None
  }
  match @ops_platform.usage_now(groups, all, since, saved) {
    Null => None
    u => Some(u)
  }
}

// ── what the agent is told (agents/instructions.ts) ──

///|
/// instructions.ts `LONG_CHAT`.
pub let long_chat_from : Int = 20

///|
/// What a session's older threads left out of a list are said as.
pub let older_threads : String = "and older ones (chat_list finds them)"

///|
pub fn told_afresh(key : String, threads : Array[String]) -> String {
  "This is a new conversation: your earlier one in this session is no longer used. Before you act on what comes below, read back from it what you need: session_history with chat \{key} (the latest entries first; older ones with before)\{if threads.length() == 0 { "" } else { ", and chat_history for " + threads.join(", ") }}."
}

///|
pub fn told_cleared_words(key : String, threads : Array[String]) -> String {
  "People cleared your context: this is a new conversation in the same chat, and your earlier one in this session is no longer loaded. Read the chat back before you act on what comes below\{if threads.length() == 0 { "" } else { ": chat_history for " + threads.join(", ") }}. Your earlier work (session_history with chat \{key}) is not to be read back by default: only when you need something from it."
}

///|
pub fn told_long_chat_words(count : Int, threads : Array[String]) -> String {
  "This chat is long (\{count} messages), and most of it is no longer in front of you. Before you go on, read back what people said in it\{if threads.length() == 0 { "" } else { " (chat_history for " + threads.join(", ") + ", older pages with before)" }}: their requests, decisions and corrections from the start. Check that what you are doing still follows them, so that you do not drift from what they asked."
}

///|
pub fn told_resume_lost_words(key : String, threads : Array[String], terminal : String?) -> String {
  let term = match terminal {
    None => ""
    Some(t) => "this session began in a terminal, and what was said there is in \{t} (its runtime's own transcript: read it from its end); "
  }
  "Your earlier conversation could not be restored: this is a new one. Before you answer, read back what you need from where it is: \{term}session_history with chat \{key} (the latest entries first; older ones with before)\{if threads.length() == 0 { "" } else { ", and chat_history for " + threads.join(", ") }}."
}

///|
/// The recent threads of a session (store `recentSessionThreads`, its RECENT_THREADS), and whether it has more.
fn Hub::recent_threads(self : Hub, key : String) -> (Array[Json], Bool) raise {
  let r = self.tw(() => self.threads.recent_session_threads(Json::string(key), num(20.0)))
  (items(field(r, "threads")), is_true(r, "more"))
}

///|
/// `threadsToldOf`: the addresses of a session's threads its agent is told to read back.
pub fn Hub::threads_told_of(self : Hub, key : String, recent? : (Array[Json], Bool)) -> Array[String] raise {
  let (threads, more) = match recent {
    Some(r) => r
    None => self.recent_threads(key)
  }
  let told = threads.map(t => {
    let th = field(t, "thread").unwrap_or(Json::null())
    "\{str_of(th, "channel").unwrap_or("")}/\{str_of(th, "threadTs").unwrap_or("")}"
  })
  if more {
    told + [older_threads]
  } else {
    told
  }
}

///|
/// `startsAfresh`: what a session going on on profile `to` is told when it starts afresh rather than take up runtime
/// session `id` (last run on `was` where the store has no record of it); None when it takes it up.
pub fn Hub::starts_afresh(self : Hub, key : String, id : String, to : String, was : String?) -> String? raise {
  let row = self.get_session(key)
  let source = self.store.runtime_session_source(key, id)
  match (row, source) {
    (Some(r), Object(_)) if str_of(source, "runtime") != str_of(r, "runtime") =>
      return Some(told_afresh(key, self.threads_told_of(key)))
    _ => ()
  }
  let from = match self.store.ran_on(key, Json::string(id)) {
    String(p) => Some(p)
    _ => was
  }
  match from {
    None => None
    Some(f) if f == to => None
    Some(_) => Some(told_afresh(key, self.threads_told_of(key)))
  }
}

///|
/// `toldCleared`: what a session whose context was cleared by hand is told as its new runtime session starts.
pub fn Hub::told_cleared(self : Hub, key : String, read_back? : Bool = false) -> String raise {
  let threads = self.threads_told_of(key)
  if read_back {
    told_afresh(key, threads)
  } else {
    told_cleared_words(key, threads)
  }
}

///|
/// cache-policy.ts `coldWorth` and `coldAfresh`.
let cold_from : Double = 50_000.0

///|
pub fn cold_worth(context : Double, cost : Double?, threshold : Double?, chosen : Json?, enabled : Bool) -> Bool {
  chosen == Some(Json::boolean(true)) ||
  (enabled && threshold == Some(0.0)) ||
  context >= cold_from ||
  (match (threshold, cost) {
    (Some(t), Some(c)) => c >= t
    _ => false
  })
}

///|
pub fn cold_afresh(chosen : Json?, enabled : Bool, threshold : Double?, cost : Double?) -> Bool {
  match chosen {
    Some(True) => return true
    Some(False) => return false
    _ => ()
  }
  if !enabled {
    return false
  }
  match threshold {
    None => true
    Some(0.0) => true
    Some(t) =>
      match cost {
        Some(c) => c >= t
        None => false
      }
  }
}

///|
/// `goesAfresh`: whether session `key` started at `now` is to start afresh.
pub fn Hub::goes_afresh(self : Hub, key : String, now : Double) -> Bool raise {
  let row = match self.get_session(key) {
    Some(r) => r
    None => return false
  }
  match field(row, "runtimeSessionId") {
    None | Some(Null) => return false
    _ => ()
  }
  let u = match self.usage_now(key) {
    Some(u) => u
    None => return false
  }
  let (last, cache) = match (num_of(u, "lastCallAt"), num_of(u, "cacheMs")) {
    (Some(l), Some(c)) => (l, c)
    _ => return false
  }
  if last + cache > now {
    return false
  }
  let config = self.config()
  let when_cold = is_true(config, "afreshWhenCold")
  let above = num_of(config, "afreshAbove")
  let chosen = field(row, "afresh")
  let threshold = if when_cold || chosen == Some(Json::boolean(true)) { above } else { None }
  let cost = num_of(u, "rereadCost")
  cold_worth(num_of(u, "contextTokens").unwrap_or(0.0), cost, threshold, chosen, when_cold) &&
  cold_afresh(chosen, when_cold, above, cost)
}

///|
/// `toldLongChat`: what a session compacted or gone on in a new conversation is told when its chats are long.
pub fn Hub::told_long_chat(self : Hub, key : String) -> String? raise {
  let recent = self.recent_threads(key)
  let mut count = 0
  for t in recent.0 {
    let id = field(field(t, "thread").unwrap_or(Json::null()), "id").unwrap_or(Json::null())
    count += match self.tw(() => self.threads.message_count(id)) {
      Number(n, ..) => n.to_int()
      _ => 0
    }
  }
  if count > long_chat_from {
    Some(told_long_chat_words(count, self.threads_told_of(key, recent~)))
  } else {
    None
  }
}

///|
/// `toldResumeLost`: what a session whose runtime session could not be resumed is told as its new one starts; one
/// continued from a terminal is told where that conversation is on the machine (the world's to find).
pub async fn Hub::told_resume_lost(self : Hub, key : String) -> String {
  let threads = self.threads_told_of(key)
  let row = self.get_session(key)
  let first = self.store.runtime_sessions(key).get(0)
  let runtime = match row {
    Some(r) =>
      match str_of(r, "runtime") {
        Some("claude" | "codex" as rt) => Some(rt)
        _ => None
      }
    None => None
  }
  let terminal = match (row, first, runtime) {
    (Some(r), Some(f), Some(rt)) if str_of(r, "cwd") is Some(c) && c != "" =>
      match (self.world.ask)("machine.transcriptOf", { "runtime": Json::string(rt), "id": f }) {
        String(t) => Some(t)
        _ => None
      }
    _ => None
  }
  told_resume_lost_words(key, threads, terminal)
}
