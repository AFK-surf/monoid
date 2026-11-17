// What a group connect says and reads besides its events (group/surface.ts): a file's type by its name, a mention of
// the bot, a card's question in words where the anchor takes no decision, and a picture's size of its head.

///|
let mimes : Map[String, String] = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
  ".pdf": "application/pdf",
  ".txt": "text/plain",
  ".md": "text/markdown",
  ".json": "application/json",
  ".csv": "text/csv",
  ".html": "text/html",
  ".mp4": "video/mp4",
  ".mov": "video/quicktime",
  ".webm": "video/webm",
  ".mp3": "audio/mpeg",
  ".zip": "application/zip",
}

///|
/// `path.extname(name)`: from the last dot of its last part, unless that part starts with it.
pub fn extname(name : String) -> String {
  let base = basename(name, "/")
  let dot = @session_chats.last_index_of(base, ".")
  if dot <= 0 {
    ""
  } else {
    @session_chats.slice(base, dot)
  }
}

///|
pub fn mime_of(name : String) -> String {
  mimes.get(@session_chats.lower(extname(name))).unwrap_or("application/octet-stream")
}

///|
/// What JavaScript's `[A-Za-z0-9_]` takes with the `iu` flags: ASCII's word characters, and the two that fold into
/// them (ſ to s, the Kelvin sign to k).
fn word_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '\u{17F}' || c == '\u{212A}'
}

///|
/// A character as `iu` compares it (its simple case folding, as near as lowercasing it says it).
fn folded(c : Char) -> String {
  match c {
    '\u{17F}' => "s"
    '\u{212A}' => "k"
    '\u{3C2}' => "\u{3C3}"
    _ => @jscase.lower(c.to_string())
  }
}

///|
/// Whether `text` mentions `name` as `@name` (in any case), not as the start of a longer ASCII word.
pub fn mentions(text : String, name : String) -> Bool {
  if name == "" {
    return false
  }
  let t = text.to_array()
  let want = ['@', ..name.to_array()]
  for i in 0..=(t.length() - want.length()) {
    if i > 0 && word_char(t[i - 1]) {
      continue
    }
    let mut same = true
    for k in 0..<want.length() {
      if folded(t[i + k]) != folded(want[k]) {
        same = false
        break
      }
    }
    if !same {
      continue
    }
    let next = i + want.length()
    if next < t.length() && word_char(t[next]) {
      continue
    }
    return true
  }
  false
}

///|
/// A card's question as the words of a message: its question, then each option numbered, and how to answer.
pub fn card_words(speech : Speech, text : String, card : J, lang : String) -> (String, Array[String]) {
  let options : Array[String] = if str_of(at(Some(card), "type")) == Some("options") && at(Some(card), "options") is Some(Arr(os)) {
    os
    .map(o => match at(Some(o), "label") {
      Some(Null) | None => ""
      Some(l) => js_text(Some(l))
    })
    .filter(l => l != "")
  } else {
    []
  }
  let lines = [@session_chats.trim_end(text)]
  if options.length() > 0 {
    lines.push("")
    for i, label in options {
      lines.push("\{i + 1}. \{label}")
    }
    lines.push("")
    lines.push(speech.tr(lang, "station.group.answerOptions"))
  } else if str_of(at(Some(card), "type")) == Some("text") {
    lines.push("")
    lines.push(speech.tr(lang, "station.group.answerText"))
  }
  let mut words = lines.join("\n")
  while words.has_prefix("\n") {
    words = @session_chats.slice(words, 1)
  }
  (words, options)
}

///|
/// A picture's size, read of its head (PNG, GIF, JPEG, WebP), so the anchor can say it before it is fetched; None for
/// what is none of these or says no size.
pub fn image_size(b : Bytes) -> (Double, Double)? {
  let n = b.length()
  let u8 = (i : Int) => b[i].to_int()
  let be16 = (i : Int) => (u8(i) << 8) | u8(i + 1)
  let le16 = (i : Int) => u8(i) | (u8(i + 1) << 8)
  let be32 = (i : Int) => (u8(i).to_double() * 16777216.0 + ((u8(i + 1) << 16) | (u8(i + 2) << 8) | u8(i + 3)).to_double())
  let le32 = (i : Int) => (u8(i + 3).to_double() * 16777216.0 + ((u8(i + 2) << 16) | (u8(i + 1) << 8) | u8(i)).to_double())
  let ascii = (at_ : Int, k : Int) => if n >= at_ + k {
    let out = StringBuilder()
    for i in at_..<(at_ + k) {
      out.write_char(Int::unsafe_to_char(u8(i)))
    }
    out.to_string()
  } else {
    ""
  }
  let sized = (w : Double, h : Double) => if w > 0.0 && h > 0.0 && w.floor() == w && h.floor() == h {
    Some((w, h))
  } else {
    None
  }
  if n >= 24 && u8(0) == 0x89 && ascii(1, 3) == "PNG" && ascii(12, 4) == "IHDR" {
    return sized(be32(16), be32(20))
  }
  if n >= 10 && (ascii(0, 6) == "GIF87a" || ascii(0, 6) == "GIF89a") {
    return sized(le16(6).to_double(), le16(8).to_double())
  }
  if n >= 4 && u8(0) == 0xff && u8(1) == 0xd8 {
    let mut i = 2
    while i + 4 <= n {
      if u8(i) != 0xff {
        return None
      }
      let marker = u8(i + 1)
      if marker == 0xff {
        i += 1
        continue
      }
      if marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8) {
        i += 2
        continue
      }
      if marker == 0xd9 || marker == 0xda {
        return None
      }
      let length = be16(i + 2)
      // (a frame's start: every SOFn but DHT C4, JPG C8 and DAC CC)
      if marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc {
        return if i + 9 <= n { sized(be16(i + 7).to_double(), be16(i + 5).to_double()) } else { None }
      }
      i += 2 + length
    }
    return None
  }
  if n >= 30 && ascii(0, 4) == "RIFF" && ascii(8, 4) == "WEBP" {
    let chunk = ascii(12, 4)
    if chunk == "VP8 " && u8(23) == 0x9d && u8(24) == 0x01 && u8(25) == 0x2a {
      return sized((le16(26) & 0x3fff).to_double(), (le16(28) & 0x3fff).to_double())
    }
    if chunk == "VP8L" && u8(20) == 0x2f {
      let bits = le32(21)
      let w = bits.to_int64().land(0x3fff) + 1L
      let h = (bits.to_int64() >> 14).land(0x3fff) + 1L
      return sized(w.to_double(), h.to_double())
    }
    if chunk == "VP8X" {
      return sized(
        ((u8(24) | (u8(25) << 8) | (u8(26) << 16)) + 1).to_double(),
        ((u8(27) | (u8(28) << 8) | (u8(29) << 16)) + 1).to_double(),
      )
    }
  }
  None
}
