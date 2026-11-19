// An Android app's APK without Gradle (scripts/apk, which builds this): its Java compiled, shrunk by R8, its
// resources and manifest linked by aapt2, its native libraries and assets packed, aligned and signed, with the SDK's
// own tools (and R8 at a version pinned here). What scripts/apk.py did, in MoonBit (2026-10-23: tools are MoonBit).
//
//     apk lock APP.json             its dependencies (APP.json's "lock": group:artifact:version[:classifier] a line) fetched once
//                                   and their SHA-256 written beside each, so builds take those bytes and no others
//     apk build APP.json --variant V --version-code N --version-name S --out APP.apk
//                                   [--abi arm64-v8a] [--keystore PATH] [--key-alias ALIAS] [--ks-pass SPEC]
//                                   [--key-pass SPEC] [--v3-signing] [--verify-cert SHA256] [--dex-only]
//                                   (--dex-only: up to its dex, kept for the build after it: begun beside what
//                                   the build packs, android.sh)
//     apk repack IN.apk --out OUT.apk [--app-id ID] [--label NAME] [--version-code N] [--version-name S]
//                                   [--env K=V;...] [--edge-to-edge true|false] [--ground C] [--debuggable true|false]
//                                   [--url-scheme S] [--permission P] [--manifest PATH] [--keystore PATH]
//                                   [--key-alias ALIAS] [--ks-pass SPEC] [--key-pass SPEC] [--v3-signing]
//                                   [--verify-cert SHA256]
//     apk fetch PATH SHA256         a file of the Maven repositories (its path in one), checked, kept: its local path
//
// APP.json (paths relative to it): "namespace" (its Java package, R's), "applicationId", "minSdk", "targetSdk",
// "compileSdk", "manifest" (optional or "@mbui" for mbui's default manifest), "java" [dirs], "res" [dirs],
// "assets" [dirs], "jniLibs" [dirs], "rules" [R8 files], "lock" (the dependencies' file), "merged" [group:artifact
// prefixes: libraries whose manifests' components the app's manifest has merged by hand],
// optional declarative manifest fields (at top-level and/or inside a variant): "label", "edgeToEdge" (bool),
// "ground" (string), "env" ({K: V}), "urlSchemes" [strings], "permissions" [strings],
// "variants": {NAME: {"applicationId" (the app's own, in place of APP.json's),
// "applicationIdSuffix", "placeholders": {…}, "res" [dirs over the app's: its own launcher colours, its own name],
// "minify": bool, "debuggable": bool}}, "strings": {resource name: [env var naming a JSON file, its key]} (values put
// in as string resources: what is secret to the build, read by the app as it starts).
//
// Why: Gradle's release build (AGP 9) ran R8 and lint again on every build, as the versionCode (main's commit count)
// is in the manifest R8 reads for its resource shrinking, and its cache could never be hit: most of CI's minute of
// Gradle (2026-10-22). Here R8's output is kept by what it is made of (the classes, the dependencies, the rules, R8's
// version), the build's number only in the manifest linked at the end. The manifest is the app's with its placeholders
// filled and its components' names made whole, and what its libraries' manifests add to <application> (attributes
// alone: one with anything else stops this, rather than a merge it does not do, unless the app's manifest has merged
// it by hand: "merged"). The libraries' resources are linked beside the app's (R classes for each package); resources
// are not shrunk; stripped of nothing, the native libraries compressed (extractNativeLibs), as the release had them.
// Every deflated entry is then deflated again by the deflater the app carries (dev.mbui.Delta's repack, JZlib, on this
// machine's JVM), before zipalign (which pads only stored entries) and apksigner: a phone applying an update's delta
// deflates the entries it made with that same code, and must come to these very bytes (Delta.java's head).
//
// Tools: $ANDROID_HOME's platforms/android-<compileSdk>/android.jar and the newest build-tools' aapt2, zipalign and
// apksigner; java and javac (17 or newer); R8 from Google's Maven at r8_version; curl, unzip, zip and shasum (or
// sha256sum). Everything fetched is kept in $APK_CACHE (default ~/.cache/mbui-apk) by its content's hash.

///|
let r8_version : String = "9.0.55"

///|
let repos : Array[String] = ["https://dl.google.com/dl/android/maven2", "https://repo1.maven.org/maven2"]

// ── the system ──────────────────────────────────────────────────────────

///|
fn say(msg : String) -> Unit {
  @sys.println_out("apk: " + msg)
}

///|
fn die(msg : String) -> Unit {
  @sys.eprintln("apk: " + msg)
  @sys.exit(1)
}

///|
/// A word of a shell command, quoted.
fn q(s : String) -> String {
  "'" + s.replace_all(old="'", new="'\\''") + "'"
}

///|
/// A command's output (its stdout and stderr), None when it did not end with 0.
fn try_sh(cmd : String) -> String? {
  @sys.run_out(cmd + " 2>&1")
}

///|
/// A command that must end with 0: its output, or what it said and a stop.
fn sh(cmd : String, what : String) -> String {
  match try_sh(cmd) {
    Some(out) => out
    None => {
      // (again, for what it said: run_out keeps no output of one that failed)
      let said = @sys.run_out("(" + cmd + ") 2>&1; true").unwrap_or("")
      @sys.eprintln(said)
      die("\{what} failed: " + sub(cmd, 0, @cmp.minimum(cmd.length(), 200)) + " …")
      ""
    }
  }
}

///|
/// `s` from `a` to `b` (UTF-16 offsets).
fn sub(s : String, a : Int, b : Int) -> String {
  s.exact_view(start=a, end=b).to_owned()
}

///|
fn home() -> String {
  @sys.getenv("HOME").unwrap_or("/tmp")
}

///|
fn sha256_file(path : String) -> String {
  let tool = if @sys.run_out("command -v shasum") is Some(_) { "shasum -a 256" } else { "sha256sum" }
  let out = sh(tool + " " + q(path), "sha256")
  match out.split(" ").next() {
    Some(h) => h.to_owned()
    None => ""
  }
}

///|
/// A SHA-256 of words (cache keys).
fn sha256_text(text : String, at : String) -> String {
  let f = at + ".key"
  ignore(@sys.write_text(f, text))
  let h = sha256_file(f)
  ignore(@sys.remove(f))
  h
}

///|
fn cache_dir() -> String {
  let d = match @sys.getenv("APK_CACHE") {
    Some(d) if d != "" => d
    _ => @sys.join(home(), ".cache/mbui-apk")
  }
  @sys.makedirs(d)
  d
}

///|
/// `url` into `dest`; false where the repository has no such file. (Once: what is fetched is kept in the cache, CI's by
/// its Actions cache, so a build fetches only what a change of the lock asks for.) A name of its own (Maven Central
/// turns some default agents away); Google's Maven answers 403 for what it does not have: the next repository's.
fn fetch(url : String, dest : String) -> Bool {
  let tmp = dest + ".part"
  match try_sh("curl -fsSL --retry 2 --max-time 300 -A mbui-apk/1 -o " + q(tmp) + " " + q(url)) {
    Some(_) => {
      ignore(sh("mv -f " + q(tmp) + " " + q(dest), "mv"))
      true
    }
    None => {
      ignore(@sys.remove(tmp))
      false
    }
  }
}

///|
fn artifact_path(coord : String, ext : String) -> String {
  let p = coord.split(":").map(fn(x) { x.to_owned() }).to_array()
  let g = p[0].replace_all(old=".", new="/")
  // group:artifact:version[:classifier] (hermes-android's AAR is only its -release one)
  let c = if p.length() > 3 { "-" + p[3] } else { "" }
  "\{g}/\{p[1]}/\{p[2]}/\{p[1]}-\{p[2]}\{c}.\{ext}"
}

///|
/// The artifact coord.ext, from the cache or the repositories; checked against `sha` when given.
fn get_artifact(coord : String, ext : String, sha? : String = "") -> String? {
  let dest = @sys.join(cache_dir(), "m2/" + coord.replace_all(old=":", new="_") + "." + ext)
  @sys.makedirs(@sys.dirname(dest))
  if !@sys.exists(dest) {
    if !repos.iter().any(fn(r) { fetch(r + "/" + artifact_path(coord, ext), dest) }) {
      return None
    }
  }
  if sha != "" && sha256_file(dest) != sha {
    ignore(@sys.remove(dest))
    die("\{coord}.\{ext}: not the SHA-256 the lock has (\{sha})")
  }
  Some(dest)
}

///|
fn cmd_fetch(path : String, sha : String) -> Unit {
  let dest = @sys.join(cache_dir(), "m2/" + path.replace_all(old="/", new="_"))
  @sys.makedirs(@sys.dirname(dest))
  if !@sys.exists(dest) && !repos.iter().any(fn(r) { fetch(r + "/" + path, dest) }) {
    die("\{path}: not found")
  }
  if sha256_file(dest) != sha {
    ignore(@sys.remove(dest))
    die("\{path}: not the SHA-256 asked for (\{sha})")
  }
  @sys.println_out(dest)
}

// ── the dependencies' lock ─────────────────────────────────────────────

///|
/// The lock's lines (group:artifact:version [ext sha256]), # comments left out.
fn read_lock(path : String) -> Array[(String, String, String)] {
  let out = []
  let text = @sys.read_text(path).unwrap_or("")
  for raw in text.split("\n") {
    let line = match raw.find("#") {
      Some(i) => raw.exact_view(end=i).trim(chars=" \t\r").to_owned()
      None => raw.trim(chars=" \t\r").to_owned()
    }
    if line == "" {
      continue
    }
    let parts = line.split(" ").filter(fn(x) { x != "" }).map(fn(x) { x.to_owned() }).to_array()
    out.push((parts[0], parts.get(1).unwrap_or(""), parts.get(2).unwrap_or("")))
  }
  out
}

