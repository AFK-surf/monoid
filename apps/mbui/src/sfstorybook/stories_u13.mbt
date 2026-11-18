// The library's quiet cards (agent_stats_node.mbt: a chat's info, an agent's card, its jobs in a sheet), each beside
// its states, what can be pressed answering as it does in the app.

///|
/// Their stories, after the others: `tips` the layer an icon button's name is shown in.
fn stories_u13(tips : @sf.TipLayer) -> Array[Story] {
  [
    {
      key: "quiet-card",
      group: "列表",
      name: "安静卡片 QuietCard",
      file: "agent_stats_node.mbt",
      api: [
        ("agent_stats_node.mbt", "quiet_card_node"),
        ("agent_stats_node.mbt", "quiet_row_node"),
        ("agent_stats_node.mbt", "row_label_node"),
        ("agent_stats_node.mbt", "labels_across"),
        ("agent_stats_node.mbt", "row_chevron_node"),
      ],
      play: None,
      about: "对话信息、智能体卡片和任务列表里的安静卡片：墨色 5% 的底，行按阶梯缩进，按下时按行的圆角起波纹。标签一列按本语言里最宽的标签对齐；标签、点和箭头都对齐值的首行，值下面多一行（账号的额度）时不跟着居中。",
      cases: [
        (
          "标签列与箭头（第二行多一行）",
          fn(card) {
            let pressed = kept("")
            let labels = ["运行于", "账号", "执行历史"]
            let across = fn() { @sf.labels_across(card, labels) }
            @sf.quiet_card_node(card, fn(k) {
              for i, label in labels {
                let value = ["MacBook Pro", "zuozijian@cue.surf（自动选择）", "12 轮，最近 3 分钟前"][i]
                let look = if i == 1 { @sf.quiet_row_top } else { @sf.quiet_row_middle }
                @sf.quiet_row_node(k, fn() { label + " " + value }, look~, press=fn() { pressed.set(label) }, fn(row) {
                  @sf.row_label_node(row, label, across)
                  row.box(fn(w) {
                    w.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                    @sf.words_node(w, fn() { value }, fn() { story_quiet_value }) |> ignore
                    if i == 1 {
                      @sf.words_node(w, fn() { "本周还剩 62%" }, fn() { story_quiet_under }) |> ignore
                    }
                  })
                  |> ignore
                  row.box(fn(c) {
                    @sf.quiet_first_line(c)
                    @sf.row_chevron_node(c)
                  })
                  |> ignore
                })
                |> ignore
              }
            })
            @sf.words_node(card, fn() { if pressed.get() == "" { "" } else { "按了「\{pressed.get()}」" } }, fn() {
              story_quiet_under
            })
            |> ignore
          },
        ),
        (
          "领头是状态点（任务）",
          fn(card) {
            @sf.quiet_card_node(card, fn(k) {
              for job in [("dev-server", "up", "运行中 · 端口 5173"), ("e2e", "restart", "正在重启"), ("lint", "fail", "退出码 1"), ("build", "off", "已结束")] {
                let (name, tone, line) = job
                @sf.quiet_row_node(k, fn() { name }, look=@sf.quiet_row_style.then(@sf.quiet_row_dot(8.0, 7.0)).then(@ui.css("align=AStart")), press=fn() {  }, fn(row) {
                  row.box(fn(d) {
                    @sf.quiet_first_line(d)
                    @sf.state_dot_node(d, fn() { tone }, size=8.0, breathes=true)
                  })
                  |> ignore
                  row.box(fn(w) {
                    w.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                    @sf.words_node(w, fn() { name }, fn() { story_quiet_value }) |> ignore
                    @sf.words_node(w, fn() { line }, fn() { story_quiet_under }) |> ignore
                  })
                  |> ignore
                  row.box(fn(c) {
                    @sf.quiet_first_line(c)
                    @sf.row_chevron_node(c)
                  })
                  |> ignore
                })
                |> ignore
              }
            })
          },
        ),
      ],
    },
    {
      key: "stats-card",
      group: "卡片",
      name: "指标卡片 StatsCard",
      file: "agent_stats_node.mbt",
      api: [("agent_stats_node.mbt", "stats_card_node"), ("agent_stats_node.mbt", "reveal_part_node")],
      play: None,
      about: "智能体卡片顶部的卡片：它最近做的事、要注意的事和最能说明问题的数字，各是一段，卡片读到之后才出现的段从零高展开到它的高度，下面的内容跟着下移，不跳；一段都没有时整张卡片和它下面的间距都不在。",
      cases: [
        (
          "分段展开（按按钮显隐）",
          fn(card) {
            let lines = kept(true)
            let notes = kept(false)
            side_by_side(card, fn(r) {
              @sf.button_node(r, fn() { if lines.get() { "收起最近" } else { "显示最近" } }, fn() { lines.set(!lines.get()) }) |> ignore
              @sf.button_node(r, fn() { if notes.get() { "收起提醒" } else { "显示提醒" } }, fn() { notes.set(!notes.get()) }) |> ignore
            })
            @sf.stats_card_node(card, fn() { lines.get() || notes.get() }, [
              (
                fn() { lines.get() },
                fn(l) {
                  l.box(fn(p) {
                    p.padding(Is((8.0, 16.0, 8.0, 16.0))).gap(Is(4.0)) |> ignore
                    @sf.words_node(p, fn() { "读了 sheets.mbt" }, fn() { story_quiet_under }) |> ignore
                    @sf.words_node(p, fn() { "正在跑 detlint" }, fn() { story_quiet_value }) |> ignore
                  })
                  |> ignore
                },
              ),
              (
                fn() { notes.get() },
                fn(n) {
                  n.box(fn(p) {
                    p.padding(Is((8.0, 16.0, 8.0, 16.0))) |> ignore
                    @sf.words_node(p, fn() { "账号本周额度只剩 5%" }, fn() { story_quiet_value }) |> ignore
                  })
                  |> ignore
                },
              ),
            ])
          },
        ),
      ],
    },
  ] + stories_u18(tips)
}

///|
/// A quiet row's value in the stories: the Ui size, the ink, on a line.
// kept across runs: a value (no field of it changes)
let story_quiet_value : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
/// What is under it: the Meta size, muted.
// kept across runs: a value (no field of it changes)
let story_quiet_under : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)
