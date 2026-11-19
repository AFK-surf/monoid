// The system's calls the drive makes (drive.c), each failing as node:fs fails: its code as Node names it, and words as
// libuv's with the call and the path, as Node's message says them.

///|
#borrow(path, out)
extern "C" fn stat_ffi(path : Bytes, follow : Int, out : FixedArray[Double]) -> Int = "sfd_stat"

///|
#borrow(path, err)
extern "C" fn readdir_ffi(path : Bytes, err : FixedArray[Int]) -> Bytes = "sfd_readdir"

///|
#borrow(path, err)
extern "C" fn realpath_ffi(path : Bytes, err : FixedArray[Int]) -> Bytes = "sfd_realpath"

///|
#borrow(path, out, err)
extern "C" fn read_ffi(
  path : Bytes,
  offset : Double,
  length : Double,
  out : FixedArray[Double],
  err : FixedArray[Int],
) -> Bytes = "sfd_read"

///|
#borrow(path, data, out)
extern "C" fn write_ffi(
  path : Bytes,
  create : Int,
  offset : Double,
  data : Bytes,
  at_least : Double,
  truncate_to : Double,
  sync : Int,
  out : FixedArray[Double],
) -> Int = "sfd_write"

///|
#borrow(from, to)
extern "C" fn rename_ffi(from : Bytes, to : Bytes) -> Int = "sfd_rename"

///|
#borrow(path)
extern "C" fn mkdir_ffi(path : Bytes, recursive : Int, mode : Int) -> Int = "sfd_mkdir"

///|
#borrow(path)
extern "C" fn rm_ffi(path : Bytes) -> Int = "sfd_rm"

///|
#borrow(path)
extern "C" fn unlink_ffi(path : Bytes) -> Int = "sfd_unlink"

///|
#borrow(from, to)
extern "C" fn copy_ffi(from : Bytes, to : Bytes) -> Int = "sfd_copy"

///|
#borrow(path)
extern "C" fn opendir_ffi(path : Bytes) -> Int = "sfd_opendir"

///|
#borrow(path, data)
extern "C" fn create_excl_ffi(path : Bytes, data : Bytes) -> Int = "sfd_create_excl"

///|
#borrow(path, tmp, data)
extern "C" fn write_private_ffi(path : Bytes, tmp : Bytes, data : Bytes) -> Int = "sfd_write_private"

///|
#borrow(out)
extern "C" fn local_ffi(ms : Double, out : FixedArray[Int]) -> Unit = "sfd_local"

///|
extern "C" fn local_ms_ffi(year : Int, month : Int, day : Int) -> Double = "sfd_local_ms"

///|
extern "C" fn uid_ffi() -> Int = "sfd_uid"

///|
/// What a call of the file system's (or still.fail Helper's) failed with: Node's code (`ENOENT`…, or the helper's
/// `outside`, `protected`, `grant`), its words, and for `grant` the grant that opens the folder and the folder.
pub(all) struct FsFailure {
  code : String
  message : String
  grant : String?
  top : String?
} derive(Show)

///|
pub(all) suberror FsError {
  FsError(FsFailure)
}

///|
pub impl Show for FsError with output(self, logger) {
  let FsError(f) = self
  logger.write_string(f.message)
}

///|
/// A failure with `code` and `message`.
pub fn fs_error(code : String, message : String) -> FsError {
  FsError({ code, message, grant: None, top: None })
}

///|
/// drive.c's code: Node's name and libuv's words.
fn code_of(n : Int) -> (String, String) {
  match n {
    1 => ("ENOENT", "no such file or directory")
    2 => ("EACCES", "permission denied")
    3 => ("EPERM", "operation not permitted")
    4 => ("EEXIST", "file already exists")
    5 => ("ENOTEMPTY", "directory not empty")
    6 => ("EISDIR", "illegal operation on a directory")
    7 => ("ENOTDIR", "not a directory")
    8 => ("ENOSPC", "no space left on device")
    9 => ("EXDEV", "cross-device link not permitted")
    10 => ("EROFS", "read-only file system")
    11 => ("ELOOP", "too many symbolic links encountered")
    12 => ("EINVAL", "invalid argument")
    13 => ("EBUSY", "resource busy or locked")
    14 => ("ENAMETOOLONG", "name too long")
    15 => ("EMFILE", "too many open files")
    16 => ("ENOSYS", "function not implemented")
    _ => ("EIO", "i/o error")
  }
}

