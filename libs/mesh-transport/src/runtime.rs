//! One actor owns routes. Link tasks carry control frames and bounded datagrams.
use crate::{
    fragments::{self, MAX_FRAME, Reassembly},
    identity::Binding,
    path_control::Control,
    path_admission::Admission,
    routing::{Action, Frame, Message, Node, Route, Router, Scope},
    transport::{Packet, QUEUE, Transport},
};
use bytes::Bytes;
use iroh::{Endpoint, EndpointAddr, endpoint::Connection};
use std::{
    collections::BTreeMap,
    sync::Arc,
    time::Duration,
};
use tokio::{
    sync::{mpsc, oneshot},
};

use n0_future::{task::{JoinHandle, JoinSet}, time::{Instant, timeout}};

pub const ALPN: &[u8] = b"mesh/neighbor/1";
const MAX_LINKS: usize = 32;
const LINK_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Debug)]
pub struct Peer {
    pub node: Node,
    pub binding: Option<Binding>,
    pub transit: bool,
    pub address: EndpointAddr,
}

impl Peer {
    /// The caller first checks scope membership and revocation. This checks the
    /// cryptographic binding, then ties the dial address to that neighbor key.
    pub fn from_binding(
        binding: &crate::identity::Binding,
        address: EndpointAddr,
        scope: Scope,
        minimum_generation: u64,
    ) -> Result<Self, &'static str> {
        binding.verify(scope, minimum_generation)?;
        if address.id.as_bytes() != &binding.neighbor {
            return Err("mesh address identity does not match its binding");
        }
        Ok(Self {
            node: binding.endpoint,
            binding: Some(binding.clone()),
            transit: binding.transit,
            address,
        })
    }
}

enum Event {
    Connect(Node, oneshot::Sender<Result<(), String>>),
    Ready(
        Node,
        u64,
        bool,
        Connection,
        mpsc::Sender<Control>,
    ),
    Received(Node, u64, Control),
    Gone(Node, u64),
    DialFinished(Node, u64),
    Routes(Node, oneshot::Sender<Vec<Route>>),
    Links(oneshot::Sender<Vec<Node>>),
    TrustedTransit(BTreeMap<Node,u64>,oneshot::Sender<Result<(),String>>),
    Disconnect(Node, oneshot::Sender<()>),
    Directory(Vec<Peer>, Binding, oneshot::Sender<Result<(), String>>),
    AttachLeaf(crate::leaf::Attachment, Option<Peer>, oneshot::Sender<Result<(),String>>),
    DetachLeaf([u8;32], oneshot::Sender<()>),
    Stop,
}

struct Link {
    generation: u64,
    preferred: bool,
    connection: Connection,
    send: mpsc::Sender<Control>,
}

pub struct Runtime {
    pub transport: Arc<Transport>,
    events: mpsc::Sender<Event>,
    task: Option<JoinHandle<()>>,
    activity:tokio::sync::watch::Receiver<Option<Instant>>,
}

