#ifndef PION_STATION_SYS_H
#define PION_STATION_SYS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// STH_EV_SYS payload framing (byte 0 = tag)
// Control events are pushed via `sth_push_sys` (never starved by data flood).
// Bulk data events are pushed via `sth_push_sys_bounded` (STH_SYS_DATA_MOST).
//
// Bounded-queue close & shutdown contract:
// - `sts_proc_close`, `sts_pty_close`, and `sts_udp_close` detach I/O teardown and
//   return immediately even when `sth_push_sys_bounded` is saturated (zero deadlock).
// - Each independent reader thread (e.g. Windows proc stdout and stderr each have
//   their own reader) that was already parked inside `sth_push_sys_bounded` may
//   surface at most one in-flight data frame for that closed `event_id` (in addition
//   to frames queued before `close`); callers must ignore frames for closed `event_id`s.
// - Shutdown completion condition: the sole consumer loops draining `sth_wait` until
//   both `sts_active_workers() == 0` and `sth_wait(0) == NULL`.
// - Child processes meant to stop with the station should be terminated via
//   `sts_proc_kill_handle` before `sts_proc_close`; background children intentionally
//   left alive after `close` keep only a silent reaper (no events after `closing == 1`)
//   which is excluded from `sts_active_workers()`.
// ---------------------------------------------------------------------------

// fs.watch events (pushed via sth_push_sys):
//   STS_EV_FS_CHANGE: [1][change_kind:1 (0=error, 1=rename, 2=change, 3=overflow)][name_utf8...]
//   STS_EV_FS_CLOSED: [2]
#define STS_EV_FS_CHANGE 1u
#define STS_EV_FS_CLOSED 2u
#define STS_FS_ERROR     0u
#define STS_FS_RENAME    1u
#define STS_FS_CHANGE    2u
#define STS_FS_OVERFLOW  3u

// Child process events:
//   STS_EV_PROC_STDOUT:     [10][bytes...]                          (bounded)
//   STS_EV_PROC_STDERR:     [11][bytes...]                          (bounded)
//   STS_EV_PROC_STDOUT_EOF: [12]                                    (control)
//   STS_EV_PROC_STDERR_EOF: [13]                                    (control)
//   STS_EV_PROC_EXIT:       [14][code:i32 le][sig:i32 le][sig_name] (control)
#define STS_EV_PROC_STDOUT     10u
#define STS_EV_PROC_STDERR     11u
#define STS_EV_PROC_STDOUT_EOF 12u
#define STS_EV_PROC_STDERR_EOF 13u
#define STS_EV_PROC_EXIT       14u

// Launcher control channel events (pushed via sth_push_sys):
//   STS_EV_CTRL_LINE: [20][line_utf8_without_lf...]
//   STS_EV_CTRL_EOF:  [21]
#define STS_EV_CTRL_LINE 20u
#define STS_EV_CTRL_EOF  21u

// Process signal events (pushed via sth_push_sys):
//   STS_EV_SIGNAL: [30][sig_num:i32 le][sig_name_utf8...]
#define STS_EV_SIGNAL 30u

// PTY / ConPTY events:
//   STS_EV_PTY_DATA: [40][bytes...]                                 (bounded)
//   STS_EV_PTY_EOF:  [41]                                           (control)
//   STS_EV_PTY_EXIT: [42][code:i32 le][sig:i32 le][sig_name]        (control)
#define STS_EV_PTY_DATA 40u
#define STS_EV_PTY_EOF  41u
#define STS_EV_PTY_EXIT 42u

// UDP dgram events:
//   STS_EV_UDP_RECV:   [50][port:u16 le][addr_len:u16 le][addr_utf8][payload...] (bounded)
//   STS_EV_UDP_CLOSED: [51]                                                      (control)
#define STS_EV_UDP_RECV   50u
#define STS_EV_UDP_CLOSED 51u

// Spawn flags for `sts_proc_spawn` and `sts_pty_spawn`.
#define STS_PROC_NEW_PGID        (1u << 0)
#define STS_PROC_STRIP_MALLOC_SE (1u << 1)
#define STS_PROC_PIPE_STDIN      (1u << 2)
#define STS_PROC_PIPE_STDOUT     (1u << 3)
#define STS_PROC_PIPE_STDERR     (1u << 4)
#define STS_PROC_EXPLICIT_ENV    (1u << 5)

// Portable signal numbers for `sts_proc_kill` / `sts_proc_kill_handle` / `sts_pty_kill`.
#define STS_SIG_PROBE 0
#define STS_SIG_HUP   1
#define STS_SIG_INT   2
#define STS_SIG_KILL  9
#define STS_SIG_TERM  15
#define STS_SIG_USR1  101
#define STS_SIG_USR2  102
#define STS_SIG_STOP  103
#define STS_SIG_CONT  104

// Portable cross-platform error codes returned by `sts_udp_send_to` / `sts_udp_send_once`.
#define STS_ERR_NETUNREACH  (-101)
#define STS_ERR_HOSTUNREACH (-113)

