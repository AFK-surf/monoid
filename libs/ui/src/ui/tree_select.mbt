// Words of the window's tree picked with the pointer, by the same selection as an old view's paragraphs (desktop.mbt):
// a node's words in pieces (View::words_runs) where what holds it says its words are picked so (words_picked: a page's,
// as an old view's page in Ctx::selectable), each a paragraph of it (SelKey's `Words`: the tree's number, the row of a
// list made by its key it is in and its place in that row: View::row_place), found where the tree lays it out and shows
// it now (tree_sels: what holds it cutting it, as big as it is drawn), never as the frame before painted it; what of it
// is picked drawn under its words (View::runs_picked, as each is made and as what is picked changes: picked_told). Its
// plain words are picked by none, as an old view's plain words are not (Ctx::text). A finger's press is what it
// presses; a finger held still on them a long press's time is the selection's (tree_finger_down, finger_select.mbt).

///|
/// How many window's trees were made (set_view_app): the one now's number, what its paragraphs are known by.
// kept across runs: counted on, never put back (a number given again would be another tree's)
let view_tree_made : Ref[Int] = Ref(0)

///|
/// What a node lends what it holds: the root node of the selection scope its words belong to (words_picked).
// kept across runs: what each node lends (View::lends), let go with it
let words_picks : @view.Lent[@view.NodeId] = @view.Lent::new()

///|
/// What a node lends what it holds: the hit-test container box for pointer selection (words_hit_box, e.g. a table cell).
// kept across runs: what each node lends (View::lends), let go with it
let words_hit_boxes : @view.Lent[@view.NodeId] = @view.Lent::new()

///|
/// The words in pieces node `v` holds, now or later, picked with the pointer, a mouse's (a page's, as an old view's
/// page's in Ctx::selectable): pressed and dragged over, picked; ⌘C (Ctrl+C) copies them; a press elsewhere lets them
/// go. By default (`apart=false`), inherits an enclosing `words_picked` scope if one exists; pass `apart=true` to start
/// an independent selection scope inside an existing one.
pub fn words_picked(v : @view.View, apart? : Bool = false) -> Unit {
  let existing = if !apart { v.lent(words_picks) } else { None }
  let scope_id = existing.unwrap_or_else(fn() { v.id() })
  v.lends(words_picks, scope_id).lends(@view.runs_picker, words_picker) |> ignore
  if existing is None {
    v.owns(fn() {
      match picked.layer {
        TreeScope(_, id) if id == scope_id => {
          if picked.dragging {
            picked.dragging = false
            tree_edge_stop()
          }
          if picked_now_said.val.untracked() is Some(_) {
            picked_now_tell()
          }
        }
        _ => ()
      }
    })
    |> ignore
  }
}

///|
/// Mark `v` as the selection hit-test box for words inside it (e.g. a table cell whose words are vertically centered
/// in a taller row): pointer hits anywhere inside `v`'s visible box clamp to the words' first or last line instead of
/// falling through to neighboring columns.
pub fn words_hit_box(v : @view.View) -> Unit {
  v.lends(words_hit_boxes, v.id()) |> ignore
}

///|
/// Whether selection scope `scope_id` is still alive and visible in the current window's tree.
fn tree_scope_live(scope_id : @view.NodeId) -> Bool {
  match view_app.val {
    Some(tree) =>
      match tree.view_of(scope_id) {
        Some(v) => !v.shown_nowhere()
        None => false
      }
    None => false
  }
}

///|
/// If the current tree selection belongs to a scope that was destroyed or hidden (`shown_nowhere`), stop any active
/// drag and drop `picked_now` while keeping the released selection snapshot for ⌘C copy until a press elsewhere. The
/// scope alive, sync `picked_now` whenever the words what is picked ends in (`ends_in`) leave or return to view (a
/// virtualized row scrolled out, parked, recycled, or scrolled back; a step folded or unfolded). Returns whether
/// `picked_now` changed.
fn sync_picked_scope_live() -> Bool {
  let before = picked_now_said.val.untracked()
  match picked.layer {
    TreeScope(_, scope_id) if !tree_scope_live(scope_id) => {
      if picked.dragging {
        picked.dragging = false
        tree_edge_stop()
      }
      if before is Some(_) {
        picked_now_tell()
      }
    }
    TreeScope(_, scope_id) if !picked.dragging =>
      match before {
        Some(p) =>
          match picked_in_order() {
            Some((_, end)) if picked_end_live(p.ends_in, end, scope_id) => ()
            _ => picked_now_tell()
          }
        None if !picked.spans.is_empty() =>
          match picked_in_order() {
            Some((_, end)) =>
              match picked_shown.get(end) {
                Some((ends_in, _, end_scope)) if end_scope == scope_id &&
                  picked_end_live(ends_in, end, scope_id) => picked_now_tell()
                _ => ()
              }
            None => ()
          }
        _ => ()
      }
    _ => ()
  }
  picked_now_said.val.untracked() != before
}

