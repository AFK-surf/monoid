// The hub as station/test/mb-session-hub.test.ts drives it (harness.mbt's `{"op": "hub"}` lines), on a database of the
// test's and a clock of the test's, what it asks of the world asked of the test:
// - `{"hub": "open", "db", "config", "workspaces", "station", "chats", "states", "now", "links"}`: the hub made over the
//   database (its stores' statements the station's), with its config, the workspaces it is in, its connects' chats as
//   they answer (`{botUserId, workspace, has}` by connect), its actors' process states (`{state, idleSince?}` by key);
// - `{"hub": "set", …}`: any of those changed, as the station's change;
// - `{"hub": "advance", "now"}`: the clock moved, what was due by then run;
// - `{"hub": "call", "fn", "args"}`: one of its methods by the TypeScript's name, answered `{"id", "result"}` or
//   `{"id", "error"}` once done; meanwhile what it tells is said `{"tell", "args"}` and what it asks `{"ask", "what",
//   "args"}`, which the test answers `{"hub": "answer", "ask", "value"}` (or `"error"`).

///|
pub struct HubHarness {
  host : @host.Host
  mut words : Words
  mut hub : Hub?
  mut now : Double
  mut config : Json
  mut workspaces : Array[String]
  mut station : String?
  mut links : Bool
  chats : Map[String, Json]
  states : Map[String, Json]
  asked : Map[Int, @effect.Deferred[Json]]
  mut asks : Int
  mut random : Int
  mut move_on : Bool?
  mut live : LiveShell?
}

///|
pub fn HubHarness::new(host : @host.Host) -> HubHarness {
  {
    host,
    words: Words::new(),
    hub: None,
    now: 0.0,
    config: Json::object({}),
    workspaces: [],
    station: None,
    links: false,
    chats: {},
    states: {},
    asked: {},
    asks: 0,
    random: 0,
    move_on: None,
    live: None,
  }
}

///|
/// The test's random bytes (its `randomBytes` made alike): byte `i` of the `k`th ask.
pub fn test_random_hex(k : Int, n : Int) -> String {
  @codec.hex_encode(Bytes::makei(n, i => ((k * 37 + i * 11 + 5) & 255).to_byte()))
}

///|
fn HubHarness::set(self : HubHarness, line : Json) -> Unit {
  match field(line, "config") {
    Some(c) => self.config = c
    None => ()
  }
  match field(line, "workspaces") {
    Some(Array(w)) => self.workspaces = w.map(js_string)
    _ => ()
  }
  match field(line, "station") {
    Some(String(s)) => self.station = Some(s)
    Some(Null) => self.station = None
    _ => ()
  }
  match field(line, "links") {
    Some(True) => self.links = true
    Some(False) => self.links = false
    _ => ()
  }
  match field(line, "chats") {
    Some(Object(m)) => {
      self.chats.clear()
      for k, v in m {
        if v != Json::null() {
          self.chats[k] = v
        }
      }
    }
    _ => ()
  }
  match field(line, "states") {
    Some(Object(m)) => {
      self.states.clear()
      for k, v in m {
        self.states[k] = v
      }
    }
    _ => ()
  }
  match field(line, "now") {
    Some(Number(n, ..)) => self.now = n
    _ => ()
  }
  match field(line, "moveOn") {
    Some(True) => self.move_on = Some(true)
    Some(False) => self.move_on = Some(false)
    Some(Null) => self.move_on = None
    _ => ()
  }
}

///|
fn HubHarness::world(self : HubHarness) -> World {
  {
    tell: (what, args) => self.host.say(({ "tell": Json::string(what), "args": args } : Json).stringify()),
    ask: async fn(what, args) {
      self.asks += 1
      let n = self.asks
      let d : @effect.Deferred[Json] = @effect.Deferred::new()
      self.asked[n] = d
      self.host.say(({ "ask": num(n.to_double()), "what": Json::string(what), "args": args } : Json).stringify())
      d.wait()
    },
    now: () => self.now,
    config: () => self.config,
    workspaces: () => self.workspaces,
    station: () => self.station,
    link: key => if self.links {
      let ws = match self.hub {
        Some(h) => h.ws_of(Some(key)).unwrap_or("ws")
        None => "ws"
      }
      Some("https://ember.test/o/\{ws}/\{self.station.unwrap_or("st")}/\{replace_all(key, ":", "%3A")}")
    } else {
      None
    },
    chat: connect => self.chats.get(connect),
    process_state: key => match self.states.get(key) {
      Some(s) => str_of(s, "state").unwrap_or("cold")
      None => "cold"
    },
    idle_ms: (key, now) => match self.states.get(key) {
      Some(s) =>
        match num_of(s, "idleSince") {
          Some(since) => Some(now - since)
          None => None
        }
      None => None
    },
    move_on: () => self.move_on,
    random_hex: n => {
      self.random += 1
      test_random_hex(self.random, n)
    },
  }
}

