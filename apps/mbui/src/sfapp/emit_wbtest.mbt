// An agent's answer coming out of its activity's avatar (emit.mbt), over the fixture's station: what
// is sent sets its agent to work (its activity shows), its answer is said while the chat shows.

///|
/// The fixture's chat open, its clock the test's; words sent and taken by the station (its agent then at work).
fn emit_core(clock : Ref[Double], words~ : String = "看一下列表") -> @ui.Tester {
  new_run()
  fix_clock.val = Some(fn() { clock.val })
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  // the chat pushed in over Home
  t.run_for(@ui.move_most_ms)
  t.tap_text("发消息")
  t.type_text(words)
  tap_send(t)
  // the station has it: in the chat, its agent at work
  fix_clock_set(clock, clock.val + fix_deliver_ms)
  t.draw()
  // (the station answers fix_answer_ms after it took them: that time passes on the page too, the words sent landed
  // and the agent's line come in meanwhile)
  t.run_for(fix_answer_ms)
  t
}

///|
/// A message's whole way out of its avatar: fold, float, spit, return.
fn emit_all_ms() -> Double {
  Pose::Fold.ms() + Pose::Float.ms() + Pose::Spit.ms() + Pose::Return.ms()
}

///|
fn emit_restore() -> Unit {
  fix_clock.val = None
}

///|
test "an answer taller than the window out of the avatar, the list at its end: read from its top, under the bar" {
  let clock = Ref(0.0)
  let t = emit_core(clock)
  // its agent at work, the list at its end: it says something long (in over its line), before the fixture's answer
  let first = "列表改成虚拟列表"
  let more = Array::makei(30, fn(i) { "第 \{i + 1} 段，接着往下讲。" }).join("\n\n")
  fix_later(1.0, fn() {
    fix_chat("s-c1").sent.push(
      msg(170, "agent", @sffixture.by_agent("anthropic", "claude", "s-c1"), long_reply + "\n\n" + more, "刚刚", {
        "ts": Json::string("long170"),
        "said": true,
      }),
    )
  })
  fix_clock_set(clock, clock.val + 1.0)
  t.draw()
  t.run_for(emit_all_ms() + 1000.0)
  // its top in view under the bar, not the list at the end of it
  guard t.drawn_of(first) is Some((_, y)) else { fail("the answer's top is not in view") }
  assert_true(y > bar_foot_at(t.ctx().window_size().0) && y < 844.0 / 2.0, msg="the answer's top at \{y}, the bar's foot at \{bar_foot_at(t.ctx().window_size().0)}")
  emit_restore()
}

///|
test "with the reader scrolled up (not watched), an answer just appears" {
  let clock = Ref(0.0)
  let t = emit_core(clock)
  t.wheel(195.0, 400.0, -600.0)
  let em = emits_of("ws1/st1\u{1}s-c1")
  fix_clock_set(clock, clock.val + fix_answer_ms)
  t.draw()
  assert_true(em.current is None)
  assert_eq(em.queue.length(), 0)
  assert_false(emit_held(em, 102.0))
  emit_restore()
}

///|
test "read up a little, the answer coming in under what is read comes where it is, its room opening: not there at once" {
  let clock = Ref(0.0)
  let t = emit_core(clock)
  t.wheel(195.0, 400.0, -120.0)
  t.run_for(@ui.move_most_ms)
  fix_clock_set(clock, clock.val + fix_answer_ms)
  t.draw()
  t.frame()
  let answer = fn() { t.words().filter(fn(w) { w.0.has_prefix("收到") }) }
  // (in view, as it sets out: nothing of it shown yet)
  guard answer() is [w, ..] else { fail("no answer in view") }
  assert_true(w.5 < 1.0, msg="\{Repr(w)}")
  // in at last where the list has it: over nothing else (its words over no other's)
  t.run_for(emit_all_ms())
  guard answer() is [w, ..] else { fail("no answer in view") }
  assert_eq(w.5, 1.0)
  for o in t.words() {
    if o.0 != w.0 && o.5 > 0.0 {
      let apart = o.2 + o.4 <= w.2 + 0.5 || w.2 + w.4 <= o.2 + 0.5 || o.1 + o.3 <= w.1 + 0.5 || w.1 + w.3 <= o.1 + 0.5
      assert_true(apart, msg="\{Repr(w)} over \{Repr(o)}")
    }
  }
  emit_restore()
}
