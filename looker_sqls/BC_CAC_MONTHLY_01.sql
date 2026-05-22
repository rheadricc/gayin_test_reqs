-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- New name: BC_CAC_MONTHLY_01
-- Output: monthly CAC by channel + blended all_channels
-- Logic:
--   - TRY-only first paid users
--   - PREPAID excluded
--   - 30-day attribution window

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

spend AS (
  SELECT
    month,
    LOWER(channel) AS channel,
    SUM(spend_tl) AS spend_tl
  FROM `microgain-9f959.bc_marketing_raw.manual_monthly_spend`
  CROSS JOIN params p
  WHERE LOWER(channel) IN ('google', 'meta', 'tiktok')
    AND month BETWEEN DATE_TRUNC(p.ds_start, MONTH) AND DATE_TRUNC(p.ds_end, MONTH)
  GROUP BY month, channel
),

date_bounds AS (
  SELECT
    MIN(month) AS min_month,
    MAX(month) AS max_month
  FROM spend
),

first_paid AS (
  SELECT
    user_id,
    MIN(DATE(created_at)) AS first_paid_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE user_id IS NOT NULL
    AND payment_option IS NOT NULL
    AND payment_option != 'PREPAID'
    AND amount > 0
    AND UPPER(currency) = 'TRY'
  GROUP BY user_id
),

attributed_paid_users AS (
  SELECT
    DATE_TRUNC(fp.first_paid_date, MONTH) AS month,
    g.mapped_channel AS channel,
    COUNT(DISTINCT fp.user_id) AS new_paid_users
  FROM first_paid fp
  JOIN `microgain-9f959.bc_marketing_raw.ga4_first_non_direct_touch` g
    ON fp.user_id = g.user_id
  CROSS JOIN date_bounds b
  WHERE fp.first_paid_date BETWEEN b.min_month AND LAST_DAY(b.max_month)
    AND DATE_DIFF(fp.first_paid_date, g.touch_date, DAY) BETWEEN 0 AND 30
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
    SAFE_DIVIDE(COALESCE(a.new_paid_users, 0), d.total_first_paid_users) AS attribution_coverage
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
    SAFE_DIVIDE(SUM(COALESCE(a.new_paid_users, 0)), ANY_VALUE(d.total_first_paid_users)) AS attribution_coverage
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