// Shared desktop global hotkey accelerator parser (macOS Carbon & Win32 RegisterHotKey).
// Parses strings like "CmdOrCtrl+Shift+Space", "Alt+K", "Ctrl+Alt+1", "Super+P" into
// canonical modifier bits and key ids, rejecting bare keys (no modifier) or unknown tokens.
#ifndef MB_HOTKEY_PARSE_H
#define MB_HOTKEY_PARSE_H
#include <ctype.h>
#include <stdint.h>
#include <string.h>

enum {
  MB_HK_CMD   = 1u << 0,
  MB_HK_CTRL  = 1u << 1,
  MB_HK_ALT   = 1u << 2,
  MB_HK_SHIFT = 1u << 3,
  MB_HK_SUPER = 1u << 4,
};

enum {
  MB_HK_KEY_NONE = 0,
  // '0'..'9' (48..57) and 'A'..'Z' (65..90) use their ASCII codes directly.
  MB_HK_KEY_F1 = 256,
  MB_HK_KEY_F2,
  MB_HK_KEY_F3,
  MB_HK_KEY_F4,
  MB_HK_KEY_F5,
  MB_HK_KEY_F6,
  MB_HK_KEY_F7,
  MB_HK_KEY_F8,
  MB_HK_KEY_F9,
  MB_HK_KEY_F10,
  MB_HK_KEY_F11,
  MB_HK_KEY_F12,
  MB_HK_KEY_SPACE,
  MB_HK_KEY_ENTER,
  MB_HK_KEY_TAB,
  MB_HK_KEY_ESCAPE,
  MB_HK_KEY_UP,
  MB_HK_KEY_DOWN,
  MB_HK_KEY_LEFT,
  MB_HK_KEY_RIGHT,
};

typedef struct mb_hotkey_spec {
  uint32_t mods;
  int key;
} mb_hotkey_spec;

static int mb_hk_ieq(const char *s, size_t n, const char *lit) {
  size_t ln = strlen(lit);
  if (n != ln) return 0;
  for (size_t i = 0; i < n; i++) {
    if (tolower((unsigned char)s[i]) != tolower((unsigned char)lit[i])) return 0;
  }
  return 1;
}

static uint32_t mb_hk_parse_mod(const char *tok, size_t n, int is_macos) {
  if (mb_hk_ieq(tok, n, "CmdOrCtrl") || mb_hk_ieq(tok, n, "CommandOrControl")) {
    return is_macos ? MB_HK_CMD : MB_HK_CTRL;
  }
  if (mb_hk_ieq(tok, n, "Cmd") || mb_hk_ieq(tok, n, "Command")) return MB_HK_CMD;
  if (mb_hk_ieq(tok, n, "Ctrl") || mb_hk_ieq(tok, n, "Control")) return MB_HK_CTRL;
  if (mb_hk_ieq(tok, n, "Alt") || mb_hk_ieq(tok, n, "Option")) return MB_HK_ALT;
  if (mb_hk_ieq(tok, n, "Shift")) return MB_HK_SHIFT;
  if (mb_hk_ieq(tok, n, "Super") || mb_hk_ieq(tok, n, "Meta") || mb_hk_ieq(tok, n, "Win")) return MB_HK_SUPER;
  return 0;
}

static int mb_hk_parse_key(const char *tok, size_t n) {
  if (n == 1) {
    unsigned char c = (unsigned char)tok[0];
    if (c >= 'a' && c <= 'z') return (int)(c - 'a' + 'A');
    if (c >= 'A' && c <= 'Z') return (int)c;
    if (c >= '0' && c <= '9') return (int)c;
    return MB_HK_KEY_NONE;
  }
  if (n >= 2 && n <= 3 && (tok[0] == 'F' || tok[0] == 'f')) {
    int num = 0;
    for (size_t i = 1; i < n; i++) {
      if (tok[i] < '0' || tok[i] > '9') return MB_HK_KEY_NONE;
      num = num * 10 + (tok[i] - '0');
    }
    if (num >= 1 && num <= 12) return MB_HK_KEY_F1 + (num - 1);
    return MB_HK_KEY_NONE;
  }
  if (mb_hk_ieq(tok, n, "Space")) return MB_HK_KEY_SPACE;
  if (mb_hk_ieq(tok, n, "Enter") || mb_hk_ieq(tok, n, "Return")) return MB_HK_KEY_ENTER;
  if (mb_hk_ieq(tok, n, "Tab")) return MB_HK_KEY_TAB;
  if (mb_hk_ieq(tok, n, "Escape") || mb_hk_ieq(tok, n, "Esc")) return MB_HK_KEY_ESCAPE;
  if (mb_hk_ieq(tok, n, "Up")) return MB_HK_KEY_UP;
  if (mb_hk_ieq(tok, n, "Down")) return MB_HK_KEY_DOWN;
  if (mb_hk_ieq(tok, n, "Left")) return MB_HK_KEY_LEFT;
  if (mb_hk_ieq(tok, n, "Right")) return MB_HK_KEY_RIGHT;
  return MB_HK_KEY_NONE;
}

