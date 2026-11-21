// ui.monoid · STANDARD STAGE (src/studio shows it in a desktop window and WebGL 2; src/studio_shots captures
// offscreen Metal stills and a 60 fps demo film): a single-viewport (1120x637 / 1120x690 zero-scroll, responsive to
// 1280x1040) interactive workbench built 100% on production `@sf` retained-tree components with a mathematically
// pinned bottom 3-scene switcher (Controls / Tokens / Overlays, 0.00 px jump).

///|
let brand_pi : Double = 3.141592653589793

///|
let monoid_vermilion : Int64 = 0xEF6334FFL

///|
fn words_look(size : Double, weight? : Int = 400, line? : Double = 0.0, tracking? : Double = 0.0, wrap? : Bool = false) -> @view.WordsLook {
  {
    size,
    weight,
    line: if line > 0.0 { line } else { size * 1.35 },
    wrap,
    tracking: if tracking == 0.0 { @view.letters_own } else { Points(tracking) },
    balance: false,
    max_lines: 0,
  }
}

///|
fn rrect_outline(x : Double, y : Double, w : Double, h : Double, r : Double, k : Double) -> (Array[Double], Bool) {
  let out : Array[Double] = []
  let push_arc = fn(cx : Double, cy : Double, from : Double, sweep : Double) {
    for p in @paint.arc(cx * k, cy * k, r * k, from~, sweep~) {
      out.push(p.0)
      out.push(p.1)
    }
  }
  push_arc(x + w - r, y + r, -brand_pi / 2.0, brand_pi / 2.0)
  push_arc(x + w - r, y + h - r, 0.0, brand_pi / 2.0)
  push_arc(x + r, y + h - r, brand_pi / 2.0, brand_pi / 2.0)
  push_arc(x + r, y + r, brand_pi, brand_pi / 2.0)
  (out, true)
}

///|
/// Monoid 2x2 rounded four-tile brand mark (top-right tile highlighted in Monoid Vermilion `#EF6334`).
#callsite(autofill(loc))
fn brand_mark(parent : @view.View, size : Double, loc~ : SourceLoc) -> Unit {
  let k = size / 24.0
  parent.box(made_for=loc, fn(b) {
    b
    .width(Is(Some(size)))
    .height(Is(Some(size)))
    .shrink(Is(0.0))
    .shapes(By(fn() {
      let c = @sf.theme().p.text
      [
        @paint.shape_of(
          [
            rrect_outline(3.0, 3.0, 8.0, 8.0, 2.2, k),
            rrect_outline(3.0, 13.0, 8.0, 8.0, 2.2, k),
            rrect_outline(13.0, 13.0, 8.0, 8.0, 2.2, k),
          ],
          fill=c,
        ),
        @paint.shape_of([rrect_outline(13.0, 3.0, 8.0, 8.0, 2.2, k)], fill=monoid_vermilion),
      ]
    }))
    |> ignore
  })
  |> ignore
}

///|
fn hex_digit(n : Int) -> Char {
  let digits = "0123456789ABCDEF"
  digits[n & 0xF].to_int().unsafe_to_char()
}

///|
/// Format 0xRRGGBBAA color as `#RRGGBB`.
fn hex_of(c : Int64) -> String {
  let rgb = (c >> 8) & 0xFFFFFFL
  let buf = StringBuilder()
  buf.write_char('#')
  for shift in [20, 16, 12, 8, 4, 0] {
    buf.write_char(hex_digit(((rgb >> shift) & 0xFL).to_int()))
  }
  buf.to_string()
}

///|
/// Accent swatch color for `key` in the current light/dark mode.
fn accent_swatch_color(key : String) -> Int64 {
  let dark = @sf.theme().dark
  match @sf.tone_of(key) {
    Some(a) => if dark { a.dark } else { a.light }
    None => @sf.theme().p.accent
  }
}

///|
/// Architectural neutral backdrop with restrained 80pt Swiss hairline grid.
#callsite(autofill(loc))
fn stage_backdrop(parent : @view.View, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(bg) {
    bg
    .over(Is(true))
    .clips(Is(true))
    .points(Is(false))
    .ground(By(fn() { @sf.theme().p.bg }))
    |> ignore
    for col in 1..<17 {
      bg.box(fn(vl) {
        vl
        .over(Is(true))
        .width(Is(Some(1.0)))
        .height(Is(Some(1200.0)))
        .offset(Is((col.to_double() * 80.0, 0.0)))
        .ground(By(fn() { @sf.alpha(@sf.theme().p.text, if @sf.theme().dark { 0.04 } else { 0.035 }) }))
        |> ignore
      })
      |> ignore
    }
    for row_i in 1..<14 {
      bg.box(fn(hl) {
        hl
        .over(Is(true))
        .width(Is(Some(1600.0)))
        .height(Is(Some(1.0)))
        .offset(Is((0.0, row_i.to_double() * 80.0)))
        .ground(By(fn() { @sf.alpha(@sf.theme().p.text, if @sf.theme().dark { 0.04 } else { 0.035 }) }))
        |> ignore
      })
      |> ignore
    }
  })
  |> ignore
}

///|
/// Compact pill button for the top Studio Bar built on `@headless.button`.
#callsite(autofill(loc))
fn studio_pill_btn(
  parent : @view.View,
  label : () -> String,
  on_press : () -> Unit,
  body : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  @headless.button(made_for=loc, parent, label, fn(_) { on_press() }, fn(b, _btn) {
    b
    .focus_ring_theme()
    .row(Is(true))
    .height(Is(Some(30.0)))
    .padding(Is((11.0, 0.0, 11.0, 0.0)))
    .radius(Is(15.0))
    .gap(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() { @sf.theme().p.raised }))
    .edge(By(fn() { (0.5, @sf.theme().p.line_strong) }))
    |> ignore
    @sf.hover_ground_node(b)
    body(b)
  })
  |> ignore
}

