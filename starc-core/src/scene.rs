use std::collections::HashMap;
use serde::{Serialize, Deserialize};

use crate::provider::{StacProvider, decompose_mgrs};

/// A single Sentinel-2 scene with its asset URLs.
///
/// This is the flattened equivalent of one row in the R starc tibble output.
/// Each field maps to a STAC item property or asset.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Scene {
    /// Scene ID, e.g. "S2C_T55GDN_20260312_0_L2A"
    pub scene_id: String,
    /// Acquisition datetime (ISO 8601), e.g. "2026-03-12T00:18:51Z"
    pub datetime: String,
    /// MGRS tile code, e.g. "55GDN"
    pub mgrs_code: String,
    /// UTM zone number
    pub mgrs_utm_zone: u32,
    /// MGRS latitude band letter
    pub mgrs_latitude_band: String,
    /// MGRS 100km grid square letters
    pub mgrs_grid_square: String,
    /// EPSG code from proj:epsg
    pub epsg: u32,
    /// Cloud cover percentage
    pub cloud_cover: f64,
    /// Platform, e.g. "sentinel-2c"
    pub platform: String,
    /// COG asset URLs keyed by band name.
    ///
    /// Keys vary by provider:
    ///   Element84: red, green, blue, nir, swir16, scl, ...
    ///   DEA: nbart_red, nbart_green, nbart_blue, nbart_nir_1, ...
    pub assets: HashMap<String, String>,
}

impl Scene {
    /// Get the COG URL for a band, e.g. `scene.asset_url("red")`.
    pub fn asset_url(&self, band: &str) -> Option<&str> {
        self.assets.get(band).map(|s| s.as_str())
    }

    /// Reconstruct the full MGRS code from its parts.
    pub fn mgrs_full_code(&self) -> String {
        format!("{}{}{}", self.mgrs_utm_zone, self.mgrs_latitude_band, self.mgrs_grid_square)
    }
}

/// Extract asset href URLs from a STAC item's assets object.
///
/// Only includes assets with type containing "geotiff" (COGs).
/// Returns band_name -> URL pairs.
pub(crate) fn extract_assets(assets: &serde_json::Value) -> HashMap<String, String> {
    let mut map = HashMap::new();
    if let Some(obj) = assets.as_object() {
        for (key, val) in obj {
            // Filter to COG assets (skip jp2, json, thumbnail, etc.)
            let asset_type = val.get("type").and_then(|t| t.as_str()).unwrap_or("");
            if !asset_type.contains("geotiff") {
                continue;
            }
            if let Some(href) = val.get("href").and_then(|h| h.as_str()) {
                map.insert(key.clone(), href.to_string());
            }
        }
    }
    map
}

