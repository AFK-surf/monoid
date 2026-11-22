// Zero-dependency AWS SigV4 S3/R2 client and end-to-end encrypted `S3Place` (station/src/replica/s3.ts).

///|
pub let s3_multipart_threshold : Int = 16777216

///|
pub let s3_multipart_part_size : Int = 8388608

///|
fn hex_upper_digit(n : Int) -> Char {
  if n < 10 {
    Int::unsafe_to_char('0' + n)
  } else {
    Int::unsafe_to_char('A' + n - 10)
  }
}

///|
/// RFC 3986 percent-encoding (preserves `A-Z a-z 0-9 - _ . ~`).
pub fn rfc3986_encode(s : String) -> String {
  let bytes = @utf8.encode(s)
  let out = StringBuilder::new()
  for b in bytes {
    let c = b.to_int()
    let unreserved = (c >= 'A' && c <= 'Z') ||
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '.' ||
      c == '~'
    if unreserved {
      out.write_char(Int::unsafe_to_char(c))
    } else {
      out.write_char('%')
      out.write_char(hex_upper_digit((c >> 4) & 0xF))
      out.write_char(hex_upper_digit(c & 0xF))
    }
  }
  out.to_string()
}

///|
pub fn encode_s3_path(key : String) -> String {
  key.split("/").map(seg => rfc3986_encode(seg.to_string())).collect().join("/")
}

///|
fn pad2(n : Int) -> String {
  if n < 10 { "0\{n}" } else { "\{n}" }
}

///|
fn pad4(n : Int) -> String {
  if n < 10 {
    "000\{n}"
  } else if n < 100 {
    "00\{n}"
  } else if n < 1000 {
    "0\{n}"
  } else {
    "\{n}"
  }
}

///|
/// Converts epoch ms to AWS SigV4 `(amzDate: YYYYMMDDTHHMMSSZ, dateStamp: YYYYMMDD)`.
pub fn format_amz_date(ms : Double) -> (String, String) {
  let p = @time.utc_parts(ms.to_int64())
  let date_stamp = "\{pad4(p.year)}\{pad2(p.month)}\{pad2(p.day)}"
  ("\{date_stamp}T\{pad2(p.hour)}\{pad2(p.minute)}\{pad2(p.second)}Z", date_stamp)
}

///|
fn parse_radix_int(s : String, base : Int) -> Int? {
  if s.length() == 0 {
    return None
  }
  let mut acc = 0
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    let d = if c >= '0' && c <= '9' {
      c - '0'
    } else if c >= 'a' && c <= 'f' {
      c - 'a' + 10
    } else if c >= 'A' && c <= 'F' {
      c - 'A' + 10
    } else {
      return None
    }
    if d >= base {
      return None
    }
    acc = acc * base + d
  }
  Some(acc)
}

///|
pub fn unescape_xml(s : String) -> String {
  let out = StringBuilder::new()
  let n = s.length()
  let mut i = 0
  while i < n {
    if s.unsafe_charcode_at(i) == '&' {
      let mut semi = -1
      let limit = if i + 12 < n { i + 12 } else { n }
      for j in (i + 1)..<limit {
        if s.unsafe_charcode_at(j) == ';' {
          semi = j
          break
        }
      }
      if semi > i {
        let ent = s.unsafe_substring(start=i + 1, end=semi)
        if ent == "amp" {
          out.write_char('&')
          i = semi + 1
          continue
        } else if ent == "lt" {
          out.write_char('<')
          i = semi + 1
          continue
        } else if ent == "gt" {
          out.write_char('>')
          i = semi + 1
          continue
        } else if ent == "quot" {
          out.write_char('"')
          i = semi + 1
          continue
        } else if ent == "apos" {
          out.write_char('\'')
          i = semi + 1
          continue
        } else if ent.has_prefix("#x") && ent.length() > 2 {
          let hex_s = ent.unsafe_substring(start=2, end=ent.length())
          match parse_radix_int(hex_s, 16) {
            Some(cp) if cp >= 0 && cp <= 0x10FFFF => {
              out.write_char(Int::unsafe_to_char(cp))
              i = semi + 1
              continue
            }
            _ => ()
          }
        } else if ent.has_prefix("#") && ent.length() > 1 {
          let dec_s = ent.unsafe_substring(start=1, end=ent.length())
          match parse_radix_int(dec_s, 10) {
            Some(cp) if cp >= 0 && cp <= 0x10FFFF => {
              out.write_char(Int::unsafe_to_char(cp))
              i = semi + 1
              continue
            }
            _ => ()
          }
        }
      }
    }
    out.write_char(Int::unsafe_to_char(s.unsafe_charcode_at(i)))
    i += 1
  }
  out.to_string()
}

