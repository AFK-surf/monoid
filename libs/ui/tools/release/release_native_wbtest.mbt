// Native filesystem whitebox tests for feed + dir/dry-run publish.

///|
test "native filesystem feed and dir publish" {
  let seed = hex_decode_exact(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
  ).unwrap()
  let pk_b64 = base64_encode(ed25519_public_key(seed))
  let tmp = "/tmp/mbui-release-native-wbtest"
  let src_dir = tmp + "/src"
  let pub_dir = tmp + "/pub"
  @sys.makedirs(src_dir)
  let key_file = tmp + "/key.pem"
  assert_true(@sys.write_text(key_file, encode_pkcs8_pem(seed)))
  let art_file = src_dir + "/app-10.zip"
  assert_true(@sys.write_bytes(art_file, Bytes::makei(1024, fn(i) { (i & 0xFF).to_byte() })))
  let small_delta = src_dir + "/9-to-10.delta"
  assert_true(@sys.write_bytes(small_delta, b"delta-bytes"))

  let (feed_json, warnings) = match build_feed_json(
    art_file,
    "1.0.10",
    10,
    "desktop-mac",
    key_file,
    "",
    [(9, small_delta)],
  ) {
    Ok(v) => v
    Err(e) => fail("build_feed_json failed: \{e}")
  }
  assert_eq(warnings.length(), 0)
  assert_true(@sys.write_text(src_dir + "/latest.json", feed_json))
  match verify_json_text(feed_json, pk_b64, "desktop-mac") {
    Ok(msg) => assert_true(msg.contains("verified app-10.zip"))
    Err(e) => fail("verify failed: \{e}")
  }

  // Dry-run does not fail
  let dry_steps = match run_publish_impl(
    src_dir,
    "dir",
    pub_dir + "-dry",
    "",
    "",
    true,
  ) {
    Ok(s) => s
    Err(e) => fail("dry-run failed: \{e}")
  }
  assert_eq(dry_steps[dry_steps.length() - 1], "copy \{src_dir}/latest.json -> \{pub_dir}-dry/latest.json")
  assert_false(@sys.exists(pub_dir + "-dry"))

  // Real dir publish
  match run_publish_impl(src_dir, "dir", pub_dir, "", "", false) {
    Ok(steps) => assert_true(steps[steps.length() - 1].contains("latest.json"))
    Err(e) => fail("dir publish failed: \{e}")
  }
  assert_true(@sys.is_file(pub_dir + "/app-10.zip"))
  assert_true(@sys.is_file(pub_dir + "/9-to-10.delta"))
  assert_true(@sys.is_file(pub_dir + "/latest.json"))
}
