// A web page left out of an upgraded workspace that nobody can approve there (the core's `me.needsAppText`: its person
// has no app in the list; the owner, 2026-11-13: 「开了安全模式那就需要 app」): in the workspace's place (the waiting
// page, sfpages' lock_wait_node.mbt) and on 安全 (security.mbt), under the title 请先安装客户端 the
// core's words in place of the ask to be approved, no word of waiting or of a trusted device (there is none) and no
// button that asks (nobody could answer it), on every screen; every rule of the Tester's audit
// clean in what those pages make (the frame's own faults around them, its rail's and its edges', are those its other
// lock screens show, lock-waiting's, and held by the sweeps' known lists).

///|
/// The words the fixture gives as the core's (core-misc.lock.needsApp), a piece of them as a line holds it.
let needs_app_piece : String = "请安装桌面或手机客户端并登录"

///|
test "a web page nobody can approve: the core's words where the ask would be, no button that asks, on every screen" {
  let faults : Array[String] = []
  for mode in ["lock-needs-app", "lock-needs-app-security"] {
    for win in corner_windows {
      let t = screen_in(mode, win, "zh")
      let words = t.words().map(fn(w) { w.0 }).join("")
      let at = "\{mode} \{win.0}"
      assert_true(words.contains(needs_app_piece), msg="\{at}: the core's words drawn (\{words})")
      assert_true(!words.contains(@sf.t("web-pages.security.request")), msg="\{at}: no button that asks")
      assert_true(!words.contains(@sf.t("web-pages.security.notAsked")), msg="\{at}: no word of asking")
      // (nothing waits and this person has no trusted device: the page says neither, its title says what to do)
      assert_true(words.contains(@sf.t("web-pages.security.needsAppTitle")), msg="\{at}: 请先安装客户端 its title (\{words})")
      assert_true(!words.contains(@sf.t("web-pages.security.waitingTitle")), msg="\{at}: not 等待批准此设备")
      assert_true(!words.contains("新设备需由你的受信任设备批准"), msg="\{at}: no word of a trusted device")
      for f in t.audit() {
        if f.contains("sfpages/lock_wait") || f.contains("sfpages/security") {
          faults.push("\{at}: \{f}")
        }
      }
    }
  }
  if faults.length() > 0 {
    println(faults.join("\n"))
  }
  assert_eq(faults, [])
}

///|
/// The words the fixture gives as the core's (core-misc.lock.out), a piece of them as a line holds it.
let out_piece : String = "将你移出了此 workspace 的安全模式"

///|
test "its person taken out of an upgraded workspace: who and when, and whom to ask, above the ask for once added back, on every screen" {
  let faults : Array[String] = []
  for mode in ["lock-out", "lock-out-security"] {
    for win in corner_windows {
      let t = screen_in(mode, win, "zh")
      let words = t.words().map(fn(w) { w.0 }).join("")
      let at = "\{mode} \{win.0}"
      assert_true(words.contains(out_piece), msg="\{at}: the core's words drawn (\{words})")
      // (the ask still there: once added back, it is how this device comes in again)
      assert_true(words.contains(@sf.t("web-pages.security.request")), msg="\{at}: the ask (\{words})")
      assert_true(!words.contains(@sf.t("web-pages.security.needsAppTitle")), msg="\{at}: not 请先安装客户端")
      for f in t.audit() {
        if f.contains("sfpages/lock_wait") || f.contains("sfpages/security") {
          faults.push("\{at}: \{f}")
        }
      }
    }
  }
  if faults.length() > 0 {
    println(faults.join("\n"))
  }
  assert_eq(faults, [])
}

///|
/// The core's words the fixture gives where its person's own lock is begun anew here, made so, and begun elsewhere
/// (core-misc.lock.restartNote, reboundOwner; android-misc.personal.replaced.note), a piece of each as a line holds it.
let restart_piece : String = "这台设备会成为你唯一的受信任设备"

///|
let rebound_piece : String = "先将你移出再重新添加"

///|
let replaced_piece : String = "你的账号可能已经被盗"

///|
/// `t` (a screen of `win`) scrolled (the wheel over its middle) till `words` stand clear of the window's edges.
fn scroll_seen(t : @ui.Tester, win : (String, Double, Double, Int, String), words : String) -> Unit {
  let (_, w, h, _, _) = win
  t.move_to(w / 2.0, h / 2.0)
  for _ in 0..<12 {
    match t.find(words) {
      Some((_, y)) if y < 40.0 => t.wheel(w / 2.0, h / 2.0, -300.0)
      Some((_, y)) if y < h - 60.0 => break
      _ => t.wheel(w / 2.0, h / 2.0, 300.0)
    }
  }
  t.run_for(@ui.move_most_ms)
}

///|
/// Presses the button `words` in `t` (a screen of `win`), the page scrolled first till it stands clear of its edges.
fn tap_seen(t : @ui.Tester, win : (String, Double, Double, Int, String), words : String) -> Unit {
  scroll_seen(t, win, words)
  t.click(Button, label=words)
}

