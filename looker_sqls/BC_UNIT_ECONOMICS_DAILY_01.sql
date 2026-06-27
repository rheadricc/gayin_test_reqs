-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- New name: BC_UNIT_ECONOMICS_DAILY_01
-- Logic:
--   - TRY + foreign currency payments included
--   - foreign currencies converted to TRY with TCMB forex_buying rate
--   - if exact payment date rate is missing, latest available TCMB rate before payment date is used
--   - PREPAID excluded
-- METRIC DICTIONARY:
--   gross_* = customer-facing amount before payment-provider commission.
--   net_*   = gross amount minus payment-provider commission. Tax is NOT deducted.
--   *_collections_* = actual payment-event cash flow grouped by payment date.
--   *_accrued_revenue_* = subscription amount allocated across entitled days.
--   *_mrr_* = recurring monthly run-rate snapshot of paid subscribers on one date.
--              MRR is NOT the cash collected during that month.
--   previous_month_* = previous completed calendar month relative to @DS_END_DATE.
--   trailing_30d_*   = @DS_END_DATE and the preceding 29 days (30 days inclusive).
--   selected_period_* = exactly @DS_START_DATE through @DS_END_DATE.
--
-- LOOKER USAGE:
--   - "MRR BO" card: net_mrr_previous_month_end_tl
--   - "Son Tamamlanmış Ay Net Tahsilat": previous_month_net_collections_tl
--   - "Son 30 Gün Net Tahsilat": trailing_30d_net_collections_tl
--   - Daily revenue trend: net_accrued_revenue_tl
--   - Paid subscriber: any subscription row whose created_at <= day <= valid_until.
--     IN_GRACE / ON_HOLD do not extend the paid period; EXPIRED rows remain
--     available for historically correct paid-subscriber counts.
--   - Collection metrics require raw minor-unit amount > 101.

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    LEAST(
      PARSE_DATE('%Y%m%d', @DS_END_DATE),
      DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
    ) AS ds_end,
    DATE_TRUNC(
      DATE_SUB(
        LEAST(
          PARSE_DATE('%Y%m%d', @DS_END_DATE),
          DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
        ),
        INTERVAL 1 MONTH
      ),
      MONTH
    ) AS previous_month_start,
    LAST_DAY(
      DATE_SUB(
        LEAST(
          PARSE_DATE('%Y%m%d', @DS_END_DATE),
          DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
        ),
        INTERVAL 1 MONTH
      )
    ) AS previous_month_end,
    DATE_SUB(
      LEAST(
        PARSE_DATE('%Y%m%d', @DS_END_DATE),
        DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
      ),
      INTERVAL 29 DAY
    ) AS trailing_30d_start
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

subs_base AS (
  SELECT
    s.user_id,
    s.status,
    s.payment_option,
    s.currency,
    s.created_at,
    s.inserted_date,
    s.apple_original_transaction_id,
    s.google_original_transaction_id,
    DATE(s.created_at)   AS created_date,
    DATE(s.valid_until)  AS valid_until_date,
    DATE(s.grace_until)  AS grace_until_date,
    DATE(s.hold_until)   AS hold_until_date,
    DATE(s.valid_until) AS paid_end_date,
    UPPER(s.currency) AS currency_code,
    SAFE_DIVIDE(CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64), 100.0) AS amount_original
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN params p
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND s.payment_option != 'PREPAID'
    AND s.status IN ('ACTIVE', 'CANCELED', 'IN_GRACE', 'ON_HOLD', 'EXPIRED')
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 101
    AND DATE(s.created_at) <= p.ds_end
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

payment_events_dedup AS (
  SELECT
    payment_date,
    user_id,
    payment_option,
    amount_gross_tl
  FROM (
    SELECT
      DATE(s.created_at) AS payment_date,
      s.user_id,
      s.payment_option,
      s.amount_gross_tl,
      ROW_NUMBER() OVER (
        PARTITION BY
          s.user_id,
          s.payment_option,
          s.currency_code,
          s.created_at,
          s.valid_until_date,
          s.apple_original_transaction_id,
          s.google_original_transaction_id,
          CAST(s.amount_original AS STRING)
        ORDER BY s.inserted_date DESC
      ) AS rn
    FROM subs_converted s
    WHERE s.amount_gross_tl IS NOT NULL
  )
  WHERE rn = 1
),

