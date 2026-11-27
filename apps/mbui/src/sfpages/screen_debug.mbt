// An app being debugged on an iOS Simulator: what its page is about is the device
// and the app, not the link, so these are beside the picture and not in 控制中心: its device's buttons (Simulator.app's
// shortcuts, as the station takes them: sim-input.ts), 截图, 重启 App (the apps installed on it), 日志 (the apps' log, asked
// again every moment while it shows, the newest first) and 设备 (how it is set). What is done with it comes round what a
// person debugging an app does over and over: put it on, look at it, read what it says, start it again. A wide page has
// what the device has itself by the device (its buttons, its hinge, and its picture or a movie kept) and App, 日志 and 设备
// beside that, what the last of them came to at their foot; a narrow one has the buttons under the picture, in reach,
// and those in a panel. A device has what it says it has: an Android one (`android:`) has no panel, and a back button.

///|
/// How often an open 日志 asks for what came since.
let debug_logs_ms : Double = 1500.0

///|
/// The newest lines an open 日志 keeps and shows.
let debug_logs_kept : Int = 200

///|
let debug_panel_w : Double = 420.0

///|
/// How wide a wide page's log is beside the device.
let debug_pane_w : Double = 320.0

///|
/// How wide what the device has itself is, by a device taller than wide: a column of round buttons.
let debug_rail_w : Double = 48.0

///|
/// How tall it is as a row under a device wider than tall: a row of round buttons.
let debug_row_h : Double = 56.0

///|
/// What is between the device's body and the column by it.
let debug_rail_gap : Double = 8.0


///|
/// 日志's place among App, 日志 and 设备.
let debug_tab_logs : Int = 1

///|
/// 设备's place among them.
let debug_tab_device : Int = 2

///|
/// An iPhone Duo's picture narrower than this (width by height) is its cover's, 1398×2034, not its inner panel's, 2007×2853.
let duo_cover_shape : Double = 0.695

///|
/// How thick the device's body shows round its picture (`B8`, its border).
let sim_bezel : Double = 8.0

///|
/// How many straight pieces make a corner's curve where the picture's corner is cut off, under the body's own edge.
let corner_cut_steps : Int = 24

///|
/// How far past the picture's edges a cut goes.
let corner_cut_over : Double = 2.0

///|
let device_body_ink : Int64 = 0x1C1C1EFFL

///|
/// What the page shows in the picture's place in `fill`: a simulator's with what debugs an app beside it (a wide page:
/// what the device has itself by the device, App, 日志 and 设备 beside that) or under it (a narrow one: its buttons
/// under the picture, in reach, and those in a panel), any other's the picture alone.
fn screen_content_node(fill : @view.View, pg : ScreenPage, pair? : () -> Bool = fn() { false }) -> Unit {
  let s = pg.s
  let u = pg.u
  let d = u.logs
  fill.pick(at_once=true, fn() {
    s.said.get() |> ignore
    s.simulator()
  }, fn(c, simulator) {
    c.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
    if !simulator {
      d.by_device.set(false)
      d.beside.set(false)
      screen_stage_node(c, pg, pair~)
      return
    }
    // (beside a chat, in its tab, as narrow whatever the window; in 远程's workbench, by its pane's width)
    @sf.by_look_node(
      c,
      fn() { pg.sim_width(c) },
      fn(w) {
        // Proposal C on mouse/keyboard wide panes (远程's workbench & standalone Viewer): pure full-bleed canvas with
        // all device & quick-debug tools in the unified top bar and the right App / 日志 / 设备 drawer collapsed by
        // default; touch tablets (Sideways/Native, no top bar) keep device controls beside/under the device.
        let top_bar = !@sf.soft_keyboard() && !(!pg.in_tab && @sf.native_on())
        d.by_device.set(!top_bar)
        if top_bar {
          debug_said_by(w, pg)
        }
        if !d.shown_set {
          d.shown.set(!top_bar)
        }
        w.reacts(fn() { flag(s.state_now(), "debug") }, fn(on) { d.beside.set(on) })
        w.row(Is(true)) |> ignore
        w.box(fn(body) {
          @sf.style_node(body, fn() { if top_bar { debug_stage_wide_body } else { debug_stage_body } }, in_row=true)
          body.basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
          screen_stage_node(body, pg)
        })
        |> ignore
        w.show(at_once=true, fn() { d.beside_now() && d.shown.get() }, fn(k) { debug_pane_node(k, pg) })
      },
      fn(n) {
        d.by_device.set(false)
        d.beside.set(false)
        n.box(fn(body) {
          @sf.style_node(body, fn() { debug_stage_body })
          body.basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
          screen_stage_node(body, pg)
        })
        |> ignore
        // (a row of its own: with the buttons there is no room for all of them on a narrow page)
        n.show(at_once=true, fn() { s.driving_now() && flag(s.state_now(), "poses") }, fn(bar) {
          @sf.style_node(bar, fn() { debug_tools_bar })
          debug_poses_node(bar, pg, icons=false)
        })
        n.box(fn(bar) {
          @sf.style_node(bar, fn() { debug_tools_bar })
          debug_tools_node(bar, pg)
        })
        |> ignore
      },
    )
  })
}

///|
/// The room the stage keeps for what the device has itself, out of what the picture is fitted into (the picture and it
/// then lie in the middle as one, not a pixel between them): by a device taller than wide, a column at its side; under
/// one wider than tall (an unfolded one, one turned), a row. None but on a wide page. Followed.
fn debug_room(u : ScreenUi, size : (Int, Int)?, cased : DeviceCase?) -> (Double, Double) {
  let reach = if cased is Some(_) { case_reach } else { 0.0 }
  match size {
    Some((w, h)) if u.logs.by_device.get() => if w > h { (0.0, debug_row_h + reach) } else { (debug_rail_w + debug_rail_gap + reach, 0.0) }
    _ => (0.0, 0.0)
  }
}

///|
/// What the device has itself in `f` (over the stage), where debug_room kept room for it by the picture: clear of the
/// body round the picture, and of where its buttons are pressed.
fn debug_by_device_node(f : @view.View, pg : ScreenPage, size : () -> (Int, Int)?) -> Unit {
  let s = pg.s
  let u = pg.u
  let column = fn() {
    match size() {
      Some((w, h)) if u.logs.by_device.get() => Some(w <= h)
      _ => None
    }
  }
  f.pick(at_once=true, column, fn(o, col) {
    o.over(Is(true)) |> ignore
    guard col is Some(column) else { return }
    o.box(fn(b) {
      let body = fn(r : SRect) {
        match device_case_now(b, s, size()) {
          Some(_) => (r.w * u.case_x + case_reach, r.h * u.case_y + case_reach)
          None => (sim_bezel, sim_bezel)
        }
      }
      b.over(Is(true)) |> ignore
      if column {
        b
        .width(Is(Some(debug_rail_w)))
        .offset(By(fn() {
          let r = u.picture_on(b)
          let (bw, _) = body(r)
          (r.x + r.w + bw + debug_rail_gap, r.y)
        }))
        |> ignore
      } else {
        @sf.style_node(b, fn() { debug_row_place })
        // (as tall as the room debug_room keeps for it: over the stage, a box of no height said would be the stage's)
        b.height(Is(Some(debug_row_h))).offset(By(fn() {
          let r = u.picture_on(b)
          let (_, bh) = body(r)
          (0.0, r.y + r.h + bh)
        }))
        |> ignore
      }
      debug_row_node(b, pg, column)
    })
    |> ignore
  })
}

