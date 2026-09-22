# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/).

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
