# ---------------------------------------------------------------------------
# climate-indices | Input / output helpers
#
# Reading and validating the station workbook, and writing result files.
# Shared by every index in this repository.
# ---------------------------------------------------------------------------

REQUIRED_FIELDS <- c("Date", "Temperature", "Precipitation")

# Accepted spellings for each required field (matched case-insensitively,
# ignoring spaces, dots and underscores).
COLUMN_SYNONYMS <- list(
  Date          = c("date", "dates", "datetime", "time", "day", "datum"),
  Temperature   = c("temperature", "temp", "tmean", "tavg", "tave", "tmed",
                    "meantemperature", "airtemperature", "t"),
  Precipitation = c("precipitation", "precip", "prec", "prcp", "pr",
                    "rainfall", "rain", "p")
)

normalise_name <- function(x) {
  gsub("[^a-z0-9]", "", tolower(x))
}

#' Map the workbook's column names onto Date / Temperature / Precipitation.
#'
#' @param found character vector of column names as read from the file
#' @return named character vector: value = original column name,
#'         name  = canonical field name
resolve_columns <- function(found) {
  key <- normalise_name(found)
  mapping <- character(0)
  for (field in REQUIRED_FIELDS) {
    hit <- which(key %in% COLUMN_SYNONYMS[[field]])
    if (length(hit) == 0L) {
      stop(sprintf(
        paste0("Could not find a '%s' column in the input file.\n",
               "  Columns found : %s\n",
               "  Accepted names: %s\n",
               "  Expected layout: column 1 = Date, 2 = Temperature, 3 = Precipitation."),
        field, paste(found, collapse = ", "),
        paste(COLUMN_SYNONYMS[[field]], collapse = ", ")), call. = FALSE)
    }
    if (length(hit) > 1L) {
      stop(sprintf("Ambiguous input: %d columns could be the '%s' field (%s).",
                   length(hit), field, paste(found[hit], collapse = ", ")),
           call. = FALSE)
    }
    mapping[field] <- found[hit]
  }
  mapping
}

#' Coerce a column of mixed provenance into Date.
#'
#' Excel date cells arrive as POSIXct; dates stored as text arrive as
#' character and are tried against a list of common formats.
as_date_column <- function(x) {
  if (inherits(x, "Date")) return(x)
  if (inherits(x, "POSIXt")) return(as.Date(x))
  if (is.numeric(x)) {
    # Excel serial numbers (1900 date system).
    return(as.Date(x, origin = "1899-12-30"))
  }
  x <- trimws(as.character(x))
  formats <- c("%Y-%m-%d", "%Y/%m/%d", "%d.%m.%Y", "%d/%m/%Y",
               "%m/%d/%Y", "%d-%m-%Y", "%Y-%m", "%Y%m%d")
  for (fmt in formats) {
    parsed <- as.Date(x, format = fmt)
    if (!any(is.na(parsed))) return(parsed)
  }
  parsed <- as.Date(x, format = formats[1])
  stop(sprintf(
    paste0("Could not parse the Date column.\n",
           "  %d of %d values failed. First unparsed value: '%s'\n",
           "  Use real Excel date cells, or text in one of: %s"),
    sum(is.na(parsed)), length(parsed),
    x[which(is.na(parsed))[1]], paste(formats, collapse = ", ")), call. = FALSE)
}

#' Read and validate a climate workbook.
#'
#' @param path   path to an .xlsx / .xls file
#' @param sheet  sheet name or 1-based index
#' @return tibble with columns Date, Temperature, Precipitation, sorted by Date
read_climate_excel <- function(path, sheet = 1) {
  if (!file.exists(path)) {
    stop(sprintf("Input file not found: %s", normalizePath(path, mustWork = FALSE)),
         call. = FALSE)
  }
  raw <- readxl::read_excel(path, sheet = sheet, .name_repair = "minimal")
  if (nrow(raw) == 0L) stop("The input sheet contains no data rows.", call. = FALSE)

  names(raw) <- trimws(names(raw))
  mapping <- resolve_columns(names(raw))

  out <- data.frame(
    Date          = as_date_column(raw[[mapping[["Date"]]]]),
    Temperature   = suppressWarnings(as.numeric(unlist(raw[[mapping[["Temperature"]]]]))),
    Precipitation = suppressWarnings(as.numeric(unlist(raw[[mapping[["Precipitation"]]]]))),
    stringsAsFactors = FALSE
  )

  if (any(is.na(out$Date))) {
    stop(sprintf("%d row(s) have a missing or unreadable Date and cannot be placed in time.",
                 sum(is.na(out$Date))), call. = FALSE)
  }
  out <- out[order(out$Date), , drop = FALSE]

  dup <- out$Date[duplicated(out$Date)]
  if (length(dup) > 0L) {
    stop(sprintf("The Date column contains %d duplicated date(s), e.g. %s.",
                 length(unique(dup)), format(unique(dup)[1])), call. = FALSE)
  }

  validate_ranges(out)
  rownames(out) <- NULL
  out
}

#' Physical plausibility checks. Hard errors for impossible values,
#' warnings where the data is merely suspicious (e.g. wrong unit).
validate_ranges <- function(df) {
  p <- df$Precipitation[!is.na(df$Precipitation)]
  if (length(p) > 0L && any(p < 0)) {
    stop(sprintf("Precipitation contains %d negative value(s); check the input file.",
                 sum(p < 0)), call. = FALSE)
  }
  t <- df$Temperature[!is.na(df$Temperature)]
  if (length(t) == 0L) stop("The Temperature column is entirely missing.", call. = FALSE)

  if (stats::median(t) > 200) {
    warning("Temperature values look like kelvin. Thornthwaite PET expects degrees Celsius.",
            call. = FALSE)
  } else if (stats::median(t) > 45) {
    warning("Temperature values look like degrees Fahrenheit. Thornthwaite PET expects degrees Celsius.",
            call. = FALSE)
  }
  if (all(is.na(df$Precipitation))) {
    stop("The Precipitation column is entirely missing.", call. = FALSE)
  }
  invisible(TRUE)
}

#' Infer whether the input is daily or already monthly.
#'
#' @return "daily" or "monthly"
detect_frequency <- function(dates) {
  if (length(dates) < 2L) {
    stop("At least two rows are needed to determine the data frequency.", call. = FALSE)
  }
  step <- stats::median(as.numeric(diff(dates)))
  if (step <= 3) return("daily")
  if (step >= 26 && step <= 32) return("monthly")
  stop(sprintf(
    paste0("Unsupported time step: the median spacing between rows is %.1f days.\n",
           "  This tool accepts daily or monthly series. Use --input-frequency to override."),
    step), call. = FALSE)
}

#' Write the result workbook (and optionally a CSV of the same table).
write_results <- function(monthly, categories, metadata, output_dir, basename, write_csv = TRUE) {
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
  xlsx_path <- file.path(output_dir, paste0(basename, ".xlsx"))
  writexl::write_xlsx(
    list(Monthly_SPEI = monthly, Category_Summary = categories, Metadata = metadata),
    path = xlsx_path
  )
  paths <- c(xlsx = xlsx_path)
  if (isTRUE(write_csv)) {
    csv_path <- file.path(output_dir, paste0(basename, ".csv"))
    utils::write.csv(monthly, csv_path, row.names = FALSE, na = "")
    paths["csv"] <- csv_path
  }
  paths
}
