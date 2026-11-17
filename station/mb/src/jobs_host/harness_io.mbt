// The harness's cases that read and write the disk, run programs or talk to a server the test runs.

///|
/// A station of the workspace as a remote case has it: its files under `root`; `whole` false, one from before
/// (chunks only, no bytes after a request).
fn station_double(host : @host.Host, root : String, whole : Bool, told : Json, asked : Array[Json]) -> Ask {
  async fn(station, request, body) {
    asked.push(obj([("station", jstr(station)), ("method", field_or_null(request, "method"))]))
    match text(request, "method") {
      "file.get" => {
        let req = if whole { request } else { Json::object(without(request, ["whole"])) }
        file_get(host, pjoin([root, text(request, "path")]), req) catch {
          e => raise Refused(words_of(e))
        }
      }
      "file.put" => {
        if body is Some(_) && !whole {
          raise NoBytes("no bytes after a request")
        }
        let path = pjoin([root, js_text_or_empty(field(request, "path"))])
        (file_put(host, path, request, body) catch { e => raise Refused(words_of(e)) }, None)
      }
      "task.files" =>
        match field(told, "taskFiles") {
          Some(String("unsupported")) => raise Refused("unsupported peer method task.files")
          Some(v) => (v, None)
          None => raise Unreached("not reached")
        }
      "sync.changes" =>
        match field(told, "changes") {
          Some(String(e)) => raise Refused(e)
          Some(v) => (v, None)
          None => raise Unreached("not reached")
        }
      m => raise Refused("unsupported peer method \{m}")
    }
  }
}

