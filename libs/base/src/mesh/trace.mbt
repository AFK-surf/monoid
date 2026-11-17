// What the mesh tells of itself: spans to its program's tracer, and lines to its program's record while that is on,
// as the TypeScript mesh tells them (client/core-ts/src/mesh.ts: `mesh.connect`, `mesh.hedge`, `mesh.race`,
// `mesh.route`, `mesh.path`, `mesh.speed`; client/core-ts/src/record.ts: `conn dial`, `conn ways`, `conn rebind`,
// `conn stuck`, `conn network-change`, `dht`). Nothing here changes what the mesh does; with none given, nothing is
// told, and a record's line is worked out only while the record is on.

///|
/// A span's attribute.
#derive(Debug, Eq)
pub(all) enum SpanValue {
  Str(String)
  Int(Int64)
  Num(Double)
  Flag(Bool)
}

///|
/// A span begun: the traceparent a peer is told it under (none: no trace), its attributes (`set`: the tracer's
/// own; `own`: the mesh's), whether it failed, and its end.
pub(all) struct Span {
  traceparent : String?
  set : (String, SpanValue) -> Unit
  own : (String, SpanValue) -> Unit
  fail : () -> Unit
  end : () -> Unit
}

///|
pub fn Span::none() -> Span {
  { traceparent: None, set: (_, _) => (), own: (_, _) => (), fail: () => (), end: () => () }
}

///|
/// Its program's tracer: what a peer is called in an attribute (`peer_key`), and a span begun by name under a
/// parent's traceparent, if any.
pub(all) struct Trace {
  peer_key : String
  start : (String, String?) -> Span
}

///|
pub fn Trace::none() -> Trace {
  { peer_key: "peer", start: (_, _) => Span::none() }
}

///|
/// A W3C traceparent: `00-<trace id, 32 hex>-<span id, 16 hex>-<01 sampled | 00>`.
pub fn format_traceparent(trace_id : Bytes, span_id : Bytes, sampled : Bool) -> String {
  "00-\{hex_bytes(trace_id)}-\{hex_bytes(span_id)}-\{if sampled { "01" } else { "00" }}"
}

///|
fn hex_bytes(bytes : Bytes) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for b in bytes {
    out.write_char(digits.get_char(b.to_int() / 16).unwrap())
    out.write_char(digits.get_char(b.to_int() % 16).unwrap())
  }
  out.to_string()
}

///|
/// Its program's record: whether lines are kept now, and where a line goes.
pub(all) struct Recorder {
  on : () -> Bool
  line : (String) -> Unit
}

///|
pub fn Recorder::none() -> Recorder {
  { on: () => false, line: _ => () }
}

///|
/// A line kept, `<what>: <fields>`, where lines are kept now (its fields worked out only then).
fn Mesh::record(self : Mesh, what : String, fields : () -> String) -> Unit {
  if (self.recorder.on)() {
    (self.recorder.line)("\{what}: \{fields()}")
  }
}

///|
/// A span begun, the peer said.
fn Mesh::span(self : Mesh, name : String, peer : String, parent? : String) -> Span {
  let span = (self.trace.start)(name, parent)
  (span.own)(self.trace.peer_key, Str(peer))
  span
}

///|
/// A place as the record names it: its peer's first 8, its scope's first 6 before it where it has one.
fn peer_tag(place : Place) -> String {
  let peer = cut_to(place.peer, 8)
  if place.scope == "" {
    peer
  } else {
    "\{cut_to(place.scope, 6)}/\{peer}"
  }
}

///|
fn cut_to(text : String, most : Int) -> String {
  let out = StringBuilder()
  let mut n = 0
  for c in text {
    guard n < most else { break }
    out.write_char(c)
    n += 1
  }
  out.to_string()
}

///|
/// A failure as the record says it: one line, 120 characters at most.
fn said_short(message : String) -> String {
  let out = StringBuilder()
  let mut space = false
  let mut started = false
  for c in message {
    if c == ' ' || c == '\n' || c == '\t' || c == '\r' {
      space = started
      continue
    }
    if space {
      out.write_char(' ')
      space = false
    }
    out.write_char(c)
    started = true
  }
  let one = out.to_string()
  if one.length() > 120 {
    cut_to(one, 117) + "…"
  } else {
    one
  }
}

///|
fn ms_of(x : Int) -> String {
  if x < 0 {
    "-"
  } else {
    "\{x}ms"
  }
}

///|
/// An endpoint's relays as a span says them: `<url> up|down, …`, or "none".
fn Mesh::relay_status(self : Mesh, endpoint : Json) -> String {
  let said = self.shell.ask("iroh.relayStatus", { "id": endpoint }) catch { _ => return "none" }
  guard said is Array(relays) && relays.length() > 0 else { return "none" }
  relays
  .map(relay => match relay {
    { "url": String(url), "connected": True, .. } => "\{url} up"
    { "url": String(url), .. } => "\{url} down"
    _ => "? down"
  })
  .join(", ")
}

