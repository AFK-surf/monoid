//! Native mesh scopes outlive the Node process that configures the front.
use futures::StreamExt;
use tokio::io::AsyncWriteExt;
use iroh::{Watcher, Endpoint, EndpointAddr, RelayMode, RelayUrl, SecretKey, endpoint::presets::Minimal};
use mesh_transport::{
    announcement::bounded_address,
    hub::Hub,
    identity::{Binding, neighbor_secret},
    routing::Scope,
    runtime::{ALPN, Peer, Runtime},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::{BTreeMap, BTreeSet}, sync::Arc};
use tokio::sync::Mutex;

pub struct Scopes {
    pub hub: Arc<Hub>,
    scopes: Arc<Mutex<BTreeMap<Scope, Kept>>>,
    changed: tokio::sync::watch::Sender<u64>,
    subscriptions: std::sync::Mutex<BTreeMap<u64, Task>>,
    configure_lock:Mutex<()>,
    bootstrap_opening:Arc<tokio::sync::Semaphore>,
    bootstrap_changes:Arc<tokio::sync::Notify>,
    #[cfg(test)]
    scopes_lock_wait: Arc<tokio::sync::Notify>,
}
struct Task(tokio::task::JoinHandle<()>);
impl Drop for Task { fn drop(&mut self) { self.0.abort(); } }
impl Default for Scopes {
    fn default() -> Self {
        Self { hub: Arc::new(Hub::default()), scopes: Arc::new(Mutex::new(BTreeMap::new())),
            changed: tokio::sync::watch::channel(0).0, subscriptions: std::sync::Mutex::new(BTreeMap::new()),
            configure_lock:Mutex::new(()),bootstrap_opening:Arc::new(tokio::sync::Semaphore::new(4)),
            bootstrap_changes:Arc::new(tokio::sync::Notify::new()),
            #[cfg(test)]
            scopes_lock_wait: Arc::new(tokio::sync::Notify::new()) }
    }
}
struct Kept {
    _address_watch: Task,
    runtime: Runtime,
    endpoint: Endpoint,
    binding: Binding,
    policy: mesh_transport::policy::TransitPolicy,
    relays: Vec<RelayUrl>,
    bootstrap_endpoint:Option<Endpoint>,
    private_peers: Vec<Peer>,
    public_peers: BTreeMap<iroh::EndpointId, Peer>,
    bootstraps: BTreeMap<iroh::EndpointId, Bootstrap>,
    bootstrap_version: u64,
    leaf_connections: BTreeMap<[u8;32], ([u8;32], [u8;32], Task)>,
}
struct Bootstrap { generation:u64, address:EndpointAddr, version:u64, _task:Task }
#[derive(Deserialize)]
struct GivenPeer {
    binding: Binding,
    address: EndpointAddr,
}
fn scope(value: &Value) -> Result<Scope, String> {
    hex::decode(
        value
            .get("scope")
            .and_then(Value::as_str)
            .ok_or("missing mesh scope")?,
    )
    .map_err(|e| e.to_string())?
    .try_into()
    .map_err(|_| "mesh scope must be 32 bytes".into())
}
// NAPI represents JS numbers beyond u32 as JSON floating-point numbers. Their
// integer value remains exact through MAX_SAFE; reject fractions and overflow.
fn safe_integer(value: &Value) -> Option<u64> {
    let n=value.as_f64()?;
    (n.is_finite() && n>=0.0 && n<=9_007_199_254_740_991.0 && n.fract()==0.0).then_some(n as u64)
}
// Minimal endpoints have no address lookup. Only explicit IP addresses and
// allowed underlay relays may be dialed; a custom transport would recurse.
fn restrict_peer(peer: &mut Peer, allowed: &[RelayUrl]) -> Result<(), String> {
    if peer.address.addrs.iter().any(|a| matches!(a, iroh::TransportAddr::Custom(_))) {
        return Err("mesh neighbor cannot use a custom transport".into());
    }
    peer.address.addrs.retain(|a| match a {
        iroh::TransportAddr::Relay(url) => allowed.contains(url),
        iroh::TransportAddr::Ip(_) => true,
        _ => false,
    });
    Ok(())
}
impl Scopes {
    /// Push one bounded snapshot per change over the front's existing control
    /// socket. No timer, repeated status request, or separate public listener.
    #[allow(dead_code)]
    pub fn subscribe<W: tokio::io::AsyncWrite + Unpin + Send + 'static>(&self, id: u64, write: Arc<Mutex<W>>) -> Result<(), String> {
        self.subscribe_updates(id, move |snapshot| {
            let write = write.clone();
            async move {
                let mut bytes = serde_json::to_vec(&json!({"event":"meshScopes", "scopes":snapshot})).unwrap();
                bytes.push(b'\n');
                write.lock().await.write_all(&bytes).await.map_err(|e| e.to_string())
            }
        })
    }
    /// Every consumer has at most one snapshot being delivered. Changes during
    /// delivery coalesce in the watch channel, preserving the newest state.
    /// Kept for `station/native/mesh`, which compiles this file directly.
    #[allow(dead_code)]
    pub fn subscribe_updates<F, U>(&self, id: u64, send: F) -> Result<(), String>
    where F: Fn(Vec<Value>) -> U + Send + 'static,
          U: std::future::Future<Output=Result<(),String>> + Send + 'static {
        self.subscribe_updates_until(id, std::future::pending(), send)
    }
    /// Same as `subscribe_updates`, cancelling the entire delivery loop (including `scopes.lock()`,
    /// `send`, and idle `changed` waits) as soon as `cancel` resolves.
    pub fn subscribe_updates_until<C, F, U>(&self, id: u64, cancel: C, send: F) -> Result<(), String>
    where C: std::future::Future<Output = ()> + Send + 'static,
          F: Fn(Vec<Value>) -> U + Send + 'static,
          U: std::future::Future<Output=Result<(),String>> + Send + 'static {
        let mut subscriptions = self.subscriptions.lock().unwrap();
        subscriptions.retain(|_, task| !task.0.is_finished());
        if subscriptions.len() >= 32 && !subscriptions.contains_key(&id) { return Err("too many mesh subscribers".into()); }
        let scopes = self.scopes.clone();
        let mut changed = self.changed.subscribe();
        #[cfg(test)]
        let scopes_lock_wait = self.scopes_lock_wait.clone();
        let task = tokio::spawn(async move {
            tokio::select! {
                biased;
                _ = cancel => {}
                _ = async move {
                    loop {
                        changed.borrow_and_update();
                        #[cfg(test)]
                        scopes_lock_wait.notify_waiters();
                        let snapshot: Vec<Value> = scopes.lock().await.iter().map(|(scope, kept)|
                            json!({"scope":hex::encode(scope), "descriptor":{"binding":kept.binding,"address":bounded_address(kept.endpoint.addr())}})).collect();
                        if send(snapshot).await.is_err() { break; }
                        if changed.changed().await.is_err() { break; }
                    }
                } => {}
            }
        });
        subscriptions.insert(id, Task(task));
        Ok(())
    }
    pub fn unsubscribe(&self, id: u64) { self.subscriptions.lock().unwrap().remove(&id); }
    #[cfg(test)]
    #[allow(dead_code)]
    pub(crate) fn notify_changed(&self) {
        self.changed.send_modify(|version| *version = version.wrapping_add(1));
    }
    #[cfg(test)]
    #[allow(dead_code)]
    pub(crate) async fn lock_scopes_for_test(&self) -> impl Drop + '_ {
        self.scopes.lock().await
    }
    #[cfg(test)]
    #[allow(dead_code)]
    pub(crate) fn scopes_lock_wait(&self) -> Arc<tokio::sync::Notify> {
        self.scopes_lock_wait.clone()
    }
    /// Called only with the station's admitted directory. A self-signed binding
    /// confirms identities; it does not grant workspace membership.
    pub async fn configure(&self, key: &SecretKey, value: &Value) -> Result<Value, String> {
        let scope = scope(value)?;
        let transit = value.get("transit").and_then(Value::as_bool).unwrap_or(false);
        let raw = value
            .get("peers")
            .and_then(Value::as_array)
            .ok_or("missing mesh peers")?;
        if raw.len() > mesh_transport::routing::MAX_NODES {
            return Err("too many mesh peers".into());
        }
        let relays: Vec<RelayUrl> = serde_json::from_value(value.get("relayUrls").cloned().unwrap_or(json!([]))).map_err(|e|e.to_string())?;
        let globals: Vec<mesh_transport::global_registration::Registration> = serde_json::from_value(value.get("globalRelays").cloned().unwrap_or(json!([]))).map_err(|e|e.to_string())?;
        for global in &globals {global.validate()?;}
        let policy=mesh_transport::policy::TransitPolicy::new(relays.clone(),globals.iter().map(|r|mesh_transport::policy::Global {node:r.node,generation:r.generation}).collect())?;
        let relays=policy.relay_urls.clone();
        let mut peers = Vec::with_capacity(raw.len());
        for peer in raw {
            let peer: GivenPeer =
                serde_json::from_value(peer.clone()).map_err(|e| e.to_string())?;
            if peer.address.addrs.len() > 8 {
                return Err("too many mesh peer addresses".into());
            }
            let given=Peer::from_binding(&peer.binding, peer.address, scope, 0).map_err(str::to_owned)?;
            // Old-lane announcements can coexist during a workspace policy
            // update; they remain authenticated records, never usable neighbors.
            if peer.binding.policy == policy.digest() {peers.push(given);}
        }
        let mut identities = BTreeSet::new();
        let mut nodes = BTreeSet::from([*key.public().as_bytes()]);
        for peer in &peers {
            if !identities.insert(peer.address.id) { return Err("duplicate mesh neighbor".into()); }
            nodes.insert(peer.node);
        }
        if nodes.len() + globals.len() > mesh_transport::routing::MAX_NODES { return Err("too many mesh nodes".into()); }
        if peers.iter().map(|p| p.node).collect::<BTreeSet<_>>().len() != peers.len() {
            return Err("duplicate mesh endpoint".into());
        }
        let mut scopes = self.scopes.lock().await;
        let generation=match scopes.get(&scope) {
            Some(kept) if kept.binding.transit!=transit => kept.binding.generation.checked_add(1).ok_or("mesh generation exhausted")?,
            Some(kept) => kept.binding.generation,
            None => 1,
        };
        if scopes.get(&scope).is_some_and(|kept|kept.policy!=policy) {
            self.hub.remove(scope);
            let mut old=scopes.remove(&scope).unwrap();old.bootstraps.clear();
            old.endpoint.close().await;
            if let Some(endpoint)=old.bootstrap_endpoint.take() {endpoint.close().await;}
            old.runtime.close().await;
        }
        if let Some(kept) = scopes.get_mut(&scope) {
            for peer in &mut peers {restrict_peer(peer,&relays)?;}
            // A changed allowlist replaces the entire lane above. This branch
            // only admits new addresses under its fixed existing policy.
            let binding = if kept.binding.transit != transit {
                Binding::sign(key, scope, policy.digest(), generation, transit)
            } else { kept.binding.clone() };
            let private_peers=peers.clone();
            for public in kept.public_peers.values_mut() {
                restrict_peer(public,&relays)?;
                peers.push(public.clone());
            }
            kept.runtime.directory_proven(peers, binding.clone()).await?;
            kept.private_peers=private_peers;
            identities.extend(kept.public_peers.values().map(|p|p.address.id));
            kept.relays = relays;
            if kept.binding.transit != transit {
                kept.binding = binding;
                self.changed.send_modify(|version| *version = version.wrapping_add(1));
            }
            return Ok(json!({"binding":kept.binding,"address":bounded_address(kept.endpoint.addr())}));
        }
        if scopes.len() >= 32 {
            return Err("too many mesh scopes".into());
        }
        for peer in &mut peers {restrict_peer(peer,&relays)?;}
        let binding = Binding::sign(key, scope, policy.digest(), generation, transit);
        let endpoint = Endpoint::builder(Minimal)
            .secret_key(neighbor_secret(key, scope, policy.digest()))
            .alpns(vec![ALPN.to_vec()])
            .relay_allowlist(relays.clone()).relay_mode(if relays.is_empty() {
                RelayMode::Disabled
            } else {
                RelayMode::custom(relays.clone())
            })
            .bind()
            .await
            .map_err(|e| e.to_string())?;
        let private_peers=peers.clone();
        let runtime = Runtime::start_proven(endpoint.clone(), binding.clone(), peers, false)?;
        if let Err(error) = self.hub.insert(scope, runtime.transport.clone()) {
            runtime.close().await;
            return Err(error.to_string());
        }
        let answer = json!({"binding":binding,"address":bounded_address(endpoint.addr())});
        let mut addresses = endpoint.watch_addr().stream();
        let changed = self.changed.clone();
        let address_watch = Task(tokio::spawn(async move {
            while addresses.next().await.is_some() { changed.send_modify(|version| *version = version.wrapping_add(1)); }
        }));
        scopes.insert(
            scope,
            Kept {
                _address_watch: address_watch,
                runtime,
                endpoint,
                binding,
                policy,
                relays,
                bootstrap_endpoint:None,
                private_peers,
                public_peers:BTreeMap::new(),
                bootstraps:BTreeMap::new(),
                bootstrap_version:0,
                leaf_connections:BTreeMap::new(),
            },
        );
        self.changed.send_modify(|version| *version = version.wrapping_add(1));
        Ok(answer)
    }
    /// The root endpoint authenticates bootstrap subscriptions. Their tasks and
    /// forwarding directories belong to the native scope, across Node handovers.
    pub async fn configure_root(&self, root:&Endpoint, value:&Value)->Result<Value,String> {
        use mesh_transport::global_registration::Registration;
        let _configure=self.configure_lock.lock().await;
        let scope=scope(value)?;
        let globals:Vec<Registration>=serde_json::from_value(value.get("globalRelays").cloned().unwrap_or(json!([]))).map_err(|e|e.to_string())?;
        if globals.len()>32 {return Err("too many global mesh relays".into());}
        let mut nodes=BTreeSet::new();
        for global in &globals {
            global.validate()?;
            if global.node==root.id() || !nodes.insert(global.node) {return Err("duplicate global mesh relay".into());}
            if value.get("peers").and_then(Value::as_array).is_some_and(|peers|peers.iter().any(|peer|
                serde_json::from_value::<GivenPeer>(peer.clone()).is_ok_and(|peer|peer.binding.endpoint==*global.node.as_bytes()))) {
                return Err("global relay conflicts with private mesh identity".into());
            }
        }
        let answer=self.configure(root.secret_key(),value).await?;
        let mut scopes=self.scopes.lock().await;
        let kept=scopes.get_mut(&scope).ok_or("mesh scope removed")?;
        kept.runtime.trusted_transit(globals.iter().map(|g|(*g.node.as_bytes(),g.generation)).collect()).await?;
        let obsolete:Vec<_>=kept.bootstraps.iter().filter(|(id,b)|!globals.iter().any(|g|g.node==**id&&g.generation==b.generation)).map(|(id,_)|*id).collect();
        for id in obsolete {
            kept.bootstraps.remove(&id); // Abort the subscription before removing its admitted neighbor.
            kept.public_peers.remove(&id);
        }
        kept.runtime.directory_proven(kept.private_peers.iter().cloned().chain(kept.public_peers.values().cloned()).collect(),kept.binding.clone()).await?;
        if !globals.is_empty() && kept.bootstrap_endpoint.is_none() {
            kept.bootstrap_endpoint=Some(Endpoint::builder(Minimal).secret_key(root.secret_key().clone())
                .relay_allowlist(kept.relays.clone()).relay_mode(if kept.relays.is_empty(){RelayMode::Disabled}else{RelayMode::custom(kept.relays.clone())})
                .bind().await.map_err(|e|e.to_string())?);
        }
        let opening=self.bootstrap_opening.clone();
        for global in globals {
            if let Some(bootstrap)=kept.bootstraps.get_mut(&global.node) {
                bootstrap.address=global.address;
                continue;
            }
            kept.bootstrap_version=kept.bootstrap_version.checked_add(1).ok_or("mesh bootstrap version exhausted")?;
            let version=kept.bootstrap_version;
            let weak=Arc::downgrade(&self.scopes);
            let root=kept.bootstrap_endpoint.as_ref().unwrap().clone();let changed=self.changed.subscribe();let opening=opening.clone();
            let address=global.address.clone();let generation=global.generation;let node=global.node;
            let ready=self.bootstrap_changes.clone();
            let task=tokio::spawn(async move { bootstrap_loop(weak,scope,version,root,global,changed,opening,ready).await; });
            kept.bootstraps.insert(node,Bootstrap {generation,address,version,_task:Task(task)});
        }
        Ok(answer)
    }
    /// The native connection, not a Node serving process, owns the attachment.
    pub async fn attach_leaf(&self, root:&Endpoint, connection:iroh::endpoint::Connection, value:&Value) -> Result<Value,String> {
        use mesh_transport::leaf::Attachment;
        let scope=scope(value)?;
        let descriptor:GivenPeer=serde_json::from_value(value.get("descriptor").cloned().ok_or("missing leaf descriptor")?).map_err(|e|e.to_string())?;
        if descriptor.binding.endpoint!=*connection.remote_id().as_bytes() || descriptor.binding.transit || connection.close_reason().is_some() {return Err("leaf does not match its authenticated connection".into());}
        let target:iroh::EndpointId=serde_json::from_value(value.get("target").cloned().ok_or("missing leaf target")?).map_err(|e|e.to_string())?;
        let expires=value.get("expiresUnixMs").and_then(safe_integer).ok_or("invalid leaf credential expiry")?;
        let mut scopes=self.scopes.lock().await;
        let kept=scopes.get_mut(&scope).ok_or("mesh scope removed")?;
        let previous:Vec<_>=kept.leaf_connections.iter().filter(|(_, (leaf, destination, _))| *leaf==descriptor.binding.endpoint && *destination==*target.as_bytes()).map(|(id,_)|*id).collect();
        if previous.is_empty() && kept.leaf_connections.len()>=mesh_transport::leaf::MAX_ATTACHMENTS {return Err("leaf connection capacity".into());}
        let mut peer=Peer::from_binding(&descriptor.binding,descriptor.address,scope,1).map_err(str::to_owned)?;
        restrict_peer(&mut peer,&kept.relays)?;
        let id=*SecretKey::generate().public().as_bytes();
        let attachment=Attachment::sign(root.secret_key(),kept.binding.clone(),descriptor.binding,*target.as_bytes(),id,expires).map_err(str::to_owned)?;
        kept.runtime.attach_leaf(attachment.clone(),Some(peer)).await?;
        for old in previous { kept.leaf_connections.remove(&old); kept.runtime.detach_leaf(old).await; }
        let leaf=attachment.leaf.endpoint;
        let weak=Arc::downgrade(&self.scopes);
        let task=tokio::spawn(async move {
            connection.closed().await;
            if let Some(scopes)=weak.upgrade() {
                let mut scopes=scopes.lock().await;
                if let Some(kept)=scopes.get_mut(&scope) {kept.runtime.detach_leaf(id).await;kept.leaf_connections.remove(&id);}
            }
        });
        kept.leaf_connections.insert(id,(leaf,*target.as_bytes(),Task(task)));
        serde_json::to_value(attachment).map_err(|e|e.to_string())
    }
    pub async fn use_leaf(&self, root:&Endpoint, value:&Value) -> Result<(),String> {
        let scope=scope(value)?;
        let mut given=value.get("attachment").cloned().ok_or("missing leaf attachment")?;
        let expires=given.get("expires_unix_ms").and_then(safe_integer).ok_or("invalid leaf credential expiry")?;
        given["expires_unix_ms"]=Value::from(expires);
        let attachment:mesh_transport::leaf::Attachment=serde_json::from_value(given).map_err(|e|e.to_string())?;
        if attachment.leaf.endpoint!=*root.id().as_bytes() {return Err("attachment belongs to another leaf".into());}
        let scopes=self.scopes.lock().await;
        let kept=scopes.get(&scope).ok_or("mesh scope removed")?;
        kept.runtime.attach_leaf(attachment,None).await
    }
    pub async fn detach_leaf(&self,value:&Value)->Result<(),String> {
        let scope=scope(value)?;
        let id:[u8;32]=serde_json::from_value(value.get("attachmentId").cloned().ok_or("missing leaf attachment id")?).map_err(|e|e.to_string())?;
        let mut scopes=self.scopes.lock().await;
        if let Some(kept)=scopes.get_mut(&scope) {kept.leaf_connections.remove(&id);kept.runtime.detach_leaf(id).await;}
        Ok(())
    }
    pub async fn address(&self, text: &str, peer: iroh::EndpointId) -> Result<iroh::TransportAddr, String> {
        let scope = scope(&json!({"scope":text}))?;
        let scopes = self.scopes.lock().await;
        let kept = scopes.get(&scope).ok_or("mesh scope is not configured")?;
        Ok(iroh::TransportAddr::Custom(kept.runtime.transport.address(*peer.as_bytes())))
    }
    pub async fn remove(&self, value: &Value) -> Result<(), String> {
        let scope = scope(value)?;
        let mut scopes = self.scopes.lock().await;
        self.hub.remove(scope);
        if let Some(mut kept) = scopes.remove(&scope) {
            kept.bootstraps.clear();
            if let Some(endpoint)=kept.bootstrap_endpoint {endpoint.close().await;}
            kept.runtime.close().await;
            self.changed.send_modify(|version| *version = version.wrapping_add(1));
        }
        Ok(())
    }
    pub async fn clear(&self) {
        self.subscriptions.lock().unwrap().clear();
        let mut scopes = self.scopes.lock().await;
        for (scope, mut kept) in std::mem::take(&mut *scopes) {
            self.hub.remove(scope);
            kept.bootstraps.clear();
            if let Some(endpoint)=kept.bootstrap_endpoint {endpoint.close().await;}
            kept.runtime.close().await;
        }
    }
}

