// cprep: the reader's C as moonc wrote it, made ready for mbui's mbc (libs/ui/scripts/mbc compile) to split and
// compile it so that a change compiles again only the units it changed, and none of them for minutes.
//
//     cprep IN.c OUT.c
//
// - moonc numbers `struct moonbit_result_<N>` (what a function that raises or is async returns) across the whole
//   program, and mbc names moonc's function types by their definitions but leaves these as they are: one function
//   that raises new anywhere moved the numbers after it, and with them the name of every function type returning one
//   and the text of every unit naming either (435 of the reader's 582 units compiled again, 2026-11-17). Named here as
//   function types (`_M0TWresult$<N>`), mbc names them by their definitions too.
// - A function type's definition (theirs too) is written on one line, its spaces one: moonc broke its lines by the
//   length of the names in it, so two of one definition (moonbit_result_9 and moonbit_result_185) were two texts for
//   mbc, which keeps a definition once by its text (a struct defined twice), and where it broke a line was in every
//   unit that has it.
// - A function of HUGE_BYTES or more (a coroutine's state machine moonc made of one async function, a line a state)
//   is not optimised (CSPLIT_OPTNONE on its prototype, which its definition takes): -O2 took LLVM 131-158 s on one of
//   1 MB on CI's ci-1, past its job's 5 minutes, -O0 a sixteenth of that; and replica_coord's of 392-487 KB took tens
//   of seconds each for linux-x64 and win32-x64, so 200 KB (2026-11-17).
// - A `#line N "PATH"` directive names the source by its absolute path, which differs between checkouts and runners
//   (ci-1's actions-runner-<n>/_work/..., each one's moon in actions-runner-<n>/_tool/...): every unit's text was
//   another on each, and 389 of 415 units missed MBC_STORE (2026-11-17). PATH from its first of `/station/mb/`,
//   `/rules/`, `/libs/ui/` or `/lib/core/` on is kept, relative (`station/mb/src/reader/actors.mbt`).

///|
#borrow(path)
extern "C" fn c_read_file(path : Bytes) -> Bytes = "cprep_read_file"

///|
extern "C" fn c_read_ok() -> Int = "cprep_read_ok"

///|
#borrow(path, data)
extern "C" fn c_write_file(path : Bytes, data : Bytes) -> Int = "cprep_write_file"

///|
/// A function of this many bytes or more (as moonc wrote it) is compiled unoptimised.
const HUGE_BYTES : Int = 200 * 1024

///|
/// What the prelude says CSPLIT_OPTNONE is, by compiler.
let optnone_defs : String =
  #|#if defined(__clang__)
  #|#define CSPLIT_OPTNONE __attribute__((optnone))
  #|#elif defined(__GNUC__)
  #|#define CSPLIT_OPTNONE __attribute__((optimize("O0")))
  #|#else
  #|#define CSPLIT_OPTNONE
  #|#endif
  #|

///|
fn is_ident(c : Byte) -> Bool {
  (c >= b'a' && c <= b'z') ||
  (c >= b'A' && c <= b'Z') ||
  (c >= b'0' && c <= b'9') ||
  c == b'_' ||
  c == b'$'
}

///|
fn is_start(c : Byte) -> Bool {
  (c >= b'a' && c <= b'z') || (c >= b'A' && c <= b'Z') || c == b'_' || c == b'$'
}

///|
fn is_digit(c : Byte) -> Bool {
  c >= b'0' && c <= b'9'
}

///|
fn is_space(c : Byte) -> Bool {
  c == b' ' || c == b'\t' || c == b'\n' || c == b'\r' || c == b'\x0b' || c == b'\x0c'
}

///|
fn starts_at(t : BytesView, i : Int, s : Bytes) -> Bool {
  if i < 0 || i + s.length() > t.length() {
    return false
  }
  for k in 0..<s.length() {
    if t[i + k] != s[k] {
      return false
    }
  }
  true
}

///|
fn ident_end(t : BytesView, i : Int) -> Int {
  let mut k = i
  while k < t.length() && is_ident(t[k]) {
    k += 1
  }
  k
}

