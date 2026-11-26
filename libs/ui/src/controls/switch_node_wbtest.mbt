// The switch exposes one accessible target with a keyboard focus ring. Disabled switches take no focus or presses.

///|
fn switch_tester(platform : Int, on : @signals.Signal[Bool], disabled : Bool) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform~)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      switch_row_node(b, fn() { "性能记录" }, fn() { on.get() }, fn(to) { on.set(to) }, note=fn() { "保存在本机" }, disabled=fn() {
        disabled
      })
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "the switch's focus ring surrounds its track and both Space and Enter activate it" {
  for platform in [0, 2] {
    let on = @signals.signal(false)
    let t = switch_tester(platform, on, false)
    assert_eq(t.all(Switch).length(), 1)
    let s = t.get(Switch, label="性能记录")
    assert_true(s.check is Some(Off))
    let (x, y, w, h) = s.rect
    assert_eq((w, h), (63.0, 28.0))
    t.key(@ui.key_tab)
    t.frame()
    assert_eq(t.focused().map(fn(s) { s.label }), Some("性能记录"))
    assert_true(t.boxes_held().iter().any(fn(b) { b.hit && (b.x, b.y, b.w, b.h) == s.rect }))
    assert_true(t.boxes_held().iter().any(fn(b) {
      b.border_w > 0.0 && b.x + b.w / 2.0 == x + w / 2.0 && b.y + b.h / 2.0 == y + h / 2.0
    }))
    t.key(@ui.key_space)
    t.frame()
    assert_true(on.get())
    t.enter()
    t.frame()
    assert_true(!on.get())
  }
}

///|
test "a disabled switch is read out as disabled and Tab passes it over" {
  for platform in [0, 2] {
    let on = @signals.signal(false)
    let t = switch_tester(platform, on, true)
    assert_true(t.get(Switch, label="性能记录").disabled)
    t.key(@ui.key_tab)
    t.frame()
    assert_true(t.focused() is None)
    t.key(@ui.key_space)
    t.enter()
    t.frame()
    assert_true(!on.get())
  }
}

///|
/// A switch row with a note under its title on a group's card (`words`: among the words of a page's card,
/// page_card_node's), `look` (narrow or wide) at the system's size of words `scale`: how far the middle of its switch
/// is from that of its title's line; no corner of it out of its card's.
fn switch_off_title_line(look : Look, scale : Double, platform : Int, words? : Bool = false) -> Double raise {
  let t = @ui.Tester::new(fn(_c) {  }, w=if look is Wide { 760.0 } else { 390.0 }, h=400.0, platform~)
  t.set_font_scale(scale)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lends(part_at, { look, section: false, list: false, card: false }) |> ignore
      let note = fn() { "保存在本机，只在你分享时才发出去，分享前可以先看一遍里面记了什么" }
      if words {
        page_card_node(b, fn(k) { switch_row_node(k, fn() { "性能记录" }, fn() { true }, fn(_) {  }, note~, in_words=true) })
      } else {
        group_node(b, card=true, fn(g) { switch_row_node(g, fn() { "性能记录" }, fn() { true }, fn(_) {  }, note~) })
      }
    })
    |> ignore
  })
  t.draw()
  let (_, sy, _, sh) = t.get(Switch, label="性能记录").rect
  let title = t.words().filter(fn(w) { w.0 == "性能记录" })
  assert_eq(title.length(), 1)
  let (_, _, ty, _, th, _) = title[0]
  assert_eq(t.first_line_faults(), [])
  assert_eq(t.corner_faults(), [])
  (sy + sh / 2.0 - (ty + th / 2.0)).abs()
}

///|
test "a switch row with a note under its title has its switch on the title's line, not across their middle, out of its card's corners: on a group's card and among a page card's words, narrow and wide, with a mouse and a finger, at text sizes 1 and 1.3" {
  for words in [false, true] {
    for look in [Narrow, Wide] {
      for platform in [0, 2] {
        for scale in [1.0, 1.3] {
          let off = switch_off_title_line(look, scale, platform, words~)
          assert_true(off <= 0.5, msg="words \{words} wide \{look is Wide} on \{platform} at \{scale}: \{off} off its title's line")
        }
      }
    }
  }
}

