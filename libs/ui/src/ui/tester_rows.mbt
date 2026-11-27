// A Tester's look at each pass of a frame's build that kept rows (kept_nodes.mbt): the frame built once more keeping
// none, as laid out, and the two compared node for node, the test failing where the rows kept are what parts them.
// Nothing of the app's frames asks it: the Tester does, as each pass is over (pass_looked).

///|
/// A row or a part kept by a pass (kept_nodes.mbt's RowNodes as the pass put it back): its list and item (-1 a part), its
/// first node and how many, when it was built, whether it was made once by what puts it there (`own`: an island, read
/// as it came, not as what holds it is built), and its name and where it was made, to say it by.
priv struct KeptRow {
  list : Int
  item : Int
  base : Int
  n : Int
  built_at : Double
  own : Bool
  named : String
  made_at : String
}

///|
/// A pass of a frame's build that kept rows, as laid out (frame_said_lines), its nodes in the order its lines say them
/// (Ctx::tree_order), and the rows it kept (KeptRow): compared once the frame is built again keeping none
/// (rows_check_end).
priv struct RowsCheck {
  lines : Array[String]
  order : Array[Int]
  rows : Array[KeptRow]
  /// where it parted from the first build keeping none: that build's lines and the first line apart; the second such
  /// build says whether they part because rows were kept or because what was built changed as it was built
  mut whole : Array[String]?
  mut at : Int
  /// what the pass that kept rows said to tell outside (Ctx::after_build): the frame's, told as it was said; a build
  /// to compare with tells nothing (what is told once, felt as a hold opened its menu, it does not tell again)
  tells : Array[(Int, () -> Unit)]
}

///|
// kept across runs: set and let go within a frame
let rows_checking : Ref[RowsCheck?] = Ref(None)

///|
/// A pass of the frame's build is over (frame_body), `kept0` the rows kept before it: where a Tester checks frames
/// (looks_check) and it kept rows, what it built and said is taken, and the frame built once more keeping none (true:
/// the caller builds it again), the two compared as that is laid out (rows_check_end). In the frame, before what its
/// builds tell outside and before it is painted: built again from the same state, it must come out the same, node for
/// node, and say the same of the frame; so it is painted the same.
fn Ctx::rows_check_begin(self : Ctx, kept0 : Int) -> Bool {
  if nodes_run.kept <= kept0 || rows_checking.val is Some(_) {
    return false
  }
  // (what it read changed as it was built or laid out, a measure taken as it was laid out: built again, it would build
  // otherwise, from what this pass left; the next frame builds it so)
  if nodes_run.told || layout_said.val != "" || watch_said.val != "" || frame_watch_of().changed_as_read() {
    return false
  }
  let rows = []
  for key, rn in kept_nodes {
    if rn.in_pool {
      rows.push({
        list: key.0,
        item: key.1,
        base: rn.base,
        n: rn.n,
        built_at: rn.built_at,
        own: rn.own,
        named: rn.named,
        made_at: match rn.made_at {
          Some(at) => at.to_string()
          None => ""
        },
      })
    }
  }
  rows_checking.val = Some({
    lines: self.frame_said_lines(),
    order: self.tree_order(),
    rows,
    whole: None,
    at: -1,
    tells: self.tells.copy(),
  })
  nodes_run.fresh = true
  nodes_run.whole = true
  // (one pass of the frame, as a host builds it: not counted, FramePerf's `passes`)
  perf_at[3] = perf_at[3] - 1
  true
}

