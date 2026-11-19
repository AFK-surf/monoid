// What a command run with a secret in its environment says, with the secret hidden (station/src/vault/scrub.ts): the
// value and the ways it is commonly written out (base64, base64url, URL-encoded, JSON-escaped) each replaced with a
// mark, also when a chunk of output ends partway through one. Exact values, not shapes. A net for output only.

///|
/// What a hidden value reads as.
pub let hidden_mark : String = "[已隐藏]"

///|
fn utf8_of(s : String) -> Bytes {
  @vault_crypto.utf8(s)
}

///|
fn latin1(b : Bytes) -> String {
  let s = StringBuilder()
  for x in b {
    s.write_char(x.to_int().unsafe_to_char())
  }
  s.to_string()
}

///|
fn ascii(s : String) -> Bytes {
  Bytes::from_array(Array::makei(s.length(), i => s.code_unit_at(i).to_int().to_byte()))
}

///|
/// `buf.toString("base64")` (padded) or `"base64url"` (unpadded).
fn b64_text(b : Bytes, url : Bool) -> String {
  if url {
    @codec.base64url_encode(b[:])
  } else {
    @codec.base64_encode(b[:])
  }
}

///|
/// `encodeURIComponent(s)`; None where `s` holds a lone surrogate (where JS throws).
fn encode_uri_component(s : String) -> String? {
  let out = StringBuilder()
  let hexs = "0123456789ABCDEF"
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s.code_unit_at(i).to_int()
    if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || (c < 128 && "-_.!~*'()".contains_char(c.unsafe_to_char())) {
      out.write_char(c.unsafe_to_char())
      i += 1
      continue
    }
    let mut cp = c
    if c >= 0xd800 && c <= 0xdbff {
      if i + 1 < n {
        let d = s.code_unit_at(i + 1).to_int()
        if d >= 0xdc00 && d <= 0xdfff {
          cp = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00)
          i += 1
        } else {
          return None
        }
      } else {
        return None
      }
    } else if c >= 0xdc00 && c <= 0xdfff {
      return None
    }
    let bytes = utf8_of(cp.unsafe_to_char().to_string())
    for x in bytes {
      out.write_char('%')
      out.write_char(hexs.code_unit_at(x.to_int() >> 4).to_int().unsafe_to_char())
      out.write_char(hexs.code_unit_at(x.to_int() & 15).to_int().unsafe_to_char())
    }
    i += 1
  }
  Some(out.to_string())
}

///|
/// The forms of `value` hidden: the value as it is and as it is often written, the shortest worth hiding 4 bytes long.
pub fn forms_of(value : String) -> Array[Bytes] {
  let raw = utf8_of(value)
  let forms : Array[Bytes] = [
    raw,
    ascii(b64_text(raw, false)),
    ascii(b64_text(raw, true)),
  ]
  match encode_uri_component(value) {
    Some(e) => forms.push(ascii(e))
    // (JS throws there: scrub.ts would fail; the value's own form kept)
    None => ()
  }
  let j = stringify(Json::string(value))
  forms.push(utf8_of(slice(j, 1, b=j.length() - 1)))
  // base64 of the value at each of the three offsets it can start at inside a longer text
  for lead in [0, 1, 2] {
    let padded = Bytes::makei(lead + raw.length(), i => if i < lead { b'\x00' } else { raw[i - lead] })
    let from = (lead * 4 + 2) / 3
    let to = (lead + raw.length()) * 4 / 3
    if to - from < 8 {
      continue
    }
    for url in [false, true] {
      forms.push(ascii(slice(b64_text(padded, url), from, b=to)))
    }
  }
  let seen : Map[String, Unit] = Map([])
  let out = []
  for f in forms {
    let k = latin1(f)
    if f.length() >= 4 && !seen.contains(k) {
      seen[k] = ()
      out.push(f)
    }
  }
  out
}

///|
/// A stream's scrubber: `push` each chunk, `end` at the end; each gives what may be shown so far.
pub struct Scrubber {
  forms : Array[Bytes]
  mark : Bytes
  keep : Int
  mut held : Bytes
}

///|
pub fn Scrubber::new(values : Array[String], mark? : String = hidden_mark) -> Scrubber {
  let forms = []
  for v in values {
    for f in forms_of(v) {
      forms.push(f)
    }
  }
  // The longest first (a stable sort, as JS's is)
  let indexed = forms.mapi((i, f) => (i, f))
  indexed.sort_by((a, b) => if a.1.length() != b.1.length() {
    b.1.length() - a.1.length()
  } else {
    a.0 - b.0
  })
  let forms = indexed.map(p => p.1)
  let mut keep = 0
  for f in forms {
    keep = keep.max(f.length() - 1)
  }
  { forms, mark: utf8_of(mark), keep, held: b"" }
}

///|
fn concat(a : Bytes, b : Bytes) -> Bytes {
  Bytes::makei(a.length() + b.length(), i => if i < a.length() {
    a[i]
  } else {
    b[i - a.length()]
  })
}

///|
fn sub(b : Bytes, from : Int, to : Int) -> Bytes {
  Bytes::makei((to - from).max(0), i => b[from + i])
}

///|
fn matches_at(all : Bytes, at : Int, f : Bytes) -> Bool {
  if all.length() - at < f.length() {
    return false
  }
  for i in 0..<f.length() {
    if all[at + i] != f[i] {
      return false
    }
  }
  true
}

///|
fn Scrubber::scan(self : Scrubber, all : Bytes, last : Bool) -> (Bytes, Bytes) {
  let parts = Buffer()
  let mut at = 0
  let mut from = 0
  let limit = if last { all.length() } else { (all.length() - self.keep).max(0) }
  while at < limit {
    let mut hit : Bytes? = None
    for f in self.forms {
      if matches_at(all, at, f) {
        hit = Some(f)
        break
      }
    }
    match hit {
      None => at += 1
      Some(f) => {
        parts.write_bytes(sub(all, from, at))
        parts.write_bytes(self.mark)
        at += f.length()
        from = at
      }
    }
  }
  parts.write_bytes(sub(all, from, from.max(limit)))
  (parts.to_bytes(), sub(all, from.max(limit), all.length()))
}

///|
pub fn Scrubber::push(self : Scrubber, chunk : Bytes) -> Bytes {
  let (out, rest) = self.scan(concat(self.held, chunk), false)
  self.held = rest
  out
}

///|
pub fn Scrubber::end(self : Scrubber) -> Bytes {
  let (out, _) = self.scan(self.held, true)
  self.held = b""
  out
}

///|
/// `buf.toString("utf8")`: what is not UTF-8 replaced (U+FFFD), as Node decodes.
pub fn utf8_text(b : Bytes) -> String {
  @vault_crypto.text_of_bytes(b)
}

///|
/// `text` scrubbed whole.
pub fn scrub(text : String, values : Array[String]) -> String {
  let s = Scrubber::new(values)
  utf8_text(concat(s.push(utf8_of(text)), s.end()))
}
