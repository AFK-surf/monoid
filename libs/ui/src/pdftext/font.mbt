// A PDF font as far as words need it: how a shown string splits into codes, how far each code moves the pen, and what
// character it is (its ToUnicode map, else its encoding). A code no map names has no text: it still takes its place.

///|
priv struct Font {
  /// the byte lengths codes come in, and each's range (a composite font's codespace); empty: one byte each
  spaces : Array[(Int, Int, Int)]
  /// by CID (a composite font) or code (a simple one), in glyph units
  widths : Map[Int, Double]
  default_width : Double
  /// glyph units to the text space's unit (1/1000, or a Type 3 font's matrix)
  scale : Double
  /// code to CID, where the font's CMap is embedded
  cids : Map[Int, Int]
  /// code to text (ToUnicode)
  unicode : Map[Int, String]
  /// a simple font's code to text (its encoding)
  encoded : Map[Int, String]
  /// the code is itself UTF-16 (a `Uni…-UCS2`/`-UTF16` CMap)
  code_is_utf16 : Bool
  /// the base encoding of a simple font: 0 none, 1 WinAnsi, 2 MacRoman, 3 Standard
  base : Int
  ascent : Double
  descent : Double
}

///|
/// The most entries one map may expand to.
const MOST_MAPPED : Int = 200000

///|
/// Big-endian number of a CMap's hex string.
fn code_of(b : Bytes) -> Int {
  let mut v = 0
  for i in 0..<imin(b.length(), 4) {
    v = (v << 8) | b[i].to_int()
  }
  v
}

///|
/// UTF-16BE as a string, what is not valid left out.
fn utf16be(b : Bytes) -> String {
  let out = StringBuilder()
  let mut i = 0
  while i + 1 < b.length() {
    let u = b[i].to_int() * 256 + b[i + 1].to_int()
    i += 2
    if u >= 0xD800 && u < 0xDC00 && i + 1 < b.length() {
      let low = b[i].to_int() * 256 + b[i + 1].to_int()
      if low >= 0xDC00 && low < 0xE000 {
        i += 2
        out.write_char((0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00)).unsafe_to_char())
      }
    } else if u < 0xD800 || u >= 0xE000 {
      out.write_char(u.unsafe_to_char())
    }
  }
  out.to_string()
}

///|
/// `s` with its last character moved on by `by`.
fn moved_on(s : String, by : Int) -> String {
  let chars = s.iter().collect()
  if chars.is_empty() {
    return s
  }
  let last = chars[chars.length() - 1].to_int() + by
  if last < 0 || last > 0x10FFFF || (last >= 0xD800 && last < 0xE000) {
    return s
  }
  chars[chars.length() - 1] = last.unsafe_to_char()
  String::from_array(chars)
}

///|
/// A CMap's bf and cid sections read into `unicode`, `cids` and `spaces`.
fn read_cmap(data : Bytes, unicode : Map[Int, String], cids : Map[Int, Int], spaces : Array[(Int, Int, Int)]) -> Unit {
  let lex = Lex::new(data, 0, data.length(), links=false)
  let mut mapped = 0
  while true {
    guard lex.next() is Some(t) else { break }
    match t {
      Op("begincodespacerange") =>
        while true {
          match lex.next() {
            Some(Str(a)) =>
              match lex.next() {
                Some(Str(b)) => spaces.push((a.length(), code_of(a), code_of(b)))
                _ => break
              }
            _ => break
          }
        }
      Op("beginbfchar") =>
        while true {
          match lex.next() {
            Some(Str(c)) =>
              match lex.next() {
                Some(Str(u)) => {
                  unicode[code_of(c)] = utf16be(u)
                  mapped += 1
                }
                _ => break
              }
            _ => break
          }
        }
      Op("beginbfrange") =>
        while true {
          guard lex.next() is Some(Str(lo)) else { break }
          guard lex.next() is Some(Str(hi)) else { break }
          guard lex.next() is Some(dest) else { break }
          let a = code_of(lo)
          let z = imin(code_of(hi), a + 65535)
          match dest {
            Str(u) => {
              let first = utf16be(u)
              let mut c = a
              while c <= z && mapped < MOST_MAPPED {
                unicode[c] = moved_on(first, c - a)
                mapped += 1
                c += 1
              }
            }
            List(items) =>
              for k, it in items {
                if a + k > z || mapped >= MOST_MAPPED {
                  break
                }
                if it is Str(u) {
                  unicode[a + k] = utf16be(u)
                  mapped += 1
                }
              }
            _ => ()
          }
        }
      Op("begincidchar") =>
        while true {
          match lex.next() {
            Some(Str(c)) =>
              match lex.next() {
                Some(Num(n)) => {
                  cids[code_of(c)] = n.to_int()
                  mapped += 1
                }
                _ => break
              }
            _ => break
          }
        }
      Op("begincidrange") =>
        while true {
          guard lex.next() is Some(Str(lo)) else { break }
          guard lex.next() is Some(Str(hi)) else { break }
          guard lex.next() is Some(Num(n)) else { break }
          let a = code_of(lo)
          let z = imin(code_of(hi), a + 65535)
          let mut c = a
          while c <= z && mapped < MOST_MAPPED {
            cids[c] = n.to_int() + (c - a)
            mapped += 1
            c += 1
          }
        }
      _ => ()
    }
    if mapped >= MOST_MAPPED {
      break
    }
  }
}

