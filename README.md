# Emergency Department Arrival Study
### Does arrival method determine how quickly you're seen in the ER — independent of clinical severity?

---

## The Question

Everyone has heard the advice: go by ambulance and you'll get seen faster in the ER. Hospital systems and EMS agencies push back on this. Their official position is that triage determines wait time — clinical severity determines who gets seen first, not how you arrived.

This audit tested that claim against a nationally representative federal dataset of 19,481 emergency department visits from 2019. One of these positions is supported by the data. One is not.

---

## Key Findings

- **The Access Override is Real** — Ambulance arrivals wait less than walk-in arrivals at every triage level without exception. The median gap runs 5–7 minutes across all five severity classifications.
- **Triage Doesn't Close the Gap** — At triage level 1 (Immediate — life-threatening), ambulance arrivals wait a median of 6 minutes. Walk-in arrivals classified at the same severity wait 13 minutes. Clinical severity does not explain the difference.
- **Two Severity Measures, Same Result** — Pain score is patient-reported at triage, independent of clinician knowledge of arrival method. The access override holds at every pain level from 0 to 10. Two independent severity measures confirm the same signal.
- **Boarding Rules It Out** — Ambulance arrivals are boarded at 20.67% — more than three times the walk-in rate of 6.19%. They carry a greater structural burden and still wait less. The alternative explanation fails and strengthens the finding.
- **National Scope** — The gap holds in all four US Census regions. Northeast (13 min), Midwest (7 min), South (3 min), West (3 min). No region eliminates the advantage.
- **The Mean Almost Hid It** — In the Northeast, ambulance and walk-in means are nearly identical (56.0 vs. 56.3 min). The medians show a 13-minute gap. This is why median is the lead statistic throughout.

---

## Why This Matters

The official messaging from EMS agencies and hospital systems telling the public that ambulance arrival does not confer a wait time advantage is not supported by 2019 federal data. A publicly held belief was tested. The belief was confirmed.

---

## Methodology Confidence

The finding was tested against every reasonable alternative explanation before a conclusion was drawn.

| Test | Result |
|------|--------|
| Triage level control (5 levels) | Gap holds at every level |
| Patient-reported pain score (0–10) | Gap holds at every pain level |
| Time of day (4 bands) | Gap holds across all bands |
| Day of week (7 days) | Gap holds every day |
| ED boarding analysis | Alternative explanation ruled out |
| US Census region (4 regions) | Gap holds nationally |

All SQL findings independently reproduced in Python against the raw CSV. 20-checkpoint scorecard — all PASS.

---

## Tools & Methods

- **SQL / BigQuery** — Forensic data analysis across 11,512 clean ER visit records drawn from 19,481 total
- **Python / pandas** — Full replication of all SQL findings from the raw CSV, demonstrating cross-platform reproducibility using equivalent logic
- **Tableau Public** — Dashboard with five analytical assets visualizing the access override signal, boarding inversion, regional scope, and pain scale confirmation
- **Documentation** — Data dictionary, validation report, executive summary, and presentation script

---

## Repository Contents

| File | Description |
|------|-------------|
| `04_EDAOA_Master_StepByStep.sql` | Forensic workbench — all twelve analytical steps executed sequentially with inline results documented |
| `04_EDAOA_Production_CTE.sql` | Production architecture — single coherent CTE chain covering all analytical dimensions, independently queryable |
| `05_EDAOA_Python_Cross_Platform.ipynb` | Python cross-platform reproducibility layer — all findings confirmed from the raw CSV using equivalent logic |
| `08_EDAOA_Executive_Summary.md` | Plain language findings document — the complete audit argument written for a general audience |

---

## Project Deliverables

- 📊 **Tableau Dashboard** — [Emergency Department Arrival Study](https://public.tableau.com/views/EDAOA_Dashboard/Dashboard1?:language=en-US&:sid=&:redirect=auth&:display_count=n&:origin=viz_share_link)
- 🐍 **Python Notebook** —  *(link to be added upon public release)*

---

## About

**Lead Analyst:** Robert Hoye-Logan
**Dataset:** NHAMCS 2019 Emergency Department Public Use File — 19,481 records representing a nationally representative sample of US emergency department visits during calendar year 2019
**Dataset Source:** [CDC National Center for Health Statistics — NHAMCS](https://www.cdc.gov/nchs/ahcd/ahcd_questionnaires.htm) — Originally distributed in Stata format (.dta), converted to CSV using Python and pandas prior to analysis
**Analysis Date:** June 2026

---

*A publicly held belief was tested against federal data. The belief was confirmed. The official messaging telling people otherwise is not supported by the data.*
