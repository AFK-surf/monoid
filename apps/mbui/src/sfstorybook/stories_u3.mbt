// The library's parts for looking through and finding (a list's search field, finding in a page), a name changed in
// its place, and people overlapping: each beside its states, what can be pressed answering as it does in the app.

///|
/// The faces a stack story shows.
fn stack_sample(n : Int) -> Array[@sf.StackFace] {
  let names = ["左子健", "Ada Lovelace", "Grace Hopper", "林青", "Linus", "王小明", "Ken Thompson", "陈默"]
  Array::makei(n, fn(i) {
    let name = names[i % names.length()]
    let face : @sf.StackFace = { id: "u\{i}", name, pictured: false, picture: fn() { "" } }
    face
  })
}

///|
/// The stories of the search field, a name changed in place, finding in a page and a stack of faces.
fn stories_u3(tips : @sf.TipLayer) -> Array[Story] {
  [
    {
      key: "search-input",
      group: "输入",
      name: "列表搜索 SearchInput",
      file: "search_input_node.mbt",
      api: [("search_input_node.mbt", "search_input_node")],
      play: None,
      about: "列表顶上的搜索框：圆角灰底、搜索图标；有内容时末端出现同心的清除按钮，点它清空并把焦点还给输入框。",
      cases: [
        (
          "空 Empty",
          fn(card) {
            let f = @ui.Field::new()
            @sf.search_input_node(card, f, fn() { "搜索设置" }) |> ignore
          },
        ),
        (
          "有内容 Typed",
          fn(card) {
            let f = @ui.Field::new(text="构建")
            @sf.search_input_node(card, f, fn() { "搜索归档" }) |> ignore
          },
        ),
        (
          "侧栏 Side",
          fn(card) {
            let f = @ui.Field::new(text="周报")
            @sf.search_input_node(card, f, fn() { "搜索归档" }, at=Side) |> ignore
          },
        ),
      ],
    },
    {
      key: "inline-rename",
      group: "输入",
      name: "原地重命名 InlineRename",
      file: "inline_rename_node.mbt",
      api: [("inline_rename_node.mbt", "inline_rename_node")],
      play: None,
      about: "在原处改名：回车或点到别处保存（去掉首尾空白，没改或为空则不改），Esc 放弃。对话全选标题，文件只选主名不含扩展名。",
      cases: [
        (
          "对话 Whole",
          fn(card) {
            let name = kept("夜里的构建又失败了")
            let f = @ui.Field::new(text=name.untracked())
            @sf.inline_rename_node(
              card,
              f,
              name.untracked(),
              "重命名",
              fn(w) {
                name.set(w)
                @sfbase.toast_later("已改名为「\{w}」")
              },
              fn() { @sfbase.toast_later("没有改名") },
              picks=NameWhole,
              frame=fn(b) {
                b.row(Is(true)).height(Is(Some(28.0))).padding(Is((10.0, 0.0, 10.0, 0.0))).radius(Is(14.0)).edge(By(fn() { (1.0, @sf.theme().p.line_strong) }))
                |> ignore
              },
            )
            |> ignore
          },
        ),
        (
          "文件 Stem",
          fn(card) {
            let f = @ui.Field::new(text="季度数据.csv")
            @sf.inline_rename_node(
              card,
              f,
              "季度数据.csv",
              "重命名",
              fn(w) { @sfbase.toast_later("已改名为「\{w}」") },
              fn() { @sfbase.toast_later("没有改名") },
              picks=NameStem,
              frame=fn(b) {
                b.row(Is(true)).height(Is(Some(28.0))).padding(Is((6.0, 0.0, 6.0, 0.0))).radius(Is(8.0)).edge(By(fn() { (1.0, @sf.theme().p.accent) }))
                |> ignore
              },
            )
            |> ignore
          },
        ),
      ],
    },
    {
      key: "page-find",
      group: "输入",
      name: "页内查找 PageFind",
      file: "page_find_node.mbt",
      api: [("page_find_node.mbt", "page_find_node")],
      play: None,
      about: "页内查找：输入框、第几个/共几个或无结果、上一个和下一个、关闭。回车下一个，⇧回车上一个，Esc 关闭；按钮有提示，手指长按也能看到。",
      cases: [
        (
          "有结果 Found",
          fn(card) {
            let at = kept(3)
            let f = @ui.Field::new(text="构建")
            @sf.page_find_node(
              card,
              fn() { "\{at.get()}/12" },
              fn(d) { at.set(((at.untracked() - 1 + d) % 12 + 12) % 12 + 1) },
              fn(_) { true },
              fn() { @sfbase.toast_later("已关闭查找") },
              field=f,
              placeholder_by=fn() { "在对话中查找" },
              tips~,
              frame=fn(b) {
                b.height(Is(Some(32.0))).padding(Is((12.0, 0.0, 3.0, 0.0))).radius(Is(16.0)).edge(By(fn() { (1.0, @sf.theme().p.line) }))
                |> ignore
              },
            )
            |> ignore
          },
        ),
        (
          "无结果 None",
          fn(card) {
            let f = @ui.Field::new(text="没有的词")
            @sf.page_find_node(card, fn() { "无结果" }, fn(_) {  }, fn(_) { false }, fn() {  }, field=f, tips~) |> ignore
          },
        ),
        (
          "无输入框 Steps",
          fn(card) {
            let at = kept(1)
            @sf.page_find_node(
              card,
              fn() { "「回程」 第 \{at.get()} / 5 处" },
              fn(d) { at.set(at.untracked() + d) },
              fn(d) { if d < 0 { at.get() > 1 } else { at.get() < 5 } },
              fn() {  },
              tips~,
            )
            |> ignore
          },
        ),
      ],
    },
    {
      key: "avatar-stack",
      group: "身份",
      name: "叠放头像 AvatarStack",
      file: "avatar_stack_node.mbt",
      api: [("avatar_stack_node.mbt", "avatar_stack_node")],
      play: None,
      about: "多人头像叠放：每个头像带一圈与底色相同的扣环，后一个压在前一个下面；超过上限时末尾显示 +n。",
      cases: [
        (
          "三人 Three",
          fn(card) {
            side_by_side(card, fn(r) {
              @sf.avatar_stack_node(r, stack_sample(3), 16.0, fn() { @sf.theme().p.bg }) |> ignore
              @sf.avatar_stack_node(r, stack_sample(3), 24.0, fn() { @sf.theme().p.bg }, ring_w=2.0, over=8.0) |> ignore
            })
          },
        ),
        (
          "超过上限 More",
          fn(card) {
            @sf.avatar_stack_node(card, stack_sample(8), 16.0, fn() { @sf.theme().p.bg }, over=7.0, most=5, tips~, tip=fn() {
              "左子健、Ada Lovelace 等 8 人"
            })
            |> ignore
          },
        ),
      ],
    },
  ] + stories_u8() + stories_u12(tips)
}
