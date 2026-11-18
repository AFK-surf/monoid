// P5-1's machine and its event streams (services.ts AdminHost and Events; api/host.ts, api/events.ts): the machine as
// GET /host, the events' `host` samples and other stations are told of it (its CPUs noted every 15 s for their recent
// average, its memory and OS read by the platform's commands, its disk the data directory's, its GPUs Apple's and
// NVIDIA's), and the event streams (`GET /events`): the store's changes pushed as they happen, what was told taken up
// from the process before (`run/events.json`) and handed to the next as this one stops.

///|
/// What a command printed, None where it failed or took longer than `ms`.
async fn run_said(host : @host.Host, program : String, args : Array[String], ms : Int) -> String? {
  let proc = spawn(host, program, args, stdout=Piped) catch { _ => return None }
  let got = @effect.timeout(ms, async fn() { proc.finished() })
  match got {
    Some((Some(0), _, out, _)) => Some(@utf8.decode_lossy(out).trim().to_owned())
    Some(_) => None
    None => {
      ignore(kill(proc.pid, "SIGKILL"))
      None
    }
  }
}

///|
fn jv(j : Json) -> @jsjson.JValue {
  @mesh_runtime.jvalue(j)
}

///|
fn of_jv(v : @jsjson.JValue) -> Json {
  @mesh_runtime.json_of(v)
}

///|
priv struct AdminHostLive {
  host : @events.Host
  /// The GPUs said last, and when (jobs/gpu.ts keeps NVIDIA's ten seconds).
  mut gpus : (Int64, Json)?
}

///|
/// The CPUs' ticks as the machine says them now: all of them, and those not idle.
fn cpu_ticks() -> @events.Ticks? {
  match machine() {
    { "cpus": Array(cpus), .. } if cpus.length() > 0 => {
      let mut busy = 0.0
      let mut total = 0.0
      for c in cpus {
        match c {
          { "times": Object(t), .. } =>
            for k, v in t {
              if v is Number(n, ..) {
                total += n
                if k != "idle" {
                  busy += n
                }
              }
            }
          _ => ()
        }
      }
      Some({ busy, total })
    }
    _ => None
  }
}

