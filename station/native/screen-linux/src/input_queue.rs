// Cancellable input queue (coalescing only absolute mouse moves, preserving relative moves and FIFO order
// for clicks/wheel/keys/text, releasing held keys/buttons on close) + 16-slot LRU X11 Unicode keycode pool.

use serde_json::Value;
use std::collections::{HashSet, VecDeque};
use std::sync::{Condvar, Mutex};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MouseKind {
    Move,
    Down,
    Up,
}

#[derive(Debug, Clone, PartialEq)]
pub enum InputOp {
    Mouse {
        kind: MouseKind,
        x: f64,
        y: f64,
        button: u8,
        dx: Option<f64>,
        dy: Option<f64>,
        relative: bool,
    },
    Wheel {
        x: f64,
        y: f64,
        dx: f64,
        dy: f64,
    },
    Key {
        evdev: u32,
        down: bool,
    },
    Text {
        text: String,
    },
}

impl InputOp {
    pub fn parse(v: &Value) -> Option<Self> {
        let f = |k: &str| v[k].as_f64().filter(|n| n.is_finite());
        match v["op"].as_str()? {
            "mouse" => {
                let kind = match v["type"].as_str()? {
                    "move" => MouseKind::Move,
                    "down" => MouseKind::Down,
                    "up" => MouseKind::Up,
                    _ => return None,
                };
                let x = f("x").unwrap_or(0.0);
                let y = f("y").unwrap_or(0.0);
                let button = v["button"].as_u64().unwrap_or(0) as u8;
                let dx = f("dx");
                let dy = f("dy");
                let relative = v["relative"].as_bool().unwrap_or(false);
                Some(InputOp::Mouse {
                    kind,
                    x,
                    y,
                    button,
                    dx,
                    dy,
                    relative,
                })
            }
            "wheel" => Some(InputOp::Wheel {
                x: f("x").unwrap_or(0.0),
                y: f("y").unwrap_or(0.0),
                dx: f("dx").unwrap_or(0.0),
                dy: f("dy").unwrap_or(0.0),
            }),
            "key" => Some(InputOp::Key {
                evdev: v["evdev"].as_u64()? as u32,
                down: v["down"].as_bool()?,
            }),
            "text" => {
                let text = v["text"].as_str()?.to_string();
                if text.is_empty() {
                    None
                } else {
                    Some(InputOp::Text { text })
                }
            }
            _ => None,
        }
    }

    fn is_abs_move(&self) -> bool {
        matches!(
            self,
            InputOp::Mouse {
                kind: MouseKind::Move,
                relative: false,
                ..
            }
        )
    }
}

struct QueueState {
    ops: VecDeque<InputOp>,
    cancelled: bool,
    held_keys: HashSet<u32>,
    held_buttons: HashSet<u8>,
}

/// Thread-safe cancellable input queue.
/// - Absolute mouse moves (`relative == false`) coalesce latest-wins against a trailing absolute move.
/// - Relative mouse moves (`relative == true`) are NEVER coalesced.
/// - Clicks, wheel, keys, and text are strictly FIFO.
/// - `cancel()` immediately drops all queued ops (including pending text) and returns held keys/buttons to release.
pub struct InputQueue {
    state: Mutex<QueueState>,
    cv: Condvar,
}

