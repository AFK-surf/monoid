// The library's link cards (peek_cards_node.mbt): what a hover card over a link holds (a web page's tile, a pull
// request's or an issue's card, a file's, a chat's), each in a hover card's room, and a link's card in an agent's words
// (a screen's, a web service's, a terminal's), each beside its states, what can be pressed answering as it does in the
// app.

///|
/// Their stories, after the others: `tips` the layer an icon button's name is shown in (none of these has one).
fn stories_u12(_tips : @sf.TipLayer) -> Array[Story] {
  [
    {
      key: "peek-cards",
      group: "卡片",
      name: "链接预览卡 PeekCards",
      file: "peek_cards_node.mbt",
      api: [
        ("peek_cards_node.mbt", "peek_page_tile_node"),
        ("peek_cards_node.mbt", "peek_change_node"),
        ("peek_cards_node.mbt", "peek_file_head_node"),
        ("peek_cards_node.mbt", "peek_chat_head_node"),
      ],
      play: None,
      about: "指针停在链接上弹出的悬浮卡里装的内容（卡片本身是 hover_card_node）：网页的图块（站点图标、标题、去处）、拉取请求或议题的卡（状态胶囊、仓库与编号、标题、作者与事实、复制链接）、文件的卡（文件名、路径、几行内容、所在行高亮、复制路径）、对话的卡（状态标记、标题、所在工作站、链接指向的那条消息）。贴角的胶囊和按钮与卡片圆角同心。",
      cases: [
        ("网页 Page", fn(card) { story_peek_room(card, fn(b) { story_page_tile(b) }) }),
        (
          "网页带预览图 Page with picture",
          fn(card) { story_peek_room(card, fn(b) { story_page_tile(b, picture="mem:story-peek-picture") }) },
        ),
        (
          "拉取请求 PR（点下方按钮切换状态）",
          fn(card) {
            let state = kept(0)
            let states = ["open", "draft", "merged", "closed"]
            story_peek_room(card, fn(b) {
              @sfbase.peek_change_node(
                b,
                true,
                fn() { states[state.get() % states.length()] },
                fn() {
                  ["已打开", "草稿", "已合并", "已关闭"][state.get() % states.length()]
                },
                fn() { "AFK-surf/monoid #7279" },
                fn() { "5 分钟前" },
                fn() { "修好站点在金丝雀版本上的几处问题：助手、交接、时钟与日志" },
                fn() {
                  [
                    Person("zuozijian", ""),
                    Size(128, 46),
                    Chip("12 个文件"),
                    Checks("passed", "18 项检查通过"),
                  ]
                },
                fn(e) { @sfbase.peek_copy_node(e, fn() { "https://github.com/AFK-surf/monoid/pull/7279" }, "common.link.copy", story_copied) },
              )
            })
            @sf.button_node(card, fn() { "切换状态" }, fn() { state.set(state.get() + 1) }, tone=Ghost) |> ignore
          },
        ),
        (
          "文件 File",
          fn(card) {
            story_peek_room(card, fn(b) {
              @sfbase.peek_rich_node(b, fn(rich) {
                @sfbase.peek_file_head_node(rich, fn() { "peeks_node.mbt:42" }, fn() { false }, fn() {
                  "~/monoid/apps/mbui/src/sfpages/peeks_node.mbt"
                }, fn() { "3 分钟前" })
                rich.box(fn(l) {
                  @sfbase.peek_file_lines_node(
                    l,
                    fn() { 41 },
                    fn() { ["  let hand = @sf.hover_card_node(", "    tips,", "    row,"] },
                    fn() { Some(42) },
                    fn() { [] },
                  )
                })
                |> ignore
                @sfbase.peek_file_foot_node(rich, fn() { "18 KB" }, fn(f) {
                  @sfbase.peek_copy_node(f, fn() { "~/monoid/apps/mbui/src/sfpages/peeks_node.mbt" }, "web-main.preview.copyPath", story_copied)
                })
              })
            })
          },
        ),
        (
          "目录 Folder",
          fn(card) {
            story_peek_room(card, fn(b) {
              @sfbase.peek_rich_node(b, fn(rich) {
                @sfbase.peek_file_head_node(rich, fn() { "sfpages" }, fn() { true }, fn() { "~/monoid/apps/mbui/src/sfpages/" }, fn() {
                  ""
                })
                rich.box(fn(l) {
                  @sfbase.peek_file_entries_node(l, fn() { ["flows/", "peeks.mbt", "peeks_node.mbt", "hover.mbt", "moon.pkg"] })
                })
                |> ignore
                @sfbase.peek_file_foot_node(rich, fn() { "128 项" }, fn(_) {  })
              })
            })
          },
        ),
        (
          "对话 Chat（点下方按钮切换已不在）",
          fn(card) {
            let gone = kept(false)
            story_peek_room(card, fn(b) {
              b.pick(fn() { gone.get() }, fn(p, is_gone) {
                @sf.style_node(p, fn() { @sfbase.peek_card_part })
                if is_gone {
                  @sfbase.peek_note_node(p, fn() { "这个对话已经不在了" })
                  @sf.button_node(p, fn() { "恢复" }, fn() { gone.set(false) }, tone=Ghost) |> ignore
                } else {
                  @sfbase.peek_rich_node(p, fn(rich) {
                    @sfbase.peek_chat_head_node(rich, fn() { "首页的列表改成按天分组" }, ago=fn() { "5 分钟前" })
                    @sfbase.peek_chat_where_node(rich, fn() { true }, fn() { true }, fn() { "🌳" }, fn() { "" }, fn() {
                      "Willow 的工作站 · 执行记录"
                    })
                    rich.box(fn(q) {
                      @sf.style_node(q, fn() { @sfbase.peek_card_part })
                      @sfbase.peek_message_node(q, fn() { "林小满 · 5 分钟前" }, fn() {
                        "列表按天分组做好了，今天、昨天和更早三段，各段里按最后活跃排序。"
                      })
                    })
                    |> ignore
                  })
                  @sf.button_node(p, fn() { "标为已不在" }, fn() { gone.set(true) }, tone=Ghost) |> ignore
                }
              })
            })
          },
        ),
      ],
    },
    {
      key: "link-card",
      group: "卡片",
      name: "链接卡 LinkCard",
      file: "peek_cards_node.mbt",
      api: [("peek_cards_node.mbt", "link_card_node"), ("peek_cards_node.mbt", "link_words_node")],
      play: None,
      about: "智能体消息里单独成段的屏幕、网页服务、终端链接画成的胶囊卡：左边类型图标（未知时留位），标题在上、状态在下；屏幕已不在时标题变弱；点按打开链接。",
      cases: [
        (
          "屏幕、服务、终端（点卡片切换已不在）",
          fn(card) {
            let gone = kept(false)
            card.box(fn(col) {
              col.gap(Is(12.0)) |> ignore
              @sfbase.link_card_node(col, fn() { Some("monitor") }, fn() { "Willow 的屏幕" }, fn() {
                if gone.get() { "已不在" } else { "1920 × 1080 · 在线" }
              }, fn() { gone.get() }, fn() { gone.set(!gone.get()) })
              @sfbase.link_card_node(col, fn() { Some("web") }, fn() { "预览服务" }, fn() { "Willow · 端口 5173 · 运行中" }, fn() {
                false
              }, fn() {  })
              @sfbase.link_card_node(col, fn() { Some("terminal") }, fn() { "构建终端" }, fn() { "moon test 正在跑" }, fn() { false }, fn() {

              })
            })
            |> ignore
          },
        ),
      ],
    },
  ]
}

