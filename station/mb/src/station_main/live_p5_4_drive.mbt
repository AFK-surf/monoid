// The station's drive (services.ts `StationDrive`, drive/drive.ts `stationDrive`): config.json's roots, what is the
// station's own never reached (its data directory, config.json, and what the parts add: the bus's `own_paths`); and
// copies into it (drive/module.ts `DriveTransfersLive`): the transfers run here and kept in <data>/drive-transfers,
// told to the asker's streams as they change (`drive-transfers`), and what another station of the workspace reads of
// this drive with a grant of this one's (`drive.walk`, `drive.part`, `drive.release` over the mesh). The admin API's
// routes (api_routes drive.mbt) ask the drive by name: `drive.<call>`, a joined workspace's `drive@<ws>.<call>`.

///|
/// What a part refused, as the admin API's routes take it (api_routes `Thrown`): its kind and what it carries.
pub(all) suberror P54Refused {
  P54Refused(String, Json)
}

///|
pub impl Show for P54Refused with output(self, logger) {
  match self {
    P54Refused(kind, said) => logger.write_string("\{kind}: \{jtext(said, "message").unwrap_or("")}")
  }
}

///|
fn p54_drive_refused(e : Error) -> Error {
  match e {
    @drive.DriveError(d) => {
      let said : Map[String, Json] = { "code": Json::string(d.code), "message": Json::string(d.message) }
      if d.have is Some(h) { said["have"] = Json::number(h) }
      if d.about is Some(a) { said["about"] = Json::string(a) }
      P54Refused("DriveError", Json::object(said))
    }
    other => other
  }
}

///|
priv struct P54Drive {
  drive : @drive.Drive
  transfers : @drive.Transfers
  key : Bytes
}

///|
fn p54_bytes_json(b : Bytes) -> Json {
  { "$bytes": Json::string(@drive.base64(b)) }
}

///|
fn p54_bytes_of(v : Json?) -> Bytes {
  match opt_text(v, "$bytes") {
    Some(b) => @drive.from_base64(b)
    None =>
      match v {
        Some(String(s)) => @drive.from_base64(s)
        _ => b""
      }
  }
}

///|
fn p54_entry_json(e : @drive.Entry) -> Json {
  e.to_json()
}

///|
/// The drive and its transfers made and said (services.ts `StationDrive`, drive/module.ts).
fn p54_drive_start(bus : LiveBus, screens : P54Screens) -> P54Drive {
  let host = bus.host
  let drive = @drive.station_drive(
    () => (bus.config_raw.val)(),
    bus.data,
    config_path(bus.data),
    () => (bus.own_paths.val)(),
    p54_helper_protected(bus, screens),
    () => [],
  )
  let key = @drive.grant_key(bus.data)
  let scoped = (t : @jsjson.JValue) => {
    let o = of_jv(t)
    if opt_field(Some(o), "home") is Some(False) {
      match jtext(o, "workspace") {
        Some(ws) => drive.scoped(ws)
        None => drive
      }
    } else {
      drive
    }
  }
  let transfers = @drive.Transfers::new({
    dir: path([bus.data, "drive-transfers"]),
    drive_for: scoped,
    remote: t => @drive.peer_source(
      async fn(station, request) {
        let req = of_jv(request)
        let ws = jtext(req, "workspace")
        let meth = jtext(req, "method").unwrap_or("")
        let (answer, bytes) = bus.call_peer(station, ws, meth, req)
        let given = Ref(bytes)
        {
          json: to_jv(answer),
          bytes: match bytes {
            Some(_) =>
              Some((
                async fn() {
                  let b = given.val
                  given.val = None
                  b
                },
                async fn() { given.val = None },
              ))
            None => None
          },
        }
      },
      t,
    ),
    now: () => wall_ms().to_double(),
    // (told to the asker's own streams, the latest kept for one coming back)
    changed: t => {
      let o = of_jv(t)
      (bus.events_tell.val)(
        "drive-transfers",
        { "transfer": of_jv(@drive.shown(t)) },
        "drive-transfer\u{0}\{jtext(o, "id").unwrap_or("")}",
        { "email": opt_field(Some(o), "by").unwrap_or(Json::null()) },
      )
    },
    rt: host.rt,
  })
  // What another station reads of this drive with a grant of this one's.
  bus.on_peer_prefix("drive.", async fn(_peer, ws, meth, params, _bytes) {
    let request = with_method(params, meth)
    let got = @drive.drive_for_peer(drive, key, to_jv(request), ws, wall_ms().to_double()) catch {
      @drive.Refused(why) => raise BusError(why)
    }
    match got.bytes {
      None => (of_jv(got.json), None)
      Some((next, stop)) => {
        // (the rest of the file as it is read, until it changes: given whole)
        let all = @buffer.new()
        while next() is Some(b) {
          all.write_bytes(b)
        }
        stop()
        (of_jv(got.json), Some(all.to_bytes()))
      }
    }
  })
  { drive, transfers, key }
}

