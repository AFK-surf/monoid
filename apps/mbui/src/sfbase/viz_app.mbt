// A station's app (station-apps): a `.mbui` widget or a `.wasm` mini-program kept on the station by its id, with its own
// documents and an LLM the station asks with its chat's profile. A widget is bound to one by its `.mbui`'s top-level
// `"app": "<id>"` or by the link it is shown by (`sf-app:<id>`, `sf-app:<id>@<rev>`); bound, what it asks of its app goes
// to the station that holds its chat (the core's `app.docs`, `app.putDoc`, `app.deleteDoc`, `app.llm`, by the session
// key it keeps its state by), and what changes there is told by `app.watch` (never read again on a timer).
//
// A program asks through its imports (`db_list`, `db_put`, `db_delete`, `llm`: viz_wasm_vm.mbt), each the id of its
// request; what it asked is sent once the call that asked has returned, and each answer is given to its `mbui_event`
// one after another, never inside another (`viz_app_deliver`): `{"type":"app","req":N,"ok":true,"op":"docs","docs":[…]}`,
// `{"type":"app","req":N,"ok":true,"op":"llm","text":"…"}`, `{"type":"app","req":N,"ok":false,"error":"…"}`; a document
// changed by anyone `{"type":"app-doc","collection":"…","id":"…","deleted":false}`.

///|
/// Where a widget's app is asked: the station that holds its chat, the session key it keeps its state by, the core's
/// call, and its watch (a streamed call: each value it says, and how it is stopped).
pub(all) struct VizAppHost {
  station : String
  key : String
  call : (String, Json, (Result[Json, Json]) -> Unit) -> Unit
  watch : (String, Json, (Json) -> Unit) -> () -> Unit
}

///|
/// The app host of a widget in chat `key` on `station`, asked through `src`: none while 实验性功能's 站点应用 is off
/// (the core's `apps`), so a widget's `"app"` is bound to nothing and its `llm` buttons ask nothing, as before apps.
pub fn viz_app_host(src : Source, station : String, key : String) -> VizAppHost? {
  if station == "" || key == "" || !feature_on(src, "apps") {
    return None
  }
  Some({
    station,
    key,
    call: src.call,
    watch: fn(name, params, on_value) {
      let id = (src.stream)(name, params, None, fn(v, _) { on_value(v) }, fn(_) { () })
      fn() { (src.cancel)(id) }
    },
  })
}

///|
/// Whether `id` is an app's id: `^[a-z0-9][a-z0-9-]{0,39}$`.
pub fn viz_app_id_ok(id : String) -> Bool {
  let n = id.length()
  if n < 1 || n > 40 {
    return false
  }
  for i in 0..<n {
    let c = id.code_unit_at(i).to_int()
    let lower = c >= 97 && c <= 122
    let digit = c >= 48 && c <= 57
    if !(lower || digit || (i > 0 && c == 45)) {
      return false
    }
  }
  true
}

///|
/// The app a link names: `sf-app:<id>` (its current version, followed) or `sf-app:<id>@<rev>` (that version alone), as
/// `(id, rev)`; None where it names none.
pub fn viz_app_link(href : String) -> (String, Int?)? {
  let h = href.trim(chars=" ").to_owned()
  if !h.has_prefix("sf-app:") {
    return None
  }
  let rest = h.exact_view(start=7).to_owned()
  let (id, rev) = match rest.find("@") {
    Some(i) => {
      let r = rest.exact_view(start=i + 1).to_owned()
      if r == "" || r.length() > 9 || !r.iter().all(fn(c) { c >= '0' && c <= '9' }) {
        return None
      }
      let mut n = 0
      for c in r {
        n = n * 10 + (c.to_int() - 48)
      }
      if n < 1 {
        return None
      }
      (rest.exact_view(end=i).to_owned(), Some(n))
    }
    None => (rest, None)
  }
  if viz_app_id_ok(id) {
    Some((id, rev))
  } else {
    None
  }
}

