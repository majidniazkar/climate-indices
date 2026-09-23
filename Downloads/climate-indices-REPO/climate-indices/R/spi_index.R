# ---------------------------------------------------------------------------
# climate-indices | Standardized Precipitation Index
#
# McKee, Doesken & Kleist (1993), 8th Conf. on Applied Climatology, 179-184.
#
# SPI is the precipitation total accumulated over `scale` months, transformed
# to the standard normal deviate that has the same cumulative probability
# under a distribution fitted to that accumulation. Two properties of the
# definition are easy to lose and are the reason this is not a z-score of the
# rolling sum:
#
#   * the fit is per CALENDAR MONTH, so the seasonal cycle is removed. Pooling
#     January and July totals into one distribution leaves the seasonal signal
#     in the index;
#   * monthly precipitation is strongly right-skewed and bounded at zero, so a
#     gamma (or similar) fit followed by the normal transform is not
#     interchangeable with subtracting a mean and dividing by a standard
#     deviation. The two agree only near the middle of the distribution, and
#     drought monitoring lives in the tail.
# ---------------------------------------------------------------------------

#' Right-aligned rolling sum, NA whenever the window is not complete.
rolling_sum <- function(x, k) {
  n <- length(x)
  if (k <= 1L) return(as.numeric(x))
  out <- rep(NA_real_, n)
  filled <- ifelse(is.na(x), 0, x)
  cs <- c(0, cumsum(filled))
  cn <- c(0, cumsum(is.na(x)))
  idx <- seq.int(k, n)
  complete <- (cn[idx + 1L] - cn[idx - k + 1L]) == 0L
  out[idx[complete]] <- (cs[idx + 1L] - cs[idx - k + 1L])[complete]
  out
}

#' Gamma parameters by the Thom (1958) maximum likelihood approximation,
#' the estimator used by the reference SPI implementations.
fit_gamma_thom <- function(x) {
  x <- x[is.finite(x) & x > 0]
  if (length(x) < 2L) stop("Too few positive values to fit a gamma distribution.",
                           call. = FALSE)
  xbar <- mean(x)
  A <- log(xbar) - mean(log(x))
  if (!is.finite(A) || A <= 0) {
    # Degenerate sample (e.g. all values equal); fall back on moments.
    v <- stats::var(x)
    if (!is.finite(v) || v <= 0) stop("Zero-variance sample.", call. = FALSE)
    return(list(shape = xbar^2 / v, scale = v / xbar))
  }
  shape <- (1 + sqrt(1 + 4 * A / 3)) / (4 * A)
  list(shape = shape, scale = xbar / shape)
}

#' Zero-inflation correction of Edwards & McKee (1997).
#'
#' SPEI::spi() fits the gamma distribution to the accumulation including its
#' zeros, and a zero then sits at cumulative probability 0, so the index comes
#' back as -Inf. The convention instead treats the accumulation as a mixed
#' distribution: H(x) = q + (1 - q) G(x), with q the observed frequency of
#' zero accumulations for that calendar month and G a gamma fitted to the
#' positive ones. A zero then maps to the finite value qnorm(q).
#'
#' @return numeric vector of SPI values for the supplied positions
spi_zero_corrected <- function(acc) {
  ok <- is.finite(acc)
  out <- rep(NA_real_, length(acc))
  if (!any(ok)) return(out)
  q <- mean(acc[ok] == 0)
  if (q >= 1) return(out)   # every accumulation zero: the index is undefined
  g <- fit_gamma_thom(acc[ok])
  probs <- q + (1 - q) * stats::pgamma(acc[ok], shape = g$shape, scale = g$scale)
  out[ok] <- stats::qnorm(probs)
  out
}

#' Compute SPI at several accumulation scales.
#'
#' @param precip_ts    monthly precipitation totals (mm) as a ts
#' @param scales       integer vector of accumulation lengths in months
#' @param distribution distribution fitted to the accumulated precipitation
#' @param fit          parameter estimation method
#' @param ref_start,ref_end optional reference period as c(year, month)
#' @param zero_correction apply the mixed-distribution correction to calendar
#'                     months that contain zero accumulations
#' @return list(values, skipped, zero_corrected)
compute_spi <- function(precip_ts, scales = c(1, 3, 6, 9, 12, 24),
                        distribution = "Gamma", fit = "ub-pwm",
                        ref_start = NULL, ref_end = NULL,
                        zero_correction = TRUE) {
  if (!stats::is.ts(precip_ts)) {
    stop("precip_ts must be a ts object; use as_monthly_ts().", call. = FALSE)
  }
  if (all(is.na(precip_ts))) {
    stop("Monthly precipitation is missing for every month; SPI cannot be computed.",
         call. = FALSE)
  }
  scales <- sort(unique(as.integer(scales)))
  if (any(is.na(scales)) || any(scales < 1L)) {
    stop("scales must be positive whole numbers of months.", call. = FALSE)
  }
  n <- length(precip_ts)
  usable <- scales[scales <= n]
  skipped <- scales[scales > n]
  cal_month <- as.integer(stats::cycle(precip_ts))

  values <- list()
  corrected <- list()
  for (s in usable) {
    res <- SPEI::spi(precip_ts, scale = s, distribution = distribution, fit = fit,
                     ref.start = ref_start, ref.end = ref_end,
                     na.rm = TRUE, verbose = FALSE)
    v <- as.numeric(res$fitted)
    acc <- rolling_sum(as.numeric(precip_ts), s)

    if (isTRUE(zero_correction) && any(acc == 0, na.rm = TRUE)) {
      # Refit the affected calendar months as a whole, so every value within a
      # calendar month comes from one consistent model.
      affected <- sort(unique(cal_month[which(acc == 0)]))
      for (m in affected) {
        pos <- which(cal_month == m)
        v[pos] <- spi_zero_corrected(acc[pos])
      }
      corrected[[paste0("SPI_", s)]] <- affected
    }

    # Any remaining non-finite value would be written to the output as -Inf.
    v[!is.finite(v)] <- NA_real_
    values[[paste0("SPI_", s)]] <- v
  }
  list(values = values, skipped = skipped, zero_corrected = corrected)
}
