// 本机缓存 and a chat's of it (KeptFilesScreen, KeptChatScreen) made once as nodes of the window's tree, one page in
// every frame (page_node): what this device keeps, read of the core as the page is made and again after a deletion
// (kept_asked), each block of a page's list bound to what it shows.

///|
/// What is kept asked of the core as `v` is made, and again each time a page of it changed it (kept_asked).
fn kept_reads_node(v : @view.View, core : Core) -> Unit {
  v.reacts(fn() { kept_asked() }, fn(_) { kept_ask(core) })
}

///|
/// What is kept asked again (a deletion's answer).
fn kept_again() -> Unit {
  kept.asked.set(kept.asked.untracked() + 1)
}

///|
/// 本机缓存 (KeptFilesScreen) made once as nodes in node `v`: all of it first, as one figure over a bar of what it is
/// made of (the chats' messages, the files opened in them, the drives' files, the files of no chat known), each part a
/// row under it, those that can be gone into or let go so; then the chats, the one keeping most first, the first few
/// until all are asked for, a block each; then whether opened files go on coming (后台下载) and what is coming so; and
/// everything let go at once. While it is read, made-up rows in their bones.
pub fn kept_node(
  v : @view.View,
  core : Core,
  on_back~ : () -> Unit,
  frame~ : () -> @sf.PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  kept_reads_node(v, core)
  @sf.page_node(
    v,
    fn() { tr("android-settings.files.title") },
    on_back~,
    frame~,
    said?,
    width?,
    tips?,
    lead=fn() { tr("android-settings.files.note") },
    fn() { kept_keys(core) },
    fn(b, key) { kept_block(b, core, key) },
  )
}

///|
/// 本机缓存's blocks by their keys, as what is kept is said now: "waiting" while it is read; else "parts", the chats'
/// heading and each chat ("chats", "chat/<station>/<thread>"), "more" where there are more than kept_first; what
/// 后台下载 (网络与同步's, fill_group_node) brings now ("going-head", "going/<n>", "stop-all"); "clear-all" where
/// anything is kept.
fn kept_keys(core : Core) -> Array[String] {
  guard kept.chats.get() is Some(chats) else { return ["waiting"] }
  let out = ["parts"]
  if chats.length() > 0 {
    out.push("chats")
    let more = chats.length() > kept_first
    let shown = if more && !kept_all.get() { kept_first } else { chats.length() }
    for i in 0..<shown {
      out.push(kept_chat_key(chats[i]))
    }
    if more {
      out.push("more")
    }
  }
  let keeping = fill_keeping(core)
  if fill_on(core) && keeping.length() > 0 {
    out.push("going-head")
    for i, _ in keeping {
      out.push("going/" + i.to_string())
    }
    out.push("stop-all")
  }
  if kept_total(chats) > 0.0 {
    out.push("clear-all")
  }
  out
}

///|
/// A chat's key among 本机缓存's blocks: its station and thread.
fn kept_chat_key(x : Json) -> String {
  "chat/" + text(Some(x), "station") + "/" + count(Some(x), "thread").to_string()
}

///|
/// Whether what was opened and let go goes on coming (prefs `fillOff`).
fn fill_on(core : Core) -> Bool {
  !flag((core.topic)("prefs", Map([])).get().value, "fillOff")
}

///|
/// How big what is opened and let go is brought whole up to (prefs `fillMax`, fill_sizes' first where it says none).
fn fill_most(core : Core) -> Double {
  match field((core.topic)("prefs", Map([])).get().value, "fillMax") {
    Some(Number(n, ..)) => n
    _ => fill_sizes[0]
  }
}

///|
/// What is coming so now (the `downloads` topic's `keeping`).
fn fill_keeping(core : Core) -> Array[Json] {
  items((core.topic)("downloads", Map([])).get().value, "keeping")
}

