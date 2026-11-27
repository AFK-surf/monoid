// Laid out Large (or Medium with no sidebar to show: a device waiting to be confirmed in the workspace's safe mode, 连接,
// 用量), the wide frame off the tape as nodes of the window's tree (mbui's view package, the way
// there's 4), made once:
//
//   - a row: the rail and the sidebar's column (as wide as the block takes, open or folded: col), the page's pane in
//     what it leaves (the page an island, built for the room the tree gives it);
//   - over them, the block (the rail and the sidebar on one ground, shell.css.ts dock), the tree's (dock_node): its
//     ground and shadow, cut round as its corners are, the rail in it and every place's sidebar over it (side_node);
//     shown a while (folded, peeking) it reaches over the page; 更新 where the closed bar leaves room for it;
//   - over the block, the sidebar's edge, a node of its own (pane_edge: each press, drag and let go at its moment).
//
// The block's move (brand.tsx moveSidebar: folded or opened as chosen, shown a while or no longer, a place with no
// sidebar of its own come to or left, another place's sidebar at its own width; and the tape left for one of those) is a
// trajectory committed at its cause (fold_moves_from): of each thing it moves where the move before had it then and
// where it goes (FoldLook), one way from 0 to 1, read where it is drawn. What is no cause of a move (the window, the
// edge dragged, the window's room folding it, a fold's place) puts things where they go at once.
//
// Still the old view's (the way there): 更新 and the page (their islands),
// and the pointer coming on the closed bar to show it a while. Back is a node of the tree's
// (wide_takes_back, wide_back_step).

///|
/// What the block and the page beside it are shown as, in one state of the block (fold_look_of) or where a move between
/// two has got (fold_along): the column the page starts after; how far the page is moved aside (shown a while); the
/// page's bars' padding at their start and their margins; the sidebar's top row's height, its bands' ground (0 the
/// sidebar's, 1 the closed bar's), the lists' marks on the rail; the block's margins in its column, its line, how much of
/// the sidebar shows, its shadow (blur, fall, how much of its colour), its corner (0 open), its ground; the sidebar's
/// box's width; the rail's width and padding (left, top, bottom) and its top row's height; where the edge's strip starts.
#derive(Eq)
priv struct FoldLook {
  x : Double
  col : Double
  aside : Double
  bar_pl : Double
  bar_ml : Double
  bar_mr : Double
  brand : Double
  band : Double
  mark : Double
  ml : Double
  mt : Double
  mr : Double
  mb : Double
  line : Double
  showing : Double
  blur : Double
  fall : Double
  shade : Double
  corner : Double
  glass : Double
  ground : Int64
  side_w : Double
  rail_w : Double
  rail_pl : Double
  rail_pt : Double
  rail_pb : Double
  rail_top : Double
  edge : Double
}

///|
/// `a` at `k` of the way to `b`.
fn fold_mix(a : FoldLook, b : FoldLook, k : Double) -> FoldLook {
  let m = fn(x : Double, y : Double) { x + (y - x) * k }
  {
    x: m(a.x, b.x),
    col: m(a.col, b.col),
    aside: m(a.aside, b.aside),
    bar_pl: m(a.bar_pl, b.bar_pl),
    bar_ml: m(a.bar_ml, b.bar_ml),
    bar_mr: m(a.bar_mr, b.bar_mr),
    brand: m(a.brand, b.brand),
    band: m(a.band, b.band),
    mark: m(a.mark, b.mark),
    ml: m(a.ml, b.ml),
    mt: m(a.mt, b.mt),
    mr: m(a.mr, b.mr),
    mb: m(a.mb, b.mb),
    line: m(a.line, b.line),
    showing: m(a.showing, b.showing),
    blur: m(a.blur, b.blur),
    fall: m(a.fall, b.fall),
    shade: m(a.shade, b.shade),
    corner: m(a.corner, b.corner),
    glass: m(a.glass, b.glass),
    ground: if k >= 1.0 { b.ground } else if k <= 0.0 { a.ground } else { @sf.mix(b.ground, k, a.ground) },
    side_w: m(a.side_w, b.side_w),
    rail_w: m(a.rail_w, b.rail_w),
    rail_pl: m(a.rail_pl, b.rail_pl),
    rail_pt: m(a.rail_pt, b.rail_pt),
    rail_pb: m(a.rail_pb, b.rail_pb),
    rail_top: m(a.rail_top, b.rail_top),
    edge: m(a.edge, b.edge),
  }
}

///|
/// How far apart two looks are where a move goes (in points: the column, the page, the block's margins, the sidebar,
/// the rail, the edge): how long a Move between them takes.
fn fold_far(a : FoldLook, b : FoldLook) -> Double {
  let mut far = 0.0
  for d in [
    a.x - b.x,
    a.col - b.col,
    a.aside - b.aside,
    a.bar_pl - b.bar_pl,
    a.bar_ml - b.bar_ml,
    a.bar_mr - b.bar_mr,
    a.brand - b.brand,
    a.ml - b.ml,
    a.mt - b.mt,
    a.mr - b.mr,
    a.mb - b.mb,
    a.side_w - b.side_w,
    a.rail_w - b.rail_w,
    a.rail_top - b.rail_top,
    a.edge - b.edge,
  ] {
    far = dmax(far, d.abs())
  }
  far
}

///|
/// The block's state, as what it is moved for (frame.mbt's `cause`): folded as chosen, shown a while, a place with no
/// sidebar of its own (or none to show: gated), which sidebar (its workspace and group), beside the system's tabs.
#derive(Eq)
priv struct FoldIs {
  folded : Bool
  peeking : Bool
  bare : Bool
  side : String
  native : Bool
}

///|
/// What the frame off the tape is laid out by now, a window `ww` by `wh`: the place's sidebar gated or bare, its
/// sidebar folded for the page's room, on a fold standing upright, closed to the bar, shown a while; the sidebar's
/// width; the bars' room at the top and the foot.
#derive(Eq)
priv struct PaneRoom {
  gated : Bool
  bare : Bool
  crowded : Bool
  on_fold : Double?
  bar : Bool
  peek : Bool
  s : Double
  top : Double
  foot : Double
}

///|
/// The room worked out once for all that reads it: some sixty bindings each worked it out whole (lock_waiting's topic
/// keys among it) at every move of the sidebar's edge dragged. Kept for the last source, workspace, width and board's
/// source asked (board_frame_src is no signal).
priv struct RoomHeld {
  src : Source
  board : Source?
  w : Workspace
  ww : Double
  room : @signals.Computed[PaneRoom]
}

