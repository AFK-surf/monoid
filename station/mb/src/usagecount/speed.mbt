// How long each call took, from when its model was asked to the last of what it wrote, as its transcript tells it
// (test/usage-counter-reference.ts `Speed`, which this is held to): Claude Code's from the line that asked (a person's
// message, a tool's result, a request sent) to each line of its response (a block written); Codex's from what asked
// (a turn begun, a person's message, a tool's output) to the last item it wrote before its token count. What Profile
// overview's 输出速度 is read of (usage.gen_ms, gen_output: store/usage-15m.ts). Where a reading stands is kept with the
// transcript's position (usage_files.speed), so that a response read in two parts is timed from its start.

///|
/// The longest a call is taken to have run: one longer is no call's alone (a pause the transcript does not tell).
let gen_most : Double = 1800000.0

///|
/// Upper bound of JS safe integers (`Number.MAX_SAFE_INTEGER`), enforced on timestamps and token counts so
/// MoonBit (`js_number`) and JS serialization stay exact without truncation or float loss.
let max_safe_int : Double = 9007199254740991.0

///|
/// Version prefix for Antigravity speed cursor persistence (`usage_files.speed`), distinguishing timed agy files
/// from legacy `,,,` / NULL rows so recent agy history is backfilled once.
let agy_speed_prefix : String = "v1:"

///|
/// Outlier sample guard for Antigravity speed settlement (tok/s): filters corrupted segments from `session/load`
/// history replays or concurrent subagent/steer overlap (not a physical model speed limit).
let agy_max_tps : Double = 500.0

///|
/// Tolerance (ms) for cross-process millisecond quantization jitter (`startedAt > time`) on instant tools.
let agy_tool_skew_ms : Double = 5.0

///|
let agy_max_usages : Int = 64

///|
let agy_max_tools : Int = 2048

///|
let agy_max_id_bytes : Int = 256

///|
/// Hard byte ceiling for serialized `usage_files.speed` (256 KiB), strictly above the worst-case structural bound:
/// - wrapper `v1:{"s":<16d>,"u":[...],"t":[...]}`: < 40 B
/// - 64 usages * (256 B id * 6x worst-case JSON \u00xx escaping + quotes/brackets + 16d time + 16d output) ~= 100,736 B (~98.4 KiB)
/// - 2048 tools * (`[` + 16d + `,` + 16d + `],` = 36 B) = 73,728 B (~72.0 KiB)
/// Total worst-case ~= 174,504 B (~170.4 KiB) < 262,144 B, so any valid in-memory state is chunk-split invariant.
let agy_max_speed_bytes : Int = 262144

///|
pub(all) struct AgyPendingUsage {
  id : String
  at : Double
  /// Recorded output tokens for outlier sample guard; None (e.g. legacy 2-tuple) skips timing this segment.
  output : Double?
}

///|
pub(all) struct AgyToolInterval {
  start : Double
  end : Double
}

///|
pub(all) struct AgySpeed {
  mut turn_start : Double?
  mut invalid : Bool
  usages : Array[AgyPendingUsage]
  tools : Array[AgyToolInterval]
}

///|
/// reference `Speed`.
pub(all) struct Speed {
  mut since : Double?
  mut open_start : Double?
  mut open_id : String?
  mut ended : Double?
  mut agy : AgySpeed?
}

///|
fn no_speed() -> Speed {
  { since: None, open_start: None, open_id: None, ended: None, agy: None }
}

///|
fn is_timed_runtime(runtime : String) -> Bool {
  runtime == "claude" || runtime == "codex" || runtime == "agy"
}

///|
fn needs_timing(runtime : String, speed : String?) -> Bool {
  match runtime {
    "claude" | "codex" => speed is None
    "agy" =>
      match speed {
        None => true
        Some(t) => !t.has_prefix(agy_speed_prefix)
      }
    _ => false
  }
}

///|
fn agy_invalidate(agy : AgySpeed) -> Unit {
  agy.turn_start = None
  agy.invalid = true
  agy.usages.clear()
  agy.tools.clear()
}

