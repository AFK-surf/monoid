// What P5-4's parts ask of the system beyond the shell (client/shell) and sys.c: a TCP connection to any address (a
// device on the station's network, the vault proxy's tunnel to a host it opens nothing of), a serial port (a device
// attached by its cable), and one line asked of still.fail Helper on its socket at once (the folders macOS protects,
// the drive's `Protected`). A connection's and a port's bytes are read by a thread of their own and told on the
// program's queue (host.c `sfh_push_sys`): `c` connected, `d` data, `e` its end, `f` why it failed; writes go through
// a bounded per-connection queue drained by a writer thread so the MoonBit event loop never blocks on send/write.
// Nothing here calls into MoonBit. Paths and hosts are UTF-8, ended by a NUL. POSIX and Win32 both.
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"

void sfh_push_sys(uint64_t id, const uint8_t *a, size_t al);

static void io_told(int64_t id, char tag, const void *data, size_t len) {
  uint8_t *msg = malloc(len + 1);
  if (msg == NULL) return;
  msg[0] = (uint8_t)tag;
  if (len) memcpy(msg + 1, data, len);
  sfh_push_sys((uint64_t)id, msg, len + 1);
  free(msg);
}

#define IO_SLOTS 1024
#define IO_WRITE_MAX (8u * 1024u * 1024u)
#define IO_CONNECT_TIMEOUT_MS 15000
#define IO_SNDTIMEO_SEC 30

typedef struct io_chunk {
  struct io_chunk *next;
  size_t len;
  uint8_t data[];
} io_chunk_t;

static void io_free_chunks(io_chunk_t *head) {
  while (head != NULL) {
    io_chunk_t *next = head->next;
    free(head);
    head = next;
  }
}

#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

typedef struct {
  int ref; // protected by io_lock
  int64_t id;
  int slot;
  int serial;
  SOCKET sock;
  HANDLE port;
  CRITICAL_SECTION lock;
  CONDITION_VARIABLE wcond;
  int ready;
  int closed;
  int write_failed;
  int end_queued;
  int end_done;
  int writer_started;
  io_chunk_t *whead;
  io_chunk_t *wtail;
  size_t wqueued;
} io_conn_t;

static io_conn_t *io_slots[IO_SLOTS];
static CRITICAL_SECTION io_lock;
static INIT_ONCE io_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK io_init(PINIT_ONCE once, PVOID param, PVOID *ctx) {
  (void)once;
  (void)param;
  (void)ctx;
  WSADATA wsa;
  WSAStartup(MAKEWORD(2, 2), &wsa);
  InitializeCriticalSection(&io_lock);
  return TRUE;
}

static void io_start(void) { InitOnceExecuteOnce(&io_once, io_init, NULL, NULL); }

static io_conn_t *io_conn_new(int64_t id, int slot) {
  io_conn_t *c = calloc(1, sizeof *c);
  if (c == NULL) return NULL;
  c->ref = 2; // 1 for io_slots[slot], 1 for caller/worker
  c->id = id;
  c->slot = slot;
  c->sock = INVALID_SOCKET;
  c->port = INVALID_HANDLE_VALUE;
  InitializeCriticalSection(&c->lock);
  InitializeConditionVariable(&c->wcond);
  return c;
}

static void io_conn_ref(io_conn_t *c) {
  EnterCriticalSection(&io_lock);
  c->ref++;
  LeaveCriticalSection(&io_lock);
}

static void io_conn_unref(io_conn_t *c) {
  EnterCriticalSection(&io_lock);
  int last = (--c->ref == 0);
  LeaveCriticalSection(&io_lock);
  if (!last) return;
  io_free_chunks(c->whead);
  if (c->port != INVALID_HANDLE_VALUE) CloseHandle(c->port);
  if (c->sock != INVALID_SOCKET) closesocket(c->sock);
  DeleteCriticalSection(&c->lock);
  free(c);
}

static int io_take(int64_t id, io_conn_t **out) {
  io_start();
  EnterCriticalSection(&io_lock);
  int found = -1;
  for (int i = 1; i < IO_SLOTS; i++) {
    if (io_slots[i] == NULL) {
      io_conn_t *c = io_conn_new(id, i);
      if (c != NULL) {
        io_slots[i] = c;
        *out = c;
        found = i;
      }
      break;
    }
  }
  LeaveCriticalSection(&io_lock);
  return found;
}

static io_conn_t *io_slot_get(int slot) {
  if (slot <= 0 || slot >= IO_SLOTS) return NULL;
  io_start();
  EnterCriticalSection(&io_lock);
  io_conn_t *c = io_slots[slot];
  if (c != NULL) c->ref++;
  LeaveCriticalSection(&io_lock);
  return c;
}

static int io_slot_clear_if(io_conn_t *c) {
  EnterCriticalSection(&io_lock);
  int had = 0;
  if (c->slot > 0 && c->slot < IO_SLOTS && io_slots[c->slot] == c) {
    io_slots[c->slot] = NULL;
    had = 1;
  }
  LeaveCriticalSection(&io_lock);
  return had;
}

static void io_error_text(DWORD code, char *buf, size_t size) {
  wchar_t w[256];
  DWORD n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code, 0, w, 256, NULL);
  if (n == 0) {
    snprintf(buf, size, "error %lu", (unsigned long)code);
    return;
  }
  while (n > 0 && (w[n - 1] == L'\r' || w[n - 1] == L'\n' || w[n - 1] == L'.')) w[--n] = 0;
  WideCharToMultiByte(CP_UTF8, 0, w, -1, buf, (int)size, NULL, NULL);
}

