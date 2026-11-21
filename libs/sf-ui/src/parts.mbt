// still.fail's parts (web/ui parts.tsx, styles/controls.css.ts, page.css.ts,
// waiting.tsx), drawn with mbui: buttons, icon buttons, chips, a segmented
// choice, small panels and their rows, page heads and cards, and the three
// ways of waiting.


///|
/// For parts whose own parameter is called `icon`.
fn draw_icon(c : @ui.Ctx, name : String, size : Double, color : Int64, by_ink? : Bool = false) -> Unit {
  icon(c, name, size~, color~, by_ink~) |> ignore
}

///|
/// What a button is (controls.css.ts): `Plain` lined, on the canvas;
/// `Primary` the one thing to do, solid; `Ghost` words alone, a ground
/// under the pointer or while busy; `Danger` lined, its words red; `DangerSolid` solid red.
#derive(Eq)
pub(all) enum Tone {
  Plain
  Primary
  Ghost
  Danger
  DangerSolid
  /// a ghost's in the red (controls.css.ts btnGhost with btnDanger: 删除 beside a dialog's other buttons)
  GhostDanger
}

///|
/// A button (Button): a 36 pill on the wide screen, the phone's 38 one on a
/// narrow, as tall as a bar's tools among them (viewer_bar's: 32); an icon before its words if given, a spinner in its
/// place while `busy`; `reach`, where it stands in a card's foot corners: how its ground reaches past the card's words
/// (foot_across); `hint`, what pressing it does in more words, over it while it is pointed at (a Button in a Tip);
/// `on_press`, what pressing it does, as it is let go (press_does).
pub fn button(
  c : @ui.Ctx,
  label : String,
  key? : String = "",
  tone? : Tone = Plain,
  icon? : String = "",
  busy? : Bool = false,
  disabled? : Bool = false,
  w? : @ui.Size = Auto,
  reach? : @ui.Style,
  hint? : String = "",
  on_press? : () -> Unit,
) -> Unit {
  button_part(c, label, key~, tone~, icon~, busy~, disabled~, w~, reach?, hint~, on_press?) |> ignore
}

///|
/// What pressing `id` does (`on_press`), where it takes presses now (`live`): done as the press is let go on it (a tap,
/// a click, Enter or Space, Activate), outside any build, at its moment (Ctx::on_press), not read by the build after.
fn press_does(c : @ui.Ctx, id : Int, live : Bool, on_press : (() -> Unit)?) -> Unit {
  match on_press {
    Some(f) if live => c.on_press(id, f)
    _ => ()
  }
}

///|
// The same button can anchor a choice's menu. Keep its node for focus and its expanded state for accessibility.
fn button_part(
  c : @ui.Ctx,
  label : String,
  key? : String = "",
  tone? : Tone = Plain,
  icon? : String = "",
  busy? : Bool = false,
  disabled? : Bool = false,
  w? : @ui.Size = Auto,
  reach? : @ui.Style,
  hint? : String = "",
  end_icon? : String = "",
  lead? : (Int64) -> Unit,
  ink_override? : Int64,
  active? : Bool = false,
  expanded? : Bool,
  on_press? : () -> Unit,
) -> Int {
  let t = theme()
  let p = t.p
  let id = c.id(if key == "" { "sf-btn/" + label } else { key })
  let live = !disabled && !busy
  press_does(c, id, live, on_press)
  // Quiet actions keep their usual look at rest, and show their own ground while doing what was pressed.
  let quiet_busy = busy && (tone == Ghost || tone == GhostDanger)
  // (its ground eased as it is painted: told as it is built, read where it is drawn, Ctx::bg_by)
  let h = @motion.told(
    c,
    "sf-btn-h/\{id}",
    if quiet_busy || (live && (c.lit(id) || c.pressed(id) || active)) { 1.0 } else { 0.0 },
    spec=@motion.tween(dur_ms, ease=Out),
  )
  // (turning and greyed as a control answers: over dur_ms, never at once. With an icon, the spinner in its place, the
  // icon fading out under it as it fades in, nothing moved; with none, the spinner coming in before its words, which
  // stay: they are what it does, said on as it does it. At work is not greyed: it is the button pressed, at full
  // strength, its spinner what to look at (2026-10-31 the user: 从不带 loading 到带 loading……感觉有点不对, 能不能不换掉字;
  // it faded to 0.7 as the web's aria-busy does, its icon swapped at once, its words faded out under the spinner).)
  // (told as it is built, read where it is painted: the spinner built while it is busy or on its way back, up to
  // its declared end)
  let turning = @motion.told(c, "sf-btn-busy/\{id}", if busy { 1.0 } else { 0.0 }, spec=@motion.tween(dur_ms, ease=Out))
  let spun = busy || !turning.over(c)
  // (faded as it is drawn)
  let seen = @motion.told(c, "sf-btn-seen/\{id}", if disabled { 0.45 } else { 1.0 }, spec=@motion.tween(dur_ms, ease=Out))
  // its ground `h` of the way to the one under the hand (no outline: where a tone has a line, it is its ground), and
  // its words' ink
  let (ground_at, tone_ink) = if on_night.val {
    // (on a stage: the night under it whatever the theme)
    match tone {
      Primary | DangerSolid => (fn(h : Double) -> Int64 { mix(0xFFFFFFFFL, h, share_ink) }, share_ground)
      _ => (fn(h) { mix(stage_plain_lit, h, stage_plain) }, share_ink)
    }
  } else {
    // the phone's: the ink with the paper's words, the chip's ground, no outline; pointed at or pressed, a
    // solid ground a step towards the page and a quiet one the hover's step darker (mbui ui/hand_moves.mbt)
    match tone {
      Primary => (fn(h : Double) -> Int64 { mix(p.primary_hover, h, p.primary) }, p.bg)
      // (white on the light theme's deep red, the page's ink on the dark one's light red: white was 2.4 to 1 there)
      DangerSolid => (fn(h) { mix(mix(p.red, 0.85, p.canvas), h, p.red) }, if t.dark { p.bg } else { 0xFFFFFFFFL })
      Danger => (fn(h) { over(p.chip, alpha(p.hover, h)) }, p.red)
      Ghost => (fn(h) { alpha(p.hover, h) }, p.text)
      GhostDanger => (fn(h) { alpha(p.hover, h) }, p.red)
      Plain => (fn(h) { over(p.chip, alpha(p.hover, h)) }, p.text)
    }
  }
  let ink = ink_override.unwrap_or(tone_ink)
  let height = button_height()
  let solid = tone == Primary || tone == DangerSolid
  // (at a sheet's foot, in a thumb's reach: its share of the foot's width, the presenters')
  let w = if w is Auto && foot_fills.val { @ui.Fill(1.0) } else { w }
  // (one of words alone at a row's end: its words where the row's value would end, its ground reaching past them)
  let reach = match reach {
    None if (tone == Ghost || tone == GhostDanger) && at_row_end() => Some(outset_end(button_padx))
    r => r
  }
  // The corner sets the outside edge; padding puts the words on the card's line. In a fixed row only the first button
  // can stand at its start; in a wrapping row any of them can. A button with an icon keeps its balanced ends.
  let aligned = card_foot_first.val || card_foot_words_now.val
  card_foot_first.val = false
  let padx = if aligned && icon == "" && lead is None && w is Auto && reach is None { card_foot_words_in(height) } else { button_padx }
  // (its words' node, as built: how they move with it)
  let mut words_at = -1
  let b = c.box(
    style=reach.unwrap_or(@ui.style()),
    dir=Row,
    w~,
    keep=foot_fills.val && w is Fill(_),
    h=Px(height),
    padx~,
    gap=if t.touch { 8.0 } else { 6.0 },
    align=ACenter,
    justify=JCenter,
    bg=ground_at(h.target()),
    radius=height / 2.0,
    id=if live { id } else { 0 },
    fn() {
      let turn = fn() {
        spinner(
          c,
          size=button_icon,
          ring=if solid { alpha(ink, 0.3) } else { p.line_strong },
          arc=if solid { ink } else { p.accent },
        )
        |> ignore
      }
      let gap = if t.touch { 8.0 } else { 6.0 }
      if icon != "" {
        c.box(fn() {
          // (by its ink: as far in from the end as the words are from the other, the grid's room round its strokes
          // taking none, so the two ends look alike)
          let drawn = c.box(fn() { draw_icon(c, icon, button_icon, ink, by_ink=true) })
          // (the spinner over it, in its place and its size: the icon's room kept, nothing beside it moved)
          if spun {
            c.look_by(drawn, fn() { @ui.look(alpha=1.0 - turning.get(c)) })
            c.layer(fn() {
              let s = c.box(style=button_turning, turn)
              c.look_by(s, fn() { @ui.look(alpha=turning.get(c)) })
            })
            |> ignore
          }
        })
        |> ignore
      }
      match lead {
        Some(f) => f(ink)
        None => ()
      }
      let words_in = fn() {
        let words = c.text(
          label,
          size=t.t.ui,
          weight=if t.touch { 600 } else { 500 },
          color=ink,
          wrap=false,
          line=t.t.ui_line,
        )
        words_at = words
      }
      if icon == "" {
        // (the spinner's room opening before its words, the button wider by it as its ends keep their room, on the
        // curve a thing reshaped is moved by, all beside it moved along; the spinner growing from its start as the room
        // opens: never out of the ground, never over the words. Kept as wide, its ends came to 4, 2026-10-31 the user:
        // 太贴边了.)
        let over = @motion.animate(c, "sf-btn-over/\{id}", if busy { 1.0 } else { 0.0 }, spec=button_reshape)
        let room = button_icon + gap
        c.box(style=button_spun, fn() {
          if busy || over > 0.0 {
            c.box(style=@ui.style(row=true, w=Fixed(room * over), h=Fixed(button_icon)), fn() {
              let s = c.box(style=button_spin, fn() { turn() })
              c.look(s, @ui.look(scale=over, ox=0.0))
              let grown = seen_at(over)
              c.look_by(s, fn() { @ui.look(alpha=turning.get(c) * grown) })
            })
            |> ignore
          }
          words_in()
        })
        |> ignore
      } else {
        words_in()
      }
      if end_icon != "" {
        draw_icon(c, end_icon, button_icon, ink, by_ink=true)
      }
    },
  )
  c.bg_by(b, fn() { ground_at(h.get(c)) })
  c.look_by(b, fn() { @ui.look(alpha=seen.get(c)) })
  // its words changed (复制图片 to 已复制): its ground goes from the width it had to the new one, its words with it, on
  // the curve a thing reshaped is moved by, not at once (the user, 2026-10-30: 按钮的变长应该也有过渡; their cause,
  // its words: sf/motion.mbt 3)
  if key != "" {
    @motion.reshape(c, b, "sf-btn/shape/" + key, by=label, spec=button_reshape)
    @motion.layout(c, words_at, "sf-btn/words/" + key, by=label, spec=button_reshape)
  }
  // (in a page's bones, one piece where it has a ground; one of words alone, its words)
  if tone != Ghost && tone != GhostDanger {
    c.bone_whole(b)
  }
  // (said a button whether it takes presses or not: one that cannot is said disabled, not left out of the tree, and its
  // faded words are asked no contrast)
  c.semantics(b, Button, id=if live { id } else { 0 }, label~, expanded?, disabled=!live)
  if live {
    tip(c, "sf-btn/" + key + label + "/tip", id, hint)
  }
  b
}

