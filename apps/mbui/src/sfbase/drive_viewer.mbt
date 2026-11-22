// A file of a station's drive as a viewer opens it (@sf.ViewerFile): read
// through the core a part at a time (`drive.read`, 4 MB a part, bytes beside the answer), kept on the device as its
// folder lists it (drive_keep: read whole as `file`, played as `played`); where it was left on this device the core's
// (the drivePlace topic, `drive.place`); saved as the drive's 下载 saves it. A text of it read in the library's reader,
// a video or a song played in its player, for a page of either frame (the phone's DriveRead and DrivePlay, the
// desktop's over the whole window).

///|
/// The file `at.path` of `at.root` on `at.station`, as its folder (the `drive` topic, as last read) lists it.
pub fn drive_viewer_file(src : Source, at : DriveAt) -> @sf.ViewerFile {
  let root = at.root.unwrap_or("")
  let dir = dv_parent(at.path)
  let name = dv_name(at.path)
  let entry = dv_entries(src, at.station, root, dir).unwrap_or([]).iter().find_first(fn(e) { e.name == name && !e.dir })
  let (by_kind, by_name, _) = preview_kind(name)
  let listed = entry.map(fn(e) { (e.mtime, e.size) })
  // what it is played by: kept as played, as the folder lists it (Player.kt: DriveCache.played by its mtime and
  // size; one not in it played without being kept), its parts' offset and length each read's own
  let played = fn() {
    let p = drive_params(at.station, root, at.path)
    match listed {
      Some((mtime, size)) => {
        drive_keep(p, "played", mtime, size)
        // (opened here, where it is: brought after everything else once let go)
        p["from"] = { "root": Json::string(root), "path": Json::string(at.path) }
      }
      None => ()
    }
    p
  }
  let size = listed.map(fn(l) { l.1 }).unwrap_or(0.0)
  {
    name,
    size: match entry {
      Some(e) => e.size
      None => 0.0
    },
    mtime: match entry {
      Some(e) => e.mtime
      None => 0.0
    },
    mime: match entry {
      Some(e) if e.mime != "" => e.mime
      _ => by_name
    },
    kind: match entry {
      Some(e) => e.kind
      None =>
        match by_kind {
          Some(KAudio) => "audio"
          Some(KVideo) => "video"
          Some(KMarkdown) => "markdown"
          Some(KText) => "text"
          _ => ""
        }
    },
    title: at.path,
    key: reader_key(at),
    bytes: None,
    read: fn(max, progress, done) {
      drive_read_all(src, at.station, root, at.path, max, "file", listed~, progress~, fn(r) {
        done(
          match r {
            Ok(b) => Ok(b)
            Err(e) => Err(dv_error(e))
          },
        )
      })
    },
    stream: Some(fn(offset, length, answer) {
      let p = played()
      p["offset"] = Json::number(offset)
      p["length"] = Json::number(length.to_double())
      stream_part(src, "drive.read", p, size, answer, ended=fn(r) {
        match r {
          Ok(_) => ()
          Err(e) => @ui.log("player: \{name} @\{offset.to_int()} failed: \{e.stringify()}")
        }
      })
    }),
    direct: direct_part("drive.read", played(), size),
    beside: Some(fn(e, done) {
      drive_read_all(src, at.station, root, dv_join(dir, e.name), subtitle_limit, "played", listed=Some((e.mtime, e.size)), fn(r) {
        done(
          match r {
            Ok(b) => Ok(b)
            Err(e) => Err(dv_error(e))
          },
        )
      })
    }),
    place: fn() {
      // where it was left, held on this device (the core's: no wait for a station)
      let place = src.topic("drivePlace", drive_params(at.station, root, at.path)).get().snapshot()
      match place.value {
        Some(v) => {
          let left = number(Some(v), "at")
          if left > 0.0 {
            LeftAt(left, number(Some(v), "of"))
          } else {
            NeverLeft
          }
        }
        None => if place.error is Some(_) { NeverLeft } else { NotKnown }
      }
    },
    keep_place: fn(left, of) {
      let p = drive_params(at.station, root, at.path)
      p["at"] = Json::number(left)
      p["of"] = Json::number(of)
      (src.call)("drive.place", Json::object(p), fn(r) {
        match r {
          Ok(_) => ()
          Err(e) => @ui.log("drive: \{name}: where it was left not kept: \{e.stringify()}")
        }
      })
    },
    // (at the press's moment: the core told then)
    save: fn() {
      toast_later(@sf.t("android-misc.drive.downloading", args=[("name", name)]))
      let (mtime, size) = listed.unwrap_or((0.0, 0.0))
      download_start_drive(src, at.station, root, at.path, name, size, mtime)
    },
    facts: @sf.no_facts,
  }
}