///|
/// Node's error for drive.c's `n`: `ENOENT: no such file or directory, open '/x'`.
fn sys_failed(n : Int, call : String, path : String, to? : String) -> FsError {
  let (code, words) = code_of(n)
  let paths = match to {
    Some(t) => "'\{path}' -> '\{t}'"
    None => "'\{path}'"
  }
  fs_error(code, "\{code}: \{words}, \{call} \{paths}")
}

///|
/// A C string: `s` in UTF-8, ended by a NUL.
fn c_str(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let out = FixedArray::make(b.length() + 1, b'\x00')
  for i = 0; i < b.length(); i = i + 1 {
    out[i] = b[i]
  }
  Bytes::from_array(out)
}

///|
/// A file's or folder's stat: what it is, its size (0 for a folder, as fs.ts `statOf`), its time (ms), its device.
pub(all) struct Stat {
  dir : Bool
  file : Bool
  link : Bool
  size : Double
  mtime_ms : Double
  dev : Double
} derive(Show, Eq)

///|
fn sys_stat(path : String, follow : Bool) -> Stat raise FsError {
  let out = FixedArray::make(4, 0.0)
  let n = stat_ffi(c_str(path), if follow { 1 } else { 0 }, out)
  if n != 0 {
    raise sys_failed(n, if follow { "stat" } else { "lstat" }, path)
  }
  let kind = out[0].to_int()
  {
    dir: kind == 2,
    file: kind == 1,
    link: kind == 3,
    size: if kind == 2 { 0.0 } else { out[1] },
    mtime_ms: out[2],
    dev: out[3],
  }
}

///|
/// `stat` (links followed).
pub fn stat(path : String) -> Stat raise FsError {
  sys_stat(path, true)
}

///|
/// `lstat` (a link itself).
pub fn lstat(path : String) -> Stat raise FsError {
  sys_stat(path, false)
}

///|
/// A folder's entry as readdir's `withFileTypes` gives it: its name and kind, links not followed.
pub(all) struct Dirent {
  name : String
  is_dir : Bool
  is_link : Bool
} derive(Show)

///|
/// readdir with its kinds, in libuv's order (by the names' bytes).
pub fn readdir(path : String) -> Array[Dirent] raise FsError {
  let err = FixedArray::make(1, 0)
  let bytes = readdir_ffi(c_str(path), err)
  if err[0] != 0 {
    raise sys_failed(err[0], "scandir", path)
  }
  let out = []
  let mut start = 0
  for i = 0; i < bytes.length(); i = i + 1 {
    if bytes[i] == b'\x00' {
      let kind = bytes[start]
      let name = @utf8.decode_lossy(bytes[start + 1:i])
      out.push({ name, is_dir: kind == b'd', is_link: kind == b'l' })
      start = i + 1
    }
  }
  out
}

///|
/// readdir's names.
pub fn names(path : String) -> Array[String] raise FsError {
  readdir(path).map(d => d.name)
}

///|
/// fs.promises.realpath.
pub fn realpath(path : String) -> String raise FsError {
  let err = FixedArray::make(1, 0)
  let bytes = realpath_ffi(c_str(path), err)
  if err[0] != 0 {
    raise sys_failed(err[0], "realpath", path)
  }
  @utf8.decode_lossy(bytes)
}

