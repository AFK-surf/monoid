// 下方栏, one page for every frame (web/src/mobile/BarSettings.tsx BarSettingsScreen; the web's desktop has no bottom
// bar, so no page of it): this device's bottom bars, each a section of its own (its name, 当前 on the one in view,
// 使用 and 删除 at its end) over a card of its places; a new one made under them. What the core keeps (`bars`) and the
// page's state are the settings' (save_bars, bar_adding: let go of as the page is left; a place held, its card's).
// The bar is Small's alone, and an iPhone Duo's (the system's tab bar: one bar, none made or switched to), so the
// settings' row of it is too (settings_list.mbt); the page is laid out at any width all the same (one open as the
// screen grows wider stays). Made once as nodes of the window's tree.

///|
/// The page (BarSettingsScreen) made once as nodes in node `v`, in the frame it is given, laid out by the `width` its
/// frame gives it: what the bars are for under its title, what they are of over it (此设备); each bar a section of its
/// own; 新建一栏; what is kept of them, under all. Each as the core keeps the bars now (`bars`), a bar made while one is
/// being added (bar_adding) under them.
pub fn bars_node(
  v : @view.View,
  core : Core,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let made = fn() { (core.bars)().0 }
  let cur = fn() { (core.bars)().1 }
  // (the made ones, and the one being made under them, kept with its first place once it has one)
  let sets = fn() -> Array[Array[String]] {
    let all = made().copy()
    if @settings.bar_adding.get() {
      all.push([])
    }
    all
  }
  // a place picked for bar `i` (one past the made ones: the one just made, kept with its first place)
  let pick_for = fn(i : Int, from : @sf.Beside) {
    let (now, _) = (core.bars)()
    let set = now.get(i).unwrap_or([])
    let left = @settings.all_places.filter(fn(p) { !set.contains(p) })
    let choices = left.map(fn(p) { @sf.choice(p, bar_place_name(p), icon=@sfbase.place_icon(p)) })
    // (an iPhone Duo's one bar: no bar to name)
    let title = if @sf.native_on() {
      ""
    } else {
      @sf.t("android-misc.bar.pick.title", args=[("n", (i + 1).to_string())])
    }
    @sf.pick(title, choices, "", fn(place) {
      let (now, ncur) = (core.bars)()
      if i >= now.length() {
        @settings.bar_adding.set(false)
        @settings.save_bars(core, now + [[place]], ncur)
      } else {
        @settings.save_bars(core, now.mapi(fn(n, s) { if n == i && !s.contains(place) && s.length() < @settings.bar_size { s + [place] } else { s } }), ncur)
      }
    }, from~)
  }
  let blocks = fn() {
    // (an iPhone Duo's is the system's tab bar, one, never swiped between: the one in view alone, no other made,
    // nothing said of switching)
    if @sf.native_on() {
      return ["bar/" + cur().to_string()]
    }
    let out = sets().mapi(fn(i, _) { "bar/" + i.to_string() })
    out.push("new")
    out.push("foot")
    out
  }
  @sf.page_node(
    v,
    fn() { @sf.t("android-misc.bar.title") },
    on_back~,
    frame~,
    said?,
    width?,
    // (an iPhone Duo's one bar: nothing said of others or of switching)
    lead=fn() { @sf.t(if @sf.native_on() { "android-misc.bar.noteOne" } else { "android-misc.bar.note" }) },
    small=fn() { @sf.t("android-misc.bar.small") },
    blocks,
    fn(b, key) {
      match key {
        "new" =>
          @sf.group_node(b, fn(g) {
            @sf.link_row_node(
              g,
              fn() { @sf.t("android-misc.bar.new") },
              fn() {
                @settings.bar_adding.set(true)
                pick_for(made().length(), Node(g))
              },
              chevron=false,
              lead=LeadLine(fn(l) { @sf.icon_node(l, "plus", bar_new_mark, By(@sf.link_ink)) |> ignore }),
            )
          })
        "foot" =>
          @sf.page_note_node(b, fn() {
            @sf.t(if made().length() > 1 { "android-misc.bar.foot.many" } else { "android-misc.bar.foot.one" })
          })
        _ => {
          let i = @string.parse_int(key.unsafe_substring(start=4, end=key.length())) catch { _ => 0 }
          let set = fn() { sets().get(i).unwrap_or([]) }
          let is_made = fn() { i < made().length() }
          let card = fn(sec : @view.View) {
            @sf.group_node(sec, fn(g) {
              bar_card_node(g, core, i, set, fn() { (@sf.native_on() || made().length() == 1) && set().length() == 1 }, fn(from) {
                pick_for(i, from)
              })
            })
          }
          // (an iPhone Duo's one bar: its card alone, no name nor 当前 over it)
          if @sf.native_on() {
            card(b)
          } else {
            @sf.section_node(
              b,
              fn() { @sf.t("android-misc.bar.set", args=[("n", (i + 1).to_string())]) },
              ends=fn(e) {
                // the one in view says so where the others offer to be it
                e.show(fn() { is_made() && i == cur() }, fn(p) {
                  @sf.pill_node(p, fn() { @sf.t("android-misc.bar.current") }, tone=Accented) |> ignore
                })
                e.show(fn() { is_made() && i != cur() }, fn(a) {
                  @sf.action_node(a, fn() { @sf.t("android-misc.bar.use") }, fn() { @settings.save_bars(core, made(), i) })
                })
                e.show(fn() { sets().length() > 1 }, fn(a) {
                  @sf.action_node(a, fn() { @sf.t("android-misc.bar.delete") }, bad=true, fn() {
                    let made = made()
                    let cur = cur()
                    if i >= made.length() {
                      @settings.bar_adding.set(false)
                    } else {
                      let left : Array[Array[String]] = []
                      for k, x in made {
                        if k != i {
                          left.push(x)
                        }
                      }
                      @settings.save_bars(core, left, if cur > i || cur >= left.length() { if cur - 1 < 0 { 0 } else { cur - 1 } } else { cur })
                    }
                  })
                })
              },
              card,
            )
          }
        }
      }
    },
  )
}

