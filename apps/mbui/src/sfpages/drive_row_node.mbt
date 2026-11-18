// A row of a folder's list on the files' page (still.fail web/src/pages/Drive.tsx DriveRow, NameField, ListHead,
// UploadRow; Drive.css.ts), as nodes of the window's tree, each bound to what it shows: its mark, name, size and time
// (compact: the size alone), the ⋯ under a pointer and the same on a right click or a finger's hold. Pressed it is
// chosen (a finger's opens it), the second of two presses opens it, its name is changed in place; pressed by a mouse
// and moved it is dragged (what is chosen with it: files_drag.mbt), and a folder takes what is dropped on it. In a tree,
// in by its depth, a folder with its disclosure; in columns, the folder open beside marked as the way to the next
// column, with › at its end.

///|
/// What a row of a folder does, as its place says (RowProps): its menu (a right click, its ⋯: about what is chosen
/// when it is among it), opened (a double click), pressed (chosen; in columns a folder opened beside), right clicked
/// (chosen, if it is not among what is), chosen, its name being changed in place and that done (None: as it was), and
/// a folder's: where what is dropped on it goes. Each read as it is asked.
pub(all) struct RowOf {
  items : () -> Array[@sf.MenuItem?]
  open : () -> Unit
  press : () -> Unit
  menu : () -> Unit
  chosen : () -> Bool
  renaming : () -> Bool
  rename : (String?) -> Unit
  drop : DriveAt?
}

///|
/// The ways a place shows a folder's rows, the same for each view (Shown): its source and its browsing (Browse), what
/// each row does, what is dropped on where a folder's rows are (not on one of them), a press where there is no row
/// (nothing chosen); whether the station takes what is written there and copies from others; whether its list is too
/// narrow for a size's and a time's columns (what a row is said under its name then); what carries a row as a mouse
/// holds it and moves it (the files' page's drag, drag_source_node: let go on a folder, it goes there; a chat's 文件
/// tab's its own, let go on the chat for its composer to take), given the row's node, what it carries and whether it
/// may be carried now.
pub(all) struct Shown {
  src : Source
  b : Browse
  row_of : (DriveAt, () -> DvEntry) -> RowOf
  drop_on : (DriveAt) -> DriveAt?
  clear : () -> Unit
  write : () -> Bool
  transfers : () -> Bool
  stacked : () -> Bool
  carries : (@view.View, () -> Dragged, () -> Bool) -> Unit
}

///|
/// The row whose menu is up (its key; "" none): marked while it is.
// kept across runs: put back as its menu goes
let row_menu_up : @signals.Signal[String] = @signals.signal("")

///|
/// Row `key`'s menu of `items`, from `from`: the row marked while it is up (`title` over it where a finger held it).
fn drive_row_menu(key : String, items : Array[@sf.MenuItem?], from : @sf.Beside, along? : @ui.Along = Start, title? : String = "") -> Unit {
  let done = items.map(fn(x) {
    x.map(fn(m) {
      {
        ..m,
        select: fn() {
          row_menu_up.set("")
          (m.select)()
        },
      }
    })
  })
  row_menu_up.set(key)
  @sf.menu(done, from~, along~, title~, gone=fn() { if row_menu_up.untracked() == key { row_menu_up.set("") } })
}

