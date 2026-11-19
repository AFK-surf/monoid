// Windows target: VERSIONINFO .rc, app.env, setup.env generation, portable .zip and setup.exe packaging.

///|
fn clamp_u16(n : Int) -> Int {
  if n < 0 {
    0
  } else if n > 65535 {
    65535
  } else {
    n
  }
}

///|
/// Parse a semver string (`1.2.3`, `1.2.3-beta.1`, `2.0`) + build number into a Windows 4-tuple.
pub fn parse_win_version_quad(version : String, build : Int) -> (Int, Int, Int, Int) {
  let mut core = version.trim(chars=" \t\r\n").to_owned()
  match core.find("-") {
    Some(i) => core = sub(core, 0, i)
    None => ()
  }
  match core.find("+") {
    Some(i) => core = sub(core, 0, i)
    None => ()
  }
  let parts = core.split(".").map(fn(s) { s.to_owned() }).to_array()
  let major = if parts.length() > 0 { parse_int_str(parts[0]).unwrap_or(0) } else { 0 }
  let minor = if parts.length() > 1 { parse_int_str(parts[1]).unwrap_or(0) } else { 0 }
  let patch = if parts.length() > 2 { parse_int_str(parts[2]).unwrap_or(0) } else { 0 }
  (clamp_u16(major), clamp_u16(minor), clamp_u16(patch), clamp_u16(build))
}