///|
/// What the admin API's drive and transfers routes ask (api_routes drive.mbt), by name; None where `op` is not theirs.
async fn p54_drive_ask(d : P54Drive, bus : LiveBus, op : String, a : Json) -> Json? {
  let s = (i : Int) => call_arg_text(a, i)
  let n = (i : Int) => opt_num(call_arg(a, i)).unwrap_or(0.0)
  let b = (i : Int) => opt_true(call_arg(a, i))
  let (name, call) = match op.find(".") {
    Some(i) => (op[:i].to_owned(), op[i + 1:].to_owned())
    None => (op, "")
  }
  let drive = if name == "drive" {
    Some(d.drive)
  } else if name.has_prefix("drive@") {
    Some(d.drive.scoped(name[6:].to_owned()))
  } else {
    None
  }
  let answer : Json = try {
  match (drive, call) {
    (Some(_), "scoped") => { "$ref": Json::string("drive@" + s(0)) }
    (Some(dr), "roots") => Json::array(dr.roots().map(r => r.to_json()))
    (Some(dr), "checkRoot") => Json::string(dr.check_root(s(0)))
    (Some(dr), "folders") => dr.folders(s(0), s(1), s(2))
    (Some(dr), "list") => {
      let (found, entries, more) = dr.list(s(0), s(1), b(2))
      { "path": Json::string(found), "entries": Json::array(entries.map(p54_entry_json)), "truncated": Json::boolean(more) }
    }
    (Some(dr), "stat") => p54_entry_json(dr.stat(s(0), s(1), b(2)))
    (Some(dr), "read") => {
      let r = dr.read(s(0), s(1), n(2), n(3), b(4))
      {
        "bytes": p54_bytes_json(r.bytes),
        "total": Json::number(r.total),
        "mtime": Json::number(r.mtime),
        "type": Json::string(r.type_),
      }
    }
    (Some(dr), "upload") => {
      let (have, entry) = dr.upload(s(0), s(1), s(2), n(3), n(4), p54_bytes_of(call_arg(a, 5)), b(6), b(7))
      { "have": Json::number(have), "size": Json::number(have), "entry": entry.map(p54_entry_json).unwrap_or(Json::null()) }
    }
    (Some(dr), "mkdir") => p54_entry_json(dr.mkdir(s(0), s(1), b(2)))
    (Some(dr), "rename") => p54_entry_json(dr.rename(s(0), s(1), s(2), b(3)))
    (Some(dr), "remove") => {
      dr.remove(s(0), s(1), b(2), b(3))
      Json::null()
    }
    (Some(dr), "zip") => {
      let (file, zip_name, type_, size) = dr.zip(s(0), s(1), n(2), b(3))
      { "file": Json::string(file), "name": Json::string(zip_name), "type": Json::string(type_), "size": Json::number(size) }
    }
    (Some(dr), "stage") => {
      // (the name it is staged by first, as Drive::stage names it: the uploads' place for it is the admin API's to
      // give, its `$fn` called through the bus; then the copy or the zip made there)
      let entry = dr.stat(s(0), s(1), b(4))
      let name = if entry.dir && b(5) { entry.name + ".zip" } else { entry.name }
      let fn_id = opt_field(call_arg(a, 2), "$fn").unwrap_or(Json::null())
      let given = bus.admin_called(fn_id, [Json::string(name)])
      let safe = jtext(given, "safe").unwrap_or(name)
      let to = match jtext(given, "path") {
        Some(p) => p
        None => raise Failure("the uploads gave no place for \{name}")
      }
      let (staged, at, size) = dr.stage(s(0), s(1), _ => (safe, to), n(3), b(4), b(5))
      { "name": Json::string(staged), "path": Json::string(at), "size": Json::number(size) }
    }
    (Some(dr), "folderToWatch") => Json::string(dr.folder_to_watch(s(0), s(1), b(2)))
    _ =>
      match op {
        // (drive/watch.ts: a folder shown in a client, told changed as it does)
        "drive/watch.changed" => {
          let told : @effect.Deferred[Bool] = @effect.Deferred::new()
          p54_folder_watches(bus).changed(s(0), s(1), c => ignore(told.succeed(c)))
          Json::boolean(told.wait())
        }
        "drive/watch.follow" => {
          let fn_id = opt_field(call_arg(a, 1), "$fn").unwrap_or(Json::null())
          let host = bus.host
          match p54_folder_watches(bus).follow(s(0), () => ignore(host.rt.fork_quiet(name="a drive folder changed", async fn() {
            ignore(bus.admin_called(fn_id, [])) catch { _ => () }
          }))) {
            Some(stop) => {
              p54_follows_next.val += 1
              let handle = "drive/watch.stop:\{p54_follows_next.val}"
              p54_follows[handle] = stop
              { "$ref": Json::string(handle) }
            }
            None => Json::null()
          }
        }
        _ if op.has_prefix("drive/watch.stop:") => {
          match p54_follows.get(op) {
            Some(stop) => {
              p54_follows.remove(op)
              stop()
            }
            None => ()
          }
          Json::null()
        }
        "drive/drive.rootsOf" =>
          Json::array(
            (match opt_str(call_arg(a, 1)) {
              Some(ws) => @drive.roots_of(call_arg(a, 0).unwrap_or(Json::null()), workspace=ws)
              None => @drive.roots_of(call_arg(a, 0).unwrap_or(Json::null()))
            }).map(Json::string),
          )
        // (a chat's files shown small: drive/thumbs.ts and posters.ts, the images' codecs this program's own)
        "drive/thumbs.dir" => Json::string(@drive.thumbs_dir(s(0)))
        "drive/thumbs.wanted" => Json::boolean(@drive.image_wanted(s(0)))
        "drive/thumbs.thumbnail" =>
          match @drive.thumbnail(s(0), s(1), Some(codecs())) {
            Some(t) => { "path": Json::string(t.path), "type": Json::string(t.type_) }
            None => Json::null()
          }
        "drive/thumbs.preview" =>
          match @drive.preview(s(0), s(1), Some(codecs())) {
            Some(t) => { "path": Json::string(t.path), "type": Json::string(t.type_) }
            None => Json::null()
          }
        "drive/thumbs.keep" =>
          Json::array(
            @drive.keep(
              match call_arg(a, 0) {
                Some(Array(fs)) => fs.map(f => to_jv(f))
                _ => []
              },
              s(1),
              Some(codecs()),
            ).map(of_jv),
          )
        "drive/posters.wanted" => Json::boolean(@drive.video_wanted(s(0)))
        "drive/posters.poster" =>
          jopt(@drive.poster(s(0), s(1), @drive.shell_makers(bus.host)))
        "drive/grants.sign" => Json::string(@drive.sign(d.key, to_jv(call_arg(a, 1).unwrap_or(Json::null()))))
        "drive/transfers.shown" => of_jv(@drive.shown(to_jv(call_arg(a, 0).unwrap_or(Json::null()))))
        "transfers.now" => Json::number(wall_ms().to_double())
        "transfers.self" => jopt(bus_station_id_opt(bus))
        "transfers.nameOf" => {
          let id = s(0)
          let mut named = id
          match (bus.cloud_state.val)() {
            Some(st) =>
              match opt_field(Some(st), "peers") {
                Some(Array(ps)) =>
                  for p in ps {
                    if jtext(p, "id") == Some(id) {
                      match jtext(p, "name") {
                        Some(nm) if nm != "" => named = nm
                        _ => ()
                      }
                    }
                  }
                _ => ()
              }
            None => ()
          }
          Json::string(named)
        }
        "transfers.start" => of_jv(d.transfers.start(to_jv(call_arg(a, 0).unwrap_or(Json::null()))))
        "transfers.list" => Json::array(d.transfers.list(s(0)).map(of_jv))
        "transfers.cancel" => of_jv(d.transfers.cancel(s(0), s(1)))
        "transfers.retry" => of_jv(d.transfers.retry(s(0), s(1)))
        "transfers.get" => d.transfers.get(s(0)).map(of_jv).unwrap_or(Json::null())
        _ => return None
      }
  }
  } catch {
    e => raise p54_drive_refused(e)
  }
  Some(answer)
}

