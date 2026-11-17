// What a chat's 文件 tab (drive_tab.mbt) draws its folder with, while the panels that hold it are still built the old
// way (the chat's side panel, a new chat's files panel, a station's tab): its rows (DriveRow, compact: a mark, a name,
// its size; the ⋯ on hover and the same on a right click or a finger's hold; pressed, picked or gone into; with a
// mouse dragged onto the chat, for its composer to take: tab_take_drop), their list, and the preview under it. The
// folder's browsing (its order, where it is told) is the files' page's (sfpages' files_browse.mbt), the entries' acts
// theirs (files_model.mbt): only the drawing is the old view's here.

///|
/// What a row of the tab does (RowProps): its menu's items, pressed (picked, or gone into), whether it is picked.
priv struct TabRowOf {
  items : () -> Array[@sf.MenuItem?]
  press : () -> Unit
  chosen : Bool
}

///|
/// The tab's drag (a row pressed with a mouse and moved past the slop carries it; let go off the tab, for the chat's
/// composer to take), and the row that took the last press or menu (what holds the rows leaves it to them).
priv struct TabDrag {
  mut press : (Dragged, Double, Double)?
  item : @signals.Signal[Dragged?]
  mut row_ids : (Int, Int)
}

///|
// kept across runs: put back by tab_drag_reset
let tdrag : TabDrag = { press: None, item: @signals.signal(None), row_ids: (0, 0) }

///|
fn tab_drag_reset() -> Unit {
  tdrag.press = None
  tdrag.item.set(None)
  tdrag.row_ids = (0, 0)
}

///|
/// What is carried now (a row of the tab dragged), for what it goes over to show it (a chat's composer).
pub fn dragged() -> Dragged? {
  tdrag.item.get()
}

///|
/// How far a press moves before it is a drag (a click's slop).
let tdrag_slop : Double = 4.0

///|
/// Row `id`, which would carry `item`, followed as it is pressed (Ctx::follow_press): a mouse's press moved past the
/// slop carries it; let go, it is let go off the tab where it is, for the chat's composer to take (tab_take_drop). Not
/// while `live` is not (the row busy).
fn tab_drag_source(c : @ui.Ctx, id : Int, item : Dragged, live : Bool) -> Unit {
  c.follow_press(id, fn(step) {
    if !live {
      return
    }
    match step {
      Down(x, y, _) => if @sf.pointer_rests() && tdrag.item.get() is None { tdrag.press = Some((item, x, y)) }
      Moving(x, y) =>
        match (tdrag.press, tdrag.item.get()) {
          (Some((i, x0, y0)), None) if (x - x0).abs() > tdrag_slop || (y - y0).abs() > tdrag_slop => {
            tdrag.press = None
            // (another carried: what was let go before and not taken is not for it)
            ftab.let_go = None
            tdrag.item.set(Some(i))
          }
          _ => ()
        }
      Up(x, y) => {
        tdrag.press = None
        match tdrag.item.get() {
          Some(i) => {
            ftab.let_go = Some((i, x, y))
            tdrag.item.set(None)
          }
          None => ()
        }
      }
      Off => {
        tdrag.press = None
        tdrag.item.set(None)
      }
    }
  })
}

///|
/// Whether a row took the press or right click the list sees now (what holds the rows leaves it to them).
fn tab_row_took(c : @ui.Ctx) -> Bool {
  let (id, did) = tdrag.row_ids
  id != 0 && (c.watch_press(id) || c.watch_press(did) || c.right_clicked(id) is Some(_) || c.held_long(id))
}