static DWORD WINAPI io_write_thread(LPVOID arg) {
  io_conn_t *c = arg;
  for (;;) {
    EnterCriticalSection(&c->lock);
    while (!c->closed && !c->write_failed && c->whead == NULL && !c->end_queued) {
      SleepConditionVariableCS(&c->wcond, &c->lock, INFINITE);
    }
    if (c->closed || c->write_failed) {
      io_chunk_t *drop = c->whead;
      c->whead = c->wtail = NULL;
      c->wqueued = 0;
      LeaveCriticalSection(&c->lock);
      io_free_chunks(drop);
      break;
    }
    if (c->whead != NULL) {
      io_chunk_t *ch = c->whead;
      c->whead = ch->next;
      if (c->whead == NULL) c->wtail = NULL;
      c->wqueued -= ch->len;
      int serial = c->serial;
      SOCKET sock = c->sock;
      HANDLE port = c->port;
      LeaveCriticalSection(&c->lock);

      size_t done = 0;
      int ok = 1;
      while (done < ch->len) {
        if (serial) {
          DWORD n = 0;
          if (!WriteFile(port, (const char *)ch->data + done, (DWORD)(ch->len - done), &n, NULL) || n == 0) {
            ok = 0;
            break;
          }
          done += (size_t)n;
        } else {
          int n = send(sock, (const char *)ch->data + done, (int)(ch->len - done), 0);
          if (n <= 0) {
            ok = 0;
            break;
          }
          done += (size_t)n;
        }
      }
      free(ch);
      if (!ok) {
        EnterCriticalSection(&c->lock);
        c->write_failed = 1;
        io_chunk_t *drop = c->whead;
        c->whead = c->wtail = NULL;
        c->wqueued = 0;
        int do_sd = (!c->closed && !c->serial && c->sock != INVALID_SOCKET);
        SOCKET sd_sock = c->sock;
        LeaveCriticalSection(&c->lock);
        io_free_chunks(drop);
        if (do_sd) shutdown(sd_sock, SD_BOTH);
        break;
      }
      continue;
    }
    if (c->end_queued) {
      int do_sd = (!c->end_done && !c->serial && c->sock != INVALID_SOCKET);
      SOCKET sd_sock = c->sock;
      c->end_done = 1;
      LeaveCriticalSection(&c->lock);
      if (do_sd) shutdown(sd_sock, SD_SEND);
      break;
    }
    LeaveCriticalSection(&c->lock);
  }
  io_conn_unref(c);
  return 0;
}

typedef struct {
  io_conn_t *conn;
  char *host;
  int port;
} io_connect_t;

static int io_is_closed(io_conn_t *c) {
  EnterCriticalSection(&c->lock);
  int closed = c->closed;
  LeaveCriticalSection(&c->lock);
  return closed;
}

static DWORD WINAPI io_tcp_thread(LPVOID arg) {
  io_connect_t *job = arg;
  io_conn_t *c = job->conn;
  char port[16];
  snprintf(port, sizeof port, "%d", job->port);
  SOCKET s = INVALID_SOCKET;
  char why[300] = "";
  uint64_t deadline = GetTickCount64() + IO_CONNECT_TIMEOUT_MS;

  if (!io_is_closed(c)) {
    struct addrinfo hints, *found = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int got = getaddrinfo(job->host, port, &hints, &found);
    if (got != 0) {
      snprintf(why, sizeof why, "%s: no such host", job->host);
    } else {
      for (struct addrinfo *a = found; a != NULL; a = a->ai_next) {
        if (io_is_closed(c)) break;
        if (GetTickCount64() >= deadline) {
          snprintf(why, sizeof why, "connect %s:%d: timed out", job->host, job->port);
          break;
        }
        s = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (s == INVALID_SOCKET) continue;
        u_long nb = 1;
        ioctlsocket(s, FIONBIO, &nb);
        int rc = connect(s, a->ai_addr, (int)a->ai_addrlen);
        if (rc == 0) break;
        int werr = WSAGetLastError();
        if (werr == WSAEWOULDBLOCK || werr == WSAEINPROGRESS) {
          int connected = 0;
          for (;;) {
            if (io_is_closed(c)) break;
            uint64_t now = GetTickCount64();
            if (now >= deadline) {
              snprintf(why, sizeof why, "connect %s:%d: timed out", job->host, job->port);
              break;
            }
            uint64_t slice = deadline - now;
            if (slice > 50) slice = 50;
            fd_set wfds, efds;
            FD_ZERO(&wfds);
            FD_ZERO(&efds);
            FD_SET(s, &wfds);
            FD_SET(s, &efds);
            struct timeval tv;
            tv.tv_sec = (long)(slice / 1000);
            tv.tv_usec = (long)((slice % 1000) * 1000);
            int sr = select(0, NULL, &wfds, &efds, &tv);
            if (sr > 0) {
              int err = 0;
              int elen = (int)sizeof err;
              getsockopt(s, SOL_SOCKET, SO_ERROR, (char *)&err, &elen);
              if (err == 0) {
                connected = 1;
              } else {
                io_error_text((DWORD)err, why, sizeof why);
              }
              break;
            }
            if (sr < 0) {
              io_error_text((DWORD)WSAGetLastError(), why, sizeof why);
              break;
            }
          }
          if (connected) break;
        } else {
          io_error_text((DWORD)werr, why, sizeof why);
        }
        closesocket(s);
        s = INVALID_SOCKET;
      }
      freeaddrinfo(found);
    }
  }

  if (s == INVALID_SOCKET) {
    if (why[0] == 0) snprintf(why, sizeof why, "connect %s:%d failed", job->host, job->port);
    if (io_slot_clear_if(c)) io_conn_unref(c);
    io_told(c->id, 'f', why, strlen(why));
    free(job->host);
    free(job);
    io_conn_unref(c);
    return 0;
  }

  u_long nb = 0;
  ioctlsocket(s, FIONBIO, &nb);
  BOOL one = TRUE;
  setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, (const char *)&one, sizeof one);
  setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof one);
  DWORD snd_ms = IO_SNDTIMEO_SEC * 1000;
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&snd_ms, sizeof snd_ms);

  EnterCriticalSection(&c->lock);
  int closed = c->closed;
  if (!closed) {
    c->sock = s;
    c->ready = 1;
  }
  LeaveCriticalSection(&c->lock);
  if (closed) {
    closesocket(s);
    free(job->host);
    free(job);
    io_conn_unref(c);
    return 0;
  }

  io_told(c->id, 'c', NULL, 0);
  char buf[65536];
  for (;;) {
    int n = recv(s, buf, sizeof buf, 0);
    if (n <= 0) break;
    io_told(c->id, 'd', buf, (size_t)n);
  }
  io_told(c->id, 'e', NULL, 0);
  free(job->host);
  free(job);
  io_conn_unref(c);
  return 0;
}

