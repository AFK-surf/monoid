// A message's files as nodes of the window's tree (message_files.mbt's message_files and card_item): laid in rows by
// the width the message is given, a row going on in the next where it has not the room; each file its own, any other
// than a picture or a video as its card, its download's state as the core says it, its menu where it is held or right
// clicked; a picture or a video in the box its data says (message_media_node.mbt).

///|
/// Where a message's file is shown, as it is now: its chat's station and session, and its view (whose session keeps a
/// file the core names none for: its first agent's).
// the chat's page as nodes: held by its tests, not used by the app yet
#warnings("-struct_never_constructed")
priv struct MessageFilesAt {
  station : () -> String
  session : () -> String
  view : () -> ChatView
  /// its message's `said` as it changes: said while the chat shows (its pictures brushed in only then)
  said : () -> Bool
  /// in a picture of the chat being shared, how it draws them (MessageNodeHere's)
  picture : MessagePicture?
  /// what their message offers of itself where it does as it is now (a message of the chat's: its link, its turn
  /// shared), after what each file's own menu offers (message_items_after)
  share : () -> MessageShare?
}

///|
/// What a file's or a picture's menu `items` offers of its message after its own, a line between (`share`, where the
/// message offers itself): its link copied and 多选 its turn shared, as its words' menu has them (sfbase's
/// message_items: its words' copy that menu's, not a file's), so a message of files alone offers those to a finger's
/// hold as to a right click. No line where nothing is before them; none of them where it offers nothing.
fn message_items_after(items : Array[@sf.MenuItem?], share : () -> MessageShare?) -> Unit {
  guard @signals.untracked(share) is Some(s) else { return }
  let more = @sfbase.message_items(@signals.untracked(s.link), "", s.go)
  guard !more.is_empty() else { return }
  if !items.is_empty() {
    items.push(None)
  }
  items.append(more)
}

///|
/// The same as a MessageHere out of a list (what the file's own actions take: opening it, quoting it, downloading it),
/// as it is when asked.
fn MessageFilesAt::here(self : MessageFilesAt) -> MessageHere {
  {
    station: (self.station)(),
    session: (self.session)(),
    view: (self.view)(),
    go: None,
    inline: false,
    gutter: 0.0,
    list: None,
    core: None,
  }
}

///|
/// A message's files in `parent` (message_files'), `list` as it is now, at the column's end where they are the viewer's
/// (`mine`): in rows by the width given, 6 apart along a row and between rows, a picture's and a video's box their data's
/// at most that width, a card as wide as what it says (236 at most, that width at most). `by`: whose message they are
/// (author, role, ts), for 引用 in their menus; `place` says where they are shown, `at()` names where they are as it is now
/// (thumb_occurrence's: a message sent from here by its key on its way, the chat's once the chat has it); `over`: the
/// room over them (message_files'). A picture's and a video's size follow the width given as bindings: the window or a
/// pane resized makes none of them again (what is held on one, how it came in, stay). Sent from here a moment ago, each
/// flies from where it stood (`flies_of`) with the rest of what was sent (`fly`: SentFly's, each its part by its key).
// the chat's page as nodes: held by its tests, not used by the app yet
#warnings("-unused_value")
fn message_files_node(
  parent : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  place : MessageFilesAt,
  list : () -> Array[Attachment],
  mine : () -> Bool,
  by : () -> (String, String, String)?,
  at : () -> String,
  over? : () -> Double = fn() { 0.0 },
  flies_of? : (String) -> (Double, Double, Double, Double)? = fn(_) { None },
  fly? : SentFly = sent_fly_alone,
) -> Unit {
  // (none, as most messages have: nothing worked out for them but whether there are some)
  parent.show(fn() { list().length() > 0 }, fn(s) {
    // (the files as they are now, worked out once as what they are worked out of changes: each file's every reading of
    // itself below goes through this, not through the message again)
    let listed = @signals.computed(fn(_) { list() })
    let list = fn() { listed.get() }
    // (across all of what holds it, as its room is: a message of one's own lines its files up at its end in it
    // (files_wrap_end), never by the box shrinking to them, which would give its room one width measured and another
    // laid out, all made by it said again between the two at each layout)
    s.width_share(Is(1.0)) |> ignore
    s.by_room(fn(r, room) {
      r.box(fn(files) {
        // (in a picture of the chat being shared, the room each one's ✕ hangs in past its top kept over the first line,
        // and between lines on top of their own, out to the scale's next step: publish.mbt)
        let hung = if place.picture is Some(_) { @sf.corner_remove_reach(@sf.message_file_corner) } else { 0.0 }
        @sf.style_node(files, fn() {
          let wrap = if mine() { files_wrap_end } else { files_wrap }
          let o = over() + hung
          if o > 0.0 { wrap.then(@ui.style(pt=@sf.room_of(o))) } else { wrap }
        })
        files.wraps(Is(Some(if hung > 0.0 { scale_up(files_gap + hung) } else { files_gap }))) |> ignore
        // (the files kept by key: a file's block told as that file changes, comes or goes, never as another does)
        let by_key = files.keyed_by(list, @sfbase.file_key)
        files.each(fn() { by_key.keys() }, fn(k) { k }, fn(slot, k) {
          // (its key read through what it is given, never kept: a block may be taken to show another key; read once
          // as that or its file changes, what reads it many times over reading that)
          let found = @signals.computed(
            fn(_) {
              let key = k.get()
              match by_key.get(key) {
                Some(x) => x
                None => attachment_of({ "name": Json::string(""), "path": Json::string(key) })
              }
            },
          )
          let a = fn() { found.get() }
          // (sent from here a moment ago: where its tile stood in the composer, which it flies from as it is made:
          // sfbase's sent_part_take, taken once)
          let part = @signals.untracked(fn() { k.get() })
          let from = @signals.untracked(fn() { flies_of(part) })
          // (only in the change it was made in, the send's: made again later (its size come with the station's copy
          // of it, as its message is delivered), it is there as it is, never flown again from where its tile stood
          // then, nor a flight paired as that change lays out what is made for it)
          let made_at = slot.cause_at()
          let from_now = fn(v : @view.View) { if v.cause_at() == made_at { from } else { None } }
          slot.box(fn(item) {
            item.max_width(By(fn() { Some(room.width()) })).shrink(Is(0.0)) |> ignore
            // (in a picture of the chat being shared, as it draws it: publish.mbt)
            let drawn = fn(item : @view.View) {
            item.pick(fn() { file_kind(a().name) }, fn(p, kind) {
              match kind {
                "image" => {
                  // (its box as its data says it, at most the width given, bound to both; the same nodes whatever its
                  // data comes to say, a picture sent from here told its size as the core's row takes it over keeping
                  // its flight and how it came in: what shows of it bound inside, message_image_node)
                  let size = fn() { media_size(a(), image_least, image_min_side, room.width()) }
                  message_image_node(p, src, place, a, by, at, fn() { size().0 }, fn() { size().1 }, flies=sent_flies(fly, part, from_now(p)))
                }
                "video" => {
                  // (made anew for another file, its still read for the file it is made for; its size bound)
                  let size = fn() { media_size(a(), video_least, 0.0, room.width()) }
                  p.pick(at_once=true, fn() { @sfbase.file_key(a()) }, fn(q, _) {
                    message_video_node(q, src, tips, place, a, by, at, fn() { size().0 }, fn() { size().1 }, flies_from=from_now(q), fly~, part~)
                  })
                  |> ignore
                }
                _ => {
                  let card = message_file_card_node(p, src, tips, place, a, by, at)
                  // (its card carried from its tile, from the tile's size to its own, as words sent go)
                  match from_now(p) {
                    // (from where its tile stood, at its own size: a card is no tile's square, never drawn
                    // stretched to one on its way)
                    Some(r) => fly.flies_in(card, part, fn(to) { Some((r.0, r.1, to.2, to.3)) })
                    None => ()
                  }
                }
              }
            })
            }
            match place.picture {
              Some(pic) => (pic.file)(item, @signals.untracked(by).map(fn(b) { b.2 }).unwrap_or(""), a, drawn)
              None => drawn(item)
            }
          })
          |> ignore
        })
      })
      |> ignore
    })
    .width_share(Is(1.0))
    |> ignore
  })
}

