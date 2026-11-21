// ＋ pressed on a touch system (still.fail's Android app): the library's panel of nodes, a sheet from the foot,
// of the gallery's recent photos across its top (the camera first: recent.mbt), then 照片, 文件 and Station 文件 (添加 n 个
// in their place while photos are chosen in the strip). A tile
// picked asks the system (held by the host where it is big: writing_add_held), what it answers coming into the draft as
// the composer is next drawn (take_in); Station 文件 puts up the shell's sheet of station files for the draft. On a
// computer ＋ is the system's picker at once (composer.mbt attach).

///|
/// What the panel holds, in its body's node `v`: the strip, then the three tiles (添加 n 个 in their place while photos
/// are chosen in the strip), each pressed shutting it (`close`) for what it asks.
fn attach_body_node(v : @view.View, src : Source, key : String, close : () -> Unit) -> Unit {
  let small = @sf.in_small_panel_node(v)
  let ask = fn(kind : @hostapi.PickKind) {
    close()
    if @ui.pick(kind, hold=true, on_got=fn(files) { picked_into(key, files) }) is None {
      @sfbase.toast_later(@sf.t(if kind == Camera { "android-chat.composer.noCamera" } else { "android-chat.composer.noFiles" }))
    }
  }
  // the gallery's recent photos, read as the panel opened (attach_open), taken as they are read
  recent_reads_node(v, src)
  let tapped = fn(i : Int) {
    if i == 0 {
      ask(Camera)
    } else if i > 0 {
      close()
      match recent_photo(i - 1) {
        Some(photo) => @ui.pick_photos([photo.src], on_got=fn(files) { picked_into(key, files) }) |> ignore
        None => ()
      }
    } else {
      match recent_access() {
        // no gallery on this host: said so
        NoGallery => {
          close()
          @sfbase.toast_later(@sf.t("android-chat.composer.noRecent"))
        }
        _ => @hostapi.gallery_ask()
      }
    }
  }
  recent_strip_node(v, tapped)
  // photos chosen in the strip: 添加 n 个 where the tiles were, as high (the sheet as it is)
  v.pick(fn() { recent.chosen.length() > 0 }, at_once=true, fn(p, adding) {
    if adding {
      recent_adding_node(p, fn(files) { picked_into(key, files) }, close, small)
      return
    }
    let corner = attach_block_corner(small)
    p.box(fn(row) {
      @sf.style_node(row, fn() { attach_tiles.then(@ui.style(pb=@sf.room_of(attach_foot(small)))) })
      for item in [
        ("android-chat.attach.photos", "photo", fn() { ask(Photos) }),
        ("android-chat.attach.files", "file", fn() { ask(Files) }),
        (
          "web-pages.chat.files",
          "server",
          fn() {
            close()
            (@sfbase.station_files_asked.val)(src, key)
          },
        ),
      ] {
        let (words, icon, press) = item
        let label = fn() { @sf.t(words) }
        row.box(fn(tile) {
          @sf.style_node(tile, fn() { attach_tile.then(@ui.style(radius=attach_block_radius(small))) }, in_row=true)
          @sf.icon_node(tile, icon, attach_icon, By(fn() { @sf.theme().p.text })) |> ignore
          @sf.words_node(tile, label, fn() { attach_words }) |> ignore
          // (Attach.kt: clip(Smooth(14)).clickable; the ladder's block corner here, or a small panel's)
          @sf.rippled_node(tile, press, corner, label)
        })
        |> ignore
      }
    })
    |> ignore
  })
}

///|
/// The tiles' row (the panel's room there; attach_foot under them, 8 between).
// kept across runs: a value (no field of it changes)
let attach_tiles : @ui.Style = @ui.css("row w=Full gap=S2")

///|
/// A tile: 70 high, its icon over its name, on a quiet ground, as round as the strip's tiles (attach_block_corner).
// kept across runs: a value (no field of it changes)
let attach_tile : @ui.Style = @ui.style(
  w=@sf.grow,
  h=Fixed(attach_tile_h),
  px=S1,
  gap=S1_5,
  bg=Neutral,
  align=ACenter,
  justify=JCenter,
)

///|
let attach_tile_h : Double = 70.0

///|
// kept across runs: a value (no field of it changes)
let attach_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false)

///|
let attach_icon : Double = 22.0

///|
/// The panel's width beside ＋ (a sheet is the window's): a phone's, as Attach.kt's sheet is laid out, so each tile has
/// the room for its name (a small panel's 280 cut Station 文件's) and the strip shows its photos past the camera.
pub let attach_w : Double = 360.0
