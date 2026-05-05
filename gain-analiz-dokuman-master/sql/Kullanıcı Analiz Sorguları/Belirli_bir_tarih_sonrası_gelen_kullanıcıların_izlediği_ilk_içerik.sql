
-- Belirli_bir_tarih_sonrası_gelen_kullanıcıların_izlediği_ilk_içerik
-- ===============================
WITH 
-- 1️⃣ BaseData: Eski kullanıcı ve abonelik bilgileri
BaseData AS (
  SELECT
      status,  -- Abonelik durumu
      subscription_plan_id,  -- Abonelik planı
      valid_until,  -- Abonelik geçerlilik tarihi
      user_id,  -- Kullanıcı ID
      email,  -- Kullanıcı e-posta
      registered_at,  -- Kayıt tarihi
      created_at,  -- Hesap oluşturulma tarihi
      grace_until,  -- Ödeme gecikme tolerans tarihi
      free_trial_start_date,  -- Ücretsiz deneme başlangıç tarihi
      free_trial_end_date,  -- Ücretsiz deneme bitiş tarihi
      REPLACE(applied_promotions,'[]',null) AS applied_promotions  -- Uygulanan promosyonlar (boşsa null)
  FROM `test_dataset.elastic_user`
  WHERE DATE(created_at) <= '2025-02-03'
),
-- 2️⃣ UpdateData: Güncel ödeme ve promosyon bilgilerini alıyoruz
UpdateData AS (
  SELECT *
  FROM (
      SELECT
          status,
          subscription_plan_id,
          valid_until,
          user_id,
          email,
          registered_at,
          created_at,
          grace_until,
          free_trial_start_date,
          free_trial_end_date,
          ap.promotionid AS PromotionID,
          ap.applyDate AS PromotionApplyDate,
          ap.name AS PromotionName,
          ap.code AS PromotionCode,
          ap.type AS PromotionType,
          benefits.freePremiumByDay AS freePremiumByDay,
          benefits.freePremiumByMonth AS freePremiumByMonth,
          benefits.isFreePremium AS isFreePremium,
          ROW_NUMBER() OVER(PARTITION BY user_id ORDER BY created_at DESC) AS rownum
      FROM `aws_s3_to_bq_migration.subs_payment`
      LEFT JOIN UNNEST(applied_promotions) ap
      LEFT JOIN UNNEST(ap.benefits) benefits
      WHERE DATE(created_at) >= '2025-02-03'
        AND DATE(created_at) <= CURRENT_DATE("Europe/Istanbul") - 1
  )
  WHERE rownum = 1  -- Her kullanıcı için sadece en güncel ödeme kaydı
),
-- 3️⃣ ReportData: BaseData ve UpdateData birleşimi; en güncel kayıtlar
ReportData AS (
  SELECT
      CASE WHEN bd.created_at > ud.created_at THEN bd.status
           WHEN ud.created_at IS NULL THEN bd.status
           ELSE ud.status
      END AS status,
      IFNULL(bd.subscription_plan_id, ud.subscription_plan_id) AS subscription_plan_id,
      CASE WHEN bd.created_at > ud.created_at THEN bd.valid_until
           WHEN ud.created_at IS NULL THEN bd.valid_until
           ELSE ud.valid_until
      END AS valid_until,
      CASE WHEN bd.created_at > ud.created_at THEN bd.user_id
           WHEN ud.created_at IS NULL THEN bd.user_id
           ELSE ud.user_id
      END AS user_id,
      CASE WHEN bd.created_at > ud.created_at THEN bd.email
           WHEN ud.created_at IS NULL THEN bd.email
           ELSE ud.email
      END AS email,
      CASE WHEN bd.created_at > ud.created_at THEN bd.registered_at
           WHEN ud.created_at IS NULL THEN bd.registered_at
           ELSE ud.registered_at
      END AS registered_at,
      CASE WHEN bd.created_at > ud.created_at THEN bd.created_at
           WHEN ud.created_at IS NULL THEN bd.created_at
           ELSE ud.created_at
      END AS created_at,
      CASE WHEN bd.created_at > ud.created_at THEN bd.grace_until
           WHEN ud.created_at IS NULL THEN bd.grace_until
           ELSE ud.grace_until
      END AS grace_until,
      CASE WHEN bd.created_at > ud.created_at THEN bd.free_trial_start_date
           WHEN ud.created_at IS NULL THEN bd.free_trial_start_date
           ELSE ud.free_trial_start_date
      END AS free_trial_start_date,
      CASE WHEN bd.created_at > ud.created_at THEN bd.free_trial_end_date
           WHEN ud.created_at IS NULL THEN bd.free_trial_end_date
           ELSE ud.free_trial_end_date
      END AS free_trial_end_date,
      CASE WHEN bd.created_at > ud.created_at THEN bd.applied_promotions
           WHEN ud.created_at IS NULL THEN bd.applied_promotions
           ELSE ud.PromotionID
      END AS applied_promotions,
      PromotionApplyDate,
      freePremiumByDay,
      PromotionID
  FROM BaseData bd
  FULL JOIN UpdateData ud ON bd.user_id = ud.user_id
),
-- 4️⃣ first_event: Her kullanıcı için en erken izleme zamanını al
first_event AS (
  SELECT
    user_id,
    MIN(datetime_ist) AS min_event_time
  FROM `looker_report.content_report_streaming_V2`
  WHERE event_date >= '2025-07-16'  -- Belirli tarih sonrası
  GROUP BY user_id
),
-- 5️⃣ first_watched: Kullanıcıların ilk izlediği içerik
first_watched AS (
  SELECT DISTINCT
    a.user_id,
    a.datetime_ist,
    a.playlistid
  FROM `looker_report.content_report_streaming_V2` a
  JOIN first_event f 
    ON a.user_id = f.user_id 
   AND a.datetime_ist = f.min_event_time
  WHERE event_date >= '2025-07-16'
)
-- 6️⃣ Ana çıktı: Kullanıcı sayısı ve ilk izledikleri içerik
SELECT
  COUNT(DISTINCT rd.user_id) AS cnt_dst,  -- Belirli tarih sonrası aktif kullanıcı sayısı
  fw.playlistid  -- İlk izlenen içerik (playlist)
FROM ReportData rd 
LEFT JOIN `Backoffice_metadata.bo_promotions` bp 
  ON rd.applied_promotions = bp.promotionId
LEFT JOIN first_watched fw 
  ON rd.user_id = fw.user_id
WHERE DATE(registered_at) >= '2025-07-16'  -- Belirli tarih sonrası kayıt olan kullanıcılar
  AND status = 'ACTIVE'  -- Aktif kullanıcılar
GROUP BY fw.playlistid
ORDER BY cnt_dst DESC;