///|
// kept across runs: the room last asked for, each window's own
let room_held : Ref[RoomHeld?] = Ref(None)

///|
fn init {
  @ui.window_kept_ref(room_held, fn() { None })
}

///|
fn pane_room(src : Source, w : Workspace, ww : Double) -> PaneRoom {
  // (one read outside any reader (pane_under's island, a press) works it out on its own: through the held computed it
  // would leave that following what it read with nobody reading it, the lock's topic among them, kept after the last
  // of the wide frame's nodes has gone: 66-wide-resize. So what the held one reads is let go of with its last reader.)
  if @signals.active_sub() is None {
    return pane_room_now(src, w, ww)
  }
  let room = match room_held.val {
    Some(h) if physical_equal(h.src, src) &&
      h.ww == ww &&
      (physical_equal(h.w, w) || h.w == w) &&
      same_board(h.board, board_frame_src.val) => h.room
    _ => {
      let room = @signals.untracked(fn() { @signals.computed(fn(_) { pane_room_now(src, w, ww) }) })
      room_held.val = Some({ src, board: board_frame_src.val, w, ww, room })
      room
    }
  }
  room.get()
}

///|
fn same_board(a : Source?, b : Source?) -> Bool {
  match (a, b) {
    (Some(x), Some(y)) => physical_equal(x, y)
    (None, None) => true
    _ => false
  }
}

///|
/// How far down the window the frame off the tape starts (the system's status bar over its top, edge to edge): the
/// page's stack, the block and the sidebar's edge each under it, worked out here alone (the pane's room's `top`).
fn pane_top() -> Double {
  @ui.system_bars().top
}

///|
fn pane_room_now(src : Source, w : Workspace, ww : Double) -> PaneRoom {
  let gated = lit_place() != "settings" && @settings.lock_waiting(settings_core(src, w), w.id)
  let bare = place_bare_now(lit_place())
  let own = !gated && !bare
  let crowded = own &&
    (@sf.native_input() is Finger) &&
    ww - rail_left() - side_on_fold().unwrap_or(wide.side_w.get()) < page_beside_least
  let folded = (wide.folded.get() && !wide.tape.get()) || crowded
  let on_fold = if folded { None } else { side_on_fold() }
  let bar = (own && folded) || bare
  let s = if gated { 0.0 } else { on_fold.unwrap_or(wide.side_w.get()) }
  let foot = if @sf.native_side() { cards_foot } else { @ui.system_bars().bottom }
  {
    gated,
    bare,
    crowded,
    on_fold,
    bar,
    peek: own && folded && wide.peeking.get(),
    s,
    top: pane_top(),
    foot,
  }
}

///|
/// What the block and the page are shown as in room `r`, the page moved aside `shift` while the block is shown a while
/// (shell.css.ts and brand.css.ts as the frame had them: frame.mbt's dock and its bars' room).
fn fold_look_of(r : PaneRoom, shift : Double) -> FoldLook {
  let bar = r.bar
  let peek = r.peek
  let s = r.s
  let inset = @ui.window_inset()
  let keys_left = @ui.window_keys_left()
  let over_bars = peek && !inset
  let updating = !r.gated && update_shown()
  let shift = if peek { shift } else { 0.0 }
  let rail_extra = if !bar && !wide.tape.get() && !@sf.native_on() { rail_window_in() - rail_in_px } else { 0.0 }
  // (under the window's buttons where they are the system's, at its left: macOS's)
  let above = if keys_left { closed_bar_top } else { bar_in_now() }
  let (blur, fall, shade) = if peek {
    closed_peek_shadow
  } else {
    open_shadow
  }
  {
    x: 0.0,
    col: rail_left() + (if bar { 0.0 } else { s }),
    aside: shift,
    bar_pl: if !bar || over_bars {
      bar_in
    } else if updating {
      if keys_left {
        bar_update_inset
      } else {
        bar_update_in
      }
    } else if keys_left {
      bar_closed_inset
    } else {
      bar_in
    },
    bar_ml: if over_bars {
      dmax(0.0, s - bar_gap_now() - shift)
    } else if peek {
      -shift
    } else {
      0.0
    },
    bar_mr: shift,
    brand: side_brand_h(bar, r.top),
    band: if bar { 1.0 } else { 0.0 },
    mark: if bar { 1.0 } else { 0.0 },
    ml: if bar { bar_in_now() } else { 0.0 },
    mt: if bar { above } else { 0.0 },
    mr: if !bar {
      0.0
    } else if peek {
      bar_gap_now() - s
    } else {
      bar_gap_now()
    },
    mb: if bar { bar_in_now() } else { 0.0 },
    line: 0.0,
    showing: if !bar || peek { 1.0 } else { 0.0 },
    blur,
    fall,
    shade,
    corner: if bar { @sf.closed_bar_of(rail_closed_ground_in).radius(@ui.corner_roots()) } else { 0.0 },
    glass: if bar && peek { 1.0 } else { 0.0 },
    ground: dock_ground(bar),
    side_w: if bar || @sf.native_on() { s } else { s + side_into_rail - rail_extra },
    rail_w: if bar { rail_closed_w } else { rail_shown_w + rail_extra },
    rail_pl: if bar { rail_closed_pad } else { rail_in_px + rail_extra },
    rail_pt: if bar { rail_closed_pad } else { 0.0 },
    rail_pb: if bar { rail_closed_pad } else { rail_in_px + rail_extra },
    rail_top: rail_top_h(bar),
    edge: if !bar {
      rail_left() + s - edge_half
    } else if peek {
      closed_edge + s
    } else {
      closed_edge
    },
  }
}

///|
/// What the block is shown as on the tape (a panel of its own, apart from the page: 6 from the window's edges, 8 from
/// the page's panel, its line and the closed bar's shadow), the sidebar `s` wide in its column `col`, the bars `top` and
/// `foot` clear: where it closes from as the tape is left for a place with no sidebar of its own (pane_view).
fn fold_look_tape(s : Double, col : Double, top : Double, foot : Double, x? : Double = 0.0) -> FoldLook {
  {
    ..fold_look_of(
      { gated: false, bare: false, crowded: false, on_fold: None, bar: false, peek: false, s, top, foot },
      0.0,
    ),
    x,
    col,
    ml: bar_in_now(),
    mt: bar_in_now(),
    mr: bar_gap_now(),
    mb: bar_in_now(),
    line: 1.0,
    blur: closed_shadow.0,
    fall: closed_shadow.1,
    shade: closed_shadow.2,
    glass: 0.0,
    ground: apart_ground(),
  }
}