///|
/// A line of the test's: answered at once (Some), or once the call it starts is done (None: said then).
pub fn HubHarness::op(self : HubHarness, line : Json) -> Json? {
  let id = field(line, "id").unwrap_or(Json::null())
  match str_of(line, "hub") {
    Some("open") => {
      self.set(line)
      let path = str_of(line, "db").unwrap_or("")
      let made = try {
        let db = @sql.Db::attach(self.host, path, wait=5000)
        let store = @store_sessions.Store::open(db, () => self.now.to_int64(), num_of(line, "latestNote").unwrap_or(0.0).to_int64())
        let threads = @store_threads.Store::new(db, self.now)
        let hub = Hub::new(self.world(), store, threads, words=self.words)
        self.hub = Some(hub)
        Json::null()
      } catch {
        e => { "error": Json::string(e.to_string()) }
      }
      Some(match made {
        Object(_) => made
        _ => { "result": Json::null() }
      })
    }
    Some("set") => {
      self.set(line)
      Some({ "result": Json::null() })
    }
    Some("advance") => {
      let target = num_of(line, "now").unwrap_or(self.now)
      match self.hub {
        Some(h) =>
          ignore(
            self.host.rt.fork(async fn() {
              // (the clock moved as a test's clock moves: to each timer due on the way, which runs at its time)
              while true {
                let mut next : Double? = None
                for t in h.timers {
                  if t.due <= target && (next is None || t.due < next.unwrap()) {
                    next = Some(t.due)
                  }
                }
                match next {
                  None => break
                  Some(due) => {
                    if due > self.now {
                      self.now = due
                    }
                    h.threads = @store_threads.Store::new(h.store.db, self.now) catch { _ => h.threads }
                    h.settle() catch {
                      _ => ()
                    }
                  }
                }
              }
              self.now = target
              h.threads = @store_threads.Store::new(h.store.db, self.now) catch { _ => h.threads }
              h.settle() catch {
                _ => ()
              }
              h.flush_threads()
              self.host.say(({ "id": id, "result": Json::null() } : Json).stringify())
            }),
          )
        None => self.now = target
      }
      match self.hub {
        Some(_) => None
        None => Some({ "result": Json::null() })
      }
    }
    Some("answer") => {
      let n = num_of(line, "ask").unwrap_or(0.0).to_int()
      match self.asked.get(n) {
        Some(d) => {
          self.asked.remove(n)
          match str_of(line, "error") {
            Some(m) => ignore(d.fail(Refused(m)))
            None => ignore(d.succeed(field(line, "value").unwrap_or(Json::null())))
          }
        }
        None => ()
      }
      None
    }
    Some("call") => {
      guard self.hub is Some(hub) else { return Some({ "error": "no hub open" }) }
      hub.words = self.words
      hub.threads = @store_threads.Store::new(hub.store.db, self.now) catch { _ => hub.threads }
      let name = str_of(line, "fn").unwrap_or("")
      let args = items(field(line, "args"))
      ignore(
        self.host.rt.fork(async fn() {
          let answer : Json = try {
            let r = if name.has_prefix("live.") {
              let live = match self.live {
                Some(l) => l
                None => {
                  let l = LiveShell::new(hub)
                  self.live = Some(l)
                  l
                }
              }
              live_call(live, slice(name, 5), args)
            } else {
              hub_call(hub, name, args)
            }
            // (what it set going with no time to wait runs as the step ends, as a fiber of no sleep does)
            hub.settle()
            hub.flush_threads()
            { "id": id, "result": r }
          } catch {
            e => {
              hub.flush_threads()
              { "id": id, "error": Json::string(error_words(e)) }
            }
          }
          self.host.say(answer.stringify())
        }),
      )
      None
    }
    _ => Some({ "error": "no such hub op" })
  }
}

