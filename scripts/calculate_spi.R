#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# climate-indices | Command line entry point for SPI
#
#   Rscript scripts/calculate_spi.R --input precipitation.xlsx
#
# Needs only date and precipitation -- no temperature and no latitude, since
# SPI involves no evapotranspiration term. With --sheet all, every worksheet
# is processed and the output workbook carries one sheet per station.
#
# Runs from any working directory. See README.md for the full option list.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(optparse)
  library(readxl)
  library(writexl)
  library(SPEI)
})

# --- locate the repository root so this runs from any working directory ----
# Launched with Rscript, the path comes from --file=. Sourced in RStudio or a
# notebook there is no such argument, so walk up from the working directory,
# or read CLIMATE_INDICES_ROOT if it is set.
find_repo_root <- function() {
  from_env <- Sys.getenv("CLIMATE_INDICES_ROOT", "")
  if (nzchar(from_env)) return(normalizePath(from_env, mustWork = TRUE))
  args <- commandArgs(trailingOnly = FALSE)
  hit <- grep("^--file=", args)
  if (length(hit) > 0L) {
    return(dirname(dirname(normalizePath(sub("^--file=", "", args[hit[1]])))))
  }
  d <- normalizePath(getwd(), winslash = "/")
  for (i in seq_len(6)) {
    if (dir.exists(file.path(d, "R")) && dir.exists(file.path(d, "scripts"))) return(d)
    parent <- dirname(d)
    if (identical(parent, d)) break
    d <- parent
  }
  stop(paste("Could not locate the repository root. Run from inside the repository,",
             "or set the CLIMATE_INDICES_ROOT environment variable."), call. = FALSE)
}
ROOT <- find_repo_root()
for (f in c("climate_io.R", "monthly.R", "classify.R", "spi_index.R")) {
  source(file.path(ROOT, "R", f))
}

# --- options ---------------------------------------------------------------
option_list <- list(
  make_option(c("-i", "--input"), type = "character", default = NULL,
              help = "Path to the input .xlsx file [required]"),
  make_option(c("-s", "--scales"), type = "character", default = "1,3,6,9,12,24",
              help = "Comma-separated SPI accumulation scales in months [default %default]"),
  make_option(c("-o", "--output-dir"), type = "character", default = "output",
              dest = "output_dir",
              help = "Directory for result files, created if absent [default %default]"),
  make_option("--sheet", type = "character", default = "1",
              help = paste("Worksheet name, 1-based index, or 'all' to process every",
                           "worksheet into one output workbook [default %default]")),
  make_option("--min-coverage", type = "double", default = 0.9, dest = "min_coverage",
              help = paste("Fraction of days in a month that must be observed for that",
                           "month to be used; sparser months become NA [default %default]")),
  make_option("--input-frequency", type = "character", default = "auto",
              dest = "input_frequency",
              help = "auto, daily or monthly [default %default]"),
  make_option("--distribution", type = "character", default = "Gamma",
              help = "Distribution fitted to the accumulated precipitation [default %default]"),
  make_option("--fit", type = "character", default = "ub-pwm",
              help = "Parameter estimation: ub-pwm, pp-pwm or max-lik [default %default]"),
  make_option("--ref-period", type = "character", default = NULL, dest = "ref_period",
              help = paste("Reference period for fitting, as YYYY-MM:YYYY-MM.",
                           "Omit to fit on the whole record")),
  make_option("--no-zero-correction", action = "store_true", default = FALSE,
              dest = "no_zero_correction",
              help = paste("Do not apply the mixed-distribution correction for zero",
                           "accumulations. Zero months then have no defined SPI")),
  make_option("--prefix", type = "character", default = "monthly_spi",
              help = "Base name for the output files [default %default]"),
  make_option("--plot", action = "store_true", default = FALSE,
              help = "Also write a PNG figure per worksheet"),
  make_option("--no-csv", action = "store_true", default = FALSE, dest = "no_csv",
              help = "Write only the .xlsx, skipping the .csv copies"),
  make_option(c("-q", "--quiet"), action = "store_true", default = FALSE,
              help = "Suppress progress messages")
)