payment_events AS (
  SELECT
    p.payment_date,
    p.user_id,
    p.payment_option,
    p.amount_gross_tl,
    p.amount_gross_tl
      * (1.0 - COALESCE(c.commission_rate, 0.00)) AS amount_net_tl
  FROM payment_events_dedup p
  LEFT JOIN payment_option_config c
    ON p.payment_option = c.payment_option
),

collection_summary AS (
  SELECT
    COUNTIF(
      e.payment_date BETWEEN p.ds_start AND p.ds_end
    ) AS selected_period_transaction_count,
    SUM(
      IF(
        e.payment_date BETWEEN p.ds_start AND p.ds_end,
        e.amount_gross_tl,
        0
      )
    ) AS selected_period_gross_collections_tl,
    SUM(
      IF(
        e.payment_date BETWEEN p.ds_start AND p.ds_end,
        e.amount_net_tl,
        0
      )
    ) AS selected_period_net_collections_tl,
    COUNTIF(
      e.payment_date BETWEEN p.previous_month_start AND p.previous_month_end
    ) AS previous_month_transaction_count,
    SUM(
      IF(
        e.payment_date BETWEEN p.previous_month_start AND p.previous_month_end,
        e.amount_gross_tl,
        0
      )
    ) AS previous_month_gross_collections_tl,
    SUM(
      IF(
        e.payment_date BETWEEN p.previous_month_start AND p.previous_month_end,
        e.amount_net_tl,
        0
      )
    ) AS previous_month_net_collections_tl,
    COUNTIF(
      e.payment_date BETWEEN p.trailing_30d_start AND p.ds_end
    ) AS trailing_30d_transaction_count,
    SUM(
      IF(
        e.payment_date BETWEEN p.trailing_30d_start AND p.ds_end,
        e.amount_gross_tl,
        0
      )
    ) AS trailing_30d_gross_collections_tl,
    SUM(
      IF(
        e.payment_date BETWEEN p.trailing_30d_start AND p.ds_end,
        e.amount_net_tl,
        0
      )
    ) AS trailing_30d_net_collections_tl
  FROM payment_events e
  CROSS JOIN params p
  WHERE e.payment_date BETWEEN
    LEAST(p.ds_start, p.previous_month_start, p.trailing_30d_start)
    AND p.ds_end
),

monthly_collections AS (
  SELECT
    DATE_TRUNC(e.payment_date, MONTH) AS month,
    COUNT(*) AS monthly_transaction_count,
    SUM(e.amount_gross_tl) AS monthly_gross_collections_tl,
    SUM(e.amount_net_tl) AS monthly_net_collections_tl
  FROM payment_events e
  CROSS JOIN params p
  WHERE e.payment_date BETWEEN p.ds_start AND p.ds_end
  GROUP BY month
),

subs AS (
  SELECT *
  FROM subs_converted
  CROSS JOIN params p
  WHERE paid_end_date >= p.ds_start
    AND amount_gross_tl IS NOT NULL
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
  JOIN subs s
    ON d.dt BETWEEN s.created_date AND s.paid_end_date
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
    a.payment_option,
    SAFE_DIVIDE(
      a.amount_gross_tl
      * (1.0 - COALESCE(c.commission_rate, 0.00)),
      EXTRACT(DAY FROM LAST_DAY(a.dt))
    ) AS net_accrued_revenue_tl
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
    COUNT(DISTINCT r.user_id) AS paid_subscribers,
    SUM(r.net_accrued_revenue_tl) AS net_accrued_revenue_tl,
    SAFE_DIVIDE(
      SUM(r.net_accrued_revenue_tl),
      COUNT(DISTINCT r.user_id)
    ) AS daily_net_arpu_tl
  FROM daily_user_revenue r
  GROUP BY date, month, is_month_end, is_selected_end
),

monthly_kpis AS (
  SELECT
    month,
    SUM(net_accrued_revenue_tl) AS monthly_net_accrued_revenue_tl,
    AVG(paid_subscribers) AS avg_daily_paid_subscribers,
    SAFE_DIVIDE(
      SUM(net_accrued_revenue_tl),
      AVG(paid_subscribers)
    ) AS monthly_net_arpu_tl
  FROM daily_kpis
  GROUP BY month
),

