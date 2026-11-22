// How a station's files are worked with on the files' page, as a local file browser does (still.fail
// web/src/drive/browse.ts useBrowse): a press chooses (⌘ adds or takes one away, ⇧ the ones between), a double click
// opens, the keys move and act on what is chosen; names are changed where they are. What is chosen, the order, a
// tree's folders open, the columns' widths and where a press or a key goes are the core's (its `driveBrowse` topic and
// `drive.browse`, client/core-ts/src/views/browse.ts): here they are drawn, each part bound to what the core says, and
// what the core answers is done (another folder shown, an entry opened, a name changed in place, a row brought into
// view), all of it in a press's or an answer's handler, outside any build.

///|
/// What a place does with what the core answers, as its page says (BrowseOptions): an entry opened by its kind (a
/// folder gone into, a file read, played, previewed or saved), another folder shown under the root (by its path;
/// `replace`: as the keys go, not a step back each), what is chosen previewed (space), the chosen asked to be deleted.
pub(all) struct BrowseDoes {
  open : (DriveAt, DvEntry) -> Unit
  go : (String, Bool) -> Unit
  preview : (DriveAt, DvEntry) -> Unit
  remove : (Array[(DriveAt, DvEntry)]) -> Unit
}

///|
/// A place as it is held here: its own name to the core (what is chosen is each place's: two sides of the files' page
/// are two), where it last told the core it is, what the core last said of it (kept while another folder is read, as
/// columns keep the choice that opened it), the row whose name is being changed (`folder\nname`) and its field, the row
/// to bring into view (told as it is asked, taken once by the list that shows it).
priv struct BrowsePlace {
  name : String
  mut told : String
  mut last : BrowseView?
  // what a call's answer said is chosen, with what the topic said then: newer than the topic till the topic changes
  mut answered : (Chosen, Chosen)?
  renaming : @signals.Signal[String?]
  mut field : @ui.Field
  show : @signals.Signal[String?]
}

///|
/// The places by the page's key for each (the files' page's sides), named p1, p2… as they come (the same steps give
/// the same names).
// kept across runs: put back by files_reset
let browse_places : Map[String, BrowsePlace] = Map([])

///|
fn browse_place(key : String) -> BrowsePlace {
  match browse_places.get(key) {
    Some(p) => p
    None => {
      let p : BrowsePlace = {
        name: "p\{browse_places.length() + 1}",
        told: "",
        last: None,
        answered: None,
        renaming: @signals.signal(None),
        field: @ui.Field::new(),
        show: @signals.signal(None),
      }
      browse_places[key] = p
      p
    }
  }
}

///|
/// The core's name for the place `key` (a fixture's mode tells it what is chosen there before the first frame).
pub fn place_name(key : String) -> String {
  browse_place(key).name
}

///|
/// A place's folder: by its page's key (its side), the folder it shows and how (as they are now, each read as it is
/// asked: what reads them is told as they change), what may be done there.
pub(all) struct Browse {
  key : String
  owner : String
  view : () -> String
  at : () -> DriveAt
  write : () -> Bool
  does : BrowseDoes
}

///|
/// A row's key among those shown: its folder's path under the root, and its name.
pub fn row_key(folder : String, name : String) -> String {
  folder + "\n" + name
}

///|
/// Where the place is, as its topic and its calls say it.
fn Browse::where_(self : Browse) -> Map[String, Json] {
  let at = (self.at)()
  browse_where(self.owner, browse_place(self.key).name, (self.view)(), at.station, at.root.unwrap_or(""), at.path, write=(self.write)())
}

///|
/// What the place `key` shows at `at` as `view` is, as of where it is told it is: tied to that, never to what is read
/// as it is now (a switch held: browse_switch).
fn browse_here(view : String, at : DriveAt) -> String {
  view + "\n" + at.station + "\n" + at.root.unwrap_or("") + "\n" + at.path
}

///|
/// What the core says of the place now (or last, while it reads another folder or way), read as it changes.
pub fn Browse::shown(self : Browse, src : Source) -> BrowseView? {
  let p = browse_place(self.key)
  match browse_topic(src, self.where_()) {
    Some(v) => {
      p.last = Some(v)
      Some(v)
    }
    None => p.last
  }
}

///|
/// The count the core says of the folder shown, of this topic alone (not a previous folder's kept while the next is
/// read).
pub fn Browse::count_text(self : Browse, src : Source) -> String? {
  match browse_topic(src, self.where_()) {
    Some(v) => v.count_text
    None => None
  }
}

