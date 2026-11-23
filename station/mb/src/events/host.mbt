// What the machine a station runs on looks like (station/src/api/host.ts, GET /host): kept here, given again within ten
// seconds, the CPU ticks last seen kept across reads, the CPUs' recent average noted every CPU_EVERY_MS; once it has
// read the machine nothing waits on it more than a moment (INFO_WAIT_MS, GPU_SAMPLE_MS). How the machine is read (its
// sample, its ticks, its disk) and the wall's clock are `HostDeps`'.

///|
/// host.ts CPU_EVERY_MS, CPU_SPAN_MS, INFO_WAIT_MS, STALE_MS, GPU_SAMPLE_MS.
pub let cpu_every_ms : Double = 15_000.0

///|
pub let cpu_span_ms : Double = 60_000.0

///|
pub let info_wait_ms : Double = 400.0

///|
pub let stale_ms : Double = 60_000.0

///|
pub let gpu_sample_ms : Double = 400.0

///|
/// CPU time since boot, all CPUs together (platform/cpu-share.ts `Ticks`): busy, total.
pub(all) struct Ticks {
  busy : Double
  total : Double
}

///|
/// cpu-share.ts `cpuShare`: the share between two samples, none until the total moved.
pub fn cpu_share(a : Ticks, b : Ticks) -> Double? {
  if b.total > a.total {
    let d = b.busy - a.busy
    let share = (if d > 0.0 { d } else { 0.0 }) / (b.total - a.total)
    Some(if share < 0.0 { 0.0 } else if share > 1.0 { 1.0 } else { share })
  } else {
    None
  }
}

///|
fn round2(x : Double) -> Double {
  js_round(x * 100.0) / 100.0
}

///|
pub(all) struct HostDeps {
  /// STILLFAIL_TEST_HOST: the isolated recording station's fixed sample.
  test_host : () -> Bool
  /// The wall's clock (ops/fibers.ts `wall`).
  now : () -> Double
  after : (Double, () -> Unit) -> () -> Unit
  /// platform.host.cpuTicks (none: not known), platform.host.sample (`osName`, `cpuModel`, `uptimeSec`, `memory`,
  /// `ownRss`), statfs of a path (`blocks`, `bsize`, `bavail`; none: it failed).
  cpu_ticks : ((Ticks?) -> Unit) -> Unit
  sample : ((J) -> Unit) -> Unit
  statfs : (String, (J?) -> Unit) -> Unit
  hostname : () -> String
  parallelism : () -> Int32
  loadavg : () -> Array[Double]
  arch : String
  /// platform.os ("windows" says no run queue).
  os : () -> String
  /// The GPUs (jobs/gpu.ts): a read (none: it failed), and what they said last (none: nothing yet).
  gpus_read : ((J?) -> Unit) -> Unit
  gpus_cached : (() -> J?)?
  /// Where its traffic was last seen leaving for the internet (api/egress.ts `EgressLook.now`: `{country, colo}`; none:
  /// not known yet, or not looked at).
  egress : () -> J?
}

///|
/// What ticks were last seen, and when.
pub(all) struct Seen {
  at : Double
  ticks : Ticks
}

