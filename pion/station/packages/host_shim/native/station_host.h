#ifndef PION_STATION_HOST_H
#define PION_STATION_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Event kinds returned by `sth_wait` in frame byte 0:
// Frame layout: [kind:1][id:8 little-endian][payload...]
#define STH_EV_STDIN_DATA 1u
#define STH_EV_STDIN_EOF  2u
#define STH_EV_SHELL_DONE 3u
#define STH_EV_SYS        4u

// Backpressure bounds (matching station/mb/src/host/host.c).
#define STH_STDIN_MOST    (16u * 1024u * 1024u)
#define STH_SYS_DATA_MOST (2u * 1024u * 1024u)

// Start host runtime: optionally start Rust shell (`shell_dir` non-empty) and/or stdin reader thread.
// Rolls back a newly started shell if stdin thread creation fails. Returns 1 on success, 0 on failure.
int32_t sth_start(const char *shell_dir, int32_t start_stdin);

// Stop owned Rust shell (waiting for in-flight calls, dropping only STH_EV_SHELL_DONE events,
// preserving queued STH_EV_STDIN_DATA / STH_EV_STDIN_EOF / STH_EV_SYS events, and waking any
// blocked `sth_wait(-1)` on an empty queue so it returns NULL).
void sth_stop(void);

// Returns 1 if a shell handle is active, 0 otherwise.
int32_t sth_shell_active(void);

// Dequeue next event, waiting at most `ms` milliseconds (<0 blocks until event or `sth_stop`, 0 polls).
// Returns malloc'd buffer `[kind:1][id:8 le][payload...]` and writes byte length to `*out_len`,
// or returns NULL when no event arrived in time or `sth_stop` woke an empty-queue wait.
// Caller frees with `sth_free`.
void *sth_wait(int64_t ms, int64_t *out_len);

// Push a control system event (unbounded) or bounded data system event (blocks at STH_SYS_DATA_MOST).
void sth_push_sys(uint64_t id, const uint8_t *data, size_t len);
void sth_push_sys_bounded(uint64_t id, const uint8_t *data, size_t len);

// Deterministic synchronization hooks for unit/concurrency tests (zero sleeps; bounded deadline).
void sth_set_stdin_limit_for_test(size_t limit_bytes);
size_t sth_stdin_queued_peak_for_test(void);
int32_t sth_wait_for_stdin_blocked_for_test(int64_t timeout_ms);
int32_t sth_wait_for_queue_waiter_for_test(int64_t timeout_ms);
void sth_push_stdin_chunk(const uint8_t *data, size_t len);
void sth_push_stdin_eof(void);

// Write all `len` bytes to stdout or stderr (handles EINTR and short writes). Returns 1 on success, 0 on error.
int32_t sth_write_stdout(const uint8_t *data, int64_t len);
int32_t sth_write_stderr(const uint8_t *data, int64_t len);

// Async & sync calls into Rust `libstillfail_shell.a`.
void sth_shell_call(
    int64_t id,
    const char *op,
    const uint8_t *json,
    int64_t json_len,
    const uint8_t *bytes,
    int64_t bytes_len,
    int32_t has_bytes);
void *sth_shell_sync(
    const char *op,
    const uint8_t *json,
    int64_t json_len,
    int64_t *out_len);

// Process & runtime utilities.
void *sth_args(int64_t *out_len);
int32_t sth_pid(void);
void sth_exit(int32_t code);
int64_t sth_now_ms(void);
int64_t sth_wall_ms(void);
int64_t sth_rss_bytes(void);
int32_t sth_open_fd_count(void);
int32_t sth_open_thread_count(void);
void *sth_build_info(int64_t *out_len);
void sth_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif // PION_STATION_HOST_H
