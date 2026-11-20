// What steps along a row in these tests (mbui's sizes_steady.mbt, `sizes_across`), a file at a time: how many a Tester
// made in it may show. Each only falls: a jump mended takes its file's number down, and a file at 0 leaves the list.

///|
fn init {
  @ui.sizes_across_known([
    ("src/sfapp_pages_test/about_test.mbt", 1),
    ("src/sfapp_pages_test/agent_tile_test.mbt", 1),
    ("src/sfapp_pages_test/files_favorite_controls_test.mbt", 2),
    ("src/sfapp_pages_test/files_favorite_motion_test.mbt", 1),
    ("src/sfapp_pages_test/files_places_test.mbt", 1),
    ("src/sfapp_pages_test/history_fixes_test.mbt", 1),
    ("src/sfapp_pages_test/model_pop_test.mbt", 6),
    ("src/sfapp_pages_test/service_link_test.mbt", 1),
    ("src/sfapp_pages_test/service_panels_test.mbt", 1),
    ("src/sfapp_pages_test/service_test.mbt", 1),
    ("src/sfapp_pages_test/station_add_test.mbt", 1),
    ("src/sfapp_pages_test/station_asks_test.mbt", 1),
    ("src/sfapp_pages_test/station_peek_test.mbt", 2),
    ("src/sfapp_pages_test/viewer_outer_test.mbt", 1),
    ("src/sfapp_pages_test/desk_service_test.mbt", 1),
  ])
}
