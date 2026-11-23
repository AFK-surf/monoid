// Other bytes handed over under a key already shown (a preview, then the picture itself): decoded again, what showed
// before standing in until that decode is ready and let go of then; the same bytes handed over again decode nothing.

///|
/// The decodes of `key` kept: each one's host id, the long side it was asked for, and its state.
fn overwrite_entries(key : String) -> Array[(Int, Int, Int)] {
  match image_cache.get(key) {
    Some(list) => list.map(fn(e) { (e.id, e.px, e.state) })
    None => []
  }
}

///|
/// The host ids of the decodes of `key` still coming.
fn overwrite_coming(key : String) -> Array[Int] {
  overwrite_entries(key).filter(fn(e) { e.2 == 0 }).map(fn(e) { e.0 })
}

///|
test "other bytes under a key shown: decoded again, the old picture standing in till the new one is ready, then let go of" {
  let t = Tester::new(
    fn(c) { c.image("mem:pic", w=Px(100.0), h=Px(100.0), fit=FitContain) |> ignore },
    w=200.0,
    h=200.0,
    finish=false,
  )
  add_image("mem:pic", b"\x89PNG preview")
  t.draw()
  let first = overwrite_entries("mem:pic")
  assert_eq(first.length(), 1)
  let (id1, want, _) = first[0]
  t.finish(1, id1)
  t.draw()
  assert_eq(overwrite_entries("mem:pic"), [(id1, want, 1)])
  assert_eq(image_size("mem:pic"), Some((400.0, 300.0)))
  let said = image_said("mem:pic")
  let decodes = said.decodes.untracked()
  // the picture itself: the preview kept only to stand in, what draws it told
  add_image("mem:pic", b"\x89PNG the picture itself")
  assert_eq(overwrite_entries("mem:pic"), [(id1, 0, 1)])
  assert_true(said.decodes.untracked() > decodes)
  assert_true(decode_state("mem:pic", want).untracked() == DecodeComing)
  assert_eq(named_image_state("mem:pic").0, 0)
  // drawn: a decode of the new bytes asked for, the preview drawn meanwhile (no frame of nothing)
  t.draw()
  let coming = overwrite_coming("mem:pic")
  assert_eq(coming.length(), 1)
  let id2 = coming[0]
  assert_true(id2 != id1)
  match image_entry_for("mem:pic", want.to_double(), 0, t.time()) {
    Some(e) => assert_eq(e.id, id1)
    None => fail("nothing stands in while the new bytes decode")
  }
  assert_true(t.fake.images.contains(id1))
  // the new decode ready: it is drawn, the preview let go of (its texture freed)
  t.finish(1, id2)
  assert_eq(overwrite_entries("mem:pic"), [(id2, want, 1)])
  assert_true(!t.fake.images.contains(id1))
  match image_entry_for("mem:pic", want.to_double(), 0, t.time()) {
    Some(e) => assert_eq(e.id, id2)
    None => fail("the new decode is not drawn")
  }
  assert_eq(image_size("mem:pic"), Some((400.0, 300.0)))
  assert_true(decode_state("mem:pic", want).untracked() == DecodeDone)
  assert_eq(named_image_state("mem:pic").0, 1)
}

///|
test "the same bytes handed over again, each frame by an old view or from outside: nothing decoded again" {
  let t = Tester::new(
    fn(c) {
      // (bytes equal to those before, though not the same Bytes, as a view that makes them each frame hands them over)
      c.image_bytes("mem:same", Bytes::from_array([b'\x89', b'P', b'N', b'G', b'1']))
      c.image("mem:same", w=Px(100.0), h=Px(100.0), fit=FitContain) |> ignore
    },
    w=200.0,
    h=200.0,
    finish=false,
  )
  t.draw()
  let (id1, want, _) = overwrite_entries("mem:same")[0]
  t.finish(1, id1)
  t.draw()
  let loads = t.image_loads().length()
  let decodes = image_said("mem:same").decodes.untracked()
  add_image("mem:same", b"\x89PNG1")
  t.draw()
  t.draw()
  assert_eq(overwrite_entries("mem:same"), [(id1, want, 1)])
  assert_eq(t.image_loads().length(), loads)
  assert_eq(image_said("mem:same").decodes.untracked(), decodes)
  assert_true(t.fake.images.contains(id1))
}

