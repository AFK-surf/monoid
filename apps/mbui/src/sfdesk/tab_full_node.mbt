// A tab of a chat's side panel over the whole window (全屏; what it is and how it is asked: sfbase's tab_full.mbt), as
// nodes of the window's tree over the wide frame (sfapp's tape_shell.mbt, both of its shells): the bar every file
// opened over a wide window has (@sf.viewer_bar_node: back to the chat by its name, the tab's name, a file's keys as
// its tools' row has them, 移到侧边), under it the tab drawn by the nodes that draw it in the panel (a file's stage, a
// web service's bar and page, a visualization's page), the panel showing nothing of it meanwhile (full_elsewhere), and
// neither drawing it while the other still does (tab_held: what it holds, a service's address, is one editor's). A
// modal layer while it is open: back, Escape, the bar's way back and 移到侧边 put it back in the panel, the tab staying;
// its chat no longer the page in view, it goes back there too.

///|
/// What a panel's front stands as while its tab is over the whole window (no tab is named so).
let tab_full_mark : String = "\u{0}full"

///|
/// Whether tab `tab` goes over the whole window (its 全屏 offered): a file in the viewer (a `.mbui` / `.wasm`
/// mini-program too), a web service, a visualization.
fn full_offered(tab : String) -> Bool {
  @sfbase.view_tab_file(tab) is Some(_) || tab_service(tab) is Some(_) || tab_file(tab) is Some(_)
}

///|
/// What puts tab `tab` of chat `r`'s panel over the whole window, where it goes there (its bar's 全屏).
fn full_of(r : ChatRef, tab : String) -> (() -> Unit)? {
  if full_offered(tab) {
    Some(fn() { @sfbase.tab_full_open(r, tab) })
  } else {
    None
  }
}

///|
/// How many nodes of the panel (beside) and of the whole window's layer (full) draw each tab that goes over the whole
/// window, by tab_hold_key, while they live.
// kept across runs: each count given back as the node holding it goes; put back by sv_reset
let held_beside : @sf.LiveMap[String, Int] = @sf.LiveMap::new()

///|
// kept across runs: as held_beside
let held_full : @sf.LiveMap[String, Int] = @sf.LiveMap::new()

///|
/// How many nodes of a window of its own draw each tab there (tab_window_node), as held_beside.
// kept across runs: as held_beside
let held_window : @sf.LiveMap[String, Int] = @sf.LiveMap::new()

///|
fn tab_hold_key(r : ChatRef, tab : String) -> String {
  tabs_key(r) + "\n" + tab
}

///|
/// Tab `tab` of chat `r` drawn by node `n` into `held` while `n` lives.
fn tab_held(n : @view.View, held : @sf.LiveMap[String, Int], r : ChatRef, tab : String) -> Unit {
  let key = tab_hold_key(r, tab)
  held.set(key, held.get(key).unwrap_or(0) + 1)
  n.owns(fn() {
    match held.get(key) {
      Some(c) if c > 1 => held.set(key, c - 1)
      _ => held.remove(key)
    }
  })
  |> ignore
}

///|
/// Whether the page of `station`'s `job` (a service's, a visualization's: tab_job) is drawn by a chat's tab now, in its
/// panel or over the whole window: its page let go as the tab closes (tab_let_go), not as the page that asked for it is
/// replaced by the chat (beside_follow).
pub fn service_tab_held(station : String, job : String) -> Bool {
  let drawn = fn(key : String) {
    match key.find("\n") {
      Some(i) =>
        key.has_prefix(station + ":") && tab_job(key.unsafe_substring(start=i + 1, end=key.length())) == Some(job)
      None => false
    }
  }
  held_beside.keys().any(drawn) || held_full.keys().any(drawn) || held_window.keys().any(drawn)
}

