// The windows of one run (window_kept.mbt's head): which is in place, what each of the others keeps meanwhile, what
// each open one shows, and the host's frames and input handed to the window they are of.

///|
/// What is kept of a window: the window runtime's own (window_kept_ui) and what the packages over it said (window_kept),
/// in the order said.
// kept across runs: what is kept of a window is the program's, said once
let windows_kept : Array[WindowKept] = []

///|
// kept across runs: the window runtime's own said once, as the first window other than the first is made
let windows_kept_said : Ref[Bool] = Ref(false)

///|
/// The window whose state the globals hold now (`now`): 0, the first, but while another's frame or input is handed to it.
let window_now : WindowNow = { now: 0 }

///|
priv struct WindowNow {
  mut now : Int
}

///|
/// What each window not in place keeps meanwhile: its putting back, one for each of windows_kept.
let window_slots : Map[Int, Array[() -> Unit]] = Map([])

///|
/// The windows of this run open beside the first (@hostapi.window_open_id): what each shows, by its id.
let windows_beside : Map[Int, String] = Map([])

///|
/// The tree of each window beside the first, by its id, once made (what a run let go of disposes: windows_reset).
let window_trees : Map[Int, @view.Tree] = Map([])

///|
/// What makes the tree of a window opened beside the first, by its id and what it shows, and the old frame round the
/// old views in it (set_window_tree).
let window_tree_maker : Ref[((Int, String) -> (@view.View) -> Unit)?] = Ref(None)

///|
let window_tree_around : Ref[((Ctx) -> Unit)?] = Ref(None)

///|
/// Who is told as a window beside the first has closed (its id), its tree let go of and the first window in place.
// kept across runs: said once, by what is over the window's runtime, as the program starts
let window_closed_tell : Array[(Int) -> Unit] = []

///|
/// The window whose frame, input or state is being dealt with now: 0, the first window (and every run with one), or a
/// window opened beside it (window_open_here).
pub fn current_window_id() -> Int {
  window_now.now
}

///|
/// What a package over the window's runtime keeps of each window apart (a window's layers, its notices): `take` takes
/// what the window in place keeps out of its globals and gives back its putting back; `fresh` puts in them what a window
/// made anew starts with. Said once, as the program starts (before any window beside the first opens); a window open
/// already when it is said starts with `fresh`.
pub fn window_kept(take : () -> (() -> Unit), fresh : () -> Unit) -> Unit {
  let k = { take, fresh }
  windows_kept.push(k)
  for _, slot in window_slots {
    slot.push(fresh)
  }
}

///|
/// What makes the tree of each window the app opens beside its first (window_open_here), by the window's id and what it
/// was opened for: the app's own, which may read what the app holds already (its core, its accounts), shown in its first
/// frame.
pub fn set_window_tree(make : (Int, String) -> (@view.View) -> Unit, around? : (Ctx) -> Unit) -> Unit {
  window_tree_maker.val = Some(make)
  window_tree_around.val = around
}

///|
/// Told each time a window beside the first closes (its id), after its tree is let go of, the first window in place.
pub fn when_window_closed(f : (Int) -> Unit) -> Unit {
  window_closed_tell.push(f)
}

///|
/// The windows open beside the first, by their ids, oldest first, and what each shows.
pub fn windows_open_here() -> Array[(Int, String)] {
  let out = windows_beside.iter().collect()
  out.sort_by_key(fn(w) { w.0 })
  out
}

///|
/// What window `wid` beside the first shows, while it is open.
pub fn window_shows(wid : Int) -> String? {
  windows_beside.get(wid)
}

///|
/// Whether this run opens a window of its own beside its first as one of its windows (@hostapi.windows_in_process), its
/// tree made by what set_window_tree said.
pub fn windows_here() -> Bool {
  window_tree_maker.val is Some(_) && @hostapi.windows_in_process()
}

///|
/// A window of this run opened beside its first for `what` (windows_here): its id, 0 where none opened. Its tree is
/// made as its first frame is drawn, by what set_window_tree said.
pub fn window_open_here(what : String) -> Int {
  guard windows_here() else { return 0 }
  let wid = @hostapi.window_open_id(what)
  if wid > 0 {
    windows_beside[wid] = what
  }
  wid
}

///|
/// What a window opened beside the first is opened as (window_open_spec): `role` the kind of window it is to the app
/// (a terminal, a viewer), `title` the system's title of it, `w` × `h` its size in points and `min_w` × `min_h` the
/// least it is made (0: the host's), `inset` whether its content goes under its title bar (None: as the host has it),
/// `what` what it shows, as set_window_tree's maker and window_shows are given it ("": what is said here, as JSON).
#derive(Eq, Debug)
pub(all) struct WindowSpec {
  role : String
  title : String
  w : Double
  h : Double
  min_w : Double
  min_h : Double
  inset : Bool?
  what : String
}

///|
pub fn WindowSpec::new(
  what? : String = "",
  role? : String = "",
  title? : String = "",
  w? : Double = 0.0,
  h? : Double = 0.0,
  min_w? : Double = 0.0,
  min_h? : Double = 0.0,
  inset? : Bool? = None,
) -> WindowSpec {
  { role, title, w, h, min_w, min_h, inset, what }
}

