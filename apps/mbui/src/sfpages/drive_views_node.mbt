// The ways a folder of a station's drive is shown on the files' page (still.fail web/src/pages/DriveViews.tsx), switched
// over its list and kept for each place on this device (prefs `driveViews`: `page`, `tab`): columns (a column a
// folder, from where it is to the one open, as Finder's), a tree (folders opened in place, several at once), or a list
// (one folder). Each row is the same (drive_row_node): chosen by a press, opened by a double click, dragged, its menu
// on a right click; the place says what a row does and in what order a folder's entries go (the core's, through the
// place: Browse). How far each folder was scrolled is its list's own, a tree's folders open and a column's width the
// core's. As nodes of the window's tree: a list a page's list of its lines by key, a line made only while it shows.

///|
/// How `place` (page or tab) shows a folder, as last chosen there. The files page starts with the detailed list; a
/// chat's narrower files tab starts with columns where they fit.
pub fn drive_view(src : Source, place : String) -> String {
  // (another way pressed and what it shows not read yet: the one shown till it is, view_press)
  match views_held.get().get(place) {
    Some(v) => return v
    None => ()
  }
  match text(field(src.topic("prefs", {}).get().value, "driveViews"), place) {
    "columns" => "columns"
    "tree" => "tree"
    "list" => "list"
    _ => if place == "page" { "list" } else { "columns" }
  }
}

///|
/// The ways a folder can be shown in a list's room `room` across: columns where two fit side by side (where one
/// alone does, they are a list that says it is columns), a tree and a list wherever.
pub fn views_for(room : Double) -> Array[String] {
  if room >= 2.0 * (column_w + column_gap) {
    ["columns", "tree", "list"]
  } else {
    ["tree", "list"]
  }
}

///|
/// How `place` shows a folder in a list's room `room` across: the way last chosen there where that room can have it,
/// else a list (what was chosen kept: wider, it is back).
pub fn view_in(src : Source, place : String, room : Double) -> String {
  let v = drive_view(src, place)
  if views_for(room).contains(v) {
    v
  } else {
    "list"
  }
}

///|
/// Another way chosen for `place` (`prefs.set {driveViews: {place}}`).
pub fn set_drive_view(src : Source, place : String, v : String) -> Unit {
  let o : Map[String, Json] = Map([])
  o[place] = if place != "page" && v == "columns" { Json::null() } else { Json::string(v) }
  (src.call)("prefs.set", { "driveViews": Json::object(o) }, @sfbase.answer_unread)
}

///|
/// Each place's way shown while another pressed waits for what it shows (view_press), by place; and the one pressed,
/// what the choice shows meanwhile (view_pressed).
// kept across runs: put back by views_held_reset
let views_held : @signals.Signal[Map[String, String]] = @signals.signal(Map([]))

///|
// kept across runs: put back by views_held_reset
let views_pressed : @signals.Signal[Map[String, String]] = @signals.signal(Map([]))

///|
pub fn views_held_reset() -> Unit {
  views_held.set(Map([]))
  views_pressed.set(Map([]))
  cols_drag.set(None)
  cols_every.val = None
  row_menu_up.set("")
}

///|
/// `place`'s entry of a map kept as a signal (`m`) set to `v`, or taken out (None): a new map, told as it changes.
fn views_put(m : @signals.Signal[Map[String, String]], place : String, v : String?) -> Unit {
  let now = m.untracked()
  if now.get(place) == v {
    return
  }
  let next = now.copy()
  match v {
    Some(v) => next[place] = v
    None => next.remove(place)
  }
  m.set(next)
}

///|
/// The way `place`'s choice shows: the one pressed while what it shows is read (view_press), else the one shown.
pub fn view_pressed(place : String, shown : String) -> String {
  views_pressed.get().get(place).unwrap_or(shown)
}

