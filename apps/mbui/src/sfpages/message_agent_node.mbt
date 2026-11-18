// What an agent (or still.fail itself) said, as nodes of the window's tree, made once (message.mbt's others_message
// with prose_with_files): under its picture, name and time, its words as the core read their Markdown (markdown_node:
// its links pressed where they lead and held for their menus, a bare link to a chat read as its title, the files its
// paths name its agent's chips, the files it places drawn where it places them, a link to a station's screens its card
// and a bare one its title: screen_links_node; each link's card while a mouse rests on it: message_link_card), its other
// files under them, what it asks under it (message_decision_node).
// What it quotes ahead of its words (message_quotes_node), each quote's own file in its card and not under its words.
// Each read through what it is given, as that changes.
// A Mermaid chart is drawn by `code` (chat_body_node's: viz_mermaid_node). Not here yet: its picture held under the
// pane's top as a long one scrolls past (c.stick).
// Its coming out of its agent's picture is here (agent_said_node's `out_of`, agent_out_steps: emit.mbt's Fold, Float,
// Spit and Return, one message of an agent's at a time).

///|
/// The card an agent's message shows in place of its words (prose_with_files'), by kind: a vault item's, a phone's, a
/// sign-in's, a rig's; "" none. Read off message_card_node's own (in_place_of), so the words are never left out for a
/// card it does not draw.
fn agent_card_kind(m : Message) -> String {
  match in_place_of(m) {
    Vault => "vault"
    Phone => "phone"
    SignIn => "signin"
    Rig => "rig"
    Words => ""
  }
}

///|
/// A station's screens' cards in what message `m` says (screen_links_node), each one's preview by the message and its
/// link, as the old view's (message.mbt's screen_links): by the message it is as each card is made (a block put by and
/// taken for another row's message: View::scrolls_window's `reused`).
fn agent_screens(src : Source, here : MessageNodeHere, m : () -> Message) -> @sf.ScreensNode {
  let of = fn() {
    @sfbase.screen_links_node(src, message=here.station + "/" + here.session + "/" + @signals.untracked(m).ts)
  }
  { card: fn(v, href, to, words) { (of().card)(v, href, to, words) }, title: fn(href, to) { (of().title)(href, to) } }
}

