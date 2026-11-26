// Line-delimited JSON harness (`--builder harness-upstream`) for station/test/mb-upstream-corpora.test.ts.
// Runs official upstream test corpora (JSONTestSuite, Node path, WPT URL, Wycheproof, PNGSuite)
// directly against MoonBit replacements.

///|
fn u_string_of_u16(arr : Array[Json]) -> String {
  let sb = StringBuilder::new(size_hint=arr.length())
  for x in arr {
    match x {
      Number(n, ..) => sb.write_char(n.to_int().unsafe_to_char())
      _ => ()
    }
  }
  sb.to_string()
}

///|
fn u_url_json(u : @cloud_net.Url) -> Json {
  {
    "href": Json::string(u.href()),
    "origin": Json::string(u.origin()),
    "protocol": Json::string(u.scheme + ":"),
    "username": Json::string(u.username),
    "password": Json::string(u.password),
    "hostname": Json::string(u.hostname()),
    "port": Json::string(match u.port { Some(p) => p.to_string(); None => "" }),
    "pathname": Json::string(u.path),
    "search": Json::string(u.search()),
    "hash": Json::string(u.hash()),
  }
}

///|
async fn upstream_eval(host : @host.Host, ask : Json) -> Json {
  let op = std_str(ask, "op")
  match op {
    "json.parse_u16" => {
      let s = match std_at(ask, "u16") {
        Some(Array(xs)) => u_string_of_u16(xs)
        _ => std_str(ask, "raw")
      }
      try {
        let v = @jsjson.parse(s)
        { "ok": Json::boolean(true), "out": Json::string(@jsjson.stringify(v)) }
      } catch {
        e => { "ok": Json::boolean(false), "err": Json::string(e.to_string()) }
      }
    }
    "path.join" => Json::string(@nodepath.join(std_str(ask, "sep"), std_strs(ask, "parts")))
    "path.dirname" => Json::string(@nodepath.dirname(std_str(ask, "sep"), std_str(ask, "path")))
    "path.basename" => Json::string(@nodepath.basename(std_str(ask, "sep"), std_str(ask, "path")))
    "path.is_absolute" => Json::boolean(@nodepath.is_absolute(std_str(ask, "sep"), std_str(ask, "path")))
    "path.with_extension" =>
      Json::string(@nodepath.with_extension(std_str(ask, "sep"), std_str(ask, "path"), std_str(ask, "ext")))
    "path.relative_parts" =>
      match @nodepath.relative_parts(std_str(ask, "sep"), std_str(ask, "path")) {
        Some(parts) => Json::array(parts.map(x => Json::string(x)))
        None => Json::null()
      }
    "url.parse" =>
      match @cloud_net.parse_url(std_str(ask, "raw")) {
        Some(u) => u_url_json(u)
        None => Json::null()
      }
    "url.encode_uri_component" => Json::string(@url.encode_uri_component(std_str(ask, "s")))
    "url.encode_uri_component_strict" => std_opt_str(@url.encode_uri_component_strict(std_str(ask, "s")))
    "url.encode_uri" => Json::string(@url.encode_uri(std_str(ask, "s")))
    "url.decode_uri_component" => std_opt_str(@url.decode_uri_component(std_str(ask, "s")))
    "url.percent_decode_lossy" => {
      let plus = match std_at(ask, "plus_space") {
        Some(True) => true
        _ => false
      }
      Json::string(@url.percent_decode_lossy(std_str(ask, "s"), plus_space=plus))
    }
    "sse.feed" => {
      let most = match std_at(ask, "most") {
        Some(Number(n, ..)) => n.to_int()
        _ => @base_wire.max_event
      }
      let sse = @base_wire.Sse::new(most~)
      let chunks : Array[Bytes] = match std_at(ask, "chunks_hex") {
        Some(Array(xs)) =>
          xs.map(x => match x {
            String(h) => @codec.hex_decode(h).unwrap_or(b"")
            _ => b""
          })
        _ => [std_bytes(ask, "hex")]
      }
      let events : Array[Json] = []
      let mut too_long = false
      for ch in chunks {
        try {
          for ev in sse.feed(ch) {
            events.push({
              "name": Json::string(ev.name),
              "data": Json::string(ev.data),
              "id": match ev.id {
                Some(i) => Json::string(i)
                None => Json::null()
              },
            })
          }
        } catch {
          @base_wire.TooLong(_) => {
            too_long = true
            break
          }
        }
      }
      { "events": Json::array(events), "tooLong": Json::boolean(too_long) }
    }
    "flate.deflate" => Json::string(@codec.hex_encode(@flate.deflate(std_bytes(ask, "hex"))))
    "flate.inflate" => std_opt_bytes(@flate.inflate(std_bytes(ask, "hex")))
    "flate.deflate_stream" => {
      let d = @flate.Deflater::new()
      let out = @buffer.new()
      match std_at(ask, "chunks_hex") {
        Some(Array(xs)) =>
          for x in xs {
            if x is String(h) {
              out.write_bytes(d.push(@codec.hex_decode(h).unwrap_or(b"")))
            }
          }
        _ => ()
      }
      out.write_bytes(d.finish())
      Json::string(@codec.hex_encode(out.to_bytes()))
    }
    "flate.zlib_compress" => Json::string(@codec.hex_encode(@flate.zlib_compress(std_bytes(ask, "hex"))))
    "flate.zlib_decompress" => std_opt_bytes(@flate.zlib_decompress(std_bytes(ask, "hex")))
    "flate.gzip" => Json::string(@codec.hex_encode(@flate.gzip(std_bytes(ask, "hex"))))
    "flate.gunzip" => std_opt_bytes(@flate.gunzip(std_bytes(ask, "hex")))
    _ => @station_main.upstream_op(host, ask)
  }
}

///|
async fn harness_upstream(host : @host.Host) -> Unit {
  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let ask = @json.parse(line) catch { _ => Json::null() }
    let id = std_at(ask, "id").unwrap_or(Json::null())
    let value = upstream_eval(host, ask)
    host.say(Json::object({ "id": id, "value": value }).stringify())
  }
}
