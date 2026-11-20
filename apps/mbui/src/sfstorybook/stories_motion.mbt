// Motion library showcase pages (动效库): 6 interactive pages demonstrating
// curves & springs, press/hover/shake, controls & glass, overlays & handoff,
// reveal/list/flash, and waiting/resident cycles.

///|
let motion_group : String = "动效库"

///|
let motion_curve_w : Double = 56.0

///|
let motion_curve_h : Double = 30.0

///|
let motion_track_w : Double = 220.0

///|
let motion_track_h : Double = 28.0

///|
let motion_dot_d : Double = 18.0

///|
let motion_track_in : Double = 5.0

///|
/// Travel distance for curve tracks (inside 220px track).
let motion_curve_travel : Double = motion_track_w - motion_track_in * 2.0 - motion_dot_d

///|
/// Target travel distance for spring tracks (leaving 32px past the finish line so overshoot is visible).
let motion_spring_travel : Double = motion_curve_travel - 32.0

///|
/// Compact 32x24 warm-to-cool gradient PNG bytes for deterministic offscreen image reveal.
let motion_png_a : Bytes = b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x20\x00\x00\x00\x18\x08\x06\x00\x00\x00\x9b\x53\xff\x34\x00\x00\x01\x1b\x49\x44\x41\x54\x78\xda\xc5\xce\xd1\x47\x03\x01\x1c\xc0\xf1\xdf\x3f\x14\x11\x11\x3d\x44\x44\xf4\x10\xd1\x5a\xdd\xee\x76\x77\xdb\xed\x6e\x77\xdb\x6d\xbb\xdd\xad\xd5\x6a\xd5\x6a\x6b\x89\xe8\x21\x22\xa2\x87\x88\x88\xe8\x21\x22\xa2\x87\x88\x88\x1e\xfa\x6b\xbe\xf5\x5f\xfc\xfe\x82\xcf\x47\x7e\x3b\x39\x7e\xb2\x1c\xdf\xd9\x1a\x5f\x69\x9e\xcf\x74\x9d\x8f\xf6\x06\xef\x6d\x83\xb7\xa4\xc0\x6b\x62\xf2\xd2\xb2\x78\x6e\x15\x79\x6a\xda\x3c\x36\x1d\x1e\x1a\x2e\xf7\x8d\x12\x77\x71\x99\xdb\xd8\xe3\xa6\x5e\xe1\xba\xee\x73\x55\xf3\xb9\xac\x05\x5c\x44\x55\xce\xa3\x90\xb3\x30\xe2\x34\xac\x31\xae\xd6\x19\x56\x63\x06\x41\x83\x7e\xd0\xa4\xe7\xb7\xe8\xfa\x09\x59\xa5\x8d\x68\xe2\x49\x25\x45\x34\xf1\xd8\xcb\x10\x4d\x3c\xf2\x3a\x88\x26\x1e\x94\x37\x11\x4d\xdc\x2b\x77\x11\x4d\xdc\x2d\xfd\x07\x34\x71\xab\xb4\x85\x68\xe2\x86\xbb\x8d\x68\xe2\x79\xb7\x87\x68\xe2\xab\xce\x0e\xa2\x89\xaf\x38\xbb\x88\x26\xbe\x6c\xf7\x11\x4d\x7c\xc9\xde\x43\x34\xf1\xc5\xe2\x3e\xa2\x89\x2f\x14\x0f\x10\x4d\x7c\xde\x1a\x20\x9a\xf8\x9c\x75\x88\x68\xe2\xb3\xe6\x11\xa2\x89\xcf\x98\x43\x44\x13\x9f\x2e\x8c\x10\x4d\x7c\xaa\x70\x8c\x68\xe2\x93\xc6\x18\xd1\xc4\x27\x8c\x13\xfe\x00\xe7\xf6\x10\xcb\x3f\x75\x0e\x93\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82"

///|
/// Second compact 32x24 emerald-to-amber gradient PNG bytes for replaying decode reveal.
let motion_png_b : Bytes = b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x20\x00\x00\x00\x18\x08\x06\x00\x00\x00\x9b\x53\xff\x34\x00\x00\x00\xff\x49\x44\x41\x54\x78\xda\xc5\xce\x61\x47\x43\x01\x18\x47\xf1\xe7\xa3\x25\xe2\xd6\x6a\xb5\x5a\xad\x56\x5b\xab\xd5\x6a\xb5\x5a\xad\x22\x22\x22\x22\x22\x11\xff\xa7\x88\x88\x88\x88\x88\x88\x88\x88\x88\x88\x88\xe8\x9b\x9c\xee\xfd\x14\xcf\x8b\xf3\xfa\x77\xac\x4b\x9b\x74\x6b\x83\x1e\x75\x48\xb4\x4e\x4e\x6b\xe4\xd5\xa6\x90\x56\xd4\x2a\x25\xad\x50\x56\x8b\x8a\x96\xa9\xa5\xd5\xb5\x44\x43\x4d\x9a\x5a\xa4\xa5\x05\xda\x6a\xd0\x49\xdb\xd2\x3c\xdb\x9a\x63\x47\x75\x76\x35\xcb\x5e\xda\xbe\x66\x38\x50\x8d\x43\x4d\x73\xa4\x2a\xc7\x5e\xe5\xc4\x2b\x9c\xfa\x14\xf2\x49\xce\xbd\x8c\x45\xe2\x17\x3e\x81\x45\xe2\x97\xd9\x40\x24\x7e\xe5\xe3\x58\x24\x7e\xed\x25\x2c\x12\xbf\xf1\x31\x2c\x12\xbf\xf5\x51\x2c\x12\xbf\xcb\x06\x22\xf1\x7b\x2f\x62\x91\xf8\x83\x8f\x60\x91\xf8\xa3\x0f\x63\x91\xf8\x93\x17\xb0\x48\xfc\xd9\x87\xb0\x48\xfc\x25\x1b\x88\xc4\x5f\x7d\x10\x8b\xc4\xdf\x3c\x8f\x45\xe2\xef\x3e\x80\x45\xe2\x1f\xde\x8f\x45\xe2\x9f\xd9\x40\x24\xfe\xe5\x39\x2c\x12\xff\xf6\x3e\x2c\x12\xff\xf1\x5e\x2c\x12\xff\xf5\x04\x8b\xc4\xff\xce\x12\xfe\x01\x9a\x87\x8e\x11\x9b\xa8\x59\x75\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82"

