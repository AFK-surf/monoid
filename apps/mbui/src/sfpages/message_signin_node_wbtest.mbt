// An agent's ask to sign in to a site in place of its post's words, as nodes (message_signin_node.mbt), set beside the
// old view's (signin_card.mbt's signin_ask_card, in a list's row so that how it went is pressed for the card read
// again, as there) on the same fixture (chat-signin's post, its card as the core says it): waiting on a device with no
// password manager, with 1Password, with the system's autofill; 1Password asked, its logins to pick from, none for the
// site, its servers not reached, the autofill asked, not to be kept; a code asked, typed; a captcha, the agent's word
// for the person; filling, left, signed in and being kept, its keeping failed; another's; signed in and kept, not
// kept, refused, expired, ended; wide, narrow, at 1.3 (its foot's buttons on lines over one another, as the old).

///|
/// chat-signin's post, its sign-in as `more` says over the fixture's (waiting), `theirs`: 陈's to answer.
fn signin_post_with(more? : Map[String, Json] = {}, theirs? : Bool = false) -> Message {
  let j = @sffixture.signin_post("chat-signin")
  match j {
    Object(o) =>
      match o.get("card") {
        Some(Object(card)) => {
          if theirs {
            card["assignee"] = "chen@example.com"
            card["assigneeText"] = "等 陈 完成"
          }
          match card.get("signinAsk") {
            Some(Object(ask)) =>
              for k, v in more {
                ask[k] = v
              }
            _ => ()
          }
        }
        _ => ()
      }
    _ => ()
  }
  card_said_then(j)
}

///|
/// What the host has of a password manager in a case: none; 1Password, the site's logins it lists (`listed`, its
/// `op item list`'s answer; its runs under way and never ending where `slow`; its servers not reached where
/// `unreached`); the system's autofill.
priv enum SignInHost {
  NoManager
  OnePassword(String, Bool, Bool)
  Autofill
}

///|
/// Two logins of github.com, as `op item list` says them (one with its account).
// kept across runs: a value
let signin_two_logins : String = "[{\"id\":\"l1\",\"title\":\"GitHub\",\"additional_information\":\"lin\",\"urls\":[{\"href\":\"https://github.com\"}]},{\"id\":\"l2\",\"title\":\"GitHub 工作\",\"additional_information\":\"lin-work\",\"urls\":[{\"href\":\"https://github.com/login\"}]}]"

///|
/// One login of github.com, as `op item list` says it.
// kept across runs: a value
let signin_one_login : String = "[{\"id\":\"l1\",\"title\":\"GitHub\",\"additional_information\":\"lin\",\"urls\":[{\"href\":\"https://github.com\"}]}]"

///|
/// The host as `h` says, set as a run begins (card_old's `begun`); what was asked of the cards before let go of.
fn signin_host(h : SignInHost) -> () -> Unit {
  fn() {
    signin_reset()
    @sf.presenters_reset()
    match h {
      NoManager => ()
      Autofill => @ui.fake_autofill.val = true
      OnePassword(listed, slow, unreached) => {
        @ui.fake_op_pending.val = slow
        @ui.fake_op.val = Some(fn(args) {
          if unreached {
            (1, "", "[ERROR] 2026/11/03 16:43:31 Get \"https://my.1password.com/api/v2/account/keysets\": unexpected EOF\n")
          } else if args.contains("list") {
            (0, listed, "")
          } else if args.contains("--otp") {
            (1, "", "[ERROR] no one-time password")
          } else {
            (0, "[{\"id\":\"username\",\"label\":\"username\",\"value\":\"lin\"},{\"id\":\"password\",\"purpose\":\"PASSWORD\",\"label\":\"password\",\"value\":\"s3cret\"}]", "")
          }
        })
      }
    }
  }
}

///|
/// A case: its name, the post, the host, what is pressed in turn on its card (each the words drawn), whether the core
/// answers keeping it in the vault with an error (signin_src).
priv struct SignInCase {
  name : String
  post : Message
  host : SignInHost
  presses : Array[String]
  fails : Bool
}

