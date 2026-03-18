WITH promo_users AS (
  SELECT DISTINCT
    s.user_id,
    ap.promotionId,
    DATE(s.free_trial_end_date) AS trial_end_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s,
       UNNEST(s.applied_promotions) ap
  WHERE ap.promotionId IS NOT NULL
    AND s.free_trial_end_date IS NOT NULL
),

paid_users AS (
  SELECT
    user_id,
    MIN(DATE(created_at)) AS first_paid_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE amount > 0
    AND payment_option IS NOT NULL
  GROUP BY user_id
),

joined AS (
  SELECT
    p.user_id,
    p.promotionId,
    p.trial_end_date,
    pu.first_paid_date
  FROM promo_users p
  JOIN paid_users pu
    ON p.user_id = pu.user_id
  WHERE pu.first_paid_date >= p.trial_end_date
)

SELECT
  DATE_TRUNC(first_paid_date, MONTH) AS ay,

  COUNT(DISTINCT user_id) AS ucretliye_gecen_user,

  COUNT(*) AS toplam_kampanya_kullanimi,

  COUNT(DISTINCT promotionId) AS kampanya_sayisi

FROM joined
GROUP BY ay
ORDER BY ay;