///|
/// Another way pressed for the folder `b` shows (every place of its owner `b.owner`; `others`, the other sides of the
/// files' page as they are shown): kept as chosen at once (set_drive_view), the choice showing it pressed, and every
/// side switched to it once what that way draws is read there (browse_switch: each one's browsing that way, and its
/// folders: columns the way down to the one shown, a tree the one shown and each folder opened in it), the folders
/// shown as they were meanwhile; never a way drawn in its bones, on either side.
pub fn view_press(src : Source, b : Browse, v : String, others? : Array[Browse] = []) -> Unit {
  let place = b.owner
  @signals.untracked(fn() {
    let shown = drive_view(src, place)
    views_put(views_pressed, place, None)
    views_put(views_held, place, None)
    set_drive_view(src, place, v)
    if v == shown {
      // (one pressed before waited for no more: the way shown is the one chosen again)
      browse_switch_off(place)
      return
    }
    views_put(views_held, place, Some(shown))
    views_put(views_pressed, place, Some(v))
    browse_switch(
      src,
      [b, ..others].map(fn(s) { (s, { view: v, at: (s.at)() }) }),
      place,
      fn(to, view) {
        let path = to.at.path
        match v {
          "columns" => {
            let out = [""]
            let mut so_far = ""
            if path != "" {
              for part in path.split("/") {
                so_far = dv_join(so_far, part.to_owned())
                out.push(so_far)
              }
            }
            out
          }
          "tree" => {
            let out = [path]
            match view {
              Some(bv) =>
                for o in bv.open {
                  if path == "" || o.has_prefix(path + "/") {
                    out.push(o)
                  }
                }
              None => ()
            }
            out
          }
          _ => [path]
        }
      },
      fn() {
        views_put(views_held, place, None)
        views_put(views_pressed, place, None)
      },
      let_go=fn() {
        if views_pressed.untracked().get(place) == Some(v) {
          views_put(views_held, place, None)
          views_put(views_pressed, place, None)
        }
      },
    )
  })
}

///|
/// Every way, and each one's icon.
// kept across runs: a table, never written
pub let view_icons : Array[(String, String)] = [("columns", "view-columns"), ("tree", "view-tree"), ("list", "list")]

///|
/// The ways the room has (`ways`: views_for's), side by side (ViewSwitch), in `parent`: a choice of their icons among
/// the bar's buttons, each its tip; `value` the one shown (chosen again where the room has not what was chosen before).
pub fn view_switch_node(
  parent : @view.View,
  ways : () -> Array[String],
  value : () -> String,
  on_change : (String) -> Unit,
  tips? : @sf.TipLayer,
) -> Unit {
  @sf.seg_icons_node(
    parent,
    fn() {
      view_icons.filter(fn(w) { ways().contains(w.0) }).map(fn(w) { (w.0, w.1, @sf.t("web-pages.drive.view." + w.0)) })
    },
    value,
    on_change,
    said=@sf.t("web-pages.drive.view.label"),
    tips?,
  )
  |> ignore
}

// ── a list, a tree ──

///|
/// A line of a list or a tree as drawn: an entry (its folder, its depth in a tree, whether it is a folder opened there),
/// or a line about a folder not listed (being read, empty, refused) at its depth; and the room under its last line, an
/// empty folder's words.
#derive(Eq)
priv enum Line {
  Row(DriveAt, DvEntry, Int, Bool?)
  Note(String, Bool, Int)
  Reading(Int)
  Empty
}

///|
/// A line as it is listed: its key, what it is, the piece of the card it is (narrow: on a card, its first and last
/// carrying its corners).
#derive(Eq)
priv struct LineAt {
  key : String
  line : Line
  piece : @sf.CardPiece
}

///|
/// A folder and, under each of its folders opened, that one's, in by a step each (TreeView, TreeFolder): its lines.
fn tree_lines(s : Shown, at : DriveAt, depth : Int, out : Array[Line], empty : Bool) -> Unit {
  let src = s.src
  let (value, error) = s.b.folder(src, at)
  match error {
    Some(e) => {
      out.push(Note(e, true, depth))
      return
    }
    None => ()
  }
  let entries = match value {
    Some(_) => s.b.arranged(src, at.path)
    None => None
  }
  match entries {
    None => out.push(Reading(depth))
    Some([]) => if !(depth == 0 && empty) { out.push(Note(@sf.t("web-pages.drive.emptyFolder"), false, depth)) }
    Some(list) =>
      for e in list {
        let full = dv_join(at.path, e.name)
        let open = e.dir && s.b.is_open(src, full)
        out.push(Row(at, e, depth, if e.dir { Some(open) } else { None }))
        if open {
          tree_lines(s, { ..at, path: full }, depth + 1, out, false)
        }
      }
  }
}

