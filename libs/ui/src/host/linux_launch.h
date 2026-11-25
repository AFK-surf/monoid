// Platform-independent Linux URI launch precheck, portal detection, script guard, login dispatch,
// and secret-safe error formatting. Included by linux_app.c and linux_browser_login.c, and compiled
// standalone in scripts/linux_launch_test.c without GTK/GLib dependencies.
#pragma once

#include <stddef.h>
#include <stdio.h>
#include <string.h>

typedef int (*mb_linux_file_exists_fn)(const char *path);
typedef const char *(*mb_linux_getenv_fn)(const char *name);
typedef int (*mb_linux_has_handler_fn)(const char *scheme);
typedef int (*mb_linux_spawn_browser_fn)(const char *browser, const char *url, void *ctx);
typedef int (*mb_linux_launch_system_fn)(const char *url, void *ctx);

// Matches GLib gportalsupport.c: Flatpak (/.flatpak-info), non-empty SNAP, or GIO_USE_PORTALS=1.
static inline int mb_linux_uses_portal(mb_linux_file_exists_fn file_exists_fn, mb_linux_getenv_fn getenv_fn) {
  if (file_exists_fn && file_exists_fn("/.flatpak-info")) return 1;
  if (getenv_fn) {
    const char *snap = getenv_fn("SNAP");
    if (snap && snap[0] != '\0') return 1;
    const char *portals = getenv_fn("GIO_USE_PORTALS");
    if (portals && strcmp(portals, "1") == 0) return 1;
  }
  return 0;
}

static inline int mb_linux_can_launch_uri(const char *scheme, mb_linux_has_handler_fn has_handler_fn,
                                          mb_linux_file_exists_fn file_exists_fn, mb_linux_getenv_fn getenv_fn) {
  if (mb_linux_uses_portal(file_exists_fn, getenv_fn)) return 1;
  if (!scheme || !scheme[0]) return 0;
  return (has_handler_fn && has_handler_fn(scheme)) ? 1 : 0;
}

static inline int mb_linux_scripted(mb_linux_getenv_fn getenv_fn) {
  if (!getenv_fn) return 0;
  return (getenv_fn("MBUI_SCRIPT") || getenv_fn("MBUI_DRIVE") || getenv_fn("MBUI_DRIVE_B64")) ? 1 : 0;
}

// Formats a launch error with action, GError domain, and numeric code only (never GError.message,
// which may echo sensitive OAuth URLs or tokens from D-Bus handlers).
static inline void mb_linux_format_launch_error(char *buf, size_t cap, const char *action, const char *domain,
                                                int code) {
  if (!buf || cap == 0) return;
  const char *a = (action && action[0]) ? action : "launch";
  const char *d = (domain && domain[0]) ? domain : "unknown";
  snprintf(buf, cap, "%s failed (%s:%d)\n", a, d, code);
}

// Browser login dispatch: $BROWSER always takes precedence (including in scripted runs like e2e);
// otherwise scripted runs succeed without launching a browser, and normal runs precheck handler/portal
// availability before submitting an async system launch.
static inline int mb_linux_dispatch_browser_login(const char *url, const char *scheme, mb_linux_getenv_fn getenv_fn,
                                                  mb_linux_file_exists_fn file_exists_fn,
                                                  mb_linux_has_handler_fn has_handler_fn,
                                                  mb_linux_spawn_browser_fn spawn_browser_fn,
                                                  mb_linux_launch_system_fn launch_system_fn, void *ctx) {
  const char *browser = getenv_fn ? getenv_fn("BROWSER") : NULL;
  if (browser && browser[0]) {
    return (spawn_browser_fn && spawn_browser_fn(browser, url, ctx)) ? 1 : 0;
  }
  if (mb_linux_scripted(getenv_fn)) {
    return 1;
  }
  if (!mb_linux_can_launch_uri(scheme, has_handler_fn, file_exists_fn, getenv_fn)) {
    return 0;
  }
  return (launch_system_fn && launch_system_fn(url, ctx)) ? 1 : 0;
}
