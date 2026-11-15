// 记忆, one page in every frame: the workspace's shared memory (MEMORY.md and skills, kept level across every station of
// the workspace), read from an online station of the workspace: its global memory (with its latest diff inline), its
// projects', the other skills (the station's built-in ones folded in a row), each row showing its recent diff and
// opening its page.

///|
/// Which station of the workspace to read the shared memory from: the first online station, else the first station.
fn memory_station(stations : Array[Json]) -> String {
  for s in stations {
    if flag(Some(s), "online") {
      return text(Some(s), "station")
    }
  }
  if stations.length() > 0 {
    text(Some(stations[0]), "station")
  } else {
    ""
  }
}

///|
/// 记忆 made once as nodes (page_node, laid out by the `width` its frame gives it, narrow where none is given) in node
/// `v`: the workspace's shared memory (its global memory by its parts, its projects', the other skills with the
/// built-in ones folded in a row), each row opening its page.
pub fn memories_node(
  v : @view.View,
  core : Core,
  here : () -> @settings.Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let topic = fn() { @settings.stations_of(core, here()) }
  let stations = fn() {
    match topic().value {
      Some(Array(a)) => a
      _ => []
    }
  }
  let address = fn() { memory_station(stations()) }
  let read = fn() {
    let a = address()
    if a == "" {
      ({ value: None, error: "" } : @settings.MemoryRead)
    } else {
      memory_of(core, a)
    }
  }
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.settings.memory.title") },
    on_back~,
    frame~,
    said?,
    width?,
    lead=fn() { @sf.t("android-misc.memory.note") },
    fn() { ["memory"] },
    fn(b, _) {
      b.pick(fn() { read().value is None }, fn(p, reading) {
        if reading {
          @sf.waiting_node(
            p,
            fn(s) { memory_body_node(s, core.quiet(), fn() { "sample" }, fn() { Some(memory_sample()) }) },
            error=fn() {
              let e = read().error
              if e != "" {
                @sf.t("web-main.memory.failed", args=[("error", e)])
              } else {
                match topic().error {
                  Some(te) => error_text(te)
                  None => ""
                }
              }
            },
          )
        } else {
          memory_body_node(p, core, address, fn() { read().value })
        }
      })
    },
  )
}

///|
/// One station's memory (kept for compatibility with direct station memory routes).
pub fn memory_node(
  v : @view.View,
  core : Core,
  here : () -> @settings.Here,
  address : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  let topic = fn() { @settings.stations_of(core, here()) }
  let stations = fn() {
    match topic().value {
      Some(Array(a)) => a
      _ => []
    }
  }
  let read = fn() { memory_of(core, address) }
  let title = fn() {
    for s in stations() {
      if text(Some(s), "station") == address {
        return text(Some(s), "name")
      }
    }
    @sf.t("web-pages.settings.memory.title")
  }
  @sf.page_node(
    v,
    title,
    on_back~,
    frame~,
    said?,
    width?,
    tips?,
    about=fn() { @sf.t("web-pages.settings.memory.lead") },
    fn() { ["memory"] },
    fn(b, _) {
      b.pick(fn() { read().value is None }, fn(p, reading) {
        if reading {
          @sf.waiting_node(
            p,
            fn(s) { memory_body_node(s, core.quiet(), fn() { "sample" }, fn() { Some(memory_sample()) }) },
            error=fn() {
              let e = read().error
              if e == "" {
                ""
              } else {
                @sf.t("web-main.memory.failed", args=[("error", e)])
              }
            },
          )
        } else {
          memory_body_node(p, core, fn() { address }, fn() { read().value })
        }
      })
    },
  )
}

