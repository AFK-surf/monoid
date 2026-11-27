// An instance's clip moved (a slide) and cut to the clip it is painted in (clamp_inst_clip): an edge the cut moves by
// a hair (clip_hair, half a point) or less is where it was, as push_box_clip has it when the frame is built whole
// (clip_edge_near), so a corner there keeps its radius; one the cut truly moves is the cut's, or square.

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

///|
test "a rounded box a list's foot cuts by less than a hair keeps its corners there; cut by more, square" {
  // (a page's list's last row set on the device's pixels, a third of a pixel past the list's foot at 3 a point: a
  // sheet's last row's ripple)
  let base = clip_stack.length()
  push_clip(0.0, 0.0, 390.0, 258.6)
  push_box_clip(40.0, 195.8, 284.0, 62.9, 18.0, 18.0, 18.0, 18.0)
  let k = clip_top()
  let near = [clip_stack[k + 4], clip_stack[k + 5], clip_stack[k + 6], clip_stack[k + 7]]
  pop_clip()
  // (cut by 2 points: what the list's foot cuts off is seen, square there)
  push_box_clip(40.0, 195.8, 284.0, 64.8, 18.0, 18.0, 18.0, 18.0)
  let k = clip_top()
  let far = [clip_stack[k + 4], clip_stack[k + 5], clip_stack[k + 6], clip_stack[k + 7]]
  pop_clip()
  pop_clip()
  assert_eq(clip_stack.length(), base)
  assert_eq(near, [18.0, 18.0, 18.0, 18.0])
  assert_eq(far, [18.0, 18.0, 0.0, 0.0])
}

///|
test "a rounded box cut by exactly half a point, a list's row on a 1x screen rounded from x.5, keeps its corners" {
  let base = clip_stack.length()
  push_clip(0.0, 0.0, 390.0, 258.5)
  push_box_clip(40.0, 196.0, 284.0, 63.0, 18.0, 18.0, 18.0, 18.0)
  let k = clip_top()
  let edge = [clip_stack[k + 4], clip_stack[k + 5], clip_stack[k + 6], clip_stack[k + 7]]
  pop_clip()
  pop_clip()
  assert_eq(clip_stack.length(), base)
  assert_eq(edge, [18.0, 18.0, 18.0, 18.0])
  let a = clamp_hair_inst()
  inst_cut_to(a, 0, -50.0, -50.0, 150.0, 99.5)
  assert_eq([a[24], a[25], a[26], a[27]], [26.0, 26.0, 26.0, 26.0])
}

///|
test "a group's cut by a hair keeps a rounded clip's corners, as push_box_clip does; by more, square" {
  let a = clamp_hair_inst()
  inst_cut_to(a, 0, -50.0, -50.0, 150.0, 100.0 - 0.3)
  assert_eq([a[24], a[25], a[26], a[27]], [26.0, 26.0, 26.0, 26.0])
  let b = clamp_hair_inst()
  inst_cut_to(b, 0, -50.0, -50.0, 150.0, 98.0)
  assert_eq([b[24], b[25], b[26], b[27]], [26.0, 26.0, 0.0, 0.0])
}

///|
test "an instance moved and cut to its clip by a hair keeps its corners there" {
  let a = clamp_hair_inst()
  clamp_inst_clip(a, 0, 0.0, 0.0, 100.0, 100.0, (-50.0, -50.0, 150.0, 99.7), (0.0, 0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 0.0))
  assert_eq([a[24], a[25], a[26], a[27]], [26.0, 26.0, 26.0, 26.0])
}

///|
test "a square clip cut by a hair onto a rounder corner of the clip it is painted in takes that corner, as built whole" {
  let a = clamp_hair_inst()
  for j in 0..<4 {
    a[24 + j] = 0.0
    a[28 + j] = 0.0
  }
  clamp_inst_clip(a, 0, 0.0, 0.0, 100.0, 100.0, (0.0, 0.0, 100.0, 99.7), (0.0, 0.0, 12.0, 0.0), (0.0, 0.0, 0.6, 0.0))
  assert_eq([a[24], a[25], a[26], a[27]], [0.0, 0.0, 12.0, 0.0])
  assert_eq(a[30], 0.6)
}
