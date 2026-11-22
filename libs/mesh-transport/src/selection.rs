//! Prefer a validated direct path without repeatedly returning to a short-lived one.
//! Recovery history follows weak connection identities, not IP ports or peer IDs.
//! A new QUIC connection starts with no history. Backup relay paths remain open.
use crate::hub::Hub;
use iroh::endpoint::transports::{
    FourTuple, PathSelection, PathSelectionConnection, PathSelectionContext, PathSelector,
};
use std::{
    collections::HashMap,
    hash::Hash,
    sync::{Arc, Mutex},
};

use n0_future::time::Instant;

const OBSERVE_MS: u64 = 3_000;
const DIRECT_OBSERVE_MS: u64 = 5_000;
const COOLDOWN_MS: u64 = 30_000;
const STABLE_DIRECT_MS: u64 = 180_000;
const MAX_DIRECT_HOLD_MS: u64 = 1_800_000;
const MAX_TRACKED: usize = 512;
const STALE_PATH_MS: u64 = 3_000;
const STALE_TX_MIN: u64 = 3;
const LIVENESS_IDLE_MS: u64 = 60_000;
const MAX_LIVENESS: usize = 512;
const PROBE_MIN_INTERVAL_MS: u64 = 1_000;
const PROBE_IN_FLIGHT_MS: u64 = 2_000;
const PROBE_BUDGET_MAX: u8 = 6;
const PROBE_BACKOFF_MS: u64 = 30_000;
const MAX_PROBES: usize = 512;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Direct,
    Transit,
}
impl Kind {
    fn of(path: &FourTuple) -> Self {
        if matches!(path, FourTuple::Ip { .. }) {
            Self::Direct
        } else {
            Self::Transit
        }
    }
    fn margin(self, next: Self, current_us: u64) -> u64 {
        match (self, next) {
            (Self::Transit, Self::Direct) => 2_000.max(current_us / 20),
            (Self::Direct, Self::Transit) => 15_000.max(current_us / 4),
            _ => 10_000.max(current_us / 5),
        }
    }
    fn observation(self, next: Self) -> u64 {
        if self == Self::Transit && next == Self::Direct {
            DIRECT_OBSERVE_MS
        } else {
            OBSERVE_MS
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Sample<S> {
    connection: S,
    generation: u64,
    epoch: u64,
    sequence: u64,
    rtt_us: u64,
}
impl<S: Eq> Sample<S> {
    fn same_source(&self, other: &Self) -> bool {
        self.connection == other.connection
            && self.generation == other.generation
            && self.epoch == other.epoch
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum GateOutcome {
    Rejected,
    Armed,
    Observing,
    Stalled,
    Ready,
}

#[derive(Debug)]
struct Gate<T, S> {
    candidate: Option<T>,
    compared: Option<(Sample<S>, Sample<S>)>,
    since: u64,
    cooldown: u64,
    touched: u64,
}
impl<T: Eq + Clone, S: Eq + Clone> Gate<T, S> {
    fn new(now: u64) -> Self {
        Self {
            candidate: None,
            compared: None,
            since: now,
            cooldown: 0,
            touched: now,
        }
    }
    fn reset(&mut self) {
        self.candidate = None;
        self.compared = None;
    }
    #[cfg(test)]
    fn consider(
        &mut self,
        candidate: T,
        current: Sample<S>,
        next: Sample<S>,
        now: u64,
        kinds: (Kind, Kind),
    ) -> bool {
        self.consider_outcome(candidate, current, next, now, kinds) == GateOutcome::Ready
    }
    fn consider_outcome(
        &mut self,
        candidate: T,
        current: Sample<S>,
        next: Sample<S>,
        now: u64,
        kinds: (Kind, Kind),
    ) -> GateOutcome {
        self.touched = now;
        let gain = next
            .rtt_us
            .checked_add(kinds.0.margin(kinds.1, current.rtt_us))
            .is_some_and(|required| required <= current.rtt_us);
        if !gain || now < self.cooldown || current.sequence == 0 || next.sequence == 0 {
            self.reset();
            return GateOutcome::Rejected;
        }
        let same_sources = self
            .compared
            .as_ref()
            .is_some_and(|(old_current, old_next)| {
                current.same_source(old_current)
                    && next.same_source(old_next)
                    && current.sequence >= old_current.sequence
                    && next.sequence >= old_next.sequence
            });
        if self.candidate.as_ref() != Some(&candidate) || !same_sources {
            self.candidate = Some(candidate);
            self.compared = Some((current, next));
            self.since = now;
            return GateOutcome::Armed;
        }
        let (old_current, old_next) = self.compared.as_ref().unwrap();
        // Repeated snapshots and PATH_RESPONSE estimates cannot advance evidence.
        if current.sequence == old_current.sequence || next.sequence == old_next.sequence {
            return GateOutcome::Stalled;
        }
        self.compared = Some((current, next));
        if now.saturating_sub(self.since) >= kinds.0.observation(kinds.1) {
            GateOutcome::Ready
        } else {
            GateOutcome::Observing
        }
    }
}

#[derive(Clone, Debug)]
struct Candidate<T, S> {
    path: T,
    kind: Kind,
    sample: Sample<S>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Traffic {
    rx_frames: u64,
    tx_datagrams: u64,
}

#[derive(Clone, Debug)]
struct Activity<T, S> {
    path: T,
    connection: S,
    generation: u64,
    traffic: Traffic,
}

/// Per-connection path reception progress, kept apart from `Gate` observations.
/// Long RTTs, burst loss, or scheduling stalls can still trip the threshold. That
/// only yields when a non-stale measured alternative exists, and any new inbound
/// authenticated frame clears staleness at once.
#[derive(Clone, Debug)]
struct PathLiveness<T, S> {
    connection: S,
    path: T,
    generation: u64,
    rx_frames: u64,
    last_rx_at: u64,
    tx_at_last_rx: u64,
    last_tx: u64,
    touched: u64,
}
impl<T, S> PathLiveness<T, S> {
    fn new(connection: S, path: T, generation: u64, traffic: Traffic, now: u64) -> Self {
        Self {
            connection,
            path,
            generation,
            rx_frames: traffic.rx_frames,
            last_rx_at: now,
            tx_at_last_rx: traffic.tx_datagrams,
            last_tx: traffic.tx_datagrams,
            touched: now,
        }
    }
    fn reset(&mut self, generation: u64, traffic: Traffic, now: u64) {
        self.generation = generation;
        self.rx_frames = traffic.rx_frames;
        self.last_rx_at = now;
        self.tx_at_last_rx = traffic.tx_datagrams;
        self.last_tx = traffic.tx_datagrams;
        self.touched = now;
    }
    fn observe(&mut self, generation: u64, traffic: Traffic, now: u64) {
        if self.generation != generation
            || traffic.rx_frames < self.rx_frames
            || traffic.tx_datagrams < self.last_tx
            || traffic.rx_frames > self.rx_frames
        {
            self.reset(generation, traffic, now);
            return;
        }
        self.last_tx = traffic.tx_datagrams;
        self.touched = now;
    }
    fn is_stale(&self, now: u64) -> bool {
        now.saturating_sub(self.last_rx_at) >= STALE_PATH_MS
            && self.last_tx.saturating_sub(self.tx_at_last_rx) >= STALE_TX_MIN
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ProbeTarget<T, S> {
    connection: S,
    path: T,
    generation: u64,
}

/// Per-(connection, path) single-path probe budget, ceiling, and in-flight guard.
/// Kept apart from `Gate` and across temporary RTT absence or generation churn so neither
/// gate resets nor path flapping can refill an exhausted budget before backoff expires.
#[derive(Clone, Debug)]
struct ProbeState<T, S> {
    connection: S,
    path: T,
    generation: u64,
    epoch: u64,
    last_sequence: u64,
    probe_seq_ceiling: u64,
    last_advance_at: Option<u64>,
    in_flight: Option<(u64, u64)>,
    last_sent_at: Option<u64>,
    remaining: u8,
    backoff_until: u64,
    saw_independent_evidence: bool,
    touched: u64,
}
impl<T, S> ProbeState<T, S> {
    fn new(connection: S, path: T, sample: &Sample<S>, now: u64) -> Self {
        Self {
            connection,
            path,
            generation: sample.generation,
            epoch: sample.epoch,
            last_sequence: sample.sequence,
            probe_seq_ceiling: sample.sequence,
            last_advance_at: None,
            in_flight: None,
            last_sent_at: None,
            remaining: PROBE_BUDGET_MAX,
            backoff_until: 0,
            saw_independent_evidence: false,
            touched: now,
        }
    }
    fn observe(&mut self, sample: &Sample<S>, now: u64) {
        self.touched = now;
        if sample.generation != self.generation {
            self.generation = sample.generation;
            self.epoch = sample.epoch;
            self.last_sequence = sample.sequence;
            self.probe_seq_ceiling = sample.sequence;
            self.last_advance_at = None;
            self.in_flight = None;
            self.last_sent_at = None;
        } else if sample.epoch != self.epoch || sample.sequence < self.last_sequence {
            // Same-generation RTT epoch reset (for example after a cross-path ACK in `noq`):
            // carry unanswered probe debt into the new sequence space so late on-path probe ACKs
            // from the previous epoch cannot be misread as independent ACK progress.
            let unanswered = self.probe_seq_ceiling.saturating_sub(self.last_sequence);
            self.in_flight = None;
            self.epoch = sample.epoch;
            self.last_sequence = sample.sequence;
            self.probe_seq_ceiling = sample.sequence.saturating_add(unanswered);
            self.last_advance_at = (sample.sequence != 0).then_some(now);
        } else if sample.sequence > self.last_sequence {
            if let Some((sent_seq, sent_at)) = self.in_flight
                && (sample.sequence > sent_seq
                    || now.saturating_sub(sent_at) >= PROBE_IN_FLIGHT_MS)
            {
                self.in_flight = None;
            }
            if sample.sequence > self.probe_seq_ceiling {
                self.saw_independent_evidence = true;
            }
            self.last_sequence = sample.sequence;
            self.probe_seq_ceiling = self.probe_seq_ceiling.max(sample.sequence);
            self.last_advance_at = Some(now);
        } else if let Some((_, sent_at)) = self.in_flight
            && now.saturating_sub(sent_at) >= PROBE_IN_FLIGHT_MS
        {
            self.in_flight = None;
        }
        if self.saw_independent_evidence && now >= self.backoff_until {
            self.remaining = PROBE_BUDGET_MAX;
            self.backoff_until = 0;
            self.saw_independent_evidence = false;
        }
    }
    fn has_recent_advance(&self, now: u64) -> bool {
        self.last_advance_at
            .is_some_and(|at| now.saturating_sub(at) < PROBE_MIN_INTERVAL_MS)
    }
    fn try_send(&mut self, now: u64) -> bool {
        if self.has_recent_advance(now) || self.in_flight.is_some() || now < self.backoff_until {
            return false;
        }
        if self
            .last_sent_at
            .is_some_and(|sent_at| now.saturating_sub(sent_at) < PROBE_MIN_INTERVAL_MS)
        {
            return false;
        }
        if self.remaining > 0 {
            self.remaining -= 1;
            if self.remaining == 0 {
                self.backoff_until = now.saturating_add(PROBE_BACKOFF_MS);
                self.saw_independent_evidence = false;
            }
        } else {
            // Post-backoff liveness guarantee: emit at most one probe per PROBE_BACKOFF_MS
            // without refilling `remaining` until genuine independent ACK progress arrives.
            self.backoff_until = now.saturating_add(PROBE_BACKOFF_MS);
        }
        self.probe_seq_ceiling = self
            .probe_seq_ceiling
            .max(self.last_sequence)
            .saturating_add(1);
        self.in_flight = Some((self.probe_seq_ceiling.saturating_sub(1), now));
        self.last_sent_at = Some(now);
        true
    }
}

#[derive(Debug)]
struct Stay<T, S> {
    path: T,
    kind: Kind,
    since: u64,
    last_sample: Option<Sample<S>>,
    evidence_since: u64,
}

/// Separate from observation gates: changing paths must not erase a failed direct attempt.
#[derive(Debug)]
struct Recovery<T, S> {
    connection: S,
    stay: Option<Stay<T, S>>,
    delay: u64,
    direct_until: u64,
    cooldown: u64,
    touched: u64,
}
impl<T: Eq + Clone, S: Eq + Clone> Recovery<T, S> {
    fn new(connection: S, now: u64) -> Self {
        Self {
            connection,
            stay: None,
            delay: COOLDOWN_MS,
            direct_until: 0,
            cooldown: 0,
            touched: now,
        }
    }
    fn selected(&mut self, path: &T, kind: Kind, sample: Option<&Sample<S>>, now: u64) {
        self.stay = Some(Stay {
            path: path.clone(),
            kind,
            since: now,
            last_sample: sample.cloned(),
            evidence_since: now,
        });
    }
    fn observe(
        &mut self,
        current: Option<(&T, Kind)>,
        seen: bool,
        sample: Option<&Sample<S>>,
        now: u64,
    ) -> bool {
        self.touched = now;
        if !seen {
            // Consume this transition once, even if no replacement is available yet.
            if self
                .stay
                .as_ref()
                .is_some_and(|stay| current.is_none_or(|(p, _)| &stay.path == p))
                && let Some(stay) = self.stay.take()
                && stay.kind == Kind::Direct
                && now.saturating_sub(stay.since) < STABLE_DIRECT_MS
            {
                self.delay = self.delay.saturating_mul(2).min(MAX_DIRECT_HOLD_MS);
                self.direct_until = now.saturating_add(self.delay);
            }
            return false;
        }
        let Some((path, kind)) = current else {
            return false;
        };
        if self.stay.as_ref().is_none_or(|stay| &stay.path != path) {
            self.selected(path, kind, sample, now);
            return false;
        }
        let stay = self.stay.as_mut().unwrap();
        if kind != Kind::Direct {
            return false;
        }
        let Some(sample) = sample.filter(|s| s.sequence != 0) else {
            return false;
        };
        let Some(old) = &stay.last_sample else {
            stay.evidence_since = now;
            stay.last_sample = Some(sample.clone());
            return false;
        };
        if !sample.same_source(old) || sample.sequence < old.sequence || old.sequence == 0 {
            stay.evidence_since = now;
        } else if sample.sequence > old.sequence
            && now.saturating_sub(stay.evidence_since) >= STABLE_DIRECT_MS
        {
            // Wall time alone cannot erase the failure history.
            self.delay = COOLDOWN_MS;
            self.direct_until = 0;
        }
        let needs_confirmation = (self.delay > COOLDOWN_MS || self.direct_until > 0)
            && sample.same_source(old)
            && sample.sequence == old.sequence
            && now.saturating_sub(stay.since) >= STABLE_DIRECT_MS
            && now.saturating_sub(stay.evidence_since) >= STABLE_DIRECT_MS;
        stay.last_sample = Some(sample.clone());
        needs_confirmation
    }
}

#[derive(Debug)]
struct Policy<T, S> {
    gates: HashMap<T, Gate<T, S>>,
    recovery: Vec<Recovery<T, S>>,
    liveness: Vec<PathLiveness<T, S>>,
    probes: Vec<ProbeState<T, S>>,
}
impl<T: Eq + Hash + Clone, S: Eq + Clone> Policy<T, S> {
    fn new() -> Self {
        Self {
            gates: HashMap::new(),
            recovery: Vec::new(),
            liveness: Vec::new(),
            probes: Vec::new(),
        }
    }
    fn reset(&mut self, current: Option<(&T, Kind)>) {
        if let Some((path, _)) = current
            && let Some(gate) = self.gates.get_mut(path)
        {
            gate.reset();
        }
    }
    fn update_liveness(&mut self, activities: &[Activity<T, S>], connections: &[S], now: u64) {
        // `Selector` is shared across remote peers while `connections` only names the peer
        // in this `select` call. Drop absent paths for this peer immediately, and expire
        // other peers or closed connections by idle age.
        self.liveness.retain(|entry| {
            if connections.contains(&entry.connection) {
                activities
                    .iter()
                    .any(|a| a.connection == entry.connection && a.path == entry.path)
            } else {
                now.saturating_sub(entry.touched) < LIVENESS_IDLE_MS
            }
        });
        // Refresh existing active entries before capacity eviction inspects `touched`.
        for act in activities {
            if !connections.contains(&act.connection) {
                continue;
            }
            if let Some(entry) = self
                .liveness
                .iter_mut()
                .find(|e| e.connection == act.connection && e.path == act.path)
            {
                entry.observe(act.generation, act.traffic, now);
            }
        }
        for act in activities {
            if !connections.contains(&act.connection)
                || self
                    .liveness
                    .iter()
                    .any(|e| e.connection == act.connection && e.path == act.path)
            {
                continue;
            }
            if self.liveness.len() >= MAX_LIVENESS {
                if let Some((oldest, _)) = self
                    .liveness
                    .iter()
                    .enumerate()
                    .filter(|(_, e)| !connections.contains(&e.connection))
                    .min_by_key(|(_, e)| e.touched)
                {
                    self.liveness.remove(oldest);
                } else {
                    continue;
                }
            }
            self.liveness.push(PathLiveness::new(
                act.connection.clone(),
                act.path.clone(),
                act.generation,
                act.traffic,
                now,
            ));
        }
    }
    /// Selected paths are shared per remote peer. A tuple is stale only when at least
    /// one active connection observes it and every active connection on it is tracked
    /// and stale.
    fn is_tuple_stale(
        &self,
        path: &T,
        activities: &[Activity<T, S>],
        connections: &[S],
        now: u64,
    ) -> bool {
        let mut any = false;
        for act in activities
            .iter()
            .filter(|a| &a.path == path && connections.contains(&a.connection))
        {
            any = true;
            let Some(entry) = self
                .liveness
                .iter()
                .find(|e| e.connection == act.connection && e.path == act.path)
            else {
                return false;
            };
            if !entry.is_stale(now) {
                return false;
            }
        }
        any
    }
    /// Pure decision step. The adapter supplies a monotonic elapsed time and selectable paths.
    #[cfg(test)]
    fn choose(
        &mut self,
        current: Option<(&T, Kind)>,
        seen: bool,
        paths: &[Candidate<T, S>],
        connections: &[S],
        now: u64,
    ) -> Option<usize> {
        self.choose_observed(current, seen, paths, &[], connections, now)
            .0
    }
    #[cfg(test)]
    fn update_probes(&mut self, paths: &[Candidate<T, S>], connections: &[S], now: u64) {
        self.update_probes_with_activities(paths, &[], connections, now);
    }
    fn update_probes_with_activities(
        &mut self,
        paths: &[Candidate<T, S>],
        activities: &[Activity<T, S>],
        connections: &[S],
        now: u64,
    ) {
        // Keep per-(connection, path) budget debt across temporary `same_path_rtt == None`
        // snapshots and short path flaps, expiring idle records by `LIVENESS_IDLE_MS` (60 s).
        self.probes
            .retain(|entry| now.saturating_sub(entry.touched) < LIVENESS_IDLE_MS);
        for entry in &mut self.probes {
            if !connections.contains(&entry.connection) {
                continue;
            }
            if let Some(p) = paths.iter().find(|p| {
                p.sample.connection == entry.connection
                    && p.path == entry.path
                    && p.sample.sequence != 0
            }) {
                entry.observe(&p.sample, now);
            } else if let Some(act) = activities
                .iter()
                .find(|a| a.connection == entry.connection && a.path == entry.path)
            {
                entry.touched = now;
                if act.generation != entry.generation {
                    // Leave `entry.generation` for `observe()` so the first sample of a true new
                    // generation resets sequence state instead of taking the same-generation epoch branch.
                    entry.in_flight = None;
                    entry.last_sent_at = None;
                    entry.last_advance_at = None;
                } else if let Some((_, sent_at)) = entry.in_flight
                    && now.saturating_sub(sent_at) >= PROBE_IN_FLIGHT_MS
                {
                    entry.in_flight = None;
                }
            } else {
                entry.in_flight = None;
            }
        }
    }
    fn ensure_probe_state(
        &mut self,
        path: &T,
        sample: &Sample<S>,
        connections: &[S],
        now: u64,
    ) -> Option<usize> {
        if let Some(idx) = self
            .probes
            .iter()
            .position(|e| e.connection == sample.connection && &e.path == path)
        {
            if self.probes[idx].generation != sample.generation {
                self.probes[idx].observe(sample, now);
            }
            return Some(idx);
        }
        if self.probes.len() >= MAX_PROBES {
            let (oldest, _) = self
                .probes
                .iter()
                .enumerate()
                .filter(|(_, e)| !connections.contains(&e.connection))
                .min_by_key(|(_, e)| e.touched)?;
            self.probes.remove(oldest);
        }
        self.probes.push(ProbeState::new(
            sample.connection.clone(),
            path.clone(),
            sample,
            now,
        ));
        Some(self.probes.len() - 1)
    }
    fn maybe_request_probe(
        &mut self,
        probes: &mut Vec<ProbeTarget<T, S>>,
        path: &T,
        sample: &Sample<S>,
        connections: &[S],
        now: u64,
    ) {
        let target = ProbeTarget {
            connection: sample.connection.clone(),
            path: path.clone(),
            generation: sample.generation,
        };
        if probes.contains(&target) {
            return;
        }
        let Some(idx) = self.ensure_probe_state(path, sample, connections, now) else {
            return;
        };
        if self.probes[idx].try_send(now) {
            probes.push(target);
        }
    }
    fn collect_recovery_probes(
        &mut self,
        pending: &[(T, Sample<S>)],
        connections: &[S],
        now: u64,
    ) -> Vec<ProbeTarget<T, S>> {
        let mut probes = Vec::new();
        for (path, sample) in pending {
            self.maybe_request_probe(&mut probes, path, sample, connections, now);
        }
        probes
    }
    fn choose_observed(
        &mut self,
        current: Option<(&T, Kind)>,
        seen: bool,
        paths: &[Candidate<T, S>],
        activities: &[Activity<T, S>],
        connections: &[S],
        now: u64,
    ) -> (Option<usize>, Vec<ProbeTarget<T, S>>) {
        self.update_liveness(activities, connections, now);
        self.update_probes_with_activities(paths, activities, connections, now);
        // Retain long holds. Every active connection is touched, including when the current path wins.
        self.recovery.retain(|r| {
            connections.contains(&r.connection)
                || now.saturating_sub(r.touched) <= MAX_DIRECT_HOLD_MS
        });
        // Refresh existing active records before capacity eviction considers their age.
        for r in self
            .recovery
            .iter_mut()
            .filter(|r| connections.contains(&r.connection))
        {
            r.touched = now;
        }
        for connection in connections {
            if !self.recovery.iter().any(|r| &r.connection == connection) {
                if self.recovery.len() == MAX_TRACKED {
                    let oldest = self
                        .recovery
                        .iter()
                        .enumerate()
                        .min_by_key(|(_, r)| r.touched)
                        .unwrap()
                        .0;
                    self.recovery.remove(oldest);
                }
                self.recovery.push(Recovery::new(connection.clone(), now));
            }
        }
        let live_best = paths
            .iter()
            .enumerate()
            .filter(|(_, p)| !self.is_tuple_stale(&p.path, activities, connections, now))
            .min_by_key(|(_, p)| p.sample.rtt_us)
            .map(|(i, _)| i);
        let any_best = paths
            .iter()
            .enumerate()
            .min_by_key(|(_, p)| p.sample.rtt_us)
            .map(|(i, _)| i);
        let current_stale = seen
            && current
                .is_some_and(|(path, _)| self.is_tuple_stale(path, activities, connections, now));
        let stale_rescue = current_stale && live_best.is_some();
        let effective_seen = seen && !stale_rescue;
        let mut recovery_pending = Vec::new();
        for r in self
            .recovery
            .iter_mut()
            .filter(|r| connections.contains(&r.connection))
        {
            let sample = current
                .and_then(|(path, _)| {
                    paths
                        .iter()
                        .find(|p| &p.path == path && p.sample.connection == r.connection)
                })
                .map(|p| &p.sample);
            if r.observe(current, effective_seen, sample, now)
                && let Some((path, _)) = current
                && let Some(s) = sample
            {
                recovery_pending.push((path.clone(), s.clone()));
            }
        }
        if let Some((path, _)) = current
            && let Some(gate) = self.gates.get_mut(path)
        {
            gate.touched = now;
        }
        self.gates
            .retain(|_, gate| now.saturating_sub(gate.touched) < 60_000);
        if !seen || stale_rescue {
            let best = live_best.or(any_best);
            self.reset(current);
            if let Some(i) = best {
                self.switched(current, &paths[i], paths, connections, now);
            }
            return (best, Vec::new());
        }
        if current_stale {
            self.reset(current);
            return (None, Vec::new());
        }
        let Some((current_path, current_kind)) = current else {
            return (None, Vec::new());
        };
        let Some(current_sample) = paths
            .iter()
            .filter(|p| &p.path == current_path && p.sample.sequence != 0)
            .min_by_key(|p| p.sample.rtt_us)
            .map(|p| &p.sample)
        else {
            self.reset(current);
            return (None, Vec::new());
        };
        let cooldown = self
            .recovery
            .iter()
            .filter(|r| connections.contains(&r.connection))
            .map(|r| r.cooldown)
            .max()
            .unwrap_or(0);
        let direct_until = self
            .recovery
            .iter()
            .filter(|r| connections.contains(&r.connection))
            .map(|r| r.direct_until)
            .max()
            .unwrap_or(0);
        // Keep the observed sample sources while they still qualify. Microsecond jitter
        // between connections must not restart an otherwise continuous observation.
        let pinned = self.gates.get(current_path).and_then(|gate| {
            let candidate = gate.candidate.as_ref()?;
            if self.is_tuple_stale(candidate, activities, connections, now) {
                return None;
            }
            let (old_current, old_next) = gate.compared.as_ref()?;
            let current = paths.iter().find(|p| {
                &p.path == current_path
                    && p.sample.same_source(old_current)
                    && p.sample.sequence >= old_current.sequence
                    && p.sample.sequence != 0
            })?;
            let (index, next) = paths.iter().enumerate().find(|(_, p)| {
                &p.path == candidate
                    && p.sample.same_source(old_next)
                    && p.sample.sequence >= old_next.sequence
                    && p.sample.sequence != 0
            })?;
            let allowed = now >= cooldown
                && !(current_kind == Kind::Transit
                    && next.kind == Kind::Direct
                    && now < direct_until)
                && next
                    .sample
                    .rtt_us
                    .checked_add(current_kind.margin(next.kind, current.sample.rtt_us))
                    .is_some_and(|required| required <= current.sample.rtt_us);
            allowed.then_some((&current.sample, index, next))
        });
        let current_sample = pinned
            .as_ref()
            .map(|(sample, _, _)| *sample)
            .unwrap_or(current_sample);
        // Filter before ranking: a relay that fails its margin must not hide an eligible IP path.
        let eligible = paths
            .iter()
            .enumerate()
            .filter(|(_, p)| {
                &p.path != current_path
                    && !self.is_tuple_stale(&p.path, activities, connections, now)
                    && p.sample.sequence != 0
                    && now >= cooldown
                    && !(current_kind == Kind::Transit
                        && p.kind == Kind::Direct
                        && now < direct_until)
                    && p.sample
                        .rtt_us
                        .checked_add(current_kind.margin(p.kind, current_sample.rtt_us))
                        .is_some_and(|required| required <= current_sample.rtt_us)
            })
            .min_by_key(|(_, p)| p.sample.rtt_us);
        let Some((i, next)) = eligible else {
            self.reset(current);
            let probes = self.collect_recovery_probes(&recovery_pending, connections, now);
            return (None, probes);
        };
        // Still rank different network paths. A genuinely faster eligible path starts
        // its own observation, while another sample of this candidate keeps its sources.
        let (i, next) = match pinned {
            Some((_, index, pinned_next)) if pinned_next.path == next.path => (index, pinned_next),
            _ => (i, next),
        };
        // Capacity exhaustion keeps a working path, but never blocks the failure branch above.
        if !self.gates.contains_key(current_path) && self.gates.len() >= MAX_TRACKED {
            let probes = self.collect_recovery_probes(&recovery_pending, connections, now);
            return (None, probes);
        }
        let current_sample = current_sample.clone();
        let next_path = next.path.clone();
        let next_sample = next.sample.clone();
        let next_kind = next.kind;
        let gate = self
            .gates
            .entry(current_path.clone())
            .or_insert_with(|| Gate::new(now));
        gate.cooldown = cooldown;
        let outcome = gate.consider_outcome(
            next_path.clone(),
            current_sample.clone(),
            next_sample.clone(),
            now,
            (current_kind, next_kind),
        );
        let gate_since = gate.since;
        match outcome {
            GateOutcome::Rejected => {
                let probes = self.collect_recovery_probes(&recovery_pending, connections, now);
                (None, probes)
            }
            GateOutcome::Armed => {
                let _ = self.ensure_probe_state(current_path, &current_sample, connections, now);
                let _ = self.ensure_probe_state(&next_path, &next_sample, connections, now);
                let probes = self.collect_recovery_probes(&recovery_pending, connections, now);
                (None, probes)
            }
            GateOutcome::Observing => {
                let probes = self.collect_recovery_probes(&recovery_pending, connections, now);
                (None, probes)
            }
            GateOutcome::Stalled => {
                let mut probes = self.collect_recovery_probes(&recovery_pending, connections, now);
                let observation = current_kind.observation(next_kind);
                if now
                    .saturating_sub(gate_since)
                    .saturating_add(PROBE_MIN_INTERVAL_MS)
                    >= observation
                {
                    self.maybe_request_probe(
                        &mut probes,
                        current_path,
                        &current_sample,
                        connections,
                        now,
                    );
                    self.maybe_request_probe(
                        &mut probes,
                        &next_path,
                        &next_sample,
                        connections,
                        now,
                    );
                }
                (None, probes)
            }
            GateOutcome::Ready => {
                self.switched(current, &paths[i], paths, connections, now);
                (Some(i), Vec::new())
            }
        }
    }
    fn switched(
        &mut self,
        current: Option<(&T, Kind)>,
        next: &Candidate<T, S>,
        paths: &[Candidate<T, S>],
        connections: &[S],
        now: u64,
    ) {
        self.switched_to(current, &next.path, next.kind, paths, connections, now);
    }
    fn switched_to(
        &mut self,
        current: Option<(&T, Kind)>,
        next: &T,
        kind: Kind,
        paths: &[Candidate<T, S>],
        connections: &[S],
        now: u64,
    ) {
        if let Some((path, _)) = current {
            self.gates.remove(path);
        }
        for r in self
            .recovery
            .iter_mut()
            .filter(|r| connections.contains(&r.connection))
        {
            let sample = paths
                .iter()
                .find(|p| &p.path == next && p.sample.connection == r.connection)
                .map(|p| &p.sample);
            r.selected(next, kind, sample, now);
            if current.is_some() {
                r.cooldown = now.saturating_add(COOLDOWN_MS);
            }
        }
    }
}

// A missing same-path RTT is not a dead native path: the latest ACK may have
// returned on another path. Keep Custom's inner validation requirement on rescue.
fn unmeasured_fallback<T>(
    has_current: bool,
    current_seen: bool,
    has_rtt: bool,
    native: Option<T>,
    first: Option<T>,
) -> Option<T> {
    if current_seen || has_rtt {
        None
    } else if has_current {
        native
    } else {
        first
    }
}

#[derive(Debug)]
pub struct Selector {
    hub: Arc<Hub>,
    epoch: Instant,
    trace_routing: bool,
    policy: Mutex<Policy<FourTuple, PathSelectionConnection>>,
}
impl Selector {
    pub fn new(hub: Arc<Hub>) -> Self {
        Self {
            hub,
            epoch: Instant::now(),
            trace_routing: std::env::var_os("MESH_TRACE_ROUTING").is_some(),
            policy: Mutex::new(Policy::new()),
        }
    }
}
impl PathSelector for Selector {
    fn select(&self, ctx: &PathSelectionContext<'_>) -> PathSelection {
        let now = self.epoch.elapsed().as_millis().min(u64::MAX as u128) as u64;
        let mut paths = Vec::new();
        let mut activities = Vec::new();
        let mut data = Vec::new();
        let mut connections = Vec::new();
        let mut first = None;
        let mut first_native = None;
        let mut current_seen = false;
        for path in ctx.paths() {
            // Include identities without RTTs so that an absent direct path is observed promptly.
            if let Some(connection) = path.connection()
                && !connections.contains(&connection)
            {
                connections.push(connection);
            }
            if !self.hub.selectable(&path.network_path().remote()) {
                continue;
            }
            current_seen |= Some(path.network_path()) == ctx.current();
            if first.is_none() {
                first = Some(path.clone());
            }
            let Some(stats) = path.stats() else { continue };
            if first_native.is_none() && !matches!(path.network_path(), FourTuple::Custom { .. }) {
                first_native = Some(path.clone());
            }
            let Some(connection) = path.connection() else {
                continue;
            };
            let f = &stats.frame_rx;
            let rx_frames = f
                .acks
                .saturating_add(f.path_acks)
                .saturating_add(f.ack_frequency)
                .saturating_add(f.crypto)
                .saturating_add(f.connection_close)
                .saturating_add(f.data_blocked)
                .saturating_add(f.datagram)
                .saturating_add(u64::from(f.handshake_done))
                .saturating_add(f.immediate_ack)
                .saturating_add(f.max_data)
                .saturating_add(f.max_stream_data)
                .saturating_add(f.max_streams_bidi)
                .saturating_add(f.max_streams_uni)
                .saturating_add(f.new_connection_id)
                .saturating_add(f.path_new_connection_id)
                .saturating_add(f.new_token)
                .saturating_add(f.path_challenge)
                .saturating_add(f.path_response)
                .saturating_add(f.ping)
                .saturating_add(f.reset_stream)
                .saturating_add(f.retire_connection_id)
                .saturating_add(f.path_retire_connection_id)
                .saturating_add(f.stream_data_blocked)
                .saturating_add(f.streams_blocked_bidi)
                .saturating_add(f.streams_blocked_uni)
                .saturating_add(f.stop_sending)
                .saturating_add(f.stream)
                .saturating_add(f.observed_addr)
                .saturating_add(f.path_abandon)
                .saturating_add(f.path_status_available)
                .saturating_add(f.path_status_backup)
                .saturating_add(f.max_path_id)
                .saturating_add(f.paths_blocked)
                .saturating_add(f.path_cids_blocked)
                .saturating_add(f.add_address)
                .saturating_add(f.reach_out)
                .saturating_add(f.remove_address);
            activities.push(Activity {
                path: path.network_path().clone(),
                connection: connection.clone(),
                generation: stats.path_generation,
                traffic: Traffic {
                    rx_frames,
                    tx_datagrams: stats.udp_tx.datagrams,
                },
            });
            let Some(rtt) = stats.same_path_rtt else {
                continue;
            };
            paths.push(Candidate {
                path: path.network_path().clone(),
                kind: Kind::of(path.network_path()),
                sample: Sample {
                    connection,
                    generation: stats.path_generation,
                    epoch: stats.same_path_rtt_epoch,
                    sequence: stats.same_path_rtt_samples,
                    rtt_us: rtt.as_micros().min(u64::MAX as u128) as u64,
                },
            });
            data.push(path);
        }
        let mut selection = PathSelection::none();
        let current = ctx.current().map(|p| (p, Kind::of(p)));
        let mut policy = self.policy.lock().unwrap();
        let (chosen, probes) =
            policy.choose_observed(current, current_seen, &paths, &activities, &connections, now);
        // Keep the existing withdrawal rule. Preference alone never retires a backup path.
        let best_for_withdrawal = paths
            .iter()
            .filter(|p| !policy.is_tuple_stale(&p.path, &activities, &connections, now))
            .min_by_key(|p| p.sample.rtt_us)
            .or_else(|| paths.iter().min_by_key(|p| p.sample.rtt_us));
        if let Some(best) = best_for_withdrawal {
            let replacement_routed = self.hub.routed(&best.path.remote());
            for path in ctx.paths() {
                if replacement_routed
                    && path.network_path() != &best.path
                    && self.hub.withdrawn(&path.network_path().remote())
                {
                    selection.close(&path);
                }
            }
        }
        if let Some(i) = chosen {
            if self.trace_routing {
                eprintln!(
                    "MESH_DIAG select now={now} current={:?} best={:?} samples={} rtt_us={}",
                    ctx.current(),
                    paths[i].path,
                    paths[i].sample.sequence,
                    paths[i].sample.rtt_us
                );
            }
            selection.set(&data[i]);
        } else if let Some(fallback) = unmeasured_fallback(
            ctx.current().is_some(),
            current_seen,
            !paths.is_empty(),
            first_native,
            first,
        ) {
            policy.switched_to(
                current,
                fallback.network_path(),
                Kind::of(fallback.network_path()),
                &paths,
                &connections,
                now,
            );
            selection.set(&fallback);
        } else {
            for target in &probes {
                if let Some((_, d)) = paths.iter().zip(&data).find(|(p, _)| {
                    p.sample.connection == target.connection
                        && p.path == target.path
                        && p.sample.generation == target.generation
                }) {
                    if self.trace_routing {
                        eprintln!(
                            "MESH_DIAG ping now={now} path={:?} gen={}",
                            target.path, target.generation
                        );
                    }
                    selection.ping(d);
                }
            }
        }
        selection
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample(connection: u64, generation: u64, sequence: u64, rtt_ms: u64) -> Sample<u64> {
        Sample {
            connection,
            generation,
            epoch: 0,
            sequence,
            rtt_us: rtt_ms * 1_000,
        }
    }
    #[test]
    fn repeated_snapshots_do_not_turn_a_spike_into_sustained_gain() {
        let mut gate = Gate::new(0);
        let current = sample(1, 1, 1, 400);
        let next = sample(1, 2, 1, 30);
        assert!(!gate.consider(
            2,
            current.clone(),
            next.clone(),
            0,
            (Kind::Transit, Kind::Transit)
        ));
        assert!(!gate.consider(
            2,
            current.clone(),
            next.clone(),
            3_000,
            (Kind::Transit, Kind::Transit)
        ));
        assert!(!gate.consider(
            2,
            current.clone(),
            next.clone(),
            60_000,
            (Kind::Transit, Kind::Transit)
        ));
        assert!(!gate.consider(
            2,
            sample(1, 1, 2, 30),
            sample(1, 2, 2, 40),
            60_001,
            (Kind::Transit, Kind::Transit)
        ));
    }
    #[test]
    fn equal_rtt_new_samples_count_but_each_side_must_advance() {
        let mut gate = Gate::new(0);
        assert!(!gate.consider(
            2,
            sample(1, 1, 1, 400),
            sample(1, 2, 1, 30),
            0,
            (Kind::Transit, Kind::Transit)
        ));
        assert!(!gate.consider(
            2,
            sample(1, 1, 2, 400),
            sample(1, 2, 1, 30),
            3_000,
            (Kind::Transit, Kind::Transit)
        ));
        assert!(gate.consider(
            2,
            sample(1, 1, 2, 400),
            sample(1, 2, 2, 30),
            3_000,
            (Kind::Transit, Kind::Transit)
        ));
    }
    #[test]
    fn path_response_initial_estimates_do_not_start_sustained_evidence() {
        let mut gate = Gate::new(0);
        assert!(!gate.consider(
            2,
            sample(1, 1, 0, 400),
            sample(1, 2, 0, 30),
            0,
            (Kind::Transit, Kind::Transit)
        ));
        assert!(!gate.consider(
            2,
            sample(1, 1, 1, 400),
            sample(1, 2, 1, 30),
            3_000,
            (Kind::Transit, Kind::Transit)
        ));
        assert!(!gate.consider(
            2,
            sample(1, 1, 2, 400),
            sample(1, 2, 2, 30),
            5_999,
            (Kind::Transit, Kind::Transit)
        ));
        assert!(gate.consider(
            2,
            sample(1, 1, 3, 400),
            sample(1, 2, 3, 30),
            6_000,
            (Kind::Transit, Kind::Transit)
        ));
    }
    #[test]
    fn missed_invalidation_still_restarts_evidence() {
        for change_current in [true, false] {
            let mut gate = Gate::new(0);
            let mut current = sample(1, 1, 1, 400);
            let mut next = sample(1, 2, 1, 30);
            assert!(!gate.consider(
                2,
                current.clone(),
                next.clone(),
                0,
                (Kind::Transit, Kind::Transit)
            ));
            // The selector never saw None, but the estimator was invalidated and recovered.
            if change_current {
                current.epoch += 1;
            } else {
                next.epoch += 1;
            }
            current.sequence += 1;
            next.sequence += 1;
            assert!(!gate.consider(
                2,
                current.clone(),
                next.clone(),
                3_000,
                (Kind::Transit, Kind::Transit)
            ));
            current.sequence += 1;
            next.sequence += 1;
            assert!(gate.consider(2, current, next, 6_000, (Kind::Transit, Kind::Transit)));
        }
    }
    #[test]
    fn observation_and_cooldown_boundaries_keep_their_existing_durations() {
        let mut gate = Gate::new(0);
        assert!(!gate.consider(
            2,
            sample(1, 1, 1, 400),
            sample(1, 2, 1, 30),
            0,
            (Kind::Transit, Kind::Transit)
        ));
        assert!(!gate.consider(
            2,
            sample(1, 1, 2, 400),
            sample(1, 2, 2, 30),
            2_999,
            (Kind::Transit, Kind::Transit)
        ));
        assert!(gate.consider(
            2,
            sample(1, 1, 3, 400),
            sample(1, 2, 3, 30),
            3_000,
            (Kind::Transit, Kind::Transit)
        ));
        gate.cooldown = 33_000;
        assert!(!gate.consider(
            2,
            sample(1, 1, 4, 400),
            sample(1, 2, 4, 30),
            32_999,
            (Kind::Transit, Kind::Transit)
        ));
        assert!(!gate.consider(
            2,
            sample(1, 1, 5, 400),
            sample(1, 2, 5, 30),
            33_000,
            (Kind::Transit, Kind::Transit)
        ));
        assert!(gate.consider(
            2,
            sample(1, 1, 6, 400),
            sample(1, 2, 6, 30),
            36_000,
            (Kind::Transit, Kind::Transit)
        ));
    }
    #[test]
    fn changing_either_connection_or_path_incarnation_restarts_evidence() {
        for (current, next) in [
            (sample(2, 1, 9, 400), sample(1, 2, 9, 30)),
            (sample(1, 3, 9, 400), sample(1, 2, 9, 30)),
            (sample(1, 1, 9, 400), sample(2, 2, 9, 30)),
            (sample(1, 1, 9, 400), sample(1, 3, 9, 30)),
        ] {
            let mut gate = Gate::new(0);
            assert!(!gate.consider(
                2,
                sample(1, 1, 1, 400),
                sample(1, 2, 1, 30),
                0,
                (Kind::Transit, Kind::Transit)
            ));
            assert!(!gate.consider(
                2,
                current.clone(),
                next.clone(),
                3_000,
                (Kind::Transit, Kind::Transit)
            ));
            assert!(!gate.consider(
                2,
                Sample {
                    sequence: 10,
                    ..current.clone()
                },
                Sample {
                    sequence: 10,
                    ..next.clone()
                },
                5_999,
                (Kind::Transit, Kind::Transit)
            ));
            assert!(gate.consider(
                2,
                Sample {
                    sequence: 11,
                    ..current
                },
                Sample {
                    sequence: 11,
                    ..next
                },
                6_000,
                (Kind::Transit, Kind::Transit)
            ));
        }
    }
}

#[cfg(test)]
mod policy_tests {
    use super::*;
    use Kind::{Direct, Transit};

    fn path(id: u64, kind: Kind, us: u64, sequence: u64) -> Candidate<u64, u64> {
        Candidate {
            path: id,
            kind,
            sample: Sample {
                connection: 1,
                generation: id,
                epoch: 0,
                sequence,
                rtt_us: us,
            },
        }
    }
    fn decide(
        policy: &mut Policy<u64, u64>,
        current: Option<(u64, Kind)>,
        paths: &[Candidate<u64, u64>],
        now: u64,
    ) -> Option<u64> {
        let seen = current.is_some_and(|(id, _)| paths.iter().any(|p| p.path == id));
        policy
            .choose(
                current.as_ref().map(|(id, kind)| (id, *kind)),
                seen,
                paths,
                &[1],
                now,
            )
            .map(|i| paths[i].path)
    }
    fn pair(
        policy: &mut Policy<u64, u64>,
        kinds: (Kind, Kind),
        rtts: (u64, u64),
        seq: u64,
        now: u64,
    ) -> Option<u64> {
        decide(
            policy,
            Some((1, kinds.0)),
            &[path(1, kinds.0, rtts.0, seq), path(2, kinds.1, rtts.1, seq)],
            now,
        )
    }
    fn comparison(kinds: (Kind, Kind), rtts: (u64, u64), expected: bool) {
        let mut policy = Policy::new();
        assert_eq!(pair(&mut policy, kinds, rtts, 1, 0), None);
        assert_eq!(
            pair(&mut policy, kinds, rtts, 2, 5_000),
            expected.then_some(2),
            "{kinds:?} {rtts:?}"
        );
    }
    #[test]
    fn only_ip_is_direct() {
        use iroh_base::CustomAddr;
        let ip = FourTuple::Ip {
            remote: "127.0.0.1:1".parse().unwrap(),
            local: None,
        };
        let relay = FourTuple::Relay {
            url: "https://relay.example".parse().unwrap(),
            endpoint_id: iroh::SecretKey::from_bytes(&[7; 32]).public(),
        };
        let custom = FourTuple::Custom {
            remote: CustomAddr::from_parts(42, &[1]),
            local: None,
        };
        assert_eq!(Kind::of(&ip), Direct);
        assert_eq!(Kind::of(&relay), Transit);
        assert_eq!(Kind::of(&custom), Transit);
    }
    #[test]
    fn table_relay_12_direct_3() {
        comparison((Transit, Direct), (12_000, 3_000), true);
    }
    #[test]
    fn table_relay_6_direct_2() {
        comparison((Transit, Direct), (6_000, 2_000), true);
    }
    #[test]
    fn table_relay_40_direct_38() {
        comparison((Transit, Direct), (40_000, 38_000), true);
    }
    #[test]
    fn table_relay_40_direct_45() {
        comparison((Transit, Direct), (40_000, 45_000), false);
    }
    #[test]
    fn table_relay_200_direct_180() {
        comparison((Transit, Direct), (200_000, 180_000), true);
    }
    #[test]
    fn table_direct_3_relay_1() {
        comparison((Direct, Transit), (3_000, 1_000), false);
    }
    #[test]
    fn table_relay_30_relay_25() {
        comparison((Transit, Transit), (30_000, 25_000), false);
    }
    #[test]
    fn thresholds_accept_exact_gain_and_reject_one_microsecond_less() {
        for (kinds, current, margin) in [
            ((Transit, Direct), 20_000, 2_000),
            ((Transit, Direct), 100_000, 5_000),
            ((Direct, Transit), 40_000, 15_000),
            ((Direct, Transit), 100_000, 25_000),
            ((Transit, Transit), 30_000, 10_000),
            ((Transit, Transit), 100_000, 20_000),
            ((Direct, Direct), 30_000, 10_000),
            ((Direct, Direct), 100_000, 20_000),
        ] {
            comparison(kinds, (current, current - margin), true);
            comparison(kinds, (current, current - margin + 1), false);
        }
    }
    #[test]
    fn submillisecond_rtts_do_not_round_into_a_switch() {
        comparison((Transit, Direct), (3_900, 2_000), false);
        comparison((Transit, Direct), (4_100, 2_000), true);
    }
    #[test]
    fn filter_before_ranking_can_prefer_a_slower_eligible_direct_path() {
        let mut policy = Policy::new();
        for (seq, now, expected) in [(1, 0, None), (2, 4_999, None), (3, 5_000, Some(3))] {
            assert_eq!(
                decide(
                    &mut policy,
                    Some((1, Transit)),
                    &[
                        path(1, Transit, 40_000, seq),
                        path(2, Transit, 37_000, seq),
                        path(3, Direct, 38_000, seq),
                    ],
                    now
                ),
                expected
            );
        }
    }
    #[test]
    fn direct_observation_needs_five_seconds_and_fresh_samples_on_both_sides() {
        let mut policy = Policy::new();
        let p = |a, b| [path(1, Transit, 200_000, a), path(2, Direct, 10_000, b)];
        for (a, b, now, expected) in [
            (1, 1, 0, None),
            (2, 2, 3_000, None),
            (3, 3, 4_999, None),
            (3, 3, 5_000, None),
            (4, 3, 5_001, None),
            (4, 4, 5_002, Some(2)),
        ] {
            assert_eq!(
                decide(&mut policy, Some((1, Transit)), &p(a, b), now),
                expected
            );
        }
    }
    #[test]
    fn transit_observation_needs_three_seconds() {
        let mut policy = Policy::new();
        assert_eq!(
            pair(&mut policy, (Direct, Transit), (100_000, 50_000), 1, 0),
            None
        );
        assert_eq!(
            pair(&mut policy, (Direct, Transit), (100_000, 50_000), 2, 2_999),
            None
        );
        assert_eq!(
            pair(&mut policy, (Direct, Transit), (100_000, 50_000), 3, 3_000),
            Some(2)
        );
    }
    #[test]
    fn changing_candidates_restarts_the_observation() {
        let mut policy = Policy::new();
        let p = |id, seq| [path(1, Transit, 40_000, seq), path(id, Direct, 30_000, seq)];
        for (id, seq, now, expected) in [
            (2, 1, 0, None),
            (3, 2, 4_000, None),
            (3, 3, 5_000, None),
            (3, 4, 8_999, None),
            (3, 5, 9_000, Some(3)),
        ] {
            assert_eq!(
                decide(&mut policy, Some((1, Transit)), &p(id, seq), now),
                expected
            );
        }
    }
    #[test]
    fn initial_estimates_do_not_start_direct_observation() {
        let mut policy = Policy::new();
        for (seq, now, expected) in [
            (0, 0, None),
            (1, 5_000, None),
            (2, 9_999, None),
            (3, 10_000, Some(2)),
        ] {
            assert_eq!(
                pair(&mut policy, (Transit, Direct), (40_000, 30_000), seq, now),
                expected
            );
        }
    }
    #[test]
    fn proactive_cooldown_and_fault_bypass() {
        let mut policy = Policy::new();
        assert_eq!(
            pair(&mut policy, (Transit, Direct), (40_000, 30_000), 1, 0),
            None
        );
        assert_eq!(
            pair(&mut policy, (Transit, Direct), (40_000, 30_000), 2, 5_000),
            Some(2)
        );
        let p = |seq| [path(2, Direct, 100_000, seq), path(3, Transit, 10_000, seq)];
        for now in [5_001, 34_999] {
            assert_eq!(decide(&mut policy, Some((2, Direct)), &p(now), now), None);
        }
        assert_eq!(
            decide(&mut policy, Some((2, Direct)), &p(35_000), 35_000),
            None
        );
        assert_eq!(
            decide(&mut policy, Some((2, Direct)), &p(38_000), 38_000),
            Some(3)
        );
        // Even a much slower path is an immediate rescue during the new cooldown.
        assert_eq!(
            decide(
                &mut policy,
                Some((3, Transit)),
                &[path(4, Direct, 900_000, 1)],
                38_001
            ),
            Some(4)
        );
    }
    #[test]
    fn passive_fallback_starts_cooldown_on_the_replacement() {
        let mut policy = Policy::new();
        assert_eq!(
            decide(
                &mut policy,
                Some((1, Transit)),
                &[path(2, Transit, 100_000, 1)],
                10
            ),
            Some(2)
        );
        let p = |seq| {
            [
                path(2, Transit, 100_000, seq),
                path(3, Transit, 10_000, seq),
            ]
        };
        for now in [11, 3_011, 30_009] {
            assert_eq!(decide(&mut policy, Some((2, Transit)), &p(now), now), None);
        }
        assert_eq!(
            decide(&mut policy, Some((2, Transit)), &p(30_010), 30_010),
            None
        );
        assert_eq!(
            decide(&mut policy, Some((2, Transit)), &p(33_010), 33_010),
            Some(3)
        );
    }
    // Force a direct rescue and then lose it before three minutes. The relay remains available.
    fn early_death(policy: &mut Policy<u64, u64>, id: u64, now: u64) -> u64 {
        assert_eq!(
            decide(
                policy,
                Some((1, Transit)),
                &[path(id, Direct, 10_000, now + 1)],
                now
            ),
            Some(id)
        );
        let failed = now + 1_000;
        assert_eq!(
            decide(
                policy,
                Some((id, Direct)),
                &[path(1, Transit, 100_000, failed)],
                failed
            ),
            Some(1)
        );
        failed
    }
    #[test]
    fn early_deaths_double_the_hold_across_new_ports_up_to_thirty_minutes() {
        let mut policy = Policy::new();
        let mut now = 0;
        let mut direct = 2;
        assert_eq!(
            decide(&mut policy, None, &[path(direct, Direct, 10_000, 1)], now),
            Some(direct)
        );
        for (round, delay) in [
            60_000, 120_000, 240_000, 480_000, 960_000, 1_800_000, 1_800_000,
        ]
        .into_iter()
        .enumerate()
        {
            let failed = now + 1_000;
            assert_eq!(
                decide(
                    &mut policy,
                    Some((direct, Direct)),
                    &[path(1, Transit, 100_000, failed)],
                    failed
                ),
                Some(1)
            );
            let p = |seq| {
                [
                    path(1, Transit, 100_000, seq),
                    path(100 + round as u64, Direct, 10_000, seq),
                ]
            };
            let expected_path = 100 + round as u64;
            for t in [
                failed + 30_000,
                failed + delay - 1,
                failed + delay,
                failed + delay + 4_999,
            ] {
                assert_eq!(
                    decide(&mut policy, Some((1, Transit)), &p(t), t),
                    None,
                    "round {round}, time {t}"
                );
            }
            assert_eq!(
                decide(
                    &mut policy,
                    Some((1, Transit)),
                    &p(failed + delay + 5_000),
                    failed + delay + 5_000
                ),
                Some(expected_path)
            );
            direct = expected_path;
            now = failed + delay + 5_000;
        }
    }
    #[test]
    fn hold_does_not_block_transit_switches_or_sole_direct_rescue() {
        let mut policy = Policy::new();
        let failed = early_death(&mut policy, 2, 0);
        let p = |seq| {
            [
                path(1, Transit, 100_000, seq),
                path(3, Transit, 50_000, seq),
                path(4, Direct, 10_000, seq),
            ]
        };
        assert_eq!(
            decide(&mut policy, Some((1, Transit)), &p(10), failed + 30_000),
            None
        );
        assert_eq!(
            decide(&mut policy, Some((1, Transit)), &p(11), failed + 33_000),
            Some(3)
        );
        assert_eq!(
            decide(
                &mut policy,
                Some((3, Transit)),
                &[path(4, Direct, 900_000, 12)],
                failed + 33_001
            ),
            Some(4)
        );
    }
    #[test]
    fn stable_direct_requires_ack_progress_before_resetting_the_delay() {
        for fresh in [false, true] {
            let mut policy = Policy::new();
            early_death(&mut policy, 2, 0);
            early_death(&mut policy, 3, 2_000);
            // Rescue ignores the 120-second hold.
            assert_eq!(
                decide(
                    &mut policy,
                    Some((1, Transit)),
                    &[path(4, Direct, 10_000, 1)],
                    4_000
                ),
                Some(4)
            );
            assert_eq!(
                decide(
                    &mut policy,
                    Some((4, Direct)),
                    &[path(4, Direct, 10_000, if fresh { 2 } else { 1 })],
                    184_000
                ),
                None
            );
            // A late failure adds no penalty, but cannot reset history without fresh ACKs.
            assert_eq!(
                decide(
                    &mut policy,
                    Some((4, Direct)),
                    &[path(1, Transit, 100_000, 1)],
                    184_001
                ),
                Some(1)
            );
            let failed = early_death(&mut policy, 5, 185_000);
            let p = |seq| [path(1, Transit, 100_000, seq), path(6, Direct, 10_000, seq)];
            assert_eq!(
                decide(&mut policy, Some((1, Transit)), &p(1), failed + 60_000),
                None
            );
            assert_eq!(
                decide(&mut policy, Some((1, Transit)), &p(2), failed + 65_000),
                if fresh { Some(6) } else { None }
            );
        }
    }
    #[test]
    fn exactly_three_minutes_is_not_an_early_death() {
        let mut policy = Policy::new();
        assert_eq!(
            decide(&mut policy, None, &[path(2, Direct, 10_000, 1)], 0),
            Some(2)
        );
        assert_eq!(
            decide(
                &mut policy,
                Some((2, Direct)),
                &[path(1, Transit, 100_000, 1)],
                180_000
            ),
            Some(1)
        );
        assert_eq!(
            pair(
                &mut policy,
                (Transit, Direct),
                (100_000, 10_000),
                1,
                210_000
            ),
            None
        );
        assert_eq!(
            pair(
                &mut policy,
                (Transit, Direct),
                (100_000, 10_000),
                2,
                215_000
            ),
            Some(2)
        );
    }
    #[test]
    fn evidence_invalidation_cannot_extend_the_early_death_window() {
        let mut policy = Policy::new();
        decide(&mut policy, None, &[path(2, Direct, 10_000, 1)], 0);
        let mut reset = path(2, Direct, 10_000, 1);
        reset.sample.epoch = 1;
        decide(&mut policy, Some((2, Direct)), &[reset], 179_000);
        decide(
            &mut policy,
            Some((2, Direct)),
            &[path(1, Transit, 100_000, 1)],
            180_000,
        );
        assert_eq!(policy.recovery[0].delay, COOLDOWN_MS);
    }
    #[test]
    fn active_records_survive_idle_gate_cleanup_and_hold_expiration() {
        let mut policy = Policy::new();
        early_death(&mut policy, 2, 0);
        for now in [
            61_001,
            120_001,
            MAX_DIRECT_HOLD_MS + 1,
            MAX_DIRECT_HOLD_MS * 2,
        ] {
            decide(
                &mut policy,
                Some((1, Transit)),
                &[path(1, Transit, 100_000, 1)],
                now,
            );
            assert_eq!(policy.recovery[0].delay, 60_000);
            assert_eq!(policy.recovery[0].touched, now);
        }
    }
    #[test]
    fn history_is_bounded_and_evicts_the_least_recently_touched_connection() {
        let mut policy = Policy::<u64, u64>::new();
        for connection in 1..=MAX_TRACKED as u64 {
            policy.choose(None, false, &[], &[connection], connection);
        }
        policy.choose(None, false, &[], &[1], 1_000);
        policy.choose(None, false, &[], &[999], 1_001);
        assert_eq!(policy.recovery.len(), MAX_TRACKED);
        assert!(policy.recovery.iter().any(|r| r.connection == 1));
        assert!(!policy.recovery.iter().any(|r| r.connection == 2));
        assert!(policy.recovery.iter().any(|r| r.connection == 999));
        policy.choose(None, false, &[], &[], MAX_DIRECT_HOLD_MS + 1_002);
        assert!(policy.recovery.is_empty());
    }
    #[test]
    fn a_new_connection_does_not_inherit_the_previous_connections_hold() {
        let mut policy = Policy::new();
        early_death(&mut policy, 2, 0);
        for (seq, now, expected) in [(1, 2_000, None), (2, 7_000, Some(1))] {
            let mut paths = [path(1, Transit, 100_000, seq), path(2, Direct, 10_000, seq)];
            for p in &mut paths {
                p.sample.connection = 2;
            }
            assert_eq!(
                policy.choose(Some((&1, Transit)), true, &paths, &[2], now),
                expected
            );
        }
    }
}

#[cfg(test)]
mod review_tests {
    use super::*;
    fn first_relay_then_direct(measured: bool) {
        let mut policy = Policy::new();
        if measured {
            let initial = [path(1, 1, Kind::Transit, 40_000, 1)];
            assert_eq!(policy.choose(None, false, &initial, &[1], 0), Some(0));
        } else {
            assert_eq!(policy.choose(None, false, &[], &[1], 0), None);
            let initial = unmeasured_fallback(false, false, false, Some(1), Some(1));
            assert_eq!(initial, Some(1));
            policy.switched_to(None, &1, Kind::Transit, &[], &[1], 0);
        }
        assert!(policy.gates.is_empty());
        let relay = [path(1, 1, Kind::Transit, 40_000, 2)];
        assert_eq!(
            policy.choose(Some((&1, Kind::Transit)), true, &relay, &[1], 50),
            None
        );
        assert!(policy.gates.is_empty());
        for (now, seq, expected) in [(100, 3, None), (5_099, 4, None), (5_100, 5, Some(1))] {
            let paths = [
                path(1, 1, Kind::Transit, 40_000, seq),
                path(2, 1, Kind::Direct, 20_000, seq),
            ];
            assert_eq!(
                policy.choose(Some((&1, Kind::Transit)), true, &paths, &[1], now),
                expected,
                "t={now}"
            );
        }
        assert!(policy.gates.is_empty());
        assert_eq!(policy.recovery[0].cooldown, 35_100);
        assert_eq!(policy.recovery[0].stay.as_ref().unwrap().since, 5_100);
    }
    #[test]
    fn initial_measured_relay_does_not_delay_direct_observation() {
        first_relay_then_direct(true);
    }
    #[test]
    fn initial_unmeasured_relay_does_not_delay_direct_observation() {
        first_relay_then_direct(false);
    }
    #[test]
    fn initial_direct_still_records_early_death_from_selection_time() {
        for measured in [false, true] {
            let mut policy = Policy::new();
            if measured {
                policy.choose(None, false, &[path(2, 1, Kind::Direct, 20_000, 1)], &[1], 0);
            } else {
                policy.choose(None, false, &[], &[1], 0);
                policy.switched_to(None, &2, Kind::Direct, &[], &[1], 0);
            }
            assert!(policy.gates.is_empty());
            assert_eq!(policy.recovery[0].stay.as_ref().unwrap().since, 0);
            let relay = [path(1, 1, Kind::Transit, 40_000, 1)];
            assert_eq!(
                policy.choose(Some((&2, Kind::Direct)), false, &relay, &[1], 100),
                Some(0)
            );
            assert_eq!(policy.recovery[0].direct_until, 60_100);
            assert_eq!(policy.recovery[0].cooldown, 30_100);
        }
    }
    fn path(id: u64, connection: u64, kind: Kind, us: u64, seq: u64) -> Candidate<u64, u64> {
        Candidate {
            path: id,
            kind,
            sample: Sample {
                connection,
                generation: id,
                epoch: 0,
                sequence: seq,
                rtt_us: us,
            },
        }
    }
    fn alternating_sources(kinds: (Kind, Kind), duration: u64) {
        let mut policy = Policy::new();
        for tick in 0..=duration / 1_000 {
            let seq = tick + 1;
            let jitter = if tick % 2 == 0 { 0 } else { 50 };
            let paths = [
                path(1, 1, kinds.0, 40_000 + jitter, seq),
                path(1, 2, kinds.0, 40_050 - jitter, seq),
                path(2, 1, kinds.1, 20_050 - jitter, seq),
                path(2, 2, kinds.1, 20_000 + jitter, seq),
            ];
            let selected = policy
                .choose(Some((&1, kinds.0)), true, &paths, &[1, 2], tick * 1_000)
                .map(|i| paths[i].path);
            assert_eq!(
                selected,
                (tick * 1_000 == duration).then_some(2),
                "tick {tick}"
            );
        }
    }
    #[test]
    fn alternating_connections_still_switch_transit_to_direct_after_five_seconds() {
        alternating_sources((Kind::Transit, Kind::Direct), 5_000);
    }
    #[test]
    fn alternating_connections_still_switch_direct_to_transit_after_three_seconds() {
        alternating_sources((Kind::Direct, Kind::Transit), 3_000);
    }
    #[test]
    fn alternating_connections_still_switch_within_class_after_three_seconds() {
        alternating_sources((Kind::Transit, Kind::Transit), 3_000);
    }
    #[test]
    fn losing_or_invalidating_pinned_sources_restarts_observation() {
        for lose_margin in [false, true] {
            let mut policy = Policy::new();
            let initial = [
                path(1, 1, Kind::Transit, 40_000, 1),
                path(2, 1, Kind::Direct, 20_000, 1),
            ];
            assert_eq!(
                policy.choose(Some((&1, Kind::Transit)), true, &initial, &[1, 2], 0),
                None
            );
            for (now, seq, expected) in [(3_000, 2, None), (5_000, 3, None), (8_000, 4, Some(2))] {
                let mut paths = vec![
                    path(1, 2, Kind::Transit, 40_000, seq),
                    path(2, 2, Kind::Direct, 20_000, seq),
                ];
                if lose_margin {
                    paths.extend([
                        path(1, 1, Kind::Transit, 40_000, seq),
                        path(2, 1, Kind::Direct, 39_000, seq),
                    ]);
                }
                assert_eq!(
                    policy
                        .choose(Some((&1, Kind::Transit)), true, &paths, &[1, 2], now)
                        .map(|i| paths[i].path),
                    expected
                );
            }
        }
    }
    #[test]
    fn a_faster_distinct_candidate_still_restarts_observation() {
        let mut policy = Policy::new();
        let initial = [
            path(1, 1, Kind::Transit, 40_000, 1),
            path(2, 1, Kind::Direct, 20_000, 1),
        ];
        assert_eq!(
            policy.choose(Some((&1, Kind::Transit)), true, &initial, &[1], 0),
            None
        );
        for (now, seq, expected) in [(3_000, 2, None), (5_000, 3, None), (8_000, 4, Some(3))] {
            let paths = [
                path(1, 1, Kind::Transit, 40_000, seq),
                path(2, 1, Kind::Direct, 20_000, seq),
                path(3, 1, Kind::Direct, 10_000, seq),
            ];
            assert_eq!(
                policy
                    .choose(Some((&1, Kind::Transit)), true, &paths, &[1], now)
                    .map(|i| paths[i].path),
                expected
            );
        }
    }
    #[test]
    fn lost_current_can_use_an_unmeasured_native_backup() {
        assert_eq!(
            unmeasured_fallback(true, false, false, Some(2), Some(2)),
            Some(2)
        );
    }
    #[test]
    fn unmeasured_fallback_preserves_custom_validation_and_current_paths() {
        assert_eq!(unmeasured_fallback(true, false, false, None, Some(3)), None);
        assert_eq!(
            unmeasured_fallback(true, true, false, Some(2), Some(2)),
            None
        );
        assert_eq!(
            unmeasured_fallback(true, false, true, Some(2), Some(2)),
            None
        );
        // Preserve the initial path choice when no selection exists yet.
        assert_eq!(
            unmeasured_fallback(false, false, false, None, Some(3)),
            Some(3)
        );
    }
    #[test]
    fn unmeasured_rescue_records_the_replacements_cooldown() {
        let mut policy = Policy::new();
        let initial = [path(2, 1, Kind::Direct, 10_000, 1)];
        policy.choose(None, false, &initial, &[1], 0);
        policy.choose(Some((&2, Kind::Direct)), false, &[], &[1], 1_000);
        policy.switched_to(
            Some((&2, Kind::Direct)),
            &1,
            Kind::Transit,
            &[],
            &[1],
            1_000,
        );
        for (now, seq, expected) in [
            (1_001, 1, None),
            (4_001, 2, None),
            (30_999, 3, None),
            (31_000, 4, None),
            (34_000, 5, Some(3)),
        ] {
            let paths = [
                path(1, 1, Kind::Transit, 100_000, seq),
                path(3, 1, Kind::Transit, 10_000, seq),
            ];
            assert_eq!(
                policy
                    .choose(Some((&1, Kind::Transit)), true, &paths, &[1], now)
                    .map(|i| paths[i].path),
                expected
            );
        }
    }
}

#[cfg(test)]
mod stale_path_tests {
    use super::*;
    use Kind::{Direct, Transit};

    type ObservedPath = (Candidate<u64, u64>, Activity<u64, u64>);

    #[allow(clippy::too_many_arguments)]
    fn observed(
        id: u64,
        connection: u64,
        generation: u64,
        kind: Kind,
        us: u64,
        seq: u64,
        rx_frames: u64,
        tx_datagrams: u64,
    ) -> ObservedPath {
        (
            Candidate {
                path: id,
                kind,
                sample: Sample {
                    connection,
                    generation,
                    epoch: 0,
                    sequence: seq,
                    rtt_us: us,
                },
            },
            Activity {
                path: id,
                connection,
                generation,
                traffic: Traffic {
                    rx_frames,
                    tx_datagrams,
                },
            },
        )
    }

    fn step(
        policy: &mut Policy<u64, u64>,
        current: Option<(u64, Kind)>,
        items: &[ObservedPath],
        connections: &[u64],
        now: u64,
    ) -> Option<u64> {
        let paths: Vec<_> = items.iter().map(|(c, _)| c.clone()).collect();
        let activities: Vec<_> = items.iter().map(|(_, a)| a.clone()).collect();
        let seen = current.is_some_and(|(id, _)| activities.iter().any(|a| a.path == id));
        policy
            .choose_observed(
                current.as_ref().map(|(id, kind)| (id, *kind)),
                seen,
                &paths,
                &activities,
                connections,
                now,
            )
            .0
            .map(|i| paths[i].path)
    }

    #[test]
    fn stale_current_rescues_to_lowest_rtt_live_candidate() {
        let mut policy = Policy::new();
        // Path 1 is selected with a 5 ms frozen RTT. Paths 2 (30 ms) and 3 (15 ms) open later.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[observed(1, 1, 1, Transit, 5_000, 10, 20, 20)],
                &[1],
                0,
            ),
            None
        );
        // Before 3 seconds or 3 outbound packets, path 1 stays selected even within the 10 ms margin.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 5_000, 10, 20, 23),
                    observed(2, 1, 2, Transit, 30_000, 0, 2, 2),
                    observed(3, 1, 3, Transit, 7_000, 0, 2, 2),
                ],
                &[1],
                2_999,
            ),
            None
        );
        // At 3,000 ms with 3 unanswered outbound datagrams, path 1 yields to path 3 (lowest live RTT).
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 5_000, 10, 20, 23),
                    observed(2, 1, 2, Transit, 30_000, 0, 3, 3),
                    observed(3, 1, 3, Transit, 7_000, 0, 3, 3),
                ],
                &[1],
                3_000,
            ),
            Some(3)
        );
    }

