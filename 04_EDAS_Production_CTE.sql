/*******************************************************************************
  EMERGENCY DEPARTMENT ARRIVAL STUDY — PRODUCTION CTE
  LEAD ANALYST : Robert Hoye-Logan
  VERSION      : 1.0
  PROJECT      : Emergency Department Arrival Study (EDAS)
  DATASET      : NHAMCS 2019 Emergency Department Public Use File
  BIGQUERY     : ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw
  DATE         : June 2026

  GOAL: Test whether arrival method determines ED wait time independent of
  clinical severity. Theory: The Access Override — ambulance arrival routes
  patients ahead of triage priority, determining wait time independent of
  clinical severity as measured by triage level.

  CENTRAL QUESTION:
  Does arrival method determine how quickly you're seen in the ED —
  independent of clinical severity?

  PURPOSE: This is the production architecture — a single coherent CTE chain
  that mirrors all twelve analytical dimensions from the Master Step-by-Step.
  Each audit dimension is independently queryable via the commented SELECT
  blocks at the end of this file.
  For the step-by-step forensic workbench, see 04_EDAS_Master_StepByStep.sql.

  METHOD: Known Structure Execution — single unified CDC source with full
  codebook documentation. Count first, profile second.

  CLEAN UNIVERSE FILTER (defined once in CTE 1, applied throughout):
    ARREMS NOT IN (-9, -8)          -- excludes arrival method placeholders
    WAITTIME NOT IN (-9, -7, 99)    -- excludes wait time placeholders
    IMMEDR NOT IN (-9, -8, 0, 7)   -- excludes non-clinical triage codes
    Final clean universe: 11,512 rows (59.09% of 19,481 total records)

  CTE MAP (mirrors 04_EDAS_Master_StepByStep.sql):
    CTE 1  : clean_universe          → Steps 1-4  (exclusion layers + base dataset)
    CTE 2  : core_contrast           → Step 5     (mean wait by arrival x triage)
    CTE 3  : distribution_contrast   → Step 6     (median + IQR by arrival x triage)
    CTE 4  : time_of_day_contrast    → Step 8     (wait by arrival x time of day)
    CTE 5  : day_of_week_contrast    → Step 9     (wait by arrival x day of week)
    CTE 6  : pain_scale_contrast     → Step 10    (alternative severity control)
    CTE 7  : boarding_contrast       → Step 11    (alternative explanation test)
    CTE 8  : regional_contrast       → Step 12    (national scope confirmation)

  SUPPLEMENTAL QUERIES:
    SUPP 0  : column_inventory       → Step 0     (full schema — 911 columns)
    SUPP 4A : schema_validation      → Step 4A    (core column data types)

  NOTE: Column names follow CDC NHAMCS 2019 codebook conventions throughout
  all queries to maintain query integrity. Readable aliases are applied in
  all output columns. See 02_EDAS_Data_Dictionary for full definitions.

  NOTE: Step 0 (column inventory) and Step 4A (schema validation) are
  documented as supplemental queries at the end of this file. Both belong
  logically in the pre-analysis phase and were identified during execution
  rather than at project outset. Neither affected analysis integrity.
  See 04_EDAS_Master_StepByStep.sql for full sequence documentation.
*******************************************************************************/


WITH

-- ============================================================
-- CTE 1: CLEAN UNIVERSE
-- Mirrors : Steps 1-4 (exclusion layers)
-- Goal    : Apply all three exclusion layers simultaneously
--           and establish the base analytical dataset.
--           All downstream CTEs reference this CTE — the
--           clean universe filter is defined exactly once.
-- Records : 11,512 rows (59.09% of 19,481 total)
-- ============================================================

