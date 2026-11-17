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
  held_beside.keys().any(drawn) || held_full.keys().any(drawn)
}

///|
/// `front`, one chat `r`'s panel shows in front, as the panel's tab picks it: tab_full_mark while it is over the whole
/// window, or the whole window's layer still draws it (it comes back to the panel as that goes), followed.
fn full_elsewhere(r : ChatRef, front : String) -> String {
  if @sfbase.tab_full_is(r.station, r.session, front) || held_full.contains(tab_hold_key(r, front)) {
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
fn tab_full_key_node(e : @view.View, r : ChatRef, front : () -> String, tips : @sf.TipLayer) -> Unit {
  @sf.icon_button_node(e, "expand", fn() { @sf.t("web-main.preview.fullWindow") }, fn() { @sfbase.tab_full_open(r, front()) }, tips~)
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
