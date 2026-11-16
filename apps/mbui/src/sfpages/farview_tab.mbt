// A chat's Farview tab drawn by this app itself (Farview's stage, fvclient/stage: the page's boxes sent by its host and
// laid out, scrolled, hovered and typed in here), not as the station's pictures of it: the core's `farview.view`
// carries the tab's own protocol both ways (client/core-ts/src/farview.ts), its bytes fed to the stage as they come and
// what the stage says sent by `farview.send`. Opened while it is shown, let go as it goes; each open a conversation of
// its own with the tab's host (the stage told so, it says its viewport again). A tab is one by its id (`browser:fv_…`,
// the screens' list saying `farview` of it); shown in two places at once (beside its chat and on its page), each is a
// stage and a conversation of its own, with its own viewport.

///|
/// Whether screen `screen` is a Farview tab, which this app draws itself.
pub fn farview_screen(screen : String) -> Bool {
  screen.has_prefix("browser:fv_")
}

///|
/// Whether screen `screen` is a Farview tab drawn by this app now (实验性功能 › Farview 原生标签页渲染 on), else shown
/// as the station's pictures of it as any other screen.
pub fn farview_native_screen(screen : String) -> Bool {
  @sfbase.farview_native.get() && farview_screen(screen)
}

///|
/// One showing of a tab: its stage and the core's call that carries it (0 none open).
priv struct FarviewTab {
  stage : @stage.Stage
  view : String
  mut call : Int
  /// whether it is shown now (1) or idle (0), to be taken by the next place that shows the tab
  mut shown : Int
}

///|
// kept across runs: a tab's stages stay as they were left while the app runs, each taken again by what shows it next
let farview_tabs : Map[String, Array[FarviewTab]] = Map([])

///|
// kept across runs: only counts
let farview_views : Ref[Int] = Ref(0)

///|
/// A stage of tab `screen` of `station` not shown now (one left idle, else a new one): a place that shows the tab while
/// another does gets its own, its viewport its own.
fn farview_tab(src : Source, station : String, screen : String) -> FarviewTab {
  let key = station + "\n" + screen
  let kept = match farview_tabs.get(key) {
    Some(a) => a
    None => {
      let a = []
      farview_tabs[key] = a
      a
    }
  }
  match kept.search_by(fn(t) { t.shown == 0 }) {
    Some(i) => kept[i]
    None => {
      farview_views.val += 1
      let view = "fv-\{farview_views.val}"
      let t = {
        stage: @stage.Stage::new(
          fn(bytes) {
            (src.call_bytes)("farview.send", Json::object({ "view": Json::string(view) }), bytes, @sfbase.answer_unread)
          },
          forget=@ui.forget_image,
          fonts=@sfbase.page_faces(),
        ),
        view,
        call: 0,
        shown: 0,
      }
      kept.push(t)
      t
    }
  }
}

///|
/// The core's call opened: the host's bytes to the stage as they come, a new conversation each time it opens.
fn FarviewTab::open(self : FarviewTab, src : Source, station : String, screen : String) -> Unit {
  if self.call != 0 {
    return
  }
  let tab = self
  self.call = (src.stream)(
    "farview.view",
    Json::object({ "station": Json::string(station), "screen": Json::string(screen), "view": Json::string(self.view) }),
    None,
    fn(value, bytes) {
      match (value, bytes) {
        (Object(o), Some(b)) if o.contains("data") => tab.stage.feed(b)
        (Object(o), _) =>
          match o.get("state") {
            Some(Object(s)) =>
              match s.get("phase") {
                Some(String("live")) => tab.stage.opened()
                _ => tab.stage.closed()
              }
            _ => ()
          }
        _ => ()
      }
    },
    fn(_) {
      tab.call = 0
      tab.stage.closed()
    },
  )
}

///|
fn FarviewTab::close(self : FarviewTab, src : Source) -> Unit {
  if self.call != 0 {
    (src.cancel)(self.call)
    self.call = 0
  }
  self.stage.closed()
}

