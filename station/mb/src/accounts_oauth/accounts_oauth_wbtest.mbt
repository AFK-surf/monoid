// Native whitebox tests for accounts_oauth: lock contention and stale-lock takeover, renewal outlasting a lend's bound,
// keychain storage, Antigravity CLI and Devin terminals, Kimi and Cursor grants, missing/hanging commands, and model
// catalog refresh. Each runs on an in-memory World (world_wbtest.mbt) with a fake clock; words are their keys here.

///|
let t0 : Double = 1800000000000.0

///|
fn creds(token : String, expires : Double, refresh? : String = "r1") -> String {
  stringify({
    "claudeAiOauth": {
      "accessToken": Json::string(token),
      "expiresAt": Json::number(expires),
      "refreshToken": Json::string(refresh),
    },
  })
}

///|
fn ok_of(j : Json) -> Json {
  match get(get(Some(j), "result"), "ok") {
    Some(v) => v
    None => fail("no ok in \{j.stringify()}") catch { _ => Json::null() }
  }
}

///|
test "a lock another holds is waited for, then refused, saying so" {
  let out = oauth_case({
    "now": Json::number(t0),
    "files": { "/h/.credentials.json": Json::string(creds("t1", t0 + 1000.0)) },
    "dirs": { "/h/.oauth_refresh.lock": Json::number(t0) },
    "routes": { "/token": [{ "body": { "access_token": "t2", "expires_in": 100 } }] },
    "home": "/h",
    "endpoint": "http://x/token",
    "root": "/h",
  })
  assert_eq(get(Some(out), "result"), Some({ "error": "station.claudeAuth.refreshLocked", "kind": "said" }))
  assert_eq(get(Some(out), "requests"), Some(Json::array([])))
}

///|
test "a lock gone stale while it is waited for is taken" {
  let out = oauth_case({
    "now": Json::number(t0),
    "files": { "/h/.credentials.json": Json::string(creds("t1", t0 + 1000.0)) },
    "dirs": { "/h/.oauth_refresh.lock": Json::number(t0 - 50_000.0) },
    "routes": { "/token": [{ "body": { "access_token": "t2", "expires_in": 100 } }] },
    "home": "/h",
    "endpoint": "http://x/token",
    "root": "/h",
  })
  let got = ok_of(out)
  guard got is Array([String("t2"), Number(expires, ..)]) else { fail("not renewed: \{got.stringify()}") }
  // (renewed some ten seconds on, once the lock was a minute old)
  assert_true(expires > t0 + 100_000.0 + 9_000.0)
  assert_eq(get(Some(out), "dirs"), Some(Json::array([])))
}

///|
test "a lend's bound outlasted: the token it has is lent, the renewal goes on behind" {
  let out = oauth_case({
    "now": Json::number(t0),
    "files": { "/h/.credentials.json": Json::string(creds("t1", t0 + 20.0 * 60_000.0)) },
    "routes": { "/token": [{ "body": { "access_token": "t2", "expires_in": 3600 }, "delay": 5000 }] },
    "home": "/h",
    "endpoint": "http://x/token",
    "margin": 1_800_000,
    "bound": 1000,
    "root": "/h",
  })
  assert_eq(ok_of(out), Json::array([Json::string("t1"), Json::number(t0 + 20.0 * 60_000.0)]))
  let file = get(get(Some(out), "files"), ".credentials.json")
  guard file is Some(String(text)) else { fail("no file") }
  assert_eq(get(get(parse_or_none(text), "claudeAiOauth"), "accessToken"), Some(Json::string("t2")))
}

///|
test "the machine's login in the keychain: read there, saved back there by security, its file untouched" {
  let out = oauth_case({
    "now": Json::number(t0),
    "keychain": Json::string(creds("t1", t0 + 1000.0)),
    "files": { "/m/.claude/.credentials.json": Json::string(creds("stale", t0 + 9000000000.0)) },
    "routes": { "/token": [{ "body": { "access_token": "t2", "expires_in": 100 } }] },
    "env": { "HOME": "/m" },
    "home": Json::null(),
    "endpoint": "http://x/token",
    "root": "/m",
  })
  assert_eq(ok_of(out), Json::array([Json::string("t2"), Json::number(t0 + 100_000.0)]))
  guard get(Some(out), "security") is Some(Array([one])) else { fail("security not asked once") }
  guard get(Some(one), "security") is Some(String(input)) else { fail("no input") }
  assert_true(input.has_prefix("add-generic-password -U -a \"station\" -s \"Claude Code-credentials\" -X \""))
  assert_eq(get(get(Some(out), "files"), ".claude/.credentials.json"), Some(Json::string(creds("stale", t0 + 9000000000.0))))
}

