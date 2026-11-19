// The workspace's stations (settings/Stations.kt StationsScreen) made once as nodes of the window's tree in every frame,
// laid out by its width (page_node): a card each with its mark and what it is doing, what of its load runs low and how
// this device reaches it, a press away from its page; those that only run tasks after them, then the workspace's
// devices under their heading; none yet, the first to add. Its owners and admins add one (its ＋ at its title's end, or
// the frame's: a place's notch, the tape's bar).

///|
/// The stations' list (StationsScreen) in node `v`, laid out by the `width` its frame gives it (narrow where none is
/// given), in the frame it is given: its blocks as the core's stations, the workspace's rigs and its devices say them
/// now, each card by what it is of (a station by its address, one that only runs tasks by its id, a device by its
/// station and id) so one joining or leaving comes and goes where it is. Adding one (an owner's and an admin's, a
/// member's that only runs tasks) at its title's end, where the frame does not hold it itself (a place's notch names
/// the page: `frame().named`), or in a frame's bar (`bar_actions`). `here`: who and where, as that changes. `shown`:
/// whether the page shows now (a stack keeps a page made once while another is over it): how each station is reached
/// is sampled of it, so read only while it does, let go of as it is covered, as the old page's was.
pub fn stations_list_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
  bar_actions? : ((@view.View) -> Unit, (@sf.Look) -> Double) -> Unit,
  shown? : () -> Bool = fn() { true },
) -> Unit {
  let topic = fn() { @settings.stations_of(core, here()) }
  // (each list worked out once for each change of what it reads, read by the blocks and by each card)
  // (this machine's station first, the rest as the workspace lists them, as they joined it: the user, 2026-11-16)
  let stations_now : @signals.Computed[Array[Json]?] = @signals.computed(fn(_) {
    match topic().value {
      Some(Array(a)) => {
        let here = a.filter(fn(st) { @settings.is_this_machine(Some(st)) })
        Some(if here.length() == 0 { a } else { here + a.filter(fn(st) { !@settings.is_this_machine(Some(st)) }) })
      }
      _ => None
    }
  })
  let stations = fn() { stations_now.get() }
  // (each station by its address, as the list has them)
  let addresses_now = @signals.computed(fn(_) {
    match stations() {
      Some(a) => a.map(fn(st) { text(Some(st), "station") })
      None => []
    }
  })
  let addresses = fn() { addresses_now.get() }
  // (the list kept by address once, so a station's card is told only as its own station changes: View::keyed_by)
  let stations_by = v.keyed_by(fn() { stations().unwrap_or([]) }, fn(st) { text(Some(st), "station") })
  let rigs_now = @signals.computed(fn(_) { if stations() is Some(_) { @settings.rigs_listed(core, here()) } else { [] } }, same=jsons_same)
  let devices_now = @signals.computed(fn(_) { if stations() is Some(_) { @settings.devices_listed(core, here()) } else { [] } }, same=jsons_same)
  // (the rigs and the devices kept by their keys once, so a row is told only as its own one changes: View::keyed_by)
  let rigs_by = v.keyed_by(fn() { rigs_now.get() }, fn(x) { text(Some(x), "id") })
  let devices_by = v.keyed_by(fn() { devices_now.get() }, fn(x) { "device/" + text(Some(x), "station") + "/" + text(Some(x), "id") })
  let add = fn() { @settings.place_action(core, here(), "stations") is Some(_) }
  let adding = fn(at : @view.View) {
    match @settings.place_action(core, @signals.untracked(here), "stations") {
      Some(run) => run(Node(at))
      None => ()
    }
  }
  let label = fn() { @sf.t("android-misc.bar.action.stations") }
  let actions = fn(l : @view.View) {
    l.show(fn() { add() && !frame().named }, fn(a) { @sf.page_add_node(a, label, adding) })
  }
  match bar_actions {
    Some(f) => f(fn(l) { l.show(add, fn(a) { @sf.page_add_node(a, label, adding) }) }, fn(_) { @sf.button_height() })
    None => ()
  }
  @sf.page_node(
    v,
    fn() { @sf.t("android-misc.bar.place.stations") },
    fn() {
      match stations() {
        None => ["waiting"]
        Some(a) => {
          // (its stations one block, a card each by its address in it: one added to a list shown makes its way in,
          // View::each's, where the page's blocks come at once)
          let out : Array[String] = if a.length() == 0 { ["first"] } else { ["stations"] }
          for r in rigs_now.get() {
            out.push("rig/" + text(Some(r), "id"))
          }
          let devices = devices_now.get()
          if devices.length() > 0 {
            out.push("devices")
          }
          for d in devices {
            out.push("device/" + text(Some(d), "station") + "/" + text(Some(d), "id"))
          }
          out
        }
      }
    },
    fn(b, key) {
      match key {
        "waiting" =>
          @sf.waiting_node(
            b,
            fn(s) {
              s.each(fn() { stations_sample }, fn(st) { text(Some(st), "station") }, fn(row, st) {
                sl_station_card_node(row, core.quiet(), fn() { Some(st.get()) }, fn() {  })
              })
            },
            error=fn() {
              match topic().error {
                Some(e) => error_text(e)
                None => ""
              }
            },
          )
        "first" => sl_first_node(b, core, here, add, adding)
        "devices" => @sf.section_heading_node(b, fn() { @sf.t("web-pages.devices.title") })
        "stations" => {
          // (live station additions/removals open or close their card slots within this block; card-internal updates stay static)
          b.transitions_only() |> ignore
          let shown_addresses = @signals.signal(@signals.untracked(addresses), same=fn(a, b) { a == b })
          b.reacts(
            addresses,
            fn(next) {
              if !@view.answering_now() {
                @view.transition(within=b, fn() { shown_addresses.set(next) })
              } else {
                shown_addresses.set(next)
              }
            },
            at_start=false,
          )
          b.each(fn() { shown_addresses.get() }, fn(k) { k }, fn(row, k) {
            let address = k.untracked()
            // (its own station of the list, read by its address: told only as that one changes)
            row.box(fn(card) {
              card.transitions_only() |> ignore
              sl_station_card_node(card, core, fn() { stations_by.get(address) }, fn() { (core.push)(Station(address)) }, shown~)
            })
            |> ignore
            // (its menu where the pointer's other button is pressed on it: opened, its name or its address copied)
            row.on_menu(fn(m) {
              let name = text(@signals.untracked(fn() { stations_by.get(address) }), "name")
              @sf.menu(
                [
                  Some(@sf.menu_item_of(@sf.t("web-pages.rowMenu.open"), fn() { (core.push)(Station(address)) }, icon="arrow-up-right")),
                  copy_item("web-pages.rowMenu.copyName", name),
                  copy_item("web-pages.rowMenu.copyAddress", address),
                ].filter(fn(i) { i is Some(_) }),
                from=@sf.at_point(m.wx, m.wy),
              )
            })
            |> ignore
          })
        }
        k if k.has_prefix("rig/") => {
          let id = k.exact_view(start=4).to_owned()
          let r = fn() { rigs_by.get(id) }
          @sf.summary_mark_card_node(
            b,
            fn(m) { @sf.icon_node(m, "boxes", @sf.summary_mark_side, By(fn() { @sf.theme().p.text })) |> ignore },
            fn() { text(r(), "name") },
            fn() { @settings.rig_said(r()) },
            fn() { (core.push)(Station(here().workspace + "/" + id)) },
          )
        }
        k if k.has_prefix("device/") => {
          let d = fn() { devices_by.get(k) }
          @sf.summary_mark_card_node(
            b,
            fn(m) { @sf.icon_node(m, "", @sf.summary_mark_side, By(fn() { @sf.theme().p.text }), name_now=fn() { @settings.device_icon(d()) }) |> ignore },
            fn() { text(d(), "name") },
            fn() { @settings.device_said(d()) },
            fn() {
              let dv = @signals.untracked(fn() { d() })
              @settings.open_device(core, @signals.untracked(here), text(dv, "station"), text(dv, "id"), Unanchored)
            },
          )
        }
        _ => ()
      }
    },
    on_back~,
    frame~,
    actions~,
    said?,
    width?,
    tips?,
  )
}

