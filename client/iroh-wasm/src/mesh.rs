//! Browser scopes are leaves. The outer iroh endpoint uses ordinary relay WSS;
//! the shared runtime carries inner root-authenticated QUIC beyond its neighbor.
use futures::lock::Mutex;
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, TransportAddr, endpoint::presets::Minimal};
use mesh_transport::{hub::Hub, identity::{Binding, neighbor_secret}, routing::{Scope, MAX_NODES}, policy::{TransitPolicy, Global}, runtime::{Peer, Runtime, ALPN}};
use serde::{Deserialize, Serialize};
use std::{collections::{BTreeMap, BTreeSet}, sync::Arc};

#[derive(Clone, Deserialize, Serialize)]
pub struct Descriptor { binding: Binding, address: EndpointAddr }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    scope: String,
    transit: bool,
    peers: Vec<Descriptor>,
    relay_urls: Vec<RelayUrl>,
    #[serde(default)]
    global_relays: Vec<Global>,
}
#[derive(Deserialize)]
pub struct UseLeaf { scope: String, attachment: mesh_transport::leaf::Attachment }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetachLeaf { scope: String, attachment_id: [u8;32] }
struct Kept { endpoint: Endpoint, runtime: Runtime, binding: Binding, relays: Vec<RelayUrl> }
pub struct Scopes { pub hub: Arc<Hub>, scopes: Mutex<BTreeMap<Scope, Kept>> }
fn scope(text: &str) -> Result<Scope, String> {
    hex::decode(text).map_err(|e|e.to_string())?.try_into().map_err(|_|"mesh scope must be 32 bytes".into())
}
impl Default for Scopes {
    fn default() -> Self { Self { hub: Arc::default(), scopes: Mutex::new(BTreeMap::new()) } }
}
impl Scopes {
    pub async fn configure(&self, root: &SecretKey, config: Config) -> Result<Descriptor, String> {
        let scope = scope(&config.scope)?;
        if config.transit { return Err("browser endpoints cannot provide transit".into()); }
        if config.global_relays.len() > 32 { return Err("too many global mesh relays".into()); }
        let mut trusted = BTreeMap::new();
        for global in &config.global_relays {
            if global.generation == 0 || global.generation > 9_007_199_254_740_991 || global.node == root.public()
                || trusted.insert(*global.node.as_bytes(), global.generation).is_some()
                || config.peers.iter().any(|p|p.binding.endpoint == *global.node.as_bytes()) { return Err("invalid global mesh identity".into()); }
        }
        if config.peers.len() >= MAX_NODES || config.relay_urls.len() > 32 { return Err("mesh scope capacity".into()); }
        let policy = TransitPolicy::new(config.relay_urls.clone(), config.global_relays)?.digest();
        let mut peers = Vec::new();
        let mut nodes = BTreeSet::from([*root.public().as_bytes()]);
        for descriptor in config.peers {
            if descriptor.address.addrs.len() > 8 || !nodes.insert(descriptor.binding.endpoint) { return Err("duplicate or excessive mesh peer".into()); }
            if descriptor.binding.policy != policy { return Err("mesh peer has another policy lane".into()); }
            let mut peer = Peer::from_binding(&descriptor.binding, descriptor.address, scope, 1).map_err(str::to_owned)?;
            if peer.address.addrs.iter().any(|a|matches!(a,TransportAddr::Custom(_))) { return Err("mesh neighbor cannot use a custom transport".into()); }
            peer.address.addrs.retain(|a| matches!(a,TransportAddr::Relay(url) if config.relay_urls.contains(url)));
            peers.push(peer);
        }
        let mut scopes = self.scopes.lock().await;
        if scopes.get(&scope).is_some_and(|kept| kept.binding.policy != policy) {
            self.hub.remove(scope);
            if let Some(kept) = scopes.remove(&scope) { kept.runtime.close().await; }
        }
        if let Some(kept) = scopes.get_mut(&scope) {
            for old in &kept.relays { if !config.relay_urls.contains(old) { kept.endpoint.remove_relay(old).await; } }
            for relay in &config.relay_urls {
                if !kept.relays.contains(relay) { kept.endpoint.insert_relay(relay.clone(), Arc::new(iroh::RelayConfig::from(relay.clone()))).await; }
            }
            kept.runtime.trusted_transit(trusted).await?;
            kept.runtime.directory_proven(peers, kept.binding.clone()).await?;
            kept.relays = config.relay_urls;
            return Ok(Descriptor { binding: kept.binding.clone(), address: kept.endpoint.addr() });
        }
        if scopes.len() >= 32 { return Err("too many mesh scopes".into()); }
        let binding = Binding::sign(root, scope, policy, 1, false);
        let endpoint = Endpoint::builder(Minimal).secret_key(neighbor_secret(root, scope, policy))
            .alpns(vec![ALPN.to_vec()])
            .relay_allowlist(config.relay_urls.clone())
            .relay_mode(if config.relay_urls.is_empty() { RelayMode::Disabled } else { RelayMode::custom(config.relay_urls.clone()) })
            .bind().await.map_err(|e|e.to_string())?;
        let runtime = Runtime::start_proven(endpoint.clone(), binding.clone(), peers, false)?;
        runtime.trusted_transit(trusted).await?;
        if let Err(error) = self.hub.insert(scope, runtime.transport.clone()) { runtime.close().await; return Err(error.to_string()); }
        let answer = Descriptor { binding: binding.clone(), address: endpoint.addr() };
        scopes.insert(scope, Kept { endpoint, runtime, binding, relays: config.relay_urls });
        Ok(answer)
    }
    pub async fn use_leaf(&self, root: EndpointId, command: UseLeaf) -> Result<(), String> {
        if command.attachment.leaf.endpoint != *root.as_bytes() { return Err("attachment belongs to another leaf".into()); }
        let scopes = self.scopes.lock().await;
        let kept = scopes.get(&scope(&command.scope)?).ok_or("mesh scope removed")?;
        kept.runtime.attach_leaf(command.attachment, None).await
    }
    pub async fn detach_leaf(&self, command: DetachLeaf) -> Result<(), String> {
        let scopes = self.scopes.lock().await;
        if let Some(kept) = scopes.get(&scope(&command.scope)?) { kept.runtime.detach_leaf(command.attachment_id).await; }
        Ok(())
    }
    pub async fn address(&self, text: &str, peer: EndpointId) -> Result<TransportAddr, String> {
        let scopes = self.scopes.lock().await;
        let kept = scopes.get(&scope(text)?).ok_or("mesh scope is not configured")?;
        Ok(TransportAddr::Custom(kept.runtime.transport.address(*peer.as_bytes())))
    }
    pub async fn remove(&self, text: &str) -> Result<(), String> {
        let scope = scope(text)?;
        let mut scopes = self.scopes.lock().await;
        self.hub.remove(scope);
        if let Some(kept) = scopes.remove(&scope) { kept.runtime.close().await; }
        Ok(())
    }
    pub async fn clear(&self) {
        let mut scopes = self.scopes.lock().await;
        for (scope, kept) in std::mem::take(&mut *scopes) { self.hub.remove(scope); kept.runtime.close().await; }
    }
}
