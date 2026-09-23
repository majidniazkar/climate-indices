# ---------------------------------------------------------------------------
# climate-indices | Using the functions directly (e.g. from RStudio)
#
# The command line script is the usual route:
#   Rscript scripts/calculate_spei.R --input <file.xlsx> --latitude <lat> --plot
#
# This file shows the same pipeline step by step, for when you want the
# intermediate objects in your session.
# ---------------------------------------------------------------------------

library(readxl); library(writexl); library(dplyr); library(SPEI)

# Point this at the repository root.
ROOT <- "."
for (f in c("climate_io.R", "monthly.R", "pet.R", "spei_index.R")) {
  source(file.path(ROOT, "R", f))
}

INPUT    <- file.path(ROOT, "data", "example", "synthetic_daily_climate.xlsx")
LATITUDE <- 48.891   # decimal degrees, negative for the southern hemisphere

# 1. Read and validate the workbook -----------------------------------------
daily <- read_climate_excel(INPUT)
str(daily)

# 2. Daily -> monthly, on a continuous calendar grid -------------------------
monthly <- aggregate_to_monthly(daily, min_coverage = 0.9)

# 3. Thornthwaite PET and the climatic water balance ------------------------
temp_ts   <- as_monthly_ts(monthly$Temperature, monthly$Date[1])
precip_ts <- as_monthly_ts(monthly$Precipitation, monthly$Date[1])

pet_ts     <- compute_pet_thornthwaite(temp_ts, LATITUDE)
balance_ts <- compute_water_balance(precip_ts, pet_ts)

monthly$PET     <- as.numeric(pet_ts)
monthly$Balance <- as.numeric(balance_ts)

# 4. SPEI at several accumulation scales ------------------------------------
res <- compute_spei(balance_ts, scales = c(1, 3, 6, 9, 12, 24))
for (nm in names(res$values)) monthly[[nm]] <- res$values[[nm]]

# 5. Inspect and save -------------------------------------------------------
head(monthly, 15)
summarise_categories(res$values)

# The driest 12-month windows in the record:
worst <- monthly[order(monthly$SPEI_12), c("Date", "SPEI_12")]
head(worst[!is.na(worst$SPEI_12), ], 10)

write_xlsx(monthly, "monthly_pet_spei_multi_scale.xlsx")
