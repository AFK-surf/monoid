// Regular expressions as JavaScript reads the routes' (no `u` flag: a string is its UTF-16 code units), so that a
// route's pattern and its checks are written here as they are in station/src/api: literals and escapes (`\d`, `\w`,
// `\s` and their negations, `\/`), classes with ranges, groups (capturing, `(?:`, `(?=`, `(?!`), alternation,
// greedy and lazy quantifiers, `^` and `$`, and the `i` flag (ASCII). Matched by backtracking: a path or a field.

///|
priv enum ReNode {
  Unit(Int32)
  AnyUnit
  Klass(Array[(Int32, Int32)], Bool)
  Begin
  Finish
  Capture(ReNode, Int32)
  Plain(ReNode)
  Look(ReNode, Bool)
  Seq(Array[ReNode])
  Alt(Array[ReNode])
  Rep(ReNode, Int32, Int32, Bool)
}

///|
/// A pattern made once, matched as often as asked.
pub struct Re {
  priv node : ReNode
  priv groups : Int32
  priv fold : Bool
}

///|
priv struct ReParser {
  src : String
  mut at : Int32
  mut groups : Int32
}

///|
fn ReParser::peek(self : ReParser) -> Int32 {
  if self.at < self.src.length() {
    self.src.unsafe_charcode_at(self.at)
  } else {
    -1
  }
}

///|
fn ReParser::alt(self : ReParser) -> ReNode {
  let branches = [self.seq()]
  while self.peek() == '|' {
    self.at += 1
    branches.push(self.seq())
  }
  if branches.length() == 1 {
    branches[0]
  } else {
    Alt(branches)
  }
}

///|
fn ReParser::seq(self : ReParser) -> ReNode {
  let items : Array[ReNode] = []
  while self.peek() != -1 && self.peek() != '|' && self.peek() != ')' {
    let atom = self.atom()
    items.push(self.quantified(atom))
  }
  if items.length() == 1 {
    items[0]
  } else {
    Seq(items)
  }
}

///|
fn ReParser::number(self : ReParser) -> Int32? {
  let start = self.at
  let mut n = 0
  while self.peek() >= '0' && self.peek() <= '9' {
    n = n * 10 + (self.peek() - '0')
    self.at += 1
  }
  if self.at == start {
    None
  } else {
    Some(n)
  }
}

///|
fn ReParser::quantified(self : ReParser, atom : ReNode) -> ReNode {
  let (min, max) = match self.peek() {
    '*' => {
      self.at += 1
      (0, -1)
    }
    '+' => {
      self.at += 1
      (1, -1)
    }
    '?' => {
      self.at += 1
      (0, 1)
    }
    '{' => {
      let back = self.at
      self.at += 1
      match self.number() {
        Some(lo) =>
          if self.peek() == '}' {
            self.at += 1
            (lo, lo)
          } else if self.peek() == ',' {
            self.at += 1
            let hi = self.number()
            if self.peek() == '}' {
              self.at += 1
              (lo, hi.unwrap_or(-1))
            } else {
              self.at = back
              return atom
            }
          } else {
            self.at = back
            return atom
          }
        None => {
          self.at = back
          return atom
        }
      }
    }
    _ => return atom
  }
  let greedy = if self.peek() == '?' {
    self.at += 1
    false
  } else {
    true
  }
  Rep(atom, min, max, greedy)
}

///|
let digit_ranges : Array[(Int32, Int32)] = [('0', '9')]

///|
let word_ranges : Array[(Int32, Int32)] = [
  ('0', '9'),
  ('A', 'Z'),
  ('_', '_'),
  ('a', 'z'),
]

///|
/// JavaScript's `\s`: its white space and line terminators.
let space_ranges : Array[(Int32, Int32)] = [
  (0x09, 0x0d),
  (0x20, 0x20),
  (0xa0, 0xa0),
  (0x1680, 0x1680),
  (0x2000, 0x200a),
  (0x2028, 0x2029),
  (0x202f, 0x202f),
  (0x205f, 0x205f),
  (0x3000, 0x3000),
  (0xfeff, 0xfeff),
]

