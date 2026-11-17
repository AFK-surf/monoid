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
// kept across runs: put back as a run begins (on_reset)
let terminal_views : Ref[Int] = Ref(0)

///|
// kept across runs: put back as a run begins (on_reset)
let terminal_asked : Ref[String] = Ref("")

///|
fn init {
  @ui.on_reset(fn() {
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
  // (clear of the column of the system's bars down the window's trailing edge, an iPhone Duo's on its side: what it
  // shows and what is pressed in it, its grid's columns as wide as that leaves; its grounds on under it)
  let pane_w = fn() {
    let w = match width {
      Some(wf) => wf()
      None => v.window().0
    }
    dmax(0.0, w - @sf.native_clear())
  }
  let base_cell = terminal_cell()
  let full : @signals.Signal[Bool] = @signals.signal(false)
  let fit80 : @signals.Signal[Bool] = @signals.signal(false)
  let kb_up : @signals.Signal[Bool] = @signals.signal(asked == "kb")
  let keys_open : @signals.Signal[Bool] = @signals.signal(asked == "keys")
  let state : @signals.Signal[Json?] = @signals.signal(None)
  let drawn : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
  let modes_sig : @signals.Signal[Int] = @signals.signal(@hostapi.term_mode_viewport_active, same=fn(a, b) { a == b })
  let out_queued : Ref[Bool] = Ref(false)
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
      let avail = pane_w() - 2.0 * terminal_in
      let want = 80.0 * base_cell
      if avail < want { dmax(0.68, avail / want) } else { 1.0 }
    } else {
      1.0
    }
  }
  let size_now = fn() { terminal_size * font_scale() }
  let line_now = fn() { terminal_line * font_scale() }
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
  let dims_now = fn() -> (Int, Int, Int, Int) {
    let sz = size_now()
    let lh = line_now()
    let (cw, _, _) = @ui.terminal_grid_metrics(sz)
    let (c, r) = terminal_cells(pane_w(), v.window().1, top(), cell=cw, head=head_h(), foot=foot_h(), line_h=lh)
    let scale = v.pixel_scale()
    let px_cw = dmax(1.0, (cw * scale).round()).to_int()
    let px_ch = dmax(1.0, (lh * scale).round()).to_int()
    (c, r, px_cw, px_ch)
  }
  let (init_c, init_r, init_cw, init_ch) = @signals.untracked(dims_now)
  let cur_size : Ref[(Int, Int)] = Ref((init_c, init_r))
  let kept : Ref[@hostapi.Terminal?] = Ref(@hostapi.Terminal::open(init_c, init_r))
  match kept.val {
    Some(t) => t.resize(init_c, init_r, cell_w=init_cw, cell_h=init_ch)
    None => ()
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
  let call_ref : Ref[Int?] = Ref(None)
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
    let params : Array[(String, Json)] = [
      ("station", str(at.station)),
      ("terminal", str(term_id)),
      ("view", str(view)),
      ("cols", Json::number(c0.to_double())),
      ("rows", Json::number(r0.to_double())),
      ("control", Json::boolean(!watch_mode)),
      ..if init_cwd != "" && term_id == "new" { [("cwd", str(init_cwd))] } else { [] },
    ]
    call_ref.val = Some(
      (src.stream)("terminal.view", obj(params), None, fn(value, bytes) {
        match value {
          Object(o) if o.contains("state") => {
            let st = o.get("state")
            state.set(st)
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
  open_stream(at.terminal, at.watch, at.cwd)
  let fling_cancel : Ref[() -> Unit] = Ref(fn() {  })
  v.owns(fn() {
    (resize_cancel.val)()
    resize_cancel.val = fn() {  }
    (fling_cancel.val)()
    fling_cancel.val = fn() {  }
    match call_ref.val {
      Some(c) => (src.cancel)(c)
      None => ()
    }
    call_ref.val = None
    match kept.val {
      Some(t) => t.close()
      None => ()
    }
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
  // Modifiers on the accessory bar: `once` for the next key, `kept_mods` locked until pressed again
  let once : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
  let kept_mods : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
  let send = fn(k : @ui.KeyIn) {
    let modes = sync_modes()
    if terminal_copy_key(k) {
      if (modes & @hostapi.term_mode_has_selection) != 0 {
        copy_selection()
      }
      return
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
    let mods = once.untracked() | kept_mods.untracked()
    let said = terminal_keys_of(terminal_held(k, mods), app_keys)
    if !(k is Key(down=false, ..)) {
      once.set(0)
    }
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
    repeat : Bool,
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
      // Do NOT set .focusable(Is(true)) here so tapping accessory keys never blurs key_catcher_node / soft keyboard!
      .presses(Is(true))
      .on_press(press)
      |> ignore
      let rep_stop : Ref[() -> Unit] = Ref(fn() {  })
      let rep_fired : Ref[Bool] = Ref(false)
      let stop_rep = fn() {
        (rep_stop.val)()
        rep_stop.val = fn() {  }
      }
      b.owns(stop_rep) |> ignore
      let on_it = fn(d : @view.Drag) { b.finger_target(d.wx, d.wy) }
      b.gesture(
        @ui.touch_slop(),
        press=fn(d) {
          stop_rep()
          rep_fired.val = false
          if repeat {
            fn step(at_t : Double) -> Unit {
              rep_stop.val = b.at_moment(
                at_t,
                fn() {
                  if b.pressed() {
                    rep_fired.val = true
                    @ui.haptic(KeyboardTap)
                    press()
                    step(at_t + 45.0)
                  }
                },
                later=true,
              )
            }
            step(d.at + 400.0)
          }
        },
        tap=fn(d) {
          let already = rep_fired.val
          stop_rep()
          rep_fired.val = false
          if !already && on_it(d) {
            @ui.haptic(KeyboardTap)
            press()
          }
        },
        drag=fn(d) {
          match d.kind {
            Up => {
              let already = rep_fired.val
              stop_rep()
              rep_fired.val = false
              if !already && on_it(d) {
                press()
              }
            }
            Off => {
              stop_rep()
              rep_fired.val = false
            }
            _ => ()
          }
        },
      )
      |> ignore
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
        arrows.gap(Is(4.0)) |> ignore
        arrows.box(fn(top_r) {
          top_r.row(Is(true)).gap(Is(4.0)) |> ignore
          top_r.box(fn(sp) { sp.width(Is(Some(key_w))).height(Is(Some(key_h))) |> ignore }) |> ignore
          pad_key(top_r, "↑", @sf.t("android-misc.screen.key.up"), fn() { tap("ArrowUp", "ArrowUp") }, key_w, key_h, false, None, "", true)
          pad_key(top_r, "⌫", @sf.t("web-pages.terminal.backspace"), fn() { tap("Backspace", "Backspace") }, key_w, key_h, false, None, "", true)
        })
        |> ignore
        arrows.box(fn(bot_r) {
          bot_r.row(Is(true)).gap(Is(4.0)) |> ignore
          pad_key(bot_r, "←", @sf.t("android-misc.screen.key.left"), fn() { tap("ArrowLeft", "ArrowLeft") }, key_w, key_h, false, None, "", true)
          pad_key(bot_r, "↓", @sf.t("android-misc.screen.key.down"), fn() { tap("ArrowDown", "ArrowDown") }, key_w, key_h, false, None, "", true)
          pad_key(bot_r, "→", @sf.t("android-misc.screen.key.right"), fn() { tap("ArrowRight", "ArrowRight") }, key_w, key_h, false, None, "", true)
        })
        |> ignore
      })
      |> ignore
      pad_key(cl, "⏎", @sf.t("web-pages.terminal.sendCmd"), fn() { tap("Enter", "Enter") }, enter_w, enter_h, true, None, "", false)
    })
    |> ignore
  }
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
          return false
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
        let menu_items : Array[@sf.MenuItem?] = []
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
          .lines_up(Is(Some(End)))
          .lies_along(Is(End))
          |> ignore
          fl.show(
            fn() { @sf.soft_keyboard() && (modes_sig.get() & @hostapi.term_mode_has_selection) != 0 },
            fn(cp) {
              @sf.button_node(
                cp,
                fn() { @sf.t("web-pages.terminal.copySelection") },
                fn() {
                  copy_selection()
                  clear_selection()
                },
                tone=Plain,
              )
              |> ignore
            },
          )
          fl.show(
            fn() { (modes_sig.get() & @hostapi.term_mode_viewport_active) == 0 },
            fn(sb) {
              @sf.button_node(
                sb,
                fn() { @sf.t("web-pages.terminal.scrollBottom") },
                scroll_to_bottom,
                tone=Primary,
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
  v.show(deck_shown, fn(tray) {
    tray.box(fn(inner) {
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
                pad_key(bar, "键盘", @sf.t("android-misc.screen.keyboard"), fn() {
                  keys_open.set(false)
                  kb_up.set(true)
                }, 0.0, 38.0, false, None, "", false)
                pad_key(bar, "粘贴", @sf.t("web-pages.screen.paste"), paste_clipboard, 0.0, 38.0, false, None, "", false)
                pad_key(bar, "", @sf.t("web-pages.terminal.hideKeyboard"), fn() { keys_open.set(false) }, 48.0, 38.0, false, None, "chevron-down", false)
              })
              |> ignore
              build_ext_tiles(area)
            } else if kind == 1 {
              // Keyboard Up: Single-row full-visibility strip with Backspace & auto-repeat
              area.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(3.0)) |> ignore
              pad_key(area, "Esc", "Esc", fn() { tap("Escape", "Escape") }, 0.0, 42.0, false, None, "", false)
              pad_key(area, "Tab", "Tab", fn() { tap("Tab", "Tab") }, 0.0, 42.0, false, None, "", false)
              pad_key(area, "Ctrl", @sf.t("android-misc.screen.key.control"), fn() { held_press(@ui.key_in_ctrl) }, 0.0, 42.0, false, Some(held(@ui.key_in_ctrl)), "", false)
              pad_key(area, "Alt", @sf.t("android-misc.screen.key.option"), fn() { held_press(@ui.key_in_alt) }, 0.0, 42.0, false, Some(held(@ui.key_in_alt)), "", false)
              pad_key(area, "←", @sf.t("android-misc.screen.key.left"), fn() { tap("ArrowLeft", "ArrowLeft") }, 31.0, 42.0, false, None, "", true)
              pad_key(area, "↓", @sf.t("android-misc.screen.key.down"), fn() { tap("ArrowDown", "ArrowDown") }, 31.0, 42.0, false, None, "", true)
              pad_key(area, "↑", @sf.t("android-misc.screen.key.up"), fn() { tap("ArrowUp", "ArrowUp") }, 31.0, 42.0, false, None, "", true)
              pad_key(area, "→", @sf.t("android-misc.screen.key.right"), fn() { tap("ArrowRight", "ArrowRight") }, 31.0, 42.0, false, None, "", true)
              pad_key(area, "⌫", @sf.t("web-pages.terminal.backspace"), fn() { tap("Backspace", "Backspace") }, 31.0, 42.0, false, None, "", true)
              pad_key(area, "", @sf.t("web-pages.terminal.hideKeyboard"), fn() {
                kb_up.set(false)
                match catcher_ref.val {
                  Some(k) => @ui.key_catcher_focus_set(k, false)
                  None => ()
                }
              }, 31.0, 42.0, false, None, "chevron-down", false)
            } else {
              // Keyboard Down Default: Left 2x3 Action Grid + Right Inverted-T Arrow Pad + Backspace + Tall Enter
              area.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
              area.box(fn(left) {
                left.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(4.0)) |> ignore
                left.box(fn(r1) {
                  r1.row(Is(true)).gap(Is(5.0)) |> ignore
                  pad_key(r1, "Esc", "Esc", fn() { tap("Escape", "Escape") }, 0.0, 41.0, false, None, "", false)
                  pad_key(r1, "Tab", "Tab", fn() { tap("Tab", "Tab") }, 0.0, 41.0, false, None, "", false)
                  pad_key(r1, "^C", @sf.t("web-pages.terminal.combo.interrupt"), fn() { raw_send("\u{03}") }, 0.0, 41.0, false, None, "", false)
                })
                |> ignore
                left.box(fn(r2) {
                  r2.row(Is(true)).gap(Is(5.0)) |> ignore
                  pad_key(r2, "键盘", @sf.t("android-misc.screen.keyboard"), fn() { kb_up.set(true) }, 0.0, 41.0, false, None, "", false)
                  pad_key(r2, "粘贴", @sf.t("web-pages.screen.paste"), paste_clipboard, 0.0, 41.0, false, None, "", false)
                  pad_key(r2, "Ctrl", @sf.t("android-misc.screen.key.control"), fn() { held_press(@ui.key_in_ctrl) }, 0.0, 41.0, false, Some(held(@ui.key_in_ctrl)), "", false)
                })
                |> ignore
              })
              |> ignore
              dpad_cluster(area, 38.0, 41.0, 44.0, 86.0)
            }
          },
        )
      }
    })
    |> ignore
  })
  // Open fixture center panel when asked by open_fixture ("keys" is now inline via keys_open signal!)
  if asked == "center" {
    open_center_panel(At(pane_w() - 28.0, top() + 24.0, 32.0, 32.0))
  }
}
