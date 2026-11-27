// Standalone SQLite auto-extension registering deterministic `js_lower(x)`
// (1:1 byte-for-byte equivalent to `pion/station/packages/jscase/src/jscase.pion`).
// Kept separate from `station_sys.c` so `station_sys_test.c` stays SQLite-free.

#include "station_sys.h"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <pthread.h>
#endif

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_context sqlite3_context;
typedef struct sqlite3_value sqlite3_value;
typedef void (*sqlite3_destructor_type)(void *);

#define STS_SQLITE_OK 0
#define STS_SQLITE_NULL 5
#define STS_SQLITE_UTF8 1
#define STS_SQLITE_DETERMINISTIC 0x000000800
#define STS_SQLITE_INNOCUOUS 0x000200000
#define STS_SQLITE_TRANSIENT ((sqlite3_destructor_type)(intptr_t)-1)

extern int sqlite3_auto_extension(void (*xEntryPoint)(void));
extern int sqlite3_create_function_v2(
    sqlite3 *db,
    const char *zFunctionName,
    int nArg,
    int eTextRep,
    void *pApp,
    void (*xFunc)(sqlite3_context *, int, sqlite3_value **),
    void (*xStep)(sqlite3_context *, int, sqlite3_value **),
    void (*xFinal)(sqlite3_context *),
    void (*xDestroy)(void *));
extern int sqlite3_value_type(sqlite3_value *pVal);
extern const unsigned char *sqlite3_value_text(sqlite3_value *pVal);
extern int sqlite3_value_bytes(sqlite3_value *pVal);
extern void sqlite3_result_text(
    sqlite3_context *ctx,
    const char *z,
    int n,
    sqlite3_destructor_type xDel);
extern void sqlite3_result_null(sqlite3_context *ctx);
extern void sqlite3_result_error_nomem(sqlite3_context *ctx);
extern void *sqlite3_malloc(int n);
extern void sqlite3_free(void *p);

static void sts_sqlite_js_lower_fn(
    sqlite3_context *ctx,
    int argc,
    sqlite3_value **argv
) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == STS_SQLITE_NULL) {
        sqlite3_result_null(ctx);
        return;
    }
    const unsigned char *txt = sqlite3_value_text(argv[0]);
    int n = sqlite3_value_bytes(argv[0]);
    if (n <= 0 || txt == NULL) {
        sqlite3_result_text(ctx, "", 0, STS_SQLITE_TRANSIENT);
        return;
    }

    // Fast path: plain lowercase ASCII requires zero transformation.
    int plain = 1;
    for (int i = 0; i < n; i++) {
        unsigned char b = txt[i];
        if (b >= 0x80u || (b >= 0x41u && b <= 0x5Au)) {
            plain = 0;
            break;
        }
    }
    if (plain) {
        sqlite3_result_text(ctx, (const char *)txt, n, STS_SQLITE_TRANSIENT);
        return;
    }

    size_t un = (size_t)n;
    if (un > (size_t)INT_MAX / 3u) {
        sqlite3_result_error_nomem(ctx);
        return;
    }
    size_t cap = un * 3u;
    size_t out_len = 0;
    if (cap <= 4096u) {
        uint8_t stack_buf[4096];
        if (!sts_js_lower_utf8((const uint8_t *)txt, un, stack_buf, sizeof(stack_buf), &out_len)) {
            sqlite3_result_error_nomem(ctx);
            return;
        }
        sqlite3_result_text(ctx, (const char *)stack_buf, (int)out_len, STS_SQLITE_TRANSIENT);
        return;
    }

    uint8_t *heap_buf = (uint8_t *)sqlite3_malloc((int)cap);
    if (heap_buf == NULL) {
        sqlite3_result_error_nomem(ctx);
        return;
    }
    if (!sts_js_lower_utf8((const uint8_t *)txt, un, heap_buf, cap, &out_len)) {
        sqlite3_free(heap_buf);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    sqlite3_result_text(ctx, (const char *)heap_buf, (int)out_len, sqlite3_free);
}

static int sts_js_lower_auto_ext(sqlite3 *db, char **pzErrMsg, const void *pApi) {
    (void)pzErrMsg;
    (void)pApi;
    return sqlite3_create_function_v2(
        db,
        "js_lower",
        1,
        STS_SQLITE_UTF8 | STS_SQLITE_DETERMINISTIC | STS_SQLITE_INNOCUOUS,
        NULL,
        sts_sqlite_js_lower_fn,
        NULL,
        NULL,
        NULL);
}

static int32_t g_sts_js_lower_rc = 0;

static void sts_do_register_sqlite_js_lower(void) {
    typedef void (*sts_auto_ext_ep)(void);
    sts_auto_ext_ep ep = (sts_auto_ext_ep)(uintptr_t)&sts_js_lower_auto_ext;
    int rc = sqlite3_auto_extension(ep);
    g_sts_js_lower_rc = (rc == STS_SQLITE_OK) ? 0 : (int32_t)rc;
}

#ifdef _WIN32
static INIT_ONCE g_sts_js_lower_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK sts_register_once_win(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    (void)once;
    (void)param;
    (void)ctx;
    sts_do_register_sqlite_js_lower();
    return TRUE;
}
#else
static pthread_once_t g_sts_js_lower_once = PTHREAD_ONCE_INIT;
#endif

int32_t sts_register_sqlite_js_lower(void) {
#ifdef _WIN32
    InitOnceExecuteOnce(&g_sts_js_lower_once, sts_register_once_win, NULL, NULL);
#else
    pthread_once(&g_sts_js_lower_once, sts_do_register_sqlite_js_lower);
#endif
    return g_sts_js_lower_rc;
}
