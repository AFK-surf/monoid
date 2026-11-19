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
      { variant: Some("nonexistent"), version: None, build: None, app_id: None },
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
  }
  let m = match parse_manifest(sample_manifest, overrides) {
    Ok(m) => m
    Err(e) => fail("unexpected error: \{e}")
  }
  // CLI overrides beat variant and base
  assert_eq(m.app_id, "dev.override.id")
  assert_eq(m.version, "2.0.0-rc1")
  assert_eq(m.build, 99)
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
