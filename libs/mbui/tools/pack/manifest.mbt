// Manifest schema (mbui.json), variant deep-merging, CLI overrides, and validation.

///|
pub struct MacConfig {
  min_version : String
  category : String
  entitlements : String
  info_plist : Array[(String, @rjson.Value)]
  formats : Array[String]
}

///|
pub struct WinConfig {
  company : String
  install_dir : String
  formats : Array[String]
  raw_for_delta : Bool
}

///|
pub struct LinuxConfig {
  categories : Array[String]
  formats : Array[String]
}

///|
pub struct AndroidConfig {
  min_sdk : Int
  target_sdk : Int
  compile_sdk : Int
  abis : Array[String]
  edge_to_edge : Bool
  ground : String
  permissions : Array[String]
  java : Array[String]
  res : Array[String]
  rules : Array[String]
  lock : String
  merged : Array[String]
}

///|
pub struct IosConfig {
  min_version : String
  edge_to_edge : Bool
  ground : String
  share_extension : Bool
  push : Bool
  usage_descriptions : Array[(String, String)]
  entitlements : String
}

///|
pub struct WebConfig {
  title : String
  theme_color_light : String
  theme_color_dark : String
  brotli : Bool
  pwa : Bool
  head : String
}

///|
pub struct UpdaterConfig {
  feed : String
  channel : String
  public_key : String
}

///|
pub struct Manifest {
  app_id : String
  name : String
  executable : String
  version : String
  build : Int
  entry : String
  icon : String
  icon_dark : String
  url_schemes : Array[String]
  env : Map[String, String]
  resources : Array[String]
  runtime : String
  macos : MacConfig
  windows : WinConfig
  linux : LinuxConfig
  android : AndroidConfig
  ios : IosConfig
  web : WebConfig
  updater : UpdaterConfig
  variant : String
}

///|
pub struct CliOverrides {
  variant : String?
  version : String?
  build : Int?
  app_id : String?
}

///|
pub fn CliOverrides::empty() -> CliOverrides {
  { variant: None, version: None, build: None, app_id: None }
}

