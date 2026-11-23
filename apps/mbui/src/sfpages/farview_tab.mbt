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
/// Append `url` into the topmost open chat's composer draft (or copy to clipboard when no chat is on the stack).
fn send_url_to_open_chat(src : Source, url : String) -> Unit {
  guard url != "" else { return }
  let pages = @sfbase.app.nav.pages()
  let mut i = pages.length() - 1
  while i >= 0 {
    if pages[i] is Chat(r) {
      let w = @sfbase.writing(src, r.station + ":" + r.session)
      let cur = @signals.untracked(fn() { w.text.get() })
      let next = if cur == "" {
        url
      } else if cur.has_suffix("\n") || cur.has_suffix(" ") {
        cur + url
      } else {
        cur + " " + url
      }
      w.field.set(next)
      @sfbase.writing_text(src, w, next)
      @sfbase.toast_later(@sf.t("web-pages.remote.urlSent"))
      return
    }
    i -= 1
  }
  @ui.clipboard_set(url)
  @sfbase.toast_later(@sf.t("web-pages.remote.urlCopied"))
}

///|
/// Farview tab `screen` of `station` in `v`, filling it (farview_pane_node, which says the rest).
#callsite(autofill(loc))
pub fn farview_tab_node(v : @view.View, src : Source, station : String, screen : String, loc~ : SourceLoc) -> Unit {
  farview_pane_node(v, src, station, screen, loc~)
}

