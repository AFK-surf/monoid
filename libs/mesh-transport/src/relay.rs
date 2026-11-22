//! A workspace relay's forwarding endpoint is independent of its control link.
//! Only a complete issuer-authenticated snapshot changes its live admission.
use crate::{announcement::{Descriptor}, directory::{Receiver, Snapshot}, identity::{Binding, neighbor_secret}, routing::Scope, runtime::{Runtime, Peer, ALPN}};
use iroh::{Endpoint, EndpointId, RelayMode, RelayUrl, SecretKey, TransportAddr, endpoint::presets::Minimal};
use std::{collections::BTreeMap, sync::Arc};
use tokio::sync::Mutex;
mod bootstrap;

pub struct Forwarder {
    endpoint: Endpoint,
    key: SecretKey,
    policy: crate::policy::TransitPolicy,
    state: Arc<Mutex<State>>,
    control: Option<Endpoint>,
    bootstraps: BTreeMap<EndpointId, bootstrap::Task>,
    opening: Arc<tokio::sync::Semaphore>,
    scope: Scope,
    node: EndpointId,
    issuer: EndpointId,
    binding: Binding,
}
struct State {
    runtime: Runtime,
    private: Vec<Peer>,
    public: BTreeMap<EndpointId, Peer>,
    globals: BTreeMap<EndpointId, (crate::global_registration::Registration, u64)>,
    epoch: u64,
    relays: Vec<RelayUrl>,
}
impl Forwarder {
    pub async fn bind(key: &SecretKey, scope: Scope, issuer: EndpointId, generation: u64) -> Result<Self, String> {
        if generation == 0 || generation > 9_007_199_254_740_991 { return Err("invalid relay generation".into()); }
        let policy=crate::policy::TransitPolicy::empty();
        let endpoint = Endpoint::builder(Minimal).secret_key(neighbor_secret(key, scope, policy.digest()))
            .alpns(vec![ALPN.to_vec()]).relay_allowlist(policy.relay_urls.clone()).relay_mode(if policy.relay_urls.is_empty(){RelayMode::Disabled}else{RelayMode::custom(policy.relay_urls.clone())}).bind().await.map_err(|e| e.to_string())?;
        let runtime = Runtime::start_proven(endpoint.clone(), Binding::sign(key, scope, policy.digest(), generation, true), vec![], false)?;
        Ok(Self { endpoint, key:key.clone(), policy:policy.clone(), scope, node: key.public(), issuer, control:None,
            binding: Binding::sign(key, scope, policy.digest(), generation, true),
            state: Arc::new(Mutex::new(State { runtime, private: vec![], public: BTreeMap::new(), globals: BTreeMap::new(), epoch: 0,
                relays: vec![] })),
            bootstraps: BTreeMap::new(), opening: Arc::new(tokio::sync::Semaphore::new(4)) })
    }
    /// The issuer control endpoint stays independent of policy-scoped bootstrap sockets.
    pub async fn bind_with_control(key:&SecretKey,scope:Scope,issuer:EndpointId,generation:u64,control:Endpoint)->Result<Self,String> {
        if control.id()!=key.public() {return Err("relay control identity mismatch".into());}
        Self::bind(key,scope,issuer,generation).await
    }
    pub fn descriptor(&self) -> Descriptor { Descriptor { binding: self.binding.clone(), address: crate::announcement::bounded_address(self.endpoint.addr()) } }
    pub fn endpoint(&self) -> Endpoint { self.endpoint.clone() }
    pub async fn linked_nodes(&self) -> Vec<crate::routing::Node> { self.state.lock().await.runtime.linked_nodes().await }
    /// Use this only for snapshots from the authenticated issuer stream or the
    /// relay's private persisted cache. Signatures alone do not grant membership.
    pub async fn apply(&mut self, mut snapshot: Snapshot) -> Result<(), String> {
        // Recheck cached snapshots through the same bounded validator as the wire.
        let mut validator = Receiver::new(self.scope, self.node, self.issuer, self.binding.generation);
        let mut begin = serde_json::to_value(&snapshot.policy).map_err(|e| e.to_string())?;
        begin["begin"] = 1.into();
        validator.frame(&serde_json::to_vec(&begin).map_err(|e| e.to_string())?)?;
        for signed in &snapshot.records {
            validator.frame(&serde_json::to_vec(&serde_json::json!({"record":signed})).map_err(|e| e.to_string())?)?;
        }
        validator.frame(br#"{"end":1}"#)?;
        let policy=snapshot.policy.transit()?;
        if self.policy != policy { self.replace_lane(policy).await?; }
        let mut state = self.state.lock().await;
        let allowed = &self.policy.relay_urls;
        let mut peers = Vec::new();
        for signed in &snapshot.records {
            let record: crate::announcement::Announcement = serde_json::from_str(&signed.body).map_err(|e| e.to_string())?;
            if record.node == self.node || record.descriptor.binding.policy != self.policy.digest() { continue; }
            let minimum = snapshot.policy.generations.get(&record.node).copied().unwrap_or(0);
            let mut peer = Peer::from_binding(&record.descriptor.binding, record.descriptor.address, self.scope, minimum).map_err(str::to_owned)?;
            restrict(&mut peer, allowed)?;
            peers.push(peer);
        }
        let mut public = state.public.clone();
        public.retain(|node, _| snapshot.policy.global_relays.iter().any(|g|
            g.node == *node && state.globals.get(node).is_some_and(|(old,_)| old.generation == g.generation)));
        for peer in public.values_mut() {
            restrict(peer, allowed)?;
        }
        for global in &mut snapshot.policy.global_relays {restrict_address(&mut global.address,allowed)?;}
        if !snapshot.policy.global_relays.is_empty() && self.control.is_none() {
            self.control=Some(Endpoint::builder(Minimal).secret_key(self.key.clone())
                .relay_allowlist(allowed.clone()).relay_mode(if allowed.is_empty(){RelayMode::Disabled}else{RelayMode::custom(allowed.clone())})
                .bind().await.map_err(|e|e.to_string())?);
        }
        // Cancellation is followed by an epoch check under this same lock, so a
        // queued response from an old subscription cannot restore a removed peer.
        let obsolete: Vec<_> = state.globals.iter().filter(|(node,(old,_))|
            !snapshot.policy.global_relays.iter().any(|g| g.node == **node && g.generation == old.generation))
            .map(|(node,_)| *node).collect();
        for node in obsolete {
            state.globals.remove(&node);
            if let Some(task) = self.bootstraps.remove(&node) { task.stop().await; }
        }
        state.runtime.trusted_transit(snapshot.policy.global_relays.iter().map(|g| (*g.node.as_bytes(),g.generation)).collect()).await?;
        state.runtime.directory_proven(peers.iter().cloned().chain(public.values().cloned()).collect(), self.binding.clone()).await?;
        state.private = peers;
        state.public = public;
        state.relays = allowed.clone();
        for global in snapshot.policy.global_relays {
            if let Some((current,_))=state.globals.get_mut(&global.node) {
                // Address refresh changes the next dial, not this live lease.
                *current=global;
                continue;
            }
            state.epoch = state.epoch.checked_add(1).ok_or("relay bootstrap epoch exhausted")?;
            let epoch = state.epoch;
            let node = global.node;
            state.globals.insert(node,(global.clone(),epoch));
            let task = bootstrap::start(Arc::downgrade(&self.state), self.control.as_ref().unwrap().clone(), self.endpoint.clone(),
                self.binding.clone(), self.policy.clone(), global, epoch, self.opening.clone());
            self.bootstraps.insert(node,task);
        }
        Ok(())
    }
    async fn replace_lane(&mut self, policy:crate::policy::TransitPolicy)->Result<(),String> {
        for (_,task) in std::mem::take(&mut self.bootstraps) {task.stop().await;}
        // Closing this outer endpoint first cuts all old-lane data and controls.
        // The root/business endpoint is independent and remains alive.
        self.endpoint.close().await;
        if let Some(control)=self.control.take() {control.close().await;}
        let binding=Binding::sign(&self.key,self.scope,policy.digest(),self.binding.generation,true);
        let endpoint=Endpoint::builder(Minimal).secret_key(neighbor_secret(&self.key,self.scope,policy.digest()))
            .alpns(vec![ALPN.to_vec()]).relay_allowlist(policy.relay_urls.clone()).relay_mode(if policy.relay_urls.is_empty(){RelayMode::Disabled}else{RelayMode::custom(policy.relay_urls.clone())}).bind().await.map_err(|e|e.to_string())?;
        let runtime=Runtime::start_proven(endpoint.clone(),binding.clone(),vec![],false)?;
        let next=Arc::new(Mutex::new(State {runtime,private:vec![],public:BTreeMap::new(),globals:BTreeMap::new(),epoch:0,
            relays:vec![]}));
        let old=std::mem::replace(&mut self.state,next);
        if let Ok(old)=Arc::try_unwrap(old) {old.into_inner().runtime.close().await;}
        self.endpoint=endpoint;self.binding=binding;self.policy=policy;
        Ok(())
    }
    pub async fn close(mut self) {
        for (_, task) in std::mem::take(&mut self.bootstraps) { task.stop().await; }
        if let Ok(state) = Arc::try_unwrap(self.state) { state.into_inner().runtime.close().await; }
        self.endpoint.close().await;
        if let Some(control)=self.control.take() {control.close().await;}
    }
}
fn restrict(peer: &mut Peer, allowed: &[RelayUrl]) -> Result<(), String> {
    restrict_address(&mut peer.address, allowed)
}
fn restrict_address(address: &mut iroh::EndpointAddr, allowed: &[RelayUrl]) -> Result<(), String> {
    if address.addrs.iter().any(|a|matches!(a,TransportAddr::Custom(_))) {return Err("recursive mesh underlay".into());}
    address.addrs.retain(|address| match address {
        TransportAddr::Ip(_) => true,
        TransportAddr::Relay(url) => allowed.contains(url),
        _ => false,
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn underlay_policy_filters_addresses_and_rejects_recursion() {
        let node = SecretKey::from([90;32]).public();
        let kept: RelayUrl = "https://kept.example".parse().unwrap();
        let removed: RelayUrl = "https://removed.example".parse().unwrap();
        let mut address = iroh::EndpointAddr::new(node).with_addrs([
            TransportAddr::Ip("127.0.0.1:1234".parse().unwrap()), TransportAddr::Relay(kept.clone()), TransportAddr::Relay(removed.clone())]);
        restrict_address(&mut address,&[kept.clone()]).unwrap();
        assert_eq!(address.addrs.len(),2);
        assert!(address.addrs.contains(&TransportAddr::Relay(kept)));
        address.addrs.insert(TransportAddr::Custom(crate::transport::address([1;32],crate::policy::TransitPolicy::empty().digest(),[2;32])));
        assert!(restrict_address(&mut address,&[]).is_err());
    }
}