///|
/// The frame built again keeping no row (rows_check_begin) is laid out: what it built and said must be what the pass
/// that kept rows built and said. Where it is not, and building it so wrote what was read as it was built (what the
/// pass that kept rows did not: rows_check_begin), what the rows kept were built from had changed unread, a device
/// keeping them (doing nothing of what building them does: an island's one time, a send) and the Tester's build
/// doing it for it: the test fails. Else it is built once more keeping none (true: the caller builds it again): that
/// coming out as the first such build did, the rows kept are what parts them, and the test fails, saying the first
/// line they part at and the row kept that holds it; coming out otherwise, what was built changed as it was built
/// (from what no signal says): kept rows or not, the next frame builds it so, unless where the first two parted is in a
/// row kept, which built otherwise than it was kept: the test fails too.
fn Ctx::rows_check_end(self : Ctx) -> Bool {
  guard rows_checking.val is Some(was) else { return false }
  let now = self.frame_said_lines()
  let mut why = "the rows kept are what parts them"
  match was.whole {
    None => {
      let at = lines_apart(was.lines, now)
      if at < 0 {
        rows_checking.val = None
        self.tells.clear()
        self.tells.append(was.tells)
        return false
      }
      was.whole = Some(now)
      was.at = at
      let wrote = rows_whole_wrote()
      if wrote == "" {
        // (apart: built once more keeping none, to know whether what parts them is the rows kept)
        perf_at[3] = perf_at[3] - 1
        return true
      }
      // (apart, and built keeping none it wrote what it read: what the rows kept do as they are built, done by the
      // Tester's build alone)
      rows_checking.val = None
      self.tells.clear()
      self.tells.append(was.tells)
      why = "built keeping none, it wrote what it read as it was built (\{wrote}), which the pass keeping rows did not: what a row or part kept does as it is built (a one time, a send) done by the Tester's build alone, never by a device's, from what changed unread (no signal it follows)"
    }
    Some(whole) => {
      rows_checking.val = None
      self.tells.clear()
      self.tells.append(was.tells)
      // (built again keeping none, it built otherwise again: what it built changed as it was built, from what it
      // read that no signal says, kept rows or not; the next frame builds it so, unless the first two part in a row
      // kept: that one built otherwise than it was kept, from what changed unread, kept or not)
      if lines_apart(whole, now) >= 0 {
        if kept_row_at(was, was.at) is None {
          return false
        }
        why = "built keeping none twice, it built otherwise each time, and the first time otherwise than the row kept that holds where they part: built from what changed unread (no signal it follows), what building it does done by the Tester's builds alone"
      }
    }
  }
  let now = was.whole.unwrap()
  let at = was.at
  let line = fn(a : Array[String], j : Int) { if j < a.length() { a[j] } else { "none" } }
  // (the row kept that holds the node, where the line is a node's: the innermost)
  let mut holder = "none of the rows kept"
  match kept_row_at(was, at) {
    Some(r) => {
      // (and the words it holds as built now, to know it by)
      let words = []
      for j in r.base..<imin(r.base + r.n, self.count) {
        let t = self.nodes[j]
        if (t.kind == kind_text || t.kind == kind_rich) && t.text != "" && words.length() < 6 {
          words.push(t.text)
        }
      }
      let node = was.order[at] - r.base
      let what = if r.item >= 0 {
        "list \{r.list}'s row \{r.item}"
      } else if r.named != "" {
        "the island \"\{r.named}\"" + (if r.own { " (made once: own)" } else { "" })
      } else if r.made_at != "" {
        "the part kept at \{r.made_at}" + (if r.own { " (made once: own)" } else { "" })
      } else {
        "part \{r.list}" + (if r.own { " (made once: own)" } else { "" })
      }
      holder = "\{what} (its node \{node}; its words: \{words.join(" | ")}; built at \{r.built_at.to_int()} ms)"
      // (all of it, both ways, where the Tester's said log asks: MBUI_ROWS_PARTED=1)
      if @hostapi.env("MBUI_ROWS_PARTED") == "1" {
        for j in 0..<was.order.length() {
          let i = was.order[j]
          if i >= r.base && i < r.base + r.n {
            println("ROWS-PARTED kept  \{line(was.lines, j)}")
            println("ROWS-PARTED built \{line(now, j)}")
          }
        }
      }
    }
    None => ()
  }
  // (every line the two part at, the first 40, each way: what was kept that building anew did not make)
  let parted = StringBuilder()
  let mut shown = 0
  for j in 0..<imax(was.lines.length(), now.length()) {
    let a = line(was.lines, j)
    let b = line(now, j)
    if a != b && shown < 40 {
      shown += 1
      parted.write_string("\nPARTED kept  " + a)
      parted.write_string("\nPARTED built " + b)
    }
  }
  let said = "the frame at \{self.clock.to_int()} ms, built keeping \{was.rows.length()} rows, (\{built_why.val}), parts from it built keeping none at line \{at} (\{holder}): \{why}; kept \{line(was.lines, at)} / \{line(was.lines, at + 1)}; built \{line(now, at)} / \{line(now, at + 1)}" +
    parted.to_string()
  rows_parted_said.val = said
  looks_fail(said)
  false
}

