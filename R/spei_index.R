# ---------------------------------------------------------------------------
# climate-indices | Standardized Precipitation Evapotranspiration Index
#
# Vicente-Serrano, Begueria & Lopez-Moreno (2010), J. Climate 23, 1696-1718.
#
# The wet/dry classification and the category summary are shared with SPI and
# live in classify.R.
# ---------------------------------------------------------------------------

#' Compute SPEI at several accumulation scales.
#'
#' @param balance_ts   monthly water balance (P - PET) as a ts
#' @param scales       integer vector of accumulation lengths in months
#' @param distribution distribution fitted to the accumulated balance
#' @param fit          parameter estimation method
#' @param ref_start,ref_end optional reference period as c(year, month);
#'                     NULL fits on the whole record
#' @return list(values = named list of numeric vectors, skipped = integer vector)
compute_spei <- function(balance_ts, scales = c(1, 3, 6, 9, 12, 24),
                         distribution = "log-Logistic", fit = "ub-pwm",
                         ref_start = NULL, ref_end = NULL) {
  if (!stats::is.ts(balance_ts)) {
    stop("balance_ts must be a ts object; use as_monthly_ts().", call. = FALSE)
  }
  scales <- sort(unique(as.integer(scales)))
  if (any(is.na(scales)) || any(scales < 1L)) {
    stop("scales must be positive whole numbers of months.", call. = FALSE)
  }
  n <- length(balance_ts)
  usable <- scales[scales <= n]
  skipped <- scales[scales > n]

  values <- list()
  for (s in usable) {
    res <- SPEI::spei(balance_ts, scale = s, distribution = distribution,
                      fit = fit, ref.start = ref_start, ref.end = ref_end,
                      na.rm = TRUE, verbose = FALSE)
    values[[paste0("SPEI_", s)]] <- as.numeric(res$fitted)
  }
  list(values = values, skipped = skipped)
}
