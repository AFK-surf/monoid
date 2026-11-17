// A station's screen in a window of this run beside the first (sfbase's window.mbt, mbui's window_slots.mbt), as the
// Mac opens one: its view handed over as it was (no `screen.view` asked again, none closed, the frame it showed drawn in
// the window's first frame), what is presented in each window that window's alone, a way to the screen again in the
// first bringing the window to the front with a toast there; the window closed, its view let go of then.

///|
/// The rig's viewer with keyboard and mouse, live, its windows opening in the run: each window beside the first the page
/// it shows alone (as the app's lone_window_tree), the presenters and the toasts over it.
fn window_rig(layered? : Bool = false) -> ScreenRig {
  let r = if layered {
    let r = screen_rig(w=1280.0, h=800.0, platform=0, h264=true)
    r.t.run_for(@sf.later_ms)
    r
  } else {
    mouse_rig()
  }
  r.t.set_window_opens(true)
  r.t.set_windows_in_process(true)
  r.t.set_window_beside_size(1, rig_w, rig_h)
  if layered {
    r.layered() |> ignore
  } else {
    r.live(others=[])
  }
  let src = r.sess().src
  @ui.set_window_tree(
    fn(wid, _) {
      fn(root) {
        @sfbase.lone_page.val = @sfbase.window_here_page(wid)
        @sfbase.lone_shown.val.set(@sfbase.lone_page.val)
        @ui.set_tree_theme(@sf.ui_theme_now)
        // (made again for another page put in its place, as the app's lone_tree)
        let shown = @sfbase.lone_shown.val
        root.pick(at_once=true, fn() {
          match shown.get() {
            Some(Screen(at)) => Some(at)
            _ => None
          }
        }, fn(p, at) {
          p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          match at {
            Some(at) =>
              screen_node(p, src, at, fn() { @sf.no_frame }, on_close=fn() {
                p.at_moment(p.logic_at(), fn() { @ui.window_close_here(wid) }) |> ignore
              })
            None => ()
          }
        })
        @ui.old(root, fn(c) { @sf.presented(c) }).over(Is(true)) |> @ui.old_takes_own |> ignore
        @sf.presented_nodes(root)
        @sfbase.toasts_node(root, fn() { @sf.toast_bottom }) |> ignore
      }
    },
    around=fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
  )
  r
}

///|
/// The words window `wid` of the rig shows now (0 the first).
fn window_words(r : ScreenRig, wid : Int) -> Array[String] {
  let out = Ref([])
  r.t.in_window(wid, fn() { out.val = r.t.words().map(fn(w) { w.0 }) })
  out.val
}

///|
/// What window `wid` of the rig draws now, as the Tester lists it.
fn window_drawn(r : ScreenRig, wid : Int) -> String {
  let out = Ref("")
  r.t.in_window(wid, fn() { out.val = r.t.drawlist() })
  out.val
}

///|
/// The rig's screen sent to a window of its own from 控制中心's 在新窗口打开, in the first window.
fn window_popped(r : ScreenRig) -> Unit {
  r.tap_label(tr("web-pages.screen.panel"))
  r.t.run_for(@sf.later_ms)
  r.t.tap_text("在新窗口打开")
}