///|
/// chat-signin's source, its calls kept in `calls`; `vault.approve` answered at once with an error where `fails` (the
/// vault locked), every other call never.
fn signin_src(fails? : Bool = false, calls? : Array[(String, Json)] = []) -> Source {
  let base = card_src("chat-signin", calls~)
  {
    ..base,
    call: fn(name, params, done) {
      (base.call)(name, params, done)
      if fails && name == "vault.approve" {
        done(Err(Json::string("密钥库已锁定")))
      }
    },
  }
}

///|
/// The sign-in's states by name.
fn signin_cases() -> Array[SignInCase] {
  let op = OnePassword(signin_two_logins, false, false)
  let s = fn(v : String) { Json::string(v) }
  [
    { name: "on screen", post: signin_post_with(), host: NoManager, presses: [], fails: false },
    { name: "1Password", post: signin_post_with(), host: op, presses: [], fails: false },
    { name: "autofill", post: signin_post_with(), host: Autofill, presses: [], fails: false },
    { name: "1Password asked", post: signin_post_with(), host: OnePassword(signin_two_logins, true, false), presses: ["用 1Password 登录"], fails: false },
    { name: "logins to pick", post: signin_post_with(), host: op, presses: ["用 1Password 登录"], fails: false },
    { name: "sending", post: signin_post_with(), host: OnePassword(signin_one_login, false, false), presses: ["用 1Password 登录"], fails: false },
    { name: "none for the site", post: signin_post_with(), host: OnePassword("[]", false, false), presses: ["用 1Password 登录"], fails: false },
    { name: "not reached", post: signin_post_with(), host: OnePassword("[]", false, true), presses: ["用 1Password 登录"], fails: false },
    { name: "autofill asked", post: signin_post_with(), host: Autofill, presses: ["用密码管理器登录"], fails: false },
    { name: "not to keep", post: signin_post_with(), host: NoManager, presses: ["登录后存入密钥库", "不存入密钥库"], fails: false },
    { name: "code", post: signin_post_with(more={ "status": s("code") }), host: NoManager, presses: [], fails: false },
    { name: "person", post: signin_post_with(more={ "status": s("person"), "why": s("blocked") }), host: NoManager, presses: [], fails: false },
    { name: "agent's word", post: signin_post_with(more={ "status": s("person"), "why": s("agent"), "said": s("要先在手机上确认登录") }), host: NoManager, presses: [], fails: false },
    { name: "filling", post: signin_post_with(more={ "status": s("filling") }), host: NoManager, presses: [], fails: false },
    { name: "left", post: signin_post_with(more={ "status": s("left") }), host: NoManager, presses: [], fails: false },
    { name: "saving", post: signin_post_with(more={ "status": s("done"), "keep": Json::boolean(true), "save": s("r-save") }), host: NoManager, presses: [], fails: false },
    {
      name: "save failed",
      post: signin_post_with(more={ "status": s("done"), "keep": Json::boolean(true), "save": s("r-save") }),
      host: NoManager,
      presses: [],
      fails: true,
    },
    { name: "theirs", post: signin_post_with(theirs=true), host: NoManager, presses: [], fails: false },
    { name: "kept", post: signin_post_with(more={ "status": s("done"), "keep": Json::boolean(true), "save": s("r-save"), "kept": s("granted") }), host: NoManager, presses: [], fails: false },
    { name: "not kept", post: signin_post_with(more={ "status": s("done"), "keep": Json::boolean(false) }), host: NoManager, presses: [], fails: false },
    { name: "done", post: signin_post_with(more={ "status": s("done"), "keep": Json::boolean(true) }), host: NoManager, presses: [], fails: false },
    { name: "denied", post: signin_post_with(more={ "status": s("denied") }), host: NoManager, presses: [], fails: false },
    { name: "withdrawn", post: signin_post_with(more={ "status": s("withdrawn") }), host: NoManager, presses: [], fails: false },
    { name: "expired", post: signin_post_with(more={ "status": s("expired") }), host: NoManager, presses: [], fails: false },
    { name: "ended", post: signin_post_with(more={ "status": s("ended") }), host: NoManager, presses: [], fails: false },
  ]
}

///|
/// How many of card_audit's rooms case `name` has.
fn signin_rooms(_name : String) -> Int {
  0
}

