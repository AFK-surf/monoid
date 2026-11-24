///|
/// A PDF of `pages` (each its dictionary's extra entries and its content stream), objects from 10, fonts 3 to 5.
fn made_pdf(pages : Array[(String, String)]) -> Bytes {
  let out = StringBuilder()
  out.write_string("%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
  let kids = StringBuilder()
  for k, _ in pages {
    kids.write_string("\{10 + 2 * k} 0 R ")
  }
  out.write_string("2 0 obj\n<< /Type /Pages /MediaBox [0 0 600 800] /Count \{pages.length()} /Kids [\{kids}] >>\nendobj\n")
  // a font of two-byte codes, its widths and what each code says
  let cmap = "/CIDInit /ProcSet findresource begin begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange 2 beginbfchar <0001> <4E2D> <0002> <2F42> endbfchar endcmap"
  out.write_string("3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /LastChar 122 /Widths [")
  for _ in 32..=122 {
    out.write_string("500 ")
  }
  out.write_string("] /Encoding /WinAnsiEncoding >>\nendobj\n")
  out.write_string("4 0 obj\n<< /Type /Font /Subtype /Type0 /Encoding /Identity-H /DescendantFonts [5 0 R] /ToUnicode 6 0 R >>\nendobj\n")
  out.write_string("5 0 obj\n<< /Type /Font /Subtype /CIDFontType2 /DW 1000 >>\nendobj\n")
  out.write_string("6 0 obj\n<< /Length \{cmap.length()} >>\nstream\n\{cmap}\nendstream\nendobj\n")
  for k, p in pages {
    let (extra, content) = p
    out.write_string(
      "\{10 + 2 * k} 0 obj\n<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents \{11 + 2 * k} 0 R \{extra} >>\nendobj\n",
    )
    out.write_string("\{11 + 2 * k} 0 obj\n<< /Length \{content.length()} >>\nstream\n\{content}\nendstream\nendobj\n")
  }
  out.write_string("trailer\n<< /Root 1 0 R >>\n%%EOF\n")
  let s = out.to_string()
  Bytes::makei(s.length(), fn(i) { s.code_unit_at(i).to_int().to_byte() })
}

///|
test "a page's words, each glyph where it is drawn" {
  let d = @pdftext.Doc::open(made_pdf([("", "BT /F1 20 Tf 100 700 Td (Hello) Tj ET")])).unwrap()
  inspect(d.pages(), content="1")
  let p = d.page(0)
  inspect(p.words(0, p.glyphs.length()), content="Hello")
  // (each 10 wide at 20 points on a page 600 wide, from 100 across)
  let e = p.glyphs[1]
  assert_true((e.x0 - 110.0 / 600.0).abs() < 1.0e-6 && (e.x1 - 120.0 / 600.0).abs() < 1.0e-6)
  assert_true(e.y0 < 100.0 / 800.0 && e.y1 > 100.0 / 800.0)
  inspect(p.readable(), content="true")
}

///|
test "two-byte codes by ToUnicode, a radical said as its ideograph" {
  let d = @pdftext.Doc::open(made_pdf([("", "BT /F2 10 Tf 50 700 Td <00010002> Tj ET")])).unwrap()
  let p = d.page(0)
  inspect(p.words(0, 2), content="中文")
}

///|
test "a heading drawn after what is under it reads first; a line that wraps joins" {
  let long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let c = "BT /F1 10 Tf 50 600 Td (\{long}) Tj ET BT /F1 10 Tf 50 588 Td (bbb) Tj ET BT /F1 20 Tf 50 700 Td (Title) Tj ET"
  let p = @pdftext.Doc::open(made_pdf([("", c)])).unwrap().page(0)
  inspect(p.words(0, p.glyphs.length()), content="Title\n\{long} bbb")
}

///|
test "two columns read one after the other" {
  let line = fn(x : Int, y : Int, s : String) { "BT /F1 10 Tf \{x} \{y} Td (\{s}) Tj ET " }
  let body = StringBuilder()
  for k in 0..<4 {
    body.write_string(line(50, 700 - 14 * k, "left left left left left left left \{k}"))
    body.write_string(line(320, 700 - 14 * k, "right right right right right ri \{k}"))
  }
  let p = @pdftext.Doc::open(made_pdf([("", body.to_string())])).unwrap().page(0)
  let all = p.words(0, p.glyphs.length())
  let last_left = all.find("left left left left left left left 3").unwrap()
  let first_right = all.find("right right right right right ri 0").unwrap()
  assert_true(last_left < first_right)
}

///|
test "a page turned: its glyphs where it is shown" {
  let d = @pdftext.Doc::open(made_pdf([("/Rotate 90", "BT /F1 20 Tf 100 700 Td (A) Tj ET")])).unwrap()
  let g = d.page(0).glyphs[0]
  // (turned a quarter clockwise: how far up it was is how far across it is, how far across how far down)
  assert_true(g.x0 < 700.0 / 800.0 && g.x1 > 700.0 / 800.0)
  assert_true((g.y0 - 100.0 / 600.0).abs() < 1.0e-6)
}

///|
test "words picked say their words, a box a line" {
  let c = "BT /F1 10 Tf 50 700 Td (one two) Tj 0 -14 Td (three) Tj ET"
  let p = @pdftext.Doc::open(made_pdf([("", c)])).unwrap().page(0)
  inspect(p.words(4, 10), content="two\nthr")
  inspect(p.rects(4, 10).length(), content="2")
  assert_eq(p.word_at(5), (4, 7))
  let at = p.glyphs[8]
  assert_eq(p.nearest((at.x0 + at.x1) / 2.0, (at.y0 + at.y1) / 2.0), Some(8))
}

///|
test "what is no PDF, or damaged, reads as nothing" {
  assert_true(@pdftext.Doc::open(b"") is None)
  assert_true(@pdftext.Doc::open(b"not a pdf at all") is None)
  assert_true(@pdftext.Doc::open(b"%PDF-1.4\n1 0 obj\n<< /Type /Catalog") is None)
  let whole = made_pdf([("", "BT /F1 10 Tf 50 700 Td (Hello) Tj ET")])
  // (cut anywhere, it opens or it does not, and what it says can be asked)
  let mut k = 0
  while k < whole.length() {
    let cut = Bytes::makei(k, fn(i) { whole[i] })
    match @pdftext.Doc::open(cut) {
      Some(d) =>
        for j in 0..<d.pages() {
          let p = d.page(j)
          ignore(p.words(0, p.glyphs.length()))
        }
      None => ()
    }
    k += 7
  }
}

///|
test "an encrypted file is not read" {
  let s = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R /Encrypt 2 0 R >>\n"
  assert_true(@pdftext.Doc::open(Bytes::makei(s.length(), fn(i) { s.code_unit_at(i).to_int().to_byte() })) is None)
}

///|
test "a standard font named with no widths: its own" {
  let s = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1000 1000] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n5 0 obj\n<< /Length 37 >>\nstream\nBT /F1 100 Tf 100 500 Td (Hi) Tj ET\nendstream\nendobj\ntrailer\n<< /Root 1 0 R >>\n"
  let d = @pdftext.Doc::open(Bytes::makei(s.length(), fn(i) { s.code_unit_at(i).to_int().to_byte() })).unwrap()
  let g = d.page(0).glyphs
  // (H is 722 wide, i 222: at 100 points on a page of 1000, 0.0722 and 0.0222)
  assert_true((g[0].x1 - g[0].x0 - 0.0722).abs() < 1.0e-6)
  assert_true((g[1].x0 - 0.1722).abs() < 1.0e-6 && (g[1].x1 - g[1].x0 - 0.0222).abs() < 1.0e-6)
}
