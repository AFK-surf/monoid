// mbc carry: the app's largest Bytes literals moved out of the C that moonc generates, each into a file of its own the
// app carries. A store that sends only an app's changed files (the App Store) sends such a literal again with every
// release when it is in the program, though its bytes never change. moonc writes one as a static object, whose address
// a static global starts as:
//
//     static struct { int32_t rc; uint32_t meta; uint8_t const data[N]; } const moonbit_bytes_literal_K = { …, LEN, … };
//     static moonbit_bytes_t NAME = (moonbit_bytes_t)moonbit_bytes_literal_K.data;
//
// Both go, and each read of NAME asks the host for the file (mbui_carried, src/host/apple_carried.m), which is mapped
// as it is first read. A literal used in any other way stays as it was.

///|
/// A carried file's first bytes: the object's header (its count, its length), which the host writes as it maps it.
let carried_header = 8

///|
/// What a literal of `min` bytes or more is replaced by: (the C without it, its file's name and what is in it)
fn carry(src : Bytes, min : Int) -> (Bytes, Array[(Bytes, Bytes)]) {
  let files : Array[(Bytes, Bytes)] = []
  // (from, to, with)
  let cuts : Array[(Int, Int, Bytes)] = []
  let data = b"uint8_t const data["
  let mut at = find(src, data, 0)
  while at >= 0 {
    let next = at + data.length()
    let n = next + digits(src, next)
    if n > next && parse_int(src[next:n]) > min {
      match carried_one(src, at, n, min, files.length() == 0) {
        Some((name, bytes, c)) => {
          files.push((name, bytes))
          for x in c {
            cuts.push(x)
          }
        }
        None => ()
      }
    }
    at = find(src, data, next)
  }
  let sorted = stable_sort(cuts, fn(a, b) { a.0 - b.0 })
  let parts : Array[BytesView] = []
  let mut from = 0
  for c in sorted {
    parts.push(src[from:c.0])
    parts.push(c.2[:])
    from = c.1
  }
  parts.push(src[from:])
  (concat(parts), files)
}

///|
/// How many digits there are at i.
fn digits(t : BytesView, i : Int) -> Int {
  let mut j = i
  while j < t.length() && is_digit(t[j]) {
    j += 1
  }
  j - i
}

///|
/// Where the next `word` as a whole identifier is.
fn find_word(t : Bytes, word : Bytes, from : Int) -> Int {
  let mut p = find(t, word, from)
  while p >= 0 {
    let e = p + word.length()
    if (p == 0 || !is_ident(t[p - 1])) && (e >= t.length() || !is_ident(t[e])) {
      return p
    }
    p = find(t, word, e)
  }
  -1
}