///|
/// The block's move, committed at its cause: its way (0 as it set out, 1 there), where it set out from and where it
/// goes; the state it was moved for last (None: not yet, the frame just made); how far the page moves aside shown a
/// while (worked out once as it is shown: frame.mbt peek_shift); told as a move is committed or where things go is put.
/// What the tape last showed of the block as it was left (a place with no sidebar of its own come to from it: the
/// block closes from there). The frame's node while it shows, its page's id among the old views'.
priv struct FoldGoes {
  way : @motion.Way
  /// how much of the drawer's glass (and of what the sidebar holds over it) shows while the block is shown a while: a
  /// fade of its own, set off with the block's move (fold_glass_goes), outlasting it as the drawer comes back to the
  /// rail, so its glass gives way over time and is never cut off as the move ends
  glass : @motion.Way
  mut from : FoldLook?
  mut to : FoldLook?
  mut was : FoldIs?
  mut shift : Double
  said : @signals.Signal[Int]
  mut left_tape : FoldLook?
  mut node : @view.View?
  /// its row, the column, the page's pane, as made (for what is asked of them: pane_seen)
  parts : Array[@view.View]
  mut page_id : Int
  /// the pages made once in the pane (pane_made: nodes of the tree's, not old views), by their entries, while they are;
  /// and the entries that show, as the stack told them whole (nav_flat_view's `shown`): what the one shown shows across
  /// read of it (fold_peek_shift), what it hands the system's bars (none)
  made : Map[Int, @view.View]
  mut shown : Array[Int]
  /// whether the core has given what the page shows of a page (sfapp's pane_ready), waited for that long at most
  mut ready : (Page) -> Bool
  mut most : Double
  /// sidebar layout width held from a mid-fold press down until a drag starts or the press ends, so a press or light
  /// tap to fold mid-transition does not snap inner sidebar content narrower before folding
  mut press_laid_w : Double?
  /// the last fully-shown look (`showing >= 0.99`) across a collapse/unfold/reversal so the sidebar's box, top spacer
  /// and band stay pinned in window coordinates behind the animating dock clip instead of drifting or re-snapping
  mut shown_look : FoldLook?
}

///|
// kept across runs: put back as a run begins (fold_goes_reset)
let fold_goes : FoldGoes = {
  way: @motion.Way::new(1.0),
  glass: @motion.Way::new(0.0),
  from: None,
  to: None,
  was: None,
  shift: 0.0,
  said: @signals.signal(0),
  left_tape: None,
  node: None,
  parts: [],
  page_id: 0,
  made: {},
  shown: [],
  ready: fn(_) { true },
  most: 0.0,
  press_laid_w: None,
  shown_look: None,
}

///|
fn fold_goes_reset() -> Unit {
  pane_page_wait.reset()
  fold_goes.way.put(1.0)
  fold_goes.glass.put(0.0)
  fold_goes.from = None
  fold_goes.to = None
  fold_goes.was = None
  fold_goes.shift = 0.0
  fold_goes.left_tape = None
  fold_goes.node = None
  fold_goes.page_id = 0
  fold_goes.made.clear()
  fold_goes.shown = []
  fold_goes.press_laid_w = None
  fold_goes.shown_look = None
}

///|
/// What is committed of the block's move told.
fn fold_said() -> Unit {
  fold_goes.said.set(fold_goes.said.untracked() + 1)
}

///|
/// Where the block's move has it at `t`: from where it set out to where it goes, as far as its way has got; there, at
/// rest (or none committed yet: `now`, as the state has it).
fn fold_along(t : Double, now : FoldLook) -> FoldLook {
  match (fold_goes.from, fold_goes.to) {
    (Some(a), Some(b)) => {
      let k = fold_goes.way.value_at(t)
      // (there: as the state has it now)
      if k >= 1.0 || !fold_goes.way.goes_at(t) {
        now
      } else {
        fold_mix(a, b, k)
      }
    }
    _ => now
  }
}

///|
/// Whether the block's move goes at `t`.
fn fold_going(t : Double) -> Bool {
  fold_goes.way.goes_at(t)
}

///|
/// Whether the block's move at `t` involves a non-fully-open `showing` state (collapsing, unfolding, or reversing
/// mid-fold), as opposed to resizing between two fully-open sidebars (`showing` ~1.0 -> ~1.0, e.g. 240 <-> 280).
fn fold_showing_toggling(t : Double) -> Bool {
  match (fold_goes.from, fold_goes.to) {
    (Some(a), Some(b)) => fold_going(t) && (a.showing < 0.99 || b.showing < 0.99)
    _ => fold_going(t)
  }
}

///|
/// The room and the look of the block now, in the workspace in view, a window `ww` wide.
fn fold_target(src : Source, w : Workspace, ww : Double) -> (PaneRoom, FoldLook) {
  let r = pane_room(src, w, ww)
  (r, fold_look_of(r, fold_goes.shift))
}

///|
/// The block's move committed at `at` (its cause's moment): from where the move before had it then (`was_look` where none
/// was committed: the tape's, as it was left) to `to`, one way as long as the furthest of what it moves goes.
fn fold_moves_from(at : Double, to : FoldLook, was_look? : FoldLook) -> Unit {
  // (where the move before has it then; at rest, where it was put: the state before this one, as it was drawn)
  let (from, old_move) = match (fold_goes.from, fold_goes.to) {
    (Some(a), Some(b)) =>
      if fold_goes.way.goes_at(at) {
        let (k, vk) = fold_goes.way.at(at)
        (fold_mix(a, b, k), Some((a, b, vk)))
      } else {
        (b, None)
      }
    _ => (was_look.unwrap_or(to), None)
  }
  if fold_far(from, to) <= 0.5 && from.ground == to.ground && from.corner == to.corner && from.glass == to.glass {
    fold_put(to, at)
    return
  }
  let v_norm = match old_move {
    Some((a, b, vk)) => {
      let (old_d, new_d) = if (b.col - a.col).abs() > 1.0 && (to.col - from.col).abs() > 1.0 {
        (b.col - a.col, to.col - from.col)
      } else if (b.mr - a.mr).abs() > 1.0 && (to.mr - from.mr).abs() > 1.0 {
        (b.mr - a.mr, to.mr - from.mr)
      } else {
        (b.x - a.x, to.x - from.x)
      }
      if new_d.abs() > 1.0 {
        dmax(-6.0, dmin(6.0, old_d * vk / new_d))
      } else {
        0.0
      }
    }
    None => 0.0
  }
  if to.showing >= 0.99 {
    fold_goes.shown_look = Some(to)
  } else if from.showing >= 0.99 {
    fold_goes.shown_look = match old_move {
      // Interrupting a same-band Open <-> Open resize, or reversing in the final 1% of Folded -> Open:
      // keep the already-laid-out target `b` instead of pinning fractional mid-flight coordinates.
      Some((a, b, _)) if b.showing >= 0.99 && (a.showing < 0.99 || a.band == b.band) => Some(b)
      _ => Some(from)
    }
  } else if fold_goes.shown_look is None {
    fold_goes.shown_look = Some(from)
  }
  fold_goes.from = Some(from)
  fold_goes.to = Some(to)
  fold_goes.way.put(0.0)
  fold_goes.way.go(1.0, @motion.moved(over=fold_far(from, to)), velocity=v_norm, at~)
  fold_glass_goes(to, at, move_ms=@ui.move_ms(fold_far(from, to)))
  fold_said()
  match app.nav.top() {
    Chat(r) => @sfbase.column_sets_off(r.station + "\u{1}" + r.session, resize=false)
    _ => ()
  }
}

