#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# climate-indices | Command line entry point for RDI
#
#   Rscript scripts/calculate_rdi.R --input precip_pet.xlsx
#   Rscript scripts/calculate_rdi.R --input station.xlsx --latitude 48.891
#
# RDI needs precipitation and PET. If the workbook carries a PET column it is
# used directly; otherwise PET is computed from temperature by the
# Thornthwaite method, which is what --latitude is for. With --sheet all,
# every worksheet is processed into one output workbook.
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
for (f in c("climate_io.R", "monthly.R", "classify.R", "pet.R",
            "spi_index.R", "sdi_index.R", "rdi_index.R")) {
  # spi_index.R supplies rolling_sum() and fit_gamma_thom(); sdi_index.R
  # supplies standardise_accumulation() and reference_mask(), shared with RDI.
  source(file.path(ROOT, "R", f))
}

# --- options ---------------------------------------------------------------
option_list <- list(
  make_option(c("-i", "--input"), type = "character", default = NULL,
              help = "Path to the input .xlsx file [required]"),
  make_option(c("-l", "--latitude"), type = "double", default = NULL,
              help = paste("Site latitude in decimal degrees, negative south.",
                           "Required only when the file has no PET column")),
  make_option(c("-s", "--scales"), type = "character", default = "1,3,6,9,12,24",
              help = "Comma-separated RDI accumulation scales in months [default %default]"),
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
  make_option("--distribution", type = "character", default = "log-normal",
              help = paste("Distribution fitted to the aridity ratio alpha:",
                           "log-normal (the original RDI_st), gamma or normal",
                           "[default %default]")),
  make_option("--ref-period", type = "character", default = NULL, dest = "ref_period",
              help = paste("Reference period for fitting, as YYYY-MM:YYYY-MM.",
                           "Omit to fit on the whole record")),
  make_option("--no-zero-correction", action = "store_true", default = FALSE,
              dest = "no_zero_correction",
              help = paste("Do not treat zero-precipitation accumulations as a",
                           "probability mass; they then have no defined RDI")),
  make_option("--no-alpha", action = "store_true", default = FALSE, dest = "no_alpha",
              help = "Omit the Alpha_<scale> aridity-ratio columns from the output"),
  make_option("--prefix", type = "character", default = "monthly_rdi",
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
  usage = "Rscript scripts/calculate_rdi.R --input FILE [--latitude LAT] [options]",
  description = paste0(
    "\nCompute multi-scale RDI from precipitation and PET.\n",
    "PET is read from the file if present, otherwise computed from\n",
    "temperature by the Thornthwaite method (which needs --latitude).\n")
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
if (!opt$distribution %in% RDI_DISTRIBUTIONS) {
  fail(sprintf("--distribution must be one of: %s",
               paste(RDI_DISTRIBUTIONS, collapse = ", ")))
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

  # PET from the file if it is there, otherwise from temperature.
  have <- available_fields(opt$input, sheet = sh)
  if ("PET" %in% have) {
    pet_source <- "column"
    fields <- c("Date", "Precipitation", "PET")
    if ("Temperature" %in% have) {
      say("  note     : both PET and Temperature present; using the supplied PET")
    }
  } else if ("Temperature" %in% have) {
    pet_source <- "thornthwaite"
    fields <- c("Date", "Temperature", "Precipitation")
    if (is.null(opt$latitude)) {
      fail(paste0("Worksheet '", sh, "' has no PET column, so PET must be computed ",
                  "from temperature by the Thornthwaite method. That needs the site ",
                  "latitude: pass --latitude."))
    }
  } else {
    fail(sprintf(paste("Worksheet '%s' has neither a PET column nor a Temperature",
                       "column. RDI needs precipitation and PET."), sh))
  }

  daily <- read_climate_excel(opt$input, sheet = sh, fields = fields)
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

  if (identical(pet_source, "thornthwaite")) {
    say("  PET      : Thornthwaite, latitude ", sprintf("%.4f", opt$latitude))
    monthly$PET <- as.numeric(compute_pet_thornthwaite(
      as_monthly_ts(monthly$Temperature, monthly$Date[1]), opt$latitude))
  } else {
    say("  PET      : taken from the input file")
  }

  n_gap <- sum(is.na(monthly$Precipitation) | is.na(monthly$PET))
  if (n_gap > 0L) say("  gaps     : ", n_gap, " month(s) without usable P or PET")
  n_zero_pet <- sum(monthly$PET == 0, na.rm = TRUE)
  if (n_zero_pet > 0L) {
    say("  PET = 0  : ", n_zero_pet, " month(s) at or below 0 degC; the aridity ratio",
        " is undefined there and short-scale RDI is left empty")
  }

  if (nrow(monthly) < 360) {
    warning(sprintf(paste("[%s] The record holds %d months (%.1f years). RDI is normally",
                          "fitted on 30+ years; shorter records give unstable extremes."),
                    sh, nrow(monthly), nrow(monthly) / 12), call. = FALSE)
  }

  first <- monthly$Date[1]
  res <- compute_rdi(as_monthly_ts(monthly$Precipitation, first),
                     as_monthly_ts(monthly$PET, first),
                     scales = scales, distribution = opt$distribution,
                     ref_start = ref$start, ref_end = ref$end,
                     zero_correction = zero_correction)
  if (length(res$skipped) > 0L) {
    warning(sprintf("[%s] Skipped scale(s) %s: longer than the %d-month record.",
                    sh, paste(res$skipped, collapse = ", "), nrow(monthly)), call. = FALSE)
  }
  if (length(res$values) == 0L) {
    fail(sprintf("[%s] No scale is shorter than the record; nothing to compute.", sh))
  }
  if (!isTRUE(opt$no_alpha)) {
    for (nm in names(res$alpha)) monthly[[nm]] <- res$alpha[[nm]]
  }
  for (nm in names(res$values)) monthly[[nm]] <- res$values[[nm]]

  say("  RDI      : scales ", paste(sub("^RDI_", "", names(res$values)), collapse = ", "),
      " | ", opt$distribution)
  if (length(res$undefined) > 0L) {
    lost <- vapply(res$undefined, length, integer(1))
    say("  undefined: ", paste(sprintf("%s in %d month(s)", names(lost), lost),
                               collapse = ", "), " (PET summed to zero)")
  }

  results[[sh]] <- monthly
  notes[[sh]] <- list(index_names = names(res$values), freq = freq,
                      pet_source = pet_source)
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
            "min_coverage", "scales_requested", "distribution", "pet_source",
            "latitude_deg", "zero_handling", "reference_period", "accumulation",
            "r_version", "SPEI_package_version"),
  Value = c(format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
            normalizePath(opt$input, winslash = "/", mustWork = FALSE),
            paste(targets, collapse = ","),
            paste(unique(vapply(notes, function(x) x$freq, character(1))), collapse = ","),
            sprintf("%.2f", opt$min_coverage),
            paste(scales, collapse = ","),
            opt$distribution,
            paste(unique(vapply(notes, function(x) x$pet_source, character(1))),
                  collapse = ","),
            if (is.null(opt$latitude)) "not used" else sprintf("%.4f", opt$latitude),
            if (zero_correction) "zero precipitation carried as a probability mass"
            else "zero precipitation left undefined",
            if (is.null(ref$start)) "full record" else opt$ref_period,
            "overlapping monthly windows, fitted per calendar month",
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
      ylab = "RDI (standard deviations)",
      title = if (length(results) > 1L) sh else NULL)
    say("Written  : ", fig)
  }
}

say("Done.")