///|
/// Quick OKLCH accent dot button in the top Studio Bar.
#callsite(autofill(loc))
fn accent_dot_btn(parent : @view.View, key : String, name : String, loc~ : SourceLoc) -> Unit {
  @headless.button(made_for=loc, parent, fn() { "Accent " + name }, fn(_) { @sf.set_accent(key) }, fn(b, _btn) {
    let active = fn() { @sf.accent_key() == key }
    b
    .focus_ring_theme()
    .width(Is(Some(24.0)))
    .height(Is(Some(24.0)))
    .radius(Is(12.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .edge(By(fn() {
      if active() {
        (1.5, @sf.theme().p.text)
      } else {
        (0.0, 0L)
      }
    }))
    |> ignore
    @sf.hover_ground_node(b)
    b.box(fn(dot) {
      dot
      .width(Is(Some(14.0)))
      .height(Is(Some(14.0)))
      .radius(Is(7.0))
      .ground(By(fn() { accent_swatch_color(key) }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Top Studio Bar (`height: 40`): brand mark + `ui.monoid · STANDARD STAGE` on left; OKLCH accent dots +
/// Dark/Light toggle + status pill on right.
#callsite(autofill(loc))
fn studio_bar(
  parent : @view.View,
  is_narrow : () -> Bool,
  hide_stage_tag : () -> Bool,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(hdr) {
    hdr
    .row(Is(true))
    .height(Is(Some(40.0)))
    .shrink(Is(0.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Between))
    |> ignore
    hdr.box(fn(left) {
      left.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
      brand_mark(left, 18.0)
      left.box(fn(w) {
        w
        .words(Is("ui.monoid"), look=words_look(15.0, weight=600, line=20.0))
        .ink(By(fn() { @sf.theme().p.text }))
        |> ignore
      })
      |> ignore
      left.show(fn() { !hide_stage_tag() }, at_once=true, fn(tag_slot) {
        tag_slot.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
        tag_slot.box(fn(dot) {
          dot
          .width(Is(Some(3.0)))
          .height(Is(Some(3.0)))
          .radius(Is(1.5))
          .shrink(Is(0.0))
          .ground(By(fn() { @sf.theme().p.subtle }))
          |> ignore
        })
        |> ignore
        tag_slot.box(fn(w) {
          w
          .words(Is("STANDARD STAGE"), look=words_look(11.0, weight=600, line=16.0, tracking=1.0))
          .ink(By(fn() { @sf.theme().p.muted }))
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
    hdr.box(fn(right) {
      right.row(Is(true)).lines_up(Is(Some(Middle))).gap(By(fn() { if is_narrow() { 8.0 } else { 12.0 } })) |> ignore
      // OKLCH accent quick-switch dots
      right.box(fn(dots) {
        dots
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .gap(Is(4.0))
        .padding(Is((3.0, 3.0, 3.0, 3.0)))
        .radius(Is(15.0))
        .ground(By(fn() { @sf.theme().p.raised }))
        .edge(By(fn() { (0.5, @sf.theme().p.line_strong) }))
        |> ignore
        accent_dot_btn(dots, "", "Vermilion")
        accent_dot_btn(dots, "blue", "Blue")
        accent_dot_btn(dots, "teal", "Teal")
        accent_dot_btn(dots, "purple", "Purple")
      })
      |> ignore
      // Dark / Light toggle
      studio_pill_btn(
        right,
        fn() { if @sf.theme().dark { "Switch to Light" } else { "Switch to Dark" } },
        fn() { @sf.set_dark(Some(!@sf.theme().dark)) },
        fn(b) {
          b.pick(fn() { @sf.theme().dark }, at_once=true, fn(ic, d) {
            @sf.icon_node(ic, if d { "moon" } else { "sun" }, 14.0, By(fn() { @sf.theme().p.text })) |> ignore
          })
          b.box(fn(w) {
            w
            .words(By(fn() { if @sf.theme().dark { "Dark" } else { "Light" } }), look=words_look(12.0, weight=500, line=16.0))
            .ink(By(fn() { @sf.theme().p.text }))
            |> ignore
          })
          |> ignore
        },
      )
      // Status indicator (desktop only)
      right.show(fn() { !is_narrow() }, at_once=true, fn(st) {
        st.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(6.0)) |> ignore
        st.box(fn(dot) {
          dot
          .width(Is(Some(6.0)))
          .height(Is(Some(6.0)))
          .radius(Is(3.0))
          .shrink(Is(0.0))
          .ground(By(fn() { @sf.theme().p.accent }))
          |> ignore
        })
        |> ignore
        st.box(fn(w) {
          w
          .words(Is("60 fps · Standard UI"), look=words_look(12.0, weight=500, line=16.0))
          .ink(By(fn() { @sf.theme().p.muted }))
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// Standard Bento card container (`radius: 18`, `0.5pt` hairline, `@sf.theme().p.card`).
#callsite(autofill(loc))
fn bento_card(
  parent : @view.View,
  is_narrow : () -> Bool,
  grow? : Double = 1.0,
  gap? : Double = 12.0,
  body : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(c) {
    c
    .grow(By(fn() { if is_narrow() { 0.0 } else { grow } }))
    .basis(By(fn() { if is_narrow() { None } else { Some(0.0) } }))
    .min_width(Is(Some(0.0)))
    .padding(By(fn() { if is_narrow() { (18.0, 18.0, 18.0, 18.0) } else { (22.0, 18.0, 22.0, 18.0) } }))
    .gap(Is(gap))
    .radius(Is(@sf.row_corner))
    .ground(By(fn() { @sf.theme().p.card }))
    .edge(By(fn() { (0.5, @sf.theme().p.line_strong) }))
    .shadow(By(fn() { (6.0, 2.0, @sf.theme().p.shadow) }))
    |> ignore
    body(c)
  })
  |> ignore
}

///|
/// Section header inside a Bento card: uppercase micro label on left, optional right slot.
#callsite(autofill(loc))
fn card_head(parent : @view.View, title : String, right? : (@view.View) -> Unit, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(r) {
    r.row(Is(true)).lies_along(Is(Between)).lines_up(Is(Some(Middle))) |> ignore
    r.box(fn(w) {
      w
      .words(Is(title), look=words_look(11.0, weight=600, line=16.0, tracking=0.9))
      .ink(By(fn() { @sf.theme().p.muted }))
      |> ignore
    })
    |> ignore
    match right {
      Some(f) => f(r)
      None => ()
    }
  })
  |> ignore
}

///|
/// Shared interactive state across the 3 scenes of `STANDARD STAGE`.
priv struct StageState {
  scene : @signals.Signal[Int]
  tag_field : @ui.Field
  filter_field : @ui.Field
  specimen_field : @ui.Field
  platforms : Array[(String, @signals.Signal[Bool])]
  channel : @signals.Signal[Int]
  jobs : @signals.Signal[Double]
  minify : @signals.Signal[Bool]
  strict : @signals.Signal[Bool]
  progress : @signals.Signal[Double]
  queued : @signals.Signal[Int]
  toasts : @signals.Signal[Array[@sf.Toast]]
  toast_seq : Ref[Int]
  confirm_open : @signals.Signal[Bool]
  confirm_danger : @signals.Signal[Bool]
  confirm_title : @signals.Signal[String]
  confirm_words : @signals.Signal[String]
  confirm_action : @signals.Signal[String]
  dialog_status : @signals.Signal[String]
  menu_open : @signals.Signal[Bool]
  menu_anchor : Ref[@view.View?]
  backends : Array[(String, @signals.Signal[Bool])]
}

///|
fn StageState::new(first_scene : Int) -> StageState {
  let tag_field = @ui.Field::new()
  tag_field.set("ui.monoid@0.2.0")
  let filter_field = @ui.Field::new()
  let specimen_field = @ui.Field::new()
  specimen_field.set("OKLCH token preview")
  {
    scene: @signals.signal(first_scene),
    tag_field,
    filter_field,
    specimen_field,
    platforms: [
      ("macOS", @signals.signal(true)),
      ("iOS", @signals.signal(true)),
      ("Android", @signals.signal(true)),
      ("Windows", @signals.signal(false)),
      ("Linux", @signals.signal(true)),
      ("WebGL 2", @signals.signal(true)),
    ],
    channel: @signals.signal(0),
    jobs: @signals.signal(8.0),
    minify: @signals.signal(true),
    strict: @signals.signal(true),
    progress: @signals.signal(0.35),
    queued: @signals.signal(2),
    toasts: @signals.signal([]),
    toast_seq: Ref(0),
    confirm_open: @signals.signal(false),
    confirm_danger: @signals.signal(false),
    confirm_title: @signals.signal("Publish ui.monoid Release"),
    confirm_words: @signals.signal("Publish the verified bundles to all selected native GPU targets and WebGL 2."),
    confirm_action: @signals.signal("Publish"),
    dialog_status: @signals.signal("Awaiting action"),
    menu_open: @signals.signal(false),
    menu_anchor: Ref(None),
    backends: [
      ("Metal", @signals.signal(true)),
      ("WebGL 2", @signals.signal(true)),
      ("Vulkan", @signals.signal(false)),
      ("D3D11", @signals.signal(true)),
    ],
  }
}

///|
fn StageState::push_toast(self : StageState, title : String, description? : String = "", action? : String = "") -> Unit {
  self.toast_seq.val += 1
  let id = "std-toast-\{self.toast_seq.val}"
  let next = self.toasts.untracked().copy()
  next.push(@sf.toast(id, title, description~, action~))
  while next.length() > 3 {
    next.remove(0) |> ignore
  }
  self.toasts.set(next)
}

///|
fn StageState::dismiss_toast(self : StageState, id : String) -> Unit {
  let next = self.toasts.untracked().filter(fn(t) { t.id != id })
  self.toasts.set(next)
}

///|
fn StageState::active_platform_count(self : StageState) -> Int {
  let mut n = 0
  for p in self.platforms {
    if p.1.get() {
      n += 1
    }
  }
  n
}

///|
fn StageState::channel_name(self : StageState) -> String {
  match self.channel.get() {
    1 => "Beta"
    2 => "Canary"
    _ => "Stable"
  }
}

///|
fn StageState::open_confirm(
  self : StageState,
  title : String,
  words : String,
  action : String,
  danger : Bool,
) -> Unit {
  self.confirm_title.set(title)
  self.confirm_words.set(words)
  self.confirm_action.set(action)
  self.confirm_danger.set(danger)
  self.confirm_open.set(true)
}

///|
/// Render filtered platform toggle chips (helper keeps `pick` bodies loop-free for detlint).
#callsite(autofill(loc))
fn platform_chips_row(parent : @view.View, st : StageState, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(row) {
    row.row(Is(true)).wraps(Is(Some(6.0))).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
    for p in st.platforms {
      let (name, sig) = p
      let lower = name.to_lower()
      let matches = fn() {
        let q = st.filter_field.text().trim(chars=" ").to_lower()
        q == "" || lower.contains(q)
      }
      row.show(matches, at_once=true, fn(slot) {
        @sf.toggle_chip_node(
          slot,
          fn() { name },
          fn() { sig.get() },
          fn() { sig.set(!sig.untracked()) },
        )
        |> ignore
      })
    }
  })
  |> ignore
}

///|
/// Scene 0: `Controls` — Release Workbench (2-column Bento on desktop, single-column stacked on narrow viewports).
#callsite(autofill(loc))
fn scene_controls(
  parent : @view.View,
  st : StageState,
  tips : @sf.TipLayer,
  is_narrow : () -> Bool,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(grid) {
    grid.row(By(fn() { !is_narrow() })).gap(Is(16.0)).width_share(Is(1.0)) |> ignore
    // Left Card: Inputs & Selection
    bento_card(grid, is_narrow, grow=1.05, gap=12.0, fn(left) {
      card_head(left, "INPUTS & SELECTION", right=fn(r) {
        @sf.badge_node(r, fn() { "\{st.active_platform_count()} / 6 targets" }, tone=Accented) |> ignore
      })
      // 1. Editable release tag input
      left.box(fn(f) {
        f.gap(Is(6.0)) |> ignore
        f.box(fn(l) {
          l
          .words(Is("Release Tag"), look=words_look(12.0, weight=500, line=16.0))
          .ink(By(fn() { @sf.theme().p.muted }))
          |> ignore
        })
        |> ignore
        @sf.input_node(
          f,
          st.tag_field,
          placeholder="ui.monoid@0.2.0",
          label="Release Tag",
          solid=true,
        )
        |> ignore
      })
      |> ignore
      // 2. Live search filter + toggle chips
      left.box(fn(f) {
        f.gap(Is(8.0)) |> ignore
        @sf.search_input_node(
          f,
          st.filter_field,
          fn() { "Filter targets (macOS, WebGL…)" },
        )
        |> ignore
        platform_chips_row(f, st)
      })
      |> ignore
      // 3. Channel segmented control
      left.box(fn(r) {
        r.row(Is(true)).wraps(Is(Some(8.0))).lies_along(Is(Between)).lines_up(Is(Some(Middle))).gap(Is(12.0)) |> ignore
        r.box(fn(l) {
          l
          .words(Is("Channel"), look=words_look(13.0, weight=500, line=18.0))
          .ink(By(fn() { @sf.theme().p.text }))
          |> ignore
        })
        |> ignore
        @sf.seg_node(
          r,
          fn() { ["Stable", "Beta", "Canary"] },
          fn() { st.channel.get() },
          fn(i) { st.channel.set(i) },
          item_w=78.0,
          said="Release Channel",
        )
        |> ignore
      })
      |> ignore
      // 4. Value slider
      left.box(fn(s) {
        s.gap(Is(4.0)) |> ignore
        s.box(fn(sh) {
          sh.row(Is(true)).lies_along(Is(Between)).lines_up(Is(Some(Middle))) |> ignore
          sh.box(fn(l) {
            l
            .words(Is("Parallel Jobs"), look=words_look(13.0, weight=500, line=18.0))
            .ink(By(fn() { @sf.theme().p.text }))
            |> ignore
          })
          |> ignore
          sh.box(fn(val) {
            val
            .words(By(fn() { "\{st.jobs.get().round().to_int()} workers" }), look=words_look(12.0, weight=600, line=16.0))
            .ink(By(fn() { @sf.theme().p.accent_text }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        @sf.value_slider_node(
          s,
          fn() { "Parallel Jobs" },
          fn() { st.jobs.get() },
          fn(v) { st.jobs.set(v) },
          min=1.0,
          max=16.0,
          step=1.0,
          format=fn(n) { "\{n}" },
          tips~,
        )
        |> ignore
      })
      |> ignore
      // 5. Switch rows
      left.box(fn(sws) {
        sws.row(Is(true)).wraps(Is(Some(10.0))).gap(Is(24.0)).lines_up(Is(Some(Middle))) |> ignore
        sws.box(fn(r1) {
          r1.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
          @sf.switch_node(
            r1,
            fn() { st.minify.get() },
            fn(v) { st.minify.set(v) },
            fn() { "Minify Wasm" },
            small=true,
          )
          r1.box(fn(w) {
            w.words(Is("Minify Wasm"), look=words_look(13.0, weight=500, line=18.0)).ink(By(fn() { @sf.theme().p.text }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        sws.box(fn(r2) {
          r2.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
          @sf.switch_node(
            r2,
            fn() { st.strict.get() },
            fn(v) { st.strict.set(v) },
            fn() { "Strict Audit" },
            small=true,
          )
          r2.box(fn(w) {
            w.words(Is("Strict Audit"), look=words_look(13.0, weight=500, line=18.0)).ink(By(fn() { @sf.theme().p.text }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    // Right Card: Actions & Telemetry
    bento_card(grid, is_narrow, grow=0.95, gap=12.0, fn(right) {
      card_head(right, "ACTIONS & TELEMETRY", right=fn(r) {
        r.pick(fn() { st.channel.get() }, at_once=true, fn(slot, ch) {
          let tone : @sf.PillTone = match ch {
            1 => Blue
            2 => Amber
            _ => Green
          }
          let label = match ch {
            1 => "Beta"
            2 => "Canary"
            _ => "Stable"
          }
          @sf.pill_node(slot, fn() { label }, tone~) |> ignore
        })
      })
      // Live release preview sub-card
      right.box(fn(preview) {
        preview
        .padding(Is((16.0, 14.0, 16.0, 14.0)))
        .gap(Is(8.0))
        .radius(Is(@sf.small_corner))
        .ground(By(fn() { @sf.theme().p.card2 }))
        .edge(By(fn() { (0.5, @sf.theme().p.line) }))
        |> ignore
        preview.box(fn(top) {
          top.row(Is(true)).wraps(Is(Some(6.0))).lies_along(Is(Between)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
          top.box(fn(title) {
            title
            .words(
              By(fn() {
                let s = st.tag_field.text().trim(chars=" ").to_owned()
                if s == "" { "ui.monoid@0.2.0" } else { s }
              }),
              look=words_look(16.0, weight=600, line=22.0),
            )
            .ink(By(fn() { @sf.theme().p.text }))
            |> ignore
          })
          |> ignore
          top.box(fn(q) {
            q.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
            @sf.count_badge_node(q, count=fn() { st.queued.get() }, look=Inline, tone=CountAccent) |> ignore
            q.box(fn(w) {
              w.words(Is("queued"), look=words_look(12.0, weight=500, line=16.0)).ink(By(fn() { @sf.theme().p.muted }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        preview.box(fn(meta) {
          meta.row(Is(true)).wraps(Is(Some(6.0))).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
          @sf.badge_node(meta, fn() { "\{st.active_platform_count()} platforms" }, tone=Neutral) |> ignore
          @sf.badge_node(meta, fn() { "\{st.jobs.get().round().to_int()} jobs" }, tone=Neutral) |> ignore
          @sf.badge_node(meta, fn() { if st.minify.get() { "Wasm minified" } else { "Wasm debug" } }, tone=Blue)
          |> ignore
          @sf.badge_node(meta, fn() { if st.strict.get() { "Audit strict" } else { "Audit relaxed" } }, tone=Green)
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Progress bar block
      right.box(fn(prog) {
        prog.gap(Is(8.0)) |> ignore
        prog.box(fn(ph) {
          ph.row(Is(true)).lies_along(Is(Between)).lines_up(Is(Some(Middle))) |> ignore
          ph.box(fn(l) {
            l.words(Is("Pipeline Progress"), look=words_look(13.0, weight=500, line=18.0)).ink(By(fn() { @sf.theme().p.text }))
            |> ignore
          })
          |> ignore
          ph.box(fn(pct) {
            pct
            .words(By(fn() { "\{(st.progress.get() * 100.0).round().to_int()}%" }), look=words_look(13.0, weight=600, line=18.0))
            .ink(By(fn() { @sf.theme().p.accent_text }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        @sf.progress_node(
          prog,
          fn() { Some(st.progress.get()) },
          fn() { @sf.theme().p.line_strong },
          fn() { @sf.theme().p.accent },
          h=6.0,
        )
        |> ignore
        prog.box(fn(cap) {
          cap
          .words(
            By(fn() {
              let p = st.progress.get()
              if p >= 0.99 {
                "Build verified on all targets — ready to publish"
              } else if p > 0.4 {
                "Compiling native GPU shaders and Wasm bundle…"
              } else {
                "Idle — click Run Build to step the pipeline"
              }
            }),
            look=words_look(12.0, weight=400, line=16.0, wrap=true),
          )
          .ink(By(fn() { @sf.theme().p.muted }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Four-variant Button Deck
      right.box(fn(btns) {
        btns.gap(Is(10.0)) |> ignore
        btns.box(fn(r1) {
          r1.row(Is(true)).gap(Is(10.0)) |> ignore
          r1.box(fn(c1) {
            c1.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
            @sf.button_node(
              c1,
              fn() { "Run Build" },
              fn() {
                let cur = st.progress.untracked()
                let next = if cur >= 0.99 { 0.25 } else if cur + 0.25 > 1.0 { 1.0 } else { cur + 0.25 }
                st.progress.set(next)
                let pct = (next * 100.0).round().to_int()
                let tag = st.tag_field.text().trim(chars=" ").to_owned()
                let name = if tag == "" { "ui.monoid@0.2.0" } else { tag }
                st.push_toast("Build \{pct}% — \{name}", description="\{st.channel_name()} · \{st.active_platform_count()} targets")
              },
              tone=Primary,
              icon="play",
              across=true,
            )
            |> ignore
          })
          |> ignore
          r1.box(fn(c2) {
            c2.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
            @sf.button_node(
              c2,
              fn() { "Queue Job" },
              fn() {
                let n = st.queued.untracked() + 1
                st.queued.set(n)
                st.push_toast("Queued job #\{n}", description="\{st.jobs.untracked().round().to_int()} parallel workers")
              },
              tone=Plain,
              icon="plus",
              across=true,
            )
            |> ignore
          })
          |> ignore
        })
        |> ignore
        btns.box(fn(r2) {
          r2.row(Is(true)).gap(Is(10.0)) |> ignore
          r2.box(fn(c3) {
            c3.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
            @sf.button_node(
              c3,
              fn() { "Reset" },
              fn() {
                st.progress.set(0.35)
                st.queued.set(2)
                st.push_toast("Workbench reset", description="Progress 35% · 2 jobs queued")
              },
              tone=Ghost,
              icon="refresh",
              across=true,
            )
            |> ignore
          })
          |> ignore
          r2.box(fn(c4) {
            c4.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
            @sf.button_node(
              c4,
              fn() { "Publish…" },
              fn() {
                let tag = st.tag_field.text().trim(chars=" ").to_owned()
                let name = if tag == "" { "ui.monoid@0.2.0" } else { tag }
                st.open_confirm(
                  "Publish \{name}?",
                  "Release to the \{st.channel_name()} channel across \{st.active_platform_count()} selected GPU targets.",
                  "Publish Release",
                  true,
                )
              },
              tone=Danger,
              icon="upload",
              across=true,
            )
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Semantic status pills & count mark
      right.box(fn(pills) {
        pills.row(Is(true)).wraps(Is(Some(8.0))).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
        @sf.pill_node(pills, fn() { "0 Audit Faults" }, tone=Green, icon="check-circle") |> ignore
        @sf.pill_node(pills, fn() { "OKLCH Locked" }, tone=Accented) |> ignore
        @sf.pill_node(pills, fn() { "WebGL 2" }, tone=Blue) |> ignore
        @sf.count_badge_node(pills, count=fn() { st.queued.get() }, look=Mark, tone=CountRed) |> ignore
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// Large accent theme pill button for the `Tokens` scene.
#callsite(autofill(loc))
fn theme_swatch_pill(parent : @view.View, key : String, name : String, loc~ : SourceLoc) -> Unit {
  @headless.button(made_for=loc, parent, fn() { "Theme " + name }, fn(_) { @sf.set_accent(key) }, fn(b, _btn) {
    let active = fn() { @sf.accent_key() == key }
    b
    .focus_ring_theme()
    .row(Is(true))
    .height(Is(Some(32.0)))
    .padding(Is((10.0, 0.0, 10.0, 0.0)))
    .gap(Is(6.0))
    .radius(Is(16.0))
    .lines_up(Is(Some(Middle)))
    .ground(By(fn() {
      let p = @sf.theme().p
      if active() { p.selected } else { p.card2 }
    }))
    .edge(By(fn() {
      if active() {
        (1.0, @sf.theme().p.accent)
      } else {
        (0.5, @sf.theme().p.line_strong)
      }
    }))
    |> ignore
    @sf.hover_ground_node(b)
    b.box(fn(dot) {
      dot
      .width(Is(Some(12.0)))
      .height(Is(Some(12.0)))
      .radius(Is(6.0))
      .ground(By(fn() { accent_swatch_color(key) }))
      |> ignore
    })
    |> ignore
    b.box(fn(w) {
      w
      .words(Is(name), look=words_look(12.0, weight=500, line=16.0))
      .ink(By(fn() { if active() { @sf.theme().p.accent_text } else { @sf.theme().p.text } }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Single color token swatch tile inside the Surface & Contrast Ladder.
#callsite(autofill(loc))
fn token_tile(parent : @view.View, name : String, role : String, color : () -> Int64, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(t) {
    t
    .grow(Is(1.0))
    .basis(Is(Some(0.0)))
    .min_width(Is(Some(0.0)))
    .padding(Is((10.0, 10.0, 10.0, 10.0)))
    .gap(Is(6.0))
    .radius(Is(@sf.small_corner))
    .ground(By(fn() { @sf.theme().p.card2 }))
    .edge(By(fn() { (0.5, @sf.theme().p.line) }))
    |> ignore
    t.box(fn(sw) {
      sw
      .height(Is(Some(38.0)))
      .radius(Is(6.0))
      .ground(By(color))
      .edge(By(fn() { (0.5, @sf.theme().p.line_strong) }))
      |> ignore
    })
    |> ignore
    t.box(fn(meta) {
      meta.gap(Is(1.0)) |> ignore
      meta.box(fn(w) {
        w.words(Is(name), look=words_look(12.0, weight=600, line=16.0)).ink(By(fn() { @sf.theme().p.text })) |> ignore
      })
      |> ignore
      meta.box(fn(h) {
        h
        .words(By(fn() { hex_of(color()) }), look=words_look(11.0, weight=500, line=14.0))
        .ink(By(fn() { @sf.theme().p.muted }))
        |> ignore
      })
      |> ignore
      meta.box(fn(r) {
        r.words(Is(role), look=words_look(10.0, weight=400, line=14.0)).ink(By(fn() { @sf.theme().p.subtle })) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Scene 1: `Tokens` — OKLCH Accent & Surface Ladder + Live Component Specimen.
#callsite(autofill(loc))
fn scene_tokens(
  parent : @view.View,
  st : StageState,
  is_narrow : () -> Bool,
  is_phone : () -> Bool,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(col) {
    col.gap(Is(16.0)).width_share(Is(1.0)) |> ignore
    // Top palette selector strip
    col.box(fn(strip) {
      strip
      .row(By(fn() { !is_narrow() }))
      .lies_along(By(fn() { if is_narrow() { Start } else { Between } }))
      .lines_up(By(fn() { if is_narrow() { None } else { Some(Middle) } }))
      .gap(Is(10.0))
      .padding(By(fn() { if is_narrow() { (18.0, 16.0, 18.0, 18.0) } else { (20.0, 12.0, 20.0, 12.0) } }))
      .radius(Is(@sf.row_corner))
      .ground(By(fn() { @sf.theme().p.card }))
      .edge(By(fn() { (0.5, @sf.theme().p.line_strong) }))
      .shadow(By(fn() { (4.0, 1.0, @sf.theme().p.shadow) }))
      |> ignore
      strip.box(fn(info) {
        info.gap(Is(2.0)) |> ignore
        info.box(fn(t) {
          t
          .words(Is("OKLCH ACCENT & SURFACE SYSTEM"), look=words_look(11.0, weight=600, line=16.0, tracking=0.9))
          .ink(By(fn() { @sf.theme().p.muted }))
          |> ignore
        })
        |> ignore
        info.box(fn(sub) {
          sub
          .words(
            Is("Switch accent or appearance to recompute every surface ramp instantaneously."),
            look=words_look(13.0, weight=400, line=18.0, wrap=true),
          )
          .ink(By(fn() { @sf.theme().p.text }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      strip.box(fn(swatches) {
        swatches.row(Is(true)).wraps(Is(Some(8.0))).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
        theme_swatch_pill(swatches, "", "Vermilion")
        theme_swatch_pill(swatches, "blue", "Blue")
        theme_swatch_pill(swatches, "teal", "Teal")
        theme_swatch_pill(swatches, "purple", "Purple")
        theme_swatch_pill(swatches, "pink", "Pink")
      })
      |> ignore
    })
    |> ignore
    // Two-column body: Surface & Contrast Ladder | Live Component Specimen
    col.box(fn(split) {
      split.row(By(fn() { !is_narrow() })).gap(Is(16.0)).width_share(Is(1.0)) |> ignore
      bento_card(split, is_narrow, grow=1.18, gap=12.0, fn(left) {
        card_head(left, "SURFACE & CONTRAST LADDER", right=fn(r) {
          @sf.badge_node(r, fn() { if @sf.theme().dark { "Dark Ramp" } else { "Light Ramp" } }, tone=Accented)
          |> ignore
        })
        left.pick(is_phone, at_once=true, fn(slot, phone) {
          slot.gap(Is(10.0)) |> ignore
          if phone {
            slot.box(fn(r1) {
              r1.row(Is(true)).gap(Is(10.0)) |> ignore
              token_tile(r1, "bg", "Page", fn() { @sf.theme().p.bg })
              token_tile(r1, "canvas", "Canvas", fn() { @sf.theme().p.canvas })
            })
            |> ignore
            slot.box(fn(r2) {
              r2.row(Is(true)).gap(Is(10.0)) |> ignore
              token_tile(r2, "raised", "Raised", fn() { @sf.theme().p.raised })
              token_tile(r2, "card", "Card", fn() { @sf.theme().p.card })
            })
            |> ignore
            slot.box(fn(r3) {
              r3.row(Is(true)).gap(Is(10.0)) |> ignore
              token_tile(r3, "chip", "Chip", fn() { @sf.theme().p.chip })
              token_tile(r3, "selected", "Selected", fn() { @sf.theme().p.selected })
            })
            |> ignore
            slot.box(fn(r4) {
              r4.row(Is(true)).gap(Is(10.0)) |> ignore
              token_tile(r4, "accent", "Accent", fn() { @sf.theme().p.accent })
              token_tile(r4, "line_strong", "0.5pt Edge", fn() { @sf.theme().p.line_strong })
            })
            |> ignore
          } else {
            slot.box(fn(r1) {
              r1.row(Is(true)).gap(Is(10.0)) |> ignore
              token_tile(r1, "bg", "Page", fn() { @sf.theme().p.bg })
              token_tile(r1, "canvas", "Canvas", fn() { @sf.theme().p.canvas })
              token_tile(r1, "raised", "Raised", fn() { @sf.theme().p.raised })
              token_tile(r1, "card", "Card", fn() { @sf.theme().p.card })
            })
            |> ignore
            slot.box(fn(r2) {
              r2.row(Is(true)).gap(Is(10.0)) |> ignore
              token_tile(r2, "chip", "Chip", fn() { @sf.theme().p.chip })
              token_tile(r2, "selected", "Selected", fn() { @sf.theme().p.selected })
              token_tile(r2, "accent", "Accent", fn() { @sf.theme().p.accent })
              token_tile(r2, "line_strong", "0.5pt Edge", fn() { @sf.theme().p.line_strong })
            })
            |> ignore
          }
        })
      })
      bento_card(split, is_narrow, grow=0.82, gap=12.0, fn(right) {
        card_head(right, "LIVE COMPONENT SPECIMEN", right=fn(r) {
          @sf.pill_node(r, fn() { if @sf.accent_key() == "" { "vermilion" } else { @sf.accent_key() } }, tone=Accented)
          |> ignore
        })
        right.box(fn(brow) {
          brow.row(Is(true)).gap(Is(10.0)) |> ignore
          brow.box(fn(c1) {
            c1.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
            @sf.button_node(
              c1,
              fn() { "Primary Action" },
              fn() { st.push_toast("Token specimen clicked", description="Accent: " + (if @sf.accent_key() == "" { "vermilion" } else { @sf.accent_key() })) },
              tone=Primary,
              across=true,
            )
            |> ignore
          })
          |> ignore
          brow.box(fn(c2) {
            c2.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
            @sf.button_node(
              c2,
              fn() { "Secondary" },
              fn() { @sf.set_dark(Some(!@sf.theme().dark)) },
              tone=Plain,
              across=true,
            )
            |> ignore
          })
          |> ignore
        })
        |> ignore
        @sf.input_node(
          right,
          st.specimen_field,
          placeholder="Token specimen input",
          label="Token Specimen Input",
          solid=true,
        )
        |> ignore
        right.box(fn(srow) {
          srow.row(Is(true)).wraps(Is(Some(8.0))).lies_along(Is(Between)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
          srow.box(fn(l) {
            l.words(Is("Appearance"), look=words_look(13.0, weight=500, line=18.0)).ink(By(fn() { @sf.theme().p.text }))
            |> ignore
          })
          |> ignore
          @sf.seg_node(
            srow,
            fn() { ["Light", "Dark"] },
            fn() { if @sf.theme().dark { 1 } else { 0 } },
            fn(i) { @sf.set_dark(Some(i == 1)) },
            item_w=86.0,
            said="Specimen Appearance",
          )
          |> ignore
        })
        |> ignore
        right.box(fn(trow) {
          trow.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))).wraps(Is(Some(8.0))) |> ignore
          @sf.switch_node(
            trow,
            fn() { st.minify.get() },
            fn(v) { st.minify.set(v) },
            fn() { "Specimen Toggle" },
            small=true,
          )
          @sf.toggle_chip_node(
            trow,
            fn() { "Active Chip" },
            fn() { st.strict.get() },
            fn() { st.strict.set(!st.strict.untracked()) },
          )
          |> ignore
          @sf.pill_node(trow, fn() { "Contrast >= 4.5:1" }, tone=Green) |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// Selected GPU backend badges (helper keeps loops out of `pick`).
#callsite(autofill(loc))
fn backend_badges_row(parent : @view.View, st : StageState, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(row) {
    row.row(Is(true)).wraps(Is(Some(6.0))).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
    for b in st.backends {
      let (name, sig) = b
      row.show(fn() { sig.get() }, at_once=true, fn(slot) {
        @sf.badge_node(slot, fn() { name }, tone=Accented) |> ignore
      })
    }
  })
  |> ignore
}

///|
/// Keycap badge for keyboard shortcut display.
#callsite(autofill(loc))
fn kbd_cap(parent : @view.View, keys : String, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(k) {
    k
    .height(Is(Some(24.0)))
    .padding(Is((8.0, 0.0, 8.0, 0.0)))
    .radius(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() { @sf.theme().p.card2 }))
    .edge(By(fn() { (0.5, @sf.theme().p.line_strong) }))
    |> ignore
    k.box(fn(w) {
      w.words(Is(keys), look=words_look(11.0, weight=600, line=16.0)).ink(By(fn() { @sf.theme().p.muted })) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Scene 2: `Overlays` — 2x2 interactive bench for Dropdown Menu, Modal Confirm, Toast Queue & Hover Tooltips.
#callsite(autofill(loc))
fn scene_overlays(
  parent : @view.View,
  st : StageState,
  tips : @sf.TipLayer,
  is_narrow : () -> Bool,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(col) {
    col.gap(Is(16.0)).width_share(Is(1.0)) |> ignore
    // Top row: Dropdown Menu | Modal Confirm Dialog
    col.box(fn(r1) {
      r1.row(By(fn() { !is_narrow() })).gap(Is(16.0)).width_share(Is(1.0)) |> ignore
      // 1. Dropdown Menu
      bento_card(r1, is_narrow, grow=1.0, gap=10.0, fn(c) {
        card_head(c, "DROPDOWN MENU", right=fn(r) {
          @sf.badge_node(r, fn() { "@sf.menu_ticks_node" }, tone=Neutral) |> ignore
        })
        c.box(fn(desc) {
          desc
          .words(
            Is("Roving-focus menu anchored to its trigger with multi-select checkmarks and keyboard navigation."),
            look=words_look(13.0, weight=400, line=18.0, wrap=true),
          )
          .ink(By(fn() { @sf.theme().p.muted }))
          |> ignore
        })
        |> ignore
        c.box(fn(act) {
          act.row(Is(true)).wraps(Is(Some(8.0))).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
          @sf.button_opens_node(
            act,
            fn() { "Configure Backends" },
            fn(anchor) {
              st.menu_anchor.val = Some(anchor)
              st.menu_open.set(true)
            },
            tone=Plain,
            icon="sliders",
          )
          |> ignore
          backend_badges_row(act, st)
        })
        |> ignore
      })
      // 2. Modal Confirm Dialog
      bento_card(r1, is_narrow, grow=1.0, gap=10.0, fn(c) {
        card_head(c, "MODAL CONFIRM DIALOG", right=fn(r) {
          @sf.badge_node(r, fn() { "@sf.confirm_node" }, tone=Neutral) |> ignore
        })
        c.box(fn(desc) {
          desc
          .words(
            Is("Focus-trapping alert dialog with animated backdrop scrim, Escape dismissal, and primary/danger tones."),
            look=words_look(13.0, weight=400, line=18.0, wrap=true),
          )
          .ink(By(fn() { @sf.theme().p.muted }))
          |> ignore
        })
        |> ignore
        c.box(fn(act) {
          act.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))).wraps(Is(Some(8.0))) |> ignore
          @sf.button_node(
            act,
            fn() { "Open Confirm Dialog" },
            fn() {
              st.open_confirm(
                "Deploy Standard UI Bundle?",
                "Confirming will build and sign the retained-tree package for all six native GPU targets.",
                "Deploy Now",
                false,
              )
            },
            tone=Primary,
          )
          |> ignore
          @sf.button_node(
            act,
            fn() { "Danger Confirm" },
            fn() {
              st.open_confirm(
                "Purge Build Cache?",
                "This clears all cached shader objects and triggers a clean rebuild on the next run.",
                "Purge Cache",
                true,
              )
            },
            tone=Danger,
          )
          |> ignore
          @sf.pill_node(act, fn() { st.dialog_status.get() }, tone=Blue) |> ignore
        })
        |> ignore
      })
    })
    |> ignore
    // Bottom row: Toast Queue | Hover Tooltips & Keyboard Focus
    col.box(fn(r2) {
      r2.row(By(fn() { !is_narrow() })).gap(Is(16.0)).width_share(Is(1.0)) |> ignore
      // 3. Toast Queue
      bento_card(r2, is_narrow, grow=1.0, gap=10.0, fn(c) {
        card_head(c, "TOAST QUEUE", right=fn(r) {
          @sf.badge_node(r, fn() { "@sf.toaster_node" }, tone=Neutral) |> ignore
        })
        c.box(fn(desc) {
          desc
          .words(
            Is("Stacked GPU-animated notifications with hover-pause, swipe dismissal, and inline action callbacks."),
            look=words_look(13.0, weight=400, line=18.0, wrap=true),
          )
          .ink(By(fn() { @sf.theme().p.muted }))
          |> ignore
        })
        |> ignore
        c.box(fn(act) {
          act.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))).wraps(Is(Some(8.0))) |> ignore
          @sf.button_node(
            act,
            fn() { "Info Toast" },
            fn() { st.push_toast("Shader cache warm", description="6 backends compiled in 142 ms") },
            tone=Plain,
            icon="info",
          )
          |> ignore
          @sf.button_node(
            act,
            fn() { "Success Toast" },
            fn() { st.push_toast("Audit passed (0 faults)", description="60 / 120 / 24 / 7 fps invariant") },
            tone=Primary,
            icon="check",
          )
          |> ignore
          @sf.button_node(
            act,
            fn() { "Action Toast" },
            fn() { st.push_toast("Bundle archived", description="standard-ui-0.2.0.tar.gz", action="Undo") },
            tone=Ghost,
            icon="bell",
          )
          |> ignore
        })
        |> ignore
      })
      // 4. Hover Tooltips & Keyboard Focus
      bento_card(r2, is_narrow, grow=1.0, gap=10.0, fn(c) {
        card_head(c, "HOVER TOOLTIPS & FOCUS", right=fn(r) {
          @sf.badge_node(r, fn() { "@sf.tip_node" }, tone=Neutral) |> ignore
        })
        c.box(fn(desc) {
          desc
          .words(
            Is("Shared TipLayer with warm handoff glide across sibling controls and high-contrast B2 keyboard focus rings."),
            look=words_look(13.0, weight=400, line=18.0, wrap=true),
          )
          .ink(By(fn() { @sf.theme().p.muted }))
          |> ignore
        })
        |> ignore
        c.box(fn(act) {
          act.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))).wraps(Is(Some(8.0))) |> ignore
          let c1 = @sf.chip_node(
            act,
            fn() { "Command Palette" },
            fn() { st.push_toast("Command Palette", description="Triggered via chip (⌘K)") },
            icon="search",
            said=fn() { "Open Command Palette (⌘K)" },
            tips~,
          )
          c1 |> ignore
          let c2 = @sf.chip_node(
            act,
            fn() { "Run Release" },
            fn() { st.push_toast("Release Pipeline", description="Triggered via chip (⌘⏎)") },
            icon="play",
            said=fn() { "Run Release Pipeline (⌘⏎)" },
            tips~,
          )
          c2 |> ignore
          let c3 = @sf.chip_node(
            act,
            fn() { "Inspect Tree" },
            fn() { st.push_toast("Tree Inspector", description="Triggered via chip (⌘I)") },
            icon="terminal",
            said=fn() { "Inspect Retained Tree (⌘I)" },
            tips~,
          )
          c3 |> ignore
        })
        |> ignore
        c.box(fn(kbds) {
          kbds.row(Is(true)).wraps(Is(Some(6.0))).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
          kbds.box(fn(l) {
            l.words(Is("Shortcuts"), look=words_look(12.0, weight=500, line=16.0)).ink(By(fn() { @sf.theme().p.muted }))
            |> ignore
          })
          |> ignore
          kbd_cap(kbds, "⌘K")
          kbd_cap(kbds, "⌘⏎")
          kbd_cap(kbds, "⌘I")
          kbd_cap(kbds, "Tab")
        })
        |> ignore
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// Build `ui.monoid · STANDARD STAGE` inside `root`.
/// `first_scene`: `0` (Controls), `1` (Tokens), or `2` (Overlays).
#callsite(autofill(loc))
pub fn studio(root : @view.View, first_scene? : Int = 0, loc~ : SourceLoc) -> Unit {
  @sf.set_language(Some("en"))
  @sf.set_product("ui.monoid")
  @ui.set_tree_theme(@sf.ui_theme_now)
  let st = StageState::new(first_scene)
  let tip_host : Ref[@view.View?] = Ref(None)
  let tips = @sf.TipLayer::new(fn() { tip_host.val })

  let body_scroll = @view.Scroll::new()

  root.box(made_for=loc, fn(stage) {
    stage.grow(Is(1.0)).clips(Is(true)) |> ignore
    // 1. Neutral architectural backdrop with 80pt hairline grid
    stage_backdrop(stage)

    // 2. Responsive viewport shell (top bar + scene content + pinned bottom 3-scene switcher)
    let is_narrow = fn() {
      let w = stage.window_w()
      w > 0.0 && w < 760.0
    }
    let is_phone = fn() {
      let w = stage.window_w()
      w > 0.0 && w < 520.0
    }
    let hide_stage_tag = fn() {
      let w = stage.window_w()
      w > 0.0 && w < 480.0
    }
    let compact_dock = fn() {
      let w = stage.window_w()
      w > 0.0 && w < 390.0
    }

    let draw_scene = fn(slot : @view.View, idx : Int) {
      slot.width_share(Is(1.0)) |> ignore
      match idx {
        1 => scene_tokens(slot, st, is_narrow, is_phone)
        2 => scene_overlays(slot, st, tips, is_narrow)
        _ => scene_controls(slot, st, tips, is_narrow)
      }
    }

    stage.box(fn(main_col) {
      main_col
      .grow(Is(1.0))
      .min_height(Is(Some(0.0)))
      .padding(By(fn() {
        if is_narrow() {
          (14.0, 10.0, 14.0, 0.0)
        } else {
          (28.0, 14.0, 28.0, 0.0)
        }
      }))
      |> ignore
      studio_bar(main_col, is_narrow, hide_stage_tag)
      main_col.pick(is_narrow, at_once=true, fn(body_slot, narrow) {
        body_slot.grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
        if narrow {
          let sc = body_slot.scrolls(
            body_scroll,
            slop=@ui.touch_slop(),
            bar=@ui.tree_scroll_bar(),
            fn(s) {
              s.padding(Is((0.0, 10.0, 0.0, 84.0))) |> ignore
              s.pick(fn() { st.scene.get() }, at_once=true, draw_scene)
            },
          )
          sc.grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
        } else {
          body_slot.box(fn(body) {
            body
            .grow(Is(1.0))
            .lies_along(Is(Middle))
            .padding(Is((0.0, 10.0, 0.0, 82.0)))
            |> ignore
            body.pick(fn() { st.scene.get() }, at_once=true, draw_scene)
          })
          |> ignore
        }
      })
    })
    |> ignore

    // 3. Mathematically pinned bottom 3-scene switcher (0.00 px jump across all scenes and window sizes)
    stage.box(fn(dock_wrap) {
      dock_wrap
      .over(Is(true))
      .points(Is(false))
      .lies_along(Is(End))
      .lines_up(Is(Some(Middle)))
      .padding(Is((0.0, 0.0, 0.0, 18.0)))
      |> ignore
      dock_wrap.box(fn(dock_shell) {
        dock_shell
        .radius(Is(@sf.segmented_height() / 2.0))
        .ground(By(fn() { @sf.theme().p.raised }))
        .edge(By(fn() { (0.5, @sf.theme().p.line_strong) }))
        .shadow(By(fn() { (12.0, 4.0, @sf.theme().p.shadow) }))
        |> ignore
        dock_shell.pick(compact_dock, at_once=true, fn(slot, compact) {
          @sf.seg_node(
            slot,
            fn() { ["Controls", "Tokens", "Overlays"] },
            fn() { st.scene.get() },
            fn(i) { st.scene.set(i) },
            item_w=if compact { 104.0 } else { 118.0 },
            said="Stage Scene",
          )
          |> ignore
        })
      })
      |> ignore
    })
    |> ignore

    // 4. Global Dropdown Menu layer (for Overlays scene)
    @sf.menu_ticks_node(
      stage,
      fn() { st.menu_open.get() },
      fn(layer) {
        match st.menu_anchor.val {
          Some(a) => {
            let (x, y, w, h) = a.placed_window_now()
            layer.box(fn(box) {
              box.over(Is(true)).offset(Is((x, y))).width(Is(Some(w))).height(Is(Some(h))) |> ignore
            })
          }
          None => layer
        }
      },
      fn() {
        let items : Array[@sf.MenuItem?] = []
        for b in st.backends {
          let (name, sig) = b
          items.push(
            Some(
              @sf.menu_item_of(
                name,
                fn() { sig.set(!sig.untracked()) },
                checked=sig.get(),
              ),
            ),
          )
        }
        items
      },
      "GPU Backends",
      Start,
      6.0,
      false,
      false,
      fn(item) { (item.select)() },
      fn() { st.menu_open.set(false) },
    )

    // 5. Global Modal Confirm Dialog layers (standard & danger variants)
    @sf.confirm_node(
      stage,
      fn() { st.confirm_open.get() && !st.confirm_danger.get() },
      fn() { st.confirm_title.get() },
      fn() { st.confirm_words.get() },
      fn() { st.confirm_action.get() },
      false,
      fn() {
        st.confirm_open.set(false)
        st.dialog_status.set("Cancelled")
      },
      fn() {
        st.confirm_open.set(false)
        st.dialog_status.set("Confirmed")
        st.push_toast(st.confirm_action.untracked() + " confirmed", description="Action completed cleanly")
      },
    )
    @sf.confirm_node(
      stage,
      fn() { st.confirm_open.get() && st.confirm_danger.get() },
      fn() { st.confirm_title.get() },
      fn() { st.confirm_words.get() },
      fn() { st.confirm_action.get() },
      true,
      fn() {
        st.confirm_open.set(false)
        st.dialog_status.set("Cancelled")
      },
      fn() {
        st.confirm_open.set(false)
        st.dialog_status.set("Confirmed")
        st.push_toast(st.confirm_action.untracked() + " confirmed", description="Action completed cleanly")
      },
    )

    // 6. Global TipLayer host
    tip_host.val = Some(
      stage.box(fn(tl) { tl.over(Is(true)).over_all(Is(true)).points(Is(false)) |> ignore }),
    )

    // 7. Global Toaster layer (positioned cleanly above the bottom scene switcher)
    @sf.toaster_node(
      stage,
      fn() { st.toasts.get() },
      fn(_) { 4000.0 },
      fn() { 76.0 },
      fn(id) {
        st.dismiss_toast(id)
        st.push_toast("Action undone", description="Previous operation reverted")
      },
      fn(id) { st.dismiss_toast(id) },
      key="std-stage-toast",
      label="Notifications",
    )
    |> ignore
  })
  |> ignore
}