///|
/// What the widget drawn as `place` holds now (its state, as it would keep it), None where none is drawn there: for
/// its tests, which read what a program set that it never kept.
pub fn viz_mbui_state_at(place : String) -> Json? {
  for s in viz_mbui_stores {
    if s.key == place {
      return Some(viz_state_snapshot(s))
    }
  }
  None
}

///|
/// Whether `store`'s widget is bound to an app it can ask.
fn viz_app_bound(store : VizMbuiStore) -> Bool {
  store.app != "" && viz_app_host_of(store) is Some(_)
}

///|
fn viz_app_host_of(store : VizMbuiStore) -> VizAppHost? {
  match store.hears {
    Some(h) => h.app
    None => None
  }
}

///|
/// A failure's words, as the station said them (what to do next is in them).
fn viz_app_error(e : Json) -> String {
  match e {
    String(s) => s
    Object(m) =>
      match m.get("err") {
        Some(inner) => viz_app_error(inner)
        None =>
          match m.get("message") {
            Some(String(s)) => s
            _ =>
              match m.get("error") {
                Some(String(s)) => s
                _ => error_words(e)
              }
          }
      }
    _ => error_words(e)
  }
}

///|
/// What a program asked during its last call (viz_wasm_vm's `app_asks`), sent to its app: each answer given to it in
/// turn (viz_app_deliver).
fn viz_app_flush(store : VizMbuiStore, inst : VizWasmInstance) -> Unit {
  if inst.host.app_asks.is_empty() {
    return
  }
  let asks = inst.host.app_asks.copy()
  inst.host.app_asks.clear()
  for ask in asks {
    viz_app_send(store, inst, ask)
  }
}

///|
fn viz_app_answer_head(ask : VizAppAsk, ok : Bool) -> Map[String, Json] {
  {
    "type": Json::string("app"),
    "req": Json::number(ask.req.to_double()),
    "ok": Json::boolean(ok),
    "op": Json::string(ask.op),
  }
}

///|
/// One request of a program sent to its app; its answer given to it as it comes.
fn viz_app_send(store : VizMbuiStore, inst : VizWasmInstance, ask : VizAppAsk) -> Unit {
  let failed = fn(words : String) {
    inst.host.app_in_flight = (inst.host.app_in_flight - 1).max(0)
    let m = viz_app_answer_head(ask, false)
    m["error"] = Json::string(words)
    viz_app_deliver(store, Json::object(m))
  }
  let host = match viz_app_host_of(store) {
    Some(h) if store.app != "" => h
    _ => {
      failed("this widget is not bound to an app")
      return
    }
  }
  if ask.fail != "" {
    failed(ask.fail)
    return
  }
  let p : Map[String, Json] = { "station": Json::string(host.station), "id": Json::string(store.app) }
  let name = match ask.op {
    "docs" => {
      p["collection"] = Json::string(ask.collection)
      "app.docs"
    }
    "put" => {
      p["collection"] = Json::string(ask.collection)
      p["doc"] = Json::string(ask.doc)
      p["data"] = ask.data
      "app.putDoc"
    }
    "delete" => {
      p["collection"] = Json::string(ask.collection)
      p["doc"] = Json::string(ask.doc)
      "app.deleteDoc"
    }
    _ => {
      p["key"] = Json::string(host.key)
      match ask.data {
        Object(m) => {
          for k in ["prompt", "system"] {
            match m.get(k) {
              Some(String(s)) => p[k] = Json::string(s)
              _ => ()
            }
          }
          match m.get("max_tokens") {
            Some(Number(n, ..)) => p["max_tokens"] = Json::number(n.floor())
            _ => ()
          }
        }
        _ => ()
      }
      "app.llm"
    }
  }
  (host.call)(name, Json::object(p), fn(r) {
    match r {
      Err(e) => failed(viz_app_error(e))
      Ok(v) => {
        inst.host.app_in_flight = (inst.host.app_in_flight - 1).max(0)
        let m = viz_app_answer_head(ask, true)
        match ask.op {
          "docs" => {
            m["collection"] = Json::string(ask.collection)
            m["docs"] = match field(Some(v), "docs") {
              Some(Array(_) as a) => a
              _ => Json::array([])
            }
          }
          "put" => {
            m["collection"] = Json::string(ask.collection)
            m["id"] = Json::string(ask.doc)
            m["rev"] = field(Some(v), "rev").unwrap_or(Json::null())
          }
          "delete" => {
            m["collection"] = Json::string(ask.collection)
            m["id"] = Json::string(ask.doc)
          }
          _ =>
            m["text"] = match field(Some(v), "text") {
              Some(String(_) as t) => t
              _ => Json::string("")
            }
        }
        viz_app_deliver(store, Json::object(m))
      }
    }
  })
}