///|
fn cmd_lock(app : String) -> Unit {
  let (cfg, base) = load(app)
  let path = @sys.join(base, text_of(cfg, "lock"))
  let head = @sys.read_text(path).unwrap_or("").split("\n").filter(fn(l) { l.has_prefix("#") }).map(fn(l) {
    l.to_owned()
  }).to_array()
  let lines = []
  for d in read_lock(path) {
    let coord = d.0
    let mut done = false
    for ext in ["aar", "jar"] {
      match get_artifact(coord, ext) {
        Some(p) => {
          lines.push("\{coord} \{ext} \{sha256_file(p)}")
          done = true
          break
        }
        None => ()
      }
    }
    if !done {
      // a BOM, or a root of Kotlin's multiplatform: nothing to pack
      lines.push("\{coord} none")
    }
  }
  ignore(@sys.write_text(path, (head + lines).join("\n") + "\n"))
  say("\{path}: \{lines.length()} dependencies")
}

// ── the build ──────────────────────────────────────────────────────────

///|
fn load(app : String) -> (@rjson.Value, String) {
  let text = @sys.read_text(app).unwrap_or("")
  let cfg = @rjson.parse(text) catch {
    _ => {
      die("\{app}: not JSON")
      @rjson.Value::Null
    }
  }
  (cfg, @sys.dirname(@sys.abspath(app)))
}

///|
fn text_of(v : @rjson.Value, key : String) -> String {
  match v.get(key) {
    Some(Str(s)) => s
    Some(Num(n)) => n
    _ => ""
  }
}

///|
fn texts_of(v : @rjson.Value, key : String) -> Array[String] {
  match v.get(key) {
    Some(Arr(a)) => a.filter_map(fn(x) { x.str() })
    _ => []
  }
}

///|
fn flag_of(v : @rjson.Value, key : String) -> Bool {
  v.get(key) is Some(Bool(true))
}

///|
fn sdk() -> String {
  match @sys.getenv("ANDROID_HOME") {
    Some(s) if s != "" => s
    _ =>
      match @sys.getenv("ANDROID_SDK_ROOT") {
        Some(s) if s != "" => s
        _ => @sys.join(home(), "Library/Android/sdk")
      }
  }
}

///|
/// A whole number's digits (anything else: 0).
fn int_of(s : String) -> Int {
  let mut n = 0
  for ch in s {
    if ch < '0' || ch > '9' {
      return 0
    }
    n = n * 10 + (ch.to_int() - '0'.to_int())
  }
  n
}

///|
/// A version's numbers, compared as numbers.
fn version_cmp(a : String, b : String) -> Int {
  let na = a.split(".").map(fn(x) { int_of(x.to_owned()) }).to_array()
  let nb = b.split(".").map(fn(x) { int_of(x.to_owned()) }).to_array()
  for i in 0..<@cmp.maximum(na.length(), nb.length()) {
    let x = na.get(i).unwrap_or(0)
    let y = nb.get(i).unwrap_or(0)
    if x != y {
      return x.compare(y)
    }
  }
  0
}

///|
/// The newest build-tools directory in $ANDROID_HOME.
fn newest_build_tools() -> String {
  let num = @re.Regex::new("^\\d+\\.\\d+\\.\\d+$") catch { _ => panic() }
  let bts = @sys.list_dir(@sys.join(sdk(), "build-tools")).filter(fn(d) { num.matches(d) })
  if bts.length() == 0 {
    die("no build-tools in \{sdk()}")
  }
  bts.sort_by(version_cmp)
  @sys.join(sdk(), "build-tools/" + bts[bts.length() - 1])
}

///|
/// The newest platforms/android-<N>/android.jar in $ANDROID_HOME.
fn newest_android_jar() -> String {
  let plats = @sys.join(sdk(), "platforms")
  let rx_plat = @re.Regex::new("^android-(\\d+)$") catch { _ => panic() }
  let found : Array[(Int, String)] = []
  if @sys.is_dir(plats) {
    for d in @sys.list_dir(plats) {
      match rx_plat.search(d) {
        Some(m) => {
          let jar = @sys.join(plats, d + "/android.jar")
          if @sys.exists(jar) {
            found.push((int_of(m.get(1)), jar))
          }
        }
        None => ()
      }
    }
  }
  if found.length() == 0 {
    die("no platforms/android-*/android.jar in \{sdk()}")
  }
  found.sort_by(fn(a, b) { a.0.compare(b.0) })
  found[found.length() - 1].1
}

///|
/// android.jar of `compile_sdk` and the newest build-tools.
fn sdk_tools(compile_sdk : String) -> (String, String) {
  let jar = @sys.join(sdk(), "platforms/android-\{compile_sdk}/android.jar")
  if !@sys.exists(jar) {
    die("no \{jar}")
  }
  (jar, newest_build_tools())
}

///|
/// An AAR unpacked once into the cache (by its hash): its classes, libraries, res, manifest, rules, R.txt.
fn extract_aar(path : String, sha : String) -> String {
  let d = @sys.join(cache_dir(), "aar/" + sub(sha, 0, 24))
  if !@sys.exists(@sys.join(d, ".done")) {
    ignore(try_sh("rm -rf " + q(d)))
    @sys.makedirs(d)
    ignore(sh("unzip -q -o " + q(path) + " -d " + q(d), "unzip"))
    ignore(@sys.write_text(@sys.join(d, ".done"), ""))
  }
  d
}

///|
/// A hash of the files under `paths` (their paths below each and contents), in order.
fn tree_hash(paths : Array[String], at : String) -> String {
  let parts = []
  for base in paths {
    if @sys.is_file(base) {
      parts.push("F" + base + " " + sha256_file(base))
    } else if @sys.is_dir(base) {
      let tool = if @sys.run_out("command -v shasum") is Some(_) { "shasum -a 256" } else { "sha256sum" }
      parts.push(
        "D" +
        sh("cd " + q(base) + " && find . -type f | LC_ALL=C sort | while IFS= read -r f; do " + tool + " \"$f\"; done", "hash"),
      )
    }
  }
  sha256_text(parts.join("\n"), at)
}

///|
/// The build's string resources from the environment (cfg "strings"), as a values file under `d`.
fn write_strings(cfg : @rjson.Value, d : String) -> Unit {
  let vals = []
  match cfg.get("strings") {
    Some(Obj(kvs)) => {
      let sorted = kvs.copy()
      sorted.sort_by(fn(a, b) { @rjson.str_cmp(a.0, b.0) })
      for kv in sorted {
        let (name, spec) = kv
        let (env_var, key) = match spec {
          Arr([Str(v), Str(k)]) => (v, k)
          _ => ("", "")
        }
        let mut v = ""
        match @sys.getenv(env_var) {
          Some(p) if p != "" && @sys.exists(p) => {
            let j = @rjson.parse(@sys.read_text(p).unwrap_or("")) catch { _ => @rjson.Value::Null }
            v = match j.get(key) {
              Some(Str(s)) => s
              Some(Num(n)) => n
              Some(Bool(b)) => if b { "True" } else { "False" }
              _ => ""
            }
          }
          _ => ()
        }
        let v = v
          .replace_all(old="\\", new="\\\\")
          .replace_all(old="\"", new="\\\"")
          .replace_all(old="&", new="&amp;")
          .replace_all(old="<", new="&lt;")
          .replace_all(old="'", new="\\'")
        vals.push("  <string name=\"\{name}\" translatable=\"false\">\{v}</string>")
      }
    }
    _ => ()
  }
  @sys.makedirs(@sys.join(d, "values"))
  ignore(
    @sys.write_text(
      @sys.join(d, "values/build_strings.xml"),
      "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<resources>\n" + vals.join("\n") + "\n</resources>\n",
    ),
  )
}

///|
fn rx(p : String) -> @re.Regex {
  @re.Regex::new(p) catch {
    _ => panic()
  }
}

///|
/// Declarative overrides applied to an AndroidManifest.xml (from apk.json / variant or `apk repack` flags).
priv struct ManifestOverrides {
  label : String?
  edge_to_edge : Bool?
  ground : String?
  env : String?
  url_schemes : Array[String]
  permissions : Array[String]
}

///|
/// Escapes text for use inside an XML attribute value.
fn xml_escape(s : String) -> String {
  s
  .replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="\"", new="&quot;")
  .replace_all(old="'", new="&apos;")
}

///|
/// Serializes key/value pairs into deterministic `K=V;...` form (keys sorted).
fn serialize_env_pairs(pairs : Array[(String, String)]) -> String {
  let sorted = pairs.copy()
  sorted.sort_by(fn(a, b) { @rjson.str_cmp(a.0, b.0) })
  sorted.map(fn(kv) { "\{kv.0}=\{kv.1}" }).join(";")
}

///|
/// Reads and merges `env` objects from top-level config and variant (variant overrides top-level).
fn env_from_json(cfg : @rjson.Value, variant : @rjson.Value) -> String? {
  let merged : Array[(String, String)] = []
  let put = fn(v : @rjson.Value) {
    match v.get("env") {
      Some(Obj(kvs)) =>
        for kv in kvs {
          let val = match kv.1 {
            Str(s) => s
            Num(n) => n
            Bool(b) => if b { "true" } else { "false" }
            _ => continue
          }
          let mut replaced = false
          for i, existing in merged {
            if existing.0 == kv.0 {
              merged[i] = (kv.0, val)
              replaced = true
              break
            }
          }
          if !replaced {
            merged.push((kv.0, val))
          }
        }
      _ => ()
    }
  }
  put(cfg)
  put(variant)
  if merged.length() == 0 {
    None
  } else {
    Some(serialize_env_pairs(merged))
  }
}

///|
fn dedup_strings(xs : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for raw in xs {
    let s = raw.trim(chars=" \t\r\n").to_owned()
    if s != "" && !out.contains(s) {
      out.push(s)
    }
  }
  out
}