///|
test "a keychain that does not read, or reads as no JSON, is never replaced by the file's login" {
  for keychain in [Json::number(1.0), Json::string("{not json")] {
    let out = oauth_case({
      "now": Json::number(t0),
      "keychain": keychain,
      "files": { "/m/.claude/.credentials.json": Json::string(creds("file", t0 + 9000000000.0)) },
      "env": { "HOME": "/m" },
      "home": Json::null(),
      "endpoint": "http://x/token",
      "root": "/m",
    })
    assert_eq(get(Some(out), "result"), Some({ "error": "station.claudeAuth.keychainUnreadable", "kind": "said" }))
  }
}

///|
test "a save that fails is tried three times, then said" {
  let out = oauth_case({
    "now": Json::number(t0),
    "files": { "/h/.credentials.json": Json::string(creds("t1", t0 + 1000.0)) },
    "unwritable": ["/h/.credentials.json"],
    "routes": { "/token": [{ "body": { "access_token": "t2", "expires_in": 100 } }] },
    "home": "/h",
    "endpoint": "http://x/token",
    "root": "/h",
  })
  assert_eq(get(Some(out), "result"), Some({ "error": "station.claudeAuth.saveFailed", "kind": "said" }))
  assert_eq(get(Some(out), "dirs"), Some(Json::array([])))
}

///|
test "the machine's commands not there, or never ending" {
  let out = machine_case({
    "commands": { "claude auth status": { "timeout": true }, "codex login status": { "missing": true } },
    "env": { "HOME": "/m" },
  })
  guard get(Some(out), "readings") is Some(Array([Array([claude, codex])])) else { fail(out.stringify()) }
  assert_eq(get(Some(claude), "text"), Some(Json::string("station.machine.unreadableFor")))
  assert_eq(get(Some(claude), "installed"), Some(Json::boolean(true)))
  assert_eq(get(Some(codex), "text"), Some(Json::string("station.machine.notInstalled")))
  assert_eq(get(Some(codex), "installed"), Some(Json::boolean(false)))
}

///|
test "a reading older than two minutes is read again in the background, the last one given meanwhile" {
  let w = World::new({})
  let io = w.io()
  let runs = Ref(0)
  let deps : MachineDeps = {
    commands: {
      run: async fn(_, _, _, _) {
        runs.val += 1
        Ended(Some(1), "", "")
      },
    },
    claude_credentials: async fn(_) { None },
    codex_home: _ => "/m/.codex",
    usage: None,
  }
  let logins = MachineLogins::new(io, deps, words(), {}, () => "zh")
  ignore(w.drive(async fn() {
    logins.refresh()
    Json::null()
  }))
  assert_eq(runs.val, 2)
  assert_eq(logins.get().length(), 2)
  w.rt.advance(0)
  assert_eq(runs.val, 2)
  w.rt.advance(120_001)
  assert_eq(logins.get().length(), 2)
  w.rt.advance(0)
  assert_eq(runs.val, 4)
}

///|
/// A world's login platform with terminals, its commands' writes kept and their events given back to the test.
priv struct Terminals {
  written : Array[String]
  events : Ref[ChildEvents?]
  killed : Array[Int]
}

///|
fn terminal_platform(w : World, t : Terminals) -> LoginPlatform {
  {
    terminal: async fn(command, args, _, _) { Some(("script", [command] + args)) },
    prepend_path: (env, _) => env,
    runnable: async fn(c, a, _) { (c, a) },
    make_command: async fn(path, script) {
      w.put(path, script)
      path
    },
    with_shell_command: async fn(_, _, _) { None },
    file_credentials: async fn(_) {  },
    spawn: async fn(_, _, _, _, events) {
      t.events.val = Some(events)
      {
        pid: Some(7),
        writable: () => true,
        write: async fn(text) { t.written.push(text) },
        send: text => t.written.push(text),
        kill: () => (),
      }
    },
    descendants: async fn(_) { [8, 9] },
    kill: pid => t.killed.push(pid),
  }
}

