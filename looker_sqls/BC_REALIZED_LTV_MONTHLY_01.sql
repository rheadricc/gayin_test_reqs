-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Name: BC_REALIZED_LTV_MONTHLY_01
-- Grain: one row per calendar month in the selected range.
--
-- METRIC DICTIONARY:
--   monthly_actual_gross_collections_tl
--     Actual customer payment events in the month before commission.
--
--   monthly_actual_net_collections_tl
--     Actual customer payment events minus payment-provider commission.
--     Tax is NOT deducted.
--
--   realized_ltv_tl
--     Average cumulative actual NET collections per acquired paying user,
--     from each user's first real payment through metric_period_end.
--
--   median_realized_ltv_tl
--     Median cumulative actual NET collections per acquired paying user.
--
--   payer_count_to_date
--     Users whose first real payment occurred on or before metric_period_end.
--
-- RULES:
--   - PREPAID excluded.
--   - Raw minor-unit amount must be > 101; test charges are excluded.
--   - Payment events are deduplicated before aggregation.
--   - Foreign currency is converted with the latest TCMB forex_buying rate
--     available on or before payment date.
--   - The final selected month may be partial. Check is_completed_month.

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE) AS ds_end,
    DATE_TRUNC(PARSE_DATE('%Y%m%d', @DS_START_DATE), MONTH) AS start_month,
    DATE_TRUNC(PARSE_DATE('%Y%m%d', @DS_END_DATE), MONTH) AS end_month
),

payment_option_config AS (
  SELECT 'APP_STORE'      AS payment_option, 0.30 AS commission_rate UNION ALL
  SELECT 'PLAY_STORE'     AS payment_option, 0.15 AS commission_rate UNION ALL
  SELECT 'MOBILE_PAYMENT' AS payment_option, 0.15 AS commission_rate UNION ALL
  SELECT 'CRAFTGATE'      AS payment_option, 0.00 AS commission_rate UNION ALL
  SELECT 'IYZICO'         AS payment_option, 0.03 AS commission_rate
),

tcmb_rates AS (
  SELECT
    DATE(rate_date) AS rate_date,
    UPPER(currency_code) AS currency_code,
    SAFE_DIVIDE(
      CAST(forex_buying AS FLOAT64),
      NULLIF(CAST(unit AS FLOAT64), 0.0)
    ) AS rate_to_try
  FROM `microgain-9f959.bc_t.tcmb_exchange_rates_raw`
  WHERE currency_code IS NOT NULL
    AND forex_buying IS NOT NULL
    AND unit IS NOT NULL
),

payment_base AS (
  SELECT
    CAST(s.user_id AS STRING) AS user_id,
    UPPER(TRIM(s.payment_option)) AS payment_option,
    UPPER(TRIM(s.currency)) AS currency_code,
    s.created_at,
    s.inserted_date,
    DATE(s.created_at) AS payment_date,
    DATE(s.valid_until) AS valid_until_date,
    s.apple_original_transaction_id,
    s.google_original_transaction_id,
    SAFE_DIVIDE(
      CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64),
      100.0
    ) AS amount_original
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN params p
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND UPPER(TRIM(s.payment_option)) != 'PREPAID'
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 101
    AND DATE(s.created_at) <= p.ds_end
),

payment_rate_candidates AS (
  SELECT
    p.*,
    r.rate_date AS matched_rate_date,
    r.rate_to_try,
    ROW_NUMBER() OVER (
      PARTITION BY
        p.user_id,
        p.payment_option,
        p.currency_code,
        p.created_at,
        p.inserted_date,
        p.valid_until_date,
        p.apple_original_transaction_id,
        p.google_original_transaction_id,
        CAST(p.amount_original AS STRING)
      ORDER BY r.rate_date DESC
    ) AS rate_rn
  FROM payment_base p
  LEFT JOIN tcmb_rates r
    ON p.currency_code != 'TRY'
   AND r.currency_code = p.currency_code
   AND r.rate_date <= p.payment_date
),

payment_converted AS (
  SELECT
    * EXCEPT(rate_rn),
    CASE
      WHEN currency_code = 'TRY' THEN amount_original
      ELSE amount_original * rate_to_try
    END AS amount_gross_tl
  FROM payment_rate_candidates
  WHERE currency_code = 'TRY'
     OR rate_rn = 1
),

payment_events_dedup AS (
  SELECT
    user_id,
    payment_option,
    payment_date,
    amount_gross_tl
  FROM (
    SELECT
      p.*,
      ROW_NUMBER() OVER (
        PARTITION BY
          p.user_id,
          p.payment_option,
          p.currency_code,
          p.created_at,
          p.valid_until_date,
          p.apple_original_transaction_id,
          p.google_original_transaction_id,
          CAST(p.amount_original AS STRING)
        ORDER BY p.inserted_date DESC
      ) AS payment_rn
    FROM payment_converted p
    WHERE p.amount_gross_tl IS NOT NULL
  )
  WHERE payment_rn = 1
),