///|
/// Farview tab `screen` of `station` in `v`, filling it: its bar (back, forward, the page again, its address; while an
/// agent drives it, a line saying so with 接管) over the page drawn here, the page's viewport as tall as what holds the
/// tab gives it less that bar (Room::height: under a shell's own bars, a panel's, the window's top band, whatever it is
/// laid out in). The tab is viewed while this is shown.
#callsite(autofill(loc))
pub fn farview_tab_node(v : @view.View, src : Source, station : String, screen : String, loc~ : SourceLoc) -> Unit {
  v.box(made_for=loc, fn(p) {
    // (as tall as what holds it gives it, never what the page in it comes to: its viewport is that height)
    p.grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).ground(By(fn() { @sf.theme().p.bg })) |> ignore
    let tab = farview_tab(src, station, screen)
    tab.shown = 1
    tab.open(src, station, screen)
    p.owns(fn() {
      tab.shown = 0
      tab.close(src)
    })
    |> ignore
    // (思源黑体 given to the page as it comes)
    p.reacts(fn() { @sfbase.page_faces().length() }, fn(_) { @sfbase.page_faces().each(fn(f) { tab.stage.add_font(f) }) })
    p.by_room(fn(col, room) {
      col.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      let chrome = col.box(fn(c) {
        farview_bar_node(c, tab.stage)
        c.show(fn() { tab.stage.agent() }, fn(at) {
          // (a notice in the bar, a capsule inset from its sides and from the page under it: never edge to edge with
          // the page, whose ground is the page's own; round as 接管 is, the two concentric)
          at.padding(Is((8.0, 0.0, 8.0, 8.0))) |> ignore
          at.box(fn(line) {
            // (the words on one line, cut short where the row has not the room for them and 接管, never wrapped beside
            // it; 接管's middle on that line's: each stands down from the top by half of what the other is taller)
            line
            .row(Is(true))
            .gap(Is(8.0))
            .padding(Is((6.0, 6.0, 6.0, 6.0)))
            .lines_up(Is(Some(Start)))
            .ground(By(fn() { @sf.theme().p.neutral_bg }))
            .radius(Is(@sf.button_height() / 2.0 + 6.0))
            |> ignore
            let first_line = fn() { @sf.node_sp(line, @sf.ui_theme().text_size(Body).1) }
            let past = fn() { (@sf.button_height() - first_line()) / 2.0 }
            line.box(fn(w) {
              // (its start off the capsule's round end, S3 in as the address's words in theirs: the line's 6 and the rest)
              w
              .grow(Is(1.0))
              .shrink(Is(1.0))
              .min_width(Is(Some(0.0)))
              .padding(By(fn() { (farview_words_in - 6.0, past().max(0.0), 0.0, 0.0) }))
              |> ignore
              @sf.words_node(w, fn() { @sf.t("web-pages.chat.screenAgent") }, fn() { farview_agent_words })
              .cuts(Is(true))
              .min_width(Is(Some(0.0)))
              .allow_ellipsis(Is(true))
              |> ignore
            })
            |> ignore
            line.box(fn(b) {
              b.padding(By(fn() { (0.0, (-past()).max(0.0), 0.0, 0.0) })) |> ignore
              @sf.button_node(b, fn() { @sf.t("android-misc.screen.takeOver") }, fn() { tab.stage.take_over() }, tone=Primary) |> ignore
            })
            |> ignore
          })
          |> ignore
        })
      })
      // (the page's viewport: as tall as the tab is given less what is over it, as tall as it is drawn; the window's
      // till the tab is first laid out)
      @stage.stage_node(col, tab.stage, height=Some(fn() { (room.height().unwrap_or(col.window().1) - room.tall(chrome)).max(0.0) }))
      |> ignore
    })
    .grow(Is(1.0))
    .basis(Is(Some(0.0)))
    .min_height(Is(Some(0.0)))
    |> ignore
  })
  |> ignore
}

///|
/// The tab's bar: ← → ⟳ and its address, Enter going to what is typed there (an address, or words to search for).
fn farview_bar_node(p : @view.View, stage : @stage.Stage) -> Unit {
  p.box(fn(bar) {
    bar.row(Is(true)).gap(Is(4.0)).padding(Is((6.0, 8.0, 6.0, 8.0))).lines_up(Is(Some(Middle))) |> ignore
    @sf.icon_button_node(bar, "arrow-left", fn() { @sf.t("web-pages.screen.back") }, fn() { stage.back() }) |> ignore
    @sf.icon_button_node(bar, "arrow-right", fn() { @sf.t("web-pages.screen.forward") }, fn() { stage.forward() }) |> ignore
    @sf.icon_button_node(bar, "refresh", fn() { @sf.t("web-pages.screen.reloadShort") }, fn() { stage.reload() }) |> ignore
    let address = @ui.Field::new()
    bar.reacts(fn() { stage.url() }, fn(u) { address.set(u) })
    bar.box(fn(f) {
      f.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      @sf.style_node(f, fn() { farview_address })
      @ui.field(f, address, font_size=14.0, max_lines=1, enter_sends=true, ime_action=2, label=@sf.t("web-pages.screen.goUrlShort"), submitted=fn(
        t,
      ) {
        stage.go(t)
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
// kept across runs: a style, read as it is
let farview_address : @ui.Style = @ui.css("px=S3 py=S2 radius=Full bg=Neutral")

///|
/// The agent's line's words: the body's, on one line.
// kept across runs: a value (no field of it changes)
let farview_agent_words : @ui.TextStyle = @ui.text_style(size=Body, color=Fg, wrap=false)

///|
/// How far in from the agent's line's start its words stand: as far as the address's words stand in their capsule
/// over it (`farview_address`'s `px=S3`), clear of the capsule's round end.
let farview_words_in : Double = @ui.Space::S3.px()