///|
/// What an agent or still.fail said (others_message's with prose_with_files) in its row's room (message_row_frame_node:
/// `key`, its list's Entry::id; `side`, `top`; `over`), as `m` says it as it changes: its picture out in the margin
/// (inline: over the head's start), its name (one of the chat's agents' opens its history), its time; its words as
/// prose_node_of draws them, its other files under them, what it asks under them (message_decision_node); where it
/// offers itself (`share`), its ⋯ and a right click's offer. `code`, `screens` (a station's screens' cards by default:
/// screen_links_node) and `shown` as agent_prose_node takes them. `ask_sought`: what it asks is what a go-to brings
/// before the eyes (the bell's: agent_asks_node's `sought`).
// the chat's page as nodes: held by its tests, not used by the app yet
#warnings("-unused_value")
fn agent_said_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  key : () -> String,
  side : () -> Double,
  top : () -> Double,
  m : () -> Message,
  found? : () -> Array[String] = fn() { [] },
  found_at? : () -> Int? = fn() { None },
  lit? : () -> (String, Int64) = fn() { ("", 0L) },
  share? : MessageShare? = None,
  code? : (String) -> ((@view.View, () -> String) -> Unit)? = fn(_) { None },
  screens? : @sf.ScreensNode,
  shown? : (@view.View, Array[(String, String, Int)]) -> Unit,
  core? : @settings.Core? = None,
  out_of? : AgentOutPlan? = None,
  piece? : () -> @sf.MdPiece? = fn() { None },
  across_of? : (Int) -> @view.Scroll = fn(_) { @view.Scroll::across() },
  tracks_of? : (Int) -> @view.TracksKept? = fn(_) { None },
  pieces_pointed? : () -> Bool = fn() { false },
  piece_made? : (@view.View) -> Unit = fn(_) {  },
  ask_sought? : () -> Bool = fn() { false },
) -> MessageRowNode {
  let menu_on : Ref[() -> Bool] = Ref(fn() { false })
  // (a piece of a long message after its first (chat_body_pieces): its blocks alone, under where its words are drawn,
  // its files and what it asks under them where it is its last; its head, picture and what it quotes the first's.
  // Which it is as it is made; the block taken for another row's piece (View::scrolls_window's `reused`) taken for one
  // of the same make (chat_body_shape), what it draws of the message read through `piece` as it is now)
  let piece_by = piece
  let piece = @signals.untracked(piece_by)
  match piece {
    Some(pc) if pc.from > 0 || (pc.rows is Some((r, _)) && r > 0) => {
      let last = pc.last
      let row = message_row_frame_node(v, key, side, top, fn(r) {
        r.box(fn(col) {
          @sf.style_node(col, fn() { msg_main })
          // (pointed at as its first piece is, that one's ⋯ shown while the pointer is on it (`piece_made`, what the
          // first's `pieces_pointed` reads); a right click on it offers what one on the first does)
          match share {
            Some(s) => {
              if !@sf.more_held() {
                col.points(Is(true)).as_ground() |> ignore
                piece_made(col)
              }
              message_menu_node(col, s)
            }
            None => ()
          }
          col.box(fn(p) {
            picked_of_by(p, key)
            @sf.style_node(p, fn() { agent_prose_piece })
            // (a piece of a message coming out of its agent's picture: its words a glyph at a time as the first's,
            // on the same clock, not there whole while the first's are still coming)
            let glyphs = out_of.bind(fn(o) { o.glyphs.val })
            agent_prose_node(p, src, here, m, found~, found_at~, lit~, code~, screens=screens.unwrap_or(agent_screens(src, here, m)), shown?, glyphs~, piece=Some(pc), piece_by~, across_of~, tracks_of~, files_too=last, share~)
          })
          |> ignore
          if last {
            agent_asks_node(col, src, here, m, core, sought=ask_sought)
          }
        })
        |> ignore
      })
      return row
    }
    _ => ()
  }
  let last = match piece {
    Some(pc) => pc.last
    None => true
  }
  let row = message_row_frame_node(v, key, side, top, fn(r) {
    // (come by data while its agent was at work: out of that agent's picture on its line (`out_of`), as emit.mbt's, each
    // step from the cause's moment: the line folds into its picture (Fold); its own picture glides there from that one
    // (Float, a flight: View::flies_in); its head and its words come out of it, the words a glyph at a time (Spit,
    // emit_out's, sfbase's glyph_in); the line unfolds again (Return))
    let out = match out_of {
      Some(plan) => Some(agent_out_steps(plan))
      None => None
    }
    let out_glyphs = out.map(fn(o) { o.glyphs })
    let (_, on) = message_others_node(
      r,
      here,
      fn() { m().time },
      fn(av) {
        // (an agent's its maker's mark; still.fail's own its mark; one of the chat's agents' with its card over it under
        // a pointer, agent_hover's: a finger's by its name)
        let pic = agent_avatar_node(
          av,
          fn() { if m().author_kind == "agent" { m().by.maker } else { "" } },
          fn() { if m().author_kind == "agent" { m().by.runtime } else { "" } },
        )
        // (as the chat's agents say it now: one they come to name after the row was made has its card from then; none in
        // a picture of the chat)
        if here.picture is None {
          message_agent_card_node(
            pic,
            src,
            here,
            fn() { if m().author_kind == "agent" { message_agent_of(here, m().by.agent) } else { "" } },
            pointed=true,
          )
        }
        // (out of its agent's picture at work: from there, Float)
        match out {
          Some(o) => (o.avatar)(pic)
          None => ()
        }
      },
      fn(h) {
        message_name_node(h, src, here, fn() { m().by.name }, fn() { message_agent_of(here, m().by.agent) }, fn() {
          m().by.from
        })
        // (out of its picture: sliding out beside it, Spit)
        match out {
          Some(o) => (o.head)(h)
          None => ()
        }
      },
      None,
      fn(b) {
        // (what it quotes ahead of its words, as the old body's)
        message_quotes_node(b, src, here, fn() { m().quotes }, fn() { m().attachments }, false, fn() { message_place(m()) }, said=fn() { m().said })
        // (its words, or the card in their place: one in the other's place as the post says)
        b.pick(fn() { agent_card_kind(m()) == "" }, fn(p, words) {
          // (what is read in it starts here, its words or the card in their place, under its head line and what it
          // quotes: what a page's list holds what shows by, where it starts (View::read_from))
          p.read_from() |> ignore
          // (and what is picked of it is of its key, what is read of it alone, not its head line: quoted by it, all of
          // it taken by 全选, chat_quote_node)
          picked_of_by(p, key)
          if words {
            // (its words and its files one piece, none apart, as the old list holds them to be picked: pickable's
            // pick_fill; a letter's, drawn by the old view alone, has them 4 apart)
            @sf.style_node(p, fn() { agent_prose_piece })
            agent_prose_node(p, src, here, m, found~, found_at~, lit~, code~, screens=screens.unwrap_or(agent_screens(src, here, m)), shown?, glyphs=out_glyphs, piece~, piece_by~, across_of~, tracks_of~, files_too=last, share~)
          } else {
            message_card_node(p, here, core, m)
          }
        })
        // (what it asks under it: its last piece's)
        if last {
          agent_asks_node(b, src, here, m, core, sought=ask_sought)
        }
      },
      share~,
      pointed_also=pieces_pointed,
    )
    menu_on.val = on
  })
  { ..row, menu_on: menu_on.val }
}

