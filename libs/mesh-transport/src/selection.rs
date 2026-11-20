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
    fn consider(
        &mut self,
        candidate: T,
        current: Sample<S>,
        next: Sample<S>,
        now: u64,
        kinds: (Kind, Kind),
    ) -> bool {
        self.touched = now;
        let gain = next
            .rtt_us
            .checked_add(kinds.0.margin(kinds.1, current.rtt_us))
            .is_some_and(|required| required <= current.rtt_us);
        if !gain || now < self.cooldown || current.sequence == 0 || next.sequence == 0 {
            self.reset();
            return false;
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
            return false;
        }
        let (old_current, old_next) = self.compared.as_ref().unwrap();
        // Repeated snapshots and PATH_RESPONSE estimates cannot advance evidence.
        if current.sequence == old_current.sequence || next.sequence == old_next.sequence {
            return false;
        }
        self.compared = Some((current, next));
        now.saturating_sub(self.since) >= kinds.0.observation(kinds.1)
    }
}

#[derive(Clone, Debug)]
struct Candidate<T, S> {
    path: T,
    kind: Kind,
    sample: Sample<S>,
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
    ) {
        self.touched = now;
        if !seen {
            // Consume this transition once, even if no replacement is available yet.
            if let Some(stay) = self.stay.take()
                && stay.kind == Kind::Direct
                && now.saturating_sub(stay.since) < STABLE_DIRECT_MS
            {
                self.delay = self.delay.saturating_mul(2).min(MAX_DIRECT_HOLD_MS);
                self.direct_until = now.saturating_add(self.delay);
            }
            return;
        }
        let Some((path, kind)) = current else { return };
        if self.stay.as_ref().is_none_or(|stay| &stay.path != path) {
            self.selected(path, kind, sample, now);
            return;
        }
        let stay = self.stay.as_mut().unwrap();
        if kind != Kind::Direct {
            return;
        }
        let Some(sample) = sample.filter(|s| s.sequence != 0) else {
            return;
        };
        let Some(old) = &stay.last_sample else {
            stay.evidence_since = now;
            stay.last_sample = Some(sample.clone());
            return;
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
        stay.last_sample = Some(sample.clone());
    }
}

#[derive(Debug)]
struct Policy<T, S> {
    gates: HashMap<T, Gate<T, S>>,
    recovery: Vec<Recovery<T, S>>,
}
impl<T: Eq + Hash + Clone, S: Eq + Clone> Policy<T, S> {
    fn new() -> Self {
        Self {
            gates: HashMap::new(),
            recovery: Vec::new(),
        }
    }
    fn reset(&mut self, current: Option<(&T, Kind)>) {
        if let Some((path, _)) = current
            && let Some(gate) = self.gates.get_mut(path)
        {
            gate.reset();
        }
    }
    /// Pure decision step. The adapter supplies a monotonic elapsed time and selectable paths.
    fn choose(
        &mut self,
        current: Option<(&T, Kind)>,
        seen: bool,
        paths: &[Candidate<T, S>],
        connections: &[S],
        now: u64,
    ) -> Option<usize> {
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
            r.observe(current, seen, sample, now);
        }
        if let Some((path, _)) = current
            && let Some(gate) = self.gates.get_mut(path)
        {
            gate.touched = now;
        }
        self.gates
            .retain(|_, gate| now.saturating_sub(gate.touched) < 60_000);
        let best = paths
            .iter()
            .enumerate()
            .min_by_key(|(_, p)| p.sample.rtt_us)
            .map(|(i, _)| i);
        if !seen {
            self.reset(current);
            if let Some(i) = best {
                self.switched(current, &paths[i], paths, connections, now);
            }
            return best;
        }
        let Some((current_path, current_kind)) = current else {
            return None;
        };
        let Some(current_sample) = paths
            .iter()
            .filter(|p| &p.path == current_path && p.sample.sequence != 0)
            .min_by_key(|p| p.sample.rtt_us)
            .map(|p| &p.sample)
        else {
            self.reset(current);
            return None;
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
            return None;
        };
        // Still rank different network paths. A genuinely faster eligible path starts
        // its own observation, while another sample of this candidate keeps its sources.
        let (i, next) = match pinned {
            Some((_, index, pinned_next)) if pinned_next.path == next.path => (index, pinned_next),
            _ => (i, next),
        };
        // Capacity exhaustion keeps a working path, but never blocks the failure branch above.
        if !self.gates.contains_key(current_path) && self.gates.len() >= MAX_TRACKED {
            return None;
        }
        let gate = self
            .gates
            .entry(current_path.clone())
            .or_insert_with(|| Gate::new(now));
        gate.cooldown = cooldown;
        if !gate.consider(
            next.path.clone(),
            current_sample.clone(),
            next.sample.clone(),
            now,
            (current_kind, next.kind),
        ) {
            return None;
        }
        self.switched(current, next, paths, connections, now);
        Some(i)
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
            let Some(rtt) = stats.same_path_rtt else {
                continue;
            };
            let Some(connection) = path.connection() else {
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
        // Keep the existing withdrawal rule. Preference alone never retires a backup path.
        if let Some(best) = paths.iter().min_by_key(|p| p.sample.rtt_us) {
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
        let current = ctx.current().map(|p| (p, Kind::of(p)));
        let mut policy = self.policy.lock().unwrap();
        let chosen = policy.choose(current, current_seen, &paths, &connections, now);
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
