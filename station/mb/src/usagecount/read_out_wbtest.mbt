// A put-away transcript read to its end (counter.mbt `read_out`): not opened again, its end not decompressed to be
// compared with its anchor; anything else about it read and checked as before.

///|
fn counted_at(offset : Double, speed? : String? = Some("1,2,3,4")) -> Counted {
  {
    session: Some("k"),
    offset,
    model: Some("m"),
    speed,
    cutoff: Some(10.0),
    anchor: Some("ab"),
    path: "/t/r.jsonl",
  }
}

///|
test "a put-away transcript read to its end is not read again" {
  let w = counted_at(100.0)
  assert_true(read_out(true, Some(w), 100.0, "/t/r.jsonl", None, "claude"))
  // Timed already: not read again even when time_from is set.
  assert_true(read_out(true, Some(w), 100.0, "/t/r.jsonl", Some(5.0), "pi"))
  assert_true(read_out(true, Some(w), 100.0, "/t/r.jsonl", Some(5.0), "claude"))
  assert_true(read_out(true, Some(w), 100.0, "/t/r.jsonl", Some(5.0), "codex"))
  assert_true(read_out(true, Some(counted_at(100.0, speed=Some("v1:"))), 100.0, "/t/r.jsonl", Some(5.0), "agy"))
  let untimed = counted_at(100.0, speed=None)
  assert_true(read_out(true, Some(untimed), 100.0, "/t/r.jsonl", None, "pi"))
  assert_true(read_out(true, Some(untimed), 100.0, "/t/r.jsonl", None, "agy"))
  // Untimed with time_from set: must be read once to backfill (including legacy agy `,,,`).
  assert_false(read_out(true, Some(untimed), 100.0, "/t/r.jsonl", Some(5.0), "claude"))
  assert_false(read_out(true, Some(untimed), 100.0, "/t/r.jsonl", Some(5.0), "codex"))
  assert_false(read_out(true, Some(untimed), 100.0, "/t/r.jsonl", Some(5.0), "agy"))
  assert_false(read_out(true, Some(counted_at(100.0, speed=Some(",,,"))), 100.0, "/t/r.jsonl", Some(5.0), "agy"))
}

///|
test "a transcript grown, cut short, not put away or never read is read and checked as before" {
  let w = counted_at(100.0)
  // Longer (calls put away with it), shorter (another file in its place).
  assert_false(read_out(true, Some(w), 120.0, "/t/r.jsonl", None, "claude"))
  assert_false(read_out(true, Some(w), 80.0, "/t/r.jsonl", None, "claude"))
  // Not put away: a file being written, its anchor compared.
  assert_false(read_out(false, Some(w), 100.0, "/t/r.jsonl", None, "claude"))
  assert_false(read_out(true, None, 100.0, "/t/r.jsonl", None, "claude"))
}

///|
test "a put-away transcript lacking its boundary, anchor or place, or its `,,,`, is read as before" {
  let w = counted_at(100.0)
  assert_false(read_out(true, Some({ ..w, cutoff: None }), 100.0, "/t/r.jsonl", None, "claude"))
  assert_false(read_out(true, Some({ ..w, anchor: None }), 100.0, "/t/r.jsonl", None, "claude"))
  // Read under another home's path: its place written again.
  assert_false(read_out(true, Some(w), 100.0, "/u/r.jsonl", None, "claude"))
  // Of a runtime whose calls are not timed, read before timing began: marked `,,,` once more.
  let untimed = counted_at(100.0, speed=None)
  assert_false(read_out(true, Some(untimed), 100.0, "/t/r.jsonl", Some(5.0), "pi"))
}
