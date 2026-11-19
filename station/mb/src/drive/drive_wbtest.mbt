// The drive's parts on their own: the order names are listed in, types, names kept beside, the pieces a grant is made
// of, CRC-32 and deflate (inflated again by mbui's zip), a folder's watches on a clock of the test's own, and a drive
// over a folder of the test's (listing, a path kept in its root, an upload in parts, a zip, the trash, a poster).

///|
fn scratch(name : String) -> String {
  let dir = join([tmpdir(), "mb-drive-\{name}-\{random_uuid()}"])
  mkdir(dir, true) catch {
    _ => ()
  }
  real_of(dir)
}

///|
fn put(path : String, text : String) -> Unit {
  mkdir(dirname(path), true) catch {
    _ => ()
  }
  write_private(path, text) catch {
    _ => ()
  }
}

///|
fn drive_over(root : String, protect : Array[String], home : String) -> Drive {
  let config : Json = { "drive": { "roots": [Json::string(root)] } }
  Drive::new({
    config: () => config,
    protect: () => protect,
    now: Some(() => 1.0e12),
    files: None,
    home: Some(home),
    mounts: () => [],
    disks: _ => [],
  })
}

///|
test "names in the order a listing has them: by their numbers, case and accents aside" {
  let sorted = stable_sort(
    ["E10.mp4", "e1.mp4", "E2.mp4", "b", "Á", "a", "_x", "10", "9", " z"],
    collate,
  )
  assert_eq(sorted, [" z", "_x", "9", "10", "Á", "a", "b", "e1.mp4", "E2.mp4", "E10.mp4"])
  assert_eq(collate("file02", "file2"), 0)
  assert_eq(units_compare("a", "B") > 0, true)
}

///|
test "a file's type by its name" {
  assert_eq(type_of("movie.MP4"), "video/mp4")
  assert_eq(type_of("clip.ogv"), "video/ogg")
  assert_eq(type_of(".bashrc"), "application/octet-stream")
  assert_eq(type_of("notes.md"), "text/markdown; charset=utf-8")
}

///|
test "a name kept beside those taken, as Finder numbers it" {
  let taken = ["a 2.txt"]
  assert_eq(free("a.txt", false, n => taken.contains(n)), "a 3.txt")
  assert_eq(free("b.d", true, _ => false), "b.d 2")
  assert_eq(free(".env", false, _ => false), ".env 2")
}

///|
test "upload parts and paths" {
  assert_eq(is_part(".stillfail-up-abc_1.part"), true)
  assert_eq(is_part(".stillfail-up-.part"), false)
  assert_eq(is_part(".stillfail-up-a b.part"), false)
  assert_eq(clean("/a/./b/../c//"), "/a/c")
  assert_eq(within("/a/b", "/a"), true)
  assert_eq(within("/ab", "/a"), false)
  assert_eq(within("/x", "/"), true)
  assert_eq(relative_in("/home/u", "/home/u/x/y"), Some("x/y"))
  assert_eq(relative_in("/home/u", "/home/uu"), None)
}

///|
test "encodeURI, base64 and HMAC-SHA256 (RFC 4231's second case)" {
  assert_eq(encode_uri("/a b/ü#?.txt"), "/a%20b/%C3%BC#?.txt")
  assert_eq(base64(b"\x00\x01\x02\x03"), "AAECAw==")
  assert_eq(base64url(b"\xfb\xff"), "-_8")
  assert_eq(from_base64("-_8"), b"\xfb\xff")
  assert_eq(
    hex(hmac_sha256(@utf8.encode("Jefe"), @utf8.encode("what do ya want for nothing?"))),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  )
}

///|
test "a grant signed and read back; another key's, an expired one, another workspace's refused" {
  let key = b"0123456789abcdef0123456789abcdef"
  let g = @jsjson.parse(
    "{\"v\":1,\"workspace\":\"ws\",\"home\":true,\"by\":\"a@x\",\"anywhere\":true,\"root\":\"/r\",\"path\":\"\",\"names\":[\"a\"],\"move\":false,\"expires\":2000}",
  )
  let signed = sign(key, g)
  let back = verify(key, Some(jvs(signed)), Some("ws"), 1000.0)
  assert_eq(@jsjson.stringify(back), @jsjson.stringify(g))
  let code = (f : () -> JV raise) => match attempt(f) {
    Ok(_) => "ok"
    Err(DriveError(d)) => d.message
    Err(_) => "other"
  }
  assert_eq(
    code(() => verify(b"other", Some(jvs(signed)), None, 1000.0)),
    "that is not a grant of this station's",
  )
  assert_eq(
    code(() => verify(key, Some(jvs(signed)), None, 3000.0)),
    "that grant has expired",
  )
  assert_eq(
    code(() => verify(key, Some(jvs(signed)), Some("other"), 1000.0)),
    "that is not a grant of this station's",
  )
  assert_eq(covers(g, "a/b"), true)
  assert_eq(covers(g, "a/../b"), false)
  assert_eq(covers(g, "b"), false)
}

