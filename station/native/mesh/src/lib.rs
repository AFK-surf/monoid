//! The station's iroh for the station in TypeScript (docs/station-ts-native.md §3): its endpoint as
//! mesh/station/src/main.rs `serve_mesh` makes it (the station's key, its relays, found on the LAN by mDNS and by relay
//! through the Mainline DHT, Cubic by default with a 256 KiB initial window), home on every one of its relays at once
//! (one connection to it has a path through each, PATH_IDLE), keepers on relays added since (keep.rs), connections both
//! ways and their streams. Which relays, when to add iroh's public ones, who may connect and what is said: the
//! TypeScript's. And the image codecs of the thumbnails (thumbs.rs).

mod keep;
mod thumbs;
mod local;
mod usage;
mod verify;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use iroh::address_lookup::{AddressLookup, AddressLookupBuilder, AddressLookupBuilderError, EndpointData, Error as AddressLookupError, Item as AddressLookupItem};
use iroh::endpoint::{Connection as IrohConnection, QuicTransportConfig, RecvStream, SendStream, presets::Minimal};
use iroh::address_lookup::EndpointInfo;
use iroh::{Endpoint as IrohEndpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, TransportAddr, Watcher};
use n0_future::StreamExt;
use n0_future::boxed::BoxStream;
use napi::bindgen_prelude::{Buffer, Promise};
use napi_derive::napi;
use tokio::sync::Mutex;

const MDNS_SERVICE: &str = "stillfail";

/// The nodes a DHT starts from: n0-mainline's defaults, with ours (cloud/dht-node, on the relays' machines) in place of relay.pkarr.org.
fn dht() -> n0_mainline::DhtBuilder {
    let mut dht = n0_mainline::DhtBuilder::default();
    dht.bootstrap(&[
        "router.bittorrent.com:6881",
        "dht.transmissionbt.com:6881",
        "dht.libtorrent.org:25401",
        "39.105.157.122:6881",
        "47.79.40.84:6881",
        "120.24.233.158:6881",
    ]);
    dht
}

fn failed(error: impl std::fmt::Display) -> napi::Error {
    napi::Error::from_reason(error.to_string())
}

/// How often each path of a connection is kept alive, and how long one may hear nothing before it is given up: its
/// packets go on on another path meanwhile (another relay, direct), and a relay's is opened again as it comes back.
/// iroh's own (5 s, 15 s; 30 s for a relay's) held a connection on a way that was gone that long (a relay down, a path
/// punched through that stopped answering), every stream on it waiting.
const PATH_KEEP_ALIVE: Duration = Duration::from_secs(1);
const PATH_IDLE: Duration = Duration::from_secs(3);
/// How long a connection may hear nothing before it is given up: with iroh's 30 s, a phone's app frozen in the background
/// that long came back to every link timed out and dialled each anew (2026-11-08). The peers take the lower of theirs.
const CONNECTION_IDLE_MS: u32 = 10 * 60_000;

fn relay_url(url: &str) -> napi::Result<RelayUrl> {
    url.parse().map_err(failed)
}

#[napi(object)]
pub struct Options {
    /// The station's 32-byte key (<data>/mesh/secret.key).
    pub secret_key: Buffer,
    pub alpns: Vec<Buffer>,
    /// still.fail's relays, ours first; none: relays off (tests on one machine).
    pub relay_urls: Vec<String>,
    /// Alternative addresses into the same relays, used by client endpoints.
    pub relay_entries: Option<Vec<RelayEntry>>,
    /// Found on the LAN and through the DHT, as a station is. Off for tests.
    pub discovery: Option<bool>,
    /// Where to listen; any free port when not said.
    pub bind_addr: Option<String>,
    /// A client's endpoint (the core in TypeScript, client/core-ts): it looks stations up on the LAN and in the DHT
    /// without being announced itself (a device is never dialed).
    pub lookup: Option<bool>,
    /// Relays alone, no IP transports: what measures the way through a relay must not go direct.
    pub relay_only: Option<bool>,
    /// Advanced choice, cubic by default; read when the endpoint is created.
    pub congestion: Option<String>,
}

#[napi(object)]
pub struct RelayEntry {
    pub entry: String,
    pub relay: String,
}

#[napi]
pub struct Endpoint {
    /// iroh's endpoint: another in its place, of the same key, once bound again on other relays (`rebind_relays`).
    inner: StdMutex<IrohEndpoint>,
    /// What it was bound with but its relays, to bind it again so.
    made: Made,
    keepers: Arc<StdMutex<HashMap<String, tokio::task::JoinHandle<()>>>>,
    /// The relays it was bound with: home on each, no keeper wanted there.
    homes: StdMutex<Vec<RelayUrl>>,
    /// Connections coming that are held unanswered, not even their handshake (`hold_incoming`), and those held.
    held: Arc<StdMutex<(u32, Vec<iroh::endpoint::Incoming>)>>,
    /// The connections whose handshakes are done, as each finishes (`accept`), once one was first asked for; and where
    /// those of an endpoint bound again in its place go too, till it is closed.
    accepted: Arc<Mutex<Option<tokio::sync::mpsc::UnboundedReceiver<IrohConnection>>>>,
    giving: StdMutex<Option<tokio::sync::mpsc::UnboundedSender<IrohConnection>>>,
    /// The relays the DHT may say a peer is on (`RelayFilter`).
    filter: Arc<StdMutex<RelayFilter>>,
    /// One binding again at a time.
    rebinding: Mutex<()>,
}

/// What an endpoint is bound with but its relays (`bind`), kept to bind it again on others (`rebind_relays`).
struct Made {
    key: SecretKey,
    alpns: Vec<Vec<u8>>,
    entries: Vec<(RelayUrl, RelayUrl)>,
    bind_addr: Option<std::net::SocketAddr>,
    relay_only: bool,
    lookup: bool,
    discovery: bool,
    /// As `set_congestion` changed it since.
    congestion: StdMutex<String>,
}

