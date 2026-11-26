// The files' places, as Finder's sidebar (still.fail web/src/pages/FilesNav.tsx): the person's own folders kept at hand
// (个人收藏, of any station: files_model.mbt, including old pins), then every station of the workspace with a drive,
// opened to its places. One list, the 中屏 and 大屏 frames' sidebar and the phone's 文件 alike, as nodes of the window's
// tree: a page's list of its lines by key, each made only while it shows, a favorite coming and going where it is. A
// row opens its folder; something dragged onto one goes into it, and a folder dragged onto 个人收藏 is kept there
// (files_drag.mbt).

///|
/// The stations opened in the places (to their places), by station.
// kept across runs: put back by places_reset
let places_open : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()

///|
/// The places forget which stations were opened (a run anew).
pub fn places_reset() -> Unit {
  places_open.clear()
}

///|
/// A station's row opened to its places (as a press on its disclosure does).
pub fn nav_open(station : String) -> Unit {
  places_open.put(station, true)
}

///|
/// What the places' list holds: a line of it, by its key (what it is: its kind, and what it is of).
#derive(Eq)
priv enum PlaceLine {
  PTrouble(String)
  PReading
  PNone
  PFavoriteHead
  PFavoriteHint
  PFavorite(Favorite, DvStation, Bool)
  PHeading
  PStation(DvStation, Bool)
}

///|
/// A line's key among the places'.
fn place_line_key(l : PlaceLine) -> String {
  match l {
    PTrouble(_) => "trouble"
    PReading => "reading"
    PNone => "none"
    PFavoriteHead => "favorite-head"
    PFavoriteHint => "favorite-hint"
    PFavorite(f, _, _) => "favorite/" + f.station + "\u{1}" + favorite_path(f.root, f.path)
    PHeading => "heading"
    PStation(s, _) => "station/" + s.station
  }
}

///|
/// The places' lines of workspace `ws`, as they are now: the person's folders kept at hand, then every station with a
/// drive (this machine's first, then as the workspace lists them), their bones while they are read.
fn files_place_lines(src : Source, ws : String) -> Array[PlaceLine] {
  let (known, error) = drive_stations(src, ws)
  let stations = known.unwrap_or([])
  let favs = favorites_in(src, ws, stations)
  let visible : Array[(Favorite, DvStation)] = []
  for f in favs {
    match stations.iter().find_first(fn(s) { s.station == f.station }) {
      Some(s) => visible.push((f, s))
      None => ()
    }
  }
  let rows : Array[PlaceLine] = []
  match (known, error) {
    (None, Some(e)) => rows.push(PTrouble(e))
    _ => ()
  }
  if known is Some(_) && stations.length() == 0 {
    rows.push(PNone)
  }
  rows.push(PFavoriteHead)
  if favs.is_empty() {
    rows.push(PFavoriteHint)
  }
  for i, (f, s) in visible {
    rows.push(PFavorite(f, s, i + 1 < visible.length()))
  }
  // (while they are read, the stations to come in their bones where they will be)
  if known is None && error is None {
    rows.push(PReading)
  }
  if stations.length() > 0 {
    rows.push(PHeading)
  }
  for i, s in stations {
    rows.push(PStation(s, i + 1 < stations.length()))
  }
  rows
}

///|
/// Whether the folder is the one shown (the side in front: the stack's top), its row lit.
fn place_lit(station : String, root : String, path : String) -> Bool {
  match app.nav.top() {
    Drive(h) =>
      if h.station != station {
        false
      } else {
        match h.root {
          Some(r) => favorite_same_path(r, h.path, root, path)
          None => false
        }
      }
    _ => false
  }
}

