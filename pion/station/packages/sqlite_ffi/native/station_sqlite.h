#ifndef PION_STATION_SQLITE_H
#define PION_STATION_SQLITE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Direct C11 bridge over the `sqlite3_*` symbols exported by `libstillfail_shell.a`
// (bundled rusqlite), avoiding JSON serialization on hot SQLite paths.
// Handles are generation-checked indices into private C tables (never raw pointers)
// so double-close, double-finalize, and post-close calls fail safely without UAF.

int64_t stq_open(const char *path, int32_t flags, int32_t busy_timeout_ms);
int32_t stq_close(int64_t db);
void *stq_errmsg(int64_t db, int64_t *out_len);
void *stq_errstr(int32_t rc, int64_t *out_len);
int32_t stq_exec(int64_t db, const char *sql);
int32_t stq_changes(int64_t db);
int32_t stq_autocommit(int64_t db);
int32_t stq_wal_checkpoint(int64_t db, int32_t mode, int32_t *out_log, int32_t *out_ckpt);
int32_t stq_wal_checkpoint_hard(
    int64_t db,
    int32_t mode,
    int32_t temp_busy_ms,
    int32_t *out_log,
    int32_t *out_ckpt);

int64_t stq_prepare(int64_t db, const char *sql, int32_t sql_len, int32_t *out_rc);
int32_t stq_finalize(int64_t stmt);
int32_t stq_reset(int64_t stmt);
int32_t stq_clear_bindings(int64_t stmt);
int32_t stq_step(int64_t stmt);

int32_t stq_bind_null(int64_t stmt, int32_t index);
int32_t stq_bind_int64(int64_t stmt, int32_t index, int64_t value);
int32_t stq_bind_double(int64_t stmt, int32_t index, double value);
int32_t stq_bind_text(int64_t stmt, int32_t index, const uint8_t *data, int32_t len);
int32_t stq_bind_blob(int64_t stmt, int32_t index, const uint8_t *data, int32_t len);

int32_t stq_column_count(int64_t stmt);
void *stq_column_name(int64_t stmt, int32_t index, int64_t *out_len);
int32_t stq_column_type(int64_t stmt, int32_t index);
int64_t stq_column_int64(int64_t stmt, int32_t index);
double stq_column_double(int64_t stmt, int32_t index);
void *stq_column_text(int64_t stmt, int32_t index, int64_t *out_len);
void *stq_column_blob(int64_t stmt, int32_t index, int64_t *out_len);

void stq_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif // PION_STATION_SQLITE_H
