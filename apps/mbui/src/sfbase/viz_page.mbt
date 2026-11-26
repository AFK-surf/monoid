// Visualizations: an HTML
// file an agent placed in its message's text (`[title](figure.html)` on a line of its own), drawn there in a page's
// view (src/ui/native.mbt NativeView::page) instead of shown as a card, with ways under it to open it over the whole
// screen or as a page of its own (PreviewFile, service.mbt). (A ```mermaid block is the app's own picture:
// viz_mermaid.mbt.)
//
// The page is the web's: its stylesheet and bridge (web/src/viz, web_assets.mbt), the web's tokens for the theme shown
// (as --e-*), the same CSP (scripts and styles from a few public CDNs, no requests of its own). It is as tall as its
// content (the bridge says), keeps what the widget asks to keep (widget.setState, on the station, given back by
// widget.state as it loads), and puts what it asks to send (sendFollowUpMessage, on a tap) in the chat's composer for
// the person to send. What the bridge posts to its own window is relayed to the app (`mbuiHost.post`): none of it is
// trusted, a field that is not what it should be is let go.

// ── the page itself ────────────────────────────────────────────────────

///|
/// A page drawn: its view, the height it said, whether it is shown yet (once it has drawn itself:
/// what is under it shows meanwhile), the theme it was told.
pub(all) struct VizFrame {
  view : @ui.NativeView
  /// The scoped place currently drawing this view; none once its page has left.
  mut owner : Int?
  html : String
  page : Bool
  mut height : Int
  /// the height it last said, and how many times running it grew a little to it (viz_runaway)
  mut said_height : Int
  /// the height it was last shown at as it said one (`height`, with `shown`), told to what binds it (a node: viz_node)
  said : @signals.Signal[Int]
  mut grown : Int
  mut shown : Bool
  mut dark : Bool
  mut font_scale : Double
  mut ground : Int64
  /// the faces it was told (viz_faces_key)
  mut faces : String
  /// its way in once it has drawn itself (viz_reveal); None once it is in
  mut reveal : @motion.Anim?
}

///|
/// Whether it has drawn itself, as a node reads it (followed): it said its height, or, a whole page (or a fragment that
/// says none), it loaded; and its host has drawn it (viz_frame's cover).
pub fn VizFrame::drawn(self : VizFrame) -> Bool {
  self.said.get() |> ignore
  (self.shown || (self.view.state() == 1 && (self.page || self.height == 0))) && self.view.host_done()
}

///|
/// The pages drawn, by where they are drawn (their message's place and file, a chart's code, the full screen's).
pub let viz_frames : Map[String, VizFrame] = Map([])

///|
/// Additional views for a place shown in more than one page at once. The first is kept in viz_frames; each free view
/// is reused after its page leaves, so returning to a chat keeps its already drawn contents.
let viz_extra_frames : Map[String, Array[VizFrame]] = Map([])

///|
fn viz_frame_for(key : String, owner : Int) -> VizFrame? {
  let first = viz_frames.get(key)
  match first {
    Some(f) if f.owner == Some(owner) => return Some(f)
    _ => ()
  }
  let extras = viz_extra_frames.get(key)
  match extras {
    Some(frames) => for f in frames { if f.owner == Some(owner) { return Some(f) } }
    None => ()
  }
  match first {
    Some(f) if f.owner is None => return Some(f)
    _ => ()
  }
  match extras {
    Some(frames) => for f in frames { if f.owner is None { return Some(f) } }
    None => ()
  }
  None
}

///|
/// Heights pages were last drawn at (by their content), so one drawn again takes its room at once.
pub let viz_heights : Map[String, Int] = Map([])

///|
/// What a page says to the app (the bridge's messages, relayed): who hears what it keeps, a failure, words to send.
pub(all) struct VizHears {
  keep : ((Json) -> Unit)?
  failed : ((String) -> Unit)?
  /// words for the chat's composer: whether it took them
  follow_up : ((String) -> Bool)?
}

///|
/// Small back-and-forth height reports on an inline page (viz_said): once a page reverses direction
/// `viz_osc_limit` times within 64 px (a ResizeObserver / sub-pixel feedback loop), hold it at the
/// tallest height seen until a larger genuine resize arrives.
priv struct VizOsc {
  mut dir : Int
  mut flips : Int
  mut hi : Int
  mut held : Bool
}

