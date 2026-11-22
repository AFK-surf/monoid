// What a post asks, under it in its chat, and what the chat needs of the viewer at its end, as nodes of the window's
// tree (decision.mbt's message_decision, decision_options, ask_dismiss, card_history; chat_rows.mbt's chat_state,
// need_card): each made once as what it reads says, following the message and the core as they change. Who decides,
// the options while it waits for the viewer (pressing one answers with it: decision.answer; the one on its way turning,
// the core's doing), 忽略 under them (decision.dismiss); once settled, how it went in one quiet line, pressed for the
// original card; a login's card (login_card_node) with who is to finish it and 忽略 under it. What comes and goes under
// the post comes and goes as anything down a column does (View::show: its way from the moment the message or the core
// changed, the framework's; the old under_post's own fades and the list's turns are not here). A vault item's approval
// (a card from before its station said what it asks) in its options' place: settings' vault_actions_node. The cards in
// place of a post's words: message_cards_node.mbt.

///|
/// What is under a post, as the message says it now.
#derive(Eq)
priv enum Asks {
  /// nothing to ask, or what is asked is in place of its words (a vault item, a phone, a sign-in, a rig: their cards')
  Nothing
  /// an agent's need with no card: 忽略 alone
  Alone
  /// who decides, its options (or a vault item's approval in their place), 忽略, how it went
  Options
  /// who decides, a field to write the answer in and 回复 (a text card: `decision.reply`), 忽略, how it went
  Text
  /// a login's card, who is to finish it, 忽略 under it (where there is a core to read the login of)
  Login
}

///|
/// What post `m` asks under it (message_decision's cases).
fn decision_asks(m : Message) -> Asks {
  match m.card {
    Some({ kind: "login", login, .. }) if login != "" => Login
    None if m.options is None => if m.asked { Alone } else { Nothing }
    Some({ ask: Some(_), .. }) | Some({ phone: Some(_), .. }) | Some({ signin: Some(_), .. }) | Some({ rig: Some(_), .. }) =>
      Nothing
    Some({ kind: "text", vault: "", .. }) => Text
    _ => Options
  }
}

///|
/// Whether post `m` is settled: answered or let go, as the core says.
fn decision_settled(m : Message) -> Bool {
  match m.decision {
    Some(d) => d.resolved || d.dismissed
    None => false
  }
}

///|
/// The options post `m` gives: its card's, where it is a card of options, else its own.
fn decision_choices(m : Message) -> Array[Choice] {
  let list = match m.card {
    Some(card) => if card.kind == "options" { card.options } else { None }
    None => m.options
  }
  list.unwrap_or([])
}

///|
/// The chat's thread where something can be sent there (not offline, not archived), as its view says now.
fn decision_thread(here : MessageNodeHere) -> Double? {
  let view = (here.view)()
  if view.offline || view.archived {
    None
  } else {
    view.thread
  }
}

///|
/// Under post `m` (as it says as it changes) of the chat `here` is, what it asks (message_decision's, as nodes): who
/// decides, its options while it is open and the chat's thread can be sent to, 忽略 while it is asked, and how it went
/// once settled, one in the others' place as that changes; a login's card, read with `core` (the settings' over the
/// chat's workspace; None where nothing is answered: a login's post is then as one with no options).
fn message_decision_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  m : () -> Message,
  core? : @settings.Core? = None,
) -> Unit {
  v.pick(
    fn() {
      match (decision_asks(m()), core) {
        (Login, None) => Options
        (asks, _) => asks
      }
    },
    fn(p, asks) {
      match (asks, core) {
        (Alone, _) =>
          p.box(fn(b) {
            @sf.style_node(b, fn() { decision_box })
            ask_dismiss_node(b, src, here, fn() { m().seq }, fn() { m().asked }, fn() { false }, fn() { true }, false)
          })
          |> ignore
        (Options, _) | (Text, _) => decision_rooms_node(p, src, here, m, core)
        (Login, Some(core)) => decision_login_node(p, src, here, core, m)
        _ => ()
      }
    },
  )
}

