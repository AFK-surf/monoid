// What is dragged on the files' page (still.fail web/src/drive/drag.ts, browse.ts takes / effectOf / dropInto, transfer.ts,
// FilesNav.tsx useFolderDrop), as nodes of the window's tree: a row pressed with a mouse and moved past a few points
// carries its file or folder under the pointer (its node taking the hold over: View::claims); let go on a folder (a
// folder's row, a column, the folder shown, a folder of the sidebar) it goes there: within its station moved (⌥:
// copied), to another station copied (⌘: moved), as Finder does across disks; a folder let go on 个人收藏 is kept there.
// A move within a station by a root both places are under (the core's `drive.moves`) is a rename there (a copy kept
// beside one of the same name named by `drive.name`), anything else the core's `drive.transfer` (the stations copy
// between them; the bar's 传输 follows it); a name already there is asked about first (替换, 保留两者, 跳过). Files from
// the computer (Finder) let go on a folder go up into it (@ui.files_onto), a folder of them made there and filled.
// Where something is let go is found among the places that take it by where each node is placed, at the moment of the
// hand's event, in its handler.

///|
/// Where something dragged can be let go: its node, its key, the folder it is (None: 个人收藏), its name, whether its
/// station takes files written there and copies from others, and how deep it lies (a folder's row over the folder
/// shown it is in); whether it takes the computer's files (a folder of the sidebar does not); the core it asks, the
/// workspace whose 个人收藏 it is.
priv struct NTarget {
  node : @view.View
  key : String
  into : DriveAt?
  name : String
  write : Bool
  transfers : Bool
  depth : Int
  outside : Bool
  src : Source
  ws : String
}

///|
/// A name already where files go, asked about: what comes (its size, its station's name) and what is there.
pub(all) struct Clash {
  name : String
  dir : Bool
  size : Double
  station : String
  there : DvEntry
}

///|
/// What is asked now: where they go, its name, how many go, the names there, the answers so far, whether the next is
/// said for all the rest, and what is done with the answers.
pub(all) struct Asking {
  into : DriveAt
  into_name : String
  total : Int
  clashes : Array[Clash]
  answers : Map[String, String]
  mut all : Bool
  done : (Map[String, String]) -> Unit
}

///|
/// The drag: what is carried once a row's hold was taken over, where the pointer is with it and the keys held (for its
/// picture and what a drop would do), the places it can be let go (by key, each its node's while it lives), the one what
/// is held is over, what is asked, and what waits on something read. Changed only as the hand, the host or the core
/// says (a row's drag's steps, files from outside held or let go, a folder or a pick read), never as a frame is built.
priv struct NDrag {
  item : @signals.Signal[Dragged?]
  at : @signals.Signal[(Double, Double)]
  mods : @signals.Signal[Int]
  targets : Map[String, NTarget]
  over : @signals.Signal[String]
  mut asking : Asking?
  later : Array[(Ref[Bool], () -> Unit)]
}

///|
// kept across runs: the drag's state (ndrag_reset puts it back)
let ndrag : NDrag = {
  item: @signals.signal(None),
  at: @signals.signal((0.0, 0.0)),
  mods: @signals.signal(0),
  targets: Map([]),
  over: @signals.signal(""),
  asking: None,
  later: [],
}

///|
/// The drag let go (a run anew).
pub fn ndrag_reset() -> Unit {
  ndrag.item.set(None)
  ndrag.over.set("")
  ndrag.mods.set(0)
  ndrag.targets.clear()
  ndrag.asking = None
  for w in ndrag.later {
    (w.1)()
  }
  ndrag.later.clear()
  clash_shown_serial.val = 0
  clash_last.val = None
  clash_changed()
}

///|
/// How far a press moves before it is a drag (a click's slop).
let ndrag_slop : Double = 4.0

