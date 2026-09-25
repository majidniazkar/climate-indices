# ---------------------------------------------------------------------------
# climate-indices | RDI using the functions directly (e.g. from RStudio)
#
# The command line script is the usual route:
#   Rscript scripts/calculate_rdi.R --input <file.xlsx> --plot
#
# This file shows the same pipeline step by step, for when you want the
# intermediate objects in your session.
# ---------------------------------------------------------------------------

library(readxl); library(writexl); library(SPEI)

ROOT <- "."
for (f in c("climate_io.R", "monthly.R", "classify.R", "pet.R",
            "spi_index.R", "sdi_index.R", "rdi_index.R")) {
  source(file.path(ROOT, "R", f))   # spi/sdi supply rolling_sum(), the fits
}

# Route A: the workbook already carries PET -------------------------------
INPUT <- file.path(ROOT, "data", "example", "synthetic_monthly_precip_pet.xlsx")
available_fields(INPUT)            # Date, Precipitation, PET

monthly <- standardise_monthly(
  read_climate_excel(INPUT, fields = c("Date", "Precipitation", "PET")))

# Route B: no PET column, so compute it from temperature -------------------
# daily <- read_climate_excel("station.xlsx")          # Date, Temperature, Precipitation
# monthly <- aggregate_to_monthly(daily)
# monthly$PET <- as.numeric(compute_pet_thornthwaite(
#   as_monthly_ts(monthly$Temperature, monthly$Date[1]), 48.891))

# How many months have no evaporative demand at all? With Thornthwaite this is
# every month at or below 0 degC, and the aridity ratio is undefined there.
sum(monthly$PET == 0, na.rm = TRUE)

# RDI at several accumulation scales ---------------------------------------
first <- monthly$Date[1]
res <- compute_rdi(as_monthly_ts(monthly$Precipitation, first),
                   as_monthly_ts(monthly$PET, first),
                   scales = c(1, 3, 6, 9, 12, 24),
                   distribution = "log-normal")

res$undefined          # months lost to PET = 0, per scale
for (nm in names(res$alpha))  monthly[[nm]] <- res$alpha[[nm]]
for (nm in names(res$values)) monthly[[nm]] <- res$values[[nm]]

# Alpha_12 is the aridity ratio over a year: below 1 means PET exceeds P.
median(monthly$Alpha_12, na.rm = TRUE)

# The normalised form RDI_n is one step from the alpha columns:
monthly$RDI_n_12 <- monthly$Alpha_12 / mean(monthly$Alpha_12, na.rm = TRUE) - 1

summarise_categories(res$values)
worst <- monthly[order(monthly$RDI_12), c("Date", "Alpha_12", "RDI_12")]
head(worst[!is.na(worst$RDI_12), ], 10)

write_xlsx(monthly, "monthly_rdi.xlsx")