int32_t p54io_tcp_open(int64_t id, moonbit_bytes_t host, int32_t port) {
  io_conn_t *c = NULL;
  int slot = io_take(id, &c);
  if (slot < 0) return -1;
  io_connect_t *job = malloc(sizeof *job);
  if (job == NULL) {
    if (io_slot_clear_if(c)) io_conn_unref(c);
    io_conn_unref(c);
    return -1;
  }
  job->conn = c;
  job->host = _strdup((const char *)host);
  job->port = port;
  HANDLE t = CreateThread(NULL, 0, io_tcp_thread, job, 0, NULL);
  if (t == NULL) {
    free(job->host);
    free(job);
    if (io_slot_clear_if(c)) io_conn_unref(c);
    io_conn_unref(c);
    return -1;
  }
  CloseHandle(t);
  return slot;
}

static DWORD WINAPI io_serial_thread(LPVOID arg) {
  io_conn_t *c = arg;
  char buf[4096];
  for (;;) {
    DWORD n = 0;
    if (!ReadFile(c->port, buf, sizeof buf, &n, NULL)) break;
    if (n > 0) io_told(c->id, 'd', buf, n);
  }
  io_told(c->id, 'e', NULL, 0);
  io_conn_unref(c);
  return 0;
}

/// A serial port (`COM3`, or `\\.\COM10`) opened raw at `baud`: its slot, or -1 with why told.
int32_t p54io_serial_open(int64_t id, moonbit_bytes_t path, int32_t baud) {
  const char *p = (const char *)path;
  char full[300];
  if (strncmp(p, "\\\\.\\", 4) == 0) snprintf(full, sizeof full, "%s", p);
  else snprintf(full, sizeof full, "\\\\.\\%s", p);
  wchar_t w[300];
  MultiByteToWideChar(CP_UTF8, 0, full, -1, w, 300);
  HANDLE h = CreateFileW(w, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
  if (h == INVALID_HANDLE_VALUE) {
    char why[300];
    io_error_text(GetLastError(), why, sizeof why);
    io_told(id, 'f', why, strlen(why));
    return -1;
  }
  DCB dcb;
  memset(&dcb, 0, sizeof dcb);
  dcb.DCBlength = sizeof dcb;
  GetCommState(h, &dcb);
  if (baud > 0) dcb.BaudRate = (DWORD)baud;
  dcb.ByteSize = 8;
  dcb.Parity = NOPARITY;
  dcb.StopBits = ONESTOPBIT;
  dcb.fBinary = TRUE;
  dcb.fOutxCtsFlow = FALSE;
  dcb.fOutxDsrFlow = FALSE;
  dcb.fDtrControl = DTR_CONTROL_ENABLE;
  dcb.fRtsControl = RTS_CONTROL_ENABLE;
  dcb.fOutX = FALSE;
  dcb.fInX = FALSE;
  SetCommState(h, &dcb);
  COMMTIMEOUTS t;
  memset(&t, 0, sizeof t);
  t.ReadIntervalTimeout = 20;
  t.ReadTotalTimeoutConstant = 0;
  t.ReadTotalTimeoutMultiplier = 0;
  SetCommTimeouts(h, &t);
  io_conn_t *c = NULL;
  int slot = io_take(id, &c);
  if (slot < 0) {
    CloseHandle(h);
    return -1;
  }
  EnterCriticalSection(&c->lock);
  c->serial = 1;
  c->port = h;
  c->ready = 1;
  LeaveCriticalSection(&c->lock);
  HANDLE th = CreateThread(NULL, 0, io_serial_thread, c, 0, NULL);
  if (th == NULL) {
    if (io_slot_clear_if(c)) io_conn_unref(c);
    io_conn_unref(c);
    return -1;
  }
  CloseHandle(th);
  io_told(id, 'c', NULL, 0);
  return slot;
}

int32_t p54io_write(int32_t slot, moonbit_bytes_t data) {
  io_conn_t *c = io_slot_get(slot);
  if (c == NULL) return 0;
  size_t len = (size_t)Moonbit_array_length(data);
  int need_start = 0;
  int ok = 1;
  EnterCriticalSection(&c->lock);
  if (!c->ready || c->closed || c->write_failed || c->end_queued) {
    ok = 0;
  } else if (len > 0) {
    if (len > IO_WRITE_MAX || c->wqueued > IO_WRITE_MAX - len) {
      ok = 0;
    } else {
      io_chunk_t *ch = malloc(sizeof *ch + len);
      if (ch == NULL) {
        ok = 0;
      } else {
        ch->next = NULL;
        ch->len = len;
        memcpy(ch->data, data, len);
        if (c->wtail != NULL) c->wtail->next = ch;
        else c->whead = ch;
        c->wtail = ch;
        c->wqueued += len;
        if (!c->writer_started) {
          c->writer_started = 1;
          need_start = 1;
        }
        WakeConditionVariable(&c->wcond);
      }
    }
  }
  LeaveCriticalSection(&c->lock);
  if (need_start) {
    io_conn_ref(c);
    HANDLE th = CreateThread(NULL, 0, io_write_thread, c, 0, NULL);
    if (th == NULL) {
      EnterCriticalSection(&c->lock);
      c->write_failed = 1;
      c->writer_started = 0;
      io_chunk_t *drop = c->whead;
      c->whead = c->wtail = NULL;
      c->wqueued = 0;
      LeaveCriticalSection(&c->lock);
      io_free_chunks(drop);
      io_conn_unref(c);
      ok = 0;
    } else {
      CloseHandle(th);
    }
  }
  io_conn_unref(c);
  return ok ? 1 : 0;
}

void p54io_end(int32_t slot) {
  io_conn_t *c = io_slot_get(slot);
  if (c == NULL) return;
  int do_sd = 0;
  SOCKET sd_sock = INVALID_SOCKET;
  EnterCriticalSection(&c->lock);
  if (c->ready && !c->closed && !c->serial && !c->end_queued) {
    c->end_queued = 1;
    if (c->writer_started) {
      WakeConditionVariable(&c->wcond);
    } else if (!c->end_done && c->sock != INVALID_SOCKET) {
      c->end_done = 1;
      do_sd = 1;
      sd_sock = c->sock;
    }
  }
  LeaveCriticalSection(&c->lock);
  if (do_sd) shutdown(sd_sock, SD_SEND);
  io_conn_unref(c);
}

void p54io_close(int32_t slot) {
  if (slot <= 0 || slot >= IO_SLOTS) return;
  io_start();
  EnterCriticalSection(&io_lock);
  io_conn_t *c = io_slots[slot];
  io_slots[slot] = NULL;
  LeaveCriticalSection(&io_lock);
  if (c == NULL) return;
  EnterCriticalSection(&c->lock);
  c->closed = 1;
  io_chunk_t *drop = c->whead;
  c->whead = c->wtail = NULL;
  c->wqueued = 0;
  int ready = c->ready;
  int serial = c->serial;
  SOCKET sock = c->sock;
  HANDLE port = c->port;
  WakeConditionVariable(&c->wcond);
  LeaveCriticalSection(&c->lock);
  io_free_chunks(drop);
  if (ready) {
    if (serial && port != INVALID_HANDLE_VALUE) CancelIoEx(port, NULL);
    else if (!serial && sock != INVALID_SOCKET) shutdown(sock, SD_BOTH);
  }
  io_conn_unref(c);
}

/// How many slots are held now.
int32_t p54io_held(void) {
  io_start();
  EnterCriticalSection(&io_lock);
  int32_t n = 0;
  for (int i = 1; i < IO_SLOTS; i++) n += io_slots[i] != NULL ? 1 : 0;
  LeaveCriticalSection(&io_lock);
  return n;
}

/// still.fail Helper is macOS's alone: nothing asked here.
moonbit_bytes_t p54io_unix_rpc(moonbit_bytes_t path, moonbit_bytes_t line, int32_t lines, int32_t timeout_ms) {
  (void)path;
  (void)line;
  (void)lines;
  (void)timeout_ms;
  return moonbit_make_bytes(0, 0);
}

#else
// ───────────────────────────────────────────── Unix ─────────────────────────────────────────────
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <termios.h>
#include <netdb.h>
#include <time.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

static int64_t io_now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void io_set_nonblock_cloexec(int fd) {
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
  int fdfl = fcntl(fd, F_GETFD, 0);
  if (fdfl >= 0) fcntl(fd, F_SETFD, fdfl | FD_CLOEXEC);
}

typedef struct {
  int ref; // protected by io_lock
  int64_t id;
  int slot;
  int serial;
  int fd;
  int cancel_pipe[2];
  pthread_mutex_t lock;
  pthread_cond_t wcond;
  int ready;
  int closed;
  int write_failed;
  int end_queued;
  int end_done;
  int writer_started;
  io_chunk_t *whead;
  io_chunk_t *wtail;
  size_t wqueued;
} io_conn_t;

static io_conn_t *io_slots[IO_SLOTS];
static pthread_mutex_t io_lock = PTHREAD_MUTEX_INITIALIZER;

static io_conn_t *io_conn_new(int64_t id, int slot) {
  io_conn_t *c = calloc(1, sizeof *c);
  if (c == NULL) return NULL;
  c->ref = 2; // 1 for io_slots[slot], 1 for caller/worker
  c->id = id;
  c->slot = slot;
  c->fd = -1;
  c->cancel_pipe[0] = -1;
  c->cancel_pipe[1] = -1;
  if (pipe(c->cancel_pipe) == 0) {
    io_set_nonblock_cloexec(c->cancel_pipe[0]);
    io_set_nonblock_cloexec(c->cancel_pipe[1]);
  }
  pthread_mutex_init(&c->lock, NULL);
  pthread_cond_init(&c->wcond, NULL);
  return c;
}

static void io_conn_ref(io_conn_t *c) {
  pthread_mutex_lock(&io_lock);
  c->ref++;
  pthread_mutex_unlock(&io_lock);
}

static void io_conn_unref(io_conn_t *c) {
  pthread_mutex_lock(&io_lock);
  int last = (--c->ref == 0);
  pthread_mutex_unlock(&io_lock);
  if (!last) return;
  io_free_chunks(c->whead);
  if (c->fd >= 0) close(c->fd);
  if (c->cancel_pipe[0] >= 0) close(c->cancel_pipe[0]);
  if (c->cancel_pipe[1] >= 0) close(c->cancel_pipe[1]);
  pthread_cond_destroy(&c->wcond);
  pthread_mutex_destroy(&c->lock);
  free(c);
}

static int io_take(int64_t id, io_conn_t **out) {
  pthread_mutex_lock(&io_lock);
  int found = -1;
  for (int i = 1; i < IO_SLOTS; i++) {
    if (io_slots[i] == NULL) {
      io_conn_t *c = io_conn_new(id, i);
      if (c != NULL) {
        io_slots[i] = c;
        *out = c;
        found = i;
      }
      break;
    }
  }
  pthread_mutex_unlock(&io_lock);
  return found;
}

static io_conn_t *io_slot_get(int slot) {
  if (slot <= 0 || slot >= IO_SLOTS) return NULL;
  pthread_mutex_lock(&io_lock);
  io_conn_t *c = io_slots[slot];
  if (c != NULL) c->ref++;
  pthread_mutex_unlock(&io_lock);
  return c;
}

static int io_slot_clear_if(io_conn_t *c) {
  pthread_mutex_lock(&io_lock);
  int had = 0;
  if (c->slot > 0 && c->slot < IO_SLOTS && io_slots[c->slot] == c) {
    io_slots[c->slot] = NULL;
    had = 1;
  }
  pthread_mutex_unlock(&io_lock);
  return had;
}

static int io_start_thread(void *(*f)(void *), void *arg) {
  pthread_t t;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  int rc = pthread_create(&t, &attr, f, arg);
  pthread_attr_destroy(&attr);
  return rc == 0;
}

static int io_is_closed(io_conn_t *c) {
  pthread_mutex_lock(&c->lock);
  int closed = c->closed;
  pthread_mutex_unlock(&c->lock);
  return closed;
}

static void *io_write_thread(void *arg) {
  io_conn_t *c = arg;
  for (;;) {
    pthread_mutex_lock(&c->lock);
    while (!c->closed && !c->write_failed && c->whead == NULL && !c->end_queued) {
      pthread_cond_wait(&c->wcond, &c->lock);
    }
    if (c->closed || c->write_failed) {
      io_chunk_t *drop = c->whead;
      c->whead = c->wtail = NULL;
      c->wqueued = 0;
      pthread_mutex_unlock(&c->lock);
      io_free_chunks(drop);
      break;
    }
    if (c->whead != NULL) {
      io_chunk_t *ch = c->whead;
      c->whead = ch->next;
      if (c->whead == NULL) c->wtail = NULL;
      c->wqueued -= ch->len;
      int fd = c->fd;
      int serial = c->serial;
      int cancel_r = c->cancel_pipe[0];
      pthread_mutex_unlock(&c->lock);

      size_t done = 0;
      int ok = 1;
      int cancelled = 0;
      int64_t deadline = io_now_ms() + (int64_t)IO_SNDTIMEO_SEC * 1000;
      while (done < ch->len) {
        int64_t left = deadline - io_now_ms();
        if (left <= 0) {
          ok = 0;
          break;
        }
        struct pollfd pfd[2];
        pfd[0].fd = fd;
        pfd[0].events = POLLOUT;
        pfd[0].revents = 0;
        nfds_t nfds = 1;
        if (cancel_r >= 0) {
          pfd[1].fd = cancel_r;
          pfd[1].events = POLLIN;
          pfd[1].revents = 0;
          nfds = 2;
        }
        int pr = poll(pfd, nfds, (int)left);
        if (pr < 0 && errno == EINTR) continue;
        if (pr <= 0) {
          ok = 0;
          break;
        }
        if (nfds == 2 && (pfd[1].revents & (POLLIN | POLLHUP | POLLERR))) {
          cancelled = 1;
          break;
        }
        if (pfd[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
          ok = 0;
          break;
        }
#ifdef MSG_NOSIGNAL
        ssize_t n = serial
          ? write(fd, (const char *)ch->data + done, ch->len - done)
          : send(fd, (const char *)ch->data + done, ch->len - done, MSG_NOSIGNAL);
        if (n < 0 && !serial && errno == ENOTSOCK) n = write(fd, (const char *)ch->data + done, ch->len - done);
#else
        ssize_t n = write(fd, (const char *)ch->data + done, ch->len - done);
#endif
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n <= 0) {
          ok = 0;
          break;
        }
        done += (size_t)n;
        deadline = io_now_ms() + (int64_t)IO_SNDTIMEO_SEC * 1000;
      }
      free(ch);
      if (cancelled) {
        pthread_mutex_lock(&c->lock);
        io_chunk_t *drop = c->whead;
        c->whead = c->wtail = NULL;
        c->wqueued = 0;
        pthread_mutex_unlock(&c->lock);
        io_free_chunks(drop);
        break;
      }
      if (!ok) {
        pthread_mutex_lock(&c->lock);
        c->write_failed = 1;
        io_chunk_t *drop = c->whead;
        c->whead = c->wtail = NULL;
        c->wqueued = 0;
        int do_sd = (!c->closed && !c->serial && c->fd >= 0);
        int sd_fd = c->fd;
        pthread_mutex_unlock(&c->lock);
        io_free_chunks(drop);
        if (do_sd) shutdown(sd_fd, SHUT_RDWR);
        break;
      }
      continue;
    }
    if (c->end_queued) {
      int do_sd = (!c->end_done && !c->serial && c->fd >= 0);
      int sd_fd = c->fd;
      c->end_done = 1;
      pthread_mutex_unlock(&c->lock);
      if (do_sd) shutdown(sd_fd, SHUT_WR);
      break;
    }
    pthread_mutex_unlock(&c->lock);
  }
  io_conn_unref(c);
  return NULL;
}

static void io_read_loop(io_conn_t *c) {
  char buf[65536];
  int fd = c->fd;
  int cancel_r = c->cancel_pipe[0];
  for (;;) {
    struct pollfd pfd[2];
    pfd[0].fd = fd;
    pfd[0].events = POLLIN;
    pfd[0].revents = 0;
    nfds_t nfds = 1;
    if (cancel_r >= 0) {
      pfd[1].fd = cancel_r;
      pfd[1].events = POLLIN;
      pfd[1].revents = 0;
      nfds = 2;
    }
    int pr = poll(pfd, nfds, -1);
    if (pr < 0 && errno == EINTR) continue;
    if (pr <= 0) break;
    if (nfds == 2 && (pfd[1].revents & (POLLIN | POLLHUP | POLLERR))) break;
    if (pfd[0].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) {
      ssize_t n = read(fd, buf, sizeof buf);
      if (n < 0 && errno == EINTR) continue;
      if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
      if (n <= 0) break;
      io_told(c->id, 'd', buf, (size_t)n);
    }
  }
  io_told(c->id, 'e', NULL, 0);
}

typedef struct {
  io_conn_t *conn;
  char *host;
  int port;
} io_job_t;

static void *io_tcp_thread(void *arg) {
  io_job_t *job = arg;
  io_conn_t *c = job->conn;
  char port[16];
  snprintf(port, sizeof port, "%d", job->port);
  int fd = -1;
  char why[300] = "";
  int64_t deadline = io_now_ms() + IO_CONNECT_TIMEOUT_MS;

  if (!io_is_closed(c)) {
    struct addrinfo hints, *found = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int got = getaddrinfo(job->host, port, &hints, &found);
    if (got != 0) {
      snprintf(why, sizeof why, "%s: %s", job->host, gai_strerror(got));
    } else {
      for (struct addrinfo *a = found; a != NULL; a = a->ai_next) {
        if (io_is_closed(c)) break;
        int64_t left = deadline - io_now_ms();
        if (left <= 0) {
          snprintf(why, sizeof why, "connect %s:%d: timed out", job->host, job->port);
          break;
        }
        fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) continue;
        io_set_nonblock_cloexec(fd);
        int rc = connect(fd, a->ai_addr, a->ai_addrlen);
        if (rc == 0) break;
        if (errno == EINPROGRESS) {
          int connected = 0;
          for (;;) {
            if (io_is_closed(c)) break;
            left = deadline - io_now_ms();
            if (left <= 0) {
              snprintf(why, sizeof why, "connect %s:%d: timed out", job->host, job->port);
              break;
            }
            struct pollfd pfd[2];
            pfd[0].fd = fd;
            pfd[0].events = POLLOUT;
            pfd[0].revents = 0;
            nfds_t nfds = 1;
            if (c->cancel_pipe[0] >= 0) {
              pfd[1].fd = c->cancel_pipe[0];
              pfd[1].events = POLLIN;
              pfd[1].revents = 0;
              nfds = 2;
            }
            int pr = poll(pfd, nfds, (int)left);
            if (pr < 0 && errno == EINTR) continue;
            if (pr == 0) {
              snprintf(why, sizeof why, "connect %s:%d: timed out", job->host, job->port);
              break;
            }
            if (pr < 0) {
              snprintf(why, sizeof why, "connect %s:%d: %s", job->host, job->port, strerror(errno));
              break;
            }
            if (nfds == 2 && (pfd[1].revents & (POLLIN | POLLHUP | POLLERR))) break;
            if (pfd[0].revents & (POLLOUT | POLLERR | POLLHUP)) {
              int err = 0;
              socklen_t elen = sizeof err;
              if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen) == 0 && err == 0) {
                connected = 1;
              } else {
                snprintf(why, sizeof why, "connect %s:%d: %s", job->host, job->port, strerror(err ? err : errno));
              }
              break;
            }
          }
          if (connected) break;
        } else {
          snprintf(why, sizeof why, "connect %s:%d: %s", job->host, job->port, strerror(errno));
        }
        close(fd);
        fd = -1;
      }
      freeaddrinfo(found);
    }
  }

  if (fd < 0) {
    if (why[0] == 0) snprintf(why, sizeof why, "connect %s:%d failed", job->host, job->port);
    if (io_slot_clear_if(c)) io_conn_unref(c);
    io_told(c->id, 'f', why, strlen(why));
  } else {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    struct timeval tv = { IO_SNDTIMEO_SEC, 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

    pthread_mutex_lock(&c->lock);
    int closed = c->closed;
    if (!closed) {
      c->fd = fd;
      c->ready = 1;
    }
    pthread_mutex_unlock(&c->lock);
    if (closed) {
      close(fd);
    } else {
      io_told(c->id, 'c', NULL, 0);
      io_read_loop(c);
    }
  }
  free(job->host);
  free(job);
  io_conn_unref(c);
  return NULL;
}

