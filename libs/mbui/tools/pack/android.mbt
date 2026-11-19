// Android target: declarative apk.json generation, Wasm/native APK packaging, and `mbui repack`.

///|
/// Generate a declarative `apk.json` consumable by `libs/mbui/scripts/apk build`.
pub fn render_apk_json(
  m : Manifest,
  manifest_dir : String,
  icons_res_dir : String,
  jni_dir : String,
  assets_dir : String,
) -> String {
  let kvs : Array[(String, @rjson.Value)] = [
    ("namespace", Str("dev.mbui.demo")),
    ("applicationId", Str(m.app_id)),
    ("minSdk", Num(m.android.min_sdk.to_string())),
    ("targetSdk", Num(m.android.target_sdk.to_string())),
    ("compileSdk", Num(m.android.compile_sdk.to_string())),
    ("manifest", Str("@mbui")),
    ("label", Str(m.name)),
    ("edgeToEdge", Bool(m.android.edge_to_edge)),
  ]
  if m.android.ground != "" {
    kvs.push(("ground", Str(m.android.ground)))
  }
  if m.env.length() > 0 {
    let env_kvs = sorted_env_pairs(m.env).map(fn(kv) { (kv.0, @rjson.Value::Str(kv.1)) })
    kvs.push(("env", Obj(env_kvs)))
  }
  if m.url_schemes.length() > 0 {
    kvs.push(("urlSchemes", Arr(m.url_schemes.map(fn(s) { @rjson.Value::Str(s) }))))
  }
  if m.android.permissions.length() > 0 {
    kvs.push(("permissions", Arr(m.android.permissions.map(fn(s) { @rjson.Value::Str(s) }))))
  }
  let java_dirs = m.android.java.map(fn(p) { @rjson.Value::Str(@sys.join(manifest_dir, p)) })
  if java_dirs.length() > 0 {
    kvs.push(("java", Arr(java_dirs)))
  }
  let res_dirs : Array[@rjson.Value] = []
  if icons_res_dir != "" {
    res_dirs.push(Str(icons_res_dir))
  }
  for r in m.android.res {
    res_dirs.push(Str(@sys.join(manifest_dir, r)))
  }
  if res_dirs.length() > 0 {
    kvs.push(("res", Arr(res_dirs)))
  }
  if jni_dir != "" {
    kvs.push(("jniLibs", Arr([Str(jni_dir)])))
  }
  if assets_dir != "" {
    kvs.push(("assets", Arr([Str(assets_dir)])))
  }
  if m.android.rules.length() > 0 {
    kvs.push(("rules", Arr(m.android.rules.map(fn(r) { @rjson.Value::Str(@sys.join(manifest_dir, r)) }))))
  }
  if m.android.lock != "" {
    kvs.push(("lock", Str(@sys.join(manifest_dir, m.android.lock))))
  }
  if m.android.merged.length() > 0 {
    kvs.push(("merged", Arr(m.android.merged.map(fn(x) { @rjson.Value::Str(x) }))))
  }
  kvs.push(
    (
      "variants",
      Obj([
        ("debug", Obj([("minify", Bool(false)), ("debuggable", Bool(true))])),
        ("release", Obj([("minify", Bool(false)), ("debuggable", Bool(false))])),
      ]),
    ),
  )
  @rjson.dumps(Obj(kvs), indent=2, ensure_ascii=false) + "\n"
}

///|
/// Build CLI argument array for `libs/mbui/scripts/apk repack`.
pub fn build_repack_args(
  m : Manifest,
  in_apk : String,
  out_apk : String,
  opts : PackOptions,
) -> Array[String] {
  let args : Array[String] = [
    "repack",
    in_apk,
    "--out",
    out_apk,
    "--app-id",
    m.app_id,
    "--label",
    m.name,
    "--version-code",
    m.build.to_string(),
    "--version-name",
    m.version,
    "--edge-to-edge",
    if m.android.edge_to_edge { "true" } else { "false" },
  ]
  if m.android.ground != "" {
    args.push("--ground")
    args.push(m.android.ground)
  }
  if m.env.length() > 0 {
    let pairs = sorted_env_pairs(m.env).map(fn(kv) { "\{kv.0}=\{kv.1}" })
    args.push("--env")
    args.push(pairs.join(";"))
  }
  for scheme in m.url_schemes {
    args.push("--url-scheme")
    args.push(scheme)
  }
  for perm in m.android.permissions {
    args.push("--permission")
    args.push(perm)
  }
  if opts.keystore != "" {
    args.push("--keystore")
    args.push(opts.keystore)
  }
  if opts.key_alias != "" {
    args.push("--key-alias")
    args.push(opts.key_alias)
  }
  if opts.ks_pass != "" {
    args.push("--ks-pass")
    args.push(opts.ks_pass)
  }
  if opts.key_pass != "" {
    args.push("--key-pass")
    args.push(opts.key_pass)
  }
  if opts.v3_signing {
    args.push("--v3-signing")
  }
  if opts.verify_cert != "" {
    args.push("--verify-cert")
    args.push(opts.verify_cert)
  }
  match opts.debuggable {
    Some(b) => {
      args.push("--debuggable")
      args.push(if b { "true" } else { "false" })
    }
    None => ()
  }
  args
}

///|
fn android_abi_triple(abi : String) -> String {
  match abi {
    "x86_64" => "x86_64-linux-android"
    _ => "aarch64-linux-android"
  }
}

