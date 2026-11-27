// Links to a station's screens and to its 共享调试 in an agent's words (still.fail apps/android chat/screens/ScreenLinks.kt,
// AdbLinks.kt), as the web draws them: one alone in a paragraph is its card (a screen's; 共享调试's is a link to its page
// alone too) (@sf.markdown's `screens`), a bare one within a sentence reads as its title. What a card says is the core's (the
// `screenCard` and `adbCard` topics). A screen its station previews is live in its card while the card is built (the
// messages' list builds only the rows in view) and the app is shown: `screen.view` with `peek`, small, each frame
// acknowledged peek_ms after the one before (the station sends the next once the last is acknowledged); stopped (the
// call cancelled) as the card goes from view or the app behind. JPEG, and H.264 where the host decodes it: a source
// that has JPEG sends it a preview, one with nothing else (an Android device) H.264, decoded by a Stream of the card's,
// video_peeks_most of those at once. One refused (its station previews as many as it can) or ended asks again
// peek_again_ms on while its card is on the screen. A card's tap opens its link, as a tap on the link
// does (open_links.mbt open_link).

///|
/// A preview's pace: a picture at most this often.
pub let peek_ms : Double = 500.0

///|
/// The picture a preview asks for, in pixels at most: the card's width, twice over.
pub let peek_size : Double = 640.0

///|
/// A preview refused or ended is asked for again after this, while its card shows.
pub let peek_again_ms : Double = 5000.0

///|
/// The most previews the app decodes as a video at once (an Android device's): a phone has few hardware decoders.
/// One more is let go, its mark shown, and asks again peek_again_ms on.
pub let video_peeks_most : Int = 2

///|
/// The shape of a browser's preview (16:10), and the default before another screen's size is known.
pub let peek_ratio : Double = 1.6

///|
pub let peek_ratio_least : Double = 0.75

///|
pub let peek_ratio_most : Double = 2.0

///|
/// A card uses the same icon as its tab and the shared library, centered in the file tile's room.
pub(all) struct LinkMark {
  name : String
}

///|
// kept across runs: an immutable icon name
pub let monitor_mark : LinkMark = { name: "monitor" }

///|
// kept across runs: an immutable icon name
pub let globe_mark : LinkMark = { name: "web" }

///|
// kept across runs: an immutable icon name
pub let terminal_mark : LinkMark = { name: "terminal" }


// ── the cards' looks ──

///|
/// A card: a row 236 wide, a capsule as a file's card (a row high, 52), on the chat's bubble ground: its mark, 24,
/// concentric with its round end (14 from its end, its top and its foot), 8 from its words, their end where the other
/// round end begins (@sf.file_capsule_words_end).
// kept across runs: a value (no field of it changes)
pub let link_card : @ui.Style = @ui.style(
  row=true,
  w=@sf.link_card_w,
  h=@sf.file_capsule_h,
  pl=S3_5,
  pr=@sf.room_of(@sf.file_capsule_words_end),
  gap=S2,
  align=ACenter,
  radius=Full,
  bg=Neutral,
)

///|
/// A screen's card with its preview: a column 280 wide, rounded as what a message carries is (@sf.message_file_radius),
/// the preview the ladder's inset in from its top and sides (@sf.peek_card_in_px).
// kept across runs: a value (no field of it changes)
pub let peek_card : @ui.Style = @ui.style(
  w=@sf.peek_card_w,
  pt=@sf.room_of(@sf.peek_card_in_px),
  px=@sf.room_of(@sf.peek_card_in_px),
  radius=@sf.message_file_radius,
  bg=Neutral,
)

///|
/// The words under a preview: a card's words' in from its sides (card_pad: the card's inset and their own), 12 under the
/// preview, 16 over the card's foot.
// kept across runs: a value (no field of it changes)
pub let peek_card_words : @ui.Style = @ui.css("w=Full pt=S3 pb=S4").then(
  @ui.style(px=@sf.room_of(@sf.card_pad - @sf.peek_card_in_px)),
)

