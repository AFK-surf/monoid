// The gallery's pages (src/gallery shows them in a window, src/shots draws them offscreen): each of the library's
// parts over a wallpaper of its own (drawn, no picture: the same on every run), as Kyant0/AndroidLiquidGlass's catalog
// shows them over its photograph. `page` makes the one asked for: the overview (every part), the dialog open over it,
// the overview held (each part pressed or dragged, held still: its glass up), and the film's (the parts a film drags,
// each where the film's script finds it).

///|
/// The parts' glass, as held still for a picture of them held: what the interactive page presses as it is made.
priv struct Held {
  button : @lg.InteractiveHighlight
  toggle : @lg.DampedDrag
  slider : @lg.DampedDrag
  tabs : @lg.DampedDrag
  tabs_light : @lg.InteractiveHighlight
  tile : @lg.InteractiveHighlight
}

///|
/// The page named `name` in the window's `root`: "overview", "dialog" (the overview, its dialog open) or
/// "interactive" (the overview, its parts held), "film" (the film's parts).
pub fn page(root : @view.View, name : String) -> Unit {
  @ui.set_tree_theme(@lg.ui_theme)
  root.box(fn(w) {
    w.grow(Is(1.0)).clips(Is(true)) |> ignore
    wallpaper(w)
    match name {
      "film" => film_page(w)
      "dialog" => {
        overview(w, None)
        let open = @signals.signal(true)
        @lg.liquid_dialog_node(
          w,
          fn() { open.get() },
          fn() { open.set(false) },
          fn() { "Dialog Title" },
          fn() { lorem },
          on_action=fn() { open.set(false) },
        )
        |> ignore
      }
      "interactive" => overview(w, Some(held_now()))
      _ => overview(w, None)
    }
  })
  |> ignore
}

///|
/// Glass held as the interactive page shows it, not pressed yet (`press_all` presses it once each part is made).
fn held_now() -> Held {
  {
    button: @lg.InteractiveHighlight::new(),
    toggle: @lg.DampedDrag::new(0.0, lo=0.0, hi=1.0, held_scale=@lg.thumb_held_scale),
    slider: @lg.DampedDrag::new(40.0, lo=0.0, hi=100.0, threshold=0.01, held_scale=@lg.thumb_held_scale),
    tabs: @lg.DampedDrag::new(0.0, lo=0.0, hi=2.0, held_scale=@lg.tab_lens_held_scale),
    tabs_light: @lg.InteractiveHighlight::new(),
    tile: @lg.InteractiveHighlight::new(),
  }
}

///|
/// The catalog's words (LoremIpsum.kt).
pub let lorem : String = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur."