impl InputQueue {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(QueueState {
                ops: VecDeque::new(),
                cancelled: false,
                held_keys: HashSet::new(),
                held_buttons: HashSet::new(),
            }),
            cv: Condvar::new(),
        }
    }

    pub fn push(&self, op: InputOp) {
        let mut s = self.state.lock().unwrap();
        if s.cancelled {
            return;
        }
        if op.is_abs_move() && s.ops.back().is_some_and(|back| back.is_abs_move()) {
            *s.ops.back_mut().unwrap() = op;
        } else {
            s.ops.push_back(op);
        }
        self.cv.notify_one();
    }

    /// Block until an op is available, or return `None` once cancelled.
    pub fn pop_blocking(&self) -> Option<InputOp> {
        let mut s = self.state.lock().unwrap();
        loop {
            if s.cancelled {
                return None;
            }
            if let Some(op) = s.ops.pop_front() {
                Self::track_held(&mut s, &op);
                return Some(op);
            }
            s = self.cv.wait(s).unwrap();
        }
    }

    /// Non-blocking pop (useful for tests and draining).
    #[cfg(test)]
    pub fn try_pop(&self) -> Option<InputOp> {
        let mut s = self.state.lock().unwrap();
        if s.cancelled {
            return None;
        }
        let op = s.ops.pop_front()?;
        Self::track_held(&mut s, &op);
        Some(op)
    }

    fn track_held(s: &mut QueueState, op: &InputOp) {
        match op {
            InputOp::Key { evdev, down } => {
                if *down {
                    s.held_keys.insert(*evdev);
                } else {
                    s.held_keys.remove(evdev);
                }
            }
            InputOp::Mouse {
                kind: MouseKind::Down,
                button,
                ..
            } => {
                s.held_buttons.insert(*button);
            }
            InputOp::Mouse {
                kind: MouseKind::Up,
                button,
                ..
            } => {
                s.held_buttons.remove(button);
            }
            _ => {}
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.state.lock().unwrap().cancelled
    }

    /// Cancel the queue, discard all pending ops, and wake any blocked worker.
    pub fn cancel(&self) {
        let mut s = self.state.lock().unwrap();
        s.cancelled = true;
        s.ops.clear();
        self.cv.notify_all();
    }

    /// Drain all currently held `(evdev_keys, mouse_buttons)` so the worker can release them on exit.
    pub fn take_held(&self) -> (Vec<u32>, Vec<u8>) {
        let mut s = self.state.lock().unwrap();
        let keys = s.held_keys.drain().collect();
        let buttons = s.held_buttons.drain().collect();
        (keys, buttons)
    }
}

/// 16-slot LRU pool of spare X11 keycodes for Unicode character injection.
pub const SPARE_POOL_SIZE: usize = 16;

struct PoolSlot {
    keycode: u8,
    keysym: Option<u32>,
    last_used: u64,
    dirty: bool,
}

pub struct SpareKeyPool {
    slots: Vec<PoolSlot>,
    tick: u64,
}

impl SpareKeyPool {
    /// Initialize the pool with up to `SPARE_POOL_SIZE` unused X11 keycodes.
    pub fn new(unused_keycodes: &[u8]) -> Self {
        let slots = unused_keycodes
            .iter()
            .take(SPARE_POOL_SIZE)
            .map(|&keycode| PoolSlot {
                keycode,
                keysym: None,
                last_used: 0,
                dirty: false,
            })
            .collect();
        Self { slots, tick: 0 }
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.slots.len()
    }

    /// Acquire a keycode for `keysym`.
    /// Returns `Some((keycode, needs_remap))`, or `None` if the pool has no spare keycodes.
    pub fn acquire(&mut self, keysym: u32) -> Option<(u8, bool)> {
        if self.slots.is_empty() {
            return None;
        }
        self.tick += 1;
        let now = self.tick;

        // 1. Hit existing mapping.
        if let Some(slot) = self.slots.iter_mut().find(|s| s.keysym == Some(keysym)) {
            slot.last_used = now;
            return Some((slot.keycode, false));
        }

        // 2. Pick an empty slot, or evict the least-recently-used slot.
        let idx = self
            .slots
            .iter()
            .position(|s| s.keysym.is_none())
            .unwrap_or_else(|| {
                self.slots
                    .iter()
                    .enumerate()
                    .min_by_key(|(_, s)| s.last_used)
                    .map(|(i, _)| i)
                    .unwrap_or(0)
            });

        let slot = &mut self.slots[idx];
        slot.keysym = Some(keysym);
        slot.last_used = now;
        slot.dirty = true;
        Some((slot.keycode, true))
    }