///|
/// A file read to its end, as fs.readFile reads it, by the shell's `fs.read`: Linux's /proc files say no size, so
/// what reads by the size it is told (drive's `read_all`) reads none of them.
async fn read_pseudo(host : @host.Host, path : String) -> String? {
  match (try { Ok(host.shell("fs.read", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok((String(s), _)) => Some(s)
    _ => None
  }
}

///|
/// platform's `host.sample`: the memory as the machine counts it, the CPU's model, the uptime, the OS, this process's
/// own memory.
async fn host_sample(host : @host.Host) -> Json {
  let m = machine()
  let num = (k : String) => match m {
    Object(o) =>
      match o.get(k) {
        Some(Number(n, ..)) => n
        _ => 0.0
      }
    _ => 0.0
  }
  let own = if num("footprint") > 0.0 { num("footprint") } else { num("rss") }
  if platform() == "darwin" {
    let total = run_said(host, "/usr/sbin/sysctl", ["-n", "hw.memsize"], 3000)
    let vm = run_said(host, "/usr/bin/vm_stat", [], 3000)
    let swap = run_said(host, "/usr/sbin/sysctl", ["-n", "vm.swapusage"], 3000)
    let model = run_said(host, "/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"], 3000)
    let version = run_said(host, "/usr/bin/sw_vers", ["-productVersion"], 3000)
    // (the system's own commands by their paths: a station's PATH may name none of them)
    let memory = @ops_platform.mac_memory_of(total, vm, () => swap)
    let memory = if memory.total_bytes > 0.0 {
      memory.to_json()
    } else {
      { "totalBytes": Json::number(num("totalmem")), "usedBytes": Json::number(num("totalmem") - num("freemem")), "swapUsedBytes": Json::null() }
    }
    {
      "memory": memory,
      "cpuModel": Json::string(model.unwrap_or("")),
      "uptimeSec": Json::number(num("uptime").round()),
      "osName": Json::string(
        match version {
          Some(v) => "macOS \{v}"
          None => "macOS"
        },
      ),
      "ownRss": Json::number(own),
    }
  } else if is_windows() {
    let total = num("totalmem")
    {
      "memory": { "totalBytes": Json::number(total), "usedBytes": Json::number(total - num("freemem")), "swapUsedBytes": Json::null() },
      "cpuModel": match m {
        { "cpus": Array([{ "model": String(s), .. }, ..]), .. } => Json::string(s)
        _ => Json::string("")
      },
      "uptimeSec": Json::number(num("uptime").round()),
      "osName": Json::string("Windows_NT"),
      "ownRss": Json::number(own),
    }
  } else {
    let (memory, model, uptime) = @ops_platform.linux_sample(
      read_pseudo(host, "/proc/meminfo").unwrap_or(""),
      read_pseudo(host, "/proc/cpuinfo").unwrap_or(""),
      read_pseudo(host, "/proc/uptime").unwrap_or(""),
    )
    let release = run_said(host, "/bin/uname", ["-r"], 3000).unwrap_or("")
    {
      "memory": memory.to_json(),
      "cpuModel": Json::string(model),
      "uptimeSec": Json::number(uptime.round()),
      "osName": Json::string("Linux \{release}"),
      "ownRss": Json::number(own),
    }
  }
}

///|
/// jobs/gpu.ts: Apple Silicon's GPU (ioreg), NVIDIA's (nvidia-smi), each answering within 1.5 s or counting as none.
async fn gpus_now(host : @host.Host) -> Json {
  let out : Array[Json] = []
  if platform() == "darwin" && arch() == "arm64" {
    match run_said(host, "/usr/sbin/ioreg", ["-rc", "AGXAccelerator", "-d1"], 1500) {
      Some(text) => {
        let after = (key : String) => match text.find(key) {
          Some(i) => Some(text[i + key.length():].to_owned())
          None => None
        }
        let name = match after("\"model\" = \"") {
          Some(rest) =>
            match rest.find("\"") {
              Some(j) => Some(rest[:j].to_owned())
              None => None
            }
          None => None
        }
        let digits = (s : String?) => match s {
          Some(rest) => {
            let b = StringBuilder()
            for c in rest.trim_start() {
              if c >= '0' && c <= '9' {
                b.write_char(c)
              } else {
                break
              }
            }
            attempt(() => @string.parse_int(b.to_string())).to_option()
          }
          None => None
        }
        let cores = digits(after("\"gpu-core-count\" = "))
        let busy = match digits(after("\"Device Utilization %\"=")) {
          Some(b) => Some(b)
          None => digits(after("\"Device Utilization %\" = "))
        }
        if name is Some(_) || cores is Some(_) || busy is Some(_) {
          let g : Map[String, Json] = { "name": Json::string(name.unwrap_or("Apple GPU")) }
          match cores {
            Some(c) => g["cores"] = Json::number(c.to_double())
            None => ()
          }
          match busy {
            Some(b) if b <= 100 => g["busy"] = Json::number(b.to_double() / 100.0)
            _ => ()
          }
          out.push(Json::object(g))
        }
      }
      None => ()
    }
  }
  if platform() != "darwin" {
    match run_said(host, "nvidia-smi", ["--query-gpu=name,memory.total,memory.used,utilization.gpu", "--format=csv,noheader,nounits"], 1500) {
      Some(csv) =>
        for line in csv.split("\n") {
          let parts = line.split(",").map(p => p.trim().to_owned()).to_array()
          if parts.length() == 0 || parts[0] == "" {
            continue
          }
          let g : Map[String, Json] = { "name": Json::string(parts[0]) }
          let num = (i : Int) => match parts.get(i) {
            Some(v) => attempt(() => @string.parse_double(v)).to_option()
            None => None
          }
          match num(1) {
            Some(t) => g["memoryTotalBytes"] = Json::number(t * 1048576.0)
            None => ()
          }
          match num(2) {
            Some(u) => g["memoryUsedBytes"] = Json::number(u * 1048576.0)
            None => ()
          }
          match num(3) {
            Some(b) => g["busy"] = Json::number(b.round() / 100.0)
            None => ()
          }
          out.push(Json::object(g))
        }
      None => ()
    }
  }
  Json::array(out)
}

///|
/// services.ts AdminHost: the machine's state (api/host.ts `Host`), its CPUs followed while the station runs; the bus's
/// `host_sample` from now on.
fn P51::admin_host_live(self : P51) -> AdminHostLive {
  let host = self.host
  let fork_after = (ms : Double, f : () -> Unit) => {
    let fiber = host.rt.fork(name="host after", async fn() {
      @effect.sleep(ms.to_int())
      f()
    })
    () => fiber.interrupt()
  }
  let live : Ref[AdminHostLive?] = Ref(None)
  let deps : @events.HostDeps = {
    test_host: () => env_get("STILLFAIL_TEST_HOST") == Some("1"),
    now: () => wall_ms().to_double(),
    after: fork_after,
    cpu_ticks: k => k(cpu_ticks()),
    sample: k => ignore(host.rt.fork(name="host sample", async fn() { k(jv(host_sample(host))) })),
    statfs: (p, k) => match disk_of(p) {
      // (statfs's fields: blocks of one byte each, as the disk's sizes say them)
      Some((free, total)) => k(Some(jv({ "blocks": Json::number(total), "bavail": Json::number(free), "bsize": Json::number(1.0) })))
      None => k(None)
    },
    hostname: () => hostname(),
    parallelism: () => match machine() {
      { "cpus": Array(c), .. } => c.length()
      _ => 1
    },
    loadavg: () => match machine() {
      { "loadavg": Array(l), .. } => l.map(x => match x { Number(n, ..) => n; _ => 0.0 })
      _ => [0.0, 0.0, 0.0]
    },
    arch: if arch() == "x86_64" { "x64" } else { arch() },
    os: () => platform(),
    gpus_read: k => ignore(
      host.rt.fork(name="gpus", async fn() {
        let g = gpus_now(host)
        match live.val {
          Some(l) => l.gpus = Some((@host.now(), g))
          None => ()
        }
        k(Some(jv(g)))
      }),
    ),
    gpus_cached: Some(() => match live.val {
      Some({ gpus: Some((_, g)), .. }) => Some(jv(g))
      _ => None
    }),
  }
  let h = @events.Host::new(deps, self.bus.data)
  let l : AdminHostLive = { host: h, gpus: None }
  live.val = Some(l)
  // timer: a sample of this machine (its CPUs every 15 s: api/host.ts CPU_EVERY_MS)
  let stop = h.follow((ms, f) => {
    let fiber = host.rt.fork(name="cpu follow", async fn() {
      while true {
        @effect.sleep(ms.to_int())
        f()
      }
    })
    () => fiber.interrupt()
  })
  self.stops.push(stop)
  self.bus.host_sample.val = async fn() { l.sample() }
  l
}

///|
async fn AdminHostLive::sample(self : AdminHostLive) -> Json {
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  self.host.sample(v => ignore(d.succeed(of_jv(v))))
  d.wait()
}

///|
async fn AdminHostLive::recent_busy(self : AdminHostLive) -> Json {
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  self.host.recent_busy(v => ignore(d.succeed(of_jv(v))))
  d.wait()
}

// ── the event streams ──

///|
priv struct EventsLive {
  events : @events.Events
  /// The streams open, by id, each what it tells next (None: it ended).
  streams : Map[Int, (@effect.Queue[String?], @events.Stream)]
  mut next_stream : Int
}

///|
/// What a thread's change says of its entries as the pages show them (views.ts `entryViews`): each as written, its
/// author's name the credential's where it is a person's, an agent's runtime and model its session's.
fn P51::entry_views(self : P51, entries : Array[@jsjson.JValue]) -> Array[@jsjson.JValue] {
  let names = match self.readers {
    Some(r) => r.names
    None => {}
  }
  entries.map(e => {
    let j = of_jv(e)
    guard j is Object(m) else { return e }
    let v = m.copy()
    let kind = match v.get("authorKind") {
      Some(String(k)) => k
      _ => ""
    }
    let author = match v.get("author") {
      Some(String(a)) => a
      _ => ""
    }
    if v.get("authorName") is None {
      match kind {
        "person" | "human" =>
          match names.get(author) {
            Some(n) => v["authorName"] = Json::string(n)
            None => ()
          }
        "agent" =>
          match (try { Ok(self.bus.store.get_session(author)) } catch { e => Err(e) }) {
            Ok(Object(s)) => {
              match s.get("runtime") {
                Some(r) => v["authorRuntime"] = r
                None => ()
              }
              match s.get("model") {
                Some(String(_) as md) => v["authorModel"] = md
                _ => ()
              }
              match s.get("title") {
                Some(String(t)) if t != "" => v["authorName"] = Json::string(t)
                _ => ()
              }
            }
            _ => ()
          }
        _ => ()
      }
    }
    match (v.get("card"), v.get("options")) {
      (None, Some(o)) => v["card"] = { "type": "options", "options": o }
      _ => ()
    }
    jv(Json::object(v))
  })
}

///|
/// What a store's session, thread and job are of, as the events and the admin API look at what a viewer sees.
fn P51::seen_store(self : P51) -> @events.SeenStore {
  let store = self.bus.store
  let db = self.bus.db
  {
    session_ws: key => match (try { Ok(store.session_ws(key)) } catch { e => Err(e) }) {
      Ok(Null) | Err(_) => None
      Ok(ws) => Some(jv(ws))
    },
    thread_sessions: thread => match (try { Ok(db.all("SELECT session FROM thread_sessions WHERE thread = ? ORDER BY joined_at, rowid", [Json::number(thread)])) } catch { e => Err(e) }) {
      Ok(rows) => rows.filter_map(r => match r.get("session") { Some(String(s)) => Some(s); _ => None })
      Err(_) => []
    },
    job_session: id => match (try { Ok(store.get_job(Json::string(id))) } catch { e => Err(e) }) {
      Ok({ "sessionKey": String(s), .. }) => Some(s)
      _ => None
    },
    session_there: key => match (try { Ok(store.get_session(key)) } catch { e => Err(e) }) {
      Ok(Null) | Err(_) => false
      Ok(_) => true
    },
    thread_there: thread => match (try { Ok(db.all("SELECT id FROM threads WHERE id = ?", [Json::number(thread)])) } catch { e => Err(e) }) {
      Ok(rows) => rows.length() > 0
      Err(_) => false
    },
    handed_to: key => match (try { Ok(store.handed_to(key)) } catch { e => Err(e) }) {
      Ok(Null) | Err(_) => None
      Ok(h) => Some(jv(h))
    },
  }
}

///|
/// services.ts Events: the event streams, made on the store's changes, the readers, the machine's samples, what of a
/// job's log is read, what a viewer sees; taken up from the process before (`run/events.json`, events.ts
/// `eventsHandoverFile`: the same file whichever program wrote it) once it is gone,
/// handed over as this one stops; the bus's `events_tell` and `overview_changed` from now on.
fn P51::events_live(self : P51) -> EventsLive {
  let bus = self.bus
  let host = self.host
  let readers = self.readers.unwrap()
  let admin_host = self.admin_host.unwrap()
  let handover_file = path([bus.data, "run", "events.json"])
  let fork_after = (ms : Double, f : () -> Unit) => {
    let fiber = host.rt.fork(name="events after", async fn() {
      @effect.sleep(ms.to_int())
      f()
    })
    () => fiber.interrupt()
  }
  let seen = self.seen_store()
  let deps : @events.Deps = {
    read: (op, args, k) => ignore(
      host.rt.fork(name="events read", async fn() {
        match (try { Ok(readers.read_bytes(op, of_jv(args), "zh")) } catch { e => Err(e) }) {
          Ok(b) => k(Ok(@utf8.decode_lossy(b)))
          Err(e) => k(Err("\{e}"))
        }
      }),
    ),
    said: (_thread, entries, _lang) => Ok(self.entry_views(entries)),
    host: k => admin_host.host.sample(v => k(Some(v))),
    job_log: id => match (try { Ok(bus.store.get_job(Json::string(id))) } catch { e => Err(e) }) {
      Ok({ "log": String(l), .. }) => Some(l)
      _ => None
    },
    log_now: (id, lines, k) => ignore(
      host.rt.fork(name="events log", async fn() {
        match (try { Ok(readers.read("jobLog", { "id": Json::string(id), "lines": Json::string(lines.to_string()) }, "zh")) } catch { e => Err(e) }) {
          Ok({ "text": text, .. } as r) =>
            k(Some(jv({ "text": text, "outputAt": match r { Object(m) => m.get("outputAt").unwrap_or(Json::null()); _ => Json::null() } })))
          _ => k(None)
        }
      }),
    ),
    live: None,
    held: None,
    held_now: None,
    session_exists: key => match (try { Ok(bus.store.get_session(key)) } catch { e => Err(e) }) {
      Ok(Null) | Err(_) => false
      Ok(_) => true
    },
    live_seen: Some((viewer, key) => @events.session_seen(seen, viewer, key)),
    overview: None,
    process_state: None,
    followed: None,
    seen: Some((viewer, of) => @events.seen_of(seen, viewer, of)),
    login_screen: None,
    in_vault: None,
    now: () => wall_ms().to_double(),
    after: fork_after,
    every: (ms, f) => {
      let fiber = host.rt.fork(name="events every", async fn() {
        while true {
          @effect.sleep(ms.to_int()) // timer: what the events' own clock asks (a heartbeat of a stream, a debounce)
          f()
        }
      })
      () => fiber.interrupt()
    },
    immediate: f => ignore(host.rt.fork(name="events now", async fn() { f() })),
    // (fs.watch of a file, as a job's log is followed: the shell keeps no watch, so its size and time are looked at
    // every EVENTS_WATCH_MS while it is followed; none where it is not there yet)
    watch: (file, changed) => {
      guard attempt(() => @drive.stat(file)) is Ok(first) else { return None }
      let going = Ref(true)
      ignore(
        host.rt.fork(name="a file followed", async fn() {
          let mut before = "\{first.size}:\{first.mtime_ms}"
          while going.val && !bus.stopped.is_done() {
            @effect.sleep(events_watch_ms) // timer: an outside system that offers no push (a file another process writes)
            match attempt(() => @drive.stat(file)) {
              Ok(st) => {
                let now = "\{st.size}:\{st.mtime_ms}"
                if now != before {
                  before = now
                  changed()
                }
              }
              Err(_) => going.val = false
            }
          }
        }),
      )
      Some(() => going.val = false)
    },
    warn: (m, fields) => p51_log("WARN", "events", m, fields=of_jv(fields)),
  }
  let run = @drive.hex(@drive.random_bytes(4))
  let events = @events.Events::new(deps, run, taking=true)
  let e : EventsLive = { events, streams: {}, next_stream: 0 }
  live_events.val = Some(events)
  // The overview as the agents' side and the parts make it (`agents.overview`), for the streams that follow it.
  events.follow(overview=(viewer, lang, k) => ignore(
    host.rt.fork(name="events overview", async fn() {
      match (try { Ok(self.overview(of_jv(viewer.raw), lang)) } catch { e => Err(e) }) {
        Ok(v) => k(Ok(jv(v)))
        Err(err) => k(Err("\{err}"))
      }
    }),
  ))
  // The store's changes, told.
  self.stops.push(bus.store.subscribe(change => events.store_changed(jv(change))))
  self.stops.push(bus.subscribe_store(change => events.store_changed(jv(change))))
  bus.events_tell.val = (event, data, key, to) => events.tell(event, jv(data), key, jv(to))
  bus.overview_changed.val = () => events.overview_changed()
  // What the process before told, taken up once it is gone.
  self.fork("events take up", async fn() {
    (bus.previous_gone)()
    // events.ts `takeUp`: there but not read (not ENOENT) is `unread`; either way what is there is removed, and the
    // one before's pid (run/hub.json's) is what it must have been written by.
    let text = read_text(handover_file)
    let unread = text is None &&
      (try { Some(@drive.stat(handover_file)) } catch { _ => None }) is Some(_)
    if text is Some(_) || unread {
      @drive.rm_force(handover_file)
    }
    match bus.previous_pid {
      Some(pid) => events.take_up(text, unread~, from=pid)
      None => events.take_up(text, unread~)
    }
  })
  // Handed over as the station stops: what the next process takes up. A read under way is waited for first (the
  // events' `idle_waiters`), so the process waits for it before it ends (`live_p5_1_handed`).
  let handed_now : @effect.Deferred[Unit] = @effect.Deferred::new()
  p51_events_handed.val = Some(handed_now)
  self.stops.push(() => {
    events.hand_over(@drive.pid(), handed => {
      match handed {
        Written(t) => write_whole(handover_file, t)
        Removed => @drive.rm_force(handover_file)
        Nothing => ()
      }
      // (the streams ended once what was handed over is written: a stream that ended before would be no listener)
      for _, s in e.streams {
        ignore(s.0.try_offer(None))
      }
      ignore(handed_now.succeed(()))
    })
  })
  e
}

///|
/// Whether this process's events were handed over as it stopped (None where it serves none).
let p51_events_handed : Ref[@effect.Deferred[Unit]?] = Ref(None)

///|
/// Waits, as the process ends, for its events to be handed over: a read under way when it stopped ends first.
pub async fn live_p5_1_handed() -> Unit {
  guard p51_events_handed.val is Some(d) else { return }
  ignore(@effect.timeout(5_000, async fn() { d.wait() })) // timer: a deadline to the process's end
}

///|
/// `GET /events` (api/events.ts `open`): a stream for `viewer`, as its query asks; what it tells taken a piece at a time
/// (`next`), None once it ends.
async fn EventsLive::open(
  self : EventsLive,
  viewer : Json,
  lang : String,
  asked : @events.Asked,
) -> (Array[(String, String)], Int) {
  let d : @effect.Deferred[Result[@events.Answer, String]] = @effect.Deferred::new()
  self.events.open(@events.Viewer::of(jv(viewer)), lang, asked, r => ignore(d.succeed(r)))
  match d.wait() {
    Ok(answer) => {
      self.next_stream += 1
      let id = self.next_stream
      let q : @effect.Queue[String?] = @effect.Queue::unbounded()
      self.streams[id] = (q, answer.stream)
      answer.stream.relay(text => ignore(q.try_offer(Some(text))), () => ignore(q.try_offer(None)))
      (answer.headers, id)
    }
    Err(why) => raise BusError(why)
  }
}

///|
/// A stream's next piece; None once it ended (closed then).
async fn EventsLive::next(self : EventsLive, id : Int) -> String? {
  guard self.streams.get(id) is Some((q, stream)) else { return None }
  match (try { Ok(q.take()) } catch { e => Err(e) }) {
    Ok(Some(t)) => Some(t)
    _ => {
      self.streams.remove(id)
      stream.close()
      None
    }
  }
}

///|
/// A stream's reader went: the stream closed at once.
fn EventsLive::close(self : EventsLive, id : Int) -> Unit {
  match self.streams.get(id) {
    Some((q, stream)) => {
      ignore(q.try_offer(None))
      self.streams.remove(id)
      stream.close()
    }
    None => ()
  }
}

///|
/// The event streams' part, once made: the agents' side gives it the live view (`follow`) and tells it what the
/// sessions at work did (`held_told`).
let live_events : Ref[@events.Events?] = Ref(None)

///|
let events_watch_ms : Int = 250
