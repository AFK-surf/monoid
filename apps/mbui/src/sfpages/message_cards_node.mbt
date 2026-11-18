// An agent's request as its card in place of its post's words (decision.mbt's vault_ask_card, phone_ask_card,
// rig_ask_card; signin_card.mbt's signin_ask_card), as nodes of the window's tree, made once as the message says it now,
// following it and the core as they change: its card while it waits, answered on it, then one line saying how it went,
// pressed for the card read again; the one in the other's place as it is decided, as anything down a column comes and
// goes (View::pick: the old under_post's fades and the list's turns are not here). The card's insides are the settings'
// (rig_card_node…), as the old ones are. Made so far: a rig's (P32), a phone's (P31: not the step left on the phone
// under its line once granted, settings' phone_ask_node says why), a vault item's (P30: one asking for a file to be
// picked too, its card as wide as it may be from the first), a sign-in's (P33: message_signin_node.mbt).

///|
/// What is in place of a post's words, as the message says it now.
#derive(Eq)
priv enum InPlace {
  /// its words (the agent's message's own)
  Words
  /// a request for its person's phone
  Phone
  /// a request for a rig of the workspace
  Rig
  /// a request about a vault item
  Vault
  /// an ask to sign in to a site
  SignIn
}

///|
/// What is in place of post `m`'s words (prose_with_files' cases).
fn in_place_of(m : Message) -> InPlace {
  match m.card {
    Some({ ask: Some(_), .. }) => Vault
    Some({ phone: Some(_), .. }) => Phone
    Some({ signin: Some(_), .. }) => SignIn
    Some({ rig: Some(_), .. }) => Rig
    _ => Words
  }
}

///|
/// Post `m`'s request as its card in place of its words (prose_with_files' cards, as nodes) in `v`, of the chat `here`
/// is, answered with `core` (None where nothing is answered); nothing where it has none.
// the chat's page as nodes: held by its tests, not used by the app yet
#warnings("-unused_value")
fn message_card_node(v : @view.View, here : MessageNodeHere, core : @settings.Core?, m : () -> Message) -> Unit {
  v.pick(fn() { in_place_of(m()) }, fn(p, k) {
    match k {
      Phone => phone_ask_node(p, here, core, m)
      Rig => rig_ask_node(p, here, core, m)
      Vault => vault_ask_node(p, here, core, m)
      SignIn => signin_ask_node(p, here, core, m)
      Words => ()
    }
  })
}

///|
/// Whether what is asked of `assignee` is the viewer's to answer in the chat `here` is (mine_to's, as the view says it
/// now): anyone's where it names no one.
fn mine_to_node(here : MessageNodeHere, assignee : String) -> Bool {
  let me = (here.view)().me
  assignee == "" || me == "" || assignee.to_lower() == me.to_lower()
}

///|
/// What reads a request again where it is asked to (`open`), but in a picture of the chat being shared, where nothing
/// of it opens (publish.mbt).
fn card_history_in(here : MessageNodeHere, open : (@view.View) -> Unit) -> ((@view.View) -> Unit)? {
  if here.picture is Some(_) {
    None
  } else {
    Some(open)
  }
}

///|
/// A request read again in a panel (card_history's, as nodes; a sheet on a small screen) opened from `from`: `body` in
/// the panel's words' room.
fn card_history_node(from : @view.View, body : (@view.View) -> Unit) -> Unit {
  card_history_from(Node(from), body)
}

///|
/// What was asked read again in a panel of nodes opened from `from` (a sheet on a small screen): `body` in the panel's
/// words' room (`padded`), or across it as a card the panel holds lays itself out (an options card: not padded).
fn card_history_from(from : @sf.Anchor, padded? : Bool = true, body : (@view.View) -> Unit) -> Unit {
  @sf.panel_nodes(
    @sf.t("web-main.history.details"),
    fn(p, _) {
      if padded {
        p.box(fn(b) {
          @sf.style_node(b, fn() { @sf.panel_words_in_node(b) })
          body(b)
        })
        |> ignore
      } else {
        body(p)
      }
    },
    from~,
  )
}

///|
/// A request with nothing in it (what a rig's reads where its message says none: the card going as another comes).
// kept across runs: a value (no field of it changes)
let rig_ask_none : RigAsk = {
  request: "",
  rig: "",
  name: "",
  reason: "",
  timeout_kind: "",
  timeout_seconds: 0,
  session: "",
  chat: "",
  title: "",
  by: "",
  status: "",
  why: "",
  delivered: false,
  granted_kind: "",
  granted_seconds: 0,
  device: "",
  device_name: "",
}

