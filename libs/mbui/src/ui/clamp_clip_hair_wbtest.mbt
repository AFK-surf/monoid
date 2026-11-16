// An instance's clip moved (a slide) and cut to the clip it is painted in (clamp_inst_clip): an edge the cut moves by
// less than a millionth is where it was, as push_box_clip has it when the frame is built whole (clip_edge_is), so a
// corner there keeps its radius; one the cut truly moves is the cut's, or square.

///|
/// An instance whose clip is (0, 0)-(100, 100), its corners 26 round and as smooth as 0.6.
fn clamp_hair_inst() -> FixedArray[Double] {
  let a = FixedArray::make(inst_size, 0.0)
  a[16] = 0.0
  a[17] = 0.0
  a[18] = 100.0
  a[19] = 100.0
  for j in 0..<4 {
    a[24 + j] = 26.0
    a[28 + j] = 0.6
  }
  a
}

///|
test "a clip cut by what it is painted in a hair inside its edge keeps that edge's corners, as built whole" {
  let a = clamp_hair_inst()
  // (the clip it is painted in ends a hair short of its right edge: the same edge worked out two ways)
  clamp_inst_clip(a, 0, 0.0, 0.0, 100.0, 100.0, (-50.0, -50.0, 100.0 - 6.0e-14, 150.0), (0.0, 0.0, 0.0, 0.0), (
    0.0, 0.0, 0.0, 0.0,
  ))
  assert_eq([a[24], a[25], a[26], a[27]], [26.0, 26.0, 26.0, 26.0])
  assert_eq([a[28], a[29], a[30], a[31]], [0.6, 0.6, 0.6, 0.6])
}

///|
test "a clip truly cut by what it is painted in takes the cut's corners there, square where it has none" {
  let a = clamp_hair_inst()
  clamp_inst_clip(a, 0, 0.0, 0.0, 100.0, 100.0, (-50.0, -50.0, 80.0, 150.0), (0.0, 0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 0.0))
  assert_eq([a[24], a[25], a[26], a[27]], [26.0, 0.0, 0.0, 26.0])
  // (cut at the corner the clip it is painted in rounds: that one's radius)
  let b = clamp_hair_inst()
  clamp_inst_clip(b, 0, 0.0, 0.0, 100.0, 100.0, (-50.0, 0.0, 80.0, 150.0), (0.0, 12.0, 0.0, 0.0), (0.0, 0.5, 0.0, 0.0))
  assert_eq([b[25], b[29]], [12.0, 0.5])
}
