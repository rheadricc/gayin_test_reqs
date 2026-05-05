-- Son3 Ayda Churn Sonrası 1 Hafta İçinde Tekrar Abonelik Başlatan Kullanıcı Sayısı
-- Amaç: Churn eden kullanıcıların 7 gün içinde tekrar abonelik başlatıp başlatmadığını hesaplamak
-- Kullanılan tablo:
--   aws_s3_to_bq_migration.subs_payment : kullanıcı abonelik bilgileri ve durumları
WITH transitions AS (
  -- 1. Kullanıcı bazında durum geçişlerini sıraya koyuyoruz
  SELECT
    user_id,
    status,
    created_at,
    LEAD(status) OVER (PARTITION BY user_id ORDER BY created_at) AS next_status,
    LEAD(created_at) OVER (PARTITION BY user_id ORDER BY created_at) AS next_created_at
  FROM `aws_s3_to_bq_migration.subs_payment`
),
churned AS (
  -- 2. Churn eden kullanıcıları ve süresi dolma zamanlarını alıyoruz
  SELECT
    user_id,
    next_created_at AS expired_time
  FROM transitions
  WHERE status = 'CANCELED' AND next_status = 'EXPIRED'
),
reactivated AS (
  -- 3. Churn eden kullanıcıların 7 gün içinde tekrar aktif olduğu kayıtları buluyoruz
  SELECT
    c.user_id
  FROM churned c
  JOIN `aws_s3_to_bq_migration.subs_payment` t
    ON c.user_id = t.user_id
   AND t.status = 'ACTIVE'
   AND t.created_at > c.expired_time
   AND t.created_at <= TIMESTAMP_ADD(c.expired_time, INTERVAL 7 DAY)
)
-- 4. Sonuç: 7 gün içinde tekrar abonelik başlatan kullanıcı sayısı
SELECT COUNT(DISTINCT user_id) AS reactivated_within_7_days
FROM reactivated;
