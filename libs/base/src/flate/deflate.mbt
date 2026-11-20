// Raw deflate made (RFC 1951), on every target: LZ77 over a 32 KiB window kept across the pieces a stream is given
// in (a hash of three bytes, the longest of the last 128 matches), each piece one block of the fixed Huffman codes,
// or stored where that would be larger (bytes no match shortens). Its bytes are not zlib's: what either gives back
// inflated is the same. What a program on this library deflates with, zlib's and gzip's wrappings (gzip.mbt) among
// them, never a copy of its own.

///|
/// How far back a match may reach, and half the window held.
let wsize : Int = 32768

///|
/// The longest match.
let most_match : Int = 258

///|
/// How many places the hash of three bytes has.
let hash_size : Int = 32768

///|
/// How many earlier places of the same hash are tried at most.
let chain_most : Int = 128

///|
let length_base : FixedArray[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
]

///|
let length_extra : FixedArray[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
]

///|
let distance_base : FixedArray[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
  8193, 12289, 16385, 24577,
]

///|
let distance_extra : FixedArray[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
]

///|
/// A raw deflate stream made a piece at a time: `push` each piece, which gives what of the stream it makes (every
/// byte of it, so the stream inflates as far as it is given), then `finish`, which ends it. A match may reach back into
/// pieces given before, as far as 32 KiB.
pub struct Deflater {
  priv out : Buffer
  /// Bits not yet a whole byte: `n` of them, the first the lowest.
  priv mut acc : UInt
  priv mut n : Int
  /// The window: the last bytes given, `fill` of them; slid down by half as it fills.
  priv window : FixedArray[Byte]
  priv mut fill : Int
  /// The last place of each hash of three bytes, and of each place the one before it of the same hash (by its place
  /// modulo `wsize`); -1 for none.
  priv head : FixedArray[Int]
  priv prev : FixedArray[Int]
  /// The first place not yet hashed.
  priv mut hashed : Int
  priv mut finished : Bool
}

///|
pub fn Deflater::new() -> Deflater {
  {
    out: Buffer(),
    acc: 0U,
    n: 0,
    window: FixedArray::make(2 * wsize, b'\x00'),
    fill: 0,
    head: FixedArray::make(hash_size, -1),
    prev: FixedArray::make(wsize, -1),
    hashed: 0,
    finished: false,
  }
}

///|
/// `count` bits of `value`, the lowest first.
fn Deflater::put(self : Deflater, value : Int, count : Int) -> Unit {
  self.acc = self.acc | (value.reinterpret_as_uint() << self.n)
  self.n += count
  while self.n >= 8 {
    self.out.write_byte((self.acc & 0xFFU).to_byte())
    self.acc = self.acc >> 8
    self.n -= 8
  }
}

///|
/// A Huffman code of `count` bits, given as it is read (its first bit the highest).
fn Deflater::code(self : Deflater, code : Int, count : Int) -> Unit {
  let mut r = 0
  for i in 0..<count {
    r = (r << 1) | ((code >> i) & 1)
  }
  self.put(r, count)
}

///|
/// A literal or length symbol in the fixed code.
fn Deflater::symbol(self : Deflater, sym : Int) -> Unit {
  if sym < 144 {
    self.code(0x30 + sym, 8)
  } else if sym < 256 {
    self.code(0x190 + sym - 144, 9)
  } else if sym < 280 {
    self.code(sym - 256, 7)
  } else {
    self.code(0xC0 + sym - 280, 8)
  }
}

///|
/// The place of `length` in `length_base`.
fn length_index(length : Int) -> Int {
  let mut i = length_base.length() - 1
  while length_base[i] > length {
    i -= 1
  }
  i
}

///|
/// The place of `distance` in `distance_base`.
fn distance_index(distance : Int) -> Int {
  let mut i = distance_base.length() - 1
  while distance_base[i] > distance {
    i -= 1
  }
  i
}

///|
/// A match (`token` holds its length above 16 bits, its distance below) in the fixed codes.
fn Deflater::matched(self : Deflater, token : Int) -> Unit {
  let length = token >> 16
  let distance = token & 0xFFFF
  let li = length_index(length)
  self.symbol(257 + li)
  self.put(length - length_base[li], length_extra[li])
  let di = distance_index(distance)
  self.code(di, 5)
  self.put(distance - distance_base[di], distance_extra[di])
}

///|
/// How many bits `token` (a literal below 256, a match above) takes in the fixed codes.
fn fixed_bits(token : Int) -> Int {
  if token < 144 {
    8
  } else if token < 256 {
    9
  } else {
    let li = length_index(token >> 16)
    let di = distance_index(token & 0xFFFF)
    (if 257 + li < 280 { 7 } else { 8 }) + length_extra[li] + 5 + distance_extra[di]
  }
}

///|
/// The hash of the three bytes at `at` in the window.
fn Deflater::hash(self : Deflater, at : Int) -> Int {
  ((self.window[at].to_int() << 10) ^ (self.window[at + 1].to_int() << 5) ^ self.window[at + 2].to_int()) &
  (hash_size - 1)
}

