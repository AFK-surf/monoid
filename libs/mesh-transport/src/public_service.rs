//! A global relay exposes only a root-key bootstrap protocol. Each request joins
//! one opaque scope with the caller's own descriptor, never its member roster.
//! The resulting neighbor endpoint carries packets independently of cloud APIs.
use crate::{announcement::{Descriptor, bounded_address}, identity::{Binding,neighbor_secret}, routing::{Node,Scope}, runtime::{Runtime,Peer,ALPN}, policy::TransitPolicy};
use iroh::{Endpoint,EndpointId,RelayMode,RelayUrl,SecretKey,Watcher,endpoint::{Connection,presets::Minimal}};
use std::{collections::BTreeMap,sync::Arc,time::Duration};
use tokio::{sync::Mutex,time::timeout};
mod backbone;

pub const BOOTSTRAP_ALPN: &[u8] = b"mesh/public/1";
const LIMIT: usize = 16 * 1024;
type Lane = (Scope,[u8;32]);
#[derive(serde::Serialize,serde::Deserialize)]
struct Join {descriptor:Descriptor,policy:TransitPolicy}
const DEADLINE: Duration = Duration::from_secs(10);
struct ScopeState {
    incarnation:u64,
    topology:Arc<tokio::sync::Notify>,
    endpoint: Endpoint,
    runtime: Runtime,
    own: Binding,
    policy: TransitPolicy,
    allowed: Vec<RelayUrl>,
    bootstrap:Option<Endpoint>,
    peers: BTreeMap<Node,(Descriptor,u64)>,
    leases:BTreeMap<Node,Connection>,
    outgoing:BTreeMap<EndpointId,backbone::Link>,
    remote:BTreeMap<Node,Descriptor>,
}
struct State { scopes: BTreeMap<Lane,ScopeState>, next: u64, globals:BTreeMap<Node,u64>, history:std::collections::BTreeSet<Node> }
pub struct Scopes {
    key: SecretKey,
    generation:u64,
    relays: Vec<RelayUrl>,
    state: Mutex<State>,
    connections:tokio::sync::Semaphore,
    backbone:tokio::sync::watch::Sender<Option<backbone::Config>>,
    opening:Arc<tokio::sync::Semaphore>,
}
impl ScopeState {
    async fn close(mut self) {
        self.outgoing.clear();
        for (_,conn) in std::mem::take(&mut self.leases) {conn.close(0u32.into(),b"public scope ended");}
        self.endpoint.close().await;
        if let Some(root)=self.bootstrap.take() {root.close().await;}
        self.runtime.close().await;
    }
}
impl Scopes {
    pub fn new(key: SecretKey, relays: Vec<RelayUrl>, generation:u64) -> Result<Arc<Self>,String> {
        if generation==0 || generation>9_007_199_254_740_991 {return Err("invalid global relay generation".into());}
        if relays.len()>32 { return Err("too many public underlay relays".into()); }
        Ok(Arc::new(Self {key,generation,relays,connections:tokio::sync::Semaphore::new(64),state:Mutex::new(State {scopes:BTreeMap::new(),next:0,globals:BTreeMap::new(),history:std::collections::BTreeSet::new()}),
            backbone:tokio::sync::watch::channel(None).0,opening:Arc::new(tokio::sync::Semaphore::new(4))}))
    }
    pub async fn close(&self) {
        let scopes=std::mem::take(&mut self.state.lock().await.scopes);
        for (_,scope) in scopes {scope.close().await;}
    }
    fn peer(&self, descriptor: &Descriptor, authenticated: EndpointId, policy: &TransitPolicy) -> Result<Peer,String> {
        if descriptor.binding.endpoint != *authenticated.as_bytes() { return Err("bootstrap caller identity mismatch".into()); }
        if descriptor.binding.policy != policy.digest() {return Err("public transit lane mismatch".into());}
        if descriptor.address.addrs.len()>8 { return Err("too many bootstrap addresses".into()); }
        let mut peer=Peer::from_binding(&descriptor.binding,descriptor.address.clone(),descriptor.binding.scope,1).map_err(str::to_owned)?;
        // Every scope uses the operator's underlay policy. No recursive overlay.
        if peer.address.addrs.iter().any(|a|matches!(a,iroh::TransportAddr::Custom(_))) { return Err("recursive public underlay".into()); }
        peer.address.addrs.retain(|a| match a {
            iroh::TransportAddr::Ip(_) => true,
            iroh::TransportAddr::Relay(url) => self.relays.contains(url) && policy.relay_urls.contains(url),
            _ => false,
        });
        Ok(peer)
    }
    async fn install<'a>(&self, kept:&mut ScopeState, descriptors:impl Iterator<Item=&'a Descriptor>)->Result<(),String> {
        let mut peers=Vec::new();
        for descriptor in descriptors {
            let peer=self.peer(descriptor,EndpointId::from_bytes(&descriptor.binding.endpoint).map_err(|e|e.to_string())?,&kept.policy)?;
            peers.push(peer);
        }
        kept.runtime.directory_proven(peers,kept.own.clone()).await
    }
    async fn register(self:&Arc<Self>, descriptor: Descriptor, policy: TransitPolicy, authenticated: EndpointId, lease: Option<u64>, connection:Option<Connection>) -> Result<(u64,Endpoint,Binding),String> {
        policy.validate()?;
        if !policy.admits(self.key.public(),self.generation) {return Err("public relay not approved by transit policy".into());}
        self.peer(&descriptor,authenticated,&policy)?;
        let scope=descriptor.binding.scope;
        let lane=(scope,policy.digest());
        if descriptor.binding.neighbor == *neighbor_secret(&self.key,scope,lane.1).public().as_bytes() {
            return Err("public neighbor uses the relay identity".into());
        }
        let node=descriptor.binding.endpoint;
        if node==*self.key.public().as_bytes() { return Err("public relay cannot join itself".into()); }
        let mut state=self.state.lock().await;
        if policy.globals.iter().any(|g|state.history.contains(g.node.as_bytes())&&state.globals.get(g.node.as_bytes())!=Some(&g.generation)) {
            return Err("transit policy names a removed global generation".into());
        }
        if state.history.contains(&node) && (state.globals.get(&node)!=Some(&descriptor.binding.generation)||!policy.admits(authenticated,descriptor.binding.generation)) {return Err("public relay registration removed or replaced".into());}
        if !state.scopes.contains_key(&lane) {
            if state.scopes.len()>=32 { return Err("public scope capacity".into()); }
            let allowed=policy.underlay(&self.relays);
            let endpoint=Endpoint::builder(Minimal).secret_key(neighbor_secret(&self.key,scope,lane.1)).alpns(vec![ALPN.to_vec()])
                .relay_allowlist(allowed.clone()).relay_mode(if allowed.is_empty(){RelayMode::Disabled}else{RelayMode::custom(allowed.clone())})
                .bind().await.map_err(|e|e.to_string())?;
            let own=Binding::sign(&self.key,scope,lane.1,self.generation,true);
            let runtime=Runtime::start_proven(endpoint.clone(),own.clone(),vec![],true)?;
            state.next=state.next.checked_add(1).ok_or("public scope sequence exhausted")?;
            let incarnation=state.next;
            let activity=runtime.activity();
            let topology=Arc::new(tokio::sync::Notify::new());
            state.scopes.insert(lane,ScopeState {incarnation,topology:topology.clone(),endpoint,runtime,own,policy:policy.clone(),allowed,bootstrap:None,peers:BTreeMap::new(),leases:BTreeMap::new(),outgoing:BTreeMap::new(),remote:BTreeMap::new()});
            backbone::follow(Arc::downgrade(self),lane,incarnation,activity,self.backbone.subscribe(),topology);
        }
        let id=if let Some(lease)=lease {lease} else {
            state.next=state.next.checked_add(1).ok_or("public lease sequence exhausted")?;state.next
        };
        let kept=state.scopes.get_mut(&lane).unwrap();
        if lease.is_some() && kept.peers.get(&node).map(|p|p.1)!=Some(id) { return Err("public bootstrap lease replaced".into()); }
        if !backbone::has_room(kept,node) { return Err("public neighbor capacity".into()); }
        if let Some((old,_))=kept.peers.get(&node) {
            if descriptor.binding.generation < old.binding.generation { return Err("stale public bootstrap identity".into()); }
        }
        let mut next=kept.peers.clone();
        next.insert(node,(descriptor,id));
        let mut descriptors=kept.remote.clone();descriptors.extend(next.iter().map(|(n,(d,_))|(*n,d.clone())));
        self.install(kept,descriptors.values()).await?;
        if let Some(conn)=connection {
            if let Some(old)=kept.leases.insert(node,conn) {old.close(0u32.into(),b"public bootstrap replaced");}
        }
        kept.peers=next;
        kept.topology.notify_one();
        Ok((id,kept.endpoint.clone(),kept.own.clone()))
    }
    async fn leave(&self, lane: Lane, node: Node, lease: u64) {
        let mut state=self.state.lock().await;
        let Some(kept)=state.scopes.get_mut(&lane) else {return};
        if kept.peers.get(&node).map(|p|p.1)!=Some(lease) {return;}
        kept.peers.remove(&node);
        kept.leases.remove(&node);
        kept.topology.notify_one();
        if kept.peers.is_empty() && kept.outgoing.is_empty() {
            let gone=state.scopes.remove(&lane).unwrap();
            drop(state);
            gone.close().await;
        } else {
            let mut descriptors=kept.remote.clone();descriptors.extend(kept.peers.iter().map(|(n,(d,_))|(*n,d.clone())));
            let _=self.install(kept,descriptors.values()).await;
        }
    }
    pub async fn serve(self: Arc<Self>, conn: Connection) -> Result<(),String> {
        let _connection=CloseConnection(Some(conn.clone()));
        let _permit=self.connections.try_acquire().map_err(|_|"public bootstrap connection capacity")?;
        let authenticated=conn.remote_id();
        let (mut send,mut recv)=timeout(DEADLINE,conn.accept_bi()).await.map_err(|_|"public bootstrap accept timeout")?.map_err(|e|e.to_string())?;
        let first:Join=timeout(DEADLINE,read(&mut recv)).await.map_err(|_|"public bootstrap request timeout")??;
        let scope=first.descriptor.binding.scope;let node=first.descriptor.binding.endpoint;
        let lane=(scope,first.descriptor.binding.policy);
        let policy=first.policy;
        let (lease,endpoint,binding)=self.register(first.descriptor,policy.clone(),authenticated,None,Some(conn.clone())).await?;
        let mut cleanup=Lease { scopes:Arc::downgrade(&self),lane,node,lease,armed:true };
        let readers=self.clone();
        // Both directions run to completion; selecting per-frame would cancel a
        // partially read length or body when an address changes.
        let reader=async move {
            let mut window=tokio::time::Instant::now();let mut updates=0;
            loop {
                let descriptor:Descriptor=read(&mut recv).await?;
                if descriptor.binding.scope!=scope || descriptor.binding.policy!=lane.1 || descriptor.binding.endpoint!=node {return Err("bootstrap scope changed".into());}
                if window.elapsed()>=Duration::from_secs(1) {window=tokio::time::Instant::now();updates=0;}
                updates+=1;if updates>16 {return Err("public address update rate exceeded".into());}
                readers.register(descriptor,policy.clone(),authenticated,Some(lease),None).await?;
            }
            #[allow(unreachable_code)] Ok::<(),String>(())
        };
        let writer=async move {
            let mut addresses=endpoint.watch_addr();
            write(&mut send,&Descriptor {binding:binding.clone(),address:bounded_address(addresses.get())}).await?;
            loop {
                let address=bounded_address(addresses.updated().await.map_err(|e|e.to_string())?);
                write(&mut send,&Descriptor {binding:binding.clone(),address}).await?;
            }
            #[allow(unreachable_code)] Ok::<(),String>(())
        };
        let result=tokio::select! {result=reader=>result,result=writer=>result};
        self.leave(lane,node,lease).await;
        cleanup.armed=false;
        conn.close(0u32.into(),b"public bootstrap ended");
        result
    }
}
async fn read<T:serde::de::DeserializeOwned>(recv: &mut iroh::endpoint::RecvStream) -> Result<T,String> {
    let mut len=[0;4];recv.read_exact(&mut len).await.map_err(|e|e.to_string())?;
    let size=u32::from_be_bytes(len) as usize;
    if size==0||size>LIMIT{return Err("public bootstrap frame too large".into());}
    let mut bytes=vec![0;size];
    timeout(DEADLINE,recv.read_exact(&mut bytes)).await.map_err(|_|"public bootstrap body timeout")?.map_err(|e|e.to_string())?;
    serde_json::from_slice(&bytes).map_err(|e|e.to_string())
}
async fn write<T:serde::Serialize>(send: &mut iroh::endpoint::SendStream, descriptor: &T) -> Result<(),String> {
    let bytes=serde_json::to_vec(descriptor).map_err(|e|e.to_string())?;
    if bytes.len()>LIMIT{return Err("public bootstrap frame too large".into());}
    timeout(DEADLINE,async {
        send.write_all(&(bytes.len()as u32).to_be_bytes()).await.map_err(|e|e.to_string())?;
        send.write_all(&bytes).await.map_err(|e|e.to_string())
    }).await.map_err(|_|"public bootstrap write timeout")?
}