///|
/// Case `c` drawn `w` wide at `scale` by the nodes.
fn signin_held(c : SignInCase, w : Double, scale? : Double = 1.0) -> @ui.Tester {
  let t = card_new(w, signin_src(fails=c.fails), fn() { c.post }, begun=signin_host(c.host))
  t.set_font_scale(scale)
  t.run_for(@ui.move_most_ms)
  for p in c.presses {
    t.tap_text(p)
    t.run_for(@ui.move_most_ms)
  }
  t
}

///|
test "a sign-in in place of its post's words, made once as nodes: waiting with no password manager, 1Password, the autofill; 1Password asked, its logins to pick, sending, none for the site, its servers not reached, the autofill asked, not to be kept; a code asked, a captcha, the agent's word, filling, left, being kept, its keeping failed, another's; kept, not kept, signed in, refused, expired, ended; wide and narrow, at 1.3" {
  for w in [760.0, 390.0] {
    let drawn : Map[String, String] = Map([])
    for c in signin_cases() {
      let t = signin_held(c, w)
      drawn[c.name] = head_drawn(t)
      card_audit(t, "\{c.name} at \{w}", signin_rooms(c.name))
    }
    for c in signin_cases() {
      let from = match c.host {
        OnePassword(_, _, _) => "1Password"
        Autofill => "autofill"
        NoManager => "on screen"
      }
      if c.name != from {
        assert_true(drawn.get(c.name) != drawn.get(from), msg="\{c.name} at \{w}: drawn as \{from}")
      }
    }
  }
  let cases = signin_cases()
  for i in [1, 4, 8, 9] {
    let t = signin_held(cases[i], 390.0, scale=1.3)
    assert_eq(t.fixed_outgrown(), [], msg=cases[i].name)
    card_audit(t, "\{cases[i].name} at 1.3", 0)
  }
}

///|
/// What was asked of the core, each call's name and its params as text.
fn signin_asked(calls : Array[(String, Json)]) -> Array[String] {
  calls.map(fn(c) { c.0 + " " + c.1.stringify() })
}

///|
/// Post `m` on a host `h`, `w` wide, `act` done on the nodes' drawing: what it asked of the core, and its Tester.
fn signin_act_new(
  m : Message,
  h : SignInHost,
  w : Double,
  act : (@ui.Tester) -> Unit raise,
) -> (Array[String], @ui.Tester) raise {
  let now : Array[(String, Json)] = []
  let t = card_new(w, card_src("chat-signin", calls=now), fn() { m }, begun=signin_host(h))
  t.run_for(@ui.move_most_ms)
  act(t)
  (signin_asked(now), t)
}

///|
/// `words` pressed on `t`'s card, then its moment.
fn signin_press(t : @ui.Tester, words : String) -> Unit {
  t.tap_text(words)
  t.run_for(@ui.move_most_ms)
}

///|
/// The card's top-right cancel × pressed, then its moment.
fn signin_press_cancel(t : @ui.Tester) -> Unit raise {
  t.click(Button, label="取消登录")
  t.run_for(@ui.move_most_ms)
}

