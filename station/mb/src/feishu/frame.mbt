// The frames of Feishu's long connection (station/src/feishu/frame.ts): protobuf's `pbbp2.Frame`, as Feishu's SDKs
// encode it, by hand, byte for byte as the TypeScript wrote and read them.
//
//   message Header { string key = 1; string value = 2; }
//   message Frame { uint64 SeqID = 1; uint64 LogID = 2; int32 service = 3; int32 method = 4; repeated Header headers = 5;
//                   string payload_encoding = 6; string payload_type = 7; bytes payload = 8; string LogIDNew = 9; }
//
// A varint is read as the TypeScript read it, into a BigInt of up to 77 bits (eleven bytes): `Big` keeps those, its
// low 64 what is written again.

///|
/// method: a control frame (ping, pong) or a data frame (an event, a callback).
pub let method_control : Int64 = 0L

///|
pub let method_data : Int64 = 1L

///|
/// A varint as read: its low 64 bits and the bits above them.
#derive(Eq, Debug)
pub(all) struct Big {
  hi : UInt64
  lo : UInt64
}

///|
pub fn Big::of(v : UInt64) -> Big {
  { hi: 0UL, lo: v }
}

///|
/// Its decimal digits (`String(bigint)`).
pub fn Big::to_decimal(self : Big) -> String {
  if self.hi == 0UL {
    return self.lo.to_string()
  }
  // (hi, lo) divided by ten again and again, by 32-bit limbs
  let limbs = [
    (self.hi >> 32).to_uint(),
    self.hi.to_uint(),
    (self.lo >> 32).to_uint(),
    self.lo.to_uint(),
  ]
  let digits = []
  while limbs.iter().any(l => l != 0U) {
    let mut rem = 0UL
    for i in 0..<limbs.length() {
      let cur = (rem << 32) | limbs[i].to_uint64()
      limbs[i] = (cur / 10UL).to_uint()
      rem = cur % 10UL
    }
    digits.push(rem.to_int())
  }
  let out = StringBuilder::new()
  for i = digits.length() - 1; i >= 0; i = i - 1 {
    out.write_char((digits[i] + '0').unsafe_to_char())
  }
  out.to_string()
}

///|
/// `Number(bigint)`: the nearest double, ties to even.
pub fn Big::to_double(self : Big) -> Double {
  if self.hi == 0UL {
    return self.lo.to_double()
  }
  let hi_bits = 64 - self.hi.clz()
  let length = 64 + hi_bits
  let shift = length - 53
  // q: the top 53 bits, rem: those below them
  let q = (self.hi << (64 - shift)) | (self.lo >> shift)
  let mask = (1UL << shift) - 1UL
  let rem = self.lo & mask
  let half = 1UL << (shift - 1)
  let mut top = q
  if rem > half || (rem == half && (q & 1UL) == 1UL) {
    top = top + 1UL
  }
  let mut d = top.to_double()
  for _ in 0..<shift {
    d = d * 2.0
  }
  d
}

///|
/// ToInt32 of a number (what `n >> 0`, `n & 7` take it as).
pub fn to_int32(d : Double) -> Int {
  if d.is_nan() || d.is_inf() {
    return 0
  }
  let t = if d < 0.0 { (-d).floor() * -1.0 } else { d.floor() }
  let two32 = 4294967296.0
  let mut m = t - (t / two32).floor() * two32
  if m < 0.0 {
    m = m + two32
  }
  if m >= 2147483648.0 {
    (m - two32).to_int()
  } else {
    m.to_int()
  }
}

///|
pub(all) struct Frame {
  seq_id : Big
  log_id : Big
  service : Int64
  meth : Int64
  headers : Array[(String, String)]
  payload_encoding : String?
  payload_type : String?
  payload : Bytes?
  log_id_new : String?
}

///|
/// A whole number as `BigInt.asUintN(64, BigInt(d))` keeps it, as an Int64's bits (what is past 64 bits let go).
pub fn wrap64(d : Double) -> Int64 {
  let m = 18446744073709551616.0
  let h = 9223372036854775808.0
  // (exact: the remainder of two doubles is, and so is each step below, both sides within a factor of two)
  let r = d % m
  if r >= h {
    (r - m).to_int64()
  } else if r < -h {
    (r + m).to_int64()
  } else {
    r.to_int64()
  }
}

