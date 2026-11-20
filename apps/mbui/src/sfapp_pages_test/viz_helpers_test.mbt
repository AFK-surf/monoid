// View-inspection helpers for service_link_test.mbt and viewer_viz_test.mbt.

///|
/// A number as a line of the fake host's says it.
fn test_num(s : String) -> Double {
  match (try Some(@json.parse(s)) catch { _ => None }) {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
}

///|
/// The views the fake host opened of `kind`, by id, oldest first.
fn opened_views(t : @ui.Tester, kind : Int) -> Array[Int] {
  let out = []
  for l in t.views() {
    let p = l.split(" ").map(fn(x) { x.to_owned() }).to_array()
    if p.length() >= 4 && p[0] == "open" && p[2] == kind.to_string() {
      out.push(test_num(p[1]).to_int())
    }
  }
  out
}

///|
/// The hole the view `id` shows through, its rect (x, y, w, h): its last placing, shown.
fn view_rect(t : @ui.Tester, id : Int) -> (Double, Double, Double, Double)? {
  let mut out = None
  for l in t.views() {
    let p = l.split(" ").map(fn(x) { x.to_owned() }).to_array()
    if p.length() >= 6 && p[0] == "place" && p[1] == id.to_string() {
      out = if p[p.length() - 1] == "hidden" {
        None
      } else {
        Some((test_num(p[2]), test_num(p[3]), test_num(p[4]), test_num(p[5])))
      }
    }
  }
  out
}

///|
/// The page of the visualization the message places, by what it draws, and no other.
fn viz_views(t : @ui.Tester) -> (Int, Int) {
  ignore(t)
  let mut page = 0
  let mut other = 0
  for k, f in viz_frames {
    if k.has_suffix("/release.html") {
      page = f.view.id()
    } else {
      other = f.view.id()
    }
  }
  (page, other)
}

///|
/// Where the 全屏 under the page of the view `id` is (its middle), by what a screen reader is told of it: the button so
/// named whose middle lies under that page, within its width; None where none is (the page not on the screen).
fn viz_full_at(t : @ui.Tester, id : Int) -> (Double, Double)? {
  guard view_rect(t, id) is Some((x, y, w, h)) else { return None }
  for b in t.all(Button, label=@sfbase.viz_tr("android-misc.viz.fullscreen")) {
    let (bx, by, bw, bh) = b.rect
    let (mx, my) = (bx + bw / 2.0, by + bh / 2.0)
    if mx >= x && mx <= x + w && my >= y + h && my <= y + h + 44.0 {
      return Some((mx, my))
    }
  }
  None
}
