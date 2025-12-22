#' Prepare STAC query
#'
#' @param spatial_window Spatial window with bbox
#' @param start_date Start date
#' @param end_date End date
#' @return Query specification
prepare_query <- function(spatial_window,  collections, provider) {
    sds::stacit(window_ll_extent(spatial_window), c(format(spatial_window$start_date), format(spatial_window$end_date)), collections = collections, provider = provider, limit = 300)
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



#' Define test location (Noville Peninsula)
#'
#' @return Data frame with single location
define_test_location <- function() {
  list(tibble::tibble(
    location = "Noville Peninsula",
    lon = -98.464,
    lat = -71.758,
    resolution = 10,           # meters
    radiusx = 3000,           # meters
    radiusy = 3000,           # meters
    purpose = "emperor"

  ),
  tibble::tibble(
    location = "Fiji Taveuna",
    lon = 179.98,
    lat = -17,
    resolution = 10,           # meters
    radiusx = 3000,           # meters
    radiusy = 3000,           # meters
    purpose = "antimeridian"

  ),   tibble::tibble(
    location = "Fiji Taveuna 80m",
    lon = 179.98,
    lat = -17,
    resolution = 80,           # meters
    radiusx = 3000 * 8,           # meters
    radiusy = 3000 * 8,           # meters
    purpose = "antimeridian"

  ), tibble::tibble(
    location = "Very South",
    lon = 0,
    lat = -75,
    resolution = 80,           # meters
    radiusx = 3000 * 8,           # meters
    radiusy = 3000 * 8,           # meters
    purpose = "edgecase"

  )) |> dplyr::bind_rows() |>
    dplyr::mutate(
      SITE_ID = sprintf("site_%s", purrr::map_chr(location, digest::digest,  algo = "murmur32"))
    )
}



fill_values <- function(x) {

  fake <- basename(tempfile())
  dummy_defaults <- tibble::tibble(location = fake, radiusx = 3000, radiusy = 3000,
                                   resolution = 10, start_date = "2015-01-01", end_date = format(Sys.Date()), purpose = "none")
  x <- dplyr::bind_rows(dummy_defaults, x)[-1L, ]
  for (var in c("resolution", "radiusx", "radiusy", "start_date", "end_date", "purpose")) {
    bad <- is.na(x[[var]])
    x[[var]][bad] <- dummy_defaults[[var]][1L]
  }

  x
}


#' Compute spatial window for location
#'
#' Converts lon/lat + buffer to:
#' - UTM CRS (appropriate zone)
#' - Projected extent (xmin, xmax, ymin, ymax)
#' - Lonlat extent (lonmin, lonmax, latmin, latmax)
#'
#' @param locations Data frame with lon, lat, radiusx, radiusy
#' @return Data frame with added spatial fields
compute_spatial_window <- function(locations) {
  locations |>
    mutate(
      crs = mk_utm_crs(lon, lat),

      utm_x = mk_utm_centre_x(lon, lat),
      utm_y = mk_utm_centre_y(lon, lat),
      utm_xmin = utm_x - radiusx,
      utm_xmax = utm_x + radiusx,
      utm_ymin = utm_y - radiusy,
      utm_ymax = utm_y + radiusy
    ) |>
    # buffer_extent and reproj_extent need rowwise or vectorized versions
    rowwise() |>
    mutate(
      crs2 = mk_utm_crs2(crs),
      utm_extent = list(vaster::buffer_extent(c(utm_xmin, utm_xmax, utm_ymin, utm_ymax), resolution)),
      ll_extent = list(reproj::reproj_extent(utm_extent, "EPSG:4326", source = crs2))
    ) |>
    ungroup() |>
    mutate(
      lonmin = purrr::map_dbl(ll_extent, 1),
      lonmax = purrr::map_dbl(ll_extent, 2),
      latmin = purrr::map_dbl(ll_extent, 3),
      latmax = purrr::map_dbl(ll_extent, 4)
    ) |>
    select(-utm_extent, -ll_extent, -crs2) |> mutate(am_cross = lonmax > 180 | lonmin < -180) |>
    split_antimeridian()
}

split_antimeridian <- function(df) {
  no_split <- df |>
    filter(!am_cross) |>
    mutate(am_part = 1L)

  needs_split <- df |> filter(am_cross)

  if (nrow(needs_split) == 0) return(no_split)

  west <- needs_split |> mutate(am_part = 1L, lonmax = 180)
  east <- needs_split |> mutate(am_part = 2L, lonmin = 180)

  bind_rows(no_split, west, east)
}
window_ll_extent <- function(x) {
  unname(unlist(x[c("lonmin", "lonmax", "latmin", "latmax")]))
}


#' Determine UTM CRS from lon/lat
#'
#' @param lon Longitude
#' @param lat Latitude
#' @return EPSG code as string
mk_utm_crs <- function(lon, lat) {
  geographiclib::utmups_fwd(cbind(lon, lat))[["crs"]]
}
mk_utm_crs2 <- function(crs) {
  sprintf("%s +over", PROJ::proj_crs_text(crs ,1L))
}
#' Determine UTM point from lon/lat
#'
#' @param lon Longitude
#' @param lat Latitude
#' @return dataframe with columns x, y in UTM
mk_utm_centre <- function(lon, lat) {
  geographiclib::utmups_fwd(cbind(lon, lat))[, c("x", "y")]
}
mk_utm_centre_x <- function(lon, lat) {
  geographiclib::utmups_fwd(cbind(lon, lat))$x
}
mk_utm_centre_y <- function(lon, lat) {
  geographiclib::utmups_fwd(cbind(lon, lat))$y
}




prepare_locations_clean <- function(locations_current) {

  locations_clean <- locations_current |>
    dplyr::mutate(
      location_orig = location,
      location = location |>
        gsub("_", " ", x = _) |>
        gsub(" (\\d+)m$", " (\\1m)", x = _),
      location_id = sanitize_location(location),
      SITE_ID = sprintf("site_%s",
                        purrr::map_chr(location, ~digest::digest(.x, algo = "murmur32")))
    )

  # Check for collisions
  collisions <- locations_clean |>
    dplyr::count(location_id) |>
    dplyr::filter(n > 1)

  if (nrow(collisions) > 0) {
    warning("Location ID collisions detected!")
    print(locations_clean |>
            dplyr::filter(location_id %in% collisions$location_id) |>
            dplyr::select(location, location_id))
    stop("Fix collisions before proceeding")
  }

  # message("\n=== LOCATION MAPPING ===")
  # locations_clean |>
  #   dplyr::select(location_orig, location, location_id, SITE_ID) |>
  #   print(n = Inf)

  locations_clean |> fill_values()
}

#' Sanitize location name for filesystem
sanitize_location <- function(location) {
  location |>
    tolower() |>
    stringi::stri_trans_general("Latin-ASCII") |>
    gsub("\\s+", "-", x = _) |>
    gsub("[^a-z0-9-]", "", x = _) |>
    gsub("-+", "-", x = _) |>
    gsub("^-|-$", "", x = _)
}





# ASSETS PARQUET FUNCTIONS
#
# Parallel-safe pattern: Each location writes separate Parquet file
# Then consolidate with distinct() in single thread

#' Write assets table to Parquet file (parallel-safe)
#'
#' @param assets_table Tibble with assets for ONE location (from get_assets)
#'   Should have: SITE_ID, location_id, solarday, scene_id, datetime,
#'                cloud_cover, red, green, blue, nir, scl, etc.
#' @param output_dir Directory to write Parquet files
#' @param collection Optional collection name for subfolder
#' @return Character. Path to written Parquet file
write_assets_to_parquet <- function(assets_table,
                                    output_dir = "_targets/assets_parquet",
                                    collection = NULL) {

  # Create output directory
  if (!is.null(collection)) {
    output_dir <- file.path(output_dir, collection)
  }

  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  }

  # Generate unique filename from first row
  # Use SITE_ID + timestamp for uniqueness (in case of re-runs)
  if (nrow(assets_table) == 0) {
    warning("Empty assets table, skipping write")
    return(NA_character_)
  }

  site_id <- assets_table$SITE_ID[1]
  location_id <- assets_table$location_id[1]

  # Filename: location-id_site-id.parquet
  # This ensures one file per location even with multiple runs
  filename <- sprintf("%s_%s.parquet", location_id, site_id)
  filepath <- file.path(output_dir, filename)

  # Write Parquet
  arrow::write_parquet(assets_table, filepath)

  message(sprintf("Wrote %d assets for %s to %s",
                  nrow(assets_table), location_id, filepath))

  # Return filepath for targets tracking
  filepath
}