///|
test "switch_node: liquid glass lens scale animation causes zero relayout (laid == 0)" {
  let on = @signals.signal(false)
  let t = switch_tester(2, on, false)
  t.check_looks(false)
  let (x, y, w, h) = t.get(Switch, label="性能记录").rect
  let lens_mount_ms = dur_ms / 4.0
  let lens_step_ms = @ui.move_most_ms / 2.0
  t.touch(0, x + w / 2.0, y + h / 2.0)
  t.run_for(lens_mount_ms)
  t.tree_frames_from_now()
  t.run_for(lens_step_ms)
  let frames = t.tree_frames()
  assert_true(frames.length() > 0, msg="expected animation frames while switch lens scales")
  assert_true(
    frames.iter().all(fn(f) { f.laid == 0 }),
    msg="switch_node lens animation must not trigger relayout: \{Repr(frames.map(fn(f) { f.laid }))}",
  )
  t.touch(2, x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms * 2.0)
}

///|
/// How far a switch `w` wide moves its thumb end to end (@glass.liquid_toggle_node's drag_dist).
fn switch_drag_dist(w : Double) -> Double {
  w - 2.0 * @glass.toggle_pad - w * @glass.thumb_w / @glass.toggle_w
}

///|
test "a switch dragged past its on end and brought back three quarters of the way from where it was taken stays on" {
  let on = @signals.signal(false)
  let t = switch_tester(0, on, false)
  let (x, y, w, h) = t.get(Switch, label="性能记录").rect
  let (x0, y0) = (x + h / 2.0, y + h / 2.0)
  let back = x0 + 0.75 * switch_drag_dist(w)
  t.press_at(x0, y0)
  t.run_for(@ui.input_step_ms)
  // (on far past its on end: held at on)
  for dx in [20.0, 60.0, 120.0] {
    t.move_to(x0 + dx, y0)
    t.run_for(@ui.input_step_ms)
  }
  // (back to three quarters of its way: on, as the hand has it there; summed move by move it would be off)
  t.move_to(back, y0)
  t.run_for(@ui.input_step_ms)
  t.release(back, y0)
  t.run_for(@ui.move_most_ms)
  assert_true(on.get())
}

///|
test "a switch dragged past its off end and brought back three quarters of the way from where it was taken turns off" {
  let on = @signals.signal(true)
  let t = switch_tester(0, on, false)
  let (x, y, w, h) = t.get(Switch, label="性能记录").rect
  let (x0, y0) = (x + w - h / 2.0, y + h / 2.0)
  let back = x0 - 0.75 * switch_drag_dist(w)
  t.press_at(x0, y0)
  t.run_for(@ui.input_step_ms)
  for dx in [20.0, 60.0, 120.0] {
    t.move_to(x0 - dx, y0)
    t.run_for(@ui.input_step_ms)
  }
  t.move_to(back, y0)
  t.run_for(@ui.input_step_ms)
  t.release(back, y0)
  t.run_for(@ui.move_most_ms)
  assert_true(!on.get())
}

///|
/// The size of the switch `make` puts on a page of `look` in a window `w` wide, with a mouse (`platform` 0) or a finger
/// (2); no line of it off its first line's middle, no corner of a row of it out of its card's.
fn switch_size_in(
  name : String,
  look : Look,
  w : Double,
  platform : Int,
  make : (@view.View) -> Unit,
) -> (Double, Double) raise {
  let t = @ui.Tester::new(fn(_c) {  }, w~, h=400.0, platform~)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lends(part_at, { look, section: false, list: false, card: false }) |> ignore
      make(b)
    })
    |> ignore
  })
  t.draw()
  let (_, _, sw, sh) = t.get(Switch, label="性能记录").rect
  let at = "\{name} wide \{look is Wide} \{w} on \{platform}"
  assert_eq(t.first_line_faults(), [], msg=at)
  assert_eq(t.corner_faults(), [], msg=at)
  assert_eq(t.squeeze_faults(), [], msg=at)
  assert_eq(t.audit(), [], msg=at)
  (sw, sh)
}

