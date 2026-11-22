// Drag state for the 文件 tab (drive_tab_node.mbt).

///|
/// The tab's drag (a row pressed with a mouse and moved past the slop carries it; let go off the tab, for the chat's
/// composer to take), where the pointer carries it in the window.
priv struct TabDrag {
  item : @signals.Signal[Dragged?]
  at : @signals.Signal[(Double, Double)]
}

///|
// kept across runs: put back by tab_drag_reset
let tdrag : TabDrag = { item: @signals.signal(None), at: @signals.signal((0.0, 0.0)) }

///|
fn tab_drag_reset() -> Unit {
  tdrag.item.set(None)
  tdrag.at.set((0.0, 0.0))
}

///|
/// What is carried now (a row of the tab dragged), for what it goes over to show it (a chat's composer).
pub fn dragged() -> Dragged? {
  tdrag.item.get()
}

///|
/// How far a press moves before it is a drag (a click's slop).
let tdrag_slop : Double = 4.0
