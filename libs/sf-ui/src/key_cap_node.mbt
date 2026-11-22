// Keys and round tools (辅助键帽与工具圆钮) as nodes of the window's tree, made once: a key of a keyboard's bar (a
// terminal's keys over its soft keyboard, a screen's keys row: Esc, Tab, the arrows, a modifier held for the next key)
// and a round tool beside a picture (a mouse's button floating at a screen's foot, 退出全屏). What each is to the hand,
// the keyboard and a screen reader is mbui's headless button's (a modifier held, a toggle button's: read out pressed
// while held); here their look, and what still.fail wants of them besides: a key that leaves the keyboard's focus where
// it is (`steals_focus` false: a terminal's keys, pressed as one types, never taking the focus off what is typed in),
// one that goes on pressing while it is held (`repeat`: from 400 ms, every 45 ms, as a keyboard's key), and the feel of
// a press going down (`felt`).

///|
/// How a key looks: `Tile` (a terminal's keys: a tile 10 round on the raised ground, solid in the primary's while
/// held or where it is the one that sends, the hover's over it pressed; its words semibold or its mark 18 in the ink
/// on it); `Pill` (a screen's keys row: 36 high, 40 wide at least, round, 10 in, on the ink at 6% and the ink itself
/// while held, the hover's under the hand; its words or its mark 18, in the page's ink on the ink).
#derive(Eq, Debug)
pub(all) enum KeyLook {
  Tile
  Pill
}

///|
/// A key's mark across (18).
pub let key_mark_size : Double = 18.0

///|
/// How long a key that repeats is held before it presses again (a keyboard's delay), and then how often (its rate).
let key_repeat_after : Double = 400.0

///|
let key_repeat_every : Double = 45.0

///|
/// A key in `parent` showing `cap` (its words: Esc, Tab, ⌃) or, where `icon` names one, that mark; named `label` (read
/// out, a test finding it by it), `press` done as it is pressed. Looks as `look` says; a `Tile` `width` wide (none: its
/// share of the row) and `height` high, solid where `primary` (the key that sends). `held`: a modifier's, solid while
/// it is held, read out pressed (a toggle button). `steals_focus` false: pressed, the keyboard's focus stays where it
/// is (a terminal's keys over its soft keyboard). `repeat`: held, pressed again from 400 ms every 45 ms till let go (no
/// press as it is let go then). `felt`: the feel of a press as it goes down, and of each press repeated. The node.
#callsite(autofill(loc))
pub fn key_cap_node(
  parent : @view.View,
  cap : String,
  label : () -> String,
  press : () -> Unit,
  look? : KeyLook = Pill,
  icon? : String = "",
  width? : Double,
  height? : Double,
  primary? : Bool = false,
  held? : () -> Bool,
  steals_focus? : Bool = true,
  repeat? : Bool = false,
  felt? : @ui.Haptic,
  loc~ : SourceLoc,
) -> @view.View {
  let is_held = held.unwrap_or(fn() { false })
  let me : Ref[@view.View?] = Ref(None)
  // (held, pressed again and again till let go: from the moment it went down, a keyboard's delay, then its rate, as
  // long as it is held; its letting go then no press of its own: Hold's)
  let down_at = Ref(0.0)
  let repeat_stop : Ref[() -> Unit] = Ref(fn() {  })
  let stop = fn() {
    (repeat_stop.val)()
    repeat_stop.val = fn() {  }
  }
  let hold = if repeat {
    Some(
      @headless.Hold::new(
        @ui.touch_slop(),
        key_repeat_after,
        fn() { true },
        down=fn(d) {
          stop()
          down_at.val = d.at
        },
        on_hold=fn() {
          match me.val {
            Some(v) => {
              fn step(at_t : Double) -> Unit {
                repeat_stop.val = v.at_moment(
                  at_t,
                  fn() {
                    if v.pressed() {
                      if felt is Some(h) {
                        @ui.haptic(h)
                      }
                      press()
                      step(at_t + key_repeat_every)
                    }
                  },
                  later=true,
                )
              }
              if felt is Some(h) {
                @ui.haptic(h)
              }
              press()
              step(down_at.val + key_repeat_after + key_repeat_every)
            }
            None => ()
          }
        },
        on_lift=stop,
        on_cancel=stop,
      ),
    )
  } else {
    None
  }
  let drawn = fn(v : @view.View, pressed : () -> Bool) {
    me.val = Some(v)
    v.owns(stop) |> ignore
    if steals_focus {
      focus_ring_node(v)
    }
    key_cap_look(v, cap, icon, look, width, height, primary, is_held, pressed, loc~)
    if felt is Some(h) {
      v.reacts(fn() { v.pressed() }, fn(down) {
        if down {
          @ui.haptic(h)
        }
      }, at_start=false)
    }
  }
  match held {
    Some(on) =>
      @headless.toggle(made_for=loc, parent, Button, label, on, fn(_) { press() }, hold?, focusable=steals_focus, fn(
        v,
        t,
      ) {
        drawn(v, fn() { t.pressed() })
      })
    None =>
      @headless.button(made_for=loc, parent, label, fn(_) { press() }, hold?, focusable=steals_focus, fn(v, b) {
        drawn(v, fn() { b.pressed() })
      })
  }
}

