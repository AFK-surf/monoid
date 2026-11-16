// Home's chats as a board (sfbase's board.mbt) made once as nodes: on the page's own paper, no frame round a column,
// its title standing on the paper and its cards under it; a card the chat's title, where it stands now, and where it
// runs, who and what is in it. Wide (720 and over) every column side by side under the board's bar (列表 | 看板, its
// filter, how it is grouped, 新待办), going sideways where they have not the room; a card pressed opens its chat beside
// the board at 960 and over (the shell's, `beside`), else as its page. Narrow a column at a time under chips choosing
// it, the columns on a track a finger swipes across, no card dragged. A card goes to another column as its chat goes
// on (its node flies there: View::shared), never because it is dragged: dragged (wide), a draft starts where 进行中
// takes it, a chat goes to the archive where the archive's place takes it, nothing else lights up to take it; a draft
// dragged goes to be deleted where the board's foot takes it. What the board
// shows and keeps is the workspace's in view, as this device keeps it (sfbase's board.mbt): its drafts, how it is
// grouped, the stations a draft may go to (its stations' rows: none made up).

///|
/// What a column shows: a draft of 待派发's or a chat's card, by its key.
#derive(Eq, Hash)
priv enum BoardKey {
  DraftKey(String)
  ChatKey(String)
}

///|
/// A card being dragged: which, the words it shows, where in the card it was taken (where the pointer is now apart, in
/// BoardOwn's `drag_xy`: what moves with the pointer reads that alone, the cards what is dragged alone).
#derive(Eq)
priv struct BoardDrag {
  key : BoardKey
  title : String
  said : String
  dx : Double
  dy : Double
  w : Double
  ox : Double
  oy : Double
}

///|
/// The board's own: the card dragged, the place under it that takes it ("run", "archive", "" none), the columns' nodes by
/// their key and the archive's place (where a drop lands), the field 新待办 is written in, the station it goes to.
priv struct BoardOwn {
  src : Source
  /// the workspace in view ("" none), and how its board is grouped
  ws : () -> String
  group : () -> String
  drag : @signals.Signal[BoardDrag?]
  /// where the pointer is in the window while a card is dragged: told at each move, read by the card in hand alone
  drag_xy : @signals.Signal[(Double, Double)]
  /// whether a card is the one dragged, the one picked (its chat beside the board), read by key: a card told only as it
  /// comes to be so or stops being so (View::selected)
  mut dragged : (BoardKey) -> Bool
  mut picked : (String) -> Bool
  over : @signals.Signal[String]
  /// whether the place under the card in hand is the one of key (a column's, "archive"), read by key as `dragged` is
  mut over_is : (String) -> Bool
  lanes : Map[String, @view.View]
  mut archive : @view.View?
  root : @view.View?
  mut side : () -> Bool
  /// the columns brought sideways so that column `key`'s shows whole (beside the chat as it opens), "" the first
  mut reveal : (String) -> Unit
  /// the columns put back to their start (another grouping)
  mut to_start : () -> Unit
  /// a draft started (let go over 进行中, or its 开始 pressed): its key, where its card was in the window then, and
  /// whether it was lifted off the board (dragged): its chat's card flies in from there as it comes, once
  mut start_from : (String, (Double, Double, Double, Double), Bool)?
  /// a draft just written: its key and where the card it was written in was, which its card grows from as it comes, once
  mut added_from : (String, (Double, Double, Double, Double))?
  /// how many times the room the line to write a draft in stands in was put away by what was written in it (not
  /// closed: let go at once, its draft come in its place, and made anew closed)
  room_made : @signals.Signal[Int]
  /// the stations a draft may go to (the workspace's), the one chosen for the next ("" none chosen: the first)
  stations : () -> Array[@sf.StationChoice]
  /// the chats and the stations by their keys (View::keyed_by): a card reads its own, told only as that one changes,
  /// never as another does
  items_by : @signals.KeyedList[String, ChatItem]
  /// the drafts by their ids, worked out as they change, in the same change: a draft started or deleted is gone from its
  /// card as the card leaves (a keyed list follows its source a reaction after, the card leaving with its words then);
  /// the device's own few, read by the drafts' cards alone
  drafts_by : () -> Map[String, @sfbase.BoardDraft]
  stations_by : @signals.KeyedList[String, @sf.StationChoice]
  /// the viewer as the board names them among the people (by person)
  me : () -> String
  /// the columns the board shows now (board_columns', its empty ones left out where 显示空列 is off), and the cards of
  /// each by its key (board_cards'), each worked out once for all that reads it, told only as it comes out otherwise
  mut columns : () -> Array[(String, String)]
  mut cards_of : (String) -> Array[BoardKey]
  field : @ui.Field
  station : @signals.Signal[String]
  /// 已归档 chosen in the board's filter's menu (the frame's: its page, or its list in the board's place)
  archived : () -> Unit
}

///|
/// The station the next draft goes to: the one chosen where it is one of the workspace's, else its first ("" none).
fn board_station_now(own : BoardOwn) -> String {
  let s = own.station.get()
  if s != "" && own.stations_by.get(s) is Some(_) {
    s
  } else {
    own.stations_by.keys().get(0).unwrap_or("")
  }
}

///|
/// 待派发's line to write in opened, where the workspace has a station for a draft to go to; else why not said.
fn board_open_add(own : BoardOwn) -> Bool {
  if @signals.untracked(own.stations).is_empty() {
    @sfbase.toast_later(@sf.t("web-main.board.no_station"))
    false
  } else {
    @sfbase.board_adding.set(true)
    true
  }
}

///|
/// The board's words for what Home's list has none for yet.
fn board_words(key : String) -> String {
  match key {
    "list" => @sf.t("web-main.board.list")
    "board" => @sf.t("web-main.board.board")
    "by-state" => @sf.t("web-main.board.by_state")
    "by-station" => @sf.t("web-main.board.by_station")
    "by-person" => @sf.t("web-main.board.by_person")
    "display" => @sf.t("web-main.board.display")
    "group-by" => @sf.t("web-main.board.group_by")
    "show-empty" => @sf.t("web-main.board.show_empty")
    "new" => @sf.t("web-main.board.new")
    "new-here" => @sf.t("web-main.board.new_here")
    "add" => @sf.t("web-main.board.add")
    "cancel" => @sf.t("web-main.board.cancel")
    "goes-on" => @sf.t("web-main.board.goes_on")
    "start" => @sf.t("web-main.board.start")
    "start-now" => @sf.t("web-main.board.start_now")
    "delete" => @sf.t("web-main.board.delete")
    "archive" => @sf.t("web-main.board.archive")
    "drop-archive" => @sf.t("web-main.board.drop_archive")
    "drag-archive" => @sf.t("web-main.board.drag_archive")
    "drop-delete" => @sf.t("web-main.board.drop_delete")
    "drag-delete" => @sf.t("web-main.board.drag_delete")
    "drop-start" => @sf.t("web-main.board.drop_start")
    "placeholder" => @sf.t("web-main.board.placeholder")
    "empty" => @sf.t("web-main.board.empty")
    "empty-draft" => @sf.t("web-main.board.empty_draft")
    "pinned" => @sf.t("web-main.board.pinned")
    _ => key
  }
}

///|
/// How wide a column is at least, and the room between columns and round the board.
let board_col_least : Double = 252.0

///|
let board_col_most : Double = 336.0

///|
let board_gap : Double = 16.0

///|
let board_pad : Double = 16.0

///|
/// How far in from its end the board's own bar keeps what stands there: past the arc of a window's corner it may stand
/// in (16 round).
let board_bar_end : Double = 20.0

///|
/// How wide the board's foot's place to let a card go is at least: its longer words' (拖到这里归档) and its room.
let board_drop_place_w : Double = 240.0

///|
/// How wide the chat open beside the board is, and from what width the board has it beside it.
pub let board_beside_w : Double = 460.0

///|
pub let board_beside_from : Double = 1040.0

///|
/// How tall the board's bar is (the pane's bars': @sf.wide_bar_h's 50).
let board_bar_h : Double = 50.0

///|
/// The card's padding, and its corner: a card's (@sf.card_corner, 26: the surface of a face 20 across 16 in, so what
/// stands in its corners is concentric with them), what stands in its top end corner (a round key 28 across, as far in
/// from both its edges as its corner allows) worked out of it.
let card_pad : Double = 16.0

///|
let card_key : Double = 28.0

///|
fn card_key_in() -> Double {
  @sf.card_corner - card_key / 2.0
}

///|
/// The lanes the board shows now by how it is grouped, each its key and words: by state the five; by station each
/// station a draft or a chat is on; by person each one in a chat.
fn board_columns(own : BoardOwn, items : Array[ChatItem], drafts : Array[@sfbase.BoardDraft]) -> Array[(String, String)] {
  match (own.group)() {
    "station" => {
      let cols : Array[(String, String)] = []
      let add = fn(st : String, name : String) {
        if st != "" && !cols.iter().any(fn(c) { c.0 == "station:" + st }) {
          cols.push(("station:" + st, if name == "" { st } else { name }))
        }
      }
      // (the workspace's stations as their rows name them, then any a draft or a chat is on besides)
      for c in (own.stations)() {
        add(c.station, c.name)
      }
      for d in drafts {
        add(d.station, d.station_name)
      }
      for i in items {
        add(i.station, i.station_name)
      }
      cols
    }
    "person" => {
      let cols : Array[(String, String)] = []
      let add = fn(n : String) {
        if !cols.iter().any(fn(c) { c.0 == "person:" + n }) {
          cols.push(("person:" + n, n))
        }
      }
      // (the viewer first)
      let me = (own.me)()
      add(me)
      for i in items {
        for n in @sfbase.board_people_of(i, me) {
          add(n)
        }
      }
      cols
    }
    _ => @sfbase.board_lanes.map(fn(l) { (l, @sfbase.board_lane_words(l)) })
  }
}