///|
/// Node `v` (a row) carrying what `item` says as a mouse holds it and moves it past the slop (a finger moving on a row
/// moves the list, as the web's rows, which a touch drags nothing of; a file is moved there by its menu): moved, it is
/// over what is under the pointer; let go, it goes where it is let go. Not while `live` says not (the row busy, its
/// name being changed).
pub fn drag_source_node(v : @view.View, item : () -> Dragged, live : () -> Bool) -> Unit {
  v
  .claims(fn(dx, dy) {
    @sf.pointer_rests() && @signals.untracked(live) && ((dx.abs() > ndrag_slop) || (dy.abs() > ndrag_slop))
  })
  .on_drag(fn(d) {
    match d.kind {
      Down => {
        ndrag.mods.set(@ui.mods_held())
        ndrag.at.set((d.wx, d.wy))
        ndrag.item.set(Some(@signals.untracked(item)))
        ndrag_over(d.wx, d.wy)
      }
      Moved => {
        ndrag.mods.set(@ui.mods_held())
        ndrag.at.set((d.wx, d.wy))
        ndrag_over(d.wx, d.wy)
      }
      Up => {
        match ndrag.item.untracked() {
          Some(i) =>
            match ndrag_at(d.wx, d.wy) {
              Some(t) => ndrag_drop(i, t, @ui.mods_held())
              None => ()
            }
          None => ()
        }
        ndrag.over.set("")
        ndrag.item.set(None)
      }
      Off => {
        ndrag.over.set("")
        ndrag.item.set(None)
      }
    }
  })
  |> ignore
}

///|
/// What is held is over (x, y) now: the target there that takes it, lit.
fn ndrag_over(x : Double, y : Double) -> Unit {
  ndrag.over.set(
    match ndrag_at(x, y) {
      Some(t) => t.key
      None => ""
    },
  )
}

///|
/// What a drop of `item` into a folder of `station` does (browse.ts effectOf): across stations a copy (⌘: a move),
/// within one a move (⌥: a copy).
fn ndrag_effect(item : Dragged, station : String, mods : Int) -> String {
  if item.station != station {
    if (mods & @ui.mod_cmd) != 0 {
      "move"
    } else {
      "copy"
    }
  } else if (mods & @ui.mod_alt) != 0 {
    "copy"
  } else {
    "move"
  }
}

///|
/// Whether `t` takes what is held over the window now (browse.ts takes): a folder written to, the station's own or one
/// that copies from others (not into what is carried itself); 个人收藏 a folder; the computer's files any folder
/// written to.
fn ndrag_takes(t : NTarget) -> Bool {
  match (ndrag.item.untracked(), t.into) {
    (Some(i), None) => i.dir
    (Some(i), Some(into)) => {
      let root = into.root.unwrap_or("")
      let inside = i.station == into.station &&
        root == i.root &&
        (into.path == i.path || into.path.has_prefix(i.path + "/"))
      t.write && !inside && (i.station == into.station || t.transfers)
    }
    (None, Some(_)) => t.write && t.outside
    (None, None) => false
  }
}

///|
/// The target under (x, y) in the window, of those placed there now, that takes what is held: the deepest, the smaller
/// of two as deep (what is drawn in the other).
fn ndrag_at(x : Double, y : Double) -> NTarget? {
  let mut best : (NTarget, Double)? = None
  for _, t in ndrag.targets {
    if !t.node.alive() || t.node.shown_nowhere() || !ndrag_takes(t) {
      continue
    }
    let (rx, ry, rw, rh) = t.node.placed_window_now()
    if x >= rx && x < rx + rw && y >= ry && y < ry + rh {
      match best {
        Some((b, _)) if b.depth > t.depth => ()
        Some((b, area)) if b.depth == t.depth && area <= rw * rh => ()
        _ => best = Some((t, rw * rh))
      }
    }
  }
  best.map(fn(b) { b.0 })
}

///|
/// Node `v` a place something can be let go, `key` its key (`src` the core it asks, `ws` the workspace whose 个人收藏 it
/// is, where it is that): said as it is made, let go with it. What a drop there would do, while what is held is over it
/// ("move", "copy", "upload", "keep"), else None: read as that changes.
pub fn drop_target_node(
  v : @view.View,
  src : Source,
  key : String,
  into : DriveAt?,
  name : String,
  write : () -> Bool,
  transfers : () -> Bool,
  depth : Int,
  outside? : Bool = true,
  ws? : String,
) -> () -> String? {
  let ws = match (ws, into) {
    (Some(w), _) => w
    (None, Some(at)) => @sfbase.workspace_of(at.station)
    (None, None) => ""
  }
  let put = fn() {
    ndrag.targets[key] = {
      node: v,
      key,
      into,
      name,
      write: @signals.untracked(write),
      transfers: @signals.untracked(transfers),
      depth,
      outside,
      src,
      ws,
    }
  }
  put()
  // (what it may take as the station's rights come: said again then)
  v.reacts(fn() { (write(), transfers()) }, fn(_) { put() }, at_start=false)
  v.owns(fn() {
    match ndrag.targets.get(key) {
      Some(t) if physical_equal(t.node, v) => ndrag.targets.remove(key)
      _ => ()
    }
  })
  |> ignore
  fn() {
    if ndrag.over.get() != key {
      return None
    }
    match (ndrag.item.get(), into) {
      (Some(_), None) => Some("keep")
      (Some(i), Some(at)) => Some(ndrag_effect(i, at.station, ndrag.mods.get()))
      (None, Some(_)) => Some("upload")
      (None, None) => None
    }
  }
}

