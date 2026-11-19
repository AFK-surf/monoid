// A service's page over the fixture (APP=sffix MBUI_FIXTURE=service | service-sized | service-restart |
// service-stopped; scripts/shots.sh service, web-service): the first row's chat's web service (slice 8's j-web), its page
// answered as a station would (`station.preview`: a made-up page, its stylesheet; the rest not found), its resources'
// ring, laid out as a phone's on the canvas, being started again, stopped. Every word in it is made up.

///|
pub let fix_service_html : String =
  #|<!doctype html>
  #|<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  #|<link rel="stylesheet" href="/app.css"><title>发布看板</title></head>
  #|<body><header>发布看板</header>
  #|<main><div class="card"><b>今日构建</b><p>3 个通过，1 个在跑</p><div class="bar" style="width:75%"></div></div>
  #|<div class="card"><b>待确认</b><p>安卓包签名、更新说明</p><div class="bar" style="width:40%"></div></div>
  #|<p id="n">脚本还没有运行</p></main>
  #|<script>document.getElementById('n').textContent = '脚本已运行：' + (6 * 7);</script>
  #|</body></html>

///|
pub let fix_service_css : String =
  #|body { margin: 0; font-family: system-ui, sans-serif; color: #24272b; background: #f7f6f3; }
  #|header { padding: 18px 20px; font-size: 20px; font-weight: 700; background: #e5704a; color: #fff; }
  #|main { padding: 12px 16px; }
  #|.card { background: #fff; border-radius: 12px; padding: 14px; margin: 10px 0; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  #|.card p { margin: 6px 0 10px; color: #646970; }
  #|.bar { height: 8px; border-radius: 4px; background: #2f8f5b; }

///|
/// The service's own topics: its job (as the mode has it) and how its page's resources came.
pub fn fixture_service_topic(f : Fixture, name : String, params : Map[String, Json]) -> Json? {
  match name {
    "job" => {
      let m = match fix_job(text(Some(Json::object(params)), "id")) {
        Object(m) => m.copy()
        _ => return Some(Json::null())
      }
      if f.mode == "service-restart" {
        m["state"] = Json::string("exited")
        m["tone"] = Json::string("restart")
        m["restarts"] = Json::number(2.0)
      }
      if f.mode == "service-stopped" {
        m["state"] = Json::string("stopped")
        m["tone"] = Json::string("off")
        m["open"] = Json::boolean(false)
      }
      Some(Json::object(m))
    }
    "previewLoad" =>
      Some({
        "percent": 75,
        "total": 4,
        "finished": 3,
        "failed": 0,
        "resources": [
          { "id": 1, "method": "GET", "path": "/", "since": 0, "ended": 42, "status": 200 },
          { "id": 2, "method": "GET", "path": "/app.css", "since": 50, "ended": 61, "status": 200 },
          { "id": 3, "method": "GET", "path": "/favicon.ico", "since": 52, "ended": 60, "status": 404 },
          { "id": 4, "method": "GET", "path": "/api/builds", "since": 70 },
        ],
      })
    _ => None
  }
}

///|
/// `station.preview` as a station answers it: the page and its stylesheet, anything else not found; the head, then
/// the body in one piece.
pub fn fixture_stream(
  name : String,
  params : Json,
  on_value : (Json, Bytes?) -> Unit,
  done : (Result[Json, Json]) -> Unit,
  mode? : String = "",
) -> Int {
  if name == "screen.view" {
    // a link's card's preview (screen_links.mbt: peek), or the viewer's (screen.mbt)
    if params is Object(o) && o.get("peek") is Some(True) {
      return fixture_peek(on_value)
    }
    return (@sfbase.screen_made_stream.val)(params, on_value, done)
  }
  if name == "terminal.view" {
    return fixture_terminal_view(params, on_value, mode~)
  }
  if name == "farview.view" {
    return fixture_farview_view(on_value)
  }
  if name != "station.preview" {
    done(Err({ "code": "unknown_call", "message": "这份假数据没有 " + name }))
    return 0
  }
  let path = text(Some(params), "path")
  let (status, kind, body) = match path {
    "/" | "/index.html" => (200, "text/html; charset=utf-8", fix_service_html)
    "/app.css" => (200, "text/css; charset=utf-8", fix_service_css)
    _ => (404, "text/plain; charset=utf-8", "Not Found")
  }
  on_value({ "head": { "status": status, "headers": [["Content-Type", kind]] } }, None)
  on_value({ "chunk": true }, Some(@utf8.encode(body)))
  done(Ok(Json::null()))
  fix_stream_ids.val += 1
  fix_stream_ids.val
}

///|
pub let fix_stream_ids : Ref[Int] = Ref(0)

