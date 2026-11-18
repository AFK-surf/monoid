// An agent's ask to sign in to a site in place of its post's words (signin_card.mbt's signin_ask_card), as nodes of the
// window's tree, made once, following the message, the core and this device's password manager as they change: its
// card while it is answered, then one line saying how it went, pressed for the card read again; the one in the other's
// place as it is decided (View::pick, as a rig's: message_cards_node.mbt). What it keeps between frames is the old
// card's (signin_runs, signin_steps, signin_notes, signin_keep, signin_saving: signals), asked and answered by its
// functions (signin_start, signin_took, signin_send…), so the two are one state. What the host answers is told as it
// comes: how a run of 1Password's `op` ended (@hostapi.OpRun::done) and the login the system's autofill gave
// (@hostapi.autofill_take) are signals, followed by a reaction (View::reacts) that takes them at that moment, as the
// approval of keeping a sign-in in the vault is asked at the moment the core says it is signed in.

///|
/// A sign-in's ask with nothing in it (what a sign-in's reads where its message says none: the card going as another
/// comes).
// kept across runs: a value (no field of it changes)
let signin_ask_none : SignInAsk = {
  id: "",
  site: "",
  reason: "",
  screen: "",
  status: "",
  why: "",
  said: "",
  keep: false,
  save: "",
  kept: "",
}

///|
/// Post `m`'s ask to sign in in place of its words (signin_ask_card's, as nodes) in `v`: its card while it is answered
/// (signin_card_node), then a line saying how it went (signin_outcome's), pressed for what was asked; ended and what
/// keeps it decided (signin_over), the line in the card's place.
fn signin_ask_node(v : @view.View, here : MessageNodeHere, core : @settings.Core?, m : () -> Message) -> Unit {
  let ask = fn() {
    match m().card {
      Some({ signin: Some(a), .. }) => a
      _ => signin_ask_none
    }
  }
  let title = fn() { @sf.t("android-misc.signin.title", args=[("site", ask().site)]) }
  v.pick(fn() { signin_over(ask()) }, fn(p, decided) {
    @sf.style_node(p, fn() { under_post_room })
    if !decided {
      // (the card as wide as what it says: lined up at the column's start, not across it)
      p.lines_up(Is(Some(Start))) |> ignore
      p.box(fn(r) {
        @sf.style_node(r, fn() { @sf.ask_card_room.then(ask_card_under_head) })
        signin_card_node(r, here, core, ask, fn() { m().card })
      })
      |> ignore
    } else {
      @settings.ask_outcome_node(
        p,
        fn() { ask().status == "done" },
        fn() { [@ui.span(signin_outcome_words(ask()))] },
        fn() { message_inline(here) },
        history=Some(fn(from) {
          card_history_node(from, fn(b) { @sf.ask_words_node(b, title, fn() { ask().reason }) |> ignore })
        }),
      )
    }
  })
}

///|
/// The card (signin_card's, as nodes) in `v`: its title and the agent's reason, and at its foot what is answered now
/// (signin_foot_node) where it is the viewer's and a core is there; else whose it is, where the card says.
fn signin_card_node(
  v : @view.View,
  here : MessageNodeHere,
  core : @settings.Core?,
  ask : () -> SignInAsk,
  card : () -> Card?,
) -> Unit {
  @sf.ask_card_node(v, fn(k) {
    @sf.ask_words_node(k, fn() { @sf.t("android-misc.signin.title", args=[("site", ask().site)]) }, fn() { ask().reason })
    |> ignore
    let answers = fn() { core is Some(_) && mine_to_node(here, card().map(fn(c) { c.assignee }).unwrap_or("")) }
    let who = fn() { card().bind(fn(c) { c.assignee_text }).unwrap_or("") }
    k.show(fn() { answers() || who() != "" }, fn(s) {
      s.pick(answers, fn(p, yes) {
        match (yes, core) {
          (true, Some(core)) => signin_foot_node(p, core, here.station, ask)
          _ => @sf.words_node(p, who, fn() { @sf.ask_note }) |> ignore
        }
      })
    })
  })
  |> ignore
}

///|
/// Which buttons a sign-in's foot has, as the card and what the password manager is asked say it now.
#derive(Eq)
priv enum SignInButtons {
  /// none (signed in, its keeping going on; left)
  NoButtons
  /// the station types the login into the page: one at work
  Filling
  /// a code the page asks: 继续, and the screen
  Code
  /// the person's own step: the screen, and 我已登录
  Person
  /// the password manager's logins of the site to pick from
  Choosing
  /// waiting: the password manager (where there is one here), on the screen, and whether to keep it
  Asking(Bool)
}

