use serde_json::Value;

/// STAC API provider profile.
///
/// Different STAC providers expose Sentinel-2 metadata differently:
/// - Element84 uses `mgrs:utm_zone`, `mgrs:latitude_band`, `mgrs:grid_square`
///   with the `query` extension
/// - DEA (Digital Earth Australia) uses `odc:region_code` with CQL2 filters
///
/// The provider determines how the MGRS filter and cloud cover filter
/// are serialized into the POST body.
#[derive(Debug, Clone)]
pub enum StacProvider {
    /// Element84 Earth Search — uses `query` extension with `mgrs:*` fields.
    /// Default collection: `sentinel-2-l2a` or `sentinel-2-c1-l2a`.
    Element84,
    /// Planetary Computer — same query style as Element84.
    PlanetaryComputer,
    /// Digital Earth Australia — uses CQL2 filter with `odc:region_code`.
    /// Collections: `ga_s2am_ard_3`, `ga_s2bm_ard_3`, `ga_s2cm_ard_3`.
    Dea,
    /// Custom provider with CQL2 filter using a specified region field.
    Cql2 {
        /// The property name for the MGRS/region code, e.g. "odc:region_code"
        region_field: String,
    },
}

impl StacProvider {
    /// Build the MGRS/region filter as part of the POST body.
    ///
    /// For Element84/PC this returns `{"query": {"mgrs:utm_zone": ..., ...}}`.
    /// For DEA/CQL2 this returns `{"filter-lang": "cql2-json", "filter": ...}`.
    pub fn build_mgrs_filter(
        &self,
        mgrs_code: &str,
        cloud_filter: Option<f64>,
    ) -> Value {
        match self {
            StacProvider::Element84 | StacProvider::PlanetaryComputer => {
                build_element84_filter(mgrs_code, cloud_filter)
            }
            StacProvider::Dea => {
                build_cql2_filter("odc:region_code", mgrs_code, cloud_filter)
            }
            StacProvider::Cql2 { region_field } => {
                build_cql2_filter(region_field, mgrs_code, cloud_filter)
            }
        }
    }

    /// Extract the MGRS code from a STAC item's properties.
    ///
    /// Element84: joins `mgrs:utm_zone` + `mgrs:latitude_band` + `mgrs:grid_square`.
    /// DEA: reads `odc:region_code` directly.
    pub fn extract_mgrs_code(&self, props: &Value) -> Option<String> {
        match self {
            StacProvider::Element84 | StacProvider::PlanetaryComputer => {
                let zone = props.get("mgrs:utm_zone").and_then(|v| v.as_u64())?;
                let band = props.get("mgrs:latitude_band").and_then(|v| v.as_str())?;
                let sq = props.get("mgrs:grid_square").and_then(|v| v.as_str())?;
                Some(format!("{zone}{band}{sq}"))
            }
            StacProvider::Dea | StacProvider::Cql2 { .. } => {
                let field = match self {
                    StacProvider::Cql2 { region_field } => region_field.as_str(),
                    _ => "odc:region_code",
                };
                props.get(field).and_then(|v| v.as_str()).map(|s| s.to_string())
            }
        }
    }

    /// The default collection name for this provider.
    pub fn default_collection(&self) -> &str {
        match self {
            StacProvider::Element84 => "sentinel-2-l2a",
            StacProvider::PlanetaryComputer => "sentinel-2-l2a",
            StacProvider::Dea => "ga_s2am_ard_3",
            StacProvider::Cql2 { .. } => "sentinel-2-l2a",
        }
    }

    /// The base URL for this provider's STAC API.
    pub fn base_url(&self) -> &str {
        match self {
            StacProvider::Element84 => "https://earth-search.aws.element84.com/v1",
            StacProvider::PlanetaryComputer => "https://planetarycomputer.microsoft.com/api/stac/v1",
            StacProvider::Dea => "https://explorer.dea.ga.gov.au/stac",
            StacProvider::Cql2 { .. } => "",
        }
    }

    /// Whether this provider uses pagination tokens in `links[rel=next].body.token`
    /// (Element84 style) or some other pagination mechanism.
    pub fn uses_token_pagination(&self) -> bool {
        match self {
            StacProvider::Element84 | StacProvider::PlanetaryComputer => true,
            StacProvider::Dea => true,
            StacProvider::Cql2 { .. } => true,
        }
    }
}

