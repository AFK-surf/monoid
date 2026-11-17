// The rows of the Stats index and the Task index of what each station of the workspace gave (its `outflowUsage` and
// `outflowChats`), as the TypeScript station made them (station/test/reference/comma-stats.ts statsRowsOf,
// taskRowsOf): their keys and their JSON byte for byte, JSON.stringify's, so that a row unchanged is not sent again.

///|
/// The source the rows are of, as Comma's analysis names it.
const SOURCE : String = "stillfail"

///|
/// Comma keeps at most this many characters of a Task's title, and of its creator.
const MAX_TITLE : Int32 = 120

///|
const MAX_TEXT : Int32 = 200

///|
const MAX_WAITS : Int32 = 8

///|
const MAX_NOTE : Int32 = 300

///|
const MAX_URL : Int32 = 500

///|
/// A row a build writes: its kind and its JSON.
pub(all) struct Row {
  kind : String
  json : String
}

///|
/// Rows by key in the order a JavaScript Map keeps them (a key set again keeps its place, takes the new row); each key
/// kept as its code units.
pub struct Rows {
  order : Array[Array[Int32]]
  rows : Map[String, (Int32, Row)]
}

///|
pub fn Rows::new() -> Rows {
  { order: [], rows: Map([]), }
}

///|
fn Rows::set(self : Rows, key : Array[Int32], row : Row) -> Unit {
  let k = @jsjson.raw_text(key)
  match self.rows.get(k) {
    Some((at, _)) => self.rows[k] = (at, row)
    None => {
      self.rows[k] = (self.order.length(), row)
      self.order.push(key)
    }
  }
}

///|
/// Each key and row in order.
pub fn Rows::each(
  self : Rows,
  f : (Array[Int32], Row) -> Unit raise,
) -> Unit raise {
  for key in self.order {
    f(key, self.rows.get(@jsjson.raw_text(key)).unwrap().1)
  }
}

///|
pub fn Rows::length(self : Rows) -> Int32 {
  self.order.length()
}

///|
/// A property of `v` as `v?.name` reads it: none where it is undefined.
fn prop(v : @jsjson.JValue?, name : String) -> @jsjson.JValue? {
  match v {
    Some(Obj(_) as o) => o.get(name)
    _ => None
  }
}

///|
fn str(s : String) -> @jsjson.JValue {
  Str(units(s))
}

///|
/// `v ?? fallback`.
fn or(v : @jsjson.JValue?, fallback : @jsjson.JValue) -> @jsjson.JValue {
  match v {
    None | Some(Null) => fallback
    Some(x) => x
  }
}

///|
fn nonempty(v : @jsjson.JValue?) -> Array[Int32]? {
  match v {
    Some(Str(s)) if s.length() > 0 => Some(s)
    _ => None
  }
}

///|
/// An object of these fields in order, those undefined left out (as JSON.stringify leaves them).
fn object(fields : Array[(String, @jsjson.JValue?)]) -> @jsjson.JValue {
  let entries = []
  for f in fields {
    if f.1 is Some(v) {
      entries.push((units(f.0), v))
    }
  }
  Obj(entries)
}

///|
/// What Object.prototype gives a plain object for a name it does not have: a function, whose `name` is that name (the
/// constructor's, Object).
fn inherited(name : Array[Int32]) -> Bool {
  match @jsjson.raw_text(name) {
    "constructor"
    | "toString"
    | "toLocaleString"
    | "valueOf"
    | "hasOwnProperty"
    | "isPrototypeOf"
    | "propertyIsEnumerable"
    | "__defineGetter__"
    | "__defineSetter__"
    | "__lookupGetter__"
    | "__lookupSetter__" => true
    _ => false
  }
}

///|
/// Who a person is, as Comma counts them: their email, else their name, else `ref`.
fn who(person : @jsjson.JValue?, fallback : @jsjson.JValue) -> @jsjson.JValue {
  if nonempty(prop(person, "email")) is Some(e) {
    return Str(e)
  }
  if nonempty(prop(person, "name")) is Some(n) {
    return Str(n)
  }
  fallback
}

///|
/// `people[key]` of `outflowUsage`'s people, for `who`: a person, or Object.prototype's function of that name (its name
/// the person's then).
fn person_of(people : @jsjson.JValue, key : Array[Int32]) -> @jsjson.JValue? {
  match people {
    Obj(_) =>
      match people.get(@jsjson.raw_text(key)) {
        Some(p) => Some(p)
        None if inherited(key) =>
          Some(
            Obj([
              (
                units("name"),
                Str(
                  if equal_units(key, units("constructor")) {
                    units("Object")
                  } else {
                    key
                  },
                ),
              ),
            ]),
          )
        None => None
      }
    _ => None
  }
}

