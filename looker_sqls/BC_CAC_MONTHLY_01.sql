-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Name: BC_CAC_MONTHLY_01
-- Output: monthly CAC by channel + blended all_channels
--   - spend source: bc_marketing_marts.ads_daily_spend
--   - TRY + foreign currency first paid users included
--   - foreign currency payments are validated with TCMB forex_buying rate availability
--   - PREPAID excluded
--   - attribution = last eligible paid touch in the 30 days before first payment
--   - one channel attribution per user
--   - cac_tl remains NULL when spend exists but attributed users = 0

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

spend_raw AS (
  SELECT
    month,
    LOWER(TRIM(CAST(channel AS STRING))) AS raw_channel,
    spend_tl
  FROM `microgain-9f959.bc_marketing_marts.ads_daily_spend`
  CROSS JOIN params p
  WHERE month BETWEEN DATE_TRUNC(p.ds_start, MONTH)
                  AND DATE_TRUNC(p.ds_end, MONTH)
),

spend AS (
  SELECT
    month,
    CASE
      WHEN REGEXP_CONTAINS(raw_channel, r'google|adwords|gads|youtube') THEN 'google'
      WHEN REGEXP_CONTAINS(raw_channel, r'meta|facebook|instagram|fb|ig|paid_social|social') THEN 'meta'
      WHEN REGEXP_CONTAINS(raw_channel, r'tiktok|tik_tok') THEN 'tiktok'
      ELSE raw_channel
    END AS channel,
    SUM(spend_tl) AS spend_tl
  FROM spend_raw
  WHERE REGEXP_CONTAINS(
    raw_channel,
    r'google|adwords|gads|youtube|meta|facebook|instagram|fb|ig|paid_social|social|tiktok|tik_tok'
  )
  GROUP BY month, channel
),

date_bounds AS (
  SELECT
    MIN(month) AS min_month,
    MAX(month) AS max_month
  FROM spend
),

tcmb_rates AS (
  SELECT
    DATE(rate_date) AS rate_date,
    UPPER(currency_code) AS currency_code,
    SAFE_DIVIDE(CAST(forex_buying AS FLOAT64), NULLIF(CAST(unit AS FLOAT64), 0.0)) AS rate_to_try
  FROM `microgain-9f959.bc_t.tcmb_exchange_rates_raw`
  WHERE currency_code IS NOT NULL
    AND forex_buying IS NOT NULL
    AND unit IS NOT NULL
),

paid_payment_base AS (
  SELECT
    CAST(s.user_id AS STRING) AS user_id,
    DATE(s.created_at) AS payment_date,
    UPPER(TRIM(s.currency)) AS currency_code,
    SAFE_DIVIDE(CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64), 100.0) AS amount_original
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN date_bounds b
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND UPPER(TRIM(s.payment_option)) != 'PREPAID'
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 0
    AND DATE(s.created_at) <= LAST_DAY(b.max_month)
),

paid_payment_rate_candidates AS (
  SELECT
    p.*,
    r.rate_date AS matched_rate_date,
    r.rate_to_try,
    ROW_NUMBER() OVER (
      PARTITION BY
        p.user_id,
        p.payment_date,
        p.currency_code,
        CAST(p.amount_original AS STRING)
      ORDER BY r.rate_date DESC
    ) AS rate_rn
  FROM paid_payment_base p
  LEFT JOIN tcmb_rates r
    ON p.currency_code != 'TRY'
   AND r.currency_code = p.currency_code
   AND r.rate_date <= p.payment_date
),

paid_payments AS (
  SELECT
    user_id,
    payment_date,
    currency_code,
    amount_original,
    matched_rate_date,
    rate_to_try
  FROM paid_payment_rate_candidates
  WHERE currency_code = 'TRY'
     OR rate_rn = 1
),

first_paid AS (
  SELECT
    user_id,
    MIN(payment_date) AS first_paid_date
  FROM paid_payments
  WHERE currency_code = 'TRY'
     OR rate_to_try IS NOT NULL
  GROUP BY user_id
),

normalized_touches AS (
  SELECT
    CAST(g.user_id AS STRING) AS user_id,
    g.touch_date,
    LOWER(TRIM(CAST(g.source AS STRING))) AS source,
    LOWER(TRIM(CAST(g.medium AS STRING))) AS medium,
    LOWER(TRIM(COALESCE(CAST(g.campaign AS STRING), 'null'))) AS campaign,
    LOWER(TRIM(CAST(g.mapped_channel AS STRING))) AS mapped_channel,
    CASE
      WHEN REGEXP_CONTAINS(
        LOWER(TRIM(CONCAT(
          COALESCE(CAST(g.mapped_channel AS STRING), ''), ' ',
          COALESCE(CAST(g.source AS STRING), ''), ' ',
          COALESCE(CAST(g.medium AS STRING), ''), ' ',
          COALESCE(CAST(g.campaign AS STRING), '')
        ))),
        r'google|adwords|gads|youtube'
      ) THEN 'google'
      WHEN REGEXP_CONTAINS(
        LOWER(TRIM(CONCAT(
          COALESCE(CAST(g.mapped_channel AS STRING), ''), ' ',
          COALESCE(CAST(g.source AS STRING), ''), ' ',
          COALESCE(CAST(g.medium AS STRING), ''), ' ',
          COALESCE(CAST(g.campaign AS STRING), '')
        ))),
        r'meta|facebook|instagram|fb|ig|l\.instagram|m\.facebook|l\.facebook'
      ) THEN 'meta'
      WHEN REGEXP_CONTAINS(
        LOWER(TRIM(CONCAT(
          COALESCE(CAST(g.mapped_channel AS STRING), ''), ' ',
          COALESCE(CAST(g.source AS STRING), ''), ' ',
          COALESCE(CAST(g.medium AS STRING), ''), ' ',
          COALESCE(CAST(g.campaign AS STRING), '')
        ))),
        r'tiktok|tik_tok'
      ) THEN 'tiktok'
      ELSE NULL
    END AS channel
  FROM `microgain-9f959.bc_marketing_raw.ga4_first_non_direct_touch` g
  CROSS JOIN date_bounds b
  WHERE g.touch_date BETWEEN DATE_SUB(b.min_month, INTERVAL 30 DAY)
                         AND LAST_DAY(b.max_month)
),