///|
/// host.ts `hostInfo`: the machine now (`info`), the ticks seen, whether it must look at them again a moment later.
pub fn host_info(
  d : HostDeps,
  data_dir : String,
  last : Seen?,
  done : (J, Seen?, Bool) -> Unit,
) -> Unit {
  if (d.test_host)() {
    return done(
      jo([
        ("hostname", js("test-station")),
        ("os", js("Test OS")),
        ("arch", js("arm64")),
        ("cpus", jn(4)),
        ("cpuModel", js("Test CPU")),
        ("load", jn(0.25)),
        ("loadAvg", ja([jn(1), jn(1), jn(1)])),
        ("cpuBusy", jn(0.25)),
        ("uptimeSec", jn(3600)),
        (
          "memory",
          jo([
            ("totalBytes", jn(8_000_000_000)),
            ("usedBytes", jn(4_000_000_000)),
            ("swapUsedBytes", jn(0)),
          ]),
        ),
        (
          "disk",
          jo([
            ("path", js("/test-station/data")),
            ("totalBytes", jn(100_000_000_000)),
            ("freeBytes", jn(50_000_000_000)),
          ]),
        ),
        ("stationRssBytes", jn(100_000_000)),
        ("checkedAt", jn((d.now)())),
      ]),
      None,
      false,
    )
  }
  let sample : Ref[J?] = { val: None, }
  let space : Ref[J?] = { val: None, }
  let busy : Ref[(J, Seen?, Bool)?] = { val: None, }
  let all = () => {
    guard sample.val is Some(s) &&
      space.val is Some(room) &&
      busy.val is Some((cpu, seen, needs)) else {
      return
    }
    let n = (d.parallelism)()
    let loads = (d.loadavg)()
    let name = (d.hostname)()
    let name = if name.has_suffix(".local") {
      name.view(end_offset=name.length() - 6).to_string()
    } else {
      name
    }
    let info = jopt([
      ("hostname", Some(js(name))),
      ("os", s.get("osName")),
      ("arch", Some(js(d.arch))),
      ("cpus", Some(jn(n.to_double()))),
      ("cpuModel", s.get("cpuModel")),
      (
        "load",
        Some(
          jn(
            round2(
              (if loads.length() > 0 { loads[0] } else { @double.not_a_number }) /
              (if n > 1 { n } else { 1 }).to_double(),
            ),
          ),
        ),
      ),
      (
        "loadAvg",
        Some(
          if (d.os)() == "windows" {
            Null
          } else {
            ja(loads.map(l => jn(round2(l))))
          },
        ),
      ),
      ("cpuBusy", Some(cpu)),
      ("uptimeSec", s.get("uptimeSec")),
      ("memory", s.get("memory")),
      ("disk", Some(room)),
      ("stationRssBytes", s.get("ownRss")),
      ("emberRssBytes", s.get("ownRss")),
      ("checkedAt", Some(jn((d.now)()))),
    ])
    done(info, seen, needs)
  }
  (d.sample)(s => {
    sample.val = Some(s)
    all()
  })
  (d.statfs)(data_dir, st => {
    space.val = Some(
      match st {
        Some(st) => {
          let f = (name : String) => num_prop(st, name).unwrap_or(0.0)
          jo([
            ("path", js(data_dir)),
            ("totalBytes", jn(f("blocks") * f("bsize"))),
            ("freeBytes", jn(f("bavail") * f("bsize"))),
          ])
        }
        None =>
          jo([
            ("path", js(data_dir)),
            ("totalBytes", jn(0)),
            ("freeBytes", jn(0)),
          ])
      },
    )
    all()
  })
  (d.cpu_ticks)(now => {
    busy.val = Some(
      match now {
        None => (Null, last, false)
        Some(now) => {
          let before = match last {
            Some(l) if (d.now)() - l.at < 60_000.0 => Some(l.ticks)
            _ => None
          }
          let share = match before {
            Some(b) => cpu_share(b, now)
            None => None
          }
          (
            match share {
              Some(s) => jn(round2(s))
              None => Null
            },
            Some({ at: (d.now)(), ticks: now, }),
            share is None,
          )
        }
      },
    )
    all()
  })
}

///|
/// host.ts `CpuWindow`: the CPUs' ticks noted for the last CPU_SPAN_MS or so.
pub struct CpuWindow {
  seen : Array[Seen]
}

///|
pub fn CpuWindow::new() -> CpuWindow {
  { seen: [], }
}

///|
pub fn CpuWindow::note(self : CpuWindow, at : Double, ticks : Ticks?) -> Unit {
  guard ticks is Some(ticks) else { return }
  self.seen.push({ at, ticks, })
  while self.seen.length() > 1 && at - self.seen[1].at >= cpu_span_ms {
    let _ = self.seen.remove(0)
  }
}

///|
pub fn CpuWindow::latest(self : CpuWindow) -> Seen? {
  self.seen.last()
}

