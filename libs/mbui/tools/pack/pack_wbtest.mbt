///|
let sample_manifest : String =
  #|{
  #|  "appId": "dev.example.demo",
  #|  "name": "Demo Client",
  #|  "version": "1.2.3",
  #|  "build": 42,
  #|  "entry": "src/demo",
  #|  "icon": "assets/icon.png",
  #|  "urlSchemes": ["demo", "demo-link"],
  #|  "env": {
  #|    "API_URL": "https://api.example.com",
  #|    "LOG_LEVEL": "info"
  #|  },
  #|  "resources": ["assets/extra.txt"],
  #|  "macos": {
  #|    "minVersion": "14.0",
  #|    "category": "public.app-category.productivity",
  #|    "formats": ["app", "zip"],
  #|    "infoPlist": {
  #|      "NSCameraUsageDescription": "Camera for video",
  #|      "CustomFlag": true,
  #|      "CustomNum": 7
  #|    }
  #|  },
  #|  "web": {
  #|    "title": "Demo Web",
  #|    "themeColorLight": "#FFFFFF",
  #|    "themeColorDark": "#111111",
  #|    "brotli": true,
  #|    "pwa": true,
  #|    "head": "<meta name=\"author\" content=\"Demo\">"
  #|  },
  #|  "variants": {
  #|    "beta": {
  #|      "appId": "dev.example.demo.beta",
  #|      "name": "Demo Client Beta",
  #|      "env": {
  #|        "LOG_LEVEL": "debug",
  #|        "BETA": "1"
  #|      },
  #|      "macos": {
  #|        "formats": ["app", "dmg"]
  #|      },
  #|      "web": {
  #|        "title": "Demo Beta"
  #|      }
  #|    }
  #|  }
  #|}

