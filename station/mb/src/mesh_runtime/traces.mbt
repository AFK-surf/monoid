// The station's traces (station/src/mesh/traces.ts): the mesh's own spans (a request stream from accepted to fully
// answered; an event stream's to its head), under the caller's trace when it records one. Batched, sent at most every
// EXPORT_MS to where the station is told (the control plane's `/v1/telemetry/traces`); a batch that cannot be sent is
// dropped. Off unless the config turns traces on. A span's id and the clocks it is timed by are given: the machine's
// randomness and its monotonic clock are its caller's.

///|
pub let export_ms : Int = 3_000

///|
pub let max_buffer : Int = 2_000

///|
pub let max_batch : Int = 500

///|
/// A W3C trace context: the trace, the caller's span, whether it is recorded.
#derive(Eq, Debug)
pub(all) struct Parent {
  trace : String
  span : String
  sampled : Bool
}

///|
pub fn Parent::to_json(self : Parent) -> Json {
  jobj([("trace", jstr(self.trace)), ("span", jstr(self.span)), ("sampled", Json::boolean(self.sampled))])
}

///|
fn hex_of(s : String, n : Int) -> Bool {
  s.length() == n && s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))
}

///|
fn zeros(s : String) -> Bool {
  s.length() > 0 && s.iter().all(c => c == '0')
}

///|
fn lower(s : String) -> String {
  let b = StringBuilder()
  for c in s {
    b.write_char(if c >= 'A' && c <= 'Z' { (c.to_int() + 32).unsafe_to_char() } else { c })
  }
  b.to_string()
}

///|
/// `00-<trace>-<span>-<flags>`; anything else is no context (`parseParent`).
pub fn parse_parent(header : String?) -> Parent? {
  let parts = js_trim(header.unwrap_or("")).split("-").map(p => p.to_owned()).to_array()
  if parts.length() != 4 {
    return None
  }
  let (version, trace, span, flags) = (parts[0], parts[1], parts[2], parts[3])
  if version.length() != 2 || version == "ff" || flags.length() != 2 || !hex_of(flags, 2) {
    return None
  }
  if !hex_of(trace, 32) || !hex_of(span, 16) || zeros(trace) || zeros(span) {
    return None
  }
  let f = @string.parse_int(flags, base=16) catch { _ => 0 }
  Some({ trace: lower(trace), span: lower(span), sampled: (f & 1) == 1 })
}

///|
let ids : Array[String] = [
  "sessions", "threads", "connects", "profiles", "logins", "workspaces", "stations", "members", "enrollments", "accounts",
]

