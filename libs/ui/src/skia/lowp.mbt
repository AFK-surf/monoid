// tiny-skia's low precision pipeline: 16 pixels at a time in u16 lanes holding 0..=255,
// wrapping as Rust's u16 does in release. Where Rust keeps two float vectors in the bits of the u16 registers (split
// and join: x in r and g, y in b and a) they are kept as floats beside them.
// Optimized with module-level scratch buffers, inlined blend stages (zero closures),
// and direct horizontal scanline fast paths for common 2D canvas solid/AA/mask fills.
// Invariant: module-level scratch buffers (`lowp_r`..`lowp_mask_c`) rely on single-threaded,
// non-reentrant execution of `lowp_start_generic` and every stage writing all lanes/channels it reads.

///|
let lowp_r : FixedArray[Int] = FixedArray::make(16, 0)

///|
let lowp_g : FixedArray[Int] = FixedArray::make(16, 0)

///|
let lowp_b : FixedArray[Int] = FixedArray::make(16, 0)

///|
let lowp_a : FixedArray[Int] = FixedArray::make(16, 0)

///|
let lowp_dr : FixedArray[Int] = FixedArray::make(16, 0)

///|
let lowp_dg : FixedArray[Int] = FixedArray::make(16, 0)

///|
let lowp_db : FixedArray[Int] = FixedArray::make(16, 0)

///|
let lowp_da : FixedArray[Int] = FixedArray::make(16, 0)

///|
let lowp_fx : FixedArray[Float] = FixedArray::make(16, 0.0)

///|
let lowp_fy : FixedArray[Float] = FixedArray::make(16, 0.0)

///|
let lowp_mask_c : FixedArray[Int] = FixedArray::make(16, 0)

///|
priv struct LowP {
  r : FixedArray[Int]
  g : FixedArray[Int]
  b : FixedArray[Int]
  a : FixedArray[Int]
  dr : FixedArray[Int]
  dg : FixedArray[Int]
  db : FixedArray[Int]
  da : FixedArray[Int]
  /// the floats in r and g, in b and a
  fx : FixedArray[Float]
  fy : FixedArray[Float]
  mut tail : Int
  mut dx : Int
  mut dy : Int
  ctx : Context
  mask_ctx : MaskCtx
  aa_mask_ctx : AAMaskCtx
  dst : SubPixmap
}

///|
fn lowp_start_generic(
  stages : Array[Stage],
  rect : ScreenIntRect,
  aa_mask_ctx : AAMaskCtx,
  mask_ctx : MaskCtx,
  ctx : Context,
  dst : SubPixmap,
) -> Unit {
  let p : LowP = {
    r: lowp_r,
    g: lowp_g,
    b: lowp_b,
    a: lowp_a,
    dr: lowp_dr,
    dg: lowp_dg,
    db: lowp_db,
    da: lowp_da,
    fx: lowp_fx,
    fy: lowp_fy,
    tail: 0,
    dx: 0,
    dy: 0,
    ctx,
    mask_ctx,
    aa_mask_ctx,
    dst,
  }
  for y in rect.y..<rect.bottom() {
    let mut x = rect.x
    let end = rect.right()
    while x + 16 <= end {
      p.dx = x
      p.dy = y
      p.tail = 16
      p.run(stages)
      x += 16
    }
    if x != end {
      p.dx = x
      p.dy = y
      p.tail = end - x
      p.run(stages)
    }
  }
}

