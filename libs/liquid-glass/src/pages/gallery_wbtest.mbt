// The gallery's bar as the hand, the keys and a screen reader meet it: a tab list choosing the page and a radio group
// choosing the look, gone while the dialog page's modal dialog is open; the gallery with and without it; the bar, each
// page light and dark, held to mbui's audit; and what a run of choices draws, the same at 60, 120, 24 and 7 frames a
// second.

///|
/// A Tester of the gallery in a window as large as the shots' (src/shots), the page `first` first, light or `dark`,
/// with its bar where `chrome` says; drawn.
fn gallery_case(first : String, dark? : Bool = false, chrome? : Bool = true) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=1280.0, h=1040.0, platform=0)
  @lg.set_dark(Some(dark))
  @ui.set_view_app(fn(root) { gallery(root, first, chrome~) })
  t.draw()
  t
}

///|
/// The middle of a node read out as `role` named `label`.
fn middle_of(t : @ui.Tester, role : @view.Role, label : String) -> (Double, Double) raise {
  let (x, y, w, h) = t.get(role, label~).rect
  (x + w / 2.0, y + h / 2.0)
}

///|
/// The bar's page tab chosen now, as read out ("" where there is no bar).
fn chosen_page(t : @ui.Tester) -> String {
  match t.query(TabList, label="Page") {
    Some(list) => t.all(Tab, selected=true, within=list).map(fn(n) { n.label }).join(",")
    None => ""
  }
}

///|
/// Long past the dialog's coming and every spring of the pages' parts.
let settled : Double = 1000.0

///|
test "the bar chooses the page by a tap and by the arrow keys, and goes while the dialog is open" {
  let t = gallery_case("overview")
  let first = (chosen_page(t), t.all(Radio).map(fn(n) { n.label }))
  let (x, y) = middle_of(t, Tab, "Interactive")
  t.tap(x, y)
  t.run_for(settled)
  let tapped = chosen_page(t)
  // (the keyboard on the page tabs, the bar's first stop of its two, the last of the window's: Right chooses the next,
  // Dialog, whose dialog is modal: the bar gone)
  t.tab(back=true)
  t.tab(back=true)
  t.key(@ui.key_code_right)
  t.run_for(settled)
  let opened = (chosen_page(t), t.all(Dialog, label="Publish ui.monoid").length(), t.all(Radio).length())
  // (the dialog closed by Escape: the bar back, the overview chosen, as what is shown)
  t.key(@ui.key_escape)
  t.run_for(settled)
  let closed = (chosen_page(t), t.all(Dialog, label="Publish ui.monoid").length())
  assert_eq(
    (first, tapped, opened, closed),
    (("Overview", ["Light", "Dark"]), "Interactive", ("", 1, 0), ("Overview", 0)),
  )
}

///|
test "the bar's look is chosen by a tap and by the arrow keys" {
  let t = gallery_case("overview")
  let (x, y) = middle_of(t, Radio, "Dark")
  t.tap(x, y)
  t.run_for(settled)
  let tapped = (@lg.is_dark(), t.get(Radio, label="Dark").check, t.get(Radio, label="Light").check)
  // (the keyboard on the look, the window's last stop: Left chooses Light)
  t.tab(back=true)
  t.key(@ui.key_code_left)
  t.run_for(settled)
  assert_eq((tapped, @lg.is_dark()), ((true, Some(@view.On), Some(@view.Off)), false))
}

///|
test "the page asked for first is chosen, and without chrome there is no bar" {
  let t = gallery_case("interactive", dark=true)
  let with_bar = (chosen_page(t), t.get(Radio, label="Dark").check)
  let bare = gallery_case("overview", chrome=false)
  let without = (bare.all(TabList, label="Page").length(), bare.all(Radio).length())
  assert_eq((with_bar, without), (("Interactive", Some(@view.On)), (0, 0)))
}

///|
test "the gallery's bar, each page light and dark, holds to mbui's audit" {
  // (the bar's own faults: the pages' are the catalog's colours over the wallpaper, as the shots draw them)
  let faults = []
  for dark in [false, true] {
    for name in ["overview", "interactive", "dialog", "film"] {
      let t = gallery_case(name, dark~)
      t.run_for(settled)
      for f in t.audit() {
        if f.contains("pages/gallery.mbt") {
          faults.push((name, dark, f))
        }
      }
    }
  }
  assert_eq(faults, [])
}

///|
/// What the window draws as the bar chooses: after each choice, the page chosen, the look, how many boxes of glass
/// are drawn and the bar's (its left, top and width, to a hundredth of a point).
fn chosen_at() -> Array[String] raise {
  let t = gallery_case("overview")
  let out = []
  let seen = fn() {
    let r = fn(x : Double) { (x * 100.0).round() / 100.0 }
    let g = t.drawn_glass()
    let bar = g.filter(fn(e) { e.3 == bar_h }).map(fn(e) { "\{r(e.0)},\{r(e.1)},\{r(e.2)}" })
    out.push("\{chosen_page(t)} \{@lg.is_dark()} \{g.length()} \{bar.join(" ")}")
  }
  seen()
  let steps : Array[(String, @view.Role)] = [
    ("Interactive", Tab),
    ("Dark", Radio),
    ("Overview", Tab),
    ("Light", Radio),
    ("Dialog", Tab),
  ]
  for step in steps {
    let (x, y) = middle_of(t, step.1, step.0)
    t.tap(x, y)
    t.run_for(settled)
    seen()
  }
  t.key(@ui.key_escape)
  t.run_for(settled)
  seen()
  out
}

///|
test "the bottom dock switches between Optics, Deck and Loupe, and Publish opens and closes the dialog" {
  let t = gallery_case("overview", chrome=false)
  let (dx, dy) = middle_of(t, Tab, "Deck")
  t.tap(dx, dy)
  t.run_for(settled)
  let on_deck = (t.all(Button, label="Build Native").length(), t.all(Slider, label="Backdrop Luminance").length())
  let (lx, ly) = middle_of(t, Tab, "Loupe")
  t.tap(lx, ly)
  t.run_for(settled)
  let on_loupe = t.all(Group, label="Optical Loupe").length()
  let (ox, oy) = middle_of(t, Tab, "Optics")
  t.tap(ox, oy)
  t.run_for(settled)
  let (px, py) = middle_of(t, Button, "Publish")
  t.tap(px, py)
  t.run_for(settled)
  let dialog_shown = t.all(Dialog, label="Publish ui.monoid").length()
  t.key(@ui.key_escape)
  t.run_for(settled)
  let dialog_closed = t.all(Dialog, label="Publish ui.monoid").length()
  assert_eq((on_deck, on_loupe, dialog_shown, dialog_closed), ((1, 1), 1, 1, 0))
}

///|
test "a run of choices is drawn the same at 60, 120, 24 and 7 frames a second" {
  inspect(chosen_at().join("\n"), content=(
    #|Overview false 6 432.5,12,415
    #|Interactive false 9 432.5,12,415
    #|Interactive true 9 432.5,12,415
    #|Overview true 6 432.5,12,415
    #|Overview false 6 432.5,12,415
    #| false 6 
    #|Overview false 6 432.5,12,415
  ))
}
