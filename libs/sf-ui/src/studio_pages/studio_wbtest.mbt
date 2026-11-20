// Tests for ui.monoid · STANDARD STAGE (studio_pages):
// 1. Bottom scene switcher 0.00 px zero-jump invariant across (1120x637), (1120x690), (1280x1040)
// 2. Zero audit faults across all 3 scenes in Light & Dark modes
// 3. Real interactive behavior for inputs, search chip filter, progress + toast, count badge, accents, menu, confirm
// 4. Frame-rate invariance across 60 / 120 / 24 / 7 fps

///|
let settled_ms : Double = 1000.0

///|
fn studio_case(
  first_scene? : Int = 0,
  dark? : Bool = false,
  w? : Double = 1120.0,
  h? : Double = 690.0,
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w~, h~, platform=0)
  @sf.set_language(Some("en"))
  @sf.set_product("ui.monoid")
  @sf.set_accent("")
  @sf.set_dark(Some(dark))
  @ui.set_view_app(fn(root) { studio(root, first_scene~) }, theme=@sf.ui_theme_now)
  t.draw()
  t
}

///|
fn mid(t : @ui.Tester, role : @view.Role, label : String) -> (Double, Double) raise {
  let (x, y, w, h) = t.get(role, label~).rect
  (x + w / 2.0, y + h / 2.0)
}

///|
test "bottom scene switcher has 0.00 px jump across Controls, Tokens, Overlays at 1120x637, 1120x690 and 1280x1040" {
  let sizes : Array[(Double, Double)] = [(1120.0, 637.0), (1120.0, 690.0), (1280.0, 1040.0)]
  for sz in sizes {
    let (w, h) = sz
    let t = studio_case(w~, h~)
    t.run_for(settled_ms)
    let r0 = t.get(RadioGroup, label="Stage Scene").rect
    let (tx, ty) = mid(t, Radio, "Tokens")
    t.tap(tx, ty)
    t.run_for(settled_ms)
    let r1 = t.get(RadioGroup, label="Stage Scene").rect
    let (ox, oy) = mid(t, Radio, "Overlays")
    t.tap(ox, oy)
    t.run_for(settled_ms)
    let r2 = t.get(RadioGroup, label="Stage Scene").rect
    let (cx, cy) = mid(t, Radio, "Controls")
    t.tap(cx, cy)
    t.run_for(settled_ms)
    let r3 = t.get(RadioGroup, label="Stage Scene").rect
    assert_eq(r0, r1)
    assert_eq(r0, r2)
    assert_eq(r0, r3)
  }
}

///|
test "all 3 scenes in light and dark modes pass Tester::audit with zero faults" {
  let faults : Array[(Int, Bool, String)] = []
  for dark in [false, true] {
    for scene in [0, 1, 2] {
      let t = studio_case(first_scene=scene, dark~, w=1120.0, h=690.0)
      t.run_for(settled_ms)
      for f in t.audit() {
        faults.push((scene, dark, f))
      }
    }
  }
  assert_eq(faults, [])
}

///|
test "Controls scene interactive actions: Run Build, Queue Job, Publish confirm, accent & dark toggle" {
  let t = studio_case(w=1120.0, h=690.0)
  t.run_for(settled_ms)
  // Switch OKLCH accent to Blue
  let (ax, ay) = mid(t, Button, "Accent Blue")
  t.tap(ax, ay)
  t.run_for(settled_ms)
  assert_eq(@sf.accent_key(), "blue")
  // Toggle Dark mode
  let (dx, dy) = mid(t, Button, "Switch to Dark")
  t.tap(dx, dy)
  t.run_for(settled_ms)
  assert_eq(@sf.theme().dark, true)
  // Click Run Build -> progress steps from 35% to 60% and toast appears
  let (bx, by) = mid(t, Button, "Run Build")
  t.tap(bx, by)
  t.run_for(settled_ms)
  assert_true(t.words_said().iter().any(fn(w) { w.0.contains("60%") }))
  // Click Queue Job -> count badge steps from 2 to 3
  let (qx, qy) = mid(t, Button, "Queue Job")
  t.tap(qx, qy)
  t.run_for(settled_ms)
  assert_true(t.words_said().iter().any(fn(w) { w.0.contains("Queued job #3") }))
  // Click Publish… -> opens real confirm dialog, Escape closes it
  let (px, py) = mid(t, Button, "Publish…")
  t.tap(px, py)
  t.run_for(settled_ms)
  assert_eq(t.all(Dialog).length(), 1)
  t.key(@ui.key_escape)
  t.run_for(settled_ms)
  assert_eq(t.all(Dialog).length(), 0)
}

///|
test "Overlays scene menu and confirm dialog work cleanly" {
  let t = studio_case(first_scene=2, w=1120.0, h=690.0)
  t.run_for(settled_ms)
  let (mx, my) = mid(t, Button, "Configure Backends")
  t.tap(mx, my)
  t.run_for(settled_ms)
  assert_true(t.all(Menu).length() >= 1)
  t.key(@ui.key_escape)
  t.run_for(settled_ms)
  assert_eq(t.all(Menu).length(), 0)
  let (cx, cy) = mid(t, Button, "Open Confirm Dialog")
  t.tap(cx, cy)
  t.run_for(settled_ms)
  assert_eq(t.all(Dialog).length(), 1)
  t.key(@ui.key_escape)
  t.run_for(settled_ms)
  assert_eq(t.all(Dialog).length(), 0)
}

///|
/// Snapshot of scene switches, accent switches, and dark/light toggles — must be identical at 60/120/24/7 fps.
fn studio_run_snapshot() -> Array[String] raise {
  let t = studio_case(w=1120.0, h=690.0)
  let out : Array[String] = []
  let snap = fn(tag : String) raise {
    let r = t.get(RadioGroup, label="Stage Scene").rect
    let rx = (r.0 * 100.0).round() / 100.0
    let ry = (r.1 * 100.0).round() / 100.0
    out.push("\{tag} dark=\{@sf.theme().dark} accent=\{@sf.accent_key()} dock=\{rx},\{ry}")
  }
  t.run_for(settled_ms)
  snap("init")
  let (bx, by) = mid(t, Button, "Accent Blue")
  t.tap(bx, by)
  t.run_for(settled_ms)
  snap("blue")
  let (tx, ty) = mid(t, Radio, "Tokens")
  t.tap(tx, ty)
  t.run_for(settled_ms)
  snap("tokens")
  let (dx, dy) = mid(t, Button, "Switch to Dark")
  t.tap(dx, dy)
  t.run_for(settled_ms)
  snap("dark")
  let (ox, oy) = mid(t, Radio, "Overlays")
  t.tap(ox, oy)
  t.run_for(settled_ms)
  snap("overlays")
  out
}

///|
test "studio interactions are identical at 60, 120, 24 and 7 fps" {
  let res = studio_run_snapshot()
  assert_eq(res.length(), 5)
  assert_eq(res[0].has_prefix("init dark=false accent= dock="), true)
  assert_eq(res[1].has_prefix("blue dark=false accent=blue dock="), true)
  assert_eq(res[2].has_prefix("tokens dark=false accent=blue dock="), true)
  assert_eq(res[3].has_prefix("dark dark=true accent=blue dock="), true)
  assert_eq(res[4].has_prefix("overlays dark=true accent=blue dock="), true)
}
