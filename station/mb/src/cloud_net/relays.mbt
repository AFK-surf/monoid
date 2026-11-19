// Which relays the station is kept on and dials another through (station/src/mesh/relays.ts): still.fail's (the ones
// browsers reach), each of its workspaces' own after them, but those every workspace of its turns off (`off`: one's
// URL, `ours` for still.fail's); iroh's public relays only while none of ours answers (and never where every workspace
// turned still.fail's off for relays of its own); and per peer, the relays it is not reached through
// (peer_relays.mbt).

///|
/// The relays the station is kept on: each of its workspaces' (`workspace_relays`), the home one's first; still.fail's
/// where it is in none. What its endpoint is bound with.
pub fn wanted_relays(ways : Ways) -> Array[String] {
  let out = []
  for m in (ways.cloud.memberships)() {
    for u in workspace_relays(ways, m.workspace) {
      if !among(out, u) {
        out.push(u)
      }
    }
  }
  if out.length() > 0 {
    out
  } else {
    (ways.cloud.relays)()
  }
}

///|
/// Where another station is dialed: its id, the relays, and those it is not reached through.
pub(all) struct StationAddr {
  id : String
  relays : Array[String]
  disabled_relays : Array[String]
}

///|
pub fn StationAddr::to_json(self : StationAddr) -> Json {
  {
    "id": Json::string(self.id),
    "relays": Json::array(self.relays.map(Json::string)),
    "disabledRelays": Json::array(self.disabled_relays.map(Json::string)),
  }
}

///|
/// The workspaces of this station's that `id` is a station or a rig of.
fn shared_with(cloud : CloudView, id : String) -> Array[String] {
  (cloud.memberships)()
  .filter(m => m.peers.iter().any(p => peer_id(p) == Some(id)) ||
    (cloud.rigs)(m.workspace).contains(id))
  .map(m => m.workspace)
}

///|
/// Where station `id` is dialed: through the relays of the workspace it is asked in, or, where none is said (or it is
/// another workspace's), of every workspace of this station's it is in too; not through those all of them turn off.
/// One of none of them: as this station is kept.
pub fn station_addr(ways : Ways, id : String, workspace? : String) -> StationAddr {
  let cloud = ways.cloud
  let shared = match workspace {
    Some(ws) if (cloud.membership)(ws) is Some(_) => [ws]
    _ => shared_with(cloud, id)
  }
  if shared.length() == 0 {
    return { id, relays: wanted_relays(ways), disabled_relays: [] }
  }
  let relays = []
  for ws in shared {
    for u in workspace_relays(ways, ws) {
      if !among(relays, u) {
        relays.push(u)
      }
    }
  }
  let offs = shared.map(ws => off_relays(ways, ws))
  let disabled_relays = offs[0].filter(u => offs.iter().all(o => among(o, u)) &&
    !among(relays, u))
  { id, relays, disabled_relays }
}

///|
/// Whether every workspace of the station's turned still.fail's relays off for relays of its own: then iroh's public
/// relays are not added while none of those answers.
pub fn ours_off(ways : Ways) -> Bool {
  let ms = (ways.cloud.memberships)()
  ms.length() > 0 &&
  ms
  .iter()
  .all(m => ways.view(m.workspace).off.contains("ours") &&
    off_relays(ways, m.workspace).length() > 0)
}

///|
/// Whether a connection's chosen path goes through one of `relays` now (`via`: its selected path's relay).
pub fn goes_through(via : String?, relays : Array[String]?) -> Bool {
  match (relays, via) {
    (Some(rs), Some(v)) if rs.length() > 0 => among(rs, v)
    _ => false
  }
}

///|
/// The endpoint as the relays' keeping asks it (native.ts `Endpoint`).
pub(all) struct RelayEndpoint {
  insert_relay : async (String) -> Unit
  remove_relay : async (String) -> Unit
  keep : (Array[String]) -> Unit
  /// The relay iroh homes on now.
  home : () -> String?
  public_relays : async (Bool) -> Unit
}

///|
/// A relay's ping (`<relay>/ping`): whether it answered ok, within 10 s.
pub(all) struct Pinger {
  ping : async (String) -> Bool
  /// Measured again on the connection made (none: not measured): the ms there and back.
  pinged : ((String, Int64) -> Unit)?
}

