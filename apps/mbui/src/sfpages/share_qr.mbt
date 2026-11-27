// Pure-MoonBit ISO/IEC 18004 QR Code encoder (Version 4, ECC Level H, 33×33) and dotted vector shape renderer.
// Encodes byte-mode URLs up to 34 UTF-8 bytes (e.g. https://still.fail, https://monoid.build) with 30% error
// correction capacity so a cleared center brand mark scans reliably at any export scale.

///|
/// Encoded square QR module matrix (`modules[row * size + col]` is `true` for dark).
pub struct ExcerptQrMatrix {
  size : Int
  modules : Array[Bool]
}

///|
let qr_v4_size : Int = 33

///|
let qr_v4_data_bytes : Int = 36

///|
let qr_v4_blocks : Int = 4

///|
let qr_v4_block_data : Int = 9

///|
let qr_v4_block_ec : Int = 16

///|
let qr_finder_size : Int = 7

///|
let qr_center_clear : Int = 7

///|
let qr_dot_radius : Double = 0.42

///|
fn qr_gf_tables() -> (Array[Int], Array[Int]) {
  let exp = Array::make(512, 0)
  let log = Array::make(256, 0)
  let mut x = 1
  for i in 0..<255 {
    exp[i] = x
    log[x] = i
    x = x << 1
    if (x & 0x100) != 0 {
      x = x ^ 0x11d
    }
  }
  for i in 255..<512 {
    exp[i] = exp[i - 255]
  }
  (exp, log)
}

///|
fn qr_gf_mul(exp : Array[Int], log : Array[Int], a : Int, b : Int) -> Int {
  if a == 0 || b == 0 {
    0
  } else {
    exp[log[a] + log[b]]
  }
}

///|
fn qr_rs_generator(exp : Array[Int], log : Array[Int], degree : Int) -> Array[Int] {
  let mut poly = [1]
  for i in 0..<degree {
    let next = Array::make(poly.length() + 1, 0)
    let factor = exp[i]
    for j in 0..<poly.length() {
      next[j] = next[j] ^ poly[j]
      next[j + 1] = next[j + 1] ^ qr_gf_mul(exp, log, poly[j], factor)
    }
    poly = next
  }
  poly
}

///|
fn qr_rs_remainder(data : Array[Int], gen : Array[Int], exp : Array[Int], log : Array[Int]) -> Array[Int] {
  let ec_len = gen.length() - 1
  let rem = Array::make(ec_len, 0)
  for d in data {
    let factor = d ^ rem[0]
    for j in 0..<(ec_len - 1) {
      rem[j] = rem[j + 1]
    }
    rem[ec_len - 1] = 0
    if factor != 0 {
      for j in 0..<ec_len {
        rem[j] = rem[j] ^ qr_gf_mul(exp, log, gen[j + 1], factor)
      }
    }
  }
  rem
}

///|
fn qr_push_bits(bits : Array[Bool], value : Int, count : Int) -> Unit {
  for i = count - 1; i >= 0; i = i - 1 {
    bits.push(((value >> i) & 1) != 0)
  }
}

///|
fn qr_encode_codewords(url : String) -> Array[Int] {
  let raw = @utf8.encode(url)
  let max_payload = qr_v4_data_bytes - 2
  let len = if raw.length() > max_payload { max_payload } else { raw.length() }
  let bits : Array[Bool] = []
  // Byte mode indicator (0100) + 8-bit length.
  qr_push_bits(bits, 4, 4)
  qr_push_bits(bits, len, 8)
  for i in 0..<len {
    qr_push_bits(bits, raw[i].to_int(), 8)
  }
  let cap_bits = qr_v4_data_bytes * 8
  let term = if cap_bits - bits.length() < 4 { cap_bits - bits.length() } else { 4 }
  for _ in 0..<term {
    bits.push(false)
  }
  while bits.length() % 8 != 0 {
    bits.push(false)
  }
  let data : Array[Int] = []
  let mut i = 0
  while i < bits.length() {
    let mut byte = 0
    for b in 0..<8 {
      byte = (byte << 1) | (if bits[i + b] { 1 } else { 0 })
    }
    data.push(byte)
    i += 8
  }
  let pads = [0xec, 0x11]
  let mut pi = 0
  while data.length() < qr_v4_data_bytes {
    data.push(pads[pi % 2])
    pi += 1
  }
  // Split into 4 identical Version 4-H blocks (9 data + 16 EC each) and interleave.
  let (exp, log) = qr_gf_tables()
  let gen = qr_rs_generator(exp, log, qr_v4_block_ec)
  let data_blocks : Array[Array[Int]] = []
  let ec_blocks : Array[Array[Int]] = []
  for b in 0..<qr_v4_blocks {
    let blk : Array[Int] = []
    for j in 0..<qr_v4_block_data {
      blk.push(data[b * qr_v4_block_data + j])
    }
    data_blocks.push(blk)
    ec_blocks.push(qr_rs_remainder(blk, gen, exp, log))
  }
  let interleaved : Array[Int] = []
  for j in 0..<qr_v4_block_data {
    for b in 0..<qr_v4_blocks {
      interleaved.push(data_blocks[b][j])
    }
  }
  for j in 0..<qr_v4_block_ec {
    for b in 0..<qr_v4_blocks {
      interleaved.push(ec_blocks[b][j])
    }
  }
  interleaved
}