clean_universe AS (
  SELECT
    ARREMS,
    WAITTIME,
    IMMEDR,
    ARRTIME,
    VDAYR,
    PAINSCALE,
    BOARDED,
    REGION,
    -- Arrival method label derived once, used throughout
    CASE ARREMS
      WHEN 1 THEN 'Ambulance'
      WHEN 2 THEN 'Walk-in'
    END                                     AS arrival_method,
    -- Triage level label derived once, used throughout
    CASE IMMEDR
      WHEN 1 THEN '1 - Immediate'
      WHEN 2 THEN '2 - Emergent'
      WHEN 3 THEN '3 - Urgent'
      WHEN 4 THEN '4 - Semi-urgent'
      WHEN 5 THEN '5 - Non-urgent'
    END                                     AS triage_level,
    -- Time of day band derived once for Step 8
    CASE
      WHEN ARRTIME BETWEEN 0 AND 559
        THEN '1 - Overnight (0000-0559)'
      WHEN ARRTIME BETWEEN 600 AND 1159
        THEN '2 - Morning (0600-1159)'
      WHEN ARRTIME BETWEEN 1200 AND 1759
        THEN '3 - Afternoon (1200-1759)'
      WHEN ARRTIME BETWEEN 1800 AND 2359
        THEN '4 - Evening (1800-2359)'
    END                                     AS time_of_day,
    -- Day of week label derived once for Step 9
    CASE VDAYR
      WHEN 1 THEN '1 - Sunday'
      WHEN 2 THEN '2 - Monday'
      WHEN 3 THEN '3 - Tuesday'
      WHEN 4 THEN '4 - Wednesday'
      WHEN 5 THEN '5 - Thursday'
      WHEN 6 THEN '6 - Friday'
      WHEN 7 THEN '7 - Saturday'
    END                                     AS day_of_week,
    -- Boarding status derived once for Step 11
    CASE
      WHEN BOARDED = -7 THEN 'Not Boarded'
      WHEN BOARDED = -9 THEN 'Unknown'
      WHEN BOARDED = 0  THEN 'Boarded - 0 min'
      WHEN BOARDED > 0  THEN 'Boarded - >0 min'
    END                                     AS boarding_status,
    -- Census region label derived once for Step 12
    CASE REGION
      WHEN 1 THEN '1 - Northeast'
      WHEN 2 THEN '2 - Midwest'
      WHEN 3 THEN '3 - South'
      WHEN 4 THEN '4 - West'
    END                                     AS census_region
  FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
  WHERE ARREMS NOT IN (-9, -8)          -- excludes arrival method placeholders
    AND WAITTIME NOT IN (-9, -7, 99)    -- excludes wait time placeholders
    AND IMMEDR NOT IN (-9, -8, 0, 7)   -- excludes non-clinical triage codes
),


-- ============================================================
-- CTE 2: CORE CONTRAST
-- Mirrors : Step 5 — Core Contrast (Mean Wait by Arrival x Triage)
-- Goal    : Cross-tabulate arrival method against triage level
--           with mean, min, and max wait time per cell.
--           First direct test of the access override signal.
-- ============================================================

core_contrast AS (
  SELECT
    arrival_method,
    triage_level,
    IMMEDR                                  AS immedr_sort,
    ARREMS                                  AS arrems_sort,
    COUNT(*)                                AS n,
    ROUND(AVG(WAITTIME), 1)                 AS avg_wait_minutes,
    ROUND(MIN(WAITTIME), 1)                 AS min_wait_minutes,
    ROUND(MAX(WAITTIME), 1)                 AS max_wait_minutes
  FROM clean_universe
  GROUP BY
    arrival_method,
    triage_level,
    IMMEDR,
    ARREMS
),


-- ============================================================
-- CTE 3: DISTRIBUTION CONTRAST
-- Mirrors : Step 6 — Distribution Contrast (Median + IQR)
-- Goal    : Add median and interquartile range to the core
--           contrast to confirm the access override signal
--           holds independent of mean distortion by outliers.
--           APPROX_QUANTILES used — true aggregate function,
--           avoids PERCENTILE_CONT window function issues
--           documented in Step 6 methodology note.
-- ============================================================

distribution_contrast AS (
  SELECT
    arrival_method,
    triage_level,
    IMMEDR                                    AS immedr_sort,
    ARREMS                                    AS arrems_sort,
    COUNT(*)                                  AS n,
    ROUND(AVG(WAITTIME), 1)                   AS avg_wait_minutes,
    APPROX_QUANTILES(WAITTIME, 4)[OFFSET(2)]  AS median_wait_minutes,
    APPROX_QUANTILES(WAITTIME, 4)[OFFSET(1)]  AS p25_wait_minutes,
    APPROX_QUANTILES(WAITTIME, 4)[OFFSET(3)]  AS p75_wait_minutes
  FROM clean_universe
  GROUP BY
    arrival_method,
    triage_level,
    IMMEDR,
    ARREMS
),


