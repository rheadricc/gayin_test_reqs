-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Name: BC_FORECAST_LTV_MONTHLY_01
-- Grain: one row per COMPLETED calendar month.
--
-- METRIC DICTIONARY:
--   monthly_net_accrued_revenue_tl
--     Subscription revenue allocated across paid-entitlement days.
--     Payment-provider commission is deducted; tax is NOT deducted.
--
--   monthly_net_arpu_tl
--     monthly_net_accrued_revenue_tl / average daily paid subscribers.
--
--   lost_subscribers
--     Distinct users whose latest subscription lifecycle is IN_GRACE,
--     ON_HOLD or EXPIRED. IN_GRACE/ON_HOLD loss date is valid_until;
--     EXPIRED loss date is the latest of valid_until/grace_until/hold_until.
--
--   monthly_loss_rate
--     lost_subscribers / paid subscribers on the first day of that month.
--
--   trailing_3_completed_month_loss_rate
--     Average monthly_loss_rate of the three months BEFORE the metric month.
--
--   forecast_ltv_tl
--     monthly_net_arpu_tl / trailing_3_completed_month_loss_rate.
--     Equivalent to ARPU x expected lifetime, where expected lifetime
--     is 1 / average monthly loss rate.
--
-- IMPORTANT:
--   Partial months are intentionally excluded. A June 1-22 ARPU must not be
--   compared with a completed May ARPU.

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE) AS ds_end,
    DATE_TRUNC(PARSE_DATE('%Y%m%d', @DS_START_DATE), MONTH) AS output_start_month,
    CASE
      WHEN PARSE_DATE('%Y%m%d', @DS_END_DATE)
        = LAST_DAY(PARSE_DATE('%Y%m%d', @DS_END_DATE))
      THEN DATE_TRUNC(PARSE_DATE('%Y%m%d', @DS_END_DATE), MONTH)
      ELSE DATE_TRUNC(
        DATE_SUB(PARSE_DATE('%Y%m%d', @DS_END_DATE), INTERVAL 1 MONTH),
        MONTH
      )
    END AS output_end_month
),

bounds AS (
  SELECT
    *,
    DATE_SUB(output_start_month, INTERVAL 3 MONTH) AS history_start_month,
    LAST_DAY(output_end_month) AS history_end_date
  FROM params
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

subs_base AS (
  SELECT
    CAST(s.user_id AS STRING) AS user_id,
    UPPER(TRIM(s.status)) AS status,
    UPPER(TRIM(s.payment_option)) AS payment_option,
    s.created_at,
    s.inserted_date,
    DATE(s.created_at) AS created_date,
    DATE(s.valid_until) AS valid_until_date,
    DATE(s.grace_until) AS grace_until_date,
    DATE(s.hold_until) AS hold_until_date,
    DATE(s.valid_until) AS paid_end_date,
    CASE
      WHEN UPPER(TRIM(s.status)) IN ('IN_GRACE', 'ON_HOLD')
        THEN DATE(s.valid_until)
      WHEN UPPER(TRIM(s.status)) = 'EXPIRED'
        THEN GREATEST(
          DATE(s.valid_until),
          COALESCE(DATE(s.grace_until), DATE(s.valid_until)),
          COALESCE(DATE(s.hold_until), DATE(s.valid_until))
        )
      ELSE NULL
    END AS loss_date,
    UPPER(TRIM(s.currency)) AS currency_code,
    SAFE_DIVIDE(
      CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64),
      100.0
    ) AS amount_original
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN bounds b
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND UPPER(TRIM(s.payment_option)) != 'PREPAID'
    AND UPPER(TRIM(s.status)) IN (
      'ACTIVE', 'CANCELED', 'IN_GRACE', 'ON_HOLD', 'EXPIRED'
    )
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 101
    AND DATE(s.created_at) <= b.history_end_date
),

