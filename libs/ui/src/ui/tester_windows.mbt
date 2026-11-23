// A Tester's windows of one run (window_slots.mbt): its fake host's windows open in the run where the test says so,
// each drawn after the first in every frame the Tester draws, at the same moment, and what the test does or reads of
// one done as that window (Tester::in_window).

///|
/// Whether the windows the app opens beside its first open in this run (@hostapi.windows_in_process: the Mac's), from
/// now on.
pub fn Tester::set_windows_in_process(self : Tester, on : Bool) -> Unit {
  self.fake.windows_in_process = on
  self.fake.wants = true
}

///|
/// The size in points window `wid` of the run is drawn at (480 × 720 unless said), from its next frame.
pub fn Tester::set_window_beside_size(self : Tester, wid : Int, w : Double, h : Double) -> Unit {
  self.fake.window_sizes[wid] = (w, h)
  self.fake.wants = true
}

///|
/// The windows of the run open beside the first, by their ids, oldest first, and what each shows.
pub fn Tester::windows_beside(self : Tester) -> Array[(Int, String)] {
  ignore(self)
  windows_open_here()
}

///|
/// `f` done as window `wid` of the run: what it reads of the window (words, what is drawn) and the input it gives (a
/// tap, keys) that window's, as the host hands it that window's; the frames it draws every window's, as ever.
pub fn Tester::in_window(self : Tester, wid : Int, f : () -> Unit) -> Unit {
  let back = self.fake.window_at
  self.fake.window_at = wid
  as_window(wid, f)
  self.fake.window_at = back
}

///|
/// Window `wid` of the run closed by the person (its own close button): the host tells the app between frames, the next
/// frame drawn.
pub fn Tester::close_window_beside(self : Tester, wid : Int) -> Unit {
  if !self.fake.window_ids_closed.contains(wid) {
    self.fake.window_ids_closed.push(wid)
  }
  on_outside(outside_window, wid, -1)
  self.fake.wants = true
}

///|
/// The windows of the run the app brought to the front, and those it closed itself, oldest first.
pub fn Tester::window_ids_fronted(self : Tester) -> Array[Int] {
  self.fake.window_ids_fronted.copy()
}

///|
pub fn Tester::window_ids_closed(self : Tester) -> Array[Int] {
  self.fake.window_ids_closed.copy()
}

///|
/// After the first window's frame of frame_shown_at's: each window of the run beside it drawn at the same moment, as
/// the host draws it, its state in place for it.
fn Tester::frames_beside(self : Tester, now : Double, shown : Double) -> Unit {
  for w in windows_open_here() {
    let (wid, _) = w
    let (ww, wh) = self.fake.window_sizes.get(wid).unwrap_or((480.0, 720.0))
    let back = self.fake.window_at
    self.fake.window_at = wid
    as_window(wid, fn() { on_frame(ww, wh, self.fake.scale, if shown > now { shown } else { now }) })
    self.fake.window_at = back
  }
}

///|
/// The title window `wid` of the run has as the host was last told it (as it was opened, @ui.set_window_title; "":
/// none).
pub fn Tester::window_title(self : Tester, wid? : Int = 0) -> String {
  ignore(self)
  fake_window_titles.get(wid).unwrap_or("")
}

///|
/// The role window `wid` beside the first was opened as (@ui.WindowSpec's `role`; "": none).
pub fn Tester::window_role(self : Tester, wid : Int) -> String {
  ignore(self)
  fake_window_roles.get(wid).unwrap_or("")
}

///|
/// What the app asked of window `wid`'s own buttons, oldest first (@hostapi.window_act: 1 minimize, 2 maximize or back,
/// 3 close; 0 the first window's, Tester::window_acts).
pub fn Tester::window_acts_of(self : Tester, wid? : Int = 0) -> Array[Int] {
  self.fake.window_acts_by.get(wid).map(fn(a) { a.copy() }).unwrap_or([])
}

///|
/// Window `wid`'s buttons in its top row or not (0 the first: Tester::set_window_inset), from its next frame on: one
/// window in full screen beside another that is not.
pub fn Tester::set_window_inset_of(self : Tester, wid : Int, on : Bool) -> Unit {
  if wid <= 0 {
    self.set_window_inset(on)
  } else {
    self.fake.window_insets[wid] = on
    self.fake.wants = true
  }
}

///|
/// Window `wid` maximized or not (0 the first: Tester::set_window_zoomed), from its next frame on.
pub fn Tester::set_window_zoomed_of(self : Tester, wid : Int, on : Bool) -> Unit {
  if wid <= 0 {
    self.set_window_zoomed(on)
  } else {
    self.fake.window_zooms[wid] = on
    self.fake.wants = true
  }
}