///|
/// Convert sampled 0..1 curve values into polyline points inside a `(w, h)` box with `pad` inset.
fn curve_points(samples : Array[Double], w : Double, h : Double, pad : Double) -> Array[(Double, Double)] {
  let n = samples.length()
  if n < 2 {
    return [(pad, h - pad), (w - pad, pad)]
  }
  let inner_w = w - pad * 2.0
  let inner_h = h - pad * 2.0
  let denom = (n - 1).to_double()
  let out : Array[(Double, Double)] = []
  for i, v in samples {
    let x = pad + inner_w * (i.to_double() / denom)
    let clamped = if v < -0.2 { -0.2 } else if v > 1.25 { 1.25 } else { v }
    let y = h - pad - inner_h * clamped
    out.push((x, y))
  }
  out
}

///|
/// Mini curve plot box rendered with `View::lines`.
fn mini_curve_box(parent : @view.View, samples : Array[Double]) -> Unit {
  let pts = curve_points(samples, motion_curve_w, motion_curve_h, 4.0)
  let base_y = motion_curve_h - 4.0
  let top_y = 4.0
  parent.box(fn(g) {
    g
    .width(Is(Some(motion_curve_w)))
    .height(Is(Some(motion_curve_h)))
    .radius(Is(6.0))
    .ground(By(fn() { @sf.theme().p.canvas }))
    .edge(By(fn() { (1.0, @sf.theme().p.line) }))
    .lines(By(fn() {
      [
        @ui.line([(4.0, base_y), (motion_curve_w - 4.0, base_y)], width=1.0, color=@sf.theme().p.line),
        @ui.line([(4.0, top_y), (motion_curve_w - 4.0, top_y)], width=1.0, color=@sf.theme().p.line),
        @ui.line(pts, width=1.8, color=@sf.theme().p.accent),
      ]
    }))
    |> ignore
  })
  |> ignore
}

///|
/// Playground for `move_duration_ms(distance)`: slider 40..800px + live duration + single-track test run.
fn motion_curves_play() -> Play {
  let dist = @signals.signal(240.0)
  let at_end = @signals.signal(false)
  let run_ref : Ref[(Bool) -> Unit] = Ref(fn(_) {  })
  {
    controls: fn(v) {
      control(v, "distance", fn(c) {
        @sf.value_slider_node(
          c,
          fn() { "位移距离" },
          fn() { dist.get() },
          fn(d) { dist.set(d) },
          min=40.0,
          max=800.0,
          step=20.0,
        )
        |> ignore
      })
    },
    preview: fn(v) {
      v.box(fn(col) {
        col.gap(Is(10.0)) |> ignore
        @sf.words_node(
          col,
          fn() {
            let d = dist.get()
            let ms = @motion.move_duration_ms(d)
            "距离 \{points(d)} px，自适应时长 \{points(ms)} ms"
          },
          fn() { @sf.meta },
        )
        |> ignore
        col.box(fn(track) {
          track
          .width(Is(Some(motion_track_w)))
          .max_width(Is(Some(motion_track_w)))
          .height(Is(Some(motion_track_h)))
          .radius(Is(motion_track_h / 2.0))
          .pad(Is(motion_track_in))
          .ground(By(fn() { @sf.theme().p.chip }))
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          |> ignore
          let way = @motion.NodeWay::new(0.0)
          track.box(fn(dot) {
            dot
            .width(Is(Some(motion_dot_d)))
            .height(Is(Some(motion_dot_d)))
            .radius(Is(motion_dot_d / 2.0))
            .ground(By(fn() { @sf.theme().p.accent }))
            .offset(By(fn() { (way.shown(dot), 0.0) }))
            |> ignore
            run_ref.val = fn(to_end) {
              way.go(dot, if to_end { motion_curve_travel } else { 0.0 }, @motion.moved(over=dist.untracked()))
            }
          })
          |> ignore
        })
        |> ignore
        side_by_side(col, fn(r) {
          @sf.button_node(
            r,
            fn() { if at_end.get() { "归位" } else { "试跑" } },
            fn() {
              let next = !at_end.untracked()
              at_end.set(next)
              (run_ref.val)(next)
            },
            icon="play",
          )
          |> ignore
        })
      })
      |> ignore
    },
    code: fn() {
      let d = dist.get()
      let ms = @motion.move_duration_ms(d)
      "let ms = @motion.move_duration_ms(\{points(d)}) // \{points(ms)} ms\nway.go(node, target, @motion.moved(over=\{points(d)}))"
    },
  }
}

