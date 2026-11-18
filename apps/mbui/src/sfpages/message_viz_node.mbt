// A visualization a message places (an HTML file drawn as a page: sfbase's viz_page.mbt) as nodes of the window's tree,
// in its row (viz_file_of's, as nodes): the frame and document viz_page.mbt keeps, its view ui's native in the row,
// what it waited under brushed off it as it comes in (sfbase's viz_reveal_node).

///|
/// The visualization `a` that message `ts` of chat `session` on `station` places, kept by session `key`, in `parent`
/// (viz_file_of's): its place 120 high, breathing, till its page has come and drawn itself; then the page, a fragment as
/// tall as it says, a whole page 16:9 of its width; its view ui's native, kept past its node (the chat keeps its pages
/// as it is left: viz_chat_left lets them go), one of its own for each copy drawn at once (viz_frame_of); under it the
/// ways to open it on its own (their tips in `tips`). What it cannot read, drawn by `failed` (its file's card).
fn message_viz_node(
  parent : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  station : String,
  session : String,
  key : String,
  ts : String,
  a : Attachment,
  failed : (@view.View) -> Unit,
) -> Unit {
  let load = @sfbase.viz_load_node(parent, src, station, key, a.path, size=a.size)
  let which = fn() {
    match load() {
      None => 0
      Some(Err(_)) => 1
      Some(Ok(_)) => 2
    }
  }
  let make_branch = fn(q : @view.View, k : Int) {
    match (k, @signals.untracked(load)) {
      (1, _) => failed(q)
      (2, Some(Ok((html, state)))) =>
        if @sfbase.is_mbui_viz(a.name) && @sfbase.viz_mbui_parse(a.name, html) is None {
          failed(q)
        } else {
          viz_shown_node(q, src, tips, station, session, key, ts, a, html, state)
        }
      _ =>
        // its place, breathing as every wait's shapes, till the page comes
        q.box(fn(w) {
          @sf.style_node(w, fn() { @sfbase.viz_wait_under })
          w.box(fn(i) {
            @sf.style_node(i, fn() { @sfbase.viz_wait })
            @sf.breathe_node(i)
          })
          |> ignore
        })
        |> ignore
    }
  }
  if @signals.untracked(load) is Some(_) {
    parent.pick(which, make_branch)
  } else if @sfbase.is_mbui_viz(a.name) {
    parent.pick(which, leave=msg_part_leave_ms, make_branch)
  } else {
    // (an HTML page come: drawn over its own breathing place till it has drawn itself and brushed in from under it
    // (viz_page_node's viz_reveal_node), so the place it waited in is let go at once, never fading over it as well)
    let page = fn() {
      match load() {
        Some(Ok(_)) => true
        _ => false
      }
    }
    parent.pick(page, fn(p, shows) {
      match (shows, @signals.untracked(load)) {
        (true, Some(Ok((html, state)))) => viz_shown_node(p, src, tips, station, session, key, ts, a, html, state)
        _ => p.pick(which, leave=msg_part_leave_ms, make_branch)
      }
    })
  }
}

