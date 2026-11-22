// What the runtimes' live parsers (station/claude, codex, cursor, dsh, pi, acp) say alike, as station/src/agents/live.ts
// has it once: the JSON read as JSON.parse reads it, a live step's start, delta and end, a failed outcome. What one
// runtime says its own way (Claude's subagent parent, a runtime's failure reasons) stays in its package.

///|
using @jsjson {type JValue}

///|
pub fn jstr(s : String) -> JValue {
  Str(s)
}

///|
pub fn obj(fields : Array[(String, JValue)]) -> JValue {
  Obj(fields)
}

///|
/// `v?.name`.
pub fn field(v : JValue?, name : String) -> JValue? {
  match v {
    Some(Obj(_) as o) => o.get(name)
    _ => None
  }
}

///|
/// `str(v)`: the string it is.
pub fn str(v : JValue?) -> String? {
  match v {
    Some(Str(s)) => Some(s)
    _ => None
  }
}

///|
/// `nonEmpty(v)`.
pub fn non_empty(v : JValue?) -> String? {
  match v {
    Some(Str(s)) if s.length() > 0 => Some(s)
    _ => None
  }
}

///|
pub fn is_str(v : JValue?, s : String) -> Bool {
  v is Some(Str(t)) && t == s
}

///|
pub fn has_prefix(s : String, p : String) -> Bool {
  s.has_prefix(p)
}

///|
/// `v ?? fallback`: none or null is the fallback.
pub fn or_else(v : JValue?, fallback : JValue) -> JValue {
  match v {
    None | Some(Null) => fallback
    Some(x) => x
  }
}

///|
/// How much of a call's input a step is started with (live.ts `INPUT_MOST`).
pub const INPUT_MOST : Int32 = 262144

///|
/// live.ts `pretty`: JSON.stringify(v ?? {}, null, 2).
pub fn pretty(v : JValue?) -> String {
  @jsjson.stringify_pretty(or_else(v, Obj([])))
}

///|
pub fn joined(parts : Array[String], sep : String) -> String {
  parts.join(sep)
}

///|
/// A step's start as live.ts `start` makes it: what is none left out.
pub fn start(
  id : String,
  step : String,
  tool : String?,
  input : String?,
) -> JValue {
  let fields : Array[(String, JValue)] = [
    ("kind", jstr("start")),
    ("id", Str(id)),
    ("step", jstr(step)),
  ]
  if tool is Some(t) {
    fields.push(("tool", Str(t)))
  }
  if input is Some(i) {
    fields.push(("input", Str(i)))
  }
  obj(fields)
}

///|
pub fn delta(
  id : String,
  field_name : String,
  text : String,
) -> JValue {
  obj([
    ("kind", jstr("delta")),
    ("id", Str(id)),
    ("field", jstr(field_name)),
    ("text", Str(text)),
  ])
}

///|
pub fn end_event(id : String) -> JValue {
  obj([("kind", jstr("end")), ("id", Str(id))])
}

///|
/// A live event as a line the station is told.
pub fn live(e : JValue) -> JValue {
  obj([("type", jstr("live")), ("event", e)])
}

///|
/// A turn's failed outcome (runtime.ts `TurnOutcome`).
pub fn failed(reason : String, message : String) -> JValue {
  obj([
    ("kind", jstr("failed")),
    ("reason", jstr(reason)),
    ("message", Str(message)),
  ])
}

///|
pub fn completed() -> JValue {
  obj([("kind", jstr("completed"))])
}

///|
pub fn aborted() -> JValue {
  obj([("kind", jstr("aborted"))])
}

///|
pub fn turn_started() -> JValue {
  obj([("type", jstr("turnStarted"))])
}

///|
pub fn turn_ended(outcome : JValue) -> JValue {
  obj([("type", jstr("turnEnded")), ("outcome", outcome)])
}

///|
pub fn tools_lost_event(why : String) -> JValue {
  obj([("type", jstr("toolsLost")), ("why", Str(why))])
}

///|
pub fn find_entry(entries : Array[(String, String)], key : String) -> Int? {
  for i, e in entries {
    if e.0 == key {
      return Some(i)
    }
  }
  None
}

///|
/// `Map.set`: a key there keeps its place.
pub fn set_entry(entries : Array[(String, String)], key : String, val : String) -> Unit {
  match find_entry(entries, key) {
    Some(i) => entries[i] = (key, val)
    None => entries.push((key, val))
  }
}

///|
pub fn load_entries(state : JValue, key : String, entries : Array[(String, String)]) -> Unit {
  if state.get(key) is Some(Arr(items)) {
    for e in items {
      if e is Arr([Str(k), Str(v), ..]) {
        set_entry(entries, k, v)
      }
    }
  }
}

///|
pub fn entries_json(entries : Array[(String, String)]) -> JValue {
  Arr(entries.map(e => JValue::Arr([Str(e.0), Str(e.1)])))
}

///|
pub fn opt_str_json(v : String?) -> JValue {
  match v {
    Some(s) => Str(s)
    None => Null
  }
}

///|
pub fn transition(phase : String?, next : String, out : Array[JValue]) -> String? {
  if phase != Some(next) {
    out.push(obj([("kind", jstr("phase")), ("phase", jstr(next))]))
    Some(next)
  } else {
    phase
  }
}

///|
pub fn end_entry(open : Array[(String, String)], id : String, out : Array[JValue]) -> Unit {
  if find_entry(open, id) is Some(i) {
    ignore(open.remove(i))
    out.push(end_event(id))
  }
}

///|
pub fn end_open(open : Array[(String, String)]) -> Array[JValue] {
  let out = open.map(e => end_event(e.0))
  open.clear()
  out
}

///|
pub fn end_non_tool_prefix(open : Array[(String, String)], prefix : String, out : Array[JValue]) -> Unit {
  for e in open.copy() {
    if e.1 != "tool" && has_prefix(e.0, prefix) {
      end_entry(open, e.0, out)
    }
  }
}

///|
pub fn has_open_tool(open : Array[(String, String)]) -> Bool {
  open.iter().any(e => e.1 == "tool")
}

///|
/// runtime.ts `stationTool`: a call to one of the station's tools, by the name the station gives it.
pub fn station_tool(name : String) -> Bool {
  has_prefix(name, "mcp__stillfail__") || has_prefix(name, "stillfail__")
}

///|
pub fn str_or_js(v : JValue?) -> String {
  match v {
    None | Some(Null) => ""
    Some(x) => @jsjson.js_string(x)
  }
}

///|
pub fn content_text(content : JValue?, allow_str? : Bool = true) -> String {
  match content {
    Some(Str(s)) if allow_str => s
    Some(Arr(items)) => joined(items.map(c => str(field(Some(c), "text")).unwrap_or("")).filter(t => t.length() > 0), "\n")
    _ => ""
  }
}