///|
/// The stations to come while they are read: three made up, as the list shows them, in their bones.
// kept across runs: a value (no field of it changes)
let stations_sample : Array[Json] = [5, 3, 7].mapi(fn(i, n) {
  Json::object({
    "station": Json::string("sample/" + i.to_string()),
    "name": Json::string(@sf.sample_words(n)),
    "online": true,
    "summary": Json::string(@sf.sample_words(12)),
  })
})

///|
/// None in the workspace (StationsFirst): its scene, what a station is for, then its first added here step by step by
/// those who manage the workspace (the settings' first_station_steps_node), 添加 station for a member who may add one
/// that only runs tasks (`add`, `adding` given the button pressed: the settings' place_action), else that the others
/// wait for one who may; while the workspace is read, a line saying so.
fn sl_first_node(b : @view.View, core : Core, here : () -> Here, add : () -> Bool, adding : (@view.View) -> Unit) -> Unit {
  let ws = fn() { @settings.workspace_view(core, here()) }
  @sf.first_one_node(
    b,
    fn() { @sf.t("android-settings.station.first") },
    lead=fn() { @sf.t("android-settings.station.firstNote") },
    art=fn(a) {
      a.pick(fn() { @sf.theme().dark }, fn(x, dark) {
        @sf.drawable_node(x, if dark { "illus_no_station_dark" } else { "illus_no_station" }, sl_first_art_w) |> ignore
      })
    },
    fn(a0) {
      // (30 in from the screen's sides, as the page's first_station was: its steps' words and field off its edges)
      a0.box(fn(a) {
        @sf.style_node(a, fn() { sl_first_in })
        // (its managers add it here, step by step; a member one that only runs tasks, in 添加 station's panel; else they
        // wait for those who may, said on a warm ground)
        a.pick(fn() { if ws().value is None { None } else { Some((@settings.manages(core, here()) == Some(true), add())) } }, fn(e, can) {
          match can {
            Some((true, _)) => @settings.first_station_steps_node(e, core, @signals.untracked(here))
            Some((false, true)) =>
              @sf.button_opens_node(e, fn() { @sf.t("web-pages.settings.stations.add") }, adding, tone=Primary, icon="plus") |> ignore
            Some((false, false)) =>
              e.box(fn(w) {
                @sf.style_node(w, fn() { sl_wait_box })
                w.ground(By(fn() { @sf.alpha(sl_warn, 0.12) })) |> ignore
                @sf.words_node(w, fn() { @sf.t("android-settings.station.wait") }, fn() { sl_wait_words }) |> ignore
              })
              |> ignore
            None =>
              @sf.wait_line_node(e, fn() {
                match ws().error {
                  Some(x) => error_text(x)
                  None => @sf.t("android-settings.workspace.reading")
                }
              })
              |> ignore
          }
        })
      })
      |> ignore
    },
  )
}

