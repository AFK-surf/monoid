//! Keep one custom transport bound while workspace scopes join and leave.
//! Each child retains its own directory, queues, neighbor endpoint and routes.
use crate::{
    routing::Scope,
    transport::{TRANSPORT_ID, Transport},
};
use iroh::endpoint::transports::{
    Addr, CustomEndpoint, CustomSender, CustomTransport, RecvInfo, Transmit,
};
use iroh_base::CustomAddr;
use n0_watcher::Watcher;
use std::{
    collections::BTreeMap,
    io,
    sync::{Arc, Mutex},
    task::{Context, Poll, Waker},
};

const MAX_SCOPES: usize = 32;
#[derive(Debug)]
struct Child {
    transport: Arc<Transport>,
    endpoint: Box<dyn CustomEndpoint>,
    sender: Arc<dyn CustomSender>,
}
#[derive(Debug)]
struct State {
    children: BTreeMap<Scope, Child>,
    waiter: Option<Waker>,
    bound: bool,
}
#[derive(Clone, Debug)]
pub struct Hub {
    state: Arc<Mutex<State>>,
    local: n0_watcher::Watchable<Vec<CustomAddr>>,
}
impl Default for Hub {
    fn default() -> Self {
        Self {
            state: Arc::new(Mutex::new(State {
                children: BTreeMap::new(),
                waiter: None,
                bound: false,
            })),
            local: n0_watcher::Watchable::new(vec![]),
        }
    }
}
impl Hub {
    pub(crate) fn selectable(&self, addr: &Addr) -> bool {
        let Addr::Custom(addr) = addr else { return true };
        if addr.id() != TRANSPORT_ID { return true; }
        if addr.data().len() != 96 { return false; }
        let scope: Scope = addr.data()[..32].try_into().unwrap();
        self.state.lock().unwrap().children.get(&scope)
            .is_some_and(|child| child.transport.selectable(addr))
    }

    pub(crate) fn routed(&self, addr: &Addr) -> bool {
        let Addr::Custom(addr) = addr else { return true };
        if addr.id() != TRANSPORT_ID {return true;}
        if addr.data().len()!=96 {return false;}
        let scope:Scope=addr.data()[..32].try_into().unwrap();
        self.state.lock().unwrap().children.get(&scope).is_some_and(|child|child.transport.routed(addr))
    }

    pub(crate) fn withdrawn(&self, addr: &Addr) -> bool {
        let Addr::Custom(addr) = addr else { return false };
        if addr.id() != TRANSPORT_ID || addr.data().len() != 96 { return false; }
        let scope: Scope = addr.data()[..32].try_into().unwrap();
        self.state.lock().unwrap().children.get(&scope)
            .is_none_or(|child| child.transport.withdrawn(addr))
    }

