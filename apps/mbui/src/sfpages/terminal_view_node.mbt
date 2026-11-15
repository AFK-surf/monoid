// A terminal of a station's, viewed: over the whole window as a station's screen is, on every screen.
// The bar across its top is a viewer's (@sf.opened_head_node: @sf.viewer_bar_node on a wide window, @sf.nav_bar_node
// with its folder under its name on a narrow one): back to the page it was opened from by name; the folder it opened
// in; at its end 按键 (on a wide window) and 控制中心 (快捷操作, the station's terminals, 只看, 复制工作目录, 结束会话).
// Under the bar, while someone else types into it or while it is only looked at, who types and 接管 (or 控制).
// Under that the terminal's screen, on its own dark ground whatever the theme, in the code face, its runs in the
// colours the program gave them; when it has ended, an overlay in its middle with 重新打开.
// On a touch device while typing into it: when the keyboard is down, a compact foot bar (键盘, 粘贴, 按键) as
// screen_view.mbt's is; when the keyboard is up, the accessory keys row (esc, tab, ctrl, alt, arrows, and pinned 按键
// and 收起键盘 at its end).

///|
// kept across runs: the views' numbers, each page its own (a core's view id is the app's to choose)
let terminal_views : Ref[Int] = Ref(0)

///|
// kept across runs: what a fixture mode asks terminal_node to open as it is made ("kb", "keys", "center")
let terminal_asked : Ref[String] = Ref("")

///|
/// Ask the next `terminal_node` made to open a fixture state (`"kb"`, `"keys"`, `"center"`).
pub fn terminal_fixture_ask(what : String) -> Unit {
  terminal_asked.val = what
}

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
/// How far in from the screen's sides and top its cells start.
let terminal_in : Double = 14.0

///|
let terminal_over : Double = 10.0