///|
/// A place's name (the bar's words for it).
fn bar_place_name(place : String) -> String {
  @sf.t("android-misc.bar.place." + place)
}

///|
/// A row held by the finger (bar_card_node's): its place, where its row stands in the card (from its top, as it
/// went down), how far it has gone since, how wide and high its row is.
#derive(Eq)
priv struct BarHeld {
  key : String
  y : Double
  dy : Double
  w : Double
  h : Double
}

///|
/// A bar's places (BarCard) as nodes in `g`, its group's list card: up to four rows, each its mark before its name
/// with a "−" at its end (none on the last place of the only bar: `only`), one held and moved up or down put where
/// it is let go (by how many rows it went), a screen reader's step moving it one along; with room left, a row at its
/// foot that adds one (`add`, from where it is). Bar `i`'s places as `set` says them now. Held, the row drawn where
/// the finger has it, raised over the other places (BarSettings.kt's graphicsLayer, zIndex(2f)): drawn so over the
/// card, its row left where it was meanwhile.
fn bar_card_node(
  g : @view.View,
  core : Core,
  i : Int,
  set : () -> Array[String],
  only : () -> Bool,
  add : (@sf.Beside) -> Unit,
) -> Unit {
  // BarSettingsScreen's onMove: the place at `j` put at `to`
  let put_at = fn(j : Int, to : Int) {
    let (now, ncur) = (core.bars)()
    if to != j && i < now.length() && j < now[i].length() && to >= 0 && to < now[i].length() {
      let moved = now[i].copy()
      let p = moved.remove(j)
      moved.insert(to, p)
      @settings.save_bars(core, now.mapi(fn(n, s) { if n == i { moved } else { s } }), ncur)
    }
  }
  let held : @signals.Signal[BarHeld?] = @signals.signal(None)
  let held_key = fn() { held.get().map(fn(h) { h.key }) }
  @sf.list_rows_node(g, fn(r) {
    r.each(set, fn(k) { k }, fn(slot, key) {
      let key = key.untracked()
      let at = fn() { @signals.untracked(set).search(key).unwrap_or(0) }
      @sf.style_node(slot, fn() { bar_row })
      slot.radius(Is(bar_slot_corner)) |> ignore
      // (held: drawn over the card where the finger has it, the row's place kept)
      slot.alpha(By(fn() { if held_key() == Some(key) { 0.0 } else { 1.0 } })) |> ignore
      @sf.list_row_face_node(
        slot,
        fn(m) { bar_place_mark_node(m, key) },
        fn() { bar_place_name(key) },
        make=fn(face) {
          face.says(Is(Some(@view.said(Group, label=bar_place_name(key), actions=[Decrement, Increment])))) |> ignore
          // a screen reader's (右移): one row along
          face.on_step(fn(by) {
            let j = at()
            let n = @signals.untracked(set).length()
            if j + by >= 0 && j + by < n {
              put_at(j, j + by)
            }
          })
          |> ignore
          // the finger's: lifted once it goes past the slop, following it up or down; let go, put by how many rows it
          // went (a row's height)
          let from = Ref(0.0)
          face.gesture(@ui.touch_slop(), drag=fn(d) {
            match d.kind {
              Down => {
                let gone = d.y - d.oy
                from.val = d.wy - gone
                let (_, fy, _, fh) = slot.placed_window_now()
                let (_, ry, rw, _) = r.placed_window_now()
                held.set(Some({ key, y: fy - ry, dy: gone, w: rw, h: if fh > 0.0 { fh } else { d.h } }))
              }
              Moved =>
                match held.get() {
                  Some(h) => held.set(Some(BarHeld::{ ..h, dy: d.wy - from.val }))
                  None => ()
                }
              Up => {
                match held.get() {
                  Some(h) if h.h > 0.0 => {
                    let j = at()
                    let n = @signals.untracked(set).length()
                    let to = j + ((d.wy - from.val) / h.h).round().to_int()
                    held.set(None)
                    put_at(j, if to < 0 { 0 } else if to >= n { n - 1 } else { to })
                  }
                  _ => held.set(None)
                }
              }
              Off => held.set(None)
            }
          })
          |> ignore
        },
      )
      // its "−" beside (not inside) what the finger holds: a press on the "−" is its own
      slot.show(fn() { !only() }, fn(k) {
        bar_remove_node(k, key, fn() {
          let (now, ncur) = (core.bars)()
          @settings.save_bars(core, now.mapi(fn(n, s) { if n == i { s.filter(fn(p) { p != key }) } else { s } }), ncur)
        })
      })
    })
    // with room left, a row at its foot that adds one, from where it is
    r.show(fn() { set().length() < @settings.bar_size }, fn(a) {
      @sf.link_row_opens_node(
        a,
        fn() { @sf.t("android-misc.bar.add") },
        fn(row) { add(Node(row)) },
        chevron=false,
        acts=true,
        lead=LeadLine(fn(l) { @sf.icon_node(l, "plus", bar_mark, By(@sf.link_ink)) |> ignore }),
      )
    })
    // the one held, where the finger has it, over the rest
    r.show(fn() { held.get() is Some(_) }, fn(o) {
      o.over(Is(true)) |> ignore
      o.pick(fn() { held_key().unwrap_or("") }, fn(slot, key) {
        @sf.style_node(slot, fn() { bar_row_held })
        let raised = @sf.held_raised
        slot.radius(Is(bar_slot_corner)).shadow(Is((raised.sigma, raised.dy, raised.color))) |> ignore
        slot
        .width(By(fn() { held.get().map(fn(h) { Some(h.w) }).unwrap_or(None) }))
        .offset(By(fn() { held.get().map(fn(h) { (0.0, h.y + h.dy) }).unwrap_or((0.0, 0.0)) }))
        |> ignore
        @sf.list_row_face_node(slot, fn(m) { bar_place_mark_node(m, key) }, fn() { bar_place_name(key) })
        slot.show(fn() { !only() }, fn(k) { bar_remove_look_node(k) })
      })
    })
  })
}

