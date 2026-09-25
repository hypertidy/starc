starc

A provider-agnostic STAC reference cache: harvests discovery results into an append-only Parquet store with four levels -- queries, acquisitions, products, assets -- recording every asset reference verbatim with no fixed band vocabulary. Markers and coverage are derived views, never stored state. Stores references, never pixels.

Design: inst/docs/design.md (the cache) and inst/docs/browness.md (the mission it serves). Two harvest modes: harvest() by region bbox, harvest_mgrs() by grid:code + month (deterministic, resumable; folded in from the rstarc experiment). Overlapping and repeated harvests are safe by design: dedup happens at read.

r
regions <- read.csv(system.file("extdata/regions-seed-example.csv", package = "starc"))
harvest(regions[1, ], "https://earth-search.aws.element84.com/v1/search",
        "sentinel-2-c1-l2a", "2015-01-01", format(Sys.Date()))
marker()
marker_region()

Validated against 82 Antarctic and subantarctic regions: 54,901 acquisitions, ~1.26M asset references, from a cold start in an afternoon. The Sentinel-2 MGRS scene-extent convention used by the aatgrid bridge was verified against 132 archive products from this store to 0 m residual.

Predecessors: the v0 wide-table implementation survives on the vectorization-refactor branch; hypertidy/rstarc contributed the MGRS harvest mode.
