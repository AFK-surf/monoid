// A file opened beside a chat: a tab of the wide frame's side panel (`view:[…]`, the core's chat-tabs.ts isView), the
// same viewer as over the whole window (viewer.mbt) made for the tab (Viewer's `beside`), one a tab, kept by the chat's
// tabs' key and the tab while the tab is open, let go as it is closed. What it shows is the whole window's: a picture
// fitted, zoomed by the wheel, two fingers or a double press, panned by a finger (the zoom's: @motion.Zoom); a PDF, a page,
// a table, code, words read in the reader, as the whole window's stage shows them (viewer_stage_node, by the tab's width);
// a film or a song in the one player embedded in the stage as part of the pane (@sf.player_view's `embedded`: on the
// pane's own ground, its picture or a song's cover fitted in the room over its controls as a tab's picture is, the
// controls always there under it in the pane's colours, laid out by the stage's width; its own player and view, not
// the whole window's, which stays the cinema);
// told of, coming, failed, as the whole window's stage says them (viewer_tree.mbt). Over it a row of tools as tall as a
// service's bar: the file's name and what it is, 预览 / 源码 where the whole window's bar has them, the reader's 目录, 搜索
// and 排版, 下载, 全屏 (the tab over the whole window: tab_full.mbt; none there once it is). A picture is marked here as
// over the whole window (标注图片 in its tools' row: marking's tools under the picture, its actions in that row in place
// of its keys, the marks drawn over the picture; its marked copy put in the chat's draft, the tab staying), and steps
// to the pictures beside it in its chat or its folder (the ways at its sides while the pointer is over it, ← and →
// there or over the whole window): the tab put in the place of its own (Shell's `beside_for`), the same tab no more.
// Nothing else of the whole window's viewer is the tab's: no flight from a thumbnail, no swipe, no keys of the
// window's.
//
// How a file comes here: open_preview puts any beside by default, or as asked (a menu's 在侧边打开; the
// whole window's 移到侧边; over the whole window as its tab, the command key held), said to the shell (Shell's
// `beside`), which puts it where the layout has a side panel for the page in view, and says whether it did. A film or a song asked so plays at once (the whole window's from
// where it was); a tab only shown again (the app begun, the chat opened, the tab or the panel back) plays from its play
// key. It is paused as its tab is no longer shown (another tab in front, the panel closed, the page gone, no panel on
// 小屏) and as the whole window's viewer opens over it, and never plays again by itself.

///|
/// Whether a file at `path` named `name` opens beside the page when that is asked: anything the viewer shows, a film and
/// a song too, but one whose bytes are only in this run's memory (a `draft:` path: the composer's pending attachments, a
/// Mermaid picture, read by keep_read), which opens over the whole window whatever was asked: a tab is kept per chat on
/// the device and made again from its key alone (view_tab_file), where a draft's bytes are gone after a restart.
pub fn opens_beside(path : String, name : String) -> Bool {
  ignore(name)
  !path.has_prefix("draft:")
}

///|
/// Whether file `a`, asked over the whole window (open_preview's `full`: pressed, the command key not held), opens in the
/// whole window's viewer of its own, not as its tab over the whole window: a picture, a film or a song, which fly from
/// their thumbnail there and back into it as they close.
pub fn opens_in_viewer(a : Attachment) -> Bool {
  preview_kind(a.name).0 is Some(KImage | KVideo | KAudio)
}

///|
/// Whether a file at `path` named `name` is offered to be opened beside the page (a menu's 在侧边打开, the whole
/// window's 移到侧边): where the shell has a side panel for the page in view (Shell's `beside_room`, followed as it
/// changes: beside_room_now), and it opens there.
pub fn beside_offered(path : String, name : String) -> Bool {
  opens_beside(path, name) && beside_room_now.get()
}

///|
/// The tab of file `a` on `station` (kept by session `key`; a drive's `drive`; one a message names by its path,
/// `named`): which of the three it is, its station, the session (a drive's root), its path, its name and its size as it
/// was opened (a drive's its time too), all a viewer of it is made again by (view_tab_file). The same file, the same
/// tab.
pub fn view_tab_key(station : String, key : String, a : Attachment, drive : DriveFile?, named : Bool) -> String {
  let parts = match drive {
    Some(d) =>
      [
        Json::string("drive"),
        Json::string(d.station),
        Json::string(d.root),
        Json::string(d.path),
        Json::string(d.name),
        Json::number(d.size),
        Json::number(d.mtime),
      ]
    None =>
      [
        Json::string(if named { "named" } else { "chat" }),
        Json::string(station),
        Json::string(key),
        Json::string(a.path),
        Json::string(a.name),
        Json::number(a.size),
      ]
  }
  "view:" + Json::array(parts).stringify()
}

///|
/// Viewer `vw`'s file's tab (view_tab_key).
pub fn Viewer::view_tab(self : Viewer) -> String {
  view_tab_key(self.station, self.key, self.file, self.drive, self.named)
}

///|
/// A file's tab read (view_tab_key's): where it is and what it is.
pub(all) struct ViewTab {
  station : String
  key : String
  file : Attachment
  drive : DriveFile?
  named : Bool
}

///|
/// The file tab `tab` is (None: no file's tab, or one that does not read).
pub fn view_tab_file(tab : String) -> ViewTab? {
  if tab.has_prefix("file:") {
    match (try Some(@json.parse(tab.exact_view(start="file:".length()).to_owned())) catch { _ => None }) {
      Some(Array([String(session), String(path), String(name)])) if (is_mbui_viz(name) || is_mbui_viz(path)) && path != "" => {
        let file : Attachment = {
          name: if name != "" { name } else { base_name(path) },
          path,
          size: 0.0,
          width: 0.0,
          height: 0.0,
          thumbhash: "",
          owner: "",
          upload: "",
          duration: 0.0,
          frames: 0,
          held: false,
        }
        return Some({ station: "", key: session, file, drive: None, named: false })
      }
      _ => return None
    }
  }
  guard tab.has_prefix("view:") else { return None }
  let v = @json.parse(tab.exact_view(start="view:".length()).to_owned()) catch { _ => return None }
  guard v is Array(xs) && xs.length() >= 6 else { return None }
  guard xs[0] is String(of) &&
    xs[1] is String(station) &&
    xs[2] is String(at) &&
    xs[3] is String(path) &&
    xs[4] is String(name) &&
    xs[5] is Number(size, ..) &&
    station != "" &&
    path != "" else {
    return None
  }
  let file : Attachment = {
    name,
    path,
    size,
    width: 0.0,
    height: 0.0,
    thumbhash: "",
    owner: "",
    upload: "",
    duration: 0.0,
    frames: 0,
    held: false,
  }
  match of {
    "chat" | "named" if xs.length() == 6 => Some({ station, key: at, file, drive: None, named: of == "named" })
    "drive" if xs.length() == 7 =>
      match xs[6] {
        Number(mtime, ..) => {
          let d : DriveFile = { station, root: at, path, name, size, mtime, kind: "", mime: preview_kind(name).1 }
          Some({ station, key: "", file: drive_attachment(d), drive: Some(d), named: false })
        }
        _ => None
      }
    _ => None
  }
}

///|
/// Whether two files' tabs are of the same file, whatever its size said (a drive's changed since it was opened): which
/// of the three, its station, its session (a drive's root), its path.
pub fn ViewTab::same_file(self : ViewTab, other : ViewTab) -> Bool {
  (self.station == other.station || self.station == "" || other.station == "") &&
  self.key == other.key &&
  self.file.path == other.file.path &&
  self.named == other.named &&
  self.drive.map(fn(d) { d.root }) == other.drive.map(fn(d) { d.root })
}

///|
/// A tab's viewer, how many nodes draw it, whether its tab was closed while one did (let go as the last goes), and
/// whether what it plays goes on as its tab moves between the panel and the whole window (tab_viewer_moves).
priv struct TabViewer {
  viewer : Viewer
  mut drawn : Int
  mut closing : Bool
  mut goes_on : Bool
  /// the pictures beside its own, read ahead (Viewer::near's, the tab's own)
  near : Map[String, Viewer]
}