///|
/// The Windows code page's characters for 0x80 to 0x9F (0: none).
let win_high : FixedArray[Int] = [
  0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
  0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
]

///|
/// MacRoman's characters for 0x80 to 0xFF.
let mac_high : FixedArray[Int] = [
  0xC4, 0xC5, 0xC7, 0xC9, 0xD1, 0xD6, 0xDC, 0xE1, 0xE0, 0xE2, 0xE4, 0xE3, 0xE5, 0xE7, 0xE9, 0xE8,
  0xEA, 0xEB, 0xED, 0xEC, 0xEE, 0xEF, 0xF1, 0xF3, 0xF2, 0xF4, 0xF6, 0xF5, 0xFA, 0xF9, 0xFB, 0xFC,
  0x2020, 0xB0, 0xA2, 0xA3, 0xA7, 0x2022, 0xB6, 0xDF, 0xAE, 0xA9, 0x2122, 0xB4, 0xA8, 0x2260, 0xC6, 0xD8,
  0x221E, 0xB1, 0x2264, 0x2265, 0xA5, 0xB5, 0x2202, 0x2211, 0x220F, 0x3C0, 0x222B, 0xAA, 0xBA, 0x3A9, 0xE6, 0xF8,
  0xBF, 0xA1, 0xAC, 0x221A, 0x192, 0x2248, 0x2206, 0xAB, 0xBB, 0x2026, 0xA0, 0xC0, 0xC3, 0xD5, 0x152, 0x153,
  0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0xF7, 0x25CA, 0xFF, 0x178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
  0x2021, 0xB7, 0x201A, 0x201E, 0x2030, 0xC2, 0xCA, 0xC1, 0xCB, 0xC8, 0xCD, 0xCE, 0xCF, 0xCC, 0xD3, 0xD4,
  0xF8FF, 0xD2, 0xDA, 0xDB, 0xD9, 0x131, 0x2C6, 0x2DC, 0xAF, 0x2D8, 0x2D9, 0x2DA, 0xB8, 0x2DD, 0x2DB, 0x2C7,
]

