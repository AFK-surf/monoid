// Composer `/` slash skill menu following the attached agent's runtime (sfbase/skills.mbt, sfpages/composer_node.mbt):
// typing `/` opens skills for the attached agent (e.g. Antigravity vs Claude), filters as letters are typed, supports
// keyboard navigation / Enter / Tab / Escape alongside `@` chat references, and ignores file paths and URLs.

///|
/// Opens a wide chat window whose `chat.skills` answers with skills for `runtime` (`agy`, `claude`, `codex`, ...).
fn skill_chat_tester(
  calls : Array[Made],
  runtime : String,
  session? : String = "s-c1",
  w? : Double = 1280.0,
  h? : Double = 800.0,
  platform? : Int = 0,
) -> @ui.Tester {
  new_run()
  let base = fixture("chat")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      if name == "chat.skills" {
        let p = match params {
          Object(m) => {
            let n = m.copy()
            n["runtime"] = Json::string(runtime)
            Json::object(n)
          }
          _ => params
        }
        (base.call)(name, p, done)
      } else {
        (base.call)(name, params, done)
      }
    },
  }
  open_chat({ station: "ws1/st1", session, title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "composer /: Antigravity chat lists Antigravity skills, filters on typing, Enter inserts /name and passes audit" {
  let calls : Array[Made] = []
  let t = skill_chat_tester(calls, "agy", session="s-agy")
  t.draw()
  t.tap_text("发消息")
  let before = t.audit().map(aw_plain)
  t.type_text("/")
  t.run_for(@motion.pop_ms)
  assert_true(t.find("调用 Skill · Antigravity") is Some(_), msg="header shows attached Antigravity runtime")
  assert_true(t.find("/swarm") is Some(_), msg="lists Antigravity /swarm skill")
  assert_true(t.find("/run-workflow") is Some(_), msg="lists Antigravity /run-workflow skill")
  assert_true(t.find("/release-check") is Some(_), msg="lists workspace skill")
  assert_true(t.find("/code-review") is None, msg="does not list Claude-only skill on Antigravity chat")
  let asked = named(calls, "chat.skills")
  assert_eq(asked.length(), 1, msg="fetches chat.skills once on open")
  assert_eq(text(Some(asked[0].params), "session"), "s-agy")
  let added = t.audit().filter(fn(f) { !before.contains(aw_plain(f)) })
  assert_eq(added, [], msg="layout audit added faults with skill popover open: " + added.join(" | "))
  // Typing filters locally without extra station requests
  t.type_text("sw")
  t.run_for(@ui.move_most_ms)
  assert_eq(named(calls, "chat.skills").length(), 1, msg="filtering does not re-fetch from station")
  assert_true(t.find("/swarm") is Some(_), msg="/swarm matches /sw")
  assert_true(t.find("/run-workflow") is None, msg="/run-workflow filtered out by /sw")
  // Enter inserts `/swarm ` and dismisses the menu
  t.key(@ui.key_code_enter)
  t.frame()
  let (_, words, _, _) = t.ime()
  assert_eq(words, "/swarm ")
  t.run_for(@motion.pop_out_ms)
  assert_true(t.find("调用 Skill · Antigravity") is None, msg="menu closed after pick")
}

///|
test "composer /: skills follow attached agent (Claude shows Claude skills, not Antigravity's); ↓ + Tab picks second" {
  let calls : Array[Made] = []
  let t = skill_chat_tester(calls, "claude", session="s-c1")
  t.draw()
  t.tap_text("发消息")
  t.type_text("请帮我 /")
  t.run_for(@motion.pop_ms)
  assert_true(t.find("调用 Skill · Claude") is Some(_), msg="header shows Claude runtime")
  assert_true(t.find("/code-review") is Some(_), msg="lists Claude skill")
  assert_true(t.find("/team:deploy") is Some(_), msg="lists session skill")
  assert_true(t.find("发版值守") is Some(_), msg="session skill names its chat's preset, not 工作目录")
  assert_true(t.find("/swarm") is None, msg="does not list Antigravity skill on Claude chat")
  // ArrowDown moves to the second skill (`/team:deploy`), Tab inserts it in place of `/`
  t.key(@ui.key_code_down)
  t.key(@ui.key_tab)
  t.frame()
  let (_, words, _, _) = t.ime()
  assert_eq(words, "请帮我 /team:deploy ")
}

///|
test "composer /: Escape closes / menu and @ menu independently without clobbering on_key" {
  let calls : Array[Made] = []
  let t = skill_chat_tester(calls, "agy", session="s-agy")
  t.draw()
  t.tap_text("发消息")
  // Open `/` menu and dismiss with Escape
  t.type_text("/")
  t.run_for(@motion.pop_ms)
  assert_true(t.find("调用 Skill · Antigravity") is Some(_))
  t.key(@ui.key_escape)
  t.run_for(@motion.pop_out_ms)
  assert_true(t.find("调用 Skill · Antigravity") is None, msg="Escape closes / skill menu")
  // Clear `/` and open `@` chat reference menu, then verify Escape still closes `@` menu
  t.backspace()
  t.type_text("@")
  t.run_for(@motion.pop_ms)
  assert_true(t.find("引用对话") is Some(_), msg="@ menu still opens")
  t.key(@ui.key_escape)
  t.run_for(@motion.pop_out_ms)
  assert_true(t.find("引用对话") is None, msg="Escape still closes @ menu")
}

///|
test "composer /: paths and URLs never trigger skill.at or open the skill menu" {
  let calls : Array[Made] = []
  let t = skill_chat_tester(calls, "agy", session="s-agy")
  t.draw()
  t.tap_text("发消息")
  t.type_text("src/app.ts https://example.com/swarm")
  t.frame()
  assert_eq(named(calls, "skill.at").length(), 0, msg="paths and URLs never call skill.at")
  assert_eq(named(calls, "chat.skills").length(), 0, msg="paths and URLs never call chat.skills")
  assert_true(t.find("调用 Skill") is None, msg="menu stays closed")
}

///|
test "composer /: works on small touch screen with >= 44pt skill rows and passes audit" {
  let calls : Array[Made] = []
  let t = skill_chat_tester(calls, "agy", session="s-agy", w=390.0, h=844.0, platform=2)
  t.draw()
  t.tap_text("发消息")
  let before = t.audit().map(aw_plain)
  t.type_text("/")
  t.run_for(@motion.pop_ms)
  assert_true(t.find("/swarm") is Some(_))
  let (_, _, _, rh) = t.get(Option, label="/swarm").rect
  assert_true(rh >= 44.0, msg="touch row height \{rh} < 44")
  let added = t.audit().filter(fn(f) { !before.contains(aw_plain(f)) })
  assert_eq(added, [], msg="small touch screen audit added faults: " + added.join(" | "))
}

///|
test "composer /: a session skill's badge is its chat's preset or project, else 工作目录" {
  assert_eq(@sfbase.skills_source_label("session", "claude", place="发版值守"), "发版值守")
  assert_eq(@sfbase.skills_source_label("session", "claude"), "工作目录")
  assert_eq(@sfbase.skills_source_label("workspace", "claude", place="发版值守"), "工作区")
  assert_eq(@sfbase.skills_badge_cut("发版值守与回归检查清单"), "发版值守与…")
  assert_eq(@sfbase.skills_badge_cut("monoid"), "monoid")
  assert_eq(@sfbase.skills_badge_cut("release-checklist"), "release-ch…")
  assert_eq(@sfbase.skills_badge_cut("发版值守"), "发版值守")
}
