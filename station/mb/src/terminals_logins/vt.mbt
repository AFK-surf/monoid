// A terminal with no display, as a login's run reads its command's screen (station/src/logins/run.ts gave it to
// @xterm/headless 6.0.0): the parts of xterm.js that make what a login's screen shows and what it answers the program,
// ported from its sources (common/parser/EscapeSequenceParser.ts, Params.ts, OscParser.ts, DcsParser.ts,
// common/InputHandler.ts, common/buffer/{Buffer,BufferLine}.ts, common/services/{BufferService,CharsetService,
// CoreService}.ts, common/input/{UnicodeV6,TextDecoder}.ts) case for case: the VT500 parser's table, every CSI, ESC
// and execute handler xterm.js registers that changes the cells, the cursor or the modes, and the answers it gives
// (DA1, DA2, DSR, DECDSR, DECRQM, DECRQSS). What has nothing to show in text (colours and the rest of SGR, titles,
// hyperlinks, the mouse's modes but as DECRQM reports them, the cursor's style) is kept only so far as an answer says
// it. The text of a row is BufferLine.translateToString(true) of `lines[ybase + row]`; the cursor is the buffer's
// x and y as xterm.js keeps them (x may be the width itself: the next print wraps). test/mb-terminals-logins.test.ts
// holds it to @xterm/headless on the same writes.

///|
const WIDTH_SHIFT : Int = 22

///|
const CODEPOINT_MASK : Int = 0x1FFFFF

///|
const IS_COMBINED : Int = 0x200000

///|
const HAS_CONTENT : Int = 0x3FFFFF

///|
/// A null cell: no code point, one column.
const NULL_CELL : Int = 0x400000

///|
const PAYLOAD_LIMIT : Int = 10000000

///|
const MAX_PARAM : Int = 0x7FFFFFFF

///|
priv struct Line {
  data : FixedArray[Int]
  combined : FixedArray[String]
  prot : FixedArray[Bool]
  mut wrapped : Bool
}

///|
fn Line::blank(cols : Int, wrapped : Bool) -> Line {
  {
    data: FixedArray::make(cols, NULL_CELL),
    combined: FixedArray::make(cols, ""),
    prot: FixedArray::make(cols, false),
    wrapped,
  }
}

///|
fn Line::len(self : Line) -> Int {
  self.data.length()
}

///|
/// A cell's content as the typed array xterm.js keeps it reads it: none (0) past its ends.
fn Line::at(self : Line, i : Int) -> Int {
  if i >= 0 && i < self.data.length() {
    self.data[i]
  } else {
    0
  }
}

///|
fn Line::width(self : Line, i : Int) -> Int {
  self.at(i) >> WIDTH_SHIFT
}

///|
fn Line::has_content(self : Line, i : Int) -> Bool {
  (self.at(i) & HAS_CONTENT) != 0
}

///|
/// (a write past its ends, as a typed array's, is none)
fn Line::set_cp(self : Line, i : Int, cp : Int, width : Int, prot : Bool) -> Unit {
  if i >= 0 && i < self.data.length() {
    self.data[i] = cp | (width << WIDTH_SHIFT)
    self.prot[i] = prot
  }
}

///|
/// setCell of a fill cell (no code point combined): `content` and its protection.
fn Line::set_fill(self : Line, i : Int, content : Int, prot : Bool) -> Unit {
  if i >= 0 && i < self.data.length() {
    self.data[i] = content
    self.prot[i] = prot
  }
}

///|
fn Line::copy_cell(self : Line, to : Int, from : Int) -> Unit {
  let c = self.data[from]
  if (c & IS_COMBINED) != 0 {
    self.combined[to] = self.combined[from]
  }
  self.data[to] = c
  self.prot[to] = self.prot[from]
}

///|
fn Line::add_codepoint(self : Line, i : Int, cp : Int, width : Int) -> Unit {
  if i < 0 || i >= self.data.length() {
    return
  }
  let mut content = self.data[i]
  if (content & IS_COMBINED) != 0 {
    self.combined[i] = self.combined[i] + from_cp(cp)
  } else if (content & CODEPOINT_MASK) != 0 {
    self.combined[i] = from_cp(content & CODEPOINT_MASK) + from_cp(cp)
    content = content & CODEPOINT_MASK.lnot()
    content = content | IS_COMBINED
  } else {
    content = cp | (1 << WIDTH_SHIFT)
  }
  if width != 0 {
    content = content & (3 << WIDTH_SHIFT).lnot()
    content = content | (width << WIDTH_SHIFT)
  }
  self.data[i] = content
}

///|
fn Line::insert_cells(self : Line, at : Int, n : Int, prot : Bool) -> Unit {
  let len = self.len()
  let pos = at % len
  if pos != 0 && self.width(pos - 1) == 2 {
    self.set_cp(pos - 1, 0, 1, prot)
  }
  if n < len - pos {
    for i = len - pos - n - 1; i >= 0; i = i - 1 {
      self.copy_cell(pos + n + i, pos + i)
    }
    for i in 0..<n {
      self.set_fill(pos + i, NULL_CELL, prot)
    }
  } else {
    for i in pos..<len {
      self.set_fill(i, NULL_CELL, prot)
    }
  }
  if self.width(len - 1) == 2 {
    self.set_cp(len - 1, 0, 1, prot)
  }
}

///|
fn Line::delete_cells(self : Line, at : Int, n : Int, prot : Bool) -> Unit {
  let len = self.len()
  let pos = at % len
  if n < len - pos {
    for i in 0..<(len - pos - n) {
      self.copy_cell(pos + i, pos + n + i)
    }
    for i in (len - n)..<len {
      self.set_fill(i, NULL_CELL, prot)
    }
  } else {
    for i in pos..<len {
      self.set_fill(i, NULL_CELL, prot)
    }
  }
  if pos != 0 && self.width(pos - 1) == 2 {
    self.set_cp(pos - 1, 0, 1, prot)
  }
  if self.width(pos) == 0 && !self.has_content(pos) {
    self.set_cp(pos, 0, 1, prot)
  }
}

///|
/// replaceCells with the erase cell (never protected).
fn Line::replace_cells(self : Line, from : Int, end : Int, respect : Bool) -> Unit {
  let len = self.len()
  let mut start = from
  if respect {
    if start != 0 && self.width(start - 1) == 2 && !self.prot[start - 1] {
      self.set_cp(start - 1, 0, 1, false)
    }
    if end < len && self.width(end - 1) == 2 && !self.prot[end] {
      self.set_cp(end, 0, 1, false)
    }
    while start < end && start < len {
      if !self.prot[start] {
        self.set_fill(start, NULL_CELL, false)
      }
      start += 1
    }
    return
  }
  if start != 0 && self.width(start - 1) == 2 {
    self.set_cp(start - 1, 0, 1, false)
  }
  if end < len && self.width(end - 1) == 2 {
    self.set_cp(end, 0, 1, false)
  }
  while start < end && start < len {
    self.set_fill(start, NULL_CELL, false)
    start += 1
  }
}

///|
fn Line::fill(self : Line, content : Int, prot : Bool, respect : Bool) -> Unit {
  for i in 0..<self.len() {
    if !respect || !self.prot[i] {
      self.set_fill(i, content, prot)
    }
  }
}

///|
fn Line::trimmed_length(self : Line) -> Int {
  for i = self.len() - 1; i >= 0; i = i - 1 {
    if (self.data[i] & HAS_CONTENT) != 0 {
      return i + (self.data[i] >> WIDTH_SHIFT)
    }
  }
  0
}

///|
fn Line::text(self : Line, trim : Bool) -> String {
  let end = if trim { @cmp.minimum(self.len(), self.trimmed_length()) } else { self.len() }
  let out = StringBuilder::new()
  let mut col = 0
  while col < end {
    let content = self.data[col]
    let cp = content & CODEPOINT_MASK
    if (content & IS_COMBINED) != 0 {
      out.write_string(self.combined[col])
    } else if cp != 0 {
      out.write_string(from_cp(cp))
    } else {
      out.write_char(' ')
    }
    let w = content >> WIDTH_SHIFT
    col += if w == 0 { 1 } else { w }
  }
  out.to_string()
}

///|
fn from_cp(cp : Int) -> String {
  if cp >= 0xD800 && cp <= 0xDFFF {
    // a lone surrogate as JavaScript's String.fromCodePoint keeps it: one code unit
    String::from_array([Int::unsafe_to_char(cp)])
  } else {
    Int::unsafe_to_char(cp).to_string()
  }
}

