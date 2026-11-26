// Bytes as text (C source is bytes: what Python's str did with surrogateescape), sets, a stable sort, SHA-1, CRC-32.

///|
fn is_ident(c : Byte) -> Bool {
  (c >= b'a' && c <= b'z') ||
  (c >= b'A' && c <= b'Z') ||
  (c >= b'0' && c <= b'9') ||
  c == b'_' ||
  c == b'$'
}

///|
/// What an identifier starts with: [A-Za-z_$]
fn is_start(c : Byte) -> Bool {
  (c >= b'a' && c <= b'z') || (c >= b'A' && c <= b'Z') || c == b'_' || c == b'$'
}

///|
fn is_digit(c : Byte) -> Bool {
  c >= b'0' && c <= b'9'
}

///|
/// A regular expression's \w (a byte past ASCII: a letter's, mostly)
fn is_word(c : Byte) -> Bool {
  (c >= b'a' && c <= b'z') ||
  (c >= b'A' && c <= b'Z') ||
  (c >= b'0' && c <= b'9') ||
  c == b'_' ||
  c >= b'\x80'
}

///|
/// \s, str.strip()'s whitespace
fn is_space(c : Byte) -> Bool {
  c == b' ' || (c >= b'\t' && c <= b'\r') || (c >= b'\x1c' && c <= b'\x1f')
}

///|
/// \b between t[i - 1] and t[i]
fn boundary(t : BytesView, i : Int) -> Bool {
  let a = i > 0 && is_word(t[i - 1])
  let b = i < t.length() && is_word(t[i])
  a != b
}

