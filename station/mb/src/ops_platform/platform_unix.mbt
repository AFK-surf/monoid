// station/src/platform/unix.ts: macOS and Linux (and another Unix as Linux), what it works out of what it is given
// (the machine's kind is a parameter, `mac`, so both are held to the TypeScript on any machine): the commands it makes,
// what it reads out of the commands' and files' words, its paths.

///|
/// unix.ts `Background`: which wrapper starts background work here.
pub(all) enum Background {
  Taskpolicy
  Ionice(String, String)
  Nice(String)
  NoWrapper
}

///|
fn background_of(j : Json) -> Background {
  match str_or(j, "kind", "none") {
    "taskpolicy" => Taskpolicy
    "ionice" => Ionice(str_or(j, "ionice", ""), str_or(j, "nice", ""))
    "nice" => Nice(str_or(j, "nice", ""))
    _ => NoWrapper
  }
}

///|
/// unix.ts `backgroundedOn`.
pub fn backgrounded_on(how : Background, program : String, args : Array[String]) -> (String, Array[String]) {
  match how {
    Taskpolicy => ("/usr/sbin/taskpolicy", ["-b", program, ..args])
    Ionice(ionice, nice) => (ionice, ["-t", "-c2", "-n7", nice, "-n", "10", program, ..args])
    Nice(nice) => (nice, ["-n", "10", program, ..args])
    NoWrapper => (program, args)
  }
}

///|
/// unix.ts `background`: the wrapper by what is there (`there`: whether a path is; `real`: where a link leads).
pub fn background_found(mac : Bool, there : (String) -> Bool, real : (String) -> String?) -> Background {
  let nice = ["/usr/bin/nice", "/bin/nice"].search_by(there).map(i => ["/usr/bin/nice", "/bin/nice"][i])
  if mac && there("/usr/sbin/taskpolicy") {
    return Taskpolicy
  }
  let ionice = if mac {
    None
  } else {
    let cands = ["/usr/bin/ionice", "/bin/ionice"]
    cands.search_by(p => there(p) && !has(real(p).unwrap_or(p), "busybox")).map(i => cands[i])
  }
  match (ionice, nice) {
    (Some(i), Some(n)) => Ionice(i, n)
    (_, Some(n)) => Nice(n)
    _ => NoWrapper
  }
}

///|
/// unix.ts `clean` (files.rs `clean` on Unix).
pub fn unix_clean(path : String) -> String {
  let out = []
  for part in split_on(path, "/") {
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      out.pop() |> ignore
    } else {
      out.push(part)
    }
  }
  "/" + out.join("/")
}

///|
/// unix.ts `startTimeOf`'s reading of ps's `etime` (`[[dd-]hh:]mm:ss`), at `now`; None where it does not read.
pub fn start_time_of_etime(text : String, now : Double) -> Double? {
  let text = js_trim(text)
  if text == "" {
    return None
  }
  let mut days = 0.0
  let mut rest = text
  let dash = index_of(text, "-")
  if dash >= 0 {
    days = js_number(sub(text, 0, dash))
    rest = sub(text, dash + 1, text.length())
    if !is_integer(days) {
      return None
    }
  }
  let parts = split_on(rest, ":").map(js_number)
  if parts.iter().any(p => !is_integer(p)) {
    return None
  }
  let seconds = if parts.length() == 3 {
    parts[0] * 3600.0 + parts[1] * 60.0 + parts[2]
  } else if parts.length() == 2 {
    parts[0] * 60.0 + parts[1]
  } else {
    return None
  }
  Some(now - (seconds + days * 86400.0) * 1000.0)
}

///|
pub(all) struct Memory {
  total_bytes : Double
  used_bytes : Double
  swap_used_bytes : Double?
  known : Bool?
}