///|
/// The audit's faults of what the waiting page and 安全 make in `t`, said where (`at`).
fn lock_own_faults(t : @ui.Tester, at : String, faults : Array[String]) -> Unit {
  for f in t.audit() {
    if f.contains("sfpages/lock_wait") || f.contains("sfpages/security") {
      faults.push("\{at}: \{f}")
    }
  }
}

///|
test "none of its person's devices answering: they are listed, a phone and a computer, and 我的其它设备都不在了 offered beside the ask; pressed on the waiting page, it says whom to ask and asks nothing, on every screen" {
  let faults : Array[String] = []
  for mode in ["lock-restart", "lock-restart-security"] {
    for win in corner_windows {
      let t = screen_in(mode, win, "zh")
      let at = "\{mode} \{win.0}"
      let words = t.words().map(fn(w) { w.0 }).join("")
      assert_true(words.contains(@sf.t("web-pages.security.request")), msg="\{at}: the ask (\{words})")
      assert_true(words.contains("我的其它设备都不在了"), msg="\{at}: the way out offered (\{words})")
      assert_true(words.contains(restart_piece), msg="\{at}: what it does (\{words})")
      assert_true(words.contains("Pixel 9") && words.contains("林的 MacBook Pro"), msg="\{at}: whom it asked (\{words})")
      scroll_seen(t, win, "林的 MacBook Pro")
      assert_true(t.locate("icon:phone").length() >= 1 && t.locate("icon:monitor").length() >= 1, msg="\{at}: a phone and a computer")
      lock_own_faults(t, at, faults)
      // (the ask kept at the card's foot, the way out over it where the two have not the room side by side)
      match (t.find(@sf.t("web-pages.security.request")), t.find("我的其它设备都不在了")) {
        (Some((rx, ry)), Some((ox, oy))) =>
          if mode.has_suffix("-security") {
            assert_true(oy <= ry + 0.5, msg="\{at}: the ask not over the way out (\{rx},\{ry} \{ox},\{oy})")
          } else {
            assert_true(oy >= ry - 0.5, msg="\{at}: the ask first (\{rx},\{ry} \{ox},\{oy})")
          }
        _ => fail("\{at}: both drawn")
      }
      // (pressed on the waiting page here; on 安全 by the page's own harness, security_wbtest.mbt)
      if mode.has_suffix("-security") {
        continue
      }
      tap_seen(t, win, "我的其它设备都不在了")
      t.run_for(@ui.move_most_ms)
      let after = t.words().map(fn(w) { w.0 }).join("")
      assert_true(after.contains(rebound_piece), msg="\{at}: whom to ask once pressed (\{after})")
      assert_true(!after.contains(@sf.t("web-pages.security.request")), msg="\{at}: nothing to ask then (\{after})")
      assert_true(!after.contains("我的其它设备都不在了"), msg="\{at}: the way out taken (\{after})")
      lock_own_faults(t, "\{at} pressed", faults)
    }
  }
  if faults.length() > 0 {
    println(faults.join("\n"))
  }
  assert_eq(faults, [])
}

///|
test "made its person's only trusted device: whom to ask, no button, on every screen" {
  let faults : Array[String] = []
  for mode in ["lock-rebound", "lock-rebound-security"] {
    for win in corner_windows {
      let t = screen_in(mode, win, "zh")
      let at = "\{mode} \{win.0}"
      let words = t.words().map(fn(w) { w.0 }).join("")
      assert_true(words.contains(rebound_piece), msg="\{at}: whom to ask (\{words})")
      assert_true(words.contains("stillfail lock reset"), msg="\{at}: an owner's way out (\{words})")
      assert_true(!words.contains(@sf.t("web-pages.security.request")), msg="\{at}: no ask")
      lock_own_faults(t, at, faults)
    }
  }
  if faults.length() > 0 {
    println(faults.join("\n"))
  }
  assert_eq(faults, [])
}

///|
test "its person's own lock begun anew on another device: what happened, never 已确认, 是我做的，继续 alone; pressed on the waiting page, the ask to join, on every screen" {
  let faults : Array[String] = []
  for mode in ["lock-replaced", "lock-replaced-security"] {
    for win in corner_windows {
      let t = screen_in(mode, win, "zh")
      let at = "\{mode} \{win.0}"
      let words = t.words().map(fn(w) { w.0 }).join("")
      assert_true(words.contains("你的受信任设备被重新设置过"), msg="\{at}: what happened (\{words})")
      assert_true(words.contains(replaced_piece), msg="\{at}: what it means (\{words})")
      assert_true(!words.contains(@sf.t("web-pages.security.request")), msg="\{at}: nothing asked before it")
      lock_own_faults(t, at, faults)
      if mode.has_suffix("-security") {
        continue
      }
      tap_seen(t, win, "是我做的，继续")
      t.run_for(@ui.move_most_ms)
      let after = t.words().map(fn(w) { w.0 }).join("")
      assert_true(after.contains(@sf.t("web-pages.security.request")), msg="\{at}: the ask to join once pressed (\{after})")
      assert_true(!after.contains(replaced_piece), msg="\{at}: what happened said no more (\{after})")
      lock_own_faults(t, "\{at} pressed", faults)
    }
  }
  if faults.length() > 0 {
    println(faults.join("\n"))
  }
  assert_eq(faults, [])
}
