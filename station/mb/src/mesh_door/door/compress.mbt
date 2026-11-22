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
/// A zstd stream: each piece given comes out flushed; `finish` ends the frame once on normal EOF.
pub(all) struct Packing {
  push : async (Bytes) -> Bytes
  finish : async () -> Bytes
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
fn media_type(t : String) -> String {
  let base = match t.find(";") {
    Some(i) => t.unsafe_substring(start=0, end=i)
    None => t
  }
  base.trim(chars=" \t\n\r").to_owned().to_lower()
}

///|
fn texty(t : String, extra_types : Array[String]) -> Bool {
  let m = media_type(t)
  m == "application/json" ||
  m == "application/x-ndjson" ||
  m.has_prefix("text/") ||
  extra_types.contains(m)
}

///|
/// `answer` as it goes to a client that asked with `headers` for `path` (after /admin/api): compressed where it can be.
pub async fn compressed(
  packer : Packer,
  answer : Answer,
  headers : Array[(String, String)],
  path : String,
  extra_types? : Array[String] = [],
) -> Answer {
  if !asks_zstd(headers) ||
    path.has_prefix("/preview/") ||
    header_of(answer.headers, "content-encoding") is Some(_) {
    return answer
  }
  if !texty(header_of(answer.headers, "content-type").unwrap_or(""), extra_types) {
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
      let mut ended = false
      let close = () => if !closed {
        closed = true
        (z.close)()
      }
      let next = async fn() -> Bytes? {
        if closed || ended {
          return None
        }
        let item = (source.next)() catch {
          e => {
            close()
            raise e
          }
        }
        if closed {
          return None
        }
        match item {
          None => {
            ended = true
            let tail = (z.finish)() catch {
              e => {
                close()
                raise e
              }
            }
            if closed {
              return None
            }
            close()
            if tail.length() > 0 {
              Some(tail)
            } else {
              None
            }
          }
          Some(piece) => {
            let out = (z.push)(piece) catch {
              e => {
                close()
                raise e
              }
            }
            if closed {
              return None
            }
            Some(out)
          }
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