// Cancellation also releases a lease. At most one cleanup belongs to each
// admitted bootstrap connection; the service runner bounds these connections.
struct Lease { scopes:std::sync::Weak<Scopes>,lane:Lane,node:Node,lease:u64,armed:bool }
struct CloseConnection(Option<Connection>);
impl Drop for CloseConnection {
    fn drop(&mut self) {
        if let Some(conn)=self.0.take() {conn.close(0u32.into(),b"public bootstrap ended");}
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        if self.armed {
            if let Some(scopes)=self.scopes.upgrade() {
                let (lane,node,lease)=(self.lane,self.node,self.lease);
                tokio::spawn(async move {scopes.leave(lane,node,lease).await;});
            }
        }
    }
}

/// One authenticated bootstrap subscription, owned by the native forwarding
/// lifecycle. Address pushes are independent of a Node process or cloud stream.
pub struct Subscription {
    conn:Connection,
    send:iroh::endpoint::SendStream,
    recv:iroh::endpoint::RecvStream,
    root:EndpointId,
    local:EndpointId,
    scope:Scope,
    initial:Descriptor,
    policy:[u8;32],
    generation:u64,
}
impl Subscription {
    pub async fn open(endpoint:&Endpoint, address:iroh::EndpointAddr, own:&Descriptor, policy:&TransitPolicy, generation:u64) -> Result<Self,String> {
        if own.binding.endpoint!=*endpoint.id().as_bytes() {return Err("bootstrap must use the endpoint root identity".into());}
        policy.validate()?;
        if own.binding.policy!=policy.digest() || !policy.admits(address.id,generation) {return Err("bootstrap transit policy mismatch".into());}
        own.binding.verify(own.binding.scope,1).map_err(str::to_owned)?;
        let root=address.id; let scope=own.binding.scope;
        timeout(DEADLINE,async {
            let conn=endpoint.connect(address,BOOTSTRAP_ALPN).await.map_err(|e|e.to_string())?;
            let mut cleanup=CloseConnection(Some(conn.clone()));
            let (mut send,mut recv)=conn.open_bi().await.map_err(|e|e.to_string())?;
            write(&mut send,&Join {descriptor:own.clone(),policy:policy.clone()}).await?;
            let initial=read(&mut recv).await?;
            check_response(&initial,root,scope,policy.digest(),generation)?;
            cleanup.0=None;
            Ok(Self {conn,send,recv,root,local:endpoint.id(),scope,initial,policy:policy.digest(),generation})
        }).await.map_err(|_|"public bootstrap open timeout".to_owned())?
    }
    pub fn initial(&self)->&Descriptor {&self.initial}
    pub async fn run(mut self, mut own:tokio::sync::watch::Receiver<Descriptor>, updates:tokio::sync::mpsc::Sender<Descriptor>)->Result<(),String> {
        let root=self.root;let scope=self.scope;
        let read_loop=async {
            loop {
                let descriptor=read(&mut self.recv).await?;
                check_response(&descriptor,root,scope,self.policy,self.generation)?;
                timeout(DEADLINE,updates.send(descriptor)).await.map_err(|_|"public bootstrap consumer stalled")?.map_err(|_|"public bootstrap consumer closed")?;
            }
            #[allow(unreachable_code)] Ok::<(),String>(())
        };
        let write_loop=async {
            loop {
                own.changed().await.map_err(|_|"public bootstrap publisher closed")?;
                let descriptor=own.borrow_and_update().clone();
                if descriptor.binding.scope!=scope || descriptor.binding.policy!=self.policy || descriptor.binding.endpoint!=*self.local.as_bytes() {return Err("public bootstrap publisher identity changed".into());}
                write(&mut self.send,&descriptor).await?;
            }
            #[allow(unreachable_code)] Ok::<(),String>(())
        };
        tokio::select! {result=read_loop=>result,result=write_loop=>result}
    }
}
impl Drop for Subscription {fn drop(&mut self){self.conn.close(0u32.into(),b"public bootstrap subscription ended");}}
fn check_response(descriptor:&Descriptor, root:EndpointId, scope:Scope, policy:[u8;32], generation:u64)->Result<(),String> {
    if descriptor.binding.policy!=policy || descriptor.binding.endpoint!=*root.as_bytes() || descriptor.binding.generation!=generation || !descriptor.binding.transit || descriptor.address.addrs.len()>8 {
        return Err("invalid public relay descriptor".into());
    }
    Peer::from_binding(&descriptor.binding,descriptor.address.clone(),scope,1).map_err(str::to_owned)?;
    if descriptor.address.addrs.iter().any(|a|matches!(a,iroh::TransportAddr::Custom(_))){return Err("recursive public bootstrap address".into());}
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bootstrap_response_binds_operator_generation_and_scope() {
        let key=SecretKey::from([81;32]);let scope=[85;32];let policy=TransitPolicy::empty().digest();
        let binding=Binding::sign(&key,scope,policy,3,true);
        let descriptor=Descriptor {address:iroh::EndpointAddr::new(neighbor_secret(&key,scope,policy).public()),binding};
        check_response(&descriptor,key.public(),scope,policy,3).unwrap();
        assert!(check_response(&descriptor,key.public(),scope,policy,2).is_err());
        assert!(check_response(&descriptor,key.public(),[86;32],policy,3).is_err());
        assert!(check_response(&descriptor,SecretKey::from([82;32]).public(),scope,policy,3).is_err());
    }
}
