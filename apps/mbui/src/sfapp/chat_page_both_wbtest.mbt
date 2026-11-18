// The chat's page both ways (sfbase's chat_page_nodes: its old view, and its inside made as nodes, its composer too:
// sfbase's composer_nodes), for a test that
// holds what the page does whichever way it is made: newchat_send's, chat_send_from_above's, quote_flight's and
// chat_parity's run once each way, each Tester made with the page as `both_nodes` says.

///|
/// Which way the chat's page is made by a Tester a both_pages test makes now (set just before it is made).
// kept across runs: said by both_pages for each run of its test, false once it is done
let both_nodes : Ref[Bool] = Ref(false)

///|
/// `f` run with the chat's page made each way: its old view, then its inside as nodes; a failure says which. One way
/// left out says why (`old_only`, `nodes_only`): what the test reads is that way's alone (its flight, its list), or the
/// other way differs as decided (the lead's, 2026-11-16).
fn both_pages(f : () -> Unit raise, old_only? : String = "", nodes_only? : String = "") -> Unit raise {
  let ways = if old_only != "" { [false] } else if nodes_only != "" { [true] } else { [false, true] }
  for nodes in ways {
    both_nodes.val = nodes
    try f() catch {
      Failure(e) => {
        both_nodes.val = false
        fail("[\{if nodes { "nodes" } else { "old" }}] \{e}")
      }
      e => {
        both_nodes.val = false
        fail("[\{if nodes { "nodes" } else { "old" }}] \{e}")
      }
    }
  }
  both_nodes.val = false
}

///|
/// What waits to go in the composer, of the viewer's id `seen`, as the frame just drawn has it (x, y, w, h, its top right
/// corner's radius): the old composer's tile where it noted it (thumb_of), the one made as nodes the end of the viewer's
/// flight that stays (View::shared's `stays`: Tester::stays_of), as both_pages runs now.
fn waiting_tile_at(t : @ui.Tester, seen : String) -> (Double, Double, Double, Double, Double)? {
  if both_nodes.val {
    t.stays_of(seen).map(fn(d) { (d.0.0, d.0.1, d.0.2, d.0.3, d.1.1) })
  } else {
    thumb_of(t.ctx(), seen).map(fn(tile) {
      let (_, corner, _, _) = tile.corners.each()
      (tile.x, tile.y, tile.w, tile.h, corner)
    })
  }
}

///|
/// The chat's page made the way both_pages runs now, said as a Tester is about to be made (after its run's reset).
fn both_way() -> Unit {
  @sfbase.chat_page_nodes.set(both_nodes.val)
  // (its composer too, as nodes: 试用新输入框, sfbase's composer_nodes)
  @sfbase.composer_nodes.set(both_nodes.val)
}
