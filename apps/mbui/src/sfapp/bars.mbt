// How far the system bars reach in over the app's view (mbui's @ui.system_bars, as the host says them), as the shell
// keeps room for them: Android's app is edge to edge (its manifest's dev.mbui.edge), its pages running under the status
// bar and the navigation bar and each padded by them where Android's are (WindowInsets.statusBars, navigationBars);
// over another app too. 0 where the host lays the view out inside them, and in a Tester unless a test says them (t.post
// of the system's `bars`). The shell gives a page what of them is its to keep room for (PageFrame's `top` and `foot`).

///|
/// What the bottom bar takes at the pages' foot in a window `width` wide, by the width a node of the window's tree
/// follows (View::window): its room laid out Small, nothing on the wide frame.
fn bar_room_at(width : Double) -> Double {
  if !@sfdesk.wide_at(width) {
    bar_room
  } else {
    0.0
  }
}

///|
/// A top bar's least height in a window `width` wide, the status bar's and its own (bar_h) as one length (TopGlassBar,
/// Chat.kt BarFrame: the status bar's padding, then heightIn(min = TopBarHeight)).
fn top_bar_h_at(width : Double) -> Double {
  status_top_now(width) + bar_h
}

///|
/// window_band for a node of the window's tree: as the frame began, followed (whether the window's buttons are the
/// app's, the zoom it is drawn at).
fn window_band_now() -> Double {
  if @ui.window_keys_own_now() {
    @sf.window_keys_band
  } else {
    dmax(window_band_mac, @ui.window_points_to_content_now(window_band_mac))
  }
}

///|
let window_band_mac : Double = 28.0

///|
/// The navigation bar's height (WindowInsets.navigationBars' bottom): what a page's foot is padded by. The soft keyboard
/// up, the view ends where it starts plus this, so what is padded by it sits on the keyboard
/// (keyboard.union(navigationBars)).
fn nav_foot() -> Double {
  @ui.system_bars().bottom
}

///|
/// What a page drawn over the whole window keeps room for (a screen's: under the status bar, over the navigation bar),
/// in a window `width` wide, the shell's to say (PageFrame).
fn system_frame_at(width : Double) -> PageFrame {
  { back: None, top: status_top_now(width), foot: nav_foot(), named: false }
}

///|
/// The status bar's height for a node of the window's tree in a window `width` wide, followed: where the window's
/// buttons are in the app's top row and it is laid out Small, their band.
fn status_top_now(width : Double) -> Double {
  let top = @ui.system_bars().top
  // (whether the buttons are in its top row read first, as the frame began, followed: a node's binding that reads
  // this (the viewers' room, viewer_host_of) is worked out again as it changes, whatever the width said then)
  let inset = @ui.window_inset_now()
  if top == 0.0 && inset && @sf.layout(width) is Small {
    window_band_now()
  } else {
    top
  }
}

///|
/// `page` made in node `v` inside the bars, as within_bars lays out an old view's (a node over all of `v`): under the
/// status bar (status_top_now, by the width of the window `v` is in) and over the navigation bar (and the keyboard,
/// nav_foot), in the room between them.
fn within_bars_tree(v : @view.View, page : (@view.View) -> Unit) -> Unit {
  v.box(fn(b) {
    b.over(Is(true)).padding(By(fn() { (0.0, status_top_now(v.window_w()), 0.0, nav_foot()) })) |> ignore
    b.box(fn(body) {
      body.grow(Is(1.0)) |> ignore
      page(body)
    })
    |> ignore
  })
  |> ignore
}
