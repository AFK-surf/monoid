// What goes over a mesh stream (station/src/mesh/wire.ts): a JSON line, then bytes. A stream is the world's (`stream.*`:
// its bytes in base64 both ways); its lines are read here.

///|
/// wire.ts MAX_HEAD: how long a line may be.
let max_head : Int = 16 * 1024

///|
/// A stream's lines read, what came after the last one kept (`carry`).
pub struct Reader {
  w : World
  stream : J
  mut carry : Bytes
}

///|
pub fn Reader::new(w : World, stream : J) -> Reader {
  { w, stream, carry: b"", }
}

///|
/// More of a stream's bytes, None at its end.
pub async fn stream_read(w : World, stream : J) -> Bytes? {
  let (said, bytes) = w.stream_call(stream, "read") catch { _ => return None }
  match (said, bytes) {
    (Object({ "end": True, .. }), _) | (_, None) => None
    (_, Some(b)) => Some(b)
  }
}

///|
pub async fn stream_write(w : World, stream : J, bytes : BytesView) -> Unit {
  ignore(w.stream_call(stream, "write", bytes=bytes.to_owned()))
}

///|
/// wire.ts `writeLine`.
pub async fn write_line(w : World, stream : J, value : J) -> Unit {
  stream_write(w, stream, @utf8.encode(stringify(value) + "\n"))
}

///|
fn index_byte(b : BytesView, x : Byte) -> Int {
  for i in 0..<b.length() {
    if b[i] == x {
      return i
    }
  }
  -1
}

///|
/// The next line, parsed; None at the stream's end.
pub async fn Reader::line(self : Reader) -> J? {
  let mut at = index_byte(self.carry, b'\n')
  if at < 0 {
    let buf = @buffer.new()
    buf.write_bytes(self.carry)
    let mut size = self.carry.length()
    while at < 0 {
      if size > max_head {
        raise fail_("head too large")
      }
      guard stream_read(self.w, self.stream) is Some(more) else {
        if size == 0 {
          return None
        }
        raise fail_("stream ended mid-line")
      }
      let found = index_byte(more, b'\n')
      if found >= 0 {
        at = size + found
      }
      buf.write_bytes(more)
      size += more.length()
    }
    self.carry = buf.to_bytes()
  }
  if at > max_head {
    raise fail_("head too large")
  }
  let line = @utf8.decode_lossy(self.carry[0:at])
  self.carry = self.carry[at + 1:].to_owned()
  Some(@session_chats.parse_js(line))
}

///|
/// `what`, or a failure saying `why` once `ms` went by first (`wall.within`).
pub async fn[X] World::within(
  self : World,
  ms : Double,
  what : async () -> X,
  why : String,
) -> X {
  @effect.race_first(what, async fn() {
    self.sleep(ms)
    raise fail_(why)
  })
}
