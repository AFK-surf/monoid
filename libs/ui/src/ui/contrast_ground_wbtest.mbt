///|
test "a ground covers text up to the smooth edge of each of its four corners" {
  let t = Tester::new(
    fn(c) {
      c.box(
        w=Px(200.0),
        h=Px(100.0),
        style=style(radius=Corners(24.0, 0.0, 80.0, 12.0)),
        bg=red,
        fn() {  },
      ) |> ignore
    },
    w=200.0,
    h=100.0,
  )
  t.draw()
  let drawn = rect_of_color(red)
  let box = FixedArray::makei(inst_size, fn(i) { drawn[i] })
  let covers = fn(x, y) { ground_kind(box, 0, x, y).0 == 1 }
  // A point seven units from both edges falls inside the smooth 24-point corner.
  assert_true(covers(7.0, 7.0))
  assert_false(covers(4.0, 4.0))
  assert_true(covers(198.0, 2.0))
  assert_false(covers(193.0, 93.0))
  // The bottom-right radius tops out at half the height. Its curve eases into the bottom edge.
  assert_false(covers(150.0, 99.9))
  assert_true(covers(150.0, 99.0))
  assert_true(covers(7.0, 93.0))
  assert_false(covers(1.0, 99.0))
}

///|
test "a shape with words over it is their ground, asked nothing; with none, a mark of its own, asked" {
  // (still.fail's chat find: a highlighter's swipe behind the word found, a yellow at 70% on a white page, 1.13 to 1)
  let swipe = [([0.0, 0.0, 60.0, 1.0, 58.0, 18.0, 2.0, 17.0], true)]
  let scribble = [([2.0, 16.0, 4.0, 2.0, 6.0, 16.0, 8.0, 2.0, 10.0, 16.0, 12.0, 2.0, 14.0, 16.0, 58.0, 2.0], false)]
  for shape in [shape_of(swipe, fill=0xFFF12DB3L), shape_of(scribble, stroke=0xFFF12DB3L, width=3.0)] {
    for words in [true, false] {
      let t = Tester::new(
        fn(c) {
          c.box(w=Px(300.0), h=Px(100.0), bg=0xFFFFFFFFL, fn() {
            c.box(w=Px(60.0), h=Px(24.0), fn() {
              c.layer(fn() {
                c.box(ty=3.0, fn() { c.shapes([shape], w=Px(60.0), h=Px(18.0)) |> ignore })
                |> ignore
              })
              |> ignore
              // (the words over it: a layer after its)
              if words {
                c.layer(fn() { c.text("找到的词", size=14.0, line=24.0) |> ignore }) |> ignore
              }
            })
            |> ignore
          })
          |> ignore
        },
        w=300.0,
        h=100.0,
      )
      let faults = t.contrast_faults()
      if words {
        assert_eq(faults, [])
      } else {
        assert_true(faults.length() > 0, msg="a faint swipe with no words on it is a mark of its own")
      }
    }
  }
}

///|
test "under glass that blurs, a fill narrower than the blur's reach is smeared out, not the ground of the words over it" {
  // (still.fail's new chat in the dark: a preset's summary over the presets' panel, its 14 pt liquid blur over the
  // split's 5 pt grip, said 4.17 to 1 on the grip as though the glass showed it whole, 2026-11-26)
  let faults_over = fn(bar_w : Double) {
    let t = Tester::new(
      fn(c) {
        c.box(w=Px(300.0), h=Px(200.0), bg=0x151517FFL, fn() {
          c.layer(fn() {
            c.box(w=Px(bar_w), h=Px(40.0), left=20.0, top=20.0, bg=0xFFFFFFFFL, fn() {  }) |> ignore
          })
          |> ignore
          c.layer(fn() {
            c.box(
              w=Px(200.0),
              h=Px(100.0),
              glass=Glass::frosted(blur=14.0, tint=0x2C2C2E80L, solid=0x2C2C2EFFL),
              fn() { c.box(left=20.0, top=30.0, fn() { c.text("含指令", size=13.0, color=0xB8BBC1FFL) |> ignore }) |> ignore },
            )
            |> ignore
          })
          |> ignore
        })
        |> ignore
      },
      w=300.0,
      h=200.0,
    )
    t.contrast_faults()
  }
  assert_eq(faults_over(5.0), [])
  assert_true(faults_over(120.0).length() > 0, msg="a fill wider than the blur's reach is still the words' ground")
}