///|
pub fn Memory::to_json(self : Memory) -> Json {
  let m : Map[String, Json] = {
    "totalBytes": jn(self.total_bytes),
    "usedBytes": jn(self.used_bytes),
    "swapUsedBytes": opt_n(self.swap_used_bytes),
  }
  match self.known {
    Some(k) => m["known"] = jb(k)
    None => ()
  }
  Json::object(m)
}

///|
/// unix.ts `macMemoryOf`: macOS's memory from what sysctl and vm_stat said.
pub fn mac_memory_of(total_text : String?, vm : String?, swap : () -> String?) -> Memory {
  let total = parse_u64(total_text.unwrap_or("")).unwrap_or(0.0)
  match vm {
    Some(vm) => {
      let after = split_on(vm, "page size of ").get(1)
      let page = match after {
        Some(a) => parse_u64(first_word(a))
        None => None
      }
      let anonymous = field_or_null(vm, "Anonymous pages")
      let purgeable = field_or_null(vm, "Pages purgeable")
      let wired = field_or_null(vm, "Pages wired down")
      let compressed = field_or_null(vm, "Pages occupied by compressor")
      match (page, anonymous, purgeable, wired, compressed) {
        (Some(page), Some(an), Some(pu), Some(wi), Some(co)) if total > 0.0 && page > 0.0 => {
          let pages = an - pu + wi + co
          let used = (if pages > 0.0 { pages } else { 0.0 }) * page
          let used_text = match swap() {
            Some(s) =>
              match split_on(s, "used = ").get(1) {
                Some(t) => Some(split_on(t, "M")[0])
                None => None
              }
            None => None
          }
          let swap_mb = match used_text {
            Some(t) => parse_f64(t)
            None => None
          }
          return {
            total_bytes: total,
            used_bytes: if used < total { used } else { total },
            swap_used_bytes: swap_mb.map(mb => js_round(mb * 1024.0 * 1024.0)),
            known: None,
          }
        }
        _ => ()
      }
    }
    None => ()
  }
  { total_bytes: total, used_bytes: 0.0, swap_used_bytes: None, known: Some(false) }
}

///|
/// unix.ts `host.sample` on Linux, from /proc's meminfo, cpuinfo and uptime (each "" where it did not read).
pub fn linux_sample(info : String, cpus : String, up : String) -> (Memory, String, Double) {
  let total = field_or_null(info, "MemTotal")
  let available = field_or_null(info, "MemAvailable")
  let swap_total = field_or_null(info, "SwapTotal")
  let swap_free = field_or_null(info, "SwapFree")
  let swap_used = match (swap_total, swap_free) {
    (Some(t), Some(f)) if f <= t => Some((t - f) * 1024.0)
    _ => None
  }
  let memory : Memory = match (total, available) {
    (Some(t), Some(a)) if t > 0.0 && a <= t =>
      { total_bytes: t * 1024.0, used_bytes: (t - a) * 1024.0, swap_used_bytes: swap_used, known: None }
    _ =>
      {
        total_bytes: total.unwrap_or(0.0) * 1024.0,
        used_bytes: 0.0,
        swap_used_bytes: swap_used,
        known: Some(false),
      }
  }
  let mut model = ""
  for l in split_on(cpus, "\n") {
    if !starts(l, "model name") {
      continue
    }
    let colon = index_of(l, ":", from=10)
    if colon >= 0 {
      model = rtrim(sub(l, colon + 1, l.length()))
      break
    }
  }
  let uptime = if up == "" { None } else { parse_f64(first_word(up)) }
  (memory, model, match uptime {
    Some(u) => js_round(u)
    None => 0.0
  })
}