///|
/// A buffer (xterm.js's Buffer): its lines (a circular list of `most` at most), where the viewport starts, the cursor,
/// the scroll region, the tab stops, what DECSC kept.
priv struct Buf {
  mut lines : Array[Line]
  most : Int
  mut ybase : Int
  mut x : Int
  mut y : Int
  mut top : Int
  mut bottom : Int
  mut tabs : Map[Int, Bool]
  mut saved_x : Int
  mut saved_y : Int
  mut saved_prot : Bool
  mut saved_charset : Int?
}

///|
fn Buf::new(cols : Int, rows : Int, most : Int) -> Buf {
  let b : Buf = {
    lines: [],
    most,
    ybase: 0,
    x: 0,
    y: 0,
    top: 0,
    bottom: rows - 1,
    tabs: {},
    saved_x: 0,
    saved_y: 0,
    saved_prot: false,
    saved_charset: None,
  }
  b.setup_tabs(cols)
  b
}

///|
fn Buf::setup_tabs(self : Buf, cols : Int) -> Unit {
  self.tabs = {}
  let mut i = 0
  while i < cols {
    self.tabs[i] = true
    i += 8
  }
}

///|
fn Buf::fill_viewport(self : Buf, cols : Int, rows : Int) -> Unit {
  if self.lines.length() == 0 {
    for _ in 0..<rows {
      self.push(Line::blank(cols, false))
    }
  }
}

///|
fn Buf::is_full(self : Buf) -> Bool {
  self.lines.length() == self.most
}

///|
fn Buf::push(self : Buf, l : Line) -> Unit {
  self.lines.push(l)
  if self.lines.length() > self.most {
    self.lines.remove(0) |> ignore
  }
}

///|
fn Buf::get(self : Buf, i : Int) -> Line? {
  if i >= 0 && i < self.lines.length() {
    Some(self.lines[i])
  } else {
    None
  }
}

///|
/// CircularList.splice(start, deleteCount, ...items), the oldest let go past `most`.
fn Buf::splice(self : Buf, start : Int, delete : Int, items : Array[Line]) -> Unit {
  let len = self.lines.length()
  let s = @cmp.minimum(start, len)
  let mut d = delete
  if d > len - s {
    d = @cmp.maximum(0, len - s)
  }
  for _ in 0..<d {
    self.lines.remove(s) |> ignore
  }
  let at = @cmp.minimum(start, self.lines.length())
  for k, item in items {
    self.lines.insert(at + k, item)
  }
  while self.lines.length() > self.most {
    self.lines.remove(0) |> ignore
  }
}

///|
/// CircularList.shiftElements(start, count, offset).
fn Buf::shift(self : Buf, start : Int, count : Int, offset : Int) -> Unit {
  if count <= 0 {
    return
  }
  if offset > 0 {
    for i = count - 1; i >= 0; i = i - 1 {
      self.set(start + i + offset, self.lines[start + i])
    }
    let expand = start + count + offset - self.lines.length()
    if expand > 0 {
      // (set already grew it)
      while self.lines.length() > self.most {
        self.lines.remove(0) |> ignore
      }
    }
  } else {
    for i in 0..<count {
      self.set(start + i + offset, self.lines[start + i])
    }
  }
}

///|
fn Buf::set(self : Buf, i : Int, l : Line) -> Unit {
  while self.lines.length() <= i {
    self.lines.push(Line::blank(l.len(), false))
  }
  self.lines[i] = l
}

///|
fn Buf::next_stop(self : Buf, cols : Int) -> Int {
  let mut x = self.x
  x += 1
  while !self.tabs.get(x).unwrap_or(false) && x < cols {
    x += 1
  }
  if x >= cols {
    cols - 1
  } else if x < 0 {
    0
  } else {
    x
  }
}

///|
fn Buf::prev_stop(self : Buf, cols : Int) -> Int {
  let mut x = self.x
  x -= 1
  while !self.tabs.get(x).unwrap_or(false) && x > 0 {
    x -= 1
  }
  if x >= cols {
    cols - 1
  } else if x < 0 {
    0
  } else {
    x
  }
}

///|
priv enum State {
  Ground
  Escape
  EscapeIntermediate
  CsiEntry
  CsiParam
  CsiIntermediate
  CsiIgnore
  SosPmApc
  OscString
  DcsEntry
  DcsParam
  DcsIgnore
  DcsIntermediate
  DcsPassthrough
}

///|
priv enum Action {
  Ignore
  Error
  Print
  Execute
  OscStart
  OscPut
  OscEnd
  CsiDispatch
  Param
  Collect
  EscDispatch
  Clear
  DcsHook
  DcsPut
  DcsUnhook
}

///|
const NON_ASCII : Int = 0xA0

///|
fn is_executable(c : Int) -> Bool {
  (c >= 0 && c < 0x18) || c == 0x19 || (c >= 0x1c && c < 0x20)
}

