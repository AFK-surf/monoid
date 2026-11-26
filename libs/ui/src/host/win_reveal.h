#ifndef MB_WIN_REVEAL_H
#define MB_WIN_REVEAL_H

// Windows window-reveal and bounded-backoff present retry state machine, shared by win_app.c and win_vbuf_test.cpp.
// Distinguishes SUCCEEDED(hr) (presented == 1, including DXGI_STATUS_OCCLUDED so locked/occluded desktops reveal
// immediately without spinning) from real submission failure (presented == 0, e.g. Map(vbuf) OOM / device loss):
// failed must_present frames retry immediately up to MB_WIN_FAST_PRESENT_RETRIES times, then back off onto the
// message loop's paced_at timer (MB_WIN_RETRY_BACKOFF_MS) so the loop never spins at vsync yet always recovers and
// uncloaks once submission succeeds.

#define MB_WIN_FAST_PRESENT_RETRIES 8
#define MB_WIN_RETRY_BACKOFF_MS 250.0

static inline int mb_win_must_present(int held, int is_win0, int win0_reveal, int window_to_show, int window_shown) {
  return held == 1 || (is_win0 && (win0_reveal == 1 || (window_to_show && !window_shown)));
}

static inline void mb_win_on_present_result(int must_present, int presented, int visible, int is_win0,
                                            int pics_missing, double frame_w, double frame_h, double now_ms,
                                            int *held, int *win0_reveal, int *submitted_this, int *presented_this,
                                            int *present_retries, int *want_frame, double *paced_at,
                                            double *paced_margin) {
  if (presented) {
    *submitted_this = 1;
    *present_retries = 0;
  }
  if (visible) *presented_this = 1;
  if (presented && *held) *held = 2;
  if (presented && is_win0 && *win0_reveal == 1 && !pics_missing && frame_w > 32.0 && frame_h > 32.0) {
    *win0_reveal = 2;
  }
  if (must_present && !presented) {
    if (*present_retries < MB_WIN_FAST_PRESENT_RETRIES) {
      (*present_retries)++;
      *want_frame = 1;
    } else {
      double retry_at = now_ms + MB_WIN_RETRY_BACKOFF_MS;
      if (*paced_at < 0.0 || retry_at < *paced_at) {
        *paced_at = retry_at;
        *paced_margin = 0.0;
      }
    }
  }
}

static inline int mb_win_try_reveal_win0(int *window_to_show, int *window_shown, int has_hwnd, int submitted_this) {
  if (*window_to_show && !*window_shown && has_hwnd && submitted_this) {
    *window_to_show = 0;
    *window_shown = 1;
    return 1;
  }
  return 0;
}

#endif
