# The MGRS grid-code harvest mode, folded in from hypertidy/rstarc.
#
# Queries by grid:code + month instead of bbox + window: deterministic
# query units (no bbox geometry, no padding, no projection anywhere),
# perfectly resumable (the query log per tile-month is a checkpoint
# lattice for full-archive backfills), and aligned with acquisition
# identity by construction -- the MGRS code IS the identity's `tile`
# field, so grid-code harvesting queries directly in identity space.
#
# The set of MGRS codes Sentinel-2 actually produces (not all codes
# exist) ships as inst/extdata/valid_mgrs_sentinel2.parquet.

#' Month window in RFC3339, inclusive of the month's last second
#' @keywords internal
month_window <- function(month) {
  m0 <- as.Date(paste0(format(as.Date(paste0(month, "-01")), "%Y-%m"), "-01"))
  m1 <- seq(m0, by = "1 month", length.out = 2)[2] - 1
  c(t0 = format(m0, "%Y-%m-%dT00:00:00Z"),
    t1 = format(m1, "%Y-%m-%dT23:59:59Z"))
}

#' Build a grid:code + month search URL
#'
#' @param mgrs MGRS code, e.g. "43DDE" (no "MGRS-" prefix)
#' @param month "YYYY-MM"
#' @param collection Collection id
#' @param endpoint STAC search endpoint (raw URL; this mode constructs
#'   the query itself rather than going through sds::stacit)
#' @param limit Page size
#' @export
mgrs_month_url <- function(mgrs, month,
                           collection = "sentinel-2-c1-l2a",
                           endpoint = "https://earth-search.aws.element84.com/v1/search",
                           limit = 300) {
  w <- month_window(month)
  qjson <- jsonlite::toJSON(
    list(`grid:code` = list(`in` = sprintf("MGRS-%s", mgrs))),
    auto_unbox = FALSE
  )
  paste0(endpoint,
         "?collections=", collection,
         "&datetime=", w[["t0"]], "/", w[["t1"]],
         "&limit=", limit,
         "&query=", utils::URLencode(qjson, reserved = TRUE))
}

#' Harvest one (MGRS tile, month) into the reference store
#'
#' The deterministic sibling of harvest(): same store, same tables,
#' same query-log-last discipline. region_id in the query log is
#' "mgrs:<code>", keeping tile-month harvests distinguishable from
#' region-bbox harvests while sharing every derived view.
#'
#' @inheritParams mgrs_month_url
#' @param store Root directory of the parquet store
#' @return the query log row, invisibly
#' @export
harvest_mgrs <- function(mgrs, month,
                         collection = "sentinel-2-c1-l2a",
                         endpoint = "https://earth-search.aws.element84.com/v1/search",
                         store = "~/starc-store", limit = 300) {
  w <- month_window(month)
  harvest_url(
    url_builder = function() mgrs_month_url(mgrs, month, collection,
                                            endpoint, limit),
    region_id = sprintf("mgrs:%s", mgrs),
    provider = endpoint, collection = collection,
    t0 = w[["t0"]], t1 = w[["t1"]], store = store
  )
}
