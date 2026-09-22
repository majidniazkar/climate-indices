# ---------------------------------------------------------------------------
# climate-indices | Daily to monthly aggregation
#
# Two properties matter for every index downstream and are enforced here:
#   1. The monthly series is a CONTINUOUS calendar grid. A month absent from
#      the input becomes an explicit NA row rather than vanishing, which would
#      otherwise shift every later month and desynchronise the seasonal cycle.
#   2. A month assembled from too few daily observations becomes NA rather
#      than a partial sum. Summing precipitation with na.rm = TRUE turns an
#      empty month into 0 mm, which an index reads as an extreme drought.
# ---------------------------------------------------------------------------

#' Number of days in the calendar month containing each element of `d`.
#'
#' Vectorised: adding 31 days to the first of a month always lands inside the
#' following month, which truncating back to its first day then recovers.
days_in_month_of <- function(d) {
  first <- as.Date(format(d, "%Y-%m-01"))
  nxt <- as.Date(format(first + 31L, "%Y-%m-01"))
  as.integer(nxt - first)
}

#' Aggregate a daily series to monthly means (temperature) and sums (precipitation).
#'
#' @param daily        data.frame with Date, Temperature, Precipitation
#' @param min_coverage minimum fraction of days in a month that must carry a
#'                     valid observation for that month to be reported
#' @return tibble on a continuous monthly grid
aggregate_to_monthly <- function(daily, min_coverage = 0.9) {
  if (min_coverage < 0 || min_coverage > 1) {
    stop("min_coverage must be between 0 and 1.", call. = FALSE)
  }
  d <- daily
  d$MonthStart <- as.Date(format(d$Date, "%Y-%m-01"))

  # The output names deliberately differ from the input columns. summarise()
  # evaluates its arguments in order and later ones see earlier results, so
  # naming an output `Temperature` would make a subsequent
  # `sum(!is.na(Temperature))` count the monthly mean rather than the days.
  agg <- dplyr::summarise(
    dplyr::group_by(d, MonthStart),
    n_days_t = sum(!is.na(Temperature)),
    n_days_p = sum(!is.na(Precipitation)),
    t_mean   = mean(Temperature, na.rm = TRUE),
    p_sum    = sum(Precipitation, na.rm = TRUE),
    .groups  = "drop"
  )
  names(agg) <- c("MonthStart", "N_Days_Temperature", "N_Days_Precipitation",
                  "Temperature", "Precipitation")
  # An all-NA month yields mean = NaN; normalise to NA before the coverage rule.
  agg$Temperature[is.nan(agg$Temperature)] <- NA_real_

  # Continuous calendar grid, first to last observed month.
  grid <- data.frame(
    MonthStart = seq(min(agg$MonthStart), max(agg$MonthStart), by = "1 month")
  )
  out <- dplyr::left_join(grid, agg, by = "MonthStart")
  out$N_Days_Temperature[is.na(out$N_Days_Temperature)] <- 0L
  out$N_Days_Precipitation[is.na(out$N_Days_Precipitation)] <- 0L

  # Coverage rule.
  required <- ceiling(min_coverage * days_in_month_of(out$MonthStart))
  out$Temperature[out$N_Days_Temperature   < required] <- NA_real_
  out$Precipitation[out$N_Days_Precipitation < required] <- NA_real_

  out$Date  <- out$MonthStart
  out$Year  <- as.integer(format(out$Date, "%Y"))
  out$Month <- as.integer(format(out$Date, "%m"))
  out$Days_In_Month <- days_in_month_of(out$Date)
  out$MonthStart <- NULL

  out[, c("Date", "Year", "Month", "Days_In_Month",
          "N_Days_Temperature", "N_Days_Precipitation",
          "Temperature", "Precipitation")]
}

#' Put an already-monthly input on the same continuous grid.
standardise_monthly <- function(monthly) {
  m <- monthly
  m$Date <- as.Date(format(m$Date, "%Y-%m-01"))
  grid <- data.frame(Date = seq(min(m$Date), max(m$Date), by = "1 month"))
  out <- dplyr::left_join(grid, m[, c("Date", "Temperature", "Precipitation")], by = "Date")
  out$Year  <- as.integer(format(out$Date, "%Y"))
  out$Month <- as.integer(format(out$Date, "%m"))
  out$Days_In_Month <- days_in_month_of(out$Date)
  out$N_Days_Temperature   <- NA_integer_
  out$N_Days_Precipitation <- NA_integer_
  out[, c("Date", "Year", "Month", "Days_In_Month",
          "N_Days_Temperature", "N_Days_Precipitation",
          "Temperature", "Precipitation")]
}

#' Wrap a monthly column as a ts anchored on its true calendar start.
#'
#' The start month is what lets thornthwaite() apply the right day-length
#' correction and lets spei() interpret a reference period. Passing a bare
#' vector makes both functions assume the series begins in January.
as_monthly_ts <- function(values, first_date) {
  stats::ts(values,
            start = c(as.integer(format(first_date, "%Y")),
                      as.integer(format(first_date, "%m"))),
            frequency = 12)
}