///|
/// How a button whose words changed goes to its new width (button): a Move as long as its width changes.
let button_reshape : @motion.Spec = @motion.moved()

///|
/// How far a button's words are in from its sides.
let button_padx : Double = 16.0

///|
/// Keep a button's leading icon or words on the line of the surrounding words, with its ground reaching past them.
pub fn button_start_reach() -> @ui.Style {
  outset_start(button_padx)
}

///|
/// How big a button's icon is.
let button_icon : Double = 16.0

///|
/// Where a button with no icon turns while busy: over its words, in the middle (button).
// kept across runs: a value (no field of it changes)
let button_turning : @ui.Style = @ui.css("w=Full h=Full align=ACenter justify=JCenter")

///|
/// A button's spinner and its words, with no icon (button): in a row, the spinner's room opening before the words.
let button_spun : @ui.Style = @ui.css("row align=ACenter")

///|
/// Where a button's spinner turns (button): an icon's square.
let button_spin : @ui.Style = @ui.style(w=Fixed(button_icon), h=Fixed(button_icon))

///|
/// Whether a button laid out now is at a sheet's foot (the presenters' sheet_body says so while it draws one): each
/// of its buttons as wide as the others, across the sheet (the phone's sheets' primary button, Button in mPad).
let foot_fills : Ref[Bool] = { val: false }

///|
/// Whether a button is drawn on the night whatever the theme (a stage's foot: stage_node), in its
/// colours.
// kept across runs: set only while a stage's foot is built, and put back
let on_night : Ref[Bool] = { val: false }

///|
/// A button's height: what can be pressed is one height (menu_row_min; the user, 2026-10-30: 「搞这么多标准干啥」), on every
/// screen with either native input (the user,
/// 2026-10-31: a finger's 44 「太大了」「我们现在发送按钮也没那么大」「按钮既然缩，那就跟大屏一致呗」「我们本就大屏小屏都支持
/// 触控」: drawn 44, one in a card's foot corners stood 4 from its edges); its press reaching the 44 every press has.
pub fn button_height() -> Double {
  menu_row_min
}

///|
/// An icon button's side (iconBtn's 32), with a finger too: what stands among a bar's icon buttons is as high.
pub let icon_button_side : Double = 32.0

///|
/// An icon button (page.css.ts iconBtn, parts.tsx IconButton): `size` square (32), its corner 12 (`corner`: the
/// ladder's step where it stands, a card's text inset in its corner the small block's 10; `round`: a circle, where it
/// stands in a pane's corner, concentric with it; `linked`: its corner where that comes from, a bar's buttons' at the
/// window's corner: @sf.bar_keys_link), the icon (16) quiet until pointed at (`lit`: so as what points at it is told
/// from outside, the host's: the window's maximize button the app draws, window_keys); `on` held down
/// (aria-pressed); named for a screen reader and said in its tip with its keys (`shortcut`, an action's).
/// `ink` and `quiet` for one over a ground of its own (the reader's paper).
pub fn icon_button(
  c : @ui.Ctx,
  icon : String,
  key? : String = "",
  size? : Double = icon_button_side,
  icon_size? : Double = 16.0,
  on? : Bool = false,
  lit? : Bool = false,
  round? : Bool = false,
  corner? : Double = r_field,
  linked? : @ui.CornerOf,
  ink? : Int64,
  quiet? : Int64,
  disabled? : Bool = false,
  label? : String = "",
  shortcut? : String = "",
  on_press? : () -> Unit,
) -> Unit {
  let t = theme()
  // (drawn its own size with a finger too: a finger reaches it from round it, mbui's press_reach)
  let ink = ink.unwrap_or(t.p.text)
  let quiet = quiet.unwrap_or(t.p.muted)
  let id = c.id(if key == "" { "sf-ib/" + icon } else { key })
  press_does(c, id, !disabled, on_press)
  // (its ground and its icon's ink eased as they are painted: told as it is built, read where it is drawn)
  let h = @motion.told(
    c,
    "sf-ib-h/\{id}",
    if !disabled && (lit || c.lit(id) || c.pressed(id)) { 1.0 } else { 0.0 },
    spec=@motion.tween(dur_ms, ease=Out),
  )
  // the page's hover, as a tint of the ink it sits with
  let ground_at = fn(h : Double) { if on { alpha(ink, 0.08) } else { alpha(ink, 0.065 * h) } }
  let corner : @ui.Radius = match linked {
    Some(link) => Linked(link)
    None => rounded(if round { size / 2.0 } else { corner })
  }
  let b = c.box(
    style=@ui.style(radius=corner),
    w=Px(size),
    h=Px(size),
    align=ACenter,
    justify=JCenter,
    bg=ground_at(h.target()),
    opacity=if disabled { 0.35 } else { 1.0 },
    id=if disabled { 0 } else { id },
    fn() {
      draw_icon(c, icon, icon_size, if on || h.target() > 0.5 { ink } else { quiet })
    },
  )
  c.bg_by(b, fn() { ground_at(h.get(c)) })
  // (its icon quiet, in the ink once its ground is half way to the hover's, as it is painted; a runtime's mark in its
  // maker's own colours)
  if !on && !icon.has_prefix("runtime:") {
    c.ink_by(b, fn() { if h.get(c) > 0.5 { ink } else { quiet } })
  }
  // named (IconButton's label): what a screen reader calls it, and its tip
  if label != "" {
    c.semantics(b, Button, id~, label~, disabled~)
    tip(c, "ib/" + key + icon, id, label, shortcut~)
  }
}

///|
/// How far an option's words stand in from its column's sides (segmentedOption: 0 12), and how little they may where
/// the room is short (option_widths).
let segmented_in : Double = 12.0

///|
let segmented_least : Double = 8.0

///|
/// How far its track's ground stands out round its options, and how far apart they are (segmented's --gap).
let segmented_pad : Double = 3.0

///|
let segmented_gap : Double = 2.0

///|
/// In a bar (`bar`): its track 2 round its options, as a bar's other tracks (Seg's).
let segmented_bar_pad : Double = @ui.Space::px(S0_5)

///|
/// How wide each of `n` options is for a segmented choice's track to be `room` across (its `item_w`): one that spans
/// the row it heads, as the field under it does (a chat's things').
pub fn segmented_item_w(room : Double, n : Int) -> Double {
  if n <= 0 {
    return 0.0
  }
  (room - 2.0 * segmented_pad - segmented_gap * (n - 1).to_double()) / n.to_double()
}

///|
let segmented_chevron : Double = 16.0

///|
/// An option's height on one line (segmentedOption: 30).
let segmented_h : Double = 30.0

///|
/// A narrow page's (Seg filling, as the web's narrow pages' mSeg): 34 high.
let segmented_narrow_h : Double = 34.0

///|
/// How high a segmented control stands where it is drawn now (a narrow page's 34, a wide page's track round
/// its options, 36).
pub fn segmented_height() -> Double {
  if look() is Narrow {
    segmented_narrow_h
  } else {
    segmented_h + 2.0 * segmented_pad
  }
}

// ---------------------------------------------------------------------------
// Small panels

///|
/// A small panel's ground (controls.css.ts popover): the canvas (the raised
/// grey in dark), a line round it, its shadow; padded panel_pad, its corner
/// the menu's. `min_w`: as wide as what it holds, at least that (a menu's,
/// controls.css.ts menuList); `max_w`: at most that.
fn small_panel(
  c : @ui.Ctx,
  w? : @ui.Size = Auto,
  h? : @ui.Size = Auto,
  min_w? : Double,
  max_w? : Double,
  body : () -> Unit,
) -> Int {
  let (blur, fall, shade) = float_shadow()
  let panel = c.box(
    w~,
    h~,
    min_w?,
    max_w?,
    pad=panel_pad,
    bg=panel_ground(),
    radius=r_menu,
    border=1.0,
    border_color=panel_edge(),
    shadow=blur,
    shadow_y=fall,
    shadow_color=shade,
    clip=true,
    body,
  )
  // (the panel: the surface of the look it comes in by, coming first, all on it after: Ctx::surface)
  c.surface(panel)
  panel
}

///|
/// Between a menu item's icon and its words (menuItem: 8), a panel row's (panelRow: 10); a panel row's icon (18) and
/// what is at its end (14).
let menu_row_gap : Double = 8.0

///|
let panel_row_gap : Double = 10.0

///|
let panel_icon : Double = 18.0

///|
pub let panel_end_icon : Double = 14.0

///|
/// A menu item's icon, out of a panel's column (16).
let menu_item_icon : Double = 16.0

///|
/// A panel row's icon's column's width (panel_row_icon's S5).
let panel_icon_col : Double = 20.0

///|
/// A panel row's icon's column (parts.css.ts panelRowIcon): 20 wide, the icon at its start (aligned with the panel's
/// title and group labels, as panel_row_face's is).
// kept across runs: a value (no field of it changes)
let panel_row_icon : @ui.Style = @ui.css("w=S5 align=AStart")

///|
/// How wide a panel's row's icon column is (panel_row_icon's), and its face's column: the face at its start, in the
/// row's middle (panel_row_by's `face`, as wide as it reaches on to where the icon's column ends).
let panel_row_icon_w : Double = @ui.Space::px(S5)

///|
// kept across runs: a value (no field of it changes)
let panel_row_face : @ui.Style = @ui.css("align=AStart justify=JCenter")

// ---------------------------------------------------------------------------
// Pages (styles/pages.css.ts)


///|
/// A page card of words (pages.css.ts card): card_pad in from every side, round by the ladder's card step; a solid
/// button in its foot corner stands there itself (foot_reach), its corner the card's whatever is in it; `ground` other
/// than the theme's card (over a picture: a player's).
pub fn card(c : @ui.Ctx, gap? : Double = 14.0, fill? : Bool = false, ground? : Int64, body : () -> Unit) -> Int {
  let t = theme()
  c.box(pad=card_pad, gap~, bg=ground.unwrap_or(t.p.card), radius=card_corner, w=if fill { card_across } else { Auto }, body)
}

///|
/// Round a sheet's grabber: 8 above and 4 under it, then 4 above and under it (Sheet.kt's two paddings, each a length
/// of its own: on Android's whole pixels 21 + 11 above the grabber and 11 + 11 under it, not one 12 and one 8).
// kept across runs: a value (no field of it changes)
let sheet_grab_outer : @ui.Style = @ui.css("w=Full pt=S2 pb=S1")