// 1. Non-recursive directory or single-file fs.watch (Linux inotify, macOS FSEvents, Windows RDCW).
int64_t sts_fs_watch_open(uint64_t event_id, const char *path);
int32_t sts_fs_watch_close(int64_t handle);

// 2. Async child process manager.
int64_t sts_proc_spawn(
    uint64_t event_id,
    const char *program,
    const uint8_t *args_nul,
    int64_t args_len,
    const uint8_t *env_nul,
    int64_t env_len,
    const char *cwd,
    uint32_t flags,
    int64_t *out_pid,
    char *err_buf,
    int64_t err_cap);
int32_t sts_proc_write_stdin(int64_t handle, const uint8_t *data, int64_t len);
int32_t sts_proc_close_stdin(int64_t handle);
int32_t sts_proc_kill_handle(int64_t handle, int32_t sig, int32_t group);
int32_t sts_proc_close(int64_t handle);
int32_t sts_proc_kill(int32_t pid, int32_t sig, int32_t group);
int64_t sts_proc_start_time_ms(int32_t pid);
int64_t sts_proc_start_ticks(int32_t pid);
void *sts_boot_id(int64_t *out_len);

// 3. Launcher control channel (Unix control fd > 4 e.g. fd 5, Windows named pipe).
// Rejects reserved fds 0..4 (stdio 0..2 and launcher listening fds 3..4).
int64_t sts_ctrl_open_fd(uint64_t event_id, int32_t fd);
int64_t sts_ctrl_open_pipe(uint64_t event_id, const char *pipe_name);
int32_t sts_ctrl_write(int64_t handle, const uint8_t *data, int64_t len);
int32_t sts_ctrl_close(int64_t handle);

// 4. Process signals (SIGTERM, SIGINT, SIGUSR1, SIGUSR2, SIGHUP on Unix; SetConsoleCtrlHandler on Windows).
int32_t sts_signal_watch(uint64_t event_id);
int32_t sts_signal_unwatch(void);

// 5. Advisory exclusive non-blocking file lock (flock / LockFileEx) + unlink helper.
// `sts_flock_try` returns handle > 0 if acquired, 0 if contended, -1 on error.
int64_t sts_flock_try(const char *path);
int32_t sts_flock_unlock(int64_t handle);
int32_t sts_unlink(const char *path);
int32_t sts_rmdir(const char *path);
void *sts_readlink(const char *path, int64_t *out_len);
void *sts_realpath(const char *path, int64_t *out_len);
void *sts_realpath_err(const char *path, int64_t *out_len, int32_t *out_err);
void *sts_lstat(const char *path, int64_t *out_len);
void *sts_lstat_err(const char *path, int64_t *out_len, int32_t *out_err);
void *sts_stat(const char *path, int64_t *out_len);
void *sts_stat_err(const char *path, int64_t *out_len, int32_t *out_err);
int32_t sts_chmod(const char *path, int32_t mode);
int32_t sts_truncate_in_place(const char *path, int64_t size);
void *sts_read_range(const char *path, int64_t offset, int64_t len, int64_t *out_len);
void *sts_read_range_meta(
    const char *path,
    int64_t offset,
    int64_t len,
    int64_t *out_len,
    int64_t *out_total_size,
    int64_t *out_mtime_ms,
    int32_t *out_err);
int32_t sts_write_at(
    const char *path,
    int64_t offset,
    const uint8_t *data,
    int64_t len,
    int32_t create,
    int32_t has_at_least,
    int64_t at_least,
    int32_t has_truncate,
    int64_t truncate_to,
    int32_t do_sync,
    int64_t *out_size,
    int32_t *out_short);
int32_t sts_sync_file(const char *path);
int32_t sts_getuid(void);
int32_t sts_geteuid(void);
int32_t sts_write_file_mode(
    const char *path,
    const uint8_t *data,
    int64_t len,
    int32_t mode,
    int32_t append);
void *sts_read_dir(const char *path, int64_t *out_len);
int32_t sts_mkdir_p(const char *path);
int32_t sts_mkdir_exclusive(const char *path);
// Atomic single-directory creation with explicit POSIX mode (0700 etc.):
// returns 1 on success, -2 on EEXIST, -3 on EACCES/EPERM, -4 on ENOENT, 0 on other error.
int32_t sts_mkdir_mode(const char *path, int32_t mode);
// Create a symbolic link at `link_path` pointing to `target` (`is_dir != 0` sets directory flag on Windows).
int32_t sts_symlink(const char *target, const char *link_path, int32_t is_dir);
// Return 1 if `path` is a Windows directory symlink / junction (reparse point + directory,
// without following the target so dangling directory symlinks return 1), 0 otherwise (always 0 on POSIX).
int32_t sts_is_dir_symlink(const char *path);
// Return current working directory (heap-allocated UTF-8, free via `sts_free`).
void *sts_getcwd(int64_t *out_len);
// Read whole regular file strictly distinguishing ENOENT (*out_err=1) vs EACCES/EPERM (*out_err=2) vs other (*out_err=3).
// Returns heap buffer (free via `sts_free`, *out_err=0) on success, or NULL on error.
void *sts_read_file_strict(const char *path, int64_t *out_len, int32_t *out_err);
// Atomic file write: short unique temp file in same parent dir (`<parent>.sf-tmp.<pid>.<16hex>`)
// + write + fsync/FlushFileBuffers + atomic rename (unlinks tmp on error).
// On POSIX: `mode < 0` opens with 0666 and respects process umask (no fchmod); `mode >= 0` enforces `mode & 0777`.
int32_t sts_write_file_atomic(const char *path, const uint8_t *data, int64_t len, int32_t mode);
int32_t sts_rename(const char *old_path, const char *new_path);
int32_t sts_random_bytes(uint8_t *buf, int64_t len);

