// Shared packing options, target parsing, and Wasm/CWasm app & runtime shell pipeline.

///|
pub struct PackOptions {
  formats : Array[String]
  runtime_dir : String
  wasm_aot : Bool
  quick : Bool
  web_no_compress : Bool
  sign_identity : String
  keychain : String
  notarize_profile : String
  keystore : String
  key_alias : String
  ks_pass : String
  key_pass : String
  v3_signing : Bool
  verify_cert : String
  debuggable : Bool?
  win_cert : String
  win_cert_pass : String
  win_timestamp : String
  ios_sdk : String
  ios_profile : String
}

///|
pub fn PackOptions::default() -> PackOptions {
  {
    formats: [],
    runtime_dir: "",
    wasm_aot: false,
    quick: false,
    web_no_compress: false,
    sign_identity: "",
    keychain: "",
    notarize_profile: "",
    keystore: "",
    key_alias: "",
    ks_pass: "",
    key_pass: "",
    v3_signing: false,
    verify_cert: "",
    debuggable: None,
    win_cert: "",
    win_cert_pass: "",
    win_timestamp: "",
    ios_sdk: "iphonesimulator",
    ios_profile: "",
  }
}

///|
/// Parse a comma-separated `--target` list (valid targets: web, mac, win, linux, android, ios).
pub fn parse_targets(raw : String) -> Result[Array[String], String] {
  let out : Array[String] = []
  for part in raw.split(",") {
    let t = part.trim(chars=" \t\r\n").to_owned()
    if t.length() == 0 {
      continue
    }
    if t != "web" &&
      t != "mac" &&
      t != "win" &&
      t != "linux" &&
      t != "android" &&
      t != "ios" {
      return Err("unsupported target '\{t}' (supported: web, mac, win, linux, android, ios)")
    }
    if !out.contains(t) {
      out.push(t)
    }
  }
  if out.length() == 0 {
    return Err("no targets specified (supported: web, mac, win, linux, android, ios)")
  }
  Ok(out)
}

///|
/// Resolve the module prefix under `_build/<target>/<mode>/build/` when `moon.work` has multiple members.
fn resolve_mod_prefix(manifest_dir : String) -> String {
  let work_path = @sys.join(manifest_dir, "moon.work")
  let mod_path = @sys.join(manifest_dir, "moon.mod")
  match @sys.read_text(work_path) {
    Some(work_txt) => {
      let mut members = 0
      for raw in work_txt.split("\n") {
        let trimmed = raw.trim(chars=" \t\r").to_owned()
        if trimmed.has_prefix("\"") {
          members += 1
        }
      }
      if members > 1 {
        match @sys.read_text(mod_path) {
          Some(mod_txt) =>
            for raw in mod_txt.split("\n") {
              let line = raw.trim(chars=" \t\r").to_owned()
              if line.has_prefix("name") {
                match line.find("\"") {
                  Some(i1) =>
                    match line.rev_find("\"") {
                      Some(i2) if i2 > i1 =>
                        return line.exact_view(start=i1 + 1, end=i2).to_owned() + "/"
                      _ => ()
                    }
                  None => ()
                }
              }
            }
          None => ()
        }
      }
    }
    None => ()
  }
  ""
}

///|
/// Resolve the `.wasm` artifact produced by `moon build --target wasm` in `manifest_dir`.
fn find_wasm_output(manifest_dir : String, pkg : String, mode : String) -> String {
  let mod_prefix = resolve_mod_prefix(manifest_dir)
  let base_pkg = @sys.basename(pkg)
  let candidate = @sys.join(
    manifest_dir,
    "_build/wasm/\{mode}/build/\{mod_prefix}\{pkg}/\{base_pkg}.wasm",
  )
  if @sys.is_file(candidate) {
    return candidate
  }
  let fallback = @sys.join(
    manifest_dir,
    "_build/wasm/\{mode}/build/\{pkg}/\{base_pkg}.wasm",
  )
  if @sys.is_file(fallback) {
    return fallback
  }
  die("built Wasm binary not found at \{candidate}")
  ""
}

///|
/// Build the app's MoonBit entry package to classic Wasm (`--target wasm`) and copy to `<build_out>/wasm/`.
pub fn build_app_wasm(
  m : Manifest,
  manifest_dir : String,
  build_out : String,
  quick : Bool,
) -> String {
  let mod_dir = m.resolve_module_dir(manifest_dir)
  let pkg = m.entry_pkg()
  let mode = if quick { "debug" } else { "release" }
  let flag = if quick { "" } else { " --release" }
  let cmd = "cd " + q(mod_dir) + " && moon build --target wasm" + flag + " src/" + q(pkg)
  say("building Wasm app (\{pkg}, \{mode})...")
  ignore(sh(cmd, "moon build --target wasm"))
  let built = find_wasm_output(mod_dir, pkg, mode)
  let wasm_dir = @sys.join(build_out, "wasm")
  @sys.makedirs(wasm_dir)
  let dest = @sys.join(wasm_dir, @sys.basename(pkg) + ".wasm")
  ignore(sh("cp -p " + q(built) + " " + q(dest), "copy built wasm"))
  dest
}

