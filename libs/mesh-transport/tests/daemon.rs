//! Starts the real executable and restarts it after one-use token consumption.
use iroh::{Endpoint, RelayMode, SecretKey, endpoint::{Connection, presets::Minimal}};
use mesh_transport::{announcement::SignedAnnouncement, enrollment::{ALPN, Invitation, IssuerAddress, Registration, SignedRegistration}, relay_store::Store};
use std::{path::PathBuf, process::Stdio, time::Duration};
use tokio::io::{AsyncBufReadExt, BufReader};
struct Temporary(PathBuf);
impl Drop for Temporary { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }
async fn request(server: &Endpoint) -> (Connection, iroh::endpoint::SendStream, serde_json::Value) {
    let conn = server.accept().await.unwrap().await.unwrap();
    let (send,recv) = conn.accept_bi().await.unwrap();
    let mut line = String::new();
    BufReader::new(recv).read_line(&mut line).await.unwrap();
    (conn,send,serde_json::from_str(&line).unwrap())
}
async fn reply(conn: &Connection, send: &mut iroh::endpoint::SendStream, value: serde_json::Value) {
    send.write_all(&serde_json::to_vec(&value).unwrap()).await.unwrap();
    send.finish().unwrap(); conn.closed().await;
}
fn process(data: &std::path::Path, invitation: Option<&std::path::Path>) -> tokio::process::Child {
    let mut cmd = tokio::process::Command::new(env!("CARGO_BIN_EXE_mesh-relay"));
    cmd.arg(data).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::inherit()).kill_on_drop(true);
    if let Some(invitation) = invitation { cmd.arg(invitation); }
    cmd.spawn().unwrap()
}
#[tokio::test]
#[ignore = "real processes and sockets: side test"]
async fn executable_restarts_without_token_and_stops_after_authenticated_revocation() {
    tokio::time::timeout(Duration::from_secs(40), async {
        let temp = Temporary(std::env::temp_dir().join(format!("mesh-daemon-{}",SecretKey::generate().public())));
        std::fs::create_dir(&temp.0).unwrap();
        let data = temp.0.join("relay"); let invitation = temp.0.join("invite.json");
        let key = SecretKey::from([70;32]);
        let server = Endpoint::builder(Minimal).secret_key(key.clone()).alpns(vec![ALPN.to_vec()]).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let invite = Invitation { scope:"ab".repeat(32),issuer:server.id(),token:"t".repeat(43),endpoint:IssuerAddress {
            id:server.id(),relays:vec![],disabled_relays:vec![],ips:server.addr().ip_addrs().copied().collect() }};
        std::fs::write(&invitation,serde_json::to_vec(&invite).unwrap()).unwrap();
        let mut first = process(&data,Some(&invitation));
        let (conn,mut send,asked) = request(&server).await;
        assert_eq!(asked["op"],"resume"); let identity = conn.remote_id();
        reply(&conn,&mut send,serde_json::json!({"error":"not registered","code":"relay_not_registered"})).await;
        let (conn,mut send,asked) = request(&server).await;
        assert_eq!(asked["op"],"enroll"); assert_eq!(asked["token"],invite.token); assert_eq!(conn.remote_id(),identity);
        let record = Registration { scope:invite.scope.clone(),node:identity,issuer:server.id(),generation:1,name:"test relay".into(),made_by:"test".into(),revoked:0 };
        let body = serde_json::to_string(&record).unwrap();
        let signed = SignedRegistration { signature:key.sign(format!("mesh-relay-registration/v1\0{body}").as_bytes()).to_string(),body };
        reply(&conn,&mut send,serde_json::json!({"ok":signed})).await;
        let (watch,_,asked) = request(&server).await;
        assert_eq!(asked["op"],"watch");
        let announcement: SignedAnnouncement = serde_json::from_value(asked["announcement"].clone()).unwrap();
        let initial = announcement.verify([0xab;32],identity,1).unwrap();
        first.kill().await.unwrap(); first.wait().await.unwrap();
        watch.close(0u32.into(),b"restart test");
        let store = Store::open(&data).unwrap();
        let saved = store.load().unwrap().unwrap();
        assert_eq!(store.key().public(),identity); assert!(saved.invitation.token.is_empty()); assert!(saved.registration.is_some());
        drop(store);
        std::fs::remove_file(&invitation).unwrap();
        let mut second = process(&data,None);
        let (conn,mut send,asked) = request(&server).await;
        assert_eq!(asked["op"],"resume"); assert!(asked.get("token").is_none()); assert_eq!(conn.remote_id(),identity);
        reply(&conn,&mut send,serde_json::json!({"ok":signed})).await;
        let (watch,_,asked) = request(&server).await;
        assert_eq!(asked["op"],"watch");
        let announcement: SignedAnnouncement = serde_json::from_value(asked["announcement"].clone()).unwrap();
        assert!(announcement.verify([0xab;32],identity,1).unwrap().revision > initial.revision);
        watch.close(1u32.into(),b"relay registration removed");
        let (conn,mut send,asked) = request(&server).await;
        assert_eq!(asked["op"],"resume");
        reply(&conn,&mut send,serde_json::json!({"error":"revoked","code":"relay_not_registered"})).await;
        assert!(!second.wait().await.unwrap().success());
        let store = Store::open(&data).unwrap();
        let saved = store.load().unwrap().unwrap();
        assert!(saved.registration.is_none()); assert!(saved.snapshot.is_none()); assert_eq!(store.key().public(),identity);
        drop(store); server.close().await;
    }).await.expect("relay executable side test deadline");
}
