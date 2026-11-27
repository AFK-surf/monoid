// A station's terminals as a made-up core gives them: three on ws1/st1 (one typed into by someone else, one nobody
// looks at, one idle), and a terminal's view: its state, then its screen (scrollback build log + box-drawing CJK table
// + syntax-highlighted TypeScript) within 42 columns so narrow phones hold every row cleanly without wrapping.

///|
/// The `terminals` topic: ws1/st1's three in the terminals' own modes (and 远程's Maple, ws1/st2, one), another station's
/// none; in any other mode not known (a station from before terminals, as a device's host keeps none yet: what the
/// Mac's own run of a mode shows, screens_wbtest's text recorded there).
fn fixture_terminals(station : String, mode : String) -> Json {
  if mode != "settings-station-terminals" &&
    mode != "terminal" &&
    !mode.has_prefix("terminal-") &&
    !mode.has_prefix("place-remote") &&
    !mode.has_prefix("chat-remote") &&
    mode != "chat-terminal-side" {
    return Json::object(Map([("terminals", Json::array([])), ("outdated", Json::boolean(false)), ("open", Json::boolean(false)), ("known", Json::boolean(false)), ("confirmed", Json::boolean(false))]))
  }
  let some = station == "ws1/st1"
  let item = fn(id : String, by : String, cwd : String, typing : String, looking : Array[String]) -> Json {
    let o : Map[String, Json] = Map([
      ("id", Json::string(id)),
      ("by", Json::string(by)),
      ("at", Json::number(1794650000000.0)),
      ("cwd", Json::string(cwd)),
      ("looking", Json::array(looking.map(Json::string))),
    ])
    if typing != "" {
      o["typing"] = Json::string(typing)
    }
    Json::object(o)
  }
  let terminals : Array[Json] = if some {
    [
      item("term-1", "左子健", "~/still.fail/station", "左子健", ["彭晓"]),
      item("term-2", "左子健", "~/still.fail", "", []),
      item("term-3", "彭晓", "~", "", []),
    ]
  } else if station == "ws1/st2" && mode.has_prefix("place-remote") {
    // (远程's Maple, online beside Willow: one terminal open on it)
    [item("term-m1", "左子健", "~/maple-worker", "", [])]
  } else {
    []
  }
  // (远程's ＋: a terminal made this run, listed after the station's own: fixture_terminal_view)
  if mode.has_prefix("place-remote") {
    for id in @settings.fixture_remote_made(station) {
      if !id.has_prefix("browser:") {
        terminals.push(item(id, "左子健", fixture_terminal_made_cwd, "", []))
      }
    }
  }
  Json::object(Map([("terminals", Json::array(terminals)), ("outdated", Json::boolean(false)), ("open", Json::boolean(true)), ("known", Json::boolean(true)), ("confirmed", Json::boolean(true))]))
}