///|
/// The preview: on its ground, its corners concentric with the card's, its mark in its middle until a picture comes.
// kept across runs: a value (no field of it changes)
pub let peek_frame : @ui.Style = @ui.css("w=Full align=ACenter justify=JCenter radius=Inner bg=Wash clip")

///|
/// A mark's box: its own, 24 (the gap to the words the card's).
// kept across runs: a value (no field of it changes)
pub let link_mark_box : @ui.Style = @ui.css("w=S6 h=S6 align=ACenter justify=JCenter")

///|
/// The words beside the mark (or under the preview): what is left across.
// kept across runs: a value (no field of it changes)
pub let link_words : @ui.Style = @ui.css("w=Full")

///|
/// Each of the two lines a line high, words or none (minLines = maxLines = 1): the title's 20, the line's 16.
// kept across runs: a value (no field of it changes)
pub let link_title_line : @ui.Style = @ui.css("w=Full h=S5")

///|
// kept across runs: a value (no field of it changes)
pub let link_line_line : @ui.Style = @ui.css("w=Full h=S4")

///|
/// The title (15/20, on one line); quieter for a screen its station no longer has.
// kept across runs: a value (no field of it changes)
pub let link_title : @ui.TextStyle = @sf.card_title.then(@sf.one_line).then(@sf.full_words)

///|
// kept across runs: a value (no field of it changes)
pub let link_title_gone : @ui.TextStyle = link_title.then(@sf.quiet)

///|
/// What its station says of it (11/16, muted, on one line).
// kept across runs: a value (no field of it changes)
pub let link_line : @ui.TextStyle = @sf.card_line.then(@sf.full_words)

// ── what the core says of them ──

///|
/// A link to a screen as a message shows it (the `screenCard` topic, client/core-ts/src/screens.ts screenCard).
pub(all) struct ScreenCard {
  kind : String
  title : String
  line : String
  gone : Bool
  peek : Bool
  width : Double
  height : Double
}

///|
/// What a link's card asks the core for what it says (screen_card_of's, adb_card_of's, service_card_of's; its chat's as
/// it opens, chat_opens): a screen's `screenCard`, a station's 共享调试's `adbCard`, a web service's `job`; None for a
/// link that is no such card.
pub fn link_card_ask(to : @sf.LinkTo) -> (String, Map[String, Json])? {
  let station = Json::string(to.station)
  match to.card {
    "screen" => Some(("screenCard", { "station": station, "screen": Json::string(to.screen) }))
    "terminal" => Some(("terminalCard", { "station": station, "terminal": Json::string(to.terminal_id()) }))
    "adb" => Some(("adbCard", { "station": station }))
    "service" => Some(("job", { "station": station, "id": Json::string(to.job) }))
    _ => None
  }
}

///|
/// The card of the terminal `href` names (`terminalCard` topic), once the core has said.
pub fn terminal_card_of(src : Source, to : @sf.LinkTo) -> (String, String, Bool)? {
  guard to.card == "terminal" && link_card_ask(to) is Some((name, params)) else { return None }
  let v = src.topic(name, params).get().value
  guard v is Some(Object(_)) else { return None }
  Some((text(v, "title"), text(v, "line"), flag(v, "gone")))
}

///|
/// The card of the screen `href` names, once the core has said.
pub fn screen_card_of(src : Source, to : @sf.LinkTo) -> ScreenCard? {
  guard to.card == "screen" && link_card_ask(to) is Some((name, params)) else { return None }
  let v = src.topic(name, params).get().value
  guard v is Some(Object(_)) else { return None }
  Some({
    kind: text(v, "kind"),
    title: text(v, "title"),
    line: text(v, "line"),
    gone: flag(v, "gone"),
    peek: flag(v, "peek"),
    width: number(v, "width"),
    height: number(v, "height"),
  })
}

