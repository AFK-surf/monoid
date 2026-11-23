// Cross-platform headless smoke and startup/memory probe for the Pion client core
// over `apps/mbui/src/host/core_api.h` (`mb_core_start` -> `mb_core_send` ->
// `on_message` -> `mb_core_stop`). Built and run by `apps/mbui/scripts/pion-core.sh smoke`.
//
// Usage: pion_smoke_test <data_dir> [cloud_origin]
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#include <mach/mach.h>
#endif

#include "core_api.h"

extern void mb_core_attach_pion_runtime(void);

typedef struct smoke_state {
  pthread_mutex_t mu;
  pthread_cond_t cv;
  double t0;
  double first_message_ms;
  double accounts_ms;
  double lock_ms;
  double settings_set_ms;
  double settings_get_ms;
  int accounts_ok;
  int lock_ok;
  int settings_set_ok;
  int settings_get_ok;
  int failed;
  _Atomic int stopped;
  _Atomic int post_stop_messages;
} smoke_state_t;

static double now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec * 1000.0 + (double)t.tv_nsec / 1e6;
}

static double memory_mb(void) {
#ifdef __APPLE__
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
    return -1.0;
  }
  return (double)info.phys_footprint / 1048576.0;
#else
  FILE *f = fopen("/proc/self/statm", "r");
  if (!f) {
    return -1.0;
  }
  unsigned long size_pages = 0;
  unsigned long rss_pages = 0;
  int n = fscanf(f, "%lu %lu", &size_pages, &rss_pages);
  fclose(f);
  if (n != 2) {
    return -1.0;
  }
  long page_size = sysconf(_SC_PAGESIZE);
  if (page_size <= 0) {
    page_size = 4096;
  }
  return ((double)rss_pages * (double)page_size) / 1048576.0;
#endif
}

static void sleep_ms(double ms) {
  if (ms <= 0.0) {
    return;
  }
  struct timespec req;
  req.tv_sec = (time_t)(ms / 1000.0);
  double rem_ms = ms - (double)req.tv_sec * 1000.0;
  req.tv_nsec = (long)(rem_ms * 1e6);
  while (nanosleep(&req, &req) == -1 && errno == EINTR) {
  }
}

static void on_message(const char *json, size_t len, const uint8_t *bytes, size_t blen, void *ctx) {
  smoke_state_t *s = (smoke_state_t *)ctx;
  if (atomic_load(&s->stopped)) {
    atomic_fetch_add(&s->post_stop_messages, 1);
    return;
  }
  double at = now_ms() - s->t0;

  char *copy = (char *)malloc(len + 1);
  if (!copy) {
    abort();
  }
  if (len > 0 && json) {
    memcpy(copy, json, len);
  }
  copy[len] = '\0';

  printf("[%8.2f ms] <- %.*s%s", at, (int)(len > 300 ? 300 : len), copy, len > 300 ? "..." : "");
  if (bytes && blen > 0) {
    printf(" (+%zu bytes)", blen);
  }
  printf("\n");
  fflush(stdout);

  pthread_mutex_lock(&s->mu);
  if (s->first_message_ms < 0.0) {
    s->first_message_ms = at;
  }
  if (strstr(copy, "\"fatal\"") != NULL) {
    s->failed = 1;
  } else if (strstr(copy, "\"id\":1") != NULL && s->accounts_ms < 0.0) {
    s->accounts_ms = at;
    s->accounts_ok = strstr(copy, "\"value\"") != NULL;
  } else if (strstr(copy, "\"id\":2") != NULL && s->lock_ms < 0.0) {
    s->lock_ms = at;
    s->lock_ok = strstr(copy, "\"value\"") != NULL;
  } else if (strstr(copy, "\"id\":3") != NULL && s->settings_set_ms < 0.0) {
    s->settings_set_ms = at;
    s->settings_set_ok = strstr(copy, "\"saved\":true") != NULL;
  } else if (strstr(copy, "\"id\":4") != NULL && s->settings_get_ms < 0.0) {
    s->settings_get_ms = at;
    s->settings_get_ok = strstr(copy, "\"value\":\"dark\"") != NULL;
  }
  pthread_cond_broadcast(&s->cv);
  pthread_mutex_unlock(&s->mu);
  free(copy);
}

static void send_json(double t0, const char *json) {
  printf("[%8.2f ms] -> %s\n", now_ms() - t0, json);
  fflush(stdout);
  mb_core_send(json, strlen(json), NULL, 0);
}