///|
/// Under post `m`, its login's card (message_decision's login case, as nodes): who is to finish it while it is open, the
/// card (login_card_node) on the chat's station or another of its workspace (the card's `station`), as the core says it
/// now, and 忽略 under it while it is asked.
fn decision_login_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  core : @settings.Core,
  m : () -> Message,
) -> Unit {
  let open = fn() {
    match m().decision {
      Some(d) => !d.resolved && !d.dismissed
      None => true
    }
  }
  // (on the chat's station, or another of its workspace: the card's)
  let login = fn() {
    let card = m().card
    let id = card.map(fn(c) { c.login }).unwrap_or("")
    let other = card.map(fn(c) { c.station }).unwrap_or("")
    (@sfbase.card_login_station(here.station, other), id)
  }
  v.box(fn(b) {
    @sf.style_node(b, fn() { decision_box })
    // (who is to finish it goes with the card as the login ends, as the old view's does (decision.mbt): not left over
    // its line till the post is settled)
    let ended = fn() {
      let l = login_followed(core, login().0, login().1)
      l is Some(_) && !login_carded(l)
    }
    b.show(fn() { open() && !ended() && m().card.bind(fn(c) { c.assignee_text }) is Some(_) }, fn(w) {
      @sf.words_node(w, fn() { m().card.bind(fn(c) { c.assignee_text }).unwrap_or("") }, fn() { settled_line }) |> ignore
    })
    // (none the core does not know: the message's words say it, and nothing takes its room)
    b.show(fn() { login_of(core, login().0, login().1) is Some(_) }, fn(s) {
      // (as wide as what it is under, as the old card's room is in decision_box: a share of its width, not stretched
      // across it, which a column lined up at its start does not do; ended, its line as wide as its words, at the start)
      s.width_share(Is(1.0)) |> ignore
      s.pick(login, fn(c, at) {
        c
        .width_share(Is(1.0))
        .lines_up(By(fn() { if login_carded(login_followed(core, at.0, at.1)) { None } else { Some(Start) } }))
        |> ignore
        login_card_node(c, core, at.0, at.1)
      })
    })
    ask_dismiss_node(b, src, here, fn() { m().seq }, fn() { m().asked }, fn() { false }, fn() { true }, false)
  })
  |> ignore
}

