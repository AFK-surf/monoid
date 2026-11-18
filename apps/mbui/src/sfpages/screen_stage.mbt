// The remote screen's stage (still.fail apps/android app/remote/ScreenViewer.kt Stage, Over, Ended, Drops, Pointer and the
// gestures), as nodes of the window's tree: the frame fitted and zoomed (its pictures ui's stream nodes, where the zoom
// has them as each frame is drawn), its pointer; how the view is, and the files sent, over it; what a finger, a mouse
// and its wheel do on it, each at its moment (on_drag, on_menu, on_wheel, on_pointer_moved).

///|
/// How far a finger goes before it is a move, not a tap (Android's touch slop, 8 dp); how long it is held still for a
/// long press; how soon after a tap a finger down again drags (ViewConfiguration's).
let screen_slop : Double = 8.0

///|
let screen_hold_ms : Double = 400.0

///|
let screen_double_tap_ms : Double = 300.0

///|
/// How far from the stage's edges the pointer is kept while zoomed in (40).
let screen_keep_margin : Double = 40.0

///|
/// How a screen gone dark is blurred under its dark (ScreenViewer.kt Stage: BlurEffect(28.dp), a radius Skia takes as
/// a deviation of 0.57735 of it and half a pixel: the glass's blur is the deviation).
let screen_over_blur : Double = 28.0 * 0.57735 + 0.5

///|
/// A floating ground's shadow (the theme's `shadow=Sm`: 2 blurred, 1 down), which a style laid on a node does not
/// draw (@sf.style_node): said on the node itself.
fn floats_node(v : @view.View) -> Unit {
  v.shadow(By(fn() { (2.0, 1.0, @ui.tree_theme().shadow) })) |> ignore
}

///|
/// The stage's view of a frame: where it is fitted.
fn ScreenUi::fit(self : ScreenUi) -> SRect {
  match self.fit_for {
    Some((w, h)) =>
      cased_in(
        fit_in(
          self.box_w.untracked(),
          self.box_h.untracked(),
          w.to_double() * (1.0 + 2.0 * self.case_x),
          h.to_double() * (1.0 + 2.0 * self.case_y),
        ),
        self.case_x,
        self.case_y,
      )
    None => srect_zero
  }
}

///|
/// Where the frame is drawn on the stage as node `n` is drawn (its zoom's glide or fling as far as it has gone then,
/// followed while one goes: the picture moves with it), and how big; nothing before its size is known.
fn ScreenUi::picture_on(self : ScreenUi, n : @view.View) -> SRect {
  self.zoom.told()
  // det-ok(layout-drawn-while): the picture is what the zoom moves and makes larger: its box is the picture's
  self.shown_at(n.drawn_while(fn(at) { self.zoom.goes_at(at) }))
}

///|
/// Whether its pictures may show on their system video layers now (live, not over, not handed to a window of its own of
/// this run while this page only goes: that window shows the layer): read as each frame draws them (ui's stream's
/// `layer`), not followed.
fn ScreenSess::layers_now(self : ScreenSess, over : () -> Bool) -> Bool {
  @signals.untracked(fn() {
    !(self.phase_now() != "live" && self.shown_seen()) &&
    !over() &&
    !(@sfbase.lone_page.val is None && @sfbase.window_has_screen(self.station, self.screen))
  })
}

///|
/// The picture the pointer may be drawn over on its system video layer, if it shows there (@ui.Stream::layered): the
/// part's over the whole's while a part is drawn over it (that part with it), else the whole's. None while what it is
/// drawn over is drawn here (the part's not on a layer, faded, under the dark…): the pointer drawn here too. Followed as
/// the streams are made and show (streams_told, part_told).
fn pointer_layer_of(s : ScreenSess) -> (@ui.Stream, Part?)? {
  s.streams_told.get() |> ignore
  s.part_told.get() |> ignore
  match (s.part, s.part_shown()) {
    (Some(pst), Some(p)) => if pst.layered() { Some((pst, Some(p))) } else { None }
    _ =>
      match s.stream {
        Some(st) if st.layered() => Some((st, None))
        _ => None
      }
  }
}

///|
/// Where the pointer is drawn while the picture shows in `f` (`over`: the view over): over the picture on its system
/// video layer where it shows there, by the host, moved as the station's pointer moves with nothing drawn
/// (ScreenSess::pointer_moved); else None, drawn here (screen_pointer_node). Followed.
fn pointer_on_layer(s : ScreenSess, over : () -> Bool) -> (@ui.Stream, Part?)? {
  s.said.get() |> ignore
  if over() || (s.phase_now() != "live" && s.shown_seen()) {
    None
  } else {
    pointer_layer_of(s)
  }
}

///|
/// The pointer on the picture's layer, while it shows there (pointer_on_layer), in `f`: in the station's shape, where
/// pointer_now has it, told the host as either changes; what the session follows of it as it moves (ScreenSess::
/// pointer_moved). A layer it is not on has none; none on any as `f` is let go.
fn screen_pointer_layer_node(f : @view.View, pg : ScreenPage, over : () -> Bool) -> Unit {
  let s = pg.s
  let u = pg.u
  // (which picture it is on, by its place: 0 none, 1 the whole's, 2 the part's; the part; the shape; where; whether it
  // follows the station's)
  f.reacts(
    fn() {
      match pointer_on_layer(s, over) {
        Some((_, part)) => {
          let shape = match pointer_shape(s) {
            "none" => "default"
            sh => sh
          }
          let follows = !u.mouse.over.get() && !pad_points(s, u) && pointer_shape(s) != "none"
          (if part is Some(_) { 2 } else { 1 }, part, shape, pointer_now(s, u), follows)
        }
        None => (0, None, "", None, false)
      }
    },
    fn(now) {
      let (which, part, shape, at, follows) = now
      let on = if which == 0 { None } else { @signals.untracked(fn() { pointer_layer_of(s) }) }
      s.pointer_layer = match on {
        Some((st, _)) => Some({ on: st, part, follows })
        None => None
      }
      for st in [s.stream, s.part] {
        match (st, on) {
          (Some(st), Some((o, _))) if physical_equal(st, o) => ()
          (Some(st), _) => st.pointer_at(None)
          (None, _) => ()
        }
      }
      match on {
        Some((o, _)) => {
          let (image, png) = @sf.pointer_png_at(f.pixel_scale(), shape~)
          let (hx, hy) = @sf.pointer_hotspot(shape)
          o.pointer_image(image, png, @sf.pointer_size, @sf.pointer_size, hx, hy)
          o.pointer_at(at.map(fn(a) { point_on(a, part) }))
        }
        None => ()
      }
    },
  )
  f.owns(fn() {
    s.pointer_layer = None
    for st in [s.stream, s.part] {
      match st {
        Some(st) => st.pointer_at(None)
        None => ()
      }
    }
  })
  |> ignore
}

///|
/// Where the pointer is now as this device draws it: the trackpad's while it drives it so, else the station's (none
/// while it is hidden there, `none`); none while this device's own mouse is over the picture driving it (it is the
/// screen's pointer then, in its shape). Followed: as either moves, the mouse comes or goes, the state is told.
fn pointer_now(s : ScreenSess, u : ScreenUi) -> (Double, Double)? {
  s.cursor_said.get() |> ignore
  s.said.get() |> ignore
  let (pad, placed) = u.pad.placed_said()
  if u.mouse.over.get() {
    None
  } else if s.driving() && s.pad(s.src) && placed {
    Some(pad)
  } else if pointer_shape(s) == "none" {
    None
  } else {
    s.cursor()
  }
}