///|
/// What the device has itself as round buttons in `parent`, their names when pressed or pointed at: a row under a
/// device wider than tall, a column by one taller than wide; what debugs an app (its picture, 录屏, what is done with
/// it put away or brought back) where it may be.
fn debug_row_node(parent : @view.View, pg : ScreenPage, column : Bool) -> Unit {
  let s = pg.s
  let u = pg.u
  let d = u.logs
  debug_said_by(parent, pg)
  parent.box(fn(bar) {
    @sf.style_node(bar, fn() { if column { debug_tools_column } else { debug_tools_bar } })
    bar.show(at_once=true, fn() { s.driving_now() }, fn(k) {
      k.row(Is(!column)).lines_up(Is(Some(Middle))).gap(Is(@ui.Space::S2.px())) |> ignore
      debug_device_keys_node(k, pg, beside=true)
      k.show(at_once=true, fn() { flag(s.state_now(), "poses") }, fn(p) { debug_poses_node(p, pg, icons=column) })
    })
    bar.show(at_once=true, fn() { flag(s.state_now(), "debug") }, fn(k) {
      k.row(Is(!column)).lines_up(Is(Some(Middle))).gap(Is(@ui.Space::S2.px())) |> ignore
      screen_round_node(k, pg, fn() { "camera" }, fn() { @sf.t("web-pages.screen.device.shot") }, fn(_) { debug_shot(s, d) }) |> ignore
      let going = fn() { debug_going(d) }
      screen_round_node(
        k,
        pg,
        fn() { if going() { "stop" } else { "play" } },
        fn() { @sf.t(if going() { "web-pages.screen.debug.recordStop" } else { "web-pages.screen.debug.recordStart" }) },
        fn(_) { debug_record_pressed(s, d, @signals.untracked(going)) },
        lit=going,
      )
      |> ignore
      // what is done with the device put away for it to have all the room, or brought back
      screen_round_node(
        k,
        pg,
        fn() { if d.shown.get() { "shrink" } else { "expand" } },
        fn() { @sf.t(if d.shown.get() { "web-pages.screen.debug.paneHide" } else { "web-pages.screen.debug.paneShow" }) },
        fn(_) {
          d.shown_set = true
          d.shown.set(!d.shown.untracked())
        },
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// The device's own buttons in `k` while it is driven (each Simulator.app's shortcut: device_combos; the case's own
/// where it has them), turning it, and its volume where nothing else has it: by the device (`beside`, where no case has
/// them), or under the picture of one without the panel its volume is in (an Android one's).
fn debug_device_keys_node(k : @view.View, pg : ScreenPage, beside~ : Bool) -> Unit {
  let s = pg.s
  k.each(at_once=true, fn() { device_combos(s, device_case_now(k, s, s.frame_size())) }, fn(c) { c.keys }, fn(slot, c) {
    screen_round_node(slot, pg, fn() { c.get().icon }, fn() { c.get().name }, fn(_) { debug_press(s, c.untracked()) }) |> ignore
  })
  let volume = fn() {
    if beside {
      device_case_now(k, s, s.frame_size()) is None
    } else {
      !flag(s.state_now(), "debug") && s.android()
    }
  }
  if beside {
    k.show(volume, fn(v) { debug_volume_node(v, pg) })
  }
  screen_round_node(k, pg, fn() { "screen-rotate" }, fn() { @sf.t("web-pages.screen.device.rotate") }, fn(_) {
    debug_device_input(s, "rotate")
  })
  |> ignore
  if !beside {
    k.show(volume, fn(v) { debug_volume_node(v, pg) })
  }
}

///|
/// The device's volume as one round button in `v` (its keys' place is one button's): pressed, a panel beside it as wide
/// as what it holds, no head (the button says what it is); on while it is open. In it a slider at the level the station
/// reads where it reads one (an Android device's: read again as it opens, set where it is moved to), else its down and
/// up, pressed as often as wanted with it staying up.
fn debug_volume_node(v : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  screen_round_node(v, pg, fn() { "volume" }, fn() { @sf.t("web-pages.screen.debug.volume") }, fn(b) {
    screen_panel_toggle(u, "volume", fn() {
      if s.volume() is Some(_) {
        s.input(s.src, Json::object({ "t": Json::string("volume") }))
      }
      @sf.panel_nodes(
        @sf.t("web-pages.screen.debug.volume"),
        fn(p, _) { debug_volume_panel_node(p, pg) },
        from=Node(b),
        fits=true,
        heads_itself=true,
        side=screen_panel_side(),
        along=Middle,
        focus=false,
      )
    })
  }, lit=fn() {
    screen_panel_on_now(u, "volume")
  })
  |> ignore
}

///|
/// What 音量's panel holds (debug_volume_node): the slider where the station reads the level, else down and up.
fn debug_volume_panel_node(p : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  p.pick(at_once=true, fn() { s.state_now() |> ignore; s.volume() is Some(_) }, fn(k, read) {
    if read {
      debug_volume_slider_node(k, s)
    } else {
      k.row(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)).gap(Is(@ui.Space::S2.px())) |> ignore
      screen_round_node(k, pg, fn() { "volume-down" }, fn() { @sf.t("web-pages.screen.debug.volumeDown") }, fn(_) {
        debug_device_input(s, "volume_down")
      })
      |> ignore
      screen_round_node(k, pg, fn() { "volume-up" }, fn() { @sf.t("web-pages.screen.debug.volumeUp") }, fn(_) {
        debug_device_input(s, "volume_up")
      })
      |> ignore
    }
  })
}

///|
/// The device's volume as a slider in `k`, 0 … its most: where it is moved to told the station (each level once), the
/// knob kept there until the station says the device is at it.
fn debug_volume_slider_node(k : @view.View, s : ScreenSess) -> Unit {
  let asked : @signals.Signal[Double?] = @signals.signal(None)
  let said = fn() {
    s.state_now() |> ignore
    s.volume()
  }
  k.reacts(said, at_start=false, fn(now) {
    match (now, asked.untracked()) {
      (Some((level, _)), Some(a)) if level == a => asked.set(None)
      _ => ()
    }
  })
  // (as tall as a press's room at least, the slider in its middle; the knob at either end as far in from the panel's
  // side as from its top, so its corner is the panel's one step in; beside its button that wide, across a sheet as
  // wide as the sheet)
  k
  .min_width(Is(Some(volume_slider_w)))
  .padding(
    By(fn() {
      let v = dmax(0.0, (@ui.room_least() - volume_slider_h) / 2.0)
      let h = @ui.Space::S1.px() + v
      (h, v, h, v)
    }),
  )
  |> ignore
  @sf.value_slider_node(
    k,
    fn() { @sf.t("web-pages.screen.debug.volume") },
    fn() {
      match (asked.get(), said()) {
        (Some(a), _) => a
        (None, Some((level, _))) => level
        (None, None) => 0.0
      }
    },
    fn(x) {
      let level = x.round()
      let was = match asked.untracked() {
        Some(a) => Some(a)
        None => @signals.untracked(said).map(fn(v) { v.0 })
      }
      if was != Some(level) {
        asked.set(Some(level))
        s.input(s.src, Json::object({ "t": Json::string("volume"), "level": Json::number(level) }))
      }
    },
    max=match @signals.untracked(said) {
      Some((_, most)) => most
      None => 1.0
    },
    bubble=false,
  )
  |> ignore
}

///|
/// 音量's slider's width (at least: a sheet's across it).
let volume_slider_w : Double = 200.0

///|
/// How tall sf's slider is drawn (its value_slider_node's).
let volume_slider_h : Double = 28.0

///|
/// What came of the device's picture taken and of an app started again, said where what debugs it says things (by the
/// device: 设备's foot; else a toast), as each is told.
fn debug_said_by(v : @view.View, pg : ScreenPage) -> Unit {
  let d = pg.u.logs
  v.reacts(fn() { d.told.get() }, fn(_) {
    let said = if d.shot_said {
      d.shot_said = false
      @sf.t("web-pages.screen.debug.shotCopied")
    } else {
      let w = d.relaunch_said
      d.relaunch_said = ""
      w
    }
    if said == "" {
      return
    }
    if d.beside_now() && d.shown.untracked() {
      d.acted.set(said)
    } else {
      toast_later(said)
    }
  }, at_start=false)
}

///|
/// An Android device (screens/android.ts): a simulator's page, with what it has.
fn ScreenSess::android(self : ScreenSess) -> Bool {
  self.screen.has_prefix("android:")
}

///|
/// A press of one of the device's buttons.
fn debug_press(s : ScreenSess, k : Combo) -> Unit {
  stroke(fn(j) { s.input(s.src, j) }, k.key, k.code, k.mods)
}

///|
/// A press of what only the device's own side knows (its volume, a memory warning).
fn debug_device_input(s : ScreenSess, name : String) -> Unit {
  s.input(s.src, Json::object({ "t": Json::string("device"), "name": Json::string(name) }))
}

///|
/// Soft outside-only elevation shadow behind a simulator's device chassis (none in 全屏 theater).
fn sim_device_shadow(u : ScreenUi) -> (Double, Double, Int64) {
  if u.full.get() {
    return (0.0, 0.0, 0L)
  }
  if @ui.tree_theme().dark {
    (32.0, 14.0, @sf.alpha(0x000000FFL, 0.42))
  } else {
    (26.0, 12.0, @sf.alpha(0x000000FFL, 0.16))
  }
}

///|
/// A 32×32 round icon button inside a 36pt liquid glass pill (wide simulator top bar or narrow mouse bottom pill).
fn sim_pill_icon_node(
  parent : @view.View,
  pg : ScreenPage,
  icon : () -> String,
  label : () -> String,
  press : (@view.View) -> Unit,
  lit? : () -> Bool = fn() { false },
  danger? : Bool = false,
) -> @view.View {
  @sf.action_box_node(parent, label, on=lit, press, fn(v) {
    @sf.style_node(v, fn() { sim_pill_btn }, in_row=true)
    v.ground(By(fn() {
      if !lit() {
        0L
      } else if danger {
        @sf.theme().p.red_bg
      } else {
        @sf.alpha(@ui.tree_theme().color(Fg), 0.1)
      }
    }))
    |> ignore
    @sf.bar_pill_key_press_node(v)
    @sf.icon_node(
      v,
      "",
      round_bar_icon,
      By(fn() { if danger && lit() { @sf.theme().p.red } else { @ui.tree_theme().color(Fg) } }),
      name_now=icon,
    )
    |> ignore
    @sf.tip_node(pg.tips, v, label) |> ignore
  })
}

///|
/// A vertical 1px hairline separator between button groups inside a liquid glass pill.
fn sim_pill_sep_node(parent : @view.View) -> Unit {
  parent.box(fn(sep) {
    sep
    .width(Is(Some(@sf.rule_w)))
    .height(Is(Some(16.0)))
    .margin(Is((2.0, 0.0, 2.0, 0.0)))
    .shrink(Is(0.0))
    .ground(By(@sf.rule_color))
    |> ignore
  })
  |> ignore
}

///|
/// The device's volume button inside a liquid glass pill (same panel as debug_volume_node).
fn sim_volume_pill_node(v : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  sim_pill_icon_node(v, pg, fn() { "volume" }, fn() { @sf.t("web-pages.screen.debug.volume") }, fn(b) {
    screen_panel_toggle(u, "volume", fn() {
      if s.volume() is Some(_) {
        s.input(s.src, Json::object({ "t": Json::string("volume") }))
      }
      @sf.panel_nodes(
        @sf.t("web-pages.screen.debug.volume"),
        fn(p, _) { debug_volume_panel_node(p, pg) },
        from=Node(b),
        fits=true,
        heads_itself=true,
        side=screen_panel_side(),
        along=Middle,
        focus=false,
      )
    })
  }, lit=fn() {
    screen_panel_on_now(u, "volume")
  })
  |> ignore
}

///|
/// Unified center liquid glass tool capsule(s) in the wide simulator top bar (Proposal C):
/// device keys (home, app switcher, keyboard, volume when uncased, rotate) | quick debug actions (screenshot, record,
/// relaunch app), plus a compact Duo pose pill when the device folds.
fn sim_bar_tools_node(parent : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  let d = u.logs
  parent.show(at_once=true, fn() { s.driving_now() || flag(s.state_now(), "debug") }, fn(row) {
    @sf.style_node(row, fn() { sim_bar_tools_group }, in_row=true)
    row.shrink(Is(0.0)) |> ignore
    @sf.bar_pill_group_node(row, height=36.0, pad=2.0, gap=2.0, fn(pill) {
      pill.show(at_once=true, fn() { s.driving_now() }, fn(k) {
        k.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(2.0)) |> ignore
        k.each(at_once=true, fn() { device_combos(s, device_case_now(k, s, s.frame_size())) }, fn(c) { c.keys }, fn(slot, c) {
          sim_pill_icon_node(slot, pg, fn() { c.get().icon }, fn() { c.get().name }, fn(_) { debug_press(s, c.untracked()) }) |> ignore
        })
        k.show(fn() { device_case_now(k, s, s.frame_size()) is None }, fn(v) { sim_volume_pill_node(v, pg) })
        sim_pill_icon_node(k, pg, fn() { "screen-rotate" }, fn() { @sf.t("web-pages.screen.device.rotate") }, fn(_) {
          debug_device_input(s, "rotate")
        })
        |> ignore
      })
      pill.show(at_once=true, fn() { s.driving_now() && flag(s.state_now(), "debug") }, fn(sep) {
        sim_pill_sep_node(sep)
      })
      pill.show(at_once=true, fn() { flag(s.state_now(), "debug") }, fn(k) {
        k.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(2.0)) |> ignore
        sim_pill_icon_node(k, pg, fn() { "camera" }, fn() { @sf.t("web-pages.screen.device.shot") }, fn(_) { debug_shot(s, d) }) |> ignore
        let going = fn() { debug_going(d) }
        sim_pill_icon_node(
          k,
          pg,
          fn() { if going() { "stop" } else { "play" } },
          fn() { @sf.t(if going() { "web-pages.screen.debug.recordStop" } else { "web-pages.screen.debug.recordStart" }) },
          fn(_) { debug_record_pressed(s, d, @signals.untracked(going)) },
          lit=going,
          danger=true,
        )
        |> ignore
        sim_pill_icon_node(k, pg, fn() { "refresh" }, fn() { @sf.t("web-pages.screen.debug.relaunch") }, fn(b) {
          match d.last_app.untracked() {
            Some((id, name)) => debug_relaunch(s, d, id, name)
            None => debug_apps_open(s, u, Node(b))
          }
        })
        |> ignore
      })
    })
    |> ignore
    row.show(at_once=true, fn() { s.driving_now() && flag(s.state_now(), "poses") }, fn(slot) {
      @sf.bar_pill_group_node(slot, height=36.0, pad=2.0, gap=2.0, fn(pill) {
        debug_poses_node(pill, pg, icons=true, pill=true)
      })
      |> ignore
    })
  })
}

///|
/// 调试 drawer toggle button in the wide simulator top bar (32pt tall to match sibling bar controls):
/// toggles the right-hand App / 日志 / 设备 pane. `corner`: when inside viewer_bar_node's right tools pill, follows its
/// concentric corner radius with no extra inactive ground.
fn sim_debug_toggle_node(parent : @view.View, pg : ScreenPage, corner? : @view.Live[Double]) -> Unit {
  let d = pg.u.logs
  let open = fn() { d.shown.get() }
  let tip = fn() { @sf.t(if open() { "web-pages.screen.debug.paneHide" } else { "web-pages.screen.debug.paneShow" }) }
  let in_pill = corner is Some(_)
  let btn = @sf.action_box_node(parent, tip, on=open, fn(_) {
    d.shown_set = true
    d.shown.set(!d.shown.untracked())
  }, fn(v) {
    @sf.style_node(v, fn() { sim_debug_btn }, in_row=true)
    v.shrink(Is(0.0)) |> ignore
    match corner {
      Some(r) => v.radius(r) |> ignore
      None => ()
    }
    v.ground(By(fn() {
      if open() {
        @sf.theme().p.accent_bg
      } else if in_pill {
        0L
      } else {
        @sf.theme().p.neutral_bg
      }
    }))
    |> ignore
    @sf.hover_ground_node(v, lit=Some(fn() { v.pointed() || v.pressed() || v.focus_shown() }))
    let ink = fn() { if open() { @sf.theme().p.accent_text } else { @ui.tree_theme().color(Fg) } }
    @sf.icon_node(v, "", round_bar_icon, By(ink), name_now=fn() { if open() { "panel-close" } else { "panel-open" } }) |> ignore
    let words = @sf.words_node(v, fn() { @sf.t("web-pages.screen.debug.pane") }, fn() { sim_debug_btn_words })
    words.ink(By(ink)) |> ignore
  })
  @sf.tip_node(pg.tips, btn, tip) |> ignore
}

///|
/// Under the picture on a narrow page, in `bar`: the device's buttons while it is driven, and what debugs an app for
/// one who may: its picture, 重启 App (the app last started again, at one press: what is restarted over and over while
/// debugging; another: App), and the panel of the rest. On a mouse pointer (narrow workbench or side panel), grouped
/// cleanly inside a single liquid glass pill; on touch, full 40pt finger targets.
fn debug_tools_node(bar : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  let d = u.logs
  debug_said_by(bar, pg)
  if !@sf.soft_keyboard() {
    bar.show(at_once=true, fn() { s.driving_now() || flag(s.state_now(), "debug") }, fn(slot) {
      @sf.bar_pill_group_node(slot, height=36.0, pad=2.0, gap=2.0, fn(pill) {
        pill.show(at_once=true, fn() { s.driving_now() }, fn(k) {
          k.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(2.0)) |> ignore
          k.each(at_once=true, fn() { device_combos(s, device_case_now(k, s, s.frame_size())) }, fn(c) { c.keys }, fn(sl, c) {
            sim_pill_icon_node(sl, pg, fn() { c.get().icon }, fn() { c.get().name }, fn(_) { debug_press(s, c.untracked()) }) |> ignore
          })
          sim_pill_icon_node(k, pg, fn() { "screen-rotate" }, fn() { @sf.t("web-pages.screen.device.rotate") }, fn(_) {
            debug_device_input(s, "rotate")
          })
          |> ignore
          k.show(fn() { !flag(s.state_now(), "debug") && s.android() }, fn(v) { sim_volume_pill_node(v, pg) })
        })
        pill.show(at_once=true, fn() { s.driving_now() && flag(s.state_now(), "debug") }, fn(sep) { sim_pill_sep_node(sep) })
        pill.show(at_once=true, fn() { flag(s.state_now(), "debug") }, fn(k) {
          k.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(2.0)) |> ignore
          sim_pill_icon_node(k, pg, fn() { "camera" }, fn() { @sf.t("web-pages.screen.device.shot") }, fn(_) { debug_shot(s, d) }) |> ignore
          sim_pill_icon_node(k, pg, fn() { "refresh" }, fn() { @sf.t("web-pages.screen.debug.relaunch") }, fn(b) {
            match d.last_app.untracked() {
              Some((id, name)) => debug_relaunch(s, d, id, name)
              None => debug_apps_open(s, u, Node(b))
            }
          })
          |> ignore
          sim_pill_icon_node(k, pg, fn() { "file-text" }, fn() { @sf.t("web-pages.screen.debug.logs") }, fn(b) {
            debug_logs_open(s, u, Node(b))
          })
          |> ignore
        })
      })
      |> ignore
    })
    return
  }
  bar.show(at_once=true, fn() { s.driving_now() }, fn(k) {
    k.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(@ui.Space::S2.px())) |> ignore
    debug_device_keys_node(k, pg, beside=false)
  })
  bar.show(at_once=true, fn() { flag(s.state_now(), "debug") }, fn(k) {
    k.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(@ui.Space::S2.px())) |> ignore
    screen_round_node(k, pg, fn() { "camera" }, fn() { @sf.t("web-pages.screen.device.shot") }, fn(_) { debug_shot(s, d) }) |> ignore
    screen_round_node(k, pg, fn() { "refresh" }, fn() { @sf.t("web-pages.screen.debug.relaunch") }, fn(b) {
      match d.last_app.untracked() {
        Some((id, name)) => debug_relaunch(s, d, id, name)
        None => debug_apps_open(s, u, Node(b))
      }
    })
    |> ignore
    screen_round_node(k, pg, fn() { "file-text" }, fn() { @sf.t("web-pages.screen.debug.logs") }, fn(b) {
      debug_logs_open(s, u, Node(b))
    })
    |> ignore
  })
}

