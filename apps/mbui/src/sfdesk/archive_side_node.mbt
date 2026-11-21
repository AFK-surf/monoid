// 已归档 as one of the chats' lists (still.fail web/src/pages/Archive.tsx ArchiveRows, ArchivePage; Archive.css.ts) made
// once as nodes of the window's tree, on the sidebar's track after 全部, 我参与的 and 监控中 (side_node's lists_side_node):
// a field to look for one, the archive's days under their headings, each archived chat a row (put back or deleted while
// pointed at, or from its menu), pressed its chat beside the list; opened, the newest of them is open beside it, or with
// none what the archive is (archive_main_node). Each line made only while it shows (View::scrolls_window); a page more
// as it comes near its end while the core says it has more.

///|
/// What an archive's line is (its key's kind): the room over it, its field, what could not be read, its rows to come,
/// what the core says of it, a day's heading, a chat's row, the room under it.
#derive(Eq)
priv enum ArchiveLine {
  Top
  Search(Bool)
  Failing(String)
  Waiting
  Said(String)
  Day(String)
  Row(Json, Bool)
  Foot
}

///|
/// 已归档 (ArchiveRows) of workspace `ws` in lane `l` of the sidebar's track, standing `at`: under the room `top` says
/// (the band's), over the room `foot` says, on `ground` (a row's face's), tips in `tips`, pictures asked on `stint`.
fn archive_pane_node(
  l : @view.View,
  src : Source,
  ws : () -> String,
  top : () -> Double,
  foot : () -> Double,
  at : @sf.ListAt,
  tips : @sf.TipLayer,
  stint : () -> Int,
) -> Unit {
  let asked = fn() -> Map[String, Json] {
    let p : Map[String, Json] = {
      "scope": Json::string(ws()),
      "limit": Json::number(archive_side.limit.get().to_double()),
    }
    if archive_side.q.get() != "" {
      p["q"] = Json::string(archive_side.q.get())
    }
    p
  }
  let topic = fn() { src.topic("archive", asked()).get() }
  // (what the core last answered: shown while what is asked now (other words, a page more) has not come)
  // (the core's value, a new JSON each time it changes: told by its object)
  // (another workspace's last answer is none of this one's)
  let kept = if archive_side.last_ws == @signals.untracked(ws) { archive_side.last } else { None }
  let last : @signals.Signal[Json?] = @signals.signal_by(kept, same=fn(a, b) { physical_equal(a, b) })
  // what came, went or moved in it makes its way only as the core tells it changed (watched): not its answer first come
  // here (made again, back from 设置 or another workspace: what showed till then was the last answer kept), nor one to
  // other words looked for or of another workspace, each its list anew at once
  let watched = Ref(false)
  let seen : Ref[(String, String)?] = Ref(None)
  l.reacts(topic, fn(t) {
    match t.value {
      Some(_) as now => {
        let here = (@signals.untracked(ws), archive_side.q.untracked())
        watched.val = seen.val == Some(here) && !@view.answering_now()
        seen.val = Some(here)
        last.set(now)
        // (for ⌥↑ ⌥↓ and the newest opened beside it: what is shown, read as they are done, keys.mbt neighbour)
        archive_side.last = now
        archive_side.last_ws = here.0
        archive_side.note.set(text(now, "note"))
      }
      None => ()
    }
  })
  let view = fn() { last.get() }
  // its lines, by their keys, and what each is: worked out once as what is shown changes
  let lines : @signals.Computed[(Array[String], Map[String, ArchiveLine])] = @signals.computed(fn(_) {
    let keys = ["top", "search"]
    let of : Map[String, ArchiveLine] = { "top": Top }
    let put = fn(k : String, line : ArchiveLine) {
      keys.push(k)
      of[k] = line
    }
    match view() {
      None =>
        match topic().error {
          Some(e) => put("failing/0", Failing(text(Some(e), "message")))
          None => put("wait", Waiting)
        }
      Some(_) as v => {
        let days = items(v, "days")
        for i, e in items(v, "errors") {
          put("failing/" + i.to_string(), Failing(text(Some(e), "text")))
        }
        if days.length() == 0 && text(v, "note") != "" {
          put("said", Said(text(v, "note")))
        }
        for d in days {
          put("h/" + text(Some(d), "label"), Day(text(Some(d), "label")))
          let list = items(Some(d), "items")
          for j, it in list {
            // (another row under it: the room between them)
            put("r/" + text(Some(it), "station") + "/" + text(Some(it), "session"), Row(it, j + 1 < list.length()))
          }
        }
      }
    }
    put("foot", Foot)
    // (its 4 under it where rows or their bones follow, as the web's margins: in a heading's 14 over it, not on top of
    // it)
    of["search"] = Search(keys.get(2).map(fn(n) { n == "wait" || n.has_prefix("r/") }).unwrap_or(false))
    (keys, of)
  })
  let keys = fn() { lines.get().0 }
  let line_of = fn(k : String) { lines.get().1.get(k) }
  // opened: its newest chat beside it, once a time it is opened with no words looked for (ArchivePage)
  l.reacts(
    fn() { app.nav.top() == Archived && archive_side.q.get() == "" && view() is Some(_) },
    fn(ready) {
      guard ready && !archive_side.landed else { return }
      let v = @signals.untracked(view)
      archive_side.landed = true
      match items(v, "days").get(0) {
        Some(d) =>
          match items(Some(d), "items").get(0) {
            Some(it) => archive_open(it)
            None => ()
          }
        None => ()
      }
    },
  )
  // (near its end while the core has more: a page more, once for what it answered)
  let more = fn() { flag(view(), "more") && topic().value is Some(_) }
  let scroll = @view.Scroll::list()
  l.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  // (its bar along its right, clear of what is over its top and at its foot: the band, the foot's band)
  l.scrolls_window(
    scroll,
    keys,
    est=@signals.untracked(fn() { @sf.theme().chat_list.row_h }),
    bar=@ui.tree_scroll_bar(),
    top_covered=top,
    bar_clear=fn() { (top(), foot()) },
    near_foot=(1.0, more, fn() { archive_side.limit.set(archive_side.limit.untracked() + archive_side_page) }),
    // (an archived chat's row, and a day's heading, as it no more shows taken by the next of its kind to come to show:
    // its key that one's, not made and let go as the list is scrolled)
    reused=fn(k) {
      match lines.untracked().1.get(k) {
        Some(Row(_, _)) => Some(0)
        Some(Day(_)) => Some(1)
        _ => None
      }
    },
    make_reused=fn(b, key) {
      // (what its key is now, the last it was where it is gone from the list: told only as that changes)
      let mine = @signals.computed(fn(was) {
        match line_of(key()) {
          Some(_) as l => l
          None => was.unwrap_or(None)
        }
      })
      let now = fn() { mine.get() }
      b.box(fn(line) {
        @sf.style_node(line, fn() { @sf.list_line(at) })
        match b.reused_kind() {
          Some(1) => archive_day_side_node(line, at, now)
          Some(0) => archive_row_line_node(line, src, tips, at, stint, Json::null(), now, key)
          _ => ()
        }
      })
      |> ignore
    },
    // (a chat's row or a day's heading, as the core told the list it changed: watched)
    comes=fn(k) { watched.val && (k.has_prefix("r/") || k.has_prefix("h/")) },
    goes=fn(k) { watched.val && (k.has_prefix("r/") || k.has_prefix("h/")) },
    fn(b, k) {
      // (what this line is as the list says it now, told only as that changes: a chat put back tells the others nothing)
      let mine = @signals.computed(fn(_) { line_of(k) })
      let now = fn() { mine.get() }
      b.box(fn(line) {
        @sf.style_node(line, fn() { @sf.list_line(at) })
        match @signals.untracked(now) {
          Some(Top) => line.height(By(fn() { Some(top() + archive_side_top_in) })) |> ignore
          Some(Foot) => line.height(By(fn() { Some(foot() + @sf.list_foot_in(at)) })) |> ignore
          Some(Search(_)) =>
            archive_search_side_node(line, at, fn() {
              match now() {
                Some(Search(gap)) => gap
                _ => false
              }
            })
          Some(Failing(_)) =>
            side_said_node(line, true, fn() {
              match now() {
                Some(Failing(w)) => w
                _ => ""
              }
            })
          Some(Said(_)) =>
            side_said_node(line, false, fn() {
              match now() {
                Some(Said(w)) => w
                _ => ""
              }
            })
          Some(Waiting) => @sf.waiting_node(line, fn(s) { archive_sample_node(s, at, tips, stint) })
          Some(Day(_)) => archive_day_side_node(line, at, now)
          Some(Row(first, _)) => archive_row_line_node(line, src, tips, at, stint, first, now, fn() { k })
          None => ()
        }
      })
      |> ignore
    },
  )
  |> ignore
}

