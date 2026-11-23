// A message's head as nodes of the window's tree, made once (message.mbt's agent_avatar, person_avatar, place_corner,
// message_name, message_time, elsewhere_route, as they draw it, their styles the same): whose it is (an agent's mark on
// its round ground, still.fail's without a maker, a person's face; the place it went to on the picture's corner), the
// name, when it was said (pressed: every time in the app the other way, absolute_times), and where it went or came
// from. What it shows bound to what it is told, as that changes; the hand's state read where it is drawn (lit_node).
// An agent's card over its name here, over its picture where its row puts it (message_agent_card_node).

///|
/// Where a message's nodes are shown (MessageHere's, made once): its chat (its station, its session, its view as it
/// changes), how wide its list is laid out (as it changes: what says whether its heads are inline, message_inline, and
/// how wide the viewer's words are at most, mine_most_of), the window's tips, and the page's time on top (what the
/// faces' pictures are asked for on), and where a quote's card leads (`jump`: the message it quotes by its ts, and the
/// passage; None, nowhere: MessageHere's `go`, the one it is given finding the message).
pub(all) struct MessageNodeHere {
  station : String
  session : String
  view : () -> ChatView
  width : () -> Double
  tips : @sf.TipLayer
  stint : () -> Int
  jump : ((String, String) -> Unit)?
  /// in a picture of the chat being shared (publish.mbt), how its messages' files are drawn there; None in its list
  picture : MessagePicture?
}

///|
/// How a picture of a chat being shared (publish.mbt) draws its messages' files: in the picture itself (`taking`),
/// else on the page that shares it. `file`: file `a` of message `ts`, as its message draws it (`draw`), in `parent`;
/// `viz`: a page of HTML `a` placed in message `ts`'s words, in `parent`, its card drawn by `card` where it is not
/// drawn as itself.
pub(all) struct MessagePicture {
  taking : Bool
  file : (@view.View, String, () -> Attachment, (@view.View) -> Unit) -> Unit
  viz : (@view.View, String, Attachment, (@view.View) -> Unit) -> Unit
}

///|
/// Whether a message's head is inline where it is shown (MessageHere's `inline`: no margin for the pictures, each over
/// its head's start), as its list's width says (the list's narrow arrangement, chat_narrow_w), as that changes.
fn message_inline(here : MessageNodeHere) -> Bool {
  (here.width)() <= chat_narrow_w
}

///|
/// The chat a message's node is shown in, as a page.
fn message_node_ref(here : MessageNodeHere) -> ChatRef {
  { station: here.station, session: here.session, title: (here.view)().title, station_name: "" }
}

///|
/// `agent` where it is one of the chat's agents (its session's key), else "": what opens its history.
fn message_agent_of(here : MessageNodeHere, agent : String) -> String {
  if agent != "" && (here.view)().agents.iter().any(fn(a) { a.key == agent }) {
    agent
  } else {
    ""
  }
}

///|
/// An agent's picture (agent_avatar's) in `v`: its model's `maker` (its `runtime`'s where none is said; still.fail's
/// mark without either) on the neutral ground, 18 round, one piece in bones; `corner` (a Place's surface; "" none), that
/// place's mark on its corner, where a place is said at all (None: an agent's own message, which never has one: no node
/// held for it); `bare`, its mark alone with no ground under it (an agent at work's, its ring round it). Each as it
/// changes. Its node (what its agent's card is over: message_agent_card_node).
fn agent_avatar_node(
  v : @view.View,
  maker : () -> String,
  runtime : () -> String,
  corner? : (() -> String)? = None,
  bare? : Bool = false,
) -> @view.View {
  v.box(fn(b) {
    let ground = if bare { agent_avatar_bare } else { agent_avatar_ground }
    @sf.style_node(b, fn() { ground })
    b.bone_whole(Is(true)) |> ignore
    let mark = fn() {
      let (m, r) = (maker(), runtime())
      if m != "" || r != "" {
        (m, agent_runtime(r))
      } else if @sf.theme().dark {
        ("", "stillfail_mark_dark")
      } else {
        ("", "stillfail_mark")
      }
    }
    b.pick(mark, fn(d, said) {
      if said.0 != "" || !said.1.has_prefix("stillfail_mark") {
        @sf.maker_mark_node(d, said.0, said.1, agent_mark_side) |> ignore
      } else {
        @sf.drawable_node(d, said.1, agent_mark_side) |> ignore
      }
    })
    match corner {
      Some(c) => place_corner_node(b, c)
      None => ()
    }
  })
}

///|
/// A place's mark on the corner of the picture `v` holds (place_corner's): over it, 14 round, 6 past its right and
/// foot, on the list's ground with a line round it; its platform's (`@sf.place_mark_name`'s) for `surface`, none for "".
fn place_corner_node(v : @view.View, surface : () -> String) -> Unit {
  v.box(fn(o) {
    o.over(Is(true)) |> ignore
    @sf.style_node(o, fn() { place_corner_room })
    o.show(fn() { surface() != "" }, fn(k) {
      @sf.style_node(k, fn() { place_corner_mark })
      k.pick(fn() { @sf.place_mark_name(surface(), @sf.theme().dark) }, fn(d, name) {
        @sf.place_mark_node(d, name, place_corner_side) |> ignore
      })
    })
  })
  |> ignore
}

