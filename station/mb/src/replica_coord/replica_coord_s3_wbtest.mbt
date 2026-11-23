// Unit tests for backup_config, SFB1 ChaCha20-Poly1305 encryption (including byte-exact Node cross-engine vectors),
// AWS SigV4 request signing, XML entity/tag parsing, and Copies target selection (auto / manual / acceptOthers / S3).

// ── Pure MoonBit RFC 8439 ChaCha20-Poly1305 test provider (no C shell link required for `moon test`) ──

///|
fn wb_rotl32(x : UInt, n : Int) -> UInt {
  (x << n) | (x >> (32 - n))
}

///|
fn wb_load_u32_le(b : BytesView, off : Int) -> UInt {
  b[off].to_uint() |
  (b[off + 1].to_uint() << 8) |
  (b[off + 2].to_uint() << 16) |
  (b[off + 3].to_uint() << 24)
}

///|
fn wb_qr(s : FixedArray[UInt], a : Int, b : Int, c : Int, d : Int) -> Unit {
  s[a] = s[a] + s[b]
  s[d] = wb_rotl32(s[d] ^ s[a], 16)
  s[c] = s[c] + s[d]
  s[b] = wb_rotl32(s[b] ^ s[c], 12)
  s[a] = s[a] + s[b]
  s[d] = wb_rotl32(s[d] ^ s[a], 8)
  s[c] = s[c] + s[d]
  s[b] = wb_rotl32(s[b] ^ s[c], 7)
}

///|
fn wb_chacha20_block(key : BytesView, counter : UInt, nonce : BytesView) -> FixedArray[Byte] {
  let state : FixedArray[UInt] = [
    0x61707865U, 0x3320646eU, 0x79622d32U, 0x6b206574U,
    wb_load_u32_le(key, 0), wb_load_u32_le(key, 4), wb_load_u32_le(key, 8), wb_load_u32_le(key, 12),
    wb_load_u32_le(key, 16), wb_load_u32_le(key, 20), wb_load_u32_le(key, 24), wb_load_u32_le(key, 28),
    counter, wb_load_u32_le(nonce, 0), wb_load_u32_le(nonce, 4), wb_load_u32_le(nonce, 8),
  ]
  let w = state.copy()
  for _ in 0..<10 {
    wb_qr(w, 0, 4, 8, 12)
    wb_qr(w, 1, 5, 9, 13)
    wb_qr(w, 2, 6, 10, 14)
    wb_qr(w, 3, 7, 11, 15)
    wb_qr(w, 0, 5, 10, 15)
    wb_qr(w, 1, 6, 11, 12)
    wb_qr(w, 2, 7, 8, 13)
    wb_qr(w, 3, 4, 9, 14)
  }
  let out = FixedArray::make(64, b'\x00')
  for i in 0..<16 {
    let v = w[i] + state[i]
    out[i * 4] = (v & 0xFFU).to_byte()
    out[i * 4 + 1] = ((v >> 8) & 0xFFU).to_byte()
    out[i * 4 + 2] = ((v >> 16) & 0xFFU).to_byte()
    out[i * 4 + 3] = ((v >> 24) & 0xFFU).to_byte()
  }
  out
}

///|
fn wb_chacha20_xor(key : BytesView, counter : UInt, nonce : BytesView, input : BytesView) -> Bytes {
  let n = input.length()
  let out = FixedArray::make(n, b'\x00')
  let mut off = 0
  let mut ctr = counter
  while off < n {
    let block = wb_chacha20_block(key, ctr, nonce)
    ctr = ctr + 1U
    let take = if n - off < 64 { n - off } else { 64 }
    for i in 0..<take {
      out[off + i] = (input[off + i].to_int() ^ block[i].to_int()).to_byte()
    }
    off += take
  }
  Bytes::from_array(out)
}