payment_events AS (
  SELECT
    p.user_id,
    p.payment_date,
    p.payment_option,
    p.amount_gross_tl,
    p.amount_gross_tl
      * (1.0 - COALESCE(c.commission_rate, 0.00)) AS amount_net_tl
  FROM payment_events_dedup p
  LEFT JOIN payment_option_config c
    ON p.payment_option = c.payment_option
),

first_paid AS (
  SELECT
    user_id,
    MIN(payment_date) AS first_paid_date,
    DATE_TRUNC(MIN(payment_date), MONTH) AS cohort_month
  FROM payment_events
  GROUP BY user_id
),

month_bounds AS (
  SELECT
    month,
    LEAST(LAST_DAY(month), p.ds_end) AS metric_period_end,
    (LAST_DAY(month) <= p.ds_end) AS is_completed_month
  FROM params p,
  UNNEST(
    GENERATE_DATE_ARRAY(p.start_month, p.end_month, INTERVAL 1 MONTH)
  ) AS month
),

monthly_collections AS (
  SELECT
    DATE_TRUNC(p.payment_date, MONTH) AS month,
    COUNT(*) AS monthly_transaction_count,
    COUNT(DISTINCT p.user_id) AS monthly_paying_user_count,
    SUM(p.amount_gross_tl) AS monthly_actual_gross_collections_tl,
    SUM(p.amount_net_tl) AS monthly_actual_net_collections_tl
  FROM payment_events p
  CROSS JOIN params x
  WHERE p.payment_date BETWEEN x.ds_start AND x.ds_end
  GROUP BY month
),

user_month_cumulative AS (
  SELECT
    m.month,
    m.metric_period_end,
    m.is_completed_month,
    f.user_id,
    f.cohort_month,
    f.first_paid_date,
    SUM(p.amount_net_tl) AS user_cumulative_net_collections_tl
  FROM month_bounds m
  JOIN first_paid f
    ON f.first_paid_date <= m.metric_period_end
  JOIN payment_events p
    ON p.user_id = f.user_id
   AND p.payment_date <= m.metric_period_end
  GROUP BY
    m.month,
    m.metric_period_end,
    m.is_completed_month,
    f.user_id,
    f.cohort_month,
    f.first_paid_date
),

monthly_realized_ltv AS (
  SELECT
    month,
    metric_period_end,
    is_completed_month,
    COUNT(DISTINCT user_id) AS payer_count_to_date,
    COUNT(DISTINCT cohort_month) AS cohort_count_to_date,
    AVG(
      SAFE_DIVIDE(
        DATE_DIFF(metric_period_end, first_paid_date, DAY),
        30.4375
      )
    ) AS avg_payer_age_months,
    AVG(user_cumulative_net_collections_tl) AS realized_ltv_tl,
    APPROX_QUANTILES(
      user_cumulative_net_collections_tl,
      100
    )[OFFSET(50)] AS median_realized_ltv_tl,
    SUM(user_cumulative_net_collections_tl) AS total_realized_net_collections_tl
  FROM user_month_cumulative
  GROUP BY month, metric_period_end, is_completed_month
),

new_payers AS (
  SELECT
    cohort_month AS month,
    COUNT(DISTINCT user_id) AS new_paying_users
  FROM first_paid
  GROUP BY month
)

SELECT
  m.month,
  m.metric_period_end,
  m.is_completed_month,
  m.payer_count_to_date,
  COALESCE(n.new_paying_users, 0) AS new_paying_users,
  m.cohort_count_to_date,
  m.avg_payer_age_months,
  COALESCE(c.monthly_transaction_count, 0) AS monthly_transaction_count,
  COALESCE(c.monthly_paying_user_count, 0) AS monthly_paying_user_count,
  COALESCE(
    c.monthly_actual_gross_collections_tl,
    0
  ) AS monthly_actual_gross_collections_tl,
  COALESCE(
    c.monthly_actual_net_collections_tl,
    0
  ) AS monthly_actual_net_collections_tl,
  SAFE_DIVIDE(
    c.monthly_actual_net_collections_tl,
    NULLIF(c.monthly_paying_user_count, 0)
  ) AS monthly_actual_net_arppu_tl,
  m.realized_ltv_tl,
  m.median_realized_ltv_tl,
  m.total_realized_net_collections_tl,
  -- Compatibility aliases for existing Looker fields.
  m.payer_count_to_date AS active_user_count,
  c.monthly_actual_net_collections_tl AS total_revenue_tl,
  SAFE_DIVIDE(
    c.monthly_actual_net_collections_tl,
    NULLIF(c.monthly_paying_user_count, 0)
  ) AS arpu_tl,
  m.total_realized_net_collections_tl AS total_realized_ltv_tl
FROM monthly_realized_ltv m
LEFT JOIN monthly_collections c
  ON m.month = c.month
LEFT JOIN new_payers n
  ON m.month = n.month
ORDER BY m.month;
