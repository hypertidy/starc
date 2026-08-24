# Identity model and extraction tests.
#
# The synthetic tests run everywhere. The fixture test uses real raw
# items from a live store when present: copy two datastrip-twin items
# (same acquisition, different item ids -- see the +4 anomaly of
# 2026-08) into tests/testthat/fixtures/ as *.json to enable it.

fake_item <- function(id, datetime = "2026-02-24T12:43:05.000Z",
                      utm_zone = 20, band = "C", square = "NC",
                      assets = list(
                        red = list(href = "https://x/red.tif",
                                   type = "image/tiff"),
                        weird_new_band = list(href = "https://x/w.tif")
                      )) {
  list(
    id = id,
    bbox = list(-60.9, -74.5, -60.1, -74.1),
    properties = list(
      platform = "sentinel-2b",
      datetime = datetime,
      `mgrs:utm_zone` = utm_zone,
      `mgrs:latitude_band` = band,
      `mgrs:grid_square` = square,
      `eo:cloud_cover` = 12.5,
      `proj:epsg` = 32720L,
      `s2:processing_baseline` = "05.12"
    ),
    assets = assets
  )
}

test_that("datastrip twins: one acquisition, two products", {
  m <- mappers[["sentinel-2-c1-l2a"]]
  a <- extract_item(fake_item("S2B_T20CNC_20260224T124156_L2A"),
                    "earth-search", "sentinel-2-c1-l2a", m)
  b <- extract_item(fake_item("S2B_T20CNC_20260224T124116_L2A"),
                    "earth-search", "sentinel-2-c1-l2a", m)
  expect_identical(a$acquisitions$acquisition_id,
                   b$acquisitions$acquisition_id)
  expect_false(identical(a$products$product_id, b$products$product_id))
  expect_identical(a$acquisitions$acquisition_id,
                   "sentinel-2b_20CNC_20260224T124305Z")
})

test_that("assets enumerate verbatim with no vocabulary", {
  m <- mappers[["sentinel-2-c1-l2a"]]
  e <- extract_item(fake_item("x"), "earth-search", "sentinel-2-c1-l2a", m)
  expect_setequal(e$assets$asset_key, c("red", "weird_new_band"))
  expect_identical(e$assets$media_type[e$assets$asset_key == "weird_new_band"],
                   NA_character_)
})

test_that("solarday shifts by centroid longitude", {
  ## 12:43 UTC at ~-60.5E: local ~08:41 same day
  expect_identical(solarday_at("2026-02-24T12:43:05.000Z", -60.5),
                   as.Date("2026-02-24"))
  ## 23:30 UTC at 150E: local ~09:30 NEXT day
  expect_identical(solarday_at("2026-02-24T23:30:00.000Z", 150),
                   as.Date("2026-02-25"))
})

test_that("pad_extent inflates a degenerate point extent", {
  ex <- pad_extent(c(110.53, 110.53, -66.282, -66.282), min_km = 5)
  expect_true(ex[1] < ex[2])
  expect_true(ex[3] < ex[4])
  ## lon pad grows with latitude
  ex80 <- pad_extent(c(0, 0, -77.6, -77.6), min_km = 5)
  expect_gt(diff(ex80[1:2]), diff(ex[1:2]))
})

test_that("month_window covers whole months including leap February", {
  w <- month_window("2024-02")
  expect_identical(w[["t0"]], "2024-02-01T00:00:00Z")
  expect_identical(w[["t1"]], "2024-02-29T23:59:59Z")
})

test_that("real raw items round-trip (fixture-gated)", {
  fx <- list.files(test_path("fixtures"), pattern = "\\.json$",
                   full.names = TRUE)
  skip_if(length(fx) < 2, "copy two datastrip-twin raw items to fixtures/")
  m <- mappers[["sentinel-2-c1-l2a"]]
  ex <- lapply(fx, function(f) {
    extract_item(jsonlite::fromJSON(f, simplifyVector = FALSE),
                 "earth-search", "sentinel-2-c1-l2a", m)
  })
  acq <- unique(vapply(ex, function(e) e$acquisitions$acquisition_id,
                       character(1)))
  expect_length(acq, 1L)
})
