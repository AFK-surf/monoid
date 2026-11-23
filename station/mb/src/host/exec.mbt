// Cross-platform process replacement (execv on Unix, CreateProcessW on Windows) and OS lookups for shims.

///|
#borrow(name)
extern "C" fn env_get_ffi(name : Bytes) -> Bytes = "sfh_env_get"

///|
extern "C" fn exe_path_ffi() -> Bytes = "sfh_exe_path"

///|
#borrow(path)
extern "C" fn is_file_ffi(path : Bytes) -> Int = "sfh_is_file"

///|
#borrow(path)
extern "C" fn is_executable_file_ffi(path : Bytes) -> Int = "sfh_is_executable_file"

///|
#borrow(name)
extern "C" fn find_in_path_ffi(name : Bytes) -> Bytes = "sfh_find_in_path"

///|
#borrow(program, argv_nul)
extern "C" fn exec_replace_ffi(program : Bytes, argv_nul : Bytes) -> Int = "sfh_exec_replace"

///|
/// Returns the environment variable value if set and non-empty.
pub fn env_get(name : String) -> String? {
  let b = env_get_ffi(cstr(name))
  if b.length() == 0 {
    None
  } else {
    Some(@utf8.decode_lossy(b))
  }
}

///|
/// Returns the canonical path of the current executable, if available.
pub fn exe_path() -> String? {
  let b = exe_path_ffi()
  if b.length() == 0 {
    None
  } else {
    Some(@utf8.decode_lossy(b))
  }
}

///|
/// Returns true if `path` exists and is a regular file (following symlinks).
pub fn is_file(path : String) -> Bool {
  is_file_ffi(cstr(path)) != 0
}

///|
/// Returns true if `path` exists, is a regular file, and is executable.
pub fn is_executable_file(path : String) -> Bool {
  is_executable_file_ffi(cstr(path)) != 0
}

///|
/// Finds an executable named `name` on PATH.
pub fn find_in_path(name : String) -> String? {
  let b = find_in_path_ffi(cstr(name))
  if b.length() == 0 {
    None
  } else {
    Some(@utf8.decode_lossy(b))
  }
}

///|
/// Replaces the current process with `program` and `argv` (including argv[0]) on Unix via execv,
/// or runs it as an inherited-handle child process on Windows and returns its exit code.
pub fn exec_replace(program : String, argv : Array[String]) -> Int {
  let mut total = 0
  let encoded : Array[Bytes] = []
  for a in argv {
    let b = @utf8.encode(a)
    encoded.push(b)
    total += b.length() + 1
  }
  let buf = FixedArray::make(total, b'\x00')
  let mut off = 0
  for b in encoded {
    for i = 0; i < b.length(); i = i + 1 {
      buf[off + i] = b[i]
    }
    off += b.length() + 1
  }
  exec_replace_ffi(cstr(program), Bytes::from_array(buf))
}
