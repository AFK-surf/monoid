// release.ts: what updating the station runs, from the pages (updates.mbt) and from `stillfail update` (command.mbt)
// alike: the channel's feed read and its release verified (signed.mbt), refused when it would put an older release
// back, and the installer this release carries told where the release is and what it and its Node must hash to.
// A delta: when the verified release says its archive's raw form and the feed lists a delta from the build this
// station runs, the delta is downloaded and applied to the installed release, and the installer is handed what it
// made (STILLFAIL_ARCHIVE) with the raw form's hash to check instead of the archive's. Anything wrong with it is a line
// in the log, and the installer downloads the whole archive as without one.

///|
/// The pauses before each try again of a feed read, or a delta's download, that failed on the way.
pub let feed_again_ms : Array[Double] = [1000.0, 2000.0, 4000.0]

///|
/// What failed on the way, not of what was asked: the network (fetch's TypeError), its deadline (a TimeoutError), a
/// gateway that could not reach it (502, 503, 504), a body that ended short of its size.
pub fn on_the_way(e : Error) -> Bool {
  let k = kind_of(e)
  k == "OnTheWay" ||
  k == "TypeError" ||
  (field_of(e, "name") is Some(Str(u)) && @jsjson.text(u) == "TimeoutError")
}

///|
fn on_way(message : String) -> Error {
  thrown("OnTheWay", message)
}

///|
/// How a request is made (`fetch`, or the cloud's transport's): the URL, a method when not GET.
pub type Request = async (String, String?) -> Response

///|
/// A request by the world's name for it (`fetch`, `cloud.fetch`).
pub fn request_by(w : World, via : String) -> Request {
  async fn(url, meth) { w.fetch(via, url, meth?) }
}

///|
/// How a pause is waited (a clock's sleep).
pub type Wait = async (Double) -> Unit

///|
/// `readFeed`: the feed of `channel` at `base`, as served. Given `wait`, a read that failed on the way is tried again
/// after each of `feed_again_ms`.
pub async fn read_feed(w : World, channel : String, base : String, request : Request, wait? : Wait) -> J {
  let url = feed(channel, base)
  let mut i = 0
  while true {
    let got : Result[J, Error] = try {
      let response = request(url, None)
      if response.status == 502 || response.status == 503 || response.status == 504 {
        raise on_way("\{url}: \{response.status}")
      }
      if !response.ok() {
        raise fail("\{url}: \{response.status}")
      }
      Ok(response.json(w))
    } catch {
      e => Err(e)
    }
    match got {
      Ok(j) => return j
      Err(e) => {
        guard wait is Some(wait) && i < feed_again_ms.length() && on_the_way(e) else { raise e }
        w.warn(
          "updates",
          "the feed not read, tried again",
          fields=jo([("url", js(url)), ("error", js(message_of(e))), ("after", jn(feed_again_ms[i]))]),
        )
        wait(feed_again_ms[i])
        i += 1
      }
    }
  }
  Null
}

///|
/// The keys a station takes when none are given it (`trustedKeys()`: its environment's STILLFAIL_RELEASE_KEYS too).
let env_release_keys : Ref[String?] = Ref(None)

///|
pub fn set_env_release_keys(keys : String?) -> Unit {
  env_release_keys.val = keys
}

///|
fn trusted_or_default(trusted : Array[(String, String)]?) -> Array[(String, String)] {
  match trusted {
    Some(t) => t
    None => trusted_keys(env_release_keys.val)
  }
}

///|
/// `verifiedOrNull`: the release `said` names, verified; none when it does not verify (why: `why`).
pub async fn verified_or_null(w : World, said : J, trusted : Array[(String, String)]?) -> (J?, String?) {
  let t = trusted_or_default(trusted)
  (Some(verify_feed(w, said, t)), None) catch {
    Thrown("Unverified", _) as e => (None, Some(message_of(e)))
    e => raise e
  }
}

///|
/// The installer `app` carries for this machine, in `lang`.
pub fn bundled_installer(app : String, lang : String) -> String {
  pjoin([app, "bin", "install.\{lang}.\{machine.val.installer_ext}"])
}

///|
/// A delta the feed lists for this machine from the build it runs, with what it must make (the signed raw form).
pub struct Delta {
  from : Double
  url : String
  sha256 : J
  size : Double
  raw_sha256 : J
  raw_size : J
}

///|
pub fn Delta::to_j(self : Delta) -> J {
  jo([
    ("from", jn(self.from)),
    ("url", js(self.url)),
    ("sha256", self.sha256),
    ("size", jn(self.size)),
    ("rawSha256", self.raw_sha256),
    ("rawSize", self.raw_size),
  ])
}

