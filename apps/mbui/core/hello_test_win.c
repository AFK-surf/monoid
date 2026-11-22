// Windows Hello as the core's secure.* asks it (src/host/win_hello.h), checked where the CI's runner can: what Windows
// says said as the core's hosts say it, the IIDs the header gives its parameterized interfaces made again as WinRT makes
// them (pinterface: SHA-1 of its namespace and the signature, IAsyncOperation<Boolean>'s known one first), the class
// found with those IIDs, no question over a window not shown, and the availability asked for (its answer printed: a
// runner has no Hello, so the prompt itself is a person's to see). scripts/win.sh hello; 0 when all held.
#define WIN32_LEAN_AND_MEAN
#include "win_hello.h"
#include <bcrypt.h>
#include <string.h>

#pragma comment(lib, "bcrypt.lib")

static int bad;

static void same(const char *what, const char *got, const char *want) {
  if ((got == NULL) != (want == NULL) || (got && strcmp(got, want) != 0)) {
    printf("hello: %s said %s, not %s\n", what, got ? got : "(yes)", want ? want : "(yes)");
    bad = 1;
  }
}

// WinRT's IID of a parameterized interface by its signature (UUID v5 of the pinterface namespace, SHA-1)
static int pinterface(const char *sig, GUID *out) {
  static const BYTE ns[16] = {0x11, 0xf4, 0x7a, 0xd5, 0x7b, 0x73, 0x42, 0xc0, 0xab, 0xae, 0x87, 0x8b, 0x1e, 0x16, 0xad, 0xee};
  BYTE h[20];
  BCRYPT_ALG_HANDLE alg = NULL;
  BCRYPT_HASH_HANDLE hash = NULL;
  int ok = BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA1_ALGORITHM, NULL, 0)) &&
           BCRYPT_SUCCESS(BCryptCreateHash(alg, &hash, NULL, 0, NULL, 0, 0)) && BCRYPT_SUCCESS(BCryptHashData(hash, (PUCHAR)ns, 16, 0)) &&
           BCRYPT_SUCCESS(BCryptHashData(hash, (PUCHAR)sig, (ULONG)strlen(sig), 0)) && BCRYPT_SUCCESS(BCryptFinishHash(hash, h, 20, 0));
  if (hash) BCryptDestroyHash(hash);
  if (alg) BCryptCloseAlgorithmProvider(alg, 0);
  if (!ok) return 0;
  h[6] = (BYTE)((h[6] & 0x0f) | 0x50);
  h[8] = (BYTE)((h[8] & 0x3f) | 0x80);
  out->Data1 = ((DWORD)h[0] << 24) | ((DWORD)h[1] << 16) | ((DWORD)h[2] << 8) | h[3];
  out->Data2 = (WORD)((h[4] << 8) | h[5]);
  out->Data3 = (WORD)((h[6] << 8) | h[7]);
  memcpy(out->Data4, h + 8, 8);
  return 1;
}

static void iid_is(const char *what, const char *sig, const IID *have) {
  GUID made;
  if (!pinterface(sig, &made)) {
    printf("hello: SHA-1 made nothing for %s\n", what);
    bad = 1;
  } else if (!IsEqualGUID(&made, have)) {
    printf("hello: %s is {%08lx-%04x-%04x-...}, not as the header has it\n", what, (unsigned long)made.Data1, made.Data2, made.Data3);
    bad = 1;
  }
}

#define OP "pinterface({9fc2b0bb-e446-44e2-aa61-9cab8f636af2};"
#define DONE "pinterface({fcdcf02c-e5d8-4478-915a-4d90b74b83a5};"
#define AVAIL "enum(Windows.Security.Credentials.UI.UserConsentVerifierAvailability;i4))"
#define RESULT "enum(Windows.Security.Credentials.UI.UserConsentVerificationResult;i4))"