///|
/// A terminal's output stream as the station gives it: 28 earlier build/check lines (forming real scrollback history on
/// phone and desktop viewports) followed by a box-drawing + CJK alignment summary and syntax-highlighted code lines
/// keeping `import { Effect }` inside the active viewport even when the 18-row mobile 按键 panel is open.
let fixture_terminal_screen : String =
  "\u{1b}[32m❯\u{1b}[0m pnpm --filter station check\r\n" +
  "\u{1b}[90m[01/24]\u{1b}[0m sync protocol schemas        \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[02/24]\u{1b}[0m check mesh transport         \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[03/24]\u{1b}[0m check relay framing          \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[04/24]\u{1b}[0m check vault grants           \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[05/24]\u{1b}[0m check drive snapshots        \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[06/24]\u{1b}[0m check runner pty ring        \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[07/24]\u{1b}[0m check conpty win32 bridge    \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[08/24]\u{1b}[0m check ghostty-vt wasm        \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[09/24]\u{1b}[0m check dirty-row encoder      \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[10/24]\u{1b}[0m check cjk wide-cell grid     \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[11/24]\u{1b}[0m check sgr mouse reporting    \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[12/24]\u{1b}[0m check scrollback viewport    \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[13/24]\u{1b}[0m check selection formatter    \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[14/24]\u{1b}[0m check ime preedit anchor     \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[15/24]\u{1b}[0m check resize reflow          \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[16/24]\u{1b}[0m check session state sync     \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[17/24]\u{1b}[0m check audio & screen mux     \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[18/24]\u{1b}[0m check sqlite wal checkpoint  \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[19/24]\u{1b}[0m check workspace peers        \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[20/24]\u{1b}[0m check bundle integrity       \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[21/24]\u{1b}[0m check release manifest       \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[22/24]\u{1b}[0m check cli smoke suite        \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[23/24]\u{1b}[0m check web preview assets     \u{1b}[32mok\u{1b}[0m\r\n" +
  "\u{1b}[90m[24/24]\u{1b}[0m all 24 checks passed (1.4s)\r\n" +
  "\u{1b}[90m┌──────────┬────────────┬────────┐\u{1b}[0m\r\n" +
  "\u{1b}[90m│\u{1b}[0m 模块名称 \u{1b}[90m│\u{1b}[0m 状态       \u{1b}[90m│\u{1b}[0m 耗时   \u{1b}[90m│\u{1b}[0m\r\n" +
  "\u{1b}[90m├──────────┼────────────┼────────┤\u{1b}[0m\r\n" +
  "\u{1b}[90m│\u{1b}[0m 远程终端 \u{1b}[90m│\u{1b}[0m \u{1b}[32m● 运行正常\u{1b}[0m \u{1b}[90m│\u{1b}[0m  0.8ms \u{1b}[90m│\u{1b}[0m\r\n" +
  "\u{1b}[90m│\u{1b}[0m 增量渲染 \u{1b}[90m│\u{1b}[0m \u{1b}[36m● 脏行复用\u{1b}[0m \u{1b}[90m│\u{1b}[0m  0.2ms \u{1b}[90m│\u{1b}[0m\r\n" +
  "\u{1b}[90m└──────────┴────────────┴────────┘\u{1b}[0m\r\n" +
  "\u{1b}[90m  1 \u{1b}[35mimport\u{1b}[0m { \u{1b}[36mEffect\u{1b}[0m } \u{1b}[35mfrom\u{1b}[0m \u{1b}[32m\"effect\"\u{1b}[0m;\r\n" +
  "\u{1b}[90m  2 \u{1b}[35mimport\u{1b}[0m { \u{1b}[36mmakeMesh\u{1b}[0m } \u{1b}[35mfrom\u{1b}[0m \u{1b}[32m\"./mesh.ts\"\u{1b}[0m;\r\n" +
  "\u{1b}[90m  3 \u{1b}[35mimport\u{1b}[0m { \u{1b}[36mterminals\u{1b}[0m } \u{1b}[35mfrom\u{1b}[0m \u{1b}[32m\"./terms.ts\"\u{1b}[0m;\r\n" +
  "\u{1b}[90m  4 \u{1b}[35mconst\u{1b}[0m \u{1b}[34mmain\u{1b}[0m = \u{1b}[36mEffect\u{1b}[0m.\u{1b}[33mgen\u{1b}[0m(\u{1b}[35mfunction*\u{1b}[0m () {\r\n" +
  "\u{1b}[90m  5 \u{1b}[0m  \u{1b}[35mconst\u{1b}[0m \u{1b}[34mmesh\u{1b}[0m = \u{1b}[35myield*\u{1b}[0m \u{1b}[36mmakeMesh\u{1b}[0m;\r\n" +
  "\u{1b}[33m  6 \u{1b}[0m  \u{1b}[35myield*\u{1b}[0m \u{1b}[33mterminals\u{1b}[0m(\u{1b}[34mmesh\u{1b}[0m);\r\n" +
  "\u{1b}[90m  7 \u{1b}[0m});\r\n" +
  "\u{1b}[1;30;44m NORMAL \u{1b}[0;37;40m src/main.ts         6,3  Bot \u{1b}[0m\r\n" +
  "\u{1b}[32m~/still.fail/station\u{1b}[0m \u{1b}[36mmain\u{1b}[0m \u{1b}[32m❯\u{1b}[0m git status -sb"

///|
/// Where a terminal 远程's ＋ makes starts (place-remote modes), and its first screen: its prompt alone.
let fixture_terminal_made_cwd : String = "~/still.fail/app"

///|
let fixture_terminal_made_screen : String = "\u{1b}[32m~/still.fail/app\u{1b}[0m \u{1b}[36mmain\u{1b}[0m \u{1b}[32m❯\u{1b}[0m "

///|
/// `terminal.view`: who types (the view itself, unless it asked to look, or `term-1`'s someone else), then the screen;
/// in 远程's modes (`mode` place-remote) a `new` one is made on its station, listed from now on, and shows its prompt.
fn fixture_terminal_view(params : Json, on_value : (Json, Bytes?) -> Unit, mode? : String = "") -> Int {
  let p = Some(params)
  let made = mode.has_prefix("place-remote") && text(p, "terminal") == "new"
  let id = match text(p, "terminal") { "new" => "term-9"; t => t }
  if made {
    @settings.fixture_remote_made_said(text(p, "station"), id)
  }
  let fresh = mode.has_prefix("place-remote") && @settings.fixture_remote_made(text(p, "station")).contains(id)
  let others = id == "term-1"
  let ended = id == "term-ended"
  let types = !others && !ended && params is Object(o) && o.get("control") is Some(True)
  let cols_req = number(p, "cols")
  let rows_req = number(p, "rows")
  let state : Map[String, Json] = Map([
    ("phase", Json::string(if ended { "ended" } else { "live" })),
    ("id", Json::string(id)),
    ("types", Json::boolean(types)),
    ("looking", Json::array(if others { [Json::string("彭晓")] } else { [] })),
    ("cols", Json::number(if cols_req > 0.0 { cols_req } else { 80.0 })),
    ("rows", Json::number(if rows_req > 0.0 { rows_req } else { 24.0 })),
    ("cwd", Json::string(if fresh { fixture_terminal_made_cwd } else { "~/still.fail/station" })),
  ])
  state["typing"] = if others { Json::string("左子健") } else if types { Json::string("Ann") } else { Json::null() }
  on_value(Json::object(Map([("state", Json::object(state))])), None)
  on_value(Json::object(Map([("screen", Json::boolean(true))])), Some(@utf8.encode(if fresh { fixture_terminal_made_screen } else { fixture_terminal_screen })))
  fix_stream_ids.val += 1
  fix_stream_ids.val
}
