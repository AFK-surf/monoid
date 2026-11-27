// The app's lists whose blocks are taken again as they leave what shows (mbui's View::scrolls_reused): a job's output
// beside its chat (sfdesk's jobs_tab_node, 大屏) scrolled from its end to its top through hundreds of lines, and ⌘K's
// results (sfpages' switcher.mbt) as the words typed bring others: how many nodes the window's tree makes meanwhile,
// and that each block shows, and opens, the key it is taken for.

///|
/// How many lines the output beside the chat holds (what the core gives of the 400 asked: sfdesk's job_output_lines).
let reused_job_lines : Int = 300

///|
/// A line of a job's output as the core's `jobLog` gives it (its number `k`, its runs).
fn reused_job_line(k : Int) -> Json {
  { "n": Json::number(k.to_double()), "runs": [{ "text": Json::string("line \{k} of the run") }] }
}

///|
/// The chat's 任务 tab beside it on 大屏 (chat-jobs-side), its job's output `reused_job_lines` lines, 输出 pressed: at
/// its end.
fn reused_jobs_side() -> @ui.Tester {
  new_run()
  let base = @sffixture.fixture("chat-jobs-side")
  let log : Json = {
    "lines": Json::array(Array::makei(reused_job_lines, reused_job_line)),
    "said": "最后输出 · 刚刚",
    "last": "x",
  }
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      if name == "jobLog" {
        return { value: Some(log), error: None, version: 1 }
      }
      base.topic(name, params).get().snapshot()
    },
  }
  open_fixture_over("chat-jobs-side", src)
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  t.run_for(@ui.move_most_ms)
  // (the choice of what it said and its output: 输出 pressed where it is)
  let (x, y, w, h) = t.get(Radio, label="输出").rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// The output's lines drawn, by their numbers, top to bottom.
fn reused_job_drawn(t : @ui.Tester) -> Array[Int] {
  let lines = t.words().filter(fn(w) { w.0.has_prefix("line ") && w.0.has_suffix(" of the run") && w.5 > 0.0 })
  lines.sort_by(fn(a, b) { a.2.compare(b.2) })
  lines.map(fn(w) {
    let mut n = 0
    for c in w.0.unsafe_substring(start=5, end=w.0.length() - 11) {
      n = n * 10 + (c.to_int() - '0'.to_int())
    }
    n
  })
}

///|
test "大屏: a job's output beside its chat scrolled from its end to its top, its lines' blocks taken by those that come: fewer made than a block a line, each block its line's" {
  let t = reused_jobs_side()
  let first = reused_job_drawn(t)
  assert_true(
    first.length() > 3 && first.last() == Some(reused_job_lines - 1),
    msg="opened at its end: \{Repr(first)}: \{t.words().map(fn(w) { w.0 }).join("|")}",
  )
  // (where a line of it is drawn: the wheel turned there)
  let (_, x, y, w, h, _) = t.words().iter().find_first(fn(w) { w.0 == "line \{reused_job_lines - 1} of the run" }).unwrap()
  t.tree_frames_from_now()
  let mut turns = 0
  while turns < 80 && reused_job_drawn(t).get(0).unwrap_or(0) > 0 {
    t.wheel(x + w / 2.0, y + h / 2.0, -120.0)
    t.run_for(@ui.move_most_ms)
    turns += 1
  }
  let made = t.tree_frames().fold(init=0, fn(n, f) { n + f.made })
  let top = reused_job_drawn(t)
  println("job output: \{turns} turns of the wheel past \{reused_job_lines - top.length()} lines: \{made} nodes made")
  // (at its top, every line drawn its own, one after another)
  assert_eq(top.get(0), Some(0), msg="at its top: \{Repr(top)}")
  assert_eq(top, Array::makei(top.length(), fn(i) { i }), msg="each block its line's")
  // (blocks taken by the lines that come, more made only where a turn brings more than are put by: under two a line
  // passed, where each line's block made anew was nearer three)
  let passed = reused_job_lines - top.length()
  assert_true(made < 2 * passed, msg="made \{made} scrolling past \{passed} lines")
}

///|
/// ⌘K open on 大屏 over Home, nothing typed, in a window `h` tall.
fn reused_switcher(h : Double) -> @ui.Tester {
  let calls : Array[Made] = []
  let t = wide_tester(calls, w=1280.0, h~, platform=0)
  t.draw()
  t.key(@ui.key_of_char('k'), mods=@ui.mod_cmd)
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// The words ⌘K's list `list` draws in what shows of it, top to bottom.
fn reused_switcher_words(t : @ui.Tester, list : @ui.Laid) -> Array[String] {
  let ws = t.words().filter(fn(w) { w.5 > 0.0 && w.1 >= list.x && w.2 >= list.y && w.2 + w.4 <= list.y + list.h })
  ws.sort_by(fn(a, b) { if a.2 == b.2 { a.1.compare(b.1) } else { a.2.compare(b.2) } })
  ws.map(fn(w) { w.0 })
}

///|
test "⌘K: what it offers with nothing typed scrolled through, its lines' blocks taken by those that come, each drawing its own line" {
  let t = reused_switcher(300.0)
  let list = switcher_lists(t, switcher_panel_rect(t))[0]
  let at_first = switcher_blocks(t, list).length()
  t.tree_frames_from_now()
  for _ in 0..<12 {
    t.wheel(list.x + list.w / 2.0, list.y + list.h / 2.0, 60.0)
    t.run_for(@ui.move_most_ms)
  }
  let made = t.tree_frames().fold(init=0, fn(n, f) { n + f.made })
  let seen = reused_switcher_words(t, list)
  println("⌘K: nothing typed, \{at_first} blocks at first, scrolled 12 turns of 60: \{made} nodes made; shows \{seen.join("|")}")
  // (each block draws the line its key is now: what it offers, in its order, where it was scrolled to)
  let lines = seen.filter(fn(w) { ["收起/展开侧边栏", "设置", "快捷键一览"].contains(w) })
  assert_eq(lines, ["收起/展开侧边栏", "设置", "快捷键一览"], msg=seen.join("|"))
  // (its lines' blocks taken by those that come: well under one line's make a line passed, as each made anew was)
  assert_true(made < 150, msg="made \{made} scrolling ⌘K's list")
}
