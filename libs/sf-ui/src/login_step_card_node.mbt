// A station's login to a command-line tool as its card (the app's sfpages login_card.mbt, which works out what it says
// from the core's `machineLogin` and `machineLogins` and does what is pressed), as nodes of the window's tree, made
// once: its title with 取消 as its × in the card's corner, the lines of how it stands or what to do (a spinner before
// one that waits, red what kept this device from the callback), a device code to read and copy, a code pasted back in
// its field with 完成 at its end, the step's button the card's width (solid while it is the next thing to do, ↗ for a
// page opened elsewhere) with the other ways of doing it in a ⋯ beside it, and ended, one quiet line. A step left of
// something under an agent's message looks the same (step_card_node). What it shows and does is given to it, as each
// says it now.
//
// And what every card of an agent's request shares once it is answered (the app's settings' rig, phone, vault and
// sign-in cards): its answer fading out where it is as how it went fades in over its room (answered_in_place_node), and
// one line saying how it went with a dot beside it, pressed for the card read again where it has a history
// (ask_outcome_node).

///|
/// A line of how a login stands or what to do: red, what kept this device from the callback; busy, a spinner before
/// it; last, as far from the card's foot as the title from its top.
pub(all) struct LoginSaid {
  words : String
  red : Bool
  busy : Bool
  last : Bool
}

///|
/// A step's button: by its key, its words, solid while it is the next thing to do, spinning while it is under way, ↗
/// for a page opened elsewhere, the other ways of doing it in a ⋯ beside it, last in the card; `press` what it does, at
/// once; `told`: in an old view, told by that key once the frame's builds are over (what is pressed as it is built:
/// Ctx::tell), else done as it is pressed.
pub(all) struct LoginStep {
  key : String
  label : String
  solid : Bool
  busy : Bool
  external : Bool
  more : Array[MenuItem]
  last : Bool
  press : () -> Unit
  told : String?
}

///|
/// A step with nothing in it (what a card's step reads while it has none: the button going as another comes).
// kept across runs: a value (no field of it changes)
let login_step_none : LoginStep = {
  key: "",
  label: "",
  solid: false,
  busy: false,
  external: false,
  more: [],
  last: true,
  press: fn() {  },
  told: None,
}

