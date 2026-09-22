# ---------------------------------------------------------------------------
# climate-indices | Potential evapotranspiration
# ---------------------------------------------------------------------------

#' Monthly PET by the Thornthwaite (1948) method.
#'
#' Temperature-only method: it needs just monthly mean temperature and the
#' site latitude, which is why it pairs with a two-variable input file. It is
#' also the least demanding of the methods in the SPEI package and tends to
#' overestimate PET in arid climates -- see the method notes in README.md.
#'
#' @param temperature_ts monthly mean temperature in degrees Celsius, a ts
#'                       created by as_monthly_ts()
#' @param latitude       site latitude in decimal degrees, negative south
#' @return ts of monthly PET in mm
compute_pet_thornthwaite <- function(temperature_ts, latitude) {
  if (!stats::is.ts(temperature_ts)) {
    stop("temperature_ts must be a ts object; use as_monthly_ts().", call. = FALSE)
  }
  if (!is.numeric(latitude) || length(latitude) != 1L || is.na(latitude)) {
    stop("latitude must be a single number in decimal degrees.", call. = FALSE)
  }
  if (latitude < -90 || latitude > 90) {
    stop(sprintf("latitude %.4f is outside [-90, 90].", latitude), call. = FALSE)
  }
  if (all(is.na(temperature_ts))) {
    stop("Monthly mean temperature is missing for every month; PET cannot be computed.",
         call. = FALSE)
  }
  pet <- as.numeric(SPEI::thornthwaite(temperature_ts, lat = latitude,
                                       na.rm = TRUE, verbose = FALSE))
  # thornthwaite() returns 0 rather than NA for months it could not evaluate,
  # which a water balance would read as "no evaporative demand". Months with no
  # temperature observation have no PET estimate and are reported as missing.
  pet[is.na(as.numeric(temperature_ts))] <- NA_real_
  stats::ts(pet, start = stats::start(temperature_ts), frequency = 12)
}

#' Climatic water balance, P - PET, in mm.
compute_water_balance <- function(precipitation_ts, pet_ts) {
  stats::ts(as.numeric(precipitation_ts) - as.numeric(pet_ts),
            start = stats::start(precipitation_ts), frequency = 12)
}
