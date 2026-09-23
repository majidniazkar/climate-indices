#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# climate-indices | Command line entry point for SPEI
#
#   Rscript scripts/calculate_spei.R --input data/example/synthetic_daily_climate.xlsx \
#                                    --latitude 48.891
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
for (f in c("climate_io.R", "monthly.R", "classify.R", "pet.R", "spei_index.R")) {
  source(file.path(ROOT, "R", f))
}

# --- options ---------------------------------------------------------------
option_list <- list(
  make_option(c("-i", "--input"), type = "character", default = NULL,
              help = "Path to the input .xlsx file [required]"),
  make_option(c("-l", "--latitude"), type = "double", default = NULL,
              help = "Site latitude in decimal degrees, negative south [required]"),
  make_option(c("-s", "--scales"), type = "character", default = "1,3,6,9,12,24",
              help = "Comma-separated SPEI accumulation scales in months [default %default]"),
  make_option(c("-o", "--output-dir"), type = "character", default = "output",
              dest = "output_dir",
              help = "Directory for result files, created if absent [default %default]"),
  make_option("--sheet", type = "character", default = "1",
              help = "Worksheet name or 1-based index [default %default]"),
  make_option("--min-coverage", type = "double", default = 0.9, dest = "min_coverage",
              help = paste("Fraction of days in a month that must be observed for that",
                           "month to be used; sparser months become NA [default %default]")),
  make_option("--input-frequency", type = "character", default = "auto",
              dest = "input_frequency",
              help = "auto, daily or monthly [default %default]"),
  make_option("--distribution", type = "character", default = "log-Logistic",
              help = "Distribution fitted to the accumulated balance [default %default]"),
  make_option("--fit", type = "character", default = "ub-pwm",
              help = "Parameter estimation: ub-pwm, pp-pwm or max-lik [default %default]"),
  make_option("--ref-period", type = "character", default = NULL, dest = "ref_period",
              help = paste("Reference period for fitting, as YYYY-MM:YYYY-MM.",
                           "Omit to fit on the whole record")),
  make_option("--prefix", type = "character", default = "monthly_pet_spei",
              help = "Base name for the output files [default %default]"),
  make_option("--plot", action = "store_true", default = FALSE,
              help = "Also write a PNG figure of the SPEI series"),
  make_option("--no-csv", action = "store_true", default = FALSE, dest = "no_csv",
              help = "Write only the .xlsx, skipping the .csv copy"),
  make_option(c("-q", "--quiet"), action = "store_true", default = FALSE,
              help = "Suppress progress messages")
)

parser <- OptionParser(
  option_list = option_list,
  usage = "Rscript scripts/calculate_spei.R --input FILE --latitude LAT [options]",
  description = paste0(
    "\nCompute Thornthwaite PET, the climatic water balance and multi-scale SPEI\n",
    "from a workbook of Date / Temperature (degC) / Precipitation (mm).\n")
)
opt <- parse_args(parser, args = commandArgs(trailingOnly = TRUE))

say <- function(...) if (!isTRUE(opt$quiet)) cat(...,  "\n", sep = "")
fail <- function(msg) {
  message("\nError: ", msg, "\n")
  print_help(parser)
  quit(status = 1)
}

# --- validate options ------------------------------------------------------
if (is.null(opt$input)) fail("--input is required.")
if (is.null(opt$latitude)) {
  fail(paste("--latitude is required. Thornthwaite PET needs the site latitude",
             "to compute day length."))
}

scales <- suppressWarnings(as.integer(trimws(strsplit(opt$scales, ",")[[1]])))
if (any(is.na(scales)) || any(scales < 1L)) {
  fail(sprintf("--scales must be a comma-separated list of positive integers, got '%s'.",
               opt$scales))
}
if (!opt$input_frequency %in% c("auto", "daily", "monthly")) {
  fail("--input-frequency must be auto, daily or monthly.")
}
sheet <- suppressWarnings(as.integer(opt$sheet))
if (is.na(sheet)) sheet <- opt$sheet

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

# --- read ------------------------------------------------------------------
say("Reading  : ", opt$input)
daily <- read_climate_excel(opt$input, sheet = sheet)
say("Rows     : ", nrow(daily), "  (", format(min(daily$Date)), " to ",
    format(max(daily$Date)), ")")