///|
/// The picker words_picked lends (words_picked_span), one value: a block in what has its words picked that is lent
/// another (one that picks none: a quote's card in a message, whose words were never of what is picked) holds words
/// none of what is picked, nor copied with it (tree_sels).
// kept across runs: a function, the same for every run
let words_picker : (@view.View) -> @view.Live[(Int, Int)] = words_picked_span

///|
/// What of each paragraph's words is picked with the pointer (from, to; (0, 0) none), by its key, as a signal of its
/// own made as it is first read (words_picked_span): told as what is picked changes (picked_told), each only as its
/// own span does.
// kept across runs: said again from what is picked as that changes
let picked_spans_said : Map[SelKey, @signals.Signal[(Int, Int)]] = Map([])

///|
/// Whether a `scrolls_window` row `(tree_id, list, row_num)` currently holds any non-empty picked span, as a signal
/// read by that row's shared memo (`row_picked_reader`, fanout <= 1).
// kept across runs: said again from what is picked as that changes
let picked_row_said : Map[(Int, @view.NodeId, Int), @signals.Signal[Bool]] = Map([])

///|
/// Per-row memo (`View::memo`) shared by all `words_runs` inside a mounted `rows_named` row: returns the row's
/// number when that row holds any picked span, or `0` otherwise so reusing an unselected row cuts off downstream
/// `RunsPicked` bindings.
// kept across runs: removed by `View::owns` when the row node is disposed
let row_picked_memos : Map[(Int, @view.NodeId), () -> Int] = Map([])

///|
/// Whether what is picked with the pointer was picked by a finger, as a signal (Ctx::selection_by_finger).
// kept across runs: said again from what is picked as that changes
let picked_finger_said : Ref[@signals.Signal[Bool]] = Ref(@signals.signal(false))

///|
/// What of paragraph `k`'s words is picked now ((0, 0): none).
fn picked_span_of(k : SelKey) -> (Int, Int) {
  match picked.spans.get(k) {
    Some(s) if s.a < s.b => (s.a, s.b)
    _ => (0, 0)
  }
}

///|
/// Whether `picked.spans` currently has any non-empty span in `(tree_id, list, row_num)`.
fn picked_row_has_any(tree_id : Int, list : @view.NodeId, row_num : Int) -> Bool {
  let found = Ref(false)
  picked.spans.each(fn(k, s) {
    if !found.val && s.a < s.b {
      match k {
        Words(t, r, place) if t == tree_id && r == list && place.length() > 0 && place[0] == row_num =>
          found.val = true
        _ => ()
      }
    }
  })
  found.val
}

///|
/// Shared per-row memo reading `number()` and gating on `picked_row_said[(tree_id, list, n)]`: returns `n` when
/// that row has an active selection, or `0` otherwise.
fn row_picked_reader(row_v : @view.View, list : @view.NodeId, number : () -> Int) -> () -> Int {
  let tree_id = view_tree_made.val
  let mk = (tree_id, row_v.id())
  match row_picked_memos.get(mk) {
    Some(m) => m
    None => {
      let m = row_v.memo(fn() {
        let n = number()
        let rk = (tree_id, list, n)
        let s = match picked_row_said.get(rk) {
          Some(s) => s
          None => {
            if picked_row_said.length() >= 64 {
              let gone : Array[(Int, @view.NodeId, Int)] = []
              picked_row_said.each(fn(k, rs) {
                if !rs.watched() && !picked_row_has_any(k.0, k.1, k.2) {
                  gone.push(k)
                }
              })
              for k in gone {
                picked_row_said.remove(k)
              }
            }
            let s = @signals.signal(picked_row_has_any(tree_id, list, n), same=fn(a, b) { a == b })
            picked_row_said[rk] = s
            s
          }
        }
        if s.get() { n } else { 0 }
      })
      row_picked_memos[mk] = m
      row_v.owns(fn() { row_picked_memos.remove(mk) }) |> ignore
      m
    }
  }
}

