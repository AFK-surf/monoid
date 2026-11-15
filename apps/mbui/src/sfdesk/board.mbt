// Home as the board in the wide frame's pane (sfpages' board_node): the sidebar closed to its bar while it shows
// (place_bare's, as 连接 and 用量 have it), the board the pane's whole; a card pressed, its chat beside the board, its
// bar of its own over it (its title, 全屏打开 to its page, × to close it), the chat's page as the pane draws it.

///|
/// The source the wide frame was last made over (pane_view's, tape_view's): what whether the workspace in view shows
/// its board is read of where no source is given (place_bare_now).
// kept across runs: put back by wide_reset as a run starts
let board_frame_src : Ref[Source?] = Ref(None)

///|
/// Whether Home shows as the board in the wide frame: the board chosen in the workspace in view, Home alone on the
/// stack.
fn board_bare() -> Bool {
  match board_frame_src.val {
    Some(src) => @sfbase.board_on_now(src) && app.nav.depth() == 1 && app.nav.top() is Home
    None => false
  }
}

///|
/// Whether workspace `ws` shows its board, as the wide frame's source has it (board_frame_src).
fn board_on_in(ws : String) -> Bool {
  match board_frame_src.val {
    Some(src) => @sfbase.board_on_of(src, ws)
    None => false
  }
}

///|
/// Home made in the pane off the tape (pane_made's): the board while it is chosen, else the page's ground alone.
fn board_home_made(src : Source, tips : @sf.TipLayer) -> (String, (@view.View, () -> Page, Page?, () -> Int, Int) -> Unit) {
  (
    "home",
    fn(v, _page, _under, _stint, k) {
      pane_made_host(v, src, k)
      board_listed_back()
      v.show(fn() { @sfbase.board_on_now(src) }, fn(b) {
        b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        // (laid out as wide as the pane is where the block's move goes, as every page made in the pane is (pane_made's
        // `width`): moved with the pane as the sidebar closes beside it, its columns' words never wrapped anew on the
        // way, each frame's width another)
        let width = fn() {
          let ww = b.window().0
          match @sfbase.workspace_in_view(src).0 {
            Some(w) => ww - fold_target(src, w, ww).1.col
            None => ww
          }
        }
        @sfpages.board_node(b, src, tips, fn() { @sfbase.workspace_in_view(src).0 }, width, beside=fn(s, r) {
          board_beside(s, src, r, tips, k)
        })
      }, at_once=true)
    },
  )
}

///|
/// Home made in the tape's page panel (Medium): the board while it is chosen, on the panel's ground (its tone behind
/// as the panel is behind), as wide as the stack is in the panel; else the panel's ground alone. Its cards open their
/// chat as the page's, over it (back to the board), no chat beside it.
fn board_tape_made(src : Source, tips : @sf.TipLayer, width : () -> Double) -> (String, (@view.View, () -> Page, Page?, () -> Int, Int) -> Unit) {
  (
    "home",
    fn(v, _page, _under, _stint, _k) {
      v.lends(@sf.pane_lent, true).grow(Is(1.0)).min_height(Is(Some(0.0))).ground(By(fn() { tape_page_ground(v) })) |> ignore
      context_node(v)
      board_listed_back()
      v.show(fn() { @sfbase.board_on_now(src) }, fn(b) {
        b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        @sfpages.board_node(b, src, tips, fn() { @sfbase.workspace_in_view(src).0 }, width, ground=fn() {
          tape_page_ground(b)
        }, columns=true, bar_frame=fn(parent, make) { board_tape_bar(parent, make) })
      }, at_once=true)
    },
  )
}

///|
/// What 列表 does on the tape besides showing the list: the sidebar brought over, the list in use (nothing left in the
/// page's panel to look at).
fn board_listed_back() -> Unit {
  @sfbase.board_listed.val = fn() {
    if wide.tape.get() {
      wide.tape_ask.set(Some(Side))
    }
  }
}