-- ============================================================
-- CTE 4: TIME OF DAY CONTRAST
-- Mirrors : Step 8 — Contextual Contrast (Time of Day)
-- Goal    : Test whether time of day amplifies or reduces
--           the arrival method wait time gap.
--           Four operational bands follow standard ED
--           staffing period conventions.
-- ============================================================

time_of_day_contrast AS (
  SELECT
    arrival_method,
    time_of_day,
    ARREMS                                    AS arrems_sort,
    COUNT(*)                                  AS n,
    ROUND(AVG(WAITTIME), 1)                   AS avg_wait_minutes,
    APPROX_QUANTILES(WAITTIME, 4)[OFFSET(2)]  AS median_wait_minutes
  FROM clean_universe
  GROUP BY
    arrival_method,
    time_of_day,
    ARREMS
),


-- ============================================================
-- CTE 5: DAY OF WEEK CONTRAST
-- Mirrors : Step 9 — Contextual Contrast (Day of Week)
-- Goal    : Test whether day of week amplifies or reduces
--           the arrival method wait time gap.
--           CDC convention: 1=Sunday through 7=Saturday.
-- ============================================================

day_of_week_contrast AS (
  SELECT
    arrival_method,
    day_of_week,
    VDAYR                                     AS vdayr_sort,
    ARREMS                                    AS arrems_sort,
    COUNT(*)                                  AS n,
    ROUND(AVG(WAITTIME), 1)                   AS avg_wait_minutes,
    APPROX_QUANTILES(WAITTIME, 4)[OFFSET(2)]  AS median_wait_minutes
  FROM clean_universe
  GROUP BY
    arrival_method,
    day_of_week,
    VDAYR,
    ARREMS
),


-- ============================================================
-- CTE 6: PAIN SCALE CONTRAST
-- Mirrors : Step 10 — Alternative Severity Control (Pain Scale)
-- Goal    : Test whether the access override signal holds
--           when controlling for patient-reported pain score
--           as a second severity measure independent of
--           clinician-assigned triage level.
--           Pain score is patient-reported — independent of
--           any clinician knowledge of arrival method.
--           Placeholder codes (-9, -8) retained in output
--           for transparency; excluded from findings.
-- ============================================================

pain_scale_contrast AS (
  SELECT
    arrival_method,
    PAINSCALE                                 AS pain_score,
    ARREMS                                    AS arrems_sort,
    COUNT(*)                                  AS n,
    ROUND(AVG(WAITTIME), 1)                   AS avg_wait_minutes,
    APPROX_QUANTILES(WAITTIME, 4)[OFFSET(2)]  AS median_wait_minutes
  FROM clean_universe
  GROUP BY
    arrival_method,
    PAINSCALE,
    ARREMS
),


-- ============================================================
-- CTE 7: BOARDING CONTRAST
-- Mirrors : Step 11 — Alternative Explanation Test (Boarding)
-- Goal    : Test whether ED boarding explains the walk-in
--           wait time disadvantage as an alternative to the
--           access override routing explanation.
--           BOARDED is a duration field in minutes — not a
--           binary flag. Confirmed by profiling before contrast.
--           Percentage calculated within each arrival method
--           using a partitioned window function.
-- ============================================================

boarding_contrast AS (
  SELECT
    arrival_method,
    boarding_status,
    ARREMS                                    AS arrems_sort,
    COUNT(*)                                  AS n,
    ROUND(COUNT(*) * 100.0
          / SUM(COUNT(*)) OVER
            (PARTITION BY ARREMS), 2)         AS pct_of_arrival_method,
    ROUND(AVG(WAITTIME), 1)                   AS avg_wait_minutes,
    APPROX_QUANTILES(WAITTIME, 4)[OFFSET(2)]  AS median_wait_minutes
  FROM clean_universe
  GROUP BY
    arrival_method,
    boarding_status,
    ARREMS
),


-- ============================================================
-- CTE 8: REGIONAL CONTRAST
-- Mirrors : Step 12 — Regional Analysis (National Scope)
-- Goal    : Test whether the access override signal holds
--           across all four US Census regions to confirm
--           the finding is national in scope.
-- ============================================================

