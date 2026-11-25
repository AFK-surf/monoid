// A terminal of a station's, viewed: over the whole window as a station's screen is, on every screen.
// The bar across its top is a viewer's (@sf.opened_head_node: @sf.viewer_bar_node on a wide window, @sf.nav_bar_node
// with its folder under its name on a narrow one): back to the page it was opened from by name; the folder it opened
// in; at its end 按键 (on a wide window) and 控制中心 (快捷操作, the station's terminals, 只看, 复制工作目录, 结束会话).
// Under the bar, while someone else types into it or while it is only looked at, who types and 接管 (or 控制).
// Under that the terminal's screen, painted cell-by-cell on its own dark ground (@ui.terminal_grid) with incremental
// binary dirty-row updates, scrollback history, text selection, SGR mouse forwarding, and IME preedit overlay; when
// it has ended, an overlay in its middle with 重新打开.
// On a touch device while typing into it: when the keyboard is down, a compact foot deck (Esc/Tab/^C, 键盘/粘贴/Ctrl,
// arrows + ⌫ + ⏎); when the keyboard is up, the single-row accessory strip above the soft keyboard.

///|
priv struct TermSess {
  view : String
  kept : Ref[@hostapi.Terminal?]
  cur_size : Ref[(Int, Int)]
  call_ref : Ref[Int?]
  state : @signals.Signal[Json?]
  drawn : @signals.Signal[Int]
  modes_sig : @signals.Signal[Int]
  out_queued : Ref[Bool]
  mut src : Source
  station : String
  mut terminal_id : String
  mut mounted : Int
}

///|
fn TermSess::close(self : TermSess) -> Unit {
  match self.call_ref.val {
    Some(c) => (self.src.cancel)(c)
    None => ()
  }
  self.call_ref.val = None
  match self.kept.val {
    Some(t) => t.close()
    None => ()
  }
  self.kept.val = None
}

///|
// kept across runs: active/preserved terminal sessions keyed by `station + "\n" + terminal_id` (reset in on_reset)
let terminal_sessions : Map[String, TermSess] = Map([])

///|
fn term_sess_key(station : String, terminal_id : String) -> String {
  station + "\n" + terminal_id
}

///|
/// Release a preserved terminal session once its tab, page and standalone window are all gone.
pub fn terminal_left(station : String, terminal : String) -> Unit {
  if @sfbase.window_has_terminal(station, terminal) {
    return
  }
  let key = term_sess_key(station, terminal)
  match terminal_sessions.get(key) {
    Some(sess) if sess.mounted <= 0 => {
      sess.close()
      terminal_sessions.remove(key)
    }
    _ => ()
  }
}

///|
/// Clean URL token extracted from `raw` (`https?://...` or `localhost:PORT` / `127.0.0.1:PORT` / `0.0.0.0:PORT`).
fn normalize_term_url(token : String) -> String? {
  let mut s = token.trim().to_owned()
  while s.length() > 0 {
    let last = s[s.length() - 1].to_int().unsafe_to_char()
    if last is ('.' | ',' | ';' | ')' | ']' | '}' | '\'' | '"' | '>') {
      s = s[:s.length() - 1].to_owned()
    } else {
      break
    }
  }
  while s.length() > 0 {
    let first = s[0].to_int().unsafe_to_char()
    if first is ('(' | '[' | '{' | '\'' | '"' | '<') {
      s = s[1:].to_owned()
    } else {
      break
    }
  }
  if s.has_prefix("http://0.0.0.0:") {
    return Some("http://127.0.0.1:" + s[15:].to_owned())
  }
  if s.has_prefix("http://") || s.has_prefix("https://") {
    return if s.length() > 8 { Some(s) } else { None }
  }
  for host in ["localhost:", "127.0.0.1:", "0.0.0.0:", "[::1]:"] {
    if s.has_prefix(host) && s.length() > host.length() {
      let port_char = s[host.length()].to_int()
      if port_char >= 48 && port_char <= 57 {
        let mapped = if host == "0.0.0.0:" { "127.0.0.1:" + s[8:].to_owned() } else { s }
        return Some("http://" + mapped)
      }
    }
  }
  None
}

///|
fn find_url_in_line(line : String, col : Int) -> String? {
  let chars = line.to_array()
  let n = chars.length()
  let mut i = 0
  let mut fallback : String? = None
  while i < n {
    while i < n && (chars[i] == ' ' || chars[i] == '\t' || chars[i] == '\r') {
      i += 1
    }
    let start = i
    while i < n && chars[i] != ' ' && chars[i] != '\t' && chars[i] != '\r' {
      i += 1
    }
    if i > start {
      let tok = String::from_array(chars[start:i])
      if normalize_term_url(tok) is Some(u) {
        if col >= start && col <= i {
          return Some(u)
        }
        if fallback is None {
          fallback = Some(u)
        }
      }
    }
  }
  fallback
}

///|
fn terminal_url_at(t : @hostapi.Terminal?, row : Int, col : Int, has_sel : Bool) -> String? {
  guard t is Some(term) else { return None }
  if has_sel {
    let sel = term.text(selection_only=true)
    for line in sel.split("\n") {
      if find_url_in_line(line.to_owned(), -1) is Some(u) {
        return Some(u)
      }
    }
  }
  let all = term.text()
  let lines = all.split("\n").collect()
  if row >= 0 && row < lines.length() {
    if find_url_in_line(lines[row].to_owned(), col) is Some(u) {
      return Some(u)
    }
  }
  None
}

///|
// kept across runs: put back as a run begins (on_reset)
let terminal_views : Ref[Int] = Ref(0)

///|
// kept across runs: put back as a run begins (on_reset)
let terminal_asked : Ref[String] = Ref("")

///|
fn init {
  @ui.on_reset(fn() {
    for _, sess in terminal_sessions {
      sess.close()
    }
    terminal_sessions.clear()
    terminal_views.val = 0
    terminal_asked.val = ""
  })
}

///|
/// Ask the next `terminal_node` made to open a fixture state (`"kb"`, `"keys"`, `"center"`, `"scrolled"`).
pub fn terminal_fixture_ask(what : String) -> Unit {
  terminal_asked.val = what
}

///|
/// The terminal's ground, the same in either theme (terminal programs take a dark ground).
let terminal_ground : Int64 = 0x16171AFFL

///|
/// The screen's words: the code face at 12.5, a line 19 high.
let terminal_size : Double = 12.5

///|
let terminal_line : Double = 19.0

///|
/// How tall a phone's bar with its subtitle comes to, and the strip of who else types with its button.
let terminal_narrow_bar_h : Double = 64.0

///|
let terminal_strip_h : Double = 52.0

///|
let terminal_foot_h : Double = 102.0

///|
let terminal_keys_narrow_h : Double = 402.0

///|
let terminal_keys_wide_h : Double = 110.0

///|
let terminal_tab_bar_h : Double = 42.0

///|
/// How far in a bar's key (32) shows its icon (16): (32 - 16) / 2.
// kept across runs: a value (no field of it changes)
let terminal_key_icon_in : Double = 8.0

///|
// kept across runs: a style, read as it is
let terminal_tab_bar_look : @ui.Style = @ui.css("row w=Full px=S2 py=S1 gap=S1_5 align=ACenter bg=Bg")

///|
// kept across runs: a style, read as it is
let terminal_cwd_chip_look : @ui.Style = @ui.css("row px=S2_5 py=S1 gap=S1_5 align=ACenter radius=Full bg=Neutral hovered{bg=Hover}")

///|
// kept across runs: a style, read as it is
let terminal_cwd_chip_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false, w=Cut)

///|
/// How far in from the screen's sides and top its cells start.
let terminal_in : Double = 14.0

///|
let terminal_over : Double = 10.0

///|
/// How wide a cell of the screen is: the code face's M at `size`.
fn terminal_cell(size? : Double = terminal_size) -> Double {
  @ui.terminal_grid_metrics(size).0
}

///|
/// How many cells a window `w` × `h` holds under the bar (`top` over it: a phone's status bar), at least 20 × 6, a cell
/// `cell` wide (terminal_cell), `head` how tall all over the screen comes to as laid out, and `foot` how tall what
/// stands under the screen comes to.
fn terminal_cells(
  w : Double,
  h : Double,
  top : Double,
  cell? : Double,
  head? : Double,
  foot? : Double = 0.0,
  line_h? : Double = terminal_line,
) -> (Int, Int) {
  let cell = match cell {
    Some(c) => c
    None => terminal_cell()
  }
  let across = if cell > 0.0 { ((w - 2.0 * terminal_in) / cell).to_int() } else { 80 }
  let over = match head {
    Some(hd) => hd
    None => top + @sf.viewer_bar_h_now()
  }
  let down = ((h - over - foot - 2.0 * terminal_over) / line_h).to_int()
  (if across < 20 { 20 } else { across }, if down < 6 { 6 } else { down })
}

///|
/// Station `at.station`'s terminal `at.terminal` in `v`, all of the window (terminal_pane_node, which says the rest).
pub fn terminal_node(
  v : @view.View,
  src : Source,
  at : @sfbase.TerminalAt,
  back~ : () -> String,
  on_back~ : () -> Unit,
  top~ : () -> Double,
  width? : () -> Double,
) -> Unit {
  terminal_pane_node(v, src, at, back~, on_back~, top~, width?)
}