///|
/// Where the block goes put there at once, no move (the window, the edge dragged, the room folding it): what goes on of
/// a move goes on for the rest of it to there.
fn fold_put(to : FoldLook, at : Double) -> Unit {
  match (fold_goes.from, fold_goes.to) {
    (Some(_), Some(was)) if was == to => return
    _ => ()
  }
  // (as of the change's moment: what goes on of a move then goes on to there; while the edge is held in hand during
  // an expanded-width resize, settle the way immediately so direct manipulation tracks the pointer with zero jump or
  // drift; while showing is crossing 0, keep the fold move running smoothly and only update its target)
  if fold_goes.way.goes_at(at) && (!wide.edge_held.get() || fold_showing_toggling(at)) {
    let cur_mid = match (fold_goes.from, fold_goes.to) {
      (Some(a), Some(was)) if a.showing >= 0.99 && was.showing >= 0.99 && to.showing < 0.99 && a.band != was.band =>
        Some(fold_along(at, to))
      _ => None
    }
    fold_goes.to = Some(to)
    if to.showing >= 0.99 {
      fold_goes.shown_look = Some(to)
    } else if cur_mid is Some(mid) {
      fold_goes.shown_look = Some(mid)
    }
  } else {
    fold_goes.way.put(1.0)
    fold_goes.from = Some(to)
    fold_goes.to = Some(to)
    fold_goes.shown_look = if to.showing >= 0.99 { Some(to) } else { None }
  }
  fold_glass_goes(to, at)
  fold_said()
}

///|
/// The drawer's glass set off at `at` for where the block goes (`to`): coming as it is shown a while, along with its
/// move (`move_ms` long: none, at once); giving way on the ease in and out over the move, and coming back to the folded
/// rail a control's answer past it (`@sf.dur_ms`), so it still shows as the drawer reaches the rail and goes from there
/// over time.
fn fold_glass_goes(to : FoldLook, at : Double, move_ms? : Double = 0.0) -> Unit {
  let g = fold_goes.glass
  if to.glass == g.target() {
    return
  }
  if to.glass > 0.0 {
    if move_ms > 0.0 {
      g.go(to.glass, @motion.tween(move_ms, ease=Out), at~)
    } else {
      g.put(to.glass)
    }
  } else if move_ms > 0.0 {
    g.go(0.0, @motion.tween(if to.band >= 1.0 { move_ms + @sf.dur_ms } else { move_ms }, ease=InOut), at~)
  } else {
    g.put(0.0)
  }
}

///|
/// The moment the block is drawn at by what reads it in node `n`: the frame's while its move goes, else after it.
fn fold_drawn_at(n : @view.View) -> Double {
  fold_goes.said.get() |> ignore
  fold_goes.way.said()
  fold_goes.glass.said()
  n.drawn_while(fn(t) { fold_goes.way.goes_at(t) || fold_goes.glass.goes_at(t) })
}