///|
/// What comes and goes under a post with options (message_decision's rooms): who decides and its options while it is
/// open (a vault item's approval in their place, answered with `core`; nothing there without one), 忽略 under them, how
/// it went once settled.
fn decision_rooms_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  m : () -> Message,
  core : @settings.Core?,
) -> Unit {
  let settled = fn() { decision_settled(m()) }
  // (how it went, once settled)
  let outcome = fn() {
    match m().decision {
      Some({ text: Some(words), .. }) if settled() => Some(words)
      _ => None
    }
  }
  // open, then settled: one place under the post with one thing in it at a time, the open card fading where it is
  // while its room gives way to how it went (a pick said `leave`, mbui's pick_leave.mbt). The card answered is the same
  // thing changing look, never the card closing and its line coming as two things beside each other (the user,
  // 2026-11-09). What the open side shows does not ask again whether it is settled: it leaves as it was at the press.
  v.box(fn(rooms) {
    // (its place across all of it: the pick's place is stretched across, each side laid as the rooms were)
    @sf.style_node(rooms, fn() { under_post_room })
    ends_on_way(rooms, settled)
    rooms.pick(settled, leave=msg_part_leave_ms, fn(side, is_settled) {
      @sf.style_node(side, fn() { decision_rooms })
      if !is_settled {
        // (what it shows as it was while open, held so as it leaves: the press settles the message, and what the open
        // side reads of it (who decides, its options, whether it is asked, 忽略) is not read again till it is gone, so it
        // fades whole where it was, never a part of it gone at the press's first frame)
        let held_m : Ref[Message?] = Ref(None)
        let open_m = fn() -> Message {
          match held_m.val {
            Some(h) if settled() => h
            _ => {
              let now = m()
              held_m.val = Some(now)
              now
            }
          }
        }
        side.box(fn(s) {
          @sf.style_node(s, fn() { under_post_room })
          s.box(fn(b) {
            @sf.style_node(b, fn() { decision_box })
            // (who decides)
            b.show(fn() { open_m().card is Some({ assignee_text: Some(_), .. }) }, fn(w) {
              @sf.words_node(
                w,
                fn() {
                  match open_m().card {
                    Some({ assignee_text: Some(a), .. }) => a
                    _ => ""
                  }
                },
                fn() { settled_line },
              )
              |> ignore
            })
            let vault = fn() { open_m().card.map(fn(c) { c.vault }).unwrap_or("") }
            // (what it is answered with, one place: its options, or a text card's words written here (decision.reply);
            // none for a vault item's, or where it is no thread's. One show, as the options alone were: a pick holds a
            // box even for none, a gap more in the card than the old view drew. A card's kind is its own all along, so
            // which of the two is read as it is shown)
            let answered_by = fn() {
              if vault() != "" || decision_thread(here) is None {
                0
              } else if decision_choices(open_m()).length() > 0 {
                1
              } else if decision_asks(open_m()) is Text {
                2
              } else {
                0
              }
            }
            b.show(fn() { answered_by() != 0 }, fn(o) {
              if @signals.untracked(answered_by) == 1 {
                decision_options_node(o, src, here, open_m)
              } else {
                decision_reply_node(o, src, here, open_m)
              }
            })
            // (an agent's request for a vault item: approved here, not answered in words; its buttons and what is typed
            // in for them as far apart as what is in decision_box)
            match core {
              Some(core) =>
                b.show(fn() { vault() != "" }, fn(a) {
                  @sf.style_node(a, fn() { vault_actions_room })
                  a.width_share(Is(1.0)) |> ignore
                  @settings.vault_actions_node(a, core, fn() { workspace_of(here.station) }, vault, fn() {
                    mine_to_node(here, open_m().card.map(fn(c) { c.assignee }).unwrap_or(""))
                  })
                })
              None => ()
            }
          })
          |> ignore
        })
        |> ignore
        // (忽略 under them, leaving with them)
        ask_dismiss_node(side, src, here, fn() { open_m().seq }, fn() { open_m().asked }, fn() { false }, fn() { true }, true)
      } else {
        // (in their place: how it went, where the core says it)
        side.show(fn() { outcome() is Some(_) }, fn(s) {
          @sf.style_node(s, fn() { under_post_room })
          s.pick(fn() { decision_choices(m()).length() > 0 }, fn(o, with_options) {
            let words = fn() { outcome().unwrap_or("") }
            if with_options {
              o.box(fn(r) {
                @sf.style_node(r, fn() { outcome_room })
                @sf.ask_history_trigger_node(
                  r,
                  fn() { [@ui.span(words())] },
                  fn() { settled_line },
                  @sf.ui_theme().leading(settled_leading).unwrap_or(settled_line_h),
                  fn(from) { decision_history(m, from) },
                )
                |> ignore
              })
              |> ignore
            } else {
              o.box(fn(r) {
                @sf.style_node(r, fn() { outcome_room })
                @sf.words_node(r, words, fn() { settled_line }) |> ignore
              })
              |> ignore
            }
          })
        })
      }
    })
  })
  |> ignore
}

