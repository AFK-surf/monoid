// Going somewhere on the files' page: another station from a
// folder's trail (the station's button at its start: the same folder there when it has one, else its home; ⌥ in a new
// tab), and a folder by its path (⌘⇧G, as Finder's 前往文件夹): `mba:~/Projects` names the station before the colon, `~`
// its home, a path without a slash in front is under the folder shown; Tab completes a folder's name, as a terminal
// does. What is typed is worked out by the core (`files.go`).

///|
/// A folder typed by its path, worked out (`files.go`'s Typed): the station, the folder it names, the folder it is in
/// and what is typed of its last part.
#derive(Eq)
priv struct Typed {
  station : String
  abs : String
  parent : String
  partial : String
}

///|
/// ⌘⇧G's dialog (open, what is typed, the line chosen; what the core worked out for what was typed, by what; the
/// folders read where the last part is typed, which were asked) and the station's button whose menu is open.
priv struct Go {
  open : @signals.Signal[Bool]
  field : @ui.Field
  typed : @signals.Signal[String]
  at : @signals.Signal[Int]
  resolved : @signals.Signal[(String, Typed?)?]
  asking : @signals.Signal[String?]
  folders : @signals.Signal[(String, String, Array[String])?]
  asked : @signals.Signal[String]
  switching : @signals.Signal[Int]
}

///|
// kept across runs: the dialog's state (go_reset puts it back)
let go : Go = {
  open: @signals.signal(false, same=fn(a, b) { a == b }),
  field: @ui.Field::new(),
  typed: @signals.signal("", same=fn(a, b) { a == b }),
  at: @signals.signal(0, same=fn(a, b) { a == b }),
  resolved: @signals.signal(None),
  asking: @signals.signal(None),
  folders: @signals.signal(None),
  asked: @signals.signal("", same=fn(a, b) { a == b }),
  switching: @signals.signal(0, same=fn(a, b) { a == b }),
}

///|
fn go_reset() -> Unit {
  go.open.set(false)
  go.field.set("")
  go.typed.set("")
  go.at.set(0)
  go.resolved.set(None)
  go.asking.set(None)
  go.folders.set(None)
  go.asked.set("")
  go.switching.set(0)
}

///|
fn typed_of(v : Json?) -> Typed? {
  match v {
    Some(Object(_)) => Some({ station: text(v, "station"), abs: text(v, "abs"), parent: text(v, "parent"), partial: text(v, "partial") })
    _ => None
  }
}

///|
/// What is typed worked out by the core, from the folder `from` (`files.go`), answered.
fn go_resolve(src : Source, ws : String, typed : String, from : DriveAt, done : (Typed?) -> Unit) -> Unit {
  (src.call)(
    "files.go",
    {
      "workspace": Json::string(ws),
      "typed": Json::string(typed),
      "station": Json::string(from.station),
      "abs": Json::string(dv_absolute(from.root.unwrap_or(""), from.path)),
    },
    fn(r) {
      match r {
        Ok(v) => done(typed_of(Some(v)))
        Err(_) => ()
      }
    },
  )
}

///|
/// A child of a folder on a station (its own separator: Windows' backslash, else a slash).
fn child_of(folder : String, name : String) -> String {
  let sep = if folder.contains("\\") && !folder.contains("/") { "\\" } else { "/" }
  if folder.has_suffix(sep) {
    folder + name
  } else {
    folder + sep + name
  }
}

///|
/// The folder `abs` of `station` as a place to go: a root for one who browses everywhere, else under the folder it pins
/// that holds it (none: it cannot be gone to).
fn place_of(stations : Array[DvStation], station : String, abs : String) -> DriveAt? {
  match stations.iter().find_first(fn(s) { s.station == station }) {
    Some(s) if s.anywhere => Some({ station, root: Some(abs), path: "" })
    Some(s) =>
      match s.roots.iter().find_first(fn(r) { abs == r.path || abs.has_prefix(r.path + "/") }) {
        Some(r) =>
          Some({
            station,
            root: Some(r.path),
            path: if abs == r.path { "" } else { abs.exact_view(start=r.path.length() + 1).to_owned() },
          })
        None => None
      }
    None => None
  }
}

