// The file preview over made-up files (APP=sffix MBUI_FIXTURE=chat-preview-<what>: the first row's chat with a file
// of it open in the preview; scripts/shots.sh preview, web-preview): a picture, a PDF of two pages, a video (whose
// reads are never answered: the player waits, as on a slow link, the same on every run), a song (its reads the same,
// how its player stands pinned), a page of HTML, code,
// Markdown, a table, and a file of no kind that can be shown; a second picture beside the first (the `imageNear` view:
// chat-preview-step with the ways to it, chat-preview-swipe halfway to it under a finger, chat-preview-swipe-wide as
// far on a wide window). Its bytes are made here; none is a real document.

///|
/// The made-up files, by the name the preview fetches them by: the file as a message has it, and its bytes.
pub fn preview_files() -> Array[(Attachment, () -> Bytes)] {
  let at = fn(name : String, size : Double, w : Double, h : Double) -> Attachment {
    { name, path: "uploads/fx/" + name, size, width: w, height: h, thumbhash: "", owner: "s-c1", upload: "", duration: 0.0, frames: 0, held: false }
  }
  [
    (at("界面草图.png", 18000.0, 600.0, 400.0), fn() { fixture_png(600, 400) }),
    (at("首页改版第三轮评审定稿前的对照截图（含深色与浅色两套）.png", 18000.0, 600.0, 400.0), fn() { fixture_png(600, 400) }),
    (at("第二版.png", 21000.0, 400.0, 560.0), fn() { fixture_png(400, 560) }),
    // 界面草图.png mirrored, before it (fixture_image_near): one stepped from as big as the one stepped to, another
    // picture
    (at("对照草图.png", 18000.0, 600.0, 400.0), fn() { fixture_png(600, 400, mirrored=true) }),
    // the chat's own picture (chat_fixture.mbt rich_chat), opened from its thumbnail there: the same picture
    (at("compare.png", 402000.0, 1600.0, 900.0), fn() { fixture_file_png("compare.png") }),
    (at("设计说明.pdf", 2400.0, 0.0, 0.0), fn() { fixture_pdf() }),
    // what its message says of it, as the station read it from its header: 12.5 s, 375 frames
    ({ ..at("演示录屏.mp4", 5242880.0, 1280.0, 720.0), duration: 12500.0, frames: 375 }, fn() { b"" }),
    ({ ..at("演示录屏.webm", 5242880.0, 1280.0, 720.0), duration: 12500.0, frames: 375 }, fn() { b"" }),
    (at("会议录音.m4a", 1489000.0, 0.0, 0.0), fn() { b"" }),
    (at("报告.html", 900.0, 0.0, 0.0), fn() { @utf8.encode(fixture_html) }),
    // the chat's visualization (chat_fixture.mbt MBUI_FIXTURE=chat-viz / chat-mbui)
    (at("release.html", 1200.0, 0.0, 0.0), fn() { @utf8.encode(fixture_viz_html) }),
    (at("release.mbui", 1600.0, 0.0, 0.0), fn() { @utf8.encode(fixture_viz_mbui) }),
    (at("memory-schemes.mbui", 2400.0, 0.0, 0.0), fn() { @utf8.encode(fixture_viz_memory_mbui) }),
    (at("list.ts", 600.0, 0.0, 0.0), fn() { @utf8.encode(fixture_code) }),
    (at("说明.md", 500.0, 0.0, 0.0), fn() { @utf8.encode(fixture_md) }),
    (at("长说明.md", 4200.0, 0.0, 0.0), fn() { @utf8.encode(fixture_md_long) }),
    (at("宽表格说明.md", 1600.0, 0.0, 0.0), fn() { @utf8.encode(fixture_md_wide) }),
    (at("数据.csv", 200.0, 0.0, 0.0), fn() { @utf8.encode(fixture_csv) }),
    (at("备份.bin", 4096.0, 0.0, 0.0), fn() { Bytes::makei(4096, fn(i) { (i % 7).to_byte() }) }),
    (at("测试版.apk", 8192.0, 0.0, 0.0), fn() { Bytes::makei(8192, fn(i) { (i % 5).to_byte() }) }),
    // the build its agent sent (MBUI_FIXTURE=chat-download, downloads_fixture.mbt): 50 MB as its message says
    (at("发布包.zip", 52428800.0, 0.0, 0.0), fn() { Bytes::makei(4096, fn(i) { (i % 3).to_byte() }) }),
  ]
}

