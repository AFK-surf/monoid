//! Real socket classification of authenticated registration refusals.
use iroh::{Endpoint, RelayMode, SecretKey, endpoint::presets::Minimal};
use mesh_transport::enrollment::{ALPN, Invitation, IssuerAddress};

#[tokio::test]
#[ignore = "real sockets: side test"]
async fn authenticated_rejection_is_distinct_from_a_transport_failure() {
    use mesh_transport::enrollment::request_status;
    tokio::time::timeout(std::time::Duration::from_secs(20), async {
        let issuer = Endpoint::builder(Minimal).secret_key(SecretKey::from([70;32])).alpns(vec![ALPN.to_vec()]).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let relay = Endpoint::builder(Minimal).secret_key(SecretKey::from([71;32])).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let invite = Invitation { scope:"ab".repeat(32), issuer:issuer.id(), token:String::new(), endpoint:IssuerAddress {
            id:issuer.id(), relays:vec![], disabled_relays:vec![], ips:issuer.addr().ip_addrs().copied().collect(),
        }};
        let server = issuer.clone();
        let task = tokio::spawn(async move {
            for code in ["relay_not_registered", "temporary_failure"] {
                let conn = server.accept().await.unwrap().await.unwrap();
                let (mut send,mut recv) = conn.accept_bi().await.unwrap();
                recv.read_to_end(4096).await.unwrap();
                let reply = serde_json::to_vec(&serde_json::json!({"error":"refused","code":code})).unwrap();
                send.write_all(&reply).await.unwrap(); send.finish().unwrap();
                conn.closed().await;
            }
        });
        assert!(request_status(&relay,&invite,true).await.unwrap_err().registration_removed());
        assert!(!request_status(&relay,&invite,true).await.unwrap_err().registration_removed());
        task.await.unwrap(); relay.close().await; issuer.close().await;
    }).await.expect("rejection side test deadline");
}