///|
/// Extracts declarative manifest overrides from `apk.json` and the active variant.
fn overrides_from_json(cfg : @rjson.Value, variant : @rjson.Value) -> ManifestOverrides {
  let label = match variant.get("label") {
    Some(Str(s)) if s != "" => Some(s)
    _ =>
      match cfg.get("label") {
        Some(Str(s)) if s != "" => Some(s)
        _ => None
      }
  }
  let edge_to_edge = match variant.get("edgeToEdge") {
    Some(Bool(b)) => Some(b)
    _ =>
      match cfg.get("edgeToEdge") {
        Some(Bool(b)) => Some(b)
        _ => None
      }
  }
  let ground = match variant.get("ground") {
    Some(Str(s)) if s != "" => Some(s)
    _ =>
      match cfg.get("ground") {
        Some(Str(s)) if s != "" => Some(s)
        _ => None
      }
  }
  let env = env_from_json(cfg, variant)
  let url_schemes = dedup_strings(texts_of(cfg, "urlSchemes") + texts_of(variant, "urlSchemes"))
  let permissions = dedup_strings(texts_of(cfg, "permissions") + texts_of(variant, "permissions"))
  { label, edge_to_edge, ground, env, url_schemes, permissions }
}

///|
/// Resolves the manifest path: omitted or `"@mbui"` falls back to mbui's default AndroidManifest.xml.
fn resolve_manifest_path(cfg : @rjson.Value, base : String, apk_home : String) -> String {
  let raw = text_of(cfg, "manifest")
  if raw == "" || raw == "@mbui" {
    @sys.join(apk_home, "../android/app/src/main/AndroidManifest.xml")
  } else {
    @sys.join(base, raw)
  }
}

///|
/// Inserts or updates `<meta-data android:name="NAME" android:value="VALUE" />` inside `<application>`.
fn set_meta_data(xml : String, name : String, value : String) -> String {
  let esc_val = xml_escape(value)
  let esc_name = xml_escape(name)
  let tag = "<meta-data android:name=\"\{esc_name}\" android:value=\"\{esc_val}\" />"
  let name_pat = name.replace_all(old=".", new="\\.")
  let existing = rx("<meta-data\\b[^>]*android:name=\"" + name_pat + "\"[^>]*/>")
  match existing.search(xml) {
    Some(m) => sub(xml, 0, m.start()) + tag + sub(xml, m.end(), xml.length())
    None =>
      match xml.find("</application>") {
        Some(at) => sub(xml, 0, at) + "        " + tag + "\n    " + sub(xml, at, xml.length())
        None => xml
      }
  }
}

///|
/// Builds a browsable VIEW `<intent-filter>` for a URL scheme.
fn build_scheme_intent_filter(scheme : String) -> String {
  let esc = xml_escape(scheme)
  "            <intent-filter>\n" +
  "                <action android:name=\"android.intent.action.VIEW\" />\n" +
  "                <category android:name=\"android.intent.category.DEFAULT\" />\n" +
  "                <category android:name=\"android.intent.category.BROWSABLE\" />\n" +
  "                <data android:scheme=\"\{esc}\" />\n" +
  "            </intent-filter>\n"
}

///|
/// Sets or replaces `package="..."` on the `<manifest ...>` opening tag without duplicating the attribute.
fn set_manifest_package(xml : String, app_id : String) -> String {
  match xml.find("<manifest") {
    None => xml
    Some(start) => {
      let rest = sub(xml, start, xml.length())
      match rest.find(">") {
        None => xml
        Some(rel_end) => {
          let end = start + rel_end + 1
          let open = sub(xml, start, end)
          let esc = xml_escape(app_id)
          let updated = match rx("\\bpackage=\"[^\"]*\"").search(open) {
            Some(pm) => sub(open, 0, pm.start()) + "package=\"\{esc}\"" + sub(open, pm.end(), open.length())
            None => "<manifest package=\"\{esc}\"" + sub(open, 9, open.length())
          }
          sub(xml, 0, start) + updated + sub(xml, end, xml.length())
        }
      }
    }
  }
}

///|
/// Sets, replaces, or removes an `android:<attr>="..."` attribute on the `<application ...>` opening tag.
fn set_application_attr(xml : String, attr : String, value : String?) -> String {
  match xml.find("<application") {
    None => xml
    Some(start) => {
      let rest = sub(xml, start, xml.length())
      match rest.find(">") {
        None => xml
        Some(rel_end) => {
          let end = start + rel_end + 1
          let open = sub(xml, start, end)
          let pat = rx("\\s*android:" + attr + "=\"[^\"]*\"")
          let updated = match value {
            Some(v) => {
              let esc = xml_escape(v)
              match pat.search(open) {
                Some(am) => sub(open, 0, am.start()) + " android:\{attr}=\"\{esc}\"" + sub(open, am.end(), open.length())
                None =>
                  if open.has_suffix("/>") {
                    sub(open, 0, open.length() - 2) + " android:\{attr}=\"\{esc}\" />"
                  } else {
                    sub(open, 0, open.length() - 1) + " android:\{attr}=\"\{esc}\">"
                  }
              }
            }
            None => pat.sub(open, "")
          }
          sub(xml, 0, start) + updated + sub(xml, end, xml.length())
        }
      }
    }
  }
}

///|
/// Applies declarative manifest overrides (label, edgeToEdge, ground, env, urlSchemes, permissions).
fn apply_manifest_overrides(xml_in : String, opts : ManifestOverrides) -> String {
  let mut text = xml_in
  // 1. label on <application ...>
  match opts.label {
    Some(lbl) => text = set_application_attr(text, "label", Some(lbl))
    None => ()
  }
  // 2. <meta-data> entries inside <application>
  match opts.edge_to_edge {
    Some(true) => text = set_meta_data(text, "dev.mbui.edge", "true")
    Some(false) => text = set_meta_data(text, "dev.mbui.edge", "false")
    None => ()
  }
  match opts.ground {
    Some(g) => text = set_meta_data(text, "dev.mbui.ground", g)
    None => ()
  }
  match opts.env {
    Some(e) => text = set_meta_data(text, "dev.mbui.env", e)
    None => ()
  }
  // 3. urlSchemes injected into the MAIN/LAUNCHER <activity> (iterative scan to avoid deep regex backtracking)
  let schemes = dedup_strings(opts.url_schemes)
  if schemes.length() > 0 {
    let mut pos = 0
    while pos < text.length() {
      let rest = sub(text, pos, text.length())
      match rest.find("<activity") {
        None => break
        Some(rel_start) => {
          let act_start = pos + rel_start
          let after_tag = act_start + 9
          // ensure "<activity" is followed by whitespace or '>' (not "<activity-alias")
          let next_ch = if after_tag < text.length() { sub(text, after_tag, after_tag + 1) } else { "" }
          if next_ch != " " && next_ch != "\t" && next_ch != "\n" && next_ch != "\r" && next_ch != ">" {
            pos = after_tag
            continue
          }
          let from_act = sub(text, act_start, text.length())
          match from_act.find("</activity>") {
            None => break
            Some(rel_end) => {
              let block = sub(text, act_start, act_start + rel_end + 11)
              if block.contains("android.intent.action.MAIN") && block.contains("android.intent.category.LAUNCHER") {
                let mut add = ""
                for s in schemes {
                  let esc = xml_escape(s)
                  let has_plain = block.contains("<data android:scheme=\"\{esc}\" />") ||
                    block.contains("<data android:scheme=\"\{esc}\"/>")
                  if !has_plain {
                    add = add + build_scheme_intent_filter(s)
                  }
                }
                if add != "" {
                  let insert_at = act_start + rel_end
                  text = sub(text, 0, insert_at) + add + "        " + sub(text, insert_at, text.length())
                }
                break
              }
              pos = act_start + rel_end + 11
            }
          }
        }
      }
    }
  }
  // 4. permissions deduplicated before <application>
  let perms = dedup_strings(opts.permissions)
  if perms.length() > 0 {
    let mut add = ""
    for p in perms {
      if !text.contains("android:name=\"" + p + "\"") {
        add = add + "<uses-permission android:name=\"\{xml_escape(p)}\" />\n    "
      }
    }
    if add != "" {
      match text.find("<application") {
        Some(at) => text = sub(text, 0, at) + add + sub(text, at, text.length())
        None => ()
      }
    }
  }
  text
}

