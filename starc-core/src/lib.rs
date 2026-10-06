//! # starc
//!
//! STAC search client for Sentinel-2 scene discovery.
//!
//! Replaces the R `sds::stacit()` query builder and
//! `starc:::get_assets_from_urls()` paginated asset extraction
//! with a single Rust library.
//!
//! ## Usage
//!
//! ```rust,ignore
//! use starc_core::{StacQuery, StacClient};
//!
//! #[tokio::main]
//! async fn main() {
//!     let query = StacQuery::new("55GDN")
//!         .datetime("2025-01-01", "2025-02-01")
//!         .max_cloud_cover(30.0);
//!
//!     let client = StacClient::earth_search();
//!     let scenes = client.search(&query).await.unwrap();
//!     println!("{} scenes found", scenes.len());
//! }
//! ```

mod query;
mod client;
mod scene;
pub mod provider;

pub use query::StacQuery;
pub use client::StacClient;
pub use scene::Scene;
pub use provider::StacProvider;
