// The phones lent to this station's agents and the workspace's devices (station/src/adb/, station/src/devices/) in
// MoonBit. What is not these parts' own is the station's or the machine's, asked of the `World` by name with its
// arguments as the TypeScript gives them, answered as it answers (a value, or what it threw):
// - the station: `store.<name>` (the hub's store), `hub.<name>`, `chat.post`, `events.tell`, `cloud.<name>`, `log.*`;
// - the machine: `adb.run` (what adb says to its arguments), `proc.*` (a process of its own: a grant's adb server, a
//   chat's display's scrcpy), `net.*` (a listener of 127.0.0.1, a connection, its bytes), `fs.*`, `platform.*` (the
//   processes, their ports, their directories), `conn.*` and `stream.*` (a member's mesh connection and its streams);
// - time: `clock.sleep` (a wait of so many ms, called off with `clock.cancel`), and `now`, the clock as last told.
// The station gives its own (`host_world`, the shell's for the machine's); the harness asks the test, which answers from
// what the TypeScript runs against.

///|
using @session_chats {
  type Thrown,
  type Words,
  fail_,
  thrown_message,
  js,
  jn,
  ji,
  jb,
  jo,
  ja,
  jsa,
  jopt,
  at,
  at_i,
  str_of,
  num_of,
  arr_of,
  nullish,
  set_field,
  without,
  spread,
  stringify,
  jeq,
  parse_opt,
  truthy,
}

///|
using @jsjson {type JValue as J}

///|
/// What these parts ask of the station and the machine.
pub struct World {
  /// Asks `name` with `args`; what it threw raises `Thrown(kind, message)`.
  call : async (String, Array[J]) -> J
  /// A function given as an argument (a card restated, a check run inside a write): what stands for it.
  callback : (async (Array[J]) -> J) -> J
  /// The clock, in ms (`wall.now()`, a part's `now()`).
  now : () -> Double
  /// Work set going, not waited for (`void promise`).
  spawn : (async () -> Unit) -> Unit
  /// The station's words (client/i18n/catalog's station part).
  words : Words
  /// The station's own language (`stationLang`).
  mut lang : String
  /// The ids of its waits, for calling one off.
  mut timers : Int
}

///|
pub fn World::new(
  call : async (String, Array[J]) -> J,
  callback : (async (Array[J]) -> J) -> J,
  now : () -> Double,
  spawn : (async () -> Unit) -> Unit,
  words : Words,
) -> World {
  { call, callback, now, spawn, words, lang: "zh", timers: 0, }
}

///|
pub async fn World::ask(self : World, name : String, args : Array[J]) -> J {
  (self.call)(name, args)
}

///|
/// `hub.store.<name>(...args)`.
pub async fn World::store(self : World, name : String, args : Array[J]) -> J {
  self.ask("store." + name, args)
}

///|
/// What an ask says, or Null where it threw (a `.catch(() => null)`).
pub async fn World::try_ask(self : World, name : String, args : Array[J]) -> J {
  self.ask(name, args) catch {
    _ => Null
  }
}

///|
/// A wait of `ms` (`wall.sleep`, `Effect.sleep` on a part's clock).
pub async fn World::sleep(self : World, ms : Double) -> Unit {
  self.timers += 1
  let id = self.timers
  let done = Ref(false)
  // (a wait interrupted, as one that lost a race, is called off)
  defer (if !done.val {
    (self.spawn)(async fn() {
      ignore(self.ask("clock.cancel", [ji(id)])) catch {
        _ => ()
      }
    })
  })
  ignore(self.ask("clock.sleep", [jn(ms), ji(id)]))
  done.val = true
}

///|
/// `f` once, `ms` from now (`wall.after`); the function returned calls it off.
pub fn World::after(
  self : World,
  ms : Double,
  f : async () -> Unit,
) -> () -> Unit {
  self.timers += 1
  let id = self.timers
  let off = Ref(false)
  (self.spawn)(async fn() {
    let said = self.ask("clock.sleep", [jn(ms), ji(id)]) catch { _ => Null }
    if !off.val && !(said is Str(_)) {
      f()
    }
  })
  () => {
    if !off.val {
      off.val = true
      (self.spawn)(async fn() {
        ignore(self.ask("clock.cancel", [ji(id)])) catch {
          _ => ()
        }
      })
    }
  }
}

///|
/// Logged as the station logs: its level, part, words and fields.
pub async fn World::log(
  self : World,
  level : String,
  part : String,
  words : String,
  fields : J,
) -> Unit {
  ignore(self.ask("log." + level, [js(part), js(words), fields])) catch {
    _ => ()
  }
}

///|
/// The station's words in `lang` (i18n.ts `tr`).
pub fn World::tr(
  self : World,
  lang : String,
  key : String,
  args~ : Array[(String, String)] = [],
) -> String {
  self.words.tr(lang, key, args~)
}

///|
/// What a refusal of these parts is (`instanceof Refused`, `DeviceAsk`...): a Thrown of its kind.
pub fn refused(kind : String, message : String) -> Thrown {
  Thrown(kind, message)
}

///|
pub fn kind_of(e : Error) -> String {
  @session_chats.thrown_kind(e)
}

///|
pub fn message_of(e : Error) -> String {
  thrown_message(e)
}

// ── what reading a value goes by ──

///|
pub fn text_of(v : J?) -> String {
  str_of(v).unwrap_or("")
}

///|
/// A field of an object, Null where it has none.
pub fn get(v : J, name : String) -> J {
  at(Some(v), name).unwrap_or(Null)
}

///|
/// Whether an object has field `name` (`name in o`, `o.name !== undefined`).
pub fn has(v : J, name : String) -> Bool {
  at(Some(v), name) is Some(_)
}

///|
pub fn list_of(v : J?) -> Array[J] {
  arr_of(v).unwrap_or([])
}

///|
pub fn num_text(d : Double) -> String {
  @session_chats.num_text(d)
}

///|
pub fn int_text(i : Int) -> String {
  i.to_string()
}

///|
/// `JSON.stringify(v, null, 2)`.
pub fn pretty(v : J) -> String {
  @jsjson.stringify_indent(v, 2)
}

///|
/// The string's UTF-16 length (`s.length`).
pub fn js_length(s : String) -> Int {
  s.length()
}

///|
/// `s.slice(a, b)` by UTF-16 units.
pub fn js_slice(s : String, a : Int, b? : Int) -> String {
  @jsjson.js_slice(s, a, end?=b)
}

///|
/// `s.trim()` (JavaScript's white space and line ends).
pub fn js_trim(s : String) -> String {
  @jsjson.trim_js(s)
}

///|
/// What JSON a number is (`Number.isInteger`).
pub fn is_int(d : Double) -> Bool {
  !d.is_nan() && !d.is_inf() && d.floor() == d
}

///|
/// `Math.floor`.
pub fn floor(d : Double) -> Double {
  d.floor()
}

///|
/// The station's own language set (`setStationLang`).
pub fn World::set_lang(self : World, lang : String) -> Unit {
  self.lang = lang
}

///|
/// `Number(s)` of a string.
pub fn js_num(s : String) -> Double {
  if js_trim(s) == "" {
    0.0
  } else {
    @session_chats.js_number(js(s)).unwrap_or(@double.not_a_number)
  }
}
