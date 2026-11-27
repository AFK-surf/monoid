// Direct C11 FFI bridge to the `sqlite3_*` symbols exported by `libstillfail_shell.a`
// (matching station/mb/src/sql/sql.c without JSON serialization overhead).
// Uses generation-validated private handle tables so Pion value copies cannot cause
// use-after-free or double-free on `close` / `finalize`.

#include "station_sqlite.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
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
extern int sqlite3_stmt_readonly(sqlite3_stmt *stmt);
extern int sqlite3_bind_parameter_count(sqlite3_stmt *stmt);
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

// Single-owner thread contract: g_table_lock protects only slot lookup/alloc/free;
// caller must serialize calls on the same db/stmt handle (consistent with SQLITE_OPEN_NO_MUTEX).
int32_t stq_stmt_readonly(int64_t stmt_h) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return 0;
    }
    return (int32_t)sqlite3_stmt_readonly(stmt);
}

// Single-owner thread contract: g_table_lock protects only slot lookup/alloc/free;
// caller must serialize calls on the same db/stmt handle (consistent with SQLITE_OPEN_NO_MUTEX).
int32_t stq_bind_parameter_count(int64_t stmt_h) {
    sqlite3_stmt *stmt = lookup_stmt(stmt_h);
    if (stmt == NULL) {
        return 0;
    }
    return (int32_t)sqlite3_bind_parameter_count(stmt);
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

static void build_sci_candidate(char *buf, size_t cap, const char *digs, int k, int exp) {
    int p = 0;
    buf[p++] = digs[0];
    if (k > 1) {
        buf[p++] = '.';
        memcpy(buf + p, digs + 1, (size_t)(k - 1));
        p += k - 1;
    }
    snprintf(buf + p, cap - (size_t)p, "e%+03d", exp);
}

static int try_format_prec(double x, int prec, char digits[32], int *out_k, int *out_exp) {
    char sci[64];
    snprintf(sci, sizeof(sci), "%.*e", prec, x);

    char c0[32];
    int ck = 0;
    const char *p = sci;
    while (*p != '\0' && *p != 'e' && *p != 'E') {
        if (*p >= '0' && *p <= '9' && ck < (int)sizeof(c0) - 1) {
            c0[ck++] = *p;
        }
        p++;
    }
    c0[ck] = '\0';
    int cexp = (*p == 'e' || *p == 'E') ? atoi(p + 1) : 0;

    double p0 = strtod(sci, NULL);
    if (p0 == x) {
        memcpy(digits, c0, (size_t)ck + 1);
        *out_k = ck;
        *out_exp = cexp;
        return 1;
    }

    // At asymmetric rounding boundaries (e.g. powers of two where the upper half-ULP is
    // twice the lower half-ULP), c0 = round(x, k) can fall just outside x's rounding
    // interval while c0 + 1 (if p0 < x) or c0 - 1 (if p0 > x) lands inside and
    // round-trips to x. Monotonicity of strtod rules out the opposite direction.
    if (p0 < x) {
        char up[32];
        memcpy(up, c0, (size_t)ck + 1);
        int up_exp = cexp;
        int carry = 1;
        for (int i = ck - 1; i >= 0 && carry; i--) {
            if (up[i] == '9') {
                up[i] = '0';
            } else {
                up[i]++;
                carry = 0;
            }
        }
        if (carry) {
            up[0] = '1';
            for (int i = 1; i < ck; i++) {
                up[i] = '0';
            }
            up_exp = cexp + 1;
        }
        char up_sci[64];
        build_sci_candidate(up_sci, sizeof(up_sci), up, ck, up_exp);
        if (strtod(up_sci, NULL) == x) {
            memcpy(digits, up, (size_t)ck + 1);
            *out_k = ck;
            *out_exp = up_exp;
            return 1;
        }
        return 0;
    }

    char dn[32];
    memcpy(dn, c0, (size_t)ck + 1);
    int dn_exp = cexp;
    int all_zero_tail = 1;
    for (int i = 1; i < ck; i++) {
        if (dn[i] != '0') {
            all_zero_tail = 0;
            break;
        }
    }
    if (dn[0] == '1' && all_zero_tail) {
        for (int i = 0; i < ck; i++) {
            dn[i] = '9';
        }
        dn_exp = cexp - 1;
    } else {
        int borrow = 1;
        for (int i = ck - 1; i >= 0 && borrow; i--) {
            if (dn[i] == '0') {
                dn[i] = '9';
            } else {
                dn[i]--;
                borrow = 0;
            }
        }
    }
    char dn_sci[64];
    build_sci_candidate(dn_sci, sizeof(dn_sci), dn, ck, dn_exp);
    if (strtod(dn_sci, NULL) == x) {
        memcpy(digits, dn, (size_t)ck + 1);
        *out_k = ck;
        *out_exp = dn_exp;
        return 1;
    }
    return 0;
}

// Format a finite IEEE-754 double using ECMAScript Number::toString shortest-decimal rules
// (matching MoonBit/JS JSON.stringify: fixed notation for 1e-6 <= |d| < 1e21, otherwise
// shortest d[.ddd]e±exp with no leading zeros in exponent; -0.0 -> "0"; non-finite -> "null").
// Relies on the default "C" locale (LC_NUMERIC decimal point is '.'; stillfail-pion never
// calls setlocale).
void *stq_format_js_double(double value, int64_t *out_len) {
    if (value != value || (value - value) != 0.0) {
        return copy_cstr("null", out_len);
    }
    if (value == 0.0) {
        return copy_cstr("0", out_len);
    }
    int neg = value < 0.0;
    double x = neg ? -value : value;

    // Fast path for exact safe integers (|value| <= 2^53 - 1 < 1e21):
    // always plain decimal digits with zero snprintf/strtod calls.
    if (x <= 9007199254740991.0) {
        int64_t iv = (int64_t)x;
        if ((double)iv == x) {
            char out[32];
            char rev[24];
            int rlen = 0;
            uint64_t u = (uint64_t)iv;
            while (u > 0u) {
                rev[rlen++] = (char)('0' + (u % 10u));
                u /= 10u;
            }
            int pos = 0;
            if (neg) {
                out[pos++] = '-';
            }
            while (rlen > 0) {
                out[pos++] = rev[--rlen];
            }
            return copy_bytes(out, pos, out_len);
        }
    }

    char digits[32];
    int k = 0;
    int exp = 0;
    // Start from prec = 16 (17 significant digits, guaranteed round-trip for IEEE-754 binary64).
    // Stripping trailing zeros tightens the upper bound for short decimals (e.g. 0.5 -> hi = 0),
    // then binary search finds the exact minimum prec in at most 4 steps instead of 17.
    int hi = 16;
    if (try_format_prec(x, 16, digits, &k, &exp)) {
        while (k > 1 && digits[k - 1] == '0') {
            k--;
        }
        digits[k] = '\0';
        hi = k - 1;
    }
    int lo = 0;
    while (lo < hi) {
        int mid = lo + (hi - lo) / 2;
        char cand[32];
        int ck = 0;
        int cexp = 0;
        if (try_format_prec(x, mid, cand, &ck, &cexp)) {
            memcpy(digits, cand, (size_t)ck + 1);
            k = ck;
            exp = cexp;
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }

    while (k > 1 && digits[k - 1] == '0') {
        k--;
    }
    digits[k] = '\0';

    int n = exp + 1;

    char out[64];
    int pos = 0;
    if (neg) {
        out[pos++] = '-';
    }
    if (k <= n && n <= 21) {
        memcpy(out + pos, digits, (size_t)k);
        pos += k;
        for (int i = 0; i < n - k; i++) {
            out[pos++] = '0';
        }
        out[pos] = '\0';
    } else if (0 < n && n <= 21) {
        memcpy(out + pos, digits, (size_t)n);
        pos += n;
        out[pos++] = '.';
        memcpy(out + pos, digits + n, (size_t)(k - n));
        pos += k - n;
        out[pos] = '\0';
    } else if (-6 < n && n <= 0) {
        out[pos++] = '0';
        out[pos++] = '.';
        for (int i = 0; i < -n; i++) {
            out[pos++] = '0';
        }
        memcpy(out + pos, digits, (size_t)k);
        pos += k;
        out[pos] = '\0';
    } else {
        out[pos++] = digits[0];
        if (k > 1) {
            out[pos++] = '.';
            memcpy(out + pos, digits + 1, (size_t)(k - 1));
            pos += k - 1;
        }
        int abs_exp = exp < 0 ? -exp : exp;
        pos += snprintf(out + pos, sizeof(out) - (size_t)pos, "e%c%d", exp >= 0 ? '+' : '-', abs_exp);
    }
    return copy_bytes(out, pos, out_len);
}

void stq_free(void *ptr) {
    free(ptr);
}
