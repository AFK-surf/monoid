// Direct C11 FFI bridge to the `sqlite3_*` symbols exported by `libstillfail_shell.a`
// (matching station/mb/src/sql/sql.c without JSON serialization overhead).
// Uses generation-validated private handle tables so Pion value copies cannot cause
// use-after-free or double-free on `close` / `finalize`.

#include "station_sqlite.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef SRWLOCK stq_lock_t;
#define STQ_LOCK_INIT SRWLOCK_INIT
static void stq_lock(stq_lock_t *l) { AcquireSRWLockExclusive(l); }
static void stq_unlock(stq_lock_t *l) { ReleaseSRWLockExclusive(l); }
#else
#include <pthread.h>
typedef pthread_mutex_t stq_lock_t;
#define STQ_LOCK_INIT PTHREAD_MUTEX_INITIALIZER
static void stq_lock(stq_lock_t *l) { pthread_mutex_lock(l); }
static void stq_unlock(stq_lock_t *l) { pthread_mutex_unlock(l); }
#endif

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
#define STQ_SQLITE_NOMEM  7
#define STQ_SQLITE_MISUSE 21

#define STQ_MAX_DBS   256u
#define STQ_MAX_STMTS 4096u

typedef struct stq_db_slot {
    sqlite3 *ptr;
    uint32_t gen;
    int32_t busy_timeout_ms;
} stq_db_slot_t;

typedef struct stq_stmt_slot {
    sqlite3_stmt *ptr;
    uint32_t gen;
} stq_stmt_slot_t;

static stq_lock_t g_table_lock = STQ_LOCK_INIT;
static stq_db_slot_t g_dbs[STQ_MAX_DBS];
static stq_stmt_slot_t g_stmts[STQ_MAX_STMTS];

static int64_t encode_handle(uint32_t slot, uint32_t gen) {
    return ((int64_t)gen << 16) | (int64_t)(slot + 1u);
}

static int decode_handle(int64_t h, uint32_t max_slots, uint32_t *out_slot, uint32_t *out_gen) {
    if (h <= 0) {
        return 0;
    }
    uint64_t u = (uint64_t)h;
    uint32_t raw_slot = (uint32_t)(u & 0xFFFFu);
    uint32_t gen = (uint32_t)(u >> 16);
    if (raw_slot == 0 || raw_slot > max_slots || gen == 0) {
        return 0;
    }
    *out_slot = raw_slot - 1u;
    *out_gen = gen;
    return 1;
}

static uint32_t bump_gen(uint32_t gen) {
    gen += 1u;
    if (gen == 0) {
        gen = 1u;
    }
    return gen;
}

static sqlite3 *lookup_db(int64_t h, int32_t *out_busy_ms) {
    uint32_t slot = 0, gen = 0;
    if (!decode_handle(h, STQ_MAX_DBS, &slot, &gen)) {
        return NULL;
    }
    stq_lock(&g_table_lock);
    sqlite3 *db = NULL;
    if (g_dbs[slot].ptr != NULL && g_dbs[slot].gen == gen) {
        db = g_dbs[slot].ptr;
        if (out_busy_ms != NULL) {
            *out_busy_ms = g_dbs[slot].busy_timeout_ms;
        }
    }
    stq_unlock(&g_table_lock);
    return db;
}

static sqlite3_stmt *lookup_stmt(int64_t h) {
    uint32_t slot = 0, gen = 0;
    if (!decode_handle(h, STQ_MAX_STMTS, &slot, &gen)) {
        return NULL;
    }
    stq_lock(&g_table_lock);
    sqlite3_stmt *stmt = NULL;
    if (g_stmts[slot].ptr != NULL && g_stmts[slot].gen == gen) {
        stmt = g_stmts[slot].ptr;
    }
    stq_unlock(&g_table_lock);
    return stmt;
}

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

    int64_t handle = -(int64_t)STQ_SQLITE_NOMEM;
    stq_lock(&g_table_lock);
    for (uint32_t i = 0; i < STQ_MAX_DBS; i++) {
        if (g_dbs[i].ptr == NULL) {
            g_dbs[i].gen = bump_gen(g_dbs[i].gen);
            g_dbs[i].ptr = db;
            g_dbs[i].busy_timeout_ms = busy_timeout_ms > 0 ? busy_timeout_ms : 0;
            handle = encode_handle(i, g_dbs[i].gen);
            break;
        }
    }
    stq_unlock(&g_table_lock);

    if (handle <= 0) {
        sqlite3_close_v2(db);
    }
    return handle;
}