///|
/// The literal whose `uint8_t const data[` is at `at` (its size's end at `n`): its file and what its C becomes; None
/// where it is not one literal one global starts as, which is only read.
fn carried_one(
  src : Bytes,
  at : Int,
  n : Int,
  min : Int,
  first : Bool,
) -> (Bytes, Bytes, Array[(Int, Int, Bytes)])? {
  let open = b"static struct { int32_t rc; uint32_t meta; "
  let start = at - open.length()
  guard start >= 0 && starts_at(src, start, open) else { return None }
  // `]; } const NAME = { KIND, LEN, bytes };`
  let is_const = b"} const "
  let p = find(src, is_const, n)
  guard p >= 0 && strip(sub(src, n, p)) == b"];" else { return None }
  let name_at = p + is_const.length()
  let name = sub(src, name_at, name_at + (ident_end(src, name_at) - name_at))
  guard starts(name, b"moonbit_bytes_literal_") else { return None }
  let body = find_byte(src, b'{', name_at)
  let end = find(src, b"};", name_at)
  guard body >= 0 && end > body else { return None }
  guard strip(sub(src, name_at + name.length(), body)) == b"=" else { return None }
  // (its first value, the count, is a macro's call)
  let kind = find(src, b"),", body)
  guard kind >= 0 && kind < end else { return None }
  let values : Array[Int] = []
  let mut i = kind + 2
  while i < end {
    let d = digits(src, i)
    if d > 0 {
      values.push(parse_int(src[i:i + d]))
      i += d
    } else {
      guard src[i] == b',' || is_space(src[i]) else { return None }
      i += 1
    }
  }
  // (moonc ends the bytes with a 0 of its own)
  guard values.length() > 1 else { return None }
  let len = values[0]
  guard len >= min && values.length() == len + 2 else { return None }
  // the one use: `static moonbit_bytes_t GLOBAL = (moonbit_bytes_t)NAME.data;`
  let use_at = find_word(src, name, end)
  guard use_at >= 0 && find_word(src, name, use_at + name.length()) < 0 else { return None }
  guard find_word(src, name, 0) == name_at else { return None }
  let after = b".data;"
  guard starts_at(src, use_at + name.length(), after) else { return None }
  let global_end = use_at + name.length() + after.length()
  let decl = b"static moonbit_bytes_t "
  let decl_at = rfind(src, decl, use_at)
  guard decl_at >= 0 else { return None }
  let global_at = decl_at + decl.length()
  let global = sub(src, global_at, ident_end(src, global_at))
  guard global.length() > 0 else { return None }
  let between = strip(sub(src, global_at + global.length(), use_at))
  guard starts(between, b"=") && strip(sub(between, 1, between.length())) == b"(moonbit_bytes_t)" else {
    return None
  }
  let bytes = Bytes::makei(carried_header + len + 1, fn(k) {
    if k < carried_header {
      b'\x00'
    } else {
      values[k - carried_header + 1].to_byte()
    }
  })
  let file = cat([sha1_hex(bytes, 16), b".bytes"])
  let call = cat([b"mbui_carried(\"", file, b"\", ", bint(len), b")"])
  let cuts : Array[(Int, Int, Bytes)] = [(start, end + 2, b"")]
  let proto : Bytes = if first { b"moonbit_bytes_t mbui_carried(char const* name, int32_t len);" } else { b"" }
  cuts.push((decl_at, global_end, proto))
  let mut q = find_word(src, global, 0)
  while q >= 0 {
    let e = q + global.length()
    if q != global_at {
      // (read alone: neither written nor its address taken; and after the host's function is declared)
      let r = lskip(src, e)
      let l = rskip(src, q)
      let written = r + 1 < src.length() && src[r] == b'=' && src[r + 1] != b'='
      guard q > global_end && !written && !(l > 0 && src[l - 1] == b'&') else { return None }
      cuts.push((q, e, call))
    }
    q = find_word(src, global, e)
  }
  Some((file, bytes, cuts))
}

///|
/// The last `s` that starts before `to`.
fn rfind(t : Bytes, s : Bytes, to : Int) -> Int {
  let mut i = to - s.length()
  while i >= 0 {
    if starts_at(t, i, s) {
      return i
    }
    i -= 1
  }
  -1
}

///|
/// mbc carry --min BYTES --out DIR FILE.c: DIR/FILE.c without the literals, DIR/files/<name>.bytes theirs; prints
/// DIR/FILE.c.
fn cmd_carry(args : Array[String]) -> Unit {
  let a = parse_args(args, ["--min", "--out"])
  let min = a.int("--min")
  guard min > 0 else {
    fatal("--min: a number of bytes")
    return
  }
  let dir = abspath(a.need("--out"))
  let path = a.src()
  let src = match read_file(path) {
    Some(s) => s
    None => {
      fatal("cannot read \{str(path)}")
      return
    }
  }
  let (c, files) = carry(src, min)
  let held = path_join(dir, b"files")
  rmtree(held)
  makedirs(held)
  for f in files {
    if !write_file(path_join(held, f.0), f.1) {
      fatal("cannot write \{str(f.0)}: \{write_error()}")
    }
  }
  let out = path_join(dir, basename(path))
  if read_file(out) != Some(c) && !write_file(out, c) {
    fatal("cannot write \{str(out)}: \{write_error()}")
  }
  for f in files {
    log("carried \{str(f.0)}: \{f.1.length()} bytes")
  }
  out_line(out)
}
