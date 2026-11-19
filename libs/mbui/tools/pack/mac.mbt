// macOS target: Info.plist XML generation, .app assembly, codesign, zip and dmg packaging.

///|
fn escape_xml(s : String) -> String {
  let sb = StringBuilder()
  for c in s {
    match c {
      '&' => sb.write_string("&amp;")
      '<' => sb.write_string("&lt;")
      '>' => sb.write_string("&gt;")
      '"' => sb.write_string("&quot;")
      '\'' => sb.write_string("&apos;")
      _ => sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
fn write_indent(sb : StringBuilder, n : Int) -> Unit {
  for _ in 0..<n {
    sb.write_char('\t')
  }
}

///|
fn write_plist_value(sb : StringBuilder, v : @rjson.Value, depth : Int) -> Unit {
  match v {
    Str(s) => {
      write_indent(sb, depth)
      sb.write_string("<string>\{escape_xml(s)}</string>\n")
    }
    Bool(b) => {
      write_indent(sb, depth)
      sb.write_string(if b { "<true/>\n" } else { "<false/>\n" })
    }
    Num(n) => {
      write_indent(sb, depth)
      if n.contains(".") || n.contains("e") || n.contains("E") {
        sb.write_string("<real>\{escape_xml(n)}</real>\n")
      } else {
        sb.write_string("<integer>\{escape_xml(n)}</integer>\n")
      }
    }
    Arr(xs) => {
      write_indent(sb, depth)
      sb.write_string("<array>\n")
      for x in xs {
        write_plist_value(sb, x, depth + 1)
      }
      write_indent(sb, depth)
      sb.write_string("</array>\n")
    }
    Obj(kvs) => {
      write_indent(sb, depth)
      sb.write_string("<dict>\n")
      for kv in kvs {
        write_indent(sb, depth + 1)
        sb.write_string("<key>\{escape_xml(kv.0)}</key>\n")
        write_plist_value(sb, kv.1, depth + 1)
      }
      write_indent(sb, depth)
      sb.write_string("</dict>\n")
    }
    Null => {
      write_indent(sb, depth)
      sb.write_string("<string></string>\n")
    }
  }
}

///|
fn write_plist_kv(sb : StringBuilder, key : String, val : String) -> Unit {
  sb.write_string("\t<key>\{escape_xml(key)}</key>\n")
  sb.write_string("\t<string>\{escape_xml(val)}</string>\n")
}

///|
fn write_plist_bool(sb : StringBuilder, key : String, val : Bool) -> Unit {
  sb.write_string("\t<key>\{escape_xml(key)}</key>\n")
  sb.write_string(if val { "\t<true/>\n" } else { "\t<false/>\n" })
}

///|
/// Generate a standard macOS XML `Info.plist` from the manifest.
pub fn render_info_plist(m : Manifest, has_icon : Bool) -> String {
  let sb = StringBuilder()
  sb.write_string("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
  sb.write_string(
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n",
  )
  sb.write_string("<plist version=\"1.0\">\n")
  sb.write_string("<dict>\n")
  write_plist_kv(sb, "CFBundleIdentifier", m.app_id)
  write_plist_kv(sb, "CFBundleName", m.name)
  write_plist_kv(sb, "CFBundleDisplayName", m.name)
  write_plist_kv(sb, "CFBundleExecutable", m.executable)
  write_plist_kv(sb, "CFBundlePackageType", "APPL")
  write_plist_kv(sb, "CFBundleInfoDictionaryVersion", "6.0")
  write_plist_kv(sb, "CFBundleShortVersionString", m.version)
  write_plist_kv(sb, "CFBundleVersion", m.build.to_string())
  write_plist_kv(sb, "LSMinimumSystemVersion", m.macos.min_version)
  write_plist_kv(sb, "NSPrincipalClass", "NSApplication")
  write_plist_bool(sb, "NSHighResolutionCapable", true)
  write_plist_bool(sb, "NSSupportsAutomaticGraphicsSwitching", true)
  if has_icon {
    write_plist_kv(sb, "CFBundleIconFile", "AppIcon")
  }
  if m.macos.category != "" {
    write_plist_kv(sb, "LSApplicationCategoryType", m.macos.category)
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
  if m.env.length() > 0 {
    let keys : Array[String] = []
    m.env.each(fn(k, _) { keys.push(k) })
    keys.sort_by(fn(a, b) { @rjson.str_cmp(a, b) })
    sb.write_string("\t<key>LSEnvironment</key>\n")
    sb.write_string("\t<dict>\n")
    for k in keys {
      let v = m.env.get(k).unwrap_or("")
      sb.write_string("\t\t<key>\{escape_xml(k)}</key>\n")
      sb.write_string("\t\t<string>\{escape_xml(v)}</string>\n")
    }
    sb.write_string("\t</dict>\n")
  }
  for kv in m.macos.info_plist {
    sb.write_string("\t<key>\{escape_xml(kv.0)}</key>\n")
    write_plist_value(sb, kv.1, 1)
  }
  sb.write_string("</dict>\n")
  sb.write_string("</plist>\n")
  sb.to_string()
}

///|
/// Resolve the native binary path produced by `moon build` in `manifest_dir` (mirrors `env.sh`'s `pkg_build`).
fn find_native_exe(manifest_dir : String, pkg : String, mode : String) -> String {
  let mod_prefix = resolve_mod_prefix(manifest_dir)
  let base_pkg = @sys.basename(pkg)
  let candidate = @sys.join(
    manifest_dir,
    "_build/native/\{mode}/build/\{mod_prefix}\{pkg}/\{base_pkg}.exe",
  )
  if @sys.is_file(candidate) {
    return candidate
  }
  let fallback = @sys.join(manifest_dir, "_build/native/\{mode}/build/\{pkg}/\{base_pkg}.exe")
  if @sys.is_file(fallback) {
    return fallback
  }
  die("built macOS binary not found at \{candidate}")
  ""
}

///|
fn mac_host_triple() -> String {
  let arch = try_sh("uname -m").unwrap_or("arm64").trim(chars=" \t\r\n").to_owned()
  if arch == "x86_64" {
    "x86_64-apple-darwin"
  } else {
    "aarch64-apple-darwin"
  }
}

///|
fn sign_mac_item(target_path : String, sign_identity : String, ent_arg : String) -> Unit {
  let cmd = if sign_identity != "" && sign_identity != "-" {
    "codesign --force --options runtime --timestamp" + ent_arg +
    " --sign " + q(sign_identity) + " " + q(target_path)
  } else {
    "codesign --force --sign - --timestamp=none" + ent_arg + " " + q(target_path)
  }
  ignore(sh(cmd, "codesign " + @sys.basename(target_path)))
}

///|
pub fn pack_mac(
  m : Manifest,
  manifest_dir : String,
  mbui_dir : String,
  out_dir : String,
  opts : PackOptions,
) -> Unit {
  let mac_out = @sys.join(out_dir, "mac")
  let build_out = @sys.join(out_dir, ".build")
  @sys.makedirs(mac_out)
  @sys.makedirs(build_out)

  let pkg = m.entry_pkg()
  let mode = if opts.quick { "debug" } else { "release" }
  let app_dir = @sys.join(mac_out, m.name + ".app")
  let macos_dir = @sys.join(app_dir, "Contents/MacOS")
  let frameworks_dir = @sys.join(app_dir, "Contents/Frameworks")
  let res_dir = @sys.join(app_dir, "Contents/Resources")

  ignore(sh("rm -rf " + q(app_dir), "clean app bundle"))
  @sys.makedirs(macos_dir)
  @sys.makedirs(res_dir)

  let exe_dst = @sys.join(macos_dir, m.executable)
  let nested_to_sign : Array[String] = []

  if m.runtime == "wasm" {
    let triple = mac_host_triple()
    let (payload_path, ext) = prepare_wasm_payload(
      m,
      manifest_dir,
      mbui_dir,
      build_out,
      opts.wasm_aot,
      opts.quick,
      triple,
      "signals",
    )
    let rt_dir = resolve_runtime_dir(mbui_dir, build_out, opts.runtime_dir, "mac")
    let rt_bin = @sys.join(rt_dir, "mbui-runtime")
    let rt_dylib = @sys.join(rt_dir, "libwasmtime.dylib")
    if !@sys.is_file(rt_bin) {
      die("macOS Wasm runtime binary not found: \{rt_bin}")
    }
    if !@sys.is_file(rt_dylib) {
      die("macOS Wasm runtime library not found: \{rt_dylib}")
    }
    @sys.makedirs(frameworks_dir)
    ignore(
      sh(
        "cp -p " + q(rt_bin) + " " + q(exe_dst) + " && chmod +x " + q(exe_dst),
        "copy macOS wasm runtime",
      ),
    )
    let dylib_dst = @sys.join(frameworks_dir, "libwasmtime.dylib")
    ignore(sh("cp -p " + q(rt_dylib) + " " + q(dylib_dst), "copy libwasmtime.dylib"))
    nested_to_sign.push(dylib_dst)
    let payload_dst = @sys.join(res_dir, "app." + ext)
    ignore(sh("cp -p " + q(payload_path) + " " + q(payload_dst), "copy app." + ext))
  } else {
    let mac_sh = @sys.join(mbui_dir, "scripts/mac.sh")
    let build_cmd = "MBUI_APP_MOD=" + q(manifest_dir) +
      " MBUI_OUT=" + q(build_out) +
      " APP=" + q(pkg) +
      " MODE=" + q(mode) +
      " MACOSX_DEPLOYMENT_TARGET=" + q(m.macos.min_version) +
      " bash " + q(mac_sh) + " build"
    say("building macOS binary (\{pkg}, \{mode})...")
    ignore(sh(build_cmd, "mac.sh build"))

    let exe_src = find_native_exe(manifest_dir, pkg, mode)
    ignore(sh("cp " + q(exe_src) + " " + q(exe_dst) + " && chmod +x " + q(exe_dst), "copy binary"))
    ignore(sh("strip -S -x " + q(exe_dst), "strip binary"))
  }

  // Icon
  let mut has_icon = false
  if m.icon != "" {
    let icon_path = @sys.join(manifest_dir, m.icon)
    match @png.read(icon_path) {
      Ok(src) => {
        let icns_path = @sys.join(res_dir, "AppIcon.icns")
        match write_file_bytes(icns_path, @png.encode_icns(src)) {
          Ok(_) => has_icon = true
          Err(e) => die(e)
        }
      }
      Err(e) => die("icon: \{e}")
    }
  }

  // Resources
  for res in m.resources {
    let src_res = @sys.join(manifest_dir, res)
    if !@sys.exists(src_res) {
      die("resource not found: \{src_res}")
    }
    let dst_res = @sys.join(res_dir, @sys.basename(res))
    ignore(sh("cp -R " + q(src_res) + " " + q(dst_res), "copy resource"))
  }

  // Info.plist + plutil lint
  let plist_path = @sys.join(app_dir, "Contents/Info.plist")
  match write_file_text(plist_path, render_info_plist(m, has_icon)) {
    Ok(_) => ()
    Err(e) => die(e)
  }
  ignore(sh("plutil -lint " + q(plist_path), "plutil -lint"))

  // Codesign (strict Apple nested order: inside-out, Frameworks dylibs first, then .app bundle)
  let ent_arg = if m.macos.entitlements != "" {
    let ep = @sys.join(manifest_dir, m.macos.entitlements)
    if !@sys.is_file(ep) {
      die("entitlements file not found: \{ep}")
    }
    " --entitlements " + q(ep)
  } else {
    ""
  }
  say("signing \{m.name}.app...")
  for nested in nested_to_sign {
    sign_mac_item(nested, opts.sign_identity, "")
  }
  sign_mac_item(app_dir, opts.sign_identity, ent_arg)
  ignore(sh("codesign --verify --deep --strict " + q(app_dir), "codesign --verify"))

  // Optional notarization
  if opts.notarize_profile != "" {
    if opts.sign_identity == "" || opts.sign_identity == "-" {
      die("--notarize-profile requires a valid --sign-identity")
    }
    let notarize_zip = @sys.join(mac_out, m.name + "-notarize.zip")
    ignore(
      sh(
        "cd " + q(mac_out) + " && ditto -c -k --sequesterRsrc --keepParent " +
        q(m.name + ".app") + " " + q(notarize_zip),
        "ditto for notarize",
      ),
    )
    say("submitting for notarization (profile \{opts.notarize_profile})...")
    ignore(
      sh(
        "xcrun notarytool submit " + q(notarize_zip) +
        " --keychain-profile " + q(opts.notarize_profile) + " --wait",
        "notarytool submit",
      ),
    )
    ignore(sh("xcrun stapler staple " + q(app_dir), "stapler staple"))
    ignore(@sys.remove(notarize_zip))
  }

  let formats = if opts.formats.length() > 0 { opts.formats } else { m.macos.formats }
  for fmt in formats {
    match fmt {
      "app" => say("macOS app bundle: \{app_dir}")
      "zip" => {
        let zip_name = m.name + "-mac.zip"
        let zip_path = @sys.join(mac_out, zip_name)
        ignore(@sys.remove(zip_path))
        ignore(
          sh(
            "cd " + q(mac_out) + " && ditto -c -k --sequesterRsrc --keepParent " +
            q(m.name + ".app") + " " + q(zip_name),
            "ditto zip",
          ),
        )
        say("macOS zip: \{zip_path}")
      }
      "dmg" => {
        let dmg_path = @sys.join(mac_out, m.name + "-mac.dmg")
        let stage = @sys.join(mac_out, ".dmg-stage")
        ignore(sh("rm -rf " + q(stage) + " " + q(dmg_path), "clean dmg stage"))
        @sys.makedirs(stage)
        ignore(
          sh(
            "ditto " + q(app_dir) + " " + q(@sys.join(stage, m.name + ".app")) +
            " && ln -s /Applications " + q(@sys.join(stage, "Applications")),
            "prepare dmg stage",
          ),
        )
        ignore(
          sh(
            "hdiutil create -volname " + q(m.name) +
            " -srcfolder " + q(stage) +
            " -ov -format UDZO " + q(dmg_path),
            "hdiutil create",
          ),
        )
        ignore(sh("rm -rf " + q(stage), "remove dmg stage"))
        say("macOS dmg: \{dmg_path}")
      }
      _ => die("unknown macOS format '\{fmt}' (expected app, zip, or dmg)")
    }
  }
}
