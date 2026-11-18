// Answers compressed for a client that asks so (`accept-encoding: zstd`; station/src/mesh/compress.ts): a whole answer
// at zstd's fast level, an event stream (and a batch's answers a line at a time, `application/x-ndjson`) each piece
// flushed against the last megabyte of the stream. JSON and text only, nothing of a preview, never what says an
// encoding already. The zstd itself is the carrier's (`Packer`: the shell's `zstd.compress` and `zstd.stream`).

///|
pub let zstd : String = "zstd"

///|
/// A whole answer smaller than this goes as it is.
pub let small : Int = 512

///|
/// zstd's fast level, and how far back a stream's pieces are compressed against (2^20).
pub let level : Int = 3

///|
pub let window_log : Int = 20

///|
/// A zstd stream: each piece given comes out flushed.
pub(all) struct Packing {
  push : async (Bytes) -> Bytes
  close : () -> Unit
}

///|
/// What compresses: whole at a level (window `window_log`), or a stream at `level`.
pub(all) struct Packer {
  whole : async (Bytes, Int) -> Bytes
  stream : async () -> Packing
}

///|
/// Whether `headers` ask for zstd.
pub fn asks_zstd(headers : Array[(String, String)]) -> Bool {
  match header_of(headers, "accept-encoding") {
    None => false
    Some(s) => s.split(",").any(e => e.trim(chars=" \t\n\r").to_owned() == zstd)
  }
}

///|
fn texty(t : String) -> Bool {
  t.has_prefix("application/json") ||
  t.has_prefix("application/x-ndjson") ||
  t.has_prefix("text/")
}

///|
/// `answer` as it goes to a client that asked with `headers` for `path` (after /admin/api): compressed where it can be.
pub async fn compressed(
  packer : Packer,
  answer : Answer,
  headers : Array[(String, String)],
  path : String,
) -> Answer {
  if !asks_zstd(headers) ||
    path.has_prefix("/preview/") ||
    header_of(answer.headers, "content-encoding") is Some(_) {
    return answer
  }
  if !texty(header_of(answer.headers, "content-type").unwrap_or("")) {
    return answer
  }
  // A length said was of what it says, not of what is sent: none is said.
  let sent = answer.headers.filter(kv => kv.0.to_lower() != "content-length")
  sent.push(("content-encoding", zstd))
  match answer.body {
    Whole(body) => {
      if body.length() < small {
        return answer
      }
      let out = (packer.whole)(body, level)
      { status: answer.status, headers: sent, body: Whole(out) }
    }
    Coming(source) => {
      let z = (packer.stream)()
      let mut closed = false
      let close = () => if !closed {
        closed = true
        (z.close)()
      }
      let next = async fn() -> Bytes? {
        match (source.next)() {
          None => {
            close()
            None
          }
          Some(piece) => Some((z.push)(piece))
        }
      }
      let stop = () => {
        close()
        (source.stop)()
      }
      { status: answer.status, headers: sent, body: Coming({ next, stop }) }
    }
  }
}