///|
/// A header's value, or None.
pub fn header(f : Frame, key : String) -> String? {
  for h in f.headers {
    if h.0 == key {
      return Some(h.1)
    }
  }
  None
}

///|
priv struct Writer {
  parts : Array[Byte]
}

///|
fn Writer::varint(self : Writer, v : UInt64) -> Unit {
  let mut n = v
  while n >= 0x80UL {
    self.parts.push(((n & 0x7fUL) | 0x80UL).to_byte())
    n = n >> 7
  }
  self.parts.push(n.to_byte())
}

///|
fn Writer::tag(self : Writer, field : Int, wire : Int) -> Unit {
  self.varint(((field << 3) | wire).to_uint64())
}

///|
fn Writer::bytes(self : Writer, field : Int, b : BytesView) -> Unit {
  self.tag(field, 2)
  self.varint(b.length().to_uint64())
  for x in b {
    self.parts.push(x)
  }
}

///|
fn header_bytes(key : String, value : String) -> Bytes {
  let w : Writer = { parts: [] }
  w.bytes(1, utf8(key))
  w.bytes(2, utf8(value))
  Bytes::from_array(w.parts)
}

///|
pub fn encode(f : Frame) -> Bytes {
  let w : Writer = { parts: [] }
  w.tag(1, 0)
  w.varint(f.seq_id.lo)
  w.tag(2, 0)
  w.varint(f.log_id.lo)
  w.tag(3, 0)
  // int32: negative ones as ten bytes, as protobuf does.
  w.varint(f.service.reinterpret_as_uint64())
  w.tag(4, 0)
  w.varint(f.meth.reinterpret_as_uint64())
  for h in f.headers {
    w.bytes(5, header_bytes(h.0, h.1))
  }
  match f.payload_encoding {
    Some(s) => w.bytes(6, utf8(s))
    None => ()
  }
  match f.payload_type {
    Some(s) => w.bytes(7, utf8(s))
    None => ()
  }
  match f.payload {
    Some(p) => w.bytes(8, p)
    None => ()
  }
  match f.log_id_new {
    Some(s) => w.bytes(9, utf8(s))
    None => ()
  }
  Bytes::from_array(w.parts)
}

///|
priv struct Reader {
  mut at : Double
  b : BytesView
}

///|
fn Reader::more(self : Reader) -> Bool {
  self.at < self.b.length().to_double()
}

///|
fn Reader::varint(self : Reader) -> Big raise FeishuError {
  let mut shift = 0
  let mut hi = 0UL
  let mut lo = 0UL
  while true {
    if self.at >= self.b.length().to_double() {
      raise FeishuError("frame: cut short")
    }
    let x = self.b[self.at.to_int()].to_uint64()
    self.at += 1.0
    let bits = x & 0x7fUL
    if shift < 64 {
      lo = lo | (bits << shift)
      if shift > 57 {
        hi = hi | (bits >> (64 - shift))
      }
    } else {
      hi = hi | (bits << (shift - 64))
    }
    if (x & 0x80UL) == 0UL {
      return { hi, lo }
    }
    shift += 7
    if shift > 70 {
      raise FeishuError("frame: varint too long")
    }
  }
  { hi, lo }
}

///|
fn Reader::chunk(self : Reader) -> BytesView raise FeishuError {
  let n = self.varint().to_double()
  if self.at + n > self.b.length().to_double() {
    raise FeishuError("frame: cut short")
  }
  let from = self.at.to_int()
  let out = self.b[from:from + n.to_int()]
  self.at += n
  out
}

///|
fn Reader::skip(self : Reader, wire : Int) -> Unit raise FeishuError {
  if wire == 0 {
    ignore(self.varint())
  } else if wire == 2 {
    ignore(self.chunk())
  } else if wire == 1 {
    self.at += 8.0
  } else if wire == 5 {
    self.at += 4.0
  } else {
    raise FeishuError("frame: wire type \{wire}")
  }
}

///|
/// `Number(BigInt.asIntN(32, v))`.
fn int32_of(v : Big) -> Int64 {
  v.lo.to_uint().reinterpret_as_int().to_int64()
}