///|
/// Node `v` (a page) takes files from the computer let go on a folder drawn in it (Finder's, Explorer's: @ui.files_onto):
/// held over one, it says where they go; let go there, read as a pick's, then up into it. Let go elsewhere they are not
/// taken here (what is there may take them otherwise: a field, by their paths).
pub fn files_from_outside_node(v : @view.View) -> Unit {
  @ui.files_onto(
    v,
    held=fn(at) {
      if ndrag.item.untracked() is None {
        match at {
          Some((x, y)) => ndrag_over(x, y)
          None => ndrag.over.set("")
        }
      }
    },
    take=fn(x, y) {
      match ndrag_at(x, y) {
        Some({ into: Some(into), src, .. }) =>
          Some(fn(pick : @ui.Pick) {
            // (up once their reading is done: its answer)
            let files : Ref[Array[@hostapi.Picked]?] = Ref(None)
            ndrag_when(
              fn() {
                if files.val is None {
                  files.val = pick.files()
                }
                files.val is Some(_)
              },
              fn() { ndrag_put_up(src, into, files.val.unwrap_or([])) },
            )
          })
        _ => None
      }
    },
  )
  |> ignore
}

///|
/// `go` done once `ready` says so: now, or as what it read changes (a folder's listing come from the core, a pick's
/// files read by the host), outside any build. What waits is let go with the drag (ndrag_reset).
fn ndrag_when(ready : () -> Bool, go : () -> Unit) -> Unit {
  // (those done before: let go of what they read)
  let gone = ndrag.later.filter(fn(w) { w.0.val })
  for w in gone {
    (w.1)()
  }
  ndrag.later.retain(fn(w) { !w.0.val })
  let (done, stop) = @sfbase.drive_when(ready, go)
  if !done.val {
    ndrag.later.push((done, stop))
  }
}

///|
/// Files from the computer into `into` (browse.ts dropInto, putFolder): each folder made there first (one there already
/// filled, as Finder merges), then each file up into its folder.
fn ndrag_put_up(src : Source, into : DriveAt, files : Array[@hostapi.Picked]) -> Unit {
  let root : String = into.root.unwrap_or("")
  let folders : Array[String] = files.filter(fn(f) { f.name.has_suffix("/") }).map(fn(f) { f.name.exact_view(end=f.name.length() - 1).to_owned() })
  let up = files.filter(fn(f) { !f.name.has_suffix("/") })
  let send = fn() {
    let ups = @sfbase.ups
    for f in up {
      let dir = dv_join(into.path, dv_parent(f.name))
      ups.serial += 1
      ups.uploads.push({
        serial: ups.serial,
        station: into.station,
        root,
        dir,
        name: @signals.signal(dv_name(f.name)),
        bytes: f.bytes,
        sent: @signals.signal(0),
        state: @signals.signal("waiting"),
        error: @signals.signal(""),
        replace: false,
        id: "",
      })
    }
    dv_pump(src)
  }
  // (one after another: a folder's parent made before it)
  fn make(i : Int) {
    if i >= folders.length() {
      send()
      return
    }
    (src.call)(
      "drive.mkdir",
      { "station": Json::string(into.station), "root": Json::string(root), "path": Json::string(dv_join(into.path, folders[i])) },
      fn(_) { make(i + 1) },
    )
  }
  make(0)
}