///|
/// `cut`: a non-empty string's first `max` code points; null for anything else.
fn cut(v : @jsjson.JValue?, max : Int32) -> @jsjson.JValue {
  match nonempty(v) {
    Some(s) => Str(cut_points(s, max))
    None => Null
  }
}

///|
/// `[...].join(SEP)`: null and undefined as nothing, the rest as String() says it.
fn join_key(parts : Array[@jsjson.JValue?]) -> Array[Int32] {
  let out = []
  for i, p in parts {
    if i > 0 {
      out.push(0)
    }
    match p {
      None | Some(Null) => ()
      Some(v) => out.append(@jsjson.js_string(v))
    }
  }
  out
}

///|
fn is_number(v : @jsjson.JValue?) -> Bool {
  v is Some(Num(_))
}

///|
fn chats_of(given : @jsjson.JValue) -> Array[@jsjson.JValue] raise {
  match given.get("chats") {
    Some(Arr(chats)) => chats
    _ => raise Failure("given.chats is not iterable")
  }
}

///|
/// One station's Stats index rows into `rows`, from the day `from_day` on.
pub fn stats_rows_of(
  rows : Rows,
  given : @jsjson.JValue,
  from_day : Array[Int32],
) -> Unit raise {
  let station = given.get("station")
  let at : Array[@jsjson.JValue?] = match station {
    None => []
    Some(s) => [Some(Str([0x40] + @jsjson.js_string(s)))]
  }
  let usage = given.get("usage")
  let people = or(prop(usage, "people"), Obj([]))
  let usage_rows = match prop(usage, "rows") {
    Some(Arr(items)) => items
    _ => []
  }
  for item in usage_rows {
    let r = Some(item)
    guard prop(r, "day") is Some(Str(day)) && prop(r, "session") is Some(Str(_)) else {
      continue
    }
    if compare_units(day, from_day) < 0 {
      continue
    }
    let person_ref = prop(r, "person")
    let person_key = match person_ref {
      None => units("undefined")
      Some(p) => @jsjson.js_string(p)
    }
    let row = object([
      ("day", prop(r, "day")),
      ("session", prop(r, "session")),
      ("thread", Some(or(prop(r, "thread"), Null))),
      ("person", Some(who(person_of(people, person_key), or(person_ref, Null)))),
      ("personRef", Some(or(person_ref, Null))),
      ("account", Some(or(prop(r, "account"), Null))),
      ("runtime", prop(r, "runtime")),
      ("model", Some(or(prop(r, "model"), Null))),
      ("calls", prop(r, "calls")),
      ("input", prop(r, "input")),
      ("cacheRead", prop(r, "cacheRead")),
      ("cacheWrite", prop(r, "cacheWrite")),
      ("output", prop(r, "output")),
      ("cost", Some(or(prop(r, "cost"), Null))),
      ("station", station),
    ])
    let key = join_key(
      [Some(str(SOURCE)), Some(str("usage"))] +
      at +
      [
        prop(r, "day"),
        prop(r, "session"),
        prop(r, "person"),
        prop(r, "account"),
        prop(r, "runtime"),
        prop(r, "model"),
      ],
    )
    rows.set(key, { kind: "usage", json: @jsjson.stringify(row), })
  }
  for c in chats_of(given) {
    let c = Some(c)
    guard is_number(prop(c, "thread")) else { continue }
    let creator = prop(c, "creator")
    let row = object([
      ("thread", prop(c, "thread")),
      ("surface", Some(or(prop(c, "surface"), str("unknown")))),
      ("title", Some(or(prop(c, "title"), str("")))),
      ("state", Some(or(prop(c, "state"), Null))),
      (
        "creator",
        Some(
          match creator {
            None | Some(Null) => @jsjson.Null
            Some(_) => who(creator, or(prop(creator, "ref"), Null))
          },
        ),
      ),
      ("createdAt", Some(or(prop(c, "createdAt"), Num(0.0)))),
      ("lastActiveAt", Some(or(prop(c, "lastActiveAt"), Num(0.0)))),
      ("archived", Some(Bool(prop(c, "archived") is Some(Bool(true))))),
      ("agents", Some(or(prop(c, "agents"), Arr([])))),
      ("station", station),
    ])
    let key = join_key(
      [Some(str(SOURCE)), Some(str("task"))] + at + [prop(c, "thread")],
    )
    rows.set(key, { kind: "task", json: @jsjson.stringify(row), })
  }
}

