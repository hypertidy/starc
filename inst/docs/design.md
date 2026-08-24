# starc: a provider-agnostic STAC reference cache

Design note, August 2026. Successor to starc 0.1.0. Written against the
estinel rationalization discussion; intended to live at inst/docs/design.md
in hypertidy/starc.

## Purpose

starc is the query-and-record layer for satellite scene discovery. It asks
STAC providers what exists for a set of regions, and records the answers
completely and permanently. It stores references, never pixels.

The one-line justification for completeness: classifying emperor penguin
presence in Sentinel-2 needs more bands than red/green/blue. Rendering is
an application; discovery is not. So the cache records every asset of
every matching item, and applications choose later. The cache is small
(references and metadata only) and each application's pixel cache is a
replay against it.

What starc explicitly is not: a renderer, a pixel store, a marker system,
or a pipeline. estinel and other consumers derive their state from it.

## The layered read model

- Layer 0 (starc, this document): all scenes, all assets, all providers,
  as references. Complete by construction. Order of magnitude: low
  millions of rows, single-digit GB of Parquet, for a decade over the
  full laundry list.
- Layer 1 (estinel browse): RGB + SCL rendered per scene per site window.
  The universal product: one image for every available scene at every
  location. Recipe: assets where common_name in (red, green, blue, scl).
- Layer 2+ (purpose caches): defined per purpose as a recipe against
  Layer 0. Examples: emperor -- multi-band chips (visible + NIR + SWIR)
  over colony windows for guano classification; cetacean/vessel --
  full-resolution crops, later joined by SAR; base operations -- SAR
  backscatter time series for winter continuity. Each is a filter on
  (regions by purpose) x (assets by common_name) x (acquisitions by
  time), rendered to its own grid and store.

Locations/times/purposes split cleanly *because* Layer 0 is complete:
no purpose ever needs to re-query, only re-read.

## Tables

All Parquet, managed as arrow datasets. Partitioning suggestions at the
end. Column types given as R/arrow types. Keys are stated per table;
enforce on the consolidate step (dedup by key, last-write-wins on
refreshed metadata).

### regions

The units of querying. One row per parent grid or singleton site window.
Derived from the estinel cluster analysis; sites reference regions, but
the sites table itself belongs to the consumer (estinel), not to starc.

    region_id      string   key. stable slug, e.g. "heard", "se_tasmania",
                            "scullin_monolith"
    lonmin, lonmax double   query extent in EPSG:4326
    latmin, latmax double
    crosses_am     bool     antimeridian flag; if TRUE the harvester
                            splits into two bbox queries (starc 0.1.0
                            already does this)
    purpose        string   comma-tags, union of member site purposes
    note           string

### queries

The append-only log of every STAC request actually issued. This is the
"rich information about past queries" goal made literal: coverage gaps,
provider outages, and markers are all derived from here.

    query_id       string   key. hash of (region_id, provider, collection,
                            t0, t1, fetched_at)
    region_id      string   -> regions
    provider       string   search endpoint URL
    collection     string   provider-side collection id
    t0, t1         timestamp[us, UTC]   requested window
    fetched_at     timestamp[us, UTC]
    n_items        int32    total items returned across all pages
    n_pages        int32
    status         string   "ok" | "empty" | "error"
    error          string   nullable
    url            string   first-page URL for reproducibility

Semantics: "empty" is a positive fact (we asked, nothing exists);
distinguish it from the absence of a row (we never asked). The
coverage-probe cadence (ask every provider about every region on a slow
schedule) and the incremental cadence (ask only policy-live pairs) both
write here identically.

### acquisitions

Canonical scene identity, independent of provider. One row per physical
acquisition unit. This is the level where "coverage" is a fact and where
solarday lives.

    acquisition_id string   key. constructed, see identity rules below
    platform       string   "sentinel-2a" | "sentinel-2c" | "sentinel-1a" | ...
    instrument     string   "msi" | "c-sar"
    mode           string   MSI: NA; SAR: "IW" | "EW"
    datetime       timestamp[us, UTC]   acquisition start
    solarday       date32   local date at footprint centroid
                            (datetime - centroid_lon/15 hours, rounded)
    centroid_lon   double
    centroid_lat   double
    tile           string   S2: MGRS tile e.g. "43DDE"; S1: burst or
                            frame id e.g. "t070_149815_iw3"
    footprint_wkb  binary   nullable; item geometry when present

