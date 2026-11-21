// A file and a quote as a message and the composer show them (still.fail web/src/Chat.tsx FileTile, FileName, FileCard,
// QuoteCard; Chat.css.ts fileTile, fileCard…, quoteCard…, later.css.ts fileCard): a file's sheet with its extension on
// it, its name cut in its middle, its card with its size or how far it has gone; a quote's card with whose it is, its
// own picture and what is said about it.

///|
/// The outlines of a tile's drawing (its path data) at `scale`: cut once for each, not again on every frame each tile is
/// drawn.
fn tile_outlines(d : String, scale : Double) -> Array[(Array[Double], Bool)] {
  match tiles_made.get((d, scale)) {
    Some(o) => o
    None => {
      let o = @pixels.svg_path(d, scale)
      tiles_made[(d, scale)] = o
      o
    }
  }
}

///|
/// The tiles' outlines cut so far, by their path data and scale (tile_outlines).
let tiles_made : Map[(String, Double), Array[(Array[Double], Bool)]] = Map([])

///|
/// The sheet filled from its foot `part` of its height (FileTile's rect from y = 36 − 36 × part, cut to the sheet's
/// outline): the outline's inside (a convex shape) cut below that line, in the sheet's points (its curves cut for
/// `scale` pixels a point).
pub fn file_tile_fill(scale : Double, part : Double, color : Int64) -> @ui.Shape {
  let share = if part < 0.0 { 0.0 } else if part > 1.0 { 1.0 } else { part }
  let from = tile_h * (1.0 - share)
  let cut = tile_outlines(tile_outline, scale).filter_map(fn(o) {
    let (pts, closed) = o
    let n = pts.length() / 2
    let out : Array[Double] = []
    for i in 0..<n {
      let (ax, ay) = (pts[2 * i], pts[2 * i + 1])
      let j = (i + 1) % n
      let (bx, by) = (pts[2 * j], pts[2 * j + 1])
      if ay >= from {
        out.push(ax)
        out.push(ay)
      }
      if (ay >= from) != (by >= from) {
        let k = (from - ay) / (by - ay)
        out.push(ax + (bx - ax) * k)
        out.push(from)
      }
    }
    // (nothing of it come yet: nothing filled)
    if out.length() < 6 {
      None
    } else {
      Some((out, closed))
    }
  })
  @ui.shape_of(cut, fill=color)
}

///|
/// A file's line icon by what it is, from its name (drive.mbt dv_kind_icon's): a video's, a sound's, a picture's, a
/// PDF's, words', code's, else a file's.
pub fn file_mark(name : String) -> String {
  match extension_of(name) {
    "mp4" | "m4v" | "webm" | "mov" | "mkv" | "avi" | "ogv" => "file-video"
    "mp3" | "m4a" | "wav" | "flac" | "ogg" | "aac" | "opus" => "file-audio"
    "png" | "jpg" | "jpeg" | "gif" | "webp" | "svg" | "avif" | "bmp" | "heic" => "photo"
    "pdf" => "file-pdf"
    "txt" | "md" | "markdown" | "log" | "rtf" | "srt" | "vtt" | "ass" | "ssa" => "file-text"
    "js" | "ts" | "tsx" | "jsx" | "json" | "py" | "rs" | "go" | "mbt" | "c" | "h" | "cpp" | "java" | "kt" | "swift"
    | "sh" | "yml" | "yaml" | "toml" | "html" | "css" | "csv" | "xml" | "sql" | "rb" | "php" => "file-code"
    _ => "file"
  }
}

///|
/// A file's mark on its card: its line icon, 24, its box its own (no room round it: the gap to its words the card's).
// kept across runs: a value (no field of it changes)
let card_mark : @ui.Style = @ui.css("w=S6 h=S6 align=ACenter justify=JCenter")

///|
let card_mark_size : Double = 24.0

///|
/// The sheet's outline, its fold, its two lines (where it has no extension), a folder's shape (FileTile's paths), and
/// what it is drawn with.
let tile_outline : String = "M6 1.75H19L26.25 9V31Q26.25 34.25 23 34.25H6Q2.75 34.25 2.75 31V5Q2.75 1.75 6 1.75Z"

///|
let tile_h : Double = 36.0

