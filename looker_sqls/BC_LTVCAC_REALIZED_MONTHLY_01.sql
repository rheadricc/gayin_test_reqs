-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Name: BC_LTVCAC_REALIZED_MONTHLY_01
-- Output: MONTH grain only
-- Logic:
--   - Realized LTV uses cumulative realized net revenue
--   - CAC uses TRY-only attributed new paid users
--   - Includes ARPU so CAC Payback Period = CAC / ARPU can be shown from same dataset

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

/* =========================
   CAC PART
   ========================= */

spend AS (
  SELECT
    month,
    LOWER(channel) AS channel,
    SUM(spend_tl) AS spend_tl
  FROM `microgain-9f959.bc_marketing_raw.manual_monthly_spend`
  CROSS JOIN params p
  WHERE LOWER(channel) IN ('google', 'meta', 'tiktok')
    AND month BETWEEN DATE_TRUNC(p.ds_start, MONTH) AND DATE_TRUNC(p.ds_end, MONTH)
  GROUP BY month, channel
),

cac_date_bounds AS (
  SELECT
    MIN(month) AS min_month,
    MAX(month) AS max_month
  FROM spend
),

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

attributed_paid_users AS (
  SELECT
    DATE_TRUNC(fp.first_paid_date, MONTH) AS month,
    g.mapped_channel AS channel,
    COUNT(DISTINCT fp.user_id) AS new_paid_users
  FROM first_paid fp
  JOIN `microgain-9f959.bc_marketing_raw.ga4_first_non_direct_touch` g
    ON fp.user_id = g.user_id
  CROSS JOIN cac_date_bounds b
  WHERE fp.first_paid_date BETWEEN b.min_month AND LAST_DAY(b.max_month)
    AND DATE_DIFF(fp.first_paid_date, g.touch_date, DAY) BETWEEN 0 AND 30
  GROUP BY month, channel
),

monthly_blended_cac AS (
  SELECT
    s.month,
    SUM(s.spend_tl) AS spend_tl,
    SUM(COALESCE(a.new_paid_users, 0)) AS new_paid_users,
    SAFE_DIVIDE(SUM(s.spend_tl), SUM(COALESCE(a.new_paid_users, 0))) AS cac_tl
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
    AND UPPER(currency) = 'TRY'
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
  realized_ltv_tl,
  ltv_cac_ratio,
  cac_payback_period,
  ratio_status
FROM final
ORDER BY month;