///|
/// What a frame's build keeping no row (rows_check_begin's) wrote of what it read as it was built, said ("" none):
/// a row's or a part's watch told, the frame's or its layout's, a value it read changed as it read it. The pass that
/// kept rows wrote none (rows_check_begin looks first).
fn rows_whole_wrote() -> String {
  if nodes_run.told {
    "a row's or a part's watch told: \{g().told_said()}"
  } else if watch_said.val != "" {
    watch_said.val
  } else if layout_said.val != "" {
    layout_said.val
  } else if frame_watch_of().changed_as_read() {
    "a value the frame read changed as it was read"
  } else {
    ""
  }
}

///|
/// The row kept (by the pass `was` compared) that holds the node line `at` says, the innermost; none where the line is
/// no node's or none kept holds it.
fn kept_row_at(was : RowsCheck, at : Int) -> KeptRow? {
  guard at >= 0 && at < was.order.length() else { return None }
  let i = was.order[at]
  let mut found : KeptRow? = None
  for r in was.rows {
    if i >= r.base && i < r.base + r.n {
      match found {
        Some(f) if f.n <= r.n => ()
        _ => found = Some(r)
      }
    }
  }
  found
}

///|
/// What the last rows check that failed said (rows_check_end), "" none since the Tester was made: what a test of the
/// check asserts, its frames not judged (Tester::frames_unjudged).
// kept across runs: put back as each Tester is made
let rows_parted_said : Ref[String] = Ref("")

///|
/// The first line where `a` and `b` part (-1: none).
fn lines_apart(a : Array[String], b : Array[String]) -> Int {
  let n = imin(a.length(), b.length())
  for j in 0..<n {
    if a[j] != b[j] {
      return j
    }
  }
  if a.length() != b.length() {
    n
  } else {
    -1
  }
}

