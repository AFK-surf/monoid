// What P5-4's parts ask of the system beyond the shell (client/shell) and sys.c: a TCP connection to any address (a
// device on the station's network, the vault proxy's tunnel to a host it opens nothing of), a serial port (a device
// attached by its cable), and one line asked of still.fail Helper on its socket at once (the folders macOS protects,
// the drive's `Protected`). A connection's and a port's bytes are read by a thread of their own and told on the
// program's queue (host.c `sfh_push_sys`): `c` connected, `d` data, `e` its end, `f` why it failed; nothing here calls
// into MoonBit. Paths and hosts are UTF-8, ended by a NUL. POSIX and Win32 both.
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

#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

typedef struct {
  int used;
  int serial;
  int64_t id;
  SOCKET sock;
  HANDLE port;
} io_slot_t;

static io_slot_t io_slots[IO_SLOTS];
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

static int io_take(int64_t id) {
  io_start();
  EnterCriticalSection(&io_lock);
  int found = -1;
  for (int i = 1; i < IO_SLOTS; i++) {
    if (!io_slots[i].used) {
      io_slots[i].used = 1;
      io_slots[i].id = id;
      io_slots[i].serial = 0;
      io_slots[i].sock = INVALID_SOCKET;
      io_slots[i].port = INVALID_HANDLE_VALUE;
      found = i;
      break;
    }
  }
  LeaveCriticalSection(&io_lock);
  return found;
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

typedef struct {
  int64_t id;
  int slot;
  char *host;
  int port;
} io_connect_t;

static DWORD WINAPI io_tcp_thread(LPVOID arg) {
  io_connect_t *job = arg;
  char port[16];
  snprintf(port, sizeof port, "%d", job->port);
  struct addrinfo hints, *found = NULL;
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  int got = getaddrinfo(job->host, port, &hints, &found);
  SOCKET s = INVALID_SOCKET;
  char why[300] = "";
  if (got != 0) {
    snprintf(why, sizeof why, "%s: no such host", job->host);
  } else {
    for (struct addrinfo *a = found; a != NULL; a = a->ai_next) {
      s = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
      if (s == INVALID_SOCKET) continue;
      if (connect(s, a->ai_addr, (int)a->ai_addrlen) == 0) break;
      io_error_text((DWORD)WSAGetLastError(), why, sizeof why);
      closesocket(s);
      s = INVALID_SOCKET;
    }
    freeaddrinfo(found);
  }
  if (s == INVALID_SOCKET) {
    if (why[0] == 0) snprintf(why, sizeof why, "connect %s:%d failed", job->host, job->port);
    EnterCriticalSection(&io_lock);
    if (io_slots[job->slot].id == job->id) io_slots[job->slot].used = 0;
    LeaveCriticalSection(&io_lock);
    io_told(job->id, 'f', why, strlen(why));
    free(job->host);
    free(job);
    return 0;
  }
  // (the slot let go meanwhile, or taken by another connection: this one is not wanted)
  EnterCriticalSection(&io_lock);
  int mine = io_slots[job->slot].used && io_slots[job->slot].id == job->id;
  if (mine) io_slots[job->slot].sock = s;
  LeaveCriticalSection(&io_lock);
  if (!mine) {
    closesocket(s);
    free(job->host);
    free(job);
    return 0;
  }
  io_told(job->id, 'c', NULL, 0);
  char buf[65536];
  for (;;) {
    int n = recv(s, buf, sizeof buf, 0);
    if (n <= 0) break;
    io_told(job->id, 'd', buf, (size_t)n);
  }
  io_told(job->id, 'e', NULL, 0);
  free(job->host);
  free(job);
  return 0;
}

int32_t p54io_tcp_open(int64_t id, moonbit_bytes_t host, int32_t port) {
  int slot = io_take(id);
  if (slot < 0) return -1;
  io_connect_t *job = malloc(sizeof *job);
  if (job == NULL) return -1;
  job->id = id;
  job->slot = slot;
  job->host = _strdup((const char *)host);
  job->port = port;
  HANDLE t = CreateThread(NULL, 0, io_tcp_thread, job, 0, NULL);
  if (t) CloseHandle(t);
  return slot;
}

typedef struct {
  int64_t id;
  int slot;
  HANDLE port;
} io_serial_t;

static DWORD WINAPI io_serial_thread(LPVOID arg) {
  io_serial_t *job = arg;
  char buf[4096];
  for (;;) {
    DWORD n = 0;
    if (!ReadFile(job->port, buf, sizeof buf, &n, NULL)) break;
    if (n > 0) io_told(job->id, 'd', buf, n);
  }
  io_told(job->id, 'e', NULL, 0);
  free(job);
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
  int slot = io_take(id);
  if (slot < 0) {
    CloseHandle(h);
    return -1;
  }
  io_slots[slot].serial = 1;
  io_slots[slot].port = h;
  io_serial_t *job = malloc(sizeof *job);
  if (job == NULL) return -1;
  job->id = id;
  job->slot = slot;
  job->port = h;
  HANDLE th = CreateThread(NULL, 0, io_serial_thread, job, 0, NULL);
  if (th) CloseHandle(th);
  io_told(id, 'c', NULL, 0);
  return slot;
}

int32_t p54io_write(int32_t slot, moonbit_bytes_t data) {
  if (slot <= 0 || slot >= IO_SLOTS) return 0;
  size_t len = (size_t)Moonbit_array_length(data), done = 0;
  EnterCriticalSection(&io_lock);
  io_slot_t s = io_slots[slot];
  LeaveCriticalSection(&io_lock);
  if (!s.used) return 0;
  while (done < len) {
    if (s.serial) {
      DWORD n = 0;
      if (!WriteFile(s.port, (const char *)data + done, (DWORD)(len - done), &n, NULL) || n == 0) return 0;
      done += n;
    } else {
      if (s.sock == INVALID_SOCKET) return 0;
      int n = send(s.sock, (const char *)data + done, (int)(len - done), 0);
      if (n <= 0) return 0;
      done += (size_t)n;
    }
  }
  return 1;
}

void p54io_end(int32_t slot) {
  if (slot <= 0 || slot >= IO_SLOTS) return;
  EnterCriticalSection(&io_lock);
  if (io_slots[slot].used && !io_slots[slot].serial && io_slots[slot].sock != INVALID_SOCKET) shutdown(io_slots[slot].sock, SD_SEND);
  LeaveCriticalSection(&io_lock);
}

void p54io_close(int32_t slot) {
  if (slot <= 0 || slot >= IO_SLOTS) return;
  EnterCriticalSection(&io_lock);
  io_slot_t s = io_slots[slot];
  io_slots[slot].used = 0;
  LeaveCriticalSection(&io_lock);
  if (!s.used) return;
  if (s.serial) CloseHandle(s.port);
  else if (s.sock != INVALID_SOCKET) {
    shutdown(s.sock, SD_BOTH);
    closesocket(s.sock);
  }
}

/// How many slots are held now.
int32_t p54io_held(void) {
  io_start();
  EnterCriticalSection(&io_lock);
  int32_t n = 0;
  for (int i = 1; i < IO_SLOTS; i++) n += io_slots[i].used ? 1 : 0;
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
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>

typedef struct {
  int used;
  int64_t id;
  int fd;
} io_slot_t;

static io_slot_t io_slots[IO_SLOTS];
static pthread_mutex_t io_lock = PTHREAD_MUTEX_INITIALIZER;

static int io_take(int64_t id) {
  pthread_mutex_lock(&io_lock);
  int found = -1;
  for (int i = 1; i < IO_SLOTS; i++) {
    if (!io_slots[i].used) {
      io_slots[i].used = 1;
      io_slots[i].id = id;
      io_slots[i].fd = -1;
      found = i;
      break;
    }
  }
  pthread_mutex_unlock(&io_lock);
  return found;
}

static void io_start_thread(void *(*f)(void *), void *arg) {
  pthread_t t;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  pthread_create(&t, &attr, f, arg);
  pthread_attr_destroy(&attr);
}

typedef struct {
  int64_t id;
  int slot;
  char *host;
  int port;
  int fd;
} io_job_t;

static void io_read_loop(int64_t id, int fd) {
  char buf[65536];
  for (;;) {
    ssize_t n = read(fd, buf, sizeof buf);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    io_told(id, 'd', buf, (size_t)n);
  }
  io_told(id, 'e', NULL, 0);
}

static void *io_tcp_thread(void *arg) {
  io_job_t *job = arg;
  char port[16];
  snprintf(port, sizeof port, "%d", job->port);
  struct addrinfo hints, *found = NULL;
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  int got = getaddrinfo(job->host, port, &hints, &found);
  int fd = -1;
  char why[300] = "";
  if (got != 0) {
    snprintf(why, sizeof why, "%s: %s", job->host, gai_strerror(got));
  } else {
    for (struct addrinfo *a = found; a != NULL; a = a->ai_next) {
      fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
      if (fd < 0) continue;
      if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
      snprintf(why, sizeof why, "connect %s:%d: %s", job->host, job->port, strerror(errno));
      close(fd);
      fd = -1;
    }
    freeaddrinfo(found);
  }
  if (fd < 0) {
    if (why[0] == 0) snprintf(why, sizeof why, "connect %s:%d failed", job->host, job->port);
    pthread_mutex_lock(&io_lock);
    if (io_slots[job->slot].id == job->id) io_slots[job->slot].used = 0;
    pthread_mutex_unlock(&io_lock);
    io_told(job->id, 'f', why, strlen(why));
  } else {
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    // (the slot let go meanwhile, or taken by another connection: this one is not wanted)
    pthread_mutex_lock(&io_lock);
    int mine = io_slots[job->slot].used && io_slots[job->slot].id == job->id;
    if (mine) io_slots[job->slot].fd = fd;
    pthread_mutex_unlock(&io_lock);
    if (!mine) {
      close(fd);
    } else {
      io_told(job->id, 'c', NULL, 0);
      io_read_loop(job->id, fd);
    }
  }
  free(job->host);
  free(job);
  return NULL;
}

/// A TCP connection to `host`:`port`, made by a thread of its own: its slot (told `c` once connected, `f` where not).
int32_t p54io_tcp_open(int64_t id, moonbit_bytes_t host, int32_t port) {
  int slot = io_take(id);
  if (slot < 0) return -1;
  io_job_t *job = malloc(sizeof *job);
  if (job == NULL) return -1;
  job->id = id;
  job->slot = slot;
  job->host = strdup((const char *)host);
  job->port = port;
  job->fd = -1;
  io_start_thread(io_tcp_thread, job);
  return slot;
}

static void *io_serial_thread(void *arg) {
  io_job_t *job = arg;
  io_read_loop(job->id, job->fd);
  free(job);
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
  int fd = open((const char *)path, O_RDWR | O_NOCTTY);
  if (fd < 0) {
    const char *why = strerror(errno);
    io_told(id, 'f', why, strlen(why));
    return -1;
  }
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
  int slot = io_take(id);
  if (slot < 0) {
    close(fd);
    return -1;
  }
  pthread_mutex_lock(&io_lock);
  io_slots[slot].fd = fd;
  pthread_mutex_unlock(&io_lock);
  io_job_t *job = malloc(sizeof *job);
  if (job == NULL) return -1;
  job->id = id;
  job->slot = slot;
  job->host = NULL;
  job->port = 0;
  job->fd = fd;
  io_told(id, 'c', NULL, 0);
  io_start_thread(io_serial_thread, job);
  return slot;
}

/// Written whole (1), or not (0: closed, refused).
int32_t p54io_write(int32_t slot, moonbit_bytes_t data) {
  if (slot <= 0 || slot >= IO_SLOTS) return 0;
  pthread_mutex_lock(&io_lock);
  int fd = io_slots[slot].used ? io_slots[slot].fd : -1;
  pthread_mutex_unlock(&io_lock);
  if (fd < 0) return 0;
  size_t len = (size_t)Moonbit_array_length(data), done = 0;
  while (done < len) {
#ifdef MSG_NOSIGNAL
    ssize_t n = send(fd, (const char *)data + done, len - done, MSG_NOSIGNAL);
    if (n < 0 && errno == ENOTSOCK) n = write(fd, (const char *)data + done, len - done);
#else
    ssize_t n = write(fd, (const char *)data + done, len - done);
#endif
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return 0;
    done += (size_t)n;
  }
  return 1;
}

/// Its sending side ended (the other side reads its end).
void p54io_end(int32_t slot) {
  if (slot <= 0 || slot >= IO_SLOTS) return;
  pthread_mutex_lock(&io_lock);
  int fd = io_slots[slot].used ? io_slots[slot].fd : -1;
  pthread_mutex_unlock(&io_lock);
  if (fd >= 0) shutdown(fd, SHUT_WR);
}

void p54io_close(int32_t slot) {
  if (slot <= 0 || slot >= IO_SLOTS) return;
  pthread_mutex_lock(&io_lock);
  int fd = io_slots[slot].used ? io_slots[slot].fd : -1;
  io_slots[slot].used = 0;
  io_slots[slot].fd = -1;
  pthread_mutex_unlock(&io_lock);
  if (fd >= 0) {
    shutdown(fd, SHUT_RDWR);
    close(fd);
  }
}

/// How many slots are held now.
int32_t p54io_held(void) {
  pthread_mutex_lock(&io_lock);
  int32_t n = 0;
  for (int i = 1; i < IO_SLOTS; i++) n += io_slots[i].used ? 1 : 0;
  pthread_mutex_unlock(&io_lock);
  return n;
}

/// `line` (a request and what it sends after it) written on the Unix socket at `path`, and what is answered read until
/// `lines` lines came (0: until the other side ends), each read waited for at most `timeout_ms` (still.fail Helper's
/// socket: its folders' requests); empty where it is not had. macOS's: elsewhere nothing is asked.
moonbit_bytes_t p54io_unix_rpc(moonbit_bytes_t path, moonbit_bytes_t line, int32_t lines, int32_t timeout_ms) {
#ifdef __APPLE__
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return moonbit_make_bytes(0, 0);
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof addr);
  addr.sun_family = AF_UNIX;
  snprintf(addr.sun_path, sizeof addr.sun_path, "%s", (const char *)path);
  if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
    close(fd);
    return moonbit_make_bytes(0, 0);
  }
  size_t len = (size_t)Moonbit_array_length(line), done = 0;
  while (done < len) {
    ssize_t n = write(fd, (const char *)line + done, len - done);
    if (n < 0 && errno == EINTR) continue;
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
    struct pollfd p = { fd, POLLIN, 0 };
    int ready = poll(&p, 1, timeout_ms);
    if (ready <= 0) break;
    if (have + 4096 > cap) {
      cap = cap == 0 ? 8192 : cap * 2;
      char *grown = realloc(got, cap);
      if (grown == NULL) break;
      got = grown;
    }
    ssize_t n = read(fd, got + have, 4096);
    if (n < 0 && errno == EINTR) continue;
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
