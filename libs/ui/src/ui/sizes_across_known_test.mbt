// What steps along a row in these tests (mbui's sizes_steady.mbt, `sizes_across`: a ground's left edge or width, where
// words start, in one frame, a speed off the frames round it, a dead stop, a turn back again soon), a file at a time: how
// many a Tester made in it may show, as they were found when the check came (2026-11-17), the most one Tester found at
// the default rate, at 60 and at 120 a second. Each only falls: a jump mended takes its file's number down, and a file
// at 0 leaves the list.

///|
fn init {
  @ui.sizes_across_known([
    ("src/ui/image_test.mbt", 1),
    ("src/ui/nav_test.mbt", 1),
  ])
}