///|
/// The place told the core where it is (`drive.browse` `at`) as that changes, from node `v` (the place's): what is
/// chosen there is then as coming to it chooses, or as columns carry it. Held while a press switched it and waits for
/// what it shows (browse_switch: told then), what that press asked handed over to what reads it here once it is shown.
pub fn Browse::follow(self : Browse, v : @view.View, src : Source) -> Unit {
  let p = browse_place(self.key)
  // (what the core says of the place read from the place's first moment, as it shows: asked before it is told where it
  // is, whatever of it the page comes to read after, as the old view's place asked it as it was built)
  v.reacts(fn() { self.shown(src) is Some(_) }, fn(_) {  }) |> ignore
  v.reacts(fn() {
    let held = browse_held.get().contains(self.owner) || browse_held.get().contains(self.key)
    (browse_here((self.view)(), (self.at)()), held)
  }, fn(now) {
    let (here, held) = now
    if held {
      return
    }
    // (what a press handed over is let go by what reads it, as it reads it (Browse::folder), never here: this follows the
    // switch as it is told, in the frame's end before the switched way is made, which then read anew from nothing what
    // the press had read: a column's folder drawn in its bones and then whole, 400 ms on, over a late core)
    if p.told != here {
      // (a name being changed lets go as another folder is shown)
      if p.told != "" {
        p.renaming.set(None)
      }
      p.told = here
      browse_send(src, self, { "act": "at" })
    }
  })
}

///|
/// Folder `at`'s entries as its station said them and why it could not be read (drive_folder), read by a way of the
/// place's as it is made or read anew: saying so where a press switched it and handed it what that press asked
/// (browse_switch, sfbase's shown_read), let go once the frame that reads it is over, as every page switched in place
/// does where it reads.
pub fn Browse::folder(self : Browse, src : Source, at : DriveAt) -> (Json?, String?) {
  let r = drive_folder(src, at.station, at.root.unwrap_or(""), at.path)
  @sfbase.shown_read("browse/" + self.owner)
  @sfbase.shown_read("browse/" + self.key)
  r
}

///|
/// The places (a place's owner, `page` or `tab`, or one place by its key) switched by a press to show something else
/// whose browsing is read meanwhile (browse_switch): the place shown as it was till then, the core told nothing more of
/// it by what shows it.
// kept across runs: put back by files_reset
let browse_held : @signals.Signal[Map[String, Bool]] = @signals.signal(Map([]))

///|
/// What waits for each place switched (browse_switch), by what holds it.
// kept across runs: put back by files_reset
let browse_waits : Map[String, @sfbase.PressWait] = Map([])

///|
/// A place's way of showing and its folder, as a switch says them (browse_switch's `to`).
pub(all) struct BrowseTo {
  view : String
  at : DriveAt
}

///|
/// The places `sides` show (each as it is, and what it is to show: another folder, another way) switched by a press,
/// held by `hold` (their owner: every place of it; or one's key): the core told at once where each is (`drive.browse`
/// `at`, as the place would once switched), and each kept as it is shown till what it is to show is answered (its
/// browsing so and each folder it draws, `folders` of it and of what its browsing says, None before that is answered:
/// sfbase's switch_answered), then `commit` (what puts them there), told in one frame with what it read handed over to
/// their readers; never a folder or a way drawn in its bones, on either side. Pressed again before that, or what it was
/// pressed in gone, the one before is waited for no more and `let_go` done.
pub fn browse_switch(
  src : Source,
  sides : Array[(Browse, BrowseTo)],
  hold : String,
  folders : (BrowseTo, BrowseView?) -> Array[String],
  commit : () -> Unit,
  let_go? : () -> Unit = fn() {  },
) -> Unit {
  @signals.untracked(fn() {
    browse_switch_off(hold)
    browse_held_put(hold, true)
    let folder = fn(to : BrowseTo, path : String) -> (String, Map[String, Json]) {
      (
        "drive",
        { "station": Json::string(to.at.station), "root": Json::string(to.at.root.unwrap_or("")), "path": Json::string(path) },
      )
    }
    let where_of = fn(b : Browse, to : BrowseTo) {
      browse_where(b.owner, browse_place(b.key).name, to.view, to.at.station, to.at.root.unwrap_or(""), to.at.path, write=(b.write)())
    }
    let asks : Array[(String, Map[String, Json])] = []
    for side in sides {
      let (b, to) = side
      let p = browse_place(b.key)
      p.told = browse_here(to.view, to.at)
      let o = where_of(b, to)
      o["act"] = Json::string("at")
      browse_call(src, b, o)
      asks.push(("driveBrowse", where_of(b, to)))
      for f in folders(to, None) {
        asks.push(folder(to, f))
      }
    }
    // (what each draws of its folders once its browsing says them: a tree's folders opened)
    let then = fn(read : ((String, Map[String, Json])) -> Json?) -> Array[(String, Map[String, Json])] {
      let out = []
      for side in sides {
        let (b, to) = side
        let got = read(("driveBrowse", where_of(b, to)))
        guard got is Some(_) else { continue }
        for f in folders(to, @sfbase.browse_view_of(got)) {
          out.push(folder(to, f))
        }
      }
      out
    }
    let w = @sfbase.switch_answered(
      src,
      asks,
      "browse/" + hold,
      then~,
      fn() {
        browse_waits.remove(hold)
        browse_held_put(hold, false)
        commit()
      },
      let_go=fn() {
        browse_waits.remove(hold)
        browse_held_put(hold, false)
        let_go()
      },
    )
    if w.waiting() {
      browse_waits[hold] = w
    }
  })
}

