// What is presented is each window's own (mbui's window_kept): a menu, a panel or a dialog opened in a window of the
// run beside the first (a station's screen in a window of its own) is presented there alone, over that window's page,
// never in the first window, nor the other way.

///|
fn init {
  @ui.window_kept_array(presented_now)
  @ui.window_kept_ref(presented_said, presented_said_new)
  @ui.window_kept_map(presented_items_said)
  @ui.window_kept_map(took_place)
  @ui.window_kept_ref(presented_drawn_said, fn() { @signals.keyed() })
  @ui.window_kept_ref(presented_alone, fn() { false })
  @ui.window_kept_array(presented_how)
  @ui.window_kept_ref(presented_sheets, fn() { false })
  @ui.window_kept_ref(presented_win_h, fn() { 0.0 })
  @ui.window_kept_ref(presented_held, fn() { false })
  @ui.window_kept_set(tree_presented)
  @ui.window_kept_map(tree_as_sheet)
  @ui.window_kept_ref(window_tips_at, fn() { None })
  @ui.window_kept_ref(transient_seq, fn() { 0 })
  @ui.window_kept_ref(transient_active, fn() { None })
  @ui.window_kept_ref(transient_tip_active, fn() { None })
  @ui.window_kept_ref(window_hover_at, fn() { None })
  @ui.window_kept_ref(window_hover_root, fn() { None })
  @ui.window_kept_ref(tree_sheet_place, fn() { None })
  @ui.window_kept_map(sheet_foot_covers)
  @ui.window_kept_ref(sheet_foot_next, fn() { 0 })
  @ui.window_kept_ref(sheet_foot_ver, sheet_foot_ver_new)
}
