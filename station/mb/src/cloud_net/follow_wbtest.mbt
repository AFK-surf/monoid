// Fake clock and follow_ways/follow_marks test harness for sync_wbtest.mbt and transport_wbtest.mbt.

///|
fn opt_json(s : String?) -> Json {
  match s {
    Some(t) => Json::string(t)
    None => Json::null()
  }
}

///|
fn rec_json(r : WaysRecord?) -> Json {
  match r {
    Some(r) => r.to_json()
    None => Json::null()
  }
}

///|
fn num(j : Json?) -> Int64 {
  safe_int(j).unwrap_or(0L)
}

///|
/// A case's cloud: its cloud.json (`state`), its roster current or not.
fn case_cloud(c : Json) -> StateCloud {
  let s = StateCloud::new(field(c, "state"))
  match field(c, "peersCurrent") {
    Some(False) => s.peers_current = false
    Some(True) => s.peers_current = true
    _ => ()
  }
  s
}

///|
///|
fn marks_of_json(marks : StationMarks) -> Json {
  let per : Map[String, Json] = Map([])
  for m in (marks.cloud.memberships)() {
    per[m.workspace] = {
      "stations": Json::array(marks.stations_of(m.workspace).map(Json::string)),
      "of": marks_json(marks.of(m.workspace)),
    }
  }
  Json::object(per)
}

/// A case's clock and timers: what is due fires in the order it was set, `advance` moving the clock.
priv struct FakeTime {
  mut now : Int64
  mut seq : Int
  waits : Array[(Int64, Int, () -> Unit)]
}

///|
fn FakeTime::new() -> FakeTime {
  { now: 0L, seq: 0, waits: [] }
}

///|
fn FakeTime::after(self : FakeTime) -> After {
  {
    after: (ms, f) => {
      self.seq += 1
      let id = self.seq
      self.waits.push((self.now + ms.to_int64(), id, f))
      fn() {
        match self.waits.search_by(w => w.1 == id) {
          Some(i) => ignore(self.waits.remove(i))
          None => ()
        }
      }
    },
  }
}

///|
/// The clock moved on to `to`, each wait due fired at its own time, in order.
fn FakeTime::advance(self : FakeTime, to : Int64) -> Unit {
  while true {
    let mut best = -1
    for i, w in self.waits {
      if w.0 <= to &&
        (best < 0 ||
        w.0 < self.waits[best].0 ||
        (w.0 == self.waits[best].0 && w.1 < self.waits[best].1)) {
        best = i
      }
    }
    if best < 0 {
      break
    }
    let w = self.waits.remove(best)
    if w.0 > self.now {
      self.now = w.0
    }
    (w.2)()
  }
  if to > self.now {
    self.now = to
  }
}

