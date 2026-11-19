// Line-delimited JSON harness (`--builder harness-stdlib`) for station/test/mb-stdlib-conformance.test.ts
// to cross-check pure MoonBit Node/stdlib replacements against real Node built-ins (node:path, node:zlib,
// JSON, encodeURI*, node:crypto, Buffer, Date).

///|
fn std_at(ask : Json, k : String) -> Json? {
  match ask {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
fn std_str(ask : Json, k : String) -> String {
  match std_at(ask, k) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn std_strs(ask : Json, k : String) -> Array[String] {
  let out : Array[String] = []
  match std_at(ask, k) {
    Some(Array(xs)) =>
      for x in xs {
        if x is String(s) {
          out.push(s)
        }
      }
    _ => ()
  }
  out
}

///|
fn std_bytes(ask : Json, k : String) -> Bytes {
  @codec.hex_decode(std_str(ask, k)).unwrap_or(b"")
}

///|
fn std_opt_bytes(v : Bytes?) -> Json {
  match v {
    Some(b) => Json::string(@codec.hex_encode(b))
    None => Json::null()
  }
}

///|
fn std_opt_str(v : String?) -> Json {
  match v {
    Some(s) => Json::string(s)
    None => Json::null()
  }
}

///|
fn std_eval(ask : Json) -> Json {
  match std_str(ask, "op") {
    "path.join" => Json::string(@nodepath.join(std_str(ask, "sep"), std_strs(ask, "parts")))
    "path.dirname" => Json::string(@nodepath.dirname(std_str(ask, "sep"), std_str(ask, "path")))
    "path.basename" => Json::string(@nodepath.basename(std_str(ask, "sep"), std_str(ask, "path")))
    "path.is_absolute" => Json::boolean(@nodepath.is_absolute(std_str(ask, "sep"), std_str(ask, "path")))
    "flate.deflate" => Json::string(@codec.hex_encode(@flate.deflate(std_bytes(ask, "hex"))))
    "flate.inflate" => std_opt_bytes(@flate.inflate(std_bytes(ask, "hex")))
    "flate.zlib_compress" => Json::string(@codec.hex_encode(@flate.zlib_compress(std_bytes(ask, "hex"))))
    "flate.zlib_decompress" => std_opt_bytes(@flate.zlib_decompress(std_bytes(ask, "hex")))
    "flate.gzip" => Json::string(@codec.hex_encode(@flate.gzip(std_bytes(ask, "hex"))))
    "flate.gunzip" => std_opt_bytes(@flate.gunzip(std_bytes(ask, "hex")))
    "json.roundtrip" => {
      let raw = std_str(ask, "raw")
      let res : String? = try Some(@jsjson.stringify(@jsjson.parse(raw))) catch { _ => None }
      std_opt_str(res)
    }
    "url.encode_uri_component" => Json::string(@url.encode_uri_component(std_str(ask, "s")))
    "url.encode_uri" => Json::string(@url.encode_uri(std_str(ask, "s")))
    "url.decode_uri_component" => std_opt_str(@url.decode_uri_component(std_str(ask, "s")))
    "codec.base64_encode" => Json::string(@codec.base64_encode(std_bytes(ask, "hex")))
    "codec.base64_decode" => std_opt_bytes(@codec.base64_decode(std_str(ask, "s")))
    "codec.base64url_encode" => Json::string(@codec.base64url_encode(std_bytes(ask, "hex")))
    "codec.base64url_decode" => std_opt_bytes(@codec.base64url_decode(std_str(ask, "s")))
    "codec.crc32" => Json::number(@codec.crc32(std_bytes(ask, "hex")).to_double())
    "hash.sha1" => Json::string(@hash.sha1_hex(std_bytes(ask, "hex")))
    "hash.sha256" => Json::string(@hash.sha256_hex(std_bytes(ask, "hex")))
    "hash.hmac_sha256" =>
      Json::string(@hash.hex_encode(@hash.hmac_sha256(std_bytes(ask, "key_hex"), std_bytes(ask, "hex"))))
    "time.format_iso_ms" => {
      let ms = @string.parse_int64(std_str(ask, "ms")) catch { _ => 0L }
      Json::string(@time.format_iso_ms(ms))
    }
    "time.parse_iso_ms" =>
      match @time.parse_iso_ms(std_str(ask, "s")) {
        Some(ms) => Json::string(ms.to_string())
        None => Json::null()
      }
    other => Json::object({ "unknown": Json::string(other) })
  }
}

///|
async fn harness_stdlib(host : @host.Host) -> Unit {
  while host.line() is Some(line) {
    let ask = @json.parse(line) catch { _ => Json::null() }
    let id = std_at(ask, "id").unwrap_or(Json::null())
    let value = std_eval(ask)
    host.say(Json::object({ "id": id, "value": value }).stringify())
  }
}