///|
/// How busy since the oldest ticks noted until `ticks` now, and over how many seconds.
pub fn CpuWindow::busy(self : CpuWindow, at : Double, ticks : Ticks?) -> J {
  let first = self.seen
    .iter()
    .find_first(s => at - s.at <= cpu_span_ms + cpu_every_ms)
  guard ticks is Some(t) && first is Some(f) && at - f.at >= 1000.0 else {
    return Null
  }
  if t.total <= f.ticks.total {
    return Null
  }
  let share = (t.busy - f.ticks.busy) / (t.total - f.ticks.total)
  let share = if share < 0.0 { 0.0 } else if share > 1.0 { 1.0 } else { share }
  jo([
    ("busy", jn(round2(share))),
    ("seconds", jn(js_round((at - f.at) / 1000.0))),
  ])
}

///|
/// host.ts `soon`: `start`'s answer, or `otherwise()` if it has not come within `ms`.
fn soon(
  d : HostDeps,
  ms : Double,
  start : ((J) -> Unit) -> Unit,
  otherwise : () -> J,
  done : (J) -> Unit,
) -> Unit {
  let settled = Ref(false)
  let stop = Ref(None)
  stop.val = Some(
    (d.after)(ms, () => {
      if !settled.val {
        settled.val = true
        done(otherwise())
      }
    }),
  )
  start(v => {
    if !settled.val {
      settled.val = true
      if stop.val is Some(s) {
        s()
      }
      done(v)
    }
  })
}

///|
/// host.ts `Host`.
pub struct Host {
  deps : HostDeps
  data_dir : String
  mut cached : (Double, J)?
  mut seen : Seen?
  mut reading : Array[(J) -> Unit]?
  mut sampling : Array[(J) -> Unit]?
  cpu : CpuWindow
}

///|
pub fn Host::new(deps : HostDeps, data_dir : String) -> Host {
  {
    deps,
    data_dir,
    cached: None,
    seen: None,
    reading: None,
    sampling: None,
    cpu: CpuWindow::new(),
  }
}

///|
/// `follow`: the CPUs' ticks noted now and every CPU_EVERY_MS, until the returned function is called; `every` the
/// clock's.
pub fn Host::follow(
  self : Host,
  every : (Double, () -> Unit) -> () -> Unit,
) -> () -> Unit {
  let stopped = Ref(false)
  let reading = Ref(false)
  let note = () => {
    if reading.val {
      return
    }
    reading.val = true
    (self.deps.cpu_ticks)(ticks => {
      if !stopped.val {
        self.cpu.note((self.deps.now)(), ticks)
      }
      reading.val = false
    })
  }
  note()
  let stop = every(cpu_every_ms, note)
  () => {
    stopped.val = true
    stop()
  }
}

///|
/// `recentBusy`.
pub fn Host::recent_busy(self : Host, done : (J) -> Unit) -> Unit {
  (self.deps.cpu_ticks)(ticks => done(self.cpu.busy((self.deps.now)(), ticks)))
}

///|
/// `sample`: the machine and its GPUs, one at a time however many ask.
pub fn Host::sample(self : Host, done : (J) -> Unit) -> Unit {
  if self.sampling is Some(waiters) {
    waiters.push(done)
    return
  }
  let waiters = [done]
  self.sampling = Some(waiters)
  let info : Ref[J?] = { val: None, }
  let gpus : Ref[J?] = { val: None, }
  let both = () => {
    guard info.val is Some(i) && gpus.val is Some(g) else { return }
    let out = with_prop(i, "gpus", g)
    // (host.ts: where it leaves said as it is now, not kept with the machine's ten-second reading)
    let out = match (self.deps.egress)() {
      Some(e) if !(self.deps.test_host)() => with_prop(out, "egress", e)
      _ => out
    }
    self.sampling = None
    for w in waiters {
      w(out)
    }
  }
  self.info(i => {
    info.val = Some(i)
    both()
  })
  let gpus_done = (g : J) => {
    gpus.val = Some(g)
    both()
  }
  if (self.deps.test_host)() {
    gpus_done(
      ja([jo([("name", js("Test GPU")), ("cores", jn(4)), ("busy", jn(0.25))])]),
    )
  } else {
    soon(
      self.deps,
      gpu_sample_ms,
      k => (self.deps.gpus_read)(g => k(g.unwrap_or(Null))),
      () => {
        match self.deps.gpus_cached {
          Some(c) => c().unwrap_or(Null)
          None => Null
        }
      },
      gpus_done,
    )
  }
}

