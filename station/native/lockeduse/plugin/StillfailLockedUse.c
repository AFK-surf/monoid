// still.fail locked use: the SecurityAgent mechanism `StillfailLockedUse:allow` of the right `fail.still.lockeduse`,
// which the screensaver rule tries first (Sources/LockedUseCore/ScreensaverRule.swift). It asks the user's guard,
// once, whether an unlock was given out for this very moment, and allows the unlock only on a whole `yes` from a
// guard whose code it checked. Anything else (no binding, no guard, a guard it cannot check, a short read, a timeout)
// denies, and the screensaver rule goes on to its other ways (the password).
//
// Kept small and in C on purpose: it runs inside the system's authorization process. Wire.swift has the bytes.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/AuthorizationPlugin.h>
#include <Security/Security.h>
#include <bsm/libbsm.h>
#include <errno.h>
#include <os/log.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define ROOT "/Library/Application Support/still.fail"
#define GUARD ROOT "/Guard.app/Contents/MacOS/stillfail-guard"
// The guard as it must be: still.fail's Developer ID (Application), its identifier.
#define GUARD_REQUIREMENT                                                                                                \
  "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and "                                         \
  "certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"D9AAN3VJK8\" and "            \
  "identifier \"fail.still.guard\""

static os_log_t say(void) {
  static os_log_t log;
  if (!log) log = os_log_create("fail.still.lockeduse", "plugin");
  return log;
}

typedef struct {
  const AuthorizationCallbacks *callbacks;
} Plugin;

typedef struct {
  Plugin *plugin;
  AuthorizationEngineRef engine;
} Mechanism;

// The uid of the user whose screen this unlocks: the authorization context's, else the console's. None: deny.
static int session_uid(Mechanism *m, uid_t *uid) {
  const AuthorizationValue *value = NULL;
  AuthorizationContextFlags flags = 0;
  if (m->plugin->callbacks->GetContextValue(m->engine, "uid", &flags, &value) == errAuthorizationSuccess && value &&
      value->length == sizeof(uid_t)) {
    memcpy(uid, value->data, sizeof(uid_t));
    return *uid >= 500;
  }
  if (m->plugin->callbacks->GetHintValue(m->engine, "uid", &value) == errAuthorizationSuccess && value &&
      value->length == sizeof(uid_t)) {
    memcpy(uid, value->data, sizeof(uid_t));
    return *uid >= 500;
  }
  // Not in the context: the console's owner (the lock screen is the console's).
  struct stat st;
  if (stat("/dev/console", &st) == 0 && st.st_uid >= 500) {
    *uid = st.st_uid;
    return 1;
  }
  return 0;
}

// This uid is bound (LockedUse.plist names it): the file is root's, never a link.
static int bound(uid_t uid) {
  struct stat st;
  if (lstat(ROOT "/LockedUse.plist", &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != 0 || (st.st_mode & 022)) return 0;
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)ROOT "/LockedUse.plist",
                                                         strlen(ROOT "/LockedUse.plist"), false);
  if (!url) return 0;
  CFReadStreamRef stream = CFReadStreamCreateWithFile(NULL, url);
  CFRelease(url);
  if (!stream || !CFReadStreamOpen(stream)) {
    if (stream) CFRelease(stream);
    return 0;
  }
  CFPropertyListRef plist = CFPropertyListCreateWithStream(NULL, stream, 0, kCFPropertyListImmutable, NULL, NULL);
  CFReadStreamClose(stream);
  CFRelease(stream);
  int yes = 0;
  if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
    CFDictionaryRef users = CFDictionaryGetValue(plist, CFSTR("users"));
    if (users && CFGetTypeID(users) == CFDictionaryGetTypeID()) {
      CFStringRef key = CFStringCreateWithFormat(NULL, NULL, CFSTR("%u"), uid);
      yes = key && CFDictionaryContainsKey(users, key);
      if (key) CFRelease(key);
    }
  }
  if (plist) CFRelease(plist);
  return yes;
}