///|
/// The tabs closed (or stepped from) while a node drew them, by tab_viewer_id, till opened again (tab_viewer_kept): no
/// viewer made for one anew as what drew it goes (the panel showing it a moment longer, till the core says it closed:
/// a picture stepped over the whole window).
// kept across runs: put back by tab_viewers_reset
let tab_gone : Map[String, Bool] = Map([])

///|
/// The viewers of the files open beside chats, by the chat's tabs' key and the tab (tab_viewer_id).
// kept across runs: put back by tab_viewers_reset (file_viewer_reset)
let tab_viewers : Map[String, TabViewer] = Map([])

///|
fn tab_viewer_id(chat : String, tab : String) -> String {
  chat + "\n" + tab
}

///|
/// What a film opened beside a chat was known to be as it was opened there (its picture's size, its length and frames:
/// the message's Attachment), by its tab (view_tab_key, which says none of it: the shell matches tabs by it as
/// it is), till its tab's viewer is made (tab_viewer), so the tab's player and its size are its file's from the first
/// frame, not 0 till the station reads its header again.
// kept across runs: put back by tab_viewers_reset (file_viewer_reset)
let tab_facts : Map[String, (Double, Double, Double, Int)] = Map([])

///|
/// File `a` opened beside a chat as tab `tab`: what is known of it kept for its viewer (tab_facts).
fn tab_facts_said(tab : String, a : Attachment) -> Unit {
  // (a film's or a song's: a picture's size is said with what it steps through, tab_steps_said)
  if a.duration > 0.0 || a.frames > 0 {
    tab_facts[tab] = (a.width, a.height, a.duration, a.frames)
  }
}

///|
/// The viewer of tab `tab` of the chat whose tabs are kept by `chat`: made as it is first shown (of the tab alone: its
/// file read again after a restart), kept while the tab is open. None: no file's tab, or one of a draft's.
pub fn tab_viewer(chat : String, tab : String) -> Viewer? {
  let id = tab_viewer_id(chat, tab)
  match tab_viewers.get(id) {
    Some(t) => Some(t.viewer)
    None if tab_gone.contains(id) => None
    None =>
      match view_tab_file(tab) {
        Some(f) if opens_beside(f.file.path, f.file.name) => {
          let (chat_station, chat_session) = match chat.find(":") {
            Some(i) => (chat.exact_view(end=i).to_owned(), chat.exact_view(start=i + 1).to_owned())
            None => ("", chat)
          }
          let station = if f.station != "" { f.station } else { chat_station }
          // (moved here from the whole window (移到侧边): what it stepped through and how big its picture is, as it
          // showed them, so the tab comes in saying what the window said; else stepping through its chat's pictures)
          let (steps, file, at) = match tab_moved.get(tab) {
            Some(m) => {
              tab_moved.remove(tab)
              // (what the window read held till the tab, made in this frame, has read it: let go at its end)
              match m.near {
                Some(l) => @ui.after_frame(fn() { l.release() })
                None => ()
              }
              (m.steps, { ..f.file, width: m.width, height: m.height }, m.at)
            }
            None => (if chat_session != "" { InChat(None, chat_session) } else { NoSteps }, f.file, "")
          }
          // (a film's or a song's as it was known as it was opened beside: tab_facts)
          let file = match tab_facts.get(tab) {
            Some((width, height, duration, frames)) => { ..file, width, height, duration, frames }
            None => file
          }
          let v = new_viewer(station, f.key, file, f.drive, steps, named=f.named, at~, beside=true)
          tab_viewers[id] = { viewer: v, drawn: 0, closing: false, goes_on: false, near: Map([]) }
          Some(v)
        }
        _ => None
      }
  }
}

///|
/// Tab `tab` of chat `chat` about to move between its panel and the whole window (tab_full.mbt): what it plays goes on
/// there as it was, playing or paused, not paused as the node that drew it goes.
fn tab_viewer_moves(chat : String, tab : String) -> Unit {
  match tab_viewers.get(tab_viewer_id(chat, tab)) {
    Some(t) => t.goes_on = true
    None => ()
  }
}

///|
/// Whether tab `tab` of chat `chat` holds a viewer still (what it read, its page, its PDF).
pub fn tab_viewer_held(chat : String, tab : String) -> Bool {
  tab_viewers.contains(tab_viewer_id(chat, tab))
}

///|
/// Tab `tab` of chat `chat` closed (sfdesk's tab_let_go): its viewer let go (what it read, its page, its PDF, its
/// reader's place kept): at once where nothing draws it, else as the last that does goes (the panel showing what it
/// had as it slides out).
pub fn tab_viewer_let_go(chat : String, tab : String) -> Unit {
  let id = tab_viewer_id(chat, tab)
  tab_gone[id] = true
  match tab_viewers.get(id) {
    Some(t) if t.drawn <= 0 => {
      t.viewer.let_go()
      tab_viewers.remove(id)
    }
    Some(t) => t.closing = true
    None => ()
  }
}

///|
/// Tab `tab` of chat `chat` opened again before what drew it went: its viewer kept.
pub fn tab_viewer_kept(chat : String, tab : String) -> Unit {
  tab_gone.remove(tab_viewer_id(chat, tab))
  match tab_viewers.get(tab_viewer_id(chat, tab)) {
    Some(t) => t.closing = false
    None => ()
  }
}

///|
/// Every tab's viewer let go (the app begun again).
fn tab_viewers_reset() -> Unit {
  tab_viewers.each(fn(_, t) { t.viewer.let_go() })
  tab_viewers.clear()
  tab_gone.clear()
  tab_asked.clear()
  tab_moved.each(fn(_, m) { m.release() })
  tab_moved.clear()
  tab_facts.clear()
}

///|
/// What a file moved beside held for its tab let go (its tab never made).
fn TabMoved::release(self : TabMoved) -> Unit {
  match self.near {
    Some(l) => l.release()
    None => ()
  }
}

///|
/// What a file moved beside from the whole window (移到侧边) was shown with there: what its picture stepped through and
/// how big it is (0: not known), for its tab's viewer as it is made (tab_viewer).
priv struct TabMoved {
  steps : Stepping
  width : Double
  height : Double
  /// where its picture is among its chat's, as the window read it (imageNear), held for the tab till it reads it
  near : TopicLease?
  /// which of its message's pictures it is (Viewer's `at`), "" none said
  at : String
}

///|
/// File tab `tab` about to be put beside the page, what it steps through (`steps`), its picture's size (0: not known),
/// where it is among its chat's as read (`near`) and which of its message's it is (`at`) kept for its viewer as it is
/// made (tab_moved): none where its viewer is made already (it is kept as it is), nothing to keep where it steps through
/// nothing and nothing is known of it. Whether it was kept (tab_moved_dropped, its tab not put there).
fn tab_steps_said(tab : String, steps : Stepping, width : Double, height : Double, near : TopicLease?, at : String) -> Bool {
  if tab_viewers.keys().any(fn(id) { id.has_suffix("\n" + tab) }) || (steps is NoSteps && width <= 0.0 && at == "" && near is None) {
    match near {
      Some(l) => l.release()
      None => ()
    }
    return false
  }
  match tab_moved.get(tab) {
    Some(was) => was.release()
    None => ()
  }
  tab_moved[tab] = { steps, width, height, near, at }
  true
}

///|
/// What was kept for tab `tab`'s viewer (tab_steps_said) let go: its tab not put beside the page.
fn tab_moved_dropped(tab : String) -> Unit {
  match tab_moved.get(tab) {
    Some(m) => m.release()
    None => ()
  }
  tab_moved.remove(tab)
}

