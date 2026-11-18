// What a chat opens on: the window of its thread's entries a first screen needs, as the TypeScript core works it out
// (client/core-ts/src/station/topics.ts `entryMinRows`, `#firstShown`, `FIRST_SHOWN_FEWEST`).

///|
/// The fewest messages a chat opened at its end opens on by what they take: a screen of them however long
/// (topics.ts `FIRST_SHOWN_FEWEST`).
pub let first_shown_fewest : Int = 6

///|
/// Who writes as the station itself (titles.ts `STATION_AUTHORS`): its words are a notice, folded to a line.
let station_authors : Array[String] = ["station", "ember", "stillfail"]

///|
/// One entry of a chat's thread, as its page reads it.
#derive(Eq, Debug)
pub(all) struct Entry {
  n : Int
  /// `message`, `edit`, …: only messages show (and count).
  kind : String
  author_kind : String
  author : String
  text : String
  /// A notice's words, where the entry is one.
  notice : String?
  /// How many files it carries.
  files : Int
  /// What agents wrote each other (`letter` marked), which the page does not show.
  letter : Bool
}

///|
/// An entry read from its JSON as the station wrote it: what is not there is empty.
pub fn Entry::of_json(n : Int, json : Json) -> Entry {
  let str = (k : String) => match json {
    Object(m) =>
      match m.get(k) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
  let (notice, files, letter) = match json {
    Object(m) => {
      let notice = match m.get("notice") {
        Some(Object(o)) =>
          match o.get("words") {
            Some(String(w)) => Some(w)
            _ => Some("")
          }
        _ => None
      }
      let files = match m.get("attachments") {
        Some(Array(a)) => a.length()
        _ => 0
      }
      (notice, files, m.get("letter") is Some(Object(_)))
    }
    _ => (None, 0, false)
  }
  {
    n,
    kind: str("kind"),
    author_kind: str("authorKind"),
    author: str("author"),
    text: str("text"),
    notice,
    files,
    letter,
  }
}

///|
/// Whether it is a message the page shows: no edit, no letter between agents.
pub fn Entry::shown(self : Entry) -> Bool {
  self.kind == "message" && !self.letter
}

///|
/// The words of it read as Markdown, where any are (views.ts `mdWords`): a notice's, an agent's or the station's
/// text; a person's are not.
pub fn Entry::md_words(self : Entry) -> String? {
  match self.notice {
    Some(w) => Some(w)
    None => if self.author_kind == "person" { None } else { Some(self.text) }
  }
}

///|
/// Whether code unit `c` is white space as JavaScript's `trim` takes it.
fn is_space(c : Int) -> Bool {
  c == 0x20 ||
  (c >= 0x09 && c <= 0x0d) ||
  c == 0xa0 ||
  c == 0x1680 ||
  (c >= 0x2000 && c <= 0x200a) ||
  c == 0x2028 ||
  c == 0x2029 ||
  c == 0x202f ||
  c == 0x205f ||
  c == 0x3000 ||
  c == 0xfeff
}

///|
/// The length of `text[from:to]` trimmed, in UTF-16 code units (JavaScript's `line.trim().length`).
fn trimmed_length(text : String, from : Int, to : Int) -> Int {
  let mut a = from
  let mut b = to
  while a < b && is_space(text.code_unit_at(a).to_int()) {
    a += 1
  }
  while b > a && is_space(text.code_unit_at(b - 1).to_int()) {
    b -= 1
  }
  b - a
}

///|
/// What a message takes at least on its page, in rows of the least a message takes (a folded notice's): a notice or
/// the station's words 1; a text's each line past its first and each 100 characters a line wraps at 0.55 of a row,
/// blank lines not counted; its files 2 more; 6 at most. topics.ts `entryMinRows`, the same for the same entry.
pub fn entry_min_rows(e : Entry) -> Int {
  if e.notice is Some(_) || station_authors.contains(e.author_kind) {
    return 1
  }
  let text = e.text
  let mut lines = 0
  let mut start = 0
  for i in 0..=text.length() {
    if i == text.length() || text.code_unit_at(i).to_int() == 10 {
      let length = trimmed_length(text, start, i)
      if length > 0 {
        lines += 1 + length / 100
      }
      start = i + 1
    }
  }
  // (0.55 of a row a line, floored: 55/100 in whole numbers floors as the double does, 0.55 being stored just above)
  let extra = (if lines > 1 { lines - 1 } else { 0 }) * 55 / 100
  let files = if e.files > 0 { 2 } else { 0 }
  let rows = 1 + extra + files
  if rows < 6 {
    rows
  } else {
    6
  }
}

///|
/// The window of `entries` (in the order of their numbers) a chat opens on, as indexes `[from, to)` into them.
///
/// At a place (`at`: an unread message, a place it was left at): the entries numbered `at - page ..= at + page - 1`,
/// a screen's context each side. At its end: back from the last entry until `rows` messages it shows are in, or,
/// once `first_shown_fewest` of them are (or `rows`, if fewer), until what they take at least (`entry_min_rows`)
/// fills `rows`: a chat of long replies opens on the screen of them it shows, not on as many replies as short
/// notices would fill it with (topics.ts `#firstShown` weighed).
pub fn first_shown_window(entries : Array[Entry], rows : Int, at? : Int, page? : Int) -> (Int, Int) {
  let page = match page {
    Some(p) => p
    None => rows
  }
  match at {
    Some(at) => {
      let mut from = entries.length()
      let mut to = 0
      for i, e in entries {
        if e.n >= at - page && e.n <= at + page - 1 {
          if i < from {
            from = i
          }
          to = i + 1
        }
      }
      if from >= to {
        (0, 0)
      } else {
        (from, to)
      }
    }
    None => {
      let fewest = if first_shown_fewest < rows { first_shown_fewest } else { rows }
      let mut shown = 0
      let mut weight = 0
      let mut first = entries.length()
      for i = entries.length() - 1; i >= 0; i = i - 1 {
        first = i
        let e = entries[i]
        if !e.shown() {
          continue
        }
        shown += 1
        weight += entry_min_rows(e)
        if shown >= rows || (shown >= fewest && weight >= rows) {
          break
        }
      }
      (first, entries.length())
    }
  }
}