///|
/// The VT500 table (EscapeSequenceParser's VT500_TRANSITION_TABLE): what `code` (0xA0 for any past 0x9f) does in
/// `state`, and where it goes.
fn transition(state : State, c : Int) -> (Action, State) {
  // anywhere
  if c == 0x18 || c == 0x1a || c == 0x99 || c == 0x9a || (c >= 0x80 && c < 0x90) || (c >= 0x91 && c < 0x98) {
    match state {
      OscString if c == 0x18 || c == 0x1a => return (OscEnd, Ground)
      DcsPassthrough if c == 0x18 || c == 0x1a => return (DcsUnhook, Ground)
      _ => return (Execute, Ground)
    }
  }
  if c == 0x9c {
    match state {
      OscString => return (OscEnd, Ground)
      DcsPassthrough => return (DcsUnhook, Ground)
      _ => return (Ignore, Ground)
    }
  }
  if c == 0x1b {
    match state {
      OscString => return (OscEnd, Ground)
      DcsPassthrough => return (DcsUnhook, Ground)
      _ => return (Clear, Escape)
    }
  }
  if c == 0x9d {
    return (OscStart, OscString)
  }
  if c == 0x98 || c == 0x9e || c == 0x9f {
    return (Ignore, SosPmApc)
  }
  if c == 0x9b {
    return (Clear, CsiEntry)
  }
  if c == 0x90 {
    return (Clear, DcsEntry)
  }
  let printable = c >= 0x20 && c < 0x7f
  match state {
    Ground =>
      if printable || c == NON_ASCII {
        (Print, Ground)
      } else if is_executable(c) {
        (Execute, Ground)
      } else {
        (Error, Ground)
      }
    Escape =>
      if is_executable(c) {
        (Execute, Escape)
      } else if c == 0x7f {
        (Ignore, Escape)
      } else if c == 0x5d {
        (OscStart, OscString)
      } else if c == 0x58 || c == 0x5e || c == 0x5f {
        (Ignore, SosPmApc)
      } else if c == 0x5b {
        (Clear, CsiEntry)
      } else if c == 0x50 {
        (Clear, DcsEntry)
      } else if c >= 0x20 && c < 0x30 {
        (Collect, EscapeIntermediate)
      } else if (c >= 0x30 && c < 0x50) ||
        (c >= 0x51 && c < 0x58) ||
        c == 0x59 ||
        c == 0x5a ||
        c == 0x5c ||
        (c >= 0x60 && c < 0x7f) {
        (EscDispatch, Ground)
      } else {
        (Error, Ground)
      }
    EscapeIntermediate =>
      if is_executable(c) {
        (Execute, EscapeIntermediate)
      } else if c == 0x7f {
        (Ignore, EscapeIntermediate)
      } else if c >= 0x20 && c < 0x30 {
        (Collect, EscapeIntermediate)
      } else if c >= 0x30 && c < 0x7f {
        (EscDispatch, Ground)
      } else {
        (Error, Ground)
      }
    OscString =>
      if c == 0x07 {
        (OscEnd, Ground)
      } else if is_executable(c) {
        (Ignore, OscString)
      } else if printable || c == 0x7f || c == NON_ASCII {
        (OscPut, OscString)
      } else {
        (Error, Ground)
      }
    SosPmApc =>
      if printable || is_executable(c) || c == 0x7f {
        (Ignore, SosPmApc)
      } else {
        (Error, Ground)
      }
    CsiEntry =>
      if is_executable(c) {
        (Execute, CsiEntry)
      } else if c == 0x7f {
        (Ignore, CsiEntry)
      } else if c >= 0x40 && c < 0x7f {
        (CsiDispatch, Ground)
      } else if c >= 0x30 && c < 0x3c {
        (Param, CsiParam)
      } else if c >= 0x3c && c <= 0x3f {
        (Collect, CsiParam)
      } else if c >= 0x20 && c < 0x30 {
        (Collect, CsiIntermediate)
      } else {
        (Error, Ground)
      }
    CsiParam =>
      if is_executable(c) {
        (Execute, CsiParam)
      } else if c == 0x7f {
        (Ignore, CsiParam)
      } else if c >= 0x30 && c < 0x3c {
        (Param, CsiParam)
      } else if c >= 0x40 && c < 0x7f {
        (CsiDispatch, Ground)
      } else if c >= 0x3c && c <= 0x3f {
        (Ignore, CsiIgnore)
      } else if c >= 0x20 && c < 0x30 {
        (Collect, CsiIntermediate)
      } else {
        (Error, Ground)
      }
    CsiIgnore =>
      if is_executable(c) {
        (Execute, CsiIgnore)
      } else if (c >= 0x20 && c < 0x40) || c == 0x7f || c == NON_ASCII {
        (Ignore, CsiIgnore)
      } else if c >= 0x40 && c < 0x7f {
        (Ignore, Ground)
      } else {
        (Error, Ground)
      }
    CsiIntermediate =>
      if is_executable(c) {
        (Execute, CsiIntermediate)
      } else if c == 0x7f {
        (Ignore, CsiIntermediate)
      } else if c >= 0x20 && c < 0x30 {
        (Collect, CsiIntermediate)
      } else if c >= 0x30 && c < 0x40 {
        (Ignore, CsiIgnore)
      } else if c >= 0x40 && c < 0x7f {
        (CsiDispatch, Ground)
      } else {
        (Error, Ground)
      }
    DcsEntry =>
      if is_executable(c) || c == 0x7f {
        (Ignore, DcsEntry)
      } else if c >= 0x20 && c < 0x30 {
        (Collect, DcsIntermediate)
      } else if c >= 0x30 && c < 0x3c {
        (Param, DcsParam)
      } else if c >= 0x3c && c <= 0x3f {
        (Collect, DcsParam)
      } else if c >= 0x40 && c < 0x7f {
        (DcsHook, DcsPassthrough)
      } else {
        (Error, Ground)
      }
    DcsIgnore =>
      if is_executable(c) || (c >= 0x20 && c < 0x80) || c == NON_ASCII {
        (Ignore, DcsIgnore)
      } else {
        (Error, Ground)
      }
    DcsParam =>
      if is_executable(c) || c == 0x7f {
        (Ignore, DcsParam)
      } else if c >= 0x30 && c < 0x3c {
        (Param, DcsParam)
      } else if c >= 0x3c && c <= 0x3f {
        (Ignore, DcsIgnore)
      } else if c >= 0x20 && c < 0x30 {
        (Collect, DcsIntermediate)
      } else if c >= 0x40 && c < 0x7f {
        (DcsHook, DcsPassthrough)
      } else {
        (Error, Ground)
      }
    DcsIntermediate =>
      if is_executable(c) || c == 0x7f {
        (Ignore, DcsIntermediate)
      } else if c >= 0x20 && c < 0x30 {
        (Collect, DcsIntermediate)
      } else if c >= 0x30 && c < 0x40 {
        (Ignore, DcsIgnore)
      } else if c >= 0x40 && c < 0x7f {
        (DcsHook, DcsPassthrough)
      } else {
        (Error, Ground)
      }
    DcsPassthrough =>
      if is_executable(c) || printable || c == NON_ASCII {
        (DcsPut, DcsPassthrough)
      } else if c == 0x7f {
        (Ignore, DcsPassthrough)
      } else {
        (Error, Ground)
      }
  }
}

///|
/// The parameters of a sequence (Params): the top-level ones only, their sub-parameters (after `:`) counted but not
/// kept (nothing here reads them).
priv struct Params {
  values : Array[Int]
  /// How many sub-parameters each has.
  subcount : Array[Int]
  mut reject : Bool
  mut sub : Bool
  mut subs : Int
}

///|
fn Params::reset(self : Params) -> Unit {
  self.values.clear()
  self.subcount.clear()
  self.reject = false
  self.sub = false
  self.subs = 0
}

///|
fn Params::add(self : Params, v : Int) -> Unit {
  self.sub = false
  if self.values.length() >= 32 {
    self.reject = true
    return
  }
  self.values.push(v)
  self.subcount.push(0)
}

///|
fn Params::add_sub(self : Params) -> Unit {
  self.sub = true
  if self.values.length() == 0 {
    return
  }
  if self.reject || self.subs >= 32 {
    // (what follows it is not kept: no sub-parameter is read here)
    return
  }
  self.subs += 1
  self.subcount[self.subcount.length() - 1] += 1
}

///|
fn Params::digit(self : Params, d : Int) -> Unit {
  if self.reject {
    return
  }
  if self.sub {
    // (a sub-parameter's digits: not kept)
    return
  }
  let n = self.values.length()
  if n == 0 {
    return
  }
  let cur = self.values[n - 1]
  let next = cur.to_int64() * 10L + d.to_int64()
  self.values[n - 1] = if next > MAX_PARAM.to_int64() { MAX_PARAM } else { next.to_int() }
}

///|
/// `params.params[i]` (0 past what was given, as the Int32Array xterm.js reuses reads where it is not stale: what is
/// read past `length` is only read where xterm.js guards it).
fn Params::at(self : Params, i : Int) -> Int {
  if i < self.values.length() {
    self.values[i]
  } else {
    0
  }
}

///|
fn Params::length(self : Params) -> Int {
  self.values.length()
}

///|
fn or1(n : Int) -> Int {
  if n == 0 {
    1
  } else {
    n
  }
}

///|
/// The terminal.
pub struct Vt {
  priv cols : Int
  priv rows : Int
  priv scrollback : Int
  priv mut normal : Buf
  priv mut alt : Buf
  priv mut active_alt : Bool
  // parser
  priv mut state : State
  priv params : Params
  priv mut collect : Int
  priv mut preceding : Int
  priv mut interim : Int
  priv mut osc_state : Int
  priv mut osc_id : Int
  priv osc_data : StringBuilder
  priv mut osc_limit : Bool
  priv mut dcs_ident : Int?
  priv dcs_data : StringBuilder
  priv mut dcs_limit : Bool
  // modes
  priv mut insert : Bool
  priv mut convert_eol : Bool
  priv mut app_cursor : Bool
  priv mut app_keypad : Bool
  priv mut bracketed : Bool
  priv mut origin : Bool
  priv mut reverse_wrap : Bool
  priv mut send_focus : Bool
  priv mut sync_output : Bool
  priv mut wrap : Bool
  priv mut cursor_hidden : Bool
  priv mut cursor_blink_option : Bool
  priv mut mouse_protocol : String
  priv mut mouse_encoding : String
  // attributes: only whether what is written now is protected (DECSCA)
  priv mut prot : Bool
  // charsets
  priv mut charset : Int?
  priv mut glevel : Int
  priv charsets : Map[Int, Int?]
  // what is told
  priv mut on_data : (String) -> Unit
  priv osc_handlers : Map[Int, Array[(String) -> Bool]]
}

///|
/// A terminal of `cols` × `rows` keeping `scrollback` lines above them (as `new Terminal({cols, rows, scrollback})`).
pub fn Vt::new(cols : Int, rows : Int, scrollback : Int) -> Vt {
  let normal = Buf::new(cols, rows, rows + scrollback)
  normal.fill_viewport(cols, rows)
  {
    cols,
    rows,
    scrollback,
    normal,
    alt: Buf::new(cols, rows, rows),
    active_alt: false,
    state: Ground,
    params: { values: [0], subcount: [0], reject: false, sub: false, subs: 0 },
    collect: 0,
    preceding: 0,
    interim: 0,
    osc_state: 0,
    osc_id: -1,
    osc_data: StringBuilder::new(),
    osc_limit: false,
    dcs_ident: None,
    dcs_data: StringBuilder::new(),
    dcs_limit: false,
    insert: false,
    convert_eol: false,
    app_cursor: false,
    app_keypad: false,
    bracketed: false,
    origin: false,
    reverse_wrap: false,
    send_focus: false,
    sync_output: false,
    wrap: true,
    cursor_hidden: false,
    cursor_blink_option: false,
    mouse_protocol: "NONE",
    mouse_encoding: "DEFAULT",
    prot: false,
    charset: None,
    glevel: 0,
    charsets: {},
    on_data: _ => (),
    osc_handlers: {},
  }
}

