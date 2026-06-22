-- Churn & Retention - Core Daily Subscription Health
-- SQL Name: BC_CHURN_RETENTION_CORE_DAILY
-- Grain: 1 row = 1 day
--
-- Kapsam:
-- 1) Abone / Ücretli Abone
-- 2) Günlük Churn Olan Ücretli Abone
-- 3) Canceled Ücretli Abone
-- 4) Grace Period Kullanıcıları
-- 5) Günlük Statü Dağılımı
-- 6) Ortalama Abonelik Süresi
--
-- İş kuralları:
-- - Tek tarih alanı: date
-- - PREPAID hariçtir.
-- - amount >= 101 gerçek ücretli abonelik kabul edilir.
-- - valid_until bugünden 2 yıldan ileride olan test kayıtları hariçtir.
-- - Abone: status boş olmayan ve EXPIRED olmayan kullanıcılar.
-- - Ücretli abone: status ACTIVE/CANCELED + valid_until_date >= date
-- - Churn: kullanıcının son ücretli kaydı ACTIVE/CANCELED değilse,
--   churn tarihi valid_until_date olarak kabul edilir.
-- - Grace period: status IN_GRACE/ON_HOLD + date > valid_until_date + date <= grace/hold end date
-- - Parasal metrik yoktur.
-- - Looker Studio tarih filtresi @DS_START_DATE / @DS_END_DATE parametreleriyle çalışır.

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS start_date,
    PARSE_DATE('%Y%m%d', @DS_END_DATE) AS end_date
),

date_spine AS (
  SELECT
    date
  FROM params,
  UNNEST(GENERATE_DATE_ARRAY(start_date, end_date, INTERVAL 1 DAY)) AS date
),

subs_base AS (
  SELECT
    s.user_id,
    UPPER(s.status) AS status,
    UPPER(s.payment_option) AS payment_option,
    s.currency,
    s.created_at,
    s.inserted_date,
    DATE(s.created_at, 'Europe/Istanbul') AS created_date,
    DATE(s.valid_until, 'Europe/Istanbul') AS valid_until_date,
    DATE(s.grace_until, 'Europe/Istanbul') AS grace_until_date,
    DATE(s.hold_until, 'Europe/Istanbul') AS hold_until_date,
    CASE
      WHEN UPPER(s.status) = 'ON_HOLD' THEN COALESCE(
        DATE(s.hold_until, 'Europe/Istanbul'),
        DATE(s.grace_until, 'Europe/Istanbul'),
        DATE(s.valid_until, 'Europe/Istanbul')
      )
      WHEN UPPER(s.status) = 'IN_GRACE' THEN COALESCE(
        DATE(s.grace_until, 'Europe/Istanbul'),
        DATE(s.hold_until, 'Europe/Istanbul'),
        DATE(s.valid_until, 'Europe/Istanbul')
      )
      ELSE DATE(s.valid_until, 'Europe/Istanbul')
    END AS active_end_date,
    s.subscription_plan_id,
    s.amount
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN params p
  WHERE s.user_id IS NOT NULL
    AND s.created_at IS NOT NULL
    AND s.valid_until IS NOT NULL
    AND s.subscription_plan_id IS NOT NULL
    AND s.amount IS NOT NULL
    AND s.amount >= 101
    AND UPPER(COALESCE(s.payment_option, '')) != 'PREPAID'
    AND DATE(s.valid_until, 'Europe/Istanbul')
      <= DATE_ADD(CURRENT_DATE('Europe/Istanbul'), INTERVAL 2 YEAR)
    AND DATE(s.created_at, 'Europe/Istanbul') <= p.end_date
),

latest_sub_by_day AS (
  SELECT
    date,
    user_id,
    status,
    valid_until_date,
    grace_until_date,
    hold_until_date,
    active_end_date,
    created_date
  FROM (
    SELECT
      d.date,
      s.user_id,
      s.status,
      s.valid_until_date,
      s.grace_until_date,
      s.hold_until_date,
      s.active_end_date,
      s.created_date,
      ROW_NUMBER() OVER (
        PARTITION BY d.date, s.user_id
        ORDER BY s.created_date DESC, s.valid_until_date DESC, s.created_at DESC
      ) AS rn
    FROM date_spine d
    JOIN subs_base s
      ON s.created_date <= d.date
     AND s.active_end_date >= d.date
  )
  WHERE rn = 1
),