///|
fn agy_add_tool(agy : AgySpeed, start : Double, end : Double) -> Unit {
  if end <= start {
    return
  }
  let mut s = start
  let mut e = end
  let out : Array[AgyToolInterval] = []
  let mut inserted = false
  for iv in agy.tools {
    if iv.end < s {
      out.push(iv)
    } else if e < iv.start {
      if !inserted {
        out.push({ start: s, end: e })
        inserted = true
      }
      out.push(iv)
    } else {
      if iv.start < s {
        s = iv.start
      }
      if iv.end > e {
        e = iv.end
      }
    }
  }
  if !inserted {
    out.push({ start: s, end: e })
  }
  if out.length() > agy_max_tools {
    agy_invalidate(agy)
  } else {
    agy.tools.clear()
    for iv in out {
      agy.tools.push(iv)
    }
  }
}

///|
fn agy_add_usage(agy : AgySpeed, id : String, at : Double, output : Double?) -> Unit {
  if agy.usages.iter().any(p => p.id == id) {
    return
  }
  if @utf8.encode(id).length() > agy_max_id_bytes || agy.usages.length() >= agy_max_usages {
    agy_invalidate(agy)
    return
  }
  agy.usages.push({ id, at, output })
}

///|
/// Net generation time in `[from, to]` excluding sorted disjoint `tools`.
/// Checks `gen_most` on each continuous non-tool gap (not the whole multi-tool prompt sum), returning 0.0 if
/// `to <= from` or any single non-tool gap exceeds `gen_most`.
fn agy_segment_gen_ms(tools : Array[AgyToolInterval], from : Double, to : Double) -> Double {
  if to <= from {
    return 0.0
  }
  let mut cursor = from
  let mut net = 0.0
  for iv in tools {
    if iv.end <= from {
      continue
    }
    if iv.start >= to {
      break
    }
    if iv.start > cursor {
      let gap = iv.start - cursor
      if gap > gen_most {
        return 0.0
      }
      net += gap
    }
    if iv.end > cursor {
      cursor = min_d(iv.end, to)
    }
  }
  if to > cursor {
    let gap = to - cursor
    if gap > gen_most {
      return 0.0
    }
    net += gap
  }
  net
}

///|
fn agy_speed_text(agy : AgySpeed) -> String {
  if agy.invalid {
    return "v1:!"
  }
  guard agy.turn_start is Some(ts) else { return agy_speed_prefix }
  let buf = StringBuilder::new()
  buf.write_string("v1:{\"s\":")
  buf.write_string(js_number(ts))
  buf.write_string(",\"u\":[")
  for i, u in agy.usages {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_char('[')
    buf.write_string(Json::string(u.id).stringify())
    buf.write_char(',')
    buf.write_string(js_number(u.at))
    buf.write_char(',')
    match u.output {
      Some(o) => buf.write_string(js_number(o))
      None => buf.write_string("null")
    }
    buf.write_char(']')
  }
  buf.write_string("],\"t\":[")
  for i, iv in agy.tools {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_char('[')
    buf.write_string(js_number(iv.start))
    buf.write_char(',')
    buf.write_string(js_number(iv.end))
    buf.write_char(']')
  }
  buf.write_string("]}")
  let text = buf.to_string()
  if @utf8.encode(text).length() > agy_max_speed_bytes {
    agy_invalidate(agy)
    return "v1:!"
  }
  text
}

///|
/// usage_files.speed (reference `speedText`): the four, comma-separated, empty for none; None where none is known.
fn speed_text(s : Speed) -> String? {
  if s.agy is Some(agy) {
    if agy.invalid || agy.turn_start is Some(_) {
      return Some(agy_speed_text(agy))
    }
    return None
  }
  if s.since is None && s.open_start is None && s.open_id is None && s.ended is None {
    return None
  }
  let n = (v : Double?) => match v {
    Some(d) => js_number(d)
    None => ""
  }
  Some(n(s.since) + "," + n(s.open_start) + "," + n(s.ended) + "," + s.open_id.unwrap_or(""))
}

