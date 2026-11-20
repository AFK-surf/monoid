// The library's facts lists, step circles, keys and round tools, words and blocks pressed (facts_list_node.mbt,
// step_circle_node.mbt, key_cap_node.mbt, text_action_node.mbt), each beside its states, what can be pressed answering
// as it does in the app.

///|
/// Their stories, after the others: `tips` the layer an icon button's name is shown in.
fn stories_u5(tips : @sf.TipLayer) -> Array[Story] {
  [
    {
      key: "facts-list",
      group: "列表",
      name: "事实表 FactsList",
      file: "facts_list_node.mbt",
      api: [("facts_list_node.mbt", "facts_list_node"), ("facts_list_node.mbt", "fact_row_node")],
      play: None,
      about: "标签加值的事实表（对话信息的来源、发起人、创建时间）：标签一列，按本语言里最宽的标签对齐，至少 80；值占满余下宽度；一行按条件显隐，不重建整表；多行的值从行顶排起，标签在它的首行上。",
      cases: [
        (
          "事实表（第三行可显隐）",
          fn(card) {
            let shown = kept(true)
            let labels = ["来源", "发起人", "最后一条"]
            @sf.facts_list_node(card, labels, fn(list) {
              @sf.fact_row_node(list, labels[0], fn(v) {
                @sf.words_node(v, fn() { "Slack · #release" }, fn() { story_fact_words }) |> ignore
              })
              @sf.fact_row_node(list, labels[1], fn(v) {
                @sf.text_action_node(v, fn() { "左子健" }, fn() { shown.set(!shown.get()) }) |> ignore
              })
              @sf.fact_row_node(list, labels[2], show=fn() { shown.get() }, fn(v) {
                @sf.words_node(v, fn() { "3 分钟前" }, fn() { story_fact_words }) |> ignore
              })
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "step-circle",
      group: "标记",
      name: "步骤圆标 StepCircle",
      file: "step_circle_node.mbt",
      api: [("step_circle_node.mbt", "step_circle_node"), ("step_circle_node.mbt", "step_circle_button_node")],
      play: None,
      about: "圆里的数字：指南的步骤（中性底、灰字）和标注的图钉（强调色圆盘、白圈、投影，可按）。数字按圆的尺寸画，不随系统字号放大；排在一段文字旁时对齐它的首行。",
      cases: [
        (
          "步骤（对齐标题首行）",
          fn(card) {
            for n in [1, 2] {
              card.box(fn(r) {
                r.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Start))) |> ignore
                @sf.step_circle_node(r, fn() { n.to_string() }, first_line=Ui, leading=L6) |> ignore
                @sf.words_node(r, fn() { "在 Slack 的应用页里打开 Socket Mode，复制生成的令牌，再回到这里粘贴" }, fn() { story_fact_words_wrap })
                .shrink(Is(1.0))
                .min_width(Is(Some(0.0)))
                |> ignore
              })
              |> ignore
            }
          },
        ),
        (
          "图钉 Pin（可按）",
          fn(card) {
            let pressed = kept(0)
            side_by_side(card, fn(r) {
              for n in [1, 2, 12] {
                @sf.step_circle_button_node(r, fn() { n.to_string() }, fn() { "标注 \{n}" }, fn(_) { pressed.set(n) }) |> ignore
              }
              @sf.words_node(r, fn() { if pressed.get() == 0 { "" } else { "按了 \{pressed.get()}" } }, fn() { story_fact_words })
              |> ignore
            })
          },
        ),
      ],
    },
    {
      key: "key-cap",
      group: "按钮",
      name: "键帽与圆钮 KeyCap",
      file: "key_cap_node.mbt",
      api: [("key_cap_node.mbt", "key_cap_node"), ("key_cap_node.mbt", "tool_round_node")],
      play: None,
      about: "键盘条上的键（终端软键盘上方的 Esc、Tab、方向键，远程画面的键行）与画面旁的圆钮。终端的键按下不抢输入焦点；方向键和 ⌫ 按住 400 ms 后每 45 ms 连发；修饰键按住时实心，读作已按下。",
      cases: [
        (
          "终端键 Tile（不抢焦点，方向键连发）",
          fn(card) {
            let typed = kept("")
            let ctrl = kept(false)
            side_by_side(card, fn(r) {
              for k in ["Esc", "Tab"] {
                @sf.key_cap_node(r, k, fn() { k }, fn() { typed.set(typed.get() + k + " ") }, look=Tile, width=56.0, height=42.0, steals_focus=false)
                |> ignore
              }
              @sf.key_cap_node(r, "Ctrl", fn() { "Control" }, fn() { ctrl.set(!ctrl.get()) }, look=Tile, width=56.0, height=42.0, held=fn() {
                ctrl.get()
              }, steals_focus=false)
              |> ignore
              @sf.key_cap_node(r, "←", fn() { "左" }, fn() { typed.set(typed.get() + "← ") }, look=Tile, width=42.0, height=42.0, steals_focus=false, repeat=true)
              |> ignore
              @sf.key_cap_node(r, "⏎", fn() { "发送" }, fn() { typed.set("") }, look=Tile, width=56.0, height=42.0, primary=true, steals_focus=false)
              |> ignore
            })
            @sf.words_node(card, fn() { typed.get() }, fn() { story_fact_words }) |> ignore
          },
        ),
        (
          "键行 Pill（修饰键按住时实心）",
          fn(card) {
            let shift = kept(false)
            side_by_side(card, fn(r) {
              @sf.key_cap_node(r, "Esc", fn() { "Esc" }, fn() {  }) |> ignore
              @sf.key_cap_node(r, "⇧", fn() { "Shift" }, fn() { shift.set(!shift.get()) }, held=fn() { shift.get() }) |> ignore
              @sf.key_cap_node(r, "", fn() { "左" }, fn() {  }, icon="arrow-left") |> ignore
              @sf.key_cap_node(r, "", fn() { "鼠标右键" }, fn() {  }, icon="mouse-right", felt=ContextClick) |> ignore
            })
          },
        ),
        (
          "圆钮 Plain",
          fn(card) {
            side_by_side(card, fn(r) { @sf.tool_round_node(r, "shrink", fn() { "退出全屏" }, fn() {  }, tips~) |> ignore })
          },
        ),
        (
          "圆钮 Floating（画面上浮着的）",
          fn(card) {
            side_by_side(card, fn(r) {
              @sf.tool_round_node(r, "mouse-left", fn() { "鼠标左键" }, fn() {  }, look=Floating, felt=KeyboardTap) |> ignore
            })
          },
        ),
      ],
    },
    {
      key: "text-action",
      group: "按钮",
      name: "文字操作与可按的块 TextAction",
      file: "text_action_node.mbt",
      api: [
        ("text_action_node.mbt", "text_action_node"),
        ("text_action_node.mbt", "action_box_node"),
        ("text_action_node.mbt", "action_box_while_node"),
      ],
      play: None,
      about: "页面上不是标准按钮的可按之处：一段可按的文字（显示全部、换一个、复制邀请），和页面自己排版、整块可按的卡片或胶囊（几个里选一个时读作已选中，能展开时读作已展开，开关读作已按下；只在有去处时可按的卡片）。",
      cases: [
        (
          "文字操作",
          fn(card) {
            let n = kept(0)
            side_by_side(card, fn(r) {
              @sf.text_action_node(r, fn() { "显示全部 \{12 + n.get()} 个" }, fn() { n.set(n.get() + 1) }) |> ignore
              @sf.text_action_node(r, fn() { "换一个" }, fn() {  }) |> ignore
              @sf.text_action_node(r, fn() { "不可用" }, fn() {  }, disabled=fn() { true }) |> ignore
            })
          },
        ),
        (
          "可按的块（选中 · 展开 · 只在有去处时可按）",
          fn(card) {
            let picked = kept("a")
            let open = kept(false)
            let goes = kept(true)
            side_by_side(card, fn(r) {
              for k in ["a", "b"] {
                @sf.action_box_node(r, fn() { "机器人 " + k }, selected=fn() { picked.get() == k }, fn(_) { picked.set(k) }, fn(b) {
                  b
                  .padding(Is((12.0, 8.0, 12.0, 8.0)))
                  .radius(Is(8.0))
                  .ground(By(fn() { @ui.tree_theme().color(if picked.get() == k { AccentBg } else { Tint }) }))
                  |> ignore
                  @sf.hover_ground_node(b)
                  @sf.words_node(b, fn() { "机器人 " + k }, fn() { story_fact_words }) |> ignore
                })
                |> ignore
              }
              @sf.action_box_node(r, fn() { "权限" }, expanded=fn() { open.get() }, fn(_) { open.set(!open.get()) }, fn(b) {
                b.row(Is(true)).gap(Is(4.0)).lines_up(Is(Some(Middle))) |> ignore
                @sf.icon_node(b, "", 14.0, By(fn() { @sf.theme().p.muted }), name_now=fn() {
                  if open.get() {
                    "chevron-down"
                  } else {
                    "chevron-right"
                  }
                })
                |> ignore
                @sf.words_node(b, fn() { "权限" }, fn() { story_fact_words }) |> ignore
              })
              |> ignore
              @sf.action_box_while_node(r, fn() { goes.get() }, fn() { "下一步" }, fn(_) { goes.set(false) }, fn(b) {
                b.padding(Is((12.0, 8.0, 12.0, 8.0))).radius(Is(8.0)) |> ignore
                @sf.hover_ground_node(b, on=fn() { goes.get() })
                @sf.words_node(b, fn() { if goes.get() { "下一步 ›" } else { "没有去处" } }, fn() { story_fact_words }) |> ignore
              })
            })
          },
        ),
      ],
    },
  ] + stories_u16(tips)
}

///|
// kept across runs: a value (no field of it changes)
let story_fact_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let story_fact_words_wrap : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg)
