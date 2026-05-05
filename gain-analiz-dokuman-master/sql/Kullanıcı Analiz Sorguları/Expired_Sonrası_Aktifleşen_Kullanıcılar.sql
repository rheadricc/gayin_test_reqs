
-- Expired_Sonrası_Aktifleşen_Kullanıcılar
-- Amaç: Aboneliği "EXPIRED" durumuna gelen kullanıcıların, daha sonra tekrar "ACTIVE" duruma geçişlerini bulmak
-- Kullanılan tablolar:
--   looker_report.all_users_updated : kullanıcıların güncel aktif durum bilgisi
--   aws_s3_to_bq_migration.subs_payment : kullanıcı abonelik geçiş geçmişi
WITH activeusers AS (
  -- 1. Şu anda aktif olan kullanıcıları alıyoruz
  SELECT
    status,
    user_id,
    created_at AS activate_created_at
  FROM `looker_report.all_users_updated`
  WHERE status = 'ACTIVE'
),
orderedstatus AS (
  -- 2. Kullanıcıların abonelik geçişlerini sıralı şekilde alıyoruz
  SELECT
    user_id,
    status,
    created_at,
    LEAD(status) OVER (PARTITION BY user_id ORDER BY created_at) AS next_status,
    LEAD(created_at) OVER (PARTITION BY user_id ORDER BY created_at) AS next_created_at
  FROM `aws_s3_to_bq_migration.subs_payment`
)
-- 3. "EXPIRED" durumundan sonra tekrar "ACTIVE" olan kullanıcıları ve süre farkını alıyoruz
SELECT 
  o.*,
  TIMESTAMP_DIFF(o.next_created_at, o.created_at, DAY) AS datediff
FROM orderedstatus o
JOIN activeusers a 
  ON o.user_id = a.user_id 
  AND o.next_created_at = a.activate_created_at
WHERE o.status = 'EXPIRED' 
  AND o.next_status = 'ACTIVE';
  -- AND timestamp_diff(next_created_at, created_at, DAY) > 30 -- opsiyonel filtre: 30 günden uzun bekleme