///|
/// An iPhone Duo's hinge in `parent`: which it is as its picture says (the cover's is closed, the inner panel's half
/// open only when asked for here, Device Hub's own being told by none), and each its press: a segmented row under the
/// picture, or (`icons`) a round button each (`pill`: 32pt glass pill buttons in the top bar).
fn debug_poses_node(parent : @view.View, pg : ScreenPage, icons~ : Bool, pill? : Bool = false) -> Unit {
  let s = pg.s
  let u = pg.u
  let names = ["closed", "book", "open"]
  let chosen = fn() {
    s.said.get() |> ignore
    s.part_told.get() |> ignore
    let cover = match s.frame_size() {
      Some((w, h)) => w.to_double() / h.to_double() < duo_cover_shape
      None => true
    }
    // (the one pressed as chosen until the picture has come: a fold takes a second or more)
    let asked = u.logs.pose_asked.get()
    if asked >= 0 && (asked == 0) != cover {
      asked
    } else if cover {
      0
    } else if u.logs.half_open {
      1
    } else {
      2
    }
  }
  let words = fn() {
    [
      @sf.t("web-pages.screen.device.pose.closed"),
      @sf.t("web-pages.screen.device.pose.book"),
      @sf.t("web-pages.screen.device.pose.open"),
    ]
  }
  // (the picture of the one asked come: nothing asked any longer, the picture saying which)
  parent.reacts(fn() {
    s.said.get() |> ignore
    s.part_told.get() |> ignore
    match s.frame_size() {
      Some((w, h)) => w.to_double() / h.to_double() < duo_cover_shape
      None => true
    }
  }, fn(cover) {
    let asked = u.logs.pose_asked.untracked()
    if asked >= 0 && (asked == 0) == cover {
      u.logs.pose_asked.set(-1)
    }
  })
  // (another chosen: asked of the device as it is pressed)
  let picked = fn(pick : Int) {
    if pick != @signals.untracked(chosen) {
      u.logs.half_open = pick == 1
      u.logs.pose_asked.set(pick)
      s.input(s.src, Json::object({ "t": Json::string("pose"), "name": Json::string(names[pick]) }))
    }
  }
  if icons {
    // (each its own button, in a glass pill or a column of them)
    for i, icon in ["phone", "panel-open", "landscape"] {
      if pill {
        sim_pill_icon_node(parent, pg, fn() { icon }, fn() { words()[i] }, fn(_) { picked(i) }, lit=fn() { chosen() == i }) |> ignore
      } else {
        screen_round_node(parent, pg, fn() { icon }, fn() { words()[i] }, fn(_) { picked(i) }, lit=fn() { chosen() == i }) |> ignore
      }
    }
  } else {
    parent.box(fn(k) {
      @sf.segmented_node(k, words, chosen, picked, said=@sf.t("web-pages.screen.device.pose"))
    })
    |> ignore
  }
}

