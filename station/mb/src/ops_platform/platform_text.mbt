// station/src/platform/text.ts, cpu-share.ts and index.ts `treeOf`: what a machine's commands and files say, read as
// host.rs read it (Rust's str methods), the same on every machine.

///|
/// Rust's char::is_whitespace.
fn rust_space(c : Int) -> Bool {
  (c >= 9 && c <= 13) ||
  c == 32 ||
  c == 0x85 ||
  c == 0xa0 ||
  c == 0x1680 ||
  (c >= 0x2000 && c <= 0x200a) ||
  c == 0x2028 ||
  c == 0x2029 ||
  c == 0x202f ||
  c == 0x205f ||
  c == 0x3000
}

///|
/// text.ts `trim`: Rust's str::trim.
pub fn rtrim(s : String) -> String {
  let mut i = 0
  let mut j = s.length()
  while i < j && rust_space(cu(s, i)) {
    i += 1
  }
  while j > i && rust_space(cu(s, j - 1)) {
    j -= 1
  }
  sub(s, i, j)
}

///|
/// text.ts `splitWords`.
pub fn split_words(s : String) -> Array[String] {
  split_runs(s, rust_space).filter(w => w != "")
}

///|
/// text.ts `firstWord`.
pub fn first_word(s : String) -> String {
  split_words(s).get(0).unwrap_or("")
}

///|
/// text.ts `parseU64`: digits, a `+` before them at most.
pub fn parse_u64(s : String) -> Double? {
  let t = if starts(s, "+") { sub(s, 1, s.length()) } else { s }
  if digits(t) {
    Some(js_number(s))
  } else {
    None
  }
}

///|
/// text.ts `parseF64`.
pub fn parse_f64(s : String) -> Double? {
  if decimal_literal(s) {
    Some(js_number(s))
  } else {
    None
  }
}

///|
/// text.ts `pressureOfAvailable`.
pub fn pressure_of_available(available : Double?, total : Double?) -> String? {
  guard available is Some(a) && total is Some(t) else { return None }
  if !(t > 0.0) || !(a >= 0.0) || a > t {
    return None
  }
  let share = a / t
  Some(if share < 0.04 { "critical" } else if share < 0.1 { "high" } else { "normal" })
}

///|
/// text.ts `pressureOfLevel`.
pub fn pressure_of_level(
  level : String,
  available? : Double? = None,
  total? : Double? = None,
) -> String? {
  match rtrim(level) {
    "1" => Some("normal")
    "2" =>
      match pressure_of_available(available, total) {
        Some(p) => Some(p)
        None => Some("high")
      }
    "4" => Some("critical")
    _ => None
  }
}

///|
/// text.ts `SWAPPING_PAGES_PER_SECOND`.
pub let swapping_pages_per_second : Double = 256.0

///|
/// text.ts `pressureOfSwap`: high while a quarter of the memory's size is swapped out and pages still go out,
/// critical at half.
pub fn pressure_of_swap(
  swap_used : Double?,
  total : Double?,
  out_per_second : Double?,
) -> String? {
  guard swap_used is Some(u) && total is Some(t) && out_per_second is Some(r) else {
    return None
  }
  if !(t > 0.0) || !(u >= 0.0) {
    return None
  }
  if r < swapping_pages_per_second {
    return Some("normal")
  }
  Some(if u >= t / 2.0 { "critical" } else if u >= t / 4.0 { "high" } else { "normal" })
}

///|
fn pressure_rank(p : String) -> Int {
  match p {
    "critical" => 2
    "high" => 1
    _ => 0
  }
}

///|
/// text.ts `worsePressure`.
pub fn worse_pressure(a : String?, b : String?) -> String? {
  match (a, b) {
    (None, _) => b
    (_, None) => a
    (Some(x), Some(y)) => if pressure_rank(x) >= pressure_rank(y) { a } else { b }
  }
}

///|
/// text.ts `swapoutsOf`: vm_stat's "Swapouts".
pub fn swapouts_of(vm : String) -> Double? {
  for line in split_lines(vm) {
    if starts(line, "Swapouts:") {
      let rest = rtrim(sub(line, 9, line.length()))
      let n = if ends(rest, ".") { sub(rest, 0, rest.length() - 1) } else { rest }
      return parse_u64(n)
    }
  }
  None
}