///|
/// A row menu's item that copies `words` (its name, its address), said copied in the toast; none where there is nothing
/// to copy, so the menu never shows an item that does nothing.
fn copy_item(label : String, words : String) -> @sf.MenuItem? {
  guard words != "" else { return None }
  Some(
    @sf.menu_item_of(
      @sf.t(label),
      fn() { @sfbase.copy_out(words, said=@sf.t("web-pages.rowMenu.copied", args=[("name", words)])) },
      icon="copy",
    ),
  )
}

///|
/// A station's card (station_card's) in node `b`, as `s` says it now: its mark (a server's where it has none), its name,
/// where it joined from and what is said of it, reconnecting before its chevron; 加入安全模式 under that where its
/// workspace's safe mode does not name it and the viewer could protect it from here; then its body.
fn sl_station_card_node(
  b : @view.View,
  core : Core,
  s : () -> Json?,
  press : () -> Unit,
  shown? : () -> Bool = fn() { true },
) -> Unit {
  @sf.summary_mark_card_node(
    b,
    fn(m) {
      m.pick(fn() { @sf.has_station_mark(text(s(), "emoji"), text(s(), "icon")) }, fn(x, marked) {
        if marked {
          @sf.station_mark_node(x, fn() { text(s(), "emoji") }, fn() { text(s(), "icon") }, @sf.summary_mark_side, fn() { @sf.theme().p.text }, fn() { 0 })
        } else {
          @sf.icon_node(x, "server", @sf.summary_mark_side, By(fn() { @sf.theme().p.text })) |> ignore
        }
      })
    },
    fn() { text(s(), "name") },
    fn() { join([sl_joined(s()), text(s(), "summary")], " · ") },
    press,
    tag=fn() { if @settings.is_this_machine(s()) { @sf.t("web-pages.stations.thisMachine") } else { "" } },
    end=fn(e) {
      e.show(fn() { flag(s(), "reconnecting") }, fn(r) {
        @sf.style_node(r, fn() { sl_reconnecting }, in_row=true)
        @sf.spinner_node(r, size=12.0) |> ignore
        @sf.words_node(r, fn() { @sf.t("common.reconnecting") }, fn() { sl_reconnecting_words }) |> ignore
      })
    },
    body=fn(card) {
      card.show(fn() { flag(s(), "protect") }, fn(p) {
        @sf.style_node(p, fn() { sl_protect })
        let address = fn() { text(s(), "station") }
        let ws = fn() {
          match address().find("/") {
            Some(i) => address().unsafe_substring(start=0, end=i)
            None => ""
          }
        }
        let joining = fn() { is_doing(core, ["lock.joinStation"], [("workspace", ws()), ("station", text(s(), "id"))]) }
        @sf.button_node(
          p,
          fn() { @sf.t("web-pages.security.joinShort") },
          fn() {
            let sv = @signals.untracked(s)
            @settings.join_dialog(core, @signals.untracked(ws), text(sv, "id"), text(sv, "name"))
          },
          busy=joining,
          disabled=joining,
          icon="shield-check",
        )
        |> ignore
      })
      sl_station_body_node(card, core, s, shown)
    },
  )
}

