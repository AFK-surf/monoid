// 已归档 made once as nodes (ArchivePage; the narrow app's Archive.kt), laid out by the width its frame gives it
// (page_node): the core's `archive`, chats archived by hand or by their station once they idled, of every station online
// in one list, newest first by the day they were archived. Each opened to read (its composer restores it), put back in
// the list (`chat.archive` with archived false), and one whose agents are done deleted for good (`session.delete`). Only
// those with the words looked for, and the newest so many, a page more as the list comes near the last of them while
// the core says it has more (`more`); the words and the limit are the page's own, gone with it. Each day's heading is a
// block of the page's list and each chat one under it, so the list makes only what shows. The rows stand on the page's
// ground, as the chats' list's do, not on a card: their 恢复 and 删除 always shown at their first line's end (no hover
// to find them by a finger), round keys a card's corner would hold to its own (the corner rule).

///|
/// How many the archive asks for at first, and how many more each time its list comes near the last of them
/// (Topics.ARCHIVE_PAGE; sfbase's page_reads asks the same).
let archive_page_size : Int = 60

///|
/// 已归档 made once in node `v`, as wide as `width` says (narrow where none is given).
pub fn archive_node(
  v : @view.View,
  core : Core,
  here : () -> @settings.Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  // (the words looked for and how many are asked: the page's own, as the old view's were while it was on the stack)
  let q : @signals.Signal[String] = @signals.signal("")
  let limit : @signals.Signal[Int] = @signals.signal(archive_page_size)
  let asked = fn() -> Map[String, Json] {
    let p : Map[String, Json] = { "scope": Json::string(here().workspace) }
    if q.get() != "" {
      p["q"] = Json::string(q.get())
    }
    p["limit"] = Json::number(limit.get().to_double())
    p
  }
  let read = fn() { (core.topic)("archive", asked()).get() }
  // (what the core last answered: shown while what is asked now (other words, a page more) has not come)
  // (the core's value, a new JSON each time it changes: told by its object)
  let last : @signals.Signal[Json?] = @signals.signal_by(None, same=fn(a, b) { physical_equal(a, b) })
  v.reacts(read, fn(r) {
    match r.value {
      Some(_) as now => last.set(now)
      None => ()
    }
  })
  let view = fn() { last.get() }
  let days = fn() { items(view(), "days") }
  let wait = fn() { field(view(), "wait") }
  let reading = fn() { view() is None || (days().length() == 0 && note_waits(wait())) }
  // (each block by what it is: each chat by its station and session; kept by key as the core's value changes, so a
  // block reading its own is told only as that one changes, comes or goes: View::keyed_by)
  let listed : @signals.KeyedList[String, (String, ArchivePart)] = v.keyed_by(
    fn() {
      let out : Array[(String, ArchivePart)] = []
      for d in days() {
        let label = text(Some(d), "label")
        out.push(("day/" + label, ArchiveDay(label)))
        for it in items(Some(d), "items") {
          out.push(("row/" + text(Some(it), "station") + "/" + text(Some(it), "session"), ArchiveRow(it)))
        }
      }
      out
    },
    fn(e) { e.0 },
    same=archive_entry_same,
  )
  let blocks = fn() {
    let out = ["search"]
    if reading() {
      out.push("wait")
      return out
    }
    for i, _ in items(view(), "errors") {
      out.push("error/" + i.to_string())
    }
    if text(view(), "note") != "" {
      out.push("note")
    }
    if days().length() == 0 && q.get() == "" {
      out.push("empty")
    }
    out.append(listed.keys())
    out
  }
  // (a day's heading (kind 1) or a chat (kind 0) in `b`, of the key `key()` says now, as the list says it, what it
  // was last while its key goes)
  let part_node = fn(b : @view.View, kind : Int, key : () -> String) {
    if kind == 1 {
      // (its words on the page's title's line, as its rows' words are: archive_row_node)
      let was = Ref("")
      @sf.day_heading_node(b, fn() {
        match listed.get(key()) {
          Some((_, ArchiveDay(l))) => was.val = l
          _ => ()
        }
        was.val
      }, wide_in=0.0)
    } else {
      let was : Ref[Json] = Ref(Json::null())
      let row = @signals.computed(fn(_) {
        match listed.get(key()) {
          Some((_, ArchiveRow(i))) => was.val = i
          _ => ()
        }
        was.val
      }, same=json_same)
      archive_row_node(b, core, fn() { row.get() }, tips?)
    }
  }
  // (near the last it holds while the core has more: a page more, once for what was answered)
  let more = fn() { flag(view(), "more") && read().value is Some(_) }
  let ask_more = fn() { limit.set(limit.untracked() + archive_page_size) }
  @sf.page_node(
    v,
    fn() { @sf.t("android-misc.bar.place.archive") },
    on_back~,
    frame~,
    said?,
    width?,
    tips?,
    near_foot=(1.5, more, ask_more),
    blocks,
    fn(b, key) {
      match key {
        "search" => archive_search_node(b, q, fn() { limit.set(archive_page_size) })
        "wait" =>
          @sf.waiting_node(
            b,
            fn(s) { archive_sample_node(s, core) },
            error=fn() {
              match (view(), read().error) {
                (None, Some(e)) => error_text(e)
                _ => ""
              }
            },
            note=fn() {
              { reading: true, text: "", failing: @settings.failing_of(wait()) }
            },
          )
        "note" => @sf.page_said_node(b, fn() { text(view(), "note") })
        "empty" => @sf.page_said_node(b, fn() { @sf.t("android-misc.archive.note") })
        _ if key.has_prefix("error/") => {
          let i = key.exact_view(start=6).iter().fold(init=0, fn(n, ch) { n * 10 + (ch.to_int() - '0'.to_int()) })
          @sf.page_said_node(b, fn() { text(items(view(), "errors").get(i), "text") }, bad=true)
        }
        // (made once for its key alone where the list takes none: its kind by its key)
        _ => part_node(b, if key.has_prefix("day/") { 1 } else { 0 }, fn() { key })
      }
    },
    // (a day's heading or a chat put by as it leaves what shows and taken by the next of its kind, reading the key it
    // shows now)
    reused=fn(k) {
      if k.has_prefix("row/") {
        Some(0)
      } else if k.has_prefix("day/") {
        Some(1)
      } else {
        None
      }
    },
    make_reused=part_node,
  )
}