///|
/// What agent's message `m` asks under it in `b`, where it asks anything: nothing else made, as no gap is wanted for
/// nothing; a login's card where there is a core to read it with; what a go-to brings before the eyes while `sought`.
fn agent_asks_node(
  b : @view.View,
  src : Source,
  here : MessageNodeHere,
  m : () -> Message,
  core : @settings.Core?,
  sought? : () -> Bool = fn() { false },
) -> Unit {
  b.show(
    fn() {
      match decision_asks(m()) {
        Nothing => false
        Login => core is Some(_)
        _ => true
      }
    },
    fn(d) {
      // (the bell gone to it: it, whole, what the go-to brings before the eyes (View::sought), not the post's top)
      d.sought(fn() { if sought() { Some(fn(w, h) { Some((0.0, 0.0, w, h)) }) } else { None } }) |> ignore
      message_decision_node(d, src, here, m, core~)
    },
  )
}

///|
/// An agent's message's words and files (prose_with_files') in `v`, as `m` says them as they change: its words as the
/// core read their Markdown at the body's size, those `found` says in bold (and marked where `found_at` says: markdown_node's), the passage `lit` says lit where they have it; a link tapped opens where it leads (a file
/// it places, that file; a path, that file of its agent's; else the link), held (or right clicked) its menu; a bare link
/// to a chat read as that chat's title; its paths its agent's files' chips; the files it places drawn where it places
/// them (their cards); the rest of its files under its words. `code`: what draws a fenced block of a language another
/// way (none: as code); `screens`: links to a station's screens as cards (none: as links); `shown`: its links told as
/// they change (what a card over one is drawn by). `piece`: which of its blocks it draws as it is made; `piece_by`, as
/// it is now (markdown_node's).
fn agent_prose_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  m : () -> Message,
  found? : () -> Array[String] = fn() { [] },
  found_at? : () -> Int? = fn() { None },
  lit? : () -> (String, Int64) = fn() { ("", 0L) },
  code? : (String) -> ((@view.View, () -> String) -> Unit)? = fn(_) { None },
  screens? : @sf.ScreensNode,
  shown? : (@view.View, Array[(String, String, Int)]) -> Unit,
  glyphs? : ((@view.View) -> Double, (Double, @view.GlyphAt) -> @view.GlyphLook)? = None,
  piece? : @sf.MdPiece? = None,
  piece_by? : () -> @sf.MdPiece?,
  across_of? : (Int) -> @view.Scroll = fn(_) { @view.Scroll::across() },
  tracks_of? : (Int) -> @view.TracksKept? = fn(_) { None },
  files_too? : Bool = true,
  share? : MessageShare? = None,
) -> Unit {
  let place = message_files_at(here, fn() { m().said }, share=fn() { share })
  let at = fn() { message_place(m()) + "/f" }
  let by = fn() -> (String, String, String)? {
    let now = m()
    Some((now.by.name, if now.author_kind == "agent" { "agent" } else { "person" }, now.ts))
  }
  // (its files beside what it quotes; those it places by their names, the rest under its words)
  let files = fn() {
    let now = m()
    beside_quotes(now.quotes, now.attachments)
  }
  let placed = fn(name : String) -> Attachment? {
    if m().placed.contains(name) {
      files().iter().find_first(fn(a) { a.name == name })
    } else {
      None
    }
  }
  let rest = fn() {
    let names = m().placed
    files().filter(fn(a) { !names.contains(a.name) })
  }
  let on_link = fn(h : String) {
    let now = @signals.untracked(m)
    let old_here = place.here()
    match @signals.untracked(fn() { placed(@sf.file_name_of(h)) }) {
      Some(a) if is_viz(a.name) && !@sfbase.is_mbui_viz(a.name) =>
        viz_open(a.name, here.station, owner_of(old_here, a), a.path, here.session, linked=true)
      Some(a) => open_file(old_here, a, at=@signals.untracked(at))
      None =>
        match @sf.path_of_link(h) {
          Some((path, _)) => open_named(src, here.station, now.by.agent, path)
          None => open_link(h)
        }
    }
  }
  let on_hold = fn(href : String, at : (Double, Double, Double, Double)) {
    match @sf.path_of_link(href) {
      Some((path, _)) => message_path_held(src, here.station, @signals.untracked(m).by.agent, path, at)
      None => message_link_held(href, at)
    }
  }
  v.show(fn() { m().text != "" }, fn(w) {
    // (coming out of its agent's picture: none of it drawn till its words start to come out (emit.mbt's Spit), each glyph
    // seen as it comes, never its lines laid out unseen over the list before then)
    match glyphs {
      Some((since, _)) => w.alpha(By(fn() { if since(w) > 0.0 { 1.0 } else { 0.0 } })) |> ignore
      None => ()
    }
    @sf.markdown_node(
      w,
      fn() { m().text },
      tree=fn() { m().md },
      size=fn() { body_size },
      found~,
      found_at~,
      lit~,
      // (its tables slid sideways out over the row's side to the pane's edge: the side as the list is laid out now, a
      // binding: the pane resized or the side panel opened moves its tables' ends, the same nodes; none in a picture)
      bleed=fn() { if here.picture is Some(_) { 0.0 } else { row_side((here.width)()) } },
      // (none of its tables' copy keys in a picture of the chat; its tables fitted to the picture taken)
      copy=here.picture is None,
      fit_tables=here.picture is Some({ taking: true, .. }),
      on_link~,
      on_link_hold=Some(on_hold),
      on_link_shown?=shown,
      // (each link's card while a mouse rests on it: link_peeks', its agent's files read in its working directory)
      link_cards=(here.tips, message_link_card(src, here.station, fn() { m().by.agent }, m)),
      chat_title=fn(h) { chat_title_of(m())(h) },
      // the files its paths name are its agent's (Chat.tsx ProseWithFiles' PathSession): their chips
      paths=@signals.untracked(m).by.agent != "",
      glyphs~,
      // (a file it places: its card where it places it; a picture's its box, side by side with others, in a table's cell)
      files=fn(name) {
        let card = fn(a) {
          fn(d) { message_files_node(d, src, here.tips, place, fn() { [a] }, fn() { false }, by, at) }
        }
        match placed(name) {
          // an HTML page: drawn as a page where it is placed (message_viz_node), its card where it cannot be read; in a
          // picture of the chat being shared, as that draws it (publish.mbt)
          Some(a) if is_viz(a.name) =>
            Some({
              draw: fn(d) {
                let ts = @signals.untracked(m).ts
                match here.picture {
                  Some(pic) => (pic.viz)(d, ts, a, card(a))
                  None =>
                    message_viz_node(d, src, here.tips, here.station, here.session, owner_of(place.here(), a), ts, a, card(a))
                }
              },
              image: None,
            })
          // (in a picture of the chat being shared, a picture it places as its file (its own ✕ on the page): publish.mbt)
          Some(a) if here.picture is Some(_) => Some({ draw: card(a), image: None })
          // (a picture: its width over its height and its box as wide as it is given there, side by side with others or
          // in a table's cell; its size bound to that width, the same nodes as it changes, as message_files_node's)
          Some(a) =>
            Some({
              draw: card(a),
              image: image_ratio(a).map(fn(r) {
                (r, fn(d : @view.View, width : () -> Double) {
                  message_image_node(d, src, place, fn() { a }, by, at, width, fn() { width() / r })
                })
              }),
            })
          None => None
        }
      },
      code~,
      screens?,
      piece~,
      piece_by?,
      across_of~,
      tracks_of~,
    )
    |> ignore
    // (words streamed in by the core, each a change of what it had answered: where they come out another height (a
    // line more), that height makes its way, the list's (in a page's list its set-out, those over it going up with it on
    // its way, as the old list's Changed did); the same height, nothing (View::resizes). An answer's first words are
    // there at once, as ever (answering.mbt). Only words streamed on (the words before them still there at their start):
    // a message's words set again to others are no stream, nothing of the list set out for them, none of its other
    // rows read again; nor another message's, a block put by and taken for another row (View::scrolls_window's
    // `reused`), whatever its words begin with)
    let streamed = Ref(@signals.untracked(fn() { (m().ts, m().text) }))
    w.reacts(fn() { (m().ts, m().text) }, fn(now) {
      let (ts, text) = now
      let (was_ts, was) = streamed.val
      streamed.val = now
      if ts == was_ts && text.length() > was.length() && text.has_prefix(was) {
        w.resizes() |> ignore
      }
    }, at_start=false)
  })
  // (the rest of its files under its words: under its last piece's, where it is in pieces)
  if files_too {
    message_files_node(v, src, here.tips, place, rest, fn() { false }, by, at, over=fn() { if m().text != "" { files_under_words } else { 0.0 } })
  }
}

