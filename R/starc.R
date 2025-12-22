#' Prepare STAC query
#'
#' @param spatial_window Spatial window with bbox
#' @param start_date Start date
#' @param end_date End date
#' @return Query specification
prepare_query <- function(spatial_window, start_date, end_date, collections, provider) {
  sds::stacit(window_ll_extent(spatial_window), c(format(start_date), format(end_date)), collections = collections, provider = provider, limit = 300)
}

#' Get assets from pre-built query URLs
#'
#' This was born as hrefs from hypertidy/scene
#' @param query_urls Query URL(s) from sds::stacit()
#' @return Tibble with asset URLs and metadata
#' @export
get_assets_from_urls <- function(query_urls) {
  if (length(query_urls) > 1) {
    # Multiple queries (anti-meridian case)
    results <- lapply(query_urls, get_assets_single)
    dplyr::bind_rows(results)
  } else {
    get_assets_single(query_urls)
  }
}

#' Internal: Fetch single STAC query with pagination
#'
#' This was born as hrefs0 from hypertidy/scene
#' @param query_url STAC query URL
#' @return Tibble with assets + metadata
get_assets_single <- function(query_url) {

  # Fetch STAC results
  json <- tryCatch(
    jsonlite::fromJSON(query_url),
    error = function(e) {
      warning("Failed to fetch STAC results: ", e$message)
      return(NULL)
    }
  )

  if (is.null(json) || length(json$features) == 0) {
    return(NULL)
  }

  # Process each feature (features is a data frame)
  # Split into rows and lapply over them
  results <- lapply(
    split(json$features, seq_len(nrow(json$features))),
    process_feature
  )

  # Convert to tibble
  df <- dplyr::bind_rows(lapply(results, tibble::as_tibble))

  # Pagination: fetch next page if it exists
  if (!is.null(json$links)) {
    next_link <- json$links[json$links$rel == "next", ]
    if (nrow(next_link) > 0) {
      next_url <- next_link$href[1]
      next_results <- get_assets_single(next_url)
      if (!is.null(next_results)) {
        df <- dplyr::bind_rows(df, next_results)
      }
    }
  }

  df
}

#' Internal: Extract assets and metadata from single feature
#'
#' @param feature Single STAC feature (one row from features data frame)
#' @return Named list with assets + metadata
process_feature <- function(feature) {

  # Extract asset URLs
  assets <- feature$assets

  # Asset types to extract (imagery + masks, no metadata files)
  asset_names <- c(
    "red", "green", "blue", "visual", "nir", "swir22",
    "rededge2", "rededge3", "rededge1", "swir16", "wvp",
    "nir08", "scl", "aot", "coastal", "nir09", "cloud", "snow", "preview"
  )

  asset_list <- lapply(asset_names, function(name) {
    if (!is.null(assets[[name]])) assets[[name]]$href else NA_character_
  })
  names(asset_list) <- asset_names

  # Extract metadata from properties
  props <- feature$properties

  # Datetime
  datetime_str <- props$datetime
  datetime_utc <- if (!is.null(datetime_str)) {
    as.POSIXct(datetime_str, format = "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC")
  } else {
    as.POSIXct(NA)
  }

  # Scene ID
  scene_id <- feature$id

  # Centroid (from proj:centroid or compute from bbox)
  if (!is.null(props$`proj:centroid`)) {
    centroid_lat <- props$`proj:centroid`$lat
    centroid_lon <- props$`proj:centroid`$lon
  } else if (!is.null(feature$bbox)) {
    bbox <- feature$bbox
    centroid_lon <- (bbox[1] + bbox[3]) / 2
    centroid_lat <- (bbox[2] + bbox[4]) / 2
  } else {
    centroid_lon <- NA_real_
    centroid_lat <- NA_real_
  }

  # Solarday (local date at centroid)
  if (!is.na(datetime_utc) && !is.na(centroid_lon)) {
    offset_hours <- centroid_lon / 15
    solarday <- as.Date(round(datetime_utc - offset_hours * 3600, "days"))
  } else {
    solarday <- as.Date(NA)
  }

  # Additional metadata
  metadata_list <- list(
    datetime = datetime_utc,
    scene_id = scene_id,
    centroid_lon = centroid_lon,
    centroid_lat = centroid_lat,
    solarday = solarday,
    cloud_cover = props$`eo:cloud_cover`,
    platform = props$platform,
    mgrs_grid_square = props$`mgrs:grid_square`,
    mgrs_latitude_band = props$`mgrs:latitude_band`,
    mgrs_utm_zone = props$`mgrs:utm_zone`,
    epsg = props$`proj:epsg`
  )

  c(asset_list, metadata_list)
}