///|
/// What this package's deflate makes (fixed codes' blocks) made whole again, from `start`; None where it is not that.
fn inflate_fixed(data : Bytes, start? : Int = 0) -> Bytes? {
  let out = @buffer.new()
  let made : Array[Byte] = []
  let mut pos = start * 8
  let bit = () => {
    let b = (data[pos >> 3].to_int() >> (pos & 7)) & 1
    pos += 1
    b
  }
  let bits = (n : Int) => {
    let mut v = 0
    for i = 0; i < n; i = i + 1 {
      v = v | (bit() << i)
    }
    v
  }
  let code = () => {
    // fixed codes, most significant bit first
    let mut c = 0
    for _i = 0; _i < 7; _i = _i + 1 {
      c = (c << 1) | bit()
    }
    if c <= 23 {
      return c + 256
    }
    c = (c << 1) | bit()
    if c >= 0x30 && c <= 0xBF {
      return c - 0x30
    }
    if c >= 0xC0 && c <= 0xC7 {
      return c - 0xC0 + 280
    }
    c = (c << 1) | bit()
    c - 0x190 + 144
  }
  while true {
    if pos >= data.length() * 8 {
      return None
    }
    let last = bit()
    if bits(2) != 1 {
      return None
    }
    while true {
      let sym = code()
      if sym < 256 {
        made.push(sym.to_byte())
      } else if sym == 256 {
        break
      } else {
        let i = sym - 257
        let len = len_base[i] + bits(len_extra[i])
        let mut d = 0
        for _k = 0; _k < 5; _k = _k + 1 {
          d = (d << 1) | bit()
        }
        let dist = dist_base[d] + bits(dist_extra[d])
        for _k = 0; _k < len; _k = _k + 1 {
          made.push(made[made.length() - dist])
        }
      }
    }
    if last == 1 {
      break
    }
  }
  for b in made {
    out.write_byte(b)
  }
  Some(out.to_bytes())
}

