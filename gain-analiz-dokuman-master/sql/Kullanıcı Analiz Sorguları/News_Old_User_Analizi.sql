
-- Newvs Old User Analizi
-- Amaç: Cüneyt Özdemir içeriklerini izleyen kullanıcıların yeni mi yoksa eski kullanıcı mı olduğunu belirlemek
-- Kullanılan tablolar:
--   looker_report.content_report_streaming_V2 : içerik izlenme kayıtları
--   aws_s3_to_bq_migration.subs_payment       : aktif ödeme yapan kullanıcılar
--   datamarts.access                           : kullanıcı oluşturulma tarihleri
CREATE OR REPLACE TABLE `microgain-9f959.test_dataset.cuneyt_new_old_20250826` AS 
WITH
-- 1. Her kullanıcının platformda ilk event tarihini buluyoruz
MinEventDate AS (
  SELECT
    DISTINCT user_id,
    MIN(event_date) AS MinEventDate
  FROM `microgain-9f959.looker_report.content_report_streaming_V2`
  WHERE event_date <= CURRENT_DATE("Europe/Istanbul")
  GROUP BY 1
),
-- 2. Cüneyt içeriklerini izleyen kullanıcılar
EsasOglanWatchers AS (
  SELECT DISTINCT
    user_id,
    event_date
  FROM `microgain-9f959.looker_report.content_report_streaming_V2`
  WHERE unique_playlistId IN ('Nhy480AT','9LX7zsJt')
    AND event_date >= '2023-09-26'
),
-- 3. İlk izleme eventini kontrol edip kullanıcıyı içerik bazında etiketliyoruz
FirstEventCheck AS (
  SELECT 
    e.*,
    IF(m.user_id IS NULL, 'Other', 'Cüneyt Özdemir') AS FirstWatchedContent
  FROM EsasOglanWatchers e
  LEFT JOIN MinEventDate m 
    ON e.user_id = m.user_id 
    AND e.event_date = m.MinEventDate
),
-- 4. AWS kayıtlarından kullanıcı oluşturulma tarihini alıyoruz
awsusers AS (
  SELECT 
    user_id AS uuid,
    MIN(TIMESTAMP(created_at)) AS MinCreatedAt
  FROM `aws_s3_to_bq_migration.subs_payment`
  WHERE status = 'ACTIVE'
  GROUP BY 1
),
-- 5. Access tablosundan kullanıcı oluşturulma tarihlerini alıyoruz
UserCreatedAt AS (
  SELECT DISTINCT 
    uuid,
    MIN(CreatedAt) AS MinCreatedAt
  FROM `datamarts.access`
  GROUP BY 1
),
-- 6. AWS ve Access tablolarındaki MinCreatedAt değerlerini birleştiriyoruz
AwsusersUserCreatedAt AS (
  SELECT * EXCEPT(rownum)
  FROM (
    SELECT *, ROW_NUMBER() OVER(PARTITION BY uuid ORDER BY MinCreatedAt ASC) AS rownum
    FROM (
      SELECT * FROM awsusers
      UNION ALL
      SELECT * FROM UserCreatedAt
    )
  )
  WHERE rownum = 1
),
-- 7. Kullanıcıların izleme tarihleri ile oluşturulma tarihlerini karşılaştırarak yeni/eskileri belirliyoruz
LastTab AS (
  SELECT 
    f.user_id,
    f.event_date,
    f.FirstWatchedContent,
    DATE(u.MinCreatedAt) AS MinCreatedAtDate,
    IF(DATE_SUB(f.event_date, INTERVAL 7 DAY) <= DATE(u.MinCreatedAt), 'Cüneyt Özdemir', 'Other') AS ComingReason
  FROM FirstEventCheck f
  LEFT JOIN AwsusersUserCreatedAt u 
    ON LOWER(f.user_id) = LOWER(u.uuid)
)
-- 8. Final: Kullanıcıyı New / Old olarak etiketliyoruz
SELECT
  *,
  CASE 
    WHEN FirstWatchedContent = 'Cüneyt Özdemir' AND ComingReason = 'Cüneyt Özdemir' THEN 'New User'
    WHEN FirstWatchedContent = 'Other' AND ComingReason = 'Cüneyt Özdemir' THEN 'New User'
    WHEN FirstWatchedContent = 'Other' AND ComingReason = 'Other' THEN 'Old User'
    WHEN FirstWatchedContent = 'Cüneyt Özdemir' AND ComingReason = 'Other' THEN 'Old User'
    ELSE 'Old User'
  END AS NewOldUserInfo
FROM LastTab;
