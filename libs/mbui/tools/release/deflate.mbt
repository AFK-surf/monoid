// Pure MoonBit RFC 1951 raw deflate compressor (LZ77 + Fixed Huffman, with stored-block fallback).

///|
let len_base : FixedArray[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67,
  83, 99, 115, 131, 163, 195, 227, 258,
]

///|
let len_extra : FixedArray[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5,
  5, 5, 0,
]

///|
let dist_base : FixedArray[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
let dist_extra : FixedArray[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11,
  11, 12, 12, 13, 13,
]

///|
priv struct BitWriter {
  out : Array[Byte]
  mut buf : Int
  mut nbits : Int
}

///|
fn BitWriter::new(cap : Int) -> BitWriter {
  { out: Array(capacity=cap), buf: 0, nbits: 0 }
}

///|
fn BitWriter::put_bits(self : BitWriter, val : Int, n : Int) -> Unit {
  self.buf = self.buf | (val << self.nbits)
  self.nbits += n
  while self.nbits >= 8 {
    self.out.push((self.buf & 0xFF).to_byte())
    self.buf = self.buf >> 8
    self.nbits -= 8
  }
}

///|
fn BitWriter::put_rev_bits(self : BitWriter, code : Int, n : Int) -> Unit {
  let mut r = 0
  for i in 0..<n {
    if ((code >> i) & 1) != 0 {
      r = r | (1 << (n - 1 - i))
    }
  }
  self.put_bits(r, n)
}

///|
fn BitWriter::finish(self : BitWriter) -> Bytes {
  if self.nbits > 0 {
    self.out.push((self.buf & 0xFF).to_byte())
    self.buf = 0
    self.nbits = 0
  }
  Bytes::makei(self.out.length(), fn(i) { self.out[i] })
}

///|
fn put_fixed_lit(bw : BitWriter, sym : Int) -> Unit {
  if sym <= 143 {
    bw.put_rev_bits(48 + sym, 8)
  } else if sym <= 255 {
    bw.put_rev_bits(400 + (sym - 144), 9)
  } else if sym <= 279 {
    bw.put_rev_bits(sym - 256, 7)
  } else {
    bw.put_rev_bits(192 + (sym - 280), 8)
  }
}

///|
fn put_fixed_match(bw : BitWriter, length : Int, dist : Int) -> Unit {
  let mut li = 28
  for i in 0..<28 {
    if length < len_base[i + 1] {
      li = i
      break
    }
  }
  put_fixed_lit(bw, 257 + li)
  if len_extra[li] > 0 {
    bw.put_bits(length - len_base[li], len_extra[li])
  }
  let mut di = 29
  for i in 0..<29 {
    if dist < dist_base[i + 1] {
      di = i
      break
    }
  }
  bw.put_rev_bits(di, 5)
  if dist_extra[di] > 0 {
    bw.put_bits(dist - dist_base[di], dist_extra[di])
  }
}

///|
fn deflate_stored(data : Bytes) -> Bytes {
  let n = data.length()
  if n == 0 {
    return Bytes::from_array([b'\x01', b'\x00', b'\x00', b'\xff', b'\xff'])
  }
  let out : Array[Byte] = Array(capacity=n + (n / 65535 + 1) * 5)
  let mut pos = 0
  while pos < n {
    let rem = n - pos
    let chunk = if rem > 65535 { 65535 } else { rem }
    let is_last = pos + chunk == n
    out.push(if is_last { b'\x01' } else { b'\x00' })
    out.push((chunk & 0xFF).to_byte())
    out.push(((chunk >> 8) & 0xFF).to_byte())
    let nlen = chunk ^ 0xFFFF
    out.push((nlen & 0xFF).to_byte())
    out.push(((nlen >> 8) & 0xFF).to_byte())
    for i in 0..<chunk {
      out.push(data[pos + i])
    }
    pos += chunk
  }
  Bytes::makei(out.length(), fn(i) { out[i] })
}

///|
fn hash3(data : Bytes, i : Int) -> Int {
  let a = data[i].to_uint()
  let b = data[i + 1].to_uint()
  let c = data[i + 2].to_uint()
  ((((a << 10) ^ (b << 5) ^ c) * 2654435761U) & 0x7FFFU).reinterpret_as_int()
}

///|
/// Compress `data` as an RFC 1951 raw deflate stream.
fn deflate_raw(data : Bytes) -> Bytes {
  let n = data.length()
  if n == 0 {
    return deflate_stored(data)
  }
  let bw = BitWriter::new(n / 2 + 16)
  // BFINAL=1, BTYPE=01 (fixed Huffman)
  bw.put_bits(3, 3)

  let head = FixedArray::make(32768, -1)
  let prev = FixedArray::make(32768, -1)
  let max_chain = 16
  let mut pos = 0
  while pos < n {
    let mut best_len = 0
    let mut best_dist = 0
    if pos + 3 <= n {
      let h = hash3(data, pos)
      let mut cand = head[h]
      prev[pos & 0x7FFF] = cand
      head[h] = pos
      let mut steps = 0
      let max_len = if n - pos > 258 { 258 } else { n - pos }
      while cand >= 0 && steps < max_chain {
        let dist = pos - cand
        if dist <= 0 || dist > 32768 {
          break
        }
        if data[cand] == data[pos] &&
          data[cand + 1] == data[pos + 1] &&
          data[cand + 2] == data[pos + 2] {
          let mut l = 3
          while l < max_len && data[cand + l] == data[pos + l] {
            l += 1
          }
          if l > best_len {
            best_len = l
            best_dist = dist
            if l == max_len {
              break
            }
          }
        }
        let next_cand = prev[cand & 0x7FFF]
        if next_cand >= cand {
          break
        }
        cand = next_cand
        steps += 1
      }
    }
    if best_len >= 3 {
      put_fixed_match(bw, best_len, best_dist)
      let end_insert = if pos + best_len < n - 2 {
        pos + best_len
      } else {
        n - 2
      }
      let mut k = pos + 1
      while k < end_insert {
        let h = hash3(data, k)
        prev[k & 0x7FFF] = head[h]
        head[h] = k
        k += 1
      }
      pos += best_len
    } else {
      put_fixed_lit(bw, data[pos].to_int())
      pos += 1
    }
  }
  put_fixed_lit(bw, 256)
  let packed = bw.finish()
  let stored_len = n + (n / 65535 + 1) * 5
  if packed.length() >= stored_len {
    deflate_stored(data)
  } else {
    packed
  }
}