///|
/// Adobe's Standard encoding where it is not ASCII: code, character.
let standard_differs : Array[(Int, Int)] = [
  (0x27, 0x2019), (0x60, 0x2018), (0xA1, 0xA1), (0xA2, 0xA2), (0xA3, 0xA3), (0xA4, 0x2044), (0xA5, 0xA5), (0xA6, 0x192),
  (0xA7, 0xA7), (0xA8, 0xA4), (0xA9, 0x27), (0xAA, 0x201C), (0xAB, 0xAB), (0xAC, 0x2039), (0xAD, 0x203A), (0xAE, 0xFB01),
  (0xAF, 0xFB02), (0xB1, 0x2013), (0xB2, 0x2020), (0xB3, 0x2021), (0xB4, 0xB7), (0xB6, 0xB6), (0xB7, 0x2022), (0xB8, 0x201A),
  (0xB9, 0x201E), (0xBA, 0x201D), (0xBB, 0xBB), (0xBC, 0x2026), (0xBD, 0x2030), (0xBF, 0xBF), (0xD0, 0x2014), (0xE1, 0xC6),
  (0xE3, 0xAA), (0xE8, 0x141), (0xE9, 0xD8), (0xEA, 0x152), (0xEB, 0xBA), (0xF1, 0xE6), (0xF5, 0x131), (0xF8, 0x142),
  (0xF9, 0xF8), (0xFA, 0x153), (0xFB, 0xDF),
]

///|
/// Code `c`'s character in base encoding `base`; 0 none.
fn base_char(base : Int, c : Int) -> Int {
  match base {
    1 =>
      if c >= 0x80 && c <= 0x9F {
        win_high[c - 0x80]
      } else if c >= 0x20 {
        c
      } else {
        0
      }
    2 =>
      if c >= 0x80 && c <= 0xFF {
        mac_high[c - 0x80]
      } else if c >= 0x20 {
        c
      } else {
        0
      }
    3 => {
      for d in standard_differs {
        if d.0 == c {
          return d.1
        }
      }
      if c >= 0x20 && c < 0x7F {
        c
      } else {
        0
      }
    }
    _ => 0
  }
}

///|
/// Glyph names a Differences array uses beyond a single letter: name, character.
let glyph_names : Array[(String, Int)] = [
  ("space", 0x20), ("exclam", 0x21), ("quotedbl", 0x22), ("numbersign", 0x23), ("dollar", 0x24), ("percent", 0x25),
  ("ampersand", 0x26), ("quotesingle", 0x27), ("parenleft", 0x28), ("parenright", 0x29), ("asterisk", 0x2A), ("plus", 0x2B),
  ("comma", 0x2C), ("hyphen", 0x2D), ("minus", 0x2212), ("period", 0x2E), ("slash", 0x2F), ("zero", 0x30), ("one", 0x31),
  ("two", 0x32), ("three", 0x33), ("four", 0x34), ("five", 0x35), ("six", 0x36), ("seven", 0x37), ("eight", 0x38),
  ("nine", 0x39), ("colon", 0x3A), ("semicolon", 0x3B), ("less", 0x3C), ("equal", 0x3D), ("greater", 0x3E),
  ("question", 0x3F), ("at", 0x40), ("bracketleft", 0x5B), ("backslash", 0x5C), ("bracketright", 0x5D),
  ("asciicircum", 0x5E), ("underscore", 0x5F), ("grave", 0x60), ("braceleft", 0x7B), ("bar", 0x7C), ("braceright", 0x7D),
  ("asciitilde", 0x7E), ("quoteleft", 0x2018), ("quoteright", 0x2019), ("quotedblleft", 0x201C), ("quotedblright", 0x201D),
  ("quotesinglbase", 0x201A), ("quotedblbase", 0x201E), ("endash", 0x2013), ("emdash", 0x2014), ("bullet", 0x2022),
  ("ellipsis", 0x2026), ("fi", 0xFB01), ("fl", 0xFB02), ("ff", 0xFB00), ("ffi", 0xFB03), ("ffl", 0xFB04), ("dagger", 0x2020),
  ("daggerdbl", 0x2021), ("degree", 0xB0), ("copyright", 0xA9), ("registered", 0xAE), ("trademark", 0x2122),
  ("section", 0xA7), ("paragraph", 0xB6), ("periodcentered", 0xB7), ("multiply", 0xD7), ("divide", 0xF7), ("plusminus", 0xB1),
  ("eacute", 0xE9), ("egrave", 0xE8), ("agrave", 0xE0), ("aacute", 0xE1), ("uuml", 0xFC), ("udieresis", 0xFC),
  ("odieresis", 0xF6), ("adieresis", 0xE4), ("germandbls", 0xDF), ("ccedilla", 0xE7), ("ntilde", 0xF1),
  ("alpha", 0x3B1), ("beta", 0x3B2), ("gamma", 0x3B3), ("delta", 0x3B4), ("epsilon", 0x3B5), ("lambda", 0x3BB),
  ("mu", 0x3BC), ("pi", 0x3C0), ("sigma", 0x3C3), ("tau", 0x3C4), ("phi", 0x3C6), ("omega", 0x3C9),
]