///|
fn wb_poly1305_mac(key32 : FixedArray[Byte], msg : BytesView) -> Bytes {
  // Pure BigInt Poly1305 (RFC 8439)
  let le_big = (arr : BytesView, off : Int, len : Int) => {
    let mut acc = 0N
    for i = len - 1; i >= 0; i = i - 1 {
      acc = (acc << 8) + BigInt::from_int(arr[off + i].to_int())
    }
    acc
  }
  let r_bytes = FixedArray::make(16, b'\x00')
  for i in 0..<16 {
    r_bytes[i] = key32[i]
  }
  r_bytes[3] = (r_bytes[3].to_int() & 15).to_byte()
  r_bytes[7] = (r_bytes[7].to_int() & 15).to_byte()
  r_bytes[11] = (r_bytes[11].to_int() & 15).to_byte()
  r_bytes[15] = (r_bytes[15].to_int() & 15).to_byte()
  r_bytes[4] = (r_bytes[4].to_int() & 252).to_byte()
  r_bytes[8] = (r_bytes[8].to_int() & 252).to_byte()
  r_bytes[12] = (r_bytes[12].to_int() & 252).to_byte()
  let r_b = Bytes::from_array(r_bytes)
  let s_bytes = FixedArray::make(16, b'\x00')
  for i in 0..<16 {
    s_bytes[i] = key32[16 + i]
  }
  let s_b = Bytes::from_array(s_bytes)
  let r = le_big(r_b[:], 0, 16)
  let s = le_big(s_b[:], 0, 16)
  let p = (1N << 130) - 5N
  let mut a = 0N
  let mut off = 0
  while off < msg.length() {
    let take = if msg.length() - off < 16 { msg.length() - off } else { 16 }
    let n = le_big(msg, off, take) + (1N << (8 * take))
    a = ((a + n) * r) % p
    off += take
  }
  a = a + s
  let tag = FixedArray::make(16, b'\x00')
  for i in 0..<16 {
    tag[i] = ((a >> (8 * i)) % 256N).to_int().to_byte()
  }
  Bytes::from_array(tag)
}

///|
fn wb_pad16(buf : @buffer.Buffer, len : Int) -> Unit {
  let rem = len % 16
  if rem != 0 {
    for _ in 0..<(16 - rem) {
      buf.write_byte(b'\x00')
    }
  }
}

///|
fn wb_u64_le(buf : @buffer.Buffer, n : Int) -> Unit {
  let mut v = n.to_int64()
  for _ in 0..<8 {
    buf.write_byte((v & 0xFFL).to_int().to_byte())
    v = v >> 8
  }
}

///|
fn wb_aead_seal(key : BytesView, nonce : BytesView, aad : BytesView, plain : BytesView) -> Bytes {
  let otk_block = wb_chacha20_block(key, 0U, nonce)
  let otk = FixedArray::make(32, b'\x00')
  for i in 0..<32 {
    otk[i] = otk_block[i]
  }
  let ct = wb_chacha20_xor(key, 1U, nonce, plain)
  let mac_data = @buffer.new()
  mac_data.write_bytesview(aad)
  wb_pad16(mac_data, aad.length())
  mac_data.write_bytes(ct)
  wb_pad16(mac_data, ct.length())
  wb_u64_le(mac_data, aad.length())
  wb_u64_le(mac_data, ct.length())
  let tag = wb_poly1305_mac(otk, mac_data.to_bytes()[:])
  let out = @buffer.new(size_hint=ct.length() + 16)
  out.write_bytes(ct)
  out.write_bytes(tag)
  out.to_bytes()
}

///|
fn wb_aead_open(key : BytesView, nonce : BytesView, aad : BytesView, sealed : BytesView) -> Bytes? {
  if sealed.length() < 16 {
    return None
  }
  let ct_len = sealed.length() - 16
  let ct = sealed[0:ct_len]
  let tag = sealed[ct_len:sealed.length()].to_bytes()
  let otk_block = wb_chacha20_block(key, 0U, nonce)
  let otk = FixedArray::make(32, b'\x00')
  for i in 0..<32 {
    otk[i] = otk_block[i]
  }
  let mac_data = @buffer.new()
  mac_data.write_bytesview(aad)
  wb_pad16(mac_data, aad.length())
  mac_data.write_bytesview(ct)
  wb_pad16(mac_data, ct.length())
  wb_u64_le(mac_data, aad.length())
  wb_u64_le(mac_data, ct.length())
  let expected = wb_poly1305_mac(otk, mac_data.to_bytes()[:])
  if expected != tag {
    return None
  }
  Some(wb_chacha20_xor(key, 1U, nonce, ct))
}

