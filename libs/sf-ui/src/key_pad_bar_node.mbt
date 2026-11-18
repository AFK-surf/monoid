// A keyboard's bar of keys (软键盘辅助键栏) as nodes of the window's tree, made once: what a terminal's keys over its
// soft keyboard and a screen's keys row are made of. The modifiers held for the next key (KeyPadMods: pressed once
// for the next key alone, again locked, a third time let go), a key of the bar that leaves the keyboard's focus where
// it is and is felt as it goes down (key_pad_key_node), the arrows and ⌫ round a tall ⏎, each going on as it is held
// (key_pad_dpad_node), and a row of keys as wide as it is given whose least used leave it for a ⋯ that turns the row
// to them, as a keyboard turns to its other keys (key_pad_row_node). Each key is key_cap_node's.

///|
/// The modifiers a keyboard's bar holds for the next key, each by its bit: pressed once, held for the next key alone;
/// pressed again while so, locked till it is pressed a third time; then let go.
pub struct KeyPadMods {
  priv once : @signals.Signal[Int]
  priv locked : @signals.Signal[Int]
}

///|
/// None held.
pub fn KeyPadMods::new() -> KeyPadMods {
  { once: @signals.signal(0), locked: @signals.signal(0) }
}

///|
/// Modifier `bit` pressed: let go where it is locked, locked where it is held for the next key, else held for it.
pub fn KeyPadMods::press(self : KeyPadMods, bit : Int) -> Unit {
  let locked = self.locked.untracked()
  let once = self.once.untracked()
  if (locked & bit) != 0 {
    self.locked.set(locked & bit.lnot())
  } else if (once & bit) != 0 {
    self.once.set(once & bit.lnot())
    self.locked.set(locked | bit)
  } else {
    self.once.set(once | bit)
  }
}

///|
/// Whether modifier `bit` is held now, for the next key or locked (followed where a binding reads it).
pub fn KeyPadMods::holds(self : KeyPadMods, bit : Int) -> Bool {
  ((self.once.get() | self.locked.get()) & bit) != 0
}

///|
/// What is held now, for the next key and locked, read once (not followed).
pub fn KeyPadMods::held_now(self : KeyPadMods) -> Int {
  self.once.untracked() | self.locked.untracked()
}

///|
/// What is held for a key going down now (KeyPadMods::held_now's), those held for the next key alone let go after it.
pub fn KeyPadMods::consume_once(self : KeyPadMods) -> Int {
  let held = self.held_now()
  self.once.set(0)
  held
}

///|
/// A key of a keyboard's bar in `parent` (key_cap_node's `Tile`): `cap` (its words: Esc, Tab, ⌃) or the mark `icon`
/// names, named `label`, `press` done as it is pressed; `width` wide (none: its share of the row), `height` high, solid
/// where `primary` (the key that sends), and while `held` says (a modifier held, read out pressed). Pressed, the
/// keyboard's focus stays on what is typed in, never taken by the key; felt as it goes down; `repeat`, it goes on
/// pressing as it is held (the arrows, ⌫). The node.
#callsite(autofill(loc))
pub fn key_pad_key_node(
  parent : @view.View,
  cap : String,
  label : String,
  press : () -> Unit,
  width? : Double,
  height~ : Double,
  primary? : Bool = false,
  held? : () -> Bool,
  icon? : String = "",
  repeat? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  pad_key_node(parent, cap, fn() { label }, press, width?, height~, primary~, held?, icon~, repeat~, loc~)
}

///|
/// key_pad_key_node's key, its name `label` read as it is drawn (the app's words as they are now, a language changed
/// followed).
#callsite(autofill(loc))
fn pad_key_node(
  parent : @view.View,
  cap : String,
  label : () -> String,
  press : () -> Unit,
  width? : Double,
  height~ : Double,
  primary~ : Bool,
  held? : () -> Bool,
  icon~ : String,
  repeat~ : Bool,
  loc~ : SourceLoc,
) -> @view.View {
  key_cap_node(
    loc~,
    parent,
    cap,
    label,
    press,
    look=Tile,
    icon~,
    width?,
    height~,
    primary~,
    held?,
    steals_focus=false,
    repeat~,
    felt=KeyboardTap,
  )
}