///|
/// A picture's or a video's box in a message (image_box's, `least` thick, `side` its least where it is cut), at most
/// `room` wide: (width, height).
fn media_size(a : Attachment, least : Double, side : Double, room : Double) -> (Double, Double) {
  let (bw, bh, _) = image_box(a, least, min_side=side)
  let w = dmin(bw, room)
  (w, bh * w / bw)
}

///|
/// Any other file of a message as its card (card_item's): pressed, the preview; while the core downloads it, or brings
/// it after everything else once opened and let go, how far in its size's place, ✕ to call it off; failed, why, ↻ to
/// ask it again. Held or right clicked, its menu (引用, 在侧边打开, 下载) where.
fn message_file_card_node(
  parent : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  place : MessageFilesAt,
  a : () -> Attachment,
  by : () -> (String, String, String)?,
  at : () -> String,
) -> @view.View {
  // (what the core says of its download, and of its being brought once opened and let go: kept)
  let coming = fn() { card_coming(src, place.here(), a()) }
  let active = fn() {
    let (dl, kept) = coming()
    flag(dl, "active") || kept is Some(_)
  }
  let failed = fn() { text(coming().0, "state") == "failed" && !active() }
  @sf.file_card_node(
    parent,
    tips,
    fn() { a().name },
    fn() {
      if failed() || active() {
        text(coming().0, "statusText")
      } else {
        @sf.file_size(a().size)
      }
    },
    failed,
    failed,
    active,
    fn() { @sf.t("web-main.file.retryDownload") },
    fn() {
      if coming().1 is Some(_) {
        @sf.t("web-pages.files.stopKeeping")
      } else {
        @sf.t("web-main.file.cancelDownload")
      }
    },
    fn(on) {
      let here = place.here()
      let a = a()
      let (dl, kept) = card_coming(src, here, a)
      let id = text(dl, "id")
      match on {
        Remove => if kept is Some(_) { keeping_stop(src, id) } else { download_cancel(src, id) }
        Retry => download_retry(src, id)
        Open => open_file(here, a, at=at())
        Restore => ()
      }
    },
    menu=fn(x, y) {
      let here = place.here()
      let a = a()
      let owner = owner_of(here, a)
      let items : Array[@sf.MenuItem?] = []
      match quote_of(here, a, owner, by()) {
        Some(q) => items.push(Some(@sf.menu_item_of(@sf.t("web-main.chat.quote"), q, icon="quote")))
        None => ()
      }
      // (those offered here alone, no line where one is not: message_files's file_options)
      for x in [beside_option(here, a, at()), download_option(src, here, a, owner)] {
        if x is Some(_) {
          items.push(x)
        }
      }
      message_items_after(items, place.share)
      @sf.menu(items, from=@sf.at_point(x, y))
    },
  )
}

///|
/// A message's files laid along rows (files_column and files_row as one): 6 apart along a row, the rows 6 apart; the
/// viewer's at the column's end.
// kept across runs: a value (no field of it changes)
let files_wrap : @ui.Style = @ui.css("row w=Full gap=S1_5 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let files_wrap_end : @ui.Style = @ui.css("row w=Full gap=S1_5 align=AStart justify=JEnd")