///|
test "a sign-in on its card, made once as nodes: on screen, signin.self; 1Password's login picked, its account and password sent with signin.fill, kept or not as chosen; the autofill's login as it comes; a code typed, by 继续 and by Enter; the person's step said done; signed in, kept by vault.approve once" {
  let none = signin_post_with()
  let op = OnePassword(signin_two_logins, false, false)
  let s = fn(v : String) { Json::string(v) }
  let cases : Array[(String, Message, SignInHost, (@ui.Tester) -> Unit raise, String)] = [
    ("on screen", none, NoManager, fn(t) { signin_press(t, "在画面中登录") }, "signin.self"),
    ("1Password, the second login", none, op, fn(t) {
      signin_press(t, "用 1Password 登录")
      signin_press(t, "GitHub 工作 · lin-work")
    }, "signin.fill"),
    ("not to keep, 1Password's only login", none, OnePassword(signin_one_login, false, false), fn(t) {
      signin_press(t, "登录后存入密钥库")
      signin_press(t, "不存入密钥库")
      signin_press(t, "用 1Password 登录")
    }, "signin.fill"),
    ("1Password slow, on screen instead", none, OnePassword(signin_two_logins, true, false), fn(t) {
      signin_press(t, "用 1Password 登录")
      signin_press(t, "在画面中登录")
    }, "signin.self"),
    ("autofill", none, Autofill, fn(t) {
      signin_press(t, "用密码管理器登录")
      @ui.fake_autofill_picks("github.com", "lin", "pw")
      t.run_for(@ui.move_most_ms)
    }, "signin.fill"),
    ("the autofill's login of another site", none, Autofill, fn(t) {
      signin_press(t, "用密码管理器登录")
      @ui.fake_autofill_picks("gitlab.com", "lin", "pw")
      t.run_for(@ui.move_most_ms)
    }, ""),
    ("a code by 继续", signin_post_with(more={ "status": s("code") }), NoManager, fn(t) {
      let (x, y) = t.find_last("验证码").unwrap()
      t.tap(x, y)
      t.type_text("123456")
      t.run_for(@ui.move_most_ms)
      signin_press(t, "继续")
    }, "signin.fill"),
    ("a code by Enter", signin_post_with(more={ "status": s("code") }), NoManager, fn(t) {
      let (x, y) = t.find_last("验证码").unwrap()
      t.tap(x, y)
      t.type_text("654321")
      t.enter()
      t.run_for(@ui.move_most_ms)
    }, "signin.fill"),
    ("the person's step", signin_post_with(more={ "status": s("person"), "why": s("blocked") }), NoManager, fn(t) {
      signin_press(t, "我已登录")
    }, "signin.self"),
    ("cancel from asking (no manager)", none, NoManager, fn(t) raise { signin_press_cancel(t) }, "signin.deny"),
    ("cancel from asking (1Password)", none, op, fn(t) raise { signin_press_cancel(t) }, "signin.deny"),
    ("cancel while 1Password slow", none, OnePassword(signin_two_logins, true, false), fn(t) raise {
      signin_press(t, "用 1Password 登录")
      signin_press_cancel(t)
    }, "signin.deny"),
    ("cancel from choosing", none, op, fn(t) raise {
      signin_press(t, "用 1Password 登录")
      signin_press_cancel(t)
    }, "signin.deny"),
    ("cancel while filling", signin_post_with(more={ "status": s("filling") }), NoManager, fn(t) raise {
      signin_press_cancel(t)
    }, "signin.deny"),
    ("cancel from code", signin_post_with(more={ "status": s("code") }), NoManager, fn(t) raise {
      signin_press_cancel(t)
    }, "signin.deny"),
    ("cancel from person", signin_post_with(more={ "status": s("person"), "why": s("blocked") }), NoManager, fn(t) raise {
      signin_press_cancel(t)
    }, "signin.deny"),
    ("cancel from left", signin_post_with(more={ "status": s("left") }), NoManager, fn(t) raise {
      signin_press_cancel(t)
    }, "signin.deny"),
    ("saving", signin_post_with(more={ "status": s("done"), "keep": Json::boolean(true), "save": s("r-save") }), NoManager, fn(t) {
      t.run_for(@ui.move_most_ms)
    }, "vault.approve"),
  ]
  for c in cases {
    let (now, t) = signin_act_new(c.1, c.2, 760.0, c.3)
    let named = now.filter(fn(a) { a.has_prefix("signin.") || a.has_prefix("vault.") })
    if c.4 == "" {
      assert_eq(named, [], msg=c.0)
    } else {
      assert_eq(named.length(), 1, msg=c.0 + ": " + now.join(" | "))
      assert_true(named[0].has_prefix(c.4 + " "), msg=c.0 + ": " + named[0])
    }
    card_audit(t, c.0, 0)
  }
}

