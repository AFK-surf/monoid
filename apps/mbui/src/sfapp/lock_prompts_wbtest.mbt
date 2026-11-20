// A new device showing this one's code (settings/lock_prompts.mbt): put up over the page open,
// whose and what it is, where it asks to be let in, the code; turned away (拒绝), or the panel closed by hand (the code
// still good: lockPrompt.hide), not put up again.

///|
test "a new device waiting on this one's code: its panel over the page, where it asks in, the code; 拒绝 turns it away" {
  let t = settings_tester("home", mode="settings-lock-prompt", shows="settings-lock-prompt", platform=2)
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting(), msg="its sheet up over the page")
  // (the screen kept on while the code is to be read off it: gone dark, the device could not ask as the code comes)
  assert_true(t.awake())
  assert_true(t.find("林的新设备请求批准") is Some(_))
  assert_true(t.find("Pixel 9") is Some(_))
  // where it asks to be let in, each workspace by name
  assert_true(t.find("申请访问") is Some(_))
  assert_true(t.find("星火工作室") is Some(_))
  assert_true(t.find("个人") is Some(_))
  assert_true(t.find("安全码只显示在此设备上") is Some(_))
  // (the button: the last words with 拒绝 in them, the lead says it too)
  let (x, y) = t.find_last("拒绝").unwrap()
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  // turned away: gone, and not put up again
  assert_false(@sf.presenting())
  assert_true(t.find("林的新设备请求批准") is None)
  assert_eq(@settings.fixture_pair_ended(), "deny")
  assert_false(t.awake())
}

///|
test "the panel closed by hand once the code is read: put away, not turned away (the code typed on the new device next)" {
  let t = settings_tester("home", mode="settings-lock-prompt", shows="settings-lock-prompt", platform=2)
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting())
  assert_true(t.awake())
  // a tap on the page beside it
  t.tap(195.0, 60.0)
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_true(t.find("林的新设备请求批准") is None)
  assert_eq(@settings.fixture_pair_ended(), "hide")
  assert_false(t.awake())
}

///|
test "no device waiting: no panel" {
  let t = settings_tester("home")
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_false(t.awake())
}

// With keyboard and mouse, on a wide window (a dialog in the middle there), done or turned away on another device
// meanwhile, asked into one more workspace meanwhile, into the person's own lock; where its words stand.

///|
/// A new device of lin's waiting on this one's code (prompt_asked, vault_prompts_wbtest.mbt): into 星火工作室 and 个人.
fn pair_asked(platform? : Int = 2, wide? : Bool = false, rest? : Bool = true) -> @ui.Tester {
  prompt_asked(fn() { @settings.fixture_prompts_now(pairing=true, key_ask=false) }, platform~, wide~, rest~)
}

///|
/// Where the words `words` are drawn under `under` (the panel's, where the page shows them too, higher up): their left,
/// top, width and height.
fn pair_word(t : @ui.Tester, words : String, under? : Double = -1.0) -> (Double, Double, Double, Double) {
  match t.words().iter().find_first(fn(w) { w.0 == words && w.2 > under }) {
    Some(w) => (w.1, w.2, w.3, w.4)
    None => @halt.saying("\{words} is not drawn under \{under}")
  }
}

///|
/// The code's two groups of three (`482`, `915`, as @ui.code_field_node groups them): on one line, 24 apart. Their
/// box together: left, top, width and height.
fn pair_code(t : @ui.Tester) -> (Double, Double, Double, Double) raise {
  let left = pair_word(t, "482")
  let right = pair_word(t, "915")
  assert_true((left.1 - right.1).abs() < 1.0, msg="the code's groups on one line: \{Repr(left)} \{Repr(right)}")
  assert_true(((right.0 - (left.0 + left.2)) - 24.0).abs() < 1.0, msg="the code's groups 24 apart: \{Repr(left)} \{Repr(right)}")
  (left.0, left.1, right.0 + right.2 - left.0, @cmp.maximum(left.3, right.3))
}

