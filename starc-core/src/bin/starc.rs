//! starc CLI — search STAC for Sentinel-2 scenes.
//!
//! Usage:
//!   starc <MGRS> [--start=DATE] [--end=DATE] [--cloud=N] [--collection=C] [--band=B]
//!
//! Examples:
//!   starc 55GDN
//!   starc 55GDN --start=2025-01-01 --end=2025-02-01
//!   starc 55GDN --start=2025-01-01 --end=2025-02-01 --cloud=20 --band=red

use starc_core::{StacQuery, StacClient};

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 || args[1] == "-h" || args[1] == "--help" {
        print_usage();
        if args.len() < 2 { std::process::exit(1); }
        return;
    }

    let (pos, opts) = parse_opts(&args[1..]);
    if pos.is_empty() {
        eprintln!("Error: MGRS code required");
        std::process::exit(1);
    }

    let mut query = StacQuery::new(&pos[0]);

    if let (Some(start), Some(end)) = (&opts.start, &opts.end) {
        query = query.datetime(start, end);
    }
    if let Some(cloud) = opts.cloud {
        query = query.max_cloud_cover(cloud);
    }
    if let Some(collection) = &opts.collection {
        query = query.collection(collection);
    }

    let client = StacClient::earth_search();
    let scenes = client.search(&query).unwrap_or_else(|e| {
        eprintln!("Error: {e}");
        std::process::exit(1);
    });

    eprintln!("# {} scenes found for {}", scenes.len(), pos[0]);

    // Print header
    if let Some(band) = &opts.band {
        // Single band mode: scene_id, datetime, cloud_cover, url
        println!("scene_id\tdatetime\tcloud_cover\turl");
        for s in &scenes {
            let url = s.asset_url(band).unwrap_or("NA");
            println!("{}\t{}\t{:.1}\t{}", s.scene_id, s.datetime, s.cloud_cover, url);
        }
    } else {
        // Full mode: scene_id, datetime, cloud_cover, platform, epsg, + all band URLs
        // Collect all band names across scenes
        let mut all_bands: Vec<String> = scenes.iter()
            .flat_map(|s| s.assets.keys().cloned())
            .collect();
        all_bands.sort();
        all_bands.dedup();

        print!("scene_id\tdatetime\tcloud_cover\tplatform\tepsg");
        for b in &all_bands {
            print!("\t{b}");
        }
        println!();

        for s in &scenes {
            print!("{}\t{}\t{:.1}\t{}\t{}",
                s.scene_id, s.datetime, s.cloud_cover, s.platform, s.epsg);
            for b in &all_bands {
                let url = s.asset_url(b).unwrap_or("NA");
                print!("\t{url}");
            }
            println!();
        }
    }
}

fn print_usage() {
    eprintln!("starc — STAC search for Sentinel-2 scenes");
    eprintln!();
    eprintln!("Usage: starc <MGRS> [options]");
    eprintln!();
    eprintln!("Options:");
    eprintln!("  --start=DATE       Start date (ISO 8601), e.g. 2025-01-01");
    eprintln!("  --end=DATE         End date");
    eprintln!("  --cloud=N          Max cloud cover percentage (0-100)");
    eprintln!("  --collection=C     STAC collection (default: sentinel-2-l2a)");
    eprintln!("  --band=B           Print only this band's URL (e.g. red, nir)");
    eprintln!();
    eprintln!("Examples:");
    eprintln!("  starc 55GDN --start=2025-01-01 --end=2025-02-01");
    eprintln!("  starc 55GDN --start=2025-01-01 --end=2025-02-01 --cloud=20 --band=red");
}

struct Opts {
    start: Option<String>,
    end: Option<String>,
    cloud: Option<f64>,
    collection: Option<String>,
    band: Option<String>,
}

fn parse_opts(args: &[String]) -> (Vec<String>, Opts) {
    let mut positional = Vec::new();
    let mut opts = Opts {
        start: None, end: None, cloud: None, collection: None, band: None,
    };

    for arg in args {
        if let Some(v) = arg.strip_prefix("--start=") {
            opts.start = Some(v.to_string());
        } else if let Some(v) = arg.strip_prefix("--end=") {
            opts.end = Some(v.to_string());
        } else if let Some(v) = arg.strip_prefix("--cloud=") {
            opts.cloud = Some(v.parse().expect("--cloud must be a number"));
        } else if let Some(v) = arg.strip_prefix("--collection=") {
            opts.collection = Some(v.to_string());
        } else if let Some(v) = arg.strip_prefix("--band=") {
            opts.band = Some(v.to_string());
        } else {
            positional.push(arg.clone());
        }
    }

    (positional, opts)
}
