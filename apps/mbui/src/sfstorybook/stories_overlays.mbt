// The library's overlays and what tells the viewer something (menu_node.mbt, confirm_node.mbt, sheet_node.mbt,
// tip_node.mbt, toast_node.mbt, hover_card_node.mbt, ask_node.mbt, notify_node.mbt, panel_node.mbt), each beside its
// states, what is pressed opening the real overlay as it does in the app.

///|
/// The overlays', the controls' and the data's stories (this file's, stories_controls.mbt's, stories_display.mbt's), in
/// that order after the others: `tips` the layer a tip and a hover card are shown in.
fn stories_wave1(tips : @sf.TipLayer) -> Array[Story] {
  stories_overlays(tips) + stories_controls(tips) + stories_display(tips)
}

///|
/// Their stories, after the others: `tips` the layer a tip and a hover card are shown in.
fn stories_overlays(tips : @sf.TipLayer) -> Array[Story] {
  [
    {
      key: "menu",
      group: "弹层",
      name: "菜单 Menu",
      file: "menu_node.mbt",
      api: [("presenters.mbt", "menu"), ("parts.mbt", "menu_item_of"), ("menu_node.mbt", "menu_node"), ("menu_node.mbt", "menu_ticks_node")],
      play: None,
      about: "按下打开的菜单：小屏从底部弹出，中屏和大屏在打开它的按钮旁边。一行可带图标、可是危险操作（红字）、可不可用（变淡、不能按）、可通向下一步（行尾箭头，不用省略号）；勾选项可多选，单选项标出当前那个；空项是分割线，隐藏的项不会留下两条相邻的线。",
      cases: [
        (
          "普通、危险、不可用与下一步",
          fn(card) {
            let said = kept("还没有选")
            side_by_side(card, fn(r) {
              @sf.button_opens_node(r, fn() { "更多操作" }, icon="more", fn(b) {
                @sf.menu(
                  [
                    Some(@sf.menu_item_of("复制链接", fn() { said.set("复制链接") }, icon="link")),
                    Some(@sf.menu_item_of("重命名", fn() { said.set("重命名") }, icon="edit")),
                    Some(@sf.menu_item_of("移到文件夹", fn() { said.set("移到文件夹") }, icon="folder", further=true)),
                    None,
                    Some(@sf.menu_item_of("导出记录", fn() {  }, icon="download", disabled=true)),
                    None,
                    Some(@sf.menu_item_of("删除对话", fn() { said.set("删除对话") }, icon="trash", danger=true)),
                  ],
                  from=@sf.Beside::Node(b),
                )
              })
              |> ignore
              @sf.words_node(r, fn() { "上次选的：" + said.get() }, fn() { @sf.caption }) |> ignore
            })
          },
        ),
        (
          "勾选项与单选项",
          fn(card) {
            let pinned = kept(true)
            let muted = kept(false)
            let sort = kept("recent")
            side_by_side(card, fn(r) {
              @sf.button_opens_node(r, fn() { "显示" }, icon="sliders", fn(b) {
                @sf.menu(
                  [
                    Some(@sf.menu_item_of("置顶的对话", fn() { pinned.set(!pinned.get()) }, icon="pin", checked=pinned.get())),
                    Some(@sf.menu_item_of("静音的对话", fn() { muted.set(!muted.get()) }, icon="bell", checked=muted.get())),
                  ],
                  from=@sf.Beside::Node(b),
                )
              })
              |> ignore
              @sf.button_opens_node(r, fn() { "排序" }, icon="list", fn(b) {
                @sf.menu(
                  [
                    Some(@sf.menu_item_of("最近活跃", fn() { sort.set("recent") }, chosen=sort.get() == "recent")),
                    Some(@sf.menu_item_of("创建时间", fn() { sort.set("created") }, chosen=sort.get() == "created")),
                    Some(@sf.menu_item_of("标题", fn() { sort.set("title") }, chosen=sort.get() == "title")),
                  ],
                  from=@sf.Beside::Node(b),
                  title="排序方式",
                )
              })
              |> ignore
            })
            @sf.words_node(
              card,
              fn() {
                let shown = [if pinned.get() { "置顶" } else { "" }, if muted.get() { "静音" } else { "" }].filter(fn(s) {
                  s != ""
                })
                let order = match sort.get() {
                  "recent" => "最近活跃"
                  "created" => "创建时间"
                  _ => "标题"
                }
                "显示：" + (if shown.is_empty() { "无" } else { shown.join("、") }) + " · 排序：" + order
              },
              fn() { @sf.caption },
            )
            |> ignore
          },
        ),
      ],
    },
    {
      key: "confirm",
      group: "弹层",
      name: "确认框 Confirm",
      file: "confirm_node.mbt",
      api: [("presenters.mbt", "confirm"), ("confirm_node.mbt", "confirm_node")],
      play: None,
      about: "做之前再问一次的对话框：标题、说明、库自带的「取消」和要做的事。危险操作的按钮是实心红色，可再带一行红色警告；Escape、返回和按外面都等于取消。",
      cases: [
        (
          "普通确认与危险确认",
          fn(card) {
            let said = kept("还没有做")
            side_by_side(card, fn(r) {
              @sf.button_opens_node(r, fn() { "发布更新" }, fn(b) {
                @sf.confirm(
                  "发布这个版本？",
                  "发布后，所有工作站会在下次空闲时更新。",
                  "发布",
                  fn() { said.set("已发布") },
                  from=@sf.Anchor::Node(b),
                )
              })
              |> ignore
              @sf.button_opens_node(r, fn() { "删除工作站" }, tone=Danger, fn(b) {
                @sf.confirm(
                  "删除这个工作站？",
                  "它上面的对话会移到别的工作站，正在跑的任务会停下。",
                  "删除",
                  fn() { said.set("已删除") },
                  danger=true,
                  warning="这一步不能撤销。",
                  from=@sf.Anchor::Node(b),
                )
              })
              |> ignore
            })
            @sf.words_node(card, fn() { "结果：" + said.get() }, fn() { @sf.caption }) |> ignore
          },
        ),
      ],
    },
    {
      key: "sheet",
      group: "弹层",
      name: "抽屉与面板列 Sheet",
      file: "sheet_column_node.mbt",
      api: [
        ("sheet_column_node.mbt", "sheet_column_node"),
        ("dialog_rows_node.mbt", "dialog_rows_node"),
        ("dialog_foot_rows_node.mbt", "dialog_foot_rows_node"),
      ],
      play: None,
      about: "小屏上的面板是从底部弹出的抽屉（sheet_node），中屏和大屏是打开它的按钮旁边的小面板或窗口中间的对话框，里面用同一套节点：sheet_column_node 是抽屉里一列的内边距；dialog_rows_node 让一列行在对话框里伸到与圆角同心的位置；dialog_foot_rows_node 是对话框脚下的行；页脚按钮放不下时反向折行，主按钮留在左下角与面板圆角同心。",
      cases: [
        (
          "一列内容、几行选项与脚下的行",
          fn(card) {
            let place = kept("tokyo")
            let said = kept("")
            side_by_side(card, fn(r) {
              @sf.button_opens_node(r, fn() { "选择工作站" }, fn(b) {
                @sf.panel_nodes(
                  "选择工作站",
                  fn(body, close) {
                    @sf.sheet_column_node(body, fn(col) {
                      @sf.words_node(col, fn() { "新对话会在选中的工作站上运行，之后也可以在对话里换。" }, fn() {
                        @sf.paragraph
                      })
                      |> ignore
                    })
                    let (list_style, row_style) = @sf.dialog_rows_node(body, 44.0)
                    body.box(fn(list) {
                      @sf.style_node(list, fn() { list_style })
                      for it in [("tokyo", "东京 · Mac Studio"), ("office", "办公室 · Mac mini"), ("cloud", "云端沙箱")] {
                        let (k, name) = it
                        list.box(fn(row) {
                          @sf.style_node(row, fn() { row_style })
                          @sf.choice_row_node(row, fn() { name }, fn() { place.get() == k }, press=fn() { place.set(k) })
                        })
                        |> ignore
                      }
                    })
                    |> ignore
                    @sf.dialog_foot_rows_node(body, @ui.style(), fn(rows) {
                      @sf.panel_row_node(rows, fn() { "添加工作站" }, fn() {
                        said.set("去添加工作站")
                        close()
                      }, icon=fn() { "plus" }, end="panel-open", plain=true)
                    })
                  },
                  foot=fn(f, close) {
                    @sf.button_node(f, fn() { "在这个工作站上开始新对话" }, fn() {
                      said.set("已选 " + place.get())
                      close()
                    }, tone=Primary)
                    |> ignore
                    @sf.button_node(f, fn() { "取消" }, close) |> ignore
                  },
                  from=@sf.Anchor::Node(b),
                )
              })
              |> ignore
              @sf.words_node(r, fn() { if said.get() == "" { "还没有选" } else { said.get() } }, fn() { @sf.caption }) |> ignore
            })
          },
        ),
      ],
    },
    {
      key: "tip",
      group: "弹层",
      name: "提示 Tip",
      file: "tip_node.mbt",
      api: [("tip_node.mbt", "tip_node"), ("tip_node.mbt", "key_caps")],
      play: None,
      about: "指针停在控件上一会儿、或键盘焦点到它上面时出现的一行说明，可带快捷键键帽；刚有一个提示消失时，下一个立刻出现。手指长按也会出现，松开后再停留片刻。",
      cases: [
        (
          "悬停或聚焦（可带快捷键）",
          fn(card) {
            side_by_side(card, fn(r) {
              let a = @sf.button_node(r, fn() { "新对话" }, fn() {  }, icon="compose")
              @sf.tip_node(tips, a, fn() { "开始一个新对话" }, shortcut="⌘N") |> ignore
              let b = @sf.button_node(r, fn() { "搜索" }, fn() {  }, icon="search")
              @sf.tip_node(tips, b, fn() { "搜索对话和文件" }, shortcut="⌘K", side=Top) |> ignore
              let c = @sf.button_node(r, fn() { "设置" }, fn() {  }, icon="settings")
              @sf.tip_node(tips, c, fn() { "外观、通知和账号" }) |> ignore
            })
          },
        ),
      ],
    },
    {
      key: "toast",
      group: "弹层",
      name: "通知条 Toast",
      file: "toast_node.mbt",
      api: [("toast_node.mbt", "toaster_node"), ("toast_node.mbt", "toast")],
      play: None,
      about: "窗口底部中间的胶囊通知：主色底、13 号字，可带一行说明和一个动作按钮（如「撤销」）。从下面淡入，到时自动消失，指针停在上面或焦点在动作上时不走；可以左右滑走，几条同时在时新的排在最下面。",
      cases: [
        (
          "成功、出错、带撤销（按下弹出）",
          fn(card) {
            let shown : @signals.Signal[Array[@sf.Toast]] = kept([])
            let n = kept(0)
            let said = kept("")
            let add = fn(title : String, description : String, action : String) {
              n.set(n.get() + 1)
              shown.set(shown.get() + [@sf.toast("story-\{n.get()}", title, description~, action~)])
            }
            let drop = fn(id : String) { shown.set(shown.get().filter(fn(t) { t.id != id })) }
            side_by_side(card, fn(r) {
              @sf.button_node(r, fn() { "已保存" }, fn() { add("已保存", "", "") }) |> ignore
              @sf.button_node(r, fn() { "发送失败" }, fn() { add("发送失败", "网络断了，恢复后会自动重发。", "") }) |> ignore
              @sf.button_node(r, fn() { "已归档" }, fn() { add("已归档 1 个对话", "", "撤销") }) |> ignore
            })
            @sf.words_node(card, fn() { if said.get() == "" { "动作按钮按下后会写在这里" } else { said.get() } }, fn() {
              @sf.caption
            })
            |> ignore
            @sf.toaster_node(
              card,
              fn() { shown.get() },
              fn(t) { if t.action != "" { @sf.toast_action_ms } else { @sf.toast_ms } },
              fn() { 24.0 },
              fn(id) {
                said.set("已撤销（\{id}）")
                drop(id)
              },
              drop,
              key="story-toast",
            )
            |> ignore
          },
        ),
      ],
    },
    {
      key: "hover-card",
      group: "弹层",
      name: "悬浮卡 HoverCard",
      file: "hover_card_node.mbt",
      api: [("hover_card_node.mbt", "hover_card_node")],
      play: None,
      about: "指针停在一个名字或链接上时，在它旁边弹出的预览卡；指针移进卡里卡不会走，移开后才收起。手指长按打开，按卡外面或 Escape 关上。卡里可以有可按的东西。",
      cases: [
        (
          "停在名字上（手指长按）",
          fn(card) {
            let said = kept("")
            side_by_side(card, fn(r) {
              @sf.words_node(r, fn() { "这一版由" }, fn() { @sf.paragraph }) |> ignore
              let name = @sf.text_action_node(r, fn() { "林小满" }, fn() { said.set("打开了林小满的资料") })
              @sf.hover_card_node(tips, name, fn(b) {
                b.box(fn(col) {
                  col.gap(Is(6.0)).width(Is(Some(240.0))) |> ignore
                  @sf.words_node(col, fn() { "林小满" }, fn() { story_card_title }) |> ignore
                  @sf.words_node(col, fn() { "设计 · 东京 · 本周发起 12 个对话" }, fn() { @sf.caption }) |> ignore
                  @sf.button_node(col, fn() { "发消息" }, fn() { said.set("给林小满发消息") }, tone=Ghost, icon="chat")
                  |> ignore
                })
                |> ignore
              })
              |> ignore
              @sf.words_node(r, fn() { "发布。" }, fn() { @sf.paragraph }) |> ignore
            })
            @sf.words_node(card, fn() { if said.get() == "" { "卡里的按钮按下后会写在这里" } else { said.get() } }, fn() {
              @sf.caption
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "ask",
      group: "弹层",
      name: "提问与待处理卡 Ask",
      file: "ask_node.mbt",
      api: [
        ("presenters.mbt", "ask"),
        ("ask_card_node.mbt", "ask_card_node"),
        ("ask_card_node.mbt", "ask_words_node"),
        ("ask_card_node.mbt", "ask_buttons_node"),
        ("ask_line_node.mbt", "ask_line_card_node"),
        ("ask_line_node.mbt", "ask_line_button_node"),
      ],
      play: None,
      about: "要用户写一句话的提问框（输入框、提示、取消与确认，可为密码）；对话里等人回答的卡（标题、说明、左下角的按钮与卡片圆角同心）；以及一行的待处理条（左边标记、文字、行尾安静的「忽略」）。",
      cases: [
        (
          "提问框（按下打开）",
          fn(card) {
            let name = kept("新对话")
            side_by_side(card, fn(r) {
              @sf.button_opens_node(r, fn() { "重命名" }, icon="edit", fn(b) {
                @sf.ask(
                  "重命名对话",
                  "保存",
                  fn(v) { name.set(v) },
                  value=name.get(),
                  placeholder="对话的名字",
                  hint="只改这台设备和工作站上看到的名字。",
                  from=@sf.Anchor::Node(b),
                )
              })
              |> ignore
              @sf.button_opens_node(r, fn() { "填写密钥" }, icon="key", fn(b) {
                @sf.ask("填写 API 密钥", "保存", fn(_) { name.set("（已存好密钥）") }, placeholder="sk-…", secret=true, from=@sf.Anchor::Node(
                  b,
                ))
              })
              |> ignore
            })
            @sf.words_node(card, fn() { "现在：" + name.get() }, fn() { @sf.caption }) |> ignore
          },
        ),
        (
          "等人回答的卡",
          fn(card) {
            let answer = kept("")
            @sf.ask_card_node(card, fn(k) {
              @sf.ask_words_node(k, fn() { "允许在 tokyo-mac-studio-0 上运行构建？" }, fn() {
                if answer.get() == "" {
                  "智能体想跑 moon check 和两项单测，大约 3 分钟。"
                } else {
                  "你选了：" + answer.get()
                }
              })
              |> ignore
              @sf.ask_buttons_node(k, fn(f) {
                @sf.button_node(f, fn() { "允许" }, fn() { answer.set("允许") }, tone=Primary, card_words=true) |> ignore
                @sf.button_node(f, fn() { "不允许" }, fn() { answer.set("不允许") }, card_words=true) |> ignore
              })
              |> ignore
            })
            |> ignore
          },
        ),
        (
          "一行待处理（可忽略）",
          fn(card) {
            let dismissed = kept(false)
            @sf.ask_line_card_node(card, fn() { false }, fn(row, stacked) {
              row.box(fn(w) {
                w.row(Is(!stacked)).gap(Is(8.0)).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                @sf.ask_line_mark_node(w, fn(m) { @sf.icon_node(m, "bell", 16.0, By(fn() { @sf.theme().p.text })) |> ignore })
                |> ignore
                w.box(fn(t) {
                  t.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                  @sf.words_node(t, fn() { if dismissed.get() { "已忽略" } else { "这个对话在等你登录 GitHub" } }, fn() {
                    @sf.paragraph
                  })
                  |> ignore
                })
                |> ignore
              })
              |> ignore
              @sf.ask_line_button_node(row, fn() { "忽略" }, 16.0, fn() { dismissed.get() }, fn() { dismissed.set(true) }) |> ignore
            })
            |> ignore
            @sf.button_node(card, fn() { "放回" }, fn() { dismissed.set(false) }, tone=Ghost) |> ignore
          },
        ),
      ],
    },
    {
      key: "notify",
      group: "反馈",
      name: "系统通知预览 Notify",
      file: "notify_node.mbt",
      api: [
        ("notify_node.mbt", "notify_preview_node"),
        ("notify_node.mbt", "way_tiles_node"),
        ("notify_node.mbt", "way_tile_node"),
        ("notify_node.mbt", "kinds_card_node"),
        ("notify_node.mbt", "kind_row_node"),
        ("notify_node.mbt", "way_row_node"),
      ],
      play: None,
      about: "通知设置页上的部件：这台设备的系统怎样显示应用的通知（macOS 右上角横幅、Windows 右下角横幅、手机顶部横幅），横幅和图标角标两种方式的开关卡片，以及按种类展开的行。",
      cases: [
        (
          "横幅预览（点下方按钮切换）",
          fn(card) {
            let look = kept(0)
            let banner = kept(true)
            let looks : Array[@sf.NoticeLook] = [MacOS, Windows, Phone(island=true)]
            card.box(fn(p) {
              p.pick(fn() { look.get() }, at_once=true, fn(at, i) {
                @sf.notify_preview_node(
                  at,
                  looks[i],
                  fn() { 340.0 },
                  fn() { banner.get() },
                  fn() { "发布清单 · 林小满" },
                  fn() { "截图换好了，你看一眼第二屏的插画。" },
                  fn() { Count(3) },
                  "launcher_icon",
                  fn() { "通知预览" },
                )
              })
            })
            |> ignore
            side_by_side(card, fn(r) {
              @sf.button_node(r, fn() { ["macOS", "Windows", "手机"][look.get()] }, fn() { look.set((look.get() + 1) % 3) }, tone=Ghost)
              |> ignore
              @sf.button_node(r, fn() { if banner.get() { "收起横幅" } else { "弹出横幅" } }, fn() { banner.set(!banner.get()) }, tone=Ghost)
              |> ignore
            })
          },
        ),
        (
          "方式与种类",
          fn(card) {
            let banner_on = kept(true)
            let badge_on = kept(false)
            let open = kept("done")
            let done_on = kept(true)
            @sf.way_tiles_node(card, fn(r) {
              @sf.way_tile_node(r, Phone(island=true), BannerWay, fn() { "横幅" }, fn() { if banner_on.get() { "已打开" } else { "已关闭" } }, fn() {
                banner_on.get()
              }, fn() { "" }, fn() { false }, fn() { banner_on.set(!banner_on.get()) })
              @sf.way_tile_node(r, Phone(island=true), BadgeWay, fn() { "图标角标" }, fn() { if badge_on.get() { "已打开" } else { "已关闭" } }, fn() {
                badge_on.get()
              }, fn() { "" }, fn() { false }, fn() { badge_on.set(!badge_on.get()) })
            })
            @sf.kinds_card_node(card, fn(k) {
              for kind in [("done", "智能体做完了", "一轮做完、等你看结果时"), ("need", "需要你处理", "要登录、要批准、要回答时")] {
                let (key, title, note) = kind
                @sf.kind_row_node(
                  k,
                  fn() { title },
                  fn() { if done_on.get() { "横幅" } else { "关闭" } },
                  fn() { note },
                  fn() { open.get() == key },
                  fn() { open.set(if open.get() == key { "" } else { key }) },
                  fn(w) {
                    @sf.way_row_node(w, fn() { "横幅" }, fn(r) {
                      @sf.switch_node(r, fn() { done_on.get() }, fn(v) { done_on.set(v) }, fn() { "横幅" })
                    })
                  },
                )
              }
            })
          },
        ),
      ],
    },
    {
      key: "panel",
      group: "弹层",
      name: "面板 Panel",
      file: "panel_node.mbt",
      api: [
        ("presenters.mbt", "panel_nodes"),
        ("panel_card_node.mbt", "panel_card_out_node"),
        ("panel_tip_node.mbt", "panel_tip_node"),
      ],
      play: None,
      about: "按钮旁边的小面板（小屏是底部抽屉）：标题、说明、内容和页脚。面板里可以放卡片（与面板圆角同心），控件的提示在面板自己的提示层里，Escape 先关提示再关面板。在面板里往里走一步：先关上这个再打开下一个，小屏上不落下遮罩。",
      cases: [
        (
          "带卡片和提示的面板",
          fn(card) {
            let said = kept("")
            side_by_side(card, fn(r) {
              @sf.button_opens_node(r, fn() { "工作站概况" }, icon="server", fn(b) {
                @sf.panel_nodes(
                  "tokyo-mac-studio-0",
                  fn(body, close) {
                    body.box(fn(k) {
                      @sf.style_node(k, fn() { @sf.panel_card_out_node(k) })
                      k.gap(Is(4.0)).padding(Is((12.0, 12.0, 12.0, 12.0))).ground(By(fn() { @sf.theme().p.card })) |> ignore
                      @sf.words_node(k, fn() { "在线 · 18 核 · 已用 83%" }, fn() { @sf.paragraph }) |> ignore
                      @sf.words_node(k, fn() { "内存剩 34 GB，磁盘剩 137 GB" }, fn() { @sf.caption }) |> ignore
                    })
                    |> ignore
                    body.box(fn(row) {
                      row.row(Is(true)).gap(Is(8.0)) |> ignore
                      let copy = @sf.button_node(row, fn() { "复制地址" }, fn() {
                        said.set("已复制地址")
                        close()
                      }, icon="copy")
                      @sf.panel_tip_node(copy, fn() { "复制这个工作站在网络里的地址" })
                    })
                    |> ignore
                  },
                  description="东京办公室的构建机",
                  from=@sf.Anchor::Node(b),
                )
              })
              |> ignore
              @sf.words_node(r, fn() { said.get() }, fn() { @sf.caption }) |> ignore
            })
          },
        ),
        (
          "在面板里往里走一步",
          fn(card) {
            let said = kept("")
            side_by_side(card, fn(r) {
              @sf.button_opens_node(r, fn() { "添加账号" }, icon="user-plus", fn(b) {
                @sf.panel_nodes(
                  "添加账号",
                  fn(body, close) {
                    for it in [("Claude", "agent"), ("Codex", "terminal"), ("Gemini", "sparks")] {
                      let (name, icon) = it
                      @sf.panel_row_node(body, fn() { name }, fn() {
                        close()
                        @sf.panel_nodes(
                          "登录 " + name,
                          fn(next, done) {
                            @sf.words_node(next, fn() { "会在浏览器里打开 " + name + " 的登录页，登录完回到这里。" }, fn() {
                              @sf.paragraph
                            })
                            |> ignore
                            @sf.button_node(next, fn() { "去登录" }, fn() {
                              said.set("去登录 " + name)
                              done()
                            }, tone=Primary)
                            |> ignore
                          },
                          from=@sf.Anchor::Node(b),
                        )
                      }, icon=fn() { icon }, end="chevron-right")
                    }
                  },
                  from=@sf.Anchor::Node(b),
                )
              })
              |> ignore
              @sf.words_node(r, fn() { said.get() }, fn() { @sf.caption }) |> ignore
            })
          },
        ),
      ],
    },
  ]
}

///|
/// A card's title in these stories (a hover card's name): the body's size, 600.
// kept across runs: a value (no field of it changes)
let story_card_title : @ui.TextStyle = @ui.text_style(size=Body, weight=Semibold, color=Fg)
