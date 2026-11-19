// The library's secret's field, state line, points and uses (secret_field_node.mbt), each beside its states, what can
// be pressed answering as it does in the app (设置 › 安全, 密钥 and a secret's page).

///|
/// Their stories, after the others: `tips` the layer an icon button's name is shown in.
fn stories_u15(_tips : @sf.TipLayer) -> Array[Story] {
  [
    {
      key: "secret-value",
      group: "表单",
      name: "密钥字段 SecretValue",
      file: "secret_field_node.mbt",
      api: [
        ("secret_field_node.mbt", "secret_value_row_node"),
        ("secret_field_node.mbt", "secret_key_node"),
        ("secret_field_node.mbt", "secret_copy_node"),
        ("secret_field_node.mbt", "secret_mask"),
      ],
      play: None,
      about: "密钥的一个字段：名字在上，值在下一行；密的值打码到按眼睛显示（8 到 20 个点，不泄露长度），复制时 30 秒后从剪贴板清掉；行尾的键和卡片角同心。未打开的条目由保存方打码，单行显示。值折成多行时，行尾的键对齐第一行，不跨多行居中。",
      cases: [
        (
          "可显示、可复制",
          fn(card) {
            let shown = kept(false)
            card.box(fn(row) {
              @sf.secret_value_row_node(row, fn() { "访问令牌" }, fn() { "ghp_8sQ2vK0mZ4xT7bN1" }, shown=fn() { shown.get() }, mono=fn() { true }, fn(l) {
                @sf.secret_key_node(l, "eye", fn() { if shown.get() { "隐藏" } else { "显示" } }, fn() { shown.set(!shown.get()) }, icon_now=fn() {
                  if shown.get() {
                    "eye-off"
                  } else {
                    "eye"
                  }
                })
                |> ignore
                @sf.secret_copy_node(l, fn() { "ghp_8sQ2vK0mZ4xT7bN1" }, fn() { true }) |> ignore
              })
            })
            |> ignore
          },
        ),
        (
          "多行（显示的私钥，键在首行）",
          fn(card) {
            let key = "-----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW QyNTUxOQAAACBz9Lq2c3RpbGxmYWlsLXN0b3J5Ym9vay1zYW1wbGU= -----END OPENSSH PRIVATE KEY-----"
            let shown = kept(true)
            card.box(fn(row) {
              @sf.secret_value_row_node(row, fn() { "SSH 私钥" }, fn() { key }, shown=fn() { shown.get() }, mono=fn() { true }, fn(l) {
                @sf.secret_key_node(l, "eye", fn() { if shown.get() { "隐藏" } else { "显示" } }, fn() { shown.set(!shown.get()) }, icon_now=fn() {
                  if shown.get() {
                    "eye-off"
                  } else {
                    "eye"
                  }
                })
                |> ignore
                @sf.secret_copy_node(l, fn() { key }, fn() { true }) |> ignore
              })
            })
            |> ignore
          },
        ),
        (
          "未打开（单行，保存方打码）",
          fn(card) {
            card.box(fn(row) {
              @sf.secret_value_row_node(row, fn() { "密码" }, fn() { "••••••••••••" }, mono=fn() { true }, one_line=true, fn(l) {
                @sf.secret_key_node(l, "eye", fn() { "显示" }, fn() {  }) |> ignore
              })
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "status-banner",
      group: "标记",
      name: "状态行 StatusBanner",
      file: "secret_field_node.mbt",
      api: [("secret_field_node.mbt", "status_banner_line_node")],
      play: None,
      about: "一个状态单独一行：开启是绿点，未开启是琥珀点，后面是它的名字，横向居中对齐。",
      cases: [
        (
          "开启 / 未开启（可切换）",
          fn(card) {
            let on = kept(true)
            @sf.status_banner_line_node(card, fn() { on.get() }, fn() { if on.get() { "安全模式已开启" } else { "安全模式未开启" } })
            side_by_side(card, fn(r) { @sf.button_node(r, fn() { "切换" }, fn() { on.set(!on.get()) }) |> ignore })
          },
        ),
      ],
    },
    {
      key: "icon-point",
      group: "列表",
      name: "图标要点 IconPoint",
      file: "secret_field_node.mbt",
      api: [("secret_field_node.mbt", "icon_point_row_node"), ("secret_field_node.mbt", "icon_points_node")],
      play: None,
      about: "图标加一段话的要点：图标对齐文字的首行，不跨多行居中。Told 是安全模式说明里的要点（图标在 20 宽的列里，正文下面是灰色补充）；Listed 是列出的东西（设备：名字多长就多宽，放不下折到下一行）。",
      cases: [
        (
          "要点 Told",
          fn(card) {
            @sf.icon_points_node(card, fn(p) {
              @sf.icon_point_row_node(p, "server", fn() { "现在：Station 上的数据由 Station 自己保管" }, rest=fn() {
                "任何能登录这台机器的人都能读到对话和密钥。"
              })
              @sf.icon_point_row_node(p, "key", fn() { "开启后：只有受信任的设备能解开" }, rest=fn() { "新设备要由已有的受信任设备批准。" })
            })
          },
        ),
        (
          "列出的设备 Listed",
          fn(card) {
            @sf.icon_points_node(card, fn(p) {
              @sf.icon_point_row_node(p, "phone", fn() { "Pixel 9 Pro" }, look=@sf.PointLook::Listed)
              @sf.icon_point_row_node(p, "monitor", fn() { "办公室里那台名字特别长、一行放不下的 Mac Studio" }, look=@sf.PointLook::Listed)
            })
          },
        ),
      ],
    },
    {
      key: "record-row",
      group: "列表",
      name: "使用记录 RecordRow",
      file: "secret_field_node.mbt",
      api: [
        ("secret_field_node.mbt", "record_row_node"),
        ("secret_field_node.mbt", "record_rows_node"),
        ("secret_field_node.mbt", "record_how_node"),
        ("secret_field_node.mbt", "mono_words_node"),
        ("secret_field_node.mbt", "mono_line_node"),
      ],
      play: None,
      about: "一次使用：谁用的（对话名，后面可跟标记）在第一行，怎么用的在下面（是命令时用等宽字），时间在第一行的行尾、对齐那一行。",
      cases: [
        (
          "两次使用（命令 / 代理）",
          fn(card) {
            @sf.record_rows_node(card, fn(l) {
              for x in [("部署 still.fail 测试版", "gh release create v1.42.0", true, "3 分钟前"), ("排查登录失败", "经代理访问 api.github.com", false, "昨天 21:04")] {
                l.box(fn(row) {
                  @sf.record_row_node(
                    row,
                    fn(n) { @sf.words_node(n, fn() { x.0 }, fn() { story_fact_words }) |> ignore },
                    fn(h) { @sf.record_how_node(h, fn() { x.1 }, fn() { x.2 }) },
                    fn() { x.3 },
                  )
                })
                |> ignore
              }
            })
          },
        ),
        (
          "等宽字",
          fn(card) {
            side_by_side(card, fn(r) {
              @sf.mono_line_node(r, fn() { "12" }, Meta, fn() { @sf.theme().p.subtle })
              @sf.mono_line_node(r, fn() { "ripple" }, Body, fn() { @sf.theme().p.text })
            })
          },
        ),
      ],
    },
  ]
}