///|
/// Extracts all occurrences of `<tag>...</tag>` (or `<ns:tag ...>...</ns:tag>`) from XML text.
pub fn extract_all_xml_tags(xml : String, tag : String) -> Array[String] {
  let out : Array[String] = []
  let open_plain = "<\{tag}"
  let close_plain = "</\{tag}>"
  let n = xml.length()
  let mut pos = 0
  while pos < n {
    let start = match xml.unsafe_substring(start=pos, end=n).find(open_plain) {
      Some(rel) => pos + rel
      None => break
    }
    let after_name = start + open_plain.length()
    if after_name >= n {
      break
    }
    let next_ch = xml.unsafe_charcode_at(after_name)
    if next_ch != '>' && next_ch != ' ' && next_ch != '\t' && next_ch != '\n' && next_ch != '\r' {
      pos = after_name
      continue
    }
    let open_end = match xml.unsafe_substring(start=after_name, end=n).find(">") {
      Some(rel) => after_name + rel
      None => break
    }
    let close_start = match xml.unsafe_substring(start=open_end + 1, end=n).find(close_plain) {
      Some(rel) => open_end + 1 + rel
      None => break
    }
    out.push(unescape_xml(xml.unsafe_substring(start=open_end + 1, end=close_start)))
    pos = close_start + close_plain.length()
  }
  out
}

///|
pub fn extract_xml_tag(xml : String, tag : String) -> String? {
  let all = extract_all_xml_tags(xml, tag)
  if all.length() > 0 { Some(all[0]) } else { None }
}

///|
fn parse_endpoint_parts(endpoint : String) -> (String, String, String, String) {
  let (proto, rest) = if endpoint.has_prefix("https://") {
    ("https:", endpoint.unsafe_substring(start=8, end=endpoint.length()))
  } else {
    ("http:", endpoint.unsafe_substring(start=7, end=endpoint.length()))
  }
  let (host, path) = match rest.find("/") {
    Some(i) => (rest.unsafe_substring(start=0, end=i), strip_trailing_slashes(rest.unsafe_substring(start=i, end=rest.length())))
    None => (rest, "")
  }
  let (hostname, port) = if host.has_prefix("[") {
    match host.find("]") {
      Some(i) => {
        let hn = host.unsafe_substring(start=0, end=i + 1)
        let pt = if i + 2 < host.length() && host.unsafe_charcode_at(i + 1) == ':' {
          host.unsafe_substring(start=i + 2, end=host.length())
        } else {
          ""
        }
        (hn, pt)
      }
      None => (host, "")
    }
  } else {
    match host.find(":") {
      Some(i) => (host.unsafe_substring(start=0, end=i), host.unsafe_substring(start=i + 1, end=host.length()))
      None => (host, "")
    }
  }
  let full_host = if port != "" { "\{hostname}:\{port}" } else { hostname }
  (proto, full_host, hostname, path)
}

///|
pub struct SignedS3Request {
  url : String
  headers : Array[(String, String)]
}

