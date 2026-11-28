// What a chat's card holds (peeks.mbt's chat_card) as nodes of the window's tree, made once: what is over it, opened
// and shut as the pointer rests on the link to the chat, is the hover card's (sf's), not this; this is what is in it,
// as the core reads the link (`link.parse`, asked once each: chats_named) and the chat's whole row says it (`chatRow`),
// as those change: the chat's mark, title and when it was last active; where it is when another station, and that the
// link is its agent's execution history; the one message the link names (`messagePeek`), else where it stands or the
// last thing said in it. One archived as its message says; one gone; its bones while the link or its row is read.
// Drawn by the library's (@sfbase.peek_chat_head_node, where it is, the message it names); this is what is read for it and
// what that says.

///|
/// What a chat's card shows (chat_card's): an archived one as its message says it; its bones while the link or its
/// row is read; that it is gone; the chat found.
#derive(Eq)
priv enum ChatShows {
  Archived
  Sample
  Gone
  Found
}

///|
/// What a chat's card holds (chat_card's) in `parent`: the chat `href` names (as it is now), read in a chat of station
/// `here` (chat_named: asked once each, as it is made or its link changes, never as it is drawn); `linked`, the chat as
/// its message says it; `link_label`, the link's own visible label (stripped of `@`, empty for bare URLs) so an
/// unavailable card keeps a two-tier title + reason layout instead of a flat single-line capsule. Active rows come from
/// `chatRow`; when absent from the active list (e.g. archived), `chatPeek` is held on demand in `scope` and released
/// with it.
// a hover card as nodes: held by its tests, not used by the app yet
#warnings("-unused_value")
fn chat_card_node(
  parent : @view.View,
  src : Source,
  scope : String,
  here : String,
  href : () -> String,
  linked : () -> LinkedChat?,
  link_label? : () -> String = fn() { "" },
) -> Unit {
  // (asked once the link is known, as it changes: chat_named asks the core only for one it has not)
  parent.reacts(href, fn(h) { chat_named(src, here, h) |> ignore })
  let named = fn() { chats_named.get(here + "\u{1}" + href()).unwrap_or(Named::Asking) }
  // (active row from `chatRow`: None while reading, Some(None) when not in active list or another workspace)
  let active = fn() -> (ChatItem, Bool, Double?)?? {
    match named() {
      Named::Chat(station, key, history, seq) => {
        guard peek_ours(here, station) else { return Some(None) }
        peek_row(src.topic("chatRow", @sfbase.whole_params(station, key)).get()).map(fn(r) {
          r.map(fn(i) { (i, history, seq) })
        })
      }
      _ => None
    }
  }
  // (on-demand `chatPeek` target: held in `scope` only when `chatRow` returned Some(None) for a chat in our workspace)
  let peek_target = fn() -> (String, String)? {
    match named() {
      Named::Chat(station, key, _, _) if peek_ours(here, station) =>
        match active() {
          Some(None) => Some((station, key))
          _ => None
        }
      _ => None
    }
  }
  parent.reacts(peek_target, fn(target) {
    match target {
      Some((station, key)) => @sfbase.hold(src, scope, "chatPeek", @sfbase.whole_params(station, key)) |> ignore
      None => ()
    }
  })
  // (the on-demand `chatPeek` state when active list missed)
  let peek_state = fn() -> @sfbase.TopicState? {
    match peek_target() {
      Some((station, key)) => Some(src.topic("chatPeek", @sfbase.whole_params(station, key)).get())
      None => None
    }
  }
  let found = fn() -> (ChatItem, Bool, Bool, Double?)? {
    match active() {
      Some(Some((item, history, seq))) => Some((item, false, history, seq))
      Some(None) =>
        match (named(), peek_state()) {
          (Named::Chat(_, _, history, seq), Some(st)) =>
            match peek_row(st) {
              Some(Some(item)) => Some((item, flag(st.value, "archived"), history, seq))
              _ => None
            }
          _ => None
        }
      None => None
    }
  }
  let gone_reason = fn() -> String {
    match named() {
      Named::Chat(station, _, _, _) if !peek_ours(here, station) =>
        @sf.t("web-main.chatRef.previewOtherWorkspace")
      Named::Chat(_) =>
        match peek_state() {
          Some(st) if st.error is Some(err) => {
            let msg = text(Some(err), "message")
            if msg != "" { msg } else { @sf.t("web-main.chatRef.previewUnavailable") }
          }
          _ => @sf.t("web-main.chatRef.previewGone")
        }
      _ => @sf.t("web-main.chatRef.previewGone")
    }
  }
  let shows = fn() {
    if found() is Some(_) {
      return Found
    }
    match named() {
      Named::Asking =>
        match linked() {
          Some(l) if l.archived => Archived
          _ => ChatShows::Sample
        }
      NoChat =>
        match linked() {
          Some(l) if l.archived => Archived
          _ => Gone
        }
      Named::Chat(station, _, _, _) => {
        if !peek_ours(here, station) {
          return Gone
        }
        match active() {
          None =>
            match linked() {
              Some(l) if l.archived => Archived
              _ => ChatShows::Sample
            }
          Some(Some(_)) => Found
          Some(None) =>
            match peek_state() {
              Some(st) =>
                if st.error is Some(_) {
                  match linked() {
                    Some(l) if l.archived => Archived
                    _ => Gone
                  }
                } else {
                  match peek_row(st) {
                    Some(Some(_)) => Found
                    Some(None) =>
                      match linked() {
                        Some(l) if l.archived => Archived
                        _ => Gone
                      }
                    None =>
                      match linked() {
                        Some(l) if l.archived => Archived
                        _ => ChatShows::Sample
                      }
                  }
                }
              None =>
                match linked() {
                  Some(l) if l.archived => Archived
                  _ => ChatShows::Sample
                }
            }
        }
      }
    }
  }
  parent.pick(shows, fn(b, s) {
    @sf.style_node(b, fn() { @sfbase.peek_card_part })
    match s {
      Archived => {
        let l = fn() {
          linked().unwrap_or({ href: "", title: "", archived: true, note: "", thread: None })
        }
        @sfbase.peek_rich_node(b, fn(rich) {
          @sfbase.peek_chat_head_node(rich, fn() { l().title })
          @sfbase.peek_chat_where_node(
            rich,
            fn() { true },
            fn() { false },
            fn() { "" },
            fn() { "" },
            fn() { "" },
            archived=fn() { true },
            archived_words=fn() { @sf.t("android-chat.search.archived") },
          )
          rich.show(
            fn() { l().note != "" && l().note != @sf.t("android-chat.search.archived") },
            fn(n) { @sfbase.peek_excerpt_node(n, fn() { l().note }) },
          )
          // (the message its link names, by the thread its message says it has)
          let message = fn() {
            match (named(), l().thread) {
              (Named::Chat(station, _, _, Some(seq)), Some(thread)) => Some((station, thread, seq))
              _ => None
            }
          }
          message_said_node(rich, src, scope, message)
        })
      }
      // (while the link or its row is read: a made-up chat's, in its bones)
      Sample =>
        @sf.waiting_node(b, fn(bones) {
          chat_card_of_node(bones, fn() { sample_chat(0) }, fn() { false }, fn() { false }, fn() { false }, fn() { None }, src, scope)
        })
      Gone =>
        b.pick(fn() { link_label() != "" }, fn(g, has_title) {
          @sf.style_node(g, fn() { @sfbase.peek_card_part })
          if has_title {
            @sfbase.peek_rich_node(g, fn(rich) {
              @sfbase.peek_chat_head_node(rich, link_label)
              @sfbase.peek_note_node(rich, gone_reason)
            })
          } else {
            @sfbase.peek_note_node(g, gone_reason)
          }
        })
      Found => {
        let it = found
        let item = fn() { it().map(fn(f) { f.0 }).unwrap_or(sample_chat(0)) }
        chat_card_of_node(
          b,
          item,
          fn() { it().map(fn(f) { f.1 }).unwrap_or(false) },
          fn() { item().station != here },
          fn() { it().map(fn(f) { f.2 }).unwrap_or(false) },
          fn() {
            match it() {
              Some((i, _, _, Some(seq))) =>
                match i.thread {
                  Some(thread) => Some((i.station, thread, seq))
                  None => None
                }
              _ => None
            }
          },
          src,
          scope,
        )
      }
    }
  })
}

