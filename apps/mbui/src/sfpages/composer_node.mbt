// A chat's composer made as nodes of the window's tree (composer.mbt's chat_composer, made once): where its page is
// made as nodes (sfbase's chat_page_nodes), in its messages' list's foot (chat_page_made's `foot_node`). What it holds
// and how it answers is the old composer's, said here by the tree's own mechanisms: a frosted capsule that grows into
// a box with its text, ＋ and send at its ends; opened (focused, written in, a file or a quote waiting) its words over
// its row of ＋, what is said before send and send, the quotes and files waiting over the words. One field all along
// (its node never made again as it opens or shuts: the focus, the caret and what the input method composes stay with
// it): one row that goes on to a second line once it is opened, its words the whole of the first (View::wraps), ＋
// laid over its foot's start (it stands there in either shape, the words kept clear of it while it is a capsule). What
// it holds is the draft as the core keeps it (sfbase's compose.mbt); what it reads of its chat is its head alone
// (sfbase's chat_view_now: a word streamed into a message reads none of it again).

///|
/// What a chat's composer made as nodes keeps of its own, each its draft's: when the cursor left it (it stays a box a
/// moment, let_go_ms), when typing last warmed its agent, the quotes' comment fields, the restores asked.
priv struct ComposingNode {
  /// a box kept a moment after the cursor left it, by draft (let_go_ms)
  held : @sf.LiveMap[String, Bool]
  /// how many times typing warmed each session's agent, and when last
  warmed : Map[String, (Int, Double)]
  /// the draft whose composer last came to show: another's coming takes the cursor
  mut shown : String
  /// the cursor put in it as its page comes (no cause of a way of its own: what the page is as it comes), and how many
  /// times it was: what changes its shape then is there at once
  mut quiet : Bool
  quiet_n : @signals.Signal[Int]
  /// the draft whose composer was given the cursor as its page came, before its field was made (its box made by the
  /// room its foot is given, after that): its field takes it as it is made
  mut focus_waits : String
}

///|
// kept across runs: put back by composing_reset
let composing_node : ComposingNode = { held: @sf.LiveMap::new(), warmed: {}, shown: "", quiet: false, quiet_n: @signals.signal(0), focus_waits: "" }

///|
/// What composing_node keeps, forgotten as a run starts (composing_reset).
fn composing_node_reset() -> Unit {
  composing_node.held.clear()
  composing_node.warmed.clear()
  composing_node.shown = ""
  composing_node.focus_waits = ""
}

///|
/// The line a composer's field is laid out on at the system's size of words `scale` (field_line's, a node's).
fn node_field_line(scale : Double) -> Double {
  @ui.sp_at(scale, @ui.style_words(@sf.theme().t.words).line)
}

///|
/// How much further in a capsule's round buttons stand than its padding says (capsule_extra's, a node's).
fn node_capsule_extra(scale : Double) -> Double {
  @sf.dmax(0.0, (node_field_line(scale) - @sf.theme().round.side) / 2.0)
}

///|
/// How many lines a composer's field grows to before it scrolls, in a window `high` tall (text_lines', a node's).
fn node_text_lines(scale : Double, high : Double) -> Int {
  let n = (@sf.dmin(text_most, high * text_window_share) / node_field_line(scale)).to_int()
  if n < 1 {
    1
  } else {
    n
  }
}

///|
/// Where a chat's composer made as nodes stands: as wide as the column it is in is laid out (`wide`), at the system's
/// size of words (`scale`), in a panel of its own where `apart` (its corners `pane`: what stands in them concentric
/// with them), else alone.
priv struct Stand {
  wide : () -> Double
  scale : () -> Double
  apart : () -> Bool
  pane : () -> FixedArray[@ui.CornerOf]?
}

///|
/// Where it stands at a panel's foot (composer_place's, a node's): in a panel of its own whose foot corners it reaches,
/// its capsule's ends each as far in as makes it concentric with the corner it is in; else as it stands alone.
fn Stand::place(self : Stand) -> ComposerPlace {
  guard (self.apart)() else { return composer_alone }
  let wide = (self.wide)()
  let extra = node_capsule_extra((self.scale)())
  @sf.with_pane((self.pane)(), fn() {
    let d = composer_side()
    if !@sf.in_pane() || composer_width(wide) < wide - 2.0 * d - 0.5 {
      composer_alone
    } else {
      let side = @sf.theme().round.side
      let h = @sf.foot_capsule_h(side + 2.0 * (capsule_pad_alone + extra), side)
      let (l, r, b) = @sf.foot_capsule(h, d, d)
      { capsule_in: (l - d, r - d, b - d), capsule_pad: (h - side) / 2.0 - extra, corner: @sf.pane_composer_corner() }
    }
  })
}

///|
/// `f` worked out as where it stands has it: in its panel (pane_round), its box's corner its place's (composer_round),
/// what stands in its corners following them (composer_inner, composer_round_in).
fn[T] Stand::at(self : Stand, f : () -> T) -> T {
  let corner = self.place().corner
  @sf.with_pane((self.pane)(), fn() {
    let was = @sf.composer_round.val
    @sf.composer_round.val = corner
    let out = f()
    @sf.composer_round.val = was
    out
  })
}

///|
/// Chat `r`'s composer made as nodes in `v` (its messages' list's foot: chat_page_made's `foot_node`), as `src` reads
/// its chat: its head alone (chat_view_now). Its tips in `tips`; `apart`, the page a panel of its own (the tape's: the
/// composer as far from its foot as from its sides, concentric with its corners `pane`); `laid`, the width its column
/// is laid out at on the page's way to another (a side panel sliding beside it: the narrower end), none at rest: how
/// far it stands from its foot is as at that end all the way, as the old composer's (composer_foot_in). Switched to as its page comes
/// to show (`shows`) from another chat's, the cursor in it with keyboard and mouse (its keyboard at hand), not taken
/// from a field in use; asked for (composer_take_focus), with touch too.
pub fn chat_composer_node(
  v : @view.View,
  src : Source,
  r : ChatRef,
  shows~ : () -> Bool,
  tips~ : @sf.TipLayer,
  apart? : () -> Bool = fn() { false },
  pane? : () -> FixedArray[@ui.CornerOf]? = fn() { None },
  laid? : () -> Double? = fn() { None },
) -> Unit {
  let draft = r.station + ":" + r.session
  let w = @signals.untracked(fn() { writing(src, draft) })
  let head = fn() { @sfbase.chat_view_now(src, r) }
  let offline = fn() { head().map(fn(h) { h.offline }).unwrap_or(false) }
  // (what it says before send: each thread it is copied to, as its head says)
  let note = fn() {
    match head() {
      Some(h) => h.cc.filter(fn(o) { o.on }).map(fn(o) { (o.via, o.place) })
      None => []
    }
  }
  // switched to another chat (its page come to show from another's): the cursor in it with keyboard and mouse, before
  // it is first drawn; not taken from a field in use (the switcher's, a dialog's)
  v.reacts(shows, fn(on) {
    guard on else { return }
    let come = composing_node.shown != draft
    composing_node.shown = draft
    // (and the new chat it was, become it under the cursor where its composer had it: that cursor kept, the keyboard as
    // it was; sent from it without it (its send pressed alone), none, as the old composer's)
    let became = @signals.untracked(fn() { @sfbase.fresh.became.get() }) == Some(r) && @ui.field_has_focus()
    if composing.wanted || (come && became) || (come && !@sf.soft_keyboard() && !@ui.field_has_focus()) {
      // (as its page comes: opened at once, as what the page is as it comes, no way of its own)
      composing_node.quiet = true
      composing_node.quiet_n.set(composing_node.quiet_n.untracked() + 1)
      // (its field made by the room its foot is given, after this: taken as it is made, where it is not yet)
      composing_node.focus_waits = draft
      w.field.focus()
      composing_node.quiet = false
    }
  })
  // (asked for and taken: asked no more)
  v.reacts(fn() { w.field.focused() }, fn(on) {
    if on {
      composing.wanted = false
    }
  })
  // (what comes into its draft from outside its field, taken as it is told)
  take_in_node(v, src, r, w, offline)
  // (its send asking the viewer where what it refers to must be shared (sfbase's outside.mbt): put up as it opens,
  // taken down as it is decided, as the asking says, whenever that changes)
  v.reacts(fn() { @sfbase.outside_asking(w.key).map(fn(s) { s.open.get() }) }, fn(_) { outside_shown(src, w.key) })
  // (by the width the column gives it, as it changes: never one worked out of the shell's state)
  v.by_room(fn(foot, room) {
    let stand : Stand = { wide: fn() { room.width() }, scale: fn() { foot.words_scale() }, apart, pane }
    // (how far what stands in its foot is drawn off where it is laid out, as its foot's room goes its way: below)
    let foot_shift = @motion.NodeWay::new(0.0)
    // (the width its foot's room is worked out at: as wide as the chat's column is laid out, as its rows are, on the
    // page's way to another width (sfbase's column_laid), else the narrower end its page says, else its own)
    let chat = r.station + "\u{1}" + r.session
    let rest_wide = fn() {
      let column = @sfbase.column_laid(chat, foot).laid
      if column > 0.0 {
        column
      } else {
        match laid() {
          Some(w) => w
          None => room.width()
        }
      }
    }
    // (12 over it, its foot's room under it: composer_foot_in's at rest; never less tall than it takes opened with one
    // line, so that opening or letting it go moves none of the messages: composer_open_room's, the old one's least)
    foot
    .padding(By(fn() { (0.0, 12.0, 0.0, stand.at(fn() { composer_foot_at(rest_wide()) })) }))
    .min_height(By(fn() { Some(stand.at(fn() { node_open_room(stand, rest_wide()) })) }))
    .lies_along(Is(End))
    .lines_up(Is(Some(Middle)))
    |> ignore
    // (its room under it come to another height as the page sets off on its way to another width (a side panel opened
    // or shut beside it: sfbase's column_sets_off): its height on the page's way from that moment (a Move, said there,
    // before the change is laid out, as each row's room over it is: message_row_node), what stands in it drawn from where
    // it stood on the same way, never stepped in the frame it sets off nor going on its own after the rows rest, never a
    // spring; none where its height comes out the same (View::resizes drops it))
    let set_off_at = Ref(@double.neg_infinity)
    @sfbase.column_set_off_each(foot, fn() {
      if foot.alive() {
        set_off_at.val = foot.cause_at()
        if foot.was_placed() {
          // (a Move by how far, as the rows' rooms go and as what stands in it is drawn: `foot_shift`, below)
          foot.resizes(foot=true) |> ignore
        }
      }
    })
    let foot_was = Ref(@signals.untracked(fn() { stand.at(fn() { composer_foot_at(rest_wide()) }) }))
    foot.reacts(fn() { stand.at(fn() { composer_foot_at(rest_wide()) }) }, fn(now) {
      let at = foot.cause_at()
      if at == set_off_at.val && foot.was_placed() && now != foot_was.val {
        let by = foot_shift.value_at(at) + now - foot_was.val
        foot_shift.put(by)
        foot_shift.go(foot, 0.0, @motion.moved())
      }
      foot_was.val = now
    })
    // (how far its ground's top is drawn off where it is laid out as its shape goes: what is said over it with it)
    // (its box's, said as it is made, after what is over it: read as said, `drawn_top_said`)
    let drawn_top : Ref[(@view.View) -> Double] = Ref(fn(_) { 0.0 })
    let drawn_top_said = @signals.signal(0)
    composer_notices_node(foot, src, r, tips, stand, fn(v) {
      drawn_top_said.get() |> ignore
      (drawn_top.val)(v) + foot_shift.shown(v)
    })
    // (the new chat it was, become it on 宽排法: its composer flies in from where the new chat's stood (sfbase's
    // fresh_composer_at, taken once), as the words sent from it do)
    let from_at = if @signals.untracked(fn() { @sfbase.fresh.became.get() }) == Some(r) &&
      @signals.untracked(fn() { room.width() }) >= @sf.page_narrow_most {
      let was = @signals.untracked(fn() { @sfbase.fresh_composer_at.get() })
      @sfbase.fresh_composer_at.set(None)
      was
    } else {
      None
    }
    composer_box_node(
      foot,
      src,
      r,
      w,
      tips,
      head,
      note,
      offline,
      stand,
      foot_shift,
      fn(f) {
        drawn_top.val = f
        drawn_top_said.set(drawn_top_said.untracked() + 1)
      },
      fn() { stand.at(fn() { composer_width(room.width()) }) },
      from_at~,
    )
    // (what went wrong, under it)
    foot.show(at_once=true, fn() { w.error.get() != "" }, fn(e) {
      @sf.style_node(e, fn() { error_box })
      @sf.words_node(e, fn() { w.error.get() }, fn() { composer_error_words }) |> ignore
    })
  })
  |> ignore
}

