// Clocks shown running, and a chat's agent read from its view: what both frames show of them.

///|
/// A second: what a clock shown in whole seconds goes on by.
pub let second_ms : Double = 1000.0

///|
/// A running clock's reading in short: 45s, 3m 20s, 1h 5m.
pub fn elapsed(ms : Double) -> String {
  let s = (if ms > 0.0 { ms / 1000.0 } else { 0.0 }).to_int()
  if s < 60 {
    "\{s}s"
  } else if s < 3600 {
    if s % 60 != 0 {
      "\{s / 60}m \{s % 60}s"
    } else {
      "\{s / 60}m"
    }
  } else if s % 3600 / 60 != 0 {
    "\{s / 3600}h \{s % 3600 / 60}m"
  } else {
    "\{s / 3600}h"
  }
}

///|
/// The agent of a chat by its session, as the chat's view has it.
pub fn agent_json(chat : Json?, key : String) -> Json? {
  for a in items(chat, "agents") {
    if text(field(Some(a), "session"), "key") == key {
      return Some(a)
    }
  }
  None
}