///|
// kept across runs: cleared on viz_close and viz_pages_reset
let viz_osc : Map[Int, VizOsc] = Map([])

///|
let viz_osc_limit : Int = 6

///|
/// What a page's view says, read (it says what it likes: a field that is not what it should be is let go).
pub fn viz_said(f : VizFrame, hears : VizHears, words : String) -> Unit {
  let m = match (try Some(@json.parse(words)) catch { _ => None }) {
    Some(Object(m)) => m
    _ => return
  }
  match m.get("type") {
    Some(String("height")) =>
      if !f.page {
        match m.get("height") {
          Some(Number(h, ..)) if h == h && h < 1.0e9 && h > 0.0 => {
            let tall = h.ceil().to_int()
            if f.shown && tall == f.said_height {
              return
            }
            // held, it stays so until its content is shorter than where it was held
            if f.grown > viz_runaway && tall >= f.said_height {
              return
            }
            let id = f.view.id()
            match viz_osc.get(id) {
              Some(o) if o.held =>
                if (tall - o.hi).abs() <= 64 {
                  return
                } else {
                  viz_osc.remove(id)
                }
              _ => ()
            }
            if f.said_height > 0 {
              let delta = tall - f.said_height
              if delta.abs() <= 64 {
                let step_dir = if delta > 0 { 1 } else { -1 }
                let o = match viz_osc.get(id) {
                  Some(o) => o
                  None => {
                    let o : VizOsc = { dir: 0, flips: 0, hi: f.said_height, held: false }
                    viz_osc[id] = o
                    o
                  }
                }
                if tall > o.hi {
                  o.hi = tall
                }
                if o.dir != 0 && o.dir != step_dir {
                  o.flips += 1
                }
                o.dir = step_dir
                if o.flips >= viz_osc_limit {
                  o.held = true
                  f.said_height = o.hi
                  f.height = o.hi
                  f.shown = true
                  f.said.set(o.hi)
                  return
                }
              } else {
                viz_osc.remove(id)
              }
            }
            f.grown = if f.said_height > 0 && tall > f.said_height && tall - f.said_height <= 64 {
              f.grown + 1
            } else {
              0
            }
            if f.grown > viz_runaway {
              return
            }
            f.said_height = tall
            // only a height it did not creep or oscillate to is kept: one kept mid-run would start the next load's run further on
            let oscillating = match viz_osc.get(id) {
              Some(o) => o.flips > 0
              None => false
            }
            if f.grown == 0 && !oscillating {
              viz_heights[f.html] = tall
            }
            f.height = tall
            f.shown = true
            f.said.set(tall)
          }
          _ => ()
        }
      }
    Some(String("state")) => {
      let s = m.get("state").unwrap_or(Json::null())
      if s.stringify().length() <= viz_max_state {
        match hears.keep {
          Some(k) => k(s)
          None => ()
        }
      }
    }
    Some(String("failed")) =>
      match (m.get("message"), hears.failed) {
        (Some(String(why)), Some(f)) => f(why)
        _ => ()
      }
    Some(String("followup")) =>
      match m.get("prompt") {
        Some(String(p)) => {
          let words = p.trim().to_owned()
          if words != "" {
            let cut = if words.length() > 4000 { words.clamped_view(end=4000).to_owned() } else { words }
            let took = match hears.follow_up {
              Some(f) => f(cut)
              None => false
            }
            toast_later(viz_tr(if took { "android-misc.viz.followupDrafted" } else { "android-misc.viz.cantSend" }))
          }
        }
        _ => ()
      }
    _ => ()
  }
}

