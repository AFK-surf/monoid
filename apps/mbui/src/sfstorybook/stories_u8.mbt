// The library's counts (count_badge_node.mbt), each beside its states.

///|
/// Their stories, after the others.
fn stories_u8() -> Array[Story] {
  [
    {
      key: "count-badge",
      group: "标记",
      name: "数字角标 CountBadge",
      file: "count_badge_node.mbt",
      api: [("count_badge_node.mbt", "count_badge_node"), ("count_badge_node.mbt", "count_words")],
      play: None,
      about: "数着的数：挂在所数之物角上的角标（红色或主色实心，16 高的圆或胶囊，数字按角标的尺寸画，不随系统字号放大；不给数时是 8 的圆点），和排在标题旁的行内计数（浅底，随字号长高）。超过上限写成 99+。",
      cases: [
        (
          "角标：数、超过 99、主色、圆点",
          fn(card) {
            side_by_side(card, fn(r) {
              @sf.count_badge_node(r, count=fn() { 3 }) |> ignore
              @sf.count_badge_node(r, count=fn() { 120 }, max=99) |> ignore
              @sf.count_badge_node(r, count=fn() { 12 }, tone=CountAccent) |> ignore
              @sf.count_badge_node(r) |> ignore
            })
          },
        ),
        (
          "行内计数",
          fn(card) {
            side_by_side(card, fn(r) {
              @sf.count_badge_node(r, count=fn() { 7 }, look=Inline, tone=CountAccent) |> ignore
              @sf.count_badge_node(r, count=fn() { 1200 }, look=Inline, max=999) |> ignore
            })
          },
        ),
      ],
    },
  ]
}