///|
/// Computes URL and AWS SigV4 headers for an S3 request.
pub fn sign_s3_request(
  target : S3TargetConfig,
  method_ : String,
  key : String,
  query : Array[(String, String)],
  body : Bytes,
  now_ms : Double,
  extra_headers? : Array[(String, String)] = [],
) -> SignedS3Request {
  let (proto, full_host, hostname, base_path) = parse_endpoint_parts(target.endpoint)
  let clean_key = if key.has_prefix("/") {
    let mut k = 0
    while k < key.length() && key.unsafe_charcode_at(k) == '/' {
      k += 1
    }
    key.unsafe_substring(start=k, end=key.length())
  } else {
    key
  }
  let port = if full_host.length() > hostname.length() + 1 {
    full_host.unsafe_substring(start=hostname.length() + 1, end=full_host.length())
  } else {
    ""
  }
  let (host_header, url_origin, raw_path) = if target.force_path_style {
    let p = if clean_key == "" {
      "\{base_path}/\{rfc3986_encode(target.bucket)}"
    } else {
      "\{base_path}/\{rfc3986_encode(target.bucket)}/\{encode_s3_path(clean_key)}"
    }
    (full_host, "\{proto}//\{full_host}", p)
  } else {
    let vhost = "\{target.bucket}.\{hostname}"
    let hh = if port != "" { "\{vhost}:\{port}" } else { vhost }
    let p = if clean_key == "" { "\{base_path}/" } else { "\{base_path}/\{encode_s3_path(clean_key)}" }
    (hh, "\{proto}//\{hh}", p)
  }
  let canonical_path = if raw_path.has_prefix("/") { raw_path } else { "/\{raw_path}" }

  let encoded_query = query.map(p => (rfc3986_encode(p.0), rfc3986_encode(p.1)))
  encoded_query.sort_by((a, b) => {
    let c = js_cmp(a.0, b.0)
    if c != 0 { c } else { js_cmp(a.1, b.1) }
  })
  let canonical_query = encoded_query.map(p => "\{p.0}=\{p.1}").join("&")

  let (amz_date, date_stamp) = format_amz_date(now_ms)
  let payload_hash = @hash.sha256_hex(body[:])

  let lower : Map[String, String] = {
    "host": host_header,
    "x-amz-content-sha256": payload_hash,
    "x-amz-date": amz_date,
  }
  for h in extra_headers {
    lower[h.0.to_lower()] = h.1.trim().to_string()
  }
  let keys = lower.keys().collect()
  keys.sort_by(js_cmp)
  let canon_hdrs = StringBuilder::new()
  for k in keys {
    canon_hdrs.write_string("\{k}:\{lower.get(k).unwrap_or("")}\n")
  }
  let signed_headers = keys.join(";")
  let canonical_request = "\{method_}\n\{canonical_path}\n\{canonical_query}\n\{canon_hdrs.to_string()}\n\{signed_headers}\n\{payload_hash}"

  let scope = "\{date_stamp}/\{target.region}/s3/aws4_request"
  let string_to_sign = "AWS4-HMAC-SHA256\n\{amz_date}\n\{scope}\n\{@hash.sha256_utf8_hex(canonical_request)}"
  let k_date = @hash.hmac_sha256(@utf8.encode("AWS4\{target.secret_access_key}")[:], @utf8.encode(date_stamp)[:])
  let k_region = @hash.hmac_sha256(k_date[:], @utf8.encode(target.region)[:])
  let k_service = @hash.hmac_sha256(k_region[:], b"s3"[:])
  let k_signing = @hash.hmac_sha256(k_service[:], b"aws4_request"[:])
  let signature = @hash.hex_encode(@hash.hmac_sha256(k_signing[:], @utf8.encode(string_to_sign)[:])[:])

  let headers : Array[(String, String)] = []
  for h in extra_headers {
    headers.push(h)
  }
  headers.push(("x-amz-content-sha256", payload_hash))
  headers.push(("x-amz-date", amz_date))
  headers.push(("authorization", "AWS4-HMAC-SHA256 Credential=\{target.access_key_id}/\{scope}, SignedHeaders=\{signed_headers}, Signature=\{signature}"))
  let url = if canonical_query == "" { "\{url_origin}\{canonical_path}" } else { "\{url_origin}\{canonical_path}?\{canonical_query}" }
  { url, headers }
}

///|
pub struct S3Client {
  target : S3TargetConfig
  host : @host.Host
  now : () -> Double
  multipart_threshold : Int
  multipart_part_size : Int
}

///|
pub fn S3Client::new(
  target : S3TargetConfig,
  host : @host.Host,
  now : () -> Double,
  multipart_threshold? : Int = s3_multipart_threshold,
  multipart_part_size? : Int = s3_multipart_part_size,
) -> S3Client {
  { target, host, now, multipart_threshold, multipart_part_size }
}

///|
fn s3_http_error(status : Int, msg : String) -> Thrown {
  Thrown("S3HttpError", jo([("status", ji(status)), ("message", js(msg))]))
}