///|
/// What an agent said and its files under it in a chat's list: one piece, none apart (sfbase's pick_fill, pickable's
/// box round them).
// kept across runs: a value (no field of it changes)
let agent_prose_piece : @ui.Style = @ui.css("w=Full")

///|
/// A file a message names by its path (`path`, its agent `agent`'s on `station`) held (or right clicked: path_held's),
/// its menu by the piece of line under the hand (`at`, in the window): 在侧边打开 where it is offered (beside_offered: a
/// side panel for the chat, a file, a kind that opens there); else nothing.
fn message_path_held(src : Source, station : String, agent : String, path : String, at : (Double, Double, Double, Double)) -> Unit {
  if path.has_suffix("/") || !@sfbase.beside_offered(path, stored_name(path)) {
    return
  }
  @sf.menu_held_node()
  @sf.menu(
    [
      Some(
        @sf.menu_item_of(@sf.t("web-main.preview.openBeside"), fn() { open_named(src, station, agent, path, beside=true) }, icon="panel-open"),
      ),
    ],
    from=At(at.0, at.1, at.2, at.3),
  )
}

///|
/// What an agent's message coming out of its picture at work does (agent_said_node's `out_of`; emit.mbt's poses, each
/// from the cause's moment): its glyphs' look as they come (Spit: emit_out's, sfbase's glyph_in, read a line at a time
/// and along it), its picture's way from that one (Float), its head's coming out beside it (Spit).
priv struct AgentOut {
  glyphs : ((@view.View) -> Double, (Double, @view.GlyphAt) -> @view.GlyphLook)
  avatar : (@view.View) -> Unit
  head : (@view.View) -> Unit
}

