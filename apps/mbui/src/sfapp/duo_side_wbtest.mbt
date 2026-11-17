// An iPhone Duo on its side (iOS 27.1's own bars for the app: platform 1, the system's bars able), its column of the
// system's down the window's trailing edge, 84 wide (`bars` right 84, its foot's home indicator 20): every screen sffix
// opens (corner_modes) on its outer screen folded (466 × 678) and its inner one open (951 × 669), each control on it
// (what is pressed, written in, stepped, chosen) held clear of that column, as the cards and the composer are
// (duo_wbtest.mbt). The column stands while the app hands it anything at all: a page over the whole window that puts
// the system's tabs away (`bare`) still has its close, its download, its 全屏 there (ios_nav.h: the bar is put away
// only with no action in it), so only a screen filled whole (a film's 全屏: bare, nothing handed) is held to the window.
// Found as #6784's dialogs were mended (2026-11-17): a drive's text read, a drive's film or sound played, a station's
// terminal, the switcher and the security lock's code each reached under it. No screen is left out by its name. What
// is left out is so by what it is:
// - what shows of a panel of the tape beside the one in use, pressed to bring it over (the page beside the sidebar,
//   `收起侧边栏`; the chat's panel beside the page, `打开侧栏`: the tape's card, which goes on under the column to the
//   screen's edge, and what is in it), there to be pressed as a whole; each then brought over by that press and held
//   as any;
// - what a box that scrolls across holds past its edge (a board's columns, a wide table's foot), where the box itself
//   shows clear of the column: the hand scrolls it in, to the box's edge (mbui's Tester::across_shown); held then
//   scrolled to its end, where all of it has come in clear of the column as the box is.

///|
/// The two screens of an iPhone Duo on its side: the outer one folded, the inner one open.
let duo_side_windows : Array[(Double, Double)] = [(466.0, 678.0), (951.0, 669.0)]

///|
/// How wide the system's column down the window's trailing edge is on its side.
let duo_side_column : Double = 84.0

///|
/// What a panel of the tape beside the one in use is said as, pressed to bring it over (sfdesk's tape_words): the page
/// beside the sidebar, the chat's panel beside the page.
fn duo_side_covers_said() -> Array[String] {
  [@sf.t("web-main.sidebar.close"), @sf.t("web-pages.chat.openPanel")]
}

///|
/// The roles of what is acted on: pressed, written in, stepped, chosen.
fn duo_side_acted(r : @ui.Role) -> Bool {
  r
  is (Button
  | Link
  | Checkbox
  | Switch
  | Radio
  | Slider
  | Tab
  | MenuItem
  | MenuItemCheckbox
  | MenuItemRadio
  | Option
  | Combobox
  | TextField)
}

///|
/// Whether the system's column stands as the app's bars were handed last (Tester::nav_said): all but where something
/// up over the whole window put the tabs away and hands no action at all (a film's 全屏).
fn duo_side_column_up(said : String) -> Bool {
  let j = @json.parse(said) catch { _ => return true }
  guard j is Object(o) else { return true }
  guard o.get("bare") is Some(True) else { return true }
  match o.get("groups") {
    Some(Array(gs)) =>
      gs.iter().any(fn(g) { g is Object(go) && go.get("items") is Some(Array(items)) && items.length() > 0 })
    _ => false
  }
}