///|
/// `front`, one chat `r`'s panel shows in front, as the panel's tab picks it: tab_full_mark while it is over the whole
/// window or in a window of its own, or the whole window's layer or that window still draws it (it comes back to the
/// panel as that goes: 移到侧边 in the window), followed.
fn full_elsewhere(r : ChatRef, front : String) -> String {
  let key = tab_hold_key(r, front)
  if @sfbase.tab_full_is(r.station, r.session, front) ||
    held_full.contains(key) ||
    @sfbase.window_has_tab(r.station, r.session, front) ||
    held_window.contains(key) {
    tab_full_mark
  } else {
    front
  }
}

///|
/// Tab `tab` of chat `r` drawn in its panel by node `n` (each that goes over the whole window: full_offered).
fn tab_held_beside(n : @view.View, r : ChatRef, tab : String) -> Unit {
  if full_offered(tab) {
    tab_held(n, held_beside, r, tab)
  }
}

///|
/// 全屏 in a panel's bar, in `e`: chat `r`'s tab in front (`front()`, as it is at the press) over the whole window.
fn tab_full_key_node(
  e : @view.View,
  r : ChatRef,
  front : () -> String,
  tips : @sf.TipLayer,
  linked~ : () -> @ui.CornerOf?,
) -> Unit {
  @sf.icon_button_node(e, "expand", fn() { @sf.t("web-main.preview.fullWindow") }, fn() { @sfbase.tab_full_open(r, front()) }, tips~, linked~)
  |> ignore
}

///|
/// The ink of the bar over a tab over the whole window: a file's opened over it (@sf.page_viewer_ink) on the page's
/// ground.
fn full_ink() -> @sf.ViewerInk {
  { ..@sf.page_viewer_ink(), ground: @sf.theme().p.bg }
}

///|
/// The tab over the whole window, if one is, in node `v` of the window's tree (laid out over the wide frame's pages),
/// made as one goes there and let go as it comes back: while its chat is the page in view; that no longer so, back in
/// its panel at that change, and so as the wide frame goes (小屏, no panel to be back in).
pub fn tab_full_layer_node(v : @view.View, src : Source) -> Unit {
  let src = src.owned_by(v)
  let asked = fn() {
    match (@sfbase.tab_full.get(), @sfbase.app.nav.top()) {
      (Some(f), Chat(c)) if c.station == f.chat.station && c.session == f.chat.session => Some(f)
      _ => None
    }
  }
  // (drawn once the panel no longer draws it)
  let shown = fn() {
    match asked() {
      Some(f) if !held_beside.contains(tab_hold_key(f.chat, f.tab)) => Some(f)
      _ => None
    }
  }
  v.box(fn(layer) {
    layer.over(Is(true)) |> ignore
    layer.owns(fn() { @sfbase.tab_full_close() }) |> ignore
    layer.reacts(fn() { (@sfbase.tab_full.get() is Some(_), asked() is Some(_)) }, fn(now) {
      if now.0 && !now.1 {
        @sfbase.tab_full_close()
      }
    })
    layer.pick(at_once=true, shown, fn(n, open) {
      match open {
        Some(f) => tab_full_node(n, src, f)
        None => ()
      }
    })
  })
  |> ignore
}

