// What an agent is doing, said in the Slack thread it works for while it works (station/src/slack/status.ts, the
// line's pacing connects/status.ts): an agent session under the thread (agents.sessions.setStatus). Where Slack will
// not show one (the app lacks the scope, the conversation does not take it), an 👀 on the message that started the work
// says the same, and goes when it is done.

///|
/// How often the status line may change: Slack's limit on the call, and enough to follow along.
pub let min_interval_ms : Int = 2000

///|
let fallback_reaction : String = "eyes"

///|
/// What Slack answers when it will not show a status here: the reaction says it instead.
fn no_status(error : String) -> Bool {
  [
    "missing_scope", "unknown_method", "not_allowed_token_type", "feature_not_enabled", "method_not_supported_for_channel_type",
    "not_in_channel",
  ]
  .iter()
  .any(code => error.contains(code))
}

///|
/// A Web API call as the bot; fails with Slack's error.
pub type Call = async (String, Params) -> Unit

///|
/// What a line's timers run on: the time now, a wait, and a fiber of whoever owns it (its timers end with it).
pub struct Clock {
  now : () -> Double
  sleep : async (Int) -> Unit
  fork : (async () -> Unit) -> @effect.Fiber[Unit]
}

///|
/// `f` run as a fiber of the clock's, not waited for.
pub fn Clock::run(self : Clock, f : async () -> Unit) -> Unit {
  ignore((self.fork)(f))
}

///|
/// One thread's status line (connects/status.ts `StatusLine` with slack/status.ts `ThreadStatus`): changed at most once
/// an interval (the first change at once), one change at a time and in order, only the latest of those said meanwhile,
/// cleared ("") once the turn ends. `say("")` clears it.
pub struct ThreadStatus {
  call : Call
  clock : Clock
  log : Log
  channel : String
  thread_ts : String
  interval : Int
  /// The message that started the work, and the session's page in still.fail (where there is one), as last said.
  mut message_ts : String?
  mut page : String?
  mut shown : String
  mut wanted : String
  /// When it last changed (never, at first: the first change goes at once).
  mut last_at : Double
  mut timer : Bool
  priv sending : Chains
  /// Slack will not show a status line here: the reaction stands in.
  mut reaction_only : Bool
  /// An app that cannot yet use agent sessions can still show the older status for this turn.
  mut legacy : Bool
  mut reacted : String?
}

///|
pub fn ThreadStatus::new(call : Call, clock : Clock, log : Log, channel : String, thread_ts : String) -> ThreadStatus {
  {
    call,
    clock,
    log,
    channel,
    thread_ts,
    interval: min_interval_ms,
    message_ts: None,
    page: None,
    shown: "",
    wanted: "",
    last_at: -@double.infinity,
    timer: false,
    sending: { tails: {} },
    reaction_only: false,
    legacy: false,
    reacted: None,
  }
}

///|
pub fn ThreadStatus::say(self : ThreadStatus, status : String, message_ts? : String? = None, page? : String? = None) -> Unit {
  if message_ts is Some(_) {
    self.message_ts = message_ts
  }
  if page is Some(_) {
    self.page = page
  }
  self.wanted = status
  if self.timer {
    return
  }
  self.timer = true
  self.clock.run(async fn() {
    let now = (self.clock.now)()
    let wait = if status == "" { 0.0 } else { {
      let w = self.last_at + self.interval.to_double() - now
      if w > 0.0 { w } else { 0.0 }
    } }
    (self.clock.sleep)(wait.to_int())
    self.due((self.clock.now)())
  })
}

///|
async fn ThreadStatus::due(self : ThreadStatus, now : Double) -> Unit {
  self.timer = false
  if self.wanted == self.shown {
    return
  }
  self.last_at = now
  let was = self.shown
  let next = self.wanted
  // Shown as it goes: said again meanwhile, it does not go twice; not shown after all, it goes with the next.
  self.shown = next
  self.sending.run("", async fn() {
    let ok = self.show(next) catch { _ => false }
    if !ok && self.shown == next {
      self.shown = was
    }
  })
}

///|
fn ThreadStatus::warn(self : ThreadStatus, words : String, said : String) -> Unit {
  (self.log)("warn", "slack", words, jo([("channel", js(self.channel)), ("thread", js(self.thread_ts)), ("error", js(said))]))
}

///|
async fn ThreadStatus::show(self : ThreadStatus, status : String) -> Bool {
  if !self.reaction_only {
    let address = [("channel_id", self.channel), ("thread_ts", self.thread_ts)]
    if !self.legacy {
      let failed = try {
        (self.call)("agents.sessions.setStatus", address + [("status", if status == "" { "active" } else { "processing" })])
        None
      } catch {
        e => Some(message_of(e))
      }
      match failed {
        None => return true
        Some(said) => {
          if !no_status(said) && !["not_authorized", "feature_disabled"].iter().any(c => said.contains(c)) {
            self.warn("could not say the agent's status in Slack", said)
            return false
          }
          self.legacy = true
        }
      }
    }
    let params = address + [("status", status)]
    if status != "" {
      params.push(("loading_messages", status))
    }
    let failed = try {
      (self.call)("assistant.threads.setStatus", params)
      None
    } catch {
      e => Some(message_of(e))
    }
    match failed {
      None => {
        if status == "" {
          self.legacy = false
        }
        return true
      }
      Some(said) => {
        if !no_status(said) {
          self.warn("could not say the agent's status in Slack", said)
          return false
        }
        self.reaction_only = true
      }
    }
  }
  let target = self.message_ts
  let reacted = self.reacted
  let failed = try {
    if status != "" {
      match target {
        Some(t) if reacted != Some(t) => {
          (self.call)("reactions.add", self.reaction(t))
          self.reacted = Some(t)
        }
        _ => ()
      }
    } else {
      match reacted {
        Some(r) => {
          self.reacted = None
          (self.call)("reactions.remove", self.reaction(r))
        }
        None => ()
      }
    }
    None
  } catch {
    e => Some(message_of(e))
  }
  match failed {
    Some(said) if !said.contains("already_reacted") && !said.contains("no_reaction") =>
      (self.log)("warn", "slack", "could not mark the agent's work in Slack", jo([("channel", js(self.channel)), ("error", js(said))]))
    _ => ()
  }
  true
}

///|
fn ThreadStatus::reaction(self : ThreadStatus, timestamp : String) -> Params {
  [("channel", self.channel), ("timestamp", timestamp), ("name", fallback_reaction)]
}
