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
  /// Its home relays as it has them now (endpoint.ts `relayStatus`: each `url`, `connected`, `access`, `conflict`).
  relay_status : () -> Json
  /// Whether it is reached through a relay now, end to end (endpoint.ts `probeRelay`): `{"ok": true}`, or `{"ok":
  /// false, "stage": "probe_offline" | "endpoint_failed"}`. None: it has no probe.
  probe_relay : (async (String) -> Json)?
}

///|
/// A relay's ping (`<relay>/ping`): whether it answered ok, within 10 s.
pub(all) struct Pinger {
  ping : async (String) -> Bool
  /// Measured again on the connection made (none: not measured): the ms there and back.
  pinged : ((String, Int64) -> Unit)?
}

///|
/// The watch of the endpoint itself on the relays' check (relays.ts `PROBE`, which says why and how): probed end to
/// end through a relay that answers, told unhealthy after `failures_to_recover` probes in a row found it at fault, never
/// in the first `startup_grace_ms`, again only after a cooldown that doubles to `cooldown_max_ms`; not probed while a
/// relay connection was taken within `recent_reach_ms`.
pub(all) struct ProbeParams {
  startup_grace_ms : Int64
  every_healthy : Int
  failures_to_recover : Int
  cooldown_ms : Int64
  cooldown_max_ms : Int64
  recent_reach_ms : Int64
}

///|
pub let probe_params : ProbeParams = {
  startup_grace_ms: 120_000L,
  every_healthy: 4,
  failures_to_recover: 3,
  cooldown_ms: 600_000L,
  cooldown_max_ms: 3_600_000L,
  recent_reach_ms: 60_000L,
}

///|
/// The longest a probe is waited for (the shell's own takes some 25 s at most): a deadline.
let probe_deadline_ms : Int = 60_000

///|
/// The watch's state between checks (relays.ts `keepRelays`' own).
priv struct ProbeWatch {
  params : ProbeParams
  started_at : Int64
  mut failures : Int
  /// The relays that failed a probe since the last one that reached it, bare.
  streak_failed : Array[String]
  mut healthy_ticks : Int
  mut unsupported : Bool
  mut last_recover_at : Int64?
  mut cooldown : Int64
  /// When the endpoint last took a connection through a relay (relays.ts `lastRelayReachAt`).
  last_relay_reach : () -> Int64?
  /// Where the last recovery and its cooldown are kept across processes (relays.ts `RecoverStore`; None: none kept).
  save_recover : async ((Int64, Int64)?) -> Unit
}

///|
/// Once the cooldown is over, back to its first, and nothing kept.
async fn ProbeWatch::cooled_down(self : ProbeWatch, now : Int64) -> Unit {
  match self.last_recover_at {
    Some(at) if now - at >= self.cooldown => {
      self.cooldown = self.params.cooldown_ms
      self.last_recover_at = None
      (self.save_recover)(None) catch {
        _ => ()
      }
    }
    _ => ()
  }
}

///|
/// The most relays one check probes through (relays.ts `MAX_PROBES_PER_TICK`, `PROBE` says why).
let max_probes_per_tick : Int = 4

///|
/// What one probe through a relay found (relays.ts `ProbeOutcome`): no probe at all, the endpoint reached, the relay out
/// of this machine's reach, or the endpoint not reached (its stage, or the error, as said).
priv enum ProbeOutcome {
  Unsupported(String)
  Reached
  Offline
  Failed(String)
}

///|
async fn probe_once(probe : async (String) -> Json, relay : String) -> ProbeOutcome {
  let probed = try {
    Ok(@effect.timeout(probe_deadline_ms, async fn() { probe(relay) })) // timer: a deadline on the probe
  } catch {
    e => Err(error_words(e))
  }
  match probed {
    Ok(Some({ "ok": True, .. })) => Reached
    Ok(Some({ "stage": String("probe_offline"), .. })) => Offline
    Ok(Some({ "stage": String(stage), .. })) => Failed("stage=\{stage}")
    Ok(Some(_)) => Failed("stage=unknown")
    Ok(None) => Failed("error=no answer in \{probe_deadline_ms} ms")
    Err(words) if words.contains("no operation") ||
      words.contains("not a function") => Unsupported(words)
    Err(words) => Failed("error=\{words}")
  }
}

