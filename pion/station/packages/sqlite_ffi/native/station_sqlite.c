// Direct C11 FFI bridge to the `sqlite3_*` symbols exported by `libstillfail_shell.a`
// (matching station/mb/src/sql/sql.c without JSON serialization overhead).

#include "station_sqlite.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

extern int sqlite3_open_v2(const char *filename, sqlite3 **db, int flags, const char *vfs);
extern int sqlite3_close_v2(sqlite3 *db);
extern int sqlite3_busy_timeout(sqlite3 *db, int ms);
extern int sqlite3_exec(sqlite3 *db, const char *sql, void *callback, void *arg, char **errmsg);
extern const char *sqlite3_errmsg(sqlite3 *db);
extern const char *sqlite3_errstr(int rc);
extern int sqlite3_changes(sqlite3 *db);
extern int sqlite3_get_autocommit(sqlite3 *db);
extern int sqlite3_wal_checkpoint_v2(sqlite3 *db, const char *zDb, int eMode, int *pnLog, int *pnCkpt);
extern int sqlite3_prepare_v2(sqlite3 *db, const char *sql, int bytes, sqlite3_stmt **stmt, const char **tail);
extern int sqlite3_finalize(sqlite3_stmt *stmt);
extern int sqlite3_reset(sqlite3_stmt *stmt);
extern int sqlite3_clear_bindings(sqlite3_stmt *stmt);
extern int sqlite3_step(sqlite3_stmt *stmt);
extern int sqlite3_bind_null(sqlite3_stmt *stmt, int i);
extern int sqlite3_bind_int64(sqlite3_stmt *stmt, int i, int64_t v);
extern int sqlite3_bind_double(sqlite3_stmt *stmt, int i, double v);
extern int sqlite3_bind_text(sqlite3_stmt *stmt, int i, const char *v, int n, void (*destructor)(void *));
extern int sqlite3_bind_blob(sqlite3_stmt *stmt, int i, const void *v, int n, void (*destructor)(void *));
extern int sqlite3_column_count(sqlite3_stmt *stmt);
extern const char *sqlite3_column_name(sqlite3_stmt *stmt, int i);
extern int sqlite3_column_type(sqlite3_stmt *stmt, int i);
extern int64_t sqlite3_column_int64(sqlite3_stmt *stmt, int i);
extern double sqlite3_column_double(sqlite3_stmt *stmt, int i);
extern const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int i);
extern const void *sqlite3_column_blob(sqlite3_stmt *stmt, int i);
extern int sqlite3_column_bytes(sqlite3_stmt *stmt, int i);

#define STQ_SQLITE_TRANSIENT ((void (*)(void *))-1)
#define STQ_DB(h) ((sqlite3 *)(intptr_t)(h))
#define STQ_STMT(h) ((sqlite3_stmt *)(intptr_t)(h))

static void *copy_bytes(const void *src, int n, int64_t *out_len) {
    if (n <= 0 || src == NULL) {
        if (out_len != NULL) {
            *out_len = 0;
        }
        return NULL;
    }
    void *out = malloc((size_t)n);
    if (out == NULL) {
        abort();
    }
    memcpy(out, src, (size_t)n);
    if (out_len != NULL) {
        *out_len = (int64_t)n;
    }
    return out;
}

static void *copy_cstr(const char *s, int64_t *out_len) {
    if (s == NULL) {
        return copy_bytes(NULL, 0, out_len);
    }
    return copy_bytes(s, (int)strlen(s), out_len);
}

int64_t stq_open(const char *path, int32_t flags, int32_t busy_timeout_ms) {
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(path != NULL ? path : "", &db, (int)flags, NULL);
    if (rc != 0) {
        if (db != NULL) {
            sqlite3_close_v2(db);
        }
        return -(int64_t)rc;
    }
    if (busy_timeout_ms > 0) {
        sqlite3_busy_timeout(db, (int)busy_timeout_ms);
    }
    return (int64_t)(intptr_t)db;
}

int32_t stq_close(int64_t db) {
    if (db == 0) {
        return 0;
    }
    return (int32_t)sqlite3_close_v2(STQ_DB(db));
}

void *stq_errmsg(int64_t db, int64_t *out_len) {
    if (db == 0) {
        return copy_cstr("null db handle", out_len);
    }
    return copy_cstr(sqlite3_errmsg(STQ_DB(db)), out_len);
}

void *stq_errstr(int32_t rc, int64_t *out_len) {
    return copy_cstr(sqlite3_errstr((int)rc), out_len);
}

int32_t stq_exec(int64_t db, const char *sql) {
    if (db == 0 || sql == NULL) {
        return 21; // SQLITE_MISUSE
    }
    return (int32_t)sqlite3_exec(STQ_DB(db), sql, NULL, NULL, NULL);
}

