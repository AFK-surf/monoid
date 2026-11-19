// A member's view of one of the station's screens (`{"screen": …}` on their link: mesh/screens.ts `answerScreen`),
// answered by mesh_runtime's `answer_screen` over this slice's screens: the hub and its sources (screens' types) given
// it as its ports, each conversion as the TypeScript's JSON says it. P5-1 hands the view here (`ui_ask`
// `screens.view`) with the stream as a handle at the shell (`p54_stream_handle`).

///|
fn p54_region(r : @screens.Region) -> @mesh_runtime.Region {
  { x: r.x, y: r.y, w: r.w, h: r.h }
}

///|
fn p54_region_of(r : @mesh_runtime.Region) -> @screens.Region {
  { x: r.x, y: r.y, w: r.w, h: r.h }
}

///|
fn p54_clip(c : @screens.Clip) -> @mesh_runtime.Clip {
  match c {
    ClipText(t) => Text(t)
    ClipPng(d) => Png(d)
  }
}

///|
fn p54_clip_of(c : @mesh_runtime.Clip) -> @screens.Clip {
  match c {
    Text(t) => ClipText(t)
    Png(d) => ClipPng(d)
  }
}

///|
fn p54_frame(f : @screens.Frame) -> @mesh_runtime.ScreenFrame {
  {
    config: f.config.map(c => {
      codec: c.codec.name(),
      width: c.width,
      height: c.height,
      description: c.description,
      region: c.region.map(p54_region),
    }),
    key: f.key,
    ts: f.ts,
    data: f.data,
  }
}

///|
/// A view a source opened, as `answer_screen` reads it.
fn p54_view_port(v : @screens.ScreenView) -> @mesh_runtime.ScreenViewPort {
  {
    next: async fn() { (v.next)().map(p54_frame) },
    next_audio: v.next_audio.map(f => async fn() { f().map(a => ({ ts: a.ts, data: a.data, codec: a.codec } : @mesh_runtime.AudioPacket)) }),
    keyframe: v.keyframe,
    input: async fn(j) {
      match @screens.input_of(p54_jv(j)) {
        Some(i) => (v.input)(i)
        None => ()
      }
    },
    rate: v.rate,
    bounds: v.bounds.map(b => (w, h, r) => b(w, h, r.map(p54_region_of))),
    regions: v.regions,
    video: v.video.map(f => () => Some(p54_of_jv(f().to_j()))),
    why: v.why,
    close: v.close,
    set_clipboard: v.set_clipboard.map(f => async fn(c, b) { f(p54_clip_of(c), b) }),
    watch_clipboard: v.watch_clipboard.map(w => (k : (@mesh_runtime.Clip) -> Unit) => w(c => k(p54_clip(c)))),
    watch_cursor: v.watch_cursor.map(w => (k : (Json) -> Unit) => w(c => k(p54_of_jv(c.to_j())))),
    cursor_image: v.cursor_image,
    watch_turn: v.watch_turn.map(w => (k : (Json) -> Unit) => w(n => k(Json::number(n.to_double())))),
    watch_windows: v.watch_windows.map(w => (k : (Json) -> Unit) => w(x => k(p54_of_jv(x.to_j())))),
    window: v.window,
    reveal: v.reveal,
    watch_login: v.watch_login.map(w => (k : (Json) -> Unit) => w(f => k(match f {
      Some(l) => {
        let m : Map[String, Json] = { "host": Json::string(l.host), "field": Json::string(l.field) }
        if l.filled {
          m["filled"] = Json::boolean(true)
        }
        Json::object(m)
      }
      None => Json::null()
    }))),
    fill: v.fill.map(f => async fn(j) {
      f({
        host: p54_text(Some(j), "host").unwrap_or(""),
        username: p54_text(Some(j), "username"),
        password: p54_text(Some(j), "password"),
      })
    }),
    watch_passkey: v.watch_passkey.map(w => (k : (Json) -> Unit) => w(a => k(match a {
      Some(p) =>
        {
          "id": Json::string(p.id),
          "host": Json::string(p.host),
          "rpId": Json::string(p.rp_id),
          "clientData": Json::string(p.client_data),
          "allow": Json::array(p.allow.map(Json::string)),
          "userVerification": Json::string(p.user_verification),
        }
      None => Json::null()
    }))),
    passkey: v.passkey.map(f => async fn(j) { f({ id: p54_text(Some(j), "id").unwrap_or(""), fields: p54_jv(j) }) }),
    watch_child: v.watch_child,
    set_clipboard_marked: v.set_clipboard_marked.map(f => async fn(c, b, m) { f(p54_clip_of(c), b, m) }),
    watch_clipboard_marked: v.watch_clipboard_marked.map(w => (k : (@mesh_runtime.Clip, Int) -> Unit) => w((c, m) => k(p54_clip(c), m))),
    watch_pointer_lock: v.watch_pointer_lock,
  }
}