///|
/// The trackpad's pointer is the one drawn: driving it as a trackpad, once the pad was moved or started where the
/// station's pointer is (until then the station's own is, where the first press starts it).
fn pad_points(s : ScreenSess, u : ScreenUi) -> Bool {
  s.driving() && s.pad(s.src) && u.pad.placed
}

///|
/// The station's pointer's shape (a CSS cursor's name, `none` hidden), the arrow's where it says none.
fn pointer_shape(s : ScreenSess) -> String {
  match text(field(s.state, "cursor"), "shape") {
    "" => "default"
    shape => shape
  }
}

///|
/// The frame, fitted and zoomed, its pointer; the gestures; how the view is, and the files sent, over it; in `p`, as
/// much of it as the stage's room. `pair`: the mouse's buttons floating at the end of its foot (mouse_float_node), what
/// else is there in a column of its own ending before them, never under them.
fn screen_stage_node(p : @view.View, pg : ScreenPage, pair? : () -> Bool = fn() { false }) -> Unit {
  let s = pg.s
  let u = pg.u
  let phase = fn() { s.phase_now() }
  let over = fn() { phase_over(phase()) }
  // over, the screen's place kept, gone dark (its last size, or a desktop's when none came)
  let size = fn() {
    s.said.get() |> ignore
    s.part_told.get() |> ignore
    match s.frame_size() {
      Some(sz) => Some(sz)
      None => if over() { Some((16, 10)) } else { None }
    }
  }
  // (a simulator's device not zoomed in: its body round the picture past the stage, unclipped)
  let in_body = fn() {
    u.zoom.told()
    s.said.get() |> ignore
    s.simulator() && !u.zoom.zoomed_at(p.drawn_while(fn(t) { u.zoom.goes_at(t) }))
  }
  p.box(fn(st) {
    st
    .grow(Is(1.0))
    .shrink(Is(1.0))
    .basis(Is(Some(0.0)))
    .min_height(Is(Some(0.0)))
    .min_width(Is(Some(0.0)))
    .clips(By(fn() { !in_body() }))
    |> ignore
    if pg.in_tab {
      st.ground(By(fn() { @ui.tree_theme().color(Faint) })) |> ignore
    }
    st.by_room(fn(held, room) {
      held.box(fn(stage) {
        stage.height(By(fn() { room.height() })) |> ignore
        u.stage_node = Some(stage)
        screen_stage_room(stage, pg, room, size, over)
        screen_stage_gestures(stage, pg)
        screen_stage_picture(stage, pg, size, over)
        screen_stage_said(stage, pg, phase, over)
      })
      |> ignore
    })
    .grow(Is(1.0))
    .shrink(Is(1.0))
    .basis(Is(Some(0.0)))
    .min_height(Is(Some(0.0)))
    |> ignore
    // (over the stage, not in it: a press on what is pressed here is its alone, not the screen's under it too)
    screen_stage_foot(st, pg, pair)
  })
  |> ignore
}

///|
/// The stage's room `room` and the frame's size (`size`), told the zoom at the moment either changes: another size of
/// frame, over (gone dark), turned or given another width by the system column, fitted again; its height alone (the
/// keyboard) keeps the picture and pointer as they were. A device's case round its picture is fitted with it, and a
/// device's page keeps some of the room for what the device has itself (debug_room). Zoomed in, the part of the screen
/// in sight is told the core, in this device's pixels (the whole once it is not).
fn screen_stage_room(
  stage : @view.View,
  pg : ScreenPage,
  room : @view.Room,
  size : () -> (Int, Int)?,
  over : () -> Bool,
) -> Unit {
  let s = pg.s
  let u = pg.u
  stage.reacts(
    fn() {
      let sz = size()
      let cased = device_case_now(stage, s, sz)
      (room.width(), room.height().unwrap_or(0.0), sz, over(), cased.map(fn(k) { k.around() }), debug_room(u, sz, cased))
    },
    fn(now) {
      let (bw, bh, sz, over, around, (room_w, room_h)) = now
      let at = stage.cause_at()
      if over && !u.over_seen {
        u.zoom.fit_now(at~)
      }
      u.over_seen = over
      if sz != u.fit_for {
        u.zoom.fit_now(at~)
      }
      let (was_w, was_h) = (u.box_w.untracked(), u.box_h.untracked())
      if (bw != was_w || bh != was_h) && was_w > 0.0 && was_h > 0.0 && sz == u.fit_for && sz is Some(_) {
        // Turned, or a fitted view given a new width by the system column: fit again. Height alone (the keyboard)
        // keeps the picture and pointer as before. (a device's page gives the stage's height to what comes as its state
        // does, its poses: its picture fitted to what is left, or it would be taken for zoomed in, its body gone)
        if (was_w > was_h) != (bw > bh) || (u.zoom.fitted && (bw != was_w || s.simulator())) {
          u.zoom.fit_now(at~)
        } else {
          u.zoom.resize_keeping(bw, bh, @signals.untracked(fn() { pointer_now(s, u) }), screen_keep_margin, when=at)
        }
      }
      u.box_w.set(bw)
      u.box_h.set(bh)
      u.fit_for = sz
      let (case_x, case_y) = around.unwrap_or((0.0, 0.0))
      u.case_x = case_x
      u.case_y = case_y
      match sz {
        Some((w, h)) => u.zoom.natural(w.to_double() * (1.0 + 2.0 * case_x), h.to_double() * (1.0 + 2.0 * case_y), at~)
        None => u.zoom.natural(0.0, 0.0, at~)
      }
      u.zoom.boxed(dmax(0.0, bw - room_w), dmax(0.0, bh - room_h), at~)
    },
  )
  // zoomed in, the part of the screen in sight told the core, as the zoom comes to rest there (a glide's end)
  stage.reacts(
    fn() {
      u.zoom.told()
      u.box_w.get() |> ignore
      u.box_h.get() |> ignore
      let at = stage.drawn_while(fn(t) { u.zoom.goes_at(t) })
      (u.in_sight_at(at), u.shown_at(at))
    },
    fn(now) {
      let (part, shown) = now
      let scale = stage.pixel_scale()
      let (w, h) = match part {
        Some(p) => (p.w * shown.w * scale, p.h * shown.h * scale)
        None => (0.0, 0.0)
      }
      s.look(s.src, part, w, h)
    },
  )
}

