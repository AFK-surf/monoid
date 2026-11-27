// What was said in a chat besides words (the core's `chatThings` view, things.ts): its pictures and videos, its other
// files, the web links in its messages and the pull requests among them, each once and the latest first. One body for
// 中屏's and 大屏's tab beside the chat (sfdesk panel_node.mbt) and 小屏's sheet (sfapp sheets.mbt), made once as nodes
// (things_node): the kinds it
// has to choose from, a field finding among the chosen kind's by their words, then that kind's: the pictures a grid,
// the rest a row each. Pressed, a picture or a file opens in the preview (an image stepping through the chat's), a
// link or a pull request in the browser; held or right clicked, its menu goes to the message it was last said in (在对话
// 里看). The chat's info names its pull requests itself (things_pulls).
//
// Pictures keep their shape: square crops of screenshots all look alike (the user, 2026-10-29: 「太丑了，而且不好用
// 」).

///|
/// Each chat's page of things as it was left: the kind chosen ("" the first it has: a signal, what a page made of it
/// reads, told as things_choose chooses another while it shows) and the words found by.
priv struct ThingsAt {
  kind : @signals.Signal[String]
  field : @ui.Field
}

///|
let things_at : Map[String, ThingsAt] = Map([])

///|
fn things_reset() -> Unit {
  things_at.clear()
}

///|
fn things_of(key : String) -> ThingsAt {
  match things_at.get(key) {
    Some(t) => t
    None => {
      let t = { kind: @signals.signal("", same=fn(a, b) { a == b }), field: @ui.Field::new() }
      things_at[key] = t
      t
    }
  }
}

///|
/// Chat `r`'s page of things to show its `kind` next (the info's 全部 N 个 for its pull requests).
pub fn things_choose(r : ChatRef, kind : String) -> Unit {
  things_of(r.station + "\u{1}" + r.session).kind.set(kind)
}

///|
/// The kinds, in the order the page offers them (things.ts KINDS), and what each is called.
// kept across runs: a value (no field of it changes)
let thing_kinds : Array[String] = ["media", "files", "links", "pulls"]

///|
fn thing_kind_name(kind : String) -> String {
  @sf.t("web-main.things." + kind)
}

///|
/// The params of a chat's things (the core's `chatThings` view): on `station`, its thread `thread`, those that have
/// the words `q` (all of them with none).
pub fn things_params(station : String, thread : Double, q? : String = "") -> Map[String, Json] {
  let p : Map[String, Json] = { "station": Json::string(station), "thread": Json::number(thread) }
  if q.trim(chars=" ") != "" {
    p["q"] = Json::string(q)
  }
  p
}

///|
/// How many things a chat has of every kind but its pull requests (what the info's row to the page counts), and its
/// pull requests, the latest first, as the core has them now (none until it has read them).
pub fn things_now(src : Source, station : String, thread : Double) -> (Int, Array[Json]) {
  let v = src.topic("chatThings", things_params(station, thread)).get().value
  let counts = field(v, "counts")
  let n = count(counts, "media") + count(counts, "files") + count(counts, "links")
  (n, items(v, "pulls"))
}

///|
/// What a pull request is called: its title once its card is read, else its repository and number.
pub fn pull_title(pull : Json?) -> String {
  match text(pull, "title") {
    "" => text(pull, "repository") + " #" + count(pull, "number").to_string()
    t => t
  }
}

///|
/// What a pull request's line under its title says: how it stands (once it is not open), its repository and number, when it last changed
/// (else when it was last said).
fn pull_meta(pull : Json?) -> String {
  // (how it stands where it is no longer open: open is what one is, said by nothing)
  let parts = []
  match text(pull, "state") {
    "" | "open" => ()
    state => parts.push(@sf.t(pr_state_key(state)))
  }
  if count(field(pull, "checks"), "failed") > 0 {
    parts.push(@sf.t("web-main.preview.checks.failed", args=[("count", count(field(pull, "checks"), "failed").to_string())]))
  }
  parts.push(text(pull, "repository") + " #" + count(pull, "number").to_string())
  let ago = match text(field(field(pull, "time"), "updatedAt"), "ago") {
    "" => text(field(field(pull, "time"), "createdAt"), "ago")
    a => a
  }
  if ago != "" {
    parts.push(ago)
  }
  parts.join(" · ")
}

///|
/// A thing held (a node's hold, presses_held_node): its menu there (thing_menu_at), felt as it opens where a finger held
/// it, as an old view's hold is (menu_held's).
fn thing_held_at(x : Double, y : Double, seq : Double, url : String, away : (Double) -> Unit, beside? : (() -> Unit)? = None) -> Unit {
  @sf.menu_held_node()
  thing_menu_at(x, y, seq, url, away, beside~)
}

