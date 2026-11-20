// The preview beside a folder's list (⌘⇧P, as Finder's preview pane: still.fail web/src/pages/DrivePane.tsx, Drive.tsx
// usePreviewShown), as nodes of the window's tree: the file chosen shown there as it is chosen (a picture whole, the
// start of a text in a list of its blocks, Markdown rendered, code as it is), with what it is, where (its station, its
// path) and its size and time; what plays (a video, a song) or needs a page of its own (a PDF) says how to open it.
// Several chosen, or a folder, say so. The files' page and a chat's 文件 tab both have it; shown or not is kept on the
// device (prefs `driveViews`: `preview`, `tabPreview`).

///|
/// Whether the preview shows beside a folder's list (`place`: the files' page's, `page`, or a chat's 文件 tab's, `tab`).
pub fn preview_shown(src : Source, place : String) -> Bool {
  text(field(src.topic("prefs", {}).get().value, "driveViews"), if place == "page" { "preview" } else { "tabPreview" }) ==
  "shown"
}

///|
/// The preview shown or not (`prefs.set {driveViews: {preview | tabPreview}}`).
pub fn set_preview_shown(src : Source, place : String, on : Bool) -> Unit {
  let o : Map[String, Json] = Map([])
  o[if place == "page" { "preview" } else { "tabPreview" }] = if on { Json::string("shown") } else { Json::null() }
  (src.call)("prefs.set", { "driveViews": Json::object(o) }, @sfbase.answer_unread)
}

///|
/// What the preview shows (Previewed): one file (the folder it is in, its entry), several chosen, or nothing.
#derive(Eq)
pub(all) enum Previewed {
  One(DriveAt, DvEntry)
  Many(Int)
  Nothing
}

///|
/// A picture is shown whole up to this size (MOST_PICTURE); past it, as the others are, by how to open it.
let fpane_most_picture : Double = 32.0 * 1024.0 * 1024.0

///|
/// The start of a text shown (TEXT_PART).
let fpane_text_part : Int = 64 * 1024

///|
/// What the preview has read of the file shown: by the file (its station, root, path and time), its picture's bytes or
/// its text's start, or that it could not be read.
priv struct FPane {
  mut key : String
  picture : @signals.Signal[String]
  text : @signals.Signal[String?]
  failed : @signals.Signal[Bool]
}

///|
// kept across runs: put back by pane_reset
let fpane : FPane = {
  key: "",
  picture: @signals.signal("", same=fn(a, b) { a == b }),
  text: @signals.signal(None),
  failed: @signals.signal(false, same=fn(a, b) { a == b }),
}

///|
/// What the preview read forgets (a run anew, another file shown).
pub fn pane_reset() -> Unit {
  fpane.key = ""
  fpane.picture.set("")
  fpane.text.set(None)
  fpane.failed.set(false)
}

///|
/// What the file is shown as here: a picture, a text, or neither (its kind's mark and how to open it).
fn fpane_way(e : DvEntry) -> String {
  let lower = e.name.to_lower()
  if e.dir {
    ""
  } else if e.kind == "image" && e.size <= fpane_most_picture && !lower.has_suffix(".heic") && !lower.has_suffix(".heif") {
    "picture"
  } else if ["text", "markdown", "code", "csv", "html", "subtitle"].contains(e.kind) {
    "text"
  } else {
    ""
  }
}

