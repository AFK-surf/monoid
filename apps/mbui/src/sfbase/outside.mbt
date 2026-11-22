// What a draft refers to, shared before it goes, for every composer: words
// with a reference to another chat in them (a mark, as the core read them: refs.mbt) are asked of the core before
// they go: the chats of the viewer's other workspaces they name that are not shared with this workspace yet, and
// which of them the viewer may share (`chat.outsideRefs`). With none (or a core that cannot say) they go at once; else
// a page asks (the phone's sheet, the desktop's dialog), and its yes shares those the viewer may with this workspace
// (the core's `chat.outsideShare`), then sends; with none they may share, the yes sends as it is. A share failing is
// said, nothing sent. A second send while the core is asked does nothing. What lets it go (the core's answer, the
// viewer's yes, a share done) sends it there and then, outside any build, as a press does: never left for a composer's
// next build to find, which a part kept as it was (an island read as it came, not as it is: a device's frames) would not
// build again for it.

///|
/// A chat of another workspace that what is sent refers to: its station and id, its title,
/// its workspace and that's name, whether the viewer may share it (its starter, or an owner or admin there).
pub(all) struct OutsideRef {
  station : String
  id : String
  title : String
  workspace : String
  workspace_name : String
  workspace_emoji : String
  workspace_icon : String
  may : Bool
}

///|
/// A draft's send waiting on what it refers to: asked of the core (`checking`), or asked of the viewer (`open`, its
/// chats, sharing them: `busy`, why that failed: `error`). Cleared to go (the core said nothing is outside, the viewer
/// said yes, or it was shared), it is sent at that moment (outside_goes).
pub(all) struct OutsideAsk {
  /// the draft's key, the station it is written on, the words it sends
  key : String
  station : String
  words : String
  /// sends it (the composer's send, as it was pressed)
  send : () -> Unit
  chats : @sf.LiveArray[OutsideRef]
  checking : @signals.Signal[Bool]
  open : @signals.Signal[Bool]
  busy : @signals.Signal[Bool]
  error : @signals.Signal[String]
}

///|
/// The send asking now (one at a time), read by the composer as it is built (its sheet or dialog, outside_asking): a
/// signal, so what is asked or answered between frames builds what reads it again, kept or not.
// kept across runs: put back by outside_reset
// (signal_ref: an asking holds its send and its signals, nothing to compare; each set is another asking, or none)
pub let outside_ask : @signals.Signal[OutsideAsk?] = @signals.signal_ref(None)

///|
fn outside_reset() -> Unit {
  outside_ask.set(None)
}

///|
/// Sends what draft `key` holds (`words`, written on `station`) by `send`, once this workspace's agents can read what
/// it refers to: no mark in it (as the core read its field: refs.mbt), or only marks this run put in of this workspace's
/// chats (refs_here_only), at once; else the core is asked first. Nothing
/// is asked on a read-only run, whose send says it sends nothing.
pub fn send_sharing(src : Source, key : String, station : String, words : String, send : () -> Unit) -> Unit {
  // (references this run's picks and pastes put in, every one to a chat of this workspace: nothing the core could find
  // outside it, so nothing asked, sent at once as words without any: refs_here_only)
  if !words.contains("@[") ||
    refs_marked(key) is Some(false) ||
    src.read_only ||
    !station.contains("/") ||
    refs_here_only(station, words) {
    send()
    return
  }
  match outside_ask.get() {
    // asked already, or asking: a second send does nothing meanwhile
    Some(s) if s.key == key && (s.checking.get() || s.open.get()) => return
    _ => ()
  }
  let s : OutsideAsk = {
    key,
    station,
    words,
    send,
    chats: @sf.LiveArray::from([]),
    checking: @signals.signal(true),
    open: @signals.signal(false),
    busy: @signals.signal(false),
    error: @signals.signal(""),
  }
  outside_ask.set(Some(s))
  (src.call)("chat.outsideRefs", { "station": Json::string(station), "text": Json::string(words) }, fn(res) {
    s.checking.set(false)
    // a core that cannot say (one before sharing) leaves it as before: sent as it is
    let chats = match res {
      Ok(v) => outside_refs_of(v)
      Err(_) => []
    }
    if chats.length() == 0 {
      // (nothing to ask the viewer: it goes now, as the answer comes, the asking let go first; where it was let go of
      // meanwhile (the app begun again), nothing goes)
      if outside_is(s) {
        outside_ask.set(None)
        (s.send)()
      }
    } else {
      s.chats.replace(chats)
      s.open.set(true)
    }
  })
}