///|
async fn io_case(host : @host.Host, op : String, c : Json) -> Json raise {
  let t = (k : String) => text(c, k)
  match op {
    "gpus" => {
      // {os, arch, steps: [{at, outputs: {command: {out} | null | "absent"}}], linux: [[{vendor, gpu}]]}
      let now = Ref(0.0)
      let outputs : Ref[Json] = Ref(Json::object(Map([])))
      let linux_reads = list_of(field(c, "linux"))
      let linux_at = Ref(0)
      let asked = []
      let g = Gpus::new(
        async fn(file, _, _) {
          asked.push(jstr(file))
          ran_from(field(outputs.val, file))
        },
        t("os"),
        t("arch"),
        () => now.val,
        async fn() {
          let k = linux_at.val
          linux_at.val += 1
          let cards = if k < linux_reads.length() { list_of(Some(linux_reads[k])) } else { [] }
          cards.map(x => LinuxGpu::{
            vendor: text(x, "vendor"),
            gpu: {
              name: text(or_null(field(x, "gpu")), "name"),
              cores: None,
              memory_total: None,
              memory_used: None,
              busy: num(field(or_null(field(x, "gpu")), "busy")),
            },
          })
        },
      )
      let out = []
      for s in list_of(field(c, "steps")) {
        now.val = num(field(s, "at")).unwrap_or(0.0)
        outputs.val = or_null(field(s, "outputs"))
        out.push(obj([("read", opt_gpus(g.read())), ("cached", opt_gpus(g.cached()))]))
      }
      obj([("reads", Json::array(out)), ("asked", Json::array(asked))])
    }
    "gpu.linux" => {
      let lspci = ran_from(field(c, "lspci"))
      let io = LinuxIo::shell(host, async fn(_, _, _) { lspci })
      Json::array(
        linux_gpus(io, root=t("root")).map(x => obj([("vendor", jstr(x.vendor)), ("gpu", x.gpu.to_json())])),
      )
    }
    "load.measure" => {
      let recent = match field(c, "recent") {
        Some({ "busy": Number(b, ..), "seconds": Number(s, ..), .. }) => Some((b, s))
        _ => None
      }
      measure(
        async fn() { or_null(field(c, "info")) },
        async fn() { or_null(field(c, "gpus")) },
        async fn() { recent },
        () => or_null(field(c, "running")),
        () => or_null(field(c, "relay")),
      )
    }
    "ws.reader" => workspace_reader_case(host, c)
    "ws.watch" => workspace_watch_case(host, c)
    "links.body" => {
      let chunks = list_of(field(c, "chunks")).map(x => base64_of(Some(x)))
      let at = Ref(0)
      let res : Answer = {
        status: 200,
        headers: [],
        url: "",
        close: async fn() {  },
        next: async fn() {
          if at.val >= chunks.length() {
            None
          } else {
            at.val += 1
            Some(chunks[at.val - 1])
          }
        },
      }
      let max = num(field(c, "max")).unwrap_or(0.0).to_int()
      jstr(@base64.encode(body_up_to(res, max, until_head=field(c, "untilHead") is Some(True))))
    }
    "links.getAt" => {
      guard @cloud_net.parse_url(t("url")) is Some(u) else { raise HostError("bad url") }
      match get_at_on(host, u, list_of(field(c, "addresses")).map(js_text), t("accept")) {
        None => Json::null()
        Some(res) => {
          let body = body_up_to(res, 1 << 20)
          obj([
            ("status", jint(res.status)),
            ("type", or_null(res.header("content-type").map(jstr))),
            ("body", jstr(@utf8.decode_lossy(body))),
          ])
        }
      }
    }
    "links.preview" => {
      // the world a preview sees: names resolve to `lookup`, GitHub's API answers `api` (by path)
      let api = or_null(field(c, "api"))
      let lookup = or_null(field(c, "lookup"))
      let io : LinkIo = {
        lookup: async fn(name) { list_of(field(lookup, name)).map(js_text) },
        get_at: async fn(url, addresses, accept) { get_at_on(host, url, addresses, accept) },
        github_api: async fn(path) {
          match field(api, path) {
            Some(v) => v
            None => raise HostError("GitHub answered 404")
          }
        },
        thumbnail: async fn(_, _) { None },
      }
      or_null(LinkPreviews::new(io).preview(t("href"), 0.0))
    }
    "preview.proxy" => {
      let body = match field(c, "body") {
        Some(String(_)) as b => Some(base64_of(b))
        _ => None
      }
      let asker = if t("asker") == "peer" { Peer } else { Preview }
      let a = proxy_preview(
        host,
        t("method"),
        header_pairs(field(c, "headers")),
        body,
        num(field(c, "port")).unwrap_or(0.0).to_int(),
        t("path"),
        t("lang"),
        asker~,
      )
      let buf = @buffer.new()
      while true {
        guard (a.next)() is Some(b) else { break }
        buf.write_bytes(b)
      }
      obj([
        ("status", jint(a.status)),
        ("headers", header_json(a.headers)),
        ("body", jstr(@base64.encode(buf.to_bytes()))),
      ])
    }
    "preview.ws" => {
      // the client's frames given whole, then its stream's end (or not, `hold`); what the client was sent
      let incoming = [base64_of(field(c, "client"))]
      let hold = field(c, "hold") is Some(True)
      let socket = open_socket(
        host,
        header_pairs(field(c, "headers")),
        num(field(c, "port")).unwrap_or(0.0).to_int(),
        t("path"),
        t("lang"),
      ) catch {
        SocketRefused(status, words) => return obj([("refused", jint(status)), ("words", jstr(words))])
      }
      let sent = @buffer.new()
      let reader = FrameReader::new(async fn() {
        if incoming.length() > 0 {
          Some(incoming.remove(0))
        } else if hold {
          @effect.never()
        } else {
          None
        }
      })
      pump_socket(host.rt, socket, reader, {
        write: async fn(b) { sent.write_bytes(b) },
        finish: async fn() {  },
      })
      obj([("protocol", or_null(socket.protocol.map(jstr))), ("sent", jstr(@base64.encode(sent.to_bytes())))])
    }
    "dirsync.patch" => {
      let changes = list_of(field(c, "changes")).map(x => Change::{
        path: text(x, "path"),
        old: text(x, "old"),
        mode: text(x, "mode"),
        after: match field(x, "after") {
          Some(String(_)) as a => Some(base64_of(a))
          _ => None
        },
        after_mode: str_opt(field(x, "afterMode")),
      })
      match patch_of(host, t("dir"), t("prefix"), t("scratch"), changes) {
        Some(p) => obj([("patch", jstr(p.patch)), ("missing", Json::array(p.missing.map(jstr)))])
        None => Json::null()
      }
    }
    _ => remote_or_jobs_case(host, op, c)
  }
}
