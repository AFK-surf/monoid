// station/src/resources/: what of this machine still.fail uses (module.ts's readings of `ps` and `nettop`, the
// programs' and the front's memory; watch.ts's looks, each process put to whose it is and what it used since the last;
// linux.ts's readings of /proc).

///|
/// module.ts `APP_IDS`: each product's desktop app's bundle ids begin so.
let app_ids : Array[String] = [stillfail_product.reverse + ".desktop", monoid_product.reverse + ".desktop"]

///|
/// module.ts `appBundles`: whether a command runs from a bundle of the desktop app's, each bundle's Info.plist read once
/// (`read`, its text, None where it does not read); one not read yet is none until it is.
pub struct AppBundles {
  known : Map[String, Bool]
}

///|
pub fn AppBundles::new() -> AppBundles {
  { known: Map([]) }
}

///|
/// The bundle a command is in, where it is in one.
pub fn bundle_of(command : String) -> String? {
  let at = index_of(command, ".app/Contents/")
  if at < 0 {
    None
  } else {
    Some(sub(command, 0, at + 4))
  }
}

///|
/// Asked of `command`: what is known now; a bundle not known yet is read (`read`) for the next ask.
pub fn AppBundles::is_app(self : AppBundles, command : String, read : (String) -> String?) -> Bool {
  guard bundle_of(command) is Some(bundle) else { return false }
  match self.known.get(bundle) {
    Some(known) => known
    None => {
      self.known[bundle] = false
      match read(bundle + "/Contents/Info.plist") {
        Some(plist) => self.known[bundle] = app_ids.iter().any(id => has(plist, id))
        None => ()
      }
      false
    }
  }
}

///|
/// module.ts `parseArgs`: `ps -o pid=,args=`'s lines, each pid's command line.
pub fn parse_args(text : String) -> Array[(Double, String)] {
  let out : Array[(Double, String)] = []
  for line in split_on(text, "\n") {
    let i = spaces_from(line, 0)
    let e = digits_from(line, i)
    if e == i || e >= line.length() || !js_space(cu(line, e)) {
      continue
    }
    let rest = sub(line, e + 1, line.length())
    if any_unit(rest, c => c == 13 || c == 0x2028 || c == 0x2029) {
      continue
    }
    let pid = js_number(sub(line, i, e))
    match out.search_by(p => p.0 == pid) {
      Some(k) => out[k] = (pid, rest)
      None => out.push((pid, rest))
    }
  }
  out
}

///|
/// module.ts `parseNettop`: each process's bytes in and out so far (`name.pid,in,out,`).
pub fn parse_nettop(text : String) -> Array[(Double, Double, Double)] {
  let out : Array[(Double, Double, Double)] = []
  for line in split_on(text, "\n") {
    // `/\.(\d+),(\d+),(\d+),?$/`: three runs of digits at the end, the first after a dot.
    let mut e = line.length()
    if ends(line, ",") {
      e -= 1
    }
    let take = (end : Int) => {
      let mut k = end
      while k > 0 && is_digit(cu(line, k - 1)) {
        k -= 1
      }
      k
    }
    let c = take(e)
    if c == e || c == 0 || cu(line, c - 1) != 44 {
      continue
    }
    let b = take(c - 1)
    if b == c - 1 || b == 0 || cu(line, b - 1) != 44 {
      continue
    }
    let a = take(b - 1)
    if a == b - 1 || a == 0 || cu(line, a - 1) != 46 {
      continue
    }
    let pid = js_number(sub(line, a, b - 1))
    let v = (pid, js_number(sub(line, b, c - 1)), js_number(sub(line, c, e)))
    match out.search_by(p => p.0 == pid) {
      Some(k) => out[k] = v
      None => out.push(v)
    }
  }
  out
}

///|
fn children_of(table : Array[ProcessInfo]) -> Map[Double, Array[Double]] {
  let m : Map[Double, Array[Double]] = Map([])
  for p in table {
    if p.pid != p.ppid {
      match m.get(p.ppid) {
        Some(a) => a.push(p.pid)
        None => m[p.ppid] = [p.pid]
      }
    }
  }
  m
}

///|
fn by_pid(table : Array[ProcessInfo]) -> Map[Double, ProcessInfo] {
  let m : Map[Double, ProcessInfo] = Map([])
  for p in table {
    m[p.pid] = p
  }
  m
}