///|
/// The card of a chat found (chat_card_of's) in `parent`, of `item` as it is now: its mark (omitted when archived),
/// title and when it was last active; its archived pill, where it is (`elsewhere`, another station: its mark and name)
/// and that the link is its agent's execution history (`history`); the message the link names (`message`: its station,
/// thread and number) in place of where it stands or the last thing said in it (three lines at most).
fn chat_card_of_node(
  parent : @view.View,
  item : () -> ChatItem,
  archived : () -> Bool,
  elsewhere : () -> Bool,
  history : () -> Bool,
  message : () -> (String, Double, Double)?,
  src : Source,
  scope : String,
) -> Unit {
  @sfbase.peek_rich_node(parent, fn(rich) {
    // (none: nothing in its place, not even the room between, as chat_mark's 0; archived chats omit the live dot)
    let tone = fn() { @sfbase.row_tone(item()) }
    @sfbase.peek_chat_head_node(
      rich,
      fn() { item().title },
      marked=fn() { !archived() && (tone() is ("busy" | "done" | "alert" | "wait")) },
      mark=fn(m) { chat_mark_node(m, tone) },
      ago=fn() { item().ago },
    )
    @sfbase.peek_chat_where_node(
      rich,
      fn() { archived() || elsewhere() || history() },
      elsewhere,
      fn() { item().station_emoji },
      fn() { item().station_icon },
      fn() { if elsewhere() { item().station_name } else { "" } },
      archived~,
      archived_words=fn() { @sf.t("android-chat.search.archived") },
      history~,
      history_words=fn() { @sf.t("web-main.chatRef.previewHistory") },
    )
    message_said_node(rich, src, scope, message)
    // (where it names none: where it stands, else the last thing said in it)
    let said = fn() {
      let i = item()
      match (i.state_text, i.decision_text, i.last) {
        (Some(s), _, _) if s != "" => s
        (_, Some(s), _) if s != "" => s
        (_, _, Some(s)) => s
        _ => ""
      }
    }
    rich.show(fn() { message() is None && said() != "" }, fn(e) { @sfbase.peek_excerpt_node(e, said) })
  })
}

