///|
/// A stand-in for Feishu's open API, as station/test/feishu-fake.ts: each upload's file_type kept by its key, and a
/// message that sends a file as another type refused with 230055.
priv struct PostRig {
  surface : FeishuSurface
  rt : @effect.Runtime
  /// Each call as `verb path`, with the upload's file_type or the message's msg_type after it.
  seen : Array[String]
  /// The paths the disk has, with their bytes.
  disk : Map[String, Bytes]
  /// The code `/open-apis/im/v1/files` answers with (0: a key).
  files_code : Ref[Int]
}

///|
let post_kinds : Array[String] = ["mp4", "opus", "pdf", "doc", "xls", "ppt", "stream"]

///|
fn post_rig() -> PostRig {
  let rt = @effect.Runtime::new()
  let seen = []
  let files : Map[String, Bytes] = Map([])
  let uploads : Map[String, String] = Map([])
  let rig_code = Ref::new(0)
  let n = Ref::new(0)
  let answer = (j : JV) => { status: 200, headers: [("content-type", "application/json")], body: utf8(stringify(j)) }
  let fetch = async fn(req : HttpRequest) -> HttpResponse {
    let path = match req.url.find("?") {
      Some(i) => req.url.unsafe_substring(start=0, end=i)
      None => req.url
    }
    let path = path.unsafe_substring(start="http://fake".length(), end=path.length())
    let body = utf8_text(req.body.unwrap_or(b""))
    if path == "/open-apis/auth/v3/tenant_access_token/internal" {
      return answer(jobj([("code", Some(jnum(0.0))), ("tenant_access_token", Some(js("t"))), ("expire", Some(jnum(7200.0)))]))
    }
    if path == "/open-apis/im/v1/images" {
      seen.push("POST \{path}")
      return answer(jobj([("code", Some(jnum(0.0))), ("data", Some(jobj([("image_key", Some(js("img_1")))])))]))
    }
    if path == "/open-apis/im/v1/files" {
      let kind = post_kinds
        .filter(k => body.contains("name=\"file_type\"\r\n\r\n\{k}\r\n"))
        .get(0)
        .unwrap_or("stream")
      seen.push("POST \{path} \{kind}")
      if rig_code.val != 0 {
        return answer(jobj([("code", Some(jnum(rig_code.val.to_double()))), ("msg", Some(js("Invalid request param.")))]))
      }
      n.val += 1
      let key = "file_\{n.val}"
      uploads[key] = kind
      return answer(jobj([("code", Some(jnum(0.0))), ("data", Some(jobj([("file_key", Some(js(key)))])))]))
    }
    if path == "/open-apis/im/v1/messages" {
      let j = try_parse(body)
      let msg_type = text(jget(j, "msg_type"))
      seen.push("POST \{path} \{msg_type}")
      let key = text(jget(try_parse(text(jget(j, "content"))), "file_key"))
      match uploads.get(key) {
        Some(kind) if msg_type is ("file" | "media" | "audio") && msg_type != file_msg_type(kind) =>
          return answer(
            jobj([
              ("code", Some(jnum(230055.0))),
              ("msg", Some(js("The type of file upload does not match the type of message being sent."))),
            ]),
          )
        _ => ()
      }
      n.val += 1
      return answer(jobj([("code", Some(jnum(0.0))), ("data", Some(jobj([("message_id", Some(js("om_bot\{n.val}")))])))]))
    }
    seen.push("\{req.verb} \{path}")
    answer(jobj([("code", Some(jnum(0.0))), ("data", Some(jobj([])))]))
  }
  let net : Net = { fetch, now: () => 0L, sleep: async fn(_) { () }, stand_in: None }
  let disk : Disk = {
    read: async fn(p) { files.get(p) },
    write_private: async fn(_, _) { () },
    mkdir: async fn(_) { () },
    put_new: async fn(_, _) { () },
  }
  let log : Log = { say: (_, _, _, _) => () }
  let threads : FeishuThreads = {
    path: "threads.json",
    file: PrivateFile::new(disk, "threads.json"),
    log,
    kept: jobj([]),
  }
  let surface = FeishuSurface::new({
    connect: "fs",
    app_id: "cli_test",
    app_secret: "s",
    domain: "feishu",
    threads,
    thread_mode: false,
    direct_threads: false,
    book: None,
    client: Some(FeishuClient::new(net, "cli_test", "s", base="http://fake")),
    net,
    words: { tr: (_, key, _) => key, station_lang: () => "zh" },
    log,
    disk,
    rt,
  }) catch {
    e => abort(error_words(e))
  }
  { surface, rt, seen, disk: files, files_code: rig_code }
}

///|
/// A post run to its end: its message id, or what it was refused with.
fn PostRig::post(self : PostRig, files : Array[Attachment]) -> Result[String, String] {
  let fiber = self.rt.fork(async fn() {
    self.surface.post({ channel: "oc_g", thread_ts: "om_a" }, "说明文字", files) catch {
      e => Err(error_words(e))
    } noraise {
      id => Ok(id)
    }
  })
  ignore(self.rt.run_ready())
  match fiber.poll() {
    Some(Succeeded(v)) => v
    _ => abort("post did not finish")
  }
}

///|
test "file_type: only .mp4 goes up as mp4, a QuickTime .mov or .m4v as a plain file" {
  assert_eq(file_type("clip.MP4"), "mp4")
  assert_eq(file_type("movie.mov"), "stream")
  assert_eq(file_type("movie.m4v"), "stream")
  assert_eq(file_type("voice.opus"), "opus")
  assert_eq(file_type("report.pdf"), "pdf")
  assert_eq(file_msg_type("mp4"), "media")
  assert_eq(file_msg_type("opus"), "audio")
  assert_eq(file_msg_type("stream"), "file")
  assert_eq(file_msg_type("pdf"), "file")
}

///|
test "post: each file goes as the message type its upload's file_type takes (FB-41)" {
  let r = post_rig()
  let names = ["clip.mp4", "voice.opus", "movie.mov", "report.pdf", "shot.png"]
  for name in names {
    r.disk["/d/\{name}"] = utf8(name)
  }
  let got = r.post(names.map(name => { path: "/d/\{name}", name }))
  assert_true(got is Ok(_))
  assert_eq(r.seen, [
    "POST /open-apis/im/v1/files mp4",
    "POST /open-apis/im/v1/files opus",
    "POST /open-apis/im/v1/files stream",
    "POST /open-apis/im/v1/files pdf",
    "POST /open-apis/im/v1/images",
    "POST /open-apis/im/v1/messages post",
    "POST /open-apis/im/v1/messages media",
    "POST /open-apis/im/v1/messages audio",
    "POST /open-apis/im/v1/messages file",
    "POST /open-apis/im/v1/messages file",
    "POST /open-apis/im/v1/messages image",
  ])
}

///|
test "post: a file that cannot be uploaded or read fails the post before any message is sent (FB-41)" {
  let r = post_rig()
  r.disk["/d/clip.mp4"] = b"mp4"
  r.files_code.val = 234001
  assert_true(r.post([{ path: "/d/clip.mp4", name: "clip.mp4" }]) is Err(_))
  assert_true(r.post([{ path: "/d/gone.pdf", name: "gone.pdf" }]) is Err(_))
  assert_eq(r.seen.filter(s => s.has_prefix("POST /open-apis/im/v1/messages")), [])
}
