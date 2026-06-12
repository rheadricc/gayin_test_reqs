-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Name: BC_LTVCAC_REALIZED_MONTHLY_01
-- Output: MONTH grain only
-- Standardized:
--   - Realized LTV uses cumulative realized net revenue
--   - TRY + foreign currency payments included
--   - Foreign currencies converted to TRY with TCMB forex_buying rate
--   - If exact payment date rate is missing, latest available TCMB rate before payment date is used
--   - CAC uses ads_daily_spend + last eligible paid touch in 30 days before first payment
--   - Includes ARPU so CAC Payback Period = CAC / ARPU can be shown from same dataset

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
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

/* =========================
   CAC PART - STANDARDIZED
   ========================= */

spend_raw AS (
  SELECT
    month,
    LOWER(TRIM(CAST(channel AS STRING))) AS raw_channel,
    spend_tl
  FROM `microgain-9f959.bc_marketing_marts.ads_daily_spend`
  CROSS JOIN params p
  WHERE month BETWEEN DATE_TRUNC(p.ds_start, MONTH)
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

cac_date_bounds AS (
  SELECT
    MIN(month) AS min_month,
    MAX(month) AS max_month
  FROM spend
),

paid_payment_base AS (
  SELECT
    CAST(s.user_id AS STRING) AS user_id,
    DATE(s.created_at) AS payment_date,
    UPPER(TRIM(s.currency)) AS currency_code,
    SAFE_DIVIDE(CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64), 100.0) AS amount_original
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN cac_date_bounds b
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND UPPER(TRIM(s.payment_option)) != 'PREPAID'
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 0
    AND DATE(s.created_at) <= LAST_DAY(b.max_month)
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

first_paid AS (
  SELECT
    user_id,
    MIN(payment_date) AS first_paid_date
  FROM paid_payments
  WHERE currency_code = 'TRY'
     OR rate_to_try IS NOT NULL
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
    CASE
      WHEN REGEXP_CONTAINS(LOWER(TRIM(CONCAT(COALESCE(CAST(g.mapped_channel AS STRING), ''), ' ', COALESCE(CAST(g.source AS STRING), ''), ' ', COALESCE(CAST(g.medium AS STRING), ''), ' ', COALESCE(CAST(g.campaign AS STRING), '')))), r'google|adwords|gads|youtube') THEN 'google'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(CONCAT(COALESCE(CAST(g.mapped_channel AS STRING), ''), ' ', COALESCE(CAST(g.source AS STRING), ''), ' ', COALESCE(CAST(g.medium AS STRING), ''), ' ', COALESCE(CAST(g.campaign AS STRING), '')))), r'meta|facebook|instagram|fb|ig|l\.instagram|m\.facebook|l\.facebook') THEN 'meta'
      WHEN REGEXP_CONTAINS(LOWER(TRIM(CONCAT(COALESCE(CAST(g.mapped_channel AS STRING), ''), ' ', COALESCE(CAST(g.source AS STRING), ''), ' ', COALESCE(CAST(g.medium AS STRING), ''), ' ', COALESCE(CAST(g.campaign AS STRING), '')))), r'tiktok|tik_tok') THEN 'tiktok'
      ELSE NULL
    END AS channel
  FROM `microgain-9f959.bc_marketing_raw.ga4_first_non_direct_touch` g
  CROSS JOIN cac_date_bounds b
  WHERE g.touch_date BETWEEN DATE_SUB(b.min_month, INTERVAL 30 DAY)
                         AND LAST_DAY(b.max_month)
),

last_touch_before_paid AS (
  SELECT
    fp.user_id,
    fp.first_paid_date,
    DATE_TRUNC(fp.first_paid_date, MONTH) AS month,
    t.channel,
    t.touch_date,
    t.medium
  FROM first_paid fp
  JOIN normalized_touches t
    ON fp.user_id = t.user_id
  CROSS JOIN cac_date_bounds b
  WHERE fp.first_paid_date BETWEEN b.min_month AND LAST_DAY(b.max_month)
    AND t.channel IN ('google', 'meta', 'tiktok')
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

monthly_blended_cac AS (
  SELECT
    s.month,
    SUM(s.spend_tl) AS spend_tl,
    SUM(COALESCE(a.new_paid_users, 0)) AS new_paid_users,
    SAFE_DIVIDE(SUM(s.spend_tl), SUM(COALESCE(a.new_paid_users, 0))) AS cac_tl,
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
  GROUP BY s.month
),

/* =========================
   REALIZED LTV + ARPU PART
   ========================= */

payment_option_config AS (
  SELECT 'APP_STORE'       AS payment_option, 0.30 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'PLAY_STORE'      AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'MOBILE_PAYMENT'  AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'CRAFTGATE'       AS payment_option, 0.00 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'IYZICO'          AS payment_option, 0.03 AS commission_rate, 0.20 AS tax_rate
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

monthly_realized_ltv AS (
  SELECT
    a.month,
    COUNT(DISTINCT a.user_id) AS active_user_count,
    t.total_revenue_tl,
    t.avg_daily_active_users,
    SAFE_DIVIDE(t.total_revenue_tl, t.avg_daily_active_users) AS arpu_tl,
    AVG(COALESCE(c.realized_ltv_tl_to_month_end, 0)) AS realized_ltv_tl
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
),

/* =========================
   FINAL
   ========================= */

final AS (
  SELECT
    l.month,
    l.active_user_count,
    l.total_revenue_tl,
    l.avg_daily_active_users,
    l.arpu_tl,
    c.spend_tl,
    c.new_paid_users,
    c.cac_tl,
    c.cac_status,
    l.realized_ltv_tl,
    SAFE_DIVIDE(l.realized_ltv_tl, c.cac_tl) AS ltv_cac_ratio,
    SAFE_DIVIDE(c.cac_tl, l.arpu_tl) AS cac_payback_period,
    CASE
      WHEN SAFE_DIVIDE(l.realized_ltv_tl, c.cac_tl) < 1 THEN 'Zarar'
      WHEN SAFE_DIVIDE(l.realized_ltv_tl, c.cac_tl) < 3 THEN 'Sınırda'
      ELSE 'Kârlı'
    END AS ratio_status
  FROM monthly_realized_ltv l
  LEFT JOIN monthly_blended_cac c
    ON l.month = c.month
)

SELECT
  month,
  active_user_count,
  total_revenue_tl,
  avg_daily_active_users,
  arpu_tl,
  spend_tl,
  new_paid_users,
  cac_tl,
  cac_status,
  realized_ltv_tl,
  ltv_cac_ratio,
  cac_payback_period,
  ratio_status
FROM final
ORDER BY month;