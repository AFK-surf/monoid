// Unit tests for `station_sqlite.c` (plain -DNDEBUG, ASan+UBSan, TSan).
// Uses self-contained mock `sqlite3_*` symbols so `c-shims` runs with zero external library
// dependencies while thoroughly exercising handle tables, generation UAF guards,
// `stq_stmt_readonly`, `stq_bind_parameter_count`, `stq_reset` vs `stq_clear_bindings`,
// and concurrent table access.

#include "station_sqlite.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REQUIRE(cond)                                                            \
    do {                                                                         \
        if (!(cond)) {                                                           \
            fprintf(stderr, "station_sqlite_test FAIL at %s:%d: %s\n", __FILE__, \
                    __LINE__, #cond);                                            \
            exit(1);                                                             \
        }                                                                        \
    } while (0)

struct sqlite3 {
    int flags;
    int busy_timeout;
    int changes;
    int autocommit;
};

struct sqlite3_stmt {
    int readonly;
    int param_count;
    int bound_mask;
    int reset_count;
    int clear_count;
};

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

int sqlite3_open_v2(const char *filename, sqlite3 **db, int flags, const char *vfs) {
    (void)vfs;
    if (filename == NULL || strcmp(filename, "fail_open") == 0) {
        *db = NULL;
        return 14; // SQLITE_CANTOPEN
    }
    sqlite3 *conn = (sqlite3 *)calloc(1, sizeof(sqlite3));
    if (conn == NULL) {
        return 7; // SQLITE_NOMEM
    }
    conn->flags = flags;
    conn->autocommit = 1;
    *db = conn;
    return 0;
}

int sqlite3_close_v2(sqlite3 *db) {
    free(db);
    return 0;
}

int sqlite3_busy_timeout(sqlite3 *db, int ms) {
    if (db != NULL) {
        db->busy_timeout = ms;
    }
    return 0;
}

int sqlite3_exec(sqlite3 *db, const char *sql, void *callback, void *arg, char **errmsg) {
    (void)callback;
    (void)arg;
    (void)errmsg;
    if (db == NULL || sql == NULL) {
        return 21;
    }
    return 0;
}

const char *sqlite3_errmsg(sqlite3 *db) {
    return db != NULL ? "mock errmsg" : "out of memory";
}

const char *sqlite3_errstr(int rc) {
    return rc == 14 ? "unable to open database file" : "mock errstr";
}

int sqlite3_changes(sqlite3 *db) {
    return db != NULL ? db->changes : 0;
}

int sqlite3_get_autocommit(sqlite3 *db) {
    return db != NULL ? db->autocommit : 1;
}

int sqlite3_wal_checkpoint_v2(sqlite3 *db, const char *zDb, int eMode, int *pnLog, int *pnCkpt) {
    (void)db;
    (void)zDb;
    (void)eMode;
    if (pnLog != NULL) *pnLog = 0;
    if (pnCkpt != NULL) *pnCkpt = 0;
    return 0;
}

int sqlite3_prepare_v2(sqlite3 *db, const char *sql, int bytes, sqlite3_stmt **stmt, const char **tail) {
    (void)db;
    (void)tail;
    if (sql == NULL || bytes <= 0) {
        *stmt = NULL;
        return 1;
    }
    sqlite3_stmt *s = (sqlite3_stmt *)calloc(1, sizeof(sqlite3_stmt));
    if (s == NULL) {
        return 7;
    }
    s->readonly = (bytes >= 6 && memcmp(sql, "SELECT", 6) == 0) ? 1 : 0;
    int qmarks = 0;
    for (int i = 0; i < bytes; i++) {
        if (sql[i] == '?') {
            qmarks++;
        }
    }
    s->param_count = qmarks;
    *stmt = s;
    return 0;
}

int sqlite3_finalize(sqlite3_stmt *stmt) {
    free(stmt);
    return 0;
}

int sqlite3_reset(sqlite3_stmt *stmt) {
    if (stmt == NULL) return 21;
    stmt->reset_count++;
    return 0;
}

int sqlite3_clear_bindings(sqlite3_stmt *stmt) {
    if (stmt == NULL) return 21;
    stmt->bound_mask = 0;
    stmt->clear_count++;
    return 0;
}

int sqlite3_step(sqlite3_stmt *stmt) {
    if (stmt == NULL) return 21;
    return 101; // SQLITE_DONE
}

int sqlite3_stmt_readonly(sqlite3_stmt *stmt) {
    return stmt != NULL ? stmt->readonly : 0;
}

int sqlite3_bind_parameter_count(sqlite3_stmt *stmt) {
    return stmt != NULL ? stmt->param_count : 0;
}

int sqlite3_bind_null(sqlite3_stmt *stmt, int i) {
    if (stmt == NULL || i < 1 || i > 30) return 21;
    stmt->bound_mask |= (1 << i);
    return 0;
}

int sqlite3_bind_int64(sqlite3_stmt *stmt, int i, int64_t v) {
    (void)v;
    return sqlite3_bind_null(stmt, i);
}

int sqlite3_bind_double(sqlite3_stmt *stmt, int i, double v) {
    (void)v;
    return sqlite3_bind_null(stmt, i);
}

int sqlite3_bind_text(sqlite3_stmt *stmt, int i, const char *v, int n, void (*destructor)(void *)) {
    (void)v;
    (void)n;
    (void)destructor;
    return sqlite3_bind_null(stmt, i);
}

int sqlite3_bind_blob(sqlite3_stmt *stmt, int i, const void *v, int n, void (*destructor)(void *)) {
    (void)v;
    (void)n;
    (void)destructor;
    return sqlite3_bind_null(stmt, i);
}

int sqlite3_column_count(sqlite3_stmt *stmt) {
    (void)stmt;
    return 0;
}

const char *sqlite3_column_name(sqlite3_stmt *stmt, int i) {
    (void)stmt;
    (void)i;
    return "";
}

int sqlite3_column_type(sqlite3_stmt *stmt, int i) {
    (void)stmt;
    (void)i;
    return 5;
}

int64_t sqlite3_column_int64(sqlite3_stmt *stmt, int i) {
    (void)stmt;
    (void)i;
    return 0;
}

double sqlite3_column_double(sqlite3_stmt *stmt, int i) {
    (void)stmt;
    (void)i;
    return 0.0;
}

const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int i) {
    (void)stmt;
    (void)i;
    return (const unsigned char *)"";
}