///|
/// module.ts `programsIn`: the resident bytes of the programs `pids` and all under them.
pub fn programs_in(table : Array[ProcessInfo]?, pids : Array[Double]) -> (Double, Int) {
  guard table is Some(t) else { return (0.0, pids.length()) }
  let byp = by_pid(t)
  let children = children_of(t)
  let seen : Array[Double] = []
  let mut bytes = 0.0
  let queue = pids.copy()
  while queue.length() > 0 {
    let pid = queue.pop().unwrap()
    if seen.contains(pid) {
      continue
    }
    seen.push(pid)
    bytes += match byp.get(pid) {
      Some(p) => p.bytes
      None => 0.0
    }
    match children.get(pid) {
      Some(c) => queue.push_iter(c.iter())
      None => ()
    }
  }
  (bytes, pids.length())
}

///|
/// module.ts `frontIn`: the front's resident bytes, the launcher's child that runs the program.
pub fn front_in(table : Array[ProcessInfo]?, launcher : Double?, self_pid : Double) -> Double? {
  guard table is Some(t) && launcher is Some(l) else { return None }
  for p in t {
    if p.ppid == l && p.pid != self_pid && starts(posix_basename(p.command), "stillfail-reade") {
      return Some(p.bytes)
    }
  }
  None
}

// ── watch.ts ─────────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let resources_look_ms : Double = 5000.0

///|
pub let resources_history_ms : Double = 600000.0

///|
/// watch.ts `Whose`.
pub(all) struct Whose {
  key : String
  kind : String
  session : String?
}

///|
fn chat_whose(session : String) -> Whose {
  { key: "chat:" + session, kind: "chat", session: Some(session) }
}

///|
/// watch.ts `Runner`.
pub(all) struct Runner {
  runner : Double
  pid : Double
  session : String?
}

///|
/// watch.ts `whoseOf`: each process's whose (in the order given).
pub fn whose_of(
  table : Array[ProcessInfo],
  jobs : Array[(String, Double)],
  is_app : (String) -> Bool,
  self_pids : Array[Double],
  runners : Array[Runner],
  args : Array[(Double, String)]?,
  places : () -> Array[(String, String)],
  places_in_arguments : ((Array[String]) -> Array[(String, String)]?)?,
) -> Map[Double, Whose] {
  let byp = by_pid(table)
  let children = children_of(table)
  let out : Map[Double, Whose] = Map([])
  let give = (roots : Array[Double], whose : Whose) => {
    let queue = roots.copy()
    while queue.length() > 0 {
      let pid = queue.pop().unwrap()
      if out.contains(pid) || !byp.contains(pid) {
        continue
      }
      out[pid] = whose
      match children.get(pid) {
        Some(c) => queue.push_iter(c.iter())
        None => ()
      }
    }
  }
  for j in jobs {
    give(table.filter(p => p.pgid == j.1).map(p => p.pid), chat_whose(j.0))
  }
  for r in runners {
    give([r.runner, r.pid], match r.session {
      Some(s) => chat_whose(s)
      None => { key: "agents", kind: "agents", session: None }
    })
  }
  let app = table.filter(p => is_app(p.command) &&
    !(match byp.get(p.ppid) {
      Some(parent) => is_app(parent.command)
      None => false
    }))
  give(app.map(p => p.pid), { key: "app", kind: "app", session: None })
  give(self_pids, { key: "station", kind: "station", session: None })
  match args {
    None => ()
    Some(a) => {
      let line_of = (pid : Double) => match a.search_by(x => x.0 == pid) {
        Some(k) => Some(a[k].1)
        None => None
      }
      let lines : Array[String] = []
      for p in table {
        if out.contains(p.pid) || out.contains(p.ppid) {
          continue
        }
        match line_of(p.pid) {
          Some(l) if !lines.contains(l) => lines.push(l)
          _ => ()
        }
      }
      let owners : Array[(String, String)]? = if lines.is_empty() {
        Some([])
      } else {
        match places_in_arguments {
          Some(f) => f(lines)
          None => None
        }
      }
      let dirs = match owners {
        Some(_) => []
        None =>
          stable_sort(
            places().map(p => (if ends(p.0, "/") { p.0 } else { p.0 + "/" }, p.1)),
            (x, y) => y.0.length() - x.0.length(),
          )
      }
      for p in table {
        if out.contains(p.pid) || out.contains(p.ppid) {
          continue
        }
        guard line_of(p.pid) is Some(line) else { continue }
        let session = match owners {
          None =>
            match dirs.search_by(d => has(line, d.0)) {
              Some(k) => Some(dirs[k].1)
              None => None
            }
          Some(o) => env_get(o, line)
        }
        match session {
          Some(s) => give([p.pid], chat_whose(s))
          None => ()
        }
      }
    }
  }
  out
}