///|
async fn S3Client::request(
  self : S3Client,
  method_ : String,
  key : String,
  query : Array[(String, String)],
  body : Bytes,
  extra_headers? : Array[(String, String)] = [],
) -> @host.FetchResponse {
  let signed = sign_s3_request(self.target, method_, key, query, body, (self.now)(), extra_headers~)
  let send_body : Bytes? = if method_ == "GET" || method_ == "HEAD" || method_ == "DELETE" { None } else { Some(body) }
  self.host.fetch(signed.url, method_=method_, headers=signed.headers, body?=send_body)
}

///|
pub async fn S3Client::test_connection(self : S3Client) -> Unit {
  let query : Array[(String, String)] = [("list-type", "2"), ("max-keys", "1")]
  if self.target.prefix != "" {
    query.push(("prefix", "\{self.target.prefix}/"))
  }
  let res = self.request("GET", "", query, b"")
  if res.status < 200 || res.status >= 300 {
    let text = res.text()
    let code = extract_xml_tag(text, "Code").unwrap_or("")
    let msg = extract_xml_tag(text, "Message").unwrap_or("")
    let detail = if code != "" || msg != "" { "S3 \{res.status}: \{code} \{msg}".trim().to_string() } else { "S3 \{res.status}" }
    raise s3_http_error(res.status, detail)
  }
}

///|
pub async fn S3Client::list_prefix(self : S3Client, prefix : String) -> Array[String] {
  let keys : Array[String] = []
  let mut token : String? = None
  while true {
    let query : Array[(String, String)] = [("list-type", "2"), ("prefix", prefix)]
    match token {
      Some(t) => query.push(("continuation-token", t))
      None => ()
    }
    let res = self.request("GET", "", query, b"")
    let xml = res.text()
    if res.status < 200 || res.status >= 300 {
      raise s3_http_error(res.status, "S3 ListObjectsV2 failed (\{res.status}): \{extract_xml_tag(xml, "Message").unwrap_or("")}")
    }
    for k in extract_all_xml_tags(xml, "Key") {
      keys.push(k)
    }
    let truncated = extract_xml_tag(xml, "IsTruncated")
    let next = extract_xml_tag(xml, "NextContinuationToken")
    if truncated == Some("true") && next is Some(nt) && nt != "" {
      token = Some(nt)
    } else {
      break
    }
  }
  keys
}

///|
pub async fn S3Client::get_object(self : S3Client, key : String) -> Bytes {
  let res = self.request("GET", key, [], b"")
  if res.status < 200 || res.status >= 300 {
    raise s3_http_error(res.status, "S3 GET \{key} failed (\{res.status})")
  }
  res.body
}

///|
pub async fn S3Client::put_object(self : S3Client, key : String, bytes : Bytes) -> Unit {
  let res = self.request("PUT", key, [], bytes, extra_headers=[("content-type", "application/octet-stream")])
  if res.status < 200 || res.status >= 300 {
    raise s3_http_error(res.status, "S3 PUT \{key} failed (\{res.status})")
  }
}

///|
pub async fn S3Client::put_stream(self : S3Client, key : String, next : async () -> Bytes?) -> Unit {
  let threshold = self.multipart_threshold
  let part_size = self.multipart_part_size
  let mut pending : Bytes = b""
  let mut upload_id : String? = None
  let parts : Array[(Int, String)] = []

  let flush_part = async fn(uid : String, data : Bytes) {
    let pn = parts.length() + 1
    let res = self.request("PUT", key, [("partNumber", "\{pn}"), ("uploadId", uid)], data)
    if res.status < 200 || res.status >= 300 {
      raise s3_http_error(res.status, "S3 UploadPart \{pn} failed (\{res.status})")
    }
    let etag = res.header("etag").unwrap_or("")
    parts.push((pn, etag))
  }

  try {
    while next() is Some(piece) {
      if piece.length() == 0 {
        continue
      }
      let b = @buffer.new(size_hint=pending.length() + piece.length())
      b.write_bytes(pending)
      b.write_bytes(piece)
      pending = b.to_bytes()
      if upload_id is None && pending.length() > threshold {
        let res = self.request("POST", key, [("uploads", "")], b"", extra_headers=[("content-type", "application/octet-stream")])
        let xml = res.text()
        if res.status < 200 || res.status >= 300 {
          raise s3_http_error(res.status, "S3 CreateMultipartUpload failed (\{res.status})")
        }
        match extract_xml_tag(xml, "UploadId") {
          Some(id) if id != "" => upload_id = Some(id)
          _ => raise failed("S3 CreateMultipartUpload returned no UploadId")
        }
      }
      match upload_id {
        Some(uid) =>
          while pending.length() >= part_size {
            let chunk = pending[0:part_size].to_bytes()
            pending = pending[part_size:].to_bytes()
            flush_part(uid, chunk)
          }
        None => ()
      }
    }
    match upload_id {
      None => self.put_object(key, pending)
      Some(uid) => {
        if pending.length() > 0 {
          flush_part(uid, pending)
        }
        let xml = StringBuilder::new()
        xml.write_string("<CompleteMultipartUpload>")
        for p in parts {
          xml.write_string("<Part><PartNumber>\{p.0}</PartNumber><ETag>\{p.1}</ETag></Part>")
        }
        xml.write_string("</CompleteMultipartUpload>")
        let res = self.request("POST", key, [("uploadId", uid)], @utf8.encode(xml.to_string()), extra_headers=[("content-type", "application/xml")])
        if res.status < 200 || res.status >= 300 {
          raise s3_http_error(res.status, "S3 CompleteMultipartUpload failed (\{res.status})")
        }
      }
    }
  } catch {
    e => {
      match upload_id {
        Some(uid) => ignore(self.request("DELETE", key, [("uploadId", uid)], b"")) catch { _ => () }
        None => ()
      }
      raise e
    }
  }
}