///|
/// Whether column `col` (board_columns') lists chat `i`: 待派发 none; by station those on it; by person those of its
/// one (`me` the viewer as the board names them, asked only there); by state those standing in it.
fn board_holds(col : String, i : ChatItem, me : () -> String) -> Bool {
  if col == "draft" {
    false
  } else if col.has_prefix("station:") {
    i.station == col.exact_view(start=8).to_owned()
  } else if col.has_prefix("person:") {
    @sfbase.board_people_of(i, me()).contains(col.exact_view(start=7).to_owned())
  } else {
    @sfbase.board_lane_of(i) == col
  }
}

///|
/// The cards of column `col` (board_columns'), in order: 待派发's drafts, then its chats (pinned first).
fn board_cards(
  col : String,
  items : Array[ChatItem],
  drafts : Array[@sfbase.BoardDraft],
  me : () -> String,
) -> Array[BoardKey] {
  let out : Array[BoardKey] = []
  if col == "draft" {
    for d in drafts {
      out.push(DraftKey(d.id))
    }
  } else if col.has_prefix("station:") {
    let st = col.exact_view(start=8).to_owned()
    for d in drafts {
      if d.station == st {
        out.push(DraftKey(d.id))
      }
    }
  } else if col.has_prefix("person:") {
    if col.exact_view(start=7).to_owned() == me() {
      for d in drafts {
        out.push(DraftKey(d.id))
      }
    }
  }
  let chats = items.filter(fn(i) { board_holds(col, i, me) })
  for i in chats {
    if i.pinned == Some(true) {
      out.push(ChatKey(@sfbase.row_name(i)))
    }
  }
  for i in chats {
    if i.pinned != Some(true) {
      out.push(ChatKey(@sfbase.row_name(i)))
    }
  }
  out
}

///|
/// Home's chats as the board in `v`, of the workspace in view (`workspace`): `width` how wide it is given (its
/// arrangement's), `top` the room over it (a bar of the shell's over it: none where the board has its own), `foot` the
/// room under it, `bar` whether it has its own bar (wide: its own; narrow, under Home's), `beside` the chat of a card
/// pressed made beside it (wide and `board_beside_from` wide: the shell's; none: the card opens its chat's page),
/// `archive` what 已归档 in its bar's filter's menu opens (the archive's page where none is said).
pub fn board_node(
  v : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  workspace : () -> Workspace?,
  width : () -> Double,
  top? : () -> Double = fn() { 0.0 },
  foot? : () -> Double = fn() { 0.0 },
  beside? : (@view.View, ChatRef) -> Unit,
  ground? : () -> Int64 = fn() { @sf.theme().p.bg },
  columns? : Bool = beside is Some(_),
  bar_frame? : (@view.View, (@view.View) -> Unit) -> Unit,
  archive? : () -> Unit = fn() { open_page(Archived) },
) -> Unit {
  let ws = fn() { workspace().map(fn(w) { w.id }).unwrap_or("") }
  // (the chats, the drafts and the workspace's stations a draft may go to, as their rows say them: each worked out once
  // for all that reads it, told only as it comes out otherwise)
  let items_now = @signals.computed(fn(_) {
    match workspace() {
      Some(w) => @sfbase.board_items(src, w.id)
      None => []
    }
  })
  let items = fn() { items_now.get() }
  let drafts_now = @signals.computed(fn(_) { @sfbase.board_drafts_of(src, ws()) })
  let drafts = fn() { drafts_now.get() }
  let drafts_map = @signals.computed(fn(_) { Map::from_array(drafts().map(fn(d) { (d.id, d) })) })
  let stations_now = @signals.computed(fn(_) {
    let rows = match workspace() {
      Some(w) =>
        match @sfbase.station_rows(src, w.id).value {
          Some(Array(a)) => a
          _ => []
        }
      None => []
    }
    rows
    .map(fn(r) -> @sf.StationChoice {
      let one = Some(r)
      { station: text(one, "station"), name: text(one, "name"), emoji: text(one, "emoji"), icon: text(one, "icon") }
    })
    .filter(fn(c) { c.station != "" && c.name != "" })
  })
  let me_now = @signals.computed(fn(_) { @sfbase.board_me_of(items()) })
  let own : BoardOwn = {
    src,
    ws,
    group: fn() { @sfbase.board_group_of(src, ws()) },
    drag: @signals.signal(None),
    drag_xy: @signals.signal((0.0, 0.0)),
    dragged: fn(_) { false },
    picked: fn(_) { false },
    over: @signals.signal(""),
    over_is: fn(_) { false },
    lanes: Map([]),
    archive: None,
    root: Some(v),
    side: fn() { false },
    reveal: fn(_) {  },
    to_start: fn() {  },
    start_from: None,
    added_from: None,
    room_made: @signals.signal(0),
    stations: fn() { stations_now.get() },
    items_by: v.keyed_by(items, @sfbase.row_name),
    drafts_by: fn() { drafts_map.get() },
    stations_by: v.keyed_by(fn() { stations_now.get() }, fn(c) { c.station }),
    me: fn() { me_now.get() },
    columns: fn() { [] },
    cards_of: fn(_) { [] },
    field: @ui.Field::new(),
    station: @signals.signal(""),
    archived: archive,
  }
  let raw_columns_now = @signals.computed(fn(_) { board_columns(own, items(), drafts()) })
  // (every column's cards and every state's (a narrow board's chips count them whatever the grouping), worked out
  // together as a chat or a draft changes; a map made anew each time: each column's own computed says whether its
  // cards came out otherwise)
  let cards_now = @signals.computed_ref(fn(_) {
    let all = items()
    let ds = drafts()
    let out : Map[String, Array[BoardKey]] = Map([])
    for c in raw_columns_now.get() {
      out[c.0] = board_cards(c.0, all, ds, own.me)
    }
    for l in @sfbase.board_lanes {
      if !out.contains(l) {
        out[l] = board_cards(l, all, ds, own.me)
      }
    }
    out
  })
  own.cards_of = fn(key) { cards_now.get().get(key).unwrap_or([]) }
  // (its empty columns left out where the workspace's board says so (显示空列 off), but 待派发 while a draft is being
  // written in it: 新待办 brings it in; shown, as by default, the cards not read here, so a chat's change tells
  // nothing to the columns)
  let columns_now = @signals.computed(fn(_) {
    let all = raw_columns_now.get()
    if @sfbase.board_show_empty_of(own.src, (own.ws)()) {
      all
    } else {
      let adding = @sfbase.board_adding.get()
      let cards = cards_now.get()
      all.filter(fn(c) { (c.0 == "draft" && adding) || cards.get(c.0).map(fn(k) { !k.is_empty() }).unwrap_or(false) })
    }
  })
  own.columns = fn() { columns_now.get() }
  own.dragged = v.selected(fn() { own.drag.get().map(fn(g) { g.key }) })
  own.over_is = v.selected(fn() {
    match own.over.get() {
      "" => None
      o => Some(o)
    }
  })
  // (the chat picked, as the card its row is: looked for only while one is picked)
  own.picked = v.selected(fn() {
    match @sfbase.board_pick.get() {
      Some(p) => items().iter().find_first(fn(i) { @sfbase.row_is(i, p) }).map(@sfbase.row_name)
      None => None
    }
  })
  v.grow(Is(1.0)).min_height(Is(Some(0.0))).ground(By(ground)) |> ignore
  // (the workspace's stations read as long as the board shows, as its opening asked them (sfbase's board_opens): the
  // line to write a draft in, and its choice of a station, whole as it comes, whichever column shows)
  v.reacts(fn() { (own.stations)().length() }, fn(_) {  })
  // (columns side by side under the board's bar in a frame's pane or panel; Home's on a phone a column at a time)
  v.pick(fn() { columns }, fn(p, wide) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))).padding(By(fn() { (0.0, top(), 0.0, foot()) })) |> ignore
    if wide {
      board_wide(p, src, tips, own, width, beside, bar_frame)
    } else {
      board_narrow(p, src, tips, own, width)
    }
  })
  // the card dragged, over all of the board where the pointer has it
  // (let go, gone at once: let go over 进行中, its chat's card flies on from where it was, board_chat_card's)
  let last : Ref[BoardDrag?] = Ref(None)
  v.show(fn() { own.drag.get() is Some(_) }, at_once=true, fn(g) {
    g.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
    g.box(fn(c) {
      let d = fn() {
        match own.drag.get() {
          Some(d) => {
            last.val = Some(d)
            Some(d)
          }
          None => last.val
        }
      }
      c
      .width(By(fn() { d().map(fn(d) { Some(d.w) }).unwrap_or(None) }))
      // (where the pointer has it: the one binding a move of it runs)
      .offset(By(fn() {
        let (x, y) = own.drag_xy.get()
        match d() {
          Some(d) => (x - d.dx - d.ox, y - d.dy - d.oy)
          None => (0.0, 0.0)
        }
      }))
      .ground(By(fn() { @sf.theme().p.card }))
      .radius(Is(@sf.card_corner))
      // (lifted off the board: a hairline round it and a soft shadow under it, the cards at rest have neither)
      .edge(By(fn() { (1.0, @sf.theme().p.line) }))
      .shadow(By(fn() { (24.0, 10.0, @sf.alpha(@sf.theme().p.shadow, 0.28)) }))
      .padding(Is((card_pad, card_pad, card_pad, card_pad)))
      |> ignore
      c.gap(Is(6.0)) |> ignore
      @sf.words_node(c, fn() { d().map(fn(d) { d.title }).unwrap_or("") }, fn() { card_title_look }) |> ignore
      // (where it runs and stands, as on the card; let go over what takes it, what it does there)
      @sf.words_node(c, fn() {
        match own.over.get() {
          "run" => board_words("drop-start")
          "archive" if d().map(fn(d) { d.key is DraftKey(_) }).unwrap_or(false) => board_words("drop-delete")
          "archive" => board_words("drop-archive")
          _ => d().map(fn(d) { d.said }).unwrap_or("")
        }
      }, fn() { if own.over.get() != "" { card_drop_look } else { card_meta_look } }) |> ignore
    })
    |> ignore
  })
}

