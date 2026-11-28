//! On-demand routes for encrypted endpoint packets.
mod fragments;
pub mod routing;
pub mod runtime;
pub mod transport;

pub mod identity;
pub mod leaf;

pub mod hub;

pub mod selection;

#[cfg(feature = "native")]
pub mod enrollment;

pub mod announcement;
pub use announcement::is_benchmarking_ip;

#[cfg(feature = "native")]
pub mod directory;
#[cfg(feature = "native")]
pub mod directory_client;
#[cfg(feature = "native")]
pub mod relay;
#[cfg(feature = "native")]
pub mod relay_store;
pub mod path_identity;

pub mod path_control;

pub mod path_admission;

#[cfg(feature = "native")]
pub mod public_service;

#[cfg(feature = "native")]
pub mod global_registration;

#[cfg(feature = "native")]
pub mod global_daemon;

pub mod policy;
