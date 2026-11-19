// The files whose Testers still show faults of how what moves goes at 60 and 120 a second (mbui's tester.mbt,
// motion_counted: what CI's runs count, `scripts/motion_said.sh`): only counted there; every other file is judged, a
// fault failing its test. Only shrinks: a file mended to none leaves the list.

///|
fn init {
  @ui.motion_counted([
    "src/sfapp/activity_wbtest.mbt",
    "src/sfapp/cards_wbtest.mbt",
    "src/sfapp/chat_keys_wbtest.mbt",
    "src/sfapp/chat_wbtest.mbt",
    "src/sfapp/composer_parts_wbtest.mbt",
    "src/sfapp/composer_wbtest.mbt",
    "src/sfapp/duo_wbtest.mbt",
    "src/sfapp/emit_kept_wbtest.mbt",
    "src/sfapp/emit_wbtest.mbt",
    "src/sfapp/kept_rows_kinds_wbtest.mbt",
    "src/sfapp/menu_node_wbtest.mbt",
    "src/sfapp/motion_wbtest.mbt",
    "src/sfapp/preview_wbtest.mbt",
    "src/sfapp/quote_image_wbtest.mbt",
    "src/sfapp/settings_wbtest.mbt",
    "src/sfapp/stack_over_wbtest.mbt",
    "src/sfapp/stations_now_wbtest.mbt",
    "src/sfapp/tape_moment_wbtest.mbt",
    "src/sfapp/tape_wbtest.mbt",
    "src/sfapp/wide_wbtest.mbt",
  ])
}