///|
/// What on the screen just drawn reaches under the column, as `at` says the screen: a line each; and each box that
/// scrolls across, clear of the column, that holds something past it (`across` false: nothing held so, each a line).
fn duo_side_under(
  t : @ui.Tester,
  w : Double,
  at : String,
  across? : Bool = true,
) -> (Array[String], Array[(Double, Double, Double, Double)]) {
  guard duo_side_column_up(t.nav_said()) else { return ([], []) }
  let edge = w - duo_side_column + 0.5
  let sems = t.semantics()
  // (what shows of a panel of the tape beside the one in use, past it: its card, pressed to bring it over, from its
  // left edge on)
  let card = sems.search_by(fn(s) {
    !s.hidden && duo_side_covers_said().contains(s.label) && s.rect.0 > 0.0 && s.rect.0 < w
  }).map(fn(i) { sems[i].rect.0 })
  // (what scrolls across and shows clear of the column)
  let boxes = if across { t.across_shown().filter(fn(a) { a.2 > 0.0 && a.3 > 0.0 && a.0 + a.2 <= edge }) } else { [] }
  let held : Array[(Double, Double, Double, Double)] = []
  let out = []
  for s in sems {
    let (x, y, sw, sh) = s.rect
    if s.hidden || !duo_side_acted(s.role) || sw <= 0.0 || sh <= 0.0 || x + sw <= edge {
      continue
    }
    if card is Some(px) && x >= px - 0.5 {
      continue
    }
    let mid = y + sh / 2.0
    match boxes.search_by(fn(a) { x >= a.0 - 0.5 && mid >= a.1 && mid <= a.1 + a.3 }) {
      Some(i) => {
        if !held.contains(boxes[i]) {
          held.push(boxes[i])
        }
        continue
      }
      None => ()
    }
    out.push("\{at}: \{s.role} \"\{s.label}\" at \{@ui.rect_text(s.rect)}, under the column past \{w - duo_side_column}")
  }
  (out, held)
}

///|
/// What on the screen just drawn reaches under the column (duo_side_under), and what each box that scrolls across
/// holds past it once that box is scrolled to its end: all of it come in by then, clear of the column as the box is.
fn duo_side_held(t : @ui.Tester, w : Double, at : String) -> Array[String] {
  let (out, held) = duo_side_under(t, w, at)
  if held.length() > 0 {
    for a in held {
      t.wheel_with(a.0 + a.2 / 2.0, a.1 + a.3 / 2.0, 100000.0, 0.0, 0)
    }
    t.run_for(@ui.move_most_ms)
    out.append(duo_side_under(t, w, at + " (scrolled across to its end)", across=false).0)
  }
  out
}

///|
/// `mode` opened in an iPhone Duo's window `w` × `h` on its side (the system's column down its trailing edge), a moment
/// after it opens (what it opens with over: screen_in's).
fn duo_side_open(mode : String, w : Double, h : Double) -> @ui.Tester {
  new_run()
  let src = fixture(mode)
  open_fixture_over(mode, src)
  let t = @ui.Tester::new(
    fn(c) { view(c, src) },
    tree=app_tree(src),
    w~,
    h~,
    platform=1,
    nav_able=true,
    // (a screen's own rules are the sweeps' (corners_wbtest.mbt): this one holds where its controls stand)
    corners_held=false,
    env=[("MBUI_LOCALE", "zh"), ("MBUI_REDUCE_MOTION", "1")],
  )
  t.post(@hostapi.system_channel, "{\"bars\":{\"top\":0,\"bottom\":20,\"left\":0,\"right\":\{duo_side_column}}}")
  t.run_for(squeeze_opening)
  t
}

///|
/// Every screen in window `w` × `h` on its side (see the file's head): what of each reaches under the column.
fn duo_side_check(w : Double, h : Double) -> Unit raise {
  let wrong : Array[String] = []
  for mode in corner_modes {
    let at = "\{w}x\{h} \{mode}"
    let t = duo_side_open(mode, w, h)
    wrong.append(duo_side_held(t, w, at))
    // the page beside the sidebar in use brought over by a press on it, then the chat's panel beside the page (nothing
    // over the frame: a card is said only then), and each held as any
    for step in duo_side_covers_said() {
      match said_at(t, step) {
        Some((x, y, cw, ch)) if x > 0.0 && x < w => {
          t.tap(x + dmin(cw, w - x) / 2.0, y + ch / 2.0)
          t.run_for(@ui.move_most_ms)
          wrong.append(duo_side_held(t, w, at + " (" + step + " pressed)"))
        }
        _ => ()
      }
    }
  }
  if wrong.length() > 0 {
    fail("\{wrong.length()} under the system's column:\n" + wrong.join("\n"))
  }
}

///|
test "an iPhone Duo folded on its side (466x678, side 84): every screen keeps its controls clear of the system column" {
  duo_side_check(duo_side_windows[0].0, duo_side_windows[0].1)
}

///|
test "an iPhone Duo open on its side (951x669, side 84): every screen keeps its controls clear of the system column" {
  duo_side_check(duo_side_windows[1].0, duo_side_windows[1].1)
}