///|
// kept across runs: a value (no field of it changes)
let sheet_grab_inner : @ui.Style = @ui.css("w=Full py=S1 align=ACenter")

///|
/// How tall a sheet's grabber stands at its top, all round it (sheet_node's grabber: 8 and 4 over its 5, 4 and 4 under): where
/// what the sheet holds begins.
pub let sheet_grab_h : Double = 8.0 + 4.0 + 5.0 + 4.0 + 4.0

///|
/// How long the pointer rests on a control before its tip shows (the web's Tooltip.Provider delayDuration).
pub let tip_delay_ms : Double = 400.0

///|
/// A tip over control `id` (parts.tsx Tip): `label` said beside it once the pointer has rested on it a moment (on
/// `side`, under it by default), and with a `shortcut`, the keys that do the same after it, quieter (shortcuts.mbt).
/// The only way anything explains itself on hover; to a finger, which rests on nothing, as it holds what it names
/// (Android's tooltips: @kit.tooltip). With no label, none. `key` names it where it is asked. `repeats`: it says
/// words the control shows itself (a file's name on its card, a tab's), whole: said only while they show cut short
/// there (@ui.Ctx::shows_cut); shown whole, a tip saying them again says nothing.
fn tip(
  c : @ui.Ctx,
  key : String,
  id : Int,
  label : String,
  side? : @ui.Side = Bottom,
  shortcut? : String = "",
  shown? : Bool = false,
  repeats? : Bool = false,
) -> Unit {
  if label == "" || id == 0 || (repeats && !c.shows_cut(id)) {
    return
  }
  let keys = shortcut_keys(shortcut)
  @kit.tooltip(c, "tip/" + key, id, label, delay=tip_delay_ms, side~, shown~, look=fn(c, _, words) {
    tip_look(c, words, keys)
  })
  |> ignore
}

///|
/// A tip as the web draws it (parts.css.ts tooltip), as tip_node's tip_look_node draws one, said in the theme's roles:
/// small words on the primary ink, 5 by 10 in, 10 round, a small shadow; in the dark not that ink (the light grey, a
/// glare of a block) but the raised grey lifted a step toward the words, a faint line round it. Its keys, where it says
/// any, each a cap of its own after its words (key_caps), the tip then 4 over, under and after them (concentric with
/// them, 6 round), its words 10 from its start.
fn tip_look(c : @ui.Ctx, words : String, keys : String) -> Unit {
  let caps = key_caps(keys)
  // (the tip: the surface of the look it comes in by: Ctx::surface)
  let tip = c.box(style=if caps.is_empty() { tip_box } else { tip_key_box }, fn() {
    c.box(style=if caps.is_empty() { tip_line } else { tip_key_line }, fn() {
      c.box(style=if caps.is_empty() { tip_words_box } else { tip_key_words }, fn() {
        c.text(words, style=tip_words_style) |> ignore
      })
      |> ignore
      if !caps.is_empty() {
        c.box(style=tip_caps_row, fn() {
          for cap in caps {
            c.box(style=tip_cap_box, fn() { c.text(cap, style=tip_cap_words) |> ignore }) |> ignore
          }
        })
        |> ignore
      }
    })
    |> ignore
  })
  c.surface(tip)
}

///|
// kept across runs: a value (no field of it changes)
let tip_box : @ui.Style = @ui.style(
  px=S2_5,
  py=S1_25,
  bg=Primary,
  radius=rounded(small_corner),
  max_w=tip_max,
  shadow=Sm,
  dark=@ui.patch(bg=Over(Raised, A(Fg, O5)), border=B1, border_color=A(Fg, O10)),
)

///|
// kept across runs: a value (no field of it changes)
let tip_key_box : @ui.Style = tip_box.then(@ui.css("pl=S2_5 pr=S1 py=S1"))

///|
// kept across runs: a value (no field of it changes)
let tip_line : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let tip_key_line : @ui.Style = @ui.css("row gap=S2 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let tip_words_box : @ui.Style = @ui.css("")

///|
// kept across runs: a value (no field of it changes)
let tip_key_words : @ui.Style = @ui.css("py=SPx")

///|
// kept across runs: a value (no field of it changes)
let tip_words_style : @ui.TextStyle = @ui.text_style(size=Meta, color=OnPrimary, dark=@ui.text_patch(color=Fg))

///|
// kept across runs: a value (no field of it changes)
let tip_caps_row : @ui.Style = @ui.css("row gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let tip_cap_box : @ui.Style = @ui.css((
  #|row h=S5 min_w=S5 px=S1_25 radius=Md bg=Over(Primary,A(OnPrimary,O10)) align=ACenter justify=JCenter dark{bg=Over(Over(Raised,A(Fg,O5)),A(Fg,O10))}
))

///|
// kept across runs: a value (no field of it changes)
let tip_cap_words : @ui.TextStyle = @ui.text_style(
  size=Caption,
  weight=Medium,
  color=OnPrimary,
  wrap=false,
  dark=@ui.text_patch(color=Fg),
)

///|
/// A small panel's ground (glass.ts panel), what floats over a card (a menu, a popover, a hover card, ⌘K): the canvas
/// in light, the raised grey in the dark. Not lifted further: the chips, tracks and empty cells in it are a step off
/// it as they are (contrast_wbtest); what cuts it off a card in the dark is its line (panel_edge) and its shadow
/// (float_shadow).
pub fn panel_ground() -> Int64 {
  let t = theme()
  if t.dark {
    t.p.raised
  } else {
    t.p.canvas
  }
}

///|
/// The line round what floats (panel_ground's): the theme's line, light or dark (in the dark 12% of the ink, as much
/// more as more contrast is asked: contrasted). Seen twice as much it was a white frame round every menu; what cuts what
/// floats off a dark card is its lifted ground and its shadow.
pub fn panel_edge() -> Int64 {
  theme().p.line
}

///|
/// A menu's item (controls.css.ts menuItem), as mbui's menus draw it: as high as the screen's at least (Theme::rows
/// pick: 34, a finger's 44), 6 by 10 in, its words (13) after a column 14 wide (`lead`: the menu's items have one, so all their words are on one line) of its icon (muted)
/// or, one of a choice (parts.tsx ChooserItem), its check where it is the one chosen, `gap` from its words; the
/// pointer's or the keyboard's ground on it; one not to be chosen now (its entry disabled: never lit) in the subtle
/// ink (menuItem[data-disabled]). `note`: what it is, a line under its words (a pick's choice's: its icon, its name and
/// that, as a sheet's row has them).
fn menu_row(
  c : @ui.Ctx,
  s : @kit.MenuItemState,
  icon_name : String,
  lead : Bool,
  gap : Double,
  end : ((@ui.Ctx, @kit.MenuItemState) -> Unit)?,
  danger? : Bool = false,
  mark? : (@ui.Ctx, Double) -> Unit,
  note? : String = "",
  at_top? : Bool = false,
  at_foot? : Bool = false,
) -> Unit {
  let t = theme()
  let (choice, checked) = match s.entry.kind {
    Choice(on) | Check(on) => (true, on)
    _ => (false, false)
  }
  let off = s.entry.disabled
  let reach = menu_row_reach(t.rows.pick)
  let (over, under_by) = ends_reach(reach, at_top, at_foot)
  c.box(
    dir=Row,
    w=Fill(1.0),
    min_h=t.rows.pick,
    mx=-reach,
    mt=over,
    mb=under_by,
    padx=text_in + reach,
    pady=menu_row_over,
    gap~,
    align=ACenter,
    radius=small_panel_inner(r_menu),
    bg=if s.hot { t.p.hover } else { 0L },
    fn() {
      let leads = fn() {
        if lead {
          c.box(style=menu_check, fn() {
            if choice {
              if checked {
                icon(c, "check", size=14.0, color=t.p.text) |> ignore
              }
            } else if icon_name != "" {
              icon(c, icon_name, size=14.0, color=if danger { if off { t.p.subtle } else { t.p.red } } else { t.p.muted })
              |> ignore
            }
          })
          |> ignore
        }
        // its own mark (a station's, a maker's) after the check, before its words, as wide as the check's column
        match mark {
          Some(m) => c.box(style=menu_check, fn() { m(c, menu_check_w) }) |> ignore
          None => ()
        }
      }
      // (a danger's in red, its icon with it: menuItem[data-danger])
      let words = if off { menu_words_off } else if danger { menu_words_danger } else { menu_words }
      let first = fn() {
        c.text(s.entry.label, style=words) |> ignore
        // what stands at its end (a ＋): pushed there
        match end {
          Some(f) => {
            c.spacer()
            f(c, s)
          }
          None => ()
        }
      }
      if note == "" {
        leads()
        first()
      } else {
        // what it is under its words, what leads it by its first line
        let lead_w = (if lead { menu_check_w + gap } else { 0.0 }) + (if mark is Some(_) { menu_check_w + gap } else { 0.0 })
        lead_by_first_line(c, if lead_w > 0.0 { lead_w - gap } else { 0.0 }, gap, leads, first, fn() {
          c.text(note, style=menu_note) |> ignore
        })
      }
    },
  )
  |> ignore
}

///|
/// What an item is, under its words: the meta size, muted.
// kept across runs: a value (no field of it changes)
let menu_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted)

///|
/// A row's words with a line under them (what it is), what leads it (`lead`: its icon, its check, its mark, `lead_w`
/// wide, `gap` from its words) standing by its first line's middle, not the whole's, and what is under it as far in
/// as its first line's words (the user, 2026-10-27: 「图标不要上下居中，跟第一行居中」): every row of a menu, a pick and
/// a sheet so made. `first`: its first line (its words, what is at their end); `under`: the lines under it.
fn lead_by_first_line(
  c : @ui.Ctx,
  lead_w : Double,
  gap : Double,
  lead : () -> Unit,
  first : () -> Unit,
  under : () -> Unit,
) -> Unit {
  c.box(style=lead_lines, fn() {
    c.box(style=lead_first_line.then(@ui.style(gap=room(gap))), fn() {
      lead()
      first()
    })
    |> ignore
    c.box(style=@ui.style(pl=room(lead_in(lead_w, gap))), under) |> ignore
  })
  |> ignore
}

///|
/// How far in the lines under a row's first stand: past what leads it and the gap after it, where something does.
fn lead_in(lead_w : Double, gap : Double) -> Double {
  if lead_w > 0.0 {
    lead_w + gap
  } else {
    0.0
  }
}

///|
/// (lead_by_first_line: the lines as wide as the row leaves them; the first a row, its parts by its middle)
let lead_lines : @ui.Style = @ui.style(w=grow)