///|
/// A source as `answer_screen` reads it; its refusal as mesh_runtime's.
fn p54_source_port(src : @screens.ScreenSource) -> @mesh_runtime.ScreenSourcePort {
  {
    kind: src.kind.name(),
    title: src.title,
    open: async fn(options) {
      let view = (src.open)(@screens.view_options_of(p54_jv(options))) catch {
        @screens.ScreenRefused(status~, key~, args~, access~, ..) =>
          raise @mesh_runtime.ScreenRefused(status, key, p54_of_jv(args), access.map(a => p54_of_jv(a.to_j())))
        e => raise e
      }
      p54_view_port(view)
    },
    access: src.access.map(f => () => Some(p54_of_jv(f().to_j()))),
    clipboard: src.clipboard,
    reveal: src.reveal,
    peek: src.peek,
    open_url: src.open_url is Some(_),
    user_tab: src.user_tab,
    sleeping: src.sleeping,
    site: src.site,
    address: src.address.map(f => () => Some(f())),
    scale: src.scale.map(f => async fn() { f().map(s => p54_of_jv(s.to_j())) }),
    set_scale: src.set_scale.map(f => async fn(n) { p54_of_jv(f(n).to_j()) }),
    resolution: src.resolution.map(f => async fn() { f().map(r => p54_of_jv(r.to_j())) }),
    set_resolution: src.set_resolution.map(f => async fn(w, h) { p54_of_jv(f(w, h).to_j()) }),
  }
}

///|
/// The station's screens as `answer_screen` reads them: each source's port the same one while the source lasts.
fn p54_hub_port(s : P54Screens) -> @mesh_runtime.ScreenHubPort {
  let ports : Map[String, (@screens.ScreenSource, @mesh_runtime.ScreenSourcePort)] = {}
  {
    get: id => match s.hub.get(id) {
      None => {
        ports.remove(id)
        None
      }
      Some(src) =>
        match ports.get(id) {
          Some((kept, port)) if physical_equal(kept, src) => Some(port)
          _ => {
            let port = p54_source_port(src)
            ports[id] = (src, port)
            Some(port)
          }
        }
    },
    drive: (id, device, taken, by) => s.hub.drive(id, device, taken, by),
    join: (id, w) =>
      s.hub.join(
        id,
        @screens.Watcher::new(
          w.name,
          w.control,
          j => (w.tell)(p54_of_jv(j)),
          device=Some(w.device),
          self_=w.self_,
          client=w.client,
          app=w.app,
          end=Some(w.end),
          watch_only=Some(w.watch_only),
        ),
      ),
    watch: f => s.hub.watch(_ => f()),
    when_stopping: f => s.hub.when_stopping(f),
  }
}

///|
/// A member's view of a screen (`screens.view`: `{head, viewer, stream}`, the stream a handle at the shell) answered
/// while it lasts.
async fn p54_screen_view(s : P54Screens, asked : Json) -> Unit {
  let bus = s.bus
  let host = bus.host
  let handle = p54_get(Some(asked), "stream").unwrap_or(Json::null())
  let stream_handle = p54_stream_handle(handle)
  let carry = p54_bytes_of(p54_get(Some(handle), "carry"))
  let stream : @door.Stream = {
    read: async fn() {
      let (said, bytes) = p54_stream_call(host, stream_handle, "read") catch { _ => return None }
      match (p54_get(Some(said), "end"), bytes) {
        (Some(True), _) => None
        (_, Some(b)) => Some(b)
        _ => None
      }
    },
    write: async fn(b) { ignore(p54_stream_call(host, stream_handle, "write", bytes=b)) },
    finish: async fn() {
      ignore(p54_stream_call(host, stream_handle, "finish")) catch {
        _ => ()
      }
    },
    stopped: async fn() {
      match (try { Ok(p54_stream_call(host, stream_handle, "stopped")) } catch { e => Err(e) }) {
        Ok(({ "code": Number(c, ..), .. }, _)) => Some(c.to_int())
        _ => None
      }
    },
    reset: async fn(code) {
      ignore(p54_stream_call(host, stream_handle, "reset", code=Json::number(code.to_double()))) catch {
        _ => ()
      }
    },
  }
  let words = (lang : String, key : String, args : Json) => {
    let given = match args {
      Object(m) =>
        m
        .to_array()
        .map(kv => (
          kv.0,
          match kv.1 {
            String(t) => t
            v => v.stringify()
          },
        ))
      _ => []
    }
    tr(lang, key, args=given)
  }
  @mesh_runtime.answer_screen(
    p54_hub_port(s),
    stream,
    carry,
    p54_get(Some(asked), "head").unwrap_or(Json::null()),
    p54_get(Some(asked), "viewer").unwrap_or(Json::null()),
    () => !bus.stopped.is_done(),
    host.rt,
    words,
    (level, part, said, with_) => slice_log(level, part, said, with_),
    host_now=Some(() => wall_ms().to_double()),
    media_datagrams=Some(async fn(token) {
      let (said, _) = p54_stream_call(host, stream_handle, "mediaDatagrams", token=Json::number(token))
      said is True
    }),
  )
}
