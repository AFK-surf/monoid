// What the files' pages (文件, a station's drive: files_page_node.mbt) keep and do, with no view of their own: the
// folders a person keeps at hand (个人收藏, of any station; old station-pinned folders join the same list: removing one
// hides it on this device without changing the station's settings or another member's access), the folder last open
// in a workspace's files' page (the rail's 文件 comes back to it), each station's places as its drive offers them, and
// what a press does to an entry (opened as its kind wants, downloaded, shared, deleted, its path copied), each done in
// the press's handler, outside any build.

using @sfbase {
  type DvStation,
  type DvEntry,
  type DvRoot,
  type DvRights,
  type DvUpload,
  type Arrangement,
  type Chosen,
  type BrowseView,
  type FilesTabs,
  type FilesTab,
  dv_join,
  dv_name,
  dv_parent,
  dv_absolute,
  dv_root_label,
  dv_stations,
  dv_rights,
  dv_error,
  dv_kind_icon,
  dv_entries,
  dv_words,
  dv_trouble,
  dv_file,
  dv_pump,
  dv_arrange,
  dv_check_name,
  browse_topic,
  browse_where,
  files_tabs,
  files_tabs_act,
  same_pane,
  download_of_drive,
  open_drive_file,
  chosen_none,
  arrangement_none,
}

// ── 个人收藏 ──

///|
/// A folder kept at hand: its station, root, path under it, and its name.
#derive(Eq)
pub(all) struct Favorite {
  station : String
  root : String
  path : String
  name : String
}

///|
/// At most this many.
let favorites_most : Int = 40

///|
/// A list of places kept in a preference (what does not hold together let go).
fn favorites_read(src : Source, ws : String, key : String) -> Array[Favorite] {
  let raw = text(field(src.topic("prefs", {}).get().value, key), ws)
  let out : Array[Favorite] = []
  match (@json.parse(raw) catch { _ => Json::null() }) {
    Array(list) =>
      for f in list {
        let f = Some(f)
        let all = ["station", "root", "path", "name"].iter().all(fn(k) { field(f, k) is Some(String(_)) })
        if all {
          let kept : Favorite = { station: text(f, "station"), root: text(f, "root"), path: text(f, "path"), name: text(f, "name") }
          if !favorite_has(out, kept.station, kept.root, kept.path) {
            out.push(kept)
          }
        }
      }
    _ => ()
  }
  out
}

///|
/// The workspace's favorites and its old pinned places, each folder once. A removed old pin stays out even if the
/// station becomes available later; its configuration is never changed by this list.
pub fn favorites(src : Source, ws : String) -> Array[Favorite] {
  favorites_in(src, ws, dv_stations(src, ws).0.unwrap_or([]))
}

///|
/// The same list using stations already read by its caller.
pub fn favorites_in(src : Source, ws : String, stations : Array[DvStation]) -> Array[Favorite] {
  let out = favorites_read(src, ws, "driveFavorites")
  let hidden = favorites_read(src, ws, "driveFavoritesHidden")
  for s in stations {
    for r in s.roots {
      if !favorite_has(out, s.station, r.path, "") && !favorite_has(hidden, s.station, r.path, "") {
        out.push({ station: s.station, root: r.path, path: "", name: if r.name == "" { dv_root_label([], r.path) } else { r.name } })
      }
    }
  }
  out
}

///|
fn favorites_json(list : Array[Favorite]) -> String {
  let kept = list.map(fn(f) -> Json {
    { "station": Json::string(f.station), "root": Json::string(f.root), "path": Json::string(f.path), "name": Json::string(f.name) }
  })
  Json::array(kept).stringify()
}

///|
fn favorites_keep(src : Source, ws : String, list : Array[Favorite], hidden : Array[Favorite]) -> Unit {
  let kept = if list.length() > favorites_most { list[:favorites_most].to_owned() } else { list }
  let favorites : Map[String, Json] = Map([])
  let removed : Map[String, Json] = Map([])
  favorites[ws] = Json::string(favorites_json(kept))
  removed[ws] = Json::string(favorites_json(hidden))
  (src.call)("prefs.set", { "driveFavorites": Json::object(favorites), "driveFavoritesHidden": Json::object(removed) }, @sfbase.answer_unread)
}

