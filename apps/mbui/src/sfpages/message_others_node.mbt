// Someone else's message as nodes of the window's tree, made once (message.mbt's others_message, sent_elsewhere, their
// styles the same): its picture out in the margin before its words (inline: over its head's start), its head (name,
// where it went, time; where a mouse is what it is used with and it offers itself, its ⋯ at the head's end; right
// clicked, the same: message_menu_node), what it says under it; its picture held under the pane's top as a long one
// scrolls past (the old one's c.stick: View::sticky, where its list says so).

///|
/// What a message offers of itself (share_turn_tool's, others_message's `share`): its key (its list's Entry::id, as a
/// right click on it says it: what the menu that opens is open for, @sfbase.message_menu_on), its link and its words
/// as they are, and its turn's picture shared (`go`).
pub(all) struct MessageShare {
  key : () -> String
  link : () -> String
  words : () -> String
  go : () -> Unit
}

///|
/// Someone else's message (others_message's) in `v`: its picture (`avatar`, made in its room) out in the margin, held
/// over the row (inline: over its head's start, 3 down); its head (`name`; where it went, `route`, after it, or on a
/// line of its own under the head while inline; its time); `body` under them, 4 apart. Inline as `here` says as it
/// changes (message_inline). Where it offers itself (`share`) and a mouse is the native input (not @sf.more_held: a
/// finger has these on the bar over what it holds picked), its ⋯ at the head's end, shown while the pointer is on the
/// row or its menu is open (its words, its link, its turn shared: @sfbase.message_items, beside the ⋯'s room), and a
/// right click on the row offers the same to the window's menu (@sfbase.share_offer, at the click's moment); the ⋯
/// shown as well while the pointer is on another slice of the same message (View::list_item_pointed). `stick_top`: its
/// picture held so far under the top of what scrolls it as a long one scrolls past (View::sticky, the old view's
/// c.stick), out in the margin only; none, never. The row's node, and whether its ⋯'s menu is open (as that changes:
/// presented_from).
fn message_others_node(
  v : @view.View,
  here : MessageNodeHere,
  time : () -> Stamp?,
  avatar : (@view.View) -> Unit,
  name : (@view.View) -> Unit,
  route : ((@view.View) -> Unit)?,
  body : (@view.View) -> Unit,
  share? : MessageShare? = None,
  stick_top? : () -> Double,
) -> (@view.View, () -> Bool) {
  // (its ⋯ where a mouse is the native input: laid out by it, the head as it is whichever hand is on it now; a right
  // click whichever: message_menu_node)
  let offered = share
  let share = if @sf.more_held() { None } else { share }
  let menu_on : Ref[() -> Bool] = Ref(fn() { false })
  let node = v.box(fn(row) {
    @sf.style_node(row, fn() { if share is Some(_) { msg_row_share } else { msg_row } })
    match share {
      // (pointed at over all of it, its ⋯ shown then, nothing pressed for it: an old view's box with an id, hovered;
      // what is pressed in it, its name, time, links, as ever; a ground, no control: the arrow over it, said by nothing)
      Some(_) => row.points(Is(true)).as_ground() |> ignore
      None => ()
    }
    match offered {
      Some(s) => message_menu_node(row, s)
      None => ()
    }
    row.box(fn(col) {
      @sf.style_node(col, fn() { if share is Some(_) { msg_main_share } else { msg_main } })
      col.box(fn(head) {
        @sf.style_node(head, fn() { if message_inline(here) { msg_head_inline } else { msg_head } })
        // (in past its picture as much as it is drawn over its start: message_inline_way)
        message_inline_way(head, here, msg_space(@sf.message_head_in))
        name(head)
        match route {
          // (at once: the list's width says the arrangement, and what the window or the sidebar does to the width is
          // no motion of its own; nothing comes or goes)
          Some(r) => head.show(fn() { !message_inline(here) }, r, at_once=true)
          None => ()
        }
        message_time_node(head, here.tips, time)
        match share {
          Some(s) => {
            head.box(fn(sp) { sp.grow(Is(1.0)) |> ignore }) |> ignore
            head.box(fn(room) {
              @sf.style_node(room, fn() { msg_share_room })
              // (its menu beside its room, which is there whether the ⋯ shows or not: open while it is)
              let open = fn() { @sf.presented_from(Node(room)) }
              menu_on.val = open
              // (the message's key its ⋯ lit, let go as its menu closes however it closes: an item chosen too (多选,
              // 复制), which @sf.menu's `gone` is not told of)
              let lit_for = Ref("")
              room.reacts(open, fn(on) {
                if !on && lit_for.val != "" {
                  if @signals.untracked(fn() { @sfbase.message_more.get() }) == lit_for.val {
                    @sfbase.message_more.set("")
                  }
                  lit_for.val = ""
                }
              }, at_start=false)
              // (at once, as the old row's hand_shown: shown by where the hand is, no coming or going of its own, so
              // the ⋯ of a row the pointer left is gone as it leaves, not still there beside the next's)
              room.show(fn() { @sf.hovered_item_node(row) || open() }, at_once=true, fn(m) {
                @sf.icon_button_node(m, "more", fn() { @sf.t("web-main.menu.more") }, fn() {
                  // (the message lit while it shows, by its key: every piece of a long one, as its right click's)
                  let k = @signals.untracked(s.key)
                  @sfbase.message_more.set(k)
                  lit_for.val = k
                  @sf.menu(
                    @sfbase.message_items(@signals.untracked(s.link), @signals.untracked(s.words), s.go),
                    from=Node(room),
                    along=End,
                  )
                }, size=msg_share_side, tips=here.tips)
                |> ignore
              })
            })
            |> ignore
          }
          None => ()
        }
      })
      |> ignore
      match route {
        Some(r) =>
          // (at once, as over the head: an arrangement by the list's width, not a coming or a going)
          col.show(fn() { message_inline(here) }, at_once=true, fn(l) {
            @sf.style_node(l, fn() { msg_route_line })
            // (as far under the head as keeps the time's room and the place's whole, one over the other)
            l.margin(Is((0.0, route_line_down(), 0.0, 0.0))) |> ignore
            r(l)
          })
        None => ()
      }
      body(col)
    })
    |> ignore
    // (over the row, at its start: out in the margin, or over the head's start where inline)
    // (one node over the row, its room its own: no box of the layer's round it; as tall as the picture it holds, not
    // the row, so that held at a top (View::sticky) it goes no further than the row's foot leaves it)
    row.box(fn(av) {
      av.over(Is(true), from_top=true) |> ignore
      match stick_top {
        // (out in the margin, held under the pane's top as a long one scrolls past, pushed up by its foot: c.stick's;
        // set with its look, in the one binding)
        Some(at) =>
          @sf.style_node_and(
            av,
            fn() { if message_inline(here) { msg_avatar_inline } else { msg_avatar_room } },
            fn() { if message_inline(here) { None } else { Some(at()) } },
            fn(held) { av.sticky(Is(held)) |> ignore },
          )
        None => @sf.style_node(av, fn() { if message_inline(here) { msg_avatar_inline } else { msg_avatar_room } })
      }
      // (out in the margin as much as it is drawn so: message_inline_way)
      message_inline_way(av, here, @sf.message_avatar_reach)
      avatar(av)
    })
    |> ignore
  })
  (node, menu_on.val)
}

