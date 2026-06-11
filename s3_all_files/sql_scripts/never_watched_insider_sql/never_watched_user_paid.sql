
DECLARE full_price_amount INT64 DEFAULT 14900;

CREATE OR REPLACE TABLE `microgain-9f959.insider.never_watched_paid_sparse_snapshot` AS
WITH candidate_users AS (
  SELECT DISTINCT pw.user_id
  FROM `test_dataset.payment_watch_dropoff_scd` pw
  JOIN `test_dataset.guncel_premium_users` pu
    ON pw.user_id = pu.user_id
  WHERE pw.dropoff_typepe = 'never_watched'   -- senin kolon ismine sadık kalıyorum
),

-- Kullanıcının ödeme geçmişi (promoyu boolean olarak tespit edelim)
payments AS (
  SELECT
    sp.user_id,
    sp.created_at,
    sp.valid_until,
    sp.status,
    sp.amount,
    -- herhangi bir promo var mı?
    EXISTS(SELECT 1 FROM UNNEST(sp.applied_promotions)) AS has_promotion
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` sp
  WHERE sp.user_id IN (SELECT user_id FROM candidate_users)
),

-- Free trial sinyali: promo yok + (valid_until - created_at) 7/8 gün
pay_labeled AS (
  SELECT
    p.*,
    CASE
      WHEN p.has_promotion = FALSE
       AND DATE_DIFF(DATE(p.valid_until), DATE(p.created_at), DAY) IN (7,8)
      THEN TRUE ELSE FALSE
    END AS is_free_trial
  FROM payments p
),

-- İlk ACTIVE kayıt
first_active AS (
  SELECT
    user_id,
    ARRAY_AGG(STRUCT(created_at, amount, has_promotion, is_free_trial)
              ORDER BY created_at ASC LIMIT 1)[OFFSET(0)] AS evt
  FROM pay_labeled
  WHERE status = 'ACTIVE'
  GROUP BY user_id
),

-- Son ACTIVE kayıt
last_active AS (
  SELECT
    user_id,
    ARRAY_AGG(STRUCT(created_at, amount)
              ORDER BY created_at DESC LIMIT 1)[OFFSET(0)] AS evt
  FROM pay_labeled
  WHERE status = 'ACTIVE'
  GROUP BY user_id
),

entry_and_latest AS (
  SELECT
    cu.user_id,

    -- giriş tipi (ilk ACTIVE event)
    CASE
      WHEN fa.evt IS NULL THEN 'no_active'
      WHEN fa.evt.is_free_trial THEN 'freetrial'
      WHEN fa.evt.has_promotion THEN 'promo'
      WHEN fa.evt.amount = full_price_amount THEN 'paid'
      ELSE 'other'
    END AS entry_type,

    fa.evt.created_at AS entry_created_at,
    fa.evt.amount     AS entry_amount,

    la.evt.created_at AS latest_created_at,
    la.evt.amount     AS latest_amount,

    -- son ACTIVE paid mi?
    CASE WHEN la.evt.amount = full_price_amount THEN TRUE ELSE FALSE END AS latest_is_paid
  FROM candidate_users cu
  LEFT JOIN first_active fa ON fa.user_id = cu.user_id
  LEFT JOIN last_active  la ON la.user_id = cu.user_id
),

-- DIM (SCD'de current olan kaydı çek)
dim_current AS (
  SELECT
    userId AS user_id,
    email AS email_address,
    communicationConsent.isEmailPermitted AS is_email_permitted
  FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`
  WHERE is_current = TRUE
)

SELECT
  e.user_id,
  d.email_address,
  d.is_email_permitted,
  CURRENT_TIMESTAMP() AS snapshot_ts
FROM entry_and_latest e
JOIN dim_current d USING (user_id)
WHERE e.latest_is_paid = TRUE;