///|
/// ⌘⇧G (GoTo) of workspace `ws` from `here` (the side in front), asked for (from a press's or a key's handler): the
/// library's dialog (@sf.panel_nodes, opened by nothing: what it holds nodes of the window's tree, made once as it
/// opens); closed (Esc, ✕, a press outside), or down as a folder is gone to. `to`: a folder gone to.
pub fn go_to_ask(src : Source, ws : String, here : DriveAt, to : (DriveAt) -> Unit) -> Unit {
  go_reset()
  go.open.set(true)
  @sf.panel_nodes(
    @sf.t("web-pages.files.goTo"),
    fn(v, close) {
      // (a folder gone to: down)
      v.reacts(fn() { go.open.get() }, fn(open) { if !open { close() } }, at_start=false)
      go_body(v, src, ws, here, to)
    },
    from=Unanchored,
    description=@sf.t("web-pages.files.goToNote"),
    gone=fn() {
      go.open.set(false)
        },
  )
}

///|
/// What the dialog holds, in node `v` (the panel's body's): a field, where it goes under it; the stations while their
/// name is typed, then the folders whose name starts with what is typed of the last part (a combobox, @sf.combo_node:
/// Tab completes the one chosen, ↑ / ↓ choose, Enter goes).
fn go_body(v : @view.View, src : Source, ws : String, here : DriveAt, to : (DriveAt) -> Unit) -> Unit {
  let stations = fn() { drive_stations(src, ws).0.unwrap_or([]) }
  let from = dv_absolute(here.root.unwrap_or(""), here.path)
  // what is typed, worked out by the core as it changes (the last answer for what is typed now)
  v.reacts(fn() { go.typed.get() }, fn(typed) {
    let asked_for = typed + "\n" + here.station + "\n" + from
    if go.asking.get() != Some(asked_for) {
      go.asking.set(Some(asked_for))
      go_resolve(src, ws, typed, here, fn(r) {
        if go.asking.get() == Some(asked_for) {
          if v.alive() {
            @view.transition(within=v.transitions_root(), fn() { go.resolved.set(Some((typed, r))) })
          } else {
            go.resolved.set(Some((typed, r)))
          }
        }
      })
    }
  })
  let resolved = fn() {
    match go.resolved.get() {
      Some((_, r)) => r
      None => None
    }
  }
  let named = fn() {
    match resolved() {
      Some(r) => stations().iter().find_first(fn(s) { s.station == r.station })
      None => None
    }
  }
  // the folders where the last part is typed, read as the way to it changes
  v.reacts(
    fn() {
      match (resolved(), named()) {
        (Some(r), Some(n)) if n.anywhere => Some((r.station, r.parent))
        _ => None
      }
    },
    fn(way) {
      guard way is Some((station, parent)) else { return }
      let key = station + "\n" + parent
      if go.asked.get() != key {
        go.asked.set(key)
        (src.call)("drive.folders", { "station": Json::string(station), "path": Json::string(parent) }, fn(a) {
          if go.asked.get() == key {
            let set_folders = fn() {
              go.folders.set(Some((station, parent, match a {
                Ok(v) => items(Some(v), "entries").map(fn(e) { text(Some(e), "name") })
                Err(_) => []
              })))
            }
            if v.alive() {
              @view.transition(within=v.transitions_root(), set_folders)
            } else {
              set_folders()
            }
          }
        })
      }
    },
  )
  // the lines: what each says, what Tab puts in, where it goes; the stations while their name is typed (nothing before
  // a colon yet), then folders whose name starts with what is typed
  let rows = fn() -> Array[(String, String, (String, String)?)] {
    let typed = go.typed.get()
    let stations = stations()
    let rows : Array[(String, String, (String, String)?)] = []
    if typed != "" && !typed.contains(":") && !typed.has_prefix("/") && !typed.has_prefix("~") {
      for s in stations {
        if @sf.lower(s.name).has_prefix(@sf.lower(typed)) {
          rows.push((s.name, @sf.lower(s.name) + ":~/", if s.home != "" { Some((s.station, s.home)) } else { None }))
        }
      }
    }
    match (resolved(), named(), go.folders.get()) {
      (Some(r), Some(n), Some((fs, fp, names))) if fs == r.station && fp == r.parent => {
        let prefix = if r.station == here.station && !typed.contains(":") { "" } else { @sf.lower(n.name) + ":" }
        let found = names.filter(fn(name) { !name.has_prefix(".") && @sf.lower(name).has_prefix(@sf.lower(r.partial)) })
        for name in found[:if found.length() > go_most { go_most } else { found.length() }] {
          let abs = child_of(r.parent, name)
          rows.push((n.name + " › " + abs, prefix + abs + "/", Some((r.station, abs))))
        }
      }
      _ => ()
    }
    rows
  }
  // (what is chosen kept among them as they change)
  v.reacts(fn() { rows().length() }, fn(n) {
    if go.at.get() >= n {
      go.at.set(if n > 0 { n - 1 } else { 0 })
    }
  })
  let open = fn(target : (String, String)?) {
    match target {
      Some((st, abs)) =>
        match place_of(stations(), st, abs) {
          Some(p) => {
            go.open.set(false)
            v.focus_let_go()
            to(p)
          }
          None => ()
        }
      None => ()
    }
  }
  // Enter: as typed now, whatever came back for what was typed before; the line at `at` where it was picked (pressed,
  // or the keys moved onto it) or a folder's name is being typed, else the folder typed itself
  let enter = fn(at : Int, picked : Bool, r : Typed?) {
    let chosen = rows().get(at)
    match (r, chosen) {
      (Some(r), Some((_, _, target))) if r.partial != "" || picked => open(target)
      (Some(r), _) => open(Some((r.station, r.abs)))
      (None, Some((_, _, target))) => open(target)
      _ => ()
    }
  }
  let enter_now = fn(at : Int, picked : Bool) {
    let words = go.field.text()
    match go.resolved.get() {
      Some((was, r)) if was == words => enter(at, picked, r)
      _ => go_resolve(src, ws, words, here, fn(r) { enter(at, picked, r) })
    }
  }
  // Tab completes the one chosen, a key its field leaves to what holds it, as it comes
  v
  .on_key(fn(k) {
    guard k.mods == 0 && k.code == @ui.key_tab else { return false }
    match rows().get(go.at.get()) {
      Some((_, complete, _)) => {
        go.field.set(complete)
        go.typed.set(complete)
        go.at.set(0)
      }
      None => ()
    }
    true
  })
  |> ignore
  // (the field and the lines under it a combobox, the library's (@sf.combo_node): ↓ ↑ move what is chosen, the
  // window's keymap's where the field has the keys (combobox_bindings), the field's caret left where it is; Enter goes)
  @sf.combo_node(
    v,
    fn() { @sf.t("web-pages.files.goTo") },
    fn() { rows().map(fn(x) { x.0 }) },
    go.at,
    fn(at, picked) { enter_now(at, picked) },
    fn(c) {
      c.box(fn(b) {
        @sf.style_node(b, fn() { go_field_box })
        // (round its words the field's to a press too: a tap its caret and its menu to paste, a long press its 粘贴)
        @ui.field_backdrop(b, go.field)
        let f = @ui.field(
          b,
          go.field,
          placeholder=@sf.t("web-pages.files.goToPlaceholder"),
          font_size=go_font,
          line=go_line,
          max_lines=1,
          enter_sends=true,
          leaves=[@ui.key_code_down, @ui.key_code_up, @ui.key_tab],
          colors_by=fn() {
            let p = @sf.theme().p
            (p.text, p.subtle, p.accent)
          },
          // Enter with no line under it: gone to, as it is pressed (where it was found already, at once; else once the
          // core finds it)
          submitted=fn(_) { enter_now(go.at.get(), false) },
          edited=fn(words) {
            go.typed.set(words)
            go.at.set(0)
          },
        )
        f.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        // (a dialog's only field: it has the keys as it opens)
        @sf.panel_opens_in_node(f)
      })
      |> ignore
      c.show(fn() { resolved() is Some(_) && named() is Some(_) }, fn(w) {
        @sf.style_node(w, fn() { go_where_box })
        @sf.words_node(
          w,
          fn() {
            match (resolved(), named()) {
              (Some(r), Some(n)) => n.name + " › " + r.abs
              _ => ""
            }
          },
          fn() { go_where },
        )
        |> ignore
      })
    },
    fn(label) { label },
    fn(row, label, on) {
      @sf.style_node(row, fn() { if on() { go_row_on } else { go_row } })
      @sf.icon_node(row, "folder", go_icon, By(fn() { @sf.theme().p.muted })) |> ignore
      // (as wide as the row leaves it: go_row_words' w=grow)
      @sf.words_node(row, fn() { label }, fn() { go_row_words }).grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0)))
      |> ignore
      row.show(on, at_once=true, fn(k) {
        @sf.style_node(k, fn() { go_key_box }, in_row=true)
        @sf.words_node(k, fn() { "Tab" }, fn() { go_key }) |> ignore
      })
    },
    list=fn(list) { @sf.style_node(list, fn() { go_list }) },
    foot=fn(c) {
      c.box(fn(k) {
        @sf.style_node(k, fn() { go_keys_box })
        @sf.words_node(k, fn() { @sf.t("web-pages.files.goToKeys") }, fn() { go_keys }) |> ignore
      })
      |> ignore
    },
  )
  |> ignore
}