///|
/// A drive's place as the core's calls and topics name it.
pub fn drive_params(station : String, root : String, path : String) -> Map[String, Json] {
  { "station": Json::string(station), "root": Json::string(root), "path": Json::string(path) }
}

///|
/// The longest subtitle read (a SubRip of a long film is a few hundred KB).
pub let subtitle_limit : Int = 4 * 1024 * 1024

///|
/// A file of a drive read whole (`drive.read`, drive_part a part), `limit` bytes at most (below 0: all of it), how much
/// has come told as it comes (from the size its folder lists, before the first part); kept as `keep` (drive_keep) as
/// its folder lists it (`listed`: its mtime, its size).
pub fn drive_read_all(
  src : Source,
  station : String,
  root : String,
  path : String,
  limit : Int,
  keep : String,
  listed~ : (Double, Double)?,
  progress? : (@sf.Got) -> Unit = fn(_) {  },
  done : (Result[Bytes, Json]) -> Unit,
) -> Unit {
  let parts : Array[Bytes] = []
  let got : Ref[Int] = { val: 0 }
  match listed {
    Some((_, size)) if size > 0.0 => progress({ loaded: 0.0, total: size })
    _ => ()
  }
  fn next() {
    let left = if limit < 0 { drive_part } else { limit - got.val }
    let want = if left < drive_part { left } else { drive_part }
    let p = drive_params(station, root, path)
    p["offset"] = Json::number(got.val.to_double())
    p["length"] = Json::number(want.to_double())
    match listed {
      Some((mtime, size)) => drive_keep(p, keep, mtime, size)
      None => ()
    }
    (src.read_bytes)("drive.read", Json::object(p), fn(r) {
      match r {
        Ok((answer, bytes)) => {
          let total = match field(Some(answer), "total") {
            Some(Number(n, ..)) => n.to_int()
            _ => got.val + bytes.length()
          }
          parts.push(bytes)
          got.val += bytes.length()
          progress({ loaded: got.val.to_double(), total: total.to_double() })
          if bytes.length() == 0 || got.val >= total || (limit >= 0 && got.val >= limit) {
            let all = Buffer(capacity=got.val)
            for b in parts {
              all.write_bytes(b)
            }
            done(Ok(all.to_bytes()))
          } else {
            next()
          }
        }
        Err(e) => done(Err(e))
      }
    })
  }
  next()
}

///|
/// Where a drive's file read or played is kept as it is left (the library's reader's and player's key).
pub fn reader_key(at : DriveAt) -> String {
  at.station + "\n" + at.root.unwrap_or("") + "\n" + at.path
}

///|
/// The text `at.path` of `at.root` on `at.station`, read (the web's Reader) as nodes in `parent` (all of its room):
/// back to its folder by name (`back`). The file as its folder lists it as the reader is made (its size, where it was
/// left, how it is read and saved).
pub fn drive_reader_node(parent : @view.View, src : Source, at : DriveAt, back : () -> Unit) -> Unit {
  let file = @signals.untracked(fn() { drive_viewer_file(src, at) })
  // (its folder, as listed, held while it is read: the folder's page under it at rest, its listing not let go of, as
  // what is gone back to shows)
  parent.reacts(fn() { dv_entries(src, at.station, at.root.unwrap_or(""), dv_parent(at.path)) is Some(_) }, fn(_) {  }) |> ignore
  @sf.reader_node(
    parent,
    reader_key(at),
    file,
    markdown=@sf.reads_as_markdown(file.name),
    back_label=fn() { viewer_folder_label(src, at.station, at.root.unwrap_or(""), dv_parent(at.path)) },
    on_back=back,
  )
  |> ignore
}