///|
/// The most answers and changes given to a program one after another before the host stops (a program that asks again
/// at each answer of a core that answers at once would not stop by itself).
let viz_app_max_burst : Int = 256

///|
/// `ev` given to `store`'s program (its `mbui_event`), after those before it: never while one is given (an answer that
/// comes at once, as it is asked, waits for the one being given), so the program is never called inside itself. What its
/// state comes to is kept, as a press's is.
fn viz_app_deliver(store : VizMbuiStore, ev : Json) -> Unit {
  if store.wasm is None {
    return
  }
  store.app_inbox.push(ev)
  if store.app_delivering {
    return
  }
  store.app_delivering = true
  let mut given = 0
  while !store.app_inbox.is_empty() && given < viz_app_max_burst {
    let next = store.app_inbox.remove(0)
    given = given + 1
    let hears = store.hears.unwrap_or(viz_hears_none)
    viz_notify_wasm_event(store, hears, next)
    let snap = viz_state_snapshot(store)
    if snap != store.synced_raw {
      store.synced_raw = snap
      match hears.keep {
        Some(keep) => keep(snap)
        None => ()
      }
    }
  }
  if !store.app_inbox.is_empty() {
    store.app_inbox.clear()
    store.wasm_error.set("too many app answers in a row (\{viz_app_max_burst}): ask again from a press")
  }
  store.app_delivering = false
}

///|
// kept across runs: a value (no field of it changes)
let viz_hears_none : VizHears = { keep: None, failed: None, follow_up: None, app: None }

///|
/// What `app.watch` said for `store`'s app, taken: a document changed given to its program; the link to the station
/// open again after an absence (not the first time, as the watch starts) given as a change of anything (`collection` and
/// `id` empty: read again what is shown); the app saved or rolled back given to `on_app` (its link's, which loads it
/// again where it follows the current version).
fn viz_app_watched(store : VizMbuiStore, v : Json, opened_before : Ref[Bool], on_app : (Json) -> Unit) -> Unit {
  match v {
    Object(m) =>
      match m.get("type") {
        Some(String("app-doc")) => {
          let ev : Map[String, Json] = {
            "type": Json::string("app-doc"),
            "collection": m.get("collection").unwrap_or(Json::string("")),
            "id": m.get("id").unwrap_or(Json::string("")),
            "deleted": Json::boolean(m.get("deleted") is Some(True)),
          }
          viz_app_deliver(store, Json::object(ev))
        }
        Some(String("opened")) => {
          if opened_before.val {
            on_app(v)
            viz_app_deliver(
              store,
              Json::object({
                "type": Json::string("app-doc"),
                "collection": Json::string(""),
                "id": Json::string(""),
                "deleted": Json::boolean(false),
              }),
            )
          }
          opened_before.val = true
        }
        Some(String("app")) => on_app(v)
        _ => ()
      }
    _ => ()
  }
}

///|
/// `store`'s app watched while node `v` is (its watch stopped as the node goes): see viz_app_watched.
fn viz_app_watch_node(v : @view.View, store : VizMbuiStore, on_app : (Json) -> Unit) -> Unit {
  let host = match viz_app_host_of(store) {
    Some(h) if store.app != "" => h
    _ => return
  }
  let opened_before = Ref(false)
  let stop : Ref[(() -> Unit)?] = Ref(None)
  // (asked in a handler, as it is made: what it says may come at once)
  v.reacts(fn() { () }, fn(_) {
    if stop.val is None {
      stop.val = Some(
        (host.watch)(
          "app.watch",
          Json::object({ "station": Json::string(host.station), "id": Json::string(store.app) }),
          fn(value) { viz_app_watched(store, value, opened_before, on_app) },
        ),
      )
    }
  })
  v.owns(fn() {
    match stop.val {
      Some(f) => {
        stop.val = None
        f()
      }
      None => ()
    }
  })
  |> ignore
}

