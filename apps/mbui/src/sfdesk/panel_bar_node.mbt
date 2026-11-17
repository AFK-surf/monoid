// A chat's side panel's bar (sideBar: panel.mbt's styles) as nodes of the window's tree, made once over whatever tab is
// in front, beside the page (side_panel_node) and on the tape (tape_side_node): its tabs, each its mark, its name and
// its ×, the one in front on the selected ground (or on the tape, a tab alone, its title), a mini-program's 全屏, the
// station's screen to a window of its own, the panel's switch at its end; its empty part the app's own top row, moving
// the window.

///|
/// What a tab's mark is (side_mark_of): an icon by its name, an agent's maker's mark, a web service's dot of how its
/// job is.
#derive(Eq)
priv enum SideMark {
  Icon(String)
  Maker(String, String)
  Dot(String)
}

///|
/// Tab `tab`'s mark as chat `r`'s view `v` has it now: a station's tab its kind's icon, an agent's its maker's, a web
/// service's its job's dot, a mini-program its own (`.mbui` / `.wasm`: its manifest's), else the icon of what it shows.
fn side_mark_of(src : Source, r : ChatRef, v : ChatView?, tab : String) -> SideMark {
  match station_tab(tab) {
    Some((kind, station, screen)) =>
      return Icon(
        match kind {
          "drive" => "folder"
          "adb" => "phone"
          "terminal" => "terminal"
          "screen" => {
            let card = src.topic("screenCard", { "station": Json::string(station), "screen": Json::string(screen) }).get().value
            let sk = text(card, "kind")
            if sk == "simulator" {
              "phone"
            } else if sk == "browser" || screen.has_prefix("browser:") {
              "web"
            } else {
              "monitor"
            }
          }
          _ => "monitor"
        },
      )
    None => ()
  }
  match v.bind(fn(v) { v.agents.iter().find_first(fn(a) { a.key == tab }) }) {
    Some(a) => return Maker(a.maker, a.runtime)
    None => ()
  }
  match tab_service(tab) {
    Some(job) => return Dot(job)
    None => ()
  }
  Icon(
    if @sfbase.view_tab_file(tab) is Some(f) {
      if @sfbase.is_mbui_viz(f.file.name) {
        @sfbase.tab_mbui_meta(src, tabs_key(r), tab, f, r.station).1
      } else if @sfbase.preview_kind(f.file.name).0 == Some(@sfbase.KImage) {
        "photo"
      } else {
        "file"
      }
    } else if tab_file(tab) is Some(_) {
      "file"
    } else if tab == "jobs" {
      "boxes"
    } else if tab == "files" {
      "folder"
    } else if tab == "things" {
      "photo"
    } else {
      "chats"
    },
  )
}

///|
/// Whether the panel showing `tabs` (`front` in front) as node `n` is drawn has no bar of the panel's over what is in
/// front, that having one of its own (side_bars'): a web service alone on the tape, the station's screen alone on its
/// side; never a tab the tree shows (side_node_tab), whose bar is the panel's.
fn side_own_bar_node(n : @view.View, tabs : Array[String], front : String, on_tape : Bool) -> Bool {
  let alone = on_tape && tabs.length() == 1
  // (a web service alone on the tape: its bar the panel's, as it has been)
  if alone && tab_service(front) is Some(_) {
    return true
  }
  // (a station's screen alone in it upright: the screen's bar its own, in the panel's bar's look: side_screen_node)
  let (ww, wh) = n.window()
  if side_screen_tab(front) is Some(_) && screen_tab_alone(tabs) && !column_short.get() && ww <= wh {
    return true
  }
  if side_node_tab(front) {
    return false
  }
  alone && tab_service(front) is Some(_)
}

///|
/// The bar's look: beside the page side_bar's, its switch at the window's corner; on the tape side_bar_tape's, in the
/// tape's panel's corners as they are now; each corner as the tree has the window's.
fn side_bar_look_node(on_tape : Bool) -> @ui.Style {
  if on_tape {
    let roots = @ui.tree_corner_roots_now()
    side_bar_tape_in(beside_column(tape_pane_corners(Panel, true), tape_room_now().under).map(fn(c) { c.radius(roots) }))
  } else {
    side_bar_look.then(
      @ui.style(pr=@sf.room_of(@sf.window_end_in(side_bar_end, roots=@ui.tree_corner_roots_now()))),
    )
  }
}