///|
/// What it answers the program (onData).
pub fn Vt::on_data(self : Vt, f : (String) -> Unit) -> Unit {
  self.on_data = f
}

///|
/// An OSC handler of the caller's (registerOscHandler): tried before the ones registered before it; one that takes
/// the sequence says true.
pub fn Vt::osc(self : Vt, id : Int, f : (String) -> Bool) -> Unit {
  match self.osc_handlers.get(id) {
    Some(a) => a.push(f)
    None => self.osc_handlers[id] = [f]
  }
}

///|
fn Vt::buf(self : Vt) -> Buf {
  if self.active_alt {
    self.alt
  } else {
    self.normal
  }
}

///|
/// The row `i` of the screen as `buffer.active.getLine(baseY + i).translateToString(true)` gives it ("" past its lines).
pub fn Vt::row(self : Vt, i : Int) -> String {
  let b = self.buf()
  match b.get(b.ybase + i) {
    Some(l) => l.text(true)
    None => ""
  }
}

///|
/// Whether row `i` goes on from the row above it (xterm.js's `IBufferLine.isWrapped`): the terminal wrapped a line too
/// long for its width there.
pub fn Vt::row_wrapped(self : Vt, i : Int) -> Bool {
  let b = self.buf()
  match b.get(b.ybase + i) {
    Some(l) => l.wrapped
    None => false
  }
}

///|
pub fn Vt::cursor_x(self : Vt) -> Int {
  self.buf().x
}

///|
pub fn Vt::cursor_y(self : Vt) -> Int {
  self.buf().y
}

///|
pub fn Vt::rows(self : Vt) -> Int {
  self.rows
}

///|
fn Vt::reply(self : Vt, s : String) -> Unit {
  (self.on_data)(s)
}

///|
/// What the program wrote (a JavaScript string, decoded as StringToUtf32 decodes it: a pair of surrogates one code
/// point, a high one at the end kept for the next write, a byte order mark dropped), parsed.
pub fn Vt::write(self : Vt, text : String) -> Unit {
  let n = text.length()
  if n == 0 {
    return
  }
  let codes : Array[Int] = []
  let mut i = 0
  if self.interim != 0 {
    let second = text.code_unit_at(0).to_int()
    if second >= 0xDC00 && second <= 0xDFFF {
      codes.push((self.interim - 0xD800) * 0x400 + second - 0xDC00 + 0x10000)
    } else {
      codes.push(self.interim)
      codes.push(second)
    }
    self.interim = 0
    i = 1
  }
  while i < n {
    let code = text.code_unit_at(i).to_int()
    if code >= 0xD800 && code <= 0xDBFF {
      i += 1
      if i >= n {
        self.interim = code
        break
      }
      let second = text.code_unit_at(i).to_int()
      if second >= 0xDC00 && second <= 0xDFFF {
        codes.push((code - 0xD800) * 0x400 + second - 0xDC00 + 0x10000)
      } else {
        codes.push(code)
        codes.push(second)
      }
      i += 1
      continue
    }
    if code != 0xFEFF {
      codes.push(code)
    }
    i += 1
  }
  self.parse(codes)
}

///|
fn Vt::clear_seq(self : Vt) -> Unit {
  self.params.reset()
  self.params.add(0)
  self.collect = 0
}

///|
fn Vt::parse(self : Vt, data : Array[Int]) -> Unit {
  let length = data.length()
  let mut i = 0
  while i < length {
    let code = data[i]
    let (action, next0) = transition(self.state, if code < 0xa0 { code } else { NON_ASCII })
    let mut next = next0
    match action {
      Print => {
        let mut j = i + 1
        while j < length {
          let c = data[j]
          if c < 0x20 || (c > 0x7e && c < NON_ASCII) {
            break
          }
          j += 1
        }
        self.print(data, i, j)
        i = j - 1
      }
      Execute => {
        self.execute(code)
        self.preceding = 0
      }
      Ignore | Error => ()
      CsiDispatch => {
        self.csi(self.collect << 8 | code)
        self.preceding = 0
      }
      Param => {
        let mut c = code
        while true {
          if c == 0x3b {
            self.params.add(0)
          } else if c == 0x3a {
            self.params.add_sub()
          } else {
            self.params.digit(c - 48)
          }
          i += 1
          if i < length {
            c = data[i]
            if c > 0x2f && c < 0x3c {
              continue
            }
          }
          break
        }
        i -= 1
      }
      Collect => self.collect = (self.collect << 8) | code
      EscDispatch => {
        self.esc(self.collect << 8 | code)
        self.preceding = 0
      }
      Clear => self.clear_seq()
      DcsHook => self.dcs_hook(self.collect << 8 | code)
      DcsPut => {
        let mut j = i + 1
        while j < length {
          let c = data[j]
          if c == 0x18 || c == 0x1a || c == 0x1b || (c > 0x7f && c < NON_ASCII) {
            break
          }
          j += 1
        }
        self.dcs_put(data, i, j)
        i = j - 1
      }
      DcsUnhook => {
        self.dcs_unhook(code != 0x18 && code != 0x1a)
        if code == 0x1b {
          next = Escape
        }
        self.clear_seq()
        self.preceding = 0
      }
      OscStart => self.osc_start()
      OscPut => {
        let mut j = i + 1
        while j < length {
          let c = data[j]
          if c < 0x20 || (c > 0x7f && c < NON_ASCII) {
            break
          }
          j += 1
        }
        self.osc_put(data, i, j)
        i = j - 1
      }
      OscEnd => {
        self.osc_end(code != 0x18 && code != 0x1a)
        if code == 0x1b {
          next = Escape
        }
        self.clear_seq()
        self.preceding = 0
      }
    }
    // (a full reset in an ESC handler set the parser to the ground already: the table's next is the ground too)
    self.state = next
    i += 1
  }
}

///|
fn utf32(data : Array[Int], start : Int, end : Int) -> String {
  let out = StringBuilder::new()
  for k in start..<end {
    out.write_string(from_cp(data[k]))
  }
  out.to_string()
}

// ── OSC and DCS ──

///|
fn Vt::osc_start(self : Vt) -> Unit {
  // (reset: an OSC under way given up)
  self.osc_id = -1
  self.osc_state = 1
  self.osc_data.reset()
  self.osc_limit = false
}

///|
fn Vt::osc_put(self : Vt, data : Array[Int], s : Int, end : Int) -> Unit {
  let mut start = s
  if self.osc_state == 3 {
    return
  }
  if self.osc_state == 1 {
    while start < end {
      let code = data[start]
      start += 1
      if code == 0x3b {
        self.osc_state = 2
        break
      }
      if code < 0x30 || 0x39 < code {
        self.osc_state = 3
        return
      }
      if self.osc_id == -1 {
        self.osc_id = 0
      }
      self.osc_id = self.osc_id * 10 + code - 48
    }
  }
  if self.osc_state == 2 && end - start > 0 && !self.osc_limit {
    self.osc_data.write_string(utf32(data, start, end))
    if self.osc_data.to_string().length() > PAYLOAD_LIMIT {
      self.osc_data.reset()
      self.osc_limit = true
    }
  }
}

///|
fn Vt::osc_end(self : Vt, success : Bool) -> Unit {
  if self.osc_state == 0 {
    return
  }
  if self.osc_state != 3 && success && !self.osc_limit {
    let data = self.osc_data.to_string()
    match self.osc_handlers.get(self.osc_id) {
      Some(hs) =>
        for k = hs.length() - 1; k >= 0; k = k - 1 {
          if (hs[k])(data) {
            break
          }
        }
      None => ()
    }
    // (xterm.js's own OSC handlers below a caller's change nothing that is read here: titles, colours, links)
  }
  self.osc_id = -1
  self.osc_state = 0
}

///|
fn Vt::dcs_hook(self : Vt, ident : Int) -> Unit {
  // (the DCS parser's reset ends one under way, unhooked as failed)
  self.dcs_ident = Some(ident)
  self.dcs_data.reset()
  self.dcs_limit = false
}