///|
/// Up to `length` bytes of a file from `offset`, its size and time; EISDIR for a folder.
pub fn read_part(
  path : String,
  offset : Double,
  length : Double,
) -> (Bytes, Double, Double) raise FsError {
  let out = FixedArray::make(2, 0.0)
  let err = FixedArray::make(1, 0)
  let bytes = read_ffi(c_str(path), offset, length, out, err)
  if err[0] != 0 {
    if err[0] == 6 {
      raise fs_error("EISDIR", "that is a folder")
    }
    raise sys_failed(err[0], "open", path)
  }
  (bytes, out[0], out[1])
}

///|
/// A file's bytes whole.
pub fn read_all(path : String) -> Bytes raise FsError {
  let (_, size, _) = read_part(path, 0.0, 0.0)
  let (bytes, _, _) = read_part(path, 0.0, size)
  bytes
}

///|
/// fs.ts `Write`: what to write and how.
pub(all) struct Write {
  create : Bool
  offset : Double
  data : Bytes
  at_least : Double?
  truncate : Double?
  sync : Bool
}

///|
/// fs.ts `Written`: the file's size after (`short`: nothing written, it was smaller than `at_least`).
pub(all) struct Written {
  size : Double
  short : Bool
} derive(Show)

///|
pub fn write_part(path : String, w : Write) -> Written raise FsError {
  let out = FixedArray::make(2, 0.0)
  let n = write_ffi(
    c_str(path),
    if w.create { 1 } else { 0 },
    w.offset,
    w.data,
    w.at_least.unwrap_or(-1.0),
    w.truncate.unwrap_or(-1.0),
    if w.sync { 1 } else { 0 },
    out,
  )
  if n != 0 {
    raise sys_failed(n, "open", path)
  }
  { size: out[0], short: out[1] == 1.0 }
}

///|
pub fn rename(from : String, to : String) -> Unit raise FsError {
  let n = rename_ffi(c_str(from), c_str(to))
  if n != 0 {
    raise sys_failed(n, "rename", from, to~)
  }
}

///|
/// mkdir (`recursive` as Node's), with `mode`.
pub fn mkdir(path : String, recursive : Bool, mode? : Int = 0o777) -> Unit raise FsError {
  let n = mkdir_ffi(c_str(path), if recursive { 1 } else { 0 }, mode)
  if n != 0 {
    raise sys_failed(n, "mkdir", path)
  }
}

///|
/// rm with `recursive` (no `force`).
pub fn rm(path : String) -> Unit raise FsError {
  let n = rm_ffi(c_str(path))
  if n != 0 {
    raise sys_failed(n, "rm", path)
  }
}

///|
/// rm with `recursive` and `force`: nothing there is no failure, any other failure let go.
pub fn rm_force(path : String) -> Unit {
  rm_ffi(c_str(path)) |> ignore
}

///|
pub fn unlink(path : String) -> Unit raise FsError {
  let n = unlink_ffi(c_str(path))
  if n != 0 {
    raise sys_failed(n, "unlink", path)
  }
}

///|
/// copyFile with COPYFILE_EXCL | COPYFILE_FICLONE.
pub fn copy_file(from : String, to : String) -> Unit raise FsError {
  let n = copy_ffi(c_str(from), c_str(to))
  if n != 0 {
    raise sys_failed(n, "copyfile", from, to~)
  }
}

///|
/// ops/files.ts `unreadableDirAsync`: there, but the station may not list it (EPERM, EACCES).
pub fn unreadable_dir(dir : String) -> Bool {
  let n = opendir_ffi(c_str(dir))
  n == 2 || n == 3
}

///|
/// A file made only where none is (O_EXCL, 0600), `text` in it.
fn create_excl(path : String, text : String) -> Unit raise FsError {
  let n = create_excl_ffi(c_str(path), @utf8.encode(text))
  if n != 0 {
    raise sys_failed(n, "open", path)
  }
}

///|
/// How many names beside a file `tmp_beside` gave in this process.
let tmp_seq : Ref[Int64] = { val: 0L }

