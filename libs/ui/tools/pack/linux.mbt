// Linux target: install.sh/.desktop/DEBIAN/control rendering, tar.gz, deb, and AppImage packaging.

///|
fn is_placeholder_char(c : Char) -> Bool {
  (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

///|
/// Return the first remaining `@PLACEHOLDER@` token if any, otherwise `None`.
fn find_unreplaced_placeholder(text : String) -> String? {
  let cs = text.to_array()
  let mut i = 0
  while i < cs.length() {
    if cs[i] == '@' {
      let mut j = i + 1
      while j < cs.length() && is_placeholder_char(cs[j]) {
        j += 1
      }
      if j > i + 1 && j < cs.length() && cs[j] == '@' {
        return Some(String::from_array(cs[i:j + 1]))
      }
    }
    i += 1
  }
  None
}

///|
fn format_linux_categories(cats : Array[String]) -> String {
  let filtered = cats
    .map(fn(s) { s.trim(chars=" \t;").to_owned() })
    .filter(fn(s) { s.length() > 0 })
  if filtered.length() == 0 {
    "Utility;"
  } else {
    filtered.join(";") + ";"
  }
}

///|
fn format_linux_extra_env(m : Manifest) -> String {
  let parts : Array[String] = []
  for kv in sorted_env_pairs(m.env) {
    let k = kv.0
    let v = kv.1
    if v.contains(" ") || v.contains("\"") || v.contains("'") || v.contains("$") {
      let esc = v.replace_all(old="\\", new="\\\\").replace_all(old="\"", new="\\\"")
      parts.push("\"\{k}=\{esc}\"")
    } else {
      parts.push("\{k}=\{v}")
    }
  }
  parts.join(" ")
}

///|
fn format_linux_update_feed(feed : String, arch : String) -> String {
  if feed == "" {
    ""
  } else {
    feed.replace_all(old="{arch}", new=arch)
  }
}

///|
/// Render `libs/ui/pack/linux/install.sh.in` by substituting all 8 placeholders
/// and verifying no unreplaced `@...@` placeholders remain.
pub fn render_linux_install_sh(tmpl : String, m : Manifest) -> Result[String, String] {
  let categories = format_linux_categories(m.linux.categories)
  let schemes = m.url_schemes.join(",")
  let feed_x64 = format_linux_update_feed(m.updater.feed, "x64")
  let feed_arm64 = format_linux_update_feed(m.updater.feed, "arm64")
  let extra_env = format_linux_extra_env(m)
  let out = tmpl
    .replace_all(old="@APP_ID@", new=m.app_id)
    .replace_all(old="@APP_NAME@", new=m.name)
    .replace_all(old="@EXE@", new=m.executable)
    .replace_all(old="@CATEGORIES@", new=categories)
    .replace_all(old="@SCHEMES@", new=schemes)
    .replace_all(old="@UPDATE_FEED_X64@", new=feed_x64)
    .replace_all(old="@UPDATE_FEED_ARM64@", new=feed_arm64)
    .replace_all(old="@EXTRA_ENV@", new=extra_env)
  match find_unreplaced_placeholder(out) {
    Some(tok) => Err("unreplaced placeholder in install.sh: \{tok}")
    None => Ok(out)
  }
}

///|
/// Render `libs/ui/pack/linux/desktop.in` by substituting all placeholders
/// and verifying no unreplaced `@...@` placeholders remain.
pub fn render_linux_desktop(
  tmpl : String,
  m : Manifest,
  exec_path? : String = "",
) -> Result[String, String] {
  let categories = format_linux_categories(m.linux.categories)
  let extra_env = format_linux_extra_env(m)
  let exe_val = if exec_path != "" { exec_path } else { "/opt/\{m.app_id}/\{m.executable}" }
  let mime_parts = m.url_schemes
    .map(fn(s) { s.trim(chars=" \t").to_owned() })
    .filter(fn(s) { s.length() > 0 })
    .map(fn(s) { "x-scheme-handler/\{s};" })
  let mime_types = mime_parts.join("")
  let mut out = tmpl
    .replace_all(old="@APP_ID@", new=m.app_id)
    .replace_all(old="@APP_NAME@", new=m.name)
    .replace_all(old="@EXE@", new=exe_val)
    .replace_all(old="@CATEGORIES@", new=categories)
    .replace_all(old="@EXTRA_ENV@", new=extra_env)
    .replace_all(old="@MIME_TYPES@", new=mime_types)
    .replace_all(old="@SCHEMES@", new=m.url_schemes.join(","))
    .replace_all(old="@UPDATE_FEED_X64@", new=format_linux_update_feed(m.updater.feed, "x64"))
    .replace_all(old="@UPDATE_FEED_ARM64@", new=format_linux_update_feed(m.updater.feed, "arm64"))
  if mime_types == "" {
    out = out.replace_all(old="MimeType=\n", new="")
    if out.has_suffix("MimeType=") {
      out = sub(out, 0, out.length() - 9)
    }
  }
  // Collapse double spaces when EXTRA_ENV is empty
  out = out.replace_all(old="  \"", new=" \"")
  match find_unreplaced_placeholder(out) {
    Some(tok) => Err("unreplaced placeholder in .desktop: \{tok}")
    None => Ok(out)
  }
}

///|
fn deb_package_name(app_id : String) -> String {
  let sb = StringBuilder()
  for c in app_id {
    if c >= 'a' && c <= 'z' {
      sb.write_char(c)
    } else if c >= 'A' && c <= 'Z' {
      sb.write_char(Int::unsafe_to_char(c.to_int() + 32))
    } else if (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.' {
      sb.write_char(c)
    } else {
      sb.write_char('-')
    }
  }
  let s = sb.to_string().trim(chars="-.").to_owned()
  if s.length() < 2 {
    "mbui-app"
  } else {
    s
  }
}

///|
/// Render a Debian `DEBIAN/control` metadata file.
pub fn render_deb_control(m : Manifest, arch : String, installed_kb : Int) -> String {
  let pkg_name = deb_package_name(m.app_id)
  let deb_arch = match arch {
    "x64" | "x86_64" | "amd64" => "amd64"
    "arm64" | "aarch64" => "arm64"
    _ => arch
  }
  let maint = if m.windows.company != "" { m.windows.company } else { m.name }
  let kb = if installed_kb > 0 { installed_kb } else { 1 }
  let sb = StringBuilder()
  sb.write_string("Package: \{pkg_name}\n")
  sb.write_string("Version: \{m.version}-\{m.build}\n")
  sb.write_string("Section: utils\n")
  sb.write_string("Priority: optional\n")
  sb.write_string("Architecture: \{deb_arch}\n")
  sb.write_string("Installed-Size: \{kb}\n")
  sb.write_string("Maintainer: \{maint}\n")
  sb.write_string("Description: \{m.name}\n")
  sb.write_string(" \{m.name} desktop application packaged by mbui.\n")
  sb.to_string()
}

///|
fn detect_linux_arch(rt_dir : String) -> (String, String) {
  if rt_dir != "" {
    let meta_path = @sys.join(rt_dir, "runtime.json")
    match @sys.read_text(meta_path) {
      Some(txt) =>
        try {
          let j = @rjson.parse(txt)
          match j.get("arch") {
            Some(Str("aarch64")) | Some(Str("arm64")) =>
              return ("arm64", "aarch64-unknown-linux-gnu")
            Some(Str("x86_64")) | Some(Str("amd64")) | Some(Str("x64")) =>
              return ("x64", "x86_64-unknown-linux-gnu")
            _ => ()
          }
        } catch {
          _ => ()
        }
      None => ()
    }
  }
  let host = try_sh("uname -m").unwrap_or("x86_64").trim(chars=" \t\r\n").to_owned()
  if host == "aarch64" || host == "arm64" {
    ("arm64", "aarch64-unknown-linux-gnu")
  } else {
    ("x64", "x86_64-unknown-linux-gnu")
  }
}

///|
fn find_linux_native_exe(build_out : String, manifest_dir : String, pkg : String, mode : String) -> String {
  let mod_prefix = resolve_mod_prefix(manifest_dir)
  let base_pkg = @sys.basename(pkg)
  let c1 = @sys.join(build_out, "linux/app/_build/native/\{mode}/build/\{mod_prefix}\{pkg}/\{base_pkg}.exe")
  if @sys.is_file(c1) {
    return c1
  }
  let c2 = @sys.join(build_out, "linux/app/_build/native/\{mode}/build/\{pkg}/\{base_pkg}.exe")
  if @sys.is_file(c2) {
    return c2
  }
  die("built Linux binary not found at \{c1}")
  ""
}

///|
pub fn pack_linux(
  m : Manifest,
  manifest_dir : String,
  mbui_dir : String,
  out_dir : String,
  opts : PackOptions,
) -> Unit {
  let lin_out = @sys.join(out_dir, "linux")
  let build_out = @sys.join(out_dir, ".build")
  let stage = @sys.join(build_out, "linux-stage")
  @sys.makedirs(lin_out)
  @sys.makedirs(build_out)
  ignore(sh("rm -rf " + q(stage), "clean linux stage"))
  @sys.makedirs(stage)

  let mod_dir = m.resolve_module_dir(manifest_dir)
  run_hook("preBuild", m.hooks.pre_build, m, manifest_dir, mbui_dir, "linux", stage, lin_out)

  let exe_dst = @sys.join(stage, m.executable)
  let mut arch = "x64"

  if m.runtime == "wasm" {
    let rt_dir = resolve_runtime_dir(mbui_dir, build_out, opts.runtime_dir, "linux")
    let (a, triple) = detect_linux_arch(rt_dir)
    arch = a
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
    let rt_bin = @sys.join(rt_dir, "mbui-runtime")
    let rt_so = @sys.join(rt_dir, "libwasmtime.so")
    if !@sys.is_file(rt_bin) {
      die("Linux Wasm runtime binary not found: \{rt_bin}")
    }
    if !@sys.is_file(rt_so) {
      die("Linux Wasm runtime library not found: \{rt_so}")
    }
    ignore(
      sh(
        "cp -p " + q(rt_bin) + " " + q(exe_dst) + " && chmod +x " + q(exe_dst),
        "copy linux wasm runtime",
      ),
    )
    ignore(
      sh(
        "cp -p " + q(rt_so) + " " + q(@sys.join(stage, "libwasmtime.so")),
        "copy libwasmtime.so",
      ),
    )
    ignore(
      sh(
        "cp -p " + q(payload_path) + " " + q(@sys.join(stage, "app." + ext)),
        "copy app." + ext,
      ),
    )
  } else {
    let (a, _) = detect_linux_arch("")
    arch = a
    let pkg = m.entry_pkg()
    let mode = if opts.quick { "debug" } else { "release" }
    let lin_sh = @sys.join(mbui_dir, "scripts/linux.sh")
    let build_cmd = "MBUI_APP_MOD=" + q(mod_dir) +
      " MBUI_OUT=" + q(build_out) +
      " APP=" + q(pkg) +
      " MODE=" + q(mode) +
      " bash " + q(lin_sh) + " build"
    say("building Linux binary (\{pkg}, \{mode})...")
    ignore(sh(build_cmd, "linux.sh build"))
    let exe_src = find_linux_native_exe(build_out, mod_dir, pkg, mode)
    ignore(
      sh(
        "cp -p " + q(exe_src) + " " + q(exe_dst) + " && chmod +x " + q(exe_dst),
        "copy linux binary",
      ),
    )
  }

  // Icon (512x512 PNG for install.sh + hicolor)
  let mut has_icon = false
  let icon_dst = @sys.join(stage, "icon.png")
  if m.icon != "" {
    let icon_path = @sys.join(manifest_dir, m.icon)
    match @png.read(icon_path) {
      Ok(src) =>
        match write_file_bytes(icon_dst, @png.encode_png(src.resize(512, 512))) {
          Ok(_) => has_icon = true
          Err(e) => die(e)
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
    let dst_res = @sys.join(stage, @sys.basename(res))
    ignore(sh("cp -R " + q(src_res) + " " + q(dst_res), "copy resource"))
  }

  // VERSION file (for linux_update.h)
  match write_file_text(@sys.join(stage, "VERSION"), m.version + "\n") {
    Ok(_) => ()
    Err(e) => die(e)
  }

  // Render install.sh from template
  let install_tmpl_path = @sys.join(mbui_dir, "pack/linux/install.sh.in")
  let install_tmpl = match @sys.read_text(install_tmpl_path) {
    Some(t) => t
    None => {
      die("cannot read Linux install template: \{install_tmpl_path}")
      ""
    }
  }
  let install_sh_text = match render_linux_install_sh(install_tmpl, m) {
    Ok(s) => s
    Err(e) => {
      die(e)
      ""
    }
  }
  let install_dst = @sys.join(stage, "install.sh")
  match write_file_text(install_dst, install_sh_text) {
    Ok(_) => ()
    Err(e) => die(e)
  }
  ignore(sh("chmod +x " + q(install_dst), "chmod +x install.sh"))

  run_hook("postStage", m.hooks.post_stage, m, manifest_dir, mbui_dir, "linux", stage, lin_out)

  let desktop_tmpl_path = @sys.join(mbui_dir, "pack/linux/desktop.in")
  let desktop_tmpl = @sys.read_text(desktop_tmpl_path).unwrap_or("")

  let formats = if opts.formats.length() > 0 { opts.formats } else { m.linux.formats }
  for fmt in formats {
    match fmt {
      "tar.gz" => {
        let tar_path = @sys.join(lin_out, "\{m.name}-linux-\{arch}.tar.gz")
        ignore(@sys.remove(tar_path))
        ignore(
          sh(
            "tar -czf " + q(tar_path) + " -C " + q(stage) + " .",
            "tar.gz linux",
          ),
        )
        say("Linux tar.gz: \{tar_path}")
      }
      "deb" => {
        let deb_root = @sys.join(build_out, "deb-stage")
        ignore(sh("rm -rf " + q(deb_root), "clean deb stage"))
        let opt_dir = @sys.join(deb_root, "opt/" + m.app_id)
        let apps_dir = @sys.join(deb_root, "usr/share/applications")
        let icons_dir = @sys.join(deb_root, "usr/share/icons/hicolor/512x512/apps")
        let debian_dir = @sys.join(deb_root, "DEBIAN")
        @sys.makedirs(opt_dir)
        @sys.makedirs(apps_dir)
        @sys.makedirs(icons_dir)
        @sys.makedirs(debian_dir)
        ignore(sh("cp -R " + q(stage) + "/. " + q(opt_dir) + "/", "copy deb payload"))
        ignore(@sys.remove(@sys.join(opt_dir, "install.sh")))
        if has_icon {
          ignore(
            sh(
              "cp -p " + q(icon_dst) + " " + q(@sys.join(icons_dir, m.app_id + ".png")),
              "copy deb icon",
            ),
          )
        }
        if desktop_tmpl != "" {
          match render_linux_desktop(desktop_tmpl, m, exec_path="/opt/\{m.app_id}/\{m.executable}") {
            Ok(dt) =>
              match write_file_text(@sys.join(apps_dir, m.app_id + ".desktop"), dt) {
                Ok(_) => ()
                Err(e) => die(e)
              }
            Err(e) => die(e)
          }
        }
        let du_out = try_sh("du -sk " + q(opt_dir)).unwrap_or("1024")
        let kb = match du_out.split("\t").next() {
          Some(s) => parse_int_str(s.trim(chars=" \t\r\n").to_owned()).unwrap_or(1024)
          None => 1024
        }
        match write_file_text(@sys.join(debian_dir, "control"), render_deb_control(m, arch, kb)) {
          Ok(_) => ()
          Err(e) => die(e)
        }
        if try_sh("command -v dpkg-deb") is Some(_) {
          let deb_path = @sys.join(lin_out, "\{m.name}-linux-\{arch}.deb")
          ignore(sh("dpkg-deb --build " + q(deb_root) + " " + q(deb_path), "dpkg-deb"))
          say("Linux deb: \{deb_path}")
        } else {
          let staged_out = @sys.join(lin_out, "\{m.name}-linux-\{arch}.deb-stage")
          ignore(sh("rm -rf " + q(staged_out) + " && cp -R " + q(deb_root) + " " + q(staged_out), "copy deb stage"))
          say("dpkg-deb not found on host; staged Debian tree at \{staged_out}")
        }
      }
      "appimage" => {
        let appdir = @sys.join(build_out, m.name + ".AppDir")
        ignore(sh("rm -rf " + q(appdir), "clean AppDir"))
        let usr_bin = @sys.join(appdir, "usr/bin")
        @sys.makedirs(usr_bin)
        ignore(sh("cp -R " + q(stage) + "/. " + q(usr_bin) + "/", "copy AppDir payload"))
        ignore(@sys.remove(@sys.join(usr_bin, "install.sh")))
        let apprun = "#!/bin/sh\nHERE=$(cd \"$(dirname \"$0\")\" && pwd)\nexec \"$HERE/usr/bin/\{m.executable}\" \"$@\"\n"
        let apprun_path = @sys.join(appdir, "AppRun")
        match write_file_text(apprun_path, apprun) {
          Ok(_) => ()
          Err(e) => die(e)
        }
        ignore(sh("chmod +x " + q(apprun_path), "chmod AppRun"))
        if has_icon {
          ignore(
            sh(
              "cp -p " + q(icon_dst) + " " + q(@sys.join(appdir, m.app_id + ".png")),
              "copy AppDir icon",
            ),
          )
        }
        if desktop_tmpl != "" {
          match render_linux_desktop(desktop_tmpl, m, exec_path=m.executable) {
            Ok(dt) =>
              match write_file_text(@sys.join(appdir, m.app_id + ".desktop"), dt) {
                Ok(_) => ()
                Err(e) => die(e)
              }
            Err(e) => die(e)
          }
        }
        if try_sh("command -v appimagetool") is Some(_) {
          let ai_path = @sys.join(lin_out, "\{m.name}-linux-\{arch}.AppImage")
          ignore(sh("appimagetool " + q(appdir) + " " + q(ai_path), "appimagetool"))
          say("Linux AppImage: \{ai_path}")
        } else {
          let staged_ai = @sys.join(lin_out, "\{m.name}-linux-\{arch}.AppDir")
          ignore(sh("rm -rf " + q(staged_ai) + " && cp -R " + q(appdir) + " " + q(staged_ai), "copy AppDir"))
          say("appimagetool not found on host; staged AppDir at \{staged_ai}")
        }
      }
      _ => die("unknown Linux format '\{fmt}' (expected tar.gz, deb, or appimage)")
    }
  }

  run_hook("postPack", m.hooks.post_pack, m, manifest_dir, mbui_dir, "linux", stage, lin_out)
}
