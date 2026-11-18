//! Exercise the actual root bootstrap protocol and its scoped data endpoints.
use iroh::{Endpoint,EndpointAddr,RelayMode,SecretKey,TransportAddr,endpoint::presets::Minimal};
use mesh_transport::{announcement::Descriptor,identity::{Binding,neighbor_secret},public_service::{Scopes,Subscription,BOOTSTRAP_ALPN},runtime::{Runtime,Peer,ALPN}};
use std::time::Duration;
use mesh_transport::policy::{TransitPolicy,Global};
const ECHO:&[u8]=b"mesh-bootstrap-side/1";
#[tokio::test]
#[ignore="real sockets: side test"]
async fn root_bootstrap_gives_two_callers_the_same_policy_scoped_neighbor() {
    tokio::time::timeout(Duration::from_secs(20),async {
        let key=SecretKey::from([71;32]);let scope=[76;32];
        let root=Endpoint::builder(Minimal).secret_key(key.clone()).relay_mode(RelayMode::Disabled).alpns(vec![BOOTSTRAP_ALPN.to_vec()]).bind().await.unwrap();
        let scopes=Scopes::new(key.clone(),vec![],1).unwrap();
        let policy=TransitPolicy::new(vec![],vec![Global{node:key.public(),generation:1}]).unwrap();
        let accept=root.clone();let service=scopes.clone();
        let serving=tokio::spawn(async move {let mut tasks=tokio::task::JoinSet::new();
            for _ in 0..2 {let conn=accept.accept().await.unwrap().await.unwrap();let service=service.clone();tasks.spawn(async move {let _=service.serve(conn).await;});}
            while tasks.join_next().await.is_some() {}
        });
        let mut callers=Vec::new();let mut subscriptions=Vec::new();
        for n in [72,73] {
            let caller_key=SecretKey::from([n;32]);
            let caller=Endpoint::builder(Minimal).secret_key(caller_key.clone()).relay_mode(RelayMode::Disabled).bind().await.unwrap();
            let own=Descriptor {binding:Binding::sign(&caller_key,scope,policy.digest(),1,false),
                address:EndpointAddr::new(neighbor_secret(&caller_key,scope,policy.digest()).public())};
            subscriptions.push(Subscription::open(&caller,root.addr(),&own,&policy,1).await.unwrap());callers.push(caller);
        }
        assert_eq!(subscriptions[0].initial().binding.endpoint,*key.public().as_bytes());
        assert_eq!(subscriptions[0].initial().binding.policy,policy.digest());
        assert_eq!(subscriptions[0].initial().binding.neighbor,subscriptions[1].initial().binding.neighbor);
        drop(subscriptions);serving.await.unwrap();scopes.close().await;
        for caller in callers {caller.close().await;}root.close().await;
    }).await.expect("bootstrap identity deadline");
}

#[tokio::test]
#[ignore="real sockets: side test"]
async fn cold_public_backbone_discovers_a_three_link_business_path() {
    tokio::time::timeout(Duration::from_secs(30),async {
        let scope=[79;32];
        let mut roots=Vec::new();let mut managers=Vec::new();let mut services=Vec::new();
        for n in [81,82] {
            let key=SecretKey::from([n;32]);
            let root=Endpoint::builder(Minimal).secret_key(key.clone()).relay_mode(RelayMode::Disabled).alpns(vec![BOOTSTRAP_ALPN.to_vec()]).bind().await.unwrap();
            let scopes=Scopes::new(key,vec![],1).unwrap();
            let accept=root.clone();let manager=scopes.clone();
            services.push(tokio::spawn(async move {
                let mut tasks=tokio::task::JoinSet::new();
                while let Some(incoming)=accept.accept().await {
                    let manager=manager.clone();
                    tasks.spawn(async move {if let Ok(conn)=incoming.await {let _=manager.serve(conn).await;}});
                }
            }));
            roots.push(root);managers.push(scopes);
        }
        let registry:Vec<_>=roots.iter().map(|root|mesh_transport::global_registration::Registration {node:root.id(),name:"side".into(),generation:1,revision:1,address:root.addr()}).collect();
        let policy=TransitPolicy::new(vec![],registry.iter().map(|r|Global{node:r.node,generation:r.generation}).collect()).unwrap();
        for i in 0..2 {managers[i].backbone(roots[i].clone(),registry.clone()).await.unwrap();}
        let mut runtimes=Vec::new();let mut endpoints=Vec::new();let mut descriptors=Vec::new();
        for n in [72,73] {
            let key=SecretKey::from([n;32]);
            let outer=Endpoint::builder(Minimal).secret_key(neighbor_secret(&key,scope,policy.digest())).relay_mode(RelayMode::Disabled).alpns(vec![ALPN.to_vec()]).bind().await.unwrap();
            let binding=Binding::sign(&key,scope,policy.digest(),1,false);
            let descriptor=Descriptor {binding:binding.clone(),address:outer.addr()};
            let runtime=Runtime::start_proven(outer,binding,vec![],false).unwrap();
            let inner=Endpoint::builder(Minimal).secret_key(key).relay_mode(RelayMode::Disabled).alpns(vec![ECHO.to_vec()])
                .add_custom_transport(runtime.transport.clone()).bind().await.unwrap();
            endpoints.push(inner);runtimes.push(runtime);descriptors.push(descriptor);
        }
        let first=Subscription::open(&endpoints[0],roots[0].addr(),&descriptors[0],&policy,1).await.unwrap();
        let second=Subscription::open(&endpoints[1],roots[1].addr(),&descriptors[1],&policy,1).await.unwrap();
        assert_eq!(first.initial().binding.endpoint,*roots[0].id().as_bytes());
        assert_ne!(first.initial().binding.neighbor,second.initial().binding.neighbor);
        for i in 0..2 {
            runtimes[i].trusted_transit(registry.iter().map(|r|(*r.node.as_bytes(),r.generation)).collect()).await.unwrap();
            let public=if i==0 {first.initial()}else{second.initial()};
            let peer=&descriptors[1-i];
            let peers=vec![Peer::from_binding(&public.binding,public.address.clone(),scope,1).unwrap(),
                Peer::from_binding(&peer.binding,EndpointAddr::new(peer.address.id),scope,1).unwrap()];
            runtimes[i].directory_proven(peers,descriptors[i].binding.clone()).await.unwrap();
        }
        let server=endpoints[1].clone();let source=endpoints[0].id();
        let echo=tokio::spawn(async move {
            let conn=server.accept().await.unwrap().await.unwrap();assert_eq!(conn.remote_id(),source);
            let (mut send,mut recv)=conn.accept_bi().await.unwrap();let data=recv.read_to_end(65536).await.unwrap();
            send.write_all(&data).await.unwrap();send.finish().unwrap();conn.closed().await;
        });
        let target=endpoints[1].id();
        // Only the custom destination is supplied; no public root or direct IP
        // can carry the business protocol as an accidental alternate route.
        let addr=EndpointAddr::new(target).with_addrs([TransportAddr::Custom(runtimes[0].transport.address(*target.as_bytes()))]);
        let conn=endpoints[0].connect(addr,ECHO).await.unwrap();assert_eq!(conn.remote_id(),target);
        let (mut send,mut recv)=conn.open_bi().await.unwrap();let payload=vec![47;65536];
        send.write_all(&payload).await.unwrap();send.finish().unwrap();
        assert_eq!(recv.read_to_end(65536).await.unwrap(),payload);
        assert_eq!(runtimes[0].routes(*target.as_bytes()).await[0].path,vec![*source.as_bytes(),*roots[0].id().as_bytes(),*roots[1].id().as_bytes(),*target.as_bytes()]);
        conn.close(0u32.into(),b"done");echo.await.unwrap();
        drop(first);drop(second);
        for manager in managers {manager.close().await;}
        for service in services {service.abort();}
        for endpoint in endpoints {endpoint.close().await;}
        for runtime in runtimes {runtime.close().await;}
        for root in roots {root.close().await;}
    }).await.expect("public bootstrap side test exceeded deadline");
}

