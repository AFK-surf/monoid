//! From mesh/station/src/keep.rs. The station on every one of still.fail's relays, not only its home one.
//!
//! A relay passes packets on only to whoever is linked to it, and iroh keeps a link only to its home relay (the
//! nearest): one it sends nothing on is let go after a minute. So a station abroad, at home on Cloudflare's relay, was
//! out of reach of a phone in mainland China, which seldom gets through to Cloudflare (2026-10-01, bft in Tokyo); the
//! phone's packets on the other relays went nowhere. iroh 1.x takes one relay transport per endpoint, so a station
//! cannot be at home on several: each relay gets a keeper instead, a small endpoint of its own on that relay alone (no
//! IP), which the station stays connected to through that relay. The connection's keep-alives (iroh's, every 5 s)
//! are the station sending on the relay, so its link there stays up, and a device dialing on any of the relays is heard
//! (the station answers on the relay it heard it on).

use std::{
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow};
use iroh::{Endpoint, EndpointAddr, RelayMode, RelayUrl, endpoint::presets::Minimal};

/// What the station and its keepers speak: nothing, only the connection is wanted.
const ALPN: &[u8] = b"stillfail/keep/1";
/// How long a keeper may take to be on its relay, and the station to reach it there.
const SETUP: Duration = Duration::from_secs(20);
/// The longest wait before trying a relay again; a hold that lasted this long starts the waits over.
const MAX_BACKOFF: Duration = Duration::from_secs(60);
/// How long an endpoint of this file's is given to close: iroh's graceful close waits on every connection (up to some
/// 12 s), which held the next hold (or a probe's answer) that long.
const CLOSE_TIMEOUT: Duration = Duration::from_secs(2);
/// How long a probe's endpoint may take to be on the relay, and the station to reach it there.
const PROBE_TIMEOUT: Duration = Duration::from_secs(10);

/// Holds the station on one relay for good, starting over (with backoff) whenever the hold breaks.
pub async fn keep(endpoint: Endpoint, relay: RelayUrl) {
    let mut backoff = Duration::from_secs(1);
    loop {
        let started = Instant::now();
        if let Err(error) = hold(&endpoint, &relay).await {
            crate::log::info(&format!("mesh: not held on {relay}: {error:#}"));
        }
        if started.elapsed() >= MAX_BACKOFF {
            backoff = Duration::from_secs(1);
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(MAX_BACKOFF);
    }
}

/// One hold: a keeper on the relay, the station connected to it through the relay, until that connection ends.
async fn hold(endpoint: &Endpoint, relay: &RelayUrl) -> Result<()> {
    let keeper = Endpoint::builder(Minimal)
        .clear_ip_transports()
        .relay_mode(RelayMode::Custom(iroh::RelayMap::from_iter([relay.clone()])))
        .alpns(vec![ALPN.to_vec()]);
    let keeper = keeper
        .bind()
        .await
        .context("keeper")?;
    let held = async {
        tokio::time::timeout(SETUP, keeper.online()).await.map_err(|_| anyhow!("keeper not on the relay after {SETUP:?}"))?;
        let addr = EndpointAddr::new(keeper.id()).with_relay_url(relay.clone());
        let dialed = async { endpoint.connect(addr, ALPN).await.context("station to keeper") };
        let accepted = async {
            let incoming = keeper.accept().await.context("keeper closed")?;
            incoming.await.context("keeper accepting")
        };
        let (conn, _accepted) = tokio::time::timeout(SETUP, async { tokio::try_join!(dialed, accepted) })
            .await
            .map_err(|_| anyhow!("no connection through the relay after {SETUP:?}"))??;
        crate::log::info(&format!("mesh: held on {relay}"));
        let reason = conn.closed().await;
        Err::<(), _>(anyhow!("connection through the relay ended: {reason}"))
    }
    .await;
    let _ = tokio::time::timeout(CLOSE_TIMEOUT, keeper.close()).await;
    held
}

/// What a probe of the station's endpoint through one relay found (`probe`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeResult {
    /// The station reached a fresh endpoint through the relay.
    Ok,
    /// A fresh endpoint did not get on the relay: this machine's network or the relay is down now, not the station.
    ProbeOffline,
    /// A fresh endpoint is on the relay, yet the station did not reach it there: the station's endpoint is at fault.
    EndpointFailed,
}

impl ProbeResult {
    /// What a probe that failed failed at (`probe_offline`, `endpoint_failed`); none for one that did not.
    pub fn stage(self) -> Option<&'static str> {
        match self {
            ProbeResult::Ok => None,
            ProbeResult::ProbeOffline => Some("probe_offline"),
            ProbeResult::EndpointFailed => Some("endpoint_failed"),
        }
    }
}

/// Whether the station's endpoint can be reached through `relay` now, end to end: a fresh endpoint of its own on that
/// relay alone (as a keeper is), dialed by the station's through the relay. The relay answering its HTTP ping says
/// nothing of the station's link there; this does, and tells a station that is no longer reached (its endpoint stuck)
/// from a network that is down.
pub async fn probe(endpoint: &Endpoint, relay: &RelayUrl) -> ProbeResult {
    let Ok(probe) = Endpoint::builder(Minimal)
        .clear_ip_transports()
        .relay_mode(RelayMode::Custom(iroh::RelayMap::from_iter([relay.clone()])))
        .alpns(vec![ALPN.to_vec()])
        .bind()
        .await
    else {
        return ProbeResult::ProbeOffline;
    };
    if tokio::time::timeout(PROBE_TIMEOUT, probe.online()).await.is_err() {
        let _ = tokio::time::timeout(CLOSE_TIMEOUT, probe.close()).await;
        return ProbeResult::ProbeOffline;
    }
    let addr = EndpointAddr::new(probe.id()).with_relay_url(relay.clone());
    let dialed = async { endpoint.connect(addr, ALPN).await.map_err(|e| e.to_string()) };
    let accepted = async {
        let incoming = probe.accept().await.ok_or_else(|| "probe closed".to_string())?;
        incoming.await.map_err(|e| e.to_string())
    };
    let met = tokio::time::timeout(PROBE_TIMEOUT, async { tokio::try_join!(dialed, accepted) }).await;
    let result = match met {
        Ok(Ok((conn, _accepted))) => {
            conn.close(0u32.into(), b"probe");
            ProbeResult::Ok
        }
        _ => ProbeResult::EndpointFailed,
    };
    let _ = tokio::time::timeout(CLOSE_TIMEOUT, probe.close()).await;
    result
}

