// The library's ways of telling (notify_node.mbt way_tile_node): the banner drawn small in a way's picture, its corner
// concentric with the picture's (notify_banner_corner) on every system's look, at 390 and 1280; nothing the audit finds.

///|
test "a way's tiles, the banner's and the badge's, on a Mac's, Windows' and a phone's look, at 390 and 1280: the banner's corners concentric with its picture's, nothing the audit finds" {
  for w in [390.0, 1280.0] {
    let t = w2_case(w~, fn(root) {
      for look in [MacOS, Windows, Phone(island=false)] {
        way_tiles_node(root, fn(r) {
          way_tile_node(r, look, BannerWay, fn() { "横幅" }, fn() { "已开启" }, fn() { true }, fn() { "" }, fn() { false }, fn() {  })
          way_tile_node(r, look, BadgeWay, fn() { "角标" }, fn() { "已关闭" }, fn() { false }, fn() { "" }, fn() { false }, fn() {  })
        })
      }
    })
    assert_eq(t.audit(), [], msg="\{w}")
    assert_eq(notify_banner_corner(), 3.0)
  }
}

///|
test "notify_banner_node draws panel liquid glass with zero audit faults across light/dark, narrow/wide and across=true/false" {
  for dark in [false, true] {
    for w in [390.0, 1280.0] {
      for across in [true, false] {
        let t = @ui.Tester::tree(
          w~,
          h=240.0,
          platform=0,
          dark~,
          theme=fn() { ui_theme() },
          fn(root) {
            root.padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
            notify_banner_node(
              root,
              fn() { "整理发布清单" },
              fn() { "构建已完成，点击查看结果" },
              "",
              across~,
            )
          },
        )
        t.draw()
        assert_true(
          t.drawn_glass().iter().any(fn(g) { g.4 == 6 }),
          msg="dark=\{dark} w=\{w} across=\{across}: banner draws liquid glass",
        )
        assert_eq(t.audit(), [], msg="dark=\{dark} w=\{w} across=\{across}: banner audit")
      }
    }
  }
}