///|
/// Where what starts at i ends when it is a literal or a comment (a string, a character, // to its line's end, /* to
/// */), else -1.
fn skip_literal(t : BytesView, i : Int) -> Int {
  let n = t.length()
  let c = t[i]
  if c == b'"' || c == b'\'' {
    let mut k = i + 1
    while k < n && t[k] != c && t[k] != b'\n' {
      k += if t[k] == b'\\' { 2 } else { 1 }
    }
    return if k < n { k + 1 } else { n }
  }
  if c == b'/' && i + 1 < n && t[i + 1] == b'/' {
    let mut k = i + 2
    while k < n && t[k] != b'\n' {
      k += 1
    }
    return k
  }
  if c == b'/' && i + 1 < n && t[i + 1] == b'*' {
    let mut k = i + 2
    while k + 1 < n && !(t[k] == b'*' && t[k + 1] == b'/') {
      k += 1
    }
    return if k + 1 < n { k + 2 } else { n }
  }
  -1
}

///|
/// Where moonc's prelude ends: the first line that declares a struct of its own (`struct _M0…;`), as mbc finds it.
fn prelude_end(t : BytesView) -> Int {
  let n = t.length()
  let mut i = 0
  while i < n {
    let mut e = i
    while e < n && t[e] != b'\n' {
      e += 1
    }
    if starts_at(t, i, b"struct _M0") {
      let k = ident_end(t, i + 7)
      if k < e && t[k] == b';' {
        return i
      }
    }
    i = e + 1
  }
  n
}

///|
/// Where a `#line` directive's path names the source from a checkout or a moon on (`station/mb/...`, `rules/...`,
/// `libs/ui/...`, `lib/core/...`).
let line_roots : Array[Bytes] = [b"/station/mb/", b"/rules/", b"/libs/ui/", b"/lib/core/"]

///|
/// For a line starting at i that is a `#line N "PATH"` directive (spaces or tabs before it) whose PATH has one of
/// line_roots: where PATH starts, where its relative part starts, else (-1, -1).
fn line_path(t : BytesView, i : Int) -> (Int, Int) {
  let n = t.length()
  let mut k = i
  while k < n && (t[k] == b' ' || t[k] == b'\t') {
    k += 1
  }
  if !starts_at(t, k, b"#line ") {
    return (-1, -1)
  }
  k += 6
  let d = k
  while k < n && is_digit(t[k]) {
    k += 1
  }
  if k == d || k >= n || t[k] != b' ' {
    return (-1, -1)
  }
  while k < n && t[k] == b' ' {
    k += 1
  }
  if k >= n || t[k] != b'"' {
    return (-1, -1)
  }
  let start = k + 1
  let mut e = start
  while e < n && t[e] != b'"' && t[e] != b'\n' {
    e += 1
  }
  if e >= n || t[e] != b'"' {
    return (-1, -1)
  }
  // (the root found first in PATH: a package of the reader's named like one, src/rules, is in its path after it)
  let mut cut = -1
  for j in start..<e {
    for r in line_roots {
      if starts_at(t, j, r) && j + r.length() <= e {
        cut = j + 1
        break
      }
    }
    if cut >= 0 {
      break
    }
  }
  if cut < 0 {
    (-1, -1)
  } else {
    (start, cut)
  }
}

///|
/// `moonbit_result_<digits>`, a whole identifier outside literals and comments, as `_M0TWresult$<digits>`; and a
/// `#line` directive's path relative (line_path).
fn rename_results(t : BytesView) -> Bytes {
  let n = t.length()
  let buf = Buffer()
  let mut last = 0
  let mut i = 0
  while i < n {
    if i == 0 || t[i - 1] == b'\n' {
      let (start, cut) = line_path(t, i)
      if start >= 0 {
        buf.write_bytesview(t[last:start])
        last = cut
        while i < n && t[i] != b'\n' {
          i += 1
        }
        continue
      }
    }
    let c = t[i]
    if c == b'"' || c == b'\'' || c == b'/' {
      let e = skip_literal(t, i)
      if e >= 0 {
        i = e
        continue
      }
      i += 1
      continue
    }
    if is_start(c) {
      let e = ident_end(t, i)
      if e - i > 15 && starts_at(t, i, b"moonbit_result_") {
        let mut digits = true
        for k in (i + 15)..<e {
          if !is_digit(t[k]) {
            digits = false
            break
          }
        }
        if digits {
          buf.write_bytesview(t[last:i])
          buf.write_bytes(b"_M0TWresult$")
          buf.write_bytesview(t[i + 15:e])
          last = e
        }
      }
      i = e
      continue
    }
    if is_digit(c) {
      // (a number's letters are no identifier: 1e5, 0x1fU)
      i = ident_end(t, i)
      continue
    }
    i += 1
  }
  buf.write_bytesview(t[last:n])
  buf.to_bytes()
}