///|
/// text.ts `swapUsedOf`: `sysctl -n vm.swapusage`'s "used = <n>M", in bytes.
pub fn swap_used_of(text : String) -> Double? {
  let at = index_of(text, "used = ")
  guard at >= 0 else { return None }
  let rest = sub(text, at + 7, text.length())
  let m = index_of(rest, "M")
  guard m > 0 else { return None }
  match parse_f64(sub(rest, 0, m)) {
    Some(n) => Some(js_round(n * 1024.0 * 1024.0))
    None => None
  }
}

///|
pub(all) struct ProcessInfo {
  pid : Double
  ppid : Double
  pgid : Double
  mut bytes : Double
  command : String
}

///|
pub fn ProcessInfo::to_json(self : ProcessInfo) -> Json {
  { "pid": jn(self.pid), "ppid": jn(self.ppid), "pgid": jn(self.pgid), "bytes": jn(self.bytes), "command": js(self.command) }
}

///|
/// Digits from `i`: where they end.
fn digits_from(s : String, i : Int) -> Int {
  let mut k = i
  while k < s.length() && is_digit(cu(s, k)) {
    k += 1
  }
  k
}

///|
/// `\s*` from `i`: where it ends.
fn spaces_from(s : String, i : Int) -> Int {
  let mut k = i
  while k < s.length() && js_space(cu(s, k)) {
    k += 1
  }
  k
}

///|
/// text.ts `parsePs`: `/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s?(.*)$/` a line.
pub fn parse_ps(text : String) -> Array[ProcessInfo] {
  let out = []
  for line in split_on(text, "\n") {
    // `.` matches no line terminator: a line with one past the numbers does not match.
    let fields = []
    let mut i = spaces_from(line, 0)
    let mut ok = true
    for f in 0..<4 {
      let e = digits_from(line, i)
      if e == i {
        ok = false
        break
      }
      fields.push(sub(line, i, e))
      i = e
      if f < 3 {
        let s = spaces_from(line, i)
        if s == i {
          ok = false
          break
        }
        i = s
      }
    }
    if !ok {
      continue
    }
    // `\s?(.*)$`: one space at most, then what is left with no line terminator in it. Backtracking: where the rest
    // holds a terminator the line does not match, unless it is the one character `\s?` takes.
    let rest_with = sub(line, i, line.length())
    let term = (c : Int) => c == 10 || c == 13 || c == 0x2028 || c == 0x2029
    let rest = if rest_with != "" && js_space(cu(rest_with, 0)) && !any_unit(sub(rest_with, 1, rest_with.length()), term) {
      sub(rest_with, 1, rest_with.length())
    } else if !any_unit(rest_with, term) {
      rest_with
    } else {
      continue
    }
    // (a run of digits glued to the rest: `\d+` gives back to `\s?` nothing, and `(.*)` takes it as it is)
    out.push({
      pid: js_number(fields[0]),
      ppid: js_number(fields[1]),
      pgid: js_number(fields[2]),
      bytes: js_number(fields[3]) * 1024.0,
      command: rtrim(rest),
    })
  }
  out
}

///|
/// text.ts `parseTopMem`: `/^\s*(\d+)\s+([\d.]+)([BKMGT])[+-]?\s*$/` a line.
pub fn parse_top_mem(text : String) -> Array[(Double, Double)] {
  let out : Array[(Double, Double)] = []
  for line in split_on(text, "\n") {
    let mut i = spaces_from(line, 0)
    let e = digits_from(line, i)
    if e == i {
      continue
    }
    let pid = js_number(sub(line, i, e))
    i = spaces_from(line, e)
    if i == e {
      continue
    }
    let ns = i
    while i < line.length() && (is_digit(cu(line, i)) || cu(line, i) == 46) {
      i += 1
    }
    if i == ns || i >= line.length() {
      continue
    }
    let unit = match cu(line, i) {
      66 => 1.0
      75 => 1024.0
      77 => 1048576.0
      71 => 1073741824.0
      84 => 1099511627776.0
      _ => continue
    }
    let number = sub(line, ns, i)
    i += 1
    if i < line.length() && (cu(line, i) == 43 || cu(line, i) == 45) {
      i += 1
    }
    if spaces_from(line, i) != line.length() {
      continue
    }
    let bytes = js_round(js_number(number) * unit)
    match out.search_by(p => p.0 == pid) {
      Some(k) => out[k] = (pid, bytes)
      None => out.push((pid, bytes))
    }
  }
  out
}

///|
/// text.ts `fieldOrNull`.
pub fn field_or_null(text : String, label : String) -> Double? {
  for line in split_on(text, "\n") {
    if !starts(line, label + ":") {
      continue
    }
    let rest = rtrim(sub(line, label.length() + 1, line.length()))
    let mut j = rest.length()
    while j > 0 && cu(rest, j - 1) == 46 {
      j -= 1
    }
    return parse_u64(first_word(sub(rest, 0, j)))
  }
  None
}

