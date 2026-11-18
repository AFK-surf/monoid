// The library's chip (chip's) as a node of the window's tree, made once: a little pill of words and an icon on a tint
// of its ink, the tint deeper under the hand as far as that has eased (dur_ms, eased out, from the moment it changed).

///|
/// A chip in `parent` (chip's, its own corner): `label`, `icon` before it (none: ""), in `ink` (the words' ink where
/// none), 30 high and 30 wide at least, 10 in either side where it has words, 10 round; on a tint of its ink, deeper
/// under the hand; drawn whole in bones. Named `said` (read out a button, its tip in `tips`) where said; `press` done as
/// it is pressed. While `disabled()`, at 35%, taking no press. `capsule`: round as a capsule (its half its height), not
/// 10: where it lies in the corner of a card concentric with it (a reader's chapter's chips, chip's `inner`). The node.
#callsite(autofill(loc))
pub fn chip_node(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  icon? : String = "",
  ink? : () -> Int64 = fn() { theme().p.text },
  said? : () -> String = fn() { "" },
  tips? : TipLayer,
  disabled? : () -> Bool = fn() { false },
  capsule? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(
    made_for=loc,
    parent,
    fn() {
      let s = said()
      if s == "" {
        label()
      } else {
        s
      }
    },
    fn(_) { press() },
    disabled~,
    fn(v, b) {
      let lit = fn() { !disabled() && (b.focus_shown() || b.hovered() || b.pressed()) }
      let hand = @motion.NodeWay::new(0.0)
      v.reacts(lit, fn(on) { hand.go_ms(v, if on { 1.0 } else { 0.0 }, dur_ms) })
      v
      .focus_ring_theme()
      .row(Is(true))
      .height(Is(Some(30.0)))
      .min_width(Is(Some(30.0)))
      .padding(By(fn() { if label() == "" { (0.0, 0.0, 0.0, 0.0) } else { (10.0, 0.0, 10.0, 0.0) } }))
      .gap(Is(2.0))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .ground(By(fn() { alpha(ink(), 0.07 + 0.05 * hand.shown(v)) }))
      .alpha(By(fn() { if disabled() { chip_off } else { 1.0 } }))
      .bone_whole(Is(true))
      |> ignore
      v.radius(Is(if capsule { 15.0 } else { 10.0 })) |> ignore
      if icon != "" {
        icon_node(v, icon, 16.0, By(ink)) |> ignore
      }
      v.show(fn() { label() != "" }, fn(w) {
        w
        .words(By(label))
        .words_look(By(fn() { { size: theme().t.meta, weight: 400, line: 18.0, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 } }))
        .ink(By(ink))
        |> ignore
      })
      match tips {
        Some(t) => tip_node(t, v, said) |> ignore
        None => ()
      }
    },
  )
}

///|
/// How a chip that cannot be pressed shows (chip's `disabled`: 35%).
let chip_off : Double = 0.35

///|
fn tone_colours(tone : PillTone) -> (Int64, Int64) {
  let p = theme().p
  match tone {
    Neutral => (p.neutral_bg, p.muted)
    Green => (p.green_bg, p.green_ink)
    Blue => (p.blue_bg, p.blue)
    Amber => (p.amber_bg, p.warn_ink)
    Red => (p.red_bg, p.red)
    Accented => (p.accent_bg, p.accent_text)
  }
}

///|
/// A status pill (pill's) as a node in `parent`: `words` in its tone's ink on its tone's ground, a tag (static_tag_in's:
/// round as a tag is, Radius::Base, so a status said never looks like what is pressed) pill_h high, pill_in in at either
/// end, growing with the system's size of words, cut short where its row has not the room; `icon` leading it (pill_icon,
/// its ink, 4 before its words; "" none); one piece in bones. The node.
#callsite(autofill(loc))
pub fn pill_node(
  parent : @view.View,
  words : () -> String,
  tone? : PillTone = Neutral,
  icon? : String = "",
  loc~ : SourceLoc,
) -> @view.View {
  let colours = fn() { tone_colours(tone) }
  parent.box(made_for=loc, fn(b) {
    let lead = if icon != "" {
      Some(fn(l : @view.View) { icon_node(l, icon, pill_icon, By(fn() { colours().1 })) |> ignore })
    } else {
      None
    }
    static_tag_in(b, pill_kind, words, fn() { colours().1 }, ground=fn() { colours().0 }, lead?, cuts=true)
  })
}

///|
/// A compact inline status badge in `parent`: `words` in its tone's ink on its tone's ground, the caption's size,
/// medium, a tag's height (static_tag_in's: round as a tag is, Radius::Base), growing with the system's size of words.
/// Said, not pressed. The node.
#callsite(autofill(loc))
pub fn badge_node(
  parent : @view.View,
  words : () -> String,
  tone? : PillTone = Neutral,
  loc~ : SourceLoc,
) -> @view.View {
  let colours = fn() { tone_colours(tone) }
  parent.box(made_for=loc, fn(b) {
    static_tag_in(b, badge_kind, words, fn() { colours().1 }, ground=fn() { colours().0 }, in_row=true)
  })
}

