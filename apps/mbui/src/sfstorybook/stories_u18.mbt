// The library's form parts (form_swatch_node.mbt): an app's look picked (its icon's well, its colour's swatch and field,
// the avatars to start from), its permissions folded and ticked, a place to pick, where a connect stands on its head's
// line, words pressed quietly, each beside its states, what can be pressed answering as it does in the app.

///|
/// Their stories, after the others: `tips` the layer an icon button's name is shown in.
fn stories_u18(tips : @sf.TipLayer) -> Array[Story] {
  [
    {
      key: "app-look",
      group: "输入",
      name: "应用外观 AppLook",
      file: "form_swatch_node.mbt",
      api: [
        ("form_swatch_node.mbt", "icon_well_node"),
        ("form_swatch_node.mbt", "swatch_field_node"),
        ("form_swatch_node.mbt", "avatar_tiles_node"),
      ],
      play: None,
      about: "一个应用的外观（Slack app 的头像与底色）：图标框（按下换一张自己的图，没有图时是上传标记和说明，字色取能在底色上读清的黑或白）；底色色块挨着它的十六进制输入框；起始头像一行 15 个，放不下时更少，每格是正方形，选中的那格描深边，指针下描悬停边。",
      cases: [
        (
          "图标框与底色（空 · 选了头像）",
          fn(card) {
            let hex = @ui.Field::new(text="#4A154B")
            let picked = kept("")
            let ground = fn() { @sf.hex_color(hex.text()).unwrap_or(@sf.theme().p.neutral_bg) }
            let ink = fn() {
              match @sf.hex_color(hex.text()) {
                Some(v) => @ui.ink_on(v, [0x24272BFFL, 0xFFFFFFFFL])
                None => @sf.theme().p.muted
              }
            }
            card.box(fn(r) {
              r.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Start))) |> ignore
              @sf.icon_well_node(r, fn() { "上传图标" }, fn() {  }, ground, ink, fn() { "" }, fn() { "上传" }, @sf.app_icon_px) |> ignore
              r.box(fn(m) {
                @sf.style_node(m, fn() { story_u18_main }, in_row=true)
                @sf.swatch_field_node(m, hex, ground, "颜色", after=fn(c) {
                  c.show(fn() { hex.text() != "#4A154B" }, fn(s) {
                    @sf.quiet_action_node(s, fn() { "推荐色" }, fn() { hex.set("#4A154B") }) |> ignore
                  })
                })
                |> ignore
                @sf.words_node(m, fn() { if picked.get() == "" { "还没选头像" } else { "选了 " + picked.get() } }, fn() { story_u18_words })
                |> ignore
              })
              |> ignore
            })
            |> ignore
            @sf.avatar_tiles_node(card, fn() { @sf.app_makers }, fn() { picked.get() }, fn() { 600.0 }, fn(a) {
              picked.set(a.id)
              hex.set(a.bg)
            }, tips)
            |> ignore
          },
        ),
      ],
    },
    {
      key: "check-groups",
      group: "选择",
      name: "权限勾选组 CheckGroups",
      file: "form_swatch_node.mbt",
      api: [("form_swatch_node.mbt", "check_groups_node")],
      play: None,
      about: "折起来的权限：一行说开了几个、共几个，按它展开；有没开的时行尾可一键全开。展开后每节一个标题和全选 / 全不选（固定开着的那组不动），放得下时每行三组，窄了每行两组或一组（有需管理员的组时每列要宽些，系统字号放大时也一样），每组一个勾选框和名字，只有管理员能批的在名字后注明，悬停说它允许什么。",
      cases: [
        ("收起 · 展开（读消息固定开着，成员需管理员）", fn(card) { story_u18_checks(card, tips) }),
        (
          "窄处 320 宽：放不下三列时两列或一列",
          fn(card) {
            card.box(fn(b) {
              b.max_width(Is(Some(320.0))) |> ignore
              story_u18_checks(b, tips)
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "place-row",
      group: "选择",
      name: "地点行 PlaceRow",
      file: "form_swatch_node.mbt",
      api: [("form_swatch_node.mbt", "place_row_node"), ("form_swatch_node.mbt", "place_note_node")],
      play: None,
      about: "接力时选的频道、群或回复的机器人：先是它的标记，再是名字（过长截断），余下的空间后是行尾说明；选中时在强调色底上、字用强调色，不能选的名字变淡，可按时指针下是悬停灰。",
      cases: [
        (
          "可选 · 选中 · 不能选",
          fn(card) {
            let chosen = kept("#dev")
            for p in [("#dev", "接力到这里", true), ("#release", "接力到这里", true), ("#ops", "需要频道里的人邀请", false)] {
              let (name, note, can) = p
              @sf.place_row_node(
                card,
                fn() { name },
                fn(b) { @sf.origin_mark_node(b, fn() { "slack" }, 16.0) |> ignore },
                fn() { chosen.get() == name },
                selected=fn() { chosen.get() == name },
                can=fn() { can },
                press=fn() { if can { chosen.set(name) } },
                end=fn(b) { @sf.place_note_node(b, fn() { note }, fn() { chosen.get() == name }) |> ignore },
              )
            }
          },
        ),
      ],
    },
    {
      key: "head-state",
      group: "标记",
      name: "连接状态行 HeadState",
      file: "form_swatch_node.mbt",
      api: [("form_swatch_node.mbt", "head_state_node"), ("form_swatch_node.mbt", "bot_tile_node")],
      play: None,
      about: "连接头部名字下的状态行：正在重连、切换或保存时一个转圈加说明；刚失败时一个红色标记加说明；否则是它的状态点和状态。机器人的头像填满它的方块（Slack 那样的方形应用图标），图片解码前和没有图片时是它平台的标记。",
      cases: [
        (
          "在线 · 正在重连 · 失败（点一下换）",
          fn(card) {
            let k = kept(0)
            card.box(fn(r) {
              r.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
              @sf.bot_tile_node(r, fn() { "" }, 40.0, fn(t, size) { @sf.drawable_node(t, "slack", size) |> ignore }) |> ignore
              r.box(fn(st) {
                st.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
                @sf.head_state_node(
                  st,
                  fn() { if k.get() == 1 { "正在重连" } else { "" } },
                  fn() { if k.get() == 2 { "重连失败" } else { "" } },
                  fn() { "online" },
                  fn() { "已连接" },
                  fn(p) { @sf.icon_node(p, "close", 14.0, By(fn() { @sf.theme().p.red })) |> ignore },
                )
              })
              |> ignore
              @sf.quiet_action_node(r, fn() { "换一种" }, fn() { k.set((k.get() + 1) % 3) }) |> ignore
            })
            |> ignore
          },
        ),
      ],
    },
  ]
}

///|
/// The permissions of check-groups' cases in `card`: two sections, 读消息 fixed on, 成员 only admins allow; open at first.
fn story_u18_checks(card : @view.View, tips : @sf.TipLayer) -> Unit {
  let on : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()
  on["read"] = true
  on["write"] = true
  let open = kept(true)
  @sf.check_groups_node(
    card,
    fn() {
      [
        {
          title: "消息",
          groups: [
            { id: "read", label: "读消息", tip: "读它在的频道里的消息", fixed: true, admin: false },
            { id: "write", label: "发消息", tip: "在频道里回复", fixed: false, admin: false },
            { id: "files", label: "文件", tip: "读和传文件", fixed: false, admin: false },
          ],
        },
        {
          title: "工作区",
          groups: [
            { id: "users", label: "成员", tip: "读成员的名字和头像", fixed: false, admin: true },
            { id: "channels", label: "频道", tip: "列出频道", fixed: false, admin: false },
          ],
        },
      ]
    },
    fn(id) { on.get(id).unwrap_or(false) },
    fn(id, now) { on[id] = now },
    fn() { open.get() },
    fn() { open.set(!open.get()) },
    {
      summary: fn(n, all) { "权限：开了 \{n} 个，共 \{all} 个" },
      all_on: fn() { "全部开启" },
      select_all: fn() { "全选" },
      select_none: fn() { "全不选" },
      admin: fn() { "需管理员" },
    },
    tips,
  )
}

///|
// kept across runs: a value (no field of it changes)
let story_u18_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let story_u18_main : @ui.Style = @ui.style(w=@sf.grow, gap=S2)