/// A TCP connection to `host`:`port`, made by a thread of its own: its slot (told `c` once connected, `f` where not).
int32_t p54io_tcp_open(int64_t id, moonbit_bytes_t host, int32_t port) {
  io_conn_t *c = NULL;
  int slot = io_take(id, &c);
  if (slot < 0) return -1;
  io_job_t *job = malloc(sizeof *job);
  if (job == NULL) {
    if (io_slot_clear_if(c)) io_conn_unref(c);
    io_conn_unref(c);
    return -1;
  }
  job->conn = c;
  job->host = strdup((const char *)host);
  job->port = port;
  if (!io_start_thread(io_tcp_thread, job)) {
    free(job->host);
    free(job);
    if (io_slot_clear_if(c)) io_conn_unref(c);
    io_conn_unref(c);
    return -1;
  }
  return slot;
}

static void *io_serial_thread(void *arg) {
  io_conn_t *c = arg;
  io_read_loop(c);
  io_conn_unref(c);
  return NULL;
}

static speed_t io_speed(int baud) {
  switch (baud) {
    case 1200: return B1200;
    case 2400: return B2400;
    case 4800: return B4800;
    case 9600: return B9600;
    case 19200: return B19200;
    case 38400: return B38400;
    case 57600: return B57600;
    case 115200: return B115200;
    case 230400: return B230400;
    default: return B115200;
  }
}