///|
/// The wide board: its bar over its columns side by side (whole columns where they have not all the room, going
/// sideways to the rest), the archive's place at its foot while a chat's card is dragged; the chat of the card picked
/// beside all of it, the window's whole height, where there is the room. The chat slides in and out from the board's
/// end (a Move as far as it is wide), the columns going from their width to the one they come to over the same way, and
/// the columns brought sideways to where they are to show over it too: one motion, its three parts each worked out of it.
fn board_wide(
  p : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  own : BoardOwn,
  width : () -> Double,
  beside : ((@view.View, ChatRef) -> Unit)?,
  bar_frame : ((@view.View, (@view.View) -> Unit) -> Unit)?,
) -> Unit {
  own.side = fn() { beside is Some(_) && width() >= board_beside_from }
  let split = fn() { beside is Some(_) && width() >= board_beside_from && @sfbase.board_pick.get() is Some(_) }
  let spec = @motion.moved(over=board_beside_w)
  // (how far open the chat beside it is, 0 to 1; the chat it shows, kept as it slides out; the columns' widths it goes
  // between; where the columns are brought sideways from and to, how far along that is)
  let opened = @motion.Way::new(if @signals.untracked(split) { 1.0 } else { 0.0 })
  let shown : @signals.Signal[ChatRef?] = @signals.signal(@signals.untracked(fn() { @sfbase.board_pick.get() }))
  let ends = Ref((0.0, 0.0))
  let glide = @motion.Way::new(1.0)
  let glides = Ref((0.0, 0.0))
  let count = fn() { (own.columns)().length() }
  // (how far along a way is at `t`, from where it set out to where it goes: 1 where it is not going)
  let along = fn(way : @motion.Way, t : Double) -> Double {
    if !way.goes_at(t) {
      return 1.0
    }
    let from = way.value_at(way.starts_at())
    let to = way.target()
    if to == from {
      1.0
    } else {
      (way.value_at(t) - from) / (to - from)
    }
  }
  // (each column's width as the chat beside them has it at `t`: on their way while it slides, else at rest)
  let col_w_at = fn(t : Double, open : Bool) -> Double {
    if opened.goes_at(t) {
      let (from, to) = ends.val
      from + (to - from) * along(opened, t)
    } else {
      board_col_w(width() - (if open { board_beside_w } else { 0.0 }), count())
    }
  }
  p.row(Is(true)) |> ignore
  p.box(fn(left) {
    left.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    match bar_frame {
      // (laid out as the frame lays out a bar where it stands: the tape's page panel's, its ends concentric with the
      // panel's corners)
      Some(frame) => frame(left, fn(bar) { board_bar_items(bar, own, apart=true) })
      None => board_bar(left, own)
    }
    left.box(fn(area) {
      area.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
      let across = @view.Scroll::across()
      // (brought sideways to `to` over the chat's way: drawn moved by what is left of the way, put there as it ends)
      let glide_to = fn(to : Double) {
        let at = area.cause_at()
        let now = across.at(area.tree) + (if glide.goes_at(at) {
          let (f, t) = glides.val
          (t - f) * along(glide, at) - (t - f)
        } else {
          0.0
        })
        // (as far as it goes there once laid out so)
        let to = if to < 0.0 { 0.0 } else { to }
        if (to - now).abs() < 0.5 {
          return
        }
        across.put(now)
        glides.val = (now, to)
        glide.put(0.0)
        glide.go(1.0, spec, at~)
        let end = glide.end()
        area.at_moment(end, fn() { if glide.end() == end { across.put(to) } }) |> ignore
      }
      // (where the columns are to be for column `key`'s to show whole, the chat beside them as it is to be)
      own.reveal = fn(key) {
        let cols = @signals.untracked(own.columns)
        let n = cols.length()
        let i = cols.search_by(fn(c) { c.0 == key }).unwrap_or(0)
        let r = width() - (if @signals.untracked(own.side) && key != "draft" { board_beside_w } else { 0.0 })
        let w = board_col_w(r, n)
        let avail = r - 2.0 * board_pad
        let fits = ((avail + board_gap) / (board_col_least + board_gap)).floor().to_int()
        let shown_n = if fits < 1 { 1 } else if fits > n { n } else { fits }
        let first = if i >= shown_n { i - shown_n + 1 } else { 0 }
        let now = across.at(area.tree)
        let stride = w + board_gap
        // (where it shows whole already, left as it is)
        let first_now = (now / stride).round().to_int()
        let first = if i >= first_now && i < first_now + shown_n && key != "draft" { first_now } else { first }
        glide_to(first.to_double() * stride)
      }
      own.to_start = fn() { across.put(0.0) }
      // (the chat beside them opened or closed: the three set off together, from that moment)
      area.reacts(split, fn(open) {
        let at = area.cause_at()
        ends.val = (col_w_at(at, !open), board_col_w(width() - (if open { board_beside_w } else { 0.0 }), count()))
        if open {
          shown.set(@sfbase.board_pick.untracked())
        }
        opened.go(if open { 1.0 } else { 0.0 }, spec, at~)
        let end = opened.end()
        area.at_moment(end, fn() {
          if opened.end() == end && !@signals.untracked(split) {
            shown.set(None)
          }
        })
        |> ignore
        if !open {
          // (closed: no further than the columns go with the whole width)
          let (_, w) = ends.val
          let n = count().to_double()
          let most = 2.0 * board_pad + n * w + (n - 1.0) * board_gap - width()
          let now = across.at(area.tree)
          if now > most {
            glide_to(if most < 0.0 { 0.0 } else { most })
          }
        }
      }, at_start=false)
      // (another chat picked while it is open: shown in its place)
      area.reacts(fn() { @sfbase.board_pick.get() }, fn(r) { if r is Some(_) { shown.set(r) } }, at_start=false)
      area.scrolls(across, slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(held) {
        held.min_height(Is(Some(0.0))) |> ignore
        held.box(fn(cols) {
          cols
          .row(Is(true))
          .gap(Is(board_gap))
          .padding(Is((board_pad, 4.0, board_pad, board_pad)))
          .min_height(Is(Some(0.0)))
          .grow(Is(1.0))
          // (on the columns' way sideways: what is left of it)
          .offset(By(fn() {
            glide.said()
            let t = cols.drawn_while(fn(at) { glide.goes_at(at) })
            if t == @double.infinity || !glide.goes_at(t) {
              (0.0, 0.0)
            } else {
              let (f, to) = glides.val
              (-(to - f) * along(glide, t), 0.0)
            }
          }))
          |> ignore
          cols.pick(own.group, fn(g, _group) {
            g.row(Is(true)).gap(Is(board_gap)).min_height(Is(Some(0.0))).grow(Is(1.0)) |> ignore
            g.each(
              fn() { (own.columns)() },
              fn(c) { c.0 },
              fn(col, c) {
                let key = @signals.untracked(fn() { c.get().0 })
                col
                .width(By(fn() {
                  opened.said()
                  let t = col.drawn_while(fn(at) { opened.goes_at(at) })
                  if t == @double.infinity || !opened.goes_at(t) {
                    Some(board_col_w(width() - (if split() { board_beside_w } else { 0.0 }), count()))
                  } else {
                    Some(col_w_at(t, split()))
                  }
                }))
                .shrink(Is(0.0))
                |> ignore
                board_column(col, src, tips, own, key, fn() { c.get().1 }, wide=true)
              },
              at_once=true,
            )
          }, at_once=true)
        })
        |> ignore
      })
      |> ignore
      // where a card dragged goes to be archived (a chat's) or deleted (a draft's), at the board's foot while one is
      area.show(fn() { own.drag.get() is Some(_) }, fn(z) {
        z.over(Is(true)).lies_along(Is(End)).lines_up(Is(Some(Middle))).padding(Is((0.0, 0.0, 0.0, 20.0))).presses(Is(false))
        |> ignore
        board_archive_place(z, own)
      })
    })
    |> ignore
  })
  |> ignore
  match beside {
    Some(make) =>
      // (as wide as it is open, what it shows as wide as it is all the way: cut to its room as it slides)
      p.show(fn() { shown.get() is Some(_) }, fn(s) {
        s
        .width(By(fn() { Some(board_beside_w * opened.shown_on(s)) }))
        .shrink(Is(0.0))
        .min_height(Is(Some(0.0)))
        .clips(Is(true))
        |> ignore
        s.box(fn(inner) {
          inner.width(Is(Some(board_beside_w))).grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          inner.pick(fn() { shown.get() }, fn(b, r) {
            b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
            match r {
              Some(r) => make(b, r)
              None => ()
            }
          }, at_once=true)
        })
        |> ignore
      }, at_once=true)
    None => ()
  }
}

///|
/// How wide each of `n` columns is in `room`: as many whole columns as `room` holds at the least, sharing it, at most
/// board_col_most (the rest sideways, never a column cut at the edge of what shows).
fn board_col_w(room : Double, n : Int) -> Double {
  let avail = room - 2.0 * board_pad
  let fits = ((avail + board_gap) / (board_col_least + board_gap)).floor().to_int()
  let shown = if fits < 1 { 1 } else if fits > n { n } else { fits }
  let fit = (avail - board_gap * (shown - 1).to_double()) / shown.to_double()
  // (all of them in the room: at most so wide, at the start; some going sideways: those that show filling it whole, so
  // the next one starts past its edge, never half in it)
  if shown >= n && fit > board_col_most {
    board_col_most
  } else if fit < board_col_least {
    board_col_least
  } else {
    fit
  }
}

///|
/// The archive's place a chat's card is let go on, where a draft's is deleted (board_wide's foot): lit while one is over
/// it.
fn board_archive_place(z : @view.View, own : BoardOwn) -> Unit {
  let draft = fn() { own.drag.get().map(fn(d) { d.key is DraftKey(_) }).unwrap_or(false) }
  z.box(fn(a) {
    own.archive = Some(a)
    a
    .row(Is(true))
    .gap(Is(8.0))
    .lines_up(Is(Some(Middle)))
    .padding(Is((20.0, 12.0, 20.0, 12.0)))
    // (as wide lit as not, its words shorter then: what the pointer is let go over stays under it)
    .min_width(Is(Some(board_drop_place_w)))
    .lies_along(Is(Middle))
    .radius(Is(1.0e6))
    .ground(By(fn() {
      let p = @sf.theme().p
      if (own.over_is)("archive") { p.accent_bg } else { p.neutral_bg }
    }))
    .says(By(fn() { Some(@view.said(Image, label=board_words(if draft() { "delete" } else { "archive" }))) }))
    |> ignore
    a.pick(draft, fn(ic, d) {
    @sf.icon_node(ic, if d { "trash" } else { "archive" }, 16.0, By(fn() {
      if (own.over_is)("archive") { @sf.theme().p.accent_text } else { @sf.theme().p.muted }
    }))
    |> ignore
    }, at_once=true)
    @sf.words_node(a, fn() {
      match ((own.over_is)("archive"), draft()) {
        (true, true) => board_words("drop-delete")
        (true, false) => board_words("drop-archive")
        (false, true) => board_words("drag-delete")
        (false, false) => board_words("drag-archive")
      }
    }, fn() {
      if (own.over_is)("archive") { drop_lit_look } else { drop_look }
    })
    |> ignore
  })
  |> ignore
}

