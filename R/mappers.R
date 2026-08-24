# Mappers, acquisition identity, and item extraction.
#
# Implements the design doc (inst/docs/design.md): five tables
# (regions external, queries/acquisitions/products/assets here), raw item
# stash, mappers per collection, query log written LAST so an "ok" row
# guarantees a complete fetch. Lists throughout (simplifyVector = FALSE):
# the assets table is an enumeration of each item's assets dict, verbatim,
# with no fixed vocabulary anywhere in the harvest.
#
# Dependencies: jsonlite, arrow, sds (query URL construction).

# ==============================================================================
# MAPPERS (one per collection; assets never need one)
# ==============================================================================

#' Mapper registry
#'
#' A mapper declares product_family and two functions: identity() returns
#' the fields that name the physical acquisition across providers;
#' promote() returns properties promoted to product columns. Everything
#' else in the item is preserved via the raw stash and the properties
#' JSON column.
mappers <- local({
  reg <- list()

  reg[["sentinel-2-c1-l2a"]] <- list(
    collection = "sentinel-2-c1-l2a",
    product_family = "l2a",
    identity = function(props) {
      list(
        platform = tolower(props[["platform"]]),
        instrument = "msi",
        mode = NA_character_,
        tile = paste0(props[["mgrs:utm_zone"]],
                      props[["mgrs:latitude_band"]],
                      props[["mgrs:grid_square"]]),
        datetime = props[["datetime"]]
      )
    },
    promote = function(props) {
      list(
        cloud_cover = props[["eo:cloud_cover"]] %||% NA_real_,
        epsg = props[["proj:epsg"]] %||% NA_integer_,
        baseline = props[["s2:processing_baseline"]] %||% NA_character_,
        polarisations = NA_character_
      )
    }
  )

  ## Planetary Computer serves the same acquisitions; identical identity
  ## fields, different collection id and band keys (assets handle the
  ## band keys by construction).
  reg[["sentinel-2-l2a"]] <- modifyList(reg[["sentinel-2-c1-l2a"]],
                                        list(collection = "sentinel-2-l2a"))
  reg
})

`%||%` <- function(a, b) if (is.null(a)) b else a

#' Canonical acquisition id
#'
#' Sentinel-2: platform + MGRS tile + datetime-to-seconds. Survives the
#' Element84 / Planetary Computer / DEA seam; reprocessings are the same
#' acquisition, different product rows. SAR mappers will supply
#' burst/frame in `tile`.
acquisition_id <- function(ident) {
  dt <- sub("\\.[0-9]+", "", ident$datetime)  # truncate to seconds
  dt <- gsub("[-:]", "", dt)
  paste(ident$platform, ident$tile, dt, sep = "_")
}

#' Solar day at the item centroid
solarday_at <- function(datetime, centroid_lon) {
  t <- as.POSIXct(strptime(datetime, "%Y-%m-%dT%H:%M:%OSZ"), tz = "UTC")
  as.Date(round(t + centroid_lon / 15 * 3600, "days"))
}

item_centroid <- function(item) {
  cen <- item$properties[["proj:centroid"]]
  if (!is.null(cen)) return(c(lon = cen$lon, lat = cen$lat))
  bb <- unlist(item$bbox)
  c(lon = mean(bb[c(1, 3)]), lat = mean(bb[c(2, 4)]))
}

# ==============================================================================
# EXTRACTION: one STAC item -> rows for the three tables
# ==============================================================================

extract_item <- function(item, provider, collection, mapper) {
  props <- item$properties
  ident <- mapper$identity(props)
  acq <- acquisition_id(ident)
  cen <- item_centroid(item)
  promoted <- mapper$promote(props)
  product_id <- paste(provider, collection, item$id, sep = ":")
  product_id <- sprintf("p_%s", substr(digest::digest(product_id, "sha1"), 1, 16))

  acquisitions <- data.frame(
    acquisition_id = acq,
    platform = ident$platform,
    instrument = ident$instrument,
    mode = ident$mode,
    datetime = ident$datetime,
    solarday = solarday_at(ident$datetime, cen[["lon"]]),
    centroid_lon = cen[["lon"]],
    centroid_lat = cen[["lat"]],
    tile = ident$tile,
    stringsAsFactors = FALSE
  )

  ## promoted columns, plus the leftovers as JSON so nothing extracted
  ## later needs a re-query (the raw stash keeps the full item anyway)
  products <- data.frame(
    product_id = product_id,
    acquisition_id = acq,
    provider = provider,
    collection = collection,
    item_id = item$id,
    product_family = mapper$product_family,
    polarisations = promoted$polarisations,
    epsg = promoted$epsg,
    cloud_cover = promoted$cloud_cover,
    baseline = promoted$baseline,
    stringsAsFactors = FALSE
  )

  ## the whole point: enumerate the assets dict verbatim, long form
  akeys <- names(item$assets)
  assets <- data.frame(
    product_id = product_id,
    asset_key = akeys,
    href = vapply(item$assets, function(a) a$href %||% NA_character_,
                  character(1), USE.NAMES = FALSE),
    media_type = vapply(item$assets, function(a) a$type %||% NA_character_,
                        character(1), USE.NAMES = FALSE),
    stringsAsFactors = FALSE
  )

  list(acquisitions = acquisitions, products = products, assets = assets,
       raw = item)
}

