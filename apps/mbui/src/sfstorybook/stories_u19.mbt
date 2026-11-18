// The library's lines of a chat's list, its notice's pill, the words pressed to say them the other way, marking's
// colours and the cards over a chats' list (chat_notice_pill_node.mbt), each beside its states, what can be pressed
// answering as it does in the app.

///|
/// Their stories, after the others: `tips` the layer a card's × names itself in.
fn stories_u19(tips : @sf.TipLayer) -> Array[Story] {
  [
    {
      key: "list-lines",
      group: "列表",
      name: "列表里的行 ListLines",
      file: "chat_notice_pill_node.mbt",
      api: [
        ("chat_notice_pill_node.mbt", "labeled_rule_node"),
        ("chat_notice_pill_node.mbt", "list_coming_node"),
        ("chat_notice_pill_node.mbt", "list_failed_node"),
        ("chat_notice_pill_node.mbt", "list_none_node"),
        ("chat_notice_pill_node.mbt", "empty_words_node"),
      ],
      play: None,
      about: "对话列表里消息之外的行：两侧细线夹着居中文字的分隔行（以下为未读），翻页时居中的转圈，读不到更早消息时的原因，一条消息都没有时的说明；以及一处什么都没有时居中的灰字（可在下面接一个按钮）。",
      cases: [
        ("未读分隔线", fn(card) { @sf.labeled_rule_node(card, fn() { "以下为未读消息" }) |> ignore }),
        (
          "翻页中 · 读不到 · 没有消息",
          fn(card) {
            @sf.list_coming_node(card, fn() { true }) |> ignore
            @sf.list_failed_node(card, fn() { "读不到更早的消息：连接断开了" }) |> ignore
            @sf.list_none_node(card, fn() { "还没有消息" }) |> ignore
          },
        ),
        (
          "空状态（带按钮）",
          fn(card) {
            card.height(Is(Some(200.0))) |> ignore
            @sf.empty_words_node(card, fn() { "还没有收藏的文件夹" }, more=fn(e) {
              @sf.button_node(e, fn() { "添加收藏" }, fn() {  }, tone=Primary) |> ignore
            })
          },
        ),
      ],
    },
    {
      key: "notice-pill",
      group: "对话",
      name: "系统通知胶囊 NoticePill",
      file: "chat_notice_pill_node.mbt",
      api: [
        ("chat_notice_pill_node.mbt", "notice_pill_node"),
        ("chat_notice_pill_node.mbt", "notice_end_action_node"),
        ("chat_notice_pill_node.mbt", "words_button_node"),
      ],
      play: None,
      about: "still.fail 在对话里说的话：居中的胶囊，一行字放不下就截短；同样的话折叠成 ×n 跟在字后；末尾可接一个「· 动作」；按一下展开，下面是出错的原文，再按收起。失败的胶囊是红底。时间是可按的字，按一下所有时间换一种说法。",
      cases: [
        (
          "收起 · 展开（失败，×3）",
          fn(card) {
            let open = kept(false)
            card.lines_up(Is(Some(Middle))) |> ignore
            @sf.notice_pill_node(
              card,
              fn() { "智能体出错了：请求太频繁 ×3" },
              fn() { open.get() },
              fn() { true },
              fn() { 3 },
              fn() { open.set(!open.get()) },
              fn(room) { @sf.words_node(room, fn() { "智能体出错了：请求太频繁" }, fn() { story_notice_words }) |> ignore },
              detailed=fn() { true },
              detail=fn(d) { @sf.words_node(d, fn() { "429 rate_limit_error" }, fn() { story_fact_words_wrap }) |> ignore },
            )
            |> ignore
          },
        ),
        (
          "普通通知",
          fn(card) {
            card.lines_up(Is(Some(Middle))) |> ignore
            @sf.notice_pill_node(
              card,
              fn() { "已切换到 claude-opus-5-5" },
              fn() { false },
              fn() { false },
              fn() { 1 },
              fn() {  },
              fn(room) { @sf.words_node(room, fn() { "已切换到 claude-opus-5-5" }, fn() { story_notice_words }) |> ignore },
            )
            |> ignore
          },
        ),
        (
          "可按的时间",
          fn(card) {
            let full = kept(false)
            @sf.words_button_node(card, fn() { if full.get() { "11月18日 14:56" } else { "3 分钟前" } }, fn() {
              story_time_words
            }, fn() { full.set(!full.get()) })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "color-swatches",
      group: "选择",
      name: "颜色色板 ColorSwatches",
      file: "chat_notice_pill_node.mbt",
      api: [("chat_notice_pill_node.mbt", "color_swatches_node"), ("chat_notice_pill_node.mbt", "color_swatch_node")],
      play: None,
      about: "标注的颜色：一组单选的色点（方向键在色点间移动），选中的一个衬白色 16% 的圆底；色点是 16 的圆盘，内缘一圈半透明白环。",
      cases: [
        (
          "色板",
          fn(card) {
            let chosen = kept(0xE5704AFFL)
            card.box(fn(row) {
              row.row(Is(true)).lines_up(Is(Some(Middle))).padding(Is((4.0, 4.0, 4.0, 4.0))).gap(Is(2.0)).radius(Is(20.0)).ground(Is(0x1C1C1EFFL))
              |> ignore
              let colors = [0xE5704AFFL, 0xE5484DFFL, 0xF5C518FFL, 0x30A46CFFL, 0x3E7BFAFFL, 0xFFFFFFFFL]
              @sf.color_swatches_node(row, fn() { "颜色" }, colors.mapi(fn(i, c) { (c, "颜色 \{i + 1}") }), fn() { chosen.get() }, fn(c) {
                chosen.set(c)
              })
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "news-card",
      group: "卡片",
      name: "更新卡片 NewsCard",
      file: "chat_notice_pill_node.mbt",
      api: [("chat_notice_pill_node.mbt", "news_card_node")],
      play: None,
      about: "对话列表顶上的卡片：上次更新带来的改动（整张可按，打开更新日志；右上角 × 与卡片圆角同心，关掉后不再显示），以及更新要人做的事（没有 ×，做完自己消失）。",
      cases: [
        (
          "更新日志",
          fn(card) {
            let gone = kept(false)
            card.show(fn() { !gone.get() }, fn(b) {
              @sf.news_card_node(
                b,
                "sparks",
                fn() { "已更新到 1389" },
                fn() { "已更新到 1389" },
                fn() {  },
                fn(w) {
                  @sf.words_node(w, fn() { "新增：对话页的系统通知可展开" }, fn() { @sf.news_card_line }) |> ignore
                  @sf.words_node(w, fn() { "改进：标注颜色可用方向键选择" }, fn() { @sf.news_card_line }) |> ignore
                },
                close=(tips, fn() { "不再显示" }, fn() { gone.set(true) }),
              )
              |> ignore
            })
          },
        ),
        (
          "允许安装更新",
          fn(card) {
            @sf.news_card_node(card, "download", fn() { "允许安装更新" }, fn() { "允许安装更新" }, fn() {  }, fn(w) {
              @sf.words_node(w, fn() { "给 still.fail 安装应用的权限，新版本下载好后会自动装上。" }, fn() { @sf.news_card_note })
              |> ignore
            })
            |> ignore
          },
        ),
      ],
    },
  ]
}

///|
/// A notice's words in the stories: small, one line.
// kept across runs: a value (no field of it changes)
let story_notice_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L7, color=Fg, wrap=false)

///|
/// A time in the stories: small and muted.
// kept across runs: a value (no field of it changes)
let story_time_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false)