///|
/// A chat's state as a Comma Task's status.
fn status_of(c : @jsjson.JValue?) -> String {
  if prop(c, "archived") is Some(Bool(true)) {
    return "archived"
  }
  match prop(c, "state") {
    Some(Str(s)) =>
      match @jsjson.raw_text(s) {
        "need_human" => "needs_review"
        "all_done" | "ended" => "done"
        _ => "in_progress"
      }
    _ => "in_progress"
  }
}

///|
/// `^[^\s@]+@[^\s@]+$`.
fn email_like(s : Array[Int32]) -> Bool {
  let mut at = -1
  for i, c in s {
    if white(c) {
      return false
    }
    if c == 0x40 {
      if at >= 0 {
        return false
      }
      at = i
    }
  }
  at > 0 && at < s.length() - 1
}

///|
/// What a chat asks of whom now as a Task index row's fields.
fn attention_fields(c : @jsjson.JValue?) -> Array[(String, @jsjson.JValue?)] {
  let a = prop(c, "attention")
  guard !(prop(c, "archived") is Some(Bool(true))) &&
    prop(a, "kind") is Some(Str(kind)) else {
    return []
  }
  guard @jsjson.raw_text(kind) is ("need" | "done" | "failed") else {
    return []
  }
  let waits : Array[Array[Int32]] = []
  if prop(a, "waitsFor") is Some(Arr(items)) {
    for w in items {
      let email = match w {
        Str(s) => lower(trim(s))
        _ => []
      }
      if email_like(email) &&
        email.length() <= MAX_TEXT &&
        waits.length() < MAX_WAITS {
        if !waits.iter().any(e => equal_units(e, email)) {
          waits.push(email)
        }
      }
    }
  }
  let note = match prop(a, "note") {
    Some(Str(s)) => cut(Some(Str(trim(s))), MAX_NOTE)
    _ => Null
  }
  [
    ("attention", Some(Str(kind))),
    (
      "waits_for",
      if waits.length() > 0 {
        Some(Arr(waits.map(e => Str(e))))
      } else {
        None
      },
    ),
    ("note", if note is Null { None } else { Some(note) }),
  ]
}

///|
/// One station's Task index rows into `rows`, by their chat's ref.
pub fn task_rows_of(rows : Rows, given : @jsjson.JValue) -> Unit raise {
  let station = given.get("station")
  for c in chats_of(given) {
    let c = Some(c)
    guard prop(c, "thread") is Some(Num(_) as thread) else { continue }
    let task_ref = match station {
      None => @jsjson.js_string(thread)
      Some(s) => @jsjson.js_string(thread) + [0x40] + @jsjson.js_string(s)
    }
    let agent = match prop(c, "agents") {
      Some(Arr(items)) if items.length() > 0 => Some(items[0])
      _ => None
    }
    let creator = prop(c, "creator")
    let created_by = match creator {
      None | Some(Null) => @jsjson.Null
      Some(_) =>
        cut(Some(who(creator, or(prop(creator, "ref"), Null))), MAX_TEXT)
    }
    let title = match cut(prop(c, "title"), MAX_TITLE) {
      Null => str("")
      t => t
    }
    let url = match prop(c, "url") {
      Some(Str(u)) if u.length() <= MAX_URL &&
        u.length() >= 8 &&
        equal_units(u[0:8].to_owned(), units("https://")) =>
        Some(@jsjson.Str(u))
      _ => None
    }
    let fields : Array[(String, @jsjson.JValue?)] = [
      ("task", Some(Str(task_ref))),
      ("title", Some(title)),
      ("status", Some(str(status_of(c)))),
      ("surface", Some(or(prop(c, "surface"), str("unknown")))),
      ("created_by", Some(created_by)),
      ("created_at", Some(or(prop(c, "createdAt"), Num(0.0)))),
      (
        "last_activity_at",
        Some(or(prop(c, "lastActiveAt"), or(prop(c, "createdAt"), Num(0.0)))),
      ),
      ("runtime", Some(cut(prop(agent, "runtime"), 40))),
      ("model", Some(cut(prop(agent, "model"), 120))),
      ("station", station),
    ]
    let row = object(
      fields +
      attention_fields(c) +
      [
        ("url", url),
        (
          "router",
          if prop(c, "router") is Some(Bool(true)) {
            Some(Bool(true))
          } else {
            None
          },
        ),
      ],
    )
    rows.set(task_ref, { kind: "task", json: @jsjson.stringify(row), })
  }
}