///|
/// Asking our relays whether they answer is asking an outside system: the one timer here.
pub let relay_check_ms : Int = 30_000

///|
fn bare(url : String) -> String {
  strip_slashes(url)
}

///|
fn same_list(a : Array[String], b : Array[String]) -> Bool {
  a.length() == b.length() &&
  a.iter().zip(b.iter()).all(p => same_url(p.0) == same_url(p.1))
}

///|
/// Keeps the endpoint on the relays wanted, for good (until interrupted). `bound`: the relays it was bound with
/// (still.fail's where not said). `log` hears what it would say.
pub async fn keep_relays(
  endpoint : RelayEndpoint,
  ways : Ways,
  pinger : Pinger,
  bound? : Array[String],
  log? : (String) -> Unit = _ => (),
) -> Unit {
  let cloud = ways.cloud
  let mut ours = wanted_relays(ways)
  let was = match bound {
    Some(b) => b
    None => (cloud.relays)()
  }
  for url in ours.filter(u => !among(was, u)) {
    (endpoint.insert_relay)(url) catch {
      e => log("a workspace's relay was not added: relay=\{url} error=\{error_words(e)}")
    }
  }
  for url in was.filter(u => !among(ours, u)) {
    (endpoint.remove_relay)(url) catch {
      e => log("a relay turned off was not removed: relay=\{url} error=\{error_words(e)}")
    }
  }
  (endpoint.keep)(ours)
  // Whether iroh's public relays are on: not known at first (an endpoint kept across a handover may have them on).
  let mut added : Bool? = None
  // One change at a time, as they come.
  let changes : @effect.Queue[Unit] = @effect.Queue::unbounded()
  let stop_ways = ways.listen(_ => ignore(changes.try_offer(())))
  let stop_cloud = (cloud.listen)(() => ignore(changes.try_offer(())))
  defer {
    stop_ways()
    stop_cloud()
  }
  let check = async fn() {
    let mut up = false
    let order = match (endpoint.home)() {
      None => ours
      Some(h) =>
        [
          ..ours.filter(u => bare(u) == bare(h)),
          ..ours.filter(u => bare(u) != bare(h)),
        ]
    }
    // Two tries each: one lost request is not the relay down.
    for relay in order {
      let mut answered = false
      for _ in 0..<2 {
        let ok = (pinger.ping)(bare(relay)) catch { _ => false }
        if ok {
          answered = true
          match pinger.pinged {
            Some(told) => {
              let start = @effect.now()
              let again = (pinger.ping)(bare(relay)) catch { _ => false }
              if again {
                told(bare(relay), @effect.now() - start)
              }
            }
            None => ()
          }
          break
        }
      }
      if answered {
        up = true
        break
      }
    }
    if !up && ours_off(ways) {
      if added != Some(false) {
        log(
          "none of the workspaces' relays answers; iroh's public relays stay off, still.fail's being turned off",
        )
        (endpoint.public_relays)(false)
        added = Some(false)
      }
    } else if !up && added != Some(true) {
      log("none of still.fail's relays answers; adding iroh's public relays until one does")
      (endpoint.public_relays)(true)
      added = Some(true)
    } else if up && added != Some(false) {
      if added == Some(true) {
        log("still.fail's relays answer again; back home to them")
      }
      (endpoint.public_relays)(false)
      added = Some(false)
    }
  }
  @effect.scoped(scope => {
    ignore(
      scope.fork_daemon("relays kept", on_error=e => log("the relays kept are no longer followed: \{error_words(e)}"), async fn() {
        while true {
          changes.take()
          let now = wanted_relays(ways)
          // (none: not in a workspace now; the relays stay as they are)
          if now.length() == 0 || same_list(now, ours) {
            continue
          }
          log("the relays kept changed")
          let before = ours
          ours = now
          try {
            for url in now.filter(u => !among(before, u)) {
              (endpoint.insert_relay)(url)
            }
            for url in before.filter(u => !among(now, u)) {
              (endpoint.remove_relay)(url)
            }
            (endpoint.keep)(now)
          } catch {
            e => log("the relays kept were not changed: \{error_words(e)}")
          }
        }
      }),
    )
    while true {
      check() catch {
        e => log("the relays' check failed: \{error_words(e)}")
      }
      @effect.sleep(relay_check_ms) // timer: a ping that measures the relays, which tell nothing by themselves
    }
  })
}
