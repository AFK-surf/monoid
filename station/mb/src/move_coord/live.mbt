// Migrations as a part of the station (station/src/move/live.ts; move/AGENTS.md): what the composition root makes of
// the station's services for them. What is the station's own to say (its roster as the control plane lists it, a
// station by its id or name, the jobs up as the moves see them, the owners of the vault grants a page of chats holds)
// and the one timer the part keeps: a burst of changes told once in 500 ms (`move` on the event stream).

///|
/// How long a burst of changes is gathered before it is told (a debounce: each file's progress).
pub let told_changed_ms : Int = 500

///|
/// The roster of a workspace as the control plane lists it (its membership's `peers`; None: not current, or none).
pub fn roster_of(membership : J?, peers_current : Bool) -> Array[RosterEntry]? {
  match membership {
    None | Some(Null) => return None
    _ => ()
  }
  if !peers_current {
    return None
  }
  let out = []
  for p in arr(get(membership, "peers")).unwrap_or([]) {
    match text(get(Some(p), "id")) {
      Some(id) =>
        out.push({
          id,
          name: text(get(Some(p), "name")).unwrap_or(""),
          tasks: text(get(Some(p), "mode")) == Some("tasks"),
        })
      None => ()
    }
  }
  Some(out)
}

///|
/// A station of a roster by what a person gives (its id, its name in any case, or its id's start of 8 or more): its
/// id, and whether it only runs tasks (by the roster, or as a rig of the workspace: `rig_of`).
pub fn station_of(
  roster : Array[RosterEntry]?,
  v : String,
  rig_of : (String) -> Bool,
) -> (String, Bool)? {
  let r = roster.unwrap_or([])
  let lower = v.to_lower()
  match r.search_by(x => x.id == v || x.name.to_lower() == lower || (v.length() >= 8 && x.id.has_prefix(v))) {
    Some(i) => Some((r[i].id, r[i].tasks || rig_of(r[i].id)))
    None => None
  }
}

///|
/// The jobs up as the moves see them (live.ts `jobs.up`): the store's rows (`id`, `sessionKey`, `name`, `command`,
/// `cwd`, `port`, `watch`), none of a remote task's, of a workspace's chats where it is asked so.
pub async fn jobs_up_as_moves(
  rows : Array[J],
  keys : Array[String]?,
  ws : String?,
  of_workspace : async (String, String) -> Bool,
) -> Array[J] {
  let out = []
  for j in rows {
    let session = text(get(Some(j), "sessionKey")).unwrap_or("")
    if session.has_prefix("remote:") {
      continue
    }
    match (keys, ws) {
      (None, Some(w)) => if !of_workspace(session, w) { continue }
      _ => ()
    }
    let pairs = [
      ("id", get(Some(j), "id").unwrap_or(Null)),
      ("session", js(session)),
      ("name", get(Some(j), "name").unwrap_or(Null)),
      ("command", get(Some(j), "command").unwrap_or(Null)),
    ]
    for k in ["cwd", "port", "watch"] {
      match get(Some(j), k) {
        Some(v) => pairs.push((k, v))
        None => ()
      }
    }
    out.push(jo(pairs))
  }
  out
}

///|
/// Each session's owners, of the vault grants it holds (live.ts `grantOwners`: the rows `{session, body}`, in order).
pub fn grant_owners_of(rows : Array[J]) -> Map[String, Array[String]] {
  let out : Map[String, Array[String]] = {}
  for r in rows {
    let session = text(get(Some(r), "session")).unwrap_or("")
    let body = text(get(Some(r), "body")).unwrap_or("")
    let o = match (try Ok(parse(body)) catch { e => Err(e) }) {
      Ok(b) => text(get(get(Some(b), "request"), "owner"))
      Err(_) => None
    }
    match o {
      Some(owner) => {
        let list = out.get(session).unwrap_or([])
        if !list.contains(owner) {
          list.push(owner)
        }
        out[session] = list
      }
      None => ()
    }
  }
  out
}

///|
/// A burst of changes told once (live.ts `changed`): the first arms the timer, the rest wait for it.
pub struct Changed {
  priv clock : Clock
  priv tell : () -> Unit
  priv mut telling : (() -> Unit)?
}

///|
pub fn Changed::new(clock : Clock, tell : () -> Unit) -> Changed {
  { clock, tell, telling: None }
}

///|
pub fn Changed::changed(self : Changed) -> Unit {
  if self.telling is Some(_) {
    return
  }
  // timer: a debounce of a burst (each file's progress)
  self.telling = Some(
    (self.clock.after)(told_changed_ms, () => {
      self.telling = None
      (self.tell)()
    }),
  )
}
