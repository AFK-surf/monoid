// A bar's tool as a node of the window's tree (the way there 4: the library's parts given their
// made-once form beside their old one): viewer_tool's, drawn and answering as it does, each of what it shows bound to
// what it says as that changes (its icon, its words, whether it is on or can be pressed, its ink), read where it is
// drawn, not taken once as it is made; its corner as what holds it says (round, or linked to the window's).

///|
/// What a tool says of itself as it changes (tool_node): the icon it shows, its words (read out, its tip), whether it
/// is on (its chosen ground, read out pressed), whether it can be pressed at all (not: faint, taking no press, no
/// focus, nothing to be done to it, read out so).
#derive(Eq, Debug)
pub(all) struct ToolSaid {
  icon : String
  label : String
  on : Bool
  disabled : Bool
}

///|
/// How big a tool is (viewer_tool_box's S8), and how far its icon is in from its sides.
pub let tool_side : Double = @ui.Space::px(S8)

///|
let tool_icon_in : Double = (tool_side - viewer_tool_icon) / 2.0

///|
/// How faint a tool that cannot be pressed is drawn (viewer_tool_box's disabled opacity, O35).
let tool_faint : Double = 0.35

///|
/// A tool of a bar's in `parent`, as viewer_tool draws one (its 32 square, its icon `viewer_tool_icon` across in its
/// middle), saying what `said` says as that changes, in the ink `ink` says: its icon the ink's muted, its own where the
/// hand is on it (a mouse's pointer over it, a finger pressing it), pressed, or on; its ground the ink's hover where
/// the hand is on it, laid over its chosen one while on; faint and taking nothing where it cannot be pressed. Its
/// corner `corner` (round: Is(tool_side / 2.0); at the window's corner, linked to it: @ui.corner_of). Lit where the
/// keyboard's focus shows on it as where the hand is on it (its hover ground and ink). Pressed (a press, Enter or
/// Space with the focus, a screen reader's Activate), `press`, as one change. Its words its tip below it (tip_node), in
/// the window's tips' layer `tip`, as viewer_tool's. `lights` false: neither its ground nor its ink answers the hand (a
/// marking tool's, picture_button's: only on or not; the keyboard's focus still shown on it). `ripples`: a press
/// ripples over it and, where its ground is one of its own (@ui.stands_alone), sinks it (press_look: picture_button's).
/// `roving`: its hover ground the one its row's tools share (roving_hover_node: going from the tool the hand came from
/// to this one), drawn over its chosen ground, under its icon, in place of its own; none given, the one what holds it
/// lends (rove_lent), if any. `progress`: while what it does goes on and says how far (Some, 0 to 1, as viewer_download
/// draws a download coming), a ring in the ink's own in its icon's place saying how far (ring_shapes), faint and taking
/// no press as a tool that cannot be pressed, read out still as itself; None, the tool. The node.
#callsite(autofill(loc))
pub fn tool_node(
  parent : @view.View,
  said : () -> ToolSaid,
  ink : () -> ViewerInk,
  corner : @view.Live[Double],
  press : () -> Unit,
  tip? : TipLayer,
  lights? : Bool = true,
  ripples? : Bool = false,
  roving? : RovingHover,
  progress? : () -> Double? = fn() { None },
  loc~ : SourceLoc,
) -> @view.View {
  // (what it says while what it does goes on: unable to be pressed, as viewer_download's ring is)
  let said = fn() {
    let s = said()
    if progress() is Some(_) {
      { ..s, disabled: true }
    } else {
      s
    }
  }
  // (the hover ground its row shares: given it, else lent it by what holds it, a bar's row of tools: rove_lent)
  let roving = match roving {
    Some(r) => Some(r)
    None => parent.lent(rove_lent)
  }
  let rippled : Ref[PressLook?] = Ref(None)
  let hand : Ref[TipHand?] = Ref(None)
  let down : ((@view.Drag) -> Unit)? = if ripples {
    Some(fn(d) { if rippled.val is Some(r) { (r.down)(d) } })
  } else {
    None
  }
  let tapped : ((@view.Drag) -> Unit)? = if ripples {
    Some(fn(d) { if rippled.val is Some(r) { (r.tapped)(d) } })
  } else {
    None
  }
  @headless.toggle(
    made_for=loc,
    parent,
    Button,
    fn() { said().label },
    fn() { said().on },
    fn(_) { press() },
    disabled=fn() { said().disabled },
    hold=@headless.Hold::new(
      @ui.touch_slop(),
      @ui.long_press_ms,
      fn() { @ui.pointing() is Finger },
      on_hold=fn() { if hand.val is Some(h) { (h.hold)() } },
      on_lift=fn() { if hand.val is Some(h) { (h.lift)() } },
      on_cancel=fn() { if hand.val is Some(h) { (h.cancel)() } },
      down?=down,
      tapped?=tapped,
    ),
    fn(v, t) {
      // (where the hand is on it, as a box's hovered look has it: a mouse's pointer over it, a finger pressing it; and
      // where the keyboard's focus shows on it, drawn as the hand on it is: the user, 2026-10-31「焦点就按 hover 样式来」;
      // none where it does not light, `lights` false)
      let lit = fn() {
        t.focus_shown() ||
        (
          lights &&
          (match @ui.pointing() {
            Mouse => t.hovered()
            Finger => t.pressed()
          })
        )
      }
      // (its ground: the ink's hover where the hand is on it, over its chosen one while on)
      let ground = fn() {
        let s = said()
        let i = ink()
        let under = if s.on { i.chosen } else { 0L }
        // (the hover ground its row's tools share: drawn by that, over this)
        if roving is Some(_) {
          return under
        }
        if !s.disabled && lit() {
          if under != 0L {
            @ui.over(under, i.hover)
          } else {
            i.hover
          }
        } else {
          under
        }
      }
      v
      .width(Is(Some(tool_side)))
      .height(Is(Some(tool_side)))
      .padding(Is((tool_icon_in, tool_icon_in, tool_icon_in, tool_icon_in)))
      .radius(corner)
      .alpha(By(fn() { if said().disabled { tool_faint } else { 1.0 } }))
      .ground(By(ground))
      |> ignore
      // (what it shows inked as the hand is on it, pressed or on; else the ink's muted)
      let shown_ink = fn() {
        let k = ink()
        let s = said()
        if s.on || (!s.disabled && (lit() || (lights && t.pressed()))) {
          k.ink
        } else {
          k.muted
        }
      }
      // (the hover ground its row shares, under its icon)
      match roving {
        Some(r) =>
          roving_hover_node(r, v, fn() { !said().disabled && lit() }, fn() { ink().hover }, corner, fn() {
            @ui.pointing() is Finger
          })
          |> ignore
        None => ()
      }
      v.box(fn(i) {
        i
        .width(Is(Some(viewer_tool_icon)))
        .height(Is(Some(viewer_tool_icon)))
        // (its ring while what it does goes on, in the ink's own, drawn in its own colours: no tint then)
        .shapes(By(fn() {
          match progress() {
            Some(p) => ring_shapes(viewer_tool_icon, p, ink().ink)
            None => tool_shapes(said().icon)
          }
        }))
        // (called as an old view's icon is, by what finds it on screen)
        .drawn_as(By(fn() { "/icon/" + said().icon + "/" }))
        .tint(By(fn() { if progress() is Some(_) { 0L } else { shown_ink() } }))
        |> ignore
      })
      |> ignore
      // (a press's ripple over it and, where its ground is one of its own as it goes down (@ui.stands_alone, as the old
      // view's box's own_ground), its sink: picture_button's, @motion.ripple)
      rippled.val = if ripples {
        Some(press_look(v, corner, fn() { @ui.stands_alone(ground()) }))
      } else {
        None
      }
      hand.val = match tip {
        Some(tips) => Some(tip_node(tips, v, fn() { said().label }, side=Bottom))
        None => None
      }
    },
  )
}