///|
/// A file-scope item of moonc's: [start, end), the first `{` at its top (-1: none), and its kind: 0 a directive,
/// 1 a function's definition, 2 anything ending in `;`.
priv struct Item {
  start : Int
  end : Int
  brace : Int
  kind : Int
}

///|
/// The items from `from` on, each from its first character that is not a space to its last.
fn items(t : BytesView, from : Int) -> Array[Item] {
  let n = t.length()
  let out = []
  let mut i = from
  while i < n {
    while i < n && is_space(t[i]) {
      i += 1
    }
    if i >= n {
      break
    }
    let start = i
    if t[i] == b'#' {
      // (a directive: to its line's end, a line ended by \ going on)
      while i < n && !(t[i] == b'\n' && t[i - 1] != b'\\') {
        i += 1
      }
      out.push({ start, end: i, brace: -1, kind: 0 })
      continue
    }
    let mut depth = 0
    let mut paren = 0
    let mut brace = -1
    let mut kind = -1
    while i < n {
      let c = t[i]
      if c == b'"' || c == b'\'' || c == b'/' {
        let e = skip_literal(t, i)
        if e >= 0 {
          i = e
          continue
        }
      } else if c == b'\n' && i + 1 < n && t[i + 1] == b'#' && depth > 0 {
        // (a directive in a body, #line: its quotes are not code)
        i += 1
        while i < n && t[i] != b'\n' {
          i += 1
        }
        continue
      } else if c == b'(' {
        paren += 1
      } else if c == b')' {
        paren -= 1
      } else if c == b'{' {
        if depth == 0 && paren == 0 && brace < 0 {
          brace = i
        }
        depth += 1
      } else if c == b'}' {
        depth -= 1
        if depth == 0 && paren == 0 && brace >= 0 {
          let mut h = brace
          while h > start && is_space(t[h - 1]) {
            h -= 1
          }
          if h > start && t[h - 1] == b')' {
            kind = 1
            i += 1
            break
          }
        }
      } else if c == b';' && depth == 0 && paren == 0 {
        kind = 2
        i += 1
        break
      }
      i += 1
    }
    out.push({ start, end: i, brace, kind: if kind < 0 { 2 } else { kind } })
  }
  out
}

///|
/// The name an item declares or defines as a function: the identifier before its first `(` (-1, -1: none).
fn fn_name(t : BytesView, it : Item) -> (Int, Int) {
  let stop = if it.brace >= 0 { it.brace } else { it.end }
  let mut k = it.start
  while k < stop && t[k] != b'(' && t[k] != b'=' && t[k] != b'{' {
    k += 1
  }
  if k >= stop || t[k] != b'(' {
    return (-1, -1)
  }
  let mut e = k
  while e > it.start && is_space(t[e - 1]) {
    e -= 1
  }
  let mut s = e
  while s > it.start && is_ident(t[s - 1]) {
    s -= 1
  }
  if s == e {
    (-1, -1)
  } else {
    (s, e)
  }
}

///|
/// Whether the item is a definition of a function type (`struct _M0TW… {`) with nothing in it a line holds alone.
fn fn_type_def(t : BytesView, it : Item) -> Bool {
  if it.kind != 2 || it.brace < 0 || !starts_at(t, it.start, b"struct _M0TW") {
    return false
  }
  let e = ident_end(t, it.start + 7)
  for k in e..<it.brace {
    if !is_space(t[k]) {
      return false
    }
  }
  for k in it.start..<(it.end - 1) {
    if t[k] == b'#' || (t[k] == b'/' && (t[k + 1] == b'/' || t[k + 1] == b'*')) {
      return false
    }
  }
  true
}