///|
/// Tab `f` over the whole window in `n` (tab_full_layer_node's): its bar over it, it under that as the panel draws it.
fn tab_full_node(n : @view.View, src : Source, f : @sfbase.TabFull) -> Unit {
  let r = f.chat
  let tab = f.tab
  tab_held(n, held_full, r, tab)
  let back = fn() { @sfbase.tab_full_close() }
  // (while it is open: the pages under it take no press, key or wheel; back and Escape put it back in its panel; the
  // keyboard's focus its own ground's as it opens, never a field of the page under it or of its own, given back as it
  // goes)
  n
  .over(Is(true))
  .modal(Is(true))
  .focus_opens_first(takes=fn(_) { false })
  |> ignore
  // (a field of the page under it, the composer's, let go of: its keys, Escape too, no longer its)
  n.focus_let_go()
  n
  // (on the page's ground, as the tab is beside the chat; its bar on it too, as a file read over the whole window has
  // its bar on its paper: full_ink)
  .ground(By(fn() { @sf.theme().p.bg }))
  .on_key(fn(k) {
    if k.code == @ui.key_escape {
      back()
      true
    } else {
      false
    }
  })
  .takes_back(back)
  |> ignore
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = @sf.TipLayer::new(fn() { tips_at.val })
  let room = fn() { (@sf.viewer_host().room)() }
  let width = fn() { n.window().0 }
  let mini = match @sfbase.view_tab_file(tab) {
    Some(f) => @sfbase.is_mbui_viz(f.file.name)
    None => false
  }
  n.box(fn(page) {
    page.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    // (under the bar, clear of the column of the system's bars down its trailing edge: an iPhone Duo's on its side)
    page.box(fn(top) { top.height(By(fn() { Some(room().0 + @sf.viewer_bar_h) })).shrink(Is(0.0)) |> ignore }) |> ignore
    page.box(fn(body) {
      body
      .grow(Is(1.0))
      .shrink(Is(1.0))
      .basis(Is(Some(0.0)))
      .min_height(Is(Some(0.0)))
      .padding(By(fn() { (0.0, 0.0, @sf.native_clear(), room().1) }))
      |> ignore
      if @sfbase.view_tab_file(tab) is Some(_) {
        side_view_node(body, src, r, tab, fn(b) { dmax(0.0, b.window().0 - @sf.native_clear()) }, None, tools=false)
      } else if tab_service(tab) is Some(job) {
        service_tab_node(body, src, r, job, None, None, None, tips)
      } else if tab_file(tab) is Some((session, path, name)) {
        file_tab_node(body, src, r, session, path, name, None, tips)
      }
    })
    |> ignore
  })
  |> ignore
  // its bar across the top, over it: back to the chat by its name, the tab's name, 移到侧边
  n.box(fn(b) {
    b.over(Is(true)) |> ignore
    let ink = full_ink
    @sf.viewer_bar_node(
      b,
      fn() {
        match @sfbase.chat_view_now(src, r) {
          Some(v) if v.title != "" => v.title
          _ => if r.title != "" { r.title } else { @sf.t("common.back") }
        }
      },
      // (a file's name and the line about it as its tools' row has them; anything else, a mini-program too, as its tab
      // is named)
      fn() {
        match @sfbase.viewer_tab_title(src, tabs_key(r), tab) {
          (name, _) if name != "" && !mini => name
          _ => side_tab_names(src, r, @sfbase.chat_view_now(src, r), tab).0
        }
      },
      fn() { if mini { "" } else { @sfbase.viewer_tab_title(src, tabs_key(r), tab).1 } },
      fn() { "" },
      fn() { false },
      fn(_) { 1.0 },
      fn() { room().0 },
      width,
      ink,
      fn(row, corner) {
        // (a file's keys as its tools' row beside the chat has them: 预览 / 源码, the reader's panels, 下载; a
        // mini-program has none there)
        if @sfbase.view_tab_file(tab) is Some(_) && !mini {
          @sfbase.viewer_tab_bar_tools(row, corner, src, tabs_key(r), tab, tips)
        }
        // (在新窗口打开 where a window of its own can show it: the tab there, this put away as it goes: tab_window_open)
        row.show(at_once=true, fn() { tab_window_offered(r, tab) }, fn(w) {
          @sf.tool_node(
            w,
            fn() { { icon: "external", label: @sf.t("web-pages.screen.window"), on: false, disabled: false } },
            ink,
            corner,
            fn() { tab_window_open(src, r, tab) |> ignore },
            tip=tips,
          )
          |> ignore
        })
        @sf.tool_node(
          row,
          fn() { { icon: "panel-open", label: @sf.t("web-main.preview.moveBeside"), on: false, disabled: false } },
          ink,
          corner,
          back,
          tip=tips,
        )
        |> ignore
      },
      back,
      tips,
    )
    |> ignore
  })
  |> ignore
  tips_at.val = Some(n.box(fn(l) { l.over(Is(true)) |> ignore }))
}

