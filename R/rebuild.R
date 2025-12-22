

#' Define test location (Noville Peninsula)
#'
#' @return Data frame with single location
define_test_location <- function() {
  list(tibble::tibble(
    location = "Noville Peninsula",
    lon = 163.0833,
    lat = -77.5167,
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

  )) |> dplyr::bind_rows() |>
    dplyr::mutate(
      SITE_ID = sprintf("site_%s", purrr::map_chr(location, digest::digest,  algo = "murmur32"))
    )
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

  # Determine UTM CRS
  crs <- mk_utm_crs(locations$lon, locations$lat)

  ## determine UTM centre
  utmcent <- mk_utm_centre(locations$lon, locations$lat)

  # Reproject to UTM
  utm_extent <- c(utmcent$x -locations$radiusx,utmcent$x + locations$radiusx,
                  utmcent$y -locations$radiusy,utmcent$y + locations$radiusy)

  # Snap to resolution
  utm_extent <- vaster::buffer_extent(utm_extent, locations$resolution)

  # Compute lonlat extent
  ll_extent <- reproj::reproj_extent(utm_extent, "+proj=longlat", source = crs)

  if (crs %in% c("EPSG:32601", "EPSG:32701", "EPSG:32660", "EPSG:32760")) {
    crs2 <- sprintf("%s +over", PROJ::proj_crs_text(crs ,1L))
    ll_extent <- reproj::reproj_extent(utm_extent, "EPSG:4326", source = crs2)
  }
  # Add to locations table
  locations |>
    dplyr::mutate(
      crs = crs,
      xmin = utm_extent[1],
      xmax = utm_extent[2],
      ymin = utm_extent[3],
      ymax = utm_extent[4],
      lonmin = ll_extent[1],
      lonmax = ll_extent[2],
      latmin = ll_extent[3],
      latmax = ll_extent[4]
    )
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
#' Determine UTM point from lon/lat
#'
#' @param lon Longitude
#' @param lat Latitude
#' @return dataframe with columns x, y in UTM
mk_utm_centre <- function(lon, lat) {
  geographiclib::utmups_fwd(cbind(lon, lat))[, c("x", "y")]
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
            dplyr::select(location_orig, location, location_id))
    stop("Fix collisions before proceeding")
  }

  # message("\n=== LOCATION MAPPING ===")
  # locations_clean |>
  #   dplyr::select(location_orig, location, location_id, SITE_ID) |>
  #   print(n = Inf)

  locations_clean
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


#' Prepare STAC query
#'
#' @param spatial_window Spatial window with bbox
#' @param start_date Start date
#' @param end_date End date
#' @return Query specification
prepare_query <- function(spatial_window, start_date, end_date, collections, provider) {
  # TODO: Implement query preparation
  # Use sds::stacit() to build query URL
  #args(sds::stacit)
  sds::stacit(window_ll_extent(spatial_window), c(start_date, end_date), collections = collections, provider = provider, limit = 300)
}
get_assets_from_urls <- function(query_urls) {

  if (length(query_urls) > 1) {
    # Multiple queries (anti-meridian case)
    results <- lapply(query_urls, get_assets_single)
    dplyr::bind_rows(results)
  } else {
    results <- get_assets_single(query_urls)
  }

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