///|
/// The device's body round its picture in `f` (over the stage), over the picture's corners: a simulator's case where it
/// has one (device_cased_node), else its body drawn from what its type's masks say of the panel the picture is of, its
/// edge painted over what lies outside the screen's corners. Not while zoomed in: what shows is then a part of the
/// screen.
fn device_body_node(f : @view.View, pg : ScreenPage, size : () -> (Int, Int)?) -> Unit {
  let s = pg.s
  let u = pg.u
  f.pick(at_once=true, fn() {
    u.zoom.told()
    s.said.get() |> ignore
    if !s.simulator() || u.zoom.zoomed_at(f.drawn_while(fn(t) { u.zoom.goes_at(t) })) {
      0
    } else if device_case_now(f, s, size()) is Some(_) {
      2
    } else {
      1
    }
  }, fn(o, how) {
    o.over(Is(true)) |> ignore
    match how {
      2 => device_cased_node(o, pg, size)
      1 => {
        let corners = fn(r : SRect) {
          s.said.get() |> ignore
          panel_corners(field(s.state, "panels"), r.w, r.h)
        }
        device_corners_node(o, pg, fn(r) { corners(r) })
        o.box(fn(b) {
          b
          .over(Is(true))
          .offset(By(fn() {
            let r = u.picture_on(b)
            (r.x - sim_bezel, r.y - sim_bezel)
          }))
          .width(By(fn() { Some(u.picture_on(b).w + sim_bezel + sim_bezel) }))
          .height(By(fn() { Some(u.picture_on(b).h + sim_bezel + sim_bezel) }))
          // det-ok(corners-each): the device's own: an iPhone Duo's cover is nearly square along its hinge (sim-mask.ts)
          .corners(By(fn() {
            let (tl, tr, br, bl) = corners(u.picture_on(b))
            Some((tl + sim_bezel, tr + sim_bezel, br + sim_bezel, bl + sim_bezel))
          }))
          .edge(Is((sim_bezel, device_body_ink)))
          .ring(By(fn() {
            if @ui.tree_theme().dark {
              (1.0, 0.0, @sf.rule_color())
            } else {
              (0.0, 0.0, 0L)
            }
          }))
          .shadow(By(fn() { sim_device_shadow(u) }))
          .shadow_outside(Is(true))
          |> ignore
        })
        |> ignore
      }
      _ => ()
    }
  })
}

