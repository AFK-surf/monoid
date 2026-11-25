// Deterministic C99 unit tests for Linux URI launch precheck, portal detection, browser login
// dispatch guards, and secret-safe error formatting (src/host/linux_launch.h).
// Build & run on Linux/macOS:
//   cc -Wall -Wextra -Werror -I libs/ui/src/host libs/ui/scripts/linux_launch_test.c -o linux_launch_test && ./linux_launch_test

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "linux_launch.h"

static int g_failed = 0;

#define CHECK(cond)                                                            \
  do {                                                                         \
    if (!(cond)) {                                                             \
      fprintf(stderr, "%s:%d: FAILED: %s\n", __FILE__, __LINE__, #cond);       \
      g_failed = 1;                                                            \
    }                                                                          \
  } while (0)

typedef struct {
  int flatpak_info;
  const char *snap;
  const char *gio_use_portals;
  const char *browser;
  const char *mbui_script;
  const char *mbui_drive;
  const char *mbui_drive_b64;
  int has_handler;
  int handler_queries;
  int browser_spawns;
  int system_launches;
} FakeEnv;

static FakeEnv g_env;

static void reset_env(void) { memset(&g_env, 0, sizeof g_env); }

static int fake_file_exists(const char *path) {
  if (strcmp(path, "/.flatpak-info") == 0) return g_env.flatpak_info;
  return 0;
}

static const char *fake_getenv(const char *name) {
  if (strcmp(name, "SNAP") == 0) return g_env.snap;
  if (strcmp(name, "GIO_USE_PORTALS") == 0) return g_env.gio_use_portals;
  if (strcmp(name, "BROWSER") == 0) return g_env.browser;
  if (strcmp(name, "MBUI_SCRIPT") == 0) return g_env.mbui_script;
  if (strcmp(name, "MBUI_DRIVE") == 0) return g_env.mbui_drive;
  if (strcmp(name, "MBUI_DRIVE_B64") == 0) return g_env.mbui_drive_b64;
  return NULL;
}

static int fake_has_handler(const char *scheme) {
  (void)scheme;
  g_env.handler_queries++;
  return g_env.has_handler;
}

static int fake_spawn_browser(const char *browser, const char *url, void *ctx) {
  (void)browser;
  (void)url;
  (void)ctx;
  g_env.browser_spawns++;
  return 1;
}

static int fake_launch_system(const char *url, void *ctx) {
  (void)url;
  (void)ctx;
  g_env.system_launches++;
  return 1;
}

// 1. Plain desktop without local handler returns 0 and submits 0 launches.
static void test_no_handler_desktop(void) {
  reset_env();
  CHECK(!mb_linux_uses_portal(fake_file_exists, fake_getenv));
  CHECK(!mb_linux_can_launch_uri("https", fake_has_handler, fake_file_exists, fake_getenv));
  CHECK(g_env.handler_queries == 1);

  int ok = mb_linux_dispatch_browser_login("https://auth.example/login", "https", fake_getenv, fake_file_exists,
                                           fake_has_handler, fake_spawn_browser, fake_launch_system, NULL);
  CHECK(ok == 0);
  CHECK(g_env.browser_spawns == 0);
  CHECK(g_env.system_launches == 0);

  // Empty or NULL scheme on non-portal desktop returns 0 without querying handler.
  g_env.has_handler = 1;
  g_env.handler_queries = 0;
  CHECK(!mb_linux_can_launch_uri(NULL, fake_has_handler, fake_file_exists, fake_getenv));
  CHECK(!mb_linux_can_launch_uri("", fake_has_handler, fake_file_exists, fake_getenv));
  CHECK(g_env.handler_queries == 0);
}

// 2. No local handler + GIO_USE_PORTALS=1 allows 1 launch.
static void test_gio_use_portals(void) {
  reset_env();
  g_env.gio_use_portals = "1";
  CHECK(mb_linux_uses_portal(fake_file_exists, fake_getenv));
  CHECK(mb_linux_can_launch_uri("https", fake_has_handler, fake_file_exists, fake_getenv));
  CHECK(g_env.handler_queries == 0);

  int ok = mb_linux_dispatch_browser_login("https://auth.example/login", "https", fake_getenv, fake_file_exists,
                                           fake_has_handler, fake_spawn_browser, fake_launch_system, NULL);
  CHECK(ok == 1);
  CHECK(g_env.browser_spawns == 0);
  CHECK(g_env.system_launches == 1);

  // GIO_USE_PORTALS=0 or other value is not treated as portal mode.
  reset_env();
  g_env.gio_use_portals = "0";
  CHECK(!mb_linux_uses_portal(fake_file_exists, fake_getenv));
  CHECK(!mb_linux_can_launch_uri("https", fake_has_handler, fake_file_exists, fake_getenv));
}

// 3. Flatpak (/.flatpak-info) or non-empty SNAP enables portal mode; empty SNAP="" stays non-sandbox.
static void test_flatpak_and_snap(void) {
  reset_env();
  g_env.flatpak_info = 1;
  CHECK(mb_linux_uses_portal(fake_file_exists, fake_getenv));
  CHECK(mb_linux_can_launch_uri("https", fake_has_handler, fake_file_exists, fake_getenv));
  CHECK(g_env.handler_queries == 0);

  reset_env();
  g_env.snap = "/snap/monoid/1";
  CHECK(mb_linux_uses_portal(fake_file_exists, fake_getenv));
  CHECK(mb_linux_can_launch_uri("https", fake_has_handler, fake_file_exists, fake_getenv));
  CHECK(g_env.handler_queries == 0);

  reset_env();
  g_env.snap = "";
  CHECK(!mb_linux_uses_portal(fake_file_exists, fake_getenv));
  CHECK(!mb_linux_can_launch_uri("https", fake_has_handler, fake_file_exists, fake_getenv));
  CHECK(g_env.handler_queries == 1);
}

// 4. Browser login dispatch guard matrix.
static void test_login_dispatch_guard_matrix(void) {
  // BROWSER + MBUI_DRIVE_B64: BROWSER runs once, system launcher runs 0 times.
  reset_env();
  g_env.browser = "/usr/bin/fake-browser";
  g_env.mbui_drive_b64 = "1";
  int ok = mb_linux_dispatch_browser_login("https://auth.example/login", "https", fake_getenv, fake_file_exists,
                                           fake_has_handler, fake_spawn_browser, fake_launch_system, NULL);
  CHECK(ok == 1);
  CHECK(g_env.browser_spawns == 1);
  CHECK(g_env.system_launches == 0);

  // No BROWSER + any scripted env var: returns 1 without launching system browser.
  const char *vars[3] = {"MBUI_SCRIPT", "MBUI_DRIVE", "MBUI_DRIVE_B64"};
  for (int i = 0; i < 3; i++) {
    reset_env();
    g_env.has_handler = 1;
    if (i == 0) g_env.mbui_script = "1";
    else if (i == 1) g_env.mbui_drive = "1";
    else g_env.mbui_drive_b64 = "1";
    (void)vars[i];
    ok = mb_linux_dispatch_browser_login("https://auth.example/login", "https", fake_getenv, fake_file_exists,
                                         fake_has_handler, fake_spawn_browser, fake_launch_system, NULL);
    CHECK(ok == 1);
    CHECK(g_env.browser_spawns == 0);
    CHECK(g_env.system_launches == 0);
    CHECK(g_env.handler_queries == 0);
  }

  // Normal desktop with handler: system launcher runs once.
  reset_env();
  g_env.has_handler = 1;
  ok = mb_linux_dispatch_browser_login("https://auth.example/login", "https", fake_getenv, fake_file_exists,
                                       fake_has_handler, fake_spawn_browser, fake_launch_system, NULL);
  CHECK(ok == 1);
  CHECK(g_env.browser_spawns == 0);
  CHECK(g_env.system_launches == 1);
}

// 5. Error formatting excludes sensitive OAuth URLs/tokens from error messages.
static void test_error_formatting_no_secret_leak(void) {
  const char *fake_gerror_message = "Failed to open https://auth.example/cb?code=SECRET_OAUTH_TOKEN";
  (void)fake_gerror_message;  // Intentionally never passed to mb_linux_format_launch_error.
  char buf[160] = {0};
  mb_linux_format_launch_error(buf, sizeof buf, "browser login open", "g-io-error-quark", 15);
  CHECK(strcmp(buf, "browser login open failed (g-io-error-quark:15)\n") == 0);
  CHECK(strstr(buf, "SECRET_OAUTH_TOKEN") == NULL);

  mb_linux_format_launch_error(buf, sizeof buf, "open-url", NULL, 0);
  CHECK(strcmp(buf, "open-url failed (unknown:0)\n") == 0);
}

int main(void) {
  test_no_handler_desktop();
  test_gio_use_portals();
  test_flatpak_and_snap();
  test_login_dispatch_guard_matrix();
  test_error_formatting_no_secret_leak();

  if (!g_failed) {
    printf("linux_launch_test: ok\n");
  }
  return g_failed;
}
