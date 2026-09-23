# ---------------------------------------------------------------------------
# climate-indices | SDI using the functions directly (e.g. from RStudio)
#
# The command line script is the usual route:
#   Rscript scripts/calculate_sdi.R --input <file.xlsx> --sheet all --plot
#
# This file shows the same pipeline step by step, for when you want the
# intermediate objects in your session.
# ---------------------------------------------------------------------------

library(readxl); library(writexl); library(SPEI)

# Point this at the repository root.
ROOT <- "."
for (f in c("climate_io.R", "monthly.R", "classify.R", "spi_index.R", "sdi_index.R")) {
  source(file.path(ROOT, "R", f))   # spi_index.R supplies rolling_sum(), fit_gamma_thom()
}

INPUT <- file.path(ROOT, "data", "example", "synthetic_daily_discharge.xlsx")

# 1. Which gauges does the workbook hold? -----------------------------------
list_sheets(INPUT)

# 2. Read one of them. SDI needs date and discharge only --------------------
daily <- read_climate_excel(INPUT, sheet = "Gauge_Karst",
                            fields = c("Date", "Discharge"))
str(daily)

# 3. Daily -> monthly totals, on a continuous calendar grid ------------------
monthly <- aggregate_to_monthly(daily, min_coverage = 0.9)
sum(monthly$Discharge == 0, na.rm = TRUE)   # zero-flow months, if any

# 4. SDI at several accumulation scales -------------------------------------
# log-normal is the default: monthly flow totals are strongly right-skewed,
# and the plain standardised anomaly ("normal") inherits that skew.
discharge_ts <- as_monthly_ts(monthly$Discharge, monthly$Date[1])
res <- compute_sdi(discharge_ts, scales = c(1, 3, 6, 9, 12, 24),
                   distribution = "log-normal")

res$zero_months     # calendar months containing zero-flow accumulations
for (nm in names(res$values)) monthly[[nm]] <- res$values[[nm]]

# Compare against the plain anomaly to see what the distribution choice costs:
plain <- compute_sdi(discharge_ts, scales = 1, distribution = "normal")$values$SDI_1
c(log_normal = sum(monthly$SDI_1 < -2, na.rm = TRUE),
  normal     = sum(plain < -2, na.rm = TRUE))

# 5. Inspect and save -------------------------------------------------------
head(monthly, 15)
summarise_categories(res$values)

worst <- monthly[order(monthly$SDI_12), c("Date", "SDI_12")]
head(worst[!is.na(worst$SDI_12), ], 10)

write_xlsx(monthly, "monthly_sdi.xlsx")