///|
/// What is picked with the pointer changed: told what follows it (each node's words of the window's tree: what of them
/// is picked, words_picked_span), each paragraph whose span changed alone, at once.
fn picked_told() -> Unit {
  let active_rows : Set[(Int, @view.NodeId, Int)] = Set([])
  picked.spans.each(fn(k, s) {
    if s.a < s.b {
      match k {
        Words(t, r, place) if place.length() > 0 => active_rows.insert((t, r, place[0]))
        _ => ()
      }
    }
  })
  @signals.start_batch()
  let unread : Array[SelKey] = []
  picked_spans_said.each(fn(k, s) {
    s.set(picked_span_of(k))
    if !s.watched() {
      unread.push(k)
    }
  })
  let unread_rows : Array[(Int, @view.NodeId, Int)] = []
  picked_row_said.each(fn(rk, s) {
    s.set(active_rows.contains(rk))
    if !s.watched() {
      unread_rows.push(rk)
    }
  })
  picked_finger_said.val.set(picked.finger)
  picked_now_tell()
  cmd_sel_underline_update()
  @signals.end_batch()
  // (what no node reads any more let go)
  if picked_spans_said.length() > 64 {
    for k in unread {
      picked_spans_said.remove(k)
    }
  }
  if picked_row_said.length() > 64 {
    for rk in unread_rows {
      picked_row_said.remove(rk)
    }
  }
}

///|
/// Which paragraph node `v`'s words are, as its words picked are known (tree_key).
fn tree_key(v : @view.View) -> SelKey {
  let (row, place) = v.row_place()
  Words(view_tree_made.val, row, place)
}

///|
/// What of node `v`'s words is picked with the pointer, followed as that changes (picked_told): View::runs_picker's.
fn words_picked_span(v : @view.View) -> @view.Live[(Int, Int)] {
  let row_read = v.row_named().map(fn(t) { (t.1, row_picked_reader(t.0, t.1, t.2)) })
  By(fn() {
    let k = match row_read {
      Some((list, read)) => {
        let row_num = read()
        if row_num == 0 {
          return (0, 0)
        }
        let (row, place) = v.row_place_with(list, row_num)
        SelKey::Words(view_tree_made.val, row, place)
      }
      None => tree_key(v)
    }
    let s = match picked_spans_said.get(k) {
      Some(s) => s
      None => {
        let s = @signals.signal(picked_span_of(k), same=fn(a, b) { a == b })
        picked_spans_said[k] = s
        s
      }
    }
    let span = s.get()
    if span.0 < span.1 {
      picked_shown_node(k, v)
    }
    span
  })
}