///|
/// The arrows and ⌫ round a tall ⏎ in `parent`, as a keyboard's inverted T: ↑ and ⌫ over ← ↓ →, each `key_w` by
/// `key_h` and 4 apart, ⏎ `enter_w` by `enter_h` beside them 6 apart (the key that sends, solid). Each tells `tap` the
/// key it is (its DOM key: ArrowUp, Backspace, Enter); the arrows and ⌫ go on as they are held. The node.
#callsite(autofill(loc))
pub fn key_pad_dpad_node(
  parent : @view.View,
  key_w : Double,
  key_h : Double,
  enter_w : Double,
  enter_h : Double,
  tap : (String) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  // (each named by the app's words as they are drawn, never read as the node is made)
  let arrow = fn(row : @view.View, cap : String, label : String, key : String) {
    pad_key_node(row, cap, fn() { t(label) }, fn() { tap(key) }, width=key_w, height=key_h, primary=false, icon="", repeat=true)
    |> ignore
  }
  parent.box(made_for=loc, fn(cl) {
    cl.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(6.0)) |> ignore
    cl.box(fn(arrows) {
      arrows.gap(Is(4.0)) |> ignore
      arrows.box(fn(top_r) {
        top_r.row(Is(true)).gap(Is(4.0)) |> ignore
        top_r.box(fn(sp) { sp.width(Is(Some(key_w))).height(Is(Some(key_h))) |> ignore }) |> ignore
        arrow(top_r, "↑", "android-misc.screen.key.up", "ArrowUp")
        arrow(top_r, "⌫", "web-pages.terminal.backspace", "Backspace")
      })
      |> ignore
      arrows.box(fn(bot_r) {
        bot_r.row(Is(true)).gap(Is(4.0)) |> ignore
        arrow(bot_r, "←", "android-misc.screen.key.left", "ArrowLeft")
        arrow(bot_r, "↓", "android-misc.screen.key.down", "ArrowDown")
        arrow(bot_r, "→", "android-misc.screen.key.right", "ArrowRight")
      })
      |> ignore
    })
    |> ignore
    pad_key_node(cl, "⏎", fn() { t("web-pages.terminal.sendCmd") }, fn() { tap("Enter") }, width=enter_w, height=enter_h, primary=true, icon="", repeat=false)
    |> ignore
  })
}

///|
/// A key of key_pad_row_node's row: `cap` (its words) or the mark `icon` names, named `name` (also its key in the row:
/// one name a key); `drop`, where the row has not the room for every key, the k-th to leave it for its ⋯ (0: never);
/// `held`, a modifier's, solid while it is held, read out pressed, and never leaving the row then; `felt`, the feel of
/// a press as it goes down (a mouse's button); `press` done as it is pressed.
pub(all) struct KeyPadKey {
  cap : String
  name : String
  icon : String
  drop : Int
  held : (() -> Bool)?
  felt : @ui.Haptic?
  press : () -> Unit
}

///|
/// Keys `keys` in a row in `parent` (key_cap_node's `Pill`s, laid out as `look` says), as wide as it is given: where
/// it has not the room for them all, the least used leave it (KeyPadKey's `drop`; a modifier held never), and a ⋯ key
/// at its end turns the row to them, as a keyboard turns to its other keys (lit while turned; pressed again, on to those
/// that had not the room there either, or back): nothing scrolled, nothing wrapped. `turned`: the names of the keys
/// the row is turned to, none on its first face (kept by its caller, the row as it was left as it is made again).
/// The node.
#callsite(autofill(loc))
pub fn key_pad_row_node(
  parent : @view.View,
  keys : Array[KeyPadKey],
  turned : @signals.Signal[Array[String]],
  look? : () -> @ui.Style = fn() { key_pad_row_look },
  loc~ : SourceLoc,
) -> @view.View {
  let held = fn(k : KeyPadKey) {
    match k.held {
      Some(h) => h()
      None => false
    }
  }
  let leaves = fn(k : KeyPadKey) { if held(k) { 0 } else { k.drop } }
  let on_face = fn(k : KeyPadKey) {
    let now = turned.get()
    now.is_empty() || now.contains(k.name)
  }
  let slots : Map[String, @view.View] = Map([])
  parent.box(made_for=loc, fn(row) {
    style_node(row, look, in_row=true)
    // (as wide as it is given, what has not the room there left out: View::drops)
    row.fits(Is(true)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    for k in keys {
      row.show(at_once=true, fn() { on_face(k) }, fn(slot) {
        slots[k.name] = slot
        slot.drops(By(fn() { leaves(k) })) |> ignore
        key_cap_node(slot, k.cap, fn() { k.name }, k.press, icon=k.icon, held?=k.held, felt?=k.felt) |> ignore
      })
    }
    // (the ⋯: on the first face there only while a key is out; turned, always, the way on or back)
    row.box(fn(more) {
      let is_turned = fn() { !turned.get().is_empty() }
      more.drops(By(fn() { if is_turned() { 0 } else { -1 } })) |> ignore
      key_cap_node(more, "", fn() { t("common.more") }, icon="more", held=is_turned, fn() {
        // (turned to those this face left out as last laid out: from the first face its others, and from them, where
        // they too have not the room, the rest; none left out, back)
        turned.set(
          keys
          .filter(fn(k) {
            let face = @signals.untracked(fn() { on_face(k) })
            face && leaves(k) > 0 && slots.get(k.name).map(fn(v) { v.alive() && v.left_out() }).unwrap_or(false)
          })
          .map(fn(k) { k.name }),
        )
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// key_pad_row_node's row where its caller says no other: its keys 4 apart, in the middle of its height.
// kept across runs: a value (no field of it changes)
let key_pad_row_look : @ui.Style = @ui.css("row gap=S1 align=ACenter")