///|
/// The rows of a list or a tree (`tree`: folders opened in place) of the folder `at` in node `parent` (filling it),
/// in a page's list of their own: `head` over them (in what scrolls), `empty` where the folder has nothing, `foot` the
/// room under the last (the frame's). The row asked into view (a key moved to it, a new folder named) brought there, as
/// near as it needs to come. Each line a block made only while it shows, by its key: an entry by its folder and name,
/// one made, taken out or moved coming and going where it is. On a card of pieces (card_piece_node), but where not
/// `card`: on the ground they stand on (a chat's 文件 tab's, in a panel).
pub fn rows_view_node(
  parent : @view.View,
  s : Shown,
  at : DriveAt,
  tree : Bool,
  compact? : Bool = false,
  card? : Bool = true,
  head? : (@view.View) -> Unit,
  empty? : (@view.View) -> Unit,
  foot? : () -> Double = fn() { 0.0 },
  pad? : (Double, Double, Double, Double),
) -> Unit {
  let src = s.src
  let lines = fn() -> Array[LineAt] {
    let got : Array[Line] = []
    if tree {
      tree_lines(s, at, 0, got, empty is Some(_))
    } else {
      let (value, _) = s.b.folder(src, at)
      if value is Some(_) {
        match s.b.arranged(src, at.path) {
          Some(list) =>
            for e in list {
              got.push(Row(at, e, 0, None))
            }
          None => ()
        }
      }
    }
    let n = got.length()
    let out = got.mapi(fn(i, l) {
      let key = match l {
        Row(a, e, _, _) => "r/" + row_key(a.path, e.name)
        Note(w, _, d) => "n/" + d.to_string() + "/" + w
        Reading(d) => "w/" + d.to_string() + "/" + i.to_string()
        Empty => "empty"
      }
      { key, line: l, piece: @sf.card_piece_of(i, n) }
    })
    if n == 0 && empty is Some(_) {
      out.push({ key: "empty", line: Empty, piece: CardWhole })
    }
    out
  }
  parent.box(fn(l) {
    l.transitions_only().grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    match pad {
      Some(p) => l.padding(Is(p)) |> ignore
      None => ()
    }
    let folder_loaded = fn() {
      let (value, _) = s.b.folder(src, at)
      value is Some(_) && s.b.arranged(src, at.path) is Some(_)
    }
    let shown_lines = @signals.signal(@signals.untracked(lines))
    let was_loaded = Ref(@signals.untracked(folder_loaded))
    l.reacts(
      fn() { (lines(), folder_loaded()) },
      fn(pair) {
        let (next, loaded_now) = pair
        let was_keys = shown_lines.untracked().map(fn(x) { x.key })
        let next_keys = next.map(fn(x) { x.key })
        let live = was_loaded.val && loaded_now && was_keys != next_keys && !@view.answering_now()
        was_loaded.val = loaded_now
        if live {
          @view.transition(within=l, fn() { shown_lines.set(next) })
        } else {
          shown_lines.set(next)
        }
      },
      at_start=false,
    )
    let keyed = l.keyed_by(fn() { shown_lines.get() }, fn(x) { x.key })
    let place : @view.ListPlace[String] = @view.ListPlace::new()
    // a row asked into view (a key moved to it), or the one being named, and that one again as the room the list has
    // changes (the soft keyboard up, the list shorter: it comes up over it): as near as it needs to come
    l.reacts(fn() {
      match s.b.to_show() {
        Some(w) => (Some(w), 0.0)
        None =>
          match s.b.renaming() {
            Some(w) => (Some(w), l.window_h())
            None => (None, 0.0)
          }
      }
    }, fn(want) {
      match want.0 {
        Some(w) => {
          place.bring("r/" + w, glide=true)
          // (and once the room it is given is laid out as it changed: what covers it come, the list shorter)
          l.at_moment(l.cause_at() + 1.0, fn() { if s.b.renaming_now() == Some(w) { place.centre("r/" + w) } }) |> ignore
          s.b.shown_done()
        }
        None => ()
      }
    })
    l.scrolls_window(
      @view.Scroll::list(),
      fn() { keyed.keys() },
      est=if compact { row_compact_est } else { row_est },
      slop=@ui.touch_slop(),
      bar=@ui.tree_scroll_bar(),
      place~,
      head?=match head {
        Some(h) => Some(fn(hv : @view.View) { h(hv) })
        None => None
      },
      foot=fn(f) { f.height(By(fn() { Some(rows_foot + foot()) })) |> ignore },
      fn(b, k) {
        guard @signals.untracked(fn() { keyed.get(k) }) is Some(first) else { return }
        let now = fn() { keyed.get(k).unwrap_or(first) }
        match first.line {
          Empty =>
            match empty {
              Some(f) => f(b)
              None => ()
            }
          _ => {
            let on = fn(make : (@view.View) -> Unit) {
              if card {
                @sf.card_piece_node(b, fn() { now().piece }, make)
              } else {
                make(b)
              }
            }
            on(fn(r) {
              match first.line {
                Row(a, e0, depth, _) => {
                  let e = fn() {
                    match now().line {
                      Row(_, e, _, _) => e
                      _ => e0
                    }
                  }
                  drive_row_node(
                    r,
                    s,
                    a,
                    e,
                    compact~,
                    depth?=if tree { Some(depth) } else { None },
                    expanded=fn() {
                      match now().line {
                        Row(_, _, _, Some(o)) => o
                        _ => false
                      }
                    },
                    on_toggle=fn() { s.b.toggle(src, dv_join(a.path, e0.name)) },
                  )
                }
                Note(words, error, depth) =>
                  r.box(fn(n) {
                    @sf.style_node(n, fn() { tree_note })
                    n.box(fn(i) { i.width(Is(Some(tree_note_in + tree_step * depth.to_double()))).shrink(Is(0.0)) |> ignore }) |> ignore
                    @sf.words_node(n, fn() { words }, fn() { if error { tree_error } else { tree_words } }) |> ignore
                  })
                  |> ignore
                Reading(depth) =>
                  r.box(fn(n) {
                    @sf.style_node(n, fn() { tree_note })
                    n.box(fn(i) { i.width(Is(Some(tree_note_in + tree_step * depth.to_double()))).shrink(Is(0.0)) |> ignore }) |> ignore
                    @sf.wait_line_node(n, fn() { "" }) |> ignore
                  })
                  |> ignore
                Empty => ()
              }
            })
          }
        }
      },
    )
    |> ignore
  })
  |> ignore
}

