# Example datasets

**These files are synthetic.** They were generated to exercise and demonstrate
the code and are not observations of any real place. Do not use them for
anything but testing.

## `synthetic_daily_climate.xlsx`

10,958 daily rows, 1991-01-01 to 2020-12-31, in the layout the tool expects:

| Column | Unit | Description |
|---|---|---|
| `Date` | date | one row per day, no gaps |
| `Temperature` | °C | daily mean air temperature |
| `Precipitation` | mm | daily precipitation total |

Generated from a seasonal temperature cycle (annual mean about 9.4 °C, range
-8.9 to 26.0 °C) with an AR(1) noise process and a slight warming trend, and
an occurrence/intensity precipitation model with a wetter summer (median
annual total about 880 mm). Two multi-month dry spells were imposed, in 2003
and in 2015-16, so the resulting SPEI series contains recognisable droughts.
Values are consistent with a continental mid-latitude site near 49° N, which
is why the examples pass `--latitude 48.891`.

## `synthetic_daily_climate_with_gaps.xlsx`

The same record with missing values introduced deliberately, to exercise the
coverage rule:

- 2005-07-05 to 2005-07-31: temperature and precipitation both absent, so July
  2005 falls below the default 90 % coverage threshold and is reported as
  missing rather than as a partial monthly total.
- 2010-03-10 to 2010-03-14: precipitation absent only, five days out of 31,
  which also drops that month below the threshold.

Running the tool on this file reports one month without usable temperature and
two without usable precipitation.

## `synthetic_daily_precipitation.xlsx`

Three worksheets, one per notional station, each 10,958 daily rows from
1991-01-01 to 2020-12-31 with only the two columns SPI needs:

| Column | Unit | Description |
|---|---|---|
| `Date` | date | one row per day, no gaps |
| `Precipitation` | mm | daily precipitation total |

| Worksheet | Median annual total | Regime | Zero months |
|---|---|---|---|
| `Lowland` | 794 mm | temperate, summer-wet | 0 |
| `Upland` | 1233 mm | wetter, same seasonality | 0 |
| `Southslope` | 296 mm | semi-arid, winter-wet | 34 |

Generated from a rainfall occurrence and intensity model with a seasonal
cycle. Multi-month dry spells were imposed in 2003 and 2015-16 at all three
stations, so the resulting SPI series contain recognisable droughts; 2003 is
the driest year everywhere.

`Southslope` exists to exercise the zero-inflation correction: its 34 months
with no rain at all would otherwise return SPI = -Inf. Running with
`--sheet all` reports the correction being applied to its dry-season calendar
months, and leaves the other two stations untouched.

## `synthetic_daily_discharge.xlsx`

Three worksheets, one per notional gauge, each 10,958 daily rows from
1991-01-01 to 2020-12-31 with only the two columns SDI needs:

| Column | Unit | Description |
|---|---|---|
| `Date` | date | one row per day, no gaps |
| `Discharge` | m3/s | daily mean discharge |

| Worksheet | Daily mean | Regime | Zero-flow months |
|---|---|---|---|
| `Gauge_Upper` | 11.8 | small catchment, strong spring snowmelt peak | 0 |
| `Gauge_Lower` | 29.1 | larger catchment, damped seasonality | 0 |
| `Gauge_Karst` | 2.7 | intermittent, dries out in late summer and autumn | 13 |

Generated from a seasonal baseflow with an AR(1) log-residual plus rainfall
and melt events with exponential recession. Peak flows reach 8-17 times the
mean and the monthly totals are right-skewed (skewness 1.4-3.1), which is the
property that makes the distribution choice matter: the plain standardised
anomaly inherits that skew, while the log-normal and gamma variants do not.

Multi-month low-flow periods were imposed in 2003 and 2015-16 at all three
gauges. `Gauge_Karst` exists to exercise the zero-flow treatment; without it
its dry-season months would return an undefined index.

## `synthetic_monthly_precip_pet.xlsx`

One worksheet, 360 monthly rows (1991-01 to 2020-12), in the layout RDI
expects when PET has already been computed elsewhere:

| Column | Unit | Description |
|---|---|---|
| `date` | date | first of each month |
| `precip` | mm | monthly precipitation total |
| `pet` | mm | monthly potential evapotranspiration total |

Derived from `synthetic_daily_climate.xlsx`: precipitation aggregated to
monthly totals, and PET computed by the Thornthwaite method at latitude
48.891. Running `calculate_rdi.R` on this file and on the daily climate file
with `--latitude 48.891` gives the same answer to within rounding, which is
what makes it a useful check of the two PET routes.

Eleven of the 360 months have **PET exactly zero** — nine Januaries, one
February and one December, all with a mean temperature at or below 0 degC.
The aridity ratio is undefined for those months, so one-month RDI is empty
there. This is a property of the Thornthwaite method at cold sites, not a
defect, and the run log reports the count.