///|
/// A size fill may be brought up to in words (0: any).
fn fill_size_said(n : Double) -> String {
  if n == 0.0 {
    tr("android-settings.files.fill.any")
  } else {
    size_words(n)
  }
}

///|
/// 本机缓存's block `key` (kept_keys') in `b`, as what is kept is said now.
fn kept_block(b : @view.View, core : Core, key : String) -> Unit {
  let chats = fn() { kept.chats.get().unwrap_or([]) }
  // (a row of the chats' card, a piece of it as it is among them now)
  let chat_piece = fn(i : () -> Int?, n : () -> Int, row : (@view.View) -> Unit) {
    b.grow(Is(1.0)) |> ignore
    @sf.card_piece_node(b, fn() {
      match i() {
        Some(i) => @sf.card_piece_of(i, n())
        None => @sf.CardPiece::CardWhole
      }
    }, wide_group=true, row)
  }
  match key {
    "waiting" => @sf.waiting_node(b, fn(s) { kept_sample_node(s, true) })
    "parts" => kept_parts_node(b, core)
    "chats" => @sf.section_heading_node(b, fn() { tr("android-settings.files.byChat") })
    "more" =>
      chat_piece(fn() { Some(1) }, fn() { 2 }, fn(g) {
        @sf.link_row_node(
          g,
          fn() {
            if kept_all.get() {
              tr("web-main.fold")
            } else {
              fill("web-main.usage.showAll", [("n", chats().length().to_string())])
            }
          },
          fn() { kept_all.set(!kept_all.untracked()) },
          chevron=false,
          folds=fn() { kept_all.get() },
        )
      })
    "going-head" =>
      @sf.section_heading_node(b, fn() { tr("android-settings.files.fill.going") }, note=fn() {
        let total = fill_keeping(core).fold(init=0.0, fn(n, k) { n + number(Some(k), "size") })
        fill("android-settings.files.total", [("size", size_words(total))])
      })
    "stop-all" =>
      chat_piece(fn() { Some(1) }, fn() { 2 }, fn(g) {
        @sf.link_row_node(g, fn() { tr("android-settings.files.fill.stopAll") }, fn() { (core.call)("fill.stopAll", obj([]), answer_unread) }, danger=true, chevron=false)
      })
    "clear-all" =>
      @sf.group_node(b, fn(g) {
        @sf.link_row_node(
          g,
          fn() { tr("android-settings.files.clearAll") },
          fn() {
            let all = chats()
            let loose = kept.loose.untracked()
            confirm(
              tr("android-settings.files.clearAll.title"),
              fill("android-settings.files.clearAll.text", [("size", size_words(@signals.untracked(fn() { kept_total(all) })))]),
              tr("android-settings.files.clear.action"),
              danger=true,
              fn() {
                for x in all {
                  (core.call)("cache.clear", obj([("station", str(text(Some(x), "station"))), ("thread", Json::number(number(Some(x), "thread")))]), fn(
                    _,
                  ) {
                    kept_again()
                  })
                }
                kept_files_clear(core, loose)
                if kept.drive.untracked() > 0.0 {
                  (core.call)("drive.kept.clear", obj([]), fn(_) { kept_again() })
                }
              },
            )
          },
          danger=true,
          chevron=false,
        )
      })
    k if k.has_prefix("going/") => {
      let at = k.exact_view(start=6).to_owned()
      let kv = fn() { fill_keeping(core).mapi(fn(i, x) { (i.to_string(), x) }).iter().find_first(fn(x) { x.0 == at }).map(fn(x) { x.1 }) }
      // (each stopped where it shows: the transfers' list, its message's card; all of them here at once)
      chat_piece(fn() { if at == "0" { Some(0) } else { Some(1) } }, fn() { 3 }, fn(g) {
        @sf.link_row_node(g, fn() { text(kv(), "title") }, fn() {  }, note=fn() { text(kv(), "statusText") }, goes=false)
      })
    }
    k if k.has_prefix("chat/") => {
      let last : Ref[(Int, Json)?] = Ref(None)
      let now = fn() {
        let all = chats()
        match all.search_by(fn(x) { kept_chat_key(x) == k }) {
          Some(i) => {
            last.val = Some((i, all[i]))
            last.val
          }
          None => last.val
        }
      }
      guard @signals.untracked(now) is Some(_) else { return }
      let xv = fn() { now().map(fn(x) { x.1 }) }
      let shown = fn() {
        let n = chats().length()
        if n > kept_first && !kept_all.get() {
          kept_first
        } else {
          n
        }
      }
      chat_piece(fn() { now().map(fn(x) { x.0 }) }, fn() { shown() + (if chats().length() > kept_first { 1 } else { 0 }) }, fn(g) {
        kept_chat_row_node(g, core, xv)
      })
    }
    _ => ()
  }
}