int main(void) {
  // what Windows says, as the core's hosts say it
  same("Available", win_hello_availability_error(UserConsentVerifierAvailability_Available), NULL);
  same("DeviceBusy", win_hello_availability_error(UserConsentVerifierAvailability_DeviceBusy), "not_in_front");
  same("DeviceNotPresent", win_hello_availability_error(UserConsentVerifierAvailability_DeviceNotPresent), "no_device_lock");
  same("NotConfiguredForUser", win_hello_availability_error(UserConsentVerifierAvailability_NotConfiguredForUser), "no_device_lock");
  same("DisabledByPolicy", win_hello_availability_error(UserConsentVerifierAvailability_DisabledByPolicy), "no_device_lock");
  same("Verified", win_hello_result_error(UserConsentVerificationResult_Verified), NULL);
  same("Canceled", win_hello_result_error(UserConsentVerificationResult_Canceled), "user_cancelled");
  same("RetriesExhausted", win_hello_result_error(UserConsentVerificationResult_RetriesExhausted), "user_cancelled");
  same("DeviceBusy (asked)", win_hello_result_error(UserConsentVerificationResult_DeviceBusy), "not_in_front");
  same("DeviceNotPresent (asked)", win_hello_result_error(UserConsentVerificationResult_DeviceNotPresent), "no_device_lock");
  same("NotConfiguredForUser (asked)", win_hello_result_error(UserConsentVerificationResult_NotConfiguredForUser), "no_device_lock");
  same("DisabledByPolicy (asked)", win_hello_result_error(UserConsentVerificationResult_DisabledByPolicy), "no_device_lock");
  same("S_OK", win_hello_hresult_error(S_OK), NULL);
  same("E_ABORT", win_hello_hresult_error(E_ABORT), "user_cancelled");
  same("ERROR_CANCELLED", win_hello_hresult_error(HRESULT_FROM_WIN32(ERROR_CANCELLED)), "user_cancelled");
  same("REGDB_E_CLASSNOTREG", win_hello_hresult_error(REGDB_E_CLASSNOTREG), "no_device_lock");
  same("E_NOINTERFACE", win_hello_hresult_error(E_NOINTERFACE), "no_device_lock");
  same("CLASS_E_CLASSNOTAVAILABLE", win_hello_hresult_error(CLASS_E_CLASSNOTAVAILABLE), "no_device_lock");
  same("E_ACCESSDENIED", win_hello_hresult_error(E_ACCESSDENIED), "not_in_front");
  same("ERROR_INVALID_WINDOW_HANDLE", win_hello_hresult_error(HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE)), "not_in_front");
  same("E_FAIL", win_hello_hresult_error(E_FAIL), "windows_hello_0x80004005");

  // the parameterized IIDs, as WinRT makes them (the algorithm first, on IAsyncOperation<Boolean>'s known IID)
  static const IID op_bool = {0xcdb5efb3, 0x5788, 0x509d, {0x9b, 0xe1, 0x71, 0xcc, 0xb8, 0xa3, 0x36, 0x2a}};
  iid_is("IAsyncOperation<Boolean>", OP "b1)", &op_bool);
  iid_is("IAsyncOperation<UserConsentVerifierAvailability>", OP AVAIL, &WIN_HELLO_IID_AVAIL_OP);
  iid_is("its completed handler", DONE AVAIL, &WIN_HELLO_IID_AVAIL_DONE);
  iid_is("IAsyncOperation<UserConsentVerificationResult>", OP RESULT, &WIN_HELLO_IID_RESULT_OP);
  iid_is("its completed handler", DONE RESULT, &WIN_HELLO_IID_RESULT_DONE);

  // the class, by the IIDs the header names its interfaces with (E_NOINTERFACE: one of them is not the class's)
  RoInitialize(RO_INIT_MULTITHREADED);
  IInspectable *statics = NULL, *interop = NULL;
  HRESULT hs = win_hello_factory(&WIN_HELLO_IID_STATICS, (void **)&statics);
  HRESULT hi = win_hello_factory(&WIN_HELLO_IID_INTEROP, (void **)&interop);
  printf("hello: UserConsentVerifier's statics 0x%08lx, its interop 0x%08lx\n", (unsigned long)hs, (unsigned long)hi);
  if (hs == E_NOINTERFACE || hi == E_NOINTERFACE) printf("hello: the class has no such interface (its IID)\n"), bad = 1;
  if (hs != REGDB_E_CLASSNOTREG && FAILED(hs)) printf("hello: the statics not found\n"), bad = 1;
  if (hi != REGDB_E_CLASSNOTREG && FAILED(hi)) printf("hello: the interop not found\n"), bad = 1;
  if (statics) statics->lpVtbl->Release(statics);
  if (interop) interop->lpVtbl->Release(interop);

  // no question over a window not shown
  same("ask over no window", win_hello_ask(NULL, "test"), "not_in_front");
  HWND hidden = CreateWindowExW(0, L"STATIC", L"hello", WS_OVERLAPPED, 0, 0, 100, 100, NULL, NULL, GetModuleHandleW(NULL), NULL);
  if (!hidden) printf("hello: no window made (%lu)\n", GetLastError()), bad = 1;
  else {
    same("ask over a hidden window", win_hello_ask(hidden, "test"), "not_in_front");
    ShowWindow(hidden, SW_MINIMIZE);
    same("ask over a minimized window", win_hello_ask(hidden, "test"), "not_in_front");
    DestroyWindow(hidden);
    same("ask over a window gone", win_hello_ask(hidden, "test"), "not_in_front");
  }

  // the availability, through the completed handler
  const char *avail = win_hello_check();
  printf("hello: Windows Hello here: %s\n", avail ? avail : "available");
  if (avail && strcmp(avail, "no_device_lock") != 0 && strcmp(avail, "not_in_front") != 0) printf("hello: availability said %s\n", avail), bad = 1;
  // and again, on a thread WinRT was begun on already (win_core.c's person thread): the same
  const char *again = win_hello_check();
  same("availability again", again, avail);
  RoUninitialize();

  if (!bad) printf("hello: Windows Hello's answers said as the core's hosts say them, its IIDs WinRT's, nothing asked over no window\n");
  return bad;
}