///|
/// A folder's row in `parent` (DriveRow), its entry `e` as it is now in the folder `at`, as `s` shows it: compact (a
/// column's, a chat's 文件 tab's: less in, the size alone), at a tree's `depth` (a folder with its disclosure, open
/// as `expanded` says, `on_toggle` as it is pressed), in columns (`column`: the folder open beside, `along`, marked, a
/// › at its end).
pub fn drive_row_node(
  parent : @view.View,
  s : Shown,
  at : DriveAt,
  e : () -> DvEntry,
  compact? : Bool = false,
  depth? : Int,
  expanded? : () -> Bool = fn() { false },
  on_toggle? : () -> Unit = fn() {  },
  column? : Bool = false,
  along? : () -> Bool = fn() { false },
) -> Unit {
  let src = s.src
  let root = at.root.unwrap_or("")
  let first = @signals.untracked(e)
  let dir = first.dir
  let full = dv_join(at.path, first.name)
  let key = "files/row/" + s.b.key + "/" + at.station + "/" + root + "/" + full
  let row = (s.row_of)(at, e)
  let busy = fn() { entry_busy(src, at, e().name) }
  let live = fn() { !busy() && !(row.renaming)() }
  let tree = depth is Some(_)
  let indent = match depth {
    Some(d) => tree_step * d.to_double()
    None => 0.0
  }
  let open_now = fn() { row_menu_up.get() == key }
  let fetching = fn() {
    match download_of_drive(src, at.station, root, full) {
      Some(d) if flag(Some(d), "active") => Some((number(Some(d), "progress") * 100.0).floor().to_int())
      _ => None
    }
  }
  let item = fn() -> Dragged {
    let e = e()
    {
      station: at.station,
      station_name: station_name(src, at.station),
      root,
      path: full,
      abs: dv_absolute(root, full),
      name: e.name,
      size: e.size,
      dir: e.dir,
    }
  }
  parent.box(fn(room) {
    // (a row's room in the list: its 2 to the next, on a wide page; on a narrow card its rows meet; in a column, no card's,
    // always 2 apart)
    if column {
      room.padding(Is((0.0, 0.0, 0.0, column_rows_apart))) |> ignore
    } else {
      @sf.row_apart_node(room)
    }
    // pressed by a mouse and moved: dragged, as its place carries it
    (s.carries)(room, item, live)
    room.box(fn(g) {
      // a folder takes what is dropped on it
      let lit = match row.drop {
        Some(into) => drop_target_node(g, src, "row/" + key, Some(into), first.name, s.write, s.transfers, 2)
        None => fn() { None }
      }
      // (its ground: a capsule with a pointer's ⋯ at its end, a row's corner with a finger's; the list's under the
      // pointer, the selected's chosen, the accent's ringed where a drop goes in; faded while something is under way)
      @sf.style_node(g, fn() {
        let base = if lit() is Some(_) {
          entry_drop
        } else if (row.chosen)() {
          entry_chosen
        } else if along() || open_now() {
          entry_along
        } else {
          entry_plain
        }
        let shape = if @sf.more_held() { entry_held } else { entry_capsule }
        base.then(shape)
      })
      // (faded while something is under way: its opacity said on the node, which style_node does not set)
      g.alpha(By(fn() { if busy() { entry_busy_alpha } else { 1.0 } })) |> ignore
      @sf.hover_ground_node(g, on=fn() { live() && lit() is None && !(row.chosen)() }, color=fn() {
        @ui.tree_theme().color(ListGround)
      })
      // pressed, it is chosen (a finger's opens it); the second of two presses opens it; its menu
      let finger = fn() { !@sf.pointer_rests() }
      let menu_at = fn(x : Double, y : Double, held : Bool) {
        guard @signals.untracked(live) else { return }
        (row.menu)()
        // (had by holding it, its menu says what it is of: a sheet over the row it was held on)
        drive_row_menu(key, (row.items)(), @sf.at_point(x, y), title=if held { @signals.untracked(e).name } else { "" })
      }
      @sf.row_presses_node(
        g,
        By(fn() { if @sf.more_held() { @sf.row_corner } else { row_round } }),
        fn() {
          if @signals.untracked(live) {
            if finger() { (row.open)() } else { (row.press)() }
          }
        },
        fn(d) {
          guard @signals.untracked(live) else { return }
          if g.twice(d) || finger() {
            (row.open)()
          } else {
            (row.press)()
          }
        },
        fn(d) { menu_at(d.wx, d.wy, true) },
        fn(x, y) { menu_at(x, y, false) },
      )
      g.says(By(fn() {
        Some(@view.said(Button, label=e().name, selected=(row.chosen)(), expanded?=if tree && dir { Some(expanded()) } else { None }))
      }))
      |> ignore
      g.box(fn(inner) {
        @sf.style_node(inner, fn() {
          let items = @sf.theme().items
          (if compact && tree {
            row_tree_compact
          } else if tree {
            row_tree
          } else if compact {
            row_compact
          } else {
            row_style
          })
          // (a column's row with its 2 to the next a row's least, a press's room: 36 with a mouse, 44 with a finger)
          .then(
            // (a chat's 文件 tab's as tall as a row's least, pressed in no less: its words less in)
            @ui.style(min_h=Fixed(if column { items.least - column_rows_apart } else { items.least })),
          )
        })
        if tree {
          // (in by its depth: 18 a step, past the 6 every tree row is in by)
          inner.box(fn(i) { i.width(Is(Some(indent))).shrink(Is(0.0)) |> ignore }) |> ignore
          inner.box(fn(d) {
            @sf.style_node(d, fn() { disclosure_box }, in_row=true)
            if dir {
              @sf.disclosure_key_node(
                d,
                fn() { @sf.t(if expanded() { "web-pages.files.collapse" } else { "web-pages.files.expand" }, args=[("name", e().name)]) },
                expanded,
                on_toggle,
                icon_size=disclosure_icon,
              )
            }
          })
          |> ignore
        }
        // (what it is under its name, too narrow for its columns: its mark on its name's line, not between the two; what
        // is at its end in the row's middle still)
        // (its name being changed, a field in the row's middle, what it is under it hidden: its mark there with it)
        let on_first_line = fn() { !compact && !column && (s.stacked)() && !(row.renaming)() }
        inner.box(fn(m) {
          @sf.style_node(m, fn() { if on_first_line() { mark_first_line } else { mark_in_line } }, in_row=true)
          // (in a box as tall as the name's line at the system's size of words, across its middle)
          name_line_node(m, fn(l) {
            @sf.icon_node(l, "", @signals.untracked(fn() { mark_size(compact) }), By(fn() { @sf.theme().p.muted }), name_now=fn() {
              let e = e()
              dv_kind_icon(if e.dir { "folder" } else { e.kind })
            })
            |> ignore
          })
        })
        |> ignore
        // its name (a field while it is changed), what it is under it where its row is too narrow for its columns
        inner.box(fn(n) {
          @sf.style_node(n, fn() { if compact { name_cell_compact } else { name_cell } }, in_row=true)
          // (its name; changed in place, the field over its line, its line's room kept: the row as tall either way)
          n.box(fn(line) {
            line.min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(line, fn() { e().name }, fn() { @sf.theme().items.name.then(file_name_cut) })
            .alpha(By(fn() { if (row.renaming)() { 0.0 } else { 1.0 } }))
            |> ignore
          })
          |> ignore
          // (what it is under its name, hidden while its name is changed: the row as tall either way)
          if !compact && !column {
            @sf.words_node(
              n,
              fn() {
                let e = e()
                if e.dir { e.time_text } else { dv_words([e.size_text, e.time_text], " · ") }
              },
              fn() { @sf.theme().items.meta },
            )
            .laid_nowhere(By(fn() { !(s.stacked)() }))
            .alpha(By(fn() { if (row.renaming)() { 0.0 } else { 1.0 } }))
            |> ignore
          }
          // (changed in place: the field over its name and what is under it, across their middle, one line in the
          // row's middle as its mark is)
          n.show(fn() { (row.renaming)() }, at_once=true, fn(o) {
            o.over(Is(true)) |> ignore
            @sf.style_node(o, fn() { name_field_over }, in_row=false)
            name_field_node(o, s.b, e, row)
          })
        })
        |> ignore
        if compact {
          // (how far it has come down, in words: a compact row has no room for the chip in its corner)
          @sf.words_node(
            inner,
            fn() {
              match fetching() {
                Some(p) => "\{p}%"
                None => if dir || column { "" } else { e().size_text }
              }
            },
            fn() { @sf.theme().items.meta },
          )
          |> ignore
          inner.box(fn(x) { @sf.style_node(x, fn() { end_compact }, in_row=true) }) |> ignore
        } else {
          // (short of room, the size leaves first, then the time, as the heads do)
          inner.box(fn(c) {
            @sf.style_node(c, fn() { size_cell }, in_row=true)
            c.laid_nowhere(By(fn() { (s.stacked)() })).drops(Is(list_drop_size)) |> ignore
            @sf.words_node(c, fn() { if dir || column { "" } else { e().size_text } }, fn() { @sf.theme().items.meta }) |> ignore
          })
          |> ignore
          inner.box(fn(c) {
            @sf.style_node(c, fn() { time_cell }, in_row=true)
            c.laid_nowhere(By(fn() { (s.stacked)() })).drops(Is(list_drop_time)) |> ignore
            @sf.words_node(c, fn() { e().time_text }, fn() { @sf.theme().items.meta }) |> ignore
          })
          |> ignore
          inner.fits(Is(true)) |> ignore
        }
        // what is at its end in the flow (a finger's, or under the name): something under way, how far it has come
        // down, how far it was read, a folder's ›
        inner.box(fn(f) {
          // (a folder's › and how far it was read on its name's line where what it is is under the name; something
          // under way and how far it has come down, on its ground, in the row's middle, clear of its corner)
          @sf.style_node(f, fn() {
            if (s.stacked)() && !(row.renaming)() && !busy() && (compact || fetching() is None) { end_flow.then(end_first_line) } else { end_flow }
          }, in_row=true)
          let laid = fn() { (s.stacked)() || @sf.more_held() }
          f.laid_nowhere(By(fn() { !laid() })) |> ignore
          f.pick(fn() {
            if busy() {
              1
            } else if fetching() is Some(_) && !compact {
              2
            } else if first.kind == "text" || first.kind == "markdown" {
              3
            } else if dir && @sf.more_held() {
              4
            } else {
              0
            }
          }, fn(x, k) {
            match k {
              1 => @sf.spinner_node(x) |> ignore
              2 => download_chip_node(x, fn() { fetching().unwrap_or(0) })
              3 => name_line_node(x, fn(l) { read_share_node(l, src, at.station, root, full, laid) })
              4 => name_line_node(x, fn(l) { @sf.icon_node(l, "chevron-right", finger_chevron, By(fn() { @sf.theme().p.subtle })) |> ignore })
              _ => ()
            }
          })
        })
        |> ignore
        if !compact {
          inner.box(fn(x) {
            @sf.style_node(x, fn() { end_cell }, in_row=true)
            x.laid_nowhere(By(fn() { @sf.more_held() })) |> ignore
          })
          |> ignore
        }
      })
      |> ignore
      // at its end, a mouse's: › on the folder open beside (columns), the ⋯ under the pointer (more, next; a spinner
      // while something is under way), in the middle of the row's capsule end, concentric with it
      g.box(fn(o) {
        o.over(Is(true)) |> ignore
        o.laid_nowhere(By(fn() { @sf.more_held() })) |> ignore
        @sf.style_node(o, fn() { more_place })
        // (a square as tall as the row at its end, what is in it in its middle: as far from the row's end as from its top
        // and foot, concentric with the row's capsule end however tall the row is)
        o.box(fn(sq) {
          sq.aspect(Is(1.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
        sq.pick(fn() {
          if busy() {
            if (s.stacked)() { 0 } else { 1 }
          } else if column && dir && along() && !open_now() {
            3
          } else {
            2
          }
        }, fn(m, k) {
          match k {
            1 => @sf.spinner_node(m) |> ignore
            3 =>
              m.box(fn(nx) {
                @sf.style_node(nx, fn() { next_box })
                @sf.icon_node(nx, "chevron-right", disclosure_icon, By(fn() { @sf.theme().p.muted })) |> ignore
              })
              |> ignore
            2 => {
              // (there whether shown or not, clear while not: the hand changes no box)
              let more = @sf.icon_button_opens_node(
                m,
                "more",
                fn() { @sf.t("web-main.menu.more") },
                fn(b) { drive_row_menu(key, (row.items)(), Node(b), along=End) },
                size=if compact { more_compact } else { more_size },
              )
              // (taking no finger while it is clear: a tap where it is not seen is the row's; its focus kept, so the
              // keyboard still reaches it, shown as it has it)
              let more_shown = fn() { open_now() || @sf.lit_within_node(g) || more.focus_shown() }
              more
              .alpha(By(fn() { if more_shown() { 1.0 } else { 0.0 } }))
              .takes(fn(w, h, _) { if more_shown() { [(0.0, 0.0, w, h)] } else { [] } })
              |> ignore
            }
            _ => ()
          }
        })
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A row's mark's size, as the screen's items have it (KindIcon 20; compact 18).
fn mark_size(compact : Bool) -> Double {
  let m = @sf.theme().items.mark
  if compact {
    m - compact_less_mark
  } else {
    m
  }
}

///|
/// A name changed in place (NameField) in `parent`: the library's name changed in place (@sf.inline_rename_node), the
/// name but its extension picked (browse_rename_start picks it); ⏎ or leaving it keeps it, esc leaves it as it was.
fn name_field_node(parent : @view.View, b : Browse, e : () -> DvEntry, row : RowOf) -> Unit {
  @sf.inline_rename_node(
    parent,
    b.rename_field(),
    @signals.untracked(e).name,
    @sf.t("web-pages.drive.rename"),
    fn(words) { (row.rename)(Some(words)) },
    fn() { (row.rename)(None) },
    frame=fn(box) { @sf.style_node(box, fn() { name_field_box }, in_row=true) },
  )
  |> ignore
}

///|
/// How far a text has been read on this device, once opened (the core's `drivePlace`), in `parent`: its share, 读完 at
/// its end; nothing read so little it says nothing. Read of the core only while it is laid (`shown`): a mouse's row
/// in a wide list lays none of it (sfdesk's row never asked it).
fn read_share_node(parent : @view.View, src : Source, station : String, root : String, path : String, shown : () -> Bool) -> Unit {
  let share = fn() {
    if !shown() {
      return 0.0
    }
    let place = src.topic("drivePlace", { "station": Json::string(station), "root": Json::string(root), "path": Json::string(path) }).get().value
    let of = number(place, "of")
    if of <= 0.0 {
      return 0.0
    }
    let at = number(place, "at") / of
    if at < 0.0 { 0.0 } else if at > 1.0 { 1.0 } else { at }
  }
  @sf.words_node(
    parent,
    fn() {
      let s = share()
      if s < read_least {
        ""
      } else if s >= read_whole {
        @sf.t("android-misc.drive.read.done")
      } else {
        "\{(s * 100.0).to_int()}%"
      }
    },
    fn() { @sf.theme().items.meta },
  )
  |> ignore
}

///|
/// Read so little it says nothing (1%), read to its end (99.5%).
let read_least : Double = 0.01

///|
let read_whole : Double = 0.995

///|
/// How far a file of the drive has come while it is downloaded (FillChip's `progress`), in `parent`: a rounded box, its
/// ground filled in the accent from the left as it comes (going to each new share over 500 ms: @motion.Eased), n% on
/// it, the fill drawn narrowed from its left to its share (a square-cornered rect cut to the capsule by its track).
fn download_chip_node(parent : @view.View, percent : () -> Int) -> Unit {
  let p = fn() {
    let p = percent()
    if p < 0 { 0 } else if p > 100 { 100 } else { p }
  }
  let fill = @motion.Eased::new(@signals.untracked(p).to_double())
  parent.box(fn(chip) {
    @sf.style_node(chip, fn() { chip_box })
    chip.reacts(p, fn(now) { fill.go(chip, now.to_double(), chip_fill_ms) }, at_start=false)
    chip.box(fn(track) {
      track.over(Is(true)) |> ignore
      @sf.style_node(track, fn() { chip_track })
      track.box(fn(done) {
        // (its share of the track as it is drawn, from its left: progress_node's part's; the accent at 20%)
        done
        .height(Is(None))
        .grow(Is(0.0))
        .ground(By(fn() { @sf.alpha(@sf.theme().p.accent, 0.2) }))
        .width_share(By(fn() { dmax(0.0, fill.shown(done)) / chip_whole }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    chip.box(fn(w) {
      @sf.style_node(w, fn() { chip_words_box })
      @sf.words_node(w, fn() { "\{p()}%" }, fn() { chip_words }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The chip's fill going to its new share (500 ms, easing out), the whole of it.
///|
let chip_fill_ms : Double = 500.0

///|
let chip_whole : Double = 100.0

///|
// kept across runs: a value (no field of it changes)
let chip_box : @ui.Style = @ui.css("h=S5 radius=Full bg=Neutral justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let chip_track : @ui.Style = @ui.css("row w=Full h=Full radius=Full clip")


///|
// kept across runs: a value (no field of it changes)
let chip_words_box : @ui.Style = @ui.css("row px=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let chip_words : @ui.TextStyle = @ui.text_style(size=Caption, weight=Semibold, color=Fg, wrap=false)

///|
/// Over a list, what its columns are (ListHead), in `parent`: each orders it (again: the other way), the one it is in
/// marked, its chevron down or up.
pub fn list_head_node(parent : @view.View, a : () -> Arrangement, on_sort : (String) -> Unit) -> Unit {
  let head = fn(row : @view.View, by : String, words : String, style : @ui.Style, drop : Int) {
    row.box(fn(h) {
      @sf.style_node(h, fn() { style.then(@ui.style(min_h=Fixed(@ui.room_least()))) }, in_row=true)
      if drop > 0 {
        h.drops(Is(drop)) |> ignore
      }
      @sf.presses_node(h, fn() { on_sort(by) })
      h.says(By(fn() { Some(@view.said(Button, label=words, pressed=a().by == by)) })) |> ignore
      @sf.words_node(h, fn() { words }, fn() { if a().by == by || @sf.lit_node(h) { head_words_on } else { head_words } }) |> ignore
      h.show(fn() { a().by == by }, at_once=true, fn(c) {
        @sf.icon_node(c, "", head_chevron, By(fn() { @sf.theme().p.text }), name_now=fn() {
          if a().down { "chevron-up" } else { "chevron-down" }
        })
        |> ignore
      })
    })
    |> ignore
  }
  parent.box(fn(row) {
    @sf.style_node(row, fn() { list_head_row })
    row.fits(Is(true)) |> ignore
    row.box(fn(m) { @sf.style_node(m, fn() { head_mark }, in_row=true) }) |> ignore
    head(row, "name", @sf.t("web-pages.drive.sortBy.nameHead"), head_name, 0)
    head(row, "size", @sf.t("web-pages.drive.sortBy.sizeHead"), head_size, list_drop_size)
    head(row, "time", @sf.t("web-pages.drive.sortBy.timeHead"), head_time, list_drop_time)
    row.box(fn(x) { @sf.style_node(x, fn() { end_cell }, in_row=true) }) |> ignore
  })
  |> ignore
}

// ── its sizes and looks ──

///|
/// A compact row's (a column's, a chat's 文件 tab's) mark 2 less than the screen's (KindIcon 20, compact 18); a tree's
/// disclosure's chevron (12), the ⋯ (32; compact 24), the heads' chevron (10); a folder's › to a finger (14).
let compact_less_mark : Double = 2.0

///|
let finger_chevron : Double = 14.0

///|
/// Narrower than this, a row says what it is under its name (its size's and time's columns would leave its name too
/// little).
pub let row_stack_below : Double = 440.0

///|
let disclosure_icon : Double = 12.0

///|
/// A ripple's corner on a row (entry_plain, a capsule): past any row's half, so as round as the row.
let row_round : Double = 1000.0

///|
let more_size : Double = 32.0

///|
let more_compact : Double = 24.0

///|
let head_chevron : Double = 10.0

///|
/// A tree's row in by a step a depth (18), past the 6 every tree row is in by.
let tree_step : Double = 18.0

///|
/// The time's column (104).
let time_w : Double = 104.0


///|
/// A row's ground (entry): with its ⋯ at its end (a pointer's), a capsule, as round as it is high (the round ⋯ in the
/// middle of its end concentric with it, whatever its height: 外圆角 = 距离 + 半高); its ⋯ had by holding it (a
/// finger's), a row's corner of the ladder's; the list's ground while marked, the selected's chosen, the accent's
/// ringed where a drop goes in; faded while something is under way on it.
// kept across runs: a value (no field of it changes)
let entry_plain : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let entry_capsule : @ui.Style = @ui.css("radius=Full")

///|
// kept across runs: a value (no field of it changes)
let entry_held : @ui.Style = @ui.style(radius=@sf.row_radius)

///|
// kept across runs: a value (no field of it changes)
let entry_along : @ui.Style = entry_plain.then(@ui.css("bg=ListGround"))

///|
// kept across runs: a value (no field of it changes)
let entry_chosen : @ui.Style = entry_plain.then(@ui.css("bg=Selected"))

///|
// kept across runs: a value (no field of it changes)
let entry_drop : @ui.Style = entry_plain.then(@ui.css("bg=AccentBg border=B1 border_color=Accent"))

///|
// kept across runs: a value (no field of it changes)
let entry_busy_alpha : Double = 0.6

///|
/// A row (row): as high as the screen's items at least, 8 by 12 in, its parts 12 apart: its mark, its name, its size
/// (96) and time (104) at their end, room for its ⋯ (36).
// kept across runs: a value (no field of it changes)
let row_style : @ui.Style = @ui.css("row w=Full px=S3 py=S2 gap=S3 align=ACenter")

///|
/// A chat's 文件 tab's and a column's (compact): 6 by 10 in, 10 apart, the size alone, room for its ⋯ (28).
// kept across runs: a value (no field of it changes)
let row_compact : @ui.Style = @ui.css("row w=Full px=S2_5 py=S1_5 gap=S2_5 align=ACenter")

///|
/// In a tree: 8 apart, its disclosure (12) before its mark, in by its depth.
// kept across runs: a value (no field of it changes)
let row_tree : @ui.Style = row_style.then(@ui.css("gap=S2 pl=S1_5"))

///|
// kept across runs: a value (no field of it changes)
let row_tree_compact : @ui.Style = row_compact.then(@ui.css("gap=S2 pl=S1_5"))

///|
// kept across runs: a value (no field of it changes)
let disclosure_box : @ui.Style = @ui.css("w=S3 h=S3 align=ACenter justify=JCenter")

///|
/// Its name (and what it is under it, stacked) in what is left of its row, never less than a few words (32: 128).
// kept across runs: a value (no field of it changes)
let name_cell : @ui.Style = @ui.style(w=@sf.grow, min_w=S32)

///|
// kept across runs: a value (no field of it changes)
let name_cell_compact : @ui.Style = @ui.style(w=@sf.grow, min_w=S16)

///|
/// What is at its end in its flow (a finger's, or under the name): 8 before it.
// kept across runs: a value (no field of it changes)
let end_flow : @ui.Style = @ui.css("row pl=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let size_cell : @ui.Style = @ui.css("row w=S24 justify=JEnd")

///|
/// The order a list's columns leave its rows and heads in, short of room: the size, then the time.
let list_drop_size : Int = 1

///|
let list_drop_time : Int = 2

///|
// kept across runs: a value (no field of it changes)
let time_cell : @ui.Style = @ui.style(row=true, w=Fixed(time_w), justify=JEnd)

///|
// kept across runs: a value (no field of it changes)
let end_cell : @ui.Style = @ui.css("w=S9")

///|
// kept across runs: a value (no field of it changes)
let end_compact : @ui.Style = @ui.css("w=S7")

///|
/// Its ⋯ (more), and › in columns (next: 24), at its end.
// kept across runs: a value (no field of it changes)
let more_place : @ui.Style = @ui.css("row w=Full h=Full justify=JEnd")

///|
// kept across runs: a value (no field of it changes)
let next_box : @ui.Style = @ui.css("w=S6 h=S6 align=ACenter justify=JCenter")

///|
/// A file's name on one line, cut short where what follows it on its row leaves it less (a name).
// kept across runs: a value (no field of it changes)
let file_name_cut : @ui.TextStyle = @ui.text_style(wrap=false, w=Cut)

///|
/// A name changed in place (nameField): a line of the accent round it, the option's corner, on the page's ground.
// kept across runs: a value (no field of it changes)
let name_field_box : @ui.Style = @ui.style(w=@sf.grow, px=S1_5, py=S0_5, radius=Xl, border=B1, border_color=Accent, bg=Bg)

///|
/// The heads (listHead): 12 in and 4 under, over the row's columns, 12 apart, their words the meta's.
// kept across runs: a value (no field of it changes)
let list_head_row : @ui.Style = @ui.css("row w=Full px=S3 pb=S1 gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let head_mark : @ui.Style = @ui.css("w=S5")

///|
// kept across runs: a value (no field of it changes)
let head_name : @ui.Style = @ui.style(row=true, w=@sf.grow, min_w=S32, gap=S1, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let head_size : @ui.Style = @ui.css("row w=S24 gap=S1 align=ACenter justify=JEnd")

///|
// kept across runs: a value (no field of it changes)
let head_time : @ui.Style = @ui.style(row=true, w=Fixed(time_w), gap=S1, align=ACenter, justify=JEnd)

///|
// kept across runs: a value (no field of it changes)
let head_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let head_words_on : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
/// Over a row's name and what is under it while its name is changed: the field across their middle, as tall as it is.
// kept across runs: a value (no field of it changes)
let name_field_over : @ui.Style = @ui.css("row w=Full h=Full align=ACenter")

///|
/// What stands on a row's name's line (its mark, a folder's ›, how far it was read), made by `make` in `parent`: in a box
/// as tall as that line at the system's size of words, across its middle (@sf.first_line_node, by the theme's name).
fn name_line_node(parent : @view.View, make : (@view.View) -> Unit) -> Unit {
  let name = @signals.untracked(fn() { @sf.theme().items.name.base })
  @sf.first_line_node(parent, name.size.unwrap_or(Ui), leading?=name.leading, make) |> ignore
}

///|
/// A row's mark where what it is is under its name: as tall as the row's middle, at its top, on the name's line
/// (first_line_faults); else in the row's middle as all else in it.
// kept across runs: a value (no field of it changes)
let mark_first_line : @ui.Style = @ui.css("h=Full justify=JStart")

///|
// kept across runs: a value (no field of it changes)
let mark_in_line : @ui.Style = @ui.css("")

///|
/// What is at its end on the name's line (mark_first_line's, its flow a row).
// kept across runs: a value (no field of it changes)
let end_first_line : @ui.Style = @ui.css("h=Full align=AStart")

///|
/// Between two rows of a column (no card's: each its own capsule, lit apart).
let column_rows_apart : Double = 2.0