///|
/// What is carried let go on `t`: kept in 个人收藏 (a folder), or moved or copied into its folder.
fn ndrag_drop(item : Dragged, t : NTarget, mods : Int) -> Unit {
  let src = t.src
  match t.into {
    None => favorite_add(src, t.ws, { station: item.station, root: item.abs, path: "", name: item.name })
    Some(into) => {
      let moves = ndrag_effect(item, into.station, mods) == "move"
      let anywhere = match dv_stations(src, t.ws).0 {
        Some(l) =>
          match l.iter().find_first(fn(s) { s.station == into.station }) {
            Some(s) => s.anywhere
            None => false
          }
        None => false
      }
      ndrag_transfer(src, item, into, moves, t.name, anywhere)
    }
  }
}

///|
/// `item` into the folder `into`: not into itself, nor where it is already; a name there asked about first, once the
/// folder is read (now, or as it is: ndrag_when).
fn ndrag_transfer(src : Source, item : Dragged, into : DriveAt, moves : Bool, into_name : String, anywhere : Bool) -> Unit {
  let into_root = into.root.unwrap_or("")
  if item.station == into.station &&
    item.root == into_root &&
    (dv_parent(item.path) == into.path || into.path == item.path || into.path.has_prefix(item.path + "/")) {
    return
  }
  ndrag_when(fn() { !(drive_folder_held(src, into.station, into_root, into.path) is (None, None)) }, fn() {
    ndrag_send(src, item, into, moves, into_name, anywhere)
  })
}

///|
/// `item` into the folder `into`, read (ndrag_transfer): a name there asked about first. Moved within its station by a
/// root both places are under (the core's `drive.moves`), it is a rename there (the one there to the trash first, or
/// this one beside it named as Finder names a copy kept: `drive.name`); anything else the stations' transfer
/// (`drive.transfer`).
fn ndrag_send(src : Source, item : Dragged, into : DriveAt, moves : Bool, into_name : String, anywhere : Bool) -> Unit {
  let into_root = into.root.unwrap_or("")
  let entries = match drive_folder_held(src, into.station, into_root, into.path) {
    (Some(_), _) => dv_entries(src, into.station, into_root, into.path).unwrap_or([])
    // (one that cannot be read: no names there to ask about)
    _ => []
  }
  let what = @sf.t(if moves { "web-pages.drive.moveWhat" } else { "web-pages.files.copyWhat" })
  let into_json : Json = { "station": Json::string(into.station), "root": Json::string(into_root), "path": Json::string(into.path) }
  // the stations' copy (or move), the answer about a name there said
  let transfer = fn(answer : String?) {
    let conflicts : Map[String, Json] = Map([])
    match answer {
      Some(a) => conflicts[item.name] = Json::string(a)
      None => ()
    }
    (src.call)(
      "drive.transfer",
      {
        "from": {
          "station": Json::string(item.station),
          "root": Json::string(item.root),
          "path": Json::string(dv_parent(item.path)),
          "names": [Json::string(item.name)],
        },
        "to": into_json,
        "move": Json::boolean(moves),
        "conflicts": Json::object(conflicts),
      },
      act_said(what),
    )
  }
  // renamed within its station: the one there to the trash first, or this one kept beside it under a name of its own
  let rename = fn(m : Json?, answer : String?) {
    let root = text(m, "root")
    let from = text(m, "from")
    let to = text(m, "to")
    let named = fn(to : String) {
      (src.call)(
        "drive.rename",
        { "station": Json::string(into.station), "root": Json::string(root), "from": Json::string(from), "to": Json::string(to) },
        act_said(what),
      )
    }
    match answer {
      Some("replace") =>
        (src.call)(
          "drive.remove",
          { "station": Json::string(into.station), "root": Json::string(into_root), "path": Json::string(dv_join(into.path, item.name)) },
          fn(_) { named(to) },
        )
      Some("keep") =>
        (src.call)(
          "drive.name",
          {
            "name": Json::string(item.name),
            "taken": Json::array(entries.map(fn(e) { Json::string(e.name) })),
            "beside": Json::boolean(true),
            "dir": Json::boolean(item.dir),
          },
          fn(r) {
            match r {
              Ok(v) => named(dv_join(dv_parent(to), text(Some(v), "name")))
              Err(_) => ()
            }
          },
        )
      _ => named(to)
    }
  }
  let go = fn(answers : Map[String, String]) {
    let answer = answers.get(item.name)
    if answer == Some("skip") {
      return
    }
    if moves && item.station == into.station {
      (src.call)(
        "drive.moves",
        {
          "items": [
            {
              "station": Json::string(item.station),
              "root": Json::string(item.root),
              "abs": Json::string(item.abs),
              "name": Json::string(item.name),
            },
          ],
          "into": into_json,
          "anywhere": Json::boolean(anywhere),
        },
        fn(r) {
          match r {
            Ok(v) =>
              match items(Some(v), "moves") {
                [m] => rename(Some(m), answer)
                _ => transfer(answer)
              }
            Err(e) => (act_said(what))(Err(e))
          }
        },
      )
    } else {
      transfer(answer)
    }
  }
  let item_lower = item.name.to_lower()
  let mut matched_entry : DvEntry? = None
  for i = 0; i < entries.length(); i = i + 1 {
    if entries[i].name.to_lower() == item_lower {
      matched_entry = Some(entries[i])
      break
    }
  }
  match matched_entry {
    Some(e) =>
      drag_ask({
        into,
        into_name,
        total: 1,
        clashes: [{ name: item.name, dir: item.dir, size: item.size, station: item.station_name, there: e }],
        answers: {},
        all: false,
        done: go,
      })
    None => go({})
  }
}

