// The library's tabs, addresses, filter pills, counts' chips and one-of rows (tab_bar_node.mbt, address_bar_node.mbt,
// filter_pill_node.mbt), each beside its states, what can be pressed answering as it does in the app.

///|
/// Their stories, after the others: `tips` the layer an icon button's name is shown in.
fn stories_u4(tips : @sf.TipLayer) -> Array[Story] {
  [
    {
      key: "tab-bar",
      group: "导航",
      name: "标签栏 TabBar",
      file: "tab_bar_node.mbt",
      api: [("tab_bar_node.mbt", "tab_bar_node"), ("tab_bar_node.mbt", "tab_words_node")],
      play: None,
      about: "可关闭的标签栏：一个标签列表，Tab 只停在当前标签，← → Home End 切换；关闭钮在标签末端，与标签同心；关掉键盘所在的标签后焦点交给新的当前标签。",
      cases: [
        (
          "胶囊 Capsule（关闭 · ＋ 新标签）",
          fn(card) {
            let keys = kept(["概览", "文件", "终端", "一个很长很长的网页标题会被截短"])
            let front = kept("概览")
            let made = kept(1)
            @sf.tab_bar_node(
              card,
              fn() { "标签页" },
              fn() { keys.get() },
              fn() { front.get() },
              fn(k) { front.set(k) },
              fn(k) { k },
              fn(b, k, shown) { @sf.tab_words_node(b, fn() { k }, shown) |> ignore },
              close=fn(k) {
                let rest = keys.get().filter(fn(x) { x != k })
                if front.get() == k {
                  front.set(rest.get(0).unwrap_or(""))
                }
                keys.set(rest)
              },
              close_label=fn(k) { "关闭「\{k}」" },
              trail=fn(e) {
                @sf.icon_button_node(e, "plus", fn() { "新标签页" }, fn() {
                  let k = "新标签 \{made.get()}"
                  made.set(made.get() + 1)
                  keys.set(keys.get() + [k])
                  front.set(k)
                }, size=@sf.side_tab_side, icon_size=14.0, tips~)
                |> ignore
              },
              tips~,
              tip=fn(_) { true },
            )
            |> ignore
          },
        ),
        (
          "槽 Groove（关闭钮悬停或当前时显示）",
          fn(card) {
            let keys = kept(["~/monoid", "~/notes", "/var/log"])
            let front = kept("~/monoid")
            @sf.tab_bar_node(
              card,
              fn() { "文件标签" },
              fn() { keys.get() },
              fn() { front.get() },
              fn(k) { front.set(k) },
              fn(k) { k },
              fn(b, k, shown) { @sf.tab_words_node(b, fn() { k }, shown) |> ignore },
              look=Groove,
              close=fn(k) {
                let rest = keys.get().filter(fn(x) { x != k })
                if front.get() == k {
                  front.set(rest.get(0).unwrap_or(""))
                }
                keys.set(rest)
              },
              close_shows=Lit,
            )
            |> ignore
          },
        ),
        (
          "胶片 Chip（不可关闭，换行）",
          fn(card) {
            let front = kept("SKILL.md")
            @sf.tab_bar_node(
              card,
              fn() { "文档页" },
              fn() { ["SKILL.md", "notes.md", "build.md", "release.md", "faq.md"] },
              fn() { front.get() },
              fn(k) { front.set(k) },
              fn(k) { k },
              fn(b, k, shown) { @sf.tab_words_node(b, fn() { k }, shown) |> ignore },
              look=Chip,
            )
            |> ignore
          },
        ),
      ],
    },
    {
      key: "address-bar",
      group: "导航",
      name: "地址栏 AddressBar",
      file: "address_bar_node.mbt",
      api: [("address_bar_node.mbt", "address_bar_node"), ("address_bar_node.mbt", "address_field_node")],
      play: None,
      about: "网页的地址栏：← → ⟳ 与地址胶囊。没人输入时跟随页面地址；点进去全选，Enter 前往，Esc 放弃输入并还原地址；底边显示加载进度。",
      cases: [
        (
          "地址栏（加载中可停止）",
          fn(card) {
            let url = kept("https://still.fail/docs")
            let busy = kept(false)
            let field = @ui.Field::new()
            @sf.address_bar_node(
              card,
              field,
              fn() { url.get() },
              fn(to) {
                url.set(to)
                busy.set(true)
              },
              fn() { "地址" },
              fn() {  },
              fn() {  },
              fn() { busy.set(true) },
              can_forward=fn() { false },
              busy=fn() { busy.get() },
              stop=fn() { busy.set(false) },
              placeholder=fn() { "输入网址" },
              progress=fn() { if busy.get() { Some((0.4, Accent)) } else { None } },
              tips~,
            )
            |> ignore
          },
        ),
        (
          "只有地址胶囊（带前置名称）",
          fn(card) {
            let path = kept("/index.html")
            let field = @ui.Field::new()
            @sf.address_field_node(
              card,
              field,
              fn() { path.get() },
              fn(to) { path.set(to) },
              fn() { "路径" },
              lead=fn(b) {
                @sf.icon_node(b, "web", @sf.theme().bars.icon, By(fn() { @sf.theme().p.muted })) |> ignore
                @sf.words_node(b, fn() { "预览 :3000" }, fn() { @sf.paragraph }) |> ignore
              },
            )
            |> ignore
          },
        ),
      ],
    },
    {
      key: "filter-pill",
      group: "选择",
      name: "筛选胶囊 FilterPill · 计数胶囊 CountChip",
      file: "filter_pill_node.mbt",
      api: [("filter_pill_node.mbt", "filter_pill_node"), ("filter_pill_node.mbt", "count_chip_node")],
      play: None,
      about: "筛选胶囊说出当前选了什么，按下重新选，选中时末端有同心的 ✕ 清除；计数胶囊带状态点和等宽数字，可作一组单选。",
      cases: [
        (
          "筛选胶囊（按 ✕ 清除）",
          fn(card) {
            let station = kept("Office-Host-2")
            side_by_side(card, fn(r) {
              @sf.filter_pill_node(
                r,
                fn() { if station.get() == "" { "选择 Station" } else { station.get() } },
                fn(_) { station.set("Office-Host-2") },
                picked=fn() { station.get() != "" },
                lead=fn(l) { @sf.icon_node(l, "sliders", 15.0, By(fn() { @sf.theme().p.muted })) |> ignore },
                clear=fn() { station.set("") },
                clear_label=fn() { "清除 Station" },
              )
              |> ignore
            })
          },
        ),
        (
          "计数胶囊 Fill（单选）· Small · Row",
          fn(card) {
            let picked = kept("Claude")
            card.box(fn(r) {
              r.row(Is(true)).gap(Is(6.0)) |> ignore
              for x in [("Claude", "4/7", false), ("Codex", "1/5", true)] {
                let (name, n, low) = x
                @sf.count_chip_node(
                  r,
                  fn() { name },
                  fn(_) { picked.set(name) },
                  count=fn() { n },
                  chosen=fn() { picked.get() == name },
                  dot=fn() { if low { "error" } else { "online" } },
                )
                .grow(Is(1.0))
                |> ignore
              }
            })
            |> ignore
            side_by_side(card, fn(r) {
              @sf.count_chip_node(r, fn() { "运行中 3" }, fn(_) {  }, dot=fn() { "online" }, look=Small) |> ignore
            })
            @sf.count_chip_node(card, fn() { "1 个 station 连不上" }, fn(_) {  }, alarm=fn() { true }, look=Row) |> ignore
          },
        ),
      ],
    },
    {
      key: "radio-rows",
      group: "选择",
      name: "单选行 RadioRows",
      file: "filter_pill_node.mbt",
      api: [("filter_pill_node.mbt", "radio_rows_node")],
      play: None,
      about: "一列单选行：一个单选组，Tab 只停一次，↑ ↓ Home End 在其中选择。",
      cases: [
        (
          "思考程度",
          fn(card) {
            let now = kept("medium")
            @sf.radio_rows_node(
              card,
              fn() { "思考程度" },
              fn() { [("low", "低"), ("medium", "中"), ("high", "高")] },
              fn() { now.get() },
              fn(v) { now.set(v) },
              fn(b, words, row) {
                b.row(Is(true)).padding(Is((12.0, 8.0, 12.0, 8.0))).lines_up(Is(Some(Middle))) |> ignore
                @sf.words_node(b, words, fn() { @sf.paragraph }).grow(Is(1.0)) |> ignore
                b.show(fn() { row.picked() }, fn(x) {
                  @sf.icon_node(x, "check", 14.0, By(fn() { @sf.theme().p.accent })) |> ignore
                })
              },
            )
            |> ignore
          },
        ),
      ],
    },
  ]
}