///|
/// The frame of `html` drawn as `key` by `owner` (a node's: viz_node): the one it has, else one no
/// other has now (a chat's kept as it was left: the same view, not loaded again), else one made, a view of its own for
/// each copy drawn at once.
pub fn viz_frame_of(
  key : String,
  html : String,
  state : Json?,
  hears : VizHears,
  owner : Int,
  fill? : Bool = false,
  ground? : Int64 = @sf.theme().p.bg,
) -> VizFrame {
  let dark = @sf.theme().dark
  if !viz_left_chats.is_empty() {
    viz_shown_again(key)
  }
  match viz_frame_for(key, owner) {
    Some(f) => f
    None => {
      let page = !viz_is_fragment(html)
      let doc = if page { viz_page_document(html) } else { viz_document(html, state, dark, ground, scroll=fill) }
      let cell : Ref[VizFrame?] = Ref(None)
      let view = @ui.NativeView::page(doc, said=fn(w) {
        match cell.val {
          Some(f) => viz_said(f, hears, w)
          None => ()
        }
      })
      // in a list, an upright drag on the page moves the list; a page of its own keeps them
      if !fill {
        view.touch(@ui.Touch::VerticalOut)
      }
      let f : VizFrame = {
        view,
        owner: None,
        html,
        page,
        height: viz_heights.get(html).unwrap_or(0),
        said_height: 0,
        said: @signals.signal(0, same=fn(a, b) { a == b }),
        grown: 0,
        shown: false,
        dark,
        font_scale: @ui.font_scale(),
        ground,
        faces: viz_faces_key(),
        reveal: Some(@motion.Anim::new(0.0)),
      }
      cell.val = Some(f)
      if viz_frames.contains(key) {
        match viz_extra_frames.get(key) {
          Some(extras) => extras.push(f)
          None => viz_extra_frames[key] = [f]
        }
      } else {
        viz_frames[key] = f
      }
      f
    }
  }
}

///|
/// Whether the theme `f` was told is not the one now (`dark`, its `ground`, the size and faces of words): taken as told
/// where it is not, to be told by viz_theme_tell.
pub fn viz_theme_news(f : VizFrame, dark : Bool, ground : Int64) -> Bool {
  if f.dark != dark || f.ground != ground || f.font_scale != @ui.font_scale() || f.faces != viz_faces_key() {
    f.dark = dark
    f.font_scale = @ui.font_scale()
    f.ground = ground
    f.faces = viz_faces_key()
    true
  } else {
    false
  }
}

///|
/// The theme told to `f`'s page (`dark`, its `ground`): its tokens and sheets, its ground.
pub fn viz_theme_tell(f : VizFrame, dark : Bool, ground : Int64) -> Unit {
  let scheme = if dark { "dark" } else { "light" }
  let g = viz_css_color(ground)
  f.view.script(
    "postMessage({vizMessage:true,type:\"theme\",tokens:" +
    viz_tokens_json(dark) +
    ",scheme:\"" +
    scheme +
    "\",sheets:" +
    Json::array(viz_sheets().map(fn(h) { Json::string(h) })).stringify().replace_all(old="<", new="\\u003c") +
    "},\"*\");var g=document.getElementById(\"mbui-ground\");if(g)g.textContent=\":root:root{background:" +
    g +
    "}\"",
  )
}

///|
/// A page come in once it has drawn itself as nodes, over its frame in `parent` (a layer of the frame's room, what goes
/// past it cut): viz_reveal's, set out at `from` (the moment it was told drawn) for viz_reveal_ms, what it waited under
/// (the placeholder: a whole page's paper, else the line's grey on the chat's ground, their corners the placeholder's)
/// brushed off from its top, an edge half its height deep going down it (the ease out) in viz_reveal_steps steps, and
/// fading out from 800 ms (300 ms). Each strip on the screen's pixels, one meeting the next with no seam; each worked out
/// of the frame's height as it is drawn (View::moved_by), nothing laid out again for it.
pub fn viz_reveal_node(parent : @view.View, page : Bool, _from : Double) -> Unit {
  // (cut to the frame, its corners the placeholder's where it is a fragment's)
  parent
  .over(Is(true))
  .fills_across(Is(true))
  .height_share(Is(1.0))
  .clips(Is(true))
  .radius(By(fn() { if page { 0.0 } else { @ui.tree_theme().corner(Xl) } }))
  |> ignore
  @motion.curtain_reveal(
    parent,
    fn() { true },
    fn() {
      @ui.tree_theme().color(if !page { Line } else if @sf.theme().dark { @sf.viz_paper_dark } else { @sf.viz_paper })
    },
    duration_ms=viz_reveal_ms,
    wait_after_ms=viz_reveal_wait_after_ms,
    wait_out_ms=viz_reveal_wait_out_ms,
    steps=viz_reveal_steps,
  )
}

///|
/// How long a page comes in, when and how fast what it waited under goes, its edge's steps (image_reveal's).
pub let viz_reveal_ms : Double = 1100.0