///|
// kept across runs: a value (no field of it changes)
let lead_first_line : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
/// Between an item's icon and its words (menuItem), its check's column and its words in a menu of choices alone
/// (chooserItem).
let menu_gap : Double = 8.0

///|
let chooser_gap : Double = 6.0

///|
/// The column before a menu item's words (controls.css.ts chooserCheck, a menuItem's svg): 14 wide, its icon or check in
/// its middle.
// kept across runs: a value (no field of it changes)
let menu_check : @ui.Style = @ui.css("w=S3_5 align=ACenter")

///|
/// How wide the column before a menu item's words is (menu_check's S3_5).
let menu_check_w : Double = 14.0

///|
/// A menu item's words: as long as they are (the menu as wide as its longest, controls.css.ts menuList).
// kept across runs: a value (no field of it changes)
let menu_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, leading=L5, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let menu_words_danger : @ui.TextStyle = @ui.text_style(size=Ui, color=Danger, leading=L5, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let menu_words_off : @ui.TextStyle = @ui.text_style(size=Ui, color=Subtle, leading=L5, wrap=false)

///|
/// A heading among a menu's items (controls.css.ts menuLabel): its words as far in as a row's (text_in) and as far
/// under what is over it as a row's are (menu_row_over: at the panel's top, where its first item's words would be), 4
/// over the items it heads; 12, muted.
// kept across runs: a value (no field of it changes)
let menu_heading : @ui.Style = @ui.css("w=Full px=S2_5 pt=S1_5 pb=S1")

///|
// kept across runs: a value (no field of it changes)
let menu_heading_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L4_75, wrap=false)

///|
/// A menu (parts.tsx Menu: mbui's dropdown menu, in the web's look): `entries` with their icons (by value), as wide as
/// its longest and `w` at least (controls.css.ts menuList 180; a menu of choices chooserMenu, 220), `offset` on `side`
/// of `trigger` (under it) lined up `along` it, or at `at`; what was chosen. The arrows, letters, Enter and Escape as a
/// menu's; a press outside closes it. `check_end`: its choices' checks are drawn at their rows' ends (`row_end`:
/// parts.tsx ChooserItem checkEnd), no column of them before their words. `show_exit` false yields at once to a panel
/// replacing it. `on_pick`: what choosing an entry does, given its value, as it is chosen (@kit.dropdown_menu's).
fn dropdown(
  c : @ui.Ctx,
  key : String,
  open : Bool,
  trigger : Int,
  entries : Array[@kit.Entry],
  icons : Map[String, String],
  w : Double,
  submenu? : Bool = false,
  side? : @ui.Side = Bottom,
  along? : @ui.Along = Start,
  offset? : Double = 6.0,
  at? : (Double, Double, Double, Double),
  row_end? : (@ui.Ctx, @kit.MenuItemState) -> Unit,
  danger? : Array[String] = [],
  marks? : Map[String, (@ui.Ctx, Double) -> Unit] = {},
  notes? : Map[String, String] = {},
  check_end? : Bool = false,
  show_exit? : Bool = true,
  on_pick? : (String) -> Unit,
) -> @kit.Menu {
  // (a column before every item's words where one has an icon or is one of a choice, its check there, so all their
  // words are on one line; a menu of choices alone, each chosen or not, its check 6 from its words)
  let choice = fn(e : @kit.Entry) { e.kind is Choice(_) || e.kind is Check(_) }
  let iconed = entries.iter().any(fn(e) { !choice(e) && icons.get(e.value).unwrap_or("") != "" })
  let lead = iconed || (!check_end && entries.iter().any(choice))
  let gap = if lead && !iconed { chooser_gap } else { menu_gap }
  @kit.dropdown_menu(
    c,
    key,
    open,
    trigger,
    entries,
    on_pick?,
    submenu~,
    side~,
    along~,
    offset~,
    min_w=w,
    at?,
    show_exit~,
    look=fn(c, w, body) { small_panel(c, min_w=w, body) |> ignore },
    item_look=fn(c, s) {
      menu_row(
        c,
        s,
        icons.get(s.entry.value).unwrap_or(""),
        lead,
        gap,
        row_end,
        danger=danger.contains(s.entry.value),
        mark?=marks.get(s.entry.value),
        note=notes.get(s.entry.value).unwrap_or(""),
        at_top=entries.length() > 0 && entries[0].value == s.entry.value,
        at_foot=entries.length() > 0 && entries[entries.length() - 1].value == s.entry.value,
      )
    },
    // (a heading's words on its items' words' line: past the column before them, where there is one)
    heading_look=fn(c, label) {
      let past = (if lead { menu_check_w + gap } else { 0.0 }) + (if marks.is_empty() { 0.0 } else { menu_check_w + gap })
      c.box(style=menu_heading.then(@ui.style(pl=room(text_in + past))), fn() { c.text(label, style=menu_heading_words) |> ignore })
      |> ignore
    },
    rule_look=menu_rule,
  )
}

///|
/// A line between parts of a small panel (controls.css.ts menuSep): the words' ink faintly (in dark the panel is
/// lighter than the page: its line a groove), 1 high, 6 over and under it, as wide as its rows' grounds (at the
/// panel's padding), so a row pointed at beside it ends where it does.
/// Rules are for menus alone; elsewhere room, a heading or a ground groups things (the user, 2026-10-25: 「除了菜单感
/// 觉都应该去掉」).
fn menu_rule(c : @ui.Ctx) -> Unit {
  c.box(style=menu_rule_at, fn() { c.box(style=rule_line.then(@ui.style(bg=Data(rule_ink(c)))), fn() {  }) |> ignore })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let menu_rule_at : @ui.Style = @ui.css("w=Full py=S1_5")

///|
/// What a menu holds (parts.tsx MenuItem): its words, its icon, in red (`danger`: what cannot be undone), not to be
/// chosen now (`disabled`), one of a choice (`chosen`: whether it is the one chosen; a menu with one is a menu of
/// choices, each checked or not in a column before its words: parts.tsx ChooserItem); what choosing it does.
pub(all) struct MenuItem {
  label : String
  icon : String
  danger : Bool
  disabled : Bool
  chosen : Bool?
  /// An independent on/off item. Its check is read alongside the single-choice items.
  checkbox : Bool
  heading : Bool
  /// what it does needs more asked first (a menu, a dialog, a page a step further in): a chevron at its end, in place
  /// of words that end in … (the user, 2026-11-17: 「改成用图标来表达，然后文字说全」)
  further : Bool
  select : () -> Unit
}

///|
pub fn menu_item_of(
  label : String,
  select : () -> Unit,
  icon? : String = "",
  danger? : Bool = false,
  disabled? : Bool = false,
  chosen? : Bool,
  checked? : Bool,
  heading? : Bool = false,
  further? : Bool = false,
) -> MenuItem {
  {
    label, icon, danger, disabled, heading, further, select,
    chosen: if checked is Some(_) { checked } else { chosen },
    checkbox: checked is Some(_),
  }
}

///|
/// The menu open now (one at a time, as Radix's are), by its key ("" none), and where a right click opened it: what
/// reads the key whole (menu_open_key) told as it changes.
// kept across runs: put back by parts_reset, as a run begins (run_begin)
let menu_open : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })

///|
/// The menu open now, by member: what asks whether its own menu is open (menu_is) told as that one opens or closes, not
/// as another does.
// kept across runs: put back by parts_reset, as a run begins (run_begin)
let menu_open_by : @signals.Keyed[String] = @signals.keyed()

///|
// kept across runs: put back by parts_reset, as a run begins (run_begin)
let menu_open_at : Ref[(Double, Double)] = Ref((0.0, 0.0))

///|
/// The menus closed and still going out (their exit playing), by their keys, by member: what opened one keeps it built
/// till gone (menu_shown), told as its own comes or goes.
// kept across runs: put back by parts_reset, as a run begins (run_begin)
let menu_going : @signals.Keyed[String] = @signals.keyed()

///|
/// The menu open now ("" none), read so its change is told to what read it.
fn menu_now() -> String {
  menu_open.get()
}

///|
/// Whether the menu `key` is the one open now, read so only its own opening or closing is told to what read it.
fn menu_is(key : String) -> Bool {
  menu_open_by.has(key)
}

///|
/// The menu open now ("" none), as it is, read by nothing.
fn menu_open_peek() -> String {
  menu_open.untracked()
}

///|
/// The menu open now: `key` ("" none).
fn menu_set(key : String) -> Unit {
  if menu_open_peek() != key {
    @signals.start_batch()
    menu_open.set(key)
    menu_open_by.set(if key == "" { [] } else { [key] })
    @signals.end_batch()
  }
}

///|
/// No menu open, no mark's words (as a run begins: run_begin).
pub fn parts_reset() -> Unit {
  presenters_reset()
  menu_set("")
  menu_open_at.val = (0.0, 0.0)
  menu_going.set([])
}

///|
/// A menu's items as they are drawn (None a line between): none at either end and none twice in a row, whatever was
/// left out between them (a choice not offered here given as None), so no menu has a line hanging at its end or two
/// lines together.
pub fn menu_clean_items(items : Array[MenuItem?]) -> Array[MenuItem?] {
  let out : Array[MenuItem?] = []
  let mut rule = false
  for x in items {
    match x {
      None => rule = out.length() > 0
      Some(_) => {
        if rule {
          out.push(None)
          rule = false
        }
        out.push(x)
      }
    }
  }
  out
}

///|
/// One of a row's tools (tools_row): what it draws in the row, and what the row's ⋯ offers in its place once the row
/// has not the room for it (Ctx::box `drop`: the k-th to go; 0 never).
pub(all) struct Tool {
  key : String
  drop : Int
  draw : () -> Unit
  instead : Array[MenuItem]
}

///|
/// A tool drawn by `draw`, offering `instead` in the ⋯ when it goes (the `drop`-th).
pub fn tool_of(key : String, draw : () -> Unit, drop? : Int = 0, instead? : Array[MenuItem] = []) -> Tool {
  { key, drop, draw, instead }
}


///|
/// A row of tools (tools_row): 6 apart, more where a press's room needs it (keys_gap), on a line.
pub fn tools_line() -> @ui.Style {
  tools_line_look.then(@ui.style(gap=keys_gap(least=tools_apart)))
}

///|
// kept across runs: a value (no field of it changes)
let tools_line_look : @ui.Style = @ui.css("row align=ACenter")

///|
/// The key of the menu open now ("" none).
pub fn menu_open_key() -> String {
  menu_now()
}

///|
/// Whether the menu `key` is drawn: open, or closed and still going out. What shows its ⋯ only under the pointer
/// keeps it while this holds, so the menu goes out where it hung (not cut off, nor from the window's corner where
/// the ⋯ is not drawn the frame it plays in).
pub fn menu_shown(key : String) -> Bool {
  menu_is(key) || menu_going.has(key)
}

