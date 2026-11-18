// The most bytes handed over for decodes (image_load_bytes) a Tester made in each file has its host hold at once
// (mbui's fake_host.mbt, host_image_bytes_known): a phone's Java side kept a GIF's every frame's, 140 MB of a 256 MB
// heap, and the app was killed (#5301). Counted on CI's runs of every test at every rate, 2026-11-11; each only falls:
// a change that hands over less brings its file's number down, and a file at 4096 or less leaves the list.

///|
fn init {
  @ui.host_image_bytes_known([
    // (every screen walked over a core answering late, a chat's pictures opened and stepped: what CI's runs held at
    // most)
    ("src/sfapp/answers_still_wbtest.mbt", 262430),
    // (every screen's switches pressed over a core answering late, its pictures among them: what Studio's run held at
    // most, 2026-11-14)
    ("src/sfapp/switches_still_wbtest.mbt", 2906925),
    // (chats switched on 中屏 and 大屏, the first one read up from its end to its pictures: what Studio's runs held at most
    // at every rate, 2026-11-16)
    ("src/sfapp/switch_still_wbtest.mbt", 127704),
    ("src/sfapp/chat_bar_wide_wbtest.mbt", 89156),
    ("src/sfapp/chat_drive_parity_wbtest.mbt", 300978),
    ("src/sfapp/chat_images_told_wbtest.mbt", 57845),
    ("src/sfapp/chat_keys_wbtest.mbt", 127704),
    ("src/sfapp/chat_motion_desk_wbtest.mbt", 462064),
    // (the chat's page made as nodes hands over the pictures of the rows its list has made round what shows, a screen
    // over and under it, where the old list handed over those in view: its 小屏 finger's pick held at its end, 2026-11-13)
    ("src/sfapp/chat_page_nodes_wbtest.mbt", 38548),
    ("src/sfapp/chat_pictures_held_wbtest.mbt", 89156),
    ("src/sfapp/chat_send_from_above_wbtest.mbt", 89156),
    // (the chat's page made as nodes, its words and a quoted picture sent: the pictures of the rows round what shows,
    // as chat_page_nodes_wbtest's, and the quote's, 2026-11-14; the quote's picture flying from its 56 tile to its
    // place in the row since 2026-11-16, as the old page's does, is decoded on its way at 512 as well as at 128, 256 and
    // its own 1024: one more of the same 38548 bytes)
    ("src/sfapp/chat_sent_seen_wbtest.mbt", 154192),
    ("src/sfapp/chat_wbtest.mbt", 960538),
    ("src/sfapp/composer_under_sheet_wbtest.mbt", 159102),
    ("src/sfapp/composer_wbtest.mbt", 231032),
    ("src/sfapp/core_pace_rows_wbtest.mbt", 89156),
    ("src/sfapp/core_pace_wbtest.mbt", 89156),
    ("src/sfapp/covered_focus_wbtest.mbt", 192504),
    ("src/sfapp/daily_paths_wbtest.mbt", 89156),
    ("src/sfapp/decide_wbtest.mbt", 159102),
    ("src/sfapp/downloads_wbtest.mbt", 89156),
    // (every screen on an iPhone Duo's two screens on its side: what Studio's run held at most, a chat's pictures
    // swiped, 2026-11-17)
    ("src/sfapp/duo_side_wbtest.mbt", 2831020),
    ("src/sfapp/duo_wbtest.mbt", 960538),
    ("src/sfapp/emit_wbtest.mbt", 89156),
    ("src/sfapp/fast_down_wbtest.mbt", 57758),
    ("src/sfapp/flight_under_bar_wbtest.mbt", 519822),
    ("src/sfapp/image_corners_chat_wbtest.mbt", 159102),
    ("src/sfapp/kept_rows_kinds_wbtest.mbt", 243220),
    ("src/sfapp/linger_wbtest.mbt", 89156),
    // (中屏's chat opened, its workspace switched: the chat's pictures handed over as it showed, 2026-11-14)
    ("src/sfapp/medium_switch_corners_wbtest.mbt", 38548),
    ("src/sfapp/newchat_send_wbtest.mbt", 231032),
    // (a new chat sent on a workspace of real size, its people's pictures on the chats' list: Studio's run, 2026-11-15)
    ("src/sfapp/real_size_new_chat_send_wbtest.mbt", 38548),
    // (a chat of real size opened as nodes: the pictures of the rows round what shows, as chat_page_nodes_wbtest's)
    ("src/sfapp/chat_nodes_open_budget_wbtest.mbt", 40824),
    // (the same chat opened again on each page, old and as nodes: the pictures of the rows round what shows, 2026-11-16)
    ("src/sfapp/chat_nodes_vs_old_wbtest.mbt", 38548),
    ("src/sfapp/notices_wbtest.mbt", 999086),
    ("src/sfapp/place_first_wbtest.mbt", 10862),
    ("src/sfapp/preview_tree_wbtest.mbt", 1934327),
    ("src/sfapp/preview_wbtest.mbt", 2894865),
    // (a picture's preview, then the image itself put in its place as it is zoomed into: both decoding at once)
    ("src/sfapp/viewer_preview_wbtest.mbt", 1921076),
    ("src/sfapp/publish_wbtest.mbt", 96306),
    ("src/sfapp/quote_flight_wbtest.mbt", 115644),
    ("src/sfapp/quote_image_wbtest.mbt", 320444),
    ("src/sfapp/screen_links_wbtest.mbt", 128336),
    // (the real size's screens, made under its own file since their motion is not judged (squeeze_wbtest.mbt's
    // screen_in): what Studio's run of both windows held at most, 2026-11-16, the wide window's; held till then under
    // squeeze_wbtest.mbt's bar, which was theirs)
    ("src/sfapp/real_size_wbtest.mbt", 1975151),
    ("src/sfapp/screens_wbtest.mbt", 1857231),
    ("src/sfapp/search_wbtest.mbt", 127704),
    ("src/sfapp/send_hold_wbtest.mbt", 89156),
    ("src/sfapp/squeeze_wbtest.mbt", 1975151),
    ("src/sfapp/tape_wbtest.mbt", 89156),
    ("src/sfapp/things_sheet_wbtest.mbt", 159102),
    ("src/sfapp/touch_wide_wbtest.mbt", 204672),
    ("src/sfapp/view_beside_wbtest.mbt", 2970770),
    ("src/sfapp/viewer_flight_wbtest.mbt", 146914),
    ("src/sfapp/viewer_media_wbtest.mbt", 115516),
    ("src/sfapp/viewer_pick_wbtest.mbt", 243220),
    ("src/sfapp/viewer_viz_wbtest.mbt", 301154),
    ("src/sfapp/viewers_desk_wbtest.mbt", 1895779),
    ("src/sfapp/wide_back_wbtest.mbt", 89156),
    ("src/sfapp/wide_panel_wbtest.mbt", 89156),
    ("src/sfapp/wide_publish_wbtest.mbt", 127704),
    ("src/sfapp/wide_wbtest.mbt", 146914),
    ("src/sfapp/window_zoom_wbtest.mbt", 38548),
  ])
}
