// A ```mermaid block's chart drawn by the app itself: the core makes it (`mermaid.chart`: mermaid.js lays it out
// there, client/core-ts/src/mermaid.ts, its words measured in the faces the app sets them in) and gives an SVG in the
// theme's colours, drawn here as a picture (mbui's SVG renderer, as an .svg file is): as wide as it is written, or the
// column's where that is less, in its proportions; over the whole screen, the viewer's picture (pinched, moved, kept).
// One the core refuses (mermaid does not read it, or part of it would be HTML) shows as its code. mermaid itself is not
// in the core's own script: the app gives it the one it carries (mermaid_hbc.mbt) the first time a chart is drawn.

///|
priv enum MermaidChart {
  ChartComing
  /// its SVG, the picture's key, its width and height as the chart says them
  ChartMade(Bytes, String, Double, Double)
  ChartRefused
}

///|
// kept across runs: the core's answers, by what was asked (mermaid_ask)
let mermaid_charts : Map[String, MermaidChart] = Map([])

///|
/// How many charts are kept (mermaid_charts), and of how many bytes of SVG at most: those least lately drawn let go of
/// beyond either (their pictures too), asked of the core again as they are drawn again.
let mermaid_most : Int = 64

///|
let mermaid_most_bytes : Int = 16 * 1024 * 1024

///|
/// When each chart was last drawn, by what was asked (mermaid_tick's count).
// kept across runs: let go with mermaid_charts (viz_pages_reset)
let mermaid_used : Map[String, Int] = Map([])

///|
// kept across runs: put back by viz_pages_reset
let mermaid_tick : Ref[Int] = { val: 0 }

///|
/// The bytes of the charts' SVGs kept (ChartMade's).
// kept across runs: put back by viz_pages_reset
let mermaid_bytes : Ref[Int] = { val: 0 }

///|
/// How many nodes of the window's tree show each chart (viz_mermaid_node's, while it is made: they read it once, as
/// mermaid_made says it changed, and would not ask for it again), by what was asked: never let go of while any does.
// kept across runs: emptied by viz_pages_reset
let mermaid_shown : Map[String, Int] = Map([])

///|
/// A node shows chart `key` now ("" none) in place of `was` ("" none): counted (mermaid_shown), drawn now.
fn mermaid_shown_by(was : String, key : String) -> Unit {
  if was != "" {
    let n = mermaid_shown.get(was).unwrap_or(0) - 1
    if n > 0 {
      mermaid_shown[was] = n
    } else {
      mermaid_shown.remove(was)
    }
  }
  if key != "" {
    mermaid_shown[key] = mermaid_shown.get(key).unwrap_or(0) + 1
    mermaid_touch(key)
  }
}

///|
/// Chart `key` drawn now (mermaid_used).
fn mermaid_touch(key : String) -> Unit {
  mermaid_tick.val += 1
  mermaid_used[key] = mermaid_tick.val
}

///|
/// The charts beyond mermaid_most or mermaid_most_bytes let go of, the least lately drawn first (none on its way from
/// the core, never `kept`): a chart made, its picture with it.
fn mermaid_trim(kept : String) -> Unit {
  while mermaid_charts.length() > mermaid_most || mermaid_bytes.val > mermaid_most_bytes {
    let mut oldest = ""
    let mut when = 0
    for k, t in mermaid_used {
      guard k != kept && !(mermaid_charts.get(k) is Some(ChartComing)) && !mermaid_shown.contains(k) else { continue }
      if oldest == "" || t < when {
        oldest = k
        when = t
      }
    }
    guard oldest != "" else { break }
    match mermaid_charts.get(oldest) {
      Some(ChartMade(svg, picture, _, _)) => {
        @ui.forget_image(picture)
        mermaid_bytes.val -= svg.length()
      }
      _ => ()
    }
    mermaid_charts.remove(oldest)
    mermaid_used.remove(oldest)
  }
}

///|
// kept across runs: how many answers came (a signal: a frame drawing a chart reads it, and comes again as one does)
let mermaid_made : @signals.Signal[Int] = @signals.signal(0)

///|
// kept across runs: whether the core was given mermaid (`mermaid.load`), as the core keeps it while it runs; false
// again where it says it has none (a core started anew), and as a run begins (mermaid_begin: a run's core is a new one)
let mermaid_given : Ref[Bool] = Ref(false)