///|
/// When an agent's message coming by data comes out of its agent's picture at work (emit.mbt's poses, one message at a
/// time an agent): the moment it came (`came`), whether its agent's line folds to its picture first (`folds`: the
/// first of a run; a later one comes while the picture is still out, and the picture drops on to it from the one before,
/// not going home first), when the picture sets out for it (`float_at`) and how long it takes there (`float_ms`: Float's,
/// or the drop's), when the message is out (`spit_end`), what its picture flies from (`from`: the line's picture, or
/// the message before's), its own picture as its row makes it (`av`: what the line's picture flies home from, and
/// a later one drops on from), and its glyphs' look as they come (`glyphs`, its first piece's: the pieces after it come
/// on the same clock). Worked out as its key comes (agent_out_plan), the same for its row and for the list's way.
priv struct AgentOutPlan {
  came : Double
  folds : Bool
  float_at : Double
  float_ms : Double
  spit_end : Double
  from : () -> (Double, Double, Double, Double)
  /// where the line's picture was as the message came into the list (its plan's Float: the list's held keys let it in,
  /// the line going in that change): what it flies from, whatever becomes of the line after
  face_at : Ref[(Double, Double, Double, Double)?]
  av : Ref[@view.View?]
  glyphs : Ref[((@view.View) -> Double, (Double, @view.GlyphAt) -> @view.GlyphLook)?]
}

