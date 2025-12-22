# in starc/R/targets.R
starc_targets_assets <- function()  {
  list(
    targets::tar_target(spatial_window, compute_spatial_window(locations), pattern = map(locations)),
    tar_target(query_specs,
               prepare_query(spatial_window,collection, provider),
               pattern = map(spatial_window), iteration = "list"),
    tar_target(assets_table, get_assets_from_urls(query_specs), pattern = map(query_specs), iteration = "list"),
    tar_target(assets_with_keys,
               assets_table |> dplyr::mutate(SITE_ID = spatial_window$SITE_ID, location_id = spatial_window$location_id, collection = collection),
               pattern = map(assets_table, spatial_window)),


    tar_target(assets_parquet,
               write_assets_to_parquet(
                 assets_with_keys,
                 output_dir = assets_parquet_store
               ),
               pattern = map(assets_with_keys),
               format = "file"  # Track file path
    ),


    tar_target(assets_consolidated, consolidate_assets_parquet(
      parquet_dir = assets_parquet_store,
      parquet_files = assets_parquet)),
    tar_target(assets_file,  write_consolidated_assets(
      assets_consolidated,
      output_path = "_targets/assets_all.parquet"), format = "file"),
    tar_target(assets_with_spatial, assets_consolidated |>
                 #dplyr::filter(cloud_cover < 30) |>
                 dplyr::left_join(spatial_window, by = c("SITE_ID", "location_id")))



  )
}