///|
/// text.ts `procStatTicks`.
pub fn proc_stat_ticks(stat : String) -> (Double, Double)? {
  let line = split_on(stat, "\n").search_by(l => starts(l, "cpu ")).map(i => split_on(stat, "\n")[i])
  guard line is Some(line) else { return None }
  let words = split_words(line)
  let v = []
  for i in 1..<@cmp.minimum(9, words.length()) {
    match parse_u64(words[i]) {
      Some(n) => v.push(n)
      None => ()
    }
  }
  if v.length() < 4 {
    return None
  }
  let total = v.fold(init=0.0, (a, b) => a + b)
  let idle = v[3] + v.get(4).unwrap_or(0.0)
  Some((total - idle, total))
}

///|
/// text.ts `parseLsof`.
pub fn parse_lsof(text : String, port : Double) -> Array[String] {
  let found = []
  for line in split_on(text, "\n") {
    if !starts(line, "n") {
      continue
    }
    let name = js_trim(sub(line, 1, line.length()))
    let at = last_index_of(name, ":")
    if at < 0 || js_number(sub(name, at + 1, name.length())) != port {
      continue
    }
    let mut address = sub(name, 0, at)
    if starts(address, "[") {
      address = sub(address, 1, address.length())
    }
    if ends(address, "]") {
      address = sub(address, 0, address.length() - 1)
    }
    if !found.contains(address) {
      found.push(address)
    }
  }
  found
}

///|
/// text.ts `idleOfIoreg`: `/"HIDIdleTime"\s*=\s*([0-9]+)/`.
pub fn idle_of_ioreg(text : String) -> Double? {
  let key = "\"HIDIdleTime\""
  let mut from = 0
  while true {
    let at = index_of(text, key, from~)
    if at < 0 {
      return None
    }
    let mut i = spaces_from(text, at + key.length())
    if i < text.length() && cu(text, i) == 61 {
      i = spaces_from(text, i + 1)
      let e = digits_from(text, i)
      if e > i {
        return Some(js_number(sub(text, i, e)) / 1.0e6)
      }
    }
    from = at + 1
  }
  None
}

///|
/// text.ts `parseMounts`: `/ on (\/.*?) \([^()]*\)$/` a line.
pub fn parse_mounts(out : String) -> Array[String] {
  let found = []
  for line in split_on(out, "\n") {
    let mut at : String? = None
    let mut from = 0
    // The first ` on /` from which a lazy `.*?` reaches ` (…)` at the line's end with no paren inside.
    while at is None {
      let i = index_of(line, " on /", from~)
      if i < 0 {
        break
      }
      let start = i + 4
      let mut k = start
      while k < line.length() {
        if cu(line, k) == 32 && k + 1 < line.length() && cu(line, k + 1) == 40 {
          let rest = sub(line, k + 2, line.length())
          if ends(rest, ")") && !has(sub(rest, 0, rest.length() - 1), "(") && !has(sub(rest, 0, rest.length() - 1), ")") {
            at = Some(sub(line, start, k))
            break
          }
        }
        // `.` matches no line terminator.
        let c = cu(line, k)
        if c == 13 || c == 0x2028 || c == 0x2029 {
          break
        }
        k += 1
      }
      from = i + 1
    }
    guard at is Some(at) else { continue }
    if at == "/" || at == "/dev" || starts(at, "/System/Volumes/") {
      continue
    }
    found.push(at)
  }
  found
}

///|
/// cpu-share.ts `cpuShare`.
pub fn cpu_share(a : (Double, Double), b : (Double, Double)) -> Double? {
  let (b0, t0) = a
  let (b1, t1) = b
  if t1 > t0 {
    let d = b1 - b0
    let busy = if d > 0.0 { d } else { 0.0 }
    let s = busy / (t1 - t0)
    Some(if s < 0.0 { 0.0 } else if s > 1.0 { 1.0 } else { s })
  } else {
    None
  }
}

///|
/// index.ts `treeOf`: the children of each pid, in the table's order.
pub fn tree_of(table : Array[ProcessInfo]) -> Array[(Double, Array[Double])] {
  let children : Array[(Double, Array[Double])] = []
  for p in table {
    if p.pid != p.ppid {
      match children.search_by(c => c.0 == p.ppid) {
        Some(k) => children[k].1.push(p.pid)
        None => children.push((p.ppid, [p.pid]))
      }
    }
  }
  children
}