///|
/// A settled post's options read again (card_history's, as nodes): the original card read-only in a panel (a sheet
/// on a small screen) opened from `from`, the one chosen checked.
fn decision_history(m : () -> Message, from : @view.View) -> Unit {
  @sf.panel_nodes(
    @sf.t("web-main.history.details"),
    fn(p, _) {
      let list = fn() { decision_choices(m()) }
      @sf.options_card_node(
        p,
        fn() { list().map(fn(o) { (o.label, o.detail, o.recommended) }) },
        fn() { false },
        fn() { None },
        chosen=fn() {
          let chosen = match m().decision {
            Some(d) => d.chosen
            None => None
          }
          list().search_by(fn(o) { Some(o.label) == chosen })
        },
        history=true,
      )
      |> ignore
    },
    from=Node(from),
  )
}

///|
/// Post `m`'s options in one card, numbered (decision_options', as nodes): as wide as what it says; pressing one
/// answers with it (`decision.answer`), the one on its way turning as the core's doing says, none pressed meanwhile;
/// settled, none pressed any more, the one picked checked. In `v`, its room.
fn decision_options_node(v : @view.View, src : Source, here : MessageNodeHere, m : () -> Message) -> Unit {
  let list = fn() { decision_choices(m()) }
  let settled = fn() { decision_settled(m()) }
  // the one on its way (the core's doing: its option)
  let busy = fn() -> Int? {
    guard decision_thread(here) is Some(thread) && !settled() else { return None }
    let on = [
      ("station", here.station),
      ("thread", thread.to_int().to_string()),
      ("seq", m().seq.to_int().to_string()),
    ]
    let mut busy : Int? = None
    for d in items(src.topic("doing", {}).get().value, "doing") {
      let dv = Some(d)
      if text(dv, "call") == "decision.answer" && text(dv, "stage") != "failed" {
        let params = field(dv, "params")
        if on.iter().all(fn(kv) { text(params, kv.0) == kv.1 }) {
          busy = list().search_by(fn(o) { o.label == text(params, "option") })
        }
      }
    }
    busy
  }
  let chosen = fn() -> Int? {
    guard settled() else { return None }
    match m().decision {
      Some({ chosen: Some(label), .. }) => list().search_by(fn(o) { o.label == label })
      _ => None
    }
  }
  // (as wide as what it says, as wide as where it is at most)
  @sf.style_node(v, fn() { options_room })
  @sf.options_card_node(
    v,
    fn() { list().map(fn(o) { (o.label, o.detail, o.recommended) }) },
    fn() { !settled() },
    busy,
    chosen~,
    wide=true,
    on_pick=fn(i) {
      let now = @signals.untracked(m)
      guard decision_thread(here) is Some(thread) && @signals.untracked(list).get(i) is Some(o) else { return }
      // picked, felt as something done (a no as something refused: act)
      @ui.haptic(Confirm)
      act(src, @sf.t("web-main.decisions.answerWhat", args=[("option", o.label)]), "", "decision.answer", {
        "station": Json::string(here.station),
        "thread": Json::number(thread),
        "seq": Json::number(now.seq),
        "option": Json::string(o.label),
      })
      // (its answer said in the chat, sent from here: the list goes to its end, as for words sent; one that closes the
      // card says nothing there)
      if !o.closes {
        @sfbase.sent_here_told(here.station + "\u{1}" + here.session, flies=false)
      }
    },
  )
  |> ignore
}

///|
/// What is written to answer each text card (by its station, thread and post: seq_key), kept while the app runs, as
/// a draft is: its card made again (the post scrolled out of the list's rows and back) shows what was written.
// kept across runs: put back by decision_reply_reset
let reply_fields : Map[String, @ui.Field] = Map([])

///|
fn decision_reply_reset() -> Unit {
  reply_fields.clear()
}