///|
/// The picture's own corners in `o`, square, cut off in the page's ground where what is round it leaves them showing
/// (`corners` of the picture where it is drawn: top left, then round it): the picture is square, a box cannot round a
/// stream's picture under what is drawn over it.
fn device_corners_node(o : @view.View, pg : ScreenPage, corners : (SRect) -> (Double, Double, Double, Double)) -> Unit {
  let u = pg.u
  o.box(fn(b) {
    let over = corner_cut_over * 2.0
    let shown = fn() { u.picture_on(b) }
    b
    .over(Is(true))
    .offset(By(fn() {
      let r = shown()
      (r.x - corner_cut_over, r.y - corner_cut_over)
    }))
    .width(By(fn() { Some(shown().w + over) }))
    .height(By(fn() { Some(shown().h + over) }))
    .shapes(By(fn() {
      let r = shown()
      let (tl, tr, br, bl) = corners(r)
      let e = corner_cut_over
      let cuts = [
        (e, e, 1.0, 1.0, tl),
        (e + r.w, e, -1.0, 1.0, tr),
        (e + r.w, e + r.h, -1.0, -1.0, br),
        (e, e + r.h, 1.0, -1.0, bl),
      ].filter(fn(k) { k.4 > 0.0 }).map(fn(k) { (corner_cut(k.0, k.1, k.2, k.3, k.4), true) })
      if cuts.is_empty() {
        []
      } else {
        [@ui.shape_of(cuts, fill=0x000000FFL)]
      }
    }))
    // (in the page's ground: the theater's in 全屏)
    .tint(By(fn() { @ui.tree_theme().color(if u.full.get() { Theater } else { Bg }) }))
    |> ignore
  })
  |> ignore
}

///|
/// What lies outside a corner's curve of radius `r`, as an outline: from the corner at (`x`, `y`) round the curve, (`dx`, `dy`)
/// the way into the picture from it.
fn corner_cut(x : Double, y : Double, dx : Double, dy : Double, r : Double) -> Array[Double] {
  let e = corner_cut_over
  let points = [x - dx * e, y - dy * e, x + dx * r, y - dy * e]
  for i in 0..=corner_cut_steps {
    let a = i.to_double() / corner_cut_steps.to_double() * @math.PI / 2.0
    points.push(x + dx * r * (1.0 - @dmath.sin(a)))
    points.push(y + dy * r * (1.0 - @dmath.cos(a)))
  }
  points.push(x - dx * e)
  points.push(y + dy * r)
  points
}

///|
/// The corners of the panel whose shape is nearest `w`×`h`, in px: top left, then round it (none known, square). Turned
/// on its side the device's are all the same, the smallest, as which way is not known.
fn panel_corners(panels : Json?, w : Double, h : Double) -> (Double, Double, Double, Double) {
  let shape = dmin(w, h) / dmax(w, h)
  let mut best : Array[Json] = []
  let mut off = 1.0
  match panels {
    Some(Array(all)) =>
      for p in all {
        let (pw, ph) = (number(Some(p), "width"), number(Some(p), "height"))
        if ph > 0.0 && (shape - pw / ph).abs() < off {
          off = (shape - pw / ph).abs()
          best = match field(Some(p), "corners") {
            Some(Array(a)) => a
            _ => []
          }
        }
      }
    _ => ()
  }
  if best.length() != 4 {
    return (0.0, 0.0, 0.0, 0.0)
  }
  let at = fn(i : Int) {
    match best[i] {
      Number(v, ..) => v * dmin(w, h)
      _ => 0.0
    }
  }
  if w > h {
    let least = dmin(dmin(at(0), at(1)), dmin(at(2), at(3)))
    (least, least, least, least)
  } else {
    (at(0), at(1), at(2), at(3))
  }
}