///|
/// usage_files.speed as this counter keeps it (reference `keptSpeed`): none known kept as `,,,` (`speed_of`: none), so
/// that NULL is only ever a transcript read before calls were timed, timed again as a counter starts.
fn kept_speed(s : Speed) -> String {
  speed_text(s).unwrap_or(",,,")
}

///|
fn kept_speed_for(runtime : String, s : Speed) -> String {
  if runtime == "agy" {
    match s.agy {
      Some(agy) => agy_speed_text(agy)
      None => agy_speed_prefix
    }
  } else {
    kept_speed(s)
  }
}

///|
fn valid_safe_int(v : Json?) -> Double? {
  match v {
    Some(Number(d, ..)) if !d.is_nan() && !d.is_inf() && d >= 0.0 && d <= max_safe_int && d == d.floor() => Some(d)
    _ => None
  }
}

///|
fn valid_time(v : Json?) -> Double? {
  valid_safe_int(v)
}

///|
fn agy_speed_of(body : String) -> AgySpeed? {
  if body == "" {
    return None
  }
  if body == "!" {
    return Some({ turn_start: None, invalid: true, usages: [], tools: [] })
  }
  let invalid = () => Some({ turn_start: None, invalid: true, usages: [], tools: [] })
  guard parse_line(body) is Some(r) else { return invalid() }
  let rec = Some(r)
  guard valid_time(get(rec, "s")) is Some(ts) else { return invalid() }
  let agy : AgySpeed = { turn_start: Some(ts), invalid: false, usages: [], tools: [] }
  match get(rec, "u") {
    Some(Array(items)) => {
      if items.length() > agy_max_usages {
        return invalid()
      }
      for item in items {
        guard item is Array(pair) && (pair.length() == 2 || pair.length() == 3) else { return invalid() }
        guard str(Some(pair[0])) is Some(id) && valid_time(Some(pair[1])) is Some(at) else { return invalid() }
        if @utf8.encode(id).length() > agy_max_id_bytes {
          return invalid()
        }
        let output = if pair.length() == 2 {
          None
        } else {
          match pair[2] {
            Null => None
            other =>
              match valid_safe_int(Some(other)) {
                Some(o) => Some(o)
                None => return invalid()
              }
          }
        }
        agy.usages.push({ id, at, output })
      }
    }
    None => ()
    _ => return invalid()
  }
  match get(rec, "t") {
    Some(Array(items)) => {
      if items.length() > agy_max_tools {
        return invalid()
      }
      let mut prev_end : Double? = None
      for item in items {
        guard item is Array(pair) && pair.length() == 2 else { return invalid() }
        guard valid_time(Some(pair[0])) is Some(s) && valid_time(Some(pair[1])) is Some(e) && e > s else {
          return invalid()
        }
        if prev_end is Some(pe) && !(pe < s) {
          return invalid()
        }
        agy.tools.push({ start: s, end: e })
        prev_end = Some(e)
      }
    }
    None => ()
    _ => return invalid()
  }
  Some(agy)
}

///|
/// reference `speedOf`.
fn speed_of(text : String?) -> Speed {
  guard text is Some(t) else { return no_speed() }
  if t.has_prefix(agy_speed_prefix) {
    if @utf8.encode(t).length() > agy_max_speed_bytes {
      return {
        since: None,
        open_start: None,
        open_id: None,
        ended: None,
        agy: Some({ turn_start: None, invalid: true, usages: [], tools: [] }),
      }
    }
    let body = t.view(start_offset=agy_speed_prefix.length()).to_owned()
    return { since: None, open_start: None, open_id: None, ended: None, agy: agy_speed_of(body) }
  }
  let parts : Array[String] = t.split(",").map(p => p.to_owned()).collect()
  let id = if parts.length() > 3 { parts[3:].to_owned().join(",") } else { "" }
  {
    since: whole_ms(parts, 0),
    open_start: whole_ms(parts, 1),
    ended: whole_ms(parts, 2),
    open_id: if id == "" { None } else { Some(id) },
    agy: None,
  }
}

