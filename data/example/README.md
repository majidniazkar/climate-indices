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