///|
/// watch.ts `Use`.
pub(all) struct Use {
  mut cpu : Double
  mut memory : Double
  mut net_in : Double
  mut net_out : Double
  mut disk_read : Double
  mut disk_write : Double
}

///|
fn zero_use() -> Use {
  { cpu: 0.0, memory: 0.0, net_in: 0.0, net_out: 0.0, disk_read: 0.0, disk_write: 0.0 }
}

///|
fn Use::add(self : Use, u : Use) -> Unit {
  self.cpu += u.cpu
  self.memory += u.memory
  self.net_in += u.net_in
  self.net_out += u.net_out
  self.disk_read += u.disk_read
  self.disk_write += u.disk_write
}

///|
fn use_fields(m : Map[String, Json], u : Use) -> Unit {
  m["cpu"] = jn(u.cpu)
  m["memory"] = jn(u.memory)
  m["netIn"] = jn(u.net_in)
  m["netOut"] = jn(u.net_out)
  m["diskRead"] = jn(u.disk_read)
  m["diskWrite"] = jn(u.disk_write)
}

///|
/// watch.ts `Usage`: what a process used so far.
pub(all) struct Usage {
  cpu_ns : Double
  footprint : Double
  disk_read : Double?
  disk_written : Double?
}

///|
struct Had {
  cpu_ns : Double
  footprint : Double
  disk_read : Double?
  disk_written : Double?
  in_ : Double
  out : Double
  command : String
}

///|
priv struct Proc {
  pid : Double
  name : String
  use_ : Use
  endable : Bool
}

///|
struct Group {
  whose : Whose
  use_ : Use
  processes : Array[Proc]
}

///|
/// watch.ts `ResourceWatch`'s looks and snapshot.
pub struct ResourceWatch {
  mut last : Map[Double, Had]
  mut last_at : Double?
  mut seen : Map[Double, String]
  mut now_ : (Double, Array[Group], Use)?
  mut history : Array[(Double, Use)]
  mut counted : Bool
  mut net : Bool
  mut disk : Bool
}

///|
pub fn ResourceWatch::new() -> ResourceWatch {
  { last: Map([]), last_at: None, seen: Map([]), now_: None, history: [], counted: false, net: false, disk: false }
}

///|
/// watch.ts `#fresh`.
pub fn ResourceWatch::fresh(self : ResourceWatch, now : Double) -> Bool {
  match self.last_at {
    Some(l) => now - l <= 3.0 * resources_look_ms
    None => false
  }
}

///|
/// A program as people know it: its executable's name.
fn program_name(command : String) -> String {
  let b = posix_basename(command)
  if b == "" {
    "?"
  } else {
    b
  }
}

///|
fn max0(n : Double) -> Double {
  if n > 0.0 {
    n
  } else {
    0.0
  }
}