/// A serial port opened raw at `baud` (0: at the speed it was set to): its slot, or -1 with why told.
int32_t p54io_serial_open(int64_t id, moonbit_bytes_t path, int32_t baud) {
  int fd = open((const char *)path, O_RDWR | O_NOCTTY | O_NONBLOCK);
  if (fd < 0) {
    const char *why = strerror(errno);
    io_told(id, 'f', why, strlen(why));
    return -1;
  }
  io_set_nonblock_cloexec(fd);
  struct termios t;
  if (tcgetattr(fd, &t) == 0) {
    cfmakeraw(&t);
    if (baud > 0) {
      cfsetispeed(&t, io_speed(baud));
      cfsetospeed(&t, io_speed(baud));
    }
    t.c_cflag |= (CLOCAL | CREAD);
    t.c_cc[VMIN] = 1;
    t.c_cc[VTIME] = 0;
    tcsetattr(fd, TCSANOW, &t);
  }
  io_conn_t *c = NULL;
  int slot = io_take(id, &c);
  if (slot < 0) {
    close(fd);
    return -1;
  }
  pthread_mutex_lock(&c->lock);
  c->serial = 1;
  c->fd = fd;
  c->ready = 1;
  pthread_mutex_unlock(&c->lock);
  io_told(id, 'c', NULL, 0);
  if (!io_start_thread(io_serial_thread, c)) {
    if (io_slot_clear_if(c)) io_conn_unref(c);
    io_conn_unref(c);
    return -1;
  }
  return slot;
}

