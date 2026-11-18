// 下方栏, one page for every frame (web/src/mobile/BarSettings.tsx BarSettingsScreen; the web's desktop has no bottom
// bar, so no page of it): this device's bottom bars, each a section of its own (its name, 当前 on the one in view,
// 使用 and 删除 at its end) over a card of its places; a new one made under them. What the core keeps (`bars`) and the
// page's state are the settings' (save_bars, bar_adding: let go of as the page is left; a place held, its card's).
// The bar is Small's alone, so the settings' row of it is too (settings_list.mbt); the page is laid out at any width
// all the same (one open as the screen grows wider stays). Made once as nodes of the window's tree.

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
    @sf.pick(@sf.t("android-misc.bar.pick.title", args=[("n", (i + 1).to_string())]), choices, "", fn(place) {
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
    lead=fn() { @sf.t("android-misc.bar.note") },
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
            fn(sec) {
              @sf.group_node(sec, card=true, fn(g) {
                bar_card_node(g, core, i, set, fn() { made().length() == 1 && set().length() == 1 }, fn(from) { pick_for(i, from) })
              })
            },
          )
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
/// A slot held by the finger (bar_card_node's): its place, where its slot stands in the row (from its start, as it
/// went down), how far it has gone since, how wide its slot is.
#derive(Eq)
priv struct BarHeld {
  key : String
  x : Double
  dx : Double
  w : Double
}

///|
/// A bar's places (BarCard) as nodes in `g`, its group's card: four slots, each its mark over its name with a "−" at
/// its corner (none on the last place of the only bar: `only`), one held and moved sideways put where it is let go (by
/// how many slots it went), a screen reader's step moving it one along; with room left, a slot that adds one (`add`,
/// from where it is). Bar `i`'s places as `set` says them now. Held, the slot drawn where the finger has it, 8% larger,
/// raised over the other places (BarSettings.kt's graphicsLayer, zIndex(2f)): drawn so over the row, its slot left
/// where it was meanwhile.
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
  g.box(fn(r) {
    @sf.style_node(r, fn() { bar_slots })
    r.each(set, fn(k) { k }, fn(slot, key) {
      let key = key.untracked()
      let at = fn() { @signals.untracked(set).search(key).unwrap_or(0) }
      @sf.style_node(slot, fn() { bar_slot }, in_row=true)
      slot.radius(Is(bar_slot_corner)) |> ignore
      // (held: drawn over the row where the finger has it, the slot's place kept)
      slot.alpha(By(fn() { if held_key() == Some(key) { 0.0 } else { 1.0 } })) |> ignore
      slot.box(fn(face) {
        @sf.style_node(face, fn() { bar_face })
        face.says(Is(Some(@view.said(Group, label=bar_place_name(key), actions=[Decrement, Increment])))) |> ignore
        // a screen reader's (右移): one slot along
        face.on_step(fn(by) {
          let j = at()
          let n = @signals.untracked(set).length()
          if j + by >= 0 && j + by < n {
            put_at(j, j + by)
          }
        })
        |> ignore
        // the finger's (detectHorizontalDragGestures): lifted once it goes past the slop, following it sideways; let go,
        // put by how many slots it went (a slot's width)
        let from = Ref(0.0)
        face.gesture(@ui.touch_slop(), drag=fn(d) {
          match d.kind {
            Down => {
              // (taken past the slop: the finger already that far from where it went down, what it holds as far
              // along with it from the first, where it went down the start)
              let gone = d.x - d.ox
              from.val = d.wx - gone
              let (fx, _, _, _) = face.placed_window_now()
              let (rx, _, _, _) = r.placed_window_now()
              held.set(Some({ key, x: fx - rx, dx: gone, w: d.w }))
            }
            Moved =>
              match held.get() {
                Some(h) => held.set(Some({ ..h, dx: d.wx - from.val }))
                None => ()
              }
            Up => {
              match held.get() {
                Some(h) if h.w > 0.0 => {
                  let j = at()
                  let n = @signals.untracked(set).length()
                  let to = j + ((d.wx - from.val) / h.w).round().to_int()
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
        bar_face_words_node(face, key)
      })
      |> ignore
      // its "−" over it beside (not inside) what the finger holds: a press on the "−" is its own
      slot.box(fn(m) {
        bar_remove_at_node(m)
        m.show(fn() { !only() }, fn(k) {
          bar_remove_node(k, key, fn() {
            let (now, ncur) = (core.bars)()
            @settings.save_bars(core, now.mapi(fn(n, s) { if n == i { s.filter(fn(p) { p != key }) } else { s } }), ncur)
          })
        })
      })
      |> ignore
    })
    // with room left, a slot that adds one, from where it is
    r.show(fn() { set().length() < @settings.bar_size }, fn(a) {
      @sf.style_node(a, fn() { bar_slot }, in_row=true)
      @sf.action_box_node(a, fn() { @sf.t("android-misc.bar.add") }, fn(face) { add(Node(face)) }, fn(face) {
        @sf.style_node(face, fn() { bar_face })
        face.box(fn(w) {
          @sf.style_node(w, fn() { bar_face_words })
          w.box(fn(ring) {
            @sf.style_node(ring, fn() { bar_add_ring })
            @sf.icon_node(ring, "plus", bar_add_mark, By(fn() { @sf.theme().p.subtle })) |> ignore
          })
          |> ignore
          @sf.words_node(w, fn() { @sf.t("android-misc.bar.add") }, fn() { bar_add_words }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    // the slots left past it, empty
    r.each(fn() { Array::makei(dmax_int(0, @settings.bar_size - set().length() - 1), fn(k) { k }) }, fn(k) { k.to_string() }, fn(e, _) {
      @sf.style_node(e, fn() { bar_slot }, in_row=true)
    })
    // the one held, where the finger has it, over the rest
    r.show(fn() { held.get() is Some(_) }, fn(o) {
      o.over(Is(true)) |> ignore
      o.pick(fn() { held_key().unwrap_or("") }, fn(p, key) {
        p.box(fn(slot) {
          @sf.style_node(slot, fn() { bar_slot_held })
          let raised = @sf.held_raised
          slot.radius(Is(bar_slot_corner)).shadow(Is((raised.sigma, raised.dy, raised.color))) |> ignore
          slot
          .width(By(fn() { held.get().map(fn(h) { Some(h.w) }).unwrap_or(None) }))
          .offset(By(fn() { held.get().map(fn(h) { (h.x + h.dx, 0.0) }).unwrap_or((0.0, 0.0)) }))
          .scale(Is(bar_held_scale))
          |> ignore
          slot.box(fn(face) {
            @sf.style_node(face, fn() { bar_face })
            bar_face_words_node(face, key)
          })
          |> ignore
          slot.box(fn(m) {
            bar_remove_at_node(m)
            m.show(fn() { !only() }, fn(k) { bar_remove_look_node(k) })
          })
          |> ignore
        })
        |> ignore
      })
    })
  })
  |> ignore
}

///|
/// The larger of two whole numbers.
fn dmax_int(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// How much larger a slot held is (graphicsLayer's scale, 1.08).
let bar_held_scale : Double = 1.08

///|
/// A slot's mark over its name (place `key`'s), in `face`.
fn bar_face_words_node(face : @view.View, key : String) -> Unit {
  face.box(fn(w) {
    @sf.style_node(w, fn() { bar_face_words })
    w.box(fn(m) {
      @sf.style_node(m, fn() { bar_mark_room })
      bar_place_mark_node(m, key)
    })
    |> ignore
    @sf.words_node(w, fn() { bar_place_name(key) }, fn() { bar_place_words }) |> ignore
  })
  |> ignore
}

///|
/// A place's mark in the bar's ink (28): the stations', their glyph with one station on, as no station is meant; the
/// others' their icon (@sfbase.place_icon).
fn bar_place_mark_node(m : @view.View, place : String) -> Unit {
  let ink = fn() { @sf.theme().p.text }
  if place == "stations" {
    let still : @sf.GlyphCounts = { online: 1, dim: 0, failing: 0, working: 0, asleep: false, connecting: 0 }
    @sf.station_glyph_node(m, fn() { still }, bar_mark, ink, fn() { @sf.theme().p.red }) |> ignore
  } else {
    @sf.icon_node(m, @sfbase.place_icon(place), bar_mark, By(ink)) |> ignore
  }
}

///|
/// A place's mark's side.
let bar_mark : Double = 28.0

///|
/// Where a slot's "−" stands, node `m`: over all of its slot, the "−" in its top right corner, in from it as far as
/// makes it concentric with its card's corner where the slot is the last.
fn bar_remove_at_node(m : @view.View) -> Unit {
  let p = bar_remove_in
  m.over(Is(true)).padding(Is((p, p, p, p))).lines_up(Is(Some(End))) |> ignore
}

///|
/// The "−" that takes place `key` out of its bar, in `m` (bar_remove_at_node's), `press` as it is pressed.
fn bar_remove_node(m : @view.View, key : String, press : () -> Unit) -> Unit {
  @sf.action_box_node(m, fn() { @sf.t("android-misc.bar.remove", args=[("name", bar_place_name(key))]) }, fn(_) { press() }, fn(minus) {
    @sf.style_node(minus, fn() { bar_remove })
    @sf.icon_node(minus, "minus", bar_remove_mark, By(fn() { @sf.theme().p.muted })) |> ignore
  })
  |> ignore
}

///|
/// The "−"'s look alone (bar_remove_node's), in `m`: on the slot held, drawn where the finger has it.
fn bar_remove_look_node(m : @view.View) -> Unit {
  m.box(fn(minus) {
    @sf.style_node(minus, fn() { bar_remove })
    @sf.icon_node(minus, "minus", bar_remove_mark, By(fn() { @sf.theme().p.muted })) |> ignore
  })
  |> ignore
}

// ── styles ─────────────────────────────────────────────

///|
/// The slots side by side, each a quarter of the card, as far apart as they go where it is wider than four slots.
// kept across runs: a value (no field of it changes)
let bar_slots : @ui.Style = @ui.css("row w=Full justify=JBetween")

///|
/// A slot: its corner round its "−" in its corner (bar_slot_corner).
// kept across runs: a value (no field of it changes)
let bar_slot : @ui.Style = @ui.style(w=@sf.grow, max_w=Fixed(bar_slot_most))

///|
/// A slot's corner: concentric with its card's at the room the card leaves round its slots (a card's row's).
let bar_slot_corner : Double = @ui.concentric(@sf.group_corner, @sf.list_pad)

///|
/// A slot's widest: as wide as a phone's quarter of its card, its "−" by its mark wherever the card is wider.
let bar_slot_most : Double = 88.0

///|
/// A slot held: on the card's ground, raised (shadow(6), black at 14% both: @sf.held_raised), round as a slot is; as
/// wide as its slot (bar_card_node's).
// kept across runs: a value (no field of it changes)
let bar_slot_held : @ui.Style = @ui.css("bg=Card")

///|
/// What a slot shows, 12 over and 10 under it, in its middle.
// kept across runs: a value (no field of it changes)
let bar_face : @ui.Style = @ui.style(w=@sf.grow, max_w=Fixed(bar_slot_most), pt=S3, pb=S2_5, align=ACenter)

///|
/// Its mark over its name, 6 apart.
// kept across runs: a value (no field of it changes)
let bar_face_words : @ui.Style = @ui.css("gap=S1_5 align=ACenter")

///|
/// The mark's room, 30 high.
// kept across runs: a value (no field of it changes)
let bar_mark_room : @ui.Style = @ui.style(h=Fixed(bar_side), justify=JCenter)

///|
let bar_side : Double = 30.0

///|
// kept across runs: a value (no field of it changes)
let bar_place_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let bar_add_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
/// The "−" that takes a place out: 20 round, on the neutral wash, in from its slot's top right corner as far as makes
/// it concentric with its card's corner where the slot is the last (capsule_in: the group's corner less its half, less
/// the card's list_pad the slot is in; the slot round it there: bar_slot).
// kept across runs: a value (no field of it changes)
let bar_remove : @ui.Style = @ui.css("w=S5 h=S5 radius=Full bg=Neutral align=ACenter justify=JCenter")

///|
/// How far in from its slot's top right corner the "−" stands.
let bar_remove_in : Double = @ui.capsule_in(@sf.group_corner, bar_remove_side) - @sf.list_pad

///|
let bar_remove_side : Double = 20.0

///|
let bar_remove_mark : Double = 12.0

///|
/// The add slot's ring: 30 round, its line 1.5.
// kept across runs: a value (no field of it changes)
let bar_add_ring : @ui.Style = @ui.style(
  w=Fixed(bar_side),
  h=Fixed(bar_side),
  radius=Full,
  border=B1_5,
  border_color=Line,
  align=ACenter,
  justify=JCenter,
)

///|
let bar_add_mark : Double = 22.0

///|
/// 新建一栏's mark.
let bar_new_mark : Double = 20.0
