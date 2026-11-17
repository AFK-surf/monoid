// The places of glyphs in a host's atlas (hostapi's atlas.mbt), as text.mbt asks for them.

///|
test "an atlas fills its plots a shelf at a time, then empties the shelf drawn from longest ago, never one this frame draws from" {
  // 1024 a side: four plots of 512, at (0, 0), (512, 0), (0, 512), (512, 512); glyphs 100 square, five to a shelf
  // (a pixel apart), five shelves to a plot
  let a = @hostapi.Atlas::new(1024)
  let gone : Array[Int] = []
  let put = fn(key : Int) { a.place(key, 100, 100, fn(k) { gone.push(k) }) }
  assert_eq(put(0), Some((0, 0, 0)))
  assert_eq(put(1), Some((0, 101, 0)))
  for k in 2..<5 {
    put(k) |> ignore
  }
  // the next shelf under the first
  assert_eq(put(5), Some((1, 0, 101)))
  for k in 6..<25 {
    put(k) |> ignore
  }
  // the first plot full: a shelf in the next, a plot never filled
  assert_eq(put(25), Some((5, 512, 0)))
  // the next frames fill the rest
  a.next_frame()
  for k in 26..<50 {
    put(k) |> ignore
  }
  a.next_frame()
  for k in 50..<75 {
    put(k) |> ignore
  }
  a.next_frame()
  for k in 75..<100 {
    put(k) |> ignore
  }
  assert_eq(gone, [])
  // all full, the first shelf drawn from in this frame (what is on the screen): the shelf drawn from longest ago, the
  // second, emptied, its five glyphs gone and no more
  a.next_frame()
  a.drawn(0)
  assert_eq(put(100), Some((1, 0, 101)))
  assert_eq(gone, [5, 6, 7, 8, 9])
  gone.clear()
  // filled again in this frame, every other shelf drawn from in it too: no room while it is drawn, nothing emptied
  for k in 101..<105 {
    put(k) |> ignore
  }
  for i in 2..<20 {
    a.drawn(i)
  }
  assert_eq(put(105), None)
  assert_eq(gone, [])
  // the next frame: room again, from the shelf drawn from longest ago
  a.next_frame()
  for i in 0..<20 {
    if i != 2 {
      a.drawn(i)
    }
  }
  assert_eq(put(105), Some((2, 0, 202)))
  assert_eq(gone, [10, 11, 12, 13, 14])
  gone.clear()
  // one taller than any shelf: the plot none of whose shelves this frame draws from, drawn from longest ago, emptied
  // whole
  a.next_frame()
  for i in 0..<15 {
    a.drawn(i)
  }
  match a.place(200, 50, 300, fn(k) { gone.push(k) }) {
    Some((_, x, y)) => assert_eq((x, y), (512, 512))
    None => fail("no room for a tall one")
  }
  assert_eq(gone, Array::makei(25, fn(i) { 75 + i }))
}

///|
test "an atlas holds no glyph larger than a plot, nor any with nothing to draw" {
  let a = @hostapi.Atlas::new(2048)
  assert_true(a.holds(@hostapi.atlas_plot, @hostapi.atlas_plot))
  assert_true(!a.holds(@hostapi.atlas_plot + 1, 10))
  assert_true(!a.holds(0, 10))
  assert_eq(a.place(0, @hostapi.atlas_plot + 1, 10, fn(_) {  }), None)
  // none at all
  assert_true(!@hostapi.Atlas::new(0).holds(10, 10))
  // one of a side smaller than a plot: the whole of it one
  let small = @hostapi.Atlas::new(64)
  assert_true(small.holds(64, 64))
  assert_true(!small.holds(65, 10))
  assert_eq(small.place(0, 64, 64, fn(_) {  }), Some((0, 0, 0)))
}

///|
test "an atlas let go of: its glyphs placed from the start again" {
  let a = @hostapi.Atlas::new(1024)
  a.place(0, 100, 100, fn(_) {  }) |> ignore
  a.place(1, 100, 100, fn(_) {  }) |> ignore
  a.clear()
  assert_eq(a.place(2, 100, 100, fn(_) {  }), Some((0, 0, 0)))
}

///|
/// Whether two glyphs' rectangles (x, y, w, h) share a pixel.
fn atlas_overlap(a : (Int, Int, Int, Int), b : (Int, Int, Int, Int)) -> Bool {
  let (ax, ay, aw, ah) = a
  let (bx, by, bw, bh) = b
  ax < bx + bw && bx < ax + aw && ay < by + bh && by < ay + ah
}

