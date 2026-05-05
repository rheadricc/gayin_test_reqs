
-- Son3 Ayda Churn Eden Kullanıcı Sayısı
-- Amaç: Son 3 ay içerisinde aboneliğini iptal edip, ardından süresi dolan kullanıcı sayısını bulmak
-- Kullanılan tablo:
--   aws_s3_to_bq_migration.subs_payment : kullanıcı abonelik bilgileri ve durumları
WITH transitions AS (
  -- 1. Kullanıcıların abonelik durum geçişlerini sıraya koyuyoruz
  SELECT
    user_id,
    status,
    created_at,
    LEAD(status) OVER (PARTITION BY user_id ORDER BY created_at) AS next_status,           -- bir sonraki durum
    LEAD(created_at) OVER (PARTITION BY user_id ORDER BY created_at) AS next_created_at    -- bir sonraki durum tarihi
  FROM `aws_s3_to_bq_migration.subs_payment`
  WHERE created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)  -- son 90 gün
)
-- 2. Churn eden kullanıcıları sayıyoruz
SELECT 
  COUNT(DISTINCT user_id) AS churned_user_count
FROM transitions
WHERE status = 'CANCELED'          -- iptal eden
  AND next_status = 'EXPIRED';     -- ve bir sonraki durum süresi dolmuş