// ── a name already there, asked about ──

///|
/// What is asked, as it was last told (ndrag.asking set or let go, a name answered, all the rest chosen the same way):
/// the asking itself, how many names it has answered, whether all the rest go one way. What reads it (clash_now: the
/// dialog's title and what it says, what it holds, its foot) follows it, as that changes.
// kept across runs: said again as it changes (ndrag_reset among them)
let clash_told : @signals.Signal[(Asking?, Int, Bool)] = @signals.signal_by((None, 0, false), same=fn(a, b) {
  let same_asking = match (a.0, b.0) {
    (Some(x), Some(y)) => physical_equal(x, y)
    (None, None) => true
    _ => false
  }
  same_asking && a.1 == b.1 && a.2 == b.2
})

///|
/// What is asked changed: told (clash_told).
fn clash_changed() -> Unit {
  clash_told.set(
    match ndrag.asking {
      Some(a) => (Some(a), a.answers.length(), a.all)
      None => (None, 0, false)
    },
  )
}

///|
/// The asking's dialog as presented (@sf.last_presented; 0 none).
// kept across runs: put back by ndrag_reset
let clash_shown_serial : Ref[Int] = Ref(0)

///|
/// A name already where files go asked about (a drop's; a page shown at that moment: the fixture's): what is asked
/// about a name already where files go, each name in turn (or all the rest the same way): 跳过, 保留两者, 替换; let go,
/// nothing goes. The library's dialog of nodes (@sf.panel_nodes, opened by nothing), up while something is asked: its
/// title, what it is about, what it holds and its foot as the name asked about now says them.
pub fn drag_ask(a : Asking) -> Unit {
  ndrag.asking = Some(a)
  clash_changed()
  if clash_shown_serial.val != 0 {
    return
  }
  @sf.panel_nodes(
    "",
    fn(v, _) { clash_body_node(v) },
    from=Unanchored,
    foot=fn(v, _) { clash_foot_node(v) },
    live=fn() {
      match clash_now() {
        (Some(a), Some(n)) =>
          (
            @sf.t(if n.dir { "web-pages.files.clashFolder" } else { "web-pages.files.clash" }, args=[
              ("folder", a.into_name),
              ("name", n.name),
            ]),
            "",
            if a.clashes.length() > 1 {
              @sf.t("web-pages.files.clashCount", args=[("n", a.total.to_string()), ("clashes", a.clashes.length().to_string())])
            } else {
              ""
            },
          )
        _ => ("", "", "")
      }
    },
    // let go (Escape, ✕, a press outside): nothing goes
    gone=fn() {
      ndrag.asking = None
      clash_shown_serial.val = 0
      clash_changed()
    },
  )
  clash_shown_serial.val = @sf.last_presented()
}

///|
/// What is asked now, and the name asked about (the first not answered).
fn clash_now() -> (Asking?, Clash?) {
  clash_told.get() |> ignore
  match ndrag.asking {
    Some(a) => {
      let mut next_clash = None
      for i = 0; i < a.clashes.length(); i = i + 1 {
        if !a.answers.contains(a.clashes[i].name) {
          next_clash = Some(a.clashes[i])
          break
        }
      }
      (Some(a), next_clash)
    }
    None => (None, None)
  }
}

