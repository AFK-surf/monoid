// Wave 2 core component stories (chip_tabs_node, row_box_node + row_tag_node, empty_node + page_none_node +
// section_none_node, link_row_node + link_row_opens_node + list_card_node, page_card_node + section_node +
// corner_row_node, panel_group_node + panel_note_node + panel_button_node + panel_switch_row_node,
// search_combo_node + combo_node, segmented_node + seg_head_node, steps_node, way_in_node + way_in_button_node +
// way_in_note_node + pick_tiles_node + video_capsule_node).

///|
/// Wave 2 stories, after Wave 1's.
fn stories_wave2(_tips : @sf.TipLayer) -> Array[Story] {
  [
    {
      key: "chip-tabs",
      group: "选择",
      name: "芯片标签页 ChipTabs",
      file: "filter_pill_node.mbt",
      api: [("filter_pill_node.mbt", "chip_tabs_node")],
      play: None,
      about: "一组横向排列的胶囊标签页（看板分栏、对话分组筛选）：整组占一个 Tab 停靠，← → 和 Home / End 在标签间切换；调用方按 RadioRow 的 picked / lit 状态画出选中底色与悬停态。",
      cases: [
        (
          "分组切换（点击或方向键切换）",
          fn(card) {
            let tab = kept("all")
            let keys = ["all", "active", "waiting", "done"]
            let label_of = fn(k : String) {
              match k {
                "all" => "全部"
                "active" => "进行中"
                "waiting" => "待处理"
                _ => "已完成"
              }
            }
            card.box(fn(row) {
              row.row(Is(true)).wraps(Is(Some(8.0))).gap(Is(8.0)) |> ignore
              @sf.chip_tabs_node(
                row,
                fn() { "对话分组" },
                keys,
                fn() { tab.get() },
                fn(k) { tab.set(k) },
                label_of,
                fn(c, k, item) {
                  c
                  .row(Is(true))
                  .min_height(By(fn() { Some(@sf.theme().items.least) }))
                  .padding(Is((14.0, 0.0, 14.0, 0.0)))
                  .lines_up(Is(Some(Middle)))
                  .radius(By(fn() { @sf.theme().items.least / 2.0 }))
                  .ground(By(fn() {
                    if item.picked() {
                      @sf.theme().p.text
                    } else if item.lit() {
                      @sf.theme().p.hover
                    } else {
                      @sf.theme().p.card
                    }
                  }))
                  .focus_ring_theme()
                  |> ignore
                  @sf.words_node(c, fn() { label_of(k) }, fn() {
                    if item.picked() {
                      story_chip_picked
                    } else {
                      story_chip_idle
                    }
                  })
                  |> ignore
                },
              )
              |> ignore
            })
            |> ignore
            @sf.words_node(card, fn() { "当前分组：" + label_of(tab.get()) }, fn() { @sf.caption }) |> ignore
          },
        ),
      ],
    },
    {
      key: "row-box",
      group: "列表",
      name: "组合卡片行 RowBox",
      file: "row_compound_node.mbt",
      api: [("row_compound_node.mbt", "row_box_node"), ("page_node.mbt", "row_tag_node")],
      play: None,
      about: "按槽位拼装的卡片行（RowScope：icon / title / note / value / tail / chevron），底层与 link_row_node 共用同一排版引擎；行标题旁可跟 row_tag_node 轻量标注归属或状态。",
      cases: [
        (
          "普通、带标签、警告与危险行",
          fn(card) {
            let said = kept("点击任意一行查看响应")
            @sf.group_node(card, fn(g) {
              @sf.row_box_node(g, fn() { "tokyo-mac-studio-0" }, press=fn() { said.set("打开工作站详情") }, fn(s) {
                s.icon("server")
                s.title(tone=RowStrong, after=fn(t) { @sf.row_tag_node(t, fn() { "本机" }) })
                s.note(fn() { "18 核，内存充裕，正在运行 4 个对话" })
                s.value(fn() { "在线" })
                s.chevron()
              })
              @sf.row_box_node(g, fn() { "受信任设备" }, press=fn() { said.set("查看待批准设备") }, fn(s) {
                s.icon("shield")
                s.title(after=fn(t) { @sf.row_tag_node(t, fn() { "安全模式" }) })
                s.note(fn() { "还有 2 台设备等待批准" }, tone=NoteWarn)
                s.value(fn() { "待处理" }, tone=NoteWarn, dot=fn() { true })
                s.chevron()
              })
              @sf.row_box_node(g, fn() { "移除此工作站" }, press=fn() { said.set("已触发移除确认") }, fn(s) {
                s.icon("trash")
                s.title(tone=RowDanger)
                s.note(fn() { "仅从当前工作区解绑，不会删除本地文件" })
              })
            })
            @sf.words_node(card, fn() { said.get() }, fn() { @sf.caption }) |> ignore
          },
        ),
      ],
    },
    {
      key: "empty-states",
      group: "反馈",
      name: "空状态 Empty",
      file: "parts.mbt",
      api: [
        ("parts.mbt", "empty_node"),
        ("page_node.mbt", "page_none_node"),
        ("page_wide_node.mbt", "section_none_node"),
      ],
      play: None,
      about: "列表或分区没有内容时的三种留白形态：empty_node 在容器中央居中展示图标与说明；page_none_node 放在空列表页顶部；section_none_node 放在空分组标题之下。",
      cases: [
        (
          "居中空状态 empty_node",
          fn(card) {
            card.box(fn(box) {
              box.min_height(Is(Some(140.0))).radius(Is(12.0)).ground(By(fn() { @sf.theme().p.card })) |> ignore
              @sf.empty_node(box, fn(e) {
                @sf.icon_node(e, "inbox", 24.0, By(fn() { @sf.theme().p.muted })) |> ignore
                @sf.words_node(e, fn() { "暂时没有新消息" }, fn() { story_card_title }) |> ignore
                @sf.words_node(e, fn() { "有新的审批或结果时，会第一时间出现在这里。" }, fn() { @sf.caption })
                |> ignore
              })
            })
            |> ignore
          },
        ),
        (
          "页面空提示 page_none_node",
          fn(card) { @sf.page_none_node(card, fn() { "还没有归档的对话，归档后会按时间排在这里。" }) },
        ),
        (
          "分区空提示 section_none_node",
          fn(card) { @sf.section_none_node(card, fn() { "当前工作站上没有正在运行的后台任务。" }) },
        ),
      ],
    },
    {
      key: "link-row",
      group: "列表",
      name: "列表卡片与导航行 LinkRow",
      file: "page_node.mbt",
      api: [
        ("page_node.mbt", "link_row_node"),
        ("page_node.mbt", "link_row_opens_node"),
        ("page_wide_node.mbt", "list_card_node"),
      ],
      play: None,
      about: "设置页与列表页共用的列表卡片（list_card_node）与跳转行：link_row_node 支持图标、副说明、当前值、右箭头或外链箭头；link_row_opens_node 把自身作为锚点弹出菜单或小面板。",
      cases: [
        (
          "列表卡片、外链与弹出菜单行",
          fn(card) {
            let station = kept("tokyo-mac-studio-0")
            let said = kept("点击任意一行试试")
            @sf.list_card_node(card, fn(g) {
              @sf.link_row_node(
                g,
                fn() { "外观与语言" },
                fn() { said.set("进入外观与语言") },
                lead=LeadIcon("settings"),
                note=fn() { "主题色、字号与界面语言" },
                value=fn() { "简体中文" },
                chevron=true,
              )
              @sf.link_row_node(
                g,
                fn() { "使用文档" },
                fn() { said.set("打开外部文档") },
                lead=LeadIcon("globe"),
                note=fn() { "在浏览器中查看配置说明" },
                out=true,
                chevron=true,
              )
              @sf.link_row_opens_node(
                g,
                fn() { "默认工作站" },
                fn(b) {
                  @sf.menu(
                    [
                      Some(@sf.menu_item_of("tokyo-mac-studio-0", fn() {
                        station.set("tokyo-mac-studio-0")
                        said.set("已切换为 tokyo-mac-studio-0")
                      }, chosen=station.get() == "tokyo-mac-studio-0")),
                      Some(@sf.menu_item_of("office-mac-mini", fn() {
                        station.set("office-mac-mini")
                        said.set("已切换为 office-mac-mini")
                      }, chosen=station.get() == "office-mac-mini")),
                    ],
                    from=@sf.Beside::Node(b),
                  )
                },
                lead=LeadIcon("server"),
                value=fn() { station.get() },
                chevron=true,
              )
            })
            @sf.words_node(card, fn() { said.get() }, fn() { @sf.caption }) |> ignore
          },
        ),
      ],
    },
    {
      key: "page-card-section",
      group: "布局",
      name: "分组、页面卡片与角行 Section",
      file: "page_wide_node.mbt",
      api: [
        ("page_wide_node.mbt", "section_node"),
        ("page_node.mbt", "page_card_node"),
        ("page_node.mbt", "corner_row_node"),
      ],
      play: None,
      about: "页面内容的三层骨架：section_node 给出分组标题、说明与底部节奏；page_card_node 提供带同心圆角上下文的卡片容器（footed=true 时底部内边距与页脚胶囊按钮同心）；corner_row_node 让单行卡片行尾按钮紧贴卡片圆角。",
      cases: [
        (
          "分组与带页脚的页面卡片",
          fn(card) {
            let count = kept(0)
            @sf.section_node(
              card,
              fn() { "工作区同步" },
              note=fn() { "全局记忆与技能会在同一工作区的工作站间自动保持一致。" },
              fn(sec) {
                @sf.page_card_node(sec, footed=true, fn(k) {
                  @sf.words_node(k, fn() { "已同步 14 项技能与全局记忆" }, fn() { @sf.paragraph }) |> ignore
                  @sf.words_node(
                    k,
                    fn() { if count.get() == 0 { "最近一次检查：刚刚" } else { "已手动核对 \{count.get()} 次" } },
                    fn() { @sf.caption },
                  )
                  |> ignore
                  @sf.card_foot_node(k, fn(f) {
                    @sf.button_node(f, fn() { "立即核对" }, fn() { count.set(count.get() + 1) }, tone=Primary, card_words=true)
                    |> ignore
                  })
                })
              },
            )
          },
        ),
        (
          "单行卡片角行 corner_row_node",
          fn(card) {
            let restored = kept(false)
            @sf.group_node(card, fn(g) {
              @sf.corner_row_node(
                g,
                fn() { if restored.get() { "已排队恢复 2 份对话备份" } else { "来自旧工作站的 2 份对话备份" } },
                fn(e) {
                  @sf.button_node(e, fn() { if restored.get() { "已提交" } else { "恢复到这台" } }, fn() {
                    restored.set(true)
                  }, tone=Primary, disabled=fn() { restored.get() })
                  |> ignore
                },
              )
            })
          },
        ),
      ],
    },
    {
      key: "panel-parts",
      group: "弹层",
      name: "面板内部分组与控件 PanelParts",
      file: "panel_parts_node.mbt",
      api: [
        ("panel_parts_node.mbt", "panel_group_node"),
        ("panel_parts_node.mbt", "panel_note_node"),
        ("small_panel_node.mbt", "panel_button_node"),
        ("panel_parts_node.mbt", "panel_switch_row_node"),
      ],
      play: None,
      about: "小面板与抽屉内部的专用组合件：panel_group_node 为行提供小标题分组；panel_switch_row_node 把开关对齐在首行行尾；panel_note_node 给出对齐行内边距的说明；panel_button_node 是 24 高的面板迷你胶囊按钮。",
      cases: [
        (
          "打开小面板（分组、开关行、说明与按钮）",
          fn(card) {
            let auto_sync = kept(true)
            let wifi_only = kept(false)
            let said = kept("还没有操作")
            side_by_side(card, fn(r) {
              @sf.button_opens_node(r, fn() { "面板设置" }, icon="sliders", fn(b) {
                @sf.panel_nodes(
                  "同步偏好",
                  fn(body, close) {
                    @sf.panel_group_node(body, fn() { "同步选项" }, fn(g) {
                      @sf.panel_switch_row_node(
                        g,
                        fn() { "自动同步记忆" },
                        fn() { auto_sync.get() },
                        fn(v) { auto_sync.set(v) },
                        note=fn() { "改动后几秒内同步到其他工作站" },
                      )
                      @sf.panel_switch_row_node(
                        g,
                        fn() { "仅 Wi-Fi 传输附件" },
                        fn() { wifi_only.get() },
                        fn(v) { wifi_only.set(v) },
                      )
                    })
                    @sf.panel_note_node(body, fn() { "关闭自动同步后，仅在手动刷新时拉取远端变更。" })
                    body.box(fn(actions) {
                      actions.row(Is(true)).wraps(Is(Some(8.0))).gap(Is(8.0)).padding(Is((6.0, 4.0, 6.0, 6.0))) |> ignore
                      @sf.panel_button_node(actions, fn() { "立即同步" }, fn() {
                        said.set("已触发立即同步")
                        close()
                      }, tone=Filled)
                      |> ignore
                      @sf.panel_button_node(actions, fn() { "恢复默认" }, fn() {
                        auto_sync.set(true)
                        wifi_only.set(false)
                        said.set("已恢复默认")
                      }, tone=Quiet)
                      |> ignore
                    })
                    |> ignore
                  },
                  from=@sf.Anchor::Node(b),
                )
              })
              |> ignore
              @sf.words_node(r, fn() { said.get() }, fn() { @sf.caption }) |> ignore
            })
          },
        ),
        (
          "面板迷你按钮四种语气",
          fn(card) {
            let hit = kept("")
            side_by_side(card, fn(r) {
              @sf.panel_button_node(r, fn() { "默认" }, fn() { hit.set("默认") }, tone=Plainly) |> ignore
              @sf.panel_button_node(r, fn() { "强调" }, fn() { hit.set("强调") }, tone=Accent) |> ignore
              @sf.panel_button_node(r, fn() { "实底" }, fn() { hit.set("实底") }, tone=Filled) |> ignore
              @sf.panel_button_node(r, fn() { "静默" }, fn() { hit.set("静默") }, tone=Quiet) |> ignore
            })
            @sf.words_node(card, fn() { if hit.get() == "" { "按下任意语气按钮" } else { "按了：" + hit.get() } }, fn() {
              @sf.caption
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "search-combo",
      group: "输入",
      name: "搜索组合框 SearchCombo",
      file: "page_node.mbt",
      api: [
        ("page_node.mbt", "search_combo_node"),
        ("page_node.mbt", "ripple_option_node"),
        ("offers_node.mbt", "combo_node"),
      ],
      play: None,
      about: "带搜索过滤的组合框：search_combo_node 将输入框与下方选项列表组成无头 Combobox，支持 ↑ ↓ 移动与 Enter 选中；combo_node 则直接管理输入框、选项数组与列表容器。",
      cases: [
        (
          "搜索组合框 search_combo_node",
          fn(card) {
            let field = @ui.Field::new()
            let query = kept("")
            let active : @signals.Signal[String?] = kept(Some("tokyo-mac-studio-0"))
            let picked = kept("尚未选择")
            let all = ["tokyo-mac-studio-0", "pvg-office-1", "pvg-office-2", "Office-Host-2"]
            let filtered = fn() {
              let q = query.get().trim(chars=" ").to_owned()
              if q == "" {
                all
              } else {
                all.filter(fn(s) { s.contains(q) })
              }
            }
            card.box(fn(b) {
              b.gap(Is(8.0)).max_width(Is(Some(360.0))) |> ignore
              let combo = @sf.search_combo_node(
                b,
                fn() { "选择工作站" },
                filtered,
                fn() { active.get() },
                fn(k) { active.set(k) },
                fn(k) { picked.set(k) },
                chosen=fn() { active.get() },
              )
              @sf.input_node(b, field, placeholder="筛选工作站名称", edited=fn(v) {
                query.set(v)
                active.set(filtered().get(0))
              })
              |> ignore
              b.box(fn(list) {
                list.gap(Is(2.0)).padding(Is((4.0, 4.0, 4.0, 4.0))).radius(Is(12.0)).ground(By(fn() { @sf.theme().p.card }))
                |> ignore
                combo.list_node(list)
                list.each(filtered, fn(k) { k }, fn(cell, k) {
                  let key = k.untracked()
                  cell.box(fn(r) {
                    r
                    .row(Is(true))
                    .min_height(By(fn() { Some(@sf.theme().items.least) }))
                    .padding(Is((10.0, 0.0, 10.0, 0.0)))
                    .lines_up(Is(Some(Middle)))
                    .radius(Is(8.0))
                    .ground(By(fn() { if active.get() == Some(key) { @sf.theme().p.hover } else { 0L } }))
                    |> ignore
                    @sf.ripple_option_node(r, combo, fn() { key }, fn() { key }, 8.0)
                    @sf.words_node(r, fn() { key }, fn() { @sf.paragraph }) |> ignore
                  })
                  |> ignore
                })
              })
              |> ignore
            })
            |> ignore
            @sf.words_node(card, fn() { "已选：" + picked.get() }, fn() { @sf.caption }) |> ignore
          },
        ),
        (
          "内联组合框 combo_node",
          fn(card) {
            let field = @ui.Field::new()
            let query = kept("")
            let at = @signals.signal(0)
            let chosen = kept("尚未选择")
            let commands = ["/plan", "/compact", "/schedule", "/goal"]
            let filtered = fn() {
              let q = query.get().trim(chars=" ").to_owned()
              if q == "" {
                commands
              } else {
                commands.filter(fn(c) { c.contains(q) })
              }
            }
            card.box(fn(b) {
              b.gap(Is(8.0)).max_width(Is(Some(360.0))) |> ignore
              @sf.combo_node(
                b,
                fn() { "快捷命令" },
                filtered,
                at,
                fn(i, _) {
                  match @signals.untracked(filtered).get(i) {
                    Some(cmd) => chosen.set(cmd)
                    None => ()
                  }
                },
                fn(c) {
                  @sf.input_node(c, field, placeholder="输入 / 筛选命令", edited=fn(v) {
                    query.set(v)
                    at.set(0)
                  })
                  |> ignore
                },
                fn(k) { k },
                fn(r, key, on) {
                  r
                  .row(Is(true))
                  .min_height(By(fn() { Some(@sf.theme().items.least) }))
                  .padding(Is((10.0, 0.0, 10.0, 0.0)))
                  .lines_up(Is(Some(Middle)))
                  .radius(Is(8.0))
                  .ground(By(fn() { if on() { @sf.theme().p.hover } else { 0L } }))
                  |> ignore
                  @sf.words_node(r, fn() { key }, fn() { @sf.paragraph }) |> ignore
                },
                list=fn(l) {
                  l.gap(Is(2.0)).padding(Is((4.0, 4.0, 4.0, 4.0))).radius(Is(12.0)).ground(By(fn() { @sf.theme().p.card }))
                  |> ignore
                },
              )
              |> ignore
            })
            |> ignore
            @sf.words_node(card, fn() { "执行：" + chosen.get() }, fn() { @sf.caption }) |> ignore
          },
        ),
      ],
    },
    {
      key: "segmented",
      group: "选择",
      name: "分段选择 Segmented",
      file: "seg_node.mbt",
      api: [("seg_node.mbt", "segmented_node"), ("seg_node.mbt", "seg_head_node")],
      play: None,
      about: "按页面宽窄自适应的分段控制器：segmented_node 在窄排法下铺满一行（支持手指拖拽透镜），宽排法下按选项内容定宽；seg_head_node 专用于顶栏右侧，空间不足时优雅收折为下拉菜单。",
      cases: [
        (
          "标准分段 segmented_node",
          fn(card) {
            let tab = kept(0)
            let labels = ["全部", "未读", "已归档"]
            card.box(fn(row) {
              row.row(Is(true)) |> ignore
              row.box(fn(slot) {
                @sf.segmented_node(slot, fn() { labels }, fn() { tab.get() }, fn(i) { tab.set(i) }, said="消息筛选")
              })
              |> ignore
            })
            |> ignore
            @sf.words_node(card, fn() { "当前筛选：" + labels[tab.get()] }, fn() { @sf.caption }) |> ignore
          },
        ),
        (
          "顶栏分段 seg_head_node",
          fn(card) {
            let mode = kept(0)
            let modes = ["列表", "看板"]
            card.box(fn(head) {
              head.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
              head.box(fn(t) {
                t.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                @sf.words_node(t, fn() { "对话视图" }, fn() { story_card_title }) |> ignore
              })
              |> ignore
              @sf.seg_head_node(head, fn() { modes }, fn() { mode.get() }, fn(i) { mode.set(i) }, said="视图切换")
              |> ignore
            })
            |> ignore
            @sf.words_node(card, fn() { "当前视图：" + modes[mode.get()] }, fn() { @sf.caption }) |> ignore
          },
        ),
      ],
    },
    {
      key: "steps",
      group: "进度",
      name: "步骤条 Steps",
      file: "parts_node.mbt",
      api: [("parts_node.mbt", "steps_node")],
      play: None,
      about: "有序操作指引步骤条：左侧固定 20 宽的编号列，右侧自动折行排布说明与状态；适合接入向导、设备配对或发布核对清单。",
      cases: [
        (
          "三步进度（可切换当前步骤）",
          fn(card) {
            let current = kept(1)
            let state_of = fn(i : Int) {
              let now = current.get()
              if i < now {
                "（已完成）"
              } else if i == now {
                "（进行中）"
              } else {
                "（待办）"
              }
            }
            @sf.steps_node(card, [
              fn(s) {
                @sf.words_node(s, fn() { "拉取最新主干并建立工作区 " + state_of(0) }, fn() {
                  if current.get() == 0 {
                    story_card_title
                  } else {
                    @sf.paragraph
                  }
                })
                |> ignore
              },
              fn(s) {
                @sf.words_node(s, fn() { "运行远端门禁与双视口审计 " + state_of(1) }, fn() {
                  if current.get() == 1 {
                    story_card_title
                  } else {
                    @sf.paragraph
                  }
                })
                |> ignore
              },
              fn(s) {
                @sf.words_node(s, fn() { "推送分支并等待 GitHub CI 全绿 " + state_of(2) }, fn() {
                  if current.get() == 2 {
                    story_card_title
                  } else {
                    @sf.paragraph
                  }
                })
                |> ignore
              },
            ])
            side_by_side(card, fn(r) {
              @sf.button_node(r, fn() { "上一步" }, fn() {
                if current.get() > 0 {
                  current.set(current.get() - 1)
                }
              }, tone=Ghost, disabled=fn() { current.get() == 0 })
              |> ignore
              @sf.button_node(r, fn() { "下一步" }, fn() {
                if current.get() < 2 {
                  current.set(current.get() + 1)
                }
              }, tone=Primary, disabled=fn() { current.get() == 2 })
              |> ignore
              @sf.words_node(r, fn() { "当前第 \{current.get() + 1} / 3 步" }, fn() { @sf.caption }) |> ignore
            })
          },
        ),
      ],
    },
    {
      key: "way-in-tiles",
      group: "引导",
      name: "引导入口、瓦片与视频胶囊 WayIn",
      file: "way_in_node.mbt",
      api: [
        ("way_in_node.mbt", "way_in_node"),
        ("way_in_node.mbt", "way_in_button_node"),
        ("way_in_node.mbt", "way_in_note_node"),
        ("tiles_node.mbt", "pick_tiles_node"),
        ("icons.mbt", "video_capsule_node"),
      ],
      play: None,
      about: "登录与引导流常用部件：way_in_node 组合插画、主按钮与状态回显；way_in_button_node 与 way_in_note_node 可独立复用；pick_tiles_node 宽排法呈三列瓦片、窄排法退化为分组列表；video_capsule_node 在媒体左下角按同心圆角贴合显示播放时长或下载进度。",
      cases: [
        (
          "引导入口页块 way_in_node",
          fn(card) {
            let busy = kept(false)
            card.box(fn(frame) {
              frame.radius(Is(16.0)).ground(By(fn() { @sf.theme().p.card })).clips(Is(true)) |> ignore
              @sf.way_in_node(
                frame,
                fn() { if @sf.theme().dark { "illus_sign_in_dark" } else { "illus_sign_in" } },
                fn() { "连接到你的工作站" },
                fn() { "登录后即可在任意设备上继续团队对话与后台任务。" },
                fn() { if busy.get() { "正在打开浏览器" } else { "登录或注册" } },
                fn() { "支持同时登录多个工作区账号" },
                fn() { busy.set(!busy.get()) },
                busy=fn() { busy.get() },
                said=fn() { if busy.get() { ("请在浏览器中完成登录", false) } else { ("", false) } },
              )
              |> ignore
            })
            |> ignore
          },
        ),
        (
          "引导说明与主次按钮 way_in_note_node / way_in_button_node",
          fn(card) {
            let loading = kept(false)
            card.box(fn(col) {
              col.gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
              @sf.way_in_note_node(col, fn() { "创建工作区后，随时可以邀请成员或接入新的工作站。" }) |> ignore
              @sf.way_in_button_node(col, fn() { if loading.get() { "正在创建" } else { "创建新工作区" } }, fn() {
                loading.set(!loading.get())
              }, solid=true, busy=fn() { loading.get() })
              |> ignore
              @sf.way_in_button_node(col, fn() { "使用已有邀请码" }, fn() { loading.set(false) }, solid=false)
              |> ignore
            })
            |> ignore
          },
        ),
        (
          "网格选择瓦片 pick_tiles_node",
          fn(card) {
            let picked = kept("尚未选择")
            let providers = [
              ("anthropic", "Anthropic"),
              ("openai", "OpenAI"),
              ("gemini", "Gemini"),
              ("deepseek", "DeepSeek"),
              ("kimi", "Kimi"),
              ("qwen", "通义千问"),
            ]
            @sf.pick_tiles_node(
              card,
              fn() { "选择模型提供方" },
              fn() { providers },
              fn(m, id) {
                let icon = match id {
                  "anthropic" => "brain"
                  "openai" => "terminal"
                  "gemini" => "sparks"
                  "deepseek" => "search"
                  "kimi" => "star"
                  _ => "globe"
                }
                @sf.icon_node(m, icon, 16.0, By(fn() { @sf.theme().p.text })) |> ignore
              },
              fn(id) { picked.set(id) },
            )
            @sf.words_node(card, fn() { "已选提供方：" + picked.get() }, fn() { @sf.caption }) |> ignore
          },
        ),
        (
          "视频时长胶囊 video_capsule_node",
          fn(card) {
            side_by_side(card, fn(r) {
              r.box(fn(thumb) {
                thumb
                .width(Is(Some(180.0)))
                .height(Is(Some(108.0)))
                .radius(Is(12.0))
                .ground(By(fn() { @sf.theme().p.card }))
                .clips(Is(true))
                |> ignore
                @sf.video_capsule_node(thumb, 125.0, corner=12.0)
              })
              |> ignore
              r.box(fn(thumb) {
                thumb
                .width(Is(Some(180.0)))
                .height(Is(Some(108.0)))
                .radius(Is(12.0))
                .ground(By(fn() { @sf.theme().p.card }))
                .clips(Is(true))
                |> ignore
                @sf.video_capsule_node(thumb, 42.0, corner=12.0, coming=fn() { Some(0.64) })
              })
              |> ignore
            })
          },
        ),
      ],
    },
  ]
}

///|
/// A picked chip tab's words: inverted on the foreground ink.
// kept across runs: a value (no field of it changes)
let story_chip_picked : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Bg, wrap=false)

///|
/// An unpicked chip tab's words: body foreground on the card ground.
// kept across runs: a value (no field of it changes)
let story_chip_idle : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false)