regional_contrast AS (
  SELECT
    census_region,
    arrival_method,
    REGION                                    AS region_sort,
    ARREMS                                    AS arrems_sort,
    COUNT(*)                                  AS n,
    ROUND(AVG(WAITTIME), 1)                   AS avg_wait_minutes,
    APPROX_QUANTILES(WAITTIME, 4)[OFFSET(2)]  AS median_wait_minutes
  FROM clean_universe
  GROUP BY
    census_region,
    arrival_method,
    REGION,
    ARREMS
)


-- ============================================================
-- FINAL OUTPUT
-- Uncomment one block to run that audit dimension.
-- Distribution Contrast is active by default as the primary
-- analytical output — median is the lead statistic throughout
-- this audit. Means are distorted by outliers confirmed in
-- Step 5 (max wait times up to 1,440 minutes).
-- ============================================================

-- Core Contrast — Step 5 (Mean wait by arrival x triage):
-- SELECT
--   arrival_method,
--   triage_level,
--   n,
--   avg_wait_minutes,
--   min_wait_minutes,
--   max_wait_minutes
-- FROM core_contrast
-- ORDER BY immedr_sort, arrems_sort;

-- Distribution Contrast — Step 6 (Median + IQR — default active):
SELECT
  arrival_method,
  triage_level,
  n,
  avg_wait_minutes,
  median_wait_minutes,
  p25_wait_minutes,
  p75_wait_minutes
FROM distribution_contrast
ORDER BY immedr_sort, arrems_sort;

-- Time of Day Contrast — Step 8:
-- SELECT
--   arrival_method,
--   time_of_day,
--   n,
--   avg_wait_minutes,
--   median_wait_minutes
-- FROM time_of_day_contrast
-- ORDER BY time_of_day, arrems_sort;

-- Day of Week Contrast — Step 9:
-- SELECT
--   arrival_method,
--   day_of_week,
--   n,
--   avg_wait_minutes,
--   median_wait_minutes
-- FROM day_of_week_contrast
-- ORDER BY vdayr_sort, arrems_sort;

-- Pain Scale Contrast — Step 10:
-- SELECT
--   arrival_method,
--   pain_score,
--   n,
--   avg_wait_minutes,
--   median_wait_minutes
-- FROM pain_scale_contrast
-- ORDER BY pain_score, arrems_sort;

-- Boarding Contrast — Step 11:
-- SELECT
--   arrival_method,
--   boarding_status,
--   n,
--   pct_of_arrival_method,
--   avg_wait_minutes,
--   median_wait_minutes
-- FROM boarding_contrast
-- ORDER BY arrems_sort, boarding_status;

-- Regional Contrast — Step 12:
-- SELECT
--   census_region,
--   arrival_method,
--   n,
--   avg_wait_minutes,
--   median_wait_minutes
-- FROM regional_contrast
-- ORDER BY region_sort, arrems_sort;


/*******************************************************************************
  SUPPLEMENTAL QUERIES
  Note: The following queries run directly against the raw table rather than
  the clean_universe CTE. They are pre-analysis structural queries that belong
  logically before Step 1 and before any aggregate calculations. Documented
  here for completeness. See 04_EDAS_Master_StepByStep.sql for full
  sequence notes and run dates.
*******************************************************************************/


-- SUPP 0: FULL COLUMN INVENTORY
-- Mirrors  : Step 0 of 04_EDAS_Master_StepByStep.sql
-- Goal     : Complete structural inventory of all 911 columns
--            including name, data type, and ordinal position.
-- Run date : June 11, 2026
-- SELECT
--   column_name,
--   data_type,
--   ordinal_position
-- FROM `ed-clinical-throughput-audit.clinical_throughput`.INFORMATION_SCHEMA.COLUMNS
-- WHERE table_name = 'nhamcs_2019_raw'
-- ORDER BY ordinal_position;


-- SUPP 4A: SCHEMA VALIDATION — CORE COLUMN DATA TYPES
-- Mirrors  : Step 4A of 04_EDAS_Master_StepByStep.sql
-- Goal     : Confirm all core audit columns are INT64 before
--            aggregate calculations. No casting required.
-- Run date : June 11, 2026
-- SELECT
--   column_name,
--   data_type
-- FROM `ed-clinical-throughput-audit.clinical_throughput`.INFORMATION_SCHEMA.COLUMNS
-- WHERE table_name = 'nhamcs_2019_raw'
--   AND column_name IN ('ARREMS', 'WAITTIME', 'IMMEDR', 'LOV');