///|
/// The station's button before a folder's trail (StationSwitch) in `parent`, of the folder `at` station `st` shows in
/// workspace `ws`: the workspace's stations with a drive (the one shown checked; one away not to be picked; this
/// machine and the one shown said); picked, the same folder there when it has one, else its home (said so); ⌥ held, in
/// a new tab (`open_in`). `go`: a folder shown in its place; `front_it`: what is pressed in a side puts it in front
/// first.
fn station_switch_node(
  parent : @view.View,
  src : Source,
  ws : String,
  at : DriveAt,
  st : () -> DvStation,
  go : (DriveAt) -> Unit,
  open_in : ((DriveAt, Bool) -> Unit)?,
  front_it : () -> Unit,
) -> Unit {
  let here = this_machine()
  let switching = @signals.signal(0)
  // picked: the same folder there when it has one, else its home (said so); ⌥ held as it is picked, in a new tab
  let picked = fn(station : String) {
    let stations = drive_stations(src, ws).0.unwrap_or([])
    match stations.iter().find_first(fn(s) { s.station == station }) {
      Some(s) if station != at.station && s.online => {
        let tab = (@ui.mods_held() & @ui.mod_alt) != 0
        let open_at = fn(root : String, same : Bool) {
          if !same {
            toast_later(@sf.t("web-pages.files.notThere", args=[("name", s.name)]))
          }
          let pane : DriveAt = { station, root: Some(root), path: "" }
          match open_in {
            Some(o) if tab => o(pane, false)
            _ => go(pane)
          }
        }
        let abs = dv_absolute(at.root.unwrap_or(""), at.path)
        if s.anywhere && s.home != "" {
          (src.call)("drive.folders", { "station": Json::string(station), "path": Json::string(abs) }, fn(r) {
            match r {
              Ok(v) if !flag(Some(v), "unreadable") => open_at(abs, true)
              _ => open_at(s.home, false)
            }
          })
        } else {
          match s.roots.get(0) {
            Some(r) => open_at(r.path, false)
            None => ()
          }
        }
      }
      _ => ()
    }
  }
  let open = fn() { switching.get() != 0 && @sf.presented_drawn_of(switching.get()) }
  @sf.action_box_node(parent, fn() { @sf.t("web-pages.files.switchStation") }, expanded=open, fn(b) {
      front_it()
      // the stations with a drive (this machine, the one shown, one away said beside each), the one shown chosen: the
      // library's pick under it
      let stations = drive_stations(src, ws).0.unwrap_or([])
      let choices = stations.map(fn(s) {
        let meta : Array[String] = []
        if s.station == here {
          meta.push(@sf.t("web-pages.files.thisMachine"))
        }
        if s.station == at.station {
          meta.push(@sf.t("web-pages.files.current"))
        }
        if !s.online {
          meta.push(@sf.t("web-pages.stations.offline"))
        }
        // (each by its mark, as the chip names the one shown)
        @sfbase.station_choice(s.station, s.name, s.emoji, s.icon, value=meta.join(" · "))
      })
      @sf.pick(@sf.t("web-pages.files.switchNote"), choices, at.station, picked, from=Node(b))
      switching.set(@sf.last_presented())
  }, fn(b) {
    @sf.style_node(b, fn() { switch_button }, in_row=true)
    @sf.hover_ground_node(b)
    b.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    station_mark_of_node(b, st, switch_icon, here)
    @sf.words_node(b, fn() { st().name }, fn() { switch_words }) |> ignore
    @sf.icon_node(b, "chevron-down", switch_chevron, By(fn() { @sf.theme().p.muted })) |> ignore
  })
  |> ignore
}

