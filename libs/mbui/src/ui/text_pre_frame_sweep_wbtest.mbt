// Words shaped before a run's first frame (its tree brought before it: a column's width measured as it is made) are
// shaped while the host's glyph generation is not yet read; where the host forgot its glyphs' keys before that frame (a
// web page's scale or a face changed, textSweep), what was shaped by them is shaped again as the frame begins
// (text_arrive), never drawn by keys that are now other glyphs'. With nothing shaped before, nothing is measured again.

///|
/// As before a run's first frame: the host's generation not yet read, nothing shaped.
fn before_first_frame() -> Unit {
  text_cache.generation = -1
  atlas_said.val = None
  clear_shapes()
  text_cache.fonts.clear()
  text_cache.metrics.clear()
}

///|
test "words shaped before the first frame are shaped again as it begins, the host's generation moved on since" {
  let t = Tester::new(fn(_c) {  })
  before_first_frame()
  let before = shape("Medium", 14.0, 500)
  assert_false(text_cache.fonts.is_empty())
  // (the host forgot its keys before the first frame)
  t.fake.generation += 1
  let said = words_shaped_in.untracked()
  text_arrive()
  assert_eq(text_cache.generation, t.fake.generation)
  assert_true(text_cache.fonts.is_empty())
  assert_eq(text_cache.shaped, 0)
  assert_eq(words_shaped_in.untracked(), said + 1)
  assert_false(physical_equal(shape("Medium", 14.0, 500), before))
}

///|
test "a first frame with nothing shaped before it measures nothing again" {
  let t = Tester::new(fn(_c) {  })
  before_first_frame()
  t.fake.generation += 1
  let said = words_shaped_in.untracked()
  text_arrive()
  assert_eq(text_cache.generation, t.fake.generation)
  assert_eq(words_shaped_in.untracked(), said)
}