///|
/// A file coming, never whole (MBUI_FIXTURE=chat-preview-coming, -coming-part, -apk-reading): its name, and what the core says of
/// how much has come of it, once, as it is asked for (None: nothing); none coming (None): every file whole at once.
pub let preview_coming : Ref[(String, Json?)?] = Ref(None)

///|
/// A picture whose bytes are no picture (MBUI_FIXTURE=chat-preview-broken): its name; none (None), each file's own.
pub let preview_broken : Ref[String?] = Ref(None)

///|
/// MBUI_FIXTURE=chat-preview-<what>: which file opens. (chat-view-side-audio: the song kept beside the chat stands as
/// chat-preview-audio's.)
pub fn fixture_preview(mode : String) -> Unit {
  if mode == "chat-view-side-audio" {
    match @sfbase.tab_viewer("ws1/st1:s-c1", fixture_view_tab(mode)) {
      Some(v) => v.pinned = Some(fixture_song_stands)
      None => ()
    }
    return
  }
  let which = match mode {
    "chat-preview-image" | "chat-preview-step" | "chat-preview-swipe" | "chat-preview-swipe-wide" | "chat-preview-coming" | "chat-preview-coming-part" | "chat-preview-broken" => "界面草图.png"
    "chat-preview-pdf" => "设计说明.pdf"
    "chat-preview-video" => "演示录屏.mp4"
    "chat-preview-webm" | "chat-preview-webm-unsupported" => "演示录屏.webm"
    "chat-preview-audio" => "会议录音.m4a"
    "chat-preview-html" => "报告.html"
    "chat-preview-mbui" => "release.mbui"
    "chat-preview-memory-mbui" => "memory-schemes.mbui"
    "chat-preview-code" => "list.ts"
    "chat-preview-md" => "说明.md"
    "chat-preview-csv" => "数据.csv"
    "chat-preview-none" => "备份.bin"
    "chat-preview-apk" | "chat-preview-apk-reading" => "测试版.apk"
    // (a picture whose name is far longer than a phone's bar has room for: the name cut short, the tools whole)
    "chat-preview-long" => "首页改版第三轮评审定稿前的对照截图（含深色与浅色两套）.png"
    _ => return
  }
  for f in preview_files() {
    if f.0.name == which {
      // (a picture coming: nothing said of how much, or a third of it; never whole)
      preview_coming.val = match mode {
        "chat-preview-coming" => Some((which, None))
        "chat-preview-coming-part" => Some((which, Some({ "loaded": 6000.0, "total": 18000.0 })))
        // (an APK asked to 安装, read as far as 25.7 MB of 40.9 MB)
        "chat-preview-apk-reading" => Some((which, Some({ "loaded": 26948403.0, "total": 42886758.0 })))
        _ => None
      }
      // (its bytes read whole, no picture in them: the host says it cannot decode them)
      preview_broken.val = if mode == "chat-preview-broken" { Some(which) } else { None }
      open_preview("ws1/st1", "s-c1", f.0, beside=false, steps=if mode == "chat-preview-image" || mode.has_prefix("chat-preview-coming") || mode == "chat-preview-broken" {
        NoSteps
      } else {
        InChat(Some(1.0), "s-c1")
      })
      // (halfway to the next on a phone; on a wide window as far, the next come in: the strip put there, held there
      // where an old view draws it, which puts it where it is pinned as it is built)
      let aside = match mode {
        "chat-preview-swipe" => Some(-150.0)
        "chat-preview-swipe-wide" => Some(-700.0)
        _ => None
      }
      match aside {
        Some(x) => {
          pv_strip.pinned = Some(x)
          pv_strip.way.put(x)
        }
        None => ()
      }
      if viewer.get() is Some(v) {
        if which.has_suffix(".m4a") {
          v.pinned = Some(fixture_song_stands)
        }
        if mode == "chat-preview-webm-unsupported" {
          v.pinned = Some({
            state: -2,
            duration: -1.0,
            position: 0.0,
            buffered: 0.0,
            playing: false,
            buffering: false,
            ended: false,
            width: 0.0,
            height: 0.0,
          })
        }
      }
    }
  }
}