///|
/// The least a menu is wide (controls.css.ts menuList), and a menu of choices (chooserMenu).
pub let menu_w : Double = 180.0

///|
pub let chooser_menu_w : Double = 220.0

///|
let about_icon : Double = 14.0

///|
/// A switch's size by the screen, the theme's rows' (Rows: a finger's 44 by 26 with touch, the web's 36 by 22 on
/// a computer); small, 26 by 16.
fn switch_size(small : Bool) -> (Double, Double) {
  if small {
    (switch_small_w, switch_small_h)
  } else {
    let r = theme().rows
    (r.switch_w, r.switch_h)
  }
}

///|
/// A tick row's room (check_row): 12 by 10 in, its box 12 before its words, a row's corner, the hover grey under the
/// hand; as high at least, its words and its box as the theme's rows (Rows). Its box stands clear of the row's corners,
/// as far in from its start as the row is round: in the row's middle, as high as both its corners reach, no box of a
/// tick could be concentric with them (keyboard and mouse's 18 in a 40 row: 11 from its top and foot, as round as 9.2 there,
/// a circle), so it stands alone, its own corner.
// kept across runs: a value (no field of it changes)
let check_row_box : @ui.Style = @ui.css("row w=Full px=S3 py=S2_5 gap=S3 align=ACenter hovered{bg=Hover} pressed{bg=Hover}").then(
  @ui.style(radius=row_radius, pl=room(row_corner)),
)

///|
// kept across runs: a value (no field of it changes)
let switch_row_words : @ui.Style = @ui.css("w=Grow(1.0) gap=S0_5")

///|
/// How many wide sections what is drawn is in: a page's part in none stands as one of them does
/// (wide_alone).
// kept across runs: counted up and down round a section's body (0 between them)
let in_section : Ref[Int] = Ref(0)

///|
/// A page's part on a wide page standing alone, in no section (a group, a choice, a card of its own): as far from
/// what follows as a section is (section_box's 28), its own room over it the section's under what is over it.
fn wide_alone(c : @ui.Ctx, body : () -> Unit) -> Unit {
  if in_section.val > 0 || in_layers.val > 0 {
    body()
  } else {
    c.box(style=section_box, body) |> ignore
  }
}

///|
// kept across runs: a value (no field of it changes)
let section_box : @ui.Style = @ui.css("w=Full mb=S7")

///|
// kept across runs: a value (no field of it changes)
let section_title : @ui.TextStyle = @ui.text_style(size=Body, leading=L7, weight=Semibold, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let section_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted)

///|
/// A pill's tone (parts.tsx Tone): its ground and its words' ink.
#derive(Eq)
pub(all) enum PillTone {
  Neutral
  Green
  Blue
  Amber
  Red
  Accented
}

///|
let pill_icon : Double = 14.0

///|
/// A step's words (the ui's 13 on 20).
pub let step_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let steps_box : @ui.Style = @ui.css("w=Full gap=S2")

///|
// kept across runs: a value (no field of it changes)
let step_row : @ui.Style = @ui.css("row w=Full align=AStart")

///|
// kept across runs: a value (no field of it changes)
let step_number : @ui.Style = @ui.css("w=S5")

///|
// kept across runs: a value (no field of it changes)
let step_number_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let step_body : @ui.Style = @ui.style(row=true, w=grow, gap=S2, align=ACenter)


///|
let verify_icon : Double = 16.0

///|
// kept across runs: a value (no field of it changes)
let verify_line : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let verify_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Positive)

///|
// kept across runs: a value (no field of it changes)
let pill_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, wrap=false)

///|
/// Nothing here (parts.tsx Empty, parts.css.ts empty): what `body` says in the middle of the room it has, 40 in, its
/// parts 6 apart, in the muted ink (its words the page's, centred).
pub fn empty(c : @ui.Ctx, body : () -> Unit) -> Unit {
  c.box(style=empty_box, body) |> ignore
}

