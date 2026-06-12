-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- New name: BC_FORECAST_LTV_MONTHLY_01
-- Output: MONTH grain only
-- Metric: Forecast LTV = ARPU × avg lifetime months
-- REVIEW NOTE: Forecast metric is intentionally different from realized LTV; do not compare as the same metric.
-- Logic:
--   - TRY + foreign currency payments included
--   - Foreign currencies converted to TRY with TCMB forex_buying rate
--   - If exact payment date rate is missing, latest available TCMB rate before payment date is used
--   - PREPAID excluded
--   - CANCELED users are counted as active until valid_until
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
  CROSS JOIN params p
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND UPPER(TRIM(s.payment_option)) != 'PREPAID'
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 0
    AND DATE(s.created_at) <= p.ds_end
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

sub_start AS (
  SELECT
    user_id,
    MIN(payment_date) AS first_sub_date
  FROM paid_payments
  WHERE currency_code = 'TRY'
     OR rate_to_try IS NOT NULL
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
    UPPER(TRIM(s.currency)) AS currency_code,
    SAFE_DIVIDE(CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64), 100.0) AS amount_original
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN params p
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND s.payment_option != 'PREPAID'
    AND s.status IN ('ACTIVE', 'CANCELED', 'IN_GRACE', 'ON_HOLD')
    AND DATE(s.created_at) <= p.ds_end
),

subs AS (
  SELECT *
  FROM subs_base
  CROSS JOIN params p
  WHERE active_end_date >= p.ds_start
),

subs_with_rate_candidates AS (
  SELECT
    s.*,
    r.rate_date AS matched_rate_date,
    r.rate_to_try,
    ROW_NUMBER() OVER (
      PARTITION BY
        CAST(s.user_id AS STRING),
        s.payment_option,
        s.currency_code,
        s.created_at,
        s.inserted_date,
        s.valid_until_date,
        CAST(s.amount_original AS STRING)
      ORDER BY r.rate_date DESC
    ) AS rate_rn
  FROM subs s
  LEFT JOIN tcmb_rates r
    ON s.currency_code != 'TRY'
   AND r.currency_code = s.currency_code
   AND r.rate_date <= s.created_date
),

subs_converted AS (
  SELECT
    * EXCEPT(rate_rn),
    CASE
      WHEN currency_code = 'TRY' THEN amount_original
      ELSE amount_original * rate_to_try
    END AS amount_gross_tl
  FROM subs_with_rate_candidates
  WHERE currency_code = 'TRY'
     OR rate_rn = 1
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
    s.amount_gross_tl,
    s.created_at,
    s.inserted_date
  FROM days d
  JOIN subs_converted s
    ON d.dt BETWEEN s.created_date AND s.active_end_date
   AND s.amount_gross_tl IS NOT NULL
),

daily_active_dedup AS (
  SELECT
    r.dt,
    r.user_id,
    r.payment_option,
    r.amount_gross_tl
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
      a.amount_gross_tl
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