subs_with_rate_candidates AS (
  SELECT
    s.*,
    r.rate_date AS matched_rate_date,
    r.rate_to_try,
    ROW_NUMBER() OVER (
      PARTITION BY
        s.user_id,
        s.payment_option,
        s.currency_code,
        s.created_at,
        s.inserted_date,
        s.valid_until_date,
        CAST(s.amount_original AS STRING)
      ORDER BY r.rate_date DESC
    ) AS rate_rn
  FROM subs_base s
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

calendar_days AS (
  SELECT d AS date
  FROM bounds b,
  UNNEST(GENERATE_DATE_ARRAY(b.history_start_month, b.history_end_date)) AS d
),

daily_paid_raw AS (
  SELECT
    d.date,
    s.user_id,
    s.payment_option,
    s.amount_gross_tl,
    s.created_at,
    s.inserted_date
  FROM calendar_days d
  JOIN subs_converted s
    ON d.date BETWEEN s.created_date AND s.paid_end_date
   AND s.amount_gross_tl IS NOT NULL
),

daily_paid_dedup AS (
  SELECT
    date,
    user_id,
    payment_option,
    amount_gross_tl
  FROM (
    SELECT
      r.*,
      ROW_NUMBER() OVER (
        PARTITION BY r.date, r.user_id
        ORDER BY r.created_at DESC, r.inserted_date DESC
      ) AS rn
    FROM daily_paid_raw r
  )
  WHERE rn = 1
),

daily_metrics AS (
  SELECT
    d.date,
    DATE_TRUNC(d.date, MONTH) AS month,
    COUNT(DISTINCT d.user_id) AS paid_subscribers,
    SUM(
      SAFE_DIVIDE(
        d.amount_gross_tl
          * (1.0 - COALESCE(c.commission_rate, 0.00)),
        EXTRACT(DAY FROM LAST_DAY(d.date))
      )
    ) AS net_accrued_revenue_tl
  FROM daily_paid_dedup d
  LEFT JOIN payment_option_config c
    ON d.payment_option = c.payment_option
  GROUP BY d.date, month
),

monthly_paid_metrics AS (
  SELECT
    month,
    SUM(net_accrued_revenue_tl) AS monthly_net_accrued_revenue_tl,
    AVG(paid_subscribers) AS avg_daily_paid_subscribers,
    MAX(IF(date = month, paid_subscribers, NULL)) AS month_start_paid_subscribers
  FROM daily_metrics
  GROUP BY month
),

loss_events AS (
  SELECT
    DATE_TRUNC(loss_date, MONTH) AS month,
    COUNT(DISTINCT user_id) AS lost_subscribers
  FROM subs_converted
  CROSS JOIN bounds b
  WHERE status IN ('IN_GRACE', 'ON_HOLD', 'EXPIRED')
    AND loss_date BETWEEN b.history_start_month AND b.history_end_date
  GROUP BY month
),

month_spine AS (
  SELECT month
  FROM bounds b,
  UNNEST(
    GENERATE_DATE_ARRAY(
      b.history_start_month,
      b.output_end_month,
      INTERVAL 1 MONTH
    )
  ) AS month
),

monthly_metrics AS (
  SELECT
    m.month,
    COALESCE(p.monthly_net_accrued_revenue_tl, 0) AS monthly_net_accrued_revenue_tl,
    COALESCE(p.avg_daily_paid_subscribers, 0) AS avg_daily_paid_subscribers,
    COALESCE(p.month_start_paid_subscribers, 0) AS month_start_paid_subscribers,
    COALESCE(l.lost_subscribers, 0) AS lost_subscribers,
    SAFE_DIVIDE(
      COALESCE(l.lost_subscribers, 0),
      NULLIF(p.month_start_paid_subscribers, 0)
    ) AS monthly_loss_rate,
    SAFE_DIVIDE(
      p.monthly_net_accrued_revenue_tl,
      NULLIF(p.avg_daily_paid_subscribers, 0)
    ) AS monthly_net_arpu_tl
  FROM month_spine m
  LEFT JOIN monthly_paid_metrics p
    ON m.month = p.month
  LEFT JOIN loss_events l
    ON m.month = l.month
),

with_trailing_loss AS (
  SELECT
    *,
    AVG(monthly_loss_rate) OVER (
      ORDER BY month
      ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING
    ) AS trailing_3_completed_month_loss_rate,
    COUNT(monthly_loss_rate) OVER (
      ORDER BY month
      ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING
    ) AS loss_rate_month_count
  FROM monthly_metrics
)

SELECT
  m.month,
  LAST_DAY(m.month) AS month_end,
  TRUE AS is_completed_month,
  m.monthly_net_accrued_revenue_tl,
  m.avg_daily_paid_subscribers,
  m.month_start_paid_subscribers,
  m.monthly_net_arpu_tl,
  m.lost_subscribers,
  m.monthly_loss_rate,
  m.trailing_3_completed_month_loss_rate,
  m.loss_rate_month_count,
  SAFE_DIVIDE(
    1.0,
    m.trailing_3_completed_month_loss_rate
  ) AS forecast_lifetime_months,
  SAFE_DIVIDE(
    m.monthly_net_arpu_tl,
    m.trailing_3_completed_month_loss_rate
  ) AS forecast_ltv_tl
FROM with_trailing_loss m
CROSS JOIN bounds b
WHERE m.month BETWEEN b.output_start_month AND b.output_end_month
ORDER BY m.month;
