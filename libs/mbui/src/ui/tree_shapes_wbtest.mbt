// A node of the window's tree's shapes (View::shapes): drawn where it is, in its tint (View::tint), their bands worked
// out once for the outlines said and their pieces put after each frame's wherever the node's block is composed again.

///|
test "a node's shapes: drawn where it is, the same as composed again in a later frame; another tint draws them in it, their bands as they were" {
  let tint = @signals.signal(0xFF0000FFL, same=fn(a, b) { a == b })
  let shapes = [shape_of([([2.0, 2.0, 18.0, 2.0, 18.0, 18.0, 2.0, 18.0], true)], fill=0x000000FFL)]
  // (another node's shapes, drawn before it once shown: their pieces before its own in the frame)
  let before = @signals.signal(false, same=fn(a, b) { a == b })
  let id : Ref[@view.NodeId?] = Ref(None)
  let t = Tester::new(fn(_c) {  })
  set_view_app(fn(root) {
    root.show(fn() { before.get() }, fn(b) {
      b.over(Is(true)).shapes(Is([shape_of([([0.0, 0.0, 20.0, 0.0, 0.0, 20.0], true)], fill=0x0000FFFFL)])) |> ignore
    })
    root.box(fn(n) {
      id.val = Some(n.id())
      n.offset(Is((100.0, 100.0))).width(Is(Some(20.0))).height(Is(Some(20.0))).shapes(Is(shapes)).tint(By(fn() { tint.get() }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let colours = fn() { t.drawn_shapes().filter(fn(s) { s.0 >= 100.0 }).map(fn(s) { s.5 }) }
  assert_true(colours().length() > 0 && colours().all(fn(c) { c == 0xFF0000FFL }))
  let covered = t.shape_cover(110.0, 110.0)
  assert_true(covered > 0.9, msg="\{covered}")
  let bands = view_shape_bands.get(id.val.unwrap()).unwrap()
  // a later frame, another node's shapes drawn before it: its block composed again, its pieces where its bands say
  before.set(true)
  t.frame_at(t.time() + frame_period_default)
  // (each band's pieces its own: no two bands' the same pieces)
  let c = g()
  let ranges : Array[(Int, Int)] = []
  for k in 0..<c.ninst {
    if c.inst[k * inst_size + 5] == 11.0 {
      ranges.push((c.inst[k * inst_size + 12].to_int(), c.inst[k * inst_size + 13].to_int()))
    }
  }
  assert_true(ranges.length() >= 2)
  for i in 0..<ranges.length() {
    for j in (i + 1)..<ranges.length() {
      let (a0, an) = ranges[i]
      let (b0, bn) = ranges[j]
      assert_true(a0 + an <= b0 || b0 + bn <= a0, msg="\{Repr(ranges)}")
    }
  }
  assert_eq(t.shape_cover(110.0, 110.0), covered)
  // another tint: drawn in it, the same bands
  tint.set(0x00FF00FFL)
  t.frame_at(t.time() + frame_period_default)
  assert_true(colours().all(fn(c) { c == 0x00FF00FFL }))
  assert_true(physical_equal(view_shape_bands.get(id.val.unwrap()).unwrap(), bands))
  assert_eq(t.shape_cover(110.0, 110.0), covered)
}

///|
test "a node with shapes alone beside the one old view, the whole window: that old view is not all the tree draws while it has them" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let mark = [shape_of([([2.0, 2.0, 18.0, 2.0, 18.0, 18.0, 2.0, 18.0], true)], fill=0x000000FFL)]
  let t = Tester::new(fn(_c) {  })
  set_view_app(fn(root) {
    old(root, fn(c) { c.box(w=Fill(1.0), h=Fill(1.0), fn() {  }) |> ignore }).grow(Is(1.0)) |> ignore
    root.box(fn(n) {
      n
      .over(Is(true))
      .offset(Is((100.0, 100.0)))
      .width(Is(Some(20.0)))
      .height(Is(Some(20.0)))
      .shapes(By(fn() { if on.get() { mark } else { [] } }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let seen = fn() { (old_whole.val, t.drawn_shapes().length() > 0) }
  assert_eq(seen(), (false, true))
  on.set(false)
  t.frame_at(t.time() + frame_period_default)
  assert_eq(seen(), (true, false))
  on.set(true)
  t.frame_at(t.time() + frame_period_default)
  assert_eq(seen(), (false, true))
}

///|
test "shape_band_made bucketed bands match O(B*S) reference and large outlines skip shape_bands_known" {
  // Reference O(B*S) implementation matching the original scan
  let ref_bands = fn(
    outlines : Array[(Array[Double], Bool)],
    fill : Bool,
    hw : Double,
    even_odd : Bool,
  ) -> Array[ShapeBand] {
    let out = []
    let segs : Array[Double] = []
    for o in outlines {
      let (pts, closed) = o
      let n = pts.length() / 2
      if n == 0 || (fill && n < 2) {
        continue
      }
      if n == 1 {
        segs.push(pts[0])
        segs.push(pts[1])
        segs.push(pts[0])
        segs.push(pts[1])
        continue
      }
      for k in 0..<(n - 1) {
        segs.push(pts[2 * k])
        segs.push(pts[2 * k + 1])
        segs.push(pts[2 * k + 2])
        segs.push(pts[2 * k + 3])
      }
      if fill || closed {
        segs.push(pts[2 * n - 2])
        segs.push(pts[2 * n - 1])
        segs.push(pts[0])
        segs.push(pts[1])
      }
    }
    let count = segs.length() / 4
    if count == 0 {
      return out
    }
    let m = hw + 1.0
    let mut y0 = 1.0e18
    let mut y1 = -1.0e18
    for k in 0..<count {
      y0 = dmin(y0, dmin(segs[4 * k + 1], segs[4 * k + 3]))
      y1 = dmax(y1, dmax(segs[4 * k + 1], segs[4 * k + 3]))
    }
    y0 = y0 - m
    y1 = y1 + m
    let mut b0 = y0
    while b0 < y1 {
      let b1 = dmin(b0 + shape_band, y1)
      let mut x0 = 1.0e18
      let mut x1 = -1.0e18
      let mine : Array[Int] = []
      for k in 0..<count {
        let ya = dmin(segs[4 * k + 1], segs[4 * k + 3])
        let yb = dmax(segs[4 * k + 1], segs[4 * k + 3])
        if yb >= b0 - m && ya <= b1 + m {
          mine.push(k)
          x0 = dmin(x0, dmin(segs[4 * k], segs[4 * k + 2]))
          x1 = dmax(x1, dmax(segs[4 * k], segs[4 * k + 2]))
        }
      }
      if mine.length() > 0 {
        let bx = x0 - m
        let bw = x1 - x0 + 2.0 * m
        let bh = b1 - b0
        let pieces : Array[Double] = []
        for k in mine {
          pieces.push((segs[4 * k] - bx) / bw)
          pieces.push((segs[4 * k + 1] - b0) / bh)
          pieces.push((segs[4 * k + 2] - bx) / bw)
          pieces.push((segs[4 * k + 3] - b0) / bh)
        }
        out.push({ x: bx, y: b0, w: bw, h: bh, pieces, even_odd: fill && even_odd })
      }
      b0 = b1
    }
    out
  }
  let poly : Array[Double] = []
  for i in 0..<45 {
    let x = i.to_double() * 5.5
    let y = 12.0 + (i % 7).to_double() * 9.3
    poly.push(x)
    poly.push(y)
  }
  let outlines = [(poly, true), ([30.0, 4.0], false)]
  for cfg in [(true, 0.0, false), (true, 0.0, true), (false, 1.5, false)] {
    let (fill, hw, eo) = cfg
    let got = shape_band_made(outlines, fill, hw, eo)
    let want = ref_bands(outlines, fill, hw, eo)
    assert_eq(got.length(), want.length())
    for i in 0..<got.length() {
      assert_eq(got[i].x, want[i].x)
      assert_eq(got[i].y, want[i].y)
      assert_eq(got[i].w, want[i].w)
      assert_eq(got[i].h, want[i].h)
      assert_eq(got[i].even_odd, want[i].even_odd)
      assert_eq(got[i].pieces, want[i].pieces)
    }
  }
  // >32 segments bypasses global shape_bands_known cache
  let before_len = shape_bands_known.length()
  ignore(shape_band_of(outlines, true, 0.0, false))
  assert_eq(shape_bands_known.length(), before_len)
}

///|
test "View::rects emits native kind 0 instances with 4-corner radii under shapes and lines" {
  let t = Tester::new(fn(_c) {  })
  set_view_app(fn(root) {
    root.box(fn(n) {
      n
      .offset(Is((20.0, 30.0)))
      .width(Is(Some(100.0)))
      .height(Is(Some(80.0)))
      .rects(
        Is([
          rect_of(4.0, 6.0, 12.0, 24.0, color=0x22AA44FFL, corners=(3.0, 3.0, 0.0, 0.0)),
          rect_of(20.0, 30.0, 10.0, 18.0, color=0xCC332280L, corners=(0.0, 0.0, 2.5, 2.5)),
        ]),
      )
      .shapes(Is([shape_of([([0.0, 0.0, 10.0, 0.0, 10.0, 10.0], true)], fill=0x112233FFL)]))
      .lines(Is([line([(0.0, 40.0), (100.0, 40.0)], width=2.0, color=0x000000FFL)]))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let insts = t.drawn_instances()
  let mut r0_idx = -1
  let mut r1_idx = -1
  let mut first_shape = -1
  let mut first_line = -1
  for i, ins in insts {
    if ins[5] == 0.0 && (ins[0] - 24.0).abs() < 0.01 && (ins[1] - 36.0).abs() < 0.01 {
      r0_idx = i
      assert_eq(ins[2], 12.0)
      assert_eq(ins[3], 24.0)
      assert_eq(ins[4], 3.0)
      assert_eq(ins[36], 3.0)
      assert_eq(ins[37], 3.0)
      assert_eq(ins[38], 0.0)
      assert_eq(ins[39], 0.0)
    } else if ins[5] == 0.0 && (ins[0] - 40.0).abs() < 0.01 && (ins[1] - 60.0).abs() < 0.01 {
      r1_idx = i
      assert_eq(ins[2], 10.0)
      assert_eq(ins[3], 18.0)
      assert_eq(ins[4], 2.5)
      assert_eq(ins[36], 0.0)
      assert_eq(ins[37], 0.0)
      assert_eq(ins[38], 2.5)
      assert_eq(ins[39], 2.5)
    } else if ins[5] == 11.0 && first_shape < 0 {
      first_shape = i
    } else if ins[5] == 10.0 && first_line < 0 {
      first_line = i
    }
  }
  assert_true(r0_idx >= 0 && r1_idx > r0_idx)
  assert_true(first_shape > r1_idx && first_line > first_shape)
}