const void *sqlite3_column_blob(sqlite3_stmt *stmt, int i) {
    (void)stmt;
    (void)i;
    return "";
}

int sqlite3_column_bytes(sqlite3_stmt *stmt, int i) {
    (void)stmt;
    (void)i;
    return 0;
}

static void *worker_thread(void *arg) {
    int id = *(int *)arg;
    for (int iter = 0; iter < 50; iter++) {
        int64_t db = stq_open("ok.db", 2 | 64 | 32768, 250);
        REQUIRE(db > 0);
        int32_t rc = 0;
        const char *sql = (id % 2 == 0) ? "SELECT ? + ? + ?" : "INSERT INTO t VALUES (?, ?)";
        int64_t st = stq_prepare(db, sql, (int32_t)strlen(sql), &rc);
        REQUIRE(st > 0 && rc == 0);
        REQUIRE(stq_stmt_readonly(st) == (id % 2 == 0 ? 1 : 0));
        REQUIRE(stq_bind_parameter_count(st) == (id % 2 == 0 ? 3 : 2));
        REQUIRE(stq_reset(st) == 0);
        REQUIRE(stq_clear_bindings(st) == 0);
        REQUIRE(stq_finalize(st) == 0);
        REQUIRE(stq_stmt_readonly(st) == 0);
        REQUIRE(stq_bind_parameter_count(st) == 0);
        REQUIRE(stq_close(db) == 0);
    }
    return NULL;
}