///|
/// The most an extension is long, its dot with it (FileName: 7).
let name_ext_most : Int = 8

///|
/// What of a file's card a press was on: its ✕, its ↻ or its ✎, or (one that opens) the card itself.
#derive(Eq, Debug)
pub(all) enum FileCardPress {
  Remove
  Retry
  Restore
  Open
}

///|
/// By its name, as tests write what a file card's press asked: what `derive(Show)` wrote.
pub impl Show for FileCardPress with output(self, logger) {
  logger.write_string(
    match self {
      Remove => "Remove"
      Retry => "Retry"
      Restore => "Restore"
      Open => "Open"
    },
  )
}

///|
/// How far the ✕ of what waits to go reaches past its top and its right edge, its corner `corner`:
/// the room a row of them keeps between its lines.
pub fn corner_remove_reach(corner : Double) -> Double {
  on_corner(corner, corner_remove_side)
}

///|
let corner_remove_side : Double = 20.0

///|
// kept across runs: a value (no field of it changes)
let card_end_room : @ui.Style = @ui.css("w=S6 h=S6 align=ACenter justify=JCenter")

///|
/// What a message carries is rounded as every card in a chat is (a question's, a screen's with its picture, pictures,
/// videos, pasted text): the ladder's card step (26). One a row high (a file's card, a screen's or a service's
/// without a picture) is a capsule (card_box).
pub let message_file_corner : Double = card_corner

///|
pub let message_file_radius : @ui.Radius = rounded(message_file_corner)

///|
/// A picture's corner `corner` as a style's: a message's file's, or a quote's own picture's (quote_picture_corner).
pub fn file_radius(corner : Double) -> @ui.Radius {
  rounded(corner)
}

///|
/// A file's card at its widest (fileCard: 236).
pub let file_card_w : Double = 236.0

///|
let card_button_icon : Double = 13.0

///|
let card_close_icon : Double = 12.0

///|
// kept across runs: a value (no field of it changes)
let card_box : @ui.Style = @ui.style(
  row=true,
  max_w=Fixed(file_card_w),
  // (a row high, a capsule, 52 (file_capsule_h): its mark, 24, concentric with its round end (14 from its
  // end, its top and its foot), 8 from its words, their end where the other round end begins, 24 from that end
  // (file_capsule_words_end; a button there concentric with it instead: card_end_justified): file_card_across; as a
  // screen's card, @sfbase's link_card. In the composer: card_waiting)
  h=file_capsule_h,
  pl=S3_5,
  pr=room(file_capsule_words_end),
  gap=S2,
  bg=Neutral,
  // (in a corner of what holds it, a composer's box: as far in as from its edges, its corner concentric)
  radius=InnerOr(Full),
  align=ACenter,
)

///|
/// A message's file card with a button at its end (its ✕, its ↻, a slot for one laid over it): that end's room its
/// start's (14), so that the button there (in card_end_room's 24) stands concentric with it as the mark does with the
/// start.
// kept across runs: a value (no field of it changes)
let card_end_justified : @ui.Style = @ui.css("pr=S3_5 justify=JBetween")

///|
/// What waits in the composer (a file's card, a quote) stands off its frosted ground by its own ground alone, no shadow
/// (the user, 2026-10-16: 附件有点难以分辨; 2026-10-25: 背景色好分辨就行了，不用这么深阴影): the capsule whiter than its
/// paper, the neutral one; in the dark a step up (the text at 10% over what floats).
pub fn composer_card() -> @ui.Style {
  composer_card_ground
}

///|
// kept across runs: a value (no field of it changes)
let composer_card_ground : @ui.Style = @ui.css("bg=Neutral dark{bg=Over(Raised, A(Fg, O10))}")

///|
let tile_going_spinner : Double = 16.0

///|
// kept across runs: a value (no field of it changes)
let card_words : @ui.Style = @ui.style(w=grow)

///|
// kept across runs: a value (no field of it changes)
let card_words_hug : @ui.Style = @ui.css("w=Cut")

///|
// kept across runs: a value (no field of it changes)
let card_name : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, leading=L6, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let card_meta : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, leading=L4, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let card_failed : @ui.TextStyle = card_meta.then(@ui.text_style(color=Danger))

