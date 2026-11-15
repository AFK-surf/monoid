// A terminal of a station's, viewed (the user, 2026-11-14, the mockup agreed in chat): over the whole window as a
// station's screen is, on every screen. The bar across its top is a viewer's (@sf.viewer_bar_node, a screen's and a
// file's): back to the page it was opened from by name; the folder it opened in, and under it where that is, or who
// types into it while someone else does, or that it ended; at its end 控制 while it is only looked at, 接管 while
// someone else types (the screen viewer's words), its ⋯ last (复制工作目录, 结束会话). A narrow page has a phone's bar
// instead (back, its name, the same at its end) and who types a line under it. Under the bar the screen, the whole of the room left, on the
// terminal's own dark ground whatever the theme, in the code face, its runs in the colours the program gave them.
//
// What it shows is the core's `terminal.view` stream (client/core-ts/src/terminals.ts) feeding a terminal the host keeps
// (@hostapi.Terminal: libghostty-vt on a device): the station's `screen` written into a terminal made anew of its size,
// what comes after it into that one. It is opened as wide and as tall as the window holds cells.

///|
// kept across runs: the views' numbers, each page its own (a core's view id is the app's to choose)
let terminal_views : Ref[Int] = Ref(0)

///|
/// The terminal's ground and its own ink, the same in either theme (terminal programs take a dark ground).
let terminal_ground : Int64 = 0x16171AFFL

///|
let terminal_ink : Int64 = 0xD8D9DBFFL

///|
/// The screen's words: the code face at 12.5, a line 19 high.
let terminal_size : Double = 12.5

///|
let terminal_line : Double = 19.0

///|
/// How tall a phone's line about the terminal under its bar comes to (page_note_node's: its words and the room round
/// them), and the line of who else types with its button (opened_head_node's), each a little over.
let terminal_note_h : Double = 34.0

///|
let terminal_strip_h : Double = 52.0

///|
/// How far in from the screen's sides and top its cells start.
let terminal_in : Double = 14.0

///|
let terminal_over : Double = 10.0

///|
/// A run of a line as the host gives it: its text and how it looks.
fn terminal_run(r : Json) -> @ui.Run? {
  guard r is Array([String(t), String(fg), String(bg), Number(flags, ..)]) else { return None }
  let f = flags.to_int()
  let inverse = (f & 8) != 0
  let (fg, bg) = if inverse { (bg, fg) } else { (fg, bg) }
  let fg = terminal_colour(fg).unwrap_or(if inverse { terminal_ground } else { terminal_ink })
  let bg = terminal_colour(bg)
  let faint = (f & 16) != 0
  Some(
    @ui.span(
      t,
      mono=true,
      bold=(f & 1) != 0,
      italic=(f & 2) != 0,
      underline=(f & 4) != 0,
      color=if faint { (fg & 0xFFFFFF00L) | 0x99L } else { fg },
      bg=match bg { Some(b) => b; None => if inverse { terminal_ink } else { 0L } },
      // (a cell's ground the whole of its cell: a line high, nothing either side, square)
      ground=Some({ room: 0.0, height: terminal_line / terminal_size, corner: 0.0, after: 0.0 }),
    ),
  )
}

///|
/// `#rrggbb` as the runs' colour (0xRRGGBBAA); None for the terminal's own.
fn terminal_colour(s : String) -> Int64? {
  guard s.length() == 7 && s.has_prefix("#") else { return None }
  let mut v = 0L
  for c in s.to_array()[1:] {
    let d = if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int()
    } else if c >= 'a' && c <= 'f' {
      c.to_int() - 'a'.to_int() + 10
    } else if c >= 'A' && c <= 'F' {
      c.to_int() - 'A'.to_int() + 10
    } else {
      return None
    }
    v = v * 16L + d.to_int64()
  }
  Some((v << 8) | 0xFFL)
}

