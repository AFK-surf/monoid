//! Side-run node: isolated namespace by default, optional external-address JSON.
//! Test keys only. External mode never uses the local UDP fault bridge.
use iroh::{
    Endpoint, EndpointAddr, RelayMode, RelayUrl, SecretKey, TransportAddr, endpoint::presets::Minimal,
};
use futures_lite::StreamExt;
use mesh_transport::{runtime::{ALPN, Peer, Runtime}, identity::{Binding, neighbor_secret}};
use std::{
    net::{Ipv4Addr, SocketAddr},
    time::{Duration, Instant},
};
const APP: &[u8] = b"mesh-netlab/1";
fn key(i: u8) -> SecretKey {
    SecretKey::from([i + 1; 32])
}
fn lower_key(i: u8, policy: [u8; 32]) -> SecretKey {
    neighbor_secret(&key(i), [99; 32], policy)
}
fn address(i: u8) -> SocketAddr {
    (Ipv4Addr::new(127, 0, 0, i + 10), 24000 + i as u16).into()
}
#[derive(Clone, Copy, Debug, PartialEq, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
enum Mode { Mesh, Direct, Relay }
#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct External {
    mode: Mode,
    relay_urls: Vec<RelayUrl>,
    nodes: Vec<ExternalNode>,
}
#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExternalNode {
    lower_bind: SocketAddr,
    inner_bind: SocketAddr,
    #[serde(default)] lower_ips: Vec<SocketAddr>,
    #[serde(default)] inner_ips: Vec<SocketAddr>,
    neighbors: Vec<u8>,
}
impl External {
    fn read() -> Option<Self> {
        let file = std::env::var_os("MESH_NETLAB_CONFIG")?;
        let config: Self = serde_json::from_slice(&std::fs::read(file).unwrap()).unwrap();
        assert_eq!(config.nodes.len(), 4, "external fixture has four nodes");
        assert_eq!(config.relay_urls.len(), 1, "external fixture uses one explicitly permitted relay");
        for (i, node) in config.nodes.iter().enumerate() {
            assert!(!node.lower_bind.ip().is_loopback() && !node.inner_bind.ip().is_loopback(),
                "external mode cannot bind loopback");
            assert!(node.lower_ips.len() <= 8 && node.inner_ips.len() <= 8);
            assert!(node.neighbors.len() <= 3 && node.neighbors.iter().all(|j| *j < 4 && usize::from(*j) != i));
            assert!(node.lower_ips.iter().chain(&node.inner_ips).all(|addr| !addr.ip().is_loopback()));
        }
        Some(config)
    }
    fn peer(&self, local: u8, peer: u8, policy: [u8; 32]) -> EndpointAddr {
        let mut addr = EndpointAddr::new(lower_key(peer, policy).public());
        if self.nodes[usize::from(local)].neighbors.contains(&peer) {
            for ip in &self.nodes[usize::from(peer)].lower_ips { addr = addr.with_ip_addr(*ip); }
            addr = addr.with_relay_url(self.relay_urls[0].clone());
        }
        addr
    }
    fn inner_peer(&self, peer: u8) -> EndpointAddr {
        let mut addr = EndpointAddr::new(key(peer).public()).with_relay_url(self.relay_urls[0].clone());
        if self.mode == Mode::Direct {
            for ip in &self.nodes[usize::from(peer)].inner_ips { addr = addr.with_ip_addr(*ip); }
        }
        addr
    }
}
type OuterConnections = std::sync::Arc<std::sync::Mutex<Vec<iroh::endpoint::WeakConnectionHandle>>>;
#[derive(Debug)]
struct OuterObserver { node: u8, policy: [u8; 32], connections: OuterConnections }
impl iroh::endpoint::EndpointHooks for OuterObserver {
    async fn after_handshake(&self, conn: &iroh::endpoint::Connection) -> iroh::endpoint::AfterHandshakeOutcome {
        let node = self.node;
        if std::env::var_os("MESH_TRACE_ROUTING").is_some() {
            let mut kept = self.connections.lock().unwrap();
            kept.retain(|weak| weak.upgrade().is_some());
            assert!(kept.len() < 8, "four-node diagnostic connection bound");
            kept.push(conn.weak_handle());
        }
        let remote = conn.remote_id();
        let peer = (0..4).find(|j| lower_key(*j, self.policy).public() == remote)
            .expect("external outer peer belongs to fixture");
        let mut events = conn.path_events();
        for path in conn.paths().iter().filter(|p| p.is_selected()) {
            println!("OUTER_SELECTED {}", serde_json::json!({"node":node,"peer":peer,"remoteId":remote.to_string(),
                "id":format!("{:?}",path.id()),"local":format!("{:?}",path.local_addr()),
                "remote":format!("{:?}",path.remote_addr())}));
        }
        // PathEventStream owns no strong connection handle and ends when this connection closes.
        tokio::spawn(async move {
            while let Some(event) = events.next().await {
                match event {
                    iroh::endpoint::PathEvent::Selected { id, local_addr, remote_addr, .. } => {
                        println!("OUTER_SELECTED {}", serde_json::json!({"node":node,"peer":peer,"remoteId":remote.to_string(),
                            "id":format!("{id:?}"),"local":format!("{local_addr:?}"),"remote":format!("{remote_addr:?}")}));
                    }
                    iroh::endpoint::PathEvent::Lagged { missed, .. } => panic!("outer path events lost: {missed}"),
                    _ => {}
                }
            }
            println!("OUTER_CLOSED {}", serde_json::json!({"node":node,"peer":peer,"remoteId":remote.to_string()}));
        });
        iroh::endpoint::AfterHandshakeOutcome::accept()
    }
}
async fn log_paths(sequence: usize, conn: &iroh::endpoint::Connection, runtime: &Runtime, target: u8, policy: [u8; 32], details: bool, outer: &OuterConnections) {
    for route in runtime.routes(*key(target).public().as_bytes()).await {
        let path: Vec<_> = route.path.iter().map(|n| (0..4).find(|j| key(*j).public().as_bytes() == n).unwrap()).collect();
        let digest: String = mesh_transport::routing::circuit([99;32], policy, &route.path).iter().map(|b| format!("{b:02x}")).collect();
        println!("ROUTE {sequence} {digest} {path:?}");
    }
    if std::env::var_os("MESH_TRACE_ROUTING").is_some() {
        outer.lock().unwrap().retain(|weak| {
            let Some(connection) = weak.upgrade() else { return false };
            println!("OUTER_STATS {sequence} {} {:?}", connection.remote_id(), connection.stats());
            for path in connection.paths().iter() {
                println!("OUTER_PATH_STATS {sequence} {} {:?} {:?} {:?}", connection.remote_id(), path.id(), path.remote_addr(), path.stats());
            }
            true
        });
    }
    for path in conn.paths().iter() {
        if std::env::var_os("MESH_TRACE_ROUTING").is_some() {
            println!("PATH_STATS {sequence} {:?} {:?}", path.id(), path.stats());
        }
        let digest = path_name(path.remote_addr());
        println!("QUIC {sequence} {} {:?} {digest} {}", path.is_selected(), path.id(), path.rtt().as_millis());
        if details {
            println!("PATH_DETAIL {}", serde_json::json!({"sequence":sequence,"selected":path.is_selected(),
                "id":format!("{:?}",path.id()),"remote":format!("{:?}",path.remote_addr()),
                "local":format!("{:?}",path.local_addr()),"rttMs":path.rtt().as_millis()}));
        }
    }
}
fn path_name(addr: &TransportAddr) -> String {
    match addr {
        TransportAddr::Custom(addr) => addr.data()[64..].iter().map(|b| format!("{b:02x}")).collect(),
        TransportAddr::Ip(_) => "native".to_owned(),
        _ => "relay".to_owned(),
    }
}
fn watch_paths(conn: &iroh::endpoint::Connection, details: bool) -> tokio::task::JoinHandle<()> {
    // Subscribe before the first snapshot: no switch between snapshots is lost.
    let mut events = conn.path_events();
    for path in conn.paths().iter().filter(|p| p.is_selected()) {
        println!("SELECTED {}", path_name(path.remote_addr()));
        if details { println!("SELECTED_DETAIL {}", serde_json::json!({"sinceWatchMs":0,
            "id":format!("{:?}",path.id()),"remote":format!("{:?}",path.remote_addr()),
            "local":format!("{:?}",path.local_addr())})); }
    }
    tokio::spawn(async move {
        let began = Instant::now();
        while let Some(event) = events.next().await {
            match event {
                iroh::endpoint::PathEvent::Selected { id, remote_addr, local_addr, .. } => {
                    println!("SELECTED {}", path_name(&remote_addr));
                    if details { println!("SELECTED_DETAIL {}", serde_json::json!({
                        "sinceWatchMs":began.elapsed().as_millis(),"id":format!("{id:?}"),
                        "remote":format!("{remote_addr:?}"),"local":format!("{local_addr:?}")})); }
                }
                iroh::endpoint::PathEvent::Lagged { missed, .. } => panic!("path events lost: {missed}"),
                _ => {}
            }
        }
    })
}
#[tokio::main]
async fn main() {
    let i: u8 = std::env::args()
        .nth(1)
        .expect("node index")
        .parse()
        .unwrap();
    assert!(i < 4);
    let external = External::read();
    let policy = mesh_transport::policy::TransitPolicy::new(
        external.as_ref().map(|c| c.relay_urls.clone()).unwrap_or_default(), vec![]).unwrap().digest();
    let outer: OuterConnections = Default::default();
    let lower_builder = Endpoint::builder(Minimal)
        .secret_key(lower_key(i, policy))
        .clear_ip_transports()
        .bind_addr(external.as_ref().map(|c| c.nodes[usize::from(i)].lower_bind).unwrap_or_else(|| address(i)))
        .unwrap()
        .alpns(vec![ALPN.to_vec()]);
    let lower_builder = if external.is_some() || std::env::var_os("MESH_TRACE_ROUTING").is_some() {
        lower_builder.hooks(OuterObserver { node:i, policy, connections:outer.clone() })
    } else { lower_builder };
    let lower_builder = if let Some(config) = &external {
        lower_builder.relay_allowlist(config.relay_urls.clone()).relay_mode(RelayMode::custom(config.relay_urls.clone()))
    } else { lower_builder.relay_mode(RelayMode::Disabled) };
    let lower = lower_builder.bind().await.unwrap();
    if external.is_some() {
        tokio::time::timeout(Duration::from_secs(30), lower.online()).await.expect("permitted outer relay ready");
        println!("ENDPOINT {}", serde_json::json!({"node":i,"layer":"outer","id":lower.id().to_string(),
            "advertised":format!("{:?}",lower.addr())}));
    }
    let peers = (0..4)
        .map(|j| Peer { binding: Some(Binding::sign(&key(j), [99; 32], policy, 1, true)),
                transit: true,
            node: *key(j).public().as_bytes(),
            address: external.as_ref().map(|c| c.peer(i,j,policy))
                .unwrap_or_else(|| EndpointAddr::new(lower_key(j,policy).public()).with_ip_addr(address(j))),
        })
        .collect();
    let runtime = Runtime::start_proven(lower, Binding::sign(&key(i), [99; 32], policy, 1, true), peers, false).unwrap();
    let hub = std::sync::Arc::new(mesh_transport::hub::Hub::default());
    hub.insert([99;32], runtime.transport.clone()).unwrap();
    let native = external.as_ref().map(|c| c.mode == Mode::Direct)
        .unwrap_or_else(|| std::env::var("MESH_SCENARIO").unwrap_or_default().starts_with("native"));
    let mesh = external.as_ref().is_none_or(|c| c.mode == Mode::Mesh);
    let inner_builder = Endpoint::builder(Minimal)
        .secret_key(key(i))
        .alpns(vec![APP.to_vec()])
        .clear_ip_transports()
        .clear_relay_transports();
    let inner_builder = if mesh {
        inner_builder.path_selector(std::sync::Arc::new(mesh_transport::selection::Selector::new(hub.clone())))
            .add_custom_transport(hub)
    } else { inner_builder };
    let inner_builder = if let Some(config) = external.as_ref().filter(|c| c.mode != Mode::Mesh) {
        inner_builder.relay_allowlist(config.relay_urls.clone()).relay_mode(RelayMode::custom(config.relay_urls.clone()))
    } else { inner_builder };
    let inner_builder = if native {
        let addr = external.as_ref().map(|c| c.nodes[usize::from(i)].inner_bind).unwrap_or_else(|| {
            let mut addr = address(i); addr.set_port(addr.port()+1000); addr
        });
        inner_builder.bind_addr(addr).unwrap()
    } else { inner_builder };
    let inner = inner_builder.bind()
        .await
        .unwrap();
    if let Some(config) = &external {
        if config.mode != Mode::Mesh {
            tokio::time::timeout(Duration::from_secs(30), inner.online()).await.expect("permitted inner relay ready");
        }
        println!("ENDPOINT {}", serde_json::json!({"node":i,"layer":"inner","mode":format!("{:?}",config.mode),
            "id":inner.id().to_string(),"advertised":format!("{:?}",inner.addr())}));
    }
    println!("READY {i}");
    if i == 0 {
        tokio::time::timeout(Duration::from_secs(90), async {
            let mut addr = EndpointAddr::new(key(3).public()).with_addrs([TransportAddr::Custom(
                runtime.transport.address(*key(3).public().as_bytes()),
            )]);
            if let Some(config) = external.as_ref().filter(|c| c.mode != Mode::Mesh) {
                addr = config.inner_peer(3);
            } else if native { let mut ip = address(3); ip.set_port(ip.port()+1000); addr = addr.with_ip_addr(ip); }
            let connecting = Instant::now();
            let conn = inner.connect(addr, APP).await.unwrap();
            println!("CONNECTED {}", connecting.elapsed().as_millis());
            assert_eq!(conn.remote_id(), key(3).public());
            if external.is_some() { println!("INNER_IDENTITY {}", serde_json::json!({"node":i,"remoteId":conn.remote_id().to_string(),"expected":key(3).public().to_string(),"sameStream":true})); }
            let watcher = watch_paths(&conn, external.is_some());
            let (mut send, mut recv) = conn.open_bi().await.unwrap();
            let payload: Vec<u8> = (0..65536).map(|n| (n % 251) as u8).collect();
            for sequence in 0..35 {
                let start = Instant::now();
                send.write_all(&payload).await.unwrap();
                let mut reply = vec![0; payload.len()];
                recv.read_exact(&mut reply).await.unwrap();
                assert_eq!(reply, payload);
                let routes = runtime.routes(*key(3).public().as_bytes()).await;
                let path: Vec<_> = routes.first().map(|route| route.path.iter()
                    .map(|n| (0..4).find(|j| key(*j).public().as_bytes() == n).unwrap())
                    .collect()).unwrap_or_default();
                let elapsed = start.elapsed().as_millis();
                log_paths(sequence, &conn, &runtime, 3, policy, external.is_some(), &outer).await;
                println!("SAMPLE {sequence} {elapsed} {path:?}");
                // Side-run cadence: expose sustained quality changes to probes.
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
            println!("VERIFIED 35 {}", 35 * payload.len());
            send.finish().unwrap();
            conn.close(0u32.into(), b"done");
            watcher.abort();
            if let Err(error) = watcher.await { assert!(error.is_cancelled(), "{error}"); }
        })
        .await
        .expect("netlab deadline");
        inner.close().await;
        runtime.close().await;
    } else if i == 3 {
        let conn = inner.accept().await.unwrap().await.unwrap();
        assert_eq!(conn.remote_id(), key(0).public());
        if external.is_some() { println!("INNER_IDENTITY {}", serde_json::json!({"node":i,"remoteId":conn.remote_id().to_string(),"expected":key(0).public().to_string(),"sameStream":true})); }
        let watcher = watch_paths(&conn, external.is_some());
        let (mut send, mut recv) = conn.accept_bi().await.unwrap();
        for sequence in 0..35 {
            let mut bytes = vec![0; 65536];
            recv.read_exact(&mut bytes).await.unwrap();
            send.write_all(&bytes).await.unwrap();
            log_paths(sequence, &conn, &runtime, 0, policy, external.is_some(), &outer).await;
        }
        send.finish().unwrap();
        conn.closed().await;
        watcher.abort();
        if let Err(error) = watcher.await { assert!(error.is_cancelled(), "{error}"); }
        inner.close().await;
        runtime.close().await;
    } else {
        std::future::pending::<()>().await;
    }
}
