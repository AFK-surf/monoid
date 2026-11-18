// A device of the person's set up without the key to a vault of theirs, waiting on this one (settings/vault_prompts.mbt):
// put up over the page open, which device and which vault; 授权 gives it the key (vault.addDevice), 稍后 or the panel
// closed by hand puts it away (vault.hidePrompt), not put up again.

///|
test "a device waiting on this one for a vault's key: its panel over the page, which device and vault; 授权 gives it" {
  let t = settings_tester("home", mode="settings-vault-prompt", shows="settings-vault-prompt", platform=2)
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting(), msg="its sheet up over the page")
  assert_true(t.find("Pixel 9 申请密钥库的钥匙") is Some(_))
  assert_true(t.find("星火工作室 · 林的库") is Some(_))
  // (the button: the last words with 授权 in them, the lead says it too)
  let (x, y) = t.find_last("授权").unwrap()
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  // given: gone, and not put up again
  assert_false(@sf.presenting())
  assert_true(t.find("Pixel 9 申请密钥库的钥匙") is None)
  assert_eq(@settings.fixture_key_ask_ended(), "give")
}

///|
test "稍后: put away (shown again only once that device asks again)" {
  let t = settings_tester("home", mode="settings-vault-prompt", shows="settings-vault-prompt", platform=2)
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting())
  let (x, y) = t.find_last("稍后").unwrap()
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_true(t.find("Pixel 9 申请密钥库的钥匙") is None)
  assert_eq(@settings.fixture_key_ask_ended(), "hide")
}

///|
test "the panel closed by hand: put away too" {
  let t = settings_tester("home", mode="settings-vault-prompt", shows="settings-vault-prompt", platform=2)
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting())
  // a tap on the page beside it
  t.tap(195.0, 60.0)
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_eq(@settings.fixture_key_ask_ended(), "hide")
}

// With keyboard and mouse, on a wide window (a dialog in the middle there), the key given or the ask put away on
// another device meanwhile, the key being given; where its words stand on each screen.

///|
/// The settings' home open (touch or keyboard and mouse: `platform`; a wide window, `wide`), at rest, then the made-up
/// core telling of what `ask` puts in its `lockPrompts` (vault_prompts.mbt, lock_prompts.mbt): its panel put up as the
/// next frame is drawn, come to rest there (`rest`) or at the moment it was put up.
fn prompt_asked(ask : () -> Unit, platform? : Int = 2, wide? : Bool = false, rest? : Bool = true) -> @ui.Tester {
  let t = settings_tester("home", platform~)
  if wide {
    t.resize(1200.0, 800.0)
    t.run_for(@ui.move_most_ms)
  }
  guard !@sf.presenting() else { @halt.saying("a panel up before it is asked") }
  ask()
  t.draw()
  if rest {
    t.run_for(@ui.move_most_ms)
  }
  t
}

///|
/// A device of lin's waiting on this one for the key to 林的库 (prompt_asked).
fn key_asked(platform? : Int = 2, wide? : Bool = false, rest? : Bool = true) -> @ui.Tester {
  prompt_asked(fn() { @settings.fixture_prompts_now(pairing=false, key_ask=true) }, platform~, wide~, rest~)
}

///|
/// Where the first of the words `words` is drawn: its left, top, width and height.
fn prompt_word(t : @ui.Tester, words : String) -> (Double, Double, Double, Double) {
  match t.words().iter().find_first(fn(w) { w.0 == words }) {
    Some(w) => (w.1, w.2, w.3, w.4)
    None => @halt.saying("\{words} is not drawn")
  }
}

///|
test "the key given or the ask put away on another device: its panel goes by itself, nothing asked of the core" {
  for screen in [(2, false), (0, false), (0, true)] {
    let t = key_asked(platform=screen.0, wide=screen.1)
    assert_true(t.find("Pixel 9 申请密钥库的钥匙") is Some(_))
    @settings.fixture_prompts_now(pairing=false, key_ask=false)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_false(@sf.presenting(), msg="platform \{screen.0}, wide \{screen.1}")
    assert_true(t.find("Pixel 9 申请密钥库的钥匙") is None)
    assert_eq(@settings.fixture_key_ask_ended(), "")
  }
}