/// Build Element84/PC-style query filter using the `query` extension.
fn build_element84_filter(mgrs_code: &str, cloud_filter: Option<f64>) -> Value {
    let (zone, band, square) = decompose_mgrs(mgrs_code);

    let mut query = serde_json::json!({
        "mgrs:utm_zone": {"eq": zone},
        "mgrs:latitude_band": {"eq": band},
        "mgrs:grid_square": {"eq": square}
    });

    if let Some(pct) = cloud_filter {
        query.as_object_mut().unwrap().insert(
            "eo:cloud_cover".to_string(),
            serde_json::json!({"lte": pct}),
        );
    }

    serde_json::json!({"query": query})
}

/// Build CQL2-JSON filter for DEA and other CQL2-capable providers.
fn build_cql2_filter(
    region_field: &str,
    mgrs_code: &str,
    cloud_filter: Option<f64>,
) -> Value {
    let mut args = vec![
        serde_json::json!({
            "op": "=",
            "args": [{"property": region_field}, mgrs_code]
        }),
    ];

    if let Some(pct) = cloud_filter {
        args.push(serde_json::json!({
            "op": "<",
            "args": [{"property": "eo:cloud_cover"}, pct]
        }));
    }

    let filter = if args.len() == 1 {
        args.into_iter().next().unwrap()
    } else {
        serde_json::json!({
            "op": "and",
            "args": args
        })
    };

    serde_json::json!({
        "filter-lang": "cql2-json",
        "filter": filter
    })
}

/// Decompose an MGRS code like "55GDN" into (zone, band, square).
pub fn decompose_mgrs(code: &str) -> (u32, String, String) {
    let zone_end = code.chars().position(|c| c.is_ascii_alphabetic()).unwrap_or(2);
    let zone: u32 = code[..zone_end].parse().unwrap_or(0);
    let band = code[zone_end..zone_end + 1].to_string();
    let square = code[zone_end + 1..].to_string();
    (zone, band, square)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decompose_mgrs() {
        assert_eq!(decompose_mgrs("55GDN"), (55, "G".into(), "DN".into()));
        assert_eq!(decompose_mgrs("5TKL"), (5, "T".into(), "KL".into()));
        assert_eq!(decompose_mgrs("32TQM"), (32, "T".into(), "QM".into()));
    }

    #[test]
    fn test_element84_filter() {
        let p = StacProvider::Element84;
        let f = p.build_mgrs_filter("55GDN", Some(30.0));
        assert_eq!(f["query"]["mgrs:utm_zone"]["eq"], 55);
        assert_eq!(f["query"]["mgrs:latitude_band"]["eq"], "G");
        assert_eq!(f["query"]["mgrs:grid_square"]["eq"], "DN");
        assert_eq!(f["query"]["eo:cloud_cover"]["lte"], 30.0);
    }

    #[test]
    fn test_dea_filter() {
        let p = StacProvider::Dea;
        let f = p.build_mgrs_filter("55HBU", Some(20.0));
        assert_eq!(f["filter-lang"], "cql2-json");
        let filter = &f["filter"];
        assert_eq!(filter["op"], "and");
        let args = filter["args"].as_array().unwrap();
        assert_eq!(args[0]["args"][0]["property"], "odc:region_code");
        assert_eq!(args[0]["args"][1], "55HBU");
        assert_eq!(args[1]["args"][0]["property"], "eo:cloud_cover");
        assert_eq!(args[1]["args"][1], 20.0);
    }

    #[test]
    fn test_dea_filter_no_cloud() {
        let p = StacProvider::Dea;
        let f = p.build_mgrs_filter("54HTE", None);
        // Single filter, no wrapping "and"
        assert_eq!(f["filter"]["op"], "=");
        assert_eq!(f["filter"]["args"][1], "54HTE");
    }

    #[test]
    fn test_extract_mgrs_element84() {
        let p = StacProvider::Element84;
        let props = serde_json::json!({
            "mgrs:utm_zone": 55,
            "mgrs:latitude_band": "G",
            "mgrs:grid_square": "DN"
        });
        assert_eq!(p.extract_mgrs_code(&props), Some("55GDN".into()));
    }

    #[test]
    fn test_extract_mgrs_dea() {
        let p = StacProvider::Dea;
        let props = serde_json::json!({
            "odc:region_code": "54HTE"
        });
        assert_eq!(p.extract_mgrs_code(&props), Some("54HTE".into()));
    }

    #[test]
    fn test_default_collections() {
        assert_eq!(StacProvider::Element84.default_collection(), "sentinel-2-l2a");
        assert_eq!(StacProvider::Dea.default_collection(), "ga_s2am_ard_3");
    }
}
