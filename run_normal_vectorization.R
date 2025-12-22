provider <-  "https://earth-search.aws.element84.com/v1/search"
collection <- "sentinel-2-c1-l2a"
## we can have 1 or many locations, only location,lon,lat are mandatory
##  optional: resolution,radiusx,radiusy,purpose,start_date,end_date [YYYY-mm-dd]
locations <- tibble::tibble(
  location = c("The 45x90 Geographical Marker", "The 45x90W Geographical Marker"),
  lon = c(90, -90),
  lat = 45,
  resolution = 10,           # meters
  radiusx = 5000,           # meters
  radiusy = 5000,           # meters
  purpose = "trivia") |> prepare_locations_clean()

  ## put this where you like, a bunch of temp-parquet will be created, consolidated below
 assets_parquet_store <- tempdir()

 # # Compute spatial window (UTM CRS, bbox in projected + lonlat)
 spatial_window <- compute_spatial_window(locations)
 query_specs <- prepare_query(spatial_window, collection, provider)
 #
 #
 # # Process assets (parallel, by location)
 # assets_table <- get_assets_from_urls(query_specs) |>
 #   tar_target(pattern = map(query_specs), iteration = "list")
 #
  # # Output Configuration
  # # OPTIONS:
  # # - Local: tempdir()
  # # - S3: sprintf("/vsis3/%s", bucket)
  # # Local development (fast, no S3 dependency)
  # store_local <- sprintf("%s/%s", tempdir(), collection) |> tar_target()  # Change to /vsis3/estinel for S3
  #
  # # Production S3 (persistent)
  # store_s3 <- sprintf("/vsis3/%s/%s", bucket, collection) |> tar_target()
  #
  # # Choose which to use
  # store <- store_local |> tar_target()  # or store_local for testing


  # # =============================================================================
  # # ADD KEYS (Minimal - just what's needed for join)
  # # =============================================================================
  #
  # # Add SITE_ID for joining later
  # # solarday already in assets_table from get_assets()
  # assets_with_keys <- assets_table |>
  #   dplyr::mutate(
  #     SITE_ID = spatial_window$SITE_ID,
  #     location_id = spatial_window$location_id,
  #     collection = collection  # Add collection for completeness
  #   ) |>
  #   tar_target(pattern = map(assets_table, spatial_window))
  # assets_parquet_store <- "_targets/assets_parquet" |> tar_target()
  # # Write to Parquet (parallel, safe for concurrent writes)
  # # Each branch gets its own file
  # assets_parquet <- write_assets_to_parquet(
  #   assets_with_keys,
  #   output_dir = assets_parquet_store
  # ) |>
  #   tar_target(
  #     pattern = map(assets_with_keys),
  #     format = "file"  # Track file path
  #   )
  #
  # # =============================================================================
  # # SINGLE-THREAD: Consolidate with distinct()
  # # =============================================================================
  #
  # # Read all parquets and deduplicate
  # # Key: (SITE_ID, solarday) - uniquely identifies a scene for a location
  # assets_consolidated <- consolidate_assets_parquet(
  #   parquet_dir = assets_parquet_store,
  #   parquet_files = assets_parquet
  # ) |>
  #   tar_target()
  #
  # # Optional: Write final consolidated file
  # assets_file <- write_consolidated_assets(
  #   assets_consolidated,
  #   output_path = "_targets/assets_all.parquet"
  # ) |> tar_target(format = "file")
  #
  #
  #
  # # Join spatial
  # assets_with_spatial <- assets_consolidated |>
  #   #dplyr::filter(cloud_cover < 30) |>
  #   dplyr::left_join(spatial_window, by = c("SITE_ID", "location_id")) |>
  #   tar_target()