parser <- OptionParser(
  option_list = option_list,
  usage = "Rscript scripts/calculate_spi.R --input FILE [options]",
  description = paste0(
    "\nCompute multi-scale SPI from a workbook of Date / Precipitation (mm).\n",
    "Daily input is aggregated to monthly totals first.\n")
)
opt <- parse_args(parser, args = commandArgs(trailingOnly = TRUE))

say <- function(...) if (!isTRUE(opt$quiet)) cat(..., "\n", sep = "")
fail <- function(msg) {
  message("\nError: ", msg, "\n")
  print_help(parser)
  quit(status = 1)
}

# --- validate options ------------------------------------------------------
if (is.null(opt$input)) fail("--input is required.")

scales <- suppressWarnings(as.integer(trimws(strsplit(opt$scales, ",")[[1]])))
if (any(is.na(scales)) || any(scales < 1L)) {
  fail(sprintf("--scales must be a comma-separated list of positive integers, got '%s'.",
               opt$scales))
}
if (!opt$input_frequency %in% c("auto", "daily", "monthly")) {
  fail("--input-frequency must be auto, daily or monthly.")
}

parse_ref <- function(txt) {
  if (is.null(txt)) return(list(start = NULL, end = NULL))
  parts <- strsplit(txt, ":", fixed = TRUE)[[1]]
  if (length(parts) != 2L) fail("--ref-period must look like 1991-01:2020-12.")
  to_pair <- function(p) {
    ym <- suppressWarnings(as.integer(strsplit(trimws(p), "-", fixed = TRUE)[[1]]))
    if (length(ym) != 2L || any(is.na(ym)) || ym[2] < 1 || ym[2] > 12) {
      fail(sprintf("Could not read '%s' as YYYY-MM.", p))
    }
    c(ym[1], ym[2])
  }
  list(start = to_pair(parts[1]), end = to_pair(parts[2]))
}
ref <- parse_ref(opt$ref_period)
zero_correction <- !isTRUE(opt$no_zero_correction)

# --- which worksheets ------------------------------------------------------
available <- list_sheets(opt$input)
if (identical(tolower(opt$sheet), "all")) {
  targets <- available
} else {
  idx <- suppressWarnings(as.integer(opt$sheet))
  if (!is.na(idx)) {
    if (idx < 1L || idx > length(available)) {
      fail(sprintf("--sheet %d is out of range; the file has %d worksheet(s): %s",
                   idx, length(available), paste(available, collapse = ", ")))
    }
    targets <- available[idx]
  } else {
    if (!opt$sheet %in% available) {
      fail(sprintf("No worksheet named '%s'. The file has: %s",
                   opt$sheet, paste(available, collapse = ", ")))
    }
    targets <- opt$sheet
  }
}

say("Reading  : ", opt$input)
say("Sheets   : ", paste(targets, collapse = ", "),
    " (of ", length(available), " in the file)")

# --- process each worksheet ------------------------------------------------
results <- list()
notes <- list()

