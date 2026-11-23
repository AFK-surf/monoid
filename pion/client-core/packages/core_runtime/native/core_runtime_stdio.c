// Minimal stdio JSONL host driver for `apps/mbui/src/host/core_api.h` linking
// real Pion `packages/core_runtime` + real Rust `libstillfail_shell`.
// Used by `pion/client-core/test/sfreplay-core-traces.test.mjs` to replay real
// `apps/mbui/e2e/traces/*.trace` flows through the compiled native engine.

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core_api.h"

extern void mb_core_attach_pion_runtime(void);

static pthread_mutex_t g_out_mu = PTHREAD_MUTEX_INITIALIZER;

static void on_host_message(
    const char *json,
    size_t len,
    const uint8_t *bytes,
    size_t blen,
    void *ctx) {
    (void)bytes;
    (void)blen;
    (void)ctx;
    pthread_mutex_lock(&g_out_mu);
    fwrite(json, 1, len, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    pthread_mutex_unlock(&g_out_mu);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <data_dir> <cloud_origin>\n", argv[0]);
        return 2;
    }
    mb_core_attach_pion_runtime();
    mb_core_start(argv[1], argv[2], 1, on_host_message, NULL);

    char *line = NULL;
    size_t cap = 0;
    ssize_t nread;
    while ((nread = getline(&line, &cap, stdin)) >= 0) {
        while (nread > 0 && (line[nread - 1] == '\n' || line[nread - 1] == '\r')) {
            nread--;
        }
        if (nread == 0) {
            continue;
        }
        line[nread] = '\0';
        mb_core_send(line, (size_t)nread, NULL, 0);
    }

    free(line);
    mb_core_stop();
    return 0;
}