///|
/// The plan of agent `face`'s message coming by data at `now` (AgentOutPlan): after its last one, while that is still
/// coming out (its words not all out of the picture yet), the picture drops on from that one's at its end; else the
/// line folds to its picture from now and the picture sets out from it once folded. Told to `face` as its last.
fn agent_out_plan(face : AgentFace, now : Double) -> AgentOutPlan {
  let plan = match face.last.val {
    Some(prev) if prev.spit_end > now => {
      let float_at = prev.spit_end
      let float_ms = @sfbase.emit_drop_ms
      let av = prev.av
      {
        came: now,
        folds: false,
        float_at,
        float_ms,
        spit_end: float_at + float_ms + @sfbase.Pose::Spit.ms(),
        from: fn() {
          match av.val {
            Some(v) if v.alive() => v.laid_window_now()
            _ => agent_face_at(face)
          }
        },
        face_at: Ref(None),
        av: Ref(None),
        glyphs: Ref(None),
      }
    }
    _ => {
      let float_at = now + @sfbase.Pose::Fold.ms()
      let float_ms = @sfbase.Pose::Float.ms()
      {
        came: now,
        folds: true,
        float_at,
        float_ms,
        spit_end: float_at + float_ms + @sfbase.Pose::Spit.ms(),
        from: fn() { agent_face_at(face) },
        face_at: Ref(None),
        av: Ref(None),
        glyphs: Ref(None),
      }
    }
  }
  face.last.val = Some(plan)
  plan
}

///|
/// Where agent `face`'s picture on its line is in the window now: its picture's own box, as a message's picture is
/// (else its line's picture's box).
fn agent_face_at(face : AgentFace) -> (Double, Double, Double, Double) {
  match face.pic.val {
    Some(v) if v.alive() => v.laid_window_now()
    _ => face.face.laid_window_now()
  }
}

///|
/// An agent's message come out of its agent's picture at work as `plan` says (emit.mbt's poses), its row made as
/// it comes into the list, at the plan's Float (held out of it till then: chat_body_node's held keys, where the line
/// folded into its picture meanwhile, Fold): the message's own picture flies from that one (or from the message before
/// it, dropping on) to its place as the line's picture is away (Float, a flight: View::flies_in, from rest to rest);
/// its head slides out beside it and its words come a glyph at a time (Spit), each on the plan's clock, as data. Its
/// going home after is the list's at the plan's end (agent_out_return).
fn agent_out_steps(plan : AgentOutPlan) -> AgentOut {
  // (how long since it came out, ms: its words and head by it, nothing before; out once its picture is there)
  let since = @motion.Way::new(0.0)
  // det-ok(motion-length): emit.mbt's Spit, its words a glyph at a time from where its picture lands
  since.go(1.0, @motion.tween(@sfbase.emit_out_ms_most, ease=Linear, delay=plan.float_ms), at=plan.float_at)
  let salt = 7
  let glyphs = (fn(w : @view.View) { since.shown_on(w) * @sfbase.emit_out_ms_most }, fn(ms : Double, g : @view.GlyphAt) {
    @sfbase.glyph_in(ms, (g.line.to_double() + g.cx / 600.0) * @sfbase.glyph_line_ms, g.index, salt)
  })
  // (the pieces after its first read these: agent_said_node's `piece`)
  plan.glyphs.val = Some(glyphs)
  {
    glyphs,
    avatar: fn(av) {
      plan.av.val = Some(av)
      // (from where the line's picture is, or the message's before, over Float's time from the plan's Float on)
      av.flies_in(after(@sf.dmax(plan.float_at - av.cause_at(), 0.0), plan.float_ms), fn(_) {
        Some(plan.face_at.val.unwrap_or_else(plan.from))
      })
      |> ignore
    },
    head: fn(h) {
      h.alpha(By(fn() { @ui.Ease::Out.at(dmin_one(since.shown_on(h) * @sfbase.emit_out_ms_most / @sfbase.emit_head_ms)) }))
      |> ignore
    },
  }
}