///|
/// One check's turn of the watch (relays.ts `probeTick`): `up` whether a relay answered its ping, `reachable` the first
/// that did, `rest` the relays after it (not asked this check), `ping_once` one ping of one of them.
async fn ProbeWatch::tick(
  self : ProbeWatch,
  endpoint : RelayEndpoint,
  up : Bool,
  reachable : String?,
  rest : Array[String],
  ping_once : async (String) -> Bool,
  on_unhealthy : () -> Unit,
  say : (String, String) -> Unit,
) -> Unit {
  guard endpoint.probe_relay is Some(probe) && !self.unsupported else { return }
  // (none of the relays answers: this machine's network or the relays', not the endpoint's)
  if !up {
    self.failures = 0
    self.streak_failed.clear()
    return
  }
  guard reachable is Some(first) else { return }
  // (a connection taken through a relay lately: reached end to end, relays.ts `PROBE`)
  let now = @effect.now()
  match (self.last_relay_reach)() {
    Some(reached) if now >= reached && now - reached < self.params.recent_reach_ms => {
      if self.failures > 0 || self.streak_failed.length() > 0 {
        say("INFO", "the endpoint took an incoming relay connection after earlier probe failures; not the endpoint's: failures=\{self.failures} failedBefore=\{self.streak_failed.join(",")} reachedMsAgo=\{now - reached}")
        self.failures = 0
        self.streak_failed.clear()
      }
      self.cooled_down(now)
      self.healthy_ticks = 0
      return
    }
    _ => ()
  }
  let status = match (endpoint.relay_status)() {
    Array(rs) => rs
    _ => []
  }
  let suspect = (status.length() > 0 &&
    status.iter().all(s => !(s is { "connected": True, .. }))) ||
    status.iter().any(s => s is { "conflict": True, .. }) ||
    self.failures > 0
  if !suspect {
    self.healthy_ticks += 1
    if self.healthy_ticks < self.params.every_healthy {
      return
    }
  }
  self.healthy_ticks = 0
  let connected : Array[String] = []
  for s in status {
    if s is { "connected": True, "url": String(u), .. } {
      connected.push(bare(u))
    }
  }
  // (relays.ts `probeTick`: on and not failed since, then not failed since, then those that have)
  let pool : Array[String] = []
  for u in [first, ..rest] {
    if !pool.iter().any(p => bare(p) == bare(u)) {
      pool.push(u)
    }
  }
  let rank = fn(u : String) -> Int {
    if self.streak_failed.contains(bare(u)) {
      2
    } else if connected.contains(bare(u)) {
      0
    } else {
      1
    }
  }
  let candidates : Array[String] = []
  for r in 0..<3 {
    for u in pool {
      if rank(u) == r {
        candidates.push(u)
      }
    }
  }
  let failed_relays : Array[String] = []
  let offline_relays : Array[String] = []
  let mut first_detail = ""
  let mut probed = 0
  let mut cand_idx = 0
  let mut exhausted = false
  while probed < max_probes_per_tick {
    // The next candidate that answers its ping (`first` answered this check's).
    let mut next : String? = None
    while next is None && cand_idx < candidates.length() {
      let c = candidates[cand_idx]
      cand_idx += 1
      if bare(c) == bare(first) || ping_once(c) {
        next = Some(c)
      }
    }
    let relay = match next {
      Some(r) => r
      None => {
        exhausted = true
        break
      }
    }
    let res = probe_once(probe, relay)
    probed += 1
    match res {
      Unsupported(words) => {
        // (a front or an addon from before: never restarted for having no probe)
        self.failures = 0
        self.streak_failed.clear()
        self.unsupported = true
        say("INFO", "the endpoint cannot be probed through a relay; not probed again: relay=\{relay} error=\{words}")
        return
      }
      Reached => {
        if failed_relays.length() > 0 {
          say("INFO", "the endpoint was not reached through one relay, but answered through another; not the endpoint's: relay=\{failed_relays[0]} okRelay=\{relay} \{first_detail}")
        } else if self.streak_failed.length() > 0 {
          say("INFO", "the endpoint answered through another relay after earlier failures; not the endpoint's: okRelay=\{relay} failedBefore=\{self.streak_failed.join(",")}")
        }
        self.failures = 0
        self.streak_failed.clear()
        self.cooled_down(@effect.now())
        return
      }
      Offline => offline_relays.push(relay)
      Failed(detail) => {
        if failed_relays.length() == 0 {
          first_detail = detail
        }
        failed_relays.push(relay)
        if !self.streak_failed.contains(bare(relay)) {
          self.streak_failed.push(bare(relay))
        }
        // (three relays found it out of reach: the endpoint's; two may be one region's, relays.ts `PROBE`)
        if failed_relays.length() >= 3 {
          break
        }
      }
    }
  }
  if failed_relays.length() < 3 &&
    candidates[cand_idx:].iter().all(c => self.streak_failed.contains(bare(c))) {
    exhausted = true
  }
  if failed_relays.length() == 0 {
    let relays = if offline_relays.length() > 1 {
      " relays=\{offline_relays.join(",")}"
    } else {
      ""
    }
    let relay = if offline_relays.length() > 0 { offline_relays[0] } else { first }
    say("INFO", "a probe through a relay that answers did not get on it; the network's, not the endpoint's: relay=\{relay}\{relays}")
    return
  }
  if failed_relays.length() == 1 && !exhausted {
    say("INFO", "a probe failed through one relay while other relays could not be reached; not counting it against the endpoint: relay=\{failed_relays[0]} offline=\{offline_relays.join(",")} \{first_detail}")
    return
  }
  let also = if failed_relays.length() > 1 {
    " also=\{failed_relays[1:].to_owned().join(",")}"
  } else {
    ""
  }
  self.failures += 1
  say("WARN", "the endpoint was not reached through a relay that answers: relay=\{failed_relays[0]}\{also} \{first_detail} failures=\{self.failures}")
  let now = @effect.now()
  if self.failures < self.params.failures_to_recover ||
    now - self.started_at < self.params.startup_grace_ms {
    return
  }
  match self.last_recover_at {
    Some(at) if now - at < self.cooldown => return
    Some(_) => {
      let doubled = self.cooldown * 2L
      self.cooldown = if doubled > self.params.cooldown_max_ms {
        self.params.cooldown_max_ms
      } else {
        doubled
      }
    }
    None => self.cooldown = self.params.cooldown_ms
  }
  self.last_recover_at = Some(now)
  // (kept before the front restarts: the next process keeps the cooldown)
  (self.save_recover)(Some((now, self.cooldown))) catch {
    _ => ()
  }
  say("ERROR", "the endpoint failed its end-to-end probes through a relay that answers; recovering it: relay=\{failed_relays[0]}\{also} failures=\{self.failures} cooldownMs=\{self.cooldown}")
  self.failures = 0
  self.streak_failed.clear()
  on_unhealthy()
}