///|
/// The drive's folders watched for clients (drive/watch.ts `FolderWatches`), made as one is first asked.
let p54_watches : Ref[@drive.FolderWatches?] = Ref(None)

///|
/// What a client's following stream stops by (`drive/watch.stop:<n>`).
let p54_follows : Map[String, () -> Unit] = Map([])

///|
let p54_follows_next : Ref[Int] = Ref(0)

///|
let p54_folder_look_ms : Int = 500

///|
/// A folder's entries as last looked at: each name with its size and time.
fn p54_folder_marks(dir : String) -> Map[String, String] raise {
  let out : Map[String, String] = Map([])
  for name in @drive.names(dir) {
    out[name] = match attempt(() => @drive.lstat(path([dir, name]))) {
      Ok(st) => "\{st.size}:\{st.mtime_ms}"
      Err(_) => ""
    }
  }
  out
}

///|
fn p54_folder_watches(bus : LiveBus) -> @drive.FolderWatches {
  match p54_watches.val {
    Some(w) => w
    None => {
      let rt = bus.host.rt
      let clock : @drive.Clock = {
        now: () => wall_ms().to_double(),
        after: (ms, f) => bus_after(bus.host, if ms < 1.0 { 1.0 } else { ms }, f),
      }
      // (the shell keeps no watch of a folder: its entries looked at every P54_FOLDER_LOOK_MS while it is watched)
      let open = (dir : String, changed : () -> Unit, failed : () -> Unit) => {
        let first = p54_folder_marks(dir)
        let going = Ref(true)
        ignore(
          rt.fork_daemon("a drive folder watched", on_error=e => @host.note("a drive folder watched failed: \{e}"), async fn() {
            let mut before = first
            while going.val && !bus.stopped.is_done() {
              @effect.sleep(p54_folder_look_ms) // timer: an outside system that offers no push (a folder; the shell keeps no watch)
              if !going.val {
                break
              }
              match (try { Ok(p54_folder_marks(dir)) } catch { e => Err(e) }) {
                Ok(now) => {
                  if now != before {
                    before = now
                    changed()
                  }
                }
                Err(_) => {
                  going.val = false
                  failed()
                }
              }
            }
          }),
        )
        ({ close: () => going.val = false } : @drive.Watcher)
      }
      let w = @drive.FolderWatches::new(clock, open)
      p54_watches.val = Some(w)
      w
    }
  }
}