///|
/// A run begins with its core given no mermaid yet: a run's core is a core started anew, which has none till it is
/// given it, whatever the run before gave the one it had. As a Tester begins a run (mbui's on_reset), unless what runs
/// the app began it already (sf's run_begun_by_app: then as it did, its reset's).
fn init {
  @ui.on_reset(fn() { if !(@sf.run_begun_by_app.val)() { mermaid_begin() } })
}

///|
/// No mermaid given to the core (a run begun).
fn mermaid_begin() -> Unit {
  mermaid_given.val = false
}

///|
/// How wide a chart that fills its width (a gantt) is made: drawn as the others are, the column's where that is less.
let mermaid_filling : Int = 720

///|
/// `rgba` laid over `ground` (both 0xRRGGBBAA, the ground opaque), as `#rrggbb`: a colour of the theme as the chart
/// gets it (the core takes nothing else into its styles).
fn mermaid_hex(rgba : Int64, ground : Int64) -> String {
  let a = (rgba & 0xFFL).to_int()
  let mix = fn(shift : Int) {
    let c = ((rgba >> shift) & 0xFFL).to_int()
    let g = ((ground >> shift) & 0xFFL).to_int()
    (c * a + g * (255 - a) + 127) / 255
  }
  let hex = "0123456789abcdef"
  let out = StringBuilder()
  out.write_char('#')
  for shift in [24, 16, 8] {
    let v = mix(shift)
    out.write_char(hex[v / 16].unsafe_to_char())
    out.write_char(hex[v % 16].unsafe_to_char())
  }
  out.to_string()
}

///|
/// What the core is asked for chart `code` `width` wide: its colours as the theme shown has them (the web's chart
/// page's: the page, a card, the strong line, the ink, the muted ink for lines, the quiet grounds, the brand).
fn mermaid_ask(code : String, width : Int) -> Json {
  let t = @sf.theme()
  let p = t.p
  let ground = p.canvas
  let colours : Map[String, Json] = {
    "background": ToJson::to_json(mermaid_hex(ground, ground)),
    "card": ToJson::to_json(mermaid_hex(p.card, ground)),
    "border": ToJson::to_json(mermaid_hex(p.line_strong, ground)),
    "text": ToJson::to_json(mermaid_hex(p.text, ground)),
    "line": ToJson::to_json(mermaid_hex(p.muted, ground)),
    "accent": ToJson::to_json(mermaid_hex(p.neutral_bg, ground)),
    "muted": ToJson::to_json(mermaid_hex(p.hover, ground)),
    "brand": ToJson::to_json(mermaid_hex(p.accent, ground)),
  }
  { "code": ToJson::to_json(code), "dark": ToJson::to_json(t.dark), "colours": Json::object(colours), "width": ToJson::to_json(width) }
}

///|
/// Chart `ask` asked of the core (given mermaid first where it has none yet), its answer kept by `key`.
fn mermaid_asked(src : Source, key : String, ask : Json) -> Unit {
  if !mermaid_given.val {
    match viz_mermaid_script() {
      Some(script) => {
        mermaid_given.val = true
        (src.call_bytes)("mermaid.load", Json::object({}), script, fn(r) { if r is Err(_) { mermaid_given.val = false } })
      }
      None => ()
    }
  }
  (src.call)("mermaid.chart", ask, fn(r) {
    match r {
      Ok({ "svg": String(svg), "width": Number(w, ..), "height": Number(h, ..), .. }) if w > 0.0 && h > 0.0 => {
        mermaid_chart_made(key, @utf8.encode(svg), w, h)
      }
      // a core that has not mermaid (started anew since it was given it): given it again, asked again
      Err({ "code": String("mermaid_absent"), .. }) if mermaid_given.val => {
        mermaid_given.val = false
        mermaid_charts.remove(key)
      }
      _ => mermaid_charts[key] = ChartRefused
    }
    mermaid_touch(key)
    mermaid_trim(key)
    mermaid_made.set(mermaid_made.get() + 1)
  })
}

///|
/// Chart `key` made by the core: its SVG `bytes` put up as its picture, `w` × `h`.
fn mermaid_chart_made(key : String, bytes : Bytes, w : Double, h : Double) -> Unit {
  let picture = "mem:mermaid/" + key
  @ui.add_image(picture, bytes)
  match mermaid_charts.get(key) {
    Some(ChartMade(was, _, _, _)) => mermaid_bytes.val -= was.length()
    _ => ()
  }
  mermaid_charts[key] = ChartMade(bytes, picture, w, h)
  mermaid_bytes.val += bytes.length()
}