int32_t stq_close(int64_t db_h) {
    uint32_t slot = 0, gen = 0;
    if (!decode_handle(db_h, STQ_MAX_DBS, &slot, &gen)) {
        return STQ_SQLITE_MISUSE;
    }
    sqlite3 *db = NULL;
    stq_lock(&g_table_lock);
    if (g_dbs[slot].ptr != NULL && g_dbs[slot].gen == gen) {
        db = g_dbs[slot].ptr;
        g_dbs[slot].ptr = NULL;
        g_dbs[slot].gen = bump_gen(g_dbs[slot].gen);
        g_dbs[slot].busy_timeout_ms = 0;
    }
    stq_unlock(&g_table_lock);
    if (db == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    return (int32_t)sqlite3_close_v2(db);
}

void *stq_errmsg(int64_t db_h, int64_t *out_len) {
    sqlite3 *db = lookup_db(db_h, NULL);
    if (db == NULL) {
        return copy_cstr("invalid or closed db handle", out_len);
    }
    return copy_cstr(sqlite3_errmsg(db), out_len);
}

void *stq_errstr(int32_t rc, int64_t *out_len) {
    return copy_cstr(sqlite3_errstr((int)rc), out_len);
}

int32_t stq_exec(int64_t db_h, const char *sql) {
    sqlite3 *db = lookup_db(db_h, NULL);
    if (db == NULL || sql == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    return (int32_t)sqlite3_exec(db, sql, NULL, NULL, NULL);
}

int32_t stq_changes(int64_t db_h) {
    sqlite3 *db = lookup_db(db_h, NULL);
    if (db == NULL) {
        return 0;
    }
    return (int32_t)sqlite3_changes(db);
}

int32_t stq_autocommit(int64_t db_h) {
    sqlite3 *db = lookup_db(db_h, NULL);
    if (db == NULL) {
        return 1;
    }
    return (int32_t)sqlite3_get_autocommit(db);
}

int32_t stq_wal_checkpoint(int64_t db_h, int32_t mode, int32_t *out_log, int32_t *out_ckpt) {
    sqlite3 *db = lookup_db(db_h, NULL);
    if (db == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    int log_frames = -1;
    int ckpt_frames = -1;
    int rc = sqlite3_wal_checkpoint_v2(db, "main", (int)mode, &log_frames, &ckpt_frames);
    if (out_log != NULL) {
        *out_log = (int32_t)log_frames;
    }
    if (out_ckpt != NULL) {
        *out_ckpt = (int32_t)ckpt_frames;
    }
    return (int32_t)rc;
}

static int query_busy_timeout_ms(sqlite3 *db, int fallback_ms) {
    sqlite3_stmt *stmt = NULL;
    int val = fallback_ms;
    if (sqlite3_prepare_v2(db, "PRAGMA busy_timeout", -1, &stmt, NULL) == 0 && stmt != NULL) {
        if (sqlite3_step(stmt) == 100) { // SQLITE_ROW
            val = (int)sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }
    return val;
}

int32_t stq_wal_checkpoint_hard(
    int64_t db_h,
    int32_t mode,
    int32_t temp_busy_ms,
    int32_t *out_log,
    int32_t *out_ckpt) {
    int32_t open_busy = 0;
    sqlite3 *db = lookup_db(db_h, &open_busy);
    if (db == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    int prev_busy = query_busy_timeout_ms(db, (int)open_busy);
    sqlite3_busy_timeout(db, (int)(temp_busy_ms > 0 ? temp_busy_ms : 1000));
    int log_frames = -1;
    int ckpt_frames = -1;
    int rc = sqlite3_wal_checkpoint_v2(db, "main", (int)mode, &log_frames, &ckpt_frames);
    sqlite3_busy_timeout(db, prev_busy);
    if (out_log != NULL) {
        *out_log = (int32_t)log_frames;
    }
    if (out_ckpt != NULL) {
        *out_ckpt = (int32_t)ckpt_frames;
    }
    return (int32_t)rc;
}

int64_t stq_prepare(int64_t db_h, const char *sql, int32_t sql_len, int32_t *out_rc) {
    sqlite3 *db = lookup_db(db_h, NULL);
    if (db == NULL || sql == NULL) {
        if (out_rc != NULL) {
            *out_rc = STQ_SQLITE_MISUSE;
        }
        return 0;
    }
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(db, sql, (int)sql_len, &stmt, NULL);
    if (rc != 0 || stmt == NULL) {
        if (out_rc != NULL) {
            *out_rc = (int32_t)(rc != 0 ? rc : STQ_SQLITE_MISUSE);
        }
        return 0;
    }

    int64_t handle = 0;
    stq_lock(&g_table_lock);
    for (uint32_t i = 0; i < STQ_MAX_STMTS; i++) {
        if (g_stmts[i].ptr == NULL) {
            g_stmts[i].gen = bump_gen(g_stmts[i].gen);
            g_stmts[i].ptr = stmt;
            handle = encode_handle(i, g_stmts[i].gen);
            break;
        }
    }
    stq_unlock(&g_table_lock);

    if (handle == 0) {
        sqlite3_finalize(stmt);
        if (out_rc != NULL) {
            *out_rc = STQ_SQLITE_NOMEM;
        }
        return 0;
    }
    if (out_rc != NULL) {
        *out_rc = 0;
    }
    return handle;
}

int32_t stq_finalize(int64_t stmt_h) {
    uint32_t slot = 0, gen = 0;
    if (!decode_handle(stmt_h, STQ_MAX_STMTS, &slot, &gen)) {
        return STQ_SQLITE_MISUSE;
    }
    sqlite3_stmt *stmt = NULL;
    stq_lock(&g_table_lock);
    if (g_stmts[slot].ptr != NULL && g_stmts[slot].gen == gen) {
        stmt = g_stmts[slot].ptr;
        g_stmts[slot].ptr = NULL;
        g_stmts[slot].gen = bump_gen(g_stmts[slot].gen);
    }
    stq_unlock(&g_table_lock);
    if (stmt == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    return (int32_t)sqlite3_finalize(stmt);
}

int32_t stq_reset(int64_t stmt_h) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    return (int32_t)sqlite3_reset(stmt);
}

int32_t stq_clear_bindings(int64_t stmt_h) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    return (int32_t)sqlite3_clear_bindings(stmt);
}

int32_t stq_step(int64_t stmt_h) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    return (int32_t)sqlite3_step(stmt);
}

int32_t stq_bind_null(int64_t stmt_h, int32_t index) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    return (int32_t)sqlite3_bind_null(stmt, (int)index);
}

int32_t stq_bind_int64(int64_t stmt_h, int32_t index, int64_t value) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    return (int32_t)sqlite3_bind_int64(stmt, (int)index, value);
}

int32_t stq_bind_double(int64_t stmt_h, int32_t index, double value) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    return (int32_t)sqlite3_bind_double(stmt, (int)index, value);
}