///|
/// Post `m`'s request for a rig in place of its words (rig_ask_card's, as nodes) in `v`: its card while it waits
/// (answered by the rig's person with `rig.decide` on the chat's station), then a line saying how it went, pressed for
/// what was asked; decided, the line in the card's place.
fn rig_ask_node(v : @view.View, here : MessageNodeHere, core : @settings.Core?, m : () -> Message) -> Unit {
  let ask = fn() {
    match m().card {
      Some({ rig: Some(a), .. }) => a
      _ => rig_ask_none
    }
  }
  // (decided, the card fades where it stands as its room gives way to how it ended (decision_rooms_node's way): one
  // place, one thing in it at a time, the card leaving as it was at the press, never gone in the press's frame. One
  // decided as it is made never goes back: none of that is made for it)
  let leave = if @signals.untracked(fn() { ask().status != "" }) { 0.0 } else { msg_part_leave_ms }
  v.pick(fn() { ask().status != "" }, leave~, fn(p, decided) {
    @sf.style_node(p, fn() { under_post_room })
    if !decided {
      // (what it shows as it was while it waited, held so as it leaves: what it reads of the message is not read again
      // once it is decided)
      let held_m : Ref[Message?] = Ref(None)
      let open_m = fn() -> Message {
        match held_m.val {
          Some(h) if ask().status != "" => h
          _ => {
            let now = m()
            held_m.val = Some(now)
            now
          }
        }
      }
      let ask = fn() {
        match open_m().card {
          Some({ rig: Some(a), .. }) => a
          _ => rig_ask_none
        }
      }
      let assignee = fn() { open_m().card.map(fn(c) { c.assignee }).unwrap_or("") }
      let who = fn() { open_m().card.bind(fn(c) { c.assignee_text }) }
      // (the card as wide as what it says: lined up at the column's start, not across it)
      p.lines_up(Is(Some(Start))) |> ignore
      p.box(fn(r) {
        @sf.style_node(r, fn() { @sf.ask_card_room.then(ask_card_under_head) })
        let card = @signals.computed(fn(_) -> @settings.RigCard {
          let a = ask()
          {
            request: a.request,
            name: a.name,
            reason: a.reason,
            timeout: (a.timeout_kind, a.timeout_seconds),
            ask: {
              "rig": Json::string(a.rig),
              "name": Json::string(a.name),
              "session": Json::string(a.session),
              "chat": Json::string(a.chat),
              "title": Json::string(a.title),
              "by": Json::string(a.by),
              "device": Json::string(a.device),
              "deviceName": Json::string(a.device_name),
            },
            mine: mine_to_node(here, assignee()),
            who: who(),
            device: a.device_name,
            ended: if a.status != "" {
              Some((a.status == "granted", @settings.rig_outcome_words(a.status, a.why, a.delivered, (a.granted_kind, a.granted_seconds))))
            } else {
              None
            },
          }
        }, same=fn(a, b) { a == b })
        @settings.rig_card_node(r, core, here.station, fn() { card.get() }, lock=fn() {
          open_page(Setting(@settings.Route::AdbShare(here.station)))
        })
      })
      |> ignore
    } else {
      @settings.rig_outcome_node(
        p,
        fn() { ask().status },
        fn() { ask().why },
        fn() { ask().delivered },
        fn() { (ask().granted_kind, ask().granted_seconds) },
        fn() { message_inline(here) },
        history=card_history_in(here, fn(from) {
          card_history_node(from, fn(b) {
            @sf.ask_words_node(
              b,
              fn() { @sf.t("web-pages.rigs.ask.title", args=[("name", ask().name)]) },
              fn() { ask().reason },
            )
            |> ignore
          })
        }),
      )
    }
  })
}

///|
/// A request with nothing in it (what a phone's reads where its message says none: the card going as another comes).
// kept across runs: a value (no field of it changes)
let phone_ask_none : PhoneAsk = { request: "", reason: "", status: "", scope: "", why: "", link: "", lasts: "" }