///|
/// The state keys a widget's llm buttons fill (viz_app_llm_press: `into`, `into_pending`, `into_error`), each with what
/// it holds before it is asked.
fn viz_app_llm_keys(root : Json) -> Map[String, Json] {
  let out : Map[String, Json] = Map([])
  fn walk(n : Json, depth : Int) -> Unit {
    if depth > 64 {
      return
    }
    match n {
      Object(m) => {
        match m.get("llm") {
          Some(Object(l)) =>
            match l.get("into") {
              Some(String(k)) if k != "" => {
                out[k] = Json::string("")
                out[k + "_pending"] = Json::boolean(false)
                out[k + "_error"] = Json::string("")
              }
              _ => ()
            }
          _ => ()
        }
        for _, v in m {
          walk(v, depth + 1)
        }
      }
      Array(a) =>
        for v in a {
          walk(v, depth + 1)
        }
      _ => ()
    }
  }
  walk(root, 0)
  out
}

///|
/// A declarative button's `"llm": {"prompt": "…{key}…", "into": "state_key", "system"?, "max_tokens"?}`: the prompt,
/// its `{key}`s filled from the state, asked of the widget's app; its answer's text put in `state[into]`. While it is
/// asked `state[into + "_pending"]` is true; a failure's words (the station's, saying what to do) go in
/// `state[into + "_error"]`, cleared by the next answer.
fn viz_app_llm_press(store : VizMbuiStore, hears : VizHears, llm : Map[String, Json]) -> Unit {
  let into = viz_json_str(llm, "into", "")
  if into == "" {
    return
  }
  let prompt = viz_interp(store, viz_json_str(llm, "prompt", "")).trim().to_owned()
  let err_key = into + "_error"
  let pending_key = into + "_pending"
  let host = match hears.app {
    Some(h) if store.app != "" => h
    Some(_) => {
      viz_state_set(store, hears, err_key, Json::string("this widget is not bound to an app: give its .mbui \"app\": \"<id>\" and save it as an app"))
      return
    }
    // (shown where no app is asked: in no chat, or with 站点应用 off: the button does nothing, as before apps)
    None => return
  }
  if prompt == "" {
    return
  }
  let p : Map[String, Json] = {
    "station": Json::string(host.station),
    "id": Json::string(store.app),
    "key": Json::string(host.key),
    "prompt": Json::string(prompt),
  }
  let system = viz_interp(store, viz_json_str(llm, "system", ""))
  if system != "" {
    p["system"] = Json::string(system)
  }
  match llm.get("max_tokens") {
    Some(Number(n, ..)) => p["max_tokens"] = Json::number(n.floor())
    _ => ()
  }
  viz_state_sig(store, pending_key, Json::boolean(true)).set(Json::boolean(true))
  (host.call)("app.llm", Json::object(p), fn(r) {
    viz_state_sig(store, pending_key, Json::boolean(false)).set(Json::boolean(false))
    match r {
      Ok(v) => {
        let text = match field(Some(v), "text") {
          Some(String(t)) => t
          _ => ""
        }
        viz_state_sig(store, err_key, Json::string("")).set(Json::string(""))
        viz_state_set(store, hears, into, Json::string(text))
      }
      Err(e) => viz_state_set(store, hears, err_key, Json::string(viz_app_error(e)))
    }
  })
}

///|
/// An app's version as the station gave it (`app.get`): what it is (`mbui` or `wasm`), which version (`rev`), its
/// source as viz_mbui_parse reads it (a `.wasm`'s bytes as `wasm:base64:`), and the name it is parsed by.
#derive(Eq)
pub(all) struct VizAppGot {
  kind : String
  rev : Int
  name : String
  raw : String
}