///|
fn field_of(json : Json, key : String) -> Json? {
  match json {
    Object(fields) => fields.get(key)
    _ => None
  }
}

///|
fn round_ms(json : Json?) -> String {
  match json {
    Some(Number(n, ..)) => "\{n.round().to_int64()}ms"
    _ => "?"
  }
}

///|
fn int_of(json : Json?) -> Int64 {
  match json {
    Some(Number(n, ..)) => n.to_int64()
    _ => 0L
  }
}

///|
fn path_id(path : Json) -> String {
  match field_of(path, "id") {
    Some(String(id)) => id
    Some(Number(n, ..)) => n.to_int64().to_string()
    _ => ""
  }
}

///|
/// Where a path goes: its relay's host, or its address, or "direct".
fn path_where(path : Json, host : Bool) -> String {
  match (field_of(path, "relay"), field_of(path, "ip")) {
    (Some(String(relay)), _) => if host { relay_host(relay) } else { relay }
    (_, Some(String(ip))) => ip
    _ => direct
  }
}

///|
fn selected_mark(path : Json) -> String {
  if path is { "selected": True, .. } {
    "*"
  } else {
    ""
  }
}

///|
/// Every way the shell has for it: `*` the one chosen, where it goes, its round trip, packets sent and lost.
pub fn Link::paths_line(self : Link) -> String {
  self
  .paths()
  .map(path => "\{selected_mark(path)}\{path_where(path, true)} \{round_ms(field_of(path, "rttMs"))} \{int_of(field_of(path, "txPackets"))}/\{int_of(field_of(path, "lostPackets"))}")
  .join("; ")
}

///|
/// Which ways the shell has for it, where each goes and the one chosen, without their counts.
pub fn Link::path_shape(self : Link) -> String {
  self.paths().map(path => "\{selected_mark(path)}\{path_id(path)}@\{path_where(path, false)}").join(",")
}

///|
/// This device's open links to `place`'s peer in its other scopes: each one's scope and ways; "" with none.
fn Mesh::beside_of(self : Mesh, place : Place) -> String {
  let out = []
  for other, opening in self.links {
    if other.peer == place.peer && other.scope != place.scope && opening.result is Some(Open(link)) && link.ended() is None {
      out.push("\{other.scope}: \{link.paths_line()}")
    }
  }
  out.join(" | ")
}

///|
/// The DHT's lines since the last take (the shell's `dht.said`), each a `dht` line saying how long before it was;
/// not taken again within `every` ms. Once the record is off the shell is told, once, to keep none. A shell that
/// has no `dht.said` says nothing.
fn Mesh::record_dht(self : Mesh, every : Int) -> Unit {
  if !(self.recorder.on)() {
    if self.dht_kept {
      self.dht_kept = false
      ignore(self.shell.ask("dht.said", { "keep": false })) catch {
        _ => ()
      }
    }
    return
  }
  let now = (self.clock.now_ms)()
  if self.dht_kept && now - self.dht_at < every.to_int64() {
    return
  }
  self.dht_kept = true
  self.dht_at = now
  let said = self.shell.ask("dht.said", { "keep": true }) catch { _ => return }
  match field_of(said, "lines") {
    Some(Array(lines)) =>
      for line in lines {
        let text = match field_of(line, "text") {
          Some(String(text)) => text
          _ => ""
        }
        let before = now - int_of(field_of(line, "at"))
        self.record("dht", () => "\{text} (\{if before < 0L { 0L } else { before }}ms before)")
      }
    _ => ()
  }
  let dropped = int_of(field_of(said, "dropped"))
  if dropped > 0L {
    self.record("dht", () => "\{dropped} line(s) dropped for want of room")
  }
}

///|
/// What went over each way to `place` since the last tick, a `conn ways` line, while the record is on: each link's
/// bytes in and out, and each of its paths' packets sent and lost since, its round trip.
fn Mesh::record_ways(self : Mesh, place : Place) -> Unit {
  guard (self.recorder.on)() else { return }
  let parts = []
  for way in self.live_ways(place) {
    let link = way.link
    let (rx, tx) = link.stats()
    let (was_rx, was_tx, was_paths) = link.recorded
    let paths = link
      .paths()
      .map(path => {
        let id = path_id(path)
        let (tx0, lost0) = was_paths.get(id).unwrap_or((0L, 0L))
        let sent = int_of(field_of(path, "txPackets"))
        let lost = int_of(field_of(path, "lostPackets"))
        was_paths[id] = (sent, lost)
        "\{selected_mark(path)}\{path_where(path, true)} \{round_ms(field_of(path, "rttMs"))} +\{sent - tx0}/\{lost - lost0}"
      })
    parts.push(
      "\{link.pin.unwrap_or("main")} in=+\{rx - was_rx}B out=+\{tx - was_tx}B missed=\{link.missed} [\{paths.join("; ")}]",
    )
    link.recorded = (rx, tx, was_paths)
  }
  if parts.length() > 0 {
    self.record("conn ways", () => "\{peer_tag(place)} \{parts.join(" | ")}")
  }
}

