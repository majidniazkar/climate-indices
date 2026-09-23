# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/).

## [1.1.0] - 2026-09-22

### Added

- `scripts/calculate_spi.R`: Standardized Precipitation Index (McKee et al.
  1993) at any set of accumulation scales, from a workbook of date and
  precipitation only. No temperature and no latitude are needed.
- `--sheet all`, which processes every worksheet in the input workbook and
  writes one result sheet, CSV and figure per station.
- Zero-inflation correction for SPI following Edwards & McKee (1997):
  `SPEI::spi()` places a zero accumulation at cumulative probability zero and
  returns -Inf, so zero months are instead evaluated under the mixed
  distribution H(x) = q + (1 - q) G(x), with the gamma fitted by the Thom
  (1958) estimator to the positive accumulations of that calendar month.
  Disable with `--no-zero-correction`.
- `R/spi_index.R`, and `R/classify.R` holding the wet/dry classification and
  category summary now shared by both indices.
- Multi-station synthetic example workbook `synthetic_daily_precipitation.xlsx`
  (three worksheets, one semi-arid with zero months).
- 21 further unit checks, including that SPI is fitted per calendar month and
  that it does not reduce to a z-score of the rolling sum.

### Changed

- `read_climate_excel()` takes a `fields` argument, so a caller can accept a
  two-column precipitation-only sheet; `aggregate_to_monthly()` and
  `standardise_monthly()` no longer require a `Temperature` column.
- `write_results()` now takes a named list of worksheets rather than a fixed
  SPEI triple, and writes one CSV per data sheet.
- `R/plot_spei.R` became `R/plot_index.R` with `plot_index_panels()`, which
  takes the axis label and an optional panel title. `plot_spei_panels()` and
  `classify_spei()` remain as aliases for callers written against 1.0.0.
- README documents that magnitudes beyond about +/-3 are extrapolation of the
  fitted distribution rather than observed frequencies.

## [1.0.0] - 2026-09-22

First public release.

### Added

- `scripts/calculate_spei.R`: command line tool computing Thornthwaite PET,
  the monthly climatic water balance and SPEI at any set of accumulation
  scales from an Excel workbook of date, temperature and precipitation.
- Reusable modules under `R/` — workbook reading and validation
  (`climate_io.R`), daily-to-monthly aggregation (`monthly.R`), PET
  (`pet.R`), the index itself (`spei_index.R`) and figures (`plot_spei.R`) —
  so further indices can reuse the input and aggregation layer.
- Multi-sheet output: monthly results, wet/dry category summary, and run
  metadata recording how the file was produced.
- Synthetic 30-year example dataset and a variant containing deliberate gaps.
- Test suite of 27 checks, plus CI running it and an end-to-end example run.