///|
/// A row of the tab's list (DriveRow, compact) of the entry `e` in `at`: its mark, its name, its size (how far it has
/// come down while it does); pressed, `row.press`; its ⋯ under the pointer, a right click or a finger's hold, its
/// menu; picked, on the selected ground; a mouse's moved, dragged (tab_drag_source).
fn tab_row(c : @ui.Ctx, src : Source, at : DriveAt, e : DvEntry, row : TabRowOf) -> Unit {
  let t = @sf.theme()
  let root = at.root.unwrap_or("")
  let full = dv_join(at.path, e.name)
  let key = "files-tab/row/" + at.station + "/" + root + "/" + full
  let id = c.id(key)
  let more = c.id(key + "/menu/more")
  let busy = @sfpages.entry_busy(src, at, e.name)
  let held_more = @sf.more_held()
  tab_drag_source(
    c,
    id,
    {
      station: at.station,
      station_name: @sfpages.station_name(src, at.station),
      root,
      path: full,
      abs: dv_absolute(root, full),
      name: e.name,
      size: e.size,
      dir: e.dir,
    },
    !busy,
  )
  if !busy {
    match c.menu_asked(id) {
      Some((x, y)) => {
        tdrag.row_ids = (id, 0)
        @sf.menu((row.items)(), from=@sf.at_point(x, y), title=if held_more { e.name } else { "" })
      }
      None => ()
    }
    c.on_press(id, fn() {
      tdrag.row_ids = (id, 0)
      (row.press)()
    })
  }
  let over = c.hovered(id)
  let ground = (if row.chosen { tab_entry_chosen } else if over { tab_entry_along } else { tab_entry_plain }).then(if held_more {
    tab_entry_held
  } else {
    tab_entry_capsule
  })
  let fetching = match download_of_drive(src, at.station, root, full) {
    Some(d) if flag(Some(d), "active") => Some((number(Some(d), "progress") * 100.0).floor().to_int())
    _ => None
  }
  let items = t.items
  c.box(style=tab_entry_room, fn() {
    let box = c.box(style=if busy { ground.then(tab_entry_busy) } else { ground }, id~, fn() {
      c.box(style=tab_row_compact.then(@ui.style(min_h=Fixed(items.least - tab_compact_less))).then(@sf.row_least_h()), fn() {
        @sf.icon(c, dv_kind_icon(if e.dir { "folder" } else { e.kind }), size=items.mark - tab_compact_less_mark, color=t.p.muted) |> ignore
        @sf.name_words(c, e.name, items.name) |> ignore
        match fetching {
          Some(p) => c.text("\{p}%", style=items.meta) |> ignore
          None => if !e.dir && e.size_text != "" { c.text(e.size_text, style=items.meta) |> ignore }
        }
        c.box(style=tab_end_compact, fn() {  }) |> ignore
      })
      |> ignore
      // at its end, a mouse's ⋯ on hover (a spinner while something is under way), in the middle of its capsule end
      c.layer(fn() {
        if held_more {
          return
        }
        c.box(style=tab_more_place, fn() {
          if busy {
            @sf.spinner(c) |> ignore
          } else {
            // (there whether shown or not, clear while not: the hand changes no box)
            c.box(style=if over { tab_more_shown } else { tab_more_clear }, fn() {
              @sf.icon_button(c, "more", key=key + "/menu/more", size=tab_more_size, round=true, label=@sf.t("web-main.menu.more"), on_press=fn() {
                @sf.menu((row.items)(), from=Of(more), along=End)
              })
              |> ignore
            })
            |> ignore
          }
        })
        |> ignore
      })
      |> ignore
      if !busy {
        @sf.press_ripple(c, id, if held_more { @sf.row_corner } else { tab_row_round })
      }
    })
    c.semantics(box, Button, id~, label=e.name, selected=row.chosen)
  })
  |> ignore
}

///|
/// The tab's rows of the folder `at` (its entries as `list` orders them), in a list of their own (`key`: by where it
/// is, so each folder keeps how far it was scrolled), `head` over them.
fn tab_rows_view(
  c : @ui.Ctx,
  src : Source,
  key : String,
  at : DriveAt,
  list : Array[DvEntry],
  row_of : (DriveAt, DvEntry) -> TabRowOf,
  head~ : () -> Unit,
) -> Unit {
  let n = list.length()
  @sf.rows_list(c, key, n + 2, tab_row_est, fn(i) {
    if i == 0 {
      head()
    } else if i == n + 1 {
      c.box(style=@ui.style(w=Full, h=Fixed(tab_rows_foot)), fn() {  }) |> ignore
    } else {
      let e = list[i - 1]
      @sf.group_row(c, i == 1, i == n, fn() { tab_row(c, src, at, e, row_of(at, e)) })
    }
  })
  |> ignore
}

