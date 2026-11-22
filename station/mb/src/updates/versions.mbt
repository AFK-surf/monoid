// versions.ts: what the updates go by, as plain functions: versions and how they compare, the release channels, what
// is offered, and the words the pages show while something updates.

///|
/// The words of the station (client/i18n/catalog's station.json, zh and en) and the language it speaks itself
/// (i18n.ts `stationLang`), as the station's process gives them.
let catalog : Ref[@ops_platform.Catalog] = Ref(@ops_platform.Catalog::from_json(Json::null(), Json::null()))

///|
let lang_said : Ref[String] = Ref("zh")

///|
pub fn set_words(zh : Json, en : Json) -> Unit {
  catalog.val = @ops_platform.Catalog::from_json(zh, en)
}

///|
pub fn set_station_lang(lang : String) -> Unit {
  lang_said.val = lang
}

///|
pub fn station_lang() -> String {
  lang_said.val
}

///|
/// JSON as the catalog's filling takes it.
fn core_json(j : J) -> Json {
  j.to_json_lossy()
}

///|
/// i18n.ts `tr`.
pub fn tr(lang : String, key : String, args? : J = jo([])) -> String {
  let m : Map[String, Json] = Map([])
  match args {
    Obj(ps) => for p in ps { m[@jsjson.sanitize_str(p.0)] = core_json(p.1) }
    _ => ()
  }
  @ops_platform.tr(catalog.val, lang, key, m)
}

///|
/// Which releases a station is updated to: the stable ones, or the test channel's.
pub fn channel_of_id(id : String) -> String? {
  let t = trim(id)
  if t == "stable" || t == "beta" {
    Some(t)
  } else {
    None
  }
}

///|
/// Where still.fail cloud says its latest (scripts/release.sh, cloud/src/install.ts).
pub fn feed(channel : String, origin : String) -> String {
  "\{origin}/releases/\{if channel == "stable" { "station" } else { "station-beta" }}.json"
}

///|
/// What each release directory's CHANNEL said, read once a process (`releaseChannel`).
let releases : Map[String, String?] = Map([])

///|
/// `releaseChannel(app)`: the channel the release in `app` came from, as its installer wrote it (CHANNEL); none from an
/// installer before that. Read once a process.
pub async fn release_channel(w : World, app : String) -> String? {
  match releases.get(app) {
    Some(known) => return known
    None => ()
  }
  let channel = match w.read_text_or_null(pjoin([app, "CHANNEL"]), sync=true) {
    Some(t) => channel_of_id(t)
    None => None
  }
  releases[app] = channel
  channel
}

///|
/// `releaseChannelSoon(app)`: as `release_channel`, off the station's thread.
pub async fn release_channel_soon(w : World, app : String) -> String? {
  match releases.get(app) {
    Some(known) => return known
    None => ()
  }
  let channel = match w.read_text_or_null(pjoin([app, "CHANNEL"])) {
    Some(t) => channel_of_id(t)
    None => None
  }
  releases[app] = channel
  channel
}

///|
/// Forgets what was read of the releases (a test's new world).
pub fn forget_releases() -> Unit {
  releases.clear()
}

///|
/// The config's `updateChannel`, when it names one.
fn config_channel(raw : J) -> String? {
  match get(Some(raw), "updateChannel") {
    Some(Str(u)) => channel_of_id(@jsjson.sanitize_str(u))
    _ => None
  }
}

///|
/// `channelFrom(raw, release)`: the channel a station is updated on, as its config says, else as its release came
/// (`release`), else stable.
pub fn channel_from(raw : J, release : String?) -> String {
  match config_channel(raw) {
    Some(c) => c
    None => release.unwrap_or("stable")
  }
}

///|
/// `channelOf(raw, app)`.
pub async fn channel_of(w : World, raw : J, app : String) -> String {
  channel_from(raw, if config_channel(raw) is None { release_channel(w, app) } else { None })
}

///|
/// `channelOfSoon(raw, app)`.
pub async fn channel_of_soon(w : World, raw : J, app : String) -> String {
  channel_from(raw, if config_channel(raw) is None { release_channel_soon(w, app) } else { None })
}

///|
/// `stationVersion(app)` (ops/version.ts): its release's BUILD, `0.1.<n>`.
pub async fn station_version(w : World, app : String) -> String? {
  let build = match w.read_text_or_null(pjoin([app, "BUILD"]), sync=true) {
    Some(t) => trim(t)
    None => return None
  }
  if build != "" && all_digits(build) {
    Some("0.1.\{build}")
  } else {
    None
  }
}