///|
test "on a narrow phone, its words as set and 1.3 times as large: the code's two groups whole, side by side" {
  // (the pair asked over settings as the screen sweeps open it, settings-lock-prompt: squeeze_wbtest.mbt's screen_in.
  // At 1.3 held to what words_large_wbtest.mbt holds every screen to: at that size the settings page under the panel
  // breaks the corner rule by itself, its account card, which is not this panel's)
  for screen in [(320.0, 690.0, 1.0), (360.0, 740.0, 1.3)] {
    let (w, h, scale) = screen
    let about = "\{w}x\{h} at \{scale}"
    let t = screen_in("settings-lock-prompt", ("narrow", w, h, 2, ""), "zh", font_scale=scale)
    assert_true(@sf.presenting(), msg=about)
    let code = pair_code(t)
    assert_true(code.0 >= 0.0 && code.0 + code.2 <= w, msg="\{about}: the code within the window: \{Repr(code)}")
    let faults = if scale == 1.0 {
      t.audit() + t.corner_faults()
    } else {
      t.squeeze_faults() + t.words_over_now() + t.fixed_outgrown()
    }
    assert_true(faults.is_empty(), msg="\{about}:\n" + faults.join("\n"))
  }
}

///|
test "done or turned away on another device: its panel goes by itself, nothing asked of the core" {
  for screen in [(2, false), (0, false), (0, true)] {
    let t = pair_asked(platform=screen.0, wide=screen.1)
    assert_true(t.find("林的新设备请求批准") is Some(_))
    assert_true(t.awake(), msg="platform \{screen.0}, wide \{screen.1}")
    @settings.fixture_prompts_now(pairing=false, key_ask=false)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_false(t.awake(), msg="platform \{screen.0}, wide \{screen.1}")
    assert_false(@sf.presenting(), msg="platform \{screen.0}, wide \{screen.1}")
    assert_true(t.find("林的新设备请求批准") is None)
    assert_eq(@settings.fixture_pair_ended(), "")
  }
}

///|
test "asked into one more workspace meanwhile: named too, its mark before it; the same panel" {
  let t = pair_asked()
  assert_true(t.find("开源") is None)
  @settings.fixture_prompts_now(pairing=true, more=true, key_ask=false)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting())
  assert_true(t.find("林的新设备请求批准") is Some(_))
  let head = pair_word(t, "申请访问")
  let (open, star) = (pair_word(t, "开源", under=head.1), pair_word(t, "星火工作室", under=head.1))
  let emoji = pair_word(t, "🌲", under=head.1)
  // (under the others; its emoji before it on its line)
  assert_true(open.1 >= star.1 + star.3, msg="开源 \{Repr(open)}, 星火工作室 \{Repr(star)}")
  assert_true(emoji.0 + emoji.2 <= open.0 && (emoji.1 + emoji.3 / 2.0 - (open.1 + open.3 / 2.0)).abs() < 2.0, msg="🌲 \{Repr(emoji)}, 开源 \{Repr(open)}")
  // (the code still under them all)
  let code = pair_code(t)
  assert_true(code.1 > open.1 + open.3, msg="the code \{Repr(code)}, 开源 \{Repr(open)}")
}

///|
test "into the person's own lock bound in no workspace: what approving lets it do said, no workspace named, nor a lock of one's own" {
  new_run()
  let t = settings_tester("home", mode="settings-lock-prompt-personal", shows="settings-lock-prompt-personal", platform=2)
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting())
  // (to people there is one safe mode, the user, 2026-11-10: it said 它要加入你的个人锁)
  assert_true(t.find("批准后，它可以批准手机调试") is Some(_))
  assert_true(t.find("申请访问") is None)
  assert_eq(t.words().filter(fn(w) { w.0.contains("个人锁") }).length(), 0)
}

///|
test "someone's first device in an upgraded workspace: the role approving lets them in as, under the workspaces, starting where they do" {
  for platform in [0, 2] {
    new_run()
    let t = settings_tester("home", mode="settings-lock-prompt-role", shows="settings-lock-prompt-role", platform~)
    t.run_for(@ui.move_most_ms)
    assert_true(@sf.presenting())
    let ask = pair_word(t, "申请访问")
    let role = pair_word(t, "「星火工作室」：批准后以管理员身份加入")
    assert_true(role.1 > ask.1, msg="platform \{platform}: under 申请访问")
    assert_eq(role.0, ask.0, msg="platform \{platform}: starting where 申请访问 does")
    let faults = t.audit()
    assert_true(faults.is_empty(), msg="platform \{platform}: " + faults.join(" | "))
  }
}