///|
/// The file read as the preview shows it, once a file (and its time): a picture whole, a part at a time; a text's start.
/// Asked as what it shows changes, outside what reads it.
fn fpane_read(src : Source, station : String, root : String, path : String, e : DvEntry, way : String) -> Unit {
  let key = station + "\u{1}" + root + "\u{1}" + path + "\u{1}" + e.mtime.to_string()
  if fpane.key == key {
    return
  }
  pane_reset()
  fpane.key = key
  if way == "" {
    return
  }
  let parts : Array[Bytes] = []
  fn next(got : Int) {
    let want = if way == "text" {
      dmin(fpane_text_part.to_double(), e.size).to_int()
    } else {
      @sfbase.drive_part
    }
    let p : Map[String, Json] = {
      "station": Json::string(station),
      "root": Json::string(root),
      "path": Json::string(path),
      "offset": Json::number(got.to_double()),
      "length": Json::number(want.to_double()),
    }
    @sfbase.drive_keep(p, "file", e.mtime, e.size)
    (src.read_bytes)("drive.read", Json::object(p), fn(r) {
      // (another file chosen since: what comes is let go)
      if fpane.key != key {
        return
      }
      match r {
        Ok((answer, bytes)) => {
          let total = match field(Some(answer), "total") {
            Some(Number(n, ..)) => n.to_int()
            _ => got + bytes.length()
          }
          parts.push(bytes)
          let now = got + bytes.length()
          if way == "text" {
            let (words, _) = @hostapi.decode_text(bytes, truncated=total > now)
            fpane.text.set(Some(words))
          } else if bytes.length() > 0 && now < total {
            next(now)
          } else {
            let whole : Array[Byte] = Array(capacity=now)
            for b in parts {
              for i in 0..<b.length() {
                whole.push(b[i])
              }
            }
            let name = "mem:files-pane/" + key
            @ui.add_image(name, Bytes::from_array(whole[:]))
            fpane.picture.set(name)
          }
        }
        Err(_) => fpane.failed.set(true)
      }
    })
  }
  next(0)
}