///|
/// answers as one from before (`before`); changes made at their times. Every call, its answer and what each came to.
fn follow_case(c : Json) -> Json {
  let time = FakeTime::new()
  let timers = time.after()
  let kind = text_of(field(c, "follow")).unwrap_or("ways")
  let cloud = case_cloud(c)
  let (store, _) = Kept::memory(text?=text_of(field(c, "kept")))
  let ways = Ways::new(cloud.view(), store, () => time.now)
  let marks = StationMarks::new(cloud.view(), Kept::memory(text?=text_of(field(c, "kept"))).0, () => time.now)
  // The peers: each a cloud of its own (its id its station) and its store.
  let peer_ways : Map[String, Ways] = Map([])
  let peer_marks : Map[String, StationMarks] = Map([])
  let peer_cfg : Map[String, Json] = Map([])
  match field(c, "peers") {
    Some(Object(ps)) =>
      for id, cfg in ps {
        let pc = StateCloud::new(field(cfg, "state"))
        peer_ways[id] = Ways::new(pc.view(), Kept::memory(text?=text_of(field(cfg, "kept"))).0, () => time.now)
        peer_marks[id] = StationMarks::new(pc.view(), Kept::memory(text?=text_of(field(cfg, "kept"))).0, () => time.now)
        peer_cfg[id] = cfg
      }
    _ => ()
  }
  let trace : Array[Json] = []
  let call = {
    call: (peer : String, ws : String?, request : Json, done : (Result[Json, String]) -> Unit) => {
      let cfg = peer_cfg.get(peer).unwrap_or(Json::null())
      let at = time.now
      trace.push({
        "t": int_json(at),
        "peer": Json::string(peer),
        "ws": opt_json(ws),
        "request": request,
      })
      let delay = num(field(cfg, "delay")).to_int()
      ignore(
        (timers.after)(delay, fn() {
          let down = array_of(field(cfg, "down"))
            .unwrap_or([])
            .iter()
            .any(span => {
              let s = array_of(Some(span)).unwrap_or([])
              s.length() == 2 && num(Some(s[0])) <= at && at < num(Some(s[1]))
            })
          let answer = if field(cfg, "before") is Some(True) {
            Err("unknown method")
          } else if down {
            Err("the peer is offline")
          } else {
            let asked_in = match ws {
              Some(w) => w
              None => text_of(field(cfg, "home")).unwrap_or("")
            }
            try {
              Ok(
                if kind == "ways" {
                  answer_ways(peer_ways[peer], request, asked_in)
                } else {
                  answer_marks(peer_marks[peer], request, asked_in)
                },
              )
            } catch {
              e => Err(error_words(e))
            }
          }
          trace.push({
            "t": int_json(time.now),
            "peer": Json::string(peer),
            "answer": match answer {
              Ok(a) => a
              Err(e) => { "error": Json::string(e) }
            },
          })
          done(answer)
        }),
      )
    },
  }
  let stop = if kind == "ways" {
    follow_ways(ways, call, timers)
  } else {
    follow_marks(marks, call, timers)
  }
  for ev in array_of(field(c, "events")).unwrap_or([]) {
    time.advance(num(field(ev, "at")))
    let ws = text_of(field(ev, "ws")).unwrap_or("")
    match text_of(field(ev, "do")).unwrap_or("") {
      "add" =>
        ignore(
          (try Some(add_relay(ways, ws, text_of(field(ev, "url")).unwrap_or(""), None)) catch {
            _ => None
          }),
        )
      "mark" =>
        ignore(
          (try Some(marks.change(name=field(ev, "name"), ("", "", ""))) catch {
            _ => None
          }),
        )
      "roster" => {
        match field(ev, "state") {
          Some(Object(m)) => {
            cloud.state.unwrap().clear()
            for k, v in m {
              cloud.state.unwrap()[k] = v
            }
          }
          _ => ()
        }
        match field(ev, "peersCurrent") {
          Some(True) => cloud.peers_current = true
          Some(False) => cloud.peers_current = false
          _ => ()
        }
        cloud.tell()
      }
      "stop" => stop()
      _ => ()
    }
  }
  time.advance(num(field(c, "until")))
  stop()
  let peers_now : Map[String, Json] = Map([])
  for id, w in peer_ways {
    peers_now[id] = if kind == "ways" {
      let per : Map[String, Json] = Map([])
      for m in (w.cloud.memberships)() {
        per[m.workspace] = rec_json(w.record(m.workspace))
      }
      Json::object(per)
    } else {
      marks_of_json(peer_marks[id])
    }
  }
  let mine = if kind == "ways" {
    let per : Map[String, Json] = Map([])
    for m in (ways.cloud.memberships)() {
      per[m.workspace] = rec_json(ways.record(m.workspace))
    }
    Json::object(per)
  } else {
    marks_of_json(marks)
  }
  {
    "trace": Json::array(trace),
    "mine": mine,
    "peers": Json::object(peers_now),
    "waiting": Json::number(time.waits.length().to_double()),
  }
}

///|
/// A case of the plane's frames: each applied in turn at its `now` (s), what the state came to after it, what was sent