///|
/// A borderless full-capsule toggle chip in `parent`: soft neutral capsule while off, accented capsule while `active`;
/// optional leading `icon` and trailing `chevron` (flipping up/down with `active`). Used for compact switches and
/// filter toggles so interactive controls read cleanly as buttons at rest without stiff square borders.
#callsite(autofill(loc))
pub fn toggle_chip_node(
  parent : @view.View,
  label : () -> String,
  active : () -> Bool,
  press : () -> Unit,
  icon? : String = "",
  chevron? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.toggle(made_for=loc, parent, Button, label, active, fn(_) { press() }, fn(b, _) {
    capsule_chip_look(label, active, icon, chevron)(b)
  })
}

///|
/// A borderless full-capsule chip in `parent` that does `press` (a button, not a toggle), drawn as toggle_chip_node's
/// off: for an action standing among those toggles (a working agent's 停止 before 只看收发 and 详情), so it is the
/// same height and look as they are. While `disabled()`, at chip_off, taking no press.
#callsite(autofill(loc))
pub fn press_chip_node(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  icon? : String = "",
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, label, fn(_) { press() }, disabled~, fn(v, _) {
    capsule_chip_look(label, fn() { false }, icon, false)(v)
    v.alpha(By(fn() { if disabled() { chip_off } else { 1.0 } })) |> ignore
  })
}

///|
/// toggle_chip_node's and press_chip_node's look, given to the headless node each makes: its capsule, `icon` before
/// `label`, `chevron` after.
fn capsule_chip_look(
  label : () -> String,
  active : () -> Bool,
  icon : String,
  chevron : Bool,
) -> (@view.View) -> Unit {
  fn(b) {
    let hand = @motion.NodeWay::new(0.0)
    b.reacts(fn() { lit_node(b) }, fn(on) { hand.go_ms(b, if on { 1.0 } else { 0.0 }, dur_ms) })
    let ink = fn() {
      let p = theme().p
      if active() { p.accent_text } else { p.text }
    }
    let ground = fn() {
      let p = theme().p
      let base = if active() { p.accent_bg } else { p.neutral_bg }
      over(base, alpha(p.hover, hand.shown(b)))
    }
    b
    .row(Is(true))
    .min_height(Is(Some(toggle_chip_h)))
    .padding(Is((10.0, 2.0, 10.0, 2.0)))
    .gap(Is(4.0))
    .lines_up(Is(Some(Middle)))
    .radius(Is(1.0e6))
    .ground(By(ground))
    .shrink(Is(0.0))
    .bone_whole(Is(true))
    |> ignore
    if icon != "" {
      icon_node(b, icon, toggle_chip_icon, By(ink)) |> ignore
    }
    b.box(fn(w) {
      w
      .words(By(label))
      .words_look(By(fn() { @ui.style_words(toggle_chip_words) }))
      .ink(By(ink))
      |> ignore
    })
    |> ignore
    if chevron {
      b.pick(active, fn(c, open) {
        icon_node(c, if open { "chevron-up" } else { "chevron-down" }, toggle_chip_chevron, By(ink)) |> ignore
      })
    }
  }
}

///|
let toggle_chip_h : Double = 22.0

///|
let toggle_chip_icon : Double = 14.0

///|
let toggle_chip_chevron : Double = 12.0

///|
// kept across runs: a value (no field of it changes)
let toggle_chip_words : @ui.TextStyle = @ui.text_style(size=Meta, wrap=false)

///|
/// One of a few to choose among in `parent` (History.kt EffortChips' chip: how hard an agent thinks, how fast): a
/// capsule as wide as its words (16 and 9 in at the system's size of words), in the chips' ground while not chosen,
/// the ink's while `chosen`, its words then the ground's and semibold; lit under the hand. A toggle button named
/// `label`, pressed (`press`) as any.
#callsite(autofill(loc))
pub fn choice_chip_node(
  parent : @view.View,
  label : () -> String,
  chosen : () -> Bool,
  press : () -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.toggle(made_for=loc, parent, Button, label, chosen, fn(_) { press() }, fn(b, _) {
    let hand = @motion.NodeWay::new(0.0)
    b.reacts(fn() { lit_node(b) }, fn(on) { hand.go_ms(b, if on { 1.0 } else { 0.0 }, dur_ms) })
    let ground = fn() {
      let p = theme().p
      if chosen() {
        p.text
      } else {
        over(p.chip, alpha(p.hover, hand.shown(b)))
      }
    }
    b
    .row(Is(true))
    .padding(By(fn() { (node_sp(b, choice_chip_x), node_sp(b, choice_chip_y), node_sp(b, choice_chip_x), node_sp(b, choice_chip_y)) }))
    .lines_up(Is(Some(Middle)))
    .radius(Is(1.0e6))
    .ground(By(ground))
    .shrink(Is(0.0))
    .bone_whole(Is(true))
    |> ignore
    b.box(fn(w) {
      w
      .words(By(label))
      .words_look(By(fn() { @ui.style_words(if chosen() { choice_chip_on } else { choice_chip_words }) }))
      .ink(By(fn() {
        let p = theme().p
        if chosen() { p.bg } else { p.text }
      }))
      |> ignore
    })
    |> ignore
  })
}

///|
/// A choice chip's words from its ends (EffortChips' 16).
let choice_chip_x : Double = 16.0

///|
/// A choice chip's words from its top and foot (EffortChips' 9).
let choice_chip_y : Double = 9.0

///|
// kept across runs: a value (no field of it changes)
let choice_chip_words : @ui.TextStyle = @ui.text_style(size=Ui, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let choice_chip_on : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, wrap=false)
