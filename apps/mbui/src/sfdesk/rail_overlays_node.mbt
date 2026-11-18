// What opens from the rail over the wide frame (rail.mbt), as nodes of the window's tree: its menu (a right click on
// it: the library's menu, @sf.menu_node, beside the place right clicked), what can be added beside it while it is
// changed (自定义侧边条: the library's panel that leaves the rail in use, @sf.beside_panel_node). The ＋'s menu over
// the workspaces is the presenters' (sfpages' workspace_add_pressed), the list of what comes and goes its key's
// (rail_node.mbt rail_transfers_node).

///|
/// What opens from the rail over the wide frame, in node `v` (a shell's, taped_shell's and paned_shell's), in the
/// workspace in view: its menu and the adder while it is changed.
pub fn rail_overlays_node(v : @view.View, src : Source) -> Unit {
  rail_menu_node(v, src)
  rail_adder_node(v, src)
}

///|
/// The rail's menu opened as a right click on `place` opens it (sffix's rail-menu).
pub fn open_rail_menu(place : String) -> Unit {
  wide.rail_menu.set(Some((place, rail_place_at(place))))
}

///|
/// One opening of the rail's menu (wide.rail_menu set): its number, the place right clicked ("" the rail itself), where
/// that was as it was right clicked.
#derive(Eq)
priv struct RailMenuOpening {
  n : Int
  place : String
  from : (Double, Double, Double, Double)?
}

///|
/// The rail's menus drawn, each opening its own (shown, or going: one opened again elsewhere as another goes comes in
/// beside its own place), and the one open now (0 none).
// kept across runs: put back by wide_reset (rail_menus_reset)
let rail_menus : @signals.Signal[Array[RailMenuOpening]] = @signals.signal_by([], same=fn(a, b) {
  a.length() == b.length() && a.iter().zip(b.iter()).all(fn(p) { p.0.n == p.1.n })
})

///|
// kept across runs: put back by wide_reset (rail_menus_reset)
let rail_menu_now : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })

///|
/// The rail's menus gone their way out (by their number), let go of as the next opens.
// kept across runs: put back by wide_reset (rail_menus_reset)
let rail_menus_gone : Map[Int, Bool] = Map([])

///|
// kept across runs: counted on, put back by wide_reset (rail_menus_reset)
let rail_menu_count : Ref[Int] = Ref(0)

///|
fn rail_menus_reset() -> Unit {
  rail_menus.set([])
  rail_menus_gone.clear()
  rail_menu_now.set(0)
  rail_menu_count.val = 0
}

///|
/// The rail's menu in node `v`, beside the place right clicked (else its first), 8 past it, clear of the window's
/// buttons' row, the library's menu (@sf.menu_node: Escape, back and a press outside close it, a right click outside
/// closing it and going on to what is under it): the places not in the rail (pressed, their page; their ＋, shown on
/// the row under the hand or with the keyboard's focus, puts one in it and the rail is changed from there),
/// 从侧边条移除 the place right clicked, 自定义侧边条, 侧边条恢复默认 where it was changed. Each opening a menu of its
/// own, made as it is opened; what it holds kept as it was as it closes, while it goes; one whose choice puts the adder
/// in its place gone at once.
fn rail_menu_node(v : @view.View, src : Source) -> Unit {
  v.reacts(fn() { wide.rail_menu.get() }, fn(m) {
    match m {
      Some((place, from)) => {
        rail_menu_count.val += 1
        let n = rail_menu_count.val
        // (those gone their way out let go of as another opens: never as one goes, what it is let go in)
        let left = rail_menus.untracked().filter(fn(x) { !rail_menus_gone.contains(x.n) })
        rail_menus_gone.clear()
        rail_menus.set(left + [{ n, place, from }])
        rail_menu_now.set(n)
      }
      None => rail_menu_now.set(0)
    }
  })
  v.each(fn() { rail_menus.get() }, fn(o) { o.n }, fn(cell, o) {
    // (over the window, as what it holds is)
    cell.over(Is(true)) |> ignore
    let { n, place, from } = o.untracked()
    let workspace = @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 })
    // (what it held as it closed, kept while it goes; and whether the adder took its place: gone at once)
    let kept : Ref[Array[(@sf.MenuItem?, @sf.MenuEnd?)]?] = Ref(None)
    let replaced = @signals.signal(false)
    let open = fn() { rail_menu_now.get() == n }
    let close = fn() {
      if @signals.untracked(open) {
        wide.rail_menu.set(None)
      }
    }
    let live = fn() {
      match workspace {
        Some(w) => rail_menu_items(src, w, place, replaced, close)
        None => []
      }
    }
    let entries = fn() {
      match kept.val {
        Some(items) => items
        None => live()
      }
    }
    let content = fn() { entries().map(fn(e) { e.0 }) }
    let hold = fn() {
      if kept.val is None {
        kept.val = Some(@signals.untracked(live))
      }
    }
    cell.reacts(open, at_start=false, fn(on) {
      if !on {
        hold()
      }
    })
    let (ax, ay, aw, ah) = from.unwrap_or((0.0, rail_menu_clear, rail_w - side_into_rail, 0.0))
    cell.show(at_once=true, fn() { !replaced.get() }, fn(m) {
      m.over(Is(true)) |> ignore
      @sf.menu_node(
        m,
        open,
        fn(layer) { @sf.fixed_anchor(layer, (ax, dmax(ay, rail_menu_clear), aw, ah)) },
        content,
        "",
        Start,
        rail_menu_off,
        false,
        false,
        fn(item) {
          hold()
          close()
          (item.select)()
        },
        fn() {
          hold()
          close()
        },
        gone=fn() { rail_menus_gone[n] = true },
        // (a place's ＋ at the end of its row)
        extras=fn(i) {
          let end = match @signals.untracked(entries).get(i) {
            Some((_, e)) => e
            None => None
          }
          { note: "", value: "", mark: None, end }
        },
        side=Right,
      )
    })
  })
}