///|
test "with keyboard and mouse on a small window: 授权 gives it the key, 稍后 puts it away" {
  let t = key_asked(platform=0)
  assert_true(@sf.presenting())
  let (x, y) = t.find_last("授权").unwrap()
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_eq(@settings.fixture_key_ask_ended(), "give")
  let t = key_asked(platform=0)
  let (x, y) = t.find_last("稍后").unwrap()
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_eq(@settings.fixture_key_ask_ended(), "hide")
}

///|
test "on a wide window: a dialog in the middle; 授权 gives it the key; 稍后, Escape and a press outside put it away" {
  let t = key_asked(platform=0, wide=true)
  let (x, y, _, _) = t.rect_of("Pixel 9 申请密钥库的钥匙").unwrap()
  assert_true(x > 200.0 && x < 800.0 && y > 150.0 && y < 500.0, msg="its title at \{x},\{y}")
  let (x, y) = t.find_last("授权").unwrap()
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_eq(@settings.fixture_key_ask_ended(), "give")
  let t = key_asked(platform=0, wide=true)
  let (x, y) = t.find_last("稍后").unwrap()
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_eq(@settings.fixture_key_ask_ended(), "hide")
  let t = key_asked(platform=0, wide=true)
  t.key(@ui.key_escape)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_eq(@settings.fixture_key_ask_ended(), "hide")
  let t = key_asked(platform=0, wide=true)
  t.tap(20.0, 780.0)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_eq(@settings.fixture_key_ask_ended(), "hide")
}

///|
test "while the key is being given: 授权 turning, neither it nor 稍后 pressed; given, the panel goes" {
  // (giving as it is put up: an old view's press said while 授权 could be pressed stays said after, so pressing it
  // while it turns would give it again there)
  let t = prompt_asked(fn() { @settings.fixture_prompts_now(pairing=false, key_ask=true, giving=true) })
  // (turning: its spinner before its words, which stand off the middle by half of it and the gap)
  let (give, later) = (prompt_word(t, "授权"), prompt_word(t, "稍后"))
  assert_true(give.0 > later.0 + 5.0, msg="授权 \{Repr(give)}, 稍后 \{Repr(later)}")
  for words in ["授权", "稍后"] {
    let (x, y) = t.find_last(words).unwrap()
    t.tap(x, y)
    t.run_for(@ui.move_most_ms)
    assert_true(@sf.presenting(), msg="\{words} pressed while it gives")
    assert_eq(@settings.fixture_key_ask_ended(), "")
  }
  @settings.fixture_prompts_now(pairing=false, key_ask=false)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
}

///|
test "where its words stand on each screen: the title, what it asks, whose vault, then 稍后 and 授权 in the panel's foot" {
  // (touch on a small window, a sheet; keyboard and mouse there, a sheet too; a wide window, a dialog in its middle)
  for screen in [(2, false), (0, false), (0, true)] {
    let t = key_asked(platform=screen.0, wide=screen.1)
    let about = "platform \{screen.0}, wide \{screen.1}"
    let title = prompt_word(t, "Pixel 9 申请密钥库的钥匙")
    let body = prompt_word(t, "这台设备已在安全模式的锁里，3 分钟前申请「林的库」的钥匙。授权后它就能用这个库里的密钥。")
    let place = prompt_word(t, "星火工作室 · 林的库")
    let give = t.get(Button, label="授权").rect
    let later = t.get(Button, label="稍后").rect
    // (one under another, in this order, at the same start; the foot's two buttons side by side under them, 稍后 first)
    assert_true(title.1 + title.3 <= body.1 && body.1 + body.3 <= place.1 && place.1 + place.3 <= give.1, msg="\{about}: \{Repr(title)} \{Repr(body)} \{Repr(place)} \{Repr(give)}")
    assert_true((title.0 - body.0).abs() < 1.0 && (body.0 - place.0).abs() < 1.0, msg="\{about}: \{Repr(title)} \{Repr(body)} \{Repr(place)}")
    assert_true((give.1 - later.1).abs() < 1.0 && later.0 + later.2 <= give.0, msg="\{about}: \{Repr(later)} \{Repr(give)}")
    let middle = body.0 + body.2 / 2.0
    if screen.1 {
      // (a dialog's: as wide as their words, at its end, in its corner)
      assert_true(later.0 > middle, msg="\{about}: \{Repr(later)} not at the end of \{Repr(body)}")
      assert_eq(t.audit(), [])
      assert_eq(t.corner_faults(), [])
    } else {
      // (a sheet's: the foot shared between them, as wide as each other, about the sheet's middle)
      assert_true((give.2 - later.2).abs() < 1.0, msg="\{about}: \{Repr(later)} \{Repr(give)}")
      assert_true(((later.0 + give.0 + give.2) / 2.0 - middle).abs() < 1.0, msg="\{about}: \{Repr(later)} \{Repr(give)} \{Repr(body)}")
    }
  }
}