last_touch_before_paid AS (
  SELECT
    fp.user_id,
    fp.first_paid_date,
    DATE_TRUNC(fp.first_paid_date, MONTH) AS month,
    t.touch_date,
    t.channel,
    t.source,
    t.medium,
    t.campaign,
    DATE_DIFF(fp.first_paid_date, t.touch_date, DAY) AS day_diff
  FROM first_paid fp
  JOIN normalized_touches t
    ON fp.user_id = t.user_id
  CROSS JOIN date_bounds b
  WHERE fp.first_paid_date BETWEEN b.min_month AND LAST_DAY(b.max_month)
    AND t.channel IN ('google', 'meta', 'tiktok')
    AND DATE_DIFF(fp.first_paid_date, t.touch_date, DAY) BETWEEN 0 AND 30
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY fp.user_id
    ORDER BY
      t.touch_date DESC,
      CASE WHEN t.medium IN ('cpc', 'cpa', 'paid', 'paid_social', 'search_cpc') THEN 1 ELSE 0 END DESC,
      t.channel
  ) = 1
),

attributed_paid_users AS (
  SELECT
    month,
    channel,
    COUNT(DISTINCT user_id) AS new_paid_users
  FROM last_touch_before_paid
  GROUP BY month, channel
),

debug_totals AS (
  SELECT
    DATE_TRUNC(first_paid_date, MONTH) AS month,
    COUNT(DISTINCT user_id) AS total_first_paid_users
  FROM first_paid
  CROSS JOIN date_bounds b
  WHERE first_paid_date BETWEEN b.min_month AND LAST_DAY(b.max_month)
  GROUP BY month
),

channel_results AS (
  SELECT
    'channel' AS channel_scope,
    1 AS sort_order,
    s.month,
    s.channel,
    s.spend_tl,
    COALESCE(a.new_paid_users, 0) AS new_paid_users,
    SAFE_DIVIDE(s.spend_tl, COALESCE(a.new_paid_users, 0)) AS cac_tl,
    d.total_first_paid_users,
    SAFE_DIVIDE(COALESCE(a.new_paid_users, 0), d.total_first_paid_users) AS attribution_coverage,
    CASE
      WHEN s.spend_tl > 0 AND COALESCE(a.new_paid_users, 0) > 0 THEN 'ok'
      WHEN s.spend_tl > 0 AND COALESCE(a.new_paid_users, 0) = 0 THEN 'spend_var_user_yok'
      WHEN s.spend_tl = 0 AND COALESCE(a.new_paid_users, 0) > 0 THEN 'spend_yok_user_var'
      ELSE 'spend_yok_user_yok'
    END AS cac_status
  FROM spend s
  LEFT JOIN attributed_paid_users a
    ON s.month = a.month
   AND s.channel = a.channel
  LEFT JOIN debug_totals d
    ON s.month = d.month
),

all_channels_results AS (
  SELECT
    'all_channels' AS channel_scope,
    99 AS sort_order,
    s.month,
    'all_channels' AS channel,
    SUM(s.spend_tl) AS spend_tl,
    SUM(COALESCE(a.new_paid_users, 0)) AS new_paid_users,
    SAFE_DIVIDE(SUM(s.spend_tl), SUM(COALESCE(a.new_paid_users, 0))) AS cac_tl,
    ANY_VALUE(d.total_first_paid_users) AS total_first_paid_users,
    SAFE_DIVIDE(SUM(COALESCE(a.new_paid_users, 0)), ANY_VALUE(d.total_first_paid_users)) AS attribution_coverage,
    CASE
      WHEN SUM(s.spend_tl) > 0 AND SUM(COALESCE(a.new_paid_users, 0)) > 0 THEN 'ok'
      WHEN SUM(s.spend_tl) > 0 AND SUM(COALESCE(a.new_paid_users, 0)) = 0 THEN 'spend_var_user_yok'
      WHEN SUM(s.spend_tl) = 0 AND SUM(COALESCE(a.new_paid_users, 0)) > 0 THEN 'spend_yok_user_var'
      ELSE 'spend_yok_user_yok'
    END AS cac_status
  FROM spend s
  LEFT JOIN attributed_paid_users a
    ON s.month = a.month
   AND s.channel = a.channel
  LEFT JOIN debug_totals d
    ON s.month = d.month
  GROUP BY s.month
)

SELECT *
FROM channel_results

UNION ALL

SELECT *
FROM all_channels_results

ORDER BY month, sort_order, channel;