///|
fn Vt::dcs_put(self : Vt, data : Array[Int], start : Int, end : Int) -> Unit {
  if self.dcs_ident is None || self.dcs_limit {
    return
  }
  self.dcs_data.write_string(utf32(data, start, end))
  if self.dcs_data.to_string().length() > PAYLOAD_LIMIT {
    self.dcs_data.reset()
    self.dcs_limit = true
  }
}

///|
fn Vt::dcs_unhook(self : Vt, success : Bool) -> Unit {
  let ident = self.dcs_ident
  self.dcs_ident = None
  if ident == Some(ident_of("", "$", 'q')) && success && !self.dcs_limit {
    self.request_status(self.dcs_data.to_string())
  }
}

///|
fn ident_of(prefix : String, inter : String, final_ : Char) -> Int {
  let mut r = 0
  for c in prefix {
    r = c.to_int()
  }
  for c in inter {
    r = (r << 8) | c.to_int()
  }
  (r << 8) | final_.to_int()
}

///|
fn Vt::request_status(self : Vt, data : String) -> Unit {
  let b = self.buf()
  let f = (s : String) => self.reply("\u{1b}" + s + "\u{1b}\\")
  if data == "\"q" {
    f("P1$r\{if self.prot { 1 } else { 0 }}\"q")
  } else if data == "\"p" {
    f("P1$r61;1\"p")
  } else if data == "r" {
    f("P1$r\{b.top + 1};\{b.bottom + 1}r")
  } else if data == "m" {
    f("P1$r0m")
  } else if data == " q" {
    // the cursor's style as its option has it (block, not blinking)
    f("P1$r\{2 - (if self.cursor_blink_option { 1 } else { 0 })} q")
  } else {
    f("P0$r")
  }
}

// ── execute ──

///|
fn Vt::execute(self : Vt, code : Int) -> Unit {
  match code {
    0x0a | 0x0b | 0x0c => self.line_feed()
    0x0d => self.buf().x = 0
    0x08 => self.backspace()
    0x09 => self.tab()
    0x0e => self.set_glevel(1)
    0x0f => self.set_glevel(0)
    0x84 => self.index()
    0x85 => self.next_line()
    0x88 => self.tab_set()
    _ => ()
  }
}

///|
fn Vt::scroll(self : Vt, wrapped : Bool) -> Unit {
  let b = self.buf()
  let blank = Line::blank(self.cols, wrapped)
  let top_row = b.ybase + b.top
  let bottom_row = b.ybase + b.bottom
  if b.top == 0 {
    let trimmed = b.is_full()
    if bottom_row == b.lines.length() - 1 {
      b.push(blank)
    } else {
      b.splice(bottom_row + 1, 0, [blank])
    }
    if !trimmed {
      b.ybase += 1
    }
  } else {
    let height = bottom_row - top_row + 1
    b.shift(top_row + 1, height - 1, -1)
    b.set(bottom_row, blank)
  }
}

///|
fn Vt::line_feed(self : Vt) -> Unit {
  let b = self.buf()
  if self.convert_eol {
    b.x = 0
  }
  b.y += 1
  if b.y == b.bottom + 1 {
    b.y -= 1
    self.scroll(false)
  } else if b.y >= self.rows {
    b.y = self.rows - 1
  } else {
    match b.get(b.ybase + b.y) {
      Some(l) => l.wrapped = false
      None => ()
    }
  }
  if b.x >= self.cols {
    b.x -= 1
  }
}

///|
fn Vt::restrict(self : Vt, max_col? : Int) -> Unit {
  let b = self.buf()
  let m = max_col.unwrap_or(self.cols - 1)
  b.x = @cmp.minimum(m, @cmp.maximum(0, b.x))
  b.y = if self.origin {
    @cmp.minimum(b.bottom, @cmp.maximum(b.top, b.y))
  } else {
    @cmp.minimum(self.rows - 1, @cmp.maximum(0, b.y))
  }
}

///|
fn Vt::backspace(self : Vt) -> Unit {
  let b = self.buf()
  if !self.reverse_wrap {
    self.restrict()
    if b.x > 0 {
      b.x -= 1
    }
    return
  }
  self.restrict(max_col=self.cols)
  if b.x > 0 {
    b.x -= 1
  } else if b.x == 0 &&
    b.y > b.top &&
    b.y <= b.bottom &&
    (match b.get(b.ybase + b.y) {
      Some(l) => l.wrapped
      None => false
    }) {
    b.lines[b.ybase + b.y].wrapped = false
    b.y -= 1
    b.x = self.cols - 1
    let line = b.lines[b.ybase + b.y]
    if (line.data[b.x] & (3 << WIDTH_SHIFT)) != 0 && !line.has_content(b.x) {
      b.x -= 1
    }
  }
  self.restrict()
}

///|
fn Vt::tab(self : Vt) -> Unit {
  let b = self.buf()
  if b.x >= self.cols {
    return
  }
  b.x = b.next_stop(self.cols)
}

///|
fn Vt::set_glevel(self : Vt, g : Int) -> Unit {
  self.glevel = g
  self.charset = self.charsets.get(g).unwrap_or(None)
}

///|
fn Vt::set_gcharset(self : Vt, g : Int, c : Int?) -> Unit {
  self.charsets[g] = c
  if self.glevel == g {
    self.charset = c
  }
}

///|
fn Vt::index(self : Vt) -> Unit {
  self.restrict()
  let b = self.buf()
  b.y += 1
  if b.y == b.bottom + 1 {
    b.y -= 1
    self.scroll(false)
  } else if b.y >= self.rows {
    b.y = self.rows - 1
  }
  self.restrict()
}

///|
fn Vt::next_line(self : Vt) -> Unit {
  self.buf().x = 0
  self.index()
}

///|
fn Vt::tab_set(self : Vt) -> Unit {
  let b = self.buf()
  b.tabs[b.x] = true
}

///|
fn Vt::reverse_index(self : Vt) -> Unit {
  self.restrict()
  let b = self.buf()
  if b.y == b.top {
    let height = b.bottom - b.top
    b.shift(b.ybase + b.y, height, 1)
    b.set(b.ybase + b.y, Line::blank(self.cols, false))
  } else {
    b.y -= 1
    self.restrict()
  }
}

// ── print ──

///|
fn wcwidth(n : Int) -> Int {
  if n < 32 {
    return 0
  }
  if n < 127 {
    return 1
  }
  if n < 65536 {
    if n >= 0x7f && n < 0xa0 {
      return 0
    }
    if in_ranges(n, bmp_combining) {
      return 0
    }
    if (n >= 0x1100 && n < 0x1160) ||
      n == 0x2329 ||
      n == 0x232a ||
      (n >= 0x2e80 && n < 0xa4d0 && n != 0x303f) ||
      (n >= 0xac00 && n < 0xd7a4) ||
      (n >= 0xf900 && n < 0xfb00) ||
      (n >= 0xfe10 && n < 0xfe1a) ||
      (n >= 0xfe30 && n < 0xfe70) ||
      (n >= 0xff00 && n < 0xff61) ||
      (n >= 0xffe0 && n < 0xffe7) {
      return 2
    }
    return 1
  }
  if in_ranges(n, high_combining) {
    return 0
  }
  if (n >= 0x20000 && n <= 0x2fffd) || (n >= 0x30000 && n <= 0x3fffd) {
    return 2
  }
  1
}

///|
fn in_ranges(n : Int, data : Array[(Int, Int)]) -> Bool {
  let max0 = data.length() - 1
  if n < data[0].0 || n > data[max0].1 {
    return false
  }
  let mut min = 0
  let mut max = max0
  while max >= min {
    let mid = (min + max) >> 1
    if n > data[mid].1 {
      min = mid + 1
    } else if n < data[mid].0 {
      max = mid - 1
    } else {
      return true
    }
  }
  false
}

///|
/// UnicodeV6.charProperties: (width, whether it joins the one before).
fn char_props(cp : Int, preceding : Int) -> Int {
  let mut width = wcwidth(cp)
  let mut join = width == 0 && preceding != 0
  if join {
    let old = (preceding >> 1) & 3
    if old == 0 {
      join = false
    } else if old > width {
      width = old
    }
  }
  ((width & 3) << 1) | (if join { 1 } else { 0 })
}

///|
fn charset_of(index : Int?, code : Int) -> Int {
  match index {
    None => code
    Some(k) =>
      match charset_table[k].1 {
        None => code
        Some(pairs) => {
          for p in pairs {
            if p.0 == code {
              return p.1
            }
          }
          code
        }
      }
  }
}

