// Thin C bridge registering the compiled Pion `core_runtime` driver callbacks
// into `packages/core_abi/native/core_pion.c` (`apps/mbui/src/host/core_api.h`).

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "core_api.h"

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
extern int32_t pion_core_runtime_screen_ack(double call, double ts);
extern int32_t pion_core_runtime_screen_input(double call, const uint8_t *json, int64_t len);

static pthread_once_t g_pion_consts_once = PTHREAD_ONCE_INIT;

static void init_pion_consts_once(void) {
    pion_pkg_core_runtime_init_consts();
}

// Driver registration ABI from `packages/core_abi/native/core_pion.c`
typedef void (*mb_core_driver_start_fn)(const char *, const char *, int, void *);
typedef void (*mb_core_driver_send_fn)(const char *, size_t, const uint8_t *, size_t, void *);
typedef void (*mb_core_driver_stop_fn)(void *);
typedef int (*mb_core_driver_screen_ack_fn)(double, double, void *);
typedef int (*mb_core_driver_screen_input_fn)(double, const uint8_t *, size_t, void *);

typedef struct mb_core_driver {
    mb_core_driver_start_fn on_start;
    mb_core_driver_send_fn on_send;
    mb_core_driver_stop_fn on_stop;
    mb_core_driver_screen_ack_fn on_screen_ack;
    mb_core_driver_screen_input_fn on_screen_input;
    void *user_ctx;
} mb_core_driver_t;

extern void mb_core_register_driver(const mb_core_driver_t *driver);

static void bridge_on_start(const char *data_dir, const char *cloud_origin, int beta, void *user_ctx) {
    (void)user_ctx;
    (void)pthread_once(&g_pion_consts_once, init_pion_consts_once);
    int64_t dlen = data_dir != NULL ? (int64_t)strlen(data_dir) : 0;
    int64_t clen = cloud_origin != NULL ? (int64_t)strlen(cloud_origin) : 0;
    (void)pion_core_runtime_start(data_dir, dlen, cloud_origin, clen, (int32_t)beta);
}

static void bridge_on_send(const char *json, size_t len, const uint8_t *bytes, size_t blen, void *user_ctx) {
    (void)user_ctx;
    pion_core_runtime_send(json, (int64_t)len, bytes, (int64_t)blen);
}

static void bridge_on_stop(void *user_ctx) {
    (void)user_ctx;
    pion_core_runtime_stop();
}

static int bridge_on_screen_ack(double call, double ts, void *user_ctx) {
    (void)user_ctx;
    return (int)pion_core_runtime_screen_ack(call, ts);
}

static int bridge_on_screen_input(double call, const uint8_t *json, size_t len, void *user_ctx) {
    (void)user_ctx;
    return (int)pion_core_runtime_screen_input(call, json, (int64_t)len);
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
}