///|
/// A run of a line as the host gives it: its text and how it looks.
fn terminal_run(r : Json, line_ratio : Double) -> @ui.Run? {
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
      color=if faint { (fg & 0xFFFFFF00L) | 0xB8L } else { fg },
      bg=match bg { Some(b) => b; None => if inverse { terminal_ink } else { 0L } },
      // (a cell's ground the whole of its cell: a line high, nothing either side, square)
      ground=Some({ room: 0.0, height: line_ratio, corner: 0.0, after: 0.0 }),
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
fn terminal_runs(said : String, line_ratio? : Double = terminal_line / terminal_size) -> Array[@ui.Run] {
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
              Array(runs) => for r in runs { match terminal_run(r, line_ratio) { Some(run) => out.push(run); None => () } }
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
/// How wide a cell of the screen is: the code face's M at `size`.
fn terminal_cell(size? : Double = terminal_size) -> Double {
  @ui.text_advance("M", size~, style=@hostapi.style_mono)
}

///|
/// How many cells a window `w` × `h` holds under the bar (`top` over it: a phone's status bar), at least 20 × 6, a cell
/// `cell` wide (terminal_cell, measured once a page); `head`, how tall all over the screen comes to as laid out, and
/// `foot`, how tall what stands under the screen comes to.
fn terminal_cells(
  w : Double,
  h : Double,
  top : Double,
  cell? : Double,
  head? : Double = 0.0,
  foot? : Double = 0.0,
  line_h? : Double = terminal_line,
) -> (Int, Int) {
  let cell = match cell {
    Some(c) => c
    None => terminal_cell()
  }
  let across = if cell > 0.0 { ((w - 2.0 * terminal_in) / cell).to_int() } else { 80 }
  let over = if head > 0.0 { head } else { top + @sf.viewer_bar_h }
  let down = ((h - over - foot - 2.0 * terminal_over) / line_h).to_int()
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
  let asked = terminal_asked.val
  terminal_asked.val = ""
  let wide = width is Some(_)
  let (w, h) = v.window()
  let base_cell = terminal_cell()
  let full : @signals.Signal[Bool] = @signals.signal(false)
  let fit80 : @signals.Signal[Bool] = @signals.signal(false)
  let kb_up : @signals.Signal[Bool] = @signals.signal(asked == "kb")
  let keys_open : @signals.Signal[Bool] = @signals.signal(asked == "keys")
  let state : @signals.Signal[Json?] = @signals.signal(None)
  let drawn : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
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
    if fit80.get() && base_cell > 0.0 {
      let avail = v.window().0 - 2.0 * terminal_in
      let want = 80.0 * base_cell
      if avail < want { dmax(0.68, avail / want) } else { 1.0 }
    } else {
      1.0
    }
  }
  let size_now = fn() { terminal_size * font_scale() }
  let line_now = fn() { (terminal_line * font_scale()).round() }
  let cell_now = fn() { base_cell * font_scale() }
  let head_h = fn() {
    if full.get() {
      0.0
    } else {
      let bar = top() + (if wide { @sf.viewer_bar_h } else { terminal_narrow_bar_h })
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
  let (cols, rows) = @signals.untracked(fn() {
    terminal_cells(w, h, top(), cell=cell_now(), head=head_h(), foot=foot_h(), line_h=line_now())
  })
  let kept : Ref[@hostapi.Terminal?] = Ref(@hostapi.Terminal::open(cols, rows))
  let last_lines : Ref[String] = Ref("")
  let last_drawn : Ref[Int] = Ref(-1)
  let read_screen = fn() -> String {
    let d = drawn.untracked()
    if d != last_drawn.val {
      last_drawn.val = d
      last_lines.val = match kept.val {
        Some(t) => t.lines()
        None => ""
      }
    }
    last_lines.val
  }
  let fresh = fn() {
    match kept.val { Some(t) => t.close(); None => () }
    let st = @signals.untracked(fn() { state.get() })
    let c = number(st, "cols").to_int()
    let r = number(st, "rows").to_int()
    kept.val = @hostapi.Terminal::open(if c > 0 { c } else { cols }, if r > 0 { r } else { rows })
  }
  let call_ref : Ref[Int?] = Ref(None)
  let open_stream = fn(term_id : String, watch_mode : Bool, init_cwd : String) {
    match call_ref.val {
      Some(c) => (src.cancel)(c)
      None => ()
    }
    state.set(None)
    fresh()
    drawn.set(drawn.untracked() + 1)
    let params : Array[(String, Json)] = [
      ("station", str(at.station)),
      ("terminal", str(term_id)),
      ("view", str(view)),
      ("cols", Json::number(cols.to_double())),
      ("rows", Json::number(rows.to_double())),
      ("control", Json::boolean(!watch_mode)),
      ..if init_cwd != "" && term_id == "new" { [("cwd", str(init_cwd))] } else { [] },
    ]
    call_ref.val = Some(
      (src.stream)("terminal.view", obj(params), None, fn(value, bytes) {
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
      }, @sfbase.answer_unread),
    )
  }
  open_stream(at.terminal, at.watch, at.cwd)
  v.owns(fn() {
    match call_ref.val {
      Some(c) => (src.cancel)(c)
      None => ()
    }
    call_ref.val = None
    match kept.val { Some(t) => t.close(); None => () }
    kept.val = None
  })
  |> ignore
  let cwd = fn() {
    let said = text(s(), "cwd")
    if said == "" { at.cwd } else { said }
  }
  let go_terminal = fn(term_id : String, watch_mode : Bool, next_cwd : String) {
    if term_id == at.terminal {
      open_stream(term_id, watch_mode, next_cwd)
    } else {
      @sfbase.app.nav.replace(Terminal({ station: at.station, terminal: term_id, watch: watch_mode, cwd: next_cwd }))
    }
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
  // Clipboard reading state (poll on frame or immediate in Tester)
  let clip_reading : Ref[@ui.ClipboardRead?] = Ref(None)
  let finish_paste = fn(words : String) {
    let pasted = terminal_pasted_of(words, terminal_bracketed_paste(read_screen()))
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
  // Modifiers on the accessory bar: `once` for the next key, `kept_mods` locked until pressed again
  let once : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
  let kept_mods : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
  let send = fn(k : @ui.KeyIn) {
    guard @signals.untracked(types) && !@signals.untracked(ended) else { return }
    if clip_reading.val is Some(r) && r.got() is Some(got) {
      clip_reading.val = None
      finish_paste(got.text)
    }
    if terminal_paste_key(k) {
      paste_clipboard()
      return
    }
    let app_keys = terminal_app_keys(read_screen())
    let mods = once.untracked() | kept_mods.untracked()
    let said = terminal_keys_of(terminal_held(k, mods), app_keys)
    if !(k is Key(down=false, ..)) {
      once.set(0)
    }
    raw_send(said)
  }
  let tap = fn(key : String, code : String) { send(Key(down=true, key~, code~, mods=0)) }
  let catcher_ref : Ref[@view.View?] = Ref(None)
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
  // 控制中心 panel (session-level management: station's terminals switcher + 新建终端, 全屏, 只看, 复制屏幕文字/工作目录, 结束会话)
  let open_center_panel = fn(from : @sf.Anchor) {
    @sf.panel_nodes(
      @sf.t("web-pages.screen.panel"),
      fn(p, done) {
        let terms = fn() { items(listed.get().value, "terminals") }
        p.show(fn() { terms().length() > 0 || may() }, fn(sec) {
          @sf.panel_group_node(sec, fn() { @sf.t("web-pages.terminal.title") }, fn(g) {
            g.each(terms, fn(t) { text(Some(t), "id") }, fn(row, t) {
              let tv = fn() { Some(t.get()) }
              let tid = text(@signals.untracked(tv), "id")
              let here = fn() {
                let cur = text(s(), "id")
                tid == (if cur == "" { at.terminal } else { cur })
              }
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
            g.show(may, fn(n) {
              @sf.panel_row_node(
                n,
                fn() { @sf.t("web-pages.terminal.new") },
                fn() {
                  done()
                  go_terminal("new", false, @signals.untracked(cwd))
                },
                icon=fn() { "plus" },
              )
            })
          })
        })
        @sf.panel_group_node(p, fn() { "" }, fn(g) {
          @sf.panel_row_node(
            g,
            fn() { @sf.t(if full.get() { "android-misc.screen.unfull" } else { "android-misc.screen.full" }) },
            fn() {
              full.set(!full.untracked())
              done()
            },
            icon=fn() { if full.get() { "shrink" } else { "expand" } },
          )
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
              let text = terminal_plain_text(read_screen())
              if text != "" {
                @ui.clipboard_set(text)
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
          g.show(fn() { may() && !ended() && text(s(), "id") != "" }, fn(e) {
            @sf.panel_rule_node(e)
            @sf.panel_row_node(
              e,
              fn() { @sf.t("web-pages.terminal.end") },
              fn() {
                let id = text(@signals.untracked(s), "id")
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
  v.grow(Is(1.0)).ground(By(fn() { @sf.theme().p.bg })) |> ignore
  // Top header bar (hidden in full screen)
  v.show(fn() { !full.get() }, fn(hd) {
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
  })
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
  let pad_key = fn(
    parent : @view.View,
    cap : String,
    name : String,
    press : () -> Unit,
    w_px : Double,
    h_px : Double,
    primary : Bool,
    held_fn : (() -> Bool)?,
    icon : String,
  ) {
    let is_held = held_fn.unwrap_or(fn() { false })
    parent.box(fn(b) {
      if w_px > 0.0 {
        b.width(Is(Some(w_px))) |> ignore
      } else {
        b.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      }
      b
      .height(Is(Some(h_px)))
      .radius(Is(10.0))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .ground(By(fn() {
        let p = @sf.theme().p
        let base = if primary || is_held() { p.primary } else { p.raised }
        if b.pressed() { @sf.over(base, p.hover) } else { base }
      }))
      .says(Is(Some(@view.said(Button, label=name))))
      |> ignore
      @sf.presses_node(b, press)
      let ink_fn = fn() {
        let p = @sf.theme().p
        if primary || is_held() { p.on_primary } else { p.text }
      }
      if icon != "" {
        @sf.icon_node(b, icon, 18.0, By(ink_fn)) |> ignore
      } else {
        b.box(fn(w) {
          w
          .words(Is(cap))
          .words_look(Is(@ui.style_words(key_tile_words)))
          .ink(By(ink_fn))
          .allow_ellipsis(Is(true))
          |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  }
  let dpad_cluster = fn(
    parent : @view.View,
    key_w : Double,
    key_h : Double,
    enter_w : Double,
    enter_h : Double,
  ) {
    parent.box(fn(cl) {
      cl.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(6.0)) |> ignore
      cl.box(fn(arrows) {
        arrows.lines_up(Is(Some(Middle))).gap(Is(4.0)) |> ignore
        pad_key(arrows, "↑", @sf.t("android-misc.screen.key.up"), fn() { tap("ArrowUp", "ArrowUp") }, key_w, key_h, false, None, "")
        arrows.box(fn(bot_r) {
          bot_r.row(Is(true)).gap(Is(4.0)) |> ignore
          pad_key(bot_r, "←", @sf.t("android-misc.screen.key.left"), fn() { tap("ArrowLeft", "ArrowLeft") }, key_w, key_h, false, None, "")
          pad_key(bot_r, "↓", @sf.t("android-misc.screen.key.down"), fn() { tap("ArrowDown", "ArrowDown") }, key_w, key_h, false, None, "")
          pad_key(bot_r, "→", @sf.t("android-misc.screen.key.right"), fn() { tap("ArrowRight", "ArrowRight") }, key_w, key_h, false, None, "")
        })
        |> ignore
      })
      |> ignore
      pad_key(cl, "⏎", @sf.t("web-pages.terminal.sendCmd"), fn() { tap("Enter", "Enter") }, enter_w, enter_h, true, None, "")
    })
    |> ignore
  }
  let drag_x : Ref[Double] = Ref(0.0)
  let drag_y : Ref[Double] = Ref(0.0)
  let kept_size : Ref[(Int, Int)?] = Ref(None)
  v.reacts(
    fn() {
      (
        terminal_cells(
          v.window().0,
          v.window().1,
          top(),
          cell=cell_now(),
          head=head_h(),
          foot=foot_h(),
          line_h=line_now(),
        ),
        types(),
      )
    },
    fn(said) {
      let ((c, r), is_typing) = said
      guard is_typing else { return }
      guard (c, r) != (cols, rows) || kept_size.val is Some(_) else { return }
      kept_size.val = Some((c, r))
      (src.call)(
        "terminal.resize",
        obj([("view", str(view)), ("cols", Json::number(c.to_double())), ("rows", Json::number(r.to_double()))]),
        @sfbase.answer_unread,
      )
      match kept.val {
        Some(t) => {
          t.resize(c, r)
          drawn.set(drawn.untracked() + 1)
        }
        None => ()
      }
    },
  )
  @ui.key_catcher_node(v, @sf.t("web-pages.terminal.title"), send, on=By(fn() { typing_here.get() }), fn(k) {
    catcher_ref.val = Some(k)
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
    .gesture(
      @ui.touch_slop(),
      tap=fn(_) {
        if @signals.untracked(fn() { typing_here.get() }) {
          keys_open.set(false)
          kb_up.set(true)
          @ui.key_catcher_focus_set(k, true)
        }
      },
      drag=fn(d) {
        guard @signals.untracked(fn() { typing_here.get() }) else { return }
        match d.kind {
          Down => {
            drag_x.val = d.wx
            drag_y.val = d.wy
          }
          Moved => {
            let step_x = 14.0
            let step_y = 18.0
            while (d.wx - drag_x.val).abs() >= step_x {
              if d.wx > drag_x.val {
                drag_x.val += step_x
                tap("ArrowRight", "ArrowRight")
              } else {
                drag_x.val -= step_x
                tap("ArrowLeft", "ArrowLeft")
              }
              @ui.haptic(TextHandleMove)
            }
            while (d.wy - drag_y.val).abs() >= step_y {
              if d.wy > drag_y.val {
                drag_y.val += step_y
                tap("ArrowDown", "ArrowDown")
              } else {
                drag_y.val -= step_y
                tap("ArrowUp", "ArrowUp")
              }
              @ui.haptic(TextHandleMove)
            }
          }
          Up | Off => ()
        }
      },
    )
    |> ignore
    k.box(fn(w) {
      w
      .words_runs(
        By(fn() {
          drawn.get() |> ignore
          terminal_runs(read_screen(), line_ratio=line_now() / size_now())
        }),
      )
      .words_look(
        By(fn() {
          { ..@view.words_plain, size: size_now(), line: line_now(), wrap: false }
        }),
      )
      .words_breaks(Is(true))
      .ink(Is(terminal_ink))
      |> ignore
    })
    |> ignore
    // Floating exit-fullscreen button in the top-right corner when full screen is on
    k.show(fn() { full.get() }, fn(f) {
      f
      .over(Is(true))
      .padding(By(fn() { (16.0, top() + 16.0, 16.0, 16.0) }))
      .lines_up(Is(Some(End)))
      |> ignore
      f.box(fn(cap) {
        @sf.style_node(cap, fn() { full_tools_box })
        cap.box(fn(b) {
          @sf.style_node(b, fn() {
            if b.pressed() { round_button_box.then(tile_pressed) } else { round_button_box }
          })
          b.says(By(fn() { Some(@view.said(Button, label=@sf.t("android-misc.screen.unfull"))) })) |> ignore
          @sf.presses_node(b, fn() { full.set(false) })
          @sf.icon_node(b, "shrink", round_icon, By(fn() { @ui.tree_theme().color(Fg) })) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    // Centered overlay when the terminal session has ended or failed
    k.show(ended, fn(ov) {
      ov
      .over(Is(true))
      .ground(Is(0x16171AD9L))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      |> ignore
      ov.box(fn(card) {
        @sf.style_node(card, fn() { ended_box })
        @sf.words_node(card, fn() { @sf.t("web-pages.terminal.ended") }, fn() { ended_title }) |> ignore
        let sub_text = fn() {
          let msg = text(s(), "message")
          if msg != "" { msg } else { cwd() }
        }
        card.show(fn() { sub_text() != "" }, fn(sub) {
          @sf.words_node(sub, sub_text, fn() { ended_why }).allow_ellipsis(Is(true)) |> ignore
        })
        card.show(may, fn(act) {
          @sf.button_node(
            act,
            fn() { @sf.t("web-pages.screen.again") },
            fn() { go_terminal("new", false, @signals.untracked(cwd)) },
            tone=Primary,
          )
          |> ignore
        })
      })
      |> ignore
    })
  })
  |> ignore
  // Bottom control deck on touch devices and inline 按键 tray on wide desktop
  v.show(deck_shown, fn(tray) {
    tray
    .gap(Is(6.0))
    .padding(By(fn() {
      let side = if wide { 12.0 } else { 8.0 }
      let top_pad = if wide { 8.0 } else { 6.0 }
      (side, top_pad, side, 6.0 + v.clear().2)
    }))
    |> ignore
    if !wide {
      tray.pick(fn() { (kb_shown(), keys_open.get()) }, fn(area, mode_state) {
        let (is_kb, is_keys) = mode_state
        if is_keys {
          ()
        } else if is_kb {
          // Keyboard Up: Single-row full-visibility strip (no cut-off arrow keys!)
          area.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(4.0)) |> ignore
          pad_key(area, "Esc", "Esc", fn() { tap("Escape", "Escape") }, 0.0, 42.0, false, None, "")
          pad_key(area, "Tab", "Tab", fn() { tap("Tab", "Tab") }, 0.0, 42.0, false, None, "")
          pad_key(area, "Ctrl", @sf.t("android-misc.screen.key.control"), fn() { held_press(@ui.key_in_ctrl) }, 0.0, 42.0, false, Some(held(@ui.key_in_ctrl)), "")
          pad_key(area, "Alt", @sf.t("android-misc.screen.key.option"), fn() { held_press(@ui.key_in_alt) }, 0.0, 42.0, false, Some(held(@ui.key_in_alt)), "")
          pad_key(area, "←", @sf.t("android-misc.screen.key.left"), fn() { tap("ArrowLeft", "ArrowLeft") }, 0.0, 42.0, false, None, "")
          pad_key(area, "↓", @sf.t("android-misc.screen.key.down"), fn() { tap("ArrowDown", "ArrowDown") }, 0.0, 42.0, false, None, "")
          pad_key(area, "↑", @sf.t("android-misc.screen.key.up"), fn() { tap("ArrowUp", "ArrowUp") }, 0.0, 42.0, false, None, "")
          pad_key(area, "→", @sf.t("android-misc.screen.key.right"), fn() { tap("ArrowRight", "ArrowRight") }, 0.0, 42.0, false, None, "")
          pad_key(area, "", @sf.t("web-pages.terminal.hideKeyboard"), fn() {
            kb_up.set(false)
            match catcher_ref.val {
              Some(k) => @ui.key_catcher_focus_set(k, false)
              None => ()
            }
          }, 0.0, 42.0, false, None, "chevron-down")
        } else {
          // Keyboard Down Default: Left 2x3 Action Grid + Right Inverted-T Arrow Pad & Tall Enter
          area.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
          area.box(fn(left) {
            left.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(4.0)) |> ignore
            left.box(fn(r1) {
              r1.row(Is(true)).gap(Is(5.0)) |> ignore
              pad_key(r1, "Esc", "Esc", fn() { tap("Escape", "Escape") }, 0.0, 41.0, false, None, "")
              pad_key(r1, "Tab", "Tab", fn() { tap("Tab", "Tab") }, 0.0, 41.0, false, None, "")
              pad_key(r1, "^C", @sf.t("web-pages.terminal.combo.interrupt"), fn() { raw_send("\u{03}") }, 0.0, 41.0, false, None, "")
            })
            |> ignore
            left.box(fn(r2) {
              r2.row(Is(true)).gap(Is(5.0)) |> ignore
              pad_key(r2, "键盘", @sf.t("android-misc.screen.keyboard"), fn() { kb_up.set(true) }, 0.0, 41.0, false, None, "")
              pad_key(r2, "粘贴", @sf.t("web-pages.screen.paste"), paste_clipboard, 0.0, 41.0, false, None, "")
              pad_key(r2, "Ctrl", @sf.t("android-misc.screen.key.control"), fn() { held_press(@ui.key_in_ctrl) }, 0.0, 41.0, false, Some(held(@ui.key_in_ctrl)), "")
            })
            |> ignore
          })
          |> ignore
          dpad_cluster(area, 38.0, 41.0, 44.0, 86.0)
        }
      })
    }
    tray.show(fn() { keys_open.get() }, fn(ext) {
      ext.gap(Is(6.0)) |> ignore
      if !wide {
        ext.box(fn(bar) {
          bar.row(Is(true)).gap(Is(6.0)) |> ignore
          pad_key(bar, "键盘", @sf.t("android-misc.screen.keyboard"), fn() {
            keys_open.set(false)
            kb_up.set(true)
          }, 0.0, 38.0, false, None, "")
          pad_key(bar, "粘贴", @sf.t("web-pages.screen.paste"), paste_clipboard, 0.0, 38.0, false, None, "")
          pad_key(bar, "", @sf.t("web-pages.terminal.hideKeyboard"), fn() { keys_open.set(false) }, 48.0, 38.0, false, None, "chevron-down")
        })
        |> ignore
      }
      let combo_cols = if wide { combos.length() } else { 3 }
      tiles_node(ext, combos.length(), combo_cols, key_tile_gap, fn(row, i) {
        let (label, seq) = combos[i]
        center_tile_node(row, key_tile_box, label, fn() { raw_send(seq) }, fn(t) {
          @sf.words_node(t, fn() { label }, fn() { key_tile_words }).allow_ellipsis(Is(true)) |> ignore
        })
      })
      let fn_cols = if wide { nav_and_fn.length() } else { 6 }
      tiles_node(ext, nav_and_fn.length(), fn_cols, key_tile_gap, fn(row, i) {
        let (label, act) = nav_and_fn[i]
        center_tile_node(row, key_tile_box, label, act, fn(t) {
          @sf.words_node(t, fn() { label }, fn() { key_tile_words }).allow_ellipsis(Is(true)) |> ignore
        })
      })
    })
  })
  // Open fixture center panel when asked by open_fixture ("keys" is now inline via keys_open signal!)
  if asked == "center" {
    open_center_panel(At(w - 28.0, top() + 24.0, 32.0, 32.0))
  }
}
