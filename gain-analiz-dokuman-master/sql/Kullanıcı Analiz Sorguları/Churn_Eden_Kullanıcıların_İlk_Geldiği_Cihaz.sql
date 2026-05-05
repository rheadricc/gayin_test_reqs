
-- Churn_Eden Kullanıcıların İlk Geldiği Cihaz
-- Amaç: Son 3 ayda churn eden kullanıcıların ilk kez hangi cihazdan giriş yaptığını tespit etmek
-- Kullanılan tablolar:
--   aws_s3_to_bq_migration.subs_payment : kullanıcı abonelik durumları
--   analytics_236816681.events_*        : kullanıcı cihaz ve event bilgileri
WITH transitions AS (
  -- 1. Kullanıcıların abonelik durum geçişlerini sıraya koyuyoruz
  SELECT
    user_id,
    status,
    email,
    created_at,
    registered_at,
    LEAD(status) OVER (PARTITION BY user_id ORDER BY created_at) AS next_status,
    LEAD(created_at) OVER (PARTITION BY user_id ORDER BY created_at) AS next_created_at
  FROM `aws_s3_to_bq_migration.subs_payment`
  WHERE created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY) -- son 90 gün
),
churn_user AS (
  -- 2. Churn eden kullanıcıları seçiyoruz (iptal edip süresi dolanlar)
  SELECT DISTINCT 
    user_id,
    email,
    registered_at
  FROM transitions
  WHERE status = 'CANCELED' AND next_status = 'EXPIRED'
),
min_event_time AS (
  -- 3. Her kullanıcı için ilk event timestamp'ini buluyoruz
  SELECT DISTINCT
    MIN(event_timestamp) AS min_event_timestamp,
    user_id
  FROM `analytics_236816681.events_*`
  GROUP BY user_id
),
device_info AS (
  -- 4. Tüm cihaz bilgilerini alıyoruz
  SELECT DISTINCT
    event_timestamp,
    user_id,
    device.category,
    device.operating_system
  FROM `analytics_236816681.events_*`
)
-- 5. Churn eden kullanıcıların ilk event cihaz bilgilerini getiriyoruz
SELECT
   di.*
FROM device_info di
JOIN min_event_time met 
  ON di.event_timestamp = met.min_event_timestamp 
  AND di.user_id = met.user_id
JOIN churn_user cu 
  ON di.user_id = cu.user_id;