///|
/// The app's manifest as it goes to aapt2: placeholders filled, its components' names whole, tools: gone, and what the
/// libraries' manifests put on <application> (their permissions too, those the app does not ask for), plus declarative
/// overrides from apk.json / variant.
fn manifest_text(
  cfg : @rjson.Value,
  base : String,
  variant : @rjson.Value,
  app_id : String,
  libs : Array[(String, String)],
) -> String {
  let mfile = resolve_manifest_path(cfg, base, @sys.getenv("APK_HOME").unwrap_or("."))
  let mut text = @sys.read_text(mfile).unwrap_or("")
  if text == "" {
    die("manifest not found or empty: \{mfile}")
  }
  let ph : Array[(String, String)] = match variant.get("placeholders") {
    Some(Obj(kvs)) => kvs.filter_map(fn(kv) { kv.1.str().map(fn(s) { (kv.0, s) }) })
    _ => []
  }
  ph.push(("applicationId", app_id))
  for kv in ph {
    text = text.replace_all(old="${" + kv.0 + "}", new=kv.1)
  }
  let left = rx("\\$\\{(\\w+)\\}").findall(text)
  if left.length() > 0 {
    let names = left.join(", ")
    die("manifest placeholders not given: [\{names}]")
  }
  let ns = text_of(cfg, "namespace")
  text = rx("(<(?:application|activity|activity-alias|service|receiver|provider)\\b[^>]*?android:name=\")\\.").sub_with(
    text,
    fn(m) { m.get(1) + ns + "." },
  )
  text = rx("\\s+tools:\\w+=\"[^\"]*\"").sub(text, "")
  text = rx("\\s+xmlns:tools=\"[^\"]*\"").sub(text, "")
  let merged = texts_of(cfg, "merged")
  // the libraries' <application> attributes (androidx.core's appComponentFactory), not those the app sets, and the
  // permissions they ask for that the app does not
  let added : Array[(String, String)] = []
  let permissions : Array[String] = []
  let comment = @re.Regex::new("<!--.*?-->", flags={ ..@re.no_flags, dotall: true }) catch { _ => panic() }
  let app_rx = @re.Regex::new("<application\\b([^>]*?)(/>|>(.*?)</application>)", flags={ ..@re.no_flags, dotall: true }) catch {
    _ => panic()
  }
  for lib in libs {
    let (name, d) = lib
    let mpath = @sys.join(d, "AndroidManifest.xml")
    if !@sys.exists(mpath) {
      continue
    }
    let lm = comment.sub(@sys.read_text(mpath).unwrap_or(""), "")
    let mut body = rx("<\\?xml[^>]*>").sub(lm, "")
    body = rx("<manifest\\b[^>]*>|</manifest>|<uses-sdk\\b[^>]*/>").sub(body, "")
    let app = app_rx.search(body)
    let mut rest = match app {
      Some(m) => body.replace(old=m.get(0), new="")
      None => body
    }
    // (a permission it asks for: the app's own too, once)
    for perm in rx("<uses-permission\\b[^>]*/>").findall(rest) {
      match rx("android:name=\"([^\"]+)\"").search(perm) {
        Some(m) if !text.contains("android:name=\"" + m.get(1) + "\"") => permissions.push(perm)
        _ => ()
      }
      rest = rest.replace_all(old=perm, new="")
    }
    let inner = match app {
      Some(m) => m.group(g=3).unwrap_or("")
      None => ""
    }
    // (one the app's manifest has merged by hand, APP.json's "merged": its components there as the app wants them)
    let by_hand = merged.iter().any(fn(p) { name.has_prefix(p) })
    if (rest.trim(chars=" \t\r\n") != "" || inner.trim(chars=" \t\r\n") != "") && !by_hand {
      die("\{name}: its manifest adds more than <application> attributes; merge it here first:\n" + body.trim(chars=" \t\r\n").to_owned())
    }
    match app {
      Some(m) =>
        for a in rx("(android:\\w+)=\"([^\"]*)\"").find_all(m.get(1)) {
          if !added.iter().any(fn(x) { x.0 == a.get(1) }) {
            added.push((a.get(1), a.get(2)))
          }
        }
      None => ()
    }
  }
  let app_open = match rx("<application\\b[^>]*").search(text) {
    Some(m) => m
    None => {
      die("no <application> in the manifest")
      panic()
    }
  }
  let have = rx("(android:\\w+)=").find_all(app_open.get(0)).map(fn(m) { m.get(1) })
  added.sort_by(fn(a, b) { @rjson.str_cmp(a.0, b.0) })
  let mut extra = ""
  for kv in added {
    if !have.contains(kv.0) {
      extra = extra + " \{kv.0}=\"\{kv.1}\""
    }
  }
  if !have.contains("android:extractNativeLibs") {
    extra = extra + " android:extractNativeLibs=\"true\""
  }
  if flag_of(variant, "debuggable") {
    extra = extra + " android:debuggable=\"true\""
  }
  text = sub(text, 0, app_open.end()) + extra + sub(text, app_open.end(), text.length())
  // its package: the application id (the namespace is R's and the components' names')
  text = set_manifest_package(text, app_id)
  if permissions.length() > 0 {
    let at = text.find("<application").unwrap_or(0)
    let seen = []
    let mut add = ""
    for p in permissions {
      if !seen.contains(p) {
        seen.push(p)
        add = add + p + "\n    "
      }
    }
    text = sub(text, 0, at) + add + sub(text, at, text.length())
  }
  apply_manifest_overrides(text, overrides_from_json(cfg, variant))
}

///|
/// The NDK's llvm-strip (the newest NDK's), as AGP strips a release's native libraries with.
fn llvm_strip() -> String {
  let nd = @sys.join(sdk(), "ndk")
  let ndks = if @sys.is_dir(nd) { @sys.list_dir(nd) } else { [] }
  ndks.sort_by(fn(a, b) { version_cmp(b, a) })
  for n in ndks {
    for host in ["darwin-x86_64", "linux-x86_64", "windows-x86_64"] {
      let p = @sys.join(nd, "\{n}/toolchains/llvm/prebuilt/\{host}/bin/llvm-strip")
      if @sys.exists(p) {
        return p
      }
    }
  }
  die("no NDK llvm-strip in \{nd}")
  ""
}

///|
/// `path` with its debug symbols stripped (--strip-unneeded, as AGP's stripReleaseDebugSymbols), kept by its content's
/// hash.
fn stripped(path : String) -> String {
  let out = @sys.join(cache_dir(), "strip/" + sub(sha256_file(path), 0, 32) + ".so")
  if @sys.exists(out) {
    ignore(try_sh("touch " + q(out)))
  } else {
    @sys.makedirs(@sys.dirname(out))
    ignore(sh(q(llvm_strip()) + " --strip-unneeded -o " + q(out + ".tmp") + " " + q(path), "llvm-strip"))
    ignore(sh("mv -f " + q(out + ".tmp") + " " + q(out), "mv"))
  }
  out
}

///|
/// classes.dex, then classes2.dex, classes3.dex… in their number's order.
fn dex_names(dir : String) -> Array[String] {
  let names = @sys.list_dir(dir).filter(fn(n) { n.has_prefix("classes") && n.has_suffix(".dex") })
  let num = fn(n : String) -> Int {
    let mid = sub(n, 7, n.length() - 4)
    if mid == "" {
      1
    } else {
      int_of(mid)
    }
  }
  names.sort_by(fn(a, b) { num(a).compare(num(b)) })
  names.map(fn(n) { @sys.join(dir, n) })
}

///|
/// A dependency's jar dexed (D8, debug) once, kept by its bytes, R8's version and the API level.
fn lib_dex(r8 : String, android_jar : String, min_api : String, jar : String, others : Array[String], work : String) -> String {
  let key = sub(sha256_text("\{sha256_file(jar)} \{r8_version} \{min_api}", work + "/libkey"), 0, 32)
  let d = @sys.join(cache_dir(), "dexlib/" + key)
  if !@sys.exists(@sys.join(d, ".done")) {
    ignore(try_sh("rm -rf " + q(d)))
    @sys.makedirs(d)
    let cp = others.map(fn(o) { "--classpath " + q(o) }).join(" ")
    ignore(
      sh(
        "java -cp " + q(r8) + " com.android.tools.r8.D8 --debug --min-api " + min_api + " --lib " + q(android_jar) +
        " --output " + q(d) + " " + q(jar) + " " + cp,
        "d8",
      ),
    )
    ignore(@sys.write_text(@sys.join(d, ".done"), ""))
  }
  d
}

///|
/// dev.mbui.Delta and JZlib, of the app's Java sources, compiled for this machine's JVM (the APK's repack): kept by
/// their sources' hash; "" where the app has no Delta. Compiled on their own rather than taken from the dex step's
/// javac: that step's classes are there only when its dex is not kept (and are built against android.jar), while
/// these few files compile in a second, and their key is exactly what the repack's bytes depend on besides the APK.
fn delta_classes(srcs : Array[String], work : String) -> String {
  let mine = srcs.filter(fn(p) { p.has_suffix("/dev/mbui/Delta.java") || p.contains("/com/jcraft/jzlib/") })
  if !mine.iter().any(fn(p) { p.has_suffix("/dev/mbui/Delta.java") }) {
    return ""
  }
  let key = mine.map(fn(p) { @sys.basename(p) + " " + sha256_file(p) })
  key.sort_by(@rjson.str_cmp)
  let d = @sys.join(cache_dir(), "delta/" + sub(sha256_text(key.join("\n"), work + "/deltakey"), 0, 32))
  if !@sys.exists(@sys.join(d, ".done")) {
    ignore(try_sh("rm -rf " + q(d)))
    @sys.makedirs(d)
    ignore(
      sh(
        "javac -nowarn -encoding UTF-8 -source 17 -target 17 -Xlint:-options -d " + q(d) + " " + mine.map(q).join(" "),
        "javac (Delta)",
      ),
    )
    ignore(@sys.write_text(@sys.join(d, ".done"), ""))
  } else {
    ignore(try_sh("touch " + q(d)))
  }
  d
}

///|
/// The cache kept small: the newest 6 dex outputs, the newest 24 stripped libraries, the newest 6 Delta compiles.
fn prune() -> Unit {
  for kv in [("dex", 6), ("strip", 24), ("delta", 6)] {
    let d = @sys.join(cache_dir(), kv.0)
    if @sys.is_dir(d) {
      ignore(try_sh("cd " + q(d) + " && ls -t | tail -n +\{kv.1 + 1} | while IFS= read -r n; do rm -rf \"$n\"; done"))
    }
  }
}

///|
/// Every file under `dir`, sorted (a path below it, its path).
fn files_under(dir : String) -> Array[String] {
  if !@sys.is_dir(dir) {
    return []
  }
  let out = sh("cd " + q(dir) + " && find . -type f | LC_ALL=C sort", "find")
  out
  .split("\n")
  .filter(fn(l) { l.has_prefix("./") })
  .map(fn(l) { sub(l.to_owned(), 2, l.length()) })
  .to_array()
}

///|
fn now_s() -> Double {
  @env.now().to_double() / 1000.0
}

///|
fn secs(x : Double) -> String {
  let t = (x * 10.0).round() / 10.0
  let s = t.to_string()
  if s.contains(".") {
    s
  } else {
    s + ".0"
  }
}