///|
test "every switch is its look's one size, 63 by 28 narrow and 50 by 22 wide, with a mouse and a finger, however wide the window" {
  let makes : Array[(String, (@view.View) -> Unit)] = [
    ("switch_node", fn(b) { switch_node(b, fn() { true }, fn(_) {  }, fn() { "性能记录" }) }),
    (
      "switch_row_node",
      fn(b) {
        group_node(b, card=true, fn(g) {
          switch_row_node(g, fn() { "性能记录" }, fn() { true }, fn(_) {  }, note=fn() { "保存在本机" })
        })
      },
    ),
    (
      "setting_switch_node",
      // (on a page's ground, as a settings page makes it: narrow, a section's heading, not a card's row)
      fn(b) { setting_switch_node(b, fn() { "性能记录" }, fn() { true }, fn(_) {  }, note=fn() { "保存在本机" }) },
    ),
  ]
  for made in makes {
    let (name, make) = made
    for platform in [0, 2] {
      for w in [320.0, 360.0, 390.0, 430.0] {
        assert_eq(switch_size_in(name, Narrow, w, platform, make), (63.0, 28.0), msg="\{name} narrow \{w} on \{platform}")
      }
      for w in [760.0, 1280.0] {
        assert_eq(switch_size_in(name, Wide, w, platform, make), (50.0, 22.0), msg="\{name} wide \{w} on \{platform}")
      }
    }
  }
}

///|
test "a narrow heading with a long title puts its trailing switch on a line of its own without squeezing the title" {
  for platform in [0, 2] {
    let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=400.0, platform~)
    @ui.set_view_app(fn(root) {
      root.box(fn(b) {
        b.lends(part_at, { look: Narrow, section: false, list: false, card: false }) |> ignore
        heading_node(
          b,
          fn() { "Hold Cmd/Ctrl to highlight & quote text" },
          ends=fn(r) { switch_node(r, fn() { true }, fn(_) {  }, fn() { "Highlight" }) },
        )
      })
      |> ignore
    })
    t.draw()
    let at = "narrow heading wrap on \{platform}"
    let (_, sw_y, sw_w, sw_h) = t.get(Switch, label="Highlight").rect
    assert_eq((sw_w, sw_h), (63.0, 28.0), msg=at)
    let title_box = t.boxes_held().filter(fn(b) { b.text.contains("Hold") })
    assert_true(!title_box.is_empty(), msg=at)
    assert_true(sw_y > title_box[0].y + title_box[0].h, msg="switch wrapped below title: \{at}")
    assert_eq(t.first_line_faults(), [], msg=at)
    assert_eq(t.squeeze_faults(), [], msg=at)
    assert_eq(t.audit(), [], msg=at)
  }
}

///|
test "an expanded last kind in kinds_card_node keeps its narrow 63x28 switch clear of the card corner on mouse and touch" {
  for pair in [(390.0, 2), (600.0, 0)] {
    let (w, platform) = pair
    let t = @ui.Tester::new(fn(_c) {  }, w~, h=600.0, platform~)
    @ui.set_view_app(fn(root) {
      root.box(fn(b) {
        b.lends(part_at, { look: Narrow, section: false, list: false, card: false }) |> ignore
        kinds_card_node(b, fn(k) {
          kind_row_node(
            k,
            fn() { "待你决定" },
            fn() { "横幅" },
            fn() { "agent 暂停等待你" },
            fn() { true },
            fn() {  },
            fn(ways) {
              way_row_node(ways, fn() { "横幅" }, fn(r) {
                switch_node(r, fn() { true }, fn(_) {  }, fn() { "横幅" })
              })
            },
          )
        })
      })
      |> ignore
    })
    t.draw()
    let at = "kinds_card_node \{w} on \{platform}"
    assert_eq(t.get(Switch, label="横幅").rect.2, 63.0, msg=at)
    assert_eq(t.get(Switch, label="横幅").rect.3, 28.0, msg=at)
    assert_eq(t.corner_faults(), [], msg=at)
    assert_eq(t.first_line_faults(), [], msg=at)
    assert_eq(t.audit(), [], msg=at)
  }
}
