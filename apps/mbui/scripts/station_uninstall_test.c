// src/host/station_uninstall.h's tests: what Windows' host (and the app's uninstaller) runs to take this machine's
// station away is bin/stillfail.ps1's `uninstall`, word for word, given the data's path as a value, whatever it holds:
//   cc -Wall -I src/host scripts/station_uninstall_test.c -o out/station_uninstall_test && out/station_uninstall_test
// (run in apps/mbui: it reads ../../bin/stillfail.ps1). `station_uninstall_test command <data>` says the command line
// alone (scripts/station_uninstall_win.sh runs it on Windows).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "station_uninstall.h"

static int failed;

#define CHECK(c)                                                      \
  do {                                                                \
    if (!(c)) {                                                       \
      fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #c); \
      failed = 1;                                                     \
    }                                                                 \
  } while (0)

// the command's script, back: base64 to UTF-16LE to UTF-8 (malloc'd)
static char *script_of(const char *command) {
  const char *b = strstr(command, "-EncodedCommand ");
  if (!b) return NULL;
  b += strlen("-EncodedCommand ");
  size_t n = strlen(b), un = 0;
  unsigned char *u = malloc(n);
  unsigned int v = 0;
  int bits = 0;
  for (size_t i = 0; i < n && b[i] != '='; i++) {
    // (one array: two equal literals need not be one object, as MSVC's are not)
    static const char digits[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const char *at = strchr(digits, b[i]);
    if (!at) return NULL;
    v = (v << 6) | (unsigned int)(at - digits);
    bits += 6;
    if (bits >= 8) bits -= 8, u[un++] = (unsigned char)(v >> bits);
  }
  char *out = malloc(un * 2 + 1), *o = out;
  for (size_t i = 0; i + 1 < un; i += 2) {
    unsigned int c = u[i] | u[i + 1] << 8;
    if (c >= 0xD800 && c < 0xDC00 && i + 3 < un) {
      c = 0x10000 + ((c - 0xD800) << 10) + ((u[i + 2] | u[i + 3] << 8) - 0xDC00);
      i += 2;
    }
    if (c < 0x80) *o++ = (char)c;
    else if (c < 0x800) *o++ = (char)(0xC0 | c >> 6), *o++ = (char)(0x80 | (c & 63));
    else if (c < 0x10000) *o++ = (char)(0xE0 | c >> 12), *o++ = (char)(0x80 | (c >> 6 & 63)), *o++ = (char)(0x80 | (c & 63));
    else *o++ = (char)(0xF0 | c >> 18), *o++ = (char)(0x80 | (c >> 12 & 63)), *o++ = (char)(0x80 | (c >> 6 & 63)), *o++ = (char)(0x80 | (c & 63));
  }
  *o = 0;
  free(u);
  return out;
}

int main(int argc, char **argv) {
  if (argc == 3 && !strcmp(argv[1], "command")) {
    char *c = station_uninstall_command(argv[2]);
    if (!c) return 1;
    puts(c);
    free(c);
    return 0;
  }
  // the same as bin/stillfail.ps1's function, line for line (its line ends as they are there)
  FILE *f = fopen("../../bin/stillfail.ps1", "rb");
  CHECK(f != NULL);
  if (f) {
    static char ps1[1 << 16];
    size_t n = fread(ps1, 1, sizeof ps1 - 1, f);
    fclose(f);
    ps1[n] = 0;
    char *from = strstr(ps1, "function Uninstall(");
    char *to = from ? strstr(from, "\n}\n") : NULL;
    CHECK(from && to);
    if (from && to) {
      to[3] = 0;
      if (strcmp(from, station_uninstall_ps)) {
        fprintf(stderr, "station_uninstall.h: station_uninstall_ps is not bin/stillfail.ps1's function Uninstall as it is now\n");
        failed = 1;
      }
    }
  }
  // the path a value: quoted for PowerShell (a ' doubled), the rest as it is, the function, then its call
  const char *data = "C:\\Users\\张 O'Neil 🙂\\.stillfail";
  char *c = station_uninstall_command(data);
  CHECK(c && !strncmp(c, "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ", 90));
  // (nothing of the path in the command line itself)
  CHECK(c && !strstr(c, "Neil") && !strchr(c + 90, ' ') && !strchr(c, '\''));
  char *s = c ? script_of(c) : NULL;
  const char *head = "$data = 'C:\\Users\\张 O''Neil 🙂\\.stillfail'\n";
  CHECK(s && !strncmp(s, head, strlen(head)));
  CHECK(s && !strncmp(s + strlen(head), station_uninstall_ps, strlen(station_uninstall_ps)));
  CHECK(s && !strcmp(s + strlen(head) + strlen(station_uninstall_ps), "Uninstall $false\n"));
  free(s);
  free(c);
  CHECK(station_uninstall_command("") == NULL && station_uninstall_command(NULL) == NULL);
  if (!failed) puts("station_uninstall: bin/stillfail.ps1's uninstall, its data a value");
  return failed;
}