///|
/// How the made-up song stands: paused at 0:31 of 1:35, the same on every run.
// kept across runs: a value (no field of it changes)
let fixture_song_stands : @player.MediaStatus = {
  state: 1,
  duration: 95000.0,
  position: 31000.0,
  buffered: 95000.0,
  playing: false,
  buffering: false,
  ended: false,
  width: 0.0,
  height: 0.0,
}

///|
/// What the fixture was asked with bytes, in order: the call and its params.
pub let fix_fetches : Array[(String, Json)] = []

///|
/// What the fixture answers with bytes: a made-up file whole (`station.file`) or a part of it (`station.file.part`;
/// a video's reads never answered).
pub fn fixture_fetch(
  name : String,
  params : Json,
  done : (Result[(Json, Bytes), Json]) -> Unit,
) -> Unit {
  fix_fetches.push((name, params))
  let p = Some(params)
  if name == "file.open" {
    let path = text(p, "path")
    // (what the device kept of one read before, given at once; one never read, none)
    if field(p, "kept") is Some(True) {
      if fix_named_kept.contains(path) {
        fixture_named(path, p, done)
      } else {
        done(Err({ "code": "not_kept", "message": "这份假数据没有留下 " + path }))
      }
      return
    }
    if fix_station_for.val <= 0.0 {
      fix_named_kept[path] = true
      fixture_named(path, p, done)
      return
    }
    fix_later(fix_station_for.val, fn() {
      fix_named_kept[path] = true
      fixture_named(path, p, done)
    })
    return
  }
  let file = text(p, "name")
  let mut found : Bytes? = None
  for f in preview_files() {
    if base_name(f.0.path) == file {
      found = Some(if preview_broken.val == Some(file) { Bytes::makei(18000, fn(i) { (i % 11).to_byte() }) } else { (f.1)() })
    }
  }
  let bytes = match found {
    Some(b) => b
    None => {
      done(Err({ "code": "not_found", "message": "这份假数据没有 " + file }))
      return
    }
  }
  match name {
    "station.file" => done(Ok(({ "type": "" }, bytes)))
    "station.file.part" => {
      if @sf.lower(file).has_suffix(".mp4") || @sf.lower(file).has_suffix(".webm") || @sf.lower(file).has_suffix(".m4a") {
        // the player waits on the network
        return
      }
      let from = number(p, "offset").to_int()
      let n = number(p, "length").to_int()
      let from = if from > bytes.length() { bytes.length() } else { from }
      let to = if from + n > bytes.length() { bytes.length() } else { from + n }
      done(Ok(({ "total": Json::number(bytes.length().to_double()) }, Bytes::makei(to - from, fn(i) { bytes[from + i] }))))
    }
    _ => done(Err({ "code": "unknown_call", "message": "这份假数据没有 " + name }))
  }
}

///|
/// The files a message names that the made-up device kept, read once (`file.open` with `kept`).
// kept across runs: put back as a fixture is made (made.mbt)
pub let fix_named_kept : Map[String, Bool] = Map([])