///|
fn negated(ranges : Array[(Int32, Int32)]) -> Array[(Int32, Int32)] {
  let sorted = ranges.copy()
  sorted.sort_by((a, b) => a.0 - b.0)
  let out = []
  let mut next = 0
  for r in sorted {
    if r.0 > next {
      out.push((next, r.0 - 1))
    }
    if r.1 + 1 > next {
      next = r.1 + 1
    }
  }
  if next <= 0xffff {
    out.push((next, 0xffff))
  }
  out
}

///|
fn escape_unit(c : Int32) -> Int32 {
  match c {
    'n' => 0x0a
    'r' => 0x0d
    't' => 0x09
    'f' => 0x0c
    'v' => 0x0b
    '0' => 0
    _ => c
  }
}

///|
/// An escape after its `\`: a class of units, or one unit.
fn ReParser::escape(self : ReParser) -> Result[Array[(Int32, Int32)], Int32] {
  let c = self.peek()
  self.at += 1
  match c {
    'd' => Ok(digit_ranges)
    'D' => Ok(negated(digit_ranges))
    'w' => Ok(word_ranges)
    'W' => Ok(negated(word_ranges))
    's' => Ok(space_ranges)
    'S' => Ok(negated(space_ranges))
    'x' => {
      let h = hex_value(self.src, self.at, 2)
      self.at += 2
      Err(h)
    }
    'u' => {
      let h = hex_value(self.src, self.at, 4)
      self.at += 4
      Err(h)
    }
    _ => Err(escape_unit(c))
  }
}

///|
fn hex_value(s : String, at : Int32, n : Int32) -> Int32 {
  let mut v = 0
  for i in 0..<n {
    v = v * 16 + @codec.hex_digit(s.unsafe_charcode_at(at + i)).unwrap_or(0)
  }
  v
}

///|
fn ReParser::klass(self : ReParser) -> ReNode {
  // after `[`
  let neg = if self.peek() == '^' {
    self.at += 1
    true
  } else {
    false
  }
  let ranges = []
  let mut first = true
  while self.peek() != -1 && (self.peek() != ']' || false) {
    if self.peek() == ']' && !first {
      break
    }
    first = false
    let lo = if self.peek() == '\\' {
      self.at += 1
      match self.escape() {
        Ok(rs) => {
          for r in rs {
            ranges.push(r)
          }
          continue
        }
        Err(u) => u
      }
    } else {
      let u = self.peek()
      self.at += 1
      u
    }
    if self.peek() == '-' &&
      self.at + 1 < self.src.length() &&
      self.src.unsafe_charcode_at(self.at + 1) != ']' {
      self.at += 1
      let hi = if self.peek() == '\\' {
        self.at += 1
        match self.escape() {
          Ok(_) => lo
          Err(u) => u
        }
      } else {
        let u = self.peek()
        self.at += 1
        u
      }
      ranges.push((lo, hi))
    } else {
      ranges.push((lo, lo))
    }
  }
  self.at += 1 // `]`
  Klass(ranges, neg)
}

///|
fn ReParser::atom(self : ReParser) -> ReNode {
  let c = self.peek()
  self.at += 1
  match c {
    '.' => AnyUnit
    '^' => Begin
    '$' => Finish
    '[' => self.klass()
    '(' =>
      if self.peek() == '?' {
        self.at += 1
        let kind = self.peek()
        self.at += 1
        let inner = self.alt()
        self.at += 1 // `)`
        match kind {
          '=' => Look(inner, false)
          '!' => Look(inner, true)
          _ => Plain(inner)
        }
      } else {
        self.groups += 1
        let n = self.groups
        let inner = self.alt()
        self.at += 1
        Capture(inner, n)
      }
    '\\' =>
      match self.escape() {
        Ok(rs) => Klass(rs, false)
        Err(u) => Unit(u)
      }
    _ => Unit(c)
  }
}