///|
/// All that is kept (kept_parts', as nodes) in `b`, on a card: large, over a bar of what it is made of; then each part a
/// row with its colour's dot on its line: the chats' messages, the files opened in them, the drives' files (let go when
/// asked), the files of no chat known (gone into); those with nothing in them left out.
fn kept_parts_node(b : @view.View, core : Core) -> Unit {
  let parts = fn() {
    let chats = kept.chats.get().unwrap_or([])
    let messages = chats.fold(init=0.0, fn(s, x) { s + number(Some(x), "bytes") })
    let opened = chats.fold(init=0.0, fn(s, x) { s + files_bytes(items(Some(x), "files")) })
    [
      ("messages", "android-settings.files.messages", messages),
      ("opened", "android-settings.files.chatFiles", opened),
      ("drive", "android-settings.files.drive", kept.drive.get()),
      ("loose", "android-settings.files.looseShort", files_bytes(kept.loose.get())),
    ].mapi(fn(i, p) { (i, p.0, p.1, p.2) }).filter(fn(p) { p.3 > 0.0 })
  }
  let total = fn() { kept_total(kept.chats.get().unwrap_or([])) }
  @sf.group_node(b, fn(g) {
    @sf.block_node(g, fn(k) {
      @sf.words_node(k, fn() { size_words(total()) }, fn() { kept_figure }) |> ignore
      k.show(fn() { total() > 0.0 }, fn(s) { kept_bar_node(s, parts, total) })
      // the parts two by two under it, each its dot, its name over its size (as wide as half the card: what is in
      // them a word or two); the drives' (let go when asked) and the files of no chat known (gone into) pressed
      k.box(fn(grid) {
        @sf.style_node(grid, fn() { kept_parts_grid })
        // (by what once: each cell reads its own part, told only as that one changes)
        let by_what = grid.keyed_by(parts, fn(p) { p.1 })
        grid.each(fn() { Array::makei((parts().length() + 1) / 2, fn(i) { i }) }, fn(i) { i }, fn(line, i) {
          @sf.style_node(line, fn() { kept_parts_line })
          // (a line's two, the second of an odd last line room alone, as wide as one)
          let two = fn() {
            let ps = parts()
            let at = i.get() * 2
            [at, at + 1].map(fn(j) { if j < ps.length() { ps[j].1 } else { "" } })
          }
          line.each(two, fn(w) { w }, fn(cell, what) {
            let what = what.untracked()
            let part = fn() { by_what.get(what) }
            let goes = what == "drive" || what == "loose"
            // (as high as a press's room at least, the native input's)
            @sf.style_node(cell, fn() { (if goes { kept_part_lit } else { kept_part_room }).then(@sf.row_least_h()) }, in_row=true)
            // (round as a row's ripple is, its ground lit under the hand)
            cell.radius(Is(@sf.row_corner)) |> ignore
            if what == "" {
              return
            }
            if goes {
              @sf.rippled_node(cell, fn() { kept_part_press(core, what) }, @sf.row_corner, fn() {
                tr(part().map(fn(p) { p.2 }).unwrap_or(""))
              })
            }
            cell.box(fn(head) {
              @sf.style_node(head, fn() { kept_part_head })
              // (its dot on its name's first line, its name onto lines where it has not the room)
              @sf.first_line_node(head, Meta, leading=L5, fn(l) {
                l.box(fn(d) {
                  @sf.style_node(d, fn() { kept_dot })
                  d.ground(By(fn() { @sf.usage_series(part().map(fn(p) { p.0 }).unwrap_or(0)) })) |> ignore
                })
                |> ignore
              })
              |> ignore
              @sf.words_node(head, fn() { tr(part().map(fn(p) { p.2 }).unwrap_or("")) }, fn() { kept_part_name }) |> ignore
            })
            |> ignore
            cell.box(fn(z) {
              @sf.style_node(z, fn() { kept_part_size_room })
              @sf.words_node(z, fn() { size_words(part().map(fn(p) { p.3 }).unwrap_or(0.0)) }, fn() { kept_part_size }) |> ignore
            })
            |> ignore
          })
        })
      })
      |> ignore
    })
  })
}