///|
/// Post `m`'s request for its person's phone in place of its words (phone_ask_card's, as nodes) in `v`: its card while it
/// waits (answered with `adb.decide` on the chat's station), then a line saying how it went, how its station holds the
/// phone after it, pressed for what was asked; decided, the line in the card's place. Granted to the viewer, on a phone
/// that lends its own adb (its host's answer, settings' adb_phone_node), the first thing left on it a card under the
/// line (step_card_node: the card does it, never a page about it; one the phone cannot do, said with nothing to press),
/// the line saying no more than what was allowed.
fn phone_ask_node(v : @view.View, here : MessageNodeHere, core : @settings.Core?, m : () -> Message) -> Unit {
  let ask = fn() {
    match m().card {
      Some({ phone: Some(a), .. }) => a
      _ => phone_ask_none
    }
  }
  let assignee = fn() { m().card.map(fn(c) { c.assignee }).unwrap_or("") }
  // (decided, the card fades where it stands as its room gives way to how it ended (decision_rooms_node's way): one
  // place, one thing in it at a time, the card leaving as it was at the press, never gone in the press's frame. One
  // decided as it is made never goes back: none of that is made for it)
  let leave = if @signals.untracked(fn() { ask().status != "" }) { 0.0 } else { msg_part_leave_ms }
  v.pick(fn() { ask().status != "" }, leave~, fn(p, decided) {
    @sf.style_node(p, fn() { under_post_room })
    if !decided {
      // (what it shows as it was while it waited, held so as it leaves: what it reads of the message is not read again
      // once it is decided)
      let held_m : Ref[Message?] = Ref(None)
      let open_m = fn() -> Message {
        match held_m.val {
          Some(h) if ask().status != "" => h
          _ => {
            let now = m()
            held_m.val = Some(now)
            now
          }
        }
      }
      let ask = fn() {
        match open_m().card {
          Some({ phone: Some(a), .. }) => a
          _ => phone_ask_none
        }
      }
      let assignee = fn() { open_m().card.map(fn(c) { c.assignee }).unwrap_or("") }
      let who = fn() { open_m().card.bind(fn(c) { c.assignee_text }) }
      // (the card as wide as what it says: lined up at the column's start, not across it)
      p.lines_up(Is(Some(Start))) |> ignore
      p.box(fn(r) {
        @sf.style_node(r, fn() { @sf.ask_card_room.then(ask_card_under_head) })
        let card = @signals.computed(fn(_) -> @settings.PhoneCard {
          let a = ask()
          {
            request: a.request,
            reason: a.reason,
            lasts: a.lasts,
            mine: mine_to_node(here, assignee()),
            who: who(),
            ended: if a.status != "" { Some((a.status, a.scope, a.why)) } else { None },
          }
        }, same=fn(a, b) { a == b })
        @settings.phone_card_node(r, core, here.station, fn() { card.get() }, how=fn() {
          open_page(Setting(@settings.Route::AdbShare(here.station)))
        })
      })
      |> ignore
    } else {
      // (on the phone, granted to the viewer: what is left to do on it, as its host and the core say it now)
      let mine_granted = fn() { core is Some(_) && ask().status == "granted" && mine_to_node(here, assignee()) }
      let step = fn() -> @settings.AdbStep? {
        match core {
          Some(core) if mine_granted() => @settings.adb_step_of(core, here.station, @settings.adb_phone_now())
          _ => None
        }
      }
      @settings.phone_outcome_node(
        p,
        fn() { ask().status },
        fn() { ask().scope },
        fn() { ask().why },
        fn() { @settings.phone_link(core, here.station, ask().link) },
        fn() { message_inline(here) },
        history=card_history_in(here, fn(from) {
          card_history_node(from, fn(b) {
            @sf.ask_words_node(b, fn() { @sf.t("android-misc.adb.ask.chat.title") }, fn() { ask().reason }) |> ignore
          })
        }),
        step_here=fn() { step() is Some(_) },
      )
      p.show(mine_granted, fn(s) {
        // (the phone asked of its host as this is made: read by the line above and the card here, as it is said)
        @settings.adb_phone_node(s) |> ignore
        s.show(fn() { step() is Some(_) }, fn(k) {
          step_card_node(
            k,
            fn() { step().map(fn(a) { a.title }).unwrap_or("") },
            fn() { step().map(fn(a) { a.sub }).unwrap_or("") },
            fn() {
              match (core, step()) {
                (Some(core), Some(a)) if a.act != "" => Some(fn() { @settings.adb_do(core, a.act, station=here.station) })
                _ => None
              }
            },
          )
        })
      })
    }
  })
}

///|
/// A request with nothing in it (what a vault item's reads where its message says none: the card going as another
/// comes).
// kept across runs: a value (no field of it changes)
let vault_ask_none : VaultAsk = {
  name: "",
  reason: "",
  timeout_kind: "",
  timeout_seconds: 0,
  approved_timeout_kind: "",
  approved_timeout_seconds: 0,
  mode: "",
  command: "",
  how_text: "",
  save_kind: "",
  username: "",
  filename: "",
  typed: false,
  oauth: "",
  describe: false,
  new_name: "",
  new_about: "",
  was_about: "",
  remove: false,
  status: "",
  scope: "",
  station: "",
  answer: "",
  lasts: "",
}