///|
test "other bytes over a decode still coming, or one that failed: that one let go of at once, the new bytes decoded" {
  let t = Tester::new(
    fn(c) {
      c.image("mem:busy", w=Px(100.0), h=Px(100.0), fit=FitContain) |> ignore
      c.image("mem:bad", w=Px(100.0), h=Px(100.0), fit=FitContain) |> ignore
    },
    w=200.0,
    h=200.0,
    finish=false,
  )
  add_image("mem:busy", b"\x89PNG old")
  add_image("mem:bad", b"\x89PNG broken")
  t.draw()
  let busy1 = overwrite_coming("mem:busy")[0]
  let bad1 = overwrite_coming("mem:bad")[0]
  t.finish(1, bad1, ok=false)
  t.draw()
  // (failed: not asked again for the same bytes)
  assert_eq(overwrite_entries("mem:bad").map(fn(e) { e.0 }), [bad1])
  // other bytes: the decode still coming and the failed one let go of, nothing left of the old bytes
  add_image("mem:busy", b"\x89PNG new")
  add_image("mem:bad", b"\x89PNG fixed")
  assert_eq(overwrite_entries("mem:busy"), [])
  assert_eq(overwrite_entries("mem:bad"), [])
  assert_true(!t.fake.images.contains(busy1))
  assert_true(!t.fake.images.contains(bad1))
  // drawn: each decoded again, and ready
  t.draw()
  let busy2 = overwrite_coming("mem:busy")
  let bad2 = overwrite_coming("mem:bad")
  assert_eq((busy2.length(), bad2.length()), (1, 1))
  t.finish(1, busy2[0])
  t.finish(1, bad2[0])
  assert_true(overwrite_entries("mem:busy").map(fn(e) { e.2 }) == [1])
  assert_true(overwrite_entries("mem:bad").map(fn(e) { e.2 }) == [1])
  assert_true(image_ready_asking_none("mem:bad"))
}

///|
test "a decode of what a picture showed before, ready late (standing in only): its size not told as the picture's" {
  let px = Ref(100.0)
  let t = Tester::new(
    fn(c) { c.image("mem:late", w=Px(px.val), h=Px(px.val), fit=FitContain) |> ignore },
    w=200.0,
    h=200.0,
    finish=false,
  )
  add_image("mem:late", b"\x89PNG late")
  t.draw()
  let id1 = overwrite_coming("mem:late")[0]
  t.finish(1, id1)
  assert_eq(image_size("mem:late"), Some((400.0, 300.0)))
  // a sharper decode asked for, then made one only standing in (px 0, as a redraw has it) of another size
  px.val = 300.0
  t.draw()
  let id2 = overwrite_coming("mem:late")[0]
  for e in image_cache.get("mem:late").unwrap() {
    if e.id == id2 {
      e.px = 0
    }
  }
  t.fake.images[id2] = { state: 0, w: 999.0, h: 777.0, ow: 999.0, oh: 777.0 }
  t.finish(1, id2)
  assert_eq(image_size("mem:late"), Some((400.0, 300.0)))
  // (and what is ready at its own size not let go of for it)
  assert_true(overwrite_entries("mem:late").any(fn(e) { e.0 == id1 && e.2 == 1 }))
}

///|
test "a vector picture handed over again with its renderer: decoded again, drawn by the new renderer" {
  let drawn : Array[String] = []
  let one = fn(_d : Bytes, _px : Int) -> (Int, Int, FixedArray[Byte])? {
    drawn.push("one")
    Some((1, 1, FixedArray::make(4, b'\xFF')))
  }
  let two = fn(_d : Bytes, _px : Int) -> (Int, Int, FixedArray[Byte])? {
    drawn.push("two")
    Some((1, 1, FixedArray::make(4, b'\x00')))
  }
  let t = Tester::new(
    fn(c) { c.image("mem:vec", w=Px(100.0), h=Px(100.0), fit=FitContain) |> ignore },
    w=200.0,
    h=200.0,
    finish=false,
  )
  add_vector_image("mem:vec", b"<svg/>", one)
  t.draw()
  let id1 = overwrite_coming("mem:vec")[0]
  t.finish(1, id1)
  t.draw()
  assert_eq(drawn, ["one"])
  add_vector_image("mem:vec", b"<svg/>", two)
  assert_eq(overwrite_entries("mem:vec").map(fn(e) { (e.0, e.1) }), [(id1, 0)])
  t.draw()
  assert_eq(drawn, ["one", "two"])
  let id2 = overwrite_coming("mem:vec")[0]
  t.finish(1, id2)
  assert_eq(overwrite_entries("mem:vec").map(fn(e) { e.0 }), [id2])
  assert_true(!t.fake.images.contains(id1))
}