///|
/// The wallpaper: soft blots of colour under a wide frost (a mesh of colour, as a photograph's), crossed by thin bright
/// stripes and a word set large, sharp, for the glass over it to bend.
fn wallpaper(w : @view.View) -> Unit {
  w.box(fn(paper) {
    paper.over(Is(true)).clips(Is(true)).ground(By(fn() { if @lg.is_dark() { 0x101028FFL } else { 0xF2E9DDFFL } })) |> ignore
    let blots : Array[(Double, Double, Double, Int64, Int64)] = [
      (-120.0, -160.0, 520.0, 0xFF8A5BFFL, 0x8C2F6BFFL),
      (520.0, -220.0, 560.0, 0x5BC8FFFFL, 0x1E4FA8FFL),
      (900.0, 260.0, 520.0, 0xFFD25BFFL, 0xA8641EFFL),
      (-200.0, 480.0, 600.0, 0x8BE38CFFL, 0x1F7A4AFFL),
      (380.0, 620.0, 560.0, 0xC58BFFFFL, 0x4B2A8CFFL),
      (1000.0, 760.0, 420.0, 0xFF6FA8FFL, 0x8C1E4FFFL),
    ]
    for b in blots {
      let (x, y, d, light, dark) = b
      paper.box(fn(c) {
        c
        .over(Is(true))
        .width(Is(Some(d)))
        .height(Is(Some(d)))
        .radius(Is(d / 2.0))
        .offset(Is((x, y)))
        .ground(By(fn() { if @lg.is_dark() { dark } else { light } }))
        |> ignore
      })
      |> ignore
    }
    paper.box(fn(f) {
      f
      .over(Is(true))
      .glass(Is(Some(@ui.Glass::frosted(blur=90.0, tint=0x00000000L, solid=0x808080FFL, contained=true))))
      |> ignore
    })
    |> ignore
    for k in 0..<14 {
      paper.box(fn(s) {
        s
        .over(Is(true))
        .width(Is(Some(2400.0)))
        .height(Is(Some(6.0)))
        .offset(Is((-600.0, -200.0 + k.to_double() * 110.0)))
        .turn(Is(-0.35))
        .ground(By(fn() { if @lg.is_dark() { 0xFFFFFF2EL } else { 0xFFFFFF8CL } }))
        |> ignore
      })
      |> ignore
    }
    // (a lattice of rings, sharp, for the glass over it to bend)
    for row in 0..<11 {
      for col in 0..<14 {
        let d = 26.0
        paper.box(fn(c) {
          c
          .over(Is(true))
          .width(Is(Some(d)))
          .height(Is(Some(d)))
          .radius(Is(d / 2.0))
          .offset(Is((30.0 + col.to_double() * 92.0 + (if row % 2 == 0 { 0.0 } else { 46.0 }), 20.0 + row.to_double() * 96.0)))
          .edge(By(fn() { (3.0, if @lg.is_dark() { 0xFFFFFF26L } else { 0xFFFFFF73L }) }))
          |> ignore
        })
        |> ignore
      }
    }
  })
  |> ignore
}

///|
/// A section of the overview in `parent`: its `title` over what `body` makes.
fn section(parent : @view.View, title : String, body : (@view.View) -> Unit) -> Unit {
  parent.box(fn(s) {
    s.gap(Is(12.0)) |> ignore
    s.box(fn(t) {
      t.words(Is(title), look=@lg.words_at(13.0, weight=600)).ink(By(fn() { @lg.alpha(@lg.colors().content, 0.6) })) |> ignore
    })
    |> ignore
    body(s)
  })
  |> ignore
}

///|
/// A row of parts in `parent`, 16 apart, their middles in line.
fn row(parent : @view.View, body : (@view.View) -> Unit) -> Unit {
  parent.box(fn(r) {
    r.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Middle))) |> ignore
    body(r)
  })
  |> ignore
}