///|
/// The `i`th of a speed's numbers: whole milliseconds, as `speed_text` writes them.
fn whole_ms(parts : Array[String], i : Int) -> Double? {
  if i >= parts.length() || parts[i] == "" {
    return None
  }
  let mut v = 0.0
  let mut sign = 1.0
  for c in parts[i] {
    if c == '-' {
      sign = -1.0
    } else if c >= '0' && c <= '9' {
      v = v * 10.0 + (c.to_int() - '0'.to_int()).to_double()
    } else {
      return None
    }
  }
  Some(sign * v)
}

///|
let timestamp_key : Bytes = b"\"timestamp\":\""

///|
let payload_key : Bytes = b"\"payload\":{\"type\":\""

///|
let api_request : Bytes = b"{\"type\":\"api-request\""

///|
let user_entry : Bytes = b"\"type\":\"user\",\"message\":{\"role\":\"user\""

///|
let response_item : Bytes = b"\"type\":\"response_item\""

///|
/// Where `p` first is in `b` (ASCII), from `from`.
fn index_of(b : BytesView, p : Bytes, from? : Int = 0) -> Int? {
  let m = p.length()
  let last = b.length() - m
  let mut i = from
  while i <= last {
    let mut j = 0
    while j < m && b[i + j] == p[j] {
      j += 1
    }
    if j == m {
      return Some(i)
    }
    i += 1
  }
  None
}

///|
/// The text after `key` up to its closing quote (reference `stampOf`'s and `payloadType`'s).
fn quoted_after(line : BytesView, key : Bytes) -> String? {
  guard index_of(line, key) is Some(at) else { return None }
  let start = at + key.length()
  let mut end = start
  while end < line.length() && line[end] != b'"' {
    end += 1
  }
  if end >= line.length() {
    return None
  }
  Some(@utf8.decode_lossy(line[start:end]))
}

///|
/// A line's own time (its first "timestamp"), where it says one.
fn stamp_of(line : BytesView) -> Double? {
  match quoted_after(line, timestamp_key) {
    Some(s) => parse_iso(s)
    None => None
  }
}

///|
/// The time from `start` to `end` as a call's, or 0: not known, or none a call takes alone.
fn gen_of(start : Double?, end : Double?) -> Double {
  match (start, end) {
    (Some(s), Some(e)) if e > s && e - s <= gen_most => e - s
    _ => 0.0
  }
}

///|
fn codex_asked(t : String) -> Bool {
  t == "task_started" ||
  t == "user_message" ||
  t == "function_call_output" ||
  t == "custom_tool_call_output" ||
  t == "local_shell_call_output"
}

///|
fn codex_writes(t : String) -> Bool {
  t == "reasoning" ||
  t == "function_call" ||
  t == "custom_tool_call" ||
  t == "local_shell_call" ||
  t == "web_search_call"
}

///|
/// When the model was asked, and (Codex) when it wrote, read of each line, those that hold no usage too.
fn speed_line(runtime : String, line : BytesView, speed : Speed) -> Unit {
  match runtime {
    "claude" =>
      if begins(line, api_request) || holds(line, user_entry) {
        if stamp_of(line) is Some(t) {
          speed.since = Some(t)
        }
      }
    "codex" =>
      match quoted_after(line, payload_key) {
        Some(t) if codex_asked(t) =>
          if stamp_of(line) is Some(at) {
            speed.since = Some(at)
          }
        Some(t) if codex_writes(t) ||
          (t == "message" &&
          holds(line, response_item) &&
          str(get(get(parse_line(@utf8.decode_lossy(line)), "payload"), "role")) == Some("assistant")) =>
          if stamp_of(line) is Some(at) {
            if speed.open_start is None {
              speed.open_start = speed.since
            }
            speed.ended = Some(at)
          }
        _ => ()
      }
    _ => ()
  }
}