///|
/// unix.ts `host.sample` on macOS: its uptime from `kern.boottime` at `now`, and its own footprint from `footprint`.
pub fn mac_boot_and_footprint(boot : String?, footprint : String?, now : Double) -> (Double, Double?) {
  let sec = match boot {
    Some(b) =>
      match split_on(b, "sec = ").get(1) {
        Some(t) => Some(split_on(t, ",")[0])
        None => None
      }
    None => None
  }
  let booted = match sec {
    Some(s) => {
      let t = rtrim(s)
      let body = if starts(t, "+") || starts(t, "-") { sub(t, 1, t.length()) } else { t }
      if digits(body) {
        Some(js_number(t))
      } else {
        None
      }
    }
    None => None
  }
  let uptime = match booted {
    Some(b) => {
      let d = (now / 1000.0).floor() - b
      if d > 0.0 {
        d
      } else {
        0.0
      }
    }
    None => 0.0
  }
  // `/phys_footprint:\s*(\d+)\s*B/`
  let bytes = match footprint {
    Some(f) => {
      let mut found : Double? = None
      let mut from = 0
      while found is None {
        let at = index_of(f, "phys_footprint:", from~)
        if at < 0 {
          break
        }
        let i = spaces_from(f, at + 15)
        let e = digits_from(f, i)
        if e > i {
          let k = spaces_from(f, e)
          if k < f.length() && cu(f, k) == 66 {
            found = Some(js_number(sub(f, i, e)))
          }
        }
        from = at + 1
      }
      found
    }
    None => None
  }
  (uptime, bytes)
}

///|
/// unix.ts `quoted`: a word as one argument of a POSIX shell's command line.
pub fn sh_quoted(word : String) -> String {
  let plain = word != "" &&
    all_units(word, c => is_alnum(c) ||
      c == 95 ||
      c == 46 ||
      c == 47 ||
      c == 61 ||
      c == 58 ||
      c == 64 ||
      c == 37 ||
      c == 43 ||
      c == 45)
  if plain {
    word
  } else {
    "'" + word.replace_all(old="'", new="'\\''") + "'"
  }
}

///|
/// unix.ts `descendants`: from what `ps -A -o pid=,ppid=` said, the processes `pid` started and theirs.
pub fn descendants_of(text : String, pid : Double) -> Array[Double] {
  let children : Array[(Double, Array[Double])] = []
  for line in split_on(text, "\n") {
    let words = split_runs(js_trim(line), js_space)
    let child = js_number(words[0])
    let parent = js_number(words.get(1).unwrap_or("x"))
    if words.length() < 2 || !is_integer(child) || !is_integer(parent) {
      continue
    }
    match children.search_by(c => c.0 == parent) {
      Some(k) => children[k].1.push(child)
      None => children.push((parent, [child]))
    }
  }
  let out = []
  let next = [pid]
  while next.length() > 0 {
    let p = next.pop().unwrap()
    match children.search_by(c => c.0 == p) {
      Some(k) =>
        for c in children[k].1 {
          if out.contains(c) {
            continue
          }
          out.push(c)
          next.push(c)
        }
      None => ()
    }
  }
  out
}

///|
/// `parseInt(s, 16)`: the hex digits it starts with; NaN where none.
fn parse_hex(s : String) -> Double {
  let t = js_trim(s)
  let mut i = 0
  let mut v = 0.0
  while i < t.length() {
    let c = cu(t, i)
    let d = if is_digit(c) {
      c - 48
    } else if c >= 97 && c <= 102 {
      c - 87
    } else if c >= 65 && c <= 70 {
      c - 55
    } else {
      break
    }
    v = v * 16.0 + d.to_double()
    i += 1
  }
  if i == 0 {
    @double.not_a_number
  } else {
    v
  }
}