///|
/// Chat `r` beside the board: on the page's paper, a line at its start, its bar over its page (the chat's page as the
/// pane draws it, its old view as yet).
fn board_beside(s : @view.View, src : Source, r : ChatRef, tips : @sf.TipLayer, serial : Int) -> Unit {
  s.row(Is(true)).grow(Is(1.0)).min_height(Is(Some(0.0))).ground(By(fn() { @sf.theme().p.bg })) |> ignore
  // (a line the whole height at its start, between it and the board)
  s.box(fn(line) {
    line.width(Is(Some(1.0))).shrink(Is(0.0)).ground(By(fn() { @sf.theme().p.line })) |> ignore
  })
  |> ignore
  s.box(fn(col) {
    col.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    col.box(fn(page) {
      page.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      // (the chat's page as the pane draws it, its old view in Home's entry's island: let go with it, as a side panel's)
      app.nav.page_island(page, serial, fn(c, _page) {
        match @sfbase.workspace_in_view(src).0 {
          Some(w) => chat_page(c, src, w, r)
          None => ()
        }
      }, key=fn() { tape_island_key() + " board " + r.station + ":" + r.session })
      .grow(Is(1.0))
      |> ignore
    })
    |> ignore
    col.box(fn(bar) {
      bar
      .over(Is(true))
      .height(Is(Some(chat_bar_room(in_pane=false))))
      .row(Is(true))
      .gap(Is(4.0))
      .lines_up(Is(Some(Middle)))
      .padding(Is((16.0, 0.0, 10.0, 0.0)))
      .ground(By(fn() { @sf.theme().p.bg }))
      |> ignore
      bar.box(fn(t) {
        t.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(t, fn() {
          match view_of_chat(src, r).0 {
            Some(v) => v.title
            None => r.title
          }
        }, fn() { beside_title_look }) |> ignore
      })
      |> ignore
      @sf.icon_button_node(bar, "expand", fn() { @sf.t("web-main.board.full") }, fn() {
        @sfbase.board_set(src, false)
        open_page(Chat(r))
      }, tips~)
      |> ignore
      @sf.icon_button_node(bar, "close", fn() { @sf.t("web-main.board.close") }, fn() { @sfbase.board_pick.set(None) }, tips~)
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let beside_title_look : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, wrap=false)

///|
/// The sidebar's key to the board (beside its filter, as it looks): the chats as columns, the sidebar closed to its bar.
fn board_key_node(f : @view.View, src : Source, tips : @sf.TipLayer) -> Unit {
  let hot = @sf.EdgeWay::new(0.0)
  f.reacts(fn() { @sf.lit_node(f) }, fn(on) { hot.go(f, if on { 1.0 } else { 0.0 }, @sf.dur_ms) })
  @sf.style_node(f, fn() { filter_box })
  f.radius(Is(1.0e6)).ground(By(fn() { @sf.alpha(@sf.theme().p.hover, hot.shown(f)) })) |> ignore
  // (on the tape the page's panel brought over with it: the board is what it holds)
  @sf.presses_node(f, fn() {
    @sfbase.board_set(src, true)
    if wide.tape.get() {
      bring_page()
    }
  })
  f.says(By(fn() { Some(@view.said(Button, label=@sf.t("web-main.board.board"))) })) |> ignore
  @sf.icon_node(f, "view-columns", side_icon, By(fn() {
    let t = @sf.theme()
    @sf.mix(t.p.text, hot.shown(f), t.p.muted)
  }))
  |> ignore
  @sf.tip_node(tips, f, fn() { @sf.t("web-main.board.board") }) |> ignore
}

///|
/// The board's bar in the tape's page panel, laid out as the panel's bar is (pane_bar_node's): as tall, as far under
/// the panel's top, its ends as far in as the panel's top corners leave what stands there concentric with them; read
/// out only while the panel is in use.
fn board_tape_bar(parent : @view.View, make : (@view.View) -> Unit) -> Unit {
  let corners = fn() {
    let side = tape_shown_side()
    let under = if side is None { tape_room_now().under } else { 0.0 }
    beside_column(tape_pane_corners(Page, side is Some(_)), under)
  }
  parent.box(fn(bar) {
    bar
    .row(Is(true))
    .shrink(Is(0.0))
    .height(By(fn() { Some(pane_bar_h()) }))
    .padding(By(fn() { (0.0, @ui.Space::px(@sf.tape_bar_over_room()), 0.0, 1.0) }))
    .lines_up(Is(Some(Middle)))
    .hides(By(fn() { wide.tape_at.get() != Page }))
    |> ignore
    bar_room_node(bar, fn() { tape_bar_start_room(corners(), true) })
    bar.box(fn(inner) {
      inner.row(Is(true)).grow(Is(1.0)).min_width(Is(Some(0.0))).lines_up(Is(Some(Middle))) |> ignore
      make(inner)
    })
    |> ignore
    bar_room_node(bar, fn() { tape_bar_end_room(corners(), side=@sf.button_height()) })
  })
  |> ignore
}
