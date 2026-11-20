// The events of a group space (`im/2`; group/event.ts), byte for byte as the IM's own code makes them (AFK-surf/group
// core/src/im/canon.mbt and event.mbt): an event is said by one device and signed by its Ed25519 key (the connect's
// key, its iroh endpoint's), over the canonical JSON of its envelope; its id is the SHA-256 of that same text. The
// anchor stamps what it takes (`aseq`, its place in its space; `n` where it is a message; `at`, its time), none of it
// signed.
//
// Canonical JSON as canon.mbt writes it: no space; whole numbers as integers; a string's `"` `\` and newline, return
// and tab escaped as `\"` `\\` `\n` `\r` `\t`, every other character under 0x20 as `\u00xx` (lowercase hex), the rest
// as it is; an object's keys in MoonBit's order of strings, which is by length first (UTF-16 code units), then code
// unit by code unit.

///|
pub let protocol_version : Int = 2

///|
pub let lobby : String = "lobby"

///|
/// The signing of what the station says and the check of what it hears (the shell's `ed25519.sign` and
/// `crypto.verify`): a seed's public half, a signature of bytes by a seed (hex), whether one is a device's.
pub(all) struct Signer {
  public_key : (String) -> String?
  sign : (String, Bytes) -> String?
  verify : (String, Bytes, String) -> Bool
}

///|
/// The envelope of an event, signed (`sig`: its device's signature, 128 hex).
pub(all) struct GroupEvent {
  space : String
  author : String
  device : String
  dseq : Double
  hlc : (Double, Double)
  prev : String
  topic : String
  kind : String
  body : J
  sig : String
}

///|
/// An event as the anchor took it.
pub(all) struct Stamped {
  id : String
  event : GroupEvent
  aseq : Double
  n : Double
  at : Double
}

