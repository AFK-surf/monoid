// A main action as wide as where it is (the settings' wide_button, Security.kt WideButton), as a node of the window's
// tree: a capsule 46 high, its words in its middle 20 from its ends, a spinner before them while what it does is under
// way; rippled as it is pressed, sinking under the finger.

///|
/// A main action as wide as where it is in `parent` (the settings' wide_button, as a node): 46 high, a capsule; primary
/// in the ink (red when `danger`, faded so while not `enabled`; the line's colour, a primary not enabled), else the ink
/// at 8%; its words `label` in the page's ground on a primary, else in the ink, 15 semibold on one line; a spinner
/// before them, in their ink, while `busy`. Pressed (`press`) only while `enabled` and not `busy`, rippled then, its
/// ground sinking under the finger (ripple_hold: handed by the headless button), the hover's ink over its ground under
/// the pointer or the keyboard's focus. Read out a button named `label`. Each as it changes.
#callsite(autofill(loc))
pub fn wide_button_node(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  primary : Bool,
  busy? : () -> Bool = fn() { false },
  enabled? : () -> Bool = fn() { true },
  danger? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  let live = fn() { enabled() && !busy() }
  let rippled : Ref[PressLook?] = Ref(None)
  @headless.button(
    made_for=loc,
    parent,
    label,
    fn(_) { press() },
    disabled=fn() { !live() },
    hold=ripple_hold(rippled, live),
    fn(v, _) {
      v.focus_ring_theme() |> ignore
      let ground = fn() {
        let t = theme()
        if !primary {
          alpha(t.p.text, 0.08)
        } else if danger {
          if enabled() {
            t.p.red
          } else {
            alpha(t.p.red, 0.4)
          }
        } else if !enabled() {
          t.p.line
        } else {
          t.p.text
        }
      }
      let ink = fn() {
        if primary && danger {
          0xFFFFFFFFL
        } else if primary {
          theme().p.bg
        } else {
          theme().p.text
        }
      }
      style_node(v, fn() { wide_button_node_box })
      v
      .height(Is(Some(wide_button_node_h)))
      .ground(By(ground))
      |> ignore
      // (one in no other's place, along a row: at once, as the old one's spinner came)
      v.show(busy, at_once=true, fn(s) {
        spinner_node(s, size=14.0, ring=fn() { alpha(ink(), 0.3) }, arc=ink) |> ignore
      })
      v.box(fn(w) {
        w
        .words(By(label))
        .words_look(By(fn() { @ui.style_words(wide_button_node_words) }))
        .ink(By(ink))
        |> ignore
        if @ui.style_cut(wide_button_node_words) {
          w.cuts(Is(true)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true)) |> ignore
        }
      })
      |> ignore
      // (lit while it may be pressed and the hand or the keyboard's focus is on it: a primary's ink a step towards the
      // page (way_in_button_node's solid one, Over(Fg, A(Bg, O15))), else the hover's ink over its quiet ground)
      hover_ground_node(v, on=live, color=fn() {
        if primary {
          alpha(theme().p.bg, 0.15)
        } else {
          @ui.tree_theme().color(Hover)
        }
      })
      // (its ripple and sink while it may be pressed: Security.kt WideButton's clickable over its capsule)
      rippled.val = Some(press_look(loc~, v, Is(wide_button_node_h / 2.0), fn() { true }))
    },
  )
}

///|
/// A wide button's height (the settings' wide_button_h).
let wide_button_node_h : Double = 46.0

///|
/// Its capsule: as wide as where it is, its words in its middle, 20 from its ends (the settings' wide_button_box).
// kept across runs: a value (no field of it changes)
let wide_button_node_box : @ui.Style = @ui.css("row w=Full px=S5 radius=Full gap=S2 align=ACenter justify=JCenter")

///|
/// Its words: the body's, semibold, on one line (Security.kt:127, 15sp).
// kept across runs: a value (no field of it changes)
let wide_button_node_words : @ui.TextStyle = body.then(strong).then(one_line)
