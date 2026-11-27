// The workbench over the parts, as Storybook's toolbar and Chromatic's modes have it: what every page is shown under,
// switched from the bar's 环境 panel (the size of words, the current input, the language), and a part's states side by
// side in a grid (state_matrix_node), each under its name, so that a state broken at 2× words or in English is seen
// beside the others. What is chosen holds for the whole run, as the system's own settings would; MBUI_FONT_SCALE,
// MBUI_POINTING and MBUI_LANG choose it as the page starts (an offscreen run of the page at each: scripts/story-diff.sh).

///|
/// The sizes of words the panel offers.
// kept across runs: a value (no element of it changes)
let env_scales : Array[Double] = [1.0, 1.3, 2.0]

///|
/// The current inputs the panel offers: the system's, a mouse, a finger.
// kept across runs: a value (no element of it changes)
let env_hands : Array[String] = ["自动", "鼠标", "触屏"]

///|
/// The languages the panel offers, as @sf.set_language takes them ("" the device's), and their names.
// kept across runs: a value (no element of it changes)
let env_langs : Array[(String, String)] = [("", "自动"), ("zh", "中文"), ("en", "English")]

///|
/// A size of words as the panel says it: one place after the point, then ×.
fn scale_words(s : Double) -> String {
  let tenths = (s * 10.0).round().to_int()
  "\{tenths / 10}.\{tenths % 10}×"
}

///|
/// The one of env_scales nearest to the size of words now.
fn scale_at(s : Double) -> Int {
  let mut best = 0
  for i, x in env_scales {
    if (x - s).abs() < (env_scales[best] - s).abs() {
      best = i
    }
  }
  best
}

///|
/// What the page is shown under: the current input chosen (0 the system's, 1 a mouse, 2 a finger: env_hands) and the
/// language chosen (env_langs' place), the size of words being mbui's own (@ui.font_scale), followed as it is.
priv struct Env {
  hand : @signals.Signal[Int]
  lang : @signals.Signal[Int]
}

///|
/// The workbench's settings as the page starts: as MBUI_FONT_SCALE (a number), MBUI_POINTING (mouse, finger) and
/// MBUI_LANG (zh, en) say, each left as it is where unset.
fn env_started() -> Env {
  let raw_scale = @ui.env("MBUI_FONT_SCALE")
  let scale = try {
    @string.parse_double(raw_scale)
  } catch {
    _ => 0.0
  }
  if scale > 0.0 {
    @ui.set_font_scale(Some(scale))
  }
  let hand = match @ui.env("MBUI_POINTING") {
    "mouse" => 1
    "finger" => 2
    _ => 0
  }
  if hand > 0 {
    @ui.set_pointing(Some(if hand == 1 { Mouse } else { Finger }))
  }
  let env_lang = @ui.env("MBUI_LANG")
  let mut lang = 0
  for i in 0..<env_langs.length() {
    if env_langs[i].0 != "" && env_langs[i].0 == env_lang {
      lang = i
      break
    }
  }
  if lang > 0 {
    @sf.set_language(Some(env_langs[lang].0))
  }
  { hand: @signals.signal(hand), lang: @signals.signal(lang) }
}

///|
/// The current input chosen: `i` of env_hands.
fn Env::choose_hand(self : Env, i : Int) -> Unit {
  self.hand.set(i)
  @ui.set_pointing(
    match i {
      1 => Some(Mouse)
      2 => Some(Finger)
      _ => None
    },
  )
}

///|
/// The language chosen: `i` of env_langs.
fn Env::choose_lang(self : Env, i : Int) -> Unit {
  self.lang.set(i)
  @sf.set_language(if i > 0 { Some(env_langs[i].0) } else { None })
}

///|
/// All of it as the system has it again: its size of words, its input, its language.
fn Env::reset(self : Env) -> Unit {
  @ui.set_font_scale(None)
  self.choose_hand(0)
  self.choose_lang(0)
}