///|
/// Invoke `libs/mbui/scripts/apk repack` with all manifest metadata and signing flags.
pub fn repack_android(
  m : Manifest,
  mbui_dir : String,
  in_apk : String,
  out_apk : String,
  opts : PackOptions,
) -> Unit {
  let abs_in = @sys.abspath(in_apk)
  if !@sys.is_file(abs_in) {
    die("repack: input APK not found: \{abs_in}")
  }
  let abs_out = @sys.abspath(out_apk)
  @sys.makedirs(@sys.dirname(abs_out))
  let apk_script = @sys.join(mbui_dir, "scripts/apk")
  let args = build_repack_args(m, abs_in, abs_out, opts)
  let quoted = args.map(q).join(" ")
  say("repacking Android APK -> \{abs_out}...")
  ignore(sh("sh " + q(apk_script) + " " + quoted, "apk repack"))
  say("Android APK ready: \{abs_out}")
}

///|
pub fn pack_android(
  m : Manifest,
  manifest_dir : String,
  mbui_dir : String,
  out_dir : String,
  opts : PackOptions,
) -> Unit {
  let and_out = @sys.join(out_dir, "android")
  let build_out = @sys.join(out_dir, ".build")
  @sys.makedirs(and_out)
  @sys.makedirs(build_out)

  let mod_dir = m.resolve_module_dir(manifest_dir)
  run_hook("preBuild", m.hooks.pre_build, m, manifest_dir, mbui_dir, "android", build_out, and_out)

  // Generate Android mipmap icons into <build_out>/android-res
  let icons_res = @sys.join(build_out, "android-res")
  if m.icon != "" {
    let icon_path = @sys.join(manifest_dir, m.icon)
    match @png.read(icon_path) {
      Ok(src) => {
        let buckets : Array[(String, Int)] = [
          ("mdpi", 48),
          ("hdpi", 72),
          ("xhdpi", 96),
          ("xxhdpi", 144),
          ("xxxhdpi", 192),
        ]
        for b in buckets {
          let dest = @sys.join(icons_res, "mipmap-\{b.0}/ic_launcher.png")
          match write_file_bytes(dest, @png.encode_png(src.resize(b.1, b.1))) {
            Ok(_) => ()
            Err(e) => die(e)
          }
        }
      }
      Err(e) => die("icon: \{e}")
    }
  }

  let abis = if m.android.abis.length() > 0 { m.android.abis } else { ["arm64-v8a"] }
  let repack_opts : PackOptions = {
    ..opts,
    debuggable: match opts.debuggable {
      Some(b) => Some(b)
      None => Some(opts.quick)
    },
  }

  for abi in abis {
    let final_apk = @sys.join(and_out, "\{m.name}-\{abi}.apk")
    if m.runtime == "wasm" {
      let triple = android_abi_triple(abi)
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
      let rt_dir = resolve_runtime_dir(
        mbui_dir,
        build_out,
        opts.runtime_dir,
        "android",
        extra_env="ABI=" + q(abi),
      )
      let rt_apk = @sys.join(rt_dir, "mbui-runtime-\{abi}.apk")
      if !@sys.is_file(rt_apk) {
        die("Android Wasm runtime APK not found: \{rt_apk}")
      }
      let inject_dir = @sys.join(build_out, "android-wasm-" + abi)
      ignore(sh("rm -rf " + q(inject_dir), "clean android wasm stage"))
      let assets_dir = @sys.join(inject_dir, "assets")
      @sys.makedirs(assets_dir)
      let staged_apk = @sys.join(inject_dir, "injected.apk")
      ignore(sh("cp -p " + q(rt_apk) + " " + q(staged_apk), "copy runtime apk"))
      ignore(
        sh(
          "cp -p " + q(payload_path) + " " + q(@sys.join(assets_dir, "app." + ext)),
          "copy app." + ext,
        ),
      )
      for res in m.resources {
        let src_res = @sys.join(manifest_dir, res)
        if !@sys.exists(src_res) {
          die("resource not found: \{src_res}")
        }
        ignore(
          sh(
            "cp -R " + q(src_res) + " " + q(@sys.join(assets_dir, @sys.basename(res))),
            "copy android resource",
          ),
        )
      }
      run_hook("postStage", m.hooks.post_stage, m, manifest_dir, mbui_dir, "android", inject_dir, and_out)
      ignore(
        sh(
          "cd " + q(inject_dir) + " && zip -q -0 -r " + q(staged_apk) + " assets",
          "inject wasm assets into apk",
        ),
      )
      repack_android(m, mbui_dir, staged_apk, final_apk, repack_opts)
    } else {
      let pkg = m.entry_pkg()
      let and_sh = @sys.join(mbui_dir, "scripts/android.sh")
      let quick_flag = if opts.quick { "1" } else { "0" }
      let build_cmd = "MBUI_APP_MOD=" + q(mod_dir) +
        " MBUI_OUT=" + q(build_out) +
        " APP=" + q(pkg) +
        " ABI=" + q(abi) +
        " VARIANT=debug" +
        " MBUI_QUICK=" + quick_flag +
        " MBUI_BUILD=" + q(m.build.to_string()) +
        " MBUI_APP_ID=" + q(m.app_id) +
        " bash " + q(and_sh) + " build"
      say("building Android native APK (\{pkg}, \{abi})...")
      ignore(sh(build_cmd, "android.sh build"))
      let built_apk = @sys.join(mbui_dir, "android/app/build/outputs/apk/debug/app-debug.apk")
      if !@sys.is_file(built_apk) {
        die("built Android APK not found at \{built_apk}")
      }
      run_hook("postStage", m.hooks.post_stage, m, manifest_dir, mbui_dir, "android", @sys.dirname(built_apk), and_out)
      repack_android(m, mbui_dir, built_apk, final_apk, repack_opts)
    }
  }

  run_hook("postPack", m.hooks.post_pack, m, manifest_dir, mbui_dir, "android", and_out, and_out)
}
