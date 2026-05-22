-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- New name: BC_CHANNEL_LTVCAC_REALIZED_01
-- Output:
--   1) channel_scope = 'selected_period'  -> one row per channel for selected range
--   2) channel_scope = 'monthly'          -> one row per month per channel
-- Logic:
--   - acquisition cohort = first paid users in selected range
--   - attribution = last non-direct touch within 30 days before first paid
--   - LTV = TRY-only realized net revenue up to ds_end
--   - CAC = spend / new paid users
--   - Ratio = avg realized LTV / CAC

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

/* =========================================
   PAYMENT CONFIG
   ========================================= */

payment_option_config AS (
  SELECT 'APP_STORE'       AS payment_option, 0.30 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'PLAY_STORE'      AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'MOBILE_PAYMENT'  AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'CRAFTGATE'       AS payment_option, 0.00 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'IYZICO'          AS payment_option, 0.03 AS commission_rate, 0.20 AS tax_rate
),

/* =========================================
   REALIZED LTV BASE (TRY-only, PREPAID excluded)
   ========================================= */

history_start AS (
  SELECT
    MIN(DATE(created_at)) AS hist_start
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE user_id IS NOT NULL
    AND payment_option IS NOT NULL
    AND payment_option != 'PREPAID'
    AND UPPER(currency) = 'TRY'
),

ltv_subs AS (
  SELECT
    s.user_id,
    s.status,
    s.payment_option,
    s.created_at,
    s.inserted_date,
    DATE(s.created_at)  AS created_date,
    DATE(s.valid_until) AS valid_until_date,
    DATE(s.grace_until) AS grace_until_date,
    DATE(s.hold_until)  AS hold_until_date,
    CASE
      WHEN s.status = 'ON_HOLD'  THEN COALESCE(DATE(s.hold_until),  DATE(s.valid_until))
      WHEN s.status = 'IN_GRACE' THEN COALESCE(DATE(s.grace_until), DATE(s.valid_until))
      ELSE DATE(s.valid_until)
    END AS active_end_date,
    CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64) AS amount_minor
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN params p
  CROSS JOIN history_start h
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND s.payment_option != 'PREPAID'
    AND s.status IN ('ACTIVE', 'IN_GRACE', 'ON_HOLD')
    AND UPPER(s.currency) = 'TRY'
    AND DATE(s.created_at) <= p.ds_end
    AND DATE(
      CASE
        WHEN s.status = 'ON_HOLD'  THEN COALESCE(s.hold_until,  s.valid_until)
        WHEN s.status = 'IN_GRACE' THEN COALESCE(s.grace_until, s.valid_until)
        ELSE s.valid_until
      END
    ) >= h.hist_start
),

ltv_days AS (
  SELECT d AS dt
  FROM params p
  CROSS JOIN history_start h
  CROSS JOIN UNNEST(GENERATE_DATE_ARRAY(h.hist_start, p.ds_end)) AS d
),

ltv_daily_active_raw AS (
  SELECT
    d.dt,
    s.user_id,
    s.payment_option,
    s.amount_minor,
    s.created_at,
    s.inserted_date
  FROM ltv_days d
  JOIN ltv_subs s
    ON d.dt BETWEEN s.created_date AND s.active_end_date
),

ltv_daily_active_dedup AS (
  SELECT
    r.dt,
    r.user_id,
    r.payment_option,
    r.amount_minor
  FROM (
    SELECT
      r.*,
      ROW_NUMBER() OVER (
        PARTITION BY r.dt, r.user_id
        ORDER BY r.created_at DESC, r.inserted_date DESC
      ) AS rn
    FROM ltv_daily_active_raw r
  ) r
  WHERE r.rn = 1
),

