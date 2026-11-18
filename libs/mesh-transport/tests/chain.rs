//! Side tests use real sockets. Run with `cargo test --test chain -- --ignored`.
use iroh::{
    Endpoint, EndpointAddr, RelayMode, SecretKey, TransportAddr, endpoint::presets::Minimal,
};
use mesh_transport::{runtime::{ALPN, Peer, Runtime}, identity::{Binding, neighbor_secret}};
use std::time::{Duration, Instant};
use futures_lite::StreamExt;

const ECHO: &[u8] = b"mesh-side/echo/1";

#[tokio::test]
#[ignore = "real sockets: side test"]
async fn five_node_chain_keeps_stream_after_middle_link_failure() {
    chain(true, false).await;
}

#[tokio::test]
#[ignore = "real sockets: side test"]
async fn chain_discovers_neighbors_without_preconnecting() {
    chain(false, true).await;
}

fn scoped_peers(index: usize, peers: &[Peer], standby: bool) -> Vec<Peer> {
    peers
        .iter()
        .enumerate()
        .map(|(other, p)| {
            let edge = [(0, 1), (1, 2), (2, 3)]
                .into_iter()
                .chain(if standby {
                    vec![(0, 4), (4, 3)]
                } else {
                    vec![]
                })
                .any(|(a, b)| (a == index && b == other) || (b == index && a == other));
            Peer { binding: p.binding.clone(),
                transit: true,
                node: p.node,
                address: if edge {
                    p.address.clone()
                } else {
                    EndpointAddr::new(p.address.id)
                },
            }
        })
        .collect()
}