// 6. Unix domain socket peer identity (JSON `{"pid":N,"auditToken":...|null}` or NULL).
void *sts_peer_process(int32_t fd, int64_t *out_len);

// 7. Process resource usage (JSON array aligned with `pids`; elements are object or null).
void *sts_process_usage(const int32_t *pids, int32_t count, int64_t *out_len);

// 8. PTY / ConPTY.
int64_t sts_pty_spawn(
    uint64_t event_id,
    const char *program,
    const uint8_t *args_nul,
    int64_t args_len,
    const uint8_t *env_nul,
    int64_t env_len,
    const char *cwd,
    int32_t cols,
    int32_t rows,
    uint32_t flags,
    int64_t *out_pid,
    char *err_buf,
    int64_t err_cap);
int32_t sts_pty_write(int64_t handle, const uint8_t *data, int64_t len);
int32_t sts_pty_resize(int64_t handle, int32_t cols, int32_t rows);
int32_t sts_pty_kill(int64_t handle, int32_t sig);
int32_t sts_pty_close(int64_t handle);

// 9. Minimal UDP dgram (for mesh/lan.ts).
int64_t sts_udp_bind(uint64_t event_id, const char *addr, int32_t port, int64_t *out_port);
int32_t sts_udp_send_to(int64_t handle, const char *addr, int32_t port, const uint8_t *data, int64_t len);
int32_t sts_udp_close(int64_t handle);
int32_t sts_udp_send_once(const char *addr, int32_t port, const uint8_t *data, int64_t len);

// 10. Machine / OS info (RSS, open_fds, open_threads, now_ms, wall_ms, pid live in host_shim).
int32_t sts_os_kind(void);   // 0=darwin, 1=linux, 2=win32, 3=other
int32_t sts_arch_kind(void); // 0=arm64, 1=x64, 2=other
void *sts_hostname(int64_t *out_len);
void *sts_homedir(int64_t *out_len);
void *sts_tmpdir(int64_t *out_len);
void *sts_env_all(int64_t *out_len);
void *sts_env_get(const char *name, int64_t *out_len);
int32_t sts_env_set(const char *name, const char *value);
int32_t sts_env_unset(const char *name);
int32_t sts_is_executable(const char *path);
void *sts_disk_of(const char *path, int64_t *out_len);
void *sts_machine_stats(int64_t *out_len);
void *sts_psi_pressure(int64_t *out_len);
void *sts_network_interfaces(int64_t *out_len);

// Active I/O event-publisher worker count (excludes silent child reapers; 0 when all I/O workers have exited).
int32_t sts_active_workers(void);

// Deterministic test helpers:
// - `sts_wait_detached_for_test`: wait until both I/O workers and child reapers have exited (1=done, 0=timeout).
// - `sts_bounded_push_inflight_for_test`: count of reader threads currently inside `sth_push_sys_bounded`.
int32_t sts_wait_detached_for_test(int64_t timeout_ms);
int32_t sts_bounded_push_inflight_for_test(void);

// FD-level TOCTOU-safe read/write under `root` (`openat` with `O_NOFOLLOW | O_DIRECTORY` on POSIX,
// `FILE_FLAG_OPEN_REPARSE_POINT` on Windows): rejects symlinks, non-regular files, and `..` traversal.
void *sts_read_under_nofollow(
    const char *root,
    const char *rel,
    int64_t offset,
    int64_t len,
    int64_t *out_len,
    int64_t *out_size);
int32_t sts_write_under_nofollow(
    const char *root,
    const char *rel,
    const uint8_t *data,
    int64_t len,
    int64_t offset,
    int32_t mode,
    int32_t truncate_end);

// Pure C11 V8 String.prototype.toLowerCase() (1:1 aligned with `jscase::lower`).
// Returns 1 on success (exact byte length written to `*out_len`), 0 on invalid args / small cap / OOM.
int32_t sts_js_lower_utf8(
    const uint8_t *in,
    size_t in_len,
    uint8_t *out,
    size_t out_cap,
    size_t *out_len);

// Idempotently register deterministic SQLite scalar function `js_lower(x)` via `sqlite3_auto_extension`.
// Implemented in `station_sqlite_ext.c`; returns 0 (SQLITE_OK) on success, non-zero SQLite rc on error.
int32_t sts_register_sqlite_js_lower(void);

// Free any buffer returned by `sts_*`.
void sts_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif // PION_STATION_SYS_H
