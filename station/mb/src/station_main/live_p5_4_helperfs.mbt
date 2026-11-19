// The folders macOS protects (Documents, Desktop, Downloads, disks) as the drive reaches them (services.ts
// `HelperFolders`, drive.ts' `Protected`): through still.fail Helper, which holds their grants, each of the drive's
// operations its `files.*` request on a connection of its own to <data>/helper/helper.sock (helper/files.ts' protocol:
// a JSON line with the token in <data>/helper/token, its answer a JSON line; a read's bytes after its head line, a
// write's bytes sent after its request). The drive asks at once, so each is asked so (live_p5_4_io.c `p54io_unix_rpc`),
// bounded in time; what is known of each folder's grant, its look in the background and its window are screens'
// `HelperFiles`.

///|
let p54_helper_ms : Int = 30000

///|
fn p54_fs_error(code : String, message : String, grant? : String, top? : String) -> Error {
  @drive.FsError({ code, message, grant, top })
}

///|
/// One request of the helper's (`op` and its fields, the scope's roots and protected paths, the token): what it
/// answered, its first line JSON, and the bytes after it; its refusal an FsError as the drive takes it.
fn p54_helper_ask(dir : String, op : Json, after : Bytes, lines : Int) -> (Json, Bytes) raise {
  let token = read_text(path([dir, "token"])).map(t => t.trim().to_owned())
  let asked = match op {
    Object(m) => {
      let c = m.copy()
      c["token"] = p54_opt(token)
      Json::object(c)
    }
    other => other
  }
  let got = p54_unix_rpc(path([dir, "helper.sock"]), p54_cat([@utf8.encode(asked.stringify() + "\n"), after]), lines, p54_helper_ms)
  let mut nl = -1
  for i in 0..<got.length() {
    if got[i] == b'\n' {
      nl = i
      break
    }
  }
  if nl < 0 {
    raise p54_fs_error("EIO", "still.fail Helper ended before it answered")
  }
  let head = @json.parse(@utf8.decode_lossy(p54_sub(got, 0, nl))) catch {
    _ => raise p54_fs_error("EIO", "still.fail Helper's answer is unreadable")
  }
  match p54_text(Some(head), "error") {
    Some(why) =>
      raise p54_fs_error(
        p54_text(Some(head), "code").unwrap_or("EIO"),
        why,
        grant?=p54_text(Some(head), "grant"),
        top?=p54_text(Some(head), "top"),
      )
    None => ()
  }
  (head, p54_sub(got, nl + 1, got.length()))
}

///|
fn p54_helper_stat(a : Json) -> @drive.Stat {
  {
    dir: p54_bool(p54_get(Some(a), "dir")),
    file: p54_bool(p54_get(Some(a), "file")),
    link: p54_bool(p54_get(Some(a), "link")),
    size: p54_num(p54_get(Some(a), "size")).unwrap_or(0.0),
    mtime_ms: p54_num(p54_get(Some(a), "mtime")).unwrap_or(0.0),
    dev: 0.0,
  }
}