// The process at the other end is the guard, as installed (root's path), as signed, running as `uid`, not debugged.
static int is_guard(int fd, uid_t uid) {
  audit_token_t token;
  socklen_t size = sizeof(token);
  if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) != 0 || size != sizeof(token)) return 0;
  if (audit_token_to_euid(token) != uid) return 0;
  CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
  const void *keys[] = {kSecGuestAttributeAudit};
  const void *values[] = {data};
  CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFRelease(data);
  SecCodeRef code = NULL;
  OSStatus got = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
  CFRelease(attributes);
  if (got != errSecSuccess || !code) return 0;
  int ok = 0;
  SecRequirementRef requirement = NULL;
  CFDictionaryRef info = NULL;
  CFURLRef path = NULL;
  if (SecRequirementCreateWithString(CFSTR(GUARD_REQUIREMENT), kSecCSDefaultFlags, &requirement) != errSecSuccess) goto done;
  if (SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement) != errSecSuccess) goto done;
  if (SecCodeCopyPath((SecStaticCodeRef)code, kSecCSDefaultFlags, &path) != errSecSuccess || !path) goto done;
  char where[1024];
  if (!CFURLGetFileSystemRepresentation(path, true, (UInt8 *)where, sizeof(where))) goto done;
  // Guard.app's bundle path, or its executable's.
  if (strcmp(where, ROOT "/Guard.app") != 0 && strcmp(where, GUARD) != 0) goto done;
  if (SecCodeCopySigningInformation((SecStaticCodeRef)code, kSecCSDynamicInformation | kSecCSSigningInformation, &info) != errSecSuccess || !info)
    goto done;
  CFNumberRef flags = CFDictionaryGetValue(info, kSecCodeInfoFlags);
  CFNumberRef status = CFDictionaryGetValue(info, kSecCodeInfoStatus);
  uint32_t f = 0, s = 0;
  if (!flags || !status || !CFNumberGetValue(flags, kCFNumberSInt32Type, &f) || !CFNumberGetValue(status, kCFNumberSInt32Type, &s)) goto done;
  // The hardened runtime as signed; valid and not debugged as it runs (CS_VALID 0x1, CS_DEBUGGED 0x10000000).
  if (!(f & kSecCodeSignatureRuntime) || !(s & 0x1) || (s & 0x10000000)) goto done;
  CFDictionaryRef entitlements = CFDictionaryGetValue(info, kSecCodeInfoEntitlementsDict);
  if (entitlements) {
    CFStringRef risky[] = {CFSTR("com.apple.security.get-task-allow"), CFSTR("com.apple.security.cs.allow-dyld-environment-variables"),
                           CFSTR("com.apple.security.cs.disable-library-validation")};
    for (size_t i = 0; i < sizeof(risky) / sizeof(risky[0]); i++) {
      if (CFDictionaryGetValue(entitlements, risky[i]) == kCFBooleanTrue) goto done;
    }
  }
  ok = 1;
done:
  if (requirement) CFRelease(requirement);
  if (info) CFRelease(info);
  if (path) CFRelease(path);
  CFRelease(code);
  return ok;
}

// One question to the guard: yes only for a whole, well-formed yes.
static int guard_says_yes(uid_t uid) {
  char path[256];
  if (snprintf(path, sizeof(path), ROOT "/lockuse/%u/auth.sock", uid) >= (int)sizeof(path)) return 0;
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  if (strlen(path) >= sizeof(address.sun_path)) return 0;
  strcpy(address.sun_path, path);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return 0;
  struct timeval timeout = {.tv_sec = 2};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
  int yes = 0;
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) goto done;
  if (!is_guard(fd, uid)) {
    os_log_error(say(), "the socket's peer is not the installed guard: denied");
    goto done;
  }
  unsigned char ask[10] = {'S', 'F', 'L', 'U', 1, 1, (unsigned char)(uid >> 24), (unsigned char)(uid >> 16), (unsigned char)(uid >> 8), (unsigned char)uid};
  if (write(fd, ask, sizeof(ask)) != sizeof(ask)) goto done;
  unsigned char answer[6];
  size_t at = 0;
  while (at < sizeof(answer)) {
    ssize_t n = read(fd, answer + at, sizeof(answer) - at);
    if (n <= 0) goto done;
    at += (size_t)n;
  }
  yes = memcmp(answer, "SFLU", 4) == 0 && answer[4] == 1 && answer[5] == 1;
done:
  close(fd);
  return yes;
}

static OSStatus invoke(AuthorizationMechanismRef ref) {
  Mechanism *m = (Mechanism *)ref;
  uid_t uid = 0;
  int allow = session_uid(m, &uid) && bound(uid) && guard_says_yes(uid);
  os_log_info(say(), "locked use for uid %u: %{public}s", uid, allow ? "allowed" : "denied");
  return m->plugin->callbacks->SetResult(m->engine, allow ? kAuthorizationResultAllow : kAuthorizationResultDeny);
}

static OSStatus mechanism_create(AuthorizationPluginRef plugin, AuthorizationEngineRef engine, AuthorizationMechanismId id,
                                 AuthorizationMechanismRef *out) {
  if (strcmp(id, "allow") != 0) return errAuthorizationInternal;
  Mechanism *m = calloc(1, sizeof(Mechanism));
  if (!m) return errAuthorizationInternal;
  m->plugin = (Plugin *)plugin;
  m->engine = engine;
  *out = m;
  return errAuthorizationSuccess;
}

static OSStatus mechanism_deactivate(AuthorizationMechanismRef ref) {
  Mechanism *m = (Mechanism *)ref;
  return m->plugin->callbacks->DidDeactivate(m->engine);
}

static OSStatus mechanism_destroy(AuthorizationMechanismRef ref) {
  free(ref);
  return errAuthorizationSuccess;
}

static OSStatus plugin_destroy(AuthorizationPluginRef ref) {
  free(ref);
  return errAuthorizationSuccess;
}

static const AuthorizationPluginInterface interface = {
    kAuthorizationPluginInterfaceVersion, plugin_destroy, mechanism_create, invoke, mechanism_deactivate, mechanism_destroy,
};

__attribute__((visibility("default"))) OSStatus AuthorizationPluginCreate(const AuthorizationCallbacks *callbacks, AuthorizationPluginRef *plugin,
                                                                          const AuthorizationPluginInterface **out) {
  if (!callbacks || callbacks->version < kAuthorizationCallbacksVersion) return errAuthorizationInternal;
  Plugin *p = calloc(1, sizeof(Plugin));
  if (!p) return errAuthorizationInternal;
  p->callbacks = callbacks;
  *plugin = p;
  *out = &interface;
  return errAuthorizationSuccess;
}