///|
/// `pattern` as JavaScript's `/pattern/` (`flags`: "i" or none).
pub fn re(pattern : String, flags~ : String = "") -> Re {
  let p : ReParser = { src: pattern, at: 0, groups: 0, }
  let node = p.alt()
  { node, groups: p.groups, fold: flags.contains("i"), }
}

///|
fn fold_unit(c : Int32) -> Int32 {
  if c >= 'A' && c <= 'Z' {
    c + 32
  } else {
    c
  }
}

///|
priv struct ReRun {
  re : Re
  s : String
  caps : Array[(Int32, Int32)]
}

///|
fn ReRun::unit_in(
  self : ReRun,
  c : Int32,
  ranges : Array[(Int32, Int32)],
) -> Bool {
  for r in ranges {
    if c >= r.0 && c <= r.1 {
      return true
    }
    if self.re.fold {
      let l = fold_unit(c)
      let u = if c >= 'a' && c <= 'z' { c - 32 } else { c }
      if (l >= r.0 && l <= r.1) || (u >= r.0 && u <= r.1) {
        return true
      }
    }
  }
  false
}

///|
fn ReRun::go(self : ReRun, n : ReNode, i : Int32, k : (Int32) -> Bool) -> Bool {
  let s = self.s
  match n {
    Unit(c) =>
      i < s.length() &&
      (
        s.unsafe_charcode_at(i) == c ||
        (self.re.fold && fold_unit(s.unsafe_charcode_at(i)) == fold_unit(c))
      ) &&
      k(i + 1)
    AnyUnit => {
      // JavaScript's `.`: any unit but a line terminator
      if i >= s.length() {
        return false
      }
      let c = s.unsafe_charcode_at(i)
      if c == 0x0a || c == 0x0d || c == 0x2028 || c == 0x2029 {
        return false
      }
      k(i + 1)
    }
    Klass(ranges, neg) =>
      i < s.length() &&
      self.unit_in(s.unsafe_charcode_at(i), ranges) != neg &&
      k(i + 1)
    Begin => i == 0 && k(i)
    Finish => i == s.length() && k(i)
    Capture(inner, g) => {
      let saved = self.caps[g]
      if self.go(inner, i, j => {
          let before = self.caps[g]
          self.caps[g] = (i, j)
          if k(j) {
            true
          } else {
            self.caps[g] = before
            false
          }
        }) {
        true
      } else {
        self.caps[g] = saved
        false
      }
    }
    Plain(inner) => self.go(inner, i, k)
    Look(inner, neg) => {
      let saved = self.caps.copy()
      let found = self.go(inner, i, _ => true)
      if neg {
        for g in 0..<saved.length() {
          self.caps[g] = saved[g]
        }
        !found && k(i)
      } else if found {
        k(i)
      } else {
        false
      }
    }
    Seq(items) => self.seq(items, 0, i, k)
    Alt(branches) => {
      for b in branches {
        if self.go(b, i, k) {
          return true
        }
      }
      false
    }
    Rep(inner, min, max, greedy) =>
      match unwrap_single(inner) {
        Some(atom) => self.rep_single(atom, min, max, greedy, i, k)
        None => self.rep(inner, min, max, greedy, 0, i, k)
      }
  }
}

///|
fn unwrap_single(n : ReNode) -> ReNode? {
  match n {
    Unit(_) | AnyUnit | Klass(_, _) => Some(n)
    Plain(inner) => unwrap_single(inner)
    _ => None
  }
}

///|
fn ReRun::match_single(self : ReRun, n : ReNode, i : Int32) -> Bool {
  let s = self.s
  if i >= s.length() {
    return false
  }
  let c = s.unsafe_charcode_at(i)
  match n {
    Unit(u) => c == u || (self.re.fold && fold_unit(c) == fold_unit(u))
    AnyUnit => c != 0x0a && c != 0x0d && c != 0x2028 && c != 0x2029
    Klass(ranges, neg) => self.unit_in(c, ranges) != neg
    _ => false
  }
}

