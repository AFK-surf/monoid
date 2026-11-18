//! The private forwarding endpoint bootstraps its own public neighbor; the root
//! control endpoint has no business ALPN or application handler.
use iroh::{Endpoint,EndpointAddr,RelayMode,SecretKey,TransportAddr,endpoint::presets::Minimal};
use mesh_transport::{announcement::{Descriptor,SignedAnnouncement,scope_text},directory::{Policy,Snapshot},global_registration::Registration,
    identity::{Binding,neighbor_secret},public_service::{Scopes,Subscription,BOOTSTRAP_ALPN},relay::Forwarder,runtime::{Runtime,Peer,ALPN}};
use std::{collections::BTreeMap,sync::Arc,time::Duration};
const SCOPE:[u8;32]=[189;32];
const ECHO:&[u8]=b"workspace-global-side/1";

#[tokio::test]
#[ignore="real QUIC sockets: side test"]
async fn workspace_relay_bootstraps_public_transit_and_revokes_its_generation() { mixed_path(false).await; }

#[tokio::test]
#[ignore="real daemon process and QUIC sockets: side test"]
async fn workspace_daemon_restores_global_cache_and_keeps_forwarding_when_issuer_disconnects() { mixed_path(true).await; }

struct Temporary(std::path::PathBuf);
impl Drop for Temporary { fn drop(&mut self) { let _=std::fs::remove_dir_all(&self.0); } }
async fn issuer_request(server:&Endpoint)->(iroh::endpoint::Connection,iroh::endpoint::SendStream,serde_json::Value) {
    use tokio::io::{AsyncBufReadExt,BufReader};
    let conn=server.accept().await.unwrap().await.unwrap();let (send,recv)=conn.accept_bi().await.unwrap();
    let mut line=String::new();BufReader::new(recv).read_line(&mut line).await.unwrap();
    (conn,send,serde_json::from_str(&line).unwrap())
}
async fn mixed_path(process:bool) {
    tokio::time::timeout(Duration::from_secs(30),async {
        let a=SecretKey::from([181;32]);let mut b=SecretKey::from([182;32]);let c=SecretKey::from([183;32]);let d=SecretKey::from([184;32]);
        let temp=Temporary(std::env::temp_dir().join(format!("workspace-global-{}",SecretKey::generate().public())));
        let store=if process {let store=mesh_transport::relay_store::Store::open(&temp.0).unwrap();b=store.key();Some(store)}else{None};
        let public=Endpoint::builder(Minimal).secret_key(c.clone()).relay_mode(RelayMode::Disabled)
            .alpns(vec![BOOTSTRAP_ALPN.to_vec()]).bind().await.unwrap();
        let scopes=Scopes::new(c.clone(),vec![],7).unwrap();
        let accept=public.clone();let manager=scopes.clone();
        let accept_bootstrap=Arc::new(std::sync::atomic::AtomicBool::new(true));
        let accepting=accept_bootstrap.clone();
        let service=tokio::spawn(async move {
            let mut tasks=tokio::task::JoinSet::new();
            while let Some(incoming)=accept.accept().await {
                if !accepting.load(std::sync::atomic::Ordering::SeqCst) {incoming.refuse();continue;}
                let manager=manager.clone();
                tasks.spawn(async move {if let Ok(conn)=incoming.await {let _=manager.serve(conn).await;}});
                while tasks.try_join_next().is_some() {}
            }
        });
        let global=Registration {node:c.public(),name:"side".into(),generation:7,revision:1,address:public.addr()};
        let policy=mesh_transport::policy::TransitPolicy::new(vec![],vec![mesh_transport::policy::Global{node:c.public(),generation:7}]).unwrap();
        let relay=Forwarder::bind(&b,SCOPE,a.public(),3).await.unwrap();
        let mut lower=Vec::new();let mut descriptors=Vec::new();
        for key in [&a,&d] {
            let outer=Endpoint::builder(Minimal).secret_key(neighbor_secret(key,SCOPE,policy.digest())).relay_mode(RelayMode::Disabled)
                .alpns(vec![ALPN.to_vec()]).bind().await.unwrap();
            descriptors.push(Descriptor {binding:Binding::sign(key,SCOPE,policy.digest(),1,false),address:outer.addr()});
            lower.push(outer);
        }
        let mut unreachable_d=descriptors[1].clone();unreachable_d.address=EndpointAddr::new(unreachable_d.address.id);
        let snapshot=Snapshot {policy:Policy {scope:scope_text(SCOPE),generation:3,nodes:vec![a.public(),b.public(),d.public()],
            generations:BTreeMap::from([(b.public(),3)]),relay_urls:vec![],global_relays:vec![global.clone()],count:3},
            records:vec![SignedAnnouncement::sign(&a,SCOPE,1,descriptors[0].clone()).unwrap(),
                SignedAnnouncement::sign(&b,SCOPE,1,relay.descriptor()).unwrap(),SignedAnnouncement::sign(&d,SCOPE,1,unreachable_d).unwrap()]};
        // Same serialized snapshot used after a daemon restart, with no issuer
        // connection present. Public bootstrap belongs to the forwarding lifetime.
        let snapshot:Snapshot=serde_json::from_slice(&serde_json::to_vec(&snapshot).unwrap()).unwrap();
        let mut relay=Some(relay);
        let mut child=None;
        let mut issuer=None;
        let mut control=None;
        let descriptor;
        if let Some(store)=store {
            use mesh_transport::enrollment::{Invitation,IssuerAddress,Registration,SignedRegistration};
            relay.take().unwrap().close().await;
            let server=Endpoint::builder(Minimal).secret_key(a.clone()).relay_mode(RelayMode::Disabled)
                .alpns(vec![mesh_transport::enrollment::ALPN.to_vec()]).bind().await.unwrap();
            let invitation=Invitation {scope:scope_text(SCOPE),issuer:a.public(),token:String::new(),endpoint:IssuerAddress {
                id:a.public(),relays:vec![],disabled_relays:vec![],ips:server.addr().ip_addrs().copied().collect()}};
            let record=Registration {scope:scope_text(SCOPE),node:b.public(),issuer:a.public(),generation:3,name:"workspace".into(),made_by:"test".into(),revoked:0};
            let body=serde_json::to_string(&record).unwrap();
            let signed=SignedRegistration {signature:a.sign(format!("mesh-relay-registration/v1\0{body}").as_bytes()).to_string(),body};
            store.save(&mesh_transport::relay_store::Saved {invitation,registration:Some(signed.clone()),revision:1,snapshot:Some(snapshot.clone())}).unwrap();
            drop(store);
            child=Some(tokio::process::Command::new(env!("CARGO_BIN_EXE_mesh-relay")).arg(&temp.0)
                .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::inherit()).kill_on_drop(true).spawn().unwrap());
            let (conn,mut send,request)=issuer_request(&server).await;
            assert_eq!(request["op"],"resume");assert_eq!(conn.remote_id(),b.public());
            send.write_all(&serde_json::to_vec(&serde_json::json!({"ok":signed})).unwrap()).await.unwrap();send.finish().unwrap();conn.closed().await;
            let (conn,send,request)=issuer_request(&server).await;
            assert_eq!(request["op"],"watch");
            let signed:SignedAnnouncement=serde_json::from_value(request["announcement"].clone()).unwrap();
            descriptor=signed.verify(SCOPE,b.public(),3).unwrap().descriptor;
            // No directory frames are sent: only the persisted, fully validated
            // snapshot can supply the process's private/public forwarding policy.
            control=Some((conn,send));issuer=Some(server);
        } else { relay.as_mut().unwrap().apply(snapshot.clone()).await.unwrap(); descriptor=relay.as_ref().unwrap().descriptor(); }
        let mut runtimes=Vec::new();let mut inner=Vec::new();
        for (i,(key,outer)) in [&a,&d].into_iter().zip(lower).enumerate() {
            let other=&descriptors[1-i];
            let mut peers=vec![Peer::from_binding(&other.binding,EndpointAddr::new(other.address.id),SCOPE,1).unwrap()];
            let rd=descriptor.clone();
            peers.push(Peer::from_binding(&rd.binding,if i==0 {rd.address}else{EndpointAddr::new(rd.address.id)},SCOPE,3).unwrap());
            let runtime=Runtime::start_proven(outer,descriptors[i].binding.clone(),peers,false).unwrap();
            runtime.trusted_transit(BTreeMap::from([(*c.public().as_bytes(),7)])).await.unwrap();
            let hub=Arc::new(mesh_transport::hub::Hub::default());hub.insert(SCOPE,runtime.transport.clone()).unwrap();
            // D's root supports bootstrap by IP, but the destination supplied to
            // A below contains only the mesh transport, forcing the three hops.
            inner.push(Endpoint::builder(Minimal).secret_key(key.clone()).relay_mode(RelayMode::Disabled).alpns(vec![ECHO.to_vec()])
                .add_custom_transport(hub.clone()).path_selector(Arc::new(mesh_transport::selection::Selector::new(hub))).bind().await.unwrap());
            runtimes.push(runtime);
        }
        let subscription=Subscription::open(&inner[1],public.addr(),&descriptors[1],&policy,7).await.unwrap();
        let pd=subscription.initial();let rd=descriptor.clone();
        runtimes[1].directory_proven(vec![Peer::from_binding(&pd.binding,pd.address.clone(),SCOPE,7).unwrap(),
            Peer::from_binding(&descriptors[0].binding,EndpointAddr::new(descriptors[0].address.id),SCOPE,1).unwrap(),
            Peer::from_binding(&rd.binding,EndpointAddr::new(rd.address.id),SCOPE,3).unwrap()],descriptors[1].binding.clone()).await.unwrap();
        runtimes[0].connect(*b.public().as_bytes()).await.unwrap();
        runtimes[1].connect(*c.public().as_bytes()).await.unwrap();
        let server=inner[1].clone();let source=a.public();
        let echo=tokio::spawn(async move {
            let conn=server.accept().await.unwrap().await.unwrap();assert_eq!(conn.remote_id(),source);
            let (mut send,mut recv)=conn.accept_bi().await.unwrap();let mut bytes=vec![0;65536];
            for _ in 0..2 {recv.read_exact(&mut bytes).await.unwrap();send.write_all(&bytes).await.unwrap();}
            send.finish().unwrap();conn.closed().await;
        });
        let address=EndpointAddr::new(d.public()).with_addrs([TransportAddr::Custom(runtimes[0].transport.address(*d.public().as_bytes()))]);
        let conn=inner[0].connect(address,ECHO).await.unwrap();assert_eq!(conn.remote_id(),d.public());
        let (mut send,mut recv)=conn.open_bi().await.unwrap();let payload=vec![77;65536];
        for iteration in 0..2 {
            send.write_all(&payload).await.unwrap();let mut reply=vec![0;payload.len()];recv.read_exact(&mut reply).await.unwrap();assert_eq!(reply,payload);
            if let Some(relay)=&mut relay {
                let mut refresh=snapshot.clone();
                refresh.policy.global_relays[0].revision+=1;
                refresh.policy.global_relays[0].address=EndpointAddr::new(c.public()).with_addrs([TransportAddr::Ip("127.0.0.1:9".parse().unwrap())]);
                // Existing bootstrap and data links remain alive, but no fresh
                // bootstrap can succeed until the changed root address recovers.
                accept_bootstrap.store(false,std::sync::atomic::Ordering::SeqCst);
                relay.apply(refresh).await.unwrap();
                assert!(relay.linked_nodes().await.contains(c.public().as_bytes()));
            }
            if process && iteration==0 {
                let (conn,_send)=control.take().unwrap();conn.close(0u32.into(),b"issuer temporarily unavailable");
            }
        }
        let path=vec![*a.public().as_bytes(),*b.public().as_bytes(),*c.public().as_bytes(),*d.public().as_bytes()];
        assert_eq!(runtimes[0].routes(*d.public().as_bytes()).await[0].path,path);
        eprintln!("private A -> workspace B -> public C -> D: 2 x 65536 bytes, E2E identities verified");
        conn.close(0u32.into(),b"done");echo.await.unwrap();
        if let Some(mut relay)=relay {
        accept_bootstrap.store(true,std::sync::atomic::Ordering::SeqCst);
        eprintln!("same-generation root address refresh retained the authenticated forwarding neighbor");
        assert!(relay.linked_nodes().await.contains(c.public().as_bytes()));
        let mut withdrawn=snapshot.clone();withdrawn.policy.global_relays.clear();relay.apply(withdrawn).await.unwrap();
        assert!(!relay.linked_nodes().await.contains(c.public().as_bytes()),"removal must withdraw the existing neighbor");
        let mut replacement=snapshot.clone();replacement.policy.global_relays[0].generation=8;
        relay.apply(replacement).await.unwrap();
        // The public server still signs generation 7. Its actual root response
        // cannot be admitted under the replacement generation 8.
        let replaced=mesh_transport::policy::TransitPolicy::new(vec![],vec![mesh_transport::policy::Global{node:c.public(),generation:8}]).unwrap();
        let next_descriptor=Descriptor {binding:Binding::sign(&a,SCOPE,replaced.digest(),1,false),
            address:EndpointAddr::new(neighbor_secret(&a,SCOPE,replaced.digest()).public())};
        assert!(Subscription::open(&inner[0],public.addr(),&next_descriptor,&replaced,8).await.is_err());
        assert!(!relay.linked_nodes().await.contains(c.public().as_bytes()));
        eprintln!("withdrawal and stale-generation root bootstrap rejected");
        relay.close().await;
        } else {
            eprintln!("real daemon restored cached globals; forwarding survived issuer control disconnect");
        }
        if let Some(mut child)=child {child.kill().await.unwrap();child.wait().await.unwrap();}
        if let Some(issuer)=issuer {issuer.close().await;}
        drop(subscription);service.abort();let _=service.await;scopes.close().await;
        for endpoint in inner {endpoint.close().await;}
        for runtime in runtimes {runtime.close().await;}
        public.close().await;
    }).await.expect("workspace/public side deadline");
}