    #[test]
    fn rescue_skips_stale_candidate_with_smaller_frozen_rtt() {
        let mut policy = Policy::new();
        // Both path 1 (selected, 4 ms) and path 2 (backup, 6 ms) stop answering at t=0.
        // Path 3 (18 ms) stays live.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 4_000, 8, 15, 15),
                    observed(2, 1, 2, Transit, 6_000, 8, 15, 15),
                    observed(3, 1, 3, Transit, 18_000, 8, 15, 15),
                ],
                &[1],
                0,
            ),
            None
        );
        // Path 1 is removed by QUIC PathIdle while path 2 still lingers with a smaller frozen RTT.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(2, 1, 2, Transit, 6_000, 8, 15, 18),
                    observed(3, 1, 3, Transit, 18_000, 11, 18, 18),
                ],
                &[1],
                3_073,
            ),
            Some(3)
        );
    }

    #[test]
    fn proactive_selection_excludes_stale_candidates() {
        let mut policy = Policy::new();
        // Path 1 (current, 50 ms) and path 2 (candidate, 10 ms) start observation at t=0.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 50_000, 1, 10, 10),
                    observed(2, 1, 2, Transit, 10_000, 1, 10, 10),
                ],
                &[1],
                0,
            ),
            None
        );
        // Path 2 goes silent after advancing sequence once at t=500, then transmits 3 unanswered packets.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 50_000, 2, 11, 11),
                    observed(2, 1, 2, Transit, 10_000, 2, 11, 11),
                ],
                &[1],
                500,
            ),
            None
        );
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 50_000, 5, 15, 15),
                    observed(2, 1, 2, Transit, 10_000, 2, 11, 14),
                ],
                &[1],
                3_500,
            ),
            None
        );
        assert!(policy.gates.get(&1).is_none_or(|g| g.candidate.is_none()));
    }

    #[test]
    fn unidirectional_inbound_stream_with_frozen_rtt_samples_is_never_stale() {
        let mut policy = Policy::new();
        // Server streams data every 400 ms. Client sends pure ACKs, so same_path_rtt_samples stays at 37
        // while authenticated rx_frames and tx_datagrams both climb.
        for second in 0..=10 {
            let rx = 100 + second * 2;
            let tx = 80 + second * 2;
            assert_eq!(
                step(
                    &mut policy,
                    Some((1, Transit)),
                    &[
                        observed(1, 1, 1, Transit, 12_000, 37, rx, tx),
                        observed(2, 1, 2, Transit, 18_000, 26 + second, 50 + second, 50 + second),
                    ],
                    &[1],
                    second * 1_000,
                ),
                None,
                "second {second}"
            );
        }
    }

    #[test]
    fn wake_time_jump_without_three_outbound_packets_does_not_mark_stale() {
        let mut policy = Policy::new();
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 10_000, 5, 20, 20),
                    observed(2, 1, 2, Transit, 25_000, 5, 20, 20),
                ],
                &[1],
                0,
            ),
            None
        );
        // Tab wakes after 60 seconds with only 2 outbound packets sent on path 1 since last rx.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 10_000, 5, 20, 22),
                    observed(2, 1, 2, Transit, 25_000, 6, 21, 21),
                ],
                &[1],
                60_000,
            ),
            None
        );
    }

    #[test]
    fn newly_seen_generation_change_and_counter_rollback_observe_from_now() {
        let mut policy = Policy::new();
        // Path 1 starts at t=10,000 with high tx count: first sight starts fresh at t=10,000.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 10_000, 5, 10, 500),
                    observed(2, 1, 2, Transit, 20_000, 5, 10, 10),
                ],
                &[1],
                10_000,
            ),
            None
        );
        // Generation bump at t=12,500 resets observation window even with +3 tx since t=10,000.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 2, Transit, 10_000, 5, 10, 504),
                    observed(2, 1, 2, Transit, 20_000, 6, 12, 12),
                ],
                &[1],
                13_000,
            ),
            None
        );
        // Counter rollback at t=15,500 also resets observation window.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 2, Transit, 10_000, 5, 9, 500),
                    observed(2, 1, 2, Transit, 20_000, 7, 14, 14),
                ],
                &[1],
                16_000,
            ),
            None
        );
    }

    #[test]
    fn new_inbound_frame_immediately_clears_staleness() {
        let mut policy = Policy::new();
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 50_000, 1, 10, 10),
                    observed(2, 1, 2, Transit, 10_000, 1, 10, 10),
                ],
                &[1],
                0,
            ),
            None
        );
        // Path 2 becomes stale at t=3,000.
        let stale_step = [
            observed(1, 1, 1, Transit, 50_000, 2, 13, 13),
            observed(2, 1, 2, Transit, 10_000, 1, 10, 13),
        ];
        assert_eq!(
            step(&mut policy, Some((1, Transit)), &stale_step, &[1], 3_000),
            None
        );
        let stale_acts: Vec<_> = stale_step.iter().map(|(_, a)| a.clone()).collect();
        assert!(policy.is_tuple_stale(&2, &stale_acts, &[1], 3_000));
        // One authenticated frame arrives on path 2 at t=3,100: staleness clears at once.
        let live_step = [
            observed(1, 1, 1, Transit, 50_000, 3, 14, 14),
            observed(2, 1, 2, Transit, 10_000, 2, 11, 14),
        ];
        assert_eq!(
            step(&mut policy, Some((1, Transit)), &live_step, &[1], 3_100),
            None
        );
        let live_acts: Vec<_> = live_step.iter().map(|(_, a)| a.clone()).collect();
        assert!(!policy.is_tuple_stale(&2, &live_acts, &[1], 3_100));
        // After 3 seconds of sustained fresh samples from t=3,100, proactive switch to path 2 succeeds.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 50_000, 4, 17, 17),
                    observed(2, 1, 2, Transit, 10_000, 3, 14, 17),
                ],
                &[1],
                6_100,
            ),
            Some(2)
        );
    }

    #[test]
    fn shared_tuple_with_one_live_and_one_stale_connection_is_not_stale() {
        let mut policy = Policy::new();
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 8_000, 5, 10, 10),
                    observed(1, 2, 1, Transit, 8_000, 5, 10, 10),
                    observed(2, 1, 2, Transit, 20_000, 5, 10, 10),
                    observed(2, 2, 2, Transit, 20_000, 5, 10, 10),
                ],
                &[1, 2],
                0,
            ),
            None
        );
        // Connection 1 stops receiving on path 1 (+4 tx, 0 rx), while connection 2 still receives on path 1.
        let mixed = [
            observed(1, 1, 1, Transit, 8_000, 5, 10, 14),
            observed(1, 2, 1, Transit, 8_000, 8, 13, 13),
            observed(2, 1, 2, Transit, 20_000, 8, 13, 13),
            observed(2, 2, 2, Transit, 20_000, 8, 13, 13),
        ];
        assert_eq!(
            step(&mut policy, Some((1, Transit)), &mixed, &[1, 2], 3_500),
            None
        );
        let mixed_acts: Vec<_> = mixed.iter().map(|(_, a)| a.clone()).collect();
        assert!(!policy.is_tuple_stale(&1, &mixed_acts, &[1, 2], 3_500));
        // Once connection 2 also goes silent for 3 seconds with >= 3 tx, tuple 1 yields to path 2.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 8_000, 5, 10, 17),
                    observed(1, 2, 1, Transit, 8_000, 8, 13, 16),
                    observed(2, 1, 2, Transit, 20_000, 11, 16, 16),
                    observed(2, 2, 2, Transit, 20_000, 11, 16, 16),
                ],
                &[1, 2],
                6_500,
            ),
            Some(2)
        );
    }

    #[test]
    fn all_paths_stale_preserves_fallback_without_oscillating_or_accumulating_early_deaths() {
        let mut policy = Policy::new();
        assert_eq!(
            step(
                &mut policy,
                None,
                &[
                    observed(1, 1, 1, Direct, 8_000, 2, 10, 10),
                    observed(2, 1, 2, Transit, 20_000, 2, 10, 10),
                    observed(3, 1, 3, Transit, 35_000, 2, 10, 10),
                ],
                &[1],
                0,
            ),
            Some(1)
        );
        // All three paths become stale from t=3,000 onward: current Direct path stays put without switching
        // every tick and without counting early deaths while no healthy replacement exists.
        for tick in 3..=8 {
            let tx = 10 + tick;
            assert_eq!(
                step(
                    &mut policy,
                    Some((1, Direct)),
                    &[
                        observed(1, 1, 1, Direct, 8_000, 2, 10, tx),
                        observed(2, 1, 2, Transit, 20_000, 2, 10, tx),
                        observed(3, 1, 3, Transit, 35_000, 2, 10, tx),
                    ],
                    &[1],
                    tick * 1_000,
                ),
                None,
                "tick {tick}"
            );
            assert_eq!(policy.recovery[0].delay, COOLDOWN_MS);
            assert_eq!(policy.recovery[0].direct_until, 0);
        }
        // If current disappears while remaining candidates are all stale, fallback still picks minimum RTT once.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Direct)),
                &[
                    observed(2, 1, 2, Transit, 20_000, 2, 10, 20),
                    observed(3, 1, 3, Transit, 35_000, 2, 10, 20),
                ],
                &[1],
                9_000,
            ),
            Some(2)
        );
        assert_eq!(policy.recovery[0].delay, 60_000);
        // Subsequent ticks on that stale fallback do not keep switching.
        assert_eq!(
            step(
                &mut policy,
                Some((2, Transit)),
                &[
                    observed(2, 1, 2, Transit, 20_000, 2, 10, 23),
                    observed(3, 1, 3, Transit, 15_000, 2, 10, 23),
                ],
                &[1],
                12_000,
            ),
            None
        );
    }

    #[test]
    fn stale_short_lived_direct_path_counts_once_and_preserves_backoff_and_other_gates() {
        let mut policy = Policy::new();
        // Establish an initial 60s direct hold from an earlier failure, then rescue to Direct path 2.
        assert_eq!(
            step(
                &mut policy,
                None,
                &[observed(2, 1, 2, Direct, 8_000, 1, 5, 5)],
                &[1],
                0,
            ),
            Some(2)
        );
        assert_eq!(
            step(
                &mut policy,
                Some((2, Direct)),
                &[observed(1, 1, 1, Transit, 40_000, 1, 5, 5)],
                &[1],
                1_000,
            ),
            Some(1)
        );
        assert_eq!(policy.recovery[0].delay, 60_000);
        // Rescue onto Direct path 4 when Transit path 1 vanishes at t=2,000.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[observed(4, 1, 4, Direct, 8_000, 1, 5, 5)],
                &[1],
                2_000,
            ),
            Some(4)
        );
        // Seed an unrelated gate entry on path 9 to verify stale rescue clears only current's gate.
        let mut other_gate = Gate::new(2_000);
        other_gate.candidate = Some(1);
        policy.gates.insert(9, other_gate);
        let mut current_gate = Gate::new(2_000);
        current_gate.candidate = Some(1);
        policy.gates.insert(4, current_gate);

        // Direct path 4 goes stale at t=5,000 while Transit path 1 is healthy -> rescues to 1 and doubles hold to 120s.
        assert_eq!(
            step(
                &mut policy,
                Some((4, Direct)),
                &[
                    observed(4, 1, 4, Direct, 8_000, 1, 5, 9),
                    observed(1, 1, 1, Transit, 40_000, 2, 9, 9),
                ],
                &[1],
                5_000,
            ),
            Some(1)
        );
        assert_eq!(policy.recovery[0].delay, 120_000);
        assert_eq!(policy.recovery[0].direct_until, 125_000);
        assert!(!policy.gates.contains_key(&4));
        assert_eq!(policy.gates.get(&9).and_then(|g| g.candidate), Some(1));
    }

    #[test]
    fn liveness_table_evicts_absent_paths_and_idle_peers_and_caps_capacity() {
        let mut policy = Policy::new();
        // Seed two paths on peer connection 1, then drop path 2 on the next select for connection 1.
        let initial = [
            observed(1, 1, 1, Transit, 10_000, 1, 1, 1),
            observed(2, 1, 2, Transit, 20_000, 1, 1, 1),
        ];
        let _ = step(&mut policy, Some((1, Transit)), &initial, &[1], 0);
        assert_eq!(policy.liveness.len(), 2);
        let kept = [observed(1, 1, 1, Transit, 10_000, 2, 2, 2)];
        let _ = step(&mut policy, Some((1, Transit)), &kept, &[1], 500);
        assert_eq!(policy.liveness.len(), 1);
        assert_eq!(policy.liveness[0].path, 1);

        // Other peers stay within LIVENESS_IDLE_MS, are LRU-evicted at MAX_LIVENESS, and expire once idle.
        for peer in 2..=(MAX_LIVENESS as u64 + 40) {
            let item = [observed(peer, peer, 1, Transit, 10_000, 1, 1, 1)];
            let _ = step(&mut policy, Some((peer, Transit)), &item, &[peer], 1_000 + peer);
            assert!(policy.liveness.len() <= MAX_LIVENESS);
        }
        assert_eq!(policy.liveness.len(), MAX_LIVENESS);

        let _ = step(
            &mut policy,
            Some((1, Transit)),
            &kept,
            &[1],
            1_000 + (MAX_LIVENESS as u64 + 40) + LIVENESS_IDLE_MS,
        );
        assert_eq!(policy.liveness.len(), 1);
        assert_eq!(policy.liveness[0].connection, 1);
        assert_eq!(policy.liveness[0].path, 1);
    }

    #[test]
    fn other_peer_select_does_not_reset_stale_observation() {
        let mut policy = Policy::new();
        let mut result = None;
        for t in 0..=4 {
            result = step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 5_000, 10, 20, 20 + t),
                    observed(2, 1, 1, Transit, 15_000, 10 + t, 20 + t, 20 + t),
                ],
                &[1],
                t * 1_000,
            );
            let _ = step(
                &mut policy,
                Some((3, Transit)),
                &[observed(3, 2, 1, Transit, 5_000, 10 + t, 20 + t, 20 + t)],
                &[2],
                t * 1_000,
            );
        }
        assert_eq!(
            result,
            Some(2),
            "another remote peer must not reset peer A liveness"
        );
    }

    #[test]
    fn capacity_overflow_untracked_shared_tuple_connection_is_not_stale() {
        for uninserted_first in [false, true] {
            let mut policy = Policy::new();
            let connections: Vec<u64> = (1..=513).collect();
            for t in 0..=4 {
                let mut activities: Vec<_> = (1..=512)
                    .map(|c| observed(c, c, 1, Transit, 5_000, 10, 20, 20 + t).1)
                    .collect();
                let extra = observed(1, 513, 1, Transit, 5_000, 10 + t, 20 + t, 20 + t).1;
                if uninserted_first && t > 0 {
                    activities.insert(0, extra);
                } else {
                    activities.push(extra);
                }
                policy.update_liveness(&activities, &connections, t * 1_000);
                if t == 4 {
                    assert!(
                        !policy.is_tuple_stale(&1, &activities, &connections, 4_000),
                        "active same-tuple connection omitted at capacity is not evidence of death"
                    );
                    // Tuple 2 has only connection 2, which stayed tracked without thrashing and is stale.
                    assert!(policy.is_tuple_stale(&2, &activities, &connections, 4_000));
                }
            }
        }
    }

    #[test]
    fn closed_connection_on_shared_tuple_does_not_block_remaining_stale_connection() {
        let mut policy = Policy::new();
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 8_000, 5, 10, 10),
                    observed(1, 2, 1, Transit, 8_000, 5, 10, 10),
                    observed(2, 2, 2, Transit, 20_000, 5, 10, 10),
                ],
                &[1, 2],
                0,
            ),
            None
        );
        // Connection 1 closes cleanly while connection 2 goes silent on tuple 1 (+3 tx, 0 rx).
        // Even though connection 1's entry has not hit LIVENESS_IDLE_MS yet, connection 2 rescues at 3s.
        assert_eq!(
            step(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 2, 1, Transit, 8_000, 5, 10, 13),
                    observed(2, 2, 2, Transit, 20_000, 8, 13, 13),
                ],
                &[2],
                3_000,
            ),
            Some(2)
        );
    }
}

