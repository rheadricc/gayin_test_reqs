# agent_log.md — GAİN BigQuery & Analytics Documentation v0.5 Handoff

## Current document

Active document produced in this pass:

`GAİN BigQuery & Analytics Technical Documentation v0.5`

Source baseline:

`GAİN BigQuery & Analytics Technical Documentation v0.4`

Primary generated files:

- `gain_bigquery_analytics_technical_documentation_v0_5.md`
- `agent_log_v0_5.md`

## Purpose of this handoff

This handoff explains the decisions, edits, and business logic finalized while moving the documentation from v0.4 to v0.5. It is intended for another AI agent, analyst, or developer who may need to continue editing the documentation without requiring the full chat history.

## User intent

The user wanted v0.4 to be used as the baseline, not a new isolated draft. The expected workflow was:

1. Preserve the existing v0.4 document body.
2. Remove the duplicate legacy fragments at the bottom.
3. Add the newly agreed v0.5 sections.
4. Renumber the affected sections.
5. Produce a clean v0.5 documentation file and a separate agent log.

## Critical correction from v0.4

The v0.4 snapshot contained a duplicate legacy fragment after:

`## 9.10 Looker Mapping Özeti`

The duplicate fragment started with:

- `## Sayfa 1 — Kullanıcı Raporları`
- `## Sayfa 2 — İçerik Genel Durum / Performans ve İzlenme`

This duplicate fragment was removed in v0.5.

Important: the real Looker mapping section must be preserved. The valid Looker mapping block is now under:

- `## 11. Looker Studio Dashboard Mapping`
- `## 11.1 Sayfa 1 — Kullanıcı Raporları`
- ...
- `## 11.10 Looker Mapping Özeti`

Only the unnumbered duplicate block after the old 9.10 summary should be removed.

## v0.5 structural changes

The document was reorganized as follows:

Old structure around the lower sections:

```text
8. Airflow DAG Inventory
8.1 Ara Toparlama — Pipeline ve Veri Akışının Okunması
9. Looker Studio Dashboard Mapping
9.1 ...
9.10 Looker Mapping Özeti
[duplicate Sayfa 1 / Sayfa 2 fragment]
```

New structure:

```text
8. Airflow DAG Inventory
8.1 Ara Toparlama — Pipeline ve Veri Akışının Okunması
9. Business Definitions
10. Promotion Conversion Logic
11. Looker Studio Dashboard Mapping
11.1 ...
11.10 Looker Mapping Özeti
12. Ownership Matrix
```

## Added section: 9. Business Definitions

The user chose the concise technical format, referred to during discussion as “Option A.” Each definition uses:

- Tanım
- Kaynak
- Business Logic
- Notlar

Definitions added:

1. Active Subscriber
2. Paid Subscriber
3. Trial User
4. New Paid User
5. Churn User
6. Grace User
7. Promotion User
8. Prepaid User

### Business definition principles

- Active subscriber should primarily rely on `valid_until`, not `created_at`.
- A canceled user may still be considered active while entitlement continues.
- Trial users are not paid subscribers.
- New paid user refers to first paid payment in the reporting period.
- PREPAID users are generally excluded from CAC, LTV, and unit economics calculations.
- Grace users should not be treated directly as churn; they are tracked separately.
- Promotion users are identified through `subs_payment.applied_promotions` and enriched through `Backoffice_metadata.bo_promotions`.

## Added section: 10. Promotion Conversion Logic

The user confirmed the following official promotion conversion definition as correct:

```text
Promotion User
↓
Promotion süresi sona erer
↓
Sonraki ödeme yapılır
↓
amount = amount_before_promotions
↓
aynı promotion tekrar kullanılmaz
↓
Conversion
```

### Promotion conversion logic details

A user should be counted as conversion only if:

1. The user previously used the relevant promotion.
2. The promotion period ended.
3. A subsequent payment exists.
4. The subsequent payment is full-price.
5. Full-price is validated with `amount = amount_before_promotions`.
6. The subsequent payment does not carry the same `promotionId` again.

### Exclusions

Do not count as conversion when:

- The user only used the promotion and never paid afterward.
- The next payment still carries the same promotion.
- The next payment is discounted.
- `amount` and `amount_before_promotions` are not equal.
- The user continues through PREPAID / gift / bundle / non-revenue mechanics.
- The payment is invalid, canceled, refunded, or otherwise not revenue-relevant.

## Added CAC attribution note

The user did not want a long separate Attribution chapter. Instead, a short note was added to the first practical CAC/spend source section, under `bc_marketing_marts.ads_daily_spend`.

Final note concept:

`Last Eligible Non-Direct Touch, 30 Day Window`

Meaning:

- CAC channel attribution is determined by the last eligible non-direct touch before the first paid payment.
- The lookback window is 30 days before first paid payment.
- Direct traffic is excluded from attribution.
- If multiple eligible touches exist, the latest eligible paid/non-direct touch is used.
- Current `ga4_first_non_direct_touch` data may not be raw touch-level data, so the current implementation should be treated as available-data best effort.
- Future state remains a dedicated mart such as `bc_marketing_marts.ga4_last_paid_touch_30d`.

