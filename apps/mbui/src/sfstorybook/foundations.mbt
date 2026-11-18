// The design's foundations, first in the list before the parts (as Storybook's, Primer's and shadcn/ui's sites open on
// theirs): the palette and the colour themes, the type scale, the corners' concentric ladder, and depth and motion.
// Each is drawn from the library's own tokens as the theme has them now (light or dark, the colour theme chosen in the
// bar, the native input, the system's size of words), never numbers of its own, so what is shown is what the parts are
// drawn in.

///|
/// The foundations' group, as the list names it (and the page's heading over their cards: 标本, not 示例).
let foundations_group : String = "设计基石"

///|
/// The foundations' pages, in the order of the list.
fn foundations() -> Array[Story] {
  [
    {
      key: "palette",
      group: foundations_group,
      name: "色板与主题色 Palette",
      file: "tokens.mbt",
      api: [],
      play: None,
      about: "still.fail 的暖纸底色、文字和语义色，随浅色、深色和顶栏选的主题色实时变化。点一块颜色复制它的名字和色值。",
      cases: [
        ("一眼 At a glance", fn(card) { glance_node(card) }),
        ("纸面与文字 Grounds & Ink", fn(card) { swatches_node(card, grounds_ink) }),
        ("语义色 Semantic", fn(card) { swatches_node(card, semantic_ink) }),
        (
          "主题色 Accents（选一个，整页跟着换）",
          fn(card) {
            accents_node(card)
            accent_swatches_node(card)
          },
        ),
      ],
    },
    {
      key: "type",
      group: foundations_group,
      name: "字阶与排版 Typography",
      file: "styles.mbt",
      api: [],
      play: None,
      about: "各级字号、行高和字重，按原生操控取键鼠的字阶（wide_type）或触控的字阶（narrow_type），再乘上系统字号。",
      cases: [
        ("字阶 Type scale", fn(card) { type_scale_node(card) }),
        ("中英混排 Mixed", fn(card) { mixed_node(card) }),
      ],
    },
    {
      key: "corners",
      group: foundations_group,
      name: "同心圆角 Corners",
      file: "tokens.mbt",
      api: [],
      play: Some(corners_play),
      about: "面板 42、卡片 26、行 18、小块 10：每一级都和外面一级同心，里面的圆角等于外面的圆角减去它离外边的距离（@ui.concentric）。",
      cases: [("同心阶梯 Ladder", fn(card) { ladder_node(card) })],
    },
    {
      key: "depth",
      group: foundations_group,
      name: "光影与动效 Depth & Motion",
      file: "shadow.mbt",
      api: [],
      play: None,
      about: "各级浮层的阴影（按 Android 的高度换算），以及同一段位移在标准缓动和弹簧下的走法。",
      cases: [
        ("阴影 Shadows", fn(card) { shadows_node(card) }),
        ("缓动与弹簧 Motion（按播放对比）", fn(card) { motion_node(card) }),
      ],
    },
  ]
}

// ---------------------------------------------------------------------------
// 色板

///|
/// A token of the palette: its name as the code says it, and its colour in a palette.
priv struct Token {
  name : String
  ink : (@sf.Palette) -> Int64
}

///|
/// The grounds, from the page's to a chip's, and the words' inks.
// kept across runs: a value (no element of it changes)
let grounds_ink : Array[Token] = [
  { name: "bg", ink: fn(p) { p.bg } },
  { name: "canvas", ink: fn(p) { p.canvas } },
  { name: "paper", ink: fn(p) { p.paper } },
  { name: "card", ink: fn(p) { p.card } },
  { name: "raised", ink: fn(p) { p.raised } },
  { name: "sidebar", ink: fn(p) { p.sidebar } },
  { name: "chip", ink: fn(p) { p.chip } },
  { name: "text", ink: fn(p) { p.text } },
  { name: "muted", ink: fn(p) { p.muted } },
  { name: "subtle", ink: fn(p) { p.subtle } },
  { name: "line", ink: fn(p) { p.line } },
  { name: "line_strong", ink: fn(p) { p.line_strong } },
]

