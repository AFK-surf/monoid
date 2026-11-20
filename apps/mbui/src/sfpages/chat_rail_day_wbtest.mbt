///|
/// 对话目录's rail says which day starts at a tick after another: its heading, as the core says it, kept with that tick
/// (days nobody said anything on make no gap of their own), and a pointer in that gap is on that day, not on a tick,
/// while one on any tick's room is on that tick.
test "chat rail: a day's gap names its day and is told apart from the ticks" {
  let ticks = chat_rail_ticks(
    ([2, 0, 3], [1.0, 2.0, 3.0, 4.0, 5.0], ["11月18日", "11月19日", "今天"]),
    (5.0, true),
    5.0,
    1000.0,
  )
  assert_eq(ticks.length(), 5)
  assert_eq(ticks.map(fn(t) { t.day }), [false, false, true, false, false])
  assert_eq(ticks.map(fn(t) { t.name }), ["", "", "今天", "", ""])
  // (laid out as chat_rail_press has them: two ticks, the day's gap, three ticks, in its middle)
  let room = tick_thick + tick_gap.px()
  let tall = 5.0 * room + tick_day_gap.px()
  let rail_h = dmax(rail_press_w, tall + 2.0 * rail_pad.px())
  let top = dmax(rail_pad.px(), (rail_h - tall) / 2.0)
  let gap_mid = top + 2.0 * room + tick_day_gap.px() / 2.0
  assert_eq(chat_rail_day_at(ticks, gap_mid), 2)
  assert_eq(chat_rail_day_at(ticks, top + room / 2.0), -1)
  assert_eq(chat_rail_day_at(ticks, top + 2.0 * room + tick_day_gap.px() + 3.0 * room / 2.0), -1)
  // (what the press asks its pointer with, one piece for both: the gap says its day, a tick's room its tick, the tick
  // under the gap included, and the second tick of the first day is its own and no day's)
  assert_eq(chat_rail_piece_at(ticks, gap_mid), -2 - 2)
  assert_eq(chat_rail_piece_at(ticks, top + room / 2.0), 0)
  assert_eq(chat_rail_piece_at(ticks, top + room + room / 2.0), 1)
  assert_eq(chat_rail_piece_at(ticks, top + 2.0 * room + tick_day_gap.px() + room / 2.0), 2)
  assert_eq(chat_rail_piece_at(ticks, top + 2.0 * room + tick_day_gap.px() + 3.0 * room / 2.0), 3)
  // (a map of the whole chat has no days)
  let map = chat_rail_ticks(
    ([2, 0, 3], [1.0, 2.0, 3.0, 4.0, 5.0], ["11月18日", "11月19日", "今天"]),
    (5.0, true),
    5.0,
    3.0 * room,
  )
  assert_true(map.iter().all(fn(t) { !t.day && t.name == "" }))
  assert_eq(chat_rail_day_at(map, gap_mid), -1)
}
