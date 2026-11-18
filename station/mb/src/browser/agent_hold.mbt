// An agent operating a tab of its chat's browser over DevTools (`Gate`, src/browser/agent-hold.ts): joined to
// `browser:<target>` in `ScreenHub` as `"agent: <its chat>"`, so people watching see `agent: … 正在控制` and passive
// views yield (`watchOnly`) without fighting the agent's clicks and navigations. When a person explicitly takes control
// (`[接管]`, `taken: true`), the agent's operating commands are refused until they leave.

///|
pub let agent_hold_idle_ms : Double = 15000.0

///|
pub(all) struct AgentHoldHub {
  driving_people : (String) -> Array[String]
  has_taken_view : (String) -> Bool
  yield_to_agent : (String, String) -> Int
  join_agent : (String, String) -> () -> Unit
}

///|
priv struct HeldEntry {
  session : String
  leave : () -> Unit
  mut cancel : () -> Unit
}

///|
pub struct BrowserAgentHold {
  priv hub : AgentHoldHub
  priv name_of : (String) -> String
  priv clock : Clock
  priv active : Map[String, HeldEntry]
  priv mut closed : Bool
}

///|
pub fn BrowserAgentHold::new(hub : AgentHoldHub, name_of : (String) -> String, clock : Clock) -> BrowserAgentHold {
  { hub, name_of, clock, active: {}, closed: false }
}

///|
fn BrowserAgentHold::release_key(self : BrowserAgentHold, key : String) -> Unit {
  match self.active.get(key) {
    Some(entry) => {
      self.active.remove(key)
      (entry.cancel)()
      (entry.leave)()
    }
    None => ()
  }
}

///|
pub fn BrowserAgentHold::act(self : BrowserAgentHold, session : String, target : String, m : String) -> String? {
  let screen_id = "browser:\{target}"
  let key = "\{session}\n\{target}"
  let who = (self.hub.driving_people)(screen_id)
  if who.length() > 0 && (self.active.contains(key) || (self.hub.has_taken_view)(screen_id)) {
    self.release_key(key)
    let names = who.join(", ")
    let verb = if who.length() > 1 { "are" } else { "is" }
    return Some(
      "\{names} \{verb} controlling \{screen_id} right now, so \{m} was not sent: do not fight them. Wait until they leave it or ask them in the chat.",
    )
  }
  if m == "Target.closeTarget" || self.closed {
    self.release_key(key)
    return None
  }
  let by = (self.name_of)(session)
  let entry = match self.active.get(key) {
    Some(e) => e
    None => {
      let leave = (self.hub.join_agent)(screen_id, by)
      let e : HeldEntry = { session, leave, cancel: () => () }
      self.active[key] = e
      e
    }
  }
  if who.length() > 0 {
    ignore((self.hub.yield_to_agent)(screen_id, by))
  }
  (entry.cancel)()
  entry.cancel = (self.clock.after)(agent_hold_idle_ms, async fn() { self.release_key(key) })
  None
}

///|
pub fn BrowserAgentHold::release_session(self : BrowserAgentHold, session : String) -> Unit {
  for key in self.active.keys().collect() {
    match self.active.get(key) {
      Some(entry) if entry.session == session => self.release_key(key)
      _ => ()
    }
  }
}

///|
pub fn BrowserAgentHold::close(self : BrowserAgentHold) -> Unit {
  self.closed = true
  for key in self.active.keys().collect() {
    self.release_key(key)
  }
}