// Parse accelerator string. Returns 1 on success, 0 if invalid or missing modifier/key.
static int mb_hotkey_parse(const char *accel, int is_macos, mb_hotkey_spec *out) {
  if (!accel || !*accel || !out) return 0;
  uint32_t mods = 0;
  int key = MB_HK_KEY_NONE;
  const char *p = accel;
  while (1) {
    const char *plus = strchr(p, '+');
    const char *end = plus ? plus : p + strlen(p);
    const char *s = p;
    while (s < end && isspace((unsigned char)*s)) s++;
    while (end > s && isspace((unsigned char)end[-1])) end--;
    size_t n = (size_t)(end - s);
    if (n == 0) return 0;
    if (plus) {
      uint32_t m = mb_hk_parse_mod(s, n, is_macos);
      if (!m) return 0;
      mods |= m;
      p = plus + 1;
    } else {
      // Final token must be a key, never a modifier.
      if (mb_hk_parse_mod(s, n, is_macos) != 0) return 0;
      key = mb_hk_parse_key(s, n);
      if (key == MB_HK_KEY_NONE) return 0;
      break;
    }
  }
  if (mods == 0 || key == MB_HK_KEY_NONE) return 0;
  out->mods = mods;
  out->key = key;
  return 1;
}

// macOS Carbon virtual keycode for a parsed key, or -1 if unsupported.
static inline int mb_hotkey_mac_keycode(int key) {
  static const int alpha_vk[26] = {
    0x00, // A
    0x0B, // B
    0x08, // C
    0x02, // D
    0x0E, // E
    0x03, // F
    0x05, // G
    0x04, // H
    0x22, // I
    0x26, // J
    0x28, // K
    0x25, // L
    0x2E, // M
    0x2D, // N
    0x1F, // O
    0x23, // P
    0x0C, // Q
    0x0F, // R
    0x01, // S
    0x11, // T
    0x20, // U
    0x09, // V
    0x0D, // W
    0x07, // X
    0x10, // Y
    0x06, // Z
  };
  static const int digit_vk[10] = {
    0x1D, // 0
    0x12, // 1
    0x13, // 2
    0x14, // 3
    0x15, // 4
    0x17, // 5
    0x16, // 6
    0x1A, // 7
    0x1C, // 8
    0x19, // 9
  };
  static const int fn_vk[12] = {
    0x7A, // F1
    0x78, // F2
    0x63, // F3
    0x76, // F4
    0x60, // F5
    0x61, // F6
    0x62, // F7
    0x64, // F8
    0x65, // F9
    0x6D, // F10
    0x67, // F11
    0x6F, // F12
  };
  if (key >= 'A' && key <= 'Z') return alpha_vk[key - 'A'];
  if (key >= '0' && key <= '9') return digit_vk[key - '0'];
  if (key >= MB_HK_KEY_F1 && key <= MB_HK_KEY_F12) return fn_vk[key - MB_HK_KEY_F1];
  switch (key) {
    case MB_HK_KEY_SPACE:  return 0x31;
    case MB_HK_KEY_ENTER:  return 0x24;
    case MB_HK_KEY_TAB:    return 0x30;
    case MB_HK_KEY_ESCAPE: return 0x35;
    case MB_HK_KEY_LEFT:   return 0x7B;
    case MB_HK_KEY_RIGHT:  return 0x7C;
    case MB_HK_KEY_DOWN:   return 0x7D;
    case MB_HK_KEY_UP:     return 0x7E;
    default: return -1;
  }
}

// macOS Carbon modifier flags (cmdKey=1<<8, shiftKey=1<<9, optionKey=1<<11, controlKey=1<<12).
static inline uint32_t mb_hotkey_mac_mods(uint32_t mods) {
  uint32_t out = 0;
  if (mods & (MB_HK_CMD | MB_HK_SUPER)) out |= (1u << 8);
  if (mods & MB_HK_SHIFT) out |= (1u << 9);
  if (mods & MB_HK_ALT) out |= (1u << 11);
  if (mods & MB_HK_CTRL) out |= (1u << 12);
  return out;
}

// Win32 virtual-key code for a parsed key, or -1 if unsupported.
static inline int mb_hotkey_win_vk(int key) {
  if (key >= 'A' && key <= 'Z') return key;
  if (key >= '0' && key <= '9') return key;
  if (key >= MB_HK_KEY_F1 && key <= MB_HK_KEY_F12) return 0x70 + (key - MB_HK_KEY_F1);
  switch (key) {
    case MB_HK_KEY_SPACE:  return 0x20;
    case MB_HK_KEY_ENTER:  return 0x0D;
    case MB_HK_KEY_TAB:    return 0x09;
    case MB_HK_KEY_ESCAPE: return 0x1B;
    case MB_HK_KEY_LEFT:   return 0x25;
    case MB_HK_KEY_UP:     return 0x26;
    case MB_HK_KEY_RIGHT:  return 0x27;
    case MB_HK_KEY_DOWN:   return 0x28;
    default: return -1;
  }
}