///|
/// AOT-compile a `.wasm` binary to a target `.cwasm` using `libs/mbui/scripts/runtime.sh compile`.
pub fn compile_app_cwasm(
  mbui_dir : String,
  build_out : String,
  wasm_path : String,
  target_triple : String,
  out_cwasm : String,
  traps : String,
) -> String {
  let runtime_sh = @sys.join(mbui_dir, "scripts/runtime.sh")
  @sys.makedirs(@sys.dirname(out_cwasm))
  let cmd = "MBUI_OUT=" + q(build_out) +
    " bash " + q(runtime_sh) +
    " compile " + q(wasm_path) +
    " --target " + q(target_triple) +
    " --out " + q(out_cwasm) +
    " --traps " + q(traps)
  say("AOT-compiling Wasm for \{target_triple}...")
  ignore(sh(cmd, "runtime.sh compile"))
  if !@sys.is_file(out_cwasm) {
    die("expected AOT output not found: \{out_cwasm}")
  }
  out_cwasm
}

///|
/// Resolve the prebuilt runtime directory for `plat` (`mac|linux|win|android|ios`):
/// uses `<runtime_dir>/<plat>` if provided, otherwise builds and caches it via `scripts/runtime.sh build <plat>`.
pub fn resolve_runtime_dir(
  mbui_dir : String,
  build_out : String,
  runtime_dir : String,
  plat : String,
  extra_env? : String = "",
) -> String {
  if runtime_dir != "" {
    let abs = @sys.abspath(runtime_dir)
    let sub_dir = @sys.join(abs, plat)
    if @sys.is_dir(sub_dir) {
      return sub_dir
    }
    if @sys.is_dir(abs) {
      return abs
    }
    die("runtime directory not found: \{sub_dir}")
  }
  let runtime_sh = @sys.join(mbui_dir, "scripts/runtime.sh")
  let env_prefix = if extra_env != "" { extra_env + " " } else { "" }
  let cmd = env_prefix + "MBUI_OUT=" + q(build_out) +
    " bash " + q(runtime_sh) + " build " + q(plat)
  say("building prebuilt \{plat} Wasm runtime shell...")
  ignore(sh(cmd, "runtime.sh build \{plat}"))
  @sys.join(build_out, "runtime/" + plat)
}

///|
/// Build `.wasm` (and optionally `.cwasm` when `wasm_aot` is true), returning `(payload_path, ext)`.
pub fn prepare_wasm_payload(
  m : Manifest,
  manifest_dir : String,
  mbui_dir : String,
  build_out : String,
  wasm_aot : Bool,
  quick : Bool,
  target_triple : String,
  traps : String,
) -> (String, String) {
  let wasm_path = build_app_wasm(m, manifest_dir, build_out, quick)
  if wasm_aot {
    let out_cwasm = @sys.join(build_out, "wasm/app-" + target_triple + ".cwasm")
    let cwasm_path = compile_app_cwasm(
      mbui_dir,
      build_out,
      wasm_path,
      target_triple,
      out_cwasm,
      traps,
    )
    (cwasm_path, "cwasm")
  } else {
    (wasm_path, "wasm")
  }
}

///|
/// Sorted `(key, value)` pairs from `m.env` for deterministic code/template generation.
fn sorted_env_pairs(env : Map[String, String]) -> Array[(String, String)] {
  let keys : Array[String] = []
  env.each(fn(k, _) { keys.push(k) })
  keys.sort_by(fn(a, b) { @rjson.str_cmp(a, b) })
  keys.map(fn(k) { (k, env.get(k).unwrap_or("")) })
}

///|
/// Execute a lifecycle hook (`preBuild`, `postStage`, or `postPack`) in `manifest_dir`
/// with standard `MBUI_*` environment variables injected. No-op when `cmd` is empty.
pub fn run_hook(
  phase : String,
  cmd : String,
  m : Manifest,
  manifest_dir : String,
  mbui_dir : String,
  target : String,
  stage_dir : String,
  out_dir : String,
) -> Unit {
  if cmd.trim(chars=" \t\r\n").length() == 0 {
    return
  }
  let mod_dir = m.resolve_module_dir(manifest_dir)
  let env_prefix = "MBUI_HOOK_PHASE=" + q(phase) +
    " MBUI_TARGET=" + q(target) +
    " MBUI_RUNTIME=" + q(m.runtime) +
    " MBUI_VARIANT=" + q(m.variant) +
    " MBUI_APP_ID=" + q(m.app_id) +
    " MBUI_APP_NAME=" + q(m.name) +
    " MBUI_EXECUTABLE=" + q(m.executable) +
    " MBUI_VERSION=" + q(m.version) +
    " MBUI_BUILD=" + q(m.build.to_string()) +
    " MBUI_MANIFEST_DIR=" + q(manifest_dir) +
    " MBUI_MODULE_DIR=" + q(mod_dir) +
    " MBUI_STAGE_DIR=" + q(stage_dir) +
    " MBUI_OUT_DIR=" + q(out_dir) +
    " MBUI_DIR=" + q(mbui_dir)
  let full = "cd " + q(manifest_dir) + " && " + env_prefix + " sh -c " + q(cmd)
  say("running \{phase} hook (\{target})...")
  let out = sh(full, "hook \{phase} (\{target})")
  if out != "" {
    @sys.out(out)
  }
}