///|
/// The page come (`html`, what its widget kept: `state`) of message_viz_node's, and the ways under it.
fn viz_shown_node(
  parent : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  station : String,
  session : String,
  key : String,
  ts : String,
  a : Attachment,
  html : String,
  state : Json?,
) -> Unit {
  parent.box(fn(b) {
    @sf.style_node(b, fn() { @sfbase.viz_file_box })
    let place = "chat/" + station + ":" + session + "/" + ts + "/" + a.path
    match @sfbase.viz_mbui_parse(a.name, html) {
      Some(widget) =>
        @sfbase.viz_mbui_node(
          b,
          place,
          widget,
          fn() { @sfbase.viz_state_of(station, key, a.path).unwrap_or(state.unwrap_or(Json::null())) },
          {
            keep: Some(fn(s) { @sfbase.viz_keep(src, station, key, a.path, s) }),
            failed: None,
            follow_up: Some(@sfbase.viz_follow_up(station, session)),
          },
        )
      None =>
        viz_page_node(b, place, html, state, {
          keep: Some(fn(s) { @sfbase.viz_keep(src, station, key, a.path, s) }),
          failed: None,
          follow_up: Some(@sfbase.viz_follow_up(station, session)),
        })
        |> ignore
    }
    // under the page, out of its way: the ways to open it on its own
    b.box(fn(ways) {
      @sf.style_node(ways, fn() { viz_node_ways })
      @sf.icon_button_node(
        ways,
        "expand",
        fn() { @sfbase.viz_tr("android-misc.viz.fullscreen") },
        fn() { viz_open_full(a.name, station, key, a.path, session) },
        tips~,
        size=viz_way_px,
        icon_size=14.0,
      )
      |> ignore
      @sf.icon_button_node(
        ways,
        "panel-open",
        fn() { @sfbase.viz_tr("android-misc.viz.openAside") },
        fn() {
          if @sfbase.is_mbui_viz(a.name) {
            @sfbase.open_preview(station, key, a, steps=@sfbase.InChat(None, session), beside=true)
          } else {
            open_page(@sfbase.PreviewFile(station, key, a.path, a.name))
          }
        },
        tips~,
        size=viz_way_px,
        icon_size=14.0,
      )
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A page of HTML (`html`, what its widget kept: `state`) drawn as `place` in `parent` (viz_frame's, as nodes): what it
/// says heard by `hears`; a fragment as tall as it says (by a move, the list's with what is round it), a whole page 16:9
/// of its width; its view ui's native, kept past its node (its chat keeps its pages as it is left), one of its own for
/// each copy drawn at once (viz_frame_of); its place, breathing, over it till it has drawn itself, then brought in
/// (viz_reveal_node). Its frame.
fn viz_page_node(parent : @view.View, place : String, html : String, state : Json?, hears : @sfbase.VizHears) -> @sfbase.VizFrame {
  let mut made : @sfbase.VizFrame? = None
  parent.box(fn(b) {
    // (its node's own: a view to each node drawing it, the same one again for the node that comes after it)
    let owner = -(b.id().at + 1)
    let t = @sf.theme()
    let f = @sfbase.viz_frame_of(place, html, state, hears, owner, ground=t.p.bg)
    f.owner = Some(owner)
    b.owns(fn() {
      if f.owner == Some(owner) {
        f.owner = None
      }
    }) |> ignore
    // the theme told only as it changes (viz_frame's)
    b.reacts(fn() { (@sf.theme().dark, @sf.theme().p.bg, @ui.font_scale()) }, fn(now) {
      let (dark, ground, _) = now
      if @sfbase.viz_theme_news(f, dark, ground) {
        @sfbase.viz_theme_tell(f, dark, ground)
      }
    })
    // drawn: what it said of its height, or a whole page (or a fragment that says none) loaded, and its host done
    // drawing it (viz_frame's cover)
    let drawn = fn() { f.drawn() }
    b.box(fn(fr) {
      if f.page {
        @sf.style_node(fr, fn() { @sfbase.viz_page_frame })
        fr.aspect(Is(1.0 / @sfbase.viz_page_ratio)) |> ignore
      } else {
        @sf.style_node(fr, fn() { viz_node_frame })
        fr.height(
          By(fn() {
            f.said.get() |> ignore
            Some((if f.height > 0 { f.height } else { @sfbase.viz_first_height }).to_double())
          }),
        )
        |> ignore
        // (as tall as it says by a move, the list's with what is round it: the height it comes to as its page says it
        // is for that word's moment, View::resizes; what was read over it does not step)
        // (its page telling its height is a live cause of its own: what it moves round it in its list goes its way too,
        // @view.transition)
        fr.reacts(
          fn() { f.said.get() },
          fn(_) { @view.transition(within=fr.transitions_root(), fn() { fr.resizes() |> ignore }) },
          at_start=false,
        )
      }
      // drawn, the first time: brought in, as a message's image is (viz_reveal_node), from that moment, once (however
      // soon its node is let go and made again, as its chat is left and gone back to); what it waited under let go at
      // its declared end. One drawn already (its chat kept as it was left) comes as it is.
      let revealing : @signals.Signal[Double?] = @signals.signal(None)
      // (its corners the placeholder's till what it waited under has gone from over it)
      let n = @ui.native(
        fr,
        f.view,
        corners=fn() {
          let r = if f.page || (@signals.untracked(drawn) && revealing.untracked() is None) {
            0.0
          } else {
            @ui.tree_theme().corner(Xl)
          }
          (r, r, r, r)
        },
        kept=true,
      )
      @sf.style_node(n, fn() { @sfbase.viz_fill })
      // till it has drawn itself, its place as while it came (the line's grey, breathing, its corners the
      // placeholder's), over it
      fr.show(at_once=true, fn() { !drawn() }, fn(o) {
        o.over(Is(true)) |> ignore
        @sf.style_node(o, fn() { @sfbase.viz_wait_ground })
        o.box(fn(i) {
          @sf.style_node(i, fn() { @sfbase.viz_wait_fill })
          @sf.breathe_node(i)
        })
        |> ignore
      })
      fr.reacts(drawn, fn(now) {
        if now && f.reveal is Some(_) && revealing.untracked() is None {
          let from = fr.cause_at()
          f.reveal = None
          revealing.set(Some(from))
          fr.at_moment(from + @sfbase.viz_reveal_ms, fn() { revealing.set(None) }) |> ignore
        }
      })
      fr.show(at_once=true, fn() { revealing.get() is Some(_) }, fn(o) {
        match revealing.untracked() {
          Some(from) => @sfbase.viz_reveal_node(o, f.page, from)
          None => ()
        }
      })
    })
    |> ignore
    made = Some(f)
  })
  |> ignore
  made.unwrap()
}

///|
/// A fragment's frame: the message's width, as tall as it says.
// kept across runs: a value (no field of it changes)
let viz_node_frame : @ui.Style = @ui.css("w=Full")

///|
/// The ways under it (viz_ways'), as far apart as the room a finger's press round each needs (44 in all).
// kept across runs: a value (no field of it changes)
let viz_node_ways : @ui.Style = @ui.css("row w=Full pt=S0_5 h=S6 gap=S6 justify=JEnd")

///|
/// Each way under it: viz_way's 22.
let viz_way_px : Double = 22.0
