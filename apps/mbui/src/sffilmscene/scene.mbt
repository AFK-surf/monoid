// The same application fixture for the native film and the Wasm still renderer. `arg` comes from their host.
///|
pub fn source(arg : (String) -> String) -> () -> @sfapp.Source {
  @sf.kept_call.val = Some(@sfkept.answer)
  let mode = arg("MBUI_FIXTURE")
  let dark = arg("MBUI_DARK") == "1"
  let late = whole_ms(arg("MBUI_CORE_MS"))
  let src : Ref[@sfapp.Source?] = Ref(None)
  fn() {
    match src.val {
      Some(s) => s
      None => {
        if arg("MBUI_FILM_AUTOFILL") == "1" { @ui.fake_autofill.val = true }
        // 1Password as a scene has it (none unless said): asked and slow to answer, or allowed but its servers not
        // reached
        let op_mode = if mode == "chat-signin-many" { "many" } else { arg("MBUI_FILM_OP") }
        match op_mode {
          "slow" => {
            @ui.fake_op.val = Some(fn(_) { (0, "[]", "") })
            @ui.fake_op_pending.val = true
          }
          "many" =>
            @ui.fake_op.val = Some(fn(args) {
              if args.contains("list") {
                (
                  0,
                  "[{\"id\":\"gh1\",\"title\":\"GitHub\",\"additional_information\":\"lin@example.com\",\"urls\":[{\"href\":\"https://github.com\"}]},{\"id\":\"gh2\",\"title\":\"GitHub\",\"additional_information\":\"lin.personal@example.com\",\"urls\":[{\"href\":\"https://github.com/login\"}]},{\"id\":\"gh3\",\"title\":\"GitHub\",\"additional_information\":\"team1@example.com\",\"urls\":[{\"href\":\"https://github.com\"}]},{\"id\":\"gh4\",\"title\":\"GitHub\",\"additional_information\":\"team2@example.com\",\"urls\":[{\"href\":\"https://github.com\"}]},{\"id\":\"gh5\",\"title\":\"GitHub OAuth\",\"additional_information\":\"524783491799-i2nuidv1m2jssguh64lopn8g1kd7a8oe.apps.example.com\",\"urls\":[{\"href\":\"https://github.com\"}]}]",
                  "",
                )
              } else if args.contains("--otp") {
                (1, "", "[ERROR] no one-time password")
              } else {
                (
                  0,
                  "[{\"id\":\"username\",\"label\":\"username\",\"value\":\"lin@example.com\"},{\"id\":\"password\",\"purpose\":\"PASSWORD\",\"label\":\"password\",\"value\":\"s3cret\"}]",
                  "",
                )
              }
            })
          "unreached" =>
            @ui.fake_op.val = Some(fn(_) {
              (1, "", "[ERROR] 2026/11/03 16:43:31 Get \"https://my.1password.com/api/v2/account/keysets\": unexpected EOF\n")
            })
          _ => ()
        }
        // (`nodes:` before a mode, as scripts of before say it: the chat's page is made as nodes whatever it says, as
        // MBUI_CHAT_PAGE is let be)
        let base_mode = match mode.strip_prefix("nodes:") {
          Some(rest) => rest.to_owned()
          None => mode
        }
        let s = if base_mode == "json" {
          @sfapp.fixture_json_app(arg("MBUI_FIXTURE_JSON"))
        } else {
          @sfapp.fixture_app(base_mode)
        }
        // MBUI_FIX_PACE, MBUI_FIX_CORE: the made-up station's pace (said in the film's record, scripts/media.sh)
        @sffixture.fix_pace_said(arg("MBUI_FIX_PACE"), arg("MBUI_FIX_CORE"))
        if arg("MBUI_WINDOW") != "" {
          let w = arg("MBUI_WINDOW")
          @sfbase.lone_page.val = @sfbase.window_page(w)
          @sfbase.set_startup_window_owner(@sfbase.window_page_owner_of(w))
        }
        if arg("MBUI_LAST_WORKSPACE") != "" { @sfbase.cached_workspace.val = arg("MBUI_LAST_WORKSPACE") }
        if arg("MBUI_UPDATES_MS") != "" { @sffixture.fixture_updates(ms=whole_ms(arg("MBUI_UPDATES_MS"))) }
        if arg("MBUI_UPDATE") != "" { @sffixture.fixture_update(arg("MBUI_UPDATE")) }
        // MBUI_CORE_CLIENT=1: answered through the core's client as a device's is (each message its text, a value's
        // first told as an answer), MBUI_CORE_MS late
        let s = if arg("MBUI_CORE_CLIENT") == "1" {
          @sffixture.round_trip_again(s, late)
        } else if late > 0.0 {
          @sffixture.round_trip(s, late)
        } else {
          s
        }
        // MBUI_OPEN_WHOLE=1: a card, a panel or a sheet opened the first time waits for what it reads, as the app does
        // (@sf.OpenGate; a fixture's own tests say what shows before the core answers, so not without it)
        let s = if arg("MBUI_OPEN_WHOLE") == "1" { { ..s, gates_opens: fn() { true } } } else { s }
        let held = arg("MBUI_HOLD")
        let s = if held != "" { @sffixture.held_topics(s, held.split(",").map(fn(x) { x.to_owned() }).collect()) } else { s }
        let failed = arg("MBUI_FAILED")
        let s = if failed != "" {
          @sffixture.failed_topics(s, failed.split(",").map(fn(x) { x.to_owned() }).collect(), arg("MBUI_FAILED_WHY"))
        } else { s }
        let s = if arg("MBUI_SAID") == "1" { @sffixture.said_longest_source(s) } else { s }
        // (a film's pictures decoded as a device's are, a picture sent from the composer among them: what its host holds
        // of them at once is theirs, as the bench's real chat's, not a test file's few small ones)
        @ui.host_image_bytes_known([
          ("src/film/scene.mbt", 262144),
          ("src/sfwasmfilm/main.mbt", 262144),
        ])
        // MBUI_FILM_FACE_MS=N: the people's faces the core gives at once (the fixture's ana_face among them), the host
        // decoding each N ms after it is asked; MBUI_FILM_FACE_WAITS=1: a page opening waits for them, as the app does
        // (Source.picture_waits; sfapp's page_pictures_wbtest)
        let s = if arg("MBUI_FILM_FACE_MS") != "" {
          let bytes = @sffixture.fixture_file_png("face.png")
          @ui.fake_decode_bytes_after.val.push((bytes, whole_ms(arg("MBUI_FILM_FACE_MS"))))
          let faces = @sfapp.core_pictures_waited(fn(_, done) { done(Some(bytes)) }, fn(_, done) { done(Some(bytes)) })
          let waits = arg("MBUI_FILM_FACE_WAITS") == "1"
          {
            ..s,
            picture: fn(url, stint) {
              let key = (faces.shown)(url, stint)
              @sfbase.picture_gated(key)
              key
            },
            picture_waits: fn(url) { waits && (faces.waits)(url) },
          }
        } else {
          s
        }
        if dark { @sf.set_dark(Some(true)) }
        @sf.give_faces()
        src.val = Some(s)
        s
      }
    }
  }
}

///|
/// A whole number of ms said in the environment (0 when none is).
fn whole_ms(s : String) -> Double {
  let mut v = 0
  for ch in s {
    let d = ch.to_int() - 48
    if d < 0 || d > 9 { return 0.0 }
    v = v * 10 + d
  }
  v.to_double()
}