///|
/// A part of what is kept pressed: the drives' files let go of once asked; the files of no chat known gone into.
fn kept_part_press(core : Core, what : String) -> Unit {
  if what == "drive" {
    confirm(tr("android-settings.files.drive"), tr("android-settings.files.drive.text"), tr("android-settings.files.clear.action"), danger=true, fn() {
      (core.call)("drive.kept.clear", obj([]), fn(_) { kept_again() })
    })
  } else {
    (core.push)(KeptChat("", -1))
  }
}

///|
/// The parts' lines, one under the other.
// kept across runs: a value (no field of it changes)
let kept_parts_grid : @ui.Style = @ui.css("w=Full")

///|
/// A line of two parts, side by side.
// kept across runs: a value (no field of it changes)
let kept_parts_line : @ui.Style = @ui.css("row w=Full")

///|
/// A part: half the line, its words a list's row's room in, its dot and name over its size.
// kept across runs: a value (no field of it changes)
let kept_part_room : @ui.Style = @ui.css("gap=SPx").then(@ui.style(w=@sf.grow, p=@sf.list_words_room))

///|
/// A part pressed (the drives', the files of no chat known): lit under the hand.
// kept across runs: a value (no field of it changes)
let kept_part_lit : @ui.Style = kept_part_room.then(@ui.css("hovered{bg=Hover}"))

///|
/// A part's dot and name on a line, 8 apart.
// kept across runs: a value (no field of it changes)
let kept_part_head : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let kept_part_name : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=@sf.grow)

///|
/// A part's size, under its name, where its name starts (past its dot).
// kept across runs: a value (no field of it changes)
let kept_part_size_room : @ui.Style = @ui.css("w=Full pl=S4")

///|
// kept across runs: a value (no field of it changes)
let kept_part_size : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Medium, color=Fg, wrap=false, w=Full)

///|
/// The bar of what all that is kept (`total()`) is made of (`parts()`: each its colour's place, what, and size), its
/// parts side by side, 1 apart, as wide as what each keeps (at least kept_bar_least of it), round at its two ends.
fn kept_bar_node(s : @view.View, parts : () -> Array[(Int, String, String, Double)], total : () -> Double) -> Unit {
  s.box(fn(bar) {
    @sf.style_node(bar, fn() { kept_bar_track })
    // (by what once: each part's piece reads its own part, told only as that one changes, and where it is as they move)
    let by_what = bar.keyed_by(parts, fn(p) { p.1 })
    bar.each(fn() { by_what.keys() }, fn(w) { w }, fn(seg, what) {
      let what = what.untracked()
      let part = fn() { by_what.get(what) }
      let r = kept_bar_h / 2.0
      seg
      .height(Is(Some(kept_bar_h)))
      .basis(Is(Some(0.0)))
      .grow(By(fn() { @cmp.maximum(kept_bar_least, part().map(fn(p) { p.3 }).unwrap_or(0.0) / dmax(1.0, total())) }))
      .ground(By(fn() { @sf.usage_series(part().map(fn(p) { p.0 }).unwrap_or(0)) }))
      // (round at the bar's ends alone: the first's start, the last's end)
      .corners(By(fn() {
        let ks = by_what.keys()
        if ks.contains(what) {
          let first = ks[0] == what
          let last = ks[ks.length() - 1] == what
          Some((if first { r } else { 0.0 }, if last { r } else { 0.0 }, if last { r } else { 0.0 }, if first { r } else { 0.0 }))
        } else {
          None
        }
      }))
      |> ignore
    })
  })
  |> ignore
}