///|
fn qr_set_fn(modules : Array[Bool], is_fn : Array[Bool], r : Int, c : Int, dark : Bool) -> Unit {
  if r >= 0 && r < qr_v4_size && c >= 0 && c < qr_v4_size {
    let idx = r * qr_v4_size + c
    modules[idx] = dark
    is_fn[idx] = true
  }
}

///|
fn qr_place_finder(modules : Array[Bool], is_fn : Array[Bool], top : Int, left : Int) -> Unit {
  for dr in -1..<=7 {
    for dc in -1..<=7 {
      let r = top + dr
      let c = left + dc
      if r < 0 || r >= qr_v4_size || c < 0 || c >= qr_v4_size {
        continue
      }
      let dark = dr >= 0 &&
        dr <= 6 &&
        dc >= 0 &&
        dc <= 6 &&
        (dr == 0 || dr == 6 || dc == 0 || dc == 6 || (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4))
      qr_set_fn(modules, is_fn, r, c, dark)
    }
  }
}

///|
fn qr_place_alignment(modules : Array[Bool], is_fn : Array[Bool], cr : Int, cc : Int) -> Unit {
  for dr in -2..<=2 {
    for dc in -2..<=2 {
      let dist = if dr.abs() > dc.abs() { dr.abs() } else { dc.abs() }
      qr_set_fn(modules, is_fn, cr + dr, cc + dc, dist != 1)
    }
  }
}

///|
fn qr_format_bits(mask : Int) -> Int {
  // ECC Level H = 0b10
  let data = (2 << 3) | (mask & 7)
  let mut rem = data << 10
  let poly = 0x537
  for i = 4; i >= 0; i = i - 1 {
    if ((rem >> (i + 10)) & 1) != 0 {
      rem = rem ^ (poly << i)
    }
  }
  ((data << 10) | rem) ^ 0x5412
}

///|
fn qr_place_format(modules : Array[Bool], is_fn : Array[Bool], mask : Int) -> Unit {
  let bits = qr_format_bits(mask)
  let bit_at = fn(pos : Int) -> Bool { ((bits >> pos) & 1) != 0 }
  // Copy 1 around top-left finder (bit 14 -> bit 0).
  let c1 : Array[(Int, Int)] = [
    (8, 0),
    (8, 1),
    (8, 2),
    (8, 3),
    (8, 4),
    (8, 5),
    (8, 7),
    (8, 8),
    (7, 8),
    (5, 8),
    (4, 8),
    (3, 8),
    (2, 8),
    (1, 8),
    (0, 8),
  ]
  for i in 0..<15 {
    let (r, c) = c1[i]
    qr_set_fn(modules, is_fn, r, c, bit_at(14 - i))
  }
  // Copy 2 along bottom-left (bits 14..8) and top-right (bits 7..0).
  let n = qr_v4_size
  for i in 0..<7 {
    qr_set_fn(modules, is_fn, n - 1 - i, 8, bit_at(14 - i))
  }
  for i in 0..<8 {
    qr_set_fn(modules, is_fn, 8, n - 8 + i, bit_at(7 - i))
  }
  // Fixed dark module at (4*version + 9, 8) = (25, 8).
  qr_set_fn(modules, is_fn, n - 8, 8, true)
}

///|
fn qr_mask_bit(mask : Int, r : Int, c : Int) -> Bool {
  match mask {
    0 => (r + c) % 2 == 0
    1 => r % 2 == 0
    2 => c % 3 == 0
    3 => (r + c) % 3 == 0
    4 => (r / 2 + c / 3) % 2 == 0
    5 => (r * c) % 2 + (r * c) % 3 == 0
    6 => ((r * c) % 2 + (r * c) % 3) % 2 == 0
    _ => ((r + c) % 2 + (r * c) % 3) % 2 == 0
  }
}