///|
/// The preview (DrivePane) in `parent`: beside the list (`below`: under it, a chat's 文件 tab's), what `shown` says is
/// chosen, shown, else what to do to see one; 打开, 下载, 复制路径 under what the file is. `station_name`: its station's.
pub fn drive_pane_node(
  parent : @view.View,
  src : Source,
  shown : () -> Previewed,
  station_name : () -> String,
  on_open : () -> Unit,
  on_save : () -> Unit,
  below? : Bool = false,
) -> Unit {
  parent.box(fn(pane) {
    @sf.style_node(pane, fn() { if below { fpane_below } else { fpane_box } }, in_row=!below)
    // (what it shows read as it is chosen: the file's start or its picture asked of the station)
    pane.reacts(shown, fn(p) {
      match p {
        One(at, e) => {
          let root = at.root.unwrap_or("")
          fpane_read(src, at.station, root, dv_join(at.path, e.name), e, fpane_way(e))
        }
        _ => ()
      }
    })
    pane.pick(fn() {
      match shown() {
        Nothing | Many(_) => ""
        One(at, e) => at.station + "\u{1}" + at.root.unwrap_or("") + "\u{1}" + dv_join(at.path, e.name) + "\u{1}" + e.mtime.to_string()
      }
    }, at_once=true, fn(b, k) {
      match k {
        "" =>
          b.box(fn(n) {
            @sf.style_node(n, fn() { fpane_none_at })
            @sf.words_node(
              n,
              fn() {
                match shown() {
                  Many(n) => @sf.t("web-pages.files.previewMany", args=[("n", n.to_string())])
                  _ => @sf.t("web-pages.files.previewNone")
                }
              },
              fn() { fpane_none },
            )
            .words_centered(Is(true))
            |> ignore
          })
          |> ignore
        _ => {
          guard @signals.untracked(shown) is One(at, e) else { return }
          let root = at.root.unwrap_or("")
          let abs = dv_absolute(root, dv_join(at.path, e.name))
          fpane_body_node(b, e, fpane_way(e), on_open, below)
          b.box(fn(about) {
            @sf.style_node(about, fn() { fpane_about })
            @sf.words_node(about, fn() { e.name }, fn() { fpane_name }) |> ignore
            // what it is, as a grid of two columns: what is said, then its value
            let facts : Array[(String, () -> String)] = []
            if !e.dir {
              facts.push((@sf.t("web-pages.files.size"), fn() { e.size_text }))
            }
            facts.push((@sf.t("web-pages.files.modified"), fn() { e.time_text }))
            facts.push(("Station", station_name))
            about.box(fn(grid) {
              @sf.style_node(grid, fn() { fpane_facts })
              grid.box(fn(said) {
                @sf.style_node(said, fn() { fpane_facts_column }, in_row=true)
                said.each(fn() { facts.map(fn(f) { f.0 }) }, fn(k) { k }, at_once=true, fn(r, k) {
                  @sf.words_node(r, fn() { k.get() }, fn() { fpane_fact_said }) |> ignore
                })
                @sf.words_node(said, fn() { @sf.t("web-pages.files.where") }, fn() { fpane_fact_said }) |> ignore
              })
              |> ignore
              grid.box(fn(values) {
                @sf.style_node(values, fn() { fpane_values_column }, in_row=true)
                values.each(fn() { Array::makei(facts.length(), fn(i) { i }) }, fn(i) { i }, at_once=true, fn(r, i) {
                  @sf.words_node(r, facts[i.untracked()].1, fn() { fpane_fact_value }) |> ignore
                })
                // (its path, in the code's letters, on one line, cut where it does not fit)
                values.box(fn(p) {
                  p
                  .words_runs(By(fn() { [@ui.span(abs, mono=true)] }), look={ ..@view.words_plain, size: @sf.theme().t.caption, wrap: false, max_lines: 1 })
                  .ink(By(fn() { @sf.theme().p.text }))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            })
            |> ignore
            about.box(fn(acts) {
              @sf.style_node(acts, fn() { fpane_actions })
              acts.wraps(Is(Some(@ui.Space::px(S1_5)))) |> ignore
              @sf.button_node(acts, fn() { @sf.t("web-pages.drive.open") }, on_open) |> ignore
              if !e.dir {
                @sf.button_node(acts, fn() { @sf.t("web-pages.drive.download") }, on_save, tone=Ghost, icon="download") |> ignore
              }
              @sf.button_node(acts, fn() { @sf.t("web-pages.drive.copyPath") }, fn() { copy_path(abs) }, tone=Ghost, icon="copy")
              |> ignore
            })
            |> ignore
          })
          |> ignore
        }
      }
    })
  })
  |> ignore
}

///|
/// What the file is, shown as it can be here, in `parent`: its picture, its text's start, else its kind's mark and how
/// to open it (pressed, it opens). A picture or a text no taller than 60% of the window; under a list (`fixed`), a
/// quarter of it.
fn fpane_body_node(parent : @view.View, e : DvEntry, way : String, open : () -> Unit, fixed : Bool) -> Unit {
  let room = fn() { parent.window_h() * (if fixed { fpane_below_tall } else { fpane_most_tall }) }
  parent.pick(fn() { if fpane.failed.get() { "failed" } else { way } }, at_once=true, fn(b, w) {
    match w {
      "failed" =>
        b.box(fn(f) {
          @sf.style_node(f, fn() { fpane_body_box })
          @sf.words_node(f, fn() { @sf.t("web-pages.files.previewFailed") }, fn() { fpane_none }) |> ignore
        })
        |> ignore
      "picture" =>
        b.box(fn(p) {
          @sf.style_node(p, fn() { fpane_picture_box })
          p.box(fn(i) {
            // whole, as large as the pane is wide and no taller than its room
            let size = fn() {
              let key = fpane.picture.get()
              let (nw, nh) = if key == "" {
                (fpane_inner, fpane_waiting_h)
              } else {
                @ui.image_natural(key).unwrap_or((fpane_inner, fpane_inner))
              }
              let s = dmin(1.0, dmin(fpane_inner / dmax(1.0, nw), room() / dmax(1.0, nh)))
              (nw * s, nh * s)
            }
            i
            .width(By(fn() { Some(size().0) }))
            .height(By(fn() { Some(size().1) }))
            .image(By(fn() {
              let key = fpane.picture.get()
              if key == "" { None } else { Some((key, "", 0)) }
            }))
            .image_contains(Is(true))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      "text" =>
        b.box(fn(t) {
          @sf.style_node(t, fn() { fpane_text_box })
          if fixed {
            t.height(By(fn() { Some(room()) })) |> ignore
          } else {
            t.max_height(By(fn() { Some(room()) })) |> ignore
          }
          t.pick(fn() { fpane.text.get() is Some(_) }, at_once=true, fn(x, read) {
            if !read {
              x.box(fn(w) { @sf.style_node(w, fn() { fpane_waiting }) }) |> ignore
              return
            }
            let words = fpane.text.untracked().unwrap_or("")
            let cut = e.size > fpane_text_part.to_double()
            if e.kind == "markdown" {
              @sf.capped_node(x, room, fn(m) {
                m.box(fn(prose) {
                  @sf.style_node(prose, fn() { fpane_prose })
                  @sf.markdown_node(prose, fn() { words }, size=fn() { 12.0 }, ink=fn() { @sf.theme().p.text }, document=true) |> ignore
                  if cut {
                    @sf.words_node(prose, fn() { @sf.t("web-pages.files.previewMore") }, fn() { fpane_more }) |> ignore
                  }
                })
                |> ignore
              })
              |> ignore
            } else {
              // (its blocks a list's, each made only while it shows: a text's start is long)
              let (blocks, _) = @sf.chunk_text(words)
              let keys = Array::makei(blocks.length() + (if cut { 1 } else { 0 }), fn(i) { i })
              x.box(fn(l) {
                l.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
                // (a block's node taken by the next to show as it no more does, its number that one's; what says the
                // rest is cut made once)
                l.scrolls_reused(@view.Scroll::list(), fn() { keys }, est=fpane_block_est, slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), reuses=fn(
                  i,
                ) {
                  i < blocks.length()
                }, fn(r, i) {
                  r.box(fn(c) {
                    @sf.style_node(c, fn() { fpane_code })
                    // (a block or what says the rest is cut: which never changes for a node, `reuses`')
                    if @signals.untracked(i) < blocks.length() {
                      c.box(fn(w) {
                        w
                        .words_runs(By(fn() { [@ui.span(blocks[i()], mono=true)] }), look={ ..@view.words_plain, size: @sf.theme().t.caption, wrap: true })
                        .ink(By(fn() { @sf.theme().p.text }))
                        |> ignore
                      })
                      |> ignore
                    } else {
                      @sf.words_node(c, fn() { @sf.t("web-pages.files.previewMore") }, fn() { fpane_more }) |> ignore
                    }
                  })
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            }
          })
        })
        |> ignore
      _ => {
        let words = if e.kind == "video" || e.kind == "audio" {
          @sf.t("web-pages.files.previewPlay")
        } else if e.dir {
          @sf.t("web-pages.files.previewFolder")
        } else {
          @sf.t("web-pages.files.previewOpen")
        }
        b.box(fn(m) {
          @sf.style_node(m, fn() { fpane_mark })
          @sf.rippled_node(m, open, fpane_mark_corner, fn() { words })
          @sf.icon_node(m, dv_kind_icon(if e.dir { "folder" } else { e.kind }), fpane_mark_icon, By(fn() { @sf.theme().p.muted }))
          |> ignore
          @sf.words_node(m, fn() { words }, fn() { fpane_mark_words }) |> ignore
        })
        |> ignore
      }
    }
  })
}

///|
/// The pane (12 in, 12 between what it shows and what the file is), the room inside.
pub let pane_w : Double = 300.0

///|
let fpane_inner : Double = 276.0

///|
/// While a picture is read (waiting: 160 of nothing).
let fpane_waiting_h : Double = 160.0

///|
/// Under a chat's 文件 tab's list (below: at most half the window, what it shows a quarter).
let fpane_below_tall : Double = 0.25

///|
// kept across runs: a value (no field of it changes)
let fpane_below : @ui.Style = @ui.css("w=Full p=S3 gap=S3")

///|
/// A picture or a text no taller than this much of the window (body: 60vh).
let fpane_most_tall : Double = 0.6

///|
/// A text's block as guessed before it is laid out.
let fpane_block_est : Double = 400.0

///|
/// What it shows at least 120 high (body), a kind's mark 180 (mark).
let fpane_least : Double = 120.0

///|
let fpane_mark_least : Double = 180.0

///|
/// A kind's mark (56).
let fpane_mark_icon : Double = 56.0

///|
// kept across runs: a value (no field of it changes)
let fpane_box : @ui.Style = @ui.style(w=Fixed(pane_w), h=Full, p=S3, gap=S3)

///|
// kept across runs: a value (no field of it changes)
let fpane_none_at : @ui.Style = @ui.css("w=Full py=S6")

///|
// kept across runs: a value (no field of it changes)
let fpane_none : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full, center=true)

///|
/// What it shows (body: the field's corner, on the neutral ground), a picture centred in it, 120 high at least.
// kept across runs: a value (no field of it changes)
let fpane_body_box : @ui.Style = @ui.style(w=Full, min_h=Fixed(fpane_least), py=S6, radius=Xl, bg=Neutral, align=ACenter, justify=JCenter)

///|
// kept across runs: a value (no field of it changes)
let fpane_picture_box : @ui.Style = @ui.style(w=Full, min_h=Fixed(fpane_least), radius=Xl, bg=Neutral, clip=true, align=ACenter, justify=JCenter)

///|
/// While it is read (waiting: 160 of nothing).
// kept across runs: a value (no field of it changes)
let fpane_waiting : @ui.Style = @ui.css("w=Full h=S40")

///|
// kept across runs: a value (no field of it changes)
let fpane_text_box : @ui.Style = @ui.style(w=Full, h=@sf.grow, radius=Xl, bg=Neutral, clip=true)

///|
/// A text's lines (textBox: 10 by 12), Markdown's (prose: 4 by 12).
// kept across runs: a value (no field of it changes)
let fpane_code : @ui.Style = @ui.css("w=Full px=S3 py=S2_5")

///|
// kept across runs: a value (no field of it changes)
let fpane_prose : @ui.Style = @ui.css("w=Full px=S3 py=S1")

///|
// kept across runs: a value (no field of it changes)
let fpane_more : @ui.TextStyle = @ui.text_style(size=Caption, color=Subtle, w=Full)

///|
/// A kind's mark and how to open it, 10 apart, 180 high at least.
// kept across runs: a value (no field of it changes)
let fpane_mark : @ui.Style = @ui.style(w=Full, min_h=Fixed(fpane_mark_least), gap=S2_5, radius=Xl, bg=Neutral, align=ACenter, justify=JCenter)

///|
// kept across runs: a value (no field of it changes)
let fpane_mark_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// What the file is (about: 8 between), its name (the ui's words, bold).
// kept across runs: a value (no field of it changes)
let fpane_about : @ui.Style = @ui.css("w=Full gap=S2")

///|
// kept across runs: a value (no field of it changes)
let fpane_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, w=Full)

///|
/// Its facts (facts: two columns, 4 by 12 between).
// kept across runs: a value (no field of it changes)
let fpane_facts : @ui.Style = @ui.css("row w=Full gap=S3")

///|
// kept across runs: a value (no field of it changes)
let fpane_facts_column : @ui.Style = @ui.css("gap=S1")

///|
// kept across runs: a value (no field of it changes)
let fpane_values_column : @ui.Style = @ui.style(w=@sf.grow, gap=S1, clip=true)

///|
// kept across runs: a value (no field of it changes)
let fpane_fact_said : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fpane_fact_value : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
/// 打开, 下载, 复制路径 (actions: 6 apart, wrapped).
// kept across runs: a value (no field of it changes)
let fpane_actions : @ui.Style = @ui.css("row w=Full gap=S1_5")

///|
/// A kind's mark's corner (the field's: Xl, 12), its press rippling round it.
let fpane_mark_corner : Double = 12.0

///|
/// What the file is shown as in a preview (fpane_way's: "picture", "text", or ""), for a chat's 文件 tab's (sfdesk's).
pub fn preview_way(e : DvEntry) -> String {
  fpane_way(e)
}

///|
/// The file read as a preview shows it (fpane_read's), once a file: for a chat's 文件 tab's (sfdesk's), from what is
/// told once its build is over.
pub fn preview_read(src : Source, station : String, root : String, path : String, e : DvEntry, way : String) -> Unit {
  fpane_read(src, station, root, path, e, way)
}

///|
/// What the preview has read of the file shown, as it is now: its picture's key ("" none yet), its text's start, whether
/// it could not be read.
pub fn preview_read_now() -> (String, String?, Bool) {
  (fpane.picture.get(), fpane.text.get(), fpane.failed.get())
}

///|
/// The start of a text a preview shows (TEXT_PART).
pub let preview_text_part : Int = fpane_text_part