/// Queued for writing (1), or refused (0: closed, write failed, or send queue full).
int32_t p54io_write(int32_t slot, moonbit_bytes_t data) {
  io_conn_t *c = io_slot_get(slot);
  if (c == NULL) return 0;
  size_t len = (size_t)Moonbit_array_length(data);
  int need_start = 0;
  int ok = 1;
  pthread_mutex_lock(&c->lock);
  if (!c->ready || c->closed || c->write_failed || c->end_queued) {
    ok = 0;
  } else if (len > 0) {
    if (len > IO_WRITE_MAX || c->wqueued > IO_WRITE_MAX - len) {
      ok = 0;
    } else {
      io_chunk_t *ch = malloc(sizeof *ch + len);
      if (ch == NULL) {
        ok = 0;
      } else {
        ch->next = NULL;
        ch->len = len;
        memcpy(ch->data, data, len);
        if (c->wtail != NULL) c->wtail->next = ch;
        else c->whead = ch;
        c->wtail = ch;
        c->wqueued += len;
        if (!c->writer_started) {
          c->writer_started = 1;
          need_start = 1;
        }
        pthread_cond_signal(&c->wcond);
      }
    }
  }
  pthread_mutex_unlock(&c->lock);
  if (need_start) {
    io_conn_ref(c);
    if (!io_start_thread(io_write_thread, c)) {
      pthread_mutex_lock(&c->lock);
      c->write_failed = 1;
      c->writer_started = 0;
      io_chunk_t *drop = c->whead;
      c->whead = c->wtail = NULL;
      c->wqueued = 0;
      pthread_mutex_unlock(&c->lock);
      io_free_chunks(drop);
      io_conn_unref(c);
      ok = 0;
    }
  }
  io_conn_unref(c);
  return ok ? 1 : 0;
}