///|
/// Every place before `upto` hashed that has three bytes after it.
fn Deflater::hash_upto(self : Deflater, upto : Int) -> Unit {
  while self.hashed < upto && self.hashed + 2 < self.fill {
    let h = self.hash(self.hashed)
    self.prev[self.hashed & (wsize - 1)] = self.head[h]
    self.head[h] = self.hashed
    self.hashed += 1
  }
}

///|
/// The window slid down by `wsize`: its upper half kept, places told anew, those gone forgotten.
fn Deflater::slide(self : Deflater) -> Unit {
  self.window.blit_to(self.window, len=wsize, src_offset=wsize, dst_offset=0)
  self.fill -= wsize
  self.hashed = if self.hashed > wsize { self.hashed - wsize } else { 0 }
  for i in 0..<hash_size {
    let p = self.head[i]
    self.head[i] = if p >= wsize { p - wsize } else { -1 }
  }
  for i in 0..<wsize {
    let p = self.prev[i]
    self.prev[i] = if p >= wsize { p - wsize } else { -1 }
  }
}

///|
/// The longest match at `at` (as a token), within `fill`; 0 where there is none of three bytes.
fn Deflater::longest(self : Deflater, at : Int) -> Int {
  if at + 2 >= self.fill {
    return 0
  }
  let w = self.window
  let most = if self.fill - at < most_match { self.fill - at } else { most_match }
  let mut best = 0
  let mut best_distance = 0
  let mut cand = self.head[self.hash(at)]
  let mut chain = chain_most
  while cand >= 0 && at - cand <= wsize && chain > 0 {
    let mut l = 0
    while l < most && w[cand + l] == w[at + l] {
      l += 1
    }
    if l > best {
      best = l
      best_distance = at - cand
      if l == most {
        break
      }
    }
    let next = self.prev[cand & (wsize - 1)]
    if next >= cand {
      break
    }
    cand = next
    chain -= 1
  }
  if best >= 3 {
    (best << 16) | best_distance
  } else {
    0
  }
}

///|
/// `data` as a block (the last where `last`), in the fixed codes or stored, whichever is shorter.
fn Deflater::block(self : Deflater, data : BytesView, last : Bool) -> Unit {
  let tokens : Array[Int] = []
  let mut bits = 3 + 7
  let mut taken = 0
  let mut at = self.fill
  while taken < data.length() || at < self.fill {
    if self.fill == self.window.length() {
      self.slide()
      at -= wsize
    }
    let room = self.window.length() - self.fill
    let k = if data.length() - taken < room { data.length() - taken } else { room }
    for i in 0..<k {
      self.window[self.fill + i] = data[taken + i]
    }
    self.fill += k
    taken += k
    // with more to come, a match is not cut at the window's end
    let upto = if taken < data.length() { self.fill - most_match } else { self.fill }
    while at < upto {
      self.hash_upto(at)
      let token = self.longest(at)
      let token = if token == 0 { self.window[at].to_int() } else { token }
      tokens.push(token)
      bits += fixed_bits(token)
      at += if token < 256 { 1 } else { token >> 16 }
    }
  }
  // stored: a head of 3 bits, at most 7 to the byte, and 4 bytes, for each 65535 bytes
  let pieces = (data.length() + 65534) / 65535
  let stored = pieces * (3 + 7 + 32) + 8 * data.length()
  if data.length() > 0 && stored < bits {
    for p in 0..<pieces {
      let from = p * 65535
      let len = if data.length() - from < 65535 { data.length() - from } else { 65535 }
      self.put(if last && p == pieces - 1 { 1 } else { 0 }, 1)
      self.put(0, 2)
      self.align()
      self.put(len, 16)
      self.put(len ^ 0xFFFF, 16)
      self.out.write_bytesview(data[from:from + len])
    }
  } else {
    self.put(if last { 1 } else { 0 }, 1)
    self.put(1, 2)
    for token in tokens {
      if token < 256 {
        self.symbol(token)
      } else {
        self.matched(token)
      }
    }
    self.symbol(256)
  }
}

///|
/// The bits written out to the next whole byte, zeros after them.
fn Deflater::align(self : Deflater) -> Unit {
  if self.n > 0 {
    self.out.write_byte((self.acc & 0xFFU).to_byte())
    self.acc = 0U
    self.n = 0
  }
}

///|
/// What was made so far, taken.
fn Deflater::take(self : Deflater) -> Bytes {
  let b = self.out.to_bytes()
  self.out.reset()
  b
}

///|
/// `data` deflated as a block of the stream; what of the stream is made by now. Nothing is made of nothing, and
/// nothing after `finish`.
pub fn Deflater::push(self : Deflater, data : BytesView) -> Bytes {
  if self.finished || data.length() == 0 {
    return b""
  }
  self.block(data, false)
  self.take()
}

///|
/// The stream ended (an empty last block) and what of it is left, to its last byte; nothing after the first.
pub fn Deflater::finish(self : Deflater) -> Bytes {
  if self.finished {
    return b""
  }
  self.finished = true
  self.block(b"", true)
  self.align()
  self.take()
}

///|
/// `data` deflated at once (raw: no zlib or gzip head), as one last block (stored, past 65535 bytes no match
/// shortens, in more).
pub fn deflate(data : BytesView) -> Bytes {
  let d = Deflater::new()
  d.finished = true
  d.block(data, true)
  d.align()
  d.take()
}
