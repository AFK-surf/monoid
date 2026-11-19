// A page made once (page_node) whose blocks are put by and taken again (its `reused` and `make_reused`): 200 blocks
// each 60 tall, scrolled to the foot and back, narrow and wide; as few blocks made as show round what shows, and every
// block drawn where and as the same page made without taking any again draws it (wide, the first block's room over
// it following which key a block shows).

///|
/// A page of 200 blocks in a Tester `w` wide (narrow under narrow_most, wide over it), its blocks taken again where
/// `reused`: scrolled down to its foot and back up a block at a time (each step a frame's, as a finger moves it: more
/// than the few a list puts by leaving at once are let go), what it draws at 3000 on the way down and at its
/// top again, and how many blocks were made, made once and made to be taken again.
fn pooled_page(w : Double, reused : Bool) -> (Array[String], Array[String], Int, Int) {
  let t = @ui.Tester::new(fn(_c) {  }, w~, h=800.0, platform=2)
  let scroll = @view.Scroll::list()
  let once = Ref(0)
  let pooled = Ref(0)
  let block_of = fn(room : @view.View, key : () -> String) {
    room.box(fn(b) { b.height(Is(Some(60.0))).words(By(fn() { "block " + key() })) |> ignore }) |> ignore
  }
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.height(Is(Some(800.0))).width(Is(Some(w))) |> ignore
      page_node(
        b,
        fn() { "Title" },
        fn() { Array::makei(200, fn(i) { "b\{i}" }) },
        fn(v, k) {
          once.val = once.val + 1
          block_of(v, fn() { k })
        },
        on_back=fn() {  },
        width=fn() { w },
        scroll~,
        reused?=if reused { Some(fn(_k : String) -> Int? { Some(0) }) } else { None },
        make_reused=fn(v, kind, key) {
          // (every block of the one kind it gives: counted only as such)
          if kind == 0 {
            pooled.val = pooled.val + 1
          }
          block_of(v, key)
        },
      )
    })
    |> ignore
  })
  t.draw()
  let drawn = fn() {
    match @ui.view_tree() {
      Some(tree) => {
        let out = tree
          .drawn()
          .filter(fn(d) { d.words.has_prefix("block ") && d.y + d.h > 0.0 && d.y < 800.0 })
          .map(fn(d) { "\{d.words} \{d.x} \{d.y} \{d.w} \{d.h}" })
        out.sort()
        out
      }
      None => []
    }
  }
  let at = fn(y : Double) {
    scroll.put(y)
    t.draw()
    t.draw()
  }
  let mut mid : Array[String] = []
  let mut y = 0.0
  while y < 12000.0 {
    y = y + 60.0
    at(y)
    if y == 3000.0 {
      mid = drawn()
    }
  }
  while y > 0.0 {
    y = y - 60.0
    at(y)
  }
  (mid, drawn(), once.val, pooled.val)
}

///|
test "a page whose blocks are taken again, narrow: a few made for 200, each drawn where the page made without taking any draws it, at its top again too" {
  let (mid_was, top_was, once_was, _) = pooled_page(390.0, false)
  let (mid, top, once, pooled) = pooled_page(390.0, true)
  assert_true(once_was >= 200, msg="made once \{once_was}")
  // (the blocks made once alone the page's own (its title, its foot), none of its 200)
  assert_true(once < 10, msg="made once \{once}")
  assert_true(pooled > 0 && pooled < 40, msg="made to be taken \{pooled}")
  assert_true(mid.length() > 0 && top.length() > 0)
  assert_eq((mid, top), (mid_was, top_was))
}

///|
test "a page whose blocks are taken again, wide: a few made for 200, the first's room over it following the key a block shows, drawn as the page made without taking any" {
  let (mid_was, top_was, _, _) = pooled_page(1200.0, false)
  let (mid, top, once, pooled) = pooled_page(1200.0, true)
  assert_true(once < 10, msg="made once \{once}")
  assert_true(pooled > 0 && pooled < 40, msg="made to be taken \{pooled}")
  assert_true(top.iter().any(fn(l) { l.has_prefix("block b0 ") }))
  assert_eq((mid, top), (mid_was, top_was))
}
