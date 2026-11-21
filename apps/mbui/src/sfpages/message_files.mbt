// A message's files on the desktop (still.fail web/src/Chat.tsx Files, FileItem, MessageFileCard, imageBox.ts; Chat.css.ts
// msgFiles, msgImage, msgImageWait, msgVideo, fileCardOpen; styles/later.css.ts): side by side, wrapping 6 apart; an
// image in a box of its own proportions (known before it loads), brushed in from its top once decoded; a video's
// still on black with its capsule (its length) in its foot's corner; anything else a card. Pressed, each opens in the file viewer
// (viewer.mbt). While the core downloads one (downloads.mbt), how far on its card, ✕ to call it off, ↻ to ask it
// again.

///|
/// The session whose workspace keeps a message's file: as the core says it, else the chat's first agent's (useKeeper).
fn owner_of(here : MessageHere, a : Attachment) -> String {
  if a.owner != "" {
    a.owner
  } else {
    match here.view.agents.get(0) {
      Some(ag) => ag.key
      None => here.session
    }
  }
}

///|
/// The last part of a path: the name the station keeps a file by (storedName).
fn stored_name(path : String) -> String {
  @sfbase.base_name(path)
}

///|
/// A message's file opened in the preview (FilePreview): an image steps through the chat's. `beside`: asked beside the
/// chat (its menu's 在侧边打开); else as the press asks (open_preview's).
fn open_file(here : MessageHere, a : Attachment, at? : String = "", beside? : Bool) -> Unit {
  match beside {
    Some(b) => open_preview(here.station, owner_of(here, a), a, steps=InChat(here.view.thread, here.session), at~, beside=b)
    None => open_preview(here.station, owner_of(here, a), a, steps=InChat(here.view.thread, here.session), at~)
  }
}

///|
/// 在侧边打开 of a message's file, where it is offered (beside_offered: a side panel for the chat, a file that opens
/// there): the file in a tab beside the chat.
fn beside_option(here : MessageHere, a : Attachment, at : String) -> @sf.MenuItem? {
  if !@sfbase.beside_offered(a.path, a.name) {
    return None
  }
  Some(@sf.menu_item_of(@sf.t("web-main.preview.openBeside"), fn() { open_file(here, a, at~, beside=true) }, icon="panel-open"))
}

///|
/// The last request to open a named path: a late answer cannot replace a later choice.
let named_open_serial : Ref[Int] = Ref(0)

///|
/// A link in what agent `agent` wrote, pressed: a file it names opens from that agent's machine, any other link as
/// links do.
fn open_agent_link(src : Source, station : String, agent : String, href : String) -> Unit {
  match @sf.local_path_of_link(href) {
    Some(path) if agent != "" => open_named(src, station, agent, path)
    _ => open_link(href)
  }
}

///|
/// A file an agent names by its path: check it in the agent's session before opening it. A path in code can name
/// something that was never a file, or one removed since the pointer last rested on it. `beside`: asked beside the chat
/// (its menu's 在侧边打开); else as the press asked, over the whole window or not said as it is pressed (full_asked),
/// not as the answer comes.
fn open_named(src : Source, station : String, agent : String, path : String, beside? : Bool) -> Unit {
  let full = beside is None && @sfbase.full_asked()
  named_open_serial.val += 1
  let serial = named_open_serial.val
  guard agent != "" && !is_dir_path(path) else { return }
  let page = @sfbase.app.nav.top()
  let params : Map[String, Json] = {
    "station": Json::string(station),
    "key": Json::string(agent),
    "path": Json::string(path),
  }
  (src.call)("file.peek", Json::object(params), fn(answer) {
    guard named_open_serial.val == serial && @sfbase.app.nav.top() == page && @sfbase.viewer.get() is None else { return }
    match answer {
      Ok(Object(_) as file) if text(Some(file), "kind") != "" && text(Some(file), "kind") != "dir" => {
        let a = attachment_of({ "name": Json::string(stored_name(path)), "path": Json::string(path) })
        match beside {
          Some(b) => open_preview(station, agent, a, named=true, beside=b)
          None => open_preview(station, agent, a, named=true, full~)
        }
      }
      // (not opened is said, as the web's FileRef says a failed open: the press is not left without an answer)
      Ok(_) => toast_later(@sf.t("web-main.preview.openFailed", args=[("name", stored_name(path)), ("error", @sf.t("web-main.preview.openFolder"))]))
      Err(e) => toast_later(@sf.t("web-main.preview.openFailed", args=[("name", stored_name(path)), ("error", text(Some(e), "message"))]))
    }
  })
}

