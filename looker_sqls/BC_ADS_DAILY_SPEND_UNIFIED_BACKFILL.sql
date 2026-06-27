-- ONE-OFF BACKFILL
-- Name: BC_ADS_DAILY_SPEND_UNIFIED_BACKFILL
--
-- Run only after the Google Ads and Meta Ads raw transfer runs for the
-- requested period have completed. The MERGE key makes reruns idempotent:
-- day + channel + account + campaign + source table.

DECLARE backfill_start DATE DEFAULT DATE '2025-07-01';
DECLARE backfill_end DATE DEFAULT DATE_SUB(
  CURRENT_DATE('Europe/Istanbul'),
  INTERVAL 1 DAY
);

CREATE TABLE IF NOT EXISTS `microgain-9f959.bc_marketing_marts.ads_daily_spend` (
  day DATE,
  month DATE,
  channel STRING,
  source_platform STRING,
  account_id STRING,
  account_name STRING,
  campaign_id STRING,
  campaign_name STRING,
  currency STRING,
  spend_tl FLOAT64,
  source_table STRING,
  loaded_at TIMESTAMP
);

MERGE `microgain-9f959.bc_marketing_marts.ads_daily_spend` AS T
USING (
  WITH google_spend AS (
    SELECT
      segments_date AS day,
      DATE_TRUNC(segments_date, MONTH) AS month,
      'google' AS channel,
      'google_ads' AS source_platform,
      CAST(customer_id AS STRING) AS account_id,
      CAST(NULL AS STRING) AS account_name,
      CAST(campaign_id AS STRING) AS campaign_id,
      CAST(NULL AS STRING) AS campaign_name,
      'TRY' AS currency,
      SUM(metrics_cost_micros) / 1000000.0 AS spend_tl,
      'p_ads_CampaignBasicStats_6861382209' AS source_table,
      CURRENT_TIMESTAMP() AS loaded_at
    FROM `microgain-9f959.bc_googleads_spend_raw.p_ads_CampaignBasicStats_6861382209`
    WHERE segments_date BETWEEN backfill_start AND backfill_end
    GROUP BY
      day, month, channel, source_platform,
      account_id, account_name, campaign_id, campaign_name,
      currency, source_table
  ),

  meta_spend AS (
    SELECT
      DateStart AS day,
      DATE_TRUNC(DateStart, MONTH) AS month,
      'meta' AS channel,
      'meta_ads' AS source_platform,
      CAST(AdAccountId AS STRING) AS account_id,
      CAST(AdAccountName AS STRING) AS account_name,
      CAST(CampaignId AS STRING) AS campaign_id,
      CAST(CampaignName AS STRING) AS campaign_name,
      UPPER(AccountCurrency) AS currency,
      SUM(CAST(Spend AS FLOAT64)) AS spend_tl,
      'AdInsights' AS source_table,
      CURRENT_TIMESTAMP() AS loaded_at
    FROM `microgain-9f959.bc_meta_spend_raw.AdInsights`
    WHERE DateStart BETWEEN backfill_start AND backfill_end
      AND UPPER(AccountCurrency) = 'TRY'
    GROUP BY
      day, month, channel, source_platform,
      account_id, account_name, campaign_id, campaign_name,
      currency, source_table
  )

  SELECT * FROM google_spend
  UNION ALL
  SELECT * FROM meta_spend
) AS S
ON  T.day = S.day
AND T.channel = S.channel
AND COALESCE(T.account_id, '') = COALESCE(S.account_id, '')
AND COALESCE(T.campaign_id, '') = COALESCE(S.campaign_id, '')
AND COALESCE(T.source_table, '') = COALESCE(S.source_table, '')

WHEN MATCHED THEN UPDATE SET
  T.month = S.month,
  T.source_platform = S.source_platform,
  T.account_name = S.account_name,
  T.campaign_name = S.campaign_name,
  T.currency = S.currency,
  T.spend_tl = S.spend_tl,
  T.loaded_at = S.loaded_at

WHEN NOT MATCHED THEN INSERT (
  day,
  month,
  channel,
  source_platform,
  account_id,
  account_name,
  campaign_id,
  campaign_name,
  currency,
  spend_tl,
  source_table,
  loaded_at
) VALUES (
  S.day,
  S.month,
  S.channel,
  S.source_platform,
  S.account_id,
  S.account_name,
  S.campaign_id,
  S.campaign_name,
  S.currency,
  S.spend_tl,
  S.source_table,
  S.loaded_at
);