///|
/// The tab's rows to come while a folder is read the first time (the library's Waiting, in its bones): `count` rows of
/// made-up names, a couple of folders first.
fn tab_rows_sample(c : @ui.Ctx, at : DriveAt, count : Int) -> Unit {
  let names : Array[(Bool, Int)] = [(true, 4), (true, 6), (false, 9), (false, 5), (false, 12)]
  @sf.rows_room(c, fn() {
    for i in 0..<count {
      let (dir, name) = names[i % names.length()]
      let e = @sfbase.dv_entry({
        "name": Json::string(@sf.sample_words(name) + (if dir { "" } else { ".md" })),
        "dir": Json::boolean(dir),
        "sizeText": Json::string(if dir { "" } else { @sf.sample_words(3) }),
      })
      @sf.group_row(c, i == 0, i == count - 1, fn() {
        tab_row(c, @sfbase.sample_source, at, e, { items: fn() { [] }, press: fn() {  }, chosen: false })
      })
    }
  })
}

///|
/// The preview under the tab's list (DrivePane, below): what was picked last in the folder shown, shown as it can be
/// here (its picture, its text's start, else its kind's mark and how to open it), what it is, 打开, 下载, 复制路径.
fn tab_pane(c : @ui.Ctx, src : Source, shown : @sfpages.Previewed, station_name : String, on_open : () -> Unit, on_save : () -> Unit) -> Unit {
  c.box(style=tab_pane_box, fn() {
    match shown {
      Nothing | Many(_) =>
        c.box(style=tab_pane_none_at, fn() { c.text(@sf.t("web-pages.files.previewNone"), style=tab_pane_none) |> ignore }) |> ignore
      One(at, e) => {
        let root = at.root.unwrap_or("")
        let abs = dv_absolute(root, dv_join(at.path, e.name))
        let way = @sfpages.preview_way(e)
        c.tell("files-tab/preview", fn() { @sfpages.preview_read(src, at.station, root, dv_join(at.path, e.name), e, way) })
        tab_pane_body(c, e, way, on_open, c.height * tab_pane_tall)
        c.box(style=tab_pane_about, fn() {
          c.text(e.name, style=tab_pane_name) |> ignore
          let facts : Array[(String, String)] = []
          if !e.dir {
            facts.push((@sf.t("web-pages.files.size"), e.size_text))
          }
          facts.push((@sf.t("web-pages.files.modified"), e.time_text))
          facts.push(("Station", station_name))
          facts.push((@sf.t("web-pages.files.where"), abs))
          c.box(style=tab_pane_facts, fn() {
            c.box(style=tab_pane_facts_column, fn() {
              for f in facts {
                c.text(f.0, style=tab_pane_fact_said) |> ignore
              }
            })
            |> ignore
            c.box(style=tab_pane_values_column, fn() {
              for f in facts {
                if f.1 == abs {
                  c.rich([@ui.span(abs, mono=true)], style=tab_pane_path) |> ignore
                } else {
                  c.text(f.1, style=tab_pane_fact_value) |> ignore
                }
              }
            })
            |> ignore
          })
          |> ignore
          c.box(style=tab_pane_actions, fn() {
            @sf.button(c, @sf.t("web-pages.drive.open"), key="files-tab/preview/open", on_press=on_open) |> ignore
            if !e.dir {
              @sf.button(c, @sf.t("web-pages.drive.download"), key="files-tab/preview/download", tone=Ghost, icon="download", on_press=on_save)
              |> ignore
            }
            @sf.button(c, @sf.t("web-pages.drive.copyPath"), key="files-tab/preview/copy", tone=Ghost, icon="copy", on_press=fn() {
              @sfpages.copy_path(abs)
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      }
    }
  })
  |> ignore
}

///|
/// What the file picked is, in the preview under the tab's list, `room` high: its picture, its text's start (scrolling
/// in itself), else its kind's mark and how to open it (pressed, it opens).
fn tab_pane_body(c : @ui.Ctx, e : DvEntry, way : String, open : () -> Unit, room : Double) -> Unit {
  let t = @sf.theme()
  let (picture, text, failed) = @sfpages.preview_read_now()
  if failed {
    c.box(style=tab_pane_body_box, fn() { c.text(@sf.t("web-pages.files.previewFailed"), style=tab_pane_none) |> ignore }) |> ignore
    return
  }
  match way {
    "picture" =>
      c.box(style=tab_pane_picture_box, fn() {
        if picture == "" {
          c.box(style=tab_pane_waiting, fn() {  }) |> ignore
        } else {
          let (nw, nh) = @ui.image_natural(picture).unwrap_or((tab_pane_inner, tab_pane_inner))
          let s = dmin(1.0, dmin(tab_pane_inner / dmax(1.0, nw), room / dmax(1.0, nh)))
          c.image(picture, w=Px(nw * s), h=Px(nh * s), fit=FitContain, bg=0L) |> ignore
        }
      })
      |> ignore
    "text" =>
      match text {
        None => c.box(style=tab_pane_picture_box, fn() { c.box(style=tab_pane_waiting, fn() {  }) |> ignore }) |> ignore
        Some(words) =>
          c.box(style=tab_pane_text_box.then(@ui.style(h=Fixed(room))), fn() {
            c.capped("files-tab/preview/text", room, fn() {
              c.box(style=tab_pane_code, fn() {
                if e.kind == "markdown" {
                  @sf.markdown(c, words, key="files-tab/preview/md", size=12.0, ink=t.p.text, document=true) |> ignore
                } else {
                  c.rich([@ui.span(words, mono=true)], style=tab_pane_code_words) |> ignore
                }
                if e.size > @sfpages.preview_text_part.to_double() {
                  c.text(@sf.t("web-pages.files.previewMore"), style=tab_pane_more) |> ignore
                }
              })
              |> ignore
            })
            |> ignore
          })
          |> ignore
      }
    _ => {
      let id = c.id("files-tab/preview/mark")
      c.on_press(id, fn() { open() })
      let words = if e.kind == "video" || e.kind == "audio" {
        @sf.t("web-pages.files.previewPlay")
      } else if e.dir {
        @sf.t("web-pages.files.previewFolder")
      } else {
        @sf.t("web-pages.files.previewOpen")
      }
      let b = c.box(style=tab_pane_mark, id~, fn() {
        @sf.icon(c, dv_kind_icon(if e.dir { "folder" } else { e.kind }), size=tab_pane_mark_icon, color=t.p.muted) |> ignore
        c.text(words, style=tab_pane_mark_words) |> ignore
      })
      c.semantics(b, Button, id~, label=words)
    }
  }
}

///|
/// A compact row 8 less high than the screen's, its mark 2 less; its ⋯ (24); a row's ripple's corner (a capsule).
let tab_compact_less : Double = 8.0

///|
let tab_compact_less_mark : Double = 2.0

///|
let tab_more_size : Double = 24.0

///|
let tab_row_round : Double = 1000.0

///|
/// A row, as tall as it mostly is till it is laid out (36 and the list's 2); under the last (30).
let tab_row_est : Double = 38.0

///|
let tab_rows_foot : Double = 30.0

///|
// kept across runs: a value (no field of it changes)
let tab_entry_room : @ui.Style = @ui.css("w=Full pb=S0_5")

///|
// kept across runs: a value (no field of it changes)
let tab_entry_plain : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let tab_entry_capsule : @ui.Style = @ui.css("radius=Full")

///|
// kept across runs: a value (no field of it changes)
let tab_entry_held : @ui.Style = @ui.style(radius=@sf.row_radius)

///|
// kept across runs: a value (no field of it changes)
let tab_entry_along : @ui.Style = tab_entry_plain.then(@ui.css("bg=ListGround"))

///|
// kept across runs: a value (no field of it changes)
let tab_entry_chosen : @ui.Style = tab_entry_plain.then(@ui.css("bg=Selected"))

///|
// kept across runs: a value (no field of it changes)
let tab_entry_busy : @ui.Style = @ui.css("opacity=O60")

///|
// kept across runs: a value (no field of it changes)
let tab_row_compact : @ui.Style = @ui.css("row w=Full px=S2_5 py=S1_5 gap=S2_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let tab_end_compact : @ui.Style = @ui.css("w=S7")

///|
// kept across runs: a value (no field of it changes)
let tab_more_place : @ui.Style = @ui.css("row w=Full h=Full pr=S1_5 align=ACenter justify=JEnd")

///|
// kept across runs: a value (no field of it changes)
let tab_more_shown : @ui.Style = @ui.css("row")

///|
// kept across runs: a value (no field of it changes)
let tab_more_clear : @ui.Style = @ui.css("row opacity=O0")

///|
/// The preview under the list: 12 in, 12 between what it shows and what the file is; what it shows a quarter of the
/// window high.
// kept across runs: a value (no field of it changes)
let tab_pane_box : @ui.Style = @ui.css("w=Full p=S3 gap=S3")

///|
let tab_pane_tall : Double = 0.25

///|
let tab_pane_inner : Double = 276.0

///|
let tab_pane_mark_icon : Double = 56.0

///|
/// What the preview shows at least 120 high, a kind's mark 180.
let tab_pane_least : Double = 120.0

///|
let tab_pane_mark_least : Double = 180.0

///|
// kept across runs: a value (no field of it changes)
let tab_pane_none_at : @ui.Style = @ui.css("w=Full py=S6")

///|
// kept across runs: a value (no field of it changes)
let tab_pane_none : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full, center=true)

///|
// kept across runs: a value (no field of it changes)
let tab_pane_body_box : @ui.Style = @ui.style(w=Full, min_h=Fixed(tab_pane_least), py=S6, radius=Xl, bg=Neutral, align=ACenter, justify=JCenter)

///|
// kept across runs: a value (no field of it changes)
let tab_pane_picture_box : @ui.Style = @ui.style(w=Full, min_h=Fixed(tab_pane_least), radius=Xl, bg=Neutral, clip=true, align=ACenter, justify=JCenter)

///|
// kept across runs: a value (no field of it changes)
let tab_pane_waiting : @ui.Style = @ui.css("w=Full h=S40")

///|
// kept across runs: a value (no field of it changes)
let tab_pane_text_box : @ui.Style = @ui.css("w=Full radius=Xl bg=Neutral clip")

///|
// kept across runs: a value (no field of it changes)
let tab_pane_code : @ui.Style = @ui.css("w=Full px=S3 py=S2_5")

///|
// kept across runs: a value (no field of it changes)
let tab_pane_code_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Fg, w=Full, leading=L4)

///|
// kept across runs: a value (no field of it changes)
let tab_pane_more : @ui.TextStyle = @ui.text_style(size=Caption, color=Subtle, w=Full)

///|
// kept across runs: a value (no field of it changes)
let tab_pane_mark : @ui.Style = @ui.style(w=Full, min_h=Fixed(tab_pane_mark_least), gap=S2_5, radius=Xl, bg=Neutral, align=ACenter, justify=JCenter)

///|
// kept across runs: a value (no field of it changes)
let tab_pane_mark_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let tab_pane_about : @ui.Style = @ui.css("w=Full gap=S2")

///|
// kept across runs: a value (no field of it changes)
let tab_pane_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let tab_pane_facts : @ui.Style = @ui.css("row w=Full gap=S3")

///|
// kept across runs: a value (no field of it changes)
let tab_pane_facts_column : @ui.Style = @ui.css("gap=S1")

///|
// kept across runs: a value (no field of it changes)
let tab_pane_values_column : @ui.Style = @ui.style(w=@sf.grow, gap=S1, clip=true)

///|
// kept across runs: a value (no field of it changes)
let tab_pane_fact_said : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let tab_pane_fact_value : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let tab_pane_path : @ui.TextStyle = @ui.text_style(size=Caption, color=Fg, wrap=false, max_lines=1, leading=L4)

///|
// kept across runs: a value (no field of it changes)
let tab_pane_actions : @ui.Style = @ui.css("row w=Full gap=S1_5")
