//! Real bootstrap sessions for separate policy lanes of one logical scope.
use iroh::{Endpoint,EndpointAddr,RelayMode,RelayUrl,SecretKey,endpoint::presets::Minimal};
use mesh_transport::{announcement::Descriptor,identity::{Binding,neighbor_secret},policy::TransitPolicy,
    public_service::{Scopes,Subscription,BOOTSTRAP_ALPN},runtime::{Runtime,Peer,ALPN}};
use std::time::Duration;
struct Relay { child:std::process::Child, config:std::path::PathBuf }
impl Drop for Relay {fn drop(&mut self){let _=self.child.kill();let _=self.child.wait();let _=std::fs::remove_file(&self.config);}}
fn relay()->(Relay,RelayUrl) {
    let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port=listener.local_addr().unwrap().port();drop(listener);
    let config=std::env::temp_dir().join(format!("mesh-policy-relay-{}-{port}.toml",std::process::id()));
    std::fs::write(&config,format!("enable_relay = true\nhttp_bind_addr = \"127.0.0.1:{port}\"\nenable_metrics = false\nenable_quic_addr_discovery = false\n")).unwrap();
    let child=std::process::Command::new(std::env::var("STILLFAIL_RELAY_BIN").expect("build iroh-relay for policy side test"))
        .arg("--dev").arg("--config-path").arg(&config).spawn().unwrap();
    (Relay {child,config},format!("http://127.0.0.1:{port}/").parse().unwrap())
}
#[tokio::test]
#[ignore="real QUIC sockets: side test"]
async fn same_scope_policy_lanes_keep_independent_underlays_and_revocations() {
    tokio::time::timeout(Duration::from_secs(40),async {
        let scope=[171;32];let key=SecretKey::from([172;32]);let caller_key=SecretKey::from([173;32]);
        let removed=SecretKey::from([174;32]).public();
        let (_relay,url)=relay();
        let root=Endpoint::builder(Minimal).secret_key(key.clone()).relay_mode(RelayMode::Disabled).alpns(vec![BOOTSTRAP_ALPN.to_vec()]).bind().await.unwrap();
        let caller=Endpoint::builder(Minimal).secret_key(caller_key.clone()).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let scopes=Scopes::new(key.clone(),vec![url.clone()],1).unwrap();
        let registry=vec![mesh_transport::global_registration::Registration {node:removed,name:"other".into(),generation:1,revision:1,address:iroh::EndpointAddr::new(removed)}];
        scopes.backbone(root.clone(),registry).await.unwrap();
        let service=scopes.clone();let accept=root.clone();
        let task=tokio::spawn(async move {let mut tasks=tokio::task::JoinSet::new();while let Some(incoming)=accept.accept().await {
            let service=service.clone();tasks.spawn(async move {if let Ok(conn)=incoming.await {let _=service.serve(conn).await;}});
            while tasks.try_join_next().is_some() {}
        }});
        let narrow=TransitPolicy::new(vec![],vec![mesh_transport::policy::Global{node:key.public(),generation:1}]).unwrap();
        let wide=TransitPolicy::new(vec![url.clone()],vec![mesh_transport::policy::Global{node:key.public(),generation:1},mesh_transport::policy::Global{node:removed,generation:1}]).unwrap();
        let mut subscriptions=Vec::new();let mut runtimes=Vec::new();let mut outers=Vec::new();
        for policy in [&narrow,&wide] {
            let outer=Endpoint::builder(Minimal).secret_key(neighbor_secret(&caller_key,scope,policy.digest())).relay_mode(RelayMode::custom(vec![url.clone()])).alpns(vec![ALPN.to_vec()]).bind().await.unwrap();
            tokio::time::timeout(Duration::from_secs(10),outer.online()).await.expect("caller connected to local relay");
            let binding=Binding::sign(&caller_key,scope,policy.digest(),1,false);
            let mut descriptor=Descriptor{binding:binding.clone(),address:outer.addr()};
            descriptor.address.addrs.insert(iroh::TransportAddr::Relay(url.clone()));
            let runtime=Runtime::start_proven(outer.clone(),binding.clone(),vec![],false).unwrap();
            let subscription=Subscription::open(&caller,root.addr(),&descriptor,policy,1).await.unwrap();
            let public=subscription.initial();assert_eq!(public.binding.policy,policy.digest());
            // Probe before installing the direct address so no cached IP path
            // can hide the relay-only result. The narrow caller deliberately
            // attempts a forbidden relay; the public lane must enforce its policy.
            let relay_only=EndpointAddr::new(public.address.id).with_relay_url(url.clone());
            let connected=tokio::time::timeout(Duration::from_secs(if policy==&wide {10}else{2}),outer.connect(relay_only,ALPN)).await;
            if policy==&wide {
                connected.unwrap().expect("wide lane can use its approved underlay").close(0u32.into(),b"relay-only probe complete");
            } else {
                assert!(!matches!(connected,Ok(Ok(_))),"narrow public lane must reject the forbidden relay-only path");
            }
            runtime.directory_proven(vec![Peer::from_binding(&public.binding,public.address.clone(),scope,1).unwrap()],binding).await.unwrap();
            runtime.connect(*key.public().as_bytes()).await.unwrap();
            subscriptions.push(subscription);runtimes.push(runtime);outers.push(outer);
        }
        assert_ne!(subscriptions[0].initial().address.id,subscriptions[1].initial().address.id);
        // The same logical caller gets distinct authenticated neighbors for
        // each policy; withdrawing a global closes only its policy lane.
        let wide_subscription=subscriptions.pop().unwrap();
        let narrow_subscription=subscriptions.pop().unwrap();
        scopes.backbone(root.clone(),vec![]).await.unwrap();
        let (own_tx,own_rx)=tokio::sync::watch::channel(Descriptor {binding:Binding::sign(&caller_key,scope,wide.digest(),1,false),address:outers[1].addr()});
        let (updates,_incoming)=tokio::sync::mpsc::channel(1);
        assert!(wide_subscription.run(own_rx,updates).await.is_err());drop(own_tx);
        assert_eq!(narrow_subscription.initial().binding.policy,narrow.digest());
        assert_eq!(runtimes[0].linked_nodes().await,vec![*key.public().as_bytes()]);
        eprintln!("same scope: narrow and wide QUIC lanes use distinct authenticated neighbors; revocation closes only affected lane");
        drop(narrow_subscription);drop(subscriptions);for runtime in runtimes {runtime.close().await;}for outer in outers {outer.close().await;}
        task.abort();let _=task.await;scopes.close().await;caller.close().await;root.close().await;
    }).await.expect("policy lane isolation deadline");
}