///|
/// A chat on 本机缓存 (kept_chat_row's, as a node; `xv` as it is now) in `g`: what it is called, what it keeps of its
/// messages and files under it, all it keeps at its end; gone into.
fn kept_chat_row_node(g : @view.View, core : Core, xv : () -> Json?) -> Unit {
  @sf.link_row_node(
    g,
    fn() {
      match text(xv(), "title") {
        "" => fill("android-settings.files.untitled", [("n", count(xv(), "thread").to_string())])
        s => s
      }
    },
    fn() {
      let x = @signals.untracked(xv)
      (core.push)(KeptChat(text(x, "station"), count(x, "thread")))
    },
    // (its messages alone: the size at its end says it)
    note=fn() {
      let files = items(xv(), "files")
      if files.length() == 0 {
        ""
      } else {
        fill("android-settings.files.chat.both", [
          ("size", size_words(number(xv(), "bytes"))),
          ("n", files.length().to_string()),
          ("files", size_words(files_bytes(files))),
        ])
      }
    },
    value=fn() {
      match xv() {
        Some(x) => size_words(chat_bytes(x))
        None => ""
      }
    },
  )
}

///|
/// What this device keeps while it is read (kept_sample's, as nodes), in its bones: made-up rows of sizes on their card
/// (`chats`: what all is made of, then the chats under their heading; else a chat's messages, then its files).
fn kept_sample_node(s : @view.View, chats : Bool) -> Unit {
  let row = fn(g : @view.View, title : Int, sub : Int) {
    @sf.link_row_node(g, fn() { @sf.sample_words(title) }, fn() {  }, note=fn() { if sub > 0 { @sf.sample_words(sub) } else { "" } }, value=fn() {
      "1 B"
    }, goes=false)
  }
  @sf.group_node(s, fn(g) {
    if chats {
      row(g, 6, 0)
      row(g, 8, 0)
      row(g, 5, 0)
    } else {
      row(g, 4, 14)
    }
  })
  @sf.section_heading_node(s, fn() { @sf.sample_words(4) })
  @sf.group_node(s, fn(g) {
    row(g, 8, 16)
    row(g, 6, 12)
    row(g, 10, 18)
    row(g, 7, 14)
  })
}

