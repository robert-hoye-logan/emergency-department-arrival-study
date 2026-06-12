/*******************************************************************************
  ED ACCESS OVERRIDE AUDIT — MASTER STEP-BY-STEP
  LEAD ANALYST : Robert Hoye-Logan
  VERSION      : 1.0
  PROJECT      : ED Access Override Audit (EDAOA)
  DATASET      : NHAMCS 2019 Emergency Department Public Use File
  BIGQUERY     : ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw
  DATES        : June 10–11, 2026

  GOAL: Test whether arrival method determines ED wait time independent of
  clinical severity. Theory: The Access Override — ambulance arrival routes
  patients ahead of triage priority, determining wait time independent of
  clinical severity as measured by triage level.

  CENTRAL QUESTION:
  Does arrival method determine how quickly you're seen in the ED —
  independent of clinical severity?

  SUPPORTING QUESTIONS:
  1. What is the overall wait time distribution? — establishing the baseline
  2. How does wait time differ by arrival method? — the core finding
  3. Does triage severity explain the difference? — the critical test
  4. Do operational conditions like time of day or day of week amplify or
     reduce the gap? — the contextual layer
  5. Does the gap hold when controlling for patient-reported pain score?
  6. Does ED boarding explain the walk-in wait time disadvantage?
  7. Does the gap hold across all US Census regions?

  PURPOSE: This is the forensic workbench — standalone queries executed
  sequentially in BigQuery to audit each analytical dimension individually.
  Each step is self-contained and independently reproducible.
  For the production CTE architecture, see 04_EDAOA_Production_CTE.sql.

  METHOD: Known Structure Execution — single unified CDC source with full
  codebook documentation. Count first, profile second.

  CLEAN UNIVERSE FILTER (applied in every analytical step):
    WHERE ARREMS NOT IN (-9, -8)          -- excludes arrival method placeholders
      AND WAITTIME NOT IN (-9, -7, 99)    -- excludes wait time placeholders
      AND IMMEDR NOT IN (-9, -8, 0, 7)   -- excludes non-clinical triage codes
    Final clean universe: 11,512 rows (59.09% of 19,481 total records)
    See Steps 2, 3, and 4 for full exclusion documentation.

  STEP MAP:
    STEP 0    : Full Column Inventory        (Schema — all 911 columns)
    STEP 1    : Record Count & Cardinality   (Baseline counts)
    STEP 1A   : Column Profile & Placeholder Hunt (ARREMS + WAITTIME)
    STEP 2    : Clean Universe Count         (Two-layer exclusion)
    STEP 3    : Triage Level Profile         (IMMEDR distribution)
    STEP 4    : Final Clean Universe Count   (Three-layer exclusion)
    STEP 4A   : Schema Validation            (Core column data types)
    STEP 5    : Core Contrast                (Mean wait by arrival x triage)
    STEP 6    : Distribution Contrast        (Median + IQR by arrival x triage)
    STEP 7    : ARRTIME + VDAYR Profile      (Time and day confirmation)
    STEP 8    : Contextual Contrast — Time   (Wait by arrival x time of day)
    STEP 9    : Contextual Contrast — Day    (Wait by arrival x day of week)
    STEP 10   : Pain Scale Control           (Alternative severity measure)
    STEP 11   : Boarding Analysis            (Alternative explanation test)
    STEP 12   : Regional Analysis            (National scope confirmation)

  NOTE: Step 0 and Step 4A were identified during analysis rather than at
  project outset. Step 0 (column inventory) belongs logically before Step 1
  and was caught during contextual layer planning. Step 4A (schema validation)
  belongs logically after Step 1 and was caught before any calculations ran.
  Neither gap affected analysis integrity. Both are documented at their
  correct logical position with execution dates noted.

  NOTE: Column names follow CDC NHAMCS 2019 codebook conventions throughout
  all queries to maintain query integrity. Readable aliases are applied in
  all output columns. See 02_EDAOA_Data_Dictionary for full definitions.
*******************************************************************************/


-- ============================================================
-- EDAOA | Step 0: Full Column Inventory
-- Goal    : Establish complete structural inventory of all
--           columns including name, data type, and ordinal
--           position before any analysis begins
-- Note    : Identified as necessary during contextual layer
--           planning (Step 7). Belongs logically before Step 1.
--           Caught before any analysis integrity was affected.
-- Run date: June 11, 2026
-- ============================================================

SELECT
  column_name,
  data_type,
  ordinal_position
FROM `ed-clinical-throughput-audit.clinical_throughput`.INFORMATION_SCHEMA.COLUMNS
WHERE table_name = 'nhamcs_2019_raw'
ORDER BY ordinal_position;

