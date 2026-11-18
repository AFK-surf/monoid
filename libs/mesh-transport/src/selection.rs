//! Compare validated native and mesh paths without reacting to a short spike.
use crate::hub::Hub;
use iroh::endpoint::transports::{FourTuple, PathSelection, PathSelectionConnection, PathSelectionContext, PathSelector};
use std::{collections::HashMap, sync::{Arc, Mutex}};

use n0_future::time::Instant;

const OBSERVE_MS: u64 = 3_000;
const COOLDOWN_MS: u64 = 30_000;
const MAX_TRACKED: usize = 512;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Sample<S> {
    connection: S,
    generation: u64,
    epoch: u64,
    sequence: u64,
    rtt_ms: u64,
}
impl<S: Eq> Sample<S> {
    fn same_source(&self, other: &Self) -> bool {
        self.connection == other.connection && self.generation == other.generation
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
        Self { candidate: None, compared: None, since: now, cooldown: 0, touched: now }
    }
    fn consider(&mut self, candidate: T, current: Sample<S>, next: Sample<S>, now: u64) -> bool {
        self.touched = now;
        let gain = next.rtt_ms.saturating_add(10.max(current.rtt_ms / 5)) <= current.rtt_ms;
        if !gain || now < self.cooldown || current.sequence == 0 || next.sequence == 0 {
            self.candidate = None;
            self.compared = None;
            return false;
        }
        let same_sources = self.compared.as_ref().is_some_and(|(old_current, old_next)| {
            current.same_source(old_current) && next.same_source(old_next)
                && current.sequence >= old_current.sequence && next.sequence >= old_next.sequence
        });
        if self.candidate.as_ref() != Some(&candidate) || !same_sources {
            self.candidate = Some(candidate);
            self.compared = Some((current, next));
            self.since = now;
            return false;
        }
        let (old_current, old_next) = self.compared.as_ref().unwrap();
        // Both sides must provide a new actual RTT sample. Wall time, ACK-frame
        // counts and repeated readings of the same snapshot cannot advance evidence.
        if current.sequence == old_current.sequence || next.sequence == old_next.sequence {
            return false;
        }
        self.compared = Some((current, next));
        now.saturating_sub(self.since) >= OBSERVE_MS
    }
}