///|
/// A folder's rows to come while it is read the first time (the library's Waiting, in its bones), in `parent`: `count`
/// rows as rows_view_node draws them (on a card but where not `card`), of made-up names, a couple of folders first.
pub fn rows_sample_node(parent : @view.View, s : Shown, at : DriveAt, count : Int, compact? : Bool = false, card? : Bool = true) -> Unit {
  @sf.waiting_node(parent, fn(w) {
    // (keep driveBrowse watched after head during pre-order Tree::rest_in while still in "reading",
    // matching "list" and post-order View::let_go so drive unsubscribes before driveBrowse at every FPS)
    w.reacts(fn() { s.b.shown(s.src) is Some(_) }, fn(_) {  })
    for i in 0..<count {
      let (dir, name) = rows_sample_names[i % rows_sample_names.length()]
      let e = @sfbase.dv_entry({
        "name": Json::string(@sf.sample_words(name) + (if dir { "" } else { ".md" })),
        "dir": Json::boolean(dir),
        "sizeText": Json::string(if dir { "" } else { @sf.sample_words(3) }),
        "timeText": Json::string(@sf.sample_words(4)),
      })
      let row = fn(r : @view.View) {
        drive_row_node(r, { ..s, src: @sfbase.sample_source, row_of: fn(_, _) { rows_sample_props } }, at, fn() { e }, compact~)
      }
      if card {
        @sf.card_piece_node(w, fn() { @sf.card_piece_of(i, count) }, row)
      } else {
        row(w)
      }
    }
  })
}

///|
/// What a made-up row does: nothing.
// kept across runs: a value (nothing in it changes)
let rows_sample_props : RowOf = {
  items: fn() { [] },
  open: fn() {  },
  press: fn() {  },
  menu: fn() {  },
  chosen: fn() { false },
  renaming: fn() { false },
  rename: fn(_) {  },
  drop: None,
}