///|
fn imin(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn imax(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// Bytes in the order of their bytes (Python's str order for UTF-8), not Bytes::compare's (length first)
fn bcmp(a : BytesView, b : BytesView) -> Int {
  let n = imin(a.length(), b.length())
  for i in 0..<n {
    let x = a[i]
    let y = b[i]
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  a.length() - b.length()
}

///|
fn sub(t : Bytes, i : Int, j : Int) -> Bytes {
  t[i:j].to_owned()
}

///|
fn cat(parts : Array[Bytes]) -> Bytes {
  let mut n = 0
  for p in parts {
    n += p.length()
  }
  let buf = Buffer(capacity=n)
  for p in parts {
    buf.write_bytesview(p)
  }
  buf.to_bytes()
}

///|
/// The parts one after another, in a text made to their length at once (not grown, not copied again)
fn concat(parts : Array[BytesView]) -> Bytes {
  let mut n = 0
  for p in parts {
    n += p.length()
  }
  let out : FixedArray[Byte] = FixedArray::make(n, b'\x00')
  let mut w = 0
  for p in parts {
    out.blit_from_bytesview(w, p)
    w += p.length()
  }
  made_text(out)
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
fn starts(t : BytesView, s : Bytes) -> Bool {
  starts_at(t, 0, s)
}

///|
fn ends(t : BytesView, s : Bytes) -> Bool {
  starts_at(t, t.length() - s.length(), s)
}

///|
/// str.find(s, from)
fn find(t : BytesView, s : Bytes, from : Int) -> Int {
  let n = t.length()
  let m = s.length()
  if m == 0 {
    return if from <= n { from } else { -1 }
  }
  let i = imax(from, 0)
  if i + m > n {
    return -1
  }
  let base = t.start_offset()
  let r = c_find(t.data(), base + i, base + n, s)
  if r < 0 {
    -1
  } else {
    r - base
  }
}

///|
fn find_byte(t : BytesView, c : Byte, from : Int) -> Int {
  let i = imax(from, 0)
  if i >= t.length() {
    return -1
  }
  let base = t.start_offset()
  let r = c_find_byte(t.data(), base + i, base + t.length(), c.to_int())
  if r < 0 {
    -1
  } else {
    r - base
  }
}

///|
fn rfind_byte(t : BytesView, c : Byte) -> Int {
  let mut i = t.length() - 1
  while i >= 0 {
    if t[i] == c {
      return i
    }
    i -= 1
  }
  -1
}

///|
fn contains(t : BytesView, s : Bytes) -> Bool {
  find(t, s, 0) >= 0
}

///|
fn has_byte(t : BytesView, c : Byte) -> Bool {
  find_byte(t, c, 0) >= 0
}

///|
fn count(t : BytesView, s : Bytes) -> Int {
  let mut n = 0
  let mut i = 0
  while true {
    let k = find(t, s, i)
    if k < 0 {
      break
    }
    n += 1
    i = k + s.length()
  }
  n
}

///|
fn lskip(t : BytesView, i : Int) -> Int {
  let mut k = i
  while k < t.length() && is_space(t[k]) {
    k += 1
  }
  k
}

///|
fn rskip(t : BytesView, j : Int) -> Int {
  let mut k = j
  while k > 0 && is_space(t[k - 1]) {
    k -= 1
  }
  k
}

///|
fn strip(t : Bytes) -> Bytes {
  let a = lskip(t, 0)
  let b = rskip(t, t.length())
  if a >= b {
    b""
  } else {
    sub(t, a, b)
  }
}

///|
fn lstrip(t : Bytes) -> Bytes {
  sub(t, lskip(t, 0), t.length())
}

///|
fn rstrip(t : Bytes) -> Bytes {
  sub(t, 0, rskip(t, t.length()))
}

///|
/// Python's text[i:j] (a negative bound from the end, clamped)
fn pyslice(t : Bytes, i : Int, j : Int) -> Bytes {
  let n = t.length()
  let a = imin(n, imax(0, if i < 0 { n + i } else { i }))
  let b = imin(n, imax(0, if j < 0 { n + j } else { j }))
  if a >= b {
    b""
  } else {
    sub(t, a, b)
  }
}

///|
fn replace_all(t : Bytes, from : Bytes, to : Bytes) -> Bytes {
  if from.length() == 0 {
    return t
  }
  let buf = Buffer()
  let mut i = 0
  while true {
    let k = find(t, from, i)
    if k < 0 {
      break
    }
    buf.write_bytesview(t[i:k])
    buf.write_bytesview(to)
    i = k + from.length()
  }
  buf.write_bytesview(t[i:])
  buf.to_bytes()
}

///|
/// len() of the text Python decoded (characters: bytes that do not continue one)
fn clen(t : BytesView) -> Int {
  let base = t.start_offset()
  c_clen(t.data(), base, base + t.length())
}

///|
fn bint(n : Int) -> Bytes {
  utf8(n.to_string())
}

///|
/// FNV-1a of t[s:e] (io.c's mbc_hash)
fn hash_range(t : BytesView, s : Int, e : Int) -> Int {
  let base = t.start_offset()
  c_hash(t.data(), base + s, base + e)
}

///|
/// k[ks:ke] is t[s:e]
fn same_range(
  k : FixedArray[Byte],
  ks : Int,
  ke : Int,
  t : BytesView,
  s : Int,
  e : Int,
) -> Bool {
  ke - ks == e - s && c_same(k, ks, t.data(), t.start_offset() + s, e - s)
}

///|
/// A table keyed by byte strings, in the order keys came in, that a range of a text can be looked up in without
/// copying it (an identifier in a function's text: most are looked up, few added). A key is looked up in a copy of
/// all of them in one array (`bytes`), never as the object it is: reading an object counts a reference to it, a
/// write, and a job's process (run_jobs) that looked names up in its parent's tables made every page their keys were
/// on its own.
struct BTab[V] {
  keys : Array[Bytes]
  hashes : Array[Int] // each key's hash_range: never worked out again
  key_at : Array[Int] // where each key starts in `bytes`, and where the last ends
  mut bytes : FixedArray[Byte]
  vals : Array[V]
  mut slots : FixedArray[Int] // index + 1 into keys; 0 empty
}

///|
fn[V] BTab::new() -> BTab[V] {
  {
    keys: [],
    hashes: [],
    key_at: [0],
    bytes: FixedArray::make(0, b'\x00'),
    vals: [],
    slots: FixedArray::make(16, 0),
  }
}

///|
fn[V] BTab::find_range(self : BTab[V], t : BytesView, s : Int, e : Int) -> Int {
  self.find_hashed(t, s, e, hash_range(t, s, e))
}

///|
/// find_range with t[s:e]'s hash_range given (a scan's, worked out once for every table it looks the name up in)
fn[V] BTab::find_hashed(
  self : BTab[V],
  t : BytesView,
  s : Int,
  e : Int,
  h : Int,
) -> Int {
  let mask = self.slots.length() - 1
  let mut i = h & mask
  while true {
    let k = self.slots[i]
    if k == 0 {
      return -1
    }
    if self.hashes[k - 1] == h &&
      same_range(self.bytes, self.key_at[k - 1], self.key_at[k], t, s, e) {
      return k - 1
    }
    i = (i + 1) & mask
  }
  -1
}

///|
fn[V] BTab::find(self : BTab[V], k : BytesView) -> Int {
  self.find_range(k, 0, k.length())
}

///|
fn[V] BTab::grow(self : BTab[V]) -> Unit {
  let n = self.slots.length() * 2
  let slots = FixedArray::make(n, 0)
  let mask = n - 1
  for idx, h in self.hashes {
    let mut i = h & mask
    while slots[i] != 0 {
      i = (i + 1) & mask
    }
    slots[i] = idx + 1
  }
  self.slots = slots
}

///|
/// Adds k (as given: not copied) with v, or sets its value
fn[V] BTab::set(self : BTab[V], k : Bytes, v : V) -> Unit {
  let h = hash_range(k, 0, k.length())
  let at = self.find_hashed(k, 0, k.length(), h)
  if at >= 0 {
    self.vals[at] = v
    return
  }
  self.put_new(k, h, v)
}

///|
/// Adds k (not there: found not to be), its hash h, with v
fn[V] BTab::put_new(self : BTab[V], k : Bytes, h : Int, v : V) -> Unit {
  if (self.keys.length() + 1) * 2 > self.slots.length() {
    self.grow()
  }
  self.keys.push(k)
  self.hashes.push(h)
  let at = self.key_at[self.key_at.length() - 1]
  if at + k.length() > self.bytes.length() {
    let bytes = FixedArray::make(
      imax(self.bytes.length() * 2, at + k.length()),
      b'\x00',
    )
    self.bytes.blit_to(bytes, len=at)
    self.bytes = bytes
  }
  self.bytes.blit_from_bytes(at, k, 0, k.length())
  self.key_at.push(at + k.length())
  self.vals.push(v)
  let mask = self.slots.length() - 1
  let mut i = h & mask
  while self.slots[i] != 0 {
    i = (i + 1) & mask
  }
  self.slots[i] = self.keys.length()
}

///|
fn[V] BTab::length(self : BTab[V]) -> Int {
  self.keys.length()
}

///|
/// Lists of ints in one array, the i-th v[at[i]:at[i + 1]]: read with no object of their own each (as BTab's keys)
struct Csr {
  at : FixedArray[Int]
  v : FixedArray[Int]
}

///|
fn Csr::of(lists : Array[Array[Int]]) -> Csr {
  let at = FixedArray::make(lists.length() + 1, 0)
  let mut n = 0
  for i, l in lists {
    n += l.length()
    at[i + 1] = n
  }
  let v = FixedArray::make(n, 0)
  let mut w = 0
  for l in lists {
    for x in l {
      v[w] = x
      w += 1
    }
  }
  { at, v }
}

///|
/// A set of byte strings, in the order they came in
struct BSet {
  t : BTab[Unit]
}

///|
fn BSet::new() -> BSet {
  { t: BTab::new() }
}

///|
fn BSet::of(xs : Array[Bytes]) -> BSet {
  let s = BSet::new()
  for x in xs {
    s.add(x)
  }
  s
}

///|
fn BSet::add(self : BSet, x : Bytes) -> Unit {
  let h = hash_range(x, 0, x.length())
  if self.t.find_hashed(x, 0, x.length(), h) < 0 {
    self.t.put_new(x, h, ())
  }
}

///|
/// Adds t[s:e] (copied only when it is not there yet), its hash_range h given
fn BSet::add_hashed(self : BSet, t : BytesView, s : Int, e : Int, h : Int) -> Unit {
  if self.t.find_hashed(t, s, e, h) < 0 {
    self.t.put_new(t[s:e].to_owned(), h, ())
  }
}

///|
fn BSet::has(self : BSet, x : BytesView) -> Bool {
  self.t.find(x) >= 0
}

///|
fn BSet::size(self : BSet) -> Int {
  self.t.length()
}

///|
fn BSet::items(self : BSet) -> Array[Bytes] {
  self.t.keys.copy()
}

///|
fn BSet::add_all(self : BSet, o : BSet) -> Unit {
  for i, k in o.t.keys {
    let h = o.t.hashes[i]
    if self.t.find_hashed(k, 0, k.length(), h) < 0 {
      self.t.put_new(k, h, ())
    }
  }
}

///|
fn BSet::copy(self : BSet) -> BSet {
  let s = BSet::new()
  s.add_all(self)
  s
}

///|
fn BSet::minus(self : BSet, o : BSet) -> BSet {
  let s = BSet::new()
  for i, k in self.t.keys {
    let h = self.t.hashes[i]
    if o.t.find_hashed(k, 0, k.length(), h) < 0 {
      s.t.put_new(k, h, ())
    }
  }
  s
}

///|
fn BSet::inter(self : BSet, o : BSet) -> BSet {
  let s = BSet::new()
  for i, k in self.t.keys {
    let h = self.t.hashes[i]
    if o.t.find_hashed(k, 0, k.length(), h) >= 0 {
      s.t.put_new(k, h, ())
    }
  }
  s
}

///|
fn BSet::sorted(self : BSet) -> Array[Bytes] {
  sort_bytes(self.items())
}

///|
fn sort_bytes(a : Array[Bytes]) -> Array[Bytes] {
  stable_sort(a, fn(x, y) { bcmp(x, y) })
}

///|
/// Sorted as Python's sorted: stable
fn[T] stable_sort(a : Array[T], cmp : (T, T) -> Int) -> Array[T] {
  let n = a.length()
  let mut src = a.copy()
  let mut dst = a.copy()
  let mut width = 1
  while width < n {
    let mut lo = 0
    while lo < n {
      let mid = imin(lo + width, n)
      let hi = imin(lo + 2 * width, n)
      let mut i = lo
      let mut j = mid
      let mut k = lo
      while k < hi {
        if i < mid && (j >= hi || cmp(src[i], src[j]) <= 0) {
          dst[k] = src[i]
          i += 1
        } else {
          dst[k] = src[j]
          j += 1
        }
        k += 1
      }
      lo += 2 * width
    }
    let t = src
    src = dst
    dst = t
    width *= 2
  }
  src
}

///|
fn sorted_ints(a : Array[Int]) -> Array[Int] {
  stable_sort(a, fn(x, y) { x - y })
}

///|
/// The first `n` hex digits of `data`'s SHA-1
fn sha1_hex(data : BytesView, n : Int) -> Bytes {
  c_sha1(data.data(), data.start_offset(), data.length(), n)
}

///|
/// The first `n` hex digits of `a ++ b`'s SHA-1 without copying either slice
fn sha1_pair_hex(a : BytesView, b : BytesView, n : Int) -> Bytes {
  c_sha1_pair(
    a.data(),
    a.start_offset(),
    a.length(),
    b.data(),
    b.start_offset(),
    b.length(),
    n,
  )
}

///|
let crc_table : FixedArray[UInt] = {
  let t = FixedArray::make(256, 0U)
  for i in 0..<256 {
    let mut c = i.reinterpret_as_uint()
    for _ in 0..<8 {
      c = if (c & 1U) != 0U { 0xEDB88320U ^ (c >> 1) } else { c >> 1 }
    }
    t[i] = c
  }
  t
}

///|
/// zlib.crc32
fn crc32(data : BytesView) -> UInt {
  let mut c = 0xFFFFFFFFU
  for i in 0..<data.length() {
    c = crc_table[((c ^ data[i].to_uint()) & 0xFFU).reinterpret_as_int()] ^
      (c >> 8)
  }
  c ^ 0xFFFFFFFFU
}
