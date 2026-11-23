// How narrow words in pieces may wrap (rich.mbt rich_least_w) as their lines break (rich_lines): a run on a ground of
// its own (a file's chip) is kept whole on a line, so it is one piece however many places its words could break at.
// Over the fake host.

///|
test "a chip on a ground of its own is as narrow as its whole line, its words broken nowhere within it" {
  let _ = Tester::new(fn(_) {  }, w=300.0, h=300.0)
  let ground : @text.Ground? = Some({ room: 0.4, height: 1.4, corner: 0.3, after: 0.2 })
  let path = "libs/ui/src/controls/table_node.mbt:152"
  let chip = [@text.span(path, mono=true, scale=0.88, bg=0x0000000FL, ground~)]
  let least = view_runs_least(chip, @view.words_plain, @view.runs_plain, 1.0)
  let line = view_runs_measure(chip, @view.words_plain, @view.runs_plain, -1.0, 1.0).0
  assert_true((least - line).abs() < 0.01)
  // the same words on no ground break at their slashes
  let bare = [@text.span(path, mono=true, scale=0.88)]
  assert_true(view_runs_least(bare, @view.words_plain, @view.runs_plain, 1.0) < least * 0.6)
  // and what is beside the chip still breaks before it and after it
  let beside = [@text.plain("见 "), chip[0], @text.plain(" 第一个分句很长很长")]
  assert_true((view_runs_least(beside, @view.words_plain, @view.runs_plain, 1.0) - least).abs() < 0.01)
}
