-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Name: BC_CHANNEL_LTVCAC_REALIZED_01
-- Purpose: "Reklam Kanalı LTV" chart only.
-- Output: exactly one row per channel for the latest six fully matured
-- acquisition-cohort months available as of @DS_END_DATE.
--
-- Looker setup:
--   Dimension = channel
--   Metric    = avg_realized_ltv_tl
--   No channel_scope filter is required.
--
-- Only channels with automated spend in ads_daily_spend are returned. A GA4
-- touch alone cannot create a channel row. This prevents an old TikTok touch
-- from appearing when no comparable TikTok spend source exists.
-- Standardized:
--   - acquisition cohort = first paid users in selected range with a complete
--     three-month observation window
--   - attribution = last eligible paid touch within 30 days before first paid
--   - spend source = bc_marketing_marts.ads_daily_spend
--   - LTV = actual net payment collections in each user's first three months
--   - churned users are included
--   - CAC spend and users use the same mature acquisition-cohort months
--   - Foreign currencies converted to TRY with TCMB forex_buying rate
--   - If exact payment date rate is missing, latest available TCMB rate before payment date is used
--   - raw minor-unit amount must be > 101
--   - channels with spend but 0 attributed users are preserved

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    LEAST(
      PARSE_DATE('%Y%m%d', @DS_END_DATE),
      DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
    ) AS ds_end,
    LEAST(
      PARSE_DATE('%Y%m%d', @DS_START_DATE),
      -- Read enough history to find the latest six fully matured cohort months
      -- even when Looker sends its default last-28-days date range.
      DATE_SUB(
        DATE_TRUNC(
          DATE_SUB(
            LEAST(
              PARSE_DATE('%Y%m%d', @DS_END_DATE),
              DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
            ),
            INTERVAL 3 MONTH
          ),
          MONTH
        ),
        INTERVAL 6 MONTH
      )
    ) AS cohort_start
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
    SAFE_DIVIDE(CAST(forex_buying AS FLOAT64), NULLIF(CAST(unit AS FLOAT64), 0.0)) AS rate_to_try
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
    SAFE_DIVIDE(CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64), 100.0) AS amount_original
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
  FROM payment_base s
  LEFT JOIN tcmb_rates r
    ON s.currency_code != 'TRY'
   AND r.currency_code = s.currency_code
   AND r.rate_date <= s.payment_date
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
  SELECT user_id, payment_option, payment_date, amount_gross_tl
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
    p.amount_gross_tl
      * (1.0 - COALESCE(c.commission_rate, 0.00)) AS amount_net_tl
  FROM payment_events_dedup p
  LEFT JOIN payment_option_config c
    ON p.payment_option = c.payment_option
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
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 101
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
    rate_to_try,
    CASE
      WHEN currency_code = 'TRY' THEN amount_original
      ELSE amount_original * rate_to_try
    END AS amount_gross_tl
  FROM paid_payment_rate_candidates
  WHERE currency_code = 'TRY'
     OR rate_rn = 1
),

first_paid AS (
  SELECT
    user_id,
    MIN(payment_date) AS first_paid_date
  FROM paid_payments
  WHERE currency_code = 'TRY' OR rate_to_try IS NOT NULL
  GROUP BY user_id
),

first_paid_selected AS (
  SELECT
    fp.user_id,
    fp.first_paid_date,
    DATE_TRUNC(fp.first_paid_date, MONTH) AS cohort_month,
    DATE_ADD(fp.first_paid_date, INTERVAL 3 MONTH) AS observation_end_date
  FROM first_paid fp
  CROSS JOIN params p
  WHERE fp.first_paid_date BETWEEN p.cohort_start AND p.ds_end
    -- Use only fully matured cohort months. A partial March cohort must not be
    -- divided into the full March ad spend before every March payer completes
    -- the same three-month observation window.
    AND DATE_ADD(
          LAST_DAY(DATE_TRUNC(fp.first_paid_date, MONTH)),
          INTERVAL 3 MONTH
        ) <= p.ds_end
),

user_realized_ltv AS (
  SELECT
    f.user_id,
    COUNT(*) AS payment_count_3m,
    SUM(e.amount_net_tl) AS user_realized_ltv_tl
  FROM first_paid_selected f
  JOIN payment_events e
    ON f.user_id = e.user_id
   AND e.payment_date >= f.first_paid_date
   AND e.payment_date < f.observation_end_date
  GROUP BY f.user_id
),