///|
/// As the host is told it (@hostapi.window_open_id): a JSON object of what is said, nothing for what is left as the
/// host has it ("role", "title", "w", "h", "minW", "minH", "inset", "what").
pub fn WindowSpec::to_json_string(self : WindowSpec) -> String {
  let m : Map[String, Json] = Map([])
  if self.role != "" {
    m["role"] = Json::string(self.role)
  }
  if self.title != "" {
    m["title"] = Json::string(self.title)
  }
  if self.w > 0.0 {
    m["w"] = Json::number(self.w)
  }
  if self.h > 0.0 {
    m["h"] = Json::number(self.h)
  }
  if self.min_w > 0.0 {
    m["minW"] = Json::number(self.min_w)
  }
  if self.min_h > 0.0 {
    m["minH"] = Json::number(self.min_h)
  }
  match self.inset {
    Some(b) => m["inset"] = Json::boolean(b)
    None => ()
  }
  if self.what != "" {
    m["what"] = Json::string(self.what)
  }
  Json::object(m).stringify()
}

///|
/// A window of this run opened beside its first as `spec` says (windows_here): its id, 0 where none opened. What it
/// shows (set_window_tree's maker, window_shows) is the spec's `what`, or the spec itself as the host was told it where
/// it says none.
pub fn window_open_spec(spec : WindowSpec) -> Int {
  guard windows_here() else { return 0 }
  let said = spec.to_json_string()
  let wid = @hostapi.window_open_id(said)
  if wid > 0 {
    windows_beside[wid] = if spec.what != "" { spec.what } else { said }
  }
  wid
}

///|
/// The title the window in place last told the host it has (set_window_title): each window's own (window_kept.mbt).
let window_title_said : Ref[String] = Ref("")

///|
/// The system's title of the window in place (current_window_id: its title bar, the Dock's and the switcher's list),
/// told the host only as it changes.
pub fn set_window_title(title : String) -> Unit {
  guard window_title_said.val != title else { return }
  window_title_said.val = title
  @hostapi.window_set_title(current_window_id(), title)
}

///|
/// The system's title of window `wid` of the run (0 the first, or one open beside it; another is none), as
/// set_window_title says it in that window.
pub fn set_window_title_of(wid : Int, title : String) -> Unit {
  if wid == current_window_id() {
    set_window_title(title)
  } else if wid == 0 || windows_beside.contains(wid) {
    as_window(wid, fn() { set_window_title(title) })
  }
}

///|
/// Window `wid` beside the first brought to the front: whether it is open still.
pub fn window_front_here(wid : Int) -> Bool {
  windows_beside.contains(wid) && @hostapi.window_front_id(wid)
}

///|
/// Window `wid` beside the first closed by the app (its page's own close): what it showed let go of now, the host told.
pub fn window_close_here(wid : Int) -> Unit {
  guard windows_beside.contains(wid) else { return }
  // (let go of between frames, never in the middle of its own: its frame ends first)
  after_frame(fn() {
    window_gone(wid)
    @hostapi.window_close_id(wid)
  })
}

///|
/// The first window's tree (view_made_now's, as window 0 makes it): what a node's tree is matched by in_tree_window.
// kept across runs: put back by view_forget
let window_zero_tree : Ref[@view.Tree?] = Ref(None)

///|
/// `f` with the globals of the window `tree` is drawn in in place (a window beside the first telling the first's tree to
/// show something: what it says of the first's nodes said in the first's state), then the one in place before put back.
/// At once where `tree` is the one in place.
fn in_tree_window(tree : @view.Tree, f : () -> Unit) -> Unit {
  if view_app.val is Some(t) && physical_equal(t, tree) {
    f()
    return
  }
  let target = if window_zero_tree.val is Some(z) && physical_equal(z, tree) {
    Some(0)
  } else {
    let mut found = None
    for wid, t in window_trees {
      if physical_equal(t, tree) {
        found = Some(wid)
      }
    }
    found
  }
  match target {
    Some(wid) if wid != window_now.now => {
      let back = window_now.now
      window_put_in(wid) |> ignore
      f()
      window_put_in(back) |> ignore
    }
    _ => f()
  }
}

///|
/// The globals made to hold window `wid`'s state (window_put_in), its tree made where it is a window not met before.
fn window_use(wid : Int) -> Unit {
  if window_put_in(wid) {
    match (window_tree_maker.val, windows_beside.get(wid)) {
      (Some(make), Some(what)) if wid > 0 =>
        match window_tree_around.val {
          Some(around) => set_view_app(make(wid, what), around~)
          None => set_view_app(make(wid, what))
        }
      _ => ()
    }
    match view_app.val {
      Some(t) if wid > 0 => window_trees[wid] = t
      _ => ()
    }
  }
}