///|
/// The files' places of workspace `ws` (FilesNav's list; the phone's 文件 the same list), in node `parent` (filling it),
/// scrolling: the person's folders kept at hand, then every station with a drive. Its rows a sidebar list's where it
/// stands (`at`: the theme's; touch's a finger's list's, a size up). `top`, `foot`: room kept at its ends for what is
/// over it; `go`: a folder opened.
pub fn files_places_node(
  parent : @view.View,
  src : Source,
  ws : String,
  at : @sf.ListAt,
  top~ : () -> Double,
  foot~ : () -> Double,
  go~ : (DriveAt) -> Unit,
  tips? : @sf.TipLayer,
) -> Unit {
  let here = this_machine()
  parent.box(fn(l) {
    l.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    let keyed = l.keyed_by(fn() { files_place_lines(src, ws) }, place_line_key)
    l.scrolls_window(
      @view.Scroll::list(),
      fn() { keyed.keys() },
      est=place_est,
      slop=@ui.touch_slop(),
      bar=@ui.tree_scroll_bar(),
      top_covered=top,
      bar_clear=fn() { (top(), foot()) },
      head=fn(h) { h.height(By(fn() { Some(top()) })) |> ignore },
      foot=fn(f) { f.height(By(fn() { Some(foot() + @sf.list_foot_in(at)) })) |> ignore },
      fn(b, k) {
        guard @signals.untracked(fn() { keyed.get(k) }) is Some(first) else { return }
        let now = fn() { keyed.get(k).unwrap_or(first) }
        b.box(fn(line) {
          @sf.style_node(line, fn() { @sf.list_line(at) })
          match first {
            PTrouble(_) =>
              line.box(fn(n) {
                @sf.style_node(n, fn() { nav_note })
                drive_err_lines_node(n, fn() { "" }, fn() {
                  match now() {
                    PTrouble(e) => e
                    _ => ""
                  }
                })
              })
              |> ignore
            PReading => @sf.waiting_node(line, fn(w) { places_sample_node(w, at) })
            PNone =>
              line.box(fn(n) {
                @sf.style_node(n, fn() { nav_note })
                @sf.words_node(n, fn() { @sf.t("web-main.rail.filesNone") }, fn() { @sf.nav_meta() }) |> ignore
              })
              |> ignore
            PFavoriteHead =>
              favorite_drop_node(line, src, ws, "head", fn(h) {
                @sf.list_heading_node(h, fn() { @sf.t("web-pages.files.favorites") }, at)
              })
            PFavoriteHint =>
              favorite_drop_node(line, src, ws, "hint", fn(h) {
                h.box(fn(x) {
                  @sf.style_node(x, fn() { @sf.side_hint_at(at) })
                  @sf.icon_node(x, "star", nav_icon, By(fn() { @sf.theme().p.subtle })) |> ignore
                  @sf.words_node(x, fn() { @sf.t("web-pages.files.favoritesHint") }, fn() { @sf.nav_meta() }) |> ignore
                })
                |> ignore
              })
            PFavorite(f, st, _) =>
              favorite_row_node(line, src, ws, at, f, fn() {
                match now() {
                  PFavorite(_, s, _) => s
                  _ => st
                }
              }, fn() {
                match now() {
                  PFavorite(_, _, more) => more
                  _ => false
                }
              }, go, tips?)
            PHeading => @sf.list_heading_node(line, fn() { "Station" }, at)
            PStation(s, _) =>
              station_row_node(line, src, ws, at, fn() {
                match now() {
                  PStation(s, _) => s
                  _ => s
                }
              }, fn() {
                match now() {
                  PStation(_, more) => more
                  _ => false
                }
              }, s.station == here, go)
          }
        })
        |> ignore
      },
    )
    |> ignore
  })
  |> ignore
}

///|
/// A sidebar's row of one line in `parent` (nav_row's): its ground as the web moves it (the pointer's, the selected
/// one's while `on`), pressed `press`, read out a link named `label`; `more`: another row under it (nav_apart's room
/// between them). What it holds `body` makes. The row's node.
fn side_row_node(
  parent : @view.View,
  at : @sf.ListAt,
  on : () -> Bool,
  label : () -> String,
  press : () -> Unit,
  more : () -> Bool,
  body : (@view.View) -> Unit,
  menu? : (Double, Double, Bool) -> Unit,
) -> @view.View {
  let mut made : @view.View? = None
  parent.box(fn(apart) {
    @sf.style_node(apart, fn() { if more() { @sf.list_more(Side) } else { nav_flat } })
    apart.box(fn(r) {
      @sf.style_node(r, fn() { @sf.side_row_at(at).then(@sf.row_least_h()) })
      @sf.nav_ground_node(r, on)
      match menu {
        // (pressed, and its menu asked as the hand does: a right click, a finger's hold)
        Some(m) => @sf.menu_presses_node(r, press, m)
        None => @sf.presses_node(r, press)
      }
      r.says(By(fn() { Some(@view.said(Link, label=label(), selected=on())) })) |> ignore
      body(r)
      made = Some(r)
    })
    |> ignore
  })
  |> ignore
  made.unwrap()
}