///|
test "在新窗口打开 on the Mac: a window of this run shows the screen in its first frame, its view handed over, never asked again" {
  let r = window_rig()
  let key = screen_key("ws-1/st-1", "browser:tab-1")
  let view = r.sess().view
  assert_true(window_drawn(r, 0).contains("stream 1280x720"), msg="the picture shown here first")
  window_popped(r)
  // the window open, its first frame drawn by the tap's: the viewer's bar and the picture it showed here, nothing
  // connecting or starting
  assert_eq(r.t.windows_beside().length(), 1)
  let wid = r.t.windows_beside()[0].0
  assert_eq(r.t.windows_opened(), [], msg="no run of its own started")
  let first = window_words(r, wid)
  assert_true(first.iter().any(fn(w) { w.contains("Chrome") }), msg="\{Repr(first)}")
  assert_true(!first.contains("正在连接"), msg="\{Repr(first)}")
  assert_true(window_drawn(r, wid).contains("stream 1280x720"), msg="the frame decoded here drawn there at once")
  nav_rested(r.t)
  // it left this window; the view the same one, open still: not asked again, not closed, not let go of
  assert_true(!(app.nav.top() is Screen(_)))
  assert_true(!window_drawn(r, 0).contains("stream 1280x720"))
  assert_eq(r.told("screen.view").length(), 1)
  assert_eq(r.cancelled, [])
  assert_true(screens_open.contains(key))
  assert_eq(r.sess().view, view)
  assert_true(window_drawn(r, wid).contains("stream 1280x720"))
  // the frames that come next are acknowledged and drawn there
  r.frame(1100.0)
  assert_true(r.acked(1100.0))
  assert_true(window_drawn(r, wid).contains("stream 1280x720"))
}

///|
test "what is presented in a window of its own is that window's: 控制中心 opened there is drawn there alone" {
  let r = window_rig()
  window_popped(r)
  nav_rested(r.t)
  let wid = r.t.windows_beside()[0].0
  assert_true(!window_words(r, wid).contains("全屏"))
  r.t.in_window(wid, fn() { r.tap_label(tr("web-pages.screen.panel")) })
  r.t.run_for(@sf.later_ms)
  assert_true(window_words(r, wid).contains("全屏"), msg="\{Repr(window_words(r, wid))}")
  assert_true(!window_words(r, 0).contains("全屏"), msg="\{Repr(window_words(r, 0))}")
}

///|
test "the screen asked for again in the first window: its window to the front, the toast in the first window alone" {
  let r = window_rig()
  window_popped(r)
  nav_rested(r.t)
  let wid = r.t.windows_beside()[0].0
  @sfbase.open_page(Screen({ station: "ws-1/st-1", screen: "browser:tab-1", title: "", until_gone: false }))
  r.t.draw()
  assert_eq(r.t.window_ids_fronted(), [wid])
  assert_true(!(app.nav.top() is Screen(_)), msg="not opened here as well")
  assert_eq(@sfbase.toast_words(), "这个屏幕已在独立窗口中打开")
  let beside = Ref("")
  r.t.in_window(wid, fn() { beside.val = @sfbase.toast_words() })
  assert_eq(beside.val, "")
  r.t.run_for(@sf.later_ms)
  assert_true(window_words(r, 0).contains("这个屏幕已在独立窗口中打开"))
  assert_true(!window_words(r, wid).contains("这个屏幕已在独立窗口中打开"))
}

///|
test "the window of its own closed: its view let go of then, once; the first window goes on and opens the screen anew" {
  let r = window_rig()
  let key = screen_key("ws-1/st-1", "browser:tab-1")
  window_popped(r)
  nav_rested(r.t)
  let wid = r.t.windows_beside()[0].0
  assert_eq(r.cancelled, [])
  r.t.close_window_beside(wid)
  r.t.draw()
  assert_eq(r.t.windows_beside(), [])
  assert_eq(r.cancelled.length(), 1)
  assert_true(!screens_open.contains(key))
  // the first window as it was; the screen opened here again asks for a view of its own
  @sfbase.open_page(Screen({ station: "ws-1/st-1", screen: "browser:tab-1", title: "Chrome", until_gone: false }))
  nav_rested(r.t)
  assert_true(app.nav.top() is Screen(_))
  assert_eq(r.told("screen.view").length(), 2)
}

///|
test "the window of its own has no way back; 控制中心's 断开 closes the window, not the run, its view let go of" {
  let r = window_rig()
  let key = screen_key("ws-1/st-1", "browser:tab-1")
  window_popped(r)
  nav_rested(r.t)
  let wid = r.t.windows_beside()[0].0
  // (nowhere to go back to: its window's own close and 断开 close it; the first window's page has its way back)
  let back = Ref(None)
  r.t.in_window(wid, fn() { back.val = r.labelled(tr("common.back")) })
  assert_true(back.val is None, msg="a way back in a window of its own")
  r.t.in_window(wid, fn() { r.tap_label(tr("web-pages.screen.panel")) })
  r.t.run_for(@sf.later_ms)
  r.t.in_window(wid, fn() { r.t.tap_text("断开") })
  r.t.run_for(@ui.move_most_ms)
  assert_eq(r.t.window_ids_closed(), [wid])
  assert_eq(r.t.windows_beside(), [])
  assert_true(!screens_open.contains(key))
  assert_eq(r.cancelled.length(), 1)
}