// A tab of a chat's side panel in a window of its own, its third place (sfbase's window.mbt: a window of this run beside
// the first): 在新窗口打开 in the panel's bar or over the whole window's bar sends it there, the tab leaving the panel as
// a station's screen does (what it holds, a file's viewer, a service's page and its site view, the run's, handed over:
// never let go of as it leaves, tab_let_go), drawn there by the nodes that draw it beside the chat under the bar a file
// opened over a wide window has. 移到侧边 there puts it back in the panel, in front, and closes the window; the window
// closed otherwise (its own close button, ⌘W) lets the tab go as its tab closed beside the chat would.

///|
/// The core each tab in a window of its own was sent there from, by tab_hold_key: what lets it go as the window closes
/// (tab_window_left).
// kept across runs: put back by sv_reset, each taken out as its window closes or gives the tab back
let tab_window_srcs : Map[String, Source] = Map([])

///|
fn init {
  @sfbase.window_tab_left.val = tab_window_left
}

///|
/// The window of its own showing tab `f` closed by the person (sfbase's window_tab_left): the tab let go of, as its tab
/// closed beside the chat would be.
fn tab_window_left(f : @sfbase.TabFull) -> Unit {
  let key = tab_hold_key(f.chat, f.tab)
  match tab_window_srcs.get(key) {
    Some(src) => {
      tab_window_srcs.remove(key)
      tab_let_go(src, f.chat, f.tab)
    }
    None => ()
  }
}

///|
/// Whether tab `tab` of chat `r` can go to a window of its own here (sfbase's window_opens_for), followed as the panel's
/// front changes.
fn tab_window_offered(r : ChatRef, tab : String) -> Bool {
  full_offered(tab) && @sfbase.window_opens_for(SideTab({ chat: r, tab }))
}

///|
/// Tab `tab` of chat `r` sent to a window of its own (在新窗口打开): whether it went. The window brought to the front
/// where one shows it already; over the whole window, that put away; the tab off the panel, what it holds that window's.
pub fn tab_window_open(src : Source, r : ChatRef, tab : String) -> Bool {
  let f : @sfbase.TabFull = { chat: r, tab }
  guard tab_window_offered(r, tab) else { return false }
  let key = tab_hold_key(r, tab)
  let had = tab_window_srcs.get(key)
  tab_window_srcs[key] = src
  if !@sfbase.open_window(SideTab(f)) {
    match had {
      Some(s) => tab_window_srcs[key] = s
      None => tab_window_srcs.remove(key)
    }
    return false
  }
  if @signals.untracked(fn() { @sfbase.tab_full_is(r.station, r.session, tab) }) {
    @sfbase.tab_full_close()
  }
  side_change(src, r, "close", Some(tab))
  true
}

///|
/// Tab `f` of the window of its own this is back in its chat's panel, in front (移到侧边): the window gives it back
/// first (sfbase's window_gives_back: nothing let go of as it closes), the caller closing it after.
fn tab_window_back(src : Source, f : @sfbase.TabFull) -> Unit {
  @sfbase.window_gives_back(@ui.current_window_id())
  tab_window_srcs.remove(tab_hold_key(f.chat, f.tab))
  side_change(src, f.chat, "open", Some(f.tab))
  // (the first window to the front, where its chat's panel shows the tab: put away by the person, brought back)
  @hostapi.window_front_id(0) |> ignore
}

///|
/// Tab `f` in a window of its own, in node `n` (sfapp's lone_tree): drawn once neither the panel nor the whole window's
/// layer draws it still (what it holds, a service's address, is one editor's: tab_held), its bar `top` under the
/// window's top (the window's top row itself where the bar keeps clear of its buttons, as over the whole window), it
/// under that as the panel draws it. `on_close`: what closes the window.
pub fn tab_window_node(
  n : @view.View,
  src : Source,
  f : @sfbase.TabFull,
  top~ : () -> Double,
  on_close~ : () -> Unit,
) -> Unit {
  let key = tab_hold_key(f.chat, f.tab)
  n.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  n.pick(at_once=true, fn() { !held_beside.contains(key) && !held_full.contains(key) }, fn(m, free) {
    if free {
      tab_window_body_node(m, src, f, top, on_close)
    }
  })
}