///|
/// What waits for a switch of `hold` (browse_switch) waited for no more, its place shown as it is.
pub fn browse_switch_off(hold : String) -> Unit {
  match browse_waits.get(hold) {
    Some(w) => {
      browse_waits.remove(hold)
      w.give_up()
    }
    None => ()
  }
}

///|
/// `hold` held (browse_held) or let go.
fn browse_held_put(hold : String, on : Bool) -> Unit {
  let now = browse_held.untracked()
  if now.contains(hold) == on {
    return
  }
  let next = now.copy()
  if on {
    next[hold] = true
  } else {
    next.remove(hold)
  }
  browse_held.set(next)
}

///|
/// What is chosen in the place now.
pub fn Browse::chosen(self : Browse, src : Source) -> Chosen {
  match self.shown(src) {
    Some(v) => v.chosen
    None => chosen_none()
  }
}

///|
/// How the device orders a folder's entries (by name where the core has not said).
pub fn Browse::arrangement(self : Browse, src : Source) -> Arrangement {
  match self.shown(src) {
    Some(v) => v.arrangement
    None => arrangement_none()
  }
}

///|
/// The folder `folder`'s entries in the order shown, as the core says them; None while it has not.
pub fn Browse::arranged(self : Browse, src : Source, folder : String) -> Array[DvEntry]? {
  let at = (self.at)()
  let entries = dv_entries(src, at.station, at.root.unwrap_or(""), folder).unwrap_or([])
  match self.shown(src) {
    Some(v) => @sfbase.dv_in_order_held(self.key + "|" + folder, v.folders.get(folder), entries)
    None => None
  }
}

///|
/// Whether a tree's folder is open.
pub fn Browse::is_open(self : Browse, src : Source, path : String) -> Bool {
  match self.shown(src) {
    Some(v) => v.open.contains(path)
    None => false
  }
}

///|
/// A column's width dragged (None: as every column is).
pub fn Browse::width_of(self : Browse, src : Source, path : String) -> Double? {
  match self.shown(src) {
    Some(v) => v.widths.get(path)
    None => None
  }
}

///|
pub fn Browse::is_chosen(self : Browse, src : Source, folder : String, name : String) -> Bool {
  let ch = self.chosen(src)
  ch.folder == folder && ch.names.contains(name)
}

///|
/// The row whose name is being changed (`folder\nname`), read as it changes.
pub fn Browse::renaming(self : Browse) -> String? {
  browse_place(self.key).renaming.get()
}

///|
/// The row whose name is being changed now, as it is (not followed).
pub fn Browse::renaming_now(self : Browse) -> String? {
  browse_place(self.key).renaming.untracked()
}

///|
/// A folder's entries as its station said them (held), by its path under the root.
fn Browse::held(self : Browse, src : Source, folder : String) -> Array[DvEntry] {
  let at = (self.at)()
  dv_entries(src, at.station, at.root.unwrap_or(""), folder).unwrap_or([])
}

///|
fn Browse::entry_of(self : Browse, src : Source, folder : String, name : String) -> DvEntry? {
  self.held(src, folder).iter().find_first(fn(e) { e.name == name })
}