///|
/// What a file is by its name (as the chat tells them apart): image, video, or anything else.
pub fn file_kind(name : String) -> String {
  match @sfbase.preview_kind(name).0 {
    Some(@sfbase.KImage) => "image"
    Some(@sfbase.KVideo) => "video"
    _ => ""
  }
}

///|
/// The box an image takes in the chat, known before it loads: its own proportions (sent with it, or its
/// ThumbHash's) within 360×300, a tiny one drawn to 40 on its longer side; a strip thinner than `least` letterboxed in
/// a box that thick; 240×160 for one sent before sizes were kept. An image at the height limit is cropped to at least
/// `min_side` across, one at the width limit to at least `min_side` high. (width, height, letterboxed)
pub fn image_box(a : Attachment, least : Double, min_side? : Double = 0.0) -> (Double, Double, Bool) {
  let (w, h) = match own_size(a) {
    Some(s) => s
    None => return (box_unknown_w, box_unknown_h, false)
  }
  let width_scale = box_most_w / w
  let height_scale = box_most_h / h
  let scale = dmin(dmin(dmax(1.0, box_tiny / dmax(w, h)), width_scale), height_scale)
  let width = w * scale
  let height = h * scale
  let hash_only = a.width <= 0.0 || a.height <= 0.0
  if (scale == height_scale || hash_only) && w * box_most_h / h < min_side {
    return (min_side.round(), box_most_h, false)
  }
  if (scale == width_scale || hash_only) && h * box_most_w / w < min_side {
    return (box_most_w, min_side.round(), false)
  }
  if width >= least && height >= least {
    return (width.round(), height.round(), false)
  }
  (dmax(least, width).round(), dmax(least, height).round(), true)
}

///|
/// An image's width over its height in the chat (its image_box's), as a table's cell draws it that wide (@sf.Placed's
/// `image`); None for any other file.
fn image_ratio(a : Attachment) -> Double? {
  guard file_kind(a.name) == "image" else { return None }
  let (w, h, _) = image_box(a, image_least, min_side=image_min_side)
  Some(w / h)
}

///|
/// An image's own proportions, as known before it loads: its size sent with it, else its ThumbHash's at the unknown
/// box's height; None for one sent before sizes were kept.
fn own_size(a : Attachment) -> (Double, Double)? {
  if a.width > 0.0 && a.height > 0.0 {
    Some((a.width, a.height))
  } else {
    thumb_ratio(a.thumbhash).map(fn(r) { ((box_unknown_h * r).round(), box_unknown_h) })
  }
}

///|
/// Whether the chat's least side crops an image: a tall one at the least width, a wide strip at the least height. Either
/// shows its beginning (its top, its left), not its middle: the middle of a strip cut from a page is as often its bare
/// ground (2026-11-15: a window's head cut across, its title at the left and its buttons at the right, shown as a box
/// of nothing).
fn image_cropped_from_start(a : Attachment) -> Bool {
  let (bw, bh, _) = image_box(a, image_least, min_side=image_min_side)
  match own_size(a) {
    Some((w, h)) =>
      (bw == image_min_side && bh == box_most_h && w * bh / h < bw) ||
      (bh == image_min_side && bw == box_most_w && h * bw / w < bh)
    None => false
  }
}

///|
/// The share of its box's width and height a picture takes in it (image_box's, `least` thick): all of it, or a
/// letterboxed one's, its own proportions fitted inside, centred.
pub fn picture_share(a : Attachment, least : Double, min_side? : Double = 0.0) -> (Double, Double) {
  let (bw, bh, letterbox) = image_box(a, least, min_side~)
  match own_size(a) {
    Some((w, h)) if letterbox => {
      let k = dmin(bw / w, bh / h)
      (w * k / bw, h * k / bh)
    }
    _ => (1.0, 1.0)
  }
}

///|
/// A ThumbHash's width over its height, from its header.
fn thumb_ratio(hash : String) -> Double? {
  if hash == "" {
    return None
  }
  @pixels.thumbhash_ratio(@codec.from_base64(hash))
}

///|
/// Its message's file `a` quoted into the chat's draft, where it is a message's (`by`: whose, their role, its ts).
fn quote_of(here : MessageHere, a : Attachment, owner : String, by : (String, String, String)?) -> (() -> Unit)? {
  by.map(fn(b) {
    let (author, role, ts) = b
    let file = attachment_json(a, owner)
    let draft = here.station + ":" + here.session
    fn() { quote_file_into(draft, author, ts, role, file) }
  })
}