///|
/// watch.ts `look`: the table (None: not read), whose each is, what each used (`usage` by pid, of those that are
/// someone's), the traffic (None: not read).
pub fn ResourceWatch::look(
  self : ResourceWatch,
  fresh : Bool,
  at : Double,
  table : Array[ProcessInfo]?,
  whose : Map[Double, Whose],
  agent_own : Array[Double],
  usage : (Array[Double]) -> Array[Usage?],
  traffic : Array[(Double, Double, Double)]?,
) -> Unit {
  guard table is Some(table) else { return }
  let mine = table.filter(p => whose.contains(p.pid))
  let used = usage(mine.map(p => p.pid))
  self.net = traffic is Some(_)
  let since = if fresh { self.last_at } else { None }
  let seconds = match since {
    Some(s) => (at - s) / 1000.0
    None => 0.0
  }
  let groups : Array[Group] = []
  let last : Map[Double, Had] = Map([])
  for i, p in mine {
    guard used.get(i) is Some(Some(read)) else { continue }
    let had = self.last.get(p.pid)
    let (tin, tout) = match traffic {
      Some(t) =>
        match t.search_by(x => x.0 == p.pid) {
          Some(k) => (t[k].1, t[k].2)
          None =>
            match had {
              Some(h) if h.command == p.command => (h.in_, h.out)
              _ => (0.0, 0.0)
            }
        }
      None =>
        match had {
          Some(h) if h.command == p.command => (h.in_, h.out)
          _ => (0.0, 0.0)
        }
    }
    self.counted = true
    if read.disk_read is Some(_) {
      self.disk = true
    }
    let u : Had = {
      cpu_ns: read.cpu_ns,
      footprint: read.footprint,
      disk_read: read.disk_read,
      disk_written: read.disk_written,
      in_: tin,
      out: tout,
      command: p.command,
    }
    last[p.pid] = u
    if since is None || seconds <= 0.0 {
      continue
    }
    let w = whose.get(p.pid).unwrap()
    let same = match had {
      Some(b) => b.command == p.command && b.cpu_ns <= u.cpu_ns
      None => false
    }
    if !same && self.seen.get(p.pid) == Some(p.command) {
      continue
    }
    let was = if same { had } else { None }
    let wv = (f : (Had) -> Double) => match was {
      Some(h) => f(h)
      None => 0.0
    }
    let use_ : Use = {
      cpu: max0((u.cpu_ns - wv(h => h.cpu_ns)) / 1.0e9 / seconds) * 100.0,
      memory: u.footprint,
      net_in: max0((u.in_ - wv(h => h.in_)) / seconds),
      net_out: max0((u.out - wv(h => h.out)) / seconds),
      disk_read: max0((u.disk_read.unwrap_or(0.0) - wv(h => h.disk_read.unwrap_or(0.0))) / seconds),
      disk_write: max0((u.disk_written.unwrap_or(0.0) - wv(h => h.disk_written.unwrap_or(0.0))) / seconds),
    }
    let g = match groups.search_by(g => g.whose.key == w.key) {
      Some(k) => groups[k]
      None => {
        let g : Group = { whose: w, use_: zero_use(), processes: [] }
        groups.push(g)
        g
      }
    }
    g.use_.add(use_)
    g.processes.push({
      pid: p.pid,
      name: program_name(p.command),
      use_,
      endable: w.kind == "chat" && !agent_own.contains(p.pid),
    })
  }
  self.last = last
  self.last_at = Some(at)
  let seen : Map[Double, String] = Map([])
  for p in table {
    seen[p.pid] = p.command
  }
  self.seen = seen
  if since is None {
    return
  }
  let by_cpu = (a : Double, b : Double) => if b > a { 1 } else if b < a { -1 } else { 0 }
  let list = stable_sort(
    groups.map(g => { ..g, processes: stable_sort(g.processes, (a, b) => by_cpu(a.use_.cpu, b.use_.cpu)) }),
    (a, b) => by_cpu(a.use_.cpu, b.use_.cpu),
  )
  let total = zero_use()
  for g in list {
    total.add(g.use_)
  }
  self.now_ = Some((at, list, total))
  self.history.push((at, total))
  self.history = self.history.filter(p => p.0 > at - resources_history_ms)
}

///|
fn group_json(g : Group) -> Json {
  let m : Map[String, Json] = { "key": js(g.whose.key), "kind": js(g.whose.kind), "session": opt_s(g.whose.session) }
  use_fields(m, g.use_)
  m["processes"] = Json::array(
    g.processes.map(p => {
      let pm : Map[String, Json] = Map([])
      use_fields(pm, p.use_)
      pm["pid"] = jn(p.pid)
      pm["name"] = js(p.name)
      pm["endable"] = jb(p.endable)
      Json::object(pm)
    }),
  )
  Json::object(m)
}

///|
/// watch.ts `snapshot`.
pub fn ResourceWatch::snapshot(self : ResourceWatch) -> Json {
  let total : Map[String, Json] = Map([])
  let (at, groups) = match self.now_ {
    Some((at, groups, t)) => {
      use_fields(total, t)
      (jn(at), Json::array(groups.map(group_json)))
    }
    None => {
      use_fields(total, zero_use())
      (Json::null(), Json::array([]))
    }
  }
  {
    "at": at,
    "everyMs": jn(resources_look_ms),
    "counted": jb(self.counted),
    "net": jb(self.net),
    "disk": jb(self.disk),
    "total": Json::object(total),
    "groups": groups,
    "history": Json::array(
      self.history.map(h => {
        let m : Map[String, Json] = { "at": jn(h.0) }
        use_fields(m, h.1)
        Json::object(m)
      }),
    ),
  }
}