///|
/// What each check (`checks`) finds in `mode` in window `win`, language `lang`, words at `scale`: each check's name and
/// what it says, all read before another Tester is made (a Tester reads the frame of the one made last).
fn key_ask_faults(
  mode : String,
  win : (String, Double, Double, Int, String),
  lang : String,
  checks : Array[(String, (@ui.Tester) -> Array[String])],
  scale? : Double = 1.0,
) -> Array[(String, Array[String])] {
  let t = screen_in(mode, win, lang, font_scale=scale)
  checks.map(fn(c) { (c.0, (c.1)(t)) })
}

///|
/// What the key's prompt adds to the settings' home it is put up over (settings/fixture.mbt's fixture_page): each
/// check's faults on the prompt that are not on that page alone, said with `at`.
fn key_ask_added(
  at : String,
  win : (String, Double, Double, Int, String),
  lang : String,
  checks : Array[(String, (@ui.Tester) -> Array[String])],
  scale? : Double = 1.0,
) -> Array[String] {
  let prompt = key_ask_faults("settings-vault-prompt", win, lang, checks, scale~)
  let under = key_ask_faults("settings-home", win, lang, checks, scale~)
  let added : Array[String] = []
  for k, c in prompt {
    for f in c.1 {
      if !under[k].1.contains(f) {
        added.push("\{at} \{c.0}: \{f}")
      }
    }
  }
  added
}

///|
test "the key's prompt in every window of the sweeps, in Chinese and English, and at 1.3: nothing over its page's own" {
  // (the sweeps' windows and checks (corners_wbtest.mbt, words_large_wbtest.mbt), held here to the prompt alone: what
  // the page under it has of its own, the tape's rail's corner on a touch and a desk-win window, is that page's and
  // its bars'. The prompt is not in corner_modes: the real-size sweep takes those, and the page under it is over a
  // new screen's bar there already.)
  let checks : Array[(String, (@ui.Tester) -> Array[String])] = [
    ("corners", fn(t) { t.corner_faults() }),
    ("squeeze", fn(t) { t.squeeze_faults() }),
    ("heights", fn(t) { t.height_faults() }),
    ("first line", fn(t) { t.first_line_faults() }),
    ("line start", fn(t) { t.line_start_faults() }),
    ("outgrown", fn(t) { t.fixed_outgrown() }),
    ("gaps", fn(t) { t.gap_faults() }),
  ]
  let wrong : Array[String] = []
  for win in corner_windows {
    for lang in ["zh", "en"] {
      let here = if lang == "zh" { checks + [("room", fn(t) { t.room_faults() })] } else { checks }
      wrong.append(key_ask_added("\{win.0}-\{lang}", win, lang, here))
    }
  }
  // (the system's words at 1.3 in a phone's window: all of it fits, no words over words)
  let large : Array[(String, (@ui.Tester) -> Array[String])] = [
    ("outgrown", fn(t) { t.fixed_outgrown() }),
    ("squeeze", fn(t) { t.squeeze_faults() }),
    ("words over words", fn(t) { t.words_over_now() }),
  ]
  for lang in ["zh", "en"] {
    wrong.append(key_ask_added("phone-\{lang} at \{words_large_scale}", corner_windows[0], lang, large, scale=words_large_scale))
  }
  assert_eq(wrong, [])
}