///|
/// Farview tab `screen` of `station` in `v`, filling it: its bar (back, forward, the page again, its address, control
/// menu; while an agent drives it, a line saying so with 接管) over the page drawn here, the page's viewport as tall as
/// what holds the tab gives it less that bar (Room::height: under a shell's own bars, a panel's, the window's top band,
/// whatever it is laid out in). The tab is viewed while this is shown.
#callsite(autofill(loc))
pub fn farview_pane_node(
  v : @view.View,
  src : Source,
  station : String,
  screen : String,
  title? : String = "",
  back? : () -> String,
  on_back? : () -> Unit,
  on_switch? : (@sfbase.Page) -> Unit,
  on_close? : () -> Unit,
  in_remote? : Bool = false,
  bar_pads? : () -> (Double, Double),
  on_window? : () -> Unit,
  tips? : @sf.TipLayer,
  top? : () -> Double = fn() { 0.0 },
  loc~ : SourceLoc,
) -> Unit {
  let switch_to = fn(next : @sfbase.Page) {
    match on_switch {
      Some(f) => f(next)
      None =>
        if @sfbase.lone_page.val is Some(_) {
          @sfbase.lone_page_replace(next)
        } else {
          @sfbase.open_page(next)
        }
    }
  }
  let close_here = fn() {
    match on_close {
      Some(f) => f()
      None =>
        match on_back {
          Some(b) => b()
          None => @sfbase.go_back() |> ignore
        }
    }
  }
  let open_new_tab = fn() {
    let scope = "fv-new/" + station
    let sub = @sfbase.hold(src, scope, "screens", { "station": Json::string(station) })
    @sfbase.press_wait(
      fn() { @sfbase.opens_answered(sub.get()) },
      fn() {
        let sval = @signals.untracked(fn() { sub.get().value })
        @sfbase.let_go(src, scope)
        let listed = items(sval, "screens")
          .filter(fn(sc) { flag(Some(sc), "userTab") || text(Some(sc), "id").has_prefix("browser:u_") })
          .map(fn(sc) { text(Some(sc), "id") })
        let next = @settings.new_browser_tab(src.call, station, listed, failed_said(@sf.t("web-pages.screen.openBrowserWhat")))
        switch_to(@sfbase.Page::Screen({ station, screen: next, title: "", until_gone: false }))
      },
      let_go=fn() { @sfbase.let_go(src, scope) },
      most=@sf.open_hold_ms,
    )
    |> ignore
  }
  // (`quiet`: the page closed it, which the station closes too: its answer not said)
  let close_tab_of = fn(quiet : Bool) {
    let scope = "fv-close/" + station
    let sub = @sfbase.hold(src, scope, "screens", { "station": Json::string(station) })
    @sfbase.press_wait(
      fn() { @sfbase.opens_answered(sub.get()) },
      fn() {
        let sval = @signals.untracked(fn() { sub.get().value })
        @sfbase.let_go(src, scope)
        let all_tabs = items(sval, "screens").filter(fn(sc) { text(Some(sc), "kind") == "browser" })
        (src.call)(
          "screen.close",
          Json::object({ "station": Json::string(station), "screen": Json::string(screen) }),
          if quiet {
            @sfbase.answer_unread
          } else {
            failed_said(@sf.t("web-pages.screen.closeTabWhat"))
          },
        )
        let rest = all_tabs.filter(fn(sc) { text(Some(sc), "id") != screen })
        if rest.is_empty() {
          close_here()
        } else {
          let idx = all_tabs.search_by(fn(sc) { text(Some(sc), "id") == screen }).unwrap_or(0)
          let pick = rest[if idx < rest.length() { idx } else { rest.length() - 1 }]
          switch_to(@sfbase.Page::Screen({ station, screen: text(Some(pick), "id"), title: text(Some(pick), "title"), until_gone: false }))
        }
      },
      let_go=fn() { @sfbase.let_go(src, scope) },
      most=@sf.open_hold_ms,
    )
    |> ignore
  }
  let close_current_tab = fn() { close_tab_of(false) }
  // (a tab the page asked for (a link to a new window, window.open, an OAuth popup): shown as it comes among the
  // station's screens, the first of this chat's tabs there that was not before (one already there on the page asked
  // for, or on none yet, is the one it opened))
  let follow_opened = fn(url : String) {
    let scope = "fv-opened/" + station
    let sub = @sfbase.hold(src, scope, "screens", { "station": Json::string(station) })
    let base = farview_tabs_of(screen)
    let before : Ref[Array[String]?] = Ref(None)
    let ours = fn(sval : Json?) {
      items(sval, "screens").filter(fn(sc) {
        let id = text(Some(sc), "id")
        id != screen && (id == base || id.has_prefix(base + "_"))
      })
    }
    let fresh = fn(sval : Json?) {
      let had = before.val.unwrap_or([])
      ours(sval).iter().find_first(fn(sc) { !had.contains(text(Some(sc), "id")) })
    }
    @sfbase.press_wait(
      fn() {
        let st = sub.get()
        if !@sfbase.opens_answered(st) {
          return false
        }
        if before.val is None {
          before.val = Some(
            ours(st.value)
            .filter(fn(sc) {
              let u = text(Some(sc), "url")
              u != url && u != "" && u != "about:blank"
            })
            .map(fn(sc) { text(Some(sc), "id") }),
          )
        }
        fresh(st.value) is Some(_)
      },
      fn() {
        let sval = @signals.untracked(fn() { sub.get().value })
        @sfbase.let_go(src, scope)
        match fresh(sval) {
          Some(sc) =>
            switch_to(@sfbase.Page::Screen({ station, screen: text(Some(sc), "id"), title: text(Some(sc), "title"), until_gone: false }))
          None => ()
        }
      },
      let_go=fn() { @sfbase.let_go(src, scope) },
      most=farview_opened_wait_ms,
      holds=false,
    )
    |> ignore
  }
  v.box(made_for=loc, fn(p) {
    // (as tall as what holds it gives it, never what the page in it comes to: its viewport is that height)
    p.grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).ground(By(fn() { @sf.theme().p.bg })) |> ignore
    let tab = farview_tab(src, station, screen)
    tab.shown = 1
    tab.open(src, station, screen)
    let find = FarviewFind::new()
    p.owns(fn() {
      tab.shown = 0
      tab.stage.find_clear()
      tab.close(src)
    })
    |> ignore
    // (a file input's picker the page asks for: the device's, once an ask; what it downloads kept on the device; a tab
    // it asks for shown as it comes, one it closes closed, back to another of the chat's)
    let picked = Ref(0)
    p.reacts(fn() { tab.stage.file_pick() }, fn(ask) {
      match ask {
        Some((n, wire_id, accept, multiple)) if n != picked.val => {
          picked.val = n
          farview_pick(tab.stage, wire_id, accept, multiple)
        }
        _ => ()
      }
    })
    p.reacts(fn() { tab.stage.downloads_seq() }, fn(_) { farview_keep_downloads(tab.stage) })
    p.reacts(fn() { tab.stage.opens_seq() }, at_start=false, fn(o) { follow_opened(o.1) })
    p.reacts(fn() { tab.stage.closed_by_page() }, at_start=false, fn(_) { close_tab_of(true) })
    // (思源黑体 given to the page as it comes)
    p.reacts(fn() { @sfbase.page_faces().length() }, fn(_) { @sfbase.page_faces().each(fn(f) { tab.stage.add_font(f) }) })
    let address = @ui.Field::new()
    p
    .key_context("Farview")
    .on_action("farview.address", fn(_) {
      address.focus()
      address.pick(0, address.text().length())
      true
    })
    .on_action("farview.reload", fn(_) {
      tab.stage.reload()
      true
    })
    .on_action("farview.back", fn(_) {
      tab.stage.back()
      true
    })
    .on_action("farview.forward", fn(_) {
      tab.stage.forward()
      true
    })
    .on_action("farview.tab_new", fn(_) {
      open_new_tab()
      true
    }, can=fn() { !in_remote })
    .on_action("farview.tab_close", fn(_) {
      close_current_tab()
      true
    }, can=fn() { !in_remote })
    .on_action("farview.find", fn(_) {
      find.show(tab.stage)
      true
    })
    .on_action("farview.find_next", fn(_) {
      find.step(tab.stage, 1)
      true
    })
    .on_action("farview.find_prev", fn(_) {
      find.step(tab.stage, -1)
      true
    })
    .on_action("farview.zoom.in", fn(_) {
      tab.stage.zoom_in()
      true
    })
    .on_action("farview.zoom.out", fn(_) {
      tab.stage.zoom_out()
      true
    })
    .on_action("farview.zoom.reset", fn(_) {
      tab.stage.zoom_reset()
      true
    })
    |> ignore
    let open_control = fn(from : @sf.Anchor) {
      let scope = "fv-menu/" + station
      let sub_s = @sfbase.hold(src, scope, "screens", { "station": Json::string(station) })
      let asks_t = (src.asks_terminals)()
      let sub_t = if asks_t {
        Some(@sfbase.hold(src, scope, "terminals", { "station": Json::string(station) }))
      } else {
        None
      }
      @sfbase.press_wait(
        fn() {
          @sfbase.opens_answered(sub_s.get()) &&
          (match sub_t { Some(st) => @sfbase.opens_answered(st.get()); None => true })
        },
        fn() {
          let sval = @signals.untracked(fn() { sub_s.get().value })
          let tval = match sub_t {
            Some(st) => @signals.untracked(fn() { st.get().value })
            None => None
          }
          @sfbase.let_go(src, scope)
          let scs = items(sval, "screens")
          let br_tabs = scs.filter(fn(sc) { text(Some(sc), "kind") == "browser" })
          let other_scs = scs.filter(fn(sc) { text(Some(sc), "kind") != "browser" })
          let user_ids = scs
            .filter(fn(sc) { flag(Some(sc), "userTab") || text(Some(sc), "id").has_prefix("browser:u_") })
            .map(fn(sc) { text(Some(sc), "id") })
          let can_term = flag(tval, "open")
          let can_browse = flag(sval, "browser") && flag(sval, "control")
          let open_terms = items(tval, "terminals").filter(fn(t) { !flag(Some(t), "ended") })
          let page_here : @sfbase.Page = @sfbase.Page::Screen({ station, screen, title, until_gone: false })
          @sf.panel_nodes(
            @sf.t("web-pages.screen.panel"),
            fn(sheet, done) {
              @sf.panel_group_node(sheet, fn() { "" }, fn(g) {
                @sf.panel_row_node(
                  g,
                  fn() { @sf.t("web-pages.screen.newTab") },
                  fn() {
                    done()
                    open_new_tab()
                  },
                  icon=fn() { "plus" },
                )
                for bt in br_tabs {
                  let bid = text(Some(bt), "id")
                  let btitle = {
                    let t = text(Some(bt), "title")
                    if t != "" { t } else { @sf.t("core-views.screen.kind.browser") }
                  }
                  let bnote = text(Some(bt), "url")
                  let cur = bid == screen
                  @sf.panel_row_node(
                    g,
                    fn() { btitle },
                    fn() {
                      done()
                      if !cur {
                        switch_to(@sfbase.Page::Screen({ station, screen: bid, title: btitle, until_gone: false }))
                      }
                    },
                    icon=fn() { "web" },
                    note=fn() { bnote },
                    end=if cur { "check" } else { "" },
                  )
                }
              })
              // (the page's own: words found on it, shown bigger or smaller, back to as laid out)
              @sf.panel_group_node(sheet, fn() { "" }, fn(g) {
                @sf.panel_row_node(
                  g,
                  fn() { @sf.t("web-pages.farview.find") },
                  fn() {
                    done()
                    find.show(tab.stage)
                  },
                  icon=fn() { "search" },
                )
                @sf.panel_row_node(
                  g,
                  fn() { @sf.t("desktop.menu.zoomIn") },
                  fn() {
                    done()
                    tab.stage.zoom_in()
                  },
                  icon=fn() { "plus" },
                )
                @sf.panel_row_node(
                  g,
                  fn() { @sf.t("desktop.menu.zoomOut") },
                  fn() {
                    done()
                    tab.stage.zoom_out()
                  },
                  icon=fn() { "minus" },
                )
                if @signals.untracked(fn() { farview_zoomed(tab.stage) }) {
                  let now = farview_zoom_said(@signals.untracked(fn() { tab.stage.zoom() }))
                  @sf.panel_row_node(
                    g,
                    fn() { @sf.t("web-pages.farview.zoomReset", args=[("zoom", now)]) },
                    fn() {
                      done()
                      tab.stage.zoom_reset()
                    },
                    icon=fn() { "text-size" },
                  )
                }
              })
              @sf.panel_group_node(sheet, fn() { "" }, fn(g) {
                @sf.panel_row_node(
                  g,
                  fn() { @sf.t("web-pages.remote.copyUrl") },
                  fn() {
                    let u = @signals.untracked(fn() { tab.stage.url() })
                    if u != "" {
                      @ui.clipboard_set(u)
                      @sfbase.toast_later(@sf.t("web-pages.remote.urlCopied"))
                    }
                    done()
                  },
                  icon=fn() { "copy" },
                )
                @sf.panel_row_node(
                  g,
                  fn() { @sf.t("web-pages.remote.sendUrlToChat") },
                  fn() {
                    let u = @signals.untracked(fn() { tab.stage.url() })
                    if u != "" {
                      send_url_to_open_chat(src, u)
                    }
                    done()
                  },
                  icon=fn() { "send" },
                )
                if @sfbase.window_opens_for(page_here) {
                  @sf.panel_row_node(
                    g,
                    fn() { @sf.t("web-pages.chat.openInWindow") },
                    fn() {
                      done()
                      if @sfbase.open_window(page_here) {
                        match on_window {
                          Some(handed) => handed()
                          None => close_here()
                        }
                      }
                    },
                    icon=fn() { "external" },
                  )
                }
                @sf.panel_row_node(
                  g,
                  fn() { @sf.t("web-pages.screen.closeTabFull") },
                  fn() {
                    done()
                    close_current_tab()
                  },
                  icon=fn() { "close" },
                  danger=true,
                )
              })
              if !other_scs.is_empty() || !open_terms.is_empty() || can_term || can_browse {
                @sf.panel_group_node(sheet, fn() { @sf.t("web-pages.remote.switchSession") }, fn(g) {
                  for sc in other_scs {
                    let sid = text(Some(sc), "id")
                    let stitle = text(Some(sc), "title")
                    let icon = if text(Some(sc), "kind") == "simulator" { "phone" } else { "monitor" }
                    @sf.panel_row_node(
                      g,
                      fn() { stitle },
                      fn() {
                        done()
                        switch_to(@sfbase.Page::Screen({ station, screen: sid, title: stitle, until_gone: false }))
                      },
                      icon=fn() { icon },
                    )
                  }
                  for tm in open_terms {
                    let tv = Some(tm)
                    let tid = text(tv, "id")
                    let tcwd = text(tv, "cwd")
                    let tlabel = terminal_title(tv)
                    @sf.panel_row_node(
                      g,
                      fn() { tlabel },
                      fn() {
                        done()
                        switch_to(@sfbase.Page::Terminal({ station, terminal: tid, watch: !can_term, cwd: tcwd }))
                      },
                      icon=fn() { "terminal" },
                      note=fn() { tcwd },
                    )
                  }
                  remote_new_session_rows_node(
                    g,
                    fn() { can_term },
                    fn() { can_browse },
                    done,
                    fn() { switch_to(@sfbase.Page::Terminal({ station, terminal: "new", watch: false, cwd: "" })) },
                    fn() {
                      let next = @settings.new_browser_tab(
                        src.call,
                        station,
                        user_ids,
                        failed_said(@sf.t("web-pages.screen.openBrowserWhat")),
                      )
                      let nu = screen_ui(screen_key(station, next))
                      nu.address_asked.set(nu.address_asked.untracked() + 1)
                      switch_to(@sfbase.Page::Screen({ station, screen: next, title: "", until_gone: false }))
                    },
                  )
                })
              }
            },
            from~,
            along=End,
            focus=false,
          )
        },
        let_go=fn() { @sfbase.let_go(src, scope) },
        most=@sf.open_hold_ms,
      )
      |> ignore
    }
    p.by_room(fn(col, room) {
      col.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      let chrome = col.box(fn(c) {
        if on_back is Some(back_fn) {
          c.box(fn(hd) {
            hd
            .row(Is(true))
            .gap(Is(8.0))
            .padding(By(fn() { (12.0, top() + 8.0, 12.0, 4.0) }))
            .lines_up(Is(Some(Middle)))
            |> ignore
            if @sfbase.lone_page.val is None {
              let back_words = match back {
                Some(bf) => bf
                None => fn() { @sf.t("common.back") }
              }
              @sf.icon_button_node(hd, "arrow-left", back_words, back_fn) |> ignore
            }
            hd.box(fn(tb) {
              tb.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              @sf.words_node(
                tb,
                fn() {
                  let u = tab.stage.url()
                  if title != "" { title } else if u != "" { u } else { @sf.t("core-views.screen.kind.browser") }
                },
                fn() { farview_head_words },
              )
              .cuts(Is(true))
              .min_width(Is(Some(0.0)))
              .allow_ellipsis(Is(true))
              |> ignore
            })
            |> ignore
            @sf.icon_button_node(hd, "plus", fn() { @sf.t("web-pages.screen.newTab") }, open_new_tab) |> ignore
            let page_here : @sfbase.Page = @sfbase.Page::Screen({ station, screen, title, until_gone: false })
            if @sfbase.window_opens_for(page_here) {
              @sf.icon_button_node(hd, "external", fn() { @sf.t("web-pages.chat.openInWindow") }, fn() {
                if @sfbase.open_window(page_here) {
                  close_here()
                }
              })
              |> ignore
            }
          })
          |> ignore
        }
        // (a window of its own, where one takes it and what shows it hands it over: beside the control button)
        let page_here : @sfbase.Page = @sfbase.Page::Screen({ station, screen, title, until_gone: false })
        let window = match on_window {
          Some(handed) if @sfbase.window_opens_for(page_here) =>
            Some(fn() {
              if @sfbase.open_window(page_here) {
                handed()
              }
            })
          _ => None
        }
        farview_bar_node(c, tab.stage, address, open_control, pads?=bar_pads, window?, tips?)
        farview_find_node(c, tab.stage, find, tips?)
        c.show(fn() { tab.stage.agent() }, fn(at) {
          // (a notice in the bar, a capsule inset from its sides and from the page under it: never edge to edge with
          // the page, whose ground is the page's own; round as 接管 is, the two concentric)
          at.padding(Is((8.0, 0.0, 8.0, 8.0))) |> ignore
          at.box(fn(line) {
            // (the words on one line, cut short where the row has not the room for them and 接管, never wrapped beside
            // it; 接管's middle on that line's, concentric capsule round it at any size of words)
            line
            .row(Is(true))
            .gap(Is(8.0))
            .padding(Is((6.0, 6.0, 6.0, 6.0)))
            .lines_up(Is(Some(Middle)))
            .ground(By(fn() { @sf.theme().p.neutral_bg }))
            .radius(Is(@sf.button_height() / 2.0 + 6.0))
            |> ignore
            line.box(fn(w) {
              // (its start off the capsule's round end, S3 in as the address's words in theirs: the line's 6 and the rest)
              w
              .grow(Is(1.0))
              .shrink(Is(1.0))
              .min_width(Is(Some(0.0)))
              .padding(Is((farview_words_in - 6.0, 0.0, 0.0, 0.0)))
              |> ignore
              @sf.words_node(w, fn() { @sf.t("web-pages.chat.screenAgent") }, fn() { farview_agent_words })
              .cuts(Is(true))
              .min_width(Is(Some(0.0)))
              .allow_ellipsis(Is(true))
              |> ignore
            })
            |> ignore
            line.box(fn(b) {
              @sf.button_node(b, fn() { @sf.t("android-misc.screen.takeOver") }, fn() { tab.stage.take_over() }, tone=Primary) |> ignore
            })
            |> ignore
          })
          |> ignore
        })
      })
      // (the page's viewport: as tall as the tab is given less what is over it, as tall as it is drawn; the window's
      // till the tab is first laid out)
      @stage.stage_node(
        col,
        tab.stage,
        height=Some(fn() { (room.height().unwrap_or(col.window_h()) - room.tall(chrome)).max(0.0) }),
        on_menu=Some(fn(hit) { farview_menu(tab.stage, hit, fn() { find.show(tab.stage) }) }),
      )
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
/// The tab's bar: ← → ⟳, its address (Enter going to what is typed there), and its control button; ← and → faded and
/// taking no press where the host says the tab has nothing to go back or forward to.
/// Where it stands at the pane's top (`pads`: 远程's), as high as a page's bar, its keys as far in from its ends as
/// the pane says, the last concentric with the window's corner, its empty part dragging the window; `window`: a window
/// of its own, beside the control button.
fn farview_bar_node(
  p : @view.View,
  stage : @stage.Stage,
  address : @ui.Field,
  open_control : (@sf.Anchor) -> Unit,
  pads? : () -> (Double, Double),
  window? : () -> Unit,
  tips? : @sf.TipLayer,
) -> Unit {
  let linked = if pads is Some(_) { Some(@sf.bar_keys_link) } else { None }
  p.box(fn(bar) {
    bar.row(Is(true)).gap(Is(4.0)).lines_up(Is(Some(Middle))) |> ignore
    match pads {
      Some(at) =>
        bar
        .height(By(fn() { Some(@sf.wide_bar_h + @sf.window_keys_bar_over_now()) }))
        .padding(By(fn() {
          let (s, e) = at()
          (s, @sf.window_keys_bar_over_now(), e, 1.0)
        }))
        .moves_window(By(@ui.window_inset_now))
        |> ignore
      None => bar.padding(Is((6.0, 8.0, 6.0, 8.0))) |> ignore
    }
    @sf.icon_button_node(bar, "arrow-left", fn() { @sf.t("web-pages.screen.back") }, fn() { stage.back() }, tips?, linked?, disabled=fn() {
      !stage.can_back()
    })
    |> ignore
    @sf.icon_button_node(bar, "arrow-right", fn() { @sf.t("web-pages.screen.forward") }, fn() { stage.forward() }, tips?, linked?, disabled=fn() {
      !stage.can_forward()
    })
    |> ignore
    @sf.icon_button_node(bar, "refresh", fn() { @sf.t("web-pages.screen.reloadShort") }, fn() { stage.reload() }, tips?, linked?)
    |> ignore
    // (@sf.address_field_node's: where the page is while nobody writes there; pressed into, all of it picked; Enter
    // goes, Escape gives the writing up)
    @sf.address_field_node(
      bar,
      address,
      fn() { stage.url() },
      fn(t) { stage.go(t) },
      fn() { @sf.t("web-pages.screen.goUrlShort") },
      placeholder=fn() { @sf.t("web-pages.screen.addressHint") },
      lead=fn(b) { @sf.icon_node(b, "web", @sf.theme().bars.icon, By(fn() { @sf.theme().p.muted })) |> ignore },
      least=0.0,
    )
    |> ignore
    // (how big the page is shown, while it is not as laid out: pressed, as laid out again)
    farview_zoom_node(bar, stage, tips?)
    let more_btn = Ref(bar)
    if window is Some(handed) {
      @sf.icon_button_node(bar, "external", fn() { @sf.t("web-pages.chat.openInWindow") }, handed, tips?, linked?) |> ignore
    }
    let mb = @sf.icon_button_node(
      bar,
      "more",
      fn() { @sf.t("web-pages.screen.panel") },
      fn() { open_control(Node(more_btn.val)) },
      tips?,
      linked?,
    )
    more_btn.val = mb
  })
  |> ignore
}

///|
// kept across runs: a style, read as it is
let farview_head_words : @ui.TextStyle = @ui.text_style(size=Body, weight=Medium, color=Fg, wrap=false)

///|
/// The agent's line's words: the body's, on one line.
// kept across runs: a value (no field of it changes)
let farview_agent_words : @ui.TextStyle = @ui.text_style(size=Body, color=Fg, wrap=false)

///|
/// How far in from the agent's line's start its words stand: as far as the address's words stand in their capsule
/// over it (@sf.address_field_node's capsule), clear of the capsule's round end.
let farview_words_in : Double = @ui.Space::S3.px()
