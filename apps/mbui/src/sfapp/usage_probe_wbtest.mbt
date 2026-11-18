///|
fn uprobe_at(t : @ui.Tester, tag : String) -> Unit {
  let ys = ["折合费用 · 近 7 天", "花费明细", "今天", "只看 Ana", "只看 林", "整理发布清单", "已删除的对话（14 个）", "林 · Opus 5.5 · Willow", "$50", "$118"].map(fn(w) {
    match t.rect_of(w) {
      Some(r) => "\{w}@\{r.1}+\{r.3}"
      None => "\{w}:none"
    }
  })
  let mut low = ("", -1.0e9)
  for w in t.words() {
    if w.2 > low.1 && w.2 < 760.0 && w.1 >= 0.0 && w.1 < 390.0 {
      low = (w.0, w.2)
    }
  }
  println("probe \{tag}: \{ys.join(" | ")} || lowest \{low.0}@\{low.1}")
}

///|
fn uprobe_tap(t : @ui.Tester, words : String) -> Unit {
  match t.words().iter().find_first(fn(w) { w.0 == words && w.2 > 60.0 && w.2 < 740.0 }) {
    Some(w) => t.tap(w.1 + 4.0, w.2 + 4.0)
    None => println("probe: no \{words} on screen")
  }
}

///|
fn uprobe_end(t : @ui.Tester, tag : String) -> Unit {
  for _ in 0..<3 {
    t.drag(180.0, 650.0, 180.0, 150.0, steps=20)
    t.run_for(kept_glide_over_ms)
  }
  uprobe_at(t, tag + " (at its end)")
  if tag.has_prefix("D") {
    let ws = t.words().filter(fn(w) { w.1 >= 0.0 && w.1 < 390.0 && w.2 > -50.0 && w.2 < 900.0 }).map(fn(w) { "\{w.0}@\{w.2.to_int()}" })
    println("words \{tag}: \{ws.join(" / ")}")
  }
}

///|
fn uprobe_open() -> @ui.Tester {
  new_run()
  let src = fixture("home")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  bars_picked.set(Some(([kept_bar], 0)))
  t.run_for(kept_switch_over_ms)
  kept_go(t, "usage", true)
  t.run_for(kept_switch_over_ms)
  t
}