///|
/// The paragraphs of the window's tree that can be picked as it is laid out and shown now (what an event finds: the
/// tree laid out as of its moment), in the order they are drawn: a node's words in pieces where what holds it says so
/// (words_picked), drawn (not clear, not laid out nowhere), taking input (none under a modal layer over it), each with
/// the part of it seen (what holds it cutting it: Tree::seen_bounds), laid out in its own terms as it draws them
/// (view_runs_laid), as big as it is drawn; none with a finger's pointing.
fn tree_sels(finger? : Bool = false) -> Array[SelTarget] {
  tree_sels_made.val = tree_sels_made.val + 1
  let out : Array[SelTarget] = []
  guard pointing() is Mouse || picked.finger || finger else { return out }
  match view_app.val {
    Some(tree) => {
      // (laid out as of the moment it is asked: what an event finds)
      tree.laid_as_now()
      tree.each_drawn_scaled(fn(c, x, y, a, s) {
        if c.runs.is_empty() || a <= 0.0 || !tree.allows(c.id) {
          return
        }
        match tree.view_of(c.id) {
          // (where its words are picked, by the picker that picks them: not where a block in it was lent another)
          Some(v) if v.lent(words_picks) is Some(scope_id) &&
            v.lent(@view.runs_picker).map(fn(f) { physical_equal(f, words_picker) }) == Some(true) => {
            let (bx0, by0, bx1, by1) = tree.seen_bounds(c.id)
            let x0 = dmax(x, bx0)
            let y0 = dmax(y, by0)
            let x1 = dmin(x + c.w * s, bx1)
            let y1 = dmin(y + c.h * s, by1)
            let (hx0, hy0, hx1, hy1) = match v.lent(words_hit_boxes).bind(fn(bid) { tree.view_of(bid) }) {
              Some(box_v) => {
                let (rx, ry, rw, rh) = box_v.rect()
                let (hbx0, hby0, hbx1, hby1) = tree.seen_bounds(box_v.id())
                (dmax(rx, hbx0), dmax(ry, hby0), dmin(rx + rw, hbx1), dmin(ry + rh, hby1))
              }
              None => (x0, y0, x1, y1)
            }
            if (hx1 <= hx0 || hy1 <= hy0) && (x1 <= x0 || y1 <= y0) {
              return
            }
            let (r, lay, _) = view_runs_laid(c.runs, c.words_look, c.runs_look, c.w, tree.words_scale_of(c.id), kept=c.words_breaks, tabular=c.words_tabular)
            let (place, row_depth) = tree_place_with_row(v)
            let base = tree_key(v)
            let of = v.lent(picked_ofs)
            let shape = v.lent(words_shapes).map(fn(f) { f() })
            // (who shows it, what it is of: what is picked of it told by them, picked_now)
            picked_shown_by(base, v, scope_id)
            out.push({
              base,
              layer: TreeScope(tree.stack_of(c.id), scope_id),
              island: None,
              at: place,
              row_depth,
              lay,
              text: lay.text,
              ox: x,
              oy: y,
              x0,
              y0,
              x1,
              y1,
              hx0,
              hy0,
              hx1,
              hy1,
              sc: s,
              center: if c.words_center { c.w } else { -1.0 },
              node: Some(c.id),
              of,
              shape,
              runs: c.runs,
            })
            ignore(r)
          }
          _ => ()
        }
      })
    }
    None => ()
  }
  out
}

///|
/// How many times the window's tree's paragraphs that can be picked were found (tree_sels), for a test: as a press, a
/// drag and what reads where they are ask, never as frames are drawn.
// kept across runs: counted on, read as differences
let tree_sels_made : Ref[Int] = Ref(0)

///|
/// Where node `v` stands in the window's tree: from the root down, each node's place among what holds it (a page's
/// list's row's as its key's among the list's keys, whichever of its rows are made: View::row_order), and the index in
/// that path where a `scrolls_window` row order was recorded (-1 if none).
fn tree_place_with_row(v : @view.View) -> (Array[Int], Int) {
  let up : Array[Int] = []
  let mut row_from_bottom = -1
  let mut at = v
  while at.parent() is Some(p) {
    let i = match at.row_order() {
      Some(i) => {
        if row_from_bottom < 0 {
          row_from_bottom = up.length()
        }
        i
      }
      None => p.kids().search_by(fn(k) { k.id() == at.id() }).unwrap_or(0)
    }
    up.push(i)
    at = p
  }
  let row_depth = if row_from_bottom >= 0 { up.length() - 1 - row_from_bottom } else { -1 }
  (up.rev(), row_depth)
}

///|
/// The paragraphs that can be picked as they are shown now: an old view's as its last frame painted them, the window's
/// tree's as it is laid out now (tree_sels).
fn sels_shown() -> Array[SelTarget] {
  desk.sels + tree_sels()
}

///|
/// The paragraph of the window's tree that can be picked under (x, y), the topmost (tree_sels), if one is.
fn tree_sel_at(x : Double, y : Double, finger? : Bool = false) -> SelTarget? {
  let sels = tree_sels(finger~)
  let mut k = sels.length() - 1
  while k >= 0 {
    let t = sels[k]
    if x >= t.hx0 && x < t.hx1 && y >= t.hy0 && y < t.hy1 {
      return Some(t)
    }
    k = k - 1
  }
  None
}

///|
/// Whether a mouse at (x, y) is over a paragraph of the window's tree that can be picked (tree_sel_at's, where a press
/// there picks), found by where each is drawn and cut alone, none laid out for it: what the pointer's shape is over
/// (view_over_words), worked out as often as the pointer moves.
fn tree_words_under(x : Double, y : Double, laid? : Bool = true) -> Bool {
  guard pointing() is Mouse && view_app.val is Some(tree) else { return false }
  if laid {
    tree.laid_as_now()
  }
  let found = Ref(false)
  tree.each_drawn_scaled(fn(c, cx, cy, a, s) {
    if found.val || c.runs.is_empty() || a <= 0.0 || !tree.allows(c.id) {
      return
    }
    if x < cx || y < cy || x >= cx + c.w * s || y >= cy + c.h * s {
      return
    }
    let (bx0, by0, bx1, by1) = tree.seen_bounds(c.id)
    if x < bx0 || y < by0 || x >= bx1 || y >= by1 {
      return
    }
    match tree.view_of(c.id) {
      Some(v) if v.lent(words_picks) is Some(_) &&
        v.lent(@view.runs_picker).map(fn(f) { physical_equal(f, words_picker) }) == Some(true) => found.val = true
      _ => ()
    }
  })
  found.val
}

