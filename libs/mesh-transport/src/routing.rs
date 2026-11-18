//! The caller owns the clock, directory, and authenticated neighbor links.
//! A route search stores no network graph. Data follows a checked source route.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

pub type Node = [u8; 32];
pub type Scope = [u8; 32];
pub const MAX_HOPS: usize = 8;
pub const MAX_NODES: usize = 256;
pub const MAX_PACKET: usize = 16_384;
const MAX_SEARCHES: usize = 64;
const MAX_SEEN: usize = 512;
const SEARCH_MS: u64 = 3_000;
const IDLE_MS: u64 = 45_000;
const PROBE_MS: u64 = 1_000;
const DEAD_MS: u64 = 6_000;

/// Both directions use the same circuit identity within one scope and policy.
/// A changed path or policy gets fresh QUIC validation and congestion state.
/// An empty path names this domain's bootstrap address, never a selected circuit.
pub fn circuit(scope: Scope, policy: [u8; 32], path: &[Node]) -> [u8; 32] {
    let mut hash = blake3::Hasher::new_derive_key("still.fail mesh circuit v2");
    hash.update(&scope);
    hash.update(&policy);
    if path.first() < path.last() {
        for n in path {
            hash.update(n);
        }
    } else {
        for n in path.iter().rev() {
            hash.update(n);
        }
    }
    *hash.finalize().as_bytes()
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum Message {
    Discover {
        request: u64,
        target: Node,
        #[serde(deserialize_with = "read_path")]
        path: Vec<Node>,
    },
    Offer {
        request: u64,
        #[serde(deserialize_with = "read_path")]
        path: Vec<Node>,
        cursor: u8,
    },
    Data {
        #[serde(deserialize_with = "read_path")]
        path: Vec<Node>,
        cursor: u8,
        #[serde(deserialize_with = "read_packet")]
        packet: Vec<u8>,
    },
    Broken {
        #[serde(deserialize_with = "read_path")]
        path: Vec<Node>,
        cursor: u8,
    },
    Probe {
        #[serde(deserialize_with = "read_path")]
        path: Vec<Node>,
        cursor: u8,
        request: u64,
        reply: bool,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Frame {
    pub scope: Scope,
    pub message: Message,
}

#[derive(Debug)]
pub enum Action {
    Send(Node, Frame),
    Deliver(Node, Vec<u8>, [u8; 32]),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Route {
    pub path: Vec<Node>,
    pub rtt_ms: u64,
    pub until: u64,
    pub last_good: u64,
    pub probes: Vec<(u64, u64)>,
    pub next_probe: u64,
    pub baseline_ms: u64,
    pub slow_samples: u8,
    pub good_samples: u8,
    // Only records that a packet arrived on this circuit, not identity or quality.
    peer_seen: bool,
}

#[derive(Debug)]
struct Search {
    satisfied: bool,
    request: u64,
    started: u64,
}

#[derive(Debug)]
pub struct Router {
    me: Node,
    scope: Scope,
    policy: [u8; 32],
    allowed: BTreeSet<Node>,
    transit: BTreeSet<Node>,
    neighbors: BTreeSet<Node>,
    routes: BTreeMap<Node, Vec<Route>>,
    searches: BTreeMap<Node, Search>,
    seen: BTreeMap<(Node, u64), (usize, u64)>,
    forward: BTreeMap<(Node, u64), (Message, u64)>,
    next_request: u64,
    active: BTreeMap<Node, u64>,
    optimize_after: BTreeMap<Node, u64>,
    search_after: BTreeMap<Node, u64>,
    bootstrap_after: BTreeMap<Node, u64>,
}

impl Router {
    pub fn new(me: Node, scope: Scope, policy: [u8; 32]) -> Self {
        Self {
            me,
            scope,
            policy,
            allowed: BTreeSet::from([me]),
            transit: BTreeSet::new(),
            neighbors: BTreeSet::new(),
            routes: BTreeMap::new(),
            searches: BTreeMap::new(),
            seen: BTreeMap::new(),
            forward: BTreeMap::new(),
            next_request: 1,
            active: BTreeMap::new(),
            optimize_after: BTreeMap::new(),
            search_after: BTreeMap::new(),
            bootstrap_after: BTreeMap::new(),
        }
    }

    /// Replace the admitted nodes. Remove cached paths through revoked nodes immediately.
    #[cfg(test)]
    pub fn directory(&mut self, nodes: impl IntoIterator<Item = Node>) -> Result<(), &'static str> {
        self.directory_roles(nodes.into_iter().map(|node| (node, true)), true)
    }

    pub fn directory_roles(&mut self, nodes: impl IntoIterator<Item = (Node, bool)>, local_transit: bool) -> Result<(), &'static str> {
        let mut next = BTreeSet::from([self.me]);
        let mut transit = BTreeSet::new();
        for (node, forwards) in nodes {
            if forwards && node != self.me { transit.insert(node); }
            next.insert(node);
            if next.len() > MAX_NODES {
                return Err("too many mesh nodes");
            }
        }
        if local_transit { transit.insert(self.me); }
        if self.allowed == next && self.transit == transit { return Ok(()); }
        self.allowed = next;
        self.transit = transit;
        // A newly learned public neighbor must not discard the discovery that
        // caused its bootstrap. Retain only prefixes still admitted by policy.
        self.forward.retain(|_,(message,_)|matches!(message,Message::Discover {path,target,..}
            if self.allowed.contains(target) && path.iter().all(|n|self.allowed.contains(n))
                && path.iter().skip(1).all(|n|self.transit.contains(n))));
        self.bootstrap_after.retain(|n, _| self.allowed.contains(n));
        self.neighbors.retain(|n| self.allowed.contains(n));
        self.routes.retain(|_, routes| {
            routes.retain(|r| r.path.iter().all(|n| self.allowed.contains(n))
                && r.path.iter().skip(1).take(r.path.len().saturating_sub(2)).all(|n| self.transit.contains(n)));
            !routes.is_empty()
        });
        self.searches.retain(|n, _| self.allowed.contains(n));
        self.active.retain(|n, _| self.allowed.contains(n));
        self.optimize_after.retain(|n, _| self.allowed.contains(n));
        self.search_after.retain(|n, _| self.allowed.contains(n));
        self.seen.retain(|(n, _), _| self.allowed.contains(n));
        Ok(())
    }

    /// Withdraw one leaf/target pair without disturbing that leaf's other work.
    pub fn detach_path_endpoints(&mut self, leaf: Node, target: Node) {
        let pair=|first:Option<&Node>,last:Option<&Node>|
            (first==Some(&leaf) && last==Some(&target)) || (first==Some(&target) && last==Some(&leaf));
        self.routes.retain(|_,routes| {routes.retain(|r|!pair(r.path.first(),r.path.last()));!routes.is_empty()});
        self.forward.retain(|_,(message,_)|!matches!(message,Message::Discover {path,target,..} if pair(path.first(),Some(target))));
        if let Some(peer)=if self.me==leaf {Some(target)} else if self.me==target {Some(leaf)} else {None} {
            self.searches.remove(&peer);self.active.remove(&peer);self.optimize_after.remove(&peer);
            self.search_after.remove(&peer);self.bootstrap_after.remove(&peer);
        }
    }

    pub fn link_up(&mut self, node: Node) -> bool {
        node != self.me && self.allowed.contains(&node) && self.neighbors.insert(node)
    }

    pub fn link_down(&mut self, node: Node) {
        self.neighbors.remove(&node);
        self.routes.retain(|_, routes| {
            routes.retain(|r| r.path.get(1) != Some(&node));
            !routes.is_empty()
        });
        // A newly requested path must not wait for a search sent over the failed link.
        self.searches.clear();
    }

    pub fn needs_links(&self) -> bool {
        self.searches.values().any(|s| !s.satisfied) || !self.forward.is_empty()
    }

    /// Replay only pending discoveries when a new authenticated neighbor opens.
    /// This lets a bridge be found without preconnecting the whole directory.
    pub fn neighbor_ready(&mut self, node: Node, now: u64) -> Vec<Action> {
        self.expire(now);
        let mut actions = vec![];
        for (&target, s) in &self.searches {
            if s.satisfied { continue; }
            actions.push(self.send(
                node,
                Message::Discover {
                    request: s.request,
                    target,
                    path: vec![self.me],
                },
            ));
        }
        for (message, _) in self.forward.values() {
            if let Message::Discover { path, .. } = message {
                if !path.contains(&node) {
                    actions.push(self.send(node, message.clone()));
                }
            }
        }
        actions
    }

    pub(crate) fn route_preferences(&self) -> impl Iterator<Item = (Node, Vec<[u8; 32]>)> + '_ {
        self.allowed.iter().filter(|node| **node != self.me).map(|node| {
            (*node, self.routes(node).iter().map(|route| circuit(self.scope, self.policy, &route.path)).collect())
        })
    }

    pub fn routes(&self, target: &Node) -> &[Route] {
        self.routes.get(target).map(Vec::as_slice).unwrap_or(&[])
    }

    pub fn expire(&mut self, now: u64) {
        self.forward.retain(|_, (_, until)| *until > now);
        self.routes.retain(|_, routes| {
            routes.retain(|r| r.until > now);
            !routes.is_empty()
        });
        self.searches
            .retain(|_, s| now.saturating_sub(s.started) < SEARCH_MS);
        self.seen.retain(|_, (_, until)| *until > now);
        self.active.retain(|_, until| *until > now);
        self.bootstrap_after
            .retain(|n, _| self.active.contains_key(n));
        self.optimize_after
            .retain(|n, _| self.active.contains_key(n));
        self.search_after.retain(|n, _| self.active.contains_key(n));
    }

    fn send(&self, to: Node, message: Message) -> Action {
        Action::Send(
            to,
            Frame {
                scope: self.scope,
                message,
            },
        )
    }

    fn path_ok(&self, path: &[Node]) -> bool {
        !path.is_empty()
            && path.len() <= MAX_HOPS + 1
            && path.iter().all(|n| self.allowed.contains(n))
            && path.iter().skip(1).take(path.len().saturating_sub(2)).all(|n| self.transit.contains(n))
            && path.iter().collect::<BTreeSet<_>>().len() == path.len()
    }

    fn install(&mut self, path: Vec<Node>, rtt_ms: u64, now: u64) {
        let Some(target) = path.last().copied() else {
            return;
        };
        if path.len() < 2 || path[0] != self.me || !self.neighbors.contains(&path[1]) {
            return;
        }
        let routes = self.routes.entry(target).or_default();
        if let Some(r) = routes.iter_mut().find(|r| r.path == path) {
            r.until = now.saturating_add(IDLE_MS);
            if rtt_ms != u64::MAX {
                r.rtt_ms = rtt_ms;
                r.last_good = now;
            }
            return;
        }
        let r = Route {
            path,
            rtt_ms,
            until: now.saturating_add(IDLE_MS),
            last_good: now,
            probes: vec![],
            next_probe: now,
            baseline_ms: rtt_ms,
            slow_samples: 0,
            good_samples: 0,
            peer_seen: false,
        };
        // A discovery response only installs a candidate. Data-plane probes must
        // confirm a stable gain before a healthy incumbent is replaced.
        routes.push(r);
        routes.truncate(2);
    }

    pub fn discover(&mut self, target: Node, now: u64) -> Vec<Action> {
        self.expire(now);
        if target == self.me
            || !self.allowed.contains(&target)
            || self.searches.contains_key(&target)
            || self.searches.len() >= MAX_SEARCHES
        {
            return vec![];
        }
        let request = self.next_request;
        self.next_request = self.next_request.wrapping_add(1);
        self.searches.insert(
            target,
            Search {
                satisfied: false,
                request,
                started: now,
            },
        );
        self.neighbors
            .iter()
            .map(|n| {
                self.send(
                    *n,
                    Message::Discover {
                        request,
                        target,
                        path: vec![self.me],
                    },
                )
            })
            .collect()
    }

    /// Drop packets while a route is found. The inner QUIC connection retransmits them.
    pub fn packet(&mut self, target: Node, packet: Vec<u8>, now: u64) -> Vec<Action> {
        self.packet_on(target, packet, circuit(self.scope, self.policy, &[]), now)
    }

    pub fn packet_on(
        &mut self,
        target: Node,
        packet: Vec<u8>,
        requested: [u8; 32],
        now: u64,
    ) -> Vec<Action> {
        self.expire(now);
        if packet.is_empty()
            || packet.len() > MAX_PACKET
            || target == self.me
            || !self.allowed.contains(&target)
        {
            return vec![];
        }
        self.active.insert(target, now.saturating_add(IDLE_MS));
        let Some(routes) = self.routes.get_mut(&target).filter(|rs| !rs.is_empty()) else {
            return self.discover(target, now);
        };
        routes[0].until = now.saturating_add(IDLE_MS);
        let preferred = routes[0].path.clone();
        let preferred_seen = routes[0].peer_seen;
        let chosen = if requested == circuit(self.scope, self.policy, &[]) {
            Some(preferred.clone())
        } else {
            routes
                .iter()
                .find(|r| circuit(self.scope, self.policy, &r.path) == requested)
                .map(|r| r.path.clone())
        };
        let mut actions = vec![];
        // QUIC path validation must use the exact circuit in the address. Moving
        // its probes to another circuit would mix RTT and congestion state.
        if let Some(path) = chosen.clone() {
            actions.push(self.send(
                path[1],
                Message::Data {
                    path,
                    cursor: 1,
                    packet: packet.clone(),
                },
            ));
        }
        // Introduce a route at most once a second until a packet arrives on its
        // reverse circuit. Continuing after that would migrate the same QUIC
        // path between circuits, mixing its RTT and congestion state.
        if !preferred_seen && chosen.as_ref() != Some(&preferred)
            && now >= *self.bootstrap_after.get(&target).unwrap_or(&0)
        {
            self.bootstrap_after
                .insert(target, now.saturating_add(1000));
            actions.push(self.send(
                preferred[1],
                Message::Data {
                    path: preferred,
                    cursor: 1,
                    packet,
                },
            ));
        }
        actions
    }

    pub fn is_active(&self) -> bool {
        !self.active.is_empty()
    }

    /// Only active destinations get path probes. An idle router sends nothing.
    pub fn tick(&mut self, now: u64) -> Vec<Action> {
        self.expire(now);
        let mut actions = vec![];
        for target in self.active.keys().copied().collect::<Vec<_>>() {
            if let Some(routes) = self.routes.get_mut(&target) {
                routes.retain(|r| now.saturating_sub(r.last_good) < DEAD_MS);
                for r in routes.iter_mut() {
                    if now < r.next_probe {
                        continue;
                    }
                    r.probes.retain(|(_, at)| now.saturating_sub(*at) < DEAD_MS);
                    let request = self.next_request;
                    self.next_request = self.next_request.wrapping_add(1);
                    r.probes.push((request, now));
                    // Keep the original cadence when a tick is late. Scheduling
                    // from `now` accumulates a full tick of drift near a deadline.
                    // Skip missed periods; never send catch-up probes in a burst.
                    r.next_probe = now.saturating_add(PROBE_MS - (now - r.next_probe) % PROBE_MS);
                    actions.push(Action::Send(
                        r.path[1],
                        Frame {
                            scope: self.scope,
                            message: Message::Probe {
                                path: r.path.clone(),
                                cursor: 1,
                                request,
                                reply: false,
                            },
                        },
                    ));
                }
            }
            let routes = self.routes.get_mut(&target);
            if let Some(routes) = routes {
                if routes.len() == 2
                    && routes[0].slow_samples >= 3
                    && routes[1].good_samples >= 3
                    && routes[1].slow_samples == 0
                    && routes[1].rtt_ms.saturating_add(10) < routes[0].rtt_ms.saturating_mul(4) / 5
                    && now >= *self.optimize_after.get(&target).unwrap_or(&0)
                {
                    routes.swap(0, 1);
                    self.optimize_after
                        .insert(target, now.saturating_add(30_000));
                }
            }
            // Prepare a missing candidate on the first measured slow reply, while
            // the unchanged three-sample promotion gates continue accumulating.
            // Healthy demand adds no search; a short spike costs at most the
            // existing bounded search and never authorizes an early promotion.
            let needs_candidate = self.routes(&target).len() == 1
                && self.routes(&target)[0].slow_samples > 0;
            if needs_candidate && now >= *self.optimize_after.get(&target).unwrap_or(&0)
                && now >= *self.search_after.get(&target).unwrap_or(&0)
                && self.searches.get(&target).is_none_or(|search| search.satisfied) {
                // Searching is rate-limited independently: a candidate that
                // finishes validation during this interval may be promoted now.
                // A recent cold success must not suppress this new demand for
                // an alternative. Keep any search still in progress.
                if self.searches.get(&target).is_some_and(|search| search.satisfied) {
                    self.searches.remove(&target);
                }
                actions.extend(self.discover(target, now));
                if self.searches.contains_key(&target) {
                    self.search_after.insert(target, now.saturating_add(10_000));
                }
            }
            if self.routes(&target).is_empty() {
                actions.extend(self.discover(target, now));
            }
        }
        actions
    }

    /// `from` is the peer authenticated by the outer connection, not a packet field.
    pub fn receive(&mut self, from: Node, frame: Frame, now: u64) -> Vec<Action> {
        self.expire(now);
        if frame.scope != self.scope || !self.neighbors.contains(&from) {
            return vec![];
        }
        match frame.message {
            Message::Discover {
                request,
                target,
                mut path,
            } => {
                if !self.path_ok(&path)
                    || path.contains(&self.me)
                    || path.last() != Some(&from)
                    || path.len() > MAX_HOPS
                    || !self.allowed.contains(&target)
                    || (path.len() > 1 && !self.transit.contains(&from))
                    || (target != self.me && !self.transit.contains(&self.me))
                {
                    return vec![];
                }
                let key = (path[0], request);
                if target != self.me
                    && self
                        .seen
                        .get(&key)
                        .is_some_and(|(len, _)| *len <= path.len())
                {
                    return vec![];
                }
                if !self.seen.contains_key(&key) && self.seen.len() >= MAX_SEEN {
                    return vec![];
                }
                self.seen
                    .insert(key, (path.len(), now.saturating_add(SEARCH_MS)));
                path.push(self.me);
                if target == self.me {
                    // Discovery authenticates a usable reverse candidate, not its
                    // quality. Only existing local demand starts nonce probes.
                    self.install(path.iter().rev().copied().collect(), u64::MAX, now);
                    return vec![self.send(
                        from,
                        Message::Offer {
                            request,
                            cursor: (path.len() - 2) as u8,
                            path,
                        },
                    )];
                }
                if path.len() > MAX_HOPS {
                    return vec![];
                }
                if self.forward.len() < MAX_SEARCHES || self.forward.contains_key(&key) {
                    self.forward.insert(
                        key,
                        (
                            Message::Discover {
                                request,
                                target,
                                path: path.clone(),
                            },
                            now.saturating_add(SEARCH_MS),
                        ),
                    );
                }
                self.neighbors
                    .iter()
                    .filter(|n| !path.contains(n))
                    .map(|n| {
                        self.send(
                            *n,
                            Message::Discover {
                                request,
                                target,
                                path: path.clone(),
                            },
                        )
                    })
                    .collect()
            }
            Message::Offer {
                request,
                path,
                cursor,
            } => {
                let i = cursor as usize;
                if !self.path_ok(&path)
                    || path.get(i) != Some(&self.me)
                    || path.get(i + 1) != Some(&from)
                {
                    return vec![];
                }
                if i == 0 {
                    let target = *path.last().unwrap();
                    if let Some(s) = self.searches.get(&target) {
                        if s.request == request {
                            let new_candidate = !self.routes(&target).iter().any(|r| r.path == path);
                            let candidate = path.clone();
                            self.install(path, now.saturating_sub(s.started), now);
                            // A response for the existing route does not satisfy
                            // a search for an alternative. Only a newly installed
                            // route stops expansion, including the first cold one.
                            if new_candidate && self.routes(&target).iter().any(|r| r.path == candidate)
                                && let Some(search) = self.searches.get_mut(&target) {
                                search.satisfied = true;
                            }
                        }
                    }
                    vec![]
                } else {
                    if !self.neighbors.contains(&path[i - 1]) {
                        return vec![];
                    }
                    self.forward.remove(&(path[0], request));
                    vec![self.send(
                        path[i - 1],
                        Message::Offer {
                            request,
                            path,
                            cursor: cursor - 1,
                        },
                    )]
                }
            }
            Message::Data {
                path,
                cursor,
                packet,
            } => {
                let i = cursor as usize;
                if !self.path_ok(&path)
                    || i == 0
                    || path.get(i) != Some(&self.me)
                    || path.get(i - 1) != Some(&from)
                    || packet.is_empty()
                    || packet.len() > MAX_PACKET
                {
                    return vec![];
                }
                if i + 1 == path.len() {
                    let source = path[0];
                    // The inner QUIC handshake authenticates this claimed source identity.
                    let reverse: Vec<_> = path.iter().rev().copied().collect();
                    self.install(reverse.clone(), u64::MAX, now);
                    if let Some(route) = self.routes.get_mut(&source)
                        .and_then(|routes| routes.iter_mut().find(|route| route.path == reverse)) {
                        route.peer_seen = true;
                    }
                    return vec![Action::Deliver(source, packet, circuit(self.scope, self.policy, &path))];
                }
                let next = path[i + 1];
                if self.neighbors.contains(&next) {
                    vec![self.send(
                        next,
                        Message::Data {
                            path,
                            cursor: cursor + 1,
                            packet,
                        },
                    )]
                } else {
                    vec![self.send(
                        from,
                        Message::Broken {
                            path,
                            cursor: cursor - 1,
                        },
                    )]
                }
            }
            Message::Broken { path, cursor } => {
                let i = cursor as usize;
                if !self.path_ok(&path)
                    || path.get(i) != Some(&self.me)
                    || path.get(i + 1) != Some(&from)
                {
                    return vec![];
                }
                if i > 0 {
                    if !self.neighbors.contains(&path[i - 1]) {
                        return vec![];
                    }
                    return vec![self.send(
                        path[i - 1],
                        Message::Broken {
                            path,
                            cursor: cursor - 1,
                        },
                    )];
                }
                let target = *path.last().unwrap();
                if let Some(routes) = self.routes.get_mut(&target) {
                    routes.retain(|r| r.path != path);
                }
                self.searches.remove(&target);
                self.discover(target, now)
            }
            Message::Probe {
                path,
                cursor,
                request,
                reply,
            } => {
                let i = cursor as usize;
                if !self.path_ok(&path) || path.get(i) != Some(&self.me) {
                    return vec![];
                }
                if reply {
                    if path.get(i + 1) != Some(&from) {
                        return vec![];
                    }
                    if i == 0 {
                        let target = *path.last().unwrap();
                        if let Some(r) = self
                            .routes
                            .get_mut(&target)
                            .and_then(|rs| rs.iter_mut().find(|r| r.path == path))
                        {
                            if let Some(index) =
                                r.probes.iter().position(|(nonce, _)| *nonce == request)
                            {
                                let (_, at) = r.probes.remove(index);
                                {
                                    let sample = now.saturating_sub(at);
                                    r.rtt_ms = if r.rtt_ms == u64::MAX {
                                        sample
                                    } else {
                                        r.rtt_ms.saturating_mul(3).saturating_add(sample) / 4
                                    };
                                    r.last_good = now;
                                    r.baseline_ms = r.baseline_ms.min(sample);
                                    if sample > r.baseline_ms.saturating_mul(3).saturating_add(100)
                                    {
                                        r.slow_samples = r.slow_samples.saturating_add(1);
                                        r.good_samples = 0;
                                    } else {
                                        r.slow_samples = 0;
                                        r.good_samples = r.good_samples.saturating_add(1);
                                    }
                                }
                            }
                        }
                        return vec![];
                    }
                    if !self.neighbors.contains(&path[i - 1]) {
                        return vec![];
                    }
                    vec![self.send(
                        path[i - 1],
                        Message::Probe {
                            path,
                            cursor: cursor - 1,
                            request,
                            reply,
                        },
                    )]
                } else {
                    if i == 0 || path.get(i - 1) != Some(&from) {
                        return vec![];
                    }
                    if i + 1 == path.len() {
                        return vec![self.send(
                            from,
                            Message::Probe {
                                path,
                                cursor: cursor - 1,
                                request,
                                reply: true,
                            },
                        )];
                    }
                    if !self.neighbors.contains(&path[i + 1]) {
                        return vec![self.send(
                            from,
                            Message::Broken {
                                path,
                                cursor: cursor - 1,
                            },
                        )];
                    }
                    vec![self.send(
                        path[i + 1],
                        Message::Probe {
                            path,
                            cursor: cursor + 1,
                            request,
                            reply,
                        },
                    )]
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    fn n(i: u8) -> Node {
        [i; 32]
    }

    fn world(edges: &[(u8, u8)]) -> Vec<Router> {
        let mut nodes: Vec<_> = (0..5)
            .map(|i| {
                let mut r = Router::new(n(i), n(99), n(98));
                r.directory((0..5).map(n)).unwrap();
                r
            })
            .collect();
        for &(a, b) in edges {
            nodes[a as usize].link_up(n(b));
            nodes[b as usize].link_up(n(a));
        }
        nodes
    }
    fn run(
        nodes: &mut [Router],
        from: u8,
        actions: Vec<Action>,
        now: u64,
    ) -> Vec<(u8, Node, Vec<u8>)> {
        let mut queue: VecDeque<_> = actions.into_iter().map(|a| (from, a)).collect();
        let mut out = vec![];
        let mut count = 0;
        while let Some((from, action)) = queue.pop_front() {
            count += 1;
            assert!(count < 200, "discovery must stop on cyclic graphs");
            match action {
                Action::Send(to, frame) => {
                    let actions = nodes[to[0] as usize].receive(n(from), frame, now);
                    queue.extend(actions.into_iter().map(|a| (to[0], a)));
                }
                Action::Deliver(source, bytes, _) => out.push((from, source, bytes)),
            }
        }
        out
    }
    #[test]
    fn adding_a_neighbor_keeps_pending_discovery_but_revocation_removes_it() {
        let mut router=Router::new(n(1),n(99),n(98));
        router.directory([n(0),n(3)]).unwrap();router.link_up(n(0));
        let discovery=Frame {scope:n(99),message:Message::Discover {request:7,target:n(3),path:vec![n(0)]}};
        assert!(router.receive(n(0),discovery,10).is_empty());
        router.directory([n(0),n(2),n(3)]).unwrap();router.link_up(n(2));
        let replay=router.neighbor_ready(n(2),11);
        assert!(matches!(&replay[..],[Action::Send(to,Frame {message:Message::Discover {request:7,target,path},..})]
            if *to==n(2) && *target==n(3) && path==&vec![n(0),n(1)]));
        router.directory([n(2),n(3)]).unwrap();
        assert!(router.neighbor_ready(n(2),12).is_empty());
    }

    #[test]
    fn detaching_one_leaf_target_preserves_other_target_routes() {
        let mut w=world(&[(0,1),(1,2),(1,3)]);
        let first=w[0].discover(n(2),0);run(&mut w,0,first,1);
        let second=w[0].discover(n(3),2);run(&mut w,0,second,3);
        assert!(!w[0].routes(&n(2)).is_empty() && !w[0].routes(&n(3)).is_empty());
        w[0].detach_path_endpoints(n(0),n(2));
        assert!(w[0].routes(&n(2)).is_empty() && !w[0].searches.contains_key(&n(2)));
        assert!(!w[0].routes(&n(3)).is_empty());
        let pending=Frame {scope:n(99),message:Message::Discover {request:99,target:n(2),path:vec![n(0)]}};
        w[1].receive(n(0),pending,4);
        w[1].detach_path_endpoints(n(0),n(2));
        assert!(w[1].forward.values().all(|(m,_)|!matches!(m,Message::Discover {target,..} if *target==n(2))));
    }

    #[test]
    fn leaves_are_endpoints_and_cannot_be_used_as_transit() {
        let edges = [(0, 1), (1, 2), (2, 3)];
        let mut w = world(&edges);
        for (i, r) in w.iter_mut().enumerate() {
            r.directory_roles((0..5).map(|j| (n(j), j == 1 || j == 2)), i == 1 || i == 2).unwrap();
        }
        let actions = w[0].discover(n(3), 0);
        run(&mut w, 0, actions, 1);
        assert_eq!(w[0].routes(&n(3))[0].path, vec![n(0), n(1), n(2), n(3)]);
        let actions = w[0].packet(n(3), vec![42], 2);
        assert_eq!(run(&mut w, 0, actions, 3), vec![(3, n(0), vec![42])]);
        // Withdrawing transit keeps the node admitted as an endpoint, but removes
        // old circuits and refuses discoveries that would put it in the middle.
        for (i, r) in w.iter_mut().enumerate() {
            r.directory_roles((0..5).map(|j| (n(j), j == 2)), i == 2).unwrap();
        }
        assert!(w[0].routes(&n(3)).is_empty());
        let actions = w[0].discover(n(3), 4000);
        run(&mut w, 0, actions, 4001);
        assert!(w[0].routes(&n(3)).is_empty());
        let actions = w[0].discover(n(1), 4002);
        run(&mut w, 0, actions, 4003);
        assert_eq!(w[0].routes(&n(1))[0].path, vec![n(0), n(1)]);
        let forged = Frame { scope: n(99), message: Message::Data {
            path: vec![n(0), n(1), n(2), n(3)], cursor: 1, packet: vec![42],
        }};
        assert!(w[1].receive(n(0), forged, 4004).is_empty());
    }

    #[test]
    fn a_quic_path_probe_keeps_its_requested_circuit() {
        let mut w = world(&[(0, 3), (0, 1), (1, 2), (2, 3)]);
        let actions = w[0].discover(n(3), 0);
        run(&mut w, 0, actions, 1);
        let alternate = vec![n(0), n(1), n(2), n(3)];
        let actions = w[0].packet_on(n(3), vec![42], circuit(n(99), n(98), &alternate), 2);
        let paths: Vec<_> = actions
            .iter()
            .filter_map(|a| match a {
                Action::Send(
                    _,
                    Frame {
                        message: Message::Data { path, .. },
                        ..
                    },
                ) => Some(path.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(
            paths[0], alternate,
            "validation must travel on the addressed circuit"
        );
        assert_eq!(
            paths.len(),
            2,
            "one bootstrap copy introduces the preferred circuit"
        );
        assert_eq!(
            w[0].packet_on(n(3), vec![42], circuit(n(99), n(98), &alternate), 3).len(),
            1,
            "bootstrap copies are bounded"
        );
        let alternate_id = circuit(n(99), n(98), &alternate);
        assert_eq!(w[0].packet_on(n(3), vec![42], alternate_id, 1002).len(), 2,
            "unconfirmed introduction retries after the existing one second limit");
        assert!(w[0].routes(&n(3)).iter().all(|route| !route.peer_seen));
        for path in [vec![n(3), n(0)], vec![n(3), n(2), n(1), n(0)]] {
            let from = path[path.len() - 2];
            let cursor = (path.len() - 1) as u8;
            w[0].receive(from, Frame { scope: n(99), message: Message::Data {
                path, cursor, packet: vec![7],
            }}, 1003);
        }
        assert!(w[0].routes(&n(3)).iter().all(|route| route.peer_seen && route.good_samples == 0));
        assert_eq!(w[0].packet_on(n(3), vec![42], alternate_id, 2002).len(), 1,
            "confirmed preferred address must not receive copies of another circuit's probes");
        w[0].routes.get_mut(&n(3)).unwrap().swap(0, 1);
        let direct_id = circuit(n(99), n(98), &[n(0), n(3)]);
        assert_eq!(w[0].packet_on(n(3), vec![42], direct_id, 3002).len(), 1,
            "promoting an already seen candidate does not reintroduce it");
        w[0].routes.get_mut(&n(3)).unwrap().retain(|route| route.path != alternate);
        w[0].install(alternate.clone(), u64::MAX, 3003);
        w[0].routes.get_mut(&n(3)).unwrap().swap(0, 1);
        assert!(!w[0].routes(&n(3))[0].peer_seen, "a new route has no stale confirmation");
        assert_eq!(w[0].packet_on(n(3), vec![42], direct_id, 4002).len(), 2);
    }

    #[test]
    fn successful_discovery_stops_neighbor_expansion_on_the_chain() {
        let mut nodes = world(&[(0, 1), (1, 2), (2, 3)]);
        let actions = nodes[0].discover(n(3), 0);
        assert!(nodes[0].needs_links());
        run(&mut nodes, 0, actions, 1);
        for node in &nodes[..4] { assert!(!node.needs_links()); }
        assert!(nodes[0].neighbor_ready(n(4), 2).is_empty());
        assert!(nodes[1].neighbor_ready(n(4), 2).is_empty());
        assert_eq!(nodes[0].routes(&n(3))[0].path, vec![n(0), n(1), n(2), n(3)]);
        let actions = nodes[0].packet(n(3), vec![42; 1200], 3);
        assert_eq!(run(&mut nodes, 0, actions, 4), vec![(3, n(0), vec![42; 1200])]);
        let actions = nodes[3].packet(n(0), vec![7], 5);
        assert_eq!(run(&mut nodes, 3, actions, 6), vec![(0, n(3), vec![7])]);
    }

    #[test]
    fn circuit_identity_is_stable_bidirectional_and_scoped_to_policy() {
        for path in [vec![], vec![n(0), n(1), n(2), n(3)]] {
            let id = circuit(n(99), n(98), &path);
            assert_eq!(id, circuit(n(99), n(98), &path));
            assert_eq!(id, circuit(n(99), n(98), &path.iter().rev().copied().collect::<Vec<_>>()));
            assert_ne!(id, circuit(n(97), n(98), &path));
            assert_ne!(id, circuit(n(99), n(97), &path));
        }
        assert_ne!(circuit(n(99), n(98), &[]), circuit(n(99), n(98), &[n(0), n(3)]));
    }

    #[test]
    fn wire_lengths_are_rejected_before_path_allocation() {
        for message in [
            Message::Discover {
                request: 1,
                target: n(2),
                path: vec![n(1); MAX_HOPS + 2],
            },
            Message::Data {
                path: vec![n(1), n(2)],
                cursor: 1,
                packet: vec![0; MAX_PACKET + 1],
            },
        ] {
            let bytes = postcard::to_allocvec(&Frame {
                scope: n(99),
                message,
            })
            .unwrap();
            assert!(postcard::from_bytes::<Frame>(&bytes).is_err());
        }
    }

    #[test]
    fn revoked_transit_invalidates_routes() {
        let mut w = world(&[(0, 1), (1, 2), (2, 3)]);
        let actions = w[0].discover(n(3), 0);
        run(&mut w, 0, actions, 1);
        w[0].directory([n(1), n(3)]).unwrap();
        assert!(w[0].routes(&n(3)).is_empty());
    }
    #[test]
    fn scope_and_sender_are_checked() {
        let mut w = world(&[(0, 1)]);
        let message = Message::Discover {
            request: 1,
            target: n(1),
            path: vec![n(0)],
        };
        assert!(
            w[1].receive(
                n(0),
                Frame {
                    scope: n(98),
                    message: message.clone()
                },
                0
            )
            .is_empty()
        );
        assert!(
            w[1].receive(
                n(2),
                Frame {
                    scope: n(99),
                    message
                },
                0
            )
            .is_empty()
        );
    }
    #[test]
    fn cycles_and_duplicate_discovery_are_bounded() {
        let mut w = world(&[(0, 1), (1, 2), (2, 0), (2, 3)]);
        let actions = w[0].discover(n(3), 0);
        run(&mut w, 0, actions, 1);
        assert!(!w[0].routes(&n(3)).is_empty());
        assert!(w[0].discover(n(3), 2).is_empty());
        assert!(!w[0].discover(n(3), SEARCH_MS + 1).is_empty());
    }
    #[test]
    fn broken_link_finds_new_route() {
        let mut w = world(&[(0, 1), (1, 2), (2, 3)]);
        let actions = w[0].discover(n(3), 0);
        run(&mut w, 0, actions, 1);
        w[1].link_down(n(2));
        w[2].link_down(n(1));
        w[0].link_up(n(4));
        w[4].link_up(n(0));
        w[4].link_up(n(3));
        w[3].link_up(n(4));
        let actions = w[0].packet(n(3), vec![1], 2);
        run(&mut w, 0, actions, 3);
        assert_eq!(w[0].routes(&n(3))[0].path, vec![n(0), n(4), n(3)]);
    }
    #[test]
    fn idle_routes_expire_and_bad_paths_do_not_allocate() {
        let mut w = world(&[(0, 1), (1, 2), (2, 3)]);
        let actions = w[0].discover(n(3), 0);
        run(&mut w, 0, actions, 1);
        w[0].expire(IDLE_MS + 1);
        assert!(w[0].routes(&n(3)).is_empty());
        for path in [vec![n(1), n(1)], vec![n(4), n(2)], vec![n(4); 100]] {
            assert!(
                w[0].receive(
                    n(1),
                    Frame {
                        scope: n(99),
                        message: Message::Discover {
                            request: 99,
                            target: n(3),
                            path,
                        }
                    },
                    0
                )
                .is_empty()
            );
        }
    }
    #[test]
    fn sustained_slow_path_yields_to_verified_candidate() {
        let mut w = world(&[(0, 3), (0, 1), (1, 2), (2, 3)]);
        let actions = w[0].discover(n(3), 0);
        run(&mut w, 0, actions, 1);
        assert_eq!(w[3].routes(&n(0)).len(), 2);
        assert_eq!(w[3].routes(&n(0))[1].path, vec![n(3), n(2), n(1), n(0)]);
        assert!(w[3].routes(&n(0)).iter().all(|r| r.rtt_ms == u64::MAX && r.good_samples == 0));
        assert!(w[3].tick(2).is_empty(), "discover does not create demand or send probes");
        for (source, target) in [(0, 3), (3, 0)] {
            let actions = w[source].packet(n(target), vec![1], 3);
            run(&mut w, source as u8, actions, 4);
        }
        for step in 1..=9 {
            let now = step * 1000;
            let mut scheduled = Vec::new();
            for source in [0, 3] {
                for action in w[source].tick(now) {
                    let delay = match &action {
                        Action::Send(_, Frame { message: Message::Probe { path, .. }, .. })
                            if path.len() == 2 && (step == 4 || step >= 6) => 400,
                        _ => 20,
                    };
                    scheduled.push((delay, source, action));
                }
            }
            scheduled.sort_by_key(|(delay, _, _)| *delay);
            for (delay, source, action) in scheduled {
                run(&mut w, source as u8, vec![action], now + delay);
            }
            for (source, target) in [(0, 3), (3, 0)] {
                if step == 1 {
                    let candidate = w[source].routes(&n(target))[1].clone();
                    assert_eq!(candidate.good_samples, 1, "one real probe gives one sample");
                    // Replaying the consumed nonce (and an unknown one) cannot
                    // turn discovery into three samples of stable quality.
                    for request in [w[source].next_request - 1, u64::MAX] {
                        w[source].receive(candidate.path[1], Frame { scope: n(99), message: Message::Probe {
                            path: candidate.path.clone(), cursor: 0, request, reply: true,
                        }}, now + 500);
                    }
                    assert_eq!(w[source].routes(&n(target))[1].good_samples, 1);
                }
                if step <= 8 {
                    assert_eq!(w[source].routes(&n(target))[0].path.len(), 2,
                        "a tick before three sustained slow replies must not switch");
                }
            }
        }
        assert_eq!(w[0].routes(&n(3))[0].path, vec![n(0), n(1), n(2), n(3)]);
        assert_eq!(w[3].routes(&n(0))[0].path, vec![n(3), n(2), n(1), n(0)]);
    }

    #[test]
    fn candidate_validation_does_not_wait_for_discovery_backoff() {
        for sustained in [false, true] {
            // Direct is ready first; the source's chain neighbor opens later.
            let mut nodes = world(&[(0, 3), (1, 2), (2, 3)]);
            let actions = nodes[0].discover(n(3), 0);
            run(&mut nodes, 0, actions, 1);
            assert!(!nodes[0].needs_links(), "cold first success stops expansion");
            let actions = nodes[0].packet(n(3), vec![1], 2);
            run(&mut nodes, 0, actions, 3);
            let actions = nodes[0].tick(100);
            assert!(actions.iter().all(|a| matches!(a, Action::Send(_, Frame {message:Message::Probe {..},..}))),
                "healthy active demand sends no exploratory discovery");
            run(&mut nodes, 0, actions, 110);
            let actions = nodes[0].tick(1_100);
            run(&mut nodes, 0, actions, 1_500);
            assert_eq!(nodes[0].routes(&n(3))[0].slow_samples, 1);
            assert!(nodes[0].searches[&n(3)].satisfied,
                "cold search nonce is still retained when the first slow reply arrives");
            let actions = nodes[0].tick(1_600);
            assert!(actions.iter().any(|a| matches!(a, Action::Send(_, Frame {message:Message::Discover {..},..}))));
            run(&mut nodes, 0, actions, 2_000);
            assert!(nodes[0].needs_links(), "old direct offer must not cancel alternative search");
            assert_eq!(nodes[0].search_after[&n(3)], 11_600);
            nodes[0].link_up(n(1)); nodes[1].link_up(n(0));
            let actions = nodes[0].neighbor_ready(n(1), 2_100);
            run(&mut nodes, 0, actions, 2_140);
            assert_eq!(nodes[0].routes(&n(3)).len(), 2);
            assert_eq!(nodes[0].routes(&n(3))[1].good_samples, 0);
            assert!(!nodes[0].needs_links(), "new candidate completes bounded search");
            for now in [2_250, 3_250, 4_250] {
                let mut scheduled: Vec<_> = nodes[0].tick(now).into_iter().map(|action| {
                    let delay = match &action {
                        Action::Send(_, Frame {message:Message::Probe {path,..},..}) if path.len()==2 && sustained => 400,
                        _ => 20,
                    };
                    (delay,action)
                }).collect();
                scheduled.sort_by_key(|(delay,_)|*delay);
                for (delay,action) in scheduled { run(&mut nodes,0,vec![action],now+delay); }
                assert_eq!(nodes[0].routes(&n(3))[0].path.len(),2,
                    "no promotion before the third candidate reply reaches a tick");
            }
            nodes[0].tick(4_750);
            assert_eq!(nodes[0].routes(&n(3))[0].path.len(), if sustained {4} else {2},
                "persistent degradation promotes before search cooldown; a short spike never promotes");
        }
    }

    #[test]
    fn one_latency_spike_does_not_promote_a_warm_candidate() {
        let mut w = world(&[(0, 3), (0, 1), (1, 2), (2, 3)]);
        let actions = w[0].discover(n(3), 0);
        run(&mut w, 0, actions, 1);
        let actions = w[0].packet(n(3), vec![1], 2);
        run(&mut w, 0, actions, 3);
        for step in 1..=10 {
            let now = step * 1000;
            let actions = w[0].tick(now);
            for action in actions {
                let delay = match &action {
                    Action::Send(
                        _,
                        Frame {
                            message: Message::Probe { path, .. },
                            ..
                        },
                    ) if path.len() == 2 => {
                        if step == 5 {
                            400
                        } else {
                            10
                        }
                    }
                    _ => 20,
                };
                run(&mut w, 0, vec![action], now + delay);
            }
            assert_eq!(w[0].routes(&n(3))[0].path, vec![n(0), n(3)]);
        }
    }

    #[test]
    fn delayed_probe_and_one_lost_probe_do_not_expire_a_live_route() {
        let mut w = world(&[(0, 1)]);
        let actions = w[0].discover(n(1), 0);
        run(&mut w, 0, actions, 1);
        let actions = w[0].packet(n(1), vec![1], 2);
        run(&mut w, 0, actions, 3);
        let delayed = w[0].tick(100);
        let _lost = w[0].tick(1100);
        run(&mut w, 0, delayed, 1600);
        assert_eq!(w[0].routes(&n(1))[0].last_good, 1600);
        let actions = w[0].tick(2100);
        run(&mut w, 0, actions, 2120);
        assert_eq!(w[0].routes(&n(1))[0].last_good, 2120);
    }

    #[test]
    fn late_ticks_keep_probe_cadence_without_catch_up_bursts() {
        let mut w = world(&[(0, 1)]);
        let actions = w[0].discover(n(1), 0);
        run(&mut w, 0, actions, 1);
        let actions = w[0].packet(n(1), vec![1], 2);
        run(&mut w, 0, actions, 3);
        // The route starts at 1 ms. A 250 ms heartbeat may run just before
        // its deadline, then just after it, without moving later deadlines.
        for (now, count) in [
            (251, 1), (1_000, 0), (1_251, 1), (2_000, 0), (2_250, 1),
            (3_000, 0), (3_250, 1), (4_000, 0), (4_250, 1),
            // Several missed intervals produce one probe, not a catch-up burst.
            (8_250, 1), (8_251, 0), (9_000, 0), (9_250, 1),
        ] {
            let actions = w[0].tick(now);
            assert_eq!(actions.len(), count, "probe count at {now} ms");
            assert!(actions.iter().all(|action| matches!(action,
                Action::Send(_, Frame {message: Message::Probe {reply: false, ..}, ..}))));
            run(&mut w, 0, actions, now + 1);
        }
    }

    #[test]
    fn idle_router_sends_no_probes_and_silent_active_path_expires() {
        let mut w = world(&[(0, 1), (1, 2), (2, 3)]);
        assert!(w[0].tick(100).is_empty());
        let actions = w[0].discover(n(3), 100);
        run(&mut w, 0, actions, 101);
        assert!(w[0].tick(102).is_empty());
        let actions = w[0].packet(n(3), vec![1], 103);
        run(&mut w, 0, actions, 104);
        let actions = w[0].tick(105);
        assert!(!actions.is_empty());
        run(&mut w, 0, actions, 106);
        assert_eq!(w[0].routes(&n(3))[0].last_good, 106);
        assert!(w[0].tick(107).is_empty());
        let _ = w[0].tick(106 + DEAD_MS);
        assert!(w[0].routes(&n(3)).is_empty());
    }
}

fn read_path<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<Node>, D::Error> {
    bounded_vec::<Node, D, 9>(d)
}
fn read_packet<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
    bounded_vec::<u8, D, MAX_PACKET>(d)
}
fn bounded_vec<'de, T: Deserialize<'de>, D: serde::Deserializer<'de>, const MAX: usize>(
    d: D,
) -> Result<Vec<T>, D::Error> {
    struct Bounded<T, const MAX: usize>(std::marker::PhantomData<T>);
    impl<'de, T: Deserialize<'de>, const MAX: usize> serde::de::Visitor<'de> for Bounded<T, MAX> {
        type Value = Vec<T>;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            write!(f, "at most {MAX} entries")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut seq: A,
        ) -> Result<Self::Value, A::Error> {
            use serde::de::Error;
            if seq.size_hint().is_some_and(|n| n > MAX) {
                return Err(A::Error::custom("mesh field too large"));
            }
            let mut out = Vec::with_capacity(seq.size_hint().unwrap_or(0).min(MAX));
            while let Some(value) = seq.next_element()? {
                if out.len() == MAX {
                    return Err(A::Error::custom("mesh field too large"));
                }
                out.push(value);
            }
            Ok(out)
        }
    }
    d.deserialize_seq(Bounded::<T, MAX>(std::marker::PhantomData))
}
