// A video's poster (posters.ts): a small picture of its first frame, for a chat to show in its place. Made on first
// asking by what the machine has (QuickLook on a Mac, `qlmanage` then `sips`; else ffmpeg where it is installed), kept
// in <data>/thumbs beside the images' thumbnails, by the video's path; made again once the video is newer (`since`).
// None where neither can make it. What runs a program is given (`run`: its file and arguments, whether it ended well
// within MAKING_MS), as is whether the machine has QuickLook.

///|
/// The longer side of a poster, in pixels.
let side : Int = 640

///|
/// How long making one may take.
pub let making_ms : Int = 30000

///|
/// posters.ts `wanted`: a video a poster is made for, by its name.
pub fn video_wanted(name : String) -> Bool {
  ends_with_any(name, [".mp4", ".m4v", ".mov", ".webm", ".ogv", ".mkv", ".avi"])
}

///|
/// Videos none could be made for (by poster path, with the video's size and time then).
let poster_failed : Map[String, String] = {}

///|
/// Posters being made, by where they go: asked again meanwhile, the same one is waited on (posters.ts `making`).
let making : Map[String, @effect.Deferred[String?]] = {}

///|
/// posters.ts `posterPath`.
pub fn poster_path(video : String, thumbs : String) -> String {
  join([thumbs, "\{id_of(video)}.poster.jpg"])
}

///|
/// How the machine makes a poster: whether it has QuickLook, and how a program is run.
pub(all) struct Makers {
  quicklook : Bool
  run : async (String, Array[String]) -> Bool
}

///|
/// Programs run by the shell (`proc.run`, off the program's thread: client/shell runs it on its blocking pool, so
/// what else the program serves goes on meanwhile), killed past MAKING_MS.
pub fn shell_makers(host : @host.Host) -> Makers {
  {
    quicklook: is_mac(),
    run: async fn(file, args) {
      let (answer, _) = host.shell("proc.run", {
        "command": Json::string(file),
        "args": Json::array(args.map(Json::string)),
        "timeoutMs": Json::number(making_ms.to_double()),
      }) catch {
        _ => return false
      }
      !(answer is Null)
    },
  }
}

///|
/// posters.ts `poster`: the video's poster (a JPEG), made if it is not there yet (or older than `since`); None when
/// none can be made.
pub async fn poster(
  video : String,
  thumbs : String,
  makers : Makers,
  since? : Double,
) -> String? {
  let path = poster_path(video, thumbs)
  match attempt(() => stat(path)) {
    Ok(had) if had.file && (since is None || had.mtime_ms >= since.unwrap()) =>
      return Some(path)
    _ => ()
  }
  let st = match attempt(() => stat(video)) {
    Ok(s) if s.file => s
    _ => return None
  }
  let stamp = "\{js_number(st.size)}:\{js_number(st.mtime_ms)}"
  if poster_failed.get(path) == Some(stamp) {
    return None
  }
  // Looked up and set with no wait between: asked twice at once, the second waits on the first's qlmanage or ffmpeg.
  let got = match making.get(path) {
    Some(d) => d.wait()
    None => {
      let d : @effect.Deferred[String?] = @effect.Deferred::new()
      making.set(path, d)
      // (let go and its waiters woken whatever ends it, an interruption too: posters.ts's `finally`)
      defer {
        if making.get(path) is Some(x) && physical_equal(x, d) {
          making.remove(path)
        }
        d.succeed(None) |> ignore
      }
      let made = make(video, thumbs, path, makers) catch { _ => None }
      making.remove(path)
      d.succeed(made) |> ignore
      made
    }
  }
  if got is None {
    poster_failed.set(path, stamp)
  }
  got
}

///|
/// mkdtemp(`prefix`): a folder of its own, its name the prefix and six letters.
fn mkdtemp(prefix : String) -> String raise {
  let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  while true {
    let r = random_bytes(6)
    let name = StringBuilder::new()
    name.write_string(prefix)
    for i = 0; i < 6; i = i + 1 {
      name.write_char(letters.get_char(r[i].to_int() % letters.length()).unwrap())
    }
    let dir = name.to_string()
    try mkdir(dir, false, mode=0o700) catch {
      FsError({ code: "EEXIST", .. }) => continue
      e => raise e
    }
    return dir
  }
  ""
}

///|
async fn make(
  video : String,
  thumbs : String,
  path : String,
  makers : Makers,
) -> String? {
  let work = try {
    mkdir(thumbs, true)
    mkdtemp(join([thumbs, ".poster-"]))
  } catch {
    _ => return None
  }
  let jpeg = join([work, "poster.jpg"])
  let mut ok = false
  if makers.quicklook &&
    (makers.run)("/usr/bin/qlmanage", ["-t", "-s", side.to_string(), "-o", work, video]) {
    let png = match attempt(() => names(work)) {
      Ok(n) =>
        match n.search_by(f => f.has_suffix(".png")) {
          Some(i) => Some(n[i])
          None => None
        }
      Err(_) => None
    }
    ok = match png {
      Some(p) =>
        (makers.run)("/usr/bin/sips", [
          "-s",
          "format",
          "jpeg",
          "-s",
          "formatOptions",
          "80",
          join([work, p]),
          "--out",
          jpeg,
        ])
      None => false
    }
  }
  if !ok {
    ok = (makers.run)("ffmpeg", [
      "-nostdin", "-loglevel", "error", "-y", "-i", video, "-frames:v", "1", "-vf",
      "scale='if(gt(iw,ih),min(\{side},iw),-2)':'if(gt(iw,ih),-2,min(\{side},ih))'",
      "-q:v", "4", jpeg,
    ])
  }
  let made = match attempt(() => stat(jpeg)) {
    Ok(s) => s.size > 0.0
    Err(_) => false
  }
  let result = if !ok || !made {
    None
  } else {
    match attempt(() => rename(jpeg, path)) {
      Ok(_) => Some(path)
      Err(_) => None
    }
  }
  rm_force(work)
  result
}