/// The relays a station's address lookup (the DHT) may say a peer is on: those the station dials that peer by
/// (`connect`'s `relays`), else those it is on itself; any while iroh's public relays are on (none of its own answers,
/// so any way may do). A peer that is also of a workspace of another station's that did not turn a relay off, or the
/// DHT's record of before it was, would otherwise have this endpoint dial it through a relay the station's workspace
/// turned off (iroh resolves an address with no path chosen, and takes every relay it is told). Its IP addresses are
/// kept: what is found on a LAN or punched through is no relay.
#[derive(Debug, Default)]
struct RelayFilter {
    endpoint: HashSet<RelayUrl>,
    peers: HashMap<EndpointId, HashSet<RelayUrl>>,
    public_on: bool,
}

impl RelayFilter {
    /// What of `item` may be dialed: none of it where it said only relays not allowed.
    fn item(&self, item: AddressLookupItem) -> Option<AddressLookupItem> {
        if self.public_on {
            return Some(item);
        }
        let allowed = self.peers.get(&item.endpoint_id()).unwrap_or(&self.endpoint);
        let data = &item.endpoint_info().data;
        let all = data.addrs().count();
        let addrs: Vec<TransportAddr> = data.addrs().filter(|a| !matches!(a, TransportAddr::Relay(url) if !allowed.contains(url))).cloned().collect();
        if addrs.is_empty() {
            return None;
        }
        if addrs.len() == all {
            return Some(item);
        }
        let mut kept = EndpointData::new(addrs);
        kept.set_user_data(data.user_data().cloned());
        Some(AddressLookupItem::new(EndpointInfo::from_parts(item.endpoint_id(), kept), item.provenance(), item.last_updated()))
    }
}

/// An address lookup whose findings go through the endpoint's `RelayFilter`; made of a builder by `Holding`.
#[derive(Debug)]
struct Filtered<L>(L, Arc<StdMutex<RelayFilter>>);

#[derive(Debug)]
struct Holding<B>(B, Arc<StdMutex<RelayFilter>>);

impl<B: AddressLookupBuilder> AddressLookupBuilder for Holding<B> {
    fn into_address_lookup(self, endpoint: &IrohEndpoint) -> Result<impl AddressLookup, AddressLookupBuilderError> {
        Ok(Filtered(self.0.into_address_lookup(endpoint)?, self.1))
    }
}

impl<L: AddressLookup> AddressLookup for Filtered<L> {
    fn publish(&self, data: &EndpointData) {
        self.0.publish(data);
    }

    fn resolve(&self, endpoint_id: EndpointId) -> Option<BoxStream<Result<AddressLookupItem, AddressLookupError>>> {
        let filter = self.1.clone();
        let found = self.0.resolve(endpoint_id)?;
        Some(
            found
                .filter_map(move |r| match r {
                    Ok(item) => filter.lock().unwrap().item(item).map(Ok),
                    Err(e) => Some(Err(e)),
                })
                .boxed(),
        )
    }
}

/// The connections' transport: the congestion controller named (BBR is opt-in: noq 1.3.0 can underestimate bandwidth
/// after idle, n0-computer/noq#852), the paths kept alive and given up as PATH_KEEP_ALIVE and PATH_IDLE say.
fn transport(congestion: &str) -> napi::Result<QuicTransportConfig> {
    let controller: Arc<dyn noq_proto::congestion::ControllerFactory + Send + Sync> = match congestion {
        "cubic" => {
            let mut config = noq_proto::congestion::CubicConfig::default();
            config.initial_window(256 * 1024);
            Arc::new(config)
        }
        "bbr" => {
            let mut config = noq_proto::congestion::Bbr3Config::default();
            config.initial_window(256 * 1024);
            Arc::new(config)
        }
        _ => return Err(failed("congestion: expected cubic or bbr")),
    };
    Ok(QuicTransportConfig::builder()
        .congestion_controller_factory(controller)
        .default_path_keep_alive_interval(PATH_KEEP_ALIVE)
        .default_path_max_idle_timeout(PATH_IDLE)
        .max_idle_timeout(Some(iroh::endpoint::VarInt::from_u32(CONNECTION_IDLE_MS).into()))
        .build())
}