///|
/// Whether each made-up row is a folder, and how long its name is (letters).
// kept across runs: a table, never written
let rows_sample_names : Array[(Bool, Int)] = [(true, 4), (true, 6), (false, 9), (false, 5), (false, 12), (false, 7), (false, 8), (false, 6)]

///|
/// Under the last row (the phone's contentPadding: 30), over the frame's room.
let rows_foot : Double = 30.0

///|
/// A list's rows, as tall as they mostly are (row 44 and the list's gap 2; compact 36 and 2), till they are laid out.
let row_est : Double = 46.0

///|
let row_compact_est : Double = 38.0

///|
/// A tree's line about a folder not listed (treeNote): 8 over and under, in by 46 and a step a depth (18), its words
/// the meta's; a column's, in by its rows' padding.
let tree_note_in : Double = 46.0

///|
// kept across runs: a value (no field of it changes)
let tree_note : @ui.Style = @ui.css("row w=Full pt=S2 pb=S2 pr=S2_5")

///|
// kept across runs: a value (no field of it changes)
let column_note : @ui.Style = tree_note.then(@ui.css("pl=S2_5"))

///|
// kept across runs: a value (no field of it changes)
let tree_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let tree_error : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger, w=Full)

// ── columns ──

///|
/// A column's width: as wide as every column is until one is dragged (240 until all are, kept on this device), 160 to
/// 640.
pub let column_w : Double = 240.0

///|
let column_least : Double = 160.0

///|
let column_most : Double = 640.0

///|
/// Between two columns, where an edge is.
pub let column_gap : Double = 6.0

///|
fn clamp_column(px : Double) -> Double {
  let w = px.round()
  if w < column_least {
    column_least
  } else if w > column_most {
    column_most
  } else {
    w
  }
}

///|
/// A column being dragged wider or narrower (its place's key, the folder's path or None with ⌥ held: every one; the
/// width), told as it changes.
// kept across runs: put back by views_held_reset
let cols_drag : @signals.Signal[(String, String?, Double)?] = @signals.signal(None)

///|
/// Every column's width as just dragged until the kept one comes back (what the prefs said then, and it).
// kept across runs: put back by views_held_reset
let cols_every : Ref[(String, Double)?] = Ref(None)

///|
/// Every column's width: as kept on this device (prefs `driveViews.column`), or as just dragged until the kept one
/// comes back.
fn every_column(src : Source) -> Double {
  let kept = text(field(src.topic("prefs", {}).get().value, "driveViews"), "column")
  match cols_every.val {
    Some((was, w)) if was == kept => return w
    _ => ()
  }
  match (@json.parse(kept) catch { _ => Json::null() }) {
    Number(w, ..) if w > 0.0 => w
    _ => column_w
  }
}

///|
/// The columns' paths, from the one they start at (`at.path`, "" under its root) to the one open (`open`, under it).
fn column_paths(at : DriveAt, open : String) -> Array[String] {
  let paths = [at.path]
  let mut so_far = at.path
  if open != "" {
    for p in open.split("/") {
      so_far = dv_join(so_far, p.to_owned())
      paths.push(so_far)
    }
  }
  paths
}