///|
/// `stationVersionSoon(app)`: its release's BUILD read off the station's thread.
pub async fn station_version_soon(w : World, app : String) -> String? {
  let build = match w.read_text_or_null(pjoin([app, "BUILD"])) {
    Some(b) => trim(b)
    None => ""
  }
  if build != "" && all_digits(build) {
    Some("0.1.\{build}")
  } else {
    None
  }
}

///|
/// A version's numbers (`/[^0-9]/` splits it), each as its digits without leading zeros.
fn parts(v : String) -> Array[String] {
  split_units(v, c => !is_digit(c))
  .filter(p => p != "")
  .map(p => {
    let mut i = 0
    while i < p.length() - 1 && cu(p, i) == 48 {
      i += 1
    }
    slice(p, i)
  })
}

///|
/// Two numbers' digits (no leading zeros) compared as BigInts.
fn compare_digits(a : String, b : String) -> Int {
  if a.length() != b.length() {
    return if a.length() > b.length() { 1 } else { -1 }
  }
  a.compare(b)
}

///|
/// Whether `latest` is a newer version than `current`, number by number ("2.1.10" is newer than "2.1.9"; a longer one
/// with the same start is newer).
pub fn newer(current : String, latest : String) -> Bool {
  let a = parts(latest)
  let b = parts(current)
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    if a[i] != b[i] {
      return compare_digits(a[i], b[i]) > 0
    }
  }
  a.length() > b.length()
}

///|
/// `/[\s(),]/`.
fn word_break(c : Int) -> Bool {
  @jscase.is_space(c) || c == 40 || c == 41 || c == 44
}

///|
/// The first dotted version in what a command said ("2.1.284 (Claude Code)", "codex-cli 0.46.0").
pub fn version_in(t : String) -> String? {
  for raw in split_units(t, word_break) {
    let mut i = 0
    while i < raw.length() && cu(raw, i) == 118 {
      i += 1
    }
    let w = slice(raw, i)
    if includes(w, ".") && split(w, ".").iter().all(p => p != "" && is_digit(cu(p, 0))) {
      return Some(w)
    }
  }
  None
}

///|
/// What is offered for the station going from `version` to `latest` (as `channel`'s feed says it), its release having
/// come from `installed`: (newer, downgrade). Back to the stable release from a beta is offered even when it is older.
/// A station's version is 0.<m>.<n>, compared by n (its build) alone.
pub fn offer(version : String?, latest : String?, channel : String, installed : String) -> (Bool, Bool) {
  let (v, l) = match (version, latest) {
    (Some(v), Some(l)) if v != "" && l != "" => (v, l)
    _ => return (false, false)
  }
  let last = (s : String) => match parts(s) {
    [] => "0"
    ps => ps[ps.length() - 1]
  }
  let c = compare_digits(last(l), last(v))
  if c > 0 {
    return (true, false)
  }
  (false, channel == "stable" && installed == "beta" && c < 0)
}

///|
/// `/^[#\s]*$/`.
fn all_bar(s : String) -> Bool {
  for i in 0..<s.length() {
    let c = cu(s, i)
    if !(c == 35 || @jscase.is_space(c)) {
      return false
    }
  }
  true
}

///|
/// `/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/`.
fn is_decimal(s : String) -> Bool {
  let n = s.length()
  let mut i = 0
  if i < n && (cu(s, i) == 43 || cu(s, i) == 45) {
    i += 1
  }
  let int_start = i
  while i < n && is_digit(cu(s, i)) {
    i += 1
  }
  let ints = i - int_start
  if ints > 0 {
    if i < n && cu(s, i) == 46 {
      i += 1
      while i < n && is_digit(cu(s, i)) {
        i += 1
      }
    }
  } else {
    if !(i < n && cu(s, i) == 46) {
      return false
    }
    i += 1
    let f = i
    while i < n && is_digit(cu(s, i)) {
      i += 1
    }
    if i == f {
      return false
    }
  }
  if i < n && (cu(s, i) == 101 || cu(s, i) == 69) {
    i += 1
    if i < n && (cu(s, i) == 43 || cu(s, i) == 45) {
      i += 1
    }
    let e = i
    while i < n && is_digit(cu(s, i)) {
      i += 1
    }
    if i == e {
      return false
    }
  }
  i == n
}

///|
/// The last complete percentage of curl's progress bar in what the installer said; none when there is none.
pub fn curl_percent(log : String) -> Int? {
  let lines = split_units(log, c => c == 13 || c == 10)
  let mut i = lines.length() - 1
  while i >= 0 {
    let line = trim_end(lines[i])
    i -= 1
    // (`/\s\S*$/`: the last space, nothing but what is not one after it)
    let mut at = -1
    for j in 0..<line.length() {
      if @jscase.is_space(cu(line, j)) {
        at = j
      }
    }
    if at < 0 {
      continue
    }
    let bar = slice(line, 0, end=at)
    let value = slice(line, at + 1)
    if bar == "" || !all_bar(bar) || !ends_with(value, "%") {
      continue
    }
    let t = slice(value, 0, end=value.length() - 1)
    if !is_decimal(t) {
      continue
    }
    let n = decimal(t)
    if n == n && n >= 0.0 && n <= 100.0 {
      return Some(n.floor().to_int())
    }
  }
  None
}