///|
/// The wide board's bar: all it holds at its end (board_bar_items'), its start left empty.
fn board_bar(p : @view.View, own : BoardOwn) -> Unit {
  p.box(fn(bar) {
    bar
    .row(Is(true))
    .height(Is(Some(board_bar_h)))
    .shrink(Is(0.0))
    .gap(Is(10.0))
    .lines_up(Is(Some(Middle)))
    // (its end clear of the window's corner where it stands in it: the sidebar closed beside the board)
    .padding(Is((board_pad, 0.0, board_bar_end, 0.0)))
    |> ignore
    board_bar_items(bar, own, apart=true)
  })
  |> ignore
}

///|
/// What the board's bar holds, in `bar` (its own, or a frame's bar it is given: the tape's page's), all at its end, as
/// Linear's board has it: 列表 (back to the list) and the filter, quiet keys; 显示, what opens how the board is shown
/// (board_display); 新待办. The filter and 显示 say on themselves what is chosen otherwise than as the board starts
/// (我参与的; 按机器 or 按成员, the empty columns left out). `apart`: the rest of the bar left empty before them.
fn board_bar_items(bar : @view.View, own : BoardOwn, apart~ : Bool) -> Unit {
  bar.box(fn(row) {
    // (新待办 the one to leave where the bar has not the room for all of it: 待派发's ＋ writes one as well)
    row.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))).fits(Is(true)) |> ignore
    // (as wide as the bar gives it, not as all it holds: what has not the room then leaves)
    if apart {
      row.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      row.box(fn(g) { g.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore }) |> ignore
    }
    // (as tall as what stands beside it in the bar: a button's)
    @sf.icon_button_node(row, "list", fn() { board_words("list") }, fn() { @sfbase.board_set(own.src, false) }, size=@sf.button_h)
    |> ignore
    board_filter_key(row, own)
    board_display_key(row, own)
    @sf.button_node(row, fn() { board_words("new") }, fn() {
      if board_open_add(own) {
        if @signals.untracked(own.group) != "state" {
          @sfbase.set_board_group(own.src, @signals.untracked(own.ws), "state")
        }
        // (待派发 the first column: brought into sight where the columns had gone sideways)
        (own.reveal)("draft")
      }
    }, icon="plus")
    .drops(Is(1))
    |> ignore
  })
  |> ignore
}

///|
/// The board's filter, as the sidebar's filter is: its menu the board's (filter_menu's `in_board`: 全部会话 or 我参与的 on
/// it; 已隐藏 the list's, 已归档 the frame's, BoardOwn's `archived`). A quiet key while it shows all of them; narrowed to
/// 我参与的, a button saying so.
fn board_filter_key(bar : @view.View, own : BoardOwn) -> Unit {
  let src = own.src
  let open = fn(k : @view.View) {
    guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return }
    let (x, y, wd, h) = k.placed_window_now()
    filter_menu(At(x, y, wd, h), @sfbase.board_filter_of(src, w.id), fn(f) { board_filter_go(src, w, f, own.archived) }, in_board=true)
  }
  bar.pick(fn() { @sfbase.board_filter_of(src, (own.ws)()) == "mine" }, at_once=true, fn(p, mine) {
    if mine {
      @sf.button_opens_node(p, fn() { @sf.t("web-main.filter.chats.mine") }, open, icon="filter") |> ignore
    } else {
      let key : Ref[@view.View?] = Ref(None)
      key.val = Some(
        @sf.icon_button_node(
          p,
          "filter",
          fn() { @sf.t("web-main.filter.chats.named", args=[("named", @sf.t("web-main.filter.all"))]) },
          fn() {
            if key.val is Some(k) {
              open(k)
            }
          },
          size=@sf.button_h,
        ),
      )
    }
  })
}

///|
/// 显示: what opens how the board is shown (board_display). Its words what it is grouped by where that is not by state;
/// quiet (a ghost's) while the board is as it starts, else on a ground of its own.
fn board_display_key(bar : @view.View, own : BoardOwn) -> Unit {
  let as_started = fn() { (own.group)() == "state" && @sfbase.board_show_empty_of(own.src, (own.ws)()) }
  bar.pick(as_started, at_once=true, fn(p, quiet) {
    @sf.button_opens_node(
      p,
      fn() {
        match (own.group)() {
          "station" => board_words("by-station")
          "person" => board_words("by-person")
          _ => board_words("display")
        }
      },
      fn(btn) { board_display(own, btn) },
      tone=if quiet { Ghost } else { Plain },
      icon="sliders",
    )
    |> ignore
  })
}

///|
/// 显示's panel beside it (Linear's Display): 列表 | 看板 as cards, how the board is grouped, whether its empty columns
/// show. Each changes the board behind it at once, the panel left open; 列表 closes it.
fn board_display(own : BoardOwn, btn : @view.View) -> Unit {
  @sf.panel_nodes(
    board_words("display"),
    fn(held, close) {
      // (in a column of its own, down the panel: the panel lays what it holds out as it says)
      held.box(fn(col) {
      col.row(Is(false)).gap(Is(10.0)).width_share(Is(1.0)) |> ignore
      @sf.choice_cards_node(
        col,
        fn() { [("list", board_words("list")), ("view-columns", board_words("board"))] },
        fn() { if @sfbase.board_on_now(own.src) { 1 } else { 0 } },
        fn(i) {
          if i == 0 {
            close()
            @sfbase.board_set(own.src, false)
          }
        },
        said=board_words("board"),
      )
      |> ignore
      // how it is grouped: its words over a choice the panel's width
      col.box(fn(g) {
        g.row(Is(false)).gap(Is(6.0)).width_share(Is(1.0)) |> ignore
        g.box(fn(t) {
          t.padding(Is((board_display_in, 0.0, board_display_in, 0.0))) |> ignore
          @sf.words_node(t, fn() { board_words("group-by") }, fn() { display_head_look }) |> ignore
        })
        |> ignore
        @sf.seg_fill_node(
          g,
          fn() { [board_words("by-state"), board_words("by-station"), board_words("by-person")] },
          fn() {
            match (own.group)() {
              "station" => 1
              "person" => 2
              _ => 0
            }
          },
          fn(i) {
            @sfbase.board_pick.set(None)
            (own.to_start)()
            @sfbase.set_board_group(own.src, @signals.untracked(own.ws), match i {
              1 => "station"
              2 => "person"
              _ => "state"
            })
          },
          said=board_words("group-by"),
        )
        |> ignore
      })
      |> ignore
      // a line, then whether its empty columns show
      col.box(fn(l) {
        l.height(Is(Some(1.0))).margin(Is((board_display_in, 2.0, board_display_in, 0.0))).ground(By(fn() { @sf.theme().p.line })) |> ignore
      })
      |> ignore
      // (its words where 分组方式's are, its switch as far in from the panel's end as from its foot: concentric with its
      // corner)
      col.box(fn(r) {
        r.padding(Is((board_display_in, 0.0, board_display_in, 0.0))) |> ignore
        @sf.switch_row_node(
          r,
          fn() { board_words("show-empty") },
          fn() { @sfbase.board_show_empty_of(own.src, (own.ws)()) },
          fn(on) { @sfbase.set_board_show_empty(own.src, @signals.untracked(own.ws), on) },
        )
      })
      |> ignore
      })
      |> ignore
    },
    from=Node(btn),
    w=board_display_w,
    heads_itself=true,
    side=Bottom,
    along=End,
  )
}

///|
/// How wide 显示's panel is.
let board_display_w : Double = 288.0

///|
/// How far in from the cards' edges 显示's words and its switch stand: the switch (36 × 22, its corner 11) as far from
/// the panel's end as from its foot, where its row (34 high) leaves it, so concentric with the panel's corner (24).
let board_display_in : Double = 7.0


///|
// kept across runs: a value (no field of it changes)
let display_head_look : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// The narrow board: chips choosing the column (each its count), the column's cards under them across the page.
fn board_narrow(
  p : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  own : BoardOwn,
  width : () -> Double,
) -> Unit {
  // (the five, each with its count, as wide as their words and 10 in at either end, sharing what is left of the
  // page's width; going sideways only where a page is narrower than they are)
  p.box(fn(chips) {
    chips.shrink(Is(0.0)).min_width(Is(Some(0.0))) |> ignore
    chips.scrolls(@view.Scroll::across(), slop=@ui.touch_slop(), fn(row) {
      row
      .row(Is(true))
      .gap(Is(3.0))
      // (the cards' margin at either end, lined up with them; 7 over and under: each one pressed in 44 high)
      .padding(Is((board_pad, 7.0, board_pad, 7.0)))
      .min_width(By(fn() { Some(width()) }))
      |> ignore
      for lane in @sfbase.board_lanes {
        let count = @signals.computed(fn(_) { (own.cards_of)(lane).length() })
        board_chip(
          row,
          fn() { @sfbase.board_lane_words(lane) },
          fn() { @sfbase.board_lane.get() == lane },
          fn() { @sfbase.board_lane.set(lane) },
          count=fn() { count.get().to_string() },
          across=true,
        )
      }
    })
    |> ignore
  })
  |> ignore
  p.box(fn(track) { board_track(track, src, tips, own) }) |> ignore
}