///|
fn wb_test_crypto() -> @vault_crypto.Crypto {
  let str_f = (args : Json, k : String) => match args {
    Object(m) => match m.get(k) { Some(String(s)) => s; _ => "" }
    _ => ""
  }
  {
    ask: (op, args) =>
      match op {
        "crypto.chachaSeal" => {
          let key = @hash.hex_decode(str_f(args, "key")).unwrap()
          let nonce = @hash.hex_decode(str_f(args, "nonce")).unwrap()
          let aad = @hash.hex_decode(str_f(args, "aad")).unwrap()
          let plain = @hash.hex_decode(str_f(args, "plain")).unwrap()
          Ok(Json::string(@hash.hex_encode(wb_aead_seal(key[:], nonce[:], aad[:], plain[:])[:])))
        }
        "crypto.chachaOpen" => {
          let key = @hash.hex_decode(str_f(args, "key")).unwrap()
          let nonce = @hash.hex_decode(str_f(args, "nonce")).unwrap()
          let aad = @hash.hex_decode(str_f(args, "aad")).unwrap()
          let sealed = @hash.hex_decode(str_f(args, "sealed")).unwrap()
          match wb_aead_open(key[:], nonce[:], aad[:], sealed[:]) {
            Some(p) => Ok(Json::string(@hash.hex_encode(p[:])))
            None => Ok(Json::null())
          }
        }
        _ => Err("unsupported in wbtest: \{op}")
      },
  }
}

///|
test "SFB1 MoonBit <-> Node byte-for-byte cross-engine interoperability & tamper rejection" {
  let crypto = wb_test_crypto()
  let key = parse_encryption_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
  let salt = @hash.hex_decode("00112233445566778899aabbccddeeff").unwrap()
  let ws = "W1"
  let origin = "a".repeat(64)
  let logical_path = "head/lz5x0-0123abcd"

  // Node-generated vectors
  let node_empty_hex = "5346423100112233445566778899aabbccddeeff000000000140a2e9bf1bf2949ec5fae9ca903efa96"
  let node_multi_hex = "5346423100112233445566778899aabbccddeeff00000006002e63aae6fe5b61738dcd97164d941d7f8367508a978800000006015b8d9be61e0c9263c0e4ff3a687527e0dd690945bb93"

  // Seal in MoonBit matches Node byte-for-byte
  let sealed_empty = sfb1_seal(crypto, key, ws, origin, logical_path, b"", salt~)
  assert_eq(@hash.hex_encode(sealed_empty[:]), node_empty_hex)
  assert_eq(sfb1_open(crypto, key, ws, origin, logical_path, @hash.hex_decode(node_empty_hex).unwrap()), b"")

  let sealed_multi = sfb1_seal(crypto, key, ws, origin, logical_path, @utf8.encode("hello world!"), salt~, frame_max=6)
  assert_eq(@hash.hex_encode(sealed_multi[:]), node_multi_hex)
  assert_eq(@utf8.decode_lossy(sfb1_open(crypto, key, ws, origin, logical_path, @hash.hex_decode(node_multi_hex).unwrap())), "hello world!")

  // Tamper tag -> rejected
  let bad = sealed_multi.to_array()
  bad[bad.length() - 1] = (bad[bad.length() - 1].to_int() ^ 1).to_byte()
  assert_true((try Ok(sfb1_open(crypto, key, ws, origin, logical_path, Bytes::from_array(bad))) catch { e => Err(e) }) is Err(_))

  // Truncated -> rejected
  assert_true((try Ok(sfb1_open(crypto, key, ws, origin, logical_path, sealed_multi[0:sealed_multi.length() - 1].to_bytes())) catch { e => Err(e) }) is Err(_))

  // Trailing byte -> rejected
  let with_tail = @buffer.new()
  with_tail.write_bytes(sealed_multi)
  with_tail.write_byte(b'\x00')
  assert_true((try Ok(sfb1_open(crypto, key, ws, origin, logical_path, with_tail.to_bytes())) catch { e => Err(e) }) is Err(_))

  // Wrong AAD (ws / origin / path) -> rejected
  assert_true((try Ok(sfb1_open(crypto, key, "W2", origin, logical_path, sealed_multi)) catch { e => Err(e) }) is Err(_))
  assert_true((try Ok(sfb1_open(crypto, key, ws, "b".repeat(64), logical_path, sealed_multi)) catch { e => Err(e) }) is Err(_))
  assert_true((try Ok(sfb1_open(crypto, key, ws, origin, "head/other", sealed_multi)) catch { e => Err(e) }) is Err(_))
}