///|
/// How much of the station's release the installer has downloaded, from update.log's tail (its last 4096 bytes).
pub async fn station_download_percent(w : World, log : String) -> Int? {
  let st = (try Some(w.stat(log)) catch { _ => None })
  guard st is Some(s) else { return None }
  let len = s.size
  let from = if len - 4096.0 > 0.0 { len - 4096.0 } else { 0.0 }
  let want = if len < 4096.0 { len.to_int() } else { 4096 }
  match (try w.read_at(log, want, from) catch { _ => None }) {
    Some(b) => curl_percent(utf8_text(b))
    None => None
  }
}

///|
/// The last lines of what a command said, for the pages (at most four, at most 600 characters), without what it told
/// a terminal (colours, a progress bar's carriage returns).
pub fn tail(said : String, lang : String) -> String {
  // A line written over (a progress bar's) is what it was last.
  let shown = split(said, "\n")
    .map(l => {
      let mut e = l.length()
      while e > 0 && cu(l, e - 1) == 13 {
        e -= 1
      }
      let parts = split(slice(l, 0, end=e), "\r")
      parts[parts.length() - 1]
    })
    .join("\n")
  let lines = split(trim(@ops_platform.plain_text(shown)), "\n").filter(l => trim(l) != "")
  let from = if lines.length() - 4 > 0 { lines.length() - 4 } else { 0 }
  let last = lines[from:].to_owned().join("\n")
  if last == "" {
    return tr(lang, "station.updates.noOutput")
  }
  let chars : Array[Char] = last.iter().collect()
  let start = if chars.length() - 600 > 0 { chars.length() - 600 } else { 0 }
  String::from_array(chars[start:].to_owned())
}

///|
/// Words the pages show, said in whichever language they are read in: a catalog key (its arguments), or text as a
/// command said it.
pub(all) enum Words {
  Key(String, J?)
  Text(String)
}

///|
/// The words as JSON, as the TypeScript keeps them (`{key, args?}` or `{text}`).
pub fn Words::to_j(self : Words) -> J {
  match self {
    Key(k, None) => jo([("key", js(k))])
    Key(k, Some(a)) => jo([("key", js(k)), ("args", a)])
    Text(t) => jo([("text", js(t))])
  }
}

///|
pub fn key(k : String, args? : Array[(String, J)]) -> Words {
  Key(k, args.map(jo))
}

///|
/// `say(w, lang)`.
pub fn say(w : Words, lang : String) -> String {
  match w {
    Text(t) => t
    Key(k, args) => tr(lang, k, args=args.unwrap_or(jo([])))
  }
}

///|
/// `sameWords(a, b)`.
pub fn same_words(a : Words?, b : Words?) -> Bool {
  let j = (w : Words?) => match w {
    Some(x) => x.to_j()
    None => Null
  }
  same(j(a), j(b))
}

///|
pub let installing : Words = Key("station.updates.installing", None)

///|
/// The step a line of an installer's output says it is at: Homebrew's, and Claude Code's installer's.
pub fn step_of(line : String) -> Words? {
  let l = trim(line)
  if ["==> Fetching", "==> Downloading"].iter().any(s => starts_with(l, s)) {
    return Some(Key("station.updates.downloading", None))
  }
  if [
      "==> Installing", "==> Pouring", "==> Upgrading", "==> Moving", "==> Linking", "Setting up Claude Code",
    ].iter().any(s => starts_with(l, s)) {
    return Some(installing)
  }
  None
}

///|
/// How much of a download is in, as the pages say it: a line, and the share when its size is known.
pub fn downloading(version : String, got : Double, total : Double?) -> (Words, Int?) {
  let mb = (b : Double) => js_round(b / 1000000.0)
  match total {
    Some(t) if t > 0.0 => {
      let g = if got < t { got } else { t }
      (
        Key(
          "station.updates.downloadingSized",
          Some(jo([("version", js(version)), ("got", jn(mb(g))), ("mb", jn(mb(t)))])),
        ),
        Some((g * 100.0 / t).floor().to_int()),
      )
    }
    _ =>
      (
        Key("station.updates.downloadingSoFar", Some(jo([("version", js(version)), ("mb", jn(mb(got)))]))),
        None,
      )
  }
}
