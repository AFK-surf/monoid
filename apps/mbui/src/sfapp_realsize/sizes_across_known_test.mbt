// What steps along a row in these tests (mbui's sizes_steady.mbt, `sizes_across`), a file at a time: how many a Tester
// made in it may show. Each only falls: a jump mended takes its file's number down, and a file at 0 leaves the list.

///|
fn init {
  @ui.sizes_across_known([
    ("src/sfapp_realsize/bar_places_kept_test.mbt", 1),
    ("src/sfapp_realsize/medium_switch_corners_test.mbt", 3),
  ])
}