///|
/// Download this attachment through the core, with the chat and original attachment so the transfer leads back here.
fn download_option(src : Source, here : MessageHere, a : Attachment, owner : String) -> @sf.MenuItem? {
  let (station, name, size) = (here.station, stored_name(a.path), a.size)
  let going_up = a.upload != "" && a.path == @sfbase.upload_path(a.upload)
  let active = flag(download_of(src, station, owner, name), "active")
  let from : Map[String, Json] = { "session": Json::string(here.session), "file": attachment_json(a, a.owner) }
  match here.view.thread {
    Some(n) => from["thread"] = Json::number(n)
    None => ()
  }
  Some(@sf.menu_item_of(
    @sf.t("web-main.preview.download"),
    fn() { download_start(src, station, owner, name, size, from=Json::object(from)) },
    icon="download",
    disabled=going_up || name == "" || active,
  ))
}

///|
/// A message's file's menu opened (`open`, handed its 在访达中显示 where there is one: the file shown in its folder on
/// this device, @sfbase.file_here): at once where this device shows no file in its folder or the file is its station's
/// here; else once the core has said where it was downloaded to here, waited for as a press waits for the core
/// (press_wait), no longer than a card waits for what it reads of the device. Made in a press's handler.
fn with_reveal(src : Source, here : MessageHere, a : Attachment, owner : String, open : (@sf.MenuItem?) -> Unit) -> Unit {
  if !@hostapi.reveals_files() {
    open(None)
    return
  }
  let item = fn(at : String) -> @sf.MenuItem? {
    guard at != "" else { return None }
    Some(@sf.menu_item_of(@sfbase.reveal_words(), fn() { @sfbase.reveal_here(at, a.name) }, icon="folder"))
  }
  let said : @signals.Signal[String?] = @signals.signal(None)
  @sfbase.file_here(src, here.station, owner, stored_name(a.path), a.size, a.path, fn(at) { said.set(Some(at)) })
  @sfbase.press_wait(
    fn() { said.get() is Some(_) },
    fn() { open(item(@signals.untracked(fn() { said.get() }).unwrap_or(""))) },
    most=@sf.open_hold_ms,
  )
  |> ignore
}

///|
/// How long a picture waits before how far it has come shows, and how long that takes to fade in.
pub let coming_after_ms : Double = 300.0

///|
pub let coming_in_ms : Double = 200.0

///|
/// The pill's ring (14 across), or the spinner in its place on white at 25%.
let coming_ring : Double = 14.0

///|
/// The pill's height: its ring and its words' line, as a video's capsule (@sf.video_capsule: the same ring and
/// words, its ends S1_5 each); 18, so that it stands concentric in a picture's corner (a card's, 26) no further in
/// than corner_fit lets it (16).
let coming_pill_h : Double = 18.0

///|
/// How far the pill is from the picture's sides and foot: concentric with its corner (26 less its half: 17; 8 in, its
/// ends were rounder than that corner left room for, which the corners' check refused).
let coming_in : Double = @ui.capsule_in(@sf.message_file_corner, coming_pill_h)

///|
/// How far the pill is from the picture's sides and foot where no corner leads it.
let coming_alone_in : Double = 8.0

///|
let coming_track : Int64 = 0xFFFFFF40L

///|
// kept across runs: a value (no field of it changes)
let coming_room : @ui.Style = @ui.style(
  w=Full,
  h=Full,
  p=@sf.room_of(coming_in),
  align=AEnd,
  justify=JEnd,
)

///|
// kept across runs: a value (no field of it changes)
let coming_pill : @ui.Style = @ui.style(
  row=true,
  h=Fixed(coming_pill_h),
  gap=S1,
  px=S1_5,
  radius=Full,
  bg=@sf.video_shade,
  align=ACenter,
)

///|
// kept across runs: a value (no field of it changes)
let coming_words : @ui.TextStyle = @ui.text_style(size=Caption, color=@sf.white_ink, wrap=false, tabular=true)

///|
/// How much larger a message's picture is lifted all the way, held for its menu.
let file_lift_scale : Double = 1.04