///|
/// A station's mark in `parent`, `size` across (station_icon's, as nodes): its own mark where it has one, else this
/// machine's or a station's.
pub fn station_mark_of_node(parent : @view.View, st : () -> DvStation, size : Double, here : String) -> Unit {
  parent.pick(fn() {
    let s = st()
    (@sf.has_station_mark(s.emoji, s.icon), s.station == here)
  }, at_once=true, fn(m, which) {
    match which {
      (true, _) => @sf.station_mark_node(m, fn() { st().emoji }, fn() { st().icon }, size, fn() { @sf.theme().p.muted }, fn() { 0 })
      (false, mine) => @sf.icon_node(m, if mine { "monitor" } else { "server" }, size, By(fn() { @sf.theme().p.muted })) |> ignore
    }
  })
}

///|
/// ⌘⇧G's: at most this many folders listed; its field's
/// words 14 on 20; a row's mark 16; the button's mark 14, its chevron 12.
let go_most : Int = 8

///|
let go_font : Double = 14.0

///|
let go_line : Double = 20.0

///|
let go_icon : Double = 16.0

///|
let switch_icon : Double = 14.0

///|
let switch_chevron : Double = 12.0

///|
/// Its field (goInput): the controls' input, in the mono face's place.
// kept across runs: a value (no field of it changes)
let go_field_box : @ui.Style = @ui.css("row w=Full h=S9 px=S3 align=ACenter radius=Lg bg=Tint")