///|
/// The accent and the inks that say something: done, failed, a link's, online, a warning's, and their grounds.
// kept across runs: a value (no element of it changes)
let semantic_ink : Array[Token] = [
  { name: "accent", ink: fn(p) { p.accent } },
  { name: "accent_text", ink: fn(p) { p.accent_text } },
  { name: "accent_bg", ink: fn(p) { p.accent_bg } },
  { name: "green", ink: fn(p) { p.green } },
  { name: "green_bg", ink: fn(p) { p.green_bg } },
  { name: "red", ink: fn(p) { p.red } },
  { name: "red_bg", ink: fn(p) { p.red_bg } },
  { name: "blue", ink: fn(p) { p.blue } },
  { name: "blue_bg", ink: fn(p) { p.blue_bg } },
  { name: "amber_bg", ink: fn(p) { p.amber_bg } },
  { name: "warn_ink", ink: fn(p) { p.warn_ink } },
  { name: "online", ink: fn(p) { p.online } },
]

///|
/// A colour as the code and a design tool write it: #RRGGBB, its opacity after it where it has one (#RRGGBBAA).
fn hex_of(c : Int64) -> String {
  let digits = "0123456789ABCDEF".to_array()
  let out = StringBuilder()
  out.write_char('#')
  let shown = if (c & 0xFFL) == 0xFFL { 3 } else { 4 }
  for i in 0..<shown {
    let b = ((c >> (24 - i * 8)) & 0xFFL).to_int()
    out.write_char(digits[b / 16])
    out.write_char(digits[b % 16])
  }
  out.to_string()
}

///|
/// Colours as tiles in rows that go on in another line where they have not the room: each its colour over its name and
/// its value, as the theme draws it now; pressed, its name and value on the clipboard and said so.
fn swatches_node(card : @view.View, tokens : Array[Token]) -> Unit {
  card.box(fn(grid) {
    grid.row(Is(true)).wraps(Is(Some(swatch_gap))).gap(Is(swatch_gap)) |> ignore
    for tok in tokens {
      let ink = fn() { (tok.ink)(@sf.theme().p) }
      swatch_node(grid, fn() { tok.name }, ink)
    }
  })
  |> ignore
}