///|
/// The narrow board's columns side by side on one track in `track`, a column its whole width, each in what scrolls of
/// its own (where it is scrolled to kept as another is shown): the one chosen (sfbase's board_lane) shown, slid to as
/// it is chosen (the chips) a column's width a step (the theme's slide, as the chats' lists are: chats_lists_node), and
/// in the hand across: a finger moving more across than down takes the track (View::claims: what scrolls a column keeps
/// the rest), the column it leaves and the one beside it following it; let go past board_swipe_share of a column, or
/// flung that way, the one beside it chosen, else back. Only the columns on the way are there (the one chosen at
/// rest; from where it set out to where it goes; in the hand, it and those beside it): one off the way is put by as it
/// was (View::each's `keeps`), laid out, drawn and read out nowhere, taken in again as it is on the way.
fn board_track(
  track : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  own : BoardOwn,
) -> Unit {
  let lanes = @sfbase.board_lanes
  let n = lanes.length()
  let index_of = fn(lane : String) { lanes.search(lane).unwrap_or(0) }
  let first = index_of(@sfbase.board_lane.untracked())
  let at = @sf.EdgeWay::new(first.to_double())
  // (those laid out: the one chosen at rest; on the way, from where it set out to where it goes)
  let span : @signals.Signal[(Int, Int)] = @signals.signal((first, first))
  let due = Ref(fn() {  })
  let slide_to = fn(k : Int) {
    let from = @signals.untracked(fn() { at.shown(track) })
    let lo = if from.floor().to_int() < k { from.floor().to_int() } else { k }
    let hi = if from.ceil().to_int() > k { from.ceil().to_int() } else { k }
    span.set((if lo < 0 { 0 } else { lo }, if hi >= n { n - 1 } else { hi }))
    let (_, _, w, _) = track.laid_window_now()
    at.go_by(track, k.to_double(), @sf.theme().chat_list.slide.per_unit(w))
    (due.val)()
    due.val = track.at_moment(at.end(), fn() { span.set((k, k)) })
  }
  track.reacts(fn() { index_of(@sfbase.board_lane.get()) }, slide_to, at_start=false)
  // (in the hand: where it was as the finger took it, and where the finger was then)
  let from = Ref(0.0)
  let from_x = Ref(0.0)
  track
  .grow(Is(1.0))
  .min_height(Is(Some(0.0)))
  .clips(Is(true))
  .claims(fn(dx, dy) {
    let k = index_of(@sfbase.board_lane.untracked())
    dx.abs() > @ui.touch_slop() && dx.abs() > dy.abs() && ((dx > 0.0 && k > 0) || (dx < 0.0 && k < n - 1))
  })
  .on_drag(fn(d) {
    let w = if d.w > 1.0 { d.w } else { 1.0 }
    let k = index_of(@sfbase.board_lane.untracked())
    match d.kind {
      Down => {
        from.val = @signals.untracked(fn() { at.shown(track) })
        from_x.val = d.wx
        (due.val)()
        due.val = fn() {  }
        at.put(from.val)
        let lo = if k > 0 { k - 1 } else { k }
        let hi = if k < n - 1 { k + 1 } else { k }
        span.set((lo, hi))
      }
      Moved => {
        let pos = from.val - (d.wx - from_x.val) / w
        let lo = if k > 0 { (k - 1).to_double() } else { k.to_double() }
        let hi = if k < n - 1 { (k + 1).to_double() } else { k.to_double() }
        at.put(if pos < lo { lo } else if pos > hi { hi } else { pos })
      }
      Up => {
        let moved = d.wx - from_x.val
        let vx = d.vx()
        let next = if k < n - 1 && (moved < -board_swipe_share * w || (vx < -board_fling_vx && moved < -board_fling_least)) {
          k + 1
        } else if k > 0 && (moved > board_swipe_share * w || (vx > board_fling_vx && moved > board_fling_least)) {
          k - 1
        } else {
          k
        }
        if next == k {
          slide_to(k)
        } else {
          @sfbase.board_lane.set(lanes[next])
        }
      }
      Off => slide_to(k)
    }
  })
  |> ignore
  for i, lane in lanes {
    track.box(fn(l) {
      l
      .over(Is(true))
      .shift(By(fn() { (i.to_double() - at.shown(l), 0.0) }))
      .clips(Is(true))
      // (read out only while it is the one chosen)
      .hides(By(fn() { index_of(@sfbase.board_lane.get()) != i }))
      |> ignore
      let on_way = fn() {
        let (lo, hi) = span.get()
        if i >= lo && i <= hi { [i] } else { [] }
      }
      l.each(on_way, fn(k) { k }, keeps=fn() { [i] }, at_once=true, fn(c, _) {
        c.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        c.box(fn(col) {
          board_column(col, src, tips, own, lane, fn() { @sfbase.board_lane_words(lane) }, wide=false)
        })
        |> ignore
      })
    })
    |> ignore
  }
}

///|
/// How far across a column the narrow board's track is taken to have the one beside it chosen as it is let go, and
/// how fast (points a millisecond) and at least how far it is flung to have it so sooner.
let board_swipe_share : Double = 0.22

///|
let board_fling_vx : Double = 0.32

///|
let board_fling_least : Double = 16.0

///|
/// Column `key` (named `name`): its title on the paper (its count beside it, 待派发's ＋ at its end), the line to write a
/// draft in where it is open, its cards; lit faintly while a card dragged over it may be let go there (a draft over
/// 进行中). Wide, its title over its cards; narrow, the chips name it, its cards alone.
fn board_column(
  col : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  own : BoardOwn,
  key : String,
  name : () -> String,
  wide~ : Bool,
) -> Unit {
  own.lanes[key] = col
  col.owns(fn() {
    match own.lanes.get(key) {
      Some(c) if c.id() == col.id() => own.lanes.remove(key)
      _ => ()
    }
  })
  |> ignore
  let cards_now = @signals.computed(fn(_) { (own.cards_of)(key) })
  let cards = fn() { cards_now.get() }
  // (lit faintly while a card in hand may be let go on it, coming and going as a control answering does)
  let lit = @sf.EdgeWay::new(0.0)
  col.reacts(fn() { (own.over_is)(key) }, fn(on) { lit.go(col, if on { 1.0 } else { 0.0 }, @sf.dur_ms) })
  col
  .gap(Is(if wide { 2.0 } else { 0.0 }))
  .grow(Is(if wide { 0.0 } else { 1.0 }))
  .min_height(Is(Some(0.0)))
  .radius(Is(@sf.card_corner))
  .ground(By(fn() {
    let p = @sf.theme().p
    let k = lit.shown(col)
    if k <= 0.0 { 0L } else { @sf.alpha(p.accent_bg, 0.45 * k) }
  }))
  |> ignore
  if wide {
    col.box(fn(h) {
      h.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))).min_height(Is(Some(44.0))).padding(Is((4.0, 0.0, 0.0, 0.0)))
      |> ignore
      @sf.words_node(h, name, fn() { lane_title_look }) |> ignore
      @sf.words_node(h, fn() { cards().length().to_string() }, fn() { lane_count_look }) |> ignore
      h.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      if key == "draft" {
        @sf.icon_button_node(h, "plus", fn() { board_words("new-here") }, fn() { board_open_add(own) |> ignore }, tips~)
        |> ignore
      }
    })
    |> ignore
  }
  // its cards, a block each only while it shows (View::scrolls_window: a column of a hundred cards makes those that
  // show), under its title (wide) or the chips (narrow), each going in and out among the others for what comes or
  // leaves (a draft written, one started, a chat come or gone): the list's own way; the line to write a draft in over
  // 待派发's, its head; what it says with none, and its room at its foot, its last blocks
  let ends = if wide { (0.0, 0.0) } else { (board_pad, board_pad) }
  let rows = fn() {
    let out = cards().map(fn(k) { CardRow(k) })
    if out.is_empty() && (key != "draft" || (wide && !@sfbase.board_adding.get())) {
      out.push(EmptyRow)
    }
    out.push(FootRow)
    out
  }
  col.box(fn(l) {
    l.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    l.scrolls_window(
      @view.Scroll::list(),
      rows,
      fn(row, r) {
        match r {
          CardRow(k) => {
            row.padding(Is((ends.0, 0.0, ends.1, 10.0))) |> ignore
            match k {
              DraftKey(id) => draft_card(row, src, tips, own, id, key, wide~)
              ChatKey(name) => board_chat_card(row, src, tips, own, name, key, wide)
            }
          }
          EmptyRow => {
            row.padding(Is((ends.0 + 4.0, 6.0, ends.1 + 4.0, 6.0))) |> ignore
            @sf.words_node(row, fn() { if key == "draft" { board_words("empty-draft") } else { board_words("empty") } }, fn() {
              card_meta_look
            })
            |> ignore
          }
          FootRow => row.height(Is(Some(if wide { 8.0 } else { 24.0 }))) |> ignore
        }
      },
      est=board_card_est,
      slop=@ui.touch_slop(),
      bar=@ui.tree_scroll_bar(),
      comes=fn(r) { r is CardRow(_) },
      goes=fn(r) { r is CardRow(_) },
      comes_whole=fn(_) { true },
      // (a card in the hand holds its place as what is over it changes)
      holds=fn(r) {
        match (r, own.drag.get()) {
          (CardRow(k), Some(g)) => g.key == k
          _ => false
        }
      },
      head=fn(h) {
        h.padding(Is((ends.0, if wide { 0.0 } else { 4.0 }, ends.1, 0.0))) |> ignore
        if key == "draft" {
          if wide {
            board_add_room(h, own, tips)
          } else {
            h.box(fn(a) {
              a.padding(Is((0.0, 0.0, 0.0, 10.0))) |> ignore
              board_add(a, own, wide, tips)
            })
            |> ignore
          }
        }
      },
    )
    |> ignore
  })
  |> ignore
}

///|
/// What a column's list holds (board_column's): a card by its key, what the column says with none, the room at its foot.
#derive(Eq, Hash)
priv enum ColRow {
  CardRow(BoardKey)
  EmptyRow
  FootRow
}

///|
/// How tall a card is taken to be in a column's list till it is measured (its title on one line, where it stands, where
/// it runs, its room under it).
let board_card_est : Double = 116.0

