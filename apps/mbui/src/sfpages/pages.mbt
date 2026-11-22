// The pages, one for every tier and either input (Pages): each drawn in the box it is given,
// what it does read from the input, never the tier; what it opens asked of the shell.

///|
/// What the pages give sfbase as the app starts: a station's login card and the card to share, for the settings'
/// core (@sfbase.settings_core); and the library where a picture made in it goes (@sf.picture_out_by, @sf.picture_out_now_by: a table's).
/// Said once (reset runs only as a Tester starts).
fn init {
  @sfbase.share_card_of.val = share_card_open
  @sfbase.screen_made_stream.val = screen_fixture_stream
  @sf.picture_out_now_by.val = fn(png, said) { picture_out_now(png, copy_said=said) }
}

///|
/// What this package keeps put back as the app begins anew (its reset).
pub fn reset() -> Unit {
  // (the files' pages: what they browse, keep, drag, preview and ask: files_browse.mbt)
  files_reset()
  station_pick_reset()
  screen_fix_mode.val = ""
  screen_fix_by_screen.val = false
  screen_fix_heard.val = None
  screens_open.clear()
  screen_uis.clear()
  center_wait_give_up()
  screens_made.val = 0
  hover_reset()
  hovered_file.val = None
  message_reset()
  rows_reset()
  login_cards_reset()
  chat_reads.clear()
  relay_focus_reset()
  publish_reset()
  xsharing_reset()
  list_reset()
  menus_reset()
  things_reset()
  steps_reset()
  composing_reset()
  triple_reset()
  recent_reset()
  chat_rows_reset()
  sidebar_reset()
  finder_reset()
  search_reset()
  settings_search_reset()
  marks_reset()
  news_reset()
  landing_reset()
  workspace_reset()
  rigs_reset()
  outside_reset()
  feedback_reset()
  decision_reply_reset()
  new_chat_reset()
  sent_in_field_reset()
  changelog_reset()
  share_looks_reset()
  font_setting_reset()
  notify_page_reset()
  usage_reset()
  desk_dialogs.val = 0
  vault_reset()
  vault_item_reset()
  mine_filter_open.clear()
  connect_reset()
  new_connect_reset()
  station_cards_reset()
  station_page_reset()
  profile_page_reset()
  profiles_overview_reset()
  share_mask_all.set(false)
  add_profile_start.clear()
  local_menu.val = false
  memory_doc_reset()
  signin_reset()
  own_picture_reset()
  fx_policy_up.val = ""
  fx_vault_add_up.val = false
}
