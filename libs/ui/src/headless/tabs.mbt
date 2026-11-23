// Tabs: a tab list and the panel of each tab, one tab chosen at a time and its panel the one shown. The tab list
// (`Tabs::list`) and its tabs (`RadioGroup::item`) are a radio group of the `Tab` kind (radio_group.mbt: a `TabList`
// of `Tab`s read out selected or not, the roving Tab stop on the chosen one, the arrow keys along `axis`, Home and End, each
// choosing what it comes to unless `manual`, where Space or Enter chooses). Each panel (`Tabs::panel`) is read out a
// `TabPanel` called by its label while its tab is chosen, and only then: what it holds made in it while its tab is
// chosen and let go as another is, or, `keep_mounted`, made once and kept while another is chosen, hidden from what
// reads the screen and taking no press and no focus then (so what it holds keeps its state, as a parked page does).
//
// Controlled (headless.mbt, State): which tab is chosen is its caller's (`chosen`), told the key chosen by a press or a
// key (`choose`).

///|
/// Tabs made once by their caller, its list and panels made by it (`Tabs::list`, `Tabs::panel`).
pub struct Tabs[K] {
  priv chosen : () -> K
  priv choose : (K) -> Unit
  priv manual : Bool
  priv axis : GroupAxis
  priv off : () -> Bool
}

///|
/// Tabs whose chosen tab is `chosen`'s, `choose` told the key chosen; `manual`: the keys move the focus alone, Space
/// or Enter choosing; `axis` which arrow keys go along its list; `disabled` while none of its tabs takes a press.
pub fn[K] Tabs::new(
  chosen : () -> K,
  choose : (K) -> Unit,
  manual? : Bool = false,
  axis? : GroupAxis = Horizontal,
  disabled? : () -> Bool = fn() { false },
) -> Tabs[K] {
  { chosen, choose, manual, axis, off: disabled }
}

///|
/// The key of the tab chosen now (as its caller says).
pub fn[K] Tabs::chosen(self : Tabs[K]) -> K {
  (self.chosen)()
}

///|
/// Its tab list in `parent`, called `label`: `look` is given its node and its group, its tabs made in it by
/// `RadioGroup::item` (directly or inside `View::each`; a tab that closes by its `on_close`). Its node.
#callsite(autofill(loc))
pub fn[K : Eq] Tabs::list(
  self : Tabs[K],
  parent : @view.View,
  label : () -> String,
  look : (@view.View, RadioGroup[K]) -> Unit,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  radio_group(
    parent,
    label,
    self.chosen,
    self.choose,
    look,
    kind=Tab,
    axis=self.axis,
    disabled=self.off,
    manual=self.manual,
    made_for=made_for.unwrap_or(loc),
    loc~,
  )
}

///|
/// A tab's panel as its look reads it: each a reading, followed where a binding reads it.
pub struct TabPanel {
  priv on : () -> Bool
}

///|
/// Whether its tab is the one chosen now: the panel shown.
pub fn TabPanel::selected(self : TabPanel) -> Bool {
  (self.on)()
}

///|
/// The panel of the tab of `key` in `parent`, read out a `TabPanel` called `label` while its tab is chosen. `look` is
/// run once as it is made, given its node and what it reads of it: all that is drawn of it and how it is laid out (none
/// of it while its tab is not chosen, where it is kept). `content` makes what it holds in it: while its tab is chosen,
/// or once and kept (`keep_mounted`), hidden and taking no input while another is. Its node.
#callsite(autofill(loc))
pub fn[K : Eq] Tabs::panel(
  self : Tabs[K],
  parent : @view.View,
  key : K,
  label : () -> String,
  look : (@view.View, TabPanel) -> Unit,
  content : (@view.View) -> Unit,
  keep_mounted? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    let on = fn() { (self.chosen)() == key }
    look(v, { on, })
    v
    .says(By(fn() { if on() { Some(@view.said(TabPanel, label=label(), selected=true)) } else { None } }))
    .hides(By(fn() { !on() }))
    .presses(By(on))
    |> ignore
    if keep_mounted {
      content(v)
    } else {
      v.show(on, at_once=true, content)
    }
  })
}
