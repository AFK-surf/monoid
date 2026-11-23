// ＋'s recent photos and videos (still.fail's Android app, latest): the gallery's
// latest across the top of the sheet after the camera, a video's tile marked with a play badge in its corner, a tap
// putting one in the message (most of what goes to an agent is a screenshot just taken); read again as the sheet opens
// and on each answer of the gallery's (@hostapi.gallery_*). Several go together as the system's photo picker and
// chat apps' strips choose them: each tile's ring in its top corner chooses it (numbered in the order chosen), and
// while some are chosen a tap anywhere on a tile chooses it or not; the tiles under the strip give way to 添加 n 个
// (recent_adding), which puts them in the message in that order.
// Without leave to read the gallery the strip's last tile asks for it (显示最近照片); with only the photos chosen for
// the app, it chooses more (选择更多照片). A host with no gallery keeps the
// tile, which says so. The strip scrolls sideways under the finger (what scrolls across: its offset gliding on once
// let go). Made as nodes of ＋'s panel (attach.mbt): what is read of the gallery taken as the host tells it.

///|
/// How many of the gallery's photos the strip shows.
let recent_most : Int = 30

///|
/// A tile of the strip: 108 wide, 8 between (recent_tiles' gap after recent_tile_w).
// its tests alone use it: where a tile stands
#warnings("-unused_value")
let recent_step : Double = 116.0

///|
/// The strip's state while the app runs.
priv struct Recent {
  /// the gallery's answers when last read
  mut answers : (Int, Int, @hostapi.GalleryAccess)
  access : @signals.Signal[@hostapi.GalleryAccess]
  mut reading : @ui.GalleryRead?
  /// how many reads were begun (what takes a read follows it: recent_reads_node)
  reading_said : @signals.Signal[Int]
  /// read again once the read under way is taken (asked for while it read)
  mut again : Bool
  photos : @sf.LiveArray[@hostapi.GalleryPhoto]
  /// the photos chosen to go together (their `src`), in the order chosen; none as the sheet opens
  chosen : @sf.LiveArray[String]
}

///|
let recent : Recent = {
  answers: (-1, -1, NoGallery),
  access: @signals.signal(NoGallery),
  reading: None,
  reading_said: @signals.signal(0),
  again: false,
  photos: @sf.LiveArray::new(),
  chosen: @sf.LiveArray::new(),
}

///|
fn recent_reset() -> Unit {
  recent.answers = (-1, -1, NoGallery)
  recent.access.set(NoGallery)
  recent.reading = None
  recent.again = false
  recent.photos.clear()
  recent.chosen.clear()
}

///|
/// The strip's photo `i` (its first after the camera: 0).
pub fn recent_photo(i : Int) -> @hostapi.GalleryPhoto? {
  recent.photos.get(i)
}

///|
/// Whether and how the gallery may be read, as last asked.
pub fn recent_access() -> @hostapi.GalleryAccess {
  recent.access.get()
}

///|
/// How far ahead of now a time of the gallery's may be and still be believed (seconds): the phone's clock set back a
/// little since it was written.
let recent_ahead : Int64 = 60L

///|
/// The `n` photos latest into the gallery at `now` (seconds), newest first: each by when it came into it (added: the
/// gallery's own stamp as it took it in), not by when it was taken or its file last written, which the camera, other
/// apps and the gallery itself write as they will (a time zone's hours ahead, a file touched again long after) and
/// which put whatever says it is newer ahead of a picture just saved. A time in milliseconds is taken as the seconds it
/// means, one ahead of now is not believed (then the later believable of the other two ranks it); the gallery's own
/// order (its id) between photos of the same time.
fn latest_photos(photos : Array[@hostapi.GalleryPhoto], now : Int64, n : Int) -> Array[@hostapi.GalleryPhoto] {
  let believed = fn(t : Int64) -> Int64 {
    let s = if t > 100_000_000_000L { t / 1000L } else { t }
    if s >= 1L && s <= now + recent_ahead {
      s
    } else {
      0L
    }
  }
  let ranked = photos.map(fn(p) {
    let added = believed(p.added)
    if added > 0L {
      (p, added)
    } else {
      let m = believed(p.modified)
      let k = believed(p.taken)
      (p, if m > k { m } else { k })
    }
  })
  ranked.sort_by(fn(a, b) {
    if a.1 != b.1 {
      b.1.compare(a.1)
    } else {
      b.0.id.compare(a.0.id)
    }
  })
  let out = []
  for i, r in ranked {
    if i >= n {
      break
    }
    out.push(r.0)
  }
  out
}

