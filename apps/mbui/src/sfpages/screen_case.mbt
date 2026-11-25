// A simulator's device as Xcode draws it: its case and buttons, whose pictures its
// station makes of what Xcode has on that Mac (screens/sim-chrome.ts; `screen.chrome`), turned as the device stands. The
// case has the panel's shape cut out of it, so the picture shows through it, on the system's video layer or drawn here
// alike; its buttons are pressed where they are, held as long as they are here. Until a device's pictures have come, or
// from a station without them, device_body_node draws what it does.

///|
/// How far past what shows of a button it is still pressed: as much of a press's room as it takes, clear of what is by it.
let case_reach : Double = 16.0

///|
/// How much of a panel's corner is cut off the square picture under the case: all of it is under the case there.
let case_corner_share : Double = 0.8

///|
/// A press's room, each way.
let case_press : Double = 44.0

///|
/// A device's case as it stands now, in its own points, all turned as its picture is.
priv struct DeviceCase {
  station : String
  /// its panel's case (the same pictures where another device has the same)
  key : String
  turn : Int
  frame_w : Double
  frame_h : Double
  /// the chassis inside `frame` (excluding side-button padding), for its elevation shadow
  body : SRect
  screen : SRect
  /// the panel's corners, upright as its framebuffer is, top left and round it (shares of its width)
  corners : Array[Double]
  buttons : Array[CaseButton]
}

///|
#derive(Eq)
priv struct CaseButton {
  name : String
  at : SRect
  dx : Double
  dy : Double
  front : Bool
  usage : (Int, Int)?
}

///|
/// The rect `r` of a `w`×`h` frame, the frame turned `turn` quarters clockwise.
fn turned_rect(r : SRect, w : Double, h : Double, turn : Int) -> SRect {
  match turn {
    1 => { x: h - r.y - r.h, y: r.x, w: r.h, h: r.w }
    2 => { x: w - r.x - r.w, y: h - r.y - r.h, w: r.w, h: r.h }
    3 => { x: r.y, y: w - r.x - r.w, w: r.h, h: r.w }
    _ => r
  }
}

///|
/// A way (dx, dy) turned as turned_rect does.
fn turned_way(dx : Double, dy : Double, turn : Int) -> (Double, Double) {
  match turn {
    1 => (-dy, dx)
    2 => (-dx, -dy)
    3 => (dy, -dx)
    _ => (dx, dy)
  }
}

///|
/// The picture in `r`, `r` being it and its case's share each way on each side.
fn cased_in(r : SRect, x : Double, y : Double) -> SRect {
  let w = r.w / (1.0 + 2.0 * x)
  let h = r.h / (1.0 + 2.0 * y)
  { x: r.x + w * x, y: r.y + h * y, w, h }
}

///|
/// How much of the case and what it has is round the picture at its widest, each way, as shares of the picture: it is kept in
/// the middle, as the picture of a device with no case is, whichever side has more.
fn DeviceCase::around(self : DeviceCase) -> (Double, Double) {
  let s = self.screen
  (
    dmax(s.x, self.frame_w - s.x - s.w) / s.w,
    dmax(s.y, self.frame_h - s.y - s.h) / s.h,
  )
}

///|
/// Whether it has that button.
fn DeviceCase::has(self : DeviceCase, name : String) -> Bool {
  self.buttons.iter().any(fn(b) { b.name == name })
}

///|
/// What is known to have come of a device's pictures (each case's, each way it is turned): what was asked, and what came.
// kept across runs: each is the pictures a station made of its Xcode's, the same whoever asks
let case_asked : Map[String, Bool] = Map([])

///|
// kept across runs: as case_asked
let case_came : Map[String, Bool] = Map([])

///|
/// Each case's pictures come (case_came): what asks whether they have reads it again as this is told.
// kept across runs: a count
let case_told : @signals.Signal[Int] = @signals.signal(0)