///|
/// A chat's Farview tab as its host shows it (farview_tab.mbt): live, a sign-in page sent whole on Farview's doc wire
/// (fvclient/doc's Mirror, as a host makes it), and an agent driving the tab.
fn fixture_farview_view(on_value : (Json, Bytes?) -> Unit) -> Int {
  fix_farview_tell.val = Some(on_value)
  fix_farview_went.clear()
  fix_farview_went.push("https://mail.example.test/login")
  fix_farview_at.val = 0
  on_value({ "state": { "phase": "live", "opens": 1 } }, None)
  let doc = @html.parse(fix_farview_html)
  // (the help's picture as its host has it fetched: its whole address and its size)
  fn mark(n : @html.Node) -> Unit {
    if n.tag == "img" {
      n.src_url = Some("https://mail.example.test/mark.png")
      n.natural = Some((24.0, 8.0))
    }
    n.children.each(mark)
  }

  mark(doc)
  let state : @doc.DocState = {
    base: "https://mail.example.test/",
    root: doc,
    frames: [],
    sheets: [("https://mail.example.test/s.css", fix_farview_css)],
    cssom: [],
    defined: fn(_) { false },
    states: fn(_) { 0 },
    target: "",
  }
  on_value({ "data": true }, Some(@proto.encode_host(Meta("https://mail.example.test/login", "登录", false, false, false))))
  on_value({ "data": true }, Some(@proto.encode_host(Reset(1, 0, @doc.Mirror::new().reset(state)))))
  // (the help's picture, a PNG: what the page's menu copies as a picture)
  on_value({ "data": true }, Some(@proto.encode_host(Asset("https://mail.example.test/mark.png", 0, 24.0, 8.0, fix_farview_mark()))))
  on_value({ "data": true }, Some(@proto.encode_host(AgentOn(true))))
  fix_stream_ids.val += 1
  fix_stream_ids.val
}

///|
/// What the tab's stage said (`farview.send`, its client wire), done as its host does what moves the tab through what
/// it was shown: an address gone to, back and forward, its bar told where it is and which ways it can go (Meta). True
/// where it was such.
fn fixture_farview_said(bytes : Bytes) -> Bool {
  guard fix_farview_tell.val is Some(tell) else { return false }
  let framer = @proto.Framer::new()
  framer.push(bytes[:])
  let mut said = false
  while framer.next() is Some(body) {
    guard @proto.decode_client(body) is Some(Nav(kind, url)) else { continue }
    let went = fix_farview_went
    // (an address of a file: what the page downloads, the tab staying where it is)
    if kind == @proto.NAV_GO && url.has_suffix(".pdf") {
      let name = match url.rev_find("/") {
        Some(i) => url.to_array()[i + 1:].iter().fold(init="", fn(a, c) { a + c.to_string() })
        None => url
      }
      tell({ "data": true }, Some(@proto.encode_host(Downloaded(name, url, "application/pdf", @utf8.encode("%PDF-1.4 Farview")))))
      said = true
      continue
    }
    if kind == @proto.NAV_GO && url != "" {
      while went.length() > fix_farview_at.val + 1 {
        went.pop() |> ignore
      }
      went.push(if url.contains("://") { url } else { "https://" + url + "/" })
      fix_farview_at.val = went.length() - 1
    } else if kind == @proto.NAV_BACK && fix_farview_at.val > 0 {
      fix_farview_at.val -= 1
    } else if kind == @proto.NAV_FORWARD && fix_farview_at.val + 1 < went.length() {
      fix_farview_at.val += 1
    } else {
      continue
    }
    let at = fix_farview_at.val
    tell({ "data": true }, Some(@proto.encode_host(Meta(went[at], "登录", false, at > 0, at + 1 < went.length()))))
    said = true
  }
  said
}

///|
// kept across runs: the tab a fixture's farview.view opened last, reset with the fixture (made.mbt)
let fix_farview_tell : Ref[((Json, Bytes?) -> Unit)?] = Ref(None)

///|
// kept across runs: where that tab went and where it is, reset with the fixture (made.mbt)
let fix_farview_went : Array[String] = []

///|
// kept across runs: reset with the fixture (made.mbt)
let fix_farview_at : Ref[Int] = Ref(0)

///|
let fix_farview_html : String = "<!doctype html><html><head><link rel=stylesheet href=s.css></head><body>" +
  "<main class=card><h1>登录</h1><p class=sub>继续前往邮箱</p><label>邮箱或用户名</label>" +
  "<input class=field value=\"\"><button class=go>继续</button>" +
  "<p class=help>登录遇到问题？查看<a href=\"https://mail.example.test/help\">登录帮助</a>，" +
  "或在登录帮助里找回邮箱。登录帮助也说明了两步验证。</p>" +
  "<a href=\"https://mail.example.test/about\"><img class=mark src=mark.png alt=Mail></a></main></body></html>"

///|
let fix_farview_css : String = "body { margin: 0; background: rgb(244, 241, 252); font-family: sans-serif } " +
  ".card { box-sizing: border-box; margin: 40px auto; max-width: 400px; padding: 32px; background: white; border-radius: 24px } " +
  "h1 { margin: 0 0 8px; font-size: 28px } .sub { margin: 0 0 24px; color: rgb(90, 90, 100) } " +
  "label { display: block; margin-bottom: 8px; font-weight: 600 } " +
  ".field { display: block; box-sizing: border-box; width: 100%; height: 44px; border: 1px solid rgb(109, 74, 255); border-radius: 8px } " +
  ".help { margin: 24px 0 12px; color: rgb(90, 90, 100); line-height: 1.6 } .help a { color: rgb(109, 74, 255) } " +
  ".mark { display: block; width: 96px; height: 32px } " +
  ".go { display: flex; align-items: center; justify-content: center; width: 100%; height: 44px; margin-top: 24px; border: 0; border-radius: 8px; background: rgb(109, 74, 255); color: white; font-size: 16px }"

///|
/// The help's picture: a PNG 24 by 8 of the page's violet (drawn 96 by 32: small, as a test's host holds few bytes).
fn fix_farview_mark() -> Bytes {
  let px = FixedArray::make(24 * 8 * 4, b'\x00')
  for i in 0..<(24 * 8) {
    px[i * 4] = b'\x6D'
    px[i * 4 + 1] = b'\x4A'
    px[i * 4 + 2] = b'\xFF'
    px[i * 4 + 3] = b'\xFF'
  }
  @pixels.png(24, 8, px)
}