///|
test "S3 SigV4 signing, RFC 3986 encoding, UTC date math, and XML unescaping" {
  let (amz_date, date_stamp) = format_amz_date(1795353066000.0)
  assert_eq(date_stamp, "20261122")
  assert_eq(amz_date, "20261122T131106Z")
  assert_eq(rfc3986_encode("a b/c~d!e'f(g)h*i"), "a%20b%2Fc~d%21e%27f%28g%29h%2Ai")
  assert_eq(encode_s3_path("dir/a b/file+1.enc"), "dir/a%20b/file%2B1.enc")
  assert_eq(unescape_xml("a&amp;b&lt;c&gt;&quot;d&quot;&apos;e&#33;&#x21;"), "a&b<c>\"d\"'e!!")
  let xml = "<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>tok&amp;1</NextContinuationToken><Contents><Key>p/a&amp;b</Key></Contents><Contents><Key>p/c</Key></Contents></ListBucketResult>"
  assert_eq(extract_xml_tag(xml, "IsTruncated"), Some("true"))
  assert_eq(extract_xml_tag(xml, "NextContinuationToken"), Some("tok&1"))
  assert_eq(extract_all_xml_tags(xml, "Key"), ["p/a&b", "p/c"])

  let t : S3TargetConfig = {
    id: "r2",
    name: "R2",
    endpoint: "https://s3.us-east-1.amazonaws.com",
    region: "auto",
    bucket: "my-bkt",
    prefix: "stillfail-backup",
    force_path_style: false,
    access_key_id: "AKIA_TEST_KEY_12345",
    secret_access_key: "SECRET_TEST_VALUE_67890",
    encryption_key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    include_transcripts: true,
  }
  let signed = sign_s3_request(t, "GET", "a/b c.enc", [("z", "1"), ("a", "2")], b"", 1795348800000.0)
  assert_eq(signed.url, "https://my-bkt.s3.us-east-1.amazonaws.com/a/b%20c.enc?a=2&z=1")
  let auth = signed.headers.search_by(h => h.0 == "authorization").map(i => signed.headers[i].1).unwrap_or("")
  assert_true(auth.has_prefix("AWS4-HMAC-SHA256 Credential=AKIA_TEST_KEY_12345/20261122/auto/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature="))
}

///|
test "backup_config validation, secret preservation, key generation, and sanitized view" {
  let a = "a".repeat(64)
  let b = "b".repeat(64)
  assert_eq(mask_value("AKIA_TEST_KEY_12345"), "AKIA_…2345")
  assert_eq(mask_value("short"), "••••")
  assert_eq(key_fingerprint("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef").length(), 8)

  let mut seq = 0
  let rand_hex = (n : Int) => {
    seq += 1
    if n == 4 { "abcd000\{seq}" } else { "f".repeat(64) }
  }
  let input1 = jo([
    ("mode", js("manual")),
    ("stations", jstrs([b])),
    ("acceptOthers", jb(false)),
    (
      "s3",
      ja([
        jo([
          ("name", js("Cloudflare R2")),
          ("endpoint", js("https://r2.example.com/")),
          ("bucket", js("my-backup")),
          ("prefix", js("/sub/path/")),
          ("accessKeyId", js("AKIA_TEST_KEY_12345")),
          ("secretAccessKey", js("SUPER_SECRET_KEY")),
        ]),
      ]),
    ),
  ])
  let (saved1, gen1) = apply_backup_update(jo([]), input1, rand_hex)
  assert_eq(gen1.length(), 1)
  let tid = gen1[0].0
  assert_eq(gen1[0].1, "f".repeat(64))
  check_backup_config(Some(saved1))

  // Update name while omitting accessKeyId, secretAccessKey & encryptionKey -> preserves all 3, generates no new key
  let input2 = jo([
    (
      "s3",
      ja([
        jo([
          ("id", js(tid)),
          ("name", js("R2 Renamed")),
          ("endpoint", js("https://r2.example.com")),
          ("bucket", js("my-backup")),
        ]),
      ]),
    ),
  ])
  let (saved2, gen2) = apply_backup_update(jo([("backup", saved1)]), input2, rand_hex)
  assert_eq(gen2.length(), 0)
  let parsed = read_backup_config(jo([("backup", saved2)]))
  assert_eq(parsed.mode, "manual")
  assert_eq(parsed.stations, [b])
  assert_eq(parsed.accept_others, false)
  assert_eq(parsed.s3.length(), 1)
  assert_eq(parsed.s3[0].name, "R2 Renamed")
  assert_eq(parsed.s3[0].access_key_id, "AKIA_TEST_KEY_12345")
  assert_eq(parsed.s3[0].secret_access_key, "SUPER_SECRET_KEY")
  assert_eq(parsed.s3[0].encryption_key, "f".repeat(64))

  // Sanitized view never contains secretAccessKey or encryptionKey
  let view = backup_view_json(
    parsed,
    [{ station: a, name: "A", accept_others: true, online: true }],
    _ => { to: 10.0, at: Some(1000.0), error: None, reason: None },
  )
  let view_str = stringify(view)
  assert_true(!view_str.contains("SUPER_SECRET_KEY"))
  assert_true(!view_str.contains("f".repeat(64)))
  assert_true(view_str.contains("AKIA_…2345"))

  // Reject non-https non-loopback endpoint and bad bucket
  assert_true((try Ok(validate_endpoint(Some(js("http://example.com")))) catch { e => Err(e) }) is Err(_))
  assert_true((try Ok(validate_endpoint(Some(js("http://127.0.0.1:9000")))) catch { e => Err(e) }) is Ok(_))
  assert_true((try Ok(validate_bucket(Some(js("INVALID_BUCKET")))) catch { e => Err(e) }) is Err(_))
}