///|
/// What a vault item's request asks, as its card says it (vault_ask_card's Asked).
fn vault_asked_of(ask : VaultAsk) -> @settings.Asked {
  {
    name: ask.name,
    reason: ask.reason,
    timeout_kind: ask.timeout_kind,
    timeout_seconds: ask.timeout_seconds,
    approved_timeout_kind: ask.approved_timeout_kind,
    approved_timeout_seconds: ask.approved_timeout_seconds,
    mode: ask.mode,
    command: ask.command,
    how_text: ask.how_text,
    save_kind: ask.save_kind,
    username: ask.username,
    filename: ask.filename,
    typed: ask.typed,
    oauth: ask.oauth,
    station: ask.station,
    describe: ask.describe,
    new_name: ask.new_name,
    new_about: ask.new_about,
    was_about: ask.was_about,
    remove: ask.remove,
  }
}

///|
/// Post `m`'s request about a vault item in place of its words (vault_ask_card's, as nodes) in `v`: its card while it
/// waits, as wide as what it says (320 at least where there is the room), its answer at its foot as the core said it
/// with the message (`vaultAsk.answer`), answered with `vault.approve` / `vault.deny`; where nothing is answered (no
/// core), the card without its answer; decided, a line saying how it ended in the card's place, pressed for what was
/// asked. One asking for a file to be picked is as wide as it may be from the first (ask_card_room_most), so what is
/// picked comes in beside its button with nothing moving.
fn vault_ask_node(v : @view.View, here : MessageNodeHere, core : @settings.Core?, m : () -> Message) -> Unit {
  // (what it asks, and that as its card says it, worked out once as the message changes: what the card makes of it
  // reads them over and over, each reading a field)
  let asking = @signals.computed(
    fn(_) {
      match m().card {
        Some({ ask: Some(a), .. }) => a
        _ => vault_ask_none
      }
    },
  )
  let ask = fn() { asking.get() }
  let asked_now = @signals.computed(fn(_) { vault_asked_of(ask()) })
  let asked = fn() { asked_now.get() }
  // (decided, the card fades where it stands as its room gives way to how it ended (decision_rooms_node's way): one
  // place, one thing in it at a time, the card leaving as it was at the press, never gone in the press's frame. One
  // decided as it is made never goes back: none of that is made for it)
  let leave = if @signals.untracked(fn() { ask().status != "" }) { 0.0 } else { msg_part_leave_ms }
  v.pick(fn() { ask().status != "" }, leave~, fn(p, decided) {
    @sf.style_node(p, fn() { under_post_room })
    if !decided {
      // (what it shows as it was while it waited, held so as it leaves: what it reads of the message is not read again
      // once it is decided)
      let held_m : Ref[Message?] = Ref(None)
      let open_m = fn() -> Message {
        match held_m.val {
          Some(h) if ask().status != "" => h
          _ => {
            let now = m()
            held_m.val = Some(now)
            now
          }
        }
      }
      let open_asking = @signals.computed(
        fn(_) {
          match open_m().card {
            Some({ ask: Some(a), .. }) => a
            _ => vault_ask_none
          }
        },
      )
      let ask = fn() { open_asking.get() }
      let open_asked = @signals.computed(fn(_) { vault_asked_of(ask()) })
      let asked = fn() { open_asked.get() }
      let card = fn() { open_m().card }
      // (the card as wide as what it says: lined up at the column's start, not across it)
      p.lines_up(Is(Some(Start))) |> ignore
      p.box(fn(r) {
        @sf.style_node(r, fn() {
          let a = ask()
          (if a.typed && a.save_kind == "file" { @sf.ask_card_room_most } else { @sf.ask_card_room }).then(ask_card_under_head)
        })
        match core {
          Some(core) =>
            @settings.vault_card_node(
              r,
              core,
              fn() { workspace_of(here.station) },
              fn() { card().map(fn(c) { c.vault }).unwrap_or("") },
              asked,
              fn() {
                let c = card()
                @settings.card_answer(
                  ask().answer,
                  ask().lasts,
                  mine_to_node(here, c.map(fn(c) { c.assignee }).unwrap_or("")),
                  who=c.bind(fn(c) { c.assignee_text }),
                )
              },
              fn() { if ask().status != "" { Some((ask().status, ask().scope)) } else { None } },
            )
          None => @settings.vault_ask_words_node(r, asked)
        }
      })
      |> ignore
    } else {
      @settings.vault_outcome_node(
        p,
        asked,
        fn() { ask().status },
        fn() { ask().scope },
        fn() { message_inline(here) },
        history=card_history_in(here, fn(from) { card_history_node(from, fn(b) { @settings.vault_ask_details_node(b, asked) }) }),
      )
    }
  })
}