#[cfg(test)]
mod probe_tests {
    use super::*;
    use Kind::{Direct, Transit};

    type ObservedPath = (Candidate<u64, u64>, Activity<u64, u64>);

    #[allow(clippy::too_many_arguments)]
    fn observed(
        id: u64,
        connection: u64,
        generation: u64,
        kind: Kind,
        us: u64,
        seq: u64,
        rx_frames: u64,
        tx_datagrams: u64,
    ) -> ObservedPath {
        (
            Candidate {
                path: id,
                kind,
                sample: Sample {
                    connection,
                    generation,
                    epoch: 0,
                    sequence: seq,
                    rtt_us: us,
                },
            },
            Activity {
                path: id,
                connection,
                generation,
                traffic: Traffic {
                    rx_frames,
                    tx_datagrams,
                },
            },
        )
    }

    fn step_probes(
        policy: &mut Policy<u64, u64>,
        current: Option<(u64, Kind)>,
        items: &[ObservedPath],
        connections: &[u64],
        now: u64,
    ) -> (Option<u64>, Vec<ProbeTarget<u64, u64>>) {
        let paths: Vec<_> = items.iter().map(|(c, _)| c.clone()).collect();
        let activities: Vec<_> = items.iter().map(|(_, a)| a.clone()).collect();
        let seen = current.is_some_and(|(id, _)| activities.iter().any(|a| a.path == id));
        let (chosen, probes) = policy.choose_observed(
            current.as_ref().map(|(id, kind)| (id, *kind)),
            seen,
            &paths,
            &activities,
            connections,
            now,
        );
        (chosen.map(|i| paths[i].path), probes)
    }