///|
fn escape_rc_string(s : String) -> String {
  let sb = StringBuilder()
  for c in s {
    match c {
      '\\' => sb.write_string("\\\\")
      '"' => sb.write_string("\"\"")
      '\n' | '\r' => sb.write_char(' ')
      _ => sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
/// Render `app.env` embedded as `MBUI_ENV RCDATA` on Windows.
pub fn render_win_env(m : Manifest) -> String {
  let sb = StringBuilder()
  sb.write_string("MBUI_APP_ID=\{m.app_id}\n")
  sb.write_string("MBUI_APP_NAME=\{m.name}\n")
  if m.url_schemes.length() > 0 {
    let schemes = m.url_schemes.join(",")
    sb.write_string("MBUI_SCHEMES=\{schemes}\n")
  }
  if m.updater.feed != "" {
    sb.write_string("MBUI_UPDATE_FEED=\{m.updater.feed}\n")
  }
  for kv in sorted_env_pairs(m.env) {
    sb.write_string("\{kv.0}=\{kv.1}\n")
  }
  sb.to_string()
}

///|
/// Render a Windows resource script (`app.rc`) with icon, `MBUI_ENV` RCDATA, and `VERSIONINFO`.
pub fn render_win_rc(m : Manifest, has_icon : Bool) -> String {
  let (v1, v2, v3, v4) = parse_win_version_quad(m.version, m.build)
  let company = escape_rc_string(if m.windows.company != "" { m.windows.company } else { m.name })
  let name = escape_rc_string(m.name)
  let exe = escape_rc_string(m.executable)
  let ver_str = escape_rc_string(m.version)
  let sb = StringBuilder()
  if has_icon {
    sb.write_string("1 ICON \"app.ico\"\n")
  }
  sb.write_string("MBUI_ENV RCDATA \"app.env\"\n\n")
  sb.write_string("1 VERSIONINFO\n")
  sb.write_string("FILEVERSION \{v1},\{v2},\{v3},\{v4}\n")
  sb.write_string("PRODUCTVERSION \{v1},\{v2},\{v3},\{v4}\n")
  sb.write_string("FILEFLAGSMASK 0x3fL\n")
  sb.write_string("FILEFLAGS 0x0L\n")
  sb.write_string("FILEOS 0x40004L\n")
  sb.write_string("FILETYPE 0x1L\n")
  sb.write_string("FILESUBTYPE 0x0L\n")
  sb.write_string("BEGIN\n")
  sb.write_string("  BLOCK \"StringFileInfo\"\n")
  sb.write_string("  BEGIN\n")
  sb.write_string("    BLOCK \"040904B0\"\n")
  sb.write_string("    BEGIN\n")
  sb.write_string("      VALUE \"CompanyName\", \"\{company}\\0\"\n")
  sb.write_string("      VALUE \"FileDescription\", \"\{name}\\0\"\n")
  sb.write_string("      VALUE \"FileVersion\", \"\{v1}.\{v2}.\{v3}.\{v4}\\0\"\n")
  sb.write_string("      VALUE \"InternalName\", \"\{exe}\\0\"\n")
  sb.write_string("      VALUE \"OriginalFilename\", \"\{exe}.exe\\0\"\n")
  sb.write_string("      VALUE \"ProductName\", \"\{name}\\0\"\n")
  sb.write_string("      VALUE \"ProductVersion\", \"\{ver_str}\\0\"\n")
  sb.write_string("    END\n")
  sb.write_string("  END\n")
  sb.write_string("  BLOCK \"VarFileInfo\"\n")
  sb.write_string("  BEGIN\n")
  sb.write_string("    VALUE \"Translation\", 0x0409, 1200\n")
  sb.write_string("  END\n")
  sb.write_string("END\n")
  sb.to_string()
}

///|
/// Render `setup.env` consumed by `libs/mbui/pack/windows/setup.c`.
pub fn render_setup_env(m : Manifest) -> String {
  let dir_name = if m.windows.install_dir != "" { m.windows.install_dir } else { m.executable }
  let sb = StringBuilder()
  sb.write_string("APP_NAME=\{m.name}\n")
  sb.write_string("APP_ID=\{m.app_id}\n")
  sb.write_string("EXE=\{m.executable}.exe\n")
  sb.write_string("DIR=\{dir_name}\n")
  sb.write_string("VERSION=\{m.version}\n")
  if m.windows.company != "" {
    sb.write_string("PUBLISHER=\{m.windows.company}\n")
  }
  if m.url_schemes.length() > 0 {
    let schemes = m.url_schemes.join(",")
    sb.write_string("SCHEMES=\{schemes}\n")
  }
  sb.to_string()
}

///|
fn sign_win_file(path : String, opts : PackOptions) -> Unit {
  if opts.win_cert == "" {
    return
  }
  let mut cmd = "signtool.exe sign /fd sha256 /f " + q(opts.win_cert)
  if opts.win_cert_pass != "" {
    cmd = cmd + " /p " + q(opts.win_cert_pass)
  }
  if opts.win_timestamp != "" {
    cmd = cmd + " /tr " + q(opts.win_timestamp) + " /td sha256"
  }
  cmd = cmd + " " + q(path)
  say("signing \{@sys.basename(path)} with signtool...")
  ignore(sh(cmd, "signtool sign"))
}

///|
fn find_win_native_exe(mbui_dir : String, manifest_dir : String, pkg : String, mode : String) -> String {
  let mod_name = resolve_mod_prefix(manifest_dir)
  let base_pkg = @sys.basename(pkg)
  let c1 = @sys.join(mbui_dir, "out/win/app/_build/native/\{mode}/build/\{mod_name}\{pkg}/\{base_pkg}.exe")
  if @sys.is_file(c1) {
    return c1
  }
  let c2 = @sys.join(mbui_dir, "out/win/app/_build/native/\{mode}/build/\{pkg}/\{base_pkg}.exe")
  if @sys.is_file(c2) {
    return c2
  }
  die("built Windows binary not found at \{c1}")
  ""
}

///|
pub fn pack_win(
  m : Manifest,
  manifest_dir : String,
  mbui_dir : String,
  out_dir : String,
  opts : PackOptions,
) -> Unit {
  let win_out = @sys.join(out_dir, "win")
  let build_out = @sys.join(out_dir, ".build")
  let stage = @sys.join(build_out, "win-stage")
  @sys.makedirs(win_out)
  @sys.makedirs(build_out)
  ignore(sh("rm -rf " + q(stage), "clean win stage"))
  @sys.makedirs(stage)

  // Generate app.ico if icon configured
  let mut has_icon = false
  let ico_path = @sys.join(stage, "app.ico")
  if m.icon != "" {
    let icon_path = @sys.join(manifest_dir, m.icon)
    match @png.read(icon_path) {
      Ok(src) => {
        let dims = [16, 24, 32, 48, 64, 128, 256]
        let pics = dims.map(fn(sz) { src.resize(sz, sz) })
        match write_file_bytes(ico_path, @png.encode_ico(pics)) {
          Ok(_) => has_icon = true
          Err(e) => die(e)
        }
      }
      Err(e) => die("icon: \{e}")
    }
  }

  let exe_name = m.executable + ".exe"
  let exe_dst = @sys.join(stage, exe_name)

  if m.runtime == "wasm" {
    let (payload_path, ext) = prepare_wasm_payload(
      m,
      manifest_dir,
      mbui_dir,
      build_out,
      opts.wasm_aot,
      opts.quick,
      "x86_64-pc-windows-msvc",
      "signals",
    )
    let rt_dir = resolve_runtime_dir(mbui_dir, build_out, opts.runtime_dir, "win")
    let rt_exe = @sys.join(rt_dir, "mbui-runtime.exe")
    let rt_dll = @sys.join(rt_dir, "wasmtime.dll")
    if !@sys.is_file(rt_exe) {
      die("Windows Wasm runtime binary not found: \{rt_exe}")
    }
    if !@sys.is_file(rt_dll) {
      die("Windows Wasm runtime library not found: \{rt_dll}")
    }
    ignore(sh("cp -p " + q(rt_exe) + " " + q(exe_dst), "copy mbui-runtime.exe"))
    ignore(
      sh(
        "cp -p " + q(rt_dll) + " " + q(@sys.join(stage, "wasmtime.dll")),
        "copy wasmtime.dll",
      ),
    )
    ignore(
      sh(
        "cp -p " + q(payload_path) + " " + q(@sys.join(stage, "app." + ext)),
        "copy app." + ext,
      ),
    )
    match write_file_text(@sys.join(stage, "app.env"), render_win_env(m)) {
      Ok(_) => ()
      Err(e) => die(e)
    }
  } else {
    let rc_dir = @sys.join(build_out, "win-rc")
    @sys.makedirs(rc_dir)
    if has_icon {
      ignore(sh("cp -p " + q(ico_path) + " " + q(@sys.join(rc_dir, "app.ico")), "copy ico for rc"))
    }
    match write_file_text(@sys.join(rc_dir, "app.env"), render_win_env(m)) {
      Ok(_) => ()
      Err(e) => die(e)
    }
    let rc_path = @sys.join(rc_dir, "app.rc")
    match write_file_text(rc_path, render_win_rc(m, has_icon)) {
      Ok(_) => ()
      Err(e) => die(e)
    }
    let res_path = @sys.join(rc_dir, "app.res")
    ignore(
      sh(
        "cd " + q(rc_dir) + " && rc.exe /nologo /fo " + q(res_path) + " " + q(rc_path),
        "rc.exe",
      ),
    )
    let pkg = m.entry_pkg()
    let mode = if opts.quick { "debug" } else { "release" }
    let win_sh = @sys.join(mbui_dir, "scripts/win.sh")
    let build_cmd = "MBUI_APP_MOD=" + q(manifest_dir) +
      " MBUI_WIN_RES=" + q(res_path) +
      " APP=" + q(pkg) +
      " MODE=" + q(mode) +
      " bash " + q(win_sh) + " build"
    say("building Windows binary (\{pkg}, \{mode})...")
    ignore(sh(build_cmd, "win.sh build"))
    let exe_src = find_win_native_exe(mbui_dir, manifest_dir, pkg, mode)
    ignore(sh("cp -p " + q(exe_src) + " " + q(exe_dst), "copy windows exe"))
  }

  // Copy resources into stage
  for res in m.resources {
    let src_res = @sys.join(manifest_dir, res)
    if !@sys.exists(src_res) {
      die("resource not found: \{src_res}")
    }
    let dst_res = @sys.join(stage, @sys.basename(res))
    ignore(sh("cp -R " + q(src_res) + " " + q(dst_res), "copy resource"))
  }

  sign_win_file(exe_dst, opts)

  let formats = if opts.formats.length() > 0 { opts.formats } else { m.windows.formats }
  for fmt in formats {
    match fmt {
      "portable" | "zip" => {
        let zip_path = @sys.join(win_out, m.name + "-win-x64.zip")
        ignore(@sys.remove(zip_path))
        ignore(
          sh(
            "cd " + q(stage) + " && zip -q -r " + q(zip_path) + " .",
            "zip windows portable",
          ),
        )
        say("Windows portable zip: \{zip_path}")
      }
      "setup" => {
        let setup_dir = @sys.join(build_out, "win-setup")
        @sys.makedirs(setup_dir)
        let setup_c = @sys.join(mbui_dir, "pack/windows/setup.c")
        if !@sys.is_file(setup_c) {
          die("Windows installer source not found: \{setup_c}")
        }
        let setup_env_path = @sys.join(setup_dir, "setup.env")
        match write_file_text(setup_env_path, render_setup_env(m)) {
          Ok(_) => ()
          Err(e) => die(e)
        }
        let mut res_obj = ""
        if has_icon {
          ignore(
            sh(
              "cp -p " + q(ico_path) + " " + q(@sys.join(setup_dir, "app.ico")),
              "copy setup ico",
            ),
          )
          let setup_rc = @sys.join(setup_dir, "setup.rc")
          match write_file_text(setup_rc, "1 ICON \"app.ico\"\n") {
            Ok(_) => ()
            Err(e) => die(e)
          }
          let setup_res = @sys.join(setup_dir, "setup.res")
          ignore(
            sh(
              "cd " + q(setup_dir) + " && rc.exe /nologo /fo " + q(setup_res) + " " + q(setup_rc),
              "rc.exe setup",
            ),
          )
          res_obj = " " + q(setup_res)
        }
        let bare_exe = @sys.join(setup_dir, "setup-bare.exe")
        ignore(
          sh(
            "cd " + q(setup_dir) + " && cl.exe -nologo -O2 -utf-8 -W0 " + q(setup_c) + res_obj +
            " -Fe:" + q(bare_exe),
            "cl.exe setup.c",
          ),
        )
        let stage_files : Array[String] = []
        for entry in @sys.list_dir(stage) {
          let p = @sys.join(stage, entry)
          if @sys.is_file(p) {
            stage_files.push(q(p))
          }
        }
        let setup_out = @sys.join(win_out, m.name + "-setup.exe")
        let files_arg = stage_files.join(" ")
        ignore(
          sh(
            q(bare_exe) + " --pack " + q(setup_out) + " " + q(setup_env_path) + " " + files_arg,
            "setup-bare --pack",
          ),
        )
        sign_win_file(setup_out, opts)
        say("Windows installer: \{setup_out}")
        if m.windows.raw_for_delta {
          let raw_out = @sys.join(win_out, m.name + "-setup-raw.exe")
          ignore(sh(q(setup_out) + " --raw " + q(raw_out), "setup --raw"))
          say("Windows raw installer (delta base): \{raw_out}")
        }
      }
      _ => die("unknown Windows format '\{fmt}' (expected portable, zip, or setup)")
    }
  }
}
