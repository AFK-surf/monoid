// A web service an agent started (a dev server, a report it serves), or a visualization it posted, as one view on
// every screen (still.fail web/src/Preview.tsx StationPreview, ServiceFrame, PreviewBar, Restart; PreviewStage.tsx,
// ViewportSize.tsx, PreviewLoad.tsx; Android's Preview.kt the phone's): found by its job (the `job` topic), known by
// its name, never its port; what serves its page and what it keeps is sfbase's (service_page.mbt, viz_file.mbt), its
// marks service_marks.mbt. The frame puts it where it goes: the phone's stack a page of its own under a bar with its
// way back (sfapp's service.mbt), a wide frame the chat's side panel's tab (sfdesk's service_tab.mbt).
//
// Its bar (@sf's page bar) over the page, a phone's two under it in a thumb's reach (as a phone's browser has them):
// back and forward in the page's own history, reload, how far its resources came (the `previewLoad` topic's ring;
// pressed, each of them in a panel), where it is (its name, then its path; typed, it goes there), its size, marking
// it. The page fills what is beside the bar, or is laid out at a size of
// its own (a phone's, a tablet's, a laptop's, a desktop's, one typed) on the grey of a canvas, fitted and centred, with
// its screen's corners; the ground dragged moves it, two fingers zoom it, a double tap fits it again. Its size is
// chosen in one place on every screen: the bar's size key, its choices in the presenters' panel (a sheet on a phone,
// beside the key with keyboard and mouse), with 移动页面 (a finger then moves the page in place of using it: said on the size key,
// pressed it stops) and 适应 once moved. Changing its size is now and then, so it keeps none of a phone's room under
// the page. A service being started again is said over the page, which loads anew once it is back. The size chosen is
// kept on the device (the core's prefs `previewSizes`).

///|
// kept across runs: a value (no field of it changes)
let note_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, center=true, w=Full)

///|
/// How far in from a panel's sides and the side its bar is not on the page stands alone in it: the nearest the theme lets
/// what lies in a corner stand (corner_fit's 4; the user, 2026-10-28: 网页边距 4px 差不多了).
let stage_in_panel_room : Double = @sf.corner_fit.near

///|
/// Where the page alone in a panel stands in from its sides and the side its bar is not on (stage_in_panel_room), and
/// its corners (top left, then round it): those away from its bar in the panel's corners there (pane_round: the
/// screen's at its edges, the system's at its foot, the tape's elsewhere; none beside the system's column) concentric
/// with them so far in, however round that makes them (an iPhone Duo's foot corner round its action: past the ladder's
/// most, as the panel's own is); those under its bar, in no corner of the panel's, the tape's so far in.
fn stage_in_panel(bar_at_foot~ : Bool, round? : FixedArray[@ui.CornerOf]? = @sf.pane_round.val) -> (Double, FixedArray[@ui.CornerOf]) {
  let r = match round {
    Some(k) => @sf.corner_radii(k)
    None => FixedArray::make(4, @sf.tape_corner)
  }
  let room = stage_in_panel_room
  let alone = @ui.concentric(@sf.tape_corner, room)
  (
    room,
    FixedArray::makei(4, fn(i) {
      if (i < 2) == bar_at_foot && r[i] > room {
        @ui.CornerOf::Own(@ui.concentric(r[i], room))
      } else {
        Own(alone)
      }
    }),
  )
}

///|
/// How far the page came, along the address's foot while its resources come (the accent), all of it red once one of
/// them failed; none once all came.
fn load_part(load : Json?) -> (Double, @ui.Color)? {
  if !(load is Some(Object(_))) {
    return None
  }
  if number(load, "failed") > 0.0 {
    Some((1.0, Danger))
  } else {
    let k = number(load, "percent") / 100.0
    if k >= 1.0 {
      None
    } else {
      Some((dmax(0.0, k), Accent))
    }
  }
}