///|
/// The plan `plan` of a message out of agent `face`'s picture at its end (its Spit over: emit.mbt's Return), told by the
/// list at that moment: where no later message of the agent's came meanwhile and the line goes on under it (its turn not
/// ended by it: `ending` false), the line's picture flies home from the message's and the line unfolds once it is there
/// (as long as a Move of its way: the further the longer), on that clock from that moment. A message that ends its turn
/// leaves the line folded and its picture away: the line is leaving, never seen again under the message for a moment.
fn agent_out_return(face : AgentFace, plan : AgentOutPlan, ending : Bool) -> Unit {
  guard !ending else { return }
  // (a later message of the agent's came meanwhile: the picture drops on to it, not home)
  guard face.last.val is Some(l) && physical_equal(l.av, plan.av) else { return }
  let back_ms = match plan.av.val {
    Some(av) if av.alive() => {
      let from = av.laid_window_now()
      let home = agent_face_at(face)
      // (its own picture home from where the message's is now, in this change: View::flies_in)
      match face.pic.val {
        Some(own) if own.alive() => own.flies_in(agent_home_flight, fn(_) { Some(from) }) |> ignore
        _ => ()
      }
      agent_home_ms(from, home)
    }
    _ => 0.0
  }
  face.away.set(false)
  // det-ok(motion-length): emit.mbt's Return, the line unfolding once its picture is home
  face.fold.go(1.0, @motion.tween(@sfbase.Pose::Return.ms(), ease=Out, delay=back_ms), at=plan.spit_end)
}

///|
/// How long the line's picture takes home from where it let a message out (`from`) to its own place (`home`): Return's
/// over its usual way (agent_way_points, a row or two), longer or shorter as a Move of it is (emit.mbt's return_ms).
fn agent_home_ms(from : (Double, Double, Double, Double), home : (Double, Double, Double, Double)) -> Double {
  let far = @sf.dmax((home.0 - from.0).abs(), (home.1 - from.1).abs())
  (@sfbase.Pose::Return.ms() * @ui.move_ms(far) / @ui.move_ms(agent_way_points)).round()
}

///|
/// The picture's usual way home (points): what Return's length is of (emit.mbt's emit_way_points).
let agent_way_points : Double = 100.0

///|
/// The line's picture flying home (Return): from rest to rest, as long as agent_home_ms has it for how far it goes.
// det-ok(motion-length): emit.mbt's Return, sf/motion.mbt kind 4
// kept across runs: constant flight curve
let agent_home_flight : @view.Flight = {
  way: fn(far) {
    let ms = (@sfbase.Pose::Return.ms() * @ui.move_ms(far) / @ui.move_ms(agent_way_points)).round()
    (ms, fn(t) { @ui.Ease::InOut.at(dmin_one(t / ms)) })
  },
}

///|
/// A flight still for `wait` ms, then on over `ms` (emit.mbt's Float: a glide from rest to rest).
fn after(wait : Double, ms : Double) -> @view.Flight {
  { way: fn(_) { (wait + ms, fn(t) { if t <= wait { 0.0 } else { @ui.Ease::InOut.at(dmin_one((t - wait) / ms)) } }) } }
}

///|
fn dmin_one(x : Double) -> Double {
  if x > 1.0 {
    1.0
  } else {
    x
  }
}