///|
/// Iterative repetition for single-unit atoms (Unit, AnyUnit, Klass) so matching long strings (such as base64 icons)
/// runs in O(1) stack instead of recursing per character.
fn ReRun::rep_single(
  self : ReRun,
  atom : ReNode,
  min : Int32,
  max : Int32,
  greedy : Bool,
  i : Int32,
  k : (Int32) -> Bool,
) -> Bool {
  let mut matched = 0
  while (max < 0 || matched < max) && self.match_single(atom, i + matched) {
    matched += 1
  }
  if matched < min {
    return false
  }
  if greedy {
    let mut n = matched
    while n >= min {
      if k(i + n) {
        return true
      }
      n -= 1
    }
    false
  } else {
    let mut n = min
    while n <= matched {
      if k(i + n) {
        return true
      }
      n += 1
    }
    false
  }
}

///|
fn ReRun::seq(
  self : ReRun,
  items : Array[ReNode],
  at : Int32,
  i : Int32,
  k : (Int32) -> Bool,
) -> Bool {
  if at == items.length() {
    k(i)
  } else {
    self.go(items[at], i, j => self.seq(items, at + 1, j, k))
  }
}

///|
fn ReRun::rep(
  self : ReRun,
  inner : ReNode,
  min : Int32,
  max : Int32,
  greedy : Bool,
  count : Int32,
  i : Int32,
  k : (Int32) -> Bool,
) -> Bool {
  let more = () => {
    (max < 0 || count < max) &&
    self.go(inner, i, j => {
      (j != i || count < min) &&
      self.rep(inner, min, max, greedy, count + 1, j, k)
    })
  }
  if count < min {
    return more()
  }
  if greedy {
    more() || k(i)
  } else {
    k(i) || more()
  }
}

///|
/// Its first match in `s` (JavaScript's `exec`): the match and each group (None: it took no part).
pub fn Re::exec(self : Re, s : String) -> Array[String?]? {
  for start in 0..<=s.length() {
    let run : ReRun = {
      re: self,
      s,
      caps: Array::make(self.groups + 1, (-1, -1)),
    }
    let mut end = -1
    if run.go(self.node, start, j => {
        end = j
        true
      }) {
      let out : Array[String?] = [Some(s.unsafe_substring(start~, end~))]
      for g in 1..<=self.groups {
        let (a, b) = run.caps[g]
        out.push(
          if a < 0 {
            None
          } else {
            Some(s.unsafe_substring(start=a, end=b))
          },
        )
      }
      return Some(out)
    }
    // anchored at the start: no later start can match
    if self.node is (Seq([Begin, ..]) | Begin) {
      break
    }
  }
  None
}

///|
/// Whether it matches somewhere in `s` (JavaScript's `test`).
pub fn Re::matches(self : Re, s : String) -> Bool {
  self.exec(s) is Some(_)
}

///|
/// Every match's groups, in order (`matchAll`), and where each started and ended.
pub fn Re::all(self : Re, s : String) -> Array[(Int32, Int32, Array[String?])] {
  let out = []
  let mut start = 0
  while start <= s.length() {
    let run : ReRun = {
      re: self,
      s,
      caps: Array::make(self.groups + 1, (-1, -1)),
    }
    let mut end = -1
    if run.go(self.node, start, j => {
        end = j
        true
      }) {
      let groups : Array[String?] = [Some(s.unsafe_substring(start~, end~))]
      for g in 1..<=self.groups {
        let (a, b) = run.caps[g]
        groups.push(
          if a < 0 {
            None
          } else {
            Some(s.unsafe_substring(start=a, end=b))
          },
        )
      }
      out.push((start, end, groups))
      start = if end == start { end + 1 } else { end }
    } else {
      start += 1
    }
  }
  out
}

///|
/// `s.replace(/re/g, f)`.
pub fn Re::replace_all(
  self : Re,
  s : String,
  f : (Array[String?]) -> String,
) -> String {
  let out = StringBuilder::new()
  let mut at = 0
  for m in self.all(s) {
    let (a, b, groups) = m
    out.write_string(s.unsafe_substring(start=at, end=a))
    out.write_string(f(groups))
    at = b
  }
  out.write_string(s.unsafe_substring(start=at, end=s.length()))
  out.to_string()
}