///|
/// The drive's operations through still.fail Helper, in one scope (helper/files.ts `HelperFs`), each asked at once.
fn p54_helper_fs(dir : String, roots : Array[String], protect : Array[String]) -> @drive.Fs {
  let ask = (op : String, fields : Array[(String, Json)]) => {
    let m : Map[String, Json] = { "op": Json::string(op), "roots": Json::array(roots.map(Json::string)), "protect": Json::array(protect.map(Json::string)) }
    for f in fields {
      m[f.0] = f.1
    }
    p54_helper_ask(dir, Json::object(m), b"", 1).0
  }
  let read = (p : String, offset : Double, length : Double) => {
    let m : Map[String, Json] = {
      "op": "files.read",
      "path": Json::string(p),
      "offset": Json::number(offset),
      "length": Json::number(length),
      "roots": Json::array(roots.map(Json::string)),
      "protect": Json::array(protect.map(Json::string)),
    }
    let (head, rest) = p54_helper_ask(dir, Json::object(m), b"", 0)
    let want = p54_num(p54_get(Some(head), "length")).unwrap_or(0.0).to_int()
    if rest.length() < want {
      raise p54_fs_error("EIO", "still.fail Helper ended before it answered")
    }
    (p54_sub(rest, 0, want), p54_num(p54_get(Some(head), "size")).unwrap_or(0.0), p54_num(p54_get(Some(head), "mtime")).unwrap_or(0.0))
  }
  let stat = (p : String, follow : Bool) => p54_helper_stat(ask("files.stat", [("path", Json::string(p)), ("follow", Json::boolean(follow))]))
  {
    helper: true,
    list: (d, most) => {
      let a = ask("files.list", [("path", Json::string(d)), ("most", Json::number(most.to_double()))])
      let entries = match p54_get(Some(a), "entries") {
        Some(Array(es)) =>
          es.map(e => {
            let name = p54_text(Some(e), "name").unwrap_or("")
            ({
              name,
              link: p54_bool(p54_get(Some(e), "link")),
              real: p54_text(Some(e), "real").unwrap_or(path([d, name])),
              stat: if p54_bool(p54_get(Some(e), "gone")) { None } else { Some(p54_helper_stat(e)) },
            } : @drive.Listed)
          })
        _ => []
      }
      (entries, p54_bool(p54_get(Some(a), "more")))
    },
    names: d => p54_strs(p54_get(Some(ask("files.names", [("path", Json::string(d))])), "names")),
    stat: p => stat(p, true),
    lstat: p => stat(p, false),
    real: p => p54_text(Some(ask("files.real", [("path", Json::string(p))])), "path").unwrap_or(p),
    read,
    read_all: p => read(p, 0.0, stat(p, true).size).0,
    copy_to: (p, to) => {
      let (bytes, _, _) = read(p, 0.0, stat(p, true).size)
      @drive.write_private_bytes(to, bytes)
    },
    write: (p, w) => {
      let m : Map[String, Json] = {
        "op": "files.write",
        "path": Json::string(p),
        "offset": Json::number(w.offset),
        "length": Json::number(w.data.length().to_double()),
        "create": Json::boolean(w.create),
        "roots": Json::array(roots.map(Json::string)),
        "protect": Json::array(protect.map(Json::string)),
      }
      match w.truncate {
        Some(t) => m["truncate"] = Json::number(t)
        None => ()
      }
      if w.sync {
        m["sync"] = Json::boolean(true)
      }
      match w.at_least {
        Some(least) => {
          // (what it is now first: smaller than asked, nothing written)
          let now = stat(p, true).size
          if now < least {
            return { size: now, short: true }
          }
        }
        None => ()
      }
      let (_, rest) = p54_helper_ask(dir, Json::object(m), w.data, 2)
      let text = @utf8.decode_lossy(rest).trim().to_owned()
      let done = @json.parse(text) catch { _ => raise p54_fs_error("EIO", "still.fail Helper ended before it answered") }
      match p54_text(Some(done), "error") {
        Some(why) => raise p54_fs_error(p54_text(Some(done), "code").unwrap_or("EIO"), why)
        None => ()
      }
      { size: p54_num(p54_get(Some(done), "size")).unwrap_or(0.0), short: false }
    },
    rename: (from, to) => ignore(ask("files.rename", [("from", Json::string(from)), ("to", Json::string(to))])),
    mkdir: (p, recursive) => ignore(ask("files.mkdir", [("path", Json::string(p)), ("recursive", Json::boolean(recursive))])),
    remove: p => ignore(ask("files.remove", [("path", Json::string(p))])),
    trash: (p, _, _) => p54_text(Some(ask("files.trash", [("path", Json::string(p))])), "to"),
    unlink: p => ignore(ask("files.unlink", [("path", Json::string(p))])),
  }
}

///|
/// The drive's `Protected` over still.fail Helper, where there is one (macOS): None elsewhere.
fn p54_helper_protected(bus : LiveBus, screens : P54Screens) -> @drive.Protected? {
  guard screens.files is Some(files) else { return None }
  let dir = path([bus.data, "helper"])
  Some({
    fs: (roots, protect) => p54_helper_fs(dir, roots, protect),
    known: top => files.known(top),
    check: tops => files.check(tops),
    ask: (grant, top) => {
      ignore(bus.host.rt.fork_quiet(name="helper window", async fn() { ignore(files.ask(grant, top)) catch { _ => () } }))
      "asking"
    },
  })
}