async fn chain(failover: bool, cold: bool) {
    tokio::time::timeout(Duration::from_secs(30), async {
        let mut lower = vec![];
        let mut secrets = vec![];
        for i in 0..if failover {5u8} else {4u8} {
            secrets.push(SecretKey::from([i+1;32]));
            lower.push(Endpoint::builder(Minimal).secret_key(neighbor_secret(secrets.last().unwrap(), [99;32], policy()))
                .relay_mode(RelayMode::Disabled).alpns(vec![ALPN.to_vec()]).bind().await.unwrap());
        }
        let peers: Vec<_> = lower.iter().zip(&secrets).map(|(ep,key)| Peer { binding: Some(Binding::sign(key,[99;32],policy(),1,true)),
                transit: true,
            node: *key.public().as_bytes(), address: ep.addr(),
        }).collect();
        let mut runtimes = vec![];
        let mut inner = vec![];
        for (index,(ep,secret)) in lower.into_iter().zip(secrets).enumerate() {
            let runtime = Runtime::start_proven(ep, Binding::sign(&secret,[99;32],policy(),1,true), scoped_peers(index,&peers,false), false).unwrap();
            let hub=std::sync::Arc::new(mesh_transport::hub::Hub::default());
            inner.push(Endpoint::builder(Minimal).secret_key(secret).alpns(vec![ECHO.to_vec()])
                .clear_ip_transports().clear_relay_transports()
                .path_selector(std::sync::Arc::new(mesh_transport::selection::Selector::new(hub.clone()))).add_custom_transport(hub.clone()).bind().await.unwrap());
            hub.insert([99;32],runtime.transport.clone()).unwrap();
            runtimes.push(runtime);
        }
        for i in 0..if cold {0} else {3} { runtimes[i].connect(*inner[i+1].id().as_bytes()).await.unwrap(); }
        let expected = inner[0].id(); let server = inner[3].clone();
        let (connection_tx, connection_rx) = tokio::sync::oneshot::channel();
        let echo = tokio::spawn(async move {
            let conn = server.accept().await.unwrap().await.unwrap();
            assert_eq!(conn.remote_id(), expected, "transit nodes must not replace the sender");
            connection_tx.send(conn.clone()).unwrap();
            let (mut send,mut recv) = conn.accept_bi().await.unwrap();
            for _ in 0..2 {
                let mut data = vec![0;128*1024];
                recv.read_exact(&mut data).await.unwrap();
                send.write_all(&data).await.unwrap();
            }
            send.finish().unwrap();
            conn.closed().await;
        });
        let addr = EndpointAddr::new(inner[3].id()).with_addrs([TransportAddr::Custom(
            runtimes[0].transport.address(*inner[3].id().as_bytes()))]);
        let conn = inner[0].connect(addr,ECHO).await.unwrap();
        assert_eq!(conn.remote_id(),inner[3].id());
        let receiver = connection_rx.await.unwrap();
        let (mut send,mut recv) = conn.open_bi().await.unwrap();
        let payload: Vec<u8> = (0..128*1024).map(|i| (i%251) as u8).collect();
        send.write_all(&payload).await.unwrap();
        let mut reply = vec![0;payload.len()];
        recv.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply,payload);
        let routes = runtimes[0].routes(*inner[3].id().as_bytes()).await;
        assert_eq!(routes[0].path,inner[..4].iter().map(|e| *e.id().as_bytes()).collect::<Vec<_>>());
        let mut failure_started = None;
        let mut before_path = conn.paths().iter().find(|p| p.is_selected()).unwrap().id();
        let mut before_receiver = receiver.paths().iter().find(|p|p.is_selected()).unwrap().id();
        if failover {
            for (i,runtime) in runtimes.iter().enumerate() { runtime.directory_proven(scoped_peers(i,&peers,true), peers[i].binding.clone().unwrap()).await.unwrap(); }
            // Exercise simultaneous dialing, then break the middle link. No inner reconnect.
            let (a,b) = tokio::join!(runtimes[0].connect(*inner[4].id().as_bytes()),
                runtimes[4].connect(*inner[0].id().as_bytes()));
            a.unwrap(); b.unwrap();
            runtimes[4].connect(*inner[3].id().as_bytes()).await.unwrap();
            before_path=conn.paths().iter().find(|p|p.is_selected()).unwrap().id();
            before_receiver=receiver.paths().iter().find(|p|p.is_selected()).unwrap().id();
            failure_started = Some(Instant::now());
            runtimes[1].disconnect(*inner[2].id().as_bytes()).await;
        }
        let changed = failure_started.unwrap_or_else(Instant::now);
        send.write_all(&payload).await.unwrap(); send.finish().unwrap();
        recv.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply,payload);
        let routes = runtimes[0].routes(*inner[3].id().as_bytes()).await;
        if failover {
            assert_eq!(routes[0].path, [0,4,3].map(|i| *inner[i].id().as_bytes()).to_vec());
        }
        if failover {
            let echo_ms = changed.elapsed().as_millis();
            let circuit = mesh_transport::routing::circuit([99;32], policy(), &routes[0].path);
            // Echo completion does not synchronize the socket actor's path view.
            // Observe both replacements within the original fault-to-recovery budget.
            let deadline = tokio::time::Instant::from_std(changed + Duration::from_millis(5000));
            let (paths, receiver_paths) = tokio::time::timeout_at(deadline, async {
                tokio::join!(replacement(&conn, before_path, circuit),
                             replacement(&receiver, before_receiver, circuit))
            }).await.expect("replacement paths exceeded frozen 5000 ms budget");
            assert!(!paths.iter().any(|p|p.id()==before_path),"withdrawn source path must close");
            let selected = paths.iter().find(|p| p.is_selected()).unwrap();
            assert_ne!(selected.id(),before_path,"route change must use distinct QUIC congestion state");
            let TransportAddr::Custom(addr) = selected.remote_addr() else { panic!("not a mesh path") };
            assert_eq!(&addr.data()[64..],mesh_transport::routing::circuit([99;32], policy(), &routes[0].path));
            assert!(!receiver_paths.iter().any(|p|p.id()==before_receiver),"withdrawn receiver path must close");
            let receiver_selected = receiver_paths.iter().find(|p| p.is_selected()).unwrap();
            let TransportAddr::Custom(receiver_addr) = receiver_selected.remote_addr() else { panic!("receiver not on mesh") };
            assert_eq!(&receiver_addr.data()[64..],mesh_transport::routing::circuit([99;32], policy(), &routes[0].path), "receiver must select the replacement circuit too");
            println!("FAILOVER source={:?} receiver={:?} circuit={:?} echo_ms={} recovery_ms={}", selected.id(), receiver_selected.id(), &addr.data()[64..], echo_ms, changed.elapsed().as_millis());
            assert!(changed.elapsed() <= Duration::from_millis(5000), "same-stream recovery exceeded frozen 5000 ms budget");
        }
        println!("{} nodes: same stream and identities, {} bytes verified, second exchange {} ms, {} hops",
            inner.len(), 2*payload.len(), changed.elapsed().as_millis(), routes[0].path.len()-1);
        conn.close(0u32.into(),b"test done"); echo.await.unwrap();
        for ep in inner { ep.close().await; }
        for r in runtimes { r.close().await; }
    }).await.expect("four-node chain exceeded its deadline");
}

fn policy() -> [u8; 32] { mesh_transport::policy::TransitPolicy::empty().digest() }

async fn replacement(
    connection: &iroh::endpoint::Connection,
    withdrawn: iroh::endpoint::PathId,
    circuit: [u8; 32],
) -> iroh::endpoint::PathList<'_> {
    let mut changes = connection.paths_stream();
    while let Some(paths) = changes.next().await {
        let ready = !paths.iter().any(|p| p.id() == withdrawn)
            && paths.iter().any(|p| p.is_selected() && matches!(p.remote_addr(),
                TransportAddr::Custom(addr) if addr.data().get(64..) == Some(circuit.as_slice())));
        if ready { return paths; }
    }
    panic!("connection closed before its replacement path was selected");
}
