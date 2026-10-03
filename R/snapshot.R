# Publishable single-file snapshots of the store.
#
# A shard store behind a no-list policy is public in bytes but not in
# navigation: nothing can enumerate the shards anonymously. A snapshot
# materializes the dedup-at-read view of a level into ONE parquet file
# for publication at a well-known key. It is a derived artifact, never
# the store: regenerate at will, overwrite in place, delete without
# loss. (First consumer: wildtiles publishes index/acquisitions.parquet
# so external users can navigate upstream coverage with no list access.)

#' Consolidate store levels into single publishable tables
#'
#' Reads the append-only shards of each requested level and applies
#' the store's read-side identity rules, materialized:
#'
#' - queries: the harvest log; one row per query_id by construction,
#'   kept whole and ordered by fetched_at.
#' - acquisitions: distinct acquisition_id (the provider-independent
#'   level; overlapping harvests re-write rows freely).
#' - products: distinct (product_id, query_id) -- re-encounters across
#'   harvests are the sighting history, retained by design.
#' - assets: distinct (product_id, asset_key); an href is a property
#'   of the product, so re-sightings add nothing.
#'
#' @param store path to the store
#' @param dir output directory, created if needed
#' @param tables which levels to snapshot
#' @return data.frame manifest: table, n_row, path
#' @export
snapshot <- function(store = "~/starc-store",
                     dir = file.path(store, "snapshot"),
                     tables = c("queries", "acquisitions", "products",
                                "assets")) {
  tables <- match.arg(tables, several.ok = TRUE)
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  out <- lapply(tables, function(nm) {
    x <- arrow::open_dataset(file.path(store, nm)) |> dplyr::collect()
    x <- snapshot_dedup(nm, x)
    path <- file.path(dir, sprintf("%s.parquet", nm))
    arrow::write_parquet(x, path)
    data.frame(table = nm, n_row = nrow(x), path = path,
               stringsAsFactors = FALSE)
  })
  do.call(rbind, out)
}

#' Read-side identity rules for one store level (pure, in-memory)
#'
#' @param level store level name
#' @param x the level's rows, duplicates and all
#' @return deduplicated rows
#' @keywords internal
snapshot_dedup <- function(level, x) {
  switch(level,
    queries      = dplyr::arrange(x, fetched_at),
    acquisitions = dplyr::distinct(x, acquisition_id, .keep_all = TRUE),
    products     = dplyr::distinct(x, product_id, query_id,
                                   .keep_all = TRUE),
    assets       = dplyr::distinct(x, product_id, asset_key,
                                   .keep_all = TRUE),
    stop("unknown store level: ", level)
  )
}
