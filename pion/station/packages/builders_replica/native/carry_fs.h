#ifndef PION_STATION_CARRY_FS_H
#define PION_STATION_CARRY_FS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 1:1 cross-platform C11 filesystem shim matching `station/mb/src/replica/carry.c`
// with Pion borrowed `ptr + int64_t byte_len` and NUL-terminated UTF-8 paths.

// Open `path` for writing (created if absent; appended when `append != 0`, else truncated).
// Returns fd (>= 0) or -1 on error.
int32_t sfc_open(const char *path, int32_t append);

// Write all `byte_len` bytes of `data` to `fd` (handling short writes and EINTR).
// Returns 0 on success, -1 on error.
int32_t sfc_write(int32_t fd, const uint8_t *data, int64_t byte_len);

// Close `fd`. Returns 0 on success, -1 on error.
int32_t sfc_close(int32_t fd);

// Set access & modification times of `path` to `secs` (seconds since Unix epoch, nanosecond precision
// on POSIX / 100ns FILETIME on Windows, matching Node utimesSync / libuv). Returns 0 or -1.
int32_t sfc_utimes(const char *path, double secs);

// Return hard-link count (lstat st_nlink / BY_HANDLE_FILE_INFORMATION.nNumberOfLinks), or -1 on error.
int32_t sfc_nlink(const char *path);

// Create hard link `to` of `from`:
//   0 = linked
//   1 = filesystem/OS does not allow hard link here (EXDEV/EPERM/ENOTSUP/EMLINK/ENOSYS/EOPNOTSUPP;
//       Windows ERROR_NOT_SAME_DEVICE/ERROR_ACCESS_DENIED/ERROR_NOT_SUPPORTED/ERROR_TOO_MANY_LINKS/ERROR_INVALID_FUNCTION)
//   2 = any other failure (e.g. `to` already exists, `from` missing)
int32_t sfc_link(const char *from, const char *to);

// Return 1 if opening `path` (`dir != 0` for directory) for reading is refused (EACCES/EPERM;
// Windows ERROR_ACCESS_DENIED), else 0.
int32_t sfc_denied(const char *path, int32_t dir);

// Return 1 if `path` is confirmed absent (ENOENT/ENOTDIR; Windows FILE_NOT_FOUND/PATH_NOT_FOUND/INVALID_NAME),
// else 0 (exists or unreadable). `follow != 0` follows symlinks (stat vs lstat).
int32_t sfc_missing(const char *path, int32_t follow);

// Return 1 if `path` is confirmed absent or not a directory when opened for listing, else 0.
int32_t sfc_dir_missing(const char *path);

// Return 1 if directory `path` is readable OR confirmed missing/not-a-dir; 0 if unreadable (EACCES/EIO/other).
int32_t sfc_dir_readable(const char *path);

// Return 1 if `path` is a regular file (links followed), 0 if not, -1 if unknown here (Windows MAX_PATH fallback).
int32_t sfc_is_file(const char *path);

// Racy-git style metadata stamp for a readable regular file `path`, writing NUL-terminated ASCII stamp into `out_buf`:
//   0  = confirmed missing (ENOENT / ENOTDIR; Windows FILE_NOT_FOUND / PATH_NOT_FOUND / INVALID_NAME)
//   -1 = error, unreadable, non-regular, buffer too small, or Windows MAX_PATH (do not use cache)
//   1  = clean (non-racy: >= 50ms since ctime / ChangeTime)
//   2  = racy (< 50ms since ctime / ChangeTime or clock skew; caller must verify via `sfc_file_fnv64`)
int32_t sfc_file_stamp(const char *path, uint8_t *out_buf, int32_t cap);

// Streaming 64-bit FNV-1a hash of raw bytes of `path` using a 64 KiB stack buffer, writing little-endian uint64_t
// to `out_hash` (unaligned-safe via memcpy). Returns 0 on success, -1 on error.
int32_t sfc_file_fnv64(const char *path, uint64_t *out_hash);

#ifdef __cplusplus
}
#endif

#endif // PION_STATION_CARRY_FS_H