#[tokio::test]
#[ignore="real sockets: side test"]
async fn withdrawn_global_cannot_rejoin_as_a_private_bootstrap_caller() {
    tokio::time::timeout(Duration::from_secs(20),async {
        let scope=[93;32];let caller_key=SecretKey::from([94;32]);let server_key=SecretKey::from([95;32]);
        let root=Endpoint::builder(Minimal).secret_key(server_key.clone()).relay_mode(RelayMode::Disabled).alpns(vec![BOOTSTRAP_ALPN.to_vec()]).bind().await.unwrap();
        let caller=Endpoint::builder(Minimal).secret_key(caller_key.clone()).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let mut policy=TransitPolicy::new(vec![],vec![Global{node:server_key.public(),generation:1},Global{node:caller_key.public(),generation:1}]).unwrap();
        let outer=Endpoint::builder(Minimal).secret_key(neighbor_secret(&caller_key,scope,policy.digest())).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let scopes=Scopes::new(server_key,vec![],1).unwrap();
        let registration=mesh_transport::global_registration::Registration {node:caller.id(),name:"caller".into(),generation:1,revision:1,address:caller.addr()};
        scopes.backbone(root.clone(),vec![registration.clone()]).await.unwrap();
        let accept=root.clone();let manager=scopes.clone();
        let service=tokio::spawn(async move {
            let mut tasks=tokio::task::JoinSet::new();
            while let Some(incoming)=accept.accept().await {
                let manager=manager.clone();tasks.spawn(async move {if let Ok(conn)=incoming.await {let _=manager.serve(conn).await;}});
            }
        });
        let mut descriptor=Descriptor {binding:Binding::sign(&caller_key,scope,policy.digest(),1,true),address:outer.addr()};
        let subscription=Subscription::open(&caller,root.addr(),&descriptor,&policy,1).await.unwrap();
        scopes.backbone(root.clone(),vec![]).await.unwrap();
        let (_own,updates)=tokio::sync::watch::channel(descriptor.clone());
        let (tx,_rx)=tokio::sync::mpsc::channel(1);
        assert!(subscription.run(updates,tx).await.is_err(),"withdrawal closes the existing subscription");
        assert!(Subscription::open(&caller,root.addr(),&descriptor,&policy,1).await.is_err(),"removed global identity cannot pose as an ordinary caller");
        scopes.backbone(root.clone(),vec![mesh_transport::global_registration::Registration {generation:2,..registration}]).await.unwrap();
        assert!(Subscription::open(&caller,root.addr(),&descriptor,&policy,1).await.is_err(),"old generation remains refused");
        policy=TransitPolicy::new(vec![],vec![Global{node:root.id(),generation:1},Global{node:caller_key.public(),generation:2}]).unwrap();
        descriptor.binding=Binding::sign(&caller_key,scope,policy.digest(),2,true);
        descriptor.address=EndpointAddr::new(neighbor_secret(&caller_key,scope,policy.digest()).public());
        let replacement=Subscription::open(&caller,root.addr(),&descriptor,&policy,1).await.unwrap();
        drop(replacement);service.abort();scopes.close().await;
        outer.close().await;caller.close().await;root.close().await;
    }).await.expect("global withdrawal exceeded deadline");
}