///|
/// What is answered at the card's foot now (signin_foot's, as nodes) in `v`: a line saying how it goes, a code's field
/// where the page asks one, and its buttons. Answered with `core` on `station`'s chat's tab.
fn signin_foot_node(v : @view.View, core : @settings.Core, station : String, ask : () -> SignInAsk) -> Unit {
  let id = fn() { ask().id }
  let step = fn() { signin_steps.get(id()).unwrap_or("") }
  let now = fn() { @signals.untracked(ask) }
  // (a run of op under way ended, as the host's word says: what it said taken, once)
  v.reacts(
    fn() { signin_runs.get(id()).bind(fn(r) { r.run.get() }).bind(fn(run) { run.done() }) is Some(_) },
    fn(ended) { if ended { @signals.untracked(fn() { signin_took(core, station, now()) }) } },
  )
  // (the login the system's autofill gave for the card's site, as the host's word says it came: sent, the ask let go)
  v.reacts(
    fn() {
      if step() == "auto" {
        match @hostapi.autofill_take() {
          Some((host, username, password)) if host == ask().site => Some((username, password))
          _ => None
        }
      } else {
        None
      }
    },
    fn(got) {
      match got {
        Some((username, password)) =>
          @signals.untracked(fn() {
            @hostapi.autofill_end()
            signin_send(core, station, now(), username, password, "")
          })
        None => ()
      }
    },
  )
  // (signed in and to be kept: approved here as the core says so, once; the request is this device's to approve)
  v.reacts(
    fn() {
      let a = ask()
      if a.status == "done" && a.save != "" && a.kept == "" && !signin_saving.contains(a.save) {
        a.save
      } else {
        ""
      }
    },
    fn(save) {
      if save != "" {
        @signals.untracked(fn() {
          signin_saving[save] = "asked"
          (core.call)("vault.approve", { "workspace": Json::string(workspace_of(station)), "request": Json::string(save) }, fn(r) {
            match r {
              Err(e) => {
                signin_saving[save] = "failed"
                (core.say)(@sf.t("android-misc.signin.saveFailed", args=[("why", @settings.error_text(e))]))
              }
              Ok(_) => ()
            }
          })
        })
      }
    },
  )
  let note = fn() {
    let a = ask()
    match a.status {
      "done" =>
        @sf.t(if signin_saving.get(a.save) == Some("failed") { "android-misc.signin.saveFailedShort" } else { "android-misc.signin.saving" })
      "left" => @sf.t("android-misc.signin.left")
      "filling" => ""
      "code" => @sf.t("android-misc.signin.code", args=[("site", a.site)])
      "person" => signin_person_words(a)
      _ =>
        match step() {
          "said" => signin_notes.get(a.id).unwrap_or("")
          "auto" => @sf.t("android-misc.screen.fill.autoPick", args=[("host", a.site)])
          "choosing" => @sf.t("android-misc.screen.fill.pick", args=[("host", a.site)])
          // (1Password can take a while, a request of its to its servers slow: what it waits for said, and the
          // screen still there to sign in on instead)
          "listing" | "getting" | "otp" => @sf.t("android-misc.screen.fill.asking")
          _ => ""
        }
    }
  }
  let buttons = fn() {
    match ask().status {
      "done" | "left" => NoButtons
      "filling" => Filling
      "code" => Code
      "person" => Person
      _ =>
        if step() == "choosing" {
          Choosing
        } else {
          Asking(signin_manager())
        }
    }
  }
  // (a code's field: what is typed in it sent by Enter or 继续, then emptied)
  let field = @ui.Field::new()
  let send = fn(words : String) {
    let code = words.trim(chars=" ").to_owned()
    if code != "" {
      field.set("")
      signin_send(core, station, now(), "", "", code)
    }
  }
  let screen = fn() { (core.open_screen)(station, now().screen) }
  v.box(fn(f) {
    @sf.style_node(f, fn() { signin_foot_room })
    f.show(fn() { note() != "" }, fn(s) { @sf.words_node(s, note, fn() { @sf.ask_note }) |> ignore })
    // (reaching out to the foot's corners as the buttons under it do: the field's ends where theirs are, its words
    // where theirs are)
    f.show(fn() { ask().status == "code" }, fn(s) {
      s.width_share(Is(1.0)) |> ignore
      s.box(fn(b) {
        @sf.style_node(b, fn() { signin_typed.then(@sf.over_foot_reach(@sf.button_height())) })
        @sf.input_node(b, field, placeholder=@sf.t("android-misc.signin.codeField"), solid=true, card_words=true, submitted=send)
        |> ignore
      })
      |> ignore
    })
    f.show(fn() { buttons() != NoButtons }, fn(s) {
      s.width_share(Is(1.0)) |> ignore
      s.pick(at_once=true, buttons, fn(p, kind) {
        p.width_share(Is(1.0)) |> ignore
        p.box(fn(col) {
          @sf.style_node(col, fn() { signin_foot_room })
          let button = fn(
            label : () -> String,
            press : () -> Unit,
            tone : @sf.Tone,
            busy : () -> Bool,
            disabled : () -> Bool,
          ) -> (@view.View) -> Unit {
            fn(at) { @sf.button_node(at, label, press, tone~, busy~, disabled~, card_words=true) |> ignore }
          }
          let never = fn() { false }
          let sending = fn() { step() == "sending" }
          let keep_chooser = fn(at : @view.View) {
            let keep = fn() { signin_keep.get(id()).unwrap_or(true) }
            let words = fn(k : Bool) { @sf.t(if k { "android-misc.signin.keep" } else { "android-misc.signin.keepNot" }) }
            @sf.chooser_button_node(
              at,
              fn() { words(keep()) },
              fn() { [("keep", words(true)), ("not", words(false))] },
              fn() { if keep() { "keep" } else { "not" } },
              fn(k) { signin_keep[now().id] = k == "keep" },
              side=Top,
              card_words=true,
            )
            |> ignore
          }
          if kind is Choosing {
            let choices = fn() {
              signin_runs.get(id()).map(fn(r) { r.choices.get().mapi(fn(i, l) { (i, l) }) }).unwrap_or([])
            }
            col.box(fn(list) {
              @sf.style_node(list, fn() { signin_typed.then(@sf.over_foot_reach(@sf.button_height())) })
              list.each(at_once=true, choices, fn(p) { (p.0, p.1.id) }, fn(r, item) {
                let words = fn() {
                  let l = item.get().1
                  if l.username == "" { l.title } else { l.title + " · " + l.username }
                }
                signin_choice_node(r, words, fn() { signin_pick(core, station, now(), item.untracked().1) })
              })
            })
            |> ignore
          }
          let parts = match kind {
            NoButtons => []
            Filling => [button(fn() { @sf.t("android-misc.signin.filling") }, fn() {  }, Primary, fn() { true }, fn() { true })]
            Code =>
              [
                button(
                  fn() { @sf.t("android-misc.signin.codeSend") },
                  fn() { send(field.text()) },
                  Primary,
                  sending,
                  fn() { field.text().trim(chars=" ").to_owned() == "" || sending() },
                ),
                button(fn() { @sf.t("android-misc.signin.openScreen") }, screen, Ghost, never, never),
              ]
            Person =>
              [
                button(fn() { @sf.t("android-misc.signin.openScreen") }, screen, Primary, never, never),
                button(fn() { @sf.t("android-misc.signin.doneSelf") }, fn() { signin_self(core, station, now(), true) }, Ghost, never, never),
              ]
            Choosing =>
              [
                button(
                  fn() { @sf.t("android-misc.signin.onScreen") },
                  fn() {
                    signin_stop(now().id)
                    signin_self(core, station, now(), false)
                  },
                  Ghost,
                  never,
                  sending,
                ),
                keep_chooser,
              ]
            Asking(manager) => {
              let asking = fn() {
                match step() {
                  "listing" | "getting" | "otp" | "sending" => true
                  _ => false
                }
              }
              let parts = if manager {
                [
                  button(
                    fn() { @sf.t(if @hostapi.passwords() { "android-misc.signin.withOp" } else { "android-misc.signin.withAuto" }) },
                    fn() { signin_start(core, station, now()) },
                    Primary,
                    asking,
                    asking,
                  ),
                  // (while 1Password is asked too: it is let go of then)
                  button(
                    fn() { @sf.t("android-misc.signin.onScreen") },
                    fn() {
                      signin_stop(now().id)
                      signin_self(core, station, now(), false)
                    },
                    Ghost,
                    never,
                    sending,
                  ),
                ]
              } else {
                [button(fn() { @sf.t("android-misc.signin.onScreen") }, fn() { signin_self(core, station, now(), false) }, Primary, never, never)]
              }
              parts.push(keep_chooser)
              parts
            }
          }
          // (each line over the one before it, the first at the foot: the old ask_buttons')
          @sf.ask_buttons_node(col, fn(f) {
            for part in parts {
              part(f)
            }
          })
          |> ignore
        })
        |> ignore
      })
    })
  })
  |> ignore
}

///|
/// A sign-in's foot: what is on it 14 apart (a card's), across the card.
// kept across runs: a value (no field of it changes)
let signin_foot_room : @ui.Style = @ui.css("w=Full gap=S3_5")

///|
/// One of 1Password's logins for the site, as a node of the window's tree (signin_choice's).
fn signin_choice_node(v : @view.View, words : () -> String, on_press : () -> Unit) -> Unit {
  @sf.action_box_node(v, words, fn(_) { on_press() }, fn(row) {
    @sf.style_node(row, signin_choice_box)
    row.ground(By(fn() { @ui.tree_theme().color(Faint) })) |> ignore
    @sf.hover_ground_node(row, lit=Some(fn() { row.focus_shown() || row.pointed() || row.pressed() }))
    @sf.words_node(row, words, signin_choice_words) |> ignore
    @sf.icon_node(row, "chevron-right", 16.0, By(fn() { @ui.tree_theme().color(Muted) })).shrink(Is(0.0)) |> ignore
  })
  |> ignore
}