///|
/// The chats the core's `chat.outsideRefs` answers.
fn outside_refs_of(v : Json) -> Array[OutsideRef] {
  items(Some(v), "chats").map(fn(c) {
    let s = Some(c)
    {
      station: text(s, "station"),
      id: text(s, "id"),
      title: text(s, "title"),
      workspace: text(s, "workspace"),
      workspace_name: text(s, "workspaceName"),
      workspace_emoji: text(s, "workspaceEmoji"),
      workspace_icon: text(s, "workspaceIcon"),
      may: flag(s, "may"),
    }
  })
}

///|
/// Whether `s` is the asking now (not let go of, nor another asked since).
fn outside_is(s : OutsideAsk) -> Bool {
  match outside_ask.get() {
    Some(now) => physical_equal(now, s)
    None => false
  }
}

///|
/// Asking `s` decided yes (sent as it is, or shared): its asking down (its page's asking closes as it reads `open`, and
/// lets go of it as it has gone: outside_gone), and the words sent now, as the composer's send was pressed.
fn outside_goes(s : OutsideAsk) -> Unit {
  // (whether it is still the one asked, read before its asking closes: closing it lets go of it at once where its page
  // reads `open` as it changes, the composer made as nodes, outside_gone)
  let go = outside_is(s)
  s.open.set(false)
  if go {
    (s.send)()
  }
}

///|
/// What draft `key`'s send is asking the viewer, while it is (or while its asking is still shown going: `outside_gone`
/// once it has).
pub fn outside_asking(key : String) -> OutsideAsk? {
  match outside_ask.get() {
    Some(s) if s.key == key && (s.open.get() || !s.chats.is_empty()) => Some(s)
    _ => None
  }
}

///|
/// Whether the viewer may share any of what it asks about (its yes shares them; else it sends as it is).
pub fn outside_sharable(s : OutsideAsk) -> Bool {
  s.chats.iter().any(fn(x) { x.may })
}

///|
/// The asking's yes (分享并发送, or 仍然发送 with none to share): those the viewer may share shared with this workspace
/// by the core (`chat.outsideShare`), then it goes as the share's answer comes; failing, why is said and nothing goes.
/// With none to share, it goes as it is, now.
pub fn outside_yes(src : Source, s : OutsideAsk) -> Unit {
  if s.busy.get() {
    return
  }
  if !outside_sharable(s) {
    outside_goes(s)
    return
  }
  s.busy.set(true)
  s.error.set("")
  (src.call)("chat.outsideShare", { "station": Json::string(s.station), "text": Json::string(s.words) }, fn(res) {
    s.busy.set(false)
    match res {
      Ok(_) => outside_goes(s)
      Err(e) => s.error.set(@sf.t("web-main.outside.failed", args=[("error", error_words(e))]))
    }
  })
}

///|
/// The asking's no (取消, or closed): nothing goes, the words as they were.
pub fn outside_no(s : OutsideAsk) -> Unit {
  s.open.set(false)
}

///|
/// Its page's asking has gone (closed and shown no more): let go of it.
pub fn outside_gone(s : OutsideAsk) -> Unit {
  if outside_is(s) && !s.open.get() {
    outside_ask.set(None)
  }
}
