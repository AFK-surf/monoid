// A ```mermaid block as nodes (sfbase's viz_mermaid_node.mbt) set beside the old view's (viz_mermaid_block, through
// @sf.markdown's `code`) on the same words: the chart made (a picture, 全屏 under it), refused (its code), being made
// (its place breathing); wide and narrow, at 1.3; 全屏 pressed; two blocks the same, two pictures, asked once.

///|
/// The fixture's source of chat-viz, the core's answer to mermaid.chart as `answer` says ("made": the fixture's,
/// "refused", "coming": none yet), what it was asked counted in `asked`.
fn mm_src(answer : String, asked : Ref[Int]) -> Source {
  let base = @sffixture.fixture("chat-viz")
  {
    ..base,
    call: fn(name, params, done) {
      if name == "mermaid.chart" {
        asked.val += 1
        match answer {
          "refused" => done(Err({ "code": "unsupported", "message": "Parse error on line 1" }))
          "coming" => ()
          _ => (base.call)(name, params, done)
        }
      } else {
        (base.call)(name, params, done)
      }
    },
  }
}

///|
/// A message's words of `blocks` ```mermaid blocks of the same code, as the core read them.
fn mm_tree(blocks : Int) -> Json {
  let block : Json = ["pre", { "code": "graph TD; A-->B", "lang": "mermaid" }]
  Json::array(Array::make(blocks, block))
}

///|
/// The words as the nodes draw them (markdown_node, its ```mermaid blocks viz_mermaid_node's), `w` wide; what is
/// presented over it drawn.
fn mm_new(w : Double, src : Source, blocks? : Int = 1) -> @ui.Tester {
  @sf.set_words(@sfbase.fill)
  @sfbase.viz_pages_reset()
  @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      root.box(fn(f) {
        @sf.style_node(f, fn() { head_frame })
        @sf.markdown_node(f, fn() { "charts" }, tree=fn() { Some(mm_tree(blocks)) }, size=fn() { body_size }, code=fn(lang) {
          if lang == "mermaid" {
            Some(fn(b, code) { @sfbase.viz_mermaid_node(b, src, "ws1/st1", code, fn() { @sf.theme().p.subtle }, tips) })
          } else {
            None
          }
        })
        |> ignore
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w~,
    h=600.0,
  )
}

///|
test "a mermaid block, made once as nodes, audits cleanly: its chart made, refused, being made; wide and narrow, at 1.3" {
  for answer in ["made", "refused", "coming"] {
    for (w, scale) in [(760.0, 1.0), (390.0, 1.0), (390.0, 1.3)] {
      let at = "\{answer} at \{w}, \{scale}"
      let t = mm_new(w, mm_src(answer, Ref(0)))
      t.set_font_scale(scale)
      t.run_for(@ui.move_most_ms)
      t.frames_owed()
      match answer {
        "made" => {
          assert_false(t.image_loads().is_empty(), msg=at)
          assert_true(t.semantics().iter().any(fn(s) { s.label == @sfbase.viz_tr("android-misc.viz.fullscreen") }), msg=at)
        }
        "refused" => assert_true(t.find("graph TD; A-->B") is Some(_), msg=at)
        _ => assert_false(t.drawn_rects().is_empty(), msg=at)
      }
      let faults = t.audit()
      assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
    }
  }
}

///|
test "two identical mermaid blocks are two pictures, each with its way to the whole screen, the chart asked once" {
  let asked = Ref(0)
  let t = mm_new(390.0, mm_src("made", asked), blocks=2)
  t.run_for(@ui.move_most_ms)
  t.frames_owed()
  assert_eq(asked.val, 1)
  let ways = t.semantics().filter(fn(s) { s.label == @sfbase.viz_tr("android-misc.viz.fullscreen") })
  assert_eq(ways.length(), 2)
  assert_true(ways[0].rect.1 != ways[1].rect.1)
  let faults = t.audit()
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
test "全屏 under a chart opens it over the whole screen" {
  let t = mm_new(390.0, mm_src("made", Ref(0)))
  t.run_for(@ui.move_most_ms)
  t.frames_owed()
  t.click(Button, label=@sfbase.viz_tr("android-misc.viz.fullscreen"))
  t.frame()
  assert_true(@sfbase.preview_open(), msg="open over the whole screen")
  @sfbase.close_now()
  let faults = t.audit()
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}