selected_period_kpis AS (
  SELECT
    SAFE_DIVIDE(
      SUM(net_accrued_revenue_tl),
      AVG(paid_subscribers)
    ) AS selected_period_net_arpu_tl
  FROM daily_kpis
),

mrr_eom_daily AS (
  SELECT
    a.dt AS date,
    SUM(a.amount_gross_tl) AS gross_mrr_eom_tl,
    SUM(
      a.amount_gross_tl
      * (1.0 - COALESCE(c.commission_rate, 0.00))
    ) AS net_mrr_eom_tl
  FROM daily_active_dedup a
  LEFT JOIN payment_option_config c
    ON a.payment_option = c.payment_option
  WHERE a.dt = LAST_DAY(a.dt)
  GROUP BY a.dt
),

mrr_snapshot_dates AS (
  SELECT ds_end AS snapshot_date, 'selected_end' AS snapshot_type
  FROM params
  UNION ALL
  SELECT previous_month_end AS snapshot_date, 'previous_month_end' AS snapshot_type
  FROM params
),

mrr_snapshot_raw AS (
  SELECT
    d.snapshot_type,
    d.snapshot_date,
    s.user_id,
    s.payment_option,
    s.amount_gross_tl,
    s.created_at,
    s.inserted_date
  FROM mrr_snapshot_dates d
  JOIN subs_converted s
    ON d.snapshot_date BETWEEN s.created_date AND s.paid_end_date
   AND s.amount_gross_tl IS NOT NULL
),

mrr_snapshot_dedup AS (
  SELECT
    snapshot_type,
    snapshot_date,
    user_id,
    payment_option,
    amount_gross_tl
  FROM (
    SELECT
      r.*,
      ROW_NUMBER() OVER (
        PARTITION BY r.snapshot_type, r.user_id
        ORDER BY r.created_at DESC, r.inserted_date DESC
      ) AS rn
    FROM mrr_snapshot_raw r
  )
  WHERE rn = 1
),

mrr_summary AS (
  SELECT
    SUM(
      IF(
        a.snapshot_type = 'selected_end',
        a.amount_gross_tl,
        0
      )
    ) AS gross_mrr_selected_end_tl,
    SUM(
      IF(
        a.snapshot_type = 'selected_end',
        a.amount_gross_tl * (1.0 - COALESCE(c.commission_rate, 0.00)),
        0
      )
    ) AS net_mrr_selected_end_tl,
    SUM(
      IF(
        a.snapshot_type = 'previous_month_end',
        a.amount_gross_tl,
        0
      )
    ) AS gross_mrr_previous_month_end_tl,
    SUM(
      IF(
        a.snapshot_type = 'previous_month_end',
        a.amount_gross_tl * (1.0 - COALESCE(c.commission_rate, 0.00)),
        0
      )
    ) AS net_mrr_previous_month_end_tl
  FROM mrr_snapshot_dedup a
  LEFT JOIN payment_option_config c
    ON a.payment_option = c.payment_option
)