static int wait_all_replies(smoke_state_t *s, int timeout_sec) {
  struct timespec dl;
  clock_gettime(CLOCK_REALTIME, &dl);
  dl.tv_sec += timeout_sec;

  pthread_mutex_lock(&s->mu);
  while (!s->failed &&
         (s->accounts_ms < 0.0 || s->lock_ms < 0.0 || s->settings_set_ms < 0.0 || s->settings_get_ms < 0.0)) {
    int rc = pthread_cond_timedwait(&s->cv, &s->mu, &dl);
    if (rc == ETIMEDOUT) {
      pthread_mutex_unlock(&s->mu);
      return 0;
    }
  }
  int done = !s->failed;
  pthread_mutex_unlock(&s->mu);
  return done;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: pion_smoke_test <data_dir> [cloud_origin]\n");
    return 2;
  }
  const char *data_dir = argv[1];
  const char *cloud_origin = argc > 2 ? argv[2] : "http://127.0.0.1:9";
  const char *linger_env = getenv("MB_SMOKE_LINGER_MS");
  double linger_ms = (linger_env && *linger_env) ? atof(linger_env) : 500.0;

  smoke_state_t st;
  memset(&st, 0, sizeof(st));
  pthread_mutex_init(&st.mu, NULL);
  pthread_cond_init(&st.cv, NULL);
  st.first_message_ms = -1.0;
  st.accounts_ms = -1.0;
  st.lock_ms = -1.0;
  st.settings_set_ms = -1.0;
  st.settings_get_ms = -1.0;

  mb_core_attach_pion_runtime();

  double rss_before_mb = memory_mb();
  st.t0 = now_ms();
  mb_core_start(data_dir, cloud_origin, 0, on_message, &st);
  printf("[%8.2f ms] core thread up (data %s, cloud %s)\n", now_ms() - st.t0, data_dir, cloud_origin);
  fflush(stdout);

  send_json(st.t0, "{\"id\":1,\"subscribe\":{\"topic\":\"accounts\"}}");
  send_json(st.t0, "{\"id\":2,\"subscribe\":{\"topic\":\"lock\",\"workspace\":\"ws-default\"}}");
  send_json(st.t0, "{\"id\":3,\"call\":\"settings.set\",\"params\":{\"key\":\"smoke.theme\",\"value\":\"dark\"}}");
  send_json(st.t0, "{\"id\":4,\"call\":\"settings.get\",\"params\":{\"key\":\"smoke.theme\"}}");

  int replies_ok = wait_all_replies(&st, 15);
  sleep_ms(linger_ms);
  double rss_running_mb = memory_mb();

  double t_stop = now_ms();
  mb_core_stop();
  atomic_store(&st.stopped, 1);
  double stop_ms = now_ms() - t_stop;

  // Verify no callbacks arrive after mb_core_stop returns.
  mb_core_send("{\"id\":99,\"call\":\"settings.get\",\"params\":{\"key\":\"smoke.theme\"}}", 68, NULL, 0);
  sleep_ms(20.0);
  double rss_after_stop_mb = memory_mb();
  int post_stop = atomic_load(&st.post_stop_messages);

  int ok = replies_ok && !st.failed && st.accounts_ok && st.lock_ok &&
           st.settings_set_ok && st.settings_get_ok && post_stop == 0;

  printf("\n== pion_smoke ==\n");
#ifdef __APPLE__
  printf("mem_metric          phys_footprint\n");
#else
  printf("mem_metric          rss\n");
#endif
  printf("first_message_ms    %.2f\n", st.first_message_ms);
  printf("accounts_ms         %.2f (%s)\n", st.accounts_ms, st.accounts_ok ? "ok" : "FAIL");
  printf("lock_ms             %.2f (%s)\n", st.lock_ms, st.lock_ok ? "ok" : "FAIL");
  printf("settings_set_ms     %.2f (%s)\n", st.settings_set_ms, st.settings_set_ok ? "ok" : "FAIL");
  printf("settings_get_ms     %.2f (%s)\n", st.settings_get_ms, st.settings_get_ok ? "ok" : "FAIL");
  printf("stop_ms             %.2f\n", stop_ms);
  printf("rss_before_mb       %.2f\n", rss_before_mb);
  printf("rss_running_mb      %.2f\n", rss_running_mb);
  printf("rss_after_stop_mb   %.2f\n", rss_after_stop_mb);
  printf("post_stop_messages  %d\n", post_stop);
  printf("result              %s\n", ok ? "OK" : "FAILED");
  fflush(stdout);

  pthread_cond_destroy(&st.cv);
  pthread_mutex_destroy(&st.mu);
  return ok ? 0 : 1;
}