    /// Keycodes that were modified and should be restored to `NoSymbol` on exit.
    pub fn dirty_keycodes(&self) -> Vec<u8> {
        self.slots
            .iter()
            .filter(|s| s.dirty)
            .map(|s| s.keycode)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn coalesces_abs_move_but_never_relative_move() {
        let q = InputQueue::new();
        q.push(InputOp::parse(&json!({"op":"mouse","type":"move","x":0.1,"y":0.1,"button":0})).unwrap());
        q.push(InputOp::parse(&json!({"op":"mouse","type":"move","x":0.2,"y":0.3,"button":0})).unwrap());
        q.push(InputOp::parse(&json!({"op":"mouse","type":"move","x":0.2,"y":0.3,"button":0,"dx":5,"dy":-3,"relative":true})).unwrap());
        q.push(InputOp::parse(&json!({"op":"mouse","type":"move","x":0.2,"y":0.3,"button":0,"dx":4,"dy":2,"relative":true})).unwrap());
        q.push(InputOp::parse(&json!({"op":"mouse","type":"down","x":0.2,"y":0.3,"button":0})).unwrap());

        assert_eq!(
            q.try_pop(),
            Some(InputOp::Mouse {
                kind: MouseKind::Move,
                x: 0.2,
                y: 0.3,
                button: 0,
                dx: None,
                dy: None,
                relative: false
            })
        );
        assert_eq!(
            q.try_pop(),
            Some(InputOp::Mouse {
                kind: MouseKind::Move,
                x: 0.2,
                y: 0.3,
                button: 0,
                dx: Some(5.0),
                dy: Some(-3.0),
                relative: true
            })
        );
        assert_eq!(
            q.try_pop(),
            Some(InputOp::Mouse {
                kind: MouseKind::Move,
                x: 0.2,
                y: 0.3,
                button: 0,
                dx: Some(4.0),
                dy: Some(2.0),
                relative: true
            })
        );
        assert_eq!(
            q.try_pop(),
            Some(InputOp::Mouse {
                kind: MouseKind::Down,
                x: 0.2,
                y: 0.3,
                button: 0,
                dx: None,
                dy: None,
                relative: false
            })
        );
        assert_eq!(q.try_pop(), None);
    }

    #[test]
    fn cancel_drops_queued_text_and_reports_held_state() {
        let q = InputQueue::new();
        q.push(InputOp::Key { evdev: 29, down: true });
        q.push(InputOp::Mouse {
            kind: MouseKind::Down,
            x: 0.5,
            y: 0.5,
            button: 0,
            dx: None,
            dy: None,
            relative: false,
        });
        q.push(InputOp::Text {
            text: "long queued text".to_string(),
        });

        assert!(q.try_pop().is_some());
        assert!(q.try_pop().is_some());
        // Cancel before text is popped.
        q.cancel();
        assert!(q.is_cancelled());
        assert_eq!(q.try_pop(), None);
        let (keys, buttons) = q.take_held();
        assert_eq!(keys, vec![29]);
        assert_eq!(buttons, vec![0]);
    }

    #[test]
    fn spare_key_pool_lru_and_dirty_restore() {
        let codes: Vec<u8> = (200..220).collect();
        let mut pool = SpareKeyPool::new(&codes);
        assert_eq!(pool.len(), SPARE_POOL_SIZE);

        // Fill 16 slots.
        for i in 0..16u32 {
            let (kc, remap) = pool.acquire(0x0100_4e00 + i).unwrap();
            assert_eq!(kc, 200 + i as u8);
            assert!(remap);
        }
        // Hit slot 0 so slot 1 becomes LRU.
        assert_eq!(pool.acquire(0x0100_4e00), Some((200, false)));
        // Next new keysym evicts slot 1 (keycode 201).
        assert_eq!(pool.acquire(0x0100_9999), Some((201, true)));
        assert_eq!(pool.dirty_keycodes().len(), 16);
    }
}
