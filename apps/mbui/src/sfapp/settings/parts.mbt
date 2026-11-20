// What is left of the settings pages' parts (the Android app's Controls.kt DoingMark), and the frame's state they are
// drawn in.

///|
/// Drawn in the wide frame's pane (a desktop's width): the pages as the web's settings pages
/// stand (pages.css.ts page: their head's title 22 in 600, no back where the sidebar is the way back, a column 760 wide
/// at most in the middle, 40 from the sides at least); `wide_deep`: a page under another of them (back shown).
pub let wide : Ref[Bool] = Ref(false)

///|
pub let wide_deep : Ref[Bool] = Ref(false)

///|
/// The core of the page being drawn (its head's back, in the wide frame).
let frame_core : Ref[Core?] = Ref(None)

///|
/// How far the status bar and the navigation bar reach in over the view (the app's, src/sfapp/bars.mbt, said each frame):
/// what a page's bar and its foot are padded by.
pub let status_top : Ref[Double] = Ref(0.0)

///|
pub let nav_foot : Ref[Double] = Ref(0.0)

///|
/// The room a place's top page keeps at its foot for the bottom bar.
pub let bar_room : Ref[Double] = Ref(0.0)

///|
/// Whether the page being drawn is a place of the bottom bar's at the stack's root (`page`'s `root`).
let at_root : Ref[Bool] = Ref(false)

///|
/// Under the app's top bar (`page`'s `top`: a place's top page on a phone), how far down what the page
/// shows starts, scrolling under the bar; 0 where the page has a bar of its own over it.
let root_top : Ref[Double] = Ref(0.0)

///|
/// The turning ring: 14, or 12 in a line of small text.
pub fn spinner(c : @ui.Ctx, inline? : Bool = false) -> Unit {
  @sf.spinner(c, size=if inline { 12.0 } else { 14.0 }) |> ignore
}

///|
/// Where what someone set going shows how it is: a spinner while it is under way, a small red
/// mark for a few seconds after it failed, why over it while it is pointed at (DoingMark.tsx DoingShown's tip: the
/// row or the menu that asked may have gone, the toast too). Its tip named by where it is called, as its place is.
#callsite(autofill(loc))
pub fn doing_mark(c : @ui.Ctx, running : Bool, failed : String?, inline? : Bool = false, loc~ : SourceLoc) -> Unit {
  let t = @sf.theme()
  if running {
    spinner(c, inline~)
  } else if failed is Some(why) {
    let key = "doing-mark/" + loc.to_string()
    let id = c.id(key)
    c.box(id~, taps=false, points=true, fn() { @sf.icon(c, "info", size=if inline { 12.0 } else { 14.0 }, color=t.p.red) |> ignore })
    |> ignore
    @sf.tip(c, key, id, if why == "" { @sf.t("web-main.doing.failed") } else { why })
  }
}

///|
/// What could not be read of a list, by the stations that failed (a ListNote's `failing`).
pub fn failing_of(note : Json?) -> Array[String] {
  items(note, "failing").map(fn(f) { text(Some(f), "text") })
}