// Win32 RegisterHotKey modifier flags (MOD_ALT=1, MOD_CONTROL=2, MOD_SHIFT=4, MOD_WIN=8).
static inline uint32_t mb_hotkey_win_mods(uint32_t mods) {
  uint32_t out = 0;
  if (mods & MB_HK_ALT) out |= 0x0001u;
  if (mods & MB_HK_CTRL) out |= 0x0002u;
  if (mods & MB_HK_SHIFT) out |= 0x0004u;
  if (mods & (MB_HK_CMD | MB_HK_SUPER)) out |= 0x0008u;
  return out;
}

#ifdef MB_HOTKEY_PARSE_TEST
#include <assert.h>
#include <stdio.h>

int main(void) {
  mb_hotkey_spec s;

  // CmdOrCtrl on macOS vs non-macOS
  assert(mb_hotkey_parse("CmdOrCtrl+Shift+Space", 1, &s) == 1);
  assert(s.mods == (MB_HK_CMD | MB_HK_SHIFT));
  assert(s.key == MB_HK_KEY_SPACE);
  assert(mb_hotkey_mac_keycode(s.key) == 0x31);
  assert(mb_hotkey_mac_mods(s.mods) == ((1u << 8) | (1u << 9)));

  assert(mb_hotkey_parse("CmdOrCtrl+Shift+Space", 0, &s) == 1);
  assert(s.mods == (MB_HK_CTRL | MB_HK_SHIFT));
  assert(s.key == MB_HK_KEY_SPACE);
  assert(mb_hotkey_win_vk(s.key) == 0x20);
  assert(mb_hotkey_win_mods(s.mods) == (0x0002u | 0x0004u));

  // Standard combos & case insensitivity
  assert(mb_hotkey_parse("Alt+K", 1, &s) == 1);
  assert(s.mods == MB_HK_ALT && s.key == 'K');
  assert(mb_hotkey_mac_keycode('K') == 0x28);
  assert(mb_hotkey_win_vk('K') == 'K');

  assert(mb_hotkey_parse("ctrl+alt+1", 0, &s) == 1);
  assert(s.mods == (MB_HK_CTRL | MB_HK_ALT) && s.key == '1');
  assert(mb_hotkey_mac_keycode('1') == 0x12);
  assert(mb_hotkey_win_vk('1') == '1');

  assert(mb_hotkey_parse("Super+P", 1, &s) == 1);
  assert(s.mods == MB_HK_SUPER && s.key == 'P');
  assert(mb_hotkey_mac_keycode('P') == 0x23);
  assert(mb_hotkey_win_mods(s.mods) == 0x0008u);

  // Function keys F1-F12
  for (int i = 1; i <= 12; i++) {
    char buf[32];
    snprintf(buf, sizeof buf, "Ctrl+F%d", i);
    assert(mb_hotkey_parse(buf, 0, &s) == 1);
    assert(s.mods == MB_HK_CTRL && s.key == MB_HK_KEY_F1 + (i - 1));
    assert(mb_hotkey_mac_keycode(s.key) >= 0);
    assert(mb_hotkey_win_vk(s.key) == 0x70 + (i - 1));
  }

  // Named keys
  assert(mb_hotkey_parse("Alt+Enter", 1, &s) == 1 && s.key == MB_HK_KEY_ENTER);
  assert(mb_hotkey_parse("Ctrl+Tab", 0, &s) == 1 && s.key == MB_HK_KEY_TAB);
  assert(mb_hotkey_parse("Shift+Escape", 1, &s) == 1 && s.key == MB_HK_KEY_ESCAPE);
  assert(mb_hotkey_parse("Alt+Up", 1, &s) == 1 && s.key == MB_HK_KEY_UP);
  assert(mb_hotkey_parse("Alt+Down", 1, &s) == 1 && s.key == MB_HK_KEY_DOWN);
  assert(mb_hotkey_parse("Alt+Left", 1, &s) == 1 && s.key == MB_HK_KEY_LEFT);
  assert(mb_hotkey_parse("Alt+Right", 1, &s) == 1 && s.key == MB_HK_KEY_RIGHT);

  // Invalid inputs rejected
  assert(mb_hotkey_parse(NULL, 1, &s) == 0);
  assert(mb_hotkey_parse("", 1, &s) == 0);
  assert(mb_hotkey_parse("K", 1, &s) == 0);
  assert(mb_hotkey_parse("Space", 0, &s) == 0);
  assert(mb_hotkey_parse("Ctrl+", 1, &s) == 0);
  assert(mb_hotkey_parse("+K", 1, &s) == 0);
  assert(mb_hotkey_parse("Ctrl++K", 1, &s) == 0);
  assert(mb_hotkey_parse("Ctrl+Shift", 1, &s) == 0);
  assert(mb_hotkey_parse("UnknownMod+K", 1, &s) == 0);
  assert(mb_hotkey_parse("Ctrl+F13", 1, &s) == 0);
  assert(mb_hotkey_parse("Ctrl+F0", 1, &s) == 0);
  assert(mb_hotkey_parse("Ctrl+UnknownKey", 1, &s) == 0);

  printf("hotkey_parse_test: all assertions passed\n");
  return 0;
}
#endif
#endif // MB_HOTKEY_PARSE_H
