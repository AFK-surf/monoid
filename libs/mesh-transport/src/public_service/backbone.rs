//! A scope opens global neighbors only after authenticated path traffic asks for
//! it. Bootstrap sockets do not renew the idle lease, so relay cycles expire.
use super::*;
use crate::global_registration::Registration;
use std::sync::Weak;
use tokio::{sync::watch,time::Instant};
const IDLE:Duration=Duration::from_secs(45);
#[derive(Clone)]
pub(super) struct Config {registry:Vec<Registration>}
pub(super) struct Link {registration:Registration,task:tokio::task::JoinHandle<()>}
impl Drop for Link {fn drop(&mut self){self.task.abort();}}
impl Scopes {
    pub async fn backbone(&self,root:Endpoint,registry:Vec<Registration>)->Result<(),String> {
        if root.id()!=self.key.public() || registry.len()>32 {return Err("invalid public backbone registry".into());}
        let mut nodes=std::collections::BTreeSet::new();
        for relay in &registry {relay.validate()?;if !nodes.insert(relay.node) {return Err("duplicate public backbone node".into());}}
        let previous=self.backbone.borrow().clone();
        let known:std::collections::BTreeSet<_>=previous.iter().flat_map(|c|c.registry.iter()).chain(registry.iter()).map(|r|*r.node.as_bytes()).collect();
        let admitted:std::collections::BTreeMap<_,_>=registry.iter().map(|r|(*r.node.as_bytes(),r.generation)).collect();
        {
            let mut state=self.state.lock().await;
            let history:std::collections::BTreeSet<_>=state.history.iter().copied().chain(known.iter().copied()).collect();
            if history.len()>256 {return Err("public registration history capacity".into());}
            state.history=history;state.globals=admitted.clone();
            // A registry revocation invalidates precisely the lanes whose
            // immutable policy names that generation. Closing the whole lane
            // also discards active path proofs, so none can revive that identity.
            let revoked:Vec<_>=state.scopes.iter().filter(|(_,kept)|kept.policy.globals.iter().any(|g|
                state.history.contains(g.node.as_bytes())&&admitted.get(g.node.as_bytes())!=Some(&g.generation))).map(|(lane,_)|*lane).collect();
            for lane in revoked {
                let gone=state.scopes.remove(&lane).unwrap();gone.close().await;
            }
            for kept in state.scopes.values_mut() {
                // A removed global identity cannot return as an ordinary caller
                // on its still-open bootstrap socket.
                kept.peers.retain(|node,(descriptor,_)|!known.contains(node)||(admitted.get(node)==Some(&descriptor.binding.generation)&&kept.policy.admits(EndpointId::from_bytes(node).unwrap(),descriptor.binding.generation)));
                kept.remote.retain(|node,descriptor|!known.contains(node)||(admitted.get(node)==Some(&descriptor.binding.generation)&&kept.policy.admits(EndpointId::from_bytes(node).unwrap(),descriptor.binding.generation)));
                kept.leases.retain(|node,conn|{
                    if kept.peers.contains_key(node) {true}else{conn.close(0u32.into(),b"global registration removed");false}
                });
                apply(self,kept).await?;
                kept.topology.notify_one();
            }
        }
        self.backbone.send_replace(Some(Config {registry}));
        Ok(())
    }
}
pub(super) fn has_room(kept:&ScopeState,node:Node)->bool {
    let reserved:std::collections::BTreeSet<_>=kept.peers.keys().copied()
        .chain(kept.outgoing.keys().map(|id|*id.as_bytes())).collect();
    reserved.contains(&node)||reserved.len()<32
}
fn active_at(last:Option<Instant>,now:Instant)->bool {
    last.is_some_and(|last|now.saturating_duration_since(last)<IDLE)
}
pub(super) fn follow(scopes:Weak<Scopes>,lane:Lane,incarnation:u64,mut activity:watch::Receiver<Option<Instant>>,mut config:watch::Receiver<Option<Config>>,topology:Arc<tokio::sync::Notify>) {
    tokio::spawn(async move {
        loop {
            let last=*activity.borrow_and_update();
            let active=active_at(last,Instant::now());
            let current=config.borrow_and_update().clone();
            let Some(owner)=scopes.upgrade() else {return};
            if reconcile(&owner,lane,incarnation,if active {current}else{None}).await.is_err() {return;}
            drop(owner);
            tokio::select! {
                _=topology.notified()=>{},
                result=activity.changed()=>{if result.is_err(){return;}},
                result=config.changed()=>{if result.is_err(){return;}},
                _=async {if let Some(last)=last.filter(|_|active) {tokio::time::sleep_until(last+IDLE).await;}else{std::future::pending::<()>().await;}}=>{},
            }
        }
    });
}
async fn reconcile(owner:&Arc<Scopes>,lane:Lane,incarnation:u64,config:Option<Config>)->Result<(),String> {
    let mut state=owner.state.lock().await;
    let kept=state.scopes.get_mut(&lane).filter(|s|s.incarnation==incarnation).ok_or("public scope ended")?;
    let wanted:Vec<_>=config.as_ref().map(|c|c.registry.iter().filter(|r|r.node!=owner.key.public() && kept.policy.admits(r.node,r.generation)).cloned().collect()).unwrap_or_default();
    let obsolete:Vec<_>=kept.outgoing.iter().filter(|(id,link)|!wanted.iter().any(|r|r.node==**id&&r.generation==link.registration.generation)).map(|(id,_)|*id).collect();
    for id in obsolete {kept.outgoing.remove(&id);kept.remote.remove(id.as_bytes());}
    apply(owner,kept).await?;
    if config.is_some() {
        for relay in wanted {
            if let Some(link)=kept.outgoing.get_mut(&relay.node) {
                link.registration=relay;
                continue;
            }
            if !has_room(kept,*relay.node.as_bytes()) {break;}
            // One inbound subscription already supplies this neighbor. Avoid an
            // unnecessary reverse subscription; crossed simultaneous opens remain bounded.
            if kept.peers.contains_key(relay.node.as_bytes()) {continue;}
            if kept.bootstrap.is_none() {
                kept.bootstrap=Some(Endpoint::builder(Minimal).secret_key(owner.key.clone())
                    .relay_allowlist(kept.allowed.clone()).relay_mode(if kept.allowed.is_empty(){RelayMode::Disabled}else{RelayMode::custom(kept.allowed.clone())})
                    .bind().await.map_err(|e|e.to_string())?);
            }
            let weak=Arc::downgrade(owner);let root=kept.bootstrap.as_ref().unwrap().clone();let registration=relay.clone();
            let task=tokio::spawn(async move {run(weak,lane,incarnation,root,registration).await;});
            kept.outgoing.insert(relay.node,Link {registration:relay,task});
        }
    }
    if kept.outgoing.is_empty() {if let Some(root)=kept.bootstrap.take() {root.close().await;}}
    if kept.peers.is_empty() && kept.outgoing.is_empty() {
        let gone=state.scopes.remove(&lane).unwrap();drop(state);gone.close().await;
        return Err("idle public scope ended".into());
    }
    Ok(())
}
async fn apply(owner:&Scopes,kept:&mut ScopeState)->Result<(),String> {
    let mut descriptors=kept.remote.clone();descriptors.extend(kept.peers.iter().map(|(n,(d,_))|(*n,d.clone())));
    owner.install(kept,descriptors.values()).await
}
fn current<'a>(state:&'a mut State,lane:Lane,incarnation:u64,relay:&Registration)->Result<&'a mut ScopeState,String> {
    let kept=state.scopes.get_mut(&lane).filter(|s|s.incarnation==incarnation).ok_or("public scope ended")?;
    if !kept.outgoing.get(&relay.node).is_some_and(|l|l.registration.generation==relay.generation) {return Err("public backbone neighbor replaced".into());}
    Ok(kept)
}
async fn learned(owner:&Scopes,lane:Lane,incarnation:u64,relay:&Registration,descriptor:Descriptor)->Result<(),String> {
    check_response(&descriptor,relay.node,lane.0,lane.1,relay.generation)?;
    let mut state=owner.state.lock().await;
    let kept=current(&mut state,lane,incarnation,relay)?;
    let old=kept.remote.insert(*relay.node.as_bytes(),descriptor);
    if let Err(error)=apply(owner,kept).await {
        if let Some(old)=old {kept.remote.insert(*relay.node.as_bytes(),old);}else{kept.remote.remove(relay.node.as_bytes());}
        return Err(error);
    }
    Ok(())
}
async fn run(scopes:Weak<Scopes>,lane:Lane,incarnation:u64,root:Endpoint,relay:Registration) {
    let mut backoff=1;
    loop {
        let Some(owner)=scopes.upgrade() else {return};
        let (endpoint,binding,policy,address)={
            let mut state=owner.state.lock().await;
            let Ok(kept)=current(&mut state,lane,incarnation,&relay) else {return};
            (kept.endpoint.clone(),kept.own.clone(),kept.policy.clone(),kept.outgoing[&relay.node].registration.address.clone())
        };
        let opening=owner.opening.clone();drop(owner);
        let result=async {
            let mut addresses=endpoint.watch_addr();
            let own=Descriptor {binding:binding.clone(),address:bounded_address(addresses.get())};
            let permit=opening.acquire().await.map_err(|_|"public backbone stopped")?;
            let subscription=Subscription::open(&root,address,&own,&policy,relay.generation).await?;
            drop(permit);
            let owner=scopes.upgrade().ok_or("public service ended")?;
            learned(&owner,lane,incarnation,&relay,subscription.initial().clone()).await?;
            drop(owner);backoff=1;
            let (own_tx,own_rx)=watch::channel(own);
            let (tx,mut rx)=tokio::sync::mpsc::channel(1);
            let receive=async {
                while let Some(descriptor)=rx.recv().await {
                    let owner=scopes.upgrade().ok_or("public service ended")?;
                    learned(&owner,lane,incarnation,&relay,descriptor).await?;
                }
                Err::<(),String>("public backbone subscription ended".into())
            };
            let publish=async {
                loop {
                    let address=bounded_address(addresses.updated().await.map_err(|e|e.to_string())?);
                    own_tx.send(Descriptor {binding:binding.clone(),address}).map_err(|_|"public backbone publisher ended")?;
                }
                #[allow(unreachable_code)] Ok::<(),String>(())
            };
            tokio::select! {r=subscription.run(own_rx,tx)=>r,r=receive=>r,r=publish=>r}
        }.await;
        if let Err(error)=result {eprintln!("public backbone unavailable: {error}");}
        tokio::time::sleep(Duration::from_secs(backoff)).await;backoff=(backoff*2).min(60);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bootstrap_alone_does_not_keep_an_idle_scope_active() {
        let start=Instant::now();
        assert!(!active_at(None,start));
        assert!(active_at(Some(start),start+IDLE-Duration::from_millis(1)));
        assert!(!active_at(Some(start),start+IDLE));
        assert!(!active_at(Some(start),start+IDLE*2));
        assert!(active_at(Some(start+IDLE),start+IDLE));
    }
}