///|
/// How much more inline than it is laid out (-1 … 1) a message in a chat's list of `here` is drawn as node `n` is drawn:
/// none at rest; on the page's way to another width across chat_narrow_w (a side panel sliding in or out beside it, the
/// tape's panels moving), its list laid out anew as the way sets off in the arrangement of where it goes (or of the
/// narrower end), so much of the way to the arrangement at the way's other end as the column says is left of it
/// (@sfbase.column_laid's `toward`, `toward_by`): its picture and its head going across between out in the margin and
/// over the head's start as the column goes, never a step of either in the frame it sets off (2026-11-17: ±25 at the
/// set off and the close of 大屏's side panel).
fn message_inline_by(here : MessageNodeHere, n : @view.View) -> Double {
  let c = @sfbase.column_laid(here.station + "\u{1}" + here.session, n)
  if c.toward_by <= 0.0 {
    return 0.0
  }
  // (the list as wide as it is laid out, at the column's other end as much wider or narrower as that is)
  let w = (here.width)()
  let laid = if w <= chat_narrow_w { 1.0 } else { 0.0 }
  let other = if w + (c.toward - c.laid) <= chat_narrow_w { 1.0 } else { 0.0 }
  (other - laid) * c.toward_by
}

///|
/// Node `n` of a message in a chat's list of `here`, `by` further across where it is laid out inline than where its
/// picture is out in the margin, drawn that much across for as much more inline as it is drawn than laid out
/// (message_inline_by): bound once a column has first set off on the page's way (none at rest, as the page's column's
/// own: chat_page_made's `narrower`), told directly as it does, no binding of each row's following the count
/// (@sfbase.column_set_off_each).
fn message_inline_way(n : @view.View, here : MessageNodeHere, by : Double) -> Unit {
  let bound = Ref(false)
  let bind = fn() {
    if !bound.val && n.alive() {
      bound.val = true
      n.offset(By(fn() { (by * message_inline_by(here, n), 0.0) })) |> ignore
    }
  }
  if @signals.untracked(fn() { @sfbase.column_set_off_count() > 0 }) {
    bind()
  } else {
    @sfbase.column_set_off_each(n, bind)
  }
}