///|
/// unix.ts `procAddress`: /proc/net/tcp's address as an address (0100007F → 127.0.0.1).
pub fn proc_address(hex : String) -> String {
  if hex != "" && all_units(hex, c => c == 48) {
    return "*"
  }
  let words = []
  let mut i = 0
  while i + 8 <= hex.length() {
    words.push(sub(hex, i, i + 8))
    i += 8
  }
  let bytes = []
  for w in words {
    let pairs = []
    let mut k = 0
    while k + 2 <= w.length() {
      pairs.push(sub(w, k, k + 2))
      k += 2
    }
    pairs.rev_in_place()
    for p in pairs {
      bytes.push(parse_hex(p))
    }
  }
  let txt = (bs : ArrayView[Double]) => bs.to_owned().map(num_text).join(".")
  if bytes.length() == 4 {
    return txt(bytes[:])
  }
  let zero10 = bytes.length() >= 10 && bytes[0:10].iter().all(b => b == 0.0)
  if zero10 && bytes.get(10) == Some(255.0) && bytes.get(11) == Some(255.0) {
    return txt(bytes[12:])
  }
  if bytes.length() >= 15 && bytes[0:15].iter().all(b => b == 0.0) && bytes.get(15) == Some(1.0) {
    return "::1"
  }
  let quads = []
  let mut q = 0
  while q + 4 <= hex.length() {
    quads.push(sub(hex, q, q + 4))
    q += 4
  }
  quads.join(":")
}

///|
/// unix.ts `procListening`'s first step: the listening sockets at `port` in /proc/net/tcp's or tcp6's words, each
/// inode with its address (the later table's over the earlier's).
pub fn proc_listening_sockets(tables : Array[String], port : Double) -> Array[(String, String)] {
  let sockets : Array[(String, String)] = []
  for text in tables {
    let lines = split_on(text, "\n")
    for li in 1..<lines.length() {
      let f = split_runs(js_trim(lines[li]), js_space)
      if f.length() < 10 || f[3] != "0A" {
        continue
      }
      let parts = split_on(f[1], ":")
      if parse_hex(parts.get(1).unwrap_or("")) == port {
        let address = proc_address(parts[0])
        match sockets.search_by(s => s.0 == f[9]) {
          Some(k) => sockets[k] = (f[9], address)
          None => sockets.push((f[9], address))
        }
      }
    }
  }
  sockets
}

///|
/// `/^socket:\[(\d+)\]$/`: a descriptor's link to a socket, its inode.
pub fn socket_inode(target : String) -> String? {
  if starts(target, "socket:[") && ends(target, "]") {
    let inner = sub(target, 8, target.length() - 1)
    if digits(inner) {
      return Some(inner)
    }
  }
  None
}

///|
/// unix.ts `tcpPortPids` on Linux: the inodes of the connections whose own end is `port` (local 127.0.0.1's, state 01).
pub fn tcp_port_inodes(tables : Array[String], port : Int) -> Array[String] {
  let hex = upper(port.to_string(radix=16)).pad_start(4, '0')
  let inodes = []
  for text in tables {
    let lines = split_on(text, "\n")
    for li in 1..<lines.length() {
      let f = split_runs(js_trim(lines[li]), js_space)
      if f.length() > 9 && ends(f[1], ":" + hex) && f[3] == "01" && !inodes.contains(f[9]) {
        inodes.push(f[9])
      }
    }
  }
  inodes
}

///|
/// unix.ts `tcpPortPids` on macOS: lsof's `-Fp` pids, each once, this process's left out.
pub fn lsof_pids(stdout : String, own : Double) -> Array[Double] {
  let out = []
  for l in split_on(stdout, "\n") {
    if starts(l, "p") {
      let p = js_number(sub(l, 1, l.length()))
      if !out.iter().any(x => x == p || (x.is_nan() && p.is_nan())) {
        out.push(p)
      }
    }
  }
  out.filter(p => p != own)
}

///|
/// unix.ts `groupMemory`: `ps -axo pgid=,rss=` summed by the groups asked (kB), in the order first found.
pub fn group_memory_of_ps(stdout : String, pgids : Array[Double]) -> Array[(Double, Double)] {
  let rss : Array[(Double, Double)] = []
  for line in split_on(stdout, "\n") {
    let words = split_runs(js_trim(line), js_space).map(js_number)
    if words.length() < 2 {
      continue
    }
    let pgid = words[0]
    let kb = words[1]
    if pgids.contains(pgid) {
      match rss.search_by(r => r.0 == pgid) {
        Some(k) => rss[k] = (pgid, rss[k].1 + kb)
        None => rss.push((pgid, kb))
      }
    }
  }
  rss
}