///|
/// The globals made to hold window `wid`'s state: the one in place taken out (its slot), `wid`'s put back, or, a window
/// not met before, a fresh one's (then true: its tree is to be made).
fn window_put_in(wid : Int) -> Bool {
  let from = window_now.now
  if wid == from {
    return false
  }
  if !windows_kept_said.val {
    windows_kept_said.val = true
    let own = window_kept_ui()
    // (the runtime's own first, then what the packages over it said)
    let theirs = windows_kept.copy()
    windows_kept.clear()
    windows_kept.append(own)
    windows_kept.append(theirs)
  }
  glyph_moves_seen.val = glyph_moves.val
  window_slots[from] = windows_kept.map(fn(k) { (k.take)() })
  window_now.now = wid
  match window_slots.get(wid) {
    Some(put) => {
      window_slots.remove(wid)
      for p in put {
        p()
      }
      glyphs_moved_since()
      false
    }
    None => {
      for k in windows_kept {
        (k.fresh)()
      }
      true
    }
  }
}

///|
/// Window `wid` beside the first gone: its tree and what its frames kept let go of in its state, its slot forgotten,
/// the first window in place, and who asked told.
fn window_gone(wid : Int) -> Unit {
  guard wid > 0 && windows_beside.contains(wid) else { return }
  let back = window_now.now
  if window_slots.contains(wid) || back == wid {
    window_put_in(wid) |> ignore
    run_let_go()
    the_ctx.val.let_go()
    window_put_in(0) |> ignore
    window_slots.remove(wid)
  }
  windows_beside.remove(wid)
  window_trees.remove(wid)
  // (a scripted run acting in it acts in the first from now on)
  match driver.val {
    Some(d) if d.wid == wid => d.wid = 0
    _ => ()
  }
  if back != wid && back != 0 {
    window_put_in(back) |> ignore
  }
  for f in window_closed_tell.copy() {
    f(wid)
  }
}

///|
/// The host told window `wid` closed (the person closed it: an outside event, hostcall.mbt's outside_window).
fn window_closed_heard(wid : Int) -> Unit {
  if windows_beside.contains(wid) {
    window_gone(wid)
  }
}

///|
/// What the host hands now (a frame, input) done as the window it is of: that window put in place for it, the first
/// put back after. A run of one window does it as it is.
fn in_host_window(f : () -> Unit) -> Unit {
  if windows_beside.is_empty() || window_now.now != 0 {
    f()
    return
  }
  let wid = @hostapi.window_current()
  if wid == 0 {
    f()
    return
  }
  guard windows_beside.contains(wid) else { return }
  window_use(wid)
  f()
  window_use(0)
}

///|
/// `f` done as window `wid` (a Tester's: what it reads or does of a window beside the first; an app's, what a node of
/// that window's tree does as its tree takes a moment another window's runtime is in place for: what it keeps of its
/// window read and written as that window's), the window in place before put back after.
pub fn as_window(wid : Int, f : () -> Unit) -> Unit {
  let back = window_now.now
  window_use(wid)
  f()
  window_use(back)
}

///|
/// The windows of a run let go of as the next run begins (a Tester's reset_globals): each beside the first its tree
/// disposed (what it bound let go of, no state of its put in place: the run's is reset after), what each kept and what
/// makes their trees the next run's to say; who is told of a window closed told of none of them.
fn windows_reset() -> Unit {
  for _, t in window_trees {
    t.dispose()
  }
  window_trees.clear()
  window_slots.clear()
  windows_beside.clear()
  // (the first window's title as no host was told one: the next run's host is another)
  window_title_said.val = ""
  window_tree_maker.val = None
  window_tree_around.val = None
}

///|
/// What `r` holds kept apart for each window (window_kept), a window made anew starting with `fresh()`.
pub fn[T] window_kept_ref(r : Ref[T], fresh : () -> T) -> Unit {
  let k = kept_ref(r, fresh)
  window_kept(k.take, k.fresh)
}

///|
/// What `a` holds kept apart for each window, a window made anew starting with none.
pub fn[T] window_kept_array(a : Array[T]) -> Unit {
  let k = kept_array(a, fn() { [] })
  window_kept(k.take, k.fresh)
}

///|
/// What `m` holds kept apart for each window, a window made anew starting with none.
pub fn[K : Hash + Eq, V] window_kept_map(m : Map[K, V]) -> Unit {
  let k = kept_map(m)
  window_kept(k.take, k.fresh)
}

///|
/// What `s` holds kept apart for each window, a window made anew starting with none.
pub fn[K : Hash + Eq] window_kept_set(s : Set[K]) -> Unit {
  let k = kept_set(s)
  window_kept(k.take, k.fresh)
}

///|
/// The glyph moves (text.mbt's glyph_moves) the window in place had seen as it was last in place.
let glyph_moves_seen : Ref[Int] = Ref(0)

///|
/// The window just put back in place, where another window's frames moved a glyph it may draw from since it was in
/// place (another scale, another zoom, a plot emptied): its next frame built whole, what it keeps of its nodes looked
/// through again, nothing it presented compared with.
fn glyphs_moved_since() -> Unit {
  if glyph_moves_seen.val == glyph_moves.val {
    return
  }
  if watch_said.val == "" {
    watch_said.val = "another window's frame moved a glyph it drew"
  }
  glyphs_held_sc.val = 0.0
  presented.forget()
}
