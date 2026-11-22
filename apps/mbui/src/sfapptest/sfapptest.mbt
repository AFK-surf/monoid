// Shared blackbox test harness helpers for test packages outside `stillfail/sfapp` (such as `stillfail/sfapp_realsize`).
// Non-shipping: contains no tests and imports no `stillfail/sfrealsize`.

///|
/// A call the page made: its name, its params, its bytes (if any) and its answer to give.
pub(all) struct Made {
  name : String
  params : Json
  bytes : Bytes?
  done : (Result[Json, Json]) -> Unit
}

///|
/// How round the system draws a desktop's window on `platform` (@hostapi.window_corner): a Mac's 16 (macOS 27), Windows
/// 11's 8; a phone's or a tablet's app fills its screen (none said).
pub fn test_window_corner(platform : Int) -> Double {
  match platform {
    0 => 16.0
    3 => 8.0
    _ => 0.0
  }
}

///|
/// How long after it opens a screen is looked at: what it opens with (a page pushed, a sheet up) over, a page whose
/// core never answers (chat-loading) slid in once it waited the most a page opening waits (`page_local_ms`).
pub let squeeze_opening : Double = @sfapp.page_local_ms + 1000.0

///|
/// Every mode sffix opens (`fixture_open.mbt`), built on demand.
pub fn corner_modes() -> Array[String] {
  @sfapp.fixture_corner_modes()
}

///|
/// A second of frames after a switch or a step: every way it sets off (a place's way in, the bar's springs, a page's
/// slide, a menu's) over by then.
pub let kept_switch_over_ms : Double = 1000.0

///|
/// What a finger's drag up or down a list glides for after it is let go, over by then (two seconds; three for a long one).
pub let kept_glide_over_ms : Double = 2000.0

///|
pub let kept_glide_long_ms : Double = 3000.0

///|
/// A few frames: what a change told, or a Tab, takes to be drawn.
pub let kept_few_frames_ms : Double = 100.0

///|
/// Between two Tabs, a frame or so drawn after each.
pub let kept_tab_gap_ms : Double = 50.0

///|
/// How long a finger rests on a tab before lifting in tap-held tests.
pub let tap_held_ms : Double = 30.0

///|
/// The bar's places' middles in the phone's window (390 by 844), and its middle's height.
pub fn today_bar_at() -> (Array[Double], Double) {
  (@sfapp.bar_centres(390.0 - 44.0, 1.0, 4).map(fn(x) { x + 22.0 }), 844.0 - 22.0 - 28.0)
}

///|
/// Run on to where the bar's own motions rest (`bar_rest`: its springs, the ball, the icons' swap and tints), past the
/// page's switch.
pub fn to_bar_rest(t : @ui.Tester) -> Unit {
  let rest = @sfapp.bar_rest()
  if rest > t.time() {
    t.run_for(rest - t.time())
  }
}

///|
/// `mode` in window `win` (its name, size, platform and the size class its host says, "" none) in `lang`, a moment
/// after it opens (what it opens with over), drawn. With `source`, wraps the fixture's base source before opening
/// overlays (used by `sfapp_realsize` for `RealSizeChanging`). `loc` is forwarded to `Tester::new` when `moves_held`
/// is false so `MOTION unjudged` and image byte bars file under the caller's file.
#callsite(autofill(loc))
pub fn screen_in(
  mode : String,
  win : (String, Double, Double, Int, String),
  lang : String,
  said? : Bool = false,
  source? : ((@sfbase.Source) -> @sfbase.Source)? = None,
  dark? : Bool = false,
  font_scale? : Double = 1.0,
  moves_held? : Bool = true,
  latin? : (FixedArray[Double], FixedArray[Double])? = None,
  loc~ : SourceLoc,
) -> @ui.Tester {
  let (_, w, h, platform, width) = win
  let src : Ref[@sfbase.Source?] = Ref(None)
  let made = fn() {
    match src.val {
      Some(s) => s
      None => {
        let s = match source {
          Some(wrap) => {
            @sfapp.reset()
            let base = if said { @sffixture.said_longest_source(@sffixture.fixture(mode)) } else { @sffixture.fixture(mode) }
            let s = wrap(base)
            @sfapp.open_fixture_over(mode, s)
            s
          }
          None =>
            if said {
              @sfapp.reset()
              let s = @sffixture.said_longest_source(@sffixture.fixture(mode))
              @sfapp.open_fixture_over(mode, s)
              s
            } else {
              @sfapp.fixture_app(mode)
            }
        }
        src.val = Some(s)
        s
      }
    }
  }
  let made_at = if moves_held { screen_here() } else { loc }
  let t = @ui.Tester::new(
    fn(c) { @sfapp.view(c, made()) },
    tree=fn(root) { @sfapp.app_tree(made())(root) },
    w~,
    h~,
    platform~,
    window_corner=test_window_corner(platform),
    corners_held=false,
    words_over_held=moves_held,
    env=[("MBUI_LOCALE", lang), ("MBUI_REDUCE_MOTION", "1")] + (if dark { [("MBUI_DARK", "1")] } else { [] }),
    loc=made_at,
  )
  if !moves_held {
    t.motion_unjudged(true)
  }
  if font_scale != 1.0 {
    t.set_font_scale(font_scale)
  }
  if latin is Some((regular, bold)) {
    t.latin_advances(regular, bold)
  }
  if width != "" {
    t.drive("system {\"size_class\":{\"width\":\"\{width}\",\"height\":\"medium\"}}\n") |> ignore
  }
  t.run_for(squeeze_opening)
  t.frame()
  t
}

///|
#callsite(autofill(loc))
fn screen_here(loc~ : SourceLoc) -> SourceLoc {
  loc
}

///|
/// The app over the fixture in a window `w` wide, its calls kept in `calls` (the fixture answers the rest).
#callsite(autofill(loc))
pub fn wide_tester(
  calls : Array[Made],
  mode? : String = "home",
  w? : Double = 1280.0,
  h? : Double = 800.0,
  platform? : Int = 0,
  window_corner? : Double = 0.0,
  window_inset? : Bool = false,
  before? : (@sfbase.Source) -> Unit = fn(_) {  },
  env? : Array[(String, String)] = [],
  loc~ : SourceLoc,
) -> @ui.Tester {
  @sfapp.new_run()
  let base = @sffixture.fixture(mode)
  let src : @sfbase.Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      (base.call)(name, params, done)
    },
  }
  if mode.has_prefix("chat") {
    @sfbase.open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  }
  before(src)
  @ui.Tester::new(
    fn(c) { @sfapp.view(c, src) },
    tree=@sfapp.app_tree(src),
    w~,
    h~,
    platform~,
    window_corner~,
    window_inset~,
    env~,
    loc~,
  )
}
