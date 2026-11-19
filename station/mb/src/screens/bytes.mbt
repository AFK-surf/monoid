// Bytes as Node's Buffer reads and writes them, big-endian.

///|
fn u32be(b : BytesView, at : Int) -> Int64 {
  (b[at].to_int64() << 24) |
  (b[at + 1].to_int64() << 16) |
  (b[at + 2].to_int64() << 8) |
  b[at + 3].to_int64()
}

///|
fn u24be(b : BytesView, at : Int) -> Int {
  (b[at].to_int() << 16) | (b[at + 1].to_int() << 8) | b[at + 2].to_int()
}

///|
/// `readBigUInt64BE` as a double (`Number(…)`).
fn u64be(b : BytesView, at : Int) -> UInt64 {
  let mut v = 0UL
  for i in 0..<8 {
    v = (v << 8) | b[at + i].to_uint64()
  }
  v
}

///|
fn put_u32be(out : FixedArray[Byte], at : Int, v : Int64) -> Unit {
  out[at] = ((v >> 24) & 0xffL).to_byte()
  out[at + 1] = ((v >> 16) & 0xffL).to_byte()
  out[at + 2] = ((v >> 8) & 0xffL).to_byte()
  out[at + 3] = (v & 0xffL).to_byte()
}

///|
fn put_u16be(out : FixedArray[Byte], at : Int, v : Int) -> Unit {
  out[at] = ((v >> 8) & 0xff).to_byte()
  out[at + 1] = (v & 0xff).to_byte()
}

///|
/// `writeInt32BE`: a signed value's two's complement.
fn put_i32be(out : FixedArray[Byte], at : Int, v : Int) -> Unit {
  put_u32be(out, at, v.to_int64() & 0xffffffffL)
}

///|
fn put_i64be(out : FixedArray[Byte], at : Int, v : Int64) -> Unit {
  for i in 0..<8 {
    out[at + i] = ((v >> (56 - 8 * i)) & 0xffL).to_byte()
  }
}


///|
fn concat(parts : Array[BytesView]) -> Bytes {
  let buf = Buffer()
  for p in parts {
    buf.write_bytesview(p)
  }
  buf.to_bytes()
}

///|
/// `buf.indexOf(needle, from)`.
fn index_of(b : BytesView, needle : BytesView, from? : Int = 0) -> Int {
  let n = b.length()
  let m = needle.length()
  if m == 0 {
    return if from <= n { from } else { n }
  }
  for i = from; i + m <= n; i = i + 1 {
    let mut all = true
    for j in 0..<m {
      if b[i + j] != needle[j] {
        all = false
        break
      }
    }
    if all {
      return i
    }
  }
  -1
}

///|
fn index_of_byte(b : BytesView, v : Byte, from? : Int = 0) -> Int {
  for i = from; i < b.length(); i = i + 1 {
    if b[i] == v {
      return i
    }
  }
  -1
}

///|
fn hex_of(b : BytesView) -> String {
  @codec.hex_encode(b)
}

///|
/// A string's Latin-1 bytes (`toString("latin1")`'s other way), each unit's low byte.
fn latin1_bytes(s : String) -> Bytes {
  let u = @jsjson.units(s)
  let out = FixedArray::make(u.length(), b'\x00')
  for i, c in u {
    out[i] = (c & 0xff).to_byte()
  }
  Bytes::from_array(out)
}

///|
/// `buf.toString("latin1")`.
fn latin1_text(b : BytesView) -> String {
  let out = StringBuilder()
  for x in b {
    out.write_char(Int::unsafe_to_char(x.to_int()))
  }
  out.to_string()
}

///|
fn b64(b : BytesView) -> String {
  @base64.encode(b)
}

///|
/// What came of a stream and is not taken yet, kept as the pieces it came in: its head looked at without joining
/// them, a whole message joined once (a frame of megabytes in many pieces is not joined again at each).
struct Carry {
  pieces : Array[Bytes]
  mut length : Int
  /// How much of the first piece is taken already.
  mut at : Int
}

///|
fn Carry::new() -> Carry {
  { pieces: [], length: 0, at: 0 }
}

///|
fn Carry::push(self : Carry, b : Bytes) -> Unit {
  if b.length() > 0 {
    self.pieces.push(b)
    self.length += b.length()
  }
}

///|
/// The byte at `i` of what is kept.
fn Carry::byte_at(self : Carry, i : Int) -> Byte {
  let mut k = i + self.at
  for p in self.pieces {
    if k < p.length() {
      return p[k]
    }
    k -= p.length()
  }
  b'\x00'
}

///|
/// The first `n` bytes kept, taken (there are at least `n`).
fn Carry::take(self : Carry, n : Int) -> Bytes {
  let out = FixedArray::make(n, b'\x00')
  let mut done = 0
  while done < n {
    let p = self.pieces[0]
    let can = p.length() - self.at
    let want = n - done
    let k = if can < want { can } else { want }
    for j in 0..<k {
      out[done + j] = p[self.at + j]
    }
    done += k
    if k == can {
      ignore(self.pieces.remove(0))
      self.at = 0
    } else {
      self.at += k
    }
  }
  self.length -= n
  Bytes::from_array(out)
}

///|
fn Carry::clear(self : Carry) -> Unit {
  self.pieces.clear()
  self.length = 0
  self.at = 0
}

///|
/// A big-endian 4-byte value at `i` of what is kept.
fn Carry::u32_at(self : Carry, i : Int) -> Int64 {
  (self.byte_at(i).to_int64() << 24) |
  (self.byte_at(i + 1).to_int64() << 16) |
  (self.byte_at(i + 2).to_int64() << 8) |
  self.byte_at(i + 3).to_int64()
}