///|
let viz_reveal_wait_after_ms : Double = 800.0

///|
let viz_reveal_wait_out_ms : Double = 300.0

///|
let viz_reveal_steps : Int = 16

///|
/// The faces a page is set in, as one string: told again when it changes.
fn viz_faces_key() -> String {
  faces_web.map(fn(f) { f.0 + "\n" + f.1 }).join("\n")
}

///|
/// A whole page's window in a message: 16:9 of its width, at most this share of the screen's height.
pub let viz_page_ratio : Double = 9.0 / 16.0

///|
pub let viz_page_most : Double = 0.8

///|
/// All the room it is given (a page of its own).
// kept across runs: a value (no field of it changes)
pub let viz_fill : @ui.Style = @ui.css("w=Full h=Full")

///|
/// What shows under a page not drawn yet: the chat's ground.
// kept across runs: a value (no field of it changes)
pub let viz_ground : @ui.Style = @ui.css("w=Full h=Full bg=Bg")

///|
/// A whole page in a message: its corners the card's (Smooth 20), on the paper (dark #26272B).
// kept across runs: a value (no field of it changes)
pub let viz_page_frame : @ui.Style = @ui.style(w=Full, radius=@sf.viz_card_radius, clip=true, bg=@sf.viz_paper, dark=@ui.patch(bg=@sf.viz_paper_dark))

///|
// kept across runs: a value (no field of it changes)
pub let viz_paper_cover : @ui.Style = @ui.style(w=Full, h=Full, bg=@sf.viz_paper, dark=@ui.patch(bg=@sf.viz_paper_dark))

///|
/// The pages drawn as `prefix…` let go (their place gone: the chat left, the full screen closed).
pub fn viz_close(prefix : String) -> Unit {
  let gone = []
  for k, f in viz_frames {
    if k.has_prefix(prefix) {
      viz_osc.remove(f.view.id())
      f.view.close()
      match viz_extra_frames.get(k) {
        Some(extras) =>
          for extra in extras {
            viz_osc.remove(extra.view.id())
            extra.view.close()
          }
        None => ()
      }
      gone.push(k)
    }
  }
  for k in gone {
    viz_frames.remove(k)
    viz_extra_frames.remove(k)
  }
}

///|
/// How many chats left last keep their pages (each its view, hidden while not painted): one gone back to shows them
/// as they were, not loaded and drawn again behind a placeholder (the user, 2026-10-29: 每次切换 chat 都会闪一下).
pub let viz_chats_kept : Int = 4

///|
/// The chats left whose pages are kept (their keys' prefix), the one left last at the end.
pub let viz_left_chats : Array[String] = []

///|
/// A chat left: its pages kept, as those of the few left before it; the one left longest ago lets its go.
pub fn viz_chat_left(station : String, session : String) -> Unit {
  let prefix = "chat/" + station + ":" + session + "/"
  match viz_left_chats.search(prefix) {
    Some(i) => ignore(viz_left_chats.remove(i))
    None => ()
  }
  viz_left_chats.push(prefix)
  while viz_left_chats.length() > viz_chats_kept {
    viz_close(viz_left_chats.remove(0))
  }
}

///|
/// A page drawn again: its chat is shown, no longer one left (its pages not let go for others left after it).
fn viz_shown_again(key : String) -> Unit {
  for i, p in viz_left_chats {
    if key.has_prefix(p) {
      ignore(viz_left_chats.remove(i))
      return
    }
  }
}

// ── in a message ─────────────────────────────────

///|
/// Where a visualization's words to send go: the chat's composer, whichever frame's (its draft: the words after what
/// is there, then the field focused, as Prose.kt's followUp): left for it by the chat's draft key, taken as it is next
/// drawn.
pub fn viz_follow_up(station : String, session : String) -> (String) -> Bool {
  fn(words) {
    draft_give(station + ":" + session, Followed(words))
    true
  }
}

///|
/// Its place while it comes: 120 high, its corners Smooth 12, a placeholder's grey (the line's), 8 under it.
// kept across runs: a value (no field of it changes)
pub let viz_wait_under : @ui.Style = @ui.css("w=Full pb=S2")

///|
// kept across runs: a value (no field of it changes)
pub let viz_wait : @ui.Style = @ui.style(w=Full, h=@sf.viz_wait_h, radius=Xl, bg=Line)