/// Its sending side ended after all queued bytes are written (the other side reads its end).
void p54io_end(int32_t slot) {
  io_conn_t *c = io_slot_get(slot);
  if (c == NULL) return;
  int do_sd = 0;
  int sd_fd = -1;
  pthread_mutex_lock(&c->lock);
  if (c->ready && !c->closed && !c->serial && !c->end_queued) {
    c->end_queued = 1;
    if (c->writer_started) {
      pthread_cond_signal(&c->wcond);
    } else if (!c->end_done && c->fd >= 0) {
      c->end_done = 1;
      do_sd = 1;
      sd_fd = c->fd;
    }
  }
  pthread_mutex_unlock(&c->lock);
  if (do_sd) shutdown(sd_fd, SHUT_WR);
  io_conn_unref(c);
}

void p54io_close(int32_t slot) {
  if (slot <= 0 || slot >= IO_SLOTS) return;
  pthread_mutex_lock(&io_lock);
  io_conn_t *c = io_slots[slot];
  io_slots[slot] = NULL;
  pthread_mutex_unlock(&io_lock);
  if (c == NULL) return;
  pthread_mutex_lock(&c->lock);
  c->closed = 1;
  io_chunk_t *drop = c->whead;
  c->whead = c->wtail = NULL;
  c->wqueued = 0;
  int ready = c->ready;
  int serial = c->serial;
  int fd = c->fd;
  int cancel_w = c->cancel_pipe[1];
  pthread_cond_signal(&c->wcond);
  pthread_mutex_unlock(&c->lock);
  io_free_chunks(drop);
  if (cancel_w >= 0) {
    uint8_t wake = 1;
    ssize_t ignored = write(cancel_w, &wake, 1);
    (void)ignored;
  }
  if (ready && !serial && fd >= 0) {
    shutdown(fd, SHUT_RDWR);
  }
  io_conn_unref(c);
}