///|
/// What the rail's menu holds, of workspace `w`, right clicked on `place` ("" the rail itself), as the rail is now,
/// each with what stands at its row's end: the places not in it (提醒 no page, nor the one in view at the rail's foot:
/// put in from 自定义侧边条) under 未固定的, each with its ＋, a line under them; 从侧边条移除 `place`, where it is in
/// the rail and not its last; 自定义侧边条; 侧边条恢复默认 where the rail was changed. Chosen, `close`d first, then each
/// does its own; 自定义侧边条, and a place's ＋, put the adder in the menu's place (`replaced`).
fn rail_menu_items(
  src : Source,
  w : Workspace,
  place : String,
  replaced : @signals.Signal[Bool],
  close : () -> Unit,
) -> Array[(@sf.MenuItem?, @sf.MenuEnd?)] {
  let kept = rail_items(src, w.id)
  let extra = rail_in_view(src, w)
  let away = rail_places(src).filter(fn(i) { !kept.contains(i) && i != "attention" && i != extra })
  let items : Array[(@sf.MenuItem?, @sf.MenuEnd?)] = []
  let item = fn(m : @sf.MenuItem) { items.push((Some(m), None)) }
  if away.length() > 0 {
    item(@sf.menu_item_of(@sf.t("web-main.rail.away"), fn() {  }, heading=true))
    for i in away {
      let label = rail_label(src, i)
      let end : @sf.MenuEnd = {
        label: @sf.t("web-main.rail.add", args=[("name", label)]),
        icon: "plus",
        press: fn() {
          // (put in, the rail changed from there, the menu gone at once for the adder)
          rail_keep(src, w.id, rail_items(src, w.id) + [i])
          replaced.set(true)
          close()
          wide.editing.set(true)
        },
      }
      items.push((Some(@sf.menu_item_of(label, fn() { rail_go_told(src, w, i, fn(_, f) { f() }) }, icon=rail_icon(i))), Some(end)))
    }
    items.push((None, None))
  }
  if place != "" && kept.contains(place) && kept.length() > 1 {
    item(
      @sf.menu_item_of(@sf.t("web-main.rail.remove", args=[("name", rail_label(src, place))]), fn() {
        rail_keep(src, w.id, kept.filter(fn(i) { i != place }))
      }, icon="minus"),
    )
  }
  item(
    @sf.menu_item_of(@sf.t("web-main.rail.customize"), fn() {
      replaced.set(true)
      wide.editing.set(true)
    }, icon="sliders"),
  )
  if flag(rail_of(src, w.id), "changed") || board_rail_changed(src, w.id) {
    item(@sf.menu_item_of(@sf.t("web-main.rail.reset"), fn() { rail_reset(src, w.id) }, icon="refresh"))
  }
  items
}