///|
/// A folder's absolute path for comparing places: a Windows root's separators and case are interchangeable, while a
/// backslash in a Unix name is a name, not a separator. Keep the stored root and path for reaching the folder.
pub fn favorite_path(root : String, path : String) -> String {
  let abs = dv_absolute(root, path)
  let abs = if @sfbase.dv_windows_path(root) { abs.replace_all(old="\\", new="/").to_lower() } else { abs }
  if abs == "/" { abs } else { abs.trim_end(chars="/").to_owned() }
}

///|
/// Two ways to the same folder on a station (a shared root and the same folder reached from its parent).
pub fn favorite_same_path(root : String, path : String, other_root : String, other_path : String) -> Bool {
  favorite_path(root, path) == favorite_path(other_root, other_path)
}

///|
/// Whether the folder (`station`, `root`, `path`) is among them, whatever root it was reached under.
pub fn favorite_has(list : Array[Favorite], station : String, root : String, path : String) -> Bool {
  for i = 0; i < list.length(); i = i + 1 {
    let f = list[i]
    if f.station == station && favorite_same_path(f.root, f.path, root, path) {
      return true
    }
  }
  false
}

///|
/// One kept (after those kept, unless it is among them).
pub fn favorite_add(src : Source, ws : String, f : Favorite) -> Unit {
  let list = favorites_read(src, ws, "driveFavorites")
  let hidden = favorites_read(src, ws, "driveFavoritesHidden").filter(fn(x) {
    !(x.station == f.station && favorite_same_path(x.root, x.path, f.root, f.path))
  })
  if !favorite_has(list, f.station, f.root, f.path) {
    list.push(f)
  }
  favorites_keep(src, ws, list, hidden)
}

///|
/// One let go.
pub fn favorite_remove(src : Source, ws : String, station : String, root : String, path : String) -> Unit {
  let list = favorites_read(src, ws, "driveFavorites").filter(fn(f) { !(f.station == station && favorite_same_path(f.root, f.path, root, path)) })
  let hidden = favorites_read(src, ws, "driveFavoritesHidden")
  if !favorite_has(hidden, station, root, path) {
    hidden.push({ station, root, path, name: "" })
  }
  favorites_keep(src, ws, list, hidden)
}

// ── what the files keep as they are left (for the app's run, not stored) ──

///|
/// The files' page last open, by workspace. How far each folder was scrolled is its list's own; what was last opened
/// in each folder, a tree's folders open and a column's width are the core's (`drive.browse`: keep_opened tells it).
// kept across runs: put back by files_reset
let files_kept_pages : Map[String, DriveAt] = Map([])

///|
/// What was opened in the folder at `at` (a folder gone into, a file), by its name: chosen as it is shown again.
pub fn keep_opened(src : Source, owner : String, at : DriveAt, name : String) -> Unit {
  (src.call)(
    "drive.browse",
    {
      "act": "opened",
      "owner": Json::string(owner),
      "station": Json::string(at.station),
      "root": Json::string(at.root.unwrap_or("")),
      "path": Json::string(at.path),
      "name": Json::string(name),
    },
    @sfbase.answer_unread,
  )
}

///|
/// The files' page last open in workspace `ws`.
pub fn last_files_page(ws : String) -> DriveAt? {
  files_kept_pages.get(ws)
}

///|
pub fn keep_files_page(ws : String, at : DriveAt) -> Unit {
  files_kept_pages[ws] = at
}

// ── the stations and their places ──

///|
/// The workspace's stations with a drive as the files' page lists them everywhere (the sidebar, ⌘⇧G, a station's
/// button): this machine's first (`stations {scope, drive: true, here}`, the one topic each of them reads).
pub fn drive_stations(src : Source, ws : String) -> (Array[DvStation]?, String?) {
  @sfbase.dv_drive_stations(src, ws, here=this_machine())
}

///|
/// The station this machine is said to be, in place of its host's (a made-up app's: the fixtures show no real
/// machine's).
pub fn set_this_machine(station : String) -> Unit {
  @sfbase.machine_here.val = Some(station)
}

///|
/// Where a station's drive starts for its viewer: its home for one who browses everywhere, else the first folder it
/// pins.
pub fn drive_start(s : DvStation) -> String? {
  if s.anywhere && s.home != "" {
    Some(s.home)
  } else {
    match s.roots.get(0) {
      Some(r) => Some(r.path)
      None => None
    }
  }
}

///|
/// The places a station's drive offers one who browses everywhere (its home, the home's own folders, its disks: each
/// its name, path, whether a disk), by station once read; which were asked.
// kept across runs: put back by files_reset
let station_places_got : @sf.LiveMap[String, Array[(String, String, Bool)]] = @sf.LiveMap::new()