///|
fn Vt::print(self : Vt, data : Array[Int], start : Int, end : Int) -> Unit {
  let cols = self.cols
  let b = self.buf()
  let mut row = b.lines[b.ybase + b.y]
  if b.x != 0 && end - start > 0 && row.width(b.x - 1) == 2 {
    row.set_cp(b.x - 1, 0, 1, self.prot)
  }
  let mut preceding = self.preceding
  for pos in start..<end {
    let mut code = data[pos]
    if code < 127 && self.charset is Some(_) {
      code = charset_of(self.charset, code)
    }
    let info = char_props(code, preceding)
    let mut w = (info >> 1) & 3
    let join = (info & 1) != 0
    let old_width = if join { (preceding >> 1) & 3 } else { 0 }
    preceding = info
    if b.x + w - old_width > cols {
      if self.wrap {
        let old_row = row
        let mut old_col = b.x - old_width
        b.x = old_width
        b.y += 1
        if b.y == b.bottom + 1 {
          b.y -= 1
          self.scroll(true)
        } else {
          if b.y >= self.rows {
            b.y = self.rows - 1
          }
          b.lines[b.ybase + b.y].wrapped = true
        }
        row = b.lines[b.ybase + b.y]
        if old_width > 0 {
          for k in 0..<old_width {
            let from = old_col + k
            row.data[k] = old_row.at(from)
            row.prot[k] = from >= 0 && from < old_row.len() && old_row.prot[from]
            if (old_row.at(from) & IS_COMBINED) != 0 {
              row.combined[k] = old_row.combined[from]
            }
          }
        }
        while old_col < cols {
          old_row.set_cp(old_col, 0, 1, self.prot)
          old_col += 1
        }
      } else {
        b.x = cols - 1
        if w == 2 {
          continue
        }
      }
    }
    if join && b.x != 0 {
      let offset = if row.width(b.x - 1) != 0 { 1 } else { 2 }
      row.add_codepoint(b.x - offset, code, w)
      for delta = w - old_width - 1; delta >= 0; delta = delta - 1 {
        row.set_cp(b.x, 0, 0, self.prot)
        b.x += 1
      }
      continue
    }
    if self.insert {
      row.insert_cells(b.x, w - old_width, self.prot)
      if row.width(cols - 1) == 2 {
        row.set_cp(cols - 1, 0, 1, self.prot)
      }
    }
    row.set_cp(b.x, code, w, self.prot)
    b.x += 1
    if w > 0 {
      w -= 1
      while w != 0 {
        row.set_cp(b.x, 0, 0, self.prot)
        b.x += 1
        w -= 1
      }
    }
  }
  self.preceding = preceding
  if b.x < cols && end - start > 0 && row.width(b.x) == 0 && !row.has_content(b.x) {
    row.set_cp(b.x, 0, 1, self.prot)
  }
}

// ── CSI ──

///|
fn Vt::set_cursor(self : Vt, x : Int, y : Int) -> Unit {
  let b = self.buf()
  b.x = x
  b.y = if self.origin { b.top + y } else { y }
  self.restrict()
}

///|
fn Vt::move_cursor(self : Vt, x : Int, y : Int) -> Unit {
  self.restrict()
  let b = self.buf()
  self.set_cursor(b.x + x, b.y + y)
}

///|
fn Vt::cursor_up(self : Vt, p : Int) -> Unit {
  let b = self.buf()
  let diff = b.y - b.top
  if diff >= 0 {
    self.move_cursor(0, -@cmp.minimum(diff, or1(p)))
  } else {
    self.move_cursor(0, -or1(p))
  }
}

///|
fn Vt::cursor_down(self : Vt, p : Int) -> Unit {
  let b = self.buf()
  let diff = b.bottom - b.y
  if diff >= 0 {
    self.move_cursor(0, @cmp.minimum(diff, or1(p)))
  } else {
    self.move_cursor(0, or1(p))
  }
}

///|
fn Vt::erase_in_line_of(self : Vt, y : Int, start : Int, end : Int, clear_wrap : Bool, respect : Bool) -> Unit {
  let b = self.buf()
  let line = b.lines[b.ybase + y]
  line.replace_cells(start, end, respect)
  if clear_wrap {
    line.wrapped = false
  }
}

///|
fn Vt::reset_line(self : Vt, y : Int, respect : Bool) -> Unit {
  let b = self.buf()
  match b.get(b.ybase + y) {
    Some(line) => {
      line.fill(NULL_CELL, false, respect)
      line.wrapped = false
    }
    None => ()
  }
}

///|
fn Vt::erase_in_display(self : Vt, p : Int, respect : Bool) -> Unit {
  self.restrict(max_col=self.cols)
  let b = self.buf()
  match p {
    0 => {
      let mut j = b.y
      self.erase_in_line_of(j, b.x, self.cols, b.x == 0, respect)
      j += 1
      while j < self.rows {
        self.reset_line(j, respect)
        j += 1
      }
    }
    1 => {
      let mut j = b.y
      self.erase_in_line_of(j, 0, b.x + 1, true, respect)
      if b.x + 1 >= self.cols {
        match b.get(j + 1) {
          Some(l) => l.wrapped = false
          None => ()
        }
      }
      while j > 0 {
        j -= 1
        self.reset_line(j, respect)
      }
    }
    2 => {
      let mut j = self.rows
      while j > 0 {
        j -= 1
        self.reset_line(j, respect)
      }
    }
    3 => {
      let size = b.lines.length() - self.rows
      if size > 0 {
        for _ in 0..<size {
          b.lines.remove(0) |> ignore
        }
        b.ybase = @cmp.maximum(b.ybase - size, 0)
      }
    }
    _ => ()
  }
}

///|
fn Vt::erase_in_line(self : Vt, p : Int, respect : Bool) -> Unit {
  self.restrict(max_col=self.cols)
  let b = self.buf()
  match p {
    0 => self.erase_in_line_of(b.y, b.x, self.cols, b.x == 0, respect)
    1 => self.erase_in_line_of(b.y, 0, b.x + 1, false, respect)
    2 => self.erase_in_line_of(b.y, 0, self.cols, true, respect)
    _ => ()
  }
}

///|
fn Vt::insert_lines(self : Vt, p : Int) -> Unit {
  self.restrict()
  let b = self.buf()
  let mut n = or1(p)
  if b.y > b.bottom || b.y < b.top {
    return
  }
  let row = b.ybase + b.y
  let offset = self.rows - 1 - b.bottom
  let bottom_abs = self.rows - 1 + b.ybase - offset + 1
  while n > 0 {
    n -= 1
    b.splice(bottom_abs - 1, 1, [])
    b.splice(row, 0, [Line::blank(self.cols, false)])
  }
  b.x = 0
}

///|
fn Vt::delete_lines(self : Vt, p : Int) -> Unit {
  self.restrict()
  let b = self.buf()
  let mut n = or1(p)
  if b.y > b.bottom || b.y < b.top {
    return
  }
  let row = b.ybase + b.y
  let j = self.rows - 1 + b.ybase - (self.rows - 1 - b.bottom)
  while n > 0 {
    n -= 1
    b.splice(row, 1, [])
    b.splice(j, 0, [Line::blank(self.cols, false)])
  }
  b.x = 0
}

///|
fn Vt::scroll_up(self : Vt, p : Int) -> Unit {
  let b = self.buf()
  let mut n = or1(p)
  while n > 0 {
    n -= 1
    b.splice(b.ybase + b.top, 1, [])
    b.splice(b.ybase + b.bottom, 0, [Line::blank(self.cols, false)])
  }
}

///|
fn Vt::scroll_down(self : Vt, p : Int) -> Unit {
  let b = self.buf()
  let mut n = or1(p)
  while n > 0 {
    n -= 1
    b.splice(b.ybase + b.bottom, 1, [])
    b.splice(b.ybase + b.top, 0, [Line::blank(self.cols, false)])
  }
}

///|
/// Each line of the scroll region, while the cursor is in it: `f` on it.
fn Vt::region_lines(self : Vt, f : (Line) -> Unit) -> Unit {
  let b = self.buf()
  if b.y > b.bottom || b.y < b.top {
    return
  }
  for y = b.top; y <= b.bottom; y = y + 1 {
    let line = b.lines[b.ybase + y]
    f(line)
    line.wrapped = false
  }
}

