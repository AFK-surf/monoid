// The kind a block of a page's list put by and taken again was given (View::reused_kind): 100 keys of blocks 40 tall
// in a column 200 tall, the even ones of one shape and the odd ones of another; each block and what is made in it
// read the kind as the block is made, and it stays its kind's as the block is taken for key after key.

///|
priv struct KindBlock {
  block : @view.View
  key : () -> Int
  /// the kind read by the block itself and by a node made in it, as they were made
  kind : Int?
  inner : Int?
}

///|
fn reused_kind_case(
  reuses? : (Int) -> Bool = fn(_) { true },
) -> (@view.Tree, @view.Scroll, Array[KindBlock], Ref[Double]) {
  let list = @view.Scroll::list()
  let blocks : Array[KindBlock] = []
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
      o.scrolls_reused(
        list,
        fn() { Array::makei(100, fn(i) { i }) },
        est=40.0,
        shape=fn(k) { k % 2 },
        reuses~,
        fn(b, key) {
          b.height(Is(Some(40.0))).words(By(fn() { "row \{key()}" })) |> ignore
          let inner : Ref[Int?] = Ref(None)
          b.box(fn(i) { inner.val = i.reused_kind() }) |> ignore
          blocks.push({ block: b, key, kind: b.reused_kind(), inner: inner.val })
        },
      )
      |> ignore
    })
    |> ignore
  })
  let now = Ref(16.0)
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  (tree, list, blocks, now)
}

///|
test "reused_kind: each block's kind its shape's as it was made, the same as it is taken for key after key" {
  let (tree, list, blocks, now) = reused_kind_case()
  let mut y = 0.0
  let wrong : Array[String] = []
  while y < 3800.0 {
    y = y + 40.0
    list.put(y)
    now.val = now.val + 16.0
    tree.frame(390.0, 844.0, now=now.val) |> ignore
    now.val = now.val + 16.0
    tree.frame(390.0, 844.0, now=now.val) |> ignore
    for b in blocks {
      if b.block.alive() && b.block.parent() is Some(_) {
        let k = @signals.untracked(b.key)
        if b.kind != Some(k % 2) || b.inner != Some(k % 2) {
          wrong.push("key \{k}: kind \{b.kind.unwrap_or(-1)}, inner \{b.inner.unwrap_or(-1)}")
        }
      }
    }
  }
  // (a few screens of blocks made, each taken for many keys)
  assert_true(blocks.length() < 30, msg="made \{blocks.length()}")
  assert_eq(wrong, [])
  assert_eq(
    blocks.filter(fn(b) { b.kind == Some(0) }).length() > 0 && blocks.filter(fn(b) { b.kind == Some(1) }).length() > 0,
    true,
  )
}

///|
test "reused_kind: none for a key said not to be taken, nor outside the list" {
  let (_, _, blocks, _) = reused_kind_case(reuses=fn(k) { k != 0 })
  let zero = blocks.filter(fn(b) { @signals.untracked(b.key) == 0 })
  let outside : Ref[Int?] = Ref(Some(-1))
  @view.Tree::new(fn(root) { outside.val = root.reused_kind() }) |> ignore
  assert_eq((zero.map(fn(b) { (b.kind, b.inner) }), outside.val), ([(None, None)], None))
}