for (sh in targets) {
  say("")
  say("[", sh, "]")
  daily <- read_climate_excel(opt$input, sheet = sh,
                              fields = c("Date", "Precipitation"))
  say("  rows     : ", nrow(daily), "  (", format(min(daily$Date)), " to ",
      format(max(daily$Date)), ")")

  freq <- if (opt$input_frequency == "auto") {
    detect_frequency(daily$Date)
  } else {
    opt$input_frequency
  }
  monthly <- if (freq == "daily") {
    aggregate_to_monthly(daily, min_coverage = opt$min_coverage)
  } else {
    standardise_monthly(daily)
  }
  say("  months   : ", nrow(monthly), " (", freq,
      if (opt$input_frequency == "auto") " detected" else " forced", ")")

  n_gap <- sum(is.na(monthly$Precipitation))
  if (n_gap > 0L) {
    say("  gaps     : ", n_gap, " month(s) without usable precipitation",
        if (freq == "daily") sprintf(" (min coverage %.0f%%)", 100 * opt$min_coverage) else "")
  }
  n_zero <- sum(monthly$Precipitation == 0, na.rm = TRUE)
  if (n_zero > 0L) say("  dry      : ", n_zero, " month(s) with zero precipitation")

  if (nrow(monthly) < 360) {
    warning(sprintf(paste("[%s] The record holds %d months (%.1f years). SPI is normally",
                          "fitted on 30+ years; shorter records give unstable extremes."),
                    sh, nrow(monthly), nrow(monthly) / 12), call. = FALSE)
  }

  precip_ts <- as_monthly_ts(monthly$Precipitation, monthly$Date[1])
  res <- compute_spi(precip_ts, scales = scales, distribution = opt$distribution,
                     fit = opt$fit, ref_start = ref$start, ref_end = ref$end,
                     zero_correction = zero_correction)
  if (length(res$skipped) > 0L) {
    warning(sprintf("[%s] Skipped scale(s) %s: longer than the %d-month record.",
                    sh, paste(res$skipped, collapse = ", "), nrow(monthly)), call. = FALSE)
  }
  if (length(res$values) == 0L) {
    fail(sprintf("[%s] No scale is shorter than the record; nothing to compute.", sh))
  }
  for (nm in names(res$values)) monthly[[nm]] <- res$values[[nm]]

  say("  SPI      : scales ", paste(sub("^SPI_", "", names(res$values)), collapse = ", "),
      " | ", opt$distribution, " / ", opt$fit)
  if (length(res$zero_corrected) > 0L) {
    say("  zero fix : mixed-distribution correction applied to calendar month(s) ",
        paste(sort(unique(unlist(res$zero_corrected))), collapse = ", "))
  }

  results[[sh]] <- monthly
  notes[[sh]] <- list(index_names = names(res$values), freq = freq,
                      n_corrected = length(res$zero_corrected))
}

# --- assemble the output workbook -----------------------------------------
sheets <- results
sheets[["Category_Summary"]] <- do.call(rbind, lapply(names(results), function(sh) {
  cols <- notes[[sh]]$index_names
  s <- summarise_categories(as.list(results[[sh]][, cols, drop = FALSE]))
  cbind(Sheet = sh, s, stringsAsFactors = FALSE)
}))
sheets[["Metadata"]] <- data.frame(
  Field = c("generated_at", "input_file", "worksheets", "input_frequency",
            "min_coverage", "scales_requested", "distribution", "fit_method",
            "zero_correction", "reference_period", "r_version", "SPEI_package_version"),
  Value = c(format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
            normalizePath(opt$input, winslash = "/", mustWork = FALSE),
            paste(targets, collapse = ","),
            paste(unique(vapply(notes, function(x) x$freq, character(1))), collapse = ","),
            sprintf("%.2f", opt$min_coverage),
            paste(scales, collapse = ","),
            opt$distribution, opt$fit,
            if (zero_correction) "Edwards & McKee (1997) mixed distribution" else "disabled",
            if (is.null(ref$start)) "full record" else opt$ref_period,
            R.version.string, as.character(utils::packageVersion("SPEI"))),
  stringsAsFactors = FALSE
)

paths <- write_results(sheets, output_dir = opt$output_dir, basename = opt$prefix,
                       csv_sheets = if (isTRUE(opt$no_csv)) character(0) else names(results))
say("")
for (p in paths) say("Written  : ", p)

if (isTRUE(opt$plot)) {
  suppressPackageStartupMessages(library(ggplot2))
  source(file.path(ROOT, "R", "plot_index.R"))
  for (sh in names(results)) {
    suffix <- if (length(results) > 1L) paste0("_", gsub("[^A-Za-z0-9._-]", "_", sh)) else ""
    fig <- plot_index_panels(
      results[[sh]], notes[[sh]]$index_names,
      file.path(opt$output_dir, paste0(opt$prefix, suffix, ".png")),
      ylab = "SPI (standard deviations)",
      title = if (length(results) > 1L) sh else NULL)
    say("Written  : ", fig)
  }
}

say("Done.")