///|
/// A tile of a colour in `grid`: its colour as a block, its `name` and its value under it; pressed, both copied.
fn swatch_node(grid : @view.View, name : () -> String, ink : () -> Int64) -> Unit {
  grid.box(fn(tile) {
    tile.basis(Is(Some(swatch_w))).grow(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(6.0)).radius(Is(@sf.small_corner)) |> ignore
    let said = fn() { name() + " " + hex_of(ink()) }
    @sf.rippled_node(
      tile,
      fn() {
        let words = @signals.untracked(said)
        @sfbase.copy_out(words, said="已复制 " + words)
      },
      @sf.small_corner,
      fn() { "复制 " + said() },
    )
    tile.box(fn(b) {
      b
      .height(Is(Some(swatch_h)))
      .radius(Is(@sf.small_corner))
      .ground(By(ink))
      .edge(By(fn() { (1.0, @sf.theme().p.line) }))
      |> ignore
    })
    |> ignore
    tile.box(fn(w) {
      w.gap(Is(2.0)) |> ignore
      @sf.words_node(w, name, fn() { swatch_name }) |> ignore
      @sf.words_node(w, fn() { hex_of(ink()) }, fn() { swatch_value }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The colour themes' accents as tiles, each by its name, in its ink as the theme is now (light or dark).
fn accent_swatches_node(card : @view.View) -> Unit {
  card.box(fn(grid) {
    grid.row(Is(true)).wraps(Is(Some(swatch_gap))).gap(Is(swatch_gap)) |> ignore
    for i, a in @sf.accents {
      let ink = fn() { if @sf.theme().dark { a.dark } else { a.light } }
      let name = accent_names.get(i).unwrap_or(a.key)
      swatch_node(grid, fn() { name }, ink)
    }
  })
  |> ignore
}

///|
/// The palette at a glance (its first state, the overview's thumbnail): the page's ground to the words' ink, then the
/// accent and its ground, each a square in a row, as the theme draws them now.
fn glance_node(card : @view.View) -> Unit {
  side_by_side(card, fn(r) {
    for tok in glance {
      r.box(fn(b) {
        b
        .width(Is(Some(glance_side)))
        .height(Is(Some(glance_side)))
        .radius(Is(@sf.small_corner))
        .ground(By(fn() { (tok.ink)(@sf.theme().p) }))
        .edge(By(fn() { (1.0, @sf.theme().p.line) }))
        |> ignore
      })
      |> ignore
    }
  })
}

///|
// kept across runs: a value (no element of it changes)
let glance : Array[Token] = [
  { name: "bg", ink: fn(p) { p.bg } },
  { name: "card", ink: fn(p) { p.card } },
  { name: "chip", ink: fn(p) { p.chip } },
  { name: "line", ink: fn(p) { p.line_strong } },
  { name: "subtle", ink: fn(p) { p.subtle } },
  { name: "text", ink: fn(p) { p.text } },
  { name: "accent_bg", ink: fn(p) { p.accent_bg } },
  { name: "accent", ink: fn(p) { p.accent } },
]

///|
let glance_side : Double = 28.0

///|
/// A tile's least width, the colour block's height, and how far apart the tiles are.
let swatch_w : Double = 120.0

///|
let swatch_h : Double = 44.0

///|
let swatch_gap : Double = 12.0

///|
// kept across runs: a value (no field of it changes)
let swatch_name : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Semibold, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let swatch_value : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false)

// ---------------------------------------------------------------------------
// 字阶

///|
/// A step of the type scale: what it is called, the style the library names it by, and its size and line as the theme
/// says them now.
priv struct Step {
  name : String
  style : @ui.TextStyle
  size : (@sf.Type) -> (Double, Double)
}

///|
// kept across runs: a value (no element of it changes)
let type_steps : Array[Step] = [
  { name: "title", style: @sf.title, size: fn(t) { (t.heading, t.heading_line) } },
  { name: "wide_heading", style: @sf.wide_heading, size: fn(t) { (t.title, t.title_line) } },
  { name: "body", style: @sf.body, size: fn(t) { (t.body, t.body_line) } },
  { name: "lead", style: @sf.lead, size: fn(t) { (t.body, t.body_line) } },
  { name: "desk_strong", style: @sf.desk_strong, size: fn(t) { (t.ui, t.ui_line) } },
  { name: "code", style: @sf.code, size: fn(t) { (t.ui, t.ui_line) } },
  { name: "meta", style: @sf.meta, size: fn(t) { (t.meta, t.meta_line) } },
  { name: "caption", style: type_caption, size: fn(t) { (t.caption, t.caption_line) } },
]

///|
/// The caption's size (the type's smallest): a mark's, a time's.
// kept across runs: a value (no field of it changes)
let type_caption : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted)

///|
/// A size said whole where it is whole (22, not 22.0).
fn points(n : Double) -> String {
  if n == n.floor() {
    n.to_int().to_string()
  } else {
    n.to_string()
  }
}

///|
/// The type scale now: which scale the native input takes and the system's size of words over it, then each step its
/// name and size over a line in it.
fn type_scale_node(card : @view.View) -> Unit {
  @sf.words_node(
    card,
    fn() {
      let scale = if @sf.theme().touch { "原生操控是触控：字阶 narrow_type" } else { "原生操控是键鼠：字阶 wide_type" }
      scale + "，系统字号 ×" + points(@ui.font_scale())
    },
    fn() { @sf.meta },
  )
  |> ignore
  for st in type_steps {
    card.box(fn(r) {
      r.row(Is(true)).wraps(Is(Some(4.0))).gap(Is(16.0)).lines_up(Is(Some(Start))) |> ignore
      r.box(fn(l) {
        l.basis(Is(Some(type_label_w))).min_width(Is(Some(0.0))).gap(Is(2.0)) |> ignore
        @sf.words_node(l, fn() { st.name }, fn() { swatch_name }) |> ignore
        @sf.words_node(
          l,
          fn() {
            let (size, line) = (st.size)(@sf.theme().t)
            "\{points(size)} / \{points(line)}"
          },
          fn() { swatch_value },
        )
        |> ignore
      })
      |> ignore
      r.box(fn(w) {
        w.grow(Is(1.0)).basis(Is(Some(type_sample_w))).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(w, fn() { "还剩两件事 Two things left" }, fn() { st.style }) |> ignore
      })
      |> ignore
    })
    |> ignore
  }
}

///|
/// How wide a step's name and size are, and its line at least before it goes under them.
let type_label_w : Double = 120.0

///|
let type_sample_w : Double = 200.0

///|
/// Chinese and English and code in one paragraph, in the body's and the paragraph's styles.
fn mixed_node(card : @view.View) -> Unit {
  @sf.words_node(card, fn() { mixed_sample }, fn() { @sf.body }) |> ignore
  @sf.words_node(card, fn() { mixed_sample }, fn() { @sf.paragraph }) |> ignore
}

///|
let mixed_sample : String = "已经跑完 48 个测试，全部通过。Windows 上的 DirectWrite 斜体还要再看一眼，`moon check` 已经干净。"

// ---------------------------------------------------------------------------
// 同心圆角

///|
/// The ladder drawn as it stands: a panel, a card in it 16 in, a row on the card 8 in, a small block on the row 8 in,
/// each round by the step its place gives it; what each step is under it.
fn ladder_node(card : @view.View) -> Unit {
  card.box(fn(pane) {
    pane
    .radius(Is(@sf.pane_corner))
    .pad(Is(@sf.panel_card_in))
    .ground(By(fn() { @sf.theme().p.canvas }))
    .edge(By(fn() { (1.0, @sf.theme().p.line) }))
    .max_width(Is(Some(ladder_most)))
    |> ignore
    pane.box(fn(c) {
      c
      .radius(Is(@sf.card_corner))
      .pad(Is(@sf.corner_inset))
      .gap(Is(@sf.corner_inset))
      .ground(By(fn() { @sf.theme().p.card }))
      .edge(By(fn() { (1.0, @sf.theme().p.line) }))
      |> ignore
      c.box(fn(row) {
        row
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .gap(Is(12.0))
        .radius(Is(@sf.row_corner))
        .pad(Is(@sf.corner_inset))
        .ground(By(fn() { @sf.theme().p.chip }))
        |> ignore
        row.box(fn(s) {
          s
          .width(Is(Some(ladder_block)))
          .height(Is(Some(ladder_block)))
          .radius(Is(@sf.small_corner))
          .ground(By(fn() { @sf.theme().p.accent }))
          |> ignore
        })
        |> ignore
        @sf.words_node(row, fn() { "行 \{points(@sf.row_corner)}，小块 \{points(@sf.small_corner)}" }, fn() { @sf.meta }).min_width(
          Is(Some(0.0)),
        )
        |> ignore
      })
      |> ignore
      c.box(fn(w) {
        w.padding(Is((@sf.corner_inset, 0.0, @sf.corner_inset, 4.0))) |> ignore
        @sf.words_node(w, fn() { "卡片 \{points(@sf.card_corner)}，在面板 \{points(@sf.pane_corner)} 里" }, fn() { @sf.meta }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  // (each step and how it comes of the one round it, as tags in a row)
  side_by_side(card, fn(r) {
    for said in ladder_said() {
      @sf.pill_node(r, fn() { said }) |> ignore
    }
  })
}

///|
/// Each step as it comes of the one round it.
fn ladder_said() -> Array[String] {
  [
    "面板 \{points(@sf.pane_corner)}",
    "卡片 \{points(@sf.card_corner)} = \{points(@sf.pane_corner)} − \{points(@sf.panel_card_in)}",
    "行 \{points(@sf.row_corner)} = \{points(@sf.card_corner)} − \{points(@sf.corner_inset)}",
    "小块 \{points(@sf.small_corner)} = \{points(@sf.row_corner)} − \{points(@sf.corner_inset)}",
  ]
}

///|
/// The ladder's panel at most this wide, and its small block's side.
let ladder_most : Double = 420.0

///|
let ladder_block : Double = 28.0

///|
/// The concentric corner's Playground: an outer box's corner and how far in what it holds stands, the inner's corner
/// worked out of them (@ui.concentric) as the corner rule holds every box to.
fn corners_play() -> Play {
  let outer = @signals.signal(26.0)
  let inset = @signals.signal(8.0)
  let inner = fn() { @ui.concentric(outer.get(), inset.get()) }
  {
    controls: fn(v) {
      control(v, "outer", fn(c) {
        @sf.value_slider_node(c, fn() { "外圆角" }, fn() { outer.get() }, fn(x) { outer.set(x) }, min=12.0, max=40.0, step=2.0)
        |> ignore
      })
      control(v, "inset", fn(c) {
        @sf.value_slider_node(c, fn() { "内边距" }, fn() { inset.get() }, fn(x) { inset.set(x) }, min=0.0, max=20.0)
        |> ignore
      })
    },
    preview: fn(v) {
      v.box(fn(o) {
        o
        .width(Is(Some(corners_box)))
        .height(Is(Some(corners_box)))
        .radius(By(fn() { outer.get() }))
        .pad(By(fn() { inset.get() }))
        .ground(By(fn() { @sf.theme().p.chip }))
        |> ignore
        o.box(fn(i) {
          i
          .grow(Is(1.0))
          .radius(By(inner))
          .ground(By(fn() { @sf.theme().p.accent_bg }))
          .edge(By(fn() { (1.0, @sf.theme().p.accent) }))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          |> ignore
          @sf.words_node(i, fn() { "inner \{points(inner())}" }, fn() { swatch_name }) |> ignore
        })
        |> ignore
      })
      |> ignore
      @sf.words_node(
        v,
        fn() { "inner = outer − inset = \{points(outer.get())} − \{points(inset.get())} = \{points(inner())}" },
        fn() { @sf.meta },
      )
      |> ignore
    },
    code: fn() {
      "outer.radius(Is(\{points(outer.get())})).pad(Is(\{points(inset.get())}))\n" +
      "inner.radius(Is(@ui.concentric(\{points(outer.get())}, \{points(inset.get())}))) // \{points(inner())}"
    },
  }
}

///|
/// The Playground's outer box's side: twice its largest corner and more, so every corner it is given is drawn whole.
let corners_box : Double = 120.0

// ---------------------------------------------------------------------------
// 光影与动效

///|
/// The shadows the library casts, from what floats lowest to what floats highest: each a tile on the card in it, named.
fn shadows_node(card : @view.View) -> Unit {
  let shadows : Array[(String, @sf.Raised)] = [
    ("floating 1", @sf.floating),
    ("page_raised 2", @sf.page_raised),
    ("held_raised 6", @sf.held_raised),
    ("pick_raised 8", @sf.pick_raised),
    ("menu_raised 18", @sf.menu_raised),
    ("sheet_raised 24", @sf.sheet_raised),
  ]
  card.box(fn(grid) {
    grid.row(Is(true)).wraps(Is(Some(shadow_gap))).gap(Is(shadow_gap)).padding(Is((4.0, 4.0, 4.0, 12.0))) |> ignore
    for s in shadows {
      let (name, r) = s
      grid.box(fn(t) {
        t
        .basis(Is(Some(swatch_w)))
        .grow(Is(1.0))
        .height(Is(Some(shadow_h)))
        .radius(Is(@sf.small_corner))
        .ground(By(fn() { @sf.theme().p.raised }))
        .shadow(Is((r.sigma, r.dy, r.color)))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        |> ignore
        @sf.words_node(t, fn() { name }, fn() { swatch_name }) |> ignore
      })
      |> ignore
    }
  })
  |> ignore
}

///|
/// The shadows' tiles: how high, and how far apart (room for the largest's blur between them).
let shadow_h : Double = 64.0

///|
let shadow_gap : Double = 20.0

///|
/// The same way along a track in two ways, side by side: the library's way in (enter_ms, eased out) and its moved
/// thing's spring (move_spring); 播放 sets both off from where they are, at the press's moment.
fn motion_node(card : @view.View) -> Unit {
  let at_end = @signals.signal(false)
  let ways = [
    ("缓动 enter_ms \{points(@sf.enter_ms)} ms", @motion.tween(@sf.enter_ms, ease=Out)),
    ("弹簧 move_spring", @sf.move_spring),
  ]
  let starts : Array[(Bool) -> Unit] = []
  for w in ways {
    let (name, spec) = w
    card.box(fn(r) {
      r.gap(Is(6.0)) |> ignore
      @sf.words_node(r, fn() { name }, fn() { @sf.meta }) |> ignore
      r.box(fn(track) {
        track
        .width(Is(Some(track_w)))
        .max_width(Is(Some(track_w)))
        .height(Is(Some(track_h)))
        .radius(Is(track_h / 2.0))
        .pad(Is(track_in))
        .ground(By(fn() { @sf.theme().p.chip }))
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        |> ignore
        let way = @motion.NodeWay::new(0.0)
        track.box(fn(dot) {
          dot
          .width(Is(Some(dot_d)))
          .height(Is(Some(dot_d)))
          .radius(Is(dot_d / 2.0))
          .ground(By(fn() { @sf.theme().p.accent }))
          .offset(By(fn() { (way.shown(dot), 0.0) }))
          |> ignore
          starts.push(fn(to_end) { way.go(dot, if to_end { track_travel } else { 0.0 }, spec) })
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  }
  side_by_side(card, fn(r) {
    @sf.button_node(
      r,
      fn() { if at_end.get() { "放回" } else { "播放" } },
      fn() {
        let to_end = !at_end.untracked()
        at_end.set(to_end)
        for s in starts {
          s(to_end)
        }
      },
      icon="play",
    )
    |> ignore
  })
}

///|
/// The track's width and height, how far in its dot runs, the dot's side, and how far the dot goes along it.
let track_w : Double = 280.0

///|
let track_h : Double = 36.0

///|
let track_in : Double = 4.0

///|
let dot_d : Double = 28.0

///|
let track_travel : Double = track_w - 2.0 * track_in - dot_d