///|
/// What a composer's box made as nodes is for: a chat's (`chat`: its `@` menu, 抄送, its agent warmed as it is typed,
/// ↑ ↓ to the chat beside it with nothing typed, what is said over it, its words sent into the chat, its foot kept as
/// it grows), or what is written for something else in it (待派发's new task): opened however little it holds
/// (`roomy`), what its field says while empty (`placeholder`, the chat's where none), whether ＋ stands in its foot
/// (`attach`: what is pasted or dropped in is taken either way), what stands in its foot's row between ＋ and send
/// (`tools`: where it goes), how much room its words leave at their end, clear of what stands over
/// its top corner (`words_end`), what send is called and shows (`sends`, `send_icon`), and what it does with what is
/// written once it is ready (`send`: composer_submit's; a chat's sends it into the chat).
priv struct BoxSpec {
  chat : Bool
  roomy : Bool
  placeholder : String
  attach : Bool
  tools : ((@view.View) -> Unit)?
  words_end : Double
  sends : () -> String
  send_icon : () -> String
  send : ((Writing) -> Unit)?
}

///|
/// A chat's composer's box (chat_composer_node's).
fn chat_box_spec() -> BoxSpec {
  {
    chat: true,
    roomy: false,
    placeholder: "",
    attach: true,
    tools: None,
    words_end: 0.0,
    sends: fn() { @sf.t("web-main.composer.send") },
    send_icon: fn() { "arrow-up" },
    send: None,
  }
}

///|
/// A composer's box made as nodes in `v` for draft `draft` on `station`, no chat's (`spec`: 待派发's new task): as wide as
/// it is given, alone (no panel's foot), what is given its draft from outside taken in (take_in_node), its tips in
/// `tips`.
fn composer_alone_node(v : @view.View, src : Source, station : String, draft : String, spec : BoxSpec, tips : @sf.TipLayer) -> Unit {
  let r : ChatRef = { station, session: "", title: "", station_name: "" }
  let w = @signals.untracked(fn() { writing(src, draft) })
  take_in_node(v, src, r, w, fn() { false })
  v.by_room(fn(foot, room) {
    let stand : Stand = {
      wide: fn() { room.width() },
      scale: fn() { foot.words_scale() },
      apart: fn() { false },
      pane: fn() { None },
    }
    composer_box_node(
      foot,
      src,
      r,
      w,
      tips,
      fn() { None },
      fn() { [] },
      fn() { false },
      stand,
      @motion.NodeWay::new(0.0),
      fn(_) {  },
      fn() { room.width() },
      spec~,
    )
  })
  |> ignore
}

