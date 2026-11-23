///|
test "xml_escape escapes all XML attribute special characters" {
  assert_eq(xml_escape("A & B <C> \"D\" 'E'"), "A &amp; B &lt;C&gt; &quot;D&quot; &apos;E&apos;")
  assert_eq(xml_escape("plain_text-123"), "plain_text-123")
}

///|
test "serialize_env_pairs sorts keys deterministically" {
  let s = serialize_env_pairs([("Z_KEY", "3"), ("A_KEY", "1"), ("M_KEY", "2")])
  assert_eq(s, "A_KEY=1;M_KEY=2;Z_KEY=3")
}

///|
test "overrides_from_json merges top-level and variant fields" {
  let cfg = @rjson.parse(
    "{\"label\":\"Base App\",\"edgeToEdge\":true,\"ground\":\"#FFFFFF,#111111\",\"env\":{\"API\":\"https://a.example?x=1&y=2\",\"MODE\":\"base\",\"NUM\":42},\"urlSchemes\":[\"myapp\",\"shared\"],\"permissions\":[\"android.permission.CAMERA\",\"android.permission.INTERNET\"]}",
  ) catch {
    _ => panic()
  }
  let variant = @rjson.parse(
    "{\"label\":\"Beta App\",\"env\":{\"MODE\":\"beta\",\"DEBUG\":true},\"urlSchemes\":[\"shared\",\"myapp-beta\"],\"permissions\":[\"android.permission.CAMERA\",\"android.permission.VIBRATE\"]}",
  ) catch {
    _ => panic()
  }
  let o = overrides_from_json(cfg, variant)
  assert_eq(o.label, Some("Beta App"))
  assert_eq(o.edge_to_edge, Some(true))
  assert_eq(o.ground, Some("#FFFFFF,#111111"))
  assert_eq(o.env, Some("API=https://a.example?x=1&y=2;DEBUG=true;MODE=beta;NUM=42"))
  assert_eq(o.url_schemes, ["myapp", "shared", "myapp-beta"])
  assert_eq(o.permissions, ["android.permission.CAMERA", "android.permission.INTERNET", "android.permission.VIBRATE"])
}

///|
test "legacy apk.json without declarative fields leaves manifest unchanged" {
  let cfg = @rjson.parse(
    "{\"namespace\":\"dev.mbui\",\"applicationId\":\"dev.mbui.demo\",\"manifest\":\"app/src/main/AndroidManifest.xml\"}",
  ) catch {
    _ => panic()
  }
  let variant = @rjson.parse("{\"debuggable\":true,\"placeholders\":{}}") catch { _ => panic() }
  let sample =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<manifest package="dev.mbui.demo" xmlns:android="http://schemas.android.com/apk/res/android">
    #|    <uses-permission android:name="android.permission.INTERNET" />
    #|    <application android:label="MoonBit UI">
    #|        <activity android:name="dev.mbui.MainActivity" android:exported="true">
    #|            <intent-filter>
    #|                <action android:name="android.intent.action.MAIN" />
    #|                <category android:name="android.intent.category.LAUNCHER" />
    #|            </intent-filter>
    #|        </activity>
    #|    </application>
    #|</manifest>
  let out = apply_manifest_overrides(sample, overrides_from_json(cfg, variant))
  assert_eq(out, sample)
}