///|
// kept across runs: put back by files_reset
let station_places_asked : Map[String, Bool] = Map([])

///|
/// Station `s`'s places (station_places_got's), asked of the core the first time (`drive.folders`), outside what reads
/// them; None while they are read.
pub fn station_places_read(src : Source, s : DvStation) -> Array[(String, String, Bool)]? {
  if !station_places_asked.contains(s.station) {
    station_places_asked[s.station] = true
    @signals.untracked(fn() {
      (src.call)("drive.folders", { "station": Json::string(s.station), "path": Json::null() }, fn(r) {
        station_places_got.put(s.station, match r {
          Ok(v) =>
            items(Some(v), "places").map(fn(p) {
              let p = Some(p)
              (text(p, "name"), text(p, "path"), flag(p, "disk"))
            })
          Err(_) => []
        })
      })
    })
  }
  station_places_got.get(s.station)
}

///|
/// A station's name, as the workspace's stations list has it (its address while not known).
pub fn station_name(src : Source, station : String) -> String {
  let ws = match station.find("/") {
    Some(i) => station.exact_view(end=i).to_owned()
    None => station
  }
  match dv_stations(src, ws).0 {
    Some(list) =>
      match list.iter().find_first(fn(s) { s.station == station }) {
        Some(s) => s.name
        None => station
      }
    None => station
  }
}

///|
/// The folder's name: its last part; the root by its name as the station lends it, the home as 主目录 for one who
/// browses every folder.
pub fn folder_name(st : DvStation, at : DriveAt) -> String {
  let root = at.root.unwrap_or("")
  if at.path != "" {
    dv_name(at.path)
  } else if st.anywhere && !st.roots.iter().any(fn(r) { r.path == root }) {
    if root == st.home {
      @sf.t("web-pages.drive.home")
    } else {
      dv_root_label([], root)
    }
  } else {
    dv_root_label(st.roots, root)
  }
}

///|
/// A pane's folder (its last part; a root pinned by its name, the home as 主目录) and its station's name (paneParts).
pub fn pane_parts(p : DriveAt, stations : Array[DvStation]) -> (String, String) {
  let root = p.root.unwrap_or("")
  let mut found : DvStation? = None
  for i = 0; i < stations.length(); i = i + 1 {
    if stations[i].station == p.station {
      found = Some(stations[i])
      break
    }
  }
  match found {
    Some(s) => {
      let folder = if p.path != "" {
        dv_name(p.path)
      } else if root == s.home && !s.roots.iter().any(fn(r) { r.path == root }) {
        @sf.t("web-pages.drive.home")
      } else {
        dv_root_label(s.roots, root)
      }
      (folder, s.name)
    }
    None => (if p.path != "" { dv_name(p.path) } else { dv_name(root) }, "")
  }
}

///|
/// A folder's entries as its station said them, and why it could not be read: read by what reads it (a node's binding),
/// let go of with it, at rest as it rests (a page covered on its stack).
pub fn drive_folder(src : Source, station : String, root : String, path : String) -> (Json?, String?) {
  drive_folder_of(src.topic("drive", drive_folder_where(station, root, path)).get().snapshot())
}

///|
/// The same, held for the drive's pages till none is left on the stack (sfbase's drive_scope, let go of then): for
/// what reads it outside a node's binding (what is let go on a folder no page shows, an old view's tab).
pub fn drive_folder_held(src : Source, station : String, root : String, path : String) -> (Json?, String?) {
  drive_folder_of(@sfbase.hold(src, @sfbase.drive_scope, "drive", drive_folder_where(station, root, path)).get().snapshot())
}

///|
fn drive_folder_where(station : String, root : String, path : String) -> Map[String, Json] {
  { "station": Json::string(station), "root": Json::string(root), "path": Json::string(path) }
}

///|
fn drive_folder_of(t : @sfbase.Topic) -> (Json?, String?) {
  (
    t.value,
    match t.error {
      Some(e) => Some(dv_error(e))
      None => None
    },
  )
}

// ── what a press does to an entry ──

///|
/// What opens an entry, by its kind (drive/model.ts openerOf): a folder gone into, read, played, previewed, saved.
pub fn opener_of(kind : String) -> String {
  match kind {
    "folder" => "folder"
    "text" | "markdown" => "read"
    "video" | "audio" => "play"
    "image" | "pdf" | "code" | "csv" | "html" | "subtitle" => "preview"
    _ => "save"
  }
}