int32_t stq_changes(int64_t db) {
    if (db == 0) {
        return 0;
    }
    return (int32_t)sqlite3_changes(STQ_DB(db));
}

int32_t stq_autocommit(int64_t db) {
    if (db == 0) {
        return 1;
    }
    return (int32_t)sqlite3_get_autocommit(STQ_DB(db));
}

int32_t stq_wal_checkpoint(int64_t db, int32_t mode, int32_t *out_log, int32_t *out_ckpt) {
    if (db == 0) {
        return 21;
    }
    int log_frames = 0;
    int ckpt_frames = 0;
    int rc = sqlite3_wal_checkpoint_v2(STQ_DB(db), NULL, (int)mode, &log_frames, &ckpt_frames);
    if (out_log != NULL) {
        *out_log = (int32_t)log_frames;
    }
    if (out_ckpt != NULL) {
        *out_ckpt = (int32_t)ckpt_frames;
    }
    return (int32_t)rc;
}

int64_t stq_prepare(int64_t db, const char *sql, int32_t sql_len) {
    if (db == 0 || sql == NULL) {
        return 0;
    }
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(STQ_DB(db), sql, (int)sql_len, &stmt, NULL) != 0) {
        return 0;
    }
    return (int64_t)(intptr_t)stmt;
}

int32_t stq_finalize(int64_t stmt) {
    if (stmt == 0) {
        return 0;
    }
    return (int32_t)sqlite3_finalize(STQ_STMT(stmt));
}

int32_t stq_reset(int64_t stmt) {
    if (stmt == 0) {
        return 21;
    }
    return (int32_t)sqlite3_reset(STQ_STMT(stmt));
}

int32_t stq_clear_bindings(int64_t stmt) {
    if (stmt == 0) {
        return 21;
    }
    return (int32_t)sqlite3_clear_bindings(STQ_STMT(stmt));
}

int32_t stq_step(int64_t stmt) {
    if (stmt == 0) {
        return 21;
    }
    return (int32_t)sqlite3_step(STQ_STMT(stmt));
}

int32_t stq_bind_null(int64_t stmt, int32_t index) {
    return (int32_t)sqlite3_bind_null(STQ_STMT(stmt), (int)index);
}

int32_t stq_bind_int64(int64_t stmt, int32_t index, int64_t value) {
    return (int32_t)sqlite3_bind_int64(STQ_STMT(stmt), (int)index, value);
}

int32_t stq_bind_double(int64_t stmt, int32_t index, double value) {
    return (int32_t)sqlite3_bind_double(STQ_STMT(stmt), (int)index, value);
}

int32_t stq_bind_text(int64_t stmt, int32_t index, const uint8_t *data, int32_t len) {
    const char *p = (data != NULL) ? (const char *)data : "";
    return (int32_t)sqlite3_bind_text(STQ_STMT(stmt), (int)index, p, (int)len, STQ_SQLITE_TRANSIENT);
}

int32_t stq_bind_blob(int64_t stmt, int32_t index, const uint8_t *data, int32_t len) {
    const void *p = (data != NULL) ? (const void *)data : (const void *)"";
    return (int32_t)sqlite3_bind_blob(STQ_STMT(stmt), (int)index, p, (int)len, STQ_SQLITE_TRANSIENT);
}

int32_t stq_column_count(int64_t stmt) {
    return (int32_t)sqlite3_column_count(STQ_STMT(stmt));
}

void *stq_column_name(int64_t stmt, int32_t index, int64_t *out_len) {
    return copy_cstr(sqlite3_column_name(STQ_STMT(stmt), (int)index), out_len);
}

int32_t stq_column_type(int64_t stmt, int32_t index) {
    return (int32_t)sqlite3_column_type(STQ_STMT(stmt), (int)index);
}

int64_t stq_column_int64(int64_t stmt, int32_t index) {
    return sqlite3_column_int64(STQ_STMT(stmt), (int)index);
}

double stq_column_double(int64_t stmt, int32_t index) {
    return sqlite3_column_double(STQ_STMT(stmt), (int)index);
}

void *stq_column_text(int64_t stmt, int32_t index, int64_t *out_len) {
    const unsigned char *p = sqlite3_column_text(STQ_STMT(stmt), (int)index);
    int n = sqlite3_column_bytes(STQ_STMT(stmt), (int)index);
    return copy_bytes(p, n, out_len);
}

void *stq_column_blob(int64_t stmt, int32_t index, int64_t *out_len) {
    const void *p = sqlite3_column_blob(STQ_STMT(stmt), (int)index);
    int n = sqlite3_column_bytes(STQ_STMT(stmt), (int)index);
    return copy_bytes(p, n, out_len);
}

void stq_free(void *ptr) {
    free(ptr);
}
