# Paginated fetch and the bbox harvest mode.

# ==============================================================================
# PAGINATED FETCH
# ==============================================================================

#' Follow rel="next" links, collecting all items
#'
#' @param url First-page search URL (from sds::stacit())
#' @param max_pages Safety valve
#' @return list(items = list of item lists, n_pages = int)
fetch_all_pages <- function(url, max_pages = 100) {
  items <- list()
  n_pages <- 0L
  while (!is.null(url) && n_pages < max_pages) {
    js <- jsonlite::fromJSON(url, simplifyVector = FALSE)
    n_pages <- n_pages + 1L
    items <- c(items, js$features %||% list())
    nxt <- Filter(function(l) identical(l$rel, "next"), js$links %||% list())
    url <- if (length(nxt) > 0) nxt[[1]]$href else NULL
  }
  list(items = items, n_pages = n_pages)
}

# ==============================================================================
# HARVEST ONE (region, provider, collection, window)
# ==============================================================================

#' Internal: fetch, extract, write shards + raw stash, then the query row
#'
#' Shared by both harvest modes. The query log row is written LAST so an
#' "ok" row guarantees a complete fetch; "empty" is a positive fact
#' distinct from the absence of a row ("never asked").
#' @keywords internal
harvest_url <- function(url_builder, region_id, provider, collection,
                        t0, t1, store = "store") {
  mapper <- mappers[[collection]]
  if (is.null(mapper)) stop("no mapper registered for collection: ", collection)

  fetched_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  qid <- substr(digest::digest(list(region_id, provider, collection,
                                    t0, t1, fetched_at), "sha1"), 1, 16)

  status <- "ok"; err <- NA_character_; items <- list(); n_pages <- 0L
  url <- NA_character_
  got <- try({
    url <- url_builder()
    fetch_all_pages(url)
  }, silent = TRUE)
  if (inherits(got, "try-error")) {
    status <- "error"; err <- conditionMessage(attr(got, "condition"))
  } else {
    items <- got$items; n_pages <- got$n_pages
    if (length(items) == 0) status <- "empty"
  }

  if (length(items) > 0) {
    ex <- lapply(items, extract_item, provider = provider,
                 collection = collection, mapper = mapper)
    shard <- function(name) do.call(rbind, lapply(ex, `[[`, name))

    ## acquisitions: provider-independent canonical level -- NOT
    ## partitioned by collection and never stamped with a query_id;
    ## query linkage flows through products.
    adir <- file.path(store, "acquisitions")
    dir.create(adir, recursive = TRUE, showWarnings = FALSE)
    arrow::write_parquet(shard("acquisitions"),
                         file.path(adir, sprintf("%s.parquet", qid)))

    ## products: exactly the thing a query returned; the query_id lives
    ## here. Re-encounters across harvests are the sighting history
    ## (first/last seen derive from queries$fetched_at via this link).
    prods <- shard("products")
    prods$query_id <- qid
    pdir <- file.path(store, "products", paste0("collection=", collection))
    dir.create(pdir, recursive = TRUE, showWarnings = FALSE)
    arrow::write_parquet(prods, file.path(pdir, sprintf("%s.parquet", qid)))

    ## assets: keyed by product_id, inherit linkage for free.
    sdir <- file.path(store, "assets", paste0("collection=", collection))
    dir.create(sdir, recursive = TRUE, showWarnings = FALSE)
    arrow::write_parquet(shard("assets"),
                         file.path(sdir, sprintf("%s.parquet", qid)))

    rawdir <- file.path(store, "raw", collection)
    dir.create(rawdir, recursive = TRUE, showWarnings = FALSE)
    for (e in ex) {
      con <- gzfile(file.path(rawdir,
                    sprintf("%s.json.gz", e$products$product_id)), "w")
      writeLines(jsonlite::toJSON(e$raw, auto_unbox = TRUE), con)
      close(con)
    }
  }

  qrow <- data.frame(
    query_id = qid, region_id = region_id,
    provider = provider, collection = collection,
    t0 = t0, t1 = t1, fetched_at = fetched_at,
    n_items = length(items), n_pages = n_pages,
    status = status, error = err, url = url,
    stringsAsFactors = FALSE
  )
  qdir <- file.path(store, "queries")
  dir.create(qdir, recursive = TRUE, showWarnings = FALSE)
  arrow::write_parquet(qrow, file.path(qdir, sprintf("%s.parquet", qid)))
  invisible(qrow)
}

#' Harvest a region bbox into the reference store
#'
#' @param region One row of a regions table (region_id, lonmin, lonmax,
#'   latmin, latmax)
#' @param provider sds::stacit provider token
#' @param collection Collection id (must have a registered mapper)
#' @param t0,t1 Query window (RFC3339 or dates sds accepts)
#' @param store Root directory of the parquet store
#' @param limit Page size
#' @param pad_km Discovery buffer applied to the extent (see pad_extent)
#' @return the query log row, invisibly
#' @export
harvest <- function(region, provider, collection, t0, t1,
                    store = "store", limit = 300, pad_km = 5) {
  llex <- pad_extent(unlist(region[c("lonmin", "lonmax", "latmin", "latmax")]),
                     min_km = pad_km)
  harvest_url(
    url_builder = function() sds::stacit(llex, c(t0, t1), limit = limit,
                                         collections = collection,
                                         provider = provider),
    region_id = region$region_id,
    provider = provider, collection = collection,
    t0 = t0, t1 = t1, store = store
  )
}
