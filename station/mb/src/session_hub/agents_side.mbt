// The agents' side of the station as it decides what the hub does (station/src/sessions/agents.ts `AgentsLive`: its
// `follow` and `start`): the station taken up once the process before is gone (turns held until the agents' door is
// open, then released, and what was cut off resumed); its workspaces followed as the control plane says them (out of
// one it had joined: its sessions end; back: they resume; a new home: the old home's chats said to be its own; out of
// every one: turns held and every process ended; in again: turns go on); made one that only runs tasks. What is not
// the hub's (the parts that go along, the jobs, the door, the rig's grants) the world's (`agents.*`). Also what the
// station's own requests of other stations are routed by (`local`), and a session's page and name.

///|
/// agents.ts `SWEEP_MS`: how often the old sandbox-name lookup is looked for, to take it down.
pub let sweep_ms : Double = 180_000.0

///|
/// agents.ts `LISTINGS`: what a runtime needs of its sessions' list of tools (the budget of Antigravity's, the tools
/// Claude Code loads at once), by what was measured of it; one not named is declared every tool as it is.
pub fn listing(runtime : String, agy_budget : Json, claude_loaded : Json) -> Json? {
  match runtime {
    "agy" => Some({ "budget": agy_budget })
    "claude" => Some({ "loaded": claude_loaded })
    _ => None
  }
}

///|
/// What the control plane says of where the station is (cloud/state.ts): whether it is in a workspace (`bound`), the
/// workspaces it joined (not its home), its home, the first of its memberships, whether it was removed, and a rig due.
pub(all) struct Place {
  bound : Bool
  joined : Array[String]
  home : String?
  first : String?
  removed : Bool
  /// Workspaces due to only run tasks (`rig_due`), and what each owner asked (`rig_pending` map ws -> pending).
  rig_due : Array[String]
  rig_pending : Json?
}

///|
pub struct AgentsSide {
  hub : Hub
  mut in_workspace : Bool
  mut joined_now : Array[String]
  mut home_now : String?
  mut taken : Bool
}

///|
pub fn AgentsSide::new(hub : Hub, place : Place) -> AgentsSide {
  { hub, in_workspace: place.bound, joined_now: place.joined.copy(), home_now: place.home, taken: false }
}

///|
/// `follow`: the control plane said where the station is now.
pub async fn AgentsSide::follow(self : AgentsSide, place : Place) -> Unit {
  let hub = self.hub
  let world = hub.world
  if place.rig_due.length() > 0 {
    let mut became_any = false
    let remaining_full = place.joined
      .filter(w => !place.rig_due.contains(w))
      .length() +
      (match place.home {
        Some(h) if !place.rig_due.contains(h) => 1
        _ => 0
      })
    for ws in place.rig_due {
      let due = match place.rig_pending {
        Some(Object(m)) => m.get(ws)
        _ => None
      }
      match due {
        None => (world.tell)("agents.rigDueDropped", { "ws": Json::string(ws) })
        Some(due_val) => {
          became_any = true
          // If no full workspace remains besides those becoming rigs, suspend everything and hand over to RigLive.
          if remaining_full == 0 {
            hub.hold("unbound")
            hub.suspend_all()
            ignore((world.ask)("agents.along", "left"))
            ignore((world.ask)("agents.jobsStopAll", "this station only runs tasks now"))
            ignore((world.ask)("agents.becomeRig", { "ws": Json::string(ws), "due": due_val }))
            return
          } else {
            if Some(ws) == self.home_now {
              self.hub.store.set_sessions_ws(Json::null(), Json::string(ws))
            }
            hub.left_workspace(ws)
            ignore((world.ask)("agents.becomeRig", { "ws": Json::string(ws), "due": due_val }))
          }
        }
      }
    }
    if became_any {
      ignore((world.ask)("agents.along", "changed"))
      return
    }
  }
  let now = place.bound
  let joined = place.joined
  // A new home workspace: one it had joined took over from a home it was taken out of (the old home's chats, those
  // that say no workspace, said to be that one's), or it moved (its chats of the old home go along).
  match (place.home, self.home_now) {
    (Some(home), Some(was)) if home != was =>
      if self.joined_now.contains(home) {
        self.hub.store.set_sessions_ws(Json::null(), Json::string(was))
      } else {
        self.hub.store.set_sessions_ws(Json::string(was), Json::null())
      }
    _ => ()
  }
  match place.home {
    Some(h) => self.home_now = Some(h)
    None => ()
  }
  let left = self.joined_now.filter(w => !joined.contains(w) && place.first != Some(w))
  let back = joined.filter(w => !self.joined_now.contains(w))
  self.joined_now = joined.copy()
  if now && now == self.in_workspace {
    for ws in left {
      hub.left_workspace(ws)
    }
    for ws in back {
      hub.back_in(ws)
    }
    if left.length() > 0 || back.length() > 0 {
      ignore((world.ask)("agents.along", "changed"))
    }
  }
  if now == self.in_workspace {
    return
  }
  self.in_workspace = now
  if now {
    ignore((world.ask)("agents.along", "joined"))
    hub.recover()
    ignore((world.ask)("agents.jobsRelaunch", Json::null()))
    hub.release("unbound")
  } else {
    let why = if place.removed {
      "the station was removed from its workspace"
    } else {
      "the station is in no workspace"
    }
    hub.hold("unbound")
    hub.suspend_all()
    ignore((world.ask)("agents.along", "left"))
    ignore((world.ask)("agents.jobsStopAll", Json::string(why)))
  }
}

///|
/// `start`: taken up once the process before is gone; then the door opens (`url`, the world's), and what was cut off
/// resumes.
pub async fn AgentsSide::start(self : AgentsSide, place : Place) -> Unit {
  let hub = self.hub
  let world = hub.world
  if !self.in_workspace {
    hub.hold("unbound")
  }
  hub.take_up()
  let url = js_string((world.ask)("agents.openDoor", Json::null()))
  hub.tools_at(url)
  self.taken = true
  // (what was cut off found while turns are still held, as `follow` does: agents.ts `start`)
  if self.in_workspace {
    ignore((world.ask)("agents.along", "taken"))
    hub.recover()
  }
  hub.release("starting")
  if self.in_workspace {
    ignore((world.ask)("agents.jobsRelaunch", Json::null()))
  } else if place.removed {
    ignore((world.ask)("agents.jobsStopAll", "the station was removed from its workspace"))
  }
  if place.rig_due.length() > 0 {
    self.follow(place)
  }
}

///|
/// What another station's request of this one's chats is answered by (agents.ts `local`), by its call_name: one of the
/// parts', or a message (`fromPeer`).
pub fn peer_route(call_name : String) -> String {
  match call_name {
    "session.read" => "read"
    "session.file" => "file"
    "session.put" => "put"
    "session.create" | "session.create.preset" | "session.create.speed" | "session.create.preset.speed" | "session.create.preset.tui" => "create"
    "session.archive" => "archive"
    "session.configure" => "configure"
    "session.list" => "list"
    "session.notice" => "notice"
    _ => "message"
  }
}

///|
/// agents.ts `agentName`: how an agent is named among a screen's people (`agent: <its chat's title>`).
pub fn agent_name(title : String?, session : String) -> String {
  "agent: \{title.unwrap_or(session)}"
}