///|
/// A place's mark in the row's muted ink (20): the stations', their glyph with one station on, as no station is
/// meant; the others' their icon (@sfbase.place_icon).
fn bar_place_mark_node(m : @view.View, place : String) -> Unit {
  let ink = fn() { @sf.theme().p.muted }
  if place == "stations" {
    let still : @sf.GlyphCounts = { online: 1, dim: 0, failing: 0, working: 0, asleep: false, connecting: 0 }
    @sf.station_glyph_node(m, fn() { still }, bar_mark, ink, fn() { @sf.theme().p.red }) |> ignore
  } else {
    @sf.icon_node(m, @sfbase.place_icon(place), bar_mark, By(ink)) |> ignore
  }
}

///|
/// A place's mark's side.
let bar_mark : Double = 20.0

///|
/// The "−" that takes place `key` out of its bar, in `m`, `press` as it is pressed.
fn bar_remove_node(m : @view.View, key : String, press : () -> Unit) -> Unit {
  @sf.action_box_node(m, fn() { @sf.t("android-misc.bar.remove", args=[("name", bar_place_name(key))]) }, fn(_) { press() }, fn(minus) {
    @sf.style_node(minus, fn() { bar_remove })
    @sf.icon_node(minus, "minus", bar_remove_mark, By(fn() { @sf.theme().p.muted })) |> ignore
  })
  |> ignore
}

///|
/// The "−"'s look alone (bar_remove_node's), in `m`: on the row held, drawn where the finger has it.
fn bar_remove_look_node(m : @view.View) -> Unit {
  m.box(fn(minus) {
    @sf.style_node(minus, fn() { bar_remove })
    @sf.icon_node(minus, "minus", bar_remove_mark, By(fn() { @sf.theme().p.muted })) |> ignore
  })
  |> ignore
}

// ── styles ─────────────────────────────────────────────

///|
/// A place's row on its bar's list card: its "−" at its end kept out of the card's corner (18: `card_control_end`).
// kept across runs: a value (no field of it changes)
let bar_row : @ui.Style = @ui.css("row w=Full pr=S4_5 align=ACenter")

///|
/// A row's corner: concentric with its card's at the room the card leaves round its rows.
let bar_slot_corner : Double = @ui.concentric(@sf.group_corner, @sf.list_pad)

///|
/// A row held: on the card's ground, raised (shadow(6), black at 14% both: @sf.held_raised), round as a row is; as
/// wide as its row (bar_card_node's).
// kept across runs: a value (no field of it changes)
let bar_row_held : @ui.Style = bar_row.then(@ui.css("bg=Card"))

///|
/// The "−" that takes a place out: 20 round, on the neutral wash.
// kept across runs: a value (no field of it changes)
let bar_remove : @ui.Style = @ui.css("w=S5 h=S5 radius=Full bg=Neutral align=ACenter justify=JCenter")

///|
let bar_remove_mark : Double = 12.0

///|
/// 新建一栏's mark.
let bar_new_mark : Double = 20.0