///|
/// The files moved beside from the whole window just now, by their tab, till the tab's viewer is made (tab_viewer):
/// a press opens the tab saying what the window said of the file, never the tab's own asks answered a moment later
/// (main's switches sweep, 2026-11-16: 「1 / 2 · … · 400×300」 came 800 ms after the press).
// kept across runs: put back by tab_viewers_reset (file_viewer_reset)
let tab_moved : Map[String, TabMoved] = Map([])

///|
/// The files the person asked beside the page just now (a press with the command key held, a menu's 在侧边打开, the
/// whole window's 移到侧边), by their tab: where a film's or a song's player starts there (ms; 0 where it was left),
/// taken by its tab's viewer as the tab's node is made (viewer_tab_node), its player played at once.
// kept across runs: put back by tab_viewers_reset (file_viewer_reset)
let tab_asked : Map[String, PlayAsked] = Map([])

///|
/// What a film or a song asked beside the page plays as (tab_asked): from where (ms; 0 where it was left), played at
/// once or left paused there (moved from the whole window's player paused: kept paused), and, moved so, the speed it
/// played at and how loud (its sound off or not) there, carried on; None, as the tab's player has them.
priv struct PlayAsked {
  at : Double
  plays : Bool
  how : (Double, Double, Bool)?
}

///|
/// File tab `tab` asked beside the page in view by the person (Shell's `beside`), a film or a song in it to play at once
/// from `at` (ms; 0 where it was left): whether the shell put it there. The tab the shell put in front may be another
/// of the same file (opened by another key: sfdesk's view_beside), the one asked of then. Its tab drawn in front
/// already (the same file asked again), no node is made for it: its viewer told here.
fn beside_open(
  tab : String,
  at : Double,
  plays? : Bool = true,
  how? : (Double, Double, Bool)? = None,
  full? : Bool = false,
) -> Bool {
  let at : PlayAsked = { at, plays, how }
  // (said before the shell is asked: its tab's node may be made as the shell puts it there)
  tab_asked[tab] = at
  let (put, new) = match (shell.val.beside)(tab, full) {
    Some(put) => put
    None => {
      tab_asked.remove(tab)
      return false
    }
  }
  if put != tab {
    tab_asked.remove(tab)
    tab_asked[put] = at
  }
  tab_viewers.each(fn(id, t) {
    if t.drawn > 0 && id.has_suffix("\n" + put) && tab_asked.contains(put) {
      tab_asked.remove(put)
      t.viewer.play_asked(at)
    }
  })
  // (over the whole window as its tab, asked so: the chat in view's, where the shell put it; put there new, only to go
  // there: lone, tab_full.mbt)
  if full {
    match app.nav.top() {
      Chat(r) => tab_full_open(r, put, lone=new)
      _ => ()
    }
  }
  true
}

///|
/// A tab's viewer asked beside by the person just now (tab_asked): its film or song played at once (or left paused, as
/// `asked` says), at the speed and as loud as it says where it says, from its `at` (ms; 0
/// where it is): its player sent there and played where it is open already, else opened so (Viewer::fetch).
fn Viewer::play_asked(self : Viewer, asked : PlayAsked) -> Unit {
  let at = asked.at
  self.plays_now = asked.plays
  match self.media {
    Some(m) => {
      if at > 0.0 {
        m.seek(at)
      }
      match asked.how {
        Some(how) => media_as(m, how)
        None => ()
      }
      match m.native() {
        Some(n) => if asked.plays { n.play() } else { n.pause() }
        None => ()
      }
    }
    None => {
      if at > 0.0 {
        self.start_at = at
      }
      self.play_how = asked.how
    }
  }
}

///|
/// Player `m` at the speed and as loud as `how` says (its speed, how loud, its sound off or not).
fn media_as(m : @player.Media, how : (Double, Double, Bool)) -> Unit {
  let (speed, volume, muted) = how
  m.set_speed(speed)
  m.set_volume(volume)
  if muted != m.volume().1 {
    m.toggle_mute()
  }
}

///|
/// Its film or song paused, where one plays (its tab no longer shown, the whole window's viewer opened over it).
fn Viewer::pause_player(self : Viewer) -> Unit {
  match self.media {
    Some(m) => m.pause()
    None => ()
  }
}

///|
/// What every tab beside a chat plays, paused (the whole window's viewer opened over them: open_preview); `chat`: only
/// those of the chat whose tabs are kept by it (its page shown no more while it is kept under another: sfdesk's
/// side_panel_node).
pub fn tab_players_pause(chat? : String = "") -> Unit {
  tab_viewers.each(fn(id, t) {
    if chat == "" || id.has_prefix(chat + "\n") {
      t.viewer.pause_player()
    }
  })
}

///|
/// 移到侧边 (the whole window's bar): viewer `vw`'s file beside the page, it closed at once (no flight back: it goes to
/// the tab); a film or a song played there from where it was. Where the shell has nowhere to put it, it stays.
pub fn Viewer::move_beside(self : Viewer, src : Source) -> Unit {
  // (where it is, played on there only where it plays here: paused here, there paused; at the speed and as loud as
  // here)
  let (at, plays, how) = match self.media {
    Some(m) => {
      let s = m.status()
      let (volume, muted) = m.volume()
      (m.position(), s.playing && !s.ended, Some((m.speed(), volume, muted)))
    }
    None => (0.0, true, None)
  }
  // (what the window showed of it, handed to the tab's viewer: what it stepped through, its picture's size)
  let (width, height) = if self.file.width > 0.0 && self.file.height > 0.0 {
    (self.file.width, self.file.height)
  } else if self.image != "" {
    @ui.image_natural(self.image).unwrap_or((0.0, 0.0))
  } else {
    (0.0, 0.0)
  }
  let tab = self.view_tab()
  // (none where its tab is open already: its viewer is kept as it is)
  let near = if self.shown_kind() == Some(KImage) && !tab_viewers.keys().any(fn(id) { id.has_suffix("\n" + tab) }) {
    image_near_params(self).map(fn(p) { src.lease_topic("imageNear", p) })
  } else {
    None
  }
  let said = tab_steps_said(tab, self.steps, width, height, near, self.at)
  tab_facts_said(tab, self.file)
  if beside_open(tab, at, plays~, how~) {
    close_now()
  } else if said {
    tab_moved_dropped(tab)
  }
}

