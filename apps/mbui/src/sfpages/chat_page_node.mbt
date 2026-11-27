// A chat's page made with its inside nodes (chat_page_made's `body`): its messages the
// page's list (chat_body_node), the composer in the list's foot the page's old view as yet, what floats over it there
// (the way to the newest, the bell, 对话目录's button and rail: chat_body_node's foot), a passage picked in a message
// quoted by its pill or the bar over a finger's pick (chat_quote_node).

///|
/// Chat `r`'s messages as `src` reads them (view_of_chat), in node `v`, growing to what the column it is in leaves
/// them, once its view is read (while it is read the first time, its messages to come in their bones and what failed
/// over them in red: chat_messages_sample_node, waiting_node), laid out by the room the column gives it
/// (View::by_room: its width what the shell gives the page, as it changes), under the chat's bar, `cover` tall (where
/// it is drawn to, what hides the list's top), `room` more over its first row, `foot` under its last and the composer
/// `composer` builds under that, in the list's foot (till the view is read, at the foot of the room it is given),
/// `lead` the unread line under its top, its tips `tips`, its time on top `stint`;
/// what is read told the core while `shows` (chat_read_node). `cover_to`: how tall what covers it comes to be, as
/// chat_body_node takes it.
pub fn chat_page_body_node(
  v : @view.View,
  src : Source,
  r : ChatRef,
  tips~ : @sf.TipLayer,
  stint~ : () -> Int,
  shows~ : () -> Bool,
  visible? : () -> Bool,
  cover? : () -> Double = fn() { bar_foot },
  cover_to? : () -> Double,
  room? : Double = list_room,
  foot? : () -> Double = fn() { list_foot },
  foot_clear_extra? : () -> Double = fn() { 0.0 },
  composer? : (@view.View) -> Unit,
  lead? : Double = unread_lead,
  on_stack? : () -> Bool = fn() { true },
) -> Unit {
  // (what changes on it moves only for a cause said (a press, a key, a live cause its list judges so): what the core
  // brings or a page coming to show is there at once, @view.transition)
  v.transitions_only() |> ignore
  let draft = r.station + ":" + r.session
  let w = @signals.untracked(fn() { @sfbase.writing(src, draft) })
  // the chat's keys (keymap.ts's chat group: the keymap's Chat), its actions here, taken while the tree gives the page
  // keys: Space with no field focused, the cursor in the composer (composer.focus, taken as it is next built); ⌘U the
  // system's file picker for its draft (composer.file) but where the chat is offline; ⌘↓ the list's (chat_body_node)
  v.key_context("Chat")
  .on_action("composer.focus", fn(e) {
    // (the page brought over first where the tape has it behind, at the key's moment, so that its composer takes keys;
    // then at once where its old view's field is drawn, Field::focus; asked of it as it is next built where it is not)
    (@sfbase.page_for_key.val)(e.at)
    w.field.focus()
    composer_take_focus()
    @sfbase.draft_given(draft)
    true
  })
  .on_action("composer.file", fn(_) {
    guard @sfbase.chat_view_now(src, r) is Some(cv) && !cv.offline else { return false }
    pick_files(w)
    true
  })
  |> ignore
  // what is let go on it from outside, wherever (a message, its ground; mbui's Tree::drop_at), but on a field (a field
  // takes words where they were let go) or on the composer (its old view's capsule takes them itself): files from this
  // machine's Finder, where it is a station, into the draft by their station and path, as a row of the 文件 tab put
  // there (its composer takes them: draft_give); words dragged in from another app into the composer's field at its
  // caret, as a paste's
  // (by where they are only where this machine is a station of the chat's workspace, finder_by_station_in: elsewhere,
  // or where the host says no paths, read and put in as files picked are, picked_files_into)
  @ui.paths_into(
    v,
    w.field,
    fn(paths) {
      @sfbase.files_into_many(draft, @sfbase.finder_dragged(src, paths))
    },
    takes=fn() { @sfbase.finder_by_station_in(@sfbase.workspace_of(r.station)) },
  )
  |> @ui.files_into(w.field, fn(files) { @sfbase.picked_files_into(draft, files) })
  |> @ui.words_into(w.field)
  |> ignore
  // its words in pieces picked with the pointer (@ui.words_picked), as the old page's in its frame are (c.selectable):
  // nothing that holds it on any screen says so (a settings page's host does: context_node, made_at), a passage of a
  // message quoted from there (chat_quote_node)
  @ui.words_picked(v)
  // (its view and entries as last read: once read, never none again while the page is)
  // (the chat's messages by key where the source keeps them so (sfbase's ChatMessages): then, while nothing sent from
  // here is on its way and its outbox is empty, its view is its head alone (sfbase's chat_head: a message patched in
  // place reads none of it again) and its rows are by key (chat_body_keyed); else its view and entries whole, as
  // view_of_chat works them out)
  let sending = fn() { @sfbase.sending_now(r.station + "\u{1}" + r.session) }
  // (put by at rest (View::on_rest): what it last read given to whatever reads it meanwhile, the chat read for none of
  // it; and read anew as it wakes, what reads it told then)
  let at_rest = Ref(false)
  let woken : @signals.Signal[Int] = @signals.signal(0)
  let read : @signals.Computed[(ChatView, Array[Entry])?] = @signals.computed(
    fn(was) {
      woken.get() |> ignore
      if at_rest.val {
        match was {
          Some(w) => return w
          None => ()
        }
      }
      // (the head read first: what holds the topic, whose messages by key are then there; the chat a new chat became
      // as view_of_chat makes it, never said to be empty, till the core's view of it holds a message: sfbase's
      // chat_keyed_now)
      let head = match @sfbase.chat_head(src, r) {
        (Some(h), _) =>
          match @sfbase.chat_messages(src, r) {
            // (what is on its way from here answering its last card: as the core will say once it has it)
            Some(ms) if @sfbase.chat_keyed_now(r, ms) => Some((@sfbase.chat_sent_here(r, h, ms).0, chat_no_entries))
            _ => None
          }
        _ => None
      }
      let next = match head {
        Some(h) => Some(h)
        None =>
          match @sfbase.view_of_chat(src, r) {
            (Some(view), entries, _) => Some((view, entries))
            _ =>
              match was {
                Some(w) => w
                None => None
              }
          }
      }
      // (the same head the same object as before, worked out anew as the page is woken from rest (its read let go of
      // as it was put by): what reads it finds it as it left it, nothing of the page worked out again for it)
      match (was, next) {
        (Some(Some((pv, pe)) as prev), Some((nv, ne))) if physical_equal(pe, ne) &&
          (physical_equal(pv, nv) || (physical_equal(ne, chat_no_entries) && pv == nv)) => prev
        _ => next
      }
    },
    // (told only as the view or its entries are other ones: the chat's list keeps both while nothing of it changed,
    // sfbase's chat_read; another topic's change reads none of the rows again)
    same=fn(a, b) {
      match (a, b) {
        (Some((v1, e1)), Some((v2, e2))) => physical_equal(v1, v2) && physical_equal(e1, e2)
        (None, None) => true
        _ => false
      }
    },
  )
  // (what it read let go of where nothing follows it as the page is put by at rest, as it is let go, and after its chat is
  // told left (chat_read_left reads it once more): read untracked, it held the chat; worked out anew as it is read
  // again, from what it last was)
  let read_rest = fn() { if !read.watched() { read.dispose() } }
  let tag_visit : Ref[(Double, Int)?] = Ref(None)
  let leave_tag_visit = fn() {
    match tag_visit.val {
      Some((th, vis)) => {
        @sfbase.classify_leave_chat(r.station, th, vis)
        tag_visit.val = None
      }
      None => ()
    }
  }
  let enter_tag_visit = fn() {
    match @signals.untracked(fn() { read.get() }) {
      Some((cv, _)) if cv.projects =>
        match cv.thread {
          Some(th) if tag_visit.val is None =>
            tag_visit.val = Some((th, @sfbase.classify_enter_chat(r.station, th)))
          _ => ()
        }
      _ => ()
    }
  }
  v.on_leaving(leave_tag_visit) |> ignore
  v.on_rest(
    fn() {
      at_rest.val = true
      leave_tag_visit()
      read_rest()
    },
    wake=fn() {
      at_rest.val = false
      woken.set(woken.untracked() + 1)
      enter_tag_visit()
      // (shown again from where it was put by, its `shows` the same as it rested so the reaction under tells nothing:
      // its pictures that could not be had asked again, as it comes into view)
      src.images.again(r.station)
    },
  )
  |> ignore
  // its pictures that could not be had for want of its station asked again as the chat comes into view (made, or shown
  // again from under what covered it), and as its station is reached again (ChatImages::seen, as its view says it
  // offline or not), as the old page's list asks them (chat_list's)
  // (and as it is woken, taken back from the stack's kept left: shown as it was, its pictures asked again all the same)
  v.reacts(fn() { (shows(), woken.get()) }, fn(now) { if now.0 { src.images.again(r.station) } })
  // (whether it shows, lent to what its rows make: a screen's card previews it only while it does, screen_links_node's)
  v.lends(@sfbase.page_shows_lent, shows) |> ignore
  v.reacts(fn() { read.get().map(fn(x) { !x.0.offline }) }, fn(reached) {
    match reached {
      Some(b) => src.images.seen(r.station, b)
      None => ()
    }
  })
  let feedback_held = @sfbase.topic_value_held(src, "chatFeedback", @sfbase.chat_params(r))
  // (read chatFeedback once the chat head has answered, outside by_room so its subscription order relative to
  // chat_bar_node's chatRow is deterministic across 7 / 60 / 120 fps rather than racing the first layout frame)
  v.reacts(fn() { read.get() is Some(_) }, fn(loaded) {
    if loaded {
      feedback_held.get() |> ignore
      enter_tag_visit()
    }
  })
  // (its rows by the width it is given, never one worked out of the shell's state)
  v.by_room(fn(b, given) {
    b.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    let width = fn() { given.width() }
    // (the composer at the foot of the room before the view is read, in the list's foot once it is: one pick, so that
    // the one before the view is let go of before the one in the list's foot is made, never both at once; the cursor
    // it had, or was to take, taken by the one after it)
    // (a chat of a workspace the viewer is not in, a link's: never its rows, whatever the core holds of it, but why it
    // cannot be read and what to do)
    let ws = match r.station.find("/") {
      Some(i) => r.station.exact_view(end=i).to_owned()
      None => ""
    }
    b.pick(at_once=true, fn() { read.get() is Some(_) && @sfbase.workspace_joined(src, ws) }, fn(o, loaded) {
      guard loaded else {
        // (not in its workspace: why and what to do in the middle of the room, nothing waited for, nothing to write)
        if !@signals.untracked(fn() { @sfbase.workspace_joined(src, ws) }) {
          o.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).lies_along(Is(Middle)) |> ignore
          @sf.empty_state_node(o, "user-plus", fn() { @sf.t("android-chat.chat.notJoined") }, note=fn() {
            @sf.t("android-chat.chat.notJoined.note")
          })
          |> ignore
          return
        }
        o.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).lies_along(Is(End)) |> ignore
        let error_text = fn() {
          match src.topic("chat", @sfbase.chat_params(r)).get().error {
            Some(e) => {
              let msg = match e {
                String(s) => s
                _ => @sfbase.text(Some(e), "message")
              }
              @sf.t("android-chat.chat.unreadable", args=[("error", msg)])
            }
            None => ""
          }
        }
        // a chat just made from a new chat (its scene leaving, its first words on their way) is the core's own:
        // nothing to read from a station, nothing breathing for the frames until the core's view of it comes
        let from_fresh = fn() {
          @sfbase.fresh.became.get() == Some(r) ||
          (@sfbase.fresh.sending.get() && @sfbase.fresh.made.get() == r.session)
        }
        let visible = visible.unwrap_or(shows)
        let since = o.cause_at()
        let waited = @sf.waited_past_node(
          o,
          fn() { since },
          @sf.later_ms,
          going=fn() { visible() && !from_fresh() && error_text() == "" },
        )
        o.show(at_once=true, fn() { error_text() != "" || (!from_fresh() && waited()) }, fn(s) {
          s
          .grow(Is(1.0))
          .shrink(Is(1.0))
          .basis(Is(Some(0.0)))
          .min_height(Is(Some(0.0)))
          .clip()
          .padding(By(fn() { (0.0, cover(), 0.0, 0.0) }))
          |> ignore
          @sf.waiting_node(
            s,
            fn(bones) { chat_messages_sample_node(bones, width, tips, stint, top=room) },
            error=error_text,
            fill=true,
          )
        })
        match composer {
          Some(build) => {
            // (whether its field had the cursor, as it last said: what its field's going tells first is not the person's)
            let had = Ref(false)
            o.owns(fn() {
              if had.val || w.field.focused() || composing.wanted {
                composer_take_focus()
                composing_node.shown = ""
              }
            })
            |> ignore
            build(o)
            o.reacts(fn() { w.field.focused() }, fn(f) { if o.alive() { had.val = f } })
          }
          None => ()
        }
        return
      }
      o.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
      let first = @signals.untracked(fn() { read.get().unwrap() })
      let view = fn() {
        match read.get() {
          Some((view, _)) => view
          None => first.0
        }
      }
      let here : MessageNodeHere = {
        station: r.station,
        session: r.session,
        view,
        width,
        tips,
        stint,
        // (a quote's card pressed: the message it quotes gone to, and the passage it quotes lit there alone where its
        // words have it, as the old page's cards (message.mbt quote_cards): chat_goes_to; where the chat's window holds
        // it not, the window moved about it first (chat.around by its ts), said where the chat has it nowhere:
        // sfbase's go_to_quoted)
        jump: Some(fn(ts, passage) {
          let msgs = chat_said_all(src, r, view)
          let mut shown : Double? = None
          for i = 0; i < msgs.length(); i = i + 1 {
            if msgs[i].ts == ts {
              shown = Some(msgs[i].seq)
              break
            }
          }
          @sfbase.go_to_quoted(src, r, @signals.untracked(view).thread, shown, ts, passage)
        }),
        picture: None,
      }
      // (the workspace in view, else, where none is read yet, the one the chat's station is of)
      let ws = @signals.untracked(fn() {
        let (now, all, _, _) = @sfbase.workspace_in_view(src)
        match now {
          Some(w) => Some(w)
          None =>
            match r.station.find("/") {
              Some(i) => {
                let id = r.station.exact_view(end=i).to_owned()
                all.iter().find_first(fn(w) { w.id == id })
              }
              None => None
            }
        }
      })
      // (none read yet at all: the chat's station's workspace by its id alone, so the chat's settings still reach it)
      let ws = ws.unwrap_or({ id: @sfbase.workspace_of(r.station), name: "", emoji: "", icon: "", email: "" })
      let core = Some(@sfbase.settings_core(src, ws))
      chat_body_node(
        o,
        src,
        here,
        fn() {
          match read.get() {
            Some((_, entries)) => entries
            None => first.1
          }
        },
        sending~,
        core~,
        cover~,
        cover_to?,
        room~,
        // (and while something waits to be decided whose bell may float over the list's end, its room over it: the last
        // row as far over the bell as it is over the composer without it, as the page before kept it (chat_list's
        // `ask_clear`))
        foot=fn() { foot() + (if @sfbase.ask_clears((here.view)()) { float_ask_clear } else { 0.0 }) },
        foot_clear_extra~,
        feedback_held~,
        composer?,
        lead~,
        read=fn(place, scroll, rows, reopening, on_reopened) {
          chat_read_node(o, src, r, view, place, scroll, rows, shows, cover, fn() { cover() + room }, rest=read_rest, reopening~, on_reopened~, on_stack~)
        },
        to=r,
        shows~,
        // (by key once the view is the chat's head (its entries none: chat_no_entries), as the core's view of a chat a
        // new chat became comes, the same list going on from what was sent from here)
        msgs=fn() {
          // (its topic's version followed too: a subscription made anew gives its list once its first answer comes, the
          // same head read or not)
          src.topic("chat", @sfbase.chat_params(r)).get().version |> ignore
          match read.get() {
            Some((_, entries)) if physical_equal(entries, chat_no_entries) =>
              @signals.untracked(fn() { @sfbase.chat_messages(src, r) })
            _ => None
          }
        },
      )
      |> ignore
    })
  })
  .grow(Is(1.0))
  .shrink(Is(1.0))
  .basis(Is(Some(0.0)))
  .min_height(Is(Some(0.0)))
  |> ignore
}