///|
/// `said` (skip, keep, replace) for the name asked about, or all the rest; all answered, the dialog down and what goes
/// goes.
fn clash_answer(a : Asking, n : Clash, said : String) -> Unit {
  let left = a.clashes.filter(fn(x) { !a.answers.contains(x.name) })
  if a.all {
    for x in left {
      a.answers[x.name] = said
    }
  } else {
    a.answers[n.name] = said
  }
  clash_changed()
  let mut all_answered = true
  for i = 0; i < a.clashes.length(); i = i + 1 {
    if !a.answers.contains(a.clashes[i].name) {
      all_answered = false
      break
    }
  }
  if all_answered {
    ndrag.asking = None
    clash_changed()
    if clash_shown_serial.val > 0 {
      @sf.close_presented_of(clash_shown_serial.val)
      clash_shown_serial.val = 0
    }
    (a.done)(a.answers)
  }
}

///|
/// What is asked now and the name asked about, for what the dialog shows (clash_now's): as it was last asked while
/// nothing is (the dialog going as all are answered shows the last name to the end).
fn clash_shown() -> (Asking, Clash)? {
  match clash_now() {
    (Some(a), Some(n)) => {
      clash_last.val = Some((a, n))
      Some((a, n))
    }
    _ => clash_last.val
  }
}

///|
/// The name the dialog last asked about (clash_shown).
// kept across runs: put back by ndrag_reset
let clash_last : Ref[(Asking, Clash)?] = Ref(None)

///|
/// How many names are left to answer of what is asked now (the one asked about among them).
fn clash_left() -> Int {
  match clash_shown() {
    Some((a, _)) => a.clashes.filter(fn(x) { !a.answers.contains(x.name) }).length()
    None => 0
  }
}

///|
/// What the dialog holds, in `v`: what comes and what is there (size or folder, where from, when), what replacing
/// does, the rest the same way (while more than the one asked about are left), each as the name asked about now says.
fn clash_body_node(v : @view.View) -> Unit {
  let name = fn() { clash_shown().map(fn(s) { s.1 }) }
  v.box(fn(facts) {
    @sf.style_node(facts, fn() { fclash_facts })
    facts.box(fn(said) {
      @sf.style_node(said, fn() { fclash_said_column }, in_row=true)
      @sf.words_node(said, fn() { @sf.t("web-pages.files.coming") }, fn() { fclash_said }) |> ignore
      @sf.words_node(said, fn() { @sf.t("web-pages.files.there") }, fn() { fclash_said }) |> ignore
    })
    |> ignore
    facts.box(fn(values) {
      @sf.style_node(values, fn() { fclash_values_column }, in_row=true)
      @sf.words_node(
        values,
        fn() {
          match name() {
            Some(n) => (if n.dir { @sf.t("web-pages.files.folder") } else { @sf.file_size(n.size) }) + " · " + n.station
            None => ""
          }
        },
        fn() { fclash_value },
      )
      |> ignore
      @sf.words_node(
        values,
        fn() {
          match name() {
            Some(n) => (if n.there.dir { @sf.t("web-pages.files.folder") } else { n.there.size_text }) + " · " + n.there.time_text
            None => ""
          }
        },
        fn() { fclash_value },
      )
      |> ignore
    })
    |> ignore
  })
  |> ignore
  @sf.words_node(v, fn() { @sf.t("web-pages.files.replaceNote") }, fn() { clash_note }) |> ignore
  v.show(fn() { clash_left() > 1 }, fn(s) {
    let all = fn() { clash_shown().map(fn(x) { x.0.all }).unwrap_or(false) }
    let words = fn() { @sf.t("web-pages.files.applyAll", args=[("n", (clash_left() - 1).to_string())]) }
    let turn = fn(on : Bool) {
      match @signals.untracked(clash_shown) {
        Some((a, _)) => {
          a.all = on
          clash_changed()
        }
        None => ()
      }
    }
    s.box(fn(row) {
      @sf.style_node(row, fn() { fclash_all })
      // (the whole row pressed, past its box: all the rest the same way or not, as its box would)
      @sf.presses_node(row, fn() { turn(!@signals.untracked(all)) })
      @sf.check_node(row, all, turn, words)
      @sf.words_node(row, words, fn() { clash_note }) |> ignore
    })
    |> ignore
  })
}

