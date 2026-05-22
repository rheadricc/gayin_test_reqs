-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- New name: BC_UNIT_ECONOMICS_DAILY_01
-- Logic:
--   - TRY-only
--   - PREPAID excluded
--   - daily net revenue / active subscribers / ARPU
--   - month-end MRR on last day of month

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

subs_base AS (
  SELECT
    s.user_id,
    s.status,
    s.payment_option,
    s.currency,
    s.created_at,
    s.inserted_date,
    DATE(s.created_at)   AS created_date,
    DATE(s.valid_until)  AS valid_until_date,
    DATE(s.grace_until)  AS grace_until_date,
    DATE(s.hold_until)   AS hold_until_date,
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
    AND s.status IN ('ACTIVE','CANCELED', 'IN_GRACE', 'ON_HOLD')
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
    a.payment_option,
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
    r.dt AS date,
    DATE_TRUNC(r.dt, MONTH) AS month,
    (r.dt = LAST_DAY(r.dt)) AS is_month_end,
    (r.dt = (SELECT ds_end FROM params)) AS is_selected_end,
    COUNT(DISTINCT r.user_id) AS active_subscribers,
    SUM(r.net_rev_tl) AS net_revenue_tl,
    SAFE_DIVIDE(SUM(r.net_rev_tl), COUNT(DISTINCT r.user_id)) AS arpu_tl
  FROM daily_user_revenue r
  GROUP BY date, month, is_month_end, is_selected_end
),

mrr_eom_daily AS (
  SELECT
    a.dt AS date,
    SUM(
      SAFE_DIVIDE(a.amount_minor, 100.0)
      * ((1.0 - COALESCE(c.commission_rate, 0.00)) * (1.0 - COALESCE(c.tax_rate, 0.20)))
    ) AS mrr_eom_tl
  FROM daily_active_dedup a
  LEFT JOIN payment_option_config c
    ON a.payment_option = c.payment_option
  WHERE a.dt = LAST_DAY(a.dt)
  GROUP BY a.dt
)

SELECT
  k.date,
  k.month,
  k.is_month_end,
  k.is_selected_end,
  k.active_subscribers,
  k.net_revenue_tl,
  k.arpu_tl,
  ROUND(k.arpu_tl, 2) AS arpu_tl_rounded,
  CAST(ROUND(k.arpu_tl * 100, 0) AS INT64) AS arpu_kurus,
  m.mrr_eom_tl
FROM daily_kpis k
LEFT JOIN mrr_eom_daily m
  ON k.date = m.date
ORDER BY k.date;