/// Parse a STAC GeoJSON Feature into a Scene.
///
/// The provider determines how the MGRS code is extracted:
/// - Element84/PC: joins `mgrs:utm_zone` + `mgrs:latitude_band` + `mgrs:grid_square`
/// - DEA/CQL2: reads `odc:region_code` (or custom field) directly
pub(crate) fn parse_feature(
    feature: &serde_json::Value,
    provider: &StacProvider,
) -> Option<Scene> {
    let props = feature.get("properties")?;

    let scene_id = feature.get("id")?.as_str()?.to_string();
    let datetime = props.get("datetime")?.as_str()?.to_string();
    let cloud_cover = props.get("eo:cloud_cover").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let platform = props.get("platform").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let epsg = props.get("proj:epsg").and_then(|v| v.as_u64()).unwrap_or(0) as u32;

    // Extract MGRS code using provider-specific logic
    let mgrs_code = provider.extract_mgrs_code(props)?;
    let (utm_zone, lat_band, grid_sq) = decompose_mgrs(&mgrs_code);

    let assets = feature.get("assets").map(extract_assets).unwrap_or_default();

    Some(Scene {
        scene_id,
        datetime,
        mgrs_code,
        mgrs_utm_zone: utm_zone,
        mgrs_latitude_band: lat_band,
        mgrs_grid_square: grid_sq,
        epsg,
        cloud_cover,
        platform,
        assets,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_feature_element84() {
        let feature = serde_json::json!({
            "id": "S2C_T55GDN_20260312_0_L2A",
            "properties": {
                "datetime": "2026-03-12T00:18:51Z",
                "eo:cloud_cover": 12.5,
                "platform": "sentinel-2c",
                "proj:epsg": 32755,
                "mgrs:utm_zone": 55,
                "mgrs:latitude_band": "G",
                "mgrs:grid_square": "DN"
            },
            "assets": {
                "red": {
                    "href": "https://example.com/B04.tif",
                    "type": "image/tiff; application=geotiff; profile=cloud-optimized"
                },
                "nir": {
                    "href": "https://example.com/B08.tif",
                    "type": "image/tiff; application=geotiff; profile=cloud-optimized"
                },
                "thumbnail": {
                    "href": "https://example.com/thumb.png",
                    "type": "image/png"
                }
            }
        });

        let scene = parse_feature(&feature, &StacProvider::Element84).unwrap();
        assert_eq!(scene.scene_id, "S2C_T55GDN_20260312_0_L2A");
        assert_eq!(scene.mgrs_code, "55GDN");
        assert_eq!(scene.mgrs_utm_zone, 55);
        assert_eq!(scene.mgrs_latitude_band, "G");
        assert_eq!(scene.mgrs_grid_square, "DN");
        assert_eq!(scene.epsg, 32755);
        assert_eq!(scene.cloud_cover, 12.5);
        assert_eq!(scene.assets.len(), 2); // thumbnail filtered out
        assert!(scene.asset_url("red").unwrap().ends_with("B04.tif"));
        assert!(scene.asset_url("thumbnail").is_none());
    }

    #[test]
    fn test_parse_feature_dea() {
        let feature = serde_json::json!({
            "id": "ga_s2am_ard_3-2-1_54HTE_2025-06-15_final",
            "properties": {
                "datetime": "2025-06-15T01:23:45Z",
                "eo:cloud_cover": 5.2,
                "platform": "sentinel-2a",
                "proj:epsg": 32754,
                "odc:region_code": "54HTE"
            },
            "assets": {
                "nbart_red": {
                    "href": "s3://dea-public-data/baseline/ga_s2am_ard_3/54/HTE/2025/06/15/band04.tif",
                    "type": "image/tiff; application=geotiff; profile=cloud-optimized"
                },
                "nbart_nir_1": {
                    "href": "s3://dea-public-data/baseline/ga_s2am_ard_3/54/HTE/2025/06/15/band08.tif",
                    "type": "image/tiff; application=geotiff; profile=cloud-optimized"
                }
            }
        });

        let scene = parse_feature(&feature, &StacProvider::Dea).unwrap();
        assert_eq!(scene.scene_id, "ga_s2am_ard_3-2-1_54HTE_2025-06-15_final");
        assert_eq!(scene.mgrs_code, "54HTE");
        assert_eq!(scene.mgrs_utm_zone, 54);
        assert_eq!(scene.mgrs_latitude_band, "H");
        assert_eq!(scene.mgrs_grid_square, "TE");
        assert_eq!(scene.epsg, 32754);
        assert_eq!(scene.cloud_cover, 5.2);
        assert_eq!(scene.assets.len(), 2);
        assert!(scene.asset_url("nbart_red").is_some());
    }

    #[test]
    fn test_mgrs_full_code() {
        let scene = Scene {
            scene_id: String::new(),
            datetime: String::new(),
            mgrs_code: "55GDN".to_string(),
            mgrs_utm_zone: 55,
            mgrs_latitude_band: "G".to_string(),
            mgrs_grid_square: "DN".to_string(),
            epsg: 32755,
            cloud_cover: 0.0,
            platform: String::new(),
            assets: HashMap::new(),
        };
        assert_eq!(scene.mgrs_full_code(), "55GDN");
    }
}