///|
/// The card of the 共享调试 `href` names, once the core has said.
pub fn adb_card_of(src : Source, to : @sf.LinkTo) -> Json? {
  guard to.card == "adb" && link_card_ask(to) is Some((name, params)) else { return None }
  match src.topic(name, params).get().value {
    Some(Object(_)) as v => v
    _ => None
  }
}

///|
/// A link to a chat's web service as a card says it (the core's `job` topic, jobs.ts shown): its name (网页服务 until
/// it is known), its station's name with its port, and how it stands (运行中, 已停止…); whether it is down (stopped or
/// failed: its title quieter).
pub fn service_card_of(src : Source, to : @sf.LinkTo) -> (String, String, Bool) {
  guard to.card == "service" && link_card_ask(to) is Some((name, params)) else { return ("", "", false) }
  let station = to.station
  let j = src.topic(name, params).get().value
  let name = match text(j, "name") {
    "" => @sf.t("android-chat.preview.service")
    n => n
  }
  guard j is Some(Object(_)) else { return (name, "", false) }
  let ws = match station.find("/") {
    Some(i) => station.exact_view(end=i).to_owned()
    None => station
  }
  let at = match dv_stations(src, ws).0 {
    Some(list) => {
      let mut name = @settings.station_name(station)
      for s in list {
        if s.station == station {
          name = s.name
          break
        }
      }
      name
    }
    None => @settings.station_name(station)
  }
  let port = number(j, "port").to_int()
  let place = if port > 0 { at + " :" + port.to_string() } else { at }
  (name, place + " · " + text(j, "word"), !flag(j, "open"))
}

///|
/// What a card says as its title where no screen's card is (a station's 共享调试's, its own; a screen's the core has
/// not said yet, 屏幕, as its link bare reads): never nothing, so it is named a link whatever has come.
pub fn card_title_unsaid(src : Source, to : @sf.LinkTo) -> String {
  if to.card == "adb" {
    adb_title(src, to)
  } else {
    @sf.t("android-misc.screen.title")
  }
}

///|
/// What a card says under its title where no screen's card is: a station's 共享调试's line, as the core says it.
pub fn card_line_unsaid(src : Source, to : @sf.LinkTo) -> String {
  text(adb_card_of(src, to), "line")
}

///|
/// A bare link to a station's 共享调试: what it reads as within a sentence.
pub fn adb_title(src : Source, to : @sf.LinkTo) -> String {
  match adb_card_of(src, to) {
    Some(_) as v => text(v, "title")
    None => @sf.t("android-misc.adb.title")
  }
}

// ── a screen live in its card ──

///|
/// How a card's preview stands: not asked for, coming (its call), or ended by the station (refused, or the screen no
/// longer previewed: its picture, or its mark, stays until the card goes from view).
#derive(Eq)
pub(all) enum PeekRun {
  PeekOff
  PeekOn
  PeekEnded
}

///|
/// A card's preview.
pub(all) struct Peek {
  station : String
  screen : String
  mut run : PeekRun
  /// the view it is (`screen.view`'s `view`), and its streamed call
  mut view : String
  mut call : Int
  /// the frames come and not yet acknowledged: their `ts`, oldest first
  waiting : Array[Json]
  /// acknowledgements sent in this view
  mut acked : Int
  /// pictures come in all
  mut got : Int
  /// its pictures by their keys, oldest first: the one shown (the newest decoded) and any newer one decoding
  pictures : Array[String]
  /// its card's target (0: none): where it shows, the card is on the screen (peeks_settle); and, in the frame it changed
  /// in, the one it had before, the one the last frame showed (its row built at another place in its list, as older
  /// messages come in before it: a row's ids are by its place, while the card, its preview and its pictures are by its
  /// key)
  mut target : Int
  mut was : Int
  /// what its view's frames are (its config's `codec`): "jpeg" before one says otherwise
  mut codec : String
  /// its video's decoder (an H.264 preview), made as its config comes; each frame acknowledged as it is shown
  mut stream : @ui.Stream?
  /// it holds one of the app's video previews (video_peeks_most)
  mut video : Bool
  /// ended long enough: asked for again where its card shows (peeks_frame, peeks_settle)
  mut again : Bool
  /// held by a card made as nodes of the window's tree (screen_links_node.mbt's screen_peek_node), which starts and
  /// stops it itself: not the old view's frames' to settle (peeks_frame, peeks_settle pass it by)
  mut made : Bool
  /// how many times what a node draws of it changed (its pictures, its run, its frames waiting), told as it does: what
  /// its node binds reads it first, then the fields as they are
  mut changes : Int
  told : @signals.Signal[Int]
}