#' Consolidate all Parquet files with deduplication
#'
#' @param parquet_dir Directory containing Parquet files
#' @param parquet_files Character vector of Parquet file paths (from targets)
#' @param dedup_keys Character vector of columns to deduplicate on
#' @return Tibble with consolidated, deduplicated assets
consolidate_assets_parquet <- function(parquet_dir = "_targets/assets_parquet",
                                       parquet_files = NULL,
                                       dedup_keys = c("SITE_ID", "datetime")) {

  message("\n=== CONSOLIDATING ASSETS ===")

  # Read all Parquet files
  if (!is.null(parquet_files)) {
    # Use provided file list (from targets)
    parquet_files <- parquet_files[!is.na(parquet_files)]
    if (length(parquet_files) == 0) {
      warning("No Parquet files to consolidate")
      return(tibble::tibble())
    }
    message(sprintf("Reading %d Parquet files", length(parquet_files)))
  } else {
    # Scan directory
    parquet_files <- list.files(parquet_dir,
                                pattern = "\\.parquet$",
                                full.names = TRUE,
                                recursive = TRUE)
    message(sprintf("Found %d Parquet files in %s",
                    length(parquet_files), parquet_dir))
  }

  # Read with Arrow dataset for efficiency
  assets_all <- arrow::open_dataset(parquet_files) |>
    dplyr::collect()

  message(sprintf("Read %d total assets", nrow(assets_all)))

  # Deduplicate by keys
  # Keep the LATEST datetime for each (SITE_ID, solarday)
  assets_deduped <- assets_all |>
    dplyr::arrange(SITE_ID, solarday, dplyr::desc(datetime)) |>
    dplyr::distinct(!!!rlang::syms(dedup_keys), .keep_all = TRUE)

  n_removed <- nrow(assets_all) - nrow(assets_deduped)
  if (n_removed > 0) {
    message(sprintf("Removed %d duplicates", n_removed))
  }

  # Summary
  message("\n=== CONSOLIDATION SUMMARY ===")
  summary <- assets_deduped |>
    dplyr::group_by(SITE_ID) |>
    dplyr::summarise(
      location_id = dplyr::first(location_id),
      n_assets = dplyr::n(),
      date_range = sprintf("%s to %s",
                           min(solarday, na.rm = TRUE),
                           max(solarday, na.rm = TRUE)),
      .groups = "drop"
    )

  print(summary, n = Inf)

  message(sprintf("\nTotal: %d assets across %d locations",
                  nrow(assets_deduped),
                  dplyr::n_distinct(assets_deduped$SITE_ID)))

  assets_deduped
}

#' Write consolidated assets to single Parquet file
#'
#' @param assets_consolidated Consolidated assets tibble
#' @param output_path Path to write final Parquet file
#' @return Character. Path to written file
write_consolidated_assets <- function(assets_consolidated,
                                      output_path = "_targets/assets_consolidated.parquet") {

  # Create directory if needed
  output_dir <- dirname(output_path)
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  }

  # Write
  arrow::write_parquet(assets_consolidated, output_path)

  message(sprintf("Wrote consolidated assets to %s", output_path))
  message(sprintf("Size: %.1f MB", file.size(output_path) / 1024^2))

  output_path
}