///|
/// The message of a chat on its card (message_said's) in `parent`, where `message` names one (its station, thread and
/// number, as it is now), as the core reads it (`messagePeek`, for `scope`): who said it and when, over its words (six
/// lines at most); that it can't be read, for one gone or a station that won't say; bones while it is read.
fn message_said_node(
  parent : @view.View,
  src : Source,
  scope : String,
  message : () -> (String, Double, Double)?,
) -> Unit {
  // (none named: nothing in its place, not even the room between)
  parent.show(fn() { message() is Some(_) }, fn(s) {
    s.pick(message, fn(b, m) {
      @sf.style_node(b, fn() { @sfbase.peek_card_part })
      guard m is Some((station, thread, seq)) else { return }
      let params : Map[String, Json] = {
        "station": Json::string(station),
        "thread": Json::number(thread),
        "seq": Json::number(seq),
      }
      let read = @sfbase.hold(src, scope, "messagePeek", params)
      let value = fn() -> Json? {
        match read.get().value {
          Some(Object(_)) as v => v
          _ => None
        }
      }
      // (said; read, in its bones; else gone: a value that is no message, or the core's error)
      let shows = fn() {
        let r = read.get()
        match r.value {
          Some(Object(_)) => 2
          None if r.error is None => 1
          _ => 0
        }
      }
      b.pick(shows, fn(q, k) {
        @sf.style_node(q, fn() { @sfbase.peek_card_part })
        match k {
          2 =>
            @sfbase.peek_message_node(
              q,
              fn() {
                let v = value()
                [text(v, "author"), text(field(field(v, "time"), "at"), "ago")].filter(fn(w) { w != "" }).join(" · ")
              },
              fn() { text(value(), "text") },
            )
          1 => @sfbase.peek_message_bones_node(q)
          _ => @sfbase.peek_note_node(q, fn() { @sf.t("web-main.chatRef.previewMessageGone") })
        }
      })
    })
  })
}
