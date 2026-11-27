// Thin C bridge registering the compiled Pion `core_runtime` driver callbacks
// into `packages/core_abi/native/core_pion.c` (`apps/mbui/src/host/core_api.h`),
// wiring native event-driven wake (`mb_core_register_wake` / `mb_core_wake`),
// and forwarding screen/media callbacks directly in pure C without touching the Pion heap.

#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "core_api.h"

void pion_core_log_warn(const char *msg, int64_t len) {
    if (msg != NULL && len > 0) {
        fprintf(stderr, "[pion-core] %.*s\n", (int)len, msg);
    }
}

int64_t pion_core_wall_now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        return 0;
    }
    return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000L);
}

int32_t pion_core_utc_offset_min(int64_t ms) {
    time_t sec = (time_t)(ms / 1000LL);
    struct tm lt;
    if (localtime_r(&sec, &lt) == NULL) {
        return 0;
    }
    return (int32_t)(lt.tm_gmtoff / 60L);
}

// Exported by `packages/core_runtime/src/core_runtime.pion` (`pub extern "C" fn`; Pion `Int` is `int32_t`)
extern void pion_pkg_core_runtime_init_consts(void);
extern int32_t pion_core_runtime_start(
    const char *data_dir,
    int64_t data_dir_len,
    const char *cloud_origin,
    int64_t cloud_origin_len,
    int32_t beta);
extern void pion_core_runtime_send(
    const char *json,
    int64_t len,
    const uint8_t *bytes,
    int64_t blen);
extern void pion_core_runtime_stop(void);
extern int64_t pion_core_runtime_on_wake(void);

// Exported by `pion/base/packages/shell/native/shell_pion.c` (pure C, thread-safe)
typedef void (*bsh_say_fn)(
    void *ctx,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *bytes,
    size_t bytes_len);
typedef uint8_t (*bsh_media_fn)(
    void *ctx,
    uint64_t call,
    uint8_t kind,
    uint8_t key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t bytes_len);

extern void bsh_on_wake(void (*woke)(void *), void *ctx);
extern void bsh_on_say(bsh_say_fn say, void *ctx);
extern void bsh_on_media(bsh_media_fn media, void *ctx);
extern int32_t bsh_screen_ack(double call, double ts);
extern int32_t bsh_screen_input(double call, const uint8_t *json, size_t len);

// Driver & native wake ABI from `packages/core_abi/native/core_pion.c`
typedef void (*mb_core_driver_start_fn)(const char *, const char *, int, void *);
typedef void (*mb_core_driver_send_fn)(const char *, size_t, const uint8_t *, size_t, void *);
typedef void (*mb_core_driver_stop_fn)(void *);
typedef int (*mb_core_driver_screen_ack_fn)(double, double, void *);
typedef int (*mb_core_driver_screen_input_fn)(double, const uint8_t *, size_t, void *);
typedef int64_t (*mb_core_driver_wake_fn)(void *user_ctx);

typedef struct mb_core_driver {
    mb_core_driver_start_fn on_start;
    mb_core_driver_send_fn on_send;
    mb_core_driver_stop_fn on_stop;
    mb_core_driver_screen_ack_fn on_screen_ack;
    mb_core_driver_screen_input_fn on_screen_input;
    void *user_ctx;
} mb_core_driver_t;

extern void mb_core_register_driver(const mb_core_driver_t *driver);
extern void mb_core_register_wake(mb_core_driver_wake_fn on_wake, void *user_ctx);
extern void mb_core_wake(void);
extern int mb_core_emit(const char *json, size_t len, const uint8_t *bytes, size_t blen);
extern int mb_core_deliver_media(
    uint64_t call,
    int kind,
    int key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t len);

static pthread_once_t g_pion_consts_once = PTHREAD_ONCE_INIT;
static _Atomic int g_bridge_active = 0;

static void init_pion_consts_once(void) {
    pion_pkg_core_runtime_init_consts();
}

static int64_t bridge_on_wake(void *user_ctx) {
    (void)user_ctx;
    if (!atomic_load(&g_bridge_active)) {
        return -1;
    }
    return pion_core_runtime_on_wake();
}

static void bridge_on_shell_wake(void *ctx) {
    (void)ctx;
    if (!atomic_load(&g_bridge_active)) {
        return;
    }
    mb_core_wake();
}

static void bridge_on_shell_say(
    void *ctx,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *bytes,
    size_t bytes_len) {
    (void)ctx;
    if (!atomic_load(&g_bridge_active)) {
        return;
    }
    (void)mb_core_emit((const char *)json, json_len, bytes, bytes_len);
}

static uint8_t bridge_on_shell_media(
    void *ctx,
    uint64_t call,
    uint8_t kind,
    uint8_t key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t bytes_len) {
    (void)ctx;
    if (!atomic_load(&g_bridge_active)) {
        return 0;
    }
    return mb_core_deliver_media(call, (int)kind, (int)key, seq, ts, bytes, bytes_len) ? 1 : 0;
}

static void bridge_on_start(const char *data_dir, const char *cloud_origin, int beta, void *user_ctx) {
    (void)user_ctx;
    (void)pthread_once(&g_pion_consts_once, init_pion_consts_once);
    atomic_store(&g_bridge_active, 1);
    int64_t dlen = data_dir != NULL ? (int64_t)strlen(data_dir) : 0;
    int64_t clen = cloud_origin != NULL ? (int64_t)strlen(cloud_origin) : 0;
    int32_t ok = pion_core_runtime_start(data_dir, dlen, cloud_origin, clen, (int32_t)beta);
    if (ok != 0) {
        bsh_on_wake(bridge_on_shell_wake, NULL);
        bsh_on_say(bridge_on_shell_say, NULL);
        bsh_on_media(bridge_on_shell_media, NULL);
    }
}

static void bridge_on_send(const char *json, size_t len, const uint8_t *bytes, size_t blen, void *user_ctx) {
    (void)user_ctx;
    pion_core_runtime_send(json, (int64_t)len, bytes, (int64_t)blen);
}

static void bridge_on_stop(void *user_ctx) {
    (void)user_ctx;
    atomic_store(&g_bridge_active, 0);
    bsh_on_media(NULL, NULL);
    bsh_on_say(NULL, NULL);
    bsh_on_wake(NULL, NULL);
    pion_core_runtime_stop();
}

static int bridge_on_screen_ack(double call, double ts, void *user_ctx) {
    (void)user_ctx;
    return (int)bsh_screen_ack(call, ts);
}

static int bridge_on_screen_input(double call, const uint8_t *json, size_t len, void *user_ctx) {
    (void)user_ctx;
    return (int)bsh_screen_input(call, json, len);
}

void mb_core_attach_pion_runtime(void) {
    mb_core_driver_t drv = {
        bridge_on_start,
        bridge_on_send,
        bridge_on_stop,
        bridge_on_screen_ack,
        bridge_on_screen_input,
        NULL,
    };
    mb_core_register_driver(&drv);
    mb_core_register_wake(bridge_on_wake, NULL);
}