///|
/// MoonBit's order of strings (core's `String::compare`): the shorter first, then by UTF-16 code unit.
pub fn moon_order(a : String, b : String) -> Int {
  if a.length() != b.length() {
    return a.length() - b.length()
  }
  for i in 0..<a.length() {
    let x = a.unsafe_get(i).to_int()
    let y = b.unsafe_get(i).to_int()
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  0
}

///|
fn canon_string(s : String, out : StringBuilder) -> Unit {
  out.write_char('"')
  for c in s {
    let v = c.to_int()
    match c {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      _ =>
        if v < 0x20 {
          out.write_string("\\u00")
          out.write_string(@codec.hex_encode(Bytes::make(1, v.to_byte())))
        } else {
          out.write_char(c)
        }
    }
  }
  out.write_char('"')
}

///|
fn canon_into(j : J, out : StringBuilder) -> Unit {
  match j {
    Null => out.write_string("null")
    Bool(b) => out.write_string(if b { "true" } else { "false" })
    Num(d) => out.write_string(if d == 0.0 { "0" } else { @session_chats.num_text(d) })
    Str(u) => canon_string(@jsjson.sanitize_str(u), out)
    Arr(xs) => {
      out.write_char('[')
      for i, x in xs {
        if i > 0 {
          out.write_char(',')
        }
        canon_into(if is_undefined(x) { Null } else { x }, out)
      }
      out.write_char(']')
    }
    Obj(_) => {
      let fs = fields_of(Some(j)).filter(f => !is_undefined(f.1))
      // (a key said twice: JavaScript's object keeps its last value, at its first place)
      let kept : Array[(String, J)] = []
      for f in fs {
        match kept.search_by(k => k.0 == f.0) {
          Some(i) => kept[i] = f
          None => kept.push(f)
        }
      }
      kept.sort_by((a, b) => moon_order(a.0, b.0))
      out.write_char('{')
      for i, f in kept {
        if i > 0 {
          out.write_char(',')
        }
        canon_string(f.0, out)
        out.write_char(':')
        canon_into(f.1, out)
      }
      out.write_char('}')
    }
  }
}

///|
/// `j` as canonical JSON (canon.mbt `canonical`).
pub fn canonical_json(j : J) -> String {
  let out = StringBuilder()
  canon_into(j, out)
  out.to_string()
}

///|
/// What is signed of an event, and what its id is the hash of (event.mbt `Event::unsigned`).
pub fn unsigned_of(e : GroupEvent) -> J {
  jo([
    ("v", ji(protocol_version)),
    ("space", js(e.space)),
    ("author", js(e.author)),
    ("device", js(e.device)),
    ("dseq", jn(e.dseq)),
    ("hlc", ja([jn(e.hlc.0), jn(e.hlc.1)])),
    ("prev", js(e.prev)),
    ("topic", js(e.topic)),
    ("kind", js(e.kind)),
    ("enc", ji(0)),
    ("body", e.body),
  ])
}

///|
pub fn signed_text(e : GroupEvent) -> String {
  canonical_json(unsigned_of(e))
}

///|
/// The event's id: SHA-256 of what is signed, hex.
pub fn event_id(e : GroupEvent) -> String {
  @cloud_net.sha256_hex(signed_text(e))
}

///|
/// An event as it goes on the wire (`signEvent`'s object: its fields, then `v`, `enc` and `sig`).
pub fn GroupEvent::to_j(self : GroupEvent) -> J {
  jo([
    ("space", js(self.space)),
    ("author", js(self.author)),
    ("device", js(self.device)),
    ("dseq", jn(self.dseq)),
    ("hlc", ja([jn(self.hlc.0), jn(self.hlc.1)])),
    ("prev", js(self.prev)),
    ("topic", js(self.topic)),
    ("kind", js(self.kind)),
    ("body", self.body),
    ("v", ji(protocol_version)),
    ("enc", ji(0)),
    ("sig", js(self.sig)),
  ])
}

///|
/// The event said by the seed's device, signed (event.mbt `sign_event`).
pub fn sign_event(signer : Signer, seed : String, e : GroupEvent) -> GroupEvent raise {
  guard (signer.sign)(seed, utf8(signed_text(e))) is Some(sig) else { raise fail_("the event was not signed") }
  { ..e, sig, }
}

///|
/// Whether the event is signed by the device it names.
pub fn verified(signer : Signer, e : GroupEvent) -> Bool {
  if !lower_hex_of(e.device, 64) || !lower_hex_of(e.sig, 128) {
    return false
  }
  (signer.verify)(e.device, utf8(signed_text(e)), e.sig)
}

///|
/// An event read off the wire (event.mbt `Event::of_json`); None where it is none.
pub fn event_of(j : J?) -> GroupEvent? {
  guard j is Some(Obj(_)) else { return None }
  if !(at(j, "v") is Some(Num(v)) && v == 2.0) || !(at(j, "enc") is Some(Num(enc)) && enc == 0.0) {
    return None
  }
  guard at(j, "hlc") is Some(Arr(hlc)) && hlc.length() == 2 && hlc[0] is Num(h0) && hlc[1] is Num(h1) else { return None }
  guard at(j, "dseq") is Some(Num(dseq)) && dseq.floor() == dseq && dseq >= 1.0 else { return None }
  guard at(j, "body") is Some(body) else { return None }
  let s = (k : String) => str_of(at(j, k))
  match (s("space"), s("author"), s("device"), s("prev"), s("topic"), s("kind"), s("sig")) {
    (Some(space), Some(author), Some(device), Some(prev), Some(topic), Some(kind), Some(sig)) =>
      Some({ space, author, device, dseq, hlc: (h0, h1), prev, topic, kind, body, sig })
    _ => None
  }
}

///|
/// A stamped event read off the wire: its id worked out again, never taken as said (None where it differs), and its
/// signature checked (None where it is not its device's).
pub fn stamped_of(signer : Signer, j : J?) -> Stamped? {
  guard event_of(at(j, "event")) is Some(event) else { return None }
  let id = event_id(event)
  if !(str_of(at(j, "id")) == Some(id)) || !verified(signer, event) {
    return None
  }
  let int = (k : String) => match at(j, k) {
    Some(Num(d)) if !d.is_nan() && !d.is_inf() => d.trunc() + 0.0
    _ => 0.0
  }
  Some({ id, event, aseq: int("aseq"), n: int("n"), at: int("at") })
}

///|
/// The id of the direct space of two members (event.mbt `direct_id`).
pub fn direct_id(a : String, b : String) -> String {
  let pair = if moon_order(a, b) < 0 { "\{a}|\{b}" } else { "\{b}|\{a}" }
  "d_" + @session_chats.slice(@cloud_net.sha256_hex("im/2 direct \{pair}"), 0, b=24)
}

///|
fn hex_tail(s : String, from : Int, n : Int) -> Bool {
  if s.length() != from + n {
    return false
  }
  for i in from..<s.length() {
    let c = s.unsafe_get(i).to_int()
    if !((c >= '0'.to_int() && c <= '9'.to_int()) || (c >= 'a'.to_int() && c <= 'f'.to_int())) {
      return false
    }
  }
  true
}

///|
pub fn is_space_id(id : String) -> Bool {
  (id.has_prefix("d_") || id.has_prefix("s_")) && hex_tail(id, 2, 24)
}

///|
pub fn is_topic_id(id : String) -> Bool {
  id == lobby || (id.has_prefix("t_") && hex_tail(id, 2, 16))
}

///|
/// A hybrid logical clock (event.mbt `Clock`): never behind the wall, never behind what was seen, after its last.
pub struct Hlc {
  mut ms : Double
  mut n : Double
}

///|
pub fn Hlc::new() -> Hlc {
  { ms: 0.0, n: 0.0 }
}

///|
pub fn Hlc::next(self : Hlc, wall : Double) -> (Double, Double) {
  if wall > self.ms {
    self.ms = wall
    self.n = 0.0
  } else {
    self.n += 1.0
  }
  (self.ms, self.n)
}

///|
pub fn Hlc::saw(self : Hlc, ms : Double, n : Double) -> Unit {
  if ms > self.ms || (ms == self.ms && n > self.n) {
    self.ms = ms
    self.n = n
  }
}