///|
/// What a change set going said should it fail (useAct): 没能{what}：{error} in the toast; `done` once done.
pub fn act_said(what : String, done? : String = "") -> (Result[Json, Json]) -> Unit {
  fn(r) {
    match r {
      Ok(_) => if done != "" { toast_later(done) }
      Err(e) => toast_later(@sf.t("web-main.act.failed", args=[("what", what), ("error", dv_error(e))]))
    }
  }
}

///|
/// A path copied, said so.
pub fn copy_path(abs : String) -> Unit {
  @ui.clipboard_set(abs)
  toast_later(@sf.t("web-pages.drive.pathCopied"))
}

///|
/// The folders being read again (drive.refresh), by station, root and path: one at a time each.
// kept across runs: put back by files_reset
let refreshing_now : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()

///|
/// The folder read again (drive.refresh), once at a time: the core reads it of the station and says the folder's
/// topic (`drive`, by its station, root and path) anew, what is in it or why it could not be read, to what holds it.
pub fn refresh_folder(src : Source, at : DriveAt) -> Unit {
  let root = at.root.unwrap_or("")
  let key = at.station + "\n" + root + "\n" + at.path
  if refreshing_now.contains(key) {
    return
  }
  refreshing_now.put(key, true)
  (src.call)(
    "drive.refresh",
    { "station": Json::string(at.station), "root": Json::string(root), "path": Json::string(at.path) },
    fn(r) {
      refreshing_now.remove(key)
      (act_said(@sf.t("web-pages.drive.refreshWhat")))(r)
    },
  )
}

///|
/// Whether the folder is being read again.
pub fn refreshing(at : DriveAt) -> Bool {
  refreshing_now.contains(at.station + "\n" + at.root.unwrap_or("") + "\n" + at.path)
}

///|
/// A file of the drive downloaded (a folder zipped first).
pub fn save_entry(src : Source, at : DriveAt, e : DvEntry) -> Unit {
  let root = at.root.unwrap_or("")
  let path = dv_join(at.path, e.name)
  if e.dir {
    @sfbase.download_start_zip(src, at.station, root, path, e.name + ".zip")
  } else {
    toast_later(@sf.t("android-misc.drive.downloading", args=[("name", e.name)]))
    @sfbase.download_start_drive(src, at.station, root, path, e.name, e.size, e.mtime)
  }
}

///|
/// A file of the drive handed to another app (分享): read through the core a part at a time, how far on its row
/// meanwhile (drive_fetch), then the system's share sheet; said when nothing takes it.
pub fn share_entry(src : Source, at : DriveAt, e : DvEntry) -> Unit {
  let root = at.root.unwrap_or("")
  let all = Buffer(capacity=if e.size > 0.0 { e.size.to_int() } else { 0 })
  @sfbase.drive_fetch(
    src,
    at.station,
    root,
    dv_join(at.path, e.name),
    fn(b) {
      all.write_bytesview(b)
      true
    },
    fn(err) {
      match err {
        None =>
          if !@ui.share("", e.name, e.mime, all.to_bytes()) {
            toast_later(@sf.t("android-misc.drive.noApp"))
          }
        Some(err) => toast_later(@sf.t("android-misc.drive.fetchFailed", args=[("name", e.name), ("error", dv_error(err))]))
      }
    },
    listed=Some((e.mtime, e.size)),
  )
}

///|
/// An entry of the folder `in_` opened as its kind wants (FolderView openIn): a folder gone into, a text read, a video
/// played, a picture or code previewed (with the pictures beside it, `near`), the rest downloaded; kept as what was
/// last opened there.
pub fn open_entry(src : Source, owner : String, in_ : DriveAt, e : DvEntry, near : Array[DvEntry], go : (DriveAt) -> Unit) -> Unit {
  let root = in_.root.unwrap_or("")
  let full = dv_join(in_.path, e.name)
  keep_opened(src, owner, in_, e.name)
  match opener_of(if e.dir { "folder" } else { e.kind }) {
    "folder" => go({ ..in_, path: full })
    "read" => open_page(DriveRead({ station: in_.station, root: Some(root), path: full }))
    "play" => open_page(DrivePlay({ station: in_.station, root: Some(root), path: full }))
    "preview" => {
      let pictures = if e.kind == "image" {
        near.filter(fn(x) { x.kind == "image" }).map(fn(x) { dv_file(in_.station, root, in_.path, x) })
      } else {
        []
      }
      open_drive_file(dv_file(in_.station, root, in_.path, e), pictures)
    }
    _ => save_entry(src, in_, e)
  }
}

