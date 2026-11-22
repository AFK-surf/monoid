// The other stations of a workspace as places for a station's copies (peers.ts): which of them keep a station's
// (rendezvous over the workspace's stations), the place one of them is over the station transport (`replica.*`), and
// what a station answers of those it keeps.

///|
/// How many other stations keep a station's copies.
pub let copies_kept = 2

///|
/// A batch, a head or a listing at most, as a request's or an answer's bytes.
pub let peer_most : Double = 268435456.0

///|
/// Every station of `stations` but `origin`, in the order they keep `origin`'s copies.
pub fn ranked(ws : String, origin : String, stations : Array[String]) -> Array[String] {
  let scored = uniq(stations).filter(s => s != origin).map(s => (sha256_text("\{ws}\n\{origin}\n\{s}"), s))
  scored.sort_by((a, b) => js_cmp(b.0, a.0))
  scored.map(x => x.1)
}

///|
/// The stations that keep `origin`'s copies in `ws`: the min(COPIES, others) whose hash with it is highest.
pub fn keepers(ws : String, origin : String, stations : Array[String]) -> Array[String] {
  let r = ranked(ws, origin, stations)
  if r.length() > copies_kept {
    r[0:copies_kept].to_array()
  } else {
    r
  }
}

///|
/// Another station of the workspace as a place for copies.
pub fn peer_place(w : World, station : String) -> Place {
  {
    held: async fn(ws, origin) {
      let got = w.ask_bytes(station, jo([("method", js("replica.held")), ("workspace", js(ws)), ("origin", js(origin)), ("whole", jb(true))]))
      match got.body {
        None => Held::nothing()
        Some(b) => {
          let v = parse(@utf8.decode_lossy(b.whole(w.fs, most=peer_most)))
          Held::of_json(v)
        }
      }
    },
    put: async fn(ws, origin, gen, kind, name, bytes) {
      ignore(
        w.ask(
          station,
          jo([("method", js("replica.put")), ("workspace", js(ws)), ("origin", js(origin)), ("gen", js(gen)), ("kind", js(kind)), ("name", js(name))]),
          body=Whole(bytes),
        ),
      )
    },
    put_file: async fn(ws, origin, hash, source) {
      let size = match w.fs.stat(source) {
        Some((_, s, _)) => s
        None => raise Thrown("Error", jo([("message", js("ENOENT: no such file or directory, stat '\{source}'")), ("code", js("ENOENT"))]))
      }
      ignore(
        w.ask(
          station,
          jo([("method", js("replica.put")), ("workspace", js(ws)), ("origin", js(origin)), ("kind", js("file")), ("name", js(hash))]),
          body=File(source, 0.0, size),
        ),
      )
    },
    drop: async fn(ws, origin, gen, batches, files) {
      ignore(
        w.ask(
          station,
          jo([
            ("method", js("replica.drop")),
            ("workspace", js(ws)),
            ("origin", js(origin)),
            ("gen", js(gen)),
            ("batches", jstrs(batches)),
            ("files", jstrs(files)),
          ]),
        ),
      )
    },
  }
}

///|
/// The stations whose copies `station` keeps in `ws`, each generation's head.
pub async fn peer_origins(w : World, station : String, ws : String) -> Array[(String, Array[J])] {
  let got = w.ask_bytes(station, jo([("method", js("replica.list")), ("workspace", js(ws)), ("whole", jb(true))]))
  match got.body {
    None => []
    Some(b) => {
      let list = parse(@utf8.decode_lossy(b.whole(w.fs, most=peer_most)))
      items(Some(list)).map(o => (text_at(o, "origin"), items(at(o, "heads"))))
    }
  }
}

///|
/// A batch, a head (`gen` its generation) or a file (`gen` None) `station` keeps, whole.
pub async fn peer_read(w : World, station : String, ws : String, origin : String, gen : String?, name : String) -> Body {
  let got = w.ask_bytes(
    station,
    jo([("method", js("replica.get")), ("workspace", js(ws)), ("origin", js(origin)), ("gen", jopt(gen)), ("name", js(name)), ("whole", jb(true))]),
  )
  match got.body {
    Some(b) => b
    None => raise failed("\{station} sent nothing of \{name}")
  }
}