///|
fn Browse::at_of(self : Browse, folder : String) -> DriveAt {
  let at = (self.at)()
  { station: at.station, root: at.root, path: folder }
}

///|
/// What the core answers done (Done): another folder shown, an entry opened, previewed, renamed or deleted, a row in
/// view.
fn browse_after(src : Source, b : Browse, done : Json) -> Unit {
  let d = Some(done)
  let p = browse_place(b.key)
  // (what is chosen as the core answered it: its topic tells it a little later, and a menu opened meanwhile is about it)
  match field(d, "chosen") {
    // (with what its topic last said, as the page last read it: never read here, where nothing may hold it any more)
    Some(Object(_)) as ch =>
      p.answered = Some((@sfbase.chosen_of(ch), match p.last { Some(v) => v.chosen; None => chosen_none() }))
    _ => ()
  }
  match field(d, "go") {
    Some(Object(_)) as g => (b.does.go)(text(g, "path"), flag(g, "replace"))
    _ => ()
  }
  let entry = fn(s : Json?) -> Array[(DriveAt, DvEntry)] {
    match b.entry_of(src, text(s, "folder"), text(s, "name")) {
      Some(e) => [(b.at_of(text(s, "folder")), e)]
      None => []
    }
  }
  match field(d, "open") {
    Some(Object(_)) as s => for x in entry(s) { (b.does.open)(x.0, x.1) }
    _ => ()
  }
  match field(d, "preview") {
    Some(Object(_)) as s => for x in entry(s) { (b.does.preview)(x.0, x.1) }
    _ => ()
  }
  match field(d, "rename") {
    Some(Object(_)) as s => browse_rename_start(b, text(s, "folder"), text(s, "name"), flag(s, "dir"))
    _ => ()
  }
  match field(d, "remove") {
    Some(Array(list)) => {
      let all : Array[(DriveAt, DvEntry)] = []
      for s in list {
        all.push_iter(entry(Some(s)).iter())
      }
      (b.does.remove)(all)
    }
    _ => ()
  }
  match field(d, "show") {
    Some(Object(_)) as s => p.show.set(Some(row_key(text(s, "folder"), text(s, "name"))))
    _ => ()
  }
}

///|
/// `drive.browse` asked of the place (`o`: its where with what is asked), what it answers done.
fn browse_call(src : Source, b : Browse, o : Map[String, Json]) -> Unit {
  (src.call)("drive.browse", Json::object(o), fn(r) {
    match r {
      Ok(Object(_) as done) => browse_after(src, b, done)
      _ => ()
    }
  })
}

///|
/// `drive.browse` asked of the place (its where as it is now, and `params`), what it answers done.
fn browse_send(src : Source, b : Browse, params : Map[String, Json]) -> Unit {
  let o = @signals.untracked(fn() { b.where_() })
  for k, v in params {
    o[k] = v
  }
  browse_call(src, b, o)
}

///|
/// A press on a row (a click: ⌘ and ⇧ as Finder has them, held as it was pressed).
pub fn Browse::press(self : Browse, src : Source, folder : String, name : String) -> Unit {
  let held = @ui.mods_held()
  browse_send(src, self, {
    "act": "press",
    "folder": Json::string(folder),
    "name": Json::string(name),
    "mod": Json::boolean((held & (@ui.mod_cmd | @ui.mod_ctrl)) != 0),
    "shift": Json::boolean((held & @ui.mod_shift_key) != 0),
  })
}

///|
/// Chosen and nothing else, unless it is among what is (a right click on a row).
pub fn Browse::choose(self : Browse, src : Source, folder : String, name : String) -> Unit {
  browse_send(src, self, { "act": "menu", "folder": Json::string(folder), "name": Json::string(name) })
}

///|
/// What is chosen, if `entry` is among it; else `entry` alone (what a menu or a drag of that row is about).
pub fn Browse::chosen_with(self : Browse, src : Source, folder : String, e : DvEntry) -> Array[(DriveAt, DvEntry)] {
  let said = self.chosen(src)
  // (as the core last answered, where its topic has not told anything since)
  let ch = match browse_place(self.key).answered {
    Some((answered, then)) if then == said => answered
    _ => said
  }
  if ch.folder == folder && ch.names.contains(e.name) && ch.names.length() > 1 {
    let out : Array[(DriveAt, DvEntry)] = []
    for n in ch.names {
      match self.entry_of(src, folder, n) {
        Some(x) => out.push((self.at_of(folder), x))
        None => ()
      }
    }
    return out
  }
  [(self.at_of(folder), e)]
}

