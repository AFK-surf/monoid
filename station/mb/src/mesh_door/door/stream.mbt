// What the mesh's wire and door stand on (station/src/mesh/endpoint.ts): a connection of an endpoint and its
// bidirectional streams, as whatever carries them gives them (the shell's iroh, a test's network in memory, a bridge to
// another program). Nothing here knows whose program serves them: no admission, no routes, no program's name.

///|
/// One bidirectional stream (endpoint.ts `Stream`).
pub(all) struct Stream {
  /// The next bytes that came, None once the other end finished it.
  read : async () -> Bytes?
  write : async (Bytes) -> Unit
  /// Finishes the sending half.
  finish : async () -> Unit
  /// Once what was sent is acknowledged: None, or the code the other end stopped reading with.
  stopped : async () -> Int?
  reset : async (Int) -> Unit
  /// Switch this stream's screen frames to QUIC datagrams tagged with `token`; None if unsupported.
  media_datagrams : (async (Double) -> Bool)?
}

///|
/// One way a connection can go now (endpoint.ts `paths`).
pub(all) struct Path {
  selected : Bool
  relay : String?
  ip : String?
  rtt_ms : Double?
  tx_packets : Double
  lost_packets : Double
}

///|
/// A connection (endpoint.ts `Connection`): what a test's or a carrier's connection lacks is None.
pub(all) struct Connection {
  remote_id : () -> String
  alpn : () -> String
  via : () -> String?
  paths : (() -> Array[Path])?
  accept_bi : async () -> Stream?
  open_bi : async () -> Stream
  /// Whether the other end is still there: true once anything is heard from it within the ms given.
  answers : (async (Int) -> Bool)?
  /// What went over it (endpoint.ts `Traffic`, by its names: `rxBytes`, `rxPackets`, ...).
  stats : (() -> Map[String, Double])?
  close : (Int, String) -> Unit
  is_closed : () -> Bool
  /// Once it is closed: why.
  closed : async () -> String
  /// Why it is gone, told apart (kind, reason); None while it is not.
  close_reason : (() -> (String, String)?)?
  /// Where the endpoint is kept by a program of its own: its id of this connection.
  handed : Int?
}

///|
/// What is said of the mesh as it goes (station/src/ops/log.ts's lines): (level, part, words, what with them). None is
/// said unless a program sets where it goes.
let logger : Ref[(String, String, String, Json) -> Unit] = Ref((_, _, _, _) => ())

///|
pub fn set_log(f : (String, String, String, Json) -> Unit) -> Unit {
  logger.val = f
}

///|
pub fn log(level : String, part : String, words : String, with_ : Json) -> Unit {
  (logger.val)(level, part, words, with_)
}

///|
/// A view's bytes as bytes of their own.
pub fn own(v : BytesView) -> Bytes {
  let b = @buffer.Buffer(size_hint=v.length())
  b.write_bytesview(v)
  b.to_bytes()
}

///|
/// Several pieces as one.
pub fn concat(parts : Array[Bytes]) -> Bytes {
  let size = parts.fold(init=0, (n, p) => n + p.length())
  let b = @buffer.Buffer(size_hint=size)
  for p in parts {
    b.write_bytes(p)
  }
  b.to_bytes()
}

///|
/// A fiber that runs `f` after `ms` on `rt`'s clock unless what this gives is called first.
pub fn after(rt : @effect.Runtime, ms : Int, f : () -> Unit) -> () -> Unit {
  let fiber = rt.fork(name="after", () => {
    @effect.sleep(ms)
    f()
  })
  () => fiber.interrupt()
}
