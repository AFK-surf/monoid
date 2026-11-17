// Files over the station transport (station/src/mesh/files.ts): a file goes in one request or one answer, its bytes
// after the head as they are read, at the pace the other end takes them. Bytes that come or go are `Pieces`: the next
// piece as it is wanted, and their sending stopped.

///|
/// How much of a file is read at once as it is sent.
pub let piece : Int = 1024 * 1024

///|
/// Bytes as they come (bus.ts `Bytes`): the next piece, None after the last; `stop`, none wanted after all.
pub(all) struct Pieces {
  next : async () -> Bytes?
  stop : async () -> Unit
}

///|
/// A file opened to be read: `read_at(at, length)` gives up to `length` bytes from `at` (none at its end).
pub(all) struct FileReading {
  read_at : async (Int64, Int) -> Bytes
  close : async () -> Unit
}

///|
/// The bytes of the file `open` opens from `offset` up to `end`, read as they are sent (`fileBytes`): opened when the
/// first are wanted (never, when nothing takes them) and closed after the last or when sending stops. A file that ends
/// before `end` fails them.
pub fn file_bytes(open : async () -> FileReading, offset : Int64, end : Int64) -> Pieces {
  let file : Ref[FileReading?] = Ref(None)
  let at = Ref(offset)
  let over = Ref(offset >= end)
  let close = async fn() {
    if file.val is Some(f) {
      file.val = None
      (f.close)()
    }
  }
  {
    next: async fn() -> Bytes? {
      if over.val {
        return None
      }
      let f = match file.val {
        Some(f) => f
        None => {
          let f = open()
          file.val = Some(f)
          f
        }
      }
      if at.val >= end {
        over.val = true
        close()
        return None
      }
      let want = if end - at.val < piece.to_int64() { (end - at.val).to_int() } else { piece }
      let got = (f.read_at)(at.val, want) catch {
        e => {
          over.val = true
          close()
          raise e
        }
      }
      if got.length() == 0 {
        over.val = true
        close()
        raise Failure("the file got shorter while it was sent")
      }
      at.val = at.val + got.length().to_int64()
      Some(got)
    },
    stop: async fn() {
      over.val = true
      close()
    },
  }
}

///|
/// A file of this machine read by the shell (`fs.bytes`), refused where it is a link (`O_NOFOLLOW`) or not there.
pub async fn shell_file(host : @host.Host, path : String) -> FileReading {
  let (kind, _) = host.shell("fs.stat", { "path": jstr(path), "lstat": Json::boolean(true) })
  match kind {
    String("file") => ()
    String("link") => raise Failure("ELOOP: too many symbolic links encountered, open '\{path}'")
    _ => raise Failure("ENOENT: no such file or directory, open '\{path}'")
  }
  {
    read_at: async fn(at : Int64, length : Int) -> Bytes {
      let (hex, _) = host.shell("fs.bytes", { "path": jstr(path), "from": jnum(at.to_double()), "length": jnum(length.to_double()) })
      match hex {
        String(h) => @hex.decode(h[:]) catch { _ => raise Failure("the file could not be read") }
        _ => raise Failure("ENOENT: no such file or directory, open '\{path}'")
      }
    },
    close: async fn() {  },
  }
}

///|
/// `bytes` in one piece: what a request or answer carries that is already in memory.
pub fn one_bytes(bytes : Bytes) -> Pieces {
  let given = Ref(bytes.length() == 0)
  { next: async fn() -> Bytes? { if given.val { None } else { given.val = true; Some(bytes) } }, stop: async fn() { given.val = true } }
}

///|
/// `bytes` written at `offset` on, all of them (`write(piece, at)` writes it whole there); how many. More than `limit`
/// from where the file begins fails.
pub async fn write_bytes(write : async (Bytes, Int64) -> Unit, bytes : Pieces, offset : Int64, limit : Int64) -> Int64 {
  let mut at = offset
  while (bytes.next)() is Some(p) {
    if at + p.length().to_int64() > limit {
      raise Failure("more came than the file can be")
    }
    write(p, at)
    at = at + p.length().to_int64()
  }
  at - offset
}

///|
/// `bytes` in memory, all of them; more than `limit` fails.
pub async fn read_bytes(bytes : Pieces, limit : Int) -> Bytes {
  let parts = []
  let mut size = 0
  while (bytes.next)() is Some(p) {
    size += p.length()
    if size > limit {
      raise Failure("more came than was asked for")
    }
    parts.push(p)
  }
  @door.concat(parts)
}

///|
/// `bytes` not wanted after all: their sending stopped, none read.
pub async fn stop_bytes(bytes : Pieces) -> Unit {
  (bytes.stop)()
}