///|
/// 跳过, 保留两者, 替换, in `v`: each answers the name asked about as it is pressed.
fn clash_foot_node(v : @view.View) -> Unit {
  let answer = fn(said : String) {
    fn() {
      match clash_now() {
        (Some(a), Some(n)) => clash_answer(a, n, said)
        _ => ()
      }
    }
  }
  @sf.button_node(v, fn() { @sf.t("web-pages.files.skip") }, answer("skip"), tone=Ghost) |> ignore
  @sf.button_node(v, fn() { @sf.t("web-pages.drive.keepBoth") }, answer("keep")) |> ignore
  @sf.button_node(v, fn() { @sf.t("web-pages.drive.replace") }, answer("replace"), tone=Primary, icon="trash") |> ignore
}

// ── what is carried, under the pointer ──

///|
/// What is carried, under the pointer (the drag's picture), in node `v` (the page's, as large as it, over it): its mark
/// and its name on a raised chip, following the pointer from where the page is placed. Nothing to the hand.
pub fn drag_ghost_node(v : @view.View) -> Unit {
  v.show(fn() { ndrag.item.get() is Some(_) }, at_once=true, fn(g) {
    let item = fn() { ndrag.item.get() }
    g
    .presses(Is(false))
    .offset(By(fn() {
      let (px, py) = ndrag.at.get()
      let (x0, y0, _, _) = v.placed_window_now()
      (px - x0 + fdrag_ghost_off, py - y0 + fdrag_ghost_off)
    }))
    |> ignore
    g.box(fn(chip) {
      @sf.style_node(chip, fn() { fdrag_ghost_chip })
      @sf.glass_capsule_node(chip, sharing=false, panel=true) |> ignore
      @sf.icon_node(chip, "", drag_icon, By(fn() { @sf.theme().p.muted }), name_now=fn() {
        match item() {
          Some(i) => dv_kind_icon(if i.dir { "folder" } else { dv_kind_of(i.name) })
          None => "file"
        }
      })
      |> ignore
      @sf.words_node(chip, fn() { item().map(fn(i) { i.name }).unwrap_or("") }, fn() { drag_chip_words }) |> ignore
    })
    |> ignore
  })
}

///|
/// A file's kind by its name, for its mark while it is carried (the folder's listing said it; this is only the picture).
fn dv_kind_of(name : String) -> String {
  match @sf.extension_of(name) {
    "md" | "markdown" => "markdown"
    "txt" | "log" => "text"
    "png" | "jpg" | "jpeg" | "gif" | "webp" | "heic" => "image"
    "mp4" | "mov" | "mkv" | "webm" => "video"
    "mp3" | "m4a" | "wav" | "flac" => "audio"
    "pdf" => "pdf"
    "csv" => "csv"
    _ => "other"
  }
}

///|
/// The drag's picture this far from the pointer (down and right of it).
let fdrag_ghost_off : Double = 12.0

///|
/// What comes and what is there (clash: 10 by 12 in, the field's corner, the neutral ground).
// kept across runs: a value (no field of it changes)
let fclash_facts : @ui.Style = @ui.css("row w=Full px=S3 py=S2_5 gap=S3 radius=Xl bg=Neutral")

///|
/// 对其余 n 项都这样做: its box and its words, the whole row pressed (36 high: its box's room to be pressed in).
// kept across runs: a value (no field of it changes)
let fclash_all : @ui.Style = @ui.css("row min_h=S9 gap=S2 align=ACenter")

///|
/// The picture carried: a floating liquid glass chip following the pointer.
// kept across runs: a value (no field of it changes)
let fdrag_ghost_chip : @ui.Style = @ui.css((
  #|row h=S8 px=S3 gap=S2 align=ACenter radius=Lg
))

///|
/// The clash's facts (4 by 12 between; what is said muted).
// kept across runs: a value (no field of it changes)
let fclash_said_column : @ui.Style = @ui.css("gap=S1")

///|
// kept across runs: a value (no field of it changes)
let fclash_values_column : @ui.Style = @ui.style(w=@sf.grow, gap=S1, clip=true)

///|
// kept across runs: a value (no field of it changes)
let fclash_said : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fclash_value : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
/// What is carried's mark (16).
let drag_icon : Double = 16.0

///|
// kept across runs: a value (no field of it changes)
let drag_chip_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
/// What the clash dialog says under its facts (a note, muted).
// kept across runs: a value (no field of it changes)
let clash_note : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)