///|
/// Post `m`'s text card (decision_options' place, as nodes: the answer written, not picked): a card of words
/// (ask_card_node) holding a field to write it in, its hint the card's `placeholder` (else 写下你的回复), and 回复 in
/// its foot's start corner (ask_buttons_node, concentric with the card), sending what is written (`decision.reply`,
/// felt as something done; turning while it goes, nothing written again meanwhile; none with nothing written). In
/// `v`, its room. Who may answer and when are the options' (decision_rooms_node shows it only where the chat's thread
/// can be sent to); once the core says it is settled, how it went comes in its place.
fn decision_reply_node(v : @view.View, src : Source, here : MessageNodeHere, m : () -> Message) -> Unit {
  @sf.style_node(v, fn() { options_room })
  // (as wide as an agent's card that is written on in a chat may be, 560, never wider than where it is: as wide all the
  // while what is written in it grows; on the ground a post's options' card is on, under the post as they are)
  v.box(fn(r) {
    @sf.style_node(r, fn() { @sf.ask_card_room_most })
    decision_reply_card_node(r, src, here, m)
  })
  |> ignore
}

///|
/// decision_reply_node's card, in `v`.
fn decision_reply_card_node(v : @view.View, src : Source, here : MessageNodeHere, m : () -> Message) -> Unit {
  let key = match decision_thread(here) {
    Some(thread) => seq_key(here.station, thread, @signals.untracked(m).seq)
    None => here.station + "\u{1}" + @signals.untracked(m).seq.to_string()
  }
  let field = match reply_fields.get(key) {
    Some(f) => f
    None => {
      let f = @ui.Field::new()
      reply_fields[key] = f
      f
    }
  }
  let written = @signals.signal(field.text())
  let doing = "decision.reply:" + key
  let busy = fn() { @sfbase.doing(doing) }
  let send = fn() {
    let words = field.text().trim(chars=" \n\t").to_owned()
    let now = @signals.untracked(m)
    guard words != "" && !busy() && decision_thread(here) is Some(thread) else { return }
    // sent, felt as something done (a no as something refused: act)
    @ui.haptic(Confirm)
    act(src, @sf.t("web-main.decisions.reply"), doing, "decision.reply", {
      "station": Json::string(here.station),
      "thread": Json::number(thread),
      "seq": Json::number(now.seq),
      "text": Json::string(words),
    })
    // (its answer said in the chat, sent from here: the list goes to its end, as for words sent)
    @sfbase.sent_here_told(here.station + "\u{1}" + here.session, flies=false)
  }
  @sf.ask_card_node(v, ground=fn() { @sf.alpha(@sf.theme().p.text, 0.05) }, fn(k) {
    // (first on the card, reaching out to its top corners as 回复 under it reaches its foot's, as far from them: the
    // field's ends where 回复's are, its words where its are, its corner concentric with the card's)
    k.box(fn(b) {
      @sf.style_node(b, fn() { signin_typed.then(@sf.top_reach(@sf.button_height())) })
      @sf.textarea_node(
        b,
        field,
        rows=2,
        most=8,
        corner=@sf.top_reach_corner(@sf.button_height()),
        placeholder_by=fn() {
          match m().card {
            Some({ placeholder, .. }) if placeholder.trim(chars=" \n\t") != "" => placeholder
            _ => @sf.t("web-main.decisions.replyPlaceholder")
          }
        },
        disabled=busy,
        solid=true,
        card_words=true,
        edited=fn(w) { written.set(w) },
      )
      |> ignore
    })
    |> ignore
    @sf.ask_buttons_node(k, fn(f) {
      @sf.button_node(
        f,
        fn() { @sf.t("web-main.decisions.reply") },
        send,
        tone=Primary,
        busy~,
        disabled=fn() { busy() || written.get().trim(chars=" \n\t") == "" },
        card_words=true,
      )
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// 忽略 under what asks what no one has decided (ask_dismiss's, as nodes), post `seq` of the chat `here` is: there while
/// the chat's thread can be sent to, it is `asked` or `resolved`, it is `asking` (its options open) and the viewer has
/// not let it go here; pressed while it is not `resolved`, it lets it go (let_go). Its words underlined in the text's
/// ink under a mouse. `lead`: the gap over it in its room (under options), opening and closing with it.
fn ask_dismiss_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  seq : () -> Double,
  asked : () -> Bool,
  resolved : () -> Bool,
  asking : () -> Bool,
  lead : Bool,
) -> Unit {
  let key = fn() {
    match decision_thread(here) {
      Some(thread) => Some(seq_key(here.station, thread, seq()))
      None => None
    }
  }
  let shown = fn() {
    match key() {
      Some(k) => (asked() || resolved()) && asking() && !dismissed.has(k)
      None => false
    }
  }
  let live = fn() { shown() && !resolved() }
  v.show(shown, fn(s) {
    @sf.style_node(s, fn() { if lead { under_post_room_lead } else { under_post_room } })
    // (忽略 as wide as its words at the start, not drawn across the column)
    s.lines_up(Is(Some(Start))) |> ignore
    @sf.action_box_node(s, fn() { @sf.t("web-main.chat.asks.dismiss") }, disabled=fn() { !live() }, fn(_) {
      if @signals.untracked(live) {
        let_go(src, here, @signals.untracked(seq))
      }
    }, fn(b) {
      @sf.style_node(b, fn() { dismiss_room })
      let hot = fn() { live() && @sf.hovered_node(b) }
      b.box(fn(w) {
        let style = fn() { if hot() { dismiss_words_hot } else { dismiss_words } }
        w
        .words_runs(By(fn() { [@ui.span(@sf.t("web-main.chat.asks.dismiss"), underline=hot())] }))
        .words_look(By(fn() { @ui.style_words(style()) }))
        .ink(By(fn() { @ui.style_ink(style()) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// The viewer lets post `seq` of the chat `here` is go (`decision.dismiss`): let go at once (dismissed), back if that
/// fails; felt as an answer picked is.
fn let_go(src : Source, here : MessageNodeHere, seq : Double) -> Unit {
  guard decision_thread(here) is Some(thread) else { return }
  let k = seq_key(here.station, thread, seq)
  dismissed.add(k)
  @ui.haptic(Confirm)
  act(
    src,
    @sf.t("web-main.decisions.dismissWhat"),
    "",
    "decision.dismiss",
    { "station": Json::string(here.station), "thread": Json::number(thread), "seq": Json::number(seq) },
    failed=fn() { dismissed.remove(k) },
  )
}

///|
/// Where the chat stands, under its last message (chat_state's, as nodes), as the core says it now (`words`, `lead`,
/// `rest`; the chat's view's `stateAsk`): what it needs of the viewer and can be let go as one card (need_card_node);
/// else its line (chat_state_line_node), 忽略 under it while the core says something there can be let go. One in the
/// other's place as the core changes it (let go: the line saying so in the card's).
// the chat's page as nodes: held by its tests, not used by the app yet
#warnings("-unused_value")
fn chat_state_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  words : () -> String,
  lead : () -> String,
  rest : () -> String,
) -> Unit {
  let ask = fn() { (here.view)().state_ask }
  // (the card let go, its line in its place: one thing changing look, the card fading where it is while its room gives
  // way, as decision_rooms_node's)
  let done = fn() { !(lead() == "need" && ask() is Some(_)) }
  ends_on_way(v, done)
  v.pick(done, leave=msg_part_leave_ms, fn(p, is_done) {
    if !is_done {
      // (what it says as it was before it was let go, held so as it leaves: never the line's words in it as it fades)
      let held : Ref[(String, String, Double)?] = Ref(None)
      let shown = fn() -> (String, String, Double) {
        match held.val {
          Some(h) if done() => h
          _ => {
            let now = (words(), rest(), ask().unwrap_or(0.0))
            held.val = Some(now)
            now
          }
        }
      }
      need_card_node(p, src, here, fn() { shown().0 }, fn() { shown().1 }, fn() { shown().2 })
    } else {
      p.box(fn(s) {
        chat_state_line_node(s, words, lead, rest) |> ignore
        s.show(fn() { ask() is Some(_) }, fn(d) {
          @sf.style_node(d, fn() { decision_box })
          ask_dismiss_node(d, src, here, fn() { ask().unwrap_or(0.0) }, fn() { true }, fn() { false }, fn() { true }, false)
        })
      })
      |> ignore
    }
  })
}

///|
/// What the chat needs of the viewer as a card (need_card's, as nodes, read out as `words`): the bell where an option's
/// number is and what it needs (`rest`) in the ink, 忽略 at its end (under them where the native input is a finger's and the chat's list
/// is narrow: at once, an arrangement by the list's width); pressed, post `seq` let go (let_go), 忽略 faded and taking
/// no press till the core says so.
fn need_card_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  words : () -> String,
  rest : () -> String,
  seq : () -> Double,
) -> Unit {
  let said = fn() { @sf.ask_line_words(@sf.theme().chat_list.state_turn.then(chat_state_wraps)) }
  // (narrow by the list's width, as message_inline's; the card lays itself out by it: what the window does to the
  // width is no motion)
  @sf.ask_line_card_node(v, fn() { (here.width)() <= chat_narrow_w }, fn(card, stacked) {
    card.box(fn(w) {
      @sf.style_node(w, fn() { need_card_words }, in_row=!stacked)
      w.says(By(fn() { Some(@view.said(Text, label=words())) })) |> ignore
      // (the bell where an option's number is, in the middle of its disc: concentric with the row's corner as it is)
      @sf.ask_line_mark_node(w, fn(m) { lead_icon_node(m, "need", fn() { @sf.theme().p.text }, centred=true) })
      |> ignore
      w.show(fn() { rest() != "" }, fn(r) {
        // (taking what is left along the line, wrapping in it)
        r.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(r, rest, said) |> ignore
      })
    })
    |> ignore
    // (忽略 the library's button ending the row, concentric with its end corner)
    card.show(fn() { decision_thread(here) is Some(_) }, fn(e) {
      if stacked {
        @sf.style_node(e, fn() { need_card_actions })
      }
      @sf.ask_line_button_node(
        e,
        fn() { @sf.t("web-main.chat.asks.dismiss") },
        state_icon,
        fn() {
          match decision_thread(here) {
            Some(thread) => dismissed.has(seq_key(here.station, thread, seq()))
            None => true
          }
        },
        fn() { let_go(src, here, @signals.untracked(seq)) },
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// What is under a post: the column's width (under_post's room).
// kept across runs: a value (no field of it changes)
let under_post_room : @ui.Style = @ui.css("w=Full")

///|
/// What is under a post with the gap over it in its room (under_post's `lead`).
// kept across runs: a value (no field of it changes)
let under_post_room_lead : @ui.Style = @ui.css("w=Full pt=S1_5")

///|
/// A vault item's approval under a post: what is in it as far apart as in decision_box (its gap).
// kept across runs: a value (no field of it changes)
let vault_actions_room : @ui.Style = @ui.css("gap=S1_5")

///|
/// How it was settled: its first line's height where the theme says none (settled_line's leading).
let settled_line_h : Double = 18.0

///|
/// A card in node `v` coming to an end (`ended` turning true: decided, answered, signed in, whether by a press here or
/// by the core's answer) while the app shows: a live cause of its message (chat_live_causes' fourth), so what that
/// change does in the chat's list (the card fading where it stood, how it ended taking its room, what is under it
/// moving) goes its way (@view.transition within the part `v` moves with). Said before what it ends (its pick), so the
/// change is the transition's as that runs; one ended as it is made, or come so where the app does not show, is there
/// at once.
fn ends_on_way(v : @view.View, ended : () -> Bool) -> Unit {
  let was = Ref(@signals.untracked(ended))
  v.reacts(ended, at_start=false, fn(now) {
    let before = was.val
    was.val = now
    if now && !before && @signals.untracked(@ui.app_visible) {
      @view.transition(within=v.transitions_root(), fn() {  })
    }
  })
}
