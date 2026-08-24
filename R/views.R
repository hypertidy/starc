# Derived views over the store: no stored state, dedup at read.

# ==============================================================================
# DERIVED VIEWS (no stored state)
# ==============================================================================

#' Marker: max solarday per collection (deduped, derived, never stored)
marker <- function(store = "store") {
  a <- arrow::open_dataset(file.path(store, "acquisitions")) |>
    dplyr::select(acquisition_id, solarday) |>
    dplyr::collect() |>
    dplyr::distinct(acquisition_id, .keep_all = TRUE)
  p <- arrow::open_dataset(file.path(store, "products")) |>
    dplyr::select(product_id, acquisition_id, collection) |>
    dplyr::collect() |>
    dplyr::distinct(product_id, .keep_all = TRUE)
  dplyr::inner_join(p, a, by = "acquisition_id") |>
    dplyr::group_by(collection) |>
    dplyr::summarise(last_solarday = max(solarday),
                     n_solardays = dplyr::n_distinct(solarday),
                     n_acquisitions = dplyr::n_distinct(acquisition_id),
                     n_products = dplyr::n(),
                     .groups = "drop")
}

#' Region-scoped marker: what estinel's incremental cadence asks for
#'
#' Joins products -> queries via query_id to recover region_id. Product
#' rows from harvests predating the query_id column drop out of the
#' inner join (re-harvest to backfill).
marker_region <- function(store = "store") {
  q <- arrow::open_dataset(file.path(store, "queries")) |>
    dplyr::select(query_id, region_id) |>
    dplyr::collect()
  a <- arrow::open_dataset(file.path(store, "acquisitions")) |>
    dplyr::select(acquisition_id, solarday) |>
    dplyr::collect() |>
    dplyr::distinct(acquisition_id, .keep_all = TRUE)
  p <- arrow::open_dataset(file.path(store, "products")) |>
    dplyr::select(product_id, acquisition_id, collection, query_id) |>
    dplyr::collect() |>
    dplyr::inner_join(q, by = "query_id") |>
    dplyr::distinct(product_id, region_id, .keep_all = TRUE)
  dplyr::inner_join(p, a, by = "acquisition_id") |>
    dplyr::group_by(region_id, collection) |>
    dplyr::summarise(last_solarday = max(solarday),
                     n_solardays = dplyr::n_distinct(solarday),
                     .groups = "drop")
}