///|
test "select_backup_targets: auto, manual, empty, and acceptOthers=false skipping" {
  let a = "a".repeat(64)
  let b = "b".repeat(64)
  let c = "c".repeat(64)
  let d = "d".repeat(64)
  let roster = [a, b, c, d]
  let accepts : Map[String, Bool] = {}

  // Auto mode picks 2 peers
  let auto2 = select_backup_targets("W1", a, roster, BackupConfig::default(), accepts, _ => false)
  assert_eq(auto2.length(), 2)
  assert_true(!auto2.contains(a))

  // Auto mode skips peer with accept_others = false
  let skipped = auto2[0]
  accepts[skipped] = false
  let auto_skip = select_backup_targets("W1", a, roster, BackupConfig::default(), accepts, _ => false)
  assert_eq(auto_skip.length(), 2)
  assert_true(!auto_skip.contains(skipped))

  // Manual mode returns exact selected peers in roster (excluding self)
  let manual_cfg : BackupConfig = { mode: "manual", stations: [a, c, "e".repeat(64)], accept_others: true, s3: [] }
  assert_eq(select_backup_targets("W1", a, roster, manual_cfg, accepts, _ => false), [c])

  // Manual empty [] returns [] (S3-only)
  let empty_cfg : BackupConfig = { mode: "manual", stations: [], accept_others: true, s3: [] }
  assert_eq(select_backup_targets("W1", a, roster, empty_cfg, accepts, _ => false), [])
}