///|
/// A drive's row's 在侧边打开 (`e` in `in_`): a file the preview shows, where it is offered (beside_offered: a side panel
/// for the page in view, a kind that opens there), opened in a tab beside it; None for anything else.
pub fn entry_beside(in_ : DriveAt, e : DvEntry) -> (() -> Unit)? {
  guard !e.dir && opener_of(e.kind) == "preview" else { return None }
  let file = dv_file(in_.station, in_.root.unwrap_or(""), in_.path, e)
  guard @sfbase.beside_offered(file.path, e.name) else { return None }
  Some(fn() { open_drive_file(file, [], beside=true) })
}

///|
/// Deleted (FolderView remove): to the machine's trash, as Finder does, nothing asked (said once done); where none takes
/// them, asked first (the library's confirm), then for good.
pub fn remove_entries(src : Source, st : DvStation, items : Array[(DriveAt, DvEntry)]) -> Unit {
  if items.is_empty() {
    return
  }
  if !st.trash {
    ask_remove(src, items)
    return
  }
  let what = @sf.t("web-pages.drive.deleteWhat")
  let left : Array[(DriveAt, DvEntry)] = []
  let answered = Ref(0)
  for x in items {
    let (at, e) = x
    (src.call)(
      "drive.remove",
      {
        "station": Json::string(at.station),
        "root": Json::string(at.root.unwrap_or("")),
        "path": Json::string(dv_join(at.path, e.name)),
      },
      fn(r) {
        answered.val += 1
        match r {
          Ok(_) => ()
          Err(err) if text(Some(err), "code") == "no_trash" => left.push(x)
          Err(err) => toast_later(@sf.t("web-main.act.failed", args=[("what", what), ("error", dv_error(err))]))
        }
        if answered.val == items.length() {
          if left.length() > 0 {
            ask_remove(src, left)
          } else {
            toast_later(@sf.t("web-pages.drive.trashed", args=[("n", items.length().to_string())]))
          }
        }
      },
    )
  }
}

///|
/// What is asked before something goes for good (Confirm): the one, the folder, or how many; 删除 does it.
fn ask_remove(src : Source, asking : Array[(DriveAt, DvEntry)]) -> Unit {
  let title = match asking {
    [(_, e)] =>
      @sf.t(if e.dir { "web-pages.drive.deleteFolderAsk" } else { "web-pages.drive.deleteAsk" }, args=[("name", e.name)])
    many => @sf.t("web-pages.drive.deleteManyAsk", args=[("n", many.length().to_string())])
  }
  let words = if asking.iter().any(fn(x) { x.1.dir }) {
    @sf.t("web-pages.drive.deleteFolderText")
  } else {
    @sf.t("web-pages.drive.deleteText")
  }
  let what = @sf.t("web-pages.drive.deleteWhat")
  @sf.confirm(title, words, @sf.t("web-pages.drive.delete"), fn() {
    for x in asking {
      let (at, e) = x
      (src.call)(
        "drive.remove",
        {
          "station": Json::string(at.station),
          "root": Json::string(at.root.unwrap_or("")),
          "path": Json::string(dv_join(at.path, e.name)),
          "permanent": Json::boolean(true),
        },
        act_said(what),
      )
    }
  }, danger=true)
}

///|
/// What the core says is under way on an entry (`doing`: removed, renamed).
pub fn entry_busy(src : Source, at : DriveAt, name : String) -> Bool {
  let root = at.root.unwrap_or("")
  let full = dv_join(at.path, name)
  for d in items(src.topic("doing", {}).get().value, "doing") {
    let call = text(Some(d), "call")
    let p = field(Some(d), "params")
    if text(Some(d), "stage") == "failed" || text(p, "station") != at.station || text(p, "root") != root {
      continue
    }
    if (call == "drive.remove" && text(p, "path") == full) || (call == "drive.rename" && text(p, "from") == full) {
      return true
    }
  }
  false
}

///|
/// The system's file picker, for files to go up into `at` (sfbase's dv_upload, from a press's handler).
pub fn upload_into(src : Source, at : DriveAt) -> Unit {
  @sfbase.dv_upload_now(src, at)
}
