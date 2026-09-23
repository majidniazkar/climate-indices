# ---------------------------------------------------------------------------
# climate-indices | Wet / dry classification, shared by every index
#
# McKee, Doesken & Kleist (1993). The same class boundaries are conventionally
# applied to SPI and to SPEI, both being expressed in standard deviations.
# ---------------------------------------------------------------------------

DROUGHT_BREAKS <- c(-Inf, -2, -1.5, -1, 1, 1.5, 2, Inf)
DROUGHT_LABELS <- c("Extremely dry", "Severely dry", "Moderately dry",
                    "Near normal", "Moderately wet", "Very wet", "Extremely wet")

#' Label standardised index values with their drought/wetness class.
classify_index <- function(x) {
  cut(x, breaks = DROUGHT_BREAKS, labels = DROUGHT_LABELS, right = FALSE)
}

# Kept for callers written against v1.0.0.
classify_spei <- classify_index

#' Count months per class for every computed scale.
#'
#' @param index_values named list of numeric vectors, names like SPI_3 / SPEI_12
#' @return long data.frame: Scale, Category, N_Months, Percent_Of_Valid
summarise_categories <- function(index_values) {
  rows <- list()
  for (nm in names(index_values)) {
    v <- index_values[[nm]]
    n_valid <- sum(is.finite(v))
    tab <- table(factor(classify_index(v), levels = DROUGHT_LABELS))
    rows[[nm]] <- data.frame(
      Scale            = as.integer(sub("^[A-Za-z]+_", "", nm)),
      Category         = names(tab),
      N_Months         = as.integer(tab),
      Percent_Of_Valid = if (n_valid > 0) round(100 * as.integer(tab) / n_valid, 2) else NA_real_,
      stringsAsFactors = FALSE
    )
  }
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}