///|
/// unix.ts `inTerminal`: a command in a pseudo-terminal of `cols` × `rows`, as `script` gives one.
pub fn in_terminal(
  mac : Bool,
  script : String?,
  program : String,
  args : Array[String],
  cols : Int,
  rows : Int,
) -> (String, Array[String])? {
  let run = "stty cols \{cols} rows \{rows} 2>/dev/null; exec \"$@\""
  let inner = ["/bin/sh", "-c", run, "sh", program, ..args]
  if mac {
    let feed = "exec 3<&0; cat <&3 | { /usr/bin/script -q /dev/null /bin/sh -c '\{run}' sh \"$@\" 3<&-; s=$?; /usr/bin/pkill -P $$ -x cat; exit $s; }"
    return Some(("/bin/sh", ["-c", feed, "sh", program, ..args]))
  }
  match script {
    None => None
    Some(s) => Some((s, ["-qfec", inner.map(sh_quoted).join(" "), "/dev/null"]))
  }
}

///|
/// unix.ts `paths.within`.
pub fn unix_within(path : String, dir : String) -> Bool {
  dir == "/" || path == dir || starts(path, dir + "/")
}

///|
/// unix.ts `paths.join`.
pub fn unix_join(base : String, given : String) -> String {
  if starts(given, "/") || base == "" {
    given
  } else if ends(base, "/") {
    base + given
  } else {
    base + "/" + given
  }
}

///|
/// unix.ts `paths.relativeIn`.
pub fn unix_relative_in(root : String, path : String) -> String? {
  if path == root {
    return Some("")
  }
  let prefix = if ends(root, "/") { root } else { root + "/" }
  if starts(path, prefix) {
    Some(sub(path, prefix.length(), path.length()))
  } else {
    None
  }
}

///|
/// unix.ts `nativeCache`.
pub fn unix_native_cache(mac : Bool, env : Array[(String, String)], home : String) -> String {
  match env_truthy(env, "STILLFAIL_NATIVE_CACHE") {
    Some(c) => c
    None =>
      if mac {
        posix_join([home, "Library", "Caches", "stillfail-native"])
      } else {
        let cache = match env_truthy(env, "XDG_CACHE_HOME") {
          Some(x) => x
          None => posix_join([home, ".cache"])
        }
        posix_join([cache, "stillfail-native"])
      }
  }
}

///|
/// unix.ts `prependPath`: `env` with `dir` first on PATH.
pub fn unix_prepend_path(env : Array[(String, String)], dir : String) -> Array[(String, String)] {
  let out = env.copy()
  env_set(out, "PATH", dir + ":" + env_get(env, "PATH").unwrap_or(""))
  out
}

///|
/// unix.ts `appendPath`: `dir` put last on `env`'s PATH unless it is on it already.
pub fn unix_append_path(env : Array[(String, String)], dir : String) -> Unit {
  let path = env_get(env, "PATH").unwrap_or("")
  if split_on(path, ":").contains(dir) {
    return
  }
  env_set(env, "PATH", if path == "" { dir } else { path + ":" + dir })
}

///|
/// unix.ts `lowered`.
pub fn unix_lowered(program : String, args : Array[String], by : Int, nice_there : Bool) -> (String, Array[String]) {
  if by == 0 || !nice_there {
    (program, args)
  } else {
    ("/usr/bin/nice", ["-n", by.to_string(), program, ..args])
  }
}

///|
/// unix.ts `flushing`.
pub fn unix_flushing(mac : Bool, dir : String) -> (String, Array[String]) {
  if mac {
    ("sync", [])
  } else {
    ("sync", ["-f", dir])
  }
}