///|
/// Whether what is picked with the pointer is of the window's tree's words (a scope of its: SelLayer's TreeScope).
fn tree_picking() -> Bool {
  picked.layer is TreeScope(_, _)
}

///|
/// What words of the window's tree are being picked in scrolls: the nearest column scrolling up and down that holds the
/// paragraph the press went down in, and the nearest row scrolling across (a code block's, a wide table's), each
/// View::scroll_holding (known by what scrolls, not by that paragraph, whose node may scroll away and be made anew
/// while picking goes on), and how fast each was last said to go toward the pointer (Scroll::edge_toward: px a ms, 0
/// still).
priv struct TreeEdge {
  scroll : @view.Scroll?
  mut speed : Double
  mut across : @view.Scroll?
  mut speed_across : Double
}

///|
// kept across runs: said as a press picks the window's tree's words, let go as they are let go or the column goes
// (tree_edge_stop)
let tree_edge : Ref[TreeEdge?] = Ref(None)

///|
/// Words of the window's tree being picked from paragraph `t` (a press on it, the pointer held): the column it is in
/// scrolls toward the pointer held past its top or its foot, the row it is in past its start or its end (tree_edge_to),
/// as an old view's list does (select_edge) and a browser's overflowing box does.
fn tree_edge_from(t : SelTarget) -> Unit {
  tree_edge_stop()
  match (view_app.val, t.node) {
    (Some(tree), Some(id)) =>
      match tree.view_of(id) {
        Some(v) => {
          let scroll = v.scroll_holding()
          let across = v.scroll_holding(across=true)
          if scroll is Some(_) || across is Some(_) {
            tree_edge.val = Some({ scroll, speed: 0.0, across, speed_across: 0.0 })
          }
        }
        None => ()
      }
    _ => ()
  }
}

///|
/// How fast what scrolls (`s`) is to go toward the pointer at `at` (the Ctx's py down a column, px across a row) while
/// `held`: past where it shows (its two ends, as it is laid out and cut by what holds it now: as the window or the page
/// changes, those then), as fast as select_edge has an old view's list go that far past (select_edge_rate, from
/// select_edge_least); within it, or let go, still. None: shown nowhere (its page covered by another, or left).
fn tree_edge_speed(tree : @view.Tree, s : @view.Scroll, across : Bool, at : Double, held : Bool) -> Double? {
  let shows = match s.shown_by() {
    Some(v) if !v.shown_nowhere() => Some(v)
    _ => None
  }
  guard shows is Some(col) else { return None }
  let (x, y, w, h) = col.rect()
  let (bx0, by0, bx1, by1) = tree.seen_bounds(col.id())
  let (top, foot) = if across {
    (dmax(x, bx0), dmin(x + w, bx1))
  } else {
    (dmax(y, by0), dmin(y + h, by1))
  }
  Some(
    if !held || foot <= top {
      0.0
    } else if at < top {
      -(top - at + select_edge_least) * select_edge_rate
    } else if at > foot {
      (at - foot + select_edge_least) * select_edge_rate
    } else {
      0.0
    },
  )
}

///|
/// Horizontal edge-scroll speed for a horizontal scroll group (`Scroll::beside` peers): only scrolls while `py` is
/// within at least one alive, visible peer's vertical visible band, returning the active peer's `Scroll` so edge
/// scrolling continues even after the slice where selection started scrolls out of view.
fn tree_edge_across_speed(
  tree : @view.Tree,
  s : @view.Scroll,
  px : Double,
  py : Double,
  held : Bool,
) -> (Double, @view.Scroll?) {
  guard held else { return (0.0, None) }
  for pair in s.shown_peers() {
    let (peer, peer_scroll) = pair
    let (x, y, w, h) = peer.rect()
    let (bx0, by0, bx1, by1) = tree.seen_bounds(peer.id())
    let vtop = dmax(y, by0)
    let vbot = dmin(y + h, by1)
    if vbot <= vtop || py < vtop || py > vbot {
      continue
    }
    let left = dmax(x, bx0)
    let right = dmin(x + w, bx1)
    if right <= left {
      continue
    }
    let v = if px < left {
      -(left - px + select_edge_least) * select_edge_rate
    } else if px > right {
      (px - right + select_edge_least) * select_edge_rate
    } else {
      0.0
    }
    return (v, Some(peer_scroll))
  }
  (0.0, None)
}