    fn target(connection: u64, path: u64, generation: u64) -> ProbeTarget<u64, u64> {
        ProbeTarget {
            connection,
            path,
            generation,
        }
    }

    #[test]
    fn unidirectional_downstream_frozen_current_probes_and_switches() {
        let mut policy = Policy::new();
        let mut cur_seq = 1;
        let mut switched_at = None;
        let mut probes_by_sec = Vec::new();

        for sec in 0..=10 {
            let now = sec * 1_000;
            let rx = 20 + sec * 5;
            let tx = 20 + sec * 5;
            let next_seq = 1 + sec;
            let (chosen, probes) = step_probes(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 30_000, cur_seq, rx, tx),
                    observed(2, 1, 2, Direct, 1_500, next_seq, 10 + sec, 10 + sec),
                ],
                &[1],
                now,
            );
            assert!(
                !probes.iter().any(|p| p.path == 2),
                "advancing candidate must not be probed"
            );
            probes_by_sec.push((sec, probes.clone()));
            if let Some(chosen_path) = chosen {
                assert_eq!(chosen_path, 2);
                assert!(probes.is_empty(), "switching tick cancels pending probes");
                switched_at = Some(now);
                break;
            }
            if probes.contains(&target(1, 1, 1)) {
                cur_seq += 1;
            }
        }
        // Window-tail probing emits 0 probes during t=0..3s, 1 probe at t=4s, and switches at t=5s.
        assert_eq!(switched_at, Some(5_000));
        for (sec, probes) in &probes_by_sec {
            if *sec == 4 {
                assert_eq!(probes, &vec![target(1, 1, 1)]);
            } else {
                assert!(probes.is_empty(), "sec {sec} unexpected probes: {probes:?}");
            }
        }

        // Once settled on Direct in initial Recovery tier, continuous unidirectional stream sends 0 probes.
        for sec in 6..=66 {
            let (_, probes) = step_probes(
                &mut policy,
                Some((2, Direct)),
                &[
                    observed(1, 1, 1, Transit, 30_000, cur_seq + sec, 60 + sec, 60 + sec),
                    observed(2, 1, 2, Direct, 1_500, 6, 100 + sec * 5, 100 + sec * 5),
                ],
                &[1],
                sec * 1_000,
            );
            assert!(probes.is_empty(), "steady-state tick {sec} must send zero probes");
        }
    }

    #[test]
    fn window_tail_lost_probe_retries_without_missing_round() {
        let mut policy = Policy::new();
        let mut cur_seq = 1;

        // t=0..3s: Gate arms at t=0 and checks gain without sending early probes.
        for sec in 0..=3 {
            let (chosen, probes) = step_probes(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 30_000, cur_seq, 20 + sec * 5, 20 + sec * 5),
                    observed(2, 1, 2, Direct, 1_500, 1 + sec, 10 + sec, 10 + sec),
                ],
                &[1],
                sec * 1_000,
            );
            assert_eq!(chosen, None);
            assert!(probes.is_empty(), "early window sec {sec} must not probe");
        }

        // t=4s: Window-tail probe #1 fires on stalled `current`, and its reply is LOST (`cur_seq` stays 1).
        let (chosen_4, probes_4) = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[
                observed(1, 1, 1, Transit, 30_000, cur_seq, 45, 45),
                observed(2, 1, 2, Direct, 1_500, 5, 14, 14),
            ],
            &[1],
            4_000,
        );
        assert_eq!(chosen_4, None);
        assert_eq!(probes_4, vec![target(1, 1, 1)]);

        // t=5s: Probe #1 is still within the 2s in-flight guard, and `Gate` stays armed (`since == 0`).
        let (chosen_5, probes_5) = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[
                observed(1, 1, 1, Transit, 30_000, cur_seq, 50, 50),
                observed(2, 1, 2, Direct, 1_500, 6, 15, 15),
            ],
            &[1],
            5_000,
        );
        assert_eq!(chosen_5, None);
        assert!(probes_5.is_empty());
        assert_eq!(policy.gates.get(&1).unwrap().since, 0);

        // t=6s: First tick after `PROBE_IN_FLIGHT_MS` expires immediately retries on `current`
        // without restarting the 5s observation window.
        let (chosen_6, probes_6) = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[
                observed(1, 1, 1, Transit, 30_000, cur_seq, 55, 55),
                observed(2, 1, 2, Direct, 1_500, 7, 16, 16),
            ],
            &[1],
            6_000,
        );
        assert_eq!(chosen_6, None);
        assert_eq!(probes_6, vec![target(1, 1, 1)]);
        cur_seq += 1;

        // t=7s: Retry reply arrives (`cur_seq == 2`) and completes the same observation round.
        let (chosen_7, probes_7) = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[
                observed(1, 1, 1, Transit, 30_000, cur_seq, 60, 60),
                observed(2, 1, 2, Direct, 1_500, 8, 17, 17),
            ],
            &[1],
            7_000,
        );
        assert_eq!(chosen_7, Some(2));
        assert!(probes_7.is_empty());
    }

    #[test]
    fn asymmetric_bidirectional_frozen_candidate_probes_and_switches() {
        let mut policy = Policy::new();
        let mut next_seq = 1;
        let mut probes_by_sec = Vec::new();
        let mut switched_at = None;

        for sec in 0..=8 {
            let now = sec * 1_000;
            // Candidate advances naturally for t=0..4s, then freezes at seq=5 once peer switches early.
            if (1..=4).contains(&sec) {
                next_seq += 1;
            }
            let (chosen, probes) = step_probes(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 28_000, 10 + sec * 5, 50 + sec * 5, 50 + sec * 5),
                    observed(2, 1, 2, Direct, 1_500, next_seq, 20 + sec * 5, 20 + sec * 5),
                ],
                &[1],
                now,
            );
            probes_by_sec.push((sec, probes.clone()));
            if let Some(chosen_path) = chosen {
                assert_eq!(chosen_path, 2);
                assert!(probes.is_empty());
                switched_at = Some(now);
                break;
            }
            if probes.contains(&target(1, 2, 2)) {
                next_seq += 1;
            }
        }
        assert_eq!(switched_at, Some(6_000));
        // Natural ACKs advanced both sides for t=0..4s (0 probes), t=5s probed Direct once, t=6s switched.
        for (sec, probes) in &probes_by_sec {
            if *sec == 5 {
                assert_eq!(probes, &vec![target(1, 2, 2)]);
            } else {
                assert!(probes.is_empty(), "sec {sec} unexpected probes: {probes:?}");
            }
        }
    }

    #[test]
    fn cooldown_and_direct_hold_and_capacity_emit_zero_probes() {
        let mut policy = Policy::new();
        // Initial selection on Transit path 1, then switch to Transit path 2 at t=3,000 -> 30s cooldown.
        let _ = step_probes(
            &mut policy,
            None,
            &[observed(1, 1, 1, Transit, 60_000, 1, 5, 5)],
            &[1],
            0,
        );
        let _ = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[
                observed(1, 1, 1, Transit, 60_000, 1, 6, 6),
                observed(2, 1, 2, Transit, 25_000, 1, 6, 6),
            ],
            &[1],
            1_000,
        );
        let (chosen, _) = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[
                observed(1, 1, 1, Transit, 60_000, 2, 10, 10),
                observed(2, 1, 2, Transit, 25_000, 2, 10, 10),
            ],
            &[1],
            4_000,
        );
        assert_eq!(chosen, Some(2));

        // Throughout cooldown (t=5,000..33,000), a faster Direct candidate with frozen seq gets 0 probes.
        for sec in 5..=33 {
            let (chosen, probes) = step_probes(
                &mut policy,
                Some((2, Transit)),
                &[
                    observed(2, 1, 2, Transit, 25_000, 2, 10 + sec, 10 + sec),
                    observed(3, 1, 3, Direct, 1_000, 1, 10 + sec, 10 + sec),
                ],
                &[1],
                sec * 1_000,
            );
            assert_eq!(chosen, None);
            assert!(probes.is_empty(), "cooldown sec {sec} must emit zero probes");
        }

        // Force an early Direct failure to enter 60s direct_until hold.
        let mut hold_policy = Policy::new();
        let _ = step_probes(
            &mut hold_policy,
            None,
            &[observed(3, 1, 3, Direct, 1_000, 1, 5, 5)],
            &[1],
            0,
        );
        // Path 3 disappears at t=5,000 -> rescues to Transit path 2 with 60s direct_until (until 65,000).
        let (rescued, probes) = step_probes(
            &mut hold_policy,
            Some((3, Direct)),
            &[observed(2, 1, 2, Transit, 25_000, 2, 10, 10)],
            &[1],
            5_000,
        );
        assert_eq!(rescued, Some(2));
        assert!(probes.is_empty());
        assert_eq!(hold_policy.recovery[0].direct_until, 65_000);

        for sec in 6..=64 {
            let (chosen, probes) = step_probes(
                &mut hold_policy,
                Some((2, Transit)),
                &[
                    observed(2, 1, 2, Transit, 25_000, 2, 10 + sec, 10 + sec),
                    observed(4, 1, 4, Direct, 1_000, 1, 10 + sec, 10 + sec),
                ],
                &[1],
                sec * 1_000,
            );
            assert_eq!(chosen, None);
            assert!(probes.is_empty(), "direct_until hold sec {sec} must emit zero probes");
        }

        // Disqualified candidate (!gain) and MAX_TRACKED gate capacity overflow also emit 0 probes.
        let mut cap_policy = Policy::new();
        for p in 100..(100 + MAX_TRACKED as u64) {
            cap_policy.gates.insert(p, Gate::new(0));
        }
        for sec in 0..=5 {
            let (_, no_gain_probes) = step_probes(
                &mut cap_policy,
                Some((100, Transit)),
                &[
                    observed(100, 1, 1, Transit, 20_000, 1, 10 + sec, 10 + sec),
                    observed(200, 1, 2, Direct, 19_000, 1, 10 + sec, 10 + sec),
                ],
                &[1],
                sec * 1_000,
            );
            assert!(no_gain_probes.is_empty());

            let (_, cap_probes) = step_probes(
                &mut cap_policy,
                Some((999, Transit)),
                &[
                    observed(999, 1, 9, Transit, 40_000, 1, 10 + sec, 10 + sec),
                    observed(200, 1, 2, Direct, 1_000, 1, 10 + sec, 10 + sec),
                ],
                &[1],
                sec * 1_000,
            );
            assert!(cap_probes.is_empty(), "capacity overflow must emit zero probes");
        }
    }

    #[test]
    fn lost_probe_responses_are_bounded_and_wait_for_independent_evidence() {
        let mut policy = Policy::new();
        // Arm at t=0; window-tail sends first probe at t=4,000.
        for sec in 0..=3 {
            let (_, early) = step_probes(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 30_000, 1 + sec, 10 + sec * 2, 10 + sec * 2),
                    observed(2, 1, 2, Direct, 1_000, 1, 10 + sec * 2, 10 + sec * 2),
                ],
                &[1],
                sec * 1_000,
            );
            assert!(early.is_empty());
        }

        let (_, p4) = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[
                observed(1, 1, 1, Transit, 30_000, 5, 18, 18),
                observed(2, 1, 2, Direct, 1_000, 1, 18, 18),
            ],
            &[1],
            4_000,
        );
        assert_eq!(p4, vec![target(1, 2, 2)]);

        // While the t=4,000 probe is still in flight (< PROBE_IN_FLIGHT_MS = 2,000 ms),
        // intermediate ticks emit zero duplicate probes.
        for t in [4_200, 4_500, 5_000, 5_999] {
            let (_, pi) = step_probes(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 30_000, 6 + t / 500, 20 + t / 200, 20 + t / 200),
                    observed(2, 1, 2, Direct, 1_000, 1, 20 + t / 200, 20 + t / 200),
                ],
                &[1],
                t,
            );
            assert!(pi.is_empty(), "in-flight guard violated at t={t}");
        }

        // Exhaust the remaining 5 burst probes at t=6, 8, 10, 12, 14s (`backoff_until = 44,000`),
        // verify complete silence throughout `[15s, 43s]`, and verify post-backoff rate is capped
        // to at most 1 probe per 30s (`remaining` stays 0 until independent ACK progress).
        let mut burst_sent = 1usize;
        for sec in 6..=43 {
            let (chosen, probes) = step_probes(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 30_000, 20 + sec, 50 + sec * 2, 50 + sec * 2),
                    observed(2, 1, 2, Direct, 1_000, 1, 50 + sec * 2, 50 + sec * 2),
                ],
                &[1],
                sec * 1_000,
            );
            assert_eq!(chosen, None);
            burst_sent += probes.len();
            if sec >= 15 {
                assert!(
                    probes.is_empty(),
                    "must remain silent throughout 30s backoff after burst budget exhausted (sec={sec})"
                );
            }
        }
        assert_eq!(burst_sent, usize::from(PROBE_BUDGET_MAX));
        assert_eq!(policy.probes.iter().find(|e| e.path == 2).unwrap().remaining, 0);

        let mut post_backoff_sent = 0usize;
        for sec in 44..=103 {
            let (chosen, probes) = step_probes(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 30_000, 20 + sec, 50 + sec * 2, 50 + sec * 2),
                    observed(2, 1, 2, Direct, 1_000, 1, 50 + sec * 2, 50 + sec * 2),
                ],
                &[1],
                sec * 1_000,
            );
            assert_eq!(chosen, None);
            post_backoff_sent += probes.len();
            assert_eq!(policy.probes.iter().find(|e| e.path == 2).unwrap().remaining, 0);
        }
        assert_eq!(post_backoff_sent, 2, "60s after backoff allows exactly 2 recovery probes (1 per 30s)");

        // Once an independent ACK advances Direct seq past `probe_seq_ceiling` after backoff,
        // `remaining` refills to `PROBE_BUDGET_MAX` and completes the switch.
        let ceiling = policy.probes.iter().find(|e| e.path == 2).unwrap().probe_seq_ceiling;
        let mut next_seq = ceiling + 1;
        let mut switched = false;
        for sec in 104..=110 {
            let (chosen, probes) = step_probes(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 30_000, 20 + sec, 50 + sec * 2, 50 + sec * 2),
                    observed(2, 1, 2, Direct, 1_000, next_seq, 50 + sec * 2, 50 + sec * 2),
                ],
                &[1],
                sec * 1_000,
            );
            if chosen == Some(2) {
                switched = true;
                break;
            }
            if probes.contains(&target(1, 2, 2)) {
                next_seq += 1;
            }
        }
        assert!(switched, "independent ACK evidence restores burst budget and completes switch");
        assert_eq!(
            policy.probes.iter().find(|e| e.path == 2).unwrap().remaining,
            PROBE_BUDGET_MAX
        );
    }

    #[test]
    fn generation_change_and_path_close_invalidate_old_probe_state() {
        let mut policy = Policy::new();
        for sec in 0..=3 {
            let _ = step_probes(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 30_000, 1 + sec, 10 + sec * 2, 10 + sec * 2),
                    observed(2, 1, 1, Direct, 1_000, 4, 10 + sec * 2, 10 + sec * 2),
                ],
                &[1],
                sec * 1_000,
            );
        }
        let (_, p4) = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[
                observed(1, 1, 1, Transit, 30_000, 5, 18, 18),
                observed(2, 1, 1, Direct, 1_000, 4, 18, 18),
            ],
            &[1],
            4_000,
        );
        assert_eq!(p4, vec![target(1, 2, 1)]);
        assert!(
            policy
                .probes
                .iter()
                .any(|e| e.path == 2 && e.generation == 1 && e.in_flight.is_some() && e.remaining == 5)
        );

        // Path 2 reopens as generation 2 at t=4,500: old generation-1 `in_flight` is cleared at once
        // while `remaining == 5` is preserved (not refilled to 6), and re-arming emits zero stale probes.
        let (_, p_rearm) = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[
                observed(1, 1, 1, Transit, 30_000, 6, 20, 20),
                observed(2, 1, 2, Direct, 1_000, 1, 2, 2),
            ],
            &[1],
            4_500,
        );
        assert!(p_rearm.is_empty());
        let entry = policy.probes.iter().find(|e| e.path == 2).unwrap();
        assert_eq!(entry.generation, 2);
        assert!(entry.in_flight.is_none());
        assert_eq!(entry.remaining, 5);

        // Reaching the new window tail on generation 2 targets generation 2 (`remaining` drops to 4).
        let (_, p_gen2) = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[
                observed(1, 1, 1, Transit, 30_000, 10, 28, 28),
                observed(2, 1, 2, Direct, 1_000, 1, 6, 6),
            ],
            &[1],
            8_500,
        );
        assert_eq!(p_gen2, vec![target(1, 2, 2)]);
        assert_eq!(policy.probes.iter().find(|e| e.path == 2).unwrap().remaining, 4);

        // Closing path 2 clears `in_flight` immediately while retaining budget debt until `LIVENESS_IDLE_MS`.
        let (_, p_closed) = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[observed(1, 1, 1, Transit, 30_000, 11, 30, 30)],
            &[1],
            9_000,
        );
        assert!(p_closed.is_empty());
        let closed_entry = policy.probes.iter().find(|e| e.path == 2).unwrap();
        assert!(closed_entry.in_flight.is_none());
        assert_eq!(closed_entry.remaining, 4);

        let _ = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[observed(1, 1, 1, Transit, 30_000, 70, 90, 90)],
            &[1],
            69_000,
        );
        assert!(!policy.probes.iter().any(|e| e.path == 2));
    }

    #[test]
    fn recovery_probes_only_when_penalized_at_three_minutes_and_resets_only_after_new_ack() {
        // 1. Initial tier (delay == COOLDOWN_MS, direct_until == 0): 10 minutes of frozen seq on Direct -> 0 probes.
        let mut clean_policy = Policy::new();
        let _ = step_probes(
            &mut clean_policy,
            None,
            &[observed(2, 1, 1, Direct, 1_500, 3, 10, 10)],
            &[1],
            0,
        );
        for sec in 1..=600 {
            let (_, probes) = step_probes(
                &mut clean_policy,
                Some((2, Direct)),
                &[observed(2, 1, 1, Direct, 1_500, 3, 10 + sec * 5, 10 + sec * 5)],
                &[1],
                sec * 1_000,
            );
            assert!(probes.is_empty(), "initial tier sec {sec} must never probe");
        }

        // 2. Penalized tier (early death -> delay = 60,000): probes once at 3 minutes, resets ONLY after new ACK.
        let mut policy = Policy::new();
        let _ = step_probes(
            &mut policy,
            None,
            &[observed(2, 1, 1, Direct, 1_500, 1, 5, 5)],
            &[1],
            0,
        );
        // Early failure at t=5,000 -> delay becomes 60,000.
        let _ = step_probes(
            &mut policy,
            Some((2, Direct)),
            &[observed(1, 1, 1, Transit, 30_000, 1, 5, 5)],
            &[1],
            5_000,
        );
        assert_eq!(policy.recovery[0].delay, 60_000);
        // Rescue back onto Direct (generation 2, seq=5) at t=10,000 when Transit disappears.
        let (chosen, _) = step_probes(
            &mut policy,
            Some((1, Transit)),
            &[observed(2, 1, 2, Direct, 1_500, 5, 10, 10)],
            &[1],
            10_000,
        );
        assert_eq!(chosen, Some(2));
        assert_eq!(policy.recovery[0].delay, 60_000);

        // Before 3 minutes on Direct (t=11,000..189,000, elapsed < 180,000 ms): 0 probes, delay stays 60,000.
        for sec in 11..=189 {
            let (_, probes) = step_probes(
                &mut policy,
                Some((2, Direct)),
                &[observed(2, 1, 2, Direct, 1_500, 5, 20 + sec * 5, 20 + sec * 5)],
                &[1],
                sec * 1_000,
            );
            assert!(probes.is_empty(), "sec {sec} before 3 min must not probe");
            assert_eq!(policy.recovery[0].delay, 60_000);
        }

        // At t=190,000 (elapsed == 180,000 ms) with seq still 5: requests 1 confirmation probe, does NOT reset yet!
        let (_, p_180) = step_probes(
            &mut policy,
            Some((2, Direct)),
            &[observed(2, 1, 2, Direct, 1_500, 5, 1_000, 1_000)],
            &[1],
            190_000,
        );
        assert_eq!(p_180, vec![target(1, 2, 2)]);
        assert_eq!(
            policy.recovery[0].delay, 60_000,
            "inbound frames and wall time alone must not reset Recovery before ACK"
        );

        // Without ACK at t=191,000 (seq still 5): still not reset, and in-flight guard emits 0 probes.
        let (_, p_181_no_ack) = step_probes(
            &mut policy,
            Some((2, Direct)),
            &[observed(2, 1, 2, Direct, 1_500, 5, 1_005, 1_005)],
            &[1],
            191_000,
        );
        assert!(p_181_no_ack.is_empty());
        assert_eq!(policy.recovery[0].delay, 60_000);

        // Once same-generation ACK arrives (seq: 5 -> 6) at t=191,500: Recovery resets, and later ticks emit 0 probes.
        let (_, p_ack) = step_probes(
            &mut policy,
            Some((2, Direct)),
            &[observed(2, 1, 2, Direct, 1_500, 6, 1_008, 1_008)],
            &[1],
            191_500,
        );
        assert!(p_ack.is_empty());
        assert_eq!(policy.recovery[0].delay, COOLDOWN_MS);
        assert_eq!(policy.recovery[0].direct_until, 0);

        for sec in 192..=210 {
            let (_, probes) = step_probes(
                &mut policy,
                Some((2, Direct)),
                &[observed(2, 1, 2, Direct, 1_500, 6, 1_010 + sec, 1_010 + sec)],
                &[1],
                sec * 1_000,
            );
            assert!(probes.is_empty());
        }
    }

    #[test]
    fn gate_reset_does_not_refill_probe_budget() {
        let mut policy = Policy::new();
        let mut cur_seq = 1;
        let mut total_probes = 0usize;

        // Every 6th second (sec % 6 == 5, right after the t=4s window-tail probe), candidate RTT
        // spikes to 29.5 ms (!gain -> Gate.reset()) and then recovers. Even when every probe is
        // answered by +1 seq, repeated Gate.reset() cycles exhaust PROBE_BUDGET_MAX at sec=34
        // and stay completely silent throughout the 30s backoff (sec=35..=63).
        for sec in 0..=63 {
            let now = sec * 1_000;
            let cand_rtt = if sec % 6 == 5 { 29_500 } else { 1_500 };
            let (chosen, probes) = step_probes(
                &mut policy,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 30_000, cur_seq, 20 + sec * 4, 20 + sec * 4),
                    observed(2, 1, 2, Direct, cand_rtt, 1 + sec, 20 + sec, 20 + sec),
                ],
                &[1],
                now,
            );
            assert_eq!(chosen, None);
            total_probes += probes.len();
            if probes.contains(&target(1, 1, 1)) {
                cur_seq += 1;
            }
            if sec >= 35 {
                assert!(
                    probes.is_empty(),
                    "Gate.reset() must not refresh probe budget during backoff (sec={sec})"
                );
            }
        }
        assert_eq!(total_probes, usize::from(PROBE_BUDGET_MAX));
        assert_eq!(policy.probes.iter().find(|e| e.path == 1).unwrap().remaining, 0);
    }

    #[test]
    fn review_exhausted_current_eventually_retries_after_candidate_stabilizes() {
        let mut p = Policy::new();
        let mut seq = 1;
        for sec in 0..=60 {
            let (_, probes) = step_probes(
                &mut p,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 30_000, seq, 100 + sec, 100 + sec),
                    observed(
                        2,
                        1,
                        2,
                        Direct,
                        if sec % 6 == 5 { 29_500 } else { 1_500 },
                        1 + sec,
                        100 + sec,
                        100 + sec,
                    ),
                ],
                &[1],
                sec * 1_000,
            );
            if probes.contains(&target(1, 1, 1)) {
                seq += 1;
            }
        }
        assert_eq!(p.probes.iter().find(|e| e.path == 1).unwrap().remaining, 0);

        let mut switched = false;
        let mut retry_count = 0;
        for sec in 61..=600 {
            let (chosen, probes) = step_probes(
                &mut p,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 30_000, seq, 100 + sec, 100 + sec),
                    observed(2, 1, 2, Direct, 1_500, 1 + sec, 100 + sec, 100 + sec),
                ],
                &[1],
                sec * 1_000,
            );
            retry_count += probes.len();
            if probes.contains(&target(1, 1, 1)) {
                seq += 1;
            }
            if chosen == Some(2) {
                switched = true;
                break;
            }
        }
        assert!(
            switched,
            "healthy stable candidate must not remain blocked forever after backoff"
        );
        assert_eq!(retry_count, 1);
    }

    #[test]
    fn review_late_probe_reply_is_not_independent_budget_refill() {
        let mut s = observed(1, 1, 1, Transit, 30_000, 1, 10, 10).0.sample;
        let mut p = ProbeState::new(1, 1, &s, 0);
        // Five probe replies arrive promptly, without any natural ACK progress.
        for i in 0..5 {
            let t = i * 3_000;
            p.observe(&s, t);
            assert!(p.try_send(t));
            s.sequence += 1;
            p.observe(&s, t + 1_000);
        }
        p.observe(&s, 15_000);
        assert!(p.try_send(15_000));
        assert_eq!(p.remaining, 0);
        p.observe(&s, 17_000);
        assert!(p.in_flight.is_none());
        // Sixth probe's only ACK is delayed until after its timeout, with candidate inactive.
        s.sequence += 1;
        p.observe(&s, 18_000);
        p.observe(&s, 45_000);
        assert_eq!(
            p.remaining, 0,
            "late probe-only ACK must not replenish independent-evidence budget"
        );
    }

    #[test]
    fn review_missing_rtt_same_generation_keeps_budget_debt() {
        let mut p = Policy::new();
        let mut s = observed(2, 1, 9, Direct, 1_000, 1, 10, 10).0.sample;
        let idx = p.ensure_probe_state(&2, &s, &[1], 0).unwrap();
        for i in 0..6 {
            p.probes[idx].observe(&s, i * 2_000);
            assert!(p.probes[idx].try_send(i * 2_000));
        }
        assert_eq!(p.probes[idx].remaining, 0);
        // Adapter omits Candidate when same_path_rtt is None, although connection/path persists.
        p.update_probes(&[], &[1], 11_000);
        let idx = p.ensure_probe_state(&2, &s, &[1], 12_000).unwrap();
        assert_eq!(
            p.probes[idx].remaining, 0,
            "temporary absence must not refill the incarnation budget"
        );
        assert!(!p.probes[idx].try_send(12_000));
        // Bumping generation on the same (connection, path) before backoff expires also keeps debt.
        s.generation = 10;
        let idx = p.ensure_probe_state(&2, &s, &[1], 13_000).unwrap();
        assert_eq!(p.probes[idx].remaining, 0);
        assert!(!p.probes[idx].try_send(13_000));
    }

    #[test]
    fn review_other_peer_preserves_budget_and_inflight() {
        let mut p = Policy::new();
        let a = observed(1, 1, 1, Transit, 30_000, 1, 10, 10).0;
        let b = observed(2, 2, 1, Transit, 30_000, 1, 10, 10).0;
        let idx = p.ensure_probe_state(&a.path, &a.sample, &[1], 0).unwrap();
        assert!(p.probes[idx].try_send(0));
        p.update_probes(&[b], &[2], 1_000);
        assert_eq!(p.probes.len(), 1);
        assert_eq!(p.probes[0].remaining, 5);
        assert_eq!(p.probes[0].in_flight, Some((1, 0)));
        p.update_probes(&[a], &[1], 1_500);
        assert_eq!(p.probes[0].remaining, 5);
        assert_eq!(p.probes[0].in_flight, Some((1, 0)));
        p.update_probes(&[], &[2], 61_500);
        assert!(p.probes.is_empty());
    }

    #[test]
    fn review_recovery_shares_exhausted_budget_and_confirms_after_backoff() {
        let mut p = Policy::new();
        let item = observed(2, 1, 1, Direct, 1_000, 1, 10, 10);
        let idx = p.ensure_probe_state(&2, &item.0.sample, &[1], 0).unwrap();
        for i in 0..6 {
            p.probes[idx].observe(&item.0.sample, i * 2_000);
            assert!(p.probes[idx].try_send(i * 2_000));
        }
        let mut r = Recovery::new(1, 0);
        r.delay = 60_000;
        r.selected(&2, Direct, Some(&item.0.sample), 0);
        p.recovery.push(r);

        let mut seq = 1;
        let mut confirm_probes = 0usize;
        for sec in 180..=185 {
            let (_, probes) = step_probes(
                &mut p,
                Some((2, Direct)),
                &[observed(2, 1, 1, Direct, 1_000, seq, 100 + sec, 100 + sec)],
                &[1],
                sec * 1_000,
            );
            confirm_probes += probes.len();
            if probes.contains(&target(1, 2, 1)) {
                seq += 1;
            }
        }
        assert_eq!(confirm_probes, 1);
        assert_eq!(p.recovery[0].delay, COOLDOWN_MS);
    }

    #[test]
    fn reviewer_generation_churn_is_burst_bounded() {
        let mut s = observed(1, 1, 1, Transit, 30_000, 1, 10, 10).0.sample;
        let mut p = ProbeState::new(1, 1, &s, 0);
        let mut sent = Vec::new();
        for t in 0..=90_006 {
            s.generation += 1;
            p.observe(&s, t);
            if p.try_send(t) {
                sent.push(t);
            }
        }
        assert_eq!(&sent[..6], &[0, 1, 2, 3, 4, 5]);
        assert_eq!(&sent[6..], &[30_005, 60_005, 90_005]);
        assert_eq!(p.remaining, 0);
    }

    #[test]
    fn reviewer_observing_advancing_paths_never_probe() {
        let mut p = Policy::new();
        for sec in 0..=5 {
            let (choice, probes) = step_probes(
                &mut p,
                Some((1, Transit)),
                &[
                    observed(1, 1, 1, Transit, 30_000, sec + 1, 100 + sec, 100 + sec),
                    observed(2, 1, 1, Direct, 1_000, sec + 1, 100 + sec, 100 + sec),
                ],
                &[1],
                sec * 1_000,
            );
            assert!(probes.is_empty());
            assert_eq!(choice, if sec == 5 { Some(2) } else { None });
        }
    }

    #[test]
    fn reviewer_observing_only_allows_independent_recovery_probe() {
        let mut p = Policy::new();
        let old = observed(1, 2, 1, Direct, 31_000, 1, 100, 100);
        let mut recovery = Recovery::new(2, 0);
        recovery.delay = 60_000;
        recovery.selected(&1, Direct, Some(&old.0.sample), 0);
        p.recovery.push(recovery);
        for (now, seq) in [(180_000, 10), (182_000, 11)] {
            let (chosen, probes) = step_probes(
                &mut p,
                Some((1, Direct)),
                &[
                    observed(1, 1, 1, Direct, 30_000, seq, now, now),
                    observed(1, 2, 1, Direct, 31_000, 1, now, now),
                    observed(2, 1, 1, Direct, 1_000, seq, now, now),
                ],
                &[1, 2],
                now,
            );
            assert_eq!(chosen, None);
            assert_eq!(probes, vec![target(2, 1, 1)]);
        }
        let gate = p.gates.get(&1).unwrap();
        assert_eq!(gate.since, 180_000);
        assert_eq!(gate.compared.as_ref().unwrap().0.sequence, 11);
    }

    #[test]
    fn reviewer_epoch_reset_does_not_erase_unanswered_probe_debt() {
        let mut p = Policy::new();
        let mut item = observed(1, 1, 1, Transit, 30_000, 10, 100, 100);
        let idx = p.ensure_probe_state(&1, &item.0.sample, &[1], 0).unwrap();
        for t in (0..=10_000).step_by(2_000) {
            p.probes[idx].observe(&item.0.sample, t);
            assert!(p.probes[idx].try_send(t));
        }
        assert_eq!(p.probes[idx].remaining, 0);
        // Cross-path ACK invalidates RTT, resets sequence, and increments epoch while
        // the same path and generation stay active in `Activity`.
        p.update_probes_with_activities(&[], &[item.1.clone()], &[1], 11_000);
        item.0.sample.epoch = 1;
        // Two previously sent probes are acknowledged on-path in packet-number order,
        // without any independent application ACK.
        for (t, seq) in [(12_000, 1), (13_000, 2)] {
            item.0.sample.sequence = seq;
            p.update_probes_with_activities(&[item.0.clone()], &[item.1.clone()], &[1], t);
        }
        p.update_probes_with_activities(&[item.0.clone()], &[item.1.clone()], &[1], 40_000);
        assert_eq!(
            p.probes[idx].remaining, 0,
            "epoch reset must not turn old probe replies into independent evidence"
        );
        // Once genuine natural ACKs advance sequence past the migrated ceiling (`7`),
        // independent evidence refills the budget cleanly.
        item.0.sample.sequence = 8;
        p.update_probes_with_activities(&[item.0.clone()], &[item.1], &[1], 41_000);
        assert_eq!(p.probes[idx].remaining, PROBE_BUDGET_MAX);
    }
}
