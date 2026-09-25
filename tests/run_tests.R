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
  library(SPEI); library(readxl); library(writexl)
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
            "spei_index.R", "spi_index.R", "sdi_index.R", "rdi_index.R")) {
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

# --- SPI -------------------------------------------------------------------
precip_ts <- as_monthly_ts(monthly$Precipitation, monthly$Date[1])
spi_res <- compute_spi(precip_ts, scales = c(1, 3, 12))

check("SPI returns one column per scale, each as long as the record", {
  identical(names(spi_res$values), c("SPI_1", "SPI_3", "SPI_12")) &&
    all(vapply(spi_res$values, length, integer(1)) == nrow(monthly))
})

check("SPI is standardised: mean near 0 and sd near 1", {
  v <- spi_res$values$SPI_1[is.finite(spi_res$values$SPI_1)]
  abs(mean(v)) < 0.15 && abs(sd(v) - 1) < 0.15
})

check("SPI is fitted per calendar month, so a purely seasonal series scores ~0", {
  # No interannual variability at all: only the seasonal cycle and mild noise.
  seas <- c(40, 40, 50, 60, 80, 95, 100, 90, 70, 55, 45, 40)
  set.seed(11)
  p <- rep(seas, 50) * exp(rnorm(600, 0, 0.2))
  v <- compute_spi(stats::ts(p, start = c(1971, 1), frequency = 12),
                   scales = 1)$values$SPI_1
  by_month <- tapply(v, rep(1:12, 50), mean)
  max(abs(by_month)) < 0.15
})

check("SPI differs from a z-score of the rolling sum, most of all in the tail", {
  # The z-score shortcut ignores both the skew of monthly totals and the
  # per-month fit, so it must not reproduce SPI.
  acc <- rolling_sum(as.numeric(precip_ts), 3)
  zscore <- (acc - mean(acc, na.rm = TRUE)) / sd(acc, na.rm = TRUE)
  spi3 <- spi_res$values$SPI_3
  both <- is.finite(zscore) & is.finite(spi3)
  dry <- both & spi3 < -1
  max(abs(spi3[both] - zscore[both])) > 0.5 &&
    mean(abs(spi3[dry] - zscore[dry])) > mean(abs(spi3[both] - zscore[both]))
})

check("the first scale-1 value is defined and the first 11 scale-12 values are not", {
  !is.na(spi_res$values$SPI_1[1]) && all(is.na(spi_res$values$SPI_12[1:11]))
})

check("rolling_sum is right-aligned and refuses an incomplete window", {
  # Windows 1-2 are short, 3 and 4 are complete, 5-7 each contain the NA.
  isTRUE(all.equal(rolling_sum(c(1, 2, 3, 4, NA, 6, 7), 3),
                   c(NA, NA, 6, 9, NA, NA, NA))) &&
    isTRUE(all.equal(rolling_sum(c(1, 2, 3, 4, NA, 6, 7), 1),
                     c(1, 2, 3, 4, NA, 6, 7))) &&
    isTRUE(all.equal(rolling_sum(c(5, 5, 5, 5), 2), c(NA, 10, 10, 10)))
})

check("a scale longer than the record is skipped, not fatal", {
  short <- compute_spi(stats::ts(as.numeric(precip_ts)[1:24], start = c(2001, 1),
                                 frequency = 12), scales = c(3, 48))
  identical(names(short$values), "SPI_3") && identical(short$skipped, 48L)
})

check("Thom gamma fit recovers the parameters of a known gamma sample", {
  set.seed(3)
  x <- rgamma(20000, shape = 2.5, scale = 18)
  g <- fit_gamma_thom(x)
  abs(g$shape - 2.5) < 0.1 && abs(g$scale - 18) < 1
})

# A dry-climate series: many zero monthly totals.
set.seed(21)
dry_p <- rgamma(480, shape = 0.45, scale = 26) * rbinom(480, 1, 0.65)
dry_ts <- stats::ts(dry_p, start = c(1981, 1), frequency = 12)

check("zero months get a finite SPI instead of -Inf", {
  v <- compute_spi(dry_ts, scales = 1, zero_correction = TRUE)$values$SPI_1
  sum(dry_p == 0) > 0 && all(is.finite(v)) && min(v) > -4
})

check("without the correction, zero months have no defined SPI", {
  v <- compute_spi(dry_ts, scales = 1, zero_correction = FALSE)$values$SPI_1
  any(is.na(v[dry_p == 0]))
})

check("the correction reports which calendar months it touched", {
  z <- compute_spi(dry_ts, scales = 1, zero_correction = TRUE)$zero_corrected
  length(z) == 1L && all(unlist(z) %in% 1:12)
})

check("a zero-free series is unchanged by the correction", {
  a <- compute_spi(precip_ts, scales = 3, zero_correction = TRUE)$values$SPI_3
  b <- compute_spi(precip_ts, scales = 3, zero_correction = FALSE)$values$SPI_3
  isTRUE(all.equal(a, b))
})

check("all zeros in a calendar month leaves that month undefined, not infinite", {
  p <- dry_p
  p[seq(7, length(p), by = 12)] <- 0          # every July bone dry
  v <- compute_spi(stats::ts(p, start = c(1981, 1), frequency = 12),
                   scales = 1)$values$SPI_1
  all(is.na(v[seq(7, length(p), by = 12)])) && !all(is.na(v))
})

check("SPI is refused when precipitation is missing for every month", {
  inherits(try(compute_spi(stats::ts(rep(NA_real_, 120), start = c(2001, 1),
                                     frequency = 12), scales = 1), silent = TRUE),
           "try-error")
})

# --- shared aggregation for a precipitation-only input ---------------------
check("a two-column input aggregates without a Temperature column", {
  m <- aggregate_to_monthly(daily[, c("Date", "Precipitation")])
  !("Temperature" %in% names(m)) && nrow(m) == 360L &&
    isTRUE(all.equal(m$Precipitation, monthly$Precipitation))
})

check("the coverage rule still applies with no Temperature column", {
  sparse <- daily[, c("Date", "Precipitation")]
  sel <- format(sparse$Date, "%Y-%m") == "2005-07" &
    as.integer(format(sparse$Date, "%d")) > 5
  sparse$Precipitation[sel] <- NA
  is.na(aggregate_to_monthly(sparse)$Precipitation[
    format(aggregate_to_monthly(sparse)$Date, "%Y-%m") == "2005-07"])
})

check("classification is shared between the indices", {
  identical(as.character(classify_index(c(-2.5, 0, 2.5))),
            c("Extremely dry", "Near normal", "Extremely wet")) &&
    identical(classify_spei(-2.5), classify_index(-2.5))
})

check("category summary strips either index prefix", {
  s <- summarise_categories(list(SPI_3 = spi_res$values$SPI_3,
                                 SPEI_3 = res$values$SPEI_3))
  setequal(s$Scale, 3)
})

# --- a temporary workbook factory, used by the checks below -----------------
tmp <- file.path(tempdir(), "climate-indices-tests")
dir.create(tmp, showWarnings = FALSE)
write_book <- function(df, name) {
  p <- file.path(tmp, name); writexl::write_xlsx(df, p); p
}

# --- SDI -------------------------------------------------------------------
# Right-skewed monthly flow with a spring peak, the shape SDI must cope with.
set.seed(31)
n_mon <- 480
cal <- rep(1:12, length.out = n_mon)
seasonal <- c(1.0, 1.1, 1.6, 2.0, 1.9, 1.4, 0.9, 0.7, 0.6, 0.7, 0.8, 0.9)
flow <- seasonal[cal] * 20 * exp(rnorm(n_mon, 0, 0.55))
flow_ts <- stats::ts(flow, start = c(1981, 1), frequency = 12)
sdi_res <- compute_sdi(flow_ts, scales = c(1, 3, 12))

check("SDI returns one column per scale, each as long as the record", {
  identical(names(sdi_res$values), c("SDI_1", "SDI_3", "SDI_12")) &&
    all(vapply(sdi_res$values, length, integer(1)) == n_mon)
})

check("SDI is standardised: mean near 0 and sd near 1", {
  v <- sdi_res$values$SDI_1[is.finite(sdi_res$values$SDI_1)]
  abs(mean(v)) < 0.15 && abs(sd(v) - 1) < 0.15
})

check("SDI is fitted per calendar month, so the flow regime is removed", {
  v <- sdi_res$values$SDI_1
  max(abs(tapply(v, cal, mean, na.rm = TRUE))) < 0.15
})

check("the first scale-1 values are undefined", {
  is.na(sdi_res$values$SDI_12[11]) && !is.na(sdi_res$values$SDI_12[12]) &&
    !is.na(sdi_res$values$SDI_1[1])
})

check("the normal variant reproduces the plain per-month standardised anomaly", {
  # This is the form in the user-supplied notebook; it must be exactly
  # recoverable so results computed that way can be reproduced.
  v <- compute_sdi(flow_ts, scales = 3, distribution = "normal")$values$SDI_3
  acc <- rolling_sum(flow, 3)
  manual <- rep(NA_real_, n_mon)
  for (m in 1:12) {
    pos <- which(cal == m)
    a <- acc[pos]
    manual[pos] <- (a - mean(a, na.rm = TRUE)) / sd(a, na.rm = TRUE)
  }
  isTRUE(all.equal(v, manual))
})

check("the log-normal variant is better calibrated on skewed flow than the normal one", {
  # Right-skewed data run through a plain anomaly stays skewed, so the
  # normal-theory drought thresholds do not carry their nominal frequencies.
  ln <- compute_sdi(flow_ts, scales = 1, distribution = "log-normal")$values$SDI_1
  nm <- compute_sdi(flow_ts, scales = 1, distribution = "normal")$values$SDI_1
  skew <- function(z) { z <- z[is.finite(z)]; mean((z - mean(z))^3) / sd(z)^3 }
  abs(skew(ln)) < 0.2 && skew(nm) > 0.5 &&
    mean(nm < -2, na.rm = TRUE) < mean(ln < -2, na.rm = TRUE)
})

check("gamma and log-normal agree in rank but not in value", {
  g <- compute_sdi(flow_ts, scales = 3, distribution = "gamma")$values$SDI_3
  l <- compute_sdi(flow_ts, scales = 3, distribution = "log-normal")$values$SDI_3
  ok <- is.finite(g) & is.finite(l)
  cor(g[ok], l[ok], method = "spearman") > 0.999 && !isTRUE(all.equal(g[ok], l[ok]))
})

check("a scale longer than the record is skipped, not fatal", {
  short <- compute_sdi(stats::ts(flow[1:24], start = c(1981, 1), frequency = 12),
                       scales = c(3, 48))
  identical(names(short$values), "SDI_3") && identical(short$skipped, 48L)
})

check("an unknown distribution is refused", {
  inherits(try(compute_sdi(flow_ts, scales = 1, distribution = "weibull"),
               silent = TRUE), "try-error")
})

check("negative discharge is refused", {
  bad <- flow; bad[10] <- -1
  inherits(try(compute_sdi(stats::ts(bad, start = c(1981, 1), frequency = 12),
                           scales = 1), silent = TRUE), "try-error")
})

# Intermittent gauge: whole months with no flow at all.
set.seed(32)
inter <- flow * rbinom(n_mon, 1, 0.72)
inter_ts <- stats::ts(inter, start = c(1981, 1), frequency = 12)

check("zero-flow months get a finite SDI instead of -Inf", {
  v <- compute_sdi(inter_ts, scales = 1, distribution = "log-normal")$values$SDI_1
  sum(inter == 0) > 0 && all(is.finite(v[!is.na(v)])) && any(!is.na(v[inter == 0]))
})

check("without the correction, zero-flow months are undefined", {
  v <- compute_sdi(inter_ts, scales = 1, distribution = "log-normal",
                   zero_correction = FALSE)$values$SDI_1
  all(is.na(v[inter == 0]))
})

check("the normal variant needs no zero handling and keeps zero months", {
  v <- compute_sdi(inter_ts, scales = 1, distribution = "normal")$values$SDI_1
  all(!is.na(v[inter == 0]))
})

check("a calendar month that never flows is left undefined, not infinite", {
  z <- flow
  z[seq(9, n_mon, by = 12)] <- 0            # September always dry
  v <- compute_sdi(stats::ts(z, start = c(1981, 1), frequency = 12),
                   scales = 1)$values$SDI_1
  all(is.na(v[seq(9, n_mon, by = 12)])) && !all(is.na(v))
})

check("SDI is refused when discharge is missing for every month", {
  inherits(try(compute_sdi(stats::ts(rep(NA_real_, 120), start = c(2001, 1),
                                     frequency = 12), scales = 1), silent = TRUE),
           "try-error")
})

check("a reference period restricts the fit but not the output", {
  full <- compute_sdi(flow_ts, scales = 1)$values$SDI_1
  part <- compute_sdi(flow_ts, scales = 1,
                      ref_start = c(1981, 1), ref_end = c(2000, 12))$values$SDI_1
  sum(!is.na(part)) == sum(!is.na(full)) && !isTRUE(all.equal(full, part))
})

check("reference_mask selects exactly the requested window", {
  m <- reference_mask(flow_ts, c(1990, 3), c(1990, 5))
  sum(m) == 3L && which(m)[1] == (1990 - 1981) * 12 + 3
})

# --- shared aggregation for discharge --------------------------------------
check("discharge is summed to monthly totals under the coverage rule", {
  d <- data.frame(Date = seq(as.Date("2001-01-01"), as.Date("2003-12-31"), by = "day"))
  d$Discharge <- 5
  m <- aggregate_to_monthly(d)
  nrow(m) == 36L && isTRUE(all.equal(m$Discharge[1], 5 * 31)) &&
    "N_Days_Discharge" %in% names(m) && !("Precipitation" %in% names(m))
})

check("a sparse discharge month becomes NA, not a partial total", {
  d <- data.frame(Date = seq(as.Date("2001-01-01"), as.Date("2003-12-31"), by = "day"))
  d$Discharge <- 5
  d$Discharge[format(d$Date, "%Y-%m") == "2002-06" &
                as.integer(format(d$Date, "%d")) > 4] <- NA
  m <- aggregate_to_monthly(d)
  is.na(m$Discharge[m$Year == 2002 & m$Month == 6])
})

check("a discharge workbook is read and negative flow rejected", {
  d <- data.frame(Date = seq(as.Date("2001-01-01"), by = "day", length.out = 100),
                  Discharge = runif(100, 1, 9))
  got <- read_climate_excel(write_book(d, "flow.xlsx"), fields = c("Date", "Discharge"))
  bad <- d; bad$Discharge[5] <- -2
  nrow(got) == 100L &&
    inherits(try(read_climate_excel(write_book(bad, "flowneg.xlsx"),
                                    fields = c("Date", "Discharge")), silent = TRUE),
             "try-error")
})

check("discharge synonyms such as Flow and Q are accepted", {
  d <- data.frame(date = seq(as.Date("2001-01-01"), by = "day", length.out = 60),
                  Flow = runif(60, 1, 9))
  ok1 <- nrow(read_climate_excel(write_book(d, "syn_flow.xlsx"),
                                 fields = c("Date", "Discharge"))) == 60L
  names(d) <- c("date", "Q")
  ok2 <- nrow(read_climate_excel(write_book(d, "syn_q.xlsx"),
                                 fields = c("Date", "Discharge"))) == 60L
  ok1 && ok2
})

# --- RDI -------------------------------------------------------------------
# Precipitation with a mild seasonal cycle against PET with a very strong one:
# the aridity ratio alpha then has a large seasonal swing, which is the
# property that forces the per-calendar-month fit.
set.seed(41)
n_rdi <- 480
cal_r <- rep(1:12, length.out = n_rdi)
pet_seas <- c(2, 6, 24, 50, 88, 109, 122, 105, 68, 38, 16, 5)
p_seas   <- c(55, 50, 58, 62, 78, 92, 90, 85, 70, 62, 60, 58)
rdi_p <- p_seas[cal_r] * exp(rnorm(n_rdi, 0, 0.45))
rdi_e <- pet_seas[cal_r] * exp(rnorm(n_rdi, 0, 0.12))
p_ts <- stats::ts(rdi_p, start = c(1981, 1), frequency = 12)
e_ts <- stats::ts(rdi_e, start = c(1981, 1), frequency = 12)
rdi_res <- compute_rdi(p_ts, e_ts, scales = c(1, 3, 12))

check("RDI returns one column per scale plus the alpha ratio", {
  identical(names(rdi_res$values), c("RDI_1", "RDI_3", "RDI_12")) &&
    identical(names(rdi_res$alpha), c("Alpha_1", "Alpha_3", "Alpha_12")) &&
    all(vapply(rdi_res$values, length, integer(1)) == n_rdi)
})

check("alpha is accumulated P divided by accumulated PET", {
  a <- rdi_res$alpha$Alpha_3
  manual <- rolling_sum(rdi_p, 3) / rolling_sum(rdi_e, 3)
  isTRUE(all.equal(a, manual))
})

check("RDI is standardised: mean near 0 and sd near 1", {
  v <- rdi_res$values$RDI_1[is.finite(rdi_res$values$RDI_1)]
  abs(mean(v)) < 0.15 && abs(sd(v) - 1) < 0.15
})

check("RDI is fitted per calendar month, so the alpha seasonal cycle is removed", {
  max(abs(tapply(rdi_res$values$RDI_1, cal_r, mean, na.rm = TRUE))) < 0.15
})

check("pooling all months instead would leave a large seasonal signal in the index", {
  # What the user-supplied notebook computes: one mean and sd over every month.
  a <- rdi_res$alpha$Alpha_1
  pooled <- (log(a) - mean(log(a), na.rm = TRUE)) / sd(log(a), na.rm = TRUE)
  seasonal_range <- diff(range(tapply(pooled, cal_r, mean, na.rm = TRUE)))
  per_month <- diff(range(tapply(rdi_res$values$RDI_1, cal_r, mean, na.rm = TRUE)))
  seasonal_range > 2 && per_month < 0.3
})

check("alpha is undefined, and RDI empty, where accumulated PET is zero", {
  e0 <- rdi_e
  e0[cal_r == 1] <- 0                      # every January frozen
  r <- compute_rdi(p_ts, stats::ts(e0, start = c(1981, 1), frequency = 12), scales = 1)
  all(is.na(r$alpha$Alpha_1[cal_r == 1])) &&
    all(is.na(r$values$RDI_1[cal_r == 1])) &&
    !all(is.na(r$values$RDI_1)) &&
    length(r$undefined$RDI_1) == sum(cal_r == 1)
})

check("a longer window bridges the zero-PET months that break scale 1", {
  e0 <- rdi_e
  e0[cal_r == 1] <- 0
  r <- compute_rdi(p_ts, stats::ts(e0, start = c(1981, 1), frequency = 12),
                   scales = c(1, 12))
  sum(is.na(r$values$RDI_1)) > sum(is.na(r$values$RDI_12))
})

check("zero-precipitation accumulations stay finite under the correction", {
  p0 <- rdi_p
  p0[seq(7, n_rdi, by = 24)] <- 0
  r <- compute_rdi(stats::ts(p0, start = c(1981, 1), frequency = 12), e_ts, scales = 1)
  v <- r$values$RDI_1
  all(is.finite(v[!is.na(v)])) && !all(is.na(v[seq(7, n_rdi, by = 24)]))
})

check("the gamma variant ranks the same months as the log-normal one", {
  g <- compute_rdi(p_ts, e_ts, scales = 3, distribution = "gamma")$values$RDI_3
  l <- rdi_res$values$RDI_3
  ok <- is.finite(g) & is.finite(l)
  cor(g[ok], l[ok], method = "spearman") > 0.999
})

check("mismatched P and PET lengths are refused", {
  inherits(try(compute_rdi(p_ts, stats::ts(rdi_e[1:100], start = c(1981, 1),
                                           frequency = 12), scales = 1),
               silent = TRUE), "try-error")
})

check("an unknown distribution and negative inputs are refused", {
  bad_dist <- inherits(try(compute_rdi(p_ts, e_ts, scales = 1, distribution = "weibull"),
                           silent = TRUE), "try-error")
  neg <- rdi_p; neg[3] <- -1
  bad_val <- inherits(try(compute_rdi(stats::ts(neg, start = c(1981, 1), frequency = 12),
                                      e_ts, scales = 1), silent = TRUE), "try-error")
  bad_dist && bad_val
})

check("a scale longer than the record is skipped, not fatal", {
  r <- compute_rdi(stats::ts(rdi_p[1:24], start = c(1981, 1), frequency = 12),
                   stats::ts(rdi_e[1:24], start = c(1981, 1), frequency = 12),
                   scales = c(3, 48))
  identical(names(r$values), "RDI_3") && identical(r$skipped, 48L)
})

# --- shared aggregation and column resolution for PET ----------------------
check("a supplied PET column is summed to monthly totals", {
  d <- data.frame(Date = seq(as.Date("2001-01-01"), as.Date("2003-12-31"), by = "day"))
  d$Precipitation <- 2
  d$PET <- 3
  m <- aggregate_to_monthly(d)
  isTRUE(all.equal(m$PET[1], 3 * 31)) && "N_Days_PET" %in% names(m)
})

check("PET column synonyms are recognised and negative PET rejected", {
  d <- data.frame(date = seq(as.Date("2001-01-01"), by = "month", length.out = 48),
                  precip = runif(48, 10, 90), ET0 = runif(48, 1, 120))
  ok <- nrow(read_climate_excel(write_book(d, "pet_syn.xlsx"),
                                fields = c("Date", "Precipitation", "PET"))) == 48L
  bad <- d; bad$ET0[2] <- -5
  ok && inherits(try(read_climate_excel(write_book(bad, "pet_neg.xlsx"),
                                        fields = c("Date", "Precipitation", "PET")),
                     silent = TRUE), "try-error")
})

check("available_fields reports what a worksheet can supply", {
  d <- data.frame(date = seq(as.Date("2001-01-01"), by = "month", length.out = 24),
                  precip = 1, pet = 1)
  f <- available_fields(write_book(d, "avail.xlsx"))
  setequal(f, c("Date", "Precipitation", "PET"))
})

# --- input validation ------------------------------------------------------

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

check("a two-column workbook is accepted when only precipitation is needed", {
  two <- daily[1:200, c("Date", "Precipitation")]
  df <- read_climate_excel(write_book(two, "twocol.xlsx"),
                           fields = c("Date", "Precipitation"))
  nrow(df) == 200L && !("Temperature" %in% names(df))
})

check("a two-column workbook is refused when temperature is needed", {
  two <- daily[1:200, c("Date", "Precipitation")]
  e <- try(read_climate_excel(write_book(two, "twocol2.xlsx")), silent = TRUE)
  inherits(e, "try-error") && grepl("Temperature", conditionMessage(attr(e, "condition")))
})

check("worksheet names are listed", {
  p <- file.path(tmp, "multi.xlsx")
  writexl::write_xlsx(list(A = daily[1:40, ], B = daily[1:40, ]), p)
  identical(list_sheets(p), c("A", "B"))
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
