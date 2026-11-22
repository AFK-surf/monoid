//! One bounded outgoing subscription per approved public root. A subscription
//! publishes only our descriptor; it never receives the workspace directory.
use super::{State, restrict};
use crate::{announcement::{Descriptor, bounded_address}, global_registration::Registration, identity::Binding, public_service::Subscription, runtime::Peer};
use iroh::{Endpoint, EndpointId, Watcher};
use std::{sync::{Arc, Weak}, time::Duration};
use tokio::sync::{Mutex, Semaphore};

pub(super) struct Task(Option<tokio::task::JoinHandle<()>>);
impl Task {
    pub(super) async fn stop(mut self) {
        if let Some(task) = self.0.take() { task.abort(); let _ = task.await; }
    }
}
impl Drop for Task { fn drop(&mut self) { if let Some(task) = &self.0 { task.abort(); } } }

async fn received(state: &Weak<Mutex<State>>, binding: &Binding,
    node: EndpointId, epoch: u64, descriptor: Descriptor) -> Result<(), String> {
    let state = state.upgrade().ok_or("relay closed")?;
    let mut state = state.lock().await;
    let (global, current) = state.globals.get(&node).ok_or("public relay removed")?;
    if *current != epoch || descriptor.binding.policy != binding.policy || descriptor.binding.endpoint != *node.as_bytes()
        || descriptor.binding.generation != global.generation || !descriptor.binding.transit {
        return Err("public relay subscription replaced".into());
    }
    let mut peer = Peer::from_binding(&descriptor.binding, descriptor.address, binding.scope, global.generation).map_err(str::to_owned)?;
    let allowed = state.relays.clone();
    restrict(&mut peer, &allowed)?;
    let mut public = state.public.clone();
    public.insert(node, peer);
    state.runtime.directory_proven(state.private.iter().cloned().chain(public.values().cloned()).collect(), binding.clone()).await?;
    state.public = public;
    Ok(())
}

pub(super) fn start(state: Weak<Mutex<State>>, root: Endpoint, endpoint: Endpoint, binding: Binding, policy:crate::policy::TransitPolicy,
    global: Registration, epoch: u64, opening: Arc<Semaphore>) -> Task {
    Task(Some(tokio::spawn(async move {
        let mut retry = 1;
        loop {
            let result = async {
                let address={
                    let state=state.upgrade().ok_or("relay closed")?;
                    let state=state.lock().await;
                    let (current,version)=state.globals.get(&global.node).ok_or("public relay removed")?;
                    if *version!=epoch || current.generation!=global.generation {return Err("public relay replaced".into());}
                    current.address.clone()
                };
                let mut addresses = endpoint.watch_addr();
                let own = Descriptor { binding: binding.clone(), address: bounded_address(addresses.get()) };
                let permit = opening.acquire().await.map_err(|_| "bootstrap queue closed")?;
                let subscription = Subscription::open(&root, address, &own, &policy, global.generation).await?;
                drop(permit);
                received(&state,&binding,global.node,epoch,subscription.initial().clone()).await?;
                retry = 1;
                let (own_tx, own_rx) = tokio::sync::watch::channel(own);
                let (tx, mut rx) = tokio::sync::mpsc::channel(1);
                let run = subscription.run(own_rx,tx);
                let publish = async {
                    loop {
                        let address = bounded_address(addresses.updated().await.map_err(|e| e.to_string())?);
                        own_tx.send(Descriptor { binding: binding.clone(), address }).map_err(|_| "bootstrap publisher ended")?;
                    }
                    #[allow(unreachable_code)] Ok::<(),String>(())
                };
                let consume = async {
                    while let Some(descriptor) = rx.recv().await {
                        received(&state,&binding,global.node,epoch,descriptor).await?;
                    }
                    Err::<(),String>("bootstrap subscription ended".into())
                };
                tokio::select! { r=run=>r, r=publish=>r, r=consume=>r }
            }.await;
            if let Err(error) = result { eprintln!("relay public bootstrap unavailable: {error}"); }
            // A failed subscription keeps its last admitted forwarding neighbor;
            // only a new issuer snapshot removes that permission.
            tokio::time::sleep(Duration::from_secs(retry)).await;
            retry = (retry * 2).min(60);
        }
    })))
}
