// A number in its circle (步骤圆标), as a node of the window's tree, made once: a guide's step (24 round on the neutral
// ground, its number muted) or a mark's pin (24 round, the accent's disc in a ring of the words on it, raised, the
// number on it bold), the number drawn by its points as the circle is (mark_words_node: never grown by the system's
// size of words out of a circle of a size said). Beside a block of words it stands on that block's first line
// (`first_line`: first_line_node's), never centred on the block's height. Pressed (step_circle_button_node), mbui's
// headless button: what it is to the hand, the keyboard and a screen reader that component's, here only its look.

///|
/// How a step's circle looks: `Step` (a guide's step: the neutral ground, its number muted, semibold); `Pin` (a mark's
/// numbered pin: the accent's disc 2 in from its edge, a ring of the words on the accent round it, raised, its number
/// bold on the accent).
#derive(Eq, Debug)
pub(all) enum StepLook {
  Step
  Pin
}

///|
/// A circle in `parent` holding `n()` (its number, as it is now), as `look` says. Where `first_line` is given, it stands
/// in a box as tall as a line of words of that size (`leading` where it says one), across that line's middle: on the
/// first line of the words beside it. The circle's node.
#callsite(autofill(loc))
pub fn step_circle_node(
  parent : @view.View,
  n : () -> String,
  look? : StepLook = Step,
  first_line? : @ui.TextSize,
  leading? : @ui.Leading,
  loc~ : SourceLoc,
) -> @view.View {
  let made : Ref[@view.View?] = Ref(None)
  let circle = fn(at : @view.View) {
    at.box(made_for=loc, fn(c) {
      made.val = Some(c)
      step_circle_look(c, n, look, loc~)
    })
    |> ignore
  }
  match first_line {
    Some(size) => first_line_node(loc~, parent, size, leading?, circle) |> ignore
    None => circle(parent)
  }
  made.val.unwrap()
}

///|
/// step_circle_node's circle that is pressed (a mark's pin opening its note): mbui's headless button named `label`,
/// `press` done as it is pressed (given its node); the keyboard's focus shown by the theme's ring round it. Where it
/// stands (over what, how far in) is its caller's, said of the node given back. The node.
#callsite(autofill(loc))
pub fn step_circle_button_node(
  parent : @view.View,
  n : () -> String,
  label : () -> String,
  press : (@view.View) -> Unit,
  look? : StepLook = Pin,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, label, press, fn(c, _) {
    focus_ring_node(c)
    step_circle_look(c, n, look, loc~)
  })
}

///|
/// What a step's circle `c` is drawn as (step_circle_node's), its number `n()` as `look` has it.
fn step_circle_look(c : @view.View, n : () -> String, look : StepLook, loc~ : SourceLoc) -> Unit {
  match look {
    Step => {
      style_node(c, fn() { step_circle })
      mark_words_node(c, n, fn() { step_circle_words }) |> ignore
    }
    Pin => {
      style_node(c, fn() { step_pin })
      c.shadow(Is((pin_raised.sigma, pin_raised.dy, pin_raised.color))) |> ignore
      c.box(made_for=loc, fn(i) {
        style_node(i, fn() { step_pin_in })
        mark_words_node(i, n, fn() { step_pin_words }) |> ignore
      })
      |> ignore
    }
  }
}

///|
/// A guide's step's circle (tokenGuide's li number): 24 round on the neutral ground, its number across its middle.
// kept across runs: a value (no field of it changes)
let step_circle : @ui.Style = @ui.css("w=S6 h=S6 radius=Full bg=Neutral align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let step_circle_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, color=Muted, wrap=false)

///|
/// A mark's pin (Preview.kt's pin): 24 round, a ring of the words on the accent 2 wide round its disc.
// kept across runs: a value (no field of it changes)
let step_pin : @ui.Style = @ui.css("w=S6 h=S6 radius=Full bg=OnAccent p=S0_5")

///|
/// Its disc: the accent, its number across its middle.
// kept across runs: a value (no field of it changes)
let step_pin_in : @ui.Style = @ui.css("w=Full h=Full radius=Full bg=Accent align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let step_pin_words : @ui.TextStyle = @ui.text_style(size=mark_pin_size, weight=Bold, color=OnAccent, wrap=false)