///|
/// What the frame built, as laid out, a line each: each node (what it is, where, how large, how it looks, what holds it
/// and what it holds, its look of draw.mbt's), then what it said of the frame (said.mbt's build lists, what is read out
/// and hidden from that, the corners worked out once laid out, the words kept, what asks to be lit).
fn Ctx::frame_said_lines(self : Ctx) -> Array[String] {
  let out = []
  // (in the tree's order, each node by where it is in it: what a frame is is its tree, not where in the frame's nodes
  // each was made, which a part kept as its nodes and the same built anew may make in another order)
  let order = self.tree_order()
  let at = Array::make(self.count, -1)
  for k, i in order {
    at[i] = k
  }
  let pos = fn(i : Int) { if i >= 0 && i < at.length() { at[i] } else { i } }
  for i in order {
    let nd = self.nodes[i]
    let drawn = match self.drawn_entry(i) {
      Some(e) =>
        " look \{e.look} z \{e.z} only \{e.only} cut \{e.top},\{e.bottom} ground \{some_text(e.ground.map(fn(g) { "(\{g.0}, \{g.1}, \{g.2}, \{g.3}, \{rect_text(g.4)})" }))} by \{e.look_by is Some(_)} cycle \{e.cycle is Some(_)}"
      None => ""
    }
    // (its words and their face where it has words: a box keeps what an earlier node of the slot held, unread)
    let words = if nd.kind == kind_image {
      " \"\{nd.text}\" still \{nd.still} fade \{nd.fade}"
    } else if nd.kind == kind_rich {
      " \"\{nd.text}\" \{some_text(nd.rl.map(fn(r) { "(\{r.text}, \{list_text(r.line_w)}, \{list_text(r.line_y)})" }))}"
    } else if nd.kind != kind_text && nd.kind != kind_editor {
      ""
    } else {
      " \"\{nd.text}\" color \{nd.color} font \{nd.font_size} \{nd.weight} wrap \{nd.wrap} lines \{nd.max_lines}" +
      (if nd.kind == kind_text {
        " \{some_text(nd.tl.map(fn(t) { "(\{t.text}, \{t.w}, \{t.h})" }))}"
      } else if nd.kind == kind_rich {
        " \{some_text(nd.rl.map(fn(r) { "(\{r.text}, \{list_text(r.line_w)}, \{list_text(r.line_y)})" }))}"
      } else {
        ""
      })
    }
    let radii_s = some_text(nd.radii.map(fn(r) { "[" + Array::makei(r.length(), fn(j) { said_at(r[j]).to_string() }).join(", ") + "]" }))
    out.push(
      "\{pos(i)} kind \{nd.kind} id \{nd.id} parent \{pos(nd.parent)} first \{pos(nd.first)} next \{pos(nd.next)} item \{nd.item} at \{said_at(nd.x)},\{said_at(nd.y)} \{said_at(nd.fw)}×\{said_at(nd.fh)} tx \{nd.tx},\{nd.ty} moved \{nd.moved_x},\{nd.moved_y} bg \{nd.bg} alpha \{nd.opacity} radius \{said_at(nd.radius)} \{radii_s} border \{nd.border_w} \{nd.border_c} shadow \{nd.shadow} \{nd.shadow_c} clip \{nd.clip} hit \{nd.hit} points \{nd.points} layer \{nd.layer} \{nd.portal} \{nd.portal_id} size \{size_said(nd.w)} \{size_said(nd.h)} placed \{nd.at_l},\{nd.at_t},\{nd.at_r},\{nd.at_b}" +
      words +
      drawn,
    )
  }
  let sb = StringBuilder()
  for l in build_lists {
    l.said_take(self, 0).said_show(sb)
  }
  for l in sb.to_string().split("\n") {
    out.push(l.to_owned())
  }
  let sems = self.sems.map(fn(s) { (pos(s.node), "\{s.id} \{s.label} \{s.value} \{s.hidden}") })
  sems.sort_by(fn(a, b) { a.0.compare(b.0) })
  out.push("sems " + sems.map(fn(s) { "\{s.0} \{s.1}" }).join("; "))
  let corners = fn(a : Array[Int]) {
    let t = a.map(pos)
    t.sort()
    t
  }
  out.push("inners \{list_text(corners(self.inners))} \{list_text(corners(self.inners_or))} \{list_text(corners(self.arounds))}")
  let words = []
  words_kept.each(fn(k, w) { words.push("\{k}: \{w.text} \{list_text(w.pieces.map(fn(p) { rect_text((p.x, p.y, p.w, p.h)) }))}") })
  words.sort()
  out.push("words " + words.join("; "))
  let lit = self.lit_asked.iter().collect()
  lit.sort()
  let chooses = self.hand_chooses.iter().collect()
  chooses.sort()
  out.push("lit \{list_text(lit)} \{list_text(chooses)}")
  // (the ids said numbered as Tester::said numbers them: that numbering let go, it numbers its own)
  if !said_log.on {
    said_log.ids.clear()
  }
  out
}

///|
/// A length as compared (frame_said_lines): to a millionth of a point, what is drawn the same is (frame_watch.mbt's
/// drawn_same), however its sum was added up.
fn said_at(x : Double) -> Double {
  (x * 1.0e6).round() / 1.0e6
}

///|
/// A size as compared (frame_said_lines).
fn size_said(s : Size) -> String {
  match s {
    Auto => "auto"
    Px(p) => "\{p}px"
    Fill(k) => "fill \{k}"
    Cut => "cut"
    Pct(p) => "\{p}%"
  }
}


///|
/// A pass of a frame's build is over: `0` as it is laid out, `1` as nothing else builds it again (`kept0` the rows kept
/// before it). Where the Tester checks the looks (looks_check): what kept rows built again keeping none and compared
/// (true: the frame builds it again).
fn rows_pass_looked(c : Ctx, at : Int, kept0 : Int) -> Bool {
  if !looks_check.val {
    return false
  }
  if at == 0 {
    c.rows_check_end()
  } else {
    c.rows_check_begin(kept0)
  }
}
