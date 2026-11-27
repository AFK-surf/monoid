// The library's pickers and controls (choices_node.mbt, stops_node.mbt, pick_node.mbt, pick_bar_node.mbt,
// offers_node.mbt, chooser_node.mbt, chooser_button_node.mbt, segments_node.mbt, disclosure_key_node.mbt,
// button_while_node.mbt, tag_node.mbt, bar_place_node.mbt), each beside its states, what can be pressed answering as it
// does in the app.

///|
/// Their stories, after the overlays': `tips` the layer an icon button's name is shown in (none of these has one).
fn stories_controls(_tips : @sf.TipLayer) -> Array[Story] {
  [
    {
      key: "choices",
      group: "选择",
      name: "说明选项卡 Choices",
      file: "choices_node.mbt",
      api: [("choices_node.mbt", "choices_node")],
      play: None,
      about: "每个选项都要一句说明时用的单选卡片组：每张卡片是标题、说明和行尾的单选圆点（对齐标题那一行，不在多行中间）；选中的描边，选中后可在卡片里多出一块内容；不可用的变淡、不能按。一组只占一个 Tab 停靠，↑ ↓ 在组里移动。",
      cases: [
        (
          "单选（选中后多出内容）",
          fn(card) {
            let way = kept("threads")
            let mention = kept(true)
            @sf.choices_node(
              card,
              fn() { way.get() },
              fn() {
                [
                  ("threads", "每个话题一个对话", "推荐：Slack 里每开一个话题，就开一个新对话，互不干扰。"),
                  ("multi-session", "频道里一个对话", "整个频道共用一个对话，大家的消息按顺序排进去。"),
                  ("single", "只听我的", "只回答你自己发的消息，频道里其他人的消息不理会。"),
                ]
              },
              fn(v) { way.set(v) },
              label=fn() { "怎样接入频道" },
              icon=fn(v, k) {
                @sf.icon_node(
                  v,
                  match k {
                    "threads" => "thread"
                    "multi-session" => "chats"
                    _ => "user"
                  },
                  16.0,
                  By(fn() { @sf.theme().p.muted }),
                )
                |> ignore
              },
              extra=fn(k) {
                guard k == "multi-session" else { None }
                Some(fn(x) { @sf.switch_node(x, fn() { mention.get() }, fn(v) { mention.set(v) }, fn() { "只在被 @ 时回答" }) })
              },
              disabled=fn(k) { k == "single" },
            )
          },
        ),
      ],
    },
    {
      key: "stops",
      group: "选择",
      name: "档位滑块 Stops",
      file: "stops_node.mbt",
      api: [("stops_node.mbt", "stops_node"), ("seg.mbt", "Stops::new")],
      play: None,
      about: "几个有先后的档位（模型的推理强度：低、中、高、最高）：窄轨道上的刻度，填到当前档，胶囊写着档名。手指拖着拇指走，经过每档都有触感，松手选中手下那档；按住时拇指变成玻璃透镜。读屏读作滑块，键盘用方向键逐档调。",
      cases: [
        (
          "推理强度（拖动或按）",
          fn(card) {
            let at = kept(1)
            let stops = @sf.Stops::new()
            let labels = ["低", "中", "高", "最高"]
            @sf.stops_node(card, fn() { labels }, fn() { at.get() }, stops, said="推理强度", on_pick=fn(i) { at.set(i) }) |> ignore
            @sf.words_node(card, fn() { "现在：" + labels[at.get()] }, fn() { @sf.caption }) |> ignore
          },
        ),
      ],
    },
    {
      key: "controls-pick",
      group: "选择",
      name: "长列表选择 Pick",
      file: "pick_node.mbt",
      api: [("presenters.mbt", "pick"), ("presenters.mbt", "choice"), ("pick_node.mbt", "pick_node")],
      play: None,
      about: "选项多到要搜索时的选择：标题下是搜索框，下面每行可带说明、当前值和图标，当前选中的打勾；小屏从底部弹出，中屏和大屏在按钮旁边。键入即筛选，↑ ↓ 移动，Enter 选中。",
      cases: [
        (
          "可搜索的模型列表",
          fn(card) {
            let model = kept("sonnet")
            let models = [
              @sf.choice("opus", "Opus 5.5", note="最强，适合难题", icon="brain"),
              @sf.choice("sonnet", "Sonnet 5.5", note="又快又好", icon="sparks"),
              @sf.choice("haiku", "Haiku 5.5", note="最快", icon="zap"),
              @sf.choice("fable", "Fable 5.2", note="长文和故事", icon="text"),
              @sf.choice("gpt", "GPT-6.2 Sol", note="Codex 订阅", icon="terminal"),
              @sf.choice("gemini", "Gemini 4 Neon", note="Antigravity", icon="star"),
              @sf.choice("qwen", "Qwen 4 Max", note="通义", icon="web"),
              @sf.choice("kimi", "Kimi K3", note="暂不可用", icon="other", disabled=true),
            ]
            side_by_side(card, fn(r) {
              @sf.button_opens_node(r, fn() { "选择模型" }, icon="chevrons-up-down", fn(b) {
                @sf.pick("模型", models, model.get(), fn(k) { model.set(k) }, from=@sf.Beside::Node(b))
              })
              |> ignore
              @sf.words_node(
                r,
                fn() {
                  let k = model.get()
                  "现在：" + models.iter().find_first(fn(c) { c.key == k }).map(fn(c) { c.label }).unwrap_or(k)
                },
                fn() { @sf.caption },
              )
              |> ignore
            })
          },
        ),
      ],
    },
    {
      key: "pick-bar",
      group: "按钮",
      name: "选中文字工具条 PickBar",
      file: "pick_bar_node.mbt",
      api: [("pick_bar_node.mbt", "pick_bar_node")],
      play: None,
      about: "手指在消息里选中文字后，浮在上面的工具条：凸起底色上的胶囊，带边线和阴影；前面是带字的按钮（引用、复制、全选），一条细竖线后是只有图标的按钮（这条消息自己的操作）。按下处有涟漪。",
      cases: [
        (
          "文字按钮与图标按钮",
          fn(card) {
            let said = kept("")
            // (as wide as what it holds, as over a message's words: not across the card)
            side_by_side(card, fn(r) {
              @sf.pick_bar_node(r, [
                { label: "引用", icon: "quote", mark: false, press: fn() { said.set("引用") } },
                { label: "复制", icon: "copy", mark: false, press: fn() { said.set("复制") } },
                { label: "全选", icon: "", mark: false, press: fn() { said.set("全选") } },
                { label: "复制链接", icon: "link", mark: true, press: fn() { said.set("复制链接") } },
                { label: "分享", icon: "share", mark: true, press: fn() { said.set("分享") } },
              ])
              |> ignore
            })
            @sf.words_node(card, fn() { if said.get() == "" { "按下的会写在这里" } else { "按了：" + said.get() } }, fn() {
              @sf.caption
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "offers",
      group: "输入",
      name: "输入建议 Offers",
      file: "offers_node.mbt",
      api: [("offers_node.mbt", "offers_node"), ("offers_node.mbt", "combo_node")],
      play: None,
      about: "输入框下面随打字出现的建议列表（@ 一个人、补全一个名字）：和输入框一样宽，可带标题和刚打的字；↓ ↑ 移动、Enter 或 Tab 选中、Escape 关上，焦点一直留在输入框里。",
      cases: [
        (
          "@ 一个人（点输入框，打字筛选）",
          fn(card) {
            let field = @ui.Field::new()
            let current = @signals.signal(0)
            let closed = kept("")
            let people = ["林小满", "左子健", "陈一帆", "王可", "李明远"]
            let typed = fn() { field.text().trim(chars=" ").to_owned() }
            let found = fn() {
              let q = typed()
              people.filter(fn(p) { p.contains(q) && p != q })
            }
            card.box(fn(b) {
              b.width(Is(Some(320.0))).max_width(Is(Some(320.0))) |> ignore
              let f = @sf.input_node(b, field, placeholder="输入名字，例如 林")
              @sf.offers_node(
                b,
                f.parent().unwrap_or(f),
                fn() { f.focused() && typed() != "" && typed() != closed.get() && !found().is_empty() },
                found,
                current,
                fn(r, key, _) { @sf.words_node(r, fn() { key }, fn() { @sf.paragraph }) |> ignore },
                fn(key) { key },
                fn(i) {
                  guard @signals.untracked(found).get(i) is Some(p) else { return }
                  field.set(p, caret=p.length())
                },
                fn() { closed.set(typed()) },
                "可以提到的人",
                head=fn() { ("可以提到的人", typed()) },
              )
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "chooser",
      group: "选择",
      name: "下拉选择 Chooser",
      file: "chooser_node.mbt",
      api: [
        ("chooser_node.mbt", "chooser_node"),
        ("chooser_node.mbt", "capsule_chooser_node"),
        ("chooser_button_node.mbt", "chooser_button_node"),
      ],
      play: None,
      about: "写着当前值的按钮，按下在它下面弹出菜单，当前那个打勾，选中即关。普通的、圆胶囊的（输入框上方的提示条里）、和按钮外观的（卡片页脚角落，文字与卡片对齐）；不可用时不能按也不亮。",
      cases: [
        (
          "三种外观",
          fn(card) {
            let keep = kept("keep")
            let station = kept("tokyo")
            let mode = kept("ask")
            let stations = [("tokyo", "东京 Mac Studio"), ("office", "办公室 Mac mini"), ("cloud", "云端沙箱")]
            let modes = [("ask", "每次都问"), ("auto", "自动批准"), ("never", "从不")]
            let words = fn(all : Array[(String, String)], k : String) {
              all.iter().find_first(fn(c) { c.0 == k }).map(fn(c) { c.1 }).unwrap_or(k)
            }
            side_by_side(card, fn(r) {
              @sf.chooser_node(r, fn() { words(stations, station.get()) }, fn() { stations }, fn() { station.get() }, fn(k) {
                station.set(k)
              })
              |> ignore
              @sf.capsule_chooser_node(r, fn() { words(modes, mode.get()) }, fn() { modes }, fn() { mode.get() }, fn(k) {
                mode.set(k)
              })
              |> ignore
              @sf.chooser_button_node(
                r,
                fn() { if keep.get() == "keep" { "保持登录" } else { "不保持登录" } },
                fn() { [("keep", "保持登录"), ("not", "不保持登录")] },
                fn() { keep.get() },
                fn(k) { keep.set(k) },
              )
              |> ignore
              @sf.chooser_node(r, fn() { "不可用" }, fn() { [] }, fn() { "" }, fn(_) {  }, disabled=fn() { true }) |> ignore
            })
          },
        ),
      ],
    },
    {
      key: "segments",
      group: "进度",
      name: "工作中圆环 Segments",
      file: "segments_node.mbt",
      api: [("segments_node.mbt", "segments_node")],
      play: None,
      about: "智能体在工作时头像外的八段弧：每段 31°（共 45° 一格），圆头，第一段朝正上；按常驻时钟一步一步转，系统减少动态效果时停在第一格。颜色按底色和墨色分别给。",
      cases: [
        (
          "三种大小与颜色",
          fn(card) {
            side_by_side(card, fn(r) {
              @sf.segments_node(r, 16.0, 2.0, fn() { @sf.theme().p.accent }, fn() { @sf.theme().p.bg }) |> ignore
              @sf.segments_node(r, 24.0, 2.5, fn() { @sf.theme().p.text }, fn() { @sf.theme().p.bg }) |> ignore
              @sf.segments_node(r, 40.0, 3.0, fn() { @sf.theme().p.green }, fn() { @sf.theme().p.bg }) |> ignore
            })
          },
        ),
      ],
    },
    {
      key: "disclosure-key",
      group: "按钮",
      name: "展开键 DisclosureKey",
      file: "disclosure_key_node.mbt",
      api: [("disclosure_key_node.mbt", "disclosure_key_node")],
      play: None,
      about: "文件树里文件夹行前的小箭头：圆的，收起时朝右、展开时朝下；读屏读作带展开状态的按钮。只管自己的开合，下面的内容由调用方按开合显示。",
      cases: [
        (
          "文件夹（点箭头展开）",
          fn(card) {
            let open = kept(false)
            card.box(fn(col) {
              col.gap(Is(4.0)) |> ignore
              col.box(fn(row) {
                row.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
                @sf.disclosure_key_node(row, fn() { if open.get() { "收起 sfpages" } else { "展开 sfpages" } }, fn() { open.get() }, fn() {
                  open.set(!open.get())
                }, side=24.0)
                @sf.icon_node(row, "folder", 16.0, By(fn() { @sf.theme().p.muted })) |> ignore
                @sf.words_node(row, fn() { "sfpages" }, fn() { @sf.paragraph }) |> ignore
              })
              |> ignore
              col.show(fn() { open.get() }, fn(kids) {
                kids.padding(Is((0.0, 0.0, 0.0, 46.0))).gap(Is(4.0)) |> ignore
                @sf.words_node(kids, fn() { "chat_row_node.mbt" }, fn() { @sf.caption }) |> ignore
                @sf.words_node(kids, fn() { "notifications.mbt" }, fn() { @sf.caption }) |> ignore
                @sf.words_node(kids, fn() { "relay.mbt" }, fn() { @sf.caption }) |> ignore
              })
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "button-while",
      group: "按钮",
      name: "有条件可按的块 ButtonWhile",
      file: "text_action_node.mbt",
      api: [("text_action_node.mbt", "action_box_while_node"), ("text_action_node.mbt", "action_box_node")],
      play: None,
      about: "只在某个条件成立时才可按的块（button_while_node）：可按时是真按钮（键盘、读屏都认得），不可按时就是一块普通内容，不留透明的可按区域，也不会被点穿。两种状态同一个外观，条件一变立刻换。",
      cases: [
        (
          "可按与不可按（点下方按钮切换）",
          fn(card) {
            let on = kept(true)
            let opened = kept(0)
            @sf.action_box_while_node(card, fn() { on.get() }, fn() { "打开 tokyo-mac-studio-0 的详情" }, fn(_) {
              opened.set(opened.get() + 1)
            }, fn(v) {
              v.row(Is(true)).gap(Is(10.0)).padding(Is((12.0, 12.0, 12.0, 12.0))).radius(Is(12.0)).ground(By(fn() { @sf.theme().p.card })) |> ignore
              @sf.icon_node(v, "server", 20.0, By(fn() { @sf.theme().p.text })) |> ignore
              v.box(fn(w) {
                w.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(2.0)) |> ignore
                @sf.words_node(w, fn() { "tokyo-mac-studio-0" }, fn() { @sf.paragraph }) |> ignore
                @sf.words_node(w, fn() { if on.get() { "在线 · 可以打开详情" } else { "离线 · 没有详情可看" } }, fn() { @sf.caption })
                |> ignore
              })
              |> ignore
            })
            side_by_side(card, fn(r) {
              @sf.button_node(r, fn() { if on.get() { "设为离线" } else { "设为在线" } }, fn() { on.set(!on.get()) }, tone=Ghost) |> ignore
              @sf.words_node(r, fn() { "打开过 \{opened.get()} 次" }, fn() { @sf.caption }) |> ignore
            })
          },
        ),
      ],
    },
    {
      key: "tag",
      group: "标记",
      name: "标签 Tag",
      file: "tag_node.mbt",
      api: [("tag_node.mbt", "tag_node")],
      play: None,
      about: "一小段写在自己底色上的字（账号页的运行环境、套餐名）：18 高，说明字号、中等字重、弱化颜色，单行；系统字号放大时字和标签一起变大。只是标注，不能按。",
      cases: [
        (
          "运行环境与套餐",
          fn(card) {
            side_by_side(card, fn(r) {
              for w in ["Claude Code", "Codex", "Antigravity CLI", "Pro 套餐"] {
                r.box(fn(t) { @sf.tag_node(t, fn() { w }) }) |> ignore
              }
              r.box(fn(t) {
                @sf.tag_node(t, fn() { "实验性" }, lead=fn(l) { @sf.icon_node(l, "sparks", 12.0, By(fn() { @sf.theme().p.muted })) |> ignore })
              })
              |> ignore
            })
          },
        ),
      ],
    },
    {
      key: "bar-place",
      group: "导航",
      name: "底栏位置 BarPlace",
      file: "bar_place_node.mbt",
      api: [("bar_place_node.mbt", "bar_place_node")],
      play: None,
      about: "小屏底栏上的一个位置：28 的图标，未选中是弱色，选中的亮色图标按亮的程度叠在上面（两张图，不是逐帧换色），右上角可带一个点；读屏读作底栏的标签页。它自己不接受按，按、滑、长按都由底栏的玻璃处理，这里用下方按钮换选中的位置。",
      cases: [
        (
          "四个位置（点下方按钮换选中）",
          fn(card) {
            let lit = kept(0)
            let places = [("chats", "对话", 0L), ("bell", "通知", 1L), ("server", "工作站", 0L), ("settings", "设置", 0L)]
            card.box(fn(bar) {
              bar.row(Is(true)).gap(Is(8.0)).padding(Is((6.0, 12.0, 6.0, 12.0))).radius(Is(30.0)).ground(By(fn() { @sf.theme().p.card }))
              |> ignore
              for i, p in places {
                let (icon, name, dot) = p
                bar.box(fn(at) {
                  at.width(Is(Some(64.0))).height(Is(Some(48.0))) |> ignore
                  @sf.bar_place_node(at, icon, None, fn(_) { if lit.get() == i { 1.0 } else { 0.0 } }, fn() {
                    if dot != 0L {
                      @sf.theme().p.red
                    } else {
                      0L
                    }
                  }, fn() { name })
                })
                |> ignore
              }
            })
            |> ignore
            @sf.button_node(card, fn() { "下一个位置" }, fn() { lit.set((lit.get() + 1) % places.length()) }, tone=Ghost) |> ignore
          },
        ),
      ],
    },
  ]
}
