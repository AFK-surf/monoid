// What a file's card holds (peeks.mbt's file_card) as nodes of the window's tree, made once: what is over it, opened
// and shut as the pointer rests on the chip that names the file, is the hover card's (sf's), not this; this is what is
// in it, as the core reads the file (`filePeek`, read by whoever holds the card) and as that changes: its head, a few of
// its lines, its picture or its first entries, its foot with its path to copy; in its bones while it is read and its
// picture comes, said why not where it is not read. Drawn by the library's (@sf.peek_file_head_node, its lines, picture,
// entries and foot); this is what is read for it and what that says.

///|
/// What a file's card shows (file_card's): its bones while it is read (and the picture it names comes); why not, read
/// and refused; the file as the core read it.
#derive(Eq)
priv enum FileShows {
  Bones
  Refused
  Shown
}

///|
/// What a file's card holds (file_card's) in `parent`: the file `path` (at `line`) that session `session` of station
/// `station` names, as `read` reads it (`filePeek`, held by whoever holds the card): in its bones while it is read and
/// the picture it names comes (@sfbase.file_peek_picture_told: told as it comes, asked as the file is read, never as a
/// binding runs), why not where it is refused, else as it is read.
// a hover card as nodes: held by its tests, not used by the app yet
#warnings("-unused_value")
fn file_card_node(
  parent : @view.View,
  src : Source,
  station : String,
  session : String,
  path : String,
  line : Int?,
  read : @signals.Computed[@sfbase.TopicState],
) -> Unit {
  let value = fn() -> Json? {
    match read.get().value {
      Some(Object(_)) as v => v
      _ => None
    }
  }
  // (the picture it names asked as it is read, as that changes; told to what reads it as it comes)
  parent.reacts(value, fn(v) {
    if v is Some(_) {
      @sfbase.file_peek_picture_ask(src, station, session, path, line, v)
    }
  })
  // (its picture's key: "" while it comes, "!" none)
  let picture_key = fn() {
    match value() {
      Some(_) as v => @sfbase.file_peek_picture_told(src, station, session, path, line, v)
      None => ""
    }
  }
  let shows = fn() {
    if value() is Some(_) && picture_key() != "" {
      Shown
    } else if read.get().error is Some(_) {
      Refused
    } else {
      Bones
    }
  }
  parent.pick(shows, fn(b, s) {
    @sf.style_node(b, fn() { @sf.peek_card_part })
    match s {
      Shown => file_shown_node(b, fn() { @sfbase.picture_drawn(picture_key()) }, value)
      // (while it is read: a made-up file's, in its bones)
      Bones => @sf.waiting_node(b, fn(bones) { file_shown_node(bones, fn() { "" }, fn() { file_sample(path) }) })
      Refused =>
        @sf.peek_rich_node(b, fn(rich) {
          file_head_node(rich, fn() { base_of(path) }, fn() { is_dir_path(path) }, fn() { path }, fn() { "" })
          @sf.peek_note_node(rich, fn() { text(read.get().error, "message") })
          file_foot_node(rich, fn() { path }, fn() { "" })
        })
    }
  })
}

///|
/// The made-up file a file's card's bones are made of while it is read (file_card's): named as `path`, five lines.
fn file_sample(path : String) -> Json? {
  Some({
    "kind": "text",
    "name": Json::string(base_of(path)),
    "path": Json::string(path),
    "size": 1,
    "lines": { "start": 1, "text": Json::array([24, 32, 18, 28, 12].map(fn(n) { Json::string(@sf.sample_words(n)) })) },
  })
}

