// The files whose Testers still show faults of how what moves goes at 60 and 120 a second (mbui's tester.mbt,
// motion_counted). Only shrinks: a file mended to none leaves the list.

///|
fn init {
  @ui.motion_counted([
    "src/sfapp_pages_test/downloads_test.mbt",
    "src/sfapp_pages_test/service_link_test.mbt",
    "src/sfapp_pages_test/desk_service_test.mbt",
  ])
}