///|
/// Each tick, a `mesh.path` span says a way's paths changed (one opened, one went, another chosen; first seen,
/// direct already) or that it missed its first ping in a row: its paths now and as the tick before saw them.
fn Mesh::watch_paths(self : Mesh, place : Place, way : Way) -> Unit {
  let link = way.link
  let shape = link.path_shape()
  let paths = link.paths_line()
  let changed = match way.shape {
    None => link.path() == Some(direct)
    Some(was) => was != shape
  }
  let missed = link.missed == 1
  if changed || missed {
    let span = self.span("mesh.path", place.peer)
    (span.own)("way", Str(way.key()))
    (span.own)("why", Str(if changed && missed { "paths missed" } else if changed { "paths" } else { "missed" }))
    (span.own)("current", Flag(self.is_current(link)))
    (span.own)("paths", Str(paths))
    if way.saw is Some(saw) {
      (span.own)("before.paths", Str(saw))
    }
    (span.end)()
  }
  way.shape = Some(shape)
  way.saw = Some(paths)
}

///|
/// What a tick sees of `place`'s ways: their paths (`watch_paths`), the record's lines of them, the DHT's.
fn Mesh::observe(self : Mesh, place : Place) -> Unit {
  for way in self.live_ways(place) {
    self.watch_paths(place, way)
  }
  self.record_ways(place)
  self.record_dht(tick_ms)
}

///|
/// A reply's speed through a relay, told (`mesh.speed`) at most once every `speed_said_ms` for each peer and relay:
/// every one seen, slower ones too.
fn Mesh::say_speed(self : Mesh, peer : String, relay : String, bytes : Int, ms : Int, now : Int64) -> Unit {
  let said = "\{peer} \{relay_key(relay)}"
  if self.speed_said.get(said) is Some(at) && now - at < speed_said_ms.to_int64() {
    return
  }
  self.speed_said[said] = now
  let span = self.span("mesh.speed", peer)
  (span.own)("via", Str(relay_host(relay)))
  (span.own)("bytes", Int(bytes.to_int64()))
  (span.own)("ms", Int(ms.to_int64()))
  (span.own)("bps", Int((bytes.to_double() / ms.to_double() * 1000.0).round().to_int64()))
  for place in self.links.keys().to_array() {
    guard place.peer == peer else { continue }
    match self.live_ways(place).search_by(way => way.key() == relay_key(relay)) {
      Some(i) => {
        let link = self.live_ways(place)[i].link
        (span.own)("current", Flag(self.is_current(link)))
        (span.own)("paths", Str(link.paths_line()))
        break
      }
      None => ()
    }
  }
  (span.end)()
}

///|
/// An opening ended, with a link or failing: its `mesh.connect` span told how, and ended. `beside`: the link came
/// of the dial tried beside its first (a wake's).
fn Mesh::connect_said(self : Mesh, place : Place, opening : Opening, made : Tried[Link], beside : Bool) -> Unit {
  guard opening.span is Some(span) else { return }
  opening.span = None
  match made {
    Did(link) => {
      if link.path() is Some(path) {
        (span.own)("path", Str(path))
      }
      if link.via() is Some(via) {
        (span.own)("via", Str(relay_host(via)))
      }
      let (onto, dialled, credential) = link.opened
      (span.own)("onto_ms", Int(onto.to_int64()))
      (span.own)("dialled_ms", Int(dialled.to_int64()))
      (span.own)("credential_ms", Int(credential.to_int64()))
      (span.own)("paths", Str(link.paths_line()))
      if beside {
        (span.own)("hedged", Flag(true))
      }
    }
    Fell(e) => {
      (span.fail)()
      (span.set)("error.type", Str(if e is OpeningTimeout(_) { "mesh" } else { code_of(e) }))
      match e {
        MeshError(cause~, ..) if cause != "" => (span.own)("cause", Str(cause))
        _ => ()
      }
      (span.own)("relay", Str(self.relay_status(self.endpoint)))
      let straight = self.ips(place)
      if straight.length() > 0 {
        (span.own)("ips", Str(straight.join(", ")))
      }
      let beside_of = self.beside_of(place)
      if beside_of != "" {
        (span.own)("beside", Str(beside_of))
      }
    }
  }
  (span.end)()
}

///|
/// How long each stage of a dial took from its start (-1: not reached), for its `conn dial` line and its span.
priv struct Stages {
  mut onto : Int
  mut credential : Int
  mut dialled : Int
  mut open_bi : Int
  mut sent : Int
}

///|
fn Stages::new() -> Stages {
  { onto: -1, credential: -1, dialled: -1, open_bi: -1, sent: -1 }
}

///|
/// A dial's outcome as its line says it.
fn outcome_of(e : Error) -> String {
  match e {
    OpeningTimeout(_) => "no-answer"
    MeshError(code~, ..) if code == "no_answer" => "no-answer"
    MeshError(message~, ..) => "error: \{said_short(message)}"
    e => "error: \{said_short(said(e))}"
  }
}