///|
/// A day's heading of the archive (archive_pane_node's) in `line`, its line as it is now (`now`).
fn archive_day_side_node(line : @view.View, at : @sf.ListAt, now : () -> ArchiveLine?) -> Unit {
  @sf.list_heading_node(
    line,
    fn() {
      match now() {
        Some(Day(d)) => d
        _ => ""
      }
    },
    at,
  )
}

///|
/// An archived chat's line of the archive (archive_pane_node's) in `line`, its line as it is now (`now`; `first` as it
/// was made) under its key as it is now (`key`: another's as a line put by is taken for another).
fn archive_row_line_node(
  line : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  at : @sf.ListAt,
  stint : () -> Int,
  first : Json,
  now : () -> ArchiveLine?,
  key : () -> String,
) -> Unit {
  let it = fn() {
    match now() {
      Some(Row(i, _)) => i
      _ => first
    }
  }
  let more = fn() {
    match now() {
      Some(Row(_, m)) => m
      _ => false
    }
  }
  archive_row_side_node(line, src, tips, it, more, at, stint, key~)
}

///|
/// What the core says over the sidebar's list (side_said's) in `line`: its words as they are now, in red where `bad`.
fn side_said_node(line : @view.View, bad : Bool, words : () -> String) -> Unit {
  line.box(fn(b) {
    @sf.style_node(b, fn() { side_said_box })
    @sf.words_node(b, words, fn() { if bad { side_words_bad } else { side_words } }) |> ignore
  })
  |> ignore
}