///|
test "apply_manifest_overrides injects label, meta-data, urlSchemes, and deduped permissions" {
  let sample =
    #|<?xml version="1.0" encoding="utf-8"?>
    #|<manifest package="dev.example.app" xmlns:android="http://schemas.android.com/apk/res/android">
    #|    <uses-permission android:name="android.permission.INTERNET" />
    #|    <application android:label="Old Label" android:hasCode="true">
    #|        <activity android:name="dev.mbui.MainActivity" android:exported="true">
    #|            <intent-filter>
    #|                <action android:name="android.intent.action.MAIN" />
    #|                <category android:name="android.intent.category.LAUNCHER" />
    #|            </intent-filter>
    #|            <intent-filter>
    #|                <action android:name="android.intent.action.VIEW" />
    #|                <category android:name="android.intent.category.DEFAULT" />
    #|                <category android:name="android.intent.category.BROWSABLE" />
    #|                <data android:scheme="dev.example.app" android:host="back" />
    #|            </intent-filter>
    #|        </activity>
    #|    </application>
    #|</manifest>
  let out = apply_manifest_overrides(sample, {
    label: Some("My & \"Cool\" App"),
    edge_to_edge: Some(true),
    ground: Some("#FFFFFF,#1B1C1F"),
    env: Some("A=1&2;B=<tag>"),
    url_schemes: ["myapp", "myapp", "dev.example.app"],
    permissions: ["android.permission.INTERNET", "android.permission.CAMERA", "android.permission.CAMERA"],
  })
  assert_true(out.contains("android:label=\"My &amp; &quot;Cool&quot; App\""))
  assert_false(out.contains("Old Label"))
  assert_true(out.contains("<meta-data android:name=\"dev.mbui.edge\" android:value=\"true\" />"))
  assert_true(out.contains("<meta-data android:name=\"dev.mbui.ground\" android:value=\"#FFFFFF,#1B1C1F\" />"))
  assert_true(out.contains("<meta-data android:name=\"dev.mbui.env\" android:value=\"A=1&amp;2;B=&lt;tag&gt;\" />"))
  assert_true(out.contains("<data android:scheme=\"myapp\" />"))
  assert_true(out.contains("<data android:scheme=\"dev.example.app\" />"))
  assert_true(out.contains("<uses-permission android:name=\"android.permission.CAMERA\" />"))
  // INTERNET was already present and must not be duplicated
  assert_eq(rx("android\\.permission\\.INTERNET").find_all(out).length(), 1)
  assert_eq(rx("android\\.permission\\.CAMERA").find_all(out).length(), 1)
  // Re-applying with updated meta-data replaces in place rather than duplicating
  let out2 = apply_manifest_overrides(out, {
    label: Some("Updated"),
    edge_to_edge: Some(false),
    ground: None,
    env: Some("K=V"),
    url_schemes: ["myapp"],
    permissions: ["android.permission.CAMERA"],
  })
  assert_true(out2.contains("android:label=\"Updated\""))
  assert_eq(rx("dev\\.mbui\\.edge").find_all(out2).length(), 1)
  assert_true(out2.contains("<meta-data android:name=\"dev.mbui.edge\" android:value=\"false\" />"))
  assert_eq(rx("dev\\.mbui\\.env").find_all(out2).length(), 1)
  assert_true(out2.contains("<meta-data android:name=\"dev.mbui.env\" android:value=\"K=V\" />"))
  assert_eq(rx("android:scheme=\"myapp\"").find_all(out2).length(), 1)
}

///|
test "resolve_manifest_path falls back to @mbui default when omitted or @mbui" {
  let empty_cfg = @rjson.parse("{}") catch { _ => panic() }
  let at_cfg = @rjson.parse("{\"manifest\":\"@mbui\"}") catch { _ => panic() }
  let custom_cfg = @rjson.parse("{\"manifest\":\"custom/AndroidManifest.xml\"}") catch { _ => panic() }
  assert_eq(resolve_manifest_path(empty_cfg, "/proj", "/mbui/scripts"), "/mbui/scripts/../android/app/src/main/AndroidManifest.xml")
  assert_eq(resolve_manifest_path(at_cfg, "/proj", "/mbui/scripts"), "/mbui/scripts/../android/app/src/main/AndroidManifest.xml")
  assert_eq(resolve_manifest_path(custom_cfg, "/proj", "/mbui/scripts"), "/proj/custom/AndroidManifest.xml")
}

///|
test "resolve_signing rejects missing explicit keystore and supports release options" {
  let missing = resolve_signing(
    { keystore: "/path/to/missing.jks", key_alias: "rel", ks_pass: "pass:secret", key_pass: "", v3_signing: false, verify_cert: "" },
    "/home/.android/debug.keystore",
    false,
  )
  assert_true(missing is Err(_))

  let default_missing = resolve_signing(
    { keystore: "", key_alias: "", ks_pass: "", key_pass: "", v3_signing: false, verify_cert: "" },
    "/home/.android/debug.keystore",
    false,
  )
  match default_missing {
    Ok(r) => {
      assert_eq(r.keystore, "/home/.android/debug.keystore")
      assert_eq(r.key_alias, "androiddebugkey")
      assert_eq(r.ks_pass, "pass:android")
      assert_eq(r.key_pass, "pass:android")
      assert_eq(r.v3_signing, false)
      assert_eq(r.needs_debug_gen, true)
    }
    Err(e) => fail("unexpected error: \{e}")
  }

  let release_ok = resolve_signing(
    { keystore: "/keys/prod.jks", key_alias: "prod", ks_pass: "env:KS_PASS", key_pass: "", v3_signing: true, verify_cert: "" },
    "/home/.android/debug.keystore",
    true,
  )
  match release_ok {
    Ok(r) => {
      assert_eq(r.keystore, "/keys/prod.jks")
      assert_eq(r.key_alias, "prod")
      assert_eq(r.ks_pass, "env:KS_PASS")
      assert_eq(r.key_pass, "env:KS_PASS")
      assert_eq(r.v3_signing, true)
      assert_eq(r.needs_debug_gen, false)
      let cmd = apksigner_sign_cmd("/sdk/apksigner", r, "/tmp/in.apk", "/tmp/out.apk")
      assert_true(cmd.contains("--ks '/keys/prod.jks'"))
      assert_true(cmd.contains("--ks-key-alias 'prod'"))
      assert_true(cmd.contains("--ks-pass 'env:KS_PASS'"))
      assert_true(cmd.contains("--key-pass 'env:KS_PASS'"))
      assert_true(cmd.contains("--v3-signing-enabled true"))
    }
    Err(e) => fail("unexpected error: \{e}")
  }

  let bad_pass = resolve_signing(
    { keystore: "/keys/prod.jks", key_alias: "prod", ks_pass: "rawsecret", key_pass: "", v3_signing: false, verify_cert: "" },
    "/home/.android/debug.keystore",
    true,
  )
  assert_true(bad_pass is Err(_))
}