///|
priv struct SigningArgs {
  keystore : String
  key_alias : String
  ks_pass : String
  key_pass : String
  v3_signing : Bool
  verify_cert : String
}

///|
priv struct ResolvedSigning {
  keystore : String
  key_alias : String
  ks_pass : String
  key_pass : String
  v3_signing : Bool
  needs_debug_gen : Bool
}

///|
fn default_debug_keystore() -> String {
  @sys.join(@sys.getenv("ANDROID_USER_HOME").unwrap_or(@sys.join(home(), ".android")), "debug.keystore")
}

///|
fn valid_pass_spec(spec : String) -> Bool {
  spec.has_prefix("pass:") || spec.has_prefix("env:") || spec.has_prefix("file:")
}

///|
/// Validates and resolves signing arguments.
/// When an explicit `--keystore` path is given and does not exist, returns Err (never silently generates a debug key).
fn resolve_signing(s : SigningArgs, default_ks : String, ks_exists : Bool) -> Result[ResolvedSigning, String] {
  let explicit = s.keystore != ""
  let keystore = if explicit { s.keystore } else { default_ks }
  if explicit && !ks_exists {
    return Err("keystore not found: \{keystore}")
  }
  let key_alias = if s.key_alias != "" { s.key_alias } else { "androiddebugkey" }
  let ks_pass = if s.ks_pass != "" { s.ks_pass } else { "pass:android" }
  let key_pass = if s.key_pass != "" { s.key_pass } else { ks_pass }
  if !valid_pass_spec(ks_pass) {
    return Err("invalid --ks-pass spec (expected pass:, env:, or file:): \{ks_pass}")
  }
  if !valid_pass_spec(key_pass) {
    return Err("invalid --key-pass spec (expected pass:, env:, or file:): \{key_pass}")
  }
  Ok({
    keystore,
    key_alias,
    ks_pass,
    key_pass,
    v3_signing: s.v3_signing,
    needs_debug_gen: !explicit && !ks_exists,
  })
}

///|
/// Builds the `apksigner sign` shell command.
fn apksigner_sign_cmd(apksigner : String, r : ResolvedSigning, aligned : String, out : String) -> String {
  let v3 = if r.v3_signing { "true" } else { "false" }
  q(apksigner) + " sign --ks " + q(r.keystore) +
  " --ks-pass " + q(r.ks_pass) +
  " --ks-key-alias " + q(r.key_alias) +
  " --key-pass " + q(r.key_pass) +
  " --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled " + v3 +
  " --out " + q(out) + " " + q(aligned)
}