int32_t stq_bind_text(int64_t stmt_h, int32_t index, const uint8_t *data, int32_t len) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    const char *p = (data != NULL) ? (const char *)data : "";
    return (int32_t)sqlite3_bind_text(stmt, (int)index, p, (int)len, STQ_SQLITE_TRANSIENT);
}

int32_t stq_bind_blob(int64_t stmt_h, int32_t index, const uint8_t *data, int32_t len) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return STQ_SQLITE_MISUSE;
    }
    const void *p = (data != NULL) ? (const void *)data : (const void *)"";
    return (int32_t)sqlite3_bind_blob(stmt, (int)index, p, (int)len, STQ_SQLITE_TRANSIENT);
}

int32_t stq_column_count(int64_t stmt_h) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return 0;
    }
    return (int32_t)sqlite3_column_count(stmt);
}

void *stq_column_name(int64_t stmt_h, int32_t index, int64_t *out_len) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return copy_bytes(NULL, 0, out_len);
    }
    return copy_cstr(sqlite3_column_name(stmt, (int)index), out_len);
}

int32_t stq_column_type(int64_t stmt_h, int32_t index) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return 5; // SQLITE_NULL
    }
    return (int32_t)sqlite3_column_type(stmt, (int)index);
}

int64_t stq_column_int64(int64_t stmt_h, int32_t index) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return 0;
    }
    return sqlite3_column_int64(stmt, (int)index);
}

double stq_column_double(int64_t stmt_h, int32_t index) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return 0.0;
    }
    return sqlite3_column_double(stmt, (int)index);
}

void *stq_column_text(int64_t stmt_h, int32_t index, int64_t *out_len) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return copy_bytes(NULL, 0, out_len);
    }
    const unsigned char *p = sqlite3_column_text(stmt, (int)index);
    int n = sqlite3_column_bytes(stmt, (int)index);
    return copy_bytes(p, n, out_len);
}

void *stq_column_blob(int64_t stmt_h, int32_t index, int64_t *out_len) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return copy_bytes(NULL, 0, out_len);
    }
    const void *p = sqlite3_column_blob(stmt, (int)index);
    int n = sqlite3_column_bytes(stmt, (int)index);
    return copy_bytes(p, n, out_len);
}

void stq_free(void *ptr) {
    free(ptr);
}
