//! Adapt bounded packet queues to iroh's custom transport interface.
use crate::routing::{MAX_PACKET, Node, Scope};
use iroh::endpoint::transports::{
    CustomEndpoint, CustomSender, CustomTransport, RecvInfo, Transmit,
};
use iroh_base::CustomAddr;
use std::{
    collections::BTreeMap,
    io,
    sync::{Arc, Mutex},
    task::{Context, Poll},
};
use tokio::sync::mpsc;

/// Private transport identifier. Its address contains the scope and endpoint key.
pub const TRANSPORT_ID: u64 = 0x73666d65736801;
pub const QUEUE: usize = 256;

#[derive(Debug)]
pub struct Packet {
    pub peer: Node,
    pub bytes: Vec<u8>,
    pub circuit: [u8; 32],
}

#[derive(Debug)]
pub struct Transport {
    preferred: Mutex<BTreeMap<Node, Vec<[u8; 32]>>>,
    scope: Scope,
    policy: [u8; 32],
    me: Node,
    local: n0_watcher::Watchable<Vec<CustomAddr>>,
    outgoing: mpsc::Sender<Packet>,
    incoming: Mutex<Option<mpsc::Receiver<Packet>>>,
}

impl Transport {
    pub fn new(
        me: Node,
        scope: Scope,
        policy: [u8; 32],
    ) -> (Arc<Self>, mpsc::Receiver<Packet>, mpsc::Sender<Packet>) {
        let (outgoing, out) = mpsc::channel(QUEUE);
        let (input, incoming) = mpsc::channel(QUEUE);
        let local = n0_watcher::Watchable::new(vec![address(scope, policy, me)]);
        (
            Arc::new(Self {
                preferred: Mutex::new(BTreeMap::new()),
                scope,
                policy,
                me,
                local,
                outgoing,
                incoming: Mutex::new(Some(incoming)),
            }),
            out,
            input,
        )
    }
    pub(crate) fn retain_peers(&self, peers: impl Iterator<Item = Node>) {
        let peers: std::collections::BTreeSet<_> = peers.collect();
        self.preferred
            .lock()
            .unwrap()
            .retain(|p, _| peers.contains(p));
    }
    /// Publish routing changes even while inner QUIC waits for a retransmission.
    /// An admitted peer with no route has no selectable old circuit.
    pub(crate) fn update_routes(&self, routes: impl Iterator<Item = (Node, Vec<[u8; 32]>)>) {
        let mut preferred = self.preferred.lock().unwrap();
        preferred.clear();
        preferred.extend(routes.take(crate::routing::MAX_NODES).map(|(peer, mut circuits)| {
            circuits.truncate(2);
            (peer, circuits)
        }));
    }
    pub(crate) fn selectable(&self, addr: &CustomAddr) -> bool {
        if addr.id() != TRANSPORT_ID || addr.data().len() != 96 || addr.data()[..32] != self.scope { return false; }
        let peer: Node = addr.data()[32..64].try_into().unwrap();
        match self.preferred.lock().unwrap().get(&peer).and_then(|circuits| circuits.first()) {
            Some(circuit) => circuit.as_slice() == &addr.data()[64..],
            None => addr.data()[64..] == crate::routing::circuit(self.scope, self.policy, &[]),
        }
    }
    /// A validated bootstrap path is usable for retirement only while routing
    /// can currently carry it; its old QUIC RTT alone is not enough.
    pub(crate) fn routed(&self, addr: &CustomAddr) -> bool {
        if addr.id() != TRANSPORT_ID || addr.data().len() != 96 || addr.data()[..32] != self.scope { return false; }
        let peer: Node = addr.data()[32..64].try_into().unwrap();
        let circuit: [u8; 32] = addr.data()[64..].try_into().unwrap();
        self.preferred.lock().unwrap().get(&peer).is_some_and(|circuits|
            !circuits.is_empty() && (circuit == crate::routing::circuit(self.scope,self.policy,&[]) || circuits.contains(&circuit)))
    }
    /// A backup remains valid when preference changes. Only route removal withdraws it.
    pub(crate) fn withdrawn(&self, addr: &CustomAddr) -> bool {
        if addr.id() != TRANSPORT_ID || addr.data().len() != 96 || addr.data()[..32] != self.scope { return false; }
        let circuit: [u8; 32] = addr.data()[64..].try_into().unwrap();
        if circuit == crate::routing::circuit(self.scope, self.policy, &[]) { return false; }
        let peer: Node = addr.data()[32..64].try_into().unwrap();
        !self.preferred.lock().unwrap().get(&peer).is_some_and(|circuits| circuits.contains(&circuit))
    }
    pub fn address(&self, peer: Node) -> CustomAddr {
        address(self.scope, self.policy, peer)
    }
}

pub fn address(scope: Scope, policy: [u8; 32], peer: Node) -> CustomAddr {
    circuit_address(scope, peer, crate::routing::circuit(scope, policy, &[]))
}

fn circuit_address(scope: Scope, peer: Node, circuit: [u8; 32]) -> CustomAddr {
    let mut data = [0; 96];
    data[..32].copy_from_slice(&scope);
    data[32..64].copy_from_slice(&peer);
    data[64..].copy_from_slice(&circuit);
    CustomAddr::from_parts(TRANSPORT_ID, &data)
}

#[derive(Debug)]
struct Sender {
    scope: Scope,
    tx: mpsc::Sender<Packet>,
}