///|
/// A login's card in `parent`, as `title` says it now: where it is (`in_sheet`: across a panel's body, its login sheet,
/// concentric with its sides and foot; else under what is above it, as wide as what it holds, 360 at least where there
/// is the room, 560 at most), `marked` (the one a link pointed to: its ground the accent, faint), its title and, where
/// it may be cancelled here (`cancel`: whether it is being cancelled, and what cancels it), 取消 as the × in its corner
/// beside it; then `body` (what it shows now) in the card.
#callsite(autofill(loc))
pub fn login_step_card_node(
  parent : @view.View,
  title : () -> String,
  body : (@view.View) -> Unit,
  in_sheet? : Bool = false,
  marked? : Bool = false,
  cancel? : (() -> Bool, () -> Unit),
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(room) {
    // (in a panel's body (its login sheet): all of its width, concentric with its sides and its foot)
    style_node(room, fn() {
      if in_sheet {
        login_room_sheet.then(panel_card_out_node(room)).then(panel_card_last_node(room))
      } else {
        login_room
      }
    })
    room.box(fn(card) {
      style_node(card, fn() {
        match (in_sheet, marked) {
          (true, true) => login_card_body_marked.then(lc_card_across)
          (true, false) => login_card_body.then(lc_card_across)
          (false, true) => login_card_body_marked
          (false, false) => login_card_body
        }
      })
      // (what is on it as wide as it, a step's button the card's width: its own lines up at the start)
      card.lines_up(Is(None)) |> ignore
      // (as wide as what it holds, 360 at least where there is the room: within the width its place gives it)
      card.min_width(Is(Some(lc_card_least)), within=true).max_width(Is(Some(lc_card_most)), within=true) |> ignore
      let head = fn(t : @view.View, in_row : Bool) {
        t.box(fn(r) {
          style_node(r, fn() { login_title_room }, in_row~)
          words_node(r, title, fn() { login_title }) |> ignore
        })
        |> ignore
      }
      match cancel {
        Some((busy, press)) => {
          card.box(fn(h) {
            style_node(h, fn() { login_head })
            head(h, true)
            login_cancel_node(h, busy, press)
          })
          |> ignore
          body(card)
        }
        None => {
          head(card, false)
          body(card)
        }
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// An ended login's one quiet line in `parent`, as `words` and `failed` (said in red) say it now.
pub fn login_ended_node(parent : @view.View, words : () -> String, failed : () -> Bool) -> Unit {
  words_node(parent, words, fn() { if failed() { login_ended_failed } else { login_ended } }) |> ignore
}

///|
/// 取消 as the card's × (CancelLogin: a small panel's icon button, in its corner, concentric with it), spinning while
/// it is done (`busy`).
fn login_cancel_node(h : @view.View, busy : () -> Bool, press : () -> Unit) -> Unit {
  action_box_node(h, fn() { t("web-main.logins.cancelWhat") }, fn(_) { press() }, disabled=fn() { busy() }, fn(b) {
    style_node(b, fn() { if lit_node(b) && !busy() { lc_cancel_lit } else { login_cancel } }, in_row=true)
    b.pick(busy, fn(m, spins) {
      if spins {
        spinner_node(m, size=login_spin) |> ignore
      } else {
        icon_node(m, "close", login_icon, By(fn() { theme().p.muted })) |> ignore
      }
    })
  })
  |> ignore
}

///|
/// A line of how it stands or what to do (cardStatus: 12 on 18, grey; red what kept this device from the callback), a
/// spinner 6 before it while it waits; `last`, as far from the card's foot as the title from its top; as `s` says it
/// now.
#callsite(autofill(loc))
pub fn login_said_node(p : @view.View, s : () -> LoginSaid, loc~ : SourceLoc) -> Unit {
  p.box(made_for=loc, fn(b) {
    style_node(b, fn() { if s().last { login_said_last } else { login_said } })
    b.show(fn() { s().busy }, fn(x) { spinner_node(x, size=login_spin) |> ignore })
    words_node(b, fn() { s().words }, fn() { if s().red { login_said_red } else { login_said_words } }) |> ignore
  })
  |> ignore
}

///|
/// What a login under way shows in its card, its lines, code and step as far apart as the card's: `body` in `card`,
/// told whether its page gives a code to paste back (`paste`), made again as that changes.
pub fn login_active_node(card : @view.View, paste : () -> Bool, body : (@view.View, Bool) -> Unit) -> Unit {
  card.pick(paste, fn(x, pasted) {
    // (its lines, its code and its step as far apart as the card's own: login_card_body's)
    style_node(x, fn() { lc_active })
    body(x, pasted)
  })
}

///|
/// What a login under way shows (ActiveCard's) in `x`, as each says it now: its lines (`said`), its device code where
/// it has one (`code`: pressed, given to `copy`), its step's button where it has one.
pub fn login_lines_node(
  x : @view.View,
  said : () -> Array[LoginSaid],
  code : () -> String,
  step : () -> LoginStep?,
  copy : (String) -> Unit,
) -> Unit {
  x.each(fn() { said().mapi(fn(i, _) { i }) }, fn(i) { i }, fn(r, i) {
    let i = i.untracked()
    login_said_node(r, fn() { said().get(i).unwrap_or({ words: "", red: false, busy: false, last: false }) })
  })
  x.show(fn() { code() != "" }, fn(r) { login_code_node(r, code, copy) })
  x.show(fn() { step() is Some(_) }, fn(r) { login_step_node(r, fn() { step().unwrap_or(login_step_none) }) })
}

///|
/// The device code (CardCode), large enough to read and copy by eye, as `code` says it now: pressed, given to `copy`
/// (nothing opened).
pub fn login_code_node(p : @view.View, code : () -> String, copy : (String) -> Unit) -> Unit {
  action_box_node(p, fn() { t("web-main.logins.copyCode") + " " + code() }, fn(_) { copy(code()) }, fn(b) {
    style_node(b, fn() { login_code_room })
    b.box(fn(w) {
      w
      .words_runs(By(fn() { [@ui.span(code(), mono=true)] }))
      .words_look(By(fn() { @ui.style_words(login_code) }))
      .ink(By(fn() { @ui.style_ink(login_code) }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A step's button (StepButton), as `s` says it now: the card's width, solid while it is the next thing to do, a plain
/// grey one once it has been, lit under the hand; a spinner while it is under way, ↗ for a page opened elsewhere; the
/// other ways in a ⋯ beside it.
pub fn login_step_node(p : @view.View, s : () -> LoginStep) -> Unit {
  let foot = fn(style : @ui.Style) { if s().last { style.then(login_foot_reach) } else { style } }
  let button = fn(at : @view.View, in_row : Bool) {
    action_box_node(at, fn() { s().label }, fn(_) { (s().press)() }, disabled=fn() { s().busy }, fn(b) {
      style_node(
        b,
        fn() {
          let now = s()
          let lit = lit_node(b) && !now.busy
          let look = match (now.solid, lit) {
            (true, true) => lc_step_solid_lit
            (true, false) => login_step_solid
            (false, true) => lc_step_lit
            (false, false) => login_step
          }
          let step = if in_row {
            look.then(login_in_row)
          } else {
            foot(look)
          }
          step.then(login_inner_round)
        },
        in_row~,
      )
      let ink = fn() { if s().solid { theme().p.on_primary } else { theme().p.text } }
      b.show(fn() { s().busy }, fn(x) { spinner_node(x, size=login_spin, arc=ink) |> ignore })
      words_node(b, fn() { s().label }, fn() { if s().solid { login_step_words_solid } else { login_step_words } }) |> ignore
      b.show(fn() { s().external }, fn(x) { icon_node(x, "arrow-up-right", login_icon, By(ink)) |> ignore })
    })
    |> ignore
  }
  p.pick(fn() { s().more.is_empty() }, fn(x, alone) {
    if alone {
      button(x, false)
      return
    }
    // the other ways of doing the step, seldom used, in a ⋯ at the row's end (align.mbt: what is used least goes into
    // the row's ⋯)
    x.box(fn(r) {
      style_node(r, fn() { foot(login_step_row) })
      button(r, true)
      action_box_node(r, fn() { t("common.login.otherWays") }, fn(m) {
          let (wx, wy, ww, wh) = m.placed_window_now()
          menu(s().more.map(fn(i) { Some(i) }), from=At(wx, wy, ww, wh), along=End)
        }, fn(m) {
        style_node(m, fn() { (if lit_node(m) { lc_more_lit } else { login_more }).then(login_inner_round) }, in_row=true)
        icon_node(m, "more", login_icon, By(fn() { theme().p.text })) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// A login whose page gives a code to paste back (PasteSteps) in `x`, as each says it now: its line (`lead`) and its
/// step, then `field`, 完成 at its end once a code is in (Enter too), given to `send`; sent, the keyboard goes, the code
/// stays and 完成 turns while it is sent or checked (`busy`: nothing more sent).
#callsite(autofill(loc))
pub fn login_paste_node(
  x : @view.View,
  lead : () -> LoginSaid,
  step : () -> LoginStep,
  field : @ui.Field,
  busy : () -> Bool,
  send : (String) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let words = fn() { field.text().trim(chars=" \n").to_owned() }
  login_said_node(x, lead)
  login_step_node(x, step)
  // sent, nothing is left to type: the keyboard goes (the code stays in the field as it is checked)
  let sent = fn(code : String) {
    // (let go of on either side of what hosts the tree, its keyboard with it: View::focus_let_go)
    x.focus_let_go()
    send(code)
  }
  x.box(made_for=loc, fn(b) {
    style_node(b, fn() { login_paste.then(login_inner_round) })
    b.box(fn(w) {
      style_node(w, fn() { login_paste_words }, in_row=true)
      @ui.field(
        w,
        field,
        placeholder=t("web-main.logins.pasteCode"),
        font_size=login_paste_size,
        line=login_paste_line,
        max_lines=1,
        enter_sends=true,
        colors_by=fn() {
          let p = theme().p
          (p.text, p.muted, p.accent)
        },
        submitted=fn(said) {
          let code = said.trim(chars=" \n").to_owned()
          if code != "" && !busy() {
            sent(code)
          }
        },
      )
      |> ignore
    })
    |> ignore
    b.show(fn() { words() != "" || busy() }, fn(d) {
      action_box_node(d, fn() { t("web-main.logins.finish") }, fn(_) { sent(words()) }, disabled=fn() { busy() }, fn(go) {
        style_node(go, fn() { (if lit_node(go) && !busy() { lc_done_lit } else { login_done }).then(login_done_round) }, in_row=true)
        // busy: a spinner over its word, as wide as before
        words_node(go, fn() { t("web-main.logins.finish") }, fn() { login_done_words }).alpha(By(fn() {
          if busy() {
            0.0
          } else {
            1.0
          }
        }))
        |> ignore
        go.show(busy, fn(s) {
          s.over(Is(true)) |> ignore
          style_node(s, fn() { login_done_spin })
          spinner_node(s, size=login_spin, arc=fn() { theme().p.on_primary }) |> ignore
        })
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// A step left of something under an agent's message, as a login's card looks (its ground, its title, a line under it
/// where there is one), as each says it now: the whole card the way to it (`go`) with a › in its corner where a login's
/// × is; none to go by, the card alone, taking no press. Quiet as the cards beside it are, no button of its own.
#callsite(autofill(loc))
pub fn step_card_node(
  v : @view.View,
  title : () -> String,
  line : () -> String,
  go : () -> (() -> Unit)?,
  loc~ : SourceLoc,
) -> Unit {
  v.box(made_for=loc, fn(room) {
    style_node(room, fn() { login_room })
    let goes = fn() { go() is Some(_) }
    // (the button across the room, lined up at its start: its card as wide as the plain one, by the room's width)
    button_while_node(loc~, room, goes, title, fn(_) {
      match @signals.untracked(go) {
        Some(f) => f()
        None => ()
      }
    }, across=Start, fn(card, _) {
      style_node(card, fn() { if goes() && lit_node(card) { lc_card_step_lit } else { login_card } })
      card.box(fn(h) {
        style_node(h, fn() { login_head })
        h.box(fn(t) {
          style_node(t, fn() { if line() == "" { login_title_alone } else { login_title_room } }, in_row=true)
          words_node(t, title, fn() { login_title }) |> ignore
        })
        |> ignore
        h.show(goes, fn(b) {
          style_node(b, fn() { login_cancel }, in_row=true)
          icon_node(b, "chevron-right", login_icon, By(fn() { theme().p.muted })) |> ignore
        })
      })
      |> ignore
      card.show(fn() { line() != "" }, fn(s) {
        login_said_node(s, fn() { { words: line(), red: false, busy: false, last: true } })
      })
    })
    |> ignore
  })
  |> ignore
}

// ── how a login's card looks (its old view's, the app's, as well) ───────────────

///|
/// The card (card): under the agent's message as a decision's options are, as wide as what it holds and at least 360
/// where there is the room (minWidth: min(100%, 360px)), 560 at most and never wider than where it is (min(100%,
/// 560px), as a vault item's card: not drawn across a wide chat's column), 8 in all round, its parts 2
/// apart, on the ink at 5%; its corner its padding and its × pill's; the accent at 10% when it is the one a link
/// pointed to.
// kept across runs: a value (no field of it changes)
pub let login_card : @ui.Style = login_card_body.then(@ui.style(min_w=login_card_least, max_w=login_card_most))

///|
/// The card but how wide it is (its node's: that by where it is, as laid out).
// kept across runs: a value (no field of it changes)
pub let login_card_body : @ui.Style = @ui.style(w=Cut, p=inset_room, gap=S0_5, radius=login_card_corner, bg=A(Fg, O5), align=AStart)

///|
/// What a login under way shows in its card (login_active_node's): its lines, code and step as far apart as the card's.
// kept across runs: a value (no field of it changes)
let lc_active : @ui.Style = @ui.css("gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
pub let login_card_body_marked : @ui.Style = login_card_body.then(@ui.css("bg=A(Accent,O10)"))

///|
/// How wide the card is at least and at most where there is the room (login_card_least's, login_card_most's).
let lc_card_least : Double = 360.0

///|
let lc_card_most : Double = 560.0

///|
/// Where it is: all of the column's width, 8 under what is above it (the card in it as wide as it says).
// kept across runs: a value (no field of it changes)
pub let login_room : @ui.Style = @ui.css("w=Full pt=S2 align=AStart")

///|
/// In a panel's body (its login sheet): full width, concentric with the panel's sides and foot; its card across it.
// kept across runs: a value (no field of it changes)
pub let login_room_sheet : @ui.Style = @ui.css("w=Full align=AStart")

///|
// kept across runs: a value (no field of it changes)
let lc_card_across : @ui.Style = @ui.css("w=Full")

///|
/// Ended: 12 on 18 in the subtle ink; failed, red.
// kept across runs: a value (no field of it changes)
pub let login_ended : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Subtle)

///|
// kept across runs: a value (no field of it changes)
pub let login_ended_failed : @ui.TextStyle = login_ended.then(@ui.text_style(color=Danger))

///|
/// Its title and its × (cardHead): the title takes the row, the × in the card's top corner, 4 apart.
// kept across runs: a value (no field of it changes)
pub let login_head : @ui.Style = @ui.css("row w=Full gap=S1 align=AStart")

///|
/// Its title (cardTitle): 13 on 20, medium, 10 in and 10 down (a small panel's row).
// kept across runs: a value (no field of it changes)
pub let login_title_room : @ui.Style = @ui.css("w=Full px=S2_5 pt=S2_5")

///|
/// Its title with no line under it (step_card_node's): as far from the card's foot as from its top, as a last line is.
// kept across runs: a value (no field of it changes)
pub let login_title_alone : @ui.Style = login_title_room.then(@ui.css("pb=S2_5"))

///|
// kept across runs: a value (no field of it changes)
pub let login_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, leading=L5)

///|
/// 取消 (PanelIconButton): 24, round, its ground under the pointer, in the card's top end corner as far in as makes it
/// concentric with it (capsule_in: the card's corner less its half), past the card's padding.
// kept across runs: a value (no field of it changes)
pub let login_cancel : @ui.Style = @ui.css("w=S6 h=S6 radius=Full align=ACenter justify=JCenter hovered{bg=Hover}").then(
  @ui.style(mt=room_of(lc_cancel_off), mr=room_of(lc_cancel_off)),
)

///|
/// 取消 under the hand (its node's: login_cancel's hovered).
// kept across runs: a value (no field of it changes)
let lc_cancel_lit : @ui.Style = login_cancel.then(@ui.css("bg=Hover"))

///|
/// How far past the card's padding 取消 stands (login_cancel), and its side (S6).
let lc_cancel_off : Double = @ui.capsule_in(card_corner, lc_cancel_side) - corner_inset

///|
let lc_cancel_side : Double = 24.0

///|
/// A line of how it stands (cardStatus): 12 on 18, grey, 10 in, a spinner 6 before it; last, 10 over the card's foot.
// kept across runs: a value (no field of it changes)
pub let login_said : @ui.Style = @ui.css("row px=S2_5 gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
pub let login_said_last : @ui.Style = login_said.then(@ui.css("pb=S2_5"))

///|
// kept across runs: a value (no field of it changes)
pub let login_said_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted)

///|
// kept across runs: a value (no field of it changes)
pub let login_said_red : @ui.TextStyle = login_said_words.then(@ui.text_style(color=Danger))

///|
/// The device code (cardCode): 10 in, 4 over and under; its words the heading's size, semibold, in the code face.
// kept across runs: a value (no field of it changes)
pub let login_code_room : @ui.Style = @ui.css("px=S2_5 py=S1")

///|
// kept across runs: a value (no field of it changes)
pub let login_code : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Fg, wrap=false)

///|
/// A step's button (cardStep): the card's width, 32 high, 8 under what is above it, 12 in, its corner the card's less
/// its padding; the ink at 5% (the pointer's over it, mbui ui/hand_moves.mbt), solid (the primary's, a step towards
/// the page under the pointer) while it is the next thing to do; its words 13 medium, a spinner or ↗ 6 beside them.
// kept across runs: a value (no field of it changes)
pub let login_step : @ui.Style = @ui.css(
  "row w=Full h=S8 mt=S2 px=S3 gap=S1_5 radius=Inner bg=A(Fg,O5) align=ACenter justify=JCenter hovered{bg=Hover}",
).then(@ui.style(mx=room_of(-lc_step_reach)))

///|
/// How far past the card's padding a step's button (a capsule 32 high, in the card's foot corners where it is last, a
/// pasted code's field so: login_paste) reaches,
/// to stand concentric with them (capsule_in: 8.87 in, the card's padding 10).
let lc_step_reach : Double = corner_inset - @ui.capsule_in(card_corner, 32.0)

///|
// kept across runs: a value (no field of it changes)
pub let login_step_solid : @ui.Style = login_step.then(@ui.css("bg=Primary hovered{bg=Over(Primary, A(Bg, O15))}"))

///|
/// A step's button under the hand (its node's: login_step's and login_step_solid's hovered).
// kept across runs: a value (no field of it changes)
let lc_step_lit : @ui.Style = login_step.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value (no field of it changes)
let lc_step_solid_lit : @ui.Style = login_step_solid.then(@ui.css("bg=Over(Primary, A(Bg, O15))"))

///|
/// A step's button with its ⋯ (a step's `more`): the row 8 under what is over it, the button the rest of it, the ⋯ a
/// round one as high, 6 after it, on the step's grey.
// kept across runs: a value (no field of it changes)
pub let login_step_row : @ui.Style = @ui.css("row w=Full mt=S2 gap=S1_5 align=ACenter").then(
  @ui.style(mx=room_of(-lc_step_reach)),
)

///|
/// What is last in the card reaching its foot as far as its sides (lc_step_reach).
// kept across runs: a value (no field of it changes)
pub let login_foot_reach : @ui.Style = @ui.style(mb=room_of(-lc_step_reach))

///|
/// A step's button beside its ⋯: none of its own room round it.
// kept across runs: a value (no field of it changes)
pub let login_in_row : @ui.Style = @ui.css("mt=S0 mx=S0 mb=S0")

///|
// kept across runs: a value (no field of it changes)
pub let login_more : @ui.Style = @ui.css("w=S8 h=S8 radius=Inner bg=A(Fg,O5) align=ACenter justify=JCenter hovered{bg=Hover}")

///|
/// The ⋯ under the hand (its node's).
// kept across runs: a value (no field of it changes)
let lc_more_lit : @ui.Style = login_more.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value (no field of it changes)
pub let login_step_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
pub let login_step_words_solid : @ui.TextStyle = login_step_words.then(@ui.text_style(color=OnPrimary))

///|
/// The code pasted back (cardPaste): the card's width, 32 high, 6 under the step, 12 in on the left and 4 on the right,
/// on the canvas, its corner the step's; 完成 at its end (cardPasteDone): 24 high, 12 in, solid, its corner the field's
/// less 4, its words 12 medium.
// kept across runs: a value (no field of it changes)
pub let login_paste : @ui.Style = @ui.css("row w=Full h=S8 mt=S1_5 pl=S3 pr=S1 gap=S1 radius=Inner bg=Bg align=ACenter").then(
  @ui.style(mx=room_of(-lc_step_reach), mb=room_of(-lc_step_reach)),
)

///|
// kept across runs: a value (no field of it changes)
pub let login_paste_words : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
pub let login_done : @ui.Style = @ui.css(
  "row h=S6 px=S3 radius=Inner bg=Primary align=ACenter justify=JCenter hovered{bg=Over(Primary, A(Bg, O15))}",
)

///|
// kept across runs: a value (no field of it changes)
let lc_done_lit : @ui.Style = login_done.then(@ui.css("bg=Over(Primary, A(Bg, O15))"))

///|
// kept across runs: a value (no field of it changes)
pub let login_done_spin : @ui.Style = @ui.css("w=Full h=Full align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
pub let login_done_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=OnPrimary, wrap=false)

///|
/// The field's words (cardPasteInput): the ui's 13 on 20.
pub let login_paste_size : Double = 13.0

///|
pub let login_paste_line : Double = 20.0

///|
/// The spinner's and the icons' sizes (Spinner inline, Close 14, ArrowUpRight 14).
pub let login_spin : Double = 12.0

///|
pub let login_icon : Double = 14.0

///|
/// The corner of what stands in the card's corners as a step's button does (Inner, its node's: concentric with the
/// card, as far in as lc_step_reach leaves it), and 完成's in the pasted code's field (4 in from its end).
let lc_inner_corner : Double = @ui.concentric(card_corner, @ui.capsule_in(card_corner, 32.0))

///|
let lc_done_corner : Double = @ui.concentric(lc_inner_corner, 4.0)

///|
// kept across runs: a value (no field of it changes)
pub let login_inner_round : @ui.Style = @ui.style(radius=radius_between(lc_inner_corner))

///|
// kept across runs: a value (no field of it changes)
pub let login_done_round : @ui.Style = @ui.style(radius=radius_between(lc_done_corner))

///|
/// A step's card (step_card_node) under the pointer: lit, as the old view's hovered.
// kept across runs: a value (no field of it changes)
let lc_card_step_lit : @ui.Style = login_card.then(@ui.css("bg=Hover"))

// ── a request's card answered ─────────────────────────────────────────────────

///|
/// A card's answer at its foot, made by `answer` in `v` (answered_in_place's, as nodes), as `ended` says it now (whether
/// it was granted, and how it went in words): answered, the answer fades out where it is (answered_fade_ms, Leave),
/// taking no press, then how it went fades in after it over the room it leaves (as long, eased out), its dot and its
/// words in the middle of it. The answer stays laid out, unseen: the card keeps its size to the point. Answered before
/// it is made, how it went is there at once.
#callsite(autofill(loc))
pub fn answered_in_place_node(
  v : @view.View,
  ended : () -> (Bool, Array[@ui.Run])?,
  answer : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let gone = fn() { ended() is Some(_) }
  let first = @signals.untracked(gone)
  let was = @motion.NodeWay::new(if first { 0.0 } else { 1.0 })
  let now = @motion.NodeWay::new(if first { 1.0 } else { 0.0 })
  v.box(made_for=loc, fn(whole) {
    style_node(whole, fn() { answered_whole })
    whole.reacts(gone, fn(g) {
      if g {
        was.go_ms(whole, 0.0, answered_fade_ms, ease=Leave)
        now.go(whole, 1.0, @motion.tween(answered_fade_ms, ease=Out, delay=answered_fade_ms))
      } else {
        now.put(0.0)
        was.put(1.0)
      }
    })
    whole.box(fn(a) {
      style_node(a, fn() { answered_room })
      a.alpha(By(fn() { was.shown(a) })).presses(By(fn() { !gone() })) |> ignore
      answer(a)
    })
    |> ignore
    // (over the answer's room, the whole of it)
    whole.box(fn(o) {
      o.over(Is(true)).alpha(By(fn() { now.shown(o) })) |> ignore
      o.box(fn(r) {
        style_node(r, fn() { answered_over })
        r.box(fn(d) {
          style_node(d, fn() {
            match ended() {
              Some((true, _)) => ask_dot_on
              _ => ask_dot
            }
          })
        })
        |> ignore
        r.box(fn(w) {
          w
          .words_runs(By(fn() { ended().map(fn(e) { e.1 }).unwrap_or([]) }))
          .words_look(By(fn() { @ui.style_words(ask_ended_words) }))
          .ink(By(fn() { @ui.style_ink(ask_ended_words) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A request's outcome line in `v` (ask_outcome's, as nodes), as they say it now: a dot (green while `granted`) and its
/// `words`; the dot in the middle of the words' first line, under the message's picture as wide as it where the
/// message's head is `inline`, else out in the margin where the picture is, the words at the row's start. `history`:
/// pressed, the card read again (given what it opens from).
#callsite(autofill(loc))
pub fn ask_outcome_node(
  v : @view.View,
  granted : () -> Bool,
  words : () -> Array[@ui.Run],
  inline : () -> Bool,
  history? : ((@view.View) -> Unit)? = None,
  loc~ : SourceLoc,
) -> Unit {
  let th = ui_theme()
  let line = th.leading(ask_ended_leading).unwrap_or(th.text_size(ask_ended_size).1)
  v.box(made_for=loc, fn(o) {
    style_node(o, fn() { ask_ended })
    o.box(fn(w) {
      style_node(w, fn() {
        let base = if inline() { ask_ended_past } else { ask_ended_at }
        if history is Some(_) {
          base.then(ask_ended_start)
        } else {
          base
        }
      })
      match history {
        Some(open) => ask_history_trigger_node(w, words, fn() { ask_ended_words }, line, open) |> ignore
        None =>
          w.box(fn(t) {
            t
            .words_runs(By(words))
            .words_look(By(fn() { @ui.style_words(ask_ended_words) }))
            .ink(By(fn() { @ui.style_ink(ask_ended_words) }))
            |> ignore
          })
          |> ignore
      }
    })
    |> ignore
    // (over the line, the whole of it: the dot's room)
    o.box(fn(l) {
      l.over(Is(true)) |> ignore
      l.box(fn(d) {
        style_node(d, fn() {
          (if inline() { ask_dot_line } else { ask_dot_line_out }).then(@ui.style(h=Fixed(node_sp(d, line))))
        })
        d.box(fn(x) { style_node(x, fn() { if granted() { ask_dot_on } else { ask_dot } }) }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// How long a card's answer takes to fade out as it is answered, and how it went to fade in after it.
pub let answered_fade_ms : Double = 200.0

///|
/// How it ended: a dot and its words, a little under what is over it.
// kept across runs: a value (no field of it changes)
pub let ask_ended : @ui.Style = @ui.css("w=Full mt=S0_5")

///|
/// Its words inline: past the message's picture, where its name is (the app's message.mbt msg_head_inline).
// kept across runs: a value (no field of it changes)
pub let ask_ended_past : @ui.Style = @ui.style(w=Full, pl=message_head_in)

///|
/// Its words with the picture out in the margin: at the row's start, as the name is.
// kept across runs: a value (no field of it changes)
pub let ask_ended_at : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
pub let ask_ended_start : @ui.Style = @ui.css("align=AStart")

///|
/// Where the dot stands: as wide as the message's picture (18) and under it, the dot in its middle; as high as a line
/// of the words, the theme's (ask_outcome_node).
// kept across runs: a value (no field of it changes)
pub let ask_dot_line : @ui.Style = @ui.css("row w=S4_5 align=ACenter justify=JCenter")

///|
/// The same out in the margin, where the picture is then (message_avatar_out).
// kept across runs: a value (no field of it changes)
pub let ask_dot_line_out : @ui.Style = ask_dot_line.then(@ui.style(ml=message_avatar_out))

///|
/// A card's answer's room at its foot (answered_in_place_node): the card's width, what is in it as far apart as in the
/// card (ask_card_node's 14).
// kept across runs: a value (no field of it changes)
pub let answered_room : @ui.Style = @ui.css("w=Full gap=S3_5")

///|
/// What holds a card's answer and how it went over it (answered_in_place_node): the card's width.
// kept across runs: a value (no field of it changes)
pub let answered_whole : @ui.Style = @ui.css("w=Full")

///|
/// How it went over a card's answer's room: its dot and its words on a line in the middle of the room's height.
// kept across runs: a value (no field of it changes)
pub let answered_over : @ui.Style = @ui.css("row w=Full h=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
pub let ask_ended_words : @ui.TextStyle = @ui.text_style(size=ask_ended_size, leading=ask_ended_leading, color=Muted)

///|
/// Its words' size and line (ask_ended_words), the line the dot beside them stands in the middle of.
// kept across runs: a value (no field of it changes)
pub let ask_ended_size : @ui.TextSize = Meta

///|
// kept across runs: a value (no field of it changes)
pub let ask_ended_leading : @ui.Leading = L5

///|
/// Its dot, 6 round: green once granted, else quiet.
// kept across runs: a value (no field of it changes)
pub let ask_dot : @ui.Style = @ui.css("w=S1_5 h=S1_5 radius=Full bg=Subtle")

///|
// kept across runs: a value (no field of it changes)
pub let ask_dot_on : @ui.Style = @ui.css("w=S1_5 h=S1_5 radius=Full bg=Positive")