normalized_touches AS (
  SELECT
    CAST(g.user_id AS STRING) AS user_id,
    g.touch_date,
    LOWER(TRIM(CAST(g.source AS STRING))) AS source,
    LOWER(TRIM(CAST(g.medium AS STRING))) AS medium,
    LOWER(TRIM(COALESCE(CAST(g.campaign AS STRING), 'null'))) AS campaign,
    REGEXP_CONTAINS(
      LOWER(TRIM(COALESCE(CAST(g.medium AS STRING), ''))),
      r'(^|[-_])(cpc|cpa|cpm|paid|conversion)([-_]|$)|instagram_(reels|stories|feed)|facebook_(mobile_|desktop_)?(reels|feed|stories)|facebook_right_column'
    ) AS is_paid_touch,
    CASE
      WHEN REGEXP_CONTAINS(LOWER(TRIM(CONCAT(COALESCE(CAST(g.mapped_channel AS STRING), ''), ' ', COALESCE(CAST(g.source AS STRING), ''), ' ', COALESCE(CAST(g.medium AS STRING), ''), ' ', COALESCE(CAST(g.campaign AS STRING), '')))), r'google|adwords|gads|youtube') THEN 'google'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(CONCAT(COALESCE(CAST(g.mapped_channel AS STRING), ''), ' ', COALESCE(CAST(g.source AS STRING), ''), ' ', COALESCE(CAST(g.medium AS STRING), ''), ' ', COALESCE(CAST(g.campaign AS STRING), '')))), r'meta|facebook|instagram|fb|ig|l\.instagram|m\.facebook|l\.facebook') THEN 'meta'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(CONCAT(COALESCE(CAST(g.mapped_channel AS STRING), ''), ' ', COALESCE(CAST(g.source AS STRING), ''), ' ', COALESCE(CAST(g.medium AS STRING), ''), ' ', COALESCE(CAST(g.campaign AS STRING), '')))), r'tiktok|tik_tok') THEN 'tiktok'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(CONCAT(COALESCE(CAST(g.mapped_channel AS STRING), ''), ' ', COALESCE(CAST(g.source AS STRING), ''), ' ', COALESCE(CAST(g.medium AS STRING), ''), ' ', COALESCE(CAST(g.campaign AS STRING), '')))), r'influencer|creator') THEN 'influencer'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(CONCAT(COALESCE(CAST(g.mapped_channel AS STRING), ''), ' ', COALESCE(CAST(g.source AS STRING), ''), ' ', COALESCE(CAST(g.medium AS STRING), ''), ' ', COALESCE(CAST(g.campaign AS STRING), '')))), r'affiliate|partner') THEN 'affiliate'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(CONCAT(COALESCE(CAST(g.mapped_channel AS STRING), ''), ' ', COALESCE(CAST(g.source AS STRING), ''), ' ', COALESCE(CAST(g.medium AS STRING), ''), ' ', COALESCE(CAST(g.campaign AS STRING), '')))), r'organic|direct|seo|referral|email|push|sms|crm') THEN 'organic'
      ELSE 'other'
    END AS channel
  FROM `microgain-9f959.bc_marketing_raw.ga4_first_non_direct_touch` g
  CROSS JOIN params p
  WHERE g.touch_date BETWEEN DATE_SUB(p.cohort_start, INTERVAL 30 DAY)
                         AND p.ds_end
),

user_channel_full AS (
  SELECT
    fp.user_id,
    fp.first_paid_date,
    fp.cohort_month,
    COALESCE(t.channel, 'other') AS channel
  FROM first_paid_selected fp
  LEFT JOIN normalized_touches t
    ON fp.user_id = t.user_id
   AND DATE_DIFF(fp.first_paid_date, t.touch_date, DAY) BETWEEN 0 AND 30
   AND t.is_paid_touch
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY fp.user_id
    ORDER BY
      t.touch_date DESC,
      CASE WHEN t.medium IN ('cpc', 'cpa', 'paid', 'paid_social', 'search_cpc') THEN 1 ELSE 0 END DESC,
      t.channel
  ) = 1
),