impl CustomSender for Sender {
    fn is_valid_send_addr(&self, addr: &CustomAddr) -> bool {
        addr.id() == TRANSPORT_ID && addr.data().len() == 96 && addr.data()[..32] == self.scope
    }
    fn poll_send(
        &self,
        _cx: &mut Context<'_>,
        dst: &CustomAddr,
        _src: Option<&CustomAddr>,
        transmit: &Transmit<'_>,
    ) -> Poll<io::Result<()>> {
        if !self.is_valid_send_addr(dst) {
            return Poll::Ready(Err(io::Error::other("invalid mesh address")));
        }
        let peer = dst.data()[32..64]
            .try_into()
            .expect("checked address length");
        let size = transmit.segment_size.unwrap_or(transmit.contents.len());
        if size == 0 || size > MAX_PACKET {
            return Poll::Ready(Err(io::Error::other("invalid mesh packet size")));
        }
        for bytes in transmit.contents.chunks(size) {
            // A full queue drops a datagram. The inner QUIC connection retransmits it.
            if let Err(mpsc::error::TrySendError::Closed(_)) = self.tx.try_send(Packet {
                peer,
                bytes: bytes.to_vec(),
                circuit: dst.data()[64..].try_into().unwrap(),
            }) {
                return Poll::Ready(Err(io::Error::other("mesh transport closed")));
            }
        }
        Poll::Ready(Ok(()))
    }
}

#[derive(Debug)]
struct Bound {
    scope: Scope,
    me: Node,
    local: n0_watcher::Watchable<Vec<CustomAddr>>,
    sender: Arc<Sender>,
    rx: mpsc::Receiver<Packet>,
}

impl CustomTransport for Transport {
    fn bind(&self) -> io::Result<Box<dyn CustomEndpoint>> {
        let rx = self
            .incoming
            .lock()
            .unwrap()
            .take()
            .ok_or_else(|| io::Error::other("mesh transport already bound"))?;
        Ok(Box::new(Bound {
            scope: self.scope,
            me: self.me,
            local: self.local.clone(),
            sender: Arc::new(Sender {
                scope: self.scope,
                tx: self.outgoing.clone(),
            }),
            rx,
        }))
    }
}

impl CustomEndpoint for Bound {
    fn watch_local_addrs(&self) -> n0_watcher::Direct<Vec<CustomAddr>> {
        self.local.watch()
    }
    fn create_sender(&self) -> Arc<dyn CustomSender> {
        self.sender.clone()
    }
    fn poll_recv(
        &mut self,
        cx: &mut Context<'_>,
        bufs: &mut [io::IoSliceMut<'_>],
        metas: &mut [noq_udp::RecvMeta],
        infos: &mut [RecvInfo],
    ) -> Poll<io::Result<usize>> {
        let mut filled = 0;
        for i in 0..bufs.len().min(metas.len()).min(infos.len()) {
            match self.rx.poll_recv(cx) {
                Poll::Pending => break,
                Poll::Ready(None) if filled == 0 => {
                    return Poll::Ready(Err(io::Error::other("mesh transport closed")));
                }
                Poll::Ready(None) => break,
                Poll::Ready(packet) => {
                    let packet = packet.unwrap();
                    if packet.bytes.len() > bufs[i].len() {
                        // Keep the receiver scheduled after a discarded packet.
                        cx.waker().wake_by_ref();
                        break;
                    }
                    bufs[i][..packet.bytes.len()].copy_from_slice(&packet.bytes);
                    metas[i].len = packet.bytes.len();
                    metas[i].stride = packet.bytes.len();
                    infos[i] = RecvInfo::new(
                        circuit_address(self.scope, packet.peer, packet.circuit),
                        Some(circuit_address(self.scope, self.me, packet.circuit)),
                    );
                    filled += 1;
                }
            }
        }
        if filled == 0 {
            Poll::Pending
        } else {
            Poll::Ready(Ok(filled))
        }
    }
}


#[cfg(test)]
mod route_publication_tests {
    use super::*;

    #[test]
    fn broken_route_is_not_selectable_without_an_outgoing_packet() {
        let (transport, _, _) = Transport::new([1; 32], [99; 32], [98; 32]);
        let peer = [2; 32];
        let old = [3; 32];
        let new = [4; 32];
        transport.update_routes([(peer, vec![old])].into_iter());
        assert!(transport.selectable(&circuit_address([99; 32], peer, old)));
        transport.update_routes([(peer, vec![new, old])].into_iter());
        assert!(!transport.selectable(&circuit_address([99; 32], peer, old)));
        assert!(!transport.withdrawn(&circuit_address([99; 32], peer, old)), "healthy backup is not withdrawn");
        assert!(!transport.withdrawn(&transport.address(peer)), "bootstrap is never withdrawn");
        assert!(transport.routed(&transport.address(peer)));
        transport.update_routes([(peer, vec![])].into_iter());
        assert!(transport.withdrawn(&circuit_address([99; 32], peer, old)));
        assert!(transport.selectable(&transport.address(peer)), "bootstrap still permits cold discovery");
        assert!(!transport.routed(&transport.address(peer)), "cached bootstrap RTT is not a retirement replacement");
        assert!(!transport.selectable(&circuit_address([99; 32], peer, old)));
        transport.update_routes([(peer, vec![new])].into_iter());
        assert!(!transport.selectable(&circuit_address([99; 32], peer, old)));
        assert!(transport.selectable(&circuit_address([99; 32], peer, new)));
    }
}
