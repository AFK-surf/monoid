// The most bytes handed over for decodes (image_load_bytes) a Tester made in each file has its host hold at once
// (mbui's fake_host.mbt, host_image_bytes_known). Counted on CI's runs of every test at every rate; each only falls.

///|
fn init {
  @ui.host_image_bytes_known([
    ("src/sfapp_pages_test/downloads_test.mbt", 89156),
    // (a picture's preview, then the image itself put in its place as it is zoomed into: both decoding at once)
    ("src/sfapp_pages_test/viewer_preview_test.mbt", 1921076),
    ("src/sfapp_pages_test/screen_links_test.mbt", 128336),
    ("src/sfapp_pages_test/viewer_viz_test.mbt", 301154),
  ])
}