#[derive(Debug)]
pub struct Selector {
    hub: Arc<Hub>,
    epoch: Instant,
    trace_routing: bool,
    gates: Mutex<HashMap<FourTuple, Gate<FourTuple, PathSelectionConnection>>>,
}
impl Selector {
    fn reset_observation(&self, current: Option<&FourTuple>) {
        if let Some(current) = current
            && let Some(gate) = self.gates.lock().unwrap().get_mut(current) {
            gate.candidate = None;
            gate.compared = None;
        }
    }
    pub fn new(hub: Arc<Hub>) -> Self {
        Self { hub, epoch: Instant::now(), trace_routing: std::env::var_os("MESH_TRACE_ROUTING").is_some(), gates: Mutex::new(HashMap::new()) }
    }
}
impl PathSelector for Selector {
    fn select(&self, ctx: &PathSelectionContext<'_>) -> PathSelection {
        let now = self.epoch.elapsed().as_millis().min(u64::MAX as u128) as u64;
        let mut current_rtt = None;
        let mut best = None;
        let mut first = None;
        let mut current_seen = false;
        for path in ctx.paths() {
            if !self.hub.selectable(&path.network_path().remote()) { continue; }
            let is_current = Some(path.network_path()) == ctx.current();
            current_seen |= is_current;
            if first.is_none() { first = Some(path.clone()); }
            let Some(stats) = path.stats() else { continue };
            let Some(rtt) = stats.same_path_rtt else { continue };
            let Some(connection) = path.connection() else { continue };
            let sample = Sample {
                connection,
                generation: stats.path_generation,
                epoch: stats.same_path_rtt_epoch,
                sequence: stats.same_path_rtt_samples,
                rtt_ms: rtt.as_millis().min(u64::MAX as u128) as u64,
            };
            if is_current && current_rtt.as_ref().is_none_or(|old: &Sample<PathSelectionConnection>| sample.rtt_ms < old.rtt_ms) {
                current_rtt = Some(sample.clone());
            }
            if best.as_ref().is_none_or(|(_, old): &(_, Sample<PathSelectionConnection>)| sample.rtt_ms < old.rtt_ms) {
                best = Some((path, sample));
            }
        }
        let mut selection = PathSelection::none();
        let Some((best, rtt)) = best else {
            self.reset_observation(ctx.current());
            if ctx.current().is_none() && let Some(first) = first { selection.set(&first); }
            return selection;
        };
        // A validated replacement exists. Retire only circuits removed by routing,
        // never healthy backups that merely lost the preference comparison.
        let replacement_routed=self.hub.routed(&best.network_path().remote());
        for path in ctx.paths() {
            if replacement_routed && path.network_path() != best.network_path()
                && self.hub.withdrawn(&path.network_path().remote()) {
                selection.close(&path);
            }
        }
        // A failed/withdrawn circuit has no hold-down. Its replacement still has
        // to pass the inner QUIC path validation (same_path_rtt above).
        if !current_seen {
            if self.trace_routing {
                eprintln!("MESH_DIAG select now={now} reason=current-not-selectable current={:?} best={:?} generation={} epoch={} samples={} rtt_ms={}", ctx.current(), best.network_path(), rtt.generation, rtt.epoch, rtt.sequence, rtt.rtt_ms);
            }
            self.reset_observation(ctx.current());
            selection.set(&best);
            return selection;
        }
        let Some(current_rtt) = current_rtt else {
            self.reset_observation(ctx.current());
            return selection;
        };
        let current = ctx.current().expect("current path seen");
        let mut gates = self.gates.lock().unwrap();
        gates.retain(|_, gate| now.saturating_sub(gate.touched) < 60_000);
        if best.network_path() == current {
            if let Some(gate) = gates.get_mut(current) { gate.candidate = None; }
            return selection;
        }
        // Capacity exhaustion keeps the working path; it never disables failover.
        if !gates.contains_key(current) && gates.len() >= MAX_TRACKED { return selection; }
        if gates.entry(current.clone()).or_insert_with(|| Gate::new(now))
            .consider(best.network_path().clone(), current_rtt, rtt, now) {
            if self.trace_routing {
                eprintln!("MESH_DIAG select now={now} reason=fresh-gate current={current:?} best={:?}", best.network_path());
            }
            selection.set(&best);
            gates.remove(current);
            let mut next = Gate::new(now);
            next.cooldown = now.saturating_add(COOLDOWN_MS);
            gates.insert(best.network_path().clone(), next);
        }
        selection
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample(connection: u64, generation: u64, sequence: u64, rtt_ms: u64) -> Sample<u64> {
        Sample { connection, generation, epoch: 0, sequence, rtt_ms }
    }
    #[test]
    fn repeated_snapshots_do_not_turn_a_spike_into_sustained_gain() {
        let mut gate = Gate::new(0);
        let current = sample(1, 1, 1, 400);
        let next = sample(1, 2, 1, 30);
        assert!(!gate.consider(2, current.clone(), next.clone(), 0));
        assert!(!gate.consider(2, current.clone(), next.clone(), 3_000));
        assert!(!gate.consider(2, current.clone(), next.clone(), 60_000));
        assert!(!gate.consider(2, sample(1, 1, 2, 30), sample(1, 2, 2, 40), 60_001));
    }
    #[test]
    fn equal_rtt_new_samples_count_but_each_side_must_advance() {
        let mut gate = Gate::new(0);
        assert!(!gate.consider(2, sample(1, 1, 1, 400), sample(1, 2, 1, 30), 0));
        assert!(!gate.consider(2, sample(1, 1, 2, 400), sample(1, 2, 1, 30), 3_000));
        assert!(gate.consider(2, sample(1, 1, 2, 400), sample(1, 2, 2, 30), 3_000));
    }
    #[test]
    fn path_response_initial_estimates_do_not_start_sustained_evidence() {
        let mut gate = Gate::new(0);
        assert!(!gate.consider(2, sample(1, 1, 0, 400), sample(1, 2, 0, 30), 0));
        assert!(!gate.consider(2, sample(1, 1, 1, 400), sample(1, 2, 1, 30), 3_000));
        assert!(!gate.consider(2, sample(1, 1, 2, 400), sample(1, 2, 2, 30), 5_999));
        assert!(gate.consider(2, sample(1, 1, 3, 400), sample(1, 2, 3, 30), 6_000));
    }
    #[test]
    fn missed_invalidation_still_restarts_evidence() {
        for change_current in [true, false] {
            let mut gate = Gate::new(0);
            let mut current = sample(1, 1, 1, 400);
            let mut next = sample(1, 2, 1, 30);
            assert!(!gate.consider(2, current.clone(), next.clone(), 0));
            // The selector never saw None, but the estimator was invalidated and recovered.
            if change_current { current.epoch += 1; } else { next.epoch += 1; }
            current.sequence += 1; next.sequence += 1;
            assert!(!gate.consider(2, current.clone(), next.clone(), 3_000));
            current.sequence += 1; next.sequence += 1;
            assert!(gate.consider(2, current, next, 6_000));
        }
    }
    #[test]
    fn observation_and_cooldown_boundaries_keep_their_existing_durations() {
        let mut gate = Gate::new(0);
        assert!(!gate.consider(2, sample(1, 1, 1, 400), sample(1, 2, 1, 30), 0));
        assert!(!gate.consider(2, sample(1, 1, 2, 400), sample(1, 2, 2, 30), 2_999));
        assert!(gate.consider(2, sample(1, 1, 3, 400), sample(1, 2, 3, 30), 3_000));
        gate.cooldown = 33_000;
        assert!(!gate.consider(2, sample(1, 1, 4, 400), sample(1, 2, 4, 30), 32_999));
        assert!(!gate.consider(2, sample(1, 1, 5, 400), sample(1, 2, 5, 30), 33_000));
        assert!(gate.consider(2, sample(1, 1, 6, 400), sample(1, 2, 6, 30), 36_000));
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
            assert!(!gate.consider(2, sample(1, 1, 1, 400), sample(1, 2, 1, 30), 0));
            assert!(!gate.consider(2, current.clone(), next.clone(), 3_000));
            assert!(!gate.consider(2, Sample { sequence: 10, ..current.clone() }, Sample { sequence: 10, ..next.clone() }, 5_999));
            assert!(gate.consider(2, Sample { sequence: 11, ..current }, Sample { sequence: 11, ..next }, 6_000));
        }
    }
}