## Data Lineage decision

A separate Data Lineage section was discussed but deliberately not added.

Reason:

- Existing sections already cover dataset inventory, scheduled query inventory, and Looker KPI-to-SQL mapping.
- Section 6.3 Unified Spend Flow already explains the one place where lineage was especially necessary because Google and Meta raw spend sources merge into `ads_daily_spend`.
- Adding a generic Data Lineage chapter would create duplication without enough additional value.

If future editors want to add lineage, the preferred location would be between the pipeline summary and Looker mapping, but this was not part of v0.5.

## Elastic vs subs_payment migration decision

A larger Elastic migration history section was discussed but not added.

Reason:

- The existing `elastic_active_user` table description already explains the essential point: some users may exist in Elastic but be missing from `subs_payment`, so Elastic remains a supporting source in some analyses.
- Full migration history is not necessary for a new analyst unless they are debugging migration-specific edge cases.

## Known Caveats decision

A separate expanded Known Caveats section was discussed but not added.

Reason:

- The caveats already live near the relevant tables and metrics.
- Creating a separate caveats section would duplicate information and increase the risk of stale conflicting definitions.

Important caveats remain distributed in context:

- `amount` and `amount_before_promotions` are minor units / kuruş.
- Financial KPI usage usually filters `currency = 'TRY'`.
- PREPAID is excluded from most unit economics calculations.
- `created_at` should not be the only subscription cycle anchor.
- `valid_until` is the preferred entitlement/active-period anchor.
- Elastic can be used as a fallback/supporting source for some legacy gaps.

## Airflow DAG Inventory update

The Airflow inventory was expanded to include near-term/live-assumed pipelines. The user explicitly wanted these to be documented as active because they were expected to be live within days.

Rows added:

- `Prod_Gain_Apple_Subscription_Status_To_Bq_Dag`
- `Prod_Gain_Google_Play_Sales_Report_To_Bq_Dag`
- `Prod_Gain_Iyzico_Transaction_To_Bq_Dag`
- `Prod_Gain_Param_Transaction_To_Bq_Dag`
- `Prod_Gain_TCMB_FX_Rates_To_Bq_Dag`
- `Prod_Gain_Kids_Profile_Counter_To_Bq_Dag`

Each was described as daily schedule in the same inventory style as the existing DAG table.

If exact Airflow cron strings become necessary later, they should be verified from Airflow DAG code or MWAA UI. v0.5 intentionally keeps the documentation at the same abstraction level as the existing DAG inventory.

## Added section: 12. Ownership Matrix

The user requested owner + vendor information. Vendor values are intentionally draft placeholders where exact company/vendor was not finalized.

Columns:

- Sistem / Kaynak
- Owner Team
- Vendor / Platform

Included systems:

- Backoffice Metadata
- Backoffice API
- REST / Core Services
- Mobile Applications
- Web Application
- Payment Systems
- AWS S3 Data Lake / Staging
- Airflow / MWAA
- BigQuery
- Looker Studio Dashboards
- Google Ads Transfer
- Meta Ads Transfer
- GA4 / Firebase Analytics
- Mux
- Insider Operational Outputs
- Adjust
- Apple App Store Subscription Data
- Google Play Subscription / Sales Data
- Iyzico Transaction Data
- Param Transaction Data
- TCMB FX Rates
- Kids Profile Counter Outputs
- Redshift Legacy Warehouse
- Superset Legacy / Ad-hoc Reporting

The user plans to edit vendor names later.

## Preserve these decisions

Future agents should preserve the following unless the user explicitly changes direction:

- Do not re-add the duplicate unnumbered `Sayfa 1` / `Sayfa 2` blocks.
- Do not create a separate Data Lineage chapter unless the user asks.
- Do not create a long Attribution chapter; keep CAC attribution as a short note.
- Do not expand Elastic migration history unless needed for debugging.
- Do not create a duplicated Known Caveats section; keep caveats close to relevant tables/metrics.
- Keep Looker mapping under section 11 unless a future version changes the broader structure.
- Treat Business Definitions and Promotion Conversion Logic as central reference sections.

## User preference notes

- The user wants direct technical documentation, not over-explained non-technical writing.
- The user strongly prefers concrete edits over repeated planning.
- The documentation should be useful for a new analyst/developer joining GAİN.
- Avoid splitting the task into unnecessary sub-steps when the agreed scope is already clear.
- Preserve existing content unless the user explicitly says to remove it.

## Final v0.5 content status

Implemented:

- v0.5 title and change summary
- duplicate legacy fragment removal
- CAC attribution note
- Airflow DAG inventory extension
- Business Definitions section
- Promotion Conversion Logic section
- Looker mapping renumbering to 11.x
- Ownership Matrix section

Not implemented by design:

- separate Data Lineage chapter
- separate Elastic migration chapter
- separate Attribution chapter
- expanded standalone Known Caveats section