///|
fn lowp_start(
  stages : Array[Stage],
  rect : ScreenIntRect,
  aa_mask_ctx : AAMaskCtx,
  mask_ctx : MaskCtx,
  ctx : Context,
  dst : SubPixmap,
) -> Unit {
  let slen = stages.length()
  let rx = rect.x
  let rw = rect.width
  let ry = rect.y
  let rbot = rect.bottom()
  let data = dst.data

  if slen == 2 {
    match (stages[0], stages[1]) {
      (UniformColor, Store) => {
        let (r, g, b, a) = ctx.uniform_rgba
        let rb = (r & 0xFF).to_byte()
        let gb = (g & 0xFF).to_byte()
        let bb = (b & 0xFF).to_byte()
        let ab = (a & 0xFF).to_byte()
        let mut y = ry
        while y < rbot {
          let mut o = dst.offset_at(rx, y) * 4
          let end_o = o + rw * 4
          while o < end_o {
            data[o] = rb
            data[o + 1] = gb
            data[o + 2] = bb
            data[o + 3] = ab
            o += 4
          }
          y += 1
        }
        return
      }
      (UniformColor, SourceOverRgba) => {
        let (r, g, b, a) = ctx.uniform_rgba
        if a == 0 && r == 0 && g == 0 && b == 0 {
          return
        }
        if a == 255 {
          let rb = (r & 0xFF).to_byte()
          let gb = (g & 0xFF).to_byte()
          let bb = (b & 0xFF).to_byte()
          let ab = (255).to_byte()
          let mut y = ry
          while y < rbot {
            let mut o = dst.offset_at(rx, y) * 4
            let end_o = o + rw * 4
            while o < end_o {
              data[o] = rb
              data[o + 1] = gb
              data[o + 2] = bb
              data[o + 3] = ab
              o += 4
            }
            y += 1
          }
          return
        }
        let ia = inv255(a)
        let mut y = ry
        while y < rbot {
          let mut o = dst.offset_at(rx, y) * 4
          let end_o = o + rw * 4
          while o < end_o {
            data[o] = (w16(r + div255(mul16(data[o].to_int(), ia))) & 0xFF).to_byte()
            data[o + 1] = (w16(g + div255(mul16(data[o + 1].to_int(), ia))) & 0xFF).to_byte()
            data[o + 2] = (w16(b + div255(mul16(data[o + 2].to_int(), ia))) & 0xFF).to_byte()
            data[o + 3] = (w16(a + div255(mul16(data[o + 3].to_int(), ia))) & 0xFF).to_byte()
            o += 4
          }
          y += 1
        }
        return
      }
      (UniformColor, StoreU8) => {
        let ab = (ctx.uniform_rgba.3 & 0xFF).to_byte()
        let mut y = ry
        while y < rbot {
          let mut o = dst.offset_at(rx, y)
          let end_o = o + rw
          while o < end_o {
            data[o] = ab
            o += 1
          }
          y += 1
        }
        return
      }
      _ => ()
    }
  } else if slen == 4 {
    match (stages[0], stages[1], stages[2], stages[3]) {
      (UniformColor, LoadDestinationU8, Lerp1Float, StoreU8) => {
        let a = ctx.uniform_rgba.3
        let c = f2u16(ctx.current_coverage * 255.0 + 0.5)
        let ic = inv255(c)
        let ac = mul16(a, c)
        let mut y = ry
        while y < rbot {
          let mut o = dst.offset_at(rx, y)
          let end_o = o + rw
          while o < end_o {
            let da = data[o].to_int()
            data[o] = (div255(w16(mul16(da, ic) + ac)) & 0xFF).to_byte()
            o += 1
          }
          y += 1
        }
        return
      }
      (UniformColor, LoadDestination, Lerp1Float, Store) => {
        let (r, g, b, a) = ctx.uniform_rgba
        let c = f2u16(ctx.current_coverage * 255.0 + 0.5)
        let ic = inv255(c)
        let rc = mul16(r, c)
        let gc = mul16(g, c)
        let bc = mul16(b, c)
        let ac = mul16(a, c)
        let mut y = ry
        while y < rbot {
          let mut o = dst.offset_at(rx, y) * 4
          let end_o = o + rw * 4
          while o < end_o {
            data[o] = (div255(w16(mul16(data[o].to_int(), ic) + rc)) & 0xFF).to_byte()
            data[o + 1] = (div255(w16(mul16(data[o + 1].to_int(), ic) + gc)) & 0xFF).to_byte()
            data[o + 2] = (div255(w16(mul16(data[o + 2].to_int(), ic) + bc)) & 0xFF).to_byte()
            data[o + 3] = (div255(w16(mul16(data[o + 3].to_int(), ic) + ac)) & 0xFF).to_byte()
            o += 4
          }
          y += 1
        }
        return
      }
      (UniformColor, LoadDestination, LerpU8, Store) => {
        let (r, g, b, a) = ctx.uniform_rgba
        let end = rect.right()
        let mut y = ry
        while y < rbot {
          let mut x = rx
          while x < end {
            let tail = if x + 16 <= end { 16 } else { end - x }
            let (d0, d1) = aa_mask_ctx.copy_at_xy(x, y, tail)
            let o = dst.offset_at(x, y) * 4
            let mut i = 0
            while i < tail {
              let c = if i == 0 { d0 } else if i == 1 { d1 } else { 0 }
              if c != 0 {
                let ic = inv255(c)
                let p = o + i * 4
                data[p] = (div255(w16(mul16(data[p].to_int(), ic) + mul16(r, c))) & 0xFF).to_byte()
                data[p + 1] = (div255(w16(mul16(data[p + 1].to_int(), ic) + mul16(g, c))) & 0xFF).to_byte()
                data[p + 2] = (div255(w16(mul16(data[p + 2].to_int(), ic) + mul16(b, c))) & 0xFF).to_byte()
                data[p + 3] = (div255(w16(mul16(data[p + 3].to_int(), ic) + mul16(a, c))) & 0xFF).to_byte()
              }
              i += 1
            }
            x += tail
          }
          y += 1
        }
        return
      }
      (UniformColor, LoadDestinationU8, LerpU8, StoreU8) => {
        let a = ctx.uniform_rgba.3
        let end = rect.right()
        let mut y = ry
        while y < rbot {
          let mut x = rx
          while x < end {
            let tail = if x + 16 <= end { 16 } else { end - x }
            let (d0, d1) = aa_mask_ctx.copy_at_xy(x, y, tail)
            let o = dst.offset_at(x, y)
            let mut i = 0
            while i < tail {
              let c = if i == 0 { d0 } else if i == 1 { d1 } else { 0 }
              if c != 0 {
                let ic = inv255(c)
                let da = data[o + i].to_int()
                data[o + i] = (div255(w16(mul16(da, ic) + mul16(a, c))) & 0xFF).to_byte()
              }
              i += 1
            }
            x += tail
          }
          y += 1
        }
        return
      }
      _ => ()
    }
  } else if slen == 5 {
    match (stages[0], stages[1], stages[2], stages[3], stages[4]) {
      (UniformColor, Scale1Float, LoadDestination, StSourceOver, Store) => {
        let (r, g, b, a) = ctx.uniform_rgba
        let c = f2u16(ctx.current_coverage * 255.0 + 0.5)
        let sr = div255(mul16(r, c))
        let sg = div255(mul16(g, c))
        let sb = div255(mul16(b, c))
        let sa = div255(mul16(a, c))
        if sa == 0 && sr == 0 && sg == 0 && sb == 0 {
          return
        }
        if sa == 255 {
          let rb = (sr & 0xFF).to_byte()
          let gb = (sg & 0xFF).to_byte()
          let bb = (sb & 0xFF).to_byte()
          let ab = (255).to_byte()
          let mut y = ry
          while y < rbot {
            let mut o = dst.offset_at(rx, y) * 4
            let end_o = o + rw * 4
            while o < end_o {
              data[o] = rb
              data[o + 1] = gb
              data[o + 2] = bb
              data[o + 3] = ab
              o += 4
            }
            y += 1
          }
          return
        }
        let ia = inv255(sa)
        let mut y = ry
        while y < rbot {
          let mut o = dst.offset_at(rx, y) * 4
          let end_o = o + rw * 4
          while o < end_o {
            data[o] = (w16(sr + div255(mul16(data[o].to_int(), ia))) & 0xFF).to_byte()
            data[o + 1] = (w16(sg + div255(mul16(data[o + 1].to_int(), ia))) & 0xFF).to_byte()
            data[o + 2] = (w16(sb + div255(mul16(data[o + 2].to_int(), ia))) & 0xFF).to_byte()
            data[o + 3] = (w16(sa + div255(mul16(data[o + 3].to_int(), ia))) & 0xFF).to_byte()
            o += 4
          }
          y += 1
        }
        return
      }
      (UniformColor, LoadDestination, StSourceOver, Lerp1Float, Store) => {
        let (r, g, b, a) = ctx.uniform_rgba
        let c = f2u16(ctx.current_coverage * 255.0 + 0.5)
        let ic = inv255(c)
        let ia = inv255(a)
        let mut y = ry
        while y < rbot {
          let mut o = dst.offset_at(rx, y) * 4
          let end_o = o + rw * 4
          while o < end_o {
            let dr = data[o].to_int()
            let dg = data[o + 1].to_int()
            let db = data[o + 2].to_int()
            let da = data[o + 3].to_int()
            let or_ = w16(r + div255(mul16(dr, ia)))
            let og = w16(g + div255(mul16(dg, ia)))
            let ob = w16(b + div255(mul16(db, ia)))
            let oa = w16(a + div255(mul16(da, ia)))
            data[o] = (div255(w16(mul16(dr, ic) + mul16(or_, c))) & 0xFF).to_byte()
            data[o + 1] = (div255(w16(mul16(dg, ic) + mul16(og, c))) & 0xFF).to_byte()
            data[o + 2] = (div255(w16(mul16(db, ic) + mul16(ob, c))) & 0xFF).to_byte()
            data[o + 3] = (div255(w16(mul16(da, ic) + mul16(oa, c))) & 0xFF).to_byte()
            o += 4
          }
          y += 1
        }
        return
      }
      (UniformColor, ScaleU8, LoadDestination, StSourceOver, Store) => {
        let (r, g, b, a) = ctx.uniform_rgba
        let end = rect.right()
        let mut y = ry
        while y < rbot {
          let mut x = rx
          while x < end {
            let tail = if x + 16 <= end { 16 } else { end - x }
            let (d0, d1) = aa_mask_ctx.copy_at_xy(x, y, tail)
            let o = dst.offset_at(x, y) * 4
            let mut i = 0
            while i < tail {
              let c = if i == 0 { d0 } else if i == 1 { d1 } else { 0 }
              if c != 0 {
                let sr = div255(mul16(r, c))
                let sg = div255(mul16(g, c))
                let sb = div255(mul16(b, c))
                let sa = div255(mul16(a, c))
                let ia = inv255(sa)
                let p = o + i * 4
                data[p] = (w16(sr + div255(mul16(data[p].to_int(), ia))) & 0xFF).to_byte()
                data[p + 1] = (w16(sg + div255(mul16(data[p + 1].to_int(), ia))) & 0xFF).to_byte()
                data[p + 2] = (w16(sb + div255(mul16(data[p + 2].to_int(), ia))) & 0xFF).to_byte()
                data[p + 3] = (w16(sa + div255(mul16(data[p + 3].to_int(), ia))) & 0xFF).to_byte()
              }
              i += 1
            }
            x += tail
          }
          y += 1
        }
        return
      }
      _ => ()
    }
  }
  lowp_start_generic(stages, rect, aa_mask_ctx, mask_ctx, ctx, dst)
}

