// What the runtimes' live parsers (station/claude, codex, cursor, dsh, pi, acp) say alike, as station/src/agents/live.ts
// has it once: the JSON read as JSON.parse reads it, a live step's start, delta and end, a failed outcome. What one
// runtime says its own way (Claude's subagent parent, a runtime's failure reasons) stays in its package.

///|
using @jsjson {type JValue}

///|
pub fn u(s : String) -> Array[Int32] {
  @jsjson.units(s)
}

///|
pub fn jstr(s : String) -> JValue {
  Str(u(s))
}

///|
pub fn obj(fields : Array[(String, JValue)]) -> JValue {
  Obj(fields.map(f => (u(f.0), f.1)))
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
pub fn str(v : JValue?) -> Array[Int32]? {
  match v {
    Some(Str(s)) => Some(s)
    _ => None
  }
}

///|
/// `nonEmpty(v)`.
pub fn non_empty(v : JValue?) -> Array[Int32]? {
  match v {
    Some(Str(s)) if s.length() > 0 => Some(s)
    _ => None
  }
}

///|
pub fn is_str(v : JValue?, s : String) -> Bool {
  v is Some(Str(t)) && t == u(s)
}

///|
pub fn has_prefix(s : Array[Int32], p : Array[Int32]) -> Bool {
  s.length() >= p.length() && s[0:p.length()].to_owned() == p
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
pub fn pretty(v : JValue?) -> Array[Int32] {
  u(@jsjson.stringify_pretty(or_else(v, Obj([]))))
}

///|
pub fn joined(parts : Array[Array[Int32]], sep : Array[Int32]) -> Array[Int32] {
  let out = []
  for i, p in parts {
    if i > 0 {
      out.append(sep)
    }
    out.append(p)
  }
  out
}

///|
/// A step's start as live.ts `start` makes it: what is none left out.
pub fn start(
  id : Array[Int32],
  step : String,
  tool : Array[Int32]?,
  input : Array[Int32]?,
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
  id : Array[Int32],
  field_name : String,
  text : Array[Int32],
) -> JValue {
  obj([
    ("kind", jstr("delta")),
    ("id", Str(id)),
    ("field", jstr(field_name)),
    ("text", Str(text)),
  ])
}

///|
pub fn end_event(id : Array[Int32]) -> JValue {
  obj([("kind", jstr("end")), ("id", Str(id))])
}

///|
/// A live event as a line the station is told.
pub fn live(e : JValue) -> JValue {
  obj([("type", jstr("live")), ("event", e)])
}

///|
/// A turn's failed outcome (runtime.ts `TurnOutcome`).
pub fn failed(reason : String, message : Array[Int32]) -> JValue {
  obj([
    ("kind", jstr("failed")),
    ("reason", jstr(reason)),
    ("message", Str(message)),
  ])
}