///|
/// A file a message names by its path (`file.open`), as the made-up station reads it: the rich chat's place.mbt, and
/// a long log (`logs/build.log`: a line a step, 600 KB and more); a part of it with `offset`, its whole size `size`.
pub fn fixture_named(path : String, p : Json?, done : (Result[(Json, Bytes), Json]) -> Unit) -> Unit {
  let bytes = match path {
    "src/list/place.mbt" =>
      @utf8.encode(
        "///|\n/// Rows put in before the anchor move it with them.\nfn ListState::moved(self : ListState, at : Int, n : Int) -> Unit {\n  if self.anchor >= at {\n    self.anchor = self.anchor + n\n  }\n}\n",
      )
    "logs/build.log" => fixture_log()
    _ => {
      done(Err({ "code": "http_404", "message": "No such file or directory" }))
      return
    }
  }
  let said : Json = { "name": Json::string(base_name(path)), "path": Json::string(path), "type": "text/plain", "size": Json::number(bytes.length().to_double()) }
  if field(p, "offset") is None && field(p, "length") is None {
    done(Ok((said, bytes)))
    return
  }
  let from = number(p, "offset").to_int()
  let n = number(p, "length").to_int()
  let from = if from > bytes.length() { bytes.length() } else { from }
  let to = if from + n > bytes.length() { bytes.length() } else { from + n }
  done(Ok((said, Bytes::makei(to - from, fn(i) { bytes[from + i] }))))
}

///|
// kept across runs: the log and the PDF as made once, the same bytes whoever asks (each is made of nothing else)
let fixture_made : Map[String, Bytes] = Map([])

///|
/// The long log: 12000 lines, each saying which it is (and some Chinese, cut across parts' ends). Made once: it is read
/// a part at a time, the whole of it asked for each part.
pub fn fixture_log() -> Bytes {
  match fixture_made.get("log") {
    Some(b) => return b
    None => ()
  }
  let b = fixture_log_made()
  fixture_made["log"] = b
  b
}

///|
fn fixture_log_made() -> Bytes {
  let sb = StringBuilder()
  for i in 1..=12000 {
    sb.write_string("[build] 第 \{i} 行：编译 src/module_\{i % 97}.mbt 完成，用时 \{i % 13} ms\n")
  }
  @utf8.encode(sb.to_string())
}

///|
// kept across runs: each picture as made once, the same bytes whoever asks (a picture is its size and side alone)
let fixture_pngs : Map[(Int, Int, Bool), Bytes] = Map([])

///|
/// A picture of its own: a soft gradient with a few shapes on it, as a sketch of a screen. Made once for each size and
/// side: every preview test opens these, and encoding one is a quarter-million pixels drawn and compressed again.
pub fn fixture_png(w : Int, h : Int, mirrored? : Bool = false) -> Bytes {
  match fixture_pngs.get((w, h, mirrored)) {
    Some(b) => return b
    None => ()
  }
  let b = fixture_png_made(w, h, mirrored)
  fixture_pngs[(w, h, mirrored)] = b
  b
}

///|
fn fixture_png_made(w : Int, h : Int, mirrored : Bool) -> Bytes {
  let rgba = FixedArray::make(w * h * 4, b'\x00')
  for y in 0..<h {
    for at in 0..<w {
      // (mirrored: the same picture, its card and button on the other side)
      let x = if mirrored { w - 1 - at } else { at }
      let k = (x + y).to_double() / (w + h - 2).to_double()
      let i = (y * w + at) * 4
      let mut r = 245.0 + (91.0 - 245.0) * k
      let mut g = 243.0 + (123.0 - 243.0) * k
      let mut b = 239.0 + (178.0 - 239.0) * k
      // a bar across the top, a card, a round button
      if y >= 24 && y < 72 && x >= 24 && x < w - 24 {
        r = 255.0
        g = 255.0
        b = 255.0
      }
      if y >= 104 && y < 296 && x >= 48 && x < 312 {
        r = 229.0
        g = 112.0
        b = 74.0
      }
      let dx = (x - 460).to_double()
      let dy = (y - 200).to_double()
      if dx * dx + dy * dy < 60.0 * 60.0 {
        r = 47.0
        g = 143.0
        b = 91.0
      }
      rgba[i] = r.round().to_int().to_byte()
      rgba[i + 1] = g.round().to_int().to_byte()
      rgba[i + 2] = b.round().to_int().to_byte()
      rgba[i + 3] = b'\xFF'
    }
  }
  @pixels.png(w, h, rgba)
}

