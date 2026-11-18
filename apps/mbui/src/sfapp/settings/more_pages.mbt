// The rest of settings' pages (the Android app's settings module): what the automatic decisions' pages keep (their
// drafts: the pages are src/sfpages automatic_decisions.mbt's, one each in every frame), this device's bottom bars
// , what this device keeps, the changelog, the prices the usage is
// counted at; and, used from the chats' pages, the machine's own sessions to go on with.

// ---------------------------------------------------------------------------
// 自动决策

///|
/// The drafts of the stations' archive policies open (`policyForm`), by station.
pub let policy_forms : Map[String, String] = Map([])

///|
/// The drafts a decisions' page opened, dropped as it is left.
fn decisions_left(core : Core, route : Route) -> Unit {
  match route {
    AutoPolicy(station) =>
      match policy_forms.get(station) {
        Some(form) => {
          policy_forms.remove(station)
          act(core, tr("web-pages.archivePolicy.closeAction"), "automaticDecisions.policy.drop", obj([("station", str(station)), ("form", str(form)), ("input", obj([]))]))
        }
        None => ()
      }
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// 下方栏

///|
/// How many places a bar holds (BAR_SIZE).
pub let bar_size : Int = 4

///|
/// Every place, in the picker's order.
// kept across runs: a table of constants, never written
pub let all_places : Array[String] = ["chats", "files", "remote", "stations", "profiles", "connects", "usage", "archive", "vault"]

///|
/// What settings' row says of the bars (barsValue): how many, or the one bar's places.
pub fn bars_value(core : Core) -> String {
  let (sets, _) = (core.bars)()
  if sets.length() > 1 {
    fill("android-misc.bar.count", [("n", sets.length().to_string())])
  } else {
    join(sets[0].map(fn(p) { tr("android-misc.bar.place." + p) }), tr("android-misc.bar.sep"))
  }
}

///|
/// The bars kept whole: an empty one dropped, the one in view still the same bar after it.
pub fn save_bars(core : Core, sets : Array[Array[String]], current : Int) -> Unit {
  let mut cur = current
  let kept : Array[Array[String]] = []
  for i, s in sets {
    if s.length() == 0 {
      if i < current {
        cur -= 1
      }
    } else {
      kept.push(s)
    }
  }
  if kept.length() > 0 {
    (core.set_bars)(kept, if cur < 0 { 0 } else if cur >= kept.length() { kept.length() - 1 } else { cur })
  }
}

///|
/// A bar just made on 下方栏's page (sfpages bars.mbt), empty until a place is added (the core keeps no empty bar): let
/// go of as the page is left.
pub let bar_adding : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })


// ---------------------------------------------------------------------------
// 存储空间 (what this device keeps)

///|
/// What the core keeps of each chat (its messages, the files opened in it) and of the drives' files, and the files of
/// no chat known (`cache.usage`), read as the page opens and again after a deletion.
priv struct Kept {
  chats : @signals.Signal[Array[Json]?]
  /// the bytes of the drives' files kept (drive.read's `keep`)
  drive : @signals.Signal[Double]
  /// the files of no chat known (`loose`)
  loose : @signals.Signal[Array[Json]]
  asked : @signals.Signal[Int]
  read : @signals.Signal[Int]
}

///|
let kept : Kept = { chats: @signals.signal(None), drive: @signals.signal(0.0, same=fn(a, b) { a == b }), loose: @signals.signal([]), asked: @signals.signal(0, same=fn(a, b) { a == b }), read: @signals.signal(-1, same=fn(a, b) { a == b })}

///|
/// Whether what is kept is not read as last asked; said read as it is asked now.
fn kept_unread() -> Bool {
  if kept.read.get() == kept.asked.get() {
    return false
  }
  kept.read.set(kept.asked.get())
  true
}

///|
/// The chats' kept data asked of the core now.
fn kept_usage(core : Core) -> Unit {
  (core.call)("cache.usage", obj([]), fn(r) {
    kept.chats.set(Some(
      match r {
        Ok(v) => items(Some(v), "chats")
        Err(_) => []
      },
    ))
    kept.drive.set(match r {
      Ok(v) => number(Some(v), "drive")
      Err(_) => 0.0
    })
    kept.loose.set(match r {
      Ok(v) => items(Some(v), "loose")
      Err(_) => []
    })
  })
}

///|
/// What 本机缓存's row says as the core last said it (kept_said's, nothing asked of it: kept_ask asks as kept_asked
/// changes).
pub fn kept_told() -> String {
  match kept.chats.get() {
    Some(chats) => size_words(kept_total(chats))
    None => ""
  }
}

///|
/// How many times what is kept was asked to be read again (a page of it changed it): what a node asking for it follows.
pub fn kept_asked() -> Int {
  kept.asked.get()
}