///|
/// The frame drawn on the stage where the zoom has it: the whole's picture, and zoomed in the part of the screen the
/// station sends alone, sharper, over it where it is (ui's stream nodes; the session holds the streams, closing them as
/// the view goes); on its way back, as it was, faded; over (ended, gone…), blurred under the dark it has gone to, what
/// happened said there. A device's case or body round it; what the device has itself beside it (a wide page's); the
/// pointer over it at its own size, however zoomed, in the station's shape: the trackpad's and the station's two of
/// their own, each where its own says, so the one put in the other's place as the trackpad is chosen or left is that
/// one coming, never the other moving there.
fn screen_stage_picture(stage : @view.View, pg : ScreenPage, size : () -> (Int, Int)?, over : () -> Bool) -> Unit {
  let s = pg.s
  let u = pg.u
  let showing = fn() {
    size() is Some(_) &&
    {
      u.zoom.told()
      u.box_w.get() > 0.0
    }
  }
  stage.show(at_once=true, showing, fn(f) {
    f.over(Is(true)) |> ignore
    // the picture, as far in as the zoom has it as each frame is drawn
    f.box(fn(pic) {
      let shown = fn() { u.picture_on(pic) }
      pic
      .over(Is(true))
      .offset(By(fn() {
        let r = shown()
        (r.x, r.y)
      }))
      .width(By(fn() { Some(shown().w) }))
      .height(By(fn() { Some(shown().h) }))
      // (on its way back, as it was, faded)
      .alpha(By(fn() { if s.phase_now() != "live" && s.shown_seen() && !over() { 0.4 } else { 1.0 } }))
      |> ignore
      pic.pick(at_once=true, fn() { s.streams_told.get() }, fn(w, _) {
        w.over(Is(true)) |> ignore
        match s.stream {
          // (live: on the system's video layer where it has one; faded, under the dark or handed to a window of its
          // own, drawn here)
          Some(st) => @ui.stream(w, st, closes=false, layer=fn() { s.layers_now(over) }).over(Is(true)) |> ignore
          None => ()
        }
        match s.part {
          Some(pst) =>
            w.box(fn(pb) {
              let part = fn() {
                s.part_told.get() |> ignore
                s.part_shown()
              }
              pb
              .over(Is(true))
              .offset(By(fn() {
                match part() {
                  Some(p) => {
                    let r = shown()
                    (p.x * r.w, p.y * r.h)
                  }
                  None => (0.0, 0.0)
                }
              }))
              .width(By(fn() { part().map(fn(p) { p.w * shown().w }) }))
              .height(By(fn() { part().map(fn(p) { p.h * shown().h }) }))
              .alpha(By(fn() { if part() is Some(_) { 1.0 } else { 0.0 } }))
              |> ignore
              @ui.stream(pb, pst, closes=false, layer=fn() { s.layers_now(over) }).over(Is(true)) |> ignore
            })
            |> ignore
          None => ()
        }
      })
    })
    |> ignore
    // a device's case round it (not zoomed in), or the body of a simulator's with none
    device_body_node(f, pg, size)
    debug_by_device_node(f, pg, size)
    // where the pointer is drawn: over the picture on its system video layer where it shows there, else here
    screen_pointer_layer_node(f, pg, over)
    // over: the screen's place gone dark (its last frame showing through, blurred), what happened said there; else the
    // pointer
    f.pick(at_once=true, over, fn(o, is_over) {
      o.over(Is(true)) |> ignore
      if is_over {
        screen_over_node(o, pg)
      } else {
        screen_pointer_node(o, pg, over)
      }
    })
  })
}

///|
/// Whether a frame of it was shown since it opened, followed (a frame kept on screen through a reconnect or an end).
fn ScreenSess::shown_seen(self : ScreenSess) -> Bool {
  self.part_told.get() |> ignore
  self.shown_any
}

///|
/// The screen gone dark in its place in `o` (its last frame showing through, blurred), what happened and why said
/// there, 重新打开 where it may be had again.
fn screen_over_node(o : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  o.box(fn(b) {
    let fit = fn() {
      u.box_w.get() |> ignore
      u.box_h.get() |> ignore
      u.zoom.told()
      u.fit()
    }
    let veil = fn() { @ui.tree_theme().color(if s.shown_seen() { Veil } else { VeilDeep }) }
    b
    .over(Is(true))
    .offset(By(fn() {
      let r = fit()
      (r.x, r.y)
    }))
    .width(By(fn() { Some(fit().w) }))
    .height(By(fn() { Some(fit().h) }))
    .glass(By(fn() { Some(@ui.Glass::frosted(blur=screen_over_blur, tint=veil(), solid=veil())) }))
    |> ignore
    @sf.style_node(b, fn() { over_box })
    screen_ended_node(b, pg)
  })
  |> ignore
}

///|
/// The pointer drawn over the frame in `o`, at its own size however zoomed, its hot spot where it points, in the
/// station's shape (the trackpad's, hidden there, an arrow); none while it is hidden or this device's mouse is over the
/// picture driving it.
fn screen_pointer_node(o : @view.View, pg : ScreenPage, over : () -> Bool) -> Unit {
  let s = pg.s
  let u = pg.u
  // (the trackpad's and the station's: each a node of its own, so one comes as the other goes, never moving between;
  // none while the picture's layer has it: screen_pointer_layer_node)
  o.pick(at_once=true, fn() {
    s.said.get() |> ignore
    if pointer_on_layer(s, over) is Some(_) {
      None
    } else {
      pointer_now(s, u).map(fn(_) { pad_points(s, u) })
    }
  }, fn(q, which) {
    q.over(Is(true)) |> ignore
    guard which is Some(_) else { return }
    q.box(fn(ptr) {
      let shape = fn() {
        s.said.get() |> ignore
        match pointer_shape(s) {
          "none" => "default"
          sh => sh
        }
      }
      let place = fn() {
        let r = u.picture_on(ptr)
        match pointer_now(s, u) {
          Some((ax, ay)) => {
            let (hx, hy) = @sf.pointer_hotspot(shape())
            (r.x + ax * r.w - hx, r.y + ay * r.h - hy)
          }
          None => (0.0, 0.0)
        }
      }
      ptr
      .over(Is(true))
      .width(Is(Some(@sf.pointer_size)))
      .height(Is(Some(@sf.pointer_size)))
      .offset(By(place))
      .image(By(fn() { Some((@sf.pointer_image_at(ptr.pixel_scale(), shape=shape()), "", 0)) }))
      |> ignore
    })
    |> ignore
  })
}

///|
/// How the view is on its way (in the middle of the stage, in the pill every wait is said in, said once it has been
/// waited on a moment: later_ms) in `stage`.
fn screen_stage_said(stage : @view.View, pg : ScreenPage, phase : () -> String, over : () -> Bool) -> Unit {
  ignore(over)
  let s = pg.s
  let words = fn() {
    match phase() {
      "live" => if s.shown_seen() { None } else { Some(@sf.t("android-misc.screen.starting")) }
      "connecting" => Some(s.message().unwrap_or(@sf.t("common.connecting")))
      "reconnecting" => Some(s.message().unwrap_or(@sf.t("common.reconnecting")))
      _ => None
    }
  }
  stage.pick(at_once=true, words, fn(c, said) {
    c.over(Is(true)) |> ignore
    guard said is Some(w) else { return }
    @sf.style_node(c, fn() { stage_center })
    // (said once it has been a moment: its room kept till then)
    let later = @signals.signal(false)
    c.at_moment(c.cause_at() + @sf.later_ms, fn() { later.set(true) }, later=true) |> ignore
    c.box(fn(pill) {
      @sf.style_node(pill, fn() { wait_pill_box }, in_row=true)
      floats_node(pill)
      pill.alpha(By(fn() { if later.get() { 1.0 } else { 0.0 } })) |> ignore
      @sf.spinner_node(pill, size=wait_spinner) |> ignore
      @sf.words_node(pill, fn() { w }, fn() { wait_pill_words }) |> ignore
    })
    |> ignore
  })
}