///|
/// What is chosen otherwise than the system's, said short (1.3× · 触屏 · EN); "" none.
fn Env::brief(self : Env) -> String {
  let parts = []
  let s = @ui.font_scale()
  if (s - 1.0).abs() > 0.001 {
    parts.push(scale_words(s))
  }
  match self.hand.get() {
    1 => parts.push("鼠标")
    2 => parts.push("触屏")
    _ => ()
  }
  match self.lang.get() {
    1 => parts.push("中文")
    2 => parts.push("EN")
    _ => ()
  }
  parts.join(" · ")
}

///|
/// The bar's button's words: 环境, or what is chosen otherwise than the system's.
fn Env::words(self : Env) -> String {
  let b = self.brief()
  if b == "" {
    "环境"
  } else {
    b
  }
}

///|
/// The 环境 panel's body: each setting a row, its name at its start (as far in as the panel's title) and a segmented
/// choice of it at its end, then what puts them all back, in the panel's corner.
fn env_body(body : @view.View, env : Env) -> Unit {
  body.box(fn(rows) {
    // (their words as far in as the panel's title, a row's padding: the library's text_in, less the panel's own)
    let side = @sf.text_in - @sf.panel_pad
    rows.gap(Is(12.0)).padding(Is((side, 0.0, side, 0.0))).min_width(Is(Some(0.0))) |> ignore
    let one = fn(name : String, labels : Array[String], chosen : () -> Int, choose : (Int) -> Unit) {
      rows.box(fn(row) {
        row.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(12.0)).min_width(Is(Some(0.0))) |> ignore
        row.box(fn(l) {
          l.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(l, fn() { name }, fn() { @sf.caption }) |> ignore
        })
        |> ignore
        @sf.seg_node(row, fn() { labels }, chosen, choose, said=name) |> ignore
      })
      |> ignore
    }
    one("字号", env_scales.map(scale_words), fn() { scale_at(@ui.font_scale()) }, fn(i) {
      @ui.set_font_scale(Some(env_scales[i]))
    })
    one("操控方式", env_hands, fn() { env.hand.get() }, fn(i) { env.choose_hand(i) })
    one("语言", env_langs.map(fn(l) { l.1 }), fn() { env.lang.get() }, fn(i) { env.choose_lang(i) })
  })
  |> ignore
  // (in the panel's corner, concentric with it: as far in from its side as from its foot, the panel's own padding)
  body.box(fn(r) {
    r.row(Is(true)).lines_up(Is(Some(Middle))).padding(Is((0.0, 12.0, 0.0, 0.0))).min_width(Is(Some(0.0))) |> ignore
    r.box(fn(gap) { gap.grow(Is(1.0)) |> ignore }) |> ignore
    @sf.button_node(r, fn() { "恢复默认" }, fn() { env.reset() }, disabled=fn() { env.brief() == "" }) |> ignore
  })
  |> ignore
}

///|
/// The 环境 panel beside `opener`.
fn env_open(opener : @view.View, env : Env) -> Unit {
  // (as wide as its three choices side by side beside their names at 1.3× words)
  @sf.panel_nodes("环境", fn(body, _) { env_body(body, env) }, from=@sf.Anchor::Node(opener), w=400.0)
}

