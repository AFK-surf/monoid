//! One bounded workspace directory subscription. The owner retries failures with
//! backoff and keeps the last complete snapshot while the control link is down.
use crate::{announcement::SignedAnnouncement, directory::{Receiver, Snapshot}, enrollment::{ALPN, Invitation}, routing::Scope};
use iroh::{Endpoint, EndpointAddr, endpoint::{Connection, RecvStream, SendStream}};
use std::time::Duration;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, BufReader};

const LIMIT: usize = 64 * 1024;

// fill_buf preserves pipelined frames without ever allocating an unbounded line.
async fn line(reader: &mut (impl AsyncBufRead + Unpin)) -> Result<Vec<u8>, String> {
    let mut result = Vec::new();
    loop {
        let bytes = reader.fill_buf().await.map_err(|e| e.to_string())?;
        if bytes.is_empty() { return Err("directory stream ended".into()); }
        let end = bytes.iter().position(|b| *b == b'\n');
        let count = end.unwrap_or(bytes.len());
        if result.len() + count > LIMIT { return Err("directory frame too large".into()); }
        result.extend_from_slice(&bytes[..count]);
        reader.consume(count + usize::from(end.is_some()));
        if end.is_some() { return Ok(result); }
    }
}

pub struct Subscription {
    connection: Connection,
    send: SendStream,
    recv: BufReader<RecvStream>,
    receiver: Receiver,
}
impl Subscription {
    pub async fn open(endpoint: &Endpoint, invite: &Invitation, scope: Scope, generation: u64, announcement: &SignedAnnouncement) -> Result<Self, String> {
        if invite.endpoint.id != invite.issuer || invite.scope != crate::announcement::scope_text(scope)
            || invite.endpoint.relays.len() > 32 || invite.endpoint.ips.len() > 8 || invite.endpoint.disabled_relays.len() > 64 {
            return Err("invalid directory issuer".into());
        }
        announcement.verify(scope, endpoint.id(), generation)?;
        tokio::time::timeout(Duration::from_secs(10), async {
            let mut address = EndpointAddr::new(invite.issuer);
            for relay in &invite.endpoint.relays {
                if !invite.endpoint.disabled_relays.contains(relay) { address = address.with_relay_url(relay.clone()); }
            }
            for ip in &invite.endpoint.ips { address = address.with_ip_addr(*ip); }
            let options = iroh::endpoint::ConnectOptions::new().with_disabled_relays(invite.endpoint.disabled_relays.clone());
            let connection = endpoint.connect_with_opts(address, ALPN, options).await.map_err(|e| e.to_string())?
                .await.map_err(|e| e.to_string())?;
            let (send, recv) = connection.open_bi().await.map_err(|e| e.to_string())?;
            let mut subscription = Self { connection, send, recv: BufReader::with_capacity(4096, recv), receiver: Receiver::new(scope, endpoint.id(), invite.issuer, generation) };
            subscription.write(&serde_json::json!({"op":"watch","scope":invite.scope,"announcement":announcement})).await?;
            Ok(subscription)
        }).await.map_err(|_| "directory connection deadline".to_owned())?
    }
    async fn write(&mut self, value: &serde_json::Value) -> Result<(), String> {
        let mut bytes = serde_json::to_vec(value).map_err(|e| e.to_string())?;
        if bytes.len() > LIMIT { return Err("directory frame too large".into()); }
        bytes.push(b'\n');
        tokio::time::timeout(Duration::from_secs(15), self.send.write_all(&bytes)).await
            .map_err(|_| "directory write deadline".to_owned())?.map_err(|e| e.to_string())
    }
    /// Drive both directions without cancelling a partially received frame when
    /// the local address changes. Updates coalesce in a watch slot; snapshots
    /// await a bounded consumer. Returning drops and closes the whole session.
    pub async fn run(mut self, mut updates: tokio::sync::watch::Receiver<SignedAnnouncement>, snapshots: tokio::sync::mpsc::Sender<Snapshot>) -> Result<(), String> {
        let recv = &mut self.recv;
        let receiver = &mut self.receiver;
        let reading = async {
            let mut initial = true;
            loop {
                let first = if initial {
                    initial = false;
                    tokio::time::timeout(Duration::from_secs(15), line(recv)).await
                        .map_err(|_| "initial directory deadline".to_owned())??
                } else { line(recv).await? };
                let snapshot = if let Some(snapshot) = receiver.frame(&first)? { snapshot } else {
                    tokio::time::timeout(Duration::from_secs(15), async {
                        loop {
                            let bytes = line(recv).await?;
                            if let Some(snapshot) = receiver.frame(&bytes)? { return Ok::<_, String>(snapshot); }
                        }
                    }).await.map_err(|_| "directory snapshot deadline".to_owned())??
                };
                tokio::time::timeout(Duration::from_secs(15), snapshots.send(snapshot)).await
                    .map_err(|_| "directory consumer stalled".to_owned())?.map_err(|_| "directory consumer closed".to_owned())?;
            }
            #[allow(unreachable_code)] Ok::<(), String>(())
        };
        let send = &mut self.send;
        let writing = async {
            loop {
                updates.changed().await.map_err(|_| "address publisher closed".to_owned())?;
                let announcement = updates.borrow_and_update().clone();
                let mut bytes = serde_json::to_vec(&serde_json::json!({"announcement":announcement})).map_err(|e| e.to_string())?;
                if bytes.len() > LIMIT { return Err("directory frame too large".into()); }
                bytes.push(b'\n');
                tokio::time::timeout(Duration::from_secs(15), send.write_all(&bytes)).await
                    .map_err(|_| "directory write deadline".to_owned())?.map_err(|e| e.to_string())?;
            }
        };
        tokio::select! {
            result = reading => result,
            result = writing => result,
            reason = self.connection.closed() => Err(reason.to_string()),
        }
    }

}
impl Drop for Subscription {
    fn drop(&mut self) { self.connection.close(0u32.into(), b"directory subscription ended"); }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn framed_reads_preserve_pipelining_and_reject_unterminated_oversize() {
        let mut reader = BufReader::with_capacity(2, &b"first\nsecond\n"[..]);
        assert_eq!(line(&mut reader).await.unwrap(), b"first");
        assert_eq!(line(&mut reader).await.unwrap(), b"second");
        assert!(line(&mut reader).await.is_err());
        let oversized = vec![b'x'; LIMIT + 1];
        assert!(line(&mut BufReader::new(oversized.as_slice())).await.is_err());
        assert!(line(&mut BufReader::new(&b"partial"[..])).await.is_err());
    }
}