///|
/// What happened and why (each once, not the headline again), and 重新打开 where it may be had again, light on the
/// screen's dark; the way out is the bar's ×, not a second one here.
fn screen_ended_node(b : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  b.box(fn(e) {
    @sf.style_node(e, fn() { ended_box })
    let headline = fn() { @sf.t("android-misc.screen." + s.phase_now()) }
    @sf.words_node(e, headline, fn() { ended_title }) |> ignore
    // why, as the core says it (and what to turn on where, macOS's grants)
    let whys = fn() {
      let said = headline()
      let st = s.state_now()
      let ws : Array[String] = []
      for w in [s.message().unwrap_or(""), text(field(st, "access"), "message")] {
        if w != "" && w != said && !ws.contains(w) {
          ws.push(w)
        }
      }
      ws
    }
    e.each(at_once=true, whys, fn(w) { w }, fn(r, w) { @sf.words_node(r, fn() { w.get() }, fn() { ended_why }) |> ignore })
    // denied for a grant the station lacks (macOS's): its station's page where it is asked for (设置's 权限), a tap
    // away rather than looked for
    let keys = fn() {
      let phase = s.phase_now()
      let access = field(s.state, "access")
      let os = screen_os(s.src, s.station).to_lower()
      let granting = !os.has_prefix("linux") &&
        phase == "denied" &&
        (field(access, "capture") == Some(Json::boolean(false)) || field(access, "control") == Some(Json::boolean(false)))
      let linux_setup = os.has_prefix("linux") && text(access, "help") == "linux-desktop"
      let ks : Array[String] = []
      if phase == "ended" || phase == "denied" || phase == "failed" {
        ks.push("again")
        if granting {
          ks.push("grants")
        }
        if linux_setup {
          ks.push("linux")
        }
      }
      ks
    }
    e.show(at_once=true, fn() { !keys().is_empty() }, fn(row) {
      @sf.style_node(row, fn() { ended_keys }, in_row=true)
      row.wraps(Is(Some(@ui.Space::S2.px()))) |> ignore
      row.each(at_once=true, keys, fn(k) { k }, fn(slot, k) {
        match k.untracked() {
          "again" => again_key_node(slot, @sf.t("web-pages.screen.again"), fn() { s.open(s.src) })
          "grants" =>
            again_key_node(slot, @sf.t("web-pages.screen.toGrants"), fn() {
              @settings.station_parts[s.station] = "settings"
              open_page(Setting(@settings.Route::Station(s.station)))
            })
          _ =>
            again_key_node(slot, @sf.t("web-pages.screen.linuxSetup"), fn() {
              @ui.open_url("https://github.com/AFK-surf/monoid/blob/main/docs/linux-desktop-setup.md") |> ignore
            })
        }
      })
    })
  })
  |> ignore
}

///|
/// A capsule under what happened (重新打开, 前往权限设置) in `parent`, light on the screen's dark: the solid one in the
/// dark theme, the soft one in the light; `press` as it is pressed.
fn again_key_node(parent : @view.View, words : String, press : () -> Unit) -> Unit {
  @headless.button(parent, fn() { words }, fn(_) { press() }, fn(b, _) {
    let dark = fn() { @ui.tree_theme().dark }
    @sf.style_node(b, fn() { if dark() { again_solid } else { again_soft } }, in_row=true)
    @sf.hover_ground_node(b)
    @sf.words_node(b, fn() { words }, fn() { if dark() { again_solid_words } else { again_soft_words } }) |> ignore
  })
  |> ignore
}

///|
/// What is over the frame's foot in `st` (a layer over the stage, taking presses where it draws something alone): the
/// files sent to the machine (but where they are beside the device: by it), filling a login, a passkey's sign-in, why
/// 控制 does not drive it; `pair`: the mouse's buttons in the foot's corner, as far in as they float, what else is there
/// before them.
fn screen_stage_foot(st : @view.View, pg : ScreenPage, pair : () -> Bool) -> Unit {
  let s = pg.s
  let u = pg.u
  st.reacts(fn() { s.taking_over_now() }, fn(on) {
    if !on {
      u.held_hint.set(false)
    }
  })
  st.pick(at_once=true, pair, fn(f, paired) {
    f.over(Is(true)) |> ignore
    let notes = fn(n : @view.View) {
      n.box(fn(c) {
        @sf.style_node(c, fn() { stage_foot_column })
        // (beside the device they are at the foot of what is done with it: nothing over the app being debugged)
        c.show(at_once=true, fn() { !(u.logs.beside_now() && u.logs.shown.get()) }, fn(d) {
          u.drops_card = Some(d)
          drops_node(d, s)
        })
        login_fill_node(c, s)
        passkey_sign_node(c, s)
        c.pick(at_once=true, fn() {
          s.said.get() |> ignore
          s.pad_set.get() |> ignore
          let hinted = u.held_hint.get()
          match s.undriven() {
            Some(why) => Some(why)
            None =>
              if hinted && !s.driving() && s.can_take_over() {
                let who = strings(s.state, "controllers").join(@sf.t("web-main.list.separator"))
                if who != "" {
                  Some(@sf.t("web-pages.screen.heldBy", args=[("who", who)]))
                } else {
                  None
                }
              } else {
                None
              }
          }
        }, fn(w, why) {
          guard why is Some(why) else { return }
          w.box(fn(b) {
            @sf.style_node(b, fn() { undriven_box }, in_row=true)
            floats_node(b)
            @sf.first_line_node(b, Meta, fn(l) {
              @sf.icon_node(l, "info", undriven_icon, By(fn() { @ui.tree_theme().color(Muted) })) |> ignore
            })
            |> ignore
            @sf.words_node(b, fn() { why }, fn() { undriven_words }) |> ignore
          })
          |> ignore
        })
      })
      |> ignore
    }
    if paired {
      // (the mouse's buttons in the foot's corner, as far in as they float, what else is there before them)
      f.box(fn(row) {
        @sf.style_node(row, fn() { screen_corner_end(stage_foot_paired) })
        row|> ignore
        row.box(fn(before) {
          @sf.style_node(before, fn() { stage_foot_before }, in_row=true)
          before|> ignore
          notes(before)
        })
        |> ignore
        mouse_float_node(row, pg)
      })
      |> ignore
    } else {
      f.box(fn(c) {
        @sf.style_node(c, fn() { stage_foot })
        c|> ignore
        notes(c)
      })
      |> ignore
    }
  })
}

///|
/// The files sent to the machine in `d`, one row each, until let go of: how far each has got, or where it is now, or
/// why it failed (as they are told: ScreenSess's `drops_told`, each its own signals).
fn drops_node(d : @view.View, s : ScreenSess) -> Unit {
  d.show(at_once=true, fn() {
    s.drops_told.get() |> ignore
    !s.drops.is_empty()
  }, fn(card) {
    // a row's round key (34) at its top end, the first's in the panel's corner concentric with it (drop_row_box)
    @sf.style_node(card, fn() { drops_box })
    floats_node(card)
    card.each(
      at_once=true,
      fn() {
        s.drops_told.get() |> ignore
        s.drops.copy()
      },
      fn(x) { x.serial },
      fn(r, item) { drop_row_node(r, s, item.untracked()) },
    )
  })
}