///|
/// The file `at.path` of `at.root` on `at.station`, played (the web's Player: opened where it was left on this device,
/// the subtitle beside it) as nodes in `parent` (all of its room), its folder's others to go to (`go`: by name, as its
/// folder lists them), back to its folder by name (`back`). The file as its folder lists it as the player is made.
/// Beside the system's bars (an iPhone Duo's), its name and its actions in them (drive_player_native) and it laid out
/// clear of their column down the window's trailing edge, its stage's ground on under it, as a chat's film is
/// (viewer_tree.mbt); filling the window beside them (@sf.player_fills_native), edge to edge.
pub fn drive_player_node(parent : @view.View, src : Source, at : DriveAt, back : () -> Unit, go : (DriveAt) -> Unit) -> Unit {
  let root = at.root.unwrap_or("")
  let dir = dv_parent(at.path)
  let file = @signals.untracked(fn() { drive_viewer_file(src, at) })
  let siblings = fn() -> Array[@sf.ViewerEntry] {
    dv_entries(src, at.station, root, dir)
    .unwrap_or([])
    .map(fn(e) { { name: e.name, size: e.size, mtime: e.mtime, mime: e.mime, kind: e.kind, dir: e.dir } })
  }
  let m = @sf.player_opened(parent, reader_key(at), file, siblings)
  let width = fn() { @sf.player_stage_w(parent.window_w()) }
  drive_player_native(parent, at, file, m, fn() { @sf.playlist_for(file, siblings()).length() > 1 }, width, back)
  // (its stage's ground under all of it, the column's room too)
  let picture = !(file.kind == "audio" || file.mime.has_prefix("audio/"))
  parent.box(fn(g) { g.over(Is(true)).ground(By(fn() { @sf.media_ink(picture).stage })) |> ignore }) |> ignore
  let room = parent.box(fn(r) {
    r.over(Is(true)).row(Is(true)).padding(By(fn() { (0.0, 0.0, parent.window_w() - width(), 0.0) })) |> ignore
  })
  let stage = room.box(fn(s) { s.grow(Is(1.0)) |> ignore })
  @sf.player_node(
    stage,
    m,
    file,
    fn() { (width(), parent.window_h()) },
    back_label=fn() { viewer_folder_label(src, at.station, root, dir) },
    on_back=back,
    still=fn() { "" },
    flying=fn() { false },
    going=fn() { false },
    move_beside=fn() { None },
    list=fn() { @sf.playlist_for(file, siblings()) },
    on_go=fn(other) { go({ station: at.station, root: at.root, path: dv_join(dir, other) }) },
  )
  |> ignore
}

///|
/// A drive's file `file` played as page `at` in `n`, its player `m` laid out `width()` wide, beside the system's bars
/// (an iPhone Duo's): its name and its actions in them in place of the player's own bar, which it draws none of there,
/// as a chat's film's are (viewer_frame.mbt's vf_native_media): close at their lead (a film turned on its side by the
/// player upright again first, as back does), 全屏 a film's, 选集 where its folder has others of its kind (`many`),
/// 下载; said as any of that changes, kept as said while it is the page on top (@sf.native_over_up). Filling the
/// window beside them (@sf.player_fills_native), none: the bars put away, its name none either. Elsewhere nothing.
fn drive_player_native(
  n : @view.View,
  at : DriveAt,
  file : @sf.ViewerFile,
  m : @player.Media,
  many : () -> Bool,
  width : () -> Double,
  back : () -> Unit,
) -> Unit {
  // (its view's, by its player's key: the drive's player is one at a time)
  let key = m.key()
  n.reacts(
    fn() {
      let w = width()
      (@sf.native_on(), @sf.player_fills_native(w), w, many(), @sf.player_listing(key))
    },
    fn(said) {
      let (on, full, w, many, listing) = said
      if !on ||
        !@sf.native_over_up(if full { "" } else { file.name }, alive=fn() { app.nav.top() == DrivePlay(at) }, owner="drive-play") ||
        full {
        return
      }
      @sf.native_over_act("close", @sf.t("common.close"), "close", fn() {
        if m.is_sideways() {
          m.upright()
        } else {
          @sf.player_full_native_set(false)
          back()
        }
      }, lead=true)
      if file.kind == "video" {
        let (words, lit, act) = @sf.player_full_act(m, w)
        @sf.native_over_act("full", words, "landscape", act, active=lit)
      }
      if many {
        @sf.native_over_act("list", @sf.t("web-pages.drive.player.list"), "list", fn() { @sf.player_list_toggle(key) }, active=listing)
      }
      @sf.native_over_act("download", @sf.t("web-main.preview.download"), "download", fn() { (file.save)() })
    },
  )
  |> ignore
}

///|
/// A drive's text read, left: where it was, kept.
pub fn reader_left(at : DriveAt) -> Unit {
  @sf.reader_let_go(reader_key(at))
}