///|
/// A chat's (KeptChatScreen) made once as nodes in node `v`, the chat `thread` on `station` (station "": the files of no
/// chat known): what is kept of its messages, deleted when asked (`cache.clear`: read again from its station when it is
/// opened), and the files opened in it, a block each, each with its bin; or all of it at once.
pub fn kept_chat_node(
  v : @view.View,
  core : Core,
  station : String,
  thread : Int,
  on_back~ : () -> Unit,
  frame~ : () -> @sf.PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  kept_reads_node(v, core)
  let loose = station == ""
  let chat = fn() {
    match kept.chats.get() {
      Some(a) if !loose => a.iter().find_first(fn(x) { text(Some(x), "station") == station && count(Some(x), "thread") == thread })
      _ => None
    }
  }
  let files = fn() { if loose { kept.loose.get() } else { items(chat(), "files") } }
  let messages = fn() { number(chat(), "bytes") }
  let file_key = fn(f : Json) { "file/" + text(Some(f), "station") + "/" + text(Some(f), "key") + "/" + text(Some(f), "name") }
  @sf.page_node(
    v,
    fn() { if loose { tr("android-settings.files.loose") } else { text(chat(), "title") } },
    on_back~,
    frame~,
    said?,
    width?,
    tips?,
    fn() {
      guard kept.chats.get() is Some(_) else { return ["waiting"] }
      let out : Array[String] = []
      if chat() is Some(_) {
        out.push("messages")
      }
      if files().length() > 0 {
        out.push("files")
        for f in files() {
          out.push(file_key(f))
        }
      }
      if messages() + files_bytes(files()) > 0.0 {
        out.push("clear")
      }
      out
    },
    fn(b, key) {
      match key {
        "waiting" => @sf.waiting_node(b, fn(s) { kept_sample_node(s, false) })
        "messages" =>
          @sf.group_node(b, fn(g) {
            @sf.link_row_node(
              g,
              fn() { tr("android-settings.files.messages") },
              fn() {
                if @signals.untracked(messages) > 0.0 {
                  confirm(tr("android-settings.files.messages"), tr("android-settings.files.messages.clear"), tr("android-settings.files.clear.action"), danger=true, fn() {
                    (core.call)("cache.clear", obj([("station", str(station)), ("thread", Json::number(thread.to_double()))]), fn(_) { kept_again() })
                  })
                }
              },
              note=fn() { tr("android-settings.files.messages.text") },
              value=fn() { size_words(messages()) },
              chevron=false,
            )
          })
        "files" => {
          let title = fn() { tr("android-settings.files.files") }
          let total = fn() { fill("android-settings.files.filesTotal", [("n", files().length().to_string()), ("size", size_words(files_bytes(files())))]) }
          @sf.section_heading_node(b, title, trailing=total)
        }
        "clear" =>
          @sf.group_node(b, fn(g) {
            @sf.link_row_node(
              g,
              fn() { tr("android-settings.files.clearChat") },
              fn() {
                let all = @signals.untracked(fn() { messages() + files_bytes(files()) })
                let had = @signals.untracked(chat)
                let fs = @signals.untracked(files)
                confirm(tr("android-settings.files.clearChat"), fill("android-settings.files.clearChat.text", [("size", size_words(all))]), tr("android-settings.files.clear.action"), danger=true, fn() {
                  match had {
                    Some(_) =>
                      (core.call)("cache.clear", obj([("station", str(station)), ("thread", Json::number(thread.to_double()))]), fn(_) { kept_again() })
                    None => kept_files_clear(core, fs)
                  }
                })
              },
              danger=true,
              chevron=false,
            )
          })
        k => {
          let last : Ref[(Int, Json)?] = Ref(None)
          let now = fn() {
            let all = files()
            match all.search_by(fn(f) { file_key(f) == k }) {
              Some(i) => {
                last.val = Some((i, all[i]))
                last.val
              }
              None => last.val
            }
          }
          guard @signals.untracked(now) is Some(_) else { return }
          b.grow(Is(1.0)) |> ignore
          @sf.card_piece_node(b, fn() {
            match now() {
              Some((i, _)) => @sf.card_piece_of(i, files().length())
              None => @sf.CardPiece::CardWhole
            }
          }, wide_group=true, fn(g) {
            kept_file_row_node(g, core, if loose { "" } else { station }, fn() { now().map(fn(x) { x.1 }) })
          })
        }
      }
    },
  )
}