///|
/// watch.ts `end`'s choice: whether `pid` may be ended for `session` (a chat's, not its agent's own), and its name;
/// Err the refusal's words.
pub fn end_choice(
  table : Array[ProcessInfo]?,
  pid : Double,
  session : String,
  whose : Map[Double, Whose],
  agent_own : Array[Double],
) -> Result[String, String] {
  guard table is Some(t) else { return Err("gone") }
  guard t.search_by(p => p.pid == pid) is Some(k) else { return Err("gone") }
  match whose.get(pid) {
    Some(w) if w.kind == "chat" && w.session == Some(session) && !agent_own.contains(pid) => Ok(program_name(t[k].command))
    _ => Err("not a chat's")
  }
}

// ── linux.ts ─────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// linux.ts `ticksOfStat`: user and system time, in clock ticks.
pub fn ticks_of_stat(text : String) -> Double? {
  let end = last_index_of(text, ")")
  if end < 0 {
    return None
  }
  let f = split_runs(js_trim(sub(text, end + 1, text.length())), js_space)
  let user = match f.get(11) {
    Some(x) => js_number(x)
    None => @double.not_a_number
  }
  let system = match f.get(12) {
    Some(x) => js_number(x)
    None => @double.not_a_number
  }
  if user.is_nan() || user.is_inf() || system.is_nan() || system.is_inf() {
    None
  } else {
    Some(user + system)
  }
}

///|
/// `^name:\s*(\d+)\s*kB` (a line of it), in bytes.
fn kb_line(text : String, name : String) -> Double? {
  for line in split_lines_any(text) {
    if !starts(line, name + ":") {
      continue
    }
    let i = spaces_from(line, name.length() + 1)
    let e = digits_from(line, i)
    if e == i {
      continue
    }
    let k = spaces_from(line, e)
    if starts(sub(line, k, line.length()), "kB") {
      return Some(js_number(sub(line, i, e)) * 1024.0)
    }
  }
  None
}

///|
/// A text's lines as `^` with the `m` flag starts them: after \n, \r, U+2028, U+2029.
fn split_lines_any(text : String) -> Array[String] {
  split_by(text, c => c == 10 || c == 13 || c == 0x2028 || c == 0x2029)
}

///|
/// linux.ts `footprintOfStatus`.
pub fn footprint_of_status(text : String) -> Double? {
  match kb_line(text, "RssAnon") {
    Some(anon) => Some(anon + kb_line(text, "RssShmem").unwrap_or(0.0) + kb_line(text, "VmSwap").unwrap_or(0.0))
    None => kb_line(text, "VmRSS")
  }
}

///|
/// `^name:\s*(\d+)` (a line of it).
fn num_line(text : String, name : String) -> Double? {
  for line in split_lines_any(text) {
    if !starts(line, name + ":") {
      continue
    }
    let i = spaces_from(line, name.length() + 1)
    let e = digits_from(line, i)
    if e > i {
      return Some(js_number(sub(line, i, e)))
    }
  }
  None
}

///|
/// linux.ts `diskOfIo`.
pub fn disk_of_io(text : String) -> (Double, Double)? {
  match (num_line(text, "read_bytes"), num_line(text, "write_bytes")) {
    (Some(r), Some(w)) => Some((r, w))
    _ => None
  }
}

///|
/// linux.ts `linuxUsage` of one pid, from its files' texts (None where one did not read).
pub fn linux_usage(stat : String?, status : String?, io : String?, tick : Double) -> Json {
  guard stat is Some(st) && ticks_of_stat(st) is Some(ticks) else { return Json::null() }
  let m : Map[String, Json] = {
    "cpuNs": jn(ticks * tick),
    "footprint": jn(
      match status {
        Some(s) => footprint_of_status(s).unwrap_or(0.0)
        None => 0.0
      },
    ),
  }
  match io {
    Some(i) =>
      match disk_of_io(i) {
        Some((r, w)) => {
          m["diskRead"] = jn(r)
          m["diskWritten"] = jn(w)
        }
        None => ()
      }
    None => ()
  }
  Json::object(m)
}