type WeakScopes=std::sync::Weak<Mutex<BTreeMap<Scope,Kept>>>;
async fn bootstrap_own(scopes:&WeakScopes,scope:Scope,node:iroh::EndpointId,version:u64)->Result<mesh_transport::announcement::Descriptor,String> {
    let scopes=scopes.upgrade().ok_or("mesh scopes closed")?;
    let scopes=scopes.lock().await;
    let kept=scopes.get(&scope).ok_or("mesh scope removed")?;
    if kept.bootstraps.get(&node).map(|b|b.version)!=Some(version) {return Err("mesh bootstrap replaced".into());}
    Ok(mesh_transport::announcement::Descriptor {binding:kept.binding.clone(),address:bounded_address(kept.endpoint.addr())})
}
async fn bootstrap_peer(scopes:&WeakScopes,scope:Scope,node:iroh::EndpointId,version:u64,descriptor:mesh_transport::announcement::Descriptor)->Result<(),String> {
    let scopes=scopes.upgrade().ok_or("mesh scopes closed")?;
    let mut scopes=scopes.lock().await;
    let kept=scopes.get_mut(&scope).ok_or("mesh scope removed")?;
    let bootstrap=kept.bootstraps.get(&node).filter(|b|b.version==version).ok_or("mesh bootstrap replaced")?;
    if descriptor.binding.policy!=kept.binding.policy || descriptor.binding.endpoint!=*node.as_bytes() || descriptor.binding.generation!=bootstrap.generation {return Err("mesh public identity changed".into());}
    let mut peer=Peer::from_binding(&descriptor.binding,descriptor.address,scope,bootstrap.generation).map_err(str::to_owned)?;
    restrict_peer(&mut peer,&kept.relays)?;
    let mut next=kept.public_peers.clone();next.insert(node,peer);
    kept.runtime.directory_proven(kept.private_peers.iter().cloned().chain(next.values().cloned()).collect(),kept.binding.clone()).await?;
    kept.public_peers=next;
    Ok(())
}
async fn bootstrap_loop(scopes:WeakScopes,scope:Scope,version:u64,root:Endpoint,global:mesh_transport::global_registration::Registration,mut changed:tokio::sync::watch::Receiver<u64>,opening:Arc<tokio::sync::Semaphore>,ready:Arc<tokio::sync::Notify>) {
    use mesh_transport::public_service::Subscription;
    let mut backoff=1;
    loop {
        let result=async {
            changed.borrow_and_update();
            let own=bootstrap_own(&scopes,scope,global.node,version).await?;
            let (policy,address)={let scopes=scopes.upgrade().ok_or("mesh scopes closed")?;let scopes=scopes.lock().await;
                let kept=scopes.get(&scope).ok_or("mesh scope removed")?;
                let bootstrap=kept.bootstraps.get(&global.node).filter(|b|b.version==version).ok_or("mesh bootstrap replaced")?;
                (kept.policy.clone(),bootstrap.address.clone())};
            let permit=opening.acquire().await.map_err(|_|"mesh bootstrap queue closed")?;
            let subscription=Subscription::open(&root,address,&own,&policy,global.generation).await?;
            drop(permit);
            bootstrap_peer(&scopes,scope,global.node,version,subscription.initial().clone()).await?;
            ready.notify_waiters();
            backoff=1;
            let (own_tx,own_rx)=tokio::sync::watch::channel(own);
            let (updates,mut incoming)=tokio::sync::mpsc::channel(1);
            let run=subscription.run(own_rx,updates);
            let publish=async {
                let mut previous=serde_json::to_vec(&*own_tx.borrow()).map_err(|e|e.to_string())?;
                loop {
                    changed.changed().await.map_err(|_|"mesh scope updates ended")?;
                    let own=bootstrap_own(&scopes,scope,global.node,version).await?;
                    let bytes=serde_json::to_vec(&own).map_err(|e|e.to_string())?;
                    if bytes==previous {continue;} previous=bytes;
                    own_tx.send(own).map_err(|_|"mesh bootstrap publisher ended")?;
                }
                #[allow(unreachable_code)] Ok::<(),String>(())
            };
            let consume=async {
                while let Some(descriptor)=incoming.recv().await {bootstrap_peer(&scopes,scope,global.node,version,descriptor).await?;}
                Err::<(),String>("mesh bootstrap updates ended".into())
            };
            tokio::select! {r=run=>r,r=publish=>r,r=consume=>r}
        }.await;
        if let Err(error)=result {eprintln!("mesh public bootstrap unavailable: {error}");}
        if bootstrap_own(&scopes,scope,global.node,version).await.is_err() {return;}
        // Retry a failed control subscription; keep its last admitted data path.
        tokio::time::sleep(std::time::Duration::from_secs(backoff)).await;
        backoff=(backoff*2).min(60);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn javascript_credential_expiry_preserves_safe_integer_milliseconds() {
        let value=Value::from(1_794_930_000_000.0);
        assert_eq!(safe_integer(&value),Some(1_794_930_000_000));
        for value in [Value::from(1.5),Value::from(-1),Value::from(9_007_199_254_740_992u64),Value::Null] {
            assert_eq!(safe_integer(&value),None);
        }
    }
    #[tokio::test]
    #[ignore="real sockets: side test"]
    async fn native_global_bootstrap_forwards_and_removes_registered_neighbors() {
        use mesh_transport::public_service::{Scopes as PublicScopes,BOOTSTRAP_ALPN};
        tokio::time::timeout(std::time::Duration::from_secs(30),async {
            let scope=[93;32];let text=hex::encode(scope);let alpn=b"native-public-side/1";
            let key=SecretKey::from([94;32]);
            let public=Endpoint::builder(Minimal).secret_key(key.clone()).relay_mode(RelayMode::Disabled).alpns(vec![BOOTSTRAP_ALPN.to_vec()]).bind().await.unwrap();
            let service=PublicScopes::new(key,vec![],1).unwrap();
            let accept=public.clone();let service_task=service.clone();
            let serving=tokio::spawn(async move {
                let mut workers=tokio::task::JoinSet::new();
                for _ in 0..2 {
                    let conn=accept.accept().await.unwrap().await.unwrap();let service=service_task.clone();
                    workers.spawn(async move {let _=service.serve(conn).await;});
                }
                while workers.join_next().await.is_some() {}
            });
            let a=Scopes::default();let b=Scopes::default();
            let ea=Endpoint::builder(Minimal).secret_key(SecretKey::from([95;32])).relay_mode(RelayMode::Disabled).alpns(vec![alpn.to_vec()]).add_custom_transport(a.hub.clone()).bind().await.unwrap();
            let eb=Endpoint::builder(Minimal).secret_key(SecretKey::from([96;32])).relay_mode(RelayMode::Disabled).alpns(vec![alpn.to_vec()]).add_custom_transport(b.hub.clone()).bind().await.unwrap();
            let global=json!({"node":public.id(),"name":"side","generation":1,"revision":1,"address":public.addr()});
            let mut pa=a.configure_root(&ea,&json!({"scope":text,"peers":[],"globalRelays":[global]})).await.unwrap();
            let mut pb=b.configure_root(&eb,&json!({"scope":text,"peers":[],"globalRelays":[global]})).await.unwrap();
            // Each private directory knows its destination identity, with no direct underlay route.
            pa["address"]["addrs"]=json!([]);pb["address"]["addrs"]=json!([]);
            a.configure_root(&ea,&json!({"scope":text,"peers":[pb],"globalRelays":[global]})).await.unwrap();
            b.configure_root(&eb,&json!({"scope":text,"peers":[pa],"globalRelays":[global]})).await.unwrap();
            for scopes in [&a,&b] {
                loop {
                    let ready=scopes.bootstrap_changes.notified();tokio::pin!(ready);ready.as_mut().enable();
                    if scopes.scopes.lock().await[&scope].public_peers.contains_key(&public.id()) {break;}
                    ready.await;
                }
            }
            let server=eb.clone();let source=ea.id();
            let echo=tokio::spawn(async move {
                let conn=server.accept().await.unwrap().await.unwrap();assert_eq!(conn.remote_id(),source);
                let (mut send,mut recv)=conn.accept_bi().await.unwrap();let bytes=recv.read_to_end(65536).await.unwrap();
                send.write_all(&bytes).await.unwrap();send.finish().unwrap();conn.closed().await;
            });
            let target=eb.id();
            let addr=EndpointAddr::new(target).with_addrs([a.address(&text,target).await.unwrap()]);
            let conn=ea.connect(addr,alpn).await.unwrap();assert_eq!(conn.remote_id(),target);
            let (mut send,mut recv)=conn.open_bi().await.unwrap();let bytes=vec![93;65536];
            send.write_all(&bytes).await.unwrap();send.finish().unwrap();assert_eq!(recv.read_to_end(65536).await.unwrap(),bytes);
            assert_eq!(a.scopes.lock().await[&scope].runtime.routes(*target.as_bytes()).await[0].path,vec![*source.as_bytes(),*public.id().as_bytes(),*target.as_bytes()]);
            conn.close(0u32.into(),b"done");echo.await.unwrap();
            a.configure_root(&ea,&json!({"scope":text,"peers":[pb],"globalRelays":[]})).await.unwrap();
            let kept=a.scopes.lock().await;
            assert!(kept[&scope].public_peers.is_empty());assert!(kept[&scope].bootstraps.is_empty());
            assert!(kept[&scope].runtime.routes(*target.as_bytes()).await.is_empty());drop(kept);
            a.clear().await;b.clear().await;serving.await.unwrap();service.close().await;
            ea.close().await;eb.close().await;public.close().await;
        }).await.expect("native global bootstrap deadline");
    }
    #[test]
    fn neighbor_addresses_obey_the_scope_underlay_policy() {
        let allowed: RelayUrl = "https://allowed.example".parse().unwrap();
        let blocked: RelayUrl = "https://blocked.example".parse().unwrap();
        let key = SecretKey::from([30; 32]);
        let mut peer = Peer { binding: None, node: *key.public().as_bytes(), transit: true,
            address: EndpointAddr::new(key.public()).with_addrs([
                iroh::TransportAddr::Relay(allowed.clone()),
                iroh::TransportAddr::Relay(blocked.clone()),
                iroh::TransportAddr::Ip("127.0.0.1:1234".parse().unwrap()),
            ]) };
        restrict_peer(&mut peer, &[allowed.clone()]).unwrap();
        assert_eq!(peer.address.addrs.len(), 2);
        restrict_peer(&mut peer, &[]).unwrap();
        assert_eq!(peer.address.addrs.len(), 1);
        peer.address.addrs.insert(iroh::TransportAddr::Custom(mesh_transport::transport::address([1;32], mesh_transport::policy::TransitPolicy::empty().digest(), peer.node)));
        assert!(restrict_peer(&mut peer, &[]).is_err());
    }

    #[tokio::test]
    #[ignore = "real sockets: side test"]
    async fn native_scope_directory_connects_business_endpoints() {
        tokio::time::timeout(std::time::Duration::from_secs(30), async {
            let a = Scopes::default();
            let b = Scopes::default();
            let ka = SecretKey::from([31; 32]);
            let kb = SecretKey::from([32; 32]);
            let alpn = b"shell-mesh-side/1";
            let ea = Endpoint::builder(Minimal)
                .secret_key(ka.clone())
                .alpns(vec![alpn.to_vec()])
                .clear_ip_transports()
                .clear_relay_transports()
                .add_custom_transport(a.hub.clone())
                .path_selector(Arc::new(mesh_transport::selection::Selector::new(a.hub.clone())))
                .bind()
                .await
                .unwrap();
            let eb = Endpoint::builder(Minimal)
                .secret_key(kb.clone())
                .alpns(vec![alpn.to_vec()])
                .clear_ip_transports()
                .clear_relay_transports()
                .add_custom_transport(b.hub.clone())
                .path_selector(Arc::new(mesh_transport::selection::Selector::new(b.hub.clone())))
                .bind()
                .await
                .unwrap();
            let (writer, reader) = tokio::io::duplex(64 * 1024);
            let writer = Arc::new(Mutex::new(writer));
            let mut events = tokio::io::BufReader::new(reader);
            a.subscribe(17, writer).unwrap();
            let mut line = String::new();
            tokio::io::AsyncBufReadExt::read_line(&mut events, &mut line).await.unwrap();
            assert_eq!(serde_json::from_str::<Value>(&line).unwrap()["scopes"], json!([]));
            let scope = [9; 32];
            let text = hex::encode(scope);
            let pa = a
                .configure(&ka, &json!({"scope":text,"peers":[]}))
                .await
                .unwrap();
            loop {
                line.clear();
                tokio::io::AsyncBufReadExt::read_line(&mut events, &mut line).await.unwrap();
                let event: Value = serde_json::from_str(&line).unwrap();
                if event["scopes"].as_array().is_some_and(|scopes| !scopes.is_empty()) {
                    assert_eq!(event["scopes"][0]["scope"], text);
                    assert_eq!(event["scopes"][0]["descriptor"]["binding"], pa["binding"]);
                    break;
                }
            }
            let pb = b
                .configure(&kb, &json!({"scope":text,"peers":[]}))
                .await
                .unwrap();
            a.configure(&ka, &json!({"scope":text,"peers":[pa,pb]}))
                .await
                .unwrap();
            b.configure(&kb, &json!({"scope":text,"peers":[pa,pb]}))
                .await
                .unwrap();
            let server = eb.clone();
            let expected = ea.id();
            let task = tokio::spawn(async move {
                let conn = server.accept().await.unwrap().await.unwrap();
                assert_eq!(conn.remote_id(), expected);
                let (mut send, mut recv) = conn.accept_bi().await.unwrap();
                let mut bytes = [0; 6];
                recv.read_exact(&mut bytes).await.unwrap();
                assert_eq!(&bytes, b"native");
                send.write_all(&bytes).await.unwrap();
                send.finish().unwrap();
                conn.closed().await;
            });
            let addr = EndpointAddr::new(eb.id()).with_addrs([iroh::TransportAddr::Custom(
                mesh_transport::transport::address(scope, mesh_transport::policy::TransitPolicy::empty().digest(), *eb.id().as_bytes()),
            )]);
            let conn = ea.connect(addr, alpn).await.unwrap();
            assert_eq!(conn.remote_id(), eb.id());
            let (mut send, mut recv) = conn.open_bi().await.unwrap();
            send.write_all(b"native").await.unwrap();
            send.finish().unwrap();
            assert_eq!(recv.read_to_end(6).await.unwrap(), b"native");
            conn.close(0u32.into(), b"done");
            task.await.unwrap();
            a.remove(&json!({"scope":text})).await.unwrap();
            loop {
                line.clear();
                tokio::io::AsyncBufReadExt::read_line(&mut events, &mut line).await.unwrap();
                if serde_json::from_str::<Value>(&line).unwrap()["scopes"] == json!([]) { break; }
            }
            a.unsubscribe(17);
            assert!(a.subscriptions.lock().unwrap().is_empty());
            b.clear().await;
            ea.close().await;
            eb.close().await;
        })
        .await
        .expect("native scope side test deadline");
    }
}
