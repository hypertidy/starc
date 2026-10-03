# Snapshot: materialized dedup-at-read. The identity rules are pure
# and tested without IO; the full path needs arrow.

test_that("snapshot_dedup applies the read-side identity rules", {
  a <- data.frame(acquisition_id = c("x", "x", "y"), solarday = 1:3)
  expect_identical(nrow(snapshot_dedup("acquisitions", a)), 2L)
  ## first row wins, as in every read-side view
  expect_identical(snapshot_dedup("acquisitions", a)$solarday, c(1L, 3L))

  p <- data.frame(product_id = c("p1", "p1", "p1"),
                  query_id = c("q1", "q1", "q2"))
  ## re-encounter under a NEW query is sighting history: kept
  expect_identical(nrow(snapshot_dedup("products", p)), 2L)

  s <- data.frame(product_id = c("p1", "p1", "p1"),
                  asset_key = c("red", "red", "nir"),
                  href = c("h1", "h1b", "h2"))
  d <- snapshot_dedup("assets", s)
  expect_identical(nrow(d), 2L)
  expect_identical(d$href, c("h1", "h2"))

  q <- data.frame(query_id = c("b", "a"), fetched_at = c(2, 1))
  expect_identical(snapshot_dedup("queries", q)$query_id, c("a", "b"))

  expect_error(snapshot_dedup("nope", a), "unknown store level")
})

test_that("snapshot writes one parquet per level and is rerunnable", {
  skip_if_not_installed("arrow")
  store <- file.path(tempdir(), "snapstore")
  on.exit(unlink(store, recursive = TRUE), add = TRUE)
  wr <- function(sub, df, shard) {
    d <- file.path(store, sub)
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
    arrow::write_parquet(df, file.path(d, sprintf("%s.parquet", shard)))
  }
  ## two overlapping harvests, shard layout as harvest() writes it
  wr("acquisitions", data.frame(acquisition_id = c("a1", "a2"),
                                solarday = c(1, 2)), "q1")
  wr("acquisitions", data.frame(acquisition_id = c("a2", "a3"),
                                solarday = c(2, 3)), "q2")
  wr("products/collection=c1",
     data.frame(product_id = "p1", acquisition_id = "a1",
                query_id = "q1"), "q1")
  wr("products/collection=c1",
     data.frame(product_id = "p1", acquisition_id = "a1",
                query_id = "q2"), "q2")
  wr("assets/collection=c1",
     data.frame(product_id = c("p1", "p1"),
                asset_key = c("red", "nir"),
                href = c("h1", "h2")), "q1")
  wr("assets/collection=c1",
     data.frame(product_id = c("p1", "p1"),
                asset_key = c("red", "nir"),
                href = c("h1", "h2")), "q2")
  wr("queries", data.frame(query_id = "q1", region_id = "r",
                           fetched_at = "2026-01-01T00:00:00Z"), "q1")
  wr("queries", data.frame(query_id = "q2", region_id = "r",
                           fetched_at = "2026-01-02T00:00:00Z"), "q2")

  dir <- file.path(tempdir(), "snapout")
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  man <- snapshot(store, dir)
  expect_identical(man$table,
                   c("queries", "acquisitions", "products", "assets"))
  expect_identical(man$n_row, c(2L, 3L, 2L, 2L))
  expect_true(all(file.exists(man$path)))

  ## derived artifact: regenerating overwrites in place, same answer
  man2 <- snapshot(store, dir)
  expect_identical(man$n_row, man2$n_row)

  ## single-table selection for publishers that want one key
  m1 <- snapshot(store, dir, tables = "acquisitions")
  expect_identical(m1$n_row, 3L)
  a <- arrow::read_parquet(m1$path)
  expect_identical(sort(a$acquisition_id), c("a1", "a2", "a3"))
})