///|
/// Its place while it draws itself: as `viz_wait`, as tall as its frame.
// kept across runs: a value (no field of it changes)
pub let viz_wait_fill : @ui.Style = @ui.css("w=Full h=Full radius=Xl bg=Line")

///|
/// The ground covering its view while it waits: its corners the placeholder's (the view's hole cut to them).
// kept across runs: a value (no field of it changes)
pub let viz_wait_ground : @ui.Style = @ui.css("w=Full h=Full radius=Xl bg=Bg")

///|
/// The page and the ways under it, 4 under them.
// kept across runs: a value (no field of it changes)
pub let viz_file_box : @ui.Style = @ui.css("w=Full pb=S1")

///|
/// The ways under the page: 2 under it, 22 high, at its end, 2 apart.
// kept across runs: a value (no field of it changes)
pub let viz_ways : @ui.Style = @ui.css("row w=Full pt=S0_5 h=S6 gap=S0_5 justify=JEnd")

///|
// kept across runs: a value (no field of it changes)
pub let viz_way : @ui.Style = @ui.style(
  w=@sf.viz_way_side,
  h=@sf.viz_way_side,
  radius=Md,
  align=ACenter,
  justify=JCenter,
)

// ── over the whole screen ────────

///|
/// A visualization open over the whole screen: its name, its file (to fetch, or fetched), the chat whose composer its
/// words go to.
#derive(Eq)
pub(all) struct VizFull {
  name : String
  station : String
  key : String
  path : String
  session : String
  /// opened by a link within a sentence (VizOpen): its wait said under the words till it covers the screen
  linked : Bool
}

///|
/// The visualization open over the whole window, if one is: a signal, what draws it built again as one is opened or
/// closed, wherever that was.
// kept across runs: put back as a run begins (viz_pages_reset)
pub let viz_full : @signals.Signal[VizFull?] = @signals.signal(None)

///|
/// Visualization `name` (at `path`, sent by session `key` of chat `session` on `station`) opened as a press asks: where
/// the shell has a side panel for the page in view, a tab there (a page's: PreviewFile; a `.mbui` / `.wasm` mini-program
/// a file's), over the whole window as that tab where `full` asks it (its 全屏; by default unless the command key is
/// held: full_asked); else, or beside the system's bars (an iPhone Duo's), over the whole window on its own (`linked`: opened
/// by a link in a sentence, its wait said under the words).
pub fn viz_open(
  name : String,
  station : String,
  key : String,
  path : String,
  session : String,
  linked? : Bool = false,
  full? : Bool,
) -> Unit {
  let full = full.unwrap_or(full_asked())
  if is_mbui_viz(name) || is_mbui_viz(path) {
    let a : Attachment = {
      name: if name != "" { name } else { base_name(path) },
      path,
      size: 0.0,
      width: 0.0,
      height: 0.0,
      thumbhash: "",
      owner: "",
      upload: "",
      duration: 0.0,
      frames: 0,
      held: false,
    }
    open_preview(station, key, a, steps=InChat(None, session), full~)
    return
  }
  // (beside the system's bars, an iPhone Duo's on its side, its own whole window, whose actions are theirs)
  if beside_room_now.untracked() && !@sf.native_on() {
    let p = PreviewFile(station, key, path, name)
    if full {
      open_page_full(p)
    } else {
      open_page(p)
    }
    return
  }
  viz_close("full/")
  viz_full.set(Some({ name, station, key, path, session, linked }))
}

///|
/// Visualization `name` asked over the whole window (its 全屏): viz_open's.
pub fn viz_open_full(name : String, station : String, key : String, path : String, session : String) -> Unit {
  viz_open(name, station, key, path, session, full=true)
}

///|
pub fn viz_close_full() -> Unit {
  viz_close("full/")
  viz_full.set(None)
}

///|
/// The visualization over the whole window, if one is open, whatever the layout, in node `v` of the window's tree (laid
/// out over the pages: narrow_shell, tape_shell), made as one is opened and let go as it is closed. On the page's ground,
/// under the bar every file opened over the whole window has (laid out Small, floating with its ×: viewer_head_node;
/// else across the top, its way back by name: viewer_bar_node; beside the system's bars (an iPhone Duo's) theirs, close
/// and download in them), the page under it as tall as the rest; a modal layer while it is open, back and Escape closing
/// it. One that cannot be read is said so and closes.
pub fn viz_full_layer_node(v : @view.View, src : Source) -> Unit {
  v.box(fn(layer) {
    layer.over(Is(true)) |> ignore
    layer.pick(
      at_once=true,
      fn() { viz_full.get() },
      fn(n, open) {
        match open {
          Some(full) => viz_full_node(n, src, full)
          None => ()
        }
      },
    )
  })
  |> ignore
}