///|
/// A PDF of two pages (US Letter), shapes and a few lines in Helvetica, its cross-reference table counted exactly. Made
/// once, as the log is.
pub fn fixture_pdf() -> Bytes {
  match fixture_made.get("pdf") {
    Some(b) => return b
    None => ()
  }
  let b = fixture_pdf_made()
  fixture_made["pdf"] = b
  b
}

///|
fn fixture_pdf_made() -> Bytes {
  let page1 =
    #|0.898 0.439 0.290 rg 56 680 500 56 re f
    #|BT /F1 28 Tf 1 1 1 rg 72 700 Td (Design notes) Tj ET
    #|0.141 0.153 0.169 rg
    #|BT /F1 14 Tf 72 620 Td (1. The list keeps its rows by their real heights.) Tj ET
    #|BT /F1 14 Tf 72 596 Td (2. Pictures load at the size they are shown.) Tj ET
    #|0.906 0.890 0.863 rg 72 300 468 240 re f
    #|0.357 0.482 0.698 rg 96 330 180 180 re f
    #|0.184 0.561 0.357 rg 320 420 190 30 re f
    #|BT /F1 12 Tf 0.4 0.4 0.4 rg 72 60 Td (Page 1 of 2) Tj ET
  let page2 =
    #|0.141 0.153 0.169 rg
    #|BT /F1 22 Tf 72 700 Td (Checklist) Tj ET
    #|BT /F1 14 Tf 72 650 Td (- Version and notes) Tj ET
    #|BT /F1 14 Tf 72 626 Td (- Both packages signed) Tj ET
    #|BT /F1 14 Tf 72 602 Td (- New screenshots) Tj ET
    #|0.898 0.439 0.290 rg 72 520 468 4 re f
    #|BT /F1 12 Tf 0.4 0.4 0.4 rg 72 60 Td (Page 2 of 2) Tj ET
  let objs = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>",
    "<< /Length \{page1.length()} >>\nstream\n" + page1 + "\nendstream",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>",
    "<< /Length \{page2.length()} >>\nstream\n" + page2 + "\nendstream",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  ]
  let sb = StringBuilder()
  sb.write_string("%PDF-1.4\n")
  let mut at = 9
  let offsets = []
  for i, o in objs {
    offsets.push(at)
    let s = "\{i + 1} 0 obj\n" + o + "\nendobj\n"
    sb.write_string(s)
    at = at + s.length()
  }
  sb.write_string("xref\n0 \{objs.length() + 1}\n0000000000 65535 f \n")
  for o in offsets {
    let d = "\{o}"
    sb.write_string("0000000000".exact_view(end=10 - d.length()).to_owned() + d + " 00000 n \n")
  }
  sb.write_string("trailer\n<< /Size \{objs.length() + 1} /Root 1 0 R >>\nstartxref\n\{at}\n%%EOF\n")
  @utf8.encode(sb.to_string())
}

///|
pub let fixture_html : String =
  #|<!doctype html>
  #|<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  #|<style>
  #|body { margin: 0; padding: 20px; font-family: system-ui, sans-serif; color: #24272b; background: #fff; }
  #|h1 { font-size: 22px; margin: 0 0 12px; }
  #|.card { background: #fbe6dc; border-radius: 12px; padding: 14px; margin: 12px 0; }
  #|.bar { height: 10px; border-radius: 5px; background: #e5704a; margin: 6px 0; }
  #|</style></head>
  #|<body>
  #|<h1>周报草稿</h1>
  #|<p>这是一页做测试用的网页，里面的脚本会写下一行字。</p>
  #|<div class="card"><div class="bar" style="width:80%"></div><div class="bar" style="width:55%"></div><div class="bar" style="width:30%"></div></div>
  #|<p id="n">脚本还没有运行</p>
  #|<script>document.getElementById('n').textContent = '脚本已运行：' + (6 * 7);</script>
  #|</body></html>