///|
/// One file's row in `r` (drops_node's): its mark by its first line, its name and its keys on that line; where it is,
/// what is done with it there, how far it has got or why it failed under them.
fn drop_row_node(r : @view.View, s : ScreenSess, d : ScreenDropItem) -> Unit {
  r.box(fn(row) {
    @sf.style_node(row, fn() { drop_row_box }, in_row=true)
    let state = fn() { d.state.get() }
    // (by its first line, which its keys make as high as they are: across their middle)
    row.box(fn(l) {
      @sf.style_node(l, fn() { drop_icon_box }, in_row=true)
      l.lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
      @sf.icon_node(
        l,
        "upload",
        drop_icon,
        By(fn() {
          @ui.tree_theme().color(
            match state() {
              "done" => Accent
              "failed" => Danger
              _ => Muted
            },
          )
        }),
        name_now=fn() {
          match state() {
            "done" => "check-circle"
            "failed" => "info"
            _ => "upload"
          }
        },
      )
      |> ignore
    })
    |> ignore
    @sf.row_lines_node(
      row,
      fn(first) {
        first.box(fn(w) {
          @sf.style_node(w, fn() { drop_words }, in_row=true)
          @sf.words_node(w, fn() { d.name.get() }, fn() { drop_name }) |> ignore
        })
        |> ignore
        first.show(at_once=true, fn() { state() == "failed" }, fn(k) {
          screen_row_key_node(k, "retry", @sf.t("android-misc.drive.retry"), fn() { s.retry(d) })
        })
        screen_row_key_node(
          first,
          "close",
          @sf.t("common.close"),
          fn() { s.dismiss(d) },
          label_now=fn() { @sf.t(if state() == "done" || state() == "failed" { "common.close" } else { "common.cancel" }) },
        )
      },
      fn(under) {
        under.pick(at_once=true, fn() {
          let st = state()
          if st == "done" && d.install {
            "installed"
          } else {
            st
          }
        }, fn(u, st) {
          match st {
            "installed" =>
              @sf.words_node(u, fn() { @sf.t("web-pages.screen.debug.installed", args=[("name", d.installed)]) }, fn() {
                drop_path_words
              })
              |> ignore
            "installing" =>
              @sf.words_node(u, fn() { @sf.t("web-pages.screen.debug.installGoing") }, fn() { drop_going_words }) |> ignore
            "done" => {
              @sf.words_node(u, fn() { d.path() }, fn() { drop_path_words }) |> ignore
              // what is done with it there goes through the view: while driving it
              u.show(at_once=true, fn() { s.driving_now() }, fn(b) {
                @sf.style_node(b, fn() { drop_buttons }, in_row=true)
                b.show(at_once=true, fn() { s.pastes() }, fn(k) {
                  soft_button_node(k, fn() { @sf.t("android-misc.screen.pastePath") }, fn() {
                    s.paste(s.src, d.path(), screen_act(@sf.t("android-misc.screen.pasteWhat")))
                  })
                })
                if d.reveal {
                  soft_button_node(b, fn() { @sf.t("android-misc.screen.reveal") }, fn() {
                    s.reveal(s.src, d.path(), screen_act(@sf.t("android-misc.screen.revealWhat")))
                  })
                }
              })
            }
            "failed" =>
              @sf.words_node(u, fn() { @sf.t("android-misc.drive.upload.failed", args=[("error", d.error)]) }, fn() {
                drop_failed_words
              })
              |> ignore
            _ => {
              let size = d.bytes.length()
              // (its size known once it goes, as Android's provider says it then)
              @sf.words_node(
                u,
                fn() {
                  if state() == "waiting" {
                    @sf.t("android-misc.screen.sendWaiting")
                  } else {
                    @sf.t("android-misc.drive.upload.going", args=[
                      ("sent", @sf.file_size(d.sent.get().to_double())),
                      ("size", @sf.file_size(size.to_double())),
                    ])
                  }
                },
                fn() { drop_going_words },
              )
              |> ignore
              u.box(fn(place) {
                @sf.style_node(place, fn() { drop_track_place })
                place.box(fn(track) {
                  @sf.style_node(track, fn() { drop_track }, in_row=true)
                  track.box(fn(fill) {
                    @sf.style_node(fill, fn() { drop_track_fill }, in_row=true)
                    fill.grow(By(fn() { if size > 0 { clamp01(d.sent.get().to_double() / size.to_double()) } else { 0.0 } })) |> ignore
                  })
                  |> ignore
                  track.box(fn(rest) {
                    rest.grow(By(fn() { if size > 0 { 1.0 - clamp01(d.sent.get().to_double() / size.to_double()) } else { 1.0 } })) |> ignore
                  })
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            }
          }
        })
      },
    )
  })
  |> ignore
}

///|
/// A button that is not the main one in `parent` (soft_button_box's: the chip under the ink's words), named `label`;
/// pressed, `press`.
fn soft_button_node(parent : @view.View, label : () -> String, press : () -> Unit) -> Unit {
  @headless.button(parent, label, fn(_) { press() }, fn(b, _) {
    @sf.style_node(b, fn() { soft_button_box }, in_row=true)
    @sf.hover_ground_node(b)
    @sf.words_node(b, label, fn() { soft_button_words }) |> ignore
  })
  |> ignore
}

///|
/// A small round key at a row's end in `parent` (34, its icon 16 muted: DriveScreen's), named `label` (as it changes:
/// `label_now`), `press` as it is pressed.
fn screen_row_key_node(parent : @view.View, icon : String, label : String, press : () -> Unit, label_now? : () -> String) -> Unit {
  @sf.round_key_node(
    parent,
    icon,
    label_now.unwrap_or(fn() { label }),
    press,
    side=drop_key_side,
    icon_size=drop_key_icon,
    ink=fn() { @ui.tree_theme().color(Muted) },
  )
}

// ── the gestures ─────────────────────────────────────────────────────────

///|
/// Two fingers on the stage: spreading (1, zooming here), or moving together (2), once they have gone past the slop.
priv struct TwoFingers {
  mut kind : Int
  c0x : Double
  c0y : Double
  s0 : Double
  mut fx : Double
  mut fy : Double
  mut spread_was : Double
}

///|
fn two_of(ax : Double, ay : Double, bx : Double, by : Double) -> (Double, Double, Double) {
  let cx = (ax + bx) / 2.0
  let cy = (ay + by) / 2.0
  let d = fn(x : Double, y : Double) { ((x - cx) * (x - cx) + (y - cy) * (y - cy)).sqrt() }
  (cx, cy, (d(ax, ay) + d(bx, by)) / 2.0)
}

///|
fn TwoFingers::new(ax : Double, ay : Double, bx : Double, by : Double) -> TwoFingers {
  let (cx, cy, s) = two_of(ax, ay, bx, by)
  { kind: 0, c0x: cx, c0y: cy, s0: s, fx: cx, fy: cy, spread_was: s }
}

///|
/// Where they are now (their middle, how far apart): what they are doing told once they have moved enough.
fn TwoFingers::at(
  self : TwoFingers,
  ax : Double,
  ay : Double,
  bx : Double,
  by : Double,
) -> (Double, Double, Double) {
  let (cx, cy, s) = two_of(ax, ay, bx, by)
  if self.kind == 0 {
    let spreading = (s - self.s0).abs()
    let moving = ((cx - self.c0x) * (cx - self.c0x) + (cy - self.c0y) * (cy - self.c0y)).sqrt()
    if spreading > screen_slop || moving > screen_slop {
      self.kind = if spreading > moving { 1 } else { 2 }
    }
  }
  (cx, cy, s)
}

///|
/// Gone on to (cx, cy), s: once told what they are doing (until then measured from where they began, none of the way
/// lost).
fn TwoFingers::went(self : TwoFingers, cx : Double, cy : Double, s : Double) -> Unit {
  if self.kind != 0 {
    self.fx = cx
    self.fy = cy
    self.spread_was = s
  }
}

///|
/// A press on the stage, followed event by event.
priv struct Gesture {
  /// the fingers down on the stage, where each is (the stage's own terms), by its number
  fingers : Map[Int, (Double, Double)]
  /// this press drives it as a trackpad (else directly), as it went down
  mut pad : Bool
  mut drives : Bool
  /// trackpad: 0 not yet told, 1 moving the pointer, 2 dragging (the button down), 3 two fingers, 4 nothing more;
  /// directly: 0 not yet told, 1 a drag sent, 2 panning here, 3 two fingers, 4 nothing more (a right click sent, or
  /// ignored)
  mut mode : Int
  mut sx : Double
  mut sy : Double
  mut lx : Double
  mut ly : Double
  /// the moment of the last event of the press (how fast the trackpad's finger goes)
  mut last_at : Double
  /// down again soon after a tap, near it: a move (or holding still) drags from where it points
  mut again : Bool
  mut two : TwoFingers?
  mut two_moved : Bool
  /// the two fingers have been down a hold's length (no right click then)
  mut two_held : Bool
  /// a tap's end on the trackpad, and where: the wait after it its own
  mut tap_open : Bool
  mut tx : Double
  mut ty : Double
  /// directly, a drag: where its last move went on the picture
  mut moved_to : (Double, Double)?
  /// the modifiers the keys row held, taken as its first button went down: their keys down until its last is up
  mut mods : Int
  mut mods_down : Bool
  /// the waits under way (a press held, two fingers held, a double tap's), each called off as what it waits for ends
  mut hold_off : () -> Unit
  mut two_off : () -> Unit
  mut tap_off : () -> Unit
}

///|
fn gesture_new() -> Gesture {
  {
    fingers: {},
    pad: false,
    drives: false,
    mode: 0,
    sx: 0.0,
    sy: 0.0,
    lx: 0.0,
    ly: 0.0,
    last_at: 0.0,
    again: false,
    two: None,
    two_moved: false,
    two_held: false,
    tap_open: false,
    tx: 0.0,
    ty: 0.0,
    moved_to: None,
    mods: 0,
    mods_down: false,
    hold_off: fn() {  },
    two_off: fn() {  },
    tap_off: fn() {  },
  }
}

///|
/// The press's first button going down: the modifiers the keys row holds taken, their keys sent down before it.
fn Gesture::mods_take(self : Gesture, held : HeldKeys, send : (Json) -> Unit) -> Unit {
  if self.mods_down {
    return
  }
  self.mods = held.take()
  self.mods_down = true
  mods_round(send, self.mods, "down")
}

///|
/// The press's last button up: the keys taken for it sent up after it.
fn Gesture::mods_give(self : Gesture, send : (Json) -> Unit) -> Unit {
  if !self.mods_down {
    return
  }
  self.mods_down = false
  mods_round(send, self.mods, "up")
}

///|
/// What a hand does on `stage`, each at its moment. A mouse is itself: the screen's pointer where it is (screen_mouse_at).
/// A finger: driving it as a trackpad, one finger moves the pointer, a tap clicks where it points, tapped again and moved
/// (or held still) it drags, two fingers tapped click the right button, two moving together scroll. Driving it directly:
/// a tap is a click where it is (down and up, the primary button), a press held a right click, a drag a drag (down,
/// moves, up), two fingers moving together a wheel while the frame is fitted, and zoomed in they pan it here instead
/// (pengxiao, 2026-11-12: 「放大时双指平移画面」). Either way two fingers spreading zoom the frame here (it is not sent);
/// only looking, moving together pan it when zoomed, one finger too, and a double tap zooms in where it is (or back to
/// fitted). A modifier held on the keys row goes round what a press clicks or drags, its key down before the first
/// button and up after the last.
fn screen_stage_gestures(stage : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  stage
  .on_drag(fingers=2, whole=true, fn(d) {
    if @sf.pointer_rests() {
      screen_mouse_drag(stage, pg, d)
    } else {
      screen_finger(stage, s, u, d)
    }
  })
  // a mouse's secondary button: a right click where it is
      .on_menu(fn(m) {
    if @sf.pointer_rests() {
      screen_mouse_menu(pg, m)
    }
  })
  // the wheel over it is its own (a mouse's, sent to the screen)
  .on_wheel(fn(w) {
    if @sf.pointer_rests() {
      screen_mouse_wheel(pg, w)
    }
  })
  // over the picture, nothing held: the screen's pointer goes where it is
  .on_pointer_moved(fn() {
    if @sf.pointer_rests() {
      screen_mouse_moved(stage, pg)
    }
  })
  // this device's mouse over the picture driving it: in the screen's pointer's shape; blocked while another operates it
  .cursor(By(fn() {
    if u.mouse.over.get() {
      s.cursor_said.get() |> ignore
      s.said.get() |> ignore
      Some(cursor_of_shape(text(field(s.state, "cursor"), "shape")))
    } else if !s.driving_now() && s.taking_over_now() {
      Some(@ui.Cursor::NotAllowed)
    } else {
      None
    }
  }))
  |> ignore
  // (the pointer gone off the stage: this device's mouse over the picture no more)
  stage.reacts(fn() { stage.pointer_within() }, fn(within) {
    if !within && !u.mouse.down {
      u.mouse.over.set(false)
    }
  })
}

///|
/// A finger's event `d` on the stage (screen_stage_gestures').
fn screen_finger(stage : @view.View, s : ScreenSess, u : ScreenUi, d : @view.Drag) -> Unit {
  let g = u.gesture
  let send = fn(j : Json) { s.input(s.src, j) }
  let at = d.at
  let x = d.x
  let y = d.y
  let shown = fn() { u.shown_at(at) }
  let fitted = fn() { u.fit().w > 0.0 }
  u.mouse.over.set(false)
  match d.kind {
    Down =>
      if g.fingers.is_empty() {
        // the press begins
        g.fingers[d.finger] = (x, y)
        g.drives = s.driving()
        g.pad = g.drives && s.pad(s.src)
        if g.pad && !u.pad.placed {
          u.pad.start_at(s.cursor())
        }
        g.mode = 0
        g.sx = x
        g.sy = y
        g.lx = x
        g.ly = y
        g.last_at = at
        g.two = None
        g.two_moved = false
        g.two_held = false
        g.moved_to = None
        let near = ((g.sx - g.tx) * (g.sx - g.tx) + (g.sy - g.ty) * (g.sy - g.ty)).sqrt() < screen_slop * 4.0
        g.again = g.pad && g.tap_open && near
        // held still: the trackpad's button down where it points; directly, a right click where it is
        (g.hold_off)()
        g.hold_off = stage.at_moment(at + screen_hold_ms, fn() { screen_held(stage, s, u) })
      } else {
        // a second finger: what the first was doing ends where it is
        g.fingers[d.finger] = (x, y)
        (g.hold_off)()
        g.hold_off = fn() {  }
        if g.mode != 3 {
          if g.pad && g.mode == 2 {
            send(pointer_input("up", u.pad.at(), btn_primary))
          }
          if !g.pad && g.mode == 1 {
            match screen_frame_at(g.lx, g.ly, shown(), true) {
              Some(p) => {
                send(pointer_input("up", p, btn_primary))
                u.tapped_at = Some(p)
              }
              None => ()
            }
          }
          g.mods_give(send)
          g.mode = 3
          let (ax, ay) = g.fingers.get(0).unwrap_or((g.lx, g.ly))
          g.two = Some(TwoFingers::new(ax, ay, x, y))
          // the two fingers' tap is quick while they have been down less than a hold (from the second's coming)
          (g.two_off)()
          g.two_off = stage.at_moment(at + screen_hold_ms, fn() { g.two_held = true }, later=true)
        }
      }
    Moved => {
      g.fingers[d.finger] = (x, y)
      if g.mode == 3 {
        let ps = g.fingers.values().collect()
        if ps.length() >= 2 {
          match g.two {
            Some(t) => {
              let (cx, cy, sp) = t.at(ps[0].0, ps[0].1, ps[1].0, ps[1].1)
              if t.kind != 0 {
                g.two_moved = true
              }
              if t.kind == 1 {
                let k = if t.spread_was > 0.0 { sp / t.spread_was } else { 1.0 }
                if fitted() {
                  u.zoom.transform(cx, cy, k, cx - t.fx, cy - t.fy, at~)
                }
              } else if t.kind == 2 {
                if g.pad {
                  scroll_by(send, cx - t.fx, cy - t.fy, u.pad.at(), shown(), s.frame_size())
                } else if u.zoom.zoomed_at(at) {
                  if fitted() {
                    u.zoom.pan(cx - t.fx, cy - t.fy, at~)
                  }
                } else if g.drives {
                  match screen_frame_at(cx, cy, shown(), true) {
                    Some(p) => scroll_by(send, cx - t.fx, cy - t.fy, p, shown(), s.frame_size())
                    None => ()
                  }
                }
              }
              t.went(cx, cy, sp)
            }
            None => ()
          }
        }
      } else {
        screen_one_finger(stage, u, x, y, at, send)
      }
      g.lx = x
      g.ly = y
      g.last_at = at
    }
    Up | Off => {
      g.fingers.remove(d.finger)
      if !g.fingers.is_empty() {
        // one of two let go: the rest of the pinch from where the other is
        return
      }
      (g.hold_off)()
      g.hold_off = fn() {  }
      (g.two_off)()
      g.two_off = fn() {  }
      // let go (a move to where it was let go first, as the last of its way); called off: nothing it would have
      // come to clicked
      if d.kind is Up && g.mode != 3 && (x != g.lx || y != g.ly) {
        screen_one_finger(stage, u, x, y, at, send)
        g.lx = x
        g.ly = y
      }
      let called_off = d.kind is Off
      match g.mode {
        0 if !called_off =>
          if g.pad {
            g.mods_take(u.held, send)
            send(pointer_input("down", u.pad.at(), btn_primary))
            send(pointer_input("up", u.pad.at(), btn_primary))
            // a click felt, as the mouse's buttons are
            @ui.haptic(KeyboardTap)
            screen_tap_open(stage, g, at)
          } else if g.drives {
            match screen_frame_at(g.sx, g.sy, shown(), false) {
              Some(p) => {
                g.mods_take(u.held, send)
                send(pointer_input("down", p, btn_primary))
                send(pointer_input("up", p, btn_primary))
                u.tapped_at = Some(p)
                @ui.haptic(KeyboardTap)
              }
              None => ()
            }
          } else if fitted() {
            // only looking: tapped twice near the same place, zoomed in there (or back to fitted)
            let near = ((g.sx - g.tx) * (g.sx - g.tx) + (g.sy - g.ty) * (g.sy - g.ty)).sqrt() < screen_slop * 4.0
            if g.tap_open && near {
              u.zoom.double_tap(g.sx, g.sy, at~)
              (g.tap_off)()
              g.tap_open = false
            } else {
              screen_tap_open(stage, g, at)
              if screen_frame_at(g.sx, g.sy, shown(), false) is Some(_) {
                screen_held_by_hint(s, u)
              }
            }
          }
        1 if !g.pad =>
          match screen_frame_at(g.lx, g.ly, shown(), true) {
            Some(p) => {
              send(pointer_input("up", p, btn_primary))
              u.tapped_at = Some(p)
            }
            None => ()
          }
        2 if g.pad => send(pointer_input("up", u.pad.at(), btn_primary))
        3 if g.pad && !g.two_moved && !g.two_held && !called_off => {
          g.mods_take(u.held, send)
          send(pointer_input("down", u.pad.at(), btn_secondary))
          send(pointer_input("up", u.pad.at(), btn_secondary))
          @ui.haptic(ContextClick)
        }
        _ => ()
      }
      g.mods_give(send)
      g.mode = 0
    }
  }
}

///|
/// A tap's end on the stage at `at` (where it went down): the double tap's wait after it its own, closing after its
/// time (what is shown does not wait for it).
fn screen_tap_open(stage : @view.View, g : Gesture, at : Double) -> Unit {
  g.tap_open = true
  g.tx = g.sx
  g.ty = g.sy
  (g.tap_off)()
  g.tap_off = stage.at_moment(at + screen_double_tap_ms, fn() { g.tap_open = false }, later=true)
}

///|
/// A finger held still on the stage a hold's length, the press's first: the trackpad's button down where it points;
/// directly, a right click where it is; only looking, nothing more of the press.
fn screen_held(stage : @view.View, s : ScreenSess, u : ScreenUi) -> Unit {
  let g = u.gesture
  g.hold_off = fn() {  }
  guard g.mode == 0 && g.fingers.length() == 1 else { return }
  let send = fn(j : Json) { s.input(s.src, j) }
  if g.pad {
    g.mods_take(u.held, send)
    send(pointer_input("down", u.pad.at(), btn_primary))
    @ui.haptic(LongPress)
    g.mode = 2
  } else {
    if g.drives {
      match screen_frame_at(g.sx, g.sy, u.shown_at(stage.logic_at()), false) {
        Some(p) => {
          g.mods_take(u.held, send)
          send(pointer_input("down", p, btn_secondary))
          send(pointer_input("up", p, btn_secondary))
          g.mods_give(send)
          u.tapped_at = Some(p)
          @ui.haptic(LongPress)
        }
        None => ()
      }
    }
    g.mode = 4
  }
}

///|
/// One finger alone on the stage gone to (`x`, `y`) at `at`: past the slop, what it is told to be (a move of the
/// trackpad's pointer, a drag, a pan here); then each move as that does it.
fn screen_one_finger(
  stage : @view.View,
  u : ScreenUi,
  x : Double,
  y : Double,
  at : Double,
  send : (Json) -> Unit,
) -> Unit {
  let g = u.gesture
  let shown = u.shown_at(at)
  match g.mode {
    0 => {
      let moved = ((x - g.sx) * (x - g.sx) + (y - g.sy) * (y - g.sy)).sqrt()
      if moved > screen_slop {
        (g.hold_off)()
        g.hold_off = fn() {  }
        if g.pad {
          if g.again {
            g.mods_take(u.held, send)
            send(pointer_input("down", u.pad.at(), btn_primary))
            g.mode = 2
          } else {
            g.mode = 1
          }
        } else if g.drives {
          match screen_frame_at(g.sx, g.sy, shown, false) {
            Some(p) => {
              g.mods_take(u.held, send)
              send(pointer_input("down", p, btn_primary))
              g.mode = 1
              match screen_frame_at(x, y, shown, true) {
                Some(p2) => {
                  g.moved_to = Some(p2)
                  send(pointer_input("move", p2, btn_primary))
                }
                None => ()
              }
            }
            None => g.mode = 4
          }
        } else if u.zoom.zoomed_at(at) {
          g.mode = 2
        } else {
          g.mode = 4
        }
      }
    }
    1 | 2 if g.pad => {
      let dx = x - g.lx
      let dy = y - g.ly
      if shown.w > 0.0 && (dx != 0.0 || dy != 0.0) {
        let dt = dmax(1.0, at - g.last_at)
        let gain = pad_gain((dx * dx + dy * dy).sqrt() / dt)
        u.pad.by(dx * gain / shown.w, dy * gain / shown.h)
        send(pointer_input("move", u.pad.at(), if g.mode == 2 { btn_primary } else { 0 }))
        if u.zoom.zoomed_at(at) {
          u.zoom.keep(u.pad.at(), screen_keep_margin, when=at)
        }
      }
    }
    // (where it is on the picture, once each: held still, no move again)
    1 =>
      match screen_frame_at(x, y, shown, true) {
        Some(p) if g.moved_to != Some(p) => {
          g.moved_to = Some(p)
          send(pointer_input("move", p, btn_primary))
        }
        _ => ()
      }
    2 => if u.fit().w > 0.0 { u.zoom.pan(x - g.lx, y - g.ly, at~) }
    _ => ()
  }
  ignore(stage)
}

///|
/// Two fingers moving together over (dx, dy) (stage px) as a wheel at `at` (0..1): the page under them moves with them,
/// the fingers' way in the frame's own pixels.
fn scroll_by(
  send : (Json) -> Unit,
  dx : Double,
  dy : Double,
  at : (Double, Double),
  shown : SRect,
  frame : (Int, Int)?,
) -> Unit {
  guard frame is Some((fw, _)) else { return }
  if shown.w <= 0.0 || (dx == 0.0 && dy == 0.0) {
    return
  }
  let k = fw.to_double() / shown.w
  send(wheel_input(at, -dx * k, -dy * k))
}

// ── a mouse ──────────────────────────────────────────────────────────────

///|
/// The mouse on the stage, as it was last seen: its primary button down there, and whether that press went to the
/// screen (it began on the picture, driving it) with the modifiers held as it did; where the screen's pointer was last
/// sent; whether the mouse is over the picture driving it (the screen's pointer then, the station's not drawn).
priv struct MouseDrive {
  mut down : Bool
  mut sent_down : Bool
  mut mods : Int
  mut at : (Double, Double)?
  over : @signals.Signal[Bool]
}

///|
/// How tall the caret this device's input method is told of on a screen, in points.
let screen_ime_h : Double = 20.0

///|
fn mouse_drive_new() -> MouseDrive {
  { down: false, sent_down: false, mods: 0, at: None, over: @signals.signal(false, same=fn(a, b) { a == b }) }
}

///|
/// The mouse's pointer sent to `at` on the screen (`buttons` held), where it was not already.
fn MouseDrive::move_to(self : MouseDrive, s : ScreenSess, at : (Double, Double), buttons : Int) -> Unit {
  if self.at != Some(at) {
    self.at = Some(at)
    s.input(s.src, pointer_input("move", at, buttons))
  }
}

///|
/// Shows a notice over the stage's foot when the person presses on the picture while another (e.g. an agent) operates
/// it, pointing them to 接管; cleared immediately once they take control or the controller leaves.
fn screen_held_by_hint(s : ScreenSess, u : ScreenUi) -> Unit {
  if !s.driving() && s.can_take_over() && !strings(s.state, "controllers").is_empty() {
    u.held_hint.set(true)
  }
}

///|
/// The mouse's primary button on the stage (`d`, a drag of it): down where it is (a press on the stage, a picture's
/// letterbox too, gives it the keyboard, this device's input method placed by it), moved held (past the picture's
/// edge, at its edge) and up, with ⇧ ⌃ ⌥ ⌘ held as it goes down, their keys round it. Only while driving it.
fn screen_mouse_drag(stage : @view.View, pg : ScreenPage, d : @view.Drag) -> Unit {
  let s = pg.s
  let u = pg.u
  let m = u.mouse
  let send = fn(j : Json) { s.input(s.src, j) }
  guard d.finger == 0 else { return }
  let shown = u.shown_at(d.at)
  match d.kind {
    Down => {
      m.down = true
      m.sent_down = false
      if s.driving() {
        match u.catcher {
          Some(k) => {
            @ui.key_catcher_focus_set(k, true)
            // (where typing is likeliest to go: where it pressed, the screen's own caret not being known here)
            let (sx, sy, _, _) = stage.rect()
            @ui.key_catcher_place(k, sx + d.x, sy + d.y, screen_ime_h)
          }
          None => ()
        }
        match screen_frame_at(d.x, d.y, shown, false) {
          Some(at) => {
            m.mods = mods_of_held(@ui.mods_held())
            mods_round(send, m.mods, "down")
            m.at = Some(at)
            send(pointer_input("down", at, btn_primary))
            m.sent_down = true
            m.over.set(true)
          }
          None => ()
        }
      } else if screen_frame_at(d.x, d.y, shown, false) is Some(_) {
        screen_held_by_hint(s, u)
      }
    }
    Moved =>
      if m.sent_down {
        match screen_frame_at(d.x, d.y, shown, true) {
          Some(at) => m.move_to(s, at, btn_primary)
          None => ()
        }
      }
    Up | Off => {
      m.down = false
      if m.sent_down {
        m.sent_down = false
        let at = match screen_frame_at(d.x, d.y, shown, true) {
          Some(at) => at
          None => m.at.unwrap_or((0.5, 0.5))
        }
        m.at = Some(at)
        send(pointer_input("up", at, 0))
        mods_round(send, m.mods, "up")
      }
    }
  }
}

///|
/// The mouse moved over the stage (nothing held): the screen's pointer where it is over the picture, driving it; this
/// device's mouse the screen's pointer there (the station's not drawn).
fn screen_mouse_moved(stage : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  let m = u.mouse
  let over = match stage.pointer_here() {
    Some((x, y)) => screen_frame_at(x, y, u.shown_at(stage.logic_at()), false)
    None => None
  }
  let driving = s.driving()
  m.over.set(driving && (over is Some(_) || m.sent_down))
  match over {
    Some(at) if driving && !m.down => m.move_to(s, at, 0)
    _ => ()
  }
}

///|
/// The mouse's secondary button on the stage: a right click where it is (Ctrl-click is the system's own right click: no
/// ⌃ round it), while driving it; it gives it the keyboard as a press does.
fn screen_mouse_menu(pg : ScreenPage, menu : @view.Menu) -> Unit {
  let s = pg.s
  let u = pg.u
  if !s.driving() {
    if screen_frame_at(menu.x, menu.y, u.shown_at(menu.at), false) is Some(_) {
      screen_held_by_hint(s, u)
    }
    return
  }
  match u.catcher {
    Some(k) => @ui.key_catcher_focus_set(k, true)
    None => ()
  }
  let send = fn(j : Json) { s.input(s.src, j) }
  match screen_frame_at(menu.x, menu.y, u.shown_at(menu.at), false) {
    Some(at) => {
      let mods = mods_of_held(@ui.mods_held()) & mod_ctrl.lnot()
      mods_round(send, mods, "down")
      u.mouse.at = Some(at)
      send(pointer_input("down", at, btn_secondary))
      send(pointer_input("up", at, 0))
      mods_round(send, mods, "up")
    }
    None => ()
  }
}

///|
/// The wheel over the stage, where the mouse is, the keys held round it (⌃ or ⌘ to zoom, ⇧ sideways), while driving it;
/// a trackpad's pinch zooms nothing there. The keys are the keyboard's, not the wheel's: a host may say a pinch is a
/// wheel with ⌃ and not mark it one.
fn screen_mouse_wheel(pg : ScreenPage, w : @view.Wheel) -> Unit {
  let s = pg.s
  let u = pg.u
  let m = u.mouse
  guard s.driving() && (w.dx != 0.0 || w.dy != 0.0) && (w.mods & @ui.wheel_mod_pinch) == 0 else { return }
  let send = fn(j : Json) { s.input(s.src, j) }
  match screen_frame_at(w.x, w.y, u.shown_at(w.at), false) {
    Some(at) => {
      // (those a press still held went down with already go up with it)
      let mods = mods_of_held(@ui.mods_held()) & (if m.sent_down { m.mods } else { 0 }).lnot()
      mods_round(send, mods, "down")
      send(wheel_input(at, w.dx, w.dy))
      mods_round(send, mods, "up")
    }
    None => ()
  }
}
