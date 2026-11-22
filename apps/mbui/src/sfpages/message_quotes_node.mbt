// What a message quotes as nodes of the window's tree (message.mbt's quotes, its styles the same): each quote a card
// of its own ahead of the message (@sf.quote_card_node), its own picture in it (the file of the message's that it
// names: a mark's screenshot, an image or a video quoted) concentric with the card; pressed, it goes to the message it
// quotes where its place says where (MessageNodeHere's `jump`). Not here: a quote sent from the composer flying in
// (the list's flight), the passage lit where it is gone to (the list's).

///|
/// What a message quotes (`quotes`, of its `files`: the one each names in its card) in `v`, as they change: the
/// viewer's (`mine`) at the column's end, as wide as the widest needs and at most as its bubble may be; anyone
/// else's across the column. `at` names where its message is, as it is now (message_place: its quotes' pictures
/// `at/q:<i>`; another message's, a block put by and taken for another row, each card made again for it); `said`
/// its `said` (MessageFilesAt's). Sent from here a moment ago, each card flies from the composer's as its words' bubble
/// does from the field: from that card itself as one box (`shared_ids`, its composer made as nodes: the id each card
/// there was shared by, in their order); its own picture from its square in that card (`flies_of`: by
/// quote_picture_key, sfbase's sent_part_take), growing to its place in it as a file sent does; all of it with the rest of
/// what was sent (`fly`: SentFly's, each card its part sent_quote_part, its picture by its key).
fn message_quotes_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  quotes : () -> Array[Quote],
  files : () -> Array[Attachment],
  mine : Bool,
  at : () -> String,
  said? : () -> Bool = fn() { false },
  shared_ids? : Array[String] = [],
  flies_of? : (String) -> (Double, Double, Double, Double)? = fn(_) { None },
  fly? : SentFly = sent_fly_alone,
) -> Unit {
  let place = message_files_at(here, said)
  v.show(fn() { quotes().length() > 0 }, fn(cards) {
    @sf.style_node(cards, fn() {
      if mine {
        quote_cards_end.then(@ui.style(max_w=Fixed(mine_most_of((here.width)()))))
      } else {
        quote_cards
      }
    })
    let keys = fn() {
      let place = at()
      quotes().mapi(fn(i, q) { place + "|" + q.ts + "/" + i.to_string() })
    }
    cards.each(keys, fn(k) { k }, fn(slot, k) {
      // (its row as wide as the cards' column, as the old card is, w=Full in it: quote_box)
      @sf.style_node(slot, fn() { quote_card_row })
      // (sent from here a moment ago: the id its card in the composer was shared by, taken once as it is made)
      let made_i = @signals.untracked(fn() { keys().search(k.get()).unwrap_or(0) })
      let shared_id = shared_ids.get(made_i).unwrap_or("")
      // (read through its key, never kept: its place among the message's quotes)
      let i = fn() { keys().search(k.get()).unwrap_or(0) }
      let q = fn() -> Quote {
        match quotes().get(i()) {
          Some(q) => q
          None => { author: "", text: "", comment: "", ts: "", role: "", file: "" }
        }
      }
      let own = fn() { quote_file(q(), files()) }
      let jumps = fn() { here.jump is Some(_) && q().ts != "" }
      let card = @sf.quote_card_node(
        slot,
        here.tips,
        fn() { q().author },
        fn() { q().text },
        fn() { q().role },
        fn() { q().comment },
        jumps,
        fn() {
          match here.jump {
            Some(go) => {
              let now = q()
              if now.ts != "" {
                go(now.ts, now.text)
              }
            }
            None => ()
          }
        },
        pictured=fn() { own() is Some(_) },
        picture=fn(b) {
          let n = @signals.untracked(i)
          quote_picture_node(b, src, here, place, own, fn() { at() + "/q:" + n.to_string() }, fly~, part=@sfbase.quote_picture_key(n), flies_of=fn() {
            flies_of(@sfbase.quote_picture_key(n))
          })
        },
      )
      // (the card itself from the composer's it was sent from, on its words' bubble's way (mine_bubble_node: the same
      // flight, as long as it is far, its rise as late): one box from that card's (its ✕ and all) to this one's, what
      // each holds at its own size in it, the composer's going as this one's comes (View::shared's `container`;
      // sf/motion.mbt's kind 4))
      if shared_id != "" {
        fly.shares(card, sent_quote_part(made_i), shared_id, particle=true)
      }
    })
    |> ignore
  })
}

///|
/// A quote's card's row among its message's quotes: across the cards' column, where its card is across it (quote_box).
// kept across runs: a value (no field of it changes)
let quote_card_row : @ui.Style = @ui.css("w=Full")

///|
/// A quote's own file in its card (`own`, as it is now), as the old card's message_files lays its one file: at most as
/// wide as the card has room for, a picture's and a video's box their data's, its corner concentric with the card's
/// (quote_picture_corner).
fn quote_picture_node(
  b : @view.View,
  src : Source,
  here : MessageNodeHere,
  place : MessageFilesAt,
  own : () -> Attachment?,
  at : () -> String,
  flies_of? : () -> (Double, Double, Double, Double)? = fn() { None },
  fly? : SentFly = sent_fly_alone,
  part? : String = "",
) -> Unit {
  let a = fn() {
    match own() {
      Some(a) => a
      None => attachment_of({ "name": Json::string(""), "path": Json::string("") })
    }
  }
  let by = fn() -> (String, String, String)? { None }
  b.box(fn(column) {
    @sf.style_node(column, fn() { files_column })
    column.by_room(fn(r, room) {
      // (sent from here a moment ago: where its square stood in the composer's card, which it flies from as it is made;
      // taken once, and only in the change it was made in, the send's: made again later, there as it is)
      let from = @signals.untracked(flies_of)
      let made_at = r.cause_at()
      let from_now = fn(v : @view.View) { if v.cause_at() == made_at { from } else { None } }
      r.pick(at_once=true, fn() { file_kind(a().name) }, fn(p, kind) {
        // (its box as its data and the card's room have it, bound: the room changing (the window, the side panel)
        // sizes it again, never makes it again; message_files_node's)
        match kind {
          "image" => {
            let size = fn() { media_size(a(), image_least, image_min_side, room.width()) }
            message_image_node(p, src, place, a, by, at, fn() { size().0 }, fn() { size().1 }, corner=@sf.quote_picture_corner, flies=sent_flies(fly, part, from_now(p)))
          }
          "video" => {
            let size = fn() { media_size(a(), video_least, 0.0, room.width()) }
            // (made again only for another file: its still, its player's place)
            p.pick(at_once=true, fn() { @sfbase.file_key(a()) }, fn(q, _) {
              message_video_node(q, src, here.tips, place, a, by, at, fn() { size().0 }, fn() { size().1 }, corner=@sf.quote_picture_corner, flies_from=from_now(q), fly~, part~)
            })
            |> ignore
          }
          _ =>
            p.box(fn(item) {
              item.max_width(By(fn() { Some(room.width()) })).shrink(Is(0.0)) |> ignore
              message_file_card_node(item, src, here.tips, place, a, by, at) |> ignore
            })
            |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
