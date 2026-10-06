use crate::provider::StacProvider;
use crate::query::StacQuery;
use crate::scene::{Scene, parse_feature};

/// STAC API client with automatic pagination.
///
/// Uses synchronous HTTP (ureq) -- no async runtime needed.
/// Handles the `next` token to page through results beyond the
/// per-request limit (300 for Element84).
#[derive(Debug, Clone)]
pub struct StacClient {
    /// Base URL of the STAC API
    pub base_url: String,
    /// Provider profile (determines filter format, MGRS extraction, etc.)
    pub provider: StacProvider,
}

impl StacClient {
    /// Create a client for Element84 Earth Search v1 (the default).
    pub fn earth_search() -> Self {
        let provider = StacProvider::Element84;
        StacClient {
            base_url: provider.base_url().to_string(),
            provider,
        }
    }

    /// Create a client for Planetary Computer.
    pub fn planetary_computer() -> Self {
        let provider = StacProvider::PlanetaryComputer;
        StacClient {
            base_url: provider.base_url().to_string(),
            provider,
        }
    }

    /// Create a client for Digital Earth Australia.
    pub fn dea() -> Self {
        let provider = StacProvider::Dea;
        StacClient {
            base_url: provider.base_url().to_string(),
            provider,
        }
    }

    /// Create a client for a custom STAC API endpoint with CQL2 support.
    pub fn cql2(base_url: &str, region_field: &str) -> Self {
        StacClient {
            base_url: base_url.trim_end_matches('/').to_string(),
            provider: StacProvider::Cql2 {
                region_field: region_field.to_string(),
            },
        }
    }

    /// Create a client with a specific provider and custom base URL override.
    pub fn with_provider(base_url: &str, provider: StacProvider) -> Self {
        StacClient {
            base_url: base_url.trim_end_matches('/').to_string(),
            provider,
        }
    }

    /// The search endpoint URL.
    pub fn search_url(&self) -> String {
        format!("{}/search", self.base_url)
    }

    /// Search for scenes matching a query, with automatic pagination.
    ///
    /// Pages through all results by following the `next` token until
    /// no more pages are available.
    pub fn search(&self, query: &StacQuery) -> Result<Vec<Scene>, String> {
        let url = self.search_url();
        let mut all_scenes = Vec::new();
        let mut token: Option<String> = None;
        let mut page = 0u32;

        loop {
            page += 1;
            let body = match &token {
                Some(t) => query.to_json_with_token(t),
                None => query.to_json(),
            };

            let resp = ureq::post(&url)
                .set("Content-Type", "application/json")
                .send_json(&body)
                .map_err(|e| format!("HTTP request failed (page {page}): {e}"))?;

            let json: serde_json::Value = resp.into_json()
                .map_err(|e| format!("Failed to parse response (page {page}): {e}"))?;

            let features = json.get("features")
                .and_then(|f| f.as_array())
                .ok_or_else(|| format!("No 'features' array in response (page {page})"))?;

            let page_count = features.len();
            for feature in features {
                if let Some(scene) = parse_feature(feature, &self.provider) {
                    all_scenes.push(scene);
                }
            }

            // Follow pagination via links with rel="next"
            let next_token = json.get("links")
                .and_then(|links| links.as_array())
                .and_then(|links| {
                    links.iter().find(|l| {
                        l.get("rel").and_then(|r| r.as_str()) == Some("next")
                    })
                })
                .and_then(|link| {
                    link.get("body")
                        .and_then(|b| b.get("token"))
                        .and_then(|t| t.as_str())
                        .map(|s| s.to_string())
                });

            match next_token {
                Some(t) if page_count > 0 => {
                    token = Some(t);
                }
                _ => break,
            }
        }

        Ok(all_scenes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_earth_search_url() {
        let client = StacClient::earth_search();
        assert_eq!(client.search_url(), "https://earth-search.aws.element84.com/v1/search");
    }

    #[test]
    fn test_planetary_computer_url() {
        let client = StacClient::planetary_computer();
        assert_eq!(
            client.search_url(),
            "https://planetarycomputer.microsoft.com/api/stac/v1/search"
        );
    }

    #[test]
    fn test_dea_url() {
        let client = StacClient::dea();
        assert_eq!(
            client.search_url(),
            "https://explorer.dea.ga.gov.au/stac/search"
        );
    }

    #[test]
    fn test_cql2_custom() {
        let client = StacClient::cql2(
            "https://my-stac.example.com/v1/",
            "s2:mgrs_tile",
        );
        assert_eq!(client.search_url(), "https://my-stac.example.com/v1/search");
        match &client.provider {
            StacProvider::Cql2 { region_field } => {
                assert_eq!(region_field, "s2:mgrs_tile");
            }
            _ => panic!("Expected CQL2 provider"),
        }
    }

    #[test]
    fn test_with_provider_override() {
        let client = StacClient::with_provider(
            "https://custom.stac.io/api",
            StacProvider::Element84,
        );
        assert_eq!(client.search_url(), "https://custom.stac.io/api/search");
    }
}
