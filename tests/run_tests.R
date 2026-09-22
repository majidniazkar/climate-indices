#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# climate-indices | Unit tests
#
#   Rscript tests/run_tests.R
#
# Plain base-R assertions so the suite has no dependency beyond the packages
# the tool itself needs. Exits non-zero on the first failure.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(dplyr); library(SPEI); library(readxl); library(writexl)
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
for (f in c("climate_io.R", "monthly.R", "pet.R", "spei_index.R")) {
  source(file.path(ROOT, "R", f))
}

PASS <- 0L
FAILURES <- character(0)
check <- function(label, expr) {
  ok <- isTRUE(tryCatch(expr, error = function(e) {
    message("  error in '", label, "': ", conditionMessage(e)); FALSE
  }))
  cat(if (ok) "PASS  " else "FAIL  ", label, "\n", sep = "")
  if (ok) PASS <<- PASS + 1L else FAILURES <<- c(FAILURES, label)
}

# --- fixtures --------------------------------------------------------------
make_daily <- function(from = "2001-01-01", to = "2030-12-31", seed = 1) {
  set.seed(seed)
  d <- seq(as.Date(from), as.Date(to), by = "day")
  doy <- as.integer(format(d, "%j"))
  data.frame(
    Date = d,
    Temperature = 9 - 9 * cos(2 * pi * (doy - 15) / 365.25) + rnorm(length(d), 0, 1.5),
    Precipitation = rgamma(length(d), shape = 0.3, scale = 8)
  )
}
daily <- make_daily()
monthly <- aggregate_to_monthly(daily)

# --- aggregation -----------------------------------------------------------
check("monthly grid has one row per calendar month", {
  nrow(monthly) == 360L
})

check("monthly grid is strictly contiguous", {
  all(diff(as.integer(format(monthly$Date, "%Y"))) * 12 +
      diff(as.integer(format(monthly$Date, "%m"))) == 1)
})

check("precipitation is summed and temperature averaged", {
  jan <- daily[format(daily$Date, "%Y-%m") == "2001-01", ]
  isTRUE(all.equal(monthly$Precipitation[1], sum(jan$Precipitation))) &&
    isTRUE(all.equal(monthly$Temperature[1], mean(jan$Temperature)))
})

check("a month missing from the input becomes an explicit NA row, not a shift", {
  gapped <- daily[format(daily$Date, "%Y-%m") != "2005-07", ]
  m <- aggregate_to_monthly(gapped)
  nrow(m) == 360L &&
    is.na(m$Temperature[m$Year == 2005 & m$Month == 7]) &&
    m$Month[m$Year == 2005 & m$Month == 8] == 8L
})

check("a sparse month becomes NA rather than a partial sum of 0 mm", {
  sparse <- daily
  sel <- format(sparse$Date, "%Y-%m") == "2005-07" &
    as.integer(format(sparse$Date, "%d")) > 5
  sparse$Precipitation[sel] <- NA
  sparse$Temperature[sel] <- NA
  m <- aggregate_to_monthly(sparse, min_coverage = 0.9)
  is.na(m$Precipitation[m$Year == 2005 & m$Month == 7])
})

check("min_coverage = 0 keeps a sparse month", {
  sparse <- daily
  sel <- format(sparse$Date, "%Y-%m") == "2005-07" &
    as.integer(format(sparse$Date, "%d")) > 5
  sparse$Precipitation[sel] <- NA
  m <- aggregate_to_monthly(sparse, min_coverage = 0)
  !is.na(m$Precipitation[m$Year == 2005 & m$Month == 7])
})

# --- time anchoring --------------------------------------------------------
check("as_monthly_ts anchors the series on its true start month", {
  mid <- aggregate_to_monthly(make_daily(from = "2001-07-01", to = "2030-12-31", seed = 2))
  identical(as.numeric(stats::start(as_monthly_ts(mid$Temperature, mid$Date[1]))),
            c(2001, 7))
})

check("PET for a July-start record differs from the same values read as January-start", {
  mid <- aggregate_to_monthly(make_daily(from = "2001-07-01", to = "2030-12-31", seed = 2))
  correct <- compute_pet_thornthwaite(as_monthly_ts(mid$Temperature, mid$Date[1]), 48.9)
  wrong <- compute_pet_thornthwaite(
    stats::ts(mid$Temperature, start = c(2001, 1), frequency = 12), 48.9)
  !isTRUE(all.equal(as.numeric(correct), as.numeric(wrong)))
})

# --- PET and balance -------------------------------------------------------
pet <- compute_pet_thornthwaite(as_monthly_ts(monthly$Temperature, monthly$Date[1]), 48.891)

check("PET is non-negative and peaks in summer", {
  all(pet >= 0) && which.max(tapply(as.numeric(pet), monthly$Month, mean)) %in% 6:8
})

check("PET rejects an out-of-range latitude", {
  inherits(try(compute_pet_thornthwaite(
    as_monthly_ts(monthly$Temperature, monthly$Date[1]), 120), silent = TRUE), "try-error")
})

check("a month with no temperature yields NA PET, not zero evaporative demand", {
  t <- monthly$Temperature
  t[100] <- NA
  p <- compute_pet_thornthwaite(as_monthly_ts(t, monthly$Date[1]), 48.891)
  is.na(p[100]) && !is.na(p[99])
})

