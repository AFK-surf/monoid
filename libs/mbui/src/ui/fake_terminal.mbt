// The Tester's terminals (hostapi/terminal.mbt): what a device's host keeps with libghostty-vt, kept here with its SGR
// colours, attributes and modes: the text written, line by line, CSI SGR sequences (`ESC [ … m`) applied to each cell's
// foreground, background and flags (bold 1, italic 2, underline 4, inverse 8, faint 16), DEC private modes `?1h`/`?1l`
// (`keys`) and `?2004h`/`?2004l` (`paste`) tracked, carriage returns and backspaces done, the last `rows` lines its
// screen.

///|
priv struct FakeCell {
  ch : Char
  fg : String
  bg : String
  flags : Int
}

///|
priv struct FakeTerminal {
  mut cols : Int
  mut rows : Int
  lines : Array[Array[FakeCell]]
  mut line : Array[FakeCell]
  mut at : Int
  mut fg : String
  mut bg : String
  mut flags : Int
  mut keys : Int
  mut paste : Int
}

///|
// kept across runs: a Tester's terminals by their ids, the next id (each run opens its own)
let fake_terminals : Map[Int, FakeTerminal] = Map([])

///|
// kept across runs: see fake_terminals
let fake_terminal_next : Ref[Int] = Ref(0)

///|
fn fake_ansi_colour(code : Int) -> String {
  match code {
    0 => "#2e3440"
    1 => "#e06c75"
    2 => "#98c379"
    3 => "#e5c07b"
    4 => "#61afef"
    5 => "#c678dd"
    6 => "#56b6c2"
    7 => "#abb2bf"
    8 => "#8a919e"
    9 => "#f47067"
    10 => "#b5cea8"
    11 => "#dcdcaa"
    12 => "#79c0ff"
    13 => "#d2a8ff"
    14 => "#76e3ea"
    _ => "#ffffff"
  }
}

///|
fn fake_hex2(n : Int) -> String {
  let v = if n < 0 { 0 } else if n > 255 { 255 } else { n }
  let hex = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f']
  String::from_array([hex[v / 16], hex[v % 16]])
}

///|
fn fake_apply_sgr(t : FakeTerminal, params : String) -> Unit {
  if params == "" {
    t.fg = ""
    t.bg = ""
    t.flags = 0
    return
  }
  let nums = params.split(";").collect().map(fn(s) {
    let mut v = 0
    for c in s {
      if c >= '0' && c <= '9' {
        v = v * 10 + (c.to_int() - '0'.to_int())
      }
    }
    v
  })
  let mut i = 0
  while i < nums.length() {
    let n = nums[i]
    match n {
      0 => {
        t.fg = ""
        t.bg = ""
        t.flags = 0
      }
      1 => t.flags = t.flags | 1
      2 => t.flags = t.flags | 16
      3 => t.flags = t.flags | 2
      4 => t.flags = t.flags | 4
      7 => t.flags = t.flags | 8
      22 => t.flags = t.flags & (1 | 16).lnot()
      23 => t.flags = t.flags & (2).lnot()
      24 => t.flags = t.flags & (4).lnot()
      27 => t.flags = t.flags & (8).lnot()
      30..=37 => t.fg = fake_ansi_colour(n - 30)
      39 => t.fg = ""
      40..=47 => t.bg = fake_ansi_colour(n - 40)
      49 => t.bg = ""
      90..=97 => t.fg = fake_ansi_colour(n - 90 + 8)
      100..=107 => t.bg = fake_ansi_colour(n - 100 + 8)
      38 if i + 4 < nums.length() && nums[i + 1] == 2 => {
        t.fg = "#" + fake_hex2(nums[i + 2]) + fake_hex2(nums[i + 3]) + fake_hex2(nums[i + 4])
        i += 4
      }
      48 if i + 4 < nums.length() && nums[i + 1] == 2 => {
        t.bg = "#" + fake_hex2(nums[i + 2]) + fake_hex2(nums[i + 3]) + fake_hex2(nums[i + 4])
        i += 4
      }
      _ => ()
    }
    i += 1
  }
}

///|
impl @hostapi.Host for FakeHost with tm_open(_, cols, rows) {
  fake_terminal_next.val += 1
  fake_terminals[fake_terminal_next.val] = {
    cols,
    rows,
    lines: [],
    line: [],
    at: 0,
    fg: "",
    bg: "",
    flags: 0,
    keys: 0,
    paste: 0,
  }
  fake_terminal_next.val
}