Identity rules:

- Sentinel-2: acquisition_id = platform + "_" + MGRS tile + "_" +
  datetime truncated to seconds. The (platform, tile, datetime) triple
  survives the Element84 / Planetary Computer / DEA seam: all three
  serve products of the same granule with these properties intact
  (Element84 and PC carry mgrs:* fields; DEA ARD carries the region
  code in its own metadata -- the mapper normalises). Do NOT use the
  provider item id as identity; it differs per provider and per
  processing baseline.
- Sentinel-1: acquisition_id = platform + "_" + burst_or_frame + "_" +
  start datetime truncated to seconds. GA NRB is burst-level with
  stable burst ids (t{track}_{burstnum}_{subswath}); scene-level
  GRD from other providers uses (platform, absolute orbit, slice) --
  record what the collection gives and keep the rule per-mapper.
- Reprocessings (new processing baseline of the same granule) are the
  SAME acquisition, DIFFERENT product rows.

### products

One row per STAC item per provider: a provider's serving of an
acquisition under a particular processing.

    product_id     string   key. hash of (provider, collection, item_id)
    acquisition_id string   -> acquisitions
    provider       string
    collection     string
    item_id        string   the STAC item id as served
    product_family string   normalised: "l2a" | "ard_nbart" | "nrb" |
                            "l1c" | ... (set by the mapper)
    polarisations  string   SAR only, e.g. "HH" or "VV,VH"; NA for MSI
    epsg           int32    proj:epsg when present
    cloud_cover    double   eo:cloud_cover when present
    baseline       string   processing baseline / product version
    properties     string   nullable; leftover properties as JSON for
                            fields not promoted to columns
    first_seen     timestamp[us, UTC]
    last_seen      timestamp[us, UTC]   updated on re-encounter; lets
                            you notice items that disappear upstream

### assets

Long form; the whole point. No fixed vocabulary anywhere in the harvest.

    product_id     string   key part 1 -> products
    asset_key      string   key part 2. the raw key from the item's
                            assets dict, verbatim: "red", "B04",
                            "nbart_red", "HH-gamma0", "metadata", ...
    href           string
    media_type     string   nullable
    size_bytes     int64    nullable (file:size when present)
    checksum       string   nullable (file:checksum when present)

### band_semantics (static lookup, versioned in the package)

The only place cross-provider unification happens. A small CSV shipped
in inst/extdata, editable by humans.

    collection      asset_key     common_name   gsd_m   notes
    sentinel-2-c1-l2a  red        red           10
    sentinel-2-c1-l2a  nir        nir           10
    sentinel-2-c1-l2a  swir16     swir16        20
    sentinel-2-c1-l2a  scl        scl           20
    sentinel-2-l2a     B04        red           10      planetary computer
    sentinel-2-l2a     SCL        scl           20
    ga_s2am_ard_3      nbart_red  red           10      dea nbart
    ga_s2am_ard_3      oa_fmask   fmask         20      not scl; different
                                                        classing
    ga_s1_nrb          HH-gamma0  gamma0_hh     20
    ...

This retires the ad hoc band_mapping inside estinel's
build_warped_composite. Renderers ask for common_name; the join
resolves per-collection keys. Note fmask vs scl is a semantic
difference, not a naming one -- keep them distinct common_names and
let the clear-sky function dispatch on which it received.

### routing_policy (consumer-owned, but specified here)

Hand-edited. Classification of the laundry list is a derived view,
never a stored column.

    region_id       string   or "*"
    product_family  string   "l2a" | "ard_nbart" | "nrb_iw" | "nrb_ew"
    preferred       string   collection id
    provider        string
    live            bool     include in incremental cadence
    effective_date  date32   for provenance when preferences change
    note            string   e.g. "switch to DEA ARD when coverage
                             confirmed south of -43"