///|
pub let fixture_code : String =
  #|// 列表的行按真实高度排，没量过的先按估计的高度占位
  #|export function moved(rows: number[], at: number, n: number): number[] {
  #|  const out = rows.slice(0, at);
  #|  for (let i = 0; i < n; i++) out.push(-1);
  #|  return out.concat(rows.slice(at));
  #|}
  #|
  #|export const estimate = 66;

///|
pub let fixture_md : String =
  #|# 发布前要做的
  #|
  #|- 版本号和更新说明
  #|- 安卓和 mac 的包都签名
  #|- 截图换成**新的**
  #|
  #|> 第二屏的插画再小一点。
  #|
  #|`scripts/shots.sh` 会把新截图和旧的比一遍。

///|
/// A long Markdown document (more than two screens tall on 1280x800) for beside-chat reader tests and stills.
pub let fixture_md_long : String =
  #|# 发布前长说明
  #|
  #|这份长文档记录每次正式发版前的完整核对项，包含客户端构建、签名校验、离屏画面对比与回滚预案。
  #|
  #|## 第一节：版本号与更新说明
  #|
  #|先核对所有平台的版本号是否与主分支最新提交一致，再整理面向用户的中文更新说明。每一条变更都必须对应真实落地的功能或修复，不能遗漏关键平台标注。
  #|
  #|- 核对 `Changelog:` 行是否准确描述用户可见改动
  #|- 核对 `Changelog-parts:` 覆盖 web、android、desktop
  #|- 确认测试版号与实际跑完的流水线一致
  #|
  #|## 第二节：多端构建与签名
  #|
  #|各个平台的安装包都需要在构建机上完成签名和公证，确保安装过程不弹出异常拦截提示。打包产物上传后要检查校验和与下载链接。
  #|
  #|- macOS 应用完成公证并验证首次启动无拦截
  #|- Windows 安装包完成代码签名与自动更新验证
  #|- Android 正式包使用发布密钥签名并核对版本码
  #|
  #|## 第三节：离屏画面与交互核对
  #|
  #|所有涉及界面改动的分支在合并前都需要通过离屏渲染生成同尺寸、同数据的前后对比图，覆盖浅色与深色主题、常规字号与大字号，以及关键交互的完整过渡。
  #|
  #|- 检查大屏与小屏下的工具排对齐与圆角阶梯
  #|- 检查长文档滚动与悬浮提示是否被裁切
  #|- 检查暗色主题下文字与图标的对比度
  #|
  #|## 第四节：列表虚拟化与帧率检查
  #|
  #|列表视图需要在 60、120、24 和 7 帧每秒以及单步跳转下保持完全一致的停靠位置与可见项统计，不得引入帧率相关漂移。
  #|
  #|- 确认多帧率单测全部通过且无额外告警
  #|- 确认快速滚动与跳转文末后位置准确落定
  #|- 确认静置后阅读位置按预期写回本地记录
  #|
  #|## 第五节：网络与离线恢复
  #|
  #|在弱网或断网重连场景下，客户端应保留已打开的侧边文件标签页，并在连接恢复后自动同步最新状态，不丢失当前阅读进度。
  #|
  #|- 断网后重新打开已缓存文档仍可正常阅读
  #|- 重连后不会触发重复拉取或界面闪烁
  #|- 关闭标签页时释放阅读器状态与订阅
  #|
  #|## 第六节：兼容性与迁移
  #|
  #|新版本客户端需要与旧版本 station 共存，任何协议字段新增都必须保持向后兼容，数据库迁移只向前演进不破坏旧数据。
  #|
  #|- 核对最低兼容版本号与接口降级路径
  #|- 确认旧缓存文件可平滑升级无需手动清理
  #|- 确认升级后已有草稿与偏好设置完好保留
  #|
  #|## 第七节：回归验证清单
  #|
  #|在最终发布前逐项执行关键路径回归，确保没有遗留的审计告警或未收录的纯调用答案。
  #|
  #|- 对话旁打开短文档与长文档的工具排表现符合预期
  #|- 独立窗口缩到最小尺寸时按钮按次序收入更多菜单
  #|- 所有单元测试与静态检查零报错通过
  #|
  #|## 第八节：发版后巡检与回滚
  #|
  #|新版本发布后持续观察崩溃率、卡顿指标与用户反馈，若发现阻断性问题立即按既定流程回退至上一个稳定版本并通知相关成员。
  #|
  #|文档末尾：所有检查项已核对完毕。