///|
/// The 6 motion library showcase stories (group: "动效库").
fn motion_stories(tips : @sf.TipLayer) -> Array[Story] {
  [
    // 1. Curves & Springs
    {
      key: "motion-curves",
      group: motion_group,
      name: "曲线与弹簧 Curves",
      file: "libs/mbui/src/motion/catalog.mbt",
      api: [
        ("catalog.mbt", "move_duration_ms"),
        ("catalog.mbt", "sample_ease"),
        ("catalog.mbt", "sample_spec"),
        ("catalog.mbt", "glass_lens_springs"),
      ],
      play: Some(motion_curves_play),
      about: "6 条定时缓动曲线同刻出发对比，以及临界阻尼与欠阻尼过冲弹簧在终点刻度线上的停准表现。",
      cases: [
        (
          "6 条定时曲线同轨对比",
          fn(card) {
            let at_end = kept(false)
            let curves : Array[(String, @ui.Ease, Double)] = [
              ("Move（距离自适应）", Move, @motion.move_duration_ms(motion_curve_travel)),
              ("Out（入场与控件响应）", Out, 280.0),
              ("Leave（退场加速）", Leave, 280.0),
              ("InOut（呼吸与描边）", InOut, 280.0),
              ("Linear（匀速循环）", Linear, 280.0),
              ("Flight（发送飞行）", Flight, 280.0),
            ]
            let starts : Array[(Bool) -> Unit] = []
            card.box(fn(grid) {
              grid.row(Is(true)).wraps(Is(Some(10.0))).gap(Is(14.0)) |> ignore
              for item in curves {
                let (label, ease, ms) = item
                let samples = @motion.sample_ease(ease, 24)
                grid.box(fn(col) {
                  col.basis(Is(Some(290.0))).gap(Is(4.0)) |> ignore
                  @sf.words_node(col, fn() { label }, fn() { @sf.meta }) |> ignore
                  col.box(fn(row) {
                    row.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
                    mini_curve_box(row, samples)
                    row.box(fn(track) {
                      track
                      .width(Is(Some(motion_track_w)))
                      .max_width(Is(Some(motion_track_w)))
                      .height(Is(Some(motion_track_h)))
                      .radius(Is(motion_track_h / 2.0))
                      .pad(Is(motion_track_in))
                      .ground(By(fn() { @sf.theme().p.chip }))
                      .row(Is(true))
                      .lines_up(Is(Some(Middle)))
                      |> ignore
                      let way = @motion.NodeWay::new(0.0)
                      track.box(fn(dot) {
                        dot
                        .width(Is(Some(motion_dot_d)))
                        .height(Is(Some(motion_dot_d)))
                        .radius(Is(motion_dot_d / 2.0))
                        .ground(By(fn() { @sf.theme().p.accent }))
                        .offset(By(fn() { (way.shown(dot), 0.0) }))
                        |> ignore
                        starts.push(fn(to_end) {
                          way.go(dot, if to_end { motion_curve_travel } else { 0.0 }, @motion.tween(ms, ease~))
                        })
                      })
                      |> ignore
                    })
                    |> ignore
                  })
                  |> ignore
                })
                |> ignore
              }
            })
            |> ignore
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
                tone=Primary,
              )
              |> ignore
            })
          },
        ),
        (
          "弹簧阻尼对比（临界阻尼 vs 过冲）",
          fn(card) {
            let at_end = kept(false)
            let springs : Array[(String, @motion.Spec)] = [
              ("snappy_damped（临界阻尼，Hover/切档推荐）", @motion.snappy_damped),
              ("move_damped（临界阻尼，常规位移）", @motion.move_damped),
              ("carousel_spring（临界阻尼，切图条）", @motion.carousel_spring),
              ("tactile_bounce（欠阻尼过冲 ζ=0.65，按压拖拽）", @motion.tactile_bounce),
            ]
            let starts : Array[(Bool) -> Unit] = []
            let finish_x = motion_track_in + motion_spring_travel + motion_dot_d / 2.0
            for item in springs {
              let (label, spec) = item
              let samples = @motion.sample_spec(spec, 500.0, 32)
              card.box(fn(col) {
                col.gap(Is(4.0)) |> ignore
                @sf.words_node(col, fn() { label }, fn() { @sf.meta }) |> ignore
                col.box(fn(row) {
                  row.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
                  mini_curve_box(row, samples)
                  row.box(fn(track) {
                    track
                    .width(Is(Some(motion_track_w)))
                    .max_width(Is(Some(motion_track_w)))
                    .height(Is(Some(motion_track_h)))
                    .radius(Is(motion_track_h / 2.0))
                    .pad(Is(motion_track_in))
                    .ground(By(fn() { @sf.theme().p.chip }))
                    .lines(By(fn() {
                      [
                        @ui.line(
                          [(finish_x, 3.0), (finish_x, motion_track_h - 3.0)],
                          width=1.5,
                          color=@sf.theme().p.line_strong,
                        ),
                      ]
                    }))
                    .row(Is(true))
                    .lines_up(Is(Some(Middle)))
                    |> ignore
                    let way = @motion.NodeWay::new(0.0)
                    track.box(fn(dot) {
                      dot
                      .width(Is(Some(motion_dot_d)))
                      .height(Is(Some(motion_dot_d)))
                      .radius(Is(motion_dot_d / 2.0))
                      .ground(By(fn() { @sf.theme().p.accent }))
                      .offset(By(fn() { (way.shown(dot), 0.0) }))
                      |> ignore
                      starts.push(fn(to_end) {
                        way.go(dot, if to_end { motion_spring_travel } else { 0.0 }, spec)
                      })
                    })
                    |> ignore
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
                fn() { if at_end.get() { "弹簧放回" } else { "弹簧出发" } },
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
          },
        ),
      ],
    },
    // 2. Press, Hover & Shake
    {
      key: "motion-press",
      group: motion_group,
      name: "按压与抖动 Press",
      file: "libs/mbui/src/motion/tools.mbt",
      api: [("tools.mbt", "hover_fade")],
      play: None,
      about: "按钮按压下沉回弹、列表行涟漪与悬浮渐变、工具栏游走热接力，以及长按蓄力与禁用拒绝抖动。",
      cases: [
        (
          "按钮按压对比",
          fn(card) {
            let count = kept(0)
            side_by_side(card, fn(r) {
              @sf.button_node(r, fn() { "普通按钮" }, fn() { count.set(count.get() + 1) }) |> ignore
              @sf.button_node(r, fn() { "主按钮" }, fn() { count.set(count.get() + 1) }, tone=Primary) |> ignore
            })
            side_by_side(card, fn(r) {
              @sf.icon_button_node(r, "plus", fn() { "新建" }, fn() { count.set(count.get() + 1) }, size=32.0, tips~) |> ignore
              @sf.send_button_node(
                r,
                fn() { "发送" },
                fn() { true },
                fn() { false },
                fn() { count.set(count.get() + 1) },
                tips~,
              )
              |> ignore
              @sf.send_button_node(r, fn() { "不可发送" }, fn() { false }, fn() { false }, fn() {  }, tips~) |> ignore
            })
            @sf.words_node(card, fn() { "已点击 \{count.get()} 次" }, fn() { @sf.caption }) |> ignore
          },
        ),
        (
          "列表行涟漪与悬浮渐变",
          fn(card) {
            let taps = kept(0)
            card.box(fn(col) {
              col.gap(Is(8.0)) |> ignore
              // Ripple row
              col.box(fn(row) {
                row
                .padding(Is((12.0, 10.0, 12.0, 10.0)))
                .radius(Is(@sf.row_corner))
                .ground(By(fn() { @sf.theme().p.card }))
                .edge(By(fn() { (1.0, @sf.theme().p.line) }))
                |> ignore
                @sf.rippled_node(row, fn() { taps.set(taps.get() + 1) }, @sf.row_corner, fn() { "涟漪按压行" })
                @sf.words_node(row, fn() { "涟漪行 press_look（点击 \{taps.get()} 次）" }, fn() { @sf.paragraph }) |> ignore
              })
              |> ignore
              // hover_ground_node row
              col.box(fn(row) {
                row
                .padding(Is((12.0, 10.0, 12.0, 10.0)))
                .radius(Is(@sf.row_corner))
                .ground(By(fn() { @sf.theme().p.card }))
                .edge(By(fn() { (1.0, @sf.theme().p.line) }))
                |> ignore
                @sf.hover_ground_node(row)
                @sf.words_node(row, fn() { "即时悬浮底色 hover_ground_node" }, fn() { @sf.paragraph }) |> ignore
              })
              |> ignore
              // @motion.hover_fade row
              col.box(fn(row) {
                let p = @motion.hover_fade(row, fn() { row.pointed() }, duration_ms=140.0)
                row
                .padding(Is((12.0, 10.0, 12.0, 10.0)))
                .radius(Is(@sf.row_corner))
                .ground(By(fn() { @sf.theme().p.card }))
                .ground_over(By(fn() {
                  let a = p()
                  if a <= 0.0 {
                    0L
                  } else {
                    @ui.alpha(@sf.theme().p.accent, 0.14 * a)
                  }
                }))
                .edge(By(fn() { (1.0, @sf.theme().p.line) }))
                |> ignore
                @sf.words_node(row, fn() { "缓动悬浮渐变 @motion.hover_fade" }, fn() { @sf.paragraph }) |> ignore
              })
              |> ignore
            })
            |> ignore
          },
        ),
        (
          "工具栏悬浮热接力 RovingHover",
          fn(card) {
            let picked = kept("无")
            side_by_side(card, fn(r) {
              r.lends(@sf.rove_lent, @sf.RovingHover::new()) |> ignore
              for item in [
                ("download", "下载"),
                ("share", "分享"),
                ("copy", "复制"),
                ("edit", "编辑"),
                ("trash", "删除"),
              ] {
                let (icon, label) = item
                @sf.tool_node(
                  r,
                  fn() { { icon, label, on: picked.get() == label, disabled: false } },
                  fn() { @sf.page_viewer_ink() },
                  Is(@sf.small_corner),
                  fn() { picked.set(label) },
                  tip=tips,
                )
                |> ignore
              }
            })
            @sf.words_node(card, fn() { "当前工具：" + picked.get() }, fn() { @sf.caption }) |> ignore
          },
        ),
        (
          "长按蓄力 HoldButton 与拒绝抖动 RefusedShake",
          fn(card) {
            let done_count = kept(0)
            let shake = @motion.ShakeWay::new()
            let box_ref : Ref[@view.View?] = Ref(None)
            side_by_side(card, fn(r) {
              @sf.hold_button_node(
                r,
                fn() { "按住确认" },
                fn() { done_count.set(done_count.get() + 1) },
                danger=false,
              )
              |> ignore
              @sf.button_node(r, fn() { "禁用按钮" }, fn() {  }, disabled=fn() { true }) |> ignore
              @sf.button_node(
                r,
                fn() { "触发抖动" },
                fn() {
                  match box_ref.val {
                    Some(v) => shake.shake(at=v.cause_at())
                    None => ()
                  }
                },
                tone=Ghost,
              )
              |> ignore
            })
            card.box(fn(b) {
              box_ref.val = Some(b)
              let _ = shake.shakes(b)
              b
              .padding(Is((12.0, 10.0, 12.0, 10.0)))
              .radius(Is(@sf.small_corner))
              .ground(By(fn() { @sf.theme().p.canvas }))
              .edge(By(fn() { (1.0, @sf.theme().p.line) }))
              |> ignore
              @sf.words_node(
                b,
                fn() { "ShakeWay 示例框（长按已完成 \{done_count.get()} 次）" },
                fn() { @sf.meta },
              )
              |> ignore
            })
            |> ignore
          },
        ),
      ],
    },
    // 3. Controls & Glass
    {
      key: "motion-controls",
      group: motion_group,
      name: "滑块与玻璃 Controls",
      file: "seg_node.mbt",
      api: [("seg_node.mbt", "seg_node"), ("stops_node.mbt", "stops_node"), ("tab_bar_node.mbt", "tab_bar_node")],
      play: None,
      about: "开关液态玻璃透镜、分段与标签页四兄弟、离散档位滑块，以及折叠面板与滚轮数字。",
      cases: [
        (
          "开关与液态玻璃透镜 Switch",
          fn(card) {
            let on_a = kept(true)
            let on_b = kept(false)
            side_by_side(card, fn(r) {
              @sf.switch_node(r, fn() { on_a.get() }, fn(v) { on_a.set(v) }, fn() { "主开关" })
              @sf.switch_node(r, fn() { on_b.get() }, fn(v) { on_b.set(v) }, fn() { "小号开关" }, small=true)
            })
          },
        ),
        (
          "分段与标签页四兄弟",
          fn(card) {
            let seg_i = kept(0)
            let fill_i = kept(0)
            let tab_k = kept("a")
            let cap_k = kept("概览")
            let grv_k = kept("日志")
            card.box(fn(col) {
              col.gap(Is(12.0)) |> ignore
              @sf.seg_node(col, fn() { ["全部", "进行中", "已完成"] }, fn() { seg_i.get() }, fn(i) { seg_i.set(i) }, said="分段器")
              |> ignore
              @sf.seg_fill_node(col, fn() { ["标准", "紧凑", "宽松"] }, fn() { fill_i.get() }, fn(i) { fill_i.set(i) }, said="铺满分段")
              |> ignore
              @sf.tabs_node(
                col,
                fn() { "下划线标签" },
                [("a", fn() { "摘要" }), ("b", fn() { "变更" }), ("c", fn() { "检查" })],
                fn() { tab_k.get() },
                fn(k) { tab_k.set(k) },
                fn(p, k) {
                  let text = match k {
                    "a" => "当前面板：摘要"
                    "b" => "当前面板：变更"
                    _ => "当前面板：检查"
                  }
                  @sf.words_node(p, fn() { text }, fn() { @sf.caption }) |> ignore
                },
              )
              |> ignore
              @sf.tab_bar_node(
                col,
                fn() { "胶囊标签栏" },
                fn() { ["概览", "文件", "终端"] },
                fn() { cap_k.get() },
                fn(k) { cap_k.set(k) },
                fn(k) { k },
                fn(b, k, shown) { @sf.tab_words_node(b, fn() { k }, shown) |> ignore },
              )
              |> ignore
              @sf.tab_bar_node(
                col,
                fn() { "槽式标签栏" },
                fn() { ["日志", "指标", "网络"] },
                fn() { grv_k.get() },
                fn(k) { grv_k.set(k) },
                fn(k) { k },
                fn(b, k, shown) { @sf.tab_words_node(b, fn() { k }, shown) |> ignore },
                look=Groove,
              )
              |> ignore
            })
            |> ignore
          },
        ),
        (
          "离散档位 Stops",
          fn(card) {
            let level = kept(1)
            let stops = @sf.Stops::new()
            @sf.stops_node(
              card,
              fn() { ["低", "中", "高", "极高"] },
              fn() { level.get() },
              stops,
              said="思考强度",
              on_pick=fn(i) { level.set(i) },
            )
            |> ignore
          },
        ),
        (
          "折叠面板 Accordion 与滚轮数字 RollingNumber",
          fn(card) {
            let open_key = kept("")
            let num = kept(42)
            @sf.accordion_node(
              card,
              [
                @sf.accordion_section("a", fn() { "临界阻尼与无过冲" }, fn(body) {
                  @sf.words_node(body, fn() { "离散档位与悬浮接力在临界阻尼下直达终点，不在边界回弹。" }, fn() { @sf.meta })
                  |> ignore
                }),
                @sf.accordion_section("b", fn() { "认识论静默" }, fn(body) {
                  @sf.words_node(body, fn() { "首次挂载与数据回填直接落位，仅用户此刻操作触发过渡。" }, fn() { @sf.meta })
                  |> ignore
                }),
              ],
              fn(k) { open_key.get() == k },
              fn(k) { open_key.set(if open_key.get() == k { "" } else { k }) },
            )
            |> ignore
            side_by_side(card, fn(r) {
              @sf.button_node(r, fn() { "减 10" }, fn() { num.set(if num.get() >= 10 { num.get() - 10 } else { 0 }) }, tone=Ghost)
              |> ignore
              @sf.rolling_number_node(r, fn() { num.get() }, format=fn(k) { "\{k}%" }) |> ignore
              @sf.button_node(r, fn() { "加 10" }, fn() { num.set(if num.get() <= 90 { num.get() + 10 } else { 100 }) }, tone=Ghost)
              |> ignore
            })
          },
        ),
      ],
    },
    // 4. Overlays
    {
      key: "motion-overlays",
      group: motion_group,
      name: "浮层与热接力 Overlays",
      file: "libs/mbui/src/motion/tools.mbt",
      api: [("tools.mbt", "overlay_presence")],
      play: None,
      about: "居中弹窗、锚点浮层与菜单、同组提示热接力，以及底部抽屉与通知条的进退场表现。",
      cases: [
        (
          "居中弹窗 Dialog / Confirm",
          fn(card) {
            let said = kept("等待操作")
            side_by_side(card, fn(r) {
              @sf.button_opens_node(r, fn() { "打开确认框" }, fn(b) {
                @sf.confirm(
                  "应用这套动效参数？",
                  "确认后会在当前示例页立即生效，按取消或 Escape 退出。",
                  "确认",
                  fn() { said.set("已确认") },
                  from=@sf.Anchor::Node(b),
                )
              })
              |> ignore
              @sf.words_node(r, fn() { said.get() }, fn() { @sf.caption }) |> ignore
            })
          },
        ),
        (
          "锚点浮层 Popover / Menu / HoverCard",
          fn(card) {
            let said = kept("尚未选择")
            side_by_side(card, fn(r) {
              @sf.button_opens_node(r, fn() { "打开面板" }, fn(b) {
                @sf.panel_nodes(
                  "动效参数",
                  fn(body, close) {
                    @sf.words_node(body, fn() { "锚点浮层沿触发器同侧展开，退场首帧释放模态。" }, fn() { @sf.meta }) |> ignore
                    @sf.button_node(body, fn() { "关闭面板" }, close, tone=Ghost) |> ignore
                  },
                  from=@sf.Anchor::Node(b),
                  fits=true,
                )
              })
              |> ignore
              @sf.button_opens_node(r, fn() { "打开菜单" }, icon="more", fn(b) {
                @sf.menu(
                  [
                    Some(@sf.menu_item_of("按时间排序", fn() { said.set("按时间排序") }, icon="list")),
                    Some(@sf.menu_item_of("按名称排序", fn() { said.set("按名称排序") }, icon="edit")),
                    None,
                    Some(@sf.menu_item_of("重置默认", fn() { said.set("重置默认") }, icon="refresh", danger=true)),
                  ],
                  from=@sf.Beside::Node(b),
                )
              })
              |> ignore
              let trigger = @sf.text_action_node(r, fn() { "悬浮预览卡" }, fn() { said.set("点击了预览触发词") })
              @sf.hover_card_node(tips, trigger, fn(b) {
                b.box(fn(col) {
                  col.gap(Is(6.0)).width(Is(Some(220.0))) |> ignore
                  @sf.words_node(col, fn() { "动效预览卡片" }, fn() { story_card_title }) |> ignore
                  @sf.words_node(col, fn() { "指针移入卡内不会收起，移出后平滑退场。" }, fn() { @sf.caption }) |> ignore
                })
                |> ignore
              })
              |> ignore
            })
            @sf.words_node(card, fn() { said.get() }, fn() { @sf.caption }) |> ignore
          },
        ),
        (
          "提示热接力 Tip",
          fn(card) {
            side_by_side(card, fn(r) {
              for item in [
                ("compose", "新建", "开始新会话"),
                ("search", "搜索", "搜索对话和文件"),
                ("sliders", "筛选", "按状态筛选列表"),
                ("settings", "设置", "外观与动效偏好"),
              ] {
                let (icon, label, tip_text) = item
                let btn = @sf.icon_button_node(r, icon, fn() { label }, fn() {  })
                @sf.tip_node(tips, btn, fn() { tip_text }) |> ignore
              }
            })
          },
        ),
        (
          "底部抽屉 Sheet 与通知 Toast",
          fn(card) {
            let shown : @signals.Signal[Array[@sf.Toast]] = kept([])
            let seq = kept(0)
            let picked = kept("未选择")
            let drop = fn(id : String) { shown.set(shown.get().filter(fn(t) { t.id != id })) }
            side_by_side(card, fn(r) {
              @sf.button_opens_node(r, fn() { "打开抽屉" }, fn(b) {
                @sf.panel_nodes(
                  "选择渲染节点",
                  fn(body, close) {
                    @sf.sheet_column_node(body, fn(col) {
                      for name in ["tokyo-mac-studio-0", "Office-Host-2", "l4es-large"] {
                        @sf.choice_row_node(
                          col,
                          fn() { name },
                          fn() { picked.get() == name },
                          press=fn() {
                            picked.set(name)
                            close()
                          },
                        )
                      }
                    })
                  },
                  from=@sf.Anchor::Node(b),
                )
              })
              |> ignore
              @sf.button_node(r, fn() { "弹出通知" }, fn() {
                let n = seq.get() + 1
                seq.set(n)
                shown.set(shown.get() + [@sf.toast("motion-toast-\{n}", "已保存动效基线", action="撤销")])
              })
              |> ignore
            })
            @sf.words_node(card, fn() { "抽屉选择：" + picked.get() }, fn() { @sf.caption }) |> ignore
            @sf.toaster_node(
              card,
              fn() { shown.get() },
              fn(t) { if t.action != "" { @sf.toast_action_ms } else { @sf.toast_ms } },
              fn() { 24.0 },
              fn(id) {
                picked.set("已撤销")
                drop(id)
              },
              drop,
              key="motion-story-toast",
            )
            |> ignore
          },
        ),
      ],
    },
    // 5. Reveal, List & Flash
    {
      key: "motion-reveal",
      group: motion_group,
      name: "揭幕与闪烁 Reveal",
      file: "libs/mbui/src/motion/tools.mbt",
      api: [("tools.mbt", "flash_way")],
      play: None,
      about: "光绘逐字揭幕、图片解码揭幕、引用定位高亮闪烁，以及列表插删的 ComeGroup 平滑让位。",
      cases: [
        (
          "光绘逐字揭幕 SpatialReveal",
          fn(card) {
            let reveal_at = kept(-1.0)
            let salt = kept(7)
            let box_ref : Ref[@view.View?] = Ref(None)
            card.box(fn(b) {
              box_ref.val = Some(b)
              b
              .padding(Is((12.0, 10.0, 12.0, 10.0)))
              .radius(Is(@sf.small_corner))
              .ground(By(fn() { @sf.theme().p.canvas }))
              .spatial_reveal(By(fn() { reveal_at.get() }), salt=By(fn() { salt.get() }))
              |> ignore
              @sf.words_node(
                b,
                fn() { "光绘揭幕在绘制阶段按阅读顺序逐行逐字渐显，零重排且不重建字形缓存。离屏与各帧率输出完全一致。" },
                fn() { @sf.paragraph },
              )
              |> ignore
            })
            |> ignore
            side_by_side(card, fn(r) {
              @sf.button_node(
                r,
                fn() { "重播揭幕" },
                fn() {
                  match box_ref.val {
                    Some(v) => {
                      salt.set(salt.untracked() + 1)
                      reveal_at.set(v.cause_at())
                    }
                    None => ()
                  }
                },
                icon="play",
              )
              |> ignore
            })
          },
        ),
        (
          "图片解码揭幕 ImageReveal",
          fn(card) {
            let img_seq = kept(0)
            let img_key = kept("")
            card.box(fn(frame) {
              frame.radius(Is(@sf.small_corner)).clips(Is(true)) |> ignore
              @sf.image_reveal_node(
                frame,
                fn() { img_key.get() },
                fn() { "" },
                fn() { 240.0 },
                fn() { 150.0 },
                comes=fn() { true },
              )
              |> ignore
            })
            |> ignore
            side_by_side(card, fn(r) {
              @sf.button_node(
                r,
                fn() { "模拟解码完成" },
                fn() {
                  let n = img_seq.untracked() + 1
                  img_seq.set(n)
                  let key = "mem:motion/reveal-\{n}"
                  @ui.add_image(key, if n % 2 == 1 { motion_png_a } else { motion_png_b })
                  img_key.set(key)
                },
                icon="play",
              )
              |> ignore
              @sf.button_node(r, fn() { "重置占位" }, fn() { img_key.set("") }, tone=Ghost) |> ignore
            })
          },
        ),
        (
          "引用定位高亮闪烁 Flash",
          fn(card) {
            let seq = kept(0)
            card.box(fn(b) {
              let lit = @motion.flash_way(b, fn() { seq.get() })
              b
              .padding(Is((12.0, 10.0, 12.0, 10.0)))
              .radius(Is(@sf.small_corner))
              .ground(By(fn() { @sf.theme().p.canvas }))
              .ground_over(By(fn() {
                let p = lit()
                if p <= 0.0 {
                  0L
                } else {
                  @ui.alpha(@sf.theme().p.accent, 0.24 * p)
                }
              }))
              .edge(By(fn() { (1.0, @sf.theme().p.line) }))
              |> ignore
              @sf.words_node(
                b,
                fn() { "被引用的消息：160ms Out 亮起，停留 740ms，再 800ms Leave 淡出。" },
                fn() { @sf.paragraph },
              )
              |> ignore
            })
            |> ignore
            side_by_side(card, fn(r) {
              @sf.button_node(r, fn() { "触发定位闪烁" }, fn() { seq.set(seq.untracked() + 1) }, icon="play") |> ignore
            })
          },
        ),
        (
          "列表插入与删除 ComeGroup",
          fn(card) {
            let items = kept([1, 2, 3])
            let next_id = kept(4)
            side_by_side(card, fn(r) {
              @sf.button_node(
                r,
                fn() { "插入一行" },
                fn() {
                  let id = next_id.untracked()
                  next_id.set(id + 1)
                  items.set([id] + items.untracked())
                },
                icon="plus",
              )
              |> ignore
              @sf.button_node(
                r,
                fn() { "删除末行" },
                fn() {
                  let cur = items.untracked()
                  if cur.length() > 1 {
                    items.set(cur[:cur.length() - 1].to_owned())
                  }
                },
                tone=Ghost,
              )
              |> ignore
            })
            card.box(fn(col) {
              col.gap(Is(6.0)) |> ignore
              col.each(fn() { items.get() }, fn(k) { k }, fn(row, k) {
                let id = k.untracked()
                row
                .padding(Is((10.0, 8.0, 10.0, 8.0)))
                .radius(Is(@sf.small_corner))
                .ground(By(fn() { @sf.theme().p.canvas }))
                .edge(By(fn() { (1.0, @sf.theme().p.line) }))
                |> ignore
                @sf.words_node(row, fn() { "动态列表条目 #\{id}" }, fn() { @sf.meta }) |> ignore
              })
            })
            |> ignore
          },
        ),
      ],
    },
    // 6. Cycles & Waiting
    {
      key: "motion-cycles",
      group: motion_group,
      name: "等待与常驻 Cycles",
      file: "libs/mbui/src/motion/tools.mbt",
      api: [
        ("tools.mbt", "breathe_alpha"),
        ("tools.mbt", "resident_cycle"),
        ("tools.mbt", "resident_step"),
      ],
      play: None,
      about: "进度条、转圈器、瞬态 60fps 与常驻 10Hz 骨架呼吸，以及更新箭头与常驻低频步进指示。",
      cases: [
        (
          "Spinner 与 ProgressBar",
          fn(card) {
            let pct : @signals.Signal[Double?] = kept(Some(0.45))
            let finish = kept(false)
            @sf.progress_node(
              card,
              fn() { pct.get() },
              fn() { @sf.theme().p.line },
              fn() { @sf.theme().p.accent },
              finishing=fn() { finish.get() },
            )
            |> ignore
            side_by_side(card, fn(r) {
              @sf.spinner_node(r, size=20.0) |> ignore
              @sf.progress_spinner_node(r, fn() { pct.get() }, size=20.0) |> ignore
              @sf.button_node(r, fn() { "25%" }, fn() {
                finish.set(false)
                pct.set(Some(0.25))
              }, tone=Ghost)
              |> ignore
              @sf.button_node(r, fn() { "75%" }, fn() {
                finish.set(false)
                pct.set(Some(0.75))
              }, tone=Ghost)
              |> ignore
              @sf.button_node(r, fn() { "100%" }, fn() {
                finish.set(false)
                pct.set(Some(1.0))
              }, tone=Ghost)
              |> ignore
              @sf.button_node(r, fn() { "不定态" }, fn() {
                finish.set(false)
                pct.set(None)
              }, tone=Ghost)
              |> ignore
              @sf.button_node(r, fn() { "完成光波" }, fn() {
                pct.set(Some(1.0))
                finish.set(true)
              }, tone=Ghost)
              |> ignore
            })
          },
        ),
        (
          "骨架呼吸 Breathe（瞬态 60fps vs 常驻 10Hz）",
          fn(card) {
            side_by_side(card, fn(r) {
              r.box(fn(col) {
                col.gap(Is(6.0)) |> ignore
                @sf.words_node(col, fn() { "瞬态 60fps" }, fn() { @sf.caption }) |> ignore
                col.box(fn(b) {
                  let a = @motion.breathe_alpha(b, period_ms=1400.0, low=0.45, resident=false)
                  b
                  .width(Is(Some(136.0)))
                  .height(Is(Some(28.0)))
                  .radius(Is(@sf.small_corner))
                  .ground(By(fn() { @sf.theme().p.chip }))
                  .alpha(By(a))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
              r.box(fn(col) {
                col.gap(Is(6.0)) |> ignore
                @sf.words_node(col, fn() { "常驻 10Hz" }, fn() { @sf.caption }) |> ignore
                col.box(fn(b) {
                  let a = @motion.breathe_alpha(b, period_ms=1400.0, low=0.45, resident=true)
                  b
                  .width(Is(Some(136.0)))
                  .height(Is(Some(28.0)))
                  .radius(Is(@sf.small_corner))
                  .ground(By(fn() { @sf.theme().p.chip }))
                  .alpha(By(a))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            })
          },
        ),
        (
          "更新箭头 UpdatingMark 与常驻 10Hz 工作指示",
          fn(card) {
            side_by_side(card, fn(r) {
              @sf.updating_mark_node(r, 24.0, fn() { @sf.theme().p.accent })
              @sf.segments_node(r, 24.0, 2.5, fn() { @sf.theme().p.accent }, fn() { @sf.theme().p.bg }) |> ignore
              r.box(fn(dots) {
                dots.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
                for i in 0..<8 {
                  dots.box(fn(d) {
                    d
                    .width(Is(Some(8.0)))
                    .height(Is(Some(8.0)))
                    .radius(Is(4.0))
                    .ground(By(fn() { @sf.theme().p.accent }))
                    .alpha(By(fn() {
                      let cur = @motion.resident_step(d, 800.0, 8)
                      let dist = (cur - i + 8) % 8
                      if dist == 0 {
                        1.0
                      } else if dist == 1 {
                        0.65
                      } else if dist == 2 {
                        0.4
                      } else {
                        0.2
                      }
                    }))
                    |> ignore
                  })
                  |> ignore
                }
              })
              |> ignore
            })
          },
        ),
      ],
    },
  ]
}