///|
/// A hover card's room round what `make` makes: 320 wide, the small panel's look, its words 10 in.
fn story_peek_room(card : @view.View, make : (@view.View) -> Unit) -> Unit {
  card.box(fn(p) {
    @sf.small_panel_node(p).width(Is(Some(320.0))) |> ignore
    p.box(fn(inner) {
      let pad = @ui.Space::px(S2_5)
      inner.padding(Is((pad, pad, pad, pad))).gap(Is(@ui.Space::px(S2))) |> ignore
      make(inner)
    })
    |> ignore
  })
  |> ignore
}

///|
/// A page's tile with its address to copy, its picture over it where `picture` names one (an image's key: one never
/// given, its ground alone, as a card shows it while its picture comes).
fn story_page_tile(b : @view.View, picture? : String = "") -> Unit {
  b.box(fn(p) {
    @sf.style_node(p, fn() { @sfbase.peek_card_part })
    @sfbase.peek_page_tile_node(
      p,
      fn() { "MoonBit：为云与边缘计算设计的编程语言" },
      fn() { "moonbitlang.com" },
      fn() { "" },
      fn() { false },
      fn() { picture },
      fn(f) { @sfbase.peek_copy_node(f, fn() { "https://www.moonbitlang.com/" }, "common.link.copy", story_copied) },
    )
  })
  |> ignore
}

///|
/// When each address or path was last copied from these stories' cards.
// kept across runs: only the stories' cards' copies, let go with the page
let story_copied : Map[String, Double] = Map([])