///|
/// Visualization `full` over the whole window in `n` (viz_full_layer_node's): what draws it once its file is read.
fn viz_full_node(n : @view.View, src : Source, full : VizFull) -> Unit {
  // (over the pages, the whole of the room it is given: not one more of what is laid out after them)
  n.over(Is(true)) |> ignore
  let load = viz_load_node(n, src, full.station, full.key, full.path)
  // (its file not read: said so, and closed, at the moment that is known; a link's wait is said under its words)
  n.reacts(fn() { load() is Some(Err(_)) }, fn(failed) {
    if failed {
      viz_close_full()
      toast_later(viz_tr("android-misc.viz.cantRead"))
    }
  })
  n.show(fn() { load() is Some(Ok(_)) }, fn(o) {
    match @signals.untracked(load) {
      Some(Ok((html, state))) => viz_full_shown(o, src, full, html, state)
      _ => ()
    }
  })
}

///|
/// Visualization `full` read (`html`, what its widget kept: `state`) over the whole window in `n` (viz_full_node's).
fn viz_full_shown(n : @view.View, src : Source, full : VizFull, html : String, state : Json?) -> Unit {
  let place = "full/" + full.station + "/" + full.key + "/" + full.path
  let hears : VizHears = {
    keep: Some(fn(s) { viz_keep(src, full.station, full.key, full.path, s) }),
    failed: None,
    follow_up: Some(viz_follow_up(full.station, full.session)),
  }
  // (while it is the one open: the pages under it take no press, key or wheel; back and Escape close it)
  @sf.fullscreen_overlay_node(n, viz_close_full) |> ignore
  // beside the system's bars (an iPhone Duo's): its name and close and download there in place of a bar of its own, said
  // as that is so, kept as said while it is the one open (@sf.native_over_up)
  let alive = fn() {
    match viz_full.untracked() {
      Some(now) => physical_equal(now, full)
      None => false
    }
  }
  n.reacts(fn() { (@sf.native_on(), @sf.t("common.close"), @sf.t("android-chat.file.download")) }, fn(said) {
    let (on, close, download) = said
    if on && @sf.native_over_up(full.name, alive~, owner="viz", over=1) {
      @sf.native_over_act("close", close, "close", fn() { viz_close_full() }, lead=true)
      @sf.native_over_act("download", download, "download", fn() {
        if html.has_prefix("wasm:base64:") {
          let b64 = html.unsafe_substring(start=12, end=html.length())
          keep_bytes_now(full.name, "application/wasm", viz_base64_decode(b64).unwrap_or(b""))
        } else {
          keep_bytes_now(full.name, "text/html", @utf8.encode(html))
        }
      })
    }
  })
  let width = fn() { n.window_w() }
  let room = fn() { (@sf.viewer_host().room)() }
  n.box(fn(page) {
    @sf.style_node(page, fn() { viz_ground })
    // under the bar, as a file's page is (viewer_stage_node's): beside the system's bars, under their room alone
    page.box(fn(top) {
      top.height(
        By(fn() {
          let under = if @sf.native_on() {
            room().0
          } else if width() <= @sf.viewer_small_w {
            room().0 + page_small_top
          } else {
            room().0 + desk_page_top
          }
          Some(under)
        }),
      )
      |> ignore
    })
    |> ignore
    page.box(fn(body) {
      @sf.style_node(body, fn() { viz_full_page.then(@ui.style(pr=@sf.room_of(@ui.Space::px(S3) + @sf.native_clear()))) })
      match viz_mbui_parse(full.name, html) {
        Some(widget) =>
          body.box(fn(b) {
            @sf.style_node(b, fn() { viz_full_mbui_box })
            viz_mbui_node(b, place, widget, fn() { viz_state_of(full.station, full.key, full.path).unwrap_or(state.unwrap_or(Json::null())) }, hears)
          })
          |> ignore
        None => viz_page_fill_node(body, place, html, state, hears)
      }
    })
    |> ignore
    page.box(fn(foot) { foot.height(By(fn() { Some(room().1) })) |> ignore }) |> ignore
  })
  |> ignore
  // its bar of its own, but beside the system's bars: laid out Small floating at the top with its ×, else across the top
  // with its way back by name (as a file opened over the window has: viewer_bar_floats)
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = @sf.TipLayer::new(fn() { tips_at.val })
  let ink = fn() { @sf.page_viewer_ink() }
  n.pick(
    fn() {
      if @sf.native_on() {
        0
      } else if @sf.viewer_bar_floats(width()) {
        1
      } else {
        2
      }
    },
    fn(b, kind) {
      // (over the page, all of the room: laid out over it, not after it)
      b.over(Is(true)) |> ignore
      match kind {
        1 =>
          @sf.viewer_head_node(
            b,
            fn() { full.name },
            fn() { "" },
            fn() { true },
            fn(_) { 1.0 },
            fn() { room().0 },
            width,
            ink,
            fn() { @sf.viewer_page_glass() },
            fn(_) {  },
            fn() { "" },
            fn() { viz_close_full() },
            tips~,
          )
          |> ignore
        2 =>
          @sf.viewer_bar_node(
            b,
            fn() { @sf.t("common.back") },
            fn() { full.name },
            fn() { "" },
            fn() { "" },
            fn() { false },
            fn(_) { 1.0 },
            fn() { room().0 },
            width,
            ink,
            fn(_, _) {  },
            fn() { viz_close_full() },
            tips,
          )
          |> ignore
        _ => ()
      }
    },
  )
  tips_at.val = Some(n.box(fn(l) { l.over(Is(true)) |> ignore }))
}