///|
fn Vt::repeat_preceding(self : Vt, p : Int) -> Unit {
  let join = self.preceding
  if join == 0 {
    return
  }
  let n = or1(p)
  let w = (join >> 1) & 3
  let b = self.buf()
  let x = b.x - w
  let row = b.lines[b.ybase + b.y]
  // (getString of a cell left of the row's start: JavaScript reads undefined there, an empty string)
  let text = if x < 0 || x >= row.len() {
    ""
  } else {
    let c = row.data[x]
    if (c & IS_COMBINED) != 0 {
      row.combined[x]
    } else if (c & CODEPOINT_MASK) != 0 {
      from_cp(c & CODEPOINT_MASK)
    } else {
      ""
    }
  }
  let one : Array[Int] = []
  let mut k = 0
  while k < text.length() {
    let ch = text.code_unit_at(k).to_int()
    if ch >= 0xD800 && ch <= 0xDBFF && k + 1 < text.length() {
      let lo = text.code_unit_at(k + 1).to_int()
      if lo >= 0xDC00 && lo <= 0xDFFF {
        one.push((ch - 0xD800) * 0x400 + lo - 0xDC00 + 0x10000)
        k += 2
        continue
      }
    }
    one.push(ch)
    k += 1
  }
  let data : Array[Int] = []
  for _ in 0..<n {
    for c in one {
      data.push(c)
    }
  }
  self.print(data, 0, data.length())
}

///|
fn Vt::set_mode(self : Vt, on : Bool) -> Unit {
  for i in 0..<self.params.length() {
    match self.params.at(i) {
      4 => self.insert = on
      20 => self.convert_eol = on
      _ => ()
    }
  }
}

///|
fn Vt::set_private_mode(self : Vt, on : Bool) -> Unit {
  for i in 0..<self.params.length() {
    let p = self.params.at(i)
    match p {
      1 => self.app_cursor = on
      2 =>
        if on {
          for g in 0..<4 {
            self.set_gcharset(g, None)
          }
        }
      6 => {
        self.origin = on
        self.set_cursor(0, 0)
      }
      7 => self.wrap = on
      12 => self.cursor_blink_option = on
      45 => self.reverse_wrap = on
      66 => self.app_keypad = on
      9 => self.mouse_protocol = if on { "X10" } else { "NONE" }
      1000 => self.mouse_protocol = if on { "VT200" } else { "NONE" }
      1002 => self.mouse_protocol = if on { "DRAG" } else { "NONE" }
      1003 => self.mouse_protocol = if on { "ANY" } else { "NONE" }
      1004 => self.send_focus = on
      1006 => self.mouse_encoding = if on { "SGR" } else { "DEFAULT" }
      1016 => self.mouse_encoding = if on { "SGR_PIXELS" } else { "DEFAULT" }
      25 => self.cursor_hidden = !on
      1048 => if on { self.save_cursor() } else { self.restore_cursor() }
      1049 | 47 | 1047 =>
        if on {
          if p == 1049 {
            self.save_cursor()
          }
          self.activate_alt()
        } else {
          self.activate_normal()
          if p == 1049 {
            self.restore_cursor()
          }
        }
      2004 => self.bracketed = on
      2026 => self.sync_output = on
      _ => ()
    }
  }
}

///|
fn Vt::activate_alt(self : Vt) -> Unit {
  if self.active_alt {
    return
  }
  self.alt.fill_viewport(self.cols, self.rows)
  self.alt.x = self.normal.x
  self.alt.y = self.normal.y
  self.active_alt = true
}

///|
fn Vt::activate_normal(self : Vt) -> Unit {
  if !self.active_alt {
    return
  }
  self.normal.x = self.alt.x
  self.normal.y = self.alt.y
  // (the alt buffer cleared: Buffer.clear)
  let a = self.alt
  a.ybase = 0
  a.y = 0
  a.x = 0
  a.lines = []
  a.top = 0
  a.bottom = self.rows - 1
  a.setup_tabs(self.cols)
  self.active_alt = false
}

///|
fn Vt::save_cursor(self : Vt) -> Unit {
  let b = self.buf()
  b.saved_x = b.x
  b.saved_y = b.ybase + b.y
  b.saved_prot = self.prot
  b.saved_charset = self.charset
}

///|
fn Vt::restore_cursor(self : Vt) -> Unit {
  let b = self.buf()
  b.x = b.saved_x
  b.y = @cmp.maximum(b.saved_y - b.ybase, 0)
  self.prot = b.saved_prot
  self.charset = b.saved_charset
  self.restrict()
}

///|
fn Vt::request_mode(self : Vt, ansi : Bool) -> Unit {
  let p = self.params.at(0)
  let b2v = (v : Bool) => if v { 1 } else { 2 }
  let v = if ansi {
    match p {
      2 => 4
      4 => b2v(self.insert)
      12 => 3
      20 => b2v(self.convert_eol)
      _ => 0
    }
  } else {
    match p {
      1 => b2v(self.app_cursor)
      3 => 0
      6 => b2v(self.origin)
      7 => b2v(self.wrap)
      8 => 3
      9 => b2v(self.mouse_protocol == "X10")
      12 => b2v(self.cursor_blink_option)
      25 => b2v(!self.cursor_hidden)
      45 => b2v(self.reverse_wrap)
      66 => b2v(self.app_keypad)
      67 => 4
      1000 => b2v(self.mouse_protocol == "VT200")
      1002 => b2v(self.mouse_protocol == "DRAG")
      1003 => b2v(self.mouse_protocol == "ANY")
      1004 => b2v(self.send_focus)
      1005 => 4
      1006 => b2v(self.mouse_encoding == "SGR")
      1015 => 4
      1016 => b2v(self.mouse_encoding == "SGR_PIXELS")
      1048 => 1
      47 | 1047 | 1049 => b2v(self.active_alt)
      2004 => b2v(self.bracketed)
      2026 => b2v(self.sync_output)
      _ => 0
    }
  }
  self.reply("\u{1b}[\{if ansi { "" } else { "?" }}\{p};\{v}$y")
}

///|
fn Vt::soft_reset(self : Vt) -> Unit {
  self.cursor_hidden = false
  let b = self.buf()
  b.top = 0
  b.bottom = self.rows - 1
  self.prot = false
  self.reset_modes()
  self.charset = None
  self.charsets.clear()
  self.glevel = 0
  b.saved_x = 0
  b.saved_y = b.ybase
  b.saved_prot = self.prot
  b.saved_charset = self.charset
  self.origin = false
}

///|
fn Vt::reset_modes(self : Vt) -> Unit {
  self.insert = false
  self.app_cursor = false
  self.app_keypad = false
  self.bracketed = false
  self.origin = false
  self.reverse_wrap = false
  self.send_focus = false
  self.sync_output = false
  self.wrap = true
}

///|
fn Vt::full_reset(self : Vt) -> Unit {
  // the parser's reset (the ground, an OSC or DCS under way given up)
  self.state = Ground
  self.clear_seq()
  self.preceding = 0
  self.osc_state = 0
  self.osc_id = -1
  self.dcs_ident = None
  // the terminal's: its buffers made anew, its attributes, charsets, modes and the mouse's
  self.normal = Buf::new(self.cols, self.rows, self.rows + self.scrollback)
  self.normal.fill_viewport(self.cols, self.rows)
  self.alt = Buf::new(self.cols, self.rows, self.rows)
  self.active_alt = false
  self.prot = false
  self.charset = None
  self.charsets.clear()
  self.glevel = 0
  self.reset_modes()
  self.mouse_protocol = "NONE"
  self.mouse_encoding = "DEFAULT"
}

///|
fn Vt::screen_alignment(self : Vt) -> Unit {
  self.set_cursor(0, 0)
  let b = self.buf()
  for off in 0..<self.rows {
    match b.get(b.ybase + b.y + off) {
      Some(line) => {
        line.fill((1 << WIDTH_SHIFT) | 'E'.to_int(), self.prot, false)
        line.wrapped = false
      }
      None => ()
    }
  }
  self.set_cursor(0, 0)
}