///|
/// Looking for one (archive_search_side's) in `line`: the library's field to look through a list by, standing where the
/// list does (@sf.search_input_node: the theme's band's height, its words' room, its mark, its words, the clear key
/// while it holds words); its 4 under it while `gap` says. What it holds the archive's words looked for (archive_side's
/// `q`, trimmed), the first page asked again as they change.
fn archive_search_side_node(line : @view.View, at : @sf.ListAt, gap : () -> Bool) -> Unit {
  let own = @ui.Field::new(text=archive_side.q.untracked())
  line.box(fn(o) {
    @sf.style_node(o, fn() { if gap() { arch_field_box } else { arch_field_alone } })
    o.reacts(fn() { own.text() }, fn(w) {
      let q = w.trim(chars=" \t\n").to_owned()
      if q != archive_side.q.untracked() {
        archive_side.q.set(q)
        archive_side.limit.set(archive_side_page)
      }
    })
    @sf.search_input_node(o, own, fn() { @sf.t("web-pages.archive.search") }, at~) |> ignore
  })
  |> ignore
}

///|
/// An archived chat's row (ArchiveRow) in `parent`, `it` as it is now, standing `at`: its title (its station's mark at
/// its end, with several), the last thing said under it, when it was archived there while pointed at (how, on its
/// tip; always to a finger); over its first line's end then, putting it back and deleting it (one under way: turning),
/// where the native input is a pointer (a finger's are in its menu: @sf.more_held). Pressed, its chat beside the list;
/// right clicked, or held by a finger, its menu (恢复 and 删除). `more`: another row under it.
fn archive_row_side_node(
  parent : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  it : () -> Json,
  more : () -> Bool,
  at : @sf.ListAt,
  stint : () -> Int,
  key? : () -> String = fn() { "" },
) -> Unit {
  let t = fn() { @sf.theme() }
  let v = fn() { Some(it()) }
  let station = fn() { text(v(), "station") }
  let session = fn() { text(v(), "session") }
  let title = fn() { text(v(), "title") }
  let on = fn() {
    match app.nav.top() {
      Chat(r) => r.station == station() && r.session == session()
      _ => false
    }
  }
  let busy = fn() { archive_doing(src, station(), session()) }
  parent.box(fn(holder) {
    @sf.style_node(holder, fn() { if more() { @sf.list_more(at) } else { @sfpages.row_last } })
    let row = holder.box(fn(_) {  })
    // (its keys while pointed at in it, or one under way; none drawn for a finger, too small for one: its menu)
    let over = fn() { busy() || (!@sf.more_held() && @sf.lit_in_node(holder)) }
    // its ground as nav_ground_by has it: the pointer's eased in and out, the selected one's while its chat is in view
    // (taken for another chat as it comes to show (archive_pane_node's reused): its ground as were it made for that one,
    // at once, not easing from the one it was)
    let hover = @motion.hover_fade_keyed(row, key, fn() { @sf.lit_node(row) }, duration_ms=@sf.dur_ms)
    let chosen = @motion.hover_fade_keyed(row, key, on, duration_ms=@sf.dur_ms)
    let ground = fn() {
      let p = t().p
      let h = hover()
      let o = chosen()
      if h <= 0.0 && o <= 0.0 {
        0L
      } else {
        @sf.over(@sf.alpha(p.hover, h * (1.0 - o)), @sf.alpha(p.selected, o))
      }
    }
    let keys_n = fn() { if flag(v(), "deletable") { 2 } else { 1 } }
    @sf.list_row_node(
      row,
      at,
      ground~,
      high=true,
      // (恢复 and 删除 over its first line's end)
      end_room=fn() { if over() { @sf.row_keys_room(keys_n()) } else { 0.0 } },
      end_slot=@ui.Space::S4.px(),
      fn(h) {
        h.box(fn(n) {
          n.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(n, title, fn() { t().chat_list.title }) |> ignore
        })
        |> ignore
        // where it was, by its station's mark
        h.pick(
          fn() {
            if @sf.has_station_mark(text(v(), "stationEmoji"), text(v(), "stationIcon")) {
              Some(@sfpages.kind_mark_of(text(v(), "stationIcon")))
            } else {
              None
            }
          },
          fn(k, size) {
            guard size is Some(size) else {
              k.laid_nowhere(Is(true)) |> ignore
              return
            }
            @sf.style_node(k, fn() { @sfpages.kind_slot }, in_row=true)
            k.gone_empty(Is(true)) |> ignore
            k.says(By(fn() { Some(@view.said(Image, label=text(v(), "place"))) })) |> ignore
            @sf.station_mark_node(
              k,
              fn() { text(v(), "stationEmoji") },
              fn() { text(v(), "stationIcon") },
              size,
              fn() { t().p.muted },
              stint,
              visible_only=true,
            )
            @sf.tip_node(tips, k, fn() { text(v(), "place") }, within=true) |> ignore
          },
        )
      },
      fn(u) {
        @sf.list_row_line_node(u, fn(m) {
          m.box(fn(s) {
            s.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(s, fn() { text(v(), "last") }, fn() { t().chat_list.last }) |> ignore
          })
          |> ignore
          // (its clock while pointed at; always to a finger, which hovers over nothing; how it was archived on its tip)
          m.show(fn() { !@sf.pointer_rests() || @sf.lit_in_node(holder) }, fn(e) {
            e.box(fn(clock) {
              @sf.words_node(clock, fn() { text(v(), "clock") }, fn() { arch_clock }) |> ignore
              @sf.tip_node(tips, clock, fn() { text(v(), "how") }, within=true) |> ignore
            })
            |> ignore
          })
        })
      },
    )
    // pressed: its chat beside the list; right clicked, or held by a finger, its menu
    row
    .says(By(fn() { Some(@view.said(Link, label=title())) }))
    .tab_stop(Is(false))
    |> ignore
    @sf.menu_presses_node(
      row,
      fn() {
        archive_open(@signals.untracked(it))
        @sfbase.show_chosen()
      },
      fn(x, y, held) {
        guard !@signals.untracked(busy) else { return }
        let from = if held {
          let (rx, ry, rw, rh) = row.placed_window_now()
          @sf.Beside::At(rx, ry, rw, rh)
        } else {
          @sf.at_point(x, y)
        }
        archive_menu_from(src, @signals.untracked(it), from)
      },
    )
    // 恢复 and 删除 at its top right while pointed at (or one under way), concentric with its corner
    holder.show(over, fn(o) {
      o
      .over(Is(true))
      .lines_up(Is(Some(End)))
      .padding(Is((0.0, @ui.capsule_in(@sf.row_corner, row_key_side), @ui.capsule_in(@sf.row_corner, row_key_side), 0.0)))
      |> ignore
      o.box(fn(line) {
        line.row(Is(true)).gap(Is(@ui.Space::px(S0_5))).lines_up(Is(Some(Middle))) |> ignore
        archive_key_node(
          line,
          tips,
          "retry",
          fn() { t().p.text },
          fn() { @sf.t("web-pages.archive.restoreNamed", args=[("title", title())]) },
          busy,
          fn() { archive_restore(src, @signals.untracked(it)) },
        )
        line.show(fn() { flag(v(), "deletable") }, fn(d) {
          archive_key_node(
            d,
            tips,
            "trash",
            fn() { t().p.red },
            fn() { @sf.t("web-pages.archive.deleteNamed", args=[("title", title())]) },
            fn() { false },
            fn() { archive_delete(src, @signals.untracked(it)) },
          )
        })
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// A key of an archived chat's row (@sf.row_key_box's) in `parent`: the library's icon button (@sf.icon_button_node),
/// round, 24 across, the pointer's ground on it; its `icon` muted, in `lit()` under the hand; read out a button named
/// `label()`, its tip; pressed, `press`. While `busy`, a spinner in its place, taking no press.
fn archive_key_node(
  parent : @view.View,
  tips : @sf.TipLayer,
  icon : String,
  lit : () -> Int64,
  label : () -> String,
  busy : () -> Bool,
  press : () -> Unit,
) -> Unit {
  parent.pick(busy, at_once=true, fn(k, on) {
    if on {
      k.width(Is(Some(row_key_side))).height(Is(Some(row_key_side))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      @sf.spinner_node(k, size=arch_spin) |> ignore
    } else {
      @sf.icon_button_node(k, icon, label, press, tips~, size=row_key_side, icon_size=arch_icon, ink=lit) |> ignore
    }
  })
}

///|
/// A row's key's side (row_key_box: S6).
let row_key_side : Double = 24.0

///|
/// The archive's rows to come while it is read (in their bones): made-up chats' rows, as archive_row_side_node makes them.
fn archive_sample_node(s : @view.View, at : @sf.ListAt, tips : @sf.TipLayer, stint : () -> Int) -> Unit {
  let rows = [(7, 13), (10, 9), (6, 15), (12, 11), (8, 14), (9, 10)]
  for i, n in rows {
    let it : Json = {
      "station": "sample",
      "session": Json::string("sample" + i.to_string()),
      "title": Json::string(@sf.sample_words(n.0)),
      "last": Json::string(@sf.sample_words(n.1)),
      "clock": Json::string(@sf.sample_words(3)),
    }
    let more = i + 1 < rows.length()
    archive_row_side_node(s, @sfbase.sample_source, tips, fn() { it }, fn() { more }, at, stint)
  }
}

///|
/// An archived chat's menu (its 恢复 and 删除 as its keys under the pointer) from `from`: right clicked at the pointer,
/// held by a finger from its row.
fn archive_menu_from(src : Source, it : Json, from : @sf.Beside) -> Unit {
  let items : Array[@sf.MenuItem?] = [
    Some(@sf.menu_item_of(@sf.t("web-pages.archive.restore"), icon="retry", fn() { archive_restore(src, it) })),
  ]
  if flag(Some(it), "deletable") {
    items.push(Some(@sf.menu_item_of(@sf.t("common.delete"), icon="trash", danger=true, fn() { archive_delete(src, it) })))
  }
  @sf.menu(items, from~, title=text(Some(it), "title"))
}

///|
/// The archive open with none of its chats beside it (ArchivePage) in node `v`: what it is, in the middle of the pane;
/// the core's note over that where it says one.
fn archive_main_node(v : @view.View) -> Unit {
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  v.box(fn(b) {
    @sf.style_node(b, fn() { arch_empty })
    @sf.words_node(b, fn() { @sf.t("web-pages.archive.title") }, fn() { arch_empty_title }) |> ignore
    b.show(fn() { archive_side.note.get() != "" }, fn(n) {
      @sf.words_node(n, fn() { archive_side.note.get() }, fn() { arch_empty_words }) |> ignore
    })
    @sf.words_node(b, fn() { @sf.t("web-pages.archive.about") }, fn() { arch_empty_words }) |> ignore
  })
  |> ignore
}

///|
/// The room between the band and the lane's search field, with either input (the old lane's 4, the web's margin over
/// its field): its search shows at its top, not tucked as the chats' is, so it keeps that room where a finger's chats'
/// lists have none (chat_list's top_in).
let archive_side_top_in : Double = 4.0