///|
/// Icon `name` as a node in `parent`, `size` across, drawn in `tint` as it changes (icon's: its shapes the same, in
/// the node's tint), called as an old view's icon is by what finds it on screen. `weighed`: drawn with its weight in
/// its middle where it stands alone in a round key (icon_weighed). The node.
#callsite(autofill(loc))
pub fn icon_node(
  parent : @view.View,
  name : String,
  size : Double,
  tint : @view.Live[Int64],
  name_now? : () -> String,
  weighed? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  // (the icon said as it changes where `name_now` says it: a key's copy turning to a check a moment)
  let name = match name_now {
    Some(f) => f
    None => fn() { name }
  }
  parent.box(made_for=loc, fn(i) {
    i
    .width(Is(Some(size)))
    .height(Is(Some(size)))
    .shapes(By(fn() {
      match icon_numbers(name()) {
        Some(d) => icon_shapes(if weighed { icon_weighed(name(), d) } else { d }, size / 24.0, 0x000000FFL)
        None => []
      }
    }))
    .drawn_as(By(fn() { "/icon/" + name() + "/" }))
    .tint(tint)
    |> ignore
  })
}

///|
/// Icon `name`'s shapes as a tool draws it (viewer_tool_icon across), in no colour of their own (the node's tint).
fn tool_shapes(name : String) -> Array[@ui.Shape] {
  match icon_numbers(name) {
    Some(d) => icon_shapes(d, viewer_tool_icon / 24.0, 0x000000FFL)
    None => []
  }
}
///|
/// 复制 as a tool of a bar in `parent` (a file tab's tools' row, the whole window's viewer's bar): `copy` done at its
/// press, true where it copied, a check said in its place copied_ms after the press, its end its own, another press
/// another end (let go with the node). The node.
#callsite(autofill(loc))
pub fn copy_tool_node(
  parent : @view.View,
  ink : () -> ViewerInk,
  corner : @view.Live[Double],
  copy : () -> Bool,
  tip? : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  let copied : @signals.Signal[Bool] = @signals.signal(false)
  let copied_end : Ref[() -> Unit] = Ref(fn() {  })
  let n = tool_node(
    parent,
    fn() {
      if copied.get() {
        { icon: "check", label: t("common.copied"), on: false, disabled: false }
      } else {
        { icon: "copy", label: t("common.copy"), on: false, disabled: false }
      }
    },
    ink,
    corner,
    fn() {
      if copy() {
        (copied_end.val)()
        copied.set(true)
        copied_end.val = parent.at_moment(parent.cause_at() + copied_ms, later=true, fn() { copied.set(false) })
      }
    },
    tip?,
    loc~,
  )
  n.owns(fn() { (copied_end.val)() }) |> ignore
  n
}
