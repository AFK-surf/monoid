// gzip (RFC 1952) of a deflate stream (RFC 1951), base/flate's. What Node's zlib.gzip makes of the same bytes is other
// bytes; what either gives back unpacked is the same (station/src/feishu/register.ts `encodeAddons`: the
// registration's link carries the app's addons so, and Feishu unpacks them).

///|
/// `data` deflated (raw).
pub fn deflate(data : BytesView) -> Bytes {
  @flate.deflate(data)
}

///|
/// `data` gzipped: no name, no time, made on Unix.
pub fn gzip(data : BytesView) -> Bytes {
  @flate.gzip(data)
}

///|
/// Base64url without padding (`Buffer.toString("base64url")`).
pub fn base64url(b : BytesView) -> String {
  @codec.base64url_encode(b)
}

///|
/// Base64 with padding (`Buffer.toString("base64")`).
pub fn base64(b : BytesView) -> String {
  @codec.base64_encode(b)
}
