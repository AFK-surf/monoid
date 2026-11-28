// Wave 3 core component stories (empty_state_node, detail_page_node, hover_panel_node, beside_panel_node,
// confirm_node, ask_node, capsule_words_button_node, count_section_node, day_heading_node + change_node,
// fill_chip_node + color_swatch_node + icon_action_node + icon_action_opens_node).

///|
/// Mount an overlay host directly on the window root (when provided) tied to `card`'s lifetime, falling back to `card`
/// in headless key-enumeration contexts.
fn story_overlay_host(card : @view.View, layer : () -> @view.View?, make : (@view.View) -> Unit) -> Unit {
  match layer() {
    Some(root) => {
      root.box(fn(h) {
        h.over(Is(true)) |> ignore
        make(h)
      }).lives_with(card)
      |> ignore
    }
    None => make(card)
  }
}

///|
/// Wave 3 stories, after Wave 2's.
fn stories_wave3(tips : @sf.TipLayer, layer? : () -> @view.View? = fn() { None }) -> Array[Story] {
  [
    {
      key: "empty-state",
      group: "反馈",
      name: "空态 EmptyState",
      file: "empty_state_node.mbt",
      api: [("empty_state_node.mbt", "empty_state_node")],
      play: None,
      about: "页面或列表暂无内容时的完整居中空态：48 圆形浅底图标、居中标题、最多 320 宽的说明折行，以及底部反向折行的行动按钮区。",
      cases: [
        (
          "带图标、标题、说明与行动按钮",
          fn(card) {
            let said = kept("点击按钮体验空态行动")
            card.box(fn(box) {
              box.radius(Is(12.0)).ground(By(fn() { @sf.theme().p.card })) |> ignore
              @sf.empty_state_node(
                box,
                "inbox",
                fn() { "还没有连接的设备" },
                note=fn() { "在手机或桌面端登录同一账号后，受信任的设备会自动出现在这里。" },
                action=fn(a) {
                  @sf.button_node(a, fn() { "查看说明" }, fn() { said.set("已打开配对说明") }, tone=Ghost) |> ignore
                  @sf.button_node(a, fn() { "添加设备" }, fn() { said.set("已开始添加设备") }, tone=Primary, icon="plus")
                  |> ignore
                },
              )
              |> ignore
            })
            |> ignore
            @sf.words_node(card, fn() { said.get() }, fn() { @sf.caption }) |> ignore
          },
        ),
        (
          "仅图标与标题（无副说明与行动区）",
          fn(card) {
            card.box(fn(box) {
              box.radius(Is(12.0)).ground(By(fn() { @sf.theme().p.card })) |> ignore
              @sf.empty_state_node(box, "search", fn() { "没有匹配的对话" }) |> ignore
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "detail-page",
      group: "布局",
      name: "详情页骨架 DetailPage",
      file: "page_skeleton_node.mbt",
      api: [("page_skeleton_node.mbt", "detail_page_node")],
      play: None,
      about: "轻量级可滚动详情/表单页骨架：自动带入安全区、窄宽排法切换、顶部返回与操作区、加载态骨架屏以及内置 TipLayer。",
      cases: [
        (
          "带返回、操作按钮与可切换加载态的详情页容器",
          fn(card) {
            let loading = kept(false)
            let back_hits = kept(0)
            let refresh_hits = kept(0)
            side_by_side(card, fn(r) {
              @sf.button_node(
                r,
                fn() { if loading.get() { "显示正文" } else { "切换加载骨架" } },
                fn() { loading.set(!loading.get()) },
                tone=Ghost,
              )
              |> ignore
              @sf.words_node(
                r,
                fn() { "返回 \{back_hits.get()} 次 · 刷新 \{refresh_hits.get()} 次" },
                fn() { @sf.caption },
              )
              |> ignore
            })
            card.box(fn(frame) {
              frame
              .height(Is(Some(320.0)))
              .radius(Is(12.0))
              .ground(By(fn() { @sf.theme().p.bg }))
              .edge(By(fn() { (1.0, @sf.theme().p.line) }))
              .clips(Is(true))
              |> ignore
              @sf.detail_page_node(
                frame,
                fn() { "工作站详情" },
                fn(body) {
                  @sf.section_node(body, fn() { "运行环境" }, fn(sec) {
                    @sf.page_card_node(sec, fn(k) {
                      @sf.words_node(k, fn() { "pvg-office-2 · x64 Linux · 8 核" }, fn() { @sf.paragraph }) |> ignore
                      @sf.words_node(k, fn() { "空闲，可直接承担远端编译与门禁审计" }, fn() { @sf.caption }) |> ignore
                    })
                  })
                },
                on_back=fn() { back_hits.set(back_hits.get() + 1) },
                frame=fn() { @sf.PageFrame::{ ..@sf.no_frame, back: Some("工作站") } },
                width=fn() { frame.window_w() },
                actions=fn(a) {
                  @sf.button_node(a, fn() { "刷新" }, fn() { refresh_hits.set(refresh_hits.get() + 1) }, tone=Ghost, icon="refresh")
                  |> ignore
                },
                loading=fn() { loading.get() },
              )
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "hover-panel",
      group: "弹层",
      name: "悬停面板 HoverPanel",
      file: "hover_card_node.mbt",
      api: [("hover_card_node.mbt", "hover_panel_node"), ("hover_card_node.mbt", "hover_panel_spec")],
      play: None,
      about: "锚定在触发器旁的交互式悬停浮层面板：关闭时 0 节点懒创建，支持鼠标悬停延迟打开、点击/长按固定打开、Esc 与外部点击收起。",
      cases: [
        (
          "悬停或点击开关（支持内部按钮与 Esc 关闭）",
          fn(card) {
            let hand_ref : Ref[@sf.HoverHand?] = Ref(None)
            let picked = kept("悬停面板未打开")
            side_by_side(card, fn(r) {
              r.box(fn(anchor) {
                @sf.button_node(
                  anchor,
                  fn() { "查看工作站队列" },
                  fn() {
                    match hand_ref.val {
                      Some(h) =>
                        if (h.open)() {
                          (h.close)()
                        } else {
                          (h.hold)()
                        }
                      None => ()
                    }
                  },
                  icon="server",
                )
                |> ignore
                let hand = @sf.hover_panel_node(
                  tips,
                  anchor,
                  "队列状态",
                  fn(body, close) {
                    @sf.panel_note_node(body, fn() { "pvg-office-2 当前空闲，可直接执行构建与测试任务。" })
                    body.box(fn(actions) {
                      actions.row(Is(true)).wraps(Is(Some(8.0))).gap(Is(8.0)).padding(Is((6.0, 4.0, 6.0, 6.0)))
                      |> ignore
                      @sf.panel_button_node(actions, fn() { "刷新状态" }, fn() { picked.set("已刷新队列状态") }, tone=Accent)
                      |> ignore
                      @sf.panel_button_node(
                        actions,
                        fn() { "关闭面板" },
                        fn() {
                          picked.set("已关闭悬停面板")
                          close()
                        },
                        tone=Quiet,
                      )
                      |> ignore
                    })
                    |> ignore
                  },
                  spec=@sf.hover_panel_spec(w=300.0, tall=0.0, side=Bottom, along=Start),
                  pointed=fn() { anchor.pointed_in() },
                )
                hand_ref.val = Some(hand)
              })
              |> ignore
              @sf.words_node(r, fn() { picked.get() }, fn() { @sf.caption }) |> ignore
            })
          },
        ),
      ],
    },
    {
      key: "beside-panel",
      group: "弹层",
      name: "锚定侧浮层 BesidePanel",
      file: "beside_panel_node.mbt",
      api: [("beside_panel_node.mbt", "beside_panel_node")],
      play: None,
      about: "锚定在触发元素旁边的非模态小面板：不加遮罩、不阻断底层窗口操作，点击面板与锚点之外、按 Esc 或系统返回时收起。",
      cases: [
        (
          "点击锚点按钮开关侧浮层",
          fn(card) {
            let open = kept(false)
            let compact = kept(false)
            let status = kept("侧浮层已关闭")
            let anchor_ref : Ref[@view.View?] = Ref(None)
            side_by_side(card, fn(r) {
              let btn = @sf.button_node(
                r,
                fn() { "自定义侧边栏" },
                fn() {
                  let next = !open.get()
                  open.set(next)
                  status.set(if next { "侧浮层已打开" } else { "侧浮层已关闭" })
                },
                icon="sliders",
              )
              anchor_ref.val = Some(btn)
              @sf.words_node(r, fn() { status.get() }, fn() { @sf.caption }) |> ignore
            })
            story_overlay_host(card, layer, fn(host) {
              @sf.beside_panel_node(
                host,
                fn() { open.get() },
                fn(_) { anchor_ref.val.unwrap() },
                280.0,
                fn() { "侧边栏设置" },
                fn(body) {
                  @sf.panel_group_node(body, fn() { "显示偏好" }, fn(g) {
                    @sf.panel_switch_row_node(
                      g,
                      fn() { "紧凑列表密度" },
                      fn() { compact.get() },
                      fn(v) { compact.set(v) },
                      note=fn() { "缩小行间距以展示更多对话" },
                    )
                  })
                  body.box(fn(actions) {
                    actions.row(Is(true)).wraps(Is(Some(8.0))).gap(Is(8.0)).padding(Is((6.0, 4.0, 6.0, 6.0))) |> ignore
                    @sf.panel_button_node(
                      actions,
                      fn() { "完成设置" },
                      fn() {
                        open.set(false)
                        status.set("已保存侧边栏设置")
                      },
                      tone=Filled,
                    )
                    |> ignore
                  })
                  |> ignore
                },
                fn() {
                  open.set(false)
                  status.set("侧浮层已收起")
                },
                keeps=fn() { anchor_ref.val },
                side=Bottom,
                along=Start,
              )
            })
          },
        ),
      ],
    },
    {
      key: "confirm-dialog",
      group: "弹层",
      name: "确认弹窗节点 ConfirmNode",
      file: "confirm_node.mbt",
      api: [("confirm_node.mbt", "confirm_node")],
      play: None,
      about: "直接以树节点挂载的模态确认弹窗（无需经全局 presenter）：普通确认支持 Enter 默认触发，危险确认禁用 Enter 默认并可附带红色 warning 警示行。",
      cases: [
        (
          "普通确认与带 warning 的危险确认（直接挂载 confirm_node）",
          fn(card) {
            let mode = kept(0)
            let result = kept("尚未确认")
            side_by_side(card, fn(r) {
              @sf.button_node(r, fn() { "打开普通确认" }, fn() { mode.set(1) }) |> ignore
              @sf.button_node(r, fn() { "打开危险确认" }, fn() { mode.set(2) }, tone=Danger) |> ignore
            })
            @sf.words_node(card, fn() { "状态：" + result.get() }, fn() { @sf.caption }) |> ignore
            story_overlay_host(card, layer, fn(host) {
              @sf.confirm_node(
                host,
                fn() { mode.get() == 1 },
                fn() { "归档选中对话？" },
                fn() { "归档后会移出主列表，但历史消息仍可随时检索。" },
                fn() { "确认归档" },
                false,
                fn() {
                  mode.set(0)
                  result.set("已取消归档")
                },
                fn() {
                  mode.set(0)
                  result.set("已归档对话")
                },
              )
              @sf.confirm_node(
                host,
                fn() { mode.get() == 2 },
                fn() { "清除本地构建缓存？" },
                fn() { "此操作会删除工作站上的离线产物目录，下次构建将重新编译。" },
                fn() { "立即清除" },
                true,
                fn() {
                  mode.set(0)
                  result.set("已取消清除")
                },
                fn() {
                  mode.set(0)
                  result.set("已清除本地缓存")
                },
                warning="此操作不可撤销，请确认没有进行中的任务。",
              )
            })
          },
        ),
      ],
    },
    {
      key: "ask-dialog",
      group: "弹层",
      name: "输入询问节点 AskNode",
      file: "ask_node.mbt",
      api: [("ask_node.mbt", "ask_node")],
      play: None,
      about: "直接以树节点挂载的输入询问弹窗：内置输入框、提示语、取消与确认按钮；仅当输入非空且与初始值不同时启用提交按钮，支持密钥掩码模式。",
      cases: [
        (
          "直接挂载 ask_node（重命名与密钥输入）",
          fn(card) {
            let open_rename = kept(false)
            let open_secret = kept(false)
            let current = kept("sfstorybook")
            let token_state = kept("未配置")
            let rename_field = @ui.Field::new(text="sfstorybook")
            let secret_field = @ui.Field::new()
            side_by_side(card, fn(r) {
              @sf.button_node(
                r,
                fn() { "修改工作区名" },
                fn() { open_rename.set(true) },
                icon="edit",
              )
              |> ignore
              @sf.button_node(
                r,
                fn() { "配置访问令牌" },
                fn() { open_secret.set(true) },
                icon="key",
                tone=Ghost,
              )
              |> ignore
            })
            @sf.words_node(
              card,
              fn() { "当前名称：" + current.get() + " · 令牌：" + token_state.get() },
              fn() { @sf.caption },
            )
            |> ignore
            story_overlay_host(card, layer, fn(host) {
              @sf.ask_node(
                host,
                fn() { open_rename.get() },
                "修改工作区名称",
                rename_field,
                "sfstorybook",
                "输入新的工作区名称",
                "保存名称",
                "修改后立即同步到当前会话标题。",
                false,
                false,
                fn() { open_rename.set(false) },
                fn(v) {
                  current.set(v)
                  open_rename.set(false)
                },
              )
              @sf.ask_node(
                host,
                fn() { open_secret.get() },
                "配置访问令牌",
                secret_field,
                "",
                "sk-…",
                "保存令牌",
                "内容会以掩码显示，仅用于当前演示。",
                true,
                false,
                fn() { open_secret.set(false) },
                fn(_) {
                  token_state.set("已保存")
                  open_secret.set(false)
                },
              )
            })
          },
        ),
      ],
    },
    {
      key: "capsule-words-button",
      group: "按钮",
      name: "胶囊文字按钮 CapsuleWordsButton",
      file: "capsule_words_button_node.mbt",
      api: [("capsule_words_button_node.mbt", "capsule_words_button_node")],
      play: None,
      about: "工具栏里的短文字胶囊按钮（如页面缩放比例 100%）：与图标按钮等高（icon_button_side），圆角胶囊底色，悬停与聚焦时加深。",
      cases: [
        (
          "缩放比例与帧率切换胶囊",
          fn(card) {
            let zooms = ["75%", "100%", "125%", "150%"]
            let fps_list = ["60 fps", "120 fps", "24 fps"]
            let zoom_i = kept(1)
            let fps_i = kept(0)
            side_by_side(card, fn(r) {
              @sf.capsule_words_button_node(
                r,
                fn() { zooms[zoom_i.get()] },
                fn() { "切换缩放比例" },
                fn() { zoom_i.set((zoom_i.get() + 1) % zooms.length()) },
                fn() { story_capsule_words },
                tips~,
              )
              |> ignore
              @sf.capsule_words_button_node(
                r,
                fn() { fps_list[fps_i.get()] },
                fn() { "切换采样帧率" },
                fn() { fps_i.set((fps_i.get() + 1) % fps_list.length()) },
                fn() { story_capsule_words },
                tips~,
              )
              |> ignore
            })
            @sf.words_node(
              card,
              fn() { "当前：" + zooms[zoom_i.get()] + " · " + fps_list[fps_i.get()] },
              fn() { @sf.caption },
            )
            |> ignore
          },
        ),
      ],
    },
    {
      key: "count-section",
      group: "布局",
      name: "计数分组 CountSection",
      file: "page_wide_node.mbt",
      api: [("page_wide_node.mbt", "count_section_node")],
      play: None,
      about: "带实时数量的分组容器：窄排法在标题后以中点拼出数量（标题 · 3），宽排法在标题后挂载行内计数徽章（count_badge_node）。",
      cases: [
        (
          "随数量动态更新的分组标题",
          fn(card) {
            let count = kept(3)
            @sf.count_section_node(card, fn() { "待审批请求" }, fn() { count.get() }, fn(sec) {
              @sf.page_card_node(sec, fn(k) {
                @sf.words_node(k, fn() { "当前有 \{count.get()} 项来自工作站的待确认操作。" }, fn() { @sf.paragraph })
                |> ignore
                side_by_side(k, fn(r) {
                  @sf.button_node(
                    r,
                    fn() { "减少一项" },
                    fn() {
                      if count.get() > 0 {
                        count.set(count.get() - 1)
                      }
                    },
                    tone=Ghost,
                    disabled=fn() { count.get() == 0 },
                  )
                  |> ignore
                  @sf.button_node(r, fn() { "新增一项" }, fn() { count.set(count.get() + 1) }, tone=Primary) |> ignore
                })
              })
            })
          },
        ),
      ],
    },
    {
      key: "day-heading",
      group: "数据展示",
      name: "日期分组标题 DayHeading",
      file: "change_node.mbt",
      api: [("change_node.mbt", "day_heading_node"), ("change_node.mbt", "change_node")],
      play: None,
      about: "更新日志与时间线记录的日期标题与变更条目：窄排法以分组标题与卡片内联标签排布，宽排法按固定类型列与右对齐版本号排布。",
      cases: [
        (
          "按天分组的更新记录",
          fn(card) {
            @sf.day_heading_node(card, fn() { "今天 · 11 月 21 日" })
            @sf.change_node(
              card,
              fn() {
                [
                  { label: "新增", text: "补齐 sfstorybook Wave 3 组件故事与双视口审计门禁", fresh: true },
                  { label: "改进", text: "统一浮层与弹窗在窄屏下的页脚反向折行", fresh: false },
                ]
              },
              fn() { "0.1.10867" },
              fn() { "所有工作站空闲时自动更新" },
              fn() { true },
            )
            @sf.day_heading_node(card, fn() { "昨天 · 11 月 20 日" }, wide_in=0.0)
            @sf.change_node(
              card,
              fn() { [{ label: "修复", text: "修复高倍率字号下卡片行尾按钮截断问题", fresh: false }] },
              fn() { "0.1.10842" },
              fn() { "" },
              fn() { false },
            )
          },
        ),
      ],
    },
    {
      key: "quota-chips-actions",
      group: "数据展示",
      name: "填充芯片、色板与图标动作 FillChip",
      file: "quota_node.mbt",
      api: [
        ("quota_node.mbt", "fill_chip_node"),
        ("chat_notice_pill_node.mbt", "color_swatch_node"),
        ("own_head_node.mbt", "icon_action_node"),
        ("own_head_node.mbt", "icon_action_opens_node"),
      ],
      play: None,
      about: "组合展示配额填充芯片（fill_chip_node，支持正常/警告/耗尽刷新/进度色与紧凑尺寸）、独立标注色点（color_swatch_node）与页头图标动作按钮（icon_action_node / icon_action_opens_node）。",
      cases: [
        (
          "配额与资源填充芯片 fill_chip_node",
          fn(card) {
            side_by_side(card, fn(r) {
              @sf.fill_chip_node(
                r,
                fn() { 68 },
                fn() { "ok" },
                fn() { "5h" },
                fn() { "68%" },
                label_muted=true,
                said=fn() { "5 小时窗口剩余 68%" },
                tips~,
              )
              |> ignore
              @sf.fill_chip_node(
                r,
                fn() { 22 },
                fn() { "amber" },
                fn() { "W" },
                fn() { "22%" },
                label_muted=true,
                said=fn() { "周窗口剩余 22%" },
                tips~,
              )
              |> ignore
              @sf.fill_chip_node(
                r,
                fn() { 0 },
                fn() { "red" },
                fn() { "5h" },
                fn() { "14m" },
                label_muted=true,
                refill=fn() { true },
                said=fn() { "14 分钟后恢复额度" },
                tips~,
              )
              |> ignore
              @sf.fill_chip_node(
                r,
                fn() { 84 },
                fn() { "progress" },
                fn() { "内存" },
                fn() { "19 G" },
                small=true,
                said=fn() { "可用内存 19 GiB" },
                tips~,
              )
              |> ignore
            })
          },
        ),
        (
          "独立色点 color_swatch_node",
          fn(card) {
            side_by_side(card, fn(r) {
              for color in [0xE5704AFFL, 0xF5C518FFL, 0x30A46CFFL, 0x3E7BFAFFL] {
                r.box(fn(slot) {
                  slot
                  .row(Is(true))
                  .width(Is(Some(32.0)))
                  .height(Is(Some(32.0)))
                  .radius(Is(16.0))
                  .lines_up(Is(Some(Middle)))
                  .ground(Is(0x1C1C1EFFL))
                  |> ignore
                  @sf.color_swatch_node(slot, fn() { color })
                })
                |> ignore
              }
            })
          },
        ),
        (
          "页头图标动作按钮 icon_action_node / icon_action_opens_node",
          fn(card) {
            let said = kept("点击图标动作按钮")
            side_by_side(card, fn(r) {
              @sf.icon_action_node(r, "edit", fn() { "重命名工作站" }, fn() { said.set("已触发重命名") }, tips~)
              |> ignore
              @sf.icon_action_node(r, "refresh", fn() { "刷新工作站" }, fn() { said.set("已触发刷新") }, tips~)
              |> ignore
              @sf.icon_action_node(r, "trash", fn() { "不可用操作" }, fn() {  }, disabled=fn() { true }, tips~) |> ignore
              @sf.icon_action_opens_node(
                r,
                "more",
                fn() { "更多动作" },
                fn(b) {
                  @sf.menu(
                    [
                      Some(@sf.menu_item_of("复制工作站 ID", fn() { said.set("已复制工作站 ID") }, icon="copy")),
                      Some(@sf.menu_item_of("查看运行日志", fn() { said.set("已打开运行日志") }, icon="terminal")),
                    ],
                    from=@sf.Beside::Node(b),
                  )
                },
                tips~,
              )
              |> ignore
            })
            @sf.words_node(card, fn() { said.get() }, fn() { @sf.caption }) |> ignore
          },
        ),
      ],
    },
    {
      key: "data-table",
      group: "数据",
      name: "可排序表格 DataTable",
      file: "data_table_node.mbt",
      api: [
        ("data_table_node.mbt", "data_table_node"),
        ("data_table_node.mbt", "toggle_table_sort"),
        ("page_fixed_node.mbt", "page_fixed_node"),
      ],
      play: None,
      about: "通用可滚动、可排序数据表格：支持 Card 与 Plain 两种表面、固定表头与 1px 分割线、常驻 12pt 排序图标槽（切换排序不抖动）、前导勾选与空态。",
      cases: [
        (
          "Card 表面 · 点击列头排序 · 前导勾选",
          fn(card) {
            let sort : @signals.Signal[@sf.TableSort?] = kept(None)
            let picked : @signals.Signal[Array[String]] = kept(["a"])
            let items = [("a", "Claude 主账号", "92%"), ("b", "Codex 团队", "45%"), ("c", "Gemini 备用", "18%")]
            let ordered_keys = fn() -> Array[String] {
              let out = items.copy()
              match sort.get() {
                Some(ts) => {
                  let asc = ts.dir is @sf.SortDir::Asc
                  out.sort_by(fn(x, y) {
                    let c = if ts.col == "quota" { x.2.compare(y.2) } else { x.1.compare(y.1) }
                    if asc { c } else { -c }
                  })
                }
                None => ()
              }
              out.map(fn(x) { x.0 })
            }
            let by_key = fn(k : String) -> (String, String, String) {
              items.iter().find_first(fn(x) { x.0 == k }).unwrap_or(("", "", ""))
            }
            let on_sort = fn(c : String) { @sf.toggle_table_sort(sort, c, allow_clear=true) }
            @sf.data_table_node(card, surface=Card, max_height=fn() { 260.0 }, fn(dt) {
              dt.head(fn(h) {
                h.lead(fn(l) {
                  let all = fn() { picked.get().length() == items.length() }
                  @sf.check_node_of(
                    l,
                    all,
                    fn(on) { picked.set(if on { ["a", "b", "c"] } else { [] }) },
                    fn() { if all() { "取消全选" } else { "全选" } },
                  )
                  |> ignore
                })
                h.col(fn() { "账号" }, sort_key="name", sort=fn() { sort.get() }, on_sort~)
                h.col(
                  fn() { "剩余额度" },
                  width=fn() { Some(88.0) },
                  align=End,
                  sort_key="quota",
                  sort=fn() { sort.get() },
                  on_sort~,
                )
              })
              dt.virtual_rows(
                ordered_keys,
                fn(tr, k) {
                  let entry = by_key(k)
                  tr.lead(fn(l) {
                    let is_on = fn() { picked.get().contains(k) }
                    @sf.check_node_of(
                      l,
                      is_on,
                      fn(on) {
                        let cur = picked.untracked().filter(fn(x) { x != k })
                        if on {
                          cur.push(k)
                        }
                        picked.set(cur)
                      },
                      fn() { entry.1 },
                    )
                    |> ignore
                  })
                  tr.cell(fn(c) {
                    @sf.words_node(c, fn() { entry.1 }, fn() { @sf.theme().rows.title })
                    .shrink(Is(1.0))
                    .min_width(Is(Some(0.0)))
                    |> ignore
                  })
                  tr.cell(
                    width=fn() { Some(88.0) },
                    align=End,
                    fn(c) { @sf.words_node(c, fn() { entry.2 }, fn() { story_dt_num_words }) |> ignore },
                  )
                },
                est=44.0,
              )
            })
            |> ignore
          },
        ),
        (
          "Plain 表面 · 空态切换",
          fn(card) {
            let show_empty = kept(false)
            let sort : @signals.Signal[@sf.TableSort?] = kept(None)
            let rows = [("s1", "tokyo-mac-studio-0", "38 ms"), ("s2", "pvg-office-2", "12 ms")]
            let keys = fn() -> Array[String] {
              if show_empty.get() {
                []
              } else {
                let out = rows.copy()
                match sort.get() {
                  Some(ts) => {
                    let asc = ts.dir is @sf.SortDir::Asc
                    out.sort_by(fn(x, y) {
                      let c = if ts.col == "rtt" { x.2.compare(y.2) } else { x.1.compare(y.1) }
                      if asc { c } else { -c }
                    })
                  }
                  None => ()
                }
                out.map(fn(x) { x.0 })
              }
            }
            side_by_side(card, fn(r) {
              @sf.button_node(
                r,
                fn() { if show_empty.get() { "恢复数据" } else { "显示空态" } },
                fn() { show_empty.set(!show_empty.get()) },
                tone=Ghost,
              )
              |> ignore
            })
            @sf.data_table_node(card, surface=Plain, max_height=fn() { 180.0 }, fn(dt) {
              dt.head(fn(h) {
                h.col(fn() { "工作站" }, sort_key="name", sort=fn() { sort.get() }, on_sort=fn(c) {
                  @sf.toggle_table_sort(sort, c)
                })
                h.col(
                  fn() { "延迟" },
                  width=fn() { Some(76.0) },
                  align=End,
                  sort_key="rtt",
                  sort=fn() { sort.get() },
                  on_sort=fn(c) { @sf.toggle_table_sort(sort, c) },
                )
              })
              dt.empty(fn(em) {
                em.padding(Is((0.0, 16.0, 0.0, 16.0))) |> ignore
                @sf.words_node(em, fn() { "没有匹配的工作站" }, fn() { @sf.caption }) |> ignore
              })
              dt.rows(keys, fn(tr, k) {
                let entry = rows.iter().find_first(fn(x) { x.0 == k }).unwrap_or(("", "", ""))
                tr.view().row(Is(true)).padding(Is((8.0, 8.0, 8.0, 8.0))).gap(Is(8.0)).lines_up(Is(Some(Middle)))
                |> ignore
                tr.cell(fn(c) {
                  @sf.words_node(c, fn() { entry.1 }, fn() { @sf.theme().rows.title })
                  .shrink(Is(1.0))
                  .min_width(Is(Some(0.0)))
                  |> ignore
                })
                tr.cell(
                  width=fn() { Some(76.0) },
                  align=End,
                  fn(c) { @sf.words_node(c, fn() { entry.2 }, fn() { story_dt_num_words }) |> ignore },
                )
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
/// Tabular metadata words inside the DataTable story.
// kept across runs: a value (no field of it changes)
let story_dt_num_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false, w=Hug, tabular=true)

///|
/// Tabular metadata words inside a capsule words button.
// kept across runs: a value (no field of it changes)
let story_capsule_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false)