///|
/// A thing's menu at `x`, `y` in the window (thing_menu's): 在对话中查看 (`away` to message `seq`), a file's 在侧边打开
/// where it is offered (`beside`: thing_beside), then a link's copy (`url`: none for a file).
fn thing_menu_at(x : Double, y : Double, seq : Double, url : String, away : (Double) -> Unit, beside? : (() -> Unit)? = None) -> Unit {
  let menu : Array[@sf.MenuItem?] = [Some(@sf.menu_item_of(@sf.t("web-main.things.show"), fn() { away(seq) }, icon="chat"))]
  match beside {
    Some(f) => menu.push(Some(@sf.menu_item_of(@sf.t("web-main.preview.openBeside"), f, icon="panel-open")))
    None => ()
  }
  if url != "" {
    menu.push(Some(@sf.menu_item_of(@sf.t("common.link.copy"), fn() { @sfbase.copy_out(url, said=@sf.t("common.link.copied")) }, icon="copy")))
  }
  @sf.menu(menu, from=@sf.at_point(x, y))
}

///|
/// What a chat's page of things shows as the core's `chatThings` has it (`v`): its bones while it is read (or while it
/// has nothing and more may come), words saying it has none once all of it is read, else what it has.
#derive(Eq)
priv enum ThingsState {
  ThingsWaiting
  ThingsNone
  ThingsShown
}

///|
fn things_state(v : Json?) -> ThingsState {
  let has = things_has(v)
  if !(v is Some(Object(_))) || (has.length() == 0 && !flag(v, "whole")) {
    ThingsWaiting
  } else if has.length() == 0 {
    ThingsNone
  } else {
    ThingsShown
  }
}

///|
/// The kinds a chat's things (`v`) has, in the order the page offers them.
fn things_has(v : Json?) -> Array[String] {
  let counts = field(v, "counts")
  thing_kinds.filter(fn(k) { count(counts, k) > 0 })
}

///|
/// What the kinds' choice says of each of `has`, how many of it `v` has after its name.
fn things_labels(v : Json?, has : Array[String]) -> Array[String] {
  let counts = field(v, "counts")
  has.map(fn(k) { thing_kind_name(k) + " " + count(counts, k).to_string() })
}

///|
/// The kind shown of `has`: the one chosen (`chosen`) where it has it, else its first.
fn things_kind_of(chosen : String, has : Array[String]) -> String {
  if has.contains(chosen) {
    chosen
  } else {
    has[0]
  }
}

///|
/// A file's, a link's or a pull request's row's name and the line under it (thing_row_node's).
fn thing_words(kind : String, t : Json?) -> (String, String) {
  let ago = text(field(field(t, "time"), "createdAt"), "ago")
  let with_ago = fn(parts : Array[String]) {
    parts.push(ago)
    @sf.join_meta(parts)
  }
  match kind {
    "files" => {
      let f = field(t, "file")
      (text(f, "name"), with_ago([@sf.file_size(number(f, "size")), text(t, "by")]))
    }
    "pulls" => (pull_title(t), pull_meta(t))
    _ => {
      let n = count(t, "count")
      let site = text(t, "site")
      match text(t, "title") {
        "" => (site, with_ago([if n > 1 { "×" + n.to_string() } else { "" }]))
        title => (title, with_ago([site, if n > 1 { "×" + n.to_string() } else { "" }]))
      }
    }
  }
}

///|
/// What pressing a file's, a link's or a pull request's row does (thing_row_node's): a file in the preview, a link and a pull
/// request in the browser.
fn thing_open(r : ChatRef, kind : String, t : Json?) -> Unit {
  if kind == "files" {
    let a = @sfbase.attachment_of(field(t, "file").unwrap_or(Json::object({})))
    @sfbase.open_preview(r.station, if a.owner != "" { a.owner } else { r.session }, a)
  } else {
    @sfbase.open_link(text(t, "url"))
  }
}

///|
/// A thing's 在侧边打开 (thing_menu_at's `beside`): a file's, or a picture's of the chat (`kind` "files", "media"), where
/// it is offered (beside_offered), opened in a tab beside the chat; None for anything else.
fn thing_beside(r : ChatRef, kind : String, t : Json?) -> (() -> Unit)? {
  guard kind == "files" || kind == "media" else { return None }
  let a = @sfbase.attachment_of(field(t, "file").unwrap_or(Json::object({})))
  guard @sfbase.beside_offered(a.path, a.name) else { return None }
  let owner = if a.owner != "" { a.owner } else { r.session }
  Some(fn() { @sfbase.open_preview(r.station, owner, a, beside=true) })
}

///|
/// A picture's or a video's width over its height as its tile shows it: its file's, else its ThumbHash's (own_size's,
/// as the chat's; a square where neither says), kept between things_tallest and things_widest (more and its tile shows
/// a part: a phone's long screenshot its top).
fn media_aspect(t : Json) -> Double {
  let f = field(Some(t), "file")
  let (w, h) = (number(f, "width"), number(f, "height"))
  let a = if w > 0.0 && h > 0.0 {
    w / h
  } else {
    thumb_ratio(text(f, "thumbhash")).unwrap_or(1.0)
  }
  if a < things_tallest {
    things_tallest
  } else if a > things_widest {
    things_widest
  } else {
    a
  }
}