///|
/// The same block of the archive's list: its key, and what it is the same (a chat's JSON as json_same says).
fn archive_entry_same(a : (String, ArchivePart), b : (String, ArchivePart)) -> Bool {
  a.0 == b.0 &&
  (match (a.1, b.1) {
    (ArchiveDay(x), ArchiveDay(y)) => x == y
    (ArchiveRow(x), ArchiveRow(y)) => json_same(x, y)
    _ => false
  })
}

///|
/// What a block of the archive's list is: a day's heading, or one of its chats.
#derive(Eq)
priv enum ArchivePart {
  ArchiveDay(String)
  ArchiveRow(Json)
}

///|
/// Whether the archive's note says it still waits for a station (failing_of's, the settings' parts).
fn note_waits(note : Json?) -> Bool {
  match note {
    Some(Object(_)) => flag(note, "reading") || @settings.failing_of(note).length() > 0
    _ => false
  }
}

///|
/// Looking for one by its title or last line (ArchiveSearch) in `parent`: the library's field to look through a list by
/// (@sf.search_input_node); what it holds the page's words looked for (`q`, trimmed), `asked_again` as they change (the first page again).
fn archive_search_node(parent : @view.View, q : @signals.Signal[String], asked_again : () -> Unit) -> Unit {
  let own = @ui.Field::new(text=q.untracked())
  parent.box(fn(page) {
    @sf.style_node(page, fn() { archive_search_page })
    page.reacts(fn() { own.text() }, fn(w) {
      let trimmed = w.trim(chars=" \t\n").to_owned()
      if trimmed != q.untracked() {
        q.set(trimmed)
        asked_again()
      }
    })
    @sf.search_input_node(page, own, fn() { @sf.t("web-pages.archive.search") }) |> ignore
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let archive_search_page : @ui.Style = @ui.css("w=Full pb=S3")

///|
/// An archived chat (ArchiveRow) in `r`, `it` as it is now: its title, where and when at its first line's end, the
/// rows' one column (read out as how it was archived, `how`, its tip in `tips` where there are tips), then 恢复 and 删除
/// (one under way: turning; one that failed: why, by its mark); its last message the line under it. Pressed, its chat
/// (read there, restored from its composer).
fn archive_row_node(r : @view.View, core : Core, it : () -> Json, tips? : @sf.TipLayer) -> Unit {
  let v = fn() { Some(it()) }
  let station = fn() { text(v(), "station") }
  let session = fn() { text(v(), "session") }
  let title = fn() { text(v(), "title") }
  let busy = fn() {
    @settings.is_doing(core, ["chat.archive"], [("station", station()), ("session", session())]) ||
    @settings.is_doing(core, ["session.delete"], [("station", station()), ("key", session())])
  }
  let failed = fn() {
    match @settings.failed_of(core, ["chat.archive"], [("station", station()), ("session", session())]) {
      Some(f) => Some(f)
      None => @settings.failed_of(core, ["session.delete"], [("station", station()), ("key", session())])
    }
  }
  // (its menu where the pointer's other button is pressed on it: its chat opened, restored as its 恢复 does, and where
  // it can be, deleted for good as its 删除 does, after a line and in red; restoring and deleting not while one is
  // under way)
  r.on_menu(fn(m) {
    let i = @signals.untracked(v)
    let doing = @signals.untracked(busy)
    let items : Array[@sf.MenuItem?] = [
      Some(
        @sf.menu_item_of(
          @sf.t("web-pages.rowMenu.openChat"),
          fn() { (core.open_chat)(text(i, "station"), text(i, "session"), text(i, "title")) },
          icon="chat",
        ),
      ),
      Some(@sf.menu_item_of(@sf.t("web-pages.rowMenu.restore"), fn() { archive_restore_from(core, i) }, icon="retry", disabled=doing)),
    ]
    if flag(i, "deletable") {
      items.push(None)
      items.push(Some(@sf.menu_item_of(@sf.t("common.delete"), fn() { archive_delete_from(core, i) }, icon="trash", danger=true, disabled=doing)))
    }
    @sf.menu(items, from=@sf.at_point(m.wx, m.wy))
  })
  |> ignore
  // (on the page's ground, no card under it: its words on the page's title's line, as the day's heading's are)
  @sf.ground_row_node(r, fn(row) {
    @sf.link_row_node(
      row,
      title,
      fn() {
        let i = @signals.untracked(v)
        (core.open_chat)(text(i, "station"), text(i, "session"), text(i, "title"))
      },
      // (where and when at its first line's end, before its keys: the rows' one column, as the old row's; the title
      // giving way to it, cut short; read out as how it was archived, ArchiveRow's contentDescription = item.how)
      tail=fn(a) {
        let how = fn() { text(v(), "how") }
        a.says(By(fn() { if how() == "" { None } else { Some(@view.said(Text, label=how())) } })) |> ignore
        @sf.words_node(a, fn() { [text(v(), "place"), text(v(), "clock")].filter(fn(s) { s != "" }).join("  ") }, fn() {
          archive_when
        })
        |> ignore
        match tips {
          Some(t) => @sf.tip_node(t, a, how, within=true) |> ignore
          None => ()
        }
      },
      note=fn() { text(v(), "last") },
      note_cut=true,
      title_cut=true,
      chevron=false,
      control=fn(c) {
        c.box(fn(keys) {
          keys.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
          keys.pick(busy, fn(k, on) {
            k.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
            if on {
              archive_key_box(k, fn(s) { @sf.spinner_node(s) |> ignore })
              return
            }
            k.show(fn() { failed() is Some(_) }, fn(f) { archive_key_box(f, fn(m) { doing_mark_node(m, fn() { false }, failed) }) })
            // (the last of them in the row's top end corner: 删除, or 恢复 where it cannot be deleted)
            archive_key_node(
              k,
              "retry",
              fn() { @sf.t("android-misc.archive.restoreNamed", args=[("title", title())]) },
              fn() { archive_restore_from(core, @signals.untracked(v)) },
              fn() { !flag(v(), "deletable") },
            )
            k.show(fn() { flag(v(), "deletable") }, fn(d) {
              archive_key_node(
                d,
                "trash",
                fn() { @sf.t("android-misc.archive.deleteNamed", args=[("title", title())]) },
                fn() { archive_delete_from(core, @signals.untracked(v)) },
                fn() { true },
              )
            })
          })
        })
        |> ignore
      },
    )
  })
}

///|
/// A key of a row's first line (its 恢复, its 删除) in `parent`: 34 across, as high as that line is drawn (the system's
/// size of words applied), so it stands on it and over none of the line under it; round at its ends, its `icon` 16 in
/// the muted ink in its middle, rippling as it is pressed; read out a button named `label()`, `press` done then.
/// The last of a narrow row's keys (`last()`) stands in the row's top end corner, as far in from its top as from its
/// end (the row's text_in): its ground, lit as it is pointed at or pressed, grows over, under and past it till it stands
/// corner_inset in, round by small_corner, concentric with the row's (row_corner) as the corner rule has it at any
/// size of words; its icon and the line it stands on where they were (row_corner_button_node's way).
fn archive_key_node(
  parent : @view.View,
  icon : String,
  label : () -> String,
  press : () -> Unit,
  last : () -> Bool,
) -> Unit {
  @sf.ripple_button_node(parent, label, press, fn(k, _) {
    let corner = archive_key_look(k, last)
    @sf.icon_node(k, icon, archive_key_icon, By(fn() { @sf.theme().p.muted })) |> ignore
    By(corner)
  })
  |> ignore
}

///|
/// The room of a row's key that takes no press (its spinner, its failure's mark) in `parent`, as archive_key_look lays
/// it out, what `inside` makes in its middle.
fn archive_key_box(parent : @view.View, inside : (@view.View) -> Unit) -> Unit {
  parent.box(fn(k) {
    archive_key_look(k, fn() { false }) |> ignore
    inside(k)
  })
  |> ignore
}

///|
/// A row's key `k` laid out (archive_key_node's): 34 across, as high as the row's first line, what it holds in its
/// middle; grown into the row's corner where it is the `last` there. How round it is, as it changes.
fn archive_key_look(k : @view.View, last : () -> Bool) -> () -> Double {
  let line = fn() { @sf.node_sp(k, @ui.tree_theme().text_size(Body).1) }
  let grown = fn() { if last() { @sf.row_end_key_grown(k) } else { 0.0 } }
  let corner = fn() { if grown() > 0.0 { @sf.small_corner } else { line() / 2.0 } }
  k
  .width(By(fn() { Some(archive_key_w + grown()) }))
  .height(By(fn() { Some(line() + 2.0 * grown()) }))
  .margin(By(fn() { (0.0, -grown(), -grown(), -grown()) }))
  .padding(By(fn() { (0.0, 0.0, grown(), 0.0) }))
  .radius(By(corner))
  .lines_up(Is(Some(Middle)))
  .lies_along(Is(Middle))
  |> ignore
  corner
}

///|
/// Where and when it was archived after a row's title: the caption's size, subtle, on one line.
// kept across runs: a value (no field of it changes)
let archive_when : @ui.TextStyle = @ui.text_style(size=Caption, color=Subtle, wrap=false)

///|
/// A row's 恢复 and 删除: 34 across, their marks 16.
let archive_key_w : Double = 34.0

///|
let archive_key_icon : Double = 16.0

///|
/// Put back in the list (`chat.archive` with archived false), said once done.
fn archive_restore_from(core : Core, v : Json?) -> Unit {
  let p : Map[String, Json] = {
    "station": Json::string(text(v, "station")),
    "session": Json::string(text(v, "session")),
    "archived": Json::boolean(false),
  }
  match field(v, "thread") {
    Some(Number(_, ..) as n) => p["thread"] = n
    _ => ()
  }
  @settings.act(
    core,
    @sf.t("android-misc.archive.restoreWhat"),
    "chat.archive",
    Json::object(p),
    done=@sf.t("android-misc.archive.restored"),
  )
}

///|
/// Deleted for good, once said so.
fn archive_delete_from(core : Core, v : Json?) -> Unit {
  let title = text(v, "title")
  @sf.confirm(
    @sf.t("android-misc.archive.deleteTitle", args=[("title", title)]),
    @sf.t("android-misc.archive.deleteText"),
    @sf.t("common.delete"),
    danger=true,
    fn() {
      @settings.act(
        core,
        @sf.t("android-misc.archive.deleteWhat"),
        "session.delete",
        Json::object({ "station": Json::string(text(v, "station")), "key": Json::string(text(v, "session")) }),
        done=@sf.t("android-misc.archive.deleted"),
      )
    },
  )
}

///|
/// The archive's chats to come while it is read (in their bones): a made-up day's heading and its chats, as the list
/// makes them.
fn archive_sample_node(s : @view.View, core : Core) -> Unit {
  @sf.day_heading_node(s, fn() { @sf.sample_words(2) }, wide_in=0.0)
  let rows = [(7, 4), (10, 5), (6, 4), (12, 6), (8, 4), (9, 5), (5, 4)]
  for i, n in rows {
    let it : Json = {
      "station": "sample",
      "session": Json::string("sample" + i.to_string()),
      "title": Json::string(@sf.sample_words(n.0)),
      "place": Json::string(@sf.sample_words(n.1)),
      "clock": Json::string(@sf.sample_words(3)),
    }
    archive_row_node(s, core.quiet(), fn() { it })
  }
}