///|
/// Station `at.station`'s terminal `at.terminal` (`new`: one opened for this page, in `at.cwd` where said), looked at
/// only where `at.watch`, in `v` (all of the window: the shell's), its bar's way back `back`'s words, `on_back` as it is
/// pressed, under `top` (a phone's status bar).
pub fn terminal_pane_node(
  v : @view.View,
  src : Source,
  at : @sfbase.TerminalAt,
  back~ : () -> String,
  on_back~ : () -> Unit,
  top~ : () -> Double,
  width? : () -> Double,
  in_tab? : Bool = false,
  bar_pads? : @sf.BarEnds,
  on_window? : () -> Unit,
  tips? : @sf.TipLayer,
  keep_open? : () -> Bool = fn() { false },
  on_resolved? : (String, String) -> Unit = fn(_, _) {  },
  on_switch_page? : (@sfbase.Page) -> Unit,
) -> Unit {
  let asked = terminal_asked.val
  terminal_asked.val = ""
  let wide = width is Some(_) || in_tab
  // (clear of the column of the system's bars down the window's trailing edge, an iPhone Duo's on its side: what it
  // shows and what is pressed in it, its grid's columns as wide as that leaves; its grounds on under it)
  let pane_w = fn() {
    let w = match width {
      Some(wf) => wf()
      None => v.window_w()
    }
    dmax(0.0, w - @sf.native_clear())
  }
  let base_cell = terminal_cell()
  let full : @signals.Signal[Bool] = @signals.signal(false)
  let fit80 : @signals.Signal[Bool] = @signals.signal(false)
  let kb_up : @signals.Signal[Bool] = @signals.signal(asked == "kb")
  let keys_open : @signals.Signal[Bool] = @signals.signal(asked == "keys")
  // Font zoom persisted per device (`prefs.terminalZoom`, 60..200, default 100) with optimistic local override
  let local_zoom : @signals.Signal[Int?] = @signals.signal(None, same=fn(a, b) { a == b })
  let zoom_pct = fn() -> Int {
    match local_zoom.get() {
      Some(z) => z
      None => {
        let raw = text(src.topic("prefs", {}).get().value, "terminalZoom")
        if raw == "" {
          100
        } else {
          let mut parsed = 0
          let mut ok = true
          for ch in raw {
            let d = ch.to_int() - 48
            if d >= 0 && d <= 9 {
              parsed = parsed * 10 + d
            } else {
              ok = false
            }
          }
          if !ok || parsed == 0 { 100 } else if parsed < 60 { 60 } else if parsed > 200 { 200 } else { parsed }
        }
      }
    }
  }
  let set_zoom = fn(next_raw : Int) {
    let clamped = if next_raw < 60 { 60 } else if next_raw > 200 { 200 } else { next_raw }
    local_zoom.set(Some(clamped))
    let zval : Json = if clamped == 100 { Json::null() } else { Json::string(clamped.to_string()) }
    (src.call)("prefs.set", Json::object({ "terminalZoom": zval }), @sfbase.answer_unread)
  }
  let step_zoom = fn(delta : Int) {
    set_zoom(@signals.untracked(zoom_pct) + delta)
  }
  let is_new_ask = at.terminal == "new" || at.terminal.has_prefix("new#")
  let existing_sess = if is_new_ask { None } else { terminal_sessions.get(term_sess_key(at.station, at.terminal)) }
  let reused = match existing_sess {
    Some(es) => es.call_ref.val is Some(_)
    None => false
  }
  let sess : TermSess = match (existing_sess, reused) {
    (Some(es), true) => {
      es.src = src
      es.mounted += 1
      es
    }
    _ => {
      terminal_views.val += 1
      let fresh : TermSess = {
        view: "terminal-" + terminal_views.val.to_string(),
        kept: Ref(None),
        cur_size: Ref((80, 24)),
        call_ref: Ref(None),
        state: @signals.signal(None),
        drawn: @signals.signal(0, same=fn(a, b) { a == b }),
        modes_sig: @signals.signal(@hostapi.term_mode_viewport_active, same=fn(a, b) { a == b }),
        out_queued: Ref(false),
        src,
        station: at.station,
        terminal_id: at.terminal,
        mounted: 1,
      }
      terminal_sessions[term_sess_key(at.station, at.terminal)] = fresh
      fresh
    }
  }
  let view = sess.view
  let state = sess.state
  let drawn = sess.drawn
  let modes_sig = sess.modes_sig
  let out_queued = sess.out_queued
  let cur_size = sess.cur_size
  let kept = sess.kept
  let call_ref = sess.call_ref
  let s = fn() { state.get() }
  let types = fn() { flag(s(), "types") }
  let typing = fn() { text(s(), "typing") }
  let ended = fn() {
    match text(s(), "phase") {
      "ended" | "failed" | "gone" | "denied" | "outdated" => true
      _ => false
    }
  }
  let listed = src.topic("terminals", { "station": str(at.station) })
  let screens_topic = src.topic("screens", { "station": str(at.station) })
  let may = fn() { flag(listed.get().value, "open") }
  let typing_here : @signals.Computed[Bool] = @signals.computed(fn(was) {
    match text(s(), "phase") {
      "ended" | "failed" | "gone" | "denied" | "outdated" => false
      "live" => types()
      _ => was.unwrap_or(false)
    }
  })
  let keys_shown = fn() { keys_open.get() && typing_here.get() && !full.get() }
  let kb_shown = fn() { (v.keyboard_inset() > 0.0 || kb_up.get()) && typing_here.get() && !keys_open.get() }
  let deck_shown = fn() { (if wide { keys_open.get() } else { @sf.soft_keyboard() }) && typing_here.get() && !full.get() }
  let font_scale = fn() {
    let user_z = zoom_pct().to_double() / 100.0
    if fit80.get() && base_cell > 0.0 {
      let avail = pane_w() - 2.0 * terminal_in
      let want = 80.0 * base_cell
      if avail < want { dmax(0.68, avail / want) } else { user_z }
    } else {
      user_z
    }
  }
  let size_now = fn() { terminal_size * font_scale() }
  let line_now = fn() { terminal_line * font_scale() }
  let head_h = fn() {
    if full.get() {
      0.0
    } else if in_tab {
      let strip = if may() && !types() && !ended() { terminal_strip_h } else { 0.0 }
      let bar_h = match bar_pads {
        Some(pads) => @sf.wide_bar_h + (pads.over)()
        None => terminal_tab_bar_h
      }
      bar_h + strip
    } else {
      let bar = top() + (if wide { @sf.viewer_bar_h_now() } else { terminal_narrow_bar_h })
      let strip = if may() && !types() && !ended() { terminal_strip_h } else { 0.0 }
      bar + strip
    }
  }
  let foot_h = fn() {
    let clear = v.clear().2
    if keys_shown() {
      (if wide { terminal_keys_wide_h } else { terminal_keys_narrow_h }) + clear
    } else if deck_shown() {
      (if kb_shown() { 54.0 } else { terminal_foot_h }) + clear
    } else {
      clear
    }
  }
  let dims_now = fn() -> (Int, Int, Int, Int) {
    let sz = size_now()
    let lh = line_now()
    let (cw, _, _) = @ui.terminal_grid_metrics(sz)
    let (c, r) = terminal_cells(pane_w(), v.window_h(), top(), cell=cw, head=head_h(), foot=foot_h(), line_h=lh)
    let scale = v.pixel_scale()
    let px_cw = dmax(1.0, (cw * scale).round()).to_int()
    let px_ch = dmax(1.0, (lh * scale).round()).to_int()
    (c, r, px_cw, px_ch)
  }
  let (init_c, init_r, init_cw, init_ch) = @signals.untracked(dims_now)
  if !reused {
    cur_size.val = (init_c, init_r)
    kept.val = @hostapi.Terminal::open(init_c, init_r)
    match kept.val {
      Some(t) => t.resize(init_c, init_r, cell_w=init_cw, cell_h=init_ch)
      None => ()
    }
  } else {
    match kept.val {
      Some(t) => {
        t.resize(init_c, init_r, cell_w=init_cw, cell_h=init_ch)
        cur_size.val = (init_c, init_r)
      }
      None => ()
    }
  }
  let sync_modes = fn() -> Int {
    let m = match kept.val {
      Some(t) => t.modes()
      None => @hostapi.term_mode_viewport_active
    }
    modes_sig.set(m)
    m
  }
  let bump_drawn = fn() {
    sync_modes() |> ignore
    if !out_queued.val {
      out_queued.val = true
      drawn.set(drawn.untracked() + 1)
    }
  }
  let reopen_vt = fn(c : Int, r : Int, px_cw : Int, px_ch : Int) {
    match kept.val {
      Some(t) => t.close()
      None => ()
    }
    let next = @hostapi.Terminal::open(c, r)
    match next {
      Some(t) => t.resize(c, r, cell_w=px_cw, cell_h=px_ch)
      None => ()
    }
    cur_size.val = (c, r)
    kept.val = next
  }
  let resize_vt = fn(c : Int, r : Int, px_cw : Int, px_ch : Int) {
    match kept.val {
      Some(t) => {
        t.resize(c, r, cell_w=px_cw, cell_h=px_ch)
        cur_size.val = (c, r)
      }
      None => reopen_vt(c, r, px_cw, px_ch)
    }
  }
  let resize_cancel : Ref[() -> Unit] = Ref(fn() {  })
  let open_stream = fn(term_id : String, watch_mode : Bool, init_cwd : String) {
    (resize_cancel.val)()
    resize_cancel.val = fn() {  }
    match call_ref.val {
      Some(c) => (src.cancel)(c)
      None => ()
    }
    state.set(None)
    let (c0, r0, cw0, ch0) = @signals.untracked(dims_now)
    reopen_vt(c0, r0, cw0, ch0)
    bump_drawn()
    let actual_term = if @sfbase.terminal_is_new(term_id) { "new" } else { term_id }
    let open_chat = @sfbase.terminal_open_chat(term_id)
    let params : Array[(String, Json)] = [
      ("station", str(at.station)),
      ("terminal", str(actual_term)),
      ("view", str(view)),
      ("cols", Json::number(c0.to_double())),
      ("rows", Json::number(r0.to_double())),
      ("control", Json::boolean(!watch_mode)),
      ..if init_cwd != "" && actual_term == "new" { [("cwd", str(init_cwd))] } else { [] },
      ..if open_chat != "" { [("chat", str(open_chat))] } else { [] },
    ]
    call_ref.val = Some(
      (src.stream)("terminal.view", obj(params), None, fn(value, bytes) {
        match value {
          Object(o) if o.contains("state") => {
            let st = o.get("state")
            state.set(st)
            let real_id = text(st, "id")
            if real_id != "" && real_id != "new" && real_id != sess.terminal_id {
              let old_k = term_sess_key(sess.station, sess.terminal_id)
              let new_k = term_sess_key(sess.station, real_id)
              if terminal_sessions.get(old_k) is Some(_) {
                terminal_sessions.remove(old_k)
              }
              sess.terminal_id = real_id
              terminal_sessions[new_k] = sess
              on_resolved(real_id, text(st, "cwd"))
            }
            if !flag(st, "types") {
              let sc = number(st, "cols").to_int()
              let sr = number(st, "rows").to_int()
              if sc > 0 && sr > 0 && (sc, sr) != cur_size.val {
                let (_, _, cw, ch) = @signals.untracked(dims_now)
                resize_vt(sc, sr, cw, ch)
                bump_drawn()
              }
            }
          }
          Object(o) if o.contains("screen") => {
            let st = @signals.untracked(fn() { state.get() })
            let (dc, dr, cw, ch) = @signals.untracked(dims_now)
            let sc = if flag(st, "types") { dc } else {
              let c = number(st, "cols").to_int()
              if c > 0 { c } else { dc }
            }
            let sr = if flag(st, "types") { dr } else {
              let r = number(st, "rows").to_int()
              if r > 0 { r } else { dr }
            }
            reopen_vt(sc, sr, cw, ch)
            match (kept.val, bytes) {
              (Some(t), Some(b)) => {
                t.write(b)
                if asked == "scrolled" {
                  t.scroll(0, -6)
                  t.select(2, 16, 8, 16, 8) |> ignore
                }
              }
              _ => ()
            }
            bump_drawn()
          }
          Object(o) if o.contains("out") =>
            match (kept.val, bytes) {
              (Some(t), Some(b)) => {
                t.write(b)
                bump_drawn()
              }
              _ => ()
            }
          _ => ()
        }
      }, @sfbase.answer_unread),
    )
  }
  if !reused {
    open_stream(at.terminal, at.watch, at.cwd)
  } else {
    bump_drawn()
  }
  let fling_cancel : Ref[() -> Unit] = Ref(fn() {  })
  v.owns(fn() {
    (resize_cancel.val)()
    resize_cancel.val = fn() {  }
    (fling_cancel.val)()
    fling_cancel.val = fn() {  }
    sess.mounted -= 1
    if sess.mounted <= 0 {
      let tid = sess.terminal_id
      let still_on_top = match @sfbase.app.nav.top() {
        Terminal(top_at) => top_at.station == at.station && top_at.terminal == tid
        _ => false
      }
      if !keep_open() && !@sfbase.window_has_terminal(at.station, tid) && !still_on_top {
        sess.close()
        terminal_sessions.remove(term_sess_key(at.station, tid))
      }
    }
  })
  |> ignore
  let cwd = fn() {
    let said = text(s(), "cwd")
    if said == "" { at.cwd } else { said }
  }
  let cur_terminal_id = fn() {
    let said = text(s(), "id")
    if said != "" { said } else { sess.terminal_id }
  }
  let switch_page = fn(next : @sfbase.Page) {
    match on_switch_page {
      Some(sw) => sw(next)
      None =>
        if @sfbase.lone_page.val is Some(_) {
          @sfbase.lone_page_replace(next)
        } else {
          @sfbase.app.nav.replace(next)
        }
    }
  }
  let go_terminal = fn(term_id : String, watch_mode : Bool, next_cwd : String) {
    let cur = @signals.untracked(cur_terminal_id)
    if term_id == cur && !@sfbase.terminal_is_new(term_id) {
      open_stream(term_id, watch_mode, next_cwd)
    } else {
      switch_page(Terminal({ station: at.station, terminal: term_id, watch: watch_mode, cwd: next_cwd }))
    }
  }
  let open_cwd_in_files = fn() {
    let dir = @signals.untracked(cwd)
    if dir != "" {
      @sfbase.open_page(Drive({ station: at.station, root: Some(dir), path: "" }))
    }
  }
  let copy_terminal_link = fn() {
    let tid = @signals.untracked(cur_terminal_id)
    guard tid != "" && !tid.has_prefix("new") else { return }
    let card = src.topic("terminalCard", { "station": str(at.station), "terminal": str(tid) }).get().value
    let rel = text(card, "link")
    let path = if rel != "" {
      rel
    } else {
      let parts = at.station.split("/").collect()
      let ws = parts.get(0).unwrap_or("").to_owned()
      let st = parts.get(1).unwrap_or("").to_owned()
      "/w/" + ws + "/s/" + st + "/terminal/" + tid
    }
    let origin = @sfbase.cloud_origin()
    @ui.clipboard_set(if origin != "" { origin + path } else { path })
    @sfbase.toast_later(@sf.t("web-pages.remote.linkCopied"))
  }
  let open_url_in_station_browser = fn(url : String) {
    let scs = items(@signals.untracked(fn() { screens_topic.get().value }), "screens")
    let listed_ids = scs.filter(fn(sc) {
      flag(Some(sc), "userTab") || text(Some(sc), "id").has_prefix("browser:u_")
    }).map(fn(sc) { text(Some(sc), "id") })
    @sfbase.open_remote_browser(src, at.station, listed_ids, url~)
  }
  let title = fn() {
    let shown = cwd()
    match shown.split("/").collect().filter(fn(p) { p.length() > 0 }).last() {
      Some(last) => last.to_owned()
      None => if shown == "" { @sf.t("web-pages.terminal.title") } else { shown }
    }
  }
  let meta = fn() {
    if ended() { @sf.t("web-pages.terminal.ended") } else { cwd() }
  }
  let set_control = fn(control : Bool) {
    (src.call)("terminal.take", obj([("view", str(view)), ("control", Json::boolean(control))]), @sfbase.answer_unread)
  }
  let take = fn() { (src.call)("terminal.take", obj([("view", str(view))]), @sfbase.answer_unread) }
  let raw_send = fn(said : String) {
    guard @signals.untracked(types) && !@signals.untracked(ended) && said != "" else { return }
    (src.call)("terminal.input", obj([("view", str(view)), ("text", str(said))]), @sfbase.answer_unread)
  }
  let scroll_to_bottom = fn() {
    match kept.val {
      Some(t) => {
        t.scroll(2, 0)
        bump_drawn()
      }
      None => ()
    }
  }
  let clear_selection = fn() {
    match kept.val {
      Some(t) => {
        t.select(0, 0, 0, 0, 0) |> ignore
        bump_drawn()
      }
      None => ()
    }
  }
  let copy_selection = fn() {
    match kept.val {
      Some(t) => {
        let txt = t.text(selection_only=true)
        if txt != "" {
          @ui.clipboard_set(txt)
        }
      }
      None => ()
    }
  }
  // Clipboard reading state (poll on frame or immediate in Tester)
  let clip_reading : Ref[@ui.ClipboardRead?] = Ref(None)
  let finish_paste = fn(words : String) {
    let modes = sync_modes()
    if (modes & @hostapi.term_mode_viewport_active) == 0 {
      scroll_to_bottom()
    }
    let pasted = terminal_pasted_of(words, terminal_bracketed_paste_mode(modes))
    raw_send(pasted)
  }
  let paste_clipboard = fn() {
    match @ui.clipboard_read() {
      Some(r) =>
        match r.got() {
          Some(got) => finish_paste(got.text)
          None => clip_reading.val = Some(r)
        }
      None => ()
    }
  }
  v.reacts(
    fn() {
      match clip_reading.val {
        Some(r) => r.got()
        None => None
      }
    },
    fn(got) {
      match got {
        Some(c) => {
          clip_reading.val = None
          finish_paste(c.text)
        }
        None => ()
      }
    },
  )
  // Modifiers on the accessory bar: held for the next key, then locked until pressed again (KeyPadMods)
  let pad_mods = @sf.KeyPadMods::new()
  let send = fn(k : @ui.KeyIn) {
    let modes = sync_modes()
    if terminal_copy_key(k) {
      if (modes & @hostapi.term_mode_has_selection) != 0 {
        copy_selection()
      }
      return
    }
    match terminal_zoom_key(k) {
      Some(0) => {
        set_zoom(100)
        return
      }
      Some(delta) => {
        step_zoom(delta)
        return
      }
      None => ()
    }
    if terminal_select_all_key(k) {
      match kept.val {
        Some(t) => {
          t.select(4, 0, 0, 0, 0) |> ignore
          bump_drawn()
        }
        None => ()
      }
      return
    }
    guard @signals.untracked(types) && !@signals.untracked(ended) else { return }
    if clip_reading.val is Some(r) && r.got() is Some(got) {
      clip_reading.val = None
      finish_paste(got.text)
    }
    if terminal_paste_key(k) {
      paste_clipboard()
      return
    }
    let app_keys = terminal_app_keys_mode(modes)
    // (those held for the next key alone let go as a key goes down)
    let mods = if k is Key(down=false, ..) { pad_mods.held_now() } else { pad_mods.consume_once() }
    let said = terminal_keys_of(terminal_held(k, mods), app_keys)
    if said != "" {
      if (modes & @hostapi.term_mode_viewport_active) == 0 {
        scroll_to_bottom()
      }
      if (modes & @hostapi.term_mode_has_selection) != 0 {
        clear_selection()
      }
      raw_send(said)
    }
  }
  let tap = fn(key : String, code : String) { send(Key(down=true, key~, code~, mods=0)) }
  let catcher_ref : Ref[@view.View?] = Ref(None)
  let keep_catcher_focus = fn() {
    if !@sf.soft_keyboard() || @signals.untracked(fn() { kb_up.get() }) {
      match catcher_ref.val {
        Some(k) => @ui.key_catcher_focus_set(k, true)
        None => ()
      }
    }
  }
  let combos : Array[(String, String)] = [
    (@sf.t("web-pages.terminal.combo.interrupt"), "\u{03}"),
    (@sf.t("web-pages.terminal.combo.eof"), "\u{04}"),
    (@sf.t("web-pages.terminal.combo.suspend"), "\u{1a}"),
    (@sf.t("web-pages.terminal.combo.clear"), "\u{0c}"),
    (@sf.t("web-pages.terminal.combo.history"), "\u{12}"),
    (@sf.t("web-pages.terminal.combo.killWord"), "\u{17}"),
    (@sf.t("web-pages.terminal.combo.lineStart"), "\u{01}"),
    (@sf.t("web-pages.terminal.combo.lineEnd"), "\u{05}"),
    (@sf.t("web-pages.terminal.combo.killLine"), "\u{15}"),
  ]
  let nav_and_fn : Array[(String, () -> Unit)] = [
    ("Home", fn() { tap("Home", "Home") }),
    ("End", fn() { tap("End", "End") }),
    ("PgUp", fn() { tap("PageUp", "PageUp") }),
    ("PgDn", fn() { tap("PageDown", "PageDown") }),
    ("Del", fn() { tap("Delete", "Delete") }),
    ("⇧Tab", fn() { raw_send("\u{1b}[Z") }),
    ..[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12].map(fn(n) {
      let fn_name = "F" + n.to_string()
      (fn_name, fn() { tap(fn_name, fn_name) })
    }),
  ]
  // 控制中心 panel (session-level management: station's remote sessions switcher + 新建终端, 字号, 在文件中打开, 复制链接, 新窗口, 全屏, 只看, 结束会话)
  let open_center_now = fn(from : @sf.Anchor) {
    @sf.panel_nodes(
      @sf.t("web-pages.screen.panel"),
      fn(p, done) {
        let terms = fn() { items(listed.get().value, "terminals") }
        let scs = fn() { items(screens_topic.get().value, "screens") }
        let can_browser = fn() { flag(screens_topic.get().value, "browser") && flag(screens_topic.get().value, "control") }
        let other_scs = fn() { scs().filter(fn(sc) { text(Some(sc), "kind") != "browser" }) }
        let user_browser_ids = fn() {
          scs().filter(fn(sc) { flag(Some(sc), "userTab") || text(Some(sc), "id").has_prefix("browser:u_") }).map(fn(sc) { text(Some(sc), "id") })
        }
        p.show(fn() { terms().length() > 0 || may() || !other_scs().is_empty() || !user_browser_ids().is_empty() || can_browser() }, fn(sec) {
          @sf.panel_group_node(sec, fn() { @sf.t("web-pages.remote.switchSession") }, fn(g) {
            g.each(other_scs, fn(sc) { text(Some(sc), "id") }, fn(row, sc) {
              let sv = fn() { Some(sc.get()) }
              let sid = text(@signals.untracked(sv), "id")
              let stitle = text(@signals.untracked(sv), "title")
              let kind = text(@signals.untracked(sv), "kind")
              @sf.panel_row_node(
                row,
                fn() { text(sv(), "title") },
                fn() {
                  done()
                  switch_page(Screen({ station: at.station, screen: sid, title: stitle, until_gone: false }))
                },
                icon=fn() { if kind == "simulator" { "phone" } else { "monitor" } },
              )
            })
            g.show(fn() { !user_browser_ids().is_empty() || can_browser() }, fn(br) {
              @sf.panel_row_node(
                br,
                fn() { @sf.t("web-pages.remote.openBrowser") },
                fn() {
                  done()
                  let ids = @signals.untracked(user_browser_ids)
                  let target = match @settings.browser_tab_to_open(at.station, ids) {
                    Some(id) => id
                    None => @settings.new_browser_tab(src.call, at.station, ids, @sfbase.answer_unread)
                  }
                  switch_page(Screen({ station: at.station, screen: target, title: "", until_gone: false }))
                },
                icon=fn() { "web" },
              )
            })
            g.each(terms, fn(t) { text(Some(t), "id") }, fn(row, t) {
              let tv = fn() { Some(t.get()) }
              let tid = text(@signals.untracked(tv), "id")
              let here = fn() { tid == cur_terminal_id() }
              @sf.panel_row_node(
                row,
                fn() { terminal_title(tv()) },
                fn() {
                  done()
                  if !@signals.untracked(here) {
                    go_terminal(tid, !flag(listed.untracked().value, "open"), text(@signals.untracked(tv), "cwd"))
                  }
                },
                icon=fn() { if here() { "check" } else { "terminal" } },
                note=fn() { text(tv(), "cwd") },
              )
            })
            let open_new_browser = fn() {
              let ids = @signals.untracked(user_browser_ids)
              let target = @settings.new_browser_tab(
                src.call,
                at.station,
                ids,
                failed_said(@sf.t("web-pages.screen.openBrowserWhat")),
              )
              let nu = screen_ui(screen_key(at.station, target))
              nu.address_asked.set(nu.address_asked.untracked() + 1)
              switch_page(Screen({ station: at.station, screen: target, title: "", until_gone: false }))
            }
            remote_new_session_rows_node(
              g,
              may,
              can_browser,
              done,
              fn() { go_terminal("new", false, @signals.untracked(cwd)) },
              open_new_browser,
            )
          })
        })
        @sf.panel_group_node(p, fn() { "" }, fn(g) {
          // Font zoom stepper row (- / 100% / +)
          g.box(fn(zrow) {
            zrow.row(Is(true)).padding(Is((12.0, 6.0, 8.0, 6.0))).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
            zrow.box(fn(lbl) {
              lbl.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              @sf.words_node(lbl, fn() { @sf.t("web-pages.remote.fontSize") + " · " + zoom_pct().to_string() + "%" }, fn() {
                @ui.text_style(size=Body, color=Fg, wrap=false, w=Cut)
              })
              |> ignore
            })
            |> ignore
            @sf.button_node(zrow, fn() { "−" }, fn() { step_zoom(-10) }, tone=Ghost) |> ignore
            zrow.show(fn() { zoom_pct() != 100 }, fn(rst) {
              @sf.button_node(rst, fn() { "100%" }, fn() { set_zoom(100) }, tone=Ghost) |> ignore
            })
            @sf.button_node(zrow, fn() { "+" }, fn() { step_zoom(10) }, tone=Ghost) |> ignore
          })
          |> ignore
          g.show(fn() { cwd() != "" }, fn(fd) {
            @sf.panel_row_node(
              fd,
              fn() { @sf.t("web-pages.remote.openInFiles") },
              fn() {
                done()
                open_cwd_in_files()
              },
              icon=fn() { "folder" },
              note=cwd,
            )
          })
          g.show(fn() {
            let tid = cur_terminal_id()
            tid != "" && !tid.has_prefix("new")
          }, fn(lk) {
            @sf.panel_row_node(
              lk,
              fn() { @sf.t("web-pages.remote.copyLink") },
              fn() {
                copy_terminal_link()
                done()
              },
              icon=fn() { "copy" },
            )
          })
          g.show(fn() {
            let tid = cur_terminal_id()
            let pg : @sfbase.Page = Terminal({ station: at.station, terminal: tid, watch: at.watch, cwd: cwd() })
            @sfbase.window_opens_for(pg)
          }, fn(wn) {
            @sf.panel_row_node(
              wn,
              fn() { @sf.t("web-pages.screen.window") },
              fn() {
                let tid = @signals.untracked(cur_terminal_id)
                let pg : @sfbase.Page = Terminal({ station: at.station, terminal: tid, watch: at.watch, cwd: @signals.untracked(cwd) })
                done()
                if @sfbase.open_window(pg) {
                  match on_window {
                    Some(handed) => handed()
                    None => on_back()
                  }
                }
              },
              icon=fn() { "external" },
            )
          })
          if !in_tab {
            @sf.panel_row_node(
              g,
              fn() { @sf.t(if full.get() { "android-misc.screen.unfull" } else { "android-misc.screen.full" }) },
              fn() {
                full.set(!full.untracked())
                done()
              },
              icon=fn() { if full.get() { "shrink" } else { "expand" } },
            )
          }
          if !wide {
            g.show(fn() { types() && !ended() }, fn(kp) {
              @sf.panel_switch_row_node(kp, fn() { @sf.t("web-pages.screen.keysPanel") }, fn() { keys_open.get() }, fn(on) {
                keys_open.set(on)
                done()
              })
            })
          }
          @sf.panel_switch_row_node(g, fn() { @sf.t("web-pages.terminal.fit80") }, fn() { fit80.get() }, fn(on) {
            fit80.set(on)
          })
          g.show(fn() { may() && !ended() && (types() || typing() == "") }, fn(m) {
            @sf.panel_switch_row_node(m, fn() { @sf.t("android-misc.screen.look") }, fn() { !types() }, fn(look_only) {
              set_control(!look_only)
            })
          })
          @sf.panel_row_node(
            g,
            fn() { @sf.t("web-pages.terminal.copyScreen") },
            fn() {
              let txt = match kept.val {
                Some(t) => t.text()
                None => ""
              }
              if txt != "" {
                @ui.clipboard_set(txt)
              }
              done()
            },
            icon=fn() { "copy" },
          )
          @sf.panel_row_node(
            g,
            fn() { @sf.t("web-pages.terminal.copyCwd") },
            fn() {
              @ui.clipboard_set(@signals.untracked(cwd))
              done()
            },
            icon=fn() { "copy" },
            note=cwd,
          )
          g.show(fn() { may() && !ended() && cur_terminal_id() != "" && !cur_terminal_id().has_prefix("new") }, fn(e) {
            @sf.panel_rule_node(e)
            @sf.panel_row_node(
              e,
              fn() { @sf.t("web-pages.terminal.end") },
              fn() {
                let id = @signals.untracked(cur_terminal_id)
                (src.call)("terminal.end", obj([("station", str(at.station)), ("terminal", str(id))]), @sfbase.answer_unread)
                done()
              },
              icon=fn() { "close" },
              danger=true,
            )
          })
        })
      },
      from~,
      along=End,
      focus=false,
    )
  }
  // (what waits for 控制中心's first read, pressed: one at a time, given up as it is pressed again or the page goes)
  let center_wait : Ref[@sfbase.PressWait?] = Ref(None)
  v.owns(fn() {
    match center_wait.val {
      Some(w) => w.give_up()
      None => ()
    }
    center_wait.val = None
  })
  |> ignore
  let open_center_panel = fn(from : @sf.Anchor) {
    match center_wait.val {
      Some(w) if w.waiting() => {
        center_wait.val = None
        w.give_up()
        return
      }
      _ => center_wait.val = None
    }
    // (once what it reads as it is first made is answered, the screen as it was meanwhile: its station's screens come
    // with it, never pushing its rows down after it came)
    let w = @sfbase.present_answered(
      src,
      [("screens", { "station": str(at.station) }), ("terminals", { "station": str(at.station) }), ("prefs", {})],
      fn() { open_center_now(from) },
    )
    if w.waiting() {
      center_wait.val = Some(w)
    }
  }
  v.grow(Is(1.0)).ground(By(fn() { @sf.theme().p.bg })).padding(By(fn() { (0.0, 0.0, @sf.native_clear(), 0.0) })) |> ignore
  // (the terminal's own dark ground on under the column beside its screen, from under its head to its foot, as the
  // page's is beside its head)
  v.box(fn(o) {
    o
    .over(Is(true))
    .row(Is(true))
    .padding(By(fn() { (0.0, head_h(), 0.0, foot_h()) }))
    |> ignore
    o.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    o.box(fn(g) { g.width(By(fn() { Some(@sf.native_clear()) })).ground(Is(terminal_ground)) |> ignore }) |> ignore
  })
  |> ignore
  // Top header bar (compact folder/tools strip in embedded tabs; full viewer header in standalone/full-window)
  v.show(fn() { !full.get() }, fn(hd) {
    if in_tab {
      // (the pane's own bar where it stands at the pane's top (bar_pads: 远程's): as high as a page's bar, its keys
      // as far in from its ends as the pane says, the last concentric with the window's corner, its empty part
      // dragging the window; else under a panel's tabs, compact)
      let linked = if bar_pads is Some(_) { Some(@sf.bar_keys_link) } else { None }
      hd.box(fn(bar) {
        match bar_pads {
          Some(pads) =>
            bar
            .row(Is(true))
            .gap(Is(6.0))
            .lines_up(Is(Some(Middle)))
            .ground(By(fn() { @sf.theme().p.bg }))
            .height(By(fn() { Some(@sf.wide_bar_h + (pads.over)()) }))
            // Keep left inset balanced with the bar's normal icon margin without mirroring window_keys_room to the left.
            .padding(By(fn() {
              let s = (pads.start)()
              let e = (pads.end)()
              let normal_end = if @ui.window_keys_own_now() {
                dmax(12.0, e - @sf.window_keys_room(roots=@ui.tree_corner_roots_now()))
              } else {
                e
              }
              (dmax(s, normal_end + terminal_key_icon_in), (pads.over)(), e, 1.0)
            }))
            .moves_window(By(@ui.window_inset_now))
            |> ignore
          None => {
            @sf.style_node(bar, fn() { terminal_tab_bar_look })
            bar.height(Is(Some(terminal_tab_bar_h))) |> ignore
          }
        }
        bar.shrink(Is(0.0)) |> ignore
        bar.box(fn(chip_slot) {
          chip_slot.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).row(Is(true)) |> ignore
          @sf.action_box_node(chip_slot, fn() { @sf.t("web-pages.remote.openInFiles") + ": " + cwd() }, fn(_) { open_cwd_in_files() }, fn(chip) {
            @sf.style_node(chip, fn() { terminal_cwd_chip_look }, in_row=true)
            chip.min_width(Is(Some(0.0))).shrink(Is(1.0)) |> ignore
            @sf.icon_node(chip, "folder", 14.0, By(fn() { @ui.tree_theme().color(Muted) })) |> ignore
            @sf.words_node(chip, fn() {
              let c = cwd()
              if c == "" { @sf.t("web-pages.terminal.title") } else { c }
            }, fn() { terminal_cwd_chip_words })
            .shrink(Is(1.0))
            .min_width(Is(Some(0.0)))
            .allow_ellipsis(Is(true))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        bar.show(fn() { types() && !ended() }, fn(ks) {
          ks.row(Is(true)).gap(Is(2.0)).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
          @sf.icon_button_node(ks, "keyboard", fn() { @sf.t("web-pages.screen.keysPanel") }, fn() {
            keys_open.set(!keys_open.untracked())
          }, tips?, linked?)
          |> ignore
          @sf.icon_button_node(ks, "clipboard", fn() { @sf.t("web-pages.screen.paste") }, paste_clipboard, tips?, linked?)
          |> ignore
        })
        // (a window of its own, where one takes it: beside 控制中心, as a chat's bar has it)
        if on_window is Some(handed) {
          let page_now = fn() -> @sfbase.Page {
            Terminal({ station: at.station, terminal: cur_terminal_id(), watch: at.watch, cwd: cwd() })
          }
          bar.show(fn() { @sfbase.window_opens_for(page_now()) }, fn(wb) {
            wb.shrink(Is(0.0)) |> ignore
            @sf.icon_button_node(
              wb,
              "external",
              fn() { @sf.t("web-pages.chat.openInWindow") },
              fn() {
                if @sfbase.open_window(@signals.untracked(page_now)) {
                  handed()
                }
              },
              tips?,
              linked?,
            )
            |> ignore
          })
        }
        let more_btn = Ref(bar)
        let mb = @sf.icon_button_node(
          bar,
          "more",
          fn() { @sf.t("web-pages.screen.panel") },
          fn() { open_center_panel(Node(more_btn.val)) },
          tips?,
          linked?,
        )
        more_btn.val = mb
      })
      |> ignore
      hd.show(fn() { may() && !types() && !ended() }, fn(st_bar) {
        st_bar
        .row(Is(true))
        .height(Is(Some(terminal_strip_h)))
        .padding(Is((12.0, 6.0, 12.0, 6.0)))
        .gap(Is(8.0))
        .lines_up(Is(Some(Middle)))
        .ground(By(fn() { @sf.theme().p.neutral_bg }))
        |> ignore
        st_bar.box(fn(tx) {
          tx.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(tx, fn() {
            if typing() != "" {
              @sf.t("web-pages.screen.controlling", args=[("names", typing())])
            } else {
              @sf.t("web-pages.screen.look")
            }
          }, fn() { @ui.text_style(size=Caption, color=Muted, wrap=false, w=Cut) })
          |> ignore
        })
        |> ignore
        @sf.button_node(st_bar, fn() {
          if typing() != "" { @sf.t("android-misc.screen.takeOver") } else { @sf.t("web-pages.screen.control") }
        }, take, tone=Primary)
        |> ignore
      })
    } else {
      @sf.opened_head_node(
        hd,
        back,
        title,
        meta,
        cwd,
        top,
        wide,
        fn(m) { open_center_panel(Node(m)) },
        on_back,
        fn() {
          if !may() || types() || ended() {
            ""
          } else if typing() != "" {
            @sf.t("web-pages.screen.controlling", args=[("names", typing())])
          } else {
            @sf.t("web-pages.screen.look")
          }
        },
        fn() { if typing() != "" { @sf.t("android-misc.screen.takeOver") } else { @sf.t("web-pages.screen.control") } },
        take,
        keys_shown=fn() { types() && !ended() },
        keys_on=fn() { keys_open.get() },
        keys=fn(_) { keys_open.set(!keys_open.untracked()) },
        paste=paste_clipboard,
      )
    }
  })
  let kept_size : Ref[(Int, Int)?] = Ref(None)
  let last_kb : Ref[Double] = Ref(@signals.untracked(fn() { v.keyboard_inset() }))
  v.reacts(
    fn() {
      (dims_now(), types(), v.keyboard_inset())
    },
    fn(said) {
      let ((c, r, px_cw, px_ch), is_typing, kb_now) = said
      let kb_moving = kb_now != last_kb.val
      last_kb.val = kb_now
      guard is_typing else { return }
      guard (c, r) != cur_size.val || kept_size.val is Some(_) else { return }
      if kept_size.val == Some((c, r)) {
        return
      }
      kept_size.val = Some((c, r))
      // Always resize local GhosttyTerminal in place immediately (preserves scrollback and reflows lines cleanly)
      resize_vt(c, r, px_cw, px_ch)
      bump_drawn()
      (resize_cancel.val)()
      resize_cancel.val = fn() {  }
      let send_resize = fn() {
        (src.call)(
          "terminal.resize",
          obj([("view", str(view)), ("cols", Json::number(c.to_double())), ("rows", Json::number(r.to_double()))]),
          @sfbase.answer_unread,
        )
      }
      if kb_moving && @sf.soft_keyboard() {
        resize_cancel.val = v.at_moment(v.cause_at() + 90.0, send_resize, later=true)
      } else {
        send_resize()
      }
    },
  )
  @ui.key_catcher_node(
    v,
    @sf.t("web-pages.terminal.title"),
    send,
    paste=finish_paste,
    on=By(fn() { typing_here.get() }),
    fn(k) {
      catcher_ref.val = Some(k)
      let was_focused : Ref[Bool] = Ref(false)
      k.reacts(
        fn() { @ui.key_catcher_focused(k) },
        fn(foc) {
          if was_focused.val && !foc && @signals.untracked(fn() { kb_up.get() }) {
            kb_up.set(false)
          }
          was_focused.val = foc
        },
      )
      k.reacts(
        fn() { typing_here.get() && (!@sf.soft_keyboard() || kb_up.get()) },
        fn(on) {
          if on {
            @ui.key_catcher_focus_set(k, true)
          }
        },
      )
      k
      .grow(Is(1.0))
      .min_height(Is(Some(0.0)))
      .ground(Is(terminal_ground))
      .padding(Is((terminal_in, terminal_over, terminal_in, terminal_over)))
      .clips(Is(true))
      |> ignore
      let grid = @ui.terminal_grid(
        k,
        fn() { kept.val },
        fn() {
          out_queued.val = false
          let d = drawn.get()
          sync_modes() |> ignore
          d
        },
        size_now,
        line_now,
        fn() { (0.0, 0.0) },
        fn() { @ui.key_catcher_focused(k) || !@sf.soft_keyboard() },
        fn() { @ui.key_catcher_composing(k) },
        on_cursor=fn(cx, cy, ch) {
          @ui.key_catcher_place(k, cx, cy, ch)
        },
      )
      let cell_at = fn(lx : Double, ly : Double) -> (Int, Int, Int, Int, Int, Int, Int, Int) {
        let (cw, _, _) = @ui.terminal_grid_metrics(@signals.untracked(size_now))
        let lh = @signals.untracked(line_now)
        let (cols_n, rows_n) = cur_size.val
        let col = if cw > 0.0 {
          let c = (lx / cw).floor().to_int()
          if c < 0 { 0 } else if c >= cols_n { cols_n - 1 } else { c }
        } else {
          0
        }
        let row = if lh > 0.0 {
          let r = (ly / lh).floor().to_int()
          if r < 0 { 0 } else if r >= rows_n { rows_n - 1 } else { r }
        } else {
          0
        }
        let scale = v.pixel_scale()
        let px = dmax(0.0, (lx * scale).round()).to_int()
        let py = dmax(0.0, (ly * scale).round()).to_int()
        let px_cw = dmax(1.0, (cw * scale).round()).to_int()
        let px_ch = dmax(1.0, (lh * scale).round()).to_int()
        let surf_w = (cols_n * px_cw).max(1)
        let surf_h = (rows_n * px_ch).max(1)
        (col, row, px, py, surf_w, surf_h, px_cw, px_ch)
      }
      let send_mouse = fn(action : Int, button : Int, lx : Double, ly : Double, mods : Int) {
        guard @signals.untracked(types) && !@signals.untracked(ended) else { return }
        match kept.val {
          Some(t) => {
            let (_, _, px, py, surf_w, surf_h, px_cw, px_ch) = cell_at(lx, ly)
            let seq = t.mouse(action, button, mods & 15, px, py, surf_w, surf_h, px_cw, px_ch)
            if seq.length() > 0 {
              raw_send(@utf8.decode_lossy(seq[:]))
            }
          }
          None => ()
        }
      }
      let pan_rem_y : Ref[Double] = Ref(0.0)
      let wheel_rem_y : Ref[Double] = Ref(0.0)
      let stop_fling = fn() {
        (fling_cancel.val)()
        fling_cancel.val = fn() {  }
      }
      let scroll_by_px = fn(dy_px : Double, modes : Int) -> Bool {
        let lh = @signals.untracked(line_now)
        guard lh > 0.0 else { return false }
        pan_rem_y.val += dy_px
        let steps = (pan_rem_y.val / lh).trunc().to_int()
        guard steps != 0 else { return false }
        pan_rem_y.val -= steps.to_double() * lh
        let alt_scroll = (modes & (@hostapi.term_mode_alt_screen | @hostapi.term_mode_alt_scroll)) ==
          (@hostapi.term_mode_alt_screen | @hostapi.term_mode_alt_scroll)
        if alt_scroll && @signals.untracked(types) && !@signals.untracked(ended) {
          let count = if steps < 0 { -steps } else { steps }
          for _ in 0..<count {
            if steps > 0 {
              tap("ArrowDown", "ArrowDown")
            } else {
              tap("ArrowUp", "ArrowUp")
            }
          }
          true
        } else {
          match kept.val {
            Some(t) => {
              t.scroll(0, steps)
              bump_drawn()
              true
            }
            None => false
          }
        }
      }
      let pinch_rem : Ref[Double] = Ref(0.0)
      grid
      .grow(Is(1.0))
      .min_height(Is(Some(0.0)))
      .as_ground()
      .cursor(
        By(fn() {
          if (modes_sig.get() & @hostapi.term_mode_mouse_tracking) != 0 {
            Some(@view.Cursor::Arrow)
          } else {
            Some(@view.Cursor::IBeam)
          }
        }),
      )
      .on_wheel_moves(fn(w) {
        if (w.mods & @ui.wheel_mod_pinch) != 0 {
          pinch_rem.val -= w.dy
          let steps = (pinch_rem.val / 12.0).trunc().to_int()
          if steps != 0 {
            pinch_rem.val -= steps.to_double() * 12.0
            step_zoom(steps * 5)
          }
          return true
        }
        stop_fling()
        let modes = sync_modes()
        let mods = w.mods & 15
        let shift = (mods & 1) != 0
        if (modes & @hostapi.term_mode_mouse_tracking) != 0 && !shift && @signals.untracked(types) && !@signals.untracked(ended) {
          if w.dy.abs() >= w.dx.abs() && w.dy != 0.0 {
            let btn = if w.dy < 0.0 { 4 } else { 5 }
            let ticks = (w.dy.abs() / 28.0).round().to_int().max(1)
            for _ in 0..<ticks {
              send_mouse(0, btn, w.x, w.y, mods)
            }
            return true
          } else if w.dx != 0.0 {
            let btn = if w.dx < 0.0 { 6 } else { 7 }
            let ticks = (w.dx.abs() / 28.0).round().to_int().max(1)
            for _ in 0..<ticks {
              send_mouse(0, btn, w.x, w.y, mods)
            }
            return true
          }
          return false
        }
        guard w.dy != 0.0 else { return false }
        let lh = @signals.untracked(line_now)
        guard lh > 0.0 else { return false }
        wheel_rem_y.val += w.dy
        let steps = (wheel_rem_y.val / lh).trunc().to_int()
        if steps == 0 {
          return true
        }
        wheel_rem_y.val -= steps.to_double() * lh
        let alt_scroll = (modes & (@hostapi.term_mode_alt_screen | @hostapi.term_mode_alt_scroll)) ==
          (@hostapi.term_mode_alt_screen | @hostapi.term_mode_alt_scroll)
        if alt_scroll && @signals.untracked(types) && !@signals.untracked(ended) {
          let count = if steps < 0 { -steps } else { steps }
          for _ in 0..<count {
            if steps > 0 {
              tap("ArrowDown", "ArrowDown")
            } else {
              tap("ArrowUp", "ArrowUp")
            }
          }
          return true
        }
        match kept.val {
          Some(t) => {
            t.scroll(0, steps)
            bump_drawn()
            true
          }
          None => false
        }
      })
      .on_menu(fn(m) {
        stop_fling()
        let modes = sync_modes()
        let mods = @hostapi.mods_held() & 15
        let shift = (mods & 1) != 0
        if (modes & @hostapi.term_mode_mouse_tracking) != 0 && !shift && @signals.untracked(types) && !@signals.untracked(ended) {
          send_mouse(0, 2, m.x, m.y, mods)
          send_mouse(1, 2, m.x, m.y, mods)
          return
        }
        let has_sel = (modes & @hostapi.term_mode_has_selection) != 0
        let can_type = @signals.untracked(types) && !@signals.untracked(ended)
        let (mcol, mrow, _, _, _, _, _, _) = cell_at(m.x, m.y)
        let found_url = terminal_url_at(kept.val, mrow, mcol, has_sel)
        let menu_items : Array[@sf.MenuItem?] = []
        match found_url {
          Some(u) => {
            menu_items.push(
              Some(
                @sf.menu_item_of(
                  @sf.t("web-pages.remote.openInRemoteBrowser"),
                  fn() {
                    open_url_in_station_browser(u)
                  },
                  icon="web",
                ),
              ),
            )
            menu_items.push(None)
          }
          None => ()
        }
        if has_sel {
          menu_items.push(
            Some(
              @sf.menu_item_of(
                @sf.t("web-pages.terminal.copySelection"),
                fn() {
                  copy_selection()
                  keep_catcher_focus()
                },
                icon="copy",
              ),
            ),
          )
        }
        if can_type {
          menu_items.push(
            Some(
              @sf.menu_item_of(
                @sf.t("web-pages.screen.paste"),
                fn() {
                  paste_clipboard()
                  keep_catcher_focus()
                },
                icon="clipboard",
              ),
            ),
          )
        }
        menu_items.push(
          Some(
            @sf.menu_item_of(
              @sf.t("web-pages.terminal.copyScreen"),
              fn() {
                match kept.val {
                  Some(t) => {
                    let txt = t.text()
                    if txt != "" {
                      @ui.clipboard_set(txt)
                    }
                  }
                  None => ()
                }
                keep_catcher_focus()
              },
              icon="copy",
            ),
          ),
        )
        if has_sel {
          menu_items.push(
            Some(
              @sf.menu_item_of(
                @sf.t("web-pages.terminal.clearSelection"),
                fn() {
                  clear_selection()
                  keep_catcher_focus()
                },
                icon="close",
              ),
            ),
          )
        }
        @sf.menu(menu_items, from=@sf.at_point(m.wx, m.wy))
      })
      |> ignore
      @ui.terminal_grid_gesture(
        grid,
        fn() { kept.val },
        sync_modes,
        fn() { @signals.untracked(types) && !@signals.untracked(ended) },
        fn(lx, ly) {
          let (col, row, _, _, _, _, _, _) = cell_at(lx, ly)
          (col, row)
        },
        send_mouse,
        scroll_by_px,
        fn() {
          stop_fling()
          pan_rem_y.val = 0.0
        },
        fn(first_at, vy0) {
          fn glide(at_t : Double, vel : Double) -> Unit {
            fling_cancel.val = v.at_moment(
              at_t,
              fn() {
                let m_now = sync_modes()
                let moved = scroll_by_px(vel * 16.0, m_now)
                let next_v = vel * 0.92
                let hit_bottom = vel > 0.0 && (sync_modes() & @hostapi.term_mode_viewport_active) != 0
                if next_v.abs() >= 0.04 && !hit_bottom && (moved || pan_rem_y.val.abs() > 0.5) {
                  glide(at_t + 16.0, next_v)
                }
              },
              later=true,
            )
          }
          glide(first_at, vy0)
        },
        bump_drawn,
        clear_selection,
        fn() { @ui.key_catcher_focus_set(k, true) },
        fn() {
          if @sf.soft_keyboard() && @signals.untracked(fn() { typing_here.get() }) {
            keys_open.set(false)
            kb_up.set(true)
            @ui.key_catcher_focus_set(k, true)
          }
        },
      )
      |> ignore
      // Floating bottom-right action pills when scrolled up in scrollback or holding a text selection
      k.show(
        fn() {
          let m = modes_sig.get()
          (m & @hostapi.term_mode_viewport_active) == 0 ||
          (@sf.soft_keyboard() && (m & @hostapi.term_mode_has_selection) != 0)
        },
        fn(fl) {
          fl
          .over(Is(true))
          .row(Is(true))
          .gap(Is(8.0))
          .padding(Is((16.0, 16.0, 16.0, 14.0)))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(End))
          |> ignore
          let float_pill = fn(parent : @view.View, label : () -> String, press : () -> Unit) {
            @sf.action_box_node(parent, label, fn(_) { press() }, fn(b) {
              b
              .row(Is(true))
              .min_height(Is(Some(36.0)))
              .padding(Is((14.0, 6.0, 14.0, 6.0)))
              .radius(By(fn() { @ui.tree_theme().corner(Full) }))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              |> ignore
              @sf.hover_ground_node(
                b,
                color=fn() {
                  if b.pressed() && !b.glass_solid() {
                    0xFFFFFF2EL
                  } else {
                    @ui.tree_theme().color(Hover)
                  }
                },
              )
              @sf.glass_capsule_node(b, sharing=false, panel=true, interactive=true) |> ignore
              b.box(fn(w) {
                w
                .words(By(label))
                .words_look(By(fn() {
                  let th = @sf.theme()
                  {
                    size: th.t.ui,
                    weight: if th.touch { 600 } else { 500 },
                    line: th.t.ui_line,
                    wrap: false,
                    tracking: @view.letters_own,
                    balance: false,
                    max_lines: 0,
                  }
                }))
                .ink(By(fn() { @sf.theme().p.text }))
                |> ignore
              })
              |> ignore
            })
            |> ignore
          }
          fl.show(
            fn() {
              let _ = drawn.get()
              @sf.soft_keyboard() &&
              (modes_sig.get() & @hostapi.term_mode_has_selection) != 0 &&
              terminal_url_at(kept.val, -1, -1, true) is Some(_)
            },
            fn(ob) {
              float_pill(
                ob,
                fn() { @sf.t("web-pages.remote.openInRemoteBrowser") },
                fn() {
                  match terminal_url_at(kept.val, -1, -1, true) {
                    Some(u) => {
                      clear_selection()
                      open_url_in_station_browser(u)
                    }
                    None => ()
                  }
                },
              )
            },
          )
          fl.show(
            fn() { @sf.soft_keyboard() && (modes_sig.get() & @hostapi.term_mode_has_selection) != 0 },
            fn(cp) {
              float_pill(
                cp,
                fn() { @sf.t("web-pages.terminal.copySelection") },
                fn() {
                  copy_selection()
                  clear_selection()
                },
              )
            },
          )
          fl.show(
            fn() { (modes_sig.get() & @hostapi.term_mode_viewport_active) == 0 },
            fn(sb) {
              @sf.float_button_node(
                sb,
                "arrow-down",
                fn() { @sf.t("web-pages.terminal.scrollBottom") },
                scroll_to_bottom,
              )
              |> ignore
            },
          )
        },
      )
      // Floating exit-fullscreen button in the top-right corner when full screen is on
      k.show(fn() { full.get() }, fn(f) {
        f
        .over(Is(true))
        .padding(
          By(fn() {
            let own = @ui.window_keys_own_now()
            let pt = match bar_pads {
              Some(pads) if own => dmax(0.0, (pads.over)() - 2.0)
              _ => if own { top() + 3.0 } else { top() + 16.0 }
            }
            let pr = match bar_pads {
              Some(pads) if own => dmax(16.0, (pads.end)())
              _ => if own { @sf.window_end_in(16.0, roots=@ui.tree_corner_roots_now()) } else { 16.0 }
            }
            (16.0, pt, pr, 16.0)
          }),
        )
        .lines_up(Is(Some(End)))
        |> ignore
        f.box(fn(cap) {
          @sf.style_node(cap, fn() { full_tools_box })
          floats_capsule_node(cap)
          @sf.tool_round_node(cap, "shrink", fn() { @sf.t("android-misc.screen.unfull") }, fn() { full.set(false) }) |> ignore
        })
        |> ignore
      })
      // Centered theme-adaptive liquid glass status card when the terminal session has ended or failed
      k.show(ended, fn(ov) {
        ov
        .over(Is(true))
        .padding(Is((24.0, 24.0, 24.0, 24.0)))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        |> ignore
        ov.box(fn(card) {
          card
          .width_share(Is(1.0))
          .max_width(Is(Some(@sf.confirm_w)))
          .padding(Is((@sf.card_pad, @sf.card_pad, @sf.card_pad, @sf.card_pad)))
          .gap(Is(18.0))
          |> ignore
          @sf.panel_surface_decorate(card, radius=@sf.card_corner, clips=true) |> ignore
          card.box(fn(head) {
            head.gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
            head.box(fn(badge) {
              badge
              .width(Is(Some(40.0)))
              .height(Is(Some(40.0)))
              .radius(Is(20.0))
              .ground(By(fn() { @sf.alpha(@sf.theme().p.text, if @sf.theme().dark { 0.10 } else { 0.07 }) }))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              |> ignore
              @sf.icon_node(badge, "terminal", 18.0, By(fn() { @sf.alpha(@sf.theme().p.text, 0.85) })) |> ignore
            })
            |> ignore
            head.box(fn(words) {
              words.width_share(Is(1.0)).gap(Is(4.0)).lines_up(Is(Some(Middle))) |> ignore
              words.box(fn(ttl) {
                ttl
                .width_share(Is(1.0))
                .words(By(fn() { @sf.t("web-pages.terminal.ended") }))
                .words_look(By(fn() {
                  let (px, line) = @ui.tree_theme().text_size(Title)
                  {
                    size: px,
                    weight: 600,
                    line,
                    wrap: true,
                    tracking: @view.letters_own,
                    balance: false,
                    max_lines: 0,
                  }
                }))
                .words_centered(Is(true))
                .ink(By(fn() { @sf.theme().p.text }))
                |> ignore
              })
              |> ignore
              let sub_text = fn() {
                let msg = text(s(), "message")
                if msg != "" { msg } else { cwd() }
              }
              words.show(fn() { sub_text() != "" }, fn(sub) {
                sub
                .width_share(Is(1.0))
                .words(By(sub_text))
                .words_look(By(fn() {
                  let (px, line) = @ui.tree_theme().text_size(Caption)
                  {
                    size: px,
                    weight: 400,
                    line,
                    wrap: false,
                    tracking: @view.letters_own,
                    balance: false,
                    max_lines: 1,
                  }
                }))
                .words_centered(Is(true))
                .allow_ellipsis(Is(true))
                .ink(By(fn() { @sf.alpha(@sf.theme().p.text, if @sf.theme().dark { 0.70 } else { 0.74 }) }))
                |> ignore
              })
            })
            |> ignore
          })
          |> ignore
          card.show(may, fn(act) {
            let h = @sf.button_height()
            let reach = @sf.card_foot_in(h) - @sf.card_pad
            act.row(Is(true)).margin(Is((reach, 0.0, reach, reach))) |> ignore
            @sf.action_box_node(
              act,
              fn() { @sf.t("web-pages.screen.again") },
              fn(_) { go_terminal("new", false, @signals.untracked(cwd)) },
              fn(b) {
                b
                .grow(Is(1.0))
                .basis(Is(Some(0.0)))
                .height(Is(Some(h)))
                .padding(Is((16.0, 0.0, 16.0, 0.0)))
                .radius(Is(h / 2.0))
                .row(Is(true))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                .ground(By(fn() {
                  let p = @sf.theme().p
                  if @sf.theme().dark { 0xFFFFFFEBL } else { p.primary }
                }))
                |> ignore
                @sf.hover_ground_node(
                  b,
                  color=fn() {
                    if @sf.theme().dark {
                      if b.pressed() { 0x00000018L } else { 0xFFFFFF40L }
                    } else if b.pressed() {
                      0xFFFFFF24L
                    } else {
                      0xFFFFFF18L
                    }
                  },
                )
                b.box(fn(w) {
                  w
                  .words(By(fn() { @sf.t("web-pages.screen.again") }))
                  .words_look(By(fn() {
                    let (px, line) = @ui.tree_theme().text_size(Ui)
                    {
                      size: px,
                      weight: 600,
                      line,
                      wrap: false,
                      tracking: @view.letters_own,
                      balance: false,
                      max_lines: 0,
                    }
                  }))
                  .ink(By(fn() { if @sf.theme().dark { 0x16171AFFL } else { @sf.theme().p.on_primary } }))
                  |> ignore
                })
                |> ignore
              },
            )
            |> ignore
          })
        })
        |> ignore
      })
    },
  )
  |> ignore
  // Bottom control deck on touch devices and single-pass inline 按键 tray on wide desktop (zero nested tray.show!)
  let build_ext_tiles = fn(ext : @view.View) {
    let combo_cols = if wide { combos.length() } else { 3 }
    tiles_node(ext, combos.length(), combo_cols, key_tile_gap, fn(row, i) {
      let (label, seq) = combos[i]
      center_tile_node(row, key_tile_box, label, fn() {
        raw_send(seq)
        keep_catcher_focus()
      }, fn(t) {
        @sf.words_node(t, fn() { label }, fn() { key_tile_words }).allow_ellipsis(Is(true)) |> ignore
      })
    })
    let fn_cols = if wide { nav_and_fn.length() } else { 6 }
    tiles_node(ext, nav_and_fn.length(), fn_cols, key_tile_gap, fn(row, i) {
      let (label, act) = nav_and_fn[i]
      center_tile_node(row, key_tile_box, label, fn() {
        act()
        keep_catcher_focus()
      }, fn(t) {
        @sf.words_node(t, fn() { label }, fn() { key_tile_words }).allow_ellipsis(Is(true)) |> ignore
      })
    })
  }
  v.show(deck_shown, fn(inner) {
    inner
    .gap(Is(6.0))
    .padding(By(fn() {
      let side = if wide { 12.0 } else { 8.0 }
      let top_pad = if wide { 8.0 } else { 6.0 }
      (side, top_pad, side, 6.0 + v.clear().2)
    }))
    |> ignore
    if wide {
      build_ext_tiles(inner)
    } else {
      inner.pick(
        fn() { if keys_open.get() { 2 } else if kb_shown() { 1 } else { 0 } },
        fn(area, kind) {
          if kind == 2 {
            area.gap(Is(6.0)) |> ignore
            area.box(fn(bar) {
              bar.row(Is(true)).gap(Is(6.0)) |> ignore
              @sf.key_pad_key_node(bar, "键盘", @sf.t("android-misc.screen.keyboard"), fn() {
                keys_open.set(false)
                kb_up.set(true)
              }, height=38.0) |> ignore
              @sf.key_pad_key_node(bar, "粘贴", @sf.t("web-pages.screen.paste"), paste_clipboard, height=38.0) |> ignore
              @sf.key_pad_key_node(bar, "", @sf.t("web-pages.terminal.hideKeyboard"), fn() { keys_open.set(false) }, width=48.0, height=38.0, icon="chevron-down") |> ignore
            })
            |> ignore
            build_ext_tiles(area)
          } else if kind == 1 {
            // Keyboard Up: Single-row full-visibility strip with Backspace & auto-repeat
            area.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(3.0)) |> ignore
            @sf.key_pad_key_node(area, "Esc", "Esc", fn() { tap("Escape", "Escape") }, height=42.0) |> ignore
            @sf.key_pad_key_node(area, "Tab", "Tab", fn() { tap("Tab", "Tab") }, height=42.0) |> ignore
            @sf.key_pad_key_node(area, "Ctrl", @sf.t("android-misc.screen.key.control"), fn() { pad_mods.press(@ui.key_in_ctrl) }, height=42.0, held=fn() { pad_mods.holds(@ui.key_in_ctrl) }) |> ignore
            @sf.key_pad_key_node(area, "Alt", @sf.t("android-misc.screen.key.option"), fn() { pad_mods.press(@ui.key_in_alt) }, height=42.0, held=fn() { pad_mods.holds(@ui.key_in_alt) }) |> ignore
            @sf.key_pad_key_node(area, "←", @sf.t("android-misc.screen.key.left"), fn() { tap("ArrowLeft", "ArrowLeft") }, width=31.0, height=42.0, repeat=true) |> ignore
            @sf.key_pad_key_node(area, "↓", @sf.t("android-misc.screen.key.down"), fn() { tap("ArrowDown", "ArrowDown") }, width=31.0, height=42.0, repeat=true) |> ignore
            @sf.key_pad_key_node(area, "↑", @sf.t("android-misc.screen.key.up"), fn() { tap("ArrowUp", "ArrowUp") }, width=31.0, height=42.0, repeat=true) |> ignore
            @sf.key_pad_key_node(area, "→", @sf.t("android-misc.screen.key.right"), fn() { tap("ArrowRight", "ArrowRight") }, width=31.0, height=42.0, repeat=true) |> ignore
            @sf.key_pad_key_node(area, "⌫", @sf.t("web-pages.terminal.backspace"), fn() { tap("Backspace", "Backspace") }, width=31.0, height=42.0, repeat=true) |> ignore
            @sf.key_pad_key_node(area, "", @sf.t("web-pages.terminal.hideKeyboard"), fn() {
              kb_up.set(false)
              match catcher_ref.val {
                Some(k) => @ui.key_catcher_focus_set(k, false)
                None => ()
              }
            }, width=31.0, height=42.0, icon="chevron-down") |> ignore
          } else {
            // Keyboard Down Default: Left 2x3 Action Grid + Right Inverted-T Arrow Pad + Backspace + Tall Enter
            area.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
            area.box(fn(left) {
              left.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(4.0)) |> ignore
              left.box(fn(r1) {
                r1.row(Is(true)).gap(Is(5.0)) |> ignore
                @sf.key_pad_key_node(r1, "Esc", "Esc", fn() { tap("Escape", "Escape") }, height=41.0) |> ignore
                @sf.key_pad_key_node(r1, "Tab", "Tab", fn() { tap("Tab", "Tab") }, height=41.0) |> ignore
                @sf.key_pad_key_node(r1, "^C", @sf.t("web-pages.terminal.combo.interrupt"), fn() { raw_send("\u{03}") }, height=41.0) |> ignore
              })
              |> ignore
              left.box(fn(r2) {
                r2.row(Is(true)).gap(Is(5.0)) |> ignore
                @sf.key_pad_key_node(r2, "键盘", @sf.t("android-misc.screen.keyboard"), fn() { kb_up.set(true) }, height=41.0) |> ignore
                @sf.key_pad_key_node(r2, "粘贴", @sf.t("web-pages.screen.paste"), paste_clipboard, height=41.0) |> ignore
                @sf.key_pad_key_node(r2, "Ctrl", @sf.t("android-misc.screen.key.control"), fn() { pad_mods.press(@ui.key_in_ctrl) }, height=41.0, held=fn() { pad_mods.holds(@ui.key_in_ctrl) }) |> ignore
              })
              |> ignore
            })
            |> ignore
            @sf.key_pad_dpad_node(area, 38.0, 41.0, 44.0, 86.0, fn(key) { tap(key, key) }) |> ignore
          }
        },
      )
    }
  })
  // Open fixture center panel when asked by open_fixture ("keys" is now inline via keys_open signal!)
  if asked == "center" {
    open_center_now(At(pane_w() - 28.0, top() + 24.0, 32.0, 32.0))
  }
}