///|
pub async fn S3Client::delete_object(self : S3Client, key : String) -> Unit {
  let res = self.request("DELETE", key, [], b"")
  if (res.status < 200 || res.status >= 300) && res.status != 404 {
    raise s3_http_error(res.status, "S3 DELETE \{key} failed (\{res.status})")
  }
}

///|
/// End-to-end encrypted S3/R2 place implementing `Place` + discovery (`origins`) + streaming restore (`read`).
pub struct S3Place {
  target : S3TargetConfig
  client : S3Client
  crypto : @vault_crypto.Crypto
  fs : Fs
  key : Bytes
  present_file_tags : Map[String, Map[String, Bool]]
}

///|
pub fn S3Place::new(
  target : S3TargetConfig,
  w : World,
) -> S3Place raise {
  let key = parse_encryption_key(target.encryption_key)
  let client = S3Client::new(target, w.host, w.clock.now)
  let crypto = @vault_crypto.Crypto::of_host(w.host)
  { target, client, crypto, fs: w.fs, key, present_file_tags: {} }
}

///|
pub fn S3Place::ws_tag(self : S3Place, ws : String) -> String {
  @hash.hex_encode(@hash.hmac_sha256(self.key[:], @utf8.encode("ws:\{ws}")[:])[:]).unsafe_substring(start=0, end=32)
}

///|
pub fn S3Place::origin_tag(self : S3Place, origin : String) -> String {
  @hash.hex_encode(@hash.hmac_sha256(self.key[:], @utf8.encode("origin:\{origin}")[:])[:]).unsafe_substring(start=0, end=32)
}

///|
pub fn S3Place::file_tag(self : S3Place, hash : String) -> String {
  @hash.hex_encode(@hash.hmac_sha256(self.key[:], @utf8.encode("file:\{hash}")[:])[:])
}

///|
fn S3Place::prefixed(self : S3Place, rel : String) -> String {
  if self.target.prefix == "" { rel } else { "\{self.target.prefix}/\{rel}" }
}

///|
fn S3Place::head_key(self : S3Place, ws : String, origin : String, gen : String) -> String {
  self.prefixed("\{self.ws_tag(ws)}/\{self.origin_tag(origin)}/head/\{gen}.enc")
}

///|
fn S3Place::batch_key(self : S3Place, ws : String, origin : String, gen : String, name : String) -> String {
  self.prefixed("\{self.ws_tag(ws)}/\{self.origin_tag(origin)}/log/\{gen}/\{name}.enc")
}

///|
fn S3Place::file_key(self : S3Place, ws : String, origin : String, hash : String) -> String {
  self.prefixed("\{self.ws_tag(ws)}/\{self.origin_tag(origin)}/files/\{self.file_tag(hash)}.enc")
}