///|
/// Chat `r`'s panel's bar in node `n` (side_bar_row's), what it shows as `shown` says it (its tabs and the one in front),
/// read by `src`; on the tape (`on_tape`) a panel of its own, a tab alone its title. Its tips in `tips`.
fn side_bar_node(
  n : @view.View,
  src : Source,
  r : ChatRef,
  shown : () -> (Array[String], String),
  on_tape : Bool,
  tips : @sf.TipLayer,
) -> Unit {
  // (its head alone: told as the chat's agents or thread change, not as a word comes into a message)
  let view = fn() { @sfbase.chat_view_now(src, r) }
  let tabs = fn() { shown().0 }
  let front = fn() { shown().1 }
  let alone = fn() { on_tape && tabs().length() == 1 }
  n.box(fn(bar) {
    @sf.style_node(bar, fn() { side_bar_look_node(on_tape) })
    // (the desktop app has no title bar: the panel's bar drags the window as the page's does, where nothing in it
    // takes the press)
    bar.shrink(Is(0.0)).moves_window(By(@ui.window_inset_now)) |> ignore
    bar.pick(at_once=true, alone, fn(p, alone) {
      if alone {
        side_title_node(p, src, r, view, fn() { tabs().get(0).unwrap_or("") })
      } else {
        @sf.style_node(p, fn() { side_tab_list }, in_row=true)
        p.each(at_once=true, tabs, fn(t) { t }, fn(row, tab) {
          let tab = @signals.untracked(fn() { tab.get() })
          side_tab_node(row, src, r, view, tab, fn() { front() == tab }, tips)
        })
      }
    })
    // the station's screen or terminal in front: expand to full window, or pop out to a window of its own (a screen's
    // with touch its own 全屏 does it, over all of it with the system's bars put away: sfpages' full_asked, so not
    // twice)
    let bar_linked = fn() { if on_tape { None } else { @sf.bar_keys_link() } }
    let expandable_page = fn() {
      match station_tab_page(r, front()) {
        Some(Screen(_)) if @sf.soft_keyboard() => None
        p => p
      }
    }
    bar.show(at_once=true, fn() { expandable_page() is Some(_) }, fn(e) {
      e.shrink(Is(0.0)) |> ignore
      @sf.icon_button_node(e, "expand", fn() { @sf.t("web-main.preview.fullWindow") }, fn() {
        match expandable_page() {
          Some(p) => {
            @sfbase.history_push()
            app.nav.push(p)
          }
          None => ()
        }
      }, tips~, linked=bar_linked)
      |> ignore
    })
    let window_page = fn() {
      match station_tab_page(r, front()) {
        Some(p) if @sfbase.window_opens_for(p) => Some(p)
        _ => None
      }
    }
    bar.show(at_once=true, fn() { window_page() is Some(_) }, fn(e) {
      e.shrink(Is(0.0)) |> ignore
      @sf.icon_button_node(e, "external", fn() { @sf.t("web-pages.screen.window") }, fn() {
        let tab = front()
        match station_tab_page(r, tab) {
          Some(p) if @sfbase.open_window(p) => side_change(src, r, "close", Some(tab))
          _ => ()
        }
      }, tips~, linked=bar_linked)
      |> ignore
    })
    // a `.mbui` / `.wasm` mini-program in front: its single bar's 全屏 (no second file toolbar row under it; any other
    // tab's is its own bar's), the tab over the whole window (tab_full_node.mbt)
    bar.show(at_once=true, fn() {
      match @sfbase.view_tab_file(front()) {
        Some(f) => @sfbase.is_mbui_viz(f.file.name)
        None => false
      }
    }, fn(e) {
      e.shrink(Is(0.0)) |> ignore
      tab_full_key_node(e, r, front, tips)
    })
    // the panel's switch stays in its top right corner, open or closed; in the short column, the column's
    // (histories_ticked)
    bar.show(at_once=true, fn() { !column_short.get() }, fn(e) {
      e.shrink(Is(0.0)) |> ignore
      @sf.icon_button_node(
        e,
        "panel-close",
        fn() { @sf.t("web-pages.chat.closePanel") },
        fn() { side_change(src, r, "clear", None) },
        tips~,
        icon_now=fn() { if alone() { "close" } else { "panel-close" } },
        linked=fn() { if on_tape { None } else { @sf.bar_keys_link() } },
        shortcut="panel.close",
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// Tab `tab`'s mark in `n` (side_mark_of's, as `view` has it), in the words' colour while `bright` (in front, or lit by
/// the hand), muted otherwise; an agent's maker's and a service's dot as they are.
fn side_mark_node(n : @view.View, src : Source, r : ChatRef, view : () -> ChatView?, tab : String, bright : () -> Bool) -> Unit {
  n.pick(fn() { side_mark_of(src, r, view(), tab) }, at_once=true, fn(m, mark) {
    m.shrink(Is(0.0)) |> ignore
    match mark {
      Icon(name) =>
        @sf.icon_node(m, name, side_tab_mark_side, By(fn() {
          let t = @sf.theme()
          if bright() {
            t.p.text
          } else {
            t.p.muted
          }
        }))
        |> ignore
      Maker(maker, runtime) => @sf.maker_mark_node(m, maker, runtime, side_tab_mark_side) |> ignore
      Dot(job) =>
        m.box(fn(d) {
          @sf.style_node(d, fn() { side_tab_mark })
          jobs_pop_dot(d, fn() {
            text(src.topic("job", { "station": Json::string(r.station), "id": Json::string(job) }).get().value, "tone")
          })
        })
        |> ignore
    }
  })
}

///|
/// A tab in `row` (side_tab_of's): its mark and its name, cut short where the tabs have not the room (all of it in its
/// tip then, but for the chat's own four), pressed to bring it in front; its × beside them closing it, a control of its
/// own (not in what brings it in front: its room to be pressed in reaching past the tab's height, @view.press_room). In
/// front (`front`) on the selected ground, its words the words' colour and 500; behind, lit by the hand on the
/// pointer's ground, its mark and words brought up to the words' colour.
fn side_tab_node(
  row : @view.View,
  src : Source,
  r : ChatRef,
  view : () -> ChatView?,
  tab : String,
  front : () -> Bool,
  tips : @sf.TipLayer,
) -> Unit {
  let names = fn() { side_tab_names(src, r, view(), tab) }
  @sf.style_node(row, side_tab_row, in_row=true)
  // (short of room in the list, a tab gives way, its words cut short, its mark and × whole: sideTab's min-width 0)
  row.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
  let body : Ref[@view.View?] = Ref(None)
  let lit = fn() {
    !front() &&
    (@sf.lit_in_node(row) ||
    (match body.val {
      Some(b) => @sf.lit_node(b)
      None => false
    }))
  }
  row
  .ground(By(fn() {
    if front() {
      @ui.tree_theme().color(Selected)
    } else if lit() {
      @ui.tree_theme().color(Hover)
    } else {
      0L
    }
  }))
  |> ignore
  row.box(fn(b) {
    body.val = Some(b)
    @sf.style_node(b, side_tab_body, in_row=true)
    b.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    b.says(By(fn() { Some(@view.said(Tab, label=names().0, selected=front())) })) |> ignore
    @sf.presses_node(b, fn() { side_front_pressed(src, r, tab) })
    side_mark_node(b, src, r, view, tab, fn() { front() || lit() })
    @sf.words_node(b, fn() { names().0 }, fn() {
      if front() {
        side_tab_front
      } else if lit() {
        side_tab_words_lit
      } else {
        side_tab_words
      }
    })
    |> ignore
    if !(tab is ("jobs" | "files" | "letters" | "things")) {
      @sf.tip_node(tips, b, fn() { names().0 }, repeats=true) |> ignore
    }
  })
  |> ignore
  // (its close 20 round, its icon 12: side_tab_close's)
  @sf.icon_button_node(row, "close", fn() { names().1 }, fn() { side_change(src, r, "close", Some(tab)) }, size=20.0, icon_size=12.0)
  .shrink(Is(0.0))
  |> ignore
}

///|
/// A tab's capsule (side_tab_shape's): 30 high, round, its close 5 from its end; what brings it in front from its start
/// (side_tab_body), its close after it. (Made as it is asked, not kept at the program's start: the start's one function
/// is at Wasm's most locals, 50000.)
fn side_tab_row() -> @ui.Style {
  @ui.style(row=true, h=@sf.side_tab_h, pr=S1_25, gap=S1_5, align=ACenter, radius=Full)
}

///|
/// What brings a tab in front (side_tab_shape's start): as high as the tab and round at its start as the tab is (its
/// focus there, concentric with it), its mark in the middle of the tab's start, its label 6 after it.
fn side_tab_body() -> @ui.Style {
  @ui.style(row=true, h=Full, pl=@sf.capsule_end_room(@sf.side_tab_side, side_tab_mark_side), gap=S1_5, align=ACenter, radius=Full)
}

///|
/// The one tab of a panel of its own on the tape as its title in `n` (side_title's): its mark and its name as the page's
/// bar has its title, read out a heading; what closes the panel at the bar's end the only close.
fn side_title_node(n : @view.View, src : Source, r : ChatRef, view : () -> ChatView?, tab : () -> String) -> Unit {
  @sf.style_node(n, fn() { side_title_row }, in_row=true)
  n.says(By(fn() { Some(@view.said(Heading, label=side_tab_names(src, r, view(), tab()).0)) })) |> ignore
  n.pick(tab, at_once=true, fn(m, tab) {
    m.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)).grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    side_mark_node(m, src, r, view, tab, fn() { true })
    @sf.words_node(m, fn() { side_tab_names(src, r, view(), tab).0 }, fn() { side_title_words }) |> ignore
  })
}
