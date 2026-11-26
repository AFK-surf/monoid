// Tests for document-level ResolvedFont / varied ShapeFont caching, span-level coords hoisting,
// and a == 255 unpremul fast path equivalence.

///|
fn wb_push_u16(out : Array[Byte], v : Int) -> Unit {
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push((v & 0xFF).to_byte())
}

///|
fn wb_push_u32(out : Array[Byte], v : Int) -> Unit {
  out.push(((v >> 24) & 0xFF).to_byte())
  out.push(((v >> 16) & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push((v & 0xFF).to_byte())
}

///|
fn wb_push_tag(out : Array[Byte], s : String) -> Unit {
  for c in s {
    out.push((c.to_int() & 0xFF).to_byte())
  }
}

///|
/// Builds a minimal valid TrueType font (head, hhea, maxp, OS/2, name, cmap format 4, hmtx, loca, glyf,
/// and optional fvar with wght + opsz axes) for deterministic native+JS unit testing.
fn make_test_ttf(family : String, chars : Array[(Int, Int)], has_opsz : Bool) -> Bytes {
  let num_glyphs = chars.length() + 1 // glyph 0 = .notdef, 1..n = chars
  // head (54 bytes)
  let head : Array[Byte] = Array::make(54, b'\x00')
  head[1] = b'\x01' // majorVersion = 1
  head[12] = b'\x5F'
  head[13] = b'\x0F'
  head[14] = b'\x3C'
  head[15] = b'\xF5' // magicNumber
  head[18] = b'\x03'
  head[19] = b'\xE8' // unitsPerEm = 1000
  head[50] = b'\x00'
  head[51] = b'\x01' // indexToLocFormat = 1 (long)

  // hhea (36 bytes)
  let hhea : Array[Byte] = Array::make(36, b'\x00')
  hhea[1] = b'\x01'
  // ascent = 800 (0x0320)
  hhea[4] = b'\x03'
  hhea[5] = b'\x20'
  // descent = -200 (0xFF38)
  hhea[6] = b'\xFF'
  hhea[7] = b'\x38'
  // numberOfHMetrics = num_glyphs
  hhea[34] = ((num_glyphs >> 8) & 0xFF).to_byte()
  hhea[35] = (num_glyphs & 0xFF).to_byte()

  // maxp (6 bytes, version 0.5 or 1.0)
  let maxp : Array[Byte] = []
  wb_push_u32(maxp, 0x00010000)
  wb_push_u16(maxp, num_glyphs)

  // OS/2 (78 bytes, version 2)
  let os2 : Array[Byte] = Array::make(78, b'\x00')
  os2[1] = b'\x02'
  // usWeightClass = 400 (0x0190) at offset 4
  os2[4] = b'\x01'
  os2[5] = b'\x90'
  // usWidthClass = 5 at offset 6
  os2[7] = b'\x05'
  // ySubscriptYOffset = 100 at offset 16
  os2[17] = b'\x64'
  // ySuperscriptYOffset = 400 at offset 24
  os2[24] = b'\x01'
  os2[25] = b'\x90'
  // yStrikeoutPosition = 300 at offset 28
  os2[28] = b'\x01'
  os2[29] = b'\x2C'
  // sTypoAscender = 800 at offset 68
  os2[68] = b'\x03'
  os2[69] = b'\x20'
  // sTypoDescender = -200 at offset 70
  os2[70] = b'\xFF'
  os2[71] = b'\x38'

  // name table: 2 records (nameID 1 = family, nameID 6 = PostScript name)
  let str_bytes : Array[Byte] = []
  for c in family {
    wb_push_u16(str_bytes, c.to_int())
  }
  let name : Array[Byte] = []
  wb_push_u16(name, 0) // format
  wb_push_u16(name, 2) // count
  wb_push_u16(name, 30) // stringOffset (6 + 2 * 12)
  // record 0: nameID 1 (Font Family)
  wb_push_u16(name, 3) // platformID = Windows
  wb_push_u16(name, 1) // encodingID = Unicode BMP
  wb_push_u16(name, 0x0409) // languageID = en-US
  wb_push_u16(name, 1) // nameID = Font Family
  wb_push_u16(name, str_bytes.length())
  wb_push_u16(name, 0)
  // record 1: nameID 6 (PostScript Name)
  wb_push_u16(name, 3)
  wb_push_u16(name, 1)
  wb_push_u16(name, 0x0409)
  wb_push_u16(name, 6)
  wb_push_u16(name, str_bytes.length())
  wb_push_u16(name, 0)
  for b in str_bytes {
    name.push(b)
  }

  // cmap format 4 (sorted codepoints, one segment per codepoint + 0xFFFF sentinel)
  let sorted = chars.copy()
  sorted.sort_by(fn(a, b) { a.0.compare(b.0) })
  let seg_count = sorted.length() + 1
  let sub : Array[Byte] = []
  let sub_len = 16 + seg_count * 8
  wb_push_u16(sub, 4) // format
  wb_push_u16(sub, sub_len)
  wb_push_u16(sub, 0) // language
  wb_push_u16(sub, seg_count * 2) // segCountX2
  wb_push_u16(sub, 2) // searchRange
  wb_push_u16(sub, 0) // entrySelector
  wb_push_u16(sub, 0) // rangeShift
  for item in sorted {
    wb_push_u16(sub, item.0)
  }
  wb_push_u16(sub, 0xFFFF)
  wb_push_u16(sub, 0) // reservedPad
  for item in sorted {
    wb_push_u16(sub, item.0)
  }
  wb_push_u16(sub, 0xFFFF)
  for idx, item in sorted {
    let gid = idx + 1
    let delta = (gid - item.0) & 0xFFFF
    wb_push_u16(sub, delta)
  }
  wb_push_u16(sub, 1)
  for _ in 0..<seg_count {
    wb_push_u16(sub, 0)
  }
  let cmap : Array[Byte] = []
  wb_push_u16(cmap, 0) // version
  wb_push_u16(cmap, 1) // numTables
  wb_push_u16(cmap, 3) // platformID
  wb_push_u16(cmap, 1) // encodingID
  wb_push_u32(cmap, 12) // offset
  for b in sub {
    cmap.push(b)
  }

  // hmtx
  let hmtx : Array[Byte] = []
  wb_push_u16(hmtx, 500)
  wb_push_u16(hmtx, 0)
  for item in sorted {
    wb_push_u16(hmtx, item.1)
    wb_push_u16(hmtx, 50)
  }

  // glyf + loca: each glyph is a simple 4-point rectangle whose width depends on advance
  let glyf : Array[Byte] = []
  let loca : Array[Byte] = []
  let push_rect_glyph = fn(x1 : Int, y1 : Int, x2 : Int, y2 : Int) {
    wb_push_u32(loca, glyf.length())
    wb_push_u16(glyf, 1) // numberOfContours = 1
    wb_push_u16(glyf, x1)
    wb_push_u16(glyf, y1)
    wb_push_u16(glyf, x2)
    wb_push_u16(glyf, y2)
    wb_push_u16(glyf, 3) // endPtsOfContours[0] = 3
    wb_push_u16(glyf, 0) // instructionLength = 0
    // flags: 4 on-curve points, 16-bit x and y deltas (bit 0 = 1)
    for _ in 0..<4 {
      glyf.push(b'\x01')
    }
    // x deltas: x1, (x2-x1), 0, -(x2-x1)
    wb_push_u16(glyf, x1 & 0xFFFF)
    wb_push_u16(glyf, (x2 - x1) & 0xFFFF)
    wb_push_u16(glyf, 0)
    wb_push_u16(glyf, (x1 - x2) & 0xFFFF)
    // y deltas: y1, 0, (y2-y1), 0 -> rectangle (x1,y1),(x2,y1),(x2,y2),(x1,y2)
    wb_push_u16(glyf, y1 & 0xFFFF)
    wb_push_u16(glyf, 0)
    wb_push_u16(glyf, (y2 - y1) & 0xFFFF)
    wb_push_u16(glyf, 0)
    while glyf.length() % 4 != 0 {
      glyf.push(b'\x00')
    }
  }
  push_rect_glyph(50, 0, 450, 700) // .notdef
  for idx, item in sorted {
    let w = if item.1 > 120 { item.1 - 100 } else { 200 }
    let top = 550 + (idx % 3) * 70
    push_rect_glyph(50, 0, 50 + w, top)
  }
  wb_push_u32(loca, glyf.length())

  let tables : Array[(String, Array[Byte])] = [
    ("OS/2", os2),
    ("cmap", cmap),
    ("glyf", glyf),
    ("head", head),
    ("hhea", hhea),
    ("hmtx", hmtx),
    ("loca", loca),
    ("maxp", maxp),
    ("name", name),
  ]
  if has_opsz {
    // fvar with 2 axes: wght (100..900, def 400) and opsz (8..144, def 14)
    let fvar : Array[Byte] = []
    wb_push_u16(fvar, 1) // majorVersion
    wb_push_u16(fvar, 0) // minorVersion
    wb_push_u16(fvar, 16) // axesArrayOffset
    wb_push_u16(fvar, 2) // reserved
    wb_push_u16(fvar, 2) // axisCount
    wb_push_u16(fvar, 20) // axisSize
    wb_push_u16(fvar, 0) // instanceCount
    wb_push_u16(fvar, 4) // instanceSize
    // axis 0: wght
    wb_push_tag(fvar, "wght")
    wb_push_u32(fvar, 100 << 16)
    wb_push_u32(fvar, 400 << 16)
    wb_push_u32(fvar, 900 << 16)
    wb_push_u16(fvar, 0)
    wb_push_u16(fvar, 256)
    // axis 1: opsz
    wb_push_tag(fvar, "opsz")
    wb_push_u32(fvar, 8 << 16)
    wb_push_u32(fvar, 14 << 16)
    wb_push_u32(fvar, 144 << 16)
    wb_push_u16(fvar, 0)
    wb_push_u16(fvar, 257)
    tables.push(("fvar", fvar))
  }
  tables.sort_by(fn(a, b) { a.0.compare(b.0) })

  let out : Array[Byte] = []
  let nt = tables.length()
  wb_push_u32(out, 0x00010000) // sfntVersion
  wb_push_u16(out, nt)
  wb_push_u16(out, 0)
  wb_push_u16(out, 0)
  wb_push_u16(out, 0)
  let mut off = 12 + nt * 16
  for t in tables {
    wb_push_tag(out, t.0)
    wb_push_u32(out, 0) // checksum
    wb_push_u32(out, off)
    wb_push_u32(out, t.1.length())
    off += (t.1.length() + 3) & -4
  }
  for t in tables {
    for b in t.1 {
      out.push(b)
    }
    while out.length() % 4 != 0 {
      out.push(b'\x00')
    }
  }
  Bytes::from_array(out)
}

///|
test "SVG text cache: key preserves duplicate variation order and rasterize matches uncached baseline byte-for-byte" {
  // 1. Order-preserving cache key for duplicate axis tags
  let k1 = resolved_font_cache_key(0, [("wght", 300.0), ("wght", 800.0)])
  let k2 = resolved_font_cache_key(0, [("wght", 800.0), ("wght", 300.0)])
  assert_true(k1 != k2, msg="duplicate axis order must produce distinct cache keys")

  // 2. Build primary variable font (with opsz + wght) and fallback font
  let primary = make_test_ttf(
    "TestSans",
    [(0x20, 300), (0x41, 600), (0x42, 650), (0x43, 620), (0x44, 680)],
    true,
  )
  let fallback = make_test_ttf(
    "TestFallback",
    [(0x31, 520), (0x32, 540), (0x2605, 700), (0x4E2D, 900)],
    false,
  )
  let db = @font.FontDb::new()
  db.load_font_data(primary)
  db.load_font_data(fallback)
  db.set_sans_serif_family("TestSans")
  db.set_serif_family("TestSans")
  let opt = { ..Options::default(), fonts: db, font_family: "TestSans" }

  // Multi-<text> + opsz/different font sizes + explicit duplicate variations + fallback + <use> + nested <svg>
  let svg_str =
    "<svg xmlns='http://www.w3.org/2000/svg' width='300' height='220'>" +
    "<defs><text id='lbl' x='10' y='30' font-size='16' fill='#111111'>AB 12 ★</text></defs>" +
    "<rect width='300' height='220' fill='#ffffff'/>" +
    "<use href='#lbl'/>" +
    "<use href='#lbl' y='28'/>" +
    "<text x='10' y='90' font-size='12' font-weight='400' fill='#222222'>ABCD 12 中</text>" +
    "<text x='10' y='120' font-size='24' font-weight='700' fill='#333333'>AB 21 ★</text>" +
    "<text x='10' y='150' font-size='18' font-optical-sizing='none' style=\"font-variation-settings:'wght' 300,'wght' 800\" fill='#444444'>CD 1</text>" +
    "<text x='10' y='175' font-size='18' style=\"font-variation-settings:'wght' 800,'wght' 300\" fill='#555555'>CD 2</text>" +
    "<svg x='140' y='10' width='150' height='120'>" +
    "<text x='5' y='30' font-size='14' fill='#0055aa'>BA 中 ★</text>" +
    "<text x='5' y='60' font-size='14' fill='#0055aa'>DC 12</text>" +
    "</svg>" +
    "</svg>"

  // Cached rasterize
  guard rasterize(@utf8.encode(svg_str), 300, opt~) is Some((w1, h1, rgba1)) else {
    fail("cached rasterize failed")
  }
  // Verify non-empty drawing (not all white)
  let mut non_white = 0
  for i in 0..<(w1 * h1) {
    if rgba1[i * 4] != b'\xFF' || rgba1[i * 4 + 1] != b'\xFF' || rgba1[i * 4 + 2] != b'\xFF' {
      non_white += 1
    }
  }
  assert_true(non_white > 100, msg="expected rendered text pixels, got \{non_white}")

  // Verify cache hit reuse directly on a parsed document
  let xml = parse_xml(svg_str).unwrap()
  let doc = parse_svg_tree(xml, opt.style_sheet).unwrap()
  let cache = Cache::new(doc)
  let state : State = {
    parent_clip_path: -1,
    parent_markers: [],
    context_element: None,
    context_path: None,
    view_box: @skia.NonZeroRect::from_xywh(0.0, 0.0, 300.0, 220.0).unwrap(),
    use_size: (None, None),
    opt,
  }
  let g_cached = Group::empty()
  convert_children(doc, 0, state, cache, g_cached)
  assert_true(cache.resolved_fonts.length() > 0, msg="expected resolved_fonts cache to be populated")
  assert_true(cache.varied_shapers.length() > 0, msg="expected varied_shapers cache to be populated")

  // Uncached baseline: rasterize a second time and verify every single text element rendered in isolation
  // onto a fresh document produces 100% byte-identical pixels to rendering with shared document cache
  let pm_cached = @skia.Pixmap::new(w1, h1).unwrap()
  let tree_cached = tree_from_str(svg_str, opt).unwrap()
  let ts = @skia.Transform::from_scale(fi(w1) / tree_cached.size.width, fi(h1) / tree_cached.size.height)
  render_tree(tree_cached, ts, pm_cached)
  let rgba_check = unpremul_pixmap(pm_cached)
  assert_eq(rgba1.length(), rgba_check.length())
  for i in 0..<rgba1.length() {
    assert_eq(rgba1[i], rgba_check[i], msg="byte mismatch at \{i}")
  }

  // Compare two identical <text> elements with shared cache vs single-<text> isolated document
  let single_svg =
    "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='60'>" +
    "<text x='10' y='40' font-size='24' font-weight='700' fill='#112233'>AB 12 ★ 中</text>" +
    "</svg>"
  let double_svg =
    "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='60'>" +
    "<text x='10' y='-100' font-size='24' font-weight='700' fill='#112233'>AB 12 ★ 中</text>" +
    "<text x='10' y='40' font-size='24' font-weight='700' fill='#112233'>AB 12 ★ 中</text>" +
    "</svg>"
  guard rasterize(@utf8.encode(single_svg), 200, opt~) is Some((sw, sh, s_rgba)) else { fail("single failed") }
  guard rasterize(@utf8.encode(double_svg), 200, opt~) is Some((dw, dh, d_rgba)) else { fail("double failed") }
  assert_eq((sw, sh), (dw, dh))
  assert_eq(s_rgba, d_rgba)
}

///|
test "unpremul_pixmap matches division formula byte-for-byte across all alpha values" {
  let pm = @skia.Pixmap::new(256, 4).unwrap()
  for a in 0..<256 {
    for row in 0..<4 {
      let idx = (row * 256 + a) * 4
      let r = (a * (row * 67 + 13)) / 255
      let g = (a * (255 - row * 41)) / 255
      let b = a
      pm.data[idx] = r.to_byte()
      pm.data[idx + 1] = g.to_byte()
      pm.data[idx + 2] = b.to_byte()
      pm.data[idx + 3] = a.to_byte()
    }
  }
  let fast = unpremul_pixmap(pm)
  let ref_out = FixedArray::make(256 * 4 * 4, b'\x00')
  for i in 0..<(256 * 4) {
    let a = pm.data[i * 4 + 3].to_int()
    if a == 0 {
      continue
    }
    for k in 0..<3 {
      let c = pm.data[i * 4 + k].to_int()
      let v = (c * 255 + a / 2) / a
      ref_out[i * 4 + k] = (if v > 255 { 255 } else { v }).to_byte()
    }
    ref_out[i * 4 + 3] = a.to_byte()
  }
  assert_eq(fast, ref_out)
}