freq <- if (opt$input_frequency == "auto") detect_frequency(daily$Date) else opt$input_frequency
say("Frequency: ", freq, if (opt$input_frequency == "auto") " (detected)" else " (forced)")

monthly <- if (freq == "daily") {
  aggregate_to_monthly(daily, min_coverage = opt$min_coverage)
} else {
  standardise_monthly(daily)
}
say("Months   : ", nrow(monthly))

n_gap_t <- sum(is.na(monthly$Temperature))
n_gap_p <- sum(is.na(monthly$Precipitation))
if (n_gap_t > 0 || n_gap_p > 0) {
  say("Gaps     : ", n_gap_t, " month(s) without usable temperature, ",
      n_gap_p, " without usable precipitation",
      if (freq == "daily") sprintf(" (min coverage %.0f%%)", 100 * opt$min_coverage) else "")
}
if (nrow(monthly) < 360) {
  warning(sprintf(paste("The record holds %d months (%.1f years). SPEI is normally fitted on",
                        "30+ years; shorter records give unstable extremes."),
                  nrow(monthly), nrow(monthly) / 12), call. = FALSE)
}

# --- PET, water balance, SPEI ---------------------------------------------
first_date <- monthly$Date[1]
temp_ts   <- as_monthly_ts(monthly$Temperature, first_date)
precip_ts <- as_monthly_ts(monthly$Precipitation, first_date)

say("PET      : Thornthwaite, latitude ", sprintf("%.4f", opt$latitude))
pet_ts <- compute_pet_thornthwaite(temp_ts, opt$latitude)
balance_ts <- compute_water_balance(precip_ts, pet_ts)

monthly$PET     <- as.numeric(pet_ts)
monthly$Balance <- as.numeric(balance_ts)

say("SPEI     : scales ", paste(scales, collapse = ", "),
    " | ", opt$distribution, " / ", opt$fit,
    if (!is.null(ref$start)) sprintf(" | reference %d-%02d:%d-%02d",
                                     ref$start[1], ref$start[2],
                                     ref$end[1], ref$end[2]) else "")
res <- compute_spei(balance_ts, scales = scales, distribution = opt$distribution,
                    fit = opt$fit, ref_start = ref$start, ref_end = ref$end)
if (length(res$skipped) > 0L) {
  warning(sprintf("Skipped scale(s) %s: longer than the %d-month record.",
                  paste(res$skipped, collapse = ", "), nrow(monthly)), call. = FALSE)
}
if (length(res$values) == 0L) {
  fail("No scale is shorter than the record; nothing to compute.")
}
for (nm in names(res$values)) monthly[[nm]] <- res$values[[nm]]

# --- write -----------------------------------------------------------------
spei_names <- names(res$values)
categories <- summarise_categories(res$values)
metadata <- data.frame(
  Field = c("generated_at", "input_file", "input_frequency", "latitude_deg",
            "min_coverage", "scales_requested", "scales_computed", "distribution",
            "fit_method", "pet_method", "reference_period", "n_months",
            "record_start", "record_end", "r_version", "SPEI_package_version"),
  Value = c(format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
            normalizePath(opt$input, winslash = "/", mustWork = FALSE),
            freq, sprintf("%.4f", opt$latitude), sprintf("%.2f", opt$min_coverage),
            paste(scales, collapse = ","),
            paste(sub("^SPEI_", "", spei_names), collapse = ","),
            opt$distribution, opt$fit, "Thornthwaite (1948)",
            if (is.null(ref$start)) "full record" else opt$ref_period,
            as.character(nrow(monthly)),
            format(min(monthly$Date)), format(max(monthly$Date)),
            R.version.string, as.character(utils::packageVersion("SPEI"))),
  stringsAsFactors = FALSE
)

paths <- write_results(
  sheets = list(Monthly_SPEI = monthly, Category_Summary = categories, Metadata = metadata),
  output_dir = opt$output_dir, basename = opt$prefix,
  csv_sheets = if (isTRUE(opt$no_csv)) character(0) else "Monthly_SPEI")
for (p in paths) say("Written  : ", p)

if (isTRUE(opt$plot)) {
  suppressPackageStartupMessages(library(ggplot2))
  source(file.path(ROOT, "R", "plot_index.R"))
  fig <- plot_index_panels(monthly, spei_names,
                           file.path(opt$output_dir, paste0(opt$prefix, ".png")),
                           ylab = "SPEI (standard deviations)")
  say("Written  : ", fig)
}

say("Done.")
