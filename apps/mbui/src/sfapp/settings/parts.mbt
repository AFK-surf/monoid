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
/// What a page's blocks stand in from the pane's sides in the wide frame (their own 16 inside it): in a panel of its
/// own none, so its cards stand `panel_card_in` (their 16) from the panel's sides (the user, 2026-11-03: 面板里可以放
/// 卡片), the column in its middle where the panel is wider than it.
fn wide_side(c : @ui.Ctx) -> Double {
  if @sf.in_pane() {
    dmax(0.0, (c.width - 792.0) / 2.0)
  } else {
    dmax(24.0, (c.width - 792.0) / 2.0)
  }
}

///|
/// How far in from a page's blocks its head's words stand: their cards' 16, in a panel of its own on the panel's words'
/// line (panel_words).
fn wide_head_in() -> Double {
  if @sf.in_pane() {
    @sf.panel_words
  } else {
    16.0
  }
}

///|
/// A page's head in the wide frame (pages.css.ts pageHead), the desktop's own pages' too (src/sfdesk): back above it
/// only on a page under another (`deep`; `on_back` when it is said, else the page popped), the title (`about`: what
/// the page is for, said by a mark beside it), what it does at its end.
pub fn wide_head(
  c : @ui.Ctx,
  core : Core,
  back : String,
  title : String,
  trailing? : () -> Unit,
  inside? : Bool = false,
  on_back? : () -> Unit,
  about? : String = "",
  lead? : String = "",
  deep? : Bool = wide_deep.val,
) -> Unit {
  let t = @sf.theme()
  head_block.val = block_at.val
  // (inside a block of the page, which stands in already)
  let side = if inside { wide_head_in() } else { wide_side(c) + wide_head_in() }
  c.box(style=if deep { wide_head_deep } else { wide_head_top }, pl=side, pr=side, fn() {
    if deep {
      let id = c.id("settings-back")
      c.box(style=wide_back, id~, fn() {
        @sf.icon(c, "chevron-left", size=14.0, color=t.p.muted) |> ignore
        c.text(back, size=t.t.meta, color=if c.lit(id) { t.p.text } else { t.p.muted }, wrap=false) |> ignore
      })
      |> ignore
      c.on_press(id, on_back.unwrap_or(fn() { (core.pop)() }))
    }
    c.box(style=title_line, fn() {
      c.box(style=if about == "" { title_words } else { title_about }, fn() {
        // (short of room, cut short before what is at its end: never under a few words, title_words)
        c.text(title, size=t.t.heading, weight=600, color=t.p.text, wrap=false, line=34.0, w=Cut) |> ignore
        if about != "" {
          @sf.about(c, "settings-about", about, label=tr("web-main.about"))
        }
      })
      |> ignore
      match trailing {
        Some(f) => f()
        None => ()
      }
    })
    |> ignore
    // what the page is for, said under its title (pageHead's p: 6 under it, the ui's 13 muted)
    if lead != "" {
      c.box(style=wide_head_lead_box, fn() { c.text(lead, style=wide_head_lead) |> ignore }) |> ignore
    }
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let wide_head_lead_box : @ui.Style = @ui.css("w=Full pt=S1_5")

///|
// kept across runs: a value (no field of it changes)
let wide_head_lead : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, w=Full)

///|
/// Which of a wide page's blocks is being laid out (-1: none, outside its list), and which drew its head (-1: a head
/// over the list).
// kept across runs: said again by every block and head as it is laid out (scroll_page, wide_head)
let block_at : Ref[Int] = Ref(-1)

///|
// kept across runs: said again by every head as it is laid out (wide_head)
let head_block : Ref[Int] = Ref(-1)

///|
/// The wide frame's head: on a page under another (back over its title) 20 down, else 40; 12 under it.
// kept across runs: a value (no field of it changes)
let wide_head_top : @ui.Style = @ui.css("w=Full pt=S10 pb=S3 bg=Bg")

///|
// kept across runs: a value (no field of it changes)
let wide_head_deep : @ui.Style = wide_head_top.then(@ui.css("pt=S5"))

///|
/// The wide frame's back, over the head's title.
// kept across runs: a value (no field of it changes)
let wide_back : @ui.Style = @ui.css("row pb=S2 gap=S1 align=ACenter")

///|
/// A title and what is at its end, in a line (LargeTitle's lead and big word too).
// kept across runs: a value (no field of it changes)
let title_line : @ui.Style = @ui.css("row w=Full gap=S2_5 align=ACenter")

///|
/// A title with what it is for beside it.
// kept across runs: a value (no field of it changes)
let title_about : @ui.Style = title_words.then(@ui.css("row gap=S1_5 align=ACenter"))

///|
/// The title's words, the room its line has left beside what follows them (pageHead: the title grows, its actions at
/// its end).
// kept across runs: a value (no field of it changes)
let title_words : @ui.Style = @ui.style(w=@sf.grow, min_w=S20)

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
/// A word in the accent's wash (本机), whole on its line: the words before it cut short instead.
pub fn you(c : @ui.Ctx, words : String) -> Unit {
  c.box(style=you_ground, keep=true, fn() {
    // Settings.kt:294 (12sp)
    c.text(words, style=you_words) |> ignore
  })
  |> ignore
}

///|
/// You's wash: 6 in at its sides, 6 round.
// kept across runs: a value (no field of it changes)
let you_ground : @ui.Style = @ui.css("px=S1_5 radius=Md bg=AccentBg")

///|
/// Small words in the accent's ink.
// kept across runs: a value (no field of it changes)
let you_words : @ui.TextStyle = @sf.caption.then(@ui.text_style(color=AccentText))

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
/// A settings page's cards to come (the library's Waiting): `sample`, what the page will show of made-up words, in its
/// bones, 12 in from the page's sides; what could not be read over them in red (the bones then still).
pub fn waiting_cards(c : @ui.Ctx, sample : () -> Unit, error? : String = "", failing? : Array[String] = []) -> Unit {
  c.box(style=wait_cards_in, fn() {
    @sf.waiting(c, sample, error~, note={ reading: failing.length() == 0, text: "", failing })
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let wait_cards_in : @ui.Style = @ui.css("w=Full px=S3")

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

