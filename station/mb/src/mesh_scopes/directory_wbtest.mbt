// Local descriptor address bounding (directory.mbt `bounded_descriptor`): <= 8 addrs stay unchanged, > 8 valid
// underlay addrs keep relays and public IPs first and satisfy `descriptor_of`, while `Custom` entries are never
// silently dropped so validation still rejects them.

///|
fn accepting_crypto() -> Crypto {
  {
    verify: fn(_k, _b, _s) { true },
    sign: fn(_t) { "00".repeat(64) },
    sha256: b => hex_of(b[:]),
    random: n => Bytes::make(n, b'\x00'),
  }
}

///|
fn byte_array(byte : Int, count : Int) -> Json {
  Json::array(Array::make(count, Json::number(byte.to_double())))
}

///|
fn sample_descriptor(addrs : Array[Json]) -> Json {
  {
    "binding": {
      "scope": byte_array(0xab, 32),
      "policy": byte_array(0x00, 32),
      "endpoint": byte_array(0xcd, 32),
      "neighbor": byte_array(0xef, 32),
      "generation": Json::number(1.0),
      "transit": Json::boolean(true),
      "signature": byte_array(0x01, 64),
    },
    "address": {
      "id": "ef".repeat(32),
      "addrs": Json::array(addrs),
    },
  }
}

///|
test "bounded_descriptor leaves <= 8 underlay addresses unchanged and un-reordered" {
  let scope = "ab".repeat(32)
  let node = "cd".repeat(32)
  let addrs : Array[Json] = [
    { "Ip": Json::string("127.0.0.1:4000") },
    { "Ip": Json::string("192.168.1.10:4000") },
    { "Relay": Json::string("https://relay-z.example") },
  ]
  let desc = sample_descriptor(addrs)
  let out = bounded_descriptor(desc)
  assert_eq(out, desc)
  ignore(descriptor_of(accepting_crypto(), out, scope, node))
}

///|
test "bounded_descriptor prioritizes relays and public IPs above 8 and passes descriptor_of" {
  let scope = "ab".repeat(32)
  let node = "cd".repeat(32)
  let addrs : Array[Json] = [
    { "Ip": Json::string("[::1]:4000") },
    { "Ip": Json::string("127.0.0.1:4000") },
    { "Ip": Json::string("[fe80::1]:4000") },
    { "Ip": Json::string("169.254.1.1:4000") },
    { "Ip": Json::string("[fd00::1]:4000") },
    { "Ip": Json::string("192.168.1.10:4000") },
    { "Ip": Json::string("172.17.0.1:4000") },
    { "Ip": Json::string("100.64.0.1:4000") },
    { "Ip": Json::string("[2606:4700:4700::1111]:4000") },
    { "Ip": Json::string("[2001:4860:4860::8888]:4000") },
    { "Ip": Json::string("8.8.8.8:4000") },
    { "Ip": Json::string("1.2.3.4:4000") },
    { "Relay": Json::string("https://relay-b.example") },
    { "Relay": Json::string("https://relay-a.example") },
  ]
  let out = bounded_descriptor(sample_descriptor(addrs))
  let expected : Json = Json::array([
    { "Relay": Json::string("https://relay-a.example") },
    { "Relay": Json::string("https://relay-b.example") },
    { "Ip": Json::string("1.2.3.4:4000") },
    { "Ip": Json::string("8.8.8.8:4000") },
    { "Ip": Json::string("[2001:4860:4860::8888]:4000") },
    { "Ip": Json::string("[2606:4700:4700::1111]:4000") },
    { "Ip": Json::string("100.64.0.1:4000") },
    { "Ip": Json::string("172.17.0.1:4000") },
  ])
  assert_eq(field(field(out, "address"), "addrs"), expected)
  ignore(descriptor_of(accepting_crypto(), out, scope, node))
}

///|
test "bounded_descriptor does not strip Custom addresses and descriptor_of still rejects them" {
  let scope = "ab".repeat(32)
  let node = "cd".repeat(32)
  let addrs : Array[Json] = []
  for i in 1..=9 {
    addrs.push({ "Ip": Json::string("192.168.1.\{i}:4000") })
  }
  addrs.push({ "Custom": { "id": Json::number(1.0) } })
  let desc = sample_descriptor(addrs)
  let out = bounded_descriptor(desc)
  assert_eq(out, desc)
  let rejected = try {
    ignore(descriptor_of(accepting_crypto(), out, scope, node))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