///|
/// What a station answers of the copies it keeps, as `place` holds them (peers.ts `serve`).
pub struct Serving {
  place : FolderPlace
  in_workspace : (String, String) -> Bool
  hello : (String, String, Array[String], Bool) -> Array[String]
  accept_others : (() -> Bool)?
}

///|
pub async fn serve(s : Serving, peer : String, request : J, body : Body?, workspace : String?) -> Answer {
  let fs = s.place.fs
  let ws = str_at(request, "workspace").unwrap_or("")
  if !is_workspace(ws) || (workspace is Some(w) && w != ws) || !(s.in_workspace)(peer, ws) {
    raise refused("not a station of this workspace")
  }
  let origin = str_at(request, "origin").unwrap_or("")
  let text = (v : J) => {
    let b = @utf8.encode(stringify(v))
    { value: jo([("size", ji(b.length()))]), body: Some(Whole(b)) }
  }
  match str_at(request, "method") {
    Some("replica.hello") => {
      let formerly = strings_of(at(request, "formerly")).filter(is_station)
      let peer_accepts = match at(request, "acceptCopies") {
        Some(Bool(false)) => false
        _ => true
      }
      let my_accepts = match s.accept_others {
        Some(f) => f()
        None => true
      }
      { value: jo([("formerly", jstrs((s.hello)(peer, ws, formerly, peer_accepts))), ("acceptCopies", jb(my_accepts))]), body: None }
    }
    Some("replica.list") => text(origins_json(s.place.origins(ws)))
    Some("replica.held") => {
      if !is_station(origin) {
        raise refused("not a station")
      }
      text(s.place.held(ws, origin).to_json())
    }
    Some("replica.get") => {
      let gen = match at(request, "gen") {
        Some(Null) => None
        Some(Str(u)) => Some(@jsjson.sanitize_str(u))
        None => Some("")
        Some(v) => Some(@jsjson.stringify(v))
      }
      let name = str_at(request, "name").unwrap_or("")
      if !is_station(origin) || (gen is Some(g) && !is_gen(g)) {
        raise refused("not a copy's name")
      }
      guard s.place.path_of(ws, origin, gen, name) is Some(path) else { raise refused("\{name} is not kept here") }
      let size = match fs.stat(path) {
        Some((_, n, _)) => n
        None => 0.0
      }
      { value: jo([("size", jn(size))]), body: Some(File(path, 0.0, size)) }
    }
    Some("replica.put") => {
      match s.accept_others {
        Some(f) if !f() => raise refused("not accepting copies")
        _ => ()
      }
      guard body is Some(b) else { raise refused("nothing sent") }
      let name = str_at(request, "name").unwrap_or("")
      let kind = text_at(request, "kind")
      if kind == "file" {
        if !is_hash(name) {
          raise refused("not a file's hash")
        }
        s.place.put_file_from(ws, origin, name, b.reader(fs))
        return { value: jo([("ok", jb(true))]), body: None }
      }
      let gen = str_at(request, "gen").unwrap_or("")
      if kind == "batch" && !is_batch(name) {
        raise refused("not a batch's name")
      }
      if kind != "batch" && kind != "head" {
        raise refused("not a kind of copy")
      }
      s.place.put(ws, origin, gen, kind, name, b.whole(fs, most=peer_most))
      { value: jo([("ok", jb(true))]), body: None }
    }
    Some("replica.drop") => {
      // Only the station a copy is of says what of it goes; the rest only add to it.
      if peer != origin {
        raise refused("only the station a copy is of folds it")
      }
      s.place.drop(ws, origin, text_at(request, "gen"), strings_of(at(request, "batches")), strings_of(at(request, "files")))
      { value: jo([("ok", jb(true))]), body: None }
    }
    _ => raise refused("no such replica request")
  }
}