///|
/// The made-up messages of chat_messages_sample_node: whether each is the viewer's, and how long each of its paragraphs
/// is (letters): a short ask, an answer of a few lines, and so on, as a chat goes.
// kept across runs: a table, never written
let sample_messages : Array[(Bool, Array[Int])] = [
  (true, [14]),
  (false, [70, 36]),
  (true, [22]),
  (false, [110, 48, 24]),
  (true, [9]),
  (false, [56]),
]

///|
/// A chat's messages to come while it is read the first time (the library's waiting_node, in its bones): made-up
/// messages as its list draws them (mine_said_node, agent_said_node: the viewer's in their bubble, an agent's words
/// under its picture, name and time), as far apart and as far in as the list has them, `top` over the first as over the
/// list's first row.
fn chat_messages_sample_node(
  v : @view.View,
  width : () -> Double,
  tips : @sf.TipLayer,
  stint : () -> Int,
  top~ : Double,
) -> Unit {
  let side = fn() { row_side(width()) }
  let gap = fn() { if width() <= chat_narrow_w { list_gap_narrow } else { list_gap } }
  let view = @sfbase.chat_view_made({ "title": Json::string(""), "messages": [] })
  let here : MessageNodeHere = {
    station: "",
    session: "",
    view: fn() { view },
    width,
    tips,
    stint,
    jump: None,
    picture: None,
  }
  v
  .fills_across(Is(true))
  .shrink(Is(1.0))
  .basis(Is(Some(0.0)))
  .min_height(Is(Some(0.0)))
  .clip()
  |> ignore
  v.box(fn(t) { t.height(Is(Some(top))) |> ignore }) |> ignore
  for i, m in sample_messages {
    let (mine, lines) = m
    let words = lines.map(@sf.sample_words)
    let key = "sample/" + i.to_string()
    let said = @sfbase.message_of({
      "ts": Json::string(key),
      "authorKind": Json::string(if mine { "person" } else { "agent" }),
      "mine": Json::boolean(mine),
      "text": Json::string(words.join("\n\n")),
      "md": Json::array(words.map(fn(w) { Json::array([Json::string("p"), Json::array([Json::string(w)])]) })),
      "by": { "name": Json::string(@sf.sample_words(if mine { 2 } else { 6 })), "maker": { "id": "anthropic" } },
      "time": { "createdAt": { "ago": Json::string(@sf.sample_words(3)), "full": "" } },
    })
    let row_top = if i == 0 { fn() { 0.0 } } else { gap }
    if mine {
      mine_said_node(v, @sfbase.sample_source, here, fn() { key }, side, row_top, fn() { said }) |> ignore
    } else {
      agent_said_node(v, @sfbase.sample_source, here, fn() { key }, side, row_top, fn() { said }) |> ignore
    }
  }
}