///|
pub async fn S3Place::held(self : S3Place, ws : String, origin : String) -> Held {
  check(ws, origin)
  let wt = self.ws_tag(ws)
  let ot = self.origin_tag(origin)
  let base = self.prefixed("\{wt}/\{ot}/")
  let keys = self.client.list_prefix(base)

  let head_gens : Array[String] = []
  let batches_by_gen : Map[String, Array[String]] = {}
  let file_tags : Map[String, Bool] = {}

  for full_key in keys {
    if !full_key.has_prefix(base) {
      continue
    }
    let rel = full_key.unsafe_substring(start=base.length(), end=full_key.length())
    if rel.has_prefix("head/") && rel.has_suffix(".enc") {
      let gen = rel.unsafe_substring(start=5, end=rel.length() - 4)
      if is_gen(gen) {
        head_gens.push(gen)
      }
    } else if rel.has_prefix("log/") && rel.has_suffix(".enc") {
      let rest = rel.unsafe_substring(start=4, end=rel.length() - 4)
      match rest.find("/") {
        Some(slash) if slash > 0 => {
          let gen = rest.unsafe_substring(start=0, end=slash)
          let batch = rest.unsafe_substring(start=slash + 1, end=rest.length())
          if is_gen(gen) && is_batch(batch) {
            match batches_by_gen.get(gen) {
              Some(xs) => xs.push(batch)
              None => batches_by_gen[gen] = [batch]
            }
          }
        }
        _ => ()
      }
    } else if rel.has_prefix("files/") && rel.has_suffix(".enc") {
      let tag = rel.unsafe_substring(start=6, end=rel.length() - 4)
      if is_hash(tag) {
        file_tags[tag] = true
      }
    }
  }

  self.present_file_tags["\{ws}\n\{origin}"] = file_tags

  let head_map : Map[String, J?] = {}
  let all_gens : Map[String, Bool] = {}
  for g in head_gens {
    all_gens[g] = true
    let parsed : J? = try {
      let enc = self.client.get_object(self.head_key(ws, origin, g))
      let plain = sfb1_open(self.crypto, self.key, ws, ot, "head/\{g}", enc)
      match as_head(parse(@utf8.decode_lossy(plain))) {
        Some(h) if text_at(h, "origin") == origin && text_at(h, "workspace") == ws && head_gen(h) == g => Some(h)
        _ => None
      }
    } catch {
      _ => None
    }
    head_map[g] = parsed
  }
  for g, _ in batches_by_gen {
    all_gens[g] = true
  }

  let gens : Array[Holding] = []
  let present_hashes : Map[String, Bool] = {}
  for gen, _ in all_gens {
    let head = head_map.get(gen).unwrap_or(None)
    let batches = batches_by_gen.get(gen).unwrap_or([])
    batches.sort_by(js_cmp)
    gens.push({ gen, head, batches })
    match head {
      Some(h) =>
        for f in head_files(h) {
          if file_tags.contains(self.file_tag(f)) {
            present_hashes[f] = true
          }
        }
      None => ()
    }
  }
  gens.sort_by((a, b) => {
    let d = gen_made(a.gen) - gen_made(b.gen)
    if d < 0.0 {
      -1
    } else if d > 0.0 {
      1
    } else if js_less(a.gen, b.gen) {
      -1
    } else {
      1
    }
  })
  { gens, files: present_hashes.keys().collect() }
}

///|
pub async fn S3Place::put(self : S3Place, ws : String, origin : String, gen : String, kind : String, name : String, bytes : Bytes) -> Unit {
  check(ws, origin, gen~)
  if kind == "batch" {
    if !is_batch(name) {
      raise failed("not a batch's name")
    }
    let enc = sfb1_seal(self.crypto, self.key, ws, origin, "log/\{gen}/\{name}", bytes)
    self.client.put_object(self.batch_key(ws, origin, gen, name), enc)
  } else {
    let ot = self.origin_tag(origin)
    let enc = sfb1_seal(self.crypto, self.key, ws, ot, "head/\{gen}", bytes)
    self.client.put_object(self.head_key(ws, origin, gen), enc)
  }
}

///|
pub async fn S3Place::put_file(self : S3Place, ws : String, origin : String, hash : String, source : String) -> Unit {
  check(ws, origin)
  if !is_hash(hash) {
    raise failed("not a file's hash")
  }
  let size = match self.fs.stat(source) {
    Some((_, s, _)) => s
    None => raise failed("ENOENT: \{source}")
  }
  let reader = File(source, 0.0, size).reader(self.fs)
  let enc_stream = sfb1_seal_stream(self.crypto, self.key, ws, origin, "files/\{hash}", reader)
  self.client.put_stream(self.file_key(ws, origin, hash), enc_stream)
  match self.present_file_tags.get("\{ws}\n\{origin}") {
    Some(tags) => tags[self.file_tag(hash)] = true
    None => ()
  }
}