///|
/// Where the adder goes beside the rail as it is opened: the rail as it is placed then, no higher than the window's
/// buttons' row (collisionPadding top 52); where the rail is not placed, its 56 from there down.
// kept across runs: said as the rail is changed, put back by wide_reset
let rail_adder_at : Ref[(Double, Double, Double, Double)] = Ref((0.0, 0.0, 0.0, 0.0))

///|
/// Beside the rail while it is changed (wide.editing), in node `v`: what can be added, by kind as the core groups them
/// (看板 among the lists after 对话 while 实验性功能's 对话列表看板视图 is on), each pressed into the rail, 全部已加入
/// where nothing is left out; 248 wide, 8 past the rail (its 56: the sidebar reaches over its last 8), clear of the
/// window's buttons' row. The library's panel that leaves the rail in use (@sf.beside_panel_node): a press in the rail
/// ends nothing, its places moved and taken out there; Escape, back and a press anywhere else end the change.
fn rail_adder_node(v : @view.View, src : Source) -> Unit {
  v.reacts(fn() { wide.editing.get() }, fn(on) {
    if on {
      rail_adder_at.val = match rail_col.val {
        Some(r) if r.alive() => {
          let (x, y, w, _) = r.placed_window_now()
          (x, dmax(y, rail_menu_clear), w, 0.0)
        }
        _ => (0.0, rail_menu_clear, rail_w, 0.0)
      }
    }
  })
  let workspace = fn() { @sfbase.workspace_in_view(src).0 }
  @sf.beside_panel_node(
    v,
    fn() { wide.editing.get() && workspace() is Some(_) },
    fn(layer) { @sf.fixed_anchor(layer, rail_adder_at.val) },
    rail_adder_w,
    fn() { @sf.t("web-main.rail.customize") },
    fn(b) {
      b.box(fn(body) {
        @sf.style_node(body, fn() { adder_body })
        // (its title and what it says of the change under it, one head: panel_head's `note`)
        body.box(fn(head) {
          @sf.panel_head_node(head, fn() { @sf.t("web-main.rail.customize") }) |> ignore
          @sf.panel_note_node(head, fn() { @sf.t("web-main.rail.customizeLead") })
        })
        |> ignore
        let kinds = fn() {
          match workspace() {
            Some(w) => rail_adder_kinds(src, w)
            None => []
          }
        }
        body.each(kinds, fn(k) { k.0 }, fn(g, k) {
          @sf.panel_group_node(g, fn() { k.get().0 }, fn(rows) {
            rows.each(fn() { k.get().1 }, fn(p) { p }, fn(row, p) {
              let place = p.untracked()
              @sf.panel_row_node(
                row,
                fn() { rail_label(src, place) },
                fn() {
                  match @signals.untracked(workspace) {
                    Some(w) => rail_keep(src, w.id, rail_items(src, w.id) + [place])
                    None => ()
                  }
                },
                icon=fn() { rail_icon(place) },
                end="plus",
              )
            })
          })
        })
        body.show(at_once=true, fn() { kinds().is_empty() }, fn(n) {
          @sf.panel_note_node(n, fn() { @sf.t("web-main.rail.allIn") })
        })
      })
      |> ignore
    },
    fn() { wide.editing.set(false) },
    keeps=fn() { rail_col.val },
    side=Right,
    along=Start,
    offset=rail_adder_off,
  )
}

///|
/// What the adder offers of workspace `w`'s rail as it is now: each kind the core groups the places by (railView's
/// `groups`; 看板 among the lists after 对话 while 实验性功能's 对话列表看板视图 is on, as rail_places has it), with the
/// places of it left out of the rail; a kind with none left out, none.
fn rail_adder_kinds(src : Source, w : Workspace) -> Array[(String, Array[String])] {
  let kept = rail_items(src, w.id)
  items(rail_view(src), "groups").filter_map(fn(g) {
    let places = words_in(items(Some(g), "places"))
    if @sfbase.board_feature.get() && text(Some(g), "kind") == "lists" {
      match places.search_by(fn(p) { p == "chats" }) {
        Some(i) => places.insert(i + 1, "board")
        None => places.insert(0, "board")
      }
    }
    let hidden = places.filter(fn(i) { !kept.contains(i) })
    if hidden.length() == 0 {
      None
    } else {
      Some((text(Some(g), "label"), hidden))
    }
  })
}
