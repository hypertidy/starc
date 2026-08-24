# browness: a seeded pattern detector on a structured research grid

Design note, August 2026. Companion and successor to the starc design
doc (reference cache) and the aatgrid package (grid arithmetic). This
document states the mission those two components exist to serve.

## Mission

Maintain, for a curated set of regions on a fixed multi-resolution
grid, a continuous wavelength-rich record of surface change at the
ice-free fringe -- and use known biological sites (penguin colonies,
seabird colonies, seal wallows, stations) to calibrate a cheap spectral
signal ("browness": organic staining and bare-ground change against
snow, ice, and rock) into a detector whose alerts justify pulling
deeper, richer, costlier data streams at specific places and times.

Cheap and everywhere finds the pattern; expensive and targeted resolves
it. The system's product is a ranked, evidenced candidate list: sites
a, b, c, each with the anomaly, its timing, and the question a richer
stream would answer.

## Why this works

- The signal is real and established: emperor colonies were discovered
  and are monitored from space by guano staining; Adelie colony extent
  has been mapped from Landsat-class data by the same signature;
  elephant seal wallows, other seabird aggregations, and vegetation
  change on subantarctic islands are the same class of spectral event
  (dark organic staining / bare-ground change on a bright or stable
  background).
- Ground truth is in-house: Bechervaise (CEMP Adelie monitoring,
  decades of annual truth), Macquarie (seals + royal/king colonies +
  vegetation monitoring + permanent station), Auster and Amanda Bay
  (emperor, near Mawson operations), Heard (colonies without station
  disturbance). Calibration is against AAD's own long-term programs.
- The substrate is already built: starc holds every asset of every
  matching scene as references (23 asset keys including per-pixel cloud
  and snow probability); aatgrid gives uniform, exactly nested,
  Sentinel-2-pixel-aligned tiles; the 82-region seed covers the
  emperor ring, the subantarctic islands, and the stations.

## The two-tier attention model

The grid's two levels are the detector's two tiers.

- Tier P (peripheral, L1 = 60 m, 36 km tiles): per-tile, per-solarday
  band statistics for every region, every scene, all weather. Cheap
  enough to never skip. This is where patterns are noticed.
- Tier F (foveal, L2 = 10 m, 6 km tiles): multi-band chips over tiles
  the periphery (or prior knowledge) marks interesting. This is where
  patterns are measured: extent, centroid, texture, change.
- Tiers beyond the archive (escalation targets, in cost order):
  - Sentinel-1 EW NRB backscatter (DE Antarctica): fast-ice state,
    breakout timing, all-weather winter continuity.
  - DEA / GA ARD optical (terrain- and illumination-corrected): the
    quality tier for Australian-sector radiometry when coverage lands.
  - Commercial VHR: individual-scale confirmation, priced per km2,
    pulled only on evidence.

Nesting is exact by construction (60/10 divides, pixel lattices
coincide), so tier-P statistics are true aggregations of tier-F pixels;
"zoom in" is arithmetic, not resampling.

## What is stored

Per (tile_id, solarday, product): written once, appended forever,
keyed on the aatgrid tile id and the starc acquisition chain.

1. summaries (parquet; the always-on layer)
   - per-band: n_valid, mean, sd, quantiles (5) for each of
     red, green, blue, nir, swir16, swir22 (extendable by
     band_semantics common_name)
   - per-pixel-quality: mean cloud_prob, mean snow_prob, scl class
     histogram, fraction valid
   - derived candidates: band ratios / indices are computed AT READ
     TIME from the band summaries where linear, and from chips where
     not; no index is baked into storage (the right browness
     formulation is an empirical question and must stay revisable)
2. chips (COG per tile-solarday; the foveal layer)
   - multi-band (visible + nir + swir + quality layers), 600x600,
     tile_gt as the warp target
   - written for: all tiles containing known sites (the seed), plus
     tiles flagged by tier P, plus a background sample for negatives
3. labels
   - known-site geometry: colony/wallow/station footprints per tile
     (the seed pattern: "stuff we know, hey that's happy feet")
   - human annotations: the estinel catalog browser's rating machinery
     repurposed as an annotation surface over chips; graded scenes are
     training data

Clouds are weights, not filters. Nothing is discarded for weather; the
per-pixel cloud/snow probabilities ride into every summary and every
analysis as uncertainty. (This inverts the browse-product rule, and it
is the main reason the science layer is not estinel: a gallery must
drop bad images, a detector must not drop bad days.)

## Trigger semantics

A trigger is a standing query over the summaries, evaluated per region
per new solarday batch. First set (deliberately simple):

- appearance: browness signal in a tile with no historical signal
  (candidate new colony / haul-out; this is how recent emperor
  colonies were actually found)
- disappearance / early decline: signal absent or collapsing during
  the expected season (candidate breeding failure; cross-examine
  fast-ice state via S1 EW at that place and fortnight)
- displacement: signal centroid moved beyond tolerance (candidate
  relocation; foveal chips first, VHR if confirmed)
- background drift: fringe-wide monotonic change over seasons
  (vegetation / exposure change; flag for the relevant program)

Each fired trigger emits: region, tiles, solardays, signal series,
uncertainty, and the named escalation with its expected
information gain. Triggers write to a log table; the log IS the
candidate list.

## Seeding and calibration plan

1. Freeze the known-site layer: colony and wallow footprints for the
   82 regions (AAD sources; the gazetteer work supplies names, the
   mapping layers supply geometry).
2. Backfill tier P from starc references for all regions (compute
   summaries across the full archive; order weeks of compute, not
   months -- it is one warp + reduce per tile-solarday).
3. Calibrate browness candidates against the ground-truth sites:
   separability of known colony tiles vs matched background tiles,
   per season, per signal class (emperor-on-ice, adelie-on-rock,
   seal-wallow, vegetation). Choose formulations empirically, with the
   remote sensing specialists; store the analysis, not the index.
4. Validate triggers retrospectively: known events (documented
   breeding failures, known relocations, Macquarie vegetation change)
   must fire; quantify false-positive load on the background sample.
5. Go prospective: evaluate triggers per harvest batch; route the
   candidate list.

## Scope boundary

The grid keeps expansion honest: a region is a set of tile ids, so
growth is deliberate, region by region, purpose by purpose. Curated
regions with scientific anchors are in scope; systematic continental
coverage is Digital Earth Antarctica's mandate and explicitly out of
scope. The candidate list is the interface between the two: this
system's alerts are, among other things, well-formed requests to the
systematic programs.

## Relationship to existing components

- aatgrid: the spatial vocabulary (ids, extents, geotransforms,
  nesting). No changes required.
- starc: the temporal vocabulary (what exists, all bands, all
  providers). No changes required; the 82-region sweep is the
  immediate prerequisite.
- estinel: demoted, not deleted. The browse pipeline keeps running at
  zero investment; its catalog browser's rating machinery is the
  annotation surface; its rendered-solarday record is the validation
  set already used to close starc rung 1.
- routing policy: gains a scientific reading -- preferred provider per
  region per QUESTION (radiometry -> ARD; ice state -> EW NRB;
  individuals -> VHR).

## Open questions (deliberately open)

- The browness formulation(s) per signal class: empirical, with the
  specialists, against the seed truth.
- Chip retention policy beyond seed + flagged + sample (storage is
  cheap but not free at 82 regions x decade x all-weather).
- Trigger thresholds: set retrospectively in step 4, reviewed with the
  monitoring programs they would notify.
- Polar-stereographic sibling grid: not needed (all sites within UTM's
  80S domain) until a deep-field purpose appears.
