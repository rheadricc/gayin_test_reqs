WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', '20251201') AS ds_start,
    PARSE_DATE('%Y%m%d', '20260401') AS ds_end
),

months AS (
  SELECT month_start AS ay
  FROM params,
  UNNEST(GENERATE_DATE_ARRAY(
    DATE_TRUNC(ds_start, MONTH),
    DATE_TRUNC(ds_end, MONTH),
    INTERVAL 1 MONTH
  )) AS month_start
),

base AS (
  SELECT
    s.user_id,
    s.status,
    s.payment_option,
    s.currency,
    DATE(s.created_at) AS event_date,
    DATE(s.created_at) AS created_date,
    DATE(s.free_trial_start_date) AS trial_start,
    DATE(s.free_trial_end_date) AS trial_end,
    DATE(s.valid_until) AS valid_until_date,
    DATE(s.grace_until) AS grace_until_date,
    DATE(s.hold_until) AS hold_until_date,
    CASE
      WHEN s.status = 'ON_HOLD'  THEN COALESCE(DATE(s.hold_until), DATE(s.valid_until))
      WHEN s.status = 'IN_GRACE' THEN COALESCE(DATE(s.grace_until), DATE(s.valid_until))
      ELSE DATE(s.valid_until)
    END AS active_end_date,
    CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64) AS amount_minor
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  WHERE s.user_id IS NOT NULL
),

-- İlgili ay içinde en az 1 gün aktif olan toplam benzersiz abone
monthly_active AS (
  SELECT
    m.ay,
    COUNT(DISTINCT b.user_id) AS total_subs
  FROM months m
  JOIN base b
    ON b.payment_option IS NOT NULL
   AND b.payment_option != 'PREPAID'
   AND UPPER(COALESCE(b.currency, '')) = 'TRY'
   AND b.status IN ('ACTIVE', 'IN_GRACE', 'ON_HOLD')
   AND b.created_date <= LAST_DAY(m.ay)
   AND b.active_end_date >= m.ay
  GROUP BY m.ay
),

-- Trial cohort: ilgili ayda free trial başlayan user'lar
trial_users AS (
  SELECT
    DATE_TRUNC(b.trial_start, MONTH) AS ay,
    b.user_id,
    MIN(b.trial_start) AS trial_start,
    MIN(b.trial_end) AS trial_end
  FROM base b
  CROSS JOIN params p
  WHERE b.trial_start IS NOT NULL
    AND b.trial_end IS NOT NULL
    AND b.trial_start BETWEEN p.ds_start AND p.ds_end
  GROUP BY ay, b.user_id
),

-- İlk ücretli ödeme tarihi
paid_users AS (
  SELECT
    b.user_id,
    MIN(b.event_date) AS first_paid_date
  FROM base b
  WHERE b.payment_option IS NOT NULL
    AND b.payment_option != 'PREPAID'
    AND b.amount_minor > 0
  GROUP BY b.user_id
),

joined AS (
  SELECT
    t.ay,
    t.user_id,
    t.trial_start,
    t.trial_end,
    p.first_paid_date
  FROM trial_users t
  LEFT JOIN paid_users p
    ON t.user_id = p.user_id
),

agg AS (
  SELECT
    ay,
    COUNT(DISTINCT user_id) AS trial_users,
    COUNT(DISTINCT IF(
      first_paid_date IS NOT NULL
      AND trial_end IS NOT NULL
      AND first_paid_date >= trial_end,
      user_id,
      NULL
    )) AS paid_users
  FROM joined
  GROUP BY ay
)

SELECT
  m.ay,
  COALESCE(a.total_subs, 0) AS total_subs,
  COALESCE(g.trial_users, 0) AS trial_users,
  COALESCE(g.paid_users, 0) AS paid_users,

  SAFE_DIVIDE(COALESCE(g.trial_users, 0), COALESCE(a.total_subs, 0)) AS trial_penetration,
  SAFE_DIVIDE(COALESCE(g.paid_users, 0), COALESCE(g.trial_users, 0)) AS trial_to_paid_conversion,
  SAFE_DIVIDE(COALESCE(g.paid_users, 0), COALESCE(a.total_subs, 0)) AS paid_vs_total,

  ROUND(SAFE_DIVIDE(COALESCE(g.trial_users, 0), COALESCE(a.total_subs, 0)) * 100, 2) AS trial_penetration_pct,
  ROUND(SAFE_DIVIDE(COALESCE(g.paid_users, 0), COALESCE(g.trial_users, 0)) * 100, 2) AS trial_to_paid_conversion_pct,
  ROUND(SAFE_DIVIDE(COALESCE(g.paid_users, 0), COALESCE(a.total_subs, 0)) * 100, 2) AS paid_vs_total_pct

FROM months m
LEFT JOIN monthly_active a
  ON m.ay = a.ay
LEFT JOIN agg g
  ON m.ay = g.ay
ORDER BY m.ay;