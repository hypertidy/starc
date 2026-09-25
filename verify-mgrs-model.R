# Verify the MGRS scene-extent model against the starc raw stash.
#
# The geometric model says: scene extent = 100 km MGRS square + 4900 m
# buffer on every side. Every raw item in the store carries the actual
# produced geometry (proj:transform, proj:shape, proj:epsg), so the
# model is checkable against every distinct MGRS code ever harvested --
# a few hundred codes, no network, one pass over the stash.
#
# Expected outcome: max abs difference 0 m on all four edges for every
# code. Any nonzero difference is a fact about the archive worth
# recording (and the model constant should then be corrected or made
# per-code).

library(dplyr)

store <- "~/starc-store"

## one product per distinct MGRS code
a <- arrow::open_dataset(file.path(store, "acquisitions")) |>
  select(acquisition_id, tile) |> collect() |> distinct()
p <- arrow::open_dataset(file.path(store, "products")) |>
  select(product_id, acquisition_id) |> collect() |>
  distinct(product_id, .keep_all = TRUE)
one <- inner_join(p, a, by = "acquisition_id") |>
  group_by(tile) |> slice(1) |> ungroup()
message(nrow(one), " distinct MGRS codes in the store")

read_raw <- function(product_id) {
  f <- file.path(store, "raw", "sentinel-2-c1-l2a",
                 sprintf("%s.json.gz", product_id))
  jsonlite::fromJSON(gzfile(f), simplifyVector = FALSE)
}

## actual extent from proj metadata; transform is row-major affine
## [xres, 0, xmin, 0, -yres, ymax, ...]; shape is [nrow, ncol]
actual_extent <- function(item) {
  a <- item$assets$red                      # any 10 m band
  if (!is.null(a[["proj:bbox"]])) {
    bb <- unlist(a[["proj:bbox"]])          # xmin ymin xmax ymax
    return(bb[c(1, 3, 2, 4)])
  }
  tr <- unlist(a[["proj:transform"]]); sh <- unlist(a[["proj:shape"]])
  if (is.null(tr) || is.null(sh)) return(NULL)
  xmin <- tr[3]; ymax <- tr[6]
  c(xmin, xmin + tr[1] * sh[2], ymax + tr[5] * sh[1], ymax)
}



model_extent <- function(mgrs, buffer = 4900) {
  me <- mgrs_extent(mgrs)   # from aatgrid-mgrs.R
  me$extent
}

check <- lapply(seq_len(nrow(one)), function(i) {
  it <- read_raw(one$product_id[i])
  act <- actual_extent(it)
  if (is.null(act)) return(NULL)
  mod <- model_extent(one$tile[i])
  data.frame(tile = one$tile[i],
             dxmin = act[1] - mod[1], dxmax = act[2] - mod[2],
             dymin = act[3] - mod[3], dymax = act[4] - mod[4])
}) |> bind_rows()

summary(abs(as.matrix(check[-1])))
bad <- filter(check, if_any(-tile, ~ abs(.x) > 0.5))
if (nrow(bad) > 0) {
  message("model deviations (metres):"); print(bad)
} else {
  message("scene-extent model exact for all ", nrow(check), " codes")
}