///|
fn case_picture(station : String, key : String, turn : Int, name : String) -> String {
  "mem:sf/case/\{station}/\{key}/\{turn}/\{name}"
}

///|
/// The case of the panel a picture of `size` is of, once its pictures have come and are decoded for node `v`'s window
/// (they are asked for here, those of this way first and the rest after them, for a turn to find them come, and asked
/// decoded with the other ways it may stand, so that a turn finds them there); none: not one, or not yet. Followed as
/// the state is told and as the pictures come.
fn device_case_now(v : @view.View, s : ScreenSess, size : (Int, Int)?) -> DeviceCase? {
  s.said.get() |> ignore
  case_told.get() |> ignore
  guard s.simulator() && size is Some((pw, ph)) && pw > 0 && ph > 0 else { return None }
  guard field(s.state, "chrome") is Some(Array(panels)) && panels.length() > 0 else { return None }
  let (pw, ph) = (pw.to_double(), ph.to_double())
  let shape = dmin(pw, ph) / dmax(pw, ph)
  let mut panel = -1
  let mut off = 0.01
  for i, p in panels {
    let (w, h) = (number(Some(p), "width"), number(Some(p), "height"))
    if w > 0.0 && h > 0.0 && (shape - dmin(w, h) / dmax(w, h)).abs() < off {
      off = (shape - dmin(w, h) / dmax(w, h)).abs()
      panel = i
    }
  }
  guard panel >= 0 else { return None }
  let p = Some(panels[panel])
  // as the station says it stands, while that is a way the picture can stand (the picture of a turn comes on its own)
  let lying = (number(p, "width") > number(p, "height")) != (pw > ph)
  let said = number(s.state, "turn").to_int()
  let turn = if (said % 2 == 1) == lying {
    said
  } else if lying {
    1
  } else {
    0
  }
  let key = text(p, "key")
  if !case_asked.contains(case_picture(s.station, key, turn, "")) {
    case_ask_one(s.src, s.station, s.screen, panels, panel, turn)
  }
  guard case_came.contains(case_picture(s.station, key, turn, "")) else { return None }
  // decoded before it shows, and the other ways it may stand with it, so that a turn finds it there
  let (win_w, win_h) = v.window()
  let px = dmax(win_w, win_h) * v.pixel_scale()
  for t in 0..<4 {
    if case_came.contains(case_picture(s.station, key, t, "")) {
      v.image_ask(case_picture(s.station, key, t, "body"), px)
    }
  }
  guard v.image_ready(case_picture(s.station, key, turn, "body"), px) else { return None }
  let (fw, fh) = (number(field(p, "frame"), "width"), number(field(p, "frame"), "height"))
  let rect_of = fn(v : Json?) -> SRect {
    turned_rect({ x: number(v, "x"), y: number(v, "y"), w: number(v, "width"), h: number(v, "height") }, fw, fh, turn)
  }
  let buttons = items(p, "buttons").map(fn(b) {
    let (dx, dy) = turned_way(number(Some(b), "dx"), number(Some(b), "dy"), turn)
    let usage = number(Some(b), "usage").to_int()
    {
      name: text(Some(b), "name"),
      at: rect_of(Some(b)),
      dx,
      dy,
      front: flag(Some(b), "front"),
      usage: if usage > 0 { Some((number(Some(b), "page").to_int(), usage)) } else { None },
    }
  })
  let turned = turn % 2 == 1
  let frame_w = if turned { fh } else { fw }
  let frame_h = if turned { fw } else { fh }
  let body = match field(p, "body") {
    Some(_) as b => rect_of(b)
    None => { x: 0.0, y: 0.0, w: frame_w, h: frame_h }
  }
  Some({
    station: s.station,
    key,
    turn,
    frame_w,
    frame_h,
    body,
    screen: rect_of(field(p, "screen")),
    corners: items(p, "corners").map(fn(v) {
      match v {
        Number(n, ..) => n
        _ => 0.0
      }
    }),
    buttons,
  })
}