///|
// kept across runs: a value (no field of it changes)
let card_button_box : @ui.Style = @ui.style(
  w=Fixed(card_button_side),
  h=Fixed(card_button_side),
  radius=Full,
  align=ACenter,
  justify=JCenter,
)

///|
/// A card's own button across (fileCardRemove: 22).
let card_button_side : Double = 22.0

///|
// kept across runs: a value (no field of it changes)
let card_button_hot : @ui.Style = card_button_box.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value (no field of it changes)
let name_row : @ui.Style = @ui.css("row w=Full")

///|
/// A mark on a previewed page or an image (`role`): its pin's number, the digits `author` ends with; "" for any other
/// quote.
fn pin_of(author : String, role : String) -> String {
  if role != "page" && role != "image" {
    return ""
  }
  let digits = StringBuilder()
  for ch in author.rev_iter() {
    if ch >= '0' && ch <= '9' {
      digits.write_char(ch)
    } else {
      break
    }
  }
  digits.to_string().rev()
}

///|
/// A quote's mark (11, the accent's) in a box as tall as its line.
let quote_icon : Double = 11.0

///|
/// quoteCard: a bubble's corner in a message (quote_box_message), in the composer its inner corner; the text at 4% over
/// the canvas.
// kept across runs: a value (no field of it changes)
let quote_box : @ui.Style = @ui.style(w=Full, radius=rounded(quote_corner), bg=Over(Bg, faint_ground), clip=true)

///|
/// In a message, as a message's bubble (sfpages message.mbt bubble: Xl2, its words 14 across and 8 over and under):
/// what it holds the bubble's 8 in from its edges (its picture the ladder's 10: quote_picture), 6 apart; its words as far
/// in across as a bubble's.
// kept across runs: a value (no field of it changes)
let quote_box_message : @ui.Style = quote_box.then(@ui.style(p=room(quote_card_in), gap=S1_5))

///|
let quote_card_in : Double = 8.0

///|
/// A quote's own picture in a message (an image, a video's still): in its card's foot corners, so as anything with a
/// ground there, the ladder's inset in (quote_picture) and round by the ladder's next step, concentric with the card
/// (its 18, so 10), all four corners alike; a message's file's 26 alone there is rounder than the card round it (the
/// user, 2026-11-02).
pub let quote_picture_corner : Double = @ui.concentric(quote_corner, corner_inset)

///|
/// A quote's corner in a message: a message's bubble's.
let quote_corner : Double = radii.xl2

///|
fn quote_box_composer() -> @ui.Style {
  quote_box.then(@ui.style(radius=composer_inner_radius()))
}

///|
/// What sits in the composer's corners is rounded concentric with it, its padding in (composer_corner: alone a card's,
/// so the ladder's next step, a row's; at the tape's foot 24.8, so 16.8): what waits in it (a quote, a file's card, a
/// picture), every one alike. Never rounder than alone (a row's): a composer rounder than a card (an iPhone Duo's screen
/// corners, 39) would make a 56 picture a circle, so there what waits stands further in (composer_waiting_in).
pub fn composer_inner() -> Double {
  dmin(@ui.concentric(composer_corner(), composer_pad), row_corner)
}

///|
/// How much further in than the padding what waits in the composer stands, concentric with its corner at
/// composer_inner: none where that is concentric at the padding.
pub fn composer_waiting_in() -> Double {
  dmax(composer_corner() - composer_pad - composer_inner(), 0.0)
}

///|
pub fn composer_inner_radius() -> @ui.Radius {
  rounded(composer_inner())
}

///|
/// The composer's padding: the ladder's inset, so what stands in its corners has the ladder's next corner (a quote's,
/// a file's; its round controls round there: the computer's 32 and the phone's 36 alike).
pub let composer_pad : Double = corner_inset

///|
/// How much short of the box's padding the files over a composer's words end their lines: the rest of its top corner
/// past the padding (composer_corner less composer_pad). What wraps there ends where it lands, so the last of the first
/// line would otherwise stand in that corner at some widths, neither concentric with it nor out of it (the corner
/// rule); kept out of it, it is out at every width.
pub fn composer_files_end() -> Double {
  composer_corner() - composer_pad
}

///|
/// Its words in a message: a bubble's 14 in from its edge, its card's padding over and under them (in the composer 9
/// over, 16 at its start, 34 at its end for its ✕).
// kept across runs: a value (no field of it changes)
let quote_source : @ui.Style = @ui.style(w=Full, px=room(quote_in))