///|
/// What a list with nothing in it shows (empty's, as a node) in `parent`: what `body` makes, in the middle of the room
/// left, 40 in.
#callsite(autofill(loc))
pub fn empty_node(parent : @view.View, body : (@view.View) -> Unit, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(b) {
    style_node(b, fn() { empty_box })
    body(b)
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let empty_box : @ui.Style = @ui.css("w=Full h=Grow(1.0) p=S10 gap=S1_5 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let first_room : @ui.Style = @ui.css("w=Full align=ACenter py=S6")

///|
// kept across runs: a value (no field of it changes)
let first_box : @ui.Style = @ui.style(w=Full, max_w=first_most, pt=S2, pb=S6, gap=S2, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let first_title_at : @ui.Style = @ui.css("pt=S3")

///|
// kept across runs: a value (no field of it changes)
let first_title : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Fg, center=true)

///|
// kept across runs: a value (no field of it changes)
let first_lead : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, center=true)

///|
// kept across runs: a value (no field of it changes)
let first_lead_box : @ui.Style = @ui.style(max_w=first_lead_most, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let first_actions : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter justify=JCenter pt=S3")

// ---------------------------------------------------------------------------
// Dialogs (parts.tsx Dialog; parts.css.ts dialog, dialogHead, dialogLead, dialogBody, dialogFoot, overlay)

///|
/// What the window keeps round a dialog up and down (parts.css.ts dialog: at most 100dvh - 48 tall).
let dialog_room : Double = 48.0

///|
/// Its title's row (dialogHead: 25 under the top, 26 from the right): the close button at its end, its middle on the
/// title's (where it stands alone: dialog_close_at).
// kept across runs: a value (no field of it changes)
let dialog_head : @ui.Style = @ui.style(
  row=true,
  w=Full,
  justify=JBetween,
  align=ACenter,
  gap=S3,
  min_h=Fixed(dialog_close),
  pt=room(dialog_head_over),
  pr=room(dialog_head_end),
)

///|
/// How far its title's row stands under its padding's top, and in from its padding's end.
let dialog_head_over : Double = 1.0

///|
let dialog_head_end : Double = 2.0

///|
/// An untitled dialog's close button (dialog): in its top right corner as far in as makes it concentric with it
/// (capsule_in), from its outer edges (a layer is laid over the whole of the box, its padding too).
fn dialog_close_corner() -> @ui.Style {
  let d = @ui.capsule_in(dialog_r, dialog_close)
  @ui.style(mt=room(d), mr=room(d))
}

///|
/// The row an untitled dialog's close button stands at the end of (over what it holds).
// kept across runs: a value (no field of it changes)
let dialog_close_row : @ui.Style = @ui.css("row w=Full justify=JEnd")

///|
/// How far from its padding's end the first row of an untitled dialog keeps clear of its close button (and 8 more).
fn dialog_close_clear() -> Double {
  @ui.capsule_in(dialog_r, dialog_close) - dialog_pad + dialog_close + 8.0
}

///|
/// What the first row of what an untitled dialog holds keeps clear of at its end, its close button over it (0 elsewhere).
// kept across runs: said by dialog round what an untitled one holds
let untitled_clear_now : Ref[Double] = { val: 0.0 }

///|
/// The room a head of its own keeps at its end in an untitled dialog, its close button over it there (none elsewhere).
pub fn untitled_clear() -> @ui.Style {
  @ui.style(pr=room(untitled_clear_now.val))
}

///|
/// An untitled dialog's body from under its close button (no title over it to stand 18 under): what it holds clear of
/// the button in its corner, pressed where it is drawn (the user, 2026-11-04: 内容让开关闭按钮; the button 26 in to be
/// concentric with the dialog's 42 stood over what a column 24 in holds).
fn dialog_untitled_top() -> @ui.Style {
  @ui.style(pt=room(@ui.capsule_in(dialog_r, dialog_close) + dialog_close - dialog_pad))
}

///|
/// Where its close button stands at its title's row's end: in its top right corner as far in as makes it concentric
/// with it (capsule_in: a mouse's 32 18 in, the ladder's pane corner's own place for it as on the tape's line; a
/// finger's 44, 12), the row as high as with a mouse's (its margins making up the rest, its middle no longer the
/// title's; the user, 2026-10-25: 25 in, by the corner and not with it).
fn dialog_close_at() -> @ui.Style {
  let side = dialog_close
  let d = @ui.capsule_in(dialog_r, side)
  let up = d - (dialog_pad + dialog_head_over)
  @ui.style(mt=room(up), mr=room(d - (dialog_pad + dialog_head_end)), mb=room(dialog_close - side - up))
}

///|
// kept across runs: a value (no field of it changes)
let dialog_title : @ui.TextStyle = @ui.text_style(size=Heading, weight=Semibold, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let dialog_lead_at : @ui.Style = @ui.css("w=Full pt=S1_5")

///|
// kept across runs: a value (no field of it changes)
let dialog_lead : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted)

///|
/// What it holds: 18 under the title (or its lead), its parts 16 apart.
// kept across runs: a value (no field of it changes)
let dialog_body : @ui.Style = @ui.css("w=Full pt=S4_5 gap=S4")

///|
/// Its buttons: at its end, 8 apart, 24 under what it holds; the last in its foot corner concentric with it (a pane of
/// the ladder's: dialog_corner_foot).
// kept across runs: a value (no field of it changes)
let dialog_foot : @ui.Style = @ui.css("row w=Full justify=JEnd align=ACenter gap=S2 pt=S6")

///|
/// A dialog's sides' room (24).
let dialog_pad : Double = 24.0

///|
// kept across runs: a value (no field of it changes)
let no_style : @ui.Style = @ui.css("")

///|
/// With no buttons, its body down to its foot, 24 under what it holds (a card there comes down to `corner_inset` over
/// it: panel_card_foot).
// kept across runs: a value (no field of it changes)
let dialog_body_end : @ui.Style = dialog_body.then(@ui.css("pb=S6"))

// ---------------------------------------------------------------------------
// Fields, selects, choices (parts.tsx Field, Select, Choices; parts.css.ts field, select, choice, radio)

///|
// kept across runs: a value (no field of it changes)
let field_box : @ui.Style = @ui.css("w=Full gap=S1_5")

///|
/// A field on a wide page: 420 at most (rule 5: what is typed not the column's whole width).
let field_box_wide : @ui.Style = field_box.then(@ui.style(max_w=Fixed(field_wide_most)))

///|
pub let field_wide_most : Double = 420.0

///|
// kept across runs: a value (no field of it changes)
let field_top : @ui.Style = @ui.css("row w=Full justify=JBetween align=AEnd gap=S2")

///|
// kept across runs: a value (no field of it changes)
let field_label : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Medium, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let field_error : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Danger)

///|
// kept across runs: a value (no field of it changes)
let field_hint : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted)

///|
/// A field's corner, one for all of them: half its controls' height (Theme::control_h), so a one-line field is a
/// capsule and lines to type in (textarea) are one grown taller, its corners its ends'.
pub fn field_round() -> Double {
  theme().control_h / 2.0
}

///|
/// A textarea's lines, and what its frame adds over them (7
/// and 1 above and under).
let textarea_line : Double = 22.4

///|
let textarea_in : Double = 16.0

///|
/// What is typed in: as what is read (global.css.ts --text-input), on the line of a list's words.
let input_size : Double = 14.0

///|
// kept across runs: a value (no field of it changes)
let select_words : @ui.TextStyle = @ui.text_style(size=Body, leading=L6, wrap=false, color=Fg)

///|
/// How many one_of lists where it is; more are a select's.
let one_of_listed_most : Int = 5

///|
/// A row of one_of: as wide as where it is, 12 in, its words and its check apart, a row's corner (row_radius).
// kept across runs: a value (no field of it changes)
let one_of_row : @ui.Style = @ui.css("row w=Full px=S3 gap=S2 align=ACenter justify=JBetween disabled{opacity=O55}").then(
  @ui.style(radius=row_radius),
)

///|
let one_of_check : Double = 16.0

///|
/// A choice: bordered, a block's corner of the ladder's (18: at a card's foot, reaching to its inset, concentric with
/// its corners; every one alike).
// kept across runs: a value (no field of it changes)
let choice_card : @ui.Style = @ui.css("w=Full bg=Surface border=B0_5 border_color=Line disabled{opacity=O55}").then(
  @ui.style(radius=row_radius),
)

///|
/// Its words a card's padding in from its edge, as a card's are (not on the panel's line: 卡片里的字跟面板的字不需要对齐).
// kept across runs: a value (no field of it changes)
let choice_hit_in_panel : @ui.Style = @ui.style(px=room(card_pad), py=S4)

///|
/// Pointed at: its hairline in the border (control_edge); chosen: edged twice in the ink (its line and a ring of 1).
// kept across runs: a value (no field of it changes)
let choice_card_hot : @ui.Style = choice_card.then(@ui.css("border_color=Border"))

///|
// kept across runs: a value (no field of it changes)
let choice_card_on : @ui.Style = choice_card.then(@ui.css("border=B2 border_color=Fg"))

///|
/// What is pressed of it (choiceHit): 12 by 14 in, its parts 12 apart.
// kept across runs: a value (no field of it changes)
let choice_hit : @ui.Style = @ui.css("row w=Full px=S3_5 py=S3 gap=S3 align=ACenter")

///|
/// (choice_hit with a description under its title: what is beside its words by its title's line)
// kept across runs: a value (no field of it changes)
let choice_hit_top : @ui.Style = @ui.css("row w=Full px=S3_5 py=S3 gap=S3 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let choice_extra : @ui.Style = @ui.css("w=Full px=S3_5")

///|
// kept across runs: a value (no field of it changes)
let choice_extra_in : @ui.Style = @ui.css("w=Full pt=S3 pb=S3_5")

///|
/// Narrow, where what it holds are rows each a ground pressed whole: those a step of the ladder in from the choice's
/// sides and its foot (corner_inset), round as that step (in_card: Inner), concentric with its corners.
// kept across runs: a value (no field of it changes)
let choice_extra_rows : @ui.Style = @ui.style(w=Full, px=inset_room)

///|
// kept across runs: a value (no field of it changes)
let choice_extra_rows_in : @ui.Style = @ui.style(w=Full, pt=S3, pb=inset_room)

///|
// kept across runs: a value (no field of it changes)
let choice_words : @ui.Style = @ui.css("w=Grow(1.0) gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let choice_title : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Semibold, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let choice_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted)

///|
/// The radio mark: 18 round, edged 1.5 (the strong grey; the ink chosen), its dot 8 in the ink.
// kept across runs: a value (no field of it changes)
let radio_mark : @ui.Style = @ui.css((
  #|w=S4_5 h=S4_5 radius=Full border=B1 border_color=Border align=ACenter justify=JCenter
))

///|
// kept across runs: a value (no field of it changes)
let radio_mark_on : @ui.Style = radio_mark.then(@ui.css("border_color=Fg"))

///|
// kept across runs: a value (no field of it changes)
let radio_dot : @ui.Style = @ui.css("w=S2 h=S2 radius=Full bg=Fg")







// ---------------------------------------------------------------------------
// A small panel's parts (parts.tsx PanelHead, PanelGroup, PanelNote, PanelFoot, PanelText, PanelButton,
// PanelIconButton; parts.css.ts: inside a small panel, @sf.small_panel, its rows @sf.menu_item(panel=true))

///|
/// A small panel's head with what stands at its end: its title in by a row's padding, 12 before what follows it, which
/// takes the rest of the line, 4 over what follows.
// kept across runs: a value (no field of it changes)
let panel_head_line : @ui.Style = @ui.css("row w=Full pl=S4 pb=S1 gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let panel_head_end : @ui.Style = @ui.style(w=grow)

///|
/// How a small panel's button stands (PanelButton's tone): its words alone, the accent's ink (the one thing to do),
/// muted (a lesser one), or the accent's pale ground always (one that must be seen).
#derive(Eq)
pub(all) enum PanelTone {
  Plainly
  Accent
  Quiet
  Filled
}

///|
// kept across runs: a value (no field of it changes)
let panel_head_box : @ui.Style = @ui.css("w=Full px=S4 pt=S1_5 pb=S1 gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let panel_title : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Semibold, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let panel_note_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let panel_group_box : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let panel_label_at : @ui.Style = @ui.css("w=Full px=S4 pt=S1_5 pb=S0_5")

///|
/// A label with something before it (panel_group_node's `lead`): in a line, 6 apart.
// kept across runs: a value (no field of it changes)
let panel_label_led : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let panel_text_box : @ui.Style = @ui.css("w=Full px=S4")

///|
// kept across runs: a value (no field of it changes)
let panel_button_box : @ui.Style = @ui.css((
  #|row h=S6 px=S2_5 gap=S1 radius=Full align=ACenter justify=JCenter hovered{bg=Hover} disabled{opacity=O50}
))

///|
// kept across runs: a value (no field of it changes)
let panel_button_filled : @ui.Style = panel_button_box.then(@ui.css("bg=AccentBg"))

///|
// kept across runs: a value (no field of it changes)
let panel_button_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, weight=Medium, wrap=false, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let panel_button_accent : @ui.TextStyle = panel_button_words.then(@ui.text_style(color=AccentText))

///|
// kept across runs: a value (no field of it changes)
let panel_button_quiet : @ui.TextStyle = panel_button_words.then(@ui.text_style(color=Muted))





// ---------------------------------------------------------------------------
// A chooser (parts.tsx Chooser; controls.css.ts chooser)


///|
/// A choice that opens a menu of what it can be (Chooser, controls.css.ts chooser): quiet words (12) and a small
/// chevron, 28 high, 8 in, 8 round, the hover's ground and the ink pointed at or open; pressed, its menu (@sf.dropdown) of
/// `entries` (a choice each: @kit.menu_radio) on `side`, 220 wide at least. `open`: whether its menu is open now, the
/// view's; `set_open`: what opens or closes it, as it is pressed (as it is let go) or dismissed (at that moment: Escape,
/// a press beside it). What was chosen comes back. `lead`: what stands before its words (a station's mark), in the ink
/// its words have. `disabled`: out of reach, with any open menu closed. `capsule`: round it as a capsule when it sits
/// at the end of another capsule, so the two can share a centre. `as_button`: the size and text style of a button,
/// retaining the chooser's quiet colors, with a chevron after its words. `on_pick`: what choosing an entry does, given
/// its value, as it is chosen, outside any build (closing it, `set_open(false)`, its own).
pub fn chooser(
  c : @ui.Ctx,
  key : String,
  words : String,
  entries : Array[@kit.Entry],
  open : () -> Bool,
  set_open : (Bool) -> Unit,
  side? : @ui.Side = Bottom,
  lead? : (Int64) -> Unit,
  disabled? : Bool = false,
  capsule? : Bool = false,
  as_button? : Bool = false,
  on_pick? : (String) -> Unit,
) -> @kit.Menu {
  let p = theme().p
  let id = c.id(key)
  if !disabled {
    c.on_press(id, fn() { set_open(!open()) })
    // Set the view's state as the key comes, before layout can rebuild the frame without that key. Otherwise the
    // menu may open for one build, lose its first-item focus on the next, and reopen with its panel focused instead.
    c.on_key(id, fn(code, mods) {
      if code == @ui.key_code_down && mods == 0 && !open() {
        set_open(true)
        true
      } else {
        false
      }
    })
  } else if open() {
    c.tell(key + "/disabled", fn() { set_open(false) })
  }
  let opened = open() && !disabled
  let focused = !disabled && c.focus_shown(id)
  let lit = !disabled && (c.lit(id) || opened || focused)
  let at_foot = card_foot_words_now.val
  let height = @ui.Space::px(S7)
  let mut b = -1
  let draw = fn() {
    let look = if capsule || at_foot { chooser_box.then(chooser_capsule) } else { chooser_box }
    let look = if at_foot && lead is None { look.then(@ui.style(px=room(card_foot_words_in(height)))) } else { look }
    b = c.box(style=look, selected=opened || focused, disabled~, id=if disabled { 0 } else { id }, fn() {
      match lead {
        Some(f) => f(if lit { p.text } else { p.muted })
        None => ()
      }
      c.text(words, style=if lit { chooser_words_lit } else { chooser_words }) |> ignore
      icon(c, "chevron-down", size=chooser_chevron, color=if lit { p.text } else { p.muted }) |> ignore
    })
  }
  if as_button {
    let node = button_part(
      c,
      words,
      key~,
      tone=Ghost,
      disabled~,
      end_icon="chevron-down",
      lead?,
      ink_override=if lit { p.text } else { p.muted },
      active=opened || focused,
      expanded=opened,
    )
    b = node
  } else if at_foot {
    // A 28-high chooser may wrap to the foot's corner on its own. Give it a button-high line and put its capsule
    // where that height meets the card's corner; its words then meet the card's words as the buttons' do.
    let inset = card_foot_in(height) - card_foot_in(button_height())
    c.box(style=@ui.style(row=true, h=Fixed(button_height()), pl=room(inset), align=ACenter), draw) |> ignore
  } else {
    draw()
  }
  if !disabled {
    c.focusable(id, node=b)
  }
  if !as_button {
    c.semantics(b, Button, id=if disabled { 0 } else { id }, label=words, expanded=opened, disabled~)
  }
  let menu : Ref[@kit.Menu?] = Ref(None)
  c.with_dismissed(fn(_) { set_open(false) }, fn() {
    menu.val = Some(dropdown(c, key + "/menu", opened, if disabled { 0 } else { id }, entries, {}, chooser_menu_w, side~, on_pick?))
  })
  menu.val.unwrap()
}

///|
// kept across runs: a value (no field of it changes)
let chooser_box : @ui.Style = @ui.css((
  #|row h=S7 px=S2 gap=S1_25 radius=Lg align=ACenter hovered{bg=Hover} selected{bg=Hover}
))

///|
// kept across runs: a value (no field of it changes)
let chooser_capsule : @ui.Style = @ui.css("radius=Full")

///|
// kept across runs: a value (no field of it changes)
let chooser_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, wrap=false, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let chooser_words_lit : @ui.TextStyle = chooser_words.then(@ui.text_style(color=Fg))

// ---------------------------------------------------------------------------
// A column's edge (parts.tsx ResizeHandle, usePointerTip; Rail.tsx SidebarEdge and DriveViews.tsx ColumnEdge look as
// it does and take the pointer as it does)

///|
/// What a column's edge was done with this frame.
#derive(Eq, Debug)
pub(all) enum Resized {
  /// nothing
  Untouched
  /// dragged (once it went past the slop from where it was pressed) to this width
  Dragging(Double)
  /// let go after it was dragged, at this width
  Dropped(Double)
  /// pressed and let go without moving (the web's `press`: a panel closing)
  Pressed
  /// the second of two clicks (the first was `Pressed`): its own width again, or as wide as what it holds needs
  Twice
}

///|
/// As what an edge's handle was done with is written (tests compare it): what `derive(Show)` wrote, a number as its text.
pub impl Show for Resized with output(self, logger) {
  match self {
    Untouched => logger.write_string("Untouched")
    Dragging(v) => logger.write_string("Dragging(\{v})")
    Dropped(v) => logger.write_string("Dropped(\{v})")
    Pressed => logger.write_string("Pressed")
    Twice => logger.write_string("Twice")
  }
}

///|
/// How an edge shows: its bar `over` its column, or `on` it (pointed at, focused, in hand), or `active` (pressed,
/// dragged); the line along it on it or active, unless it has `line` false.
fn edge_state(over : Bool, on : Bool, active : Bool, line : Bool) -> Int {
  (if over || on || active { 1 } else { 0 }) |
  (if on || active { 2 } else { 0 }) |
  (if active { 4 } else { 0 }) |
  (if (on && line) || active { 8 } else { 0 })
}

///|
pub let edge_bar_ms : Double = 180.0

///|
pub let edge_ink_ms : Double = 150.0

///|
pub let edge_line_ms : Double = 140.0

///|
/// How far in the card of options' rows stand: a list card's (list_pad, as a menu's rows in its panel), round by the
/// ladder's row corner in its corners.
let options_card_pad : Double = list_pad

///|
/// An option's row's corner (the ladder's row corner, concentric in the card's).
let option_row_corner : Double = row_corner

///|
/// An option's measures, the theme's for the screen (decided once): its number's disc a list
/// item's mark, as far in from the row's top and side as makes it concentric with the row (its corner less the disc's
/// half); its label in the controls' words, what it leads to in the meta's. Keyboard and mouse's as the web's
/// (13 on 20 over 12 on 18); a phone's or a tablet's a size up (a 22 disc 7
/// in, 15 on 22 over 13 on 18).
priv struct OptionType {
  disc : Double
  pad_in : Double
  label : Double
  label_line : Double
  detail : Double
  detail_line : Double
}

///|
fn option_type() -> OptionType {
  let t = theme()
  let disc = t.items.mark
  {
    disc,
    pad_in: @ui.capsule_in(option_row_corner, disc),
    label: t.t.ui,
    label_line: t.t.ui_line,
    detail: t.t.meta,
    detail_line: t.t.meta_line,
  }
}

///|
/// The card of options in the wide frame: as wide as what it says, 460 at least; on a phone
/// as wide as where it is.
let options_least_wide : Double = 460.0

///|
/// The card's width at most: as wide as its widest label or detail with its number and paddings, 460 at least (the
/// web's `width: fit-content; min-width: min(100%, 460px)`), where it is at most as its layout gives it (the card fills
/// where it is up to this: never its room read back from a frame before, which a chat's first frame has not, the card
/// laid out none wide there and the list again in the next); on a phone where it is's (none).
fn options_most(options : Array[(String, String, Bool)], ot : OptionType, wide : Bool) -> Double {
  if !wide {
    return 1.0e9
  }
  let mut words = 0.0
  for o in options {
    words = dmax(words, @ui.text_advance(o.0, size=ot.label, weight=500))
    words = dmax(words, @ui.text_advance(o.1, size=ot.detail, weight=400))
  }
  // (the card's inset each side, the row's number in by 8 and 12 after it, the row's 12 at its end)
  dmax(options_least_wide, options_card_pad * 2.0 + ot.pad_in + ot.disc + 12.0 + words + 12.0).ceil()
}

///|
/// The card's corner: a list card's (a column of rows list_pad in, list_card_corner), its rows round by the ladder's
/// row corner and their discs concentric with them (as far in as their half less that: the row's pad_in).
let options_card_radius : Double = list_card_corner

///|
/// What leads ask_line_card's words (what the chat needs: its bell), where an option's number is: in the middle of a
/// column as wide and as high as its disc, so it stands as far in from the row's corner as the disc, concentric.
pub fn ask_line_mark() -> @ui.Style {
  let d = ask_line_disc()
  @ui.style(w=Fixed(d), h=Fixed(d), align=ACenter, justify=JCenter)
}

///|
/// How big the check in a picked option's disc is, of the disc.
pub let option_check_share : Double = 0.6

///|
/// Where the check stands in a picked option's disc, over its number: its middle.
// kept across runs: a value (no field of it changes)
let option_check_room : @ui.Style = @ui.css("w=Full h=Full align=ACenter justify=JCenter")

///|
/// How far an option's row keeps its words from its end, where the one being sent turns.
let option_row_end : Double = 12.0

///|
/// Room at the start of ask_line_card's row where no mark leads it (what the chat needed, let go): its words where the
/// mark `icon` wide would start in ask_line_mark's column.
pub fn ask_line_start(icon : Double) -> @ui.Style {
  let side = (ask_line_disc() - icon) / 2.0
  @ui.style(pl=room(side))
}

///|
// kept across runs: a value (no field of it changes)
let ask_line_button_words : @ui.TextStyle = @ui.text_style(w=Hug, wrap=false)

///|
/// The words of ask_line_card's row (what it says, 忽略 at its end): `words` on lines as high as ask_line_mark's
/// column, as an option's label on its disc, so the first line has the mark in its middle and the row as far over it
/// as under it. (On a list's state line, 18 against the disc's 20 laid from the top, the words stood 1 over the bell.)
pub fn ask_line_words(words : @ui.TextStyle) -> @ui.TextStyle {
  words.then(@ui.text_style(leading=theme().items.mark_line))
}

///|
/// The width of ask_line_mark's column: an option's disc, the theme's for the screen.
fn ask_line_disc() -> Double {
  option_type().disc
}

///|
/// ask_line_card's ground: an option row's corner, on the text at 5%.
// kept across runs: a value (no field of it changes)
let ask_line_ground : @ui.Style = @ui.css("bg=A(Fg,O5)").then(@ui.style(radius=rounded(option_row_corner)))

///|
/// Its row: 12 between its words and what is at its end, as an option's disc and label.
// kept across runs: a value (no field of it changes)
let ask_line_row : @ui.Style = @ui.css("row w=Full gap=S3 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let ask_line_column : @ui.Style = @ui.css("w=Full align=AStart")

///|
// kept across runs: a value (no field of it changes)
let dialog_title_line : @ui.Style = @ui.style(row=true, w=grow, gap=S2, align=AEnd)

///|
// kept across runs: a value (no field of it changes)
let dialog_step : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let dialog_title_one : @ui.TextStyle = dialog_title.then(one_line)


///|
/// The same page (waiting_page) as nodes of the window's tree, made once in `parent`: its mark, `title()` and `lead()`
/// as they change, then what `body` makes in the column under them; `clear()` of the room's top is under something
/// else (a bar over the page), which a touch screen's column never starts under. The node.
#callsite(autofill(loc))
pub fn waiting_page_node(
  parent : @view.View,
  mark : String,
  title : () -> String,
  lead : () -> String,
  body : (@view.View) -> Unit,
  clear? : () -> Double = fn() { 0.0 },
  loc~ : SourceLoc,
) -> @view.View {
  // (the native input the app was started with: the same the whole run)
  let touch = @signals.untracked(native_input) is Finger
  parent.box(made_for=loc, fn(room) {
    style_node(room, fn() { if touch { wait_room_touch } else { wait_room } })
    if touch {
      // (no less than what is over the room's top: in the middle as before while there is room for both, then under
      // the bar and down)
      room.box(fn(spring) {
        style_node(spring, fn() { wait_spring })
        spring.min_height(By(fn() { Some(clear()) })) |> ignore
      })
      |> ignore
    } else {
      room.box(fn(top) { top.height(Is(Some(wait_top))) |> ignore }) |> ignore
    }
    room.box(fn(col) {
      style_node(col, fn() { if touch { wait_column_touch } else { wait_column } })
      // (all of the room across up to its most, in its middle: the room lines it up there, not stretched to its start)
      col.fills_across(Is(false)).width_share(Is(1.0)) |> ignore
      icon_node(col, mark, if touch { wait_icon_touch } else { wait_icon }, By(fn() { theme().p.text })) |> ignore
      // (each line in the middle, as the old view's centred words: Ctx::text's `center`)
      words_node(col, title, fn() { if touch { wait_title_touch } else { wait_title } }).words_centered(Is(true))
      |> ignore
      words_node(col, lead, fn() { wait_lead }).words_centered(Is(true)) |> ignore
      body(col)
    })
    |> ignore
    if touch {
      room.box(fn(spring) { style_node(spring, fn() { wait_spring }) }) |> ignore
    }
  })
}

///|
/// The desktop page's place (waiting: margin 110 auto 0) and the touch screen's (mWaiting: its height, the column in
/// its middle).
// kept across runs: a value (no field of it changes)
let wait_room : @ui.Style = @ui.css("w=Full h=Full align=ACenter")

///|
let wait_top : Double = 110.0

///|
// kept across runs: a value (no field of it changes)
let wait_room_touch : @ui.Style = @ui.css("w=Full h=Full align=ACenter")

///|
/// What holds the touch screen's column in the middle of its height, one over it and one under: each takes half the
/// room left, and none where the column is taller than the room, so it starts at the room's top and only its foot
/// runs past (a column centred by `justify` loses its head as much as its foot: the lock's page with many trusted
/// devices under its action, #4213).
// kept across runs: a value (no field of it changes)
let wait_spring : @ui.Style = @ui.style(h=grow)

///|
/// The column: 460 wide at most, 24 in at its sides (waiting); a touch screen's 28 in (mWaiting); 14 apart.
// kept across runs: a value (no field of it changes)
let wait_column : @ui.Style = @ui.css("w=Full px=S6 gap=S3_5 align=ACenter").then(@ui.style(max_w=Fixed(wait_w)))

///|
let wait_w : Double = 460.0

///|
// kept across runs: a value (no field of it changes)
let wait_column_touch : @ui.Style = @ui.css("w=Full px=S7 gap=S3_5 align=ACenter")

///|
/// The mark: 40 on the desktop page, 44 on a touch screen.
let wait_icon : Double = 40.0

///|
let wait_icon_touch : Double = 44.0

///|
/// The title: the heading's size, 600 (waitingTitle); a touch screen's bold (mWaitingTitle, a <b>).
// kept across runs: a value (no field of it changes)
let wait_title : @ui.TextStyle = @ui.text_style(size=Heading, weight=Semibold, color=Fg, center=true)

///|
// kept across runs: a value (no field of it changes)
let wait_title_touch : @ui.TextStyle = @ui.text_style(size=Heading, weight=Bold, color=Fg, center=true)

///|
/// What it waits for: the body's, muted (waitingLead).
// kept across runs: a value (no field of it changes)
let wait_lead : @ui.TextStyle = @ui.text_style(size=Meta, leading=L7, color=Muted, center=true)

///|
/// Where a way-in page's picture ends, down its page (way_in_page): a little over its middle, so a page of a button or
/// two sits about the middle and one with more has room under it.
let way_in_picture_foot : Double = 0.42

///|
/// How far down a way-in page what it holds starts (way_in_whole's py: S10).
let way_in_page_top : Double = 40.0

///|
/// Between the sign-in button's spinner and its words.
let sign_in_spin_gap : Double = 8.0

///|
/// The sign-in button's width at most on a desktop, as the desktop app's.
let sign_in_desk_w : Double = 300.0

///|
/// On a phone or a tablet: across a phone's page less its sides; no wider than this on a larger one.
let sign_in_touch_w : Double = 420.0

///|
/// The button: 50 high, a pill (SignIn.kt: height(50.dp), CircleShape).
let sign_in_button_h : Double = 50.0

///|
/// The button's words' room from its ends: past where its round ends turn, so its words are never in their curve.
let sign_in_button_padx : Double = 20.0

///|
/// The button's words' room above and below, where they take two lines: within its 50 while they take one.
let sign_in_button_pady : Double = 10.0

///|
/// The picture: as wide as the button at most (SignIn.kt: widthIn(max = 300.dp)), never past the page's sides.
let sign_in_picture_w : Double = 300.0

///|
/// What the page leaves either side of the picture (its sides: way_in_whole's px).
let sign_in_side_w : Double = 30.0


///|
/// How far round the mark has turned where a turn is at `k` (0 to 1): the same speed through each turn's join, so it
/// never appears to stop while catching up.
fn sync_turned(k : Double) -> Double {
  k * 2.0 * 3.141592653589793
}

///|
/// How fast it turns (radians per ms), including at a turn's join.
fn sync_turning() -> Double {
  2.0 * 3.141592653589793 / sync_turn_ms
}

///|
/// The mark brought to rest once all is here: from `from`, going `speed` (per ms), to `to` in `ms`, as a cubic going on
/// from that speed and slowing to none there.
#derive(Eq)
priv struct SyncRest {
  ms : Double
  from : Double
  speed : Double
  to : Double
}

///|
/// Where it rests from a turn's state at moment `now`: the next half turn on (the mark is two arrows, the same turned
/// half round), slowing evenly from its speed (what it has to go over half its speed: in sync_settle_least to
/// sync_settle_most), not going back.
fn sync_rest(now : Double) -> SyncRest {
  let pi = 3.141592653589793
  let p = now / sync_turn_ms
  let k = p - p.floor()
  let from = sync_turned(k)
  let speed = sync_turning()
  // a cubic from `speed` to none goes back unless what it has to go is at least a third of `speed` over its time
  let mut to = (from / pi).ceil() * pi
  while to <= from || speed * sync_settle_least > 3.0 * (to - from) {
    to = to + pi
  }
  let even = if speed > 0.0 { 2.0 * (to - from) / speed } else { sync_settle_most }
  let ms = dmin(sync_settle_most, dmax(sync_settle_least, even))
  { ms, from, speed, to }
}

///|
/// How far on to rest it is where its time is at `s` (0 to 1): leaving at its speed, arriving with none (a cubic
/// Hermite, from 0 to 1).
fn SyncRest::ease(self : SyncRest, s : Double) -> Double {
  let lead = if self.to > self.from { self.ms * self.speed / (self.to - self.from) } else { 0.0 }
  let s2 = s * s
  let s3 = s2 * s
  (s3 - 2.0 * s2 + s) * lead + (3.0 * s2 - 2.0 * s3)
}

///|
/// The refresh mark's parts with `left` of each drawn (1 whole, 0 none): each arrow's curve from its head, the head's
/// two strokes from their corner where the curve starts (refresh's data: curve, head, curve, head).
fn sync_drawn_back(part : Int, pts : Array[Double], left : Double) -> Array[Array[Double]] {
  if part % 2 == 0 {
    [stroke_from_start(pts, left)]
  } else {
    // (a head: its first point, its corner, its last)
    [
      stroke_from_start([pts[2], pts[3], pts[0], pts[1]], left),
      stroke_from_start([pts[2], pts[3], pts[4], pts[5]], left),
    ]
  }
}

///|
/// What the catching up said last, by its key (said as it goes), and whether it showed (only then the tick).
// kept across runs: put back as it goes (sync_key), and as a run begins (on_reset)
let sync_said : LiveMap[String, String] = LiveMap::new()

///|
// kept across runs: put back as it goes (sync_key), and as a run begins (on_reset)
let sync_seen : LiveMap[String, Bool] = LiveMap::new()

///|
/// Where each mark comes to rest once all is here, by its key, from the frame it was.
// kept across runs: put back as it goes (sync_key), and as a run begins (on_reset)
let sync_rests : LiveMap[String, SyncRest] = LiveMap::new()

///|
/// A run begins with nothing caught up: what a run before left showing (a mark seen, its tick still to come, as that
/// run ended) is no run's after it (a Home's catching up drawn as going away in the next run's first frames).
fn init {
  @ui.on_reset(fn() {
    sync_said.clear()
    sync_seen.clear()
    sync_rests.clear()
  })
}

///|
/// A turn of the mark: evenly, but slower than the other waiting rings (spinner_turn_ms), as it only says the list is
/// catching up in the background, nothing to wait for (the user, 2026-11-14: 1.4 s, not 0.8).
let sync_turn_ms : Double = 1400.0

///|
/// How long the mark takes to come to rest, at least and at most; how far on in that the arrows start to go.
let sync_settle_least : Double = 150.0

///|
let sync_settle_most : Double = 700.0

///|
let sync_rest_gone : Double = 0.8

///|
/// How long the tick stays once drawn, how long the arrows take to be drawn back and the tick to be drawn (begun as
/// they are mostly back), and to fade.
let sync_done_ms : Double = 1000.0

///|
let sync_back_ms : Double = 180.0

///|
let sync_tick_ms : Double = 240.0

///|
let sync_out_ms : Double = 400.0


///|
/// What a key holds, in its middle, over what else it holds (sync_key's marks turning into each other).
// kept across runs: a value (no field of it changes)
let update_ring_at : @ui.Style = @ui.css("w=Full h=Full align=ACenter justify=JCenter")

///|
/// What comes (a download), drawn as an icon in an icon's place, as a node of the window's tree in `parent`: the
/// download's mark `size` across in `color`, the ring round it the accent from its top as far round as `coming` says it
/// has come (0 to 1), going to a part told anew over @motion.progress_ms, eased out (progress_spinner's).
#callsite(autofill(loc))
pub fn coming_mark_node(
  parent : @view.View,
  coming : () -> Double,
  size : Double,
  color : () -> Int64,
  loc~ : SourceLoc,
) -> Unit {
  let stroke = size * icon_stroke / 24.0
  let side = size * coming_ring / 24.0 + stroke
  let pi = 3.141592653589793
  let mid = side / 2.0
  let r = mid - stroke / 2.0
  let ring = @ui.arc(mid, mid, r, from=0.0, sweep=2.0 * pi)
  let part = fn() {
    let k = coming()
    if k < 0.0 {
      0.0
    } else if k > 1.0 {
      1.0
    } else {
      k
    }
  }
  let way = @motion.NodeWay::new(@signals.untracked(part))
  let look = coming_mark_box(size)
  parent.box(made_for=loc, fn(m) {
    style_node(m, fn() { look })
    m.reacts(part, fn(k) { way.go_ms(m, k, @motion.progress_ms) })
    m.box(fn(l) {
      l
      .width(Is(Some(side)))
      .height(Is(Some(side)))
      .lines(By(fn() {
        let t = theme()
        let shown = way.shown(m)
        let lines = [@ui.line(ring, width=stroke, color=t.p.line_strong)]
        if shown > 0.0 {
          lines.push(@ui.line(@ui.arc(mid, mid, r, from=-0.5 * pi, sweep=shown * 2.0 * pi), width=stroke, color=t.p.accent))
        }
        lines
      }))
      |> ignore
    })
    |> ignore
    m.box(fn(o) {
      o.over(Is(true)) |> ignore
      style_node(o, fn() { update_ring_at })
      icon_node(o, "download-ring", size, By(color)) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// What coming_mark_node draws in: `size` square, what it holds in its middle.
fn coming_mark_box(size : Double) -> @ui.Style {
  @ui.style(w=Fixed(size), h=Fixed(size), align=ACenter, justify=JCenter)
}

///|
/// The icons' line (design/icons: stroke-width 1.75 of 24), and the width of the circles they draw (3.5 to 20.5).
let icon_stroke : Double = 1.75

///|
let coming_ring : Double = 17.0

///|
/// Its dot: 3 in from the key's top right, 9 across on a ring of the page's ground 2 wide.
// kept across runs: a value (no field of it changes)
let update_dot_at : @ui.Style = @ui.style(w=Full, h=Full, pt=room(update_dot_in), pr=room(update_dot_in), align=AEnd)

///|
let update_dot_in : Double = 3.0

///|
// kept across runs: a value (no field of it changes)
let update_dot_ring : @ui.Style = @ui.style(
  w=Fixed(update_dot_side),
  h=Fixed(update_dot_side),
  radius=Full,
  bg=Bg,
  p=room(update_dot_rim),
)

///|
let update_dot_side : Double = 13.0

///|
let update_dot_rim : Double = 2.0

///|
// kept across runs: a value (no field of it changes)
let update_dot_bad : @ui.Style = @ui.css("w=Full h=Full radius=Full bg=Danger")

///|
/// A menu's row at a dialog's foot: a capsule (row_line's there).
// kept across runs: a value (no field of it changes)
let menu_row_capsule : @ui.Style = @ui.css("radius=Full")