/// How many slots are held now.
int32_t p54io_held(void) {
  pthread_mutex_lock(&io_lock);
  int32_t n = 0;
  for (int i = 1; i < IO_SLOTS; i++) n += io_slots[i] != NULL ? 1 : 0;
  pthread_mutex_unlock(&io_lock);
  return n;
}

/// `line` (a request and what it sends after it) written on the Unix socket at `path`, and what is answered read until
/// `lines` lines came (0: until the other side ends), with total elapsed time bounded by `timeout_ms` on the monotonic
/// clock (still.fail Helper's socket: its folders' requests); empty where it is not had. macOS's: elsewhere nothing is asked.
moonbit_bytes_t p54io_unix_rpc(moonbit_bytes_t path, moonbit_bytes_t line, int32_t lines, int32_t timeout_ms) {
#ifdef __APPLE__
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return moonbit_make_bytes(0, 0);
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  io_set_nonblock_cloexec(fd);
  int64_t deadline = io_now_ms() + (timeout_ms > 0 ? (int64_t)timeout_ms : 0);
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof addr);
  addr.sun_family = AF_UNIX;
  snprintf(addr.sun_path, sizeof addr.sun_path, "%s", (const char *)path);
  int rc = connect(fd, (struct sockaddr *)&addr, sizeof addr);
  if (rc != 0) {
    if (errno == EINPROGRESS || errno == EAGAIN) {
      int connected = 0;
      for (;;) {
        int64_t left = deadline - io_now_ms();
        if (left <= 0) break;
        struct pollfd p = { fd, POLLOUT, 0 };
        int ready = poll(&p, 1, (int)left);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) break;
        int err = 0;
        socklen_t elen = sizeof err;
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen) == 0 && err == 0) connected = 1;
        break;
      }
      if (!connected) {
        close(fd);
        return moonbit_make_bytes(0, 0);
      }
    } else {
      close(fd);
      return moonbit_make_bytes(0, 0);
    }
  }
  size_t len = (size_t)Moonbit_array_length(line), done = 0;
  while (done < len) {
    int64_t left = deadline - io_now_ms();
    if (left <= 0) {
      close(fd);
      return moonbit_make_bytes(0, 0);
    }
    ssize_t n = write(fd, (const char *)line + done, len - done);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      struct pollfd p = { fd, POLLOUT, 0 };
      int ready = poll(&p, 1, (int)left);
      if (ready < 0 && errno == EINTR) continue;
      if (ready <= 0) {
        close(fd);
        return moonbit_make_bytes(0, 0);
      }
      continue;
    }
    if (n <= 0) {
      close(fd);
      return moonbit_make_bytes(0, 0);
    }
    done += (size_t)n;
  }
  char *got = NULL;
  size_t have = 0, cap = 0;
  int seen = 0;
  for (;;) {
    int64_t left = deadline - io_now_ms();
    if (left <= 0) break;
    struct pollfd p = { fd, POLLIN, 0 };
    int ready = poll(&p, 1, (int)left);
    if (ready < 0 && errno == EINTR) continue;
    if (ready <= 0) break;
    if (have + 4096 > cap) {
      cap = cap == 0 ? 8192 : cap * 2;
      char *grown = realloc(got, cap);
      if (grown == NULL) break;
      got = grown;
    }
    ssize_t n = read(fd, got + have, 4096);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
    if (n <= 0) break;
    for (ssize_t i = 0; i < n; i++) {
      if (got[have + (size_t)i] == '\n') seen++;
    }
    have += (size_t)n;
    if (lines > 0 && seen >= lines) break;
  }
  close(fd);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)have, 0);
  if (have) memcpy(out, got, have);
  free(got);
  return out;
#else
  (void)path;
  (void)line;
  (void)lines;
  (void)timeout_ms;
  return moonbit_make_bytes(0, 0);
#endif
}
#endif
