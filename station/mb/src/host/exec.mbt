// Cross-platform process replacement (execv on Unix, CreateProcessW + Job Object on Windows) and OS lookups for shims.

///|
extern "C" fn is_windows_ffi() -> Int = "sfh_is_windows"

///|
#borrow(name)
extern "C" fn env_get_ffi(name : Bytes) -> Bytes = "sfh_env_get"

///|
#borrow(name, val)
extern "C" fn env_set_ffi(name : Bytes, val : Bytes) -> Int = "sfh_env_set"

///|
#borrow(name)
extern "C" fn env_unset_ffi(name : Bytes) -> Int = "sfh_env_unset"

///|
extern "C" fn getcwd_ffi() -> Bytes = "sfh_getcwd"

///|
extern "C" fn exe_path_ffi() -> Bytes = "sfh_exe_path"

///|
#borrow(path)
extern "C" fn is_file_ffi(path : Bytes) -> Int = "sfh_is_file"

///|
#borrow(path)
extern "C" fn is_executable_file_ffi(path : Bytes) -> Int = "sfh_is_executable_file"

///|
#borrow(a, b)
extern "C" fn same_file_ffi(a : Bytes, b : Bytes) -> Int = "sfh_same_file"

///|
#borrow(name)
extern "C" fn find_in_path_ffi(name : Bytes) -> Bytes = "sfh_find_in_path"

///|
#borrow(program, argv_nul)
extern "C" fn exec_replace_ffi(program : Bytes, argv_nul : Bytes) -> Int = "sfh_exec_replace"

///|
/// Compile-time host OS check: true on Windows, false on Unix.
pub fn is_windows() -> Bool {
  is_windows_ffi() != 0
}

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
/// Sets environment variable `name` to `val`.
pub fn env_set(name : String, val : String) -> Bool {
  env_set_ffi(cstr(name), cstr(val)) != 0
}

///|
/// Unsets environment variable `name`.
pub fn env_unset(name : String) -> Bool {
  env_unset_ffi(cstr(name)) != 0
}

///|
/// Returns the current working directory, if available.
pub fn getcwd() -> String? {
  let b = getcwd_ffi()
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
/// Returns true if `a` and `b` refer to the same underlying file (dev/ino on Unix, volume+file index on Windows).
pub fn same_file(a : String, b : String) -> Bool {
  same_file_ffi(cstr(a), cstr(b)) != 0
}

///|
/// Finds an executable named `name` on PATH (explicit PATH directories only).
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
/// or runs it as an inherited-handle child process in a KILL_ON_JOB_CLOSE | SILENT_BREAKAWAY_OK
/// Job Object on Windows and returns its exit code.
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
