// Home as the board, the rail's 看板 (right under 对话, while 实验性功能's 对话列表看板视图 is on; sfpages' board_node):
// off the tape (大屏) the sidebar closed to its bar while it shows (place_bare_now's, as 连接 and 用量 have it), the
// board the pane's whole, a card pressed its chat beside the board, its bar of its own over it (its title, 全屏打开 to
// its page, × to close it), the chat's page as the pane draws it; on the tape (中屏) the board the page's panel's,
// brought over as 看板 is pressed, the sidebar's list beside it as ever. 对话 pressed from it, the list again with the
// chat that was open as 看板 was gone to (board_kept_chat).

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
/// The pane's board width, both for the board's arrangement and a notification opening a chat beside it.
fn board_width(src : Source, w : Workspace, ww : Double) -> Double {
  ww - fold_target(src, w, ww).1.col
}

///|
/// A notification while the board is in view opens its chat as a card does, if the board has room beside it. A chat
/// page, another workspace or a narrower board keeps the ordinary page-opening path.
pub fn notice_on_board(src : Source, r : ChatRef, ww : Double) -> Bool {
  guard !wide.tape.get() && board_bare() && @sfbase.workspace_in_view(src).0 is Some(w) &&
    @sfbase.workspace_of(r.station) == w.id && board_width(src, w, ww) >= @sfpages.board_beside_from else {
    return false
  }
  @sfbase.board_pick.set(Some(r))
  true
}

///|
/// Home made in the pane off the tape (pane_made's): the board while it is chosen, else the page's ground alone.
fn board_home_made(src : Source, tips : @sf.TipLayer) -> (String, (@view.View, () -> Page, Page?, () -> Int, Int) -> Unit) {
  (
    "home",
    fn(v, _page, _under, stint, k) {
      pane_made_host(v, src, k)
      board_listed_back()
      // (once made, put by as it was while the list is chosen (View::each's `keeps`), taken in again at once as the
      // board is: not made anew at each switch)
      v.each(fn() { if @sfbase.board_on_now(src) { [0] } else { [] } }, fn(k) { k }, keeps=fn() { [0] }, at_once=true, fn(b, _) {
        b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        // (laid out as wide as the pane is where the block's move goes, as every page made in the pane is (pane_made's
        // `width`): moved with the pane as the sidebar closes beside it, its columns' words never wrapped anew on the
        // way, each frame's width another)
        let width = fn() {
          let ww = b.window().0
          match @sfbase.workspace_in_view(src).0 {
            Some(w) => board_width(src, w, ww)
            None => ww
          }
        }
        // The window offers ⌘W to what is in use before closing; the chat beside the board closes as its × does.
        b.on_action("window.close_panel", fn(_) {
          @sfbase.board_pick.set(None)
          true
        }, can=fn() { width() >= @sfpages.board_beside_from && @sfbase.board_pick.get() is Some(_) })
        |> ignore
        @sfpages.board_node(b, src, tips, fn() { @sfbase.workspace_in_view(src).0 }, width, beside=fn(s, r) {
          board_beside(s, src, r, tips, k)
        }, bar_frame=fn(parent, make) { board_pane_bar(parent, src, make) }, archive=fn() { board_archive_go(src) }, stint~)
      })
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
    fn(v, _page, _under, stint, _k) {
      v.lends(@sf.pane_lent, true).grow(Is(1.0)).min_height(Is(Some(0.0))).ground(By(fn() { tape_page_ground(v) })) |> ignore
      context_node(v)
      board_listed_back()
      // (once made, put by while the list is chosen and taken in again, as board_home_made's)
      v.each(fn() { if @sfbase.board_on_now(src) { [0] } else { [] } }, fn(k) { k }, keeps=fn() { [0] }, at_once=true, fn(b, _) {
        b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        @sfpages.board_node(b, src, tips, fn() { @sfbase.workspace_in_view(src).0 }, width, ground=fn() {
          tape_page_ground(b)
        }, columns=true, bar_frame=fn(parent, make) { board_tape_bar(parent, make) }, archive=fn() { board_archive_go(src) }, stint~)
      })
    },
  )
}

///|
/// The board's bar in the pane off the tape, laid out as a chat's bar there is (chat_bar_wide_node's, its ends
/// pane_chat_bar_ends'): as tall, its start past the rail and the window's buttons as the block is closed, its margins
/// while the folded sidebar is shown a while, its end at the window's corner, or the bar's own room before the chat open
/// beside the board; its empty part dragging the window, in one with its buttons in the app's top row.
fn board_pane_bar(parent : @view.View, src : Source, make : (@view.View) -> Unit) -> Unit {
  let ends = pane_chat_bar_ends(src, parent)
  let high = fn() { @sf.wide_bar_h + (ends.over)() }
  parent.box(fn(held) {
    held
    .row(Is(true))
    .shrink(Is(0.0))
    .height(By(fn() { Some(high()) }))
    // (its margins as spaces at its ends, one less than none taken back by drawing the row moved back as far)
    .offset(By(fn() { (dmin(0.0, (ends.margins)().0), 0.0) }))
    |> ignore
    bar_room_node(held, fn() { dmax(0.0, (ends.margins)().0) })
    held.box(fn(bar) {
      bar
      .row(Is(true))
      .grow(Is(1.0))
      .min_width(Is(Some(0.0)))
      .lines_up(Is(Some(Middle)))
      .padding(By(fn() { (0.0, (ends.over)(), 0.0, 0.0) }))
      // (its empty part drags the window: what is in it taking presses all the same, so it is said to take them)
      .presses(Is(true))
      .moves_window(By(fn() { @ui.window_inset() }))
      |> ignore
      bar_room_node(bar, ends.start)
      bar.box(fn(inner) {
        // (as wide as the bar gives it, not as all it holds: what has not the room leaves, board_bar_items')
        inner.row(Is(true)).grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).lines_up(Is(Some(Middle))) |> ignore
        make(inner)
      })
      |> ignore
      // (the chat open beside the board: the bar's own room before it; else clear of the window's corner, as a
      // capsule at a bar's end is: 新待办's)
      bar_room_node(bar, fn() { (ends.end)(@sfbase.board_pick.get() is Some(_), true) })
    })
    |> ignore
    bar_room_node(held, fn() {
      let (ml, mr) = (ends.margins)()
      mr + dmin(0.0, ml)
    })
  })
  |> ignore
}