///|
/// A name beside `path` no other private write of this process takes (`<path>.<pid>.<n>.tmp`, L13).
fn tmp_beside(path : String) -> String {
  tmp_seq.val += 1L
  "\{path}.\{pid()}.\{tmp_seq.val}.tmp"
}

///|
/// ops/files.ts `writePrivateSoon`: written beside (`tmp_beside`, 0600), synced, put in place; what was written beside
/// let go of where that failed.
pub fn write_private(path : String, text : String) -> Unit raise FsError {
  write_private_bytes(path, @utf8.encode(text))
}

///|
/// A time's fields in the machine's local time: year, month (0-11), day, hours, minutes, seconds.
pub fn local_time(ms : Double) -> (Int, Int, Int, Int, Int, Int) {
  let out = FixedArray::make(6, 0)
  local_ffi(ms, out)
  (out[0], out[1], out[2], out[3], out[4], out[5])
}

///|
/// `new Date(year, month, day).getTime()`.
pub fn local_midnight(year : Int, month : Int, day : Int) -> Double {
  local_ms_ffi(year, month, day)
}

///|
/// process.getuid().
pub fn uid() -> Int {
  uid_ffi()
}

///|
#borrow(name, found)
extern "C" fn getenv_ffi(name : Bytes, found : FixedArray[Int]) -> Bytes = "sfd_getenv"

///|
/// process.env[name].
pub fn env(name : String) -> String? {
  let found = FixedArray::make(1, 0)
  let v = getenv_ffi(c_str(name), found)
  if found[0] == 1 {
    Some(@utf8.decode_lossy(v))
  } else {
    None
  }
}

///|
extern "C" fn platform_ffi() -> Int = "sfd_platform"

///|
/// Whether the program runs on macOS.
pub fn is_mac() -> Bool {
  platform_ffi() == 1
}

///|
/// Whether the program runs on Windows.
pub fn is_windows() -> Bool {
  platform_ffi() == 2
}

///|
/// `f`'s value, or what it failed with.
pub fn[T] attempt(f : () -> T raise) -> Result[T, Error] {
  try Ok(f()) catch {
    e => Err(e)
  }
}

///|
extern "C" fn random_ffi(n : Int) -> Bytes = "sfd_random"

///|
/// `n` random bytes.
pub fn random_bytes(n : Int) -> Bytes {
  random_ffi(n)
}

///|
/// Bytes as lowercase hex.
pub fn hex(b : BytesView) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder::new()
  for i = 0; i < b.length(); i = i + 1 {
    let v = b[i].to_int()
    out.write_char(digits.get_char(v >> 4).unwrap())
    out.write_char(digits.get_char(v & 15).unwrap())
  }
  out.to_string()
}

///|
/// crypto.randomUUID(): a version 4 UUID.
pub fn random_uuid() -> String {
  let b = random_bytes(16).to_fixedarray()
  b[6] = ((b[6].to_int() & 0x0F) | 0x40).to_byte()
  b[8] = ((b[8].to_int() & 0x3F) | 0x80).to_byte()
  let h = hex(Bytes::from_array(b))
  "\{h.unsafe_substring(start=0, end=8)}-\{h.unsafe_substring(start=8, end=12)}-\{h.unsafe_substring(start=12, end=16)}-\{h.unsafe_substring(start=16, end=20)}-\{h.unsafe_substring(start=20, end=32)}"
}

///|
/// `write_private` of bytes.
pub fn write_private_bytes(path : String, data : Bytes) -> Unit raise FsError {
  let tmp = tmp_beside(path)
  let n = write_private_ffi(c_str(path), c_str(tmp), data)
  if n != 0 {
    rm_force(tmp)
    raise sys_failed(n, "open", path)
  }
}

///|
extern "C" fn pid_ffi() -> Int = "sfd_pid"

///|
extern "C" fn now_ms_ffi() -> Double = "sfd_now_ms"

///|
/// process.pid.
pub fn pid() -> Int {
  pid_ffi()
}

///|
/// Date.now().
pub fn wall_clock() -> Double {
  now_ms_ffi()
}
