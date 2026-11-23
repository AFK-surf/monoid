// A stream's sound on Windows (win_stream.cpp's player) as a rule over its voice: when a packet is queued, when the
// voice starts, when what is queued is let go, and how much it wants queued first (@hostapi.stream_audio_wanted). Plain
// C of no system's: win_stream.cpp gives it XAudio2's source voice and the machine's clock, scripts/win_sound_test.c a
// voice of its own on its own clock.
//
// Its reserve, what is queued before it plays, starts at 100 ms (SOUND_BASE packets of 20 ms). A packet that comes
// late while the voice plays (since the last one, or since it started, longer than the reserve covers) makes it that
// long and a packet more, at most 300 ms (SOUND_MOST): packets of a busy Mac's sound came 50 to 270 ms apart now and
// then, and 60 ms ran dry, heard as a crackle each time. A gap while it does not play drains nothing and raises
// nothing; nor does one of a second or more (the sound paused, not late).
//
// What an app pacing sound by @hostapi.stream_audio_played needs (till 2026-11-15 an app that kept 160 ms ahead of what
// played and gave more only as that played, a replay of a recording's, had no sound again for the window's life once
// the window froze for more than 140 ms, every start waiting for 300 ms that never came):
// - sound_wanted tells the app its reserve in ms (@hostapi.stream_audio_wanted), so an app that paces its packets keeps
//   at least that much queued and starts at once with no timer;
// - each SOUND_CALM_MS with no packet late (more than SOUND_BASE covers) and nothing run dry halves what it is over
//   SOUND_BASE (300 ms back to 100 in 40 s).
#ifndef MB_WIN_SOUND_H
#define MB_WIN_SOUND_H
#include <stddef.h>
#include <stdint.h>

#define SOUND_BASE 5           // the reserve at first and the least: 100 ms
#define SOUND_MOST 15          // the largest: 300 ms
#define SOUND_CALM_MS 10000.0  // each this long calm halves the reserve's excess over SOUND_BASE

// What the player does to its voice.
typedef struct SoundVoice {
  void *it;
  int (*queued)(void *it);                         // buffers queued (the one playing among them)
  int (*submit)(void *it, const uint8_t *packet);  // one 20 ms packet after those queued (0: refused)
  int (*start)(void *it);                          // 0: refused
  void (*flush)(void *it);                         // stopped, what is queued let go
} SoundVoice;

typedef struct SoundPlayer {
  int reserve;  // packets queued before it plays (0: none came yet, SOUND_BASE then)
  int playing;
  double from;  // while it plays: when the last packet came or it started, the later (ms)
  double calm;  // since when no packet came late, nor did it run dry
  double gap;   // the last late packet's gap (ms: what win_stream.cpp's log says)
} SoundPlayer;

// Its voice let go (or made anew): it does not play.
static inline void sound_stopped(SoundPlayer *p) {
  p->playing = 0;
  p->from = 0;
}

// What p's reserve (in packets) is at `now` with `queued` buffers on its voice; writes the updated calm start and any
// new late gap when asked.
static inline int sound_reserve_at(const SoundPlayer *p, int queued, double now, double *calm_out, double *gap_out) {
  if (!p->reserve) {
    if (calm_out) *calm_out = now;
    return SOUND_BASE;
  }
  int reserve = p->reserve;
  double calm = p->calm;
  double gap = (p->playing && p->from > 0) ? now - p->from : 0;
  int paused = gap >= 1000;
  int need = (!paused && gap > 0) ? (int)(gap / 20) + 2 : 0;
  // (each calm stretch completed before any late gap began halves the excess: a pause of a minute brings it back at once)
  double calm_to = (need > SOUND_BASE) ? p->from + (SOUND_BASE - 1) * 20.0 : now;
  while (reserve > SOUND_BASE && calm_to - calm >= SOUND_CALM_MS) {
    reserve = SOUND_BASE + (reserve - SOUND_BASE) / 2;
    calm += SOUND_CALM_MS;
  }
  int dry = p->playing && queued == 0 && !paused;
  // (after reserve shrank, letting the old surplus drain down to the new reserve is not a late packet)
  int late = need > reserve || (need > SOUND_BASE && queued < reserve - 2);
  if (late || dry) {
    calm = now;
    if (need > reserve) {
      reserve = need < SOUND_MOST ? need : SOUND_MOST;
      if (gap_out) *gap_out = gap;
    }
  }
  if (calm_out) *calm_out = calm;
  return reserve;
}

// Milliseconds queued before its voice starts, at `now` (`queued`: buffers on its voice now, 0 when it has none).
static inline double sound_wanted(const SoundPlayer *p, int queued, double now) {
  return (double)sound_reserve_at(p, queued, now, NULL, NULL) * 20.0;
}

// A packet came at `now` (ms) and is queued.
static inline void sound_packet(SoundPlayer *p, const SoundVoice *v, const uint8_t *packet, double now) {
  int queued = v->queued(v->it);
  int dry = p->playing && queued == 0;
  p->reserve = sound_reserve_at(p, queued, now, &p->calm, &p->gap);
  // more than the reserve and 200 ms queued (a stall), or run dry while playing: emptied, the reserve filled again
  if (queued >= p->reserve + 10 || dry) {
    v->flush(v->it);
    p->playing = 0;
    p->from = 0;
    queued = 0;
  }
  if (!v->submit(v->it, packet)) return;
  // started once its reserve is queued
  if (!p->playing && queued + 1 >= p->reserve && v->start(v->it)) p->playing = 1;
  if (p->playing) p->from = now;
}

#endif