///|
/// Where it goes (goWhere): 8 under the field, muted, small.
// kept across runs: a value (no field of it changes)
let go_where : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let go_where_box : @ui.Style = @ui.css("w=Full pt=S2")

///|
/// Its lines (goList: 2 apart, 10 under), each (goRow) 7 by 10 in, 8 between its parts, the one chosen on the selected
/// ground.
// kept across runs: a value (no field of it changes)
let go_list : @ui.Style = @ui.css("w=Full gap=S0_5 pt=S2_5")

///|
// kept across runs: a value (no field of it changes)
let go_row : @ui.Style = @ui.css("row w=Full h=S8 px=S2_5 gap=S2 align=ACenter radius=Lg")

///|
// kept across runs: a value (no field of it changes)
let go_row_on : @ui.Style = go_row.then(@ui.css("bg=Selected"))

///|
// kept across runs: a value (no field of it changes)
let go_row_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=@sf.grow)

///|
/// The key (kbd): 5 in at its sides, a hairline round it, its corner 4.
// kept across runs: a value (no field of it changes)
let go_key_box : @ui.Style = @ui.css("px=S1_25 radius=Base border=B0_5 border_color=Line")

///|
// kept across runs: a value (no field of it changes)
let go_key : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false)

///|
/// Under the list, its keys (goKeys): 10 under it, faint.
// kept across runs: a value (no field of it changes)
let go_keys : @ui.TextStyle = @ui.text_style(size=Caption, color=Subtle, w=Full)

///|
// kept across runs: a value (no field of it changes)
let go_keys_box : @ui.Style = @ui.css("w=Full pt=S2_5")

///|
/// The station's button (switchButton): 22 high, 7 in, 5 between, a hairline round it on the raised ground, its corner
/// the options'.
// kept across runs: a value (no field of it changes)
let switch_button : @ui.Style = @ui.css((
  #|row h=S6 px=S2 gap=S1_25 align=ACenter radius=Lg bg=Raised border=B0_5 border_color=Line
))

///|
// kept across runs: a value (no field of it changes)
let switch_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false, w=Cut)