///|
/// Nothing chosen (a press where there is no row).
pub fn Browse::clear(self : Browse, src : Source) -> Unit {
  if @signals.untracked(fn() { self.chosen(src).names.length() }) > 0 {
    browse_send(src, self, { "act": "clear" })
  }
}

///|
/// A folder of the tree opened or closed (its disclosure).
pub fn Browse::toggle(self : Browse, src : Source, path : String) -> Unit {
  browse_send(src, self, { "act": "tree", "folder": Json::string(path) })
}

///|
/// A column's width dragged, kept (`path` its folder's).
pub fn Browse::keep_width(self : Browse, src : Source, path : String, px : Double) -> Unit {
  let o = @signals.untracked(fn() { self.where_() })
  o["path"] = Json::string(path)
  o["act"] = Json::string("width")
  o["width"] = Json::number(px)
  browse_call(src, self, o)
}

///|
/// Every column as wide as the rest again.
pub fn Browse::forget_widths(self : Browse, src : Source) -> Unit {
  browse_send(src, self, { "act": "widths" })
}

///|
/// The order and whether hidden files show, changed (`drive.arrange`).
pub fn Browse::arrange_as(self : Browse, src : Source, by? : String, down? : Bool, hidden? : Bool) -> Unit {
  ignore(self)
  dv_arrange(src, by?, down?, hidden?)
}

///|
/// (its field holding the name, picked but its extension: NameField's onFocus)
fn browse_rename_start(b : Browse, folder : String, name : String, dir : Bool) -> Unit {
  let p = browse_place(b.key)
  let f = @ui.Field::new()
  f.set(name)
  let dot = match name.rev_find(".") {
    Some(i) if i > 0 && !dir => i
    _ => name.length()
  }
  f.pick(0, dot)
  p.field = f
  p.renaming.set(Some(row_key(folder, name)))
}

///|
/// A row's name changed in place from here (its menu's 重命名): chosen, its field shown.
pub fn Browse::start_rename(self : Browse, src : Source, folder : String, e : DvEntry) -> Unit {
  browse_send(src, self, { "act": "choose", "folder": Json::string(folder), "name": Json::string(e.name) })
  browse_rename_start(self, folder, e.name, e.dir)
}

///|
/// The field a name is changed in (the row's whose name it is).
pub fn Browse::rename_field(self : Browse) -> @ui.Field {
  browse_place(self.key).field
}

///|
/// The name being changed done (None: left as it was): the station asked, chosen under its new name as soon as it
/// has it; what is wrong with the name said.
pub fn Browse::rename(self : Browse, src : Source, folder : String, e : DvEntry, to : String?) -> Unit {
  let p = browse_place(self.key)
  p.renaming.set(None)
  let name = match to {
    Some(t) => t.trim(chars=" \t\n").to_owned()
    None => return
  }
  if name == "" || name == e.name {
    return
  }
  let what = @sf.t("web-pages.drive.renameWhat")
  let at = @signals.untracked(self.at)
  // (a name it may not have refused, in the core's words)
  dv_check_name(src, name, fn(problem) {
    match problem {
      Some(p) => toast_later(@sf.t("web-main.act.failed", args=[("what", what), ("error", p)]))
      None =>
        (src.call)(
          "drive.rename",
          {
            "station": Json::string(at.station),
            "root": Json::string(at.root.unwrap_or("")),
            "from": Json::string(dv_join(folder, e.name)),
            "to": Json::string(dv_join(folder, name)),
          },
          fn(r) {
            match r {
              Ok(_) => browse_send(src, self, { "act": "choose", "folder": Json::string(folder), "name": Json::string(name) })
              Err(err) => toast_later(@sf.t("web-main.act.failed", args=[("what", what), ("error", dv_error(err))]))
            }
          },
        )
    }
  })
}