///|
/// The file of tab `tab` beside the chat whose tabs are kept by `chat`, in node `q` (the panel under its bar): its tools
/// (tab_tools_node), then its stage, the rest: a picture its nodes (tab_picture_node), anything else as the whole
/// window's stage shows it (viewer_stage_node), told of, coming or failed its nodes
/// (viewer_note_node); a film or a song its player embedded (tab_player_node). What it reads
/// asked of the core as what it needs comes; 下载 told the core as it is asked. Made as the person asked the file beside
/// just now (tab_asked), its film or song plays at once; let go (the tab no longer shown), it is paused. `width()`, how
/// wide the tab is; `full`, what puts it over the whole window (its 全屏); `tools`, whether its tools' row is drawn over
/// it (not over the whole window, where the bar has them: viewer_tab_bar_tools).
pub fn viewer_tab_node(
  q : @view.View,
  src : Source,
  chat : String,
  tab : String,
  width : () -> Double,
  full : (() -> Unit)?,
  tools? : Bool = true,
) -> Unit {
  guard tab_viewer(chat, tab) is Some(vw) else { return }
  let id = tab_viewer_id(chat, tab)
  match tab_viewers.get(id) {
    Some(t) => {
      t.drawn += 1
      t.goes_on = false
    }
    None => ()
  }
  // (asked beside just now: its film or song played at once, before its player is made below)
  match tab_asked.get(tab) {
    Some(at) => {
      tab_asked.remove(tab)
      vw.play_asked(at)
    }
    None => ()
  }
  q.owns(fn() {
    // (its tab no longer shown: what it plays paused, played again only from its play key; not where it is shown
    // elsewhere now, or is to be as it moves between the panel and the whole window)
    match tab_viewers.get(id) {
      Some(t) => {
        t.drawn -= 1
        if t.drawn <= 0 && !t.goes_on {
          vw.pause_player()
          // (marking it left: its tools and its marks gone with it)
          if marks_tab.val is Some(m) && physical_equal(m, vw) {
            marks_leave()
          }
        }
        if t.drawn <= 0 && t.closing {
          t.viewer.let_go()
          tab_viewers.remove(id)
        }
      }
      None => vw.pause_player()
    }
  })
  |> ignore
  // what it reads asked of the core as what it needs comes (its kind sniffed, its bytes, a read failed, 下载 asked)
  // (its film's or song's player made as it is asked for: what plays it there from then)
  let media_made = @signals.signal(false)
  q.reacts(
    fn() {
      (
        vw.sniffed.get(),
        vw.bytes.get() is Some(_),
        vw.error.get() is Some(_),
        vw.fetching.get(),
        vw.asked_told.get(),
        vw.whole_due(),
      )
    },
    fn(_) {
      vw.fetch(src)
      media_made.set(vw.media is Some(_))
    },
  )
  // release the preview image once the whole image is decoded so host memory stays bounded
  q.reacts(
    fn() {
      vw.bytes.get() |> ignore
      vw.preview_image != "" &&
      vw.image != "" &&
      vw.image != vw.preview_image &&
      @ui.image_any_ready(vw.image)
    },
    fn(ready) {
      if ready {
        vw.drop_preview_image()
      }
    },
  )
  // what marking made of its picture, taken as the host says it is drawn (MarkedImage::ready): kept, or into the chat's
  // draft, once (Viewer::marks_frame), while it is this tab's marking
  q.reacts(
    fn() {
      marks_said()
      match marking.job {
        Some(j) => Some((j.id(), j.ready()))
        None => None
      }
    },
    fn(job) {
      if job is Some((_, true)) && vw.marks_here() {
        vw.marks_came(fn(name, mime, png) { keep_bytes_now(name, mime, png) }, fn() {  })
      }
    },
  )
  // (what marking stamps what it makes by: this source's clock)
  src_now.val = src.now
  // 下载 asked: a chat's file's download said to the core at that change; what was asked before it was here saved, or
  // installed, as its whole comes; each once
  q.reacts(fn() { (vw.asked_told.get(), vw.bytes.get() is Some(_), vw.previewed.get()) }, fn(_) {
    download_told(src, vw)
    if vw.whole_here() is Some(_) {
      if vw.save_after {
        vw.save_after = false
        vw.save_now()
      }
      if vw.install_after {
        vw.install_after = false
        vw.ask_install()
      }
      vw.share_came()
      vw.copy_came()
      vw.marks_finish_came()
    }
  })
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = @sf.TipLayer::new(fn() { tips_at.val })
  if tools && !is_mbui_viz(vw.file.name) {
    q.box(fn(row) { tab_tools_node(row, src, vw, full, tips) }) |> ignore
  }
  q.box(fn(s) {
    s
    .grow(Is(1.0))
    .shrink(Is(1.0))
    .basis(Is(Some(0.0)))
    .min_height(Is(Some(0.0)))
    .clips(Is(true))
    |> ignore
    // a film or a song: the one player embedded (no keys, nothing of the window's)
    let played = vw.played()
    if played {
      s.show(fn() { media_made.get() }, fn(h) {
        h.over(Is(true)) |> ignore
        tab_player_node(h, src, vw)
      })
    }
    let picture = fn() { vw.markable() }
    s.show(picture, fn(p) { tab_picture_node(p, src, vw, chat, tab) })
    let stage = fn() { vw.outer_stage() }
    let mbui = fn() { !played && !picture() && stage() == Hosted && viewer_mbui_rendered(vw) }
    s.show(mbui, fn(m) { viewer_mbui_node(m, src, vw) })
    // (what its stage's nodes show of it, its words picked as a page's are: viewer_stage_node)
    s.show(fn() { !played && !picture() && stage() == Hosted && !viewer_mbui_rendered(vw) }, fn(h) {
      viewer_stage_node(h, src, vw, width, panel=tools)
    })
    s.show(fn() { !played && !picture() && stage() != Hosted }, fn(note) {
      viewer_note_node(note, src, vw, stage, bars=false)
    })
    // the reader's 排版 while its reading has it open: docked at the stage's right from its top, no wider than it (the
    // tab's own, going with it as another tab comes to the front and there again as it comes back)
    s.show(fn() { @sf.reader_panel_of(vw.read_key()) == @sf.ReaderPanel::Layout }, fn(l) {
      l.over(Is(true)) |> ignore
      @sf.reader_layout_docked(l, fn() { @sf.reader_panel_toggle(vw.read_key(), @sf.ReaderPanel::Layout) }, fits=true)
    })
  })
  |> ignore
  // (its tips over all of it)
  tips_at.val = Some(q.box(fn(l) { l.over(Is(true)) |> ignore }))
}

///|
/// The tools over a file's tab in `row` (as tall as a service's bar, PreviewBar's): its name and the line about it (its
/// size, its kind), cut short where the tab is narrow; then 预览 / 源码 (a table's, a page's, once read: as the whole
/// window's bar has them), the reader's 目录, 搜索, 排版 (Markdown and words read in it: its panels opened from here,
/// the layout's in the tab's stage, viewer_tab_node's; scroll-to-bottom floats at the stage's bottom-right), 标注图片
/// and 复制 (pictures), 下载 (a ring while the core downloads it), 全屏 (`full`, where it is given). Each done at its
/// press's moment; their tips in `tips`. The keys stand by the name's line, not the middle of the name and the line
/// under it (the user, 2026-11-14: 「不应该一个图标或者一行内容跟多行做垂直居中对齐」).
fn tab_tools_node(row : @view.View, src : Source, vw : Viewer, full : (() -> Unit)?, tips : @sf.TipLayer) -> Unit {
  row
  .row(Is(true))
  .lines_up(Is(Some(Start)))
  .gap(Is(@ui.Space::px(S2)))
  .min_height(Is(Some(@ui.room_least())))
  .padding(Is((@ui.Space::px(S3), @ui.Space::px(S1_5), @ui.Space::px(S2), @ui.Space::px(S1_5))))
  .shrink(Is(0.0))
  .says(Is(Some(@view.said(Toolbar, label=vw.file.name))))
  |> ignore
  let ink = fn() { @sf.page_viewer_ink() }
  let corner : @view.Live[Double] = Is(@sf.tool_side / 2.0)
  // its name and the line about it, giving way to the tools
  row.box(fn(f) {
    f
    .grow(Is(1.0))
    .shrink(Is(1.0))
    .min_width(Is(Some(0.0)))
    .clips(Is(true))
    // (its name's line across the keys' middle: as far down as half of what they stand taller than it)
    .padding(By(fn() {
      f.words_redone() |> ignore
      let th = @ui.tree_theme()
      let line = @sf.node_sp(f, th.leading(L5).unwrap_or(th.text_size(Ui).1))
      (0.0, @sf.dmax(0.0, (@sf.tool_side - line) / 2.0), 0.0, 0.0)
    }))
    |> ignore
    f.box(fn(n) {
      n
      .words(By(fn() { vw.file.name }))
      .words_look(By(fn() { tab_words(Ui, L5, 600) }))
      .ink(By(fn() { ink().ink }))
      .says(By(fn() { Some(@view.said(Text, label=vw.file.name)) }))
      // (cut short where the tab is narrow, its tools' room theirs: marking's actions wider than its keys)
      .cuts(Is(true))
      |> ignore
    })
    |> ignore
    f.show(fn() { vf_meta(vw, src) != "" }, fn(l) {
      l
      .words(By(fn() { vf_meta(vw, src) }))
      .words_look(By(fn() { tab_words(Caption, L4, 400) }))
      .ink(By(fn() { ink().muted }))
      .says(By(fn() { Some(@view.said(Text, label=vf_meta(vw, src))) }))
      .cuts(Is(true))
      |> ignore
    })
  })
  |> ignore
  row.box(fn(r) { tab_keys_node(r, src, vw, ink, corner, full, tips) }) |> ignore
}