///|
test "a child popup followed in the window of its own: the tab it left let go of, a way to the popup fronting the window, the popup let go of as it closes" {
  let r = window_rig()
  window_popped(r)
  nav_rested(r.t)
  let wid = r.t.windows_beside()[0].0
  assert_eq(r.cancelled, [])
  r.state(
    "live",
    more={
      "childOpened": Json::number(1.0),
      "childScreen": Json::string("browser:oauth-1"),
      "childTitle": Json::string("Sign in with Google"),
    },
  )
  nav_rested(r.t)
  // the window shows the popup now: the tab it left no window's, its view let go of
  let shown = Ref(None)
  r.t.in_window(wid, fn() { shown.val = @sfbase.lone_page.val })
  match shown.val {
    Some(Screen(at)) => assert_eq(at.screen, "browser:oauth-1")
    _ => fail("expected the popup in the window of its own")
  }
  assert_true(!screens_open.contains(screen_key("ws-1/st-1", "browser:tab-1")))
  assert_eq(r.cancelled.length(), 1)
  assert_true(!(app.nav.top() is Screen(_)))
  // a way to the popup in the first window: the window to the front, not opened here
  @sfbase.open_page(Screen({ station: "ws-1/st-1", screen: "browser:oauth-1", title: "", until_gone: false }))
  r.t.draw()
  assert_eq(r.t.window_ids_fronted(), [wid])
  assert_true(!(app.nav.top() is Screen(_)))
  // the window closed: the popup's view let go of
  r.t.close_window_beside(wid)
  r.t.draw()
  assert_true(!screens_open.contains(screen_key("ws-1/st-1", "browser:oauth-1")))
  assert_eq(r.cancelled.length(), 2)
}

///|
/// The places the rig's host was told of its native views since `from`: each line, whether it says the window it was
/// told in (a window beside the first) and whether it hid the view.
fn places_since(r : ScreenRig, from : Int) -> Array[String] {
  r.t.views()[from:].to_owned().filter(fn(l) { l.has_prefix("place ") })
}

///|
test "on the Mac's video layer, popped from the screen's page: the layer goes to the window in its first frame, the page going here never takes it back nor hides it" {
  let r = window_rig(layered=true)
  assert_true(r.sess().stream.unwrap().layered())
  r.tap_label(tr("web-pages.screen.panel"))
  r.t.run_for(@sf.later_ms)
  let from = r.t.views().length()
  // every frame the first window draws as its page goes: no hole of the layer in it
  let holes_here = Ref(0)
  r.t.each_frame(Some(fn() { holes_here.val += r.t.holes().length() }))
  r.t.tap_text("在新窗口打开")
  let wid = r.t.windows_beside()[0].0
  // (the tap's frame, the window's first: the layer shown there)
  let first = places_since(r, from)
  assert_true(first.iter().any(fn(l) { l.has_suffix("window \{wid}") && !l.contains("hidden") }), msg="\{Repr(first)}")
  nav_rested(r.t)
  r.t.each_frame(None)
  let all = places_since(r, from)
  assert_true(all.iter().all(fn(l) { l.has_suffix("window \{wid}") }), msg="placed by the first window: \{Repr(all)}")
  assert_true(!all.last().unwrap().contains("hidden"), msg="\{Repr(all)}")
  assert_eq(holes_here.val, 0)
  let there = Ref(0)
  r.t.in_window(wid, fn() { there.val = r.t.holes().length() })
  assert_eq(there.val, 1)
  assert_eq(r.cancelled, [])
}