///|
/// What is kept asked of the core where it is not read as last asked (kept_said's ask, at the moment of what reads it:
/// a node's reaction to kept_asked, outside a build: asked at once, as kept_read's told ask is there).
pub fn kept_ask(core : Core) -> Unit {
  if kept_unread() {
    kept_usage(core)
  }
}

///|
/// All that is kept: the chats' (their messages and files), the files of no chat known and the drives' files.
fn kept_total(chats : Array[Json]) -> Double {
  chats.fold(init=kept.drive.get() + files_bytes(kept.loose.get()), fn(s, x) { s + chat_bytes(x) })
}

///|
/// The bytes kept of `files` (a chat's, or those of no chat).
fn files_bytes(files : Array[Json]) -> Double {
  files.fold(init=0.0, fn(s, f) { s + number(Some(f), "bytes") })
}

///|
/// What is kept of a chat: its messages and the files opened in it.
fn chat_bytes(x : Json) -> Double {
  number(Some(x), "bytes") + files_bytes(items(Some(x), "files"))
}

///|
/// A size in bytes in words (fileSize).
fn size_words(n : Double) -> String {
  let one = fn(x : Double) { ((x * 10.0).round() / 10.0).to_string() }
  if n < 1024.0 {
    n.to_int().to_string() + " B"
  } else if n < 1024.0 * 1024.0 {
    one(n / 1024.0) + " KB"
  } else if n < 1024.0 * 1024.0 * 1024.0 {
    one(n / 1024.0 / 1024.0) + " MB"
  } else {
    one(n / 1024.0 / 1024.0 / 1024.0) + " GB"
  }
}

///|
/// How long ago `at` was, in the app's words: just now, minutes, hours, days.
fn since_words(now : Double, at : Double) -> String {
  let minutes = ((now - at) / 60000.0).floor().to_int()
  if minutes < 1 {
    tr("android-settings.files.justNow")
  } else if minutes < 60 {
    fill("android-settings.files.minutes", [("n", minutes.to_string())])
  } else if minutes < 24 * 60 {
    fill("android-settings.files.hours", [("n", (minutes / 60).to_string())])
  } else {
    fill("android-settings.files.days", [("n", (minutes / (24 * 60)).to_string())])
  }
}

///|
/// The chats shown until all are asked for (as 用量's lists show theirs).
let kept_first : Int = 8

///|
/// Whether all the chats are shown on 本机缓存, not only the first kept_first.
let kept_all : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

///|
/// The least share of the bar a part has, seen however little it keeps.
let kept_bar_least : Double = 0.01

///|
/// All that is kept, as 用量's totals are said (the heading's size, 600).
// kept across runs: a value (no field of it changes)
let kept_figure : @ui.TextStyle = @ui.text_style(size=Heading, weight=Semibold, color=Fg, wrap=false, w=Full)

///|
/// A part's dot, its colour in the bar (用量's people's).
// kept across runs: a value (no field of it changes)
let kept_dot : @ui.Style = @ui.css("w=S2 h=S2 radius=Full")

///|
/// The sizes a file opened and let go may be brought whole up to (prefs `fillMax`: 0 any), the core's own first.
// kept across runs: a table, never written
let fill_sizes : Array[Double] = [1024.0 * 1024.0 * 1024.0, 100.0 * 1024.0 * 1024.0, 500.0 * 1024.0 * 1024.0, 0.0]

///|
/// Files kept let go, each (`cache.file.clear`), of no chat known: by the station each says.
fn kept_files_clear(core : Core, files : Array[Json]) -> Unit {
  for f in files {
    kept_file_clear(core, text(Some(f), "station"), f)
  }
}

///|
/// A file kept of a chat on `station` let go (`cache.file.clear`): read again from its station when opened.
fn kept_file_clear(core : Core, station : String, f : Json) -> Unit {
  let fv = Some(f)
  (core.call)("cache.file.clear", obj([("station", str(station)), ("key", str(text(fv, "key"))), ("name", str(text(fv, "name")))]), fn(_) {
    kept.asked.set(kept.asked.get() + 1)
  })
}

///|
/// A station's rule's draft (`decisionForm`) opened for what shows it (its rows made once, src/sfpages
/// automatic_decisions.mbt), by the name it is then known by; dropped by decision_form_drop as they are let go.
pub fn decision_form_open(core : Core, station : String) -> String {
  profile_forms.val += 1
  let f = "mbui-decision-" + profile_forms.val.to_string()
  act(core, tr("web-pages.automaticDecisions.configAction"), "automaticDecisions.form.open", obj([("station", str(station)), ("form", str(f)), ("input", obj([]))]))
  f
}

///|
/// A station's rule's draft `form` (decision_form_open's) dropped: what showed it let go.
pub fn decision_form_drop(core : Core, station : String, form : String) -> Unit {
  act(core, tr("web-pages.automaticDecisions.configAction"), "automaticDecisions.form.drop", obj([("station", str(station)), ("form", str(form)), ("input", obj([]))]))
}