///|
test "usage probe: a person picked in the legend" {
  let t = uprobe_open()
  uprobe_at(t, "L opened")
  uprobe_end(t, "L none picked")
  let t = uprobe_open()
  uprobe_tap(t, "Ana")
  t.run_for(kept_switch_over_ms)
  uprobe_at(t, "L Ana picked")
  uprobe_end(t, "L Ana picked")
  t.drag(180.0, 250.0, 180.0, 550.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_at(t, "L Ana picked, back up 300")
  uprobe_tap(t, "只看 Ana")
  t.run_for(kept_switch_over_ms)
  uprobe_end(t, "L let go")
}

///|
test "usage probe: a person picked in the breakdown" {
  let t = uprobe_open()
  t.drag(180.0, 600.0, 180.0, 300.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_tap(t, "人")
  t.run_for(kept_switch_over_ms)
  uprobe_at(t, "B people tab")
  uprobe_tap(t, "林")
  t.run_for(kept_switch_over_ms)
  uprobe_at(t, "B 林 picked")
  uprobe_end(t, "B 林 picked")
}

///|
fn uprobe_b() -> @ui.Tester {
  let t = uprobe_open()
  t.drag(180.0, 600.0, 180.0, 300.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_tap(t, "人")
  t.run_for(kept_switch_over_ms)
  uprobe_tap(t, "林")
  t.run_for(kept_switch_over_ms)
  t
}

///|
test "usage probe: after a row's pick, dragged elsewhere or after another tap" {
  let t = uprobe_b()
  t.drag(180.0, 300.0, 180.0, 100.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_at(t, "B2 dragged from 300")
  t.drag(180.0, 100.0, 180.0, 500.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_at(t, "B2 dragged down from 100")
  let t = uprobe_b()
  t.tap(380.0, 30.0)
  t.run_for(kept_switch_over_ms)
  t.drag(180.0, 650.0, 180.0, 150.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_at(t, "B3 after another tap")
  let t = uprobe_b()
  t.wheel(180.0, 400.0, 300.0)
  t.run_for(kept_glide_over_ms)
  uprobe_at(t, "B4 wheel 300")
}

///|
test "usage probe: isolate" {
  // legend picked after a scroll
  let t = uprobe_open()
  t.drag(180.0, 600.0, 180.0, 450.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_at(t, "C1 scrolled 150")
  uprobe_tap(t, "Ana")
  t.run_for(kept_switch_over_ms)
  uprobe_end(t, "C1 legend after scroll")
  // a row picked unscrolled, chats tab (a chat row opens a chat: use the people tab)
  let t = uprobe_open()
  uprobe_tap(t, "人")
  t.run_for(kept_switch_over_ms)
  uprobe_at(t, "C2 people tab, top")
  uprobe_tap(t, "Ana")
  t.run_for(kept_switch_over_ms)
  uprobe_end(t, "C2 legend at top, people tab")
  // people tab, scrolled, legend's pick by setting the pick (no press)
  let t = uprobe_open()
  t.drag(180.0, 600.0, 180.0, 300.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_tap(t, "人")
  t.run_for(kept_switch_over_ms)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfpages.usage_only_for_test(("people", "lin@example.com")) })
  t.run_for(kept_switch_over_ms)
  uprobe_end(t, "C3 set, people tab, scrolled")
  let t = uprobe_open()
  t.drag(180.0, 600.0, 180.0, 300.0, steps=20)
  t.run_for(kept_glide_over_ms)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfpages.usage_only_for_test(("people", "lin@example.com")) })
  t.run_for(kept_switch_over_ms)
  uprobe_end(t, "C4 set, chats tab, scrolled")
}

///|
test "usage probe: the filtered view answered late" {
  for late in [false, true] {
    new_run()
    let pending = @signals.signal(false, same=fn(a, b) { a == b })
    let base = fixture("home")
    let src = { ..base, topic_read: fn(name, params) {
      let answer = base.topic(name, params).get().snapshot()
      if name == "usage" && params.get("only") is Some(_) && pending.get() { { ..answer, value: None } } else { answer }
    } }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
    bars_picked.set(Some(([kept_bar], 0)))
    t.run_for(kept_switch_over_ms)
    kept_go(t, "usage", true)
    t.run_for(kept_switch_over_ms)
    uprobe_tap(t, "人")
    t.run_for(kept_switch_over_ms)
    uprobe_end(t, "D\{late} people tab")
    pending.set(late)
    t.drag(180.0, 250.0, 180.0, 400.0, steps=20)
    t.run_for(kept_glide_over_ms)
    uprobe_at(t, "D\{late} up 150")
    uprobe_tap(t, "林")
    t.run_for(kept_switch_over_ms)
    uprobe_at(t, "D\{late} 林 picked")
    pending.set(false)
    t.run_for(kept_switch_over_ms)
    uprobe_at(t, "D\{late} answered")
    uprobe_end(t, "D\{late} answered")
  }
}

///|
test "usage probe: answered mid-way" {
  for late in [0.0, 16.0, 50.0, 100.0, 150.0, 200.0, 300.0, 450.0] {
    new_run()
    let pending = @signals.signal(false, same=fn(a, b) { a == b })
    let base = fixture("home")
    let src = { ..base, topic_read: fn(name, params) {
      let answer = base.topic(name, params).get().snapshot()
      if name == "usage" && params.get("only") is Some(_) && pending.get() { { ..answer, value: None } } else { answer }
    } }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
    bars_picked.set(Some(([kept_bar], 0)))
    t.run_for(kept_switch_over_ms)
    kept_go(t, "usage", true)
    t.run_for(kept_switch_over_ms)
    t.drag(180.0, 600.0, 180.0, 300.0, steps=20)
    t.run_for(kept_glide_over_ms)
    uprobe_tap(t, "人")
    t.run_for(kept_switch_over_ms)
    pending.set(true)
    uprobe_tap(t, "林")
    t.run_for(late)
    pending.set(false)
    t.run_for(kept_switch_over_ms)
    let chip = t.rect_of("只看 林")
    let head = t.rect_of("花费明细")
    match (chip, head) {
      (Some(c), Some(h)) => println("midway \{late}: chip→head \{h.1 - c.1}")
      _ => println("midway \{late}: chip \{chip is Some(_)} head \{head is Some(_)}")
    }
    uprobe_end(t, "M\{late}")
    match (t.rect_of("只看 林"), t.rect_of("花费明细")) {
      (Some(c), Some(h)) => println("midway \{late} at end: chip→head \{h.1 - c.1}")
      _ => ()
    }
  }
}

///|
test "usage probe: kept and woken, then a row picked" {
  for mode in ["none", "late", "preparing"] {
    new_run()
    let pending = @signals.signal(false, same=fn(a, b) { a == b })
    let base = fixture("home")
    let src = { ..base, topic_read: fn(name, params) {
      let answer = base.topic(name, params).get().snapshot()
      if name == "usage" && params.get("only") is Some(_) && pending.get() {
        if mode == "preparing" {
          match answer.value {
            Some(Object(o)) => {
              let m = o.copy()
              m["detailsPreparing"] = Json::boolean(true)
              { ..answer, value: Some(Json::object(m)) }
            }
            _ => answer
          }
        } else {
          { ..answer, value: None }
        }
      } else {
        answer
      }
    } }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
    bars_picked.set(Some(([kept_bar], 0)))
    t.run_for(kept_switch_over_ms)
    kept_go(t, "usage", true)
    t.run_for(kept_switch_over_ms)
    kept_go(t, "profiles", true)
    t.run_for(kept_switch_over_ms)
    kept_go(t, "usage", true)
    t.run_for(kept_switch_over_ms)
    t.drag(180.0, 600.0, 180.0, 300.0, steps=20)
    t.run_for(kept_glide_over_ms)
    uprobe_tap(t, "人")
    t.run_for(kept_switch_over_ms)
    pending.set(mode != "none")
    uprobe_tap(t, "林")
    t.run_for(150.0)
    pending.set(false)
    t.run_for(kept_switch_over_ms)
    match (t.rect_of("只看 林"), t.rect_of("花费明细")) {
      (Some(c), Some(h)) => println("kept \{mode}: chip→head \{h.1 - c.1}")
      (c, h) => println("kept \{mode}: chip \{c is Some(_)} head \{h is Some(_)}")
    }
    uprobe_end(t, "E\{mode}")
    t.drag(180.0, 200.0, 180.0, 600.0, steps=20)
    t.run_for(kept_glide_over_ms)
    uprobe_at(t, "E\{mode} back down 400")
  }
}

///|
test "usage probe: on a device's pixels" {
  for case in [(1, "none"), (1, "late"), (2, "none"), (2, "late")] {
    let (platform, mode) = case
    new_run()
    let pending = @signals.signal(false, same=fn(a, b) { a == b })
    let base = fixture("home")
    let src = { ..base, topic_read: fn(name, params) {
      let answer = base.topic(name, params).get().snapshot()
      if name == "usage" && params.get("only") is Some(_) && pending.get() { { ..answer, value: None } } else { answer }
    } }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform~, scale=3.0)
    t.set_rows_on_pixels(true)
    bars_picked.set(Some(([kept_bar], 0)))
    t.run_for(kept_switch_over_ms)
    kept_go(t, "usage", true)
    t.run_for(kept_switch_over_ms)
    uprobe_tap(t, "人")
    t.run_for(kept_switch_over_ms)
    uprobe_at(t, "F\{platform}\{mode} people")
    pending.set(mode != "none")
    uprobe_tap(t, "林")
    t.run_for(150.0)
    pending.set(false)
    t.run_for(kept_switch_over_ms)
    match (t.rect_of("只看 林"), t.rect_of("花费明细")) {
      (Some(c), Some(h)) => println("dev \{platform} \{mode}: chip→head \{h.1 - c.1}")
      (c, h) => println("dev \{platform} \{mode}: chip \{c is Some(_)} head \{h is Some(_)}")
    }
    uprobe_end(t, "F\{platform}\{mode}")
    t.drag(180.0, 200.0, 180.0, 600.0, steps=20)
    t.run_for(kept_glide_over_ms)
    uprobe_at(t, "F\{platform}\{mode} back down 400")
  }
}

///|
test "usage probe: answered empty while reading first" {
  for mode in ["empty", "emptywait"] {
    new_run()
    let pending = @signals.signal(false, same=fn(a, b) { a == b })
    let base = fixture("home")
    let src = { ..base, topic_read: fn(name, params) {
      let answer = base.topic(name, params).get().snapshot()
      if name == "usage" && params.get("only") is Some(_) && pending.get() {
        match answer.value {
          Some(Object(o)) => {
            let m = o.copy()
            m["empty"] = Json::boolean(true)
            m["lists"] = Json::array([])
            if mode == "emptywait" {
              m["wait"] = { "reading": Json::boolean(true), "failing": [], "empty": Json::boolean(true) }
            }
            { ..answer, value: Some(Json::object(m)) }
          }
          _ => answer
        }
      } else {
        answer
      }
    } }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=1, scale=3.0)
    t.set_rows_on_pixels(true)
    bars_picked.set(Some(([kept_bar], 0)))
    t.run_for(kept_switch_over_ms)
    kept_go(t, "usage", true)
    t.run_for(kept_switch_over_ms)
    uprobe_tap(t, "人")
    t.run_for(kept_switch_over_ms)
    pending.set(true)
    uprobe_tap(t, "林")
    t.run_for(150.0)
    uprobe_at(t, "G\{mode} pending")
    pending.set(false)
    t.run_for(kept_switch_over_ms)
    match (t.rect_of("只看 林"), t.rect_of("花费明细")) {
      (Some(c), Some(h)) => println("empty \{mode}: chip→head \{h.1 - c.1}")
      (c, h) => println("empty \{mode}: chip \{c is Some(_)} head \{h is Some(_)}")
    }
    uprobe_end(t, "G\{mode}")
  }
}

///|
fn uprobe_filtered(v : Json?, list : String, key : String) -> Json? {
  match v {
    Some(Object(o)) => {
      let m = o.copy()
      let lists = match o.get("lists") {
        Some(Array(ls)) =>
          ls.map(fn(l) {
            match l {
              Object(lo) if text(Some(l), "key") == list => {
                let lm = lo.copy()
                match lo.get("items") {
                  Some(Array(its)) => lm["items"] = Json::array(its.filter(fn(it) { text(Some(it), "key") == key }))
                  _ => ()
                }
                Json::object(lm)
              }
              _ => l
            }
          })
        _ => []
      }
      m["lists"] = Json::array(lists)
      Some(Json::object(m))
    }
    _ => v
  }
}

///|
test "usage probe: real size, a person's row picked" {
  for late in [false, true] {
    let c = @sfrealsize.RealSizeChanging::new()
    reset()
    let pending = @signals.signal(false, same=fn(a, b) { a == b })
    let real = c.source(@sffixture.fixture("home"))
    let src = { ..real, topic_read: fn(name, params) {
      match (name, params.get("only")) {
        ("usage", Some(only)) => {
          let p = params.copy()
          p.remove("only")
          let answer = (real.topic_read)(name, p)
          let list = text(Some(only), "list")
          let key = text(Some(only), "key")
          { ..answer, value: if pending.get() { None } else { uprobe_filtered(answer.value, list, key) } }
        }
        _ => (real.topic_read)(name, params)
      }
    } }
    open_fixture_over("home", src)
    let t = @ui.Tester::new(fn(x) { view(x, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=1, scale=3.0, env=[("MBUI_LOCALE", "zh")])
    t.motion_unjudged(true)
    t.set_rows_on_pixels(true)
    t.run_for(kept_switch_over_ms)
    bars_picked.set(Some(([kept_bar], 0)))
    t.run_for(kept_switch_over_ms)
    kept_go(t, "usage", true)
    t.run_for(kept_switch_over_ms)
    uprobe_at(t, "H\{late} opened")
    for _ in 0..<12 {
      let y = match t.words().iter().find_first(fn(w) { w.0 == "花费明细" }) { Some(w) => w.2; None => 9999.0 }
      if y > 150.0 && y < 900.0 && y > 260.0 {
        t.drag(180.0, 500.0, 180.0, 400.0, steps=20)
        t.run_for(kept_glide_over_ms)
      }
    }
    let head = t.words().iter().find_first(fn(w) { w.0 == "花费明细" && w.2 > 0.0 })
    println("H\{late}: head \{match head { Some(h) => h.2; None => -1.0 }}")
    uprobe_tap(t, "人")
    t.run_for(kept_switch_over_ms)
    let hy = match t.words().iter().find_first(fn(w) { w.0 == "花费明细" }) { Some(w) => w.2; None => 0.0 }
    let rows = t.words().filter(fn(w) { w.2 > hy + 70.0 && w.2 < 700.0 && w.1 < 60.0 && w.1 > 20.0 })
    println("H\{late}: rows \{rows.map(fn(w) { "\{w.0}@\{w.2}" }).join(" / ")}")
    pending.set(late)
    match rows.get(0) {
      Some(r) => t.tap(r.1 + 4.0, r.2 + 4.0)
      None => println("H: no row")
    }
    t.run_for(150.0)
    pending.set(false)
    t.run_for(kept_switch_over_ms)
    let ws = t.words().filter(fn(w) { w.1 >= 0.0 && w.2 > -30.0 && w.2 < 900.0 }).map(fn(w) { "\{w.0}@\{w.2.to_int()}" })
    println("H\{late} picked: \{ws.join(" / ")}")
    for _ in 0..<3 {
      t.drag(180.0, 650.0, 180.0, 150.0, steps=20)
      t.run_for(kept_glide_over_ms)
    }
    let ws = t.words().filter(fn(w) { w.1 >= 0.0 && w.2 > -30.0 && w.2 < 900.0 }).map(fn(w) { "\{w.0}@\{w.2.to_int()}" })
    println("H\{late} picked, at its end: \{ws.join(" / ")}")
  }
}

///|
test "usage probe: scrolled while the pick is read" {
  for case in [(2, 0), (2, 1), (2, 2), (1, 0), (1, 1), (1, 2)] {
    let (platform, how) = case
    new_run()
    let pending = @signals.signal(false, same=fn(a, b) { a == b })
    let base = fixture("home")
    let src = { ..base, topic_read: fn(name, params) {
      let answer = base.topic(name, params).get().snapshot()
      if name == "usage" && params.get("only") is Some(_) && pending.get() { { ..answer, value: None } } else { answer }
    } }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform~, scale=3.0)
    t.set_rows_on_pixels(true)
    bars_picked.set(Some(([kept_bar], 0)))
    t.run_for(kept_switch_over_ms)
    kept_go(t, "usage", true)
    t.run_for(kept_switch_over_ms)
    uprobe_tap(t, "人")
    t.run_for(kept_switch_over_ms)
    // to its end, the person's row in view
    for _ in 0..<3 {
      t.drag(180.0, 650.0, 180.0, 250.0, steps=20)
      t.run_for(kept_glide_over_ms)
    }
    uprobe_at(t, "S\{platform}/\{how} before")
    pending.set(true)
    uprobe_tap(t, "陈")
    t.run_for(100.0)
    uprobe_at(t, "S\{platform}/\{how} pending")
    if how == 0 {
      // a finger up the page while it is read, the answer after it rests
      t.drag(180.0, 650.0, 180.0, 250.0, steps=20)
      t.run_for(kept_glide_over_ms)
    } else if how == 1 {
      // a finger down the page, answered in its glide
      t.drag(180.0, 250.0, 180.0, 650.0, steps=6)
      t.run_for(120.0)
    } else {
      // a finger up the page, answered in its glide
      t.drag(180.0, 650.0, 180.0, 250.0, steps=6)
      t.run_for(120.0)
    }
    pending.set(false)
    t.run_for(kept_glide_over_ms)
    match (t.rect_of("只看 陈"), t.rect_of("花费明细")) {
      (Some(c), Some(h)) => println("scrolled \{platform}/\{how}: chip→head \{h.1 - c.1}")
      (c, h) => println("scrolled \{platform}/\{how}: chip \{c is Some(_)} head \{h is Some(_)}")
    }
    uprobe_end(t, "S\{platform}/\{how}")
    for _ in 0..<3 {
      t.drag(180.0, 200.0, 180.0, 600.0, steps=20)
      t.run_for(kept_glide_over_ms)
    }
    uprobe_at(t, "S\{platform}/\{how} back to its top")
  }
}

///|
test "usage probe: the core's client answering late" {
  for case in [(2, 0.0), (2, 100.0), (2, 400.0), (1, 400.0)] {
    let (platform, ms) = case
    new_run()
    let src = @sffixture.round_trip_again(fixture("home"), 0.0, late=fn(name, params) {
      if name == "usage" && params.get("only") is Some(_) { ms } else { 0.0 }
    })
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform~, scale=3.0)
    t.set_rows_on_pixels(true)
    bars_picked.set(Some(([kept_bar], 0)))
    t.run_for(kept_switch_over_ms)
    kept_go(t, "usage", true)
    t.run_for(kept_switch_over_ms)
    uprobe_tap(t, "人")
    t.run_for(kept_switch_over_ms)
    for _ in 0..<3 {
      t.drag(180.0, 650.0, 180.0, 250.0, steps=20)
      t.run_for(kept_glide_over_ms)
    }
    uprobe_tap(t, "陈")
    t.run_for(kept_glide_over_ms)
    let ws = t.words().filter(fn(w) { w.1 >= 0.0 && w.2 > -30.0 && w.2 < 900.0 }).map(fn(w) { "\{w.0}@\{w.2.to_int()}" })
    println("R\{platform}/\{ms} picked: \{ws.join(" / ")}")
    uprobe_end(t, "R\{platform}/\{ms}")
    let ws = t.words().filter(fn(w) { w.1 >= 0.0 && w.2 > -30.0 && w.2 < 900.0 }).map(fn(w) { "\{w.0}@\{w.2.to_int()}" })
    println("R\{platform}/\{ms} at end: \{ws.join(" / ")}")
  }
}
