// The station's traces (station/src/mesh/traces.ts): the mesh's own spans (a request stream from accepted to fully
// answered; an event stream's to its head), under the caller's trace when it records one. Batched, sent at most every
// EXPORT_MS to where the station is told (the control plane's `/v1/telemetry/traces`); a batch that cannot be sent is
// tried once more at the next flush (unless the plane refused it with a 4xx), then dropped, said at most every 10 min.
// Where `tail_only` (the config's `telemetry.traces` unset), only a failed or slow span is kept. A span's id and the
// clocks it is timed by are given: the machine's randomness and its monotonic clock are its caller's.

///|
pub let export_ms : Int = 3_000

///|
pub let max_buffer : Int = 2_000

///|
pub let max_batch : Int = 500

///|
/// The least time between two `traces dropped` lines (monotonic ns).
pub let drop_warn_ns : Int64 = 600_000_000_000L

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
  /// Only failed or slow spans are kept (`slow_ms` or longer).
  tail_only : Bool
  slow_ms : Int
  /// The batch at the head was put back after a failure: a second failure drops it.
  mut retrying : Bool
  /// When `traces dropped` was said last (monotonic ns).
  mut dropped_at : Int64?
}

///|
/// `rt`: the clock the batching wait runs on; `hr_now`: the monotonic clock spans are timed by; `said`: a line of the
/// log (level, words, what with them); `tail_only`: keep only a failed span or one that took `slow_ms` or longer.
pub fn Traces::new(
  enabled : Bool,
  rt : @effect.Runtime,
  hr_now : () -> Int64,
  said : (String, String, Json) -> Unit,
  tail_only? : Bool = false,
  slow_ms? : Int = 1_000,
) -> Traces {
  {
    enabled,
    spans: [],
    rt,
    armed: false,
    sink: None,
    closed: false,
    waiting: None,
    hr_now,
    said,
    tail_only,
    slow_ms,
    retrying: false,
    dropped_at: None,
  }
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
/// A root internal span when traces are on: `trace_id` (16 random bytes in hex), `id` (8 random bytes in hex),
/// `wall_ms` the wall clock now. `parent.span` is empty so OTLP omits `parentSpanId` (`root:<name>` in Cloud Trace).
pub fn Traces::start_root(self : Traces, trace_id : String, id : String, wall_ms : Int64) -> Span? {
  guard self.enabled else { return None }
  Some({ parent: { trace: trace_id, span: "", sampled: true }, id, wall_ns: wall_ms * 1_000_000L, started: (self.hr_now)() })
}

///|
/// The `traceparent` for what this span asks of others.
pub fn traceparent(span : Span) -> String {
  "00-\{span.parent.trace}-\{span.id}-01"
}

///|
/// Ends `span` as an OTLP server span with these attributes (where `tail_only`, a quick one that did not fail is not
/// kept).
pub fn Traces::end(self : Traces, span : Span, name : String, attributes : Array[(String, Json)], failed : Bool) -> Unit {
  let end = span.wall_ns + ((self.hr_now)() - span.started)
  if self.tail_only && !failed && end - span.wall_ns < self.slow_ms.to_int64() * 1_000_000L {
    return
  }
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
/// Records an OTLP internal span (`kind = 1`) with explicit wall-clock start/end timestamps (ns).
/// Omits `parentSpanId` when `parent_span_id` is empty so Cloud Trace classifies it as a root span.
pub fn Traces::record_internal(
  self : Traces,
  trace_id : String,
  id : String,
  start_wall_ns : Int64,
  end_wall_ns : Int64,
  name : String,
  attributes : Array[(String, Json)],
  failed : Bool,
  always_keep? : Bool = false,
  slow_ms? : Int = -1,
  parent_span_id? : String = "",
) -> Unit {
  if !self.enabled {
    return
  }
  let dur_ns = end_wall_ns - start_wall_ns
  if self.tail_only && !always_keep && !failed {
    let threshold_ms = if slow_ms >= 0 { slow_ms } else { self.slow_ms }
    if dur_ns < threshold_ms.to_int64() * 1_000_000L {
      return
    }
  }
  let fields : Array[(String, Json)] = [
    ("traceId", jstr(trace_id)),
    ("spanId", jstr(id)),
  ]
  if parent_span_id != "" {
    fields.push(("parentSpanId", jstr(parent_span_id)))
  }
  fields.push(("name", jstr(name)))
  fields.push(("kind", jnum(1.0)))
  fields.push(("startTimeUnixNano", jstr(start_wall_ns.to_string())))
  fields.push(("endTimeUnixNano", jstr(end_wall_ns.to_string())))
  fields.push(("attributes", Json::array(attributes.map(a => attribute(a.0, a.1)))))
  fields.push(("status", jobj([("code", jnum(if failed { 2.0 } else { 1.0 }))])))
  self.record(jobj(fields))
}

///|
/// Ends `span` as an OTLP internal span (`kind = 1`), omitting `parentSpanId` for root spans.
pub fn Traces::end_internal(
  self : Traces,
  span : Span,
  name : String,
  attributes : Array[(String, Json)],
  failed : Bool,
  always_keep? : Bool = false,
  slow_ms? : Int = -1,
) -> Unit {
  let end = span.wall_ns + ((self.hr_now)() - span.started)
  self.record_internal(
    span.parent.trace,
    span.id,
    span.wall_ns,
    end,
    name,
    attributes,
    failed,
    always_keep~,
    slow_ms~,
    parent_span_id=span.parent.span,
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
  self.arm()
}

///|
/// The next flush, `export_ms` from now, unless one is due already.
fn Traces::arm(self : Traces) -> Unit {
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
    let sent : Result[Unit, Error] = try Ok(sink(batch)) catch { e => Err(e) }
    match sent {
      Ok(_) => self.retrying = false
      Err(e) => {
        let message = message_of(e)
        // (a 4xx is the plane's refusal: sending it again is refused again)
        if !self.retrying && !message.contains("answered 4") {
          let kept = batch.copy()
          kept.append(self.spans)
          self.spans.clear()
          self.spans.append(if kept.length() > max_buffer { kept[0:max_buffer].to_owned() } else { kept })
          self.retrying = true
          break
        }
        self.retrying = false
        let now = (self.hr_now)()
        let due = match self.dropped_at {
          None => true
          Some(at) => now - at >= drop_warn_ns
        }
        if due {
          self.dropped_at = Some(now)
          (self.said)(
            "warn",
            "traces dropped",
            jobj([("error", jstr(message)), ("count", jnum(batch.length().to_double()))]),
          )
        }
        break
      }
    }
  }
  if self.spans.length() > 0 {
    self.arm()
  }
}

///|
/// Sends batches to `sink` (the control plane's).
pub fn Traces::export_to(self : Traces, sink : async (Array[Json]) -> Unit) -> Unit {
  self.sink = Some(sink)
}

///|
/// A batch of the mesh's spans as OTLP JSON, of `station` (`otlpBody`); `resource`: what else describes it, an empty key
/// or value left out.
pub fn otlp_body(station : String, spans : Array[Json], resource? : Array[(String, String)] = []) -> String {
  let attributes = [attribute("service.name", jstr("stillfail-mesh")), attribute("stillfail.station", jstr(station))]
  for kv in resource {
    if kv.0 != "" && kv.1 != "" {
      attributes.push(attribute(kv.0, jstr(kv.1)))
    }
  }
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
                Json::array(attributes),
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
