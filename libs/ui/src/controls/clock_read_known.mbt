// What of this package's files reads the time as a node's property (mbui's src/view/clock_read.mbt: a bar a file, the
// places in it that may, each going and only falling).

///|
fn init {
  @view.clock_read_known([
    ("drawn_at", "ui/src/controls/tip_node.mbt", 2),
    ("drawn_at", "ui/src/controls/viewer_head_node.mbt", 1),
  ])
}
