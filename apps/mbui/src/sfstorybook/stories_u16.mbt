// The library's login card and a request's card answered (login_step_card_node.mbt), each beside its states, what can
// be pressed answering as it does in the app.

///|
/// Their stories, after the others: `tips` the layer an icon button's name is shown in.
fn stories_u16(tips : @sf.TipLayer) -> Array[Story] {
  ignore(tips)
  [
    {
      key: "login-card",
      group: "卡片",
      name: "登录卡 LoginCard",
      file: "login_step_card_node.mbt",
      api: [
        ("login_step_card_node.mbt", "login_step_card_node"),
        ("login_step_card_node.mbt", "login_lines_node"),
        ("login_step_card_node.mbt", "login_paste_node"),
        ("login_step_card_node.mbt", "login_ended_node"),
        ("login_step_card_node.mbt", "step_card_node"),
      ],
      play: None,
      about: "工作站登录命令行工具的卡片（对话里 Agent 消息下、工作站页的登录）：标题和角上的 × 取消；说明行（等待时前面转圈，本设备收不到回调时标红）；设备码可点按复制；步骤按钮占满卡宽，该做的那一步是实心，按过后变灰，其他做法收在旁边的 ⋯；粘贴回填的码在输入框里，有字后末尾出现「完成」。结束后只剩一行灰字。",
      cases: [
        (
          "设备码（实心步骤 + ⋯ 其他做法，可取消）",
          fn(card) {
            let pressed = kept(false)
            let cancelled = kept(false)
            let step = fn() -> @sfbase.LoginStep? {
              Some({
                key: "story-login-device",
                label: "复制并打开",
                solid: !pressed.get(),
                busy: false,
                external: false,
                more: [@sf.menu_item_of("复制链接", fn() {  }), @sf.menu_item_of("在 willow 的浏览器中打开", fn() {  })],
                last: true,
                press: fn() { pressed.set(true) },
                told: None,
              })
            }
            @sfbase.login_step_card_node(card, fn() { if cancelled.get() { "GitHub CLI（已取消）" } else { "GitHub CLI" } }, cancel=(fn() { false }, fn() { cancelled.set(true) }), fn(c) {
              @sfbase.login_active_node(c, fn() { false }, fn(x, _) {
                @sfbase.login_lines_node(
                  x,
                  fn() { [{ words: "在 github.com 上输入这个码", red: false, busy: false, last: false }] },
                  fn() { "8F2C-41DA" },
                  step,
                  fn(_) {  },
                )
              })
            })
          },
        ),
        (
          "粘贴回填（打开登录页 ↗，填码后出现完成）",
          fn(card) {
            let field = @ui.Field::new()
            let sent = kept(false)
            @sfbase.login_step_card_node(card, fn() { "Claude Code" }, cancel=(fn() { false }, fn() {  }), fn(c) {
              @sfbase.login_active_node(c, fn() { true }, fn(x, _) {
                @sfbase.login_paste_node(
                  x,
                  fn() { { words: "在 claude.ai 上登录，把页面给出的码粘贴回来", red: false, busy: false, last: false } },
                  fn() {
                    {
                      key: "story-login-paste",
                      label: "打开登录页",
                      solid: false,
                      busy: false,
                      external: true,
                      more: [],
                      last: false,
                      press: fn() {  },
                      told: None,
                    }
                  },
                  field,
                  fn() { sent.get() },
                  fn(_) { sent.set(true) },
                )
              })
            })
          },
        ),
        (
          "等待中与本设备收不到回调（标红）",
          fn(card) {
            @sfbase.login_step_card_node(card, fn() { "Google Cloud CLI" }, cancel=(fn() { true }, fn() {  }), fn(c) {
              @sfbase.login_active_node(c, fn() { false }, fn(x, _) {
                @sfbase.login_lines_node(
                  x,
                  fn() {
                    [
                      { words: "本设备的 8085 端口已被占用", red: true, busy: false, last: false },
                      { words: "正在等浏览器回来", red: false, busy: true, last: true },
                    ]
                  },
                  fn() { "" },
                  fn() { None },
                  fn(_) {  },
                )
              })
            })
          },
        ),
        (
          "不能在这里完成（无 ×）与已结束",
          fn(card) {
            @sfbase.login_step_card_node(card, fn() { "AWS CLI" }, fn(c) {
              @sfbase.login_said_node(c, fn() { { words: "请在工作站上完成登录", red: false, busy: false, last: true } })
            })
            @sfbase.login_ended_node(card, fn() { "已在 willow 上登录 gh" }, fn() { false })
            @sfbase.login_ended_node(card, fn() { "gcloud · 登录失败" }, fn() { true })
          },
        ),
        (
          "剩下的一步 StepCard（可点 / 无去处）",
          fn(card) {
            let went = kept(0)
            @sfbase.step_card_node(card, fn() { "在手机上配对" }, fn() { if went.get() == 0 { "打开开发者选项里的无线调试" } else { "按了 \{went.get()} 次" } }, fn() {
              Some(fn() { went.set(went.get() + 1) })
            })
            @sfbase.step_card_node(card, fn() { "这台手机不能共享调试" }, fn() { "" }, fn() { None })
            // (in a column narrower than a card's least, 260, as far apart as the cards above: both all of it, the one that goes
            // somewhere no wider)
            card.box(fn(narrow) {
              narrow.width(Is(Some(260.0))).gap(Is(12.0)) |> ignore
              @sfbase.step_card_node(narrow, fn() { "在手机上配对" }, fn() { "打开开发者选项里的无线调试" }, fn() { Some(fn() {  }) })
              @sfbase.step_card_node(narrow, fn() { "这台手机不能共享调试" }, fn() { "" }, fn() { None })
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "answered-in-place",
      group: "卡片",
      name: "审批回执 Answered",
      file: "login_step_card_node.mbt",
      api: [("login_step_card_node.mbt", "answered_in_place_node"), ("login_step_card_node.mbt", "ask_outcome_node")],
      play: None,
      about: "Agent 请求卡片答复后：按钮在原处淡出，结果（圆点 + 一行字）随后在它让出的位置淡入，卡片尺寸不变；决定后的单行结果圆点对齐首行，可点开再看原卡。",
      cases: [
        (
          "按下允许或拒绝，原处换成结果",
          fn(card) {
            let ended : @signals.Signal[(Bool, String)?] = kept(None)
            @sf.ask_card_node(card, fn(k) {
              @sf.ask_words_node(k, fn() { "允许调试你的手机" }, fn() { "要装新包并看日志" }) |> ignore
              @sf.answered_in_place_node(k, fn() { ended.get().map(fn(e) { (e.0, [@ui.span(e.1)]) }) }, fn(a) {
                @sf.ask_buttons_node(a, fn(f) {
                  @sf.button_node(f, fn() { "允许" }, fn() { ended.set(Some((true, "已允许 · 1 小时"))) }, tone=Primary, card_words=true)
                  |> ignore
                  @sf.button_node(f, fn() { "拒绝" }, fn() { ended.set(Some((false, "已拒绝"))) }, tone=Ghost, card_words=true)
                  |> ignore
                })
                |> ignore
              })
            })
            |> ignore
          },
        ),
        (
          "结果行（消息头像下方的圆点对齐首行，长文案折行）",
          fn(card) {
            @sf.ask_outcome_node(card, fn() { true }, fn() { [@ui.span("已允许使用 GitHub 令牌 · 本对话内")] }, fn() { true })
            @sf.ask_outcome_node(
              card,
              fn() { false },
              fn() { [@ui.span("已拒绝使用 Production 数据库的只读账号，Agent 会改用测试环境继续排查这个问题")] },
              fn() { true },
            )
          },
        ),
      ],
    },
  ]
}