///|
/// What its node draws of it changed (Peek's `told`).
fn Peek::tell(self : Peek) -> Unit {
  self.changes += 1
  self.told.set(self.changes)
}

///|
/// The cards' previews, by card.
pub let peeks : Map[String, Peek] = Map([])

///|
/// The cards with a preview built in this pass of the frame, or held by a list's row kept as its nodes (@ui.built_used).
pub let peeks_built : Map[String, Bool] = Map([])

///|
/// Previews asked for so far: each view's name its own.
pub let peek_views : Ref[Int] = Ref(0)

///|
/// The previews decoded as a video now (video_peeks_most at most).
pub let video_peeks : Ref[Int] = Ref(0)

///|
pub fn peeks_reset() -> Unit {
  peeks.clear()
  peeks_built.clear()
  peek_views.val = 0
  video_peeks.val = 0
}

///|
pub fn peek_for(key : String, station : String, screen : String) -> Peek {
  match peeks.get(key) {
    Some(p) => p
    None => {
      let p : Peek = {
        station,
        screen,
        run: PeekOff,
        view: "",
        call: 0,
        waiting: [],
        acked: 0,
        got: 0,
        pictures: [],
        target: 0,
        was: 0,
        codec: "jpeg",
        stream: None,
        video: false,
        again: false,
        made: false,
        changes: 0,
        told: @signals.signal(0),
      }
      peeks[key] = p
      p
    }
  }
}

///|
/// A value of a preview as it comes. A config: what its frames are; H.264's (an Android device's) to the card's Stream,
/// if the app decodes fewer than video_peeks_most videos now, else the preview let go (asked again later). A frame:
/// a JPEG handed over under a key of its own, its `ts` to acknowledge peek_ms after the one before; an H.264 one to
/// the Stream, acknowledged as soon as it is shown or let go (the station paces an Android preview itself).
pub fn peek_took(src : Source, p : Peek, view : String, value : Json, bytes : Bytes?) -> Unit {
  if p.view != view {
    return
  }
  peek_took_now(src, p, view, value, bytes)
  p.tell()
}

///|
/// peek_took's, of its own view's value.
fn peek_took_now(src : Source, p : Peek, view : String, value : Json, bytes : Bytes?) -> Unit {
  match field(Some(value), "config") {
    Some(Object(_) as cfg) => {
      let codec = text(Some(cfg), "codec")
      p.codec = codec
      if codec == "h264" {
        if !p.video {
          if video_peeks.val >= video_peeks_most {
            peek_end(src, p)
            return
          }
          p.video = true
          video_peeks.val += 1
        }
        let st = match p.stream {
          Some(st) => st
          None => {
            let st = @ui.Stream::new(
              // acknowledged as it is shown or let go, not at a later frame's build (nothing may build one: the
              // station would wait on it); its pace is the station's own (an Android preview's 2 frames a second)
              shown=fn(ts) {
                if p.view == view {
                  (src.call)("screen.ack", { "view": Json::string(view), "ts": Json::number(ts) }, answer_unread)
                }
              },
              broken=fn() {
                if p.view == view {
                  (src.call)("screen.keyframe", { "view": Json::string(view) }, answer_unread)
                }
              },
            )
            p.stream = Some(st)
            st
          }
        }
        match bytes {
          Some(b) => st.h264(b, number(Some(cfg), "width").to_int(), number(Some(cfg), "height").to_int())
          None => ()
        }
      }
      return
    }
    _ => ()
  }
  let f = field(Some(value), "frame")
  let ts = match field(f, "ts") {
    Some(Number(n, ..)) => Json::number(n)
    Some(String(s)) =>
      match (try Some(@json.parse(s)) catch { _ => None }) {
        Some(Number(n, ..)) => Json::number(n.floor())
        _ => return
      }
    _ => return
  }
  if p.codec == "h264" {
    match (p.stream, bytes, ts) {
      (Some(st), Some(b), Number(n, ..)) if b.length() > 0 => st.frame(b, flag(f, "key"), n)
      _ => p.waiting.push(ts)
    }
    return
  }
  match bytes {
    Some(b) if b.length() > 0 => {
      let k = "mem:sf/peek/\{view}/\{p.got}"
      p.got += 1
      @ui.add_image(k, b)
      p.pictures.push(k)
    }
    _ => ()
  }
  p.waiting.push(ts)
}