///|
/// A file kept (KeptChatScreen's row, kept_file_row's as a node; `fv` as it is now) in `g`: its name, how much and when
/// it was last opened under it (未下载完成 when only a part of it came), deleted by its bin at its end (`station`: its
/// chat's, "" the file's own).
fn kept_file_row_node(g : @view.View, core : Core, station : String, fv : () -> Json?) -> Unit {
  let at = fn() { if station == "" { text(fv(), "station") } else { station } }
  @sf.link_row_node(
    g,
    fn() { text(fv(), "name") },
    fn() {  },
    note=fn() {
      let bytes = number(fv(), "bytes")
      if bytes < number(fv(), "size") {
        fill("android-settings.files.partial", [("size", size_words(bytes))])
      } else {
        fill("android-settings.files.meta", [("size", size_words(bytes)), ("opened", since_words((core.now)(), number(fv(), "opened")))])
      }
    },
    goes=false,
    // (its bin, done at its end on its name's line (row_control_node), raising it no higher: no ground or corner of its
    // own, pressed or not, so none stands round in its card's corner where no circle is concentric with it; its icon
    // the text's ink under the hand)
    control=fn(t) {
      @sf.icon_button_node(
        t,
        "trash",
        fn() { tr("android-settings.files.clear.action") + "「" + text(fv(), "name") + "」" },
        fn() {
          match @signals.untracked(fv) {
            Some(f) => kept_file_clear(core, @signals.untracked(at), f)
            None => ()
          }
        },
        size=kept_bin_side,
        icon_size=kept_bin_icon,
        grounded=false,
      )
      .lies_along(Is(Middle))
      |> ignore
    },
  )
}

///|
/// The bar's height (kept_bar's h=S2), round at its ends.
let kept_bar_h : Double = 8.0

///|
/// The bar's track under its parts (kept_bar's, cut by nothing: its parts round at its ends themselves), 1 apart.
// kept across runs: a value (no field of it changes)
let kept_bar_track : @ui.Style = @ui.css("row w=Full h=S2 gap=SPx radius=Full bg=TintStrong")

///|
/// A kept file's bin: its 18 icon muted in a 36 square (kept_bin's w=S9 h=S9).
let kept_bin_icon : Double = 18.0

///|
let kept_bin_side : Double = 36.0

///|
/// 后台下载 (网络与同步's, src/sfpages network.mbt) as a card in node `v`: whether what was opened and let go goes on
/// coming (prefs `fillOff`), and while it does, how big a file is brought whole up to (prefs `fillMax`). What it brings
/// now is 本机缓存's (kept_keys' "going").
pub fn fill_group_node(v : @view.View, core : Core) -> Unit {
  let set = fn(name : String, value : Json) { (core.call)("prefs.set", obj([(name, value)]), answer_unread) }
  // (not a card of words: its pressed row's corner follows the group's, as it did on 本机缓存)
  @sf.group_node(v, fn(g) {
    // (the library's switch row, as every setting's)
    @sf.switch_row_node(
      g,
      fn() { tr("android-settings.files.fill.on") },
      fn() { fill_on(core) },
      fn(now) { set("fillOff", if now { Json::null() } else { Json::boolean(true) }) },
      note=fn() { tr("android-settings.files.fill.on.sub") },
    )
    g.show(fn() { fill_on(core) }, fn(s) {
      @sf.link_row_opens_node(
        s,
        fn() { tr("android-settings.files.fill.max") },
        fn(row) {
          let most = fill_most(core)
          @sf.pick(
            tr("android-settings.files.fill.max"),
            fill_sizes.map(fn(n) { @sf.choice(n.to_string(), fill_size_said(n)) }),
            most.to_string(),
            fn(k) {
              let n = fill_sizes.search_by(fn(x) { x.to_string() == k }).map(fn(i) { fill_sizes[i] }).unwrap_or(fill_sizes[0])
              set("fillMax", if n == fill_sizes[0] { Json::null() } else { Json::number(n) })
            },
            from=Node(row),
          )
        },
        note=fn() { tr("android-settings.files.fill.max.sub") },
        value=fn() { fill_size_said(fill_most(core)) },
      )
    })
  })
}