///|
/// A space said exactly (message_head_in), in points.
fn msg_space(s : @ui.Space) -> Double {
  match s {
    Exact(x) => x
    _ => 0.0
  }
}

///|
/// The room of a message's ⋯ at its head's end (share_turn_tool's share_turn_room), and the ⋯ as big.
// kept across runs: a value (no field of it changes)
let msg_share_room : @ui.Style = @ui.css("w=S6 h=S6")

///|
let msg_share_side : Double = 24.0

///|
/// What an agent of the chat said in Slack (or Feishu, or another chat) rather than here, or a person's message there it
/// was given (sent_elsewhere's), as `s` says as it changes, in `v`: drawn as a message of theirs, that place's mark on
/// the picture's corner and, after the name, where it went or came from, red where sending it failed; its words as
/// Markdown, its files under them (a person's message there came with them). In its row's room
/// (message_row_frame_node: `key`, its list's Entry::id `s:<key>`; `side`, `top`; `over`).
// the chat's page as nodes: held by its tests, not used by the app yet
#warnings("-unused_value")
fn sent_elsewhere_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  key : String,
  side : () -> Double,
  top : () -> Double,
  s : () -> Elsewhere,
) -> MessageRowNode {
  message_row_frame_node(v, fn() { key }, side, top, fn(m) { sent_elsewhere_body(m, src, here, key, s) })
}

///|
/// What was said elsewhere (sent_elsewhere's) in `v`, its row's room round it: sent_elsewhere_node's (`key` its list's
/// Entry::id). Its words, where it has any, are what is read in it and picked of it (of its key, as an agent's are);
/// a link in them held (or right clicked) its menu. No link's card nor a chat's title for a bare link: what was said
/// elsewhere comes with neither (Elsewhere has no `links`), as the old row had none.
fn sent_elsewhere_body(v : @view.View, src : Source, here : MessageNodeHere, key : String, s : () -> Elsewhere) -> Unit {
  let surface = fn() {
    match s().place {
      Some(p) => p.surface
      None => "slack"
    }
  }
  let agent = fn() {
    let e = s()
    if e.received { "" } else { message_agent_of(here, e.by.agent) }
  }
  message_others_node(
    v,
    here,
    fn() { s().time },
    fn(av) {
      av.pick(fn() { s().received }, fn(a, received) {
        if received {
          a.box(fn(p) {
            @sf.style_node(p, fn() { person_avatar_room })
            person_avatar_node(p, src, here, fn() { s().by.name }, fn() { s().by.name }, fn() { s().by.picture })
            place_corner_node(p, surface)
          })
          |> ignore
        } else {
          let pic = agent_avatar_node(a, fn() { s().by.maker }, fn() { s().by.runtime }, corner=Some(fn() {
            if surface() == "feishu" { "feishu" } else { "slack" }
          }))
          // (one of the chat's agents': its card over its picture, as the old row's agent_avatar has it)
          message_agent_card_node(pic, src, here, agent, pointed=true)
        }
      })
    },
    fn(h) { message_name_node(h, src, here, fn() { s().by.name }, agent, fn() { "" }) },
    Some(fn(r) { elsewhere_route_node(r, s) }),
    fn(b) {
      // (its words in its body itself, as they are (none: nothing of them laid out); what is read in it starts there,
      // under its head line; what is picked of it of its key, its words alone)
      let w = @sf.markdown_node(
        b,
        fn() { s().text },
        size=fn() { body_size },
        on_link=fn(h) { open_link(h) },
        on_link_hold=Some(message_link_held),
      )
      w.read_from() |> ignore
      @ui.picked_of(w, key, whole=true) |> ignore
      // (its files, where it came with some: one from elsewhere is said whole as it comes, never given more after; none
      // made for the many that come with none)
      if @signals.untracked(fn() { s().attachments.length() > 0 }) {
        message_files_node(
          b,
          src,
          here.tips,
          message_files_at(here, fn() { false }),
          fn() { s().attachments },
          fn() { false },
          fn() { None },
          fn() { "" },
        )
      }
    },
  )
  |> ignore
}

///|
/// How far apart the middles of a head's time and of the place on the line of its own under it (inline) stand, laid
/// out with nothing between them, at the default size of words: half the head's line (24), the column's gap (4), half
/// the place (20). Larger words only set them further apart.
let route_line_apart : Double = head_line_h / 2.0 + 4.0 + 10.0

///|
/// How much further down an inline head's line of where it went goes, so that its place and the time over it each
/// have a press's least room (@ui.room_least: a keyboard and mouse's 36, a finger's 44) neither cutting the other's
/// (the old view's had 31 and 32: the coordinator, 2026-11-11).
fn route_line_down() -> Double {
  ignore(route_line_apart)
  0.0
}