///|
fn LowP::run(self : LowP, stages : Array[Stage]) -> Unit {
  for s in stages {
    if !self.stage(s) {
      return
    }
  }
}

///|
fn w16(v : Int) -> Int {
  v & 0xFFFF
}

///|
fn div255(v : Int) -> Int {
  w16(w16(v + 255) >> 8)
}

///|
fn inv255(v : Int) -> Int {
  w16(255 - v)
}

///|
fn mul16(a : Int, b : Int) -> Int {
  w16(a * b)
}

///|
fn lerp16(from : Int, to : Int, t : Int) -> Int {
  div255(w16(mul16(from, inv255(t)) + mul16(to, t)))
}

///|
fn LowP::stage(self : LowP, s : Stage) -> Bool {
  let p = self
  match s {
    MoveDestinationToSource =>
      for i in 0..<16 {
        p.r[i] = p.dr[i]
        p.g[i] = p.dg[i]
        p.b[i] = p.db[i]
        p.a[i] = p.da[i]
      }
    Premultiply =>
      for i in 0..<16 {
        p.r[i] = div255(mul16(p.r[i], p.a[i]))
        p.g[i] = div255(mul16(p.g[i], p.a[i]))
        p.b[i] = div255(mul16(p.b[i], p.a[i]))
      }
    UniformColor => {
      let (r, g, b, a) = p.ctx.uniform_rgba
      for i in 0..<16 {
        p.r[i] = r
        p.g[i] = g
        p.b[i] = b
        p.a[i] = a
      }
    }
    SeedShader =>
      for i in 0..<16 {
        p.fx[i] = fi(p.dx) + (fi(i) + 0.5)
        p.fy[i] = fi(p.dy) + 0.5
      }
    LoadDestination => p.load_dst()
    Store => p.store()
    LoadDestinationU8 => {
      let o = p.dst.offset_at(p.dx, p.dy)
      for i in 0..<16 {
        p.da[i] = if i < p.tail { p.dst.data[o + i].to_int() } else { 0 }
      }
    }
    StoreU8 => {
      let o = p.dst.offset_at(p.dx, p.dy)
      for i in 0..<p.tail {
        p.dst.data[o + i] = (p.a[i] & 0xFF).to_byte()
      }
    }
    LoadMaskU8 => {
      let o = p.mask_ctx.at(p.dx, p.dy)
      for i in 0..<16 {
        p.r[i] = 0
        p.g[i] = 0
        p.b[i] = 0
        p.a[i] = if i < p.tail { p.mask_ctx.data[o + i].to_int() } else { 0 }
      }
    }
    MaskU8 => {
      let o = p.mask_ctx.at(p.dx, p.dy)
      let mut all_zero = true
      for i in 0..<16 {
        let v = if i < p.tail { p.mask_ctx.data[o + i].to_int() } else { 0 }
        lowp_mask_c[i] = v
        if v != 0 {
          all_zero = false
        }
      }
      if all_zero {
        return false
      }
      for i in 0..<16 {
        let ci = lowp_mask_c[i]
        p.r[i] = div255(mul16(p.r[i], ci))
        p.g[i] = div255(mul16(p.g[i], ci))
        p.b[i] = div255(mul16(p.b[i], ci))
        p.a[i] = div255(mul16(p.a[i], ci))
      }
    }
    ScaleU8 => {
      let (d0, d1) = p.aa_mask_ctx.copy_at_xy(p.dx, p.dy, p.tail)
      for i in 0..<16 {
        let c = if i == 0 { d0 } else if i == 1 { d1 } else { 0 }
        p.r[i] = div255(mul16(p.r[i], c))
        p.g[i] = div255(mul16(p.g[i], c))
        p.b[i] = div255(mul16(p.b[i], c))
        p.a[i] = div255(mul16(p.a[i], c))
      }
    }
    LerpU8 => {
      let (d0, d1) = p.aa_mask_ctx.copy_at_xy(p.dx, p.dy, p.tail)
      for i in 0..<16 {
        let c = if i == 0 { d0 } else if i == 1 { d1 } else { 0 }
        p.r[i] = lerp16(p.dr[i], p.r[i], c)
        p.g[i] = lerp16(p.dg[i], p.g[i], c)
        p.b[i] = lerp16(p.db[i], p.b[i], c)
        p.a[i] = lerp16(p.da[i], p.a[i], c)
      }
    }
    Scale1Float => {
      let c = f2u16(p.ctx.current_coverage * 255.0 + 0.5)
      for i in 0..<16 {
        p.r[i] = div255(mul16(p.r[i], c))
        p.g[i] = div255(mul16(p.g[i], c))
        p.b[i] = div255(mul16(p.b[i], c))
        p.a[i] = div255(mul16(p.a[i], c))
      }
    }
    Lerp1Float => {
      let c = f2u16(p.ctx.current_coverage * 255.0 + 0.5)
      for i in 0..<16 {
        p.r[i] = lerp16(p.dr[i], p.r[i], c)
        p.g[i] = lerp16(p.dg[i], p.g[i], c)
        p.b[i] = lerp16(p.db[i], p.b[i], c)
        p.a[i] = lerp16(p.da[i], p.a[i], c)
      }
    }
    StClear =>
      for i in 0..<16 {
        p.r[i] = 0
        p.g[i] = 0
        p.b[i] = 0
        p.a[i] = 0
      }
    StSourceAtop =>
      for i in 0..<16 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa = inv255(sa)
        p.r[i] = div255(w16(mul16(p.r[i], da) + mul16(p.dr[i], isa)))
        p.g[i] = div255(w16(mul16(p.g[i], da) + mul16(p.dg[i], isa)))
        p.b[i] = div255(w16(mul16(p.b[i], da) + mul16(p.db[i], isa)))
        p.a[i] = div255(w16(mul16(sa, da) + mul16(da, isa)))
      }
    StDestinationAtop =>
      for i in 0..<16 {
        let sa = p.a[i]
        let da = p.da[i]
        let ida = inv255(da)
        p.r[i] = div255(w16(mul16(p.dr[i], sa) + mul16(p.r[i], ida)))
        p.g[i] = div255(w16(mul16(p.dg[i], sa) + mul16(p.g[i], ida)))
        p.b[i] = div255(w16(mul16(p.db[i], sa) + mul16(p.b[i], ida)))
        p.a[i] = div255(w16(mul16(da, sa) + mul16(sa, ida)))
      }
    StSourceIn =>
      for i in 0..<16 {
        let da = p.da[i]
        p.r[i] = div255(mul16(p.r[i], da))
        p.g[i] = div255(mul16(p.g[i], da))
        p.b[i] = div255(mul16(p.b[i], da))
        p.a[i] = div255(mul16(p.a[i], da))
      }
    StDestinationIn =>
      for i in 0..<16 {
        let sa = p.a[i]
        p.r[i] = div255(mul16(p.dr[i], sa))
        p.g[i] = div255(mul16(p.dg[i], sa))
        p.b[i] = div255(mul16(p.db[i], sa))
        p.a[i] = div255(mul16(p.da[i], sa))
      }
    StSourceOut =>
      for i in 0..<16 {
        let ida = inv255(p.da[i])
        p.r[i] = div255(mul16(p.r[i], ida))
        p.g[i] = div255(mul16(p.g[i], ida))
        p.b[i] = div255(mul16(p.b[i], ida))
        p.a[i] = div255(mul16(p.a[i], ida))
      }
    StDestinationOut =>
      for i in 0..<16 {
        let isa = inv255(p.a[i])
        p.r[i] = div255(mul16(p.dr[i], isa))
        p.g[i] = div255(mul16(p.dg[i], isa))
        p.b[i] = div255(mul16(p.db[i], isa))
        p.a[i] = div255(mul16(p.da[i], isa))
      }
    StSourceOver =>
      for i in 0..<16 {
        let isa = inv255(p.a[i])
        p.r[i] = w16(p.r[i] + div255(mul16(p.dr[i], isa)))
        p.g[i] = w16(p.g[i] + div255(mul16(p.dg[i], isa)))
        p.b[i] = w16(p.b[i] + div255(mul16(p.db[i], isa)))
        p.a[i] = w16(p.a[i] + div255(mul16(p.da[i], isa)))
      }
    StDestinationOver =>
      for i in 0..<16 {
        let ida = inv255(p.da[i])
        p.r[i] = w16(p.dr[i] + div255(mul16(p.r[i], ida)))
        p.g[i] = w16(p.dg[i] + div255(mul16(p.g[i], ida)))
        p.b[i] = w16(p.db[i] + div255(mul16(p.b[i], ida)))
        p.a[i] = w16(p.da[i] + div255(mul16(p.a[i], ida)))
      }
    StModulate =>
      for i in 0..<16 {
        p.r[i] = div255(mul16(p.r[i], p.dr[i]))
        p.g[i] = div255(mul16(p.g[i], p.dg[i]))
        p.b[i] = div255(mul16(p.b[i], p.db[i]))
        p.a[i] = div255(mul16(p.a[i], p.da[i]))
      }
    StMultiply =>
      for i in 0..<16 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa = inv255(sa)
        let ida = inv255(da)
        p.r[i] = div255(w16(w16(mul16(p.r[i], ida) + mul16(p.dr[i], isa)) + mul16(p.r[i], p.dr[i])))
        p.g[i] = div255(w16(w16(mul16(p.g[i], ida) + mul16(p.dg[i], isa)) + mul16(p.g[i], p.dg[i])))
        p.b[i] = div255(w16(w16(mul16(p.b[i], ida) + mul16(p.db[i], isa)) + mul16(p.b[i], p.db[i])))
        p.a[i] = div255(w16(w16(mul16(sa, ida) + mul16(da, isa)) + mul16(sa, da)))
      }
    StScreen =>
      for i in 0..<16 {
        p.r[i] = w16(w16(p.r[i] + p.dr[i]) - div255(mul16(p.r[i], p.dr[i])))
        p.g[i] = w16(w16(p.g[i] + p.dg[i]) - div255(mul16(p.g[i], p.dg[i])))
        p.b[i] = w16(w16(p.b[i] + p.db[i]) - div255(mul16(p.b[i], p.db[i])))
        p.a[i] = w16(w16(p.a[i] + p.da[i]) - div255(mul16(p.a[i], p.da[i])))
      }
    StXor =>
      for i in 0..<16 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa = inv255(sa)
        let ida = inv255(da)
        p.r[i] = div255(w16(mul16(p.r[i], ida) + mul16(p.dr[i], isa)))
        p.g[i] = div255(w16(mul16(p.g[i], ida) + mul16(p.dg[i], isa)))
        p.b[i] = div255(w16(mul16(p.b[i], ida) + mul16(p.db[i], isa)))
        p.a[i] = div255(w16(mul16(sa, ida) + mul16(da, isa)))
      }
    StPlus =>
      for i in 0..<16 {
        let vr = w16(p.r[i] + p.dr[i])
        let vg = w16(p.g[i] + p.dg[i])
        let vb = w16(p.b[i] + p.db[i])
        let va = w16(p.a[i] + p.da[i])
        p.r[i] = if vr < 255 { vr } else { 255 }
        p.g[i] = if vg < 255 { vg } else { 255 }
        p.b[i] = if vb < 255 { vb } else { 255 }
        p.a[i] = if va < 255 { va } else { 255 }
      }
    StDarken =>
      for i in 0..<16 {
        let sa = p.a[i]
        let da = p.da[i]
        let xr = mul16(p.r[i], da)
        let yr = mul16(p.dr[i], sa)
        p.r[i] = w16(w16(p.r[i] + p.dr[i]) - div255(if xr > yr { xr } else { yr }))
        let xg = mul16(p.g[i], da)
        let yg = mul16(p.dg[i], sa)
        p.g[i] = w16(w16(p.g[i] + p.dg[i]) - div255(if xg > yg { xg } else { yg }))
        let xb = mul16(p.b[i], da)
        let yb = mul16(p.db[i], sa)
        p.b[i] = w16(w16(p.b[i] + p.db[i]) - div255(if xb > yb { xb } else { yb }))
        p.a[i] = w16(sa + div255(mul16(da, inv255(sa))))
      }
    StLighten =>
      for i in 0..<16 {
        let sa = p.a[i]
        let da = p.da[i]
        let xr = mul16(p.r[i], da)
        let yr = mul16(p.dr[i], sa)
        p.r[i] = w16(w16(p.r[i] + p.dr[i]) - div255(if xr < yr { xr } else { yr }))
        let xg = mul16(p.g[i], da)
        let yg = mul16(p.dg[i], sa)
        p.g[i] = w16(w16(p.g[i] + p.dg[i]) - div255(if xg < yg { xg } else { yg }))
        let xb = mul16(p.b[i], da)
        let yb = mul16(p.db[i], sa)
        p.b[i] = w16(w16(p.b[i] + p.db[i]) - div255(if xb < yb { xb } else { yb }))
        p.a[i] = w16(sa + div255(mul16(da, inv255(sa))))
      }
    StExclusion =>
      for i in 0..<16 {
        let sa = p.a[i]
        let da = p.da[i]
        p.r[i] = w16(w16(p.r[i] + p.dr[i]) - mul16(2, div255(mul16(p.r[i], p.dr[i]))))
        p.g[i] = w16(w16(p.g[i] + p.dg[i]) - mul16(2, div255(mul16(p.g[i], p.dg[i]))))
        p.b[i] = w16(w16(p.b[i] + p.db[i]) - mul16(2, div255(mul16(p.b[i], p.db[i]))))
        p.a[i] = w16(sa + div255(mul16(da, inv255(sa))))
      }
    StDifference =>
      for i in 0..<16 {
        let sa = p.a[i]
        let da = p.da[i]
        let xr = mul16(p.r[i], da)
        let yr = mul16(p.dr[i], sa)
        p.r[i] = w16(w16(p.r[i] + p.dr[i]) - mul16(2, div255(if xr < yr { xr } else { yr })))
        let xg = mul16(p.g[i], da)
        let yg = mul16(p.dg[i], sa)
        p.g[i] = w16(w16(p.g[i] + p.dg[i]) - mul16(2, div255(if xg < yg { xg } else { yg })))
        let xb = mul16(p.b[i], da)
        let yb = mul16(p.db[i], sa)
        p.b[i] = w16(w16(p.b[i] + p.db[i]) - mul16(2, div255(if xb < yb { xb } else { yb })))
        p.a[i] = w16(sa + div255(mul16(da, inv255(sa))))
      }
    StHardLight =>
      for i in 0..<16 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa = inv255(sa)
        let ida = inv255(da)
        let sada = mul16(sa, da)
        let sr = p.r[i]
        let dr = p.dr[i]
        let kr = if w16(sr + sr) <= sa {
          mul16(mul16(2, sr), dr)
        } else {
          w16(sada - mul16(mul16(2, w16(sa - sr)), w16(da - dr)))
        }
        p.r[i] = div255(w16(w16(mul16(sr, ida) + mul16(dr, isa)) + kr))
        let sg = p.g[i]
        let dg = p.dg[i]
        let kg = if w16(sg + sg) <= sa {
          mul16(mul16(2, sg), dg)
        } else {
          w16(sada - mul16(mul16(2, w16(sa - sg)), w16(da - dg)))
        }
        p.g[i] = div255(w16(w16(mul16(sg, ida) + mul16(dg, isa)) + kg))
        let sb = p.b[i]
        let db = p.db[i]
        let kb = if w16(sb + sb) <= sa {
          mul16(mul16(2, sb), db)
        } else {
          w16(sada - mul16(mul16(2, w16(sa - sb)), w16(da - db)))
        }
        p.b[i] = div255(w16(w16(mul16(sb, ida) + mul16(db, isa)) + kb))
        p.a[i] = w16(sa + div255(mul16(da, isa)))
      }
    StOverlay =>
      for i in 0..<16 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa = inv255(sa)
        let ida = inv255(da)
        let sada = mul16(sa, da)
        let sr = p.r[i]
        let dr = p.dr[i]
        let kr = if w16(dr + dr) <= da {
          mul16(mul16(2, sr), dr)
        } else {
          w16(sada - mul16(mul16(2, w16(sa - sr)), w16(da - dr)))
        }
        p.r[i] = div255(w16(w16(mul16(sr, ida) + mul16(dr, isa)) + kr))
        let sg = p.g[i]
        let dg = p.dg[i]
        let kg = if w16(dg + dg) <= da {
          mul16(mul16(2, sg), dg)
        } else {
          w16(sada - mul16(mul16(2, w16(sa - sg)), w16(da - dg)))
        }
        p.g[i] = div255(w16(w16(mul16(sg, ida) + mul16(dg, isa)) + kg))
        let sb = p.b[i]
        let db = p.db[i]
        let kb = if w16(db + db) <= da {
          mul16(mul16(2, sb), db)
        } else {
          w16(sada - mul16(mul16(2, w16(sa - sb)), w16(da - db)))
        }
        p.b[i] = div255(w16(w16(mul16(sb, ida) + mul16(db, isa)) + kb))
        p.a[i] = w16(sa + div255(mul16(da, isa)))
      }
    SourceOverRgba => {
      p.load_dst()
      for i in 0..<16 {
        let ia = inv255(p.a[i])
        p.r[i] = w16(p.r[i] + div255(mul16(p.dr[i], ia)))
        p.g[i] = w16(p.g[i] + div255(mul16(p.dg[i], ia)))
        p.b[i] = w16(p.b[i] + div255(mul16(p.db[i], ia)))
        p.a[i] = w16(p.a[i] + div255(mul16(p.da[i], ia)))
      }
      p.store()
    }
    StTransform => {
      let ts = p.ctx.transform
      for i in 0..<16 {
        let x = p.fx[i]
        let y = p.fy[i]
        p.fx[i] = x * ts.sx + (y * ts.kx + ts.tx)
        p.fy[i] = x * ts.ky + (y * ts.sy + ts.ty)
      }
    }
    PadX1 => for i in 0..<16 { p.fx[i] = lnormalize(p.fx[i]) }
    ReflectX1 =>
      for i in 0..<16 {
        let x = p.fx[i]
        let f = lfloor((x - 1.0) * 0.5)
        p.fx[i] = lnormalize((x - 1.0 - (f + f) - 1.0).abs())
      }
    RepeatX1 => for i in 0..<16 { p.fx[i] = lnormalize(p.fx[i] - lfloor(p.fx[i])) }
    StGradient => {
      let g = p.ctx.gradient
      for i in 0..<16 {
        let t = p.fx[i]
        let mut idx = 0
        for k in 1..<g.len {
          if t >= g.t_values[k] {
            idx += 1
          }
        }
        let f = g.factors[idx]
        let bb = g.biases[idx]
        p.round_to_u16(i, t * f.r + bb.r, t * f.g + bb.g, t * f.b + bb.b, t * f.a + bb.a)
      }
    }
    EvenlySpaced2StopGradient => {
      let f = p.ctx.es2_factor
      let bb = p.ctx.es2_bias
      for i in 0..<16 {
        let t = p.fx[i]
        p.round_to_u16(i, t * f.r + bb.r, t * f.g + bb.g, t * f.b + bb.b, t * f.a + bb.a)
      }
    }
    XYToRadius =>
      for i in 0..<16 {
        let x = p.fx[i]
        let y = p.fy[i]
        p.fx[i] = (x * x + y * y).sqrt()
      }
    _ => @halt.saying("lowp: no such stage")
  }
  true
}

