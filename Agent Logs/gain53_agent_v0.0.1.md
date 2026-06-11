# agent.md — GAİN BigQuery & Analytics Documentation Handoff

## Current state

This handoff preserves the current canvas/document snapshot as requested by the user. The document title is:

`GAİN BigQuery & Analytics Technical Documentation v0.4`

The current canvas state intentionally includes the main Looker mapping section (`9.1` through `9.10`) and also retains a duplicated legacy fragment at the bottom beginning with:

- `## Sayfa 1 — Kullanıcı Raporları`
- `## Sayfa 2 — İçerik Genel Durum / Performans ve İzlenme`

The user asked to save this version before further edits because prior canvas operations accidentally deleted needed content.

## Files created

- `gain_bigquery_analytics_technical_documentation_v0_4.md`
- `gain_bigquery_analytics_technical_documentation_v0_4.docx`
- `gain_bigquery_analytics_technical_documentation_v0_4.pdf`
- `agent.md`

## Most important context

The document explains GAİN's BigQuery / Analytics data architecture, including:

1. Purpose and scope of the documentation.
2. High-level hybrid data architecture with client, REST/Core, 3rd party, processing, BigQuery/DWH, and visualization layers.
3. BigQuery dataset inventory.
4. Critical table catalog.
5. Data Transfer jobs.
6. BigQuery Scheduled Query inventory.
7. Airflow DAG inventory.
8. Pipeline/data-flow summary.
9. Looker Studio Dashboard Mapping.
10. KPI definitions and downstream caveats.

## Architecture logic to preserve

The most important architecture diagram logic is:

- Client applications generate two outputs:
  - Operational/raw stream to REST/Core.
  - Analytics/engagement stream to 3rd party platforms.
- REST/Core stream path:
  - REST/Core → Kinesis → Lambda → AWS S3.
- 3rd party analytics stream path:
  - 3rd Party → Kinesis → AWS S3.
- AWS S3 then feeds Airflow / Python jobs / BigQuery Scheduled Queries.
- BigQuery is the primary current data warehouse.
- Redshift is legacy/secondary.
- Looker Studio is the primary dashboarding layer.

## CAC / spend current state

The documentation has been updated to reflect that:

- `bc_marketing_marts.ads_daily_spend` is the active primary spend source.
- `bc_googleads_spend_raw` and `bc_meta_spend_raw` actively receive data.
- `BC_ADS_DAILY_SPEND_UNIFIED_01` normalizes raw Google/Meta spend into `ads_daily_spend`.
- `bc_marketing_raw.manual_monthly_spend` is legacy/historical fallback.

## Known issue to handle in the next editing pass

The current v0.4 snapshot has a duplicated legacy fragment after `9.10 Looker Mapping Özeti`. If the user asks to clean the document, remove only the duplicate fragment below `9.10`, starting from:

`## Sayfa 1 — Kullanıcı Raporları`

and continuing through the truncated duplicate `## Sayfa 2 — İçerik Genel Durum / Performans ve İzlenme` section.

Do not remove the main `9.1`–`9.10` sections.

## User preference

The user wants technical detail and does not want the documentation to be written for non-technical readers. The tone should be practical, direct, and clear for analysts/developers.