///|
test "a sign-in asked of 1Password, made once as nodes: what it is at said as the host's word comes, never asked of it each frame; let go of for the screen, what it would have said taken no more" {
  let t = card_new(760.0, card_src("chat-signin"), fn() { signin_post_with() }, begun=signin_host(OnePassword(signin_two_logins, true, false)))
  t.run_for(@ui.move_most_ms)
  signin_press(t, "用 1Password 登录")
  assert_true(card_has(t, "正在问 1Password…"))
  assert_true(t.get(Button, label="用 1Password 登录").disabled)
  // (while it runs: nothing built again for it, the app at rest)
  assert_true(t.at_rest(), msg=t.rest_why())
  // its list comes: the logins to pick from, at that moment (its buttons fading where they stood as the list comes in
  // their place: at rest a move after the frame that took it)
  @ui.fake_op_pending.val = false
  t.run_for(@ui.move_most_ms)
  t.run_for(@ui.move_most_ms)
  assert_true(card_has(t, "选一个 github.com 的登录"))
  assert_true(card_has(t, "GitHub · lin"))
  assert_true(card_has(t, "GitHub 工作 · lin-work"))
  card_audit(t, "picking", 0)
  // asked again, slow, and let go of for the screen: its note gone, nothing it says after taken
  let t = card_new(760.0, card_src("chat-signin"), fn() { signin_post_with() }, begun=signin_host(OnePassword(signin_two_logins, true, false)))
  t.run_for(@ui.move_most_ms)
  signin_press(t, "用 1Password 登录")
  signin_press(t, "在画面中登录")
  assert_false(card_has(t, "正在问 1Password…"))
  @ui.fake_op_pending.val = false
  t.run_for(@ui.move_most_ms)
  assert_false(card_has(t, "选一个 github.com 的登录"))
  assert_false(t.get(Button, label="用 1Password 登录").disabled)
  card_audit(t, "let go", 0)
}

///|
test "a sign-in decided as its card shows, made once as nodes: the card goes, the line saying how it went in its place; pressed, what was asked read again" {
  @sf.presenters_reset()
  let m = @signals.signal(signin_post_with())
  let t = card_new(390.0, card_src("chat-signin"), fn() { m.get() }, begun=signin_host(NoManager))
  t.run_for(@ui.move_most_ms)
  assert_true(card_has(t, "在画面中登录"))
  m.set(signin_post_with(more={ "status": Json::string("done"), "keep": Json::boolean(true), "save": Json::string("r-save"), "kept": Json::string("granted") }))
  t.run_for(@ui.move_most_ms)
  assert_false(card_has(t, "在画面中登录"))
  assert_false(card_has(t, "查看 PR #512 的 Actions 日志"))
  let line = "已登录 github.com · 已存入密钥库"
  assert_true(card_has(t, line))
  card_audit(t, "decided", signin_rooms("kept"))
  t.click(Button, label=line + " · " + @sf.t("web-main.history.details"))
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting())
  assert_true(card_has(t, "登录 github.com"))
  assert_true(card_has(t, "查看 PR #512 的 Actions 日志"))
  @sf.close_all_presented()
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
}

///|
test "many 1Password logins including a long OAuth username: stacked top to bottom in 1Password's order, cut to one line inside the card, with 在画面中登录 and 登录后存入密钥库 kept below" {
  let many = "[{\"id\":\"gh1\",\"title\":\"GitHub\",\"additional_information\":\"lin@example.com\",\"urls\":[{\"href\":\"https://github.com\"}]},{\"id\":\"gh2\",\"title\":\"GitHub\",\"additional_information\":\"lin.personal@example.com\",\"urls\":[{\"href\":\"https://github.com/login\"}]},{\"id\":\"gh3\",\"title\":\"GitHub\",\"additional_information\":\"team1@example.com\",\"urls\":[{\"href\":\"https://github.com\"}]},{\"id\":\"gh4\",\"title\":\"GitHub\",\"additional_information\":\"team2@example.com\",\"urls\":[{\"href\":\"https://github.com\"}]},{\"id\":\"gh5\",\"title\":\"GitHub OAuth\",\"additional_information\":\"524783491799-i2nuidv1m2jssguh64lopn8g1kd7a8oe.apps.example.com\",\"urls\":[{\"href\":\"https://github.com\"}]}]"
  let c : SignInCase = {
    name: "five logins with long oauth",
    post: signin_post_with(),
    host: OnePassword(many, false, false),
    presses: ["用 1Password 登录"],
    fails: false,
  }
  for w in [760.0, 390.0] {
    let t = signin_held(c, w)
    assert_eq(t.fixed_outgrown(), [], msg="outgrown at \{w}")
    card_audit(t, "five logins at \{w}", 0)
    let y1 = t.find_last("GitHub · lin@example.com").unwrap().1
    let y2 = t.find_last("GitHub · lin.personal@example.com").unwrap().1
    let y3 = t.find_last("GitHub · team1@example.com").unwrap().1
    let y4 = t.find_last("GitHub · team2@example.com").unwrap().1
    let y5 = t.find_last("GitHub OAuth").unwrap().1
    let y_self = t.find_last("在画面中登录").unwrap().1
    let y_keep = t.find_last("登录后存入密钥库").unwrap().1
    assert_true(y1 < y2 && y2 < y3 && y3 < y4 && y4 < y5, msg="top-to-bottom order: \{y1},\{y2},\{y3},\{y4},\{y5}")
    assert_true(y5 < y_self && y5 < y_keep, msg="actions below choices: \{y5} vs \{y_self},\{y_keep}")
  }
  let t = signin_held(c, 390.0, scale=1.3)
  assert_eq(t.fixed_outgrown(), [], msg="outgrown at 390 1.3")
  card_audit(t, "five logins at 390 1.3", 0)
}