///|
/// Every part, in two columns over the wallpaper; with `held`, each held as that says (pressed as the page is made).
fn overview(root : @view.View, held : Held?) -> Unit {
  let on = @signals.signal(true)
  let off = @signals.signal(false)
  let level = @signals.signal(40.0)
  let tab3 = @signals.signal(0)
  let tab4 = @signals.signal(1)
  let air = @signals.signal(false)
  let wifi = @signals.signal(true)
  let cell = @signals.signal(true)
  root.box(fn(page) {
    page.grow(Is(1.0)).row(Is(true)).gap(Is(48.0)).padding(Is((48.0, 40.0, 48.0, 40.0))) |> ignore
    page.box(fn(left) {
      left.width(Is(Some(520.0))).shrink(Is(0.0)).gap(Is(28.0)) |> ignore
      section(left, "LiquidButton", fn(s) {
        row(s, fn(r) {
          @lg.liquid_button_node(r, fn() { "Transparent Liquid Button" }, fn() {  }, light?=held.map(fn(h) { h.button }))
          |> ignore
          @lg.liquid_button_node(r, fn() { "Surface Liquid Button" }, fn() {  }, surface=0xFFFFFF4DL) |> ignore
        })
        row(s, fn(r) {
          @lg.liquid_button_node(r, fn() { "Tinted Liquid Button" }, fn() {  }, tint=0x0088FFFFL) |> ignore
          @lg.liquid_button_node(r, fn() { "Tinted Liquid Button" }, fn() {  }, tint=0xFF8D28FFL) |> ignore
        })
      })
      section(left, "LiquidToggle", fn(s) {
        row(s, fn(r) {
          @lg.liquid_toggle_node(r, fn() { off.get() }, fn(v) { off.set(v) }, fn() { "Wi-Fi" }, drag?=held.map(fn(h) {
            h.toggle
          }))
          |> ignore
          @lg.liquid_toggle_node(r, fn() { on.get() }, fn(v) { on.set(v) }, fn() { "Bluetooth" }) |> ignore
        })
      })
      section(left, "LiquidSlider", fn(s) {
        s.box(fn(b) {
          b.width(Is(Some(460.0))) |> ignore
          @lg.liquid_slider_node(b, fn() { level.get() }, fn(v) { level.set(v) }, fn() { "Brightness" }, drag?=held.map(fn(
            h,
          ) {
            h.slider
          }))
          |> ignore
        })
        |> ignore
      })
      section(left, "LiquidBottomTabs", fn(s) {
        s.box(fn(b) {
          b.width(Is(Some(460.0))).gap(Is(20.0)) |> ignore
          @lg.liquid_bottom_tabs_node(
            b,
            ["Tab 1", "Tab 2", "Tab 3"],
            fn() { tab3.get() },
            fn(i) { tab3.set(i) },
            label="Tabs",
            drag?=held.map(fn(h) { h.tabs }),
            light?=held.map(fn(h) { h.tabs_light }),
          )
          |> ignore
          @lg.liquid_bottom_tabs_node(
            b,
            ["Tab 1", "Tab 2", "Tab 3", "Tab 4"],
            fn() { tab4.get() },
            fn(i) { tab4.set(i) },
            label="More tabs",
          )
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
    page.box(fn(right) {
      right.width(Is(Some(616.0))).shrink(Is(0.0)).gap(Is(28.0)) |> ignore
      section(right, "Control center", fn(s) {
        row(s, fn(r) {
          let wide = @lg.tile_size * 2.0 + @lg.tile_gap
          // (its corners round what it holds, 16 in: the catalog's 34 would cut closer to its capsules than they sit to
          // its edge)
          @lg.liquid_card_node(
            r,
            wide,
            wide,
            fn() { "Connectivity" },
            radius=@lg.tile_inner / 2.0 + @lg.tile_gap,
            light?=held.map(fn(h) { h.tile }),
            press=fn() {  },
            content=fn(c) {
              c.padding(Is((@lg.tile_gap, @lg.tile_gap, @lg.tile_gap, @lg.tile_gap))).lies_along(Is(Between)) |> ignore
              c.box(fn(rr) {
                rr.row(Is(true)).lies_along(Is(Between)) |> ignore
                @lg.liquid_control_item_node(rr, fn() { air.get() }, fn(v) { air.set(v) }, fn() { "Airplane mode" }) |> ignore
                @lg.liquid_control_item_node(rr, fn() { wifi.get() }, fn(v) { wifi.set(v) }, fn() { "Wi-Fi" }) |> ignore
              })
              |> ignore
              c.box(fn(rr) {
                rr.row(Is(true)) |> ignore
                @lg.liquid_control_item_node(rr, fn() { cell.get() }, fn(v) { cell.set(v) }, fn() { "Cellular" }) |> ignore
              })
              |> ignore
            },
          )
          |> ignore
          r.box(fn(col) {
            col.gap(Is(@lg.tile_gap)) |> ignore
            row(col, fn(rr) {
              @lg.liquid_control_tile_node(rr, fn() { "Flight" }, fn() {  }) |> ignore
              @lg.liquid_control_tile_node(rr, fn() { "Rotation" }, fn() {  }, angle=135.0) |> ignore
            })
            @lg.liquid_card_node(col, wide, @lg.tile_size, fn() { "Now playing" }) |> ignore
          })
          |> ignore
        })
      })
      section(right, "Adaptive luminance", fn(s) {
        row(s, fn(r) {
          for lum in [0.92, 0.08] {
            r.box(fn(b) {
              b
              .width(Is(Some(220.0)))
              .height(Is(Some(200.0)))
              .radius(Is(28.0))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              .ground(Is(if lum > 0.5 { 0xF4F4F4FFL } else { 0x1C1C1EFFL }))
              |> ignore
              b.box(fn(stripes) {
                // (six lines, 32 from its top and 24 from its foot, cut to its corners: the card's shadow over it is not)
                stripes.over(Is(true)).clips(Is(true)).radius(Is(28.0)).padding(Is((0.0, 32.0, 0.0, 0.0))).gap(Is(24.0)) |> ignore
                for _ in 0..<6 {
                  stripes.box(fn(line) {
                    line.height(Is(Some(4.0))).ground(Is(if lum > 0.5 { 0xD0D0D8FFL } else { 0x3A3A44FFL })) |> ignore
                  })
                  |> ignore
                }
              })
              |> ignore
              @lg.liquid_adaptive_surface_node(b, fn() { lum }, size=150.0) |> ignore
            })
            |> ignore
          }
        })
      })
      section(right, "Progressive blur", fn(s) {
        s.box(fn(b) {
          b.radius(Is(24.0)).clips(Is(true)) |> ignore
          b.box(fn(text) {
            text.padding(Is((20.0, 16.0, 20.0, 16.0))).ground(By(fn() { @lg.alpha(@lg.colors().paper, 0.5) })) |> ignore
            text.box(fn(t) {
              t.words(Is(lorem), look=@lg.words_at(16.0, wrap=true)).ink(By(fn() { @lg.colors().content })) |> ignore
            })
            |> ignore
          })
          |> ignore
          b.box(fn(o) {
            o.over(Is(true)) |> ignore
            @lg.liquid_progressive_blur_node(o, height=96.0) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      section(right, "Magnifier", fn(s) {
        @lg.liquid_magnifier_node(s, fn() { lorem }, at=(60.0, 40.0)) |> ignore
      })
    })
    |> ignore
  })
  |> ignore
  match held {
    Some(h) =>
      @signals.untracked(fn() {
        // (each held as a finger holds it: the button pressed and pulled right, the toggle's thumb and the slider's,
        // the tabs' lens between its first two tabs, a tile pressed)
        h.button.down(60.0, 24.0, 240.0, 48.0)
        h.button.moved(120.0, 34.0)
        h.toggle.press()
        h.slider.press()
        h.tabs.press()
        h.tabs.update_value(0.55)
        h.tabs_light.down(80.0, 32.0, 460.0, 64.0)
        h.tile.down(110.0, 40.0, 152.0, 152.0)
      })
    None => ()
  }
}

///|
/// The film's page: the parts its script drags, each where the script finds it (src/shots, film_script): 40 in from
/// the window's top left, 40 apart down it, 520 wide.
fn film_page(root : @view.View) -> Unit {
  let on = @signals.signal(false)
  let level = @signals.signal(30.0)
  let tab = @signals.signal(0)
  root.box(fn(page) {
    page.grow(Is(1.0)).gap(Is(40.0)).padding(Is((40.0, 40.0, 40.0, 40.0))).lines_up(Is(Some(Start))) |> ignore
    @lg.liquid_button_node(page, fn() { "Liquid Button" }, fn() {  }) |> ignore
    @lg.liquid_toggle_node(page, fn() { on.get() }, fn(v) { on.set(v) }, fn() { "Toggle" }) |> ignore
    page.box(fn(b) {
      b.width(Is(Some(520.0))) |> ignore
      @lg.liquid_slider_node(b, fn() { level.get() }, fn(v) { level.set(v) }, fn() { "Slider" }) |> ignore
    })
    |> ignore
    page.box(fn(b) {
      b.width(Is(Some(520.0))) |> ignore
      @lg.liquid_bottom_tabs_node(b, ["Tab 1", "Tab 2", "Tab 3", "Tab 4"], fn() { tab.get() }, fn(i) { tab.set(i) }, label="Tabs")
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