///|
test "words scrolled through with a glyph of each stretch of them kept on the screen: every one placed, none on the screen let go" {
  // 4096 a side, glyphs 56 square (Han at 15 points, 3.5 pixels a point), 25 new ones a frame; one in every 50 stays
  // on the screen, drawn from in every frame after it came: one in each plot's 81, so that were a plot emptied only
  // whole, past the 64th none could be, every glyph after it with no room
  let a = @hostapi.Atlas::new(4096)
  let gone : Array[Int] = []
  let live : Map[Int, (Int, Int, Int, Int)] = Map([])
  let stays : Array[(Int, Int)] = []
  let mut key = 0
  for _ in 0..<400 {
    a.next_frame()
    for s in stays {
      a.drawn(s.1)
    }
    for _ in 0..<25 {
      match
        a.place(key, 56, 56, fn(k) {
          gone.push(k)
          live.remove(k)
        }) {
        Some((shelf, x, y)) => {
          let r = (x, y, 56, 56)
          for s in stays {
            assert_true(!atlas_overlap(live[s.0], r), msg="\{key} over \{s.0}")
          }
          live[key] = r
          if key % 50 == 0 {
            stays.push((key, shelf))
          }
        }
        None => fail("no room for \{key}")
      }
      key += 1
    }
  }
  assert_eq(key, 10000)
  assert_eq(stays.length(), 200)
  // none on the screen let go; what was let go, let go once
  assert_true(gone.iter().all(fn(k) { k % 50 != 0 }))
  let once : Map[Int, Bool] = Map([])
  for k in gone {
    assert_true(!once.contains(k))
    once[k] = true
  }
  // the atlas holds 5184 of them (nine shelves of nine to a plot), as many as it did: all but those let go are where
  // they were put
  assert_eq(live.length(), 10000 - gone.length())
  assert_true(live.length() <= 5184 && live.length() > 5000, msg="\{live.length()}")
}

///|
test "a large glyph stays while it is drawn from, its shelf or its plot taken when it is not, and none overlaps another" {
  // 1024 a side: four plots of 512; glyphs of 40, one of 300 × 80, and of 512 (a plot's whole)
  let a = @hostapi.Atlas::new(1024)
  let live : Map[Int, (Int, Int, Int, Int)] = Map([])
  // (what was put out of the atlas or over another, said)
  let wrong : Array[String] = []
  let put = fn(key : Int, w : Int, h : Int) -> Int? {
    match a.place(key, w, h, fn(k) { live.remove(k) }) {
      Some((shelf, x, y)) => {
        let r = (x, y, w, h)
        if x < 0 || y < 0 || x + w > 1024 || y + h > 1024 {
          wrong.push("\{key} out")
        }
        live.each(fn(k, o) { if atlas_overlap(o, r) { wrong.push("\{key} over \{k}") } })
        live[key] = r
        Some(shelf)
      }
      None => None
    }
  }
  let wide = put(0, 300, 80).unwrap()
  let big = put(1, 512, 512).unwrap()
  assert_eq(live[0], (0, 0, 300, 80))
  // (no room under the wide one: a plot of its own)
  assert_eq(live[1], (512, 0, 512, 512))
  // small ones round them (beside the wide one first, on its shelf), frame after frame, more than the rest of the
  // atlas holds, the large two drawn from in each: they stay
  let mut key = 2
  for _ in 0..<40 {
    a.next_frame()
    a.drawn(wide)
    a.drawn(big)
    for _ in 0..<20 {
      put(key, 40, 40).unwrap() |> ignore
      key += 1
    }
  }
  assert_eq(live[0], (0, 0, 300, 80))
  assert_eq(live[1], (512, 0, 512, 512))
  // no longer drawn from: the wide one's shelf taken for small ones in time
  for _ in 0..<40 {
    a.next_frame()
    for _ in 0..<20 {
      put(key, 40, 40).unwrap() |> ignore
      key += 1
    }
  }
  assert_true(!live.contains(0))
  // and one as large as a plot: the one shelf as tall, the large one's, emptied for it
  a.next_frame()
  put(key, 512, 512).unwrap() |> ignore
  assert_true(!live.contains(1))
  assert_eq(live[key], (512, 0, 512, 512))
  assert_eq(wrong, [])
}