///|
fn Vt::csi(self : Vt, ident : Int) -> Unit {
  let p0 = self.params.at(0)
  let b = self.buf()
  let i = (prefix : String, inter : String, f : Char) => ident_of(prefix, inter, f)
  if ident == i("", "", '@') {
    self.restrict()
    b.lines[b.ybase + b.y].insert_cells(b.x, or1(p0), false)
  } else if ident == i("", " ", '@') {
    self.region_lines(l => l.delete_cells(0, or1(p0), false))
  } else if ident == i("", "", 'A') {
    self.cursor_up(p0)
  } else if ident == i("", " ", 'A') {
    self.region_lines(l => l.insert_cells(0, or1(p0), false))
  } else if ident == i("", "", 'B') {
    self.cursor_down(p0)
  } else if ident == i("", "", 'C') {
    self.move_cursor(or1(p0), 0)
  } else if ident == i("", "", 'D') {
    self.move_cursor(-or1(p0), 0)
  } else if ident == i("", "", 'E') {
    self.cursor_down(p0)
    self.buf().x = 0
  } else if ident == i("", "", 'F') {
    self.cursor_up(p0)
    self.buf().x = 0
  } else if ident == i("", "", 'G') || ident == i("", "", '`') {
    self.set_cursor(or1(p0) - 1, b.y)
  } else if ident == i("", "", 'H') || ident == i("", "", 'f') {
    self.set_cursor(if self.params.length() >= 2 { or1(self.params.at(1)) - 1 } else { 0 }, or1(p0) - 1)
  } else if ident == i("", "", 'I') {
    if b.x < self.cols {
      for _ in 0..<or1(p0) {
        b.x = b.next_stop(self.cols)
      }
    }
  } else if ident == i("", "", 'J') {
    self.erase_in_display(p0, false)
  } else if ident == i("?", "", 'J') {
    self.erase_in_display(p0, true)
  } else if ident == i("", "", 'K') {
    self.erase_in_line(p0, false)
  } else if ident == i("?", "", 'K') {
    self.erase_in_line(p0, true)
  } else if ident == i("", "", 'L') {
    self.insert_lines(p0)
  } else if ident == i("", "", 'M') {
    self.delete_lines(p0)
  } else if ident == i("", "", 'P') {
    self.restrict()
    b.lines[b.ybase + b.y].delete_cells(b.x, or1(p0), false)
  } else if ident == i("", "", 'S') {
    self.scroll_up(p0)
  } else if ident == i("", "", 'T') {
    self.scroll_down(p0)
  } else if ident == i("", "", 'X') {
    self.restrict()
    b.lines[b.ybase + b.y].replace_cells(b.x, b.x + or1(p0), false)
  } else if ident == i("", "", 'Z') {
    if b.x < self.cols {
      for _ in 0..<or1(p0) {
        b.x = b.prev_stop(self.cols)
      }
    }
  } else if ident == i("", "", 'a') {
    self.move_cursor(or1(p0), 0)
  } else if ident == i("", "", 'b') {
    self.repeat_preceding(p0)
  } else if ident == i("", "", 'c') {
    if p0 <= 0 {
      self.reply("\u{1b}[?1;2c")
    }
  } else if ident == i(">", "", 'c') {
    if p0 <= 0 {
      self.reply("\u{1b}[>0;276;0c")
    }
  } else if ident == i("", "", 'd') {
    self.set_cursor(b.x, or1(p0) - 1)
  } else if ident == i("", "", 'e') {
    self.move_cursor(0, or1(p0))
  } else if ident == i("", "", 'g') {
    if p0 == 0 {
      b.tabs.remove(b.x)
    } else if p0 == 3 {
      b.tabs = {}
    }
  } else if ident == i("", "", 'h') {
    self.set_mode(true)
  } else if ident == i("?", "", 'h') {
    self.set_private_mode(true)
  } else if ident == i("", "", 'l') {
    self.set_mode(false)
  } else if ident == i("?", "", 'l') {
    self.set_private_mode(false)
  } else if ident == i("", "", 'm') {
    self.char_attributes()
  } else if ident == i("", "", 'n') {
    match p0 {
      5 => self.reply("\u{1b}[0n")
      6 => self.reply("\u{1b}[\{b.y + 1};\{b.x + 1}R")
      _ => ()
    }
  } else if ident == i("?", "", 'n') {
    if p0 == 6 {
      self.reply("\u{1b}[?\{b.y + 1};\{b.x + 1}R")
    }
  } else if ident == i("", "!", 'p') {
    self.soft_reset()
  } else if ident == i("", "", 'r') {
    let top = or1(p0)
    let mut bottom = self.rows
    if self.params.length() >= 2 {
      let given = self.params.at(1)
      if given <= self.rows && given != 0 {
        bottom = given
      }
    }
    if bottom > top {
      b.top = top - 1
      b.bottom = bottom - 1
      self.set_cursor(0, 0)
    }
  } else if ident == i("", "", 's') {
    self.save_cursor()
  } else if ident == i("", "", 'u') {
    self.restore_cursor()
  } else if ident == i("", "'", '}') {
    self.region_lines(l => l.insert_cells(b.x, or1(p0), false))
  } else if ident == i("", "'", '~') {
    self.region_lines(l => l.delete_cells(b.x, or1(p0), false))
  } else if ident == i("", "\"", 'q') {
    if p0 == 1 {
      self.prot = true
    }
    if p0 == 2 || p0 == 0 {
      self.prot = false
    }
  } else if ident == i("", "$", 'p') {
    self.request_mode(true)
  } else if ident == i("?", "$", 'p') {
    self.request_mode(false)
  }
  // (`CSI t`, the window's options: all off, so nothing; `CSI SP q`, the cursor's style: nothing shown)
}

///|
/// SGR (charAttributes): of the attributes only DECSCA's protection is the cells' here, which SGR 0 takes off; a
/// colour's parameters (38, 48, 58) are passed over as xterm.js's `_extractColor` takes them.
fn Vt::char_attributes(self : Vt) -> Unit {
  let ps = self.params
  if ps.length() == 1 && ps.at(0) == 0 {
    self.prot = false
    return
  }
  let l = ps.length()
  let mut i = 0
  while i < l {
    let p = ps.at(i)
    if p == 0 {
      self.prot = false
    } else if p == 38 || p == 48 || p == 58 {
      i += self.extract_color(i)
    }
    i += 1
  }
}

///|
fn Vt::extract_color(self : Vt, pos : Int) -> Int {
  let ps = self.params
  let accu = [0, 0, -1, 0, 0, 0]
  let mut space = 0
  let mut advance = 0
  while true {
    accu[advance + space] = ps.at(pos + advance)
    if ps.subcount[pos + advance] > 0 {
      break
    }
    if (accu[1] == 5 && advance + space >= 2) || (accu[1] == 2 && advance + space >= 5) {
      break
    }
    if accu[1] != 0 {
      space = 1
    }
    advance += 1
    if !(advance + pos < ps.length() && advance + space < accu.length()) {
      break
    }
  }
  advance
}

// ── ESC ──

///|
fn glevel_of(c : Int) -> Int? {
  match c {
    0x28 => Some(0) // (
    0x29 => Some(1) // )
    0x2a => Some(2) // *
    0x2b => Some(3) // +
    0x2d => Some(1) // -
    0x2e => Some(2) // .
    _ => None
  }
}

///|
fn Vt::esc(self : Vt, ident : Int) -> Unit {
  let final_ = ident & 0xff
  let collect = ident >> 8
  if collect == 0 {
    match final_ {
      0x37 => self.save_cursor() // 7
      0x38 => self.restore_cursor() // 8
      0x44 => self.index() // D
      0x45 => self.next_line() // E
      0x48 => self.tab_set() // H
      0x4d => self.reverse_index() // M
      0x3d => self.app_keypad = true // =
      0x3e => self.app_keypad = false // >
      0x63 => self.full_reset() // c
      0x6e | 0x7d => self.set_glevel(2) // n }
      0x6f | 0x7c => self.set_glevel(3) // o |
      0x7e => self.set_glevel(1) // ~
      _ => ()
    }
    return
  }
  if collect == 0x25 && (final_ == 0x40 || final_ == 0x47) {
    // ESC % @, ESC % G
    self.set_glevel(0)
    self.set_gcharset(0, None)
    return
  }
  if collect == 0x23 && final_ == 0x38 {
    self.screen_alignment()
    return
  }
  if collect == 0x2f {
    // ESC / <flag>: registered for each set, and doing nothing
    return
  }
  match glevel_of(collect) {
    Some(g) =>
      for k, set in charset_table {
        if set.0.to_int() == final_ {
          self.set_gcharset(g, if set.1 is None { None } else { Some(k) })
          return
        }
      }
    None => ()
  }
}
