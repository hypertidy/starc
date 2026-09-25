# MGRS bridge: map aatgrid tiles to the Sentinel-2 MGRS tiles that can
# contribute pixels to them.
#
# aatgrid tiles are the render/analysis vocabulary; MGRS codes are the
# acquisition vocabulary (starc's acquisition `tile` field). This join
# drives both the render plan (which products intersect this tile) and
# the harvest_mgrs backfill lattice (region -> tile block -> codes x
# months).
#
# Geometry model: a Sentinel-2 scene's extent is its 100 km MGRS square
# buffered by 4900 m on every side (109800 m tiles, ~9.8 km overlap
# between neighbours). VERIFY against real proj:transform from the
# starc raw stash before first production use (see
# verify-mgrs-model.R); the buffer constant is the one assumption here
# that is convention, not arithmetic.
#
# Suggests: geographiclib



#' Candidate MGRS codes near a zone/band, from the code string alone
#'
#' Cheap prefilter over the valid-codes table: zone number within +/- 1
#' (S2 covers zone boundaries from both sides) and latitude band
#' adjacent to the tile's. Avoids touching all 28,696 codes.
#' @keywords internal
mgrs_candidates <- function(zone_number, lat_bands, valid) {
  zn <- as.integer(substr(valid, 1, 2))
  band <- substr(valid, 3, 3)
  ## wrap zones 1 and 60
  near <- abs(zn - zone_number) <= 1 |
    abs(zn - zone_number) == 59
  valid[near & band %in% lat_bands]
}

#' Map aatgrid tiles to intersecting Sentinel-2 MGRS scenes
#'
#' Same-zone pairs intersect by interval arithmetic (both rectangles in
#' one CRS). Cross-zone pairs reproject the buffered scene extent into
#' the tile's zone via densified project_extent() -- the corner-only
#' trap applies to MGRS squares exactly as it did to Heard's bbox.
#'
#' @param tiles data.frame from tiles_for_extent2() (tile_id, zone_id,
#'   res, col, row)
#' @param valid Character vector of valid S2 MGRS codes (see
#'   starc's inst/extdata/valid_mgrs_sentinel2.parquet)
#' @param lat_bands Latitude band letters to consider (derive from the
#'   tiles' latitude range; e.g. c("C", "D", "E") around 53S-77S)
#' @return long data.frame: tile_id, mgrs, same_zone,
#'   offset60 (scene-origin easting mod 60 in the tile's CRS frame --
#'   whether 60 m assets land lattice-aligned or sub-pixel shifted)
#' @export
tiles_to_mgrs <- function(tiles, valid, lat_bands) {
  stopifnot(length(unique(tiles$zone_id)) == 1L)
  zp <- parse_tile_id(tiles$tile_id[1])
  tile_epsg <- sprintf("EPSG:%s%02d",
                       if (zp$hemisphere == "N") "326" else "327",
                       zp$zone_number)
  cands <- mgrs_candidates(zp$zone_number, lat_bands, valid)

  tex <- tile_index_to_extent(tiles$col, tiles$row, tiles$res[1])
  out <- vector("list", length(cands))
  for (k in seq_along(cands)) {
    me <- mgrs_extent(cands[k])
    same_zone <- me$zone_number == zp$zone_number &&
      me$hemisphere == zp$hemisphere
    ex <- if (same_zone) {
      me$extent
    } else {
      ## densified reprojection of the scene extent into the tile zone
      project_extent(utm_extent_to_lonlat(me$extent, me$epsg),
                     tile_epsg)
    }
    hit <- tex$xmin < ex[2] & tex$xmax > ex[1] &
           tex$ymin < ex[4] & tex$ymax > ex[3]
    if (any(hit)) {
      out[[k]] <- data.frame(
        tile_id = tiles$tile_id[hit],
        mgrs = cands[k],
        same_zone = same_zone,
        offset60 = if (same_zone) (me$extent[1] %% 60) else NA_real_,
        stringsAsFactors = FALSE
      )
    }
  }
  do.call(rbind, out)
}

#' Lonlat bbox of a UTM extent, densified (helper for cross-zone)
#' @keywords internal
utm_extent_to_lonlat <- function(extent, epsg, n = 21) {
  ## project_extent in reverse: densify in the UTM frame, transform to
  ## lonlat, take the bbox
  b <- extent_boundary(extent, n)
  xy <- as.matrix(PROJ::proj_trans(b, "EPSG:4326", source_crs = epsg))
  c(min(xy[, 1]), max(xy[, 1]), min(xy[, 2]), max(xy[, 2]))
}
