use serde_json::Value;

use crate::provider::StacProvider;

/// A STAC search query for Sentinel-2 scenes.
///
/// Builds the POST body for the `/search` endpoint.
/// The query format adapts to the provider: Element84/PC use the `query`
/// extension, DEA/CQL2 providers use CQL2-JSON filters.
#[derive(Debug, Clone)]
pub struct StacQuery {
    /// MGRS tile code, e.g. "55GDN"
    pub mgrs_code: String,
    /// Collection ID — provider default if not overridden
    pub collection: Option<String>,
    /// Start date (ISO 8601 date), e.g. "2025-01-01"
    pub datetime_start: Option<String>,
    /// End date (ISO 8601 date)
    pub datetime_end: Option<String>,
    /// Maximum cloud cover percentage (0-100)
    pub max_cloud_cover: Option<f64>,
    /// Page size for pagination (Element84 max is 300)
    pub limit: u32,
    /// Which STAC provider this query targets
    pub provider: StacProvider,
}

impl StacQuery {
    /// Create a new query for an MGRS tile using Element84 (the default).
    pub fn new(mgrs_code: &str) -> Self {
        StacQuery {
            mgrs_code: mgrs_code.to_uppercase(),
            collection: None,
            datetime_start: None,
            datetime_end: None,
            max_cloud_cover: None,
            limit: 300,
            provider: StacProvider::Element84,
        }
    }

    /// Create a query targeting a specific provider.
    pub fn with_provider(mgrs_code: &str, provider: StacProvider) -> Self {
        StacQuery {
            mgrs_code: mgrs_code.to_uppercase(),
            collection: None,
            datetime_start: None,
            datetime_end: None,
            max_cloud_cover: None,
            limit: 300,
            provider,
        }
    }

    /// Set the date range.
    pub fn datetime(mut self, start: &str, end: &str) -> Self {
        self.datetime_start = Some(start.to_string());
        self.datetime_end = Some(end.to_string());
        self
    }

    /// Override the collection (otherwise the provider default is used).
    /// Element84 default: "sentinel-2-l2a".
    /// DEA default: "ga_s2am_ard_3".
    pub fn collection(mut self, collection: &str) -> Self {
        self.collection = Some(collection.to_string());
        self
    }

    /// Filter by maximum cloud cover percentage.
    pub fn max_cloud_cover(mut self, pct: f64) -> Self {
        self.max_cloud_cover = Some(pct);
        self
    }

    /// Set page size (default: 300, which is Element84's max).
    pub fn limit(mut self, limit: u32) -> Self {
        self.limit = limit;
        self
    }

    /// The collection ID this query will use (explicit override or provider default).
    pub fn effective_collection(&self) -> &str {
        self.collection.as_deref().unwrap_or_else(|| self.provider.default_collection())
    }

    /// Build the JSON POST body as a serde_json::Value.
    ///
    /// The MGRS/region filter format depends on the provider:
    /// - Element84/PC: `{"query": {"mgrs:utm_zone": ..., ...}}`
    /// - DEA/CQL2: `{"filter-lang": "cql2-json", "filter": ...}`
    pub fn to_json(&self) -> Value {
        let collection = self.effective_collection();

        // Start with provider-specific MGRS + cloud filter
        let filter_json = self.provider.build_mgrs_filter(
            &self.mgrs_code,
            self.max_cloud_cover,
        );

        // Merge into base body with collections, limit, datetime
        let mut body = serde_json::json!({
            "collections": [collection],
            "limit": self.limit,
        });

        // Merge all keys from the provider filter into the body
        if let Some(filter_obj) = filter_json.as_object() {
            for (k, v) in filter_obj {
                body.as_object_mut().unwrap().insert(k.clone(), v.clone());
            }
        }

        if let (Some(start), Some(end)) = (&self.datetime_start, &self.datetime_end) {
            body.as_object_mut().unwrap().insert(
                "datetime".to_string(),
                Value::String(format!("{start}T00:00:00Z/{end}T23:59:59Z")),
            );
        }

        body
    }

    /// Build the JSON body with a `token` for pagination.
    pub(crate) fn to_json_with_token(&self, token: &str) -> Value {
        let mut body = self.to_json();
        body.as_object_mut().unwrap().insert(
            "token".to_string(),
            Value::String(token.to_string()),
        );
        body
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_is_element84() {
        let q = StacQuery::new("55GDN");
        assert_eq!(q.effective_collection(), "sentinel-2-l2a");
    }

    #[test]
    fn test_dea_default_collection() {
        let q = StacQuery::with_provider("55GDN", StacProvider::Dea);
        assert_eq!(q.effective_collection(), "ga_s2am_ard_3");
    }

    #[test]
    fn test_collection_override() {
        let q = StacQuery::with_provider("55GDN", StacProvider::Dea)
            .collection("ga_s2cm_ard_3");
        assert_eq!(q.effective_collection(), "ga_s2cm_ard_3");
    }

    #[test]
    fn test_element84_json_body() {
        let q = StacQuery::new("55GDN")
            .datetime("2025-01-01", "2025-02-01")
            .max_cloud_cover(30.0);
        let body = q.to_json();

        assert_eq!(body["collections"][0], "sentinel-2-l2a");
        assert_eq!(body["limit"], 300);
        assert_eq!(body["query"]["mgrs:utm_zone"]["eq"], 55);
        assert_eq!(body["query"]["mgrs:latitude_band"]["eq"], "G");
        assert_eq!(body["query"]["mgrs:grid_square"]["eq"], "DN");
        assert_eq!(body["query"]["eo:cloud_cover"]["lte"], 30.0);
        assert!(body["datetime"].as_str().unwrap().contains("2025-01-01"));
    }

    #[test]
    fn test_dea_json_body() {
        let q = StacQuery::with_provider("54HTE", StacProvider::Dea)
            .datetime("2025-06-01", "2025-06-30")
            .max_cloud_cover(20.0);
        let body = q.to_json();

        assert_eq!(body["collections"][0], "ga_s2am_ard_3");
        assert_eq!(body["filter-lang"], "cql2-json");
        let filter = &body["filter"];
        assert_eq!(filter["op"], "and");
        let args = filter["args"].as_array().unwrap();
        assert_eq!(args[0]["args"][0]["property"], "odc:region_code");
        assert_eq!(args[0]["args"][1], "54HTE");
        // No "query" key for CQL2 providers
        assert!(body.get("query").is_none());
    }

    #[test]
    fn test_dea_no_cloud_filter() {
        let q = StacQuery::with_provider("54HTE", StacProvider::Dea);
        let body = q.to_json();
        // Single filter, no wrapping "and"
        assert_eq!(body["filter"]["op"], "=");
    }

    #[test]
    fn test_json_no_cloud_filter() {
        let q = StacQuery::new("55GDN");
        let body = q.to_json();
        assert!(body["query"].get("eo:cloud_cover").is_none());
    }

    #[test]
    fn test_json_with_token() {
        let q = StacQuery::new("55GDN");
        let body = q.to_json_with_token("next:abc123");
        assert_eq!(body["token"], "next:abc123");
    }
}
