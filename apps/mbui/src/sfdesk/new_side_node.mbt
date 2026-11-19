// The new chat's side panel made as nodes (newchat.mbt's new_files_panel, side_beside's, in the window's tree beside
// the page made as nodes: side_panel_node's), in a pane off the tape: its one tab, Station 文件, the stations lending
// their files (files_tab_node, as a chat's 文件 tab), what is added going into the new chat's draft; kept open or closed
// by the core on this device as a chat's tabs are (`chatTabs` by `new:<workspace>`: new_files_open, new_files_set),
// sliding in and out as a chat's panel does (side_slides). On the tape it is a panel of its own beside the page's, in
// the tape's panel (tape_view.mbt's tape_side_node: tape_new_side_node).

///|
/// Workspace `w`'s new chat's panel in column `col` of the page's row (side_panel_node's, by `key`, its `new:<ws>`):
/// its column as wide as side_col has it while its 文件 is open where a station lends its files, moved aside with the
/// page; in it, while it shows, the panel as wide as it is at rest (cut to the column while it slides), its bar and the
/// tab; its edge beside the page.
fn new_side_node(col : @view.View, src : Source, w : Workspace, key : String, tips : @sf.TipLayer) -> Unit {
  let address = fn() { new_drive_station(src, w) }
  let open = fn() { new_files_open(src, w.id) && address() is Some(_) }
  let close = fn() { new_files_set(src, w.id, false) }
  col.reacts(open, fn(open) { side_slides(col, src, key, "", open) })
  let over = fn() { pane_w_at(src, col) < side_both_least }
  let at = fn() { side_col(src, col, key, open()) }
  col
  .shrink(Is(0.0))
  .width(By(fn() { Some(if over() { 0.0 } else { at() }) }))
  .clips(By(fn() { !over() && at() < side_whole(src, col) }))
  .offset(By(fn() { (pane_aside_at(src, col), 0.0) }))
  |> ignore
  // (shown while open, and while it slides out as its tab was closed: side_leaving)
  col.show(at_once=true, fn() { open() || side_leaving(key) is Some(_) }, fn(p) {
    p
    .grow(Is(1.0))
    .min_height(Is(Some(0.0)))
    .width(By(fn() { Some(side_whole(src, p)) }))
    .offset(By(fn() { (if over() { -at() } else { 0.0 }, 0.0) }))
    .ground(By(fn() { @sf.theme().p.bg }))
    .shadow(By(fn() {
      if over() {
        let (blur, fall) = @ui.Shadow::Xl.blur_y()
        (blur, fall, @ui.tree_theme().shadow)
      } else {
        (0.0, 0.0, 0L)
      }
    }))
    |> ignore
    // (panel.close: the panel closed, at its key's moment)
    p.on_action("panel.close", fn(_) {
      close()
      true
    })
    |> ignore
    new_side_bar_node(p, close, tips)
    p.box(fn(q) {
      q.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).clips(Is(true)) |> ignore
      // (the station its tab starts at, as the page's picks say it: another, the tab made again there)
      q.pick(address, fn(t, at) {
        t.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        match at {
          Some(station) =>
            files_tab_node(t, src, w.id, key, station, fn() { @sf.foot_corner(@sf.button_height(), ftab_side, ftab_under) }, tips)
          None => ()
        }
      })
    })
    |> ignore
  })
  // its edge, beside the page only
  col.show(at_once=true, fn() { !over() && open() }, fn(e) { side_edge_node(e, src, close, tips) })
}

///|
/// Workspace `ws`'s new chat's panel on the tape, in its panel `q` (tape_side_node's, its ground and corners round it),
/// read by `src`: its bar on the tape's line and its one tab, as beside the page (new_side_node), 添加 in the panel's
/// foot corner, concentric with it, as a chat's 文件 on the tape (side_files_node's). Kept while it slides out as its
/// tab was closed (tape_shown_side: side_leaving).
fn tape_new_side_node(q : @view.View, src : Source, ws : String, tips : @sf.TipLayer) -> Unit {
  let key = "new:" + ws
  let close = fn() { new_files_set(src, ws, false) }
  // (the last station it was at kept while none is said, so that sliding out it is not emptied)
  let last : Ref[String?] = { val: None }
  let address = fn() {
    let now = match @sfbase.workspace_in_view(src).0 {
      Some(w) if w.id == ws => new_drive_station(src, w)
      _ => None
    }
    if now is Some(_) {
      last.val = now
    }
    last.val
  }
  // (panel.close: the panel closed, at its key's moment)
  q.on_action("panel.close", fn(_) {
    close()
    true
  })
  |> ignore
  new_side_bar_node(q, close, tips, tape=true)
  q.box(fn(b) {
    b.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).clips(Is(true)) |> ignore
    // (the station its tab starts at, as the page's picks say it: another, the tab made again there)
    b.pick(address, fn(t, at) {
      t.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      match at {
        Some(station) =>
          files_tab_node(t, src, ws, key, station, fn() {
            @sf.pane_round.val = Some(beside_column(tape_pane_corners(Panel, true), tape_room_now().under))
            let st = @sf.foot_corner(@sf.button_height(), ftab_side, ftab_under)
            @sf.pane_round.val = None
            st
          }, tips)
        None => ()
      }
    })
  })
  |> ignore
}

///|
/// The new chat's panel's bar in `n` (new_files_panel's, side_bar_node's look beside the page, on the tape's line where
/// `tape`): its one tab in front, Station 文件, its mark and its name, its × closing it; the panel's switch at the bar's
/// end closing it as well (`close`). Its tips in `tips`.
fn new_side_bar_node(n : @view.View, close : () -> Unit, tips : @sf.TipLayer, tape? : Bool = false) -> Unit {
  let name = fn() { @sf.t("web-pages.chat.files") }
  n.box(fn(bar) {
    @sf.style_node(bar, fn() { side_bar_look_node(tape) })
    // (the desktop app has no title bar: the panel's bar drags the window as the page's does, where nothing in it
    // takes the press)
    bar.shrink(Is(0.0)).moves_window(By(@ui.window_inset_now)) |> ignore
    // (its one tab, in front, as a chat's panel's tabs are: @sf.tab_bar_node's capsule, its × closing the panel)
    @sf.tab_bar_node(
      bar,
      fn() { @sf.t("web-pages.screen.tabs") },
      fn() { ["files"] },
      fn() { "files" },
      fn(_) {  },
      fn(_) { name() },
      fn(b, _, _) {
        @sf.icon_node(b, "folder", side_tab_mark_side, By(fn() { @sf.theme().p.text })) |> ignore
        @sf.words_node(b, name, fn() { side_tab_front }).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      },
      close=fn(_) { close() },
      close_label=fn(_) { @sf.t("web-pages.chat.close", args=[("name", name())]) },
      at_once=true,
      tips~,
    )
    .grow(Is(1.0))
    .min_width(Is(Some(0.0)))
    |> ignore
    bar.box(fn(e) {
      e.shrink(Is(0.0)) |> ignore
      @sf.icon_button_node(
        e,
        "panel-close",
        fn() { @sf.t("web-pages.chat.closePanel") },
        close,
        tips~,
        // (none on the tape: its buttons round on the tape's line, concentric with its corner, as a chat's panel's)
        linked=fn() { if tape { None } else { @sf.bar_keys_link() } },
        shortcut="panel.close",
      )
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