daily_user_revenue AS (
  SELECT
    a.dt,
    a.user_id,
    SAFE_DIVIDE(
      SAFE_DIVIDE(a.amount_minor, 100.0)
      * ((1.0 - COALESCE(c.commission_rate, 0.00)) * (1.0 - COALESCE(c.tax_rate, 0.20))),
      EXTRACT(DAY FROM LAST_DAY(a.dt))
    ) AS net_rev_tl
  FROM ltv_daily_active_dedup a
  LEFT JOIN payment_option_config c
    ON a.payment_option = c.payment_option
),

user_realized_ltv AS (
  SELECT
    user_id,
    SUM(net_rev_tl) AS user_realized_ltv_tl
  FROM daily_user_revenue
  GROUP BY user_id
),

/* =========================================
   ACQUISITION COHORT (TRY-only first paid users)
   ========================================= */

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

first_paid_selected AS (
  SELECT
    fp.user_id,
    fp.first_paid_date,
    DATE_TRUNC(fp.first_paid_date, MONTH) AS cohort_month
  FROM first_paid fp
  CROSS JOIN params p
  WHERE fp.first_paid_date BETWEEN p.ds_start AND p.ds_end
),

/* =========================================
   CHANNEL NORMALIZATION - TOUCH
   ========================================= */

touch_ranked AS (
  SELECT
    fp.user_id,
    fp.first_paid_date,
    DATE_TRUNC(fp.first_paid_date, MONTH) AS cohort_month,
    g.mapped_channel,
    g.touch_date,
    ROW_NUMBER() OVER (
      PARTITION BY fp.user_id
      ORDER BY g.touch_date DESC, g.mapped_channel
    ) AS rn
  FROM first_paid_selected fp
  JOIN `microgain-9f959.bc_marketing_raw.ga4_first_non_direct_touch` g
    ON fp.user_id = g.user_id
  WHERE DATE_DIFF(fp.first_paid_date, g.touch_date, DAY) BETWEEN 0 AND 30
),

user_channel AS (
  SELECT
    user_id,
    first_paid_date,
    cohort_month,
    CASE
      WHEN mapped_channel IS NULL THEN 'other'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(mapped_channel)), r'(meta|facebook|instagram)') THEN 'meta'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(mapped_channel)), r'(google|adwords|youtube)') THEN 'google'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(mapped_channel)), r'(tiktok|tik tok)') THEN 'tiktok'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(mapped_channel)), r'(influencer|creator)') THEN 'influencer'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(mapped_channel)), r'(affiliate|partner)') THEN 'affiliate'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(mapped_channel)), r'(organic|direct|seo|referral|email|push|sms|crm)') THEN 'organic'
      ELSE 'other'
    END AS channel
  FROM touch_ranked
  WHERE rn = 1
),

user_channel_full AS (
  SELECT
    fp.user_id,
    fp.first_paid_date,
    fp.cohort_month,
    COALESCE(uc.channel, 'other') AS channel
  FROM first_paid_selected fp
  LEFT JOIN user_channel uc
    ON fp.user_id = uc.user_id
),

/* =========================================
   CHANNEL NORMALIZATION - SPEND
   ========================================= */

spend_raw AS (
  SELECT
    month,
    LOWER(TRIM(channel)) AS raw_channel,
    SUM(spend_tl) AS spend_tl
  FROM `microgain-9f959.bc_marketing_raw.manual_monthly_spend`
  CROSS JOIN params p
  WHERE month BETWEEN DATE_TRUNC(p.ds_start, MONTH) AND DATE_TRUNC(p.ds_end, MONTH)
  GROUP BY month, raw_channel
),