///|
/// A part's states side by side in `parent`: `title` over them ("" none), then each state in a cell of its own, its
/// name over it, the cells as wide as each other and wrapping onto as many lines as the room needs.
fn state_matrix_node(parent : @view.View, title : String, states : Array[(String, (@view.View) -> Unit)]) -> Unit {
  parent.box(fn(m) {
    m.gap(Is(8.0)).min_width(Is(Some(0.0))) |> ignore
    if title != "" {
      @sf.words_node(m, fn() { title }, fn() { @sf.caption }) |> ignore
    }
    m.box(fn(grid) {
      grid.row(Is(true)).wraps(Is(Some(8.0))).gap(Is(8.0)).min_width(Is(Some(0.0))) |> ignore
      for s in states {
        let (name, make) = s
        grid.box(fn(cell) {
          cell
          .basis(Is(Some(148.0)))
          .grow(Is(1.0))
          .min_width(Is(Some(0.0)))
          // (the page's own ground: set off from the card it is on, in the light and in the dark alike)
          .ground(By(fn() { @sf.theme().p.bg }))
          .radius(Is(8.0))
          .pad(Is(12.0))
          .gap(Is(8.0))
          |> ignore
          @sf.words_node(cell, fn() { name }, fn() { @sf.meta }) |> ignore
          cell.box(fn(shown) {
            shown.row(Is(true)).lines_up(Is(Some(Middle))).min_width(Is(Some(0.0))) |> ignore
            make(shown)
          })
          |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// The workbench's own pages, after the parts': the state matrix of the controls most pages hold, under what the bar's
/// 环境 panel chose.
fn workbench_stories(env : Env) -> Array[Story] {
  [
    {
      key: "matrix",
      group: "工作台",
      name: "状态矩阵 State matrix",
      file: "button_node.mbt",
      api: [],
      play: None,
      about: "常用控件的各个状态并排一格一格摆出来，跟着顶栏「环境」里选的字号、操控方式和语言实时变化：一处状态在 2× 字号或英文下出问题，和其它状态放在一起一眼就能看出来。",
      cases: [
        (
          "按钮各状态 Button states",
          fn(card) {
            state_matrix_node(card, "", [
              ("主要 Primary", fn(v) { @sf.button_node(v, fn() { "保存" }, fn() {  }, tone=Primary) |> ignore }),
              ("默认 Default", fn(v) { @sf.button_node(v, fn() { "取消" }, fn() {  }) |> ignore }),
              ("幽灵 Ghost", fn(v) { @sf.button_node(v, fn() { "更多" }, fn() {  }, tone=Ghost) |> ignore }),
              ("危险 Danger", fn(v) { @sf.button_node(v, fn() { "删除" }, fn() {  }, tone=Danger) |> ignore }),
              ("带图标 Icon", fn(v) { @sf.button_node(v, fn() { "分享" }, fn() {  }, icon="share") |> ignore }),
              (
                "禁用 Disabled",
                fn(v) { @sf.button_node(v, fn() { "不可用" }, fn() {  }, disabled=fn() { true }) |> ignore },
              ),
              (
                "库里的词 Library words",
                fn(v) { @sf.button_node(v, fn() { @sf.t("common.cancel") }, fn() {  }) |> ignore },
              ),
            ])
          },
        ),
        (
          "开关各状态 Switch states",
          fn(card) {
            let on = @signals.signal(true)
            state_matrix_node(card, "", [
              ("关 Off", fn(v) { @sf.switch_node(v, fn() { false }, fn(_) {  }, fn() { "关着的开关" }) }),
              ("开 On", fn(v) { @sf.switch_node(v, fn() { on.get() }, fn(x) { on.set(x) }, fn() { "开着的开关" }) }),
              (
                "禁用 Disabled",
                fn(v) { @sf.switch_node(v, fn() { true }, fn(_) {  }, fn() { "不可用的开关" }, disabled=fn() { true }) },
              ),
            ])
          },
        ),
        (
          "输入框各状态 Input states",
          fn(card) {
            state_matrix_node(card, "", [
              ("空 Empty", fn(v) { @sf.input_node(v, @ui.Field::new(), placeholder="搜索") |> ignore }),
              ("有字 Filled", fn(v) { @sf.input_node(v, @ui.Field::new(text="still.fail"), label="名字") |> ignore }),
              (
                "禁用 Disabled",
                fn(v) { @sf.input_node(v, @ui.Field::new(), placeholder="不可用", disabled=fn() { true }) |> ignore },
              ),
            ])
          },
        ),
        (
          "当前环境 Environment",
          fn(card) {
            @sf.words_node(
              card,
              fn() {
                let hand = match @ui.pointing() {
                  Finger => "手指"
                  Mouse => "鼠标"
                }
                let lang = if @sf.language() == "en" { "English" } else { "中文" }
                "字号 \{scale_words(@ui.font_scale())} · 当前操控 \{hand}（选的是\{env_hands[env.hand.get()]}） · 语言 \{lang}"
              },
              fn() { @sf.body },
            )
            |> ignore
          },
        ),
      ],
    },
  ]
}