///|
/// Asking our relays whether they answer is asking an outside system: the one timer here.
pub let relay_check_ms : Int = 30_000

///|
/// How often `keep_relays` concurrently re-ranks all relays by measured RTT to pick the nearest live one.
pub let relay_rank_ms : Int64 = 600_000L

///|
/// Timeout for each relay in the concurrent ranking pass (falls back to sequential 2-try check if all miss).
let relay_rank_timeout_ms : Int = 5_000

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
/// (still.fail's where not said). `log` hears what it would say. `on_unhealthy`: the endpoint probed on each check
/// (`ProbeParams`, `params` a test's), and this told once it is found at fault; `say` hears what the watch would say,
/// with its level (`INFO`, `WARN`, `ERROR`; none: `log`). `last_relay_reach`: when the endpoint last took a connection
/// through a relay (`@effect.now()`'s time); `load_recover` and `save_recover`: where the last recovery and its cooldown
/// (`(at, cooldown)`) are kept across processes.
pub async fn keep_relays(
  endpoint : RelayEndpoint,
  ways : Ways,
  pinger : Pinger,
  bound? : Array[String],
  log? : (String) -> Unit = _ => (),
  on_unhealthy? : () -> Unit,
  params? : ProbeParams = probe_params,
  say? : (String, String) -> Unit,
  last_relay_reach? : () -> Int64? = () => None,
  load_recover? : async () -> (Int64, Int64)?,
  save_recover? : async ((Int64, Int64)?) -> Unit,
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
  let started_at = @effect.now()
  let watch : ProbeWatch = {
    params,
    started_at,
    failures: 0,
    streak_failed: [],
    healthy_ticks: 0,
    unsupported: false,
    last_recover_at: None,
    cooldown: params.cooldown_ms,
    last_relay_reach,
    save_recover: match save_recover {
      Some(f) => f
      None => async fn(_ : (Int64, Int64)?) {  }
    },
  }
  // (a recovery's cooldown from the process before: one found absurd or long over is not kept)
  match load_recover {
    Some(load) =>
      match (load() catch { _ => None }) {
        Some((at, cooldown)) if at <= started_at + 60_000L &&
          started_at - at <= params.cooldown_max_ms * 2L => {
          watch.last_recover_at = Some(at)
          watch.cooldown = if cooldown < params.cooldown_ms {
            params.cooldown_ms
          } else if cooldown > params.cooldown_max_ms {
            params.cooldown_max_ms
          } else {
            cooldown
          }
          log("the relays' probe cooldown kept from the process before: lastRecoverAt=\{at} cooldownMs=\{watch.cooldown}")
        }
        _ => ()
      }
    None => ()
  }
  let mut preferred : (String, Int64)? = None
  let mut ranked : Array[String] = []
  let mut ranked_ours : Array[String] = []
  let check = async fn() {
    let list = ours
    let mut up = false
    let mut reachable : String? = None
    let mut rest : Array[String] = []
    let use_rank = pinger.pinged is Some(_) && list.length() > 1
    if !use_rank {
      preferred = None
      ranked = []
      ranked_ours = []
    }
    match pinger.pinged {
      Some(told) if use_rank => {
        let now = @effect.now()
        let need_rank = match preferred {
          None => true
          Some((pref, at)) =>
            !among(list, pref) ||
            now - at >= relay_rank_ms ||
            list.iter().any(u => !among(ranked_ours, u))
        }
        if need_rank {
          let tasks : Array[async () -> (String, Int64, Int)?] = []
          for idx, relay in list {
            tasks.push(async fn() {
              let measured = try {
                @effect.timeout(relay_rank_timeout_ms, async fn() { // timer: a deadline on the concurrent relay rank ping
                  let ok1 = (pinger.ping)(bare(relay)) catch { _ => false }
                  if !ok1 {
                    return None
                  }
                  let start = @effect.now()
                  let ok2 = (pinger.ping)(bare(relay)) catch { _ => false }
                  if !ok2 {
                    return None
                  }
                  Some((relay, @effect.now() - start, idx))
                })
              } catch {
                _ => None
              }
              match measured {
                Some(Some(res)) => Some(res)
                _ => None
              }
            })
          }
          let results = @effect.all(tasks)
          let ok_sorted : Array[(String, Int64, Int)] = []
          for r in results {
            if r is Some(item) {
              ok_sorted.push(item)
            }
          }
          ok_sorted.sort_by(fn(a, b) {
            let cmp = a.1.compare(b.1)
            if cmp != 0 {
              cmp
            } else {
              a.2.compare(b.2)
            }
          })
          if ok_sorted.length() > 0 {
            let (fastest, fastest_ms, _) = ok_sorted[0]
            let next_ranked : Array[String] = []
            for item in ok_sorted {
              next_ranked.push(item.0)
            }
            for idx, relay in list {
              if !ok_sorted.iter().any(x => x.2 == idx) {
                next_ranked.push(relay)
              }
            }
            up = true
            reachable = Some(fastest)
            preferred = Some((fastest, now))
            ranked = next_ranked
            ranked_ours = list.copy()
            rest = ranked[1:].to_owned()
            told(bare(fastest), fastest_ms)
          } else {
            preferred = None
            ranked = []
            ranked_ours = []
          }
        }
      }
      _ => ()
    }
    if !up {
      let order = match (use_rank, preferred) {
        (true, Some((pref, _))) => {
          let out : Array[String] = []
          let push_unique = fn(u : String) {
            if !among(out, u) {
              out.push(u)
            }
          }
          for u in list {
            if same_url(u) == same_url(pref) {
              push_unique(u)
            }
          }
          for u in ranked {
            if among(list, u) {
              push_unique(u)
            }
          }
          for u in list {
            push_unique(u)
          }
          out
        }
        _ =>
          match (endpoint.home)() {
            None => list
            Some(h) =>
              [
                ..list.filter(u => bare(u) == bare(h)),
                ..list.filter(u => bare(u) != bare(h)),
              ]
          }
      }
      // Two tries each: one lost request is not the relay down.
      for i, relay in order {
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
          reachable = Some(relay)
          // (the relays after it, not asked this check: probed through where it fails, relays.ts `PROBE`)
          rest = order[i + 1:].to_owned()
          break
        }
      }
      if use_rank {
        match preferred {
          Some((pref, _)) => {
            let still_pref = match reachable {
              Some(r) => up && bare(r) == bare(pref)
              None => false
            }
            if !still_pref {
              preferred = None
            }
          }
          None => ()
        }
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
    match on_unhealthy {
      Some(told) =>
        watch.tick(
          endpoint,
          up,
          reachable,
          rest,
          async fn(u) { (pinger.ping)(bare(u)) catch { _ => false } },
          told,
          match say {
            Some(f) => f
            None => (_, words) => log(words)
          },
        )
      None => ()
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
