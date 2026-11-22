// The library's parts that show data (quota_node.mbt, quota_lines_node.mbt, meter_line_node.mbt,
// meter_chips_brief_node.mbt, grid_table_node.mbt, link_cards_node.mbt, countdown_node.mbt, item_row_node.mbt,
// list_row_node.mbt, code_display_node.mbt), each beside its states, from data said here as the core says it, never from the time of day.

///|
/// Their stories, after the controls': `tips` the layer a chip's and a link's card are shown in.
fn stories_display(tips : @sf.TipLayer) -> Array[Story] {
  [
    {
      key: "quota",
      group: "数据",
      name: "用量配额 Quota",
      file: "quota_node.mbt",
      api: [
        ("quota_node.mbt", "quota_chips_node"),
        ("quota_node.mbt", "quota_worded_node"),
        ("quota_node.mbt", "fill_chip_node"),
        ("quota_node.mbt", "dials_node"),
        ("quota_lines_node.mbt", "quota_lines_node"),
      ],
      play: None,
      about: "一个账号各个时间窗还剩多少：每个窗口一个胶囊，按剩余量填色（够用、偏少、快用完三档），前面是窗口的标记（5H、W）；指针停上去说剩多少、何时刷新。窄处只写标记；多行版本放不下时，账号的窗口一行、各模型自己的一行。也可画成仪表盘。",
      cases: [
        (
          "胶囊（点下方按钮换用量）",
          fn(card) {
            let at = kept(0)
            card.box(fn(col) {
              col.gap(Is(12.0)) |> ignore
              @sf.quota_chips_node(col, fn() { Some(story_quota(at.get())) }, tips~)
              @sf.quota_worded_node(col, fn() { Some(story_quota(at.get())) }, tips~)
            })
            |> ignore
            side_by_side(card, fn(r) {
              @sf.button_node(r, fn() { ["用量正常", "快用完", "已用完"][at.get()] + " · 换一个" }, fn() { at.set((at.get() + 1) % 3) })
              |> ignore
            })
          },
        ),
        (
          "多行（账号的与各模型的）",
          fn(card) {
            @sf.quota_lines_node(card, fn() { Some(story_quota_models) })
          },
        ),
        (
          "仪表盘",
          fn(card) {
            @sf.dials_node(card, fn() {
              [
                { number: "62", unit: "%", fill: 62, level: "ok", label: "5 小时", note: "2 小时后刷新", label_short: "5h", note_short: "", turns: false },
                { number: "18", unit: "%", fill: 18, level: "amber", label: "每周", note: "3 天后刷新", label_short: "W", note_short: "", turns: false },
                { number: "4", unit: "%", fill: 4, level: "red", label: "Opus 每周", note: "3 天后刷新", label_short: "Opus", note_short: "", turns: false },
              ]
            })
          },
        ),
      ],
    },
    {
      key: "meters",
      group: "数据",
      name: "指标条 Meters",
      file: "meter_line_node.mbt",
      api: [("meter_line_node.mbt", "meter_line_node"), ("meter_chips_brief_node.mbt", "meter_chips_brief_node")],
      play: None,
      about: "一台机器的 CPU、内存、磁盘还剩多少：一行胶囊，按剩余量填色。简明版在一行放不下时，先省掉还很充足的，从最后一个起，快不够的一直留着；最窄时连它们也省掉，绝不截断成看不懂的半个。",
      cases: [
        (
          "一行（够用、偏少、快不够）",
          fn(card) { @sf.meter_line_node(card, fn() { story_meters }) },
        ),
        (
          "简明版（拖动宽度看省略）",
          fn(card) {
            let narrow = kept(false)
            card.box(fn(b) {
              b.width(By(fn() { Some(if narrow.get() { 160.0 } else { 340.0 }) })) |> ignore
              @sf.meter_chips_brief_node(b, fn() { story_meters })
            })
            |> ignore
            @sf.button_node(card, fn() { if narrow.get() { "放宽到 340" } else { "收窄到 160" } }, fn() { narrow.set(!narrow.get()) }, tone=Ghost)
            |> ignore
          },
        ),
      ],
    },
    {
      key: "grid-table",
      group: "数据",
      name: "数据表格 GridTable",
      file: "grid_table_node.mbt",
      api: [("grid_table_node.mbt", "grid_table_node"), ("grid_table_node.mbt", "GridTable::row"), ("grid_table_node.mbt", "GridRow::head")],
      play: None,
      about: "由页面自己排版的数据表（工作站的「进程」）：表头一行、每列一个列头，下面是数据行；读屏读作表格、行和列头。列宽按可用宽度算，名字一列占满余下的宽度，数字列靠右。",
      cases: [
        (
          "进程表",
          fn(card) {
            let rows = [("claude", "12.4%", "1.2 GB"), ("moon test", "86.0%", "3.4 GB"), ("node station", "2.1%", "410 MB"), ("codex", "0.3%", "220 MB")]
            @sf.grid_table_node(card, fn(table, tb) {
              table.gap(Is(0.0)).width(Is(Some(340.0))).max_width(Is(Some(340.0))) |> ignore
              tb.row(table, fn(head, hr) {
                head.row(Is(true)).padding(Is((6.0, 8.0, 6.0, 8.0))) |> ignore
                story_cell(head, 1.0, fn(c) { hr.head(c, fn(h) { @sf.words_node(h, fn() { "进程" }, fn() { @sf.caption }) |> ignore }) |> ignore })
                story_cell(head, 0.0, fn(c) { hr.head(c, fn(h) { @sf.words_node(h, fn() { "CPU" }, fn() { @sf.caption }) |> ignore }) |> ignore })
                story_cell(head, 0.0, fn(c) { hr.head(c, fn(h) { @sf.words_node(h, fn() { "内存" }, fn() { @sf.caption }) |> ignore }) |> ignore })
              })
              |> ignore
              for r in rows {
                let (name, cpu, mem) = r
                tb.row(table, fn(row, _) {
                  row.row(Is(true)).padding(Is((8.0, 8.0, 8.0, 8.0))) |> ignore
                  story_cell(row, 1.0, fn(c) { @sf.words_node(c, fn() { name }, fn() { story_cell_words }) |> ignore })
                  story_cell(row, 0.0, fn(c) { @sf.words_node(c, fn() { cpu }, fn() { story_cell_words }) |> ignore })
                  story_cell(row, 0.0, fn(c) { @sf.words_node(c, fn() { mem }, fn() { story_cell_words }) |> ignore })
                })
                |> ignore
              }
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "link-cards",
      group: "卡片",
      name: "链接悬浮卡 LinkCards",
      file: "link_cards_node.mbt",
      api: [("link_cards_node.mbt", "link_cards_node")],
      play: None,
      about: "一段文字里的链接各自带的悬浮卡：指针停在链接那一段上一会儿，卡在它下面、对齐它的开头打开；离开链接和卡一会儿后关上。卡里读的东西从指针碰到链接起才开始读。手指长按和右键是链接自己的菜单，不开卡。",
      cases: [
        (
          "停在链接上",
          fn(card) {
            // (its links in the theme's accent ink, its words in the text's, as the theme is now)
            let runs = fn() -> Array[@ui.Run] {
              let ink = @sf.theme().p.accent_text
              [
                @ui.plain("改动在 "),
                @ui.span("#7279", color=ink, link="https://github.com/AFK-surf/monoid/pull/7279"),
                @ui.plain(" 里，说明见 "),
                @ui.span("设计文档", color=ink, link="https://example.com/design"),
                @ui.plain("。"),
              ]
            }
            card.box(fn(col) {
              let shown : @signals.Signal[Array[(String, String, Int)]] = @signals.signal([])
              let links : Ref[@ui.RunsLinks?] = Ref(None)
              let words = col.box(fn(w) {
                w.words_runs(By(runs)).ink(By(fn() { @sf.theme().p.text })) |> ignore
                links.val = Some(@ui.runs_links(w, runs, fn(_) {  }, shown=fn(now) { shown.set(now) }))
              })
              match links.val {
                Some(l) =>
                  @sf.link_cards_node(col, tips, words, l, fn() { shown.get() }, fn(link) {
                    Some({
                      tile: false,
                      body: fn(b) {
                        b.box(fn(x) {
                          x.gap(Is(4.0)) |> ignore
                          @sf.words_node(x, fn() { (link.words)() }, fn() { story_card_title }) |> ignore
                          @sf.words_node(x, fn() { link.href }, fn() { @sf.caption }) |> ignore
                        })
                        |> ignore
                      },
                    })
                  })
                  |> ignore
                None => ()
              }
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "countdown",
      group: "数据",
      name: "倒计时 Countdown",
      file: "countdown_node.mbt",
      api: [("countdown_node.mbt", "countdown_now_node")],
      play: None,
      about: "倒计时（登录还剩几分钟）：显示的时间只在剩余整段数变化的那一刻重读（用同一个时钟的 at_moment），不是每帧读时钟。这里从按下「开始」那一刻起数 90 秒，每秒一跳，用的是页面自己的时钟，不读现实时间。",
      cases: [
        (
          "按秒倒数（按开始）",
          fn(card) {
            let ends = kept(0.0)
            card.box(fn(b) {
              let now = @sf.countdown_now_node(b, fn() { b.logic_at() }, fn() { ends.get() }, period=1000.0)
              @sf.words_node(
                b,
                fn() {
                  let end = ends.get()
                  if end <= 0.0 {
                    "还没开始"
                  } else {
                    let left = ((end - now()) / 1000.0).ceil().to_int()
                    if left <= 0 {
                      "时间到了"
                    } else {
                      "剩 \{left / 60}:\{if left % 60 < 10 { "0" } else { "" }}\{left % 60}"
                    }
                  }
                },
                fn() { story_count_words },
              )
              |> ignore
              @sf.button_node(b, fn() { if ends.get() <= 0.0 { "开始" } else { "重来" } }, fn() { ends.set(b.logic_at() + 90000.0) }, tone=Ghost)
              |> ignore
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "item-row",
      group: "列表",
      name: "详情行 ItemRow",
      file: "item_row_node.mbt",
      api: [("item_row_node.mbt", "item_row_node"), ("item_row_node.mbt", "row_lines_node"), ("item_row_node.mbt", "group_rows_node")],
      play: None,
      about: "页面卡片里一组详情行（工作站的更新、安装的组件）：首行是名字和行尾的东西，下面是说明行；行与行之间的分割线由组统一画，隐藏一行时不留两条相邻的线。行尾按钮对齐首行。",
      cases: [
        (
          "一组详情行（第二行可显隐）",
          fn(card) {
            let shown = kept(true)
            @sf.group_rows_node(card, fn(g) {
              story_item(g, "still.fail 工作站", "0.1.10278", "今天 09:12 更新", "更新", fn() {  })
              g.show(fn() { shown.get() }, fn(s) { story_item(s, "Claude Code", "2.4.1", "有新版本 2.4.3", "更新", fn() {  }) })
              story_item(g, "Codex", "0.98.0", "已是最新", "", fn() {  })
            })
            @sf.button_node(card, fn() { if shown.get() { "藏起第二行" } else { "放回第二行" } }, fn() { shown.set(!shown.get()) }, tone=Ghost)
            |> ignore
          },
        ),
      ],
    },
    {
      key: "list-row",
      group: "列表",
      name: "列表行 ListRow",
      file: "list_row_node.mbt",
      api: [("list_row_node.mbt", "list_row_node"), ("list_row_node.mbt", "list_row_line_node"), ("list_row_node.mbt", "list_heading_node")],
      play: None,
      about: "对话、工作站、文件夹、账号列表共用的一行：标记在首行旁边，首行是标题和行尾的东西，下面是说明行；对话行总是固定高。放在侧栏还是占满整屏，决定行缩进多少、底色是不是圆角。",
      cases: [
        (
          "侧栏里（有标记、有分组标题）",
          fn(card) {
            card.box(fn(list) {
              list.width(Is(Some(280.0))).max_width(Is(Some(280.0))) |> ignore
              @sf.list_heading_node(list, fn() { "今天" }, Side)
              story_list_row(list, Side, "整理发布清单", "正在核对第三项", "3 分钟前", true)
              story_list_row(list, Side, "首页按天分组", "做好了，三段按最后活跃排序", "1 小时前", false)
            })
            |> ignore
          },
        ),
        (
          "占满整屏",
          fn(card) {
            card.box(fn(list) {
              story_list_row(list, Whole, "tokyo-mac-studio-0", "在线 · 18 核 · 6 个任务", "", true)
              story_list_row(list, Whole, "office-mac-mini", "离线 · 2 小时前还在", "", false)
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "code-display",
      group: "数据",
      name: "验证码展示 CodeDisplay",
      file: "code_display_node.mbt",
      api: [("code_display_node.mbt", "code_display_node"), ("code_display_node.mbt", "code_segments")],
      play: None,
      about: "给人照着读、到另一台设备上输入的码（受信任设备的安全码、登录验证码）：等宽大字，按输入框的分组（默认 3+3，组间 24）分段，居中；一行放不下时每组各占一行，仍居中。长度对不上分组的码原样整段显示。",
      cases: [
        ("6 位安全码（默认 3+3 分段）", fn(card) { @sf.code_display_node(card, fn() { "482915" }) |> ignore }),
        (
          "窄容器自动折行（160px）",
          fn(card) {
            card.box(fn(b) {
              b.width(Is(Some(160.0))) |> ignore
              @sf.code_display_node(b, fn() { "482915" }) |> ignore
            })
            |> ignore
          },
        ),
        ("自定义分组（4+4）", fn(card) { @sf.code_display_node(card, fn() { "48291573" }, groups=[4, 4]) |> ignore }),
      ],
    },
  ]
}

///|
/// An allowance as the core says one: its 5 hours' and its week's windows, `at` how much is left in them (0 plenty, 1
/// little, 2 none).
fn story_quota(at : Int) -> Json {
  let (five, week, level5, levelw) = match at {
    0 => (62, 88, "ok", "ok")
    1 => (12, 34, "amber", "ok")
    _ => (0, 21, "red", "ok")
  }
  {
    "state": "ok",
    "windows": [
      { "label": "5 小时", "mark": "5H", "left": five.to_double(), "level": level5, "refills": "42 分钟后刷新", "refillShort": "42m" },
      { "label": "每周", "mark": "W", "left": week.to_double(), "level": levelw, "refills": "3 天后刷新", "refillShort": "3d" },
    ],
  }
}

///|
/// A Claude subscription's windows with its models' own weeks (each its `scope`), as the core says them.
// kept across runs: a value (no field of it changes)
let story_quota_models : Json = {
  "state": "ok",
  "windows": [
    { "label": "5 小时", "mark": "5H", "left": 62.0, "level": "ok", "refills": "42 分钟后刷新" },
    { "label": "每周", "mark": "W", "left": 40.0, "level": "ok", "refills": "3 天后刷新" },
    { "label": "Opus 每周", "mark": "Opus", "left": 8.0, "level": "red", "refills": "3 天后刷新", "scope": "Opus" },
    { "label": "Sonnet 每周", "mark": "Sonnet", "left": 71.0, "level": "ok", "refills": "3 天后刷新", "scope": "Sonnet" },
  ],
}

///|
/// A machine's meter as the core says one: its short name, how much is left in %, its level, its figure and unit.
fn story_meter(short : String, left : Int, level : String, big : String, unit : String) -> Json {
  {
    "short": Json::string(short),
    "left": Json::number(left.to_double()),
    "level": Json::string(level),
    "remaining": Json::string(if unit == "%" { "空闲 " + big + "%" } else { "剩 " + big + " G" }),
    "big": Json::string(big),
    "unit": Json::string(unit),
    "label": Json::string(short),
    "value": Json::string(big),
  }
}

///|
// kept across runs: a value (no field of it changes)
let story_meters : Array[Json] = [
  story_meter("CPU", 91, "ok", "91", "%"),
  story_meter("内存", 9, "red", "1.4", "GB"),
  story_meter("磁盘", 22, "amber", "28", "GB"),
]

///|
/// A cell of the story's table in `row`: `grow` 1 the name's (taking what is left), else 72 wide, its words at its end.
fn story_cell(row : @view.View, grow : Double, make : (@view.View) -> Unit) -> Unit {
  row.box(fn(c) {
    if grow > 0.0 {
      c.grow(Is(grow)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    } else {
      c.width(Is(Some(72.0))).lies_along(Is(End)) |> ignore
    }
    make(c)
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let story_cell_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let story_count_words : @ui.TextStyle = @ui.text_style(size=Body, weight=Semibold, color=Fg, wrap=false)

///|
/// A row of a card's group of rows in `g`: `name` and `version` on its first line, `note` under it, a button `action`
/// ("" none) at its first line's end.
fn story_item(g : @view.View, name : String, version : String, note : String, action : String, press : () -> Unit) -> Unit {
  @sf.item_row_node(g, fn(r) {
    @sf.row_lines_node(
      r,
      fn(h) {
        h.box(fn(n) {
          n.row(Is(true)).gap(Is(6.0)).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(n, fn() { name }, fn() { story_card_title }) |> ignore
          @sf.words_node(n, fn() { version }, fn() { @sf.caption }) |> ignore
        })
        |> ignore
        if action != "" {
          @sf.button_node(h, fn() { action }, press, tone=Ghost) |> ignore
        }
      },
      fn(u) { @sf.words_node(u, fn() { note }, fn() { @sf.caption }) |> ignore },
    )
  })
}

///|
/// A row of a list standing `at` in `list`: `title`, `note` under it, `when` at its first line's end ("" none), a dot
/// before its first line: the accent's where `lit` (unread, online), else the muted ink's.
fn story_list_row(list : @view.View, at : @sf.ListAt, title : String, note : String, when : String, lit : Bool) -> Unit {
  list.box(fn(row) {
    @sf.list_row_node(
      row,
      at,
      mark=fn(k) {
        k.box(fn(s) {
          s.width(Is(Some(8.0))).height(Is(Some(8.0))).radius(Is(4.0)).ground(By(fn() { if lit { @sf.theme().p.accent } else { @sf.theme().p.subtle } }))
          |> ignore
        })
        |> ignore
      },
      fn(h) {
        h.box(fn(n) {
          n.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(n, fn() { title }, fn() { @sf.theme().chat_list.title }) |> ignore
        })
        |> ignore
        if when != "" {
          @sf.words_node(h, fn() { when }, fn() { @sf.caption }) |> ignore
        }
      },
      fn(u) { @sf.list_row_line_node(u, fn(l) { @sf.words_node(l, fn() { note }, fn() { @sf.theme().chat_list.last }) |> ignore }) },
    )
  })
  |> ignore
}
