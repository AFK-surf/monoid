// The chat's page for a test that holds what the page does (its inside made as nodes, its composer too):
// newchat_send's, chat_send_from_above's, quote_flight's and chat_parity's, each a failure saying the page it ran on.

///|
/// `f` run on the chat's page; a failure says it ran on the page made as nodes.
fn both_pages(f : () -> Unit raise) -> Unit raise {
  try f() catch {
    Failure(e) => fail("[nodes] \{e}")
    e => fail("[nodes] \{e}")
  }
}

///|
/// What waits to go in the composer, of the viewer's id `seen`, as the frame just drawn has it (x, y, w, h, its top right
/// corner's radius): the end of the viewer's flight that stays (View::shared's `stays`: Tester::stays_of).
fn waiting_tile_at(t : @ui.Tester, seen : String) -> (Double, Double, Double, Double, Double)? {
  t.stays_of(seen).map(fn(d) { (d.0.0, d.0.1, d.0.2, d.0.3, d.1.1) })
}
