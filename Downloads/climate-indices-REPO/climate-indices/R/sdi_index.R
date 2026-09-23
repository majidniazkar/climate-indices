# ---------------------------------------------------------------------------
# climate-indices | Streamflow Drought Index
#
# Nalbantis & Tsakiris (2009), Water Resources Management 23, 881-897.
#
# SDI standardises cumulative streamflow over an accumulation window, fitted
# separately for each calendar month. Two points of definition matter:
#
#   * the original paper writes SDI as (V - mean) / sd of the cumulative
#     volume, i.e. a standardised anomaly under an assumed NORMAL
#     distribution, and then immediately notes that streamflow volumes are
#     usually skewed, for which it prescribes the two-parameter LOG-NORMAL
#     variant: take natural logarithms first. Monthly streamflow totals are
#     strongly right-skewed in practice, so "log-normal" is the default here
#     and "normal" is offered for reproducing the plain-anomaly form;
#   * the paper evaluates SDI over the hydrological year at four fixed
#     reference periods. This implementation instead uses overlapping monthly
#     accumulation windows, as SPI and SPEI do and as the later SDI
#     literature generally does, so the three indices in this repository are
#     directly comparable month by month.
#
# Zero-flow months are handled as in SPI: an intermittent gauge has a finite
# probability mass at zero that neither the log-normal nor the gamma
# distribution can represent.
# ---------------------------------------------------------------------------

SDI_DISTRIBUTIONS <- c("log-normal", "gamma", "normal")

#' Standardise one calendar month's accumulations.
#'
#' @param acc          accumulated flow for this calendar month, NA where the
#'                     window is incomplete
#' @param in_ref       logical, which positions belong to the fitting period
#' @param distribution one of SDI_DISTRIBUTIONS
#' @param zero_correction treat zeros as a probability mass rather than
#'                     dropping them (ignored by the normal variant, which
#'                     needs no transformation)
#' @return numeric vector the same length as `acc`
standardise_accumulation <- function(acc, in_ref, distribution = "log-normal",
                                     zero_correction = TRUE) {
  out <- rep(NA_real_, length(acc))
  usable <- is.finite(acc)
  fit_sample <- acc[usable & in_ref]
  if (length(fit_sample) < 2L) return(out)

  if (identical(distribution, "normal")) {
    s <- stats::sd(fit_sample)
    if (!is.finite(s) || s == 0) return(out)
    out[usable] <- (acc[usable] - mean(fit_sample)) / s
    return(out)
  }

  q <- mean(fit_sample == 0)
  if (q >= 1) return(out)                      # never any flow in this month
  if (!isTRUE(zero_correction)) q <- 0         # zeros are then left undefined
  positive <- fit_sample[fit_sample > 0]
  if (length(positive) < 2L) return(out)

  probs <- rep(NA_real_, length(acc))
  if (identical(distribution, "gamma")) {
    g <- fit_gamma_thom(positive)
    probs[usable] <- stats::pgamma(acc[usable], shape = g$shape, scale = g$scale)
  } else {
    mu <- mean(log(positive))
    sdlog <- stats::sd(log(positive))
    if (!is.finite(sdlog) || sdlog == 0) return(out)
    probs[usable] <- stats::plnorm(acc[usable], meanlog = mu, sdlog = sdlog)
  }
  # Mixed distribution: H(x) = q + (1 - q) G(x). With q = 0 this is the plain
  # fit, and a zero accumulation maps to the finite value qnorm(q).
  h <- q + (1 - q) * probs
  if (!isTRUE(zero_correction)) h[usable & acc == 0] <- NA_real_
  out <- stats::qnorm(h)
  out[!is.finite(out)] <- NA_real_
  out
}

#' Compute SDI at several accumulation scales.
#'
#' @param discharge_ts monthly total discharge as a ts
#' @param scales       integer vector of accumulation lengths in months
#' @param distribution "log-normal" (default), "gamma" or "normal"
#' @param ref_start,ref_end optional reference period as c(year, month);
#'                     NULL fits on the whole record
#' @param zero_correction apply the mixed-distribution treatment to calendar
#'                     months containing zero-flow accumulations
#' @return list(values, skipped, zero_months, distribution)
compute_sdi <- function(discharge_ts, scales = c(1, 3, 6, 9, 12, 24),
                        distribution = "log-normal",
                        ref_start = NULL, ref_end = NULL,
                        zero_correction = TRUE) {
  if (!stats::is.ts(discharge_ts)) {
    stop("discharge_ts must be a ts object; use as_monthly_ts().", call. = FALSE)
  }
  if (!distribution %in% SDI_DISTRIBUTIONS) {
    stop(sprintf("distribution must be one of: %s",
                 paste(SDI_DISTRIBUTIONS, collapse = ", ")), call. = FALSE)
  }
  if (all(is.na(discharge_ts))) {
    stop("Monthly discharge is missing for every month; SDI cannot be computed.",
         call. = FALSE)
  }
  x <- as.numeric(discharge_ts)
  if (any(x < 0, na.rm = TRUE)) {
    stop("Monthly discharge contains negative values.", call. = FALSE)
  }
  scales <- sort(unique(as.integer(scales)))
  if (any(is.na(scales)) || any(scales < 1L)) {
    stop("scales must be positive whole numbers of months.", call. = FALSE)
  }
  n <- length(x)
  usable <- scales[scales <= n]
  skipped <- scales[scales > n]

  cal_month <- as.integer(stats::cycle(discharge_ts))
  in_ref <- reference_mask(discharge_ts, ref_start, ref_end)

  values <- list()
  zero_months <- list()
  for (s in usable) {
    acc <- rolling_sum(x, s)
    v <- rep(NA_real_, n)
    for (m in unique(cal_month)) {
      pos <- which(cal_month == m)
      v[pos] <- standardise_accumulation(acc[pos], in_ref[pos],
                                         distribution = distribution,
                                         zero_correction = zero_correction)
    }
    hit <- sort(unique(cal_month[which(acc == 0)]))
    if (length(hit) > 0L) zero_months[[paste0("SDI_", s)]] <- hit
    values[[paste0("SDI_", s)]] <- v
  }
  list(values = values, skipped = skipped, zero_months = zero_months,
       distribution = distribution)
}

#' Logical mask of the positions inside a c(year, month) reference window.
reference_mask <- function(x_ts, ref_start = NULL, ref_end = NULL) {
  tt <- stats::time(x_ts)
  yr <- floor(as.numeric(tt) + 1e-8)
  mo <- round((as.numeric(tt) - yr) * 12) + 1
  serial <- yr * 12 + (mo - 1)
  lo <- if (is.null(ref_start)) -Inf else ref_start[1] * 12 + (ref_start[2] - 1)
  hi <- if (is.null(ref_end))    Inf else ref_end[1]   * 12 + (ref_end[2]   - 1)
  serial >= lo & serial <= hi
}