///|
/// How opaque `words` are drawn on `t` now (the last drawn so), none where they are not.
fn signin_seen(t : @ui.Tester, words : String) -> Double? {
  let mut seen : Double? = None
  for w in t.words() {
    if w.0 == words {
      seen = Some(w.5)
    }
  }
  seen
}

///|
test "a sign-in's card made once as nodes moves on without a jump: 1Password's logins come in place of its buttons as those fade where they stood; ended, the card fades where it stood as the line saying how it went takes its place" {
  @sf.presenters_reset()
  let m = @signals.signal(signin_post_with())
  let t = card_new(760.0, card_src("chat-signin"), fn() { m.get() }, begun=signin_host(OnePassword(signin_two_logins, false, false)))
  t.run_for(@ui.move_most_ms)
  assert_eq(signin_seen(t, "用 1Password 登录"), Some(1.0))
  // 1Password asked: its logins to pick from, its buttons before fading as they go, never gone in that frame
  t.tap_text("用 1Password 登录")
  t.run_for(@sf.leave_ms / 2.0)
  let half = signin_seen(t, "用 1Password 登录")
  assert_true(half is Some(a) && a > 0.0 && a < 1.0, msg="its button half way out: \{Repr(half)}")
  t.run_for(@ui.move_most_ms)
  assert_true(signin_seen(t, "用 1Password 登录") is None, msg="its button not gone")
  assert_eq(signin_seen(t, "GitHub · lin"), Some(1.0))
  assert_eq(signin_seen(t, "GitHub 工作 · lin-work"), Some(1.0))
  // ended: the card fading where it stood, the line in its place once it is gone
  m.set(signin_post_with(more={ "status": Json::string("done"), "keep": Json::boolean(false) }))
  @ui.came_from_outside()
  t.run_for(@sf.leave_ms / 2.0)
  let half = signin_seen(t, "GitHub · lin")
  assert_true(half is Some(a) && a > 0.0 && a < 1.0, msg="the card half way out: \{Repr(half)}")
  t.run_for(@ui.move_most_ms)
  assert_true(signin_seen(t, "GitHub · lin") is None, msg="the card not gone")
  assert_true(t.words().iter().any(fn(w) { w.0.has_prefix("已登录 github.com") }), msg="\{Repr(t.words().map(fn(w) { w.0 }))}")
  card_audit(t, "ended", 0)
}

///|
test "a sign-in ended as its card is made, made once as nodes: the line saying how it went there at once, no card fading over it" {
  @sf.presenters_reset()
  let t = card_new(760.0, card_src("chat-signin"), fn() {
    signin_post_with(more={ "status": Json::string("done"), "keep": Json::boolean(false) })
  }, begun=signin_host(NoManager))
  t.draw()
  assert_true(t.words().iter().any(fn(w) { w.0.has_prefix("已登录 github.com") }), msg="\{Repr(t.words().map(fn(w) { w.0 }))}")
  assert_true(signin_seen(t, "在画面中登录") is None)
}

