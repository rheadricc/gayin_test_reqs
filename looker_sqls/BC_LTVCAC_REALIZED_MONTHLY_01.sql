-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Name: BC_LTVCAC_REALIZED_MONTHLY_01
--
-- Exactly one row per fully matured acquisition-cohort month.
-- This is already the blended result of all paid channels; it intentionally
-- has no channel dimension.
--
-- Looker "Geriye Dönük Analiz":
--   Dimension = month
--   Metrics   = realized_ltv_tl, cac_tl, ltv_cac_ratio
--   Do not add a channel filter.
--   Do not use is_latest_mature_month=true when multiple months are required.
--
-- Definitions:
--   realized_ltv_tl = paid-channel users' average actual net collections
--                     during their first three months.
--   cac_tl          = same cohort month's automated paid-channel spend
--                     / same attributed paid users.
--   ltv_cac_ratio   = realized_ltv_tl / cac_tl.
--   cohort_monthly_realized_revenue_tl = realized_ltv_tl / 3.
--                     This is NOT the current subscriber portfolio ARPU from
--                     BC_UNIT_ECONOMICS_DAILY_01. It is the acquired cohort's
--                     monthlyized first-three-month realized revenue.
--
-- Churned users are included. Tax is not deducted. Raw payment amount > 101.
-- manual_monthly_spend is intentionally not used.
--
-- The Looker start-date parameter is intentionally not used as the cohort
-- acquisition lower bound. A "last 28 days" scorecard filter cannot contain a
-- cohort that has already completed a three-month observation window. Instead,
-- the query calculates matured cohorts from the trailing 12-month acquisition
-- window ending at @DS_END_DATE. Scorecards select the latest row with
-- is_latest_mature_month=true.

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    LEAST(
      PARSE_DATE('%Y%m%d', @DS_END_DATE),
      DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
    ) AS ds_end,
    DATE_SUB(
      DATE_TRUNC(
        LEAST(
          PARSE_DATE('%Y%m%d', @DS_END_DATE),
          DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
        ),
        MONTH
      ),
      INTERVAL 12 MONTH
    ) AS cohort_scan_start
),

payment_option_config AS (
  SELECT 'APP_STORE'       AS payment_option, 0.30 AS commission_rate UNION ALL
  SELECT 'PLAY_STORE'      AS payment_option, 0.15 AS commission_rate UNION ALL
  SELECT 'MOBILE_PAYMENT'  AS payment_option, 0.15 AS commission_rate UNION ALL
  SELECT 'CRAFTGATE'       AS payment_option, 0.00 AS commission_rate UNION ALL
  SELECT 'IYZICO'          AS payment_option, 0.03 AS commission_rate
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

payment_events AS (
  SELECT
    p.user_id,
    p.payment_option,
    p.payment_date,
    p.amount_gross_tl
      * (1.0 - COALESCE(c.commission_rate, 0.00)) AS amount_net_tl
  FROM payment_converted p
  LEFT JOIN payment_option_config c
    ON p.payment_option = c.payment_option
  WHERE p.amount_gross_tl IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
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
  ) = 1
),

first_paid AS (
  SELECT
    user_id,
    MIN(payment_date) AS first_paid_date
  FROM payment_events
  GROUP BY user_id
),

mature_first_paid AS (
  SELECT
    f.user_id,
    f.first_paid_date,
    DATE_TRUNC(f.first_paid_date, MONTH) AS month,
    DATE_ADD(f.first_paid_date, INTERVAL 3 MONTH) AS observation_end_date
  FROM first_paid f
  CROSS JOIN params p
  WHERE f.first_paid_date BETWEEN p.cohort_scan_start AND p.ds_end
    AND DATE_ADD(
          LAST_DAY(DATE_TRUNC(f.first_paid_date, MONTH)),
          INTERVAL 3 MONTH
        ) <= p.ds_end
),

normalized_touches AS (
  SELECT
    CAST(g.user_id AS STRING) AS user_id,
    g.touch_date,
    LOWER(TRIM(CAST(g.medium AS STRING))) AS medium,
    REGEXP_CONTAINS(
      LOWER(TRIM(COALESCE(CAST(g.medium AS STRING), ''))),
      r'(^|[-_])(cpc|cpa|cpm|paid|conversion)([-_]|$)|instagram_(reels|stories|feed)|facebook_(mobile_|desktop_)?(reels|feed|stories)|facebook_right_column'
    ) AS is_paid_touch,
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
  CROSS JOIN params p
  WHERE g.touch_date BETWEEN DATE_SUB(p.cohort_scan_start, INTERVAL 30 DAY)
                         AND p.ds_end
),

attributed_users AS (
  SELECT
    f.user_id,
    f.first_paid_date,
    f.month,
    f.observation_end_date,
    t.channel
  FROM mature_first_paid f
  JOIN normalized_touches t
    ON f.user_id = t.user_id
   AND DATE_DIFF(f.first_paid_date, t.touch_date, DAY) BETWEEN 0 AND 30
  WHERE t.channel IN ('google', 'meta', 'tiktok')
    AND t.is_paid_touch
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY f.user_id
    ORDER BY
      t.touch_date DESC,
      CASE
        WHEN t.medium IN ('cpc', 'cpa', 'paid', 'paid_social', 'search_cpc')
          THEN 1
        ELSE 0
      END DESC,
      t.channel
  ) = 1
),