///|
/// A Markdown document with long paragraphs and a 5-column table for beside-chat panel width tests and stills.
pub let fixture_md_wide : String =
  #|# 跨端发布核对表
  #|
  #|对话旁侧栏本身已经受到面板宽度的自然约束，当用户把侧栏拉宽以便同时对照多列表格与较长的技术说明段落时，如果正文列仍然按整窗阅读器的三十四字宽上限收紧，两侧就会留下大片空白，表格列也会被过早挤压换行。放宽侧栏面板内的正文宽度上限到四十八字宽后，长段文字和五列表格都能更舒展地展开，而切到全屏或独立窗口时依然保持三十四字宽的舒适行长。
  #|
  #|## 平台构建与签名状态
  #|
  #|| 平台 | 构建目标 | 签名状态 | 帧率门禁 | 备注 |
  #|| --- | --- | --- | --- | --- |
  #|| macOS | arm64 / universal | 已公证 | 60 / 120 / 24 / 7 | 侧栏与独立窗口均通过 |
  #|| Windows | x64 / arm64 | 代码签名 | 60 / 120 / 24 / 7 | 标题栏按钮对齐无告警 |
  #|| Android | arm64-v8a | 发布密钥 | 60 / 120 / 24 / 7 | 非 debuggable 包 |
  #|| iOS | arm64 | TestFlight | 60 / 120 / 24 / 7 | 竖横屏安全区正常 |
  #|| Web | wasm-gc | CDN 校验 | 60 / 120 / 24 / 7 | 与客户端共用一套渲染 |
  #|
  #|## 布局与阅读体验说明
  #|
  #|在默认窗口尺寸下如果侧栏宽度低于八百一十二像素，正文区会贴合面板减去左右边距后的全部可用宽度；一旦用户将窗口放大或拖动分割线把侧栏拉宽至一千像素附近，正文区会平滑扩展至七百六十八像素上限，不再受制于五百四十四像素的整窗窄列限制。

///|
pub let fixture_csv : String =
  #|名字,平台,帧时间（毫秒）,通过
  #|首页,安卓,0.42,是
  #|聊天,安卓,0.57,是
  #|聊天,mac,0.31,是
  #|"设置, 外观",web,0.66,否

///|
/// The `imageNear` view of the made-up chat: 界面草图.png has 第二版.png after it, the first of the two; 对照草图.png (no
/// message of the chat's) has 界面草图.png after it, as big as it.
pub fn fixture_image_near(params : Map[String, Json]) -> Json? {
  match params.get("path") {
    Some(String("uploads/fx/界面草图.png")) =>
      Some({
        "index": 0,
        "count": 2,
        "after": {
          "name": "第二版.png",
          "path": "uploads/fx/第二版.png",
          "size": 21000,
          "width": 400,
          "height": 560,
          "owner": "s-c1",
        },
      })
    Some(String("uploads/fx/第二版.png")) =>
      Some({
        "index": 1,
        "count": 2,
        "before": {
          "name": "界面草图.png",
          "path": "uploads/fx/界面草图.png",
          "size": 18000,
          "width": 600,
          "height": 400,
          "owner": "s-c1",
        },
      })
    // (as big as the one after it, 界面草图.png)
    Some(String("uploads/fx/对照草图.png")) =>
      Some({
        "index": 0,
        "count": 2,
        "after": {
          "name": "界面草图.png",
          "path": "uploads/fx/界面草图.png",
          "size": 18000,
          "width": 600,
          "height": 400,
          "owner": "s-c1",
        },
      })
    _ => Some(Json::object({}))
  }
}