SELECT
  k.date,
  k.month,
  k.is_month_end,
  k.is_selected_end,
  (
    k.date = LEAST(
      LAST_DAY(k.date),
      (SELECT ds_end FROM params)
    )
  ) AS is_month_snapshot,
  k.paid_subscribers,
  -- Temporary compatibility field for existing Looker charts.
  k.paid_subscribers AS active_subscribers,
  k.net_accrued_revenue_tl,
  -- Compatibility aliases: these are accrued revenue and daily ARPU.
  k.net_accrued_revenue_tl AS net_revenue_tl,
  k.daily_net_arpu_tl,
  k.daily_net_arpu_tl AS arpu_tl,
  ROUND(k.daily_net_arpu_tl, 2) AS arpu_tl_rounded,
  CAST(ROUND(k.daily_net_arpu_tl * 100, 0) AS INT64) AS arpu_kurus,
  IF(
    k.date = LEAST(LAST_DAY(k.date), p.ds_end),
    mk.avg_daily_paid_subscribers,
    NULL
  ) AS avg_daily_paid_subscribers,
  IF(
    k.date = LEAST(LAST_DAY(k.date), p.ds_end),
    mk.monthly_net_accrued_revenue_tl,
    NULL
  ) AS monthly_net_accrued_revenue_tl,
  IF(
    k.date = LEAST(LAST_DAY(k.date), p.ds_end),
    mk.monthly_net_arpu_tl,
    NULL
  ) AS monthly_net_arpu_tl,
  IF(
    k.is_selected_end,
    sp.selected_period_net_arpu_tl,
    NULL
  ) AS selected_period_net_arpu_tl,
  IF(
    k.date = LEAST(LAST_DAY(k.date), p.ds_end),
    mc.monthly_transaction_count,
    NULL
  ) AS monthly_transaction_count,
  IF(
    k.date = LEAST(LAST_DAY(k.date), p.ds_end),
    mc.monthly_gross_collections_tl,
    NULL
  ) AS monthly_gross_collections_tl,
  IF(
    k.date = LEAST(LAST_DAY(k.date), p.ds_end),
    mc.monthly_net_collections_tl,
    NULL
  ) AS monthly_net_collections_tl,
  m.gross_mrr_eom_tl,
  m.net_mrr_eom_tl,
  -- Compatibility alias: old mrr_eom_tl means NET MRR after commission.
  m.net_mrr_eom_tl AS mrr_eom_tl,
  IF(
    k.is_selected_end,
    ms.gross_mrr_selected_end_tl,
    NULL
  ) AS gross_mrr_selected_end_tl,
  IF(
    k.is_selected_end,
    ms.net_mrr_selected_end_tl,
    NULL
  ) AS net_mrr_selected_end_tl,
  IF(
    k.is_selected_end,
    ms.net_mrr_selected_end_tl,
    NULL
  ) AS mrr_selected_end_tl,
  IF(
    k.is_selected_end,
    ms.gross_mrr_previous_month_end_tl,
    NULL
  ) AS gross_mrr_previous_month_end_tl,
  IF(
    k.is_selected_end,
    ms.net_mrr_previous_month_end_tl,
    NULL
  ) AS net_mrr_previous_month_end_tl,
  IF(
    k.is_selected_end,
    ms.net_mrr_previous_month_end_tl,
    NULL
  ) AS mrr_previous_month_end_tl,
  IF(k.is_selected_end, p.previous_month_start, NULL) AS previous_month_start,
  IF(k.is_selected_end, p.previous_month_end, NULL) AS previous_month_end,
  IF(k.is_selected_end, p.trailing_30d_start, NULL) AS trailing_30d_start,
  IF(k.is_selected_end, p.ds_end, NULL) AS trailing_30d_end,
  IF(
    k.is_selected_end,
    cs.selected_period_transaction_count,
    NULL
  ) AS selected_period_transaction_count,
  IF(
    k.is_selected_end,
    cs.selected_period_gross_collections_tl,
    NULL
  ) AS selected_period_gross_collections_tl,
  IF(
    k.is_selected_end,
    cs.selected_period_net_collections_tl,
    NULL
  ) AS selected_period_net_collections_tl,
  IF(
    k.is_selected_end,
    cs.previous_month_transaction_count,
    NULL
  ) AS previous_month_transaction_count,
  IF(
    k.is_selected_end,
    cs.previous_month_gross_collections_tl,
    NULL
  ) AS previous_month_gross_collections_tl,
  IF(
    k.is_selected_end,
    cs.previous_month_net_collections_tl,
    NULL
  ) AS previous_month_net_collections_tl,
  IF(
    k.is_selected_end,
    cs.trailing_30d_transaction_count,
    NULL
  ) AS trailing_30d_transaction_count,
  IF(
    k.is_selected_end,
    cs.trailing_30d_gross_collections_tl,
    NULL
  ) AS trailing_30d_gross_collections_tl,
  IF(
    k.is_selected_end,
    cs.trailing_30d_net_collections_tl,
    NULL
  ) AS trailing_30d_net_collections_tl
FROM daily_kpis k
LEFT JOIN mrr_eom_daily m
  ON k.date = m.date
LEFT JOIN monthly_kpis mk
  ON k.month = mk.month
LEFT JOIN monthly_collections mc
  ON k.month = mc.month
CROSS JOIN collection_summary cs
CROSS JOIN mrr_summary ms
CROSS JOIN params p
CROSS JOIN selected_period_kpis sp
ORDER BY k.date;
