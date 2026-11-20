// The settings pages' parts, as the Android app draws them (shared/ui/Parts.kt: NavBack, NavBar, LargeTitle,
// SectionHeader, Card, ListCard, ListRow, Seg, Avatar; screens/SettingParts.kt GoRow, PageNote; PageParts.kt Switch,
// PresenceDot; Controls.kt Button, PickRow, DoingMark; Waiting.kt Waiting, WaitLine; PlaceRows.kt PlaceEmpty;
// Stations.kt TopBack). Sizes in dp as there; colours src/sf's narrow palette.

///|
/// Each page's blocks as given and as its list made of them, by the page's key (scroll_page's `keys`).
// kept across runs: put back by settings' reset (parts_reset)
let page_rows : Map[String, @ui.ListRows[(String, () -> Unit)]] = Map([])

///|
/// Each page's keys that can make its list continuous, as last given.
// kept across runs: put back by settings' reset (parts_reset)
let page_keys : Map[String, Array[String]] = Map([])

///|
/// Drawn in the wide frame's pane (a desktop's width): the pages as the web's settings pages
/// stand (pages.css.ts page: their head's title 22 in 600, no back where the sidebar is the way back, a column 760 wide
/// at most in the middle, 40 from the sides at least); `wide_deep`: a page under another of them (back shown).
pub let wide : Ref[Bool] = Ref(false)

///|
pub let wide_deep : Ref[Bool] = Ref(false)

///|
/// What a large-title page's top had (top_back), for its head in the wide frame (large_title).
let top_trailing : Ref[(() -> Unit)?] = Ref(None)

///|
let top_on_back : Ref[(() -> Unit)?] = Ref(None)

///|
let top_label : Ref[String] = Ref("")

///|
/// The core of the page being drawn (its head's back, in the wide frame).
let frame_core : Ref[Core?] = Ref(None)

///|
/// How far the status bar and the navigation bar reach in over the view (the app's, src/sfapp/bars.mbt, said each frame):
/// what a page's bar and its foot are padded by.
pub let status_top : Ref[Double] = Ref(0.0)

///|
pub let nav_foot : Ref[Double] = Ref(0.0)

///|
/// The room a place's top page keeps at its foot for the bottom bar.
pub let bar_room : Ref[Double] = Ref(0.0)

///|
/// Whether the page being drawn is a place of the bottom bar's at the stack's root (`page`'s `root`).
let at_root : Ref[Bool] = Ref(false)

///|
/// Under the app's top bar (`page`'s `top`: a place's top page on a phone), how far down what the page
/// shows starts, scrolling under the bar; 0 where the page has a bar of its own over it.
let root_top : Ref[Double] = Ref(0.0)

///|
/// A settings button's height.
pub let settings_button_h : Double = 38.0

///|
/// A button (`button`) in a card's foot corners, its ground reaching past the card's words to where it is concentric
/// with the card's corner (@sf.card_foot_in): across the card (what is in it centred), or at its start (a button with
/// words after it: its words where they were).
// kept across runs: a value (no field of it changes)
pub let foot_across : @ui.Style = @sf.foot_across(settings_button_h)

///|
/// Whether what is being drawn is on a list card: a PickRow's ground is then the card's
/// padding in from its edge already. Set only while a list card's rows are drawn.
let on_card : Ref[Bool] = Ref(false)

///|
/// A person's picture: theirs once it is here, else their initial on their colour.
pub fn avatar(c : @ui.Ctx, core : Core, id : String, name : String, size : Double, picture? : String = "") -> Unit {
  @sf.avatar(c, id, name, if picture == "" { "" } else { (core.picture)(picture, c.page_stint()) }, size)
}

///|
/// The turning ring: 14, or 12 in a line of small text.
pub fn spinner(c : @ui.Ctx, inline? : Bool = false) -> Unit {
  @sf.spinner(c, size=if inline { 12.0 } else { 14.0 }) |> ignore
}

///|
/// Where what someone set going shows how it is: a spinner while it is under way, a small red
/// mark for a few seconds after it failed, why over it while it is pointed at (DoingMark.tsx DoingShown's tip: the
/// row or the menu that asked may have gone, the toast too). Its tip named by where it is called, as its place is.
#callsite(autofill(loc))
pub fn doing_mark(c : @ui.Ctx, running : Bool, failed : String?, inline? : Bool = false, loc~ : SourceLoc) -> Unit {
  let t = @sf.theme()
  if running {
    spinner(c, inline~)
  } else if failed is Some(why) {
    let key = "doing-mark/" + loc.to_string()
    let id = c.id(key)
    c.box(id~, taps=false, points=true, fn() { @sf.icon(c, "info", size=if inline { 12.0 } else { 14.0 }, color=t.p.red) |> ignore })
    |> ignore
    @sf.tip(c, key, id, if why == "" { @sf.t("web-main.doing.failed") } else { why })
  }
}