///|
/// What words of the window's tree are being picked in toward the pointer (the Ctx's px, py) while `held`
/// (tree_edge_speed): said to each only as how fast changes (Scroll::edge_toward goes on as it is said, its place a
/// function of time), never again for the same. The column shown nowhere: all of it still, and known no more, at once;
/// the row alone shown nowhere, it alone still.
fn tree_edge_to(c : Ctx, held : Bool) -> Unit {
  guard tree_edge.val is Some(e) else { return }
  guard view_app.val is Some(tree) else { return }
  // (laid out and placed as of the moment it is asked: what changed since the last frame (the column moved, made
  // shorter, laid out nowhere) as it is then)
  tree.laid_as_now()
  match e.scroll {
    Some(s) =>
      match tree_edge_speed(tree, s, false, c.py, held) {
        Some(v) =>
          if v != e.speed {
            e.speed = v
            s.edge_toward(v)
          }
        None => {
          tree_edge_stop()
          return
        }
      }
    None => ()
  }
  match e.across {
    Some(s) => {
      let (v, active) = tree_edge_across_speed(tree, s, c.px, c.py, held)
      match active {
        Some(peer_s) => {
          let switched = peer_s.serial() != s.serial()
          if switched {
            e.across = Some(peer_s)
          }
          if v != e.speed_across || switched {
            e.speed_across = v
            peer_s.edge_toward(v)
          }
        }
        None =>
          if e.speed_across != 0.0 {
            e.speed_across = 0.0
            s.edge_toward(0.0)
          }
      }
    }
    None => ()
  }
}

///|
/// What words of the window's tree were picked in still, and known no more (they are let go, the pointer let them be,
/// or the column went).
fn tree_edge_stop() -> Unit {
  match tree_edge.val {
    Some(e) => {
      match e.scroll {
        Some(s) if e.speed != 0.0 => s.edge_toward(0.0)
        _ => ()
      }
      match e.across {
        Some(s) if e.speed_across != 0.0 => s.edge_toward(0.0)
        _ => ()
      }
      tree_edge.val = None
    }
    None => ()
  }
}

///|
/// A finger held on words of the window's tree that are picked with the pointer (words_picked): what is set going for
/// its hold's moment (called off as the finger moves past the slop, is let go or called off, or another goes down).
// kept across runs: let go as a run begins (view_forget's tree_finger_off)
let tree_finger_hold : Ref[(() -> Unit)?] = Ref(None)