///|
/// TextDecoder's reading of a field (a leading byte order mark taken off).
fn field_text(b : BytesView) -> String {
  utf8_text(b, bom=true)
}

///|
pub fn decode(bytes : BytesView) -> Frame raise FeishuError {
  let r : Reader = { at: 0.0, b: bytes }
  let mut seq_id = Big::of(0UL)
  let mut log_id = Big::of(0UL)
  let mut service = 0L
  let mut meth = 0L
  let headers = []
  let mut payload_encoding = None
  let mut payload_type = None
  let mut payload = None
  let mut log_id_new = None
  while r.more() {
    let tag = to_int32(r.varint().to_double())
    let field = tag >> 3
    let wire = tag & 7
    if field == 1 && wire == 0 {
      seq_id = r.varint()
    } else if field == 2 && wire == 0 {
      log_id = r.varint()
    } else if field == 3 && wire == 0 {
      service = int32_of(r.varint())
    } else if field == 4 && wire == 0 {
      meth = int32_of(r.varint())
    } else if field == 5 && wire == 2 {
      let h : Reader = { at: 0.0, b: r.chunk() }
      let mut key = ""
      let mut value = ""
      while h.more() {
        let t = to_int32(h.varint().to_double())
        if t >> 3 == 1 && (t & 7) == 2 {
          key = field_text(h.chunk())
        } else if t >> 3 == 2 && (t & 7) == 2 {
          value = field_text(h.chunk())
        } else {
          h.skip(t & 7)
        }
      }
      headers.push((key, value))
    } else if field == 6 && wire == 2 {
      payload_encoding = Some(field_text(r.chunk()))
    } else if field == 7 && wire == 2 {
      payload_type = Some(field_text(r.chunk()))
    } else if field == 8 && wire == 2 {
      payload = Some(r.chunk().to_bytes())
    } else if field == 9 && wire == 2 {
      log_id_new = Some(field_text(r.chunk()))
    } else {
      r.skip(wire)
    }
  }
  {
    seq_id,
    log_id,
    service,
    meth,
    headers,
    payload_encoding,
    payload_type,
    payload,
    log_id_new,
  }
}

///|
priv struct Open {
  parts : Array[Bytes?]
  at : Int64
}

///|
/// Data frames too big for one come in parts (`sum` of them, numbered by `seq`, under one `message_id`): put together
/// once all are in. Parts of one never finished are dropped after a while (`drop`).
pub struct Parts {
  priv open : Map[String, Open]
}

///|
pub fn Parts::new() -> Parts {
  { open: Map([]) }
}

///|
/// How many are open (the tests').
pub fn Parts::open_count(self : Parts) -> Int {
  self.open.length()
}

///|
/// The whole payload once every part of its message is in, else None. A `sum` no array can be as long as is the
/// TypeScript's RangeError.
pub fn Parts::add(self : Parts, f : Frame, now : Int64) -> Bytes? raise FeishuError {
  let sum = js_number(header(f, "sum").unwrap_or("1"))
  let payload = f.payload.unwrap_or(b"")
  if !(sum > 1.0) {
    return Some(payload)
  }
  let id = header(f, "message_id").unwrap_or("")
  let seq = js_number(header(f, "seq").unwrap_or("0"))
  let entry = match self.open.get(id) {
    Some(e) => e
    None => {
      if sum != sum.floor() || sum >= 4294967296.0 {
        raise FeishuError("Invalid array length")
      }
      let e : Open = { parts: Array::make(sum.to_int(), None), at: now }
      self.open[id] = e
      e
    }
  }
  if seq >= 0.0 &&
    seq < entry.parts.length().to_double() &&
    seq == seq.floor() {
    entry.parts[seq.to_int()] = Some(payload)
  }
  if entry.parts.iter().any(p => p is None) {
    return None
  }
  self.open.remove(id)
  let out = []
  for p in entry.parts {
    for b in p.unwrap() {
      out.push(b)
    }
  }
  Some(Bytes::from_array(out))
}

///|
pub fn Parts::drop(self : Parts, before : Int64) -> Unit {
  let gone = []
  for id, e in self.open {
    if e.at < before {
      gone.push(id)
    }
  }
  for id in gone {
    self.open.remove(id)
  }
}