///|
test "Copies history: record, dedup logic, 50-record cap, persistence reload, limit clamping, and restore merge" {
  let ws = "W1"
  let peer_b = "b".repeat(64)
  let hist : Map[String, Array[BackupRecord]] = {}
  let mut seq = 0
  let add = (
    at : Double,
    kind : String,
    target_kind : String,
    target : String,
    target_name : String,
    status : String,
    chats : Int,
    messages : Int,
    batches : Int,
    bytes : Double,
    reason : String?,
    error : String?,
  ) => {
    seq += 1
    append_history_record(hist, seq, ws, at, kind, target_kind, target, target_name, status, chats, messages, batches, bytes, reason, error)
  }

  // Record peer sync ok + s3 sync ok
  let r1 = add(1000.0, "sync", "station", peer_b, "Cedar", "ok", 10, 80, 2, 4096.0, None, None)
  let r2 = add(2000.0, "sync", "s3", "r2main", "Cloudflare R2", "ok", 10, 80, 2, 4096.0, None, None)
  assert_eq(r1.id, "1000-1")
  assert_eq(r2.id, "2000-2")

  // Error dedup rule: first failure (was_error=None) records; same reason skipped; reason change records; recovery records
  let should_rec = (was_error : String?, prev_reason : String?, reason : String) => was_error is None || prev_reason != Some(reason)
  assert_true(should_rec(None, None, "offline"))
  assert_false(should_rec(Some("unreachable"), Some("offline"), "offline"))
  assert_true(should_rec(Some("unreachable"), Some("offline"), "error"))
  ignore(add(3000.0, "sync", "station", peer_b, "Cedar", "error", 0, 0, 0, 0.0, Some("offline"), Some("station unreachable")))
  ignore(add(4000.0, "sync", "station", peer_b, "Cedar", "ok", 11, 85, 3, 5000.0, None, None))
  // A sync that went well right after one that went well to the same place takes its place; one after a failure does not
  ignore(add(4500.0, "sync", "station", peer_b, "Cedar", "ok", 12, 90, 3, 5100.0, None, None))
  let cedar = hist[ws].filter(r => r.target == peer_b).map(r => (r.at, r.status))
  assert_eq(cedar, [(4500.0, "ok"), (3000.0, "error"), (1000.0, "ok")])

  // Cap at 50 records per workspace (newest first)
  for i in 0..<60 {
    ignore(add(5000.0 + i.to_double() * 100.0, "sync", "s3", "r2-\{i}", "Cloudflare R2", "ok", i, i * 2, 1, 1024.0, None, None))
  }
  assert_eq(hist[ws].length(), history_max)
  assert_eq(hist[ws][0].at, 10900.0)
  assert_eq(hist[ws][history_max - 1].at, 6000.0)

  // Persistence round-trip: history_payload_json -> stringify -> parse -> parse_history_file
  let disk_text = stringify(history_payload_json(hist))
  let reloaded = parse_history_file(Some(parse(disk_text)))
  assert_eq(reloaded[ws].length(), history_max)
  assert_eq(reloaded[ws][0].id, hist[ws][0].id)
  assert_eq(reloaded[ws][0].target_kind, "s3")
  assert_eq(reloaded[ws][0].target_name, "Cloudflare R2")
  assert_eq(reloaded[ws][0].status, "ok")

  // Corrupted or wrong-version history safely falls back to empty
  assert_eq(parse_history_file(None).length(), 0)
  assert_eq(parse_history_file(Some(parse("{\"v\":2,\"workspaces\":{}}"))).length(), 0)

  // Restore outcome merge + limit clamping (1..50) + no duplicate when same restore at exists
  let outcome = parse(
    "{\"origin\":\"\{peer_b}\",\"name\":\"Old\",\"from\":\"s3:r2main\",\"at\":20000,\"rows\":{\"sessions\":4,\"entries\":22},\"files\":1,\"missing\":0,\"error\":null,\"reason\":null,\"pending\":false,\"left\":0}",
  )
  let top2 = query_history(reloaded, Some(outcome), ws, 2, _ => "Peer", id => if id == "r2main" { "Cloudflare R2" } else { id })
  assert_eq(top2.length(), 2)
  assert_eq(top2[0].kind, "restore")
  assert_eq(top2[0].target_kind, "s3")
  assert_eq(top2[0].target, "r2main")
  assert_eq(top2[0].target_name, "Cloudflare R2")
  assert_eq(top2[0].status, "ok")
  assert_eq(top2[0].chats, 4)
  assert_eq(top2[0].messages, 22)
  assert_eq(top2[1].at, 10900.0)

  // Clamp limit < 1 to 1 and > 50 to 50
  assert_eq(query_history(reloaded, Some(outcome), ws, 0, _ => "Peer", id => id).length(), 1)
  assert_eq(query_history(reloaded, Some(outcome), ws, 999, _ => "Peer", id => id).length(), history_max)

  // If history already has a restore record at the same `at`, do not duplicate it
  ignore(append_history_record(reloaded, 999, ws, 20000.0, "restore", "s3", "r2main", "Cloudflare R2", "ok", 4, 22, 0, 0.0, None, None))
  let deduped = query_history(reloaded, Some(outcome), ws, 50, _ => "Peer", id => id)
  let restore_count = deduped.filter(r => r.kind == "restore" && r.at == 20000.0).length()
  assert_eq(restore_count, 1)
}
