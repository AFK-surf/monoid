#ifndef PION_STATION_FOOTPRINT_FS_H
#define PION_STATION_FOOTPRINT_FS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Error codes matching station/mb/src/footprint/footprint.c and Node/libuv errno mapping.
#define SFP_OK           0
#define SFP_ENOENT       1
#define SFP_EACCES       2
#define SFP_EPERM        3
#define SFP_ENOTDIR      4
#define SFP_ELOOP        5
#define SFP_ENAMETOOLONG 6
#define SFP_EIO          7

// Entry kinds stored in out5[0] by sfp_lstat.
#define SFP_OTHER 0
#define SFP_FILE  1
#define SFP_DIR   2
#define SFP_LINK  3

// lstat(path) without following symlinks.
// Writes [kind, dev, ino, nlink, blocks] into out5 (5 int64_t elements).
// Returns SFP_OK (0) or an SFP_* error code (1..7).
int32_t sfp_lstat(const char *path, int64_t *out5);

// Read directory entry names (excluding "." and "..") as NUL-terminated UTF-8 strings
// packed consecutively into a single malloc'd buffer.
// On POSIX, entries are sorted byte-lexicographically (strcmp), matching libuv scandir.
// Writes total byte length to *out_len and error code (SFP_OK or 1..7) to *out_err.
// Returns NULL if the directory is empty or on error. Caller frees non-NULL pointer with sfp_free.
void *sfp_readdir(const char *path, int64_t *out_len, int32_t *out_err);

// Returns 1 if path exists (following symlinks, like Node fs.existsSync), else 0.
int32_t sfp_exists(const char *path);

// Returns 1 if path is a directory (following symlinks, like stat().isDirectory()), else 0.
int32_t sfp_is_dir(const char *path);

// Read up to `most` bytes (clamped to [0, 4096]) from a regular file at `path`.
// On POSIX: opens with O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC and checks fstat S_ISREG,
// refusing FIFOs (even with no writer) and device files immediately without blocking.
// On Windows: checks GetFileType == FILE_TYPE_DISK and excludes directories.
// Sets *out_err = 0 on success (with *out_len = bytes read) or 1 on error/non-regular file.
// Returns malloc'd buffer when *out_len > 0 (caller frees with sfp_free), else NULL.
void *sfp_head(const char *path, int32_t most, int64_t *out_len, int32_t *out_err);

// Monotonic clock in milliseconds (CLOCK_MONOTONIC on POSIX, GetTickCount64 on Windows).
int64_t sfp_now_ms(void);

// Returns 1 on Windows (_WIN32), 0 otherwise.
int32_t sfp_is_windows(void);

// Free a buffer returned by sfp_readdir or sfp_head.
void sfp_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif // PION_STATION_FOOTPRINT_FS_H