///|
/// A finger down at (x, y) at `at` on the window's tree: where words of its that are picked with the pointer are
/// there, at a long press's moment after (the tree's timeline: whatever frames are drawn), held still on them all the
/// while and nothing of the tree's having taken it for its own hold, what held it lets go of it (a column scrolled by
/// it, an old view under the words that took the press: called off) and it is the old frame's from then, the word
/// there picked (Ctx::finger_pick), slid on from and let go as an old view's words a finger held are
/// (finger_select.mbt).
fn tree_finger_down(tree : @view.Tree, x : Double, y : Double, at : Double) -> Unit {
  tree_finger_off()
  // (what is under it looked for at the hold's moment alone, as the tree is then: nothing laid out for it as it goes
  // down)
  guard pointing() is Finger else { return }
  // (this press's: downs_made counts it once the tree has routed it, pointer_in_now)
  let down = downs_made.val + 1
  tree_finger_hold.val = Some(
    tree
    .root()
    .at_moment(at + long_press_ms, fn() {
      tree_finger_hold.val = None
      if downs_made.val != down {
        return
      }
      let words = tree_sel_at(x, y, finger=true)
      if tree_finger_menu(tree, x, y, words) {
        return
      }
      match view_held.val {
        // (a column it scrolls held it: called off, as a hold handed on calls its cover's off)
        Some(Dragging(id)) if tree.claims_scroll(id) =>
          tree.drag_at(id, Off, x, y, view_moment(), finger=view_fingers[0]) |> ignore
        Some(Nowhere) => ()
        // (an old view under them held it, the words of the tree's that take no press drawn over it there (a page's
        // messages over 小屏's shell): its press called off, as a hold of the old frame's own on words it drew is its)
        Some(Old(_, _)) if words is Some(t) && tree_words_over(tree, t, x, y) => g().press_called_off(x, y, at)
        // (a cover held over them whose still hold goes through to what lies under it (View::gesture's `through`: the
        // page beside 中屏's sidebar), which nothing of the tree's under it took: its hold ended, as one handed through
        // is, the words under it the hold's)
        Some(Dragging(id)) if words is Some(_) && tree.hold_goes_through(id) =>
          tree.drag_at(id, Off, x, y, view_moment(), finger=view_fingers[0]) |> ignore
        // (a ground's press (View::as_ground: the page a tap on brings its bars, a reader's on 小屏) under words picked
        // with the pointer: the hold the words', the ground's press called off, no tap as it is let go)
        Some(Node(id)) if words is Some(_) && tree.is_ground(id) => tree.hold_lost_in(id.at)
        // (a node's own press, its own hold: its)
        _ => return
      }
      guard words is Some(t) else { return }
      view_down.val = None
      view_held.val = Some(Old(-1, None))
      view_input_went(-1)
      old_pointer_now(0, x, y, 0, 0, at)
      g().finger_pick(t, x, y)
    }),
  )
}

///|
/// A finger held still as long as a long press at (x, y), on what asks for a menu there (View::on_menu, Tree::menu_at):
/// its menu, as the secondary button's press asks it, and the rest of the press nobody's (a node's press let go
/// unpressed, no tap as it is let go; a column it was to scroll told Off), felt. Not where what takes the hold is
/// another's: a node's own gesture (a hold of its own, @headless.Hold), a gesture answering a hold alone there
/// (Tree::hold_at, its hold due at the same moment), a field the press went down on (view_down let go by it), an old
/// view, a cover whose hold goes through, words a finger picks there (their hold picks them, as ever). Whether it did.
fn tree_finger_menu(tree : @view.Tree, x : Double, y : Double, words : SelTarget?) -> Bool {
  guard view_down.val is Some(_) else { return false }
  let call_off : () -> Unit = match view_held.val {
    // (a field of the tree's on Android has its own long press (tree_field_held) that picks the word there; never
    // stolen by its secondary-button context menu, nor by an I-beam backdrop area wired with field_menu_on)
    Some(Node(id)) if tree_fields.contains(id) || tree_field_menu_areas.contains(id) => return false
    Some(Node(id)) => fn() { tree.hold_lost_in(id.at) }
    Some(Dragging(id)) if tree.claims_scroll(id) && words is None =>
      fn() { tree.drag_at(id, Off, x, y, view_moment(), finger=view_fingers[0]) |> ignore }
    Some(Nowhere) if words is None => fn() {  }
    _ => return false
  }
  if tree.hold_at(x, y) is Some(_) {
    return false
  }
  // (even after a field's press was cancelled by the window going behind or a second finger, a touch hold over a tree
  // field or its field_menu_on backdrop must never trigger its desktop secondary-button context menu)
  match tree.target_at(x, y) {
    Pressed(id) if tree_fields.contains(id) || tree_field_menu_areas.contains(id) => return false
    _ => ()
  }
  guard tree.menu_at(x, y, view_moment()) else { return false }
  call_off()
  view_down.val = None
  view_nothing_down.val = None
  view_held.val = Some(Nowhere)
  haptic(LongPress)
  h_frame_owed()
  true
}

///|
/// Whether paragraph `t` of the window's tree (its node's words) is what is drawn topmost at (x, y): over what else is
/// there (an old view hosted under it, which a press there reaches as its words take none: Tree::drop_at).
fn tree_words_over(tree : @view.Tree, t : SelTarget, x : Double, y : Double) -> Bool {
  match (tree.drop_at(x, y), t.node) {
    (Some(OnNode(id)), Some(n)) => id == n
    _ => false
  }
}

///|
/// What a finger's hold on words of the window's tree set going called off (tree_finger_down).
fn tree_finger_off() -> Unit {
  match tree_finger_hold.val {
    Some(stop) => stop()
    None => ()
  }
  tree_finger_hold.val = None
}
