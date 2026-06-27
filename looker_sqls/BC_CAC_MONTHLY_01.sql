-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Name: BC_CAC_MONTHLY_01
-- Output:
--   channel_scope = 'monthly'
--     Monthly CAC by channel + blended all_channels.
--   channel_scope = 'selected_period'
--     One comparable row per channel over fully matured cohort months.
--     This scope contains CAC, first-three-month realized LTV and LTV/CAC.
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
    LEAST(
      PARSE_DATE('%Y%m%d', @DS_END_DATE),
      DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
    ) AS ds_end,
    LEAST(
      PARSE_DATE('%Y%m%d', @DS_START_DATE),
      -- Selected-period cards require fully matured cohorts even when Looker
      -- sends its default last-28-days range. Read six mature cohort months;
      -- Looker's date dimension still limits the monthly chart presentation.
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

spend_raw AS (
  SELECT
    month,
    LOWER(TRIM(CAST(channel AS STRING))) AS raw_channel,
    spend_tl
  FROM `microgain-9f959.bc_marketing_marts.ads_daily_spend`
  CROSS JOIN params p
  WHERE month BETWEEN DATE_TRUNC(p.cohort_start, MONTH)
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
    UPPER(TRIM(s.payment_option)) AS payment_option,
    s.created_at,
    s.inserted_date,
    DATE(s.created_at) AS payment_date,
    DATE(s.valid_until) AS valid_until_date,
    s.apple_original_transaction_id,
    s.google_original_transaction_id,
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
  FROM paid_payment_base p
  LEFT JOIN tcmb_rates r
    ON p.currency_code != 'TRY'
   AND r.currency_code = p.currency_code
   AND r.rate_date <= p.payment_date
),

paid_payments AS (
  SELECT
    user_id,
    payment_option,
    created_at,
    inserted_date,
    payment_date,
    valid_until_date,
    apple_original_transaction_id,
    google_original_transaction_id,
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

payment_events AS (
  SELECT
    p.user_id,
    p.payment_date,
    p.amount_gross_tl
      * (1.0 - COALESCE(c.commission_rate, 0.00)) AS amount_net_tl
  FROM paid_payments p
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
  FROM paid_payments
  WHERE currency_code = 'TRY' OR rate_to_try IS NOT NULL
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
    AND t.is_paid_touch
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

attributed_paid_user_rows AS (
  SELECT
    user_id,
    first_paid_date,
    month,
    channel
  FROM last_touch_before_paid
),

mature_attributed_users AS (
  SELECT a.*
  FROM attributed_paid_user_rows a
  CROSS JOIN params p
  JOIN spend s
    ON a.month = s.month
   AND a.channel = s.channel
  WHERE DATE_ADD(LAST_DAY(a.month), INTERVAL 3 MONTH) <= p.ds_end
),

user_ltv_3m AS (
  SELECT
    a.user_id,
    a.month,
    a.channel,
    COUNT(*) AS payment_count_3m,
    SUM(e.amount_net_tl) AS realized_ltv_3m_tl
  FROM mature_attributed_users a
  JOIN payment_events e
    ON a.user_id = e.user_id
   AND e.payment_date >= a.first_paid_date
   AND e.payment_date < DATE_ADD(a.first_paid_date, INTERVAL 3 MONTH)
  GROUP BY a.user_id, a.month, a.channel
),

monthly_channel_ltv AS (
  SELECT
    month,
    channel,
    COUNT(DISTINCT user_id) AS ltv_users,
    AVG(realized_ltv_3m_tl) AS realized_ltv_tl,
    APPROX_QUANTILES(realized_ltv_3m_tl, 100)[OFFSET(50)]
      AS median_realized_ltv_tl,
    SUM(realized_ltv_3m_tl) AS total_realized_ltv_tl,
    AVG(payment_count_3m) AS avg_payment_count_3m
  FROM user_ltv_3m
  GROUP BY month, channel
),

monthly_all_ltv AS (
  SELECT
    month,
    COUNT(DISTINCT user_id) AS ltv_users,
    AVG(realized_ltv_3m_tl) AS realized_ltv_tl,
    APPROX_QUANTILES(realized_ltv_3m_tl, 100)[OFFSET(50)]
      AS median_realized_ltv_tl,
    SUM(realized_ltv_3m_tl) AS total_realized_ltv_tl,
    AVG(payment_count_3m) AS avg_payment_count_3m
  FROM user_ltv_3m
  GROUP BY month
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
    'monthly' AS channel_scope,
    1 AS sort_order,
    s.month,
    s.month AS cohort_start_month,
    s.month AS cohort_end_month,
    CASE
      WHEN DATE_ADD(LAST_DAY(s.month), INTERVAL 3 MONTH)
             <= (SELECT ds_end FROM params)
        THEN DATE_ADD(LAST_DAY(s.month), INTERVAL 3 MONTH)
    END AS observation_window_end,
    s.channel,
    s.spend_tl,
    COALESCE(a.new_paid_users, 0) AS new_paid_users,
    SAFE_DIVIDE(s.spend_tl, COALESCE(a.new_paid_users, 0)) AS cac_tl,
    d.total_first_paid_users,
    SAFE_DIVIDE(COALESCE(a.new_paid_users, 0), d.total_first_paid_users) AS attribution_coverage,
    l.realized_ltv_tl,
    l.median_realized_ltv_tl,
    l.total_realized_ltv_tl,
    l.avg_payment_count_3m,
    SAFE_DIVIDE(
      l.realized_ltv_tl,
      SAFE_DIVIDE(s.spend_tl, COALESCE(a.new_paid_users, 0))
    ) AS ltv_cac_ratio,
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
  LEFT JOIN monthly_channel_ltv l
    ON s.month = l.month
   AND s.channel = l.channel
),

all_channels_results AS (
  SELECT
    'monthly' AS channel_scope,
    99 AS sort_order,
    s.month,
    s.month AS cohort_start_month,
    s.month AS cohort_end_month,
    CASE
      WHEN DATE_ADD(LAST_DAY(s.month), INTERVAL 3 MONTH)
             <= (SELECT ds_end FROM params)
        THEN DATE_ADD(LAST_DAY(s.month), INTERVAL 3 MONTH)
    END AS observation_window_end,
    'all_channels' AS channel,
    SUM(s.spend_tl) AS spend_tl,
    SUM(COALESCE(a.new_paid_users, 0)) AS new_paid_users,
    SAFE_DIVIDE(SUM(s.spend_tl), SUM(COALESCE(a.new_paid_users, 0))) AS cac_tl,
    ANY_VALUE(d.total_first_paid_users) AS total_first_paid_users,
    SAFE_DIVIDE(SUM(COALESCE(a.new_paid_users, 0)), ANY_VALUE(d.total_first_paid_users)) AS attribution_coverage,
    ANY_VALUE(l.realized_ltv_tl) AS realized_ltv_tl,
    ANY_VALUE(l.median_realized_ltv_tl) AS median_realized_ltv_tl,
    ANY_VALUE(l.total_realized_ltv_tl) AS total_realized_ltv_tl,
    ANY_VALUE(l.avg_payment_count_3m) AS avg_payment_count_3m,
    SAFE_DIVIDE(
      ANY_VALUE(l.realized_ltv_tl),
      SAFE_DIVIDE(
        SUM(s.spend_tl),
        SUM(COALESCE(a.new_paid_users, 0))
      )
    ) AS ltv_cac_ratio,
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
  LEFT JOIN monthly_all_ltv l
    ON s.month = l.month
  GROUP BY s.month
),

selected_channel_results AS (
  SELECT
    'selected_period' AS channel_scope,
    1 AS sort_order,
    DATE_TRUNC((SELECT ds_end FROM params), MONTH) AS month,
    MIN(c.month) AS cohort_start_month,
    MAX(c.month) AS cohort_end_month,
    DATE_ADD(LAST_DAY(MAX(c.month)), INTERVAL 3 MONTH)
      AS observation_window_end,
    c.channel,
    SUM(c.spend_tl) AS spend_tl,
    SUM(c.new_paid_users) AS new_paid_users,
    SAFE_DIVIDE(SUM(c.spend_tl), SUM(c.new_paid_users)) AS cac_tl,
    SUM(c.total_first_paid_users) AS total_first_paid_users,
    SAFE_DIVIDE(
      SUM(c.new_paid_users),
      SUM(c.total_first_paid_users)
    ) AS attribution_coverage,
    SAFE_DIVIDE(
      SUM(c.total_realized_ltv_tl),
      SUM(c.new_paid_users)
    ) AS realized_ltv_tl,
    APPROX_QUANTILES(c.median_realized_ltv_tl, 100)[OFFSET(50)]
      AS median_realized_ltv_tl,
    SUM(c.total_realized_ltv_tl) AS total_realized_ltv_tl,
    SAFE_DIVIDE(
      SUM(c.avg_payment_count_3m * c.new_paid_users),
      SUM(c.new_paid_users)
    ) AS avg_payment_count_3m,
    SAFE_DIVIDE(
      SAFE_DIVIDE(
        SUM(c.total_realized_ltv_tl),
        SUM(c.new_paid_users)
      ),
      SAFE_DIVIDE(SUM(c.spend_tl), SUM(c.new_paid_users))
    ) AS ltv_cac_ratio,
    CASE
      WHEN SUM(c.spend_tl) > 0 AND SUM(c.new_paid_users) > 0 THEN 'ok'
      WHEN SUM(c.spend_tl) > 0 AND SUM(c.new_paid_users) = 0
        THEN 'spend_var_user_yok'
      ELSE 'spend_yok_user_yok'
    END AS cac_status
  FROM channel_results c
  CROSS JOIN params p
  WHERE DATE_ADD(LAST_DAY(c.month), INTERVAL 3 MONTH) <= p.ds_end
  GROUP BY c.channel
),

selected_all_channels_result AS (
  SELECT
    'selected_period' AS channel_scope,
    99 AS sort_order,
    DATE_TRUNC((SELECT ds_end FROM params), MONTH) AS month,
    MIN(c.month) AS cohort_start_month,
    MAX(c.month) AS cohort_end_month,
    DATE_ADD(LAST_DAY(MAX(c.month)), INTERVAL 3 MONTH)
      AS observation_window_end,
    'all_channels' AS channel,
    SUM(c.spend_tl) AS spend_tl,
    SUM(c.new_paid_users) AS new_paid_users,
    SAFE_DIVIDE(SUM(c.spend_tl), SUM(c.new_paid_users)) AS cac_tl,
    SUM(c.total_first_paid_users) AS total_first_paid_users,
    SAFE_DIVIDE(
      SUM(c.new_paid_users),
      SUM(c.total_first_paid_users)
    ) AS attribution_coverage,
    SAFE_DIVIDE(
      SUM(c.total_realized_ltv_tl),
      SUM(c.new_paid_users)
    ) AS realized_ltv_tl,
    APPROX_QUANTILES(c.median_realized_ltv_tl, 100)[OFFSET(50)]
      AS median_realized_ltv_tl,
    SUM(c.total_realized_ltv_tl) AS total_realized_ltv_tl,
    SAFE_DIVIDE(
      SUM(c.avg_payment_count_3m * c.new_paid_users),
      SUM(c.new_paid_users)
    ) AS avg_payment_count_3m,
    SAFE_DIVIDE(
      SAFE_DIVIDE(
        SUM(c.total_realized_ltv_tl),
        SUM(c.new_paid_users)
      ),
      SAFE_DIVIDE(SUM(c.spend_tl), SUM(c.new_paid_users))
    ) AS ltv_cac_ratio,
    CASE
      WHEN SUM(c.spend_tl) > 0 AND SUM(c.new_paid_users) > 0 THEN 'ok'
      WHEN SUM(c.spend_tl) > 0 AND SUM(c.new_paid_users) = 0
        THEN 'spend_var_user_yok'
      ELSE 'spend_yok_user_yok'
    END AS cac_status
  FROM all_channels_results c
  CROSS JOIN params p
  WHERE DATE_ADD(LAST_DAY(c.month), INTERVAL 3 MONTH) <= p.ds_end
),

all_outputs AS (
  SELECT * FROM channel_results

  UNION ALL

  SELECT * FROM all_channels_results

  UNION ALL

  SELECT * FROM selected_channel_results

  UNION ALL

  SELECT * FROM selected_all_channels_result
)

SELECT
  *,
  SAFE_DIVIDE(realized_ltv_tl, cac_tl) AS ratio_formula_check
FROM all_outputs
ORDER BY channel_scope, month, sort_order, channel;