///|
/// Where a station this workspace joined is at home, as grey words before what is said of it.
fn sl_joined(s : Json?) -> String {
  if !flag(s, "joined") {
    return ""
  }
  match opt_text(s, "home") {
    Some(h) => @sf.t("web-pages.stations.joinedFrom", args=[("name", h)])
    None => @sf.t("web-pages.stations.joinedElsewhere")
  }
}

///|
/// Under a station's name (StationBody's, as nodes): what of its load runs low and how this device reaches it, in the
/// same room whatever state it is in; offline, its picture asleep and a line saying so over that room; not read yet,
/// those in their bones; reconnecting, faded as last heard. How it is reached read only while the page shows (`shown`,
/// stations_list_node's).
fn sl_station_body_node(card : @view.View, core : Core, s : () -> Json?, shown : () -> Bool) -> Unit {
  let online = fn() { flag(s(), "online") }
  let host = fn() {
    match field(s(), "host") {
      Some(Object(_)) as h if online() => h
      _ => None
    }
  }
  // (how this device reaches it, while it is up: the core's `stationNet`, sampled while shown)
  let net = fn() {
    if !online() || !shown() {
      return None
    }
    match (core.topic)("stationNet", { "station": str(text(s(), "station")) }).get().value {
      Some(Object(_)) as n => n
      _ => None
    }
  }
  let faded = fn() { flag(s(), "reconnecting") }
  let seen = fn(known : Bool) {
    if !online() {
      0.0
    } else if !known {
      0.0
    } else if faded() {
      0.45
    } else {
      1.0
    }
  }
  let unreadable = fn() { items(s(), "problems").iter().any(fn(p) { text(Some(p), "key") == "incompatible" }) }
  card.box(fn(body) {
    @sf.style_node(body, fn() { sl_body })
    // its load's boxes, a chip's room kept whatever it shows (none read, or away); not read yet while up, grey bars over
    // their room
    body.box(fn(m) {
      m.min_height(Is(Some(@sf.fill_chip_h))) |> ignore
      m.box(fn(x) {
        x.alpha(By(fn() { seen(host() is Some(_)) })) |> ignore
        @sf.meter_line_node(x, fn() { items(host(), "meters") })
      })
      |> ignore
      m.show(fn() { online() && host() is None && !unreadable() }, fn(o) {
        o.over(Is(true)) |> ignore
        @sf.waiting_node(o, fn(w) { @sf.meter_line_node(w, fn() { sl_meters_sample }) })
      })
    })
    |> ignore
    // its network 10 under them; not read yet while up, grey bars over its line's room (the made-up one it keeps the
    // room of, unseen)
    body.box(fn(n) {
      n.box(fn(x) {
        x.alpha(By(fn() { seen(net() is Some(_)) })) |> ignore
        @sf.station_net_line_node(x, net)
      })
      |> ignore
      n.show(fn() { online() && net() is None }, fn(o) {
        o.over(Is(true)) |> ignore
        @sf.waiting_node(o, fn(w) { @sf.station_net_line_node(w, fn() { None }) })
      })
    })
    |> ignore
    // offline: its picture and a line saying so, across the room
    body.show(fn() { !online() }, fn(o) {
      o.over(Is(true)) |> ignore
      @sf.style_node(o, fn() { sl_offline })
      o.pick(fn() { @sf.theme().dark }, fn(x, dark) {
        let pic = if dark { "illus_station_offline_dark" } else { "illus_station_offline" }
        if @sf.has_drawable(pic) {
          @sf.drawable_node(x, pic, sl_offline_picture_w) |> ignore
        }
      })
      @sf.words_node(o, fn() { @sf.t("android-settings.stations.silent") }, fn() { sl_offline_words })
      .grow(Is(1.0))
      .min_width(Is(Some(0.0)))
      |> ignore
    })
  })
  |> ignore
}