///|
fn login_deps(plat : LoginPlatform, ready : (String, Bool) -> Bool) -> LoginDeps {
  {
    platform: plat,
    env: () => { "HOME": "/u", "SSH_CONNECTION": "x" },
    kimi: async fn(_) { raise Failed("none") },
    cursor_handshake: () => { "url": "https://cursor.example/login?h=1" },
    poll_cursor: async fn(_) { None },
    mint_cursor_key: async fn(_, _) { raise Failed("none") },
    write_cursor: async fn(_, _) {  },
    agy_token_ready: ready,
    note_agy_email: async fn(_, _) {  },
    loopback_of: _ => false,
    key_name: () => "still.fail",
  }
}

///|
fn say(t : Terminals, text : String) -> Unit {
  match t.events.val {
    Some(e) => (e.output)(text)
    None => ()
  }
}

///|
test "the Antigravity CLI: its terminal answered, Google chosen, its code typed, done once its file is whole" {
  let w = World::new({})
  let io = w.io()
  let t : Terminals = { written: [], events: Ref(None), killed: [] }
  let logins = LoginManager::new(io, login_deps(terminal_platform(w, t), (text, _) => text == "whole"), words(), "/d")
  let profile : LoginProfile = { id: "ag", runtime: "agy", home: "/p/ag", email: None, enterprise: false }
  let started = w.drive(async fn() { logins.start(profile, "zh").to_json() }, timers=false)
  assert_eq(get(Some(started), "state"), Some(Json::string("starting")))
  say(t, "\u{1b}[c")
  assert_eq(t.written, [agy_terminal_answer])
  say(t, "Select login method\n")
  assert_eq(t.written[1], "\r")
  say(t, "Open https://accounts.google.com/o/oauth2/auth?redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback&state=s1 and enter the authorization code\n")
  assert_eq(logins.get("ag").unwrap().state, "needs_code")
  ignore(w.drive(async fn() { logins.submit_code("ag", " c0de ", "zh").to_json() }, timers=false))
  assert_eq(t.written[2], "c0de\r")
  assert_eq(logins.get("ag").unwrap().state, "verifying")
  w.put("/d/run/agy-login/ag-1/.gemini/antigravity-cli/antigravity-oauth-token", "partial")
  w.rt.advance(500)
  assert_eq(logins.get("ag").unwrap().state, "verifying")
  w.put("/d/run/agy-login/ag-1/.gemini/antigravity-cli/antigravity-oauth-token", "whole")
  w.rt.advance(500)
  assert_eq(logins.get("ag").unwrap().state, "done")
  assert_eq(w.files.get("/p/ag/agy/.gemini/antigravity-cli/antigravity-oauth-token"), Some("whole"))
  // (its process, and those between, stopped: it does not end by itself)
  w.rt.advance(0)
  assert_eq(t.killed, [7, 8, 9])
}

///|
test "a company's Google account: the Cloud way chosen, its licence, how to pay, its project asked of the person" {
  let w = World::new({})
  let io = w.io()
  let t : Terminals = { written: [], events: Ref(None), killed: [] }
  let logins = LoginManager::new(io, login_deps(terminal_platform(w, t), (_, _) => false), words(), "/d")
  let profile : LoginProfile = { id: "ag", runtime: "agy", home: "/p/ag", email: None, enterprise: true }
  ignore(w.drive(async fn() { logins.start(profile, "zh").to_json() }, timers=false))
  say(t, "Select login method\n")
  assert_eq(t.written, ["\u{1b}[B"])
  w.rt.advance(50)
  assert_eq(t.written, ["\u{1b}[B", "\r"])
  say(t, "Continue with Google Cloud\n")
  assert_eq(t.written.length(), 3)
  say(t, "https://accounts.google.com/o/oauth2/auth?x=antigravity.google%2Foauth-callback Authorization code: ")
  ignore(w.drive(async fn() { logins.submit_code("ag", "code", "zh").to_json() }, timers=false))
  say(t, "Could not fetch licenses: Permission denied\nCan't find your subscription?\n")
  assert_eq(t.written[t.written.length() - 1], "\r")
  say(t, "Pay only for the tokens you use\n")
  w.rt.advance(50)
  say(t, "Provide Google Cloud project\n")
  assert_eq(logins.get("ag").unwrap().state, "needs_project")
  ignore(w.drive(async fn() { logins.submit_code("ag", "my-project", "zh").to_json() }, timers=false))
  say(t, "\u{1b}[31m[Auth Error] Failed to save GCP settings: denied\u{1b}[0m\n")
  let job = logins.get("ag").unwrap()
  assert_eq(job.state, "failed")
  assert_eq(job.error, Some("station.login.agyFailed"))
}