///|
/// The screen's lines as the host gave them, as runs, a line a run of breaks.
fn terminal_runs(said : String) -> Array[@ui.Run] {
  let parsed = @json.parse(said) catch { _ => return [] }
  let out : Array[@ui.Run] = []
  match parsed {
    Object(o) =>
      match o.get("lines") {
        Some(Array(lines)) =>
          for i, line in lines {
            if i > 0 {
              out.push(@ui.span("\n", mono=true))
            }
            match line {
              Array(runs) => for r in runs { match terminal_run(r) { Some(run) => out.push(run); None => () } }
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  out
}

///|
/// How wide a cell of the screen is: the code face's M at the screen's size.
fn terminal_cell() -> Double {
  @ui.text_advance("M", size=terminal_size, style=@hostapi.style_mono)
}

///|
/// How many cells a window `w` × `h` holds under the bar (`top` over it: a phone's status bar), at least 20 × 6, a cell
/// `cell` wide (terminal_cell, measured once a page); `head`, how tall all over the screen comes to as laid out (the
/// bar, the line about it, who types), where it is known (more than 0), in the bar's place.
fn terminal_cells(w : Double, h : Double, top : Double, cell? : Double, head? : Double = 0.0) -> (Int, Int) {
  let cell = match cell {
    Some(c) => c
    None => terminal_cell()
  }
  let across = if cell > 0.0 { ((w - 2.0 * terminal_in) / cell).to_int() } else { 80 }
  let over = if head > 0.0 { head } else { top + @sf.viewer_bar_h }
  let down = ((h - over - 2.0 * terminal_over) / terminal_line).to_int()
  (if across < 20 { 20 } else { across }, if down < 6 { 6 } else { down })
}

///|
/// Station `at.station`'s terminal `at.terminal` (`new`: one opened for this page, in `at.cwd` where said), looked at
/// only where `at.watch`, in `v` (all of the window: the shell's), its bar's way back `back`'s words, `on_back` as it is
/// pressed, under `top` (a phone's status bar).
pub fn terminal_node(
  v : @view.View,
  src : Source,
  at : @sfbase.TerminalAt,
  back~ : () -> String,
  on_back~ : () -> Unit,
  top~ : () -> Double,
  width? : () -> Double,
) -> Unit {
  terminal_views.val += 1
  let view = "terminal-" + terminal_views.val.to_string()
  let (w, h) = v.window()
  let cell = terminal_cell()
  // (how tall all over the screen comes to: the bar (a phone's under its status bar, with the line about it under it),
  // and the line of who else types while it shows; what the screen's rows are worked out under, a little over rather
  // than under, so no line of it is ever under the window's foot)
  let head_h = fn() {
    let bar = top() + @sf.viewer_bar_h + (if width is Some(_) { 0.0 } else { terminal_note_h })
    bar + v.clear().2
  }
  let (cols, rows) = @signals.untracked(fn() { terminal_cells(w, h + v.keyboard_inset(), top(), cell~, head=head_h()) })
  // (what the core says of it, whole as it changes; and the screen drawn again as what feeds it comes)
  let state : @signals.Signal[Json?] = @signals.signal(None)
  let drawn : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
  let kept : Ref[@hostapi.Terminal?] = Ref(@hostapi.Terminal::open(cols, rows))
  // (the screen as the host gives it, read once each time what feeds it came: its lines drawn, its cursor followed, the
  // cursor keys' mode asked, all of this one reading)
  let screen : @signals.Computed[String] = @signals.computed(fn(_) {
    drawn.get() |> ignore
    match kept.val {
      Some(t) => t.lines()
      None => ""
    }
  })
  let fresh = fn() {
    match kept.val { Some(t) => t.close(); None => () }
    let s = @signals.untracked(fn() { state.get() })
    let c = number(s, "cols").to_int()
    let r = number(s, "rows").to_int()
    kept.val = @hostapi.Terminal::open(if c > 0 { c } else { cols }, if r > 0 { r } else { rows })
  }
  let params : Array[(String, Json)] = [
    ("station", str(at.station)),
    ("terminal", str(at.terminal)),
    ("view", str(view)),
    ("cols", Json::number(cols.to_double())),
    ("rows", Json::number(rows.to_double())),
    ("control", Json::boolean(!at.watch)),
    ..if at.cwd != "" && at.terminal == "new" { [("cwd", str(at.cwd))] } else { [] },
  ]
  let call = (src.stream)("terminal.view", obj(params), None, fn(value, bytes) {
    match value {
      Object(o) if o.contains("state") => state.set(o.get("state"))
      Object(o) if o.contains("screen") => {
        fresh()
        match (kept.val, bytes) { (Some(t), Some(b)) => t.write(b); _ => () }
        drawn.set(drawn.untracked() + 1)
      }
      Object(o) if o.contains("out") => {
        match (kept.val, bytes) { (Some(t), Some(b)) => t.write(b); _ => () }
        drawn.set(drawn.untracked() + 1)
      }
      _ => ()
    }
  }, @sfbase.answer_unread)
  v.owns(fn() {
    (src.cancel)(call)
    match kept.val { Some(t) => t.close(); None => () }
    kept.val = None
  })
  |> ignore
  let s = fn() { state.get() }
  let types = fn() { flag(s(), "types") }
  let typing = fn() { text(s(), "typing") }
  let ended = fn() { text(s(), "phase") == "ended" }
  let cwd = fn() {
    let said = text(s(), "cwd")
    if said == "" { at.cwd } else { said }
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
  // (one who may type: every member but a read-only one, as the station's terminals say)
  let listed = src.topic("terminals", { "station": str(at.station) })
  let may = fn() { flag(listed.get().value, "open") }
  let take = fn() { (src.call)("terminal.take", obj([("view", str(view))]), @sfbase.answer_unread) }
  v.grow(Is(1.0)).ground(By(fn() { @sf.theme().p.bg })) |> ignore
  // its head (@sf.opened_head_node: a viewer's bar in a wide frame, a phone's in a phone's): back, where it is, its ⋯
  // (复制工作目录; 结束会话 for one who may, while it runs); under it who else types and 接管, or 只看 and 控制
  // (what of the screen shows under all that now: less the line of who else types while it shows, and the keys row
  // while the soft keyboard is up, the window laid out over that)
  let shown_h = fn() {
    let strip = if may() && !types() && !ended() { terminal_strip_h } else { 0.0 }
    let keys = if v.keyboard_inset() > 0.0 { @sf.accessory_keys_h - v.clear().2 } else { 0.0 }
    v.window().1 - head_h() - strip - keys - 2.0 * terminal_over
  }
  @sf.opened_head_node(
    v,
    back,
    title,
    meta,
    cwd,
    top,
    width is Some(_),
    fn(m) {
      let (x, y, w, h) = m.placed_window_now()
      let id = text(@signals.untracked(s), "id")
      @sf.menu(
        [
          Some(@sf.menu_item_of(@sf.t("web-pages.terminal.copyCwd"), icon="copy", fn() { @ui.clipboard_set(@signals.untracked(cwd)) })),
          if @signals.untracked(may) && !@signals.untracked(ended) && id != "" {
            Some(@sf.menu_item_of(@sf.t("web-pages.terminal.end"), icon="close", danger=true, fn() {
              (src.call)("terminal.end", obj([("station", str(at.station)), ("terminal", str(id))]), @sfbase.answer_unread)
            }))
          } else {
            None
          },
        ],
        from=At(x, y, w, h),
        along=End,
      )
    },
    on_back,
    // (who else types, and 接管; or that it is only looked at, and 控制: for one who may, while it runs)
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
  )
  // the keys row's modifiers (ctrl, alt: @ui.key_in_*): `once` for the next key typed, `kept` till pressed again (the
  // mockup's: pressed once, for the next key; twice, kept)
  let once : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
  let kept_mods : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
  // what is typed while it is this page's to type into (`types`, while it runs): sent as the program reads it
  // (terminal_keys_of), with what the keys row holds, the cursor keys as the program last asked for them
  let send = fn(k : @ui.KeyIn) {
    guard @signals.untracked(types) && !@signals.untracked(ended) else { return }
    let app_keys = terminal_app_keys(screen.untracked())
    let said = terminal_keys_of(terminal_held(k, once.untracked() | kept_mods.untracked()), app_keys)
    // (a key's going down or words typed take the row's once-held modifiers; its coming up nothing)
    if !(k is Key(down=false, ..)) {
      once.set(0)
    }
    if said != "" {
      (src.call)("terminal.input", obj([("view", str(view)), ("text", str(said))]), @sfbase.answer_unread)
    }
  }
  let tap = fn(key : String, code : String) { send(Key(down=true, key~, code~, mods=0)) }
  // a modifier of the row pressed: off, then for the next key, then kept, then off
  let held_press = fn(bit : Int) {
    if (kept_mods.untracked() & bit) != 0 {
      kept_mods.set(kept_mods.untracked() & bit.lnot())
    } else if (once.untracked() & bit) != 0 {
      once.set(once.untracked() & bit.lnot())
      kept_mods.set(kept_mods.untracked() | bit)
    } else {
      once.set(once.untracked() | bit)
    }
  }
  let held = fn(bit : Int) { fn() { ((once.get() | kept_mods.get()) & bit) != 0 } }
  // the row's keys (the mockup's): those a terminal is driven by first, then the characters a phone's keyboard hides,
  // then F1 to F12, the row scrolling across to them
  let key = fn(cap : String, name : String, k : String, code : String) -> @sf.AccessoryKey {
    { cap, name, held: None, press: fn() { tap(k, code) } }
  }
  let held_key = fn(cap : String, name : String, bit : Int) -> @sf.AccessoryKey {
    { cap, name, held: Some(held(bit)), press: fn() { held_press(bit) } }
  }
  let typed = fn(c : String) -> @sf.AccessoryKey { { cap: c, name: c, held: None, press: fn() { send(Text(c)) } } }
  let fkey = fn(n : Int) -> @sf.AccessoryKey { key("F" + n.to_string(), "F" + n.to_string(), "F" + n.to_string(), "F" + n.to_string()) }
  let row_keys : Array[@sf.AccessoryKey] = [
    key("esc", "Esc", "Escape", "Escape"),
    key("tab", "Tab", "Tab", "Tab"),
    held_key("ctrl", @sf.t("android-misc.screen.key.control"), @ui.key_in_ctrl),
    held_key("alt", @sf.t("android-misc.screen.key.option"), @ui.key_in_alt),
    key("←", @sf.t("android-misc.screen.key.left"), "ArrowLeft", "ArrowLeft"),
    key("↑", @sf.t("android-misc.screen.key.up"), "ArrowUp", "ArrowUp"),
    key("↓", @sf.t("android-misc.screen.key.down"), "ArrowDown", "ArrowDown"),
    key("→", @sf.t("android-misc.screen.key.right"), "ArrowRight", "ArrowRight"),
    typed("|"),
    typed("~"),
    typed("/"),
    typed("-"),
    typed("_"),
    typed("\\"),
    ..[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12].map(fkey),
  ]
  // (the size said last, none while it is the one the view was opened at)
  let kept_size : Ref[(Int, Int)?] = Ref(None)
  // the window's size changed: as many cells as it holds now, said to the station and to the terminal kept here
  // (the window's whole height, the soft keyboard's part of it too: the window's tree is laid out over the keyboard, and
  // the screen is not made anew of fewer rows as it comes and goes, but lifted over it, the cursor's line kept in sight)
  v.reacts(fn() { (terminal_cells(v.window().0, v.window().1 + v.keyboard_inset(), top(), cell~, head=head_h()), types()) }, fn(said) {
    let ((c, r), typing) = said
    // (said only while this view types: the core sends no other's size)
    guard typing else { return }
    guard (c, r) != (cols, rows) || kept_size.val is Some(_) else { return }
    kept_size.val = Some((c, r))
    (src.call)("terminal.resize", obj([("view", str(view)), ("cols", Json::number(c.to_double())), ("rows", Json::number(r.to_double()))]), @sfbase.answer_unread)
    // (its lines drawn again only where a terminal is kept here, whose lines the new size changed)
    match kept.val {
      Some(t) => {
        t.resize(c, r)
        drawn.set(drawn.untracked() + 1)
      }
      None => ()
    }
  })
  // the screen under it: the rest of the window, on the terminal's own ground, taking the keyboard while it is this
  // page's to type into (pressed, or as it comes to be: the keys go to the terminal at once)
  // (this page's to type into: while it runs and types, and through a reopen of its view or its link's coming back
  // (connecting, reconnecting: it types again as it did), so the keyboard is not put away and raised again by them)
  let typing_here : @signals.Computed[Bool] = @signals.computed(fn(was) {
    match text(s(), "phase") {
      "ended" | "failed" => false
      "live" => types()
      _ => was.unwrap_or(false)
    }
  })
  @ui.key_catcher_node(v, @sf.t("web-pages.terminal.title"), send, on=By(fn() { typing_here.get() }), fn(k) {
    k.reacts(fn() { typing_here.get() }, fn(on) { @ui.key_catcher_focus_set(k, on) })
    k
    .grow(Is(1.0))
    .min_height(Is(Some(0.0)))
    .ground(Is(terminal_ground))
    .padding(Is((terminal_in, terminal_over, terminal_in, terminal_over)))
    .clips(Is(true))
    |> ignore
    k.box(fn(w) {
      w
      // (the soft keyboard up, and the keys row over it: lifted as far as keeps the cursor's line in sight over them,
      // the lines over it going up under the head, as a terminal's own window does)
      .offset(By(fn() {
        let row = terminal_cursor_row(screen.get())
        let lift = (row + 1).to_double() * terminal_line - shown_h()
        (0.0, if lift > 0.0 { -lift } else { 0.0 })
      }))
      .words_runs(By(fn() {
        drawn.get() |> ignore
        terminal_runs(screen.get())
      }), look={ size: terminal_size, weight: 400, line: terminal_line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 })
      .words_breaks(Is(true))
      .ink(Is(terminal_ink))
      |> ignore
    })
    |> ignore
  })
  |> ignore
  // the keys a phone's keyboard has not, over it while it is up and the keys are this page's (the mockup's 小屏 · 终端)
  v.show(fn() { v.keyboard_inset() > 0.0 && typing_here.get() }, fn(r) { @sf.accessory_keys_node(r, row_keys) })
}