///|
/// A new folder in `folder`, named as Finder does (`drive.name`: 未命名文件夹, 未命名文件夹 2…), its name then changed
/// in place.
pub fn Browse::new_folder(self : Browse, src : Source, folder : String) -> Unit {
  let what = @sf.t("web-pages.drive.mkdirWhat")
  let failed = fn(err : Json) { toast_later(@sf.t("web-main.act.failed", args=[("what", what), ("error", dv_error(err))])) }
  let at = @signals.untracked(self.at)
  let root = at.root.unwrap_or("")
  (src.call)(
    "drive.name",
    {
      "name": Json::string(@sf.t("web-pages.drive.untitledFolder")),
      "station": Json::string(at.station),
      "root": Json::string(root),
      "path": Json::string(folder),
    },
    fn(r) {
      match r {
        Ok(v) => {
          let name = text(Some(v), "name")
          (src.call)(
            "drive.mkdir",
            { "station": Json::string(at.station), "root": Json::string(root), "path": Json::string(dv_join(folder, name)) },
            fn(r) {
              match r {
                Ok(_) => {
                  browse_send(src, self, { "act": "choose", "folder": Json::string(folder), "name": Json::string(name) })
                  browse_rename_start(self, folder, name, true)
                  browse_place(self.key).show.set(Some(row_key(folder, name)))
                }
                Err(err) => failed(err)
              }
            },
          )
        }
        Err(err) => failed(err)
      }
    },
  )
}

///|
/// The row to bring into view (told as it is asked), read as it changes.
pub fn Browse::to_show(self : Browse) -> String? {
  browse_place(self.key).show.get()
}

///|
/// The row to bring into view, taken (the list that showed it did so).
pub fn Browse::shown_done(self : Browse) -> Unit {
  browse_place(self.key).show.set(None)
}

///|
/// A key as the core names it (its `keys`): `mod+` before it with ⌘ or Ctrl held, a letter in small; ⌘⇧. its own.
fn key_name(code : Int, mods : Int) -> String? {
  let m = (mods & (@ui.mod_cmd | @ui.mod_ctrl)) != 0
  let shift = (mods & @ui.mod_shift_key) != 0
  if m && shift && (code == @ui.key_of_char('.') || code == @ui.key_of_char('>')) {
    return Some("mod+shift+Period")
  }
  let k = if code == @ui.key_code_down {
    "ArrowDown"
  } else if code == @ui.key_code_up {
    "ArrowUp"
  } else if code == @ui.key_code_home {
    "Home"
  } else if code == @ui.key_code_end {
    "End"
  } else if code == @ui.key_code_right {
    "ArrowRight"
  } else if code == @ui.key_code_left {
    "ArrowLeft"
  } else if code == @ui.key_code_enter {
    "Enter"
  } else if code == @ui.key_escape {
    "Escape"
  } else if code == @ui.key_code_backspace {
    "Backspace"
  } else if code == @ui.key_code_delete {
    "Delete"
  } else if code >= 1000 {
    let ch = (code - 1000).unsafe_to_char()
    let lower = if ch >= 'A' && ch <= 'Z' { (ch.to_int() + 32).unsafe_to_char() } else { ch }
    lower.to_string()
  } else {
    return None
  }
  Some(if m { "mod+" + k } else { k })
}

///|
/// A key pressed where the rows are (the page's, anywhere on it but a field): one that does something here now is the
/// rows' (the core says which), taken; a letter goes to a name starting with it. True where it was taken.
pub fn Browse::key(self : Browse, src : Source, code : Int, mods : Int) -> Bool {
  if browse_place(self.key).renaming.untracked() is Some(_) {
    return false
  }
  let acts = match @signals.untracked(fn() { self.shown(src) }) {
    Some(v) => v.keys
    None => []
  }
  match key_name(code, mods) {
    Some(name) if acts.contains(name) => {
      let shift = (mods & @ui.mod_shift_key) != 0
      browse_send(src, self, { "act": "key", "key": Json::string(name), "shift": Json::boolean(shift) })
      true
    }
    Some(_) if (mods & (@ui.mod_cmd | @ui.mod_ctrl | @ui.mod_alt)) == 0 && code >= 1000 && code != @ui.key_space => {
      let letter = (code - 1000).unsafe_to_char().to_string()
      browse_send(src, self, { "act": "type", "letter": Json::string(letter) })
      true
    }
    _ => false
  }
}

///|
/// What the browsing kept forgets (a run anew).
pub fn files_reset() -> Unit {
  files_arrived.val = ""
  browse_places.clear()
  for _, w in browse_waits {
    w.end()
  }
  browse_waits.clear()
  browse_held.set(Map([]))
  files_kept_pages.clear()
  station_places_got.clear()
  station_places_asked.clear()
  refreshing_now.clear()
  dialogs_reset()
  go_reset()
  pane_reset()
  ndrag_reset()
  views_held_reset()
  places_reset()
}