///|
/// A file tab's keys in row `r` (tab_tools_node's, and the bar's over the whole window: viewer_tab_bar_tools): 预览 /
/// 源码, the reader's 目录, 搜索, 排版 panels (scroll-to-bottom floats at the stage's bottom-right), 下载 and 全屏
/// (`full`, where it is given), in `ink`, each `corner` round, their tips in `tips`.
fn tab_keys_node(
  r : @view.View,
  src : Source,
  vw : Viewer,
  ink : () -> @sf.ViewerInk,
  corner : @view.Live[Double],
  full : (() -> Unit)?,
  tips : @sf.TipLayer,
  gives? : Bool = false,
) -> Unit {
  // (`gives`: its keys made in the row of the bar over the whole window or of a window of its own, which leaves out
  // what has not the room (sf's viewer_bar_node: View::fits), each the `k`-th to leave into its ⋯ at its end, there only
  // while something did (View::drops); else a row of its own, kept whole)
  if !gives {
    r.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(@sf.keys_apart())).shrink(Is(0.0)) |> ignore
  }
  let slots : Array[(Ref[@view.View?], () -> Bool, () -> @sf.MenuItem?)] = []
  // each of its keys there while `!vw.marks_here() && there()` says so, the `k`-th to leave where it gives
  // (tab_keys_drop_*), what it is in its ⋯ once it left
  let slot = fn(k : Int, there : () -> Bool, menu : () -> @sf.MenuItem?, make : (@view.View) -> Unit) {
    let held : Ref[@view.View?] = Ref(None)
    let shown = fn() { !vw.marks_here() && there() }
    r.show(shown, fn(x) {
      held.val = Some(x)
      if gives {
        x.drops(Is(k)) |> ignore
      }
      make(x)
    })
    slots.push((held, shown, menu))
  }
  // (marking it: marking's actions in their place, Viewer::marks_here)
  r.show(fn() { vw.marks_here() }, fn(k) { marks_actions_node_of(k, vw, ink, tips) })
  // (loading or upgrading an image: progress in the bar)
  if gives {
    r.show(fn() { !vw.marks_here() && vw.image_loading() }, fn(x) {
      @sf.viewer_coming_node(x, fn() { vw.got.get() }, fn() { vw.file.size }, ink) |> ignore
    })
  } else {
    r.show(fn() { !vw.marks_here() && vw.image_loading() }, fn(x) {
      @sf.viewer_coming_node(x, fn() { vw.got.get() }, fn() { vw.file.size }, ink, lead=false, track=@sf.vfr_head_coming_track)
      |> ignore
    })
  }
  // 预览 / 源码: a table's, a page's, an mbui widget's, once read (the library's segmented choice, what it chooses told:
  // Viewer::set_source)
  let sourced = fn() { vw.bytes.get() is Some(_) && vf_has_source(vw) }
  slot(
    tab_keys_drop_source,
    sourced,
    fn() {
      let now = vw.source
      Some(
        @sf.menu_item_of(
          @sf.t(if now { "web-main.preview.rendered" } else { "web-main.preview.source" }),
          fn() { vw.set_source(!now) },
        ),
      )
    },
    fn(x) {
      x.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      @sf.seg_node(
        x,
        fn() { [@sf.t("web-main.preview.rendered"), @sf.t("web-main.preview.source")] },
        fn() {
          vw.source_told.get() |> ignore
          if vw.source {
            1
          } else {
            0
          }
        },
        fn(k) { vw.set_source(k == 1) },
        item_w=vf_tabs_item,
      )
      |> ignore
    },
  )
  // the reader's panels, opened from here (the layout's in the tab's stage; scroll-to-bottom floats at bottom-right)
  let panels = [
    (@sf.ReaderPanel::Contents, "list", @sf.t("web-pages.drive.reader.contents"), tab_keys_drop_contents),
    (@sf.ReaderPanel::Find, "search", @sf.t("web-pages.drive.reader.find"), tab_keys_drop_find),
    (@sf.ReaderPanel::Layout, "text", @sf.t("web-pages.drive.reader.layout"), tab_keys_drop_layout),
  ]
  for p in panels {
    let (panel, icon, label, k) = p
    slot(
      k,
      fn() { vf_reads(vw) },
      fn() { Some(@sf.menu_item_of(label, fn() { @sf.reader_panel_toggle(vw.read_key(), panel) }, icon~)) },
      fn(x) {
        @sf.tool_node(
          x,
          fn() { { icon, label, on: @sf.reader_panel_of(vw.read_key()) == panel, disabled: false } },
          ink,
          corner,
          fn() { @sf.reader_panel_toggle(vw.read_key(), panel) },
          tip=tips,
        )
        |> ignore
      },
    )
  }
  // 标注图片: once its whole picture is here, a picture it shows (as the whole window's bar has it: image_tools)
  slot(
    tab_keys_drop_mark,
    fn() { (gives || !vw.upgrading()) && vw.bytes.get() is Some(_) && vw.markable() },
    fn() { Some(@sf.menu_item_of(@sf.t("web-main.annotate.image"), fn() { vw.marks_start_here() }, icon="edit")) },
    fn(x) {
      @sf.tool_node(
        x,
        fn() { { icon: "edit", label: @sf.t("web-main.annotate.image"), on: false, disabled: false } },
        ink,
        corner,
        fn() { vw.marks_start_here() },
        tip=tips,
      )
      |> ignore
    },
  )
  // 复制: the whole picture on the clipboard, a check a moment after (as the whole window's bar has it: image_tools)
  let copy_image = fn() { vw.ask_copy() }
  slot(
    tab_keys_drop_copy,
    fn() { (gives || !vw.upgrading()) && vw.bytes.get() is Some(_) && vw.shown_kind() == Some(KImage) },
    fn() { Some(@sf.menu_item_of(@sf.t("common.copy"), fn() { copy_image() |> ignore }, icon="copy")) },
    fn(x) { @sf.copy_tool_node(x, ink, corner, copy_image, tip=tips) |> ignore },
  )
  // 下载: what is here saved at once; one told of, read whole first; a ring while the core downloads it
  let dl = fn() { vw.download(src) }
  let saving = fn() {
    // (a film or a song played as it comes: read whole as it is asked)
    vw.bytes.get() is Some(_) || ((vw.told_of() || vw.played()) && !vw.asked_now())
  }
  slot(
    tab_keys_drop_download,
    fn() { (gives || !vw.upgrading()) && !vw.coming() },
    fn() {
      Some(
        @sf.menu_item_of(
          @sf.t("web-main.preview.download"),
          fn() { vw.save_now() },
          icon="download",
          disabled=!@signals.untracked(saving),
        ),
      )
    },
    fn(x) {
      @sf.tool_node(
        x,
        fn() { { icon: "download", label: @sf.t("web-main.preview.download"), on: false, disabled: !saving() } },
        ink,
        corner,
        fn() { vw.save_now() },
        tip=tips,
        progress=fn() { if downloading(dl()) { Some(number(dl(), "progress")) } else { None } },
      )
      |> ignore
    },
  )
  // what left it, in its ⋯ at its end (there only while something did)
  if gives {
    r.box(fn(x) {
      x.drops(Is(-1)) |> ignore
      let at : Ref[@view.View?] = Ref(None)
      at.val = Some(
        @sf.tool_node(
          x,
          fn() { { icon: "more", label: @sf.t("web-main.menu.more"), on: false, disabled: false } },
          ink,
          corner,
          fn() {
            let gone : Array[@sf.MenuItem?] = []
            for s in slots {
              let (held, there, item) = s
              match held.val {
                Some(v) if @signals.untracked(there) && @signals.untracked(fn() { v.left_out() }) =>
                  match item() {
                    Some(m) => gone.push(Some(m))
                    None => ()
                  }
                _ => ()
              }
            }
            match at.val {
              Some(n) => @sf.menu(gone, from=Node(n))
              None => ()
            }
          },
          tip=tips,
        ),
      )
    })
    |> ignore
  }
  // 全屏: the tab over the whole window (tab_full.mbt)
  match full {
    Some(f) =>
      r.show(fn() { !vw.marks_here() }, fn(x) {
        @sf.tool_node(
          x,
          fn() { { icon: "expand", label: @sf.t("web-main.preview.fullWindow"), on: false, disabled: false } },
          ink,
          corner,
          f,
          tip=tips,
        )
        |> ignore
      })
    None => ()
  }
}