///|
/// `id` started again, said when it was; the next press is for it too.
fn debug_relaunch(s : ScreenSess, d : DebugLogs, id : String, name : String) -> Unit {
  if !s.is_active_principal() {
    return
  }
  d.last_app.set(Some((id, name)))
  let params = { "station": Json::string(s.station), "screen": Json::string(s.screen), "app": Json::string(id) }
  (s.src.call)("screen.relaunch", Json::object(params), fn(r) {
    d.relaunch_said = match r {
      Ok(_) => @sf.t("web-pages.screen.debug.relaunched", args=[("name", name)])
      Err(e) => text(Some(e), "message")
    }
    d.told.set(d.told.untracked() + 1)
  })
}

///|
/// The device's picture in its own pixels, onto this device's clipboard (what a person shows an agent or a colleague).
fn debug_shot(s : ScreenSess, d : DebugLogs) -> Unit {
  if !s.is_active_principal() {
    return
  }
  let params = { "station": Json::string(s.station), "screen": Json::string(s.screen) }
  (s.src.call)("screen.screenshot", Json::object(params), fn(r) {
    if !s.is_active_principal() {
      return
    }
    match r {
      Ok(v) =>
        match @codec.from_base64_exact(text(Some(v), "png")) {
          Some(png) => {
            @ui.clipboard_set_png(png, label=@sf.product())
            d.shot_said = true
            d.told.set(d.told.untracked() + 1)
          }
          None => ()
        }
      Err(_) => ()
    }
  })
}

///|
/// A device's buttons, as combos are: each Simulator.app's shortcut for it (screens/android.ts takes them too). An
/// Android device has its back (Escape there) and shows its own software keyboard. What the device's case has itself
/// (`cased`: its power button, a home button) is pressed there.
fn device_combos(s : ScreenSess, cased : DeviceCase?) -> Array[Combo] {
  let c = fn(name : String, keys : String, key : String, code : String, mods : Int, icon : String) -> Combo {
    { name: @sf.t(name), keys, key, code, mods, icon }
  }
  let home = c("web-pages.screen.device.home", "⇧⌘H", "h", "KeyH", mod_meta | mod_shift, "square")
  let tasks = c("web-pages.screen.device.appSwitcher", "⌃⇧⌘H", "h", "KeyH", mod_ctrl | mod_meta | mod_shift, "view-columns")
  let lock = c("web-pages.screen.device.lock", "⌘L", "l", "KeyL", mod_meta, "power")
  if s.android() {
    [c("web-pages.screen.device.back", "Esc", "Escape", "Escape", 0, "arrow-left"), home, tasks, lock]
  } else {
    let keyboard = c("web-pages.screen.device.softKeyboard", "⌘K", "k", "KeyK", mod_meta, "keyboard")
    match cased {
      Some(k) => if k.has("home") { [tasks, keyboard] } else { [home, tasks, keyboard] }
      None => [home, tasks, lock, keyboard]
    }
  }
}

///|
/// One line of the log as `screen.logs` says it: when (its time of day), how serious, which app, what.
#derive(Eq)
priv struct DebugLine {
  at : String
  level : String
  app : String
  words : String
}

///|
/// What debugs an app holds, the pane beside the device's and the 日志 panel's alike: what the panel's nodes read of it
/// told as it changes (a signal each).
priv struct DebugLogs {
  /// where the next look asks from (`next` of the last answer)
  mut after : Double
  /// the newest last (told as they come: what shows them reads them), and how many older were let go
  lines : @signals.Signal[Array[DebugLine]]
  mut dropped : Int
  mut asks : Int
  mut asking : Bool
  failed : @signals.Signal[String]
  /// which of 日志 and 设备 shows
  tab : @signals.Signal[Int]
  /// how the device is set, as it last said (`screen.settings`); asked for as 设备 first shows
  settings : @signals.Signal[Json?]
  mut settings_asked : Bool
  mut shot_said : Bool
  /// each time the device's picture was taken or an app started again (`shot_said`, `relaunch_said`: what says it reads
  /// them as this is told)
  told : @signals.Signal[Int]
  /// what is done with the device is beside it, its foot saying what came of it (the files gone up to it among that)
  beside : @signals.Signal[Bool]
  /// what the device has itself is by it (a wide page), not under its picture
  by_device : @signals.Signal[Bool]
  /// what is done with it shows beside the device, or is put away for the device to have the room
  shown : @signals.Signal[Bool]
  /// whether the person (or a test) explicitly toggled `shown`, so entering a wide layout keeps their choice
  mut shown_set : Bool
  /// the app 重启 App is for (id, name), once one was chosen
  last_app : @signals.Signal[(String, String)?]
  mut relaunch_said : String
  /// asked here for an iPhone Duo's half open (the inner panel's picture says the rest)
  mut half_open : Bool
  /// the pose last pressed, until the picture says it (-1: none)
  pose_asked : @signals.Signal[Int]
  /// what the last of debug_actions came to
  acted : @signals.Signal[String]
  /// whether its status bar was made tidy here (simctl does not say)
  tidy_bar : @signals.Signal[Bool]
  /// started here and not ended yet (`settings` says one started before this page)
  recording : @signals.Signal[Bool]
  /// the movie of a recording ended, to download (the drive's root and path)
  to_save : @signals.Signal[(String, String)?]
  /// set here (none yet: as `settings` says)
  enrolled : @signals.Signal[Bool?]
  /// the buttons of the device's case a hand pressed here, by their names: held down (true), or let go and its press
  /// still to come (false)
  buttons_held : Map[String, Bool]
}

///|
/// A log's timestamp ("2026-11-02 13:23:11.123456+0800") at its time of day.
fn debug_time(at : String) -> String {
  let chars = at.to_array()
  if chars.length() >= 19 {
    String::from_array(chars[11:19])
  } else {
    at
  }
}

///|
fn debug_line_of(v : Json) -> DebugLine {
  let line = Some(v)
  { at: debug_time(text(line, "at")), level: text(line, "level"), app: text(line, "app"), words: text(line, "text") }
}

///|
/// What came in a `screen.logs` answer, added to what is held.
fn DebugLogs::took(self : DebugLogs, answer : Json) -> Unit {
  let lines = items(Some(answer), "lines").map(debug_line_of)
  // (a new array told: what reads the lines reads them again)
  let all = self.lines.untracked().copy()
  all.append(lines)
  if all.length() > debug_logs_kept {
    self.dropped += all.length() - debug_logs_kept
    self.lines.set(all[all.length() - debug_logs_kept:].to_owned())
  } else if lines.length() > 0 {
    self.lines.set(all)
  }
  self.after = number(Some(answer), "next")
}

///|
/// Whether what is done with the device is beside it now, followed.
fn DebugLogs::beside_now(self : DebugLogs) -> Bool {
  self.beside.get()
}

///|
fn DebugLogs::copied_text(self : DebugLogs) -> String {
  self.lines.get().map(fn(l) { l.at + " " + l.app + " " + l.words }).join("\n")
}

///|
/// 日志 from 控制中心 or the tools under the device, its body nodes (screen_debug_node.mbt).
fn debug_logs_open(s : ScreenSess, u : ScreenUi, from : @sf.Anchor) -> Unit {
  let open = fn() {
    @sf.panel_nodes(@sf.t("web-pages.screen.debug.logs"), fn(v, _) { debug_logs_node(v, s, u) }, from~,
      side=screen_panel_side(), w=debug_panel_w, tall=0.82, grows=true, focus=false)
  }
  if @sf.native_on() && !u.in_tab {
    screen_panel_toggle(u, "logs", open)
  } else {
    open()
  }
}