///|
test "Devin's sign-in with no terminal to run in is refused, saying so" {
  let w = World::new({})
  let io = w.io()
  let t : Terminals = { written: [], events: Ref(None), killed: [] }
  let plat = { ..terminal_platform(w, t), terminal: async fn(_, _, _, _) { None } }
  let logins = LoginManager::new(io, login_deps(plat, (_, _) => false), words(), "/d")
  let profile : LoginProfile = { id: "dv", runtime: "devin", home: "/p/dv", email: None, enterprise: false }
  let job = w.drive(async fn() { logins.start(profile, "zh").to_json() }, timers=false)
  assert_eq(get(Some(job), "state"), Some(Json::string("failed")))
  assert_eq(get(Some(job), "error"), Some(Json::string("station.login.devinNoTerminal")))
}

///|
test "Devin: its code typed with a carriage return, a sign-in that does not end in time failed" {
  let w = World::new({})
  let io = w.io()
  let t : Terminals = { written: [], events: Ref(None), killed: [] }
  let logins = LoginManager::new(io, login_deps(terminal_platform(w, t), (_, _) => false), words(), "/d")
  let profile : LoginProfile = { id: "dv", runtime: "devin", home: "/p/dv", email: None, enterprise: false }
  ignore(w.drive(async fn() { logins.start(profile, "zh").to_json() }, timers=false))
  say(t, "Open \u{1b}]8;;https://app.devin.ai/auth/cli/x?code_challenge=1\u{07}https://app.devin.ai/auth/cli/x?code_challenge=1\u{1b}]8;;\u{07} and paste it here\n")
  assert_eq(logins.get("dv").unwrap().url, Some("https://app.devin.ai/auth/cli/x?code_challenge=1"))
  ignore(w.drive(async fn() { logins.submit_code("dv", "tok", "zh").to_json() }, timers=false))
  assert_eq(t.written, ["tok\r"])
  w.rt.advance(90_000)
  assert_eq(logins.get("dv").unwrap().error, Some("station.login.verifyTimedOut"))
}

///|
test "Kimi's grant and Cursor's confirmation, followed by the station" {
  let w = World::new({ "wall": Json::number(t0) })
  let io = w.io()
  let t : Terminals = { written: [], events: Ref(None), killed: [] }
  let kept = []
  let polls = Ref(0)
  let deps = {
    ..login_deps(terminal_platform(w, t), (_, _) => false),
    kimi: async fn(home) {
      {
        start: async fn() {
          { device_code: "kd", user_code: "K-1", url: "https://kimi.example/d", expires_in_ms: 60_000.0, interval_ms: 2000.0 }
        },
        ask: async fn(_) {
          polls.val += 1
          if polls.val == 1 {
            raise Failed("offline")
          }
          if polls.val == 2 {
            Pending(true)
          } else {
            Signed({ access: "ka", refresh: "kr", expires_in_ms: 1000.0, org: None })
          }
        },
        keep: async fn(token) { async fn() { kept.push("\{home} \{token.access}") } },
      }
    },
    poll_cursor: async fn(_) {
      polls.val += 1
      if polls.val > 5 {
        Some({ "accessToken": "ca" })
      } else {
        None
      }
    },
    mint_cursor_key: async fn(access, name) { { "apiKey": Json::string("key-\{access}-\{name}"), "email": "c@x" } },
    write_cursor: async fn(home, login) { kept.push("\{home} \{login.stringify()}") },
  }
  let logins = LoginManager::new(io, deps, words(), "/d")
  let job = w.drive(async fn() { logins.start_kimi("km", "/p/km", "zh").to_json() }, timers=false)
  assert_eq(get(Some(job), "provider"), Some(Json::string("kimi")))
  assert_eq(get(Some(job), "expiresAt"), Some(Json::number(60_000.0)))
  w.rt.advance(2000)
  // (the network failed once: asked again at the interval)
  assert_eq(logins.get("km").unwrap().state, "needs_approval")
  w.rt.advance(2000)
  w.rt.advance(6999)
  assert_eq(logins.get("km").unwrap().state, "needs_approval")
  w.rt.advance(1)
  assert_eq(logins.get("km").unwrap().state, "done")
  assert_eq(kept, ["/p/km ka"])
  polls.val = 0
  let job = w.drive(async fn() { logins.start_cursor("cu", "/p/cu", "zh").to_json() }, timers=false)
  assert_eq(get(Some(job), "url"), Some(Json::string("https://cursor.example/login?h=1")))
  // asked at 1 s, then 1.2, 1.44, 1.728, 2.074 and 2.489 s apart (each 1.2 times the last, rounded)
  for ms in [1000, 1200, 1440, 1728, 2074] {
    assert_eq(logins.get("cu").unwrap().state, "needs_approval")
    w.rt.advance(ms)
  }
  w.rt.advance(2489)
  assert_eq(logins.get("cu").unwrap().state, "done")
  assert_eq(kept[1], "/p/cu {\"apiKey\":\"key-ca-still.fail\",\"email\":\"c@x\",\"keyName\":\"still.fail\",\"createdAt\":1800000000000}")
}

