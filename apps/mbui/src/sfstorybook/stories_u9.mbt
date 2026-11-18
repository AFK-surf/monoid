// The library's keyboard bar of keys, ring to choose by, words chosen between over a picture to share and key of how
// far something came (key_pad_bar_node.mbt, select_ring_node.mbt, share_tabs_node.mbt, bar_meter_button_node.mbt),
// each beside its states, what can be pressed answering as it does in the app.

///|
/// Their stories, after the others.
fn stories_u9() -> Array[Story] {
  [
    {
      key: "key-pad-bar",
      group: "按钮",
      name: "软键盘辅助键栏 KeyPadBar",
      file: "key_pad_bar_node.mbt",
      api: [
        ("key_pad_bar_node.mbt", "key_pad_key_node"),
        ("key_pad_bar_node.mbt", "key_pad_dpad_node"),
        ("key_pad_bar_node.mbt", "key_pad_row_node"),
        ("key_pad_bar_node.mbt", "KeyPadMods"),
      ],
      play: None,
      about: "终端软键盘上方的键与远程画面的键行共用的一套：修饰键按一次只管下一个键，再按锁住，第三次放开；键按下不抢输入焦点，按下时有触感；方向键和 ⌫ 围着高的 ⏎ 排成倒 T，按住连发；键行放不下时最少用的先让位，末尾的 ⋯ 把键行翻到它们，按住的修饰键从不让位。",
      cases: [
        (
          "修饰键（一次 · 锁住 · 放开）与倒 T 方向键",
          fn(card) {
            let mods = @sf.KeyPadMods::new()
            let typed = kept("")
            let typed_key = fn(key : String) {
              let held = mods.consume_once()
              let ctrl = if (held & @ui.key_in_ctrl) != 0 { "⌃" } else { "" }
              typed.set(typed.get() + ctrl + key + " ")
            }
            side_by_side(card, fn(r) {
              @sf.key_pad_key_node(r, "Esc", "Esc", fn() { typed_key("Esc") }, width=56.0, height=41.0) |> ignore
              @sf.key_pad_key_node(r, "Ctrl", "Control", fn() { mods.press(@ui.key_in_ctrl) }, width=56.0, height=41.0, held=fn() {
                mods.holds(@ui.key_in_ctrl)
              })
              |> ignore
              @sf.key_pad_dpad_node(r, 38.0, 41.0, 44.0, 86.0, typed_key) |> ignore
            })
            @sf.words_node(card, fn() { "按下的键：" + typed.get() }, fn() { story_fact_words }) |> ignore
          },
        ),
        (
          "键行（窄时让位，⋯ 翻面）",
          fn(card) {
            let turned : @signals.Signal[Array[String]] = kept([])
            let shift = kept(false)
            let key = fn(cap : String, name : String, icon : String, drop : Int) -> @sf.KeyPadKey {
              { cap, name, icon, drop, held: None, felt: None, press: fn() {  } }
            }
            card.box(fn(narrow) {
              narrow.width(Is(Some(260.0))) |> ignore
              @sf.key_pad_row_node(narrow, [
                key("Esc", "Esc", "", 0),
                key("Tab", "Tab", "", 3),
                {
                  cap: "⇧",
                  name: "Shift",
                  icon: "",
                  drop: 2,
                  held: Some(fn() { shift.get() }),
                  felt: None,
                  press: fn() { shift.set(!shift.get()) },
                },
                key("⌥", "Option", "", 1),
                key("", "左", "arrow-left", 4),
                key("", "右", "arrow-right", 4),
              ], turned)
              |> ignore
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "select-ring",
      group: "选择",
      name: "圆环多选 SelectRing",
      file: "select_ring_node.mbt",
      api: [("select_ring_node.mbt", "select_ring_node")],
      play: None,
      about: "图片上的多选圆环（最近的照片、文件夹里的文件）：没选时是白圈压着一层淡黑，白图上也看得见；选中后填成主色，写上第几个被选中；读作复选框。",
      cases: [
        (
          "按选中的先后编号",
          fn(card) {
            let chosen : @signals.Signal[Array[String]] = kept(["b"])
            let order = fn(k : String) {
              match chosen.get().search(k) {
                Some(i) => i + 1
                None => 0
              }
            }
            side_by_side(card, fn(r) {
              for k in ["a", "b", "c"] {
                r.box(fn(tile) {
                  tile
                  .width(Is(Some(64.0)))
                  .height(Is(Some(64.0)))
                  // (its corner the ring's half side and the 6 it stands in from both edges: concentric)
                  .radius(Is(@sf.select_ring_side / 2.0 + 6.0))
                  .padding(Is((6.0, 6.0, 6.0, 6.0)))
                  .lies_along(Is(End))
                  .ground(By(fn() { @ui.tree_theme().color(Tint) }))
                  |> ignore
                  @sf.select_ring_node(tile, fn() { "选择 " + k }, fn() { order(k) }, fn() {
                    let now = chosen.get()
                    chosen.set(if now.contains(k) { now.filter(fn(x) { x != k }) } else { [..now, k] })
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
      key: "share-tabs",
      group: "选择",
      name: "分享图分组 ShareTabs",
      file: "share_tabs_node.mbt",
      api: [("share_tabs_node.mbt", "share_tabs_node")],
      play: None,
      about: "分享图上方的分组切换（卡片的样式分组、部分打码 | 完全打码）：一行居中的字，当前的白而略粗，手放上去的变白，其余淡白；读作标签列表，← → 逐个切换。",
      cases: [
        (
          "两组",
          fn(card) {
            let shown = kept(false)
            card.box(fn(night) {
              night.padding(Is((16.0, 12.0, 16.0, 12.0))).radius(Is(12.0)).ground(Is(0x18181BFFL)) |> ignore
              @sf.share_tabs_node(
                night,
                fn() { "打码" },
                [false, true],
                fn(all) { if all { "完全打码" } else { "部分打码" } },
                fn() { shown.get() },
                fn(all) { shown.set(all) },
              )
              |> ignore
            })
            |> ignore
          },
        ),
      ],
    },
    {
      key: "bar-meter",
      group: "进度",
      name: "进度键 BarMeter",
      file: "bar_meter_button_node.mbt",
      api: [("bar_meter_button_node.mbt", "bar_meter_button_node")],
      play: None,
      about: "工具栏里说明进展的键（网页服务的资源加载）：一个圆环，有失败时变红；按下看明细；读作按钮，圆环读作进度条。",
      cases: [
        (
          "加载中 · 有失败",
          fn(card) {
            let part = kept(40)
            side_by_side(card, fn(r) {
              for failed in [false, true] {
                @sf.bar_meter_button_node(
                  r,
                  fn() { "加载" },
                  fn(_) { part.set((part.get() + 20) % 120) },
                  ring=20.0,
                  part=fn() { part.get().to_double() },
                  value=fn() { "\{part.get()}%" },
                  color=fn() { if failed { @sf.theme().p.red } else { @sf.theme().p.muted } },
                )
                |> ignore
              }
            })
          },
        ),
      ],
    },
  ]
}