///|
/// 已归档 chosen in the board's filter's menu: the list again, its place the archive's (as the sidebar's filter has it).
fn board_archive_go(src : Source) -> Unit {
  guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return }
  @sfbase.board_set(src, false)
  rail_go_told(src, w, "archive", fn(_, g) { g() })
}

///|
/// What going back to the list (the rail's 对话) does on the tape besides showing it: the sidebar brought over, the list in use (nothing left in the
/// page's panel to look at); only while Home is what the page's panel shows (the board turned off from 实验性功能
/// leaves the panel on that page, as it was).
fn board_listed_back() -> Unit {
  @sfbase.board_listed.val = fn() {
    if wide.tape.get() && app.nav.top() is Home {
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
  // (its bar's end at the window's corner, as a chat's bar in the pane: pane_chat_bar_ends')
  let ends = pane_chat_bar_ends(src, s)
  s.box(fn(col) {
    col.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    col.box(fn(page) {
      page.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      // (the chat's page as the pane draws it: made as nodes or its old view, as 试用新对话页 says now)
      board_beside_page(page, src, r, tips, serial)
    })
    |> ignore
    col.box(fn(bar) {
      bar
      .over(Is(true))
      .height(Is(Some(chat_bar_room(in_pane=false))))
      .row(Is(true))
      .gap(Is(4.0))
      .lines_up(Is(Some(Middle)))
      // (its title as far in from its start as × is seen from its end: the button's room at the end's, its icon of 16
      // in its middle)
      .padding(By(fn() {
        let end = (ends.end)(false, false)
        (end + (@sf.icon_button_side - 16.0) / 2.0, 0.0, end, 0.0)
      }))
      .ground(By(fn() { @sf.theme().p.bg }))
      // (its empty part drags the window, as a chat's bar does)
      .presses(Is(true))
      .moves_window(By(fn() { @ui.window_inset() }))
      |> ignore
      bar.box(fn(t) {
        t.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(t, fn() {
          // (its head alone, as the bar of the chat's page made as nodes reads it: a word streamed into a message reads
          // none of it again)
          match @sfbase.chat_view_now(src, r) {
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
      // (as wide as the bar gives it, not as all it holds: what has not the room leaves, board_bar_items')
      inner.row(Is(true)).grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).lines_up(Is(Some(Middle))) |> ignore
      make(inner)
    })
    |> ignore
    bar_room_node(bar, fn() { tape_bar_end_room(corners(), side=@sf.button_height()) })
  })
  |> ignore
}

///|
/// The chat (or the new chat) open in the chats' place of each workspace as its 看板 was gone to from there, put back
/// as 对话 is pressed from the board (board_back_to_chat).
// kept across runs: put back by wide_reset as a run starts
let board_kept_chat : Map[String, Page] = Map([])

///|
/// The rail's 看板 pressed in workspace `w`: the board, kept as it is where it shows already (what is open beside it);
/// from the chats' list, the chat open there kept to come back to (board_kept_chat).
fn board_go(src : Source, w : Workspace) -> Unit {
  // (on the tape, the page's panel the board is in brought over)
  if lit_place() == "board" {
    if wide.tape.get() {
      bring_page()
    }
    return
  }
  if lit_place() == "chats" && !app.nav.pages().contains(Archived) {
    let mut open : Page? = None
    for p in app.nav.pages() {
      match p {
        Chat(_) | NewChat => open = Some(p)
        _ => ()
      }
    }
    match open {
      Some(p) => board_kept_chat[w.id] = p
      None => board_kept_chat.remove(w.id)
    }
  }
  @sfbase.board_set(src, true)
  if wide.tape.get() {
    bring_page()
  }
}

///|
/// Back to workspace `w`'s chats from its board: the chat open as 看板 was gone to put back beside the list (on the
/// tape, the list the one in use beside it, board_listed_back's). Whether there was one.
fn board_back_to_chat(w : Workspace) -> Bool {
  guard board_kept_chat.get(w.id) is Some(p) else { return false }
  board_kept_chat.remove(w.id)
  if app.nav.pages()[0] != Home {
    @sfbase.go_place("chats") |> ignore
  }
  @sfbase.history_push()
  app.nav.replace_above(1, [p])
  wide.landed.set(w.id)
  true
}