    pub fn insert(&self, scope: Scope, transport: Arc<Transport>) -> io::Result<()> {
        let mut state = self.state.lock().unwrap();
        if state.children.contains_key(&scope) {
            return Err(io::Error::other("mesh scope already bound"));
        }
        if state.children.len() >= MAX_SCOPES {
            return Err(io::Error::other("too many mesh scopes"));
        }
        let endpoint = transport.bind()?;
        let addresses = endpoint.watch_local_addrs().get();
        if addresses
            .iter()
            .any(|a| a.data().get(..32) != Some(scope.as_slice()))
        {
            return Err(io::Error::other("mesh scope mismatch"));
        }
        let sender = endpoint.create_sender();
        state.children.insert(scope, Child { endpoint, sender, transport });
        self.update(&state);
        if let Some(waker) = state.waiter.take() {
            waker.wake();
        }
        Ok(())
    }
    pub fn remove(&self, scope: Scope) {
        let mut state = self.state.lock().unwrap();
        state.children.remove(&scope);
        self.update(&state);
        if let Some(waker) = state.waiter.take() {
            waker.wake();
        }
    }
    fn update(&self, state: &State) {
        let addresses = state
            .children
            .values()
            .flat_map(|c| c.endpoint.watch_local_addrs().get())
            .collect();
        self.local.set(addresses).ok();
    }
}
impl CustomTransport for Hub {
    fn bind(&self) -> io::Result<Box<dyn CustomEndpoint>> {
        let mut state = self.state.lock().unwrap();
        if state.bound {
            return Err(io::Error::other("mesh hub already bound"));
        }
        state.bound = true;
        Ok(Box::new(Bound {
            hub: self.clone(),
            next: 0,
        }))
    }
}
impl CustomSender for Hub {
    fn is_valid_send_addr(&self, addr: &CustomAddr) -> bool {
        if addr.id() != TRANSPORT_ID || addr.data().len() != 96 {
            return false;
        }
        let scope: Scope = addr.data()[..32].try_into().unwrap();
        self.state
            .lock()
            .unwrap()
            .children
            .get(&scope)
            .is_some_and(|c| c.sender.is_valid_send_addr(addr))
    }
    fn poll_send(
        &self,
        cx: &mut Context<'_>,
        dst: &CustomAddr,
        src: Option<&CustomAddr>,
        transmit: &Transmit<'_>,
    ) -> Poll<io::Result<()>> {
        if dst.id() != TRANSPORT_ID || dst.data().len() != 96 {
            return Poll::Ready(Err(io::Error::other("invalid mesh address")));
        }
        let scope: Scope = dst.data()[..32].try_into().unwrap();
        let state = self.state.lock().unwrap();
        match state.children.get(&scope) {
            Some(child) => child.sender.poll_send(cx, dst, src, transmit),
            None => Poll::Ready(Err(io::Error::other("mesh scope removed"))),
        }
    }
}
#[derive(Debug)]
struct Bound {
    hub: Hub,
    next: usize,
}
impl CustomEndpoint for Bound {
    fn watch_local_addrs(&self) -> n0_watcher::Direct<Vec<CustomAddr>> {
        self.hub.local.watch()
    }
    fn create_sender(&self) -> Arc<dyn CustomSender> {
        Arc::new(self.hub.clone())
    }
    fn poll_recv(
        &mut self,
        cx: &mut Context<'_>,
        bufs: &mut [io::IoSliceMut<'_>],
        metas: &mut [noq_udp::RecvMeta],
        infos: &mut [RecvInfo],
    ) -> Poll<io::Result<usize>> {
        let mut state = self.hub.state.lock().unwrap();
        state.waiter = Some(cx.waker().clone());
        let keys: Vec<_> = state.children.keys().copied().collect();
        for offset in 0..keys.len() {
            let index = (self.next + offset) % keys.len();
            let result = state
                .children
                .get_mut(&keys[index])
                .unwrap()
                .endpoint
                .poll_recv(cx, bufs, metas, infos);
            match result {
                Poll::Ready(Ok(n)) => {
                    self.next = index + 1;
                    return Poll::Ready(Ok(n));
                }
                Poll::Ready(Err(_)) => {
                    state.children.remove(&keys[index]);
                    self.hub.update(&state);
                }
                Poll::Pending => {}
            }
        }
        Poll::Pending
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn scope_changes_keep_the_hub_and_other_scopes_bound() {
        let hub = Hub::default();
        let bound = hub.bind().unwrap();
        let (a, _out_a, _in_a) = Transport::new([1; 32], [10; 32], [98; 32]);
        let (b, _out_b, _in_b) = Transport::new([1; 32], [11; 32], [98; 32]);
        hub.insert([10; 32], a.clone()).unwrap();
        hub.insert([11; 32], b.clone()).unwrap();
        assert!(hub.is_valid_send_addr(&a.address([2; 32])));
        assert!(hub.is_valid_send_addr(&b.address([2; 32])));
        hub.remove([10; 32]);
        assert!(!hub.is_valid_send_addr(&a.address([2; 32])));
        assert!(hub.is_valid_send_addr(&b.address([2; 32])));
        assert_eq!(bound.watch_local_addrs().get().len(), 1);
        assert!(hub.bind().is_err());
    }
}