///|
/// unix.ts `agyStaging`.
pub fn unix_agy_staging(env : Array[(String, String)], url : String) -> String? {
  match env_truthy(env, "HOME") {
    Some(h) =>
      Some(
        posix_join([h, ".cache", "antigravity", "staging", if has(url, ".tar.gz") { "agy.tar.gz" } else { "agy" }]),
      )
    None => None
  }
}

///|
pub(all) struct NodeBuild {
  dist : String
  archive : String
  bin : String
  npm : String
  tar : String
}

///|
pub fn NodeBuild::to_json(self : NodeBuild) -> Json {
  { "dist": js(self.dist), "archive": js(self.archive), "bin": js(self.bin), "npm": js(self.npm), "tar": js(self.tar) }
}

///|
/// unix.ts `nodeBuild` for Node's `platform` and `arch`.
pub fn unix_node_build(version : String, platform : String, arch : String) -> NodeBuild? {
  if (platform != "darwin" && platform != "linux") || (arch != "arm64" && arch != "x64") {
    return None
  }
  let dist = "node-v\{version}-\{platform}-\{arch}"
  Some({ dist, archive: dist + ".tar.gz", bin: "bin", npm: "npm", tar: "tar" })
}

///|
/// unix.ts `agyBuild` for Node's `platform` and `arch`, `musl` where its libc's files are there.
pub fn unix_agy_build(platform : String, arch : String, musl : Bool) -> String? {
  let a = if arch == "arm64" {
    "arm64"
  } else if arch == "x64" {
    "amd64"
  } else {
    return None
  }
  if platform == "darwin" {
    return Some("darwin_" + a)
  }
  if platform != "linux" || musl {
    return None
  }
  Some("linux_" + a)
}

///|
/// unix.ts `browserPlaces`: where a Chrome may be, best first, `on_path` where a command is found on PATH.
pub fn unix_browser_places(mac : Bool, env : Array[(String, String)], on_path : (String) -> String?) -> Array[String] {
  let home = env_get(env, "HOME").unwrap_or("")
  let apps = (name : String, binary : String) => [
    "/Applications/\{name}.app/Contents/MacOS/\{binary}",
    posix_join([home, "Applications", name + ".app", "Contents", "MacOS", binary]),
  ]
  let out = []
  if mac {
    out.push_iter(apps("Google Chrome", "Google Chrome").iter())
    out.push_iter(apps("Chromium", "Chromium").iter())
    out.push_iter(apps("Microsoft Edge", "Microsoft Edge").iter())
  } else {
    for n in ["google-chrome-stable", "google-chrome"] {
      match on_path(n) {
        Some(p) => out.push(p)
        None => ()
      }
    }
    out.push("/opt/google/chrome/chrome")
    for n in ["chromium", "chromium-browser", "microsoft-edge-stable", "microsoft-edge"] {
      match on_path(n) {
        Some(p) => out.push(p)
        None => ()
      }
    }
  }
  let seen = []
  for p in out {
    if !seen.contains(p) {
      seen.push(p)
    }
  }
  seen
}

///|
/// unix.ts `cwds` on macOS: lsof's `-Fpn` (each `p` a pid, the `n` after it its directory).
pub fn lsof_cwds(text : String) -> Array[(Double, String)] {
  let out : Array[(Double, String)] = []
  let mut pid : Double? = None
  for line in split_on(text, "\n") {
    if starts(line, "p") {
      pid = Some(js_number(sub(line, 1, line.length())))
    } else if starts(line, "n") {
      match pid {
        Some(p) =>
          match out.search_by(o => o.0 == p) {
            Some(k) => out[k] = (p, sub(line, 1, line.length()))
            None => out.push((p, sub(line, 1, line.length())))
          }
        None => ()
      }
    }
  }
  out
}

///|
/// unix.ts `commands`: ps's `comm=` lines.
pub fn ps_commands(stdout : String) -> Array[String] {
  split_on(stdout, "\n").map(js_trim).filter(l => l != "")
}

