// iOS target: Info.plist & AppIcon.appiconset generation, native/wasm .app assembly, signing, and .ipa packaging.

///|
/// Generate a valid iOS XML `Info.plist` from the manifest and target SDK (`iphonesimulator` or `iphoneos`).
pub fn render_ios_info_plist(m : Manifest, sdk : String) -> String {
  let platform = if sdk == "iphoneos" { "iPhoneOS" } else { "iPhoneSimulator" }
  let sb = StringBuilder()
  sb.write_string("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
  sb.write_string(
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n",
  )
  sb.write_string("<plist version=\"1.0\">\n")
  sb.write_string("<dict>\n")
  write_plist_kv(sb, "CFBundleIdentifier", m.app_id)
  write_plist_kv(sb, "CFBundleExecutable", "mbui")
  write_plist_kv(sb, "CFBundleName", m.name)
  write_plist_kv(sb, "CFBundleDisplayName", m.name)
  write_plist_kv(sb, "CFBundlePackageType", "APPL")
  write_plist_kv(sb, "CFBundleInfoDictionaryVersion", "6.0")
  write_plist_kv(sb, "CFBundleDevelopmentRegion", "en")
  write_plist_kv(sb, "CFBundleShortVersionString", m.version)
  write_plist_kv(sb, "CFBundleVersion", m.build.to_string())
  write_plist_kv(sb, "MinimumOSVersion", m.ios.min_version)
  sb.write_string("\t<key>CFBundleSupportedPlatforms</key>\n")
  sb.write_string("\t<array>\n")
  sb.write_string("\t\t<string>\{platform}</string>\n")
  sb.write_string("\t</array>\n")
  sb.write_string("\t<key>UIDeviceFamily</key>\n")
  sb.write_string("\t<array>\n")
  sb.write_string("\t\t<integer>1</integer>\n")
  sb.write_string("\t\t<integer>2</integer>\n")
  sb.write_string("\t</array>\n")
  sb.write_string("\t<key>UIRequiredDeviceCapabilities</key>\n")
  sb.write_string("\t<array>\n")
  sb.write_string("\t\t<string>arm64</string>\n")
  sb.write_string("\t</array>\n")
  write_plist_bool(sb, "UIRequiresFullScreen", false)
  write_plist_bool(sb, "CADisableMinimumFrameDurationOnPhone", true)
  sb.write_string("\t<key>UILaunchScreen</key>\n")
  sb.write_string("\t<dict/>\n")
  sb.write_string("\t<key>UIApplicationSceneManifest</key>\n")
  sb.write_string("\t<dict>\n")
  sb.write_string("\t\t<key>UIApplicationSupportsMultipleScenes</key>\n")
  sb.write_string("\t\t<false/>\n")
  sb.write_string("\t\t<key>UISceneConfigurations</key>\n")
  sb.write_string("\t\t<dict>\n")
  sb.write_string("\t\t\t<key>UIWindowSceneSessionRoleApplication</key>\n")
  sb.write_string("\t\t\t<array>\n")
  sb.write_string("\t\t\t\t<dict>\n")
  sb.write_string("\t\t\t\t\t<key>UISceneConfigurationName</key>\n")
  sb.write_string("\t\t\t\t\t<string>Default</string>\n")
  sb.write_string("\t\t\t\t\t<key>UISceneDelegateClassName</key>\n")
  sb.write_string("\t\t\t\t\t<string>MBSceneDelegate</string>\n")
  sb.write_string("\t\t\t\t</dict>\n")
  sb.write_string("\t\t\t</array>\n")
  sb.write_string("\t\t</dict>\n")
  sb.write_string("\t</dict>\n")
  sb.write_string("\t<key>UISupportedInterfaceOrientations</key>\n")
  sb.write_string("\t<array>\n")
  sb.write_string("\t\t<string>UIInterfaceOrientationPortrait</string>\n")
  sb.write_string("\t\t<string>UIInterfaceOrientationLandscapeLeft</string>\n")
  sb.write_string("\t\t<string>UIInterfaceOrientationLandscapeRight</string>\n")
  sb.write_string("\t</array>\n")
  sb.write_string("\t<key>UISupportedInterfaceOrientations~ipad</key>\n")
  sb.write_string("\t<array>\n")
  sb.write_string("\t\t<string>UIInterfaceOrientationPortrait</string>\n")
  sb.write_string("\t\t<string>UIInterfaceOrientationPortraitUpsideDown</string>\n")
  sb.write_string("\t\t<string>UIInterfaceOrientationLandscapeLeft</string>\n")
  sb.write_string("\t\t<string>UIInterfaceOrientationLandscapeRight</string>\n")
  sb.write_string("\t</array>\n")
  if m.icon != "" {
    write_plist_kv(sb, "CFBundleIconName", "AppIcon")
  }
  if m.url_schemes.length() > 0 {
    sb.write_string("\t<key>CFBundleURLTypes</key>\n")
    sb.write_string("\t<array>\n")
    sb.write_string("\t\t<dict>\n")
    sb.write_string("\t\t\t<key>CFBundleURLName</key>\n")
    sb.write_string("\t\t\t<string>\{escape_xml(m.app_id)}</string>\n")
    sb.write_string("\t\t\t<key>CFBundleURLSchemes</key>\n")
    sb.write_string("\t\t\t<array>\n")
    for scheme in m.url_schemes {
      sb.write_string("\t\t\t\t<string>\{escape_xml(scheme)}</string>\n")
    }
    sb.write_string("\t\t\t</array>\n")
    sb.write_string("\t\t</dict>\n")
    sb.write_string("\t</array>\n")
  }
  write_plist_bool(sb, "MBUIEdge", m.ios.edge_to_edge)
  write_plist_bool(sb, "MBUIEdgeToEdge", m.ios.edge_to_edge)
  if m.ios.ground != "" {
    write_plist_kv(sb, "MBUIGround", m.ios.ground)
  }
  if m.ios.share_extension {
    write_plist_kv(sb, "MBUIAppGroup", "group." + m.app_id)
  }
  for kv in m.ios.usage_descriptions {
    write_plist_kv(sb, kv.0, kv.1)
  }
  sb.write_string("</dict>\n")
  sb.write_string("</plist>\n")
  sb.to_string()
}

///|
/// Generate `AppIcon.appiconset/Contents.json` matching `tools/png` iOS icon outputs.
pub fn render_ios_appicon_contents_json(has_dark? : Bool = false) -> String {
  render_ios_iconset_json(has_dark)
}

///|
pub fn build_ios_codesign_cmd(
  path : String,
  sign_identity : String,
  ent_arg : String,
  keychain : String,
) -> String {
  let id = if sign_identity != "" { sign_identity } else { "-" }
  let ts = if id == "-" { " --timestamp=none" } else { "" }
  let kc = if keychain != "" { " --keychain " + q(keychain) } else { "" }
  "codesign --force --sign " + q(id) + ts + kc + ent_arg + " " + q(path)
}

///|
fn ios_sign_item(
  path : String,
  sign_identity : String,
  ent_arg : String,
  keychain : String,
) -> Unit {
  let cmd = build_ios_codesign_cmd(path, sign_identity, ent_arg, keychain)
  ignore(sh(cmd, "codesign iOS " + @sys.basename(path)))
}

///|
pub fn pack_ios(
  m : Manifest,
  manifest_dir : String,
  mbui_dir : String,
  out_dir : String,
  opts : PackOptions,
) -> Unit {
  let sdk = if opts.ios_sdk != "" { opts.ios_sdk } else { "iphonesimulator" }
  if sdk != "iphonesimulator" && sdk != "iphoneos" {
    die("invalid --ios-sdk '\{sdk}' (expected iphonesimulator or iphoneos)")
  }
  let ios_out = @sys.join(out_dir, "ios")
  let build_out = @sys.join(out_dir, ".build")
  let stage_meta = @sys.join(build_out, "ios-meta")
  let app_dir = @sys.join(ios_out, m.name + ".app")
  @sys.makedirs(ios_out)
  @sys.makedirs(build_out)
  @sys.makedirs(stage_meta)

  let mod_dir = m.resolve_module_dir(manifest_dir)
  run_hook("preBuild", m.hooks.pre_build, m, manifest_dir, mbui_dir, "ios", app_dir, ios_out)

  // Generate Assets.xcassets/AppIcon.appiconset if icon configured
  let assets_dir = @sys.join(stage_meta, "Assets.xcassets")
  let mut has_assets = false
  if m.icon != "" {
    let icon_path = @sys.join(manifest_dir, m.icon)
    match @png.read(icon_path) {
      Ok(src) => {
        let iconset = @sys.join(assets_dir, "AppIcon.appiconset")
        @sys.makedirs(iconset)
        match write_file_bytes(@sys.join(iconset, "icon.png"), @png.encode_png(src.resize(1024, 1024))) {
          Ok(_) => ()
          Err(e) => die(e)
        }
        let mut has_dark = false
        if m.icon_dark != "" {
          let dark_path = @sys.join(manifest_dir, m.icon_dark)
          match @png.read(dark_path) {
            Ok(dp) =>
              match write_file_bytes(@sys.join(iconset, "icon-dark.png"), @png.encode_png(dp.resize(1024, 1024))) {
                Ok(_) => has_dark = true
                Err(e) => die(e)
              }
            Err(e) => die("iconDark: \{e}")
          }
        }
        match write_file_text(@sys.join(iconset, "Contents.json"), render_ios_appicon_contents_json(has_dark~)) {
          Ok(_) => has_assets = true
          Err(e) => die(e)
        }
      }
      Err(e) => die("icon: \{e}")
    }
  }

  // Generate Info.plist + plutil -lint
  let plist_src = @sys.join(stage_meta, "Info.plist")
  match write_file_text(plist_src, render_ios_info_plist(m, sdk)) {
    Ok(_) => ()
    Err(e) => die(e)
  }
  ignore(sh("plutil -lint " + q(plist_src), "plutil -lint iOS Info.plist"))

  ignore(sh("rm -rf " + q(app_dir), "clean iOS app bundle"))

  if m.runtime == "wasm" {
    let (triple, traps) = if sdk == "iphoneos" {
      ("pulley64", "checked")
    } else {
      let host = try_sh("uname -m").unwrap_or("arm64").trim(chars=" \t\r\n").to_owned()
      let arch = if host == "x86_64" { "x86_64" } else { "aarch64" }
      ("\{arch}-apple-ios-sim", "signals")
    }
    let (payload_path, ext) = prepare_wasm_payload(
      m,
      manifest_dir,
      mbui_dir,
      build_out,
      opts.wasm_aot,
      opts.quick,
      triple,
      traps,
    )
    let rt_dir = resolve_runtime_dir(
      mbui_dir,
      build_out,
      opts.runtime_dir,
      "ios",
      extra_env="MBUI_IOS_SDK=" + q(sdk),
    )
    let rt_app = @sys.join(rt_dir, "MBUI.app")
    if !@sys.is_dir(rt_app) {
      die("iOS Wasm runtime app bundle not found: \{rt_app}")
    }
    ignore(sh("cp -Rp " + q(rt_app) + " " + q(app_dir), "copy iOS wasm runtime app"))
    ignore(
      sh(
        "cp -p " + q(payload_path) + " " + q(@sys.join(app_dir, "app." + ext)),
        "copy app." + ext,
      ),
    )
    ignore(sh("cp -p " + q(plist_src) + " " + q(@sys.join(app_dir, "Info.plist")), "update iOS Info.plist"))
    if has_assets && try_sh("xcrun -f actool") is Some(_) {
      let partial = @sys.join(stage_meta, "assets-info.plist")
      ignore(
        sh(
          "xcrun actool --compile " + q(app_dir) +
          " --platform " + q(sdk) +
          " --minimum-deployment-target " + q(m.ios.min_version) +
          " --target-device iphone --target-device ipad --app-icon AppIcon" +
          " --output-partial-info-plist " + q(partial) + " " + q(assets_dir),
          "actool",
        ),
      )
      ignore(
        try_sh(
          "/usr/libexec/PlistBuddy -c " + q("Merge " + partial) + " " + q(@sys.join(app_dir, "Info.plist")),
        ),
      )
    }
  } else {
    let pkg = m.entry_pkg()
    let ios_sh = @sys.join(mbui_dir, "scripts/ios.sh")
    let assets_env = if has_assets { " MBUI_IOS_ASSETS=" + q(assets_dir) } else { "" }
    let build_cmd = "MBUI_APP_MOD=" + q(mod_dir) +
      " MBUI_OUT=" + q(build_out) +
      " MBUI_IOS_SDK=" + q(sdk) +
      " MBUI_IOS_ID=" + q(m.app_id) +
      " MBUI_IOS_PLIST=" + q(plist_src) +
      " MBUI_IOS_BUILD=" + q(m.build.to_string()) +
      " MBUI_IOS_VERSION=" + q(m.version) +
      assets_env +
      " APP=" + q(pkg) +
      " bash " + q(ios_sh) + " build"
    say("building iOS app (\{pkg}, \{sdk})...")
    ignore(sh(build_cmd, "ios.sh build"))
    let built_sub = if sdk == "iphoneos" { "out/ios-device/MBUI.app" } else { "out/ios/MBUI.app" }
    let built_app = @sys.join(mod_dir, built_sub)
    if !@sys.is_dir(built_app) {
      die("built iOS app not found at \{built_app}")
    }
    ignore(sh("cp -Rp " + q(built_app) + " " + q(app_dir), "copy built iOS app"))
  }

  // Copy resources into app_dir
  for res in m.resources {
    let src_res = @sys.join(manifest_dir, res)
    if !@sys.exists(src_res) {
      die("resource not found: \{src_res}")
    }
    ignore(
      sh(
        "cp -R " + q(src_res) + " " + q(@sys.join(app_dir, @sys.basename(res))),
        "copy iOS resource",
      ),
    )
  }

  // Embed provisioning profile if provided
  if opts.ios_profile != "" {
    let prof = @sys.abspath(opts.ios_profile)
    if !@sys.is_file(prof) {
      die("iOS provisioning profile not found: \{prof}")
    }
    ignore(
      sh(
        "cp -p " + q(prof) + " " + q(@sys.join(app_dir, "embedded.mobileprovision")),
        "embed provisioning profile",
      ),
    )
  }

  run_hook("postStage", m.hooks.post_stage, m, manifest_dir, mbui_dir, "ios", app_dir, ios_out)

  // Nested signing: Frameworks first, then .app bundle
  let ent_arg = if m.ios.entitlements != "" {
    let ep = @sys.join(manifest_dir, m.ios.entitlements)
    if !@sys.is_file(ep) {
      die("iOS entitlements file not found: \{ep}")
    }
    " --entitlements " + q(ep)
  } else {
    ""
  }
  let fw_dir = @sys.join(app_dir, "Frameworks")
  if @sys.is_dir(fw_dir) {
    let entries = @sys.list_dir(fw_dir)
    entries.sort_by(fn(a, b) { @rjson.str_cmp(a, b) })
    for entry in entries {
      if entry.has_suffix(".dylib") || entry.has_suffix(".framework") {
        ios_sign_item(@sys.join(fw_dir, entry), opts.sign_identity, "", opts.keychain)
      }
    }
  }
  if opts.sign_identity != "" || sdk == "iphonesimulator" {
    ios_sign_item(app_dir, opts.sign_identity, ent_arg, opts.keychain)
  }

  let formats = if opts.formats.length() > 0 { opts.formats } else { ["app"] }
  for fmt in formats {
    match fmt {
      "app" => say("iOS app bundle: \{app_dir}")
      "ipa" => {
        let ipa_stage = @sys.join(build_out, "ipa-stage")
        let payload_dir = @sys.join(ipa_stage, "Payload")
        ignore(sh("rm -rf " + q(ipa_stage), "clean ipa stage"))
        @sys.makedirs(payload_dir)
        ignore(
          sh(
            "cp -Rp " + q(app_dir) + " " + q(@sys.join(payload_dir, m.name + ".app")),
            "stage ipa Payload",
          ),
        )
        let ipa_path = @sys.join(ios_out, m.name + ".ipa")
        ignore(@sys.remove(ipa_path))
        ignore(
          sh(
            "cd " + q(ipa_stage) + " && zip -q -r " + q(ipa_path) + " Payload",
            "zip ipa",
          ),
        )
        ignore(sh("rm -rf " + q(ipa_stage), "cleanup ipa stage"))
        say("iOS ipa: \{ipa_path}")
      }
      _ => die("unknown iOS format '\{fmt}' (expected app or ipa)")
    }
  }

  run_hook("postPack", m.hooks.post_pack, m, manifest_dir, mbui_dir, "ios", app_dir, ios_out)
}
