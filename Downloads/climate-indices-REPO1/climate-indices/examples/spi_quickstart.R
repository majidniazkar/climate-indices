# ---------------------------------------------------------------------------
# climate-indices | SPI using the functions directly (e.g. from RStudio)
#
# The command line script is the usual route:
#   Rscript scripts/calculate_spi.R --input <file.xlsx> --sheet all --plot
#
# This file shows the same pipeline step by step, for when you want the
# intermediate objects in your session.
# ---------------------------------------------------------------------------

library(readxl); library(writexl); library(dplyr); library(SPEI)

# Point this at the repository root.
ROOT <- "."
for (f in c("climate_io.R", "monthly.R", "classify.R", "spi_index.R")) {
  source(file.path(ROOT, "R", f))
}

INPUT <- file.path(ROOT, "data", "example", "synthetic_daily_precipitation.xlsx")

# 1. Which worksheets does the workbook hold? -------------------------------
list_sheets(INPUT)

# 2. Read one of them. SPI needs no temperature, so ask for two fields ------
daily <- read_climate_excel(INPUT, sheet = "Southslope",
                            fields = c("Date", "Precipitation"))
str(daily)

# 3. Daily -> monthly totals, on a continuous calendar grid ------------------
monthly <- aggregate_to_monthly(daily, min_coverage = 0.9)
sum(monthly$Precipitation == 0, na.rm = TRUE)   # dry months, if any

# 4. SPI at several accumulation scales -------------------------------------
# The fit is per calendar month, and zero months are handled by the
# mixed-distribution correction rather than returning -Inf.
precip_ts <- as_monthly_ts(monthly$Precipitation, monthly$Date[1])
res <- compute_spi(precip_ts, scales = c(1, 3, 6, 9, 12, 24))

res$zero_corrected      # which calendar months needed the correction
for (nm in names(res$values)) monthly[[nm]] <- res$values[[nm]]

# 5. Inspect and save -------------------------------------------------------
head(monthly, 15)
summarise_categories(res$values)

# The driest 12-month windows in the record:
worst <- monthly[order(monthly$SPI_12), c("Date", "SPI_12")]
head(worst[!is.na(worst$SPI_12), ], 10)

write_xlsx(monthly, "monthly_spi.xlsx")