///|
fn LowP::round_to_u16(self : LowP, i : Int, rf : Float, gf : Float, bf : Float, af : Float) -> Unit {
  self.r[i] = f2u16(lnormalize(rf) * 255.0 + 0.5)
  self.g[i] = f2u16(lnormalize(gf) * 255.0 + 0.5)
  self.b[i] = f2u16(lnormalize(bf) * 255.0 + 0.5)
  self.a[i] = f2u16(af * 255.0 + 0.5)
}

///|
fn LowP::load_dst(self : LowP) -> Unit {
  let o = self.dst.offset_at(self.dx, self.dy) * 4
  let d = self.dst.data
  for i in 0..<16 {
    if i < self.tail {
      self.dr[i] = d[o + i * 4].to_int()
      self.dg[i] = d[o + i * 4 + 1].to_int()
      self.db[i] = d[o + i * 4 + 2].to_int()
      self.da[i] = d[o + i * 4 + 3].to_int()
    } else {
      self.dr[i] = 0
      self.dg[i] = 0
      self.db[i] = 0
      self.da[i] = 0
    }
  }
}

///|
fn LowP::store(self : LowP) -> Unit {
  let o = self.dst.offset_at(self.dx, self.dy) * 4
  let d = self.dst.data
  for i in 0..<self.tail {
    d[o + i * 4] = (self.r[i] & 0xFF).to_byte()
    d[o + i * 4 + 1] = (self.g[i] & 0xFF).to_byte()
    d[o + i * 4 + 2] = (self.b[i] & 0xFF).to_byte()
    d[o + i * 4 + 3] = (self.a[i] & 0xFF).to_byte()
  }
}