///|
/// This way's pictures asked for, then, as each comes, the next not asked for of the others: one at a time, as making them
/// is all the station does for as long as it takes.
fn case_ask_one(src : Source, station : String, screen : String, panels : Array[Json], panel : Int, turn : Int) -> Unit {
  let p = Some(panels[panel])
  let key = text(p, "key")
  let id = case_picture(station, key, turn, "")
  if case_asked.contains(id) {
    return
  }
  case_asked[id] = true
  let params = {
    "station": Json::string(station),
    "screen": Json::string(screen),
    "panel": Json::number(panel.to_double()),
    "turn": Json::number(turn.to_double()),
  }
  (src.call)("screen.chrome", Json::object(params), fn(r) {
    guard r is Ok(v) else { return }
    let got = Some(v)
    let take = fn(name : String, b64 : String) {
      match @codec.from_base64_exact(b64) {
        Some(png) => @ui.add_image(case_picture(station, key, turn, name), png)
        None => ()
      }
    }
    take("body", text(got, "body"))
    for b in items(p, "buttons") {
      let name = text(Some(b), "name")
      let pictures = field(field(got, "buttons"), name)
      take(name, text(pictures, "up"))
      take(name + "/down", text(pictures, "down"))
    }
    case_came[id] = true
    case_told.set(case_told.untracked() + 1)
    // the rest, one after another
    for i, _ in panels {
      for t in 0..<4 {
        if !case_asked.contains(case_picture(station, text(Some(panels[i]), "key"), t, "")) {
          case_ask_one(src, station, screen, panels, i, t)
          return
        }
      }
    }
  })
}