///|
impl @hostapi.Host for FakeHost with tm_write(_, id, data) {
  guard fake_terminals.get(id) is Some(t) else { return }
  let text = @utf8.decode_lossy(data)
  let cs = text.to_array()
  let mut i = 0
  while i < cs.length() {
    let c = cs[i]
    match c {
      '\u{1b}' => {
        // a sequence: CSI to its final byte, OSC to BEL or ST, else the one after it
        i += 1
        if i < cs.length() && cs[i] == '[' {
          i += 1
          let start = i
          while i < cs.length() && !(cs[i] >= '@' && cs[i] <= '~') {
            i += 1
          }
          if i < cs.length() {
            let final_ch = cs[i]
            let params = String::from_array(cs[start:i].to_owned())
            if final_ch == 'm' {
              fake_apply_sgr(t, params)
            } else if final_ch == 'h' || final_ch == 'l' {
              let on = if final_ch == 'h' { 1 } else { 0 }
              if params == "?1" {
                t.keys = on
              } else if params == "?2004" {
                t.paste = on
              }
            }
          }
        } else if i < cs.length() && cs[i] == ']' {
          while i < cs.length() && cs[i] != '\u{07}' && !(cs[i] == '\\' && cs[i - 1] == '\u{1b}') {
            i += 1
          }
        }
      }
      '\r' => t.at = 0
      '\n' => {
        t.lines.push(t.line)
        t.line = []
        t.at = 0
      }
      '\u{08}' => if t.at > 0 { t.at -= 1 }
      _ if c.to_int() < 0x20 => ()
      _ => {
        let cell : FakeCell = { ch: c, fg: t.fg, bg: t.bg, flags: t.flags }
        if t.at < t.line.length() {
          t.line[t.at] = cell
        } else {
          t.line.push(cell)
        }
        t.at += 1
      }
    }
    i += 1
  }
}

///|
impl @hostapi.Host for FakeHost with tm_resize(_, id, cols, rows) {
  guard fake_terminals.get(id) is Some(t) else { return }
  t.cols = cols
  t.rows = rows
}

///|
impl @hostapi.Host for FakeHost with tm_lines(_, id) {
  guard fake_terminals.get(id) is Some(t) else { return "" }
  let all = [..t.lines, t.line]
  let shown = if all.length() > t.rows { all[all.length() - t.rows:].to_owned() } else { all }
  let lines : Array[Json] = shown.map(fn(cells) {
    if cells.is_empty() {
      return Json::array([])
    }
    let runs : Array[Json] = []
    let buf = StringBuilder()
    let mut cur_fg = cells[0].fg
    let mut cur_bg = cells[0].bg
    let mut cur_flags = cells[0].flags
    for cell in cells {
      if cell.fg == cur_fg && cell.bg == cur_bg && cell.flags == cur_flags {
        buf.write_char(cell.ch)
      } else {
        runs.push(
          Json::array([
            Json::string(buf.to_string()),
            Json::string(cur_fg),
            Json::string(cur_bg),
            Json::number(cur_flags.to_double()),
          ]),
        )
        buf.reset()
        buf.write_char(cell.ch)
        cur_fg = cell.fg
        cur_bg = cell.bg
        cur_flags = cell.flags
      }
    }
    runs.push(
      Json::array([
        Json::string(buf.to_string()),
        Json::string(cur_fg),
        Json::string(cur_bg),
        Json::number(cur_flags.to_double()),
      ]),
    )
    Json::array(runs)
  })
  let y = shown.length() - 1
  let said : Map[String, Json] = Map([
    ("cols", Json::number(t.cols.to_double())),
    ("rows", Json::number(t.rows.to_double())),
    ("cursor", Json::array([Json::number(t.at.to_double()), Json::number(y.to_double()), Json::boolean(true)])),
    ("keys", Json::number(t.keys.to_double())),
    ("paste", Json::number(t.paste.to_double())),
    ("lines", Json::array(lines)),
  ])
  Json::object(said).stringify()
}

///|
impl @hostapi.Host for FakeHost with tm_close(_, id) {
  fake_terminals.remove(id)
}