///|
test "sign-in card reads username, password and inline TOTP from one op item get with --vault and skips --otp" {
  let calls : Array[(String, Json)] = []
  let t = card_new(760.0, signin_src(calls~), fn() { signin_post_with() }, begun=fn() {
    signin_reset()
    @sf.presenters_reset()
    @ui.fake_op_runs.clear()
    @ui.fake_op.val = Some(fn(args) {
      if args.contains("list") {
        (0, "[{\"id\":\"gh1\",\"title\":\"GitHub\",\"additional_information\":\"lin\",\"vault\":{\"id\":\"v1\"},\"urls\":[{\"href\":\"https://github.com\"}]}]", "")
      } else {
        (0, "{\"id\":\"gh1\",\"fields\":[{\"id\":\"username\",\"purpose\":\"USERNAME\",\"value\":\"lin\"},{\"id\":\"password\",\"purpose\":\"PASSWORD\",\"value\":\"s3cret\"},{\"id\":\"otp\",\"type\":\"OTP\",\"totp\":\"246810\"}]}", "")
      }
    })
  })
  t.run_for(@ui.move_most_ms)
  signin_press(t, "用 1Password 登录")
  t.run_for(@ui.move_most_ms)
  assert_eq(@ui.fake_op_runs.length(), 2)
  assert_eq(@ui.fake_op_runs[0], ["item", "list", "--categories", "Login", "--format", "json"])
  assert_eq(@ui.fake_op_runs[1], ["item", "get", "gh1", "--vault", "v1", "--reveal", "--format", "json"])
  let fills = calls.filter(fn(c) { c.0 == "signin.fill" })
  assert_eq(fills.length(), 1)
  let login = field(Some(fills[0].1), "login")
  assert_eq(text(login, "username"), "lin")
  assert_eq(text(login, "password"), "s3cret")
  assert_eq(text(login, "code"), "246810")
  @ui.fake_op.val = None
}

///|
test "cancelling a sign-in card stops 1Password, disables buttons while in flight, recovers on error, and settles on denied or withdrawn" {
  @sf.presenters_reset()
  let calls : Array[(String, Json)] = []
  let fail_deny = Ref(true)
  let base = card_src("chat-signin", calls~)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      (base.call)(name, params, done)
      if name == "signin.deny" && fail_deny.val {
        done(Err(Json::string("the sign-in is done already")))
      }
    },
  }
  let m = @signals.signal(signin_post_with())
  let t = card_new(760.0, src, fn() { m.get() }, begun=signin_host(OnePassword(signin_two_logins, true, false)))
  t.run_for(@ui.move_most_ms)
  // Start 1Password (pending), then cancel: op is stopped, error recovers button state
  signin_press(t, "用 1Password 登录")
  assert_true(card_has(t, "正在问 1Password…"))
  t.click(Button, label="取消登录")
  t.run_for(@ui.move_most_ms)
  assert_false(card_has(t, "正在问 1Password…"))
  assert_eq(calls.filter(fn(c) { c.0 == "signin.deny" }).length(), 1)
  assert_false(t.get(Button, label="取消登录").disabled)
  assert_false(t.get(Button, label="用 1Password 登录").disabled)
  // Next cancel stays in flight: buttons disable until the station settles the card
  fail_deny.val = false
  t.click(Button, label="取消登录")
  t.run_for(@ui.move_most_ms)
  assert_eq(calls.filter(fn(c) { c.0 == "signin.deny" }).length(), 2)
  assert_true(t.get(Button, label="取消登录").disabled)
  assert_true(t.get(Button, label="用 1Password 登录").disabled)
  assert_true(t.get(Button, label="在画面中登录").disabled)
  // Settled as denied: card collapses to outcome line
  m.set(signin_post_with(more={ "status": Json::string("denied") }))
  t.run_for(@ui.move_most_ms)
  assert_true(card_has(t, "已取消登录 github.com"))
  card_audit(t, "denied outcome", 0)
  // Settled as withdrawn by agent: card collapses to withdrawn outcome line
  let m2 = @signals.signal(signin_post_with())
  let t2 = card_new(760.0, card_src("chat-signin"), fn() { m2.get() }, begun=signin_host(NoManager))
  t2.run_for(@ui.move_most_ms)
  m2.set(signin_post_with(more={ "status": Json::string("withdrawn") }))
  t2.run_for(@ui.move_most_ms)
  assert_true(card_has(t2, "agent 已撤回登录 github.com"))
  card_audit(t2, "withdrawn outcome", 0)
}
