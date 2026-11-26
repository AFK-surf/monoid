// The core makes a Mermaid chart as SVG in the theme's colours. Press the picture or the button below it to open
// the viewer. While the core makes the chart, show a placeholder. If it refuses, show the code.

///|
const MERMAID_FILE : String = "Mermaid.svg"

///|
/// How a chart stands as the core has said (mermaid_charts, as mermaid_made says it changed): made (its SVG, its
/// picture, its width and height), refused, or coming (asked, or not yet).
#derive(Eq)
priv enum MermaidNow {
  NowComing
  NowMade(Bytes, String, Double, Double)
  NowRefused
}

///|
/// A ```mermaid block (viz_mermaid_block's) in `v`, its code as `code` says it as it changes: its chart, drawn as a
/// picture, with a way under it to the whole screen (in `subtle`, its tip in `tips`; the viewer's on `station`); while
/// the core makes it, its place breathing; refused, its code.
pub fn viz_mermaid_node(
  v : @view.View,
  src : Source,
  station : String,
  code : () -> String,
  subtle : () -> Int64,
  tips : @sf.TipLayer,
) -> Unit {
  let ask = fn() { mermaid_ask(code(), mermaid_filling) }
  // (the chart it shows, counted while it does: none is let go of while a node shows it, as it would not ask again)
  let shown_key : Ref[String] = Ref("")
  v.owns(fn() {
    mermaid_shown_by(shown_key.val, "")
    shown_key.val = ""
    // (let go of now, where more are kept than mermaid keeps)
    mermaid_trim("")
  })
  |> ignore
  // (asked of the core as its code or the theme's colours make another ask: once for all the blocks asking the same)
  v.reacts(fn() { ask().stringify() }, fn(key) {
    mermaid_shown_by(shown_key.val, key)
    shown_key.val = key
    if mermaid_charts.get(key) is None {
      mermaid_charts[key] = ChartComing
      mermaid_asked(src, key, @signals.untracked(ask))
    }
  })
  let now = fn() {
    ignore(mermaid_made.get())
    match mermaid_charts.get(ask().stringify()) {
      Some(ChartMade(svg, picture, w, h)) => NowMade(svg, picture, w, h)
      Some(ChartRefused) => NowRefused
      _ => NowComing
    }
  }
  v.pick(now, fn(b, said) {
    match said {
      NowRefused => @sf.code_block_node(b, code, fn() { "mermaid" }, fn() { None })
      NowMade(svg, picture, w, h) =>
        b.box(fn(m) {
          let open = fn() { mermaid_full(station, svg, w, h) }
          @sf.style_node(m, fn() { viz_mermaid_box })
          m.box(fn(p) {
            @sf.style_node(p, fn() { @ui.style(w=Full, max_w=Fixed(w)) })
            p.aspect(Is(w / h)).image(Is(Some((picture, "", 8192)))).image_contains(Is(true)) |> ignore
            @sf.rippled_node(p, open, 6.0, fn() { MERMAID_FILE })
          })
          |> ignore
          mermaid_ways_node(m, open, subtle, tips)
        })
        |> ignore
      NowComing =>
        b.box(fn(m) {
          @sf.style_node(m, fn() { viz_mermaid_box })
          m.box(fn(g) {
            @sf.style_node(g, fn() { viz_wait_ground.then(@ui.style(h=Fixed(viz_first_height.to_double()))) })
            g.box(fn(f) {
              @sf.style_node(f, fn() { viz_wait_fill })
              // (breathing as every wait's shapes: whole to half and back in breath_ms, from moment 0 on, as breathe's)
              f.alpha(By(fn() {
                let at = f.cycle(@sf.breath_ms)
                let way = if at < 0.5 { at * 2.0 } else { 2.0 - at * 2.0 }
                1.0 - 0.5 * @ui.Ease::InOut.at(way)
              }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
    }
  })
}

///|
/// Under a chart, at its end (as other visualizations' ways): 全屏, its tip in `tips`, opening the chart as pressing it does.
fn mermaid_ways_node(
  v : @view.View,
  open : () -> Unit,
  subtle : () -> Int64,
  tips : @sf.TipLayer,
) -> Unit {
  let label = fn() { viz_tr("android-misc.viz.fullscreen") }
  v.box(fn(ways) {
    @sf.style_node(ways, fn() { viz_ways })
    ways.box(fn(k) {
      @sf.style_node(k, fn() { viz_way }, in_row=true)
      @sf.rippled_node(k, open, 6.0, label)
      @sf.icon_node(k, "expand", 14.0, By(subtle)) |> ignore
      @sf.tip_node(tips, k, label) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Chart `svg` (`w` × `h`) over the whole screen, the viewer's (mermaid_ways' press: as a picture waiting in the composer
/// opens, from its bytes, a path of its own, no session's), on `station`.
fn mermaid_full(station : String, svg : Bytes, w : Double, h : Double) -> Unit {
  let a : Attachment = {
    name: MERMAID_FILE,
    path: "draft:mermaid/" + @zip.sha256(svg).exact_view(end=16).to_owned(),
    size: svg.length().to_double(),
    width: w,
    height: h,
    thumbhash: "",
    owner: "",
    upload: "",
    duration: 0.0,
    frames: 0,
    held: false,
  }
  // (the viewer's id of it, Viewer::id: its station, no session, its path)
  keep_read(station + "//" + a.path, svg)
  open_preview(station, "", a)
}
