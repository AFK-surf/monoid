// What the station itself asks of a chat's Farview tab on its agent port (src/browser/farview-agent.ts, 127.0.0.1), as
// agent.exe does: a script's value, the cookies read, set or cleared, a step (a field typed, a click, a key) and what
// the page says after it. Farview's wire (its src/proto): a message is a 4-byte big-endian length and a body, the body
// a kind and its fields, each integer a zigzag varint, each string its UTF-8 length and bytes. Used for the sign-ins
// put into the tab and for filling its sign-in form, so nothing of them (a cookie, a password) is ever on a command
// line.

///|
/// What the station asks (`AgentAsk`): `look`, `eval` a script, `cookies` (get, set, clear) and `act` (a verb on a
/// selector with text).
pub(all) enum AgentAsk {
  Look
  Eval(String)
  Cookies(String, String)
  Act(String, String, String)
}

///|
/// What the tab answers (`AgentAnswer`): a value (a script's, as JSON; the cookies'), what the page says after a step
/// (its address, title, outline), or that a person took the tab back.
pub(all) enum AgentAnswer {
  Value(String)
  Seen(String, String, String)
  Taken
}

///|
pub fn AgentAnswer::to_j(self : AgentAnswer) -> J {
  match self {
    Value(v) => jo([("kind", js("value")), ("value", js(v))])
    Seen(u, t, o) => jo([("kind", js("seen")), ("url", js(u)), ("title", js(t)), ("outline", js(o))])
    Taken => jo([("kind", js("taken"))])
  }
}

///|
let kind_look : Int = 19

///|
let kind_seen : Int = 20

///|
let kind_taken : Int = 21

///|
let kind_act : Int = 18

///|
let kind_eval : Int = 32

///|
let kind_value : Int = 33

///|
let kind_cookies : Int = 35

///|
fn varint(out : @buffer.Buffer, v : Int) -> Unit {
  let mut u = ((v << 1) ^ (v >> 31)).reinterpret_as_uint()
  while u >= 0x80U {
    out.write_byte(((u & 0x7fU) | 0x80U).reinterpret_as_int().to_byte())
    u = u >> 7
  }
  out.write_byte(u.reinterpret_as_int().to_byte())
}

///|
fn wire_str(out : @buffer.Buffer, s : String) -> Unit {
  let b = utf8(s)
  varint(out, b.length())
  out.write_bytes(b)
}

///|
/// A message as the wire carries it, its length first.
pub fn encode_ask(a : AgentAsk) -> Bytes {
  let body = @buffer.new()
  match a {
    Look => varint(body, kind_look)
    Eval(script) => {
      varint(body, kind_eval)
      wire_str(body, script)
    }
    Cookies(verb, arg) => {
      varint(body, kind_cookies)
      wire_str(body, verb)
      wire_str(body, arg)
    }
    Act(verb, selector, t) => {
      varint(body, kind_act)
      wire_str(body, verb)
      wire_str(body, selector)
      wire_str(body, t)
    }
  }
  let b = body.to_bytes()
  let out = @buffer.new()
  let n = b.length()
  out.write_byte((n >> 24).to_byte())
  out.write_byte(((n >> 16) & 0xff).to_byte())
  out.write_byte(((n >> 8) & 0xff).to_byte())
  out.write_byte((n & 0xff).to_byte())
  out.write_bytes(b)
  out.to_bytes()
}

///|
priv struct WireReader {
  b : Bytes
  mut i : Int
}

///|
fn WireReader::int(self : WireReader) -> Int {
  let mut shift = 0
  let mut u = 0
  while self.i < self.b.length() {
    let c = self.b[self.i].to_int()
    self.i += 1
    u = u | ((c & 0x7f) << (shift % 32))
    shift += 7
    if c < 0x80 {
      break
    }
  }
  let uu = u.reinterpret_as_uint()
  ((uu >> 1).reinterpret_as_int()) ^ -(u & 1)
}

///|
fn WireReader::string(self : WireReader) -> String {
  let n = self.int()
  let end = if self.i + n > self.b.length() { self.b.length() } else { self.i + n }
  let start = if self.i > end { end } else { self.i }
  let s = from_utf8(self.b[start:end].to_bytes())
  self.i += n
  s
}

///|
/// A body read: an answer to the station, or None for what else the host sends (a frame, a notice).
pub fn decode_answer(body : Bytes) -> AgentAnswer? {
  let r : WireReader = { b: body, i: 0 }
  let kind = r.int()
  if kind == kind_value {
    Some(Value(r.string()))
  } else if kind == kind_seen {
    let url = r.string()
    let title = r.string()
    Some(Seen(url, title, r.string()))
  } else if kind == kind_taken {
    Some(Taken)
  } else {
    None
  }
}

///|
/// How long an answer is waited for: the host waits on a script's promise up to 30 s of the page's time.
let answer_ms : Double = 45_000.0

///|
/// A connection to a port of 127.0.0.1 (node:net's), as the station's program has it (the shell's `tcp.*`).
pub(all) struct TcpLink {
  write : async (Bytes) -> Unit
  /// The next bytes it says; None once it ended.
  read : async () -> Bytes?
  close : () -> Unit
}

///|
/// The station's ways to the tabs' hosts: a connection to a port of 127.0.0.1.
pub(all) struct FarviewNet {
  connect : async (Int) -> TcpLink
  clock : Clock
}

///|
/// `ask` of the tab whose agent port is `port`, on a connection of its own: its first answer.
pub async fn ask_tab(net : FarviewNet, port : Int, ask : AgentAsk) -> AgentAnswer {
  within(
    net.clock,
    answer_ms,
    async fn() {
      let link = (net.connect)(port)
      let r = attempt(async fn() {
        (link.write)(encode_ask(ask))
        let buf = @buffer.new()
        let mut held = b""
        while true {
          guard (link.read)() is Some(chunk) else {
            raise fail_("Farview's tab closed the connection")
          }
          buf.reset()
          buf.write_bytes(held)
          buf.write_bytes(chunk)
          held = buf.to_bytes()
          while held.length() >= 4 {
            let n = (held[0].to_int() << 24) |
              (held[1].to_int() << 16) |
              (held[2].to_int() << 8) |
              held[3].to_int()
            if n < 0 || held.length() < 4 + n {
              break
            }
            let answer = decode_answer(held[4:4 + n].to_bytes())
            held = held[4 + n:].to_bytes()
            match answer {
              Some(a) => return a
              None => ()
            }
          }
        }
        raise fail_("Farview's tab closed the connection")
      })
      (link.close)()
      match r {
        Ok(a) => a
        Err(e) => raise e
      }
    },
    "Farview's tab did not answer",
  )
}

///|
/// A script's value in the tab (its JSON parsed; None where it is none).
pub async fn eval_in(net : FarviewNet, port : Int, script : String) -> J? {
  match ask_tab(net, port, Eval(script)) {
    Value(v) => try Some(parse(v)) catch { _ => None }
    Taken => raise fail_("the person took the tab back")
    Seen(_, _, _) => raise fail_("no value")
  }
}
