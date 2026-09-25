# ---------------------------------------------------------------------------
# climate-indices | Daily to monthly aggregation
#
# Three properties matter for every index downstream and are enforced here:
#   1. The monthly series is a CONTINUOUS calendar grid. A month absent from
#      the input becomes an explicit NA row rather than vanishing, which would
#      otherwise shift every later month and desynchronise the seasonal cycle.
#   2. A month assembled from too few daily observations becomes NA rather
#      than a partial total. Summing with na.rm = TRUE turns an empty month
#      into 0, which an index reads as an extreme drought.
#   3. Which monthly statistic each variable takes is declared once, in
#      MONTHLY_STATISTIC, so a new index adds its variable in one place.
#
# Written in base R on purpose. An earlier dplyr::summarise() version silently
# miscounted observation days because summarise() lets later expressions see
# the results of earlier ones, so an output column named after an input column
# changes that name's meaning mid-call.
# ---------------------------------------------------------------------------

MONTHLY_STATISTIC <- c(Temperature   = "mean",   # monthly mean air temperature
                       Precipitation = "sum",    # monthly total, mm
                       Discharge     = "sum",    # monthly total of daily flows
                       PET           = "sum")    # monthly total, mm, if supplied

#' Number of days in the calendar month containing each element of `d`.
#'
#' Vectorised: adding 31 days to the first of a month always lands inside the
#' following month, which truncating back to its first day then recovers.
days_in_month_of <- function(d) {
  first <- as.Date(format(d, "%Y-%m-01"))
  nxt <- as.Date(format(first + 31L, "%Y-%m-01"))
  as.integer(nxt - first)
}

#' The continuous monthly grid spanning a vector of dates.
monthly_grid <- function(dates) {
  ms <- as.Date(format(dates, "%Y-%m-01"))
  seq(min(ms), max(ms), by = "1 month")
}

#' Frame of calendar columns for a monthly grid.
monthly_skeleton <- function(grid) {
  data.frame(Date          = grid,
             Year          = as.integer(format(grid, "%Y")),
             Month         = as.integer(format(grid, "%m")),
             Days_In_Month = days_in_month_of(grid))
}

#' Which recognised variables a frame carries, in canonical order.
present_variables <- function(df) {
  vars <- intersect(names(MONTHLY_STATISTIC), names(df))
  if (length(vars) == 0L) {
    stop(sprintf("No recognised variable column found. Expected one of: %s",
                 paste(names(MONTHLY_STATISTIC), collapse = ", ")), call. = FALSE)
  }
  vars
}

#' Aggregate a daily series to monthly values on a continuous calendar grid.
#'
#' Temperature is averaged; precipitation and discharge are summed. A month
#' whose observed days fall below `min_coverage` of its length is reported as
#' missing.
#'
#' @param daily        data.frame with Date plus one or more recognised variables
#' @param min_coverage minimum fraction of a month's days that must carry a
#'                     valid observation for that month to be reported
#' @return data.frame: Date, Year, Month, Days_In_Month, N_Days_<var>..., <var>...
aggregate_to_monthly <- function(daily, min_coverage = 0.9) {
  if (min_coverage < 0 || min_coverage > 1) {
    stop("min_coverage must be between 0 and 1.", call. = FALSE)
  }
  vars <- present_variables(daily)
  month_start <- as.Date(format(daily$Date, "%Y-%m-01"))
  grid <- monthly_grid(daily$Date)
  key <- as.character(grid)

  out <- monthly_skeleton(grid)
  required <- ceiling(min_coverage * out$Days_In_Month)

  counts <- list()
  values <- list()
  for (v in vars) {
    x <- daily[[v]]
    n_obs <- tapply(!is.na(x), month_start, sum)
    agg <- if (identical(MONTHLY_STATISTIC[[v]], "mean")) {
      tapply(x, month_start, mean, na.rm = TRUE)
    } else {
      tapply(x, month_start, sum, na.rm = TRUE)
    }
    n <- as.integer(n_obs[key])
    n[is.na(n)] <- 0L
    val <- as.numeric(agg[key])
    val[is.nan(val)] <- NA_real_       # all-NA month: mean() yields NaN
    val[n < required] <- NA_real_      # coverage rule
    counts[[paste0("N_Days_", v)]] <- n
    values[[v]] <- val
  }
  cbind(out,
        as.data.frame(counts, check.names = FALSE),
        as.data.frame(values, check.names = FALSE))
}

#' Put an already-monthly input on the same continuous grid.
standardise_monthly <- function(monthly) {
  vars <- present_variables(monthly)
  ms <- as.Date(format(monthly$Date, "%Y-%m-01"))
  grid <- monthly_grid(monthly$Date)
  pos <- match(as.character(grid), as.character(ms))

  out <- monthly_skeleton(grid)
  counts <- list()
  values <- list()
  for (v in vars) {
    counts[[paste0("N_Days_", v)]] <- rep(NA_integer_, length(grid))
    values[[v]] <- as.numeric(monthly[[v]])[pos]
  }
  cbind(out,
        as.data.frame(counts, check.names = FALSE),
        as.data.frame(values, check.names = FALSE))
}

#' Wrap a monthly column as a ts anchored on its true calendar start.
#'
#' The start month is what lets thornthwaite() apply the right day-length
#' correction and lets the indices interpret a reference period. Passing a
#' bare vector makes those functions assume the series begins in January.
as_monthly_ts <- function(values, first_date) {
  stats::ts(values,
            start = c(as.integer(format(first_date, "%Y")),
                      as.integer(format(first_date, "%m"))),
            frequency = 12)
}