///|
/// The device's case round its picture in `o` (over the stage): its buttons behind it (in their pressed picture, and in
/// a way, under a press), it over them, a home button on it, and where each is pressed while it is driven; the
/// picture's corners, outside the panel, cut off as far in as the case over them (the panel's own less a little, it
/// being no circle). Each where the picture is drawn, as it is drawn (ScreenUi::shown_on).
fn device_cased_node(o : @view.View, pg : ScreenPage, size : () -> (Int, Int)?) -> Unit {
  let s = pg.s
  let u = pg.u
  let cased = fn() { device_case_now(o, s, size()) }
  // (the case as it stands, by its pictures: made again for another way it stands, or another device)
  o.pick(at_once=true, fn() { cased().map(fn(k) { (k.key, k.turn) }) }, fn(c, which) {
    c.over(Is(true)) |> ignore
    guard which is Some(_) && @signals.untracked(cased) is Some(k) else { return }
    let place = fn(n : @view.View, r : SRect) -> SRect {
      let shown = u.picture_on(n)
      let scale = shown.w / k.screen.w
      let ox = shown.x - k.screen.x * scale
      let oy = shown.y - k.screen.y * scale
      { x: ox + r.x * scale, y: oy + r.y * scale, w: r.w * scale, h: r.h * scale }
    }
    let picture = fn(name : String) { case_picture(k.station, k.key, k.turn, name) }
    let corner = fn(r : SRect, i : Int) {
      let unit = dmin(r.w, r.h) * case_corner_share
      if k.corners.length() == 4 {
        k.corners[(i + 4 - k.turn) % 4] * unit
      } else {
        0.0
      }
    }
    device_corners_node(c, pg, fn(r) { (corner(r, 0), corner(r, 1), corner(r, 2), corner(r, 3)) })
    let held = u.logs.buttons_held
    let downs : Map[String, @signals.Signal[Bool]] = Map([])
    for b in k.buttons {
      downs[b.name] = @signals.signal(false, same=fn(a, b) { a == b })
    }
    let image = fn(n : @view.View, src : () -> String, r : () -> SRect) {
      n
      .over(Is(true))
      .offset(By(fn() {
        let at = r()
        (at.x, at.y)
      }))
      .width(By(fn() { Some(r().w) }))
      .height(By(fn() { Some(r().h) }))
      .image(By(fn() { Some((src(), "", 8192)) }))
      |> ignore
    }
    // soft outside-only elevation shadow behind the chassis so the device lifts cleanly off the canvas
    c.box(fn(sh) {
      let bd = fn() { place(sh, k.body) }
      let outer_corner = fn(i : Int) {
        let b = bd()
        let sc = place(sh, k.screen)
        let bz = dmax(0.0, dmin(b.w - sc.w, b.h - sc.h) / 2.0)
        let scr_r = if k.corners.length() == 4 { k.corners[(i + 4 - k.turn) % 4] * dmin(sc.w, sc.h) } else { 0.0 }
        dmin(dmin(b.w, b.h) / 2.0, scr_r + bz)
      }
      sh
      .over(Is(true))
      .offset(By(fn() {
        let at = bd()
        (at.x, at.y)
      }))
      .width(By(fn() { Some(bd().w) }))
      .height(By(fn() { Some(bd().h) }))
      // det-ok(corners-each): the device's own: an iPhone Duo's cover is nearly square along its hinge (sim-mask.ts)
      .corners(By(fn() { Some((outer_corner(0), outer_corner(1), outer_corner(2), outer_corner(3))) }))
      .shadow(By(fn() { sim_device_shadow(u) }))
      .shadow_outside(Is(true))
      |> ignore
    })
    |> ignore
    let looks = fn(b : CaseButton) {
      c.box(fn(n) {
        let down = fn() { s.driving_now() && downs.get(b.name).map(fn(d) { d.get() }).unwrap_or(false) }
        image(n, fn() { picture(if down() { b.name + "/down" } else { b.name }) }, fn() {
          let r = place(n, b.at)
          // (pressed, in by half the way: it stays to be seen)
          if down() {
            let scale = r.w / b.at.w
            { ..r, x: r.x + b.dx * scale / 2.0, y: r.y + b.dy * scale / 2.0 }
          } else {
            r
          }
        })
      })
      |> ignore
    }
    for b in k.buttons {
      if !b.front {
        looks(b)
      }
    }
    c.box(fn(n) { image(n, fn() { picture("body") }, fn() { place(n, { x: 0.0, y: 0.0, w: k.frame_w, h: k.frame_h }) }) }) |> ignore
    for b in k.buttons {
      if b.front {
        looks(b)
      }
    }
    // where each is pressed, while it is driven
    c.show(at_once=true, fn() { s.driving_now() }, fn(p) {
      p.over(Is(true)) |> ignore
      p.each(
        at_once=true,
        fn() { k.buttons.filter(fn(b) { b.usage is Some(_) && case_button_word(b.name) is Some(_) }) },
        fn(b) { b.name },
        fn(slot, b) {
          let b = b.untracked()
          match (b.usage, case_button_word(b.name)) {
            (Some(usage), Some(word)) =>
              case_button_press_node(slot, pg, b, fn(n) { case_room(place(n, b.at), place(n, k.screen), b.front) }, usage, word, held, downs.get(b.name))
            _ => ()
          }
        },
      )
    })
  })
}

///|
/// What a person calls a button.
fn case_button_word(name : String) -> String? {
  match name {
    "power" => Some(@sf.t("web-pages.screen.device.lock"))
    "home" => Some(@sf.t("web-pages.screen.device.home"))
    "volume-up" => Some(@sf.t("web-pages.screen.debug.volumeUp"))
    "volume-down" => Some(@sf.t("web-pages.screen.debug.volumeDown"))
    "action" => Some(@sf.t("web-pages.screen.device.action"))
    "mute" => Some(@sf.t("web-pages.screen.device.mute"))
    _ => None
  }
}