monthly_spend_by_channel AS (
  SELECT
    month,
    LOWER(TRIM(channel)) AS channel,
    SUM(spend_tl) AS spend_tl
  FROM `microgain-9f959.bc_marketing_marts.ads_daily_spend`
  CROSS JOIN params p
  WHERE month BETWEEN DATE_TRUNC(p.cohort_scan_start, MONTH)
                  AND DATE_TRUNC(p.ds_end, MONTH)
    AND LOWER(TRIM(channel)) IN ('google', 'meta', 'tiktok')
  GROUP BY month, channel
),

eligible_attributed_users AS (
  SELECT a.*
  FROM attributed_users a
  JOIN monthly_spend_by_channel s
    ON a.month = s.month
   AND a.channel = s.channel
),

user_ltv_3m AS (
  SELECT
    a.user_id,
    a.month,
    a.channel,
    COUNT(*) AS payment_count_3m,
    SUM(e.amount_net_tl) AS realized_ltv_3m_tl
  FROM eligible_attributed_users a
  JOIN payment_events e
    ON a.user_id = e.user_id
   AND e.payment_date >= a.first_paid_date
   AND e.payment_date < a.observation_end_date
  GROUP BY a.user_id, a.month, a.channel
),

monthly_cohort AS (
  SELECT
    month,
    COUNT(DISTINCT user_id) AS new_paid_users,
    AVG(realized_ltv_3m_tl) AS realized_ltv_tl,
    APPROX_QUANTILES(
      realized_ltv_3m_tl,
      100
    )[OFFSET(50)] AS median_realized_ltv_tl,
    SUM(realized_ltv_3m_tl) AS total_realized_ltv_tl,
    AVG(payment_count_3m) AS avg_payment_count_3m
  FROM user_ltv_3m
  GROUP BY month
),

monthly_first_paid_totals AS (
  SELECT
    month,
    COUNT(DISTINCT user_id) AS total_first_paid_users
  FROM mature_first_paid
  GROUP BY month
),

monthly_spend AS (
  SELECT
    month,
    SUM(spend_tl) AS spend_tl
  FROM monthly_spend_by_channel
  GROUP BY month
),

final AS (
  SELECT
    c.month,
    DATE_ADD(LAST_DAY(c.month), INTERVAL 3 MONTH) AS metric_period_end,
    TRUE AS is_completed_month,
    c.new_paid_users AS active_user_count,
    c.total_realized_ltv_tl AS total_revenue_tl,
    CAST(NULL AS FLOAT64) AS avg_daily_active_users,
    SAFE_DIVIDE(
      c.realized_ltv_tl,
      3.0
    ) AS cohort_monthly_realized_revenue_tl,
    s.spend_tl,
    c.new_paid_users,
    t.total_first_paid_users,
    SAFE_DIVIDE(
      c.new_paid_users,
      t.total_first_paid_users
    ) AS attribution_coverage,
    SAFE_DIVIDE(s.spend_tl, c.new_paid_users) AS cac_tl,
    CASE
      WHEN s.spend_tl > 0 AND c.new_paid_users > 0 THEN 'ok'
      WHEN s.spend_tl > 0 AND c.new_paid_users = 0 THEN 'spend_var_user_yok'
      ELSE 'spend_yok'
    END AS cac_status,
    c.realized_ltv_tl,
    c.median_realized_ltv_tl,
    c.total_realized_ltv_tl,
    c.avg_payment_count_3m,
    SAFE_DIVIDE(
      c.realized_ltv_tl,
      SAFE_DIVIDE(s.spend_tl, c.new_paid_users)
    ) AS ltv_cac_ratio,
    SAFE_DIVIDE(
      SAFE_DIVIDE(s.spend_tl, c.new_paid_users),
      SAFE_DIVIDE(c.realized_ltv_tl, 3.0)
    ) AS cac_payback_period
  FROM monthly_cohort c
  JOIN monthly_spend s
    ON c.month = s.month
  LEFT JOIN monthly_first_paid_totals t
    ON c.month = t.month
)

SELECT
  month,
  month = MAX(month) OVER () AS is_latest_mature_month,
  metric_period_end,
  is_completed_month,
  active_user_count,
  total_revenue_tl,
  avg_daily_active_users,
  cohort_monthly_realized_revenue_tl,
  -- Compatibility alias for the existing Looker field.
  cohort_monthly_realized_revenue_tl AS arpu_tl,
  spend_tl,
  new_paid_users,
  total_first_paid_users,
  attribution_coverage,
  cac_tl,
  cac_status,
  realized_ltv_tl,
  median_realized_ltv_tl,
  total_realized_ltv_tl,
  avg_payment_count_3m,
  ltv_cac_ratio,
  cac_payback_period,
  CASE
    WHEN ltv_cac_ratio < 1 THEN 'Zarar'
    WHEN ltv_cac_ratio < 3 THEN 'Sınırda'
    ELSE 'Kârlı'
  END AS ratio_status,
  -- Diagnostic field: must equal ltv_cac_ratio.
  SAFE_DIVIDE(realized_ltv_tl, cac_tl) AS ratio_formula_check
FROM final
ORDER BY month;