///|
/// ＋'s sheet opened (by what opens it, as it does): none chosen, the gallery read again, what it took in since it was
/// last read with it (a screenshot just taken). Not seen by what the sheet holds: it is made only while the sheet is
/// up, so it never sees it down between two openings.
pub fn recent_opened() -> Unit {
  recent.chosen.clear()
  recent_read()
}

///|
/// The gallery read as it is now; asked while a read is under way, read again once that one is taken (one at a time,
/// none let go of unread).
fn recent_read() -> Unit {
  recent.answers = recent_gallery_state()
  if recent.reading is Some(_) {
    recent.again = true
    return
  }
  let access = recent.answers.2
  recent.access.set(access)
  recent.reading = match access {
    Whole | Chosen => @ui.gallery_read()
    _ => {
      recent.photos.replace([])
      None
    }
  }
  recent.reading_said.set(recent.reading_said.untracked() + 1)
}

///|
/// Follow host events and check permissions again when the app returns from Settings.
fn recent_gallery_state() -> (Int, Int, @hostapi.GalleryAccess) {
  @ui.app_focused() |> ignore
  (@ui.gallery_changes(), @hostapi.gallery_answers(), @hostapi.gallery_access())
}

///|
/// Refresh the strip when access or the library changes while the sheet is open.
fn recent_reads_node(v : @view.View, src : Source) -> Unit {
  v.reacts(
    recent_gallery_state,
    fn(answers) {
      if answers != recent.answers {
        recent_read()
      }
    },
  )
  v.reacts(
    fn() { (recent.reading_said.get(), @ui.gallery_reads_told()) },
    fn(_) {
      guard recent.reading is Some(read) && read.photos() is Some(all) else { return }
      recent.reading = None
      let next = latest_photos(all, ((src.now)() / 1000.0).to_int64(), recent_most)
      if v.was_placed() && !recent.photos.is_empty() {
        @view.transition(within=v.transitions_root(), fn() { recent.photos.replace(next) })
      } else {
        recent.photos.replace(next)
      }
      // Keep selections for photos that are still in the gallery.
      recent.chosen.retain(fn(s) { recent.photos.iter().any(fn(p) { p.src == s }) })
      @hostapi.log("recent photos: \{recent.photos.length()} of \{all.length()}")
      if recent.again {
        recent.again = false
        recent_read()
      }
    },
  )
}

///|
/// While photos are chosen in the strip, in node `v` where the tiles under it were (as high, so the sheet stays as it
/// is): 添加 n 个; pressed, `close` shuts the sheet and the photos chosen are read whole as one pick of them, in the
/// order chosen, given to `add` as the last is answered. `small`: in a small panel beside ＋ (attach_foot).
fn recent_adding_node(
  v : @view.View,
  add : (Array[@hostapi.Picked]) -> Unit,
  close : () -> Unit,
  small : Bool,
) -> Unit {
  let words = fn() { @sf.t("web-mobile.files.addCount", args=[("n", recent.chosen.length().to_string())]) }
  let press = fn() {
    close()
    let chosen = recent.chosen.copy()
    recent.chosen.clear()
    @ui.pick_photos(chosen, on_got=add) |> ignore
  }
  v.box(fn(row) {
    @sf.style_node(row, fn() {
      let base = recent_add_row.then(@ui.style(pb=@sf.room_of(attach_foot(small))))
      if small { base } else { base.then(@sf.panel_card_out_node(row)).then(@sf.panel_card_last_node(row)) }
    })
    row.box(fn(b) {
      @sf.style_node(b, fn() { recent_add.then(@ui.style(radius=attach_block_radius(small))) }, in_row=true)
      @sf.words_node(b, words, fn() { recent_add_words }) |> ignore
      @sf.rippled_node(b, press, attach_block_corner(small), words)
    })
    |> ignore
  })
  |> ignore
}

///|
/// Photo `src` chosen to go with the others, or not any more.
fn recent_choose(src : String) -> Unit {
  if recent.chosen.contains(src) {
    recent.chosen.retain(fn(s) { s != src })
  } else {
    recent.chosen.push(src)
  }
}