///|
fn debug_logs_new() -> DebugLogs {
  {
    after: 0.0,
    lines: @signals.signal([]),
    dropped: 0,
    asks: 0,
    asking: false,
    failed: @signals.signal("", same=fn(a, b) { a == b }),
    tab: @signals.signal(0, same=fn(a, b) { a == b }),
    settings: @signals.signal(None),
    settings_asked: false,
    beside: @signals.signal(false, same=fn(a, b) { a == b }),
    by_device: @signals.signal(false, same=fn(a, b) { a == b }),
    shown: @signals.signal(false, same=fn(a, b) { a == b }),
    shown_set: false,
    shot_said: false,
    told: @signals.signal(0),
    last_app: @signals.signal(None, same=fn(a, b) { a == b }),
    relaunch_said: "",
    half_open: false,
    pose_asked: @signals.signal(-1, same=fn(a, b) { a == b }),
    acted: @signals.signal("", same=fn(a, b) { a == b }),
    tidy_bar: @signals.signal(false, same=fn(a, b) { a == b }),
    recording: @signals.signal(false, same=fn(a, b) { a == b }),
    to_save: @signals.signal(None, same=fn(a, b) { a == b }),
    enrolled: @signals.signal(None, same=fn(a, b) { a == b }),
    buttons_held: {},
  }
}

///|
/// What came since the last answer asked for (`screen.logs`), taken; `answered` once it is.
fn debug_logs_ask(s : ScreenSess, d : DebugLogs, answered : () -> Unit) -> Unit {
  if !s.is_active_principal() {
    return
  }
  d.asking = true
  let n = d.asks
  let params = { "station": Json::string(s.station), "screen": Json::string(s.screen), "after": Json::number(d.after) }
  (s.src.call)("screen.logs", Json::object(params), fn(r) {
    match r {
      Ok(v) => {
        d.failed.set("")
        d.took(v)
      }
      Err(e) => d.failed.set(text(Some(e), "message"))
    }
    d.asking = false
    d.asks = n + 1
    answered()
  })
}

///|
/// App, 日志 and 设备, in the words of the language now.
fn debug_tab_labels() -> Array[String] {
  [@sf.t("web-pages.screen.debug.app"), @sf.t("web-pages.screen.debug.logs"), @sf.t("web-pages.screen.debug.device")]
}

///|
/// Setting `name` of the device set to `value`, how it is then taken from the answer.
fn debug_setting_chosen(s : ScreenSess, d : DebugLogs, name : String, value : String) -> Unit {
  if !s.is_active_principal() {
    return
  }
  let params = { "station": Json::string(s.station), "screen": Json::string(s.screen), "name": Json::string(name), "value": Json::string(value) }
  (s.src.call)("screen.setSetting", Json::object(params), fn(r) {
    match r {
      Ok(v) => d.settings.set(Some(v))
      Err(e) => d.failed.set(text(Some(e), "message"))
    }
  })
}

///|
/// 外观's choices: the value set, its words' key.
// kept across runs: a table, never written
let debug_appearances : Array[(String, String)] = [("light", "web-pages.screen.debug.light"), ("dark", "web-pages.screen.debug.dark")]

///|
/// 文字大小's choices: the value set, its words' key.
// kept across runs: a table, never written
let debug_text_sizes : Array[(String, String)] = [
  ("small", "web-pages.screen.debug.textSmall"),
  ("large", "web-pages.screen.debug.textDefault"),
  ("extra-extra-large", "web-pages.screen.debug.textLarge"),
  ("accessibility-large", "web-pages.screen.debug.textLargest"),
]

///|
/// How the device is set, asked (`screen.settings`).
fn debug_settings_ask(s : ScreenSess, d : DebugLogs) -> Unit {
  if !s.is_active_principal() {
    return
  }
  d.settings_asked = true
  let params = { "station": Json::string(s.station), "screen": Json::string(s.screen) }
  (s.src.call)("screen.settings", Json::object(params), fn(r) {
    match r {
      Ok(v) => d.settings.set(Some(v))
      Err(e) => d.failed.set(text(Some(e), "message"))
    }
  })
}

///|
/// 状态栏's choices: as it is, made tidy (9:41).
fn debug_status_labels() -> Array[String] {
  [@sf.t("web-pages.screen.debug.statusReal"), @sf.t("web-pages.screen.debug.statusTidy")]
}

///|
/// Its status bar made tidy (9:41), or as it is again.
fn debug_tidy_chosen(s : ScreenSess, d : DebugLogs, tidy : Bool) -> Unit {
  d.tidy_bar.set(tidy)
  debug_act(s, d, "screen.statusBar", { "tidy": Json::boolean(tidy) }, @sf.t("web-pages.screen.debug.done"))
}

///|
/// 面容 / 指纹's choices: not enrolled, enrolled.
fn debug_enrolled_labels() -> Array[String] {
  [@sf.t("web-pages.screen.debug.notEnrolled"), @sf.t("web-pages.screen.debug.enrolled")]
}

///|
/// Whether a face or a finger is enrolled: as set here, else as the device says.
fn debug_enrolled(d : DebugLogs) -> Bool {
  d.enrolled.get().unwrap_or(flag(d.settings.get(), "enrolled"))
}

///|
/// A face or a finger enrolled, or not.
fn debug_enrolled_chosen(s : ScreenSess, d : DebugLogs, on : Bool) -> Unit {
  d.enrolled.set(Some(on))
  debug_act(s, d, "screen.biometrics", { "what": Json::string(if on { "enrol" } else { "unenrol" }) }, @sf.t("web-pages.screen.debug.done"))
}

///|
/// Whether 录屏 is going: started here, or before this page as the device says.
fn debug_going(d : DebugLogs) -> Bool {
  d.recording.get() || flag(d.settings.get(), "recording")
}

///|
/// 录屏 started, of the panel in use where the device has two, or ended.
fn debug_record_pressed(s : ScreenSess, d : DebugLogs, going : Bool) -> Unit {
  if !s.is_active_principal() {
    return
  }
  let params : Map[String, Json] = { "station": Json::string(s.station), "screen": Json::string(s.screen) }
  if !going {
    if flag(s.state, "poses") {
      let cover = match s.frame_size() {
        Some((w, h)) => w.to_double() / h.to_double() < duo_cover_shape
        None => true
      }
      params["panel"] = Json::string(if cover { "cover" } else { "inner" })
    }
    d.recording.set(true)
    d.acted.set("")
    (s.src.call)("screen.recordStart", Json::object(params), fn(r) {
      match r {
        Ok(_) => ()
        Err(e) => {
          d.recording.set(false)
          d.acted.set(text(Some(e), "message"))
        }
      }
    })
    return
  }
  d.recording.set(false)
  d.settings.set(None)
  d.settings_asked = false
  d.acted.set(@sf.t("web-pages.screen.debug.recordSaving"))
  (s.src.call)("screen.recordStop", Json::object(params), fn(r) {
    match r {
      Ok(v) if text(Some(v), "path") != "" => {
        d.acted.set(@sf.t("web-pages.screen.debug.recordSaved"))
        d.to_save.set(Some((text(Some(v), "root"), text(Some(v), "path"))))
      }
      Ok(_) => d.acted.set("")
      Err(e) => d.acted.set(text(Some(e), "message"))
    }
  })
}