///|
fn qr_penalty_line(line : Array[Bool]) -> Int {
  let n = line.length()
  let mut score = 0
  let mut run = 1
  for i in 1..<n {
    if line[i] == line[i - 1] {
      run += 1
    } else {
      if run >= 5 {
        score += 3 + (run - 5)
      }
      run = 1
    }
  }
  if run >= 5 {
    score += 3 + (run - 5)
  }
  // Finder-like 1:1:3:1:1 with 4 light modules on either side.
  let pat_a = [true, false, true, true, true, false, true, false, false, false, false]
  let pat_b = [false, false, false, false, true, false, true, true, true, false, true]
  for i in 0..<=(n - 11) {
    let mut ma = true
    let mut mb = true
    for k in 0..<11 {
      if line[i + k] != pat_a[k] {
        ma = false
      }
      if line[i + k] != pat_b[k] {
        mb = false
      }
    }
    if ma {
      score += 40
    }
    if mb {
      score += 40
    }
  }
  score
}

///|
fn qr_penalty(modules : Array[Bool]) -> Int {
  let n = qr_v4_size
  let mut score = 0
  let row_buf = Array::make(n, false)
  let col_buf = Array::make(n, false)
  for i in 0..<n {
    for j in 0..<n {
      row_buf[j] = modules[i * n + j]
      col_buf[j] = modules[j * n + i]
    }
    score += qr_penalty_line(row_buf) + qr_penalty_line(col_buf)
  }
  // 2×2 same-color blocks.
  for r in 0..<(n - 1) {
    for c in 0..<(n - 1) {
      let v = modules[r * n + c]
      if v == modules[r * n + c + 1] && v == modules[(r + 1) * n + c] && v == modules[(r + 1) * n + c + 1] {
        score += 3
      }
    }
  }
  // Dark balance.
  let mut dark = 0
  for m in modules {
    if m {
      dark += 1
    }
  }
  let total = n * n
  let k = ((dark * 20 - total * 10).abs() + total - 1) / total - 1
  if k > 0 {
    score += k * 10
  }
  score
}

///|
/// Encodes `url` as a Version 4 ECC-H QR Code matrix (33×33).
pub fn encode_excerpt_qr(url : String) -> ExcerptQrMatrix {
  let n = qr_v4_size
  let codewords = qr_encode_codewords(url)
  let base_mod = Array::make(n * n, false)
  let is_fn = Array::make(n * n, false)
  qr_place_finder(base_mod, is_fn, 0, 0)
  qr_place_finder(base_mod, is_fn, 0, n - 7)
  qr_place_finder(base_mod, is_fn, n - 7, 0)
  for i in 8..<(n - 8) {
    qr_set_fn(base_mod, is_fn, 6, i, i % 2 == 0)
    qr_set_fn(base_mod, is_fn, i, 6, i % 2 == 0)
  }
  qr_place_alignment(base_mod, is_fn, 26, 26)
  // Reserve format info slots before placing data bits.
  qr_place_format(base_mod, is_fn, 0)
  // Place data + EC bits in standard zig-zag order.
  let total_bits = codewords.length() * 8
  let mut bit_idx = 0
  let mut upward = true
  let mut col = n - 1
  while col >= 1 {
    if col == 6 {
      col -= 1
    }
    for step in 0..<n {
      let row = if upward { n - 1 - step } else { step }
      for dx in 0..<2 {
        let c = col - dx
        let idx = row * n + c
        if !is_fn[idx] {
          let dark = if bit_idx < total_bits {
            ((codewords[bit_idx >> 3] >> (7 - (bit_idx & 7))) & 1) != 0
          } else {
            false
          }
          base_mod[idx] = dark
          bit_idx += 1
        }
      }
    }
    upward = !upward
    col -= 2
  }
  // Evaluate all 8 masks and pick the lowest penalty.
  let mut best_mask = 0
  let mut best_score = 0x7fffffff
  let mut best_mod = base_mod
  for mask in 0..<8 {
    let cand = base_mod.copy()
    for r in 0..<n {
      for c in 0..<n {
        let idx = r * n + c
        if !is_fn[idx] && qr_mask_bit(mask, r, c) {
          cand[idx] = !cand[idx]
        }
      }
    }
    qr_place_format(cand, is_fn.copy(), mask)
    let sc = qr_penalty(cand)
    if sc < best_score {
      best_score = sc
      best_mask = mask
      best_mod = cand
    }
  }
  ignore(best_mask)
  { size: n, modules: best_mod }
}

// ── Dotted concentric rounded-finder vector shape renderer ─────────────────