///|
/// Which of a file's keys in the bar of a window of its own leaves it first where it has not the room (View::drops: 1
/// first): 预览 / 源码 (the widest), then the reader's 排版, 搜索, 目录, then 标注图片, 复制, then 下载.
let tab_keys_drop_source : Int = 1

///|
let tab_keys_drop_layout : Int = 2

///|
let tab_keys_drop_find : Int = 3

///|
let tab_keys_drop_contents : Int = 4

///|
let tab_keys_drop_mark : Int = 5

///|
let tab_keys_drop_copy : Int = 6

///|
let tab_keys_drop_download : Int = 7

///|
/// How far a tab's picture is fitted clear of its stage's edges (the whole window's on a stage under 640, @motion.Zoom's),
/// and its room to be taken by the hand in from them.
let tab_picture_margin : Double = 12.0

///|
/// Words of the tools' row: the theme's `size`, `line` a line, `weight`, on one line.
fn tab_words(size : @ui.TextSize, line : @ui.Leading, weight : Int) -> @view.WordsLook {
  let th = @ui.tree_theme()
  let (px, own) = th.text_size(size)
  { size: px, weight, line: th.leading(line).unwrap_or(own), wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
}

///|
/// The keys of file tab `tab` of the chat whose tabs are kept by `chat` in the row of the bar over the whole window
/// (`row`, each `corner` round as the bar has them; sfdesk's tab_full_node.mbt): as its tools' row beside the chat has
/// them, but 全屏.
pub fn viewer_tab_bar_tools(
  row : @view.View,
  corner : @view.Live[Double],
  src : Source,
  chat : String,
  tab : String,
  tips : @sf.TipLayer,
) -> Unit {
  guard tab_viewer(chat, tab) is Some(vw) else { return }
  // (made in the bar's own row: short of room, a window of its own at its least, its keys leaving it into its ⋯,
  // tab_keys_node's `gives`)
  tab_keys_node(row, src, vw, fn() { @sf.page_viewer_ink() }, corner, None, tips, gives=true)
}

///|
/// The name of file tab `tab` of the chat whose tabs are kept by `chat` and the line about it (its size, its kind), as
/// its tools' row says them: the bar's over the whole window.
pub fn viewer_tab_title(src : Source, chat : String, tab : String) -> (String, String) {
  match tab_viewer(chat, tab) {
    Some(vw) => (vw.file.name, vf_meta(vw, src))
    None => ("", "")
  }
}

///|
/// A tab's film or song in `h` (its stage, all of it), in the one player embedded in it as part of the pane
/// (@sf.player_node's `embedded`: on the pane's own ground, its picture or a song's cover fitted in the room over its
/// controls as far in as a tab's picture is, tab_picture_margin, the controls always there under it in the pane's
/// colours, laid out by the stage's size as it is given): its own player and view, not the whole window's; no keys, no
/// flight, nothing to close (the tab's tools have its name, 下载 and 全屏).
fn tab_player_node(h : @view.View, src : Source, vw : Viewer) -> Unit {
  guard vw.media is Some(m) else { return }
  // (a fixture's: how it stands pinned, the same on every run)
  match vw.pinned {
    Some(p) => m.pin(p)
    None => ()
  }
  h.by_room(fn(held, room) {
    // (as wide as the stage is given and as tall; the window's till it is first laid out)
    let size = fn() { (room.width(), room.height().unwrap_or(held.window_h())) }
    held.box(fn(k) {
      k.height(By(fn() { Some(size().1) })) |> ignore
      @sf.player_node(
        k,
        m,
        vw.player_file(),
        size,
        back_label=fn() { "" },
        on_back=fn() {  },
        // (a song has no picture: no still of it is asked for)
        still=fn() { if vw.shown_kind() == Some(KVideo) { vw.still(src) } else { "" } },
        flying=fn() { false },
        going=fn() { false },
        move_beside=fn() { None },
        embedded=true,
        margin=tab_picture_margin,
      )
      |> ignore
    })
    |> ignore
  })
  .grow(Is(1.0))
  .basis(Is(Some(0.0)))
  .min_height(Is(Some(0.0)))
  |> ignore
}

///|
/// A tab's picture in `s` (its stage, all of it; tab `tab` of the chat whose tabs are kept by `chat`): fitted as the
/// whole window's is (tab_picture_margin clear of the stage's edges, never larger than its own size: its zoom's,
/// new_viewer), laid out so in the stage less that margin and drawn as its zoom has it as the frame is drawn, grown about
/// its middle and moved as far from it as the zoom says; the wheel zooms it (with ⌘ or ⌃, a trackpad's pinch) or pans it
/// zoomed, two fingers pinch it, one pans it zoomed, a double press zooms in and back, each at its event's moment, the
/// zoom told the stage's size as it is laid out and the picture's as it comes. What takes the hand is the stage less the
/// margin, clear of what lies at its edges (the side panel's edge). While it comes with nothing to stand in for it, how
/// much has; not read, or no picture in it, why. The pointer's secondary button on it, its menu (复制图片). Marked
/// (Viewer::marks_here): one finger draws what marking's tool draws, the marks drawn over it, marking's tools under it (tab_marks_foot_node). The ways to the pictures beside it at
/// its sides while the pointer is over it (a finger's: while it is not marked), ← and → there or over the whole window,
/// Escape leaving what marking has open (marks_back): each a step of the tab (tab_step).
fn tab_picture_node(s : @view.View, src : Source, vw : Viewer, chat : String, tab : String) -> Unit {
  s.over(Is(true)) |> ignore
  let z = vw.zoom
  let m = tab_picture_margin
  let marked = fn() { vw.marks_here() }
  // (over the whole window as its tab: its keys whatever the pointer is over)
  let over_all = fn() {
    match tab_full.get() {
      Some(f) => f.tab == tab && f.chat.station + ":" + f.chat.session == chat
      None => false
    }
  }
  // (the stage's own terms: the zoom's, the margin round the hand's room put back)
  let tell_natural = fn(at : Double) {
    let (nw, nh) = vw.natural_size(src)
    z.natural(nw, nh, at~)
  }
  let tell = fn(w : Double, h : Double, at : Double) {
    z.boxed(w + 2.0 * m, h + 2.0 * m, at~)
    tell_natural(at)
  }
  // how much larger than fitted it is drawn, and how far its middle is from the stage's, as node `n` is drawn: where
  // the zoom has it (as each frame draws it while it glides or flings, else as it was told)
  let placed = fn(n : @view.View) -> (Double, Double, Double) {
    z.told()
    let t = n.drawn_while(fn(at) { z.goes_at(at) })
    let fitted = z.nw * z.fit()
    match z.rect_at(t) {
      Some((x, y, w, h)) if fitted > 0.0 => (w / fitted, x + w / 2.0 - z.bw / 2.0, y + h / 2.0 - z.bh / 2.0)
      _ => (1.0, 0.0, 0.0)
    }
  }
  // two fingers' last middle and how far apart they were (0: one finger), one finger's last place, whether two were on
  // it since the first went down (a mark being drawn called off then)
  let fingers : Map[Int, (Double, Double)] = Map([])
  let pinch : Ref[(Double, Double, Double)] = Ref((0.0, 0.0, 0.0))
  let pinched : Ref[Bool] = Ref(false)
  let last : Ref[(Double, Double)] = Ref((0.0, 0.0))
  let moved : Ref[Double] = Ref(0.0)
  let apart = fn() {
    let at = fingers.values().to_array()
    if at.length() < 2 {
      (0.0, 0.0, 0.0)
    } else {
      let (ax, ay) = at[0]
      let (bx, by) = at[1]
      ((ax + bx) / 2.0, (ay + by) / 2.0, ((ax - bx) * (ax - bx) + (ay - by) * (ay - by)).sqrt())
    }
  }
  // (a finger on it while marked: what marking's tool does there, `phase` 0 down, 1 moved, 2 let go; at the stage's
  // point, where the picture is then)
  let marks_at = fn(phase : Int, x : Double, y : Double, at : Double) {
    match vw.marks_rect(at) {
      Some(r) => marks_finger(phase, x, y, r, z.nw)
      None => ()
    }
  }
  // zoomed in past fitted (or gliding there): the image itself asked for in place of its preview (Viewer::whole_due);
  // once asked, wanted till it comes, zoomed out again or not
  s.reacts(
    fn() {
      vw.zoom.told()
      let z = vw.zoom
      z.nw > 0.0 && (if z.gliding { z.g_to[0] } else { z.scale }) > z.fit() * 1.01
    },
    fn(zoomed) { if zoomed { vw.zoomed_in.set(true) } },
  )
  s
  .on_key(fn(k) {
    if marked() {
      if k.code == @ui.key_escape && k.mods == 0 {
        marks_back()
        return true
      }
      return false
    }
    if (k.code == @ui.key_code_left || k.code == @ui.key_code_right) &&
      k.mods == 0 &&
      (s.pointer_within() || over_all()) {
      tab_step(src, vw, chat, tab, if k.code == @ui.key_code_left { -1 } else { 1 })
      return true
    }
    false
  })
  |> ignore
  s.box(fn(stage) {
    stage.grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    // (the zoom told the stage's size as it is laid out, the picture's as it comes: what marks are drawn by from the
    // first, before a finger has been on it)
    stage.box(fn(o) {
      o.over(Is(true)) |> ignore
      o
      .by_room(fn(held, room) {
        held.reacts(fn() { (room.width(), room.height(), vw.natural_size(src)) }, fn(told) {
          match told {
            (w, Some(h), _) if w > 2.0 * m && h > 2.0 * m => tell(w - 2.0 * m, h - 2.0 * m, held.cause_at())
            _ => ()
          }
        })
      })
      .grow(Is(1.0))
      |> ignore
    })
    |> ignore
    stage.box(fn(room) {
      room.over(Is(true)).padding(Is((m, m, m, m))) |> ignore
      room.box(fn(area) {
        area
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        .min_height(Is(Some(0.0)))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .says(By(fn() { Some(@view.said(Image, label=vw.file.name)) }))
        .on_drag(
          fn(d) {
            tell(d.w, d.h, d.at)
            // (the stage's own terms for a point of the window's, as it is drawn then)
            let (ox, oy) = (d.x - d.wx + m, d.y - d.wy + m)
            let (sx, sy) = (d.x + m, d.y + m)
            match d.kind {
              Down => {
                fingers[d.finger] = (d.wx, d.wy)
                if fingers.length() == 1 {
                  z.stop_fling(at=d.at) |> ignore
                  last.val = (d.wx, d.wy)
                  moved.val = 0.0
                  pinched.val = false
                  if marked() {
                    marks_at(0, sx, sy, d.at)
                  }
                } else {
                  // (a second finger: a pinch; a mark being drawn or moved, called off)
                  marks_finger_off()
                  pinched.val = true
                  pinch.val = apart()
                }
              }
              Moved => {
                fingers[d.finger] = (d.wx, d.wy)
                if fingers.length() >= 2 {
                  let (cx, cy, dist) = apart()
                  let (px, py, was) = pinch.val
                  if was > 0.0 && dist > 0.0 {
                    z.transform(cx + ox, cy + oy, dist / was, cx - px, cy - py, at=d.at)
                  }
                  pinch.val = (cx, cy, dist)
                } else if marked() && !pinched.val {
                  marks_at(1, sx, sy, d.at)
                } else {
                  let (lx, ly) = last.val
                  moved.val = moved.val + (d.wx - lx).abs() + (d.wy - ly).abs()
                  if z.zoomed_at(d.at) {
                    z.pan(d.wx - lx, d.wy - ly, at=d.at)
                  }
                  last.val = (d.wx, d.wy)
                }
              }
              Up | Off => {
                let alone = fingers.length() == 1
                fingers.remove(d.finger)
                if fingers.length() == 1 {
                  // (one of two let go: the one left followed from where it is next)
                  pinch.val = (0.0, 0.0, 0.0)
                  last.val = fingers.values().to_array()[0]
                }
                if alone && marked() && !pinched.val {
                  // (let go: what it drew or moved put down; called off: dropped, or put back)
                  if d.kind == Up {
                    marks_at(2, sx, sy, d.at)
                  } else {
                    marks_finger_off()
                  }
                } else if d.kind == Up && alone && !marked() && moved.val <= tap_slop && area.twice(d) {
                  // a press let go where it went down, the second of two: in to 2.5 times fitted round it, or back
                  z.double_tap(sx, sy, at=d.at)
                }
              }
            }
          },
          fingers=2,
          whole=true,
        )
        .on_wheel(fn(w) {
          tell(w.w, w.h, w.at)
          vw.wheeled(z, w.x + m, w.y + m, w.dx, w.dy, w.mods, w.at)
        })
        // (the pointer's secondary button on the picture, not marked: its menu, as over the whole window, Viewer::menu_on)
        .on_menu(fn(e) {
          if marked() {
            return
          }
          match (z.rect_at(e.at), vw.bytes.get()) {
            (Some((rx, ry, rw, rh)), Some(_)) if e.x + m >= rx && e.x + m < rx + rw && e.y + m >= ry && e.y + m < ry + rh =>
              vw.picture_menu_at(e.wx, e.wy)
            _ => ()
          }
        })
        |> ignore
        // fitted: as wide as it is at most and no wider than its room, as tall for as wide, no taller than its room, in
        // its middle (contained in that box: as large as the zoom's fitted scale has it)
        area.box(fn(p) {
          p
          .width(By(fn() {
            let (nw, _) = vw.natural_size(src)
            if nw > 0.0 {
              Some(nw)
            } else {
              None
            }
          }))
          .max_width(Is(None), within=true)
          .aspect(By(fn() {
            let (nw, nh) = vw.natural_size(src)
            if nw > 0.0 && nh > 0.0 {
              nw / nh
            } else {
              0.0
            }
          }))
          .shrink(Is(1.0))
          .min_height(Is(Some(0.0)))
          .image(By(fn() { if vw.picture_failed() { None } else { vw.picture_shown(src) } }))
          .image_contains(Is(true))
          .scale(By(fn() { placed(p).0 }))
          .offset(By(fn() {
            let (_, x, y) = placed(p)
            (x, y)
          }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // (marked, once where it is is known: the marks drawn and the numbered marks' pins over it, over them the words
    // being written, a field of the tree's: as the whole window's canvas has them)
    stage.show(fn() { marked() && vw.marks_shown() }, fn(h) {
      h.over(Is(true)) |> ignore
      h.box(fn(x) { marks_shapes_node(x, vw) }) |> ignore
      h.box(fn(p) { marks_pins_node(p, vw) }) |> ignore
    })
    stage.show(fn() { marked() && vw.marks_shown() && marking.writing is Some(_) }, fn(h) { marks_writing_node(h, vw) })
    // the ways to the pictures beside it (its chat's, its folder's), there while the pointer is over it (a finger's
    // always), none while it is marked; pressed, a step of the tab at that moment
    let tips_at : Ref[@view.View?] = Ref(None)
    let tips = @sf.TipLayer::new(fn() { tips_at.val })
    stage.box(fn(h) {
      h.over(Is(true)) |> ignore
      @sf.viewer_steps_node(
        h,
        fn() { !marked() && vw.near_ids(src).0 is Some(_) },
        fn() { !marked() && vw.near_ids(src).1 is Some(_) },
        fn(_) { !@sf.pointer_rests() || stage.pointer_within() },
        fn(_) { 1.0 },
        fn() {
          z.told()
          z.bw <= @sf.viewer_small_w
        },
        fn(dir) { tab_step(src, vw, chat, tab, dir) },
        tips,
      )
      |> ignore
    })
    |> ignore
    // (its read failed, or no picture in it: why)
    stage.show(fn() { vw.picture_failed() || vw.error.get() is Some(_) }, fn(f) {
      f.over(Is(true)).padding(Is((24.0, 24.0, 24.0, 24.0))).lines_up(Is(Some(Middle))) |> ignore
      f.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      f.box(fn(w) {
        w
        .words(By(fn() {
          match vw.error.get() {
            Some(e) => pv_fill("android-chat.file.loadFailed", [("error", e)])
            None => pv("android-chat.file.image.failed")
          }
        }))
        .words_look(By(fn() {
          let size = @sf.theme().t.body
          { size, weight: 400, line: @ui.tree_theme().text_line * size, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
        }))
        .ink(By(fn() { @sf.theme().p.muted }))
        |> ignore
      })
      |> ignore
      f.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    })
    tips_at.val = Some(stage.box(fn(l) { l.over(Is(true)) |> ignore }))
  })
  |> ignore
  // marking's tools under it while it is marked, the stage giving them their room
  s.show(marked, fn(f) { tab_marks_foot_node(f) })
  // (what is beside it read ahead once its own has come (or failed), the tab's own: as what is beside it is said)
  match tab_viewers.get(tab_viewer_id(chat, tab)) {
    Some(t) =>
      s.reacts(fn() { (vw.near_ids(src), vw.bytes.get() is Some(_), vw.error.get() is Some(_)) }, fn(_) {
        let (before, after) = vw.near(src, kept=t.near)
        vw.read_near(src, before, after, kept=t.near)
      })
    None => ()
  }
}

///|
/// Marking's tools under a tab's picture, in `f` (tab_picture_node's), one column in its middle: the notes' cards while
/// no note is written, the note being written in the tools' place, else the tools (the colours' row over them while
/// asked for): marking's foot over the whole window (marks_foot_node), laid under the picture, 8 under them.
fn tab_marks_foot_node(f : @view.View) -> Unit {
  f.shrink(Is(0.0)).padding(Is((12.0, 8.0, 12.0, 0.0))) |> ignore
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = @sf.TipLayer::new(fn() { tips_at.val })
  f.show(
    at_once=true,
    fn() {
      marks_said()
      marking.note < 0 && mark_notes().length() > 0
    },
    fn(r) { note_cards_node(r) },
  )
  f.show(
    at_once=true,
    fn() {
      marks_said()
      marks_note_shown() is Some(_)
    },
    fn(n) { note_box_node(n) },
  )
  f.show(
    at_once=true,
    fn() {
      marks_said()
      marking.note < 0
    },
    fn(t) { marks_tools_node(t, tips) },
  )
  tips_at.val = Some(f.box(fn(l) { l.over(Is(true)) |> ignore }))
}

///|
/// Tab `tab` of the chat whose tabs are kept by `chat`, viewer `vw`'s, stepped to the picture before (`dir` -1) or after
/// (1) its own in its chat or its folder (Viewer::near, the tab's own): that one's tab put in its place (Shell's
/// `beside_for`), what it steps through, its size and which of its message's it is said to its viewer as it is made
/// (tab_steps_said); none there, or marked, nothing.
fn tab_step(src : Source, vw : Viewer, chat : String, tab : String, dir : Int) -> Unit {
  if vw.marks_here() {
    return
  }
  let kept = match tab_viewers.get(tab_viewer_id(chat, tab)) {
    Some(t) => t.near
    None => Map([])
  }
  let (before, after) = vw.near(src, kept~)
  guard (if dir < 0 { before } else { after }) is Some(n) else { return }
  let next = view_tab_key(n.station, n.key, n.file, n.drive, n.named)
  // (its picture's size as its message says it: laid out at it from the first frame, decoded once at it)
  let said = tab_steps_said(next, vw.steps, n.file.width, n.file.height, None, n.at)
  match (shell.val.beside_for)(next, tab) {
    Some(_) => ()
    None => if said { tab_moved_dropped(next) }
  }
}

///|
/// A `.mbui` / `.wasm` side-panel tab's resolved `(title, icon)`, kicking off `vw.fetch(src)` if not yet started so
/// synchronous fixtures resolve on the very first frame and background `.mbui` tabs show their app title and icon.
pub fn tab_mbui_meta(
  src : Source,
  chat : String,
  tab : String,
  f : ViewTab,
  fallback_station : String,
) -> (String, String) {
  let station = if f.station != "" { f.station } else { fallback_station }
  let bytes = match tab_viewer(chat, tab) {
    Some(vw) => {
      if vw.bytes.untracked() is None && !vw.fetching.untracked() && vw.error.untracked() is None {
        vw.fetch(src)
      }
      vw.bytes.get()
    }
    None => None
  }
  viz_mbui_meta_of(station, f.key, f.file.path, f.file.name, bytes)
}

///|
/// Whether viewer `vw` shows a rendered native `.mbui` / `.wasm` widget in the window's tree.
pub fn viewer_mbui_rendered(vw : Viewer) -> Bool {
  vw.source_told.get() |> ignore
  vw.shown_kind() == Some(KMbui) &&
  !vw.source &&
  !vw.told_of() &&
  vw.bytes.get() is Some(b) &&
  viz_mbui_parse_bytes(vw.file.name, b) is Some(_)
}

///|
/// A rendered `.mbui` / `.wasm` widget in viewer `vw`'s stage (`bars`: true over the whole window under `image_bar`,
/// false in a side-panel tab under `tab_tools_node`).
pub fn viewer_mbui_node(parent : @view.View, src : Source, vw : Viewer, bars? : Bool = false) -> Unit {
  parent.over(Is(true)) |> ignore
  @ui.words_picked(parent)
  let session = vw.chat_session()
  let state_sig = viz_ensure_state(src, vw.station, vw.key, vw.file.path)
  let place = (if vw.beside { "beside/" } else { "viewer/" }) + vw.id()
  let scroll = @view.Scroll::new()
  parent.scrolls(scroll, fn(s) {
    s.padding(
      By(fn() {
        let s3 = @ui.Space::px(S3)
        if bars {
          let (top, foot) = (@sf.viewer_host().room)()
          let w = s.window_w()
          let under = if @sf.native_over.up {
            top + s3
          } else if w <= @sf.viewer_small_w {
            top + page_small_top
          } else {
            top + desk_page_top
          }
          let side = if w >= 960.0 { dmax(s3, (w - 880.0) / 2.0) } else { s3 }
          (side, under, side + @sf.native_clear(), foot + s3 * 2.0)
        } else {
          (s3, s3, s3, s3)
        }
      }),
    )
    |> ignore
    s.pick(
      fn() {
        match vw.bytes.get() {
          Some(b) => b.length()
          None => 0
        }
      },
      fn(p, _) {
        @sf.style_node(p, fn() { @ui.style(w=Full) })
        match vw.bytes.untracked() {
          Some(b) =>
            match viz_mbui_parse_bytes(vw.file.name, b) {
              Some(widget) =>
                viz_mbui_node(
                  p,
                  place,
                  widget,
                  fn() { state_sig.get().unwrap_or(Json::null()) },
                  {
                    keep: if vw.station != "" && vw.key != "" {
                      Some(fn(st) { viz_keep(src, vw.station, vw.key, vw.file.path, st) })
                    } else {
                      None
                    },
                    failed: None,
                    follow_up: if vw.station != "" && session != "" {
                      Some(viz_follow_up(vw.station, session))
                    } else {
                      None
                    },
                  },
                )
              None => ()
            }
          None => ()
        }
      },
    )
  })
  |> ignore
}