///|
/// What a key `v` is drawn as (key_cap_node's): its ground, its size, its words or mark, as `look` has them.
fn key_cap_look(
  v : @view.View,
  cap : String,
  icon : String,
  look : KeyLook,
  width : Double?,
  height : Double?,
  primary : Bool,
  held : () -> Bool,
  pressed : () -> Bool,
  loc~ : SourceLoc,
) -> Unit {
  let solid = fn() { primary || held() }
  match look {
    Tile => {
      match width {
        Some(w) => v.width(Is(Some(w))) |> ignore
        None => v.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      }
      if height is Some(h) {
        v.height(Is(Some(h))) |> ignore
      }
      v
      .radius(Is(key_tile_r))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .ground(By(fn() {
        let p = theme().p
        let base = if solid() { p.primary } else { p.raised }
        if pressed() {
          over(base, p.hover)
        } else {
          base
        }
      }))
      |> ignore
      let ink = fn() {
        let p = theme().p
        if solid() {
          p.on_primary
        } else {
          p.text
        }
      }
      if icon != "" {
        icon_node(v, icon, key_mark_size, By(ink)) |> ignore
      } else {
        v.box(made_for=loc, fn(w) {
          w
          .words(Is(cap))
          .words_look(By(fn() { @ui.style_words(key_tile_words) }))
          .ink(By(ink))
          .allow_ellipsis(Is(true))
          |> ignore
        })
        |> ignore
      }
    }
    Pill => {
      style_node(v, fn() { key_pill }, in_row=true)
      v.ground(By(fn() { @ui.tree_theme().color(if held() { Fg } else { Tint }) })) |> ignore
      hover_ground_node(v)
      if icon != "" {
        icon_node(v, icon, key_mark_size, By(fn() { @ui.tree_theme().color(if held() { Bg } else { Fg }) })) |> ignore
      } else {
        words_node(v, fn() { cap }, fn() { if held() { key_pill_on_words } else { key_pill_words } }) |> ignore
      }
    }
  }
}

///|
/// How a round tool looks: `Plain` (40 round, the hover's ground under the hand and pressed, its mark 20 in the ink:
/// 退出全屏 over a terminal); `Floating` (44 round, a press's least, on the floating ground raised over a picture, the
/// hover's pressed: a mouse's button at a screen's foot).
#derive(Eq, Debug)
pub(all) enum ToolLook {
  Plain
  Floating
}

///|
/// A round tool in `parent` showing mark `icon` (20) in the ink, named `label` (read out, and its tip in `tips`),
/// `press` done as it is pressed; looks as `look` says. `felt`: the feel of a press as it goes down (a mouse's right
/// button's, a context click's). The node.
#callsite(autofill(loc))
pub fn tool_round_node(
  parent : @view.View,
  icon : String,
  label : () -> String,
  press : () -> Unit,
  look? : ToolLook = Plain,
  tips? : TipLayer,
  felt? : @ui.Haptic,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, label, fn(_) { press() }, fn(v, b) {
    focus_ring_node(v)
    match look {
      Plain => {
        style_node(v, fn() { tool_round }, in_row=true)
        hover_ground_node(v, lit=Some(fn() { b.hovered() || b.pressed() || b.focus_shown() }))
      }
      Floating => {
        style_node(v, fn() { tool_round_floating }, in_row=true)
        glass_capsule_node(
          v,
          min_height=Some(44.0),
          radius=Some(22.0),
          sharing=true,
          interactive=true,
          panel=true,
        )
        |> ignore
        hover_ground_node(v, lit=Some(fn() { b.pressed() }))
      }
    }
    icon_node(v, icon, tool_round_mark, By(fn() { @ui.tree_theme().color(Fg) })) |> ignore
    if felt is Some(h) {
      v.reacts(fn() { v.pressed() }, fn(down) {
        if down {
          @ui.haptic(h)
        }
      }, at_start=false)
    }
    match tips {
      Some(t) => tip_node(t, v, label) |> ignore
      None => ()
    }
  })
}

///|
/// A terminal's key's corner (10).
let key_tile_r : Double = 10.0

///|
// kept across runs: a value (no field of it changes)
let key_tile_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Fg, weight=Semibold, wrap=false)

///|
/// A screen's key: 36 high, 40 wide at least, round, 10 in, its words or mark in a row (never squeezed: a key short of
/// room leaves whole).
// kept across runs: a value (no field of it changes)
let key_pill : @ui.Style = @ui.css("row h=S9 min_w=S10 px=S2_5 radius=Full bg=Tint align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let key_pill_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L4_75, weight=Semibold, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let key_pill_on_words : @ui.TextStyle = key_pill_words.then(@ui.text_style(color=Bg))

///|
/// A round tool's mark across (20).
let tool_round_mark : Double = 20.0

///|
/// A round tool (40), its mark across its middle.
// kept across runs: a value (no field of it changes)
let tool_round : @ui.Style = @ui.css("w=S10 h=S10 radius=Full align=ACenter justify=JCenter")

///|
/// A round tool floating over a picture: 44 (a press's least), on single-layer liquid glass (the ink at 8% pressed).
// kept across runs: a value (no field of it changes)
let tool_round_floating : @ui.Style = @ui.css("w=S11 h=S11 radius=Full align=ACenter justify=JCenter")
