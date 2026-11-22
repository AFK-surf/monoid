// 17-drive-read (e2e/traces/drive-read.trace: Mac against the local still.fail): a text of the lent folder read
// (drive.read): its chapters found, the bars a tap away, the contents going to a chapter; where it was left told to
// the core once the reader held still (drive.place, past the first two chapters: Flow::end has it asked as the run
// asked it), and its row says how far.
// before it: 15-drive-lend

///|
test "17-drive-read" {
  @sfreplay.orders(fn(seed) {
    let f = @sfreplay.Flow::start(@sfreplay.trace("drive-read"), seed~)
    f.open_page(@sfapp.Page::Files)
    f.tap("=e2e-082940")
    f.run_to(@ui.nav_rest)
    f.tap("小说-e2e.txt")
    // (the reader in, its push over: a live run taps its text only then)
    f.run_for(@ui.move_most_ms)
    // a tap on the text: the bars
    f.tap_at(195.0, 420.0)
    f.run_for(@sf.reader_bars_ms)
    f.see("目录")
    f.see("下一章")
    f.see("第一章 雨后的车站")
    f.tap("目录")
    f.run_for(reader_sheet_ms)
    f.see("第三章 灯塔的钥匙")
    f.tap("第三章 灯塔的钥匙")
    f.run_for(reader_sheet_ms)
    f.gone("第四章 回程")
    // held still there: where it is told to the core
    f.run_for(@sf.reader_still_ms)
    f.back()
    f.run_to(@ui.nav_rest)
    f.see("小说-e2e.txt")
    f.see("%")
    f.end()
  })
}

///|
/// How long the reader's contents' sheet (sf's sheet_node, the window's tree's) takes to come or go at most: a way as far
/// as the window is tall or its scrim's fade, whichever is longer.
let reader_sheet_ms : Double = @motion.sheet_scrim_ms.max(@ui.move_ms(844.0)) + 2.0 * @ui.input_step_ms
