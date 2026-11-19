// gzip (RFC 1952) of a deflate stream (RFC 1951): one block of fixed Huffman codes over what LZ77 finds (a hash of
// three bytes, the longest of the last few matches in a 32 KiB window). What Node's zlib.gzip makes of the same bytes
// is other bytes; what either gives back unpacked is the same (station/src/feishu/register.ts `encodeAddons`: the
// registration's link carries the app's addons so, and Feishu unpacks them).

///|
priv struct Bits {
  out : Array[Byte]
  mut acc : UInt
  mut n : Int
}

///|
fn Bits::put(self : Bits, value : UInt, count : Int) -> Unit {
  self.acc = self.acc | (value << self.n)
  self.n += count
  while self.n >= 8 {
    self.out.push((self.acc & 0xffU).to_byte())
    self.acc = self.acc >> 8
    self.n -= 8
  }
}

///|
/// A Huffman code, its bits reversed (deflate writes them first bit first).
fn Bits::code(self : Bits, code : Int, count : Int) -> Unit {
  let mut r = 0
  for i in 0..<count {
    r = (r << 1) | ((code >> i) & 1)
  }
  self.put(r.reinterpret_as_uint(), count)
}

///|
fn Bits::flush(self : Bits) -> Unit {
  if self.n > 0 {
    self.out.push((self.acc & 0xffU).to_byte())
    self.acc = 0U
    self.n = 0
  }
}

///|
/// A literal or length symbol's fixed code.
fn Bits::symbol(self : Bits, sym : Int) -> Unit {
  if sym < 144 {
    self.code(0x30 + sym, 8)
  } else if sym < 256 {
    self.code(0x190 + sym - 144, 9)
  } else if sym < 280 {
    self.code(sym - 256, 7)
  } else {
    self.code(0xc0 + sym - 280, 8)
  }
}

///|
let length_base : Array[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
let length_extra : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
let dist_base : Array[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025,
  1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
let dist_extra : Array[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
fn Bits::matched(self : Bits, length : Int, dist : Int) -> Unit {
  let mut li = length_base.length() - 1
  while length_base[li] > length {
    li -= 1
  }
  self.symbol(257 + li)
  self.put((length - length_base[li]).reinterpret_as_uint(), length_extra[li])
  let mut di = dist_base.length() - 1
  while dist_base[di] > dist {
    di -= 1
  }
  self.code(di, 5)
  self.put((dist - dist_base[di]).reinterpret_as_uint(), dist_extra[di])
}

///|
/// `data` deflated: one final block of fixed codes.
pub fn deflate(data : BytesView) -> Bytes {
  let b : Bits = { out: [], acc: 0U, n: 0 }
  b.put(1U, 1) // BFINAL
  b.put(1U, 2) // BTYPE 01: fixed codes
  let n = data.length()
  let window = 32768
  let head : Map[Int, Int] = Map([])
  let prev = Array::make(n, -1)
  let key = (i : Int) => (data[i].to_int() << 16) |
    (data[i + 1].to_int() << 8) |
    data[i + 2].to_int()
  let mut i = 0
  while i < n {
    let mut best_len = 0
    let mut best_dist = 0
    if i + 2 < n {
      let k = key(i)
      let mut cand = head.get(k).unwrap_or(-1)
      let mut tries = 64
      while cand >= 0 && i - cand <= window && tries > 0 {
        let mut l = 0
        while l < 258 && i + l < n && data[cand + l] == data[i + l] {
          l += 1
        }
        if l > best_len {
          best_len = l
          best_dist = i - cand
        }
        cand = prev[cand]
        tries -= 1
      }
    }
    let step = if best_len >= 3 {
      b.matched(best_len, best_dist)
      best_len
    } else {
      b.symbol(data[i].to_int())
      1
    }
    for j in i..<(i + step) {
      if j + 2 < n {
        let k = key(j)
        prev[j] = head.get(k).unwrap_or(-1)
        head[k] = j
      }
    }
    i += step
  }
  b.symbol(256)
  b.flush()
  Bytes::from_array(b.out)
}

///|
/// `data` gzipped: no name, no time, made on Unix.
pub fn gzip(data : BytesView) -> Bytes {
  let out : Array[Byte] = [
    b'\x1f', b'\x8b', b'\x08', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x03',
  ]
  for x in deflate(data) {
    out.push(x)
  }
  let crc = @codec.crc32(data)
  let size = data.length().reinterpret_as_uint()
  for v in [crc, size] {
    for s in [0, 8, 16, 24] {
      out.push(((v >> s) & 0xffU).to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
/// Base64url without padding (`Buffer.toString("base64url")`).
pub fn base64url(b : BytesView) -> String {
  @codec.base64url_encode(b)
}

///|
/// Base64 with padding (`Buffer.toString("base64")`).
pub fn base64(b : BytesView) -> String {
  @codec.base64_encode(b)
}
