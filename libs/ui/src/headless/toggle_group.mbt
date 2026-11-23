// The toggle group: a row (or a column) of toggle buttons, each on or off (a text's bold, italic and underline: `Multiple`)
// or at most one on at a time (its alignment: `Single`). The group is read out a `Group` called by its label; each item
// (`ToggleGroup::item`) is a toggle button (toggle.mbt, `ToggleKind::Button`: read out a button pressed while it is on,
// pressed by the pointer, Enter or Space, a screen reader's Activate), telling its caller what it is to be.
//
// Which are on is its caller's (`is_on`), told the key of an item and what it is to be (`turn`): `Single`, where an
// item is turned on, the caller turns the one on before it off (a press on the one on turns it off: none on then);
// `Multiple`, each its own.
//
// Keys (Radix's toggle group): Tab stops on one of its items (roving: the last that had the focus while it is still
// enabled, else the first on, else the first enabled), and while one has the focus the arrow keys along `axis` go to the
// enabled item before and after, around the ends unless `wraps` is false, Home and End to the first and the last, each
// showing the focus there and turning nothing; a disabled item is passed by.

///|
/// Whether at most one item of a toggle group is on at a time (`Single`) or each is its own (`Multiple`).
#derive(Eq, Debug)
pub(all) enum ToggleGroupKind {
  Single
  Multiple
}

///|
/// A toggle group handed to its look to make its items by (`ToggleGroup::item`).
pub struct ToggleGroup[K] {
  priv kind : ToggleGroupKind
  priv is_on : (K) -> Bool
  priv turn : (K, Bool) -> Unit
  priv off : () -> Bool
  priv items : RovingFocus
}

///|
/// Whether the whole group is disabled (as its caller says).
pub fn[K] ToggleGroup::disabled(self : ToggleGroup[K]) -> Bool {
  (self.off)()
}

///|
/// Whether at most one of its items is on at a time.
pub fn[K] ToggleGroup::single(self : ToggleGroup[K]) -> Bool {
  self.kind is Single
}

///|
/// A toggle group in `parent`, called `label`, its items on as `is_on` says, `turn` told the key of one pressed and what
/// it is to be; `kind` at most one on or each its own; `axis` which arrow keys go along it; `wraps`: the keys go round
/// its ends; `rtl`: flip horizontal arrow keys (`←`/`→`); `disabled` while none of it takes a press or the focus.
/// `look` is given its node and the `ToggleGroup[K]` its items are made by (directly or inside `View::each`), once as
/// it is made: all that is drawn of it and how it is laid out. Its node.
#callsite(autofill(loc))
pub fn[K] toggle_group(
  parent : @view.View,
  label : () -> String,
  is_on : (K) -> Bool,
  turn : (K, Bool) -> Unit,
  look : (@view.View, ToggleGroup[K]) -> Unit,
  kind? : ToggleGroupKind = Multiple,
  axis? : GroupAxis = Horizontal,
  wraps? : Bool = true,
  rtl? : Bool = false,
  disabled? : () -> Bool = fn() { false },
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let items = RovingFocus::new(axis~, roving=true, wraps~, rtl~)
  let g : ToggleGroup[K] = { kind, is_on, turn, off: disabled, items }
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    look(v, g)
    v
    .says(By(fn() { Some(@view.said(Group, label=label())) }))
    .on_key(fn(k) {
      if k.mods != 0 || disabled() {
        return false
      }
      items.step(k.code) is Some(_)
    })
    |> ignore
  })
}

///|
/// An item of `key` in `parent` (the group's node or a part of it), called `label`: a toggle button (toggle.mbt), on
/// while `is_on` says so of its key, pressed `turn` told the other; `disabled` while it alone takes no press and no
/// focus. `look` as the toggle's. Its node.
#callsite(autofill(loc))
pub fn[K] ToggleGroup::item(
  self : ToggleGroup[K],
  parent : @view.View,
  key : K,
  label : () -> String,
  look : (@view.View, Toggle) -> Unit,
  disabled? : () -> Bool = fn() { false },
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let off = fn() { (self.off)() || disabled() }
  let on = fn() { (self.is_on)(key) }
  let v = toggle(
    parent,
    Button,
    label,
    on,
    fn(to) { (self.turn)(key, to) },
    look,
    disabled=off,
    made_for=made_for.unwrap_or(loc),
    loc~,
  )
  // (its Tab stop the group's, said after the toggle's focusable)
  self.items.add(v, disabled=off, preferred=on)
  v
}