///|
/// A file as the core read it (`v`, file_shown's) in `parent`: its head; a text's lines, an image's picture (`picture`:
/// its image's key, "" none) or a directory's first entries; its foot.
fn file_shown_node(parent : @view.View, picture : () -> String, v : () -> Json?) -> Unit {
  let kind = fn() { text(v(), "kind") }
  let dir = fn() { kind() == "dir" }
  let lines = fn() { field(v(), "lines") }
  let at = fn() {
    match field(lines(), "at") {
      Some(Number(n, ..)) => Some(n.to_int())
      _ => None
    }
  }
  @sf.peek_rich_node(parent, fn(rich) {
    file_head_node(
      rich,
      fn() {
        text(v(), "name") +
        (match at() {
          Some(n) => ":" + n.to_string()
          None => ""
        })
      },
      dir,
      fn() { text(v(), "path") },
      fn() { text(field(field(v(), "time"), "mtime"), "ago") },
    )
    // (what it shows of itself: a text's lines, an image's picture, a directory's entries, or none)
    let body = fn() {
      match kind() {
        "text" if items(lines(), "text").length() > 0 => 1
        "image" if picture() != "" => 2
        "dir" if items(v(), "entries").length() > 0 => 3
        _ => 0
      }
    }
    // (none: nothing in its place, not even the room between)
    rich.show(fn() { body() != 0 }, fn(s) {
      s.pick(body, fn(b, k) {
        match k {
          1 => file_lines_node(b, lines, at, fn() { text(v(), "name") })
          // (its picture all in its box, fading in once it is decoded for the room it is given, the hover's ground under
          // it till then: an old view's picture's bg)
          2 => @sf.peek_file_picture_node(b, picture)
          3 => file_entries_node(b, fn() { items(v(), "entries") })
          _ => ()
        }
      })
    })
    let what = fn() {
      if dir() {
        @sf.t("web-main.preview.items", args=[("count", count(v(), "count").to_string())])
      } else {
        let size = @sf.file_size(
          match field(v(), "size") {
            Some(Number(n, ..)) => n
            _ => 0.0
          },
        )
        if kind() == "binary" {
          size + " · " + @sf.t("web-main.preview.binary")
        } else {
          size
        }
      }
    }
    file_foot_node(rich, fn() { text(v(), "path") }, what)
  })
}

///|
/// Its head (file_head's, @sf.peek_file_head_node) in `parent`: its mark (a folder's where `dir`), its name and when it
/// was written; its whole path under them, a home directory as `~` (shown_path).
fn file_head_node(
  parent : @view.View,
  name : () -> String,
  dir : () -> Bool,
  path : () -> String,
  ago : () -> String,
) -> Unit {
  @sf.peek_file_head_node(parent, name, dir, fn() { shown_path(path()) }, ago)
}

///|
/// Its lines (file_lines's, @sf.peek_file_lines_node) in `parent`: each numbered from `lines`' start, the one at `at`
/// marked, in the colours the core says of the language `name`'s (code.ink, as a preview colours it: code_ink_node),
/// plain till it has.
fn file_lines_node(parent : @view.View, lines : () -> Json?, at : () -> Int?, name : () -> String) -> Unit {
  let words = fn() {
    items(lines(), "text").map(fn(l) {
      match l {
        String(t) => t
        _ => ""
      }
    })
  }
  let lang = fn() {
    let (_, _, lang) = @sfbase.preview_kind(name())
    lang
  }
  // (coloured as a whole, then cut at its lines; a file of no language as it is, nothing asked)
  let all = fn() { words().join("\n") }
  let colored = if @signals.untracked(lang) == "" {
    fn() { [] }
  } else {
    let ink = @sf.code_ink_node(parent, all, lang)
    fn() {
      match ink() {
        Some(Some(i)) => @sfbase.runs_by_line(@sf.ink_runs(all(), i, @sf.theme().dark))
        _ => []
      }
    }
  }
  @sf.peek_file_lines_node(parent, fn() { count(lines(), "start") }, words, at, colored)
}

///|
/// A directory's first entries (file_entries's, @sf.peek_file_entries_node) in `parent`, by their names.
fn file_entries_node(parent : @view.View, entries : () -> Array[Json]) -> Unit {
  @sf.peek_file_entries_node(parent, fn() {
    entries().map(fn(e) {
      match e {
        String(t) => t
        _ => ""
      }
    })
  })
}

///|
/// Its foot (file_foot's, @sf.peek_file_foot_node) in `parent`: what it is in words (`what`), and its path to copy
/// (复制路径, saying 已复制 copied_ms from the moment it was pressed) in the card's bottom end corner.
fn file_foot_node(parent : @view.View, path : () -> String, what : () -> String) -> Unit {
  @sf.peek_file_foot_node(parent, what, fn(f) { @sf.peek_copy_node(f, path, "web-main.preview.copyPath", path_copied_at) })
}

///|
/// When each file's path was last copied from its card (file_foot_node's), by the path: what a card of it made again
/// says, as file_foot's mark by the path is kept.
// kept across runs: let go as the app begins anew (its init)
let path_copied_at : Map[String, Double] = Map([])

///|
fn init {
  @ui.on_reset(fn() { path_copied_at.clear() })
}