///|
/// Tiles of widths over heights `aspects` laid in lines `room` across, `gap` apart: each line as many as reach across
/// it at `high`, then as high as fills it exactly (no higher than `high`); the last, not reaching, at `high` from the
/// start. Each line's first tile, the one after its last and its height.
fn media_lines(aspects : Array[Double], room : Double, high : Double, gap : Double) -> Array[(Int, Int, Double)] {
  let out = []
  let mut from = 0
  let mut sum = 0.0
  for i, a in aspects {
    sum = sum + a
    let gaps = gap * (i - from).to_double()
    if sum * high + gaps >= room {
      out.push((from, i + 1, (room - gaps) / sum))
      from = i + 1
      sum = 0.0
    }
  }
  if from < aspects.length() {
    out.push((from, aspects.length(), high))
  }
  out
}

///|
/// How far its rows stand in from the tab's sides beside the chat (16, as the letters' messages do: things_side_w), the
/// sheet's words' in a sheet.
// kept across runs: a value (no field of it changes)
let things_side : @ui.Style = @ui.css("px=S4")

///|
let things_side_w : Double = 16.0

///|
/// The kinds and the field over the rest: 12 over, 12 under, 8 apart.
// kept across runs: a value (no field of it changes)
let things_head : @ui.Style = @ui.css("w=Full pt=S3 pb=S3 gap=S2")

///|
// kept across runs: a value (no field of it changes)
let things_kind_alone : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)

///|
/// A line of tiles this high where they reach across it (lower to fit), the tiles this far apart; a tile at most this
/// tall (a phone's screenshot, 9 by 19.5, shows its top) and wide.
let things_line_high : Double = 136.0

///|
let things_gap : Double = 4.0

///|
let things_tallest : Double = 0.56

///|
let things_widest : Double = 2.4

///|
/// A day's heading: 12 over it, 8 to its first message.
// kept across runs: a value (no field of it changes)
let things_day : @ui.Style = @ui.css("w=Full pt=S3 pb=S2")

///|
// kept across runs: a value (no field of it changes)
let things_day_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
/// What a message says over its pictures: 6 over it, 6 to them.
// kept across runs: a value (no field of it changes)
let things_said_line : @ui.Style = @ui.css("w=Full pt=S1_5 pb=S1_5")

///|
// kept across runs: a value (no field of it changes)
let things_said : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let things_said_when : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let things_said_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let things_grid_line : @ui.Style = @ui.css("w=Full pb=S1")