///|
/// An app's version asked of its station: what has come (None while it comes; Err the station's words where it could
/// not be read), whether it was asked.
pub(all) struct VizAppLoad {
  got : @signals.Signal[Result[VizAppGot, String]?]
  mut asked : Bool
}

///|
/// The app versions asked, by station, id and version ("" for the current one).
pub let viz_app_loads : Map[String, VizAppLoad] = Map([])

///|
fn viz_app_load_id(station : String, id : String, rev : Int?) -> String {
  station + "/" + id + "@" + (match rev { Some(n) => n.to_string(); None => "" })
}

///|
/// What `app.get` answered, read.
pub fn viz_app_got_of(id : String, v : Json) -> Result[VizAppGot, String] {
  let kind = match field(Some(v), "kind") {
    Some(String(k)) => k
    _ => "mbui"
  }
  let rev = match field(Some(v), "rev") {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
  match field(Some(v), "source") {
    Some(String(src)) =>
      if kind == "wasm" {
        Ok({ kind, rev, name: id + ".wasm", raw: "wasm:base64:" + src })
      } else {
        Ok({ kind, rev, name: id + ".mbui", raw: src })
      }
    _ => Err("the station gave app \{id} without its source: save it again (app_save)")
  }
}

///|
/// App `id` (its version `rev`, or the current one) asked of `station` (again where `again`: it changed there), into its
/// load. What came before stays shown till the new one comes.
fn viz_app_ask(src : Source, l : VizAppLoad, station : String, id : String, rev : Int?) -> Unit {
  let p : Map[String, Json] = { "station": Json::string(station), "id": Json::string(id) }
  match rev {
    Some(n) => p["rev"] = Json::number(n.to_double())
    None => ()
  }
  (src.call)("app.get", Json::object(p), fn(r) {
    match r {
      Ok(v) => l.got.set(Some(viz_app_got_of(id, v)))
      Err(e) =>
        match l.got.untracked() {
          // (a version shown already stays shown: what failed is only the newer one)
          Some(Ok(_)) => ()
          _ => l.got.set(Some(Err(viz_app_error(e))))
        }
    }
  })
}

///|
/// App `id` on `station` (version `rev`, or the current one) for node `v`: asked as it is made (where not asked yet), read
/// as it comes.
pub fn viz_app_load_node(
  v : @view.View,
  src : Source,
  station : String,
  id : String,
  rev : Int?,
) -> () -> Result[VizAppGot, String]? {
  let lid = viz_app_load_id(station, id, rev)
  let l = match viz_app_loads.get(lid) {
    Some(l) => l
    None => {
      let l : VizAppLoad = { got: @signals.signal(None), asked: false }
      viz_app_loads[lid] = l
      l
    }
  }
  // (asked in a handler, as it is made: its answer may come at once)
  v.reacts(fn() { () }, fn(_) {
    if !l.asked {
      l.asked = true
      viz_app_ask(src, l, station, id, rev)
    }
  })
  fn() { l.got.get() }
}

///|
/// What `app.watch` said of the app itself (`{"type":"app","id","rev","current"}`) for the current version of `id` on
/// `station` shown at `shown`: asked again where the version current there is another (a widget pinned to a version
/// never is).
pub fn viz_app_changed(src : Source, station : String, id : String, shown : Int, said : Json) -> Unit {
  // (the link to the station open again after an absence: what changed meanwhile was not told, so asked again)
  let reopened = field(Some(said), "type") == Some(Json::string("opened"))
  let current = match field(Some(said), "current") {
    _ if reopened => -1
    Some(Number(n, ..)) => n.to_int()
    _ =>
      match field(Some(said), "rev") {
        Some(Number(n, ..)) => n.to_int()
        _ => return
      }
  }
  if current == shown {
    return
  }
  match viz_app_loads.get(viz_app_load_id(station, id, None)) {
    Some(l) => viz_app_ask(src, l, station, id, None)
    None => ()
  }
}

///|
/// What the app loads keep, let go (viz_pages_reset's).
pub fn viz_app_loads_clear() -> Unit {
  viz_app_loads.clear()
}