///|
/// The bar under the page (service_foot_bar): on the page's ground (none of its own: what parts it from the page is
/// where it ends), a press's room high (@ui.room_least) over what lifts its keys into a panel's foot corners, its keys
/// keys_gap apart, the address taking what they leave (160 at least: a phone's 360 holds it, its four keys and their
/// rooms just so).
// kept across runs: a value (no field of it changes)
let foot_row_look : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
/// How far in its first and last keys stand at its sides where no corner of a panel's is to be followed: as a page
/// bar's, 8.
let foot_keys_in : Double = 8.0

///|
/// What the size key says: its size, or, while a finger moves the page, that a press stops it.
fn size_said(p : ServicePage) -> String {
  if p.moving.get() {
    svc("android-chat.preview.moveOff")
  } else {
    svc("android-chat.preview.size.title")
  }
}

///|
/// The size key: 28 high, round, 6 in, as wide as high at least (its icon alone in its
/// middle, as the bar's other keys); sized, on the chip's ground with its size (12) 5 after the icon, 8 in; moving the
/// page, on the accent's 14% in the accent's ink (as the mark key picking).
// kept across runs: a value (no field of it changes)
let size_key : @ui.Style = @ui.css("row h=S7 min_w=S7 radius=Full px=S1_5 gap=S1_25 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let size_key_sized : @ui.Style = size_key.then(@ui.css("px=S2 bg=Faint"))

///|
// kept across runs: a value (no field of it changes)
let size_key_moving : @ui.Style = size_key_sized.then(@ui.style(bg=@sf.mark_key_on))

///|
// kept across runs: a value (no field of it changes)
let size_key_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let size_key_words_moving : @ui.TextStyle = size_key_words.then(@ui.text_style(color=AccentText))

///|
/// What of the page's bar leaves it first where it is short of room, each to its ⋯: how far its resources came, then
/// its size (its words first, its key keeping its icon: chosen now and then), then reload; back and forward never, as
/// a browser's own (the user, 2026-10-27: 前进后退不能省吧).
let bar_drop_load : Int = 1

///|
let bar_drop_size_words : Int = 2

///|
let bar_drop_size : Int = 3

///|
let bar_drop_reload : Int = 4

///|
/// A line of the bar's ⋯: what a key that left the bar does, `on_press` once it is chosen.
fn bar_line(label : String, icon : String, disabled~ : Bool, on_press~ : () -> Unit) -> @sf.MenuItem {
  @sf.menu_item_of(label, on_press, icon~, disabled~)
}

///|
/// `390 × 844` (自动 for no height).
fn dims(w : Int, h : Int?) -> String {
  "\{w} × " +
  (match h {
    Some(x) => x.to_string()
    None => svc("android-chat.preview.auto")
  })
}

///|
/// A double tap on the ground: the second of two taps (Ctx::on_double_press), the one let go moving less than this.
let stage_tap_slop : Double = 12.0

///|
/// The page's corners, as its screen's: a phone's round, a tablet's less, a desktop's all but
/// square.
fn corner_of(width : Int, scale : Double) -> Double {
  if width <= 600 {
    44.0
  } else if width < 1024 {
    24.0
  } else {
    5.0 / scale
  }
}

///|
// kept across runs: a value (no field of it changes)
let service_restart_pill : @ui.Style = @ui.css("row pl=S4 pr=S4_5 py=S2_5 gap=S3 radius=Full align=AStart")

///|
// kept across runs: a value (no field of it changes)
let service_restart_dot : @ui.Style = @ui.css("w=S2 h=S2 radius=Full bg=Warn")

///|
// kept across runs: a value (no field of it changes)
let service_restart_words : @ui.Style = @ui.css("gap=SPx")

///|
// kept across runs: a value (no field of it changes)
let service_restart_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let service_restart_note : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// The preset a size is (either way round), if it is one.
fn preset_of(v : Viewport?) -> String? {
  match v {
    Some({ width, height: Some(h) }) =>
      match svc_presets.iter().find_first(fn(p) { (p.1 == width && p.2 == h) || (p.1 == h && p.2 == width) }) {
        Some(p) => Some(p.0)
        None => None
      }
    _ => None
  }
}

///|
/// All the sizes, the same on every screen, in node `v` (the panel's body), `close` closing it: as big as the preview,
/// the presets, 自定义; a page laid out at a size of its own moved by a finger in place of used (移动页面: what the
/// toolbar under the page had) and fitted again once moved or zoomed. Its rows a row's room, its words the theme's
/// (Rows, its ui and meta: a touch device's a finger's and a size up), a sheet on a phone and beside the size key with
/// keyboard and mouse (the presenters'). What it shows follows the page's size, whether a finger moves it and whether it
/// is fitted as they change (signals: ServicePage's `viewport`, `moving`, its view told).
fn page_sizes(v : @view.View, key : String, close : () -> Unit) -> Unit {
  let p = service_pages.get(key)
  let current = fn() {
    match p {
      Some(x) => x.viewport.get()
      None => None
    }
  }
  // what shows as it stands: the tools of a page laid out at a size of its own (移动页面), and among them 适应 where the
  // page is not fitted
  let tools_now = fn(x : ServicePage) { x.viewport.get() is Some(_) }
  let unfitted = fn(x : ServicePage) {
    // (whether it is fitted, as the view is told it: Zoom::told follows each change of where it shows)
    x.view.told()
    !x.view.fitted
  }
  // (closed by a press that changes what it shows: what it showed as it was closed is what it shows on its way out, no
  // more and no less, its rows not opening nor closing their way under a panel going; the check follows the row
  // chosen)
  let left : @signals.Signal[(Bool, Bool)?] = @signals.signal(None)
  // the panel closed after `change`, what shows as it stands kept first
  let leave = fn(change : () -> Unit) {
    match (p, left.get()) {
      (Some(x), None) => left.set(Some((tools_now(x), unfitted(x))))
      _ => ()
    }
    change()
    close()
  }
  v.box(fn(room) {
    @sf.style_node(room, fn() { sizes_room })
    let option = fn(checked : () -> Bool, name : () -> String, note : () -> String, size : Viewport?) {
      size_option_node(room, checked, name, note, fn() {
        leave(fn() {
          match p {
            Some(x) => {
              // a size chosen is fitted anew (at the press's moment); the page no longer moved by a finger
              x.moving.set(false)
              x.view.fit_now(at=room.cause_at())
              x.viewport.set(size)
              keep_size(key, size)
            }
            None => ()
          }
        })
      })
    }
    option(fn() { current() is None }, fn() { svc("android-chat.preview.fit") }, fn() { svc("android-chat.preview.fit.note") }, None)
    for pr in svc_presets {
      option(
        fn() { preset_of(current()) == Some(pr.0) },
        fn() { svc("android-chat.preview.preset." + pr.0) },
        fn() { dims(pr.1, Some(pr.2)) },
        Some({ width: pr.1, height: Some(pr.2) }),
      )
    }
    room.box(fn(g) { @sf.style_node(g, fn() { custom_gap }) }) |> ignore
    match p {
      Some(x) => {
        custom_size(room, x, key)
        // laid out at a size of its own: moved by a finger, fitted again (the toolbar's tools that were)
        let tools_shown = fn() {
          match left.get() {
            Some((tools, _)) => tools
            None => tools_now(x)
          }
        }
        room.show(tools_shown, fn(tools) {
          @sf.style_node(tools, fn() { sizes_tools })
          @sf.panel_switch_row_node(
            tools,
            fn() { svc("android-chat.preview.move") },
            fn() { x.moving.get() },
            fn(on) {
              // (on: what it changes is the page under the panel, so the panel goes)
              if on {
                leave(fn() { x.moving.set(true) })
              } else {
                x.moving.set(false)
              }
            },
            note=fn() { svc("android-chat.preview.move.note") },
          )
          let fit_shown = fn() {
            match left.get() {
              Some((_, fit)) => fit
              None => unfitted(x)
            }
          }
          tools.show(
            fit_shown,
            fn(b) {
              // (in by a row's padding: the switch over it lays out its own, panel_switch_row_node)
              @sf.style_node(b, fn() { sizes_fit })
              @sf.button_node(
                b,
                fn() { svc("android-chat.preview.fitView") },
                fn() {
                  leave(fn() {
                    x.view.fit_now(at=b.cause_at())
                    x.moving.set(false)
                  })
                },
                across=true,
              )
              |> ignore
            },
          )
        })
      }
      None => ()
    }
  })
  |> ignore
}

///|
/// A size's row in `parent` (the page's own: its check before its name, its note at its end), chosen while `checked()`:
/// its check's column on its words' line, its name a row's title (500 chosen), its note a row's note; as tall as a
/// row's least, its words as far in as the panel's (@sf.panel_words_in_node: panel_row_in's), the hover's ground under
/// the hand, rippling round its corner under a press; `press` done as it is pressed, read out a button named by it.
fn size_option_node(
  parent : @view.View,
  checked : () -> Bool,
  name : () -> String,
  note : () -> String,
  press : () -> Unit,
) -> Unit {
  parent.box(fn(o) {
    @sf.style_node(o, fn() {
      size_option.then(@sf.panel_row_in_node(o)).then(@ui.style(min_h=Fixed(@sf.theme().items.least)))
    })
    @sf.hover_ground_node(o)
    // (read out by its name and its size, as the old row was)
    @sf.rippled_node(o, press, @sf.row_corner, fn() { name() + " " + note() })
    // (its check's column, the check in its middle while chosen: along the row, at once)
    o.box(fn(k) {
      k.width(By(fn() { Some(@sf.theme().rows.check) })).row(Is(true)).lies_along(Is(Middle)) |> ignore
      k.show(checked, fn(i) { @sf.icon_node(i, "check", size_check_icon, By(fn() { @sf.theme().p.accent })) |> ignore })
    })
    |> ignore
    o.box(fn(n) {
      @sf.style_node(n, fn() { custom_name }, in_row=true)
      @sf.words_node(n, name, fn() { @sf.theme().rows.title.then(if checked() { size_name_on } else { size_name }) }) |> ignore
    })
    |> ignore
    @sf.words_node(o, note, fn() { @sf.theme().rows.note }) |> ignore
  })
  |> ignore
}

///|
/// The sizes' room (under them the presenter's foot); a size's row: at the panel's rows' edge, its check's column on
/// its words' line (@sf.panel_row_in_node), 8 apart, concentric with the panel; its name a row's title (500 chosen),
/// its note a row's note (Rows); the check 16.
// kept across runs: a value (no field of it changes)
let sizes_room : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let size_option : @ui.Style = @ui.css("row w=Full px=S2_5 gap=S2 align=ACenter")

///|
let size_check_icon : Double = 16.0

///|
/// A size's name: on its one line, whole (what it is, after it, gives way first).
// kept across runs: a value (no field of it changes)
let size_name : @ui.TextStyle = @ui.text_style(wrap=false)

///|
// kept across runs: a value (no field of it changes)
let size_name_on : @ui.TextStyle = @ui.text_style(weight=Medium, wrap=false)

///|
/// Moving and fitting under 自定义, 12 under it, 8 apart.
// kept across runs: a value (no field of it changes)
let sizes_tools : @ui.Style = @ui.css("w=Full pt=S3 gap=S2")

///|
/// Fitting under moving: a row's padding in.
// kept across runs: a value (no field of it changes)
let sizes_fit : @ui.Style = @ui.css("w=Full px=S2_5")

///|
/// The turn key's icon.
let custom_turn_icon : Double = 15.0

///|
/// 自定义's row: 10 under the sizes, its name where the sizes' names are (past a column
/// as wide as their check), its two fields the theme's rows' (Rows), 4 apart with × between them, the turn key 24
/// round (faint when there is nothing to turn), 6 in from the row's end: in the panel's corner, as far from its side as
/// from its foot, its round concentric with the panel's.
// kept across runs: a value (no field of it changes)
let custom_gap : @ui.Style = @ui.css("h=S2_5")

///|
// kept across runs: a value (no field of it changes)
let custom_row : @ui.Style = @ui.css("row w=Full pl=S2_5 pr=S1_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let custom_fields : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let custom_name : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let custom_field : @ui.Style = @ui.style(radius=@sf.custom_field_r, bg=Faint, px=S1_5, justify=JCenter)

///|
// kept across runs: a value (no field of it changes)
let custom_by : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let custom_turn : @ui.Style = @ui.css("w=S6 h=S6 radius=Full align=ACenter justify=JCenter")

///|
/// Any size, typed, in node `v`: the width, and the height (empty: as high as the preview leaves it), put as Enter is
/// pressed in either field; turned by the button. 72 × 36 fields on the chip's ground. While neither field has the
/// keys, they say the size the page is at, as it changes (what was typed and not put goes then, as it always went).
fn custom_size(v : @view.View, p : ServicePage, key : String) -> Unit {
  let r = fn() { @sf.theme().rows }
  // (the two fields' nodes, as they are made below)
  let fields : Array[@view.View] = []
  // (put at the moment of the key that put it)
  let commit = fn(at : Double) {
    let ws = p.custom_w.text()
    let hs = p.custom_h.text()
    let width = size_of(ws)
    let height = if hs == "" { Some(None) } else { size_of(hs).map(fn(x) { Some(x) }) }
    match (width, height) {
      (Some(w), Some(h)) => {
        let size : Viewport = { width: clamp_size(w), height: h.map(clamp_size) }
        let same = match p.viewport.get() {
          Some(x) => x.width == w && x.height == h
          None => false
        }
        if !same {
          p.moving.set(false)
          p.view.fit_now(at~)
          p.viewport.set(Some(size))
          keep_size(key, Some(size))
        }
      }
      _ => ()
    }
  }
  v.box(fn(row) {
    @sf.style_node(row, fn() { custom_row.then(@ui.style(min_h=Fixed(@sf.theme().items.least))) })
    // (its name where the sizes' names are: past a column as wide as their check)
    row.box(fn(g) { g.width(By(fn() { Some(r().check) })) |> ignore }) |> ignore
    row.box(fn(n) {
      @sf.style_node(n, fn() { custom_name }, in_row=true)
      @sf.words_node(n, fn() { svc("android-chat.preview.custom") }, fn() { r().title }) |> ignore
    })
    |> ignore
    let field = fn(parent : @view.View, f : @ui.Field, hint : String) {
      parent.box(fn(b) {
        @sf.style_node(b, fn() { custom_field.then(@ui.style(w=r().field_w, h=r().field_h)) })
        fields.push(@ui.field(
          b,
          f,
          placeholder_by=fn() { svc(hint) },
          max_lines=1,
          enter_sends=true,
          ime_action=@hostapi.ime_action_number,
          size_by=fn() { @sf.theme().t.ui },
          colors_by=fn() {
            let k = @sf.theme().p
            (k.text, k.subtle, k.accent)
          },
          // (digits alone, as they are typed)
          edited=fn(words) {
            let digits = size_digits(words)
            if digits != words {
              f.set(digits)
            }
          },
          submitted=fn(_) {
            commit(b.cause_at())
            f.let_go()
          },
        ))
      })
      |> ignore
    }
    row.box(fn(fs) {
      @sf.style_node(fs, fn() { custom_fields }, in_row=true)
      field(fs, p.custom_w, "android-chat.preview.width")
      @sf.words_node(fs, fn() { "×" }, fn() { custom_by }) |> ignore
      field(fs, p.custom_h, "android-chat.preview.auto")
    })
    |> ignore
    custom_turn_node(row, p, key)
  })
  |> ignore
  // what it is, unless someone is typing there (as of each change of the size or of whether either field has the keys)
  v.reacts(fn() { (p.viewport.get(), fields.iter().any(fn(f) { f.focused() })) }, fn(now) {
    guard !now.1 else { return }
    let (w, h) = match now.0 {
      Some(x) => (x.width.to_string(), x.height.map(fn(n) { n.to_string() }).unwrap_or(""))
      None => ("", "")
    }
    if p.custom_w.text() != w {
      p.custom_w.set(w)
    }
    if p.custom_h.text() != h {
      p.custom_h.set(h)
    }
  })
}

///|
/// The turn key in `parent` (24 round, its icon in the words' ink): the width and the height of a size with both
/// swapped, fitted anew at the press's moment; faint, taking no press and read out disabled where there is nothing to
/// turn; its name by it in the panel's tips.
fn custom_turn_node(parent : @view.View, p : ServicePage, key : String) -> Unit {
  let turnable = fn() {
    match p.viewport.get() {
      Some(x) => x.height is Some(_)
      None => false
    }
  }
  let label = fn() { @sf.t("web-main.viewport.turn") }
  let turn = fn(k : @view.View) {
    match p.viewport.get() {
      Some({ width, height: Some(h) }) => {
        let size : Viewport = { width: h, height: Some(width) }
        p.view.fit_now(at=k.cause_at())
        p.viewport.set(Some(size))
        keep_size(key, Some(size))
      }
      _ => ()
    }
  }
  @sf.action_box_node(parent, label, turn, disabled=fn() { !turnable() }, fn(k) {
    @sf.style_node(k, fn() { custom_turn })
    k.alpha(By(fn() { if turnable() { 1.0 } else { @ui.Opacity::O35.value() } })) |> ignore
    @sf.icon_node(k, "landscape", custom_turn_icon, By(fn() { @sf.theme().p.text })) |> ignore
    @sf.panel_tip_node(k, label)
  })
  |> ignore
}

///|
/// How the page's resources came, each of them, in node `v` (the panel's body): as tall as they are, scrolled past the
/// web's most (Preview.css.ts loadList: min(320px, 55vh)) on every screen. Each resource a row of its own by its id
/// (the core's, never used again), made as it comes and let go as the core lists it no more (the page loaded anew),
/// what it says bound to what the core says of it now.
fn load_list(v : @view.View, src : Source, station : String, port : Int) -> Unit {
  let load = fn() {
    src.topic("previewLoad", { "station": Json::string(station), "port": Json::number(port.to_double()) }).get().value
  }
  // (its words on the panel's words' line wherever it is drawn)
  v.box(fn(o) {
    @sf.style_node(o, fn() { @sf.panel_words_in_node(o) })
    @sf.sized_words_node(o, fn() { svc("android-chat.load.note") }, fn() { @sf.theme().t.caption }, fn() { @sf.theme().p.muted }) |> ignore
    o.box(fn(l) {
      l.padding(Is((0.0, 12.0, 0.0, 0.0))) |> ignore
      l.show(fn() { number(load(), "total") <= 0.0 }, fn(w) {
        @sf.sized_words_node(w, fn() { svc("android-chat.load.waiting") }, fn() { @sf.theme().t.meta }, fn() { @sf.theme().p.muted })
        |> ignore
      })
      // (the old view's capped box's: no taller than its most, what it holds scrolling in it)
      @sf.capped_node(l, fn() { dmin(load_list_most, load_list_share * l.window_h()) }, fn(b) {
        b.each(fn() { items(load(), "resources") }, fn(r) { number(Some(r), "id").to_int() }, fn(row, r) {
          // (in a box of no padding of its own: a row that comes or goes closes its way to none of it)
          row.box(fn(b) { load_row(b, fn() { Some(r.get()) }) }) |> ignore
        })
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A resource's row in node `b`, `rr` what the core says of it now: its path, what came of it (正在读取 till it ended,
/// then its status or 失败) and how long it took on its line, why it failed under it; red where it failed.
fn load_row(b : @view.View, rr : () -> Json?) -> Unit {
  let error = fn() { text(rr(), "error") }
  let ink = fn() {
    let t = @sf.theme()
    if error() != "" || number(rr(), "status") >= 400.0 {
      t.p.red
    } else {
      t.p.muted
    }
  }
  let ended = fn() { field(rr(), "ended") is Some(Number(_, ..)) }
  let caption = fn() { @sf.theme().t.caption }
  b.padding(Is((0.0, 6.0, 0.0, 6.0))) |> ignore
  b.box(fn(line) {
    line.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
    // (its path on its one line, cut short where the line leaves it less: the old one's max_lines=1)
    @sf.sized_words_node(line, fn() { text(rr(), "path") }, fn() { @sf.theme().t.meta }, ink, cut=true)
    .grow(Is(1.0))
    .basis(Is(Some(0.0)))
    |> ignore
    @sf.sized_words_node(
      line,
      fn() {
        if !ended() {
          svc("common.reading")
        } else if error() != "" {
          svc("android-chat.load.failed")
        } else {
          number(rr(), "status").to_int().to_string()
        }
      },
      caption,
      ink,
      wrap=false,
    )
    |> ignore
    line.show(ended, fn(m) {
      @sf.sized_words_node(
        m,
        fn() {
          let ms = dmax(0.0, number(rr(), "ended") - number(rr(), "since")).to_int64()
          "\{ms} ms"
        },
        caption,
        ink,
        wrap=false,
      )
      |> ignore
    })
  })
  |> ignore
  b.show(fn() { error() != "" }, fn(e) { @sf.sized_words_node(e, error, caption, ink) |> ignore })
}

///|
/// The resources' list at most: 320, 55% of the window where that is less.
let load_list_most : Double = 320.0

///|
let load_list_share : Double = 0.55

///|
fn load_label(v : Json?) -> String {
  let n = fn(k : String) { number(v, k).to_int().to_string() }
  if number(v, "failed") > 0.0 {
    svc("android-chat.load.label.failed", args=[
      ("percent", n("percent")),
      ("finished", n("finished")),
      ("total", n("total")),
      ("failed", n("failed")),
    ])
  } else {
    svc("android-chat.load.label", args=[("percent", n("percent")), ("finished", n("finished")), ("total", n("total"))])
  }
}

// ── a visualization as a page of its own ─

///|
// kept across runs: a value (no field of it changes)
pub let file_wait : @ui.Style = @ui.css("w=Full px=S5 py=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let file_name_box : @ui.Style = @ui.css("row w=Full clip")

///|
// kept across runs: a value (no field of it changes)
let file_name_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false, w=Cut)



///|
/// Where it says so (Restart): at the stage's foot, in its middle, 20 over it.
// kept across runs: a value (no field of it changes)
let service_restart_room : @ui.Style = @ui.css("w=Full h=Full pb=S5 align=ACenter justify=JEnd")

///|
/// How far the page's resources came, each of them, beside the ring that opened it: a
/// sheet with touch short of Large.
fn service_load_panel(src : Source, station : String, port : Int, from : @sf.Anchor) -> Unit {
  let words = fn() {
    load_label(src.topic("previewLoad", { "station": Json::string(station), "port": Json::number(port.to_double()) }).get().value)
  }
  @sf.panel_nodes(words(), fn(v, _) { load_list(v, src, station, port) }, from~, live=fn() { (words(), "", "") })
}

///|
/// The page's sizes (a phone's to a desktop's, 自定义 typed, turned), beside what
/// opened them; one chosen, they go.
pub fn service_sizes_panel(key : String, from : @sf.Anchor) -> Unit {
  @sf.panel_nodes(svc("android-chat.preview.size.title"), fn(v, close) { page_sizes(v, key, close) }, from~, focus=false)
}