///|
fn a(args : Array[Json], i : Int) -> Json {
  arg(args, i).unwrap_or(Json::null())
}

///|
/// The usage checker the harness made (one at most).
let checks : Array[UsageCheck] = []

///|
/// The agents' side the harness made (one at most).
let agents_of : Array[AgentsSide] = []

///|
fn opt_arg_str(args : Array[Json], i : Int) -> String? {
  match arg(args, i) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn bool_arg(args : Array[Json], i : Int) -> Bool {
  arg(args, i) is Some(True)
}

///|
fn pairs_json(xs : Array[(String, String)]) -> Json {
  Json::array(xs.map(p => Json::array([Json::string(p.0), Json::string(p.1)])))
}

///|
/// One of the hub's methods, by the TypeScript's name.
pub async fn hub_call(hub : Hub, name : String, x : Array[Json]) -> Json {
  let unit = undefined()
  match name {
    "hold" => {
      hub.hold(a_str(x, 0))
      unit
    }
    "release" => {
      hub.release(a_str(x, 0))
      unit
    }
    "holds" => Json::boolean(hub.holds(a_str(x, 0)))
    "suspendAll" => {
      hub.suspend_all()
      unit
    }
    "quiet" => {
      hub.quiet(a_str(x, 0))
      unit
    }
    "unquiet" => {
      hub.unquiet(a_str(x, 0))
      unit
    }
    "quietIn" => Json::boolean(hub.quiet_in(a_str(x, 0)))
    "ofWorkspace" => Json::boolean(hub.of_workspace(a_str(x, 0), a_str(x, 1)))
    "handedOver" => Json::boolean(hub.handed_over(a_str(x, 0)))
    "holdChat" => {
      hub.hold_chat(a_str(x, 0), a_str(x, 1), notice?=opt_arg_str(x, 2))
      unit
    }
    "releaseChat" => Json::boolean(hub.release_chat(a_str(x, 0)))
    "wakeChat" => {
      hub.wake_chat(a_str(x, 0))
      unit
    }
    "busy" => Json::boolean(hub.busy(a_str(x, 0)))
    "chatHeld" => opt_str(hub.chat_held(a_str(x, 0)))
    "held" => Json::boolean(hub.held(a_str(x, 0)))
    "moveOn" => Json::boolean(hub.move_on())
    "stoppedNotice" => opt_str(hub.stopped_notice(a_str(x, 0)))
    "movedTo" => opt_str(hub.moved_to(a_str(x, 0), a_str(x, 1), a_str(x, 2)))
    "leftWorkspace" => {
      hub.left_workspace(a_str(x, 0))
      unit
    }
    "backIn" => {
      hub.back_in(a_str(x, 0))
      unit
    }
    "running" => int(hub.running())
    "anyRunning" => Json::boolean(hub.any_running())
    "receive" => {
      hub.receive(a_str(x, 0), arg(x, 1).unwrap_or(Json::null()))
      unit
    }
    "accept" => {
      hub.accept(a_str(x, 0), arg(x, 1).unwrap_or(Json::null()))
      unit
    }
    "deliver" => {
      let options = arg(x, 4).unwrap_or(Json::object({}))
      hub.deliver(
        arg(x, 0).unwrap_or(Json::null()),
        arg(x, 1).unwrap_or(Json::null()),
        a_arr(x, 2).map(js_string),
        a_str(x, 3),
        retry_pending=is_true(options, "retryPending"),
        workspace?=match field(options, "workspace") {
          None => None
          Some(Object(m)) if m.get("$undefined") is Some(True) => None
          Some(String(w)) => Some(Some(w))
          Some(_) => Some(None)
        },
      )
      unit
    }
    "deliverLetter" => {
      hub.deliver_letter(arg(x, 0).unwrap_or(Json::null()), arg(x, 1).unwrap_or(Json::null()), a_arr(x, 2).map(js_string))
      unit
    }
    "shared" => {
      hub.shared(arg(x, 0).unwrap_or(Json::null()), arg(x, 1).unwrap_or(Json::null()), a_str(x, 2), a_str(x, 3))
      unit
    }
    "toolsAt" => {
      hub.tools_at(a_str(x, 0))
      unit
    }
    "recover" => {
      hub.recover()
      unit
    }
    "installed" => {
      hub.installed(a_str(x, 0))
      unit
    }
    "idleNow" => {
      hub.idle_now(a_str(x, 0))
      unit
    }
    "evictAllIdle" => int(hub.evict_all_idle())
    "evict" => {
      hub.evict(a_str(x, 0))
      unit
    }
    "changed" => {
      hub.changed(a_str(x, 0), restart=bool_arg(x, 1))
      unit
    }
    "allowanceReset" => {
      hub.allowance_reset(a_str(x, 0))
      unit
    }
    "everyChanged" => {
      hub.every_changed()
      unit
    }
    "runtimeUpdated" => {
      hub.runtime_updated(a_str(x, 0))
      unit
    }
    "profileLoginChanged" => {
      hub.profile_login_changed(a_str(x, 0))
      unit
    }
    "profileGone" => {
      hub.profile_gone(a_str(x, 0))
      unit
    }
    "followAccounts" => {
      let map : Map[String, String] = Map([])
      for e in a_arr(x, 1) {
        match e {
          Array(pair) if pair.length() == 2 => map[js_string(pair[0])] = js_string(pair[1])
          _ => ()
        }
      }
      int(hub.follow_accounts(a_arr(x, 0).map(js_string), map))
    }
    "warm" | "stop" | "cancelRetry" | "retryFailed" | "reassign" | "compact" | "notify" => {
      let r = hub.command(a_str(x, 0), name, x[1:].to_owned())
      if name == "compact" {
        r
      } else {
        unit
      }
    }
    "clear" => hub.command(a_str(x, 0), "clear", [Json::boolean(false), Json::boolean(bool_arg(x, 1))])
    "processState" => Json::string(hub.process_state(a_str(x, 0)))
    "processes" => pairs_json(hub.processes())
    "clientKey" =>
      match hub.client_key(a_str(x, 0)) {
        Some(k) => Json::string(k)
        None => unit
      }
    "clientKeys" => pairs_json(hub.client_keys())
    "noteLength" => {
      hub.note_length(a_str(x, 0), arg(x, 1).unwrap_or(Json::null()))
      unit
    }
    "surface" => Json::string(hub.surface(a_str(x, 0)))
    "wsOf" => opt_str(hub.ws_of(opt_arg_str(x, 0)))
    "profilesIn" => Json::array(hub.profiles_in(opt_arg_str(x, 0)))
    "inWorkspace" => {
      let key = a_str(x, 0)
      Json::boolean(hub.get_session(key) is Some(_) && hub.ws_of(Some(key)) == Some(a_str(x, 1)))
    }
    "modelsFor" => Json::array(hub.models_for(a_str(x, 0)))
    "modelsFirst" => Json::array(hub.models_first(a_str(x, 0), a_str(x, 1)))
    "createSession" => {
      hub.create_session(
        a_str(x, 0),
        hub.connect(a_str(x, 1)),
        a_str(x, 2),
        arg(x, 3),
        opt_arg_str(x, 4),
        opt_arg_str(x, 5),
      )
      unit
    }
    "handOver" => {
      let limit_ms = match arg(x, 0) {
        Some(Number(ms, ..)) => ms
        _ => 30_000.0
      }
      let partial = arg(x, 1) is Some(True)
      hub.hand_over(limit_ms~, partial~)
    }
    "takeUp" => {
      hub.take_up()
      unit
    }
    "endOrphan" => Json::boolean(hub.end_orphan(arg(x, 0).unwrap_or(Json::null()), a_num(x, 1)))
    "adopt" => {
      hub.adopt(arg(x, 0).unwrap_or(Json::null()))
      unit
    }
    "shutdown" => {
      hub.shutdown()
      unit
    }
    "dropActor" => Json::boolean(hub.drop_actor(a_str(x, 0)))
    "fetched" => {
      let (text, attachments) = hub.fetched(a_str(x, 0), a_str(x, 1), a_str(x, 2), a_arr(x, 3))
      { "text": Json::string(text), "attachments": Json::array(attachments) }
    }
    "told" => {
      // other stations' bots, as connects/workspace.ts tells them
      let bots : Set[String] = Set([])
      for b in a_arr(x, 1) {
        bots.add(js_string(b))
      }
      hub.told_bots[a_str(x, 0)] = bots
      unit
    }
    // lifecycle.ts
    "bindSingle" => Json::string(hub.bind_single(a_str(x, 0), opt_arg_str(x, 1), opt_arg_str(x, 2), opt_arg_str(x, 3)))
    "openChat" => hub.open_chat(a_str(x, 0), a_str(x, 1), opt_arg_str(x, 2))
    "addToThread" => {
      hub.add_to_thread(arg(x, 0).unwrap_or(Json::null()), a_str(x, 1))
      unit
    }
    "say" =>
      hub.say(
        arg(x, 0).unwrap_or(Json::null()),
        a_str(x, 1),
        a_str(x, 2),
        attachments=a_arr(x, 3),
        quotes=a_arr(x, 4),
        client?=opt_arg_str(x, 5),
      )
    "newSession" => {
      let (key, thread) = hub.new_session(arg(x, 0).unwrap_or(Json::null()), lang?=opt_arg_str(x, 1))
      [Json::string(key), thread]
    }
    "archive" => {
      hub.archive(a_str(x, 0), bool_arg(x, 1))
      unit
    }
    "archiveBy" => {
      hub.archive_by(a_str(x, 0), bool_arg(x, 1), a_str(x, 2))
      unit
    }
    "archiveChat" => {
      hub.archive_chat(arg(x, 0).unwrap_or(Json::null()), bool_arg(x, 1))
      unit
    }
    "deleteSession" => {
      hub.delete_session(a_str(x, 0))
      unit
    }
    "expireArchived" =>
      match hub.expire_archived(a_num(x, 0)) {
        Some(n) => num(n)
        None => Json::null()
      }
    "relieveArchived" => {
      hub.relieve_archived()
      unit
    }
    "continueMachineSession" => {
      let (key, thread) = hub.continue_machine_session(a(x, 0), a(x, 1), a_str(x, 2), lang?=opt_arg_str(x, 3), ws?=opt_arg_str(x, 4))
      [Json::string(key), thread]
    }
    "agents.start" | "agents.follow" => {
      let p = a(x, 0)
      let place : Place = {
        bound: is_true(p, "bound"),
        joined: items(field(p, "joined")).map(js_string),
        home: str_of(p, "home"),
        first: str_of(p, "first"),
        removed: is_true(p, "removed"),
        rig_due: is_true(p, "rigDue"),
        rig_pending: match field(p, "rigPending") {
          None | Some(Null) => None
          r => r
        },
      }
      let side = match agents_of.get(0) {
        Some(s) => s
        None => {
          let s = AgentsSide::new(hub, place)
          agents_of.push(s)
          s
        }
      }
      if name == "agents.start" {
        side.start(place)
      } else {
        side.follow(place)
      }
      unit
    }
    "autoArchive" => {
      let missing = Unprepared::new()
      let next = hub.auto_archive(a_num(x, 0), look?=arg(x, 1), missing~)
      { "next": match next { Some(n) => num(n); None => Json::null() }, "missing": missing.to_json() }
    }
    "configure" => {
      hub.configure(a_str(x, 0), arg(x, 1).unwrap_or(Json::null()), lang?=opt_arg_str(x, 2))
      unit
    }
    // afresh.ts, read/usage.ts `usageNow`
    "usageNow" => opt_json(hub.usage_now(a_str(x, 0)))
    "threadsToldOf" => strs(hub.threads_told_of(a_str(x, 0)))
    "startsAfresh" => opt_str(hub.starts_afresh(a_str(x, 0), a_str(x, 1), a_str(x, 2), opt_arg_str(x, 3)))
    "toldCleared" => Json::string(hub.told_cleared(a_str(x, 0), read_back=bool_arg(x, 1)))
    "goesAfresh" => Json::boolean(hub.goes_afresh(a_str(x, 0), a_num(x, 1)))
    "toldLongChat" => opt_str(hub.told_long_chat(a_str(x, 0)))
    "toldResumeLost" => Json::string(hub.told_resume_lost(a_str(x, 0)))
    // usage/: the counter, the usage kept, the checker
    "usageStart" => {
      let c = UsageCounter::new(hub)
      hub.counter = Some(c)
      hub.keeps_counted = true
      c.start()
      unit
    }
    "usageSoon" => {
      match hub.counter {
        Some(c) => c.soon(a_str(x, 0))
        None => ()
      }
      unit
    }
    "readingAll" =>
      match hub.counter {
        Some(c) => Json::boolean(c.reading_all())
        None => Json::boolean(true)
      }
    "untilTimer" => {
      // (the test waits for the hub to have set a timer, an event of its own, before it moves the clock on to it)
      if hub.timers.length() == 0 {
        let d : @effect.Deferred[Unit] = @effect.Deferred::new()
        hub.timer_waiters.push(d)
        d.wait()
      }
      unit
    }
    "usageDrain" => {
      let d = UsageDrain::new(hub)
      d.begin()
      unit
    }
    "retireUsage" => {
      hub.retire_usage()
      unit
    }
    "usageCheck" => {
      // (the checker asked in turn, its answers given by the test as `usageCheckHeard`)
      let c = match checks.get(0) {
        Some(c) => c
        None => {
          let c = UsageCheck::new(hub)
          checks.push(c)
          c
        }
      }
      match a_str(x, 0) {
        "remote" => c.ready_remote()
        "chats" => c.ready_chats(a(x, 1))
        "heard" => c.heard(a(x, 1))
        "exited" => c.exited(a_num(x, 1).to_int())
        "trim" => return int(c.trim_idle())
        "close" => c.close()
        other => raise Refused("no check call \{other}")
      }
      unit
    }
    "keepUsage" => {
      hub.keep_usage(a_str(x, 0), quiet=bool_arg(x, 1))
      unit
    }
    "usageStop" => {
      match hub.counter {
        Some(c) => c.stop()
        None => ()
      }
      unit
    }
    "storeCall" =>
      match a_str(x, 0) {
        "startTurn" => {
          hub.store.start_turn(a(x, 1), a(x, 2), a(x, 3))
          unit
        }
        "endTurn" => {
          hub.store.end_turn(a(x, 1), a(x, 2), a(x, 3), a(x, 4), a(x, 5))
          unit
        }
        "usageChanged" => {
          hub.store.usage_changed(a_arr(x, 1), None, bool_arg(x, 3))
          unit
        }
        other => raise Refused("no store call \{other}")
      }
    _ => raise Refused("no hub call \{name}")
  }
}

///|
/// One of the live view's shell's (live.ts `LiveHub`), by the TypeScript's name.
async fn live_call(live : LiveShell, name : String, x : Array[Json]) -> Json {
  let unit = undefined()
  match name {
    "subscribe" =>
      int(
        live.subscribe(
          a_str(x, 0),
          a_num(x, 1),
          match arg(x, 2) {
            Some(Number(n, ..)) => Some(n)
            _ => None
          },
          brief=bool_arg(x, 3),
        ),
      )
    "unsubscribe" => {
      live.unsubscribe(a_str(x, 0), a_num(x, 1).to_int())
      unit
    }
    "forget" => {
      live.forget(a_str(x, 0))
      unit
    }
    "running" => {
      live.running(a_str(x, 0), bool_arg(x, 1))
      unit
    }
    "event" => {
      live.event(a_str(x, 0), a(x, 1))
      unit
    }
    "soon" => {
      live.soon(a_str(x, 0))
      unit
    }
    "moved" => {
      live.moved(a_str(x, 0))
      unit
    }
    "turnEnded" => {
      live.turn_ended(a_str(x, 0))
      unit
    }
    "usageCounted" => {
      live.usage_counted()
      unit
    }
    "held" => strs(live.held_now())
    "nowOf" => live.now_of(a_arr(x, 0).map(js_string))
    "carried" => live.carried()
    "takePlans" => {
      live.take_plans(a(x, 0))
      unit
    }
    "takeTails" => {
      live.take_tails(a(x, 0))
      unit
    }
    "told" => {
      live.told_by_program(a_str(x, 0), a_arr(x, 1))
      unit
    }
    "asked" => live.asked_by_program(a_str(x, 0), a_arr(x, 1))
    _ => raise Refused("no live call \{name}")
  }
}
