// What a page's list's pinned foot says resizes (View::resizes, `foot`) at the moment a key flies in goes on that
// flight's rise, as long (Tree::feet_carried): on a flight shorter than the Move it was said on too, at rest at the
// flight's end, nothing of its way left going after it.

///|
let feet_at : Double = 100.5

///|
test "feet_carried: on a flight shorter than its Move, the foot at rest at the flight's end" {
  for flips in [false, true] {
    let ms = 120.0
    let keys = @signals.signal(Array::makei(10, fn(i) { i }), same=fn(a, b) { a == b })
    let tall = @signals.signal(90.0, same=fn(a, b) { a == b })
    let foot_box : Ref[View?] = Ref(None)
    let tree = Tree::new(fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
        o.scrolls_window(
          Scroll::list(),
          fn() { keys.get() },
          est=40.0,
          follows=fn() { true },
          flips~,
          foot=fn(f) {
            f.box(fn(c) {
              foot_box.val = Some(c)
              c.height(By(fn() { Some(tall.get()) })).shrink(Is(0.0)).words(Is("脚")) |> ignore
            })
            |> ignore
          },
          fn(b, k) {
            if k == 70 {
              b.box(fn(w) {
                w.height(Is(Some(60.0))).shrink(Is(0.0)).words(Is("行70")) |> ignore
                w.flies_in({ way: fn(_) { (ms, fn(t) { if t >= ms { 1.0 } else { t / ms } }) } }, fn(to) {
                  Some((0.0, 380.0, to.2, to.3))
                })
                |> ignore
              })
              |> ignore
            } else {
              b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
            }
          },
        )
        |> ignore
      })
      |> ignore
    })
    tree.frame(390.0, 844.0) |> ignore
    tree.event(feet_at, fn() {
      keys.set(Array::makei(11, fn(i) { if i < 10 { i } else { 70 } }))
      match foot_box.val {
        Some(c) => c.resizes(foot=true) |> ignore
        None => ()
      }
      tall.set(30.0)
    })
    tree.frame(390.0, 844.0, now=feet_at) |> ignore
    tree.frame(390.0, 844.0, now=feet_at + ms / 2.0) |> ignore
    let at = match foot_box.val {
      Some(c) => c.at
      None => -1
    }
    assert_true(tree.nodes[at].coming, msg="flips \{flips}: the foot not on its way half way through the flight")
    tree.frame(390.0, 844.0, now=feet_at + ms + 1.0) |> ignore
    assert_false(tree.nodes[at].coming, msg="flips \{flips}: the foot still on its way after the flight's end")
    assert_true((tree.nodes[at].flex.height - 30.0).abs() < 0.01, msg="flips \{flips}: the foot \{tree.nodes[at].flex.height} tall")
  }
}