///|
/// A glyph's name as a character (`A`, `uni4E2D`, `u1F600`, `space`), "" if unknown.
fn glyph_text(name : String) -> String {
  // (`a.alt`: its base's)
  let base = match name.find(".") {
    Some(i) if i > 0 => name.exact_view(end=i).to_owned()
    _ => name
  }
  if base.length() == 1 {
    return base
  }
  for g in glyph_names {
    if g.0 == base {
      return g.1.unsafe_to_char().to_string()
    }
  }
  let hex_from = if base.has_prefix("uni") && base.length() >= 7 {
    3
  } else if base.has_prefix("u") && base.length() >= 5 && base.length() <= 7 {
    1
  } else {
    -1
  }
  if hex_from > 0 {
    let end = if hex_from == 3 { 7 } else { base.length() }
    let mut v = 0
    for k in hex_from..<end {
      let h = hex_value(base.code_unit_at(k).to_int())
      if h < 0 {
        return ""
      }
      v = v * 16 + h
    }
    if v > 0 && v <= 0x10FFFF && (v < 0xD800 || v >= 0xE000) {
      return v.unsafe_to_char().to_string()
    }
  }
  ""
}

///|
/// Font dictionary `d` read.
fn Objects::font(self : Objects, d : Map[String, Obj]) -> Font {
  let subtype = self.name_of(d.get("Subtype"))
  let unicode : Map[Int, String] = Map([])
  let cids : Map[Int, Int] = Map([])
  let spaces : Array[(Int, Int, Int)] = []
  let widths : Map[Int, Double] = Map([])
  let encoded : Map[Int, String] = Map([])
  match self.of(d.get("ToUnicode")) {
    Stream(_, _, _) as s =>
      match self.stream_bytes(s) {
        Some(data) => read_cmap(data, unicode, Map([]), [])
        None => ()
      }
    _ => ()
  }
  let mut default_width = 0.0
  let mut scale = 0.001
  let mut code_is_utf16 = false
  let mut base = 0
  let mut descriptor : Map[String, Obj]? = None
  if subtype == "Type0" {
    default_width = 1000.0
    match self.of(d.get("Encoding")) {
      Name(n) => {
        code_is_utf16 = n.contains("UCS2") || n.contains("UTF16")
        if !n.has_prefix("Identity") && !code_is_utf16 {
          // (a legacy double-byte encoding: ASCII one byte, the rest two)
          spaces.push((1, 0, 0x7F))
        }
        spaces.push((2, 0, 0xFFFF))
      }
      Stream(_, _, _) as s => {
        match self.stream_bytes(s) {
          Some(data) => read_cmap(data, Map([]), cids, spaces)
          None => ()
        }
        if spaces.is_empty() {
          spaces.push((2, 0, 0xFFFF))
        }
      }
      _ => spaces.push((2, 0, 0xFFFF))
    }
    let kids = self.of(d.get("DescendantFonts"))
    let kid = match kids {
      List(a) if a.length() > 0 => self.dict(Some(a[0]))
      _ => None
    }
    match kid {
      Some(k) => {
        default_width = self.num(k.get("DW"), 1000.0)
        descriptor = self.dict(k.get("FontDescriptor"))
        self.cid_widths(k.get("W"), widths)
      }
      None => ()
    }
  } else {
    let first = self.int_of(d.get("FirstChar"), 0)
    for k, w in self.nums(d.get("Widths")) {
      if k >= 4096 {
        break
      }
      widths[first + k] = w
    }
    descriptor = self.dict(d.get("FontDescriptor"))
    default_width = match descriptor {
      Some(fd) => self.num(fd.get("MissingWidth"), 0.0)
      None => 0.0
    }
    // (a standard font may come with no widths at all: its own, known to every reader)
    if widths.is_empty() && subtype != "Type3" {
      match core_widths(self.name_of(d.get("BaseFont"))) {
        Some((table, usual)) => {
          default_width = usual.to_double()
          match table {
            Some(t) =>
              for k in 0..<t.length() {
                widths[32 + k] = t[k].to_double()
              }
            None => ()
          }
        }
        None => ()
      }
    }
    if subtype == "Type3" {
      let m = self.nums(d.get("FontMatrix"))
      if m.length() == 6 && m[0] != 0.0 {
        scale = m[0].abs()
      }
    }
    base = if subtype == "TrueType" { 1 } else if subtype == "Type3" { 0 } else { 3 }
    let named = fn(n : String) {
      match n {
        "WinAnsiEncoding" => 1
        "MacRomanEncoding" => 2
        "StandardEncoding" => 3
        _ => base
      }
    }
    match self.of(d.get("Encoding")) {
      Name(n) => base = named(n)
      Dict(e) => {
        base = named(self.name_of(e.get("BaseEncoding")))
        match self.of(e.get("Differences")) {
          List(items) => {
            let mut at = 0
            for it in items {
              match self.get(it) {
                Num(n) => at = n.to_int()
                Name(g) => {
                  let t = glyph_text(g)
                  if t != "" {
                    encoded[at] = t
                  }
                  at += 1
                }
                _ => ()
              }
            }
          }
          _ => ()
        }
      }
      _ => ()
    }
  }
  let (ascent, descent) = match descriptor {
    Some(fd) => {
      let a = self.num(fd.get("Ascent"), 0.0) / 1000.0
      let e = self.num(fd.get("Descent"), 0.0) / 1000.0
      (
        if a > 0.3 && a < 1.6 { a } else { default_ascent },
        if e < 0.0 && e > -0.8 { e } else { default_descent },
      )
    }
    None => (default_ascent, default_descent)
  }
  {
    spaces,
    widths,
    default_width,
    scale,
    cids,
    unicode,
    encoded,
    code_is_utf16,
    base,
    ascent,
    descent,
  }
}

