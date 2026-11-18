//! An independent relay forwards encrypted business streams from signed policy.
use iroh::{Endpoint, EndpointAddr, RelayMode, SecretKey, TransportAddr, endpoint::presets::Minimal};
use mesh_transport::{announcement::{Descriptor, SignedAnnouncement, scope_text}, directory::{Policy, Snapshot}, identity::{Binding, neighbor_secret}, relay::Forwarder, runtime::{ALPN, Peer, Runtime}};
use std::{collections::BTreeMap, sync::Arc, time::Duration};
const SCOPE: [u8;32] = [89;32];
const ECHO: &[u8] = b"relay-side/echo/1";

#[tokio::test]
#[ignore = "real sockets: side test"]
async fn signed_directory_drives_independent_relay_and_removes_revoked_routes() {
    tokio::time::timeout(Duration::from_secs(20), async {
        let a = SecretKey::from([91;32]);
        let b = SecretKey::from([92;32]);
        let d = SecretKey::from([93;32]);
        let mut relay = Forwarder::bind(&b, SCOPE, a.public(), 3).await.unwrap();
        let mut lower = vec![];
        let mut descriptors = vec![];
        for key in [&a, &d] {
            let endpoint = Endpoint::builder(Minimal).secret_key(neighbor_secret(key,SCOPE,mesh_transport::policy::TransitPolicy::empty().digest())).alpns(vec![ALPN.to_vec()])
                .relay_mode(RelayMode::Disabled).bind().await.unwrap();
            descriptors.push(Descriptor { binding: Binding::sign(key, SCOPE, mesh_transport::policy::TransitPolicy::empty().digest(), 1, false), address: endpoint.addr() });
            lower.push(endpoint);
        }
        let mut snapshot = Snapshot { policy: Policy { scope: scope_text(SCOPE), generation:3,
            nodes:vec![a.public(),b.public(),d.public()], generations:BTreeMap::from([(b.public(),3)]), relay_urls:vec![],global_relays:vec![],count:3 },
            records:vec![SignedAnnouncement::sign(&a,SCOPE,1,descriptors[0].clone()).unwrap(),
                SignedAnnouncement::sign(&b,SCOPE,1,relay.descriptor()).unwrap(),
                SignedAnnouncement::sign(&d,SCOPE,1,descriptors[1].clone()).unwrap()] };
        relay.apply(snapshot.clone()).await.unwrap();
        let mut runtimes = vec![];
        let mut inner = vec![];
        for (i, (key, endpoint)) in [&a,&d].into_iter().zip(lower).enumerate() {
            let rd = relay.descriptor();
            let other = &descriptors[1-i];
            let peers = vec![Peer::from_binding(&rd.binding,rd.address,SCOPE,3).unwrap(),
                Peer::from_binding(&other.binding,EndpointAddr::new(other.address.id),SCOPE,1).unwrap()];
            let runtime = Runtime::start_proven(endpoint,Binding::sign(key, SCOPE, mesh_transport::policy::TransitPolicy::empty().digest(), 1, false),peers,false).unwrap();
            let hub = Arc::new(mesh_transport::hub::Hub::default());
            hub.insert(SCOPE,runtime.transport.clone()).unwrap();
            inner.push(Endpoint::builder(Minimal).secret_key(key.clone()).alpns(vec![ECHO.to_vec()])
                .clear_ip_transports().clear_relay_transports().add_custom_transport(hub.clone())
                .path_selector(Arc::new(mesh_transport::selection::Selector::new(hub))).bind().await.unwrap());
            runtime.connect(*b.public().as_bytes()).await.unwrap();
            runtimes.push(runtime);
        }
        let server = inner[1].clone();
        let sender = a.public();
        let echo = tokio::spawn(async move {
            let conn = server.accept().await.unwrap().await.unwrap();
            assert_eq!(conn.remote_id(),sender);
            let (mut send,mut recv) = conn.accept_bi().await.unwrap();
            let mut data = vec![0;65536];
            for _ in 0..2 { recv.read_exact(&mut data).await.unwrap(); send.write_all(&data).await.unwrap(); }
            send.finish().unwrap();
            conn.closed().await;
        });
        let address = EndpointAddr::new(d.public()).with_addrs([TransportAddr::Custom(runtimes[0].transport.address(*d.public().as_bytes()))]);
        let conn = inner[0].connect(address,ECHO).await.unwrap();
        assert_eq!(conn.remote_id(),d.public());
        let (mut send,mut recv) = conn.open_bi().await.unwrap();
        let payload: Vec<u8> = (0..65536).map(|i| (i%251) as u8).collect();
        for _ in 0..2 {
            send.write_all(&payload).await.unwrap();
            let mut reply = vec![0;payload.len()];
            recv.read_exact(&mut reply).await.unwrap();
            assert_eq!(reply,payload);
            relay.apply(snapshot.clone()).await.unwrap();
        }
        let routes = runtimes[0].routes(*d.public().as_bytes()).await;
        assert_eq!(routes[0].path,vec![*a.public().as_bytes(),*b.public().as_bytes(),*d.public().as_bytes()]);
        conn.close(0u32.into(),b"stream verification done"); echo.await.unwrap();
        assert!(relay.linked_nodes().await.contains(d.public().as_bytes()));
        snapshot.policy.nodes.retain(|id| *id != d.public());
        snapshot.records.pop(); snapshot.policy.count = 2;
        relay.apply(snapshot).await.unwrap();
        assert!(!relay.linked_nodes().await.contains(d.public().as_bytes()),"removed destination must lose its live neighbor link");
        runtimes[1].disconnect(*b.public().as_bytes()).await;
        assert!(runtimes[1].connect(*b.public().as_bytes()).await.is_err(),"revoked neighbor must not reconnect");

        for endpoint in inner { endpoint.close().await; }
        for runtime in runtimes { runtime.close().await; }
        relay.close().await;
    }).await.expect("relay forwarding side test deadline");
}
