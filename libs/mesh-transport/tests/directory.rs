//! Real QUIC directory framing, idle address updates and issuer disconnection.
use iroh::{Endpoint, RelayMode, SecretKey, endpoint::presets::Minimal};
use mesh_transport::{announcement::SignedAnnouncement, directory_client::Subscription, enrollment::{ALPN, Invitation, IssuerAddress}};
use tokio::io::{AsyncBufReadExt, BufReader};

#[tokio::test]
#[ignore = "real sockets: side test"]
async fn authenticated_directory_keeps_updates_and_snapshots_on_one_stream() {
    tokio::time::timeout(std::time::Duration::from_secs(20), async {
        let issuer = Endpoint::builder(Minimal).secret_key(SecretKey::from([70;32])).alpns(vec![ALPN.to_vec()]).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let relay = Endpoint::builder(Minimal).secret_key(SecretKey::from([83;32])).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let announcement: SignedAnnouncement = serde_json::from_str(include_str!("fixtures/announcement.json")).unwrap();
        let invite = Invitation { scope: "54".repeat(32), issuer: issuer.id(), token: String::new(), endpoint: IssuerAddress {
            id: issuer.id(), relays: vec![], disabled_relays: vec![], ips: issuer.addr().ip_addrs().copied().collect(),
        }};
        let server = issuer.clone();
        let node = relay.id();
        let record = announcement.clone();
        let (partial_tx, partial_rx) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(async move {
            let mut partial_tx = Some(partial_tx);
            let conn = server.accept().await.unwrap().await.unwrap();
            assert_eq!(conn.remote_id(), node);
            let (mut send, recv) = conn.accept_bi().await.unwrap();
            let mut reader = BufReader::new(recv);
            let mut input = String::new();
            reader.read_line(&mut input).await.unwrap();
            let asked: serde_json::Value = serde_json::from_str(&input).unwrap();
            assert_eq!(asked["op"], "watch");
            assert!(asked.get("token").is_none());
            let received: SignedAnnouncement = serde_json::from_value(asked["announcement"].clone()).unwrap();
            received.verify([84;32], node, 3).unwrap();
            for version in 1..=2 {
                let begin = serde_json::json!({"begin":version,"scope":"54".repeat(32),"generation":3,"nodes":[node,server.id()],"generations":{node.to_string():3},"relayUrls":[],"count":1});
                // A local update arrives while the second snapshot is partial.
                send.write_all(format!("{begin}\n").as_bytes()).await.unwrap();
                if version == 2 {
                    partial_tx.take().unwrap().send(()).unwrap();
                    input.clear();
                    reader.read_line(&mut input).await.unwrap();
                    let update: serde_json::Value = serde_json::from_str(&input).unwrap();
                    assert_eq!(update["announcement"]["body"], record.body);
                }
                let frames = format!("{}\n{}\n", serde_json::json!({"record":record}), serde_json::json!({"end":version}));
                send.write_all(frames.as_bytes()).await.unwrap();
            }
            send.finish().unwrap();
            conn.closed().await;
        });
        let subscription = Subscription::open(&relay, &invite, [84;32], 3, &announcement).await.unwrap();
        let (updates, changed) = tokio::sync::watch::channel(announcement.clone());
        let (snapshots, mut received) = tokio::sync::mpsc::channel(1);
        let client = tokio::spawn(subscription.run(changed, snapshots));
        let first = received.recv().await.unwrap();
        assert_eq!(first.records.len(), 1);
        partial_rx.await.unwrap();
        updates.send(announcement).unwrap();
        let second = received.recv().await.unwrap();
        assert_eq!(first.records[0].body, second.records[0].body);
        assert!(client.await.unwrap().is_err());
        task.await.unwrap();
        relay.close().await;
        issuer.close().await;
    }).await.expect("directory side test deadline");
}