///|
test "manifest parses defaults and derives safe executable" {
  let minimal = "{\"appId\": \"dev.example.hello\", \"name\": \"Hello World!\"}"
  let m = match parse_manifest(minimal, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  assert_eq(m.app_id, "dev.example.hello")
  assert_eq(m.name, "Hello World!")
  assert_eq(m.executable, "Hello-World")
  assert_eq(m.version, "0.1.0")
  assert_eq(m.build, 1)
  assert_eq(m.entry, "src/app")
  assert_eq(m.entry_pkg(), "app")
  assert_eq(m.runtime, "native")
  assert_eq(m.macos.min_version, "13.0")
  assert_eq(m.web.title, "Hello World!")
}

///|
test "manifest rejects invalid inputs" {
  assert_true(parse_manifest("not json", CliOverrides::empty()) is Err(_))
  assert_true(parse_manifest("[]", CliOverrides::empty()) is Err(_))
  // missing appId
  assert_true(parse_manifest("{\"name\": \"X\"}", CliOverrides::empty()) is Err(_))
  // invalid appId (not reverse-DNS)
  assert_true(parse_manifest("{\"appId\": \"single\", \"name\": \"X\"}", CliOverrides::empty()) is Err(_))
  assert_true(parse_manifest("{\"appId\": \"dev.1bad.app\", \"name\": \"X\"}", CliOverrides::empty()) is Err(_))
  assert_true(parse_manifest("{\"appId\": \"dev..app\", \"name\": \"X\"}", CliOverrides::empty()) is Err(_))
  // missing name
  assert_true(parse_manifest("{\"appId\": \"dev.example.a\"}", CliOverrides::empty()) is Err(_))
  // bad runtime
  assert_true(
    parse_manifest(
      "{\"appId\": \"dev.example.a\", \"name\": \"A\", \"runtime\": \"jvm\"}",
      CliOverrides::empty(),
    )
    is Err(_),
  )
  // bad build
  assert_true(
    parse_manifest(
      "{\"appId\": \"dev.example.a\", \"name\": \"A\", \"build\": 0}",
      CliOverrides::empty(),
    )
    is Err(_),
  )
  // unknown variant
  assert_true(
    parse_manifest(
      sample_manifest,
      { variant: Some("nonexistent"), version: None, build: None, app_id: None, runtime: None, env: [] },
    )
    is Err(_),
  )
}

///|
test "variant deep-merge preserves base env and platform fields, CLI overrides win" {
  let overrides : CliOverrides = {
    variant: Some("beta"),
    version: Some("2.0.0-rc1"),
    build: Some(99),
    app_id: Some("dev.override.id"),
    runtime: Some("wasm"),
    env: [],
  }
  let m = match parse_manifest(sample_manifest, overrides) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  // CLI overrides beat variant and base
  assert_eq(m.app_id, "dev.override.id")
  assert_eq(m.version, "2.0.0-rc1")
  assert_eq(m.build, 99)
  assert_eq(m.runtime, "wasm")
  // Variant overrides top-level name
  assert_eq(m.name, "Demo Client Beta")
  // env is merged (API_URL kept from base, LOG_LEVEL overridden, BETA added)
  assert_eq(m.env.get("API_URL"), Some("https://api.example.com"))
  assert_eq(m.env.get("LOG_LEVEL"), Some("debug"))
  assert_eq(m.env.get("BETA"), Some("1"))
  // macos section deep-merged (minVersion & category preserved, formats replaced)
  assert_eq(m.macos.min_version, "14.0")
  assert_eq(m.macos.category, "public.app-category.productivity")
  assert_eq(m.macos.formats, ["app", "dmg"])
  // web section deep-merged (title overridden, pwa/themeColor preserved)
  assert_eq(m.web.title, "Demo Beta")
  assert_eq(m.web.pwa, true)
  assert_eq(m.web.theme_color_dark, "#111111")
}

///|
test "render_info_plist includes standard keys, URL schemes, env, icon and custom infoPlist" {
  let m = match parse_manifest(sample_manifest, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  let xml = render_info_plist(m, true)
  assert_true(xml.contains("<key>CFBundleIdentifier</key>\n\t<string>dev.example.demo</string>"))
  assert_true(xml.contains("<key>CFBundleName</key>\n\t<string>Demo Client</string>"))
  assert_true(xml.contains("<key>CFBundleDisplayName</key>\n\t<string>Demo Client</string>"))
  assert_true(xml.contains("<key>CFBundleExecutable</key>\n\t<string>Demo-Client</string>"))
  assert_true(xml.contains("<key>CFBundleShortVersionString</key>\n\t<string>1.2.3</string>"))
  assert_true(xml.contains("<key>CFBundleVersion</key>\n\t<string>42</string>"))
  assert_true(xml.contains("<key>LSMinimumSystemVersion</key>\n\t<string>14.0</string>"))
  assert_true(xml.contains("<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>"))
  assert_true(xml.contains("<key>CFBundleURLTypes</key>"))
  assert_true(xml.contains("<string>demo-link</string>"))
  assert_true(xml.contains("<key>LSEnvironment</key>"))
  assert_true(xml.contains("<key>API_URL</key>"))
  assert_true(xml.contains("<key>NSCameraUsageDescription</key>"))
  assert_true(xml.contains("<key>CustomFlag</key>\n\t<true/>"))
  assert_true(xml.contains("<key>CustomNum</key>\n\t<integer>7</integer>"))
}

///|
test "render_web_html and render_web_manifest reflect manifest settings" {
  let m = match parse_manifest(sample_manifest, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  let html = render_web_html(m, true)
  assert_true(html.contains("<title>Demo Web</title>"))
  assert_true(html.contains("prefers-color-scheme: light)\" content=\"#FFFFFF\""))
  assert_true(html.contains("prefers-color-scheme: dark)\" content=\"#111111\""))
  assert_true(html.contains("<link rel=\"icon\" href=\"favicon.ico\">"))
  assert_true(html.contains("<link rel=\"manifest\" href=\"manifest.webmanifest\">"))
  assert_true(html.contains("<meta name=\"author\" content=\"Demo\">"))
  assert_true(html.contains("['host.js', 'app.js']"))
  assert_true(html.contains("id=\"nogl\""))

  let mf = render_web_manifest(m, true)
  let parsed = try @rjson.parse(mf) catch {
    @rjson.JsonError(e) => fail("invalid webmanifest json: \{e}")
  }
  assert_true(parsed.get("name") == Some(Str("Demo Web")))
  assert_true(parsed.get("short_name") == Some(Str("Demo Client")))
  assert_true(parsed.get("display") == Some(Str("standalone")))
  assert_true(parsed.get("icons") is Some(Arr(_)))
}

///|
test "placeholder icon generates valid 256x256 PNG" {
  let pic = make_placeholder_icon(64)
  assert_eq(pic.w, 64)
  assert_eq(pic.h, 64)
  // Corner outside rounded rect is transparent, center is opaque
  let corner = pic.rgba(0, 0)
  assert_eq(corner.3, 0)
  let center = pic.rgba(32, 32)
  assert_eq(center.3, 255)
  let png_bytes = @png.encode_png(pic)
  assert_true(@png.decode_png(png_bytes) is Ok(_))
}

///|
let full_6target_manifest : String =
  #|{
  #|  "appId": "dev.example.omni",
  #|  "name": "Omni App",
  #|  "executable": "omni-app",
  #|  "version": "2.4.7-rc.1",
  #|  "build": 128,
  #|  "entry": "src/app",
  #|  "icon": "assets/icon.png",
  #|  "urlSchemes": ["omni", "omni-open"],
  #|  "env": {
  #|    "Z_KEY": "last",
  #|    "A_KEY": "first value"
  #|  },
  #|  "updater": {
  #|    "feed": "https://updates.example.com/linux-{arch}/latest.json"
  #|  },
  #|  "windows": {
  #|    "company": "Example Corp",
  #|    "installDir": "OmniApp",
  #|    "formats": ["portable", "setup"],
  #|    "rawForDelta": true
  #|  },
  #|  "linux": {
  #|    "categories": ["Development", "Utility"],
  #|    "formats": ["tar.gz", "deb"]
  #|  },
  #|  "android": {
  #|    "minSdk": 26,
  #|    "targetSdk": 35,
  #|    "compileSdk": 35,
  #|    "abis": ["arm64-v8a", "x86_64"],
  #|    "edgeToEdge": true,
  #|    "ground": "#FFFFFF,#111111",
  #|    "permissions": ["android.permission.CAMERA", "android.permission.RECORD_AUDIO"]
  #|  },
  #|  "ios": {
  #|    "minVersion": "17.0",
  #|    "edgeToEdge": true,
  #|    "ground": "#FFFFFF,#111111",
  #|    "shareExtension": true,
  #|    "usageDescriptions": {
  #|      "NSCameraUsageDescription": "Take photos",
  #|      "NSMicrophoneUsageDescription": "Record audio"
  #|    }
  #|  }
  #|}

///|
test "parse_targets supports comma-separated targets, dedups, and rejects invalid" {
  assert_eq(parse_targets("web,mac,win,linux,android,ios"), Ok(["web", "mac", "win", "linux", "android", "ios"]))
  assert_eq(parse_targets(" linux , win , linux "), Ok(["linux", "win"]))
  assert_true(parse_targets("") is Err(_))
  assert_true(parse_targets("mac,bsd") is Err(_))
}

///|
test "windows version quad, env, rc, and setup.env rendering" {
  assert_eq(parse_win_version_quad("2.4.7-rc.1", 128), (2, 4, 7, 128))
  assert_eq(parse_win_version_quad("1.0", 5), (1, 0, 0, 5))
  assert_eq(parse_win_version_quad("3.2.1+build", 70000), (3, 2, 1, 65535))

  let m = match parse_manifest(full_6target_manifest, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  let wenv = render_win_env(m)
  assert_true(wenv.contains("MBUI_APP_ID=dev.example.omni\n"))
  assert_true(wenv.contains("MBUI_APP_NAME=Omni App\n"))
  assert_true(wenv.contains("MBUI_SCHEMES=omni,omni-open\n"))
  assert_true(wenv.contains("MBUI_UPDATE_FEED=https://updates.example.com/linux-{arch}/latest.json\n"))
  // Deterministic sorted order: A_KEY before Z_KEY
  let idx_a = wenv.find("A_KEY=first value").unwrap_or(-1)
  let idx_z = wenv.find("Z_KEY=last").unwrap_or(-1)
  assert_true(idx_a > 0 && idx_z > idx_a)

  let rc = render_win_rc(m, true)
  assert_true(rc.contains("1 ICON \"app.ico\""))
  assert_true(rc.contains("MBUI_ENV RCDATA \"app.env\""))
  assert_true(rc.contains("FILEVERSION 2,4,7,128"))
  assert_true(rc.contains("VALUE \"CompanyName\", \"Example Corp\\0\""))
  assert_true(rc.contains("VALUE \"OriginalFilename\", \"omni-app.exe\\0\""))

  let senv = render_setup_env(m)
  assert_true(senv.contains("APP_NAME=Omni App\n"))
  assert_true(senv.contains("APP_ID=dev.example.omni\n"))
  assert_true(senv.contains("EXE=omni-app.exe\n"))
  assert_true(senv.contains("DIR=OmniApp\n"))
  assert_true(senv.contains("VERSION=2.4.7-rc.1\n"))
  assert_true(senv.contains("PUBLISHER=Example Corp\n"))
  assert_true(senv.contains("SCHEMES=omni,omni-open\n"))
}

///|
test "linux install.sh, desktop, and deb control rendering" {
  let m = match parse_manifest(full_6target_manifest, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  let tmpl_install =
    #|id='@APP_ID@'
    #|app_name='@APP_NAME@'
    #|exe='@EXE@'
    #|categories='@CATEGORIES@'
    #|schemes='@SCHEMES@'
    #|update_feed_x64='@UPDATE_FEED_X64@'
    #|update_feed_arm64='@UPDATE_FEED_ARM64@'
    #|extra_env='@EXTRA_ENV@'
    #|
  let rendered = match render_linux_install_sh(tmpl_install, m) {
    Ok(s) => s
    Err(e) => fail("unexpected error: \{e}")
  }
  assert_true(rendered.contains("id='dev.example.omni'"))
  assert_true(rendered.contains("app_name='Omni App'"))
  assert_true(rendered.contains("exe='omni-app'"))
  assert_true(rendered.contains("categories='Development;Utility;'"))
  assert_true(rendered.contains("schemes='omni,omni-open'"))
  assert_true(rendered.contains("update_feed_x64='https://updates.example.com/linux-x64/latest.json'"))
  assert_true(rendered.contains("update_feed_arm64='https://updates.example.com/linux-arm64/latest.json'"))
  assert_true(rendered.contains("\"A_KEY=first value\" Z_KEY=last"))
  assert_true(find_unreplaced_placeholder(rendered) is None)

  // Unreplaced unknown placeholder must error
  assert_true(render_linux_install_sh("x='@UNKNOWN_TOKEN@'", m) is Err(_))

  let tmpl_desktop =
    #|[Desktop Entry]
    #|Name=@APP_NAME@
    #|Exec=env MBUI_APP_ID=@APP_ID@ @EXTRA_ENV@ "@EXE@" %u
    #|Categories=@CATEGORIES@
    #|MimeType=@MIME_TYPES@
    #|
  let desktop = match render_linux_desktop(tmpl_desktop, m) {
    Ok(s) => s
    Err(e) => fail("unexpected error: \{e}")
  }
  assert_true(desktop.contains("Name=Omni App"))
  assert_true(desktop.contains("/opt/dev.example.omni/omni-app"))
  assert_true(desktop.contains("MimeType=x-scheme-handler/omni;x-scheme-handler/omni-open;"))
  assert_true(find_unreplaced_placeholder(desktop) is None)

  let ctrl = render_deb_control(m, "x64", 4096)
  assert_true(ctrl.contains("Package: dev.example.omni\n"))
  assert_true(ctrl.contains("Version: 2.4.7-rc.1-128\n"))
  assert_true(ctrl.contains("Architecture: amd64\n"))
  assert_true(ctrl.contains("Installed-Size: 4096\n"))
}

///|
test "android apk.json and repack CLI arg rendering" {
  let m = match parse_manifest(full_6target_manifest, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  let json_txt = render_apk_json(m, "/app", "/tmp/res", "/tmp/jni", "/tmp/assets")
  let parsed = try @rjson.parse(json_txt) catch {
    @rjson.JsonError(e) => fail("invalid apk.json: \{e}")
  }
  assert_true(parsed.get("applicationId") == Some(Str("dev.example.omni")))
  assert_true(parsed.get("manifest") == Some(Str("@mbui")))
  assert_true(parsed.get("label") == Some(Str("Omni App")))
  assert_true(parsed.get("edgeToEdge") == Some(Bool(true)))
  assert_true(parsed.get("ground") == Some(Str("#FFFFFF,#111111")))
  assert_true(parsed.get("urlSchemes") is Some(Arr(_)))
  assert_true(parsed.get("permissions") is Some(Arr(_)))

  let opts : PackOptions = {
    ..PackOptions::default(),
    keystore: "/keys/rel.jks",
    key_alias: "rel",
    ks_pass: "env:KS_PASS",
    key_pass: "env:KEY_PASS",
    v3_signing: true,
    verify_cert: "deadbeef",
  }
  let args = build_repack_args(m, "/in.apk", "/out.apk", opts)
  assert_eq(args[0], "repack")
  assert_eq(args[1], "/in.apk")
  assert_true(args.contains("--app-id"))
  assert_true(args.contains("dev.example.omni"))
  assert_true(args.contains("--version-code"))
  assert_true(args.contains("128"))
  assert_true(args.contains("--url-scheme"))
  assert_true(args.contains("omni-open"))
  assert_true(args.contains("--permission"))
  assert_true(args.contains("android.permission.CAMERA"))
  assert_true(args.contains("--v3-signing"))
  assert_true(args.contains("--verify-cert"))
  assert_true(args.contains("deadbeef"))
}

///|
test "ios Info.plist and AppIcon Contents.json rendering" {
  let m = match parse_manifest(full_6target_manifest, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  let sim_plist = render_ios_info_plist(m, "iphonesimulator")
  assert_true(sim_plist.contains("<key>CFBundleIdentifier</key>\n\t<string>dev.example.omni</string>"))
  assert_true(sim_plist.contains("<key>CFBundleDisplayName</key>\n\t<string>Omni App</string>"))
  assert_true(sim_plist.contains("<key>MinimumOSVersion</key>\n\t<string>17.0</string>"))
  assert_true(sim_plist.contains("<string>iPhoneSimulator</string>"))
  assert_true(sim_plist.contains("<key>CFBundleIconName</key>\n\t<string>AppIcon</string>"))
  assert_true(sim_plist.contains("<key>UIRequiresFullScreen</key>\n\t<false/>"))
  assert_true(sim_plist.contains("<key>MBUIEdgeToEdge</key>\n\t<true/>"))
  assert_true(sim_plist.contains("<key>MBUIGround</key>\n\t<string>#FFFFFF,#111111</string>"))
  assert_true(sim_plist.contains("<key>NSCameraUsageDescription</key>\n\t<string>Take photos</string>"))
  assert_true(sim_plist.contains("<string>omni-open</string>"))

  let dev_plist = render_ios_info_plist(m, "iphoneos")
  assert_true(dev_plist.contains("<string>iPhoneOS</string>"))

  let icon_json = render_ios_appicon_contents_json(has_dark=true)
  let parsed = try @rjson.parse(icon_json) catch {
    @rjson.JsonError(e) => fail("invalid AppIcon Contents.json: \{e}")
  }
  assert_true(parsed.get("images") is Some(Arr(_)))
}

///|
test "build_repack_args handles optional --debuggable flag" {
  let m = match parse_manifest(full_6target_manifest, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  let args_none = build_repack_args(m, "/in.apk", "/out.apk", PackOptions::default())
  assert_true(!args_none.contains("--debuggable"))

  let args_false = build_repack_args(
    m,
    "/in.apk",
    "/out.apk",
    { ..PackOptions::default(), debuggable: Some(false) },
  )
  assert_true(args_false.contains("--debuggable"))
  assert_true(args_false.contains("false"))

  let args_true = build_repack_args(
    m,
    "/in.apk",
    "/out.apk",
    { ..PackOptions::default(), debuggable: Some(true) },
  )
  assert_true(args_true.contains("--debuggable"))
  assert_true(args_true.contains("true"))
}

///|
test "build_publish_args enforces scripts/release subcommand and flag contract" {
  let m = match parse_manifest(full_6target_manifest, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  // Default subcommand is "publish" with no injected --version/--build/--kind/--app-id
  let def_args = build_publish_args(m, ["--dir", "/dist", "--bucket", "r2://rel"])
  assert_eq(def_args, ["publish", "--dir", "/dist", "--bucket", "r2://rel"])

  // Explicit non-feed/sign subcommands preserve order and never inject --version/--build/--kind/--app-id
  assert_eq(build_publish_args(m, ["keygen", "--out", "/k"]), ["keygen", "--out", "/k"])
  assert_eq(build_publish_args(m, ["verify", "a.zip", "a.sig"]), ["verify", "a.zip", "a.sig"])
  assert_eq(build_publish_args(m, ["delta", "old.bin", "new.bin"]), ["delta", "old.bin", "new.bin"])
  assert_eq(build_publish_args(m, ["publish", "--dry-run"]), ["publish", "--dry-run"])

  // "feed" and "sign" auto-fill missing --version, --build, --kind <appId> (never --app-id)
  let feed_args = build_publish_args(m, ["feed", "--out", "/dist/latest.json"])
  assert_eq(feed_args[0], "feed")
  assert_true(feed_args.contains("--version"))
  assert_true(feed_args.contains("2.4.7-rc.1"))
  assert_true(feed_args.contains("--build"))
  assert_true(feed_args.contains("128"))
  assert_true(feed_args.contains("--kind"))
  assert_true(feed_args.contains("dev.example.omni"))
  assert_true(!feed_args.contains("--app-id"))

  // Explicit --version/--kind on "sign" are not duplicated
  let sign_args = build_publish_args(m, ["sign", "--version", "9.9.9", "--kind", "custom.id", "a.zip"])
  assert_eq(sign_args, ["sign", "--build", "128", "--version", "9.9.9", "--kind", "custom.id", "a.zip"])
}

///|
test "moduleDir parsing, variant override, and resolve_module_dir" {
  let raw =
    #|{
    #|  "appId": "dev.example.multi",
    #|  "name": "Multi Mod",
    #|  "moduleDir": "ui",
    #|  "variants": {
    #|    "alt": {
    #|      "moduleDir": "packages/alt-ui"
    #|    }
    #|  }
    #|}
  let m_base = match parse_manifest(raw, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  assert_eq(m_base.module_dir, "ui")
  assert_eq(m_base.resolve_module_dir("/workspace/repo"), "/workspace/repo/ui")

  let m_alt = match
    parse_manifest(raw, { ..CliOverrides::empty(), variant: Some("alt") }) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  assert_eq(m_alt.module_dir, "packages/alt-ui")
  assert_eq(m_alt.resolve_module_dir("/workspace/repo"), "/workspace/repo/packages/alt-ui")
  assert_eq(normalize_posix_path("/workspace/repo/sub/../ui/./"), "/workspace/repo/ui")

  // Empty moduleDir returns manifest_dir unchanged
  let m_empty = match
    parse_manifest("{\"appId\": \"dev.example.flat\", \"name\": \"Flat\"}", CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  assert_eq(m_empty.module_dir, "")
  assert_eq(m_empty.resolve_module_dir("/workspace/flat"), "/workspace/flat")
}

///|
test "hooks parsing and variant deep-merge" {
  let raw =
    #|{
    #|  "appId": "dev.example.hooked",
    #|  "name": "Hooked App",
    #|  "hooks": {
    #|    "preBuild": "echo pre-base",
    #|    "postStage": "echo stage-base"
    #|  },
    #|  "variants": {
    #|    "beta": {
    #|      "hooks": {
    #|        "postStage": "echo stage-beta",
    #|        "postPack": "echo pack-beta"
    #|      }
    #|    }
    #|  }
    #|}
  let m_base = match parse_manifest(raw, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  assert_eq(m_base.hooks.pre_build, "echo pre-base")
  assert_eq(m_base.hooks.post_stage, "echo stage-base")
  assert_eq(m_base.hooks.post_pack, "")

  let m_beta = match
    parse_manifest(raw, { ..CliOverrides::empty(), variant: Some("beta") }) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  // Base preBuild preserved, postStage overridden, postPack added
  assert_eq(m_beta.hooks.pre_build, "echo pre-base")
  assert_eq(m_beta.hooks.post_stage, "echo stage-beta")
  assert_eq(m_beta.hooks.post_pack, "echo pack-beta")
}

///|
test "parse_env_override and CLI --env overrides merge onto base and variant env" {
  assert_eq(parse_env_override("FOO=bar"), Ok(("FOO", "bar")))
  assert_eq(parse_env_override("URL=https://x.test/a?b=1&c=2"), Ok(("URL", "https://x.test/a?b=1&c=2")))
  assert_eq(parse_env_override("EMPTY="), Ok(("EMPTY", "")))
  assert_true(parse_env_override("NO_EQUALS") is Err(_))
  assert_true(parse_env_override("=missing_key") is Err(_))

  let overrides : CliOverrides = {
    ..CliOverrides::empty(),
    variant: Some("beta"),
    env: [("LOG_LEVEL", "trace"), ("EXTRA_URL", "https://x.test")],
  }
  let m = match parse_manifest(sample_manifest, overrides) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  assert_eq(m.env.get("API_URL"), Some("https://api.example.com"))
  assert_eq(m.env.get("BETA"), Some("1"))
  assert_eq(m.env.get("LOG_LEVEL"), Some("trace"))
  assert_eq(m.env.get("EXTRA_URL"), Some("https://x.test"))
}

///|
test "render_meta_json and render_meta_sh with POSIX single-quote escaping" {
  let raw =
    #|{
    #|  "appId": "dev.example.meta",
    #|  "name": "O'Brien's $(uname) App",
    #|  "executable": "obrien-app",
    #|  "version": "1.5.0",
    #|  "build": 77,
    #|  "moduleDir": "ui",
    #|  "entry": "src/main",
    #|  "urlSchemes": ["meta", "meta-x"],
    #|  "env": {
    #|    "Z_VAL": "a'b;rm -rf /",
    #|    "A_VAL": "plain"
    #|  },
    #|  "updater": {
    #|    "feed": "https://rel.example.test/latest.json",
    #|    "channel": "beta"
    #|  },
    #|  "macos": {
    #|    "minVersion": "14.2"
    #|  },
    #|  "windows": {
    #|    "company": "O'Brien Co",
    #|    "installDir": "OBrienApp"
    #|  }
    #|}
  let overrides : CliOverrides = {
    ..CliOverrides::empty(),
    env: [("EXTRA_URL", "https://x.test")],
  }
  let m = match parse_manifest(raw, overrides) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }

  let json_txt = render_meta_json(m, "/tmp/proj")
  let parsed = try @rjson.parse(json_txt) catch {
    @rjson.JsonError(e) => fail("invalid meta json: \{e}")
  }
  assert_true(parsed.get("appId") == Some(Str("dev.example.meta")))
  assert_true(parsed.get("moduleDir") == Some(Str("/tmp/proj/ui")))
  assert_true(parsed.get("entry") == Some(Str("src/main")))
  assert_true(parsed.get("build") == Some(Num("77")))
  match parsed.get("env") {
    Some(Obj(_) as env_obj) => {
      assert_true(env_obj.get("EXTRA_URL") == Some(Str("https://x.test")))
      assert_true(env_obj.get("A_VAL") == Some(Str("plain")))
    }
    _ => fail("expected env object in meta json")
  }
  assert_true(parsed.get("macos") is Some(Obj(_)))
  assert_true(parsed.get("windows") is Some(Obj(_)))
  assert_true(parsed.get("linux") is Some(Obj(_)))
  assert_true(parsed.get("android") is Some(Obj(_)))
  assert_true(parsed.get("ios") is Some(Obj(_)))
  assert_true(parsed.get("web") is Some(Obj(_)))

  let sh_txt = render_meta_sh(m, "/tmp/proj")
  assert_true(sh_txt.contains("MBUI_APP_ID='dev.example.meta'\n"))
  // Single quotes escaped as '\'' so $(uname) and semicolons stay literal inside single quotes
  assert_true(sh_txt.contains("MBUI_APP_NAME='O'\\''Brien'\\''s $(uname) App'\n"))
  assert_true(sh_txt.contains("MBUI_EXECUTABLE='obrien-app'\n"))
  assert_true(sh_txt.contains("MBUI_VERSION='1.5.0'\n"))
  assert_true(sh_txt.contains("MBUI_BUILD='77'\n"))
  assert_true(sh_txt.contains("MBUI_MODULE_DIR='/tmp/proj/ui'\n"))
  assert_true(sh_txt.contains("MBUI_ENTRY='src/main'\n"))
  assert_true(sh_txt.contains("MBUI_SCHEMES='meta,meta-x'\n"))
  assert_true(sh_txt.contains("MBUI_UPDATE_FEED='https://rel.example.test/latest.json'\n"))
  assert_true(sh_txt.contains("MBUI_UPDATE_CHANNEL='beta'\n"))
  assert_true(
    sh_txt.contains(
      "MBUI_ENV_KV='A_VAL=plain;EXTRA_URL=https://x.test;Z_VAL=a'\\''b;rm -rf /'\n",
    ),
  )
  assert_true(sh_txt.contains("MBUI_MAC_MIN_VERSION='14.2'\n"))
  assert_true(sh_txt.contains("MBUI_WIN_INSTALL_DIR='OBrienApp'\n"))
  assert_true(sh_txt.contains("MBUI_WIN_COMPANY='O'\\''Brien Co'\n"))
}

///|
test "codesign commands include --keychain when non-empty" {
  let mac_no_kc = build_mac_codesign_cmd("/tmp/App.app", "Dev ID", "", "")
  assert_true(!mac_no_kc.contains("--keychain"))
  let mac_kc = build_mac_codesign_cmd("/tmp/App.app", "Dev ID", "", "/tmp/ci.keychain-db")
  assert_true(mac_kc.contains("--keychain '/tmp/ci.keychain-db'"))
  assert_true(mac_kc.contains("--sign 'Dev ID'"))

  let ios_no_kc = build_ios_codesign_cmd("/tmp/App.app", "-", "", "")
  assert_true(!ios_no_kc.contains("--keychain"))
  let ios_kc = build_ios_codesign_cmd("/tmp/App.app", "Apple Dist", "", "/tmp/ci.keychain-db")
  assert_true(ios_kc.contains("--keychain '/tmp/ci.keychain-db'"))
  assert_true(ios_kc.contains("--sign 'Apple Dist'"))
}

///|
test "resolve_module_dir preserves Windows drive paths" {
  let dot_json = "{\"appId\":\"dev.example.win\",\"name\":\"WinApp\",\"moduleDir\":\".\"}"
  let m_dot = match parse_manifest(dot_json, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail(e)
  }
  assert_eq(m_dot.resolve_module_dir("D:/a/b"), "D:/a/b")
  assert_eq(m_dot.resolve_module_dir("D:\\a\\b"), "D:/a/b")

  let rel_json = "{\"appId\":\"dev.example.win\",\"name\":\"WinApp\",\"moduleDir\":\"../ui\"}"
  let m_rel = match parse_manifest(rel_json, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail(e)
  }
  assert_eq(m_rel.resolve_module_dir("D:/a/b"), "D:/a/ui")
  assert_eq(m_rel.resolve_module_dir("D:\\a\\b"), "D:/a/ui")

  let up_json = "{\"appId\":\"dev.example.win\",\"name\":\"WinApp\",\"moduleDir\":\"../../..\"}"
  let m_up = match parse_manifest(up_json, CliOverrides::empty()) {
    Ok(m) => m
    Err(e) => fail(e)
  }
  assert_eq(m_up.resolve_module_dir("D:/a/b"), "D:/")
}