///|
test "verify_cert_match normalizes and checks SHA-256 fingerprint" {
  let out =
    #|Signer #1 certificate DN: CN=Release, O=Example, C=US
    #|Signer #1 certificate SHA-256 digest: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    #|Signer #1 certificate SHA-1 digest: deadbeef
  let ok = verify_cert_match(
    out,
    "01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF",
  )
  assert_true(ok is Ok(_))
  let bad = verify_cert_match(out, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
  assert_true(bad is Err(_))
  let none = verify_cert_match("no certs here", "0123")
  assert_true(none is Err(_))
}

///|
test "parse_badging extracts package, versions, sdk, label, namespace, and permissions" {
  let sample =
    #|package: name='dev.mbui.demo' versionCode='42' versionName='1.2.3'
    #|sdkVersion:'30'
    #|targetSdkVersion:'36'
    #|uses-permission: name='android.permission.INTERNET'
    #|uses-permission: name='android.permission.CAMERA'
    #|application-label:'Demo App'
    #|launchable-activity: name='dev.mbui.MainActivity'  label='' icon=''
  let m = parse_badging(sample)
  assert_eq(m.pkg, "dev.mbui.demo")
  assert_eq(m.version_code, "42")
  assert_eq(m.version_name, "1.2.3")
  assert_eq(m.min_sdk, "30")
  assert_eq(m.target_sdk, "36")
  assert_eq(m.label, "Demo App")
  assert_eq(m.java_ns, "dev.mbui")
  assert_eq(m.permissions, ["android.permission.INTERNET", "android.permission.CAMERA"])
  assert_false(manifest_uses_app_res("<application android:theme=\"@android:style/Theme.Material.Light.NoActionBar\">"))
  assert_true(manifest_uses_app_res("<application android:icon=\"@mipmap/ic_launcher\">"))
}

///|
test "set_manifest_package inserts or replaces package without duplicating" {
  let no_pkg = "<?xml version=\"1.0\"?>\n<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\">\n</manifest>"
  let added = set_manifest_package(no_pkg, "dev.example.one")
  assert_true(added.contains("<manifest package=\"dev.example.one\" xmlns:android="))
  assert_eq(rx("\\bpackage=").find_all(added).length(), 1)

  let with_pkg = "<?xml version=\"1.0\"?>\n<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"old.pkg.name\">\n</manifest>"
  let replaced = set_manifest_package(with_pkg, "dev.example.two")
  assert_true(replaced.contains("package=\"dev.example.two\""))
  assert_false(replaced.contains("old.pkg.name"))
  assert_eq(rx("\\bpackage=").find_all(replaced).length(), 1)
}

///|
test "set_application_attr adds, replaces, and removes attributes cleanly" {
  let xml = "<application android:label=\"Demo\" android:debuggable=\"true\"><activity /></application>"
  let with_factory = set_application_attr(xml, "appComponentFactory", Some("androidx.core.app.CoreComponentFactory"))
  assert_true(with_factory.contains("android:appComponentFactory=\"androidx.core.app.CoreComponentFactory\""))
  let no_debug = set_application_attr(with_factory, "debuggable", None)
  assert_false(no_debug.contains("android:debuggable"))
  assert_true(no_debug.contains("android:label=\"Demo\""))
}

///|
test "parse_xmltree_app_attrs extracts appComponentFactory, debuggable, and dev.mbui meta-data" {
  let tree =
    #|N: android=http://schemas.android.com/apk/res/android (line=2)
    #|  E: manifest (line=2)
    #|    E: application (line=28)
    #|      A: http://schemas.android.com/apk/res/android:label(0x01010001)="Demo" (Raw: "Demo")
    #|      A: http://schemas.android.com/apk/res/android:debuggable(0x0101000f)=true
    #|      A: http://schemas.android.com/apk/res/android:appComponentFactory(0x0101057a)="androidx.core.app.CoreComponentFactory" (Raw: "androidx.core.app.CoreComponentFactory")
    #|      E: activity (line=30)
    #|        E: meta-data (line=35)
    #|          A: http://schemas.android.com/apk/res/android:name(0x01010003)="dev.mbui.env" (Raw: "dev.mbui.env")
    #|          A: http://schemas.android.com/apk/res/android:value(0x01010024)="WRONG=nested" (Raw: "WRONG=nested")
    #|      E: meta-data (line=77)
    #|        A: http://schemas.android.com/apk/res/android:name(0x01010003)="dev.mbui.edge" (Raw: "dev.mbui.edge")
    #|        A: http://schemas.android.com/apk/res/android:value(0x01010024)=(type 0x12)0xffffffff
    #|      E: meta-data (line=78)
    #|        A: http://schemas.android.com/apk/res/android:name(0x01010003)="dev.mbui.ground" (Raw: "dev.mbui.ground")
    #|        A: http://schemas.android.com/apk/res/android:value(0x01010024)="#FFFFFF,#1B1C1F" (Raw: "#FFFFFF,#1B1C1F")
    #|      E: meta-data (line=79)
    #|        A: http://schemas.android.com/apk/res/android:name(0x01010003)="dev.mbui.env" (Raw: "dev.mbui.env")
    #|        A: http://schemas.android.com/apk/res/android:value(0x01010024)="FOO=bar;BAZ=1" (Raw: "FOO=bar;BAZ=1")
  let attrs = parse_xmltree_app_attrs(tree)
  assert_eq(attrs.app_component_factory, Some("androidx.core.app.CoreComponentFactory"))
  assert_eq(attrs.debuggable, Some(true))
  assert_eq(attrs.edge_to_edge, Some(true))
  assert_eq(attrs.ground, Some("#FFFFFF,#1B1C1F"))
  assert_eq(attrs.env, Some("FOO=bar;BAZ=1"))

  // Also verify build-tools 37+ indentation (E: children +4, A: +4)
  let tree37 =
    #|  E: application (line=28)
    #|        A: http://schemas.android.com/apk/res/android:appComponentFactory(0x0101057a)="androidx.core.app.CoreComponentFactory" (Raw: "androidx.core.app.CoreComponentFactory")
    #|        E: meta-data (line=77)
    #|            A: http://schemas.android.com/apk/res/android:name(0x01010003)="dev.mbui.env" (Raw: "dev.mbui.env")
    #|            A: http://schemas.android.com/apk/res/android:value(0x01010024)="K=V" (Raw: "K=V")
  let attrs37 = parse_xmltree_app_attrs(tree37)
  assert_eq(attrs37.app_component_factory, Some("androidx.core.app.CoreComponentFactory"))
  assert_eq(attrs37.env, Some("K=V"))
}

///|
test "hash_of_line takes the hash of either tool's line, escaped or not" {
  let h = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  assert_eq(hash_of_line(h + "  a b/c.txt"), h)
  assert_eq(hash_of_line(h + " *c.txt"), h)
  assert_eq(hash_of_line("\\" + h + "  b\\\\s"), h)
  assert_eq(hash_of_line("short"), "")
}

///|
test "sha256_files hashes many files at once, each as sha256_file does" {
  let d = sh("mktemp -d -t apk-test-XXXXXX", "mktemp").trim(chars=" \n").to_owned()
  let abc = @sys.join(d, "abc")
  let spaced = @sys.join(d, "a b/it's here.txt")
  let slashed = @sys.join(d, "back\\slash")
  let empty = @sys.join(d, "empty")
  @sys.makedirs(@sys.join(d, "a b"))
  assert_true(@sys.write_text(abc, "abc"))
  assert_true(@sys.write_text(spaced, "abc"))
  assert_true(@sys.write_text(slashed, "x"))
  assert_true(@sys.write_text(empty, ""))
  assert_eq(sha256_files([]).length(), 0)
  let one = sha256_files([abc])
  assert_eq(one.length(), 1)
  assert_eq(one.get(abc), Some("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
  // (in the order asked, twice over: one hash a path)
  let all = sha256_files([empty, spaced, abc, slashed, abc])
  assert_eq(all.length(), 4)
  assert_eq(all.get(empty), Some("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
  assert_eq(all.get(spaced), all.get(abc))
  assert_eq(all.get(slashed), Some("2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"))
  for p in [abc, spaced, slashed, empty] {
    assert_eq(all.get(p), Some(sha256_file(p)))
  }
  // (more than one start of the tool: 450 files, three of them)
  let many = []
  for i = 0; i < 450; i = i + 1 {
    let p = @sys.join(d, "f\{i}")
    assert_true(@sys.write_text(p, if i % 2 == 0 { "abc" } else { "" }))
    many.push(p)
  }
  let sums = sha256_files(many)
  assert_eq(sums.length(), 450)
  for i, p in many {
    assert_eq(sums.get(p), all.get(if i % 2 == 0 { abc } else { empty }))
  }
  assert_eq(sha256_text("abc", @sys.join(d, "t")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  ignore(try_sh("rm -rf " + q(d)))
}