-- RESULTS: 911 total columns
-- Core audit columns confirmed:
-- VMONTH    INT64   1    visit month
-- VDAYR     INT64   2    day of week
-- ARRTIME   INT64   3    arrival time (military format confirmed Step 7)
-- WAITTIME  INT64   4    wait time in minutes
-- LOV       INT64   5    length of visit
-- AGE       INT64   6    patient age
-- ARREMS    INT64   16   arrival method
-- IMMEDR    INT64   34   triage level (immediacy rating)
-- PAINSCALE INT64   35   pain scale score
-- TOTCHRON  INT64   89   total chronic conditions
-- ADMIT     INT64   245  admission status
-- REGION    INT64   303  geographic region
-- BOARDED   INT64   911  boarding duration in minutes
-- PATWT     FLOAT64 909  patient survey weight
-- EDWT      FLOAT64 910  ED survey weight
--
-- NOTE: PATWT and EDWT are CDC complex sample survey weights.
-- Unweighted analysis is valid for within-dataset pattern
-- detection. National estimates require weight application.
-- All EDAOA analysis is unweighted and scoped to pattern
-- detection within the 2019 sample.
--
-- NOTE: Mixed data types observed in medication columns
-- (DRUGID1-30, RX fields). Outside EDAOA scope.


-- ============================================================
-- EDAOA | Step 1: Record Count + Column Cardinality Baseline
-- Goal    : Establish total record count and distinct value
--           counts for the four core audit columns before
--           any profiling
-- Run date: June 10, 2026
-- ============================================================

SELECT
  COUNT(*)                    AS total_records,
  COUNT(DISTINCT ARREMS)      AS distinct_arrems,
  COUNT(DISTINCT WAITTIME)    AS distinct_waittime,
  COUNT(DISTINCT IMMEDR)      AS distinct_immedr,
  COUNT(DISTINCT LOV)         AS distinct_lov
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`;

-- RESULTS:
-- total_records      : 19,481
-- distinct_arrems    : 4       (expected 1-5; 4 values present)
-- distinct_waittime  : 465     (wide range; placeholder codes suspected)
-- distinct_immedr    : 9       (expected 1-5; CDC placeholders confirmed present)
-- distinct_lov       : 1,394   (continuous-like; placeholder review pending)


-- ============================================================
-- EDAOA | Step 1a: Column Profile + Placeholder Hunt
-- Goal    : Profile ARREMS and WAITTIME distributions;
--           explicitly surface CDC placeholder codes in WAITTIME
-- Run date: June 10, 2026
-- ============================================================

-- BLOCK 1 — ARREMS arrival method distribution
SELECT
  'ARREMS'                        AS column_name,
  CAST(ARREMS AS STRING)          AS value,
  COUNT(*)                        AS n,
  ROUND(COUNT(*) * 100.0
        / SUM(COUNT(*)) OVER (), 2) AS pct_of_total,
  'arrival_distribution'          AS block
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
GROUP BY ARREMS

UNION ALL

-- BLOCK 2 — WAITTIME top-20 most frequent values
SELECT
  'WAITTIME'                      AS column_name,
  CAST(WAITTIME AS STRING)        AS value,
  COUNT(*)                        AS n,
  ROUND(COUNT(*) * 100.0
        / SUM(COUNT(*)) OVER (), 2) AS pct_of_total,
  'waittime_top20'                AS block
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
GROUP BY WAITTIME
QUALIFY ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) <= 20

UNION ALL

-- BLOCK 3 — CDC placeholder code hunt in WAITTIME
SELECT
  'WAITTIME_PLACEHOLDERS'         AS column_name,
  CAST(WAITTIME AS STRING)        AS value,
  COUNT(*)                        AS n,
  ROUND(COUNT(*) * 100.0
        / SUM(COUNT(*)) OVER (), 2) AS pct_of_total,
  'placeholder_hunt'              AS block
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
WHERE WAITTIME IN (-9, -8, -7, 99, 999, 9999)
GROUP BY WAITTIME

ORDER BY block, n DESC;

-- RESULTS:
-- BLOCK 1 — ARREMS arrival distribution
-- value  n       pct_of_total
-- 2      15,882  81.53%   (walk-in)
-- 1       3,068  15.75%   (ambulance)
-- -8        417   2.14%   (CDC: not applicable)
-- -9        114   0.59%   (CDC: blank / not stated)
--
-- BLOCK 2 — WAITTIME top-20 most frequent values
-- -9 is the single most frequent value at 2,648 rows (13.59%)
-- Legitimate values begin at rank 2: 4 min (733), 0 min (717), etc.
-- -7 appears at rank 10: 464 rows (2.38%)
--
-- BLOCK 3 — CDC placeholder hunt in WAITTIME
-- value  n       pct_of_placeholder_rows
-- -9     2,648   84.55%
-- -7       464   14.81%
-- 99        20    0.64%
-- Total placeholder rows: 3,132 (16.08% of 19,481)
-- -8, 999, and 9999 not present in WAITTIME


-- ============================================================
-- EDAOA | Step 2: Clean Universe Count
-- Goal    : Apply ARREMS and WAITTIME placeholder exclusions
--           simultaneously and confirm exact usable row count
-- Run date: June 10, 2026
-- ============================================================

SELECT
  COUNT(*)                        AS total_records,
  SUM(CASE WHEN ARREMS IN (-9, -8)
           THEN 1 ELSE 0 END)     AS arrems_excluded,
  SUM(CASE WHEN WAITTIME IN (-9, -7, 99)
           THEN 1 ELSE 0 END)     AS waittime_excluded,
  SUM(CASE WHEN ARREMS NOT IN (-9, -8)
            AND WAITTIME NOT IN (-9, -7, 99)
           THEN 1 ELSE 0 END)     AS clean_universe,
  ROUND(SUM(CASE WHEN ARREMS NOT IN (-9, -8)
                  AND WAITTIME NOT IN (-9, -7, 99)
                 THEN 1 ELSE 0 END) * 100.0
        / COUNT(*), 2)            AS clean_pct_of_total
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`;

