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
    // (one tab alone its title only on the tape: beside a chat, its tabs always, no structure to pick between them)
    if on_tape {
      bar.pick(at_once=true, alone, fn(p, alone) {
        if alone {
          side_title_node(p, src, r, view, fn() { tabs().get(0).unwrap_or("") })
        } else {
          @sf.style_node(p, fn() { side_tab_list }, in_row=true)
          side_tabs_node(p, src, r, view, tabs, front, tips)
        }
      })
    } else {
      side_tabs_node(bar, src, r, view, tabs, front, tips)
    }
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
    // a `.mbui` / `.wasm` mini-program in front: its single bar's 全屏, before 在新窗口打开 as a screen's are (no second file toolbar row under it; any other
    // tab's is its own bar's), the tab over the whole window (tab_full_node.mbt)
    bar.show(at_once=true, fn() {
      match @sfbase.view_tab_file(front()) {
        Some(f) => @sfbase.is_mbui_viz(f.file.name)
        None => false
      }
    }, fn(e) {
      e.shrink(Is(0.0)) |> ignore
      tab_full_key_node(e, r, front, tips, linked=bar_linked)
    })
    // 在新窗口打开, one key (one show) for what it sends: the station's screen or terminal in front to a window of its
    // own, else a tab that goes over the whole window in front (a file, a mini-program, a web service, a
    // visualization) to its third place (tab_full_node.mbt's tab_window_open)
    bar.show(at_once=true, fn() { window_page() is Some(_) || tab_window_offered(r, front()) }, fn(e) {
      e.shrink(Is(0.0)) |> ignore
      @sf.icon_button_node(e, "external", fn() { @sf.t("web-pages.screen.window") }, fn() {
        let tab = front()
        match window_page() {
          Some(p) => if @sfbase.open_window(p) { side_change(src, r, "close", Some(tab)) }
          None => tab_window_open(src, r, tab) |> ignore
        }
      }, tips~, linked=bar_linked)
      |> ignore
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
          let job_held = @sfbase.topic_value_held(src, "job", {
            "station": Json::string(r.station),
            "id": Json::string(job),
          })
          jobs_pop_dot(d, fn() { text(job_held.get(), "tone") })
        })
        |> ignore
    }
  })
}

///|
/// The panel's tabs in `p` (@sf.tab_bar_node's capsules, one tab list: Tab stopping at the one in front, ← → bringing
/// each in front): each its mark and its name, cut short where the tabs have not the room (all of it in its tip then,
/// but for the chat's own four), pressed to bring it in front; its × at its end closing it, concentric with it, a
/// control of its own. In front on the selected ground, its words the words' colour and 500; behind, lit by the hand
/// on the pointer's ground, its mark and words brought up to the words' colour.
fn side_tabs_node(
  p : @view.View,
  src : Source,
  r : ChatRef,
  view : () -> ChatView?,
  tabs : () -> Array[String],
  front : () -> String,
  tips : @sf.TipLayer,
) -> Unit {
  // each service tab's job, held as it was while a new ask of it has no answer yet (the panel taken back kept left)
  let jobs_held : Map[String, @signals.Computed[Json?]] = Map([])
  let job_of = fn(job : String) -> Json? {
    let held = match jobs_held.get(job) {
      Some(c) => c
      None => {
        let c = @sfbase.topic_value_held(src, "job", { "station": Json::string(r.station), "id": Json::string(job) })
        jobs_held[job] = c
        c
      }
    }
    held.get()
  }
  let names = fn(tab : String) { side_tab_names(src, r, view(), tab, job_of~) }
  @sf.tab_bar_node(
    p,
    fn() { @sf.t("web-pages.screen.tabs") },
    tabs,
    front,
    fn(tab) { side_front_pressed(src, r, tab) },
    fn(tab) { names(tab).0 },
    fn(b, tab, shown) {
      side_mark_node(b, src, r, view, tab, fn() { shown.front() || shown.lit() })
      @sf.words_node(b, fn() { names(tab).0 }, fn() {
        if shown.front() {
          side_tab_front
        } else if shown.lit() {
          side_tab_words_lit
        } else {
          side_tab_words
        }
      })
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      |> ignore
    },
    close=fn(tab) { side_change(src, r, "close", Some(tab)) },
    close_label=fn(tab) { names(tab).1 },
    at_once=true,
    tips~,
    tip=fn(tab) { !(tab is ("jobs" | "files" | "letters" | "things")) },
  )
  .grow(Is(1.0))
  .min_width(Is(Some(0.0)))
  |> ignore
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