///|
let default_ascent : Double = 0.88

///|
let default_descent : Double = -0.2

///|
/// A CID font's `W` array read into `out`.
fn Objects::cid_widths(self : Objects, w : Obj?, out : Map[Int, Double]) -> Unit {
  guard self.of(w) is List(a) else { return }
  let mut i = 0
  let mut total = 0
  while i + 1 < a.length() && total < MOST_MAPPED {
    let c = self.int_of(Some(a[i]), 0)
    match self.get(a[i + 1]) {
      List(ws) => {
        for k, x in ws {
          out[c + k] = self.num(Some(x), 0.0)
          total += 1
        }
        i += 2
      }
      Num(z) => {
        if i + 2 >= a.length() {
          break
        }
        let v = self.num(Some(a[i + 2]), 0.0)
        let last = imin(z.to_int(), c + 65535)
        let mut k = c
        while k <= last && total < MOST_MAPPED {
          out[k] = v
          total += 1
          k += 1
        }
        i += 3
      }
      _ => i += 2
    }
  }
}

///|
/// The code at `i` of `s`, and how many bytes it took.
fn Font::code_at(self : Font, s : Bytes, i : Int) -> (Int, Int) {
  if self.spaces.is_empty() {
    return (s[i].to_int(), 1)
  }
  let mut v = 0
  for n in 1..=4 {
    if i + n > s.length() {
      break
    }
    v = (v << 8) | s[i + n - 1].to_int()
    for r in self.spaces {
      if r.0 == n && v >= r.1 && v <= r.2 {
        return (v, n)
      }
    }
  }
  // (no range holds it: as many bytes as the longest, what is left at most)
  let mut longest = 1
  for r in self.spaces {
    longest = imax(longest, r.0)
  }
  let n = imin(longest, s.length() - i)
  let mut c = 0
  for k in 0..<n {
    c = (c << 8) | s[i + k].to_int()
  }
  (c, n)
}

