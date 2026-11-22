// Pure MoonBit state machine for `bar_switch` timing across non-Android hosts (iOS, macOS, Windows, Web):
// tracks a bottom-bar place switch (or account page open) from `placed` through first frame `built` and each
// newly subscribed topic's first decoded value, emitting JSON matching Android's `BarTiming.java` schema.
// Only place names, topic names, durations and byte counts: no user text or session identifiers.

///|
/// A switch is reported once its page is built and every tracked topic has arrived, or at latest this long after.
let bar_switch_longest_ms : Double = 3000.0

///|
/// Topics subscribed within this window after `built` are still attributed to the switch (matches BarTiming.java).
let bar_switch_follow_ms : Double = 500.0

///|
priv struct BarTopic {
  name : String
  at : Double
  mut arrived : Double
  mut bytes : Int
  mut parts : String
  mut failed : Bool
}

///|
priv struct BarSwitch {
  from : String?
  to : String
  first : Bool
  away_ms : Double?
  placed_at : Double
  mut built_at : Double
  topics : Map[Int, BarTopic]
  topic_order : Array[Int]
}

///|
struct BarSwitchTracker {
  seen : Map[String, Bool]
  left : Map[String, Double]
  mut current : BarSwitch?
}

///|
fn BarSwitchTracker::new() -> BarSwitchTracker {
  { seen: Map([]), left: Map([]), current: None }
}

///|
fn BarSwitchTracker::has_pending(self : BarSwitchTracker) -> Bool {
  self.current is Some(_)
}

///|
fn bar_round2(ms : Double) -> Double {
  (ms * 100.0).round() / 100.0
}

///|
fn BarSwitchTracker::finish(self : BarSwitchTracker, cut : Bool) -> String? {
  guard self.current is Some(s) else { return None }
  self.current = None
  let obj : Map[String, Json] = Map([])
  obj["from"] = match s.from {
    Some(f) => Json::string(f)
    None => Json::null()
  }
  obj["to"] = Json::string(s.to)
  obj["first"] = Json::boolean(s.first)
  match s.away_ms {
    Some(away) => obj["away_ms"] = Json::number(away.floor())
    None => ()
  }
  obj["composed_ms"] = if s.built_at >= 0.0 {
    Json::number(bar_round2(s.built_at - s.placed_at))
  } else {
    Json::null()
  }
  obj["cut"] = Json::boolean(cut || s.built_at < 0.0)
  obj["topics_count"] = Json::number(s.topic_order.length().to_double())
  let topics : Array[Json] = []
  for id in s.topic_order {
    match s.topics.get(id) {
      Some(t) => {
        let j : Map[String, Json] = Map([])
        j["topic"] = Json::string(t.name)
        j["core_ms"] = if t.arrived >= 0.0 {
          Json::number(bar_round2(t.arrived - t.at))
        } else {
          Json::null()
        }
        j["tap_shown_ms"] = if t.arrived >= 0.0 {
          Json::number(bar_round2(t.arrived - s.placed_at))
        } else {
          Json::null()
        }
        if t.bytes >= 0 {
          j["bytes"] = Json::number(t.bytes.to_double())
        }
        if t.parts != "" {
          let parsed : Json? = Some(@json.parse(t.parts)) catch { _ => None }
          match parsed {
            Some(p) => j["parts"] = p
            None => ()
          }
        }
        if t.failed {
          j["failed"] = Json::boolean(true)
        }
        topics.push(Json::object(j))
      }
      None => ()
    }
  }
  obj["topics"] = Json::array(topics)
  Some(Json::object(obj).stringify())
}

///|
fn BarSwitchTracker::settle(self : BarSwitchTracker) -> String? {
  guard self.current is Some(s) else { return None }
  if s.built_at < 0.0 {
    return None
  }
  for id in s.topic_order {
    match s.topics.get(id) {
      Some(t) if t.arrived < 0.0 => return None
      _ => ()
    }
  }
  self.finish(false)
}

///|
/// A place's page put on the stack in place of `from`'s ("" none) at `now` (monotonic ms).
/// If a previous switch is still in flight, returns its JSON with `cut: true`.
fn BarSwitchTracker::placed(
  self : BarSwitchTracker,
  from : String,
  to : String,
  now : Double,
) -> String? {
  let prev = self.finish(true)
  let was = if from == "" { None } else { Some(from) }
  match was {
    Some(w) => {
      self.left[w] = now
      self.seen[w] = true
    }
    None => ()
  }
  let first = !self.seen.contains(to)
  self.seen[to] = true
  let away_ms = match self.left.get(to) {
    Some(since) => Some(if now >= since { now - since } else { 0.0 })
    None => None
  }
  self.current = Some({
    from: was,
    to,
    first,
    away_ms,
    placed_at: now,
    built_at: -1.0,
    topics: Map([]),
    topic_order: [],
  })
  prev
}

///|
/// The first frame build containing `place` completed at `now` (monotonic ms).
/// Returns the switch JSON if no tracked topics are still pending.
fn BarSwitchTracker::built(
  self : BarSwitchTracker,
  place : String,
  now : Double,
) -> String? {
  guard self.current is Some(s) else { return None }
  if s.to != place || s.built_at >= 0.0 {
    return None
  }
  s.built_at = now
  self.settle()
}

///|
/// A topic subscribed anew (`id`, `topic`) at `now` (monotonic ms); returns whether it is tracked by the active switch.
fn BarSwitchTracker::followed(
  self : BarSwitchTracker,
  id : Int,
  topic : String,
  now : Double,
) -> Bool {
  guard self.current is Some(s) else { return false }
  if s.built_at >= 0.0 && now - s.built_at > bar_switch_follow_ms {
    return false
  }
  if s.topics.contains(id) {
    return false
  }
  s.topics[id] = {
    name: topic,
    at: now,
    arrived: -1.0,
    bytes: -1,
    parts: "",
    failed: false,
  }
  s.topic_order.push(id)
  true
}

///|
/// First message decoded for subscription `id` at `now` (monotonic ms): `bytes` (-1 on failure) and optional `parts` JSON.
/// Returns the switch JSON once `built` has completed and all tracked topics have arrived.
fn BarSwitchTracker::decoded(
  self : BarSwitchTracker,
  id : Int,
  bytes : Int,
  parts : String,
  now : Double,
) -> String? {
  guard self.current is Some(s) else { return None }
  guard s.topics.get(id) is Some(t) else { return None }
  if t.arrived >= 0.0 {
    return None
  }
  t.arrived = now
  t.bytes = bytes
  t.parts = parts
  t.failed = bytes < 0
  self.settle()
}

///|
/// Timeout fallback: emits the active switch with `cut: true` once `bar_switch_longest_ms` (3000 ms) have elapsed.
fn BarSwitchTracker::tick(self : BarSwitchTracker, now : Double) -> String? {
  guard self.current is Some(s) else { return None }
  if now - s.placed_at >= bar_switch_longest_ms {
    self.finish(true)
  } else {
    None
  }
}