///|
/// A person's picture in a chat (person_avatar's) in `v`: 18 round, their face where they have one (`picture`, asked
/// for on the page's time on top), their initial on their colour (by `id`) till then.
fn person_avatar_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  id : () -> String,
  name : () -> String,
  picture : () -> String,
) -> Unit {
  @sf.avatar_node(
    v,
    id,
    name,
    fn() {
      let p = picture()
      if p != "" { (src.picture)(p, (here.stint)()) } else { "" }
    },
    avatar_side,
  )
}

///|
/// A name over its message (message_name's) in `v`: `name` in the accent's ink, 240 at most, cut short past it; one of
/// the chat's agents' (`agent`) opens its history beside the chat, another chat's agent's (`from`, its link) that chat;
/// underlined then while the hand is on it (lit_node), and as wide as a press's least room less its head's gap at
/// least (its words at its start); one of the chat's agents' with its card over it, as over its picture (agent_hover's:
/// message_agent_card_node). Each as it changes: one that comes to be of the chat's agents after its row was made (the
/// chat's agents said after its messages) given its card and its hand then, nothing made again; none watched for so
/// where it can never be one (`may_be_agent` false: a person's row).
fn message_name_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  name : () -> String,
  agent : () -> String,
  from : () -> String,
  may_be_agent? : Bool = true,
) -> Unit {
  // (in a picture of the chat being shared, only words: what it would open is the chat's, not the picture's)
  let goes = fn() { here.picture is None && (agent() != "" || from() != "") }
  v.box(fn(b) {
    @sf.style_node(b, fn() { msg_name_room })
    let press = fn() {
      let a = @signals.untracked(agent)
      if a != "" {
        open_detail(src, message_node_ref(here), a)
      } else {
        open_link(@signals.untracked(from))
      }
    }
    @sf.presses_node(b, on=goes, press)
    // (its agent's card over it, the card's hand then its presses': one gesture a node; one that comes to be of the
    // chat's agents after it was made (the chat's agents said after its messages) given its card then, in place; none
    // in a picture of the chat)
    if here.picture is Some(_) {
      ()
    } else if @signals.untracked(agent) != "" {
      message_agent_card_node(b, src, here, agent, words_along=true, press~)
    } else if may_be_agent {
      let carded = Ref(false)
      b.reacts(fn() { agent() != "" }, at_start=false, fn(on) {
        if on && !carded.val && b.alive() {
          carded.val = true
          message_agent_card_node(b, src, here, agent, words_along=true, press~)
        }
      })
    }
    b.says(By(fn() { if goes() { Some(@view.said(Link, label=name())) } else { None } })) |> ignore
    b.box(fn(w) {
      w
      .words_runs(By(fn() { [@ui.span(name(), underline=goes() && @sf.lit_node(b))] }))
      .words_look(By(fn() { @ui.style_words(msg_name) }))
      .ink(By(fn() { @ui.style_ink(msg_name) }))
      .cuts(Is(true))
      .min_width(Is(Some(0.0)))
      .allow_ellipsis(Is(true))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// When it was said (message_time's) in `v`: how long ago, or when (absolute_times: pressed, every time in the app says
/// the other), 11 and muted, the other way in its tip (in `tips`); none while `time` says none. As each changes.
fn message_time_node(v : @view.View, tips : @sf.TipLayer, time : () -> Stamp?) -> Unit {
  let said = fn(other : Bool) {
    match time() {
      Some(s) => if absolute_times.get() != other { s.full } else { s.ago }
      None => ""
    }
  }
  // (the button's own words, no box of theirs in it; none and nothing to press while there is no time: no structure of
  // its own, a node a message's head the fewer than a show and its box)
  let b = @sf.words_button_node(v, fn() { said(false) }, fn() { msg_time }, shown=fn() { time() is Some(_) }, fn() {
    absolute_times.set(!absolute_times.get())
  })
  @sf.tip_node(tips, b, fn() { said(true) }) |> ignore
}

///|
/// Where it went or came from (elsewhere_route's) in `v`: its mark in the accent, 发送到 or 来自 Slack, the place (its
/// mark and its name; pressed where it has a link, the pointer's ground on it then), 发送失败 in red. As `s` changes.
fn elsewhere_route_node(v : @view.View, s : () -> Elsewhere) -> Unit {
  let place = fn() {
    match s().place {
      Some(p) => (p.surface, p.name, p.url, p.app)
      None => ("slack", "Slack", "", "")
    }
  }
  v.box(fn(r) {
    @sf.style_node(r, fn() { msg_route })
    @sf.icon_node(r, "send", route_icon, By(fn() { @sf.theme().p.accent }), name_now=fn() {
      if s().received { "received" } else { "send" }
    })
    |> ignore
    @sf.words_node(
      r,
      fn() {
        @sf.t(if s().received { "web-main.chat.fromSlack" } else { "web-main.history.sentTo" }).trim_end(chars=" ").to_owned()
      },
      fn() { route_words },
    )
    |> ignore
    @sf.place_node(
      r,
      fn() { place().0 },
      fn() { place().1 },
      fn(hot) { if hot { route_place_hot } else { route_place } },
      route_place_words,
      mark=route_mark,
      press=Some(fn() {
        let (_, _, url, app) = @signals.untracked(place)
        @sfbase.open_slack(app, url) |> ignore
      }),
      on=fn() { place().2 != "" },
    )
    |> ignore
    r.show(fn() { s().failed }, fn(f) {
      @sf.style_node(f, fn() { route_failed })
      @sf.words_node(f, fn() { @sf.t("web-main.history.sendFailed") }, fn() { route_failed_words }) |> ignore
    })
  })
  |> ignore
}