///|
fn plain_word(segment : String) -> Bool {
  segment != "" &&
  segment.length() <= 24 &&
  segment.iter().all(c => (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') &&
  segment.iter().any(c => c >= 'a' && c <= 'z')
}

///|
/// A path without its ids: a segment after a collection, or one that is no plain word, is `:id` (`route`).
pub fn route(path : String) -> String {
  let mut end = path.length()
  for i in 0..<path.length() {
    let c = path.code_unit_at(i).to_int()
    if c == 0x3f || c == 0x23 {
      end = i
      break
    }
  }
  let mut after_collection = false
  path
  .clamped_view(end~)
  .to_owned()
  .split("/")
  .map(s => {
    let segment = s.to_owned()
    let id = segment != "" && (after_collection || !plain_word(segment))
    after_collection = !id && ids.contains(segment)
    if id {
      ":id"
    } else {
      segment
    }
  })
  .to_array()
  .join("/")
}

///|
/// An OTLP attribute of `value` as JavaScript has it (`attribute`).
pub fn attribute(key : String, value : Json) -> Json {
  let v = match value {
    True => jobj([("boolValue", Json::boolean(true))])
    False => jobj([("boolValue", Json::boolean(false))])
    Number(n, ..) if js_is_integer(n) => jobj([("intValue", jstr(js_num(n)))])
    Number(n, ..) => jobj([("doubleValue", jnum(n))])
    String(s) => jobj([("stringValue", jstr(s))])
    other => jobj([("stringValue", jstr(js_stringify(other)))])
  }
  jobj([("key", jstr(key)), ("value", v)])
}

///|
/// A span begun: its caller's context, its id, the wall clock it began at (ns) and the monotonic one (ns).
pub(all) struct Span {
  parent : Parent
  id : String
  wall_ns : Int64
  started : Int64
}

///|
/// The spans, batched and sent.
pub struct Traces {
  enabled : Bool
  spans : Array[Json]
  rt : @effect.Runtime
  mut armed : Bool
  mut sink : (async (Array[Json]) -> Unit)?
  mut closed : Bool
  mut waiting : @effect.Fiber[Unit]?
  /// The monotonic clock in ns (`process.hrtime.bigint()`).
  hr_now : () -> Int64
  said : (String, String, Json) -> Unit
}

///|
/// `rt`: the clock the batching wait runs on; `hr_now`: the monotonic clock spans are timed by; `said`: a line of the
/// log (level, words, what with them).
pub fn Traces::new(
  enabled : Bool,
  rt : @effect.Runtime,
  hr_now : () -> Int64,
  said : (String, String, Json) -> Unit,
) -> Traces {
  { enabled, spans: [], rt, armed: false, sink: None, closed: false, waiting: None, hr_now, said }
}

///|
/// Stops batching: a flush still waiting is not made.
pub fn Traces::close(self : Traces) -> Unit {
  self.closed = true
  if self.waiting is Some(f) {
    f.interrupt()
  }
  self.waiting = None
}

///|
/// A span under `parent`, when traces are on and the caller records this trace: `id` its id (8 random bytes in hex),
/// `wall_ms` the wall clock now.
pub fn Traces::start(self : Traces, parent : Parent?, id : String, wall_ms : Int64) -> Span? {
  guard self.enabled && parent is Some(p) && p.sampled else { return None }
  Some({ parent: p, id, wall_ns: wall_ms * 1_000_000L, started: (self.hr_now)() })
}

///|
/// The `traceparent` for what this span asks of others.
pub fn traceparent(span : Span) -> String {
  "00-\{span.parent.trace}-\{span.id}-01"
}

///|
/// Ends `span` as an OTLP server span with these attributes.
pub fn Traces::end(self : Traces, span : Span, name : String, attributes : Array[(String, Json)], failed : Bool) -> Unit {
  let end = span.wall_ns + ((self.hr_now)() - span.started)
  self.record(
    jobj([
      ("traceId", jstr(span.parent.trace)),
      ("spanId", jstr(span.id)),
      ("parentSpanId", jstr(span.parent.span)),
      ("name", jstr(name)),
      ("kind", jnum(2.0)),
      ("startTimeUnixNano", jstr(span.wall_ns.to_string())),
      ("endTimeUnixNano", jstr(end.to_string())),
      ("attributes", Json::array(attributes.map(a => attribute(a.0, a.1)))),
      ("status", jobj([("code", jnum(if failed { 2.0 } else { 1.0 }))])),
    ]),
  )
}

///|
fn Traces::record(self : Traces, span : Json) -> Unit {
  if !self.enabled {
    return
  }
  if self.spans.length() < max_buffer {
    self.spans.push(span)
  }
  if self.armed || self.closed {
    return
  }
  self.armed = true
  self.waiting = Some(
    self.rt.fork(name="traces", () => {
      @effect.sleep(export_ms)
      self.flush()
    }),
  )
}

///|
async fn Traces::flush(self : Traces) -> Unit {
  self.armed = false
  while self.spans.length() > 0 {
    let n = if self.spans.length() < max_batch { self.spans.length() } else { max_batch }
    let batch = self.spans[0:n].to_owned()
    let rest = self.spans[n:].to_owned()
    self.spans.clear()
    self.spans.append(rest)
    guard self.sink is Some(sink) else { continue }
    sink(batch) catch {
      e => {
        (self.said)("warn", "traces dropped", jobj([("error", jstr(message_of(e)))]))
        continue
      }
    }
    (self.said)("info", "traces sent", Json::null())
  }
}

///|
/// Sends batches to `sink` (the control plane's).
pub fn Traces::export_to(self : Traces, sink : async (Array[Json]) -> Unit) -> Unit {
  self.sink = Some(sink)
}

///|
/// A batch of the mesh's spans as OTLP JSON, of `station` (`otlpBody`).
pub fn otlp_body(station : String, spans : Array[Json]) -> String {
  let body = jobj([
    (
      "resourceSpans",
      Json::array([
        jobj([
          (
            "resource",
            jobj([
              (
                "attributes",
                Json::array([attribute("service.name", jstr("stillfail-mesh")), attribute("stillfail.station", jstr(station))]),
              ),
            ]),
          ),
          (
            "scopeSpans",
            Json::array([jobj([("scope", jobj([("name", jstr("stillfail-mesh"))])), ("spans", Json::array(spans))])]),
          ),
        ]),
      ]),
    ),
  ])
  js_stringify(body)
}