///|
fn is_ascii_alpha(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
fn is_ascii_alnum(c : Char) -> Bool {
  is_ascii_alpha(c) || (c >= '0' && c <= '9')
}

///|
/// Validate reverse-DNS appId (e.g. `dev.example.demo`): at least 2 dot-separated
/// non-empty segments, each starting with an ASCII letter and containing only
/// ASCII letters, digits, `_` or `-`.
pub fn is_valid_app_id(id : String) -> Bool {
  if id.length() == 0 {
    return false
  }
  let segs = id.split(".").map(fn(s) { s.to_owned() }).to_array()
  if segs.length() < 2 {
    return false
  }
  for seg in segs {
    let cs = seg.to_array()
    if cs.length() == 0 || !is_ascii_alpha(cs[0]) {
      return false
    }
    for c in cs {
      if !is_ascii_alnum(c) && c != '_' && c != '-' {
        return false
      }
    }
  }
  true
}

///|
/// Derive a safe executable filename from `name`.
pub fn derive_executable(name : String) -> String {
  let sb = StringBuilder()
  let mut prev_dash = false
  for c in name {
    if is_ascii_alnum(c) || c == '_' || c == '.' {
      sb.write_char(c)
      prev_dash = false
    } else if c == '-' || c == ' ' {
      if sb.to_string().length() > 0 && !prev_dash {
        sb.write_char('-')
        prev_dash = true
      }
    }
  }
  let s = sb.to_string().trim(chars="-.").to_owned()
  if s.length() == 0 {
    "app"
  } else {
    s
  }
}

///|
/// Deep-merge `over` onto `base`: objects merge recursively by key; all other values replace.
fn merge_json(base : @rjson.Value, over : @rjson.Value) -> @rjson.Value {
  match (base, over) {
    (Obj(bkvs), Obj(okvs)) => {
      let out = bkvs.copy()
      for kv in okvs {
        let mut found = false
        for i, existing in out {
          if existing.0 == kv.0 {
            out[i] = (kv.0, merge_json(existing.1, kv.1))
            found = true
            break
          }
        }
        if !found {
          out.push(kv)
        }
      }
      Obj(out)
    }
    _ => over
  }
}

///|
fn parse_int_str(s : String) -> Int? {
  let cs = s.to_array()
  if cs.length() == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if cs[0] == '-' {
    neg = true
    i = 1
  }
  if i >= cs.length() {
    return None
  }
  let mut v = 0
  while i < cs.length() {
    let c = cs[i]
    if c < '0' || c > '9' {
      return None
    }
    v = v * 10 + (c.to_int() - '0'.to_int())
    i += 1
  }
  Some(if neg { -v } else { v })
}

///|
fn opt_str(obj : @rjson.Value, key : String, default : String) -> Result[String, String] {
  match obj.get(key) {
    None | Some(Null) => Ok(default)
    Some(Str(s)) => Ok(s)
    Some(_) => Err("field '\{key}' must be a string")
  }
}

///|
fn opt_bool(obj : @rjson.Value, key : String, default : Bool) -> Result[Bool, String] {
  match obj.get(key) {
    None | Some(Null) => Ok(default)
    Some(Bool(b)) => Ok(b)
    Some(_) => Err("field '\{key}' must be a boolean")
  }
}

///|
fn opt_int(obj : @rjson.Value, key : String, default : Int) -> Result[Int, String] {
  match obj.get(key) {
    None | Some(Null) => Ok(default)
    Some(Num(n)) =>
      match parse_int_str(n) {
        Some(v) => Ok(v)
        None => Err("field '\{key}' must be an integer")
      }
    Some(_) => Err("field '\{key}' must be an integer")
  }
}

///|
fn opt_str_arr(obj : @rjson.Value, key : String, default : Array[String]) -> Result[Array[String], String] {
  match obj.get(key) {
    None | Some(Null) => Ok(default)
    Some(Arr(xs)) => {
      let out : Array[String] = []
      for x in xs {
        match x {
          Str(s) => out.push(s)
          _ => return Err("field '\{key}' must be an array of strings")
        }
      }
      Ok(out)
    }
    Some(_) => Err("field '\{key}' must be an array of strings")
  }
}

///|
fn opt_str_map(obj : @rjson.Value, key : String) -> Result[Map[String, String], String] {
  let out : Map[String, String] = Map([])
  match obj.get(key) {
    None | Some(Null) => Ok(out)
    Some(Obj(kvs)) => {
      for kv in kvs {
        match kv.1 {
          Str(s) => out[kv.0] = s
          _ => return Err("field '\{key}.\{kv.0}' must be a string")
        }
      }
      Ok(out)
    }
    Some(_) => Err("field '\{key}' must be an object of strings")
  }
}

///|
fn opt_str_pairs(obj : @rjson.Value, key : String) -> Result[Array[(String, String)], String] {
  let out : Array[(String, String)] = []
  match obj.get(key) {
    None | Some(Null) => Ok(out)
    Some(Obj(kvs)) => {
      for kv in kvs {
        match kv.1 {
          Str(s) => out.push((kv.0, s))
          _ => return Err("field '\{key}.\{kv.0}' must be a string")
        }
      }
      Ok(out)
    }
    Some(_) => Err("field '\{key}' must be an object of strings")
  }
}

///|
fn opt_obj(obj : @rjson.Value, key : String) -> Result[@rjson.Value, String] {
  match obj.get(key) {
    None | Some(Null) => Ok(@rjson.Value::Obj([]))
    Some(Obj(_) as o) => Ok(o)
    Some(_) => Err("field '\{key}' must be an object")
  }
}

///|
/// Parse, variant-merge, apply CLI overrides, and validate an `mbui.json` document.
pub fn parse_manifest(text : String, overrides : CliOverrides) -> Result[Manifest, String] {
  let root = try @rjson.parse(text) catch {
    @rjson.JsonError(msg) => return Err("invalid JSON: \{msg}")
  }
  match root {
    Obj(_) => ()
    _ => return Err("mbui.json root must be a JSON object")
  }
  // Apply variant deep merge if requested
  let mut variant_name = ""
  let effective = match overrides.variant {
    None => root
    Some(vname) => {
      variant_name = vname
      match root.get("variants") {
        Some(Obj(vkvs)) => {
          let mut found : @rjson.Value? = None
          let avail : Array[String] = []
          for kv in vkvs {
            avail.push(kv.0)
            if kv.0 == vname {
              found = Some(kv.1)
            }
          }
          match found {
            Some(Obj(_) as vobj) => merge_json(root.remove("variants"), vobj)
            Some(_) => return Err("variant '\{vname}' must be an object")
            None => {
              let list = avail.join(", ")
              return Err("unknown variant '\{vname}' (available: \{list})")
            }
          }
        }
        _ => return Err("unknown variant '\{vname}' (no 'variants' section defined)")
      }
    }
  }

  let raw_app_id = match opt_str(effective, "appId", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let app_id = match overrides.app_id {
    Some(id) => id
    None => raw_app_id
  }
  if !is_valid_app_id(app_id) {
    return Err("invalid or missing 'appId' ('\{app_id}'): expected reverse-DNS identifier like dev.example.app")
  }

  let name = match opt_str(effective, "name", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  if name.trim(chars=" \t\r\n").length() == 0 {
    return Err("missing or empty required field 'name'")
  }

  let raw_exec = match opt_str(effective, "executable", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let executable = if raw_exec.length() > 0 { raw_exec } else { derive_executable(name) }

  let raw_version = match opt_str(effective, "version", "0.1.0") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let version = match overrides.version {
    Some(v) => v
    None => raw_version
  }
  if version.trim(chars=" \t\r\n").length() == 0 {
    return Err("field 'version' must not be empty")
  }

  let raw_build = match opt_int(effective, "build", 1) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let build = match overrides.build {
    Some(b) => b
    None => raw_build
  }
  if build < 1 {
    return Err("field 'build' must be >= 1 (got \{build})")
  }

  let entry = match opt_str(effective, "entry", "src/app") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  if entry.trim(chars=" \t\r\n").length() == 0 {
    return Err("field 'entry' must not be empty")
  }

  let icon = match opt_str(effective, "icon", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let icon_dark = match opt_str(effective, "iconDark", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let url_schemes = match opt_str_arr(effective, "urlSchemes", []) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let env = match opt_str_map(effective, "env") {
    Ok(m) => m
    Err(e) => return Err(e)
  }
  let resources = match opt_str_arr(effective, "resources", []) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let runtime = match opt_str(effective, "runtime", "native") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  if runtime != "native" && runtime != "wasm" {
    return Err("field 'runtime' must be \"native\" or \"wasm\" (got \"\{runtime}\")")
  }

  // macos
  let mac_obj = match opt_obj(effective, "macos") {
    Ok(o) => o
    Err(e) => return Err(e)
  }
  let mac_min_version = match opt_str(mac_obj, "minVersion", "13.0") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let mac_category = match opt_str(mac_obj, "category", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let mac_entitlements = match opt_str(mac_obj, "entitlements", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let mac_info_plist = match mac_obj.get("infoPlist") {
    None | Some(Null) => []
    Some(Obj(kvs)) => kvs
    Some(_) => return Err("field 'macos.infoPlist' must be an object")
  }
  let mac_formats = match opt_str_arr(mac_obj, "formats", ["app"]) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let macos : MacConfig = {
    min_version: mac_min_version,
    category: mac_category,
    entitlements: mac_entitlements,
    info_plist: mac_info_plist,
    formats: mac_formats,
  }

  // windows
  let win_obj = match opt_obj(effective, "windows") {
    Ok(o) => o
    Err(e) => return Err(e)
  }
  let win_company = match opt_str(win_obj, "company", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let win_install_dir = match opt_str(win_obj, "installDir", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let win_formats = match opt_str_arr(win_obj, "formats", ["zip"]) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let win_raw_for_delta = match opt_bool(win_obj, "rawForDelta", false) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let windows : WinConfig = {
    company: win_company,
    install_dir: win_install_dir,
    formats: win_formats,
    raw_for_delta: win_raw_for_delta,
  }

  // linux
  let lin_obj = match opt_obj(effective, "linux") {
    Ok(o) => o
    Err(e) => return Err(e)
  }
  let lin_categories = match opt_str_arr(lin_obj, "categories", ["Utility"]) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let lin_formats = match opt_str_arr(lin_obj, "formats", ["tar.gz"]) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let linux : LinuxConfig = { categories: lin_categories, formats: lin_formats }

  // android
  let and_obj = match opt_obj(effective, "android") {
    Ok(o) => o
    Err(e) => return Err(e)
  }
  let and_min_sdk = match opt_int(and_obj, "minSdk", 26) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let and_target_sdk = match opt_int(and_obj, "targetSdk", 35) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let and_compile_sdk = match opt_int(and_obj, "compileSdk", 35) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let and_abis = match opt_str_arr(and_obj, "abis", ["arm64-v8a"]) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let and_edge = match opt_bool(and_obj, "edgeToEdge", true) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let and_ground = match opt_str(and_obj, "ground", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let and_perms = match opt_str_arr(and_obj, "permissions", []) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let and_java = match opt_str_arr(and_obj, "java", []) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let and_res = match opt_str_arr(and_obj, "res", []) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let and_rules = match opt_str_arr(and_obj, "rules", []) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let and_lock = match opt_str(and_obj, "lock", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let and_merged = match opt_str_arr(and_obj, "merged", []) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let android : AndroidConfig = {
    min_sdk: and_min_sdk,
    target_sdk: and_target_sdk,
    compile_sdk: and_compile_sdk,
    abis: and_abis,
    edge_to_edge: and_edge,
    ground: and_ground,
    permissions: and_perms,
    java: and_java,
    res: and_res,
    rules: and_rules,
    lock: and_lock,
    merged: and_merged,
  }

  // ios
  let ios_obj = match opt_obj(effective, "ios") {
    Ok(o) => o
    Err(e) => return Err(e)
  }
  let ios_min_version = match opt_str(ios_obj, "minVersion", "16.0") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let ios_edge = match opt_bool(ios_obj, "edgeToEdge", true) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let ios_ground = match opt_str(ios_obj, "ground", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let ios_share = match opt_bool(ios_obj, "shareExtension", false) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let ios_push = match opt_bool(ios_obj, "push", false) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let ios_usage = match opt_str_pairs(ios_obj, "usageDescriptions") {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let ios_entitlements = match opt_str(ios_obj, "entitlements", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let ios : IosConfig = {
    min_version: ios_min_version,
    edge_to_edge: ios_edge,
    ground: ios_ground,
    share_extension: ios_share,
    push: ios_push,
    usage_descriptions: ios_usage,
    entitlements: ios_entitlements,
  }

  // web
  let web_obj = match opt_obj(effective, "web") {
    Ok(o) => o
    Err(e) => return Err(e)
  }
  let web_title = match opt_str(web_obj, "title", name) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let web_light = match opt_str(web_obj, "themeColorLight", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let web_dark = match opt_str(web_obj, "themeColorDark", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let web_brotli = match opt_bool(web_obj, "brotli", true) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let web_pwa = match opt_bool(web_obj, "pwa", false) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let web_head = match opt_str(web_obj, "head", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let web : WebConfig = {
    title: web_title,
    theme_color_light: web_light,
    theme_color_dark: web_dark,
    brotli: web_brotli,
    pwa: web_pwa,
    head: web_head,
  }

  // updater
  let upd_obj = match opt_obj(effective, "updater") {
    Ok(o) => o
    Err(e) => return Err(e)
  }
  let upd_feed = match opt_str(upd_obj, "feed", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let upd_channel = match opt_str(upd_obj, "channel", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let upd_key = match opt_str(upd_obj, "publicKey", "") {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let updater : UpdaterConfig = {
    feed: upd_feed,
    channel: upd_channel,
    public_key: upd_key,
  }

  Ok({
    app_id,
    name,
    executable,
    version,
    build,
    entry,
    icon,
    icon_dark,
    url_schemes,
    env,
    resources,
    runtime,
    macos,
    windows,
    linux,
    android,
    ios,
    web,
    updater,
    variant: variant_name,
  })
}

///|
/// Render a human- and CI-readable summary of the resolved manifest.
pub fn Manifest::summary(self : Manifest) -> String {
  let sb = StringBuilder()
  sb.write_string("appId:      \{self.app_id}\n")
  sb.write_string("name:       \{self.name}\n")
  sb.write_string("executable: \{self.executable}\n")
  sb.write_string("version:    \{self.version} (build \{self.build})\n")
  sb.write_string("entry:      \{self.entry}\n")
  sb.write_string("runtime:    \{self.runtime}\n")
  if self.variant != "" {
    sb.write_string("variant:    \{self.variant}\n")
  }
  if self.icon != "" {
    sb.write_string("icon:       \{self.icon}\n")
  }
  if self.icon_dark != "" {
    sb.write_string("iconDark:   \{self.icon_dark}\n")
  }
  if self.url_schemes.length() > 0 {
    let schemes = self.url_schemes.join(", ")
    sb.write_string("urlSchemes: \{schemes}\n")
  }
  if self.resources.length() > 0 {
    let res_list = self.resources.join(", ")
    sb.write_string("resources:  \{res_list}\n")
  }
  if self.env.length() > 0 {
    let keys : Array[String] = []
    self.env.each(fn(k, _) { keys.push(k) })
    keys.sort_by(fn(a, b) { @rjson.str_cmp(a, b) })
    let pairs = keys.map(fn(k) {
      let v = self.env.get(k).unwrap_or("")
      "\{k}=\{v}"
    })
    let joined_env = pairs.join(", ")
    sb.write_string("env:        \{joined_env}\n")
  }
  let mac_fmts = self.macos.formats.join(", ")
  sb.write_string("macos:      min=\{self.macos.min_version} formats=[\{mac_fmts}]")
  if self.macos.category != "" {
    sb.write_string(" category=\{self.macos.category}")
  }
  if self.macos.entitlements != "" {
    sb.write_string(" entitlements=\{self.macos.entitlements}")
  }
  sb.write_string("\n")
  let win_fmts = self.windows.formats.join(", ")
  sb.write_string("windows:    formats=[\{win_fmts}] rawForDelta=\{self.windows.raw_for_delta}")
  if self.windows.company != "" {
    sb.write_string(" company=\{self.windows.company}")
  }
  if self.windows.install_dir != "" {
    sb.write_string(" installDir=\{self.windows.install_dir}")
  }
  sb.write_string("\n")
  let lin_fmts = self.linux.formats.join(", ")
  let lin_cats = self.linux.categories.join(", ")
  sb.write_string("linux:      formats=[\{lin_fmts}] categories=[\{lin_cats}]\n")
  let and_abis = self.android.abis.join(", ")
  sb.write_string(
    "android:    sdk=\{self.android.min_sdk}/\{self.android.target_sdk}/\{self.android.compile_sdk} abis=[\{and_abis}] edgeToEdge=\{self.android.edge_to_edge}",
  )
  if self.android.ground != "" {
    sb.write_string(" ground=\{self.android.ground}")
  }
  if self.android.permissions.length() > 0 {
    sb.write_string(" perms=\{self.android.permissions.length()}")
  }
  if self.android.java.length() > 0 {
    sb.write_string(" java=\{self.android.java.length()}")
  }
  if self.android.res.length() > 0 {
    sb.write_string(" res=\{self.android.res.length()}")
  }
  if self.android.rules.length() > 0 {
    sb.write_string(" rules=\{self.android.rules.length()}")
  }
  if self.android.lock != "" {
    sb.write_string(" lock=\{self.android.lock}")
  }
  if self.android.merged.length() > 0 {
    sb.write_string(" merged=\{self.android.merged.length()}")
  }
  sb.write_string("\n")
  sb.write_string(
    "ios:        min=\{self.ios.min_version} edgeToEdge=\{self.ios.edge_to_edge} share=\{self.ios.share_extension} push=\{self.ios.push}",
  )
  if self.ios.ground != "" {
    sb.write_string(" ground=\{self.ios.ground}")
  }
  if self.ios.usage_descriptions.length() > 0 {
    sb.write_string(" usageDescriptions=\{self.ios.usage_descriptions.length()}")
  }
  if self.ios.entitlements != "" {
    sb.write_string(" entitlements=\{self.ios.entitlements}")
  }
  sb.write_string("\n")
  sb.write_string(
    "web:        title=\"\{self.web.title}\" brotli=\{self.web.brotli} pwa=\{self.web.pwa}",
  )
  if self.web.theme_color_light != "" {
    sb.write_string(" light=\{self.web.theme_color_light}")
  }
  if self.web.theme_color_dark != "" {
    sb.write_string(" dark=\{self.web.theme_color_dark}")
  }
  sb.write_string("\n")
  if self.updater.feed != "" || self.updater.channel != "" || self.updater.public_key != "" {
    sb.write_string(
      "updater:    feed=\{self.updater.feed} channel=\{self.updater.channel} key=\{self.updater.public_key}\n",
    )
  }
  sb.to_string()
}

///|
/// Package name under `src/` (strips leading `src/` if present).
pub fn Manifest::entry_pkg(self : Manifest) -> String {
  if self.entry.has_prefix("src/") {
    self.entry.exact_view(start=4).to_owned()
  } else {
    self.entry
  }
}