///|
test "with keyboard and mouse on a small window, and on a wide one (a dialog in the middle): 拒绝 turns it away" {
  for wide in [false, true] {
    let t = pair_asked(platform=0, wide~)
    if wide {
      let (x, y, _, _) = t.rect_of("林的新设备请求批准").unwrap()
      assert_true(x > 200.0 && x < 800.0 && y > 150.0 && y < 500.0, msg="its title at \{x},\{y}")
    }
    let (x, y) = t.find_last("拒绝").unwrap()
    t.tap(x, y)
    t.run_for(@ui.move_most_ms)
    assert_false(@sf.presenting(), msg="wide \{wide}")
    assert_eq(@settings.fixture_pair_ended(), "deny")
  }
}

///|
test "on a wide window: Escape and a press outside put it away, the code still good" {
  let t = pair_asked(platform=0, wide=true)
  t.key(@ui.key_escape)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_eq(@settings.fixture_pair_ended(), "hide")
  let t = pair_asked(platform=0, wide=true)
  t.tap(20.0, 780.0)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_eq(@settings.fixture_pair_ended(), "hide")
}


///|
test "where its words stand on each screen: whose and what, where it asks in, the code in the middle, until when, 拒绝 in its foot" {
  // (touch on a small window, a sheet; keyboard and mouse there, a sheet too; a wide window, a dialog in its middle)
  for screen in [(2, false), (0, false), (0, true)] {
    let t = pair_asked(platform=screen.0, wide=screen.1)
    let about = "platform \{screen.0}, wide \{screen.1}"
    let body = pair_word(t, "Pixel 9。确认申请人和设备后，在新设备上输入下方安全码；无法确认请拒绝。")
    let head = pair_word(t, "申请访问")
    let (star, mine) = (pair_word(t, "星火工作室", under=head.1), pair_word(t, "个人", under=head.1))
    let code = pair_code(t)
    let (until, note) = (pair_word(t, "14:05 前有效"), pair_word(t, "安全码只显示在此设备上，不会发送给任何人"))
    let deny = t.get(Button, label="拒绝").rect
    let foot = fn(r : (Double, Double, Double, Double)) { r.1 + r.3 }
    let mid = fn(r : (Double, Double, Double, Double)) { r.0 + r.2 / 2.0 }
    // (one under another, in this order)
    let order = [body, head, star, mine, code, until, note, deny]
    for i in 1..<order.length() {
      assert_true(foot(order[i - 1]) <= order[i].1 + 0.5, msg="\{about}: \{i}: \{Repr(order[i - 1])} over \{Repr(order[i])}")
    }
    // (what it asks and where at the panel's words' start; each workspace's name after its letter; the code, until when
    // and 拒绝 in the middle of the panel's words)
    assert_true((body.0 - head.0).abs() < 1.0 && star.0 > head.0 && (star.0 - mine.0).abs() < 1.0, msg="\{about}: \{Repr(body)} \{Repr(head)} \{Repr(star)} \{Repr(mine)}")
    let middle = mid(body)
    for r in [code, until] {
      assert_true((mid(r) - middle).abs() < 1.0, msg="\{about}: \{Repr(r)} not in the middle of \{Repr(body)}")
    }
    // (拒绝 in the panel's foot: across a sheet's, at a dialog's end in its corner)
    if screen.1 {
      assert_true(deny.0 > middle, msg="\{about}: \{Repr(deny)} not at the end of \{Repr(body)}")
      assert_eq(t.audit(), [])
      assert_eq(t.corner_faults(), [])
    } else {
      assert_true((mid(deny) - middle).abs() < 1.0, msg="\{about}: \{Repr(deny)} not in the middle of \{Repr(body)}")
    }
  }
}