///|
/// The frame off the tape in node `v` (the signed-in shell's, filling the window: sfapp's paned_shell), in the workspace
/// in view (its file's head).
pub fn pane_view(v : @view.View, src : Source, ready~ : (Page) -> Bool, most~ : Double) -> Unit {
  wide.tape.set(false)
  board_frame_src.val = Some(src)
  // (its tips over all of the window, as the old frame's are: none cut by the pane, the sidebar's edge's and its pages')
  let tips = @sf.TipLayer::new(fn() { Some(v) })
  fold_goes.node = Some(v)
  fold_goes.ready = ready
  fold_goes.most = most
  // (what this frame committed is its own: let go with it, the next one made starting from none, or from the tape as it
  // was left then)
  fold_goes.from = None
  fold_goes.to = None
  fold_goes.was = None
  fold_goes.shift = 0.0
  fold_goes.press_laid_w = None
  fold_goes.shown_look = None
  fold_goes.way.put(1.0)
  fold_goes.glass.put(0.0)
  let side_at_c = @signals.computed(fn(_) { pane_side_at(src, v) })
  let rail_at_c = @signals.computed(fn(_) { pane_rail_at(src, v) })
  let side_at = fn() { if @signals.active_sub() is None { pane_side_at(src, v) } else { side_at_c.get() } }
  let rail_at = fn() { if @signals.active_sub() is None { pane_rail_at(src, v) } else { rail_at_c.get() } }
  nav_hold(src)
  // (a chat's detail asked as a page put beside its chat as it comes on top, before a frame builds it)
  beside_follow(v, src)
  v.owns(fn() {
    side_at_c.dispose()
    rail_at_c.dispose()
    nav_held.val = fn() { None }
    fold_goes.node = None
    fold_goes.parts.clear()
    fold_goes.from = None
    fold_goes.to = None
    fold_goes.was = None
    fold_goes.left_tape = None
    fold_goes.press_laid_w = None
    fold_goes.shown_look = None
  })
  |> ignore
  // what the page's pane shows as the page on top changes, at its cause's moment (page_wait.mbt)
  pane_page_wait.follow(v, fn(p) { (fold_goes.ready)(p) }, fn() { fold_goes.most })
  // another place's or workspace's sidebar as it was left (side_take), at that cause, as the tape takes it: not as the
  // frame after it is built, so what follows it before then (its place pressed again) finds it so
  v.reacts(
    fn() {
      match @sfbase.workspace_in_view(src).0 {
        Some(w) if src.topic("prefs", {}).get().value is Some(_) => w.id + "\n" + side_group(src, w.id)
        _ => ""
      }
    },
    fn(key) {
      if key == "" {
        return
      }
      match @sfbase.workspace_in_view(src).0 {
        Some(w) => side_take(src, w.id) |> ignore
        None => ()
      }
    },
  )
  // the block moved for what it is moved for, at that moment: from where it is then; else what it goes to changed by
  // what is no cause of a move, put there at once
  let first = Ref(true)
  v.reacts(
    fn() {
      match @sfbase.workspace_in_view(src).0 {
        Some(w) => {
          let r = pane_room(src, w, v.window_w())
          let group = if @sf.native_on() { "tabs" } else { side_group(src, w.id) }
          let cause : FoldIs = {
            folded: wide.folded.get(),
            peeking: wide.peeking.get(),
            bare: r.gated || r.bare,
            side: w.id + "\n" + group,
            native: @sf.native_on(),
          }
          Some((cause, fold_look_of(r, fold_goes.shift)))
        }
        None => None
      }
    },
    fn(said) {
      guard said is Some((cause, look)) else { return }
      let at = v.cause_at()
      let was = fold_goes.was
      fold_goes.was = Some(cause)
      // (the tape left for a place with no sidebar of its own: the block closes from the tape's panel, as it was)
      let from_tape = fold_goes.left_tape
      fold_goes.left_tape = None
      let made = first.val
      first.val = false
      match (was, from_tape) {
        (Some(w), _) if w != cause && w.native == cause.native && !wide.edge_held.get() => {
          // shown a while from now: how far the page moves aside, worked out once as it starts
          let look = if cause.peeking && !w.peeking {
            fold_goes.shift = fold_peek_shift(fold_along(at, look))
            match @sfbase.workspace_in_view(src).0 {
              Some(ws) => fold_look_of(pane_room(src, ws, v.window_w()), fold_goes.shift)
              None => look
            }
          } else {
            look
          }
          fold_moves_from(at, look)
        }
        (None, Some(t)) if made && cause.bare => fold_moves_from(at, look, was_look=t)
        _ => fold_put(look, at)
      }
    },
  )
  // back while the frame takes it (wide_takes_back: the entry before in the history, a page popped), a node of the
  // window's tree's under the page and the block, what an old view says takes back (a page's own, a layer over all)
  // taking it before it; whose it is said at the cause that changes it, each step taken at its moment (wide_back_step)
  let held : Ref[WideBack?] = Ref(None)
  let fwd_held : Ref[WideBack?] = Ref(None)
  let hint = back_hint_new(v)
  v.show(fn() { wide_takes_back(src) }, fn(b) {
    b.follows_back(fn(step) { wide_back_step(src, held, hint, step) }) |> ignore
    b.owns(fn() { wide_back_left(held, hint, v.cause_at()) }) |> ignore
  })
  v.follows_forward(when=fn() { wide_takes_forward(src) }, fn(step) { wide_forward_step(src, fwd_held, hint, step) })
  |> ignore
  v.owns(fn() { wide_back_left(fwd_held, hint, v.cause_at()) }) |> ignore
  v.box(fn(row) {
    fold_goes.parts.clear()
    fold_goes.parts.push(row)
    row.row(Is(true)).grow(Is(1.0)) |> ignore
    // the rail and the sidebar's column: what the block takes of the row, open or folded, where its move has got
    row.box(fn(col) {
      fold_goes.parts.push(col)
      col
      .width(By(fn() {
        match @sfbase.workspace_in_view(src).0 {
          Some(w) => {
            let (_, now) = fold_target(src, w, col.window_w())
            Some(fold_along(fold_drawn_at(col), now).col)
          }
          None => Some(0.0)
        }
      }))
      |> ignore
    })
    |> ignore
    // the page's pane in what the column leaves, its stack under the bars at the top (pane_top: a margin, as what is
    // laid over what holds it takes none of that one's padding)
    row.box(fn(pane) {
      fold_goes.parts.push(pane)
      let pane_clips = fn() { pane_fold_locked(fold_drawn_at(pane)) }
      pane
      .grow(Is(1.0))
      .ground(By(fn() { if pane_clips() { @sf.theme().p.bg } else { 0L } }))
      .clips(By(pane_clips))
      .bounds_input(By(pane_clips))
      |> ignore
      pane.box(fn(page) {
        page.grow(Is(1.0)).over(Is(true)).margin(By(fn() { (0.0, pane_top(), 0.0, 0.0) })) |> ignore
        // (the stack the tree's, each page its island: page_pane.mbt)
        pane_pages(page, src, tips)
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  // the block over them (reaching over the page shown a while), the tree's: its ground and the rail (dock_node)
  v.box(fn(b) {
    b.over(Is(true)) |> ignore
    dock_node(b, side_at, fn(r) { rail_node(r, src, tips, rail_at) })
  })
  |> ignore
  // The rail's closed look follows the block's target, at the cause of the change.
  v.reacts(fn() {
    match @sfbase.workspace_in_view(src).0 {
      Some(w) => pane_room(src, w, v.window_w()).bar
      None => false
    }
  }, fn(bar) { wide.closed.set(bar) })
  // 更新 where the closed bar's start leaves room for it (pane_update_node)
  v.show(at_once=true, fn() { pane_update_shows(src, v) }, fn(o) { pane_update_node(o, src, tips) })
  // the sidebar made once, the tree's, over the block where it lays its sidebar out (side_node)
  v.box(fn(sides) {
    sides.over(Is(true)) |> ignore
    side_node(sides, src, tips, side_at)
  })
  |> ignore
  // the block's line over all it holds (dock_edge_node)
  v.box(fn(line) {
    line.over(Is(true)) |> ignore
    dock_edge_node(line, side_at)
  })
  |> ignore
  // the sidebar's edge, the tree's, over the block (its rows under its strip), but where a list's thumb of the
  // sidebar's is shown there: the thumb's (@ui.yield_thumbs)
  v.show(fn() { pane_edge_stands(src, v) }, fn(n) {
    n.over(Is(true)) |> ignore
    pane_edge(n, v, src, tips)
  })
  back_hint_node(v, hint)
}

///|
/// Where the block off the tape lays its sidebar out as node `n` (over all of the window) is drawn, in the workspace in
/// view: where its move has got (fold_along at what `n` is drawn at:
/// dock_side_at).
fn pane_side_at(src : Source, n : @view.View) -> SideAt {
  match @sfbase.workspace_in_view(src).0 {
    Some(w) => {
      let (ww, wh) = n.window()
      let (r, now) = fold_target(src, w, ww)
      let t = fold_drawn_at(n)
      // (the drawer's glass where its own fade has got, not where the move has: fold_glass_goes)
      let glass = fold_goes.glass.value_at(t)
      let f = { ..fold_along(t, now), glass: glass }
      let top = if side_full_height(r.bar) { 0.0 } else { r.top }
      let d = dock_side_at(r.bar, r.peek, r.s, f.col, top, r.foot, 0.0, wh, Some((f, fold_going(t))))
      // (what the sidebar holds shows as its glass does while that comes or goes, folded: never on no ground)
      // (only as the drawer comes from or goes back to the folded rail: between open and shown a while it shows whole)
      let at_rail = match (fold_goes.from, fold_goes.to) {
        (Some(a), Some(b)) => a.showing <= 0.0 || b.showing <= 0.0
        _ => false
      }
      let seen = if r.bar && at_rail && (glass > 0.0 || fold_goes.glass.goes_at(t)) { glass } else { 1.0 }
      // While collapsing, unfolding or reversing mid-fold (`showing` crossing 0), pin the sidebar's box, layout width,
      // top spacer (`brand`) and band insets to the fully-shown endpoint (`shown_look`) while the dock clip (`block`)
      // reveals/hides it. Otherwise `cut.offset.y` (`f.mt`) and `side_top_node` (`f.brand`) trade height across two
      // separate rounding steps (`Tree::rows_placed` vs `each_drawn_in_order`), and `box.0` drifts through fractional X
      // when `rail_extra != 0`, causing ±1px vertical jumping and every-frame glyph re-phasing.
      // (`press_laid_w` is only set while `showing >= 0.99` on same-band resizes, mutually exclusive with toggling.)
      if fold_showing_toggling(t) && fold_goes.press_laid_w is None {
        if fold_goes.shown_look is Some(h) {
          let h_bar = h.band >= 0.5
          let h_top = if side_full_height(h_bar) { 0.0 } else { r.top }
          let (_, h_dock_h) = dock_size(h_bar, h, h.col, h_top, r.foot, wh)
          let h_rail = if @sf.native_on() { 0.0 } else { h.rail_w }
          let h_box = (h.x + h.ml + h_rail, h_top + h.mt, h.side_w, h_dock_h)
          return {
            ..d,
            box: h_box,
            laid_w: h.side_w,
            brand: h.brand,
            band: h.band,
            list_brand: h.brand,
            list_band: h.band,
            seen,
          }
        }
      }
      // (what it holds laid out at its target width while a same-band expanded width switch animates, drawn cut and
      // placed where the move has got; open <-> floating changes band 0 <-> 1 and interpolates smoothly with `f`)
      let laid_w = match fold_goes.press_laid_w {
        Some(lw) => lw
        None =>
          match (fold_goes.from, fold_goes.to) {
            (Some(from), _) if fold_going(t) && now.showing <= 0.0 => from.side_w
            (Some(from), _) if fold_going(t) && from.showing <= 0.0 => now.side_w
            (Some(from), Some(to)) if fold_going(t) && from.showing > 0.0 && to.showing > 0.0 && from.band == to.band =>
              to.side_w
            _ => f.side_w
          }
      }
      let (list_brand, _, list_band) = fold_held_at(t, f)
      { ..d, laid_w, list_brand, list_band, seen }
    }
    None =>
      {
        box: (0.0, 0.0, 0.0, 0.0),
        laid_w: 0.0,
        rail_w: 0.0,
        block: (0.0, 0.0, 0.0, 0.0),
        ground: 0L,
        shadow: (0.0, 0.0, 0L),
        links: None,
        round: 0.0,
        edge: (0.0, 0L),
        shown: false,
        brand: 0.0,
        band: 0.0,
        list_brand: 0.0,
        list_band: 0.0,
        bar: false,
        tape: false,
        glass: 0.0,
        seen: 1.0,
      }
  }
}

///|
/// What the window's tree has of the frame off the tape, for a test: who its shell, its row, the block's column and the
/// page's pane are (made once: the same while it shows), and how wide the column is laid out. None while it does not
/// show.
pub fn pane_seen() -> (Array[@view.NodeId], Double)? {
  match fold_goes.node {
    Some(v) if fold_goes.parts.length() == 3 => {
      let (_, _, w, _) = fold_goes.parts[1].rect()
      Some(([v.id()] + fold_goes.parts.map(fn(p) { p.id() }), w))
    }
    _ => None
  }
}

///|
/// Where the block's move committed has the block at `t` (how far across it is drawn, the column it takes), worked out
/// of the move alone, for a test; None where none is committed.
pub fn pane_fold_at(t : Double) -> (Double, Double)? {
  match pane_look_at(t) {
    Some(f) => Some((f.x, f.col))
    None => None
  }
}

///|
/// Where the block's move committed has, at `t`, the block's margin at its right (shown a while, past the column), how
/// far the page is moved aside, where the edge stands, how much of the sidebar shows; for a test, None where none is
/// committed.
pub fn pane_reach_at(t : Double) -> (Double, Double, Double, Double)? {
  match pane_look_at(t) {
    Some(f) => Some((f.mr, f.aside, f.edge, f.showing))
    None => None
  }
}

///|
/// Where the block's last move committed set out from (how far across, the column), for a test.
pub fn pane_fold_from() -> (Double, Double)? {
  match fold_goes.from {
    Some(f) => Some((f.x, f.col))
    None => None
  }
}

///|
fn pane_look_at(t : Double) -> FoldLook? {
  match (fold_goes.from, fold_goes.to) {
    (Some(a), Some(b)) =>
      Some(if fold_goes.way.goes_at(t) { fold_mix(a, b, fold_goes.way.value_at(t)) } else { b })
    _ => None
  }
}

///|
/// The frame off the tape's node while it shows, for a test (what is due at a moment of its own, View::at_moment).
pub fn pane_node() -> @view.View? {
  fold_goes.node
}

///|
/// The page made once in the pane that shows (an entry the stack told shown: fold_goes' `shown`), if one is.
fn pane_made_shown() -> @view.View? {
  for k in fold_goes.shown {
    match fold_goes.made.get(k) {
      Some(v) if v.alive() => return Some(v)
      _ => ()
    }
  }
  None
}

///|
/// What the page that shows in the pane off the tape shows across, as the folded sidebar shown a while reads it as it
/// starts (fold_peek_shift; for a test too): a page made once (a chat's made as nodes: its messages' column), what its
/// tree's parts show across; else the old view's page, its bars left out.
pub fn pane_shown_across() -> (Double, Double)? {
  match pane_made_shown() {
    Some(p) => p.shown_across()
    None => @ui.current().shown_across(fold_goes.page_id, but="page-bar")
  }
}

///|
/// The page made once in the pane that shows, for a test: who it is (None: none shows).
pub fn pane_made_seen() -> @view.NodeId? {
  pane_made_shown().map(fn(v) { v.id() })
}

///|
/// The pane's rect and the active made-once page's rect, for a test (verifying full height and right-edge alignment
/// during fold transitions).
pub fn pane_made_rect() -> ((Double, Double, Double, Double), (Double, Double, Double, Double))? {
  match (fold_goes.parts.get(2), pane_made_shown()) {
    (Some(pane), Some(made)) => Some((pane.rect(), made.rect()))
    _ => None
  }
}

///|
/// How far the page moves aside for the folded sidebar shown a while, worked out once as it is shown (frame.mbt
/// peek_shift: what the page showed across as the last frame laid it out: an old view's page, or one made once of the
/// tree's), the block where it is (`at`).
fn fold_peek_shift(at : FoldLook) -> Double {
  let shown = pane_shown_across()
  match fold_goes.node {
    Some(v) => {
      let s = wide.side_w.get()
      let w = v.window_w()
      match shown {
        Some((left, right)) => {
          let moved = (rail_left() - at.col) / 2.0
          let reach = bar_in_now() + rail_closed_w + s + peek_gap
          let room = w - 2.0 * peek_gap - dmin(right + moved, w)
          dmax(0.0, dmin(s, dmin(room, reach - dmax(left + moved, rail_left())))).round()
        }
        None => 0.0
      }
    }
    None => 0.0
  }
}

///|
/// The sidebar's top row's room for its lists, its box's width and how far the band over its lists is to the closed bar's
/// (`f` where its move has got): on the way between two looks the larger end's all the way when collapsing/unfolding, or
/// the target end's when switching widths with the same `band` (what is in the sidebar not laid out again each frame for
/// the little they differ; it goes under what cuts the block as it goes). Open <-> floating transitions change `band`
/// (0 <-> 1) and must interpolate continuously with `f`, otherwise right-aligned sidebar controls jump 10px on frame 0.
fn fold_held_at(t : Double, f : FoldLook) -> (Double, Double, Double) {
  match (fold_goes.from, fold_goes.to) {
    (Some(a), Some(b)) if fold_going(t) && (a.showing <= 0.0 || b.showing <= 0.0) =>
      (dmax(a.brand, b.brand), dmax(a.side_w, b.side_w), dmin(a.band, b.band))
    (Some(a), Some(b)) if fold_going(t) && a.showing > 0.0 && b.showing > 0.0 && a.band == b.band =>
      (b.brand, b.side_w, b.band)
    _ => (f.brand, f.side_w, f.band)
  }
}

///|
/// Whether 更新 shows off the tape with the sidebar closed, where its first row is not shown, in the workspace in view, a
/// window as wide as node `n` has it: an update offered (update_shown), the block the closed bar, not shown a while.
fn pane_update_shows(src : Source, n : @view.View) -> Bool {
  match @sfbase.workspace_in_view(src).0 {
    Some(w) => {
      let r = pane_room(src, w, n.window_w())
      !r.gated && update_shown() && r.bar && !r.peek
    }
    None => false
  }
}

///|
/// 更新 off the tape with the sidebar closed (pane_update_shows) in node `o`, over all of the window: where the bar's
/// start leaves room for it, past the rail (update_closed_in; past the window's buttons where they are in the app's top
/// row, update_closed_inset), update_top under the system's bars over the window (a phone's status bar, which take what
/// is pressed under them); its tip in `tips`.
fn pane_update_node(o : @view.View, src : Source, tips : @sf.TipLayer) -> Unit {
  o
  .over(Is(true))
  .padding(By(fn() {
    let top = match @sfbase.workspace_in_view(src).0 {
      Some(w) => pane_room(src, w, o.window_w()).top
      None => 0.0
    }
    let left = if @ui.window_inset_now() { update_closed_inset } else { update_closed_in }
    (left, top + update_top, 0.0, 0.0)
  }))
  |> ignore
  // (in a row: as wide as the key, its tip and its press on it alone)
  o.box(fn(row) {
    row.row(Is(true)) |> ignore
    update_key_of(row, src, tips)
  })
  |> ignore
}

///|
/// Where the rail off the tape is drawn as node `n` (over all of the window) is drawn: where the block's move has got
/// then (fold_along at what `n` is drawn at), in the workspace in view.
fn pane_rail_at(src : Source, n : @view.View) -> RailAt {
  match @sfbase.workspace_in_view(src).0 {
    Some(w) => {
      let (r, now) = fold_target(src, w, n.window_w())
      rail_at_fold(r.bar, fold_along(fold_drawn_at(n), now))
    }
    None => rail_at_tape(dock_ground(false))
  }
}

///|
/// What the old frame does under the frame off the tape with workspace `w` in view, before the old views it holds
/// (sfapp's view_in, off the tape): how the lists take the hand, the system's tabs where it has its own bars, the folded
/// sidebar shown a while as the pointer comes on the closed bar. The sidebar of this place and workspace as it was left,
/// the chat landed on. The window's buttons' row is the tree's (sfapp's wide_top_node).
pub fn pane_under(c : @ui.Ctx, src : Source, w : Workspace, all : Array[Workspace]) -> Unit {
  c.mouse_drags_lists(pane_finger())
  wide.side_place = side_place()
  side_follow(c, src, w.id)
  wide.tape.set(false)
  tape_off()
  native_frame(c, src, w, all)
  let r = pane_room(src, w, c.width)
  wide.crowded = r.crowded
  side_crowded()
  let peek_r = rail_left() - bar_gap_now() + (if wide.peeking.get() { r.s } else { 0.0 })
  // (under the window's buttons where they are the system's, at its left: macOS's)
  let peek_top = if @ui.window_keys_left() { closed_bar_top } else { bar_in_now() }
  side_peek(c, bar_in_now(), r.top + peek_top, peek_r, c.height - r.foot - bar_in_now())
  land(src, w)
  // (back, the shell's one way: the frame's node's, pane_view, wide_takes_back)
  // (the pages of closed tabs let go as each closes: service_tab.mbt's tab_let_go)
}

///|
/// Whether the sidebar's edge stands beside the block (sidebar_edge's: none where the block is bare of its sidebar,
/// folding on its own, or crowded), in the workspace in view, a window as wide as node `n` has it.
fn pane_edge_stands(src : Source, n : @view.View) -> Bool {
  match @sfbase.workspace_in_view(src).0 {
    Some(w) => {
      let r = pane_room(src, w, n.window_w())
      !r.bare && r.on_fold is None && !r.crowded
    }
    None => false
  }
}

///|
/// The sidebar's edge (the web's SidebarEdge), the tree's, in node `n` over what `holder` holds: a
/// strip 12 wide down all of the window, its line in its middle where the block's move has the edge as it is drawn
/// (fold_along's `edge`), the library's look 3 in (its bar shown with the pointer on the strip, its line not while the
/// sidebar is folded). Open or shown a while, dragged, the sidebar's width (side_min to side_max), each event at its
/// moment; folded, its width as it is, and a press of it (let go without moving, or after a drag: the web's moves go
/// nowhere there; the second of two) the sidebar folded or opened again, as Enter, Space or a screen reader's press of
/// it do. Held, the wide frame's edge_held, from its press to its end (let go, called off, gone with its node). Its
/// pointer the resizing one while the sidebar is open, a button's folded; read out as a button saying what a press does;
/// its words by the pointer along it (tips). Where a list's thumb of the sidebar's is shown under its strip, that thumb's.
fn pane_edge(n : @view.View, holder : @view.View, src : Source, tips : @sf.TipLayer) -> Unit {
  let held = @signals.signal(false, same=fn(a, b) { a == b })
  let words = fn() {
    if wide.folded.get() {
      @sf.t("web-main.sidebar.open")
    } else {
      @sf.t("web-pages.workspace.resizeSidebar") + " · " + @sf.t("web-main.sidebar.close")
    }
  }
  // (its width dragged open and shown a while; folded, only pressed, any way it moves)
  let sized = fn() { !wide.folded.get() || wide.peeking.get() }
  let fold = fn() { wide.folded.set(!wide.folded.get()) }
  n
  .width(Is(Some(@ui.Space::px(S3))))
  .height(By(fn() { Some(dmax(0.0, n.window_h() - pane_top())) }))
  .offset(By(fn() {
    match @sfbase.workspace_in_view(src).0 {
      Some(w) => {
        let (r, now) = fold_target(src, w, n.window_w())
        (fold_along(fold_drawn_at(holder), now).edge, r.top)
      }
      None => (0.0, pane_top())
    }
  }))
  |> ignore
  // (dragged on past either end, its line drawn aside as a string, sprung back as it is let go; folded, none)
  let visible_side_w = fn() -> Double {
    match @sfbase.workspace_in_view(src).0 {
      Some(w) if sized() => {
        let (r, now) = fold_target(src, w, n.window_w())
        let cur_f = fold_along(n.cause_at(), now)
        if cur_f.showing >= 0.99 {
          let s = cur_f.side_w - (now.side_w - r.s)
          dmax(side_min, dmin(side_max, s))
        } else {
          wide.side_w.get()
        }
      }
      _ => wide.side_w.get()
    }
  }
  let press_saved_w : Ref[Double?] = Ref(None)
  let pull = @sf.EdgePull::new()
  let e = @sf.edge_node(
    n,
    words,
    visible_side_w,
    fn() { if sized() { side_min } else { wide.side_w.get() } },
    fn() { if sized() { side_max } else { wide.side_w.get() } },
    Right,
    fn(said, _) {
      match said {
        Dragging(x) => {
          fold_goes.press_laid_w = None
          wide.side_w.set(x)
        }
        Dropped(x) if sized() => {
          fold_goes.press_laid_w = None
          press_saved_w.val = None
          wide.side_w.set(x)
        }
        // (folded: the web's moves go nowhere, so a press that moved is a press)
        Dropped(_) | Pressed | Twice => fold()
        Untouched => ()
      }
    },
    fn(h) {
      held.set(h)
      wide.edge_held.set(h)
      if h && sized() {
        let cur = visible_side_w()
        let saved = wide.side_w.get()
        press_saved_w.val = if fold_going(n.cause_at()) { Some(saved) } else { None }
        if (cur - saved).abs() > 0.01 {
          fold_goes.press_laid_w = match (fold_goes.from, fold_goes.to) {
            (Some(a), Some(b)) if fold_going(n.cause_at()) && a.showing > 0.0 && b.showing > 0.0 && a.band == b.band =>
              Some(b.side_w)
            _ => None
          }
          wide.side_w.set(cur)
        } else {
          fold_goes.press_laid_w = None
        }
      } else if !h {
        let held_laid = fold_goes.press_laid_w
        fold_goes.press_laid_w = None
        match press_saved_w.val {
          Some(sw) => {
            press_saved_w.val = None
            if (wide.side_w.get() - sw).abs() > 0.01 {
              wide.side_w.set(sw)
              match held_laid {
                Some(lw) => {
                  fold_goes.from = fold_goes.from.map(fn(a) { { ..a, side_w: lw } })
                  fold_goes.to = fold_goes.to.map(fn(b) { { ..b, side_w: lw } })
                }
                None => ()
              }
              match @sfbase.workspace_in_view(src).0 {
                Some(w) => fold_moves_from(n.cause_at(), fold_target(src, w, n.window_w()).1)
                None => ()
              }
            }
          }
          None => ()
        }
      }
    },
    tips~,
    side=Right,
    pull~,
  )
  // (a list's thumb of the sidebar's shown under its strip: the thumb's there)
  @ui.yield_thumbs(e)
  // (a button's as the web's is: its pointer the resizing one while open; read out as what a press does; Enter, Space
  // or a screen reader's press of it, as a press of it is)
  @sf.action_box_node(e, words, fn(_) { fold() }, in_node=true, fn(v) {
    v
    .focus_ring(Is(None))
    .cursor(By(fn() { if wide.folded.get() { None } else { Some(ResizeX) } }))
    |> ignore
  })
  |> ignore
  e.box(fn(g) {
    g.over(Is(true)).padding(Is((@ui.Space::px(@sf.edge_in), 0.0, 0.0, 0.0))) |> ignore
    @sf.edge_look_node(
      g,
      fn() { false },
      fn() { e.pointed() || e.focus_shown() || held.get() },
      fn() { held.get() },
      line=fn() { !wide.folded.get() },
      pull~,
    )
    |> ignore
  })
  |> ignore
}