///|
/// How far code `code` moves the pen, in the text space's units at size 1.
fn Font::advance(self : Font, code : Int) -> Double {
  let key = if self.spaces.is_empty() { code } else { self.cids.get(code).unwrap_or(code) }
  self.widths.get(key).unwrap_or(self.default_width) * self.scale
}

///|
/// What code `code` says; "" where no map names it.
fn Font::text_of(self : Font, code : Int) -> String {
  match self.unicode.get(code) {
    Some(t) => t
    None => {
      if self.code_is_utf16 && code > 0 && (code < 0xD800 || code >= 0xE000) {
        return code.unsafe_to_char().to_string()
      }
      if !self.spaces.is_empty() {
        return ""
      }
      match self.encoded.get(code) {
        Some(t) => t
        None => {
          let c = base_char(self.base, code)
          if c > 0 {
            c.unsafe_to_char().to_string()
          } else {
            ""
          }
        }
      }
    }
  }
}

///|
/// The ideographs Kangxi radicals U+2F00 to U+2FD5 stand for. Some fonts map their glyphs to the radicals, which look the
/// same and match nothing when the words are searched for or edited.
let kangxi : String = "一丨丶丿乙亅二亠人儿入八冂冖冫几凵刀力勹匕匚匸十卜卩厂厶又口囗土士夂夊夕大女子宀寸小尢尸屮山巛工己巾干幺广廴廾弋弓彐彡彳心戈戶手支攴文斗斤方无日曰月木欠止歹殳毋比毛氏气水火爪父爻爿片牙牛犬玄玉瓜瓦甘生用田疋疒癶白皮皿目矛矢石示禸禾穴立竹米糸缶网羊羽老而耒耳聿肉臣自至臼舌舛舟艮色艸虍虫血行衣襾見角言谷豆豕豸貝赤走足身車辛辰辵邑酉釆里金長門阜隶隹雨靑非面革韋韭音頁風飛食首香馬骨高髟鬥鬯鬲鬼魚鳥鹵鹿麥麻黃黍黑黹黽鼎鼓鼠鼻齊齒龍龜龠"

///|
/// The ideographs CJK radicals U+2E80 to U+2EF3 stand for (Unicode's EquivalentUnifiedIdeograph.txt), U+3000 where none
/// is in the basic plane.
let radicals : String = "　厂乛乚乙亻冂　刀刂卜㔾小小兀尣尢　巳幺彑　忄心扌攵　旡日月歺母民氵氺灬爫爫丬牛犭王　目示礻　糹纟罓罒㓁冗　羊　　耂肀聿肉　艹艹艹虎衤覀西见角　讠贝　车辶辶辶邑钅長镸长门　阝雨青韦页风飞食　飠饣　马骨鬼鱼鸟卤麦黄黾斉齐歯齿竜龙龜亀龟"

///|
/// What a glyph says as it is copied: radicals as their ideographs, a ligature as its letters.
fn plain_text(s : String) -> String {
  let mut plain = true
  for c in s {
    let v = c.to_int()
    if (v >= 0x2E80 && v <= 0x2FD5) || (v >= 0xFB00 && v <= 0xFB06) {
      plain = false
      break
    }
  }
  if plain {
    return s
  }
  let out = StringBuilder()
  for c in s {
    let v = c.to_int()
    if v >= 0x2F00 && v <= 0x2FD5 {
      out.write_char(kangxi.code_unit_at(v - 0x2F00).to_int().unsafe_to_char())
    } else if v >= 0x2E80 && v <= 0x2EF3 {
      let r = radicals.code_unit_at(v - 0x2E80).to_int()
      out.write_char((if r == 0x3000 { v } else { r }).unsafe_to_char())
    } else {
      match v {
        0xFB00 => out.write_string("ff")
        0xFB01 => out.write_string("fi")
        0xFB02 => out.write_string("fl")
        0xFB03 => out.write_string("ffi")
        0xFB04 => out.write_string("ffl")
        0xFB05 | 0xFB06 => out.write_string("st")
        _ => out.write_char(c)
      }
    }
  }
  out.to_string()
}