///|
test "SHA-256 as FIPS 180-4's examples have it" {
  assert_eq(
    hex(@hash.sha256(b"abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  assert_eq(
    hex(@hash.sha256(@utf8.encode("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
  assert_eq(
    hex(@hash.sha256(b"")),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
}

///|
test "CRC-32 rolled on, and deflate inflated again to the same" {
  assert_eq(crc32(@utf8.encode("123456789"), 0U), 0xCBF43926U)
  assert_eq(crc32(@utf8.encode("6789"), crc32(@utf8.encode("12345"), 0U)), 0xCBF43926U)
  let text = StringBuilder::new()
  for i = 0; i < 2000; i = i + 1 {
    text.write_string("line \{i % 17} of the drive's text\n")
  }
  let data = @utf8.encode(text.to_string())
  let d = Deflater::new()
  let out = @buffer.new()
  out.write_bytes(d.push(data[0:30000].to_bytes()))
  out.write_bytes(d.push(data[30000:].to_bytes()))
  out.write_bytes(d.finish())
  let packed = out.to_bytes()
  assert_eq(packed.length() < data.length() / 4, true)
  assert_eq(inflate_fixed(packed), Some(data))
  let empty = Deflater::new()
  assert_eq(inflate_fixed(empty.finish()), Some(b""))
}

///|
test "a folder's watch: a burst told once, kept between asks, its asking held at most so long" {
  let fake : FakeClock = { now: 0.0, timers: [], next: 0 }
  let handlers : Array[(() -> Unit, () -> Unit)] = []
  let mut closed = 0
  let w = FolderWatches::new(held=1500.0, kept=5000.0, fake.clock(), fn(_, change, error) {
    handlers.push((change, error))
    { close: () => closed += 1 }
  })
  let got : Array[(Bool, Double)] = []
  w.changed("/f", "c", yes => got.push((yes, fake.now)))
  fake.advance(1500.0)
  assert_eq(got, [(false, 1500.0)])
  w.changed("/f", "c", yes => got.push((yes, fake.now)))
  (handlers[0].0)()
  (handlers[0].0)()
  fake.advance(250.0)
  assert_eq(got[1], (true, 1750.0))
  (handlers[0].0)()
  fake.advance(250.0)
  w.changed("/f", "c", yes => got.push((yes, fake.now)))
  assert_eq(got[2], (true, 2000.0))
  // Nobody asking for `kept`: let go.
  fake.advance(5000.0)
  assert_eq(w.size(), 0)
  assert_eq(closed, 1)
  let told : Array[Double] = []
  let stop = w.follow("/g", () => told.push(fake.now)).unwrap()
  (handlers[1].1)()
  assert_eq(told, [7000.0])
  assert_eq(closed, 2)
  // (let go again by its follower: closed again, as watch.ts closes it)
  stop()
  assert_eq(closed, 3)
}

///|
test "a drive over a folder: listed in order, kept in its root, an upload in parts, removed to its trash" {
  let base = scratch("drive")
  let root = join([base, "root"])
  let data = join([root, ".stillfail"])
  put(join([data, "key"]), "secret")
  put(join([root, "Season 1", "E10.mp4"]), "ten")
  put(join([root, "Season 1", "E2.mp4"]), "two")
  put(join([root, "notes.md"]), "# hi\n")
  put(join([base, "outside.txt"]), "out")
  let d = drive_over(root, [data], base)
  let (_, entries, more) = d.list(root, "", false)
  assert_eq(entries.map(e => e.name), ["Season 1", "notes.md"])
  assert_eq(more, false)
  let (_, season, _) = d.list(root, "Season 1", false)
  assert_eq(season.map(e => e.name), ["E2.mp4", "E10.mp4"])
  let code = (f : () -> Unit raise) => match attempt(f) {
    Ok(_) => "ok"
    Err(DriveError(e)) => e.code
    Err(_) => "other"
  }
  assert_eq(code(() => d.list(root, "../", false) |> ignore), "path_escape")
  assert_eq(code(() => d.list(root, ".stillfail", false) |> ignore), "protected")
  assert_eq(code(() => d.list("/elsewhere", "", false) |> ignore), "not_a_root")
  let (have, entry) = d.upload(root, "up.txt", "u1", 0.0, 6.0, b"abc", false, false)
  assert_eq(have, 3.0)
  assert_true(entry is None)
  assert_eq(code(() => d.upload(root, "up.txt", "u1", 4.0, 6.0, b"ef", false, false) |> ignore), "upload_lost")
  let (have2, entry2) = d.upload(root, "up.txt", "u1", 3.0, 6.0, b"def", false, false)
  assert_eq(have2, 6.0)
  assert_eq(entry2.map(e => e.size), Some(6.0))
  assert_eq(read_all(join([root, "up.txt"])), b"abcdef")
  d.remove(root, "up.txt", false, false)
  assert_eq(attempt(() => stat(join([root, "up.txt"]))) is Err(_), true)
}

///|
test "a folder zipped: what it holds inflated again, links and what is skipped left out" {
  let base = scratch("zip")
  let dir = join([base, "photos"])
  let text = StringBuilder::new()
  for i = 0; i < 500; i = i + 1 {
    text.write_string("again and again \{i % 3}\n")
  }
  put(join([dir, "a.txt"]), text.to_string())
  put(join([dir, "sub", "b.bin"]), "x")
  put(join([dir, "skip.me"]), "no")
  let to = join([base, "out.zip"])
  let size = zip_folder(dir, to, 1.0e9, (_, n) => n == "skip.me", direct())
  let zip = read_all(to)
  assert_eq(zip.length().to_double(), size)
  // The entries: photos/, photos/a.txt (deflated), photos/sub/, photos/sub/b.bin (stored).
  let u16 = (at : Int) => zip[at].to_int() | (zip[at + 1].to_int() << 8)
  let u32 = (at : Int) => u16(at) | (u16(at + 2) << 16)
  let end = zip.length() - 22
  assert_eq(u16(end + 10), 4)
  let mut at = u32(end + 16)
  let names = []
  let methods = []
  for _i = 0; _i < 4; _i = _i + 1 {
    let n = u16(at + 28)
    names.push(@utf8.decode_lossy(zip[at + 46:at + 46 + n]))
    methods.push(u16(at + 10))
    let local = u32(at + 42)
    if u16(at + 10) == 8 {
      let start = local + 30 + u16(local + 26)
      let back = inflate_fixed(zip, start~)
      assert_eq(back.map(b => @utf8.decode_lossy(b)), Some(text.to_string()))
    }
    at = at + 46 + n
  }
  assert_eq(names, ["photos/", "photos/a.txt", "photos/sub/", "photos/sub/b.bin"])
  assert_eq(methods, [0, 8, 0, 0])
  let small = join([base, "small.zip"])
  assert_eq(attempt(() => zip_folder(dir, small, 10.0, (_, _) => false, direct())) is Err(TooBig), true)
}

///|
test "the freedesktop trash: its note made first, a name there given a number" {
  let base = scratch("trash")
  put(join([base, "f.txt"]), "1")
  let first = to_trash(join([base, "f.txt"]), Some("freedesktop"), 0.0, Some(base))
  put(join([base, "f.txt"]), "2")
  let second = to_trash(join([base, "f.txt"]), Some("freedesktop"), 0.0, Some(base))
  assert_eq(first.map(basename), Some("f.txt"))
  assert_eq(second.map(basename), Some("f 2.txt"))
  let info = @utf8.decode_lossy(
    read_all(join([base, ".local", "share", "Trash", "info", "f 2.txt.trashinfo"])),
  )
  assert_eq(info.has_prefix("[Trash Info]\nPath=\{encode_uri(join([base, "f.txt"]))}\nDeletionDate="), true)
  assert_eq(to_trash(join([base, "x"]), None, 0.0, Some(base)), None)
}

///|
/// `body` run on a runtime of the test's own to its end.
fn run_async(body : async () -> Unit) -> Unit raise {
  let rt = @effect.Runtime::new()
  let fiber = rt.fork(body)
  for _i = 0; _i < 1000 && !fiber.is_done(); _i = _i + 1 {
    rt.advance(1)
  }
  match fiber.poll() {
    Some(Succeeded(_)) => ()
    Some(Failed(e)) => raise e
    _ => fail("the test's fibers did not end")
  }
}

///|
test "a poster made by what the machine has: QuickLook then sips, else ffmpeg; one that cannot be made not tried again" {
  run_async(async fn() {
    let base = scratch("poster")
    let video = join([base, "v.mp4"])
    put(video, "not really a video")
    let thumbs = join([base, "thumbs"])
    let ran : Array[String] = []
    let makers : Makers = {
      quicklook: true,
      run: async fn(file, args) {
        ran.push(basename(file))
        match basename(file) {
          "qlmanage" => {
            put(join([args[4], "v.mp4.png"]), "png")
            true
          }
          "sips" => {
            put(args[args.length() - 1], "jpeg")
            true
          }
          _ => false
        }
      },
    }
    assert_eq(poster(video, thumbs, makers), Some(poster_path(video, thumbs)))
    assert_eq(ran, ["qlmanage", "sips"])
    assert_eq(poster(video, thumbs, makers), Some(poster_path(video, thumbs)))
    assert_eq(ran.length(), 2)
    let other = join([base, "w.mov"])
    put(other, "w")
    let none : Makers = {
      quicklook: false,
      run: async fn(f, _) {
        ran.push(f)
        false
      },
    }
    assert_eq(poster(other, thumbs, none), None)
    assert_eq(poster(other, thumbs, none), None)
    assert_eq(ran, ["qlmanage", "sips", "ffmpeg"])
    assert_eq(names(thumbs).filter(n => n.has_prefix(".poster-")), [])
  })
}

///|
test "a poster asked twice at once is made once, the second asking waiting on the first" {
  run_async(async fn() {
    let base = scratch("posters-at-once")
    let video = join([base, "v.mp4"])
    put(video, "video")
    let thumbs = join([base, "thumbs"])
    let gate : @effect.Deferred[Unit] = @effect.Deferred::new()
    let mut runs = 0
    let makers : Makers = {
      quicklook: false,
      run: async fn(_, args) {
        runs += 1
        gate.wait()
        put(args[args.length() - 1], "jpeg")
        true
      },
    }
    let first = @effect.runtime().fork(async fn() { poster(video, thumbs, makers) })
    let second = @effect.runtime().fork(async fn() { poster(video, thumbs, makers) })
    @effect.pause()
    @effect.pause()
    gate.succeed(()) |> ignore
    let a = first.join()
    let b = second.join()
    assert_eq(runs, 1)
    assert_eq(a, Some(poster_path(video, thumbs)))
    assert_eq(b, a)
  })
}

///|
test "where a dropped file goes: Downloads, the home where there is none, as last found" {
  let base = scratch("drop")
  let ask = dropped_into(base)
  mkdir(join([base, "Downloads"]), false)
  assert_eq(ask(), base)
  assert_eq(ask(), join([base, "Downloads"]))
}

///|
test "Windows' paths: drives and shares, either separator, case aside, as windows.ts has them" {
  with_paths(Win("C:\\work"), () => {
    assert_eq(join(["C:\\Users\\u", "Documents", "a.txt"]), "C:\\Users\\u\\Documents\\a.txt")
    assert_eq(dirname("C:\\a\\b"), "C:\\a")
    assert_eq(basename("C:\\a\\B.txt"), "B.txt")
    assert_eq(path_key("C:\\A\\B"), "c:\\a\\b")
    assert_eq(within("c:\\users\\U\\docs", "C:\\Users\\u"), true)
    assert_eq(within("C:\\Users\\uu", "C:\\Users\\u"), false)
    assert_eq(within("D:\\x", "D:\\"), true)
    assert_eq(rooted("C:\\x"), true)
    assert_eq(rooted("/x"), true)
    assert_eq(rooted("x\\y"), false)
    assert_eq(clean("relative\\..\\x"), "C:\\work\\x")
    assert_eq(clean("D:/a/./b/../c/"), "D:\\a\\c")
    assert_eq(relative_in("C:\\Users\\u", "c:\\users\\u\\x\\y"), Some("x\\y"))
    assert_eq(relative_in("C:\\Users\\u", "C:\\Other"), None)
    assert_eq(root_of("E:\\Movies\\x"), "E:\\")
    assert_eq(root_of("E:x"), "E:")
    assert_eq(root_of("\\\\server\\share\\a"), "\\\\server\\share\\")
    assert_eq(root_of("\\a"), "\\")
    // The way to a folder: from its drive when it is not under the home, each part joined as Windows joins them.
    assert_eq(
      crumbs("E:\\Movies\\Season 1", "C:\\Users\\u", "en").stringify(),
      "[{\"name\":\"E:\\\\\",\"path\":\"E:\\\\\"},{\"name\":\"Movies\",\"path\":\"E:\\\\Movies\"},{\"name\":\"Season 1\",\"path\":\"E:\\\\Movies\\\\Season 1\"}]",
    )
    assert_eq(
      crumbs("c:\\users\\u\\Music/Live", "C:\\Users\\u", "zh").stringify(),
      "[{\"name\":\"主目录\",\"path\":\"C:\\\\Users\\\\u\"},{\"name\":\"Music\",\"path\":\"C:\\\\Users\\\\u\\\\Music\"},{\"name\":\"Live\",\"path\":\"C:\\\\Users\\\\u\\\\Music\\\\Live\"}]",
    )
    // A part of a path with `\` or `:` leads out of its root: refused before anything is looked at.
    let config : Json = { "drive": { "roots": ["C:\\Media"] } }
    let d = Drive::new({
      config: () => config,
      protect: () => [],
      now: None,
      files: None,
      home: Some("C:\\Users\\u"),
      mounts: () => [],
      disks: _ => [],
    })
    assert_eq(roots_of(config), ["C:\\Media"])
    for path in ["a\\..\\..\\x", "D:x", "a/b:stream"] {
      let code = match attempt(() => d.place("c:\\media", path, false)) {
        Ok(_) => "ok"
        Err(DriveError(e)) => e.code
        Err(_) => "other"
      }
      assert_eq(code, "path_escape")
    }
    // A name there in another case is the same name: kept beside under a name of its own.
    let there = ["Report.PDF"].map(path_key)
    assert_eq(free("report.pdf", false, n => there.contains(path_key(n))), "report 2.pdf")
    assert_eq(there.contains(path_key("REPORT.pdf")), true)
  })
  assert_true(path_mode.val is Posix)
  assert_eq(within("/A/b", "/a"), false)
}

///|
test "the drive's errors are said as their words" {
  let said = [
    (drive_error("not_found", "no such file") : Error).to_string(),
    (Refused("the grant is gone") : Error).to_string(),
    (fs_error("ENOENT", "no such file or directory") : Error).to_string(),
    (TooBig : Error).to_string(),
  ]
  assert_eq(said, [
    "no such file", "the grant is gone", "no such file or directory", "zip archive exceeds size limit",
  ])
  for s in said {
    assert_false(s.contains("station/"))
    assert_false(s.contains("("))
  }
}