///|
/// The preview of `p` asked for (`screen.view` with `peek`, small: JPEG, and H.264 where the host decodes it).
pub fn peek_start(src : Source, p : Peek) -> Unit {
  peek_views.val += 1
  let view = "mbui-peek-\{peek_views.val}"
  p.view = view
  p.run = PeekOn
  p.call = 0
  p.acked = 0
  p.again = false
  p.codec = "jpeg"
  p.waiting.clear()
  let codecs : Array[Json] = if @ui.h264_here() { ["jpeg", "h264"] } else { ["jpeg"] }
  let params : Map[String, Json] = {
    "station": Json::string(p.station),
    "screen": Json::string(p.screen),
    "view": Json::string(view),
    "codecs": Json::array(codecs),
    "maxWidth": Json::number(peek_size),
    "maxHeight": Json::number(peek_size),
    "peek": true,
  }
  let id = (src.stream)("screen.view", Json::object(params), None, fn(v, b) { peek_took(src, p, view, v, b) }, fn(_) {
    // refused or ended (the station previews as many as it can now, or no longer this one): what it shows stays
    if p.view == view {
      p.call = 0
      peek_end(src, p)
    }
  })
  if p.view == view && p.run == PeekOn {
    p.call = id
  }
  p.tell()
}

///|
/// Its video's decoder stopped and its place among the app's video previews given back (its last picture goes with it:
/// a JPEG one, kept, shows until the next).
fn peek_drop_video(p : Peek) -> Unit {
  match p.stream {
    Some(st) => st.close()
    None => ()
  }
  p.stream = None
  if p.video {
    p.video = false
    video_peeks.val = if video_peeks.val > 0 { video_peeks.val - 1 } else { 0 }
  }
}

///|
/// The preview of `p` ended (refused, ended by the station, or let go for want of a decoder): its call cancelled if it
/// still runs; asked for again peek_again_ms on while its card shows (`view` kept, its wait's key).
fn peek_end(src : Source, p : Peek) -> Unit {
  if p.call != 0 {
    (src.cancel)(p.call)
  }
  p.call = 0
  p.run = PeekEnded
  p.waiting.clear()
  peek_drop_video(p)
  p.tell()
}

///|
/// The preview of `p` no longer asked for: its call cancelled.
pub fn peek_stop(src : Source, p : Peek) -> Unit {
  if p.call != 0 {
    (src.cancel)(p.call)
  }
  p.call = 0
  p.view = ""
  p.run = PeekOff
  p.again = false
  p.waiting.clear()
  peek_drop_video(p)
  p.tell()
}

///|
/// Every preview stopped (the app gone behind: no frame may come after it).
pub fn peeks_stop_all(src : Source) -> Unit {
  for _, p in peeks {
    if p.run == PeekOn {
      peek_stop(src, p)
    }
  }
}

///|
/// Legacy frame hook kept for the top-level shell until Wave 8C; all screen previews are node-owned (`p.made = true`).
pub fn peeks_frame(c : @ui.Ctx, src : Source) -> Unit {
  ignore(c)
  ignore(src)
  peeks_built.clear()
}
