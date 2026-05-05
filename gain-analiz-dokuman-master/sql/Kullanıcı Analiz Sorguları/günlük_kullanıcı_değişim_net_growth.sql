-- Parametreler
WITH params AS (
  SELECT DATE '2025-09-19' AS start_date,
         CURRENT_DATE() /*-1*/   AS end_date
),

-- Gün listesi
days AS (
  SELECT day
  FROM params p, UNNEST(GENERATE_DATE_ARRAY(p.start_date, p.end_date)) AS day
),

-- Kaynak
subs AS (
  SELECT
    user_id,
    status,
    created_at,
    DATE(created_at) AS created_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`, params
  WHERE DATE(created_at) <= (SELECT end_date FROM params)
),

-- 1) first_active_date: TÜM TARİH boyunca ilk ACTIVE günü
first_active_global AS (
  SELECT
    user_id,
    MIN(DATE(created_at)) AS first_active_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE status = 'ACTIVE'
  GROUP BY user_id
),

-- 2) Gün sonu snapshot
snapshot AS (
  SELECT
    d.day,
    s.user_id,
    ARRAY_AGG(s.status ORDER BY s.created_at DESC LIMIT 1)[OFFSET(0)] AS status_today
  FROM days d
  JOIN subs s
    ON DATE(s.created_at) <= d.day
  GROUP BY d.day, s.user_id
),

-- 3) Önceki gün durumu + paid bayrağı
snap_flags AS (
  SELECT
    s.day,
    s.user_id,
    s.status_today,
    LAG(s.status_today) OVER (PARTITION BY s.user_id ORDER BY s.day) AS status_yesterday,
    CASE WHEN s.status_today IN ('ACTIVE','CANCELED') THEN 1 ELSE 0 END AS paid_today
  FROM snapshot s
),

-- 4) Dün paid miydi?
snap_flags_prev AS (
  SELECT
    sf.*,
    CASE WHEN LAG(sf.paid_today) OVER (PARTITION BY sf.user_id ORDER BY sf.day) = 1 THEN 1 ELSE 0 END AS paid_yesterday
  FROM snap_flags sf
),

-- 5) Etiketleme
labeled AS (
  SELECT
    sf.day,
    sf.user_id,
    sf.status_today,
    sf.status_yesterday,
    fa.first_active_date,
    sf.paid_today,

    CASE
      WHEN sf.status_today = 'ACTIVE'
       AND fa.first_active_date IS NOT NULL
       AND sf.day = fa.first_active_date
      THEN 1 ELSE 0
    END AS is_new_user,

    CASE
      WHEN sf.status_today = 'ACTIVE'
       AND sf.status_yesterday IN ('ON_HOLD','EXPIRED','CANCELED','IN_GRACE')
      THEN 1 ELSE 0
    END AS is_retained_user,

    CASE
      WHEN sf.status_yesterday IN ('ACTIVE','CANCELED')
       AND sf.status_today    IN ('ON_HOLD','EXPIRED')
      THEN 1 ELSE 0
    END AS is_churn_business,

    CASE WHEN sf.paid_yesterday = 0 AND sf.paid_today = 1 THEN 1 ELSE 0 END AS became_paid,
    CASE WHEN sf.paid_yesterday = 1 AND sf.paid_today = 0 THEN 1 ELSE 0 END AS left_paid_all
  FROM snap_flags_prev sf
  LEFT JOIN first_active_global fa USING (user_id)
),

-- 6) Günlük özet
daily AS (
  SELECT
    day AS date,
    SUM(paid_today)                  AS toplam_ucretli_abonelik,
    SUM(is_new_user)                 AS yeni_kullanici,
    SUM(is_retained_user)            AS retained_users,
    SUM(is_churn_business)           AS churn_users_business,
    SUM(became_paid)                 AS became_paid,
    SUM(left_paid_all)               AS left_paid_all
  FROM labeled
  GROUP BY day
),

-- 7) Net flow + günlük değişim
final AS (
  SELECT
    d.date,
    FORMAT_DATE('%A', d.date) AS gun_adi, -- ✅ Gün ismi eklendi
    d.toplam_ucretli_abonelik,
    d.toplam_ucretli_abonelik - LAG(d.toplam_ucretli_abonelik) OVER (ORDER BY d.date) AS gunluk_degisim,
    d.yeni_kullanici,
    d.retained_users,
    d.churn_users_business AS churn_users,
    (d.became_paid - d.left_paid_all) AS net_flow_paid_exact
  FROM daily d
)

SELECT *
FROM final
WHERE net_flow_paid_exact != toplam_ucretli_abonelik
ORDER BY date;

