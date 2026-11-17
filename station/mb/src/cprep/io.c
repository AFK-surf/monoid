// cprep's needs from the system: a file read and one written whole, as bytes (paths as UTF-8 bytes).
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"

static char *cprep_path(moonbit_bytes_t p) {
  int32_t n = Moonbit_array_length(p);
  char *s = malloc((size_t)n + 1);
  memcpy(s, p, (size_t)n);
  s[n] = 0;
  return s;
}

static int32_t cprep_ok;

// the file's bytes (empty, cprep_read_ok 0, when it cannot be read)
moonbit_bytes_t cprep_read_file(moonbit_bytes_t path) {
  char *p = cprep_path(path);
  FILE *f = fopen(p, "rb");
  free(p);
  cprep_ok = 0;
  if (!f) return moonbit_make_bytes(0, 0);
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (n < 0 || n > INT32_MAX) {
    fclose(f);
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  size_t got = fread(out, 1, (size_t)n, f);
  fclose(f);
  if ((long)got != n) return moonbit_make_bytes(0, 0);
  cprep_ok = 1;
  return out;
}

int32_t cprep_read_ok(void) { return cprep_ok; }

// 1 once all of data is written
int32_t cprep_write_file(moonbit_bytes_t path, moonbit_bytes_t data) {
  char *p = cprep_path(path);
  FILE *f = fopen(p, "wb");
  free(p);
  if (!f) return 0;
  size_t n = (size_t)Moonbit_array_length(data);
  size_t put = fwrite(data, 1, n, f);
  int closed = fclose(f);
  return put == n && closed == 0;
}