///|
/// What the core says of a file's card's download (dl), and of its being brought after everything else once opened
/// and let go (fill.ts: kept), which stands in the download's place.
fn card_coming(src : Source, here : MessageHere, a : Attachment) -> (Json?, Json?) {
  let owner = owner_of(here, a)
  let dl = download_of(src, here.station, owner, stored_name(a.path))
  // opened and let go, being brought after everything else (fill.ts): how far in its size's place, ✕ stops it
  let kept = if flag(dl, "active") { None } else { keeping_of(src, here.station, owner, stored_name(a.path)) }
  (if kept is Some(_) { kept } else { dl }, kept)
}

///|
/// The spacing scale's first step `d` or more (gaps.mbt rule 6: a gap is a step of it).
fn scale_up(d : Double) -> Double {
  for s in @ui.space_scale() {
    if s.px() >= d - 0.01 {
      return s.px()
    }
  }
  d
}

///|
/// Each image's way in, by its source, while the run lasts (None: first shown decoded, as it is).
let reveals : Map[String, @motion.Anim?] = Map([])

///|
/// What the messages keep of their own, let go (the package's reset).
fn message_reset() -> Unit {
  named_open_serial.val += 1
  reveals.clear()
  notices_open.clear()
}

///|
/// How long an image comes in, how blurred and how much larger it starts (a blur under a quarter is none), and when
/// and how fast what it waited on goes; its edge's steps.
pub let reveal_ms : Double = 1100.0

///|
/// An image decoded at most this many pixels on its longer side.
let image_px_most : Double = 8192.0

///|
/// The least an image's box is across (16) and a video's (96: room round its capsule); the box of one sent before
/// sizes were kept (240×160); the most (360×300); a tiny one drawn to 40 on its longer side.
pub let image_least : Double = 16.0

///|
/// An image at the height limit is at least this wide, one at the width limit at least this high: cropped without
/// changing its proportions.
pub let image_min_side : Double = 160.0

///|
pub let video_least : Double = 96.0

///|
let box_unknown_w : Double = 240.0

///|
let box_unknown_h : Double = 160.0

///|
let box_most_w : Double = 360.0

///|
let box_most_h : Double = 300.0

///|
let box_tiny : Double = 40.0

///|
/// Files 6 apart (msgFiles gap).
let files_gap : Double = 6.0

///|
/// An unavailable image's mark (20).
let no_preview_icon : Double = 20.0

///|
// kept across runs: a value (no field of it changes)
let files_column : @ui.Style = @ui.css("w=Full gap=S1_5 align=AStart")

///|
/// How far a message's files are under its words: 8, twice what is between its other parts (msg_main's gap), a card
/// being heavier than a line.
let files_under_words : Double = 8.0

///|
/// An image's box (msgImage): clipped to its corners (in a corner of what holds it, a quote's card, concentric with
/// that one); the neutral ground while it waits.
// kept across runs: a value (no field of it changes)
let image_frame : @ui.Style = @ui.style(radius=InnerOr(@sf.message_file_radius), clip=true)

///|
/// A picture's box's corner `corner` on a node (message_image_node, message_video_node: a message's file's, or a
/// quote's own picture's concentric with its card: @sf.quote_picture_corner).
fn frame_corner_node(corner : Double) -> @ui.Style {
  @ui.style(radius=@sf.file_radius(corner))
}

///|
// kept across runs: a value (no field of it changes)
let image_frame_waiting : @ui.Style = image_frame.then(@ui.css("bg=Neutral"))

///|
/// Where a letterboxed picture is (msgImage[data-letterbox]): in its box's middle.
// kept across runs: a value (no field of it changes)
let letterbox_room : @ui.Style = @ui.css("w=Full h=Full align=ACenter justify=JCenter")

///|
/// letterbox_room waiting on its picture, nothing of it to show yet: the neutral ground (image_fill_waiting's).
// kept across runs: a value (no field of it changes)
let letterbox_room_waiting : @ui.Style = letterbox_room.then(@ui.css("bg=Neutral"))

///|
/// One that cannot be had (msgImageUnavailable): its mark over 无法预览, muted, in its middle.
// kept across runs: a value (no field of it changes)
let no_preview_box : @ui.Style = @ui.css("w=Full h=Full gap=S1_5 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let no_preview_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false)

///|
/// A video's box (msgVideo): black, clipped to its corners; nothing over its picture but its capsule
/// (@sf.video_capsule).
// kept across runs: a value (no field of it changes)
let video_frame : @ui.Style = @ui.style(radius=InnerOr(@sf.message_file_radius), clip=true)