///|
pub async fn S3Place::drop(self : S3Place, ws : String, origin : String, gen : String, batches : Array[String], files : Array[String]) -> Unit {
  check(ws, origin, gen~)
  for b in batches {
    if is_batch(b) {
      self.client.delete_object(self.batch_key(ws, origin, gen, b))
    }
  }
  let tags = self.present_file_tags.get("\{ws}\n\{origin}")
  for f in files {
    if is_hash(f) {
      self.client.delete_object(self.file_key(ws, origin, f))
      match tags {
        Some(m) => m.remove(self.file_tag(f))
        None => ()
      }
    }
  }
}

///|
pub fn S3Place::place(self : S3Place) -> Place {
  {
    held: (ws, origin) => self.held(ws, origin),
    put: (ws, origin, gen, kind, name, bytes) => self.put(ws, origin, gen, kind, name, bytes),
    put_file: (ws, origin, hash, source) => self.put_file(ws, origin, hash, source),
    drop: (ws, origin, gen, batches, files) => self.drop(ws, origin, gen, batches, files),
  }
}

///|
pub async fn S3Place::origins(self : S3Place, ws : String) -> Array[(String, Array[J])] {
  if !is_workspace(ws) {
    return []
  }
  let base = self.prefixed("\{self.ws_tag(ws)}/")
  let keys = self.client.list_prefix(base)
  let by_origin : Map[String, Array[J]] = {}
  for full_key in keys {
    if !full_key.has_prefix(base) {
      continue
    }
    let rel = full_key.unsafe_substring(start=base.length(), end=full_key.length())
    let parts = rel.split("/").map(s => s.to_string()).collect()
    if parts.length() == 3 && parts[1] == "head" && parts[2].has_suffix(".enc") {
      let ot = parts[0]
      let gen = parts[2].unsafe_substring(start=0, end=parts[2].length() - 4)
      if ot.length() == 32 && all_of(ot, is_hex_char) && is_gen(gen) {
        try {
          let enc = self.client.get_object(full_key)
          let plain = sfb1_open(self.crypto, self.key, ws, ot, "head/\{gen}", enc)
          match as_head(parse(@utf8.decode_lossy(plain))) {
            Some(h) if text_at(h, "workspace") == ws && head_gen(h) == gen && self.origin_tag(text_at(h, "origin")) == ot => {
              let orig = text_at(h, "origin")
              match by_origin.get(orig) {
                Some(xs) => xs.push(h)
                None => by_origin[orig] = [h]
              }
            }
            _ => ()
          }
        } catch {
          _ => ()
        }
      }
    }
  }
  let out : Array[(String, Array[J])] = []
  for origin, heads in by_origin {
    heads.sort_by((a, b) => {
      let d = gen_made(head_gen(a)) - gen_made(head_gen(b))
      if d < 0.0 { -1 } else if d > 0.0 { 1 } else if js_less(head_gen(a), head_gen(b)) { -1 } else { 1 }
    })
    out.push((origin, heads))
  }
  out
}

///|
pub async fn S3Place::read(self : S3Place, ws : String, origin : String, gen : String?, name : String) -> Body {
  check(ws, origin, gen?)
  match gen {
    None => {
      if !is_hash(name) {
        raise failed("not a file's hash")
      }
      let enc = self.client.get_object(self.file_key(ws, origin, name))
      Whole(sfb1_open(self.crypto, self.key, ws, origin, "files/\{name}", enc))
    }
    Some(g) =>
      if name == "head.json" {
        let enc = self.client.get_object(self.head_key(ws, origin, g))
        Whole(sfb1_open(self.crypto, self.key, ws, self.origin_tag(origin), "head/\{g}", enc))
      } else if is_batch(name) {
        let enc = self.client.get_object(self.batch_key(ws, origin, g, name))
        Whole(sfb1_open(self.crypto, self.key, ws, origin, "log/\{g}/\{name}", enc))
      } else {
        raise failed("not a copy's name")
      }
  }
}