///|
/// Tab `f` in a window of its own, in `n` (tab_window_node's, once it is that window's alone).
fn tab_window_body_node(
  n : @view.View,
  src : Source,
  f : @sfbase.TabFull,
  top : () -> Double,
  on_close : () -> Unit,
) -> Unit {
  let r = f.chat
  let tab = f.tab
  tab_held(n, held_window, r, tab)
  // (the tab given back through the core as the app holds it, not this window's: what it asks there is answered after
  // this window's nodes are let go of)
  let app_src = src
  let src = src.owned_by(n)
  n.grow(Is(1.0)).min_height(Is(Some(0.0))).ground(By(fn() { @sf.theme().p.bg })) |> ignore
  let back = fn() {
    tab_window_back(app_src, f)
    on_close()
  }
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = @sf.TipLayer::new(fn() { tips_at.val })
  let width = fn() { n.window().0 }
  let mini = match @sfbase.view_tab_file(tab) {
    Some(v) => @sfbase.is_mbui_viz(v.file.name)
    None => false
  }
  // the tab's name, its bar's and the window's own as it comes (a service's job named as the core answers): the window's
  // by its id, taken as it is made, as what tells it may come between frames, the first window's runtime in place
  let title_now = fn() {
    match @sfbase.viewer_tab_title(src, tabs_key(r), tab) {
      (name, _) if name != "" && !mini => name
      _ => side_tab_names(src, r, @sfbase.chat_view_now(src, r), tab).0
    }
  }
  let wid = @ui.current_window_id()
  n.reacts(title_now, fn(t) { if t != "" { @ui.set_window_title_of(wid, t) } })
  // its bar across the top, over `host`: no way back (the window's own close, ⌘W, closes it, as a screen's window
  // alone: sf's viewer_bar_node), the tab's name, a file's keys, 移到侧边
  let bar_over = fn(host : @view.View) {
    host.box(fn(b) {
      b.over(Is(true)) |> ignore
      let ink = full_ink
      @sf.viewer_bar_node(
        b,
        fn() { "" },
        title_now,
        fn() { if mini { "" } else { @sfbase.viewer_tab_title(src, tabs_key(r), tab).1 } },
        fn() { "" },
        fn() { false },
        fn(_) { 1.0 },
        top,
        width,
        ink,
        fn(row, corner) {
          if @sfbase.view_tab_file(tab) is Some(_) && !mini {
            @sfbase.viewer_tab_bar_tools(row, corner, src, tabs_key(r), tab, tips)
          }
          @sf.tool_node(
            row,
            fn() { { icon: "panel-open", label: @sf.t("web-main.preview.moveBeside"), on: false, disabled: false } },
            ink,
            corner,
            back,
            tip=tips,
          )
          |> ignore
        },
        on_close,
        tips,
      )
      |> ignore
    })
    |> ignore
  }
  match (tab_service(tab), tab_file(tab)) {
    // a web service, a visualization: its page's own bar the window's one bar, its 移到侧边 at its end; while it is
    // not up (connecting, stopped, not found, unreadable), the bar above over what is said in its place
    (Some(job), _) if @sfbase.view_tab_file(tab) is None =>
      n.box(fn(body) {
        body.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        service_tab_node(body, src, r, job, None, None, None, tips, beside=Some(back), bar=Some(bar_over))
      })
      |> ignore
    (_, Some((session, path, name))) if @sfbase.view_tab_file(tab) is None =>
      n.box(fn(body) {
        body.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        file_tab_node(body, src, r, session, path, name, None, tips, beside=Some(back), bar=Some(bar_over))
      })
      |> ignore
    // a file in the viewer: under the bar as over the whole window
    _ => {
      n.box(fn(page) {
        page.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        page.box(fn(t) { t.height(By(fn() { Some(top() + @sf.viewer_bar_h) })).shrink(Is(0.0)) |> ignore }) |> ignore
        page.box(fn(body) {
          body.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
          side_view_node(body, src, r, tab, fn(b) { b.window().0 }, None, tools=false)
        })
        |> ignore
      })
      |> ignore
      bar_over(n)
    }
  }
  tips_at.val = Some(n.box(fn(l) { l.over(Is(true)) |> ignore }))
}