///|
test "a sign-in that runs out is failed, saying so" {
  let w = World::new({})
  let io = w.io()
  let t : Terminals = { written: [], events: Ref(None), killed: [] }
  let logins = LoginManager::new(io, login_deps(terminal_platform(w, t), (_, _) => false), words(), "/d")
  ignore(w.drive(async fn() { logins.start_cursor("cu", "/p/cu", "zh").to_json() }, timers=false))
  w.rt.advance(900_000)
  assert_eq(logins.get("cu").unwrap().error, Some("station.login.timedOut"))
}

///|
test "Cursor's and the Antigravity CLI's checks, as their parts say" {
  let check = (runtime : String, deps : Json) => check_case({
    "options": { "runtime": Json::string(runtime), "kind": "subscription", "home": "/p" },
    "deps": deps,
    "files": { "/p/agy/.gemini/antigravity-cli/antigravity-oauth-token": "tok" },
  })
  let r = check("cursor", { "cursor": { "apiKey": "k", "email": "old@x" }, "cursorMe": {}, "cursorModels": ["a", "b"] })
  assert_eq(get(Some(r), "result"), Some({ "state": "ok", "detail": "station.profile.signedInstation.list.commaold@x", "models": ["a", "b"], "checkedAt": 0 }))
  let r = check("cursor", { "cursor": { "apiKey": "k" }, "cursorMe": Json::null() })
  assert_eq(get(get(Some(r), "result"), "detail"), Some(Json::string("station.profile.cursorKeyRevoked")))
  let r = check("cursor", { "cursor": Json::null() })
  assert_eq(get(get(Some(r), "result"), "state"), Some(Json::string("login")))
  let r = check("agy", { "agySignedIn": true, "agyReady": true, "agyEmail": "g@x", "agyPlan": "ultra" })
  assert_eq(get(Some(r), "result"), Some({ "state": "ok", "detail": "station.profile.signedInstation.list.commag@x", "models": Json::null(), "checkedAt": 0, "plan": "ultra" }))
  let r = check("agy", { "agySignedIn": true, "agyReady": false })
  assert_eq(get(get(Some(r), "result"), "state"), Some(Json::string("login")))
  let r = check("agy", { "agySignedIn": false })
  assert_eq(get(get(Some(r), "result"), "state"), Some(Json::string("login")))
}

///|
test "the models part asks at its start and as the cloud says, by the ETag it names" {
  let w = World::new({ "routes": { "/v1/models": [{ "body": { "models": { "m": {} } }, "headers": { "etag": "e1" } }] } })
  let io = w.io()
  let cat = Catalog::new()
  let told : Ref[((Json) -> Unit)?] = Ref(None)
  ignore(w.drive(async fn() {
    ignore(models_live(io, cat, "/d", () => Some("https://cloud.example"), f => told.val = Some(f), _ => ()))
    Json::null()
  }))
  assert_eq(cat.named(), ["m"])
  (told.val.unwrap())({ "type": "models", "etag": "e1" })
  w.rt.advance(0)
  (told.val.unwrap())({ "type": "models", "etag": "e2" })
  w.rt.advance(0)
  assert_eq(w.requests.map(r => get(Some(r), "url").unwrap()), [
    Json::string("https://cloud.example/v1/models"),
    Json::string("https://cloud.example/v1/models?v=e2"),
  ])
  assert_eq(w.files.get("/d/model-catalog.json"), Some("{\"etag\":\"e1\",\"models\":{\"m\":{}}}"))
}