/// A way of finding stations (mDNS on the LAN, the DHT) that could not be made leaves the endpoint without it, said,
/// instead of failing the endpoint: mDNS binds UDP 5353 on the machine's networks, which fails with none up yet (a
/// Windows station started at logon before its network) or the port held by another program, and the endpoint failing
/// left the station off the mesh, and offline, until it was restarted.
#[derive(Debug)]
struct Optional<B>(&'static str, B);

#[derive(Debug)]
struct Unmade<L>(Option<L>);

impl<B: AddressLookupBuilder> AddressLookupBuilder for Optional<B> {
    fn into_address_lookup(self, endpoint: &IrohEndpoint) -> Result<impl AddressLookup, AddressLookupBuilderError> {
        Ok(Unmade(match self.1.into_address_lookup(endpoint) {
            Ok(lookup) => Some(lookup),
            Err(error) => {
                eprintln!("mesh: stations not found through {}: {error:#}", self.0);
                None
            }
        }))
    }
}

impl<L: AddressLookup> AddressLookup for Unmade<L> {
    fn publish(&self, data: &EndpointData) {
        if let Some(lookup) = &self.0 {
            lookup.publish(data);
        }
    }

    fn resolve(&self, endpoint_id: EndpointId) -> Option<BoxStream<Result<AddressLookupItem, AddressLookupError>>> {
        self.0.as_ref().and_then(|lookup| lookup.resolve(endpoint_id))
    }
}

#[napi]
pub async fn bind(options: Options) -> napi::Result<Endpoint> {
    let bytes: [u8; 32] = options.secret_key.as_ref().try_into().map_err(|_| failed("the key is not 32 bytes"))?;
    let relays: Vec<RelayUrl> = options.relay_urls.iter().map(|u| relay_url(u)).collect::<Result<_, _>>()?;
    let entries: Vec<(RelayUrl, RelayUrl)> = options.relay_entries.unwrap_or_default().iter().map(|e| Ok((relay_url(&e.entry)?, relay_url(&e.relay)?))).collect::<napi::Result<_>>()?;
    let bind_addr = options.bind_addr.as_deref().map(|a| a.parse::<std::net::SocketAddr>().map_err(failed)).transpose()?;
    let congestion = options.congestion.unwrap_or_else(|| "cubic".into());
    transport(&congestion)?;
    let made = Made {
        key: SecretKey::from_bytes(&bytes),
        alpns: options.alpns.iter().map(|a| a.to_vec()).collect(),
        entries,
        bind_addr,
        relay_only: options.relay_only.unwrap_or(false),
        lookup: options.lookup.unwrap_or(false),
        discovery: options.discovery.unwrap_or(true),
        congestion: StdMutex::new(congestion),
    };
    let filter = Arc::new(StdMutex::new(RelayFilter { endpoint: relays.iter().cloned().collect(), ..RelayFilter::default() }));
    let inner = made.bind(&relays, &filter).await?;
    Ok(Endpoint {
        inner: StdMutex::new(inner),
        made,
        keepers: Arc::default(),
        homes: StdMutex::new(relays),
        held: Arc::default(),
        accepted: Arc::default(),
        giving: StdMutex::new(None),
        filter,
        rebinding: Mutex::new(()),
    })
}

impl Made {
    /// iroh's endpoint, bound on `relays` (home on each).
    async fn bind(&self, relays: &[RelayUrl], filter: &Arc<StdMutex<RelayFilter>>) -> napi::Result<IrohEndpoint> {
        let relay_map = iroh::RelayMap::from_iter(relays.iter().map(|relay| {
            iroh::RelayConfig::from(relay.clone()).with_entries(self.entries.iter().filter(|(_, target)| target == relay).map(|(entry, _)| entry.clone()))
        }));
        let transport = transport(&self.congestion.lock().unwrap())?;
        let mut builder = IrohEndpoint::builder(Minimal)
            .secret_key(self.key.clone())
            .alpns(self.alpns.clone())
            .relay_mode(if relays.is_empty() { RelayMode::Disabled } else { RelayMode::Custom(relay_map) })
            .home_on_every_relay()
            .transport_config(transport);
        if let Some(addr) = self.bind_addr {
            builder = builder.bind_addr(addr).map_err(failed)?;
        }
        if self.relay_only {
            builder = builder.clear_ip_transports();
        }
        if self.lookup && !relays.is_empty() {
            builder = builder
                .address_lookup(Optional("mDNS", iroh_mdns_address_lookup::MdnsAddressLookup::builder().service_name(MDNS_SERVICE).advertise(false)))
                .address_lookup(Optional("the DHT", iroh_mainline_address_lookup::DhtAddressLookup::builder().dht_builder(dht()).no_publish()));
        } else if self.discovery {
            // (the DHT's findings held to the relays the station's workspaces go by: RelayFilter)
            builder = builder
                .address_lookup(Optional("mDNS", iroh_mdns_address_lookup::MdnsAddressLookup::builder().service_name(MDNS_SERVICE)))
                .address_lookup(Holding(Optional("the DHT", iroh_mainline_address_lookup::DhtAddressLookup::builder().dht_builder(dht()).secret_key(self.key.clone())), filter.clone()));
        }
        builder.bind().await.map_err(failed)
    }
}

/// The connections coming to `endpoint`, each given to `tx` as its handshake is done, till it closes. Handshakes go on
/// side by side, each on its own (`Endpoint::accept` says why).
fn accepting(endpoint: IrohEndpoint, held: Arc<StdMutex<(u32, Vec<iroh::endpoint::Incoming>)>>, tx: tokio::sync::mpsc::UnboundedSender<IrohConnection>) {
    napi::bindgen_prelude::spawn(async move {
        while let Some(incoming) = endpoint.accept().await {
            {
                let mut held = held.lock().unwrap();
                if held.0 > 0 {
                    held.0 -= 1;
                    held.1.push(incoming);
                    continue;
                }
            }
            let tx = tx.clone();
            napi::bindgen_prelude::spawn(async move {
                // One whose handshake fails is said, where it came from and how long it took: a device whose
                // dials to the station never got through said nothing here, which way its packets came or
                // whether any came at all (2026-10-29).
                let from = incoming.remote_addr();
                let started = Instant::now();
                match incoming.await {
                    Ok(conn) => {
                        let _ = tx.send(conn);
                    }
                    Err(error) => eprintln!("mesh: a connection's handshake failed from {from:?} after {} ms: {error:#}", started.elapsed().as_millis()),
                }
            });
        }
    });
}

#[napi(object)]
pub struct Addr {
    /// The endpoint's id (hex).
    pub id: String,
    pub relays: Option<Vec<String>>,
    /// `ip:port`, each.
    pub ips: Option<Vec<String>>,
}

fn endpoint_addr(addr: &Addr) -> napi::Result<EndpointAddr> {
    let bytes: [u8; 32] = hex::decode(&addr.id).map_err(failed)?.try_into().map_err(|_| failed("the id is not 32 bytes"))?;
    let id = EndpointId::from_bytes(&bytes).map_err(failed)?;
    let mut out = EndpointAddr::new(id);
    for url in addr.relays.iter().flatten() {
        out = out.with_relay_url(relay_url(url)?);
    }
    for ip in addr.ips.iter().flatten() {
        out = out.with_ip_addr(ip.parse::<std::net::SocketAddr>().map_err(failed)?);
    }
    Ok(out)
}

#[napi]
impl Endpoint {
    /// iroh's endpoint as it is now.
    fn inner(&self) -> IrohEndpoint {
        self.inner.lock().unwrap().clone()
    }

    /// Its id, as the station's (hex).
    #[napi]
    pub fn id(&self) -> String {
        hex::encode(self.inner().id().as_bytes())
    }

    /// Where it listens on this machine: `ip:port`, each.
    #[napi]
    pub fn sockets(&self) -> Vec<String> {
        self.inner().bound_sockets().iter().map(ToString::to_string).collect()
    }

    /// Resolves once it is on its home relay (at once with relays off).
    #[napi]
    pub async fn online(&self) {
        self.inner().online().await;
    }

    /// Its home relay now, if it has one.
    #[napi]
    pub fn home(&self) -> Option<String> {
        self.inner().home_relay_status().get().first().map(|s| s.url().to_string())
    }

    #[napi]
    pub async fn insert_relay(&self, url: String) -> napi::Result<()> {
        let url = relay_url(&url)?;
        self.filter.lock().unwrap().endpoint.insert(url.clone());
        self.inner().insert_relay(url.clone(), Arc::new(iroh::RelayConfig::from(url))).await;
        Ok(())
    }

    #[napi]
    pub async fn remove_relay(&self, url: String) -> napi::Result<()> {
        let url = relay_url(&url)?;
        self.filter.lock().unwrap().endpoint.remove(&url);
        self.inner().remove_relay(&url).await;
        Ok(())
    }

    /// The congestion controller of the connections made from now on, dialed and accepted (one made keeps its own):
    /// the advanced network setting changed while the station runs.
    #[napi]
    pub fn set_congestion(&self, congestion: String) -> napi::Result<()> {
        self.inner().set_transport_config(transport(&congestion)?);
        *self.made.congestion.lock().unwrap() = congestion;
        Ok(())
    }

    /// iroh's own public relays: added while none of still.fail's answers, removed once one does (`keep_relays`).
    #[napi]
    pub async fn public_relays(&self, on: bool) {
        self.filter.lock().unwrap().public_on = on;
        let public: Vec<Arc<iroh::RelayConfig>> = iroh::defaults::prod::default_relay_map().relays();
        for config in public {
            if on {
                self.inner().insert_relay(config.url.clone(), config.clone()).await;
            } else {
                self.inner().remove_relay(&config.url).await;
            }
        }
    }

    /// Keeps the station on exactly these relays, besides those it is home on (bound with): a keeper for each new one
    /// (keep.rs), those of relays no longer named stopped.
    #[napi]
    pub fn keep(&self, urls: Vec<String>) -> napi::Result<()> {
        let mut relays: Vec<RelayUrl> = urls.iter().map(|u| relay_url(u)).collect::<Result<_, _>>()?;
        let homes = self.homes.lock().unwrap().clone();
        relays.retain(|r| !homes.contains(r));
        let urls: Vec<String> = relays.iter().map(ToString::to_string).collect();
        let mut keepers = self.keepers.lock().unwrap();
        keepers.retain(|url, task| {
            let named = urls.contains(url);
            if !named {
                task.abort();
            }
            named
        });
        for relay in relays {
            let endpoint = self.inner();
            keepers.entry(relay.to_string()).or_insert_with(|| napi::bindgen_prelude::spawn(keep::keep(endpoint, relay)));
        }
        Ok(())
    }

    /// The next `n` connections coming are never answered, not even their handshake: a device whose way here is gone,
    /// dialing (the client core's tests).
    #[napi]
    pub fn hold_incoming(&self, n: u32) {
        self.held.lock().unwrap().0 = n;
    }

    /// The next connection, its handshake done; null once the endpoint is closed. One that fails its handshake is
    /// skipped. Handshakes go on side by side, each on its own: one that is never finished (its device gone half way,
    /// as an app updating, a phone out of signal) holds up no other. Taken one at a time, every connection behind it
    /// waited until it timed out, half a minute in which the station took no one (2026-10-08: with devices dialling
    /// every way at once, stations were out of everyone's reach a minute or two at a time).
    #[napi]
    pub async fn accept(&self) -> Option<Connection> {
        let mut accepted = self.accepted.lock().await;
        let done = accepted.get_or_insert_with(|| {
            let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
            accepting(self.inner(), self.held.clone(), tx.clone());
            *self.giving.lock().unwrap() = Some(tx);
            rx
        });
        done.recv().await.map(|inner| Connection { inner })
    }

    /// A connection to another endpoint (a peer station; a station, from a client), offering `alpn` and, for one from
    /// before a rename, the `additional` ones too. `given_up`: resolves once the caller no longer waits for it (its
    /// own deadline passed), and the handshake is given up then (`dial`).
    #[napi]
    pub async fn connect(&self, addr: Addr, alpn: Buffer, additional: Option<Vec<Buffer>>, given_up: Option<Promise<()>>) -> napi::Result<Connection> {
        let options = iroh::endpoint::ConnectOptions::new().with_additional_alpns(additional.unwrap_or_default().iter().map(|a| a.to_vec()).collect());
        let given_up = async move {
            match given_up {
                Some(promise) => drop(promise.await),
                None => std::future::pending().await,
            }
        };
        let to = endpoint_addr(&addr)?;
        {
            // The relays it is dialed by are the only ones the DHT may add (RelayFilter); none said, those of the endpoint.
            let mut filter = self.filter.lock().unwrap();
            match &addr.relays {
                Some(_) => drop(filter.peers.insert(to.id, to.relay_urls().cloned().collect())),
                None => drop(filter.peers.remove(&to.id)),
            }
        }
        let conn = dial(&self.inner(), to, &alpn, options, given_up).await.map_err(failed)?;
        Ok(Connection { inner: conn })
    }

    /// Tells it where an endpoint is without looking it up (tests, a LAN with no relay).
    #[napi]
    pub fn add_addr(&self, addr: Addr) -> napi::Result<()> {
        let addr = endpoint_addr(&addr)?;
        let inner = self.inner();
        let lookup = inner.address_lookup().map_err(failed)?;
        lookup.add(iroh::address_lookup::MemoryLookup::from_endpoint_info([addr]));
        Ok(())
    }

    /// Replace forwarding entrances without closing the endpoint's existing connections.
    #[napi]
    pub async fn set_relay_entries(&self, entries: Vec<RelayEntry>) -> napi::Result<()> {
        let mut grouped = BTreeMap::<RelayUrl, Vec<RelayUrl>>::new();
        for entry in entries {
            grouped.entry(relay_url(&entry.relay)?).or_default().push(relay_url(&entry.entry)?);
        }
        self.inner().set_relay_entries(grouped.into_iter().collect()).await;
        Ok(())
    }

    /// The network changed (a phone's, after it slept): its sockets and relay connection looked at anew.
    #[napi]
    pub async fn network_change(&self) {
        self.inner().network_change().await;
    }

    /// Its home relays, and whether it is connected to each now (and held inactive there for another endpoint of its id).
    #[napi]
    pub fn relay_status(&self) -> Vec<RelayState> {
        self.inner().home_relay_status().get().iter().map(|s| RelayState { url: s.url().to_string(), connected: s.is_connected(), access: s.access_url().to_string(), conflict: s.same_endpoint_id_connected() }).collect()
    }

    /// Bound again as it was, on `urls` alone: what takes a relay it is home on off it, which `remove_relay` does not
    /// (iroh's `Transports::bind` gives each relay it is bound with a relay map of its own, and the transport it homes
    /// with tells a relay no longer named nothing). The same key, so the same id; its connections end with the endpoint
    /// let go, and are dialed again. Its keepers stop (`keep` starts those wanted). One holding a fixed port lets it go
    /// first, and where it cannot be bound so is bound again as it was; another is bound before the old one goes.
    /// What `accept` gives from then on comes of the new one too.
    #[napi]
    pub async fn rebind_relays(&self, urls: Vec<String>) -> napi::Result<()> {
        let relays: Vec<RelayUrl> = urls.iter().map(|u| relay_url(u)).collect::<Result<_, _>>()?;
        let _one = self.rebinding.lock().await;
        let old = self.inner();
        let was = self.homes.lock().unwrap().clone();
        for (_, task) in self.keepers.lock().unwrap().drain() {
            task.abort();
        }
        let fixed = self.made.bind_addr.is_some_and(|a| a.port() != 0);
        if fixed {
            old.close().await;
        }
        let new = match self.made.bind(&relays, &self.filter).await {
            Ok(new) => new,
            Err(error) if fixed => {
                eprintln!("mesh: not bound again on {urls:?}: {error}; bound as it was");
                let again = self.made.bind(&was, &self.filter).await?;
                *self.inner.lock().unwrap() = again.clone();
                if let Some(tx) = self.giving.lock().unwrap().clone() {
                    accepting(again, self.held.clone(), tx);
                }
                return Err(error);
            }
            Err(error) => return Err(error),
        };
        *self.inner.lock().unwrap() = new.clone();
        *self.homes.lock().unwrap() = relays.clone();
        {
            let mut filter = self.filter.lock().unwrap();
            filter.endpoint = relays.iter().cloned().collect();
            filter.public_on = false;
        }
        if let Some(tx) = self.giving.lock().unwrap().clone() {
            accepting(new, self.held.clone(), tx);
        }
        if !fixed {
            // (its close waits on every connection, up to seconds: not waited for)
            napi::bindgen_prelude::spawn(async move { old.close().await });
        }
        Ok(())
    }

    #[napi]
    pub async fn close(&self) {
        for (_, task) in self.keepers.lock().unwrap().drain() {
            task.abort();
        }
        // (accept answers none once the endpoint's own accepting ends)
        self.giving.lock().unwrap().take();
        self.inner().close().await;
    }
}

/// A dial's handshake, given up as `given_up` resolves: its `Connecting` dropped, which closes it, so it sends no more
/// Initials. The handshake is otherwise bounded only by the connection's idle timeout (CONNECTION_IDLE_MS): a dial its
/// caller stopped waiting for (the app's after CONNECT_TIMEOUT_MS) went on retransmitting to every relay and address of
/// the station for ten minutes, a dozen such filled the endpoint's queue of what it sends to that station and dropped
/// what the connections that did come up sent, one of them came up tens of seconds late over a relay that answered
/// once and stood dead for ten minutes, and the endpoint's close waited for all of them (2026-11-12, a station
/// restarted while a device viewed its screen).
async fn dial(
    endpoint: &IrohEndpoint,
    addr: EndpointAddr,
    alpn: &[u8],
    options: iroh::endpoint::ConnectOptions,
    given_up: impl std::future::Future<Output = ()>,
) -> anyhow::Result<IrohConnection> {
    let handshake = async {
        let connecting = endpoint.connect_with_opts(addr, alpn, options).await?;
        anyhow::Ok(connecting.await?)
    };
    tokio::select! {
        biased;
        conn = handshake => conn,
        () = given_up => Err(anyhow::anyhow!("given up")),
    }
}

#[napi(object)]
pub struct RelayState {
    pub url: String,
    pub connected: bool,
    pub access: String,
    /// The relay holds this endpoint's connection inactive: another endpoint with its secret key connected after it
    /// (a second station on the same key: another machine with a copy of its data, a front left from before).
    pub conflict: bool,
}

/// One way a connection can go: through a relay (its URL) or direct; the one chosen now, its round trip, and the
/// packets sent and lost on it alone (the connection's own counts take in every way it tried and dropped too).
#[napi(object)]
pub struct PathState {
    pub id: String,
    pub selected: bool,
    pub relay: Option<String>,
    /// A direct way's address at the other end (`ip:port`).
    pub ip: Option<String>,
    pub rtt_ms: Option<f64>,
    pub tx_packets: f64,
    pub lost_packets: f64,
    /// How much its sender may have unacknowledged on it now (bytes), and how many times it was cut for loss.
    pub cwnd: f64,
    pub congestion_events: f64,
}

/// What went over a connection since it opened, both ways: bytes, packets, and of the frames in them those that
/// carry nothing (pings, ACK requests, ACKs) and those that carry something (stream data, datagrams, the handshake's).
/// A connection that only trades the first kind, thousands of packets a second, is a storm (mesh/storms.ts).
#[napi(object)]
pub struct Stats {
    pub rx_bytes: f64,
    pub tx_bytes: f64,
    pub rx_packets: f64,
    pub tx_packets: f64,
    pub rx_pings: f64,
    pub tx_pings: f64,
    pub rx_ack_requests: f64,
    pub tx_ack_requests: f64,
    pub rx_acks: f64,
    pub tx_acks: f64,
    pub rx_data: f64,
    pub tx_data: f64,
}

/// Why a connection went: `application` (the other end closed it, saying `reason`), `local`, `timeout`, or `other`
/// (`reason` in words).
#[napi(object)]
pub struct CloseInfo {
    pub kind: String,
    pub reason: String,
}

fn close_info(error: &iroh::endpoint::ConnectionError) -> CloseInfo {
    use iroh::endpoint::ConnectionError;
    match error {
        ConnectionError::ApplicationClosed(close) => CloseInfo { kind: "application".into(), reason: String::from_utf8_lossy(&close.reason).into_owned() },
        ConnectionError::LocallyClosed => CloseInfo { kind: "local".into(), reason: String::new() },
        ConnectionError::TimedOut => CloseInfo { kind: "timeout".into(), reason: String::new() },
        other => CloseInfo { kind: "other".into(), reason: other.to_string() },
    }
}

#[napi]
pub struct Connection {
    inner: IrohConnection,
}

#[napi]
impl Connection {
    /// The device at the other end (hex).
    #[napi]
    pub fn remote_id(&self) -> String {
        hex::encode(self.inner.remote_id().as_bytes())
    }

    #[napi]
    pub fn alpn(&self) -> Buffer {
        self.inner.alpn().to_vec().into()
    }

    /// How it runs now: "relay", "direct", or null while none is chosen.
    #[napi]
    pub fn via(&self) -> Option<String> {
        self.inner.paths().iter().find(|p| p.is_selected()).map(|p| if p.is_relay() { "relay" } else { "direct" }.to_string())
    }

    /// The next stream the other end opened; null once the connection is gone.
    #[napi]
    pub async fn accept_bi(&self) -> Option<Stream> {
        let (send, recv) = self.inner.accept_bi().await.ok()?;
        Some(Stream::new(send, recv))
    }

    #[napi]
    pub async fn open_bi(&self) -> napi::Result<Stream> {
        let (send, recv) = self.inner.open_bi().await.map_err(failed)?;
        Ok(Stream::new(send, recv))
    }

    #[napi]
    pub fn close(&self, code: u32, reason: String) {
        self.inner.close(code.into(), reason.as_bytes());
    }

    /// Whether it is gone already.
    #[napi]
    pub fn is_closed(&self) -> bool {
        self.inner.close_reason().is_some()
    }

    /// Resolves when it is gone, with why.
    #[napi]
    pub async fn closed(&self) -> String {
        self.inner.closed().await.to_string()
    }

    /// Resolves when it is gone, with why, told apart (`CloseInfo`).
    #[napi]
    pub async fn closed_info(&self) -> CloseInfo {
        close_info(&self.inner.closed().await)
    }

    /// Why it is gone, if it is.
    #[napi]
    pub fn close_reason(&self) -> Option<CloseInfo> {
        self.inner.close_reason().map(|e| close_info(&e))
    }

    /// Every way it can go now.
    #[napi]
    pub fn paths(&self) -> Vec<PathState> {
        self.inner.paths().iter().map(|p| {
            let stats = p.stats();
            PathState {
                id: p.id().to_string(),
                selected: p.is_selected(),
                relay: match p.remote_addr() {
                    iroh::TransportAddr::Relay(url) => Some(url.to_string()),
                    _ => None,
                },
                ip: match p.remote_addr() {
                    iroh::TransportAddr::Ip(addr) => Some(addr.to_string()),
                    _ => None,
                },
                rtt_ms: stats.same_path_rtt.map(|rtt| rtt.as_secs_f64() * 1000.0),
                tx_packets: stats.udp_tx.datagrams as f64,
                lost_packets: stats.lost_packets as f64,
                cwnd: stats.cwnd as f64,
                congestion_events: stats.congestion_events as f64,
            }
        }).collect()
    }

    /// Whether the other end is still there: asked with a datagram (which a live end acknowledges at once) a few times
    /// within `within_ms`, true as soon as anything is heard from it. A process killed with the connection open says
    /// nothing, and the connection would only go at QUIC's idle timeout (CONNECTION_IDLE_MS). An end that takes no
    /// datagrams is not asked, and counts as there.
    #[napi]
    pub async fn answers(&self, within_ms: u32) -> bool {
        let heard = self.inner.stats().udp_rx.datagrams;
        let within = Duration::from_millis(within_ms.into());
        let deadline = Instant::now() + within;
        let mut ask = Instant::now();
        loop {
            if self.inner.close_reason().is_some() {
                return false;
            }
            if self.inner.stats().udp_rx.datagrams > heard {
                return true;
            }
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            if now >= ask {
                match self.inner.send_datagram(bytes::Bytes::from_static(&[0])) {
                    Ok(()) => {}
                    Err(iroh::endpoint::SendDatagramError::ConnectionLost(_)) => return false,
                    Err(_) => return true,
                }
                ask = now + within / 3;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    #[napi]
    pub fn stats(&self) -> Stats {
        let stats = self.inner.stats();
        let data = |f: &iroh::endpoint::FrameStats| (f.stream + f.datagram + f.crypto) as f64;
        Stats {
            rx_bytes: stats.udp_rx.bytes as f64,
            tx_bytes: stats.udp_tx.bytes as f64,
            rx_packets: stats.udp_rx.datagrams as f64,
            tx_packets: stats.udp_tx.datagrams as f64,
            rx_pings: stats.frame_rx.ping as f64,
            tx_pings: stats.frame_tx.ping as f64,
            rx_ack_requests: stats.frame_rx.immediate_ack as f64,
            tx_ack_requests: stats.frame_tx.immediate_ack as f64,
            rx_acks: (stats.frame_rx.acks + stats.frame_rx.path_acks) as f64,
            tx_acks: (stats.frame_tx.acks + stats.frame_tx.path_acks) as f64,
            rx_data: data(&stats.frame_rx),
            tx_data: data(&stats.frame_tx),
        }
    }

    /// A stream one way: what measures a round trip sends a byte on it (mesh.rs `sample_relay_rtt`).
    #[napi]
    pub async fn open_uni(&self) -> napi::Result<UniStream> {
        let send = self.inner.open_uni().await.map_err(failed)?;
        Ok(UniStream { send: Arc::new(Mutex::new(send)) })
    }
}

#[napi]
pub struct UniStream {
    send: Arc<Mutex<SendStream>>,
}

#[napi]
impl UniStream {
    #[napi]
    pub async fn write(&self, bytes: Buffer) -> napi::Result<()> {
        self.send.lock().await.write_all(&bytes).await.map_err(failed)
    }

    #[napi]
    pub async fn finish(&self) -> napi::Result<()> {
        self.send.lock().await.finish().map_err(failed)
    }

    /// Resolves once what was sent is acknowledged: null, or the code the other end stopped it with.
    #[napi]
    pub async fn stopped(&self) -> napi::Result<Option<u32>> {
        let stopped = self.send.lock().await.stopped();
        let code = stopped.await.map_err(failed)?;
        Ok(code.map(|c| u32::try_from(c.into_inner()).unwrap_or(u32::MAX)))
    }
}

#[napi]
pub struct Stream {
    send: Arc<Mutex<SendStream>>,
    recv: Arc<Mutex<RecvStream>>,
    /// Set by `reset`: a read waiting on the other end gives up (it holds the receiving half meanwhile).
    reset: tokio::sync::watch::Sender<bool>,
}

impl Stream {
    fn new(send: SendStream, recv: RecvStream) -> Stream {
        Stream { send: Arc::new(Mutex::new(send)), recv: Arc::new(Mutex::new(recv)), reset: tokio::sync::watch::channel(false).0 }
    }
}

#[napi]
impl Stream {
    /// What came next, up to 64 KiB; null at its end (or once it was reset).
    #[napi]
    pub async fn read(&self) -> napi::Result<Option<Buffer>> {
        let mut reset = self.reset.subscribe();
        if *reset.borrow() {
            return Ok(None);
        }
        let mut buf = vec![0u8; 64 * 1024];
        let mut recv = self.recv.lock().await;
        let read = tokio::select! {
            read = recv.read(&mut buf) => read.map_err(failed)?,
            _ = reset.changed() => None,
        };
        match read {
            Some(n) => {
                buf.truncate(n);
                Ok(Some(buf.into()))
            }
            None => Ok(None),
        }
    }

    #[napi]
    pub async fn write(&self, bytes: Buffer) -> napi::Result<()> {
        self.send.lock().await.write_all(&bytes).await.map_err(failed)
    }

    #[napi]
    pub async fn finish(&self) -> napi::Result<()> {
        self.send.lock().await.finish().map_err(failed)
    }

    /// Resolves once what was sent is acknowledged: null; or the code the other end stopped reading with; or null once
    /// the stream is gone.
    #[napi]
    pub async fn stopped(&self) -> Option<u32> {
        // The future owns what it waits on: taken under the lock and awaited without it, so writes go on meanwhile.
        let stopped = self.send.lock().await.stopped();
        stopped.await.ok().flatten().map(|c| u32::try_from(c.into_inner()).unwrap_or(u32::MAX))
    }

    /// Ends it at once, both ways: a read waiting gives up first, so the receiving half can be stopped.
    #[napi]
    pub async fn reset(&self, code: u32) {
        let _ = self.reset.send(true);
        let _ = self.send.lock().await.reset(code.into());
        let _ = self.recv.lock().await.stop(code.into());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A way of finding stations that cannot be made, as mDNS is with UDP 5353 unavailable.
    #[derive(Debug)]
    struct Unavailable;

    #[derive(Debug)]
    struct Nothing;

    impl AddressLookup for Nothing {}

    impl AddressLookupBuilder for Unavailable {
        fn into_address_lookup(self, _endpoint: &IrohEndpoint) -> Result<impl AddressLookup, AddressLookupBuilderError> {
            Err::<Nothing, _>(AddressLookupBuilderError::from_err("mdns", std::io::Error::other("no network")))
        }
    }

    /// What came to `socket` since it was last asked: datagrams, counted.
    fn arrived(socket: &tokio::net::UdpSocket) -> usize {
        let mut buf = [0u8; 2048];
        let mut n = 0;
        while socket.try_recv(&mut buf).is_ok() {
            n += 1;
        }
        n
    }

    /// A dial whose caller gave up sends nothing more to the station, and the endpoint closes at once; one nobody gives
    /// up goes on retransmitting its Initial until the connection's idle timeout (CONNECTION_IDLE_MS), and the endpoint's
    /// close waits that long for it. On the test's clock (paused: it moves when nothing else can), a socket that takes
    /// every datagram and answers none in place of the station.
    #[tokio::test(start_paused = true)]
    async fn a_dial_given_up_sends_no_more() {
        let quiet = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let station = EndpointAddr::new(SecretKey::from_bytes(&[7; 32]).public()).with_ip_addr(quiet.local_addr().unwrap());
        let endpoint = IrohEndpoint::builder(Minimal).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let (give_up, given_up) = tokio::sync::oneshot::channel::<()>();
        let dialing = tokio::spawn({
            let endpoint = endpoint.clone();
            async move { dial(&endpoint, station, b"test", iroh::endpoint::ConnectOptions::new(), async { drop(given_up.await) }).await }
        });
        // The app's CONNECT_TIMEOUT_MS: its Initial sent, and again as nothing answers.
        tokio::time::sleep(Duration::from_secs(10)).await;
        assert!(arrived(&quiet) >= 2, "the dial sent its Initial and retransmitted it");
        give_up.send(()).unwrap();
        assert_eq!(dialing.await.unwrap().unwrap_err().to_string(), "given up");
        // What its close sends, then nothing for the rest of the ten minutes.
        tokio::time::sleep(Duration::from_secs(1)).await;
        arrived(&quiet);
        tokio::time::sleep(Duration::from_millis(CONNECTION_IDLE_MS.into())).await;
        assert_eq!(arrived(&quiet), 0, "a dial given up went on sending");
        let closing = tokio::time::Instant::now();
        endpoint.close().await;
        assert!(closing.elapsed() < Duration::from_secs(5), "the endpoint's close waited {:?}", closing.elapsed());
    }

    /// A DHT saying a peer is at these addresses.
    #[derive(Debug)]
    struct Says(Vec<TransportAddr>);

    impl AddressLookup for Says {
        fn resolve(&self, endpoint_id: EndpointId) -> Option<BoxStream<Result<AddressLookupItem, AddressLookupError>>> {
            let item = AddressLookupItem::new(EndpointInfo::from_parts(endpoint_id, EndpointData::new(self.0.clone())), "dht", Some(7));
            Some(n0_future::stream::iter([Ok(item)]).boxed())
        }
    }

    /// What `lookup` finds of `id`: each finding's addresses, its provenance and when it was updated.
    async fn found(lookup: &impl AddressLookup, id: EndpointId) -> Vec<(Vec<TransportAddr>, &'static str, Option<u64>)> {
        lookup.resolve(id).unwrap().filter_map(|r| r.ok()).map(|i| (i.endpoint_info().data.addrs().cloned().collect(), i.provenance(), i.last_updated())).collect::<Vec<_>>().await
    }

    /// The DHT's record of a peer (another workspace of its that kept still.fail's relays on, or one of before they
    /// were turned off) adds none of the relays the station does not go by: those of the endpoint, else those the peer
    /// is dialed by; its IP addresses stay, and everything while iroh's public relays are on.
    #[tokio::test]
    async fn the_dht_adds_no_relay_turned_off() {
        let off: RelayUrl = "https://relay.still.example".parse().unwrap();
        let own: RelayUrl = "https://relay.own.example".parse().unwrap();
        let ip: std::net::SocketAddr = "192.168.1.9:4433".parse().unwrap();
        let peer = SecretKey::from_bytes(&[9; 32]).public();
        let filter = Arc::new(StdMutex::new(RelayFilter { endpoint: [own.clone()].into(), ..RelayFilter::default() }));
        let all = vec![TransportAddr::Relay(off.clone()), TransportAddr::Relay(own.clone()), TransportAddr::Ip(ip)];
        let dht = Filtered(Says(all.clone()), filter.clone());
        assert_eq!(found(&dht, peer).await, vec![(vec![TransportAddr::Relay(own.clone()), TransportAddr::Ip(ip)], "dht", Some(7))]);
        assert!(found(&Filtered(Says(vec![TransportAddr::Relay(off.clone())]), filter.clone()), peer).await.is_empty(), "nothing left: no finding");
        // Dialed by relays of its own (`connect`'s): those, whatever the endpoint is on.
        filter.lock().unwrap().peers.insert(peer, [off.clone()].into());
        assert_eq!(found(&dht, peer).await[0].0, vec![TransportAddr::Relay(off.clone()), TransportAddr::Ip(ip)]);
        filter.lock().unwrap().peers.insert(peer, HashSet::new());
        assert_eq!(found(&dht, peer).await[0].0, vec![TransportAddr::Ip(ip)]);
        // iroh's public relays on: as it was found.
        filter.lock().unwrap().public_on = true;
        assert_eq!(found(&dht, peer).await[0].0, all);
    }

    /// Bound again on fewer relays: the same id, its relays and what the DHT may add those alone, and what comes to the
    /// endpoint bound in its place given by the same `accept`.
    #[tokio::test]
    async fn bound_again_on_other_relays() {
        let (a, b) = ("http://127.0.0.1:9/".to_string(), "http://127.0.0.1:10/".to_string());
        let options = Options {
            secret_key: vec![5u8; 32].into(),
            alpns: vec![b"test".to_vec().into()],
            relay_urls: vec![a.clone(), b.clone()],
            relay_entries: None,
            discovery: Some(false),
            bind_addr: Some("127.0.0.1:0".into()),
            lookup: None,
            relay_only: None,
            congestion: None,
        };
        let endpoint = bind(options).await.unwrap();
        let id = endpoint.id();
        let accepting = endpoint.accept();
        let first = tokio::time::timeout(Duration::from_millis(10), accepting).await;
        assert!(first.is_err(), "nothing came yet");
        endpoint.rebind_relays(vec![b.clone()]).await.unwrap();
        assert_eq!(endpoint.id(), id);
        assert_eq!(*endpoint.homes.lock().unwrap(), vec![relay_url(&b).unwrap()]);
        assert_eq!(endpoint.filter.lock().unwrap().endpoint, [relay_url(&b).unwrap()].into());
        let socket: std::net::SocketAddr = endpoint.sockets().iter().find_map(|s| s.parse().ok().filter(|a: &std::net::SocketAddr| a.is_ipv4())).unwrap();
        let client = IrohEndpoint::builder(Minimal).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let to = EndpointAddr::new(endpoint.inner().id()).with_ip_addr(std::net::SocketAddr::from(([127, 0, 0, 1], socket.port())));
        let dialing = tokio::spawn({
            let client = client.clone();
            async move { client.connect(to, b"test").await.map(|c| c.remote_id()) }
        });
        let came = tokio::time::timeout(Duration::from_secs(10), endpoint.accept()).await.expect("accepted in time").expect("a connection");
        assert_eq!(came.inner.remote_id(), client.id());
        assert_eq!(dialing.await.unwrap().unwrap(), endpoint.inner().id());
        endpoint.close().await;
        assert!(tokio::time::timeout(Duration::from_secs(10), endpoint.accept()).await.expect("answered once closed").is_none());
        client.close().await;
    }

    #[tokio::test]
    async fn an_unmade_lookup_leaves_the_endpoint_up() {
        let failing = IrohEndpoint::builder(Minimal).relay_mode(RelayMode::Disabled).address_lookup(Unavailable).bind().await;
        assert!(failing.is_err(), "iroh fails an endpoint whose lookup is not made");
        let endpoint = IrohEndpoint::builder(Minimal).relay_mode(RelayMode::Disabled).address_lookup(Optional("mDNS", Unavailable)).bind().await;
        assert!(endpoint.is_ok(), "{:?}", endpoint.err());
        endpoint.unwrap().close().await;
    }
}
