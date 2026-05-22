-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- New name: BC_FORECAST_LTV_MONTHLY_01
-- Output: MONTH grain only
-- Metric: Forecast LTV = ARPU × avg lifetime months
-- Logic:
--   - TRY-only
--   - PREPAID excluded
--   - avg lifetime is calculated against each month's own month-end

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

payment_option_config AS (
  SELECT 'APP_STORE'       AS payment_option, 0.30 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'PLAY_STORE'      AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'MOBILE_PAYMENT'  AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'CRAFTGATE'       AS payment_option, 0.00 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'IYZICO'          AS payment_option, 0.03 AS commission_rate, 0.20 AS tax_rate
),

sub_start AS (
  SELECT
    user_id,
    MIN(DATE(created_at)) AS first_sub_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE user_id IS NOT NULL
    AND payment_option IS NOT NULL
    AND payment_option != 'PREPAID'
    AND UPPER(currency) = 'TRY'
  GROUP BY user_id
),

subs_base AS (
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
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND s.payment_option != 'PREPAID'
    AND s.status IN ('ACTIVE', 'IN_GRACE', 'ON_HOLD')
    AND UPPER(s.currency) = 'TRY'
    AND DATE(s.created_at) <= p.ds_end
),

subs AS (
  SELECT *
  FROM subs_base
  CROSS JOIN params p
  WHERE active_end_date >= p.ds_start
),

days AS (
  SELECT d AS dt
  FROM params p,
  UNNEST(GENERATE_DATE_ARRAY(p.ds_start, p.ds_end)) AS d
),

daily_active_raw AS (
  SELECT
    d.dt,
    s.user_id,
    s.payment_option,
    s.amount_minor,
    s.created_at,
    s.inserted_date
  FROM days d
  JOIN subs s
    ON d.dt BETWEEN s.created_date AND s.active_end_date
),

daily_active_dedup AS (
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
    FROM daily_active_raw r
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
  FROM daily_active_dedup a
  LEFT JOIN payment_option_config c
    ON a.payment_option = c.payment_option
),

daily_kpis AS (
  SELECT
    DATE_TRUNC(dt, MONTH) AS month,
    dt,
    COUNT(DISTINCT user_id) AS daily_active_users,
    SUM(net_rev_tl) AS daily_revenue_tl
  FROM daily_user_revenue
  GROUP BY month, dt
),

monthly_totals AS (
  SELECT
    month,
    SUM(daily_revenue_tl) AS total_revenue_tl,
    AVG(daily_active_users) AS avg_daily_active_users
  FROM daily_kpis
  GROUP BY month
),

monthly_active_users AS (
  SELECT DISTINCT
    DATE_TRUNC(dt, MONTH) AS month,
    user_id
  FROM daily_active_dedup
),

monthly_age AS (
  SELECT
    mau.month,
    AVG(
      SAFE_DIVIDE(
        DATE_DIFF(LAST_DAY(mau.month), ss.first_sub_date, DAY),
        30.0
      )
    ) AS avg_lifetime_months
  FROM monthly_active_users mau
  JOIN sub_start ss
    ON mau.user_id = ss.user_id
  GROUP BY mau.month
)

SELECT
  m.month,
  m.total_revenue_tl,
  m.avg_daily_active_users,
  SAFE_DIVIDE(m.total_revenue_tl, m.avg_daily_active_users) AS arpu_tl,
  a.avg_lifetime_months,
  SAFE_MULTIPLY(
    SAFE_DIVIDE(m.total_revenue_tl, m.avg_daily_active_users),
    a.avg_lifetime_months
  ) AS forecast_ltv_tl
FROM monthly_totals m
LEFT JOIN monthly_age a
  ON m.month = a.month
ORDER BY m.month;