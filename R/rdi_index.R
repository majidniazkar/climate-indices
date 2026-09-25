# ---------------------------------------------------------------------------
# climate-indices | Reconnaissance Drought Index
#
# Tsakiris & Vangelis (2005), European Water 9/10, 3-11;
# Tsakiris, Pangalou & Vangelis (2007), Water Resources Management 21, 821-833.
#
# RDI is built on the ratio of accumulated precipitation to accumulated
# potential evapotranspiration,
#
#     alpha_k = sum(P over k months) / sum(PET over k months),
#
# which is the aridity ratio over that window. The standardised form RDI_st is
# alpha_k transformed to a standard normal deviate, fitted SEPARATELY FOR EACH
# CALENDAR MONTH. The per-month fit is not optional decoration: alpha has a
# very large seasonal cycle in any climate with a cold season, because PET
# collapses towards zero in winter while precipitation does not. Standardising
# a pooled sample of all twelve months therefore produces an index that mostly
# reports which season it is.
#
# Two structural facts about alpha drive the handling below:
#   * alpha is UNDEFINED where accumulated PET is zero. With the Thornthwaite
#     method PET is exactly zero for any month whose mean temperature is at or
#     below 0 degC, so short-scale RDI has genuine winter gaps at cold sites.
#     Those months are reported as missing, and counted, rather than filled.
#   * alpha is ZERO where accumulated precipitation is zero, which no
#     log-normal or gamma fit can represent. This is the same zero-mass
#     problem as in SPI and SDI and is handled the same way.
# ---------------------------------------------------------------------------

RDI_DISTRIBUTIONS <- c("log-normal", "gamma", "normal")

#' The aridity ratio alpha_k = accumulated P / accumulated PET.
#'
#' @return numeric vector, NA where the window is incomplete or PET sums to 0
compute_alpha <- function(precip, pet, scale) {
  p_sum <- rolling_sum(precip, scale)
  e_sum <- rolling_sum(pet, scale)
  alpha <- rep(NA_real_, length(p_sum))
  ok <- is.finite(p_sum) & is.finite(e_sum) & e_sum > 0
  alpha[ok] <- p_sum[ok] / e_sum[ok]
  alpha
}

#' Compute RDI at several accumulation scales.
#'
#' @param precip_ts    monthly precipitation totals (mm) as a ts
#' @param pet_ts       monthly PET totals (mm) as a ts, the same length
#' @param scales       integer vector of accumulation lengths in months
#' @param distribution "log-normal" (default, the original RDI_st), "gamma" or
#'                     "normal"
#' @param ref_start,ref_end optional reference period as c(year, month)
#' @param zero_correction carry zero-precipitation accumulations as a
#'                     probability mass instead of dropping them
#' @return list(values, alpha, skipped, undefined, distribution)
compute_rdi <- function(precip_ts, pet_ts, scales = c(1, 3, 6, 9, 12, 24),
                        distribution = "log-normal",
                        ref_start = NULL, ref_end = NULL,
                        zero_correction = TRUE) {
  if (!stats::is.ts(precip_ts) || !stats::is.ts(pet_ts)) {
    stop("precip_ts and pet_ts must be ts objects; use as_monthly_ts().", call. = FALSE)
  }
  if (length(precip_ts) != length(pet_ts)) {
    stop("precip_ts and pet_ts must cover the same months.", call. = FALSE)
  }
  if (!distribution %in% RDI_DISTRIBUTIONS) {
    stop(sprintf("distribution must be one of: %s",
                 paste(RDI_DISTRIBUTIONS, collapse = ", ")), call. = FALSE)
  }
  p <- as.numeric(precip_ts)
  e <- as.numeric(pet_ts)
  if (all(is.na(p)) || all(is.na(e))) {
    stop("Precipitation or PET is missing for every month; RDI cannot be computed.",
         call. = FALSE)
  }
  if (any(p < 0, na.rm = TRUE) || any(e < 0, na.rm = TRUE)) {
    stop("Precipitation and PET must be non-negative.", call. = FALSE)
  }
  scales <- sort(unique(as.integer(scales)))
  if (any(is.na(scales)) || any(scales < 1L)) {
    stop("scales must be positive whole numbers of months.", call. = FALSE)
  }
  n <- length(p)
  usable <- scales[scales <= n]
  skipped <- scales[scales > n]

  cal_month <- as.integer(stats::cycle(precip_ts))
  in_ref <- reference_mask(precip_ts, ref_start, ref_end)

  values <- list()
  alphas <- list()
  undefined <- list()
  for (s in usable) {
    alpha <- compute_alpha(p, e, s)
    v <- rep(NA_real_, n)
    for (m in unique(cal_month)) {
      pos <- which(cal_month == m)
      v[pos] <- standardise_accumulation(alpha[pos], in_ref[pos],
                                         distribution = distribution,
                                         zero_correction = zero_correction)
    }
    # Months lost to PET = 0, as distinct from the incomplete leading window.
    lost <- which(is.na(alpha) & seq_len(n) >= s)
    if (length(lost) > 0L) undefined[[paste0("RDI_", s)]] <- lost
    alphas[[paste0("Alpha_", s)]] <- alpha
    values[[paste0("RDI_", s)]] <- v
  }
  list(values = values, alpha = alphas, skipped = skipped,
       undefined = undefined, distribution = distribution)
}