///|
fn Host::info(self : Host, done : (J) -> Unit) -> Unit {
  let now = (self.deps.now)()
  if self.cached is Some((at, info)) && now - at < 10_000.0 {
    return done(info)
  }
  let stale = match self.cached {
    Some((at, info)) if now - at < stale_ms => Some(info)
    _ => None
  }
  match stale {
    None => self.fresh(done)
    Some(stale) =>
      soon(self.deps, info_wait_ms, k => self.fresh(k), () => stale, done)
  }
}

///|
/// `fresh`: a fresh look at the machine, kept as it comes; one at a time however many ask.
fn Host::fresh(self : Host, done : (J) -> Unit) -> Unit {
  let now = (self.deps.now)()
  let last = match self.seen {
    Some(s) if now - s.at < 60_000.0 => Some(s)
    _ =>
      match self.cpu.latest() {
        Some(l) => Some(l)
        None => self.seen
      }
  }
  if self.reading is Some(waiters) {
    waiters.push(done)
    return
  }
  let waiters = [done]
  self.reading = Some(waiters)
  host_info(self.deps, self.data_dir, last, (info, seen, needs) => {
    let finish = (info : J, seen : Seen?) => {
      self.seen = seen
      self.cached = Some((num_prop(info, "checkedAt").unwrap_or(0.0), info))
      self.reading = None
      for w in waiters {
        w(info)
      }
    }
    match (needs, seen) {
      (true, Some(first)) => {
        let start = (self.deps.now)()
        let info = Ref(info)
        fn look() {
          (self.deps.cpu_ticks)(ticks => {
            match ticks {
              None => {
                info.val = with_prop(
                  info.val,
                  "checkedAt",
                  jn((self.deps.now)()),
                )
                finish(info.val, last)
              }
              Some(t) =>
                match cpu_share(first.ticks, t) {
                  Some(share) => {
                    info.val = with_prop(info.val, "cpuBusy", jn(round2(share)))
                    let seen = Some({ at: (self.deps.now)(), ticks: t, })
                    info.val = with_prop(
                      info.val,
                      "checkedAt",
                      jn((self.deps.now)()),
                    )
                    finish(info.val, seen)
                  }
                  None =>
                    if (self.deps.now)() - start >= 2_000.0 {
                      info.val = with_prop(
                        info.val,
                        "checkedAt",
                        jn((self.deps.now)()),
                      )
                      finish(info.val, last)
                    } else {
                      let _ = (self.deps.after)(100.0, look)
                    }
                }
            }
          })
        }

        let _ = (self.deps.after)(500.0, look)
      }
      _ => finish(info, seen)
    }
  })
}

// ── where its traffic leaves (api/egress.ts) ──

///|
/// egress.ts TRACE_URL, EVERY_MS, WAIT_MS: Cloudflare's trace, looked at again every 30 minutes, given 10 s.
pub let egress_trace_url : String = "https://www.cloudflare.com/cdn-cgi/trace"

///|
pub let egress_every_ms : Int = 30 * 60_000

///|
pub let egress_wait_ms : Int = 10_000

///|
/// egress.ts `egressOf`: what a trace's answer says of where it came from, `{country, colo}` (its country two letters,
/// `XX` and `T1` (Tor) not one; the data centre three letters, else null); none where it says no country.
pub fn egress_of(trace : String) -> J? {
  let field = (name : String) => {
    let prefix = name + "="
    for line in trace.split("\n") {
      if line.has_prefix(prefix) {
        return line[prefix.length():].trim().to_owned().to_upper()
      }
    }
    ""
  }
  let letters = (s : String, n : Int) => s.length() == n &&
    s.iter().all(c => c >= 'A' && c <= 'Z')
  let country = field("loc")
  if !letters(country, 2) || country == "XX" || country == "T1" {
    return None
  }
  let colo = field("colo")
  Some(jo([("country", js(country)), ("colo", if letters(colo, 3) { js(colo) } else { Null })]))
}