spend_monthly AS (
  SELECT
    month,
    CASE
      WHEN REGEXP_CONTAINS(LOWER(TRIM(channel)), r'google|adwords|gads|youtube') THEN 'google'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(channel)), r'meta|facebook|instagram|fb|ig|paid_social|social') THEN 'meta'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(channel)), r'tiktok|tik_tok') THEN 'tiktok'
      ELSE LOWER(TRIM(channel))
    END AS channel,
    SUM(spend_tl) AS spend_tl
  FROM `microgain-9f959.bc_marketing_marts.ads_daily_spend`
  CROSS JOIN params p
  WHERE month BETWEEN DATE_TRUNC(p.cohort_start, MONTH)
                  AND DATE_TRUNC(p.ds_end, MONTH)
  GROUP BY month, channel
),

mature_cohort_months AS (
  SELECT month
  FROM (
    SELECT DISTINCT cohort_month AS month
    FROM first_paid_selected
  )
  QUALIFY DENSE_RANK() OVER (ORDER BY month DESC) <= 6
),

eligible_spend_monthly AS (
  SELECT s.*
  FROM spend_monthly s
  JOIN mature_cohort_months m
    ON s.month = m.month
),

selected_channel_user_metrics AS (
  SELECT
    uc.channel,
    COUNT(DISTINCT uc.user_id) AS users,
    AVG(COALESCE(l.user_realized_ltv_tl, 0)) AS avg_realized_ltv_tl,
    APPROX_QUANTILES(COALESCE(l.user_realized_ltv_tl, 0), 100)[OFFSET(50)] AS median_realized_ltv_tl,
    SUM(COALESCE(l.user_realized_ltv_tl, 0)) AS total_realized_ltv_tl,
    AVG(COALESCE(l.payment_count_3m, 0)) AS avg_payment_count_3m
  FROM user_channel_full uc
  JOIN eligible_spend_monthly s
    ON uc.cohort_month = s.month
   AND uc.channel = s.channel
  LEFT JOIN user_realized_ltv l
    ON uc.user_id = l.user_id
  WHERE uc.channel IN ('google', 'meta', 'tiktok')
  GROUP BY uc.channel
),

selected_spend AS (
  SELECT channel, SUM(spend_tl) AS spend_tl
  FROM eligible_spend_monthly
  GROUP BY channel
),

selected_window AS (
  SELECT
    MIN(month) AS cohort_start_month,
    MAX(month) AS cohort_end_month,
    DATE_ADD(LAST_DAY(MAX(month)), INTERVAL 3 MONTH) AS observation_window_end,
    COUNT(DISTINCT month) AS loaded_cohort_month_count
  FROM eligible_spend_monthly
),

selected_channel_final AS (
  SELECT
    'selected_period' AS channel_scope,
    -- Tag the summary with the report end month so Looker's default current
    -- date filter does not hide it. The true cohort dates are separate fields.
    DATE_TRUNC((SELECT ds_end FROM params), MONTH) AS month,
    w.cohort_start_month,
    w.cohort_end_month,
    w.observation_window_end,
    w.loaded_cohort_month_count,
    CASE
      WHEN w.loaded_cohort_month_count = 6 THEN 'complete'
      ELSE 'partial_backfill'
    END AS cohort_window_status,
    s.channel,
    COALESCE(m.users, 0) AS users,
    s.spend_tl,
    SAFE_DIVIDE(s.spend_tl, COALESCE(m.users, 0)) AS cac_tl,
    COALESCE(m.avg_realized_ltv_tl, 0) AS avg_realized_ltv_tl,
    COALESCE(m.median_realized_ltv_tl, 0) AS median_realized_ltv_tl,
    COALESCE(m.total_realized_ltv_tl, 0) AS total_realized_ltv_tl,
    COALESCE(m.avg_payment_count_3m, 0) AS avg_payment_count_3m,
    SAFE_DIVIDE(
      COALESCE(m.avg_realized_ltv_tl, 0),
      SAFE_DIVIDE(s.spend_tl, COALESCE(m.users, 0))
    ) AS ltv_cac_ratio,
    CASE
      WHEN s.spend_tl > 0 AND COALESCE(m.users, 0) > 0 THEN 'ok'
      WHEN s.spend_tl > 0 AND COALESCE(m.users, 0) = 0 THEN 'spend_var_user_yok'
      ELSE 'spend_yok'
    END AS cac_status
  FROM selected_spend s
  LEFT JOIN selected_channel_user_metrics m
    ON s.channel = m.channel
  CROSS JOIN selected_window w
)

SELECT
  *,
  -- Diagnostic field: this must be identical to ltv_cac_ratio.
  SAFE_DIVIDE(avg_realized_ltv_tl, cac_tl) AS ratio_formula_check
FROM selected_channel_final
ORDER BY channel;