///|
/// The wide board's room the card a draft is written in stands in, at 待派发's top: opening and closing as a room does
/// (as tall as its share of the card, the card as big as it is open about its middle, seen from half open), what is
/// under it going with it, a Move as far as the card is tall; opened, the card empty. Put away by what was written in
/// it, gone at once: its draft comes in its place, grown from it (draft_card's), the cards under it going on one Move.
fn board_add_room(b : @view.View, own : BoardOwn, tips : @sf.TipLayer) -> Unit {
  let open = fn() { @sfbase.board_adding.get() }
  // (opened: empty)
  b.reacts(open, fn(o) {
    if o {
      own.field.set("")
    }
  }, at_start=false)
  // (made anew at once as what was written in it is added, closed and laid nowhere: the one that held it let go with
  // what makes the cards under it, so that what moves for its draft finds both done; opened, mbui's room's way)
  b.pick(fn() { own.room_made.get() }, fn(room, _) {
    @motion.reveal_node(room, open, fn(h) {
      h.padding(Is((0.0, 0.0, 0.0, 10.0))) |> ignore
      board_add(h, own, true, tips)
    })
    |> ignore
  }, at_once=true)
}

///|
/// The card a draft is written in at 待派发's top, as the cards under it look: what it is, × to put it away (wide), the
/// station it goes to, 添加.
fn board_add(a : @view.View, own : BoardOwn, wide : Bool, tips : @sf.TipLayer) -> Unit {
  let card_at : Ref[@view.View?] = Ref(None)
  let add = fn() {
    let words = own.field.text()
    let st = @signals.untracked(fn() { board_station_now(own) })
    let name = own.stations_by.peek(st).map(fn(s) { s.name }).unwrap_or("")
    let from = match card_at.val {
      Some(c) if c.alive() => Some(c.placed_window_now())
      _ => None
    }
    // (the draft and its line put away one change: what moves for it goes from where all of it stood before)
    guard words.trim(chars=" \n\r\t").to_owned() != "" else { return }
    @signals.start_batch()
    // (wide, put away at once once written, its words in it, its room let go first: its draft comes in its place,
    // grown from where it was)
    if wide {
      own.room_made.set(own.room_made.untracked() + 1)
      @sfbase.board_adding.set(false)
    }
    let added = @sfbase.board_draft_add(own.src, @signals.untracked(own.ws), words, st, name)
    if wide && added is Some(id) {
      own.added_from = from.map(fn(r) { (id, r) })
    }
    @signals.end_batch()
    guard added is Some(_) else { return }
    if !wide {
      // (narrow it stays, 待派发's own line, empty for the next)
      own.field.set("")
    }
  }
  let cancel = fn() {
    own.field.set("")
    @sfbase.board_adding.set(false)
  }
  // (what stands in its foot's corners, as tall as a control, concentric with the card's: as far in as that leaves)
  let h = fn() { @sf.theme().control_h }
  let foot_in = fn() { @sf.card_corner - h() / 2.0 }
  // (添加 as tall as a button, lower than a control where it is touched: as far in from the end as its middle leaves it
  // from the foot, concentric with the card's corner too)
  let add_in = fn() {
    let d = h() - @sf.button_height()
    if d > 0.0 { d / 2.0 } else { 0.0 }
  }
  a.box(fn(card) {
    card_at.val = Some(card)
    card
    .ground(By(fn() { @sf.theme().p.card }))
    .radius(Is(@sf.card_corner))
    .padding(By(fn() { (foot_in(), card_pad, foot_in(), foot_in()) }))
    .gap(Is(12.0))
    |> ignore
    // its words, on the card's own paper: no frame round them, where a card's title begins
    card.box(fn(w) {
      w.row(Is(true)).padding(By(fn() { (card_pad - foot_in(), 0.0, if wide { card_title_end() + card_pad - foot_in() } else { card_pad - foot_in() }, 0.0) })) |> ignore
      let typed = @ui.field(
        w,
        own.field,
        placeholder=board_words("placeholder"),
        label=board_words("placeholder"),
        max_lines=3,
        enter_sends=true,
        submitted=fn(_) { add() },
        leaves=[@ui.key_escape],
        size_by=fn() { @sf.theme().t.ui },
        colors_by=fn() {
          let th = @ui.tree_theme()
          (th.fg, th.subtle, th.accent)
        },
      )
      // (tall enough to be found by a finger, all of it the field's)
      typed.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_height(Is(Some(32.0))) |> ignore
      // (Escape puts it away, as × does)
      if wide {
        w.on_key(fn(k) {
          if k.code == @ui.key_escape {
            cancel()
            true
          } else {
            false
          }
        })
        |> ignore
      }
      // (opened to be written in: the cursor in it, each time it opens)
      // (once what opened it is done: its room in use by then)
      typed.reacts(fn() { @sfbase.board_adding.get() }, fn(on) {
        if on {
          @signals.after_flush(fn() { typed.ask_focus() |> ignore })
          // (and once its room is laid out open where the host gives the focus by where it is: a browser's)
          typed.at_moment(typed.cause_at() + 1.0, fn() { if @sfbase.board_adding.untracked() { typed.ask_focus() |> ignore } })
          |> ignore
        }
      })
    })
    |> ignore
    card.box(fn(r) {
      r.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
      // (where it goes: the library's choice of a station, round as the foot's buttons, its mark where a card's words
      // begin)
      @sf.station_choice_node(
        r,
        own.stations,
        fn() { board_station_now(own) },
        fn(at) { own.station.set(at) },
        title=board_words("goes-on"),
        label=fn(name) { board_words("goes-on") + ": " + name },
        round=true,
      )
      |> ignore
      r.box(fn(g) { g.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore }) |> ignore
      r.box(fn(k) {
        k.shrink(Is(0.0)).margin(By(fn() { (0.0, 0.0, add_in(), 0.0) })) |> ignore
        @sf.button_node(k, fn() { board_words("add") }, add, tone=Primary, disabled=fn() {
          own.field.text().trim(chars=" \n\t").is_empty() || board_station_now(own) == ""
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  if wide {
    card_corner_key(a, tips, fn() { true }, "close", fn() { board_words("cancel") }, cancel)
  }
}


///|
/// A compact choice (a column on a narrow board, a station a draft goes to): 30 high, round, its words (and a
/// station's mark before them) on a tint of the words' ink, the accent's while chosen; `across`: as wide as it is given,
/// its words in its middle. Pressed, `press`; read out a toggle button by its words.
fn board_chip(
  parent : @view.View,
  words : () -> String,
  on : () -> Bool,
  press : () -> Unit,
  mark? : String = "",
  across? : Bool = false,
  high? : () -> Double = fn() { 30.0 },
  count? : () -> String,
) -> Unit {
  parent.box(fn(c) {
    c
    .row(Is(true))
    .height(By(fn() { Some(high()) }))
    .radius(By(fn() { high() / 2.0 }))
    .gap(Is(if count is Some(_) { 2.0 } else { 4.0 }))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    // (8 in at either end at least: five of them, the longest 等你处理, whole on a phone 390 wide within the cards'
    // margins, what the row leaves shared among them)
    .padding(Is((8.0, 0.0, 8.0, 0.0)))
    .ground(By(fn() {
      let p = @sf.theme().p
      if on() {
        p.accent_bg
      } else if @sf.lit_node(c) {
        @sf.alpha(p.text, 0.09)
      } else {
        @sf.alpha(p.text, 0.05)
      }
    }))
    |> ignore
    // (across: as wide as its words at least, sharing what the row leaves; never narrower than they are)
    c.shrink(Is(0.0)) |> ignore
    if across {
      c.grow(Is(1.0)) |> ignore
    }
    @sf.presses_node(c, press)
    let said = fn() {
      match count {
        Some(n) => words() + " " + n()
        None => words()
      }
    }
    c.says(By(fn() { Some(@view.said(Button, label=said(), selected=on())) })) |> ignore
    if mark != "" {
      @sf.station_mark_node(c, fn() { "" }, fn() { mark }, 12.0, fn() { @sf.theme().p.muted }, fn() { 0 })
    }
    @sf.words_node(c, words, fn() { if on() { chip_on_look } else { chip_look } }) |> ignore
    match count {
      Some(n) => @sf.words_node(c, n, fn() { if on() { chip_on_look } else { chip_count_look } }) |> ignore
      None => ()
    }
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let chip_look : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let chip_count_look : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let chip_on_look : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)

///|
/// The ground every card has, at rest: the page's card, no line round it, no shadow.
fn card_ground(card : @view.View, picked : () -> Bool, faded : () -> Bool) -> Unit {
  card
  .ground(By(fn() {
    let p = @sf.theme().p
    if picked() {
      @sf.over(p.card, @sf.alpha(p.accent_bg, 0.55))
    } else if @sf.lit_node(card) {
      @sf.over(p.card, @sf.alpha(p.hover, 0.6))
    } else {
      p.card
    }
  }))
  .radius(Is(@sf.card_corner))
  .padding(Is((card_pad, card_pad, card_pad, card_pad)))
  .gap(Is(6.0))
  .alpha(By(fn() { if faded() { 0.35 } else { 1.0 } }))
  |> ignore
}

///|
/// A card's drag: taken past the slop, it follows the pointer (BoardOwn's drag); what is under it that takes it lit;
/// let go there, `drop` told that place's key ("run", "archive") and where the card in hand was in the window then (as
/// tall as the card it was taken from); else nothing.
fn card_drags(
  card : @view.View,
  own : BoardOwn,
  key : BoardKey,
  title : () -> String,
  said : () -> String,
  takes : Array[String],
  press : () -> Unit,
  drop : (String, (Double, Double, Double, Double)) -> Unit,
  menu? : (Double, Double) -> Unit,
) -> Unit {
  let under = fn(x : Double, y : Double) -> String {
    let inside = fn(n : @view.View) {
      let (nx, ny, nw, nh) = n.placed_window_now()
      x >= nx && x < nx + nw && y >= ny && y < ny + nh
    }
    for t in takes {
      let at = match t {
        "archive" =>
          match own.archive {
            Some(a) if a.alive() && inside(a) => "archive"
            _ => ""
          }
        lane =>
          match own.lanes.get(lane) {
            Some(c) if c.alive() && inside(c) => lane
            _ => ""
          }
      }
      if at != "" {
        return at
      }
    }
    ""
  }
  let held_h = Ref(0.0)
  // (right clicked or held long by a finger: its menu where it was)
  match menu {
    Some(m) => card.on_menu(fn(e) { m(e.wx, e.wy) }) |> ignore
    None => ()
  }
  card.gesture(
    @ui.touch_slop(),
    tap=fn(_) { press() },
    hold?=menu.map(fn(m) { (@ui.long_press_ms, fn(d : @view.Drag) { m(d.wx, d.wy) }) }),
    drag=fn(d) {
      match d.kind {
        Down => {
          let (cx, cy, cw, ch) = card.placed_window_now()
          held_h.val = ch
          let (ox, oy) = match own.root {
            Some(r) if r.alive() => {
              let (x, y, _, _) = r.placed_window_now()
              (x, y)
            }
            _ => (0.0, 0.0)
          }
          own.drag_xy.set((d.wx, d.wy))
          own.drag.set(Some({ key, title: @signals.untracked(title), said: @signals.untracked(said), dx: d.wx - cx, dy: d.wy - cy, w: cw, ox, oy }))
          own.over.set("")
          @sfbase.board_drag_active.set(true)
        }
        // (the card in hand follows the pointer, and what is under it that takes it is lit: nothing else told)
        Moved =>
          if own.drag.untracked() is Some(_) {
            own.drag_xy.set((d.wx, d.wy))
            own.over.set(under(d.wx, d.wy))
          }
        Up => {
          let at = under(d.wx, d.wy)
          let rect = match own.drag.untracked() {
            Some(g) => {
              let (x, y) = own.drag_xy.untracked()
              (x - g.dx, y - g.dy, g.w, held_h.val)
            }
            None => card.placed_window_now()
          }
          own.drag.set(None)
          own.over.set("")
          @sfbase.board_drag_active.set(false)
          if at != "" {
            drop(at, rect)
          }
        }
        Off => {
          own.drag.set(None)
          own.over.set("")
          @sfbase.board_drag_active.set(false)
        }
      }
    },
  )
  |> ignore
}

///|
/// A draft's card (待派发's): its words, where it is to run, 开始 at its top end; `wide`, dragged onto 进行中, started
/// there too. Narrow, a column at a time with nowhere to drag it to: not dragged, so a finger on it scrolls the column;
/// held long (or right clicked), its menu.
fn draft_card(
  row : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  own : BoardOwn,
  id : String,
  lane : String,
  wide~ : Bool,
) -> Unit {
  let d = fn() { (own.drafts_by)().get(id) }
  let title = fn() { d().map(fn(d) { d.title }).unwrap_or("") }
  let card_at : Ref[@view.View?] = Ref(None)
  // (started from `from` in the window, `lifted` off the board there: its chat's card flies in from there,
  // board_chat_card's)
  let start_from = fn(from : (Double, Double, Double, Double), lifted : Bool) {
    match @signals.untracked(d) {
      Some(d) => {
        // (its chat's card is of the key it is made under: its row's all along)
        own.start_from = Some((d.station + "/" + @sfbase.board_key_of(d), from, lifted))
        @sfbase.board_start(src, @signals.untracked(own.ws), d)
      }
      None => ()
    }
  }
  let start = fn() {
    match card_at.val {
      Some(c) if c.alive() => start_from(c.placed_window_now(), false)
      _ => start_from((0.0, 0.0, 0.0, 0.0), false)
    }
  }
  let delete = fn() { @sfbase.board_draft_remove(src, @signals.untracked(own.ws), id) }
  // (its menu: start it now, delete it)
  let menu = fn(x : Double, y : Double) {
    @sf.menu(
      [
        Some(@sf.menu_item_of(board_words("start-now"), start, icon="play")),
        Some(@sf.menu_item_of(board_words("delete"), delete, icon="trash", danger=true)),
      ],
      from=At(x, y, 0.0, 0.0),
    )
  }
  // (the station it goes to as the workspace's rows have it: its mark)
  let station = fn() {
    let st = d().map(fn(d) { d.station }).unwrap_or("")
    own.stations_by.get(st)
  }
  row.box(fn(w) {
  w.box(fn(card) {
    card_at.val = Some(card)
    // (written a moment ago in the card over 待派发's cards: its ground grows from as tall as that one was, its foot
    // coming up with the cards under it, one Move)
    match own.added_from {
      Some((added, from)) if added == id => {
        own.added_from = None
        let grow = @sf.EdgeWay::new(0.0)
        let by = Ref(0.0)
        card.at_moment(card.cause_at(), fn() {
          by.val = from.3 - card.laid_window_now().3
          grow.go_from(card, 1.0, 0.0, @motion.moved(over=by.val.abs()))
        })
        |> ignore
        card.ground_drawn(By(fn() { { dx: 0.0, dy: 0.0, dw: 0.0, dh: by.val * grow.shown(card), corners: None } })) |> ignore
      }
      _ => ()
    }
    card_ground(card, fn() { false }, fn() { (own.dragged)(DraftKey(id)) })
    if wide {
      card_drags(card, own, DraftKey(id), title, fn() { d().map(fn(d) { d.station_name }).unwrap_or("") }, ["archive", "run"], fn() {  }, fn(at, rect) {
        if at == "archive" {
          delete()
        } else {
          start_from(rect, true)
        }
      }, menu~)
    } else {
      card.on_menu(fn(e) { menu(e.wx, e.wy) }) |> ignore
      @sf.presses_held_node(card, fn() {  }, @ui.long_press_ms, fn(e) { menu(e.wx, e.wy) })
      card.says(By(fn() { Some(@view.said(Button, label=title())) })) |> ignore
    }
    card.box(fn(head) {
      head.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Start))) |> ignore
      head.box(fn(t) {
        t.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(t, title, fn() { card_title_look }) |> ignore
      })
      |> ignore
      head.padding(Is((0.0, 0.0, card_title_end(), 0.0))) |> ignore
    })
    |> ignore
    // where it is to run, as a chat's card says where it runs (and, not by state, that it waits in 待派发)
    card.box(fn(m) {
      m.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
      @sf.station_mark_node(
        m,
        fn() { station().map(fn(c) { c.emoji }).unwrap_or("") },
        fn() {
          match station() {
            Some(c) if c.icon != "" || c.emoji != "" => c.icon
            // (none said, or a station not of the workspace's rows: a station's own glyph, as a station's page has
            // one with none of its own)
            _ => "glyph:desktop"
          }
        },
        14.0,
        fn() { @sf.theme().p.muted },
        fn() { 0 },
      )
      @sf.words_node(m, fn() {
        let name = d().map(fn(d) { d.station_name }).unwrap_or("")
        if (own.group)() == "state" { name } else { name + " · " + @sfbase.board_lane_words("draft") }
      }, fn() { card_meta_look })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  card_corner_key(w, tips, fn() { true }, "play", fn() { board_words("start") }, start)
  })
  |> ignore
  ignore(lane)
}

///|
/// A round key standing in the top end corner of card `w` holds while `when` holds, over it, concentric with the card's
/// corner (card_key_in from its top and its end), not part of what flies with the card (View::shared): its title keeps
/// clear of it (card_title_end).
fn card_corner_key(w : @view.View, tips : @sf.TipLayer, when : () -> Bool, icon : String, label : () -> String, press : () -> Unit) -> Unit {
  w.show(when, fn(o) {
    o.over(Is(true)).row(Is(true)).lies_along(Is(End)).lines_up(Is(Some(Start))) |> ignore
    o.box(fn(k) {
      k.margin(Is((0.0, card_key_in(), card_key_in(), 0.0))).shrink(Is(0.0)) |> ignore
      @sf.icon_button_node(k, icon, label, press, tips~, size=card_key, icon_size=14.0) |> ignore
    })
    |> ignore
  }, at_once=true)
}

///|
/// How far a card's title stops short of its end where a key stands in its corner (card_corner_key's, and a gap).
fn card_title_end() -> Double {
  card_key_in() + card_key + 6.0 - card_pad
}

///|
/// The chat's card of row `name` in column `lane`: its title (two lines at most), its pin and, done, 归档 at its top
/// end; where it stands now; where it runs, where it came from, when, its agents and its people. Pressed, its chat
/// beside the board (wide) or its page; wide, dragged onto the archive's place, archived.
fn board_chat_card(
  row : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  own : BoardOwn,
  name : String,
  lane : String,
  wide : Bool,
) -> Unit {
  // (listed in its column: one gone on to another column is that column's card now, not this one's; its own row read by
  // its key, told only as it changes)
  let found = fn() {
    match own.items_by.get(name) {
      Some(i) if board_holds(lane, i, own.me) => Some(i)
      _ => None
    }
  }
  // (as it was last listed: a card leaving keeps its words)
  let last : Ref[ChatItem?] = Ref(@signals.untracked(found))
  let item = fn() {
    match found() {
      Some(i) => {
        last.val = Some(i)
        Some(i)
      }
      None => last.val
    }
  }
  // (while its chat is being made, the words it was started with: not 新对话)
  let title = fn() { item().map(fn(i) { @sfbase.board_title_of(i) }).unwrap_or("") }
  let r = fn() { item().map(fn(i) { row_ref(i) }) }
  let stands = fn() { item().map(fn(i) { @sfbase.board_lane_of(i) }).unwrap_or("done") }
  let open = fn() {
    guard @signals.untracked(r) is Some(r) else { return }
    if wide && @signals.untracked(own.side) {
      let opening = @sfbase.board_pick.untracked() != Some(r)
      @sfbase.board_pick.set(if opening { Some(r) } else { None })
      // (its column whole beside the chat as it opens)
      if opening {
        (own.reveal)(lane)
      }
    } else {
      open_page(Chat(r))
    }
  }
  let archive = fn() {
    match @signals.untracked(item) {
      Some(i) => {
        if @sfbase.board_pick.untracked().map(fn(p) { @sfbase.row_is(i, p) }).unwrap_or(false) {
          @sfbase.board_pick.set(None)
        }
        archive_row(src, i)
      }
      None => ()
    }
  }
  // (picked only where its chat shows beside the board: no ground of it left where there is not the room)
  let picked = fn() { (own.picked)(name) && (own.side)() }
  // (a draft's chat come as it was started: from where its card was, lifted off the board (its hairline and shadow
  // going as it lands) where it was dragged; by its key alone, as the column lists it: its row by key may come a moment
  // after, items_by following the chats as a reaction)
  let lifted = match own.start_from {
    Some((sid, _, _)) if sid == name => own.start_from
    _ => None
  }
  if lifted is Some(_) {
    own.start_from = None
  }
  let lift = @sf.EdgeWay::new(0.0)
  row.box(fn(w) {
  match lifted {
    Some((_, (fx, fy, fw, _), up)) => {
      w.flies_in(@motion.flight_by(@motion.moved()), fn(to) { Some((fx, fy, fw, to.3)) }) |> ignore
      if up {
        w.at_moment(w.cause_at(), fn() { lift.go_from(w, 1.0, 0.0, @motion.moved()) }) |> ignore
      }
    }
    None => ()
  }
  w.box(fn(card) {
    card
    .edge(By(fn() {
      let k = lift.shown(card)
      if k <= 0.0 { (0.0, 0L) } else { (k, @sf.alpha(@sf.theme().p.line, k)) }
    }))
    .shadow(By(fn() {
      let k = lift.shown(card)
      if k <= 0.0 { (0.0, 0.0, 0L) } else { (24.0 * k, 10.0 * k, @sf.alpha(@sf.theme().p.shadow, 0.28 * k)) }
    }))
    |> ignore
    // (one thing by its row's key: the same from the draft's card on through the core's pending row to its station's)
    // (narrow, its column's alone: the track slides from one to another, a card going on to another column is not
    // flown across it)
    @motion.shared(card, board_shared(own, lane, name) + (if wide { "" } else { "@" + lane })) |> ignore
    card_ground(card, picked, fn() { (own.dragged)(ChatKey(name)) })
    card.presses(Is(true)).focusable(Is(true)).on_press(open).says(By(fn() { Some(@view.said(Button, label=title())) })) |> ignore
    // (narrow, a column at a time with nowhere to drag it to: not dragged, so a finger on it scrolls the column)
    if wide {
      card_drags(card, own, ChatKey(name), title, fn() {
        match item() {
          Some(i) => i.station_name + " · " + card_said(Some(i))
          None => ""
        }
      }, ["archive"], open, fn(_, _) { archive() })
    }
    // its title, and what stands at its end
    card.box(fn(head) {
      head.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Start))) |> ignore
      head.box(fn(t) {
        t.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(t, title, fn() { card_title_look }) |> ignore
      })
      |> ignore
      head.show(fn() { item().map(fn(i) { i.pinned == Some(true) }).unwrap_or(false) }, fn(m) {
        m.padding(Is((0.0, 3.0, 0.0, 0.0))).says(Is(Some(@view.said(Image, label=board_words("pinned"))))) |> ignore
        @sf.icon_node(m, "pin", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
      }, along_row=true)
      head.padding(By(fn() { (0.0, 0.0, if stands() == "done" { card_title_end() } else { 0.0 }, 0.0) })) |> ignore
    })
    |> ignore
    // where it stands now: its lead (by station or person, which column of the state it is in) and the core's words
    card.box(fn(s) {
      s.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Start))) |> ignore
      s.box(fn(m) {
        m.height(By(fn() { Some(@sf.theme().t.meta_line) })).lines_up(Is(Some(Middle))).row(Is(true)).shrink(Is(0.0)) |> ignore
        m.pick(stands, fn(mm, st) {
          match st {
            "done" => @sf.icon_node(mm, "check", 14.0, By(fn() { @sf.theme().p.green_ink })) |> ignore
            "watch" => @sf.icon_node(mm, "watch", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
            "run" => chat_mark_node(mm, fn() { "busy" })
            _ =>
              chat_mark_node(mm, fn() {
                item().map(fn(i) { if i.state == "failed" || i.unsent { "alert" } else { "wait" } }).unwrap_or("wait")
              })
          }
        }, at_once=true)
      })
      |> ignore
      s.box(fn(w) {
        w.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        // (its mark says where it stands, by state or not: no column's name before it)
        @sf.words_node(w, fn() { card_said(item()) }, fn() {
          match (stands(), item()) {
            ("wait", Some(i)) if i.state == "failed" || i.unsent => card_state_red
            ("wait", _) => card_state_warn
            ("done", _) => card_state_done()
            _ => card_state_muted
          }
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // where it runs, where from, when; its agents and its people at the end
    card.box(fn(m) {
      m.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))).padding(Is((0.0, 2.0, 0.0, 0.0))) |> ignore
      @sf.station_mark_node(
        m,
        fn() { item().map(fn(i) { i.station_emoji }).unwrap_or("") },
        fn() { item().map(fn(i) { i.station_icon }).unwrap_or("") },
        14.0,
        fn() { @sf.theme().p.muted },
        fn() { 0 },
      )
      m.box(fn(t) {
        t.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        // (as it was last listed, as its other words: a card leaving keeps them)
        let said = Ref("")
        @sf.words_node(t, fn() {
          match found() {
            Some(i) => {
              // (its time in words where its row says it: a list's rows come without it, a chat's whole row is asked
              // only as it is pressed or opened, never a card's subscription of its own)
              said.val = if i.ago == "" { i.station_name } else { i.station_name + " · " + i.ago }
              said.val
            }
            None => said.val
          }
        }, fn() { card_meta_look })
        |> ignore
      })
      |> ignore
      m.show(fn() { item().map(fn(i) { i.origin_kind != "" }).unwrap_or(false) }, fn(o) {
        o.says(By(fn() { Some(@view.said(Image, label=item().map(fn(i) { i.origin_text }).unwrap_or(""))) })) |> ignore
        @sf.origin_mark_node(o, fn() { item().map(fn(i) { i.origin_kind }).unwrap_or("") }, 13.0) |> ignore
      }, along_row=true)
      m.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      m.box(fn(a) {
        a.row(Is(true)).gap(Is(2.0)).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
        a.each(fn() { item().map(fn(i) { i.agents.iter().take(3).collect() }).unwrap_or([]) }, fn(g) {
          g.maker + "\u{1}" + g.runtime
        }, fn(b, g) {
          let g = @signals.untracked(fn() { g.get() })
          b.says(Is(Some(@view.said(Image, label=g.runtime)))) |> ignore
          @sf.maker_mark_node(b, g.maker, g.runtime, 14.0) |> ignore
        }, at_once=true)
      })
      |> ignore
      m.box(fn(f) {
        f.row(Is(true)).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
        // (each its own person, by their id: told only as they change)
        f.each(fn() { item().map(fn(i) { i.people.iter().take(3).collect() }).unwrap_or([]) }, fn(p) { p.id }, fn(b, p) {
          let id = @signals.untracked(fn() { p.get() }).id
          b.margin(Is((-4.0, 0.0, 0.0, 0.0))).radius(Is(1.0e6)).padding(Is((1.0, 1.0, 1.0, 1.0))).ground(By(fn() { @sf.theme().p.card }))
          .says(By(fn() { Some(@view.said(Image, label=p.get().name)) }))
          |> ignore
          @sf.avatar_node(b, fn() { id }, fn() { p.get().name }, fn() { p.get().picture }, 18.0)
        }, at_once=true)
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  card_corner_key(w, tips, fn() { stands() == "done" }, "archive", fn() { board_words("archive") }, archive)
  })
  |> ignore
  ignore(lane)
}

///|
/// What a card says of where its chat stands: the core's line for it, else the last thing said in it.
fn card_said(i : ChatItem?) -> String {
  guard i is Some(i) else { return "" }
  let rest = i.state_rest.trim(chars=" ·").to_owned()
  let whole = match (i.state_text, i.decision_text, i.last) {
    (Some(s), _, _) if s != "" => s
    (_, Some(d), _) if d != "" => d
    (_, _, Some(l)) => l
    _ => ""
  }
  // (its mark before it says where it stands already: the core's lead word not said again, as the sidebar's rows have
  // it; a decision keeps who it waits for, a failure what went wrong)
  match i.state_lead {
    "done" | "need" if rest != "" => rest
    "watch" => {
      let w = if rest != "" { rest } else { whole }
      let lead = @sf.t("web-main.board.watch_prefix")
      if lead != "" && w.has_prefix(lead) { w.exact_view(start=lead.length()).to_owned() } else { w }
    }
    _ => whole
  }
}

///|
// kept across runs: a value (no field of it changes)
let card_title_look : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, wrap=true, max_lines=2, leading=L5)

///|
// kept across runs: a value (no field of it changes)
let card_drop_look : @ui.TextStyle = @ui.text_style(size=Meta, color=Accent, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let card_meta_look : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let card_state_muted : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=true, max_lines=2)

///|
// kept across runs: a value (no field of it changes)
let card_state_warn : @ui.TextStyle = @ui.text_style(size=Meta, color=WarnInk, wrap=true, max_lines=2)

///|
// kept across runs: a value (no field of it changes)
let card_state_red : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger, wrap=true, max_lines=2)

///|
fn card_state_done() -> @ui.TextStyle {
  // (the theme's green ink, read on the card's white)
  let p = @sf.theme().p
  @ui.text_style(size=Meta, color=Data(p.green_ink), wrap=true, max_lines=2)
}

///|
// kept across runs: a value (no field of it changes)
let lane_title_look : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let lane_count_look : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let drop_look : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let drop_lit_look : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=AccentText, wrap=false)

///|
/// The key a card is one thing by (View::shared): its chat's (or its draft's, the chat it becomes), within how the board is
/// grouped (another grouping's columns another board, nothing flying between them); by person, within its column too (a
/// chat in each of its people's).
fn board_shared(own : BoardOwn, lane : String, id : String) -> String {
  let group = @signals.untracked(own.group)
  "board/" + group + "/" + (if lane.has_prefix("person:") { lane + "/" } else { "" }) + id
}