///|
/// A quote card's words in a message further in across than its card's padding, to a bubble's 14 (none further
/// over); in the composer 16 in, 34 at its end, 9 over; what is said 3 under the words, 10 under it there.
let quote_in : Double = 14.0 - quote_card_in

///|
let quote_end_composer : Double = 34.0

///|
let quote_in_composer : @ui.Space = S4

///|
let quote_over_composer : Double = 9.0

///|
let quote_said_over : Double = 3.0

///|
// kept across runs: a value (no field of it changes)
let quote_source_composer : @ui.Style = @ui.style(
  w=Full,
  pl=quote_in_composer,
  pr=room(quote_end_composer),
  pt=room(quote_over_composer),
)

///|
/// How far from a quote's top and start its pin (a capsule quote_pin_h high) stands, concentric with its corner
/// (capsule_in); in the composer, with a row's.
let quote_pin_in : Double = @ui.capsule_in(quote_corner, quote_pin_h)

///|
let quote_pin_in_composer : Double = @ui.capsule_in(row_corner, quote_pin_h)

///|
let quote_pin_h : Double = 16.0

///|
/// A page mark's quote: its pin (a capsule 16 high) as far from its top and start as makes it concentric with its
/// corner (quote_pin_in).
// kept across runs: a value (no field of it changes)
let quote_source_pin : @ui.Style = quote_source.then(
  @ui.style(pl=room(quote_pin_in - quote_card_in), pt=room(quote_pin_in - quote_card_in)),
)

///|
/// With its ✕ hung on its corner, nothing kept at its end for it: its words as far in at its end
/// as at its start.
// kept across runs: a value (no field of it changes)
let quote_source_hung : @ui.Style = quote_source_composer.then(@ui.css("pr=S4"))

///|
// kept across runs: a value (no field of it changes)
let quote_source_hung_pin : @ui.Style = quote_source_hung.then(
  @ui.style(pl=room(quote_pin_in_composer), pt=room(quote_pin_in_composer)),
)

///|
// kept across runs: a value (no field of it changes)
let quote_words : @ui.Style = @ui.css("row w=Full gap=S1 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let quote_mark : @ui.Style = @ui.css("h=S4_5 justify=JCenter")

///|
/// quoteCardText: 12 on 18 (1.5), two lines at most, muted; the text's ink under the pointer when it leads somewhere.
// kept across runs: a value (no field of it changes)
let quote_text : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, max_lines=2)

///|
// kept across runs: a value (no field of it changes)
let quote_text_hot : @ui.TextStyle = quote_text.then(@ui.text_style(color=Fg))

///|
/// quoteCardPin: a page mark's number as its pin, 16 high, the accent's ground, white; a capsule (a circle for one
/// figure), so in its quote's corner it stands where its shape is concentric with it (the web's corner 8 8 8 2).
// kept across runs: a value (no field of it changes)
let quote_pin : @ui.Style = @ui.css("h=S4 min_w=S4 px=S1 radius=Full bg=Accent align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let quote_pin_words : @ui.TextStyle = @ui.text_style(size=Caption, weight=Semibold, color=OnAccent, wrap=false)

///|
/// Its picture in a message: in its card's foot corners the ladder's inset in from its sides and foot, past its card's
/// padding (in the composer 6 over it, 16 in).
// kept across runs: a value (no field of it changes)
let quote_picture : @ui.Style = @ui.style(
  row=true,
  px=room(corner_inset - quote_card_in),
  pb=room(corner_inset - quote_card_in),
)

///|
// kept across runs: a value (no field of it changes)
let quote_picture_composer : @ui.Style = @ui.css("row px=S4 pt=S1_5")

///|
/// quoteCardComment: 3 over, 16 in, 10 under it in the composer; in a message's, as far in as its words.
// kept across runs: a value (no field of it changes)
let quote_comment : @ui.Style = @ui.style(w=Full, px=room(quote_in))

///|
// kept across runs: a value (no field of it changes)
let quote_comment_composer : @ui.Style = @ui.style(w=Full, px=S4, pt=room(quote_said_over), pb=S2_5)

///|
// kept across runs: a value (no field of it changes)
let quote_said : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg)
