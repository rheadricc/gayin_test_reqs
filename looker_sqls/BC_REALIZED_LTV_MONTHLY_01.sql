-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- New name: BC_REALIZED_LTV_MONTHLY_01
-- Output: MONTH grain only
-- Metric: realized cumulative LTV up to month-end
-- REVIEW NOTE: Core LTV basis is active-day prorated realized net revenue.
-- Logic:
--   - TRY + foreign currency payments included
--   - Foreign currencies converted to TRY with TCMB forex_buying rate
--   - If exact payment date rate is missing, latest available TCMB rate before payment date is used
--   - PREPAID excluded
--   - CANCELED users are counted as active until valid_until
--   - real net revenue per user-day
--   - cumulative realized LTV by user
--   - averaged over users active in each selected month

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

history_start AS (
  SELECT
    MIN(DATE(created_at)) AS hist_start
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE user_id IS NOT NULL
    AND payment_option IS NOT NULL
    AND payment_option != 'PREPAID'
),

subs AS (
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
  CROSS JOIN history_start h
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND s.payment_option != 'PREPAID'
    AND s.status IN ('ACTIVE', 'CANCELED', 'IN_GRACE', 'ON_HOLD')
    AND DATE(s.created_at) <= p.ds_end
    AND DATE(
      CASE
        WHEN s.status = 'ON_HOLD'  THEN COALESCE(s.hold_until,  s.valid_until)
        WHEN s.status = 'IN_GRACE' THEN COALESCE(s.grace_until, s.valid_until)
        ELSE s.valid_until
      END
    ) >= h.hist_start
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
  FROM params p
  CROSS JOIN history_start h
  CROSS JOIN UNNEST(GENERATE_DATE_ARRAY(h.hist_start, p.ds_end)) AS d
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

monthly_user_revenue_all AS (
  SELECT
    DATE_TRUNC(dt, MONTH) AS month,
    user_id,
    SUM(net_rev_tl) AS revenue_month_tl
  FROM daily_user_revenue
  GROUP BY month, user_id
),

user_cumulative_ltv AS (
  SELECT
    month,
    user_id,
    SUM(revenue_month_tl) OVER (
      PARTITION BY user_id
      ORDER BY month
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS realized_ltv_tl_to_month_end
  FROM monthly_user_revenue_all
),

selected_daily_kpis AS (
  SELECT
    DATE_TRUNC(dt, MONTH) AS month,
    dt,
    COUNT(DISTINCT user_id) AS daily_active_users,
    SUM(net_rev_tl) AS daily_revenue_tl
  FROM daily_user_revenue
  CROSS JOIN params p
  WHERE dt BETWEEN p.ds_start AND p.ds_end
  GROUP BY month, dt
),

monthly_selected_totals AS (
  SELECT
    month,
    SUM(daily_revenue_tl) AS total_revenue_tl,
    AVG(daily_active_users) AS avg_daily_active_users
  FROM selected_daily_kpis
  GROUP BY month
),

selected_month_active_users AS (
  SELECT DISTINCT
    DATE_TRUNC(dt, MONTH) AS month,
    user_id
  FROM daily_active_dedup
  CROSS JOIN params p
  WHERE dt BETWEEN p.ds_start AND p.ds_end
),

final AS (
  SELECT
    a.month,
    COUNT(DISTINCT a.user_id) AS active_user_count,
    t.total_revenue_tl,
    t.avg_daily_active_users,
    SAFE_DIVIDE(t.total_revenue_tl, t.avg_daily_active_users) AS arpu_tl,
    AVG(COALESCE(c.realized_ltv_tl_to_month_end, 0)) AS realized_ltv_tl,
    APPROX_QUANTILES(COALESCE(c.realized_ltv_tl_to_month_end, 0), 100)[OFFSET(50)] AS median_realized_ltv_tl,
    SUM(COALESCE(c.realized_ltv_tl_to_month_end, 0)) AS total_realized_ltv_tl
  FROM selected_month_active_users a
  LEFT JOIN user_cumulative_ltv c
    ON a.user_id = c.user_id
   AND a.month = c.month
  LEFT JOIN monthly_selected_totals t
    ON a.month = t.month
  GROUP BY
    a.month,
    t.total_revenue_tl,
    t.avg_daily_active_users
)

SELECT
  month,
  active_user_count,
  total_revenue_tl,
  avg_daily_active_users,
  arpu_tl,
  realized_ltv_tl,
  median_realized_ltv_tl,
  total_realized_ltv_tl
FROM final
ORDER BY month;