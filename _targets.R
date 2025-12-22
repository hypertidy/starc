# ==============================================================================
# ESTINEL V2 - BAREBONES PIPELINE
# ==============================================================================
# Minimal locations: Noville_Peninsula, Fiji for testing
# Configurable: endpoint, provider, collection, rootdir
# Works with local (tempdir) or S3 (/vsis3/estinel)
# ==============================================================================

library(targets)
library(tarchetypes)

# Essential packages
pkgs <- c("dplyr", "jsonlite", "reproj", "sds", "gdalraster", "vapour", "crew")

ncpus <- 24
log_directory <- "_targets/logs"

tar_option_set(
  controller = if (ncpus <= 1) NULL else crew::crew_controller_local(
    workers = ncpus
    #,options_local = crew_options_local(log_directory = log_directory)
  ),
  format = "qs",
  packages = pkgs
)


# Load functions
tar_source()

tar_assign({

  # =============================================================================
  # CONFIGURATION
  # =============================================================================

  # S3 Configuration
  bucket <- "estinel" |> tar_target()
  endpoint <- "https://projects.pawsey.org.au" |> tar_target()
  # STAC Configuration
  provider <- "https://earth-search.aws.element84.com/v1/search" |> tar_target()
  collection <- "sentinel-2-c1-l2a" |> tar_target()

  # Output Configuration
  # OPTIONS:
  # - Local: tempdir()
  # - S3: sprintf("/vsis3/%s", bucket)
  # Local development (fast, no S3 dependency)
  store_local <- sprintf("%s/%s", tempdir(), collection) |> tar_target()  # Change to /vsis3/estinel for S3

  # Production S3 (persistent)
  store_s3 <- sprintf("/vsis3/%s/%s", bucket, collection) |> tar_target()

  # Choose which to use
  store <- store_local |> tar_target()  # or store_local for testing


  # test locations, includes antimeridian
  locations <- define_test_location() |> prepare_locations_clean() |>  tar_target()

  # Compute spatial window (UTM CRS, bbox in projected + lonlat)
  spatial_window <- compute_spatial_window(locations) |> tar_target(pattern = map(locations))
  query_specs <- prepare_query(spatial_window,start_date = "2015-01-01",
                               end_date = format(Sys.Date()), collection, provider) |>
    tar_target(pattern = map(spatial_window), iteration = "list")


  # Process assets (parallel, by location)
  assets_table <- get_assets_from_urls(query_specs) |>
    tar_target(pattern = map(query_specs), iteration = "list")

  # =============================================================================
  # ADD KEYS (Minimal - just what's needed for join)
  # =============================================================================

  # Add SITE_ID for joining later
  # solarday already in assets_table from get_assets()
  assets_with_keys <- assets_table |>
    dplyr::mutate(
      SITE_ID = spatial_window$SITE_ID,
      location_id = spatial_window$location_id,
      collection = collection  # Add collection for completeness
    ) |>
    tar_target(pattern = map(assets_table, spatial_window))
  assets_parquet_store <- "_targets/assets_parquet" |> tar_target()
  # Write to Parquet (parallel, safe for concurrent writes)
  # Each branch gets its own file
  assets_parquet <- write_assets_to_parquet(
    assets_with_keys,
    output_dir = assets_parquet_store
  ) |>
    tar_target(
      pattern = map(assets_with_keys),
      format = "file"  # Track file path
    )

  # =============================================================================
  # SINGLE-THREAD: Consolidate with distinct()
  # =============================================================================

  # Read all parquets and deduplicate
  # Key: (SITE_ID, solarday) - uniquely identifies a scene for a location
  assets_consolidated <- consolidate_assets_parquet(
    parquet_dir = assets_parquet_store,
    parquet_files = assets_parquet
  ) |>
    tar_target()

  # Optional: Write final consolidated file
  assets_file <- write_consolidated_assets(
    assets_consolidated,
    output_path = "_targets/assets_all.parquet"
  ) |> tar_target(format = "file")



  # Join spatial
  assets_with_spatial <- assets_consolidated |>
    #dplyr::filter(cloud_cover < 30) |>
    dplyr::left_join(spatial_window, by = c("SITE_ID", "location_id")) |>
    tar_target()


})