///|
// kept across runs: a value (no field of it changes)
let things_grid_row : @ui.Style = @ui.css("row w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let things_measure : @ui.Style = @ui.css("w=Full")

///|
/// A tile: round as a message's file, the hover's grey under its picture while it comes; pointed at, a shade fainter.
// kept across runs: a value (no field of it changes)
let things_tile : @ui.Style = @ui.style(radius=@sf.message_file_radius, clip=true, bg=Hover).then(@ui.css("hovered{opacity=O85}"))

///|
// kept across runs: a value (no field of it changes)
let things_tile_none : @ui.Style = @ui.css("w=Full h=Full align=ACenter justify=JCenter")

///|
/// A row's room in the list: 2 under it.
// kept across runs: a value (no field of it changes)
let things_line : @ui.Style = @ui.css("w=Full pb=S0_5")

///|
/// A row: 8 by 8 in (its mark at the rows' words' inset less 8), round as an option, the pointer's ground on it; its
/// mark, its two lines and 在对话里看 10 apart.
// kept across runs: a value (no field of it changes)
let things_row : @ui.Style = @ui.css("row w=Full py=S2 pl=S2 pr=S1 gap=S2_5 align=ACenter radius=Xl hovered{bg=Hover} pressed{bg=Hover}")

///|
// kept across runs: a value (no field of it changes)
let things_row_mark : @ui.Style = @ui.css("w=S4 h=S4 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let things_row_words : @ui.Style = @ui.style(w=@sf.grow).then(@ui.css("gap=S0_5"))

///|
// kept across runs: a value (no field of it changes)
let things_row_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let things_row_meta : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let things_found_none : @ui.Style = @ui.css("w=Full py=S3")

///|
// kept across runs: a value (no field of it changes)
let things_none : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let things_more : @ui.Style = @ui.css("row w=Full py=S2 justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let things_foot : @ui.Style = @ui.css("w=Full h=S6")

// The page made once as nodes of the window's tree (things_node: 小屏's sheet, a panel whose body is nodes; 中屏's and
// 大屏's tab beside the chat): what it shows follows the core's `chatThings` as it changes, its rows each made as it
// comes into sight (View::scrolls_window).

///|
/// One of the rows of a chat's page of things made once (things_node's): the kinds and the field over them, words saying
/// none is found, a day's heading, what a message said over its pictures, a line of its pictures (each and how high),
/// a file, a link or a pull request (its kind's), more to come, the room at its foot.
priv enum ThingsRow {
  RowHead
  RowNoneFound
  RowDay(String)
  RowSaid(Json)
  RowTiles(Array[Json], Double)
  RowThing(String, Json)
  RowMore
  RowFoot
}

///|
/// Whether row `b` says what `a` did (a value of the core's the same one, else what it says).
fn things_row_same(a : ThingsRow, b : ThingsRow) -> Bool {
  let json_same = fn(x : Json, y : Json) { physical_equal(x, y) || x == y }
  match (a, b) {
    (RowHead, RowHead) | (RowNoneFound, RowNoneFound) | (RowMore, RowMore) | (RowFoot, RowFoot) => true
    (ThingsRow::RowDay(x), ThingsRow::RowDay(y)) => x == y
    (ThingsRow::RowSaid(x), ThingsRow::RowSaid(y)) => json_same(x, y)
    (RowTiles(x, hx), RowTiles(y, hy)) => {
      if hx != hy || x.length() != y.length() {
        return false
      }
      for i = 0; i < x.length(); i = i + 1 {
        if !json_same(x[i], y[i]) {
          return false
        }
      }
      true
    }
    (RowThing(kx, x), RowThing(ky, y)) => kx == ky && json_same(x, y)
    _ => false
  }
}

///|
/// Whether a list's rows by key `b` are those of `a` (`same` of each row): its keys in order, each row by its key.
fn[R] rows_table_same(
  a : (Array[String], Map[String, R]),
  b : (Array[String], Map[String, R]),
  same : (R, R) -> Bool,
) -> Bool {
  if physical_equal(a, b) {
    return true
  }
  if a.0 != b.0 {
    return false
  }
  for i = 0; i < a.0.length(); i = i + 1 {
    let k = a.0[i]
    match (a.1.get(k), b.1.get(k)) {
      (Some(x), Some(y)) => if !same(x, y) { return false }
      _ => return false
    }
  }
  true
}

///|
/// Chat `r`'s things (its thread `thread`) as nodes of the window's tree in `v`, made once: in a panel's body (小屏's
/// sheet) its sides its words'; `beside` the chat (中屏's and 大屏's tab), 16 in from the tab's (things_side). `away`
/// goes to the chat at a message (the sheet closed first). The kind chosen (told as things_choose chooses another) and
/// the words found by are the chat's page's (things_at), kept as it is left.
pub fn things_node(
  v : @view.View,
  src : Source,
  r : ChatRef,
  thread : Double,
  away : (Double) -> Unit,
  beside? : Bool = false,
) -> Unit {
  let key = r.station + "\u{1}" + r.session
  let at = things_of(key)
  let side = fn() { if beside { things_side } else { @sf.panel_words_in_node(v) } }
  let sides = if beside { things_side_w } else { @sf.panel_words_at_node(v) }
  let value = fn() {
    src.topic("chatThings", things_params(r.station, thread, q=at.field.text())).get().value
  }
  // (the kind chosen, as it is kept for the chat's page: told as another is chosen, here or by things_choose)
  let chosen = at.kind
  let has = fn() { things_has(value()) }
  let kind = fn() {
    let h = has()
    if h.is_empty() {
      ""
    } else {
      things_kind_of(chosen.get(), h)
    }
  }
  v.pick(fn() { things_state(value()) }, fn(p, state) {
    // (filling the room the panel or the tab gives it)
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    match state {
      ThingsWaiting => @sf.waiting_node(p, fn(w) { things_sample_node(w, side) }, fill=true)
      ThingsNone =>
        @sf.empty_node(p, fn(e) {
          @sf.words_node(e, fn() { @sf.t("web-main.things.none") }, fn() { things_none }) |> ignore
        })
      ThingsShown => things_list_node(p, src, r, thread, at, value, has, kind, chosen, side, sides, away)
    }
  })
}

///|
/// The rows' keys `keys` of things of kind `kind`, as things_list_node reads them, `other` said of them: whether they are
/// another kind's in place of the one before (@sf.pg_blocks_read of its things' keys and its kind: another kind came and
/// the one before went), so read again in the same change as it was; a thing come or gone of the same kind (the last one
/// too, its place none found) only came or went.
fn things_kind_read(was : Ref[Set[String]], other : Ref[Bool], keys : Array[String], kind : String) -> Array[String] {
  let set = keys.filter(fn(k) { k.has_prefix("thing/") })
  set.push("kind/" + kind)
  @sf.pg_blocks_read(was, other, set) |> ignore
  keys
}

///|
/// What things_node shows of a chat's things once it has some (`value` as the core has them now, the kinds it `has`,
/// the `kind` shown, `chosen` told as one is chosen), in `p`: its rows in a list, made as they come into sight,
/// `side`'s sides (`sides` points each); at its top again as another kind is chosen.
fn things_list_node(
  p : @view.View,
  src : Source,
  r : ChatRef,
  thread : Double,
  at : ThingsAt,
  value : () -> Json?,
  has : () -> Array[String],
  kind : () -> String,
  chosen : @signals.Signal[String],
  side : () -> @ui.Style,
  sides : Double,
  away : (Double) -> Unit,
) -> Unit {
  // (its rows by the room it is given, filling the room the panel gives it)
  p.by_room(fn(p, given) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    let scroll = @view.Scroll::new()
    // (the room the grid's tiles share across, as the field's box is: the list's less its sides, given it as it is laid
    // out, its rows made by it there)
    let room = fn() { given.width() - 2.0 * sides }
    // (its things' keys and its kind as last read, and whether their last change was another kind shown: its rows
    // another list, there at once; one thing come or gone of the same kind, the last one too, its way: things_kind_read)
    let keys_was : Ref[Set[String]] = Ref(Set([]))
    let kind_other = Ref(false)
    // (its rows by their keys, as the core has its things now, the kind shown, the room the tiles have)
    let table : @signals.Computed[(Array[String], Map[String, ThingsRow])] = @signals.computed_by(fn(_) {
      let v = value()
      let k = kind()
      let keys : Array[String] = []
      let rows : Map[String, ThingsRow] = Map([])
      let put = fn(name : String, row : ThingsRow) {
        keys.push(name)
        rows[name] = row
      }
      put("head", RowHead)
      let shown = items(v, k)
      if shown.length() == 0 {
        put("none", RowNoneFound)
      } else if k == "media" {
        let across = room()
        for di, d in items(v, "mediaDays") {
          let day = Some(d)
          if text(day, "day") != "" {
            put("day/\{di}/" + text(day, "day"), RowDay(text(day, "day")))
          }
          for gi, g in items(day, "groups") {
            let group = Some(g)
            put("said/\{di}/\{gi}", RowSaid(g))
            let tiles = items(group, "items")
            for line in media_lines(tiles.map(media_aspect), across, things_line_high, things_gap) {
              let (from, to, high) = line
              let these = tiles[from:to].to_owned()
              put("tiles/\{di}/\{gi}/\{from}/\{to}/\{high}", RowTiles(these, high))
            }
          }
        }
      } else {
        for t in shown {
          put("thing/" + k + "/" + text(Some(t), "key"), RowThing(k, t))
        }
      }
      // not all of the chat is here yet: more may come, older ones
      if !flag(v, "whole") {
        put("more", RowMore)
      }
      put("foot", RowFoot)
      (keys, rows)
    }, same=fn(a, b) { rows_table_same(a, b, things_row_same) })
    p.scrolls_window(
      scroll,
      fn() { things_kind_read(keys_was, kind_other, table.get().0, kind()) },
      // (a thing come or gone by data makes its way, the list's (View::comes), keyed by the thing; the rest (its head,
      // the days and tiles laid out by the room the tiles have, by where they are among them) there and gone at once, and
      // all of it as another kind is shown)
      comes=fn(name) { !kind_other.val && name.has_prefix("thing/") },
      goes=fn(name) { !kind_other.val && name.has_prefix("thing/") },
      fn(row, name) {
        match @signals.untracked(fn() { table.get().1.get(name) }) {
          Some(RowHead) => things_head_node(row, at, value, has, kind, chosen, side, room)
          Some(RowNoneFound) => {
            @sf.style_node(row, fn() { things_found_none.then(side()) })
            @sf.words_node(row, fn() { @sf.t("web-main.find.none") }, fn() { things_none }) |> ignore
          }
          Some(ThingsRow::RowDay(day)) => things_day_node(row, side, fn() { day })
          Some(ThingsRow::RowSaid(group)) => {
            @sf.style_node(row, fn() { things_said_line.then(side()) })
            media_said_node(row, Some(group))
          }
          Some(RowTiles(tiles, high)) => {
            @sf.style_node(row, fn() { things_grid_line.then(side()) })
            row.box(fn(line) {
              @sf.style_node(line, fn() { things_grid_row })
              for t in tiles {
                media_tile_node(line, src, r, thread, t, media_aspect(t) * high, high, away)
              }
            })
            |> ignore
          }
          Some(RowThing(k, t)) => {
            @sf.style_node(row, fn() { things_line.then(side()) })
            // (as the core has it now: a pull request's card read, its title)
            let tv = fn() {
              match table.get().1.get(name) {
                Some(RowThing(_, now)) => Some(now)
                _ => Some(t)
              }
            }
            thing_row_node(row, src, r, k, tv, away)
          }
          Some(RowMore) => {
            @sf.style_node(row, fn() { things_more })
            @sf.spinner_node(row, size=things_more_spin) |> ignore
          }
          Some(RowFoot) => @sf.style_node(row, fn() { things_foot })
          None => ()
        }
      },
      est=things_row_est,
      slop=@ui.touch_slop(),
      bar=@ui.tree_scroll_bar(),
      // (a thing's row of a kind, and a day's heading, as it no more shows taken by the next of its kind to come to
      // show, its key that one's: not made and let go as the list is scrolled; its kind its key's, which never changes)
      reused=fn(name) {
        match table.untracked().1.get(name) {
          Some(RowThing(k, _)) => thing_kinds.search(k)
          Some(ThingsRow::RowDay(_)) => Some(thing_kinds.length())
          _ => None
        }
      },
      make_reused=fn(row, name) {
        // (what its key is now, the last it was where it is gone from the list: what it shows as it goes)
        let last : Ref[ThingsRow?] = Ref(None)
        let now = fn() {
          match table.get().1.get(name()) {
            Some(r) => {
              last.val = Some(r)
              Some(r)
            }
            None => last.val
          }
        }
        match row.reused_kind() {
          Some(kind_idx) if kind_idx == thing_kinds.length() =>
            things_day_node(row, side, fn() {
              match now() {
                Some(ThingsRow::RowDay(day)) => day
                _ => ""
              }
            })
          Some(kind_idx) if kind_idx >= 0 && kind_idx < thing_kinds.length() => {
            let k = thing_kinds[kind_idx]
            @sf.style_node(row, fn() { things_line.then(side()) })
            thing_row_node(row, src, r, k, fn() {
              match now() {
                Some(RowThing(_, t)) => Some(t)
                _ => None
              }
            }, away)
          }
          _ => ()
        }
      },
    )
    |> ignore
    // (another kind chosen: its list from its top, as a list of its own)
    p.reacts(kind, fn(_) { scroll.put(0.0) })
  })
  .grow(Is(1.0))
  .min_height(Is(Some(0.0)))
  |> ignore
}

///|
/// A day's heading of the media in `row` (things_list_node's), `day` as it is now: `side`'s sides.
fn things_day_node(row : @view.View, side : () -> @ui.Style, day : () -> String) -> Unit {
  @sf.style_node(row, fn() { things_day.then(side()) })
  // (as wide as they are, cut where the row has not the room (things_day_words' w=Cut), as an old view's words in a
  // column are: not stretched across it)
  row.lines_up(Is(Some(@view.Along::Start))) |> ignore
  @sf.words_node(row, day, fn() { things_day_words }) |> ignore
}

///|
/// How tall a row of the list is taken to be till it is laid out, and its spinner's side.
let things_row_est : Double = 48.0

///|
let things_more_spin : Double = 16.0

///|
/// The kinds a chat has to choose from, each with how many, and the field finding among the chosen kind's (the list's
/// first row) in `row`: their choice across the row as the field under it is (a single kind its name alone).
fn things_head_node(
  row : @view.View,
  at : ThingsAt,
  value : () -> Json?,
  has : () -> Array[String],
  kind : () -> String,
  chosen : @signals.Signal[String],
  side : () -> @ui.Style,
  room : () -> Double,
) -> Unit {
  @sf.style_node(row, fn() { things_head.then(side()) })
  // (made again only as how many kinds it has changes, or how wide each is to be: their words as they are now; the
  // web's Segmented (drawn by its list, outside the sheet's narrow arrangement), each
  // option as wide as spans the row as the field under it does)
  row.pick(fn() { (has().length(), @sf.segmented_item_w(room(), has().length())) }, fn(choice, made) {
    let (n, item_w) = made
    if n > 1 {
      choice.row(Is(true)) |> ignore
      choice.box(fn(slot) {
        @sf.seg_node(
          slot,
          fn() { things_labels(value(), has()) },
          fn() { has().search(kind()).unwrap_or(0) },
          fn(i) {
            match @signals.untracked(has).get(i) {
              Some(k) => chosen.set(k)
              None => ()
            }
          },
          item_w~,
        )
        |> ignore
      })
      |> ignore
    } else {
      @sf.words_node(choice, fn() { thing_kind_name(kind()) }, fn() { things_kind_alone }) |> ignore
    }
  })
  row.box(fn(m) {
    @sf.style_node(m, fn() { things_measure })
    @sf.input_node(m, at.field, placeholder=@sf.t("web-main.things.find"), small=true) |> ignore
  })
  |> ignore
}

///|
/// What a message sent its pictures and videos with says in `row`: when and who, then its
/// first words, cut to the line.
fn media_said_node(row : @view.View, group : Json?) -> Unit {
  let when = [text(group, "clock"), text(group, "by")].filter(fn(s) { s != "" })
  row.box(fn(b) {
    @sf.style_node(b, fn() { things_said })
    if when.length() > 0 {
      @sf.words_node(b, fn() { when.join(" · ") }, fn() { things_said_when }).allow_ellipsis(Is(true)) |> ignore
    }
    if text(group, "words") != "" {
      @sf.words_node(b, fn() { text(group, "words") }, fn() { things_said_words }).allow_ellipsis(Is(true)) |> ignore
    }
  })
  |> ignore
}

///|
/// A picture or a video of the chat's in `line`, a tile `w` by `h`: its picture covering it
/// (its top where it is longer than its tile), its likeness till it is here, round as a message's file is; a video's
/// still (the station's, else its first frame drawn here: video_still_node) and its length in its foot corner.
/// Pressed, the preview, a picture stepping through the chat's; held or right clicked, its menu.
fn media_tile_node(
  line : @view.View,
  src : Source,
  r : ChatRef,
  thread : Double,
  t : Json,
  w : Double,
  h : Double,
  away : (Double) -> Unit,
) -> Unit {
  let tv = Some(t)
  let a = @sfbase.attachment_of(field(tv, "file").unwrap_or(Json::object({})))
  let owner = if a.owner != "" { a.owner } else { r.session }
  let video = file_kind(a.name) == "video"
  let thumb = r.station + "/" + owner + "/" + a.path
  // (held off the page as a message's: a light screenshot's is the page's colour)
  let likeness = fn() {
    @gallery.thumbhash_image(a.thumbhash, ground=@sf.theme().p.neutral_bg, under=@sf.theme().p.bg).unwrap_or("")
  }
  // (longer than its tile, by its size or its ThumbHash's: covering it from its top, as wide as it, its likeness too)
  let tall = match own_size(a) {
    Some((aw, ah)) => ah / aw > h / w + things_tall_by
    None => false
  }
  let pressed = fn() { @sfbase.open_preview(r.station, owner, a, steps=InChat(Some(thread), r.session)) }
  let label = @sf.t(if video { "web-main.file.play" } else { "web-main.file.view" }, args=[("name", a.name)])
  @sf.action_box_node(line, fn() { label }, fn(_) { pressed() }, fn(b) {
    // (a video's still: the station's, else its first frame drawn here)
    let picture = if video {
      @sfbase.video_still_node(b, src, r.station, owner, a, thumb)
    } else {
      // (one sent from here: the picture it was picked as, not asked of the station again)
      fn() {
        match @sfbase.sent_picture_told(r.station, a) {
          Some(k) if k != "" && k != "!" => k
          _ => src.file_told(r.station, owner, stored_name(a.path))
        }
      }
    }
    @sf.style_node(b, fn() { things_tile })
    b
    .width(Is(Some(w)))
    .height(Is(Some(h)))
    // (pointed at, a shade fainter: things_tile's hovered)
    .alpha(By(fn() { if @sf.hovered_node(b) { things_tile_lit } else { 1.0 } }))
    .on_menu(fn(m) { thing_menu_at(m.wx, m.wy, number(tv, "seq"), "", away, beside=thing_beside(r, "media", tv)) })
    |> ignore
    @sf.presses_held_node(b, pressed, @ui.long_press_ms, fn(d) {
      thing_held_at(d.wx, d.wy, number(tv, "seq"), "", away, beside=thing_beside(r, "media", tv))
    })
    b.box(fn(i) {
      i
      .width(Is(Some(w)))
      .height(Is(Some(h)))
      .image(By(fn() {
        match picture() {
          "" | "!" => if likeness() != "" { Some((likeness(), "", things_tile_most)) } else { None }
          k => Some((k, likeness(), things_tile_most))
        }
      }))
      // (in its own proportions, never stretched: a long one from its top)
      .image_covers(Is(true))
      .image_covers_at(Is(if tall { Some((0.0, 0.0)) } else { None }))
      // (its picture fading in as it comes, its likeness there at once)
      .image_fades(By(fn() { picture() != "" && picture() != "!" }))
      |> ignore
    })
    |> ignore
    // (none to show: its kind's mark in its middle)
    b.show(fn() { picture() == "!" && likeness() == "" }, fn(n) {
      n.over(Is(true)) |> ignore
      @sf.style_node(n, fn() { things_tile_none })
      @sf.icon_node(n, if video { "file-video" } else { "photo" }, things_tile_mark, By(fn() { @sf.theme().p.muted })) |> ignore
    })
    if video {
      @sf.video_capsule_node(b, a.duration)
    }
  })
  |> ignore
}

///|
/// How much longer than its tile a picture is before its tile shows its top, how faint a tile pointed at
/// is, its mark's side where there is nothing to show, and how many pixels its picture is asked at most.
let things_tall_by : Double = 0.01

///|
let things_tile_lit : Double = 0.85

///|
let things_tile_mark : Double = 20.0

///|
let things_tile_most : Int = 8192

///|
/// A file, a link or a pull request of the chat's in `row`: its mark, what it is called and the
/// line under it, 在对话中查看 at its end; the pointer's ground on it. Pressed, a file opens in the preview, a link and
/// a pull request in the browser; held or right clicked, its menu.
fn thing_row_node(row : @view.View, src : Source, r : ChatRef, kind : String, t : () -> Json?, away : (Double) -> Unit) -> Unit {
  let words = fn() { thing_words(kind, t()) }
  let pressed = fn() { thing_open(r, kind, @signals.untracked(t)) }
  @sf.action_box_node(row, fn() { words().0 }, fn(_) { pressed() }, fn(b) {
    @sf.style_node(b, fn() { things_row })
    b
    .on_menu(fn(m) {
      let tn = @signals.untracked(t)
      thing_menu_at(m.wx, m.wy, number(tn, "seq"), text(tn, "url"), away, beside=thing_beside(r, kind, tn))
    })
    |> ignore
    @sf.hover_ground_node(b)
    // pointed at, a link's card over it, a pull request's as a message's link to it shows it (web_peek_node: at
    // its left, under it it would cover the rows after it)
    if kind != "files" {
      web_peek_node(b, src, r.station, fn() { text(t(), "url") }, fn() { words().0 }, side=Left, peek=fn() { text(t(), "peek") })
    }
    @sf.presses_held_node(b, pressed, @ui.long_press_ms, fn(d) {
      let tn = @signals.untracked(t)
      thing_held_at(d.wx, d.wy, number(tn, "seq"), text(tn, "url"), away, beside=thing_beside(r, kind, tn))
    })
    b.box(fn(m) {
      @sf.style_node(m, fn() { things_row_mark })
      match kind {
        "pulls" =>
          m.box(fn(g) {
            g
            .width(Is(Some(things_mark_side)))
            .height(Is(Some(things_mark_side)))
            .shapes(By(fn() {
              let state = text(t(), "state")
              let (ink, _) = state_colours(state)
              match pr_glyph(state) {
                Some(d) => @ui.vector_shapes(glyph_of(d, ink), things_mark_side, g.pixel_scale())
                None => []
              }
            }))
            |> ignore
          })
          |> ignore
        "files" => @sf.icon_node(m, "file", things_mark_side, By(fn() { @sf.theme().p.muted })) |> ignore
        _ => @sf.icon_node(m, "link", things_mark_side, By(fn() { @sf.theme().p.muted })) |> ignore
      }
    })
    |> ignore
    b.box(fn(w) {
      @sf.style_node(w, fn() { things_row_words }, in_row=true)
      // (its words as wide as they are, cut where it has not the room, as an old view's in a column are: not stretched
      // across it)
      w.lines_up(Is(Some(@view.Along::Start))) |> ignore
      @sf.words_node(w, fn() { words().0 }, fn() { things_row_name }) |> ignore
      w.show(fn() { words().1 != "" }, fn(m) {
        m.lines_up(Is(Some(@view.Along::Start))) |> ignore
        @sf.words_node(m, fn() { words().1 }, fn() { things_row_meta }) |> ignore
      })
    })
    |> ignore
    @sf.icon_button_node(b, "chat", fn() { @sf.t("web-main.things.show") }, fn() { away(number(@signals.untracked(t), "seq")) })
    |> ignore
  })
  |> ignore
}

///|
/// A row's mark's side (thing_row_node's).
let things_mark_side : Double = 16.0

///|
/// Things made up, for what the page shows while they are read in `v`: the kinds' choice
/// and a few rows, `side`'s sides.
fn things_sample_node(v : @view.View, side : () -> @ui.Style) -> Unit {
  v.box(fn(h) {
    @sf.style_node(h, fn() { things_head.then(side()) })
    h.box(fn(line) {
      line.row(Is(true)) |> ignore
      line.box(fn(slot) {
        @sf.segmented_node(slot, fn() { ["media", "files", "links"].map(fn(k) { thing_kind_name(k) + " 0" }) }, fn() { 0 }, fn(_) {  })
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  for n in things_sample_words {
    v.box(fn(l) {
      @sf.style_node(l, fn() { things_line.then(side()) })
      l.box(fn(b) {
        @sf.style_node(b, fn() { things_row })
        b.box(fn(m) {
          @sf.style_node(m, fn() { things_row_mark })
          @sf.icon_node(m, "link", things_mark_side, By(fn() { @sf.theme().p.muted })) |> ignore
        })
        |> ignore
        b.box(fn(w) {
          @sf.style_node(w, fn() { things_row_words }, in_row=true)
          @sf.words_node(w, fn() { @sf.sample_words(n) }, fn() { things_row_name }) |> ignore
          @sf.words_node(w, fn() { @sf.sample_words(things_sample_meta) }, fn() { things_row_meta }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  }
}

///|
/// How many made-up words each of the sample's rows is called (things_sample_node's), and its line under it.
// kept across runs: a value (no field of it changes)
let things_sample_words : Array[Int] = [18, 24, 14, 20, 16]

///|
let things_sample_meta : Int = 10
