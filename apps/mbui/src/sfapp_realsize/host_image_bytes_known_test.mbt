// The most bytes handed over for decodes (image_load_bytes) a Tester made in each file has its host hold at once
// (mbui's fake_host.mbt, host_image_bytes_known). Counted on CI's runs of every test at every rate; each only falls.

///|
fn init {
  @ui.host_image_bytes_known([
    // (大屏 rail 停驻实测：真实尺寸工作区打开首条对话页的头像解码量，与 medium_switch_corners_test / real_size_new_chat_send_test 一致)
    ("src/sfapp_realsize/bar_places_kept_test.mbt", 38548),
    // (a chat of real size opened as nodes: the pictures of the rows round what shows, as chat_page_nodes_wbtest's)
    ("src/sfapp_realsize/chat_nodes_open_budget_test.mbt", 40824),
    // (the same chat opened again on each page, old and as nodes: the pictures of the rows round what shows, 2026-11-16)
    // (中屏's chat opened, its workspace switched: the chat's pictures handed over as it showed, 2026-11-14)
    ("src/sfapp_realsize/medium_switch_corners_test.mbt", 38548),
    // (a new chat sent on a workspace of real size, its people's pictures on the chats' list: Studio's run, 2026-11-15)
    ("src/sfapp_realsize/real_size_new_chat_send_test.mbt", 38548),
    // (the real size's screens, made under its own file since their motion is not judged (sfapptest's screen_in):
    // what Studio's run of both windows held at most, 2026-11-16, the wide window's)
    ("src/sfapp_realsize/real_size_test.mbt", 1975151),
    // Wide/medium rail switch budget gates on the real-size workspace (same chat avatar decode ceiling as bar_places_kept_test).
    ("src/sfapp_realsize/wide_switch_budget_test.mbt", 38548),
    // Wide/medium full Place cold-open 5-dim budget gates on the real-size workspace (covers settings subpages too).
    ("src/sfapp_realsize/wide_cold_open_budget_test.mbt", 46949),
  ])
}