///|
/// A wait said in a line of its own (the library's WaitLine: @sf.wait_line, a spinner before it after a moment; what is
/// wrong in red at once); `pad`: in from its sides as a card's words.
pub fn wait_line(c : @ui.Ctx, words : String, error? : Bool = false, pad? : Bool = false) -> Unit {
  if pad {
    c.box(style=wait_line_padded, fn() { @sf.wait_line(c, words, error~) }) |> ignore
  } else {
    @sf.wait_line(c, words, error~)
  }
}

///|
/// A wait's line in a page's flow: in from its sides as a card's words.
// kept across runs: a value (no field of it changes)
let wait_line_padded : @ui.Style = @ui.css("w=Full px=S5 py=S2")

///|
/// What could not be read of a list, by the stations that failed (a ListNote's `failing`).
pub fn failing_of(note : Json?) -> Array[String] {
  items(note, "failing").map(fn(f) { text(Some(f), "text") })
}

///|
/// A text button's ground under the finger past its words (Controls.kt pressText: PRESS_OUT on each side, half that
/// above and under), and its corner (PRESS_CORNER).
let press_out : Double = 6.0

///|
let press_corner : Double = 8.0

///|
/// Words to tap with room round them, what is tapped (BarSettings.kt 设为当前, 删除: padding(4) inside its clickable).
// kept across runs: a value (no field of it changes)
let press_room : @ui.Style = @ui.css("p=S1")

///|
/// Words that do something when tapped (`on_press`, as the tap is let go: @sf.press_does).
pub fn tap_text(
  c : @ui.Ctx,
  key : String,
  label : String,
  color? : Int64,
  size? : Double = 15.0,
  said? : String = "",
  room? : Bool = false,
  on_press? : () -> Unit,
) -> Unit {
  let id = c.id(key)
  // `room`: 4 round its words, what it takes (BarSettings.kt's 设为当前, 删除: padding(4) inside what is tapped)
  let b = c.box(style=if room { press_room } else { @ui.style() }, id~, fn() {
    // Settings.kt:447 (15sp), Profiles.kt:794, Vault.kt:365 (14sp): the theme's line, 1.4 its size (its size the
    // caller's)
    c.text(label, style=@sf.link.then(@sf.one_line), size~, line=size * 1.4, color?) |> ignore
    // with room: rippled over it, 6 round (BarSettings.kt: clip(Smooth(6)).clickable); else round its words as
    // Controls.kt pressText
    if room {
      @motion.ripple(c, id, 6.0)
    } else {
      @motion.ripple(c, id, press_corner, out_x=press_out, out_y=press_out / 2.0)
    }
  })
  // `said`: what it says to a screen reader in place of its words (its contentDescription)
  if said != "" {
    c.semantics(b, Button, id~, label=said)
  }
  @sf.press_does(c, id, true, on_press)
}

///|
/// Words in the code face (CodeFont: a code, a key, a variable), one line unless `wrap`.
/// With `style` (a role of @sf's styles.mbt), that, and what is said besides over it.
pub fn mono(
  c : @ui.Ctx,
  words : String,
  style? : @ui.TextStyle,
  size? : Double,
  weight? : Int,
  color? : Int64,
  line? : Double,
  wrap? : Bool = false,
  center? : Bool = false,
) -> Unit {
  // without a style, as it always was: 13, 400, the words' colour, the font's own line
  let (size, weight, color, line) = match style {
    Some(_) => (size, weight, color, line)
    None =>
      (
        Some(size.unwrap_or(13.0)),
        Some(weight.unwrap_or(400)),
        Some(color.unwrap_or(@sf.theme().p.text)),
        Some(line.unwrap_or(0.0)),
      )
  }
  if center {
    c.box(style=centre_column, fn() {
      c.rich([@ui.span(words, mono=true)], style?, size?, weight?, color?, line?, wrap~) |> ignore
    })
    |> ignore
  } else {
    c.rich(
      [@ui.span(words, mono=true)],
      style?,
      size?,
      weight?,
      color?,
      line?,
      wrap~,
      w=if wrap { Fill(1.0) } else { Auto },
    )
    |> ignore
  }
}

///|
/// What it holds in the middle of where it is, across.
// kept across runs: a value (no field of it changes)
let centre_column : @ui.Style = @ui.css("w=Full align=ACenter")