daily_status_counts AS (
  SELECT
    date,

    COUNT(DISTINCT IF(
      status IS NOT NULL
      AND status != 'EXPIRED',
      user_id,
      NULL
    )) AS subscriber_count,

    COUNT(DISTINCT IF(
      status IN ('ACTIVE', 'CANCELED')
      AND valid_until_date >= date,
      user_id,
      NULL
    )) AS paid_subscriber_count,

    COUNT(DISTINCT IF(
      status = 'ACTIVE'
      AND valid_until_date >= date,
      user_id,
      NULL
    )) AS active_status_subscriber_count,

    COUNT(DISTINCT IF(
      status = 'CANCELED'
      AND valid_until_date >= date,
      user_id,
      NULL
    )) AS canceled_subscriber_count,

    COUNT(DISTINCT IF(
      status = 'IN_GRACE'
      AND date > valid_until_date
      AND date <= COALESCE(grace_until_date, active_end_date),
      user_id,
      NULL
    )) AS in_grace_status_subscriber_count,

    COUNT(DISTINCT IF(
      status = 'ON_HOLD'
      AND date > valid_until_date
      AND date <= COALESCE(hold_until_date, active_end_date),
      user_id,
      NULL
    )) AS on_hold_status_subscriber_count,

    COUNT(DISTINCT IF(
      status IN ('IN_GRACE', 'ON_HOLD')
      AND date > valid_until_date
      AND date <= active_end_date,
      user_id,
      NULL
    )) AS grace_period_subscriber_count,

    COUNT(DISTINCT IF(
      status = 'EXPIRED'
      OR (
        valid_until_date < date
        AND status NOT IN ('ACTIVE', 'CANCELED', 'IN_GRACE', 'ON_HOLD')
      ),
      user_id,
      NULL
    )) AS expired_status_subscriber_count

  FROM latest_sub_by_day
  GROUP BY date
),

last_paid_subscription AS (
  SELECT
    user_id,
    status,
    valid_until_date,
    ROW_NUMBER() OVER (
      PARTITION BY user_id
      ORDER BY valid_until_date DESC, created_date DESC, created_at DESC
    ) AS rn
  FROM subs_base
),

daily_churn AS (
  SELECT
    valid_until_date AS date,
    COUNT(DISTINCT user_id) AS churned_paid_subscriber_count
  FROM last_paid_subscription
  WHERE rn = 1
    AND status NOT IN ('ACTIVE', 'CANCELED')
    AND valid_until_date >= (SELECT start_date FROM params)
    AND valid_until_date <= (SELECT end_date FROM params)
  GROUP BY date
),

user_first_paid AS (
  SELECT
    user_id,
    MIN(created_date) AS first_paid_date
  FROM subs_base
  GROUP BY user_id
),

daily_average_tenure AS (
  SELECT
    l.date,
    ROUND(
      AVG(DATE_DIFF(l.date, f.first_paid_date, DAY) / 30.4375),
      2
    ) AS avg_subscription_tenure_month
  FROM latest_sub_by_day l
  JOIN user_first_paid f
    ON l.user_id = f.user_id
  WHERE l.status IN ('ACTIVE', 'CANCELED')
    AND l.valid_until_date >= l.date
  GROUP BY l.date
)

SELECT
  d.date,

  COALESCE(sc.subscriber_count, 0) AS subscriber_count,
  COALESCE(sc.paid_subscriber_count, 0) AS paid_subscriber_count,
  COALESCE(ch.churned_paid_subscriber_count, 0) AS churned_paid_subscriber_count,
  COALESCE(sc.canceled_subscriber_count, 0) AS canceled_subscriber_count,
  COALESCE(sc.grace_period_subscriber_count, 0) AS grace_period_subscriber_count,

  COALESCE(sc.active_status_subscriber_count, 0) AS active_status_subscriber_count,
  COALESCE(sc.in_grace_status_subscriber_count, 0) AS in_grace_status_subscriber_count,
  COALESCE(sc.on_hold_status_subscriber_count, 0) AS on_hold_status_subscriber_count,
  COALESCE(sc.expired_status_subscriber_count, 0) AS expired_status_subscriber_count,

  COALESCE(t.avg_subscription_tenure_month, 0) AS avg_subscription_tenure_month

FROM date_spine d
LEFT JOIN daily_status_counts sc
  ON d.date = sc.date
LEFT JOIN daily_churn ch
  ON d.date = ch.date
LEFT JOIN daily_average_tenure t
  ON d.date = t.date
ORDER BY
  d.date DESC;