///|
fn write_collapsed(buf : Buffer, t : BytesView) -> Unit {
  let mut gap = false
  for c in t {
    if is_space(c) {
      gap = true
    } else {
      if gap {
        buf.write_byte(b' ')
      }
      gap = false
      buf.write_byte(c)
    }
  }
}

///|
/// A prototype, CSPLIT_OPTNONE said after its `static` (mbc takes `static` off where it leads)
fn write_optnone(buf : Buffer, t : BytesView) -> Unit {
  if starts_at(t, 0, b"static ") {
    buf.write_bytes(b"static CSPLIT_OPTNONE ")
    buf.write_bytesview(t[7:])
  } else {
    buf.write_bytes(b"CSPLIT_OPTNONE ")
    buf.write_bytesview(t)
  }
}

///|
/// moonc's C made ready for mbc (the head of this file), and the names of the functions left unoptimised.
fn prep(src : Bytes, huge? : Int = HUGE_BYTES) -> (Bytes, Array[String]) {
  let t = rename_results(src)
  let p = prelude_end(t)
  let all = items(t, p)
  // the functions left unoptimised, by name; those that have a prototype
  let huge_names : Map[Bytes, Unit] = Map([])
  let named : Array[String] = []
  for it in all {
    if it.kind == 1 && it.end - it.start >= huge {
      let (s, e) = fn_name(t, it)
      if s >= 0 {
        let name = t[s:e].to_owned()
        if name != b"main" && name != b"moonbit_init" && !huge_names.contains(name) {
          huge_names[name] = ()
          named.push(@utf8.decode_lossy(name))
        }
      }
    }
  }
  let proto_of : Map[Bytes, Unit] = Map([])
  for it in all {
    if it.kind == 2 && it.brace < 0 {
      let (s, e) = fn_name(t, it)
      if s >= 0 && huge_names.contains(t[s:e].to_owned()) {
        proto_of[t[s:e].to_owned()] = ()
      }
    }
  }
  let buf = Buffer()
  buf.write_bytesview(t[0:p])
  buf.write_bytes(@utf8.encode(optnone_defs))
  let mut last = p
  for it in all {
    if fn_type_def(t, it) {
      buf.write_bytesview(t[last:it.start])
      write_collapsed(buf, t[it.start:it.end])
      last = it.end
    } else if it.kind == 2 && it.brace < 0 {
      let (s, e) = fn_name(t, it)
      if s >= 0 && huge_names.contains(t[s:e].to_owned()) {
        buf.write_bytesview(t[last:it.start])
        write_optnone(buf, t[it.start:it.end])
        last = it.end
      }
    } else if it.kind == 1 && it.brace >= 0 {
      let (s, e) = fn_name(t, it)
      if s >= 0 &&
        huge_names.contains(t[s:e].to_owned()) &&
        !proto_of.contains(t[s:e].to_owned()) {
        // (none declared before it: its prototype, so said, before it)
        buf.write_bytesview(t[last:it.start])
        let mut h = it.brace
        while h > it.start && is_space(t[h - 1]) {
          h -= 1
        }
        write_optnone(buf, t[it.start:h])
        buf.write_bytes(b";\n\n")
        last = it.start
        proto_of[t[s:e].to_owned()] = ()
      }
    }
  }
  buf.write_bytesview(t[last:])
  (buf.to_bytes(), named)
}

///|
fn main {
  let args = @env.args()
  if args.length() != 3 {
    println("usage: cprep IN.c OUT.c")
    panic()
  }
  let src = c_read_file(@utf8.encode(args[1]))
  if c_read_ok() == 0 {
    println("cprep: cannot read \{args[1]}")
    panic()
  }
  let (out, named) = prep(src)
  if c_write_file(@utf8.encode(args[2]), out) == 0 {
    println("cprep: cannot write \{args[2]}")
    panic()
  }
  for n in named {
    println("cprep: \{n}: \{HUGE_BYTES / 1024} KB or more, not optimised")
  }
}