///|
/// Whether `stty -a`'s words hold `word` as a whole word (`/(^|\s)word(\s|$)/`).
fn has_flag(text : String, word : String) -> Bool {
  let mut from = 0
  while true {
    let at = index_of(text, word, from~)
    if at < 0 {
      return false
    }
    let before = at == 0 || js_space(cu(text, at - 1))
    let e = at + word.length()
    let after = e == text.length() || js_space(cu(text, e))
    if before && after {
      return true
    }
    from = at + 1
  }
  false
}

///|
/// unix.ts `echoes`: from ps's `tty=` and `stty -a`'s words.
pub fn echoes_of(tty : String, stty : String?) -> Bool? {
  let t = js_trim(tty)
  if t == "" || starts(t, "?") || t == "??" {
    return None
  }
  guard stty is Some(out) else { return None }
  if has_flag(out, "-echo") && !has_flag(out, "-icanon") {
    return Some(false)
  }
  if has_flag(out, "-echo") || has_flag(out, "echo") {
    Some(true)
  } else {
    None
  }
}

///|
/// unix.ts `askLauncher`: the signal each ask is.
pub fn unix_launcher_signal(op : String) -> String? {
  match op {
    "handover" => Some("SIGUSR2")
    "drain" => Some("SIGUSR1")
    "hup" => Some("SIGHUP")
    _ => None
  }
}

///|
/// unix.ts `startInstaller`'s shell: the installer in the background, its exit and what it said written.
pub let unix_installer_shell : String = "( sh \"$1\"; echo $? > \"$2/update.exit\" ) > \"$2/update.log\" 2>&1 < /dev/null &"

///|
/// unix.ts `os`: std::env::consts::OS for Node's `platform`.
pub fn unix_os(platform : String) -> String {
  match platform {
    "darwin" => "macos"
    "linux" => "linux"
    "freebsd" => "freebsd"
    "openbsd" => "openbsd"
    p => p
  }
}

///|
/// unix.ts `userShell`: SHELL, else the user's own where `env` is this user's.
pub fn unix_user_shell(env : Array[(String, String)], user_home : String?, user_shell : String?) -> String? {
  match env_truthy(env, "SHELL") {
    Some(s) => Some(s)
    None =>
      match user_home {
        None => None
        Some(h) =>
          match env_truthy(env, "HOME") {
            None => user_shell
            Some(home) => if home == h { user_shell } else { None }
          }
      }
  }
}

///|
/// unix.ts `isLauncher`: what ps says the process runs.
pub fn unix_is_launcher(command : String) -> Bool {
  has(command, "stillfail-station")
}

///|
/// unix.ts `holdAwake`'s commands: caffeinate on macOS (for `pid`), systemd-inhibit around a `cat` elsewhere.
pub fn unix_hold_awake(mac : Bool, why : String, pid : Int, inhibit_found : Bool) -> (String, Array[String])? {
  if mac {
    return Some(("caffeinate", ["-i", "-w", pid.to_string()]))
  }
  if !inhibit_found {
    return None
  }
  Some(("systemd-inhibit", ["--what=idle:sleep", "--who=still.fail", "--why=" + why, "--mode=block", "cat"]))
}

///|
/// unix.ts `claudeInstall`, `devinInstall`, `agyInstall`.
pub fn unix_installs() -> Json {
  {
    "claudeInstall": { "program": "/bin/sh", "args": ["-c", "curl -fsSL https://claude.ai/install.sh | bash"] },
    "devinInstall": {
      "program": "/bin/sh",
      "args": [
        "-c", "set -e; s=$(curl -fsSL https://cli.devin.ai/install.sh); printf '%s\\n' \"$s\" | sed -E '/^\"[^\"]*\" setup[[:space:]]*$/d' | bash",
      ],
    },
    "agyInstall": { "program": "/bin/sh", "args": ["-c", "curl -fsSL https://antigravity.google/cli | bash"] },
  }
}