///|
/// Where a button at `r` is pressed: a press's room (case_press) along its edge and across it, from the panel at `screen`
/// outward, never over that, and on the case itself as it is (a home button) only as far as that takes.
fn case_room(r : SRect, screen : SRect, front : Bool) -> SRect {
  if front {
    let w = dmax(r.w, case_press)
    let h = dmax(r.h, case_press)
    return { x: r.x + (r.w - w) / 2.0, y: r.y + (r.h - h) / 2.0, w, h }
  }
  if r.y + r.h <= screen.y + 1.0 {
    // over the panel
    let w = dmax(r.w, case_press)
    let y = dmax(r.y - case_reach, dmin(r.y, screen.y - case_press))
    { x: r.x + (r.w - w) / 2.0, y, w, h: screen.y - y }
  } else if r.y >= screen.y + screen.h - 1.0 {
    let w = dmax(r.w, case_press)
    let end = dmin(r.y + r.h + case_reach, dmax(r.y + r.h, screen.y + screen.h + case_press))
    { x: r.x + (r.w - w) / 2.0, y: screen.y + screen.h, w, h: end - screen.y - screen.h }
  } else if r.x < screen.x {
    let h = dmax(r.h, case_press)
    let x = dmax(r.x - case_reach, dmin(r.x, screen.x - case_press))
    { x, y: r.y + (r.h - h) / 2.0, w: screen.x - x, h }
  } else {
    let h = dmax(r.h, case_press)
    let end = dmin(r.x + r.w + case_reach, dmax(r.x + r.w, screen.x + screen.w + case_press))
    { x: screen.x + screen.w, y: r.y + (r.h - h) / 2.0, w: end - screen.x - screen.w, h }
  }
}

///|
/// A button pressed in `p` at `room` (where it is as its node `n` is drawn): told as it goes down and as it comes up, as
/// long as it is held here (a power button held is Siri, then the slider, as on the device); the hand's press on it down
/// as it goes down, up as it is let go or called off; pressed with no hand on it (a key's, a screen reader's Activate)
/// down and up at once. Its picture pressed while held (`down`).
fn case_button_press_node(
  p : @view.View,
  pg : ScreenPage,
  b : CaseButton,
  room : (@view.View) -> SRect,
  usage : (Int, Int),
  word : String,
  held : Map[String, Bool],
  down : @signals.Signal[Bool]?,
) -> Unit {
  let s = pg.s
  let tell = fn(on : Bool) {
    s.input(s.src, Json::object({
      "t": Json::string("button"),
      "page": Json::number(usage.0.to_double()),
      "usage": Json::number(usage.1.to_double()),
      "down": Json::boolean(on),
    }))
  }
  let shown = fn(on : Bool) {
    match down {
      Some(d) => d.set(on)
      None => ()
    }
  }
  let k = @sf.action_box_node(p, fn() { word }, fn(_) {
    match held.get(b.name) {
      // (no hand's press on it: a key's, a screen reader's Activate) down and up at once
      None => {
        tell(true)
        tell(false)
      }
      // (let go, its up not told yet: told as its press ends)
      Some(true) => {
        shown(false)
        tell(false)
      }
      Some(false) => ()
    }
    held.remove(b.name)
  }, fn(n) {
    n
    .over(Is(true))
    .offset(By(fn() {
      let r = room(n)
      (r.x, r.y)
    }))
    .width(By(fn() { Some(room(n).w) }))
    .height(By(fn() { Some(room(n).h) }))
    |> ignore
    // the hand's press on it: down as it goes down, up as it is let go (the press it ends comes next) or called off
    n.reacts(fn() { n.pressed() }, fn(on) {
      shown(on)
      if on {
        held[b.name] = true
        tell(true)
      } else if held.get(b.name) == Some(true) {
        held[b.name] = false
        tell(false)
      }
    }, at_start=false)
  })
  @sf.tip_node(pg.tips, k, fn() { word }) |> ignore
}