impl Runtime {
    /// Signed neighbors support public transit without sharing a workspace roster.
    /// Public mode admits only direct neighbors plus identities on active paths.
    pub fn start_proven(endpoint: Endpoint, own: Binding, peers: Vec<Peer>, public: bool) -> Result<Self, String> {
        own.verify(own.scope, 1).map_err(str::to_owned)?;
        if endpoint.id().as_bytes() != &own.neighbor { return Err("local neighbor binding mismatch".into()); }
        let mode = ProofMode::new(own.clone(), public, &peers)?;
        Self::start_inner(endpoint, own.endpoint, own.scope, peers, own.transit, mode)
    }
    fn start_inner(endpoint: Endpoint, me: Node, scope: Scope, peers: Vec<Peer>, transit: bool, proof_mode: ProofMode) -> Result<Self, String> {
        let (directory, lower) = directory_maps(peers)?;
        let mut router = Router::new(me, scope, proof_mode.own.policy);
        router
            .directory_roles(directory.values().map(|p| (p.node, p.transit)), transit)
            .map_err(str::to_owned)?;
        let (transport, outgoing, incoming) = Transport::new(me, scope, proof_mode.own.policy);
        let (events, receive) = mpsc::channel(QUEUE);
        let (activity_tx,activity)=tokio::sync::watch::channel(None);
        let task = n0_future::task::spawn(actor(
            transport.clone(),
            endpoint,
            router,
            directory,
            lower,
            events.clone(),
            receive,
            outgoing,
            incoming,
            proof_mode,
            activity_tx,
        ));
        Ok(Self {
            transport,
            events,
            task: Some(task),
            activity,
        })
    }
    /// Validated path traffic activates and renews bounded public backbone leases.
    /// Bootstrap subscriptions alone do not keep those leases alive.
    pub fn activity(&self)->tokio::sync::watch::Receiver<Option<Instant>> {self.activity.clone()}
    pub async fn directory_proven(&self, peers: Vec<Peer>, own: Binding) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.events
            .send(Event::Directory(peers, own, tx))
            .await
            .map_err(|_| "mesh stopped")?;
        rx.await.map_err(|_| "mesh stopped".to_owned())?
    }
    pub async fn connect(&self, peer: Node) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.events
            .send(Event::Connect(peer, tx))
            .await
            .map_err(|_| "mesh stopped")?;
        rx.await.map_err(|_| "mesh stopped".to_string())?
    }
    pub async fn disconnect(&self, peer: Node) {
        let (tx, rx) = oneshot::channel();
        if self.events.send(Event::Disconnect(peer, tx)).await.is_ok() {
            let _ = rx.await;
        }
    }
    pub async fn routes(&self, peer: Node) -> Vec<Route> {
        let (tx, rx) = oneshot::channel();
        if self.events.send(Event::Routes(peer, tx)).await.is_err() {
            return vec![];
        }
        rx.await.unwrap_or_default()
    }
    pub async fn linked_nodes(&self) -> Vec<Node> {
        let (tx, rx) = oneshot::channel();
        if self.events.send(Event::Links(tx)).await.is_err() { return vec![]; }
        rx.await.unwrap_or_default()
    }
    /// Operator-approved public roots may occur in a path without being direct
    /// neighbors. Their per-scope bindings arrive only with that path's proof.
    pub async fn trusted_transit(&self,nodes:BTreeMap<Node,u64>)->Result<(),String> {
        let (tx,rx)=oneshot::channel();
        self.events.send(Event::TrustedTransit(nodes,tx)).await.map_err(|_|"mesh stopped")?;
        rx.await.map_err(|_|"mesh stopped".to_string())?
    }
    pub async fn attach_leaf(&self, attachment: crate::leaf::Attachment, neighbor: Option<Peer>) -> Result<(),String> {
        let (tx,rx)=oneshot::channel();
        self.events.send(Event::AttachLeaf(attachment,neighbor,tx)).await.map_err(|_|"mesh stopped")?;
        rx.await.map_err(|_|"mesh stopped".to_string())?
    }
    pub async fn detach_leaf(&self, id: [u8;32]) {
        let (tx,rx)=oneshot::channel();
        if self.events.send(Event::DetachLeaf(id,tx)).await.is_ok() {let _=rx.await;}
    }
    pub async fn close(mut self) {
        let _ = self.events.send(Event::Stop).await;
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

async fn actor(
    transport: Arc<Transport>,
    endpoint: Endpoint,
    mut router: Router,
    mut directory: BTreeMap<Node, Peer>,
    mut lower: BTreeMap<iroh::EndpointId, Node>,
    events: mpsc::Sender<Event>,
    mut receive: mpsc::Receiver<Event>,
    mut outgoing: mpsc::Receiver<Packet>,
    incoming: mpsc::Sender<Packet>,
    mut proof_mode: ProofMode,
    activity:tokio::sync::watch::Sender<Option<Instant>>,
) {
    let mut workers = JoinSet::new();
    let mut links: BTreeMap<Node, Link> = BTreeMap::new();
    let mut leaf_peers = BTreeMap::<Node,Peer>::new();
    let leaf_live: Arc<std::sync::RwLock<std::collections::BTreeSet<[u8;32]>>> = Arc::default();
    let mut generation = 0;
    let trace_routing = std::env::var_os("MESH_TRACE_ROUTING").is_some();
    let mut traced_preferences = Vec::new();
    let start = Instant::now();
    let mut dialing = BTreeMap::new();
    let mut waiting: BTreeMap<Node,Vec<oneshot::Sender<Result<(),String>>>> = BTreeMap::new();
    let mut retry_after = BTreeMap::new();
    let mut automatic_attempts = 0;
    let mut last_attempt = None;
    let mut attempt_window = 0;
    let mut heartbeat = n0_future::time::interval(Duration::from_millis(250));
    heartbeat.set_missed_tick_behavior(n0_future::time::MissedTickBehavior::Skip);
    loop {
        let actions = tokio::select! {
            _ = heartbeat.tick(), if router.is_active() || router.needs_links() || proof_mode.public.is_some() || proof_mode.leaves.all().next().is_some() => {
                let now = start.elapsed().as_millis() as u64;
                if let Some(public) = proof_mode.public.as_mut() {
                    if public.expire(now) { let _ = router.directory_roles(public.roles(),true); }
                }
                let attachments:Vec<_>=proof_mode.leaves.all().map(|a|(a.id,a.leaf.endpoint,a.target)).collect();
                if proof_mode.leaves.expire(now,unix_ms()) {
                    for (id,leaf,target) in attachments {if proof_mode.leaves.get(&id).is_none() {router.detach_path_endpoints(leaf,target);}}
                    let _ = router.directory_roles(proof_mode.roles(&directory),proof_mode.own.transit);
                }
                router.tick(now)
            },
            accepted = endpoint.accept(), if workers.len() < MAX_LINKS => {
                let Some(accepted) = accepted else { break };
                generation += 1;
                let gen_id = generation;
                let tx = events.clone(); let lower = lower.clone(); let leaf_live=leaf_live.clone();
                workers.spawn(async move {
                    if let Ok(Ok(conn)) = timeout(LINK_TIMEOUT, accepted).await {
                        let Some(peer) = lower.get(&conn.remote_id()).copied() else {
                            conn.close(1u32.into(), b"unknown mesh peer"); return;
                        };
                        link(conn, peer, gen_id, false, tx, leaf_live).await;
                    }
                });
                vec![]
            }
            Some(_) = workers.join_next(), if !workers.is_empty() => { vec![] }
            packet = outgoing.recv() => {
                let Some(packet) = packet else { break };
                let actions=router.packet_on(packet.peer, packet.bytes, packet.circuit, start.elapsed().as_millis() as u64);
                actions
            }
            event = receive.recv() => {
                let Some(event) = event else { break };
                match event {
                    Event::Stop => break,
                    Event::AttachLeaf(attachment,neighbor,answer) => {
                        let result=(|| {
                            proof_mode.check_attachment(&attachment,&directory,unix_ms()).map_err(str::to_owned)?;
                            if attachment.issuer.endpoint != proof_mode.own.endpoint && attachment.leaf.endpoint != proof_mode.own.endpoint {return Err("local attachment is neither leaf nor ingress".into());}
                            if let Some(peer)=&neighbor {
                                if attachment.issuer.endpoint != proof_mode.own.endpoint || peer.node != attachment.leaf.endpoint
                                    || peer.address.id.as_bytes()!=&attachment.leaf.neighbor || peer.transit {return Err("invalid leaf neighbor".into());}
                                if directory.contains_key(&peer.node) && !leaf_peers.contains_key(&peer.node) {return Err("leaf conflicts with directory".into());}
                                if directory.len() >= crate::routing::MAX_NODES && !directory.contains_key(&peer.node) {return Err("leaf neighbor capacity".into());}
                            } else if attachment.issuer.endpoint==proof_mode.own.endpoint {return Err("ingress requires its leaf neighbor".into());}
                            let replaces=proof_mode.leaves.all().any(|a|a.leaf.endpoint==attachment.leaf.endpoint && a.target==attachment.target && a.id!=attachment.id);
                            let endpoints=(attachment.leaf.endpoint,attachment.target);
                            proof_mode.leaves.insert(attachment,start.elapsed().as_millis() as u64,true).map_err(str::to_owned)?;
                            if replaces {router.detach_path_endpoints(endpoints.0,endpoints.1);}
                            if let Some(peer)=neighbor {lower.insert(peer.address.id,peer.node);directory.insert(peer.node,peer.clone());leaf_peers.insert(peer.node,peer);}
                            router.directory_roles(proof_mode.roles(&directory),proof_mode.own.transit).map_err(str::to_owned)?;
                            *leaf_live.write().unwrap()=proof_mode.leaves.all().map(|a|a.id).collect();
                            Ok(())
                        })();
                        let _=answer.send(result);vec![]
                    }
                    Event::DetachLeaf(id,answer) => {
                        if let Some(a)=proof_mode.leaves.remove(&id) {
                            router.detach_path_endpoints(a.leaf.endpoint,a.target);
                            if !proof_mode.leaves.all().any(|other|other.leaf.endpoint==a.leaf.endpoint) {
                                if let Some(peer)=leaf_peers.remove(&a.leaf.endpoint) {
                                    directory.remove(&peer.node);lower.remove(&peer.address.id);dialing.remove(&peer.node);
                                    if let Some(link)=links.remove(&peer.node) {link.connection.close(1u32.into(),b"leaf detached");}
                                    for waiter in waiting.remove(&peer.node).unwrap_or_default() {let _=waiter.send(Err("leaf detached".into()));}
                                }
                                router.link_down(a.leaf.endpoint);
                            }
                            let _=router.directory_roles(proof_mode.roles(&directory),proof_mode.own.transit);
                        }
                        *leaf_live.write().unwrap()=proof_mode.leaves.all().map(|a|a.id).collect();
                        let _=answer.send(());vec![]
                    }
                    Event::Links(answer) => { let _ = answer.send(links.keys().copied().collect()); vec![] }
                    Event::TrustedTransit(nodes,answer)=>{
                        let result=(|| {
                            if nodes.len()>32 || nodes.values().any(|g|*g==0||*g>9_007_199_254_740_991) {return Err("invalid public transit policy".into());}
                            let mode=&mut proof_mode;
                            if mode.public.is_some() || nodes.contains_key(&mode.own.endpoint) {return Err("invalid private transit policy".into());}
                            let mut roles=mode.roles(&directory);
                            roles.extend(nodes.keys().map(|n|(*n,true)));
                            router.directory_roles(roles,mode.own.transit).map_err(str::to_owned)?;
                            mode.transit_proofs.retain(|n,b|nodes.get(n)==Some(&b.generation));
                            mode.trusted=nodes;
                            Ok(())
                        })();
                        let _=answer.send(result);vec![]
                    }
                    Event::DialFinished(peer, gen_id) => {
                        if dialing.get(&peer) == Some(&gen_id) {
                            dialing.remove(&peer);
                            for answer in waiting.remove(&peer).unwrap_or_default() { let _ = answer.send(Err("mesh neighbor dial failed".into())); }
                        }
                        vec![]
                    }
                    Event::Directory(peers, own, answer) => {
                        let result = (|| {
                            if own.endpoint != proof_mode.own.endpoint || own.scope != proof_mode.own.scope || own.neighbor != proof_mode.own.neighbor || own.generation < proof_mode.own.generation {
                                return Err("local binding changed identity or moved backward".into());
                            }
                            let mode = proof_mode.updated(own,&peers)?;
                            let (mut next,mut keys) = directory_maps(peers)?;
                            for peer in leaf_peers.values() {if mode.leaves.all().any(|a|a.leaf.endpoint==peer.node) {next.insert(peer.node,peer.clone());keys.insert(peer.address.id,peer.node);}}
                            let roles=mode.roles(&next);
                            router.directory_roles(roles, mode.own.transit).map_err(str::to_owned)?;
                            links.retain(|peer,link| {
                                let keep = next.get(peer).is_some_and(|p| p.address.id==link.connection.remote_id());
                                if !keep {
                                    router.link_down(*peer);
                                    link.connection.close(1u32.into(),b"mesh peer revoked");
                                }
                                keep
                            });
                            directory = next; lower = keys;
                            for a in proof_mode.leaves.all() {if mode.leaves.get(&a.id).is_none() {router.detach_path_endpoints(a.leaf.endpoint,a.target);}}
                            proof_mode = mode;
                            transport.retain_peers(directory.keys().copied());
                            Ok(())
                        })();
                        let _ = answer.send(result);
                        vec![]
                    }
                    Event::Connect(peer, answer) => {
                        retry_after.remove(&peer);
                        if links.contains_key(&peer) { let _ = answer.send(Ok(())); }
                        else if dialing.contains_key(&peer) {
                            let pending = waiting.entry(peer).or_default();
                            if pending.len() < MAX_LINKS { pending.push(answer); }
                            else { let _ = answer.send(Err("mesh connect waiter limit".into())); }
                        }
                        else if workers.len() >= MAX_LINKS { let _ = answer.send(Err("mesh link limit".into())); }
                        else if let Some(p) = directory.get(&peer) {
                            let endpoint = endpoint.clone(); let addr = p.address.clone(); let tx = events.clone(); let leaf_live=leaf_live.clone();
                            generation += 1; let gen_id = generation;
                            dialing.insert(peer,gen_id);
                            waiting.entry(peer).or_default().push(answer);
                            workers.spawn(async move {
                                if let Ok(Ok(conn)) = timeout(LINK_TIMEOUT, endpoint.connect(addr, ALPN)).await {
                                    link(conn, peer, gen_id, true, tx.clone(), leaf_live).await;
                                }
                                let _ = tx.send(Event::DialFinished(peer,gen_id)).await;
                            });
                        } else { let _ = answer.send(Err("unknown mesh peer".into())); }
                        vec![]
                    }
                    Event::Ready(peer, gen_id, dialed, conn, send) => {
                        if retry_after.get(&peer) == Some(&u64::MAX)
                            || !directory.get(&peer).is_some_and(|p| p.address.id==conn.remote_id()) {
                            conn.close(1u32.into(),b"mesh peer revoked");
                            if dialing.get(&peer) == Some(&gen_id) {
                                dialing.remove(&peer);
                                for answer in waiting.remove(&peer).unwrap_or_default() { let _ = answer.send(Err("mesh peer revoked".into())); }
                            }
                            continue;
                        }
                        dialing.remove(&peer);
                        // Both ends prefer the connection initiated by the smaller outer key.
                        let preferred = dialed == (endpoint.id() < conn.remote_id());
                        if links.get(&peer).is_some_and(|old| old.preferred || !preferred) {
                            conn.close(0u32.into(), b"duplicate link");
                        } else {
                            router.link_up(peer);
                            if let Some(old) = links.insert(peer, Link { generation: gen_id, preferred, connection: conn, send }) {
                                old.connection.close(0u32.into(), b"duplicate link");
                            }
                        }
                        for answer in waiting.remove(&peer).unwrap_or_default() { let _ = answer.send(Ok(())); }
                        router.neighbor_ready(peer,start.elapsed().as_millis() as u64)
                    }
                    Event::Disconnect(peer, answer) => {
                        retry_after.insert(peer,u64::MAX);
                        dialing.remove(&peer);
                        for answer in waiting.remove(&peer).unwrap_or_default() { let _ = answer.send(Err("mesh neighbor disconnected".into())); }
                        if let Some(link) = links.remove(&peer) { link.connection.close(0u32.into(), b"link removed"); }
                        router.link_down(peer);
                        let _ = answer.send(());
                        vec![]
                    }
                    Event::Gone(peer, gen_id) => {
                        if links.get(&peer).is_some_and(|l| l.generation == gen_id) {
                            links.remove(&peer); router.link_down(peer);
                        }
                        vec![]
                    }
                    Event::Received(peer, gen_id, control) => {
                        if links.get(&peer).is_some_and(|l| l.generation == gen_id) {
                            let now = start.elapsed().as_millis() as u64;
                            let Ok(frame) = proof_mode.receive(peer, control, &directory, now) else { continue; };
                            let _ = router.directory_roles(proof_mode.roles(&directory),proof_mode.own.transit);
                            let discovery=matches!(frame.message,Message::Discover {..});
                            // Temporary causal trace: only endpoint control replies, never data packets.
                            let trace_target = if trace_routing { match &frame.message {
                                Message::Probe { path, cursor: 0, reply: true, .. }
                                | Message::Offer { path, cursor: 0, .. } => path.last().copied(),
                                _ => None,
                            }} else { None };
                            if let Some(target) = trace_target {
                                eprintln!("MESH_DIAG recv now={now} frame={:?} before={:?}", frame.message, router.routes(&target));
                            }
                            let actions=router.receive(peer, frame, now);
                            if let Some(target) = trace_target {
                                eprintln!("MESH_DIAG after now={now} target={target:?} routes={:?}", router.routes(&target));
                            }
                            if discovery || !actions.is_empty() {
                                let stamp=Instant::now();
                                activity.send_if_modified(|last| {
                                    if last.is_none_or(|last|stamp.duration_since(last)>=Duration::from_millis(250)) {*last=Some(stamp);true}else{false}
                                });
                            }
                            actions
                        } else { vec![] }
                    }
                    Event::Routes(peer, answer) => {
                        let _ = answer.send(router.routes(&peer).to_vec()); vec![]
                    }
                }
            }
        };
        let gone: Vec<_> = leaf_peers.keys().filter(|node| !proof_mode.leaves.all().any(|a| a.leaf.endpoint==**node)).copied().collect();
        for node in gone {
            if let Some(peer)=leaf_peers.remove(&node) {directory.remove(&node);lower.remove(&peer.address.id);}
            if let Some(link)=links.remove(&node) {link.connection.close(1u32.into(),b"leaf expired");}
            dialing.remove(&node);router.link_down(node);
            for waiter in waiting.remove(&node).unwrap_or_default() {let _=waiter.send(Err("leaf expired".into()));}
        }
        *leaf_live.write().unwrap()=proof_mode.leaves.all().map(|a|a.id).collect();
        let _=router.directory_roles(proof_mode.roles(&directory),proof_mode.own.transit);
        // Offers, broken links and probe results can change a route while inner
        // QUIC has no outgoing packet (e.g. it is waiting for its PTO).
        if trace_routing {
            let preferences: Vec<_> = router.route_preferences().collect();
            if preferences != traced_preferences {
                eprintln!("MESH_DIAG preferences now={} routes={preferences:?}", start.elapsed().as_millis());
                traced_preferences = preferences;
            }
        }
        transport.update_routes(router.route_preferences());
        for action in actions {
            match action {
                Action::Send(to, frame) => {
                    if trace_routing && match &frame.message {
                        Message::Discover { path, .. } => path.len() == 1,
                        Message::Probe { path, reply: false, .. } => path.first() == Some(&proof_mode.own.endpoint),
                        _ => false,
                    } {
                        eprintln!("MESH_DIAG send now={} to={to:?} frame={:?}", start.elapsed().as_millis(), frame.message);
                    }
                    if let Some(link) = links.get(&to) {
                        // Saturation drops packets rather than blocking every neighbor.
                        let Ok(control) = proof_mode.outgoing(frame,to,&directory) else { continue; };
                        let _ = link.send.try_send(control);
                    }
                }
                Action::Deliver(peer, bytes, circuit) => {
                    let _ = incoming.try_send(Packet {
                        peer,
                        bytes,
                        circuit,
                    });
                }
            }
        }
        let now = start.elapsed().as_millis() as u64;
        if now >= attempt_window {
            automatic_attempts = 0;
            attempt_window = now.saturating_add(10_000);
        }
        if router.needs_links() {
            let mut candidates: Vec<_> = directory.keys().copied().collect();
            if let Some(last) = last_attempt {
                let offset = candidates.partition_point(|peer| *peer <= last);
                candidates.rotate_left(offset);
            }
            for peer in candidates {
                let p = &directory[&peer];
                if dialing.len() >= 4 || workers.len() >= MAX_LINKS || automatic_attempts >= 16 {
                    break;
                }
                if p.address.id == endpoint.id()
                    || links.contains_key(&peer)
                    || dialing.contains_key(&peer)
                    || now < *retry_after.get(&peer).unwrap_or(&0)
                {
                    continue;
                }
                retry_after.insert(peer, now.saturating_add(10_000));
                automatic_attempts += 1;
                last_attempt = Some(peer);
                let endpoint = endpoint.clone();
                let addr = p.address.clone();
                let tx = events.clone(); let leaf_live=leaf_live.clone();
                generation += 1;
                let gen_id = generation;
                dialing.insert(peer,gen_id);
                workers.spawn(async move {
                    if let Ok(Ok(conn)) = timeout(LINK_TIMEOUT, endpoint.connect(addr, ALPN)).await
                    {
                        link(conn, peer, gen_id, true, tx.clone(), leaf_live).await;
                    }
                    let _ = tx.send(Event::DialFinished(peer,gen_id)).await;
                });
            }
        }
    }
    for link in links.values() {
        link.connection.close(0u32.into(), b"mesh stopped");
    }
    workers.abort_all();
    while workers.join_next().await.is_some() {}
    endpoint.close().await;
}

async fn link(
    conn: Connection,
    peer: Node,
    generation: u64,
    dialed: bool,
    events: mpsc::Sender<Event>,
    leaf_live: Arc<std::sync::RwLock<std::collections::BTreeSet<[u8;32]>>>,
) {
    let opened = timeout(LINK_TIMEOUT, async {
        let (mut send, mut recv) = if dialed {
            conn.open_bi().await
        } else {
            conn.accept_bi().await
        }
        .map_err(|e| e.to_string())?;
        send.write_all(b"M3").await.map_err(|e| e.to_string())?;
        let mut header = [0; 2];
        recv.read_exact(&mut header)
            .await
            .map_err(|e| e.to_string())?;
        if header != *b"M3" {
            return Err("invalid neighbor version".into());
        }
        Ok::<_, String>((send, recv))
    })
    .await;
    let (mut send, mut recv) = match opened {
        Ok(Ok(pair)) => pair,
        _ => {
            conn.close(1u32.into(), b"mesh handshake failed");
            return;
        }
    };
    let (tx, mut rx) = mpsc::channel::<Control>(QUEUE);
    if events
        .send(Event::Ready(
            peer,
            generation,
            dialed,
            conn.clone(),
            tx,
        ))
        .await
        .is_err()
    {
        return;
    }
    let mut workers = JoinSet::new();
    let writer_conn = conn.clone();
    workers.spawn(async move {
        let mut id = 0u64;
        while let Some(control) = rx.recv().await {
            if control.leaf.is_some_and(|id|!leaf_live.read().unwrap().contains(&id)) {continue;}
            if matches!(control.frame.message, Message::Data { .. } | Message::Probe { .. }) {
                let bytes = postcard::to_allocvec(&control).map_err(|e|e.to_string())?;
                if bytes.len() > MAX_FRAME { continue; }
                id = id.wrapping_add(1);
                for part in fragments::split(id, &bytes) {
                    writer_conn
                        .send_datagram(Bytes::from(part))
                        .map_err(|e| e.to_string())?;
                }
            } else {
                let bytes = control.encode().map_err(str::to_owned)?;
                send.write_all(&(bytes.len() as u32).to_be_bytes())
                    .await
                    .map_err(|e| e.to_string())?;
                send.write_all(&bytes).await.map_err(|e| e.to_string())?;
            }
        }
        Ok::<_, String>(())
    });
    let tx = events.clone();
    workers.spawn(async move {
        loop {
            let mut len = [0; 4];
            recv.read_exact(&mut len).await.map_err(|e| e.to_string())?;
            let len = u32::from_be_bytes(len) as usize;
            if len == 0 || len > crate::path_control::MAX_CONTROL {
                return Err("invalid mesh control length".into());
            }
            let mut bytes = vec![0; len];
            recv.read_exact(&mut bytes)
                .await
                .map_err(|e| e.to_string())?;
            let control = Control::decode(&bytes).map_err(str::to_owned)?;
            if matches!(control.frame.message, Message::Data { .. } | Message::Probe { .. }) {
                return Err("data on control stream".into());
            }
            tx.send(Event::Received(peer, generation, control))
                .await
                .map_err(|_| "mesh stopped".to_string())?;
        }
    });
    let tx = events.clone();
    let reader_conn = conn.clone();
    workers.spawn(async move {
        let mut fragments = Reassembly::default();
        let start = Instant::now();
        loop {
            let bytes = reader_conn
                .read_datagram()
                .await
                .map_err(|e| e.to_string())?;
            if let Some(bytes) = fragments.receive(peer, &bytes, start.elapsed().as_millis() as u64)
            {
                let control: Control = postcard::from_bytes(&bytes).map_err(|e| e.to_string())?;
                if !matches!(control.frame.message, Message::Data { .. } | Message::Probe { .. }) {
                    return Err("control in datagram".into());
                }
                tx.send(Event::Received(peer, generation, control))
                    .await
                    .map_err(|_| "mesh stopped".to_string())?;
            }
        }
    });
    let _ = workers.join_next().await;
    workers.abort_all();
    while workers.join_next().await.is_some() {}
    conn.close(0u32.into(), b"mesh neighbor closed");
    let _ = events.send(Event::Gone(peer, generation)).await;
}

fn directory_maps(
    peers: Vec<Peer>,
) -> Result<(BTreeMap<Node, Peer>, BTreeMap<iroh::EndpointId, Node>), String> {
    if peers.len() > crate::routing::MAX_NODES {
        return Err("too many peers".into());
    }
    let mut lower = BTreeMap::new();
    let mut directory = BTreeMap::new();
    for peer in peers {
        if lower.insert(peer.address.id, peer.node).is_some()
            || directory.insert(peer.node, peer).is_some()
        {
            return Err("duplicate peer identity".into());
        }
    }
    Ok((directory, lower))
}

struct ProofMode {
    own: Binding,
    public: Option<Admission>,
    trusted:BTreeMap<Node,u64>,
    transit_proofs:BTreeMap<Node,Binding>,
    leaves: crate::leaf::Active,
}

#[cfg(test)]
mod policy_tests {
    use super::*;
    #[test]
    fn detached_leaf_proof_cannot_reopen_ingress_after_reattach() {
        let scope=[121;32]; let policy=crate::policy::TransitPolicy::empty().digest();
        let key=iroh::SecretKey::from([122;32]);
        let issuer=Binding::sign(&key,scope,policy,1,true);
        let leaf=Binding::sign(&iroh::SecretKey::from([123;32]),scope,policy,1,false);
        let target=Binding::sign(&iroh::SecretKey::from([124;32]),scope,policy,1,true);
        let peer=Peer::from_binding(&target,EndpointAddr::new(iroh::EndpointId::from_bytes(&target.neighbor).unwrap()),scope,1).unwrap();
        let directory=BTreeMap::from([(peer.node,peer.clone())]);
        let mut mode=ProofMode::new(issuer.clone(),false,&[peer]).unwrap();
        let attachment=crate::leaf::Attachment::sign(&key,issuer.clone(),leaf.clone(),target.endpoint,[1;32],9_007_199_254_740_991).unwrap();
        let mut control=Control { leaf:Some(attachment.id),attachment:Some(attachment.clone()),
            frame:Frame {scope,message:Message::Offer { request:1,path:vec![leaf.endpoint,issuer.endpoint,target.endpoint],cursor:1 }},
            proofs:vec![leaf.clone(),issuer.clone(),target.clone()] };
        mode.leaves.insert(attachment.clone(),0,true).unwrap();
        assert!(mode.receive(target.endpoint,control.clone(),&directory,1).is_ok());
        mode.leaves.remove(&attachment.id);
        assert_eq!(mode.receive(target.endpoint,control.clone(),&directory,2).unwrap_err(),"leaf attachment is not live locally");
        let replacement=crate::leaf::Attachment::sign(&key,issuer,leaf,target.endpoint,[2;32],attachment.expires_unix_ms).unwrap();
        mode.leaves.insert(replacement.clone(),3,true).unwrap();
        assert_eq!(mode.receive(target.endpoint,control.clone(),&directory,4).unwrap_err(),"leaf attachment is not live locally");
        control.leaf=Some(replacement.id);control.attachment=Some(replacement);
        assert!(mode.receive(target.endpoint,control,&directory,5).is_ok());
    }
    #[test]
    fn private_paths_accept_only_registered_public_generations_without_full_descriptors() {
        let scope=[112;32];
        let proofs:Vec<_>=(113..117).map(|n|Binding::sign(&iroh::SecretKey::from([n;32]),scope,crate::policy::TransitPolicy::empty().digest(),2,true)).collect();
        let peers:Vec<_>=[1,3].into_iter().map(|i|Peer::from_binding(&proofs[i],EndpointAddr::new(iroh::EndpointId::from_bytes(&proofs[i].neighbor).unwrap()),scope,2).unwrap()).collect();
        let directory:BTreeMap<_,_>=peers.iter().map(|p|(p.node,p.clone())).collect();
        let mut mode=ProofMode::new(proofs[0].clone(),false,&peers).unwrap();
        let control=Control {leaf:None,attachment:None,frame:Frame {scope,message:Message::Offer {request:1,path:proofs.iter().map(|p|p.endpoint).collect(),cursor:0}},proofs:proofs.clone()};
        assert!(mode.receive(proofs[1].endpoint,control.clone(),&directory,0).is_err());
        mode.trusted.insert(proofs[2].endpoint,3);
        assert!(mode.receive(proofs[1].endpoint,control.clone(),&directory,0).is_err());
        assert!(mode.transit_proofs.is_empty());
        mode.trusted.insert(proofs[2].endpoint,2);
        let mut invalid=control.clone();invalid.proofs[2].signature=proofs[1].signature;
        assert!(mode.receive(proofs[1].endpoint,invalid,&directory,0).is_err());
        assert!(mode.transit_proofs.is_empty());
        mode.receive(proofs[1].endpoint,control.clone(),&directory,0).unwrap();
        assert_eq!(mode.transit_proofs.len(),1);
        assert!(mode.transit_proofs.contains_key(&proofs[2].endpoint));
        mode.trusted.clear();mode.transit_proofs.clear();
        assert!(mode.receive(proofs[1].endpoint,control,&directory,0).is_err());
    }
}
impl ProofMode {
    fn new(own: Binding, public: bool, peers: &[Peer]) -> Result<Self,String> {
        own.verify(own.scope,1).map_err(str::to_owned)?;
        let proofs = Self::peer_proofs(&own,peers)?;
        let public = if public {
            let mut admission = Admission::new(own.clone()).map_err(str::to_owned)?;
            admission.neighbors(proofs).map_err(str::to_owned)?;
            Some(admission)
        } else { None };
        Ok(Self { own,public,trusted:BTreeMap::new(),transit_proofs:BTreeMap::new(), leaves:crate::leaf::Active::default() })
    }
    fn peer_proofs(own: &Binding, peers: &[Peer]) -> Result<Vec<Binding>,String> {
        peers.iter().map(|peer| {
            let proof = peer.binding.as_ref().ok_or("missing signed neighbor binding")?;
            proof.verify(own.scope,1).map_err(str::to_owned)?;
            if proof.policy != own.policy || proof.endpoint != peer.node || proof.neighbor != *peer.address.id.as_bytes() || proof.transit != peer.transit {
                return Err("signed neighbor directory mismatch".into());
            }
            Ok(proof.clone())
        }).collect()
    }
    fn updated(&self, own: Binding, peers: &[Peer]) -> Result<Self,String> {
        if let Some(old) = &self.public {
            if own.generation != self.own.generation || own.transit != self.own.transit { return Err("restart public scope to change local identity".into()); }
            let proofs = Self::peer_proofs(&own,peers)?;
            let mut public = old.clone();
            public.neighbors(proofs).map_err(str::to_owned)?;
            Ok(Self { own,public:Some(public),trusted:BTreeMap::new(),transit_proofs:BTreeMap::new(), leaves:self.leaves.clone() })
        } else {
            let mut next=Self::new(own,false,peers)?;
            next.trusted=self.trusted.clone();next.transit_proofs=self.transit_proofs.clone();next.leaves=self.leaves.clone();
            next.leaves.retain(|a| a.policy==next.own.policy
                && (a.target==next.own.endpoint || peers.iter().any(|p|p.node==a.target))
                && (if a.issuer.endpoint==next.own.endpoint { a.issuer.generation==next.own.generation && a.issuer.neighbor==next.own.neighbor && next.own.transit }
                    else { peers.iter().any(|p|p.binding.as_ref().is_some_and(|b| b.endpoint==a.issuer.endpoint && b.generation==a.issuer.generation && b.neighbor==a.issuer.neighbor && b.transit)) }));Ok(next)
        }
    }
    fn roles(&self, directory: &BTreeMap<Node,Peer>) -> BTreeMap<Node,bool> {
        let mut roles = self.public.as_ref().map(|p|p.roles()).unwrap_or_else(||directory.values().map(|p|(p.node,p.transit)).collect());
        roles.extend(self.trusted.keys().map(|n|(*n,true)));
        roles.extend(self.leaves.all().map(|a|(a.leaf.endpoint,false)));
        roles
    }
    fn check_attachment(&self, a: &crate::leaf::Attachment, directory: &BTreeMap<Node,Peer>, unix: u64) -> Result<(), &'static str> {
        a.verify_signature()?; a.live(unix)?;
        if a.scope != self.own.scope || a.policy != self.own.policy { return Err("leaf has another policy lane"); }
        if self.public.is_none() {
            let issuer = if a.issuer.endpoint == self.own.endpoint {&self.own} else {
                directory.get(&a.issuer.endpoint).and_then(|p|p.binding.as_ref()).ok_or("leaf issuer is not an admitted station")?
            };
            a.issued_by(issuer,self.own.scope,self.own.policy,unix)?;
            if a.target != self.own.endpoint && !directory.contains_key(&a.target) { return Err("leaf target is not admitted"); }
        }
        Ok(())
    }
    fn outgoing(&self, frame: Frame, to: Node, directory: &BTreeMap<Node,Peer>) -> Result<Control,&'static str> {
        let data = matches!(frame.message,Message::Data {..}|Message::Probe {..});
        let path = frame_path(&frame);
        let attachment = self.leaves.all().find(|a| (path.first()==Some(&a.leaf.endpoint) && path.last()==Some(&a.target)) || (path.last()==Some(&a.leaf.endpoint) && path.first()==Some(&a.target))).cloned();
        if let Some(a) = &attachment { a.live(unix_ms())?; a.path(&path,to,matches!(frame.message,Message::Discover {..}))?; }
        let leaf = attachment.as_ref().map(|a|a.id);
        if data { return Ok(Control {frame,proofs:vec![],leaf,attachment:None}); }
        let mut control = if let Some(public) = &self.public { public.outgoing(frame,to)? } else {
            Control::build(frame,to,|node| {
                if *node == self.own.endpoint { Some(self.own.clone()) }
                else { directory.get(node).and_then(|p|p.binding.clone()).or_else(||self.transit_proofs.get(node).cloned())
                    .or_else(||self.leaves.all().find(|a|a.leaf.endpoint==*node).map(|a|a.leaf.clone())) }
            })?
        };
        control.leaf=leaf; control.attachment=attachment;
        Ok(control)
    }
    fn receive(&mut self, from: Node, control: Control, directory: &BTreeMap<Node,Peer>, now: u64) -> Result<Frame,&'static str> {
        let data = matches!(control.frame.message,Message::Data {..}|Message::Probe {..});
        let path = frame_path(&control.frame);
        let given = control.attachment.clone();
        if data && (given.is_some() || !control.proofs.is_empty()) { return Err("data cannot allocate leaf admission"); }
        if let Some(a)=&given {
            if control.leaf != Some(a.id) { return Err("leaf attachment marker mismatch"); }
            self.check_attachment(a,directory,unix_ms())?;
            // Only the authenticated application connection may create a local
            // attachment. Replayed remote proofs cannot re-open its ingress.
            if (a.issuer.endpoint==self.own.endpoint || a.leaf.endpoint==self.own.endpoint)
                && !self.leaves.local(&a.id) { return Err("leaf attachment is not live locally"); }
            if let Some(old)=self.leaves.get(&a.id) { if !old.same(a) { return Err("leaf attachment id reused"); } }
        }
        if let Some(id)=control.leaf {
            let a = given.as_ref().or_else(||self.leaves.get(&id)).ok_or("unknown leaf attachment")?;
            if a.id != id { return Err("leaf marker mismatch"); }
            a.live(unix_ms())?;
            a.path(&path,self.own.endpoint,matches!(control.frame.message,Message::Discover {..}))?;
        } else if given.is_some() || self.leaves.all().any(|a|path.contains(&a.leaf.endpoint)) { return Err("leaf path lacks attachment marker"); }
        let leaf_marker=control.leaf;
        let frame = if let Some(public) = &mut self.public {
            if data {
                if !public.data(from,&control.frame,now) {return Err("unadmitted public data path");}
                control.frame
            } else { public.control(from,control,now)? }
        } else if data { control.frame } else {
            if control.frame.scope != self.own.scope { return Err("wrong private control scope"); }
            let sender = directory.get(&from).ok_or("unknown private control sender")?;
            let (path,previous) = control.identities(self.own.endpoint)?;
            if path.get(previous) != Some(&from) { return Err("wrong private control sender"); }
            let mut generations = BTreeMap::new();
            for proof in &control.proofs {
                if proof.policy != self.own.policy { return Err("path has another policy lane"); }
                if let Some(generation)=self.trusted.get(&proof.endpoint) {
                    if proof.generation!=*generation || !proof.transit {return Err("public path identity differs from registration");}
                    generations.insert(proof.endpoint,*generation); continue;
                }
                let known = if proof.endpoint == self.own.endpoint { &self.own }
                    else if let Some(known)=directory.get(&proof.endpoint).and_then(|p|p.binding.as_ref()) {known}
                    else {given.as_ref().filter(|a|a.leaf.endpoint==proof.endpoint).map(|a|&a.leaf)
                        .or_else(||self.leaves.all().find(|a|a.leaf.endpoint==proof.endpoint).map(|a|&a.leaf)).ok_or("path outside private directory")?};
                if proof.neighbor != known.neighbor || proof.transit != known.transit { return Err("path identity conflicts with private directory"); }
                generations.insert(proof.endpoint,known.generation);
            }
            control.verify(self.own.endpoint,*sender.address.id.as_bytes(),&generations)?;
            for proof in &control.proofs {if self.trusted.contains_key(&proof.endpoint) {self.transit_proofs.insert(proof.endpoint,proof.clone());}}
            control.frame
        };
        if let Some(a)=given { let local=self.leaves.local(&a.id); self.leaves.insert(a,now,local)?; }
        if let Some(id)=leaf_marker {self.leaves.touch(&id,now);}
        Ok(frame)
    }
}
fn unix_ms() -> u64 {
    n0_future::time::SystemTime::now().duration_since(n0_future::time::SystemTime::UNIX_EPOCH).unwrap_or_default().as_millis().min(u64::MAX as u128) as u64
}
fn frame_path(frame: &Frame) -> Vec<Node> {
    match &frame.message {
        Message::Discover {path,target,..} => path.iter().copied().chain([*target]).collect(),
        Message::Data {path,..}|Message::Probe {path,..}|Message::Offer {path,..}|Message::Broken {path,..} => path.clone(),
    }
}