///|
/// A part of 个人收藏 in `parent` takes a folder dragged onto it (`key`); a favorite's own drop target takes precedence.
fn favorite_drop_node(parent : @view.View, src : Source, ws : String, key : String, body : (@view.View) -> Unit) -> Unit {
  parent.box(fn(k) {
    let keeping = drop_target_node(k, src, "keep/" + key, None, "", fn() { true }, fn() { true }, 0, outside=false, ws~)
    @sf.style_node(k, fn() { if keeping() is Some(_) { keep_on } else { keep_off } })
    body(k)
  })
  |> ignore
}

///|
/// A folder of the places in `parent` that takes a drop (`into`, named `name`): its row, ringed while what it takes is
/// over it, saying what a drop does; its corner the row's.
fn side_drop_node(
  parent : @view.View,
  src : Source,
  key : String,
  into : DriveAt,
  name : String,
  write : () -> Bool,
  transfers : () -> Bool,
  row : (@view.View) -> Unit,
) -> Unit {
  parent.box(fn(d) {
    let lit = drop_target_node(d, src, "side/" + key, Some(into), name, write, transfers, 1, outside=false)
    @sf.style_node(d, fn() {
      let drop = @sf.theme().chat_list.side_drop
      if lit() is Some(_) { drop.then(fdrag_side_on) } else { drop }
    })
    row(d)
    d.show(fn() { lit() is Some(_) }, at_once=true, fn(o) {
      o.over(Is(true)).presses(Is(false)) |> ignore
      @sf.style_node(o, fn() { fdrag_says_place })
      o.box(fn(says) {
        @sf.style_node(says, fn() { fdrag_says })
        @sf.words_node(says, fn() { @sf.t(if lit() == Some("copy") { "web-pages.files.copyHereShort" } else { "web-pages.files.moveHereShort" }) }, fn() {
          fdrag_says_words
        })
        |> ignore
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// One favorite in `parent`: its row opens the folder; a hold or right click offers to remove it. A pointer also gets a
/// remove key at its end while it is pointed at.
fn favorite_row_node(
  parent : @view.View,
  src : Source,
  ws : String,
  at : @sf.ListAt,
  f : Favorite,
  st : () -> DvStation,
  more : () -> Bool,
  go : (DriveAt) -> Unit,
  tips? : @sf.TipLayer,
) -> Unit {
  let place = f.station + "/" + f.root + "/" + f.path
  let label = @sf.t("web-pages.files.unfavorite", args=[("name", f.name)])
  // Preserve the root used by older station integrations that can only read configured roots.
  let into = fn() -> DriveAt {
    match st().roots.iter().find_first(fn(r) { favorite_same_path(f.root, f.path, r.path, "") }) {
      Some(r) => { station: f.station, root: Some(r.path), path: "" }
      None => { station: f.station, root: Some(f.root), path: f.path }
    }
  }
  let remove = fn() { favorite_remove(src, ws, f.station, f.root, f.path) }
  favorite_drop_node(parent, src, ws, "favorite/" + place, fn(k) {
    side_drop_node(k, src, "fav/" + place, @signals.untracked(into), f.name, fn() { dv_rights(src, ws, Some(st())).write }, fn() {
      st().transfers
    }, fn(d) {
      side_row_node(
        d,
        at,
        fn() {
          let i = into()
          place_lit(f.station, i.root.unwrap_or(""), i.path)
        },
        fn() { f.name },
        fn() { go(@signals.untracked(into)) },
        more,
        fn(r) {
          @sf.icon_node(r, "folder", nav_icon, By(fn() { @sf.theme().p.muted })) |> ignore
          r.box(fn(w) {
            w.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            @sf.nav_words_node(w, fn() { f.name }, faint=fn() { !st().online })
          })
          |> ignore
          @sf.words_node(r, fn() { st().name }, fn() { @sf.nav_meta().then(meta_cut) }) |> ignore
          // (its ✕ takes it out, a press elsewhere on it goes there: there with a pointer while it is pointed at, as small
          // as a row's key, its row as high as ever)
          r.show(fn() { !@sf.more_held() && @sf.lit_within_node(r) }, at_once=true, fn(key) {
            @sf.style_node(key, fn() { favorite_remove_key(at) }, in_row=true)
            @sf.icon_button_node(key, "close", fn() { label }, remove, tips?, size=favorite_key_side, icon_size=nav_icon, ink=fn() {
              @sf.theme().p.subtle
            })
            |> ignore
          })
        },
        // (held by a finger or right clicked: its menu, of what it is: beside the row a finger held, where the pointer
        // was pressed)
        menu=fn(x, y, _held) {
          @sf.menu([Some(@sf.menu_item_of(label, icon="star", remove))], from=@sf.at_point(x, y), title=f.name)
        },
      )
      |> ignore
    })
  })
}

///|
/// A station's row (StationRow) in `parent`: its disclosure, then its home (or the folder it pins, for a read-only
/// member), this machine said, how full its disk is or that it is away; its places under it while opened.
fn station_row_node(
  parent : @view.View,
  src : Source,
  ws : String,
  at : @sf.ListAt,
  s : () -> DvStation,
  more : () -> Bool,
  here : Bool,
  go : (DriveAt) -> Unit,
) -> Unit {
  let station = @signals.untracked(s).station
  let open = fn() { places_open.contains(station) }
  let start = fn() { drive_start(s()) }
  let write = fn() { dv_rights(src, ws, Some(s())).write }
  let transfers = fn() { s().transfers }
  let places = fn() -> Array[(String, String, Bool)]? {
    let st = s()
    if st.anywhere {
      if open() { station_places_read(src, st) } else { None }
    } else {
      Some(st.roots.map(fn(r) { (r.name, r.path, false) }))
    }
  }
  let row = fn(d : @view.View) {
    side_row_node(
      d,
      at,
      fn() {
        match start() {
          Some(r) => place_lit(station, r, "")
          None => false
        }
      },
      fn() { s().name },
      fn() {
        match @signals.untracked(start) {
          Some(r) => go({ station, root: Some(r), path: "" })
          None => ()
        }
      },
      fn() { open() && places().unwrap_or([]).length() > 0 },
      fn(r) {
        // its disclosure, as wide as makes it a press's room inside its row, the chevron in its middle
        @sf.action_box_node(r, fn() { @sf.t(if open() { "web-pages.files.collapse" } else { "web-pages.files.expand" }, args=[("name", s().name)]) }, expanded=open, fn(_) {
          if places_open.contains(station) {
            places_open.remove(station)
          } else {
            places_open.put(station, true)
          }
        }, fn(dis) {
          @sf.style_node(dis, fn() { disclosure_at(at) }, in_row=true)
          @sf.icon_node(dis, "", nav_icon, By(fn() { @sf.theme().p.subtle }), name_now=fn() { if open() { "chevron-down" } else { "chevron-right" } })
          |> ignore
        })
        |> ignore
        station_mark_of_node(r, s, Row)
        r.box(fn(w) {
          w.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.nav_words_node(w, fn() { s().name }, faint=fn() { !s().online })
        })
        |> ignore
        if here {
          r.box(fn(chip) {
            @sf.style_node(chip, fn() { here_chip }, in_row=true)
            @sf.words_node(chip, fn() { @sf.t("web-pages.files.thisMachine") }, fn() { here_words }) |> ignore
          })
          |> ignore
        }
        r.pick(fn() { s().online }, at_once=true, fn(x, online) {
          if online {
            disk_bar_node(x, s)
          } else {
            @sf.words_node(x, fn() { @sf.t("web-pages.stations.offline") }, fn() { @sf.nav_meta() }) |> ignore
          }
        })
      },
    )
    |> ignore
  }
  parent.box(fn(item) {
    // (another station under it: the room between two things that light up, nav_apart's)
    @sf.style_node(item, fn() { if more() { @sf.list_more(Side) } else { station_item } })
    item.pick(fn() { start() }, at_once=true, fn(x, st) {
      match st {
        Some(r) => side_drop_node(x, src, "station/" + station, { station, root: Some(r), path: "" }, @signals.untracked(s).name, write, transfers, row)
        None => row(x)
      }
    })
    // its places, under it while opened (asked once, as its row opens: station_places_read)
    item.show(open, fn(under) {
      under.pick(fn() { places() is None && s().anywhere }, at_once=true, fn(p, reading) {
        if reading {
          p.box(fn(n) {
            @sf.style_node(n, fn() { nav_note })
            @sf.words_node(n, fn() { @sf.t("web-pages.files.reading") }, fn() { @sf.nav_meta() }) |> ignore
          })
          |> ignore
          return
        }
        p.box(fn(list) {
          @sf.style_node(list, fn() { places_in })
          list.each(fn() { places().unwrap_or([]) }, fn(x) { x.1 }, fn(pr, x) {
            let (name, path, disk) = x.untracked()
            let into : DriveAt = { station, root: Some(path), path: "" }
            side_drop_node(pr, src, "place/" + station + "/" + path, into, name, write, transfers, fn(d) {
              side_row_node(
                d,
                at,
                fn() { place_lit(station, path, "") },
                fn() { name },
                fn() { go(into) },
                fn() {
                  let all = places().unwrap_or([])
                  match all.last() {
                    Some(l) => l.1 != path
                    None => false
                  }
                },
                fn(r) {
                  @sf.icon_node(r, if disk { "disk" } else { "folder" }, nav_icon, By(fn() { @sf.theme().p.muted })) |> ignore
                  r.box(fn(w) {
                    w.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                    @sf.nav_words_node(w, fn() { name }, faint=fn() { !s().online })
                  })
                  |> ignore
                },
              )
              |> ignore
            })
          })
        })
        |> ignore
      })
    })
  })
  |> ignore
}

///|
/// The stations to come while they are read (the library's Waiting, in its bones), in `parent`: their heading and two
/// made-up stations' rows, as station_row_node draws them.
fn places_sample_node(parent : @view.View, at : @sf.ListAt) -> Unit {
  @sf.list_heading_node(parent, fn() { "Station" }, at)
  for i, n in [5, 3] {
    let s = @sfbase.dv_station({
      "station": Json::string("sample/" + i.to_string()),
      "name": Json::string(@sf.sample_words(n)),
      "online": true,
      "overview": { "disk": { "totalBytes": 2.0, "freeBytes": 1.0 } },
    })
    station_row_node(parent, @sfbase.sample_source, "", at, fn() { s }, fn() { i == 0 }, false, fn(_) {  })
  }
}

///|
/// How full a station's disk is (DiskBar), in `parent`: a short bar, amber past 90%; what it says what is left, in GB,
/// and how much is used.
fn disk_bar_node(parent : @view.View, s : () -> DvStation) -> Unit {
  let used = fn() {
    let st = s()
    if st.disk_total <= 0.0 { 0.0 } else { 1.0 - st.disk_free / st.disk_total }
  }
  let said = fn() {
    let st = s()
    let gb = st.disk_free / 1.0e9
    let left = if st.disk_free >= 1.0e11 { gb.round().to_int().to_string() } else { @sf.to_fixed(gb, 1) }
    @sf.t("web-pages.files.diskLeft", args=[("free", left + " GB"), ("percent", (used() * 100.0).round().to_int().to_string())])
  }
  parent.box(fn(track) {
    @sf.style_node(track, fn() { disk_track }, in_row=true)
    track.laid_nowhere(By(fn() { s().disk_total <= 0.0 })).says(By(fn() { Some(@view.said(Image, label=said())) })) |> ignore
    track.box(fn(part) {
      @sf.style_node(part, fn() { if used() >= disk_full { disk_warn } else { disk_used } })
      part.width(By(fn() { Some(disk_w * used()) })) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A row's mark (16), the disk's bar (28 by 3), past what it is amber (90%).
let nav_icon : Double = 16.0

///|
let disk_w : Double = 28.0

///|
let disk_full : Double = 0.9

///|
/// A row of the list as a guess at its height, before it is laid out.
let place_est : Double = 36.0

///|
/// A row with no row under it: as it is.
// kept across runs: a value (no field of it changes)
let nav_flat : @ui.Style = @ui.css("w=Full")

///|
/// A station's row and its places under it, one item of the list.
// kept across runs: a value (no field of it changes)
let station_item : @ui.Style = @ui.css("w=Full")

///|
/// The list's words in place of rows (empty, reading, trouble), 8 by 10 in.
// kept across runs: a value (no field of it changes)
let nav_note : @ui.Style = @ui.css("w=Full px=S2_5 py=S2")

///|
/// 个人收藏 (keep): ringed while a folder dragged over it would be kept there.
// kept across runs: a value (no field of it changes)
let keep_off : @ui.Style = @ui.css("w=Full radius=Xl")

///|
// kept across runs: a value (no field of it changes)
let keep_on : @ui.Style = keep_off.then(@ui.css("border=B1 border_color=Accent"))

///|
/// A station's name beside its row's words, cut short where the row has not the room.
// kept across runs: a value (no field of it changes)
let meta_cut : @ui.TextStyle = @ui.text_style(w=Cut)

///|
/// A row key concentric with the side row's rounded end, without increasing the row's height.
fn favorite_remove_key(at : @sf.ListAt) -> @ui.Style {
  let corner = @sf.row_least() / 2.0
  let inset = @ui.capsule_in(corner, @sf.row_keys_room(1), room=corner)
  favorite_key_look.then(@ui.style(mr=@sf.room_of(inset - @sf.band_pad_in(at))))
}

///|
// kept across runs: a value (no field of it changes)
let favorite_key_look : @ui.Style = @ui.css("row align=ACenter justify=JCenter")

///|
/// The remove key's side (row_key_box's: 24).
let favorite_key_side : Double = 24.0

///|
/// A station's disclosure: its chevron 16 across, its box as wide as makes it a press's room inside its row (whose sides
/// are the band's pad in: 20 with touch), the chevron in its middle.
fn disclosure_at(at : @sf.ListAt) -> @ui.Style {
  let w = dmax(disclosure_side, @ui.room_least() - 2.0 * @sf.band_pad_in(at))
  disclosure_look.then(@ui.style(w=Fixed(w)))
}

///|
let disclosure_side : Double = 16.0

///|
// kept across runs: a value (no field of it changes)
let disclosure_look : @ui.Style = @ui.css("h=S4 align=ACenter justify=JCenter")

///|
/// This machine (here): a pill on the accent's ground, its words small.
// kept across runs: a value (no field of it changes)
let here_chip : @ui.Style = @ui.css("px=S1_25 radius=Full bg=AccentBg")

///|
// kept across runs: a value (no field of it changes)
let here_words : @ui.TextStyle = @ui.text_style(size=Caption, color=AccentText, wrap=false)

///|
/// A station's places, in under it (places: 14; and a row's own 6).
// kept across runs: a value (no field of it changes)
let places_in : @ui.Style = @ui.css("w=Full pl=S5")

///|
// kept across runs: a value (no field of it changes)
let disk_track : @ui.Style = @ui.style(w=Fixed(disk_w), h=Fixed(disk_h), radius=Sm, bg=Line, clip=true)

///|
let disk_h : Double = 3.0

///|
// kept across runs: a value (no field of it changes)
let disk_used : @ui.Style = @ui.css("h=Full bg=Muted")

///|
// kept across runs: a value (no field of it changes)
let disk_warn : @ui.Style = @ui.css("h=Full bg=Warn")

///|
/// What a drop over it would land in: ringed in the accent on its wash.
// kept across runs: a value (no field of it changes)
let fdrag_side_on : @ui.Style = @ui.css("bg=AccentBg border=B1 border_color=Accent")

///|
// kept across runs: a value (no field of it changes)
let fdrag_says_place : @ui.Style = @ui.css("row w=Full h=Full pr=S2 align=ACenter justify=JEnd")

///|
/// What a drop there does (dropSays: a capsule in the accent, 7 in, its words 11 bold on it).
// kept across runs: a value (no field of it changes)
let fdrag_says : @ui.Style = @ui.css("px=S1_5 py=SPx radius=Full bg=Accent")

///|
// kept across runs: a value (no field of it changes)
let fdrag_says_words : @ui.TextStyle = @ui.text_style(size=Caption, weight=Semibold, color=OnPrimary, wrap=false)
