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
  // (ended, the card fades where it stands as its room gives way to how it went, as a rig's: ask_in_place_node; what
  // it asked held as it was while it was answered, nothing of it answered again once it has ended)
  ask_in_place_node(
    v,
    fn() { signin_over(ask()) },
    ask,
    fn(_) { @sf.ask_card_room.then(ask_card_under_head) },
    fn(r, open_ask) { signin_card_node(r, here, core, open_ask, fn() { m().card }) },
    fn(p) {
      @settings.ask_outcome_node(
        p,
        fn() { ask().status == "done" },
        fn() { [@ui.span(signin_outcome_words(ask()))] },
        fn() { message_inline(here) },
        history=Some(fn(from) {
          card_history_node(from, fn(b) { @sf.ask_words_node(b, title, fn() { ask().reason }) |> ignore })
        }),
      )
    },
  )
}

///|
/// The card (signin_card's, as nodes) in `v`: its title and the agent's reason, a top-right × to cancel while it is
/// open and the viewer's (`signin.deny`), and at its foot what is answered now (signin_foot_node) where it is the
/// viewer's and a core is there; else whose it is, where the card says.
fn signin_card_node(
  v : @view.View,
  here : MessageNodeHere,
  core : @settings.Core?,
  ask : () -> SignInAsk,
  card : () -> Card?,
) -> Unit {
  @sf.ask_card_node(v, fn(k) {
    let answers = fn() { core is Some(_) && mine_to_node(here, card().map(fn(c) { c.assignee }).unwrap_or("")) }
    let who = fn() { card().bind(fn(c) { c.assignee_text }).unwrap_or("") }
    let can_cancel = fn() { answers() && ask().status != "done" }
    k.box(fn(what) {
      @sf.style_node(what, fn() { @sf.ask_what })
      what.box(fn(head) {
        @sf.style_node(head, fn() { signin_head })
        head.box(fn(t) {
          @sf.style_node(t, fn() { signin_head_words }, in_row=true)
          t
          .words_runs(
            By(fn() {
              [@ui.span(@sf.t("android-misc.signin.title", args=[("site", ask().site)]), weight=600, color=@sf.theme().p.text)]
            }),
          )
          .words_look(By(fn() { @ui.style_words(@sf.ask_title) }))
          .ink(By(fn() { @ui.style_ink(@sf.ask_title) }))
          |> ignore
        })
        |> ignore
        head.show(can_cancel, fn(s) {
          match core {
            Some(core) => {
              let id = fn() { ask().id }
              let busy = fn() { signin_steps.get(id()).unwrap_or("") == "denying" }
              let disabled = fn() {
                let st = signin_steps.get(id()).unwrap_or("")
                st == "denying" || st == "sending"
              }
              signin_cancel_node(s, here.tips, busy, disabled, fn() {
                signin_deny(core, here.station, @signals.untracked(ask))
              })
            }
            None => ()
          }
        })
      })
      |> ignore
      what.show(fn() { ask().reason != "" }, fn(n) { @sf.words_node(n, fn() { ask().reason }, fn() { @sf.ask_note }) |> ignore })
    })
    |> ignore
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
      "person" => SignInButtons::Person
      _ =>
        if step() == "choosing" {
          Choosing
        } else {
          SignInButtons::Asking(signin_manager())
        }
    }
  }
  // (a code's field: what is typed in it sent by Enter or 继续, then emptied)
  let field = @ui.Field::new()
  let send = fn(words : String) {
    if @signals.untracked(fn() { step() == "sending" || step() == "denying" }) {
      return
    }
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
      // (one set of buttons for another as what is answered moves on (1Password's logins to pick from, a code asked,
      // filling in): the one before fading where it stood as the foot's room makes its way to the one now, as a
      // card's own parts go (msg_part_leave_ms))
      s.pick(buttons, leave=msg_part_leave_ms, fn(p, kind) {
        p.width_share(Is(1.0)) |> ignore
        p.box(fn(col) {
          @sf.style_node(col, fn() { signin_foot_room })
          let button = fn(
            label : () -> String,
            press : () -> Unit,
            tone : @sf.Tone,
            busy : () -> Bool,
            disabled : () -> Bool,
          ) -> (@view.View, Bool) -> Unit {
            fn(at, across) { @sf.button_node(at, label, press, tone~, busy~, disabled~, across~, card_words=!across) |> ignore }
          }
          let never = fn() { false }
          let sending = fn() { step() == "sending" }
          let denying = fn() { step() == "denying" }
          let busy_end = fn() { sending() || denying() }
          let keep_chooser = fn(at : @view.View) {
            let keep = fn() { signin_keep.get(id()).unwrap_or(true) }
            let words = fn(k : Bool) { @sf.t(if k { "android-misc.signin.keep" } else { "android-misc.signin.keepNot" }) }
            @sf.foot_chooser_node(
              at,
              fn() { words(keep()) },
              fn() { [("keep", words(true)), ("not", words(false))] },
              fn() { if keep() { "keep" } else { "not" } },
              fn(k) { signin_keep[now().id] = k == "keep" },
              disabled=busy_end,
            )
            |> ignore
          }
          let keep_over_chooser = fn(at : @view.View) {
            let keep = fn() { signin_keep.get(id()).unwrap_or(true) }
            let words = fn(k : Bool) { @sf.t(if k { "android-misc.signin.keep" } else { "android-misc.signin.keepNot" }) }
            @sf.capsule_chooser_node(
              at,
              fn() { words(keep()) },
              fn() { [("keep", words(true)), ("not", words(false))] },
              fn() { if keep() { "keep" } else { "not" } },
              fn(k) { signin_keep[now().id] = k == "keep" },
              disabled=busy_end,
              side=Top,
            )
            |> ignore
          }
          if kind is Choosing {
            let choices = fn() {
              signin_runs.get(id()).map(fn(r) { r.choices.get().mapi(fn(i, l) { (i, l) }) }).unwrap_or([])
            }
            col.box(fn(list) {
              @sf.style_node(list, fn() { signin_typed.then(@sf.over_foot_reach(@sf.button_height())) })
              list.each(choices, fn(p) { (p.0, p.1.id) }, fn(r, item) {
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
                  fn() { send(field.commit_composing()) },
                  Primary,
                  sending,
                  fn() { field.composed_said().trim(chars=" ").to_owned() == "" || busy_end() },
                ),
                button(fn() { @sf.t("android-misc.signin.openScreen") }, screen, Plain, never, denying),
              ]
            Person =>
              [
                button(fn() { @sf.t("android-misc.signin.openScreen") }, screen, Primary, never, denying),
                button(fn() { @sf.t("android-misc.signin.doneSelf") }, fn() { signin_self(core, station, now(), true) }, Plain, never, denying),
              ]
            Choosing =>
              [
                button(
                  fn() { @sf.t("android-misc.signin.onScreen") },
                  fn() {
                    signin_stop(now().id)
                    signin_self(core, station, now(), false)
                  },
                  Plain,
                  never,
                  busy_end,
                ),
              ]
            Asking(manager) => {
              let asking = fn() {
                match step() {
                  "listing" | "getting" | "otp" | "sending" => true
                  _ => false
                }
              }
              if manager {
                [
                  button(
                    fn() { @sf.t(if @hostapi.passwords() { "android-misc.signin.withOp" } else { "android-misc.signin.withAuto" }) },
                    fn() { signin_start(core, station, now()) },
                    Primary,
                    asking,
                    fn() { asking() || denying() },
                  ),
                  // (while 1Password is asked too: it is let go of then)
                  button(
                    fn() { @sf.t("android-misc.signin.onScreen") },
                    fn() {
                      signin_stop(now().id)
                      signin_self(core, station, now(), false)
                    },
                    Plain,
                    never,
                    busy_end,
                  ),
                ]
              } else {
                [button(fn() { @sf.t("android-misc.signin.onScreen") }, fn() { signin_self(core, station, now(), false) }, Primary, never, denying)]
              }
            }
          }
          let has_keep = match kind {
            Choosing | Asking(_) => true
            _ => false
          }
          if !has_keep {
            // (each line over the one before it, the first at the foot: the old ask_buttons')
            @sf.ask_buttons_node(col, fn(f) {
              for part in parts {
                part(f, false)
              }
            })
            |> ignore
          } else {
            // (the first that has the room whole: keep_chooser across from the buttons at the card's end corner,
            // concentric with it as phone_ask_node and vault_ask_node do; else on its own line over the buttons, with
            // two pills filling the bottom width cleanly across both foot corners, or stacked when even tighter)
            col.box(fn(r) {
              r.width_share(Is(1.0)).row(Is(true)).one_of(Is(true)) |> ignore
              r.box(fn(f) {
                @sf.style_node(f, fn() { @sf.ask_foot_chosen_end() }, in_row=true)
                f.wraps(By(fn() { Some(@sf.ask_foot_lines()) }), reverse=true) |> ignore
                f.box(fn(g) {
                  @sf.style_node(g, fn() { @sf.ask_foot })
                  for part in parts {
                    part(g, false)
                  }
                })
                |> ignore
                keep_chooser(f)
              })
              |> ignore
              if parts.length() == 2 {
                r.box(fn(w) {
                  w.width_share(Is(1.0)) |> ignore
                  w.box(fn(o) {
                    @sf.style_node(o, fn() { signin_over_keep_plain })
                    keep_over_chooser(o)
                  })
                  |> ignore
                  w.box(fn(f) {
                    @sf.style_node(f, fn() { @sf.ask_foot.then(@sf.foot_reach(@sf.button_height())).then(signin_foot_fill) })
                    f.box(fn(cell) {
                      cell.grow(Is(1.0)) |> ignore
                      (parts[0])(cell, true)
                    })
                    |> ignore
                    f.box(fn(cell) {
                      cell.grow(Is(1.0)) |> ignore
                      (parts[1])(cell, true)
                    })
                    |> ignore
                  })
                  |> ignore
                })
                |> ignore
              }
              r.box(fn(w) {
                w.width_share(Is(1.0)) |> ignore
                w.box(fn(o) {
                  @sf.style_node(o, fn() { signin_over_keep_plain })
                  keep_over_chooser(o)
                })
                |> ignore
                @sf.ask_buttons_node(w, fn(f) {
                  for part in parts {
                    part(f, false)
                  }
                })
                |> ignore
              })
              |> ignore
            })
            |> ignore
          }
        })
        |> ignore
      })
    })
  })
  |> ignore
}