///|
/// The strip in node `v` (across the panel it is in, to its sides: scrolled, the tiles go under them): the camera, the
/// recent photos, the tile that asks; `tapped(i)` with the tile tapped: 0 the camera, 1… a photo (none chosen: it
/// alone), -1 the asking tile. A photo's ring (a finger's reach round it, as the tree's presses are reached), or any of
/// a photo while some are chosen, chooses it or not. Each as the gallery's photos, those chosen and its leave are now.
fn recent_strip_node(v : @view.View, tapped : (Int) -> Unit) -> Unit {
  let small = @sf.in_small_panel_node(v)
  let (side, top) = recent_in(small)
  let corner = attach_block_corner(small)
  let ask = fn() {
    match recent.access.get() {
      Whole => None
      Chosen => Some(@sf.t("android-chat.attach.recent.more"))
      _ => Some(@sf.t("android-chat.attach.recent.allow"))
    }
  }
  v.box(fn(bleed) {
    @sf.style_node(bleed, fn() { @sf.panel_bleed_node(v) })
    bleed.box(fn(strip) {
      strip.scrolls(@view.Scroll::across(), slop=@ui.touch_slop(), fn(held) {
        @sf.style_node(
          held,
          fn() { recent_strip_row.then(@ui.style(pl=@sf.room_of(side), pr=@sf.room_of(side), pt=@sf.room_of(top))) },
        )
        // the camera
        recent_tile_node(held, small, fn() { @sf.t("android-chat.attach.camera") }, fn() { tapped(0) }, fn(t) {
          @sf.icon_node(t, "camera", 24.0, By(fn() { @sf.theme().p.text })) |> ignore
        })
        // the photos, newest first
        held.each(
          fn() { recent.photos.map(fn(p) { (p.src, p.video) }) },
          fn(p) { p.0 },
          fn(t, p) { recent_photo_node(t, p, small, corner, tapped) },
          along_row=true,
        )
        // the tile that asks for the gallery
        held.show(fn() { ask() is Some(_) }, fn(s) {
          let words = fn() { ask().unwrap_or("") }
          recent_tile_node(s, small, words, fn() { tapped(-1) }, fn(t) {
            t.box(fn(b) {
              @sf.style_node(b, fn() { recent_ask })
              @sf.icon_node(b, "photo", 22.0, By(fn() { @sf.theme().p.muted })) |> ignore
              // (its lines each in the middle, as recent_ask_words says)
              @sf.words_node(b, words, fn() { recent_ask_words }).words_centered(Is(true)) |> ignore
            })
            |> ignore
          })
        })
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A tile of the strip in `parent` (92 × 122, the chip's grey under it), as round as attach_block_radius; `body` making
/// what it holds in it. Pressed as a button called `label` (the strip's tiles answer nothing more of the hand: the
/// strip glides under it), `press` done then.
fn recent_tile_node(
  parent : @view.View,
  small : Bool,
  label : () -> String,
  press : () -> Unit,
  body : (@view.View) -> Unit,
) -> Unit {
  @sf.action_box_node(parent, label, fn(_) { press() }, fn(t) {
    @sf.style_node(t, fn() { recent_tile_box.then(@ui.style(radius=attach_block_radius(small))) }, in_row=true)
    body(t)
  })
  |> ignore
}

///|
/// Photo `p` (its src, whether it is a video's still) of the strip, in `parent`: its picture over its tile, its ring in
/// its top end corner (chosen: its number on the primary), a video's play mark in its foot's start corner, each
/// concentric with the tile's `corner`. Pressed while none is chosen, `tapped` with its place (1 the first); while
/// some are, it is chosen or not, as its ring does.
fn recent_photo_node(
  parent : @view.View,
  p : @signals.Signal[(String, Bool)],
  small : Bool,
  corner : Double,
  tapped : (Int) -> Unit,
) -> Unit {
  let src = fn() { p.get().0 }
  let n = fn() {
    match recent.chosen.search_by(fn(s) { s == src() }) {
      Some(k) => k + 1
      None => 0
    }
  }
  recent_tile_node(
    parent,
    small,
    fn() { @sf.t(if p.get().1 { "web-main.preview.kind.video" } else { "web-main.preview.kind.image" }) },
    fn() {
      let s = @signals.untracked(src)
      if recent.chosen.length() > 0 {
        recent_choose(s)
      } else {
        match recent.photos.search_by(fn(x) { x.src == s }) {
          Some(i) => tapped(i + 1)
          None => ()
        }
      }
    },
    fn(t) {
      t.box(fn(i) {
        i
        .width(Is(Some(recent_tile_w)))
        .height(Is(Some(recent_tile_h)))
        .radius(Is(corner))
        .clips(Is(true))
        .image(By(fn() { Some((src(), "", (recent_tile_h * i.pixel_scale()).ceil().to_int())) }))
        .image_covers(Is(true))
        |> ignore
      })
      |> ignore
      // (over the picture: its ring, chosen its number, and a video's play mark)
      t.box(fn(m) {
        m.over(Is(true)) |> ignore
        @sf.style_node(m, fn() { recent_marks.then(@ui.style(p=@sf.room_of(recent_mark_in(corner)))) })
        m.box(fn(room) {
          @sf.style_node(room, fn() { recent_ring_room })
          @sf.select_ring_node(
            room,
            fn() { @sf.t("android-chat.marks.tool.select") },
            n,
            fn() { recent_choose(@signals.untracked(src)) },
            side=recent_mark_side,
          )
          |> ignore
        })
        |> ignore
        m.show(fn() { p.get().1 }, fn(k) { @sf.play_mark_node(k, recent_mark_side, A(Theater, O45)) |> ignore }, at_once=true)
      })
      |> ignore
    },
  )
}

///|
/// The strip's row: as far in as recent_in has it, 12 over its foot, its tiles 8 apart; as wide as its tiles, neither
/// held to the screen's width nor clipping (what scrolls across, Scroll::across, is the strip's width and cuts it).
// kept across runs: a value (no field of it changes)
let recent_strip_row : @ui.Style = @ui.css("row pb=S3 gap=S2")

///|
/// Extra room under ＋'s tiles: none, since `sheet_held` already provides symmetric 16pt bottom padding matching sides
/// and a small panel has its own `panel_pad`.
fn attach_foot(_small : Bool) -> Double {
  0.0
}

///|
/// How far in the strip's tiles stand from the panel's sides and under its top: in a sheet aligned with the cards below
/// (`panel_card_in`, 16) and below the 42pt top corner (`pane_corner - sheet_grab_h`); in a small panel (`small`), at
/// its padding.
fn recent_in(small : Bool) -> (Double, Double) {
  if small {
    (@sf.panel_pad, 0.0)
  } else {
    (@sf.panel_card_in, @sf.pane_corner - @sf.sheet_grab_h)
  }
}

///|
/// How round ＋'s tiles are (the strip's, 照片 文件 Station 文件, 添加 n 个): `card_corner` (26) in a sheet so tiles inset
/// 16pt from 42pt floating glass stay concentric (`26 + 16 = 42`); in a small panel (`small`), concentric with `r_menu`.
fn attach_block_corner(small : Bool) -> Double {
  if small {
    @sf.small_panel_inner(@sf.r_menu)
  } else {
    @sf.card_corner
  }
}

///|
/// attach_block_corner as a style's: a small panel's `panel_in`, else `card_radius`.
fn attach_block_radius(small : Bool) -> @ui.Radius {
  if small {
    @sf.panel_in
  } else {
    @sf.card_radius
  }
}

///|
/// What is marked on a photo's tile: its ring at its top end, a video's play mark at its foot's start, each concentric
/// with the tile's corner (recent_mark_in).
// kept across runs: a value (no field of it changes)
let recent_marks : @ui.Style = @ui.css("w=Full h=Full justify=JBetween align=AStart")

///|
/// The marks' side.
let recent_mark_side : Double = 22.0

///|
/// How far in a mark stands from the sides of a tile `corner` round: concentric with its corner (18 round: 7).
fn recent_mark_in(corner : Double) -> Double {
  @ui.capsule_in(corner, recent_mark_side)
}

///|
/// The ring's place: across the top of the tile, at its end.
// kept across runs: a value (no field of it changes)
let recent_ring_room : @ui.Style = @ui.css("row w=Full justify=JEnd")




///|
/// 添加 n 个's row, where the tiles under the strip were (as far over the foot: attach_foot).
// kept across runs: a value (no field of it changes)
let recent_add_row : @ui.Style = @ui.css("row w=Full")

///|
/// 添加 n 个: as high and round as the tiles it stands for (attach_tile, attach_block_corner), on the primary.
// kept across runs: a value (no field of it changes)
let recent_add : @ui.Style = @ui.style(
  w=Full,
  h=Fixed(recent_add_h),
  bg=Primary,
  align=ACenter,
  justify=JCenter,
)

///|
let recent_add_h : Double = 70.0

///|
// kept across runs: a value (no field of it changes)
let recent_add_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=OnPrimary, wrap=false)

///|
/// A tile: 108 × 122 (as round as attach_block_corner: what is marked in its corners concentric with it), a quiet ground
/// under it.
// kept across runs: a value (no field of it changes)
let recent_tile_box : @ui.Style = @ui.style(
  w=Fixed(recent_tile_w),
  h=Fixed(recent_tile_h),
  bg=Neutral,
  clip=true,
  align=ACenter,
  justify=JCenter,
)

///|
let recent_tile_w : Double = 108.0

///|
let recent_tile_h : Double = 122.0

///|
/// The tile that asks for the gallery: its picture over what it asks, 8 in.
// kept across runs: a value (no field of it changes)
let recent_ask : @ui.Style = @ui.css("px=S2 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let recent_ask_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L4, center=true, balance=true)