///|
/// Normalizes a SHA-256 fingerprint string: lowercase hex with colons and whitespace stripped.
fn normalize_sha256(s : String) -> String {
  let sb = StringBuilder()
  for c in s {
    if c == ':' || c == ' ' || c == '\t' || c == '\r' || c == '\n' {
      continue
    }
    if c >= 'A' && c <= 'F' {
      sb.write_char(Int::unsafe_to_char(c.to_int() - 'A'.to_int() + 'a'.to_int()))
    } else {
      sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
/// Extracts the signer certificate SHA-256 digest from `apksigner verify --print-certs` output.
fn extract_cert_sha256(verify_out : String) -> String? {
  let pat = rx("certificate SHA-256 digest:\\s*([0-9a-fA-F:]+)")
  match pat.search(verify_out) {
    Some(m) => Some(normalize_sha256(m.get(1)))
    None => None
  }
}

///|
/// Checks whether `apksigner verify --print-certs` output matches the expected SHA-256 fingerprint.
fn verify_cert_match(verify_out : String, expected : String) -> Result[String, String] {
  let want = normalize_sha256(expected)
  match extract_cert_sha256(verify_out) {
    Some(got) =>
      if got == want {
        Ok(got)
      } else {
        Err("certificate SHA-256 mismatch: expected \{want}, got \{got}")
      }
    None => Err("could not parse certificate SHA-256 digest from apksigner verify output")
  }
}

///|
/// Signs `aligned` into `out` and optionally verifies the signing certificate SHA-256 fingerprint.
fn sign_and_verify(bt : String, s : SigningArgs, aligned : String, out : String) -> Unit {
  let default_ks = default_debug_keystore()
  let ks_path = if s.keystore != "" { s.keystore } else { default_ks }
  let resolved = match resolve_signing(s, default_ks, @sys.exists(ks_path)) {
    Ok(r) => r
    Err(msg) => {
      die(msg)
      panic()
    }
  }
  if resolved.needs_debug_gen {
    // (no key given, as a branch's CI has none: a debug key of its own, as Gradle made one)
    @sys.makedirs(@sys.dirname(@sys.abspath(resolved.keystore)))
    ignore(
      sh(
        "keytool -genkeypair -keystore " + q(resolved.keystore) +
        " -storepass android -alias androiddebugkey -keypass android -keyalg RSA -validity 10000 -dname 'CN=Android Debug,O=Android,C=US'",
        "keytool",
      ),
    )
  }
  @sys.makedirs(@sys.dirname(@sys.abspath(out)))
  let apksigner = @sys.join(bt, "apksigner")
  ignore(sh(apksigner_sign_cmd(apksigner, resolved, aligned, out), "apksigner"))
  if s.verify_cert != "" {
    let vout = sh(q(apksigner) + " verify --print-certs " + q(out), "apksigner verify")
    match verify_cert_match(vout, s.verify_cert) {
      Ok(_) => ()
      Err(msg) => {
        ignore(@sys.remove(out))
        die(msg)
      }
    }
  }
}

///|
priv struct BuildArgs {
  app : String
  variant : String
  version_code : String
  version_name : String
  out : String
  abi : String
  signing : SigningArgs
  dex_only : Bool
}

///|
fn cmd_build(a : BuildArgs) -> Unit {
  let t0 = now_s()
  let times : Array[(String, Double)] = []
  let mut t = t0
  let lap = fn(what : String, since : Double) -> Double {
    let n = now_s()
    times.push((what, n - since))
    n
  }
  let (cfg, base) = load(a.app)
  let variant = match cfg.get("variants") {
    Some(v) =>
      match v.get(a.variant) {
        Some(x) => x
        None => {
          die("no variant \{a.variant} in \{a.app}")
          @rjson.Value::Null
        }
      }
    None => @rjson.Value::Null
  }
  let app_id = (match text_of(variant, "applicationId") {
      "" => text_of(cfg, "applicationId")
      own => own
    }) +
    text_of(variant, "applicationIdSuffix")
  let minify = flag_of(variant, "minify")
  let min_sdk = text_of(cfg, "minSdk")
  let (android_jar, bt) = sdk_tools(text_of(cfg, "compileSdk"))
  let aapt2 = @sys.join(bt, "aapt2")
  let work = sh("mktemp -d -t apk-XXXXXX", "mktemp").trim(chars=" \n").to_owned()
  // the dependencies: AARs unpacked (classes, their res), jars as they are
  let deps = read_lock(@sys.join(base, text_of(cfg, "lock"))).filter(fn(d) { d.1 != "" && d.1 != "none" })
  let jars : Array[String] = []
  let libs : Array[(String, String)] = []
  let rules : Array[String] = []
  for dep in deps {
    let (coord, ext, sha) = dep
    let p = match get_artifact(coord, ext, sha~) {
      Some(p) => p
      None => {
        die("\{coord}.\{ext}: not found")
        ""
      }
    }
    if ext == "jar" {
      jars.push(p)
      continue
    }
    let d = extract_aar(p, sha)
    libs.push((coord, d))
    let inner = [@sys.join(d, "classes.jar")]
    let ld = @sys.join(d, "libs")
    if @sys.is_dir(ld) {
      let names = @sys.list_dir(ld)
      names.sort_by(@rjson.str_cmp)
      for n in names {
        inner.push(@sys.join(ld, n))
      }
    }
    for j in inner {
      if @sys.exists(j) {
        jars.push(j)
      }
    }
    if @sys.exists(@sys.join(d, "proguard.txt")) {
      rules.push(@sys.join(d, "proguard.txt"))
    }
  }
  t = lap("dependencies", t)
  // resources: each library's compiled once (by its own content), the app's and the build's strings each time
  let strings = @sys.join(work, "strings")
  write_strings(cfg, strings)
  let compiled = []
  let lib_packages = []
  let pkg_rx = rx("package=\"([^\"]+)\"")
  for lib in libs {
    let d = lib.1
    let res = @sys.join(d, "res")
    if !@sys.is_dir(res) || @sys.list_dir(res).length() == 0 {
      continue
    }
    match pkg_rx.search(@sys.read_text(@sys.join(d, "AndroidManifest.xml")).unwrap_or("")) {
      Some(m) => lib_packages.push(m.get(1))
      None => ()
    }
    let out = @sys.join(cache_dir(), "flat/" + sub(tree_hash([res], work + "/flatkey"), 0, 24) + ".zip")
    if !@sys.exists(out) {
      @sys.makedirs(@sys.dirname(out))
      ignore(sh(q(aapt2) + " compile --dir " + q(res) + " -o " + q(out + ".tmp"), "aapt2 compile"))
      ignore(sh("mv -f " + q(out + ".tmp") + " " + q(out), "mv"))
    }
    compiled.push(out)
  }
  let app_flat = []
  // (the variant's own after the app's: linked as overlays, what it says again is its)
  let res_dirs = (texts_of(cfg, "res") + texts_of(variant, "res")).map(fn(r) { @sys.join(base, r) })
  res_dirs.push(strings)
  for i, res in res_dirs {
    if @sys.is_dir(res) {
      let out = @sys.join(work, "app\{i}.zip")
      ignore(sh(q(aapt2) + " compile --dir " + q(res) + " -o " + q(out), "aapt2 compile"))
      app_flat.push(out)
    }
  }
  t = lap("resources compiled", t)
  // the manifest, linked with everything: resources.arsc, res/, the binary manifest, R.java, the rules it keeps
  let man = @sys.join(work, "AndroidManifest.xml")
  ignore(@sys.write_text(man, manifest_text(cfg, base, variant, app_id, libs)))
  let gen = @sys.join(work, "gen")
  let ap = @sys.join(work, "res.ap_")
  let aapt_rules = @sys.join(work, "aapt_rules.txt")
  let mut link = q(aapt2) + " link -I " + q(android_jar) + " --manifest " + q(man) + " -o " + q(ap) + " --java " +
    q(gen) + " --proguard " + q(aapt_rules) + " --min-sdk-version " + min_sdk + " --target-sdk-version " +
    text_of(cfg, "targetSdk") + " --version-code " + a.version_code + " --version-name " + q(a.version_name) +
    " --custom-package " + q(text_of(cfg, "namespace")) + " --auto-add-overlay --no-version-vectors"
  if lib_packages.length() > 0 {
    let uniq = []
    for p in lib_packages {
      if !uniq.contains(p) {
        uniq.push(p)
      }
    }
    uniq.sort_by(@rjson.str_cmp)
    link = link + " --extra-packages " + q(uniq.join(":"))
  }
  for c in compiled {
    link = link + " -R " + q(c)
  }
  for c in app_flat {
    link = link + " -R " + q(c)
  }
  ignore(sh(link, "aapt2 link"))
  t = lap("linked", t)
  // dex: javac, then R8 (release) or D8, kept by what they are made of: the Java's sources (the app's and R's), the
  // dependencies, the rules, the tools (not the manifest: the build's number is in it); kept, neither runs
  let srcs = []
  let java_dirs = texts_of(cfg, "java").map(fn(j) { @sys.join(base, j) })
  java_dirs.push(gen)
  for d in java_dirs {
    for f in files_under(d) {
      if f.has_suffix(".java") {
        srcs.push(@sys.join(d, f))
      }
    }
  }
  let r8 = match get_artifact("com.android.tools:r8:\{r8_version}", "jar") {
    Some(p) => p
    None => {
      die("no R8 \{r8_version}")
      ""
    }
  }
  let all_rules = texts_of(cfg, "rules").map(fn(r) { @sys.join(base, r) }) + rules
  let default_rules = @sys.join(@sys.getenv("APK_HOME").unwrap_or("."), "apk-proguard-android-optimize.txt")
  // (aapt2's rules say where each came from: this build's own temporary paths, not what they keep)
  let kept = @sys.read_text(aapt_rules)
    .unwrap_or("")
    .split("\n")
    .filter(fn(l) { !l.trim(chars=" \t").has_prefix("#") })
    .map(fn(l) { l.to_owned() })
    .to_array()
    .join("\n")
  ignore(@sys.write_text(aapt_rules, kept))
  let key = []
  key.push("\{r8_version} \{minify} \{min_sdk} \{a.variant} \{@sys.getenv("JAVA_HOME").unwrap_or("")}")
  for p in srcs {
    key.push(@sys.basename(p) + " " + sha256_file(p))
  }
  for p in jars + all_rules + [default_rules, android_jar] {
    key.push(sha256_file(p))
  }
  key.push(kept)
  let dex_dir = @sys.join(cache_dir(), "dex/" + sub(sha256_text(key.join("\n"), work + "/dexkey"), 0, 32))
  if !@sys.exists(@sys.join(dex_dir, ".done")) {
    let classes = @sys.join(work, "classes")
    @sys.makedirs(classes)
    ignore(@sys.write_text(@sys.join(work, "srcs.txt"), srcs.join("\n")))
    let cp = ([android_jar] + jars).join(":")
    ignore(
      sh(
        "javac -nowarn -encoding UTF-8 -source 17 -target 17 -Xlint:-options -cp " + q(cp) + " -d " + q(classes) + " @" +
        q(@sys.join(work, "srcs.txt")),
        "javac",
      ),
    )
    t = lap("javac", t)
    ignore(try_sh("rm -rf " + q(dex_dir)))
    @sys.makedirs(dex_dir)
    let jar_in = @sys.join(work, "app-classes.jar")
    ignore(sh("cd " + q(classes) + " && find . -type f | LC_ALL=C sort | zip -q -X " + q(jar_in) + " -@", "zip classes"))
    let cmd = if minify {
      "java -cp " + q(r8) + " com.android.tools.r8.R8 --release --min-api " + min_sdk + " --lib " + q(android_jar) +
      " --output " + q(dex_dir) + " --pg-conf " + q(default_rules) + " --pg-conf " + q(aapt_rules) +
      " --pg-map-output " + q(@sys.join(dex_dir, "mapping.txt")) +
      all_rules.map(fn(r) { " --pg-conf " + q(r) }).join("") + " " + q(jar_in) + " " + jars.map(q).join(" ")
    } else {
      // (debug: the app's own classes alone, the dependencies on their classpath: they are dexed apart, below)
      "java -cp " + q(r8) + " com.android.tools.r8.D8 --debug --min-api " + min_sdk + " --lib " + q(android_jar) +
      " --output " + q(dex_dir) + " " + q(jar_in) + jars.map(fn(j) { " --classpath " + q(j) }).join("")
    }
    ignore(sh(cmd, if minify { "r8" } else { "d8" }))
    ignore(@sys.write_text(@sys.join(dex_dir, ".done"), ""))
    t = lap(if minify { "r8" } else { "d8" }, t)
  } else {
    ignore(try_sh("touch " + q(dex_dir)))
    t = lap("dex (kept)", t)
  }
  // a debug build's dependencies: each dexed once, by its own bytes (the lock's), side by side with the app's
  // (classes2.dex on: minSdk 29 loads them all), as Gradle's debug builds dex each library apart
  let dexes = dex_names(dex_dir)
  if !minify {
    for j in jars {
      let d = lib_dex(r8, android_jar, min_sdk, j, jars.filter(fn(x) { x != j }), work)
      for x in dex_names(d) {
        dexes.push(x)
      }
    }
    t = lap("dependencies dexed", t)
  }
  // (--dex-only: no further: its dex is kept, and the build after it, with the app's native libraries and assets
  // made meanwhile, finds it there)
  if a.dex_only {
    ignore(try_sh("rm -rf " + q(work)))
    say("dex of \{a.variant} in \{secs(now_s() - t0)} s: " + times.map(fn(x) { "\{x.0} \{secs(x.1)} s" }).join(", "))
    return
  }
  // the APK: what aapt2 linked, the dex (stored), the native libraries (compressed), the assets, the jars' resources
  let unsigned = @sys.join(work, "unsigned.apk")
  ignore(sh("cp " + q(ap) + " " + q(unsigned), "cp"))
  let stage = @sys.join(work, "stage")
  @sys.makedirs(stage)
  for i, p in dexes {
    let n = if i == 0 { "classes.dex" } else { "classes\{i + 1}.dex" }
    ignore(sh("cp " + q(p) + " " + q(@sys.join(stage, n)), "cp"))
  }
  let dex_files = []
  for i, _ in dexes {
    dex_files.push(if i == 0 { "classes.dex" } else { "classes\{i + 1}.dex" })
  }
  ignore(sh("cd " + q(stage) + " && zip -q -X -0 " + q(unsigned) + " " + dex_files.join(" "), "zip dex"))
  let packed = @sys.join(work, "packed")
  @sys.makedirs(packed)
  for jd in texts_of(cfg, "jniLibs").map(fn(x) { @sys.join(base, x) }) {
    let abis = if a.abi != "" {
      [a.abi]
    } else if @sys.is_dir(jd) {
      let l = @sys.list_dir(jd)
      l.sort_by(@rjson.str_cmp)
      l
    } else {
      []
    }
    for abi in abis {
      let ad = @sys.join(jd, abi)
      if @sys.is_dir(ad) {
        let names = @sys.list_dir(ad)
        names.sort_by(@rjson.str_cmp)
        for n in names {
          if n.has_suffix(".so") {
            @sys.makedirs(@sys.join(packed, "lib/" + abi))
            ignore(sh("cp " + q(stripped(@sys.join(ad, n))) + " " + q(@sys.join(packed, "lib/\{abi}/\{n}")), "cp"))
          }
        }
      }
    }
  }
  for asd in texts_of(cfg, "assets").map(fn(x) { @sys.join(base, x) }) {
    if @sys.is_dir(asd) {
      @sys.makedirs(@sys.join(packed, "assets"))
      ignore(sh("cp -R " + q(asd) + "/. " + q(@sys.join(packed, "assets")), "cp assets"))
    }
  }
  // the jars' Kotlin builtins and version files, the first of each name (what the app's own linking did not put)
  for j in jars {
    ignore(try_sh("unzip -n -q " + q(j) + " '*.kotlin_builtins' 'META-INF/*.version' -d " + q(packed)))
  }
  if files_under(packed).length() > 0 {
    ignore(sh("cd " + q(packed) + " && find . -type f | LC_ALL=C sort | zip -q -X " + q(unsigned) + " -@", "zip"))
  }
  t = lap("packed", t)
  let to_align = match delta_classes(srcs, work) {
    "" => unsigned
    classes => {
      let repacked = @sys.join(work, "repacked.apk")
      ignore(sh("java -cp " + q(classes) + " dev.mbui.Delta repack " + q(unsigned) + " " + q(repacked), "repack"))
      t = lap("repacked", t)
      repacked
    }
  }
  let aligned = @sys.join(work, "aligned.apk")
  ignore(sh(q(@sys.join(bt, "zipalign")) + " -P 16 -f 4 " + q(to_align) + " " + q(aligned), "zipalign"))
  sign_and_verify(bt, a.signing, aligned, a.out)
  ignore(lap("signed", t))
  ignore(try_sh("rm -rf " + q(work)))
  prune()
  let size = sh("wc -c < " + q(a.out), "wc").trim(chars=" \n\t")
  say(
    "\{a.out}: \{size} bytes in \{secs(now_s() - t0)} s: " + times.map(fn(x) { "\{x.0} \{secs(x.1)} s" }).join(", "),
  )
}

// ── repack ─────────────────────────────────────────────────────────────

///|
priv struct ApkMeta {
  pkg : String
  version_code : String
  version_name : String
  min_sdk : String
  target_sdk : String
  label : String
  java_ns : String
  permissions : Array[String]
}

///|
/// Extracts `key='value'` from a single line of `aapt2 dump badging`.
fn badging_attr(line : String, key : String) -> String {
  let needle = key + "='"
  match line.find(needle) {
    None => ""
    Some(i) => {
      let start = i + needle.length()
      let rest = sub(line, start, line.length())
      match rest.find("'") {
        Some(end) => sub(rest, 0, end)
        None => ""
      }
    }
  }
}

///|
/// Parses `aapt2 dump badging` output into metadata used as defaults for `apk repack`.
fn parse_badging(badging : String) -> ApkMeta {
  let mut pkg = ""
  let mut version_code = "1"
  let mut version_name = "0.1.1"
  let mut min_sdk = "30"
  let mut target_sdk = "36"
  let mut label = ""
  let mut java_ns = "dev.mbui"
  let permissions : Array[String] = []
  for raw in badging.split("\n") {
    let line = raw.trim(chars=" \t\r").to_owned()
    if line.has_prefix("package:") {
      let n = badging_attr(line, "name")
      if n != "" {
        pkg = n
      }
      let vc = badging_attr(line, "versionCode")
      if vc != "" {
        version_code = vc
      }
      let vn = badging_attr(line, "versionName")
      if vn != "" {
        version_name = vn
      }
    } else if line.has_prefix("sdkVersion:'") && line.has_suffix("'") {
      min_sdk = sub(line, 12, line.length() - 1)
    } else if line.has_prefix("targetSdkVersion:'") && line.has_suffix("'") {
      target_sdk = sub(line, 18, line.length() - 1)
    } else if line.has_prefix("application-label:'") && line.has_suffix("'") {
      label = sub(line, 19, line.length() - 1)
    } else if line.has_prefix("launchable-activity:") {
      let cls = badging_attr(line, "name")
      match cls.rev_find(".") {
        Some(dot) => java_ns = sub(cls, 0, dot)
        None => ()
      }
    } else if line.has_prefix("uses-permission:") {
      let p = badging_attr(line, "name")
      if p != "" && !permissions.contains(p) {
        permissions.push(p)
      }
    }
  }
  { pkg, version_code, version_name, min_sdk, target_sdk, label, java_ns, permissions }
}

///|
/// Whether a manifest XML references non-framework (`@<type>/...` other than `@android:...`) resources.
fn manifest_uses_app_res(xml : String) -> Bool {
  rx("@(?!android:)[a-zA-Z0-9_\\.]+/[a-zA-Z0-9_\\.]+").search(xml) is Some(_)
}

///|
/// Original `<application>` attributes and `dev.mbui.*` `<meta-data>` extracted from `aapt2 dump xmltree`.
priv struct XmltreeAppAttrs {
  app_component_factory : String?
  debuggable : Bool?
  edge_to_edge : Bool?
  ground : String?
  env : String?
}

///|
fn leading_spaces(s : String) -> Int {
  let mut n = 0
  for c in s {
    if c == ' ' {
      n += 1
    } else {
      break
    }
  }
  n
}

///|
/// Extracts the attribute value from an `aapt2 dump xmltree` `A: ...=...` line.
fn xmltree_attr_value(line : String) -> String? {
  let rhs = match line.find(")=") {
    Some(i) => sub(line, i + 2, line.length())
    None =>
      match line.find("=") {
        Some(i) => sub(line, i + 1, line.length())
        None => return None
      }
  }
  if rhs.has_prefix("\"") {
    let cs = rhs.to_array()
    let sb = StringBuilder()
    let mut i = 1
    while i < cs.length() {
      let c = cs[i]
      if c == '\\' && i + 1 < cs.length() {
        let next = cs[i + 1]
        match next {
          'n' => sb.write_char('\n')
          't' => sb.write_char('\t')
          '\\' => sb.write_char('\\')
          '"' => sb.write_char('"')
          _ => sb.write_char(next)
        }
        i += 2
        continue
      }
      if c == '"' {
        return Some(sb.to_string())
      }
      sb.write_char(c)
      i += 1
    }
    Some(sb.to_string())
  } else {
    let trimmed = rhs.trim(chars=" \t\r").to_owned()
    if trimmed == "" {
      None
    } else {
      Some(trimmed)
    }
  }
}

///|
fn xmltree_bool(v : String) -> Bool? {
  if v == "true" || v == "(type 0x12)0xffffffff" || v == "(type 0x12)0x1" {
    Some(true)
  } else if v == "false" || v == "(type 0x12)0x0" {
    Some(false)
  } else {
    None
  }
}

///|
/// Parses `aapt2 dump xmltree <in.apk> --file AndroidManifest.xml` to preserve `<application>`'s
/// `appComponentFactory`, `debuggable`, and `dev.mbui.edge` / `dev.mbui.ground` / `dev.mbui.env` meta-data.
fn parse_xmltree_app_attrs(xmltree : String) -> XmltreeAppAttrs {
  let mut app_indent = -1
  let mut app_child_indent = -1
  let mut in_app_attrs = false
  let mut in_meta = false
  let mut meta_indent = -1
  let mut meta_name = ""
  let mut meta_val = ""
  let mut app_component_factory : String? = None
  let mut debuggable : Bool? = None
  let mut edge_to_edge : Bool? = None
  let mut ground : String? = None
  let mut env : String? = None
  let flush_meta = fn() {
    if in_meta && meta_name != "" && meta_val != "" {
      if meta_name == "dev.mbui.edge" {
        edge_to_edge = xmltree_bool(meta_val)
      } else if meta_name == "dev.mbui.ground" {
        ground = Some(meta_val)
      } else if meta_name == "dev.mbui.env" {
        env = Some(meta_val)
      }
    }
    in_meta = false
    meta_indent = -1
    meta_name = ""
    meta_val = ""
  }
  for raw in xmltree.split("\n") {
    let s = raw.to_owned()
    let indent = leading_spaces(s)
    let line = s.trim(chars=" \t\r").to_owned()
    if line == "" {
      continue
    }
    if in_meta && indent <= meta_indent {
      flush_meta()
    }
    if app_indent >= 0 && indent <= app_indent && line.has_prefix("E:") {
      app_indent = -1
      app_child_indent = -1
      in_app_attrs = false
    }
    if line.has_prefix("E: application ") || line == "E: application" {
      app_indent = indent
      app_child_indent = -1
      in_app_attrs = true
      continue
    }
    if app_indent >= 0 {
      if line.has_prefix("E: ") {
        in_app_attrs = false
        if app_child_indent < 0 && indent > app_indent {
          app_child_indent = indent
        }
        if indent == app_child_indent && (line.has_prefix("E: meta-data ") || line == "E: meta-data") {
          in_meta = true
          meta_indent = indent
          meta_name = ""
          meta_val = ""
        }
        continue
      }
      if in_app_attrs && indent > app_indent && line.has_prefix("A: ") {
        if line.contains(":appComponentFactory(") || line.contains(":appComponentFactory=") {
          match xmltree_attr_value(line) {
            Some(v) if v != "" => app_component_factory = Some(v)
            _ => ()
          }
        } else if line.contains(":debuggable(") || line.contains(":debuggable=") {
          match xmltree_attr_value(line) {
            Some(v) => debuggable = xmltree_bool(v)
            None => ()
          }
        }
      } else if in_meta && indent > meta_indent && line.has_prefix("A: ") {
        if line.contains(":name(") || line.contains(":name=") {
          meta_name = xmltree_attr_value(line).unwrap_or("")
        } else if line.contains(":value(") || line.contains(":value=") {
          meta_val = xmltree_attr_value(line).unwrap_or("")
        }
      }
    }
  }
  flush_meta()
  { app_component_factory, debuggable, edge_to_edge, ground, env }
}

///|
priv struct RepackArgs {
  input : String
  out : String
  app_id : String
  label : String?
  version_code : String
  version_name : String
  env : String?
  edge_to_edge : Bool?
  ground : String?
  debuggable : Bool?
  url_schemes : Array[String]
  permissions : Array[String]
  manifest : String
  signing : SigningArgs
}

///|
fn cmd_repack(a : RepackArgs) -> Unit {
  let t0 = now_s()
  if !@sys.exists(a.input) {
    die("input APK not found: \{a.input}")
  }
  let bt = newest_build_tools()
  let aapt2 = @sys.join(bt, "aapt2")
  let android_jar = newest_android_jar()
  let work = sh("mktemp -d -t apk-repack-XXXXXX", "mktemp").trim(chars=" \n").to_owned()
  let badging = sh(q(aapt2) + " dump badging " + q(a.input), "aapt2 dump badging")
  let meta = parse_badging(badging)
  let xmltree = try_sh(q(aapt2) + " dump xmltree " + q(a.input) + " --file AndroidManifest.xml").unwrap_or("")
  let orig_attrs = parse_xmltree_app_attrs(xmltree)
  let pkg_dump = try_sh(q(aapt2) + " dump packagename " + q(a.input))
    .unwrap_or("")
    .trim(chars=" \t\r\n")
    .to_owned()
  let orig_pkg = if pkg_dump != "" { pkg_dump } else { meta.pkg }
  let app_id = if a.app_id != "" { a.app_id } else { orig_pkg }
  if app_id == "" {
    die("could not determine application id; pass --app-id")
  }
  let vc = if a.version_code != "" { a.version_code } else { meta.version_code }
  let vn = if a.version_name != "" { a.version_name } else { meta.version_name }
  let mfile = if a.manifest == "" || a.manifest == "@mbui" {
    @sys.join(@sys.getenv("APK_HOME").unwrap_or("."), "../android/app/src/main/AndroidManifest.xml")
  } else {
    a.manifest
  }
  let mut text = @sys.read_text(mfile).unwrap_or("")
  if text == "" {
    die("manifest not found or empty: \{mfile}")
  }
  text = text.replace_all(old="${applicationId}", new=app_id)
  let left = rx("\\$\\{(\\w+)\\}").findall(text)
  if left.length() > 0 {
    let names = left.join(", ")
    die("manifest placeholders not given: [\{names}]")
  }
  let ns = meta.java_ns
  text = rx("(<(?:application|activity|activity-alias|service|receiver|provider)\\b[^>]*?android:name=\")\\.").sub_with(
    text,
    fn(m) { m.get(1) + ns + "." },
  )
  text = rx("\\s+tools:\\w+=\"[^\"]*\"").sub(text, "")
  text = rx("\\s+xmlns:tools=\"[^\"]*\"").sub(text, "")
  match rx("<application\\b[^>]*").search(text) {
    Some(m) => {
      if !m.get(0).contains("android:extractNativeLibs=") {
        text = sub(text, 0, m.end()) + " android:extractNativeLibs=\"true\"" + sub(text, m.end(), text.length())
      }
    }
    None => die("no <application> in the manifest")
  }
  // Preserve appComponentFactory from original APK unless the template already specifies one.
  match orig_attrs.app_component_factory {
    Some(factory) =>
      if !text.contains("android:appComponentFactory=") {
        text = set_application_attr(text, "appComponentFactory", Some(factory))
      }
    None => ()
  }
  // Preserve debuggable from original APK unless explicitly overridden via --debuggable true|false.
  let eff_debuggable = match a.debuggable {
    Some(b) => Some(b)
    None => orig_attrs.debuggable
  }
  match eff_debuggable {
    Some(true) => text = set_application_attr(text, "debuggable", Some("true"))
    Some(false) => text = set_application_attr(text, "debuggable", None)
    None => ()
  }
  text = set_manifest_package(text, app_id)
  let eff_label = match a.label {
    Some(l) => Some(l)
    None => if a.manifest == "" && meta.label != "" { Some(meta.label) } else { None }
  }
  let eff_edge = match a.edge_to_edge {
    Some(b) => Some(b)
    None => orig_attrs.edge_to_edge
  }
  let eff_ground = match a.ground {
    Some(g) => Some(g)
    None => orig_attrs.ground
  }
  let eff_env = match a.env {
    Some(e) => Some(e)
    None => orig_attrs.env
  }
  let eff_perms = dedup_strings(meta.permissions + a.permissions)
  text = apply_manifest_overrides(text, {
    label: eff_label,
    edge_to_edge: eff_edge,
    ground: eff_ground,
    env: eff_env,
    url_schemes: a.url_schemes,
    permissions: eff_perms,
  })
  let man = @sys.join(work, "AndroidManifest.xml")
  ignore(@sys.write_text(man, text))
  let man_ap = @sys.join(work, "manifest.ap_")
  let extra_inc = if manifest_uses_app_res(text) { " -I " + q(a.input) } else { "" }
  ignore(
    sh(
      q(aapt2) + " link -I " + q(android_jar) + extra_inc + " --manifest " + q(man) + " -o " + q(man_ap) +
      " --min-sdk-version " + meta.min_sdk + " --target-sdk-version " + meta.target_sdk +
      " --version-code " + vc + " --version-name " + q(vn) + " --no-version-vectors",
      "aapt2 link (repack)",
    ),
  )
  let stage = @sys.join(work, "stage")
  @sys.makedirs(stage)
  ignore(sh("unzip -q -o " + q(man_ap) + " AndroidManifest.xml -d " + q(stage), "unzip manifest"))
  let unsigned = @sys.join(work, "unsigned.apk")
  ignore(sh("cp " + q(a.input) + " " + q(unsigned), "cp"))
  // Strip any existing v1 signature files so apksigner signs cleanly.
  ignore(
    try_sh(
      "zip -q -d " + q(unsigned) +
      " 'META-INF/*.SF' 'META-INF/*.RSA' 'META-INF/*.EC' 'META-INF/*.DSA' 'META-INF/MANIFEST.MF'",
    ),
  )
  ignore(sh("cd " + q(stage) + " && zip -q -X " + q(unsigned) + " AndroidManifest.xml", "zip manifest"))
  let aligned = @sys.join(work, "aligned.apk")
  ignore(sh(q(@sys.join(bt, "zipalign")) + " -P 16 -f 4 " + q(unsigned) + " " + q(aligned), "zipalign"))
  sign_and_verify(bt, a.signing, aligned, a.out)
  ignore(try_sh("rm -rf " + q(work)))
  let size = sh("wc -c < " + q(a.out), "wc").trim(chars=" \n\t")
  say("\{a.out}: \{size} bytes repacked in \{secs(now_s() - t0)} s")
}

///|
fn parse_opt(rest : Array[String], name : String, default : String) -> String {
  for i, x in rest {
    if x == name && i + 1 < rest.length() {
      return rest[i + 1]
    }
  }
  default
}

///|
fn parse_opt_some(rest : Array[String], name : String) -> String? {
  for i, x in rest {
    if x == name && i + 1 < rest.length() {
      return Some(rest[i + 1])
    }
  }
  None
}

///|
fn parse_opt_many(rest : Array[String], name : String) -> Array[String] {
  let out : Array[String] = []
  for i, x in rest {
    if x == name && i + 1 < rest.length() {
      for part in rest[i + 1].split(",") {
        let s = part.trim(chars=" \t").to_owned()
        if s != "" {
          out.push(s)
        }
      }
    }
  }
  out
}

///|
fn parse_signing_args(rest : Array[String]) -> SigningArgs {
  {
    keystore: parse_opt(rest, "--keystore", ""),
    key_alias: parse_opt(rest, "--key-alias", ""),
    ks_pass: parse_opt(rest, "--ks-pass", ""),
    key_pass: parse_opt(rest, "--key-pass", ""),
    v3_signing: rest.contains("--v3-signing"),
    verify_cert: parse_opt(rest, "--verify-cert", ""),
  }
}

///|
fn usage() -> Int {
  @sys.eprintln(
    "apk: lock APP.json | build APP.json --variant V --version-code N --version-name S --out APK [--abi A] [--keystore K] [--key-alias A] [--ks-pass SPEC] [--key-pass SPEC] [--v3-signing] [--verify-cert SHA256] [--dex-only] | repack IN.apk --out OUT.apk [--app-id ID] [--label NAME] [--version-code N] [--version-name S] [--env K=V;...] [--edge-to-edge true|false] [--ground C] [--debuggable true|false] [--url-scheme S] [--permission P] [--manifest PATH] [--keystore K] [--key-alias A] [--ks-pass SPEC] [--key-pass SPEC] [--v3-signing] [--verify-cert SHA256] | fetch PATH SHA256",
  )
  2
}

///|
fn main {
  let args = @env.args()[1:].to_owned()
  let code = match args {
    ["lock", app] => {
      cmd_lock(app)
      0
    }
    ["fetch", path, sha] => {
      cmd_fetch(path, sha)
      0
    }
    ["build", app, .. rest] => {
      let rest_arr = rest.to_owned()
      let out = parse_opt(rest_arr, "--out", "")
      if out == "" {
        usage()
      } else {
        cmd_build({
          app,
          variant: parse_opt(rest_arr, "--variant", "debug"),
          version_code: parse_opt(rest_arr, "--version-code", "1"),
          version_name: parse_opt(rest_arr, "--version-name", "0.1.1"),
          out,
          abi: parse_opt(rest_arr, "--abi", ""),
          signing: parse_signing_args(rest_arr),
          dex_only: rest_arr.contains("--dex-only"),
        })
        0
      }
    }
    ["repack", input, .. rest] => {
      let rest_arr = rest.to_owned()
      let out = parse_opt(rest_arr, "--out", "")
      if out == "" {
        usage()
      } else {
        let edge_to_edge = match parse_opt_some(rest_arr, "--edge-to-edge") {
          Some("true") => Some(true)
          Some("false") => Some(false)
          Some(other) => {
            die("invalid --edge-to-edge value (expected true or false): \{other}")
            None
          }
          None => None
        }
        let debuggable = match parse_opt_some(rest_arr, "--debuggable") {
          Some("true") => Some(true)
          Some("false") => Some(false)
          Some(other) => {
            die("invalid --debuggable value (expected true or false): \{other}")
            None
          }
          None => None
        }
        let url_schemes = parse_opt_many(rest_arr, "--url-scheme") + parse_opt_many(rest_arr, "--url-schemes")
        let permissions = parse_opt_many(rest_arr, "--permission") + parse_opt_many(rest_arr, "--permissions")
        cmd_repack({
          input,
          out,
          app_id: parse_opt(rest_arr, "--app-id", ""),
          label: parse_opt_some(rest_arr, "--label"),
          version_code: parse_opt(rest_arr, "--version-code", ""),
          version_name: parse_opt(rest_arr, "--version-name", ""),
          env: parse_opt_some(rest_arr, "--env"),
          edge_to_edge,
          ground: parse_opt_some(rest_arr, "--ground"),
          debuggable,
          url_schemes,
          permissions,
          manifest: parse_opt(rest_arr, "--manifest", ""),
          signing: parse_signing_args(rest_arr),
        })
        0
      }
    }
    _ => usage()
  }
  @sys.exit(code)
}