spend_monthly AS (
  SELECT
    month,
    CASE
      WHEN raw_channel IS NULL THEN 'other'
      WHEN REGEXP_CONTAINS(raw_channel, r'(meta|facebook|instagram)') THEN 'meta'
      WHEN REGEXP_CONTAINS(raw_channel, r'(google|adwords|youtube)') THEN 'google'
      WHEN REGEXP_CONTAINS(raw_channel, r'(tiktok|tik tok)') THEN 'tiktok'
      WHEN REGEXP_CONTAINS(raw_channel, r'(influencer|creator)') THEN 'influencer'
      WHEN REGEXP_CONTAINS(raw_channel, r'(affiliate|partner)') THEN 'affiliate'
      WHEN REGEXP_CONTAINS(raw_channel, r'(organic|direct|seo|referral|email|push|sms|crm)') THEN 'organic'
      ELSE 'other'
    END AS channel,
    SUM(spend_tl) AS spend_tl
  FROM spend_raw
  GROUP BY month, channel
),

/* =========================================
   MONTHLY CHANNEL METRICS
   ========================================= */

monthly_channel_user_metrics AS (
  SELECT
    uc.cohort_month AS month,
    uc.channel,
    COUNT(DISTINCT uc.user_id) AS users,
    AVG(COALESCE(l.user_realized_ltv_tl, 0)) AS avg_realized_ltv_tl,
    APPROX_QUANTILES(COALESCE(l.user_realized_ltv_tl, 0), 100)[OFFSET(50)] AS median_realized_ltv_tl,
    SUM(COALESCE(l.user_realized_ltv_tl, 0)) AS total_realized_ltv_tl
  FROM user_channel_full uc
  LEFT JOIN user_realized_ltv l
    ON uc.user_id = l.user_id
  GROUP BY uc.cohort_month, uc.channel
),

monthly_channel_final AS (
  SELECT
    'monthly' AS channel_scope,
    m.month,
    m.channel AS channel,
    m.users,
    s.spend_tl,
    SAFE_DIVIDE(s.spend_tl, m.users) AS cac_tl,
    m.avg_realized_ltv_tl,
    m.median_realized_ltv_tl,
    m.total_realized_ltv_tl,
    SAFE_DIVIDE(m.avg_realized_ltv_tl, SAFE_DIVIDE(s.spend_tl, m.users)) AS ltv_cac_ratio
  FROM monthly_channel_user_metrics m
  LEFT JOIN spend_monthly s
    ON m.month = s.month
   AND m.channel = s.channel
),

/* =========================================
   SELECTED PERIOD CHANNEL METRICS
   ========================================= */

selected_channel_user_metrics AS (
  SELECT
    uc.channel,
    COUNT(DISTINCT uc.user_id) AS users,
    AVG(COALESCE(l.user_realized_ltv_tl, 0)) AS avg_realized_ltv_tl,
    APPROX_QUANTILES(COALESCE(l.user_realized_ltv_tl, 0), 100)[OFFSET(50)] AS median_realized_ltv_tl,
    SUM(COALESCE(l.user_realized_ltv_tl, 0)) AS total_realized_ltv_tl
  FROM user_channel_full uc
  LEFT JOIN user_realized_ltv l
    ON uc.user_id = l.user_id
  GROUP BY uc.channel
),

selected_spend AS (
  SELECT
    channel,
    SUM(spend_tl) AS spend_tl
  FROM spend_monthly
  GROUP BY channel
),

selected_channel_final AS (
  SELECT
    'selected_period' AS channel_scope,
    DATE_TRUNC((SELECT ds_end FROM params), MONTH) AS month,
    m.channel AS channel,
    m.users,
    s.spend_tl,
    SAFE_DIVIDE(s.spend_tl, m.users) AS cac_tl,
    m.avg_realized_ltv_tl,
    m.median_realized_ltv_tl,
    m.total_realized_ltv_tl,
    SAFE_DIVIDE(m.avg_realized_ltv_tl, SAFE_DIVIDE(s.spend_tl, m.users)) AS ltv_cac_ratio
  FROM selected_channel_user_metrics m
  LEFT JOIN selected_spend s
    ON m.channel = s.channel
)

SELECT *
FROM monthly_channel_final

UNION ALL

SELECT *
FROM selected_channel_final

ORDER BY channel_scope, month, channel;