///|
/// The workspace's memory (`m`, as the core reads it, as it changes) as nodes: its global memory (with its recent diff
/// inline), its projects', the other skills with its built-in ones folded in a row, each row opening its page.
fn memory_body_node(
  v : @view.View,
  core : Core,
  address : () -> String,
  m : () -> Json?,
) -> Unit {
  let skills = fn(group : String) { items(m(), "skills").filter(fn(k) { text(Some(k), "group") == group }) }
  let skill_rows = fn(g : @view.View, group : () -> Array[Json]) {
    g.each(group, fn(k) { text(Some(k), "name") }, fn(row, k) {
      let kv = fn() { Some(k.get()) }
      let diff = fn() { items(kv(), "diff") }
      let changed = fn() { text(kv(), "whenChanged") }
      memory_row_node(
        row,
        fn() { text(kv(), "name") },
        fn() { if diff().length() > 0 { "" } else { text(kv(), "line") } },
        fn() { text(kv(), "size") },
        changed~,
        diff~,
        fn() { (core.push)(MemoryDoc(@signals.untracked(address), text(kv(), "name"), 0)) },
      )
    })
  }
  let global = fn() { field(m(), "global") }
  let global_sections = fn() { items(global(), "sections") }
  @sf.section_node(
    v,
    fn() { @sf.t("web-main.memory.global") },
    note=fn() { join([@sf.t("web-main.memory.global.when"), text(global(), "size")], " · ") },
    fn(s) {
      s.pick(fn() { sections_of(m()).length() == 0 }, fn(p, empty) {
        if empty {
          @sf.section_none_node(p, fn() { @sf.t("web-main.memory.empty") })
        } else {
          @sf.group_node(p, fn(g) {
            g.each(fn() { sections_of(m()).mapi(fn(i, x) { (i, x) }) }, fn(x) { x.0.to_string() }, fn(row, x) {
              let i = @signals.untracked(fn() { x.get().0 })
              let sec_json = fn() -> Json? {
                let all = global_sections()
                if i >= 0 && i < all.length() { Some(all[i]) } else { None }
              }
              let diff = fn() {
                let d = items(sec_json(), "diff")
                if d.length() > 0 {
                  d
                } else if i == 0 {
                  items(global(), "diff")
                } else {
                  []
                }
              }
              let changed = fn() {
                let c = text(sec_json(), "whenChanged")
                if c != "" {
                  c
                } else if i == 0 {
                  text(global(), "whenChanged")
                } else {
                  ""
                }
              }
              memory_row_node(
                row,
                fn() { x.get().1.0 },
                fn() { if diff().length() > 0 { "" } else { section_line(x.get().1.1) } },
                fn() { x.get().1.2 },
                changed~,
                diff~,
                fn() { (core.push)(MemoryDoc(@signals.untracked(address), "", i)) },
              )
            })
          })
        }
      })
    },
  )
  @sf.section_node(v, fn() { @sf.t("web-main.memory.projects") }, note=fn() { @sf.t("web-main.memory.projects.when") }, fn(
    s,
  ) {
    s.pick(fn() { skills("project").length() == 0 }, fn(p, empty) {
      if empty {
        @sf.section_none_node(p, fn() { @sf.t("web-main.memory.projects.none") })
      } else {
        @sf.group_node(p, fn(g) { skill_rows(g, fn() { skills("project") }) })
      }
    })
  })
  v.show(fn() { skills("skill").length() + skills("builtin").length() > 0 }, fn(o) {
    @sf.section_node(o, fn() { @sf.t("web-main.memory.others") }, note=fn() { @sf.t("web-main.memory.others.when") }, fn(
      s,
    ) {
      @sf.group_node(s, fn(g) {
        skill_rows(g, fn() { skills("skill") })
        // (the station's own, folded in a row: open as it was left, @settings.builtin_open_of)
        g.show(fn() { skills("builtin").length() > 0 }, fn(f) {
          let open = fn() { @settings.builtin_open_of(address()) }
          memory_row_node(
            f,
            fn() { @sf.t("web-main.memory.builtin") },
            fn() {
              if open() {
                ""
              } else {
                join(skills("builtin").map(fn(k) { text(Some(k), "name") }), @sf.t("web-main.list.separator"))
              }
            },
            fn() { @sf.t("web-main.memory.count", args=[("n", skills("builtin").length().to_string())]) },
            folds=open,
            fn() { @settings.builtin_turn(@signals.untracked(address)) },
          )
        })
        // (each a row of the list's own while open, the list's gap between them: no box round them)
        skill_rows(g, fn() { if @settings.builtin_open_of(address()) { skills("builtin") } else { [] } })
      })
    })
  })
}

///|
/// The first summary line of a global memory section (`words`), without a leading Markdown list marker.
fn section_line(words : String) -> String {
  for l in words.split("\n") {
    let s = l.trim(chars=" \t").to_owned()
    if s != "" && !s.has_prefix("#") {
      if s.has_prefix("- ") || s.has_prefix("* ") || s.has_prefix("+ ") {
        return s.unsafe_substring(start=2, end=s.length()).trim(chars=" \t").to_owned()
      }
      return s
    }
  }
  ""
}

///|
/// Renders a recent diff block inside a memory row's `below` slot, standing `corner_inset` (8) in from the row's
/// sides and foot so its `small_corner` (10) is concentric with the row's `row_corner` (18) and the card's `22`, while
/// its 8px inner padding aligns its gutter mark with the row's title at `text_in` (16).
fn memory_diff_below_node(parent : @view.View, diff : () -> Array[Json]) -> Unit {
  parent.box(fn(col) {
    col
    .grow(Is(1.0))
    .shrink(Is(1.0))
    .min_width(Is(Some(0.0)))
    .margin(Is(@sf.row_below_inset(parent)))
    |> ignore
    col.pick(diff, fn(d, rows) {
      if rows.length() > 0 {
        memory_diff_node(d, rows)
      }
    })
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let memory_diff_box : @ui.Style = tool_diff.then(@ui.css("px=S2"))

///|
// kept across runs: a value (no field of it changes)
let memory_diff_line : @ui.Style = @ui.css("row w=Full px=S2")

///|
// kept across runs: a value (no field of it changes)
let memory_diff_out : @ui.Style = memory_diff_line.then(@ui.css("bg=DangerBg"))

///|
// kept across runs: a value (no field of it changes)
let memory_diff_head : @ui.Style = memory_diff_line.then(@ui.css("pt=S1"))

///|
/// Renders the diff lines of a memory row's recent change in `v`.
fn memory_diff_node(v : @view.View, diff_rows : Array[Json]) -> Unit {
  let n = diff_rows.length()
  steps_box_node(v, memory_diff_box, fn(d) {
    for i, r in diff_rows {
      match r {
        Array([String(mark), String(line)]) =>
          d.box(fn(l) {
            l.margin(Is((-8.0, 0.0, -8.0, 0.0))) |> ignore
            let is_first = i == 0
            let is_last = i + 1 == n
            @sf.style_node(l, fn() {
              let base = match mark {
                "-" => memory_diff_out
                "+" => memory_diff_line.then(@ui.style(bg=Data(@sf.theme().p.green_bg)))
                "@" => memory_diff_head
                _ => memory_diff_line
              }
              let with_top = if is_first { base.then(tool_diff_row_top) } else { base }
              if is_last { with_top.then(tool_diff_row_bot) } else { with_top }
            })
            let ink = fn() {
              match mark {
                "-" => @sf.theme().p.red
                "+" => @sf.theme().p.green_ink
                _ => @sf.theme().p.subtle
              }
            }
            steps_box_node(l, tool_diff_mark, fn(m) {
              if mark == "-" || mark == "+" {
                steps_run(m, fn() { mark }, tool_mono, mono=true, ink~)
              }
            })
            steps_box_node(l, tool_diff_words, fn(w) {
              steps_run(w, fn() { if line == "" { " " } else { line } }, match mark {
                "@" => tool_mono_head
                " " => tool_mono_muted
                _ => tool_mono
              }, mono=true)
            }, in_row=true)
          })
          |> ignore
        _ => ()
      }
    }
  })
}

///|
/// A row of the workspace's memory made once: its name, an optional recent-change tag after its title, a line under it
/// cut short (or its recent diff block below it), how much is in it at its end; `folds` what follows it where it says so.
fn memory_row_node(
  parent : @view.View,
  title : () -> String,
  sub : () -> String,
  value : () -> String,
  changed? : () -> String,
  diff? : () -> Array[Json],
  folds? : () -> Bool,
  press : () -> Unit,
) -> Unit {
  match (changed, diff) {
    (Some(ch), Some(df)) =>
      @sf.link_row_node(
        parent,
        title,
        press,
        value~,
        note=sub,
        note_cut=true,
        title_after=fn(a) { @sf.row_tag_node(a, ch) },
        title_after_shown=fn() { ch() != "" },
        below=fn(b) { memory_diff_below_node(b, df) },
        below_open=fn() { if df().length() > 0 { 1.0 } else { 0.0 } },
        folds?,
      )
    _ =>
      @sf.link_row_node(
        parent,
        title,
        press,
        value~,
        note=sub,
        note_cut=true,
        folds?,
      )
  }
}

///|
/// A memory made up, for what is shown while it is read (memory_body_node in its bones): a few parts of the global
/// memory, a project's skill and two others.
fn memory_sample() -> Json {
  let row = fn(name : Int, line : Int, group : String) -> Json {
    {
      "name": Json::string(@sf.sample_words(name)),
      "line": Json::string(@sf.sample_words(line)),
      "size": Json::string(@sf.sample_words(3)),
      "group": Json::string(group),
    }
  }
  {
    "global": {
      "size": Json::string(@sf.sample_words(3)),
      "sections": Json::array(
        [4, 6, 5].map(fn(n) { Json::object({ "title": Json::string(@sf.sample_words(n)), "note": Json::string(@sf.sample_words(3)) }) }),
      ),
    },
    "skills": [row(6, 18, "project"), row(5, 14, "skill"), row(8, 20, "skill")],
  }
}
