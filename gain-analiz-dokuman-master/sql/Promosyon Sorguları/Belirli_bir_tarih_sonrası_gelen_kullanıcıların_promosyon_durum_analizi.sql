
-- Belirli_bir_tarih_sonrası_gelen_kullanıcıların_promosyon_durum_analizi
-- ===============================
WITH 
-- 1️⃣ BaseData: Eski kullanıcı ve abonelik bilgilerini alıyoruz
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
          ap.promotionid AS PromotionID,  -- Promosyon ID
          ap.applyDate AS PromotionApplyDate,  -- Promosyon uygulama tarihi
          ap.name AS PromotionName,
          ap.code AS PromotionCode,
          ap.type AS PromotionType,
          benefits.freePremiumByDay AS freePremiumByDay,  -- Günlük premium hakkı
          benefits.freePremiumByMonth AS freePremiumByMonth,  -- Aylık premium hakkı
          benefits.isFreePremium AS isFreePremium,  -- Premium hakkı var mı
          ROW_NUMBER() OVER(PARTITION BY user_id ORDER BY created_at DESC) AS rownum  -- En güncel kayıt
      FROM `aws_s3_to_bq_migration.subs_payment`
      LEFT JOIN UNNEST(applied_promotions) ap
      LEFT JOIN UNNEST(ap.benefits) benefits
      WHERE DATE(created_at) >= '2025-02-03'
        AND DATE(created_at) <= CURRENT_DATE("Europe/Istanbul") - 1
  )
  WHERE rownum = 1  -- Her kullanıcı için sadece en güncel ödeme kaydını al
),
-- 3️⃣ ReportData: Eski ve güncel verileri birleştirip en güncel bilgiyi seçiyoruz
ReportData AS (
  SELECT
      CASE
          WHEN bd.created_at > ud.created_at THEN bd.status
          WHEN ud.created_at IS NULL THEN bd.status
          ELSE ud.status
      END status,
      IFNULL(bd.subscription_plan_id, ud.subscription_plan_id) AS subscription_plan_id,
      CASE
          WHEN bd.created_at > ud.created_at THEN bd.valid_until
          WHEN ud.created_at IS NULL THEN bd.valid_until
          ELSE ud.valid_until
      END valid_until,
      CASE
          WHEN bd.created_at > ud.created_at THEN bd.user_id
          WHEN ud.created_at IS NULL THEN bd.user_id
          ELSE ud.user_id
      END user_id,
      CASE
          WHEN bd.created_at > ud.created_at THEN bd.email
          WHEN ud.created_at IS NULL THEN bd.email
          ELSE ud.email
      END email,
      CASE
          WHEN bd.created_at > ud.created_at THEN bd.registered_at
          WHEN ud.created_at IS NULL THEN bd.registered_at
          ELSE ud.registered_at
      END registered_at,
      CASE
          WHEN bd.created_at > ud.created_at THEN bd.created_at
          WHEN ud.created_at IS NULL THEN bd.created_at
          ELSE ud.created_at
      END created_at,
      CASE
          WHEN bd.created_at > ud.created_at THEN bd.grace_until
          WHEN ud.created_at IS NULL THEN bd.grace_until
          ELSE ud.grace_until
      END grace_until,
      CASE
          WHEN bd.created_at > ud.created_at THEN bd.free_trial_start_date
          WHEN ud.created_at IS NULL THEN bd.free_trial_start_date
          ELSE ud.free_trial_start_date
      END free_trial_start_date,
      CASE
          WHEN bd.created_at > ud.created_at THEN bd.free_trial_end_date
          WHEN ud.created_at IS NULL THEN bd.free_trial_end_date
          ELSE ud.free_trial_end_date
      END free_trial_end_date,
      CASE
          WHEN bd.created_at > ud.created_at THEN bd.applied_promotions
          WHEN ud.created_at IS NULL THEN bd.applied_promotions
          ELSE ud.PromotionID
      END applied_promotions,
      PromotionApplyDate,
      freePremiumByDay,
      PromotionID
  FROM BaseData bd
  FULL JOIN UpdateData ud ON bd.user_id = ud.user_id
)
-- 4️⃣ Ana çıktı: Belirli bir tarih sonrası kayıt olan kullanıcıların promosyon durumunu gösteriyoruz
SELECT
    COUNT(DISTINCT rd.user_id) AS cnt_dst,  -- Kullanıcı sayısı (unique)
    rd.applied_promotions,  -- Uygulanan promosyon ID
    DATE(rd.created_at) AS created_at,  -- Hesap oluşturulma tarihi
    DATE(rd.registered_at) AS registered_at,  -- Kayıt tarihi
    -- Eğer promosyon yoksa ve free trial süresi 7 veya 8 gün ise 'freetrial', aksi halde backoffice'ten promosyon adı
    CASE
        WHEN rd.applied_promotions IS NULL AND DATE_DIFF(DATE(valid_until), DATE(rd.created_at), DAY) IN (7,8) THEN 'freetrial'
        ELSE bp.name
    END AS promo_name
FROM ReportData rd 
LEFT JOIN `Backoffice_metadata.bo_promotions` bp 
  ON rd.applied_promotions = bp.promotionId
WHERE DATE(registered_at) >= '2025-07-16'  -- Belirli tarih sonrası kullanıcılar
  AND status = 'ACTIVE'  -- Aktif kullanıcılar
GROUP BY rd.applied_promotions, created_at, registered_at, promo_name
ORDER BY cnt_dst DESC;