///|
/// A sign-in card's header: its title beside the top-right cancel ×.
// kept across runs: a value (no field of it changes)
let signin_head : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
/// The title inside the sign-in card's header row.
// kept across runs: a value (no field of it changes)
let signin_head_words : @ui.Style = @ui.style(w=@sf.grow)

///|
/// Top-right cancel × (28×28, concentric with the card's corner at 12px from top and right, matching foot_chooser_node's
/// 12px right inset at the bottom-right corner).
let signin_cancel_side : Double = 28.0

///|
let signin_cancel_off : Double = @ui.capsule_in(@sf.card_corner, signin_cancel_side) - @sf.card_pad

///|
// kept across runs: a value (no field of it changes)
let signin_cancel_style : @ui.Style = @ui.css("w=S7 h=S7 radius=Full align=ACenter justify=JCenter hovered{bg=Hover}").then(
  @ui.style(mt=@sf.room_of(signin_cancel_off), mr=@sf.room_of(signin_cancel_off)),
)

///|
// kept across runs: a value (no field of it changes)
let signin_cancel_lit : @ui.Style = signin_cancel_style.then(@ui.css("bg=Hover"))

///|
/// Cancel × in the card's top-right corner, spinning while `signin.deny` is in flight.
fn signin_cancel_node(
  h : @view.View,
  tips : @sf.TipLayer,
  busy : () -> Bool,
  disabled : () -> Bool,
  press : () -> Unit,
) -> Unit {
  let label = fn() { @sf.t("android-misc.signin.cancel") }
  let box = @sf.action_box_node(h, label, fn(_) { press() }, disabled~, fn(b) {
    @sf.style_node(b, fn() { if @sf.lit_node(b) && !disabled() { signin_cancel_lit } else { signin_cancel_style } }, in_row=true)
    b.pick(busy, fn(m, spins) {
      if spins {
        @sf.spinner_node(m, size=14.0) |> ignore
      } else {
        @sf.icon_node(m, "close", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
      }
    })
  })
  @sf.tip_node(tips, box, label) |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let signin_foot_fill : @ui.Style = @ui.css("w=Full")

///|
/// The keep chooser above the buttons on a narrow card: its label aligned directly with the card's title (offset left by
/// chooser_x = 8px so its words start at card_pad).
let signin_over_keep_off : Double = -8.0

///|
// kept across runs: a value (no field of it changes)
let signin_over_keep_plain : @ui.Style = @ui.css("row mb=S2").then(@ui.style(ml=@sf.room_of(signin_over_keep_off)))

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