int main(void) {
    // 1. Open failure returns negative rc; errstr works.
    int64_t bad_db = stq_open("fail_open", 2 | 64 | 32768, 250);
    REQUIRE(bad_db == -14);
    int64_t elen = 0;
    void *estr = stq_errstr(14, &elen);
    REQUIRE(estr != NULL && elen > 0);
    stq_free(estr);

    // 2. Valid open, prepare SELECT (readonly=1, params=2) and INSERT (readonly=0, params=3).
    int64_t db = stq_open("test.db", 2 | 64 | 32768, 250);
    REQUIRE(db > 0);

    int32_t rc = 0;
    const char *sel_sql = "SELECT a, b FROM t WHERE x = ? AND y = ?";
    int64_t sel = stq_prepare(db, sel_sql, (int32_t)strlen(sel_sql), &rc);
    REQUIRE(sel > 0 && rc == 0);
    REQUIRE(stq_stmt_readonly(sel) == 1);
    REQUIRE(stq_bind_parameter_count(sel) == 2);

    const char *ins_sql = "INSERT INTO t VALUES (?, ?, ?)";
    int64_t ins = stq_prepare(db, ins_sql, (int32_t)strlen(ins_sql), &rc);
    REQUIRE(ins > 0 && rc == 0);
    REQUIRE(stq_stmt_readonly(ins) == 0);
    REQUIRE(stq_bind_parameter_count(ins) == 3);

    // 3. Finalize invalidates handles; post-finalize queries return 0 safely (no UAF).
    REQUIRE(stq_finalize(sel) == 0);
    REQUIRE(stq_finalize(sel) == 21); // SQLITE_MISUSE
    REQUIRE(stq_stmt_readonly(sel) == 0);
    REQUIRE(stq_bind_parameter_count(sel) == 0);

    REQUIRE(stq_finalize(ins) == 0);
    REQUIRE(stq_stmt_readonly(0) == 0);
    REQUIRE(stq_bind_parameter_count(0) == 0);
    REQUIRE(stq_stmt_readonly(-1) == 0);
    REQUIRE(stq_bind_parameter_count(-1) == 0);

    REQUIRE(stq_close(db) == 0);
    REQUIRE(stq_close(db) == 21);

    // 4. Multi-threaded handle table stress (TSan verification).
    pthread_t threads[4];
    int ids[4] = {0, 1, 2, 3};
    for (int i = 0; i < 4; i++) {
        REQUIRE(pthread_create(&threads[i], NULL, worker_thread, &ids[i]) == 0);
    }
    for (int i = 0; i < 4; i++) {
        REQUIRE(pthread_join(threads[i], NULL) == 0);
    }

    // 5. ECMAScript shortest-decimal double formatting (`stq_format_js_double`).
    struct {
        double v;
        const char *want;
    } fmt_cases[] = {
        {0.0, "0"},
        {-0.0, "0"},
        {1.0, "1"},
        {100.0, "100"},
        {1.5, "1.5"},
        {-1.5, "-1.5"},
        {0.00001, "0.00001"},
        {0.000001, "0.000001"},
        {1e-7, "1e-7"},
        {1.5e-7, "1.5e-7"},
        {1e20, "100000000000000000000"},
        {1e21, "1e+21"},
        {1.8531501765868567e21, "1.8531501765868567e+21"},
        {9007199254740992.0, "9007199254740992"},
        // Asymmetric rounding boundaries (powers of two where upper half-ULP is 2x lower).
        {5.960464477539063e-8, "5.960464477539063e-8"},   // 2^-24
        {-5.960464477539063e-8, "-5.960464477539063e-8"}, // -2^-24
        {2.9802322387695312e-8, "2.9802322387695312e-8"}, // 2^-25
        {2.220446049250313e-16, "2.220446049250313e-16"}, // 2^-52 (DBL_EPSILON)
        {1.1102230246251565e-16, "1.1102230246251565e-16"}, // 2^-53
        {2.2250738585072014e-308, "2.2250738585072014e-308"}, // 2^-1022 (DBL_MIN)
        {5e-324, "5e-324"},                               // 2^-1074 (DBL_TRUE_MIN)
    };
    for (size_t i = 0; i < sizeof(fmt_cases) / sizeof(fmt_cases[0]); i++) {
        int64_t flen = 0;
        char *fstr = (char *)stq_format_js_double(fmt_cases[i].v, &flen);
        REQUIRE(fstr != NULL);
        REQUIRE((size_t)flen == strlen(fmt_cases[i].want));
        REQUIRE(memcmp(fstr, fmt_cases[i].want, (size_t)flen) == 0);
        stq_free(fstr);
    }
    // Non-finite doubles -> "null".
    double zero_d = 0.0;
    double nonfinite[3] = {0.0 / zero_d, 1.0 / zero_d, -1.0 / zero_d};
    for (int i = 0; i < 3; i++) {
        int64_t flen = 0;
        char *fstr = (char *)stq_format_js_double(nonfinite[i], &flen);
        REQUIRE(fstr != NULL && flen == 4 && memcmp(fstr, "null", 4) == 0);
        stq_free(fstr);
    }

    printf("station_sqlite_test: ALL PASSED\n");
    return 0;
}