///|
/// A page of its own (`html`, what its widget kept: `state`) drawn as `place` in `parent`, all of the room it is given:
/// its view ui's native, kept past its node (viz_close lets it go), scrolling in itself; covered by the page's ground till
/// it has drawn itself and its host has drawn it (viz_frame's cover). The theme told to it as it changes.
fn viz_page_fill_node(parent : @view.View, place : String, html : String, state : Json?, hears : VizHears) -> Unit {
  parent.box(fn(b) {
    @sf.style_node(b, fn() { viz_fill })
    // (its node's own: a view to each node drawing it)
    let owner = -(b.id().at + 1)
    let f = viz_frame_of(place, html, state, hears, owner, fill=true, ground=@sf.theme().p.bg)
    f.owner = Some(owner)
    b.owns(fn() {
      if f.owner == Some(owner) {
        f.owner = None
      }
    })
    |> ignore
    b.reacts(fn() { (@sf.theme().dark, @sf.theme().p.bg, @ui.font_scale()) }, fn(now) {
      let (dark, ground, _) = now
      if viz_theme_news(f, dark, ground) {
        viz_theme_tell(f, dark, ground)
      }
    })
    let drawn = fn() { f.drawn() }
    let view = @ui.native(b, f.view, kept=true)
    @sf.style_node(view, fn() { viz_fill })
    b.show(at_once=true, fn() { !drawn() }, fn(o) {
      o.over(Is(true)) |> ignore
      @sf.style_node(o, fn() { viz_ground })
    })
  })
  |> ignore
}

///|
/// The page under it, 12 in at its sides, as tall as the rest.
// kept across runs: a value (no field of it changes)
pub let viz_full_page : @ui.Style = @ui.style(w=Full, h=@sf.grow, px=S3)

///|
// kept across runs: a value (no field of it changes)
let viz_full_mbui_box : @ui.Style = @ui.style(w=Full, h=@sf.grow, py=S3)

///|
// kept across runs: a value (no field of it changes)
pub let viz_mermaid_box : @ui.Style = @ui.css("w=Full")

///|
/// What the visualizations keep put back as the app begins anew (sfbase's reset).
pub fn viz_pages_reset() -> Unit {
  viz_frames.clear()
  viz_extra_frames.clear()
  viz_left_chats.clear()
  viz_heights.clear()
  viz_osc.clear()
  viz_mbui_states_clear()
  viz_full.set(None)
  mermaid_charts.clear()
  mermaid_used.clear()
  mermaid_shown.clear()
  mermaid_tick.val = 0
  mermaid_bytes.val = 0
}