///|
/// `op` of the device told, what comes back said where 设备 says things.
fn debug_act(s : ScreenSess, d : DebugLogs, op : String, more : Map[String, Json], done : String) -> Unit {
  if !s.is_active_principal() {
    return
  }
  let params : Map[String, Json] = { "station": Json::string(s.station), "screen": Json::string(s.screen) }
  more.each(fn(k, v) { params[k] = v })
  d.acted.set("")
  (s.src.call)(op, Json::object(params), fn(r) {
    d.acted.set(
      match r {
        Ok(_) => done
        Err(e) => text(Some(e), "message")
      },
    )
  })
}

///|
/// Beside the device, in `k` (a wide page's, 320 wide, the page's height): App, 日志 and 设备 to choose between and 复制日志
/// over the log, what is over it staying as it scrolls; what came of what was done, and the files sent to the device,
/// staying under it.
fn debug_pane_node(k : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  let d = u.logs
  // (its slot in the row beside the device, a 1px vertical hairline separating the pane from the canvas)
  k.row(Is(true)) |> ignore
  k.box(fn(rule) {
    @sf.style_node(rule, fn() { debug_pane_rule }, in_row=true)
    rule.shrink(Is(0.0)).ground(By(@sf.rule_color)) |> ignore
  })
  |> ignore
  k.box(fn(pane) {
    @sf.style_node(pane, fn() { debug_pane_box.then(@ui.css("h=Full")) }, in_row=true)
    pane.width(Is(Some(debug_pane_w))).min_height(Is(Some(0.0))) |> ignore
    pane.box(fn(head) {
      @sf.style_node(head, fn() { debug_pane_head })
      // (as wide as its options, 复制日志 at the head's other end on 日志: the old pane's)
      @sf.seg_node(head, debug_tab_labels, fn() { d.tab.get() }, fn(i) { d.tab.set(i) }) |> ignore
      head.show(at_once=true, fn() { d.tab.get() == debug_tab_logs && !d.lines.get().is_empty() }, fn(k) {
        debug_logs_copy_node(k, d)
      })
    })
    |> ignore
    pane.box(fn(body) {
      body.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      body.scrolls(@view.Scroll::new(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(c) {
        c.pick(at_once=true, fn() { d.tab.get() }, fn(t, tab) {
          if tab == debug_tab_logs {
            // (its lines one under another, nothing between them: the old pane's list)
            t.grow(Is(1.0)) |> ignore
            debug_lines_node(t, s, d, copy=false)
          } else {
            @sf.style_node(t, fn() { debug_device_box })
            if tab == debug_tab_device {
              debug_device_node(t, s, u, beside=true)
            } else {
              debug_app_node(t, s, u, beside=true)
            }
          }
        })
      })
      |> ignore
    })
    |> ignore
    debug_said_node(pane, d)
    drops_node(pane, s)
  })
  |> ignore
}

///|
/// What 重启 App's panel holds (its sending a notification and taking an app off alike): the apps as the device said
/// them (None: still asked), what the last thing done says (asked for the apps, one started again), whether one is
/// being done, each told as it changes.
priv struct DebugApps {
  apps : @signals.Signal[Array[Json]?]
  said : @signals.Signal[String]
  mut going : Bool
  /// the notification the one chosen is sent (none: it is started again)
  push : String?
  /// the one chosen is taken off the device
  uninstall : Bool
}

///|
/// 重启 App from 控制中心, 日志's App, or the tools under the device, beside what opened it (`from`); `push`: the
/// notification sent to the one chosen; `uninstall`: the one chosen taken off.
fn debug_apps_open(s : ScreenSess, u : ScreenUi, from : @sf.Anchor, push? : String, uninstall? : Bool = false) -> Unit {
  if !s.is_active_principal() {
    return
  }
  let d : DebugApps = { apps: @signals.signal(None), said: @signals.signal(""), going: false, push, uninstall }
  let params = { "station": Json::string(s.station), "screen": Json::string(s.screen) }
  (s.src.call)("screen.apps", Json::object(params), fn(r) {
    match r {
      Ok(v) => d.apps.set(Some(items(Some(v), "apps")))
      Err(e) => {
        d.said.set(text(Some(e), "message"))
        d.apps.set(Some([]))
      }
    }
  })
  let open = fn() {
    // (what is chosen in it is what it is said to be for)
    let title = @sf.t(if push is Some(_) { "web-pages.screen.debug.pushGo" } else if uninstall { "web-pages.screen.debug.uninstall" } else { "web-pages.screen.debug.relaunch" })
    @sf.panel_nodes(title, fn(v, _) { debug_apps_node(v, s, u, d) }, from~, side=screen_panel_side(), w=net_panel_w, focus=false)
  }
  if @sf.native_on() && !u.in_tab {
    screen_panel_toggle(u, "apps", open)
  } else {
    open()
  }
}

///|
/// The apps on the device in `v` (debug_apps_open's), each pressed what the panel is for: started again (the next
/// 重启 App's), sent the notification, or taken off (not offered again); what came of it said under them.
fn debug_apps_node(v : @view.View, s : ScreenSess, u : ScreenUi, d : DebugApps) -> Unit {
  @sf.panel_group_node(v, fn() { "" }, fn(g) {
    g.show(at_once=true, fn() { d.apps.get() is None }, fn(n) { @sf.panel_note_node(n, fn() { @sf.t("web-pages.screen.debug.appsLoading") }) })
    g.show(at_once=true, fn() { d.apps.get() is Some([]) && d.said.get() == "" }, fn(n) {
      @sf.panel_note_node(n, fn() { @sf.t("web-pages.screen.debug.appsNone") })
    })
    g.each(
      at_once=true,
      fn() { d.apps.get().unwrap_or([]).map(fn(a) { (text(Some(a), "id"), text(Some(a), "name"), flag(Some(a), "running")) }) },
      fn(a) { a.0 },
      fn(row, a) {
        @sf.panel_row_node(
          row,
          fn() { a.get().1 },
          fn() {
            if d.going || !s.is_active_principal() {
              return
            }
            let (id, name, _) = a.untracked()
            d.going = true
            let params = { "station": Json::string(s.station), "screen": Json::string(s.screen), "app": Json::string(id) }
            let (op, done) = match d.push {
              Some(words) => {
                params["text"] = Json::string(words)
                ("screen.push", @sf.t("web-pages.screen.debug.pushed", args=[("name", name)]))
              }
              None if d.uninstall => ("screen.uninstall", @sf.t("web-pages.screen.debug.uninstalled", args=[("name", name)]))
              None => {
                u.logs.last_app.set(Some((id, name)))
                ("screen.relaunch", @sf.t("web-pages.screen.debug.relaunched", args=[("name", name)]))
              }
            }
            (s.src.call)(op, Json::object(params), fn(r) {
              d.going = false
              match r {
                Ok(_) => {
                  // (one taken off the device is not offered again)
                  if d.uninstall {
                    d.apps.set(d.apps.untracked().map(fn(all) { all.filter(fn(x) { text(Some(x), "id") != id }) }))
                  }
                  d.said.set(done)
                }
                Err(e) => d.said.set(text(Some(e), "message"))
              }
            })
          },
          icon=fn() { "phone" },
          note=fn() { if a.get().2 { @sf.t("web-pages.screen.debug.appRunning") } else { "" } },
        )
      },
    )
    g.show(at_once=true, fn() { d.said.get() != "" }, fn(n) { @sf.panel_note_node(n, fn() { d.said.get() }) })
  })
}