### raw item store (optional, recommended)

Alongside the tables, keep the item JSON gzipped, one object per
product: raw/{collection}/{acquisition solarday year}/{product_id}.json.gz
Items are a few KB; a decade of the laundry list is single-digit GB.
Any property not promoted to a column is recoverable by re-parse, never
by re-query. This is the recipe-not-payload principle applied to the
recipes themselves.

## Mappers

One mapper per collection, registered by collection id. A mapper is two
functions and a declaration; everything else is shared.

    mapper <- list(
      collection = "sentinel-2-c1-l2a",
      product_family = "l2a",
      identity = function(props, item) {
        list(
          platform = tolower(props$platform),
          tile = paste0(props$`mgrs:utm_zone`,
                        props$`mgrs:latitude_band`,
                        props$`mgrs:grid_square`),
          datetime = parse_dt(props$datetime)
        )
      },
      promote = function(props) {
        list(cloud_cover = props$`eo:cloud_cover`,
             epsg = props$`proj:epsg`,
             baseline = props$`s2:processing_baseline`)
      }
    )

Assets need no mapper at all: enumerate the dict verbatim into the long
table. That is the structural guarantee that adding DEA or ga_s1_nrb is
a new mapper file plus band_semantics rows, and zero schema change.

Harvest loop (per query): page through results (keep 0.1.0's rel=next
follower), for each item run the collection's mapper -> upsert
acquisition, upsert product, replace assets for that product, stash raw
JSON, then write the query log row last (so a crash mid-harvest leaves
no "ok" row for an incomplete fetch).

## Derived views (dplyr/arrow on the tables; no stored state)

- marker(region, collection): max(solarday) over acquisitions joined
  through products to queries' region. Replaces estinel's S3 marker
  JSONs entirely; nothing to clear, corrupt, or delete.
- coverage(region): acquisitions per year per product_family; the input
  to "switch to DEA when provided" decisions and to conversations with
  the DE Antarctica team ("here are our regions; here is what we see").
- classification(region): join regions x routing_policy -- the
  DEA-ARD / NRB-IW / NRB-EW / generic-L2A classes, always current.
- cross_provider(acquisition): products per acquisition; answers "which
  solardays does DEA cover that Element84 also covers" as a self-join,
  and proves that switching preferred product never changes the
  temporal record, only the radiometry.
- render_plan(consumer): for estinel Layer 1 --
  new acquisitions since marker, for policy-preferred products, assets
  filtered by common_name in (red, green, blue, scl), grouped by
  (site window, solarday). For a Layer 2 purpose cache the same query
  with a different common_name set and grid.

## Cadence

- incremental: per routing_policy live pairs, t0 = marker + 1 day,
  t1 = now + buffer. Runs every few hours; cheap because pagination
  replaces yearly chunking and regions replace per-site queries
  (Heard: 12 queries -> 1).
- coverage probe: all providers x all regions, wide window, weekly or
  monthly. Discovers new coverage (DEA expansion, DE Antarctica going
  operational, S1C ramp-up) and writes the same tables. Probe discovers,
  policy prefers, pipeline renders.

## Partitioning and layout

    store/
      regions.parquet
      queries/            partition: year(fetched_at)
      acquisitions/       partition: platform-family (s2 | s1)
      products/           partition: collection
      assets/             partition: collection
      raw/                as above
      band_semantics.csv  shipped with the package, copied on init

Consolidation: dedup by stated keys; products update last_seen;
assets replace-by-product. Arrow datasets keep every consumer read
lazy and predicate-pushed.

## Boundaries

- No pixels. Ever. Purpose caches own their pixels and their grids.
- No site table. Sites -> regions membership is estinel's (rung 2 grid
  registry); starc only needs regions.
- No preference logic in the harvest. The harvester records everything
  it is pointed at; routing_policy is read only at plan time.
- Continental systematic coverage is out of scope (Digital Earth
  Antarctica / DEA territory). starc's regions are curated windows.