///|
/// A column a folder (ColumnsView), in node `parent` (as tall as it), from the one it starts at (`at`) to the one open
/// (`open()`, under it), each with the next open marked; a folder pressed opens next to its column, the columns after
/// it let go. As many as its room holds, the last ones (as the web's strip keeps the last in view): those that do not
/// fit laid out nowhere. Each column takes what is dropped on it into its folder. Its edge, dragged, makes it wider or
/// narrower (with ⌥ held every column; a double click as wide as its longest name). `empty`: what the last column shows
/// where its folder has nothing.
pub fn columns_view_node(
  parent : @view.View,
  s : Shown,
  at : DriveAt,
  open : () -> String,
  empty? : (@view.View) -> Unit,
) -> Unit {
  let src = s.src
  let paths = fn() { column_paths(at, open()) }
  let width_of = fn(p : String) {
    match cols_drag.get() {
      Some((k, whose, px)) if k == s.b.key && (whose is None || whose == Some(p)) => px
      _ => s.b.width_of(src, p).unwrap_or(every_column(src))
    }
  }
  parent.box(fn(strip) {
    @sf.style_node(strip, fn() { columns_strip })
    strip.by_room(fn(held, room) {
      held.row(Is(true)).height(By(fn() { room.height() })) |> ignore
      // (the first of them shown: as many of the last as its room holds)
      let from = fn() {
        let ps = paths()
        let ws = ps.map(width_of)
        let mut from = ps.length() - 1
        let mut used = ws[from] + column_gap
        while from > 0 && used + ws[from - 1] + column_gap <= room.width() {
          from -= 1
          used += ws[from] + column_gap
        }
        from
      }
      held.each(fn() { paths() }, fn(p) { p }, fn(c, p) {
        let path = p.untracked()
        let index = fn() { paths().search(path).unwrap_or(0) }
        c.row(Is(true)).height(Is(None)).laid_nowhere(By(fn() { index() < from() })) |> ignore
        let next = fn() {
          let ps = paths()
          let i = index()
          if i + 1 < ps.length() { Some(dv_name(ps[i + 1])) } else { None }
        }
        let last = fn() { index() == paths().length() - 1 }
        column_node(c, s, { ..at, path, }, next, fn() { width_of(path) }, last, empty)
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// A column of the folder `at` in `parent`, `width` wide, the folder open beside it (`next`) marked; its edge after it.
fn column_node(
  parent : @view.View,
  s : Shown,
  at : DriveAt,
  next : () -> String?,
  width : () -> Double,
  last : () -> Bool,
  empty : ((@view.View) -> Unit)?,
) -> Unit {
  let src = s.src
  let root = at.root.unwrap_or("")
  let ckey = "files/column/" + s.b.key + "/" + at.station + "/" + root + "/" + at.path
  parent.box(fn(col) {
    @sf.style_node(col, fn() { column_box })
    col.width(By(fn() { Some(width()) })) |> ignore
    let lit = match (s.drop_on)(at) {
      Some(into) => drop_target_node(col, src, ckey, Some(into), dv_name(dv_absolute(root, at.path)), s.write, s.transfers, 1)
      None => fn() { None }
    }
    col.ground(By(fn() { if lit() is Some(_) { @ui.tree_theme().color(AccentBg) } else { 0L } })) |> ignore
    // (round at its top only while something is held over it: at rest it is no box of its own, flush with its card's
    // foot without a corner to stand in its card's)
    col.corners(By(fn() { if lit() is Some(_) { Some((column_top, column_top, column_foot, column_foot)) } else { None } })) |> ignore
    // a press in it where there is no row: nothing chosen
    col.presses(Is(true)).on_press(s.clear) |> ignore
    let shows = fn() {
      let (value, error) = s.b.folder(src, at)
      match (value, error) {
        (_, Some(_)) => 1
        (None, None) => 2
        (Some(_), None) =>
          match s.b.arranged(src, at.path) {
            None => 2
            Some([]) => 3
            Some(_) => 4
          }
      }
    }
    col.pick(shows, fn(b, k) {
      match k {
        1 =>
          b.box(fn(n) {
            @sf.style_node(n, fn() { column_note })
            @sf.words_node(n, fn() { drive_folder(src, at.station, root, at.path).1.unwrap_or("") }, fn() { tree_error }) |> ignore
          })
          |> ignore
        2 =>
          b.box(fn(n) {
            @sf.style_node(n, fn() { column_note })
            @sf.wait_line_node(n, fn() { "" }) |> ignore
          })
          |> ignore
        3 =>
          b.pick(last, fn(e, is_last) {
            match empty {
              Some(f) if is_last => f(e)
              _ =>
                e.box(fn(n) {
                  @sf.style_node(n, fn() { column_note })
                  @sf.words_node(n, fn() { @sf.t("web-pages.drive.emptyFolder") }, fn() { tree_words }) |> ignore
                })
                |> ignore
            }
          })
        _ => {
          let list = fn() { s.b.arranged(src, at.path).unwrap_or([]) }
          b.transitions_only().grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          let shown_list = @signals.signal(@signals.untracked(list))
          b.reacts(
            list,
            fn(next) {
              let was_keys = shown_list.untracked().map(fn(e) { e.name })
              let next_keys = next.map(fn(e) { e.name })
              if was_keys != next_keys && !@view.answering_now() {
                @view.transition(within=b, fn() { shown_list.set(next) })
              } else {
                shown_list.set(next)
              }
            },
            at_start=false,
          )
          let keyed = b.keyed_by(fn() { shown_list.get() }, fn(e) { e.name })
          let place : @view.ListPlace[String] = @view.ListPlace::new()
          b.reacts(fn() { s.b.to_show() }, fn(want) {
            match want {
              Some(w) if w.has_prefix(at.path + "\n") => {
                place.bring(w.exact_view(start=at.path.length() + 1).to_owned(), glide=true)
                s.b.shown_done()
              }
              _ => ()
            }
          })
          b.scrolls_window(
            @view.Scroll::list(),
            fn() { keyed.keys() },
            est=row_compact_est,
            slop=@ui.touch_slop(),
            bar=@ui.tree_scroll_bar(),
            place~,
            fn(r, name) {
              guard @signals.untracked(fn() { keyed.get(name) }) is Some(first) else { return }
              let e = fn() { keyed.get(name).unwrap_or(first) }
              drive_row_node(r, s, at, e, compact=true, column=true, along=fn() { next() == Some(name) })
            },
          )
          |> ignore
        }
      }
    })
  })
  |> ignore
  column_edge_node(parent, s, at.path, width, fn() {
    s.b.arranged(src, at.path).unwrap_or([]).map(fn(e) { e.name })
  })
}

///|
/// A column's edge (ColumnEdge: the library's edge, as the app's other columns' edges are), `width` wide now, after
/// it in `parent`: dragged, its width, or with ⌥ held every column's (kept on this device as it is let go); pressed
/// twice, as wide as its longest name needs.
fn column_edge_node(parent : @view.View, s : Shown, path : String, width : () -> Double, names : () -> Array[String]) -> Unit {
  let src = s.src
  parent.box(fn(room) {
    @sf.style_node(room, fn() { column_edge_room }, in_row=true)
    @sf.edge_node(
      room,
      fn() { @sf.t("web-pages.drive.resizeColumn") },
      width,
      fn() { column_least },
      fn() { column_most },
      Right,
      fn(said, _at) {
        let every = (@ui.mods_held() & @ui.mod_alt) != 0
        match said {
          Dragging(w) => cols_drag.set(Some((s.b.key, if every { None } else { Some(path) }, w)))
          Dropped(w) => {
            let was_every = match cols_drag.untracked() {
              Some((_, whose, _)) => whose is None
              None => false
            }
            cols_drag.set(None)
            if every || was_every {
              // every column as wide, kept on this device
              s.b.forget_widths(src)
              let kept = if w == column_w { Json::null() } else { Json::string(w.to_int().to_string()) }
              cols_every.val = Some((match kept { String(k) => k; _ => "" }, w))
              (src.call)("prefs.set", { "driveViews": { "column": kept } }, @sfbase.answer_unread)
            } else {
              s.b.keep_width(src, path, w)
            }
          }
          Twice => {
            let need = names().fold(init=0.0, fn(m, n) { dmax(m, @ui.text_advance(n, size=@sf.theme().t.ui)) })
            if need > 0.0 {
              s.b.keep_width(src, path, clamp_column(need + column_row_room))
            }
          }
          _ => ()
        }
      },
      fn(_) {  },
    )
    |> ignore
  })
  |> ignore
}

///|
/// A column's row about its name (a compact row: 10 in, its mark 18, 10, the name, 10, its size's room, 10, 28, 10 in;
/// and a point, as the web's fit adds one).
let column_row_room : Double = 97.0

///|
/// The columns side by side, as tall as the list.
// kept across runs: a value (no field of it changes)
let columns_strip : @ui.Style = @ui.css("row w=Full h=Full")

///|
/// A column (column): as tall as the strip, its rows 2 apart; lit while a drop goes into it, its top's corners the
/// field's then (column_node), its foot square (it goes on past the page's foot, its rows scrolling under it).
// kept across runs: a value (no field of it changes)
let column_box : @ui.Style = @ui.css("h=Full")

///|
/// Its top's corners (the field's, Xl) and its foot's.
let column_top : Double = 12.0

///|
let column_foot : Double = 0.0

///|
/// An edge: as wide as the gap between two columns (6), the library's look from its left.
// kept across runs: a value (no field of it changes)
let column_edge_room : @ui.Style = @ui.style(w=Fixed(column_gap), h=Full)