///|
pub struct Plan {
  release : J
  /// The installer to run (the one this release carries).
  script : String
  /// What it is told: where the releases are, the channel, what the archive and Node must hash to, its language.
  env : Array[(String, String)]
  /// The delta to try first, when there is one.
  delta : Delta?
}

///|
pub fn Plan::to_j(self : Plan) -> J {
  jo([
    ("release", self.release),
    ("script", js(self.script)),
    ("env", jo(self.env.map(p => (p.0, js(p.1))))),
    (
      "delta",
      match self.delta {
        Some(d) => d.to_j()
        None => Null
      },
    ),
  ])
}

///|
/// `/^(?!.*(^|\/)\.\.?(\/|$))[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)*$/`: a file under /releases/.
fn release_file(f : String) -> Bool {
  let segs = split(f, "/")
  for s in segs {
    if s == "" || s == "." || s == ".." {
      return false
    }
    for i in 0..<s.length() {
      let c = cu(s, i)
      let ok = (c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        is_digit(c) ||
        c == 46 ||
        c == 95 ||
        c == 45
      if !ok {
        return false
      }
    }
  }
  true
}

///|
/// `deltaFor`: the delta `said` lists for `platform` from build `current`, when `build` (verified) says the raw form
/// it makes; none otherwise, and for one not well formed or no smaller than the archive itself.
pub fn delta_for(said : J, build : J, platform : String?, current : Double?, base : String) -> Delta? {
  let (current, platform, raw_sha, raw_size) = match
    (current, platform, get(Some(build), "rawSha256"), get(Some(build), "rawSize")) {
    (Some(c), Some(p), Some(rs), Some(rz)) => (c, p, rs, rz)
    _ => return None
  }
  let list = match get(get(Some(said), "deltas"), platform) {
    Some(Arr(xs)) => xs
    _ => return None
  }
  let d = match list.search_by(d => num(get(Some(d), "from")) == Some(current)) {
    Some(i) => list[i]
    None => return None
  }
  let file = match get(Some(d), "file") {
    Some(Str(u)) => @jsjson.text(u)
    _ => return None
  }
  if !release_file(file) || !sha_test(get(Some(d), "sha256")) || !is_safe_integer(get(Some(d), "size")) {
    return None
  }
  let size = num(get(Some(d), "size")).unwrap()
  if size <= 0.0 {
    return None
  }
  match num(get(Some(build), "size")) {
    Some(b) if size >= b => return None
    _ => ()
  }
  Some({
    from: current,
    url: "\{base}/releases/\{file}",
    sha256: get(Some(d), "sha256").unwrap(),
    size,
    raw_sha256: raw_sha,
    raw_size: raw_size,
  })
}

///|
/// `/^0\.\d+\.(\d+)$/.exec(version)?.[1]` as a number (NaN where it does not match).
fn build_of(version : String) -> Double {
  let ps = split(version, ".")
  if ps.length() == 3 && ps[0] == "0" && all_digits(ps[1]) && all_digits(ps[2]) {
    decimal(ps[2])
  } else {
    @double.not_a_number
  }
}

///|
/// `planUpdate`: what updating the station of `app` (from `installed`'s channel) to `channel`'s latest at `base`
/// runs. Refusals are raised in `lang`.
pub async fn plan_update(
  w : World,
  base : String,
  channel : String,
  app : String,
  installed : String,
  lang : String,
  trusted : Array[(String, String)]?,
  request : Request,
  wait? : Wait,
) -> Plan {
  let said = read_feed(w, channel, base, request, wait?)
  let (release, why) = verified_or_null(w, said, trusted)
  guard release is Some(release) else {
    raise fail(tr(lang, "station.updates.unverified", args=jo([("why", jopt(why))])))
  }
  let version = station_version_soon(w, app)
  let current = match version {
    Some(v) => Some(build_of(v))
    None => None
  }
  if !allowed(release, current, channel, Some(installed)) {
    raise fail(
      tr(
        lang,
        "station.updates.older",
        args=jo([("version", js(release_version(release))), ("current", jopt(version))]),
      ),
    )
  }
  let build = expected(release, platform()) catch {
    _ => raise fail(tr(lang, "station.updates.noBuild", args=jo([("version", js(release_version(release)))])))
  }
  let script = bundled_installer(app, lang)
  if !w.accessible(script) {
    raise fail(tr(lang, "station.updates.noInstaller"))
  }
  let safe = match current {
    Some(c) if is_safe_integer(Some(Num(c))) => Some(c)
    _ => None
  }
  {
    release,
    script,
    env: [
      ("STILLFAIL_ORIGIN", base),
      ("STILLFAIL_CHANNEL", channel),
      ("STILLFAIL_RELEASE_SHA256", js_string_opt(get(Some(build), "sha256"))),
      ("STILLFAIL_NODE_SHA256", js_string_opt(get(Some(build), "nodeSha256"))),
      ("STILLFAIL_INSTALL_LANG", lang),
    ],
    delta: delta_for(said, build, platform(), safe, base),
  }
}

///|
/// Applies the delta file `delta` to the installed release `app`, writing what it makes to `out`.
pub type Applier = async (String, String, String, Signal) -> Unit

///|
/// A child process's events as the world gives them, in order: `["stdout"|"stderr", text]`, `["error", message]`,
/// `["close", code, signal?]`.
pub type Events = Array[J]

///|
fn events_of(j : J) -> Events {
  match get(Some(j), "$child") {
    Some(Arr(xs)) => xs
    _ => []
  }
}

///|
/// `applyApart`: the applier in a process apart: the release's own Node running its station's
/// `update --apply-delta`, or from a checkout scripts/delta.ts. Its last line said is why it failed.
pub fn apply_apart(w : World) -> Applier {
  async fn(app, delta, out, _signal) {
    let m = machine.val
    let args = if ends_with(m.applier, ".ts") {
      [m.applier, "apply", "--old", app, "--delta", delta, "--out", out]
    } else {
      [m.applier, "update", "--apply-delta", "--app", app, "--delta", delta, "--out", out]
    }
    let child = w.call("child_process.spawn", [
      js(m.exec_path),
      jstrs(args),
      jo([
        ("stdio", jstrs(["ignore", "ignore", "pipe"])),
        ("signal", signal_j),
        ("windowsHide", jb(true)),
      ]),
    ])
    let mut said = ""
    for ev in events_of(child) {
      match ev {
        Arr([Str(k), Str(t), ..]) if @jsjson.text(k) == "stderr" => {
          said = said + @jsjson.text(t)
          said = slice(said, -2000)
        }
        Arr([Str(k), Str(m), ..]) if @jsjson.text(k) == "error" => raise fail(@jsjson.text(m))
        Arr([Str(k), code, ..rest]) if @jsjson.text(k) == "close" => {
          if code is Num(0.0) {
            return
          }
          let lines = split(trim(said), "\n")
          let last = lines[lines.length() - 1]
          if last != "" {
            raise fail(last)
          }
          let why = match code {
            Num(c) => num_text(c)
            _ =>
              match rest {
                [Str(s), ..] => @jsjson.text(s)
                _ => "null"
              }
          }
          raise fail("the applier ended (\{why})")
        }
        _ => ()
      }
    }
  }
}

///|
/// Where the installer takes an archive it is handed from: a directory of its own in the temporary one.
async fn handed_archive(w : World) -> (String, String) {
  let hex_ = hex(bytes_of(Some(w.call("crypto.randomBytes", [ji(16)]))))
  let tmp = text(Some(w.call("os.tmpdir", []))).unwrap_or("")
  if machine.val.installer_ext == "ps1" {
    (pjoin([tmp, "stillfail-handed-\{hex_}"]), "stillfail.zip")
  } else {
    (pjoin([tmp, "stillfail-handed.\{hex_}"]), "stillfail.tar.gz")
  }
}

///|
/// JavaScript's `Number(text)` of what a header says.
pub fn js_number(t : String) -> Double {
  let s = trim(t)
  if s == "" {
    return 0.0
  }
  if is_decimal(s) {
    return decimal(s)
  }
  match s {
    "Infinity" | "+Infinity" => @double.infinity
    "-Infinity" => @double.neg_infinity
    _ => {
      if s.length() > 2 && cu(s, 0) == 48 {
        let base = match cu(s, 1) {
          120 | 88 => 16
          111 | 79 => 8
          98 | 66 => 2
          _ => 0
        }
        if base > 0 {
          let mut v = 0.0
          for i in 2..<s.length() {
            let d = hex_value(cu(s, i))
            if d < 0 || d >= base {
              return @double.not_a_number
            }
            v = v * base.to_double() + d.to_double()
          }
          return v
        }
      }
      @double.not_a_number
    }
  }
}

///|
/// Downloads the delta to `to`, refused unless it is the size and sha256 the feed says (failed on the way: OnTheWay, a
/// TypeError or a TimeoutError).
async fn download_delta(
  w : World,
  d : Delta,
  to : String,
  progress : async (Int) -> Unit,
  request : Request,
) -> Unit {
  let response = request(d.url, None)
  if response.status == 502 || response.status == 503 || response.status == 504 {
    raise on_way("\{d.url}: \{response.status}")
  }
  if !response.ok() || !response.has_body {
    raise fail("\{d.url}: \{response.status}")
  }
  match response.header("content-length") {
    Some(length) if js_number(length) != d.size =>
      raise fail("the delta is \{length} bytes, the feed says \{num_text(d.size)}")
    _ => ()
  }
  let all = Buffer()
  let out = w.write_stream(to)
  let mut got = 0.0
  let mut said = -1
  let streamed : Result[Unit, Error] = try {
    for chunk in response.chunks {
      got += chunk.length().to_double()
      if got > d.size {
        raise fail("the delta is more than the \{num_text(d.size)} bytes the feed says")
      }
      all.write_bytes(chunk)
      out.write(chunk)
      let percent = (got * 100.0 / d.size).floor().to_int()
      if percent != said {
        said = percent
        progress(percent)
      }
    }
    match response.breaks {
      Some(e) => raise e
      None => ()
    }
    Ok(())
  } catch {
    e => Err(e)
  }
  out.end()
  match streamed {
    Err(e) => raise e
    Ok(_) => ()
  }
  if got < d.size {
    raise on_way("the delta broke off at \{num_text(got)} of the \{num_text(d.size)} bytes the feed says")
  }
  if !(d.sha256 is Str(u) && @jsjson.text(u) == sha256(all.to_bytes())) {
    raise fail("the delta's sha256 is not the feed's")
  }
}

///|
/// `takeDelta`: what the installer is told beside `plan.env` once the plan's delta made the release's raw archive:
/// where it is (STILLFAIL_ARCHIVE) and what it hashes to (STILLFAIL_RELEASE_SHA256). Never fails: a delta not used is
/// a line in the log, what it left removed, and nothing told.
pub async fn take_delta(
  w : World,
  plan : Plan,
  app : String,
  apply : Applier,
  signal : Signal,
  progress? : async (Int) -> Unit = fn(_) {  },
  request : Request,
  wait? : Wait,
) -> Array[(String, String)] {
  guard plan.delta is Some(d) else { return [] }
  let (dir, archive) = handed_archive(w)
  let made = pjoin([dir, archive])
  let took : Result[Array[(String, String)], Error] = try {
    w.mkdir(dir, opts=jo([("mode", ji(448))]))
    let file = pjoin([dir, "delta"])
    let mut i = 0
    while true {
      let got : Result[Unit, Error] = try {
        download_delta(w, d, file, progress, request)
        Ok(())
      } catch {
        e => Err(e)
      }
      match got {
        Ok(_) => break
        Err(e) => {
          w.rm(file)
          guard wait is Some(wait) && i < feed_again_ms.length() && !signal.aborted && on_the_way(e) else {
            raise e
          }
          w.warn(
            "updates",
            "the delta not downloaded, tried again",
            fields=jo([("url", js(d.url)), ("error", js(message_of(e))), ("after", jn(feed_again_ms[i]))]),
          )
          wait(feed_again_ms[i])
          i += 1
        }
      }
    }
    apply(app, file, made, signal)
    w.rm(file)
    signal.throw_if_aborted()
    let (sum, size) = w.hash_file(made)
    let raw_ok = (d.raw_size is Num(n) && n == size) && (d.raw_sha256 is Str(u) && @jsjson.text(u) == sum)
    if !raw_ok {
      raise fail("what it made (\{num_text(size)} bytes) is not the release's signed raw archive")
    }
    w.info(
      "updates",
      "the release made from a delta",
      fields=jo([("from", jn(d.from)), ("delta", jn(d.size)), ("archive", d.raw_size)]),
    )
    Ok([("STILLFAIL_ARCHIVE", made), ("STILLFAIL_RELEASE_SHA256", js_string(d.raw_sha256))])
  } catch {
    e => Err(e)
  }
  match took {
    Ok(handed) => handed
    Err(e) => {
      w.rm_quiet(dir, recursive=true)
      w.warn(
        "updates",
        "the delta not used: the installer downloads the whole release",
        fields=jo([("from", jn(d.from)), ("url", js(d.url)), ("why", js(message_of(e)))]),
      )
      []
    }
  }
}