///|
/// A machine's CPU, memory and disk made up, for what shows while they are read (in their bones).
// kept across runs: a value (no field of it changes)
let sl_meters_sample : Array[Json] = ["CPU", "RAM", "Disk"].map(fn(n) {
  Json::object({ "key": Json::string(n), "label": Json::string(n), "text": "00%", "level": "ok" })
})

// ── styles ─────────────────────────────────────────

///|
/// The scene over the first to add.
let sl_first_art_w : Double = 240.0

///|
/// The offline picture's width on a card: the room's height (the load's 20, 10, the network's two lines of 18 2 apart:
/// 68) times the picture's 2:1 (stations.mbt's offline_picture_w).
let sl_offline_picture_w : Double = 136.0

///|
/// Reconnecting before the chevron: the ring and its word, 5 apart.
// kept across runs: a value (no field of it changes)
let sl_reconnecting : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sl_reconnecting_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false)

///|
/// 加入安全模式's line, under the head.
// kept across runs: a value (no field of it changes)
let sl_protect : @ui.Style = @ui.css("row w=Full")

///|
/// The body, under the head: its load, and 10 under that its network.
// kept across runs: a value (no field of it changes)
let sl_body : @ui.Style = @ui.css("w=Full gap=S2_5")

///|
/// Offline: its picture and a line saying so, across the body's room, 12 apart.
// kept across runs: a value (no field of it changes)
let sl_offline : @ui.Style = @ui.css("row w=Full h=Full gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sl_offline_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, max_lines=3, w=Full)

///|
/// What adds the first, 30 in from the screen's sides as first_station's was (the page's own 12 and 18 more).
// kept across runs: a value (no field of it changes)
let sl_first_in : @ui.Style = @ui.css("w=Full px=S4_5")

///|
/// Where the viewer may not add one: that they wait, on a warm ground 12 round, its words 12 and 10 in.
// kept across runs: a value (no field of it changes)
let sl_wait_box : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 radius=Xl")

///|
/// The warm ground's ink (settings' warn).
let sl_warn : Int64 = 0xD9962BFFL

///|
// kept across runs: a value (no field of it changes)
let sl_wait_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L4_75, color=Fg, w=Full)
