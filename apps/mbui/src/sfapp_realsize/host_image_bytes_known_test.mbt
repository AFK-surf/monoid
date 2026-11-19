// The most bytes handed over for decodes (image_load_bytes) a Tester made in each file has its host hold at once
// (mbui's fake_host.mbt, host_image_bytes_known). Counted on CI's runs of every test at every rate; each only falls.

///|
fn init {
  @ui.host_image_bytes_known([
    // (a chat of real size opened as nodes: the pictures of the rows round what shows, as chat_page_nodes_wbtest's)
    ("src/sfapp_realsize/chat_nodes_open_budget_test.mbt", 40824),
    // (the same chat opened again on each page, old and as nodes: the pictures of the rows round what shows, 2026-11-16)
    ("src/sfapp_realsize/chat_nodes_vs_old_test.mbt", 38548),
    // (中屏's chat opened, its workspace switched: the chat's pictures handed over as it showed, 2026-11-14)
    ("src/sfapp_realsize/medium_switch_corners_test.mbt", 38548),
    // (a new chat sent on a workspace of real size, its people's pictures on the chats' list: Studio's run, 2026-11-15)
    ("src/sfapp_realsize/real_size_new_chat_send_test.mbt", 38548),
    // (the real size's screens, made under its own file since their motion is not judged (sfapptest's screen_in):
    // what Studio's run of both windows held at most, 2026-11-16, the wide window's)
    ("src/sfapp_realsize/real_size_test.mbt", 1975151),
  ])
}