-- RESULTS:
-- total_records      : 19,481
-- arrems_excluded    : 531     (ARREMS placeholders: -8 and -9)
-- waittime_excluded  : 3,132   (WAITTIME placeholders: -9, -7, 99)
-- clean_universe     : 16,036  (rows passing both exclusions)
-- clean_pct_of_total : 82.32%
-- NOTE: 313 rows had placeholder problems in both columns
-- simultaneously — overlap correctly handled by combined filter


-- ============================================================
-- EDAOA | Step 3: Triage Level (IMMEDR) Profile
-- Goal    : Profile IMMEDR distribution within the two-layer
--           clean universe to identify placeholder codes
--           requiring exclusion before the core contrast
-- Run date: June 10, 2026
-- ============================================================

SELECT
  IMMEDR                          AS triage_level,
  COUNT(*)                        AS n,
  ROUND(COUNT(*) * 100.0
        / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
WHERE ARREMS NOT IN (-9, -8)
  AND WAITTIME NOT IN (-9, -7, 99)
GROUP BY IMMEDR
ORDER BY IMMEDR;

-- RESULTS:
-- triage_level  n       pct_of_total
-- -9            347     2.16%    (CDC: blank / not stated)
-- -8            3,028   18.88%   (CDC: not applicable)
-- 0             536     3.34%    (CDC: no triage assigned)
-- 1             169     1.05%    (Immediate)
-- 2             1,562   9.74%    (Emergent)
-- 3             5,869   36.60%   (Urgent)
-- 4             3,452   21.53%   (Semi-urgent)
-- 5             460     2.87%    (Non-urgent)
-- 7             613     3.82%    (CDC: no triage performed)
--
-- Legitimate triage levels (1-5) : 11,512  71.79% of clean universe
-- Non-clinical codes (-9,-8,0,7) :  4,524  28.21% of clean universe
--
-- NOTE: Value 7 (no triage performed) may represent the strongest
-- form of the access override effect — patients routed entirely
-- around the triage system. Excluded from core contrast because
-- no severity comparator is available. Flagged for future analysis.


-- ============================================================
-- EDAOA | Step 4: Final Clean Universe Count
-- Goal    : Confirm exact row count after all three exclusion
--           layers are applied simultaneously
-- Run date: June 10, 2026
-- ============================================================

SELECT
  COUNT(*)                        AS clean_universe_final,
  ROUND(COUNT(*) * 100.0
        / 19481, 2)               AS pct_of_original
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
WHERE ARREMS NOT IN (-9, -8)
  AND WAITTIME NOT IN (-9, -7, 99)
  AND IMMEDR NOT IN (-9, -8, 0, 7);

-- RESULTS:
-- clean_universe_final  : 11,512  (rows surviving all three exclusion layers)
-- pct_of_original       : 59.09%  (share of original 19,481 records)
--
-- EXCLUSION SUMMARY:
-- Start                          : 19,481
-- After ARREMS + WAITTIME layers : 16,036  (Step 2)
-- After IMMEDR layer             : 11,512  (Step 4)
-- Total excluded                 :  7,969  (40.91%)
-- IMMEDR reduction of 4,524 rows primarily driven by
-- -8 (not applicable) at 3,028 rows


-- ============================================================
-- EDAOA | Step 4a: Schema Validation — Core Column Data Types
-- Goal    : Confirm data types of all core audit columns
--           before aggregate calculations in Step 5
-- Note    : Identified as necessary by lead analyst prior to
--           Step 5. Schema validation belongs logically after
--           Step 1 but was caught before any analysis integrity
--           was affected.
-- Run date: June 11, 2026
-- ============================================================

SELECT
  column_name,
  data_type
FROM `ed-clinical-throughput-audit.clinical_throughput`.INFORMATION_SCHEMA.COLUMNS
WHERE table_name = 'nhamcs_2019_raw'
  AND column_name IN ('ARREMS', 'WAITTIME', 'IMMEDR', 'LOV');

-- RESULTS:
-- column_name  data_type
-- WAITTIME     INT64
-- LOV          INT64
-- ARREMS       INT64
-- IMMEDR       INT64
--
-- All four core columns confirmed as INT64 (integer).
-- No casting required in Step 5 or any subsequent step.
-- CASE statements, AVG(), MIN(), MAX() execute cleanly.


-- ============================================================
-- EDAOA | Step 5: Core Contrast — Wait Time by Arrival Method
--         and Triage Level
-- Goal    : Cross-tabulate arrival method against triage level
--           with mean, min, and max wait time per cell to
--           surface the access override signal
-- Run date: June 10, 2026
-- ============================================================

SELECT
  CASE ARREMS
    WHEN 1 THEN 'Ambulance'
    WHEN 2 THEN 'Walk-in'
  END                             AS arrival_method,
  CASE IMMEDR
    WHEN 1 THEN '1 - Immediate'
    WHEN 2 THEN '2 - Emergent'
    WHEN 3 THEN '3 - Urgent'
    WHEN 4 THEN '4 - Semi-urgent'
    WHEN 5 THEN '5 - Non-urgent'
  END                             AS triage_level,
  COUNT(*)                        AS n,
  ROUND(AVG(WAITTIME), 1)         AS avg_wait_minutes,
  ROUND(MIN(WAITTIME), 1)         AS min_wait_minutes,
  ROUND(MAX(WAITTIME), 1)         AS max_wait_minutes
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
WHERE ARREMS NOT IN (-9, -8)
  AND WAITTIME NOT IN (-9, -7, 99)
  AND IMMEDR NOT IN (-9, -8, 0, 7)
GROUP BY ARREMS, IMMEDR
ORDER BY IMMEDR, ARREMS;

-- RESULTS:
-- arrival_method  triage_level      n      avg   min    max
-- Ambulance       1 - Immediate     89     22.3   0.0   291.0
-- Walk-in         1 - Immediate     80     52.2   0.0   596.0
-- Ambulance       2 - Emergent      526    31.5   0.0   991.0
-- Walk-in         2 - Emergent      1,036  37.0   0.0   783.0
-- Ambulance       3 - Urgent        1,032  36.1   0.0  1031.0
-- Walk-in         3 - Urgent        4,837  40.2   0.0  1440.0
-- Ambulance       4 - Semi-urgent   221    26.2   0.0   274.0
-- Walk-in         4 - Semi-urgent   3,231  34.0   0.0   878.0
-- Ambulance       5 - Non-urgent    38     20.6   0.0   105.0
-- Walk-in         5 - Non-urgent    422    38.2   0.0   746.0
--
-- KEY FINDING: Ambulance arrivals wait less than walk-ins at
-- every triage level without exception. Access override signal
-- confirmed. Gap ranges 4-30 minutes across triage levels.
-- Max wait times (up to 1,440 min) confirm outlier presence —
-- median analysis required in Step 6.


-- ============================================================
-- EDAOA | Step 6: Wait Time Distribution — Median and IQR
--         by Arrival Method and Triage Level
-- Goal    : Add median and IQR to core contrast to confirm
--           access override signal holds independent of
--           mean distortion by outliers
-- Note    : Two prior versions rejected:
--           Version 1 — PERCENTILE_CONT with GROUP BY expanded
--           output to one row per distinct WAITTIME value.
--           Version 2 — PERCENTILE_CONT with QUALIFY ROW_NUMBER
--           produced implausibly low medians due to window
--           function evaluating before full partition computed.
--           Final version uses APPROX_QUANTILES, a true
--           aggregate function, which resolves both issues.
-- Run date: June 11, 2026
-- ============================================================

SELECT
  CASE ARREMS
    WHEN 1 THEN 'Ambulance'
    WHEN 2 THEN 'Walk-in'
  END                                     AS arrival_method,
  CASE IMMEDR
    WHEN 1 THEN '1 - Immediate'
    WHEN 2 THEN '2 - Emergent'
    WHEN 3 THEN '3 - Urgent'
    WHEN 4 THEN '4 - Semi-urgent'
    WHEN 5 THEN '5 - Non-urgent'
  END                                     AS triage_level,
  COUNT(*)                                AS n,
  ROUND(AVG(WAITTIME), 1)                 AS avg_wait_minutes,
  APPROX_QUANTILES(WAITTIME, 4)[OFFSET(2)] AS median_wait_minutes,
  APPROX_QUANTILES(WAITTIME, 4)[OFFSET(1)] AS p25_wait_minutes,
  APPROX_QUANTILES(WAITTIME, 4)[OFFSET(3)] AS p75_wait_minutes
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
WHERE ARREMS NOT IN (-9, -8)
  AND WAITTIME NOT IN (-9, -7, 99)
  AND IMMEDR NOT IN (-9, -8, 0, 7)
GROUP BY ARREMS, IMMEDR
ORDER BY IMMEDR, ARREMS;

-- RESULTS:
-- arrival_method   triage_level      n      avg   median  p25  p75
-- Ambulance        1 - Immediate     89     22.3   6      2    15
-- Walk-in          1 - Immediate     80     52.2   13     4    40
-- Ambulance        2 - Emergent      526    31.5   9      3    25
-- Walk-in          2 - Emergent      1,036  37.0   14     5    37
-- Ambulance        3 - Urgent        1,032  36.1   10     4    28
-- Walk-in          3 - Urgent        4,837  40.2   15     6    42
-- Ambulance        4 - Semi-urgent   221    26.2   10     4    28
-- Walk-in          4 - Semi-urgent   3,231  34.0   16     6    40
-- Ambulance        5 - Non-urgent    38     20.6   11     4    28
-- Walk-in          5 - Non-urgent    422    38.2   17     6    41
--
-- MEDIAN GAP BY TRIAGE LEVEL:
-- 1 - Immediate  : -7 min  (6 vs 13)
-- 2 - Emergent   : -5 min  (9 vs 14)
-- 3 - Urgent     : -5 min  (10 vs 15)
-- 4 - Semi-urgent: -6 min  (10 vs 16)
-- 5 - Non-urgent : -6 min  (11 vs 17)
--
-- KEY FINDING: Access override holds in median across all five
-- triage levels. Gap is remarkably consistent at 5-7 minutes.
-- No triage level eliminates the arrival method advantage.
-- Median is the lead statistic — means distorted by outliers.


-- ============================================================
-- EDAOA | Step 7: ARRTIME and VDAYR Profile
-- Goal    : Profile arrival time and day of week distributions
--           within the clean universe to confirm format, check
--           for placeholder codes, and establish bucketing
--           strategy before the contextual contrast
-- Run date: June 11, 2026
-- ============================================================

-- BLOCK 1 — ARRTIME top-20 most frequent values
SELECT
  'ARRTIME'                       AS column_name,
  ARRTIME                         AS value,
  COUNT(*)                        AS n,
  ROUND(COUNT(*) * 100.0
        / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
WHERE ARREMS NOT IN (-9, -8)
  AND WAITTIME NOT IN (-9, -7, 99)
  AND IMMEDR NOT IN (-9, -8, 0, 7)
GROUP BY ARRTIME
QUALIFY ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) <= 20

UNION ALL

-- BLOCK 2 — VDAYR full distribution
SELECT
  'VDAYR'                         AS column_name,
  VDAYR                           AS value,
  COUNT(*)                        AS n,
  ROUND(COUNT(*) * 100.0
        / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
WHERE ARREMS NOT IN (-9, -8)
  AND WAITTIME NOT IN (-9, -7, 99)
  AND IMMEDR NOT IN (-9, -8, 0, 7)
GROUP BY VDAYR

ORDER BY column_name, n DESC;

-- RESULTS:
-- ARRTIME — confirmed four-digit military time format
-- No placeholder codes in top-20. Distribution flat.
-- Bucketed into four operational bands for Step 8:
--   Overnight  0000-0559
--   Morning    0600-1159
--   Afternoon  1200-1759
--   Evening    1800-2359
--
-- VDAYR — 7 distinct values, no placeholder codes
-- value  n      pct      label
-- 2      1,814  15.76%   Monday    (highest — weekend spillover)
-- 3      1,699  14.76%   Tuesday
-- 6      1,660  14.42%   Friday
-- 5      1,641  14.25%   Thursday
-- 4      1,628  14.14%   Wednesday
-- 1      1,546  13.43%   Sunday
-- 7      1,524  13.24%   Saturday  (lowest)
-- CDC convention confirmed: 1=Sunday through 7=Saturday


-- ============================================================
-- EDAOA | Step 8: Contextual Contrast — Wait Time by Arrival
--         Method and Time of Day
-- Goal    : Test whether time of day amplifies or reduces the
--           arrival method wait time gap
-- Run date: June 11, 2026
-- ============================================================

SELECT
  CASE ARREMS
    WHEN 1 THEN 'Ambulance'
    WHEN 2 THEN 'Walk-in'
  END                                       AS arrival_method,
  CASE
    WHEN ARRTIME BETWEEN 0 AND 559
      THEN '1 - Overnight (0000-0559)'
    WHEN ARRTIME BETWEEN 600 AND 1159
      THEN '2 - Morning (0600-1159)'
    WHEN ARRTIME BETWEEN 1200 AND 1759
      THEN '3 - Afternoon (1200-1759)'
    WHEN ARRTIME BETWEEN 1800 AND 2359
      THEN '4 - Evening (1800-2359)'
  END                                       AS time_of_day,
  COUNT(*)                                  AS n,
  ROUND(AVG(WAITTIME), 1)                   AS avg_wait_minutes,
  APPROX_QUANTILES(WAITTIME, 4)[OFFSET(2)]  AS median_wait_minutes
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
WHERE ARREMS NOT IN (-9, -8)
  AND WAITTIME NOT IN (-9, -7, 99)
  AND IMMEDR NOT IN (-9, -8, 0, 7)
GROUP BY ARREMS, time_of_day
ORDER BY time_of_day, ARREMS;

-- RESULTS:
-- arrival_method  time_of_day                n      avg    median
-- Ambulance       1 - Overnight (0000-0559)  307    35.6   8
-- Walk-in         1 - Overnight (0000-0559)  967    37.1   12
-- Ambulance       2 - Morning (0600-1159)    427    27.5   8
-- Walk-in         2 - Morning (0600-1159)    2,525  31.6   14
-- Ambulance       3 - Afternoon (1200-1759)  629    33.5   12
-- Walk-in         3 - Afternoon (1200-1759)  3,259  41.2   16
-- Ambulance       4 - Evening (1800-2359)    543    34.2   9
-- Walk-in         4 - Evening (1800-2359)    2,855  39.5   17
--
-- MEDIAN GAP BY TIME OF DAY:
-- Overnight  : 4 min  (8 vs 12)   — narrowest gap
-- Morning    : 6 min  (8 vs 14)
-- Afternoon  : 4 min  (12 vs 16)
-- Evening    : 8 min  (9 vs 17)   — widest gap
--
-- KEY FINDING: Access override holds across all four time bands.
-- Gap is consistent rather than operationally driven — no single
-- time band eliminates the arrival method advantage.
-- Evening shows widest gap; overnight shows narrowest.


-- ============================================================
-- EDAOA | Step 9: Contextual Contrast — Wait Time by Arrival
--         Method and Day of Week
-- Goal    : Test whether day of week amplifies or reduces the
--           arrival method wait time gap
-- Run date: June 11, 2026
-- ============================================================

SELECT
  CASE ARREMS
    WHEN 1 THEN 'Ambulance'
    WHEN 2 THEN 'Walk-in'
  END                                       AS arrival_method,
  CASE VDAYR
    WHEN 1 THEN '1 - Sunday'
    WHEN 2 THEN '2 - Monday'
    WHEN 3 THEN '3 - Tuesday'
    WHEN 4 THEN '4 - Wednesday'
    WHEN 5 THEN '5 - Thursday'
    WHEN 6 THEN '6 - Friday'
    WHEN 7 THEN '7 - Saturday'
  END                                       AS day_of_week,
  COUNT(*)                                  AS n,
  ROUND(AVG(WAITTIME), 1)                   AS avg_wait_minutes,
  APPROX_QUANTILES(WAITTIME, 4)[OFFSET(2)]  AS median_wait_minutes
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
WHERE ARREMS NOT IN (-9, -8)
  AND WAITTIME NOT IN (-9, -7, 99)
  AND IMMEDR NOT IN (-9, -8, 0, 7)
GROUP BY ARREMS, VDAYR
ORDER BY VDAYR, ARREMS;

-- RESULTS:
-- arrival_method  day_of_week      n      avg    median
-- Ambulance       1 - Sunday       264    33.0   8
-- Walk-in         1 - Sunday       1,282  33.4   14
-- Ambulance       2 - Monday       282    30.2   9
-- Walk-in         2 - Monday       1,532  41.2   17
-- Ambulance       3 - Tuesday      297    29.6   11
-- Walk-in         3 - Tuesday      1,402  39.4   16
-- Ambulance       4 - Wednesday    266    36.5   9
-- Walk-in         4 - Wednesday    1,362  36.6   15
-- Ambulance       5 - Thursday     260    36.2   9
-- Walk-in         5 - Thursday     1,381  38.3   15
-- Ambulance       6 - Friday       271    30.1   11
-- Walk-in         6 - Friday       1,389  42.2   15
-- Ambulance       7 - Saturday     266    34.2   9
-- Walk-in         7 - Saturday     1,258  32.0   13
--
-- MEDIAN GAP BY DAY OF WEEK:
-- Sunday     : 6 min  (8 vs 14)
-- Monday     : 8 min  (9 vs 17)   — widest gap
-- Tuesday    : 5 min  (11 vs 16)
-- Wednesday  : 6 min  (9 vs 15)
-- Thursday   : 6 min  (9 vs 15)
-- Friday     : 4 min  (11 vs 15)  — narrowest gap
-- Saturday   : 4 min  (9 vs 13)   — narrowest gap
--
-- KEY FINDING: Access override holds every day of the week.
-- Monday widest gap — weekend spillover drives elevated
-- walk-in volume. Friday/Saturday narrowest gap.
-- Wednesday mean anomaly: ambulance 36.5 vs walk-in 36.6
-- (near-identical means, yet median shows 6-min gap) —
-- strongest illustration of why median is the correct
-- lead statistic.


-- ============================================================
-- EDAOA | Step 10: Alternative Severity Control — Pain Scale
-- Goal    : Test whether access override signal holds when
--           controlling for patient-reported pain score as a
--           second severity measure independent of clinician-
--           assigned triage level
-- Run date: June 11, 2026
-- ============================================================

SELECT
  CASE ARREMS
    WHEN 1 THEN 'Ambulance'
    WHEN 2 THEN 'Walk-in'
  END                                       AS arrival_method,
  PAINSCALE                                 AS pain_score,
  COUNT(*)                                  AS n,
  ROUND(AVG(WAITTIME), 1)                   AS avg_wait_minutes,
  APPROX_QUANTILES(WAITTIME, 4)[OFFSET(2)]  AS median_wait_minutes
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
WHERE ARREMS NOT IN (-9, -8)
  AND WAITTIME NOT IN (-9, -7, 99)
  AND IMMEDR NOT IN (-9, -8, 0, 7)
GROUP BY ARREMS, PAINSCALE
ORDER BY PAINSCALE, ARREMS;

-- RESULTS:
-- arrival_method  pain_score  n      avg    median
-- Ambulance       -9          19     8.8    4      (placeholder: blank)
-- Walk-in         -9          112    22.3   11     (placeholder: blank)
-- Ambulance       -8          435    33.1   11     (placeholder: not applicable)
-- Walk-in         -8          1,787  37.6   19     (placeholder: not applicable)
-- Ambulance       0           637    30.6   9
-- Walk-in         0           2,412  39.1   15
-- Ambulance       1           16     19.6   10
-- Walk-in         1           86     33.5   15
-- Ambulance       2           44     27.3   12
-- Walk-in         2           321    37.6   14
-- Ambulance       3           44     39.5   9
-- Walk-in         3           300    38.4   14
-- Ambulance       4           65     43.0   12
-- Walk-in         4           477    41.9   16
-- Ambulance       5           88     35.8   9
-- Walk-in         5           587    34.4   14
-- Ambulance       6           95     42.1   6
-- Walk-in         6           608    36.0   13
-- Ambulance       7           103    27.8   8
-- Walk-in         7           712    38.2   15
-- Ambulance       8           122    34.1   8
-- Walk-in         8           910    39.5   15
-- Ambulance       9           60     23.8   8
-- Walk-in         9           461    35.2   14
-- Ambulance       10          178    37.6   8
-- Walk-in         10          833    37.0   15
--
-- PLACEHOLDER CODES IN PAINSCALE:
-- -9 (blank): 131 rows total — excluded from contrast findings
-- -8 (not applicable): 2,222 rows total — excluded from contrast
--
-- MEDIAN GAP ACROSS PAIN SCORES 0-10:
-- Score 0  : -6 min  (9 vs 15)
-- Score 1  : -5 min  (10 vs 15)
-- Score 2  : -2 min  (12 vs 14) — narrowest gap
-- Score 3  : -5 min  (9 vs 14)
-- Score 4  : -4 min  (12 vs 16)
-- Score 5  : -5 min  (9 vs 14)
-- Score 6  : -7 min  (6 vs 13)
-- Score 7  : -7 min  (8 vs 15)
-- Score 8  : -7 min  (8 vs 15)
-- Score 9  : -6 min  (8 vs 14)
-- Score 10 : -7 min  (8 vs 15)
--
-- KEY FINDING: Access override holds at every pain level 0-10
-- without exception. Even at maximum reported pain (score 10)
-- ambulance median is 8 min vs walk-in 15 min.
-- METHODOLOGICAL SIGNIFICANCE: Pain score is patient-reported
-- at triage, independent of clinician knowledge of arrival
-- method. Access override holding on this measure neutralizes
-- the triage bias critique. Central finding confirmed by two
-- independent severity measures: clinician-assigned triage
-- level (IMMEDR) and patient-reported pain score (PAINSCALE).


-- ============================================================
-- EDAOA | Step 11: Alternative Explanation Test — Boarding
-- Goal    : Test whether ED boarding explains the walk-in wait
--           time disadvantage as an alternative to the access
--           override routing explanation
-- Note    : BOARDED column is a duration field in minutes,
--           not a binary flag. Profiled before contrast —
--           same Count First discipline throughout the audit.
--           -7 (not applicable) = not boarded = 89.32% of
--           clean universe. Boarding affects 986 rows (8.57%).
--           Ambiguity in initial profile required contrast
--           before any conclusion was drawn.
-- Run date: June 11, 2026
-- ============================================================

SELECT
  CASE ARREMS
    WHEN 1 THEN 'Ambulance'
    WHEN 2 THEN 'Walk-in'
  END                               AS arrival_method,
  CASE
    WHEN BOARDED = -7 THEN 'Not Boarded'
    WHEN BOARDED = -9 THEN 'Unknown'
    WHEN BOARDED = 0  THEN 'Boarded - 0 min'
    WHEN BOARDED > 0  THEN 'Boarded - >0 min'
  END                               AS boarding_status,
  COUNT(*)                          AS n,
  ROUND(COUNT(*) * 100.0
        / SUM(COUNT(*)) OVER
          (PARTITION BY ARREMS), 2) AS pct_of_arrival_method,
  ROUND(AVG(WAITTIME), 1)           AS avg_wait_minutes,
  APPROX_QUANTILES(WAITTIME, 4)
    [OFFSET(2)]                     AS median_wait_minutes
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
WHERE ARREMS NOT IN (-9, -8)
  AND WAITTIME NOT IN (-9, -7, 99)
  AND IMMEDR NOT IN (-9, -8, 0, 7)
GROUP BY ARREMS, boarding_status
ORDER BY arrival_method, boarding_status;

-- RESULTS:
-- arrival_method  boarding_status    n      pct    avg    median
-- Ambulance       Boarded - 0 min    117    6.14%  18.7   5
-- Ambulance       Boarded - >0 min   277    14.53% 26.2   11
-- Ambulance       Not Boarded        1,409  73.92% 35.7   9
-- Ambulance       Unknown            103    5.40%  25.5   10
-- Walk-in         Boarded - 0 min    160    1.67%  30.1   9
-- Walk-in         Boarded - >0 min   434    4.52%  39.1   21
-- Walk-in         Not Boarded        8,874  92.38% 37.8   15
-- Walk-in         Unknown            138    1.44%  37.4   12
--
-- BOARDING RATE COMPARISON:
-- Ambulance total boarded : 20.67% (394 of 1,906 rows)
-- Walk-in total boarded   :  6.19% (594 of 9,606 rows)
-- Ambulance boarded at 3x the rate of walk-ins
--
-- ALTERNATIVE EXPLANATION RESULT: NOT SUPPORTED
-- For boarding to explain the walk-in wait time disadvantage
-- walk-ins would need to be boarded at a higher rate.
-- The opposite is true. Ambulance arrivals carry a boarding
-- burden three times greater than walk-ins and still wait less.
--
-- THREE CONFIRMATIONS FROM THIS FINDING:
-- 1. Ambulance arrivals seen faster — core finding holds
-- 2. Higher boarding rate confirms ambulance arrivals are
--    genuinely sicker and admitted more frequently —
--    validates clinical logic of the access override
-- 3. Ambulance arrivals wait less despite higher boarding
--    burden — access override effect is strong enough to
--    survive a structural disadvantage
--
-- OPERATIONAL NOTE: Higher boarding rate means ambulance
-- arrivals consume ED resources longer on average. Relevant
-- to ED throughput and capacity planning discussions.
--
-- NOTE: Boarded walk-in median of 21 min is highest in the
-- table — when walk-ins are boarded the wait time impact is
-- more severe, possibly because walk-ins may still be in the
-- waiting area when boarding occurs.


-- ============================================================
-- EDAOA | Step 12: Regional Analysis — Wait Time by Arrival
--         Method and Census Region
-- Goal    : Test whether the access override signal holds
--           across all four US Census regions to confirm
--           national scope
-- Run date: June 11, 2026
-- ============================================================

SELECT
  CASE REGION
    WHEN 1 THEN '1 - Northeast'
    WHEN 2 THEN '2 - Midwest'
    WHEN 3 THEN '3 - South'
    WHEN 4 THEN '4 - West'
  END                                       AS region,
  CASE ARREMS
    WHEN 1 THEN 'Ambulance'
    WHEN 2 THEN 'Walk-in'
  END                                       AS arrival_method,
  COUNT(*)                                  AS n,
  ROUND(AVG(WAITTIME), 1)                   AS avg_wait_minutes,
  APPROX_QUANTILES(WAITTIME, 4)[OFFSET(2)]  AS median_wait_minutes
FROM `ed-clinical-throughput-audit.clinical_throughput.nhamcs_2019_raw`
WHERE ARREMS NOT IN (-9, -8)
  AND WAITTIME NOT IN (-9, -7, 99)
  AND IMMEDR NOT IN (-9, -8, 0, 7)
GROUP BY REGION, ARREMS
ORDER BY REGION, ARREMS;

-- RESULTS:
-- region          arrival_method  n      avg    median
-- 1 - Northeast   Ambulance       382    56.0   13
-- 1 - Northeast   Walk-in         2,000  56.3   26
-- 2 - Midwest     Ambulance       417    16.6   7
-- 2 - Midwest     Walk-in         2,419  32.1   14
-- 3 - South       Ambulance       755    30.2   9
-- 3 - South       Walk-in         3,414  33.0   12
-- 4 - West        Ambulance       352    32.0   12
-- 4 - West        Walk-in         1,773  33.7   15
--
-- MEDIAN GAP BY REGION:
-- Northeast : 13 min (13 vs 26) — largest gap
-- Midwest   :  7 min (7 vs 14)
-- South     :  3 min (9 vs 12)  — smallest gap
-- West      :  3 min (12 vs 15) — smallest gap
--
-- KEY FINDING: Access override holds in all four Census
-- regions. Finding is national in scope and cannot be
-- explained as a regional anomaly.
--
-- NORTHEAST ANOMALY: Largest gap at 13 min and highest
-- absolute wait times in the dataset for both arrival
-- methods. Mean vs median divergence most dramatic here —
-- ambulance mean 56.0 vs walk-in mean 56.3 nearly identical
-- while medians show 13-min gap. Strongest illustration in
-- the audit of why median is the correct lead statistic.
--
-- FOLLOW-UP: Is the Northeast gap driven by higher overall
-- ED congestion, different routing protocols, or regional
-- infrastructure? Cannot be determined from NHAMCS data.
-- Flagged for future research.