///|
fn qr_rounded_rect_pts(x : Double, y : Double, w : Double, h : Double, r : Double) -> Array[Double] {
  let rr = @sf.dmin(r, @sf.dmin(w, h) / 2.0)
  let pts : Array[Double] = []
  let pi = @math.PI
  let segs = 4
  let push_arc = fn(cx : Double, cy : Double, a0 : Double, a1 : Double) {
    for i in 0..<=segs {
      let a = a0 + (a1 - a0) * i.to_double() / segs.to_double()
      pts.push(cx + rr * @dmath.cos(a))
      pts.push(cy + rr * @dmath.sin(a))
    }
  }
  push_arc(x + w - rr, y + rr, -pi / 2.0, 0.0)
  push_arc(x + w - rr, y + h - rr, 0.0, pi / 2.0)
  push_arc(x + rr, y + h - rr, pi / 2.0, pi)
  push_arc(x + rr, y + rr, pi, 1.5 * pi)
  pts
}

///|
fn qr_circle_pts(cx : Double, cy : Double, r : Double) -> Array[Double] {
  let pts : Array[Double] = []
  let segs = 10
  let two_pi = 2.0 * @math.PI
  for i in 0..<segs {
    let a = two_pi * i.to_double() / segs.to_double()
    pts.push(cx + r * @dmath.cos(a))
    pts.push(cy + r * @dmath.sin(a))
  }
  pts
}

///|
fn qr_is_finder(size : Int, r : Int, c : Int) -> Bool {
  (r < qr_finder_size && c < qr_finder_size) ||
  (r < qr_finder_size && c >= size - qr_finder_size) ||
  (r >= size - qr_finder_size && c < qr_finder_size)
}

///|
fn qr_is_alignment(r : Int, c : Int) -> Bool {
  (r - 26).abs() <= 2 && (c - 26).abs() <= 2
}

///|
/// Renders `matrix` into `@ui.Shape` vector geometry of `side × side` points with round data dots,
/// concentric rounded finders, solid rounded alignment square, and a cleared center for a brand mark.
pub fn excerpt_qr_shapes(matrix : ExcerptQrMatrix, side : Double, color : Int64) -> Array[@ui.Shape] {
  let n = matrix.size
  let unit = side / n.to_double()
  let clear_start = (n - qr_center_clear) / 2
  let clear_end = clear_start + qr_center_clear
  let in_center = fn(r : Int, c : Int) -> Bool {
    r >= clear_start && r < clear_end && c >= clear_start && c < clear_end
  }
  let dot_outlines : Array[(Array[Double], Bool)] = []
  let dot_r = qr_dot_radius * unit
  for r in 0..<n {
    for c in 0..<n {
      if !matrix.modules[r * n + c] {
        continue
      }
      if qr_is_finder(n, r, c) || qr_is_alignment(r, c) || in_center(r, c) {
        continue
      }
      let cx = (c.to_double() + 0.5) * unit
      let cy = (r.to_double() + 0.5) * unit
      dot_outlines.push((qr_circle_pts(cx, cy, dot_r), true))
    }
  }
  let finder_outlines : Array[(Array[Double], Bool)] = []
  let corners : Array[(Int, Int)] = [(0, 0), (n - qr_finder_size, 0), (0, n - qr_finder_size)]
  for corner in corners {
    let fx = corner.0.to_double() * unit
    let fy = corner.1.to_double() * unit
    finder_outlines.push((qr_rounded_rect_pts(fx, fy, 7.0 * unit, 7.0 * unit, 2.0 * unit), true))
    finder_outlines.push((qr_rounded_rect_pts(fx + unit, fy + unit, 5.0 * unit, 5.0 * unit, 1.4 * unit), true))
    finder_outlines.push((qr_rounded_rect_pts(fx + 2.0 * unit, fy + 2.0 * unit, 3.0 * unit, 3.0 * unit, 0.9 * unit), true))
  }
  // Solid rounded alignment pattern at (26, 26) so scanners lock accurately.
  let ax = 24.0 * unit
  let ay = 24.0 * unit
  finder_outlines.push((qr_rounded_rect_pts(ax, ay, 5.0 * unit, 5.0 * unit, 1.4 * unit), true))
  finder_outlines.push((qr_rounded_rect_pts(ax + unit, ay + unit, 3.0 * unit, 3.0 * unit, 0.9 * unit), true))
  finder_outlines.push((qr_rounded_rect_pts(ax + 2.0 * unit, ay + 2.0 * unit, 1.0 * unit, 1.0 * unit, 0.5 * unit), true))
  [
    @ui.shape_of(dot_outlines, fill=color),
    @ui.shape_of(finder_outlines, fill=color, even_odd=true),
  ]
}
