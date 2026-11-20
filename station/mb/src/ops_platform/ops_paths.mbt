// station/src/ops/paths.ts, version.ts, own.ts, unanswered.ts, json-file.ts, disk.ts, nice.ts, held.ts, waits.ts,
// group.ts's decisions: paths as the station checks them, by the machine's own rules (`Plat`).

///|
/// Which machine's paths (platform.paths): Unix's (`/`) or Windows' (`\` and `/`, drives, case aside). `cwd` is
/// what a Windows path with no drive is resolved from.
pub(all) enum Plat {
  Unix
  Windows(String)
}

///|
fn Plat::is_sep(self : Plat, c : Int) -> Bool {
  match self {
    Unix => c == 47
    Windows(_) => wsep(c)
  }
}

///|
/// paths.ts `segments`.
pub fn segments(p : Plat, path : String) -> Array[String] {
  split_by(path, c => p.is_sep(c))
}

///|
/// paths.ts `cleanPosix`.
pub fn clean_posix(p : Plat, path : String) -> String {
  let out = []
  for part in segments(p, path) {
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
/// paths.ts `clean`.
pub fn clean_path(p : Plat, path : String) -> String {
  match p {
    Unix => unix_clean(path)
    Windows(cwd) => win_clean(path, cwd)
  }
}

///|
fn path_key(p : Plat, path : String) -> String {
  match p {
    Unix => path
    Windows(_) => lower(path)
  }
}

///|
/// paths.ts `samePath`.
pub fn same_path(p : Plat, a : String, b : String) -> Bool {
  path_key(p, a) == path_key(p, b)
}

///|
/// paths.ts `within`.
pub fn within(p : Plat, path : String, dir : String) -> Bool {
  match p {
    Unix => unix_within(path, dir)
    Windows(_) => win_within(path, dir)
  }
}

///|
/// paths.ts `inside`.
pub fn inside(p : Plat, path : String, dir : String) -> Bool {
  !same_path(p, path, dir) && within(p, path, dir)
}

///|
/// paths.ts `fileName`.
pub fn file_name(p : Plat, path : String) -> String? {
  let parts = segments(p, path).filter(x => x != "" && x != ".")
  guard parts.last() is Some(last) else { return None }
  if last == ".." {
    return None
  }
  let root_name = match p {
    Unix => false
    Windows(_) => win_is_root_name(last)
  }
  if parts.length() == 1 && root_name {
    None
  } else {
    Some(last)
  }
}

///|
/// paths.ts `anyBaseName`.
pub fn any_base_name(path : String) -> String {
  split_by(path, wsep).filter(x => x != "").last().unwrap_or("")
}

///|
/// paths.ts `joinPath`.
pub fn join_path(p : Plat, base : String, given : String) -> String {
  match p {
    Unix => unix_join(base, given)
    Windows(_) => win_join(base, given)
  }
}

///|
/// The characters a portable name has none of (`/[\x00-\x1f<>:"/\\|?*]/`).
fn unportable(c : Int) -> Bool {
  c <= 0x1f ||
  c == 60 ||
  c == 62 ||
  c == 58 ||
  c == 34 ||
  c == 47 ||
  c == 92 ||
  c == 124 ||
  c == 63 ||
  c == 42
}

///|
/// One of Windows' device names, alone or before a dot (`/^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(\.|$)/i`).
fn device_name(name : String) -> Bool {
  let low = lower(name)
  let take = (n : Int) => low.length() == n || cu(low, n) == 46
  for d in ["con", "prn", "aux", "nul"] {
    if starts(low, d) && take(3) {
      return true
    }
  }
  for d in ["com", "lpt"] {
    if starts(low, d) && low.length() >= 4 {
      let c = cu(low, 3)
      if (is_digit(c) || c == 0xb9 || c == 0xb2 || c == 0xb3) && take(4) {
        return true
      }
    }
  }
  false
}

///|
fn utf8_len(s : String) -> Int {
  @utf8.encode(s).length()
}

///|
/// paths.ts `portableName`.
pub fn portable_name(name : String) -> Bool {
  name != "" &&
  !any_unit(name, unportable) &&
  !starts(name, ".") &&
  !ends(name, ".") &&
  !ends(name, " ") &&
  !device_name(name) &&
  utf8_len(name) <= 255
}

///|
/// paths.ts `portableComponent`.
pub fn portable_component(name : String) -> String {
  if portable_name(name) {
    return name
  }
  let b = StringBuilder()
  for i in 0..<name.length() {
    let c = cu(name, i)
    b.write_char(Int::unsafe_to_char(if unportable(c) { 95 } else { c }))
  }
  let mut kept = b.to_string()
  if starts(kept, ".") {
    kept = "_" + sub(kept, 1, kept.length())
  }
  kept = sub(kept, 0, 64)
  kept + "-" + sub(@cloud_net.sha256_hex(name), 0, 12)
}

///|
/// paths.ts `relativeParts`.
pub fn relative_parts(p : Plat, path : String) -> Array[String]? {
  let rooted = match p {
    Unix => starts(path, "/")
    Windows(_) => win_rooted(path)
  }
  if path == "" || rooted {
    return None
  }
  let parts = segments(p, path)
  if parts.contains("..") {
    None
  } else {
    Some(parts)
  }
}

///|
/// paths.ts `platform.paths.relativeIn`.
pub fn relative_in(p : Plat, root : String, path : String) -> String? {
  match p {
    Unix => unix_relative_in(root, path)
    Windows(cwd) => win_relative_in(root, path, cwd)
  }
}

// ── version.ts ───────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// version.ts `stationVersion`: from the release's BUILD file's text (None where it did not read).
pub fn station_version(build : String?) -> String? {
  match build {
    Some(text) => {
      let b = js_trim(text)
      if b != "" && digits(b) {
        Some("0.1." + b)
      } else {
        None
      }
    }
    None => None
  }
}

///|
/// version.ts `stationBuiltAt`: from the release's BUILT_AT file's text (Unix ms; None where absent or invalid).
pub fn station_built_at(built_at : String?) -> Double? {
  match built_at {
    Some(text) => {
      let raw = js_trim(text)
      if raw != "" && digits(raw) {
        let parsed = try Some(@string.parse_int64(raw[:])) catch { _ => None }
        match parsed {
          Some(ms) if ms > 0L && ms <= 9007199254740991L => Some(ms.to_double())
          _ => None
        }
      } else {
        None
      }
    }
    None => None
  }
}

///|
/// version.ts `version`: the `--app` release's, else this code's, else 0.1.0.
pub fn version_of(args : Array[String], app_build : String?, own_build : String?) -> String {
  let at = args.search_by(a => a == "--app")
  let app = match at {
    Some(i) => args.get(i + 1)
    None => None
  }
  let given = match app {
    Some(a) if a != "" => station_version(app_build)
    _ => None
  }
  match given {
    Some(v) => v
    None => station_version(own_build).unwrap_or("0.1.0")
  }
}

///|
/// version.ts `builtAt`: the `--app` release's BUILT_AT, else this code's, else None.
pub fn built_at_of(args : Array[String], app_built_at : String?, own_built_at : String?) -> Double? {
  let at = args.search_by(a => a == "--app")
  let app = match at {
    Some(i) => args.get(i + 1)
    None => None
  }
  let given = match app {
    Some(a) if a != "" => station_built_at(app_built_at)
    _ => None
  }
  match given {
    Some(ms) => Some(ms)
    None => station_built_at(own_built_at)
  }
}

// ── own.ts ───────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// own.ts `Own`: what is the station's own on this machine.
pub struct Own {
  data : String
  config : String
  more_of : Array[() -> Array[String]]
}

///|
pub fn Own::new(data : String, config : String) -> Own {
  { data, config, more_of: [] }
}

///|
pub fn Own::add(self : Own, more : () -> Array[String]) -> Unit {
  self.more_of.push(more)
}

///|
pub fn Own::more(self : Own) -> Array[String] {
  let out = []
  for f in self.more_of {
    out.push_iter(f().iter())
  }
  out
}

///|
pub fn Own::paths(self : Own) -> Array[String] {
  [self.data, self.config, ..self.more()]
}

// ── unanswered.ts ────────────────────────────────────────────────────────────────────────────────────────────────

///|
let unreached : Array[String] = [
  "ECONNREFUSED", "ECONNRESET", "ECONNABORTED", "ENOTFOUND", "EAI_AGAIN", "ETIMEDOUT", "EHOSTUNREACH", "ENETUNREACH", "EPIPE",
]

///|
/// unanswered.ts `unanswered`, of an error as it is told: whether it is one, its name, whether a TypeError, its
/// message, its code.
pub fn unanswered(is_error : Bool, name : String, type_error : Bool, message : String, code : String) -> Bool {
  if !is_error {
    return false
  }
  name == "TimeoutError" || (type_error && message == "fetch failed") || unreached.contains(code)
}

// ── disk.ts ──────────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let disk_low_bytes : Double = 20.0 * 1073741824.0

///|
pub let disk_soft_bytes : Double = 30.0 * 1073741824.0

///|
pub let disk_every_ms : Double = 300000.0

///|
pub let disk_soft_every_ms : Double = 30000.0

///|
/// disk.ts `diskSoft`.
pub fn disk_soft(total : Double) -> Double {
  let t = total / 10.0
  if t > disk_soft_bytes {
    t
  } else {
    disk_soft_bytes
  }
}

///|
/// disk.ts `diskLow`: the low mark of a disk of `total` bytes, a tenth of it where that is less than disk_low_bytes.
pub fn disk_low(total : Double) -> Double {
  let t = total / 10.0
  if t < disk_low_bytes {
    t
  } else {
    disk_low_bytes
  }
}

///|
/// disk.ts `diskTier`.
pub fn disk_tier(free : Double, total : Double) -> String {
  if free < disk_low(total) {
    "low"
  } else if free < disk_soft(total) {
    "soft"
  } else {
    "ok"
  }
}

///|
/// disk.ts `diskEvery`.
pub fn disk_every(tier : String) -> Double {
  if tier == "ok" {
    disk_every_ms
  } else {
    disk_soft_every_ms
  }
}

// ── nice.ts ──────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// nice.ts `agentNice`: STILLFAIL_AGENT_NICE (0 to 19), else 10.
pub fn agent_nice(given : String?) -> Int {
  let asked = match given {
    Some(s) => js_number(s)
    None => @double.not_a_number
  }
  if is_integer(asked) && asked >= 0.0 && asked <= 19.0 {
    asked.to_int()
  } else {
    10
  }
}

// ── held.ts ──────────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let held_exit : Int = 3

///|
/// held.ts `heldBy`: of run/station.json's and run/hub.json's texts (None where one did not read), the pid of another
/// process running the station.
pub fn held_by(texts : Array[String?], self_pid : Double, alive : (Double) -> Bool) -> Double? {
  for t in texts {
    let pid = match t {
      Some(text) =>
        match js_parse(text) {
          Some(j) => num_field(j, "pid")
          None => None
        }
      None => None
    }
    match pid {
      Some(p) if is_safe_integer(p) && p > 0.0 && p != self_pid && alive(p) => return Some(p)
      _ => ()
    }
  }
  None
}

// ── waits.ts ─────────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let waited_ms : Double = 20.0

///|
/// waits.ts `Waits`.
pub struct Waits {
  mut ms : Double
  mut calls : Int
  mut longest : Double
  by : Array[(String, Double, Int)]
}

///|
pub fn no_waits() -> Waits {
  { ms: 0.0, calls: 0, longest: 0.0, by: [] }
}

///|
/// waits.ts `waited`.
pub fn waited(waits : Waits, ms : Double, who : () -> String) -> Unit {
  waits.ms += ms
  waits.calls += 1
  if ms > waits.longest || waits.longest.is_nan() {
    waits.longest = if ms.is_nan() { ms } else { @cmp.maximum(waits.longest, ms) }
  }
  if ms < waited_ms {
    return
  }
  let key = who()
  match waits.by.search_by(b => b.0 == key) {
    Some(k) => waits.by[k] = (key, waits.by[k].1 + ms, waits.by[k].2 + 1)
    None => waits.by.push((key, ms, 1))
  }
}

///|
pub fn Waits::to_json(self : Waits) -> Json {
  {
    "ms": jn(self.ms),
    "calls": ji(self.calls),
    "longest": jn(self.longest),
    "by": Json::array(self.by.map(b => Json::array([js(b.0), jn(b.1), ji(b.2)]))),
  }
}

///|
/// waits.ts `longestWaits`.
pub fn longest_waits(waits : Waits, most? : Int = 3) -> String {
  let sorted = stable_sort(waits.by, (a, b) => {
    let d = b.1 - a.1
    if d > 0.0 {
      1
    } else if d < 0.0 {
      -1
    } else {
      0
    }
  })
  sorted[0:@cmp.minimum(most, sorted.length())]
  .to_owned()
  .map(w => "\{w.0} \{num_text(js_round(w.1))}ms×\{w.2}")
  .join("; ")
}

///|
/// waits.ts `askedBy`: the first three functions a stack names, past the wrappers and the store's own helpers.
pub fn asked_by(stack : String?) -> String {
  let names = []
  let lines = split_on(stack.unwrap_or(""), "\n")
  for i in 1..<lines.length() {
    let line = lines[i]
    // `/^\s*at (?:async )?([^\s(]+) \(/`
    let mut k = spaces_from(line, 0)
    if !starts(sub(line, k, line.length()), "at ") {
      continue
    }
    k += 3
    if starts(sub(line, k, line.length()), "async ") {
      // `(?:async )?` is optional: where what follows is no name and ` (`, the name may be `async` itself.
      let after = name_paren(line, k + 6)
      match after {
        Some(n) => {
          if skip_name(n) {
            continue
          }
          names.push(n)
          if names.length() == 3 {
            break
          }
          continue
        }
        None => ()
      }
    }
    match name_paren(line, k) {
      Some(n) => {
        if skip_name(n) {
          continue
        }
        names.push(n)
        if names.length() == 3 {
          break
        }
      }
      None => ()
    }
  }
  names.join(" < ")
}

///|
/// `([^\s(]+) \(` from `k`: the name.
fn name_paren(line : String, k : Int) -> String? {
  let mut e = k
  while e < line.length() && !js_space(cu(line, e)) && cu(line, e) != 40 {
    e += 1
  }
  if e == k {
    return None
  }
  if e + 1 < line.length() && cu(line, e) == 32 && cu(line, e + 1) == 40 {
    Some(sub(line, k, e))
  } else {
    None
  }
}

///|
fn skip_name(name : String) -> Bool {
  let time_n = starts(name, "time") && all_units(sub(name, 4, name.length()), is_digit)
  time_n || has(name, "#") || has(name, "<anonymous>")
}

// ── group.ts ─────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// group.ts `stillOurs`: a group recorded at `started_at` is still that group, by when its leader started now (None:
/// not running), whether a group outlives its leader here, and whether any of it is there.
pub fn still_ours(started : Double?, started_at : Double, outlives : Bool, alive : Bool) -> Bool {
  let ours = match started {
    Some(s) => (s - started_at).abs() < 5000.0
    None => outlives && alive
  }
  ours && alive
}

///|
/// group.ts `endGroup`: how many times a group being ended is looked at (each LOOK_MS) before it is killed.
pub fn end_group_looks(grace_ms : Double) -> Int {
  let n = (grace_ms / 100.0).floor()
  if n > 1.0 {
    n.to_int()
  } else {
    1
  }
}