check("an all-missing temperature series is refused rather than returning zeros", {
  t <- rep(NA_real_, nrow(monthly))
  inherits(try(compute_pet_thornthwaite(as_monthly_ts(t, monthly$Date[1]), 48.891),
               silent = TRUE), "try-error")
})

check("water balance equals P - PET", {
  b <- compute_water_balance(as_monthly_ts(monthly$Precipitation, monthly$Date[1]), pet)
  isTRUE(all.equal(as.numeric(b), monthly$Precipitation - as.numeric(pet)))
})

# --- SPEI ------------------------------------------------------------------
balance <- compute_water_balance(as_monthly_ts(monthly$Precipitation, monthly$Date[1]), pet)
res <- compute_spei(balance, scales = c(1, 3, 12))

check("one output column per requested scale, each as long as the record", {
  identical(names(res$values), c("SPEI_1", "SPEI_3", "SPEI_12")) &&
    all(vapply(res$values, length, integer(1)) == nrow(monthly))
})

check("SPEI is standardised: mean near 0 and sd near 1", {
  v <- res$values$SPEI_1[is.finite(res$values$SPEI_1)]
  abs(mean(v)) < 0.15 && abs(sd(v) - 1) < 0.15
})

check("the first scale-1 value is defined and the first 11 scale-12 values are not", {
  !is.na(res$values$SPEI_1[1]) && all(is.na(res$values$SPEI_12[1:11]))
})

check("a scale longer than the record is skipped, not fatal", {
  short <- compute_spei(balance[1:24] |> stats::ts(start = c(2001, 1), frequency = 12),
                        scales = c(3, 48))
  identical(names(short$values), "SPEI_3") && identical(short$skipped, 48L)
})

check("classification follows the McKee thresholds", {
  identical(as.character(classify_spei(c(-2.5, -1.7, -1.2, 0, 1.2, 1.7, 2.5))),
            c("Extremely dry", "Severely dry", "Moderately dry", "Near normal",
              "Moderately wet", "Very wet", "Extremely wet"))
})

check("category summary covers every scale and counts only valid months", {
  s <- summarise_categories(res$values)
  setequal(s$Scale, c(1, 3, 12)) &&
    sum(s$N_Months[s$Scale == 1]) == sum(!is.na(res$values$SPEI_1))
})

# --- input validation ------------------------------------------------------
tmp <- file.path(tempdir(), "climate-indices-tests")
dir.create(tmp, showWarnings = FALSE)
write_book <- function(df, name) {
  p <- file.path(tmp, name); writexl::write_xlsx(df, p); p
}

check("a well-formed workbook round-trips", {
  p <- write_book(daily[1:400, ], "good.xlsx")
  df <- read_climate_excel(p)
  nrow(df) == 400L && inherits(df$Date, "Date")
})

check("column synonyms such as Temp / Rainfall are accepted", {
  alt <- daily[1:120, ]; names(alt) <- c("date", "Temp", "Rainfall")
  nrow(read_climate_excel(write_book(alt, "synonyms.xlsx"))) == 120L
})

check("a missing required column gives a named error", {
  bad <- daily[1:60, c("Date", "Temperature")]
  e <- try(read_climate_excel(write_book(bad, "nocol.xlsx")), silent = TRUE)
  inherits(e, "try-error") && grepl("Precipitation", conditionMessage(attr(e, "condition")))
})

check("negative precipitation is rejected", {
  bad <- daily[1:60, ]; bad$Precipitation[10] <- -5
  inherits(try(read_climate_excel(write_book(bad, "negative.xlsx")), silent = TRUE),
           "try-error")
})

check("duplicated dates are rejected", {
  bad <- daily[c(1:60, 60), ]
  inherits(try(read_climate_excel(write_book(bad, "dup.xlsx")), silent = TRUE),
           "try-error")
})

check("Fahrenheit-looking temperatures raise a unit warning", {
  f <- daily[1:365, ]; f$Temperature <- f$Temperature * 9 / 5 + 32
  got <- FALSE
  withCallingHandlers(read_climate_excel(write_book(f, "fahrenheit.xlsx")),
                      warning = function(w) {
                        if (grepl("Fahrenheit", conditionMessage(w))) got <<- TRUE
                        invokeRestart("muffleWarning")
                      })
  got
})

check("dates stored as text are parsed", {
  txt <- daily[1:90, ]; txt$Date <- format(txt$Date, "%d.%m.%Y")
  inherits(read_climate_excel(write_book(txt, "textdates.xlsx"))$Date, "Date")
})

check("daily and monthly inputs are told apart", {
  detect_frequency(daily$Date[1:100]) == "daily" &&
    detect_frequency(monthly$Date[1:24]) == "monthly"
})

cat("\n", PASS, " of ", PASS + length(FAILURES), " checks passed.\n", sep = "")
if (length(FAILURES) > 0L) {
  cat("Failed:\n", paste0("  - ", FAILURES, collapse = "\n"), "\n", sep = "")
  # Non-zero exit under Rscript so CI fails; a plain error when sourced.
  if (any(grepl("^--file=", commandArgs(FALSE)))) quit(status = 1) else stop("tests failed")
}