///|
/// The composer's box in `foot`, `width()` wide: its capsule or its box, its field, ＋, what it says before send, send;
/// a chat's, or as `spec` says.
fn composer_box_node(
  foot : @view.View,
  src : Source,
  r : ChatRef,
  w : Writing,
  tips : @sf.TipLayer,
  head : () -> ChatView?,
  note : () -> Array[(String, String)],
  no_files : () -> Bool,
  stand : Stand,
  foot_shift : @motion.NodeWay,
  drawn_top : ((@view.View) -> Double) -> Unit,
  width : () -> Double,
  spec? : BoxSpec = chat_box_spec(),
  from_at? : (Double, Double, Double, Double)? = None,
) -> Unit {
  let draft = w.key
  let focused = fn() { w.field.focused() }
  // (a box while it has the cursor; lost, a capsule a moment later, let_go_ms: kept so by the cursor's leaving)
  let held = fn() { composing_node.held.get(draft).unwrap_or(false) }
  let multiline = fn() {
    spec.roomy || focused() || held() || w.text.get() != "" || w.files.get().length() > 0 || w.quotes.get().length() > 0
  }
  let ready = fn() {
    (w.ready.get() || (w.field.text().trim() != "" && !w.starting.get()))
  }
  let scale = stand.scale
  // (send pressed, or Enter: a chat's into its chat, else as `spec` says, once ready)
  let submit = fn() {
    match spec.send {
      Some(send) => composer_submit(src, w, r.station, locked=false, send) |> ignore
      None => composer_node_submit(src, r, w, head, ready)
    }
  }
  // (and the room under the list's last row with its ground, from the same cause, the same way: its foot's height, kept
  // to its foot, the composer growing from it: View::resizes)
  // (its height and the foot's room going their way for what changes them, said in the change of each cause: the
  // cursor come or let go, a line typed or taken out, a file or a quote put in by a hand here (View::resizes); what an
  // answer of the core's puts in is there at once, as an answer is)
  let made : Ref[@view.View?] = Ref(None)
  // (how far it is a box (1) or a capsule (0), on the way its height goes as it opens or is let go)
  let shape = @motion.NodeWay::new(if @signals.untracked(multiline) { 1.0 } else { 0.0 })
  // (how far it is drawn as a box (1) or a capsule (0) where it is opened from a capsule with nothing in it or let go to
  // one, a box of one line: laid out at once, its foot's least (node_open_room) keeping what is round it where it
  // stood, its ground, its words, ＋ and send drawn from where they stood in the shape it had, on the old one's clock
  // (composer_shape_ms), never a resize; at its end, as laid out)
  let morph = @motion.NodeWay::new(@signals.untracked(fn() { shape.target() }))
  // (where its parts stand `k` of the way from its capsule (0) to its box of one line (1), from the left and the foot
  // of the box it is laid in opened: its capsule as far in as its place's capsule_in, its parts as far in as its
  // padding and theirs, as laid out below)
  let side = fn() { @sf.theme().round.side }
  let one_line = fn() { @sf.dmax(side(), node_field_line(scale())) }
  let shut_in = fn() { stand.place().capsule_in }
  let shut_pad = fn() { stand.place().capsule_pad + node_capsule_extra(scale()) }
  let open_in = fn() { stand.at(fn() { @sf.composer_round_in() }) }
  let between = fn(shut : Double, opened : Double, k : Double) { shut + (opened - shut) * k }
  // (drawn off where it is laid out: by where a part stands at `k` from where it stands at the way's end, across and
  // down)
  let drawn_off = fn(v : @view.View, left : (Double) -> Double, foot : (Double) -> Double) -> (Double, Double) {
    let k = morph.shown(v)
    let to = morph.target()
    if k == to {
      (0.0, 0.0)
    } else {
      (left(k) - left(to), foot(to) - foot(k))
    }
  }
  // (how far what it says while empty shows: composer_field_node's)
  // (and while a layer over the page keeps its cursor for it, parked: its own again as that layer goes)
  // (and flying in from the new chat it was (`from_at`): away till it has landed, then back as at rest)
  let hint_in = @motion.NodeWay::new(
    if from_at is Some(_) || @signals.untracked(fn() { focused() || w.field.parked() || held() }) {
      0.0
    } else {
      1.0
    },
  )
  // (its hint's way back said by that flight: not set off again as it is first made)
  let fresh_fly = Ref(from_at is Some(_))
  // (how much taller than it is laid out its ground is drawn, over it: what it was as words were sent from it, held as
  // long as the old composer's on this page is (sfbase's sent_out_hold_ms), then down to none on their flight's curve)
  let sent_over = @motion.NodeWay::new(0.0)
  // (the moment it goes down from as tall as it was, once the way it was going on as words left it is over: -1 when
  // it is said to go down as they are sent)
  let sent_down_at = Ref(-1.0)
  // (words sent from it: its field's hint and caret away till they are half way up and out of it, as the old flight's
  // (sfbase's flight_hint_away, sent_out_away_ms): while a way of that length goes, said as they are sent)
  let away_way = @motion.NodeWay::new(0.0)
  let away = fn() { away_way.goes(foot) }
  // (said once a moment, whatever said it first: what changes it again at the same moment, another cause of that
  // moment, goes on the one way said then, never set out again over it)
  let reshaped_at = Ref(-1.0)
  let resize = fn(way : (Double, (Double) -> Double)?) {
    // (none before it is first drawn: what it is as its page comes in is there at once)
    guard foot.was_placed() && !composing_node.quiet else { return }
    guard foot.cause_at() != reshaped_at.val else { return }
    reshaped_at.val = foot.cause_at()
    // (a chat's kept to its foot as it grows; elsewhere to its top, as a card is)
    match made.val {
      Some(b) => b.resizes(foot=spec.chat, spec?=way) |> ignore
      None => foot.resizes(foot=spec.chat, spec?=way) |> ignore
    }
  }
  // (a line more or fewer, what waits to go put in or taken out: a Move by how far)
  let reshape = fn() { resize(None) }
  // (opened from a capsule with nothing in it, or let go to one: its foot's height on its shape's way, kept to its foot,
  // said in the change of that cause (the cursor come, its moment let go after it left), the box laid out at once and
  // drawn from the shape it had (`morph`). Nothing where its least (node_open_room) holds it as tall both ways; where
  // something over it (what is said over it, what went wrong) has it taller than that least, the room it grows or
  // shrinks by goes its way, the messages over it going with it as one, never at once)
  let shape_way = fn() {
    guard foot.was_placed() && !composing_node.quiet else { return }
    guard foot.cause_at() != reshaped_at.val else { return }
    // (taller than its least, opened or not, only with something over it (what is said over it) or under it (what went
    // wrong): its shape moves it then)
    guard spec.chat &&
      @signals.untracked(fn() { w.error.get() != "" || composer_notice_kinds(src, r).length() > 0 }) else {
      return
    }
    reshaped_at.val = foot.cause_at()
    foot.resizes(foot=true, spec=(composer_shape_ms, fn(p) { @ui.Ease::Move.at(p) })) |> ignore
  }
  // (what waits to go put in or taken out from outside its hand here (the system's picker answering, a file shared
  // into the app or quoted from a message, a 文件 row put in, what the core gives back): its height its way too, from
  // the change that brought it, as the old composer's foot gave its list its room)
  // (taken out too, as the core answers what a hand here asked (its ✕): from that answer's moment; not what goes as
  // it is sent, which leaves at once, its ground held as it was: sent_from_node, `sent_at`)
  let sent_at = Ref(-1.0)
  // (how far its words are drawn under where they are laid out as a line more of them makes its way in (`regrow`):
  // where they stood, by its top, down to where they stand; how far that line is from all of it shown)
  let grow = @motion.NodeWay::new(0.0)
  let grew = Ref(0.0)
  // (a line more or fewer, `by` how far: its height its way as any other (resize), its words kept to its top on that way
  // as the old one's field grew, the line it grows by coming out at its words' foot, fading to it pixel by pixel, what
  // showed before untouched (the owner, 2026-10-30: 「带渐隐，但不是整行渐隐」), at the same rate)
  let regrow = fn(by : Double) {
    guard foot.was_placed() && !composing_node.quiet else { return }
    let ms = @ui.row_size_ms
    let left = grow.value_at(foot.cause_at())
    resize(Some((ms, fn(p) { @ui.Ease::Move.at(p) })))
    grew.val = left + by
    grow.put(left + by)
    grow.go_ms(foot, 0.0, ms, ease=Move)
  }
  foot.reacts(fn() { w.files.get().length() + w.quotes.get().length() }, fn(_) {
    if foot.cause_at() != sent_at.val {
      reshape()
    }
  })
  foot.box(fn(box) {
    box.width(By(fn() { Some(width()) })) |> ignore
    // (drawn off where it is laid out as its foot's room goes its way on the page's: chat_composer_node's foot_shift)
    box.offset(By(fn() { (0.0, foot_shift.shown(box)) })) |> ignore
    made.val = Some(box)
    // (a chat's alone: what flies from it and what is set beside it find it)
    if spec.chat {
      composer_nodes[draft] = (box, foot, sent_over, foot_shift)
    }
    // (from where the new chat's composer stood, on the flight of what is sent from it, its foot kept to its foot; its
    // hint back once it has landed, as at rest without the cursor)
    match from_at {
      Some((fx, fy, fw, fh)) => {
        let start_at = box.cause_at()
        box.flies_in(
          sent_part_flight,
          fn(to) {
            let from = (fx, fy + fh - to.3, fw, to.3)
            let (dur, _) = (sent_part_flight.way)(sent_far(from, to))
            let ms = @sf.dmax(1.0, dur)
            let holds = fn() { w.text.get() != "" || w.files.get().length() > 0 || w.quotes.get().length() > 0 }
            if !@signals.untracked(fn() { focused() || w.field.parked() || (held() && !holds()) }) {
              hint_in.put_at(
                foot,
                0.0,
                1.0,
                @motion.tween(@sf.hint_back_ms, ease=Out, delay=@sf.dmax(ms, @sfbase.flight_most_ms)),
                start_at,
              )
            }
            Some(from)
          },
          up_late=sent_up_late,
          far_of=sent_far,
        )
        |> ignore
      }
      None => ()
    }
    // (as tall as it was as words left it while it was going: once that way has slowed to rest, down on the flight's
    // curve from the moment what flies from it begins its rise (sent_out_hold_ms after), or from then if that is past,
    // to come to none as it would have)
    box.reacts(fn() { sent_over.goes(box) }, fn(going) {
      let start = sent_down_at.val
      if !going && start >= 0.0 {
        sent_down_at.val = -1.0
        let now = box.cause_at()
        let hold = @sfbase.sent_out_hold_ms
        let end = start - hold + @ui.move_most_ms
        let from = if start > now { start } else { now }
        if end > from {
          sent_over.go(box, 0.0, @motion.tween(end - from, ease=Flight, delay=from - now))
        } else {
          sent_over.put(0.0)
        }
      }
    })
    let sent_hold = fn() {
      // (its hint and caret away from this moment till the words sent are half way out of it, then its hint back as at
      // rest without the cursor)
      let at = box.cause_at()
      sent_at.val = at
      // (words or quotes going: files alone leave it where it is, as the old flight's, flight_hint_away)
      let words_go = @signals.untracked(fn() {
        w.text.get().trim(chars=" \n\t") != "" || w.quotes.get().length() > 0
      })
      if words_go {
        @sfbase.sent_out_told(draft, at)
        away_way.go_from(foot, 0.0, 1.0, @motion.tween(@sfbase.sent_out_away_ms(), ease=Linear))
      }
      // (as tall as it is at this moment, all it held still in it, and as fast as its height went on a way then (View::
      // height_going_now: nothing laid out for it, a layout here laying its list out with the row sent and not the
      // composer emptied); to its one line's box, as it is laid out once emptied)
      let (was, speed) = box.height_going_now()
      let wide = (stand.wide)()
      let one = stand.at(fn() { node_open_room(stand, wide) - 12.0 - composer_foot_at(wide) })
      if was > one || speed != 0.0 {
        // (its foot down at once, words sent from it: what stands beside the list by that foot (对话目录's rail) told
        // how far, and from when, as the old one's tells it: sfbase's chat_foot_dropped)
        if was > one && words_go {
          @sfbase.chat_foot_dropped.set(Some((draft, at, was - one)))
        }
        let hold = @sfbase.sent_out_hold_ms
        sent_over.put(was - one)
        if speed != 0.0 {
          // (on a way as it was sent: slowing to rest from as fast as it went, as the old one's (@motion.stop_for), not
          // stopped dead; down from there once that way is over: `sent_down_at`)
          sent_down_at.val = at + hold
          sent_over.go(box, was - one, @sf.move_spring, velocity=speed * 1000.0)
        } else {
          // (held so till what flies from it begins its rise, then down on their flight's curve)
          sent_down_at.val = -1.0
          sent_over.go(box, 0.0, @motion.tween(@ui.move_most_ms - hold, ease=Flight, delay=hold))
        }
      }
    }
    if spec.chat {
      composer_sent_holds[draft] = sent_hold
    }
    // (its ground as drawn now off where it is laid out, as node `v` draws it: from its capsule to its box of one line
    // or back (`morph`), or as tall as it was as words left it (`sent_over`); what stands over it going with its top:
    // chat_composer_node's `drawn_top`)
    let ground_now = fn(v : @view.View) -> @view.GroundShape {
      let over = sent_over.shown(v)
      let k = morph.shown(v)
      let to = morph.target()
      if k != to {
        // (from its capsule to its box of one line, or back: its sides, its foot and its height between the two)
        let (l, r, b) = shut_in()
        let shut_h = one_line() + 2.0 * stand.place().capsule_pad
        let open_h = stand.at(fn() { node_open_room(stand, (stand.wide)()) - 12.0 - composer_foot_at((stand.wide)()) })
        let left = fn(k : Double) { between(l, 0.0, k) }
        let right = fn(k : Double) { between(r, 0.0, k) }
        let low = fn(k : Double) { between(b, 0.0, k) }
        let high = fn(k : Double) { between(shut_h, open_h, k) }
        {
          dx: left(k) - left(to),
          dy: low(to) + high(to) - low(k) - high(k),
          dw: left(to) + right(to) - left(k) - right(k),
          dh: high(k) - high(to),
          corners: None,
        }
      } else if over > 0.0 {
        { dx: 0.0, dy: -over, dw: 0.0, dh: over, corners: None }
      } else {
        @view.ground_as_laid
      }
    }
    drawn_top(fn(v) { ground_now(v).dy })
    box.ground_drawn(By(fn() { ground_now(box) }))
    |> ignore
    box.owns(fn() {
      match composer_nodes.get(draft) {
        Some((b, _, _, _)) if b.id() == box.id() => {
        composer_nodes.remove(draft)
        composer_sent_holds.remove(draft)
      }
        _ => ()
      }
    })
    |> ignore
    // words dragged in from another app and let go on it beside its field (its ＋, send, its edge: on the field they
    // go where they were let go): into its field at its caret, as a paste's; files from this machine's Finder let go on
    // it (or on its field) where it is a station of the chat's workspace: by its station and path, named so or sent as
    // files as the chat takes what is dragged in (the old composer's cap: c.paths_into, c.words_into); elsewhere (or
    // where the host says no paths, as Windows' does) read and put in as files picked are (c.files_into); either way
    // given to the draft, whose taker says where it takes no files (take_in_node)
    @ui.paths_into(
      box,
      w.field,
      fn(paths) {
        for d in @sfbase.finder_dragged(src, paths) {
          @sfbase.files_into(w.key, d)
        }
      },
      takes=fn() { @sfbase.finder_by_station_in(@sfbase.workspace_of(r.station)) },
    )
    |> @ui.files_into(w.field, fn(files) { @sfbase.picked_files_into(w.key, files) })
    |> @ui.words_into(w.field)
    |> ignore
    // (its ground the floating glass, the accent's over it while a file is dragged over: a 文件 tab's row, files from
    // the computer the page takes)
    box
    .glass(
      By(fn() {
        let dragging = !no_files() && (@sfbase.drag_carried.val)() is Some(_) && @sf.lit_node(box)
        Some(@sf.glass_floating(tint?=if dragging { Some(@sf.alpha(@sf.theme().p.accent, drag_tint)) } else { None }))
      }),
    )
    // (round as a capsule is, or as its box's corner; from one to the other as its height goes its way: drawn, as a
    // control answering, never laid out again for it)
    .radius(
      By(fn() {
        let pill = (@sf.theme().round.side + 2.0 * (stand.place().capsule_pad + node_capsule_extra(scale()))) / 2.0
        let k = stand.place().corner
        let p = shape.shown(box)
        pill + (k - pill) * p
      }),
    )
    // (a capsule further in than the box by its place's capsule_in, from its left, its right and its foot)
    .margin(
      By(fn() {
        if multiline() {
          (0.0, 0.0, 0.0, 0.0)
        } else {
          let (l, r, b) = stand.place().capsule_in
          (l, 0.0, r, b)
        }
      }),
    )
    .padding(
      By(fn() {
        if multiline() {
          let p = @sf.composer_pad
          (p, p, p, p)
        } else {
          let pad = stand.place().capsule_pad
          let extra = node_capsule_extra(scale())
          (pad + extra, pad, pad + extra, pad)
        }
      }),
    )
    // (the I-beam over it)
    .cursor(Is(Some(IBeam)))
    |> ignore
    // (what waits to go over its words: its quotes, its files)
    composer_extras_node(box, src, r, w, tips, stand)
    // (`@` and a few letters: the chats they find, over it: a chat's)
    if spec.chat {
      ref_menu_node(box, src, r, w)
    }
    // (its words, then what is said before send and send: one line as a capsule, ＋ laid over its start; opened, the
    // words the whole of the first line, the rest on a second, at its end)
    box.box(fn(line) {
      // (a press on its words' row beside its field is its field's, the cursor put in it; one on what waits to go over
      // it is that one's, as the old composer's cards took theirs, never the field's. Taken by what lies under the row,
      // not the row itself: what is drawn small on it (send) reached from round it as far as its press's room holds,
      // over the row's own, as the old composer's (reach.mbt's `cut` is only by what holds it))
      // (with what stands between ＋ and send (a station choice, as tall as a row's press room, past the row's foot):
      // the box's own, under all it holds, as nothing it holds overlaps it)
      if spec.tools is None {
        line.box(fn(under) {
          under.over(Is(true)).on_press(fn() { w.field.focus() }) |> ignore
        })
        |> ignore
      } else {
        box.on_press(fn() { w.field.focus() }) |> ignore
      }
      line
      .row(Is(true))
      // (its parts a point apart, as the capsule's are: composer_box's)
      .gap(Is(1.0))
      .lies_along(Is(End))
      .lines_up(Is(Some(Middle)))
      .wraps(By(fn() { if multiline() { Some(@ui.Space::px(S2_5)) } else { None } }))
      |> ignore
      line.box(fn(words) {
        words
        // (cut to what shows of it as a line more makes its way in, softly at that foot: `grow`)
        .clips(Is(true))
        .clips_past(By(fn() { -grow.shown(words) }))
        .fades(
          By(fn() {
            let left = grow.shown(words)
            (0.0, 0.0, 0.0, if left > 0.0 { @ui.cut_soft(grew.val - left, left) } else { 0.0 })
          }),
        )
        .grow(Is(1.0))
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        .width_share(By(fn() { if multiline() { 1.0 } else { 0.0 } }))
        // (a row, its field growing across it: on one line as high as the capsule's round buttons, its line in their
        // middle (text_shut); opened, as tall as its lines (text_open))
        .row(Is(true))
        .min_height(
          By(fn() {
            if multiline() {
              None
            } else {
              Some(@sf.dmax(@sf.theme().round.side, node_field_line(scale())))
            }
          }),
        )
        .lines_up(By(fn() { if multiline() { Some(Start) } else { Some(Middle) } }))
        .margin(
          By(fn() {
            if multiline() {
              (0.0, 0.0, 0.0, 0.0)
            } else {
              (@sf.theme().round.side + 1.0, 0.0, 0.0, 0.0)
            }
          }),
        )
        .padding(By(fn() { if multiline() { (8.0, 8.0, 8.0 + spec.words_end, 0.0) } else { (0.0, 0.0, 8.0, 0.0) } }))
        // (its field: on one line past ＋ in the capsule's middle, opened over the row of ＋ and send)
        .offset(
          By(fn() {
            let (x, y) = drawn_off(
              words,
              fn(k) { between(shut_in().0 + shut_pad() + side() + 1.0, @sf.composer_pad + 8.0, k) },
              fn(k) {
                between(
                  shut_in().2 + stand.place().capsule_pad + (one_line() - node_field_line(scale())) / 2.0,
                  open_in() + side() + 10.0,
                  k,
                )
              },
            )
            (x, y + grow.shown(words))
          }),
        )
        |> ignore
        composer_field_node(words, src, r, w, scale, fn() { hint_in.shown(words) }, away, spec, submit, fn(on) {
          if on {
            // (from a capsule: opened as the cursor comes in, a box of one line, drawn from the capsule: `morph`)
            // (a capsule till now: kept by nothing, holding nothing)
            let shut = @signals.untracked(fn() {
              !held() && w.text.get() == "" && w.files.get().length() == 0 && w.quotes.get().length() == 0
            })
            if shut {
              shape_way()
            }
            composing_node.held.set(draft, true)
          }
        }, regrow)
      })
      |> ignore
      line.box(fn(tail) {
        tail
        .row(Is(true))
        .gap(Is(@ui.Space::px(S1)))
        .lines_up(Is(Some(Middle)))
        .shrink(Is(0.0))
        // (send at its end: in the capsule's end, opened in its foot corner)
        .offset(
          By(fn() {
            drawn_off(tail, fn(k) { -between(shut_in().1 + shut_pad(), open_in(), k) }, fn(k) {
              between(shut_in().2 + stand.place().capsule_pad + (one_line() - side()) / 2.0, open_in(), k)
            })
          }),
        )
        // (opened, its send round in the box's foot corner, concentric with it: composer_round_in)
        .margin(
          By(fn() {
            if multiline() {
              let d = stand.at(fn() { @sf.composer_round_in() }) - @sf.composer_pad
              (0.0, 0.0, d, d)
            } else {
              (0.0, 0.0, 0.0, 0.0)
            }
          }),
        )
        |> ignore
        // (抄送 once opened, in a chat its agents' threads are copied from)
        // (抄送 and where it is copied, made only in a chat copied elsewhere)
        tail.show(fn() { (multiline() && cc_shown(head())) || note().length() > 0 }, fn(cc) {
          cc.row(Is(true)).gap(Is(@ui.Space::px(S1))).lines_up(Is(Some(Middle))) |> ignore
          cc.show(fn() { multiline() && cc_shown(head()) }, fn(t) { cc_chooser_node(t, src, r, head, tips) })
          cc.show(fn() { note().length() > 0 }, fn(n) {
          @sf.style_node(n, fn() { cc_note_box })
          n.each(note, fn(o) { o.0 + "\u{1}" + o.1 }, fn(p, o) {
            let (via, place) = @signals.untracked(fn() { o.get() })
            @sf.style_node(p, fn() { cc_place })
            cc_mark_node(p, via)
            @sf.words_node(p, fn() { place }, fn() { cc_words }) |> ignore
          })
        })
        })
        // (what it says of where it goes, where it says so: from ＋'s end, as far as send leaves, as tall as ＋ and send,
        // what it holds centred on theirs whatever its own press room: a station choice is as tall as a row, ＋ and send
        // are round)
        match spec.tools {
          Some(tools) => {
            tail.grow(Is(1.0)) |> ignore
            tail.box(fn(gap) {
              gap
              .grow(Is(1.0))
              .shrink(Is(1.0))
              .min_width(Is(Some(0.0)))
              .row(Is(true))
              .lines_up(Is(Some(Middle)))
              .height(By(fn() { Some(side()) }))
              .padding(By(fn() { (open_in() - @sf.composer_pad + side() + 6.0, 0.0, 6.0, 0.0) }))
              |> ignore
              tools(gap)
            })
            |> ignore
          }
          None => ()
        }
        // (send: the library's, its arrow alone, a chat's own draft never making a chat as a new chat's does)
        @sf.send_button_node(tail, spec.sends, ready, fn() { false }, submit, tips~, icon_now=spec.send_icon)
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // (＋ over its foot's start, in either shape: in its capsule's start; opened, in its box's foot corner, concentric
    // with it)
    // (laid over the box from its foot's start, no box of its own round it: as far in as the capsule's round end
    // leaves it, or concentric with the box's foot corner)
    if spec.attach {
    attach_node(box, src, w, tips, no_files, place=fn(b) {
      b
      .over(Is(true), edges=(Some(0.0), None, None, Some(0.0)))
      // (in the capsule's start, opened in its foot corner)
      .offset(
        By(fn() {
          drawn_off(b, fn(k) { between(shut_in().0 + shut_pad(), open_in(), k) }, fn(k) {
            between(shut_in().2 + stand.place().capsule_pad, open_in(), k)
          })
        }),
      )
      .margin(
        By(fn() {
          if multiline() {
            let d = stand.at(fn() { @sf.composer_round_in() })
            (d, 0.0, 0.0, d)
          } else {
            let pad = stand.place().capsule_pad
            (pad + node_capsule_extra(scale()), 0.0, 0.0, pad)
          }
        }),
      )
      |> ignore
    })
    }
  })
  |> ignore
  // (its corners going from a capsule's to its box's as it opens, and back as it is let go, as far as its height
  // goes then: a Move over the height between them)
  let quiet_was = Ref(@signals.untracked(fn() { composing_node.quiet_n.get() }))
  let first = Ref(true)
  // (whether anything is in it: what is written, what waits to go)
  let held_in = fn() { w.text.get() != "" || w.files.get().length() > 0 || w.quotes.get().length() > 0 }
  let held_in_was = Ref(@signals.untracked(held_in))
  foot.reacts(fn() { (multiline(), composing_node.quiet_n.get(), held_in()) }, fn(now) {
    let (on, quiet, full) = now
    let had = held_in_was.val
    held_in_was.val = full
    let to = if on { 1.0 } else { 0.0 }
    // (opened as its page came, the cursor put in it then: there at once)
    if first.val || quiet != quiet_was.val || !foot.was_placed() {
      first.val = false
      quiet_was.val = quiet
      shape.put(to)
      morph.put(to)
    } else if to != shape.target() {
      // det-ok(motion-length): the field opening past ＋ and send kept off them on this clock, as the old one's
      shape.go_ms(foot, to, composer_shape_ms, ease=Move)
      // (opened from a capsule or let go to one with nothing in it before or after, the cursor come or gone: a box of
      // one line, in its foot's least, drawn there; with something put in or taken out, its height its way, laid out)
      if !full && !had {
        // det-ok(motion-length): the field opening past ＋ and send kept off them on this clock, as the old one's
        morph.go_ms(foot, to, composer_shape_ms, ease=Move)
      } else {
        morph.put(to)
      }
    }
  })
  // (what it says while empty only on it at rest without the cursor, so it never moves with its shape (composer_hint's):
  // gone at once as the cursor comes in or the box is kept, or as it goes from a box to a capsule or back (a quote or a
  // file taken out, the last of them); back over hint_back_ms once it is at rest without the cursor and its shape's way
  // there is over)
  let hint_shape = Ref(@signals.untracked(multiline))
  let away_was = Ref(false)
  // (kept a box a moment after the cursor left it: hidden then only where it holds nothing, to be let go to a capsule;
  // holding something (a quote, a file), it stays a box, at rest, the hint on it as the old one's, the cursor in a
  // quote's line or nowhere)
  foot.reacts(fn() { (focused() || w.field.parked() || (held() && !held_in()), multiline(), away()) }, fn(now) {
    let (hidden, shaped, gone) = now
    let reshaped = shaped != hint_shape.val
    hint_shape.val = shaped
    let back = away_was.val && !gone
    away_was.val = gone
    // (flying in from the new chat it was: its hint's way back is that flight's)
    if fresh_fly.val {
      fresh_fly.val = false
      if !hidden && !reshaped && !gone {
        return
      }
    }
    if hidden || reshaped || gone {
      hint_in.put(0.0)
    }
    if !hidden && !gone {
      if back {
        // (what was sent half way out of it: back as at rest, from this moment)
        hint_in.go_ms(foot, 1.0, @sf.hint_back_ms)
      } else {
        // (once its shape's way there is over: composer_shape_ms, composer_hint's `going`)
        hint_in.go(foot, 1.0, @motion.tween(@sf.hint_back_ms, ease=Out, delay=composer_shape_ms))
      }
    }
  })
  // (the cursor gone: a box a moment more, then a capsule; back in it before then, still a box)
  foot.reacts(focused, fn(now) {
    if now {
      if !@signals.untracked(held) {
        composing_node.held.set(draft, true)
      }
    } else {
      foot.at_moment(foot.cause_at() + let_go_ms, fn() {
        if !w.field.focused() && !w.field.parked() {
          // (let go to a capsule now, drawn from its box of one line: `morph`)
          if !@signals.untracked(held_in) {
            shape_way()
          }
          composing_node.held.set(draft, false)
        }
      })
      |> ignore
    }
  })
}

///|
/// What is said over chat `r`'s composer made as nodes, a notice each, in their order (composer_notices_node's): it
/// archived, its agent's prompt cache over, its station down, a report of the person's answered.
fn composer_notice_kinds(src : Source, r : ChatRef) -> Array[String] {
  let h = @sfbase.chat_view_now(src, r)
  let ks : Array[String] = []
  if h.map(fn(h) { h.archived }).unwrap_or(false) {
    ks.push("archive")
  }
  if h.map(fn(h) { h.cache_cold is Some(_) && !h.archived }).unwrap_or(false) {
    ks.push("wait")
  }
  if h.map(fn(h) { h.offline }).unwrap_or(false) {
    ks.push("unplug")
  }
  if feedback_reports(src, r).iter().any(fn(f) { !report_dismissed(f) }) {
    ks.push("said")
  }
  ks
}

///|
/// The room a chat's composer made as nodes takes opened with one line at the foot of a column `wide` (composer_open_room's,
/// a node's): its box (its padding, 8 over its field's one line, 10 to its row, its round buttons as far from its foot as
/// makes them concentric with its corner), 12 over it and its foot's room under it.
fn node_open_room(stand : Stand, wide : Double) -> Double {
  let t = @sf.theme()
  let corner = stand.place().corner
  @sf.composer_pad + (8.0 + node_field_line((stand.scale)())) + 10.0 + t.round.side + @ui.capsule_in(corner, t.round.side) +
  12.0 +
  composer_foot_at(wide)
}

///|
/// Whether chat `h`'s composer offers 抄送 (its agents' threads in Slack or Feishu: cc_chooser's).
fn cc_shown(h : ChatView?) -> Bool {
  match h {
    Some({ cc, thread: Some(_), .. }) => cc.length() > 0
    _ => false
  }
}

///|
/// The composer's field in `words` (composer_text's, a node's): the theme's words at the system's size, growing with
/// what is typed to text_lines', then scrolling; while empty what to write, or with keyboard and mouse and nothing
/// focused the key that brings the cursor back; typed, told to the core (its agent warmed once a minute); Enter sends
/// (⌘Enter where chosen), ⇧Enter a new line; with nothing typed ↑ / ↓ go to the chat above or below. What it says while
/// empty shows as far as `hint_in()` says.
fn composer_field_node(
  words : @view.View,
  src : Source,
  r : ChatRef,
  w : Writing,
  scale : () -> Double,
  hint_in : () -> Double,
  away : () -> Bool,
  spec : BoxSpec,
  submit : () -> Unit,
  focus_told : (Bool) -> Unit,
  regrow : (Double) -> Unit,
) -> Unit {
  let prefs = fn() { src.topic("prefs", {}).get().value }
  let by_command = fn() { @settings.sends_by_command(prefs()) }
  let hint = fn() {
    if spec.placeholder != "" {
      spec.placeholder
    } else if !@sf.soft_keyboard() && !w.field.focused() && !@ui.field_has_focus() {
      match @settings.key_label(prefs(), "composer.focus") {
        "" => @sf.t("web-main.composer.placeholder")
        key => @sf.t("web-main.composer.pressToTypeCjk", args=[("key", key)])
      }
    } else {
      @sf.t("web-main.composer.placeholder")
    }
  }
  let wl = @signals.untracked(fn() { @ui.style_words(@sf.theme().t.words) })
  let max_lines = @signals.untracked(fn() { node_text_lines(scale(), words.window().1) })
  // (whether the cursor is in it, as it was last told: what it had as it is let go, the focus let go with it then
  // unsaid)
  let had_focus = Ref(@signals.untracked(fn() { w.field.focused() }))
  let typed = @ui.field(
    words,
    w.field,
    placeholder_by=hint,
    font_size=wl.size,
    line=wl.line,
    trim=true,
    max_lines~,
    words=true,
    // (the core's bound, asked as it is made, followed as it answers: refs.mbt's paste_threshold_now)
    paste_limit_by=fn() { @sfbase.paste_threshold_now(src) },
    look=@sfbase.refs_look(w.key, @signals.untracked(fn() { @sf.theme().p.accent })),
    colors_by=fn() {
      let p = @sf.theme().p
      // (its caret away while what was sent from it leaves it: composer_box_node's `away`)
      (p.text, @sf.alpha(p.subtle, hint_in()), if away() { @sf.alpha(p.accent, 0.0) } else { p.accent })
    },
    edit=fn(e) { @sfbase.refs_edited(src, w.key, w.field, r.station, false, e) },
    edited=fn(now) {
      // (a line more or fewer: its height its way; the same lines, nothing said, so nothing coming in its column in
      // the same change is set off with it)
      match field_comes_other(w.field, wl, max_lines, @signals.untracked(fn() { w.text.get() }), now) {
        Some(by) => regrow(by)
        None => ()
      }
      if now != @signals.untracked(fn() { w.text.get() }) && !@signals.untracked(fn() { w.starting.get() }) {
        writing_text(src, w, now)
        if spec.chat {
          composer_warm(src, r, words.cause_at())
        }
      }
    },
    submitted=fn(now) {
      if !@signals.untracked(fn() { w.starting.get() }) {
        if now != @signals.untracked(fn() { w.text.get() }) {
          writing_text(src, w, now)
        }
        submit()
      }
    },
    pasted=fn(now) {
      @sfbase.writing_paste(src, w, r.station, now)
    },
    files=fn(files) {
      for f in files {
        writing_add(src, w, r.station, f.0, f.1)
      }
    },
  )
  // (as 快捷键's 发送 says now (prefs sendKey), followed: changed while it is made, the next Enter goes by it)
  @ui.field_sends_by(typed, fn() {
    let command = by_command()
    (@sf.enter_sends(command~), @sf.command_sends(command))
  })
  @ui.field_focus_told(typed, fn(on) {
    had_focus.val = on
    focus_told(on)
  })
  // (let go with the cursor in it (its page made anew: another node of the same draft's composer to come), the cursor
  // kept for the one that takes its place, as an old view's editor of the same draft keeps it)
  typed.owns(fn() {
    if had_focus.val {
      composing_node.focus_waits = w.key
    }
  })
  |> ignore
  // (the cursor given it as its page came, before it was made: taken now, as what the page is as it comes)
  if composing_node.focus_waits == w.key {
    composing_node.focus_waits = ""
    // (once what it is made in is held from the window's root, as the change that makes it is told)
    @signals.after_flush(fn() {
      if !w.field.focused() {
        composing_node.quiet = true
        w.field.focus()
        composing_node.quiet = false
      }
    })
  }
  typed.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
  // nothing typed in a chat's: ↑ ↓ the chat above or below, as the list shows them now, before the field sees it
  typed.on_key(fn(k) {
    guard spec.chat && k.mods == 0 && (k.code == @ui.key_code_up || k.code == @ui.key_code_down) else { return false }
    guard w.text.get() == "" && !(@sfbase.neighbour_held.val)() else { return false }
    match @sfbase.workspace_in_view(src).0 {
      Some(ws) => (@sfbase.neighbour_go.val)(src, ws, if k.code == @ui.key_code_up { -1 } else { 1 })
      None => ()
    }
    true
  })
  |> ignore
}

///|
/// Whether field `field` (composer_field_node's: words `wl`, `max_lines` at most) comes out another height with `now` in
/// it than with `was`, as wide as its words were laid out last: a line more or fewer. Not laid out yet, so.
fn field_comes_other(field : @ui.Field, wl : @view.WordsLook, max_lines : Int, was : String, now : String) -> Double? {
  guard field.lines() is Some(lines) else { return Some(0.0) }
  let wide = lines.room.2 / (if lines.scale > 0.0 { lines.scale } else { 1.0 })
  let laid = field.laid(font_size=wl.size, line=wl.line, max_lines~, trim=true)
  let (_, h0) = { ..laid, words: was }.size(Some(wide))
  let (_, h1) = { ..laid, words: now }.size(Some(wide))
  if (h1 - h0).abs() > 0.01 {
    Some(h1 - h0)
  } else {
    None
  }
}

///|
/// Typing warms chat `r`'s agent's runtime, so a cold start overlaps the writing: the first time, then a minute after
/// the last (warm's, at moment `at`).
fn composer_warm(src : Source, r : ChatRef, at : Double) -> Unit {
  guard @sfbase.chat_view_now(src, r) is Some(h) && !h.archived && !h.offline && !src.read_only else { return }
  let (n, last) = composing_node.warmed.get(r.session).unwrap_or((0, @double.neg_infinity))
  if n > 0 && at - last < warm_every_ms {
    return
  }
  composing_node.warmed[r.session] = (n + 1, at)
  (src.call)("session.warm", { "station": Json::string(r.station), "key": Json::string(r.session) }, @sfbase.answer_unread)
}

///|
/// Send pressed (or Enter) in draft `w`'s composer of chat `r` (`head`, its view as it is): the line of a quote it takes
/// that had the focus gives it to the words' field first, as Enter in that line does and as its ✕ does (not lost with the
/// line as its card sets out); then, once the press is told, its own change of the press's moment (as the old composer's
/// send was made by its build: what it puts in the chat's list comes in it as one sent, its row made from the field's
/// words as they flew), composer_submit's (composer_state.mbt): sent into the chat where it is ready (send_in_chat_node).
fn composer_node_submit(src : Source, r : ChatRef, w : Writing, head : () -> ChatView?, ready : () -> Bool) -> Unit {
  guard @signals.untracked(ready) else { return }
  let quote_had = @signals.untracked(fn() {
    w.quotes
    .get()
    .iter()
    .any(fn(q) { composing.comments.get(text(Some(q), "id")).map(fn(f) { f.focused() }).unwrap_or(false) })
  })
  if quote_had {
    w.field.focus()
  }
  @ui.after_frame(fn() {
    @signals.start_batch()
    composer_submit(src, w, r.station, locked=false, fn(w) {
      match @signals.untracked(head) {
        Some(v) => send_in_chat_node(src, r, v, w)
        None => ()
      }
    })
    |> ignore
    @signals.end_batch()
  })
}

///|
/// ＋ in `parent` (attach's, a node's): 32 round, the muted ink, the hover's ground and the text's ink under the
/// pointer, faint where no file is taken in; pressed, the system's file picker (on a touch system the sheet of what can
/// go in: attach.mbt); its tip with its keys (composer.file).
fn attach_node(
  parent : @view.View,
  src : Source,
  w : Writing,
  tips : @sf.TipLayer,
  no_files : () -> Bool,
  place? : (@view.View) -> Unit = fn(_) {  },
) -> Unit {
  @headless.button(
    parent,
    fn() { @sf.t("web-main.composer.attach") },
    fn(b) {
      if @sf.attach_from_sheet() {
        attach_open_node(b, src, w.key)
      } else {
        pick_files(w)
      }
    },
    disabled=no_files,
    fn(b, state) {
      let lit = fn() { !no_files() && (state.hovered() || state.pressed() || state.focus_shown()) }
      let side = @sf.theme().round.side
      place(b)
      b
      .width(Is(Some(side)))
      .height(Is(Some(side)))
      .radius(Is(side / 2.0))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .focus_ring_theme()
      |> ignore
      @sf.hover_ground_node(b, on=fn() { !no_files() })
      @sf.icon_node(
        b,
        "plus",
        plus_icon,
        By(fn() {
          let p = @sf.theme().p
          if no_files() {
            @sf.alpha(p.text, faint)
          } else if lit() {
            p.text
          } else {
            p.muted
          }
        }),
      )
      |> ignore
      @sf.tip_node(tips, b, fn() { if no_files() { "" } else { @sf.t("web-main.composer.attach") } }, shortcut="composer.file")
      |> ignore
    },
  )
  |> ignore
}

///|
/// 抄送 in `parent` (cc_chooser's, a node's): a chooser's look (12, quiet, the hover's ground while the hand is on it or
/// its menu is open), opening a menu over it of the threads to tick, each its mark and place, the ticked ones checked:
/// one closes once ticked, several stay open to tick in turn (each tick `chat.cc`).
fn cc_chooser_node(parent : @view.View, src : Source, r : ChatRef, head : () -> ChatView?, tips : @sf.TipLayer) -> Unit {
  ignore(tips)
  let to = fn() {
    match head() {
      Some({ cc, thread: Some(th), .. }) => (cc, th)
      _ => ([], 0.0)
    }
  }
  let open = @signals.signal(false, same=fn(a, b) { a == b })
  let label = fn() { @sf.t("web-main.composer.ccLabel") }
  let b = @headless.disclosure(parent, fn() { ([label()] + to().0.filter(fn(o) { o.on }).map(fn(o) { o.place })).join(" ") }, fn() {
    open.get()
  }, fn(_) { open.set(!open.untracked()) }, fn(v, d) {
    let lit = fn() { @sf.lit_node(v) || d.open() }
    v
    .row(Is(true))
    .height(Is(Some(@ui.Space::px(S7))))
    .padding(Is((@ui.Space::px(S2), 0.0, @ui.Space::px(S2), 0.0)))
    .gap(Is(@ui.Space::px(S1_5)))
    .radius(By(fn() { @ui.tree_theme().corner(Lg) }))
    .lines_up(Is(Some(Middle)))
    .ground(By(fn() { if lit() { @ui.tree_theme().color(Hover) } else { 0L } }))
    .focus_ring_theme()
    |> ignore
    @sf.words_node(v, label, fn() { if lit() { cc_words_lit } else { cc_words } }) |> ignore
    @sf.icon_node(v, "chevron-down", 12.0, By(fn() { if lit() { @sf.theme().p.text } else { @sf.theme().p.muted } }))
    |> ignore
    v.on_leaving(fn() { open.set(false) }) |> ignore
  })
  // (its menu made over the window, living as long as 抄送 does: not in the composer, which cuts what it holds)
  let holder = parent.tree.root().box(fn(h) { h.over(Is(true)) |> ignore }).lives_with(b)
  @sf.menu_ticks_node(
    holder,
    fn() { open.get() },
    fn(_) { b },
    fn() {
      let (cc, th) = to()
      cc.map(fn(o) {
        Some(
          @sf.menu_item_of(o.place, chosen=o.on, fn() {
            (src.call)(
              "chat.cc",
              {
                "station": Json::string(r.station),
                "thread": Json::number(th),
                "to": Json::number(o.thread),
                "on": Json::boolean(!o.on),
              },
              @sfbase.answer_unread,
            )
          }),
        )
      })
    },
    "",
    End,
    6.0,
    false,
    false,
    fn(item) {
      (item.select)()
      // (one: done once ticked; several: left open to tick the next)
      if to().0.length() <= 1 {
        open.set(false)
      }
    },
    fn() { open.set(false) },
    side=Top,
    min_w=@sf.chooser_menu_w,
    // (each ticked one's check at its row's end, none before its mark: the old one's, 左子健's)
    check_end=true,
    extras=fn(i) {
      match to().0.get(i) {
        Some(o) => { note: "", value: "", mark: Some(Drawn(if o.via == "feishu" { "feishu" } else { "slack" })), end: None }
        None => { note: "", value: "", mark: None, end: None }
      }
    },
  )
}

///|
/// The mark of the platform what is sent is copied to (cc_mark's, a node's): Feishu's for Feishu, else Slack's, 14.
fn cc_mark_node(parent : @view.View, via : String) -> Unit {
  @sf.origin_mark_node(parent, fn() { via }, 14.0) |> ignore
}

///|
/// What waits to go with the message in `box` (composer_extras', as nodes): the quotes, each with a line for what is
/// said about it (the one the core asks the focus for takes it; Enter in it goes back to the words), then the files: a
/// picture as its tile, pasted words, a station's file, a link or any other file as its card; each with its ✕ hung on
/// its corner. Made while there is any, coming in and going down the composer's column as what comes does.
fn composer_extras_node(
  box : @view.View,
  src : Source,
  r : ChatRef,
  w : Writing,
  tips : @sf.TipLayer,
  stand : Stand,
) -> Unit {
  let inner = fn() { stand.at(fn() { @sf.composer_inner() }) }
  // (there at once, as what the core's draft says it holds: its height going its way where a hand here put it in or
  // took it out, View::resizes said at that cause; its parts made whole, never drawn on a way of their own inside the
  // list's foot)
  box.show(at_once=true, fn() { w.quotes.get().length() > 0 || w.files.get().length() > 0 }, fn(area) {
    area
    .padding(
      By(fn() {
        let d = stand.at(fn() { @sf.composer_waiting_in() })
        (d, d, d, 0.0)
      }),
    )
    |> ignore
    // (its quotes, then its files: each nothing while it holds none, so what goes closes with the area's own way)
    area.box(fn(qs) {
      // (each 10 over what follows it, within it: what goes closes with it, nothing left behind)
      qs.gap(Is(@ui.Space::px(S1_5))).gone_empty(Is(true)).padding(Is((0.0, 0.0, 0.0, @ui.Space::px(S2_5)))) |> ignore
      qs.each(at_once=true, fn() { w.quotes.get() }, fn(q) { text(Some(q), "id") }, fn(row, q) {
        let id = text(Some(@signals.untracked(fn() { q.get() })), "id")
        let v = fn() { Some(q.get()) }
        let f = match composing.comments.get(id) {
          Some(f) => f
          None => {
            let f = @ui.Field::new(text=text(@signals.untracked(v), "comment"))
            composing.comments[id] = f
            f
          }
        }
        let card_key = w.key + "\u{1}" + id
        let card = @sf.composer_quote_card_node(
          row,
          tips,
          fn() { text(v(), "author") },
          fn() { text(v(), "text") },
          fn() { text(v(), "role") },
          fn(line) {
            @ui.field(
              line,
              f,
              placeholder=@sf.t("web-main.quote.commentPlaceholder"),
              font_size=@signals.untracked(fn() { @sf.theme().t.ui }),
              line=@signals.untracked(fn() { @sf.theme().t.ui_line }),
              max_lines=1,
              enter_sends=true,
              colors_by=fn() {
                let p = @sf.theme().p
                (p.text, p.subtle, p.accent)
              },
              edited=fn(now) { writing_comment(src, w, id, now) },
              // (Enter in it: back to the words)
              submitted=fn(_) { w.field.focus() },
            )
            .grow(Is(1.0))
            |> ignore
          },
          fn() {
            if f.focused() {
              w.field.focus()
            }
            composer_quote_cards.remove(w.key + "\u{1}" + id)
            writing_unquote(src, w, id)
          },
          fn() { @sf.t("web-main.quote.remove") },
          pictured=fn() { quote_picture_now(src, w, r.station, v()) is Some(_) },
          picture=fn(b) {
            // (a message's video on the station: its still, as a message's file shows it: video_still_node)
            let still = quote_still_node(b, src, r.station, @signals.untracked(v))
            let tile = waiting_tile_of(
              b,
              fn() {
                match quote_picture_now(src, w, r.station, v()).map(fn(p) { p.0 }) {
                  Some("") => still()
                  Some(k) => k
                  None => ""
                }
              },
              fn() { quote_picture_now(src, w, r.station, v()).map(fn(p) { p.1 }).unwrap_or(false) },
              fn() { going_now(field(v(), "own")) },
              fn() { gone_up(field(v(), "own")) },
              fn() { text(field(v(), "own"), "error") != "" },
              fn() { writing_retry(src, w, text(field(v(), "own"), "id")) },
            )
            // (its square, for what is sent to fly from: composer_sent_parts)
            composer_sent_parts_kept(w.key + "\u{1}" + id + "\u{1}picture", tile)
          },
        )
        composer_quote_cards[card_key] = card
        card.owns(fn() {
          match composer_quote_cards.get(card_key) {
            Some(c) if c.id() == card.id() => composer_quote_cards.remove(card_key)
            _ => ()
          }
        })
        |> ignore
        // (the one the core says asks for the focus: given it, told; none where it says none, a quote of its own with no id
        // among them)
        // (given once what it is made in is held from the window's root, and once a menu or a sheet its quote was asked
        // from is closing: in a change of that moment after the one that closed it, once the layer it was has let the
        // keys go (Tree::takes_keys) and given back the focus it held, the focus given to it after that)
        row.reacts(fn() { w.focus.get() != "" && w.focus.get() == id && !@sf.presenting() }, fn(asks) {
          if asks {
            row.at_moment(row.cause_at(), fn() {
              if @signals.untracked(fn() { w.focus.get() }) == id {
                f.focus()
                writing_focused(src, w)
              }
            })
            |> ignore
          }
        })
      })
    })
    |> ignore
    area.box(fn(fs) {
      fs
      .gone_empty(Is(true))
      .row(Is(true))
      .gap(Is(@ui.Space::px(S1_5)))
      .wraps(By(fn() { Some(@ui.Space::px(S1_5) + @sf.corner_remove_reach(inner())) }))
      .padding(
        By(fn() {
          let end = stand.at(fn() { @sf.composer_files_end() - @sf.composer_waiting_in() })
          (0.0, 0.0, end, @ui.Space::px(S2_5))
        }),
      )
      |> ignore
      fs.each(at_once=true, fn() { w.files.get() }, fn(f) { text(Some(f), "id") }, fn(item, f) {
        composer_file_node(item, src, r, w, tips, fn() { Some(f.get()) }, inner, stand)
      })
    })
    |> ignore
  })
}

///|
/// A picture or a video's still waiting in the composer in `parent` (the library's waiting_tile_node): picture `key()`
/// covering it (a video's still on the words' ink; none yet, the neutral ground), decoded for as many of the device's
/// pixels as it is drawn at; going up, failed and a video's mark as the library's tile draws them. The tile's node.
fn waiting_tile_of(
  parent : @view.View,
  key : () -> String,
  video : () -> Bool,
  going : () -> Bool,
  part : () -> Double?,
  failed : () -> Bool,
  again : () -> Unit,
) -> @view.View {
  @sf.waiting_tile_node(
    parent,
    fn(p) {
      p
      .ground(By(fn() { if video() { @sf.theme().p.text } else { @ui.tree_theme().color(Neutral) } }))
      .image(
        By(fn() {
          match key() {
            "" | "!" => None
            k => Some((k, "", (@sf.waiting_tile_side * p.pixel_scale()).ceil().to_int()))
          }
        }),
      )
      .image_covers(Is(true))
      |> ignore
    },
    going,
    part,
    failed,
    again,
    fn() { @sf.t("web-main.composer.retryUpload") },
    video~,
  )
}

///|
/// A quote's own picture as the composer shows it now (quote_picture's, a node's): its key and whether it is a video's
/// still; the device's own while it holds it (a mark's screenshot), else the station's image of a message quoted.
fn quote_picture_now(src : Source, w : Writing, station : String, q : Json?) -> (String, Bool)? {
  let own = field(q, "own")
  let kind = file_kind(text(own, "name"))
  guard own is Some(_) && (kind == "image" || kind == "video") else { return None }
  match writing_pictures.get(text(own, "id")) {
    Some(picture) => Some((picture, kind == "video"))
    None => {
      match field(own, "done") {
        Some(j) => {
          let a = attachment_of(j)
          let owner = text(Some(j), "owner")
          match sent_picture(station, a) {
            Some(k) => return Some((k, kind == "video"))
            None => ()
          }
          if owner != "" && kind == "image" {
            return Some(((src.file)(station, owner, stored_name(a.path)), false))
          }
          // (a message's video on the station: its first frame, made where its tile is: quote_still_node)
          if owner != "" && kind == "video" {
            return Some(("", true))
          }
        }
        None => ()
      }
      waiting_picture(src, w, own).map(fn(p) { (p, kind == "video") })
    }
  }
}

///|
/// The first frame of quote `q`'s own video where it is a message's on the station (its `done` with its session
/// `owner`), for its tile in node `b` (video_still_node: as a message's file shows it), "" while it is not made or
/// where it is none such.
fn quote_still_node(b : @view.View, src : Source, station : String, q : Json?) -> () -> String {
  let done = field(field(q, "own"), "done")
  let owner = text(done, "owner")
  match done {
    Some(j) if owner != "" && file_kind(text(field(q, "own"), "name")) == "video" => {
      let a = attachment_of(j)
      @sfbase.video_still_node(b, src, station, owner, a, station + "/" + owner + "/" + a.path)
    }
    _ => fn() { "" }
  }
}

///|
/// One file waiting in `item` (composer_file's, a node's): its picture's tile, or its card; its ✕ hung on its corner.
fn composer_file_node(
  item : @view.View,
  src : Source,
  r : ChatRef,
  w : Writing,
  tips : @sf.TipLayer,
  v : () -> Json?,
  inner : () -> Double,
  stand : Stand,
) -> Unit {
  let id = text(@signals.untracked(v), "id")
  let name = fn() { text(v(), "name") }
  let remove = fn() { writing_remove(src, w, id) }
  item.pick(fn() { waiting_picture(src, w, v()) is Some(_) }, at_once=true, fn(p, pictured) {
    if pictured {
      @sf.with_corner_remove_node(
        p,
        fn() { @sf.t("web-main.file.remove", args=[("name", name())]) },
        @signals.untracked(inner),
        fn(at) {
          // (a video's that the host has no picture of: its first frame, made from its bytes)
          let still = @sfbase.writing_still_node(at, id)
          let tile = waiting_tile_of(
            at,
            fn() {
              match waiting_picture(src, w, v()) {
                Some("") => still()
                Some(k) => k
                None => ""
              }
            },
            fn() { file_kind(name()) == "video" },
            fn() { going_now(v()) },
            fn() { gone_up(v()) },
            fn() { text(v(), "error") != "" },
            fn() { writing_retry(src, w, id) },
          )
          @sf.tip_node(tips, tile, fn() { if text(v(), "error") != "" { text(v(), "error") } else { name() } }) |> ignore
          composer_sent_parts_kept(w.key + "\u{1}" + id, tile)
          // (the end of the preview's flight that stays, by the viewer's id of what it opens: drawn nowhere while the
          // viewer shows it, its picture flown from here and back here, View::shared's `stays`, as a message's
          // thumbnail is (message_media_node))
          tile
          .shared(
            By(fn() {
              let picture = waiting_picture(src, w, v()).unwrap_or("")
              // (one the viewer cannot open yet, a video whose first frame is still being made: the id it will open by
              // once it can, from here, drafted)
              match waiting_seen(waiting_preview(r.station, id, name(), picture, v())) {
                "" => r.station + "//draft:" + id
                seen => seen
              }
            }),
            @motion.flight_by(@motion.moved()),
            stays=true,
          )
          |> ignore
          // tapped, it opens in the viewer (preview_composer_picture's): a press on what holds it and its ✕, so the ✕
          // over its corner is pressed within it, not beside it
          at.on_press(fn() { preview_waiting(r.station, id, name(), waiting_picture(src, w, v()).unwrap_or(""), v()) })
          |> ignore
        },
        remove,
      )
      |> ignore
    } else {
      @sf.with_corner_remove_node(
        p,
        fn() { remove_label(v(), name()) },
        @signals.untracked(inner),
        fn(at) {
          // (as wide as a file's card, or the composer where it is narrower)
          at.width(By(fn() { Some(@sf.dmin(@sf.file_card_w, stand.at(fn() { composer_width((stand.wide)()) }))) })) |> ignore
          let card : Ref[@view.View?] = Ref(None)
          let as_ = fn() { waiting_as(v()) }
          let ref_ = fn() { field(v(), "ref") }
          let error = fn() { text(v(), "error") }
          card.val = Some(
            @sf.file_waiting_node(
              at,
              tips,
              fn() {
                if as_() is Link {
                  text(field(v(), "link"), "url")
                } else if as_() is AnyFile && field(ref_(), "dir") is Some(True) {
                  name() + ".zip"
                } else {
                  name()
                }
              },
              fn() {
                match as_() {
                  Link =>
                    match text(field(v(), "link"), "title") {
                      "" => text(field(v(), "link"), "url")
                      t => t
                    }
                  Pasted =>
                    match text(field(v(), "pasted"), "preview") {
                      "" => @sf.t("web-main.composer.pastedText")
                      first => first
                    }
                  _ => ""
                }
              },
              fn() { waiting_meta(v()) },
              inner,
              fn(on) {
                match (as_(), on) {
                  (Link, Opened) => open_link(text(field(v(), "link"), "url"))
                  (Pasted, Back) => {
                    let back = text(field(v(), "pasted"), "text")
                    let now = w.text.get()
                    let words = if now == "" { back } else { now + "\n" + back }
                    @sfbase.refs_put(w.key, w.field, words)
                    writing_text(src, w, words)
                    remove()
                    w.field.focus()
                  }
                  (Pasted, Again) => @sfbase.writing_paste_again(src, w, id)
                  (ByPath | AnyFile, Opened) =>
                    match (field(v(), "ref"), card.val) {
                      (Some(Object(_)), Some(c)) =>
                        @sf.panel_nodes(name(), fn(pv, close) { ref_panel_body(pv, close, src, w.key, r.station, id) }, from=Node(c))
                      _ => ()
                    }
                  (ByPath | AnyFile, Again) => writing_retry(src, w, id)
                  _ => ()
                }
              },
              tip=fn() {
                match as_() {
                  ByPath => text(ref_(), "path")
                  Link => text(field(v(), "link"), "url")
                  Pasted => waiting_meta(v())
                  AnyFile => name()
                }
              },
              dir=fn() { field(ref_(), "dir") is Some(True) },
              named=fn() { as_() is ByPath },
              fails=fn() { error() != "" },
              spins=fn() { going_now(v()) && field(v(), "sent") is None && as_() is (AnyFile | Pasted) },
              retry=fn() { error() != "" && (as_() is AnyFile || as_() is Pasted) },
              restore=fn() { as_() is Pasted && restorable(w, v()) },
              opens=fn() { as_() is (ByPath | Link) || (as_() is AnyFile && ref_() is Some(Object(_))) },
            ),
          )
          match card.val {
            Some(c) => composer_sent_parts_kept(w.key + "\u{1}" + id, c)
            None => ()
          }
        },
        remove,
      )
      |> ignore
    }
  })
}

///|
/// What a file waiting's card says under its name (file_card's `meta` as waiting_card asks it): why it failed; going up,
/// how far; a station's file named by its path, its station and that it goes so; a link, its site; pasted words, how
/// many characters; else its size.
fn waiting_meta(v : Json?) -> String {
  let error = text(v, "error")
  if error != "" {
    return error
  }
  match waiting_as(v) {
    ByPath => text(field(v, "ref"), "stationName") + " · " + @sf.t("web-main.file.modePath")
    Link => text(field(v, "link"), "site")
    Pasted =>
      if going_now(v) {
        waiting_going(v)
      } else {
        @sf.t("web-main.composer.pasteAttachment", args=[("count", @sf.grouped(number(field(v, "pasted"), "characters")))])
      }
    AnyFile =>
      if going_now(v) {
        waiting_going(v)
      } else {
        let done = field(v, "done")
        @sf.file_size(number(done, "size") + (if done is None { number(v, "size") } else { 0.0 }))
      }
  }
}

///|
/// How far a file waiting has gone up (file_card's `pending`): every byte gone, its station not yet saying it has them,
/// not 100%.
fn waiting_going(v : Json?) -> String {
  let size = number(v, "size")
  match field(v, "sent") {
    Some(Number(s, ..)) if size > 0.0 && s >= size => @sf.t("common.uploadConfirming")
    Some(Number(s, ..)) if size > 0.0 =>
      @sf.t("web-main.file.uploadingPart", args=[("percent", (s / size * 100.0).floor().to_int().to_string()), ("size", @sf.file_size(size))])
    _ => @sf.t("common.uploading")
  }
}

///|
/// What a picture waiting opens in the viewer as it is tapped (preview_composer_picture's): its station, its session
/// (none: it is in the draft) and the file, with the bytes picked or kept where it has them (`draft:<id>`), else a
/// quoted message's file on the station (`done` with its session `owner`), else the picture its tile shows; none where
/// it has nothing to show.
fn waiting_preview(
  station : String,
  id : String,
  name : String,
  picture : String,
  v : Json?,
) -> (String, String, Attachment, Bytes?)? {
  let done = field(v, "done")
  let width = if number(done, "width") > 0.0 { number(done, "width") } else { number(v, "width") }
  let height = if number(done, "height") > 0.0 { number(done, "height") } else { number(v, "height") }
  let drafted = fn(size : Double) -> Attachment {
    {
      name,
      path: "draft:" + id,
      size,
      width,
      height,
      thumbhash: "",
      owner: "",
      upload: "",
      duration: 0.0,
      frames: 0,
      held: false,
    }
  }
  match @sfbase.writing_went_to(id) {
    Some((went_station, _, bytes)) => {
      let s = if station != "" { station } else { went_station }
      Some((s, "", drafted(bytes.length().to_double()), Some(bytes)))
    }
    None =>
      match done {
        Some(j) if text(done, "owner") != "" => Some((station, text(done, "owner"), attachment_of(j), None))
        _ if picture != "" && picture != "!" => {
          let size = if number(done, "size") > 0.0 { number(done, "size") } else { number(v, "size") }
          Some((station, "", drafted(size), None))
        }
        _ => None
      }
  }
}

///|
/// The viewer's id of what `preview` opens (its station, its session if any, its path: preview_composer_picture's
/// `seen`), its tile's as the viewer flies from it and back into it; "" none.
fn waiting_seen(preview : (String, String, Attachment, Bytes?)?) -> String {
  match preview {
    Some((s, owner, a, _)) => s + "/" + owner + "/" + a.path
    None => ""
  }
}

///|
/// A picture waiting tapped (preview_composer_picture's): it opens in the viewer (waiting_preview's), growing out of
/// its tile, the bytes it has kept for the viewer to read by its id.
fn preview_waiting(station : String, id : String, name : String, picture : String, v : Json?) -> Unit {
  let preview = waiting_preview(station, id, name, picture, v)
  match preview {
    Some((s, owner, a, bytes)) => {
      match bytes {
        Some(b) => @sfbase.keep_read(waiting_seen(preview), b)
        None => ()
      }
      @sfbase.open_preview(s, owner, a)
    }
    None => ()
  }
}

///|
/// What is said over a chat's composer in `foot` (chat_notices', as nodes), each a capsule of its own over it as the
/// composer is, coming in and going down its column as what comes does: an archived chat's, with 还原对话 (why it
/// failed under it; not while its station is down); its agent's prompt cache over, with the choice of how it goes on;
/// its station down; the still.fail team's reply on a bug report sent from it.
fn composer_notices_node(
  foot : @view.View,
  src : Source,
  r : ChatRef,
  tips : @sf.TipLayer,
  stand : Stand,
  drawn_off : (@view.View) -> Double,
) -> Unit {
  let key = r.station + ":" + r.session
  let head = fn() { @sfbase.chat_view_now(src, r) }
  let width = fn() { stand.at(fn() { composer_width((stand.wide)()) }) }
  // (each a notice of its own, in their order: one comes in and goes down the column as what comes does)
  let report = fn() { feedback_reports(src, r).iter().find_first(fn(f) { !report_dismissed(f) }) }
  let kinds = fn() { composer_notice_kinds(src, r) }
  // (the ＋'s middle as the composer draws it, from its start: its round control's, a point wider for the capsule's edge
  // line, its capsule_pad_alone in; where each notice's mark stands)
  let plus_mid = fn() { capsule_pad_alone + node_capsule_extra((stand.scale)()) + (@sf.theme().round.side + 1.0) / 2.0 }
  foot.each(kinds, fn(k) { k }, fn(n, kind) {
    // (as wide as the composer, the library's notice drawn in from its ends)
    n.width(By(fn() { Some(width()) })) |> ignore
    match @signals.untracked(fn() { kind.get() }) {
      // (archived: sending restores it; 还原对话 restores it now)
      "archive" => {
        let busy = fn() { composing.restoring.get(key).unwrap_or(false) }
        let off = fn() { busy() || head().map(fn(h) { h.offline }).unwrap_or(false) || src.read_only }
        // (drawn with the composer's ground's top as its shape goes, as far over it all the way: where its foot's
        // room goes its way on the page's too; the notice's own box, its row a slot of the column)
        let made = @sf.composer_notice_node(
          n,
          tips,
          fn() { "archive" },
          fn() { @sf.t("web-main.archived.sendRestores") },
          plus_mid,
          offer={
            words: fn() { @sf.t(if busy() { "web-main.archived.restoring" } else { "web-main.archived.restore" }) },
            name: fn() { @sf.t("web-main.archived.restore") },
            off,
            press: fn() { notice_restore(src, r, key) },
          },
          failed=fn() { composing.restore_errors.get(key).unwrap_or("") },
        )
        made.offset(By(fn() { (0.0, drawn_off(made)) })) |> ignore
      }
      // (its agent's prompt cache over: what going on would read again, and the choice of how it goes on)
      "wait" => {
        let cold = fn() { head().bind(fn(h) { h.cache_cold }) }
        let doing = fn() {
          match cold() {
            Some((session, _, _, _)) => "session.settings/" + r.station + "/" + session
            None => ""
          }
      }
        let held = fn() { @sfbase.doing(doing()) || head().map(fn(h) { h.offline }).unwrap_or(false) }
        // (drawn with the composer's ground's top as its shape goes, as far over it all the way: where its foot's
        // room goes its way on the page's too; the notice's own box, its row a slot of the column)
        let made = @sf.composer_notice_node(
          n,
          tips,
          fn() { "wait" },
          fn() { cold().map(fn(c) { c.1 }).unwrap_or("") },
          plus_mid,
          summary=fn() {
            match cold() {
              Some((_, status, detail, _)) if detail != "" => Some((status, detail))
              _ => None
            }
          },
          choices=fn() { [("go_on", @sf.t("web-main.chat.goOn")), ("afresh", @sf.t("web-main.chat.afresh"))] },
          chosen=fn() { if cold().map(fn(c) { c.3 }).unwrap_or(false) { "afresh" } else { "go_on" } },
          held~,
          choose=fn(value) {
              guard cold() is Some((session, _, _, afresh)) && !held() else { return }
              let next = value == "afresh"
              if next != afresh {
                let words = if next { "web-main.chat.afresh" } else { "web-main.chat.goOn" }
                let params : Json = { "station": Json::string(r.station), "key": Json::string(session), "afresh": Json::boolean(next) }
                @sfbase.act(src, @sf.t(words), doing(), "session.settings", params)
              }
          },
        )
        made.offset(By(fn() { (0.0, drawn_off(made)) })) |> ignore
      }
      // (its station down, or gone for its update)
      "unplug" => {
        // (drawn with the composer's ground's top as its shape goes, as far over it all the way: where its foot's
        // room goes its way on the page's too; the notice's own box, its row a slot of the column)
        let made = @sf.composer_notice_node(
          n,
          tips,
          fn() { if head().map(fn(h) { h.updating }).unwrap_or(false) { "updating" } else { "unplug" } },
          fn() {
            match head().bind(fn(h) { h.offline_note }) {
              Some(note) => note
              None =>
                if r.station_name != "" {
                  @sf.t("web-main.chat.offline.named", args=[("name", r.station_name)])
                } else {
                  @sf.t("web-main.chat.offline")
                }
            }
          },
          plus_mid,
        )
        made.offset(By(fn() { (0.0, drawn_off(made)) })) |> ignore
      }
      // (the still.fail team's reply on a bug report sent from it: the chat's people's to read)
      "said" => {
        // (whose reply it is over the first line of their latest: words of a length nobody knows under a title of their
        // own, beside what it offers across the middle of both, never broken for them alone)
        // (drawn with the composer's ground's top as its shape goes, as far over it all the way: where its foot's
        // room goes its way on the page's too; the notice's own box, its row a slot of the column)
        let made = @sf.composer_notice_node(
          n,
          tips,
          fn() { "said" },
          fn() { report().map(fn(f) { text(Some(f), "heading") }).unwrap_or("") },
          plus_mid,
          summary=fn() {
            report().map(fn(f) { (text(Some(f), "heading"), text(Some(f), "latest")) })
          },
          offer={
            words: fn() { @sf.t("web-main.feedback.open") },
            name: fn() { @sf.t("web-main.feedback.open") },
            off: fn() { false },
            press: fn() {
              match report() {
                Some(f) => open_feedback(src, r, text(Some(f), "id"))
                None => ()
              }
            },
          },
          dismiss={
            words: fn() { "" },
            name: fn() { @sf.t("web-main.feedback.dismiss") },
            off: fn() { false },
            press: fn() {
              guard report() is Some(f) else { return }
              let id = text(Some(f), "id")
              let latest_id = report_latest_id(f)
              guard latest_id != "" else { return }
              feedback_dismissed[id] = latest_id
              (src.call)(
                "feedback.dismiss",
                { "workspace": Json::string(text(Some(f), "workspace")), "id": Json::string(id), "reply": Json::string(latest_id) },
                @sfbase.answer_unread,
              )
            },
          },
        )
        made.offset(By(fn() { (0.0, drawn_off(made)) })) |> ignore
      }
      _ => ()
    }
  })
}

///|
/// An archived chat restored (还原对话 over its composer): told the core, felt as done or refused, why it failed kept.
fn notice_restore(src : Source, r : ChatRef, key : String) -> Unit {
  composing.restoring[key] = true
  composing.restore_errors.remove(key)
  let p : Map[String, Json] = {
    "station": Json::string(r.station),
    "session": Json::string(r.session),
    "archived": Json::boolean(false),
  }
  match @sfbase.chat_view_now(src, r).bind(fn(h) { h.thread }) {
    Some(th) => p["thread"] = Json::number(th)
    None => ()
  }
  (src.call)("chat.archive", Json::object(p), fn(res) {
    composing.restoring.remove(key)
    match res {
      Err(e) => {
        composing.restore_errors[key] = error_words(e)
        @ui.haptic(Reject)
      }
      Ok(_) => @ui.haptic(Confirm)
    }
  })
}

///|
/// ＋'s sheet for draft `key` on a touch system, opened by ＋ (`plus`, a node: attach_open's).
fn attach_open_node(plus : @view.View, src : Source, key : String) -> Unit {
  @sf.panel_nodes("", fn(v, close) { attach_body_node(v, src, key, close) }, from=Node(plus), w=attach_w)
  recent_opened()
}

///|
/// What is put into draft `w` from outside its field taken in as it is given, at its moment (take_in's, a node's: sfbase's
/// draft_taker while it shows; take_given), the cursor in its field after words a visualization asked to send; none of
/// what holds files while no file is taken in (`no_files`).
fn take_in_node(v : @view.View, src : Source, r : ChatRef, w : Writing, no_files : () -> Bool) -> Unit {
  let off = @sfbase.draft_taker(w.key, fn() {
    let off_files = @signals.untracked(no_files)
    let mut refused = false
    for g in @sfbase.draft_taken(w.key) {
      if off_files && (g is Dropped(_) || (g is Picked(list) && !list.is_empty())) {
        refused = true
      }
      given_into(src, r.station, w, off_files, g)
    }
    // (files not taken in where none goes up now, its station not reached: said why, and what to do, never let go of
    // with nothing said, as the old composer says it)
    if refused {
      toast_later(@sf.t("web-main.composer.filesOffline"))
    }
  })
  v.owns(off) |> ignore
}

///|
/// The cards of the quotes waiting in each draft's composer made as nodes, by its key and the quote's id: where each is
/// laid out is said at a send (send_in_chat_node), for the sent row's cards to fly from (sfbase's sent_quotes_from_said).
// kept across runs: each let go with its node
let composer_quote_cards : Map[String, @view.View] = Map([])

///|
/// What holds each draft's composer made as nodes at the shape it had as words were sent from it (its ground drawn as
/// tall as it was, coming down to its one line: composer_box_node's), said as it is emptied (sent_from_node).
// kept across runs: each let go with its composer's node
let composer_sent_holds : Map[String, () -> Unit] = Map([])

///|
/// The tiles of the files and the quotes' pictures waiting in each draft's composer made as nodes, by its key and the
/// file's id (a quote's picture: the quote's id, then `picture`): where each is laid out is said at a send
/// (send_in_chat_node), for the sent row's parts to fly from (sfbase's sent_part_said), as the old composer's are.
// kept across runs: each let go with its node
let composer_sent_parts : Map[String, @view.View] = Map([])

///|
/// Node `v` kept as `key`'s among composer_sent_parts while it is made.
fn composer_sent_parts_kept(key : String, v : @view.View) -> Unit {
  composer_sent_parts[key] = v
  v.owns(fn() {
    match composer_sent_parts.get(key) {
      Some(k) if k.id() == v.id() => composer_sent_parts.remove(key)
      _ => ()
    }
  })
  |> ignore
}

///|
/// Where node `key` of composer_sent_parts was last placed, while it is made: as it stood before the change under way,
/// nothing laid out for it.
fn composer_sent_part_at(key : String) -> (Double, Double, Double, Double)? {
  match composer_sent_parts.get(key) {
    Some(v) if v.alive() => Some(v.placed_window_now())
    _ => None
  }
}

///|
/// What is written sent into chat `r` from a composer made as nodes (send_in_chat's): in the list in the moment it is
/// sent, before the core has it (sent_local: its list goes to its end for it, chat_body_node's), the composer empty at
/// once; then what the core took (`composer.take`) goes (`chat.send`). Not taken in at all: back in the composer unless
/// something new is written there, saying why.
pub fn send_in_chat_node(src : Source, r : ChatRef, v : ChatView, w : Writing) -> Unit {
  if src.read_only {
    toast_later(read_only_words)
    return
  }
  @ui.haptic(KeyboardTap)
  let words = @signals.untracked(fn() { w.text.get() }).trim(chars=" \n\t").to_owned()
  let rk = r.station + "\u{1}" + r.session
  remember_sent_pictures_now(src, w, r.station)
  let marks = @sfbase.refs_sent_marks(w.key, words)
  ignore(marks)
  let runs = @sfbase.refs_sent_runs(w.key, words)
  // (where its words, cards and files stand in the composer now, as part of what is sent: its row flies from there,
  // whatever makes it at whatever moment (sent_local's `from`, SentFrom; mbui's View::flies_in); none with motion
  // reduced)
  let from : @sfbase.SentFrom? = if @ui.reduced_motion() {
    None
  } else {
    // (its words from where they stand in the field)
    let words = w.field.words_at().map(fn(at) { at.0 })
    // (each quote's card from where it is laid out in the composer, message_quotes_node's: where it stands at rest)
    let quotes = @signals.untracked(fn() { w.quotes.get() }).map(fn(q) {
      let k = w.key + "\u{1}" + text(Some(q), "id")
      let card = composer_quote_cards.get(k)
      composer_quote_cards.remove(k)
      match card {
        Some(c) if c.alive() => {
          // (drawn off by how much further in the composer's card has its words than the message's has: those set out
          // where these stood)
          let (x, y, cw, ch) = c.placed_window_now()
          let (dx, dy) = @sf.quote_words_shift(text(Some(q), "author"), text(Some(q), "role"))
          Some((x + dx, y + dy, cw, ch))
        }
        _ => None
      }
    })
    // (each of its files from its tile there, as the old composer's: its picture's or its card's, by what its row keys
    // it by (flying_key); each quote's own picture from its square in its card)
    let parts : Array[(String, (Double, Double, Double, Double))] = []
    let going = @signals.untracked(fn() { going_files(w) }).map(fn(f) { text(Some(f), "id") })
    for f in @signals.untracked(fn() { w.files.get() }) {
      let v = Some(f)
      let id = text(v, "id")
      let key = flying_key(v, going.contains(id), waiting_picture(src, w, v) is Some(_))
      match composer_sent_part_at(w.key + "\u{1}" + id) {
        Some(at) if key != "" => parts.push((key, at))
        _ => ()
      }
    }
    let held = @signals.untracked(fn() { w.quotes.get() })
    for i, _ in @signals.untracked(fn() { sent_quotes(w) }) {
      let q = Some(held[i])
      let own = field(q, "own")
      let key = flying_key(own, going.contains(text(own, "id")), true)
      match composer_sent_part_at(w.key + "\u{1}" + text(q, "id") + "\u{1}picture") {
        Some(at) if own is Some(_) && key != "" => parts.push((@sfbase.quote_picture_key(i), at))
        _ => ()
      }
    }
    Some({ words, quotes, parts, delay: 0.0 })
  }
  let row = sent_local(
    rk,
    Some(chat_whole(src, r, v)),
    words,
    @signals.untracked(fn() { up_files(w) }),
    going=@signals.untracked(fn() { going_files(w) }),
    quotes=@signals.untracked(fn() { sent_quotes(w) }),
    runs~,
    from~,
    now=(src.now)(),
  )
  @sfbase.chat_latest_now(src, r, v, @sf.t("web-main.chat.toLatest")) |> ignore
  // (emptied in the change its sent key comes in, as the old composer's take was asked in the build that sent it: its
  // foot giving back its room as that key comes, in the one way of its column; what the core answers a change of its
  // own)
  sent_from_node(src, r, v, w, rk, row)
}

///|
/// Draft `w` sent into chat `r` as row `row` of `rk` from a composer made as nodes (send_in_chat_node's): its ground held
/// at the shape it had, then taken and sent as any composer's is (chat_draft_take).
fn sent_from_node(src : Source, r : ChatRef, v : ChatView, w : Writing, rk : String, row : String) -> Unit {
  // (emptied as it is taken: laid out at its one line at once, its room under the list's last row with it (the sent
  // row carries it, as sfbase's composer_set_out says none for words sent), its ground keeping the shape it had as what
  // was sent left it, as the old composer's on this page does (sfbase's sent_out_hold_ms: till what flies from it begins
  // its rise), then down on their flight's curve, by move_most_ms)
  if !@ui.reduced_motion() {
    match composer_sent_holds.get(w.key) {
      Some(hold) => hold()
      None => ()
    }
  }
  sent_into_chat(src, r, v, w, rk, row)
}

///|
/// The pictures a composer made as nodes shows going with its message (remember_sent_pictures'), each by its upload
/// and, once up, by the station's path, so its row draws the same picture.
fn remember_sent_pictures_now(src : Source, w : Writing, station : String) -> Unit {
  let remember = fn(v : Json?, picture : String) {
    if picture == "" || picture == "!" {
      return
    }
    let id = text(v, "id")
    if id != "" {
      @sfbase.sent_picture_kept("upload\u{1}" + id, picture)
    }
    let path = text(field(v, "done"), "path")
    if station != "" && path != "" {
      @sfbase.sent_picture_kept(@sfbase.sent_key(station, path), picture)
    }
  }
  for file in @signals.untracked(fn() { w.files.get() }) {
    let v = Some(file)
    remember(v, waiting_picture(src, w, v).unwrap_or(""))
  }
  // (a quote's own picture where this device has it: picked here, or kept as the draft was (composer.picture); a
  // station's has the same source in both places already, its reveal not stopped half way as its message takes over)
  for q in @signals.untracked(fn() { w.quotes.get() }) {
    let own = field(Some(q), "own")
    match writing_pictures.get(text(own, "id")) {
      Some(p) => remember(own, p)
      None => remember(own, waiting_picture(src, w, own).unwrap_or(""))
    }
  }
}

///|
/// The `@` menu over composer `box` for draft `w` (ref_menu's, as nodes: the library's offers_node), while its field
/// has the focus and is at `@` and a few letters: its head (引用对话 and the words typed), then the chats they find (the
/// workspace's on every station of it, then the viewer's others', not this one), each its agent's mark, its title
/// (another workspace's or station's whose after it), when it was last active; or what it says in their place. ↑ / ↓
/// choose, Enter or Tab or a press put the one chosen in as its mark; Escape closes it for this `@`.
fn ref_menu_node(box : @view.View, src : Source, r : ChatRef, w : Writing) -> Unit {
  let into = workspace_of(r.station)
  let at = fn() {
    guard w.field.focused() && @sfbase.refs_at(w.key) is Some((start, query)) else { return None }
    if @sfbase.refs_closed(w.key, start) {
      None
    } else {
      Some((start, query))
    }
  }
  let found = fn() -> (@sfbase.Topic, Array[Json])? {
    guard at() is Some((_, query)) else { return None }
    let params : Map[String, Json] = {
      "scope": Json::string(into),
      "query": Json::string(query),
      "station": Json::string(r.station),
      "limit": Json::number(ref_shown.to_double()),
      "elsewhere": Json::boolean(true),
      "exclude": Json::string(r.session),
    }
    let topic = @sfbase.refs_search(src, w.key, params)
    Some((topic, items(topic.value, "items")))
  }
  let chats = fn() { found().map(fn(f) { f.1 }).unwrap_or([]) }
  let key_of = fn(x : Json) { text(Some(x), "station") + "\t" + text(Some(x), "id") }
  // (the chats found by their key, once for every row: a row reads its own by its key)
  let by_key : @signals.Computed[Map[String, Json]] = @signals.computed(fn(_) {
    Map::from_array(chats().map(fn(x) { (key_of(x), x) }))
  })
  let current = @signals.signal(0, same=fn(a, b) { a == b })
  // (the words typed after the `@` another: the first chosen again)
  box.reacts(fn() { at().map(fn(a) { a.1 }) }, fn(_) { current.set(0) })
  @sf.offers_node(
    box,
    box,
    fn() { at() is Some(_) },
    fn() { chats().map(key_of) },
    current,
    fn(row, k, on) {
      let item = fn() { by_key.get().get(k) }
      let ci = fn() { item().map(@sfbase.chat_item) }
      row.box(fn(logo) {
        @sf.style_node(logo, fn() { ref_logo })
        logo.pick(fn() { ci().bind(fn(c) { c.agents.get(0) }).map(fn(a) { (a.maker, a.runtime) }) }, at_once=true, fn(m, a) {
          match a {
            Some((maker, runtime)) => @sf.maker_mark_node(m, maker, runtime, ref_logo_size) |> ignore
            None => ()
          }
        })
      })
      |> ignore
      row.box(fn(cell) {
        @sf.style_node(cell, fn() { ref_title_cell })
        // (all the row leaves, its time at the row's end, as the old menu's)
        cell.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(cell, fn() { ci().map(fn(c) { c.title }).unwrap_or("") }, fn() { ref_title }) |> ignore
        // another workspace's: whose; another station's: its mark and name
        cell.show(fn() { text(item(), "outside") != "" }, fn(chip) {
          @sf.style_node(chip, fn() { ref_chip_station })
          @sf.workspace_badge_node(
            chip,
            fn() { text(item(), "outside") },
            fn() { text(item(), "outsideEmoji") },
            fn() { text(item(), "outsideIcon") },
            ref_chip_icon,
          )
          @sf.words_node(chip, fn() { text(item(), "outside") }, fn() { ref_chip_words }) |> ignore
        })
        cell.show(fn() { text(item(), "outside") == "" && flag(item(), "otherStation") }, fn(chip) {
          @sf.style_node(chip, fn() { ref_chip_station })
          @sf.station_mark_node(
            chip,
            fn() { ci().map(fn(c) { c.station_emoji }).unwrap_or("") },
            fn() { ci().map(fn(c) { c.station_icon }).unwrap_or("") },
            ref_chip_icon,
            fn() { @sf.theme().p.muted },
            fn() { 0 },
          )
          @sf.words_node(chip, fn() { ci().map(fn(c) { c.station_name }).unwrap_or("") }, fn() { ref_chip_words })
          |> ignore
        })
      })
      |> ignore
      @sf.words_node(row, fn() { ci().map(fn(c) { c.ago }).unwrap_or("") }, fn() { ref_time }) |> ignore
      ignore(on)
    },
    fn(k) { @signals.untracked(fn() { by_key.get().get(k) }).map(fn(x) { @sfbase.chat_item(x).title }).unwrap_or("") },
    fn(i) {
      guard at() is Some((start, _)) && chats().get(i) is Some(x) else { return }
      let item = @sfbase.chat_item(x)
      @sfbase.refs_pick_now(src, w.key, w.field, start, into, item.station, item.id, item.title, fn(why) {
        toast_later(@sf.t("web-main.composer.refFailed", args=[("title", item.title), ("error", why)]))
      })
    },
    fn() { @sfbase.refs_close(w.key) },
    @sf.t("web-main.chatRef.title"),
    head=fn() { (@sf.t("web-main.chatRef.title"), at().map(fn(a) { a.1 }).unwrap_or("")) },
    side=Top,
    offset=ref_menu_off,
    none=fn(n) {
      @sf.style_node(n, fn() { ref_empty })
      n.pick(
        fn() {
          match found() {
            Some((topic, _)) if topic.value is None => if topic.error is Some(_) { 2 } else { 1 }
            Some((_, list)) if list.is_empty() => if at().map(fn(a) { a.1 }).unwrap_or("") != "" { 3 } else { 4 }
            _ => 0
          }
        },
        at_once=true,
        fn(p, said) {
          match said {
            1 => @sf.wait_line_node(p, fn() { @sf.t("common.reading") }) |> ignore
            2 =>
              @sf.words_node(p, fn() { @sf.t("web-main.chatRef.update", args=[("app", "still.fail")]) }, fn() {
                ref_empty_words
              })
              |> ignore
            3 => @sf.words_node(p, fn() { @sf.t("web-main.chatRef.noMatch") }, fn() { ref_empty_words }) |> ignore
            4 => @sf.words_node(p, fn() { @sf.t("web-main.chatRef.none") }, fn() { ref_empty_words }) |> ignore
            _ => ()
          }
        },
      )
    },
  )
}

///|
/// Each draft's composer made as nodes: its box, its foot in its list (what it is laid out as, read by what looks at
/// it: a test) and how much taller than it is laid out its ground is drawn (what it held as words were sent from it:
/// composer_box_node's sent_over), let go with it.
// kept across runs: each let go with its node
let composer_nodes : Map[String, (@view.View, @view.View, @motion.NodeWay, @motion.NodeWay)] = Map([])

///|
/// How much taller than it is laid out composer `c`'s ground is drawn at `at` (what it holds of the shape it had as
/// words were sent from it), 0 at rest.
fn composer_node_over(c : (@view.View, @view.View, @motion.NodeWay, @motion.NodeWay), at : Double) -> Double {
  c.2.value_at(at)
}

///|
/// Where draft `draft`'s composer made as nodes is drawn now (its box's ground, in the window), none where none shows.
pub fn composer_node_box(draft : String) -> (Double, Double, Double, Double)? {
  composer_nodes.get(draft).map(fn(c) { c.0.placed_window_now() })
}

///|
/// How much room draft `draft`'s composer made as nodes takes under its list's last row at `at` (its foot as laid out,
/// with what its ground holds over it of the shape it had as words were sent from it: as the old composer's room is
/// held for them, composer_room), none where none shows.
pub fn composer_node_room(draft : String, at : Double) -> Double? {
  composer_nodes.get(draft).map(fn(c) { c.1.laid_window_now().3 + composer_node_over(c, at) })
}

///|
/// Where the composer made as nodes shown now stands at `at`, as the old composer's box is measured (what a test sets
/// beside it): its box as laid out, drawn off it by as far as its foot's room is on its way on the page's
/// (chat_composer_node's foot_shift); what its ground holds over it as words leave it not counted, as the old one's
/// measured box does not; none where none shows.
pub fn composer_node_ground(at : Double) -> (Double, Double, Double, Double)? {
  for _, c in composer_nodes {
    if c.0.alive() {
      let (x, y, w, h) = c.0.laid_window_now()
      return Some((x, y + c.3.value_at(at), w, h))
    }
  }
  None
}

///|
/// Where the composer made as nodes shown now is laid out (composer_node_box's), whichever draft's it is: none where none
/// shows. (`at`: what its ground holds over it as words leave it is drawn, not laid out: composer_node_room's.)
pub fn composer_node_shown(at : Double) -> (Double, Double, Double, Double)? {
  ignore(at)
  for _, c in composer_nodes {
    if c.0.alive() {
      return Some(c.0.placed_window_now())
    }
  }
  None
}

///|
/// How many nodes the composer made as nodes shown now holds, its foot's own with all it holds (what it costs: a test).
pub fn composer_node_count() -> Int {
  fn count(v : @view.View) -> Int {
    v.kids().fold(init=1, fn(n, k) { n + count(k) })
  }
  for _, c in composer_nodes {
    if c.1.alive() {
      return count(c.1)
    }
  }
  0
}
