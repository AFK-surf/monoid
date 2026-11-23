// An accordion (手风琴) as nodes of the window's tree, made once: its sections in one bordered card, a hairline between
// each and the next and none before the first or after the last (its sections are fixed as it is made, none hidden
// after), each a header (its title, a chevron at its end on the title's first line, turned up while it is open) over
// its panel, which opens and closes under it as what comes into a column and goes from it does (View::show). What it
// is to the hand, the keyboard and a screen reader is mbui's accordion (@headless.accordion: each header a disclosure
// pressed by the pointer, Enter or Space, ↓ ↑ Home End along the headers, a disabled one passed by; each panel a
// region); here its look.

///|
/// A section of an accordion_node (accordion_section): its key, its title, what its panel holds (made while it is
/// open), and whether its header alone takes no press.
pub struct AccordionSection[K] {
  priv key : K
  priv title : () -> String
  priv content : (@view.View) -> Unit
  priv disabled : () -> Bool
}

///|
/// A section of `key` called `title`, its panel made by `content` while it is open; `disabled` while its header takes
/// no press and no focus.
pub fn[K] accordion_section(
  key : K,
  title : () -> String,
  content : (@view.View) -> Unit,
  disabled? : () -> Bool = fn() { false },
) -> AccordionSection[K] {
  { key, title, content, disabled }
}

///|
/// The sections of `sections` in `parent`, one under the other in a bordered card as wide as where it is: each open as
/// `is_open` says of its key, `toggle` told the key of one a press on its header turns; `kind` one open at a time (the
/// caller closing the one open before) or each its own; `disabled` while none of it takes a press. A header: its title
/// (13, 500) and a chevron at its end on the title's first line (never across the middle of its lines), muted, the
/// title's ink under the hand, turned up over dur_ms while its section is open; faded and taking no press while
/// disabled. A panel: what its section holds, under its header, in from the card's sides as its title is. The node.
#callsite(autofill(loc))
pub fn[K] accordion_node(
  parent : @view.View,
  sections : Array[AccordionSection[K]],
  is_open : (K) -> Bool,
  toggle : (K) -> Unit,
  kind? : @headless.AccordionKind = Single(collapsible=true),
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  @headless.accordion(made_for=loc, parent, is_open, toggle, kind~, disabled~, fn(card, a) {
    style_node(card, fn() { accordion_card })
    for i, s in sections {
      // (a hairline between this one and the one before: never before the first, never after the last)
      if i > 0 {
        card.box(fn(rule) { style_node(rule, fn() { accordion_rule }) }) |> ignore
      }
      let key = s.key
      let open = fn() { a.is_open(key) }
      a.trigger(card, key, s.title, disabled=s.disabled, made_for=loc, fn(h, d) {
        accordion_head(h, d, s.title, open)
      })
      |> ignore
      card.show(open, fn(p) {
        a.panel(p, key, s.title, made_for=loc, fn(body) {
          style_node(body, fn() { accordion_panel })
          (s.content)(body)
        })
        |> ignore
      })
    }
  })
}

///|
/// A header's look on its disclosure's node `h`: its title and its chevron on the title's first line.
fn accordion_head(h : @view.View, d : @headless.Disclosure, title : () -> String, open : () -> Bool) -> Unit {
  style_node(h, fn() { accordion_head_row })
  h.focus_ring_theme().alpha(By(fn() { if d.disabled() { accordion_off_alpha } else { 1.0 } })) |> ignore
  let lit = fn() { !d.disabled() && (d.hovered() || d.pressed()) }
  words_node(h, title, fn() { accordion_title }).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
  // (its chevron at its end on its title's first line, turned up as its section opens and back as it closes, each
  // from its press: a control answering the hand)
  let turned = @motion.NodeWay::new(if @signals.untracked(open) { 1.0 } else { 0.0 })
  h.reacts(at_start=false, open, fn(o) { turned.go_ms(h, if o { 1.0 } else { 0.0 }, dur_ms) })
  first_line_node(h, Ui, leading=L6, fn(m) {
    icon_node(m, "chevron-down", accordion_chevron, By(fn() { if lit() { theme().p.text } else { theme().p.muted } }))
    .turn(By(fn() { turned.shown(h) * accordion_pi }))
    |> ignore
  })
  |> ignore
}

///|
let accordion_pi : Double = 3.141592653589793

///|
/// The chevron's size.
let accordion_chevron : Double = 16.0

///|
/// How far a disabled header is seen.
let accordion_off_alpha : Double = 0.55

///|
/// The card its sections are in: the surface, a hairline of the line round it (control_edge), a row's corner.
// kept across runs: a value (no field of it changes)
let accordion_card : @ui.Style = @ui.css("w=Full bg=Surface border=B0_5 border_color=Line").then(
  @ui.style(radius=row_radius),
)

///|
/// The hairline between one section and the next, across the card.
// kept across runs: a value (no field of it changes)
let accordion_rule : @ui.Style = @ui.css("w=Full h=SPx bg=Line")

///|
/// A header: a row, 14 in from the card's sides, 12 over and under, its title and chevron 12 apart, lined up at their
/// tops (the chevron on the title's first line).
// kept across runs: a value (no field of it changes)
let accordion_head_row : @ui.Style = @ui.css("row w=Full px=S3_5 py=S3 gap=S3 align=AStart")

///|
/// A header's title.
// kept across runs: a value (no field of it changes)
let accordion_title : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Medium, color=Fg)

///|
/// A panel: in from the card's sides as its header's title is, under it.
// kept across runs: a value (no field of it changes)
let accordion_panel : @ui.Style = @ui.css("w=Full px=S3_5 pb=S3_5 